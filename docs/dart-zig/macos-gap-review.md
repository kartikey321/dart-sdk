# dart-zig macOS Gap Review

Last updated: 2026-05-03

This document captures the current production-readiness gaps in the macOS
`kqueue` backend relative to the Linux `io_uring` backend. The goal is to make
later work resumable without redoing the backend audit.

## Scope

Files reviewed:

- `dart-zig/src/event_loop/kqueue.zig`
- `dart-zig/src/event_loop/io_uring.zig`
- `dart-zig/src/zig_io/state.zig`
- `dart-zig/src/zig_io/natives/tcp.zig`
- `dart-zig/src/http/parser.zig`

This review is focused on backend parity and production safety, not feature
parity with all of `dart:io`.

## Summary

Current status:

- Linux is the production-first backend.
- macOS is implemented, but not yet at Linux correctness parity.
- The largest remaining risks are in the macOS send path, signal behavior, and
  event-loop scheduling semantics.

The main conclusion is straightforward: macOS should be treated as supported for
development and experimentation, but not yet as equally production-safe as
Linux.

## Critical Gaps

### 1. `SIGPIPE` risk on socket writes

Affected code in `dart-zig/src/event_loop/kqueue.zig`:

- line 272
- line 395
- line 428
- line 450
- line 477
- line 498
- line 540
- line 751
- line 777
- line 800
- line 1052

The macOS backend uses plain `posix.write()` on TCP sockets in multiple hot
paths. Unlike the Linux `io_uring` send path, there is no visible suppression of
`SIGPIPE` such as `MSG_NOSIGNAL`, and there is no `SO_NOSIGPIPE` setup on the
socket.

Risk:

- A peer that closes at the wrong time can trigger `SIGPIPE`.
- That can terminate the worker or process instead of surfacing a recoverable
  write error.

Minimum fix:

- Set `SO_NOSIGPIPE` on accepted and connected sockets on macOS.
- Audit all direct `posix.write()` socket paths after that change to ensure they
  rely on the socket option consistently.

Notes:

- This is a release blocker for macOS production traffic.

### 2. Short writes are treated as full success

Affected code in `dart-zig/src/event_loop/kqueue.zig`:

- line 540
- line 800
- line 1046

The macOS send path writes once and treats the result as terminal success. If
the kernel accepts only part of the buffer, the remainder is not tracked and the
slot is freed as if the full payload was sent.

Risk:

- Response truncation under backpressure.
- Silent data corruption from the application point of view.
- Divergent behavior from Linux once Linux partial-send tracking is enabled.

Minimum fix:

- Mirror the Linux send-state model in `kqueue.zig`.
- Retain remaining bytes in the slot.
- Re-arm `EVFILT_WRITE` until the buffer is fully written or a hard error
  occurs.

Notes:

- This is the most important backend parity fix after `SIGPIPE`.

## Major Gaps

### 3. Read operations ignore the caller's `maxBytes`

Affected code in `dart-zig/src/event_loop/kqueue.zig`:

- line 337
- line 359
- line 374
- line 689
- line 709
- line 719

The macOS backend reads into the full embedded buffer rather than honoring the
read cap requested by the caller. On Linux, the intent is that recv operations
respect the requested maximum length.

Risk:

- Higher layers can receive more bytes than requested.
- Behavior diverges from Linux in code that assumes bounded reads.
- This can interact badly with framing and body handling logic.

Minimum fix:

- Port the same `max_len` handling used in the Linux path into the macOS recv
  and TLS recv paths.

### 4. Message wakeup and microtask draining are weaker than Linux

Affected code in `dart-zig/src/event_loop/kqueue.zig`:

- line 202
- line 206

Relevant Linux reference in `dart-zig/src/event_loop/io_uring.zig`:

- line 172
- line 175
- line 186
- line 190

Linux drains pending scheduler callbacks in a loop and explicitly calls
`DartEngine_DrainMicrotasksQueue()`. The macOS pipe wakeup path batches pending
message handling, but does not mirror the same re-check and microtask-drain
semantics.

