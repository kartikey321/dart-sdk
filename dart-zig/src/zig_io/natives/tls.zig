const std = @import("std");
const posix = std.posix;
const engine = @import("../../engine.zig");
const state = @import("../state.zig");
const tls = @import("../tls.zig");

fn postTokenTlsInt(loop: state.LoopRef, token: i64, int_val: i64) void {
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

fn postTokenTlsNull(loop: state.LoopRef, token: i64) void {
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

fn postTokenTlsBytes(loop: state.LoopRef, token: i64, bytes: []const u8) void {
    if (loop.batch_port_ptr.* == 0) return;

    var token_obj = engine.Dart_CObject{
        .@"type" = engine.Dart_CObject_kInt64,
        .value = .{ .as_int64 = token },
    };
    var value_obj = engine.Dart_CObject{
        .@"type" = engine.Dart_CObject_kTypedData,
        .value = .{ .as_typed_data = .{
            .data_type = engine.Dart_TypedData_kUint8,
            .length = @intCast(bytes.len),
            .values = bytes.ptr,
        } },
    };
    var ptrs = [2]?*engine.Dart_CObject{ &token_obj, &value_obj };
    var obj = engine.Dart_CObject{
        .@"type" = engine.Dart_CObject_kArray,
        .value = .{ .as_array = .{ .length = 2, .values = ptrs[0..].ptr } },
    };
    _ = engine.Dart_PostCObject(loop.batch_port_ptr.*, &obj);
}

fn parseTlsId(raw: i64) ?u16 {
    if (raw <= 0) return null;
    if (raw > std.math.maxInt(u16)) return null;
    return @intCast(raw);
}

pub fn ZigTls_Configure(args: engine.Dart_NativeArguments) callconv(.c) void {
    var cert_peer: ?*anyopaque = null;
    const cert_handle = engine.Dart_GetNativeStringArgument(args, 0, &cert_peer);
    if (engine.Dart_IsError(cert_handle)) {
        engine.Dart_SetIntegerReturnValue(args, -1);
        return;
    }

    var key_peer: ?*anyopaque = null;
    const key_handle = engine.Dart_GetNativeStringArgument(args, 1, &key_peer);
    if (engine.Dart_IsError(key_handle)) {
        engine.Dart_SetIntegerReturnValue(args, -1);
        return;
    }

    var cert_cstr: [*:0]const u8 = undefined;
    if (engine.Dart_IsError(engine.Dart_StringToCString(cert_handle, &cert_cstr))) {
        engine.Dart_SetIntegerReturnValue(args, -1);
        return;
    }

    var key_cstr: [*:0]const u8 = undefined;
    if (engine.Dart_IsError(engine.Dart_StringToCString(key_handle, &key_cstr))) {
        engine.Dart_SetIntegerReturnValue(args, -1);
        return;
    }

    const rc = tls.configure(std.mem.span(cert_cstr), std.mem.span(key_cstr));
    engine.Dart_SetIntegerReturnValue(args, rc);
}

pub fn ZigTls_UpgradeToken(args: engine.Dart_NativeArguments) callconv(.c) void {
    var fd_val: i64 = 0;
    _ = engine.Dart_GetNativeIntegerArgument(args, 0, &fd_val);

    var token: i64 = 0;
    _ = engine.Dart_GetNativeIntegerArgument(args, 1, &token);

    const loop = state.current_loop orelse return;
    const fd: posix.fd_t = @intCast(fd_val);

    const tls_id = tls.allocConn(fd);
    if (tls_id == 0) {
        postTokenTlsInt(loop, token, -1);
        return;
    }

    const idx = state.allocSlot(loop.pool, loop.slot_alloc) orelse {
        tls.freeConn(tls_id);
        postTokenTlsInt(loop, token, -1);
        return;
    };

    const ctx = &loop.pool[idx];
    ctx.op = .tls_handshake;
    ctx.port_id = token;
    ctx.fd = fd;
    ctx.tls_id = tls_id;
    ctx.data = .{ .tls_handshake = {} };

    const hs0 = tls.advanceHandshake(tls_id);
    switch (hs0) {
        .done => {
            postTokenTlsInt(loop, token, tls_id);
            state.freeSlot(loop.pool, loop.slot_alloc, idx);
        },
        .want_read, .want_write => {
            loop.ops.submit_recv(loop.ptr, idx, fd);
        },
        .err => {
            postTokenTlsInt(loop, token, -1);
            state.freeSlot(loop.pool, loop.slot_alloc, idx);
            tls.freeConn(tls_id);
        },
    }
}

pub fn ZigTls_ReadToken(args: engine.Dart_NativeArguments) callconv(.c) void {
    var tls_id_raw: i64 = 0;
    _ = engine.Dart_GetNativeIntegerArgument(args, 0, &tls_id_raw);

    var max_val: i64 = state.kBufSize;
    _ = engine.Dart_GetNativeIntegerArgument(args, 1, &max_val);

    var token: i64 = 0;
    _ = engine.Dart_GetNativeIntegerArgument(args, 2, &token);

    const loop = state.current_loop orelse return;
    const tls_id = parseTlsId(tls_id_raw) orelse {
        postTokenTlsNull(loop, token);
        return;
    };

    const fd = tls.getFd(tls_id) orelse {
        postTokenTlsNull(loop, token);
        return;
    };

    const idx = state.allocSlot(loop.pool, loop.slot_alloc) orelse {
        postTokenTlsNull(loop, token);
        return;
    };

    const ctx = &loop.pool[idx];
    ctx.op = .recv;
    ctx.port_id = token;
    ctx.fd = fd;
    ctx.tls_id = tls_id;
    ctx.data = .{ .recv = .{} };

    // If SSL already has plaintext buffered (data arrived during handshake),
    // deliver it immediately without waiting for a kqueue event.
    if (tls.pendingPlaintext(tls_id) > 0) {
        const n = tls.readPlaintext(tls_id, ctx.data.recv.buf[0..]);
        if (n > 0) {
            postTokenTlsBytes(loop, token, ctx.data.recv.buf[0..@intCast(n)]);
        } else {
            postTokenTlsNull(loop, token);
        }
        state.freeSlot(loop.pool, loop.slot_alloc, idx);
        return;
    }

    loop.ops.submit_recv(loop.ptr, idx, fd);
}

pub fn ZigTls_WriteBytesToken(args: engine.Dart_NativeArguments) callconv(.c) void {
    var tls_id_raw: i64 = 0;
    _ = engine.Dart_GetNativeIntegerArgument(args, 0, &tls_id_raw);

    const list = engine.Dart_GetNativeArgument(args, 1);

    var token: i64 = 0;
    _ = engine.Dart_GetNativeIntegerArgument(args, 2, &token);

    const loop = state.current_loop orelse return;
    const tls_id = parseTlsId(tls_id_raw) orelse {
        postTokenTlsInt(loop, token, -1);
        return;
    };

    var data_type: c_int = 0;
    var data_ptr: ?*anyopaque = null;
    var data_len: isize = 0;
    const acq = engine.Dart_TypedDataAcquireData(list, &data_type, &data_ptr, &data_len);
    if (engine.Dart_IsError(acq) or data_ptr == null) {
        _ = engine.Dart_TypedDataReleaseData(list);
        postTokenTlsInt(loop, token, -1);
        return;
    }

    if (data_len <= 0) {
        _ = engine.Dart_TypedDataReleaseData(list);
        postTokenTlsInt(loop, token, 0);
        return;
    }

    const bytes = @as([*]u8, @ptrCast(data_ptr.?))[0..@intCast(data_len)];
    const n = tls.writePlaintext(tls_id, bytes);
    _ = engine.Dart_TypedDataReleaseData(list);
    postTokenTlsInt(loop, token, n);
}

pub fn ZigTls_Close(args: engine.Dart_NativeArguments) callconv(.c) void {
    var tls_id_raw: i64 = 0;
    _ = engine.Dart_GetNativeIntegerArgument(args, 0, &tls_id_raw);

    const tls_id = parseTlsId(tls_id_raw) orelse return;
    tls.freeConn(tls_id);
}
