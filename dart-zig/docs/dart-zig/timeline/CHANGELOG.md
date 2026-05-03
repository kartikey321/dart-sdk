# dart-zig Changelog

---

## Phase 18 — Bug fixes, perf profiling, AOT HttpServer, `req.path` optimisation (2026-05-03)

### Bug fixes (`src/event_loop/io_uring.zig`, `src/zig_io/natives/tcp.zig`)

Three production-correctness issues found via code audit and fixed:

**1. Invalid `Dart_TypedDataReleaseData` after failed `AcquireData` (tcp.zig)**
`ZigIo_TcpWriteBytesToken` and `ZigIo_TcpWriteBytes` both called `ReleaseData` unconditionally
even when `AcquireData` returned an error. Calling Release without a matching Acquire
corrupts Dart VM WeakTable state and could destabilise the heap.
Fix: check `Dart_IsError(acq)` first; only call `ReleaseData` when acquisition succeeded.

**2. Pool slot leak on SQ-full in legacy `.serve` / `.loop` dispatch (io_uring.zig)**
In `dispatchPoolCqe`, the resubmit `ring.read(...)` calls for incomplete HTTP requests used
`catch {}` — silently swallowing SQ-full errors and leaving the pool slot permanently
in-use. Under sustained high-connection load the 4096-slot pool would exhaust, causing
every new native I/O call to fail with `-1`.
Fix: on `ring.read` failure, post `-1` to the Dart port and free the slot immediately.
Three sites patched: `.serve` incomplete recv, `.loop` incomplete recv, `.loop` empty-buffer
resubmit.

**Note on CQ overflow:** Zig's `copy_cqes` already handles `IORING_SQ_CQ_OVERFLOW` — when
the flag is set it calls `io_uring_enter(GETEVENTS)` before returning, flushing the kernel
overflow list back to the CQ ring. No additional handling needed.

### `ZigHttpServer` — `req.path` fast-path + AOT compilation

**`req.path` property (lib/zig_http_server.dart)**

Added direct `path` field to `ZigHttpRequest`; `uri` is now lazy:
```dart
class ZigHttpRequest {
  final String path;        // raw path string — no allocation cost
  Uri get uri => _uri ??= Uri.parse(path);  // lazy, only when query params needed
}
```
Handlers that only need the path (the common case) no longer trigger `Uri.parse()` on every
request. perf profile confirmed `Dart_NewStringFromUTF8` (0.27% of samples in JIT) was the
`Uri.parse` allocation; it is absent from the AOT profile after this change.

Updated `zig_http_server_example.dart` to use `switch (req.path)` instead of
`switch (req.uri.path)`.

**AOT snapshot**

ZigHttpServer is now compiled and benchmarked as AOT ELF:
```sh
dart pkg/vm/bin/gen_kernel.dart --aot -o example_aot.dill example.dart
gen_snapshot --snapshot-kind=app-aot-elf --elf=example.so example_aot.dill
./dart-zig-aot example.so 9091
```

**Benchmark (`wrk -t4 -c100 -d10s`, Linux VPS, 1 worker):**
```
ZigHttpServer JIT (before req.path fix):   ~36.5k req/s
ZigHttpServer AOT (after req.path fix):    ~35.9k req/s  (consistent, low jitter)
Op.loop AOT (zero-Dart path):              ~130k  req/s
dart:io AOT:                               ~9.9k  req/s
```
AOT is slightly lower than warmed JIT in raw req/s but has much better tail latency:
- JIT: 3.5ms avg ± 6ms (GC pauses visible)
- AOT: 2.8ms avg ± 1.1ms (no JIT compilation GC spikes)

### perf profile — ZigHttpServer JIT vs AOT

