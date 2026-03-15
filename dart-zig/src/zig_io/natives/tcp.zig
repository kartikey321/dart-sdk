const std = @import("std");
const posix = std.posix;
const engine = @import("../../engine.zig");
const state = @import("../state.zig");

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
    try posix.bind(sock, &addr.any, addr.getOsSockLen());
    try posix.listen(sock, backlog);

    return sock;
}

/// ZigIo_TcpAccept(listenFd: int, sendPort: SendPort) → void
/// Submits an async accept via the current event loop backend.
pub fn ZigIo_TcpAccept(args: engine.Dart_NativeArguments) callconv(.c) void {
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
    ctx.data = .{ .accept = {} };

    loop.ops.submit_accept(loop.ptr, idx, @intCast(fd_val));
}

/// ZigIo_TcpRead(connFd: int, maxBytes: int, sendPort: SendPort) → void
/// Submits an async read into the pool slot's embedded recv buffer.
/// No heap allocation: buf lives in CompletionCtx.recv.buf ([kBufSize]u8).
pub fn ZigIo_TcpRead(args: engine.Dart_NativeArguments) callconv(.c) void {
    var fd_val: i64 = 0;
    _ = engine.Dart_GetNativeIntegerArgument(args, 0, &fd_val);
    var max_val: i64 = state.kBufSize;
    _ = engine.Dart_GetNativeIntegerArgument(args, 1, &max_val);

    const port_handle = engine.Dart_GetNativeArgument(args, 2);
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
    ctx.op = .recv;
    ctx.port_id = port_id;
    ctx.fd = @intCast(fd_val);
    ctx.data = .{ .recv = .{} }; // buf is the embedded [kBufSize]u8; no alloc needed
    // maxBytes hint is ignored: the backend reads up to kBufSize bytes.

    loop.ops.submit_recv(loop.ptr, idx, @intCast(fd_val));
}

/// ZigIo_TcpWrite(connFd: int, bytes: List<int>, sendPort: SendPort) → void
/// Submits an async write. Copies bytes into the pool slot's embedded send buffer.
pub fn ZigIo_TcpWrite(args: engine.Dart_NativeArguments) callconv(.c) void {
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
    ctx.data = .{ .send = .{ .len = send_len } };

    // Copy byte-by-byte from Dart List<int> into embedded send buffer.
    for (ctx.data.send.buf[0..send_len], 0..) |*byte, i| {
        const elem = engine.Dart_ListGetAt(list, @intCast(i));
        var v: i64 = 0;
        _ = engine.Dart_IntegerToInt64(elem, &v);
        byte.* = @intCast(v & 0xff);
    }

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
    if (engine.Dart_IsError(acq) or data_ptr == null or data_len <= 0) {
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
