# dart-zig: Revised Implementation Plan

A Zig-hosted Dart runtime that replaces `runtime/bin/` I/O host layer with a Zig
binary, plugs into the DartEngine embedding API, and swaps epoll for io_uring on Linux.

**Working SDK:** `/Users/kartik/StudioProjects/sdk/`
**Build output:** `xcodebuild/ReleaseARM64/` (ARM64 macOS)
**SDK commit:** `4037331bcc5a52f36630212197cbaa42be1ffb0e`

---

## Collaboration Rules

These rules govern how work is split between Claude, Codex, and the user.

### Agent Responsibilities

| Agent | Does | Does NOT |
|---|---|---|
| **Claude** | Analysis, architecture, targeted reads, doc updates, verification | Long builds, repeated reads, boilerplate generation |
| **Codex** | Autonomous code writing, multi-file edits, build-fix loops (`--full-auto`) | Architecture decisions, codebase analysis |
| **User** | Terminal, network, system access, external research, delicate ops | Routine doc updates |

### Hard Rules

1. **Token rule** — if a task costs >2x tokens vs offloading it, offload it
2. **Stuck rule** — if any agent is blocked after 2 attempts, it stops and offloads; does NOT brute-force
3. **Delicate ops rule** — anything that modifies shared state, pushes to remote, or is irreversible: agent stops, flags to user, waits for explicit approval
4. **External research** — user can bring in findings from external sources (papers, PRs, other repos); log them in CHANGELOG as `[EXTERNAL]` entries
5. **Offload logging** — every offloaded task gets a row in the Offload Log below; status: `PENDING → IN-PROGRESS → DONE`

### Verification Checkpoints

A checkpoint runs at the **end of every phase** and on demand. It checks:

- [ ] **Alignment** — does what was built match what the phase success criteria said?
- [ ] **Regression** — does the existing embedder sample (`run_timer_async`) still pass?
- [ ] **Gaps** — what did we plan to do that wasn't done?
- [ ] **Drift** — has any agent gone off-plan or made undocumented decisions?
- [ ] **New risks** — did implementation reveal problems not in the risk table?

Checkpoint results are logged in CHANGELOG as `[CHECKPOINT-N]` entries.
Failed checks block the next phase until resolved.

### Offload Log

| # | Task | Offloaded To | Status | Phase | Notes |
|---|---|---|---|---|---|
| 1 | `gclient sync` + build | User | ✅ DONE | 0 | Built to `xcodebuild/ReleaseARM64/` |
| 2 | Install Zig | User | ✅ DONE | pre-1 | `zig 0.15.2` at `/opt/homebrew/Cellar/zig/0.15.2` |

---

## Verification Status

### What the Analysis Confirmed ✅

| Claim | Verdict |
|---|---|
| DartEngine API exists and works | ✅ Confirmed — real samples, copyright 2025 |
| epoll + interrupt pipe (3 hops) | ✅ Confirmed — `interrupt_fds_` at line 76, `epoll_wait` at line 391 |
| io_uring collapses recv to 1 hop | ✅ True for recv/send (needs `IORING_OP_TIMEOUT` for timers) |
| `Dart_SetNativeResolver` pattern | ✅ Confirmed — `io_natives.cc` `IO_NATIVE_LIST` is exactly this |

### What the Analysis Found WRONG or MISSED ❌

| Claim | Reality |
|---|---|
| `Dart_PostCObject` is zero-copy | ❌ Copies into Dart heap — must use `Dart_NewExternalTypedDataWithFinalizer` |
| `@cImport` translates `dart_engine.h` | ❌ Anonymous C union fails — manual Zig struct required |
| `dart:io` natives can be replaced cleanly | ❌ Engine registers them before Zig runs — you're adding, not replacing |
| `Isolate.spawn` works | ❌ `engine.cc:103` sets `create_group = nullptr` — spawn silently fails |
| `dart_engine.h` available as shipped header | ❌ Not in `runtime/include/BUILD.gn` — must build from SDK source tree |
| Engine independent of `runtime/bin` | ❌ `engine/BUILD.gn:30` hardlinks `../bin:common_embedder_dart_io` |
| `Timer` / `Future.delayed` works | ❌ Needs `timerfd` or `IORING_OP_TIMEOUT` — entirely unimplemented |
| `print()` works out of the box | ❌ Needs `SetExecutableName` + stdio fd setup |
| GC is handled | ❌ `Dart_NotifyIdle` never called — GC latency spikes under load |