**JIT flat profile (top named symbols):**
```
 1.90%  libc write                          ← actual TCP send
 1.34%  pthread_mutex_lock                  ← Dart VM internal locking per completion
 1.02%  NativeEntry::AutoScopeNativeCallWrapper  ← every @pragma native entry overhead
 0.94%  Scavenger::TryAllocateNewTLAB       ← per-request GC allocation
 0.94%  pthread_mutex_unlock
 0.63%  malloc
 0.40%  ApiMessageSerializer::Serialize     ← batch CQE→Dart message packing
 0.27%  Dart_NewStringFromUTF8              ← Uri.parse() (eliminated by req.path)
 0.23%  ZigHttp_Parse                       ← our HTTP parser (tiny — good)
 0.29%  ZigIo_TcpReadToken / 0.27% ZigIo_TcpWriteBytesToken
```
Profile is fragmented — no single hot function. Server was spending ~5% in kernel
(`io_uring_enter`), with the rest scattered across Dart VM machinery. Compare to Op.loop
which spends 96% in `io_uring_enter` (pure I/O wait).

**AOT flat profile (top named symbols, reveals actual Dart hotspots):**
```
 1.59%  libc write
 1.55%  _Utf8Encoder._fillBuffer            ← utf8.encode() for HTTP header bytes
 1.26%  Future._propagateToListeners        ← async await/completion chain
 1.20%  pthread_mutex_lock
 1.05%  stub AwaitStub                      ← suspend cost per await
 1.01%  stub AllocateClosure1Stub           ← async continuation allocation
 0.99%  stub AllocateObjectParameterizedStub ← ZigHttpRequest/Response alloc
 0.93%  stub AllocateUint8ArrayStub         ← recv buffer copies
 0.87%  stub AllocateContextStub            ← captured-variable context per conn
 0.85%  String._concatAll                   ← header string interpolation
 0.78%  AutoScopeNativeCallWrapper          (↓ vs JIT — no JIT recompile overhead)
 0.74%  _StringBase._interpolate            ← '$name: $value\r\n' in header loop
 0.52%  ZigHttpResponse.close               ← response building
 0.47%  ZigHttpServer._handleConnection
 0.45%  Scavenger::TryAllocateNewTLAB       (↓ vs JIT)
 0.39%  _LinkedHashMapMixin._insert/_remove ← ZigHeaders Map per response
```

**AOT profile key findings:**
- `Uri.parse` is **gone** from AOT profile (eliminated by `req.path`)
- `_Utf8Encoder._fillBuffer` (1.55%) — `utf8.encode()` for HTTP header bytes is now the
  #2 hotspot. Pre-building static header byte sequences would reduce this.
- String interpolation (`$name: $value\r\n`) in the header loop: 0.85%+0.74% = 1.59%
  combined. Pre-computing `content-type` / `content-length` prefix bytes would help.
- `ZigHeaders` HashMap insert/remove (0.78%) — for default headers that are always set,
  a flat array would be faster.
- Allocation stubs dominate (>4% combined): async closures, contexts, Uint8Arrays.
  Per-request object count is high; a connection-scoped buffer pool could reduce GC.

**`close()` prod-correctness fix**
`content-type` and `connection` were set with `_set` (unconditional overwrite), silently
discarding any value the handler set via `response.headers.set(...)`. Changed both to
`_setIfAbsent` so handler-set values are respected. `content-length` was already `_setIfAbsent`.

**Status line cache (safe optimisation applied)**
Replaced `'HTTP/1.1 $statusCode ${_statusText(statusCode)}\r\n'` string interpolation with
a `static const Map<int, String>` of pre-built status lines. Eliminates `String._concatAll`
for all common status codes. Unknown codes fall back to interpolation.

**Deferred optimisations — prod-breaking, do not apply before release:**

| Optimisation | Why deferred |
|---|---|
| Pre-build `content-type: text/plain…\r\n` bytes | Bypasses `headers.set('content-type', …)` override |
| Pre-build `connection: keep-alive\r\n` bytes | Bypasses `headers.set('connection', 'close')` override |
| Remove `ZigHeaders` from default-header path | Breaks all user custom headers |
| Inline ASCII digit loop for `content-length` | Breaks `headers.set('content-length', …)` override |
| Replace `ZigHeaders` Map with flat array | API-breaking — removes `headers[name]` lookup |

