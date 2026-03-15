const engine = @import("../engine.zig");
const natives = struct {
    pub const version = @import("natives/version.zig");
    pub const write = @import("natives/write.zig");
    pub const tcp = @import("natives/tcp.zig");
};

pub const NativeEntry = struct {
    name: [:0]const u8,
    argc: c_int,
    func: engine.Dart_NativeFunction,
    auto_scope: bool,
};
// Silence unused import warning — engine is used via NativeEntry.func type
comptime { _ = engine; }

pub const table: []const NativeEntry = &.{
    // version.zig
    .{ .name = "ZigIo_Version", .argc = 0, .func = natives.version.ZigIo_Version, .auto_scope = true },
    // write.zig
    .{ .name = "ZigIo_StdoutWrite", .argc = 1, .func = natives.write.ZigIo_StdoutWrite, .auto_scope = true },
    // tcp.zig
    .{ .name = "ZigIo_TcpBind", .argc = 3, .func = natives.tcp.ZigIo_TcpBind, .auto_scope = true },
    .{ .name = "ZigIo_TcpAccept", .argc = 2, .func = natives.tcp.ZigIo_TcpAccept, .auto_scope = true },
    .{ .name = "ZigIo_TcpRead", .argc = 3, .func = natives.tcp.ZigIo_TcpRead, .auto_scope = true },
    .{ .name = "ZigIo_TcpWrite", .argc = 3, .func = natives.tcp.ZigIo_TcpWrite, .auto_scope = true },
    .{ .name = "ZigIo_TcpWriteBytes", .argc = 3, .func = natives.tcp.ZigIo_TcpWriteBytes, .auto_scope = true },
    .{ .name = "ZigIo_Close", .argc = 1, .func = natives.tcp.ZigIo_Close, .auto_scope = false },
};
