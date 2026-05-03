const builtin = @import("builtin");
comptime {
    if (builtin.os.tag != .macos) @compileError("kqueue requires macOS");
}

const std = @import("std");
const posix = std.posix;
const c = std.c;
const engine = @import("../engine.zig");
const state = @import("../zig_io/state.zig");
const tls_module = @import("../zig_io/tls.zig");
const profiler = @import("../profiler.zig");
const http_parser = @import("../http/parser.zig");
const http_responses = @import("../http/responses.zig");

// kqueue filter constants not exposed in std.c on all Zig versions
const EVFILT_SIGNAL: i16 = -6;
const EVFILT_WRITE: i16 = -2;

pub const EventLoop = struct {
    kq: posix.fd_t,
    pipe_r: posix.fd_t,
    pipe_w: posix.fd_t,
    isolate: engine.DartHandle,
    pending: std.atomic.Value(i32),
    // Heap-allocated: 4096 × ~8 KB = 32 MB; too large for the stack.
    pool: *[state.kPoolSize]state.CompletionCtx,
    slot_alloc: state.SlotAllocator,
    /// Set by ZigIo_SetBatchPort once Dart main() initialises the dispatcher.
    /// When non-zero, completions are batched into one CObject_kArray per kevent() call.
    batch_port_id: engine.Dart_Port = 0,

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
            .batch_port_ptr = &self.batch_port_id,
        };
        defer state.current_loop = null;

        const timeout_200ms = posix.timespec{
            .sec = 0,
            .nsec = 200 * std.time.ns_per_ms,
        };
        var events: [32]posix.Kevent = undefined;
        var no_changes: [0]posix.Kevent = .{};

        // Batch buffer: at most one entry per event in the kevent() batch.
        var batch: [32]BatchEntry = undefined;
        var batch_n: usize = 0;

        while (true) {
            const n = posix.kevent(self.kq, no_changes[0..], events[0..], &timeout_200ms) catch break;
            if (profiler.enabled and n > 0) profiler.p.onKeventReturn(@intCast(n));

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

            batch_n = 0;

            var i: usize = 0;
            while (i < n) : (i += 1) {
                const event = events[i];

                // Signal event (SIGINT/SIGTERM) → graceful shutdown
                if (event.udata == 1) return;

                // Pool slot I/O event (udata >= kPoolBase)
                if (event.udata >= @as(usize, state.kPoolBase)) {
                    if (self.batch_port_id != 0) {
                        // Batch path: perform I/O now, defer posting until after loop.
                        if (self.collectPoolEvent(event, &batch[batch_n])) {
                            batch_n += 1;
                        }
                    } else {
                        // Fallback: post individually (batch port not yet initialised).
                        self.dispatchPoolEvent(event);
                    }
                    continue;
                }

                // Message pipe ready — process queued Dart messages.
                if (event.ident == @as(usize, @intCast(self.pipe_r))) {
                    _ = self.drainPipe();
                    const count: i32 = @intCast(@max(1, self.pending.swap(0, .acq_rel)));
                    var processed: i32 = 0;
                    while (processed < count) : (processed += 1) {
                        if (self.isolate != null) {
                            engine.DartEngine_HandleMessage(self.isolate);
                        }
                    }
                }
            }

            // Post one batch message for all I/O completions collected this iteration.
            // Dart_PostCObject copies kTypedData bytes synchronously → safe to free slots after.
            if (batch_n > 0) {
                self.flushBatch(batch[0..batch_n]);
            }
        }
    }

    // ---------------------------------------------------------------------------
    // Per-entry result collected during a kevent() batch.
    // ---------------------------------------------------------------------------
    const BatchKind = enum { int_val, null_val, typed_data };
    const BatchEntry = struct {
        token: engine.Dart_Port,
        slot_idx: usize,
        kind: BatchKind,
        int_val: i64 = 0,
        bytes_len: usize = 0,
    };

    /// Re-arm a serve slot for EVFILT_READ (incomplete request — need more data).
    fn armServeRecv(self: *EventLoop, idx: usize, fd: posix.fd_t) bool {
        const udata = @as(usize, state.kPoolBase) + idx;
        return addKevent(
            self.kq,
            @intCast(fd),
            @as(i16, c.EVFILT.READ),
            @as(u16, c.EV.ADD | c.EV.ENABLE | c.EV.ONESHOT),
            udata,
        );
    }

    /// Re-arm a serve slot for EVFILT_WRITE (partial write remainder path).
    fn armServeWrite(self: *EventLoop, idx: usize, fd: posix.fd_t) bool {
        const udata = @as(usize, state.kPoolBase) + idx;
        return addKevent(
            self.kq,
            @intCast(fd),
            EVFILT_WRITE,
            @as(u16, c.EV.ADD | c.EV.ENABLE | c.EV.ONESHOT),
            udata,
        );
    }

    /// Process the pipelining inner loop for an Op.loop slot.
    /// Tries to route recv_buf[0..recv_len]; writes response inline; memmoves past
    /// consumed bytes; loops until buffer empty or partial write.
    /// Returns null if the slot was re-armed (no post to Dart needed).
    /// Returns an i64 if the connection should be closed (post this value to Dart).
    fn processLoopPipeline(self: *EventLoop, idx: usize) ?i64 {
        const ctx = &self.pool[idx];
        const sd = &ctx.data.loop;
        while (true) {
            const rr = http_parser.routeRequestFull(sd.recv_buf[0..sd.recv_len]);
            if (rr.route == http_parser.RouteId.incomplete) {
                if (!self.armServeRecv(idx, ctx.fd)) return -1;
                return null;
            }
            const resp = http_responses.forRoute(rr.route) orelse return -1;
            const close = http_responses.shouldClose(rr.route);
            const n = posix.write(ctx.fd, resp) catch return -1;
            if (n < resp.len) {
                // Partial write — arm EVFILT_WRITE for remainder.
                sd.write_ptr = resp.ptr + n;
                sd.write_len = resp.len - n;
                sd.write_phase = true;
                sd.should_close = close;
                sd.pending_consumed = rr.consumed;
                if (!self.armServeWrite(idx, ctx.fd)) return -1;
                return null;
            }
            if (close) return -1;
            // Advance buffer past consumed request.
            const remaining = sd.recv_len - rr.consumed;
            if (remaining > 0) {
                std.mem.copyForwards(u8, sd.recv_buf[0..remaining], sd.recv_buf[rr.consumed..sd.recv_len]);
            }
            sd.recv_len = remaining;
            if (remaining == 0) {
                // Buffer empty — re-arm for next request.
                if (!self.armServeRecv(idx, ctx.fd)) return -1;
                return null;
            }
            // Pipelined request — loop immediately.
        }
    }

    fn armTlsHandshake(self: *EventLoop, idx: usize, fd: posix.fd_t, wait_write: bool) bool {
        const filter: i16 = if (wait_write) EVFILT_WRITE else @as(i16, c.EVFILT.READ);
        const udata = @as(usize, state.kPoolBase) + idx;
        return addKevent(
            self.kq,
            @intCast(fd),
            filter,
            @as(u16, c.EV.ADD | c.EV.ENABLE | c.EV.ONESHOT),
            udata,
        );
    }

    /// Perform the I/O syscall for a pool event and record the result in `out`.
    /// Returns true if a result was recorded; false if the event was invalid.
    fn collectPoolEvent(self: *EventLoop, event: posix.Kevent, out: *BatchEntry) bool {
        const idx = event.udata - @as(usize, state.kPoolBase);
        if (idx >= state.kPoolSize) return false;
        const ctx = &self.pool[idx];
        if (!ctx.in_use) return false;

        out.token = ctx.port_id;
        out.slot_idx = idx;

        switch (ctx.op) {
            .accept => {
                const conn = posix.accept(ctx.fd, null, null, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC) catch {
                    out.kind = .int_val;
                    out.int_val = -1;
                    return true;
                };
                setTcpNoDelay(conn);
                out.kind = .int_val;
                out.int_val = conn;
                return true;
            },
            .recv => {
                if (ctx.tls_id != 0) {
                    const tls_id = ctx.tls_id;
                    const bytes_read = posix.read(ctx.fd, ctx.data.recv.buf[0..]) catch {
                        out.kind = .null_val;
                        return true;
                    };
                    if (bytes_read == 0) {
                        out.kind = .null_val;
                        return true;
                    }
                    if (!tls_module.feedRecv(tls_id, ctx.data.recv.buf[0..bytes_read])) {
                        out.kind = .null_val;
                        return true;
                    }
                    const plain_n = tls_module.readPlaintext(tls_id, ctx.data.recv.buf[0..]);
                    if (plain_n > 0) {
                        out.kind = .typed_data;
                        out.bytes_len = @intCast(plain_n);
                    } else {
                        out.kind = .null_val;
                    }
                    return true;
                }

                const bytes_read = posix.read(ctx.fd, ctx.data.recv.buf[0..]) catch {
                    out.kind = .null_val;
                    return true;
                };
                if (bytes_read == 0) {
                    out.kind = .null_val;
                } else {
                    out.kind = .typed_data;
                    out.bytes_len = bytes_read;
                }
                return true;
            },
            .recv_route => {
                // Read bytes then parse+route in Zig — posts a route int, not a Uint8List.
                // Eliminates Dart Uint8List allocation, ApiMessageSerializer, memcpy, and GC pressure.
                const bytes_read = posix.read(ctx.fd, ctx.data.recv_route.buf[0..]) catch {
                    out.kind = .int_val;
                    out.int_val = http_parser.RouteId.eof;
                    return true;
                };
                if (bytes_read == 0) {
                    out.kind = .int_val;
                    out.int_val = http_parser.RouteId.eof;
                } else {
                    out.kind = .int_val;
                    out.int_val = http_parser.routeRequest(ctx.data.recv_route.buf[0..bytes_read]);
                }
                return true;
            },
            .serve => {
                const sd = &ctx.data.serve;
                if (!sd.write_phase) {
                    // Phase 1: recv fired — append to buffer, route, write inline.
                    const space = sd.recv_buf[sd.recv_len..];
                    if (space.len == 0) {
                        // Buffer full without a complete request — send 400.
                        _ = posix.write(ctx.fd, http_responses.bad_request) catch {};
                        out.kind = .int_val;
                        out.int_val = -1;
                        return true;
                    }
                    const bytes_read = posix.read(ctx.fd, space) catch {
                        out.kind = .int_val;
                        out.int_val = -1;
                        return true;
                    };
                    if (bytes_read == 0) {
                        out.kind = .int_val;
                        out.int_val = -1; // EOF
                        return true;
                    }
                    sd.recv_len += bytes_read;
                    const route = http_parser.routeRequest(sd.recv_buf[0..sd.recv_len]);
                    if (route == http_parser.RouteId.incomplete) {
                        // Need more data — re-arm EVFILT_READ and keep accumulating.
                        if (!self.armServeRecv(idx, ctx.fd)) {
                            out.kind = .int_val;
                            out.int_val = -1;
                            return true;
                        }
                        return false;
                    }
                    sd.should_close = http_responses.shouldClose(route);
                    const resp = http_responses.forRoute(route) orelse {
                        out.kind = .int_val;
                        out.int_val = -1;
                        return true;
                    };
                    // Inline write — almost always completes fully for <200B responses.
                    const n = posix.write(ctx.fd, resp) catch {
                        out.kind = .int_val;
                        out.int_val = -1;
                        return true;
                    };
                    if (n >= resp.len) {
                        out.kind = .int_val;
                        out.int_val = if (sd.should_close) -1 else 0;
                        return true;
                    }
                    // Partial write (rare on loopback) — arm EVFILT_WRITE for remainder.
                    sd.write_ptr = resp.ptr + n;
                    sd.write_len = resp.len - n;
                    sd.write_phase = true;
                    if (!self.armServeWrite(idx, ctx.fd)) {
                        out.kind = .int_val;
                        out.int_val = -1;
                        return true;
                    }
                    return false; // don't complete yet
                } else {
                    // Phase 2: EVFILT_WRITE fired — write the remainder.
                    const n = posix.write(ctx.fd, sd.write_ptr[0..sd.write_len]) catch {
                        out.kind = .int_val;
                        out.int_val = -1;
                        return true;
                    };
                    if (n >= sd.write_len) {
                        out.kind = .int_val;
                        out.int_val = if (sd.should_close) -1 else 0;
                        return true;
                    }
                    // Still partial — update and re-arm.
                    sd.write_ptr += n;
                    sd.write_len -= n;
                    if (!self.armServeWrite(idx, ctx.fd)) {
                        out.kind = .int_val;
                        out.int_val = -1;
                        return true;
                    }
                    return false;
                }
            },
            .loop => {
                const sd = &ctx.data.loop;
                if (!sd.write_phase) {
                    // Recv phase: read into remaining buffer space.
                    const space = sd.recv_buf[sd.recv_len..];
                    if (space.len == 0) {
                        _ = posix.write(ctx.fd, http_responses.bad_request) catch {};
                        posix.close(ctx.fd);
                        out.kind = .int_val;
                        out.int_val = -1;
                        return true;
                    }
                    const bytes_read = posix.read(ctx.fd, space) catch {
                        posix.close(ctx.fd);
                        out.kind = .int_val;
                        out.int_val = -1;
                        return true;
                    };
                    if (bytes_read == 0) {
                        posix.close(ctx.fd);
                        out.kind = .int_val;
                        out.int_val = -1;
                        return true;
                    }
                    sd.recv_len += bytes_read;
                } else {
                    // Write phase: complete partial write remainder.
                    const n = posix.write(ctx.fd, sd.write_ptr[0..sd.write_len]) catch {
                        posix.close(ctx.fd);
                        out.kind = .int_val;
                        out.int_val = -1;
                        return true;
                    };
                    if (n < sd.write_len) {
                        sd.write_ptr += n;
                        sd.write_len -= n;
                        if (!self.armServeWrite(idx, ctx.fd)) {
                            posix.close(ctx.fd);
                            out.kind = .int_val;
                            out.int_val = -1;
                            return true;
                        }
                        return false;
                    }
                    // Write complete.
                    if (sd.should_close) {
                        posix.close(ctx.fd);
                        out.kind = .int_val;
                        out.int_val = -1;
                        return true;
                    }
                    sd.write_phase = false;
                    // Advance buffer past the request that was just served.
                    const remaining = sd.recv_len - sd.pending_consumed;
                    if (remaining > 0) {
                        std.mem.copyForwards(u8, sd.recv_buf[0..remaining], sd.recv_buf[sd.pending_consumed..sd.recv_len]);
                    }
                    sd.recv_len = remaining;
                }
                // Run pipelining loop.
                if (self.processLoopPipeline(idx)) |val| {
                    posix.close(ctx.fd);
                    out.kind = .int_val;
                    out.int_val = val;
                    return true;
                }
                return false;
            },
            .send => {
                const bytes_written = posix.write(ctx.fd, ctx.data.send.buf[0..ctx.data.send.len]) catch {
                    out.kind = .int_val;
                    out.int_val = -1;
                    return true;
                };
                out.kind = .int_val;
                out.int_val = @intCast(bytes_written);
                return true;
            },
            .tls_handshake => {
                const tls_id = ctx.tls_id;
                if (tls_id == 0) {
                    out.kind = .int_val;
                    out.int_val = -1;
                    return true;
                }

                // `.tls_handshake` has no embedded recv buffer in the tagged union.
                // Use a stack buffer for sync kqueue reads.
                var net_buf: [state.kBufSize]u8 = undefined;
                if (event.filter != EVFILT_WRITE) {
                    const bytes_read = posix.read(ctx.fd, net_buf[0..]) catch |err| switch (err) {
                        error.WouldBlock => {
                            if (!self.armTlsHandshake(idx, ctx.fd, false)) {
                                out.kind = .int_val;
                                out.int_val = -1;
                                tls_module.freeConn(tls_id);
                                return true;
                            }
                            return false;
                        },
                        else => {
                            out.kind = .int_val;
                            out.int_val = -1;
                            tls_module.freeConn(tls_id);
                            return true;
                        },
                    };
                    if (bytes_read == 0) {
                        out.kind = .int_val;
                        out.int_val = -1;
                        tls_module.freeConn(tls_id);
                        return true;
                    }
                    if (!tls_module.feedRecv(tls_id, net_buf[0..bytes_read])) {
                        out.kind = .int_val;
                        out.int_val = -1;
                        tls_module.freeConn(tls_id);
                        return true;
                    }
                }

                switch (tls_module.advanceHandshake(tls_id)) {
                    .done => {
                        out.kind = .int_val;
                        out.int_val = tls_id;
                        return true;
                    },
                    .want_read => {
                        if (!self.armTlsHandshake(idx, ctx.fd, false)) {
                            out.kind = .int_val;
                            out.int_val = -1;
                            tls_module.freeConn(tls_id);
                            return true;
                        }
                        return false;
                    },
                    .want_write => {
                        if (!self.armTlsHandshake(idx, ctx.fd, true)) {
                            out.kind = .int_val;
                            out.int_val = -1;
                            tls_module.freeConn(tls_id);
                            return true;
                        }
                        return false;
                    },
                    .err => {
                        out.kind = .int_val;
                        out.int_val = -1;
                        tls_module.freeConn(tls_id);
                        return true;
                    },
                }
            },
        }
    }

    /// Build one Dart_CObject_kArray with [token0, value0, token1, value1, ...] and post it.
    /// All pool slots are freed after the post (kTypedData bytes are copied by Dart_PostCObject).
    fn flushBatch(self: *EventLoop, batch: []BatchEntry) void {
        var token_objs: [32]engine.Dart_CObject = undefined;
        var value_objs: [32]engine.Dart_CObject = undefined;
        var ptrs: [64]?*engine.Dart_CObject = undefined;

        for (batch, 0..) |entry, i| {
            token_objs[i] = .{ .@"type" = engine.Dart_CObject_kInt64, .value = .{ .as_int64 = entry.token } };
            value_objs[i] = switch (entry.kind) {
                .int_val => .{ .@"type" = engine.Dart_CObject_kInt64, .value = .{ .as_int64 = entry.int_val } },
                .null_val => .{ .@"type" = engine.Dart_CObject_kNull, .value = .{ .as_int64 = 0 } },
                .typed_data => .{
                    .@"type" = engine.Dart_CObject_kTypedData,
                    .value = .{ .as_typed_data = .{
                        .data_type = engine.Dart_TypedData_kUint8,
                        .length = @intCast(entry.bytes_len),
                        .values = self.pool[entry.slot_idx].data.recv.buf[0..entry.bytes_len].ptr,
                    } },
                },
            };
            ptrs[2 * i] = &token_objs[i];
            ptrs[2 * i + 1] = &value_objs[i];
        }

        var batch_obj = engine.Dart_CObject{
            .@"type" = engine.Dart_CObject_kArray,
            .value = .{ .as_array = .{
                .length = @intCast(2 * batch.len),
                .values = ptrs[0..].ptr,
            } },
        };
        if (profiler.enabled) profiler.p.onFlushBatch();
        _ = engine.Dart_PostCObject(self.batch_port_id, &batch_obj);

        // Free all slots after posting — kTypedData bytes were copied synchronously.
        for (batch) |entry| {
            state.freeSlot(self.pool, &self.slot_alloc, entry.slot_idx);
        }
    }

    /// Fallback: post each completion immediately (used before batch port is set up).
    fn dispatchPoolEvent(self: *EventLoop, event: posix.Kevent) void {
        const idx = event.udata - @as(usize, state.kPoolBase);
        if (idx >= state.kPoolSize) return;
        const ctx = &self.pool[idx];
        if (!ctx.in_use) return;

        switch (ctx.op) {
            .accept => {
                const conn = posix.accept(ctx.fd, null, null, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC) catch {
                    _ = engine.Dart_PostInteger(ctx.port_id, -1);
                    state.freeSlot(self.pool, &self.slot_alloc, idx);
                    return;
                };
                setTcpNoDelay(conn);
                _ = engine.Dart_PostInteger(ctx.port_id, conn);
                state.freeSlot(self.pool, &self.slot_alloc, idx);
            },
            .recv => {
                if (ctx.tls_id != 0) {
                    const tls_id = ctx.tls_id;
                    const bytes_read = posix.read(ctx.fd, ctx.data.recv.buf[0..]) catch {
                        state.postRecvResult(ctx.port_id, -1, ctx.data.recv.buf[0..0]);
                        state.freeSlot(self.pool, &self.slot_alloc, idx);
                        return;
                    };
                    if (bytes_read == 0 or !tls_module.feedRecv(tls_id, ctx.data.recv.buf[0..bytes_read])) {
                        state.postRecvResult(ctx.port_id, -1, ctx.data.recv.buf[0..0]);
                        state.freeSlot(self.pool, &self.slot_alloc, idx);
                        return;
                    }
                    const plain_n = tls_module.readPlaintext(tls_id, ctx.data.recv.buf[0..]);
                    if (plain_n > 0) {
                        state.postRecvResult(ctx.port_id, plain_n, ctx.data.recv.buf[0..]);
                    } else {
                        state.postRecvResult(ctx.port_id, -1, ctx.data.recv.buf[0..0]);
                    }
                    state.freeSlot(self.pool, &self.slot_alloc, idx);
                    return;
                }

                const bytes_read = posix.read(ctx.fd, ctx.data.recv.buf[0..]) catch {
                    state.postRecvResult(ctx.port_id, -1, ctx.data.recv.buf[0..0]);
                    state.freeSlot(self.pool, &self.slot_alloc, idx);
                    return;
                };
                state.postRecvResult(ctx.port_id, @intCast(bytes_read), ctx.data.recv.buf[0..]);
                state.freeSlot(self.pool, &self.slot_alloc, idx);
            },
            .recv_route => {
                // Legacy (pre-batch) path: read + route in Zig, post int directly.
                const bytes_read = posix.read(ctx.fd, ctx.data.recv_route.buf[0..]) catch {
                    _ = engine.Dart_PostInteger(ctx.port_id, http_parser.RouteId.eof);
                    state.freeSlot(self.pool, &self.slot_alloc, idx);
                    return;
                };
                const route: i64 = if (bytes_read == 0)
                    http_parser.RouteId.eof
                else
                    http_parser.routeRequest(ctx.data.recv_route.buf[0..bytes_read]);
                _ = engine.Dart_PostInteger(ctx.port_id, route);
                state.freeSlot(self.pool, &self.slot_alloc, idx);
            },
            .serve => {
                // Legacy path: synchronous serve with blocking read loop for incomplete requests.
                const sd = &ctx.data.serve;
                // Read loop: accumulate until complete or EOF.
                const route = blk: {
                    while (true) {
                        const space = sd.recv_buf[sd.recv_len..];
                        if (space.len == 0) break :blk http_parser.RouteId.bad_request;
                        const n = posix.read(ctx.fd, space) catch break :blk http_parser.RouteId.eof;
                        if (n == 0) break :blk http_parser.RouteId.eof;
                        sd.recv_len += n;
                        const r = http_parser.routeRequest(sd.recv_buf[0..sd.recv_len]);
                        if (r != http_parser.RouteId.incomplete) break :blk r;
                        // incomplete — loop to read more
                    }
                };
                const close = http_responses.shouldClose(route);
                if (http_responses.forRoute(route)) |resp| {
                    var written: usize = 0;
                    while (written < resp.len) {
                        const n = posix.write(ctx.fd, resp[written..]) catch break;
                        if (n == 0) break;
                        written += n;
                    }
                }
                _ = engine.Dart_PostInteger(ctx.port_id, if (close) -1 else 0);
                state.freeSlot(self.pool, &self.slot_alloc, idx);
            },
            .loop => {
                // Legacy path: synchronous keep-alive loop until connection closes.
                const sd = &ctx.data.loop;
                while (true) {
                    // Read one batch of data.
                    const space = sd.recv_buf[sd.recv_len..];
                    if (space.len == 0) break; // buffer overflow — close
                    const n = posix.read(ctx.fd, space) catch break;
                    if (n == 0) break; // EOF
                    sd.recv_len += n;
                    // Pipeline: serve all complete requests in recv_buf.
                    while (true) {
                        const rr = http_parser.routeRequestFull(sd.recv_buf[0..sd.recv_len]);
                        if (rr.route == http_parser.RouteId.incomplete) break; // need more data
                        const close = http_responses.shouldClose(rr.route);
                        if (http_responses.forRoute(rr.route)) |resp| {
                            var written: usize = 0;
                            while (written < resp.len) {
                                const w = posix.write(ctx.fd, resp[written..]) catch break;
                                if (w == 0) break;
                                written += w;
                            }
                        }
                        if (close) {
                            _ = engine.Dart_PostInteger(ctx.port_id, -1);
                            state.freeSlot(self.pool, &self.slot_alloc, idx);
                            return;
                        }
                        // Advance past consumed request.
                        const remaining = sd.recv_len - rr.consumed;
                        if (remaining > 0) {
                            std.mem.copyForwards(u8, sd.recv_buf[0..remaining], sd.recv_buf[rr.consumed..sd.recv_len]);
                        }
                        sd.recv_len = remaining;
                        if (remaining == 0) break; // buffer empty — read more
                    }
                }
                _ = engine.Dart_PostInteger(ctx.port_id, -1);
                state.freeSlot(self.pool, &self.slot_alloc, idx);
            },
            .send => {
                const bytes_written = posix.write(ctx.fd, ctx.data.send.buf[0..ctx.data.send.len]) catch {
                    _ = engine.Dart_PostInteger(ctx.port_id, -1);
                    state.freeSlot(self.pool, &self.slot_alloc, idx);
                    return;
                };
                _ = engine.Dart_PostInteger(ctx.port_id, @intCast(bytes_written));
                state.freeSlot(self.pool, &self.slot_alloc, idx);
            },
            .tls_handshake => {
                const tls_id = ctx.tls_id;
                if (tls_id == 0) {
                    _ = engine.Dart_PostInteger(ctx.port_id, -1);
                    state.freeSlot(self.pool, &self.slot_alloc, idx);
                    return;
                }

                var net_buf: [state.kBufSize]u8 = undefined;
                if (event.filter != EVFILT_WRITE) {
                    const bytes_read = posix.read(ctx.fd, net_buf[0..]) catch |err| switch (err) {
                        error.WouldBlock => {
                            if (!self.armTlsHandshake(idx, ctx.fd, false)) {
                                _ = engine.Dart_PostInteger(ctx.port_id, -1);
                                tls_module.freeConn(tls_id);
                                state.freeSlot(self.pool, &self.slot_alloc, idx);
                            }
                            return;
                        },
                        else => {
                            _ = engine.Dart_PostInteger(ctx.port_id, -1);
                            tls_module.freeConn(tls_id);
                            state.freeSlot(self.pool, &self.slot_alloc, idx);
                            return;
                        },
                    };
                    if (bytes_read == 0) {
                        _ = engine.Dart_PostInteger(ctx.port_id, -1);
                        tls_module.freeConn(tls_id);
                        state.freeSlot(self.pool, &self.slot_alloc, idx);
                        return;
                    }
                    if (!tls_module.feedRecv(tls_id, net_buf[0..bytes_read])) {
                        _ = engine.Dart_PostInteger(ctx.port_id, -1);
                        tls_module.freeConn(tls_id);
                        state.freeSlot(self.pool, &self.slot_alloc, idx);
                        return;
                    }
                }

                switch (tls_module.advanceHandshake(tls_id)) {
                    .done => {
                        _ = engine.Dart_PostInteger(ctx.port_id, tls_id);
                        state.freeSlot(self.pool, &self.slot_alloc, idx);
                    },
                    .want_read => {
                        if (!self.armTlsHandshake(idx, ctx.fd, false)) {
                            _ = engine.Dart_PostInteger(ctx.port_id, -1);
                            tls_module.freeConn(tls_id);
                            state.freeSlot(self.pool, &self.slot_alloc, idx);
                        }
                    },
                    .want_write => {
                        if (!self.armTlsHandshake(idx, ctx.fd, true)) {
                            _ = engine.Dart_PostInteger(ctx.port_id, -1);
                            tls_module.freeConn(tls_id);
                            state.freeSlot(self.pool, &self.slot_alloc, idx);
                        }
                    },
                    .err => {
                        _ = engine.Dart_PostInteger(ctx.port_id, -1);
                        tls_module.freeConn(tls_id);
                        state.freeSlot(self.pool, &self.slot_alloc, idx);
                    },
                }
            },
        }
    }

    fn postSingleCompletion(
        self: *EventLoop,
        token: engine.Dart_Port,
        slot_idx: usize,
        kind: BatchKind,
        int_val: i64,
        bytes_len: usize,
    ) void {
        if (self.batch_port_id != 0) {
            var token_obj = engine.Dart_CObject{
                .@"type" = engine.Dart_CObject_kInt64,
                .value = .{ .as_int64 = token },
            };
            var value_obj = switch (kind) {
                .int_val => engine.Dart_CObject{
                    .@"type" = engine.Dart_CObject_kInt64,
                    .value = .{ .as_int64 = int_val },
                },
                .null_val => engine.Dart_CObject{
                    .@"type" = engine.Dart_CObject_kNull,
                    .value = .{ .as_int64 = 0 },
                },
                .typed_data => engine.Dart_CObject{
                    .@"type" = engine.Dart_CObject_kTypedData,
                    .value = .{ .as_typed_data = .{
                        .data_type = engine.Dart_TypedData_kUint8,
                        .length = @intCast(bytes_len),
                        .values = self.pool[slot_idx].data.recv.buf[0..bytes_len].ptr,
                    } },
                },
            };
            var ptrs = [2]?*engine.Dart_CObject{ &token_obj, &value_obj };
            var obj = engine.Dart_CObject{
                .@"type" = engine.Dart_CObject_kArray,
                .value = .{ .as_array = .{
                    .length = 2,
                    .values = ptrs[0..].ptr,
                } },
            };
            _ = engine.Dart_PostCObject(self.batch_port_id, &obj);
            return;
        }

        switch (kind) {
            .int_val => {
                _ = engine.Dart_PostInteger(token, int_val);
            },
            .null_val => {
                state.postRecvResult(token, -1, self.pool[slot_idx].data.recv.buf[0..0]);
            },
            .typed_data => {
                state.postRecvResult(
                    token,
                    @intCast(bytes_len),
                    self.pool[slot_idx].data.recv.buf[0..bytes_len],
                );
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
    .submit_recv_route = submitRecv, // same kevent registration; op field distinguishes dispatch
    .submit_serve = submitServe,
    .submit_loop = submitLoop,
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
        self.postSingleCompletion(ctx.port_id, slot_idx, .int_val, -1, 0);
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
        self.postSingleCompletion(ctx.port_id, slot_idx, .null_val, 0, 0);
        state.freeSlot(self.pool, &self.slot_alloc, slot_idx);
    }
}

/// Arm EVFILT_READ for a serve slot — completion handler does read+route+write.
fn submitServe(loop: *anyopaque, slot_idx: usize, fd: posix.fd_t) void {
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
        self.postSingleCompletion(ctx.port_id, slot_idx, .int_val, -1, 0);
        state.freeSlot(self.pool, &self.slot_alloc, slot_idx);
    }
}

/// Arm EVFILT_READ for a loop slot — completion handler handles entire keep-alive connection.
fn submitLoop(loop: *anyopaque, slot_idx: usize, fd: posix.fd_t) void {
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
        self.postSingleCompletion(ctx.port_id, slot_idx, .int_val, -1, 0);
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
                self.postSingleCompletion(ctx.port_id, slot_idx, .int_val, -1, 0);
                state.freeSlot(self.pool, &self.slot_alloc, slot_idx);
            }
        } else {
            self.postSingleCompletion(ctx.port_id, slot_idx, .int_val, -1, 0);
            state.freeSlot(self.pool, &self.slot_alloc, slot_idx); // buf is embedded, no heap free
        }
        return;
    };
    // Write completed immediately — post result and free the slot.
    self.postSingleCompletion(ctx.port_id, slot_idx, .int_val, @intCast(bytes_written), 0);
    state.freeSlot(self.pool, &self.slot_alloc, slot_idx);
}

fn setTcpNoDelay(fd: posix.fd_t) void {
    const one = std.mem.toBytes(@as(c_int, 1));
    posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, &one) catch {};
}
