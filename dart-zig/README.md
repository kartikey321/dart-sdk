# dart-zig

A custom Dart runtime with a Zig-based event loop, replacing `dart:io` with a
direct kqueue (macOS) / io_uring (Linux) backend. The goal is to close the gap
between Dart and native server runtimes by eliminating unnecessary abstraction
layers between the Dart VM and the kernel.

---

## Status

Current state:

- Runtime substrate exists for both Linux (`io_uring`) and macOS (`kqueue`).
- The project is strongest today as a custom runtime plus TCP and HTTP server
  platform.
- Linux is the production-first backend.
- macOS is implemented, but is not yet at Linux correctness parity.
- This is not yet a full `dart:io` replacement.

Current focus:

- keep the Linux path stable and production-safe
- close the remaining macOS backend gaps
- evolve the runtime/TCP/HTTP server stack before expanding to broader
  `dart:io` compatibility

Latest major runtime milestone:

- `PERF-6`: keep-alive loop native, with the entire connection lifecycle in Zig
  and zero Dart interactions per request on the fused fast path

Important caveats:

- The fused `http_server.dart` fast path is the best-performing path today.
- The higher-level `zig_http_server.dart` layer is more ergonomic, but slower.
- For current macOS backend risks and parity work, see
  `docs/dart-zig/macos-gap-review.md`.
- The benchmark numbers below are split into:
  - recent validated measurements on the current codebase
  - older milestone results kept for historical context

### Recently validated measurements

These are the latest measurements that were rechecked during the current audit
cycle.

**Linux single-worker, `io_uring`, `wrk -t4 -c256 -d5s`:**
```
Fused fast path (`lib/http_server.dart`, JIT):        ~105k req/s
`ZigHttpServer` (`lib/zig_http_server.dart`, JIT):    ~20k req/s
`ZigHttpServer` (`lib/zig_http_server.dart`, AOT):    ~34k req/s
```

Interpretation:

- The fused Zig-side loop remains the performance path.
- The Dart-layer `ZigHttpServer` abstraction is significantly slower, but it is
  still useful as the higher-level API surface.
- These numbers were measured on a single server worker, so they are not
  multi-worker scaling claims.

### Historical milestone results

These are older milestone measurements that are still useful for trend history,
but should not be treated as current parity proof for the present branch
without rerunning them.

**macOS ARM64 single-worker (historical, kqueue, `wrk -t4 -c128 -d10s`):**
```
PERF-6 (loop op):   ~243k req/s JIT  /  ~275k req/s AOT  (0 await/request, 0 heap allocs)
PERF-4 (serve op):  ~178k req/s      (1 await/request, 0 heap allocs)
Phase 14 baseline:  ~159k req/s      (3 awaits/request, batch dispatcher)
```

**Linux VPS 6-core (historical, io_uring, ReleaseFast, taskset CPU-pinned, `bench_vps.sh`):**
```
               JIT       AOT     vs PERF-4 JIT
1 worker:    ~102k      97k          +7%
3 workers:   ~200k     ~204k         ~flat
6 workers:   ~210k     ~207k         +9%
```
> JIT 1w beats PERF-4 (95k) after JIT safepoint fix (`jit_idle_iters` threshold=128 in io_uring.zig).

---

## Architecture

```
Dart application code
        │
        │  native calls (@pragma vm:external-name)
        ▼
   zig_io.dart  ─────────────────────────────────────────┐
                                                          │
   src/zig_io/natives/tcp.zig  (native entry points)     │
        │  allocSlot / postResult                        │
        ▼                                                 │
   src/zig_io/state.zig  (shared pool + LoopOps vtable)  │
        │                                                 │
        ▼                                                 │
   src/event_loop/kqueue.zig   (macOS)                   │
   src/event_loop/io_uring.zig (Linux)                   │
        │                                                 │
        ▼                                                 │
   Kernel (kevent / io_uring_enter)  ◄───────────────────┘
```

- **CompletionCtx pool**: 4096 slots × ~8 KB each (32 MB heap). Each in-flight accept/recv/send occupies one slot. O(1) free-list allocator (`SlotAllocator`).
- **Inline write fast-path**: `submitSend` tries `posix.write()` inline before queuing a SQE/kevent. On loopback the TCP send buffer is never full — eliminates a full kernel round-trip per echo.
- **AOT support**: `dart-zig-aot` binary links `dart_engine_aot_shared`. Pass `.dylib` (macOS) or `.so` (Linux) snapshot; runtime auto-detects by extension.

