# dart-zig Benchmarking Guide

How to build, run, and record echo-server benchmark results on both macOS (kqueue) and Linux io_uring (Docker).

---

## Overview

The benchmark measures TCP echo throughput: **N concurrent connections × M round-trips × 1 KB payload**.
Both servers are started on different ports; the same benchmark client drives them back-to-back.

| Component | File | Port |
|---|---|---|
| dart-zig echo server | `lib/echo_server.dart` → `test-snapshots/echo_server.dill` | 9090 |
| dart:io baseline | `lib/dart_io_echo.dart` → `test-snapshots/dart_io_echo.dill` | 9091 |
| benchmark client | `lib/bench_echo_concurrent.dart` → `test-snapshots/bench_echo_concurrent.dill` | client |

Default load: **200 connections × 100 msgs × 1024 B** = 20 000 round-trips per run, 3 timed runs after a warmup pass.

---

## Prerequisites

### macOS (kqueue backend)

```sh
# Verify Zig
zig version          # must print 0.15.2

# Verify engine dylib exists
ls /Users/kartik/StudioProjects/sdk/xcodebuild/ReleaseARM64/libdart_engine_jit_shared.dylib
```

### Linux / Docker (io_uring backend)

```sh
# Docker must be running
docker info | grep -i server

# Verify the builder image exists (build once if not)
docker images | grep dart-zig-builder
# If missing: docker build -t dart-zig-builder sdk/dart-zig/docker/
```

---

## Step 1 — Build the Zig binary

### macOS

```sh
cd /Users/kartik/StudioProjects/sdk/dart-zig
zig build -Doptimize=ReleaseFast
# Output: zig-out/bin/dart-zig
```

### Linux (cross-compile inside Docker)

```sh
cd /Users/kartik/StudioProjects/sdk
docker run --rm \
  -v "$(pwd)":/workspace/sdk \
  dart-zig-builder \
  bash /workspace/sdk/dart-zig/docker/rebuild_linux.sh
# Output: dart-zig/zig-out-linux/bin/dart-zig
```

---

## Step 2 — Recompile `.dill` snapshots (only needed after Dart source changes)

Use the **SDK-bundled dart** (3.12), not the system dart (3.11).

```sh
SDK=/Users/kartik/StudioProjects/sdk
DART=$SDK/xcodebuild/ReleaseARM64/dart
PLATFORM=$SDK/xcodebuild/ReleaseARM64/vm_platform.dill
OUTDIR=$SDK/dart-zig/test-snapshots
GEN_KERNEL=$SDK/pkg/vm/bin/gen_kernel.dart

# Echo server (dart-zig)
$DART $GEN_KERNEL \
  --platform $PLATFORM \
  --link-platform \
  --packages $SDK/dart-zig/.dart_tool/package_config.json \
  -o $OUTDIR/echo_server.dill \
  $SDK/dart-zig/lib/echo_server.dart

# Echo server (dart:io baseline)
$DART $GEN_KERNEL \
  --platform $PLATFORM \
  --link-platform \
  --packages $SDK/dart-zig/.dart_tool/package_config.json \
  -o $OUTDIR/dart_io_echo.dill \
  $SDK/dart-zig/lib/dart_io_echo.dart

# Benchmark client
$DART $GEN_KERNEL \
  --platform $PLATFORM \
  --link-platform \
  --packages $SDK/dart-zig/.dart_tool/package_config.json \
  -o $OUTDIR/bench_echo_concurrent.dill \
  $SDK/dart-zig/lib/bench_echo_concurrent.dart
```

> **Note:** If the platform file version doesn't match the binary you get `"kernel format N is not supported"`. Always use `xcodebuild/ReleaseARM64/dart` + `xcodebuild/ReleaseARM64/vm_platform.dill` together.

---

## Step 3 — Run the benchmark

### macOS (local, kqueue)

Open **two terminals**.