The remaining profile hotspots (`Future._propagateToListeners`, `AwaitStub`, `AllocateClosure1Stub`,
`AllocateContextStub`) are structural costs of 2 Dart awaits/request and cannot be reduced
without changing the abstraction itself.

---

## Phase 17 — HttpServer abstraction + io_uring async send + perf audit (2026-05-03)

### ZigHttpServer abstraction (`lib/zig_http_server.dart`)

New `ZigHttpServer` class providing a dart:io-compatible API over dart-zig's io_uring backend:

```dart
final server = await ZigHttpServer.bind('0.0.0.0', 8080);
server.stream.listen((req) {
  req.response
    ..statusCode = 200
    ..write('Hello!')
    ..close();
});
```

**Design:**
- `ZigHttpServer.bind()` → calls `zigIoTcpBind` (Zig), returns server object
- Accept loop: `zigIoTcpAcceptFuture` per connection (io_uring accept SQE)
- Per-connection: 8 KB stack buffer, accumulates until `parseHttpRequest` (ZigHttp_Parse native) succeeds
- Response: `ZigHttpResponse` builds HTTP/1.1 bytes in Dart, sends via `zigIoTcpWriteBytesFuture`
- Keep-alive: Zig byte-scan for `Connection: close` header (no Dart string alloc)
- `ZigHeaders`: case-insensitive map (lowercase storage)
- ~2 io_uring round-trips per request (recv SQE + send SQE)

**Benchmark (JIT, 1 worker, `wrk -t4 -c100 -d10s`):**
```
ZigHttpServer abstraction:  ~36.5k req/s  (~2 Dart awaits/request)
Op.loop (zero-Dart path):   ~130k  req/s  (0 Dart awaits/request)
dart:io AOT:                ~9.9k  req/s
```
ZigHttpServer provides full Dart request handlers at 3.7× dart:io throughput.
Op.loop remains the fast path for static-response servers (12× dart:io).

### async `ring.send` / `ring.recv` (io_uring, Linux)

Replaced `posix.write()` fast-path with async `ring.send()` in `processLoopPipeline`:
- All pending sends batched into one `io_uring_enter()` call
- `ring.recv` / `ring.send` use socket-layer ops (bypass VFS)

**Result (+12–15% throughput on 3-worker AOT):**
```
Before (posix.write):  ~178k req/s (3w AOT)
After  (ring.send):    ~200-221k req/s
```

### SO_REUSEPORT multi-process for dart:io (`/tmp/reuseport_shim.so`)

LD_PRELOAD shim that sets `SO_REUSEPORT` on every TCP socket, enabling N independent
dart:io processes to share a port (the same model as Node.js cluster):

```sh
LD_PRELOAD=/tmp/reuseport_shim.so dartaotruntime server.aot 8080 &
LD_PRELOAD=/tmp/reuseport_shim.so dartaotruntime server.aot 8080 &
# kernel distributes connections evenly across both
```

**Benchmark (Linux VPS 6-core, `wrk -t4 -c100 -d15s`):**
```
dart:io AOT 1 process:                    ~9.9k req/s
dart:io AOT 3 processes (shim):           ~31.3k req/s  (3.2× scaling)
dart:io AOT 6 processes (shim):           ~46.8k req/s  (4.7× — diminishing returns)
dart-zig AOT 1 worker:                    ~119.7k req/s
dart-zig AOT 3 workers:                   ~225.2k req/s
dart-zig AOT 6 workers:                   ~204.6k req/s
```

dart-zig 1 worker beats dart:io 6 processes by 2.5×. The fundamental gap is that
dart:io does Dart work per request (header parsing, Future chains, response allocation);
dart-zig Op.loop keeps the entire keep-alive cycle in Zig.

### perf profile (AOT, 1 worker under wrk load)

```
96.23%  io_uring_enter (blocked in kernel waiting for I/O) ← expected, I/O bound
 1.01%  routeRequestFull (Zig HTTP parser)
 0.98%  processLoopPipeline (CQE handler + SQE submission)
 0.31%  io_uring_sqe.prep_rw / prep_recv
 0.20%  flush_sq
```

