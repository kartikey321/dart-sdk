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
    try {
      while (true) {
        final framed = await zigIoTcpReadRequestFuture(connFd);
        if (framed == null) return;

        final response = ZigHttpResponse(connFd);
        final request =
            ZigHttpRequest(framed.method, framed.path, framed.bodyBytes, response);

        _controller.add(request);
        await response._doneFuture;

        if (!framed.keepAlive) return;
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
