const builtin = @import("builtin");
comptime {
    if (builtin.os.tag != .linux) @compileError("io_uring requires Linux");
}

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const engine = @import("../engine.zig");
const state = @import("../zig_io/state.zig");

const notify_user_data: u64 = 1;
const timeout_user_data: u64 = 2;
const signal_user_data: u64 = 3;

pub const EventLoop = struct {
    ring: linux.IoUring,
    notify_fd: posix.fd_t,
    signal_fd: posix.fd_t,
    isolate: engine.DartHandle,
    pending: std.atomic.Value(i32),
    notify_buf: u64,
    signal_buf: linux.signalfd_siginfo,
    timeout_ts: linux.kernel_timespec,
    // Heap-allocated: 256 × ~8 KB = 2 MB; too large for the stack.
    pool: *[state.kPoolSize]state.CompletionCtx,
    slot_alloc: state.SlotAllocator,

    pub fn init(isolate: engine.DartHandle) !EventLoop {
        var ring = try linux.IoUring.init(256, 0);
        errdefer ring.deinit();

        const notify_fd = try posix.eventfd(0, linux.EFD.NONBLOCK | linux.EFD.CLOEXEC);
        errdefer posix.close(notify_fd);

        // signalfd: block SIGINT+SIGTERM from default delivery, receive via fd instead.
        // sigprocmask uses posix.sigset_t ([16]c_ulong, 128 bytes).
        // signalfd uses linux.sigset_t ([1]c_ulong, 8 bytes) — build it directly.
        var posix_mask = posix.sigemptyset();
        posix.sigaddset(&posix_mask, posix.SIG.INT);
        posix.sigaddset(&posix_mask, posix.SIG.TERM);
        posix.sigprocmask(posix.SIG.BLOCK, &posix_mask, null);

        // Both SIGINT(2) and SIGTERM(15) fit in the low 64 bits: bit = sig-1.
        const sfd_mask: linux.sigset_t = .{
            (@as(c_ulong, 1) << (@as(u6, @intCast(posix.SIG.INT)) - 1)) |
            (@as(c_ulong, 1) << (@as(u6, @intCast(posix.SIG.TERM)) - 1)),
        };
        const signal_fd_raw = linux.signalfd(-1, &sfd_mask, linux.SFD.NONBLOCK | linux.SFD.CLOEXEC);
        const signal_fd = @as(posix.fd_t, @intCast(signal_fd_raw));
        errdefer posix.close(signal_fd);

        // Heap-allocate the pool (256 × ~8 KB = 2 MB).
        const pool = try std.heap.c_allocator.create([state.kPoolSize]state.CompletionCtx);
        errdefer std.heap.c_allocator.destroy(pool);
        for (pool) |*ctx| ctx.* = .{};

        var loop = EventLoop{
            .ring = ring,
            .notify_fd = notify_fd,
            .signal_fd = signal_fd,
            .isolate = isolate,
            .pending = std.atomic.Value(i32).init(0),
            .notify_buf = 0,
            .signal_buf = std.mem.zeroes(linux.signalfd_siginfo),
            .timeout_ts = .{
                .sec = 0,
                .nsec = 200 * std.time.ns_per_ms,
            },
            .pool = pool,
            .slot_alloc = undefined,
        };
        loop.slot_alloc.init();
        return loop;
    }

    pub fn deinit(self: *EventLoop) void {
        posix.close(self.signal_fd);
        posix.close(self.notify_fd);
        self.ring.deinit();
        std.heap.c_allocator.destroy(self.pool);
    }

    pub fn toScheduler(self: *EventLoop) engine.MessageScheduler {
        return .{
            .schedule_callback = schedule_callback,
            .context = self,
        };
    }

    pub fn schedule_callback(isolate: engine.DartHandle, ctx: ?*anyopaque) callconv(.c) void {
        _ = isolate;
        const self: *EventLoop = @ptrCast(@alignCast(ctx orelse return));

        // Only write to eventfd on the idle→busy transition (prev==0).
        // When pending is already >0, the event loop is still draining messages
        // and will process this one too — no extra wakeup syscall needed.
        const prev = self.pending.fetchAdd(1, .monotonic);
        if (prev == 0) {
            const one: u64 = 1;
            _ = posix.write(self.notify_fd, std.mem.asBytes(&one)) catch {};
        }
    }

    pub fn run(self: *EventLoop) void {
        // Expose this loop to tcp.zig natives running on this thread.
        state.current_loop = .{
            .ptr = self,
            .ops = &uring_ops,
            .pool = self.pool,
            .slot_alloc = &self.slot_alloc,
        };
        defer state.current_loop = null;

        // arm notify read here (not in init) so &self.notify_buf is stable
        self.armNotifyRead() catch return;
        self.armSignalRead() catch return;
        self.armTimeout() catch return;

        var cqes: [32]linux.io_uring_cqe = undefined;
        while (true) {
            _ = self.ring.submit_and_wait(1) catch break;

            // Track whether any pool I/O fired this iteration.
            // Used to suppress Dart_NotifyIdle when the loop is actively processing
            // connections (timeout CQE can arrive in the same batch as pool CQEs).
            var any_io = false;

            while (true) {
                const n = self.ring.copy_cqes(&cqes, 0) catch break;
                if (n == 0) break;

                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const cqe = cqes[i];

                    if (cqe.user_data == notify_user_data) {
                        // Drain the pending counter atomically: schedule_callback
                        // only writes to eventfd once (on idle→busy transition), so
                        // notify_buf is always 1. Use pending.swap(0) to get the
                        // real number of messages that have accumulated.
                        const count: i32 = @intCast(@max(1, self.pending.swap(0, .acquire)));
                        var processed: i32 = 0;
                        while (processed < count) : (processed += 1) {
                            if (self.isolate != null) {
                                engine.DartEngine_HandleMessage(self.isolate);
                            }
                        }
                        self.notify_buf = 0;
                        self.armNotifyRead() catch {};
                    } else if (cqe.user_data == signal_user_data) {
                        // SIGINT or SIGTERM — graceful shutdown
                        return;
                    } else if (cqe.user_data == timeout_user_data and
                        cqe.res == -@as(i32, @intFromEnum(linux.E.TIME)))
                    {
                        // Only hint GC when truly idle — no pool I/O in this batch.
                        // Calling Dart_NotifyIdle mid-benchmark triggers premature GC.
                        if (!any_io) {
                            if (self.isolate != null) {
                                engine.DartEngine_AcquireIsolate(self.isolate);
                                engine.Dart_NotifyIdle(std.time.microTimestamp() + 5_000);
                                const live = engine.Dart_HasLivePorts();
                                engine.DartEngine_ReleaseIsolate();
                                if (!live) return;
                            }
                        }
                        self.armTimeout() catch return;
                    } else if (cqe.user_data >= state.kPoolBase) {
                        self.dispatchPoolCqe(cqe);
                        any_io = true;
                    }
                }
            }
        }
    }

    fn dispatchPoolCqe(self: *EventLoop, cqe: linux.io_uring_cqe) void {
        const raw_idx = cqe.user_data - state.kPoolBase;
        if (raw_idx >= state.kPoolSize) return;
        const idx: usize = @intCast(raw_idx);
        const ctx = &self.pool[idx];
        if (!ctx.in_use) return;

        switch (ctx.op) {
            .accept => {
                // cqe.res is the new conn fd (>=0) or -errno on error.
                if (cqe.res >= 0) setTcpNoDelay(@intCast(cqe.res));
                _ = engine.Dart_PostInteger(ctx.port_id, cqe.res);
                state.freeSlot(self.pool, &self.slot_alloc, idx);
            },
            .recv => {
                // postRecvResult serializes buf[0..cqe.res] into a Dart kTypedData
                // message (one VM memcpy). Pool slot freed immediately — no GC.
                state.postRecvResult(ctx.port_id, cqe.res, ctx.data.recv.buf[0..]);
                state.freeSlot(self.pool, &self.slot_alloc, idx);
            },
            .send => {
                _ = engine.Dart_PostInteger(ctx.port_id, cqe.res);
                state.freeSlot(self.pool, &self.slot_alloc, idx); // buf is embedded, no heap free
            },
        }
    }

    fn armNotifyRead(self: *EventLoop) !void {
        _ = try self.ring.read(
            notify_user_data,
            self.notify_fd,
            .{ .buffer = std.mem.asBytes(&self.notify_buf) },
            0,
        );
    }

    fn armSignalRead(self: *EventLoop) !void {
        _ = try self.ring.read(
            signal_user_data,
            self.signal_fd,
            .{ .buffer = std.mem.asBytes(&self.signal_buf) },
            0,
        );
    }

    fn armTimeout(self: *EventLoop) !void {
        _ = try self.ring.timeout(
            timeout_user_data,
            &self.timeout_ts,
            0,
            0,
        );
    }
};

