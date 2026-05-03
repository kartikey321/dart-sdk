const std = @import("std");
const posix = std.posix;
const engine = @import("../../engine.zig");
const state = @import("../state.zig");
const profiler = @import("../../profiler.zig");
const http_parser = @import("../../http/parser.zig");
const http_responses = @import("../../http/responses.zig");

/// ZigIo_TcpBind(host: String, port: int, backlog: int) → int (fd or -errno)
/// Synchronous: creates, binds, and listens a TCP socket. Returns fd on success.
pub fn ZigIo_TcpBind(args: engine.Dart_NativeArguments) callconv(.c) void {
    var host_peer: ?*anyopaque = null;
    const host_handle = engine.Dart_GetNativeStringArgument(args, 0, &host_peer);
    if (engine.Dart_IsError(host_handle)) {
        engine.Dart_SetIntegerReturnValue(args, -1);
        return;
    }
    var host_cstr: [*:0]const u8 = undefined;
    _ = engine.Dart_StringToCString(host_handle, &host_cstr);
    const host = std.mem.span(host_cstr);

    var port_val: i64 = 0;
    _ = engine.Dart_GetNativeIntegerArgument(args, 1, &port_val);

    var backlog_val: i64 = 128;
    _ = engine.Dart_GetNativeIntegerArgument(args, 2, &backlog_val);

    const fd = tcpBind(host, @intCast(port_val), @intCast(backlog_val)) catch |err| {
        engine.Dart_SetIntegerReturnValue(args, -@as(i64, @intFromError(err)));
        return;
    };
    engine.Dart_SetIntegerReturnValue(args, fd);
}

fn tcpBind(host: []const u8, port: u16, backlog: u31) !i64 {
    const addr = try std.net.Address.parseIp(host, port);
    // NONBLOCK: required for kqueue readiness-based accept without blocking.
    // On Linux with io_uring, a non-blocking listen socket also works fine.
    const sock = try posix.socket(
        addr.any.family,
        posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK,
        0,
    );
    errdefer posix.close(sock);

    try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    // SO_REUSEPORT: allows N workers to each bind their own socket to the same
    // port. The kernel distributes incoming connections across all listeners
    // with zero cross-thread coordination (Phase 12 multicore).
    try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
    try posix.bind(sock, &addr.any, addr.getOsSockLen());
    try posix.listen(sock, backlog);

    return sock;
}

// ---------------------------------------------------------------------------
// Token completion helpers
//
// These post a 2-element kArray [token, value] to the batch port so the Dart
// _ZigIoDispatcher._onBatch handler can resolve the correct Completer.
// They are used on error / fast-path exits where no pool slot is submitted,
// guaranteeing that every token submission produces exactly one completion.
// No-ops if the batch port has not yet been initialised (batch_port_ptr == 0),
// which can only happen if ZigIo_SetBatchPort has not been called — a
// programming error that is not reachable during normal operation.
// ---------------------------------------------------------------------------

/// Post [token, int_val] to the batch port.
fn postTokenInt(loop: state.LoopRef, token: i64, int_val: i64) void {
    if (loop.batch_port_ptr.* == 0) return;
    var token_obj = engine.Dart_CObject{
        .@"type" = engine.Dart_CObject_kInt64,
        .value = .{ .as_int64 = token },
    };
    var value_obj = engine.Dart_CObject{
        .@"type" = engine.Dart_CObject_kInt64,
        .value = .{ .as_int64 = int_val },
    };
    var ptrs = [2]?*engine.Dart_CObject{ &token_obj, &value_obj };
    var obj = engine.Dart_CObject{
        .@"type" = engine.Dart_CObject_kArray,
        .value = .{ .as_array = .{ .length = 2, .values = ptrs[0..].ptr } },
    };
    _ = engine.Dart_PostCObject(loop.batch_port_ptr.*, &obj);
}