## Current Scope

What exists today:

- custom Dart runtime embedding
- Linux `io_uring` event loop
- macOS `kqueue` event loop
- TCP accept/read/write/close primitives
- HTTP server fast path in Zig
- higher-level Dart HTTP server abstraction
- partial TLS groundwork

What does not exist yet as production-complete surface:

- full `dart:io` parity
- `HttpClient` replacement
- filesystem/process/DNS/UDP parity
- production-parity macOS backend behavior

If the goal is full `dart:io` replacement, that is a larger follow-on project.
The current codebase should be understood first as a server runtime and native
I/O platform for Dart.

---

## Prerequisites

### macOS (kqueue backend)

```sh
zig version          # must print 0.15.2
ls /Users/kartik/StudioProjects/sdk/xcodebuild/ReleaseARM64/libdart_engine_jit_shared.dylib
ls /Users/kartik/StudioProjects/sdk/xcodebuild/ReleaseARM64/libdart_engine_aot_shared.dylib
```

### Linux / Docker (io_uring backend)

```sh
docker info | grep -i server
docker images | grep dart-zig-builder
# If missing: docker build -t dart-zig-builder sdk/dart-zig/docker/
```

---

## Build

### JIT binary (runs `.dill` kernel snapshots)

```sh
cd /Users/kartik/StudioProjects/sdk/dart-zig
zig build -Doptimize=ReleaseFast
# Output: zig-out/bin/dart-zig
```

### AOT binary (runs `.dylib`/`.so` AOT snapshots)

```sh
zig build -Doptimize=ReleaseFast -Daot=true
# Output: zig-out/bin/dart-zig-aot
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

## Compiling Snapshots

### JIT kernel snapshots (`.dill`)

```sh
SDK=/Users/kartik/StudioProjects/sdk
DART=$SDK/xcodebuild/ReleaseARM64/dart
PLATFORM=$SDK/xcodebuild/ReleaseARM64/vm_platform.dill
GEN_KERNEL=$SDK/pkg/vm/bin/gen_kernel.dart
OUTDIR=$SDK/dart-zig/test-snapshots

$DART $GEN_KERNEL --platform $PLATFORM --link-platform \
  -o $OUTDIR/echo_server.dill       $SDK/dart-zig/lib/echo_server.dart
$DART $GEN_KERNEL --platform $PLATFORM --link-platform \
  -o $OUTDIR/dart_io_echo.dill      $SDK/dart-zig/lib/dart_io_echo.dart
$DART $GEN_KERNEL --platform $PLATFORM --link-platform \
  -o $OUTDIR/bench_echo_concurrent.dill $SDK/dart-zig/lib/bench_echo_concurrent.dart
```

### AOT snapshots (macOS → `.dylib`, Linux → `.so`)

```sh
GEN_SNAP=$SDK/xcodebuild/ReleaseARM64/gen_snapshot

# Step 1: AOT kernel (enables TFA tree-shaking)
$DART $GEN_KERNEL --platform $PLATFORM --link-platform --aot \
  -o $OUTDIR/echo_server_aot.dill       $SDK/dart-zig/lib/echo_server.dart
$DART $GEN_KERNEL --platform $PLATFORM --link-platform --aot \
  -o $OUTDIR/dart_io_echo_aot.dill      $SDK/dart-zig/lib/dart_io_echo.dart
$DART $GEN_KERNEL --platform $PLATFORM --link-platform --aot \
  -o $OUTDIR/bench_echo_concurrent_aot.dill $SDK/dart-zig/lib/bench_echo_concurrent.dart

# Step 2: Native snapshot (macOS Mach-O dylib)
$GEN_SNAP --snapshot-kind=app-aot-macho-dylib \
  --macho=$OUTDIR/echo_server_aot.dylib       $OUTDIR/echo_server_aot.dill
$GEN_SNAP --snapshot-kind=app-aot-macho-dylib \
  --macho=$OUTDIR/dart_io_echo_aot.dylib      $OUTDIR/dart_io_echo_aot.dill
