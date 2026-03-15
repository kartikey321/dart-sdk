// dart:io echo server — baseline for benchmark comparison.
// Run with stock dart:  dart lib/dart_io_echo.dart [port]
// Run with dart-zig:   ./zig-out/bin/dart-zig test-snapshots/dart_io_echo.dill [port]
//
// Note: dart:io is wired up by the DartEngine, so this also works under dart-zig.

// ignore_for_file: unawaited_futures

import 'dart:async';
import 'dart:io';

Future<void> _handleConn(Socket socket) async {
  await socket.forEach((data) => socket.add(data));
  await socket.close();
}

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.parse(args[0]) : 8081;

  final server = await ServerSocket.bind('0.0.0.0', port);
  print('dart:io echo server on port $port');

  await for (final socket in server) {
    socket.setOption(SocketOption.tcpNoDelay, true);
    _handleConn(socket);
  }
}
