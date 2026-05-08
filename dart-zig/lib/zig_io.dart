// dart-zig native I/O library.
// Import this file in your Dart program (include it when running gen_kernel).
// All external functions are resolved by the Zig native resolver set in main.zig.

// ignore_for_file: camel_case_types

import 'dart:async' show Completer;
import 'dart:convert' show utf8;
import 'dart:isolate' show RawReceivePort, SendPort;
import 'dart:typed_data' show Uint8List;

// ---------------------------------------------------------------------------
// Version (sync, for wiring verification)
// ---------------------------------------------------------------------------

@pragma('vm:external-name', 'ZigIo_Version')
external String zigIoVersion();

// ---------------------------------------------------------------------------
// Stdout write (sync; on Linux uses io_uring IORING_OP_WRITE, on macOS posix.write)
// ---------------------------------------------------------------------------

/// Write [bytes] to stdout. Returns number of bytes written, or -1 on error.
@pragma('vm:external-name', 'ZigIo_StdoutWrite')
external int zigIoStdoutWrite(List<int> bytes);

// ---------------------------------------------------------------------------
// TCP (async; Dart passes a SendPort, Zig posts result back when io_uring completes)
// ---------------------------------------------------------------------------

/// Bind+listen on [host]:[port]. Returns a file descriptor on success, -errno on error.
@pragma('vm:external-name', 'ZigIo_TcpBind')
external int zigIoTcpBind(String host, int port, int backlog);

/// Submit an async accept on [listenFd].
/// When a connection arrives, posts [connFd, peerAddr] to [sendPort].
@pragma('vm:external-name', 'ZigIo_TcpAccept')
external void zigIoTcpAccept(int listenFd, SendPort sendPort);

/// Submit an async read on [connFd] of up to [maxBytes] bytes.
/// Posts a [Uint8List] on success, or null on EOF/error, to [sendPort].
@pragma('vm:external-name', 'ZigIo_TcpRead')
external void zigIoTcpRead(int connFd, int maxBytes, SendPort sendPort);

/// Submit an async write of [bytes] (List<int>) to [connFd].
/// Posts bytes-written count (int) to [sendPort] on completion.
@pragma('vm:external-name', 'ZigIo_TcpWrite')
external void zigIoTcpWrite(int connFd, List<int> bytes, SendPort sendPort);

/// Like [zigIoTcpWrite] but takes a [Uint8List] — more efficient (single memcpy).
/// Posts bytes-written count (int) to [sendPort] on completion.
@pragma('vm:external-name', 'ZigIo_TcpWriteBytes')
external void zigIoTcpWriteBytes(int connFd, Uint8List bytes, SendPort sendPort);

/// Close a file descriptor.
@pragma('vm:external-name', 'ZigIo_Close')
external void zigIoClose(int fd);

// ---------------------------------------------------------------------------
// Batch dispatcher (Phase 14) — one RawReceivePort, token map, one kArray
// message per kevent() batch instead of N individual messages.
// ---------------------------------------------------------------------------


@pragma('vm:external-name', 'ZigIo_SetBatchPort')
external void _zigIoSetBatchPort(SendPort port);

@pragma('vm:external-name', 'ZigIo_TcpAcceptToken')
external void _zigIoTcpAcceptToken(int listenFd, int token);

@pragma('vm:external-name', 'ZigIo_TcpReadToken')
external void _zigIoTcpReadToken(int connFd, int maxBytes, int token);

@pragma('vm:external-name', 'ZigIo_TcpReadRequestToken')
external void _zigIoTcpReadRequestToken(int connFd, int token);

@pragma('vm:external-name', 'ZigIo_TcpServeToken')
external void _zigIoTcpServeToken(int connFd, int token);

@pragma('vm:external-name', 'ZigIo_TcpReadRouteToken')
external void _zigIoTcpReadRouteToken(int connFd, int token);

@pragma('vm:external-name', 'ZigIo_TcpWriteBytesToken')
external void _zigIoTcpWriteBytesToken(int connFd, Uint8List bytes, int token);

@pragma('vm:external-name', 'ZigIo_TcpLoopToken')
external void _zigIoTcpLoopToken(int connFd, int token);

/// Per-isolate batch dispatcher. Initialised lazily on first token I/O call.
/// All completions from one kevent() batch arrive in one List message,
/// reducing DartEngine_HandleMessage call count from N to 1.
/// Exported so that zig_tls.dart can reuse the same batch port.
late final _dispatcher = _ZigIoDispatcher();

// Package-accessible alias used by zig_tls.dart.
// ignore: library_private_types_in_public_api
_ZigIoDispatcher get zigIoDispatcher => _dispatcher;

class _ZigIoDispatcher {
  final RawReceivePort _port = RawReceivePort();
  final Map<int, Completer<Object?>> _pending = {};
  int _counter = 0;

  _ZigIoDispatcher() {
    _port.handler = _onBatch;
    _zigIoSetBatchPort(_port.sendPort);
  }

