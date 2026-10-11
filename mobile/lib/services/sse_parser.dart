/// Shared SSE text-protocol parser: both transports (package:http on the
/// VM, fetch() on the web) decode bytes to lines and feed them here, so
/// event dispatch stays identical on every platform.
class SseEventParser {
  String? _event;
  final List<String> _dataBuffer = <String>[];

  /// Feeds one protocol line. Returns an (event, data) pair when a blank
  /// line terminates a dispatchable event, null otherwise.
  (String, String)? onLine(String line) {
    if (line.isEmpty) {
      if (_dataBuffer.isEmpty) {
        _event = null;
        return null;
      }
      final result = (_event ?? 'message', _dataBuffer.join('\n'));
      _event = null;
      _dataBuffer.clear();
      return result;
    }
    if (line.startsWith(':')) return null; // heartbeat comment
    if (line.startsWith('event:')) {
      _event = line.substring(6).trim();
    } else if (line.startsWith('data:')) {
      _dataBuffer.add(line.substring(5).trim());
    }
    return null;
  }

  void reset() {
    _event = null;
    _dataBuffer.clear();
  }
}