$GEN_SNAP --snapshot-kind=app-aot-macho-dylib \
  --macho=$OUTDIR/bench_echo_concurrent_aot.dylib $OUTDIR/bench_echo_concurrent_aot.dill

# Step 2 (Linux ELF .so): replace --snapshot-kind=app-aot-macho-dylib --macho=
#   with --snapshot-kind=app-aot-elf --elf=
```

---

## Running

```sh
export DYLD_LIBRARY_PATH=/Users/kartik/StudioProjects/sdk/xcodebuild/ReleaseARM64

BIN=/Users/kartik/StudioProjects/sdk/dart-zig/zig-out/bin/dart-zig
SNAPS=/Users/kartik/StudioProjects/sdk/dart-zig/test-snapshots

# Start a server
$BIN $SNAPS/echo_server.dill 9090
```

---

## Benchmarking

See **`docs/dart-zig/benchmarking.md`** for the full guide. Quick reference:

### macOS — JIT

```sh
SDK=/Users/kartik/StudioProjects/sdk
BIN=$SDK/dart-zig/zig-out/bin/dart-zig
SNAPS=$SDK/dart-zig/test-snapshots
export DYLD_LIBRARY_PATH=$SDK/xcodebuild/ReleaseARM64

# Start servers
$BIN $SNAPS/echo_server.dill  9090 & ZIG=$!
$BIN $SNAPS/dart_io_echo.dill 9091 & IO=$!
sleep 2

# Run benchmark
echo "=== dart-zig ===" && $BIN $SNAPS/bench_echo_concurrent.dill 127.0.0.1 9090 200 100
echo "=== dart:io  ===" && $BIN $SNAPS/bench_echo_concurrent.dill 127.0.0.1 9091 200 100

kill $ZIG $IO
```

### macOS — AOT

```sh
AOT=$SDK/dart-zig/zig-out/bin/dart-zig-aot

$AOT $SNAPS/echo_server_aot.dylib  9090 & ZIG=$!
$AOT $SNAPS/dart_io_echo_aot.dylib 9091 & IO=$!
sleep 2

echo "=== dart-zig AOT ===" && $AOT $SNAPS/bench_echo_concurrent_aot.dylib 127.0.0.1 9090 200 100
echo "=== dart:io  AOT ===" && $AOT $SNAPS/bench_echo_concurrent_aot.dylib 127.0.0.1 9091 200 100

kill $ZIG $IO
```

### Linux — Docker (io_uring)

```sh
cd /Users/kartik/StudioProjects/sdk
docker run --rm --security-opt seccomp=unconfined \
  -v "$(pwd)":/workspace/sdk dart-zig-builder \
  bash /workspace/sdk/dart-zig/docker/run_bench.sh
```

> `--security-opt seccomp=unconfined` is required — Docker's default seccomp blocks `io_uring_setup`.

### Reading results

```
  run 1: 196ms  =>  196078 req/s  ~392 MB/s  (completed: 20000/20000)
  run 2:  74ms  =>  270270 req/s  ~541 MB/s  (completed: 20000/20000)
  run 3:  73ms  =>  273973 req/s  ~548 MB/s  (completed: 20000/20000)
