/// Hot-path latency profiler for dart-zig.
///
/// Measures three intervals per I/O operation:
///
///   [A] post→native   Time from Dart_PostCObject (flushBatch) to the next
///                     native function entry. This is the pure Dart overhead:
///                     message delivery + Completer lookup + .complete() +
///                     async continuation resume + native call setup.
///                     ← THE most important number. High here = Dart scheduling
///                       is the bottleneck.
///
///   [B] native→post   Time inside a native function from entry to when it
///                     calls postTokenXxx / flushBatch. This is Zig/kernel work.
///                     Should be < 2µs for simple I/O ops.
///
///   [C] kevent→flush  Time from kevent() returning to flushBatch() being called.
///                     This is event-loop Zig overhead (collectPoolEvent loop).
///                     Should be < 1µs for small batches.
///
/// Enable by setting `pub const enabled = true` below, then rebuild.
/// The report is printed to stderr every REPORT_EVERY native calls.
///
/// Usage: in kqueue.zig and natives/tcp.zig, call:
///
///   profiler.onKeventReturn()     after kevent() call
///   profiler.onFlushBatch()       just before Dart_PostCObject in flushBatch
///   profiler.onNativeEntry(.xxx)  at the top of each token native
///
const std = @import("std");

/// Set to false to compile out all profiling with zero overhead.
pub const enabled = false;

/// Print a report every N native calls.
const REPORT_EVERY: u64 = 10_000;

/// Outlier filter: ignore samples > this many ns (e.g. context switches).
const MAX_SAMPLE_NS: u64 = 5_000_000; // 5ms

pub const Op = enum { accept, read, write, tls_upgrade, tls_read, tls_write };

// ── Rolling statistics ────────────────────────────────────────────────────────

const Stats = struct {
    count: u64 = 0,
    sum: u64 = 0,
    min: u64 = std.math.maxInt(u64),
    max: u64 = 0,

    fn record(s: *Stats, ns: u64) void {
        s.count += 1;
        s.sum += ns;
        if (ns < s.min) s.min = ns;
        if (ns > s.max) s.max = ns;
    }

    fn mean(s: *const Stats) u64 {
        return if (s.count == 0) 0 else s.sum / s.count;
    }

    fn reset(s: *Stats) void {
        s.* = .{};
    }
};

// ── Per-op breakdown ──────────────────────────────────────────────────────────

const OpStats = struct {
    post_to_native: Stats = .{},  // [A] Dart scheduling overhead
    native_to_post: Stats = .{},  // [B] Zig/kernel work
    count: u64 = 0,

    fn reset(s: *OpStats) void {
        s.post_to_native.reset();
        s.native_to_post.reset();
        s.count = 0;
    }
};

// ── Profiler state (threadlocal — one per worker) ─────────────────────────────

