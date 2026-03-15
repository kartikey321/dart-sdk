# Phase 4 — Platform Event Loop (io_uring + kqueue)

**Started:** 2026-03-12
**Completed:** —
**Status:** IN-PROGRESS

## Goal
Replace the ad-hoc `std::async(DartEngine_HandleMessage, isolate)` dispatch pattern
with a proper event loop backed by io_uring (Linux) or kqueue (macOS).

Install a `DartEngine_MessageScheduler` that wakes the event loop when Dart
posts a message. The event loop calls `DartEngine_HandleMessage` on wake-up.

**No change to SetupCoreLibraries yet** — epoll still handles dart:io I/O.
This phase is pure dispatch layer.

## Prerequisite
Phase 3 complete ✅

## Success Criteria
- [ ] `src/event_loop/common.zig` — comptime dispatch: `io_uring.zig` on Linux, `kqueue.zig` on macOS
- [ ] `src/event_loop/io_uring.zig` — eventfd + IoUring event loop (Linux)
- [ ] `src/event_loop/kqueue.zig` — pipe + kqueue event loop (macOS)
- [ ] `engine.zig` additions: `DartEngine_MessageScheduler` struct + `DartEngine_SetDefaultMessageScheduler`
- [ ] `main.zig` updated: install scheduler, invoke `main()`, run event loop
- [ ] Smoke test (macOS): `dart-zig hello_kernel.dart.snapshot` → `hi, world!` (event loop version)
- [ ] Regression (Linux Docker): `dart-zig timer_kernel.dart.snapshot` → `Ticks: ~103`

## Key Architecture

### Why This Works Without Touching SetupCoreLibraries
```
Dart VM (epoll-backed dart:io)
     │
     │  Timer fires → Dart posts message to isolate
     │
     ▼
DartEngine_MessageScheduler.schedule_callback(isolate, ctx)
     │                                             ▲
     │  write(eventfd, 1)                          │
     ▼                                             │
io_uring waits on eventfd  ──── wake up ──► DartEngine_HandleMessage(isolate)
```

The epoll event handler manages I/O fds and timer registration.
Our scheduler intercepts the "message is ready" notification and
drives `DartEngine_HandleMessage` from our event loop thread.

### schedule_callback Contract
- Called from a Dart VM thread that holds internal locks
- Must be FAST and NON-BLOCKING (write to fd and return)
- Must NOT call any Dart C API from inside the callback

### Event Loop Termination
- Track active message count via atomic counter
- Decrement after each `DartEngine_HandleMessage`
- Exit loop when counter reaches 0 AND no new schedule_callback fires for N ms
- Or: `DartEngine_Shutdown` signal via SIGTERM handler (Phase 5)

## Files to Create/Modify

| File | Action |
|------|--------|
| `src/event_loop/common.zig` | New — interface + comptime dispatch |
| `src/event_loop/io_uring.zig` | New — Linux backend |
| `src/event_loop/kqueue.zig` | New — macOS backend |
| `src/engine.zig` | Add: `DartEngine_MessageScheduler`, `DartEngine_SetDefaultMessageScheduler`, `DartEngine_SetMessageScheduler` |
| `src/main.zig` | Update: create event loop, install scheduler, run loop |
| `build.zig` | No changes needed (comptime dispatch handles platform selection) |

## Implementation Notes

### src/event_loop/common.zig
```zig
const builtin = @import("builtin");

pub const EventLoop = switch (builtin.os.tag) {
    .linux => @import("io_uring.zig").EventLoop,
    .macos => @import("kqueue.zig").EventLoop,
    else   => @compileError("unsupported platform for event loop"),
};
```

### src/event_loop/io_uring.zig (Linux)
```zig
// Uses std.os.linux.IoUring (Zig stdlib — no liburing dep needed)
// eventfd for wake-up signal from schedule_callback
// submit_and_wait(1) to block until event arrives
// IORING_OP_READ on eventfd fd
```

### src/event_loop/kqueue.zig (macOS)
```zig
// Uses std.posix.kqueue + kevent
// EVFILT_READ on read end of a pipe (write end used in schedule_callback)
// kevent() with null timeout = block until event
```

### engine.zig additions
```zig
pub const MessageScheduler = extern struct {
    schedule_callback: ?*const fn (isolate: DartHandle, context: ?*anyopaque) callconv(.c) void,
    context: ?*anyopaque,
};
pub extern fn DartEngine_SetDefaultMessageScheduler(scheduler: MessageScheduler) void;
pub extern fn DartEngine_SetMessageScheduler(scheduler: MessageScheduler, isolate: DartHandle) void;
```

### main.zig flow
```
1. DartEngine_Init
2. DartEngine_KernelFromFile
3. Create EventLoop (opens eventfd/pipe)
4. DartEngine_SetDefaultMessageScheduler(scheduler)
5. DartEngine_CreateIsolate
6. DartEngine_AcquireIsolate + Dart_Invoke("main") + DartEngine_ReleaseIsolate
7. event_loop.run()  ← blocks until quiescent
8. DartEngine_Shutdown
```

## Environment
- Linux build: Docker ARM64 Ubuntu 22.04, kernel 6.10.14-linuxkit
- Engine SO: `out/ReleaseARM64/libdart_engine_jit_shared.so` (when Docker build completes)
- macOS dev: test with kqueue backend, validate with hello snapshot
- Zig: 0.15.2

## Regression Test (Linux Docker)
```sh
docker run --rm -v /Users/kartik/StudioProjects:/workspace dart-zig-builder \
  /workspace/sdk/dart-zig/zig-out/bin/dart-zig \
  /workspace/sdk/out/ReleaseARM64/gen/timer_kernel.dart.snapshot
# Must print non-zero Ticks
```

## Session Log
(no sessions yet)

## Blockers
| # | Blocker | Discovered | Resolved |
|---|---------|-----------|---------|

## Resolved Blockers
| # | Blocker | Resolution | Date |
|---|---------|-----------|------|

## Artifacts
(none yet)
