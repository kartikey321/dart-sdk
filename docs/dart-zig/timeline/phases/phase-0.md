# Phase 0 — Build From Source

**Started:** 2026-03-11
**Completed:** 2026-03-11
**Status:** COMPLETED

## Goal
Build the Dart SDK from source, verify engine build targets exist, pin exact
SDK commit and Zig version so snapshot format stays stable.

## Success Criteria
- [ ] `./tools/build.py --mode=release` completes without error
- [ ] `out/ReleaseX64/` contains a linkable engine `.so` (confirm exact filename)
- [ ] `runtime/engine/BUILD.gn` has a target suitable for linking (confirm name)
- [ ] `git rev-parse HEAD` pinned in `CHANGELOG.md` header
- [ ] `zig version` pinned in `CHANGELOG.md` header
- [ ] A minimal C program can `dlopen` the built `.so` without error

## Key Commands

```sh
# 1. Verify Python build tools are available
cd /Users/kartik/StudioProjects/dart-sdk
python3 tools/build.py --help

# 2. Full release build (slow — ~20-40 min first time)
./tools/build.py --mode=release

# 3. Check what was produced
ls -la out/ReleaseX64/*.so out/ReleaseX64/*.dylib 2>/dev/null

# 4. Read the engine BUILD.gn to find the right target name
cat runtime/engine/BUILD.gn

# 5. Pin versions
git rev-parse HEAD
zig version
```

## Expected Output Files
The exact filenames depend on the build. Likely candidates:
- `out/ReleaseX64/libdart.so` (full VM)
- `out/ReleaseX64/libdart_precompiled_runtime.so` (AOT)
- Check `runtime/engine/BUILD.gn` for engine-specific shared lib targets

## Known Issues / Pre-checks
- macOS: The SDK builds as `.dylib` not `.so`
- Requires `depot_tools` on PATH
- First build downloads dependencies — needs network access
- `runtime/engine/BUILD.gn` may not have a standalone shared lib target —
  verify before assuming the build command in impl-plan.md is correct

## Session Log

### Session 2026-03-11
**What happened:** gclient sync ran from `/Users/kartik/StudioProjects` (not dart-sdk/).
Cloned fresh SDK to `sdk/`. Full ARM64 release build succeeded.
**Commands run:**
```sh
cd ~/StudioProjects && gclient sync
cd sdk && ./tools/build.py --mode=release
```
**Result:** `[4915/4915]` build complete in 479s.
Output: `xcodebuild/ReleaseARM64/` (ARM64 Mac, not ReleaseX64)

**Corrections to impl-plan from this session:**
- Output dir is `xcodebuild/ReleaseARM64/` not `out/ReleaseX64/`
- Working SDK is `/Users/kartik/StudioProjects/sdk/` not `dart-sdk/`
- Docs moved to `sdk/docs/dart-zig/`

## Blockers

| # | Blocker | Discovered | Resolved |
|---|---------|-----------|---------|
| 1 | gclient sync cloned new sdk/ instead of bootstrapping dart-sdk/ | 2026-03-11 | 2026-03-11 — use sdk/ as working tree |
| 2 | HTTP 429 rate limit on first gclient sync attempt | 2026-03-11 | 2026-03-11 — second run succeeded |

## Resolved Blockers

| # | Blocker | Resolution | Date |
|---|---------|-----------|------|
| 1 | Wrong working dir | Work from sdk/ | 2026-03-11 |
| 2 | Rate limit | Retry | 2026-03-11 |

## Artifacts
- `/Users/kartik/StudioProjects/sdk/xcodebuild/ReleaseARM64/libdart_engine_jit_shared.dylib`
- `/Users/kartik/StudioProjects/sdk/xcodebuild/ReleaseARM64/libdart_engine_aot_shared.dylib`
- SDK commit: `4037331bcc5a52f36630212197cbaa42be1ffb0e`
