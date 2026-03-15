# Phase 2 — create_group Callback (Isolate.spawn)

**Started:** 2026-03-11
**Completed:** 2026-03-12
**Status:** COMPLETED

## Goal
Implement `create_group` callback in `engine.cc` so `Isolate.spawn` works.
Currently `CreateInitializeParams` sets `create_group = nullptr` — any Dart
code calling `Isolate.spawn` silently fails.

## Prerequisite
Phase 1 complete ✅

## Success Criteria
- [x] `Engine::CreateGroupCallback` implemented — `engine.cc:394`
- [x] `Engine::InitializeIsolateCallback` implemented — `engine.cc:424`
- [x] Both declared as `static` in `engine.h:90,98`
- [x] `CreateInitializeParams` wires them in — `engine.cc:102-103`
- [x] Build clean ✅
- [x] Regression: `Ticks: 104` (baseline 103) ✅

## Key Files to Modify

| File | Change |
|---|---|
| `runtime/engine/engine.h` | Declare `CreateGroupCallback` + `InitializeIsolateCallback` as static |
| `runtime/engine/engine.cc` | Implement both callbacks, wire in `CreateInitializeParams` |

## Dart_IsolateGroupCreateCallback Signature (from dart_api.h)

```cpp
typedef Dart_Isolate (*Dart_IsolateGroupCreateCallback)(
    const char* script_uri,
    const char* main,
    const char* package_root,
    const char* package_config,
    Dart_IsolateFlags* flags,
    void* isolate_group_data,
    void* isolate_data,
    char** error);
```

## Implementation Plan

### CreateGroupCallback
When `Isolate.spawn` fires, the VM passes the parent's `script_uri`.
Find the matching snapshot in `owned_snapshots_` and call `StartIsolate`:

```cpp
Dart_Isolate Engine::CreateGroupCallback(
    const char* script_uri,
    const char* main,
    const char* package_root,
    const char* package_config,
    Dart_IsolateFlags* flags,
    void* isolate_group_data,
    void* isolate_data,
    char** error) {
  Engine* engine = Engine::instance();
  MutexLocker ml(&engine->engine_state_);
  for (const auto& snapshot : engine->owned_snapshots_) {
    if (snapshot.script_uri != nullptr &&
        strcmp(snapshot.script_uri, script_uri) == 0) {
      return engine->StartIsolate(snapshot, error);
    }
  }
  *error = Utils::StrDup("dart-zig: no snapshot registered for script_uri");
  return nullptr;
}
```

### InitializeIsolateCallback
```cpp
bool Engine::InitializeIsolateCallback(
    void* isolate_group_data,
    void* isolate_data,
    char** error) {
  return true;  // Engine handles initialization in StartIsolate
}
```

### Wire into CreateInitializeParams (engine.cc ~line 103)
Replace:
```cpp
params.create_group = nullptr;
params.shutdown_isolate = nullptr;
```
With:
```cpp
params.create_group = Engine::CreateGroupCallback;
params.initialize_isolate = Engine::InitializeIsolateCallback;
params.shutdown_isolate = nullptr;
```

## Regression Test

```sh
cd /Users/kartik/StudioProjects/sdk
./buildtools/ninja/ninja -C xcodebuild/ReleaseARM64 dart_engine_jit_shared
./buildtools/ninja/ninja -C xcodebuild/ReleaseARM64 samples/embedder:run_timer_async_kernel
xcodebuild/ReleaseARM64/run_timer_async_kernel \
  xcodebuild/ReleaseARM64/gen/timer_kernel.dart.snapshot
# Must print non-zero Ticks (baseline: 103)
```

## Session Log

### Session 2026-03-12
**Duration:** ~8 min (Codex --full-auto)
**What happened:** Codex implemented both callbacks. Caught real API discrepancy:
`Dart_InitializeIsolateCallback` in this SDK version takes `(void** child_isolate_data, char** error)`
not `(void*, void*, char**)` as the plan assumed. Codex adapted signatures correctly.
Build clean, regression `Ticks: 104`.

## Blockers

| # | Blocker | Discovered | Resolved |
|---|---------|-----------|---------|

## Resolved Blockers

| # | Blocker | Resolution | Date |
|---|---------|-----------|------|
| 1 | `Dart_InitializeIsolateCallback` signature mismatch vs plan | 2026-03-12 | Codex adapted to actual typedef |

## Artifacts
- `runtime/engine/engine.h:90,98` — `CreateGroupCallback` + `InitializeIsolateCallback` declarations
- `runtime/engine/engine.cc:102-103` — wired in `CreateInitializeParams`
- `runtime/engine/engine.cc:394,424` — callback implementations