---

## The Real Blocker: Engine ↔ bin Entanglement

`runtime/engine/BUILD.gn` hardcodes:

```gn
deps = [
  "../bin:common_embedder_dart_io",   # dart:io natives
  "../bin:libdart_builtin",           # dart:core/_builtin
]
```

And `engine.cc:197` calls:

```cpp
bin::DartUtils::SetupCoreLibraries(..., bin::DartIoSettings{});
```

Before Zig can register a single native function, the engine has already wired:
- `IONativeLookup` as the resolver for `dart:io` (including `EventHandler_SendData`)
- `dart:_builtin`'s `print` hook
- The full epoll-backed event handler as the official I/O back-end

If you call `EventHandler_SendData` from `dart:async`'s `Timer` with no epoll thread
running → the interrupt pipe `write()` blocks the Dart isolate indefinitely.

**This is the primary blocker. Everything else is secondary.**

---

## Revised Architecture: Two Parallel Tracks

```
Track 1 (Fork)                          Track 2 (Host)
─────────────────                       ──────────────────
Fork runtime/engine                     Zig binary on top
Make SetupCoreLibraries injectable      io_uring event loop
Add create_group callback               timerfd / IORING_OP_TIMEOUT
Fix Shutdown leak                       stdio wiring
Re-export dart_engine.h                 signal bridge
               │                        GC idle notification
               └──── join here ─────────┘
                        │
                 Performance layer
                 (io_uring registered buffers,
                  SEND_ZC, splice, multi-core)
```

---

## Phase Overview — As-Built Status

> **Note:** Phase numbering diverged from the original spec during implementation.
> The table below reflects what was *actually built*, not the original plan.
> Original spec phases 1–9 are preserved below for reference.

| Phase | Goal | Status | Key Files |
|---|---|---|---|
| 0 | Build setup: SDK from source, pin commit | ✅ DONE | `build.zig`, `build.zig.zon` |
| 1 | Fork `runtime/engine`: injectable `DartIoSettings`, fix `Dart_Cleanup` shutdown | ✅ DONE | `runtime/engine/engine.cc`, `engine.h` |
| 2 | Zig host binary: replaces `dart`, loads `.dill`, boots isolate | ✅ DONE | `src/main.zig`, `src/engine.zig` |
| 3 | io_uring (Linux) + kqueue (macOS) event loop; `IORING_OP_TIMEOUT` for timers | ✅ DONE | `src/event_loop/io_uring.zig`, `kqueue.zig` |
| 4 | Full host: stdio wiring, `Dart_HasLivePorts` quiescence, `_startMainIsolate` | ✅ DONE | `src/main.zig` |
| 5 | GC idle (`Dart_NotifyIdle`) + signal handling (signalfd / EVFILT_SIGNAL) | ✅ DONE | `io_uring.zig`, `kqueue.zig` |
| 6 | Zig I/O natives via `Dart_SetNativeResolver`; thread-based async as scaffold | ✅ DONE | `src/zig_io/`, `lib/zig_io.dart` |
| 7 | Real async I/O: replace threads with io_uring SQEs / kqueue readiness | ✅ DONE | `src/zig_io/state.zig`, `natives/tcp.zig` |
| 8 | `Dart_PostCObject` for TcpRead data; `ZigIo_TcpWriteBytes`; echo server + benchmark | ✅ DONE | `engine.zig`, `tcp.zig`, `lib/echo_server.dart` |
| 9 | O(1) free-list pool allocator; benchmark correctness; SOCK.NONBLOCK; TCP_NODELAY | ✅ DONE | `state.zig`, `io_uring.zig`, `kqueue.zig` |
| 10 | io_uring inline write fast-path (Phase 10c): eliminate send SQE round-trip | ✅ DONE | `io_uring.zig` |
| 11 | AOT compilation support: `-Daot=true`, `DartEngine_AotSnapshotFromFile`, auto-detect by extension | ✅ DONE | `build.zig`, `engine.zig`, `main.zig` |
| **12** | **SO_REUSEPORT multicore: N isolates × N event loops, kernel-distributed accept** | ✅ **DONE** | `main.zig`, `tcp.zig` |
| 13 | HTTP/1.1 native parser in Zig; Dart receives structured `HttpRequest` | 📋 PLANNED | `src/http/parser.zig`, `lib/zig_http.dart` |
| 14 | Completion batching: N completions per Dart wakeup, reduce scheduler overhead | 📋 PLANNED | `event_loop/`, `state.zig` |
| 15 | TLS via BoringSSL: termination in Zig before bytes reach Dart | 📋 PLANNED | `src/tls/` |
| 16 | HTTP/2: h2c cleartext first, HPACK + stream mux, then TLS | 📋 PLANNED | `src/http2/` |
| 17 | HTTP/3 via quiche (Cloudflare): UDP path, QUIC, requires Phase 15 TLS | 📋 PLANNED | `src/quic/` |

