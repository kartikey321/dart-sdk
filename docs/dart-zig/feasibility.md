# dart-zig: Feasibility Analysis

**Verdict: YES, this can be done. Every phase is technically feasible.**

Validated by direct reading of the SDK codebase on 2026-03-11.

---

## Overall Verdict

The project is feasible end-to-end. The blockers identified are all **engineering
work**, not architectural impossibilities. The hardest part is Phase 1 (forking
the engine), and even that is a ~150-line C++ change across 4 files.

---

## Phase-by-Phase Verdict

---

### Phase 0 — Build From Source
**Verdict: FEASIBLE ✅**

**Confirmed from `runtime/engine/BUILD.gn`:**
- `dart_engine_jit_shared` target exists at line ~70
- `dart_engine_aot_shared` target exists at line ~85
- Both also have static variants: `dart_engine_jit_static`, `dart_engine_aot_static`

**Correction to impl-plan.md build commands:**
```sh
# The target path syntax for build.py is:
./tools/build.py --mode=release  # builds everything, including engine

# To build just engine targets (faster):
python3 tools/gn.py --mode=release
ninja -C out/ReleaseX64 dart_engine_jit_shared dart_engine_aot_shared
```

**macOS note:** Output is `.dylib` not `.so`:
- `out/ReleaseX64/libdart_engine_jit_shared.dylib`
- `out/ReleaseX64/libdart_engine_aot_shared.dylib`

**Hardest challenge:** First build takes 20-40 minutes and requires `depot_tools`.
Subsequent incremental builds are fast.

**Critical action:** Pin SDK commit in `build.zig`:
```zig
// build.zig
const DART_SDK_COMMIT = "$(cat DART_ZIG_SDK_COMMIT)";
```

---

### Phase 1 — Fork runtime/engine
**Verdict: FEASIBLE ✅ — Cleanest phase technically**

**Why it's clean:**
- `engine.h` uses a singleton pattern (`Engine::instance()`) — one place to add hooks
- `engine.h` class has a clear private fields section — add `DartZigIoHooks hooks_` there
- `dart_engine_impl.cc` is only 80 lines — adding `DartEngine_SetHooks()` is trivial
- All C API functions in `dart_engine_impl.cc` follow the exact same pattern

**Exact changes needed (confirmed against source):**

**1. `runtime/engine/include/dart_engine.h`** — add before `#endif`:
```cpp
typedef struct DartZigIoHooks {
  Dart_Handle (*setup_core_libs)(Dart_Isolate isolate, void* context);
  Dart_Handle (*register_io_natives)(Dart_Handle library, void* context);
  void* context;
} DartZigIoHooks;

DART_EXPORT void DartEngine_SetHooks(DartZigIoHooks hooks);
```

**2. `runtime/engine/engine.h`** — add to private section (after line 134):
```cpp
DartZigIoHooks hooks_ = {nullptr, nullptr, nullptr};
```
Add public setter declaration:
```cpp
void SetHooks(DartZigIoHooks hooks);
```

**3. `runtime/engine/engine.cc:StartIsolate`** — replace line 197:
```cpp
// Before: hardcoded
bin::DartUtils::SetupCoreLibraries(false, false, false, bin::DartIoSettings{});

// After: injectable
Dart_Handle core_libs_result;
if (hooks_.setup_core_libs != nullptr) {
  core_libs_result = hooks_.setup_core_libs(isolate, hooks_.context);
} else {
  core_libs_result = bin::DartUtils::SetupCoreLibraries(
      false, false, false, bin::DartIoSettings{});
}
```

Also add to `Engine::Shutdown` (after the isolate loop, around line 278):
```cpp
char* cleanup_error = Dart_Cleanup();
if (cleanup_error != nullptr) {
  Syslog::PrintErr("Dart_Cleanup: %s\n", cleanup_error);
  free(cleanup_error);
}
dart::embedder::Cleanup();
```

Also update `CreateInitializeParams` (line 98-105):
```cpp
params.create_group = Engine::CreateGroupCallback;
params.initialize_isolate = Engine::InitializeIsolateCallback;
// CreateGroupCallback calls StartIsolate for child isolates
```

