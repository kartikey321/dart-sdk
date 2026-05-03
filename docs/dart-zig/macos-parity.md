# dart-zig macOS Parity Plan

Last updated: 2026-05-03

This document defines what "macOS parity" should mean for `dart-zig`.

It is intentionally different from
`docs/dart-zig/macos-gap-review.md`:

- `macos-gap-review.md` is the audit record of what is currently wrong
- `macos-parity.md` is the target-state checklist for when the `kqueue`
  backend can be considered at Linux parity for the current runtime scope

## Goal

The goal is not "feature parity with all of `dart:io`".

The goal is:

- parity with the current `dart-zig` runtime scope
- parity of backend correctness between Linux `io_uring` and macOS `kqueue`
- enough validation that macOS can be treated as a production-capable backend,
  not just a development backend

## Scope

Backend parity here covers:

- TCP accept / recv / send / close
- batch dispatcher behavior
- fused HTTP fast path behavior
- keep-alive and pipelining behavior
- isolate wakeup / scheduler behavior
- shutdown behavior
- JIT and AOT runtime behavior at the backend boundary

It does not mean:

- full `dart:io` replacement
- TLS parity beyond what the current runtime already supports
- HTTP/2 or HTTP/3 parity

## Parity Criteria

macOS should only be called parity-ready when all of the following are true.

### 1. Socket write behavior matches Linux safety guarantees

Required outcomes:

- client disconnects during write do not terminate the process
- socket writes surface recoverable errors instead of `SIGPIPE`
- all hot-path write sites are covered, not just one code path

Implementation target:

- `SO_NOSIGPIPE` or equivalent protection is consistently applied
- direct `posix.write()` call sites are audited after the protection is added

### 2. Partial writes are fully handled

Required outcomes:

- large or backpressured responses are never silently truncated
- send completion means "all requested bytes sent", not "one write happened"
- async re-arming semantics match the Linux send-state model

Implementation target:

- macOS `.send` path retains unsent bytes
- `EVFILT_WRITE` is re-armed until completion or hard error
- slot lifetime remains correct across partial sends

### 3. Read semantics match Linux

Required outcomes:

- recv and TLS recv honor the requested `maxBytes`
- higher layers never receive more than the requested cap
- request framing logic sees equivalent bounded-read behavior on both backends

Implementation target:

- `max_len` or equivalent cap is enforced in `kqueue.zig`

### 4. Wakeup and microtask behavior match Linux

Required outcomes:

- pending scheduler callbacks are drained consistently
- microtasks are drained after wakeup the same way they are on Linux
- backend differences do not change async completion ordering in surprising ways

Implementation target:

- macOS wakeup path loops until pending work is drained
- microtask draining mirrors Linux notify-path semantics

### 5. Multi-worker shutdown is coordinated

Required outcomes:

- `SIGINT` and `SIGTERM` stop all workers, not just one
- main thread does not hang waiting on surviving worker loops
- shutdown semantics are the same across Linux and macOS worker mode

Implementation target:

- shared runtime shutdown state is used by both backends
- each worker observes shutdown on wakeup and exits cleanly

### 6. JIT runtime behavior is not backend-fragile

Required outcomes:

- macOS does not regress badly in hot loops that stay inside Zig
- isolate safepoint behavior is not materially weaker than Linux
- JIT-mode behavior is predictable in single-worker and multi-worker runs

Implementation target:

- port Linux-style periodic safepoint mitigation or equivalent mechanism

### 7. Fused HTTP fast path behavior matches Linux

Required outcomes:

- keep-alive loop behavior is equivalent
- pipelined requests in one recv buffer are processed correctly
- buffer rollover / memmove / re-arm behavior is equivalent under load
- connection close semantics match Linux on EOF and error

Implementation target:

- rerun HTTP/1.1 keep-alive and pipelining checks on macOS after backend fixes

### 8. Public docs stop overstating Linux-specific assumptions

Required outcomes:

- docs do not imply Linux-only runtime architecture
- docs do not imply parity before it is earned
- macOS support level is described accurately

Implementation target:

- public references consistently say:
  - `io_uring` on Linux
  - `kqueue` on macOS
- README and benchmark notes clearly separate:
  - Linux validated state
  - macOS historical or pending state

## Minimum Validation Matrix

Before calling macOS parity-ready, rerun at least this matrix on macOS:

### Correctness

1. accept loop under sustained connection churn
2. recv with varying `maxBytes`
3. large response writes that force partial-send behavior
4. client disconnect during write
5. keep-alive with multiple sequential requests on one connection
6. pipelined requests buffered in one recv
7. multi-worker startup and shutdown with `SIGINT`

### Runtime mode coverage

1. JIT single-worker
2. JIT multi-worker
3. AOT single-worker
4. AOT multi-worker

### Comparison expectations

Parity does not require identical req/s numbers across Linux and macOS.

Parity does require:

- equivalent correctness
- equivalent lifecycle semantics
- no backend-specific crash modes
- no backend-specific truncation or scheduler bugs

## Exit Criteria

macOS can be described as parity-ready for the current runtime scope when:

1. all parity criteria above are met
2. the critical and major items in `macos-gap-review.md` are closed
3. the validation matrix passes on real macOS hardware
4. the README is updated to remove the "not yet at Linux correctness parity"
   caveat

## Suggested Work Order

Recommended implementation order:

1. `SIGPIPE` protection
2. partial-send retention and `EVFILT_WRITE` re-arming
3. recv `maxBytes` parity
4. shared shutdown propagation
5. wakeup + microtask drain parity
6. JIT safepoint mitigation
7. validation reruns
8. documentation update

This order is deliberate:

- first eliminate crash risk
- then eliminate silent corruption
- then align runtime semantics
- then validate and update claims

