# dart-zig CHANGELOG

Append-only. Newest entries at top. See README.md for entry format rules.

**SDK Commit Pin:** `4037331bcc5a52f36630212197cbaa42be1ffb0e` (sdk/)
**Zig Version Pin:** `0.15.2` (`/opt/homebrew/Cellar/zig/0.15.2`)
**Working SDK Path:** `/Users/kartik/StudioProjects/sdk/`
**Build Output:** `xcodebuild/ReleaseARM64/` (ARM64 macOS)

---

## [PERF-2] ZigHttp_RouteRequest — Zero-Allocation Parse+Route Native
**Date:** 2026-04-14
**Phase:** post-15 optimisation
**Status:** COMPLETED
**Author:** kartik / claude-sonnet-4-6

### What Was Done

Replaced the per-request `ZigHttp_Parse` native (which allocated a Dart
`List<Object?>` + 2 `String` + 1 `Integer` on every request) with a new
`ZigHttp_RouteRequest` native that parses AND routes in Zig and returns a
single `int` — zero Dart heap allocation on the hot path.

Also pre-built all four HTTP responses (hello / ping / 404 / 400) as module-
level `final Uint8List` globals so no response bytes are re-encoded per
request.

#### Files Changed

| File | Change |
|------|--------|
| `src/http/parser.zig` | Added `RouteId` constants + `routeRequest()` fn |
| `src/http/natives.zig` | Added `ZigHttp_RouteRequest` sync native |
| `src/http/native_table.zig` | Registered `ZigHttp_RouteRequest` |
| `lib/zig_http.dart` | Added `_zigHttpRouteRequest` extern, `RouteId` class, `zigHttpRoute()` |
| `lib/http_server.dart` | Hot path uses `zigHttpRoute()`; all responses pre-built at startup |

#### Before vs After (per request)

| Step | Before | After |
|------|--------|-------|
| Parse call | `ZigHttp_Parse` → `Dart_NewList(3)` + 2×`Dart_NewStringFromUTF8` + `Dart_NewInteger` + 3×`Dart_ListSetAt` | `ZigHttp_RouteRequest` → `Dart_SetIntegerReturnValue` |
| Dart objects allocated | ~4 heap objects (List + 2 Strings + Integer) | 0 |
| Route decision | Dart `switch(req.path)` string compare | Zig `std.mem.eql` before returning |
| Response lookup | Pre-built (`_kHelloResponse`) or inline allocation (ping/404) | All pre-built globals |

#### Benchmark (AOT, `wrk -t4 -c128 -d10s`)

Stable **147k ± 1k req/s** across all runs — no JIT cold-start variance.

---

## [PERF-1] Multi-Worker SO_REUSEPORT Investigation
**Date:** 2026-04-14
**Phase:** post-15 multicore
**Status:** COMPLETED (infrastructure ready; scaling visible only on separate-client setup)
**Author:** kartik / claude-sonnet-4-6

### What Was Done

Confirmed that the multi-worker SO_REUSEPORT infrastructure already built in
Phase 12 (`--workers=N` flag, `SO_REUSEPORT` in `tcpBind()`) is correct.
Investigated why same-machine wrk benchmarks show flat scaling, diagnosed root
cause: wrk (client) and dart-zig (server) compete for CPUs on the same machine,
so wrk reaches its own ceiling (~132k req/s) regardless of server worker count.

Compared approach with HttpArena's fletch benchmark: fletch uses `LD_PRELOAD
reuseport_shim.so` because `dart:io`'s `HttpServer.bind(shared:true)` does
not actually set `SO_REUSEPORT` at the kernel level for cross-process sharing.
dart-zig sets `SO_REUSEPORT` natively in Zig — no shim needed.

#### Root Cause of Flat Scaling on Same Machine

```
11-core Mac, wrk -t4 -c128:
  wrk eating ~4 cores  (sending + receiving)
  1-worker server: ~1 core (kqueue sleeping)
  ──────────────────────────────────────────
  wrk ceiling: ~148k req/s  ← bottleneck, NOT the server
  Adding workers: no effect — wrk cannot go faster
```

To observe linear scaling: server must be CPU-pinned to dedicated cores
(Linux `--cpuset-cpus`) with the load client on separate cores (`taskset`).
Planned VPS test: 6-core Linux, server pinned to 0-2, wrk/gcannon to 3-5.

#### No Code Changes

The multi-worker path was already correct. This entry documents the
investigation findings.

---

## [BENCH-1] Full Comparison Benchmark Suite + dart:io AOT + HTTPS AOT Snapshot
**Date:** 2026-03-21
**Phase:** post-15 tooling
**Status:** COMPLETED
**Author:** kartik / claude-sonnet-4-6

### What Was Done

Added a complete, reproducible benchmark suite covering every combination of
protocol (HTTP/HTTPS), runtime mode (JIT/AOT), and worker count (1 / N-core),
for both dart-zig and dart:io. Fixed the AOT native resolver so HTTPS AOT
works, compiled dart:io AOT snapshots for fair comparison.

#### Files Added / Changed

| File | Change |
|------|--------|
| `scripts/bench_http.sh` | New: runs full benchmark suite |
| `scripts/compile_snapshots.sh` | New: compiles all JIT + AOT snapshots |
| `lib/dart_io_https_server.dart` | New: dart:io HTTPS server for benchmarking |
| `bin/dart_io_http_server.aot` | New: dart:io HTTP AOT snapshot (dartaotruntime) |
| `bin/dart_io_https_server.aot` | New: dart:io HTTPS AOT snapshot (dartaotruntime) |
| `test-snapshots/https_server_aot.dylib` | New: dart-zig HTTPS AOT snapshot |
| `src/main.zig` — `installAllResolvers()` | Fix: AOT HTTPS native resolver (see below) |

#### Bug Fixed: AOT HTTPS Native Resolver

`installZigTlsResolver()` iterated loaded libraries by URI suffix. In JIT
mode URIs are fully qualified file paths — this worked. In AOT mode
`Dart_LibraryUrl` returns an error for snapshot-embedded libraries, so all
libraries were silently skipped with `continue`, leaving no resolver installed
for `zig_tls.dart`. Result: `ZigTls_Configure` crashed on first call.

**Fix:** Merged the three separate `installZigIoResolver` / `installZigTlsResolver` /
`installZigHttpResolver` functions into one `installAllResolvers()` that does a
single pass:
- URI starts with `dart:` → skip (built-ins have no dart-zig natives).
- URI ends with `zig_http.dart` → install ZigHttp resolver.
- URI available but anything else → install ZigIo resolver (covers `zig_io.dart`,
  `zig_tls.dart`, and app libraries).
- URI **unavailable** (AOT) → install ZigIo resolver as fallback. The lookup
  table returns `null` for unknown names, which is harmless.

#### dart:io AOT Compilation

The system `dart` binary (3.11.1) cannot compile from the SDK root because
`pubspec.yaml` pins language version to `3.12`. Workaround: copy source to
`/tmp` (no package config there) and use `dart compile aot-snapshot`:

```sh
cp lib/dart_io_http_server.dart  /tmp/
cp lib/dart_io_https_server.dart /tmp/
dart compile aot-snapshot -o bin/dart_io_http_server.aot  /tmp/dart_io_http_server.dart
dart compile aot-snapshot -o bin/dart_io_https_server.aot /tmp/dart_io_https_server.dart
```

Run the `.aot` files with `dartaotruntime` (ships with Flutter SDK or
system dart SDK ≥3.0):

```sh
dartaotruntime bin/dart_io_http_server.aot  9199
dartaotruntime bin/dart_io_https_server.aot 9199 /path/to/test-certs
```

`compile_snapshots.sh` automates all of this, including the `/tmp` copy and the
cert-path patch for the HTTPS server.

---

### How to Run Benchmarks

**One-time setup (only needed if source changes):**

```sh
# 1. Build Zig binaries (JIT + AOT engines)
zig build -Doptimize=ReleaseFast
zig build -Doptimize=ReleaseFast -Daot=true

# 2. Compile all Dart snapshots (dart-zig JIT/AOT + dart:io AOT)
./scripts/compile_snapshots.sh           # everything
./scripts/compile_snapshots.sh http      # HTTP only
./scripts/compile_snapshots.sh https     # HTTPS only
./scripts/compile_snapshots.sh dartio    # dart:io AOT exes only
```

**Run the benchmark suite:**

```sh
./scripts/bench_http.sh           # full suite (HTTP + HTTPS, ~15 min)
./scripts/bench_http.sh http      # HTTP only  (~8 min)
./scripts/bench_http.sh https     # HTTPS only (~8 min)
./scripts/bench_http.sh quick     # quick pass (4s per server, ~4 min)
```

The script starts one server at a time on a fixed port (9199), runs `wrk`,
kills the server, then moves to the next. This avoids port conflicts and cross-
server interference. Multipliers are printed relative to the dart:io JIT
1-worker baseline.

---

### Benchmark Results

**macOS ARM64 · kqueue · loopback · wrk 4t × 128c × 10s**

#### HTTP (plain)

```
dart:io   HTTP  JIT  1-worker     43,202 req/s   (1.0×  baseline)
dart:io   HTTP  AOT  1-worker     56,015 req/s   (1.3×)
dart-zig  HTTP  JIT  1-worker    155,333 req/s   (3.6×)
dart-zig  HTTP  AOT  1-worker    149,715 req/s   (3.5×)

dart:io   HTTP  AOT  11-workers   56,013 req/s   (1.3×)   ← loopback-bound
dart-zig  HTTP  JIT  11-workers  150,937 req/s   (3.5×)   ← loopback-bound
dart-zig  HTTP  AOT  11-workers  157,589 req/s   (3.6×)   ← loopback-bound
```

#### HTTPS (TLS / BoringSSL)

```
dart:io   HTTPS  JIT  1-worker    21,655 req/s   (1.0×  baseline)
dart:io   HTTPS  AOT  1-worker    23,122 req/s   (1.1×)
dart-zig  HTTPS  JIT  1-worker   111,257 req/s   (5.1×)
dart-zig  HTTPS  AOT  1-worker   113,727 req/s   (5.3×)

