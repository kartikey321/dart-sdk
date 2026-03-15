const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -Daot=true → link dart_engine_aot_shared (runs AOT snapshots, no JIT warmup).
    // -Daot=false (default) → link dart_engine_jit_shared (runs .dill kernel snapshots).
    const aot = b.option(bool, "aot", "Link the AOT engine (dart_engine_aot_shared) instead of JIT") orelse false;

    // Platform-specific engine output directory (based on build host)
    const engine_dir = if (builtin.os.tag == .linux)
        "../out/ReleaseARM64"
    else
        "../xcodebuild/ReleaseARM64";

    const exe = b.addExecutable(.{
        .name = if (aot) "dart-zig-aot" else "dart-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addIncludePath(b.path("../runtime/engine/include"));
    exe.root_module.addIncludePath(b.path("../runtime/include"));

    exe.root_module.addLibraryPath(b.path(engine_dir));
    const engine_lib = if (aot) "dart_engine_aot_shared" else "dart_engine_jit_shared";
    exe.root_module.linkSystemLibrary(engine_lib, .{});

    if (builtin.os.tag == .linux) {
        // pthread_create is a weak symbol in glibc — must explicitly link pthreads
        // so libdart_engine_jit_shared.so sees a non-null pthread_create at startup.
        exe.linkLibC();
        exe.root_module.linkSystemLibrary("pthread", .{});
    } else if (builtin.os.tag == .macos) {
        exe.root_module.linkFramework("CoreFoundation", .{});
        exe.root_module.linkSystemLibrary("objc", .{});
    }

    const lib_dir_abs = b.pathResolve(&.{ b.build_root.path orelse ".", engine_dir });
    exe.root_module.addRPath(.{ .cwd_relative = lib_dir_abs });

    b.installArtifact(exe);
}
