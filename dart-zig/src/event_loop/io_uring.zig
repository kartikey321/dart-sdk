const builtin = @import("builtin");
comptime {
    if (builtin.os.tag != .linux) @compileError("io_uring requires Linux");
}

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const engine = @import("../engine.zig");
const state = @import("../zig_io/state.zig");
const tls_module = @import("../zig_io/tls.zig");
const profiler = @import("../profiler.zig");
const http_parser = @import("../http/parser.zig");
const http_responses = @import("../http/responses.zig");

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
    // Heap-allocated: 4096 × ~8 KB = 32 MB; too large for the stack.
    pool: *[state.kPoolSize]state.CompletionCtx,
    slot_alloc: state.SlotAllocator,
    /// Set by ZigIo_SetBatchPort once Dart main() initialises the dispatcher.
    /// When non-zero, completions are batched into one CObject_kArray per
    /// copy_cqes() call instead of N individual Dart_PostInteger/PostCObject calls.
    batch_port_id: engine.Dart_Port = 0,
    /// Set when armNotifyRead() fails because the SQ is full (256 recv re-arms
    /// from 256 op.loop connections can exactly fill a 256-slot SQ). Retried
    /// at the top of the next submit_and_wait iteration after the SQ drains.
    notify_needs_rearm: bool = false,

    pub fn init(isolate: engine.DartHandle) !EventLoop {
        // SQ size 4096: prevents overflow when 256 op.loop connections each
        // re-arm a recv SQE across 8 copy_cqes() passes (256 SQEs) plus notify.
        var ring = try linux.IoUring.init(4096, 0);
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

        // Heap-allocate the pool (4096 × ~8 KB = 32 MB).
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
        state.request_conn_table.deinit();
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
        // batch_port_ptr points into self so the address is stable for the
        // lifetime of run() — ZigIo_SetBatchPort writes through it.
        state.current_loop = .{
            .ptr = self,
            .ops = &uring_ops,
            .pool = self.pool,
            .slot_alloc = &self.slot_alloc,
            .batch_port_ptr = &self.batch_port_id,
        };
        defer state.current_loop = null;

        // arm notify read here (not in init) so &self.notify_buf is stable
        self.armNotifyRead() catch return;
        self.armSignalRead() catch return;
        self.armTimeout() catch return;

        var cqes: [32]linux.io_uring_cqe = undefined;
        // Counts consecutive event-loop iterations where pool I/O fired but no
        // Dart messages were posted (Op.loop keeps connections alive without Dart
        // involvement). Used to give the JIT compiler periodic safepoints so its
        // background threads can install compiled code on single-core-pinned VMs.
        var jit_idle_iters: u32 = 0;
        var no_live_idle_iters: u8 = 0;
        while (true) {
            _ = self.ring.submit_and_wait(1) catch break;

            // Retry deferred notify re-arm now that submit_and_wait has drained
            // the SQ. Keep the flag set if it fails again (retry next iteration).
            if (self.notify_needs_rearm) {
                self.notify_needs_rearm = false;
                self.armNotifyRead() catch { self.notify_needs_rearm = true; };
            }

            // Track whether any pool I/O fired this iteration.
            // Used to suppress Dart_NotifyIdle when the loop is actively processing
            // connections (timeout CQE can arrive in the same batch as pool CQEs).
            var any_io = false;

            while (true) {
                const n = self.ring.copy_cqes(&cqes, 0) catch break;
                if (n == 0) break;
                if (profiler.enabled and n > 0) profiler.p.onKeventReturn(@intCast(n));

                // Batch buffer: one entry per pool CQE in this copy_cqes() call.
                // Mirrors kqueue's per-kevent() flush granularity.
                var batch: [32]BatchEntry = undefined;
                var batch_n: usize = 0;

                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const cqe = cqes[i];

                    if (cqe.user_data == notify_user_data) {
                        // Drain all pending scheduler callbacks before re-arming eventfd.
                        while (true) {
                            const count: i32 = @intCast(@max(1, self.pending.swap(0, .acq_rel)));
                            var processed: i32 = 0;
                            while (processed < count) : (processed += 1) {
                                if (self.isolate != null) {
                                    engine.DartEngine_HandleMessage(self.isolate);
                                }
                            }
                            // Drain microtask queue so async continuations run.
                            if (self.isolate != null) {
                                engine.DartEngine_AcquireIsolate(self.isolate);
                                engine.Dart_EnterScope();
                                _ = engine.DartEngine_DrainMicrotasksQueue();
                                engine.Dart_ExitScope();
                                engine.DartEngine_ReleaseIsolate();
                            }
                            if (self.pending.load(.acquire) == 0) break;
                        }
                        self.notify_buf = 0;
                        self.armNotifyRead() catch {
                            // SQ full — retry at top of next submit_and_wait iteration.
                            self.notify_needs_rearm = true;
                        };
                    } else if (cqe.user_data == signal_user_data) {
                        if (cqe.res <= 0) {
                            // Spurious/non-ready signalfd completion (e.g. -EAGAIN).
                            // Re-arm and continue; this is not a real shutdown signal.
                            self.armSignalRead() catch return;
                            continue;
                        }
                        const sig_bytes = std.mem.asBytes(&self.signal_buf);
                        const signo = std.mem.readInt(u32, sig_bytes[0..4], .little);
                        if (signo != @as(u32, @intCast(posix.SIG.INT)) and signo != @as(u32, @intCast(posix.SIG.TERM))) {
                            self.armSignalRead() catch return;
                            continue;
                        }
                        // SIGINT or SIGTERM — graceful shutdown.
                        // Flush any pending batch so in-flight completions are delivered
                        // before the event loop exits (prevents hanging Dart futures).
                        if (batch_n > 0) self.flushBatch(batch[0..batch_n]);
                        return;
                    } else if (cqe.user_data == timeout_user_data and
                        cqe.res == -@as(i32, @intFromEnum(linux.E.TIME)))
                    {
                        // Only hint GC when truly idle — no pool I/O in this batch.
                        // Calling Dart_NotifyIdle mid-benchmark triggers premature GC.
                        if (!any_io) {
                            // In batch-dispatch mode (ZigIo_SetBatchPort set), this
                            // runtime is serving native I/O futures and should not
                            // auto-exit on Dart_HasLivePorts heuristics.
                            if (self.batch_port_id != 0) {
                                self.armTimeout() catch return;
                                continue;
                            }
                            if (self.isolate != null) {
                                engine.DartEngine_AcquireIsolate(self.isolate);
                                engine.Dart_NotifyIdle(std.time.microTimestamp() + 5_000);
                                const live = engine.Dart_HasLivePorts();
                                engine.DartEngine_ReleaseIsolate();
                                if (!live) {
                                    // Avoid exiting on transient false negatives from
                                    // Dart_HasLivePorts while server I/O is still active.
                                    // Require repeated idle "no-live" checks and an empty
                                    // completion pool before terminating the loop.
                                    no_live_idle_iters +%= 1;
                                    if (no_live_idle_iters >= 5 and !hasActivePoolOps(self)) {
                                        if (batch_n > 0) self.flushBatch(batch[0..batch_n]);
                                        return;
                                    }
                                } else {
                                    no_live_idle_iters = 0;
                                }
                            }
                        } else {
                            no_live_idle_iters = 0;
                        }
                        self.armTimeout() catch return;
                    } else if (cqe.user_data >= state.kPoolBase) {
                        any_io = true;
                        if (self.batch_port_id != 0) {
                            // Batch path: collect result now, post after all CQEs processed.
                            if (self.collectPoolCqe(cqe, &batch[batch_n])) {
                                batch_n += 1;
                            }
                        } else {
                            // Legacy path: post each completion individually.
                            // Used before ZigIo_SetBatchPort is called from Dart main().
                            self.dispatchPoolCqe(cqe);
                        }
                    }
                }

                // Post one batch message for all I/O completions in this copy_cqes() call.
                // Dart_PostCObject copies kTypedData bytes synchronously → safe to free
                // slots after. Mirrors kqueue's per-kevent() flushBatch call.
                if (batch_n > 0) {
                    jit_idle_iters = 0;
                    self.flushBatch(batch[0..batch_n]);
                } else if (any_io) {
                    // Pool I/O fired but no Dart messages were posted (e.g. Op.loop
                    // re-armed itself without completing to Dart). On single-core-pinned
                    // processes the JIT compiler background threads never get cooperative
                    // CPU time. Give them a safepoint every 64 iterations so the JIT can
                    // install compiled code and avoid priority inversion.
                    jit_idle_iters += 1;
                    if (jit_idle_iters >= 128 and self.isolate != null) {
                        jit_idle_iters = 0;
                        engine.DartEngine_AcquireIsolate(self.isolate);
                        engine.DartEngine_ReleaseIsolate();
                    }
                }
            }
        }
    }

    fn hasActivePoolOps(self: *EventLoop) bool {
        for (self.pool) |ctx| {
            if (ctx.in_use) return true;
        }
        return false;
    }

    // -------------------------------------------------------------------------
    // Batch types — mirror of kqueue.zig BatchKind / BatchEntry.
    // -------------------------------------------------------------------------

    const BatchKind = enum { int_val, null_val, typed_data, request_val };

    const BatchEntry = struct {
        token: engine.Dart_Port,
        slot_idx: usize,
        kind: BatchKind,
        int_val: i64 = 0,
        bytes_len: usize = 0,
    };

    fn shiftRecvRequestAfterPost(self: *EventLoop, idx: usize) void {
        const rd = &self.pool[idx].data.recv_request;
        const conn = rd.conn orelse return;
        const remaining = conn.recv_len - rd.end_off;
        if (remaining > 0) {
            std.mem.copyForwards(u8, conn.recv_buf[0..remaining], conn.recv_buf[rd.end_off..conn.recv_len]);
        }
        conn.recv_len = remaining;
    }

    fn fillReadRequestMetadata(self: *EventLoop, idx: usize) bool {
        const rd = &self.pool[idx].data.recv_request;
        const conn = rd.conn orelse return false;
        const framed = http_parser.frameRequest(conn.recv_buf[0..conn.recv_len]);
        if (framed.status == .incomplete) return false;
        if (framed.status != .complete) return false;

        const base_ptr = @intFromPtr(&conn.recv_buf);
        rd.method_off = @intFromPtr(framed.method.ptr) - base_ptr;
        rd.method_len = framed.method.len;
        rd.path_off = @intFromPtr(framed.path.ptr) - base_ptr;
        rd.path_len = framed.path.len;
        rd.body_off = framed.body_offset;
        rd.end_off = framed.end_offset;
        rd.keep_alive = framed.keep_alive;
        if (framed.chunked) {
            const decoded_len = http_parser.decodeChunkedBodyInPlace(&conn.recv_buf, framed.body_offset, framed.end_offset) orelse return false;
            rd.body_len = decoded_len;
        } else {
            rd.body_len = framed.end_offset - framed.body_offset;
        }
        return true;
    }

    fn postSingleRequestCompletion(self: *EventLoop, token: engine.Dart_Port, slot_idx: usize) void {
        const rd = &self.pool[slot_idx].data.recv_request;
        const conn = rd.conn orelse return;

        var method_obj = engine.Dart_CObject{
            .@"type" = engine.Dart_CObject_kTypedData,
            .value = .{ .as_typed_data = .{
                .data_type = engine.Dart_TypedData_kUint8,
                .length = @intCast(rd.method_len),
                .values = conn.recv_buf[rd.method_off .. rd.method_off + rd.method_len].ptr,
            } },
        };
        var path_obj = engine.Dart_CObject{
            .@"type" = engine.Dart_CObject_kTypedData,
            .value = .{ .as_typed_data = .{
                .data_type = engine.Dart_TypedData_kUint8,
                .length = @intCast(rd.path_len),
                .values = conn.recv_buf[rd.path_off .. rd.path_off + rd.path_len].ptr,
            } },
        };
        var body_obj = engine.Dart_CObject{
            .@"type" = engine.Dart_CObject_kTypedData,
            .value = .{ .as_typed_data = .{
                .data_type = engine.Dart_TypedData_kUint8,
                .length = @intCast(rd.body_len),
                .values = conn.recv_buf[rd.body_off .. rd.body_off + rd.body_len].ptr,
            } },
        };
        var flags_obj = engine.Dart_CObject{
            .@"type" = engine.Dart_CObject_kInt64,
            .value = .{ .as_int64 = if (rd.keep_alive) 1 else 0 },
        };
        var request_values = [4]?*engine.Dart_CObject{
            &method_obj,
            &path_obj,
            &body_obj,
            &flags_obj,
        };
        var request_obj = engine.Dart_CObject{
            .@"type" = engine.Dart_CObject_kArray,
            .value = .{ .as_array = .{
                .length = 4,
                .values = request_values[0..].ptr,
            } },
        };
        var token_obj = engine.Dart_CObject{
            .@"type" = engine.Dart_CObject_kInt64,
            .value = .{ .as_int64 = token },
        };
        var pair_values = [2]?*engine.Dart_CObject{ &token_obj, &request_obj };
        var pair_obj = engine.Dart_CObject{
            .@"type" = engine.Dart_CObject_kArray,
            .value = .{ .as_array = .{
                .length = 2,
                .values = pair_values[0..].ptr,
            } },
        };
        _ = engine.Dart_PostCObject(self.batch_port_id, &pair_obj);
        self.shiftRecvRequestAfterPost(slot_idx);
    }

    // -------------------------------------------------------------------------
    // collectPoolCqe — extract result from a pool CQE into a BatchEntry.
    // Returns true if the entry was populated; false if the slot was invalid.
    // -------------------------------------------------------------------------

    fn collectPoolCqe(self: *EventLoop, cqe: linux.io_uring_cqe, out: *BatchEntry) bool {
        const raw_idx = cqe.user_data - state.kPoolBase;
        if (raw_idx >= state.kPoolSize) return false;
        const idx: usize = @intCast(raw_idx);
        const ctx = &self.pool[idx];
        if (!ctx.in_use) return false;

        out.token = ctx.port_id;
        out.slot_idx = idx;

        switch (ctx.op) {
            .accept => {
                // cqe.res is the new conn fd (>=0) or -errno on error.
                if (cqe.res >= 0) setTcpNoDelay(@intCast(cqe.res));
                out.kind = .int_val;
                out.int_val = @as(i64, cqe.res);
                return true;
            },
            .recv => {
                // cqe.res > 0: bytes received; 0: EOF; <0: error.
                if (cqe.res > 0) {
                    out.kind = .typed_data;
                    out.bytes_len = @intCast(cqe.res);
                } else {
                    out.kind = .null_val;
                }
                return true;
            },
            .recv_request => {
                const rd = &ctx.data.recv_request;
                const conn = rd.conn orelse {
                    out.kind = .null_val;
                    return true;
                };
                if (cqe.res <= 0) {
                    state.request_conn_table.remove(ctx.fd);
                    out.kind = .null_val;
                    return true;
                }
                conn.recv_len += @intCast(cqe.res);
                if (self.fillReadRequestMetadata(idx)) {
                    out.kind = .request_val;
                    return true;
                }
                const framed = http_parser.frameRequest(conn.recv_buf[0..conn.recv_len]);
                if (framed.status == .invalid) {
                    state.request_conn_table.remove(ctx.fd);
                    out.kind = .null_val;
                    return true;
                }
                const space = conn.recv_buf[conn.recv_len..];
                if (space.len == 0) {
                    state.request_conn_table.remove(ctx.fd);
                    out.kind = .null_val;
                    return true;
                }
                _ = self.ring.recv(cqe.user_data, ctx.fd, .{ .buffer = space }, 0) catch {
                    state.request_conn_table.remove(ctx.fd);
                    out.kind = .null_val;
                    return true;
                };
                return false;
            },
            .recv_route => {
                // Read completed — parse+route in Zig, post a route int to Dart.
                // Eliminates Uint8List allocation, ApiMessageSerializer, memcpy, GC pressure.
                if (cqe.res > 0) {
                    out.kind = .int_val;
                    out.int_val = http_parser.routeRequest(ctx.data.recv_route.buf[0..@intCast(cqe.res)]);
                } else {
                    out.kind = .int_val;
                    out.int_val = http_parser.RouteId.eof;
                }
                return true;
            },
            .serve => {
                const sd = &ctx.data.serve;
                const user_data = cqe.user_data; // slot index encoded; reuse for write SQE
                if (!sd.write_phase) {
                    // Phase 1: recv SQE completed — accumulate, route, write inline.
                    if (cqe.res <= 0) {
                        out.kind = .int_val;
                        out.int_val = -1;
                        return true;
                    }
                    sd.recv_len += @intCast(cqe.res);
                    const route = http_parser.routeRequest(ctx.data.serve.recv_buf[0..sd.recv_len]);
                    if (route == http_parser.RouteId.incomplete) {
                        // Need more data — resubmit recv SQE into remaining buffer space.
                        const space = sd.recv_buf[sd.recv_len..];
                        if (space.len == 0) {
                            // Buffer full — send 400.
                            _ = posix.write(ctx.fd, http_responses.bad_request) catch {};
                            out.kind = .int_val;
                            out.int_val = -1;
                            return true;
                        }
                        _ = self.ring.read(user_data, ctx.fd, .{ .buffer = space }, 0) catch {
                            out.kind = .int_val;
                            out.int_val = -1;
                            return true;
                        };
                        return false; // wait for next recv
                    }
                    sd.should_close = http_responses.shouldClose(route);
                    const resp = http_responses.forRoute(route) orelse {
                        out.kind = .int_val;
                        out.int_val = -1;
                        return true;
                    };
                    // Inline posix.write fast-path — avoids a full io_uring round-trip.
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
                    // Partial write (rare) — submit write SQE for the remainder.
                    const start: usize = if (n > 0) n else 0;
                    sd.write_ptr = resp.ptr + start;
                    sd.write_len = resp.len - start;
                    sd.write_phase = true;
                    _ = self.ring.write(user_data, ctx.fd, sd.write_ptr[0..sd.write_len], 0) catch {
                        out.kind = .int_val;
                        out.int_val = -1;
                        return true;
                    };
                    return false; // wait for write SQE completion
                } else {
                    // Phase 2: write SQE completed.
                    if (cqe.res <= 0) {
                        out.kind = .int_val;
                        out.int_val = -1;
                        return true;
                    }
                    const written: usize = @intCast(cqe.res);
                    if (written < sd.write_len) {
                        // Still partial — resubmit.
                        sd.write_ptr += written;
                        sd.write_len -= written;
                        _ = self.ring.write(user_data, ctx.fd, sd.write_ptr[0..sd.write_len], 0) catch {
                            out.kind = .int_val;
                            out.int_val = -1;
                            return true;
                        };
                        return false;
                    }
                    out.kind = .int_val;
                    out.int_val = if (sd.should_close) -1 else 0;
                    return true;
                }
            },
            .loop => {
                const sd = &ctx.data.loop;
                const user_data = cqe.user_data;
                if (!sd.write_phase) {
                    // Recv SQE completed — accumulate and run pipeline loop.
                    if (cqe.res <= 0) {
                        posix.close(ctx.fd);
                        out.kind = .int_val;
                        out.int_val = -1;
                        return true;
                    }
                    sd.recv_len += @intCast(cqe.res);
                } else {
                    // Write SQE completed — advance buffer, clear write_phase.
                    if (cqe.res <= 0) {
                        posix.close(ctx.fd);
                        out.kind = .int_val;
                        out.int_val = -1;
                        return true;
                    }
                    const written: usize = @intCast(cqe.res);
                    if (written < sd.write_len) {
                        // Still partial — resubmit send SQE.
                        sd.write_ptr += written;
                        sd.write_len -= written;
                        _ = self.ring.send(user_data, ctx.fd, sd.write_ptr[0..sd.write_len], linux.MSG.NOSIGNAL) catch {
                            posix.close(ctx.fd);
                            out.kind = .int_val;
                            out.int_val = -1;
                            return true;
                        };
                        return false;
                    }
                    if (sd.should_close) {
                        posix.close(ctx.fd);
                        out.kind = .int_val;
                        out.int_val = -1;
                        return true;
                    }
                    sd.write_phase = false;
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
                const sd = &ctx.data.send;
                if (cqe.res <= 0) {
                    out.kind = .int_val;
                    out.int_val = -1;
                    return true;
                }
                sd.sent += @intCast(cqe.res);
                if (sd.sent < sd.len) {
                    _ = self.ring.send(cqe.user_data, ctx.fd, sd.remaining(), linux.MSG.NOSIGNAL) catch {
                        out.kind = .int_val;
                        out.int_val = -1;
                        return true;
                    };
                    return false;
                }
                out.kind = .int_val;
                out.int_val = @intCast(sd.len);
                return true;
            },
            .tls_handshake => {
                const tls_id = ctx.tls_id;
                if (tls_id == 0 or cqe.res <= 0) {
                    out.kind = .int_val;
                    out.int_val = -1;
                    if (tls_id != 0) tls_module.freeConn(tls_id);
                    return true;
                }
                if (!tls_module.feedRecv(tls_id, ctx.data.recv.buf[0..@intCast(cqe.res)])) {
                    out.kind = .int_val;
                    out.int_val = -1;
                    tls_module.freeConn(tls_id);
                    return true;
                }

                switch (tls_module.advanceHandshake(tls_id)) {
                    .done => {
                        out.kind = .int_val;
                        out.int_val = tls_id;
                        return true;
                    },
                    .want_read, .want_write => {
                        _ = self.ring.read(
                            cqe.user_data,
                            ctx.fd,
                            .{ .buffer = ctx.data.recv.buf[0..] },
                            0,
                        ) catch {
                            out.kind = .int_val;
                            out.int_val = -1;
                            tls_module.freeConn(tls_id);
                            return true;
                        };
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

    // -------------------------------------------------------------------------
    // flushBatch — build one Dart_CObject_kArray with
    // [token0, value0, token1, value1, ...] and post it to batch_port_id.
    // All pool slots are freed after the post (kTypedData bytes are copied
    // synchronously by Dart_PostCObject before this function returns).
    // -------------------------------------------------------------------------

    fn flushBatch(self: *EventLoop, batch: []BatchEntry) void {
        var token_objs: [32]engine.Dart_CObject = undefined;
        var value_objs: [32]engine.Dart_CObject = undefined;
        var ptrs: [64]?*engine.Dart_CObject = undefined;
        var request_objs: [32]engine.Dart_CObject = undefined;
        var method_objs: [32]engine.Dart_CObject = undefined;
        var path_objs: [32]engine.Dart_CObject = undefined;
        var body_objs: [32]engine.Dart_CObject = undefined;
        var flags_objs: [32]engine.Dart_CObject = undefined;
        var request_values: [32][4]?*engine.Dart_CObject = undefined;

        for (batch, 0..) |entry, i| {
            token_objs[i] = .{
                .@"type" = engine.Dart_CObject_kInt64,
                .value = .{ .as_int64 = entry.token },
            };
            value_objs[i] = switch (entry.kind) {
                .int_val => .{
                    .@"type" = engine.Dart_CObject_kInt64,
                    .value = .{ .as_int64 = entry.int_val },
                },
                .null_val => .{
                    .@"type" = engine.Dart_CObject_kNull,
                    .value = .{ .as_int64 = 0 },
                },
                .typed_data => .{
                    .@"type" = engine.Dart_CObject_kTypedData,
                    .value = .{ .as_typed_data = .{
                        .data_type = engine.Dart_TypedData_kUint8,
                        .length = @intCast(entry.bytes_len),
                        .values = self.pool[entry.slot_idx].data.recv.buf[0..entry.bytes_len].ptr,
                    } },
                },
                .request_val => blk: {
                    const rd = &self.pool[entry.slot_idx].data.recv_request;
                    const conn = rd.conn orelse break :blk .{
                        .@"type" = engine.Dart_CObject_kNull,
                        .value = .{ .as_int64 = 0 },
                    };

                    method_objs[i] = .{
                        .@"type" = engine.Dart_CObject_kTypedData,
                        .value = .{ .as_typed_data = .{
                            .data_type = engine.Dart_TypedData_kUint8,
                            .length = @intCast(rd.method_len),
                            .values = conn.recv_buf[rd.method_off .. rd.method_off + rd.method_len].ptr,
                        } },
                    };
                    path_objs[i] = .{
                        .@"type" = engine.Dart_CObject_kTypedData,
                        .value = .{ .as_typed_data = .{
                            .data_type = engine.Dart_TypedData_kUint8,
                            .length = @intCast(rd.path_len),
                            .values = conn.recv_buf[rd.path_off .. rd.path_off + rd.path_len].ptr,
                        } },
                    };
                    body_objs[i] = .{
                        .@"type" = engine.Dart_CObject_kTypedData,
                        .value = .{ .as_typed_data = .{
                            .data_type = engine.Dart_TypedData_kUint8,
                            .length = @intCast(rd.body_len),
                            .values = conn.recv_buf[rd.body_off .. rd.body_off + rd.body_len].ptr,
                        } },
                    };
                    flags_objs[i] = .{
                        .@"type" = engine.Dart_CObject_kInt64,
                        .value = .{ .as_int64 = if (rd.keep_alive) 1 else 0 },
                    };
                    request_values[i] = .{
                        &method_objs[i],
                        &path_objs[i],
                        &body_objs[i],
                        &flags_objs[i],
                    };
                    request_objs[i] = .{
                        .@"type" = engine.Dart_CObject_kArray,
                        .value = .{ .as_array = .{
                            .length = 4,
                            .values = request_values[i][0..].ptr,
                        } },
                    };
                    break :blk request_objs[i];
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
            if (entry.kind == .request_val) {
                self.shiftRecvRequestAfterPost(entry.slot_idx);
            }
            state.freeSlot(self.pool, &self.slot_alloc, entry.slot_idx);
        }
    }

    // -------------------------------------------------------------------------
    // postSingleCompletion — post one completion, routing through the batch
    // port when active (batch_port_id != 0) or falling back to direct posting.
    //
    // Used by submit* vtable functions for their synchronous fast-path and
    // error cases — these can fire both before and after batch mode is enabled.
    // slot_idx is only accessed for .typed_data (recv buffer pointer); pass 0
    // for .int_val and .null_val cases.
    // -------------------------------------------------------------------------

    fn postSingleCompletion(
        self: *EventLoop,
        token: engine.Dart_Port,
        slot_idx: usize,
        kind: BatchKind,
        int_val: i64,
        bytes_len: usize,
    ) void {
        if (self.batch_port_id != 0) {
            if (kind == .request_val) {
                self.postSingleRequestCompletion(token, slot_idx);
                return;
            }
            // Batch mode: wrap as a 2-element kArray [token, value] so the
            // Dart _ZigIoDispatcher._onBatch handler can route it correctly.
            var token_obj = engine.Dart_CObject{
                .@"type" = engine.Dart_CObject_kInt64,
                .value = .{ .as_int64 = token },
            };
            var value_obj: engine.Dart_CObject = switch (kind) {
                .int_val => .{
                    .@"type" = engine.Dart_CObject_kInt64,
                    .value = .{ .as_int64 = int_val },
                },
                .null_val => .{
                    .@"type" = engine.Dart_CObject_kNull,
                    .value = .{ .as_int64 = 0 },
                },
                .typed_data => .{
                    .@"type" = engine.Dart_CObject_kTypedData,
                    .value = .{ .as_typed_data = .{
                        .data_type = engine.Dart_TypedData_kUint8,
                        .length = @intCast(bytes_len),
                        .values = self.pool[slot_idx].data.recv.buf[0..bytes_len].ptr,
                    } },
                },
                .request_val => unreachable,
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

        // Legacy mode: post directly to the real Dart_Port stored in token.
        switch (kind) {
            .int_val => {
                _ = engine.Dart_PostInteger(token, int_val);
            },
            .null_val => {
                // EOF / error on recv — post null via postRecvResult helper.
                state.postRecvResult(token, -1, self.pool[slot_idx].data.recv.buf[0..0]);
            },
            .typed_data => {
                state.postRecvResult(
                    token,
                    @intCast(bytes_len),
                    self.pool[slot_idx].data.recv.buf[0..bytes_len],
                );
            },
            .request_val => {
                self.postSingleRequestCompletion(token, slot_idx);
            },
        }
    }

    /// Process the pipelining inner loop for an Op.loop slot (io_uring path).
    /// Returns null if the slot was re-armed (SQE submitted, no Dart post).
    /// Returns i64 if the connection should close (post this value to Dart).
    fn processLoopPipeline(self: *EventLoop, idx: usize) ?i64 {
        const ctx = &self.pool[idx];
        const sd = &ctx.data.loop;
        const user_data: u64 = state.kPoolBase + @as(u64, idx);
        while (true) {
            const rr = http_parser.routeRequestFull(sd.recv_buf[0..sd.recv_len]);
            if (rr.route == http_parser.RouteId.incomplete) {
                // Need more data — resubmit recv SQE into remaining buffer space.
                const space = sd.recv_buf[sd.recv_len..];
                if (space.len == 0) return -1; // buffer full — close
                _ = self.ring.recv(user_data, ctx.fd, .{ .buffer = space }, 0) catch return -1;
                return null;
            }
            const resp = http_responses.forRoute(rr.route) orelse return -1;
            const close = http_responses.shouldClose(rr.route);
            // Submit send SQE — socket path, bypasses VFS layer.
            // io_uring batches all pending sends in one enter().
            sd.write_ptr = resp.ptr;
            sd.write_len = resp.len;
            sd.write_phase = true;
            sd.should_close = close;
            sd.pending_consumed = rr.consumed;
            _ = self.ring.send(user_data, ctx.fd, sd.write_ptr[0..sd.write_len], linux.MSG.NOSIGNAL) catch return -1;
            return null;
            // (pipelining: write CQE handler calls processLoopPipeline again)
        }
    }

    // -------------------------------------------------------------------------
    // dispatchPoolCqe — legacy (non-batch) dispatch.
    // Only called when batch_port_id == 0 (before ZigIo_SetBatchPort fires).
    // In this mode ctx.port_id is a real Dart_Port, not a token.
    // -------------------------------------------------------------------------

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
            .recv_request => {
                const rd = &ctx.data.recv_request;
                const conn = rd.conn orelse {
                    state.freeSlot(self.pool, &self.slot_alloc, idx);
                    return;
                };
                if (cqe.res <= 0) {
                    state.request_conn_table.remove(ctx.fd);
                    state.postRecvResult(ctx.port_id, -1, conn.recv_buf[0..0]);
                    state.freeSlot(self.pool, &self.slot_alloc, idx);
                    return;
                }
                conn.recv_len += @intCast(cqe.res);
                if (self.fillReadRequestMetadata(idx)) {
                    self.postSingleRequestCompletion(ctx.port_id, idx);
                    state.freeSlot(self.pool, &self.slot_alloc, idx);
                    return;
                }
                const framed = http_parser.frameRequest(conn.recv_buf[0..conn.recv_len]);
                if (framed.status == .invalid) {
                    state.request_conn_table.remove(ctx.fd);
                    state.postRecvResult(ctx.port_id, -1, conn.recv_buf[0..0]);
                    state.freeSlot(self.pool, &self.slot_alloc, idx);
                    return;
                }
                const space = conn.recv_buf[conn.recv_len..];
                if (space.len == 0) {
                    state.request_conn_table.remove(ctx.fd);
                    state.postRecvResult(ctx.port_id, -1, conn.recv_buf[0..0]);
                    state.freeSlot(self.pool, &self.slot_alloc, idx);
                    return;
                }
                _ = self.ring.recv(cqe.user_data, ctx.fd, .{ .buffer = space }, 0) catch {
                    state.request_conn_table.remove(ctx.fd);
                    state.postRecvResult(ctx.port_id, -1, conn.recv_buf[0..0]);
                    state.freeSlot(self.pool, &self.slot_alloc, idx);
                };
            },
            .recv_route => {
                // Legacy path: parse+route in Zig, post int directly.
                const route: i64 = if (cqe.res > 0)
                    http_parser.routeRequest(ctx.data.recv_route.buf[0..@intCast(cqe.res)])
                else
                    http_parser.RouteId.eof;
                _ = engine.Dart_PostInteger(ctx.port_id, route);
                state.freeSlot(self.pool, &self.slot_alloc, idx);
            },
            .serve => {
                // Legacy path: accumulate recv then synchronous blocking write.
                const sd = &ctx.data.serve;
                if (cqe.res <= 0) {
                    _ = engine.Dart_PostInteger(ctx.port_id, -1);
                    state.freeSlot(self.pool, &self.slot_alloc, idx);
                    return;
                }
                sd.recv_len += @intCast(cqe.res);
                const route = http_parser.routeRequest(sd.recv_buf[0..sd.recv_len]);
                // In the legacy path, resubmit recv synchronously for incomplete.
                if (route == http_parser.RouteId.incomplete) {
                    const space = sd.recv_buf[sd.recv_len..];
                    if (space.len > 0) {
                        _ = self.ring.read(
                            state.kPoolBase + @as(u64, idx),
                            ctx.fd,
                            .{ .buffer = space },
                            0,
                        ) catch {
                            _ = engine.Dart_PostInteger(ctx.port_id, -1);
                            state.freeSlot(self.pool, &self.slot_alloc, idx);
                            return;
                        };
                    } else {
                        _ = engine.Dart_PostInteger(ctx.port_id, -1);
                        state.freeSlot(self.pool, &self.slot_alloc, idx);
                    }
                    return;
                }
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
                if (cqe.res <= 0) {
                    _ = engine.Dart_PostInteger(ctx.port_id, -1);
                    state.freeSlot(self.pool, &self.slot_alloc, idx);
                    return;
                }
                sd.recv_len += @intCast(cqe.res);
                // Pipeline: serve all complete requests in recv_buf.
                while (true) {
                    const rr = http_parser.routeRequestFull(sd.recv_buf[0..sd.recv_len]);
                    if (rr.route == http_parser.RouteId.incomplete) {
                        // Need more data — resubmit recv.
                        const space = sd.recv_buf[sd.recv_len..];
                        if (space.len > 0) {
                            _ = self.ring.read(state.kPoolBase + @as(u64, idx), ctx.fd, .{ .buffer = space }, 0) catch {
                                _ = engine.Dart_PostInteger(ctx.port_id, -1);
                                state.freeSlot(self.pool, &self.slot_alloc, idx);
                                return;
                            };
                        } else {
                            _ = engine.Dart_PostInteger(ctx.port_id, -1);
                            state.freeSlot(self.pool, &self.slot_alloc, idx);
                        }
                        return;
                    }
                    const close = http_responses.shouldClose(rr.route);
                    if (http_responses.forRoute(rr.route)) |resp| {
                        var written: usize = 0;
                        while (written < resp.len) {
                            const n = posix.write(ctx.fd, resp[written..]) catch break;
                            if (n == 0) break;
                            written += n;
                        }
                    }
                    if (close) {
                        _ = engine.Dart_PostInteger(ctx.port_id, -1);
                        state.freeSlot(self.pool, &self.slot_alloc, idx);
                        return;
                    }
                    const remaining = sd.recv_len - rr.consumed;
                    if (remaining > 0) {
                        std.mem.copyForwards(u8, sd.recv_buf[0..remaining], sd.recv_buf[rr.consumed..sd.recv_len]);
                    }
                    sd.recv_len = remaining;
                    if (remaining == 0) {
                        // Buffer empty — resubmit recv for next request.
                        _ = self.ring.read(state.kPoolBase + @as(u64, idx), ctx.fd, .{ .buffer = sd.recv_buf[0..] }, 0) catch {
                            _ = engine.Dart_PostInteger(ctx.port_id, -1);
                            state.freeSlot(self.pool, &self.slot_alloc, idx);
                            return;
                        };
                        return;
                    }
                }
            },
            .send => {
                const sd = &ctx.data.send;
                if (cqe.res <= 0) {
                    _ = engine.Dart_PostInteger(ctx.port_id, -1);
                    state.freeSlot(self.pool, &self.slot_alloc, idx);
                    return;
                }
                sd.sent += @intCast(cqe.res);
                if (sd.sent < sd.len) {
                    _ = self.ring.send(cqe.user_data, ctx.fd, sd.remaining(), linux.MSG.NOSIGNAL) catch {
                        _ = engine.Dart_PostInteger(ctx.port_id, -1);
                        state.freeSlot(self.pool, &self.slot_alloc, idx);
                        return;
                    };
                    return;
                }
                _ = engine.Dart_PostInteger(ctx.port_id, @intCast(sd.len));
                state.freeSlot(self.pool, &self.slot_alloc, idx);
            },
            .tls_handshake => {
                const tls_id = ctx.tls_id;
                if (tls_id == 0 or cqe.res <= 0) {
                    _ = engine.Dart_PostInteger(ctx.port_id, -1);
                    if (tls_id != 0) tls_module.freeConn(tls_id);
                    state.freeSlot(self.pool, &self.slot_alloc, idx);
                    return;
                }
                if (!tls_module.feedRecv(tls_id, ctx.data.recv.buf[0..@intCast(cqe.res)])) {
                    _ = engine.Dart_PostInteger(ctx.port_id, -1);
                    tls_module.freeConn(tls_id);
                    state.freeSlot(self.pool, &self.slot_alloc, idx);
                    return;
                }

                switch (tls_module.advanceHandshake(tls_id)) {
                    .done => {
                        _ = engine.Dart_PostInteger(ctx.port_id, tls_id);
                        state.freeSlot(self.pool, &self.slot_alloc, idx);
                    },
                    .want_read, .want_write => {
                        _ = self.ring.read(
                            cqe.user_data,
                            ctx.fd,
                            .{ .buffer = ctx.data.recv.buf[0..] },
                            0,
                        ) catch {
                            _ = engine.Dart_PostInteger(ctx.port_id, -1);
                            tls_module.freeConn(tls_id);
                            state.freeSlot(self.pool, &self.slot_alloc, idx);
                            return;
                        };
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
//
// Error paths use postSingleCompletion() so completions are correctly routed
// to the batch port when active — preventing hanging Dart futures on errors
// that occur after ZigIo_SetBatchPort has been called.
// ---------------------------------------------------------------------------

const uring_ops = state.LoopOps{
    .submit_accept = submitAccept,
    .submit_recv = submitRecv,
    .submit_recv_request = submitRecvRequest,
    .submit_recv_route = submitRecvRoute,
    .submit_serve = submitServe,
    .submit_loop = submitLoop,
    .submit_send = submitSend,
};

fn submitAccept(loop: *anyopaque, slot_idx: usize, fd: posix.fd_t) void {
    const self: *EventLoop = @ptrCast(@alignCast(loop));
    const ctx = &self.pool[slot_idx];
    const user_data: u64 = state.kPoolBase + @as(u64, slot_idx);
    const accept_flags: u32 = linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC;
    _ = self.ring.accept(user_data, fd, null, null, accept_flags) catch {
        self.postSingleCompletion(ctx.port_id, slot_idx, .int_val, -1, 0);
        state.freeSlot(self.pool, &self.slot_alloc, slot_idx);
    };
}

fn submitRecv(loop: *anyopaque, slot_idx: usize, fd: posix.fd_t) void {
    const self: *EventLoop = @ptrCast(@alignCast(loop));
    const ctx = &self.pool[slot_idx];
    const user_data: u64 = state.kPoolBase + @as(u64, slot_idx);
    // Kernel reads directly into the pool slot's embedded recv buffer — no alloc.
    _ = self.ring.read(user_data, fd, .{ .buffer = ctx.data.recv.buf[0..] }, 0) catch {
        self.postSingleCompletion(ctx.port_id, slot_idx, .null_val, 0, 0);
        state.freeSlot(self.pool, &self.slot_alloc, slot_idx);
    };
}

fn submitRecvRequest(loop: *anyopaque, slot_idx: usize, fd: posix.fd_t) void {
    const self: *EventLoop = @ptrCast(@alignCast(loop));
    const ctx = &self.pool[slot_idx];
    const rd = &ctx.data.recv_request;
    const conn = rd.conn orelse {
        self.postSingleCompletion(ctx.port_id, slot_idx, .null_val, 0, 0);
        state.freeSlot(self.pool, &self.slot_alloc, slot_idx);
        return;
    };

    if (conn.recv_len > 0 and self.fillReadRequestMetadata(slot_idx)) {
        self.postSingleRequestCompletion(ctx.port_id, slot_idx);
        state.freeSlot(self.pool, &self.slot_alloc, slot_idx);
        return;
    }

    const framed: http_parser.FramedRequest = if (conn.recv_len > 0)
        http_parser.frameRequest(conn.recv_buf[0..conn.recv_len])
    else
        .{ .status = http_parser.ParseStatus.incomplete };
    if (framed.status == .invalid) {
        state.request_conn_table.remove(fd);
        self.postSingleCompletion(ctx.port_id, slot_idx, .null_val, 0, 0);
        state.freeSlot(self.pool, &self.slot_alloc, slot_idx);
        return;
    }

    const user_data: u64 = state.kPoolBase + @as(u64, slot_idx);
    const space = conn.recv_buf[conn.recv_len..];
    if (space.len == 0) {
        state.request_conn_table.remove(fd);
        self.postSingleCompletion(ctx.port_id, slot_idx, .null_val, 0, 0);
        state.freeSlot(self.pool, &self.slot_alloc, slot_idx);
        return;
    }
    _ = self.ring.recv(user_data, fd, .{ .buffer = space }, 0) catch {
        state.request_conn_table.remove(fd);
        self.postSingleCompletion(ctx.port_id, slot_idx, .null_val, 0, 0);
        state.freeSlot(self.pool, &self.slot_alloc, slot_idx);
    };
}

/// Arm a recv SQE for a serve slot. The completion handler does read+route+write.
fn submitServe(loop: *anyopaque, slot_idx: usize, fd: posix.fd_t) void {
    const self: *EventLoop = @ptrCast(@alignCast(loop));
    const ctx = &self.pool[slot_idx];
    const user_data: u64 = state.kPoolBase + @as(u64, slot_idx);
    _ = self.ring.read(user_data, fd, .{ .buffer = ctx.data.serve.recv_buf[0..] }, 0) catch {
        self.postSingleCompletion(ctx.port_id, slot_idx, .int_val, -1, 0);
        state.freeSlot(self.pool, &self.slot_alloc, slot_idx);
    };
}

/// Arm a recv SQE for a loop slot. Completion handler handles entire keep-alive connection.
fn submitLoop(loop: *anyopaque, slot_idx: usize, fd: posix.fd_t) void {
    const self: *EventLoop = @ptrCast(@alignCast(loop));
    const ctx = &self.pool[slot_idx];
    const user_data: u64 = state.kPoolBase + @as(u64, slot_idx);
    _ = self.ring.recv(user_data, fd, .{ .buffer = ctx.data.loop.recv_buf[0..] }, 0) catch {
        self.postSingleCompletion(ctx.port_id, slot_idx, .int_val, -1, 0);
        state.freeSlot(self.pool, &self.slot_alloc, slot_idx);
    };
}

fn submitRecvRoute(loop: *anyopaque, slot_idx: usize, fd: posix.fd_t) void {
    const self: *EventLoop = @ptrCast(@alignCast(loop));
    const ctx = &self.pool[slot_idx];
    const user_data: u64 = state.kPoolBase + @as(u64, slot_idx);
    // Kernel reads directly into recv_route buffer; completion handler routes to an int.
    _ = self.ring.read(user_data, fd, .{ .buffer = ctx.data.recv_route.buf[0..] }, 0) catch {
        self.postSingleCompletion(ctx.port_id, slot_idx, .int_val, http_parser.RouteId.eof, 0);
        state.freeSlot(self.pool, &self.slot_alloc, slot_idx);
    };
}

fn submitSend(loop: *anyopaque, slot_idx: usize, fd: posix.fd_t, buf: []const u8) void {
    const self: *EventLoop = @ptrCast(@alignCast(loop));
    const ctx = &self.pool[slot_idx];
    const sd = &ctx.data.send;
    const user_data: u64 = state.kPoolBase + @as(u64, slot_idx);

    // Inline fast-path: try posix.write() before touching the ring.
    // On loopback the TCP send buffer is never full for 1–8 KB payloads,
    // so write() almost always succeeds immediately — eliminating one full
    // io_uring_enter round-trip and one eventfd wakeup per echo.
    // This mirrors what kqueue's submitSend already does and what dart:io
    // does (SocketBase::Write → write() before any epoll registration).
    const n = posix.write(fd, buf) catch |err| blk: {
        if (err == error.WouldBlock) break :blk @as(usize, 0); // EAGAIN → SQE path
        // Hard error (EBADF, EPIPE, etc.) — notify Dart immediately via
        // postSingleCompletion so batch-mode futures complete on errors too.
        self.postSingleCompletion(ctx.port_id, slot_idx, .int_val, -1, 0);
        state.freeSlot(self.pool, &self.slot_alloc, slot_idx);
        return;
    };
    if (n > 0) {
        sd.sent += n;
        if (sd.sent == sd.len) {
            // Entire payload sent inline — no SQE needed.
            self.postSingleCompletion(ctx.port_id, slot_idx, .int_val, @intCast(sd.len), 0);
            state.freeSlot(self.pool, &self.slot_alloc, slot_idx);
            return;
        }
    }
    // n == 0 means EAGAIN; n > 0 but sd.sent < sd.len means short write.
    _ = self.ring.send(user_data, fd, sd.remaining(), linux.MSG.NOSIGNAL) catch {
        self.postSingleCompletion(ctx.port_id, slot_idx, .int_val, -1, 0);
        state.freeSlot(self.pool, &self.slot_alloc, slot_idx);
    };
}

fn setTcpNoDelay(fd: posix.fd_t) void {
    const one = std.mem.toBytes(@as(c_int, 1));
    posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, &one) catch {};
}