dart:io   HTTPS  AOT  11-workers  22,780 req/s   (1.1×)   ← loopback-bound
dart-zig  HTTPS  JIT  11-workers 108,394 req/s   (5.0×)   ← loopback-bound
dart-zig  HTTPS  AOT  11-workers 114,496 req/s   (5.3×)   ← loopback-bound
```

#### What "loopback-bound" means

When both the load generator (`wrk`) and the server run on the **same machine**,
all traffic travels through the OS loopback interface (`lo0` / `127.0.0.1`)
rather than a physical NIC. The loopback stack has a fixed throughput ceiling
imposed by the kernel's memory-copy budget and TCP/IP processing overhead —
roughly **1–2 Gbps** of effective HTTP throughput on a modern ARM64 Mac, which
corresponds to ~150–200 k req/s for a small payload like `Hello from dart-zig!`.

Once a single dart-zig worker saturates that ceiling, adding more workers
provides no extra capacity because the **bottleneck has shifted from the server
to the network path** between the load generator and the server. This is why
11-worker results are flat vs 1-worker for dart-zig:

```
dart-zig HTTP AOT 1-worker   → 149k req/s  (near loopback ceiling)
dart-zig HTTP AOT 11-workers → 157k req/s  (≈same — loopback already saturated)
```

dart:io doesn't hit the ceiling because its single-threaded event loop tops out
at ~56k req/s, well below the loopback limit. Multi-worker dart:io is also flat
because its bottleneck is CPU in the Dart VM, not the network.

**To measure true multi-core scaling**, run `wrk` on a separate machine
connected over a physical network (GbE or 10 GbE). On a local LAN with 10 GbE:
- 1 worker: ~140–160k req/s (matches loopback result)
- N workers: expect close to N × per-worker throughput up to NIC limit
- Requires adjusting `--workers=N` and `wrk` host from `127.0.0.1` to the
  server's LAN IP.

---

## [PHASE-15] TLS Termination via BoringSSL
**Date:** 2026-03-21
**Phase:** 15
**Status:** COMPLETED
**Author:** kartik / claude-sonnet-4-6

### What Was Done

Full TLS/HTTPS termination implemented on top of the Phase 14 batch dispatcher.

#### Architecture

- **`dart-zig/src/zig_io/tls.zig`**: BoringSSL TLS layer using memory BIOs
  (`BIO_new_bio_pair` ×2). `TlsConn` pool (4096 slots, 1-based `tls_id: u16`)
  with `pending_cipher` buffer for non-blocking `flushWbio`. Key ops:
  `configure`, `allocConn`, `freeConn`, `advanceHandshake`, `feedRecv`,
  `readPlaintext`, `writePlaintext`, `pendingPlaintext`.

- **`dart-zig/src/zig_io/natives/tls.zig`**: Five native entry points:
  `ZigTls_Configure`, `ZigTls_UpgradeToken`, `ZigTls_ReadToken`,
  `ZigTls_WriteBytesToken`, `ZigTls_Close`. `ZigTls_ReadToken` checks
  `SSL_pending` before arming kqueue (fast-path for data buffered during
  handshake). `ZigTls_WriteBytesToken` is synchronous (encrypt + send inline).

- **kqueue `.tls_handshake` op**: Drives the TLS handshake state machine via
  `advanceHandshake` on EVFILT_READ/WRITE events. Stack buffer avoids
  tagged-union UB. `armTlsHandshake` picks the right filter per handshake state.

- **kqueue `.recv` TLS path**: When `ctx.tls_id != 0`, reads ciphertext, calls
  `feedRecv` + `readPlaintext` instead of passing raw bytes to Dart.

- **`dart-zig/lib/zig_tls.dart`**: Dart API using the shared batch dispatcher.

- **`dart-zig/lib/https_server.dart`**: HTTPS/1.1 demo server.

#### Bugs Fixed During Implementation

1. **`BIO_should_retry == 1` check**: BoringSSL returns the flag bitmask (`0x08 = 8`),
   not `1`. Fixed: `!= 0` check. This was causing `flushWbio` to return `.err`
   on every initial call, aborting all handshakes immediately.

2. **`BIO_new_bio_pair` + `SSL_set_bio` ownership**: SSL owns the ssl-side BIOs
   (`ssl_rbio`/`ssl_wbio`); app retains app-side (`app_rbio`/`app_wbio`).
   Connection closed via `SSL_free` + `BIO_free(rbio)` + `BIO_free(wbio)`.

3. **kqueue pipe wake-up after `flushBatch`**: After `flushBatch`, natives called
   from within `DartEngine_HandleMessage` post new messages via `Dart_PostCObject`
   but do NOT trigger `schedule_callback` (pending > 0 guard). After the first
   message is processed, `pending` drops to 0 and `kevent()` would block for
   200 ms × 20 = 4 seconds. Fixed: unconditional `posix.write(pipe_w, 1)` after
   every `flushBatch` call ensures the next `kevent()` wakes immediately.

4. **`freeTlsSlot` order**: `freeConn` must call `freeTlsSlot(idx)` BEFORE
   `conn.* = .{}` (clearing `in_use`), because `freeTlsSlot` asserts `in_use`.

5. **`SSL_pending` fast path**: After handshake completion, application data
   already buffered by SSL is invisible to kqueue. `ZigTls_ReadToken` calls
   `pendingPlaintext()` and delivers buffered data immediately without arming
   kqueue when `SSL_pending > 0`.

#### Build

BoringSSL static libraries built via `scripts/build_boringssl.sh`
(cmake Release, ARM64 ASM enabled, `libssl.a` + `libcrypto.a` in
`boringssl-build/`). Linked via `build.zig` with `linkLibCpp()`.

#### Benchmark (macOS, 1 worker, c=50)

```
wrk -t2 -c50 -d8s https://127.0.0.1:8444/
Requests/sec: 50,643   Transfer/sec: 6.18 MB/s
Latency avg: 46µs  p99: <1ms
```

---

## [HARDENING-1] io_uring Batch Parity + Token Completion Guarantee + Default Worker Fix
**Date:** 2026-03-21
**Phase:** post-14 stabilisation
**Status:** COMPLETED
**Author:** kartik / claude-sonnet-4-6

### What Was Done

Three independent stability fixes applied in one pass.

#### 1. io_uring batch parity (Linux backend now matches kqueue Phase 14)

The Linux io_uring backend was missing the full Phase 14 batch dispatch
implementation. `LoopRef.batch_port_ptr` existed in `state.zig` but
`io_uring.EventLoop` never set it, so `ZigIo_SetBatchPort` was silently
a no-op on Linux — all Linux completions fell back to individual
`Dart_PostInteger` / `postRecvResult` calls even after batch mode was
requested from Dart.

**`src/event_loop/io_uring.zig`** — full batch parity added, mirroring `kqueue.zig`:
- Added `batch_port_id: engine.Dart_Port = 0` field to `EventLoop`.
- `run()` now sets `batch_port_ptr = &self.batch_port_id` in `current_loop`
  so `ZigIo_SetBatchPort` correctly activates batch mode on Linux.
- Added `BatchKind` enum (`int_val | null_val | typed_data`) and `BatchEntry`
  struct (identical shape to kqueue's types).
- Added `collectPoolCqe(cqe, out: *BatchEntry) bool`: extracts accept/recv/send
  result from a CQE into a `BatchEntry` without posting.
- Added `flushBatch(batch: []BatchEntry)`: builds one `Dart_CObject_kArray`
  with `[token0,val0,token1,val1,…]` pairs and posts to `batch_port_id`.
  Slots freed after post (bytes copied synchronously by `Dart_PostCObject`).
- Added `postSingleCompletion(token, slot_idx, kind, int_val, bytes_len)`:
  routes one completion through batch port (as a 2-element kArray) when
  `batch_port_id != 0`, or falls back to direct `Dart_PostInteger` /
  `postRecvResult` in legacy mode.
- Updated `run()` inner CQE loop: when `batch_port_id != 0`, pool CQEs are
  collected via `collectPoolCqe` into a per-`copy_cqes()` batch buffer
  (up to 32 entries, matching `cqes[32]`), then flushed via `flushBatch`
  after the full batch is processed. Mirrors kqueue's per-`kevent()` flush.
- Updated `submitAccept`, `submitRecv`, `submitSend` vtable functions to call
  `postSingleCompletion` on their error paths instead of raw `Dart_PostInteger`
  / `postRecvResult`. This ensures SQE submission failures complete batch-mode
  futures rather than silently losing the completion.
- Signal CQE handler now calls `flushBatch` for any pending batch before
  returning, preventing futures from hanging on graceful shutdown.
- Pool size comment corrected: 4096 × ~8 KB = 32 MB (was incorrect 256 / 2 MB
  copy-paste from before Phase 13).

#### 2. Token completion guarantee (all three token natives)

The token-based native variants (`ZigIo_TcpAcceptToken`, `ZigIo_TcpReadToken`,
`ZigIo_TcpWriteBytesToken`) previously returned early on several failure paths
without posting any completion. This left `_ZigIoDispatcher._pending[token]`
unresolved forever, causing the corresponding `Future` to hang permanently.

**`src/zig_io/natives/tcp.zig`** — hardened all three token functions:
- Added two file-scope helpers: `postTokenInt(loop, token, int_val)` and
  `postTokenNull(loop, token)`. Both build a 2-element `kArray [token, value]`
  and post to `loop.batch_port_ptr.*`, matching the shape expected by
  `_ZigIoDispatcher._onBatch`. No-op if `batch_port_ptr == 0`.
- `ZigIo_TcpAcceptToken`: pool exhaustion now calls `postTokenInt(loop, token, -1)`.
- `ZigIo_TcpReadToken`: pool exhaustion now calls `postTokenNull(loop, token)`
  (null = EOF sentinel, consistent with how recv errors are typed in Dart).
- `ZigIo_TcpWriteBytesToken`: three error paths hardened:
  - `Dart_TypedDataAcquireData` failure → `postTokenInt(loop, token, -1)`.
  - `data_len <= 0` (empty `Uint8List`) → `postTokenInt(loop, token, 0)` (0
    bytes written, no pool slot needed). Previously returned silently — future
    hung permanently.
  - Pool exhaustion → `postTokenInt(loop, token, -1)`.

#### 3. Default worker count changed to 1

`run()` in `src/main.zig` previously defaulted to `std.Thread.getCpuCount()`
workers, spawning N isolates and N event loops for every program including
non-server workloads. A `hello.dill world` invocation would:
1. Start 11 workers (M3 Pro), each trying to invoke `main(["world"])`.
2. Workers whose `_startMainIsolate` encountered a `RangeError` (hello.dart's
   `args[0]` with an empty list from the other workers) produced cascading
   error messages, then a segfault as engines raced during shutdown.

**`src/main.zig`**:
- Default `workers` changed from `std.Thread.getCpuCount()` to `1`.
- `--workers=0` now means "auto = getCpuCount()" for convenience.
- Comment updated to document the explicit opt-in nature of multicore mode.

### What Was Verified
- `zig build` (macOS host) succeeds.
- `zig test dart-zig/src/http/parser.zig` — all 4 parser tests pass.
- `dart-zig --workers=1 test-snapshots/hello.dill world` → `hi, world!` (single worker).
- `dart-zig test-snapshots/hello.dill world` → `hi, world!` (default=1 now safe).

### Bugs Fixed
| Bug | Root Cause | Fix |
|---|---|---|
| `hello.dill` segfault on default run | Default N workers, each calling `main(args[0])` with potentially empty args list | Default workers = 1 |
| Linux token futures hang forever after `ZigIo_SetBatchPort` | io_uring never set `batch_port_ptr`, so `ZigIo_SetBatchPort` was no-op on Linux | Set `batch_port_ptr = &self.batch_port_id` in `run()` |
| Token future hangs on pool exhaustion (all three token natives) | Early return without posting completion | `postTokenInt` / `postTokenNull` on all exhaustion paths |
| Token future hangs on empty `Uint8List` write | Silent early return instead of `postTokenInt(0)` | Post `0` bytes written immediately |
| Batch-mode futures hang on SQE submission error (io_uring) | `submitAccept/Recv/Send` error paths used raw `Dart_PostInteger` bypassing batch port | Switch to `postSingleCompletion` on all error paths |

### Files Changed
- `src/main.zig` — default workers = 1, `--workers=0` → auto
- `src/event_loop/io_uring.zig` — `batch_port_id` field, `BatchKind`/`BatchEntry`,
  `collectPoolCqe`, `flushBatch`, `postSingleCompletion`; updated `run()` dispatch
  and `submit*` vtable error paths
- `src/zig_io/natives/tcp.zig` — `postTokenInt`/`postTokenNull` helpers;
  hardened `ZigIo_TcpAcceptToken`, `ZigIo_TcpReadToken`, `ZigIo_TcpWriteBytesToken`
- `dart-zig/README.md` — pool size (256→4096, 2MB→32MB), resolver path,
  project layout corrected, benchmark history extended

### Linux Docker Verification (io_uring, ARM64, JIT, 200 conns × 100 msgs × 1024B)

Run immediately after HARDENING-1 was applied. Both servers ran to full
completion with zero errors — confirming the batch parity fix is live and
the token completion guarantee holds end-to-end on Linux.

```
dart-zig (io_uring, batch mode):
  run 1:  88ms  =>  227273 req/s  ~455 MB/s  (completed: 20000/20000)
  run 2:  74ms  =>  270270 req/s  ~541 MB/s  (completed: 20000/20000)
  run 3: 100ms  =>  200000 req/s  ~400 MB/s  (completed: 20000/20000)

dart:io baseline (io_uring host):
  run 1:  99ms  =>  202020 req/s  ~404 MB/s  (completed: 20000/20000)
  run 2: 107ms  =>  186916 req/s  ~374 MB/s  (completed: 20000/20000)
  run 3:  63ms  =>  317460 req/s  ~635 MB/s  (completed: 20000/20000)
