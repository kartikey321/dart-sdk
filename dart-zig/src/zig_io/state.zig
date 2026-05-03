/// Shared state between the native I/O layer and the event-loop backends.
/// Both io_uring.zig (Linux) and kqueue.zig (macOS) embed a `completion_pool`
/// and register themselves via `current_loop` at the start of `run()`.
const std = @import("std");
const posix = std.posix;
const engine = @import("../engine.zig");

pub const kPoolSize: usize = 4096;
/// user_data/udata values 1-15 are reserved for system ops
/// (notify=1, timeout=2, signal=3).  Pool slots start at 16.
pub const kPoolBase: u64 = 16;

/// Maximum bytes per recv or send buffer embedded in the pool slot.
/// 4096 slots × 8 KB = 32 MB total — stays resident in L3 cache.
pub const kBufSize: usize = 8192;

pub const Op = enum(u8) { accept, recv, recv_route, serve, loop, send, tls_handshake };

pub const CompletionCtx = struct {
    in_use: bool = false,
    op: Op = .accept,
    port_id: engine.Dart_Port = 0,
    fd: posix.fd_t = -1,
    tls_id: u16 = 0,
    data: Data = .{ .accept = .{} },

    pub const Data = union(Op) {
        /// accept: stores the listen fd so the CQE handler can immediately re-arm.
        accept: struct { listen_fd: posix.fd_t = -1 },
        /// Pre-allocated receive buffer embedded in the slot.
        /// Filled by the kernel (io_uring) or posix.read (kqueue).
        /// Immediately reusable after postRecvResult posts a kTypedData copy.
        recv: RecvData,
        /// Like recv but parses + routes in Zig before posting.
        /// Posts a route int (RouteId) instead of a Uint8List — zero Dart heap alloc.
        recv_route: RecvData,
        /// Fused read+route+write in one async op.
        /// Phase 1 (write_phase=false): recv into recv_buf.
        /// Phase 2 (write_phase=true): write static response remainder via SQE/kevent.
        /// Posts 0 (keep-alive) or -1 (close) to Dart — one await per request.
        serve: ServeData,
        /// Keep-alive connection loop: handles the entire connection lifetime in Zig.
        /// recv → route → write → memmove → loop (pipelining), repeat.
        /// Only posts to Dart on close/error — one await per connection, zero per request.
        loop: ServeData,
        /// Pre-allocated send buffer embedded in the slot.
        /// Filled by ZigIo_TcpWriteBytes via @memcpy from Dart Uint8List.
        send: SendData,
        /// TLS handshake state is kept in zig_io/tls.zig.
        tls_handshake: void,
    };

    pub const RecvData = struct {
        buf: [kBufSize]u8 = undefined,
    };
    pub const ServeData = struct {
        recv_buf: [kBufSize]u8 = undefined,
        /// Bytes accumulated so far in recv_buf (for multi-read request assembly).
        recv_len: usize = 0,
        /// Points into http/responses.zig comptime slices — no heap alloc.
        write_ptr: [*]const u8 = undefined,
        write_len: usize = 0,
        /// false = waiting for recv; true = waiting for partial-write remainder.
        write_phase: bool = false,
        /// Set after routing: close connection after write completes.
        should_close: bool = false,
        /// Bytes consumed by the current request (body_offset of the request
        /// being written). Used by Op.loop to memmove past the request after
        /// a partial write completes.
        pending_consumed: usize = 0,
    };
    pub const SendData = struct {
        buf: [kBufSize]u8 = undefined,
        len: usize = 0,
    };
};