```

- **Run 1** — cold start (JIT warmup + OS TCP state). Always slower in JIT mode.
- **Run 2–3** — steady state. AOT: run 1 ≈ run 3.
- **Primary metric**: `req/s`. Ignore `MB/s` for cross-comparison (payload-dependent).
- Linux Docker: ±30% variance is normal. Compare averages across 3 runs.

---

## Project Layout

```
dart-zig/
├── build.zig                    # Zig build — -Daot=true for AOT binary
├── lib/
│   ├── zig_io.dart              # Dart-side native bindings
│   ├── echo_server.dart         # dart-zig echo server (benchmark target)
│   ├── dart_io_echo.dart        # dart:io echo server (baseline)
│   └── bench_echo_concurrent.dart
├── src/
│   ├── main.zig                 # Entry point — loads snapshot, runs event loop
│   ├── engine.zig               # Dart engine C bindings
│   ├── event_loop/
│   │   ├── common.zig           # Platform dispatch
│   │   ├── kqueue.zig           # macOS backend
│   │   └── io_uring.zig         # Linux backend
│   ├── zig_io/
│   │   ├── state.zig            # CompletionCtx pool, SlotAllocator, LoopOps vtable
│   │   ├── resolver.zig         # ZigIo native function resolver
│   │   ├── native_table.zig     # ZigIo native lookup table
│   │   └── natives/
│   │       ├── tcp.zig          # Native entry points (accept/recv/send/close, token API)
│   │       ├── write.zig        # ZigIo_StdoutWrite
│   │       └── version.zig      # ZigIo_Version
│   └── http/
│       ├── parser.zig           # Zero-allocation HTTP/1.1 state machine + routeRequest()
│       ├── responses.zig        # Comptime-constant response byte slices (serve op)
│       ├── natives.zig          # ZigHttp_Parse / ZigHttp_RouteRequest natives
│       ├── native_table.zig     # ZigHttp native lookup table
│       └── resolver.zig         # ZigHttp native function resolver
├── lib/
│   ├── zig_io.dart              # Dart-side native bindings + batch dispatcher
│   ├── zig_http.dart            # HttpRequest + parseHttpRequest (ZigHttp_Parse)
│   ├── echo_server.dart         # dart-zig echo server (benchmark target)
│   ├── dart_io_echo.dart        # dart:io echo server (baseline)
│   ├── http_server.dart         # HTTP/1.1 Hello World server (wrk target)
│   └── bench_echo_concurrent.dart
├── test-snapshots/              # Compiled .dill and .dylib/.so snapshots
├── docker/
│   ├── Dockerfile
│   ├── rebuild_linux.sh
│   └── run_bench.sh
└── docs/dart-zig/
    ├── benchmarking.md          # Detailed benchmarking guide
    └── timeline/CHANGELOG.md   # Phase-by-phase progress log
```

---

## Benchmark Notes

Read the benchmark tables carefully:

- recent validated measurements are the most trustworthy for current state
- historical milestone numbers are useful for trend tracking
- macOS numbers in this file are currently historical until rerun on the clean
  upstream-based branch
- Linux is the only backend that has been recently revalidated during the audit

## Historical Benchmark History

### macOS ARM64, kqueue, `wrk -t4 -c128`

| Phase  | What                          | req/sec JIT | req/sec AOT |
|--------|-------------------------------|------------:|------------:|
| 11     | AOT baseline (echo)           | —           | 291k avg    |
| 13     | HTTP/1.1 server               | 133–147k    | —           |
| 14     | Batch dispatcher              | ~159k       | —           |
| PERF-2 | ZigHttp_RouteRequest          | ~163k       | —           |
| PERF-3 | recv_route op                 | ~170k       | —           |
| PERF-4 | Fused serve op (1 await/req)  | ~178k       | ~178k       |
| **PERF-6** | **Loop native (0 await/req)** | **~243k** | **~275k** |

### Linux VPS, 6-core, io_uring, taskset CPU-pinned, ReleaseFast

| Phase  | 1w JIT | 3w JIT | 6w JIT | 1w AOT | 3w AOT | Notes |
|--------|-------:|-------:|-------:|-------:|-------:|-------|
| 14     | ~37k  | ~126k  | —     | —     | —     | 3 awaits/req |
| **PERF-4/5** | **95k** | **206k** | 192k¹ | **97k** | **238k** | **1 await/req** |

> ¹ 6-worker number limited by core contention on a 6-core VPS — wrk and server share cores 3–5.

### Linux VPS, 6-core, io_uring, taskset CPU-pinned

| Workers | Server cores | req/sec (pre-PERF-4) |
|---------|-------------|---------------------:|
| 1       | 0           | ~37k                 |
| 3       | 0–2         | ~126k (3.4×)         |
| 6       | 0–2         | TBD                  |

> - Phase 13–14 HTTP measured with wrk on same machine; client/server compete for cores.
> - Linux multi-worker uses `taskset -c` to pin server + client to separate core ranges.
> - PERF-3/4 estimates based on macOS; VPS numbers pending next benchmark run.

---

## Docs

- `docs/dart-zig/benchmarking.md` — full setup, build, run, and recording guide
- `docs/dart-zig/macos-gap-review.md` — current macOS backend parity and safety gaps
- `docs/dart-zig/timeline/CHANGELOG.md` — phase-by-phase development log
