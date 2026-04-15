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

import 'zig_io.dart';

// ---------------------------------------------------------------------------
// Connection handler — one await per request.
//
// zigIoTcpServeFuture() is a fused Zig op that:
//   1. Reads bytes from the fd into a pool slot buffer
//   2. Calls routeRequest() in the completion handler
//   3. Looks up the comptime-constant response slice (responses.zig)
//   4. Writes the response inline via posix.write() fast-path
//   5. Posts 0 (keep-alive) or -1 (close) to Dart
//
// Zero Dart heap allocation per request — no Uint8List, no GC, no memcpy.
// ---------------------------------------------------------------------------

Future<void> _handleConn(int connFd) async {
  while (true) {
    final result = await zigIoTcpServeFuture(connFd);
    if (result != 0) {
      zigIoClose(connFd);
      return;
    }
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
    final connFd = await zigIoTcpAcceptFuture(listenFd);
    if (connFd < 0) {
      print('accept error: $connFd');
      continue;
    }
    _handleConn(connFd); // fire-and-forget
  }
}
