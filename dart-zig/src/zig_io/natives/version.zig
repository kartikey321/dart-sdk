const engine = @import("../../engine.zig");

const version_str = "dart-zig/0.1.0 (zig " ++ @import("builtin").zig_version_string ++ ")";

pub fn ZigIo_Version(args: engine.Dart_NativeArguments) callconv(.c) void {
    const result = engine.Dart_NewStringFromUTF8(version_str, version_str.len);
    engine.Dart_SetReturnValue(args, result);
}