/// Post [token, null] to the batch port (EOF / recv error sentinel).
fn postTokenNull(loop: state.LoopRef, token: i64) void {
    if (loop.batch_port_ptr.* == 0) return;
    var token_obj = engine.Dart_CObject{
        .@"type" = engine.Dart_CObject_kInt64,
        .value = .{ .as_int64 = token },
    };
    var null_obj = engine.Dart_CObject{
        .@"type" = engine.Dart_CObject_kNull,
        .value = .{ .as_int64 = 0 },
    };
    var ptrs = [2]?*engine.Dart_CObject{ &token_obj, &null_obj };
    var obj = engine.Dart_CObject{
        .@"type" = engine.Dart_CObject_kArray,
        .value = .{ .as_array = .{ .length = 2, .values = ptrs[0..].ptr } },
    };
    _ = engine.Dart_PostCObject(loop.batch_port_ptr.*, &obj);
}

/// ZigIo_SetBatchPort(port: SendPort) → void
/// Called once from Dart main() to register the batch dispatch port.
/// After this call, all I/O completions are delivered as one kArray message
/// per kevent() batch rather than as N individual messages.
pub fn ZigIo_SetBatchPort(args: engine.Dart_NativeArguments) callconv(.c) void {
    const port_handle = engine.Dart_GetNativeArgument(args, 0);
    var port_id: engine.Dart_Port = 0;
    if (engine.Dart_IsError(engine.Dart_SendPortGetId(port_handle, &port_id))) return;
    const loop = state.current_loop orelse return;
    loop.batch_port_ptr.* = port_id;
}

/// ZigIo_TcpAcceptToken(listenFd: int, token: int) → void
/// Token-based variant of TcpAccept for use with the batch dispatcher.
pub fn ZigIo_TcpAcceptToken(args: engine.Dart_NativeArguments) callconv(.c) void {
    if (profiler.enabled) profiler.p.onNativeEntry(.accept);
    var fd_val: i64 = 0;
    _ = engine.Dart_GetNativeIntegerArgument(args, 0, &fd_val);
    var token: i64 = 0;
    _ = engine.Dart_GetNativeIntegerArgument(args, 1, &token);

    const loop = state.current_loop orelse return;
    const idx = state.allocSlot(loop.pool, loop.slot_alloc) orelse {
        // Pool exhausted — post -1 immediately so the Dart Completer completes
        // rather than hanging in _ZigIoDispatcher._pending indefinitely.
        postTokenInt(loop, token, -1);
        return;
    };
    const ctx = &loop.pool[idx];
    ctx.op = .accept;
    ctx.port_id = token;
    ctx.fd = @intCast(fd_val);
    ctx.tls_id = 0;
    ctx.data = .{ .accept = .{ .listen_fd = @intCast(fd_val) } };
    if (profiler.enabled) profiler.p.onNativePost();
    loop.ops.submit_accept(loop.ptr, idx, @intCast(fd_val));
}

/// ZigIo_TcpReadToken(connFd: int, maxBytes: int, token: int) → void
/// Token-based variant of TcpRead for use with the batch dispatcher.
pub fn ZigIo_TcpReadToken(args: engine.Dart_NativeArguments) callconv(.c) void {
    if (profiler.enabled) profiler.p.onNativeEntry(.read);
    var fd_val: i64 = 0;
    _ = engine.Dart_GetNativeIntegerArgument(args, 0, &fd_val);
    var max_val: i64 = state.kBufSize;
    _ = engine.Dart_GetNativeIntegerArgument(args, 1, &max_val);
    var token: i64 = 0;
    _ = engine.Dart_GetNativeIntegerArgument(args, 2, &token);

    const loop = state.current_loop orelse return;
    const idx = state.allocSlot(loop.pool, loop.slot_alloc) orelse {
        // Pool exhausted — post null (EOF sentinel) so Dart treats this as a
        // closed connection rather than a permanently pending future.
        postTokenNull(loop, token);
        return;
    };
    const ctx = &loop.pool[idx];
    ctx.op = .recv;
    ctx.port_id = token;
    ctx.fd = @intCast(fd_val);
    ctx.tls_id = 0;
    ctx.data = .{ .recv = .{} };
    if (profiler.enabled) profiler.p.onNativePost();
    loop.ops.submit_recv(loop.ptr, idx, @intCast(fd_val));
}