  void _onBatch(Object? msg) {
    final batch = msg as List<Object?>;
    for (int i = 0; i < batch.length; i += 2) {
      final token = batch[i] as int;
      _pending.remove(token)?.complete(batch[i + 1]);
    }
  }

  Future<T> submit<T>(void Function(int token) fn) {
    final token = ++_counter;
    final c = Completer<T>();
    _pending[token] = c as Completer<Object?>;
    fn(token);
    return c.future;
  }
}

class ZigIoFramedRequest {
  final Uint8List methodBytes;
  final Uint8List pathBytes;
  final Uint8List bodyBytes;
  final bool keepAlive;

  const ZigIoFramedRequest(
    this.methodBytes,
    this.pathBytes,
    this.bodyBytes,
    this.keepAlive,
  );
}

/// Accept a connection. Returns connFd.
Future<int> zigIoTcpAcceptFuture(int listenFd) =>
    _dispatcher.submit<int>((t) => _zigIoTcpAcceptToken(listenFd, t));

/// Read up to [maxBytes] from [connFd]. Returns null on EOF/error.
Future<Uint8List?> zigIoTcpReadFuture(int connFd, int maxBytes) =>
    _dispatcher
        .submit<Uint8List?>((t) => _zigIoTcpReadToken(connFd, maxBytes, t))
        .then((v) => v as Uint8List?);

Future<ZigIoFramedRequest?> zigIoTcpReadRequestFuture(int connFd) =>
    _dispatcher
        .submit<Object?>((t) => _zigIoTcpReadRequestToken(connFd, t))
        .then((v) {
      if (v == null) return null;
      final result = v as List<Object?>;
      final flagsObj = result[3];
      final flags = switch (flagsObj) {
        int i => i,
        bool b => b ? 1 : 0,
        _ => 0,
      };
      return ZigIoFramedRequest(
        _asBytes(result[0]),
        _asBytes(result[1]),
        _asBytes(result[2]),
        (flags & 1) != 0,
      );
    });

Uint8List _asBytes(Object? v) {
  if (v == null) return Uint8List(0);
  if (v is Uint8List) return v;
  if (v is List<int>) return Uint8List.fromList(v);
  if (v is String) return Uint8List.fromList(utf8.encode(v));
  throw StateError('Unexpected request field type: ${v.runtimeType}');
}

/// Fused read+route+write in one async op. Returns 0 (keep-alive) or -1 (close).
/// One await per request — eliminates one isolate crossing vs read_route + write.
Future<int> zigIoTcpServeFuture(int connFd) =>
    _dispatcher
        .submit<int>((t) => _zigIoTcpServeToken(connFd, t))
        .then((v) => (v as int?) ?? -1);

/// Keep-alive connection loop: entire connection lifecycle handled in Zig.
/// One await per connection (not per request). Returns -1 when the connection closes.
/// Handles HTTP pipelining automatically — no Dart involvement per request.
Future<int> zigIoTcpLoopFuture(int connFd) =>
    _dispatcher
        .submit<int>((t) => _zigIoTcpLoopToken(connFd, t))
        .then((v) => (v as int?) ?? -1);

/// Read from [connFd], parse+route in Zig. Returns a [RouteId] int.
/// No Uint8List allocation — bytes are parsed entirely in the Zig completion handler.
Future<int> zigIoTcpReadRouteFuture(int connFd) =>
    _dispatcher
        .submit<int>((t) => _zigIoTcpReadRouteToken(connFd, t))
        .then((v) => (v as int?) ?? -3); // -3 = RouteId.eof

/// Write [bytes] to [connFd]. Returns bytes written, or -1 on error.
Future<int> zigIoTcpWriteBytesFuture(int connFd, Uint8List bytes) =>
    _dispatcher
        .submit<int>((t) => _zigIoTcpWriteBytesToken(connFd, bytes, t))
        .then((v) => (v as int?) ?? -1);

// ---------------------------------------------------------------------------
// Per-connection fast path (Phase 11 style) — single RawReceivePort reused
// for all reads/writes on one connection. Uses Dart_PostInteger directly,
// bypassing the batch dispatcher's HashMap lookup overhead.
// ---------------------------------------------------------------------------

/// One-shot accept. Creates a temporary port, fires once, then closes it.
Future<int> zigIoAcceptFuture(int listenFd) {
  final c = Completer<int>();
  final p = RawReceivePort();
  p.handler = (Object? msg) {
    p.close();
    c.complete((msg as int?) ?? -1);
  };
  zigIoTcpAccept(listenFd, p.sendPort);
  return c.future;
}

/// Per-connection wrapper. One [RawReceivePort] is created at construction
/// and reused for every read and write, avoiding per-op port allocation.
class ZigConn {
  final int fd;
  final RawReceivePort _port;
  Completer<Object?>? _pending;

  ZigConn(this.fd) : _port = RawReceivePort() {
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
    zigIoClose(fd);
    _port.close();
  }
}