// ---------------------------------------------------------------------------
// io_uring vtable — called by tcp.zig natives from the event-loop thread.
// SQEs are queued here; they are submitted to the kernel on the next
// submit_and_wait() call at the top of run()'s loop.
// ---------------------------------------------------------------------------

const uring_ops = state.LoopOps{
    .submit_accept = submitAccept,
    .submit_recv = submitRecv,
    .submit_send = submitSend,
};

fn submitAccept(loop: *anyopaque, slot_idx: usize, fd: posix.fd_t) void {
    const self: *EventLoop = @ptrCast(@alignCast(loop));
    const ctx = &self.pool[slot_idx];
    const user_data: u64 = state.kPoolBase + @as(u64, slot_idx);
    const accept_flags: u32 = linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC;
    _ = self.ring.accept(user_data, fd, null, null, accept_flags) catch {
        _ = engine.Dart_PostInteger(ctx.port_id, -1);
        state.freeSlot(self.pool, &self.slot_alloc, slot_idx);
    };
}

fn submitRecv(loop: *anyopaque, slot_idx: usize, fd: posix.fd_t) void {
    const self: *EventLoop = @ptrCast(@alignCast(loop));
    const ctx = &self.pool[slot_idx];
    const user_data: u64 = state.kPoolBase + @as(u64, slot_idx);
    // Kernel reads directly into the pool slot's embedded recv buffer — no alloc.
    _ = self.ring.read(user_data, fd, .{ .buffer = ctx.data.recv.buf[0..] }, 0) catch {
        state.postRecvResult(ctx.port_id, -1, ctx.data.recv.buf[0..0]);
        state.freeSlot(self.pool, &self.slot_alloc, slot_idx);
    };
}

