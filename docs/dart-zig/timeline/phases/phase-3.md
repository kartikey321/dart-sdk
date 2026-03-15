# Phase 3 — Zig Host Binary Scaffold

**Started:** 2026-03-12
**Completed:** 2026-03-12
**Status:** COMPLETED

## Goal
Create the `dart-zig/` Zig project. A minimal Zig binary that:
1. Links against `libdart_engine_jit_shared.dylib`
2. Calls `DartEngine_Init` + `DartEngine_CreateIsolate`
3. Runs a simple Dart kernel snapshot (print "Hello from Dart")
4. Exits cleanly

No io_uring, no event loop yet. Pure scaffold + proof of life.

## Prerequisite
Phases 1 + 2 complete ✅

## Success Criteria
- [x] `dart-zig/` directory created at `/Users/kartik/StudioProjects/sdk/dart-zig/`
- [x] `build.zig` compiles cleanly with `zig build`
- [x] `src/engine.zig` has manual bindings for `dart_engine.h` (no @cImport on union)
- [x] `src/main.zig` calls `DartEngine_Init`, `DartEngine_CreateIsolate`, `DartEngine_Shutdown`
- [x] Smoke test: `./zig-out/bin/dart-zig <snapshot>` prints output from Dart code

## Environment
- Zig: `0.15.2` at `/opt/homebrew/Cellar/zig/0.15.2`
- Engine dylib: `../xcodebuild/ReleaseARM64/libdart_engine_jit_shared.dylib`
- Headers: `../runtime/engine/include/dart_engine.h`, `../runtime/include/dart_api.h`
- Platform: ARM64 macOS

## Project Structure

```
dart-zig/
├── build.zig
├── build.zig.zon
└── src/
    ├── main.zig      ← entry point
    └── engine.zig    ← manual C bindings (no @cImport on union)
```

## Key Implementation Notes

### build.zig
- Add include paths: `../runtime/engine/include` and `../runtime/include`
- Add library path: `../xcodebuild/ReleaseARM64`
- Link: `dart_engine_jit_shared`
- Add rpath: `../xcodebuild/ReleaseARM64` (so dylib is found at runtime)
- macOS: may need `-framework CoreFoundation` and `-lobjc`

### src/engine.zig — Manual struct for anonymous union
`@cImport` CANNOT translate `DartEngine_SnapshotData` anonymous union.
Define manually:
```zig
pub const SnapshotKind = enum(c_int) { Kernel = 0, Aot = 1 };
pub const SnapshotData = extern struct {
    script_uri: [*c]const u8,
    kind: c_int,
    // union as 4 pointer-sized fields (AOT has 4, Kernel has 2 + 2 padding)
    field0: [*c]const u8,
    field1: usize,
    field2: [*c]const u8,
    field3: [*c]const u8,
};
```

### src/main.zig — Minimal flow
```
1. DartEngine_Init(&error) → check error
2. DartEngine_KernelFromFile(path, &error) → get snapshot
3. DartEngine_CreateIsolate(snapshot, &error) → get isolate
4. DartEngine_HandleMessage(isolate)  ← drives Dart main()
5. DartEngine_Shutdown()
```

## Smoke Test Snapshot
Use the pre-built hello snapshot from the SDK build:
```sh
ls xcodebuild/ReleaseARM64/gen/  # look for hello_kernel or similar
```
Or compile on the fly:
```sh
xcodebuild/ReleaseARM64/dart compile kernel samples/embedder/hello.dart \
  -o /tmp/hello.dill
dart-zig/zig-out/bin/dart-zig /tmp/hello.dill
# Expected: prints something from Dart
```

## Regression
`run_timer_async_kernel` baseline still `Ticks: ~103` (no changes to engine C++ files).

## Session Log

### Session 2026-03-12
**Duration:** ~15 min (Codex scaffold + Claude fix)
**What happened:**
- Codex created `build.zig`, `build.zig.zon`, `src/engine.zig`, `src/main.zig`. Build clean.
- First smoke test ran silently: `DartEngine_HandleMessage` only drains message queue; does NOT invoke `main()`.
- Correct pattern (from `run_main.cc`): `DartEngine_AcquireIsolate` + `Dart_Invoke(Dart_RootLibrary(), "main", args)`.
- Added `DartEngine_AcquireIsolate/ReleaseIsolate`, `Dart_Invoke`, `Dart_RootLibrary`, `Dart_LookupLibrary`, `Dart_GetNonNullableType`, `Dart_NewListOfTypeFilled` bindings to `engine.zig`.
- Second run failed: `List<dynamic>` not subtype of `List<String>` — must use `Dart_NewListOfTypeFilled` with String type.
- Third run: `hi, world!` ✅

## Blockers
| # | Blocker | Discovered | Resolved |
|---|---------|-----------|---------|

## Resolved Blockers
| # | Blocker | Resolution | Date |
|---|---------|-----------|------|
| 1 | `DartEngine_HandleMessage` doesn't invoke `main()` | 2026-03-12 | Switch to `DartEngine_AcquireIsolate` + `Dart_Invoke` pattern (from `run_main.cc`) |
| 2 | `Dart_NewList` creates `List<dynamic>`, fails type check | 2026-03-12 | Use `Dart_NewListOfTypeFilled(string_type, filler, len)` |

## Artifacts
- `dart-zig/build.zig` — Zig 0.15.x build script, links `dart_engine_jit_shared`, absolute rpath, CoreFoundation + objc
- `dart-zig/build.zig.zon` — package file
- `dart-zig/src/engine.zig` — manual extern bindings (no @cImport), `DartHandle`, `SnapshotData`, `DartZigIoHooks`, full dart_api.h subset
- `dart-zig/src/main.zig` — init → kernel-from-file → create isolate → acquire → invoke main → shutdown
- `dart-zig/zig-out/bin/dart-zig` — built binary
- Smoke test: `dart-zig xcodebuild/ReleaseARM64/gen/hello_kernel.dart.snapshot` → `hi, world!` ✅
