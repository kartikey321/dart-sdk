const engine = @import("../engine.zig");
const natives = struct {
    pub const version = @import("natives/version.zig");
    pub const write = @import("natives/write.zig");
    pub const tcp = @import("natives/tcp.zig");
    pub const tls = @import("natives/tls.zig");
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
    // tcp.zig — legacy port-based API (used by echo_server.dart)
    .{ .name = "ZigIo_TcpBind", .argc = 3, .func = natives.tcp.ZigIo_TcpBind, .auto_scope = true },
    .{ .name = "ZigIo_TcpAccept", .argc = 2, .func = natives.tcp.ZigIo_TcpAccept, .auto_scope = true },
    .{ .name = "ZigIo_TcpRead", .argc = 3, .func = natives.tcp.ZigIo_TcpRead, .auto_scope = true },
    .{ .name = "ZigIo_TcpWrite", .argc = 3, .func = natives.tcp.ZigIo_TcpWrite, .auto_scope = true },
    .{ .name = "ZigIo_TcpWriteBytes", .argc = 3, .func = natives.tcp.ZigIo_TcpWriteBytes, .auto_scope = true },
    .{ .name = "ZigIo_Close", .argc = 1, .func = natives.tcp.ZigIo_Close, .auto_scope = false },
    // tcp.zig — batch dispatcher API (Phase 14, used by http_server.dart)
    .{ .name = "ZigIo_SetBatchPort", .argc = 1, .func = natives.tcp.ZigIo_SetBatchPort, .auto_scope = true },
    .{ .name = "ZigIo_TcpAcceptToken", .argc = 2, .func = natives.tcp.ZigIo_TcpAcceptToken, .auto_scope = true },
    .{ .name = "ZigIo_TcpReadToken", .argc = 3, .func = natives.tcp.ZigIo_TcpReadToken, .auto_scope = true },
    .{ .name = "ZigIo_TcpReadRouteToken", .argc = 2, .func = natives.tcp.ZigIo_TcpReadRouteToken, .auto_scope = true },
    .{ .name = "ZigIo_TcpServeToken", .argc = 2, .func = natives.tcp.ZigIo_TcpServeToken, .auto_scope = true },
    .{ .name = "ZigIo_TcpLoopToken", .argc = 2, .func = natives.tcp.ZigIo_TcpLoopToken, .auto_scope = true },
    .{ .name = "ZigIo_TcpWriteBytesToken", .argc = 3, .func = natives.tcp.ZigIo_TcpWriteBytesToken, .auto_scope = true },
    // tls.zig — token-based TLS API
    .{ .name = "ZigTls_Configure", .argc = 2, .func = natives.tls.ZigTls_Configure, .auto_scope = true },
    .{ .name = "ZigTls_UpgradeToken", .argc = 2, .func = natives.tls.ZigTls_UpgradeToken, .auto_scope = true },
    .{ .name = "ZigTls_ReadToken", .argc = 3, .func = natives.tls.ZigTls_ReadToken, .auto_scope = true },
    .{ .name = "ZigTls_WriteBytesToken", .argc = 3, .func = natives.tls.ZigTls_WriteBytesToken, .auto_scope = true },
    .{ .name = "ZigTls_Close", .argc = 1, .func = natives.tls.ZigTls_Close, .auto_scope = true },
};
