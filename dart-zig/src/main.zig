const std = @import("std");
const posix = std.posix;
const engine = @import("engine.zig");
const EventLoop = @import("event_loop/common.zig").EventLoop;
const zig_io_resolver = @import("zig_io/resolver.zig");
const zig_http_resolver = @import("http/resolver.zig");

fn printEngineError(step: []const u8, err: ?[*:0]u8) void {
    if (err) |msg| {
        std.debug.print("{s} failed: {s}\n", .{ step, std.mem.span(msg) });
        return;
    }
    std.debug.print("{s} failed\n", .{step});
}

fn printDartHandleError(step: []const u8, handle: engine.DartHandle) void {
    if (handle != null and engine.Dart_IsError(handle)) {
        std.debug.print("{s} failed: {s}\n", .{ step, std.mem.span(engine.Dart_GetError(handle)) });
        return;
    }
    std.debug.print("{s} failed\n", .{step});
}

// Serializes concurrent isolate creation. The Dart VM does not support
// concurrent DartEngine_CreateIsolate calls from multiple threads.
var init_mutex = std.Thread.Mutex{};

const WorkerArgs = struct {
    snapshot: engine.SnapshotData,
    snapshot_path: [:0]const u8,
    dart_argv: []const [*:0]const u8,
    worker_id: usize,
};

/// Initialize one worker under the global init mutex.
/// out_loop must point to storage that outlives the call (caller's stack frame).
/// The scheduler captures &out_loop, so the address MUST be stable after return.
/// On success, out_loop is fully initialized and caller owns it (must call deinit).
/// On error, out_loop is cleaned up before returning; caller must NOT deinit it.
fn workerInit(wargs: *const WorkerArgs, out_loop: *EventLoop) !void {
    init_mutex.lock();
    defer init_mutex.unlock();

    out_loop.* = try EventLoop.init(null);
    errdefer out_loop.deinit();

    // Set the default scheduler using out_loop — stable address in the caller's frame.
    // Needed before CreateIsolate in case the engine posts messages during setup.
    engine.DartEngine_SetDefaultMessageScheduler(out_loop.toScheduler());

    var err: ?[*:0]u8 = null;
    const isolate = engine.DartEngine_CreateIsolate(wargs.snapshot, &err) orelse {
        printEngineError("DartEngine_CreateIsolate", err);
        return error.IsolateCreateFailed;
    };
    out_loop.isolate = isolate;

    // Also set per-isolate scheduler so multicore workers each wake their own loop.
    engine.DartEngine_SetMessageScheduler(out_loop.toScheduler(), isolate);

    {
        engine.DartEngine_AcquireIsolate(isolate);
        defer engine.DartEngine_ReleaseIsolate();

        engine.Dart_EnterScope();
        defer engine.Dart_ExitScope();

        const root_lib = engine.Dart_RootLibrary();
        if (root_lib == null or engine.Dart_IsError(root_lib)) {
            printDartHandleError("Dart_RootLibrary", root_lib);
            return error.RootLibFailed;
        }

        // Install native resolvers (ZigIo + ZigHttp) on all loaded libraries.
        installAllResolvers();

        // Build List<String> from dart_argv and invoke _startMainIsolate.
        const core_lib = engine.Dart_LookupLibrary(engine.Dart_NewStringFromCString("dart:core"));
        if (core_lib == null or engine.Dart_IsError(core_lib)) {
            printDartHandleError("Dart_LookupLibrary(dart:core)", core_lib);
            return error.CoreLibFailed;
        }
        const string_type = engine.Dart_GetNonNullableType(
            core_lib,
            engine.Dart_NewStringFromCString("String"),
            0,
            null,
        );
        if (string_type == null or engine.Dart_IsError(string_type)) {
            printDartHandleError("Dart_GetNonNullableType(String)", string_type);
            return error.StringTypeFailed;
        }
        const empty_str = engine.Dart_NewStringFromCString("");
        const dart_list = engine.Dart_NewListOfTypeFilled(
            string_type,
            empty_str,
            @intCast(wargs.dart_argv.len),
        );
        if (dart_list == null or engine.Dart_IsError(dart_list)) {
            printDartHandleError("Dart_NewListOfTypeFilled", dart_list);
            return error.DartListFailed;
        }
        for (wargs.dart_argv, 0..) |arg, idx| {
            const dart_str = engine.Dart_NewStringFromCString(arg);
            _ = engine.Dart_ListSetAt(dart_list, @intCast(idx), dart_str);
        }

        // Use _startMainIsolate — handles 0/1/2-arg main() signatures.
        const main_closure = engine.Dart_GetField(
            root_lib,
            engine.Dart_NewStringFromCString("main"),
        );
        if (main_closure == null or engine.Dart_IsError(main_closure)) {
            printDartHandleError("Dart_GetField(main)", main_closure);
            return error.MainClosureFailed;
        }
        const isolate_lib = engine.Dart_LookupLibrary(
            engine.Dart_NewStringFromCString("dart:isolate"),
        );
        if (isolate_lib == null or engine.Dart_IsError(isolate_lib)) {
            printDartHandleError("Dart_LookupLibrary(dart:isolate)", isolate_lib);
            return error.IsolateLibFailed;
        }
        var start_args = [2]engine.DartHandle{ main_closure, dart_list };
        const invoke_result = engine.Dart_Invoke(
            isolate_lib,
            engine.Dart_NewStringFromCString("_startMainIsolate"),
            2,
            &start_args,
        );
        if (invoke_result == null or engine.Dart_IsError(invoke_result)) {
            printDartHandleError("Dart_Invoke(_startMainIsolate)", invoke_result);
            return error.StartMainIsolateFailed;
        }
    }
    // Success: errdefer on out_loop is cancelled; caller owns it.
}