**Terminal 1 — start both servers:**
```sh
SDK=/Users/kartik/StudioProjects/sdk
BIN=$SDK/dart-zig/zig-out/bin/dart-zig
SNAPS=$SDK/dart-zig/test-snapshots
export DYLD_LIBRARY_PATH=$SDK/xcodebuild/ReleaseARM64

ZIG_LOG=/tmp/dart_zig_echo.log
IO_LOG=/tmp/dart_io_echo.log
: > "$ZIG_LOG"
: > "$IO_LOG"

# dart-zig on 9090
$BIN $SNAPS/echo_server.dill 9090 > "$ZIG_LOG" 2>&1 &
ZIG_PID=$!

# dart:io on 9091
$BIN $SNAPS/dart_io_echo.dill 9091 > "$IO_LOG" 2>&1 &
IO_PID=$!

echo "dart-zig PID=$ZIG_PID  dart:io PID=$IO_PID"

# Validate startup before benchmarking
sleep 2
grep -q "dart-zig echo server on port" "$ZIG_LOG" || { echo "dart-zig failed"; sed -n '1,80p' "$ZIG_LOG"; exit 1; }
grep -q "dart:io echo server on port" "$IO_LOG" || { echo "dart:io failed"; sed -n '1,80p' "$IO_LOG"; exit 1; }
```

**Terminal 2 — run the client:**
```sh
SDK=/Users/kartik/StudioProjects/sdk
BIN=$SDK/dart-zig/zig-out/bin/dart-zig
SNAPS=$SDK/dart-zig/test-snapshots
export DYLD_LIBRARY_PATH=$SDK/xcodebuild/ReleaseARM64

echo "=== dart-zig (kqueue) ==="
$BIN $SNAPS/bench_echo_concurrent.dill 127.0.0.1 9090 200 100

echo ""
echo "=== dart:io baseline ==="
$BIN $SNAPS/bench_echo_concurrent.dill 127.0.0.1 9091 200 100
```

**Terminal 1 — stop servers when done:**
```sh
kill $ZIG_PID $IO_PID
```

### Linux (Docker, io_uring)

Single command — `run_bench.sh` handles everything inside the container:

```sh
cd /Users/kartik/StudioProjects/sdk

docker run --rm \
  --security-opt seccomp=unconfined \
  -v "$(pwd)":/workspace/sdk \
  dart-zig-builder \
  bash /workspace/sdk/dart-zig/docker/run_bench.sh
```

> **`--security-opt seccomp=unconfined` is required.** Docker's default seccomp profile blocks `io_uring_setup`. Without it the server exits silently on startup.

---

## Step 4 — Reading the output

```
Concurrent benchmark: 200 conns × 100 msgs × 1024B = 20000 round-trips
Payload: 1024B  Total data: 19531KB  Server: 127.0.0.1:9090
  run 1: 412ms  =>  48543 req/s  ~97 MB/s  (completed: 20000/20000)
  run 2: 294ms  =>  68027 req/s  ~136 MB/s (completed: 20000/20000)
  run 3: 287ms  =>  69686 req/s  ~139 MB/s (completed: 20000/20000)
```

| Field | Meaning |
|---|---|
| `run 1` | First run — JIT cold start, GC layout, OS TCP state. Always slower. |
| `run 2` | JIT warmed. On Linux, GC may not have swept previous data yet ("coasting"). |
| `run 3` | Steady state. On Linux with GC pressure, may dip vs run 2 (GC finalizer storm). |
| `req/s` | Completed round-trips per second. Primary metric. |
| `MB/s` | Bidirectional throughput (rx + tx counted). |

If a run prints `errors:` or `completed < total`, treat that run as invalid.
`bench_echo_concurrent.dart` now exits non-zero when timed runs have errors.

**Interpreting variance:**
- macOS kqueue: run 2 ≈ run 3 is expected. Spread > 10% = something changed.
- Linux Docker: ±30% spread across runs is normal (Docker ARM64 virtualisation noise). Compare **averages across 3 runs**, not individual runs.

---

## Step 5 — Custom load parameters

