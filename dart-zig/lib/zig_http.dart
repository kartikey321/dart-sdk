// dart-zig HTTP/1.1 library — uses ZigHttp_Parse native for zero-allocation parsing.
// Import this alongside zig_io.dart in any server that needs HTTP.

import 'dart:typed_data';

// ---------------------------------------------------------------------------
// Native bindings
// ---------------------------------------------------------------------------

/// Parse an HTTP/1.1 request from raw bytes.
/// Returns [method, path, bodyOffset] on success, null if incomplete/invalid.
@pragma('vm:external-name', 'ZigHttp_Parse')
external List<Object?>? _zigHttpParse(Uint8List bytes);

/// Parse and frame one HTTP/1.1 request from raw bytes.
/// Returns [method, path, bodyOffset, endOffset, keepAlive, chunked] on
/// success, null if incomplete/invalid.
@pragma('vm:external-name', 'ZigHttp_FrameRequest')
external List<Object?>? _zigHttpFrameRequest(Uint8List bytes);

/// Parse AND route in one Zig call — zero heap allocation.
/// Returns a [RouteId] integer constant.
@pragma('vm:external-name', 'ZigHttp_RouteRequest')
external int _zigHttpRouteRequest(Uint8List bytes);

// ---------------------------------------------------------------------------
// Fast route API (preferred for hot-path servers)
// ---------------------------------------------------------------------------

/// Route IDs returned by [zigHttpRoute]. Must stay in sync with
/// parser.zig RouteId constants.
abstract final class RouteId {
  static const int hello      =  0; // GET /  or  GET /index.html
  static const int ping       =  1; // GET /ping
  static const int notFound   = -1; // valid request, unrecognised path
  static const int badRequest = -2; // malformed or incomplete
  static const int eof        = -3; // connection closed or read error
  static const int incomplete = -4; // need more data (serve op re-arms recv internally)
}

/// Returns a [RouteId] constant — no Dart heap allocation in the hot path.
int zigHttpRoute(Uint8List bytes) => _zigHttpRouteRequest(bytes);

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Immutable parsed HTTP/1.1 request.
/// `rawBytes` is the full receive buffer (headers + body).
/// All string fields are sliced/copied by the Zig parser — no Dart scanning needed.
class HttpRequest {
  final String method;
  final String path;

  /// Byte offset in [rawBytes] where the body begins (after the blank line).
  final int bodyOffset;

  /// The raw receive buffer.  Body = rawBytes.sublist(bodyOffset).
  final Uint8List rawBytes;

  const HttpRequest(this.method, this.path, this.bodyOffset, this.rawBytes);

  /// Body bytes (zero-copy subview of [rawBytes]).
  Uint8List get body => rawBytes.sublist(bodyOffset);

  /// True if the request has a non-empty body.
  bool get hasBody => bodyOffset < rawBytes.length;

  @override
  String toString() => '$method $path (body=${rawBytes.length - bodyOffset}B)';
}

/// Parse an HTTP/1.1 request from [bytes].
/// Returns null if the data is incomplete or malformed.
HttpRequest? parseHttpRequest(Uint8List bytes) {
  final result = _zigHttpParse(bytes);
  if (result == null) return null;
  return HttpRequest(
    result[0]! as String,
    result[1]! as String,
    result[2]! as int,
    bytes,
  );
}

class FramedHttpRequest {
  final String method;
  final String path;
  final int bodyOffset;
  final int endOffset;
  final bool keepAlive;
  final bool chunked;
  final Uint8List rawBytes;

  const FramedHttpRequest(
    this.method,
    this.path,
    this.bodyOffset,
    this.endOffset,
    this.keepAlive,
    this.chunked,
    this.rawBytes,
  );
}

FramedHttpRequest? frameHttpRequest(Uint8List bytes) {
  final result = _zigHttpFrameRequest(bytes);
  if (result == null) return null;
  return FramedHttpRequest(
    result[0]! as String,
    result[1]! as String,
    result[2]! as int,
    result[3]! as int,
    result[4]! as bool,
    result[5]! as bool,
    bytes,
  );
}