fn submitSend(loop: *anyopaque, slot_idx: usize, fd: posix.fd_t, buf: []u8) void {
    const self: *EventLoop = @ptrCast(@alignCast(loop));
    const ctx = &self.pool[slot_idx];
    const user_data: u64 = state.kPoolBase + @as(u64, slot_idx);

    // Inline fast-path: try posix.write() before touching the ring.
    // On loopback the TCP send buffer is never full for 1–8 KB payloads,
    // so write() almost always succeeds immediately — eliminating one full
    // io_uring_enter round-trip and one eventfd wakeup per echo.
    // This mirrors what kqueue's submitSend already does and what dart:io
    // does (SocketBase::Write → write() before any epoll registration).
    const n = posix.write(fd, buf) catch |err| blk: {
        if (err == error.WouldBlock) break :blk @as(usize, 0); // EAGAIN → SQE path
        // Hard error (EBADF, EPIPE, etc.) — notify Dart immediately.
        _ = engine.Dart_PostInteger(ctx.port_id, -1);
        state.freeSlot(self.pool, &self.slot_alloc, slot_idx);
        return;
    };
    if (n > 0) {
        // Full or partial write succeeded inline.
        // Post result directly — no SQE needed, one fewer kernel round-trip.
        _ = engine.Dart_PostInteger(ctx.port_id, @intCast(n));
        state.freeSlot(self.pool, &self.slot_alloc, slot_idx);
        return;
    }
    // n == 0 means EAGAIN: send buffer full. Fall through to async SQE.
    _ = self.ring.write(user_data, fd, buf, 0) catch {
        _ = engine.Dart_PostInteger(ctx.port_id, -1);
        state.freeSlot(self.pool, &self.slot_alloc, slot_idx);
    };
}

fn setTcpNoDelay(fd: posix.fd_t) void {
    const one = std.mem.toBytes(@as(c_int, 1));
    posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, &one) catch {};
}
