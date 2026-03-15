const builtin = @import("builtin");
comptime {
    if (builtin.os.tag != .macos) @compileError("kqueue requires macOS");
}

const std = @import("std");
const posix = std.posix;
const c = std.c;
const engine = @import("../engine.zig");
const state = @import("../zig_io/state.zig");

// kqueue filter constants not exposed in std.c on all Zig versions
const EVFILT_SIGNAL: i16 = -6;
const EVFILT_WRITE: i16 = -2;

pub const EventLoop = struct {
    kq: posix.fd_t,
    pipe_r: posix.fd_t,
    pipe_w: posix.fd_t,
    isolate: engine.DartHandle,
    pending: std.atomic.Value(i32),
    // Heap-allocated: 256 × ~8 KB = 2 MB; too large for the stack.
    pool: *[state.kPoolSize]state.CompletionCtx,
    slot_alloc: state.SlotAllocator,

    pub fn init(isolate: engine.DartHandle) !EventLoop {
        const kq = try posix.kqueue();
        errdefer posix.close(kq);

        const pipe_fds = try posix.pipe();
        errdefer {
            posix.close(pipe_fds[0]);
            posix.close(pipe_fds[1]);
        }

        // Set both ends non-blocking; drainPipe() relies on WouldBlock to stop reading
        var pipe_r_flags = try posix.fcntl(pipe_fds[0], posix.F.GETFL, 0);
        pipe_r_flags |= @as(usize, 1) << @bitOffsetOf(posix.O, "NONBLOCK");
        _ = try posix.fcntl(pipe_fds[0], posix.F.SETFL, pipe_r_flags);

        var pipe_w_flags = try posix.fcntl(pipe_fds[1], posix.F.GETFL, 0);
        pipe_w_flags |= @as(usize, 1) << @bitOffsetOf(posix.O, "NONBLOCK");
        _ = try posix.fcntl(pipe_fds[1], posix.F.SETFL, pipe_w_flags);

        // Register message pipe (EVFILT_READ) + SIGINT + SIGTERM (EVFILT_SIGNAL)
        // EVFILT_SIGNAL requires the signal to be ignored at the OS level first
        _ = posix.sigaction(posix.SIG.INT, &.{
            .handler = .{ .handler = posix.SIG.IGN },
            .mask = posix.sigemptyset(),
            .flags = 0,
        }, null);
        _ = posix.sigaction(posix.SIG.TERM, &.{
            .handler = .{ .handler = posix.SIG.IGN },
            .mask = posix.sigemptyset(),
            .flags = 0,
        }, null);

        var changes = [3]posix.Kevent{
            .{
                .ident = @as(usize, @intCast(pipe_fds[0])),
                .filter = @as(i16, c.EVFILT.READ),
                .flags = @as(u16, c.EV.ADD | c.EV.ENABLE),
                .fflags = 0,
                .data = 0,
                .udata = 0,
            },
            .{
                .ident = @as(usize, @intCast(posix.SIG.INT)),
                .filter = EVFILT_SIGNAL,
                .flags = @as(u16, c.EV.ADD | c.EV.ENABLE),
                .fflags = 0,
                .data = 0,
                .udata = 1, // tag: signal event
            },
            .{
                .ident = @as(usize, @intCast(posix.SIG.TERM)),
                .filter = EVFILT_SIGNAL,
                .flags = @as(u16, c.EV.ADD | c.EV.ENABLE),
                .fflags = 0,
                .data = 0,
                .udata = 1, // tag: signal event
            },
        };
        var no_events: [0]posix.Kevent = .{};
        _ = try posix.kevent(kq, changes[0..], no_events[0..], null);

        // Heap-allocate the pool (256 × ~8 KB = 2 MB).
        const pool = try std.heap.c_allocator.create([state.kPoolSize]state.CompletionCtx);
        errdefer std.heap.c_allocator.destroy(pool);
        for (pool) |*ctx| ctx.* = .{};

        var loop = EventLoop{
            .kq = kq,
            .pipe_r = pipe_fds[0],
            .pipe_w = pipe_fds[1],
            .isolate = isolate,
            .pending = std.atomic.Value(i32).init(0),
            .pool = pool,
            .slot_alloc = undefined,
        };
        loop.slot_alloc.init();
        return loop;
    }

    pub fn deinit(self: *EventLoop) void {
        posix.close(self.pipe_w);
        posix.close(self.pipe_r);
        posix.close(self.kq);
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

        // Only write to the pipe on the idle→busy transition (prev==0).
        const prev = self.pending.fetchAdd(1, .monotonic);
        if (prev == 0) {
            const byte = [1]u8{1};
            _ = posix.write(self.pipe_w, byte[0..]) catch {};
        }
    }

    pub fn run(self: *EventLoop) void {
        // Expose this loop to tcp.zig natives running on this thread.
        state.current_loop = .{
            .ptr = self,
            .ops = &kqueue_ops,
            .pool = self.pool,
            .slot_alloc = &self.slot_alloc,
        };
        defer state.current_loop = null;

        const timeout_200ms = posix.timespec{
            .sec = 0,
            .nsec = 200 * std.time.ns_per_ms,
        };
        var events: [32]posix.Kevent = undefined;
        var no_changes: [0]posix.Kevent = .{};

        while (true) {
            const n = posix.kevent(self.kq, no_changes[0..], events[0..], &timeout_200ms) catch break;

            if (n == 0) {
                // Idle timeout — notify GC + check live ports.
                if (self.isolate != null) {
                    engine.DartEngine_AcquireIsolate(self.isolate);
                    engine.Dart_NotifyIdle(std.time.microTimestamp() + 5_000);
                    const live = engine.Dart_HasLivePorts();
                    engine.DartEngine_ReleaseIsolate();
                    if (!live) break;
                }
                continue;
            }

            var i: usize = 0;
            while (i < n) : (i += 1) {
                const event = events[i];

                // Signal event (SIGINT/SIGTERM) → graceful shutdown
                if (event.udata == 1) return;

                // Pool slot I/O event (udata >= kPoolBase)
                if (event.udata >= @as(usize, state.kPoolBase)) {
                    self.dispatchPoolEvent(event);
                    continue;
                }

                // Message pipe ready
                if (event.ident == @as(usize, @intCast(self.pipe_r))) {
                    // Drain all bytes from the pipe (schedule_callback only writes
                    // one byte per idle→busy transition, so byte count ≠ message count).
                    // Use pending.swap(0) to get the real number of queued messages.
                    _ = self.drainPipe();
                    const count: i32 = @intCast(@max(1, self.pending.swap(0, .acquire)));
                    var processed: i32 = 0;
                    while (processed < count) : (processed += 1) {
                        if (self.isolate != null) {
                            engine.DartEngine_HandleMessage(self.isolate);
                        }
                    }
                }
            }
        }
    }

    fn dispatchPoolEvent(self: *EventLoop, event: posix.Kevent) void {
        const idx = event.udata - @as(usize, state.kPoolBase);
        if (idx >= state.kPoolSize) return;
        const ctx = &self.pool[idx];
        if (!ctx.in_use) return;

        switch (ctx.op) {
            .accept => {
                // listen fd is readable: do non-blocking accept
                const conn = posix.accept(
                    ctx.fd,
                    null,
                    null,
                    posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
                ) catch {
                    _ = engine.Dart_PostInteger(ctx.port_id, -1);
                    state.freeSlot(self.pool, &self.slot_alloc, idx);
                    return;
                };
                setTcpNoDelay(conn);
                _ = engine.Dart_PostInteger(ctx.port_id, conn);
                state.freeSlot(self.pool, &self.slot_alloc, idx);
            },
            .recv => {
                // conn fd is readable: do non-blocking read into embedded pool buffer.
                const bytes_read = posix.read(ctx.fd, ctx.data.recv.buf[0..]) catch {
                    state.postRecvResult(ctx.port_id, -1, ctx.data.recv.buf[0..0]);
                    state.freeSlot(self.pool, &self.slot_alloc, idx);
                    return;
                };
                // postRecvResult serializes buf[0..n] into a Dart kTypedData message
                // (one VM memcpy). The pool slot is freed immediately after — no GC.
                state.postRecvResult(ctx.port_id, @intCast(bytes_read), ctx.data.recv.buf[0..]);
                state.freeSlot(self.pool, &self.slot_alloc, idx);
            },
            .send => {
                // conn fd is writable: retry the write with embedded send buffer.
                const bytes_written = posix.write(ctx.fd, ctx.data.send.buf[0..ctx.data.send.len]) catch {
                    _ = engine.Dart_PostInteger(ctx.port_id, -1);
                    state.freeSlot(self.pool, &self.slot_alloc, idx);
                    return;
                };
                _ = engine.Dart_PostInteger(ctx.port_id, @intCast(bytes_written));
                state.freeSlot(self.pool, &self.slot_alloc, idx);
            },
        }
    }

    fn drainPipe(self: *EventLoop) i32 {
        var buf: [256]u8 = undefined;
        var total: i32 = 0;
        while (true) {
            const bytes = posix.read(self.pipe_r, buf[0..]) catch |err| switch (err) {
                error.WouldBlock => return total,
                else => return total,
            };
            if (bytes == 0) return total;
            total += @intCast(bytes);
        }
    }
};