---

## Phase 8: Echo Server + First Benchmark

**Goal:** Wire up real data flow (read → write), prove the round-trip works end-to-end,
and establish a baseline latency/throughput comparison against stock `dart` + `dart:io`.

### 8a — `Dart_PostCObject` for TcpRead

Currently `ZigIo_TcpRead` posts only the byte *count* as an integer. Replace with a
`Dart_CObject` payload so Dart receives an actual `Uint8List` (or `null` on EOF):

```zig
// engine.zig additions
pub const Dart_CObject_Type = c_int;
pub const Dart_CObject_kNull: Dart_CObject_Type = 0;
pub const Dart_CObject_kInt64: Dart_CObject_Type = 3;
pub const Dart_CObject_kTypedData: Dart_CObject_Type = 7;

pub const Dart_CObject = extern struct {
    @"type": Dart_CObject_Type,
    value: extern union {
        as_int64: i64,
        as_typed_data: extern struct {
            data_type: c_int,   // Dart_TypedData_Type
            length: isize,      // in elements, not bytes
            values: [*]const u8,
        },
        _pad: [40]u8,           // match C union size (as_external_typed_data = 40 bytes)
    },
};
pub extern fn Dart_PostCObject(port_id: Dart_Port, message: *Dart_CObject) bool;
```

In `dispatchPoolCqe` / `dispatchPoolEvent` for `.recv`:
- `n > 0` → post `Dart_CObject_kTypedData` with buffer slice (`Dart_PostCObject` copies)
- `n <= 0` → post `Dart_CObject_kNull` (EOF or error)
- Free heap buffer in both cases

### 8b — `ZigIo_TcpWriteBytes(fd, Uint8List, sendPort)`

Current `ZigIo_TcpWrite` walks `List<int>` element-by-element via `Dart_ListGetAt`
(O(n) VM calls). Add a typed-data variant using `Dart_TypedDataAcquireData` for a
single memcpy:

```dart
// lib/zig_io.dart
@pragma('vm:external-name', 'ZigIo_TcpWriteBytes')
external void zigIoTcpWriteBytes(int connFd, Uint8List bytes, SendPort sendPort);
```

```zig
// tcp.zig — ZigIo_TcpWriteBytes
pub fn ZigIo_TcpWriteBytes(args: engine.Dart_NativeArguments) callconv(.c) void {
    // Dart_TypedDataAcquireData → memcpy → Dart_TypedDataReleaseData → submit
}
```

### 8c — Echo server + benchmark

```
dart-zig/lib/echo_server.dart      — uses zig_io primitives
dart-zig/lib/dart_io_echo.dart     — identical logic with dart:io (baseline)
```

Benchmark with `wrk` or a simple Dart client:
- Metric: requests/sec (echo round-trips), latency P50/P99
- Platforms: macOS (kqueue) + Linux Docker (io_uring)

---

## Phase 9: True Zero-Copy (ExternalTypedData)

`Dart_PostCObject` with `kTypedData` **copies** bytes into the Dart heap. To eliminate
this copy, wrap the kernel-filled buffer directly as a Dart object:

```zig
// After io_uring recv CQE fires — no copy:
const dart_buf = engine.Dart_NewExternalTypedDataWithFinalizer(
    engine.Dart_TypedData_kUint8,
    buf_ptr,       // kernel-filled buffer
    bytes_received,
    buf_ptr,       // peer passed to finalizer
    bytes_received,
    bufFinalizer,  // returns buffer to pool when Dart GC collects
);
var obj = engine.Dart_CObject{
    .type = engine.Dart_CObject_kExternalTypedData,
    // ...
};
_ = engine.Dart_PostCObject(port_id, &obj);
```

Pair with **io_uring registered buffers** (`ring.register_buffers`) to pin the pool
in kernel page tables — eliminates the `iommu_map` on every I/O operation.

---

## Phase 12: SO_REUSEPORT Multicore ✅ DONE

One (Dart isolate + event loop) pair per CPU core. Kernel distributes incoming
connections across workers via `SO_REUSEPORT` — zero cross-thread coordination,
no mutex, no work-stealing.

### Design

```zig
// main.zig
const n_workers = try std.Thread.getCpuCount();
var threads = try allocator.alloc(std.Thread, n_workers);

for (0..n_workers) |i| {
    threads[i] = try std.Thread.spawn(.{}, workerMain, .{ snapshot_path, i });
}
for (threads) |t| t.join();

fn workerMain(snapshot_path: [:0]const u8, worker_id: usize) void {
    // Each worker: its own engine init, isolate, event loop
    // Listens on the same port via SO_REUSEPORT — kernel load-balances
    runWorker(snapshot_path, worker_id) catch |e| {
        std.debug.print("worker {d} fatal: {s}\n", .{ worker_id, @errorName(e) });
    };
}
```

### Key changes
- `main.zig`: detect `-workers=N` arg (default: `std.Thread.getCpuCount()`), spawn N threads each running `workerMain`
- `event_loop/kqueue.zig` + `io_uring.zig`: accept socket created with `SO_REUSEPORT` so kernel assigns connections to whichever worker's accept queue is free
- Each worker calls `DartEngine_Init` / `DartEngine_CreateIsolate` independently (engine supports multiple isolates)
- No shared state between workers — each isolate has its own pool, slot allocator, event loop

### Expected outcome
~N× throughput on N-core machine. M3 Pro has 11 performance cores → target: 2.5M+ req/s echo (AOT).

---

## Phase 13: HTTP/1.1 Native Parser ✅ DONE

Zig parses request line + headers. Dart receives a structured `HttpRequest` object,
not raw bytes. Body streaming stays Dart-side.

```zig
// src/http/parser.zig — zero-allocation state machine
const ParseResult = union(enum) {
    incomplete,
    complete: HttpRequest,
    error: ParseError,
};

const HttpRequest = struct {
    method: []const u8,
    path:   []const u8,
    // headers stored as index into raw buffer — no allocation
    headers: [32]Header,
    header_count: usize,
    body_offset: usize,
};
```

Dart side:
```dart
// lib/zig_http.dart
@pragma('vm:external-name', 'ZigHttp_Listen')
external void zigHttpListen(int port, void Function(HttpRequest req) handler);
```

---

## Phase 14: Completion Batching ✅ DONE

Instead of one `DartEngine_HandleMessage` per completion, accumulate up to N
completions in the event loop tick before notifying Dart. Reduces scheduler
overhead under high connection counts.

**Implemented:** Single `RawReceivePort` per isolate + `Map<int, Completer>` token
map. Zig posts one `Dart_CObject_kArray` (`[token0,val0,...]`) per `kevent()` batch.
`postSingleCompletion()` helper routes error/fast-path completions correctly in both
batch and legacy mode. Benchmark: **159k req/sec (c=128), 150k req/sec (c=400)** —
stable at high concurrency (was crashing in Phase 13 at c=400).

---

## Phase 15: TLS via BoringSSL ✅ DONE

BoringSSL is already in the SDK tree (Dart uses it internally). Link it from
Zig, do TLS termination before bytes reach the Dart handler. Required for
browser-facing HTTP/2 and for QUIC (HTTP/3).

