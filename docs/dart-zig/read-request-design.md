# ZigHttpServer `read_request` Design

## Problem

`ZigHttpServer` still uses Dart to orchestrate connection-level request assembly:

1. `zigIoTcpReadFuture()` posts a raw `Uint8List` chunk to Dart.
2. Dart appends that chunk into a per-connection `recvBuf`.
3. Dart calls `frameHttpRequest()` to ask Zig where the request ends.
4. Dart shifts pipelined leftover bytes in `recvBuf`.
5. Dart repeats until the next request is complete.

Moving header/body framing into Zig removed the worst repeated header scans, but it did not change the larger boundary shape:

- one Dart completion per recv chunk
- one Dart-owned connection buffer per connection
- Dart-owned pipelining state
- Dart-managed request assembly loop

The next step is to replace the raw chunk API for `ZigHttpServer` with a native `read_request` operation that owns:

- recv accumulation
- request completeness detection
- pipelined leftover bytes
- connection keep-alive state

Dart should receive one completion per request, not one completion per recv chunk.

## Goals

1. Remove Dart-side connection buffering from `ZigHttpServer`.
2. Reuse the existing native connection-state model already used by `.serve` and `.loop`.
3. Keep the public `ZigHttpServer` handler API close to its current shape.
4. Avoid introducing native external body buffers in the first phase.
5. Preserve correctness for:
   - fragmented TCP reads
   - pipelined keep-alive requests
   - `Content-Length`
   - chunked request bodies

## Non-Goals

1. Do not move response construction into Zig.
2. Do not introduce external typed data / finalizer-backed request bodies in phase 1.
3. Do not replace the fused `.serve` or `.loop` fast paths.
4. Do not solve streaming uploads in this phase.

## Existing Native Building Blocks

The native runtime already has the state model needed for `read_request`.

### `state.CompletionCtx.Data.serve`

`ServeData` already contains:

- `recv_buf: [kBufSize]u8`
- `recv_len: usize`
- `write_phase: bool`
- `pending_consumed: usize`

That is already enough to model:

- bytes accumulated so far for one connection
- how many bytes of the current request were consumed
- what bytes remain after a pipelined request is served

### `io_uring.processLoopPipeline`

The loop path already proves the backend can:

1. accumulate data in a native per-connection buffer
2. parse one request
3. retain leftover pipelined bytes
4. continue serving the same connection without returning to Dart

`read_request` should reuse that state shape, but post a framed request to Dart instead of routing to a static native response.

## Proposed Contract

Introduce a new async token-based native op:

- `ZigIo_TcpReadRequestToken(connFd: int, token: int) -> void`

and a Dart wrapper:

- `Future<FramedRequestResult?> zigIoTcpReadRequestFuture(int connFd)`

Where `FramedRequestResult` is:

```dart
class FramedRequestResult {
  final String method;
  final String path;
  final Uint8List bodyBytes;
  final bool keepAlive;
  final bool chunked;

  const FramedRequestResult(
    this.method,
    this.path,
    this.bodyBytes,
    this.keepAlive,
    this.chunked,
  );
}
```

Result semantics:

- returns `null` on EOF or terminal read error
- returns one fully framed request per completion
- body bytes are already isolated to the current request
- any pipelined remainder stays in native connection state

This means `ZigHttpServer._handleConnection` becomes:

1. `await zigIoTcpReadRequestFuture(connFd)`
2. build `ZigHttpRequest`
3. await response close
4. close connection if `keepAlive == false`
5. loop for next request

No Dart `recvBuf`, no chunk accumulation loop, no leftover shifting.

## Connection State Model

Add a new per-connection op in native state:

```zig
pub const Op = enum(u8) {
    accept,
    recv,
    recv_request,
    recv_route,
    serve,
    loop,
    send,
    tls_handshake,
};
```

Add matching state:

```zig
recv_request: RequestReadData,
```

with:

```zig
pub const RequestReadData = struct {
    recv_buf: [kBufSize]u8 = undefined,
    recv_len: usize = 0,
};
```

Phase 1 should keep this minimal. It does not need write fields because request reading and response writing are still separate ops in Dart.

## Native Completion Behavior

### Submit

`submit_read_request(loop, slot_idx, fd)`:

1. if `recv_len > 0`, attempt to frame immediately from buffered bytes
2. if incomplete, arm `recv` into `recv_buf[recv_len..]`
3. on completion, append bytes by increasing `recv_len`
4. retry framing

### On Complete Request

When `parser.frameRequest(recv_buf[0..recv_len])` returns complete:

1. isolate the request bytes
2. build one completion payload for Dart:
   - method
   - path
   - body bytes
   - keepAlive
   - chunked
3. memmove pipelined leftover bytes to the front:
   - `remaining = recv_len - end_offset`
   - `copyForwards(recv_buf[0..remaining], recv_buf[end_offset..recv_len])`
   - `recv_len = remaining`
4. free the completion slot

### Body Handling in Phase 1

Phase 1 keeps the current ownership model:

- the completion message to Dart contains copied request body bytes
- fixed `Content-Length` and chunked are both materialized before the Dart handler runs

This does not eliminate the final copy into the message queue, but it removes:

- Dart recv chunk accumulation
- Dart connection buffering
- Dart pipelined leftover shifting
- Dart per-request framing orchestration

That is the main target of this phase.

## Wire Format to Dart

The simplest first version is a 5-element `kArray`:

1. method string
2. path string
3. body `kTypedData`
4. keepAlive bool
5. chunked bool

The current batch dispatcher already expects one `[token, value]` pair. So `value` should itself be a `kArray` containing those five elements.

This keeps the dispatcher unchanged:

- outer batch message: `[token, value]`
- `value`: request payload array

Alternative designs like a packed integer descriptor plus separate body posting should be rejected in phase 1 because they complicate the boundary without reducing Dart work meaningfully.

## Parser Expectations

`parser.frameRequest()` is already close to what `read_request` needs:

- request completeness
- body start offset
- body end offset
- keep-alive
- chunked

What still remains in Dart today is chunked body decoding. For `read_request`, that should move into Zig as part of the native request completion path, because returning raw chunk framing to Dart recreates the same avoidable work.

Phase split:

### Phase 1A

Use `frameRequest()` for:

- completeness
- keepAlive
- request end offset

Then materialize body bytes in native code:

- fixed `Content-Length`: copy `recv_buf[body_offset..end_offset]`
- chunked: decode chunked body in native code into one contiguous body buffer before posting

### Phase 1B

Refactor `parser.zig` so chunked-body assembly helpers move there, instead of duplicating them in event-loop code.

The important constraint is that Dart should not do chunked decode anymore once `read_request` exists.

## API Surface Changes

### Dart

Add to `zig_io.dart`:

```dart
@pragma('vm:external-name', 'ZigIo_TcpReadRequestToken')
external void _zigIoTcpReadRequestToken(int connFd, int token);

Future<FramedRequestResult?> zigIoTcpReadRequestFuture(int connFd) =>
    _dispatcher
        .submit<FramedRequestResult?>((t) => _zigIoTcpReadRequestToken(connFd, t))
        .then((v) => v as FramedRequestResult?);
```

Then change `ZigHttpServer` to consume only this op.

### Native

Add:

- `ZigIo_TcpReadRequestToken`
- `submit_recv_request`
- `Op.recv_request`
- result posting helper for request arrays

## Expected `ZigHttpServer` Shape After Refactor

```dart
void _handleConnection(int connFd) async {
  try {
    while (true) {
      final framed = await zigIoTcpReadRequestFuture(connFd);
      if (framed == null) return;

      final response = ZigHttpResponse(connFd);
      final request = ZigHttpRequest(
        framed.method,
        framed.path,
        framed.bodyBytes,
        response,
      );

      _controller.add(request);
      await response._doneFuture;

      if (!framed.keepAlive) return;
    }
  } finally {
    zigIoClose(connFd);
  }
}
```

This becomes a request loop, not a recv assembly loop.

## Why This Is Better Than More Dart-Side Tuning

Without `read_request`, further Dart-side tuning still leaves:

- one Dart completion per recv chunk
- one Dart buffer mutation per chunk
- one Dart memmove per pipelined request
- Dart as the owner of request assembly state

`read_request` removes that entire control path from Dart.

That is a larger architectural win than shaving more scans off the existing buffer loop.

## Risks

1. Native complexity increases.
2. Chunked decode must be correct in Zig before Dart removes its fallback.
3. Request payload posting will still allocate/copy at the message boundary in phase 1.
4. `kBufSize` remains a hard limit for buffered request bodies in this phase.

## Rollout Plan

### Step 1

Add doc-only design and keep the current `frameRequest()` path unchanged.

### Step 2

Implement `Op.recv_request` and `ZigIo_TcpReadRequestToken` on Linux only.

Success criteria:

- existing `HttpArena` validation still passes
- `ZigHttpServer` compiles without Dart recv buffering

### Step 3

Move chunked body decode into Zig for the `read_request` path.

Success criteria:

- no `_decodeChunkedBody()` in `zig_http_server.dart`
- chunked request validation still passes

### Step 4

Measure:

- `zig_http_server_example` JIT
- `zig_http_server_example` AOT
- `HttpArena` baseline/json profiles

### Step 5

If the request rate is still dominated by the Dart message boundary, then the next step is not more parser work. It is one of:

1. native-owned external body buffers for larger bodies
2. a more compact native request descriptor
3. a more fused request/response path

## Recommended First Implementation Slice

The first patch should do only this:

1. add `Op.recv_request`
2. add `RequestReadData`
3. add `ZigIo_TcpReadRequestToken`
4. return fully framed request payloads to Dart
5. switch `ZigHttpServer` to that API

Do not combine that patch with:

- external typed data
- streaming bodies
- response-path changes
- kqueue parity work

That keeps the delta focused and benchmarkable.
