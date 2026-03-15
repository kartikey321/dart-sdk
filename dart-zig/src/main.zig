const std = @import("std");
const posix = std.posix;
const engine = @import("engine.zig");
const EventLoop = @import("event_loop/common.zig").EventLoop;
const zig_io_resolver = @import("zig_io/resolver.zig");

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

fn run() !u8 {
    const allocator = std.heap.page_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("usage: {s} <kernel.dill>\n", .{args[0]});
        return 1;
    }

    const snapshot_path = try allocator.dupeZ(u8, args[1]);
    defer allocator.free(snapshot_path);

    // Restore SIGSEGV/SIGBUS to default before initializing Dart VM.
    // Zig's panic handler installs a SIGSEGV handler that conflicts with the
    // Dart VM's own use of SIGSEGV for stack-overflow detection (guard pages).
    // Dart VM will install its own handler during DartEngine_Init.
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
    const is_aot = std.mem.endsWith(u8, args[1], ".so") or
        std.mem.endsWith(u8, args[1], ".dylib") or
        std.mem.endsWith(u8, args[1], ".snapshot");

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

    var event_loop = try EventLoop.init(null);
    defer event_loop.deinit();

    engine.DartEngine_SetDefaultMessageScheduler(event_loop.toScheduler());

    err = null;
    const isolate = engine.DartEngine_CreateIsolate(snapshot, &err) orelse {
        printEngineError("DartEngine_CreateIsolate", err);
        return 1;
    };
    event_loop.isolate = isolate;

    {
        engine.DartEngine_AcquireIsolate(isolate);
        defer engine.DartEngine_ReleaseIsolate();

        engine.Dart_EnterScope();
        defer engine.Dart_ExitScope();

        const root_lib = engine.Dart_RootLibrary();
        if (root_lib == null or engine.Dart_IsError(root_lib)) {
            printDartHandleError("Dart_RootLibrary", root_lib);
            return 1;
        }

        // Install the zig_io native resolver on any library that imports zig_io.dart.
        // The snapshot's library URI matches the file:// path used at gen_kernel time.
        // We iterate loaded libraries and set the resolver on the one named "zig_io".
        installZigIoResolver();

        // Build List<String> from argv[2..] (dart_args after snapshot path)
        const dart_argv = args[2..];
        const core_lib = engine.Dart_LookupLibrary(engine.Dart_NewStringFromCString("dart:core"));
        if (core_lib == null or engine.Dart_IsError(core_lib)) {
            printDartHandleError("Dart_LookupLibrary(dart:core)", core_lib);
            return 1;
        }
        const string_type = engine.Dart_GetNonNullableType(core_lib, engine.Dart_NewStringFromCString("String"), 0, null);
        if (string_type == null or engine.Dart_IsError(string_type)) {
            printDartHandleError("Dart_GetNonNullableType(String)", string_type);
            return 1;
        }
        const empty_str = engine.Dart_NewStringFromCString("");
        const dart_list = engine.Dart_NewListOfTypeFilled(string_type, empty_str, @intCast(dart_argv.len));
        if (dart_list == null or engine.Dart_IsError(dart_list)) {
            printDartHandleError("Dart_NewListOfTypeFilled", dart_list);
            return 1;
        }
        for (dart_argv, 0..) |arg, idx| {
            const dart_str = engine.Dart_NewStringFromCString(arg.ptr);
            _ = engine.Dart_ListSetAt(dart_list, @intCast(idx), dart_str);
        }

        // Use _startMainIsolate — handles 0/1/2-arg main() via _delayEntrypointInvocation
        // Same pattern as runtime/bin/main_impl.cc:1074-1096
        const main_closure = engine.Dart_GetField(root_lib, engine.Dart_NewStringFromCString("main"));
        if (main_closure == null or engine.Dart_IsError(main_closure)) {
            printDartHandleError("Dart_GetField(main)", main_closure);
            return 1;
        }
        const isolate_lib = engine.Dart_LookupLibrary(engine.Dart_NewStringFromCString("dart:isolate"));
        if (isolate_lib == null or engine.Dart_IsError(isolate_lib)) {
            printDartHandleError("Dart_LookupLibrary(dart:isolate)", isolate_lib);
            return 1;
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
            return 1;
        }
    }

    event_loop.run();

    return 0;
}

/// Walk loaded libraries; for any whose URI ends with "zig_io.dart", install
/// our native resolver so @pragma('vm:external-name', 'ZigIo_*') declarations resolve.
/// Must be called inside an active isolate scope (AcquireIsolate + EnterScope).
fn installZigIoResolver() void {
    // Dart_GetLoadedLibraries returns a List<Library> handle.
    const libs = engine.Dart_GetLoadedLibraries();
    if (engine.Dart_IsError(libs) or engine.Dart_IsNull(libs)) return;

    var count: isize = 0;
    _ = engine.Dart_ListLength(libs, &count);

    var i: isize = 0;
    while (i < count) : (i += 1) {
        const lib = engine.Dart_ListGetAt(libs, i);
        if (engine.Dart_IsError(lib) or engine.Dart_IsNull(lib)) continue;

        const uri_handle = engine.Dart_LibraryUrl(lib);
        if (engine.Dart_IsError(uri_handle)) continue;

        var uri_cstr: [*:0]const u8 = undefined;
        if (engine.Dart_IsError(engine.Dart_StringToCString(uri_handle, &uri_cstr))) continue;
        const uri = std.mem.span(uri_cstr);

        if (std.mem.endsWith(u8, uri, "zig_io.dart")) {
            const result = engine.Dart_SetNativeResolver(
                lib,
                zig_io_resolver.ZigIoNativeLookup,
                zig_io_resolver.ZigIoNativeSymbol,
            );
            if (engine.Dart_IsError(result)) {
                std.debug.print("warning: failed to install zig_io resolver on {s}\n", .{uri});
            } else {
                std.debug.print("zig_io resolver installed on {s}\n", .{uri});
            }
            return;
        }
    }
    // Not an error — program may not import zig_io.dart at all.
}

pub fn main() void {
    const exit_code = run() catch |e| blk: {
        std.debug.print("fatal: {s}\n", .{@errorName(e)});
        break :blk 1;
    };
    std.process.exit(exit_code);
}