**Completed 2026-03-21.** Memory BIOs (`BIO_new_bio_pair` ×2), TlsConn pool,
`advanceHandshake` kqueue state machine, synchronous `writePlaintext`,
`SSL_pending` fast-path for buffered post-handshake data. kqueue pipe wake-up
bug fixed (unconditional `pipe_w` write after `flushBatch`).
Benchmark: **50,643 HTTPS req/sec** (c=50, macOS, 1 worker).

---

## Phase 16: HTTP/2

h2c (cleartext) first for internal/gRPC use, then TLS-backed H2 after Phase 15.
HPACK header compression + stream multiplexing. Dart gets `Http2Stream` objects.

---

## Phase 17: HTTP/3 via quiche

Link Cloudflare's quiche C library for QUIC + HTTP/3. New UDP socket path in
Zig, separate from the TCP kqueue/io_uring backends. Requires Phase 15 (TLS 1.3
is mandatory for QUIC).

---

## Original Phase Overview (Corrected Difficulty Order)

---

## Phase 0: Build From Source

```sh
# Pin the exact commit so snapshot format matches
cd /Users/kartik/StudioProjects/dart-sdk
git rev-parse HEAD > DART_ZIG_SDK_COMMIT

# Full build (slow first time, ~20-40 min)
./tools/build.py --mode=release

# OR build just the engine targets (faster, after first full build):
ninja -C out/ReleaseX64 dart_engine_jit_shared dart_engine_aot_shared

# Output (Linux):  out/ReleaseX64/libdart_engine_jit_shared.so
#                  out/ReleaseX64/libdart_engine_aot_shared.so
# Output (macOS):  out/ReleaseX64/libdart_engine_jit_shared.dylib
#                  out/ReleaseX64/libdart_engine_aot_shared.dylib
```

> **IMPORTANT:** Link against `libdart_engine_{jit,aot}_shared.{so,dylib}` — NOT
> `libdart.so`. Use JIT for `.dill` kernel snapshots, AOT for `.so` compiled snapshots.
> You cannot mix them in one process. Also available as static libs:
> `dart_engine_jit_static`, `dart_engine_aot_static`.

---

## Phase 1: Fork runtime/engine (Blocker)

**Goal:** Make `SetupCoreLibraries` injectable and break the hard `dart:io` coupling.

### [MODIFY] `runtime/engine/engine.h`

Add `DartZigIoHooks` struct to allow overriding the `dart:io` setup:

```cpp
// New: injectable I/O hooks — pass nullptr to use stock dart:io
struct DartZigIoHooks {
  // Called instead of bin::DartUtils::SetupCoreLibraries
  // Return Dart_Handle error or Dart_Null()
  Dart_Handle (*setup_core_libs)(Dart_Isolate isolate, void* ctx);
  // Called to register native resolver for dart:io (or your replacement)
  Dart_Handle (*register_io_natives)(Dart_Handle library, void* ctx);
  void* context;
};
```

### [MODIFY] `runtime/engine/engine.cc:StartIsolate`

```cpp
// Replace the hardcoded SetupCoreLibraries call:
if (hooks_.setup_core_libs != nullptr) {
  core_libs_result = hooks_.setup_core_libs(isolate, hooks_.context);
} else {
  // Stock path — sets up dart:io with epoll backend
  core_libs_result = bin::DartUtils::SetupCoreLibraries(
      false, false, false, bin::DartIoSettings{});
}
```

### [MODIFY] `runtime/engine/engine.cc:Shutdown`

Fix the resource leak — `Shutdown` currently never calls `Dart_Cleanup`:

```cpp
void Engine::Shutdown() {
  // ... existing isolate shutdown ...

  // ADD: properly cleanup the VM
  char* error = Dart_Cleanup();
  if (error != nullptr) {
    Syslog::PrintErr("Dart_Cleanup error: %s\n", error);
    free(error);
  }
  dart::embedder::Cleanup();
}
```

### [MODIFY] `runtime/engine/engine.cc:CreateInitializeParams`

```cpp
// Add create_group callback — fixes Isolate.spawn
params.create_group = Engine::CreateGroupCallback;
params.initialize_isolate = Engine::InitializeIsolateCallback;
```

---

## Phase 2: Zig Host Binary

### Fix: Manual Zig struct for anonymous union

`@cImport` cannot translate `DartEngine_SnapshotData`'s anonymous union. Manually define:

```zig
// src/engine.zig — manual translation of dart_engine.h
pub const SnapshotKind = enum(c_int) {
    Kernel = 0,
    Aot    = 1,
};

// Manual struct — @cImport would fail on anonymous union
pub const SnapshotData = extern struct {
    script_uri: [*c]const u8,
    kind: SnapshotKind,
    _data: extern union {
        kernel: extern struct {
            kernel_buffer:      [*c]const u8,
            kernel_buffer_size: isize,
            _pad: [2]isize,
        },
        aot: extern struct {
            vm_snapshot_data:         [*c]const u8,
            vm_snapshot_instructions: [*c]const u8,
            vm_isolate_data:          [*c]const u8,
            vm_isolate_instructions:  [*c]const u8,
        },
    },
};
```

### [NEW] `src/main.zig`

```zig
pub fn main() !void {
    // 1. Init engine with our custom hooks (no dart:io epoll backend)
    var hooks = engine.DartZigHooks{
        .setup_core_libs     = zigSetupCoreLibs,
        .register_io_natives = zigRegisterIoNatives,
        .context             = &global_loop,
    };
    try engine.initWithHooks(&hooks);

    // 2. Start event loop + isolate
    var loop = try EventLoop.init();
    engine.setDefaultScheduler(.{
        .schedule_callback = EventLoop.scheduleCallback,
        .context = &loop,
    });

    const snapshot = try engine.kernelFromFile(snapshot_path);
    const isolate  = try engine.createIsolate(snapshot);
    try registerNatives(isolate);
    try loop.run();
    engine.shutdown(); // now calls Dart_Cleanup
}
```

---

## Phase 3: io_uring Event Loop + Timers

### Key: `IORING_OP_TIMEOUT` replaces `timerfd`

The existing event handler uses `timerfd_create()` registered with epoll for
`Timer` / `Future.delayed`. The Zig equivalent uses io_uring's native timeout:

```zig
// event_loop.zig — timer handling
fn scheduleTimer(self: *EventLoop, millis: i64, dart_port: c.Dart_Port) !void {
    const entry = try self.alloc.create(CompletionEntry);
    entry.* = .{ .tag = .timer, .dart_port = dart_port };
    var ts = std.os.linux.kernel_timespec{
        .tv_sec  = @divTrunc(millis, 1000),
        .tv_nsec = @mod(millis, 1000) * 1_000_000,
    };
    _ = try self.ring.timeout(@intFromPtr(entry), &ts,
        0, std.os.linux.IORING_TIMEOUT_ABS);
    _ = try self.ring.submit();
}

// completion handler:
.timer => {
    _ = c.Dart_PostNull(entry.dart_port);
},
```

### GC idle notification

```zig
// In the event loop, between completion batches:
fn runOnce(self: *EventLoop) !void {
    const count = try self.ring.copy_cqes(&self.cqes, 0); // non-blocking
    if (count == 0) {
        // Idle — tell the GC it has time to work
        const deadline_us = std.time.microTimestamp() + 5_000; // 5ms window
        c.Dart_NotifyIdle(deadline_us);
        _ = try self.ring.copy_cqes(&self.cqes, 1); // block until next event
    }
    // process completions...
}
```

---

## Phase 4: Full Host Responsibilities

### stdio setup (makes `print()` work)

```zig
fn setupStdio(isolate: engine.Isolate) !void {
    engine.acquireIsolate(isolate);
    defer engine.releaseIsolate();
    c.Dart_EnterScope();
    defer c.Dart_ExitScope();

    const io_lib = c.Dart_LookupLibrary(
        c.Dart_NewStringFromCString("dart:io"));
    // Note: entry point is _setupHooks, not _setupStdio
    _ = c.Dart_Invoke(io_lib,
        c.Dart_NewStringFromCString("_setupHooks"), 0, null);
    _ = c.Dart_SetEnvironmentCallback(platformEnvCallback, null);
}
```

### Signal handling

```zig
fn setupSignals(loop: *EventLoop) !void {
    const sig_fd = try std.posix.signalfd(-1,
        &.{ .INT = true, .TERM = true, .HUP = true }, 0);
    try loop.registerFd(sig_fd, .signal);
}

// On completion:
.signal => {
    // Read signalfd_siginfo, map to Dart ProcessSignal port
    c.Dart_PostInteger(signal_port, signo);
},
```

