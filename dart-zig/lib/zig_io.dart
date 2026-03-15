// dart-zig native I/O library.
// Import this file in your Dart program (include it when running gen_kernel).
// All external functions are resolved by the Zig native resolver set in main.zig.

// ignore_for_file: camel_case_types

import 'dart:isolate' show SendPort;
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