/// ZigIo_TcpServeToken(connFd: int, token: int) → void
/// Fused read+route+write in one async op. Posts 0 (keep-alive) or -1 (close) to Dart.
/// One await per request instead of two — eliminates one Dart isolate crossing + Completer resume.
pub fn ZigIo_TcpServeToken(args: engine.Dart_NativeArguments) callconv(.c) void {
    if (profiler.enabled) profiler.p.onNativeEntry(.read);
    var fd_val: i64 = 0;
    _ = engine.Dart_GetNativeIntegerArgument(args, 0, &fd_val);
    var token: i64 = 0;
    _ = engine.Dart_GetNativeIntegerArgument(args, 1, &token);

    const loop = state.current_loop orelse return;
    const idx = state.allocSlot(loop.pool, loop.slot_alloc) orelse {
        // Pool exhausted (>4096 concurrent connections) — send 503 and signal close.
        // Explicit 503 rather than silent drop so the client gets a proper HTTP error.
        _ = posix.write(@intCast(fd_val), http_responses.service_unavailable) catch {};
        postTokenInt(loop, token, -1);
        return;
    };
    const ctx = &loop.pool[idx];
    ctx.op = .serve;
    ctx.port_id = token;
    ctx.fd = @intCast(fd_val);
    ctx.tls_id = 0;
    ctx.data = .{ .serve = .{} };
    if (profiler.enabled) profiler.p.onNativePost();
    loop.ops.submit_serve(loop.ptr, idx, @intCast(fd_val));
}

/// ZigIo_TcpLoopToken(connFd: int, token: int) → void
/// Keep-alive connection loop: entire connection lifecycle handled in Zig.
/// Only posts to Dart on close/error — one await per connection, zero per request.
/// Handles HTTP pipelining: multiple requests buffered in one recv are all served
/// without re-arming recv, via memmove + immediate re-routing.
pub fn ZigIo_TcpLoopToken(args: engine.Dart_NativeArguments) callconv(.c) void {
    if (profiler.enabled) profiler.p.onNativeEntry(.read);
    var fd_val: i64 = 0;
    _ = engine.Dart_GetNativeIntegerArgument(args, 0, &fd_val);
    var token: i64 = 0;
    _ = engine.Dart_GetNativeIntegerArgument(args, 1, &token);

    const loop = state.current_loop orelse return;
    const idx = state.allocSlot(loop.pool, loop.slot_alloc) orelse {
        // Pool exhausted — send 503 synchronously, post close.
        _ = posix.write(@intCast(fd_val), http_responses.service_unavailable) catch {};
        postTokenInt(loop, token, -1);
        return;
    };
    const ctx = &loop.pool[idx];
    ctx.op = .loop;
    ctx.port_id = token;
    ctx.fd = @intCast(fd_val);
    ctx.tls_id = 0;
    ctx.data = .{ .loop = .{} };
    if (profiler.enabled) profiler.p.onNativePost();
    loop.ops.submit_loop(loop.ptr, idx, @intCast(fd_val));
}

