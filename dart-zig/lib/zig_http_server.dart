// dart-zig HttpServer — drop-in dart:io-style API backed by io_uring.
//
// Usage:
//   final server = await ZigHttpServer.bind('0.0.0.0', 8080);
//   server.stream.listen((req) {
//     req.response
//       ..statusCode = 200
//       ..headers.set('Content-Type', 'text/plain')
//       ..write('Hello!')
//       ..close();
//   });
//
// ~2 io_uring round-trips per request (recv + send).
// HTTP parsing in Zig (ZigHttp_Parse) — zero Dart heap allocs in the parse path.

// ignore_for_file: unawaited_futures

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'zig_io.dart';
import 'zig_http.dart' show parseHttpRequest;

// ---------------------------------------------------------------------------
// ZigHttpServer
// ---------------------------------------------------------------------------

class ZigHttpServer {
  final int _listenFd;
  final StreamController<ZigHttpRequest> _controller;
  bool _closed = false;

  ZigHttpServer._(this._listenFd)
      : _controller = StreamController<ZigHttpRequest>();

  static Future<ZigHttpServer> bind(String host, int port,
      {int backlog = 4096}) {
    final fd = zigIoTcpBind(host, port, backlog);
    if (fd < 0) throw Exception('ZigHttpServer.bind failed: errno=${-fd}');
    final server = ZigHttpServer._(fd);
    server._acceptLoop();
    return Future.value(server);
  }

  /// Stream of incoming requests. Use `.listen()` to handle them.
  Stream<ZigHttpRequest> get stream => _controller.stream;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    zigIoClose(_listenFd);
    await _controller.close();
  }

  void _acceptLoop() async {
    while (!_closed) {
      final connFd = await zigIoTcpAcceptFuture(_listenFd);
      if (connFd < 0) continue;
      _handleConnection(connFd);
    }
  }

  void _handleConnection(int connFd) async {
    // Reuse a single 8 KB buffer per connection — no per-request allocation.
    final recvBuf = Uint8List(8192);
    int bufLen = 0;

    try {
      while (true) {
        // Accumulate until we have a complete HTTP request.
        while (true) {
          final space = 8192 - bufLen;
          if (space == 0) return; // request headers too large
          final chunk = await zigIoTcpReadFuture(connFd, space);
          if (chunk == null) return; // EOF or error
          recvBuf.setRange(bufLen, bufLen + chunk.length, chunk);
          bufLen += chunk.length;

          // ZigHttp_Parse: fast Zig path, returns method/path/bodyOffset.
          final parsed = parseHttpRequest(
              Uint8List.sublistView(recvBuf, 0, bufLen));
          if (parsed != null) {
            final bodyOffset = parsed.bodyOffset;
            final keepAlive = _keepAlive(recvBuf, bodyOffset);
            final framed = _frameRequest(recvBuf, bufLen, bodyOffset);
            if (framed == null) continue;

            final response = ZigHttpResponse(connFd);
            final request = ZigHttpRequest(
                parsed.method, parsed.path, framed.bodyBytes, response);

            _controller.add(request);
            await response._doneFuture;

            // Shift any pipelined data to buffer front.
            final remaining = bufLen - framed.endOffset;
            if (remaining > 0) {
              recvBuf.setRange(0, remaining,
                  Uint8List.sublistView(recvBuf, framed.endOffset, bufLen));
            }
            bufLen = remaining;

            if (!keepAlive) return;
            break;
          }
          // incomplete — keep reading
        }
      }
    } finally {
      zigIoClose(connFd);
    }
  }
}

// ---------------------------------------------------------------------------
// ZigHttpRequest
// ---------------------------------------------------------------------------

class ZigHttpRequest {
  final String method;
  // Raw path string — use this for simple route matching (no allocation).
  final String path;
  final Uint8List bodyBytes;
  final ZigHttpResponse response;

  ZigHttpRequest(this.method, this.path, this.bodyBytes, this.response);

  // Full Uri — lazy. Only materialised when query params or other Uri fields
  // are needed. Simple `switch (req.path)` routing never pays this cost.
  Uri? _uri;
  Uri get uri => _uri ??= Uri.parse(path);

  String get bodyText => utf8.decode(bodyBytes);
}

// ---------------------------------------------------------------------------
// ZigHttpResponse
// ---------------------------------------------------------------------------

class ZigHttpResponse {
  final int _connFd;
  int statusCode = 200;
  final ZigHeaders headers = ZigHeaders._();
  final _body = BytesBuilder();
  final Completer<void> _done = Completer<void>();
  bool _closed = false;

  ZigHttpResponse(this._connFd);

  Future<void> get _doneFuture => _done.future;

  void write(Object obj) => _body.add(utf8.encode(obj.toString()));
  void add(List<int> data) => _body.add(data);

  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    final bodyBytes = _body.takeBytes();
    headers._setIfAbsent('content-type', 'text/plain; charset=utf-8');
    headers._setIfAbsent('content-length', '${bodyBytes.length}');
    headers._setIfAbsent('connection', 'keep-alive');

