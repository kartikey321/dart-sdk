const std = @import("std");
const engine = @import("../engine.zig");
const table = @import("native_table.zig").table;

/// Called by the Dart VM to resolve a native function by name + arity.
/// Returns null if not found (causes a NoSuchMethodError in Dart).
pub fn ZigIoNativeLookup(
    name: engine.DartHandle,
    argc: c_int,
    auto_setup_scope: *bool,
) callconv(.c) engine.Dart_NativeFunction {
    // Dart_StringToCString requires an active scope (set up before this call).
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

/// Called by the Dart VM to obtain the C symbol name for a native function
/// (used for --print-snapshot-sizes and similar tooling).
pub fn ZigIoNativeSymbol(func: engine.Dart_NativeFunction) callconv(.c) [*:0]const u8 {
    for (table) |entry| {
        if (entry.func == func) return entry.name;
    }
    return "unknown";
}
