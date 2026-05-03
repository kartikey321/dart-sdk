// dart-zig HttpServer abstraction example — dart:io-style API over io_uring.
// Run with: ./zig-out/bin/dart-zig test-snapshots/zig_http_server_example.dill [port]

import 'dart:async';
import 'zig_http_server.dart';

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.parse(args[0]) : 8080;
  final server = await ZigHttpServer.bind('0.0.0.0', port);
  print('ZigHttpServer on port $port');

  final done = Completer<void>();

  server.stream.listen(
    (req) {
      switch (req.path) {
        case '/':
        case '/index.html':
          req.response
            ..statusCode = 200
            ..write('Hello from ZigHttpServer!')
            ..close();
          break;
        case '/ping':
          req.response
            ..statusCode = 200
            ..write('pong')
            ..close();
          break;
        default:
          req.response
            ..statusCode = 404
            ..write('Not Found: ${req.path}')
            ..close();
      }
    },
    onDone: done.complete,
  );

  await done.future;
}
