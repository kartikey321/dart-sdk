const engine = @import("../engine.zig");
const http_natives = @import("natives.zig");

pub const NativeEntry = struct {
    name: [:0]const u8,
    argc: c_int,
    func: engine.Dart_NativeFunction,
    auto_scope: bool,
};

pub const table: []const NativeEntry = &.{
    .{ .name = "ZigHttp_Parse",        .argc = 1, .func = http_natives.ZigHttp_Parse,        .auto_scope = true },
    .{ .name = "ZigHttp_RouteRequest", .argc = 1, .func = http_natives.ZigHttp_RouteRequest, .auto_scope = true },
};