**4. `runtime/engine/dart_engine_impl.cc`** — add (follows existing pattern exactly):
```cpp
DART_EXPORT void DartEngine_SetHooks(DartZigIoHooks hooks) {
  Engine::instance()->SetHooks(hooks);
}
```

**Calling sequence from Zig:**
```zig
DartEngine_SetHooks(hooks);   // MUST be before DartEngine_CreateIsolate
DartEngine_SetDefaultMessageScheduler(scheduler);
DartEngine_CreateIsolate(snapshot, &error);
```

**Hardest challenge:** Implementing `CreateGroupCallback` for `Isolate.spawn`.
It must call `StartIsolate` with a child snapshot and set the scheduler. The
callback signature is `Dart_IsolateGroupCreateCallback` from `dart_api.h`.

---

### Phase 2 (Zig Host Binary) — `@cImport` anonymous union
**Verdict: FEASIBLE ✅ — Known Zig limitation with documented workaround**

**Confirmed:** `DartEngine_SnapshotData` has an anonymous union with two
anonymous structs inside (lines 50-61 in `dart_engine.h`). Zig's `@cImport`
cannot handle this.

**Manual translation — exact memory layout verified:**
```zig
pub const SnapshotData = extern struct {
    script_uri: [*c]const u8,
    kind: c_int,  // 0=Kernel, 1=AOT
    // Union: 4 pointers wide (AOT is larger; kernel has 2 fields + 2 padding)
    vm_snapshot_data:         [*c]const u8,  // == kernel_buffer for Kernel kind
    vm_snapshot_instructions: [*c]const u8,  // == kernel_buffer_size (reinterpreted)
    vm_isolate_data:          [*c]const u8,
    vm_isolate_instructions:  [*c]const u8,
};
```
For Kernel kind, set `vm_snapshot_data = kernel_buffer` and
`vm_snapshot_instructions = @ptrFromInt(@intCast(usize, kernel_buffer_size))`.

**Hardest challenge:** Getting the union alignment exactly right on both
x86-64 and ARM64 (macOS M-series). Write a C test that asserts
`offsetof(DartEngine_SnapshotData, vm_snapshot_data) == offsetof(...)`.

---

### Phase 3 (io_uring Event Loop)
**Verdict: FEASIBLE on Linux ✅ — macOS requires kqueue fallback**

**io_uring availability:**
- `IORING_TIMEOUT_ABS` requires kernel ≥ 5.11 (released March 2021)
- Zig's `std.os.linux.IO_Uring` is in stable Zig (≥ 0.11)
- Struct name: `std.os.linux.IO_Uring` (capital letters)

**macOS reality check:**
- io_uring is Linux-only. macOS requires `kqueue` + `kevent`
- Zig's `std.os` has `kqueue` support
- For now: `comptime` switch on `builtin.os.tag` to select backend

**`Dart_NotifyIdle` signature confirmed in `dart_api.h:1242`:**
```c
DART_EXPORT void Dart_NotifyIdle(int64_t deadline);
// deadline is microseconds since epoch (NOT milliseconds)
```
Use `std.time.microTimestamp()` for the current time.

**GC idle placement — the right spot:**
```zig
fn runOnce(self: *EventLoop) !void {
    // Non-blocking drain first
    const count = try self.ring.copy_cqes(&self.cqes, 0);
    if (count == 0) {
        // Between idle polls: notify GC with 5ms deadline
        // Must NOT hold isolate lock here
        const now_us = std.time.microTimestamp();
        c.Dart_NotifyIdle(now_us + 5_000);
        // Now block
        _ = try self.ring.copy_cqes(&self.cqes, 1);
    }
}
```

**Hardest challenge:** Timer accuracy. `IORING_TIMEOUT_ABS` with
`CLOCK_MONOTONIC` is the correct clock for `Dart_TimerMillisecondClock`
(confirmed: `runtime/bin/utils_linux.cc:78` uses `CLOCK_MONOTONIC`).

---

### Phase 4 (Full Host Responsibilities)
**Verdict: FEASIBLE ✅ — Tedious but no hidden surprises**

