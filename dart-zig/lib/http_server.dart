// dart-zig HTTP/1.1 server — Hello World, benchmarkable with wrk.
//
// Compile (JIT):
//   dart compile kernel \
//     --packages=.dart_tool/package_config.json \
//     -o test-snapshots/http_server.dill lib/http_server.dart
//
// Run:
//   ./zig-out/bin/dart-zig  test-snapshots/http_server.dill [port]
//   ./zig-out/bin/dart-zig-aot test-snapshots/http_server_aot.dylib [port]
//
// Benchmark:
//   wrk -t4 -c128 -d10s http://127.0.0.1:8080/

// ignore_for_file: unawaited_futures

import 'dart:convert';
import 'dart:typed_data';

import 'zig_io.dart';
import 'zig_http.dart';

// ---------------------------------------------------------------------------
// TCP helpers (same pattern as echo_server.dart)
// ---------------------------------------------------------------------------

// Uses the batch dispatcher from zig_io.dart:
//   zigIoTcpAcceptFuture  — completions batched into one kArray per kevent() call
//   zigIoTcpReadFuture    — token-based, single RawReceivePort for all connections
//   zigIoTcpWriteBytesFuture

Future<int> _accept(int listenFd) => zigIoTcpAcceptFuture(listenFd);

class _Conn {
  final int fd;
  const _Conn(this.fd);

  Future<Uint8List?> read(int maxBytes) => zigIoTcpReadFuture(fd, maxBytes);

  Future<int> writeBytes(Uint8List bytes) =>
      zigIoTcpWriteBytesFuture(fd, bytes);

  void close() => zigIoClose(fd);
}

// ---------------------------------------------------------------------------
// HTTP response builder
// ---------------------------------------------------------------------------

// Pre-build all responses once at startup — zero per-request allocation.
final Uint8List _kHelloResponse = _buildHelloResponse();
final Uint8List _kPingResponse  = _buildPingResponse();
final Uint8List _k404Response   = _buildNotFoundResponse();
final Uint8List _k400Response   = _buildBadRequestResponse();

Uint8List _buildHelloResponse() {
  const body = 'Hello from dart-zig!';
  final bodyBytes = utf8.encode(body);
  final headers = 'HTTP/1.1 200 OK\r\n'
      'Content-Type: text/plain; charset=utf-8\r\n'
      'Content-Length: ${bodyBytes.length}\r\n'
      'Connection: keep-alive\r\n'
      '\r\n';
  final headerBytes = utf8.encode(headers);
  final out = Uint8List(headerBytes.length + bodyBytes.length);
  out.setAll(0, headerBytes);
  out.setAll(headerBytes.length, bodyBytes);
  return out;
}

Uint8List _buildNotFoundResponse() {
  const body = '404 Not Found';
  final bodyBytes = utf8.encode(body);
  final headers = 'HTTP/1.1 404 Not Found\r\n'
      'Content-Type: text/plain; charset=utf-8\r\n'
      'Content-Length: ${bodyBytes.length}\r\n'
      'Connection: keep-alive\r\n'
      '\r\n';
  final headerBytes = utf8.encode(headers);
  final out = Uint8List(headerBytes.length + bodyBytes.length);
  out.setAll(0, headerBytes);
  out.setAll(headerBytes.length, bodyBytes);
  return out;
}

Uint8List _buildPingResponse() {
  const body = 'pong';
  final bodyBytes = utf8.encode(body);
  final headers = 'HTTP/1.1 200 OK\r\n'
      'Content-Type: text/plain; charset=utf-8\r\n'
      'Content-Length: ${bodyBytes.length}\r\n'
      'Connection: keep-alive\r\n'
      '\r\n';
  final headerBytes = utf8.encode(headers);
  final out = Uint8List(headerBytes.length + bodyBytes.length);
  out.setAll(0, headerBytes);
  out.setAll(headerBytes.length, bodyBytes);
  return out;
}

Uint8List _buildBadRequestResponse() {
  const body = 'Bad Request';
  final bodyBytes = utf8.encode(body);
  final headers = 'HTTP/1.1 400 Bad Request\r\n'
      'Content-Type: text/plain; charset=utf-8\r\n'
      'Content-Length: ${bodyBytes.length}\r\n'
      'Connection: close\r\n'
      '\r\n';
  final headerBytes = utf8.encode(headers);
  final out = Uint8List(headerBytes.length + bodyBytes.length);
  out.setAll(0, headerBytes);
  out.setAll(headerBytes.length, bodyBytes);
  return out;
}

// ---------------------------------------------------------------------------
// Connection handler
// ---------------------------------------------------------------------------

Future<void> _handleConn(int connFd) async {
  final conn = _Conn(connFd);

  // Keep-alive loop: serve multiple requests per connection.
  while (true) {
    // Read enough for full request headers (typical request << 8KB).
    final bytes = await conn.read(8192);
    if (bytes == null || bytes.isEmpty) {
      // Client closed the connection — normal keep-alive EOF.
      conn.close();
      return;
    }

    // Single Zig call: parse + route → int, zero Dart heap allocation.
    final route = zigHttpRoute(bytes);
    if (route == RouteId.badRequest) {
      await conn.writeBytes(_k400Response);
      conn.close();
      return;
    }

    final response = switch (route) {
      RouteId.hello    => _kHelloResponse,
      RouteId.ping     => _kPingResponse,
      _                => _k404Response,
    };

    final written = await conn.writeBytes(response);
    if (written < 0) {
      conn.close();
      return;
    }
    // Loop: wait for next request on the same connection.
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.parse(args[0]) : 8080;

  final listenFd = zigIoTcpBind('0.0.0.0', port, 128);
  if (listenFd < 0) {
    print('bind failed: $listenFd');
    return;
  }
  print('dart-zig HTTP/1.1 server on port $port  (fd=$listenFd)');

  while (true) {
    final connFd = await _accept(listenFd);
    if (connFd < 0) {
      print('accept error: $connFd');
      continue;
    }
    _handleConn(connFd); // fire-and-forget
  }
}
