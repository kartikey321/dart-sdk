// dart:io HTTPS/1.1 server — benchmark baseline.
// Run with stock dart: dart lib/dart_io_https_server.dart [port]
// Cert paths default to test-certs/ relative to the script's parent directory.

import 'dart:io';

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.parse(args[0]) : 9004;
  final certDir = args.length >= 2 ? args[1] : _defaultCertDir();

  final ctx = SecurityContext()
    ..useCertificateChain('$certDir/cert.pem')
    ..usePrivateKey('$certDir/key.pem');

  final server = await HttpServer.bindSecure('0.0.0.0', port, ctx, shared: true);
  print('dart:io HTTPS server on port $port');
  await for (final req in server) {
    req.response
      ..statusCode = 200
      ..headers.set('Content-Type', 'text/plain; charset=utf-8')
      ..headers.set('Connection', 'keep-alive')
      ..write('Hello from dart:io TLS!')
      ..close();
  }
}

String _defaultCertDir() {
  // Works both when run as source (dart lib/...) and as AOT exe (bin/...).
  final script = Platform.script.toFilePath();
  final libOrBin = script.substring(0, script.lastIndexOf('/'));
  final parent = libOrBin.substring(0, libOrBin.lastIndexOf('/'));
  return '$parent/test-certs';
}