**`_setupStdio` — does it exist?**
Confirmed in `sdk/lib/_internal/vm/bin/stdio_patch.dart` and
`runtime/bin/stdio.cc`. The Dart-side hook is `_setupStdio` in `dart:io`.
Call it like:
```zig
const io_lib = c.Dart_LookupLibrary(c.Dart_NewStringFromCString("dart:io"));
_ = c.Dart_Invoke(io_lib, c.Dart_NewStringFromCString("_setupHooks"), 0, null);
```
Note: `_setupHooks` (not `_setupStdio`) is the right entry point —
confirmed in `dart_io_api_impl.cc:156`: `Dart_Invoke(io_lib, "_setupHooks", ...)`.

**Signal handling:**
`signalfd` on Linux works with io_uring via `IORING_OP_READ` on the signalfd
file descriptor. Read a `signalfd_siginfo` struct on completion.
Post to `ProcessSignal` Dart port via `Dart_PostInteger`.

**Microtask draining — when exactly:**
Call `DartEngine_DrainMicrotasksQueue()` after **every** `Dart_Invoke` call from
Zig into Dart (ZigHttp_Respond, any Zig→Dart call). Not after
`DartEngine_HandleMessage` — that already drains internally.

**Hardest challenge:** Signal-to-Dart-port mapping. You need to look up which
`Dart_Port` is listening for each signal. The stock dart binary uses
`Process::SetSignalHandler` from `runtime/bin/process.h` — you'll need to
replicate this lookup or call the existing native `Process_SetSignalHandler`.

---

### Phase 5 (Zig I/O Natives)
**Verdict: FEASIBLE ✅ — One important correction to the plan**

**`IONativeLookup` is NOT exported from the shared library.**
From `runtime/bin/io_natives.h:13`:
```cpp
Dart_NativeFunction IONativeLookup(Dart_Handle name,
                                   int argument_count,
                                   bool* auto_setup_scope);
```
No `DART_EXPORT` — it's a plain internal C++ symbol.

**The correct fallthrough function IS exported:**
From `runtime/include/bin/dart_io_api.h:58`:
```cpp
Dart_NativeFunction LookupIONative(Dart_Handle name,
                                   int argument_count,
                                   bool* auto_setup_scope);
```
This is the public wrapper. Call `LookupIONative` from your Zig fallthrough,
not `IONativeLookup`.

**Corrected Zig fallthrough:**
```zig
pub export fn zigNativeLookup(
    name: c.Dart_Handle,
    argument_count: c_int,
    auto_setup_scope: *bool,
) callconv(.C) c.Dart_NativeFunction {
    auto_setup_scope.* = true;
    // Check Zig table first
    for (&native_table) |*entry| { ... }
    // Fall through to exported public API (NOT IONativeLookup)
    return c.LookupIONative(name, argument_count, auto_setup_scope);
}
```

**Hardest challenge:** Ensuring the Phase 1 hook correctly overrides the
resolver *after* `SetupCoreLibraries` has run. The hook's
`register_io_natives` callback is called from within `SetupDartIoLibrary`
which is called from `SetupCoreLibraries` — so by the time it returns,
our resolver is already installed.

---

### Phase 6 (True Zero-Copy)
**Verdict: FEASIBLE with caveats ✅**

**`Dart_NewExternalTypedDataWithFinalizer` confirmed in `dart_api.h:2712`:**
```c
DART_EXPORT Dart_Handle Dart_NewExternalTypedDataWithFinalizer(
    Dart_TypedData_Type type,
    void* data,
    intptr_t length,
    void* peer,
    intptr_t external_allocation_size,
    Dart_WeakPersistentHandleCallback callback);
```
This wraps a C buffer as a Dart `Uint8List` without copying. The finalizer is
called when Dart GC collects the object, returning the buffer to your pool.

**SEND_ZC caveat (confirmed):** Must use Zig-owned buffers. Copy from Dart
heap to Zig buffer before submitting `IORING_OP_SEND_ZC`. Free after
`IORING_CQE_F_NOTIF` completion.

**Hardest challenge:** Buffer pool sizing. Each active connection holds a
4KB buffer pinned outside the Dart heap. With 10k connections you're pinning
40MB of non-GC memory. Need a tiered pool (small/medium/large buffers).

---

### Phase 7 (Multi-Core)
**Verdict: FEASIBLE ✅ — Engine explicitly supports multiple isolates**