/// ZigIo_TcpReadRouteToken(connFd: int, token: int) → void
/// Read bytes from connFd, parse+route in Zig, post a RouteId int to Dart.
/// Zero Uint8List allocation — eliminates ApiMessageSerializer, memcpy, GC pressure.
pub fn ZigIo_TcpReadRouteToken(args: engine.Dart_NativeArguments) callconv(.c) void {
    if (profiler.enabled) profiler.p.onNativeEntry(.read);
    var fd_val: i64 = 0;
    _ = engine.Dart_GetNativeIntegerArgument(args, 0, &fd_val);
    var token: i64 = 0;
    _ = engine.Dart_GetNativeIntegerArgument(args, 1, &token);

    const loop = state.current_loop orelse return;
    const idx = state.allocSlot(loop.pool, loop.slot_alloc) orelse {
        postTokenInt(loop, token, http_parser.RouteId.eof);
        return;
    };
    const ctx = &loop.pool[idx];
    ctx.op = .recv_route;
    ctx.port_id = token;
    ctx.fd = @intCast(fd_val);
    ctx.tls_id = 0;
    ctx.data = .{ .recv_route = .{} };
    if (profiler.enabled) profiler.p.onNativePost();
    loop.ops.submit_recv_route(loop.ptr, idx, @intCast(fd_val));
}

/// ZigIo_TcpWriteBytesToken(connFd: int, bytes: Uint8List, token: int) → void
/// Token-based variant of TcpWriteBytes for use with the batch dispatcher.
pub fn ZigIo_TcpWriteBytesToken(args: engine.Dart_NativeArguments) callconv(.c) void {
    if (profiler.enabled) profiler.p.onNativeEntry(.write);
    var fd_val: i64 = 0;
    _ = engine.Dart_GetNativeIntegerArgument(args, 0, &fd_val);

    const list = engine.Dart_GetNativeArgument(args, 1);

    var token: i64 = 0;
    _ = engine.Dart_GetNativeIntegerArgument(args, 2, &token);

    var data_type: c_int = 0;
    var data_ptr: ?*anyopaque = null;
    var data_len: isize = 0;
    const acq = engine.Dart_TypedDataAcquireData(list, &data_type, &data_ptr, &data_len);
    if (engine.Dart_IsError(acq)) {
        // AcquireData failed — must NOT call ReleaseData.
        if (state.current_loop) |loop| postTokenInt(loop, token, -1);
        return;
    }
    if (data_ptr == null) {
        _ = engine.Dart_TypedDataReleaseData(list);
        if (state.current_loop) |loop| postTokenInt(loop, token, -1);
        return;
    }
    if (data_len <= 0) {
        _ = engine.Dart_TypedDataReleaseData(list);
        // Empty Uint8List — complete immediately with 0 bytes written.
        // No pool slot needed.
        if (state.current_loop) |loop| postTokenInt(loop, token, 0);
        return;
    }

    const loop = state.current_loop orelse {
        _ = engine.Dart_TypedDataReleaseData(list);
        return;
    };
    const idx = state.allocSlot(loop.pool, loop.slot_alloc) orelse {
        _ = engine.Dart_TypedDataReleaseData(list);
        // Pool exhausted — post error so the Dart future completes.
        postTokenInt(loop, token, -1);
        return;
    };

    const send_len: usize = @min(@as(usize, @intCast(data_len)), state.kBufSize);
    const ctx = &loop.pool[idx];
    ctx.op = .send;
    ctx.port_id = token;
    ctx.fd = @intCast(fd_val);
    ctx.tls_id = 0;
    ctx.data = .{ .send = .{ .len = send_len } };
    @memcpy(ctx.data.send.buf[0..send_len], @as([*]u8, @ptrCast(data_ptr.?))[0..send_len]);
    _ = engine.Dart_TypedDataReleaseData(list);

    if (profiler.enabled) profiler.p.onNativePost();
    loop.ops.submit_send(loop.ptr, idx, @intCast(fd_val), ctx.data.send.buf[0..send_len]);
}

