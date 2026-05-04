pub const DartHandle = ?*anyopaque;

pub const SnapshotKind = enum(c_int) {
    Kernel = 0,
    Aot = 1,
};

pub const SnapshotData = extern struct {
    script_uri: [*c]const u8,
    kind: c_int,
    field0: [*c]const u8,
    field1: usize,
    field2: [*c]const u8,
    field3: [*c]const u8,
};

pub const DartZigIoHooks = extern struct {
    setup_core_libs: ?*const fn (isolate: ?*anyopaque, context: ?*anyopaque) callconv(.c) ?*anyopaque,
    register_io_natives: ?*const fn (library: ?*anyopaque, context: ?*anyopaque) callconv(.c) ?*anyopaque,
    context: ?*anyopaque,
};

pub extern fn DartEngine_Init(err: *?[*:0]u8) bool;
pub extern fn DartEngine_Shutdown() void;
pub extern fn DartEngine_KernelFromFile(path: [*:0]const u8, err: *?[*:0]u8) SnapshotData;
pub extern fn DartEngine_AotSnapshotFromFile(path: [*:0]const u8, err: *?[*:0]u8) SnapshotData;
pub extern fn DartEngine_CreateIsolate(snapshot: SnapshotData, err: *?[*:0]u8) DartHandle;
pub extern fn DartEngine_HandleMessage(isolate: DartHandle) void;
pub extern fn Dart_HandleMessage() DartHandle;
pub extern fn DartEngine_DrainMicrotasksQueue() DartHandle;
pub extern fn DartEngine_AcquireIsolate(isolate: DartHandle) void;
pub extern fn DartEngine_ReleaseIsolate() void;
pub extern fn DartEngine_SetHooks(hooks: DartZigIoHooks) void;
pub const MessageScheduler = extern struct {
    schedule_callback: ?*const fn (isolate: DartHandle, context: ?*anyopaque) callconv(.c) void,
    context: ?*anyopaque,
};
pub extern fn DartEngine_SetDefaultMessageScheduler(scheduler: MessageScheduler) void;
pub extern fn DartEngine_SetMessageScheduler(scheduler: MessageScheduler, isolate: DartHandle) void;

pub extern fn Dart_EnterScope() void;
pub extern fn Dart_ExitScope() void;
pub extern fn Dart_RootLibrary() DartHandle;
pub extern fn Dart_NewStringFromCString(str: [*:0]const u8) DartHandle;
pub extern fn Dart_Invoke(target: DartHandle, name: DartHandle, num_args: c_int, args: ?[*]DartHandle) DartHandle;
pub extern fn Dart_IsError(handle: DartHandle) bool;
pub extern fn Dart_GetError(handle: DartHandle) [*:0]const u8;
pub extern fn Dart_NewList(length: isize) DartHandle;
pub extern fn Dart_NewListOfTypeFilled(element_type: DartHandle, fill_object: DartHandle, length: isize) DartHandle;
pub extern fn Dart_ListSetAt(list: DartHandle, index: isize, value: DartHandle) DartHandle;
pub extern fn Dart_GetField(container: DartHandle, name: DartHandle) DartHandle;
pub extern fn Dart_NotifyIdle(deadline_in_microseconds: i64) void;
pub extern fn Dart_HasLivePorts() bool;

// ---------------------------------------------------------------------------
// Native function mechanism (Dart_SetNativeResolver)
// ---------------------------------------------------------------------------

pub const Dart_NativeArguments = ?*anyopaque;
pub const Dart_NativeFunction = ?*const fn (args: Dart_NativeArguments) callconv(.c) void;
pub const Dart_NativeEntryResolver = ?*const fn (
    name: DartHandle,
    argc: c_int,
    auto_setup_scope: *bool,
) callconv(.c) Dart_NativeFunction;
pub const Dart_NativeEntrySymbol = ?*const fn (func: Dart_NativeFunction) callconv(.c) [*:0]const u8;

pub extern fn Dart_SetNativeResolver(
    library: DartHandle,
    resolver: Dart_NativeEntryResolver,
    symbol: Dart_NativeEntrySymbol,
) DartHandle;

// Argument extraction
pub extern fn Dart_GetNativeArgumentCount(args: Dart_NativeArguments) c_int;
pub extern fn Dart_GetNativeArgument(args: Dart_NativeArguments, index: c_int) DartHandle;
pub extern fn Dart_GetNativeIntegerArgument(args: Dart_NativeArguments, index: c_int, value: *i64) DartHandle;
pub extern fn Dart_GetNativeStringArgument(args: Dart_NativeArguments, index: c_int, peer: ?*?*anyopaque) DartHandle;
pub extern fn Dart_GetNativeBooleanArgument(args: Dart_NativeArguments, index: c_int, value: *bool) DartHandle;

