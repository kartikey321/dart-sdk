/// Shared state between the native I/O layer and the event-loop backends.
/// Both io_uring.zig (Linux) and kqueue.zig (macOS) embed a `completion_pool`
/// and register themselves via `current_loop` at the start of `run()`.
const std = @import("std");
const posix = std.posix;
const engine = @import("../engine.zig");

pub const kPoolSize: usize = 256;
/// user_data/udata values 1-15 are reserved for system ops
/// (notify=1, timeout=2, signal=3).  Pool slots start at 16.
pub const kPoolBase: u64 = 16;

/// Maximum bytes per recv or send buffer embedded in the pool slot.
/// 256 slots × 8 KB = 2 MB total — stays resident in L3 cache.
pub const kBufSize: usize = 8192;

pub const Op = enum(u8) { accept, recv, send };

pub const CompletionCtx = struct {
    in_use: bool = false,
    op: Op = .accept,
    port_id: engine.Dart_Port = 0,
    fd: posix.fd_t = -1,
    data: Data = .{ .accept = {} },

    pub const Data = union(Op) {
        /// accept needs no extra data: we pass null addr/addrlen to accept().
        accept: void,
        /// Pre-allocated receive buffer embedded in the slot.
        /// Filled by the kernel (io_uring) or posix.read (kqueue).
        /// Immediately reusable after postRecvResult posts a kTypedData copy.
        recv: RecvData,
        /// Pre-allocated send buffer embedded in the slot.
        /// Filled by ZigIo_TcpWriteBytes via @memcpy from Dart Uint8List.
        send: SendData,
    };

    pub const RecvData = struct {
        buf: [kBufSize]u8 = undefined,
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
    submit_send: *const fn (loop: *anyopaque, slot_idx: usize, fd: posix.fd_t, buf: []u8) void,
};

pub const LoopRef = struct {
    ptr: *anyopaque,
    ops: *const LoopOps,
    pool: *[kPoolSize]CompletionCtx,
    slot_alloc: *SlotAllocator,
};

/// Set at the top of `run()` in each backend; read by tcp.zig natives.
/// Safe because Dart native functions execute on the event-loop thread.
pub threadlocal var current_loop: ?LoopRef = null;

/// O(1) free-list allocator for completion pool slots.
/// Avoids scanning all 256 slots on every submit.
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