/// ZigIo_TcpAccept(listenFd: int, sendPort: SendPort) → void
/// Submits an async accept via the current event loop backend.
pub fn ZigIo_TcpAccept(args: engine.Dart_NativeArguments) callconv(.c) void {
    if (profiler.enabled) profiler.p.onNativeEntry(.accept);
    var fd_val: i64 = 0;
    _ = engine.Dart_GetNativeIntegerArgument(args, 0, &fd_val);

    const port_handle = engine.Dart_GetNativeArgument(args, 1);
    var port_id: engine.Dart_Port = 0;
    if (engine.Dart_IsError(engine.Dart_SendPortGetId(port_handle, &port_id))) return;

    const loop = state.current_loop orelse {
        _ = engine.Dart_PostInteger(port_id, -1);
        return;
    };
    const idx = state.allocSlot(loop.pool, loop.slot_alloc) orelse {
        _ = engine.Dart_PostInteger(port_id, -1);
        return;
    };
    const ctx = &loop.pool[idx];
    ctx.op = .accept;
    ctx.port_id = port_id;
    ctx.fd = @intCast(fd_val);
    ctx.tls_id = 0;
    ctx.data = .{ .accept = .{ .listen_fd = @intCast(fd_val) } };

    if (profiler.enabled) profiler.p.onNativePost();
    loop.ops.submit_accept(loop.ptr, idx, @intCast(fd_val));
}

/// ZigIo_TcpRead(connFd: int, maxBytes: int, sendPort: SendPort) → void
/// Submits an async read into the pool slot's embedded recv buffer.
/// No heap allocation: buf lives in CompletionCtx.recv.buf ([kBufSize]u8).
pub fn ZigIo_TcpRead(args: engine.Dart_NativeArguments) callconv(.c) void {
    if (profiler.enabled) profiler.p.onNativeEntry(.read);
    var fd_val: i64 = 0;
    _ = engine.Dart_GetNativeIntegerArgument(args, 0, &fd_val);
    var max_val: i64 = state.kBufSize;
    _ = engine.Dart_GetNativeIntegerArgument(args, 1, &max_val);

    const port_handle = engine.Dart_GetNativeArgument(args, 2);
    var port_id: engine.Dart_Port = 0;
    if (engine.Dart_IsError(engine.Dart_SendPortGetId(port_handle, &port_id))) return;

    const loop = state.current_loop orelse {
        state.postRecvResult(port_id, -1, &.{});
        return;
    };
    const idx = state.allocSlot(loop.pool, loop.slot_alloc) orelse {
        state.postRecvResult(port_id, -1, &.{});
        return;
    };

    const ctx = &loop.pool[idx];
    ctx.op = .recv;
    ctx.port_id = port_id;
    ctx.fd = @intCast(fd_val);
    ctx.tls_id = 0;
    ctx.data = .{ .recv = .{} }; // buf is the embedded [kBufSize]u8; no alloc needed
    // maxBytes hint is ignored: the backend reads up to kBufSize bytes.

    if (profiler.enabled) profiler.p.onNativePost();
    loop.ops.submit_recv(loop.ptr, idx, @intCast(fd_val));
}

/// ZigIo_TcpWrite(connFd: int, bytes: List<int>, sendPort: SendPort) → void
/// Submits an async write. Copies bytes into the pool slot's embedded send buffer.
pub fn ZigIo_TcpWrite(args: engine.Dart_NativeArguments) callconv(.c) void {
    if (profiler.enabled) profiler.p.onNativeEntry(.write);
    var fd_val: i64 = 0;
    _ = engine.Dart_GetNativeIntegerArgument(args, 0, &fd_val);

    const list = engine.Dart_GetNativeArgument(args, 1);
    var length: isize = 0;
    _ = engine.Dart_ListLength(list, &length);

    const port_handle = engine.Dart_GetNativeArgument(args, 2);
    var port_id: engine.Dart_Port = 0;
    if (engine.Dart_IsError(engine.Dart_SendPortGetId(port_handle, &port_id))) return;

    if (length <= 0) {
        _ = engine.Dart_PostInteger(port_id, 0);
        return;
    }

    const loop = state.current_loop orelse {
        _ = engine.Dart_PostInteger(port_id, -1);
        return;
    };
    const idx = state.allocSlot(loop.pool, loop.slot_alloc) orelse {
        _ = engine.Dart_PostInteger(port_id, -1);
        return;
    };

    const send_len: usize = @min(@as(usize, @intCast(length)), state.kBufSize);
    const ctx = &loop.pool[idx];
    ctx.op = .send;
    ctx.port_id = port_id;
    ctx.fd = @intCast(fd_val);
    ctx.tls_id = 0;
    ctx.data = .{ .send = .{ .len = send_len } };

    // Copy byte-by-byte from Dart List<int> into embedded send buffer.
    for (ctx.data.send.buf[0..send_len], 0..) |*byte, i| {
        const elem = engine.Dart_ListGetAt(list, @intCast(i));
        var v: i64 = 0;
        _ = engine.Dart_IntegerToInt64(elem, &v);
        byte.* = @intCast(v & 0xff);
    }

    if (profiler.enabled) profiler.p.onNativePost();
    loop.ops.submit_send(loop.ptr, idx, @intCast(fd_val), ctx.data.send.buf[0..send_len]);
}

