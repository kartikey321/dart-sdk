// dart:io HTTP/1.1 server — benchmark baseline.
// Run with stock dart: dart lib/dart_io_http_server.dart [port]

import 'dart:io';
import 'dart:convert';

final _response = () {
  final body = utf8.encode('Hello from dart:io!');
  final headers = utf8.encode(
    'HTTP/1.1 200 OK\r\n'
    'Content-Type: text/plain; charset=utf-8\r\n'
    'Content-Length: ${body.length}\r\n'
    'Connection: keep-alive\r\n'
    '\r\n',
  );
  final out = List<int>.from(headers)..addAll(body);
  return out;
}();

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.parse(args[0]) : 9003;
  final server = await HttpServer.bind('0.0.0.0', port, shared: true);
  print('dart:io HTTP server on port $port');
  await for (final req in server) {
    req.response
      ..statusCode = 200
      ..headers.set('Content-Type', 'text/plain; charset=utf-8')
      ..headers.set('Connection', 'keep-alive')
      ..write('Hello from dart:io!')
      ..close();
  }
}
