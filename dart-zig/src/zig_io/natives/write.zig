const std = @import("std");
const posix = std.posix;
const engine = @import("../../engine.zig");

/// ZigIo_StdoutWrite(bytes: List<int>) → int
/// Writes a Dart List<int> to stdout. Returns bytes written or -1 on error.
/// Uses posix.write on both platforms (io_uring IORING_OP_WRITE on Linux — Phase 7).
pub fn ZigIo_StdoutWrite(args: engine.Dart_NativeArguments) callconv(.c) void {
    const list = engine.Dart_GetNativeArgument(args, 0);
    if (engine.Dart_IsError(list) or engine.Dart_IsNull(list)) {
        engine.Dart_SetIntegerReturnValue(args, -1);
        return;
    }

    var length: isize = 0;
    _ = engine.Dart_ListLength(list, &length);
    if (length <= 0) {
        engine.Dart_SetIntegerReturnValue(args, 0);
        return;
    }

    // Stack-allocate for small writes; heap for larger ones.
    const MAX_STACK = 4096;
    if (length <= MAX_STACK) {
        var buf: [MAX_STACK]u8 = undefined;
        fillBuf(list, buf[0..@intCast(length)]);
        const written = posix.write(posix.STDOUT_FILENO, buf[0..@intCast(length)]) catch {
            engine.Dart_SetIntegerReturnValue(args, -1);
            return;
        };
        engine.Dart_SetIntegerReturnValue(args, @intCast(written));
    } else {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const alloc = gpa.allocator();
        const buf = alloc.alloc(u8, @intCast(length)) catch {
            engine.Dart_SetIntegerReturnValue(args, -1);
            return;
        };
        defer alloc.free(buf);
        fillBuf(list, buf);
        const written = posix.write(posix.STDOUT_FILENO, buf) catch {
            engine.Dart_SetIntegerReturnValue(args, -1);
            return;
        };
        engine.Dart_SetIntegerReturnValue(args, @intCast(written));
    }
}

fn fillBuf(list: engine.DartHandle, buf: []u8) void {
    for (buf, 0..) |*byte, i| {
        const elem = engine.Dart_ListGetAt(list, @intCast(i));
        var v: i64 = 0;
        _ = engine.Dart_IntegerToInt64(elem, &v);
        byte.* = @intCast(v & 0xff);
    }
}