/// ZigIo_TcpWriteBytes(connFd: int, bytes: Uint8List, sendPort: SendPort) → void
/// Like ZigIo_TcpWrite but takes a Uint8List — single memcpy via TypedDataAcquireData.
/// Copies into the pool slot's embedded send buffer; no heap allocation.
pub fn ZigIo_TcpWriteBytes(args: engine.Dart_NativeArguments) callconv(.c) void {
    var fd_val: i64 = 0;
    _ = engine.Dart_GetNativeIntegerArgument(args, 0, &fd_val);

    const list = engine.Dart_GetNativeArgument(args, 1);

    const port_handle = engine.Dart_GetNativeArgument(args, 2);
    var port_id: engine.Dart_Port = 0;
    if (engine.Dart_IsError(engine.Dart_SendPortGetId(port_handle, &port_id))) return;

    // Acquire raw pointer to the Uint8List's backing store.
    var data_type: c_int = 0;
    var data_ptr: ?*anyopaque = null;
    var data_len: isize = 0;
    const acq = engine.Dart_TypedDataAcquireData(list, &data_type, &data_ptr, &data_len);
    if (engine.Dart_IsError(acq)) {
        // AcquireData failed — must NOT call ReleaseData.
        _ = engine.Dart_PostInteger(port_id, -1);
        return;
    }
    if (data_ptr == null or data_len <= 0) {
        _ = engine.Dart_TypedDataReleaseData(list);
        _ = engine.Dart_PostInteger(port_id, if (data_len <= 0) 0 else -1);
        return;
    }

    const loop = state.current_loop orelse {
        _ = engine.Dart_TypedDataReleaseData(list);
        _ = engine.Dart_PostInteger(port_id, -1);
        return;
    };
    const idx = state.allocSlot(loop.pool, loop.slot_alloc) orelse {
        _ = engine.Dart_TypedDataReleaseData(list);
        _ = engine.Dart_PostInteger(port_id, -1);
        return;
    };

    const send_len: usize = @min(@as(usize, @intCast(data_len)), state.kBufSize);
    const ctx = &loop.pool[idx];
    ctx.op = .send;
    ctx.port_id = port_id;
    ctx.fd = @intCast(fd_val);
    ctx.tls_id = 0;
    ctx.data = .{ .send = .{ .len = send_len } };

    // Single memcpy from Dart heap into embedded send buffer.
    @memcpy(ctx.data.send.buf[0..send_len], @as([*]u8, @ptrCast(data_ptr.?))[0..send_len]);
    _ = engine.Dart_TypedDataReleaseData(list);

    loop.ops.submit_send(loop.ptr, idx, @intCast(fd_val), ctx.data.send.buf[0..send_len]);
}

/// ZigIo_Close(fd: int) → void  (no-scope leaf)
pub fn ZigIo_Close(args: engine.Dart_NativeArguments) callconv(.c) void {
    var fd_val: i64 = 0;
    _ = engine.Dart_GetNativeIntegerArgument(args, 0, &fd_val);
    posix.close(@intCast(fd_val));
}