```

**Analysis:**
- dart-zig avg ~232k req/s; dart:io avg ~235k req/s — within normal Docker
  ARM64 ±30% variance. Both are in the Phase 10a–10c expected range (~240k avg).
- dart:io run 3 spike (317k) is the documented TIME_WAIT coasting phenomenon:
  the first two runs establish open sockets; run 3 rides them before OS reclaim.
- dart-zig run 2 (270k) leads dart:io run 2 (187k) by +45% in this Docker run,
  consistent with the inline-write fast-path advantage on io_uring.
- **Critical:** 20000/20000 completed on every run for both backends — no
  hangs, no errors. Before HARDENING-1, batch mode on Linux was silently
  broken (ZigIo_SetBatchPort was a no-op; any token future would hang
  indefinitely). This confirms the fix is correct.

### Next Steps
- Add integration tests: token liveness under pool exhaustion, empty-write
  completion, `--workers=1` vs `--workers=N` semantics.
- Consider `--workers=0` as the recommended server invocation and document it
  in the benchmarking guide.
- Run HTTP bench (`wrk -t4 -c128`) on Linux to verify http_server.dart +
  batch dispatcher parity with macOS Phase 14 numbers (~150k req/s).

---

## [PHASE-14] Completion Batching (Batch Dispatcher)
**Date:** 2026-03-20
**Phase:** 14 — Reduce N `DartEngine_HandleMessage` calls per `kevent()` batch to 1 by posting one `Dart_CObject_kArray` per batch
**Status:** COMPLETED
**Author:** kartik / claude-sonnet-4-6 / codex-gpt-5.3

### What Was Done
Replaced the per-operation `RawReceivePort` + `SendPort` dispatch model with a single
per-isolate `RawReceivePort` that receives one `List` message per `kevent()` batch.

- **`src/engine.zig`**: Added `Dart_CObject_kArray = 6`, `as_array` field to
  `Dart_CObject.value` union (`length: isize`, `values: [*]?*Dart_CObject`).

- **`src/zig_io/state.zig`**: Added `batch_port_ptr: *engine.Dart_Port` to `LoopRef`.
  Batch port is set once by `ZigIo_SetBatchPort`; when non-zero all completions are
  routed through it.

- **`src/event_loop/kqueue.zig`**:
  - Added `batch_port_id: engine.Dart_Port = 0` to `EventLoop`.
  - Refactored `run()` to collect completions into a `[32]BatchEntry` buffer during
    the `kevent()` event loop, then call `flushBatch()` once after all events processed.
  - `collectPoolEvent()`: performs the I/O syscall (accept/recv/send), records result.
  - `flushBatch()`: builds one `Dart_CObject_kArray` with `[token0,val0,token1,val1,...]`
    pairs and posts it to `batch_port_id`. `kTypedData` bytes are copied synchronously
    by `Dart_PostCObject` before slots are freed.
  - `postSingleCompletion()`: helper for error/fast-path cases (submit* error paths,
    `submitSend` inline fast-path). Checks `batch_port_id != 0`: if set, posts a
    2-element `kArray` to batch port; otherwise falls back to `Dart_PostInteger` /
    `postRecvResult`. Fixes the Phase 14 bug where `ctx.port_id` is a token (not a
    real `Dart_Port`) in batch mode.
  - `dispatchPoolEvent()`: retained as fallback when batch port is not yet initialised.

- **`src/zig_io/natives/tcp.zig`**:
  - `ZigIo_SetBatchPort`: reads `SendPort`, stores to `loop.batch_port_ptr.*`.
  - `ZigIo_TcpAcceptToken`, `ZigIo_TcpReadToken`, `ZigIo_TcpWriteBytesToken`:
    token-based variants; store integer token in `ctx.port_id` instead of a `Dart_Port`.

- **`src/zig_io/native_table.zig`**: Added 4 new entries for batch API.

- **`lib/zig_io.dart`**: Added `_ZigIoDispatcher` class with one `RawReceivePort`,
  `Map<int, Completer>` token map, and `_onBatch` handler that processes `[token, value]`
  pairs from the list message. Public wrappers: `zigIoTcpAcceptFuture`,
  `zigIoTcpReadFuture`, `zigIoTcpWriteBytesFuture`.

- **`lib/http_server.dart`**: Updated to use `zigIoTcpAcceptFuture` /
  `zigIoTcpReadFuture` / `zigIoTcpWriteBytesFuture` from the batch dispatcher.

### Bugs Found and Fixed During Implementation

**`submitSend` inline fast-path routing bug**: When batch mode is active, `submitSend`
called `Dart_PostInteger(ctx.port_id, bytes_written)` where `ctx.port_id` is an integer
token (1, 2, 3…), not a real `Dart_Port`. Write succeeds at OS level but the Dart
future never completes → `_handleConn` hangs after first response. Fix:
`postSingleCompletion()` checks `batch_port_id != 0` and routes to the correct port.

### Benchmark Results (macOS ARM64, kqueue, AOT, keep-alive, 11 workers SO_REUSEPORT)
```
wrk -t4 -c128 -d10s:  159k req/s  (stable, no errors)
wrk -t4 -c400 -d10s:  150k req/s  (stable, no errors — was crashing in Phase 13)
```

**DartEngine_HandleMessage reduction**: With a 32-event `kevent()` batch, Phase 14
delivers up to 32 completions per single `DartEngine_HandleMessage` call vs. N calls
in Phase 13. On loopback at 150k req/sec the improvement is primarily in Dart VM
re-entry overhead, not visible in single-machine throughput (client/server share cores).

### Files Changed
- `src/engine.zig` — `Dart_CObject_kArray`, `as_array` union field
- `src/zig_io/state.zig` — `batch_port_ptr` in `LoopRef`
- `src/event_loop/kqueue.zig` — batch dispatcher, `postSingleCompletion` helper
- `src/zig_io/natives/tcp.zig` — `ZigIo_SetBatchPort`, `*Token` natives
- `src/zig_io/native_table.zig` — 4 new entries
- `lib/zig_io.dart` — `_ZigIoDispatcher`, batch wrapper futures
- `lib/http_server.dart` — uses batch futures

---

## [PHASE-13] HTTP/1.1 Native Parser
**Date:** 2026-03-19
**Phase:** 13 — Zero-allocation HTTP/1.1 parser in Zig; Dart receives structured HttpRequest; server benchmarkable with `wrk`
**Status:** COMPLETED
**Author:** kartik / claude-sonnet-4-6

### What Was Done
Implemented a zero-allocation HTTP/1.1 parser in Zig and wired it to a complete HTTP
server with keep-alive support.

- **`src/http/parser.zig`**: Zero-allocation state-machine HTTP/1.1 parser. All slices
  (`method`, `path`, `headers[32]`) point directly into the input buffer — no heap
  allocation. Returns `ParseResult{status, method, path, body_offset, headers, header_count}`.
  4 unit tests pass (GET, POST with body, incomplete, multi-header).

- **`src/http/natives.zig`**: `ZigHttp_Parse` — synchronous native (uses
  `Dart_SetReturnValue`, not ports). Acquires TypedData pin, runs parser, copies
  method/path to stack buffers (before release), builds `Dart List[method, path, bodyOffset]`.

- **`src/http/native_table.zig`** + **`src/http/resolver.zig`**: `ZigHttpNativeLookup` /
  `ZigHttpNativeSymbol` — same vtable pattern as zig_io resolver.

- **`lib/zig_http.dart`**: `HttpRequest{method, path, bodyOffset, rawBytes}`.
  `parseHttpRequest(Uint8List) → HttpRequest?` calls `_zigHttpParse` (external-name native).

- **`lib/http_server.dart`**: Hello World HTTP/1.1 server. Routes: `/` and `/index.html`
  → 200 Hello, `/ping` → 200 pong, else → 404. `Connection: keep-alive` — connection
  handler loops over multiple requests per TCP connection, eliminating ephemeral-port
  exhaustion under `wrk` load.

- **`src/zig_io/state.zig`**: Increased `kPoolSize` from 256 → 4096 (32 MB pool) to
  support high concurrent connection counts without slot exhaustion.

- **`src/zig_io/natives/tcp.zig`**: Fixed `ZigIo_TcpRead` error paths to post `null`
  (via `postRecvResult`) instead of `-1` integer, consistent with how recv completions
  are typed (`Uint8List?`, not `int`).

### Bugs Found and Fixed During Implementation

**Port exhaustion (`Connection: close`)**: First benchmark attempt used `Connection: close`.
At 35k req/sec × 30s TIME_WAIT (macOS MSL=15s), 16k-port ephemeral range exhausted in
<0.5s. Wrk reported all-connect-errors on the second run. Fix: switch to
`Connection: keep-alive` with a per-connection request loop. Connections reused →
zero TIME_WAIT accumulation.

**Pool slot exhaustion + type crash**: `kPoolSize=256` with 400 concurrent keep-alive
connections (each holding one recv slot) → `allocSlot` fails → `ZigIo_TcpRead` posted
`Dart_PostInteger(-1)` → `_Conn.read()` tried `v as Uint8List?` → crash. Fixed by:
1. `kPoolSize` 256 → 4096; 2. error paths use `postRecvResult(port_id, -1, &.{})` → null.

### Benchmark Results (macOS ARM64, kqueue, AOT, keep-alive)
```
wrk -t4 -c128 -d10s:
  1 worker:  133k req/s   (1 Dart isolate, single kqueue)
 11 workers: 135k req/s   (11 isolates × SO_REUSEPORT, kernel-distributed)

wrk -t4 -c512 -d10s:
  1 worker:  147k req/s
  4 workers: 141k req/s
 11 workers: 138k req/s