    final sb = StringBuffer()
      ..write(_statusLine(statusCode));
    headers._forEach((name, value) => sb.write('$name: $value\r\n'));
    sb.write('\r\n');

    final headerBytes = utf8.encode(sb.toString());
    final out = Uint8List(headerBytes.length + bodyBytes.length)
      ..setRange(0, headerBytes.length, headerBytes)
      ..setRange(
          headerBytes.length, headerBytes.length + bodyBytes.length, bodyBytes);

    await zigIoTcpWriteBytesFuture(_connFd, out);
    _done.complete();
  }

  // Pre-built status lines — avoids string interpolation on every response.
  static const _statusLines = {
    200: 'HTTP/1.1 200 OK\r\n',
    201: 'HTTP/1.1 201 Created\r\n',
    204: 'HTTP/1.1 204 No Content\r\n',
    301: 'HTTP/1.1 301 Moved Permanently\r\n',
    302: 'HTTP/1.1 302 Found\r\n',
    304: 'HTTP/1.1 304 Not Modified\r\n',
    400: 'HTTP/1.1 400 Bad Request\r\n',
    401: 'HTTP/1.1 401 Unauthorized\r\n',
    403: 'HTTP/1.1 403 Forbidden\r\n',
    404: 'HTTP/1.1 404 Not Found\r\n',
    405: 'HTTP/1.1 405 Method Not Allowed\r\n',
    429: 'HTTP/1.1 429 Too Many Requests\r\n',
    500: 'HTTP/1.1 500 Internal Server Error\r\n',
    502: 'HTTP/1.1 502 Bad Gateway\r\n',
    503: 'HTTP/1.1 503 Service Unavailable\r\n',
  };

  static String _statusLine(int code) =>
      _statusLines[code] ?? 'HTTP/1.1 $code Unknown\r\n';
}

// ---------------------------------------------------------------------------
// ZigHeaders — case-insensitive map (lowercase storage)
// ---------------------------------------------------------------------------

class ZigHeaders {
  final Map<String, String> _map = {};

  ZigHeaders._();

  String? operator [](String name) => _map[name.toLowerCase()];
  void set(String name, String value) => _map[name.toLowerCase()] = value;
  bool contains(String name) => _map.containsKey(name.toLowerCase());

  void _set(String lowerName, String value) => _map[lowerName] = value;
  void _setIfAbsent(String lowerName, String value) =>
      _map.putIfAbsent(lowerName, () => value);
  void _forEach(void Function(String, String) fn) => _map.forEach(fn);
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Check if Connection header requests close (default: keep-alive in HTTP/1.1).
bool _keepAlive(Uint8List buf, int bodyOffset) {
  // Scan for "connection:" header between request-line and body.
  // Skip request line first.
  int pos = 0;
  while (pos < bodyOffset && buf[pos] != 0x0a) pos++;
  pos++;

  while (pos < bodyOffset) {
    if (buf[pos] == 0x0d || buf[pos] == 0x0a) break;
    // Match "connection:" case-insensitively (6 chars + ':').
    if (pos + 11 < bodyOffset) {
      final b = buf;
      if ((b[pos] | 0x20) == 0x63 && // c
          (b[pos + 1] | 0x20) == 0x6f && // o
          (b[pos + 2] | 0x20) == 0x6e && // n
          (b[pos + 3] | 0x20) == 0x6e && // n
          (b[pos + 4] | 0x20) == 0x65 && // e
          (b[pos + 5] | 0x20) == 0x63 && // c
          (b[pos + 6] | 0x20) == 0x74 && // t
          (b[pos + 7] | 0x20) == 0x69 && // i
          (b[pos + 8] | 0x20) == 0x6f && // o
          (b[pos + 9] | 0x20) == 0x6e && // n
          b[pos + 10] == 0x3a) { // :
        // Found Connection: — check if value contains "close".
        var vp = pos + 11;
        while (vp < bodyOffset && buf[vp] == 0x20) vp++;
        if (vp + 5 <= bodyOffset &&
            (buf[vp] | 0x20) == 0x63 &&
            (buf[vp + 1] | 0x20) == 0x6c &&
            (buf[vp + 2] | 0x20) == 0x6f &&
            (buf[vp + 3] | 0x20) == 0x73 &&
            (buf[vp + 4] | 0x20) == 0x65) {
          return false; // Connection: close
        }
        return true; // Connection: keep-alive (or other value)
      }
    }
    // Skip to next header line.
    while (pos < bodyOffset && buf[pos] != 0x0a) pos++;
    pos++;
  }
  return true; // HTTP/1.1 default: keep-alive
}

class _FramedRequest {
  final int endOffset;
  final Uint8List bodyBytes;