Key insight: server is I/O-bound. User-space CPU is negligible. Optimization headroom
is in reducing kernel round-trips (SQPOLL) or network RTT, not Zig processing.

---

## PERF-6 — Keep-alive loop native: zero Dart interactions per request (2026-04-15)

**What changed:**
- New `Op.loop` in `state.zig` — reuses `ServeData` struct (adds `pending_consumed: usize` field)
- New `submit_loop` vtable entry in `LoopOps`
- `kqueue.zig`: `processLoopPipeline()` helper + `.loop` in `collectPoolEvent` + `.loop` in `dispatchPoolEvent` + `submitLoop()`
- `io_uring.zig`: `processLoopPipeline()` helper + `.loop` in `collectPoolCqe` + `.loop` in `dispatchPoolCqe` + `submitLoop()`
- `tcp.zig`: `ZigIo_TcpLoopToken(connFd, token)` native — allocates slot, sets `op=.loop`, submits
- `native_table.zig`: registered `ZigIo_TcpLoopToken` argc=2
- `zig_io.dart`: `_zigIoTcpLoopToken` extern + `zigIoTcpLoopFuture(connFd)` function
- `http_server.dart`: `_handleConn` reduced to `await zigIoTcpLoopFuture(connFd); zigIoClose(connFd);`

**Key design — pipelining inner loop:**
After writing the response, if `recv_buf` still contains bytes (pipelined request from the same `recv`), call `routeRequestFull()` again immediately without re-arming the socket. This eliminates the kevent/CQE roundtrip for pipelined requests — pure CPU processing only.

```
recv → routeRequestFull() → posix.write() → memmove → routeRequestFull() → ... → re-arm recv
```

**Dart hot-path changes:**
- Before: accept → `while { await zigIoTcpServeFuture() }` = 1 await/request
- After:  accept → `await zigIoTcpLoopFuture()` = 1 await/connection = **0 await/request**

**Results (macOS ARM64, kqueue, JIT/AOT, `wrk -t4 -c128 -d10s`):**

| Phase | JIT req/s | AOT req/s | vs PERF-4 |
|-------|----------:|----------:|----------:|
| PERF-4 (serve op, 1 await/req) | ~178k | ~178k | baseline |
| **PERF-6 (loop op, 0 await/req)** | **~243k** | **~275k** | **+37% JIT / +54% AOT** |

**Results (Linux VPS, 6-core, io_uring, ReleaseFast, taskset CPU-pinned, `bench_vps.sh`):**

| Config | PERF-4 | PERF-6 (no fix) | PERF-6 + safepoint fix |
|--------|-------:|----------------:|-----------------------:|
| JIT 1w | 95k | 67k (-30%) | **~102k (+7%)** |
| JIT 3w | 206k | 201k | ~200k |
| JIT 6w | 192k | 210k | ~210k |
| AOT 1w | 97k | 97k | 97k |
| AOT 3w | 238k | 211k | ~204k |
| AOT 6w | 187k | 207k | ~206k |

**JIT safepoint fix (`jit_idle_iters`, threshold=128):** Without regular `DartEngine_HandleMessage` calls (Dart is only woken on connection close), JIT background compiler threads on a single-core-pinned process starve. Confirmed by `ps -L` showing a DartWorker thread competing with the event loop. Fix: every 128 event-loop iterations where pool I/O fired but no Dart batch was posted, call `DartEngine_AcquireIsolate/ReleaseIsolate` — creates a safepoint without running Dart code or GC. This recovers JIT 1w from 67k → ~102k (beats PERF-4 baseline).

**Key insight:** Eliminating the HashMap lookup + Completer.complete() overhead per request unlocks significant gains, especially for AOT where Dart execution is cheaper (TFA tree-shaking reduces dispatch overhead). JIT still benefits because the event loop no longer needs to context-switch into Dart between requests.

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