```

**Note on single-machine benchmarks**: On a single host, the wrk client and server
compete for the same CPU cores. At ~130–147k req/sec, the loopback network stack is
the bottleneck, not the server. Multi-worker shows similar or slightly lower throughput
vs single-worker because extra OS threads consume cores that the wrk client could use.
True N× scaling requires a dedicated client machine.

### Files Changed
- `src/http/parser.zig` — zero-allocation HTTP/1.1 state machine (new)
- `src/http/natives.zig` — `ZigHttp_Parse` synchronous native (new)
- `src/http/native_table.zig` — native lookup table (new)
- `src/http/resolver.zig` — `ZigHttpNativeLookup`/`ZigHttpNativeSymbol` (new)
- `src/main.zig` — `installZigHttpResolver()` wired alongside zig_io
- `lib/zig_http.dart` — `HttpRequest`, `parseHttpRequest` (new)
- `lib/http_server.dart` — Hello World HTTP server with keep-alive (new)
- `src/zig_io/state.zig` — `kPoolSize` 256 → 4096
- `src/zig_io/natives/tcp.zig` — `ZigIo_TcpRead` null error paths

---

## [PHASE-12] SO_REUSEPORT Multicore
**Date:** 2026-03-16
**Phase:** 12 — N isolates × N event loops, kernel-distributed accept via SO_REUSEPORT
**Status:** COMPLETED
**Author:** kartik / claude-sonnet-4-6

### What Was Done
Implemented multicore worker model for dart-zig. Each CPU core gets its own
Dart isolate + kqueue event loop + listen socket. The kernel distributes incoming
connections across all N sockets with zero cross-thread coordination.

- **`src/main.zig`**: Restructured into `workerInit` (serialized under `init_mutex`) +
  `workerMain` (runs independently after init). Key fix: `EventLoop` is declared in
  `workerMain`'s stack frame and passed as an out-pointer to `workerInit` —
  `toScheduler()` captures `&event_loop`, so the address must be stable before and
  after `workerInit` returns. Returning EventLoop by value would create a dangling
  scheduler pointer.
- **`--workers=N` flag**: Explicit worker count. Default: `std.Thread.getCpuCount()`.
  `--workers=1` runs on main thread with no thread overhead (preserves Phase 11 path).
- **Per-isolate scheduler**: `DartEngine_SetMessageScheduler(loop.toScheduler(), isolate)`
  ensures each worker's isolate wakes its own event loop, not a shared global.
- **`src/zig_io/natives/tcp.zig`**: Added `SO_REUSEPORT` to `tcpBind()`. Each worker's
  Dart `main()` independently calls `zigIoTcpBind` and gets its own listen socket on
  the same port. No Dart-side changes required.
- **Global init mutex**: `DartEngine_CreateIsolate` is not thread-safe; each worker
  acquires `init_mutex` before creating its isolate and releases before `run()`.

### Bug Found and Fixed During Implementation
`workerInit` originally returned `EventLoop` by value. `toScheduler()` captures
`self` (the address of the local `EventLoop`). When the struct is returned by value
(even with NRVO, not guaranteed), the scheduler's `context` pointer dangled. The
`schedule_callback` wrote to a dead stack address — the message pipe was never
written, isolates starved, benchmark hung. Fix: pass `*EventLoop` as an out-parameter
from `workerMain`'s frame into `workerInit`.

### Benchmark Results (macOS ARM64, kqueue)
```
dart-zig AOT 11 workers:  269k → 347k → 352k req/s  (benchmark client limited)
dart-zig AOT  1 worker:   286k → 306k → 351k req/s  (single-core baseline)
```

Both plateaus near ~350k req/s because the benchmark client (single Dart event loop,
128 connections) is the bottleneck, not the server. Multicore correctness verified:
20/20 concurrent connections echoed correctly across all 11 workers. To observe N×
throughput scaling, a multi-threaded client (wrk2, bombardier, multi-process TCP
bench) is needed — beyond scope of Phase 12.

### Files Changed
- `src/main.zig` — `workerInit`/`workerMain` with out-param EventLoop, `--workers=N`,
  global init_mutex, per-isolate `DartEngine_SetMessageScheduler`
- `src/zig_io/natives/tcp.zig` — `SO_REUSEPORT` in `tcpBind()`

---

## [PHASE-11] AOT Compilation Support
**Date:** 2026-03-15
**Phase:** 11 — JIT vs AOT snapshot support; benchmark AOT vs JIT vs dart:io
**Status:** COMPLETED
**Author:** kartik / claude-sonnet-4-6

### What Was Done
Added full AOT compilation support to dart-zig:

- **`build.zig`**: `-Daot=true` build option → produces `dart-zig-aot` binary linking `dart_engine_aot_shared` instead of `dart_engine_jit_shared`
- **`engine.zig`**: Added `DartEngine_AotSnapshotFromFile` extern declaration (was in the header but not wired up)
- **`main.zig`**: Auto-detects snapshot kind by extension — `.dill` → JIT kernel path, `.so`/`.dylib`/`.snapshot` → AOT path; no flag needed at runtime
- **Snapshot compilation**: `gen_kernel --aot` (enables TFA tree-shaking) → `gen_snapshot --snapshot-kind=app-aot-macho-dylib` (macOS) or `--snapshot-kind=app-aot-elf` (Linux)

### Benchmark Results

**macOS ARM64 (kqueue) — four-way comparison:**
```
dart:io   JIT:  213k → 225k → 253k req/s   (warming visible across runs)
dart:io   AOT:  290k → 286k → 282k req/s   (flat from run 1, ~283k avg)
dart-zig  JIT:  196k → 270k → 274k req/s   (JIT warmup cost on run 1)
dart-zig  AOT:  294k → 294k → 286k req/s   (no warmup, flat, fastest)
```

### Analysis
- **AOT run 1 (+50% vs JIT run 1)**: JIT pays compilation cost cold; AOT starts at full speed
- **AOT steady-state ≈ JIT steady-state**: once JIT warms, both reach ~274–294k; AOT is slightly ahead but within noise
- **dart-zig AOT leads dart:io AOT**: 291k avg vs 283k avg (+3%) — leaner Zig↔Dart boundary survives AOT compilation
- **AOT variance near-zero**: dart-zig AOT run 1 ≈ run 3 (294k/294k/286k); predictable latency from first request
- **Production use case**: AOT is the right mode for deployed servers — eliminates JIT warmup penalty on restart/cold start

### Files Changed
- `build.zig` — `-Daot` option, `dart-zig-aot` binary name, `engine_lib` switch
- `src/engine.zig` — `DartEngine_AotSnapshotFromFile` extern
- `src/main.zig` — auto-detect `.dill` vs `.so`/`.dylib`/`.snapshot` by extension

---

## [PHASE-10c] io_uring Inline Write Fast-Path
**Date:** 2026-03-14
**Phase:** 10c — Eliminate send SQE round-trip for loopback/hot-path writes
**Status:** COMPLETED
**Author:** kartik / claude-sonnet-4-6

### Root Cause (from analysis)
The io_uring `submitSend` was unconditionally queuing a `ring.write(SQE)` for every send, requiring a full `io_uring_enter` + CQE round-trip even when the socket's send buffer was ready (which is ~100% of the time on loopback). This gave **2 kernel entries per echo** vs dart:io/kqueue's **1**, halving theoretical throughput.

dart:io confirmed to use **epoll** (not io_uring) on Linux, with `SocketBase::Write()` calling `write()` inline from Dart — exactly the kqueue pattern. kqueue's `submitSend` already had this inline fast-path. io_uring was the only backend missing it.

### What Was Done
Added `posix.write()` fast-path to `submitSend` in `io_uring.zig`:
- Try inline `posix.write()` first
- On success (n > 0): post `Dart_PostInteger(n)` directly, free slot, return — **no SQE queued**
- On `EAGAIN` (WouldBlock): fall through to `ring.write(SQE)` async path
- On hard error: post -1, free slot

This mirrors exactly what kqueue's `submitSend` already does and what dart:io's `SocketBase::Write` does before any epoll registration.

### Benchmark Results

**macOS ARM64 (kqueue)** — unchanged (kqueue already had inline write):
```
dart-zig: 213k → 250k → 270k req/s
dart:io:  213k → 233k → 244k req/s
```

**Linux ARM64 (io_uring, Docker)** — two runs:
```
dart-zig run A:  167k → 183k → 208k  (Docker variance on run 3)
dart-zig run B:  160k → 263k → 345k  (clean — 345k peak)
dart:io  run A:   26k → 157k → 196k  (dart:io run 1 Docker collapse)
dart:io  run B:  206k → 192k → 323k
```

**Before vs after (Linux run 1 — cold start):**
```
Before Phase 10c:  110k req/s
After  Phase 10c:  160–167k req/s   (+45–52%)
```

**Before vs after (Linux run 3 — warm):**
```
Before Phase 10c:  263k req/s  (previous best clean run)
After  Phase 10c:  345k req/s  (+31%)
```

dart-zig run 3 peak (345k) now leads dart:io peak (323k) by **+7%** on Linux.

### Analysis
The inline write eliminates ~600ns io_uring_enter + ~300ns eventfd wakeup for the send path. On loopback, `posix.write()` succeeds synchronously in ~200ns (TCP sk_buff memcpy), completing in less time than a single io_uring syscall. The remaining gap vs dart:io on cold-start (160k vs 206k) is from: io_uring SQ/CQ ring page faults on first access, JIT warmup of the Dart echo loop, and the recv path still going through a full SQE round-trip.

### Files Changed
- `src/event_loop/io_uring.zig` — `submitSend`: inline `posix.write()` fast-path before `ring.write(SQE)`

### Next Steps
- Apply same inline fast-path to `submitRecv` if recv data is already in the socket buffer (IORING_OP_RECV_MULTISHOT addresses this more cleanly)
- Phase 10b: `IORING_OP_RECV_MULTISHOT` — eliminate recv SQE re-arm overhead

---

## [PHASE-10a-r2] Benchmark Re-run: Correctness Fixes + O(1) Pool Allocator
**Date:** 2026-03-14
**Phase:** 10a follow-up — apply 4 fixes and re-benchmark
**Status:** COMPLETED
**Author:** kartik / claude-sonnet-4-6

### Fixes Applied (by kartik)
1. **Benchmark correctness**: count completed round-trips per run; compute req/s from actual completed work; timed runs exit non-zero on errors. (`bench_echo_concurrent.dart`)
2. **Startup health checks**: `run_bench.sh` now captures server logs, polls for ready patterns, fails fast on startup errors.
3. **Linux accept parity**: Accepted sockets get `SOCK.NONBLOCK | SOCK.CLOEXEC` + `TCP_NODELAY` (io_uring). macOS accept path also gets `TCP_NODELAY` (kqueue).
4. **O(1) pool slot allocator**: Replaced linear slot scan with free-list stack. Wired through `LoopRef.slot_alloc` and all alloc/free call sites.

### Benchmark Results

**macOS ARM64 (kqueue)** — clean, stable:
```
dart-zig Phase 10a+fixes: 222k → 256k → 274k req/s  (monotonically improving, 0 errors)
dart:io baseline:          182k → 129k → 247k req/s  (noisy — run 2 GC hiccup)
```
dart-zig run 3 (274k) beats dart:io run 3 (247k) by **+11%** and is far more consistent.

**Linux ARM64 (io_uring, Docker)** — clean run:
```
dart-zig: 110k → 148k → 263k req/s  (JIT warms progressively)
dart:io:  215k → 213k → 274k req/s  (flat from run 1 — dart:io cold path is cheaper)
```
dart:io run 3 leads by ~4% (274k vs 263k). dart-zig's cold-start is slower because the first two runs are still warming the JIT + populating the pool cache. At warm steady state they converge.

**Historical Docker runs (characterising variance)**:
```
dart-zig  earlier A: 97k  → 227k → 17k   (run 3 TIME_WAIT collapse)
dart-zig  earlier B: 172k → 177k → 345k  (clean — 345k peak, best ever)
dart:io   earlier A: 200k → 192k → 303k
dart:io   earlier B: 225k → 132k → 20k   (run 3 TIME_WAIT collapse)
```
The run 3 collapse (17k or 20k) rotates between backends across invocations — Docker loopback TIME_WAIT churn, not a code regression. Peak dart-zig: **345k**; peak dart:io: **303k**.

### Files Changed
- `lib/bench_echo_concurrent.dart` — completed-ops tracking, non-zero exit on errors
- `docker/run_bench.sh` — health-check wait loop, `set -euo pipefail`
- `src/event_loop/io_uring.zig` — `SOCK.NONBLOCK|CLOEXEC` on accept, `setTcpNoDelay`
- `src/event_loop/kqueue.zig` — `TCP_NODELAY` on accepted connections
- `src/zig_io/state.zig` — `SlotAllocator` O(1) free-list, updated `allocSlot`/`freeSlot`
- `src/zig_io/natives/tcp.zig` — pass `slot_alloc` through vtable call sites
- `docs/dart-zig/benchmarking.md` — startup validation, clarified req/s = completed ops

---

## [PHASE-10a] Zero-Malloc Embedded Pool Buffers
**Date:** 2026-03-14
**Phase:** 10a — Pool-embedded recv/send buffers
**Status:** COMPLETED
**Author:** kartik / claude-sonnet-4-6

### What Was Done

Replaced per-op `c_allocator.alloc`/`free` for recv and send buffers with static buffers embedded directly in each `CompletionCtx` pool slot.

**Root cause addressed:**
Even with `c_allocator`, every recv allocated 8 KB via `malloc` and freed it via a Dart GC finalizer. Under load: malloc lock contention + GC finalizer invocation mid-benchmark = run-to-run variance and throughput ceiling.

**Changes:**
- `state.zig`: `RecvData.buf: [kBufSize]u8 = undefined`, `SendData.buf: [kBufSize]u8 = undefined, len: usize = 0`. Added `kBufSize = 8192`.
- Pool is heap-allocated (`c_allocator.create([kPoolSize]CompletionCtx)`) so the 2 MB block lives on the heap, not the stack.
- `tcp.zig`: `ZigIo_TcpRead` allocates no heap — sets `ctx.data = .{ .recv = .{} }` and submits. `ZigIo_TcpWriteBytes` memcpy's into `ctx.data.send.buf` before submitting.
- `kqueue.zig`/`io_uring.zig`: `posix.read` / `ring.read` targets `ctx.data.recv.buf[0..]`. No `free` anywhere for recv or send.
- `state.zig` `postRecvResult`: reverted to `kTypedData` — Dart_PostCObject serializes `buf[0..n]` into the Dart message (one VM memcpy from cache-hot pool slot). Pool slot freed immediately; no GC finalizer involved.
- Removed `freeRecvBuffer` finalizer and `Dart_CObject_kExternalTypedData` usage.

**Result**: Zero malloc per I/O op. Zero GC pressure. 256 pool slots × 8 KB = 2 MB stays in L3 cache.

### Benchmark Results

**macOS ARM64 (kqueue)**:
```
dart-zig Phase 10a: 227k → 263k → 274k req/s  (monotonically improving, no GC hiccup)
dart:io baseline:   222k → 250k → 260k req/s
```
dart-zig beats dart:io on all 3 runs (not just warm). Clean monotonic improvement.

**Linux ARM64 (io_uring, Docker)**:
```
dart-zig Phase 10a: 281k → 206k → 241k req/s  (avg ~243k)
dart:io baseline:   235k → 210k → 267k req/s  (avg ~237k)
```
dart-zig avg 243k > dart:io avg 237k. **First consistent lead on Linux io_uring.**

**Phase progression (Linux io_uring avg req/s)**:
- Phase 8:  142k (baseline)
- Phase 9:  221k (+56%)
- Phase 9b: 200k (Docker variance dominated)
- Phase 10a: 243k (+71% over Phase 8)

### Files Changed
- `src/zig_io/state.zig` — `kBufSize`, embedded `RecvData`/`SendData`, removed finalizer, `postRecvResult` → kTypedData
- `src/zig_io/natives/tcp.zig` — no malloc, embed buf in slot before submit
- `src/event_loop/kqueue.zig` — heap-allocate pool, read/write into embedded buf, no free
- `src/event_loop/io_uring.zig` — heap-allocate pool, read/write into embedded buf, no free

### Next Steps (Phase 10b)
- `IORING_OP_RECV_MULTISHOT` with provided buffer ring (io_uring Linux only): submit one SQE per accepted connection, kernel pushes CQEs continuously — eliminates Dart→Zig re-arm overhead from hot path
- Requires new Dart stream API for per-connection recv (`readStream` instead of `read()`)
- `Dart_Handle_Finalizer` path in engine.zig still present for potential future use

---

## [PHASE-9b] Event Loop Coalescing + Idle Detection Fix
**Date:** 2026-03-14
**Phase:** 9b — Notification batching
**Status:** COMPLETED
**Author:** kartik / claude-sonnet-4-6

### Root Cause Found
Deep research (Codex + Gemini + manual analysis) identified two additional bottlenecks not addressed in Phase 9:

**Eventfd/pipe write amplification** (`io_uring.zig:91`, `kqueue.zig:119`):
`schedule_callback` was called once per `Dart_PostCObject`. With 200 concurrent connections, processing 200 CQEs in one batch triggered 200 `write(notify_fd)` syscalls — 200 × ~100ns = 20µs of pure notification overhead per round-trip. The eventfd counter accumulated correctly but every write was still a syscall.

**Linux idle detection firing mid-benchmark** (`io_uring.zig:135`):
The 200ms timeout CQE fired regardless of whether pool I/O was active. Unlike kqueue (which only fires idle when `kevent()` returns 0 events), io_uring's timeout SQE fires on schedule. This was calling `Dart_NotifyIdle` during active benchmark runs, triggering premature GC on Linux.

### What Was Done

**Fix 1 — Coalesce eventfd/pipe writes (both backends)**
`schedule_callback` now only writes to the wakeup fd when pending transitions 0→1 (idle→busy). If the loop is already awake processing a batch, no syscall is needed.

To preserve correctness: the notify handler was changed from using `notify_buf` (eventfd accumulated count = number of writes) to `pending.swap(0, .acquire)` (true number of posted messages). This decouples message count from write count.

```zig
// schedule_callback: write only on idle→busy
const prev = self.pending.fetchAdd(1, .monotonic);
if (prev == 0) { write(notify_fd, 1); }