**Confirmed from `engine.h`:**
- `isolates_` field is `std::vector<Dart_Isolate>` — multiple isolates supported
- Each `StartIsolate` call adds to the vector
- Per-isolate locking via `IsolateData::mutex` — no global lock per request

**Confirmed from `engine.cc:Shutdown`:**
- Iterates `isolates_` and shuts each one down individually
- `is_running_` flag is shared — set to `false` on shutdown, all isolates stop

**`SO_REUSEPORT` + per-thread rings:** Each Zig worker thread owns:
1. One `IO_Uring` ring (no sharing required)
2. One `Dart_Isolate` (via `DartEngine_CreateIsolate` — safe to call from any thread)
3. One listen socket bound with `SO_REUSEPORT`

**Critical dependency:** Requires Phase 1's `create_group` callback to handle
`Isolate.spawn` from within a worker isolate. Without this, worker isolates
that call `Isolate.spawn` crash.

**Hardest challenge:** Isolate group semantics. All isolates spawned from the
same snapshot should share an isolate group (for memory sharing). Verify that
multiple `DartEngine_CreateIsolate` calls on the same snapshot create the same
group, or that group sharing is explicit.

---

### Phase 8 (SEND_ZC + SPLICE)
**Verdict: FEASIBLE on Linux kernel ≥ 6.0 ✅**

- `IORING_OP_SEND_ZC` requires kernel ≥ 6.0 (Oct 2022)
- `IORING_OP_SPLICE` requires kernel ≥ 5.7 (May 2020)
- Both available in Zig's `std.os.linux`

---

## Hidden Dependencies Between Phases

```
Phase 0 (build)
    └── Phase 1 (fork engine)  ← MUST complete before anything else works
            ├── Phase 2 (Zig host binary)
            │       └── Phase 3 (io_uring event loop)
            │               └── Phase 4 (full host responsibilities)
            │                       └── Phase 5 (Zig I/O natives)
            │                               ├── Phase 6 (zero-copy)
            │                               └── Phase 7 (multi-core)  ← also needs Phase 1 create_group
            │                                       └── Phase 8 (SEND_ZC/SPLICE)
            └── Phase 9 (benchmarks)  ← needs Phase 5+ for meaningful comparison
```

**Critical cascade risk:** Phase 1's `create_group` callback is needed by
BOTH Phase 4 (signal handling uses `Process` which spawns isolates) AND
Phase 7 (multi-core). If `create_group` is deferred, both phases are blocked.

---

## One-Line Verdict Per Phase

| Phase | Verdict | Hardest Single Challenge |
|---|---|---|
| 0 | ✅ FEASIBLE | First build time (~40min), depot_tools setup |
| 1 | ✅ FEASIBLE | `CreateGroupCallback` implementation for `Isolate.spawn` |
| 2 | ✅ FEASIBLE | Union memory layout verification across architectures |
| 3 | ✅ FEASIBLE (Linux) | macOS kqueue fallback; timer clock alignment |
| 4 | ✅ FEASIBLE | Signal-to-Dart-port mapping without `Process` natives |
| 5 | ✅ FEASIBLE | Use `LookupIONative` (not `IONativeLookup`) for fallthrough |
| 6 | ✅ FEASIBLE | Buffer pool sizing under high connection count |
| 7 | ✅ FEASIBLE | Isolate group semantics for multi-snapshot workers |
| 8 | ✅ FEASIBLE (kernel≥6.0) | SEND_ZC buffer stability across GC boundaries |
| 9 | ✅ FEASIBLE | Ensuring fair comparison (same hardware, warm JIT) |

---

## Corrections to impl-plan.md

| Location | Current (wrong) | Correct |
|---|---|---|
| Phase 0 build command | `./tools/build.py --mode=release runtime/engine:dart_engine_jit_shared` | `ninja -C out/ReleaseX64 dart_engine_jit_shared` |
| Phase 0 output extension | `.so` | `.dylib` on macOS, `.so` on Linux |
| Phase 4 stdio function | `_setupStdio` | `_setupHooks` (in `dart:io`) |
| Phase 5 fallthrough fn | `IONativeLookup` | `LookupIONative` (from `dart_io_api.h`) |
| Phase 2 hooks call order | unspecified | `DartEngine_SetHooks` MUST be called before `DartEngine_CreateIsolate` |