/// Entry point for each worker thread.  Initializes under the global mutex
/// then runs the event loop independently (no shared state after init).
fn workerMain(wargs: *const WorkerArgs) void {
    // Declare event_loop here so its address is stable for the scheduler.
    // workerInit captures &event_loop via toScheduler() — must not move after that.
    var event_loop: EventLoop = undefined;
    workerInit(wargs, &event_loop) catch |e| {
        std.debug.print("worker {d}: init failed: {s}\n", .{ wargs.worker_id, @errorName(e) });
        return;
    };
    defer event_loop.deinit();
    event_loop.run();
}

fn run() !u8 {
    const allocator = std.heap.page_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Parse optional --workers=N before the snapshot path.
    // Default: 1 (single-threaded).  Pass --workers=N (or --workers=0 for
    // auto = logical CPU count) to enable SO_REUSEPORT multicore mode.
    var workers: usize = 1;
    var arg_start: usize = 1; // index of snapshot path in args[]
    if (args.len > 1 and std.mem.startsWith(u8, args[1], "--workers=")) {
        const n_str = args[1]["--workers=".len..];
        const parsed = std.fmt.parseInt(usize, n_str, 10) catch workers;
        // --workers=0 → auto-detect CPU count
        workers = if (parsed == 0) (std.Thread.getCpuCount() catch 1) else parsed;
        arg_start = 2;
    }

    if (args.len < arg_start + 1) {
        std.debug.print("usage: {s} [--workers=N] <snapshot>\n", .{args[0]});
        return 1;
    }

    const snapshot_path = try allocator.dupeZ(u8, args[arg_start]);
    defer allocator.free(snapshot_path);

    // Restore SIGSEGV/SIGBUS to default before initializing the Dart VM.
    // Zig's panic handler installs a SIGSEGV handler that conflicts with the
    // Dart VM's own use of SIGSEGV for stack-overflow detection (guard pages).
    const sig_dfl = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.SEGV, &sig_dfl, null);
    posix.sigaction(posix.SIG.BUS, &sig_dfl, null);

    var err: ?[*:0]u8 = null;
    if (!engine.DartEngine_Init(&err)) {
        printEngineError("DartEngine_Init", err);
        return 1;
    }
    defer engine.DartEngine_Shutdown();

    // Auto-detect snapshot kind: .dill → JIT kernel, .so/.dylib/.snapshot → AOT.
    const is_aot = std.mem.endsWith(u8, args[arg_start], ".so") or
        std.mem.endsWith(u8, args[arg_start], ".dylib") or
        std.mem.endsWith(u8, args[arg_start], ".snapshot");

    err = null;
    const snapshot = if (is_aot)
        engine.DartEngine_AotSnapshotFromFile(snapshot_path.ptr, &err)
    else
        engine.DartEngine_KernelFromFile(snapshot_path.ptr, &err);
    if (err != null) {
        const loader = if (is_aot) "DartEngine_AotSnapshotFromFile" else "DartEngine_KernelFromFile";
        printEngineError(loader, err);
        return 1;
    }

    // dart_argv = everything after the snapshot path (transparent to workers).
    const dart_argv_raw = args[arg_start + 1 ..];
    const dart_argv = try allocator.alloc([*:0]const u8, dart_argv_raw.len);
    defer allocator.free(dart_argv);
    for (dart_argv_raw, 0..) |a, i| dart_argv[i] = a.ptr;

    if (workers == 1) {
        // Fast path: run the single worker on the main thread (no thread creation).
        const wargs = WorkerArgs{
            .snapshot = snapshot,
            .snapshot_path = snapshot_path,
            .dart_argv = dart_argv,
            .worker_id = 0,
        };
        workerMain(&wargs);
        return 0;
    }

    std.debug.print("dart-zig: starting {d} workers (SO_REUSEPORT)\n", .{workers});

    const threads = try allocator.alloc(std.Thread, workers);
    defer allocator.free(threads);

    const worker_args = try allocator.alloc(WorkerArgs, workers);
    defer allocator.free(worker_args);

    for (0..workers) |i| {
        worker_args[i] = .{
            .snapshot = snapshot,
            .snapshot_path = snapshot_path,
            .dart_argv = dart_argv,
            .worker_id = i,
        };
        threads[i] = try std.Thread.spawn(.{}, workerMain, .{&worker_args[i]});
    }

    for (threads) |t| t.join();
    return 0;
}