### Microtask draining (critical after every native→Dart call)

```zig
// After every ZigHttp_Respond or other Zig→Dart invocation:
fn drainMicrotasks(isolate: engine.Isolate) void {
    engine.acquireIsolate(isolate);
    defer engine.releaseIsolate();
    c.Dart_EnterScope();
    defer c.Dart_ExitScope();
    _ = c.DartEngine_DrainMicrotasksQueue();
}
```

---

## Phase 5: Zig I/O Natives (after resolver override)

After Phase 1's `register_io_natives` hook is in place, register Zig functions
before the stock `IONativeLookup` runs. The hook gives first-refusal on native
resolution — check Zig table first, fall through to `IONativeLookup` for anything
not yet implemented. This enables incremental replacement of `dart:io`.

```zig
fn zigRegisterIoNatives(library: c.Dart_Handle, ctx: ?*anyopaque) callconv(.C) c.Dart_Handle {
    // Override dart:io's resolver — our table is checked first
    return c.Dart_SetNativeResolver(library, zigNativeLookup, zigNativeSymbol);
}

// zigNativeLookup: check Zig table, then fall through to stock IONativeLookup
pub export fn zigNativeLookup(
    name: c.Dart_Handle,
    argument_count: c_int,
    auto_setup_scope: *bool,
) callconv(.C) c.Dart_NativeFunction {
    auto_setup_scope.* = true;
    // ... check native_table ...
    // Fall through to public exported wrapper (NOT IONativeLookup — that's internal only)
    // LookupIONative is exported via runtime/include/bin/dart_io_api.h
    return c.LookupIONative(name, argument_count, auto_setup_scope);
}
```

---

## Phase 6: True Zero-Copy with ExternalTypedData

`Dart_PostCObject` copies bytes into Dart heap. For true zero-copy:

```zig
// Register fixed buffers with io_uring (pinned in kernel page tables)
const BUF_SIZE  = 4096;
const BUF_COUNT = 256;
var buf_pool: [BUF_COUNT][BUF_SIZE]u8 = undefined;
try ring.register_buffers(&buf_pool);

// On recv completion — wrap kernel-filled buffer as Dart object WITHOUT copy:
fn onRecvComplete(cqe: io_uring_cqe, dart_port: c.Dart_Port, buf_id: usize) void {
    const bytes   = @intCast(usize, cqe.res);
    const buf_ptr = &buf_pool[buf_id];

    // Dart_NewExternalTypedDataWithFinalizer wraps C memory as Dart Uint8List
    // Finalizer returns the buffer to our pool when Dart GC collects it
    const dart_bytes = c.Dart_NewExternalTypedDataWithFinalizer(
        c.Dart_TypedData_kUint8,
        buf_ptr,
        bytes,
        buf_ptr,        // peer passed to finalizer
        bytes,
        bufferFinalizer,
    );
    _ = c.Dart_PostCObject(dart_port, &dart_bytes);
}

fn bufferFinalizer(isolate_group: ?*anyopaque, peer: ?*anyopaque) callconv(.C) void {
    const buf = @ptrCast(*[BUF_SIZE]u8, @alignCast(@alignOf([BUF_SIZE]u8), peer));
    buf_pool_return(buf);
}
```

### SEND_ZC caveat

`IORING_OP_SEND_ZC` requires the send buffer to remain stable until the kernel
ACKs the send. Since Dart's GC can move heap objects, the send buffer must be a
Zig-owned buffer — copy the Dart response into a Zig buffer, submit `SEND_ZC`,
then free after the `IORING_CQE_F_NOTIF` completion signals the kernel is done.

---

## Phase 7: Multi-Core via create_group + SO_REUSEPORT

One (Dart isolate, io_uring ring) pair per CPU core. The kernel distributes
connections via `SO_REUSEPORT` with zero cross-thread coordination:

```zig
// main.zig
const num_workers = try std.Thread.getCpuCount();
var workers = try alloc.alloc(Worker, num_workers);
for (workers) |*w| {
    w.* = try Worker.init(snapshot, listen_fd);
    _ = try std.Thread.spawn(.{}, Worker.run, .{w});
}

const Worker = struct {
    loop:    EventLoop,
    isolate: engine.Isolate,

    fn init(snapshot: SnapshotData, listen_fd: std.posix.fd_t) !Worker {
        var loop    = try EventLoop.init(); // each worker has its own ring
        const isolate = try engine.createIsolate(snapshot);
        try loop.startAccepting(listen_fd); // SO_REUSEPORT distributes
        return .{ .loop = loop, .isolate = isolate };
    }
    fn run(self: *Worker) void { self.loop.run() catch {}; }
};
```

---

## Risk Table

| Risk | Severity | Mitigation |
|---|---|---|
| `engine/BUILD.gn` hardlinks `runtime/bin` | **Blocker** | Phase 1 fork — injectable hooks |
| `dart_engine.h` not in shipped SDK | **Blocker** | Build from SDK source, pin commit |
| `Isolate.spawn` broken (`create_group = nullptr`) | **Blocker for servers** | Phase 1 `create_group` callback |
| `dart:io` resolver registered before Zig runs | Architectural | Phase 1 hook gives first-refusal |
| `Dart_PostCObject` copies bytes | Performance | Phase 6 `ExternalTypedData` |
| `@cImport` fails on anonymous union | Build | Phase 2 manual Zig struct |
| `Timer`/`Future.delayed` hangs without event handler | Functional | Phase 3 `IORING_OP_TIMEOUT` |
| `print()` silent without stdio setup | Functional | Phase 4 `_setupStdio` invoke |
| Signal handling not replicated | Functional | Phase 4 `signalfd` + io_uring |
| GC never notified of idle time | Latency spikes | Phase 3 `Dart_NotifyIdle` |
| Microtasks dropped after native calls | Broken `Future` chains | Phase 4 `DrainMicrotasksQueue` |
| `Engine::Shutdown` leaks VM resources | Production | Phase 1 — add `Dart_Cleanup` |
| `SEND_ZC` breaks with GC-moved Dart buffers | Correctness | Phase 6 — Zig-owned buffers only |
| Snapshot format instability | Maintenance | Pin SDK commit hash in `build.zig` |
| JIT vs AOT = different `.so` files | Build | Separate `dart-zig-jit` / `dart-zig-aot` targets |

---

## Phase 8+: Bigger Opportunities

| Opportunity | Why it matters |
|---|---|
| `IORING_OP_SPLICE` for file serving / proxying | Kernel-to-kernel transfer, no userspace buffer at all |
| HTTP/2 multiplexing in Zig | Streams map naturally to SQ batches; Dart only sees app logic |
| Zig `comptime` native table generation | Auto-generate both Zig `native_table` and `dart_zig_io.dart` `@pragma` declarations from one source |
| Hot reload via `CreateVmServiceIsolateFromKernel` | Wire `dart_embedder_api.h` to enable kernel patching on running isolates |
| Dart service protocol (Observatory) | `dart_embedder_api.h:CreateVmServiceIsolate` — enables profiling, heap inspection |

---

## Key File Locations (SDK Source Tree)

| File | Relevance |
|---|---|
| `runtime/engine/include/dart_engine.h` | Primary embedding API |
| `runtime/engine/engine.cc` | Engine implementation — target for Phase 1 fork |
| `runtime/engine/BUILD.gn` | Build deps — shows `runtime/bin` entanglement |
| `runtime/bin/eventhandler_linux.cc` | epoll implementation being replaced |
| `runtime/bin/io_natives.cc` | `IO_NATIVE_LIST` — native function table pattern |
| `runtime/bin/dartutils.cc:559` | `SetupCoreLibraries` — what engine calls, what we replace |
| `runtime/include/bin/dart_io_api.h` | `DartIoSettings` struct + `SetupDartIoLibrary` |
| `runtime/include/dart_embedder_api.h` | `InitOnce`, `CreateVmServiceIsolate` |
| `runtime/include/dart_api.h` | Full public VM API — `Dart_NotifyIdle`, `ExternalTypedData`, etc. |
| `samples/embedder/run_timer_async.cc` | Closest working example to our target architecture |
