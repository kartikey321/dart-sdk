// Minimal benchmark/reference HTTP server for dart-zig.
//
// Current scope:
// - GET /pipeline    -> "ok"
// - GET /baseline11  -> sum of integer query params
//
// This is intentionally narrow. It is meant to serve as a reference benchmark
// app for external harnesses such as HttpArena, starting with pipelined and
// baseline HTTP/1.1 tests.

import 'dart:async';

import 'zig_http_server.dart';

int _sumQuery(Uri uri) {
  var sum = 0;
  for (final value in uri.queryParameters.values) {
    final parsed = int.tryParse(value);
    if (parsed != null) sum += parsed;
  }
  return sum;
}

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.parse(args[0]) : 8080;
  final server = await ZigHttpServer.bind('0.0.0.0', port);
  print('dart-zig benchmark HTTP server on port $port');

  final done = Completer<void>();
  server.stream.listen(
    (req) {
      switch (req.path) {
        case '/pipeline':
          req.response
            ..statusCode = 200
            ..headers.set('content-type', 'text/plain; charset=utf-8')
            ..write('ok')
            ..close();
          break;
        default:
          final uri = req.uri;
          if (uri.path == '/baseline11') {
            req.response
              ..statusCode = 200
              ..headers.set('content-type', 'text/plain; charset=utf-8')
              ..write(_sumQuery(uri))
              ..close();
          } else {
            req.response
              ..statusCode = 404
              ..headers.set('content-type', 'text/plain; charset=utf-8')
              ..write('not found')
              ..close();
          }
      }
    },
    onDone: done.complete,
  );

  await done.future;
}