```sh
# Usage: bench_echo_concurrent.dill <host> <port> <conns> <msgs_per_conn>

# Light load (quick sanity check)
$BIN $SNAPS/bench_echo_concurrent.dill 127.0.0.1 9090 50 50

# Standard load (default)
$BIN $SNAPS/bench_echo_concurrent.dill 127.0.0.1 9090 200 100

# Heavy load (stress the pool — approaches 256-slot limit)
$BIN $SNAPS/bench_echo_concurrent.dill 127.0.0.1 9090 200 500
```

> **Pool limit:** `kPoolSize = 256`. Running > 256 concurrent connections will stall — the pool allocator returns null and ops are dropped. Keep `conns ≤ 200` to leave headroom for accept slots.

Payload size is hardcoded at `kPayload = 1024` bytes in `bench_echo_concurrent.dart`. To change it, edit that constant and recompile the `.dill`.

---

## Step 6 — Recording results

After each benchmark run, append an entry to the CHANGELOG:

**File:** `docs/dart-zig/timeline/CHANGELOG.md`

```markdown
## [PHASE-Nx] Description
**Date:** YYYY-MM-DD
...
### Benchmark Results

**macOS ARM64 (kqueue)**:
\```
dart-zig PhaseNx:   run1=Xk  run2=Xk  run3=Xk req/s
dart:io baseline:   run1=Xk  run2=Xk  run3=Xk req/s
\```

**Linux ARM64 (io_uring, Docker)**:
\```
dart-zig PhaseNx:   run1=Xk  run2=Xk  run3=Xk req/s
dart:io baseline:   run1=Xk  run2=Xk  run3=Xk req/s
\```
```

Always run **both** macOS and Linux benchmarks and record all three run numbers — not just the best. This preserves the full variance picture across phases.

---

## Troubleshooting

### Server starts but client gets `Connection refused`
The servers need ~1–2 s to bind. Add `sleep 2` between starting servers and running the client.

### `io_uring_setup` fails (Linux)
Missing `--security-opt seccomp=unconfined` flag. Docker's default seccomp blocks io_uring syscalls.

### `Bad state: Kernel format X is not supported`
The `.dill` was compiled with a different SDK version than the binary. Recompile using `xcodebuild/ReleaseARM64/dart` + matching `vm_platform.dill`.

### `Pool exhausted` / stalled benchmark
More than 256 concurrent ops in flight. Reduce `conns` below 200, or increase `kPoolSize` in `state.zig` (requires recompile and new `.dill`).

### Run 1 is dramatically lower than run 2–3 (expected)
Normal. Run 1 pays JIT compilation cost. Compare run 2 and run 3 for performance analysis.

### Linux run 3 lower than run 2
Expected under GC pressure phases (pre-10a). With Phase 10a+ embedded pool buffers, run 3 should be ≥ run 2 since there are no GC finalizers in flight.

---

## Quick Reference

```sh
# ---- macOS one-liner (both servers + client) ----
SDK=/Users/kartik/StudioProjects/sdk
BIN=$SDK/dart-zig/zig-out/bin/dart-zig
SNAPS=$SDK/dart-zig/test-snapshots
export DYLD_LIBRARY_PATH=$SDK/xcodebuild/ReleaseARM64

$BIN $SNAPS/echo_server.dill 9090 & ZIG=$!
$BIN $SNAPS/dart_io_echo.dill 9091 & IO=$!
sleep 2

echo "=== dart-zig ===" && $BIN $SNAPS/bench_echo_concurrent.dill 127.0.0.1 9090 200 100
echo "=== dart:io  ===" && $BIN $SNAPS/bench_echo_concurrent.dill 127.0.0.1 9091 200 100

kill $ZIG $IO

# ---- Linux Docker one-liner ----
docker run --rm --security-opt seccomp=unconfined \
  -v "$(pwd)":/workspace/sdk dart-zig-builder \
  bash /workspace/sdk/dart-zig/docker/run_bench.sh
```