  const _FramedRequest(this.endOffset, this.bodyBytes);
}

_FramedRequest? _frameRequest(Uint8List buf, int bufLen, int bodyOffset) {
  final transferEncoding = _headerValue(buf, bodyOffset, 'transfer-encoding');
  if (transferEncoding != null &&
      transferEncoding.toLowerCase().contains('chunked')) {
    return _decodeChunkedBody(buf, bufLen, bodyOffset);
  }

  final contentLengthValue = _headerValue(buf, bodyOffset, 'content-length');
  if (contentLengthValue != null) {
    final contentLength = int.tryParse(contentLengthValue.trim());
    if (contentLength == null || contentLength < 0) return null;
    final endOffset = bodyOffset + contentLength;
    if (bufLen < endOffset) return null;
    return _FramedRequest(
      endOffset,
      Uint8List.sublistView(buf, bodyOffset, endOffset),
    );
  }

  return _FramedRequest(bodyOffset, Uint8List(0));
}

String? _headerValue(Uint8List buf, int bodyOffset, String name) {
  final lowerName = ascii.encode(name.toLowerCase());
  int pos = 0;
  while (pos < bodyOffset && buf[pos] != 0x0a) pos++;
  pos++;

  while (pos < bodyOffset) {
    if (buf[pos] == 0x0d || buf[pos] == 0x0a) break;

    var colon = pos;
    while (colon < bodyOffset && buf[colon] != 0x3a && buf[colon] != 0x0a) {
      colon++;
    }
    if (colon >= bodyOffset || buf[colon] != 0x3a) break;

    final nameLen = colon - pos;
    if (nameLen == lowerName.length) {
      var match = true;
      for (var i = 0; i < lowerName.length; i++) {
        if ((buf[pos + i] | 0x20) != lowerName[i]) {
          match = false;
          break;
        }
      }
      if (match) {
        var valueStart = colon + 1;
        while (valueStart < bodyOffset &&
            (buf[valueStart] == 0x20 || buf[valueStart] == 0x09)) {
          valueStart++;
        }
        var valueEnd = valueStart;
        while (valueEnd < bodyOffset &&
            buf[valueEnd] != 0x0d &&
            buf[valueEnd] != 0x0a) {
          valueEnd++;
        }
        return ascii.decode(buf.sublist(valueStart, valueEnd));
      }
    }

    while (pos < bodyOffset && buf[pos] != 0x0a) pos++;
    pos++;
  }

  return null;
}

_FramedRequest? _decodeChunkedBody(Uint8List buf, int bufLen, int bodyOffset) {
  var pos = bodyOffset;
  final body = BytesBuilder(copy: false);

  while (true) {
    final lineEnd = _findLineEnd(buf, pos, bufLen);
    if (lineEnd == null) return null;
    final sizeText = ascii
        .decode(buf.sublist(pos, lineEnd))
        .split(';')
        .first
        .trim();
    final chunkSize = int.tryParse(sizeText, radix: 16);
    if (chunkSize == null || chunkSize < 0) return null;
    final nextPos = _advancePastLineEnd(buf, lineEnd, bufLen);
    if (nextPos == null) return null;
    pos = nextPos;

    if (chunkSize == 0) {
      while (true) {
        final trailerEnd = _findLineEnd(buf, pos, bufLen);
        if (trailerEnd == null) return null;
        if (trailerEnd == pos) {
          final endOffset = _advancePastLineEnd(buf, trailerEnd, bufLen);
          if (endOffset == null) return null;
          return _FramedRequest(endOffset, body.takeBytes());
        }
        final nextTrailerPos = _advancePastLineEnd(buf, trailerEnd, bufLen);
        if (nextTrailerPos == null) return null;
        pos = nextTrailerPos;
      }
    }

    final chunkEnd = pos + chunkSize;
    if (chunkEnd + 1 >= bufLen) return null;
    body.add(Uint8List.sublistView(buf, pos, chunkEnd));
    pos = chunkEnd;

    if (buf[pos] == 0x0d) {
      if (pos + 1 >= bufLen || buf[pos + 1] != 0x0a) return null;
      pos += 2;
    } else if (buf[pos] == 0x0a) {
      pos += 1;
    } else {
      return null;
    }
  }
}

int? _findLineEnd(Uint8List buf, int start, int limit) {
  for (var i = start; i < limit; i++) {
    if (buf[i] == 0x0a) {
      return i > start && buf[i - 1] == 0x0d ? i - 1 : i;
    }
  }
  return null;
}

int? _advancePastLineEnd(Uint8List buf, int lineEnd, int limit) {
  if (lineEnd >= limit) return null;
  if (buf[lineEnd] == 0x0a) return lineEnd + 1;
  if (lineEnd + 1 < limit && buf[lineEnd] == 0x0d && buf[lineEnd + 1] == 0x0a) {
    return lineEnd + 2;
  }
  if (lineEnd + 1 < limit && buf[lineEnd + 1] == 0x0a) return lineEnd + 2;
  return null;
}
