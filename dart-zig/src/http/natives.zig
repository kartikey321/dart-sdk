const engine = @import("../engine.zig");
const parser = @import("parser.zig");

/// ZigHttp_RouteRequest(bytes: Uint8List) → int  (synchronous native)
///
/// Parses the HTTP request AND resolves it to a route integer — no Dart heap
/// allocation.  The caller switches on the returned int to pick a pre-built
/// response Uint8List.
///
/// Return values (must match lib/zig_http.dart RouteId constants):
///   0  → hello  (GET /  or  GET /index.html)
///   1  → ping   (GET /ping)
///  -1  → 404 Not Found
///  -2  → 400 Bad Request / incomplete
pub fn ZigHttp_RouteRequest(args: engine.Dart_NativeArguments) callconv(.c) void {
    const bytes_handle = engine.Dart_GetNativeArgument(args, 0);

    var data_type: c_int = 0;
    var data_ptr: ?*anyopaque = null;
    var data_len: isize = 0;
    const acq = engine.Dart_TypedDataAcquireData(bytes_handle, &data_type, &data_ptr, &data_len);
    if (engine.Dart_IsError(acq) or data_ptr == null or data_len <= 0) {
        _ = engine.Dart_TypedDataReleaseData(bytes_handle);
        engine.Dart_SetIntegerReturnValue(args, parser.RouteId.bad_request);
        return;
    }

    const buf: []const u8 = @as([*]const u8, @ptrCast(data_ptr.?))[0..@intCast(data_len)];
    const route_id = parser.routeRequest(buf);
    _ = engine.Dart_TypedDataReleaseData(bytes_handle);

    engine.Dart_SetIntegerReturnValue(args, route_id);
}

/// ZigHttp_Parse(bytes: Uint8List) → List<Object?>?   (synchronous native)
///
/// Parses an HTTP/1.1 request from the raw byte buffer.
/// Returns List[method, path, bodyOffset] on success, Dart null if incomplete or invalid.
///
/// The method and path are copied to stack buffers before releasing the TypedData
/// pin so the Dart GC can move the buffer freely after the call returns.
pub fn ZigHttp_Parse(args: engine.Dart_NativeArguments) callconv(.c) void {
    const bytes_handle = engine.Dart_GetNativeArgument(args, 0);

    var data_type: c_int = 0;
    var data_ptr: ?*anyopaque = null;
    var data_len: isize = 0;
    const acq = engine.Dart_TypedDataAcquireData(bytes_handle, &data_type, &data_ptr, &data_len);
    if (engine.Dart_IsError(acq) or data_ptr == null or data_len <= 0) {
        _ = engine.Dart_TypedDataReleaseData(bytes_handle);
        engine.Dart_SetReturnValue(args, engine.Dart_Null());
        return;
    }

    const buf: []const u8 = @as([*]const u8, @ptrCast(data_ptr.?))[0..@intCast(data_len)];
    const result = parser.parse(buf);

    // Copy method and path to stack buffers while the typed-data pin is held.
    // After ReleaseData the GC is free to move the backing store.
    var method_buf: [16]u8 = undefined; // longest HTTP method: OPTIONS = 7 chars
    var path_buf: [4096]u8 = undefined;
    const method_len = @min(result.method.len, method_buf.len);
    const path_len = @min(result.path.len, path_buf.len);
    if (result.status == .complete) {
        @memcpy(method_buf[0..method_len], result.method[0..method_len]);
        @memcpy(path_buf[0..path_len], result.path[0..path_len]);
    }
    _ = engine.Dart_TypedDataReleaseData(bytes_handle);

    if (result.status != .complete) {
        engine.Dart_SetReturnValue(args, engine.Dart_Null());
        return;
    }

    // Build Dart List<Object?>[method, path, bodyOffset].
    const list = engine.Dart_NewList(3);
    _ = engine.Dart_ListSetAt(list, 0,
        engine.Dart_NewStringFromUTF8(method_buf[0..].ptr, method_len));
    _ = engine.Dart_ListSetAt(list, 1,
        engine.Dart_NewStringFromUTF8(path_buf[0..].ptr, path_len));
    _ = engine.Dart_ListSetAt(list, 2,
        engine.Dart_NewInteger(@intCast(result.body_offset)));
    engine.Dart_SetReturnValue(args, list);
}

/// ZigHttp_FrameRequest(bytes: Uint8List) → List<Object?>?
///
/// Parses and frames one HTTP request from the raw receive buffer.
/// Returns List[method, path, bodyOffset, endOffset, keepAlive, chunked]
/// when a full request is available.
/// Returns null if the buffer is incomplete or invalid.
pub fn ZigHttp_FrameRequest(args: engine.Dart_NativeArguments) callconv(.c) void {
    const bytes_handle = engine.Dart_GetNativeArgument(args, 0);

    var data_type: c_int = 0;
    var data_ptr: ?*anyopaque = null;
    var data_len: isize = 0;
    const acq = engine.Dart_TypedDataAcquireData(bytes_handle, &data_type, &data_ptr, &data_len);
    if (engine.Dart_IsError(acq) or data_ptr == null or data_len <= 0) {
        _ = engine.Dart_TypedDataReleaseData(bytes_handle);
        engine.Dart_SetReturnValue(args, engine.Dart_Null());
        return;
    }

    const buf: []const u8 = @as([*]const u8, @ptrCast(data_ptr.?))[0..@intCast(data_len)];
    const result = parser.frameRequest(buf);

    var method_buf: [16]u8 = undefined;
    var path_buf: [4096]u8 = undefined;
    const method_len = @min(result.method.len, method_buf.len);
    const path_len = @min(result.path.len, path_buf.len);
    if (result.status == .complete) {
        @memcpy(method_buf[0..method_len], result.method[0..method_len]);
        @memcpy(path_buf[0..path_len], result.path[0..path_len]);
    }
    _ = engine.Dart_TypedDataReleaseData(bytes_handle);

    if (result.status != .complete) {
        engine.Dart_SetReturnValue(args, engine.Dart_Null());
        return;
    }

    const list = engine.Dart_NewList(6);
    _ = engine.Dart_ListSetAt(list, 0,
        engine.Dart_NewStringFromUTF8(method_buf[0..].ptr, method_len));
    _ = engine.Dart_ListSetAt(list, 1,
        engine.Dart_NewStringFromUTF8(path_buf[0..].ptr, path_len));
    _ = engine.Dart_ListSetAt(list, 2,
        engine.Dart_NewInteger(@intCast(result.body_offset)));
    _ = engine.Dart_ListSetAt(list, 3,
        engine.Dart_NewInteger(@intCast(result.end_offset)));
    _ = engine.Dart_ListSetAt(list, 4,
        if (result.keep_alive) engine.Dart_True() else engine.Dart_False());
    _ = engine.Dart_ListSetAt(list, 5,
        if (result.chunked) engine.Dart_True() else engine.Dart_False());
    engine.Dart_SetReturnValue(args, list);
}
