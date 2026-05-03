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
// Connection handler — one await per connection (PERF-6 loop op).
//
// zigIoTcpLoopFuture() is a fused Zig op that handles the entire keep-alive
// connection lifecycle without returning to Dart between requests:
//   recv → routeRequestFull() → inline posix.write() → memmove → repeat
//
// HTTP pipelining: if multiple requests arrived in one recv, they are all
// served immediately without re-arming the socket.
//
// Posts only when the connection closes (returns -1).
// Zero Dart heap allocation per request or per connection.
// ---------------------------------------------------------------------------

Future<void> _handleConn(int connFd) async {
  await zigIoTcpLoopFuture(connFd);
  // fd already closed by Zig before posting -1
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.parse(args[0]) : 8080;

  final listenFd = zigIoTcpBind('0.0.0.0', port, 4096);
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
