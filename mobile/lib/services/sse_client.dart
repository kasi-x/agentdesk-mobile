import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Minimal SSE client over package:http with exponential-backoff
/// reconnect. Every (re)connect receives a `snapshot` event, so no
/// Last-Event-ID bookkeeping is needed (docs/protocol.md).
class SseClient {
  final http.Client _client;
  Timer? _retryTimer;
  bool _disposed = false;
  int _retrySeconds = 1;

  SseClient({http.Client? client}) : _client = client ?? http.Client();

  void connect({
    required Uri uri,
    required Map<String, String> headers,
    required void Function(String event, String data) onEvent,
    required void Function() onConnected,
  }) {
    _disposed = false;
    _retrySeconds = 1;
    _attempt(uri: uri, headers: headers, onEvent: onEvent, onConnected: onConnected);
  }

  Future<void> _attempt({
    required Uri uri,
    required Map<String, String> headers,
    required void Function(String event, String data) onEvent,
    required void Function() onConnected,
  }) async {
    if (_disposed) return;
    try {
      final request = http.Request('GET', uri)..headers.addAll(headers);
      final response = await _client.send(request).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw http.ClientException('stream responded ${response.statusCode}', uri);
      }
      _retrySeconds = 1;
      onConnected();

      String? event;
      final dataBuffer = <String>[];
      final lines =
          response.stream.transform(utf8.decoder).transform(const LineSplitter());
      await for (final line in lines) {
        if (line.isEmpty) {
          if (dataBuffer.isNotEmpty) {
            onEvent(event ?? 'message', dataBuffer.join('\n'));
          }
          event = null;
          dataBuffer.clear();
          continue;
        }
        if (line.startsWith(':')) continue; // heartbeat comment
        if (line.startsWith('event:')) {
          event = line.substring(6).trim();
        } else if (line.startsWith('data:')) {
          dataBuffer.add(line.substring(5).trim());
        }
      }
      // Server closed the stream → fall through to reconnect.
    } catch (_) {
      // connect/transport failure → fall through to reconnect
    }
    _scheduleReconnect(uri: uri, headers: headers, onEvent: onEvent, onConnected: onConnected);
  }

  void _scheduleReconnect({
    required Uri uri,
    required Map<String, String> headers,
    required void Function(String event, String data) onEvent,
    required void Function() onConnected,
  }) {
    if (_disposed) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(Duration(seconds: _retrySeconds), () {
      _retrySeconds = (_retrySeconds * 2).clamp(1, 30);
      _attempt(uri: uri, headers: headers, onEvent: onEvent, onConnected: onConnected);
    });
  }

  Future<void> dispose() async {
    _disposed = true;
    _retryTimer?.cancel();
    _client.close();
  }
}