// ---------------------------------------------------------------------------
// kqueue vtable — called by tcp.zig natives from the event-loop thread.
// We register EVFILT_READ (accept/recv) or EVFILT_WRITE (send) kevents;
// actual I/O is performed when the event fires in run().
// ---------------------------------------------------------------------------

const kqueue_ops = state.LoopOps{
    .submit_accept = submitAccept,
    .submit_recv = submitRecv,
    .submit_send = submitSend,
};

fn addKevent(kq: posix.fd_t, ident: usize, filter: i16, flags: u16, udata: usize) bool {
    var change = [1]posix.Kevent{.{
        .ident = ident,
        .filter = filter,
        .flags = flags,
        .fflags = 0,
        .data = 0,
        .udata = udata,
    }};
    var no_events: [0]posix.Kevent = .{};
    _ = posix.kevent(kq, change[0..], no_events[0..], null) catch return false;
    return true;
}

fn submitAccept(loop: *anyopaque, slot_idx: usize, fd: posix.fd_t) void {
    const self: *EventLoop = @ptrCast(@alignCast(loop));
    const udata = @as(usize, state.kPoolBase) + slot_idx;
    if (!addKevent(
        self.kq,
        @intCast(fd),
        @as(i16, c.EVFILT.READ),
        @as(u16, c.EV.ADD | c.EV.ENABLE | c.EV.ONESHOT),
        udata,
    )) {
        const ctx = &self.pool[slot_idx];
        _ = engine.Dart_PostInteger(ctx.port_id, -1);
        state.freeSlot(self.pool, &self.slot_alloc, slot_idx);
    }
}

