// dart-zig HTTPS/1.1 server — Phase 15 TLS demo.
//
// Compile (JIT):
//   dart compile kernel \
//     --packages=.dart_tool/package_config.json \
//     -o test-snapshots/https_server.dill lib/https_server.dart
//
// Run:
//   ./zig-out/bin/dart-zig test-snapshots/https_server.dill [port] [cert.pem] [key.pem]
//
// Test:
//   curl -k https://127.0.0.1:8443/
//   wrk -t4 -c128 -d10s https://127.0.0.1:8443/

// ignore_for_file: unawaited_futures

import 'dart:convert';
import 'dart:typed_data';

import 'zig_io.dart';
import 'zig_tls.dart';
import 'zig_http.dart';

// ---------------------------------------------------------------------------
// Pre-built responses (same as http_server.dart)
// ---------------------------------------------------------------------------

final Uint8List _kHelloResponse = _buildResponse(200, 'OK', 'Hello from dart-zig TLS!');
final Uint8List _k404Response = _buildResponse(404, 'Not Found', '404 Not Found');
final Uint8List _k400Response = _buildResponse(400, 'Bad Request', 'Bad Request', close: true);

Uint8List _buildResponse(int status, String statusText, String body,
    {bool close = false}) {
  final bodyBytes = utf8.encode(body);
  final headers = 'HTTP/1.1 $status $statusText\r\n'
      'Content-Type: text/plain; charset=utf-8\r\n'
      'Content-Length: ${bodyBytes.length}\r\n'
      'Connection: ${close ? "close" : "keep-alive"}\r\n'
      '\r\n';
  final headerBytes = utf8.encode(headers);
  final out = Uint8List(headerBytes.length + bodyBytes.length);
  out.setAll(0, headerBytes);
  out.setAll(headerBytes.length, bodyBytes);
  return out;
}

Uint8List _buildPingResponse() => _buildResponse(200, 'OK', 'pong');

// ---------------------------------------------------------------------------
// TLS connection handler
// ---------------------------------------------------------------------------

Future<void> _handleTlsConn(int connFd) async {
  // Perform TLS handshake — upgrades the raw TCP fd to TLS.
  // zigTlsUpgradeFuture takes full ownership of connFd (closes it on error too).
  final tlsId = await zigTlsUpgradeFuture(connFd);
  if (tlsId < 0) return; // fd already closed inside the TLS layer

  // Keep-alive loop: serve multiple requests per TLS connection.
  while (true) {
    final bytes = await zigTlsReadFuture(tlsId, 8192);
    if (bytes == null || bytes.isEmpty) {
      zigTlsClose(tlsId);
      return;
    }

    final req = parseHttpRequest(bytes);
    if (req == null) {
      await zigTlsWriteBytesFuture(tlsId, _k400Response);
      zigTlsClose(tlsId);
      return;
    }

    final response = switch (req.path) {
      '/' || '/index.html' => _kHelloResponse,
      '/ping' => _buildPingResponse(),
      _ => _k404Response,
    };

    final written = await zigTlsWriteBytesFuture(tlsId, response);
    if (written < 0) {
      zigTlsClose(tlsId);
      return;
    }
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.parse(args[0]) : 8443;
  final certFile = args.length > 1 ? args[1] : 'test-certs/cert.pem';
  final keyFile = args.length > 2 ? args[2] : 'test-certs/key.pem';

  final rc = zigTlsConfigure(certFile, keyFile);
  if (rc != 0) {
    print('TLS configure failed (cert=$certFile key=$keyFile)');
    return;
  }
  print('TLS configured: cert=$certFile');

  final listenFd = zigIoTcpBind('0.0.0.0', port, 128);
  if (listenFd < 0) {
    print('bind failed: $listenFd');
    return;
  }
  print('dart-zig HTTPS/1.1 server on port $port  (fd=$listenFd)');

  while (true) {
    final connFd = await zigIoTcpAcceptFuture(listenFd);
    if (connFd < 0) {
      print('accept error: $connFd');
      continue;
    }
    _handleTlsConn(connFd); // fire-and-forget
  }
}
