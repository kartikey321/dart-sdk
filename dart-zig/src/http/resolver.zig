const std = @import("std");
const engine = @import("../engine.zig");
const table = @import("native_table.zig").table;

pub fn ZigHttpNativeLookup(
    name: engine.DartHandle,
    argc: c_int,
    auto_setup_scope: *bool,
) callconv(.c) engine.Dart_NativeFunction {
    var name_cstr: [*:0]const u8 = undefined;
    if (engine.Dart_IsError(engine.Dart_StringToCString(name, &name_cstr))) return null;
    const name_str = std.mem.span(name_cstr);

    for (table) |entry| {
        if (entry.argc == argc and std.mem.eql(u8, name_str, entry.name)) {
            auto_setup_scope.* = entry.auto_scope;
            return entry.func;
        }
    }
    return null;
}

pub fn ZigHttpNativeSymbol(func: engine.Dart_NativeFunction) callconv(.c) [*:0]const u8 {
    for (table) |entry| {
        if (entry.func == func) return entry.name;
    }
    return "unknown";
}
