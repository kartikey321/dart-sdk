# dart-zig Changelog

---

## PERF-5 — Correctness: partial read accumulation + pool exhaustion 503 (2026-04-15)

**Problems fixed:**

1. **Partial HTTP read (false 400):** `routeRequest()` previously mapped `incomplete` → `bad_request`.
   Slow or segmented clients got a false 400. Now `incomplete` returns `RouteId.incomplete = -4`
   and the serve op re-arms recv (kqueue: EVFILT_READ re-arm; io_uring: resubmit read SQE into
   remaining buffer space) until the full request arrives or the 8KB buffer fills.

2. **Pool exhaustion silent drop:** When all 4096 slots are in use, `ZigIo_TcpServeToken` used to
   post `-1` which looked like EOF. Now: sends a synchronous `503 Service Unavailable` response
   (no slot needed) then signals close — client gets a proper HTTP error instead of a hang.

**Changes:**
- `parser.zig`: `routeRequest()` returns `RouteId.incomplete = -4` for `status == .incomplete`
- `responses.zig`: added `service_unavailable` comptime slice
- `state.zig`: `ServeData` gains `recv_len: usize = 0`
- `kqueue.zig`: batch + legacy paths accumulate into `recv_buf[recv_len..]`; new `armServeRecv()`
- `io_uring.zig`: resubmits read SQE into remaining buffer on incomplete
- `tcp.zig`: pool-exhausted path sends 503 synchronously
- `zig_http.dart`: `RouteId.incomplete = -4` synced

---

Phase-by-phase development log. Benchmarks run with `wrk -t4 -c128 -d10s` unless noted.

---

## PERF-4 — Fused serve op: read+route+write in one async slot (2026-04-15)

**What changed:**
- New `Op.serve` in `state.zig` with `ServeData` (recv_buf + write_ptr/len + phase flags)
- New `src/http/responses.zig`: comptime-constant response byte slices for all four routes — no heap, no Dart involvement
- kqueue + io_uring: `collectPoolEvent`/`collectPoolCqe` handle `.serve` in two phases:
  - Phase 1 (recv): read bytes → `routeRequest()` → inline `posix.write()` of static response
  - Phase 2 (write-remainder, rare): re-arms EVFILT_WRITE (kqueue) / resubmits SQE (io_uring) until fully sent
- `ZigIo_TcpServeToken(connFd, token)` native in `tcp.zig`
- `zigIoTcpServeFuture(connFd)` in `zig_io.dart`: posts 0 (keep-alive) or −1 (close)
- `http_server.dart` reduced to 55 lines — hot path is a single `await zigIoTcpServeFuture(connFd)`

**Result (Linux VPS, 6-core, io_uring, ReleaseFast, taskset CPU-pinned, `bench_vps.sh`):**

| Config | Before (Phase 14) | After (PERF-4) | Gain |
|--------|------------------:|---------------:|-----:|
| JIT 1 worker  | ~37k  | **95k**  | **2.5×** |
| JIT 3 workers | ~126k | **206k** | **1.6×** |
| JIT 6 workers | —     | 192k     | _(see note)_ |
| AOT 1 worker  | —     | **97k**  | +2% vs JIT |
| AOT 3 workers | —     | **238k** | 2.46× scaling |
| AOT 6 workers | —     | 187k     | _(see note)_ |

**Note on 6-worker degradation:** 6 workers pinned to cores 0–5 while wrk also runs on cores 3–5
causes server workers 3–5 to compete with the benchmark client. This is a benchmarking artifact,
not a regression — 6 workers would scale linearly on a 12-core machine where client and server
can be fully separated. Effective max for this VPS is 3 server workers (cores 0–2) + 3 wrk (3–5).

**Key insight — AOT ≈ JIT (+2% single-worker):** With only 1 await per request, Dart execution
is no longer the bottleneck. JIT is already fully warmed before wrk's 10s window. The remaining
overhead is the batch dispatcher's HashMap lookup + Completer resume.

- Per-request await count: **3 → 1**
- Per-request Dart heap allocation: **2 → 0** (no Uint8List, no response copy)
- Isolate crossings per request: **3 → 1**
- macOS kqueue single-worker (debug build): **~178k req/sec**

---

## PERF-3 — recv_route op: parse+route in Zig completion handler (2026-04-15)