pub const Profiler = struct {
    ops: [6]OpStats = [_]OpStats{.{}} ** 6,
    kevent_to_flush: Stats = .{},  // [C] event-loop overhead
    batch_size: Stats = .{},       // events per kevent() call

    total_calls: u64 = 0,
    last_report: u64 = 0,

    // Timestamp tracking
    t_kevent: i128 = 0,    // set by onKeventReturn
    t_post: i128 = 0,      // set by onFlushBatch
    t_native: i128 = 0,    // set by onNativeEntry
    current_op: Op = .read,

    pub fn onKeventReturn(self: *Profiler, n_events: usize) void {
        self.t_kevent = std.time.nanoTimestamp();
        self.batch_size.record(@intCast(n_events));
    }

    pub fn onFlushBatch(self: *Profiler) void {
        const now = std.time.nanoTimestamp();
        // [C] kevent → flush
        if (self.t_kevent > 0) {
            const ns: u64 = @intCast(now - self.t_kevent);
            if (ns < MAX_SAMPLE_NS) self.kevent_to_flush.record(ns);
            self.t_kevent = 0;
        }
        self.t_post = now;
    }

    pub fn onNativeEntry(self: *Profiler, op: Op) void {
        const now = std.time.nanoTimestamp();
        self.t_native = now;
        self.current_op = op;
        // [A] post → native (Dart scheduling round-trip)
        if (self.t_post > 0) {
            const ns: u64 = @intCast(now - self.t_post);
            if (ns < MAX_SAMPLE_NS) {
                self.ops[@intFromEnum(op)].post_to_native.record(ns);
            }
            self.t_post = 0;
        }
    }

    pub fn onNativePost(self: *Profiler) void {
        const now = std.time.nanoTimestamp();
        // [B] native → post (Zig work duration)
        if (self.t_native > 0) {
            const ns: u64 = @intCast(now - self.t_native);
            if (ns < MAX_SAMPLE_NS) {
                self.ops[@intFromEnum(self.current_op)].native_to_post.record(ns);
                self.ops[@intFromEnum(self.current_op)].count += 1;
            }
            self.t_native = 0;
        }
        self.total_calls += 1;
        if (self.total_calls - self.last_report >= REPORT_EVERY) {
            self.report();
            self.last_report = self.total_calls;
            self.resetStats();
        }
    }

    fn resetStats(self: *Profiler) void {
        for (&self.ops) |*o| o.reset();
        self.kevent_to_flush.reset();
        self.batch_size.reset();
    }

    fn report(self: *const Profiler) void {
        const op_names = [_][]const u8{
            "accept", "read  ", "write ", "tls_up", "tls_rd", "tls_wr",
        };
        std.debug.print(
            "\n╔══ dart-zig profiler  ({d} total calls) ══════════════════════════╗\n" ++
            "║  interval           avg       min       max      samples       ║\n" ++
            "╠═══════════════════════════════════════════════════════════════════╣\n",
            .{self.total_calls},
        );
        std.debug.print(
            "║  [C] kevent→flush   {d:>6}ns  {d:>6}ns  {d:>8}ns  {d:>8}     ║\n",
            .{
                self.kevent_to_flush.mean(),
                if (self.kevent_to_flush.min == std.math.maxInt(u64)) 0 else self.kevent_to_flush.min,
                self.kevent_to_flush.max,
                self.kevent_to_flush.count,
            },
        );
        std.debug.print(
            "║  batch size         {d:>6.1}             (events/kevent call)       ║\n",
            .{if (self.batch_size.count == 0) @as(f64, 0) else @as(f64, @floatFromInt(self.batch_size.sum)) / @as(f64, @floatFromInt(self.batch_size.count))},
        );
        std.debug.print(
            "╠═══════════════════════════════════════════════════════════════════╣\n" ++
            "║  op      interval   avg       min       max      calls          ║\n" ++
            "╠═══════════════════════════════════════════════════════════════════╣\n",
            .{},
        );
        for (self.ops, 0..) |o, i| {
            if (o.count == 0) continue;
            std.debug.print(
                "║  {s}  [A]post→nat {d:>6}ns  {d:>6}ns  {d:>8}ns  {d:>8}     ║\n",
                .{
                    op_names[i],
                    o.post_to_native.mean(),
                    if (o.post_to_native.min == std.math.maxInt(u64)) 0 else o.post_to_native.min,
                    o.post_to_native.max,
                    o.post_to_native.count,
                },
            );
            std.debug.print(
                "║  {s}  [B]nat→post {d:>6}ns  {d:>6}ns  {d:>8}ns  {d:>8}     ║\n",
                .{
                    op_names[i],
                    o.native_to_post.mean(),
                    if (o.native_to_post.min == std.math.maxInt(u64)) 0 else o.native_to_post.min,
                    o.native_to_post.max,
                    o.count,
                },
            );
        }
        std.debug.print(
            "╚══════════════════════════════════════════════════════════════════╝\n",
            .{},
        );
    }
};

pub threadlocal var p: Profiler = .{};