Risk:

- Different ordering and latency of async continuations.
- Potential starvation or delayed progress for recursively scheduled work.
- Harder-to-debug backend-specific behavior differences.

Minimum fix:

- Make the macOS wakeup path mirror the Linux notify path.
- After each message-handling pass, drain microtasks.
- Re-check the pending counter before finishing the wakeup cycle.

### 5. Multi-worker shutdown semantics are not aligned

Affected code in `dart-zig/src/event_loop/kqueue.zig`:

- line 182

Relevant Linux reference in `dart-zig/src/event_loop/io_uring.zig`:

- line 197

The macOS signal path exits the current loop on signal delivery, but it does not
yet clearly mirror the shared shutdown propagation that was added on the Linux
side during audit work.

Risk:

- One worker stops while siblings continue waiting.
- Main thread can block on joins during shutdown.
- Ctrl-C behavior can differ between backends.

Minimum fix:

- Use the same shared runtime shutdown state on both backends.
- Ensure all workers observe shutdown on their next wakeup and exit cleanly.

Notes:

- This should be fixed before claiming multi-worker production readiness on
  macOS.

## Moderate Gaps

### 6. No JIT safepoint mitigation equivalent to Linux

Relevant Linux reference in `dart-zig/src/event_loop/io_uring.zig`:

- line 142
- line 248
- line 249

The Linux backend includes a periodic safepoint/yield mechanism for JIT
workloads when the hot loop keeps traffic inside Zig and does not naturally post
back into Dart. The macOS backend does not appear to have an equivalent.

Risk:

- Different performance or scheduler behavior under JIT.
- Potentially worse behavior on single-core or pinned-worker setups.

Minimum fix:

- Port the same periodic isolate acquire/release or equivalent safepoint logic
  into the macOS loop.

Notes:

- This is not as urgent as correctness bugs, but it matters for backend parity.

### 7. Documentation still reads as Linux-first

Examples:

- comments and examples that describe the runtime as "io_uring-backed"

The codebase now clearly has both Linux and macOS backends, but some docs and
example language still describe the system in Linux-only terms.

Risk:

- Confusing expectations for users and future maintainers.
- Makes it harder to communicate which parts are cross-platform and which are
  Linux-first.

Minimum fix:

- Update public docs and examples to consistently say:
  - `io_uring` on Linux
  - `kqueue` on macOS

## Recommended Fix Order

Suggested order for actual implementation:

1. `SIGPIPE` suppression on macOS sockets
2. Partial-send tracking and `EVFILT_WRITE` re-arming
3. `maxBytes` parity for recv paths
4. Shared shutdown propagation across workers
5. Message wakeup and microtask drain parity
6. JIT safepoint mitigation
7. Documentation cleanup

This order is intentional:

- first stop hard crashes
- then stop silent truncation
- then align API semantics
- then align scheduler behavior

## Validation Plan

After the fixes above, re-run the following on macOS:

1. Basic TCP echo tests
2. HTTP keep-alive tests
3. Large response tests that force partial writes
4. Abrupt client disconnect tests during write
5. Multi-worker shutdown tests with `SIGINT`
6. JIT and AOT smoke tests
7. Throughput comparison between Linux and macOS on equivalent workloads

Specific checks to add:

- client closes during response write must not kill the process
- large responses must be fully sent under backpressure
- recv must never exceed requested `maxBytes`
- pending microtasks must continue draining after wakeup
- all workers must terminate on process shutdown

## Handoff Notes

Important branch context:

- canonical remote branch is `fork/dart-zig`
- clean upstream-based local worktree is `/home/kartik/testing/sdk-mainbase`
- old `dart-zig-test` branch is historical only and should not be used as the
  active base for new work

Practical guidance for the next session:

- make macOS changes in `sdk-mainbase`
- preserve Linux behavior while porting the parity fixes
- test the `kqueue` path directly instead of assuming the Linux fixes carry over