**What changed:**
- New `Op.recv_route` in `state.zig`; completion handler calls `routeRequest()` and posts a `RouteId` int
- Eliminates: `ApiMessageSerializer::Serialize`, Uint8List malloc, memcpy, WeakTable tracking, GC pressure
- `ZigIo_TcpReadRouteToken` native + `zigIoTcpReadRouteFuture()` in `zig_io.dart`
- `RouteId.eof = -3` added to both `parser.zig` and `zig_http.dart`
- Per-request await count: **3 → 2** (recv_route + write)

**Perf profile savings (estimated from pre-work perf data):**
- `ApiMessageSerializer::Serialize`: −0.80%
- `memcpy` (backing store): −0.47%
- `ScavengerVisitor` (GC): −1.23%

Note: PERF-4 (serve op) supersedes this for the hot path. recv_route remains available as a building block.

---

## PERF-2 — ZigHttp_RouteRequest: parse+route in one native call (2026-04)

**What changed:**
- `src/http/parser.zig`: added `RouteId` constants + `routeRequest(buf) i64`
- `src/http/natives.zig`: `ZigHttp_RouteRequest` native — acquires TypedData, routes, returns int
- `lib/zig_http.dart`: `RouteId` class + `zigHttpRoute(bytes)` function
- `lib/http_server.dart`: hot path calls `zigHttpRoute(bytes)` → switch on int
- Zero Dart heap allocation for routing (was: string slicing, header map construction)

---

## PERF-1 — Multi-worker SO_REUSEPORT investigation (2026-04)

**Finding:** No scaling visible on macOS — benchmark client (wrk) and server compete for the same cores. Same-machine ceiling ~132k req/sec regardless of worker count.

**Fix:** CPU pinning with `taskset -c` on Linux VPS separates server and client cores.

**Linux VPS results (6-core, io_uring, taskset separated, pre-PERF-4):**
| Workers | Cores (server) | req/sec |
|---------|---------------|---------|
| 1       | 0             | ~37k    |
| 3       | 0–2           | ~126k   |

See PERF-4 for post-optimization numbers (92k / 196k).

Linear scaling confirmed (3.4× on 3 cores). Architecture is correct.

---

## Phase 15 — VPS setup script (2026-04)

`scripts/setup_vps.sh`: one-shot x86_64 Linux VPS provisioner.
- Installs Zig 0.15.2 for correct arch
- System deps (build-essential, liburing-dev, wrk from source if missing)
- depot_tools + gclient sync + Dart engine build (JIT + AOT shared libs, 20–40 min)
- BoringSSL static libs
- dart-zig JIT + AOT binaries
- HTTP snapshots (JIT .dill + AOT .so)

---

## Phase 14 — Batch dispatcher (2026-03)

**What changed:**
- `ZigIo_SetBatchPort` native: registers a single `RawReceivePort` for all I/O completions
- `_ZigIoDispatcher` in `zig_io.dart`: token map, one `kArray` message per kevent() batch
- Reduces `DartEngine_HandleMessage` calls from N (one per completion) to 1 per batch
- Token-based API: `ZigIo_TcpAcceptToken`, `ZigIo_TcpReadToken`, `ZigIo_TcpWriteBytesToken`

**Result:** HTTP server: 133–147k → **159k req/sec** (Linux io_uring, wrk same-machine)

---

## Phase 13 — HTTP/1.1 server (2026-03)

- `src/http/parser.zig`: zero-allocation HTTP/1.1 parser, all slices into caller buffer
- `src/http/natives.zig`: `ZigHttp_Parse` native (synchronous, returns `[method, path, bodyOffset]`)
- `lib/http_server.dart`: keep-alive loop, pre-built response `Uint8List` globals
- `lib/zig_http.dart`: `HttpRequest`, `parseHttpRequest()`

---

## Phase 12 — SO_REUSEPORT multi-worker (2026-03)

- N workers each `bind()+listen()` on the same port with `SO_REUSEPORT`
- Kernel distributes incoming connections across workers with zero coordination
- `--workers=N` CLI flag; each worker gets its own event loop + Dart isolate
- `kPoolSize` raised 256 → 4096 (32 MB pool)

---

## Phase 11 — AOT support + kqueue/io_uring backends (2026-02)

- `dart-zig-aot` binary links `dart_engine_aot_shared`
- kqueue backend (macOS): EVFILT_READ/WRITE, pipe-based wakeup
- io_uring backend (Linux): SQE ring, eventfd wakeup, signalfd shutdown
- `Dart_NotifyIdle` on timeout — GC hints during idle periods
- Inline send fast-path in io_uring: `posix.write()` before SQE submission

**macOS ARM64 steady-state (kqueue, AOT):**
```
dart-zig AOT:  291k avg req/s
dart:io  AOT:  283k avg req/s
```
