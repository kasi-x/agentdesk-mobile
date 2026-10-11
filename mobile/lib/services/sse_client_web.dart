// Web SSE transport: package:http's BrowserClient buffers the whole
// response body, so a never-ending event stream would hang forever.
// Instead this uses the browser fetch() API directly and reads the
// ReadableStream incrementally, feeding decoded lines into the shared
// [SseEventParser] so event dispatch matches the IO transport exactly.

import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'sse_parser.dart';

/// Minimal SSE client over fetch() + ReadableStream with
/// exponential-backoff reconnect. Every (re)connect receives a `snapshot`
/// event, so no Last-Event-ID bookkeeping is needed (docs/protocol.md).
class SseClient {
  Timer? _retryTimer;
  bool _disposed = false;
  int _retrySeconds = 1;
  web.AbortController? _inflight;

  SseClient({Object? client});

  void connect({
    required Uri uri,
    required Map<String, String> headers,
    required void Function(String event, String data) onEvent,
    required void Function() onConnected,
  }) {
    _disposed = false;
    _retrySeconds = 1;
    _attempt(
        uri: uri,
        headers: headers,
        onEvent: onEvent,
        onConnected: onConnected);
  }

  Future<void> _attempt({
    required Uri uri,
    required Map<String, String> headers,
    required void Function(String event, String data) onEvent,
    required void Function() onConnected,
  }) async {
    if (_disposed) return;
    final aborter = web.AbortController();
    _inflight = aborter;
    try {
      final jsHeaders = web.Headers();
      headers.forEach((name, value) => jsHeaders.append(name, value));
      // match the IO transport: same method + Accept, caller-supplied auth
      jsHeaders.set('Accept', 'text/event-stream');
      final init = web.RequestInit(
        method: 'GET',
        headers: jsHeaders,
        signal: aborter.signal,
      );
      final response =
          await web.window.fetch(uri.toString().toJS, init).toDart;
      if (response.status != 200) {
        throw StateError('stream responded ${response.status}');
      }
      final body = response.body;
      if (body == null) throw StateError('stream has no body');
      _retrySeconds = 1;
      onConnected();

      final parser = SseEventParser();
      final reader = web.ReadableStreamDefaultReader(body);
      final decoder = web.TextDecoder();
      var textTail = '';
      try {
        while (true) {
          if (_disposed) return;
          final chunk = await reader.read().toDart;
          if (chunk.done) break;
          final value = chunk.value;
          // Chunk values are Uint8Array views; decode incrementally.
          final text = value == null
              ? ''
              : decoder.decode(value as JSObject, web.TextDecodeOptions(stream: true));
          textTail += text;
          final lines = textTail.split('\n');
          // Hold the last (possibly partial) line for the next chunk.
          textTail = lines.removeLast();
          for (final raw in lines) {
            final line = raw.endsWith('\r')
                ? raw.substring(0, raw.length - 1)
                : raw;
            final dispatched = parser.onLine(line);
            if (dispatched != null) onEvent(dispatched.$1, dispatched.$2);
          }
        }
      } finally {
        reader.releaseLock();
      }
      // Server closed the stream → fall through to reconnect.
    } catch (_) {
      // connect/transport failure (incl. abort on dispose) → reconnect
    } finally {
      if (identical(_inflight, aborter)) _inflight = null;
    }
    _scheduleReconnect(
        uri: uri,
        headers: headers,
        onEvent: onEvent,
        onConnected: onConnected);
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
      _attempt(
          uri: uri,
          headers: headers,
          onEvent: onEvent,
          onConnected: onConnected);
    });
  }

  Future<void> dispose() async {
    _disposed = true;
    _retryTimer?.cancel();
    // Aborts the in-flight fetch + reader.read(), landing in catch → but
    // _disposed blocks the reconnect, so the stream just ends.
    _inflight?.abort();
    _inflight = null;
  }
}
