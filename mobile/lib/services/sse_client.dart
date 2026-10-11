// The IO implementation streams via package:http (`Client.send`);
// the web implementation reads fetch()'s ReadableStream incrementally
// because BrowserClient buffers whole bodies (an SSE stream would hang).
export 'sse_client_io.dart' if (dart.library.js_interop) 'sse_client_web.dart';