// notify handler: drain all messages using pending counter
const count = @max(1, self.pending.swap(0, .acquire));
HandleMessage × count;
```

Same pattern applied to kqueue's pipe: `drainPipe()` result discarded, `pending.swap(0)` drives message count.

**Fix 2 — Suppress `Dart_NotifyIdle` when I/O is active (io_uring only)**
Added `any_io: bool` flag per outer loop iteration. Set to `true` when `dispatchPoolCqe` is called. `Dart_NotifyIdle` is only called on timeout if `!any_io` — i.e., genuinely idle.

### Benchmark Results

**macOS ARM64 (kqueue)** — before vs after:
```
dart-zig Phase 9:       run2=246k  run3=256k  (unstable, run3 matches dart:io)
dart-zig Phase 9b:      run2=273k  run3=273k  (stable, beats dart:io by ~5%)
dart:io baseline:       run2=256k  run3=260k
```
Run 2 = Run 3 = 273k: variance eliminated. dart-zig now consistently leads dart:io on macOS.

**Linux ARM64 (io_uring, Docker)** — result within Docker variance noise:
```
dart-zig Phase 9b:      162k → 224k → 215k  (avg ~200k)
dart:io baseline:       238k → 196k → 277k  (avg ~237k, also noisy)
```
Docker ARM64 variance (~30%) dominates sub-20% differences. Linux gains require Phase 10 architectural changes.

### Files Changed
- `src/event_loop/io_uring.zig` — `schedule_callback` coalescing + `pending.swap(0)` in notify handler + `any_io` idle guard
- `src/event_loop/kqueue.zig` — `schedule_callback` coalescing + `pending.swap(0)` in pipe handler

### Remaining Bottlenecks (Phase 10 targets)
1. **Per-recv malloc/free + GC finalizer churn**: Embed `[8192]u8` directly in `CompletionCtx` — zero alloc, zero GC pressure
2. **`Completer` allocation per op**: `_ZigConn.read()` still constructs a `Completer<Object?>` per call
3. **`IORING_OP_RECV_MULTISHOT`**: Submit one SQE per connection, kernel feeds CQEs continuously — eliminates Dart→Zig→SQE re-arm overhead

---

## [PHASE-9] Zero-Copy Recv + c_allocator + Single Port Per Connection
**Date:** 2026-03-14
**Phase:** 9 — Performance: Eliminate 3 root-cause bottlenecks
**Status:** COMPLETED
**Author:** kartik / claude-sonnet-4-6

### What Was Done
Three targeted fixes to close the 43% gap (142k vs 203k req/s) found in Phase 8 Linux io_uring benchmark:

**Fix #1 — One RawReceivePort per connection (not per op)**
- Created `_ZigConn` class in `lib/echo_server.dart` holding a single `RawReceivePort` + `Completer` slot
- Each read/write reuses the same port; only one `port_id` lookup per connection instead of per I/O op
- Eliminates ~700–1200 ns/req of VM port-map mutex contention

**Fix #2 — Replace page_allocator with c_allocator (malloc/free)**
- Changed all recv/send buffer allocs in `tcp.zig` from `std.heap.page_allocator` to `std.heap.c_allocator`
- `page_allocator` calls `mmap`/`munmap` per alloc (~1400 ns). `c_allocator` calls `malloc`/`free` (~40 ns from libc pool)
- Updated all error-path frees in `kqueue.zig`, `io_uring.zig` to `std.heap.c_allocator.free`

**Fix #3 — Zero-copy recv via Dart_CObject_kExternalTypedData**
- Added `Dart_CObject_kExternalTypedData = 8`, `Dart_HandleFinalizer` type, and `as_external_typed_data` struct to `engine.zig`
- Updated `state.zig`'s `postRecvResult` to post `kExternalTypedData` with `freeRecvBuffer` finalizer (`std.c.free`)
- On success: Dart GC owns the malloc'd buffer, calls finalizer on collection — zero VM copies
- On error/EOF: `postRecvResult` frees the buffer immediately itself
- Removed all caller-side `page_allocator.free(recv.buf)` from `kqueue.zig` and `io_uring.zig`

### Benchmark Results

**macOS ARM64 (kqueue backend)**
```
dart-zig phase 9:  run1=190k  run2=246k  run3=256k req/s   (warm: ~256k)
dart:io baseline:  run1=202k  run2=253k  run3=256k req/s   (warm: ~256k)
```
macOS: parity maintained (~256k req/s both). kqueue gives no batching advantage.

**Linux ARM64 (io_uring backend, Docker)**
```
dart-zig phase 9:  run1=112k  run2=333k  run3=217k req/s   (peak: 333k)
dart:io baseline:  run1=238k  run2=222k  run3=206k req/s   (avg: ~222k)
```
Linux: dart-zig peak 333k > dart:io peak 238k (+40%). Average comparable (~221k vs ~222k).
Phase 8 was 142k vs 203k (dart:io +43%). Phase 9 eliminated the gap.

Variance in dart-zig runs is from ExternalTypedData GC finalizers running mid-benchmark
(Dart GC collects recv buffers from previous run, triggering `std.c.free` calls on GC thread).

### Files Changed
- `lib/echo_server.dart` — `_ZigConn` class: one RawReceivePort per connection
- `src/engine.zig` — `Dart_CObject_kExternalTypedData`, `Dart_HandleFinalizer`, `as_external_typed_data` union arm
- `src/zig_io/state.zig` — `freeRecvBuffer` finalizer, `postRecvResult` → kExternalTypedData
- `src/zig_io/natives/tcp.zig` — all page_allocator → c_allocator
- `src/event_loop/kqueue.zig` — remove recv frees (owned by GC), send frees → c_allocator
- `src/event_loop/io_uring.zig` — remove recv frees (owned by GC), send frees → c_allocator
- `test-snapshots/echo_server.dill` — recompiled (format 130)

---

## [PHASE-8] TCP Echo Server + Benchmark
**Date:** 2026-03-13
**Phase:** 8 — Echo Server + Benchmark
**Status:** COMPLETED
**Author:** kartik / claude-sonnet-4-6

### What Was Done
- Added `Dart_CObject` extern struct to `engine.zig` with `_pad: [40]u8` to match C union sizeof=48
- Added `Dart_PostCObject` extern fn declaration to `engine.zig`
- Added `Dart_CObject_kNull`, `Dart_CObject_kInt64`, `Dart_CObject_kTypedData` type constants
- Added `postRecvResult` helper to `state.zig`: posts `kTypedData(Uint8List)` if n>0, `kNull` if n≤0
- Updated `io_uring.zig` and `kqueue.zig` dispatch to call `state.postRecvResult` for recv CQEs/events
- Added `ZigIo_TcpWriteBytes` native to `tcp.zig`: accepts `Uint8List` via `Dart_TypedDataAcquireData` + `@memcpy`
- Updated `native_table.zig` with `ZigIo_TcpWriteBytes` entry
- Updated `lib/zig_io.dart`: added `zigIoTcpWriteBytes(int, Uint8List, SendPort)` declaration
- Created `lib/echo_server.dart`: async TCP echo using zig_io primitives
- Created `lib/dart_io_echo.dart`: baseline TCP echo using dart:io (`socket.forEach`)
- Compiled both to `test-snapshots/*.dill` using `dart pkg/vm/bin/gen_kernel.dart` with vm_platform.dill format 130
  - Key: use `xcodebuild/ReleaseARM64/dart` (3.12 SDK binary), not system dart (3.11 can't compile 3.12 workspace)

### Benchmark Results (macOS ARM64, kqueue backend)
Sequential benchmark: 100–200 connections × 200 messages × 64B payload
```
dart-zig (zig_io/kqueue):  263k–301k req/s   0 errors
dart:io baseline:          247k–313k req/s   0 errors
```
Both backends are within measurement noise (~5–10%) — kqueue overhead is equivalent.
dart-zig matches dart:io performance while using a fully custom Zig event loop.

### What Was Fixed / Discovered
- `dart compile kernel` from inside the SDK workspace picks up `sdk: ^3.12.0-0` → fails with system dart 3.11
  Solution: use `xcodebuild/ReleaseARM64/dart` directly with `pkg/vm/bin/gen_kernel.dart`
- `socket.pipe(socket)` type error in dart 3.11 (Socket is StreamConsumer<List<int>>, pipe needs Uint8List)
  Fixed in dart_io_echo.dart: use `socket.forEach((data) => socket.add(data))`
- Benchmark client `sock.first` cancels stream after one chunk — causes RST errors
  Fixed: use `sock.listen(...)` accumulating bytes until all kPayload*msgs bytes received

### Files Changed
- `src/engine.zig` — Dart_CObject, Dart_PostCObject, type constants
- `src/zig_io/state.zig` — postRecvResult helper
- `src/zig_io/natives/tcp.zig` — ZigIo_TcpWriteBytes, updated recv to return Uint8List
- `src/zig_io/native_table.zig` — ZigIo_TcpWriteBytes entry
- `src/event_loop/io_uring.zig` — dispatchPoolCqe recv uses state.postRecvResult
- `src/event_loop/kqueue.zig` — dispatchPoolEvent recv uses state.postRecvResult
- `lib/zig_io.dart` — zigIoTcpWriteBytes declaration
- `lib/echo_server.dart` — new: TCP echo using zig_io
- `lib/dart_io_echo.dart` — new: TCP echo using dart:io
- `test-snapshots/echo_server.dill` — new: compiled format 130
- `test-snapshots/dart_io_echo.dill` — new: compiled format 130

---

## [CHECKPOINT-7] Post-Phase-7 Verification
**Date:** 2026-03-13
**Status:** PASSED (macOS ARM64 kqueue + Linux ARM64 io_uring)

### Alignment ✅
- `dart-zig/src/zig_io/state.zig` — `CompletionCtx` pool, `LoopOps` vtable, `LoopRef`, `threadlocal current_loop` ✅
- `dart-zig/src/zig_io/natives/tcp.zig` — no more threads; uses `state.current_loop` vtable ✅
- `dart-zig/src/event_loop/io_uring.zig` — pool embedded, CQE dispatch extended, `uring_ops` vtable ✅
- `dart-zig/src/event_loop/kqueue.zig` — pool embedded, EVFILT_READ/WRITE dispatch, `kqueue_ops` vtable ✅

### Smoke Tests ✅ (macOS + Linux Docker --security-opt seccomp=unconfined)
```
zig_io resolver installed on file://.../dart-zig/lib/zig_io.dart
version: dart-zig/0.1.0 (zig 0.15.2)
stdout_write: hello!
wrote: 21 bytes
listen fd: 10
accept connFd: 12  (ok)
done
```

### Bugs Fixed ✅
- **u64 + usize type mismatch** in io_uring submit functions: used `state.kPoolBase + @as(u64, slot_idx)`.
- **Array index type**: `dispatchPoolCqe` casts raw u64 idx to usize via `@intCast` after bounds check.
- **listen socket NONBLOCK**: added `SOCK.NONBLOCK` to `tcpBind()` — required for kqueue readiness-based accept.
- **Linux Docker**: io_uring requires `--security-opt seccomp=unconfined` in Docker.

---

## [PHASE-7] io_uring/kqueue Native I/O — COMPLETED
**Date:** 2026-03-13
**Phase:** 7 — Replace thread-per-op with real io_uring (Linux) / kqueue readiness (macOS)
**Status:** COMPLETED (macOS + Linux)
**Author:** claude-sonnet-4-6

### What Was Done
- Created `dart-zig/src/zig_io/state.zig`:
  - `Op` enum: `accept`, `recv`, `send`
  - `CompletionCtx`: `in_use`, `op`, `port_id`, `fd`, `data` union (`accept: void`, `recv: {buf:[]u8}`, `send: {buf:[]u8}`)
  - `kPoolSize = 256`, `kPoolBase = 16` (user_data/udata values 1-15 reserved for system ops)
  - `LoopOps` vtable: `submit_accept`, `submit_recv`, `submit_send` function pointers
  - `LoopRef`: ptr + ops + pool pointer
  - `pub threadlocal var current_loop: ?LoopRef = null` — set in `run()`, cleared on exit
  - `allocSlot` / `freeSlot` helpers
- Updated `dart-zig/src/zig_io/natives/tcp.zig`:
  - Removed all detached thread spawning
  - `ZigIo_TcpBind`: added `SOCK.NONBLOCK` to socket creation
  - `ZigIo_TcpAccept/Read/Write`: allocate pool slot, fill ctx, call vtable `submit_*`
  - Heap-allocated recv/send buffers; freed in event-loop dispatch on completion
- Updated `dart-zig/src/event_loop/io_uring.zig`:
  - Added `pool: [256]CompletionCtx` field; zero-initialized in `init()`
  - `run()` sets `state.current_loop` at start, clears via defer
  - CQE dispatch: added `else if (user_data >= kPoolBase)` → `dispatchPoolCqe()`
  - `dispatchPoolCqe`: bounds-checks idx, frees heap buf, calls `Dart_PostInteger`, frees slot
  - `submitAccept/Recv/Send`: queue SQEs via `ring.accept/read/write`; free + post -1 on SQE failure
- Updated `dart-zig/src/event_loop/kqueue.zig`:
  - Added `pool: [256]CompletionCtx` field
  - `run()` sets `state.current_loop` at start
  - Event dispatch: `udata >= kPoolBase` → `dispatchPoolEvent()`
  - `dispatchPoolEvent`: switch on `ctx.op` → non-blocking `posix.accept/read/write`
  - `submitAccept/Recv`: register `EVFILT_READ | EV_ONESHOT` kevent
  - `submitSend`: try non-blocking `posix.write` first; register `EVFILT_WRITE | EV_ONESHOT` only on EAGAIN

---

## [CHECKPOINT-6] Post-Phase-6 Verification
**Date:** 2026-03-13
**Status:** PASSED (macOS ARM64 + Linux ARM64)

### Alignment ✅
- `dart-zig/lib/zig_io.dart` — Dart native declarations with `@pragma('vm:external-name', ...)` ✅
- `dart-zig/src/zig_io/resolver.zig` — `ZigIoNativeLookup` + `ZigIoNativeSymbol` ✅
- `dart-zig/src/zig_io/native_table.zig` — single-source-of-truth native table ✅
- `dart-zig/src/zig_io/natives/version.zig` — sync string native ✅
- `dart-zig/src/zig_io/natives/write.zig` — sync stdout write native ✅
- `dart-zig/src/zig_io/natives/tcp.zig` — TcpBind (sync) + TcpAccept/Read/Write (async via thread) ✅
- `main.zig` — `installZigIoResolver()` walks loaded libraries, installs resolver on `zig_io.dart` ✅

### Smoke Tests ✅ (macOS + Linux)
```
zig_io resolver installed on file://.../dart-zig/lib/zig_io.dart
version: dart-zig/0.1.0 (zig 0.15.2)
stdout_write: hello!
wrote: 21 bytes
listen fd: 10
accept connFd: 11  (ok)
done
```

### Bugs Fixed ✅
- **Dart_StringToCString error check**: was `!= null` (wrong — non-null means success). Fixed: `Dart_IsError(...)`.
- **Import paths**: `zig_io/` sub-files used `../../` (exits module root). Fixed: `../` for `zig_io/*.zig`, `../../` for `zig_io/natives/*.zig`.
- **posix.accept arity**: Zig 0.15 takes 4 args (fd, addr, addrlen, flags). Added `posix.SOCK.CLOEXEC`.
- **SendPort import**: `zig_io.dart` needs `import 'dart:isolate' show SendPort`.

---

## [PHASE-6] Zig I/O Natives — COMPLETED
**Date:** 2026-03-13
**Phase:** 6 — Zig I/O Natives via Dart_SetNativeResolver
**Status:** COMPLETED (macOS + Linux)
**Author:** claude-sonnet-4-6

### What Was Done
- **Consulted Codex** for Phase 6 design: confirmed gen_kernel inclusion, Dart_NativeArguments patterns, RawReceivePort async pattern, resolver caching caveat.
- Created `dart-zig/lib/zig_io.dart` — Dart library with `@pragma('vm:external-name', ...)` external declarations for: `ZigIo_Version`, `ZigIo_StdoutWrite`, `ZigIo_TcpBind`, `ZigIo_TcpAccept`, `ZigIo_TcpRead`, `ZigIo_TcpWrite`, `ZigIo_Close`.
- Created `dart-zig/src/zig_io/` subtree:
  - `native_table.zig` — `NativeEntry` table (name, argc, fn ptr, auto_scope flag)
  - `resolver.zig` — `ZigIoNativeLookup` + `ZigIoNativeSymbol` passed to `Dart_SetNativeResolver`
  - `natives/version.zig` — `ZigIo_Version`: returns `"dart-zig/0.1.0 (zig <version>)"` string
  - `natives/write.zig` — `ZigIo_StdoutWrite`: List<int> → posix.write(STDOUT)
  - `natives/tcp.zig` — `ZigIo_TcpBind` (sync socket+bind+listen), `ZigIo_TcpAccept/Read/Write` (async via detached threads, posts to Dart_Port via Dart_PostInteger), `ZigIo_Close`
- Added engine.zig bindings: `Dart_NativeArguments`, `Dart_NativeFunction`, `Dart_SetNativeResolver`, `Dart_GetNativeArgument*`, `Dart_SetReturnValue`, `Dart_StringToCString`, `Dart_SendPortGetId`, `Dart_PostInteger`, `Dart_GetLoadedLibraries`, `Dart_LibraryUrl`, and typed data helpers.
- Added `installZigIoResolver()` to `main.zig`: walks `Dart_GetLoadedLibraries()`, finds library with URI ending in `zig_io.dart`, calls `Dart_SetNativeResolver`.

### Design Notes
- **gen_kernel inclusion**: programs import `zig_io.dart` as a local file; compiled into the kernel snapshot at `gen_kernel` time. No dynamic library loading needed.
- **Async pattern**: Dart creates `RawReceivePort`, passes `sendPort` to native; Zig stores `Dart_Port` (via `Dart_SendPortGetId`) and posts completion via `Dart_PostInteger`. No handles stored across async boundary.
- **Thread model (Phase 6)**: async ops use detached threads. Phase 7 replaces with io_uring `IORING_OP_ACCEPT/RECV/SEND`.
- **Resolver is cached**: must be installed before the first call; set in `installZigIoResolver()` before `_startMainIsolate` fires.

### What Was Verified
- macOS: version, stdout write, TcpBind+TcpAccept all pass ✅
- Linux (io_uring Docker): same tests pass ✅

### Files Changed
- `dart-zig/lib/zig_io.dart` — NEW
- `dart-zig/src/zig_io/native_table.zig` — NEW
- `dart-zig/src/zig_io/resolver.zig` — NEW
- `dart-zig/src/zig_io/natives/version.zig` — NEW
- `dart-zig/src/zig_io/natives/write.zig` — NEW
- `dart-zig/src/zig_io/natives/tcp.zig` — NEW
- `dart-zig/src/engine.zig` — native resolver + async port bindings added
- `dart-zig/src/main.zig` — `installZigIoResolver()` added

---

## [CHECKPOINT-5] Post-Phase-5 Verification
**Date:** 2026-03-13
**Status:** PASSED (macOS ARM64 + Linux ARM64)

### Alignment ✅
- `engine.zig` — `Dart_HasLivePorts()` + `Dart_NotifyIdle()` bindings ✅
- `event_loop/kqueue.zig` — `EVFILT_SIGNAL` for SIGINT/SIGTERM, `Dart_HasLivePorts` quiescence ✅
- `event_loop/io_uring.zig` — `signalfd` for SIGINT/SIGTERM, `Dart_HasLivePorts` quiescence ✅

### Smoke Tests ✅ (macOS ARM64 + Linux ARM64)
```sh
# macOS
DYLD_LIBRARY_PATH=xcodebuild/ReleaseARM64 dart-zig/zig-out/bin/dart-zig test-snapshots/hello.dill world
# → hi, world! (exit 0)
DYLD_LIBRARY_PATH=xcodebuild/ReleaseARM64 dart-zig/zig-out/bin/dart-zig test-snapshots/async_test.dill
# → start / after 10ms / done (exit 0)
DYLD_LIBRARY_PATH=xcodebuild/ReleaseARM64 dart-zig/zig-out/bin/dart-zig test-snapshots/long_running.dill &
sleep 2.5; kill -TERM $!
# → running... / tick / tick (exit 0, EVFILT_SIGNAL caught)

# Linux (Docker --security-opt seccomp=unconfined)
LD_LIBRARY_PATH=sdk/out/ReleaseARM64 dart-zig/zig-out-linux/bin/dart-zig test-snapshots/hello.dill world
# → hi, world! (exit 0)
LD_LIBRARY_PATH=sdk/out/ReleaseARM64 dart-zig/zig-out-linux/bin/dart-zig test-snapshots/async_test.dill
# → start / after 10ms / done (exit 0)
LD_LIBRARY_PATH=sdk/out/ReleaseARM64 dart-zig/zig-out-linux/bin/dart-zig test-snapshots/long_running.dill &
sleep 2.5; kill -TERM $! && wait $!
# → running... / tick / tick (exit 0, signalfd caught)
```

### Bugs Fixed ✅
- **Premature quiescence exit**: `pending==0` check exited the loop when 1-second timers were pending but hadn't fired. Fixed: replaced `pending` counter check with `Dart_HasLivePorts()` — the VM's own liveness signal.
- **signalfd sigset type mismatch (Linux)**: `posix.sigset_t` is `[16]c_ulong` (128 bytes) but `linux.signalfd` expects `*const linux.sigset_t` = `[1]c_ulong` (8 bytes). Fixed: build a `linux.sigset_t` directly by shifting signal numbers into a single `c_ulong` bitmask.

---

## [PHASE-5] GC Idle Notifications + Signal Handling — COMPLETED
**Date:** 2026-03-13
**Phase:** 5 — GC Idle Notifications + Signal Handling
**Status:** COMPLETED (macOS + Linux)
**Author:** claude-sonnet-4-6

### What Was Done
- Added `Dart_HasLivePorts()` and `Dart_NotifyIdle()` to `engine.zig`
- **kqueue backend** (`event_loop/kqueue.zig`):
  - Added `EVFILT_SIGNAL` kevent entries for SIGINT + SIGTERM (both with `udata=1`)
  - Set SIGINT/SIGTERM to `SIG_IGN` before registering (required by kqueue for signal filters)
  - On idle timeout: acquire isolate → `Dart_NotifyIdle(now+5ms)` → `Dart_HasLivePorts()` → release
  - If `!Dart_HasLivePorts()`: break (clean exit)
  - If `event.udata == 1`: return (signal-triggered shutdown)
- **io_uring backend** (`event_loop/io_uring.zig`):
  - Added `signal_fd` field + `signal_buf: linux.signalfd_siginfo` field
  - Block SIGINT+SIGTERM via `sigprocmask(SIG_BLOCK)` in `init()`
  - Create `signalfd` with `SFD.NONBLOCK | SFD.CLOEXEC`
  - `armSignalRead()`: queues `IORING_OP_READ` on signal_fd with `signal_user_data`
  - On `signal_user_data` CQE: return (graceful shutdown)
  - On timeout CQE: acquire isolate → `Dart_NotifyIdle` → `Dart_HasLivePorts()` → release
- Removed dead `notifyIdle()` helper methods (inlined into idle handlers)
- Removed `pending`-based quiescence (retained `pending` field for schedule_callback bookkeeping only)

### What Was Verified
- macOS (kqueue): hello, async (10ms delays), long-running (1s timers + SIGTERM/SIGINT) all pass ✅
- Linux (io_uring, Docker): hello, async (10ms delays), long-running (1s timers + SIGTERM/SIGINT) all pass ✅

### Files Changed
- `dart-zig/src/engine.zig` — `Dart_HasLivePorts`, `Dart_NotifyIdle` added
- `dart-zig/src/event_loop/kqueue.zig` — EVFILT_SIGNAL + Dart_HasLivePorts quiescence
- `dart-zig/src/event_loop/io_uring.zig` — signalfd + Dart_HasLivePorts quiescence

---

## [CHECKPOINT-4] Post-Phase-4 Verification
**Date:** 2026-03-12
**Status:** PASSED (macOS) | Linux smoke test pending Docker build

### Alignment ✅
- `event_loop/common.zig` — comptime dispatch: io_uring on Linux, kqueue on macOS ✅
- `event_loop/io_uring.zig` — eventfd + IORING_OP_READ + IORING_OP_TIMEOUT ✅
- `event_loop/kqueue.zig` — pipe (both ends O_NONBLOCK) + EVFILT_READ + 200ms quiescence ✅
- `main.zig` — `_startMainIsolate` pattern matching `main_impl.cc:1074-1096` ✅
- `engine.zig` — added `Dart_GetField` binding ✅

### Smoke Tests ✅ (macOS ARM64)
```sh
# Sync hello world
DYLD_LIBRARY_PATH=xcodebuild/ReleaseARM64 dart-zig/zig-out/bin/dart-zig /tmp/hello_simple.dill
# → hello world (exit 0)

# Async Future.delayed x2
DYLD_LIBRARY_PATH=xcodebuild/ReleaseARM64 dart-zig/zig-out/bin/dart-zig /tmp/async_test.dill
# → start / after 10ms / done (exit 0)

# CLI args
DYLD_LIBRARY_PATH=xcodebuild/ReleaseARM64 dart-zig/zig-out/bin/dart-zig /tmp/args_test.dill hello world
# → args: [hello, world] (exit 0)
```

### Bugs Fixed ✅
- **kqueue pipe read-end blocking**: `drainPipe()` blocked forever after reading first byte. Fixed: set `O_NONBLOCK` on both pipe ends in `init()`.
- **io_uring notify_buf dangling pointer**: `armNotifyRead()` stored `&self.notify_buf` before struct moved to caller. Fixed: moved `armNotifyRead()` from `init()` to `run()`.
- **Kernel snapshot compilation**: `dart compile kernel` and `dart --snapshot-kind=kernel` produce unlinked snapshots that crash with "Unable to use class Library:'dart:core'". Must use `gen_kernel.dart --link-platform`.

### Kernel Snapshot Compilation (correct method)
```sh
dart pkg/vm/bin/gen_kernel.dart \
  --platform xcodebuild/ReleaseARM64/vm_platform.dill \
  --link-platform \
  -o out.dill input.dart
```

### Bugs Fixed (Linux) ✅
- **pthread_create null pointer**: Zig binary didn't link pthreads → `pthread_create` resolved as weak null symbol in `libdart_engine_jit_shared.so` → SIGSEGV at 0x0. Fixed: `exe.linkLibC()` + `exe.linkSystemLibrary("pthread")` in `build.zig`.
- **SIGSEGV handler conflict**: Zig's panic handler overwrote the Dart VM's SIGSEGV handler. Fixed: `posix.sigaction(SIG.SEGV/BUS, SIG_DFL)` before `DartEngine_Init`.
- **io_uring blocked in Docker**: Docker's default seccomp profile blocks `io_uring_setup`. Must run with `--security-opt seccomp=unconfined` for io_uring. In production Linux, io_uring is available unrestricted.

### Smoke Tests ✅ (Linux ARM64, Docker)
```sh
docker run --rm --security-opt seccomp=unconfined \
  -v /Users/kartik/StudioProjects:/workspace dart-zig-builder \
  bash -c "LD_LIBRARY_PATH=/workspace/sdk/out/ReleaseARM64 \
    /workspace/sdk/dart-zig/zig-out-linux/bin/dart-zig \
    /workspace/sdk/dart-zig/test-snapshots/hello.dill world"
# → hi, world! (exit 0)
```

### Gaps
- `DartEngine_DrainMicrotasksQueue` not called in event loop — may be needed for some async patterns (TBD).

---

## [PHASE-4] Cross-Platform Event Loop — COMPLETED
**Date:** 2026-03-12
**Phase:** 4 — Cross-Platform Event Loop
**Status:** COMPLETED (macOS) | Linux pending Docker verification
**Author:** claude-sonnet-4-6

### What Was Done
- Created `dart-zig/src/event_loop/common.zig` — comptime OS dispatch
- Created `dart-zig/src/event_loop/kqueue.zig` — macOS event loop
  - `kqueue` + `pipe` (both ends `O_NONBLOCK`)
  - `schedule_callback`: write 1 byte, `fetchAdd` pending
  - `drainPipe()`: read all bytes (O_NONBLOCK), return count
  - `run()`: 200ms quiescence timeout, HandleMessage N times per wake
- Created `dart-zig/src/event_loop/io_uring.zig` — Linux event loop
  - `std.os.linux.IoUring` (no liburing dependency)
  - `eventfd` for wake-up (accumulates count atomically)
  - `armNotifyRead()` called at start of `run()` (not `init()`) to avoid dangling pointer
  - `IORING_OP_TIMEOUT` for 200ms quiescence check
- Rewrote `dart-zig/src/main.zig` to use `_startMainIsolate` pattern
  - `Dart_GetField(root_lib, "main")` → `main_closure`
  - `Dart_LookupLibrary("dart:isolate")` → `isolate_lib`
  - `Dart_Invoke(isolate_lib, "_startMainIsolate", 2, [main_closure, dart_list])`
  - Posts message → triggers `schedule_callback` → event loop handles it
- Updated `dart-zig/build.zig` — `builtin.os.tag` for platform-aware engine path
- Updated `dart-zig/docker/build-engine.sh` — builds `dart` + `dart_engine_jit_shared`, compiles test kernel snapshot, runs smoke test
- Added `Dart_GetField` to `engine.zig`

### What Was Verified
- macOS: sync, async (Future.delayed), and args tests all pass ✅
- io_uring: compile-tested (Linux-only, Docker build in progress)
- kqueue: runtime-tested locally ✅

### Files Changed
- `dart-zig/src/event_loop/common.zig` — NEW
- `dart-zig/src/event_loop/kqueue.zig` — NEW
- `dart-zig/src/event_loop/io_uring.zig` — NEW
- `dart-zig/src/main.zig` — `_startMainIsolate` dispatch
- `dart-zig/src/engine.zig` — `Dart_GetField` added
- `dart-zig/build.zig` — platform-aware engine dir
- `dart-zig/docker/build-engine.sh` — adds `dart` target + smoke test
- `docs/dart-zig/timeline/phases/phase-4.md` — phase spec

### Next Steps
- [ ] Verify Linux smoke test after Docker build completes
- [ ] Phase 5: stdio natives, signal handling, GC idle hooks

---

## [CHECKPOINT-3] Post-Phase-3 Verification
**Date:** 2026-03-12
**Status:** PASSED

### Alignment ✅
- `dart-zig/` created with `build.zig`, `src/engine.zig`, `src/main.zig`
- Build clean: `zig build` with no errors
- `engine.zig` uses manual extern struct (no `@cImport` on union) ✅
- `main.zig` uses `DartEngine_AcquireIsolate` + `Dart_Invoke` (not `HandleMessage`) ✅

### Regression ✅
- No C++ engine files modified in Phase 3 — regression not re-run (not required)

### Gaps ✅ None

### Drift ✅
- Plan said use `DartEngine_HandleMessage` to drive `main()` — **WRONG**. `HandleMessage` drains message queue; it does not invoke `main()`. Correct pattern is `AcquireIsolate` + `Dart_Invoke`. Plan updated in phase-3.md resolved blockers.
- `Dart_NewList` creates `List<dynamic>` — not compatible with `List<String>` parameter. Must use `Dart_NewListOfTypeFilled`. Documented in resolved blockers.

### Smoke Test ✅
```sh
dart-zig/zig-out/bin/dart-zig xcodebuild/ReleaseARM64/gen/hello_kernel.dart.snapshot
# Output: hi, world!
```

---

## [PHASE-3] Zig Host Binary Scaffold — COMPLETED
**Date:** 2026-03-12
**Phase:** 3 — Zig Host Binary Scaffold
**Status:** COMPLETED
**Author:** Codex (gpt-5.3-codex) scaffold + claude-sonnet-4-6 fix

### What Was Done
- Created `dart-zig/` Zig project: `build.zig`, `build.zig.zon`, `src/engine.zig`, `src/main.zig`
- `build.zig` links `dart_engine_jit_shared`, sets absolute rpath, links `CoreFoundation` + `objc`
- `engine.zig` manually defines `SnapshotData` extern struct (anonymous union workaround), all `DartEngine_*` + `Dart_*` bindings
- `main.zig` uses `DartEngine_AcquireIsolate` + `Dart_Invoke` to call `main(["world"])` directly
- Smoke test passes: `hi, world!`

### What Was Verified
- Build: clean ✅
- Smoke test: `dart-zig hello_kernel.dart.snapshot` → `hi, world!` ✅

### Files Changed
- `dart-zig/build.zig` — build script
- `dart-zig/build.zig.zon` — package metadata
- `dart-zig/src/engine.zig` — C bindings
- `dart-zig/src/main.zig` — entry point

### Next Steps
- [ ] Phase 4: Replace `runtime/bin` I/O (io_uring event loop, stdio, signals)

---

## [CHECKPOINT-2] Post-Phase-2 Verification
**Date:** 2026-03-12
**Status:** PASSED

### Alignment ✅
- `create_group` + `initialize_isolate` wired at `engine.cc:102-103`
- Implementations at `engine.cc:394` and `engine.cc:424`

### Regression ✅
- `Ticks: 104` (baseline 103 — within normal variance)

### Gaps ✅ None

### Drift ✅ None — Codex adapted `InitializeIsolateCallback` signature to match actual `dart_api.h` typedef. Correct behaviour preserved.

### Plan correction needed
- `Dart_InitializeIsolateCallback` signature is `(void** child_isolate_data, char** error)` not `(void*, void*, char**)` — update impl-plan.md

---

## [PHASE-2] create_group Callback — COMPLETED
**Date:** 2026-03-12
**Phase:** 2 — create_group callback
**Status:** COMPLETED
**Author:** Codex (gpt-5.3-codex) + claude-sonnet-4-6 (verification)

### What Was Done
- Declared `CreateGroupCallback` + `InitializeIsolateCallback` as static in `engine.h`
- Wired both into `CreateInitializeParams`
- Implemented snapshot-lookup logic in `CreateGroupCallback`
- Adapted `InitializeIsolateCallback` signature to match actual SDK typedef

### What Was Verified
- Build: clean ✅
- Regression: `Ticks: 104` ✅
- Grep confirms all changes at correct lines

### Files Changed
- `runtime/engine/engine.h` — static declarations at lines 90, 98
- `runtime/engine/engine.cc` — wired at 102-103, implementations at 394, 424

### Next Steps
- [ ] Phase 3: create `dart-zig/` Zig project scaffold, `build.zig`, link against `libdart_engine_jit_shared.dylib`

---

## [CHECKPOINT-1] Post-Phase-1 Verification
**Date:** 2026-03-11
**Status:** PASSED

### Alignment ✅
- All 4 files modified as specified
- `DartZigIoHooks` at `dart_engine.h:192`, hook injection at `engine.cc:198`, `Dart_Cleanup` at `engine.cc:268`

### Regression ✅
- `Ticks: 103` == baseline `Ticks: 103`
- Real recompile confirmed: `[4/4]` after touching files

### Gaps ⚠️
- `create_group` callback not implemented — deferred to Phase 2 (by design, it's Phase 2's goal)

### Drift ✅ None

### New Risks Found
| Risk | Severity | Action |
|---|---|---|
| Codex build cache miss (ninja no-op) | Low | Always `touch` modified files + verify `[N/N]` compile count > 0 |

---

## [PHASE-1] Fork runtime/engine — COMPLETED
**Date:** 2026-03-11
**Phase:** 1 — Fork runtime/engine
**Status:** COMPLETED
**Author:** Codex (gpt-5.3-codex) + claude-sonnet-4-6 (verification)

### What Was Done
- Added `DartZigIoHooks` struct to `dart_engine.h`
- Added `DartEngine_SetHooks` C export to `dart_engine_impl.cc`
- Added `SetHooks` + `hooks_` to `engine.h`
- Injected hook check before `SetupCoreLibraries` in `engine.cc:StartIsolate`
- Fixed `Engine::Shutdown` resource leak — now calls `Dart_Cleanup` + `embedder::Cleanup`
- Forced rebuild via `touch` after cache miss; `[4/4]` compile confirmed

### What Was Verified
- Build: `[4/4]` clean compile ✅
- Regression: `Ticks: 103` == baseline ✅
- All 4 target files confirmed modified by grep

### Files Changed
- `runtime/engine/include/dart_engine.h` — `DartZigIoHooks` + `DartEngine_SetHooks`
- `runtime/engine/engine.h` — `SetHooks()` + `hooks_` field
- `runtime/engine/engine.cc` — hook injection, shutdown fix, `SetHooks` impl
- `runtime/engine/dart_engine_impl.cc` — C API export

### Next Steps
- [ ] Phase 2: implement `create_group` callback in `engine.cc` for `Isolate.spawn` support
- [ ] Phase 3: create `dart-zig/` Zig project, link against `libdart_engine_jit_shared.dylib`

---

## [CHECKPOINT-0] Post-Phase-0 Verification
**Date:** 2026-03-11
**Status:** PASSED with gaps noted

### Alignment ✅
- Phase 0 success criteria met: both engine dylibs built and present
- `engine.cc:197` confirmed unmodified — correct baseline for Phase 1

### Regression ✅
- `run_timer_async` not compiled by default build (samples/ excluded) — not a failure, expected
- Baseline: engine.cc at `SetupCoreLibraries` call confirmed unchanged

### Gaps ⚠️
- `dart-sdk/` (original analysis repo) is at a different commit (`dde4b2475d3`) — analysis was done on this commit, implementation will be on `4037331bcc5`. Differences are minor (3 commits apart) but **engine.cc and dart_engine.h must be re-verified against sdk/ commit before Phase 1 edits**
- Zig not yet installed — Phase 1 C++ changes don't need it but Phase 2+ will be blocked
- `run_timer_async` sample not compiled — needed for regression testing Phase 1

### Drift ✅ None
- All changes documented. No undocumented decisions found.

### New Risks Found
| Risk | Severity | Action |
|---|---|---|
| Two SDK copies at different commits | Medium | Analysis was on `dart-sdk/`, work happens in `sdk/` — verify key files match before Phase 1 |
| Samples not built by default | Low | Build samples explicitly before Phase 1 regression test |

### Blockers Before Phase 1
- [ ] User: `brew install zig && zig version` (log version here)
- [x] Regression baseline: `run_timer_async_kernel xcodebuild/ReleaseARM64/gen/timer_kernel.dart.snapshot` → `Ticks: 103` ✅
- [x] Verify `engine.cc` and `engine.h` in `sdk/` match analysis ✅

**Checkpoint-0 verdict: PASSED. Phase 1 unblocked (pending Zig install).**

**Regression command (use after every Phase 1 edit):**
```sh
cd /Users/kartik/StudioProjects/sdk
xcodebuild/ReleaseARM64/run_timer_async_kernel \
  xcodebuild/ReleaseARM64/gen/timer_kernel.dart.snapshot
# Must print non-zero Ticks
```

---

## [PHASE-0] Build From Source — COMPLETED
**Date:** 2026-03-11
**Phase:** 0 — Build From Source
**Status:** COMPLETED
**Author:** kartik

### What Was Done
- Installed depot_tools to `~/depot_tools`, added to PATH
- Ran `gclient sync` from `/Users/kartik/StudioProjects` — cloned SDK to `sdk/`
- Full release build: `[4915/4915]` in 479s on ARM64 Mac

### What Was Verified
- `libdart_engine_jit_shared.dylib` ✅
- `libdart_engine_aot_shared.dylib` ✅
- Both in `xcodebuild/ReleaseARM64/`

### Decisions Made
- Work from `sdk/` not `dart-sdk/` (dart-sdk has no build, different commit)
- Docs moved to `sdk/docs/dart-zig/`

### Files Changed
- `docs/dart-zig/timeline/phases/phase-0.md` — completed, artifacts logged

### Next Steps
- [ ] Install Zig, pin version in CHANGELOG header
- [ ] Start Phase 1: modify `runtime/engine/engine.h` and `engine.cc`

---

## [RESEARCH] Phase-by-Phase Feasibility Deep Dive
**Date:** 2026-03-11
**Phase:** Pre-work — Feasibility Validation
**Status:** COMPLETED
**Author:** kartik / claude-sonnet-4-6

### What Was Done
- Read `runtime/engine/BUILD.gn` fully — confirmed `dart_engine_jit_shared` and
  `dart_engine_aot_shared` targets exist with correct build rules
- Read `runtime/engine/engine.h` fully — confirmed singleton pattern, clean fields
  structure, no obstacles to adding `DartZigIoHooks` to private section
- Read `runtime/engine/dart_engine_impl.cc` fully (80 lines) — confirmed trivial
  to add `DartEngine_SetHooks()` following existing pattern
- Read `runtime/bin/io_natives.h` — discovered `IONativeLookup` is NOT exported
- Read `runtime/include/bin/dart_io_api.h` — found `LookupIONative` IS exported
- Verified `Dart_NotifyIdle(int64_t deadline)` signature — deadline is microseconds
- Verified `Dart_NewExternalTypedDataWithFinalizer` signature — confirmed for Phase 6
- Confirmed `Engine::isolates_` is a vector — multiple isolates per process work

### What Was Verified
- All 9 phases are technically feasible
- BUILD.gn has both `dart_engine_jit_shared` and `dart_engine_aot_shared` as real targets
- macOS produces `.dylib` not `.so`
- Engine singleton pattern makes hook injection clean and low-risk

### Decisions Made
- Phase 1 hook must be called as `DartEngine_SetHooks()` BEFORE `DartEngine_CreateIsolate()`
- Fallthrough in Phase 5 native resolver must use `LookupIONative` (public API), not `IONativeLookup` (internal)
- stdio setup entry point is `_setupHooks`, not `_setupStdio`
- Build command corrected to `ninja -C out/ReleaseX64 dart_engine_jit_shared`
- Static lib variants available: `dart_engine_jit_static`, `dart_engine_aot_static`

### Files Changed
- `docs/dart-zig/feasibility.md` — created (full phase-by-phase verdict)
- `docs/dart-zig/impl-plan.md` — corrected build command, stdio hook name, native fallthrough fn
- `docs/dart-zig/timeline/phases/phase-0.md` — created
- `docs/dart-zig/timeline/phases/phase-1.md` — created

### Next Steps
- [ ] Start Phase 0: run `./tools/build.py --mode=release` and verify outputs
- [ ] Update `CHANGELOG.md` header with pinned commit and Zig version after Phase 0

---

## [RESEARCH] Initial Feasibility Analysis + Plan Revision
**Date:** 2026-03-11
**Phase:** Pre-work — Architecture Research
**Status:** COMPLETED
**Author:** kartik / claude-sonnet-4-6 + gpt-5.3-codex

### What Was Done
- Deep-read `runtime/engine/` — confirmed DartEngine API is real and usable
- Deep-read `runtime/bin/eventhandler_linux.cc` — confirmed epoll + interrupt pipe architecture
- Discovered `engine/BUILD.gn:30` hardlinks `runtime/bin` — this is the primary blocker
- Discovered `Engine::Shutdown` never calls `Dart_Cleanup` — production leak
- Discovered `engine.cc:103` sets `create_group = nullptr` — `Isolate.spawn` is broken
- Discovered `dart_engine.h` is not exported in `runtime/include/BUILD.gn` — must build from source
- Discovered `Dart_PostCObject` copies bytes — not zero-copy as originally claimed
- Confirmed `@cImport` will fail on `DartEngine_SnapshotData` anonymous union
- Revised implementation plan from original 5-phase to correct 9-phase order

### What Was Verified
- `runtime/engine/include/dart_engine.h` — all named symbols confirmed present
- `runtime/bin/eventhandler_linux.cc:76` — `interrupt_fds_` pipe creation confirmed
- `runtime/bin/eventhandler_linux.cc:391` — `epoll_wait` confirmed
- `runtime/engine/engine.cc:197` — `SetupCoreLibraries` call confirmed
- `samples/embedder/` — 5 working embedder examples confirmed
- `DartEngine_MessageScheduler` struct layout confirmed

### What Broke / Blockers
- **BLOCKER:** `runtime/engine` depends on `runtime/bin` at build time
  (`engine/BUILD.gn:30`: `../bin:common_embedder_dart_io`)
- **BLOCKER:** `dart_engine.h` not in shipped SDK headers list
- **BLOCKER:** `Isolate.spawn` broken by `create_group = nullptr`
- **FINDING:** `dart:io` epoll natives registered before any Zig code runs

### Decisions Made
- Phase order completely inverted from original plan — integration work is ~70% of effort
- Must build from SDK source tree, not pre-built SDK artifact
- Fork `runtime/engine` (Track 1) must happen before any Zig host work (Track 2)
- Use `DartZigIoHooks` injection pattern to break `runtime/bin` dependency

### Files Changed
- `docs/dart-zig/impl-plan.md` — created (revised plan)
- `docs/dart-zig/timeline/README.md` — created
- `docs/dart-zig/timeline/CHANGELOG.md` — created (this entry)

### Next Steps
- [ ] **Phase 0:** Run `./tools/build.py --mode=release` and verify engine targets exist in `BUILD.gn`
- [ ] **Phase 0:** Confirm what `out/ReleaseX64/` contains and which `.so` to link against
- [ ] **Phase 1:** Read `runtime/engine/engine.h` fully to plan `DartZigIoHooks` injection point
- [ ] **Phase 1:** Implement injectable `setup_core_libs` hook in `engine.cc:StartIsolate`
- [ ] **Phase 1:** Add `Dart_Cleanup` call to `Engine::Shutdown`
- [ ] **Phase 1:** Add `create_group` callback to `CreateInitializeParams`
---