/// Walk all loaded libraries once and install native resolvers.
/// - zig_io.dart / zig_tls.dart  → ZigIo resolver (combined table)
/// - zig_http.dart               → ZigHttp resolver
/// - URI unavailable (AOT mode)  → install ZigIo resolver as fallback so
///   TLS/IO natives embedded in the snapshot are still resolved.
/// Must be called inside an active isolate scope (AcquireIsolate + EnterScope).
fn installAllResolvers() void {
    const libs = engine.Dart_GetLoadedLibraries();
    if (engine.Dart_IsError(libs) or engine.Dart_IsNull(libs)) return;

    var count: isize = 0;
    _ = engine.Dart_ListLength(libs, &count);

    var i: isize = 0;
    while (i < count) : (i += 1) {
        const lib = engine.Dart_ListGetAt(libs, i);
        if (engine.Dart_IsError(lib) or engine.Dart_IsNull(lib)) continue;

        const uri_handle = engine.Dart_LibraryUrl(lib);

        // If we can read the URI, use it to pick the right resolver.
        if (!engine.Dart_IsError(uri_handle)) {
            var uri_cstr: [*:0]const u8 = undefined;
            if (engine.Dart_IsError(engine.Dart_StringToCString(uri_handle, &uri_cstr))) continue;
            const uri = std.mem.span(uri_cstr);

            // Skip built-in dart: libraries — they have no dart-zig natives.
            if (std.mem.startsWith(u8, uri, "dart:")) continue;

            if (std.mem.endsWith(u8, uri, "zig_http.dart")) {
                _ = engine.Dart_SetNativeResolver(lib, zig_http_resolver.ZigHttpNativeLookup, zig_http_resolver.ZigHttpNativeSymbol);
            } else {
                // zig_io.dart, zig_tls.dart, and any app library that may
                // embed native calls — install the combined ZigIo table.
                _ = engine.Dart_SetNativeResolver(lib, zig_io_resolver.ZigIoNativeLookup, zig_io_resolver.ZigIoNativeSymbol);
            }
        } else {
            // AOT snapshots may not expose library URIs.  Install the ZigIo
            // resolver on every library we can't identify — the lookup table
            // returns null for unknown names, which is harmless.
            _ = engine.Dart_SetNativeResolver(lib, zig_io_resolver.ZigIoNativeLookup, zig_io_resolver.ZigIoNativeSymbol);
        }
    }
}


pub fn main() void {
    const exit_code = run() catch |e| blk: {
        std.debug.print("fatal: {s}\n", .{@errorName(e)});
        break :blk 1;
    };
    std.process.exit(exit_code);
}