fn submitRecv(loop: *anyopaque, slot_idx: usize, fd: posix.fd_t) void {
    const self: *EventLoop = @ptrCast(@alignCast(loop));
    const udata = @as(usize, state.kPoolBase) + slot_idx;
    if (!addKevent(
        self.kq,
        @intCast(fd),
        @as(i16, c.EVFILT.READ),
        @as(u16, c.EV.ADD | c.EV.ENABLE | c.EV.ONESHOT),
        udata,
    )) {
        const ctx = &self.pool[slot_idx];
        state.postRecvResult(ctx.port_id, -1, ctx.data.recv.buf[0..0]);
        state.freeSlot(self.pool, &self.slot_alloc, slot_idx);
    }
}

fn submitSend(loop: *anyopaque, slot_idx: usize, fd: posix.fd_t, buf: []u8) void {
    const self: *EventLoop = @ptrCast(@alignCast(loop));
    const ctx = &self.pool[slot_idx];
    const udata = @as(usize, state.kPoolBase) + slot_idx;

    // Try a non-blocking write first; only register EVFILT_WRITE if EAGAIN.
    const bytes_written = posix.write(fd, buf) catch |err| {
        if (err == error.WouldBlock) {
            // fd not ready — register EVFILT_WRITE; buf stays in ctx.data.send.buf.
            if (!addKevent(
                self.kq,
                @intCast(fd),
                EVFILT_WRITE,
                @as(u16, c.EV.ADD | c.EV.ENABLE | c.EV.ONESHOT),
                udata,
            )) {
                _ = engine.Dart_PostInteger(ctx.port_id, -1);
                state.freeSlot(self.pool, &self.slot_alloc, slot_idx);
            }
        } else {
            _ = engine.Dart_PostInteger(ctx.port_id, -1);
            state.freeSlot(self.pool, &self.slot_alloc, slot_idx); // buf is embedded, no heap free
        }
        return;
    };
    // Write completed immediately — post result and free the slot.
    _ = engine.Dart_PostInteger(ctx.port_id, @intCast(bytes_written));
    state.freeSlot(self.pool, &self.slot_alloc, slot_idx);
}

fn setTcpNoDelay(fd: posix.fd_t) void {
    const one = std.mem.toBytes(@as(c_int, 1));
    posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, &one) catch {};
}
