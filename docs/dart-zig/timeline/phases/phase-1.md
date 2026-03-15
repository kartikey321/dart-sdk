# Phase 1 — Fork runtime/engine (Blocker)

**Started:** 2026-03-11
**Completed:** 2026-03-11
**Status:** COMPLETED

## Goal
Break the hard `runtime/bin` dependency in `runtime/engine` by making
`SetupCoreLibraries` injectable via hooks. This unblocks all subsequent phases.

## Success Criteria
- [x] `DartZigIoHooks` struct added to `runtime/engine/include/dart_engine.h:192`
- [x] `engine.cc:StartIsolate` checks hook before calling `SetupCoreLibraries` (line 198)
- [x] `Engine::Shutdown` calls `Dart_Cleanup` + `embedder::Cleanup` (lines 268-273)
- [ ] `CreateInitializeParams` sets `create_group` to a real callback — DEFERRED to Phase 2
- [x] Engine builds cleanly — `[4/4]` real compile confirmed
- [x] Regression test passes — `Ticks: 103` (baseline: 103)
- [x] `setup_core_libs = nullptr` (default) produces identical behavior

## Prerequisite
Phase 0 complete — must have a working build before modifying engine.

## Key Files to Modify

| File | Change |
|---|---|
| `runtime/engine/engine.h` | Add `DartZigIoHooks` struct, add `hooks_` field to `Engine` class |
| `runtime/engine/engine.cc` | Inject hook check in `StartIsolate`, fix `Shutdown`, add `create_group` |
| `runtime/engine/dart_engine_impl.cc` | Expose new `DartEngine_SetHooks` C API function |
| `runtime/engine/include/dart_engine.h` | Declare `DartEngine_SetHooks` in public header |

## The Hook Injection Point

In `engine.cc:StartIsolate` around line 197, replace:
```cpp
Dart_Handle core_libs_result = bin::DartUtils::SetupCoreLibraries(
    false, false, false, bin::DartIoSettings{});
```

With:
```cpp
Dart_Handle core_libs_result;
if (hooks_.setup_core_libs != nullptr) {
  core_libs_result = hooks_.setup_core_libs(isolate, hooks_.context);
} else {
  core_libs_result = bin::DartUtils::SetupCoreLibraries(
      false, false, false, bin::DartIoSettings{});
}
```

## The Shutdown Fix

In `engine.cc:Shutdown` — after the isolate loop, add:
```cpp
// Cleanup VM resources (was missing — caused resource leak in long-lived hosts)
char* cleanup_error = Dart_Cleanup();
if (cleanup_error != nullptr) {
  Syslog::PrintErr("Dart_Cleanup: %s\n", cleanup_error);
  free(cleanup_error);
}
dart::embedder::Cleanup();
```

## The create_group Fix

In `engine.cc:CreateInitializeParams`:
```cpp
params.create_group = Engine::CreateGroupCallback;
params.initialize_isolate = Engine::InitializeIsolateCallback;
```

Implement `CreateGroupCallback` to call `StartIsolate` for the child snapshot.

## Regression Test

After changes, run:
```sh
cd /Users/kartik/StudioProjects/sdk
./buildtools/ninja/ninja -C xcodebuild/ReleaseARM64 samples/embedder:run_timer_async_kernel
xcodebuild/ReleaseARM64/run_timer_async_kernel \
  xcodebuild/ReleaseARM64/gen/timer_kernel.dart.snapshot
# Expected output: non-zero Ticks (baseline: Ticks: 103)
```

## Session Log

### Session 2026-03-11
**Duration:** ~10 min (Codex --full-auto)
**What happened:** Codex made all 4 file edits. Initial ninja showed no work — turns out
build cache thought files unchanged. Forced rebuild by touching files. Real `[4/4]` compile
confirmed all changes valid. Regression test: `Ticks: 103` == baseline.
**Note:** `create_group` callback deferred — implementing it requires `Dart_IsolateGroupCreateCallback`
signature work that is self-contained in Phase 2.

## Blockers

| # | Blocker | Discovered | Resolved |
|---|---------|-----------|---------|

## Resolved Blockers

| # | Blocker | Resolution | Date |
|---|---------|-----------|------|
| 1 | `ninja: no work to do` after Codex edits | 2026-03-11 | `touch` files to invalidate cache |

## Artifacts
- `runtime/engine/include/dart_engine.h` — `DartZigIoHooks` struct + `DartEngine_SetHooks` at line 192
- `runtime/engine/engine.h` — `SetHooks()` public method + `hooks_` private field at line 59/138
- `runtime/engine/engine.cc` — hook injection at line 198, `Dart_Cleanup` at line 268, `SetHooks` impl at line 389
- `runtime/engine/dart_engine_impl.cc` — `DartEngine_SetHooks` C export at line 79
- `xcodebuild/ReleaseARM64/libdart_engine_jit_shared.dylib` — rebuilt with hooks