/// Vtable that lets tcp.zig submit I/O without knowing the concrete backend.
pub const LoopOps = struct {
    submit_accept: *const fn (loop: *anyopaque, slot_idx: usize, fd: posix.fd_t) void,
    submit_recv: *const fn (loop: *anyopaque, slot_idx: usize, fd: posix.fd_t) void,
    /// submit_recv_route reuses the same I/O path as submit_recv.
    /// The op field on the slot distinguishes how the completion is dispatched.
    submit_recv_route: *const fn (loop: *anyopaque, slot_idx: usize, fd: posix.fd_t) void,
    /// Fused read+route+write — arms a recv; completion handler routes and writes inline.
    submit_serve: *const fn (loop: *anyopaque, slot_idx: usize, fd: posix.fd_t) void,
    /// Keep-alive connection loop — entire connection lifecycle in Zig; posts only on close.
    submit_loop: *const fn (loop: *anyopaque, slot_idx: usize, fd: posix.fd_t) void,
    submit_send: *const fn (loop: *anyopaque, slot_idx: usize, fd: posix.fd_t, buf: []u8) void,
};

pub const LoopRef = struct {
    ptr: *anyopaque,
    ops: *const LoopOps,
    pool: *[kPoolSize]CompletionCtx,
    slot_alloc: *SlotAllocator,
    /// Points into the EventLoop struct; ZigIo_SetBatchPort writes through this.
    batch_port_ptr: *engine.Dart_Port,
};

/// Set at the top of `run()` in each backend; read by tcp.zig natives.
/// Safe because Dart native functions execute on the event-loop thread.
pub threadlocal var current_loop: ?LoopRef = null;

/// O(1) free-list allocator for completion pool slots.
/// Avoids scanning all 4096 slots on every submit.
pub const SlotAllocator = struct {
    free_stack: [kPoolSize]u16 = undefined,
    free_len: usize = 0,

    pub fn init(self: *SlotAllocator) void {
        var i: usize = 0;
        while (i < kPoolSize) : (i += 1) {
            // Pop from the end => 0,1,2,... allocation order.
            self.free_stack[i] = @intCast(kPoolSize - 1 - i);
        }
        self.free_len = kPoolSize;
    }
};

/// Find a free slot in the pool, mark it in_use, return its index.
pub fn allocSlot(pool: *[kPoolSize]CompletionCtx, slots: *SlotAllocator) ?usize {
    if (slots.free_len == 0) return null;
    slots.free_len -= 1;
    const idx: usize = @intCast(slots.free_stack[slots.free_len]);
    std.debug.assert(!pool[idx].in_use);
    pool[idx].in_use = true;
    return idx;
}

/// Mark a slot as free.
pub fn freeSlot(pool: *[kPoolSize]CompletionCtx, slots: *SlotAllocator, idx: usize) void {
    std.debug.assert(pool[idx].in_use);
    std.debug.assert(slots.free_len < kPoolSize);
    pool[idx].in_use = false;
    slots.free_stack[slots.free_len] = @intCast(idx);
    slots.free_len += 1;
}

/// Post a route integer (recv_route result) directly — no Uint8List, no memcpy.
/// route < -2 means EOF/error (use RouteId.eof = -3).
pub fn postRouteResult(port_id: engine.Dart_Port, route: i64) void {
    var obj = engine.Dart_CObject{
        .@"type" = engine.Dart_CObject_kInt64,
        .value = .{ .as_int64 = route },
    };
    _ = engine.Dart_PostCObject(port_id, &obj);
}

/// Post the result of a recv operation to a Dart SendPort.
/// - n > 0  → post kTypedData copying buf[0..n] into a Dart Uint8List.
///            buf is a slice of the pool slot's embedded [kBufSize]u8 — it is
///            immediately reusable after this call (Dart_PostCObject serializes
///            the bytes into the isolate message queue synchronously).
/// - n <= 0 → post kNull (EOF or error). No buffer involved.
pub fn postRecvResult(port_id: engine.Dart_Port, n: isize, buf: []const u8) void {
    if (n > 0) {
        var obj = engine.Dart_CObject{
            .@"type" = engine.Dart_CObject_kTypedData,
            .value = .{ .as_typed_data = .{
                .data_type = engine.Dart_TypedData_kUint8,
                .length = n,
                .values = buf.ptr,
            } },
        };
        _ = engine.Dart_PostCObject(port_id, &obj);
    } else {
        var obj = engine.Dart_CObject{
            .@"type" = engine.Dart_CObject_kNull,
            .value = .{ .as_int64 = 0 },
        };
        _ = engine.Dart_PostCObject(port_id, &obj);
    }
}