// Return value setters
pub extern fn Dart_SetReturnValue(args: Dart_NativeArguments, retval: DartHandle) void;
pub extern fn Dart_SetIntegerReturnValue(args: Dart_NativeArguments, retval: i64) void;
pub extern fn Dart_SetBooleanReturnValue(args: Dart_NativeArguments, retval: bool) void;
pub extern fn Dart_SetNullReturnValue(args: Dart_NativeArguments) void;

// String helpers
pub extern fn Dart_StringToCString(str: DartHandle, cstr: *[*:0]const u8) DartHandle;
pub extern fn Dart_NewStringFromUTF8(utf8: [*]const u8, length: usize) DartHandle;

// List helpers (for passing byte arrays to/from Dart)
pub extern fn Dart_ListLength(list: DartHandle, length: *isize) DartHandle;
pub extern fn Dart_ListGetAt(list: DartHandle, index: isize) DartHandle;
pub extern fn Dart_IntegerToInt64(integer: DartHandle, value: *i64) DartHandle;
pub extern fn Dart_NewInteger(value: i64) DartHandle;
pub extern fn Dart_Null() DartHandle;
pub extern fn Dart_IsNull(handle: DartHandle) bool;
pub extern fn Dart_True() DartHandle;
pub extern fn Dart_False() DartHandle;

// TypedData (Uint8List) helpers
pub extern fn Dart_TypedDataAcquireData(
    handle: DartHandle,
    kind: *c_int,
    data: *?*anyopaque,
    length: *isize,
) DartHandle;
pub extern fn Dart_TypedDataReleaseData(handle: DartHandle) DartHandle;
pub extern fn Dart_NewTypedData(kind: c_int, length: isize) DartHandle;
pub extern fn Dart_TypedDataSetAt(handle: DartHandle, index: isize, value: DartHandle) DartHandle;
pub const Dart_TypedData_kUint8: c_int = 2;

// SendPort / async posting
pub const Dart_Port = i64;
pub extern fn Dart_SendPortGetId(port: DartHandle, port_id: *Dart_Port) DartHandle;
pub extern fn Dart_PostInteger(port_id: Dart_Port, value: i64) bool;

// Dart_CObject — cross-thread message type (dart_native_api.h)
// Layout must match the C struct exactly.  The union's largest member is
// as_external_typed_data (40 bytes on 64-bit); _pad ensures correct sizing.
pub const Dart_CObject_Type = c_int;
pub const Dart_CObject_kNull: Dart_CObject_Type = 0;
pub const Dart_CObject_kInt64: Dart_CObject_Type = 3;
pub const Dart_CObject_kArray: Dart_CObject_Type = 6;
pub const Dart_CObject_kTypedData: Dart_CObject_Type = 7;
pub const Dart_CObject_kExternalTypedData: Dart_CObject_Type = 8;

/// Finalizer invoked by the Dart GC when an ExternalTypedData object is collected.
/// `peer` is the raw pointer passed at construction time.
pub const Dart_HandleFinalizer = ?*const fn (
    isolate_callback_data: ?*anyopaque,
    peer: ?*anyopaque,
) callconv(.c) void;

pub const Dart_CObject = extern struct {
    @"type": Dart_CObject_Type,
    value: extern union {
        as_int64: i64,
        // kArray: flat list of Dart_CObject pointers.
        // Used by completion batching (Phase 14) to deliver N results in one message.
        as_array: extern struct {
            length: isize,
            values: [*]?*Dart_CObject,
        },
        as_typed_data: extern struct {
            data_type: c_int, // Dart_TypedData_Type (kUint8 = 2)
            length: isize, // in elements (= bytes for Uint8List)
            values: [*]const u8,
        },
        // Zero-copy buffer: Dart takes ownership; finalizer frees when GC'd.
        // Layout matches dart_native_api.h ExternalTypedData (40 bytes on 64-bit).
        // c_int(4) + pad(4) + isize(8) + ptr(8) + peer(8) + fn(8) = 40 bytes.
        as_external_typed_data: extern struct {
            data_type: c_int,
            length: isize,
            data: [*]u8,
            peer: ?*anyopaque,
            callback: Dart_HandleFinalizer,
        },
    },
};
pub extern fn Dart_PostCObject(port_id: Dart_Port, message: *Dart_CObject) bool;

// Library introspection (for resolver installation)
pub extern fn Dart_GetLoadedLibraries() DartHandle;
pub extern fn Dart_LibraryUrl(library: DartHandle) DartHandle;
pub extern fn Dart_LookupLibrary(url: DartHandle) DartHandle;
pub extern fn Dart_GetNonNullableType(library: DartHandle, class_name: DartHandle, number_of_type_arguments: c_int, type_arguments: ?[*]DartHandle) DartHandle;

pub fn kernelSnapshotData(path: [*:0]const u8) SnapshotData {
    return .{
        .script_uri = path,
        .kind = @intFromEnum(SnapshotKind.Kernel),
        .field0 = path,
        .field1 = 0,
        .field2 = null,
        .field3 = null,
    };
}
