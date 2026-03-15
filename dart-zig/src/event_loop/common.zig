const builtin = @import("builtin");

pub const EventLoop = switch (builtin.os.tag) {
    .linux => @import("io_uring.zig").EventLoop,
    .macos => @import("kqueue.zig").EventLoop,
    else => @compileError("unsupported platform for event loop"),
};
