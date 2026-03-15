// dart-zig echo server — uses zig_io primitives, no dart:io.
// Compile: gen_kernel --packages=.dart_tool/package_config.json
//          --platform=<sdk>/out/.../vm_platform_strong.dill
//          --aot=false -o test-snapshots/echo_server.dill lib/echo_server.dart
//
// Run: ./zig-out/bin/dart-zig test-snapshots/echo_server.dill [port]

// ignore_for_file: unawaited_futures

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'zig_io.dart';

// ---------------------------------------------------------------------------
// _accept: one-shot port per accept (accepts are infrequent, not hot path)
// ---------------------------------------------------------------------------

Future<int> _accept(int listenFd) {
  final c = Completer<int>();
  final p = RawReceivePort();
  p.handler = (Object? msg) {
    p.close();
    c.complete(msg as int);
  };
  zigIoTcpAccept(listenFd, p.sendPort);
  return c.future;
}

// ---------------------------------------------------------------------------
// _ZigConn: wraps a connection fd with a single RawReceivePort.
// One port multiplexes all read+write completions for a connection.
// Sequential I/O on a connection means at most one pending op at a time.
// ---------------------------------------------------------------------------

class _ZigConn {
  final int fd;
  final RawReceivePort _port;
  Completer<Object?>? _pending;

  _ZigConn(this.fd) : _port = RawReceivePort() {
    _port.handler = (Object? msg) {
      final c = _pending!;
      _pending = null;
      c.complete(msg);
    };
  }

  Future<Uint8List?> read(int maxBytes) {
    _pending = Completer<Object?>();
    zigIoTcpRead(fd, maxBytes, _port.sendPort);
    return _pending!.future.then((v) => v as Uint8List?);
  }

  Future<int> writeBytes(Uint8List bytes) {
    _pending = Completer<Object?>();
    zigIoTcpWriteBytes(fd, bytes, _port.sendPort);
    return _pending!.future.then((v) => (v as int?) ?? -1);
  }

  void close() {
    _port.close();
    zigIoClose(fd);
  }
}

// ---------------------------------------------------------------------------
// Connection handler
// ---------------------------------------------------------------------------

Future<void> _handleConn(int connFd) async {
  final conn = _ZigConn(connFd);
  while (true) {
    final data = await conn.read(4096);
    if (data == null || data.isEmpty) break;
    final written = await conn.writeBytes(data);
    if (written < 0) break;
  }
  conn.close();
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
  print('dart-zig echo server on port $port  (fd=$listenFd)');

  while (true) {
    final connFd = await _accept(listenFd);
    if (connFd < 0) {
      print('accept error: $connFd');
      continue;
    }
    _handleConn(connFd); // fire-and-forget
  }
}
