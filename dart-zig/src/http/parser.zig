/// Zero-allocation HTTP/1.1 request parser.
/// All slices in the result point into the caller-provided buffer — no heap use.
/// Handles LF-only and CRLF line endings.

pub const kMaxHeaders = 32;

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const ParseStatus = enum { complete, incomplete, invalid };

pub const ParseResult = struct {
    status: ParseStatus = .incomplete,
    method: []const u8 = &.{},
    path: []const u8 = &.{},
    /// Byte offset in the input buffer where the body begins (after \r\n\r\n).
    body_offset: usize = 0,
    headers: [kMaxHeaders]Header = undefined,
    header_count: usize = 0,
};

pub const FramedRequest = struct {
    status: ParseStatus = .incomplete,
    method: []const u8 = &.{},
    path: []const u8 = &.{},
    body_offset: usize = 0,
    end_offset: usize = 0,
    keep_alive: bool = true,
    chunked: bool = false,
};

/// Parse an HTTP/1.1 request from `buf`.
/// Returns immediately with status=incomplete if more data is needed.
/// Returns status=invalid for malformed requests (missing SP in request-line, etc.).
pub fn parse(buf: []const u8) ParseResult {
    var result = ParseResult{};
    var pos: usize = 0;

    // -----------------------------------------------------------------------
    // Request line: "METHOD SP /path SP HTTP/1.x CRLF"
    // -----------------------------------------------------------------------

    // method (up to first SP)
    const method_start = pos;
    while (pos < buf.len and buf[pos] != ' ') : (pos += 1) {}
    if (pos >= buf.len) return result; // incomplete
    result.method = buf[method_start..pos];
    pos += 1; // skip SP

    // path (up to SP or end-of-line)
    const path_start = pos;
    while (pos < buf.len and buf[pos] != ' ' and buf[pos] != '\r' and buf[pos] != '\n') : (pos += 1) {}
    if (pos >= buf.len) return result; // incomplete
    result.path = buf[path_start..pos];

    // skip rest of request line (HTTP/1.x CRLF)
    while (pos < buf.len and buf[pos] != '\n') : (pos += 1) {}
    if (pos >= buf.len) return result; // incomplete
    pos += 1; // skip LF

    // -----------------------------------------------------------------------
    // Headers: "Name: value CRLF" repeated, terminated by empty line
    // -----------------------------------------------------------------------
    while (pos < buf.len) {
        // Empty line signals end of headers
        if (buf[pos] == '\r') {
            if (pos + 1 < buf.len and buf[pos + 1] == '\n') {
                result.body_offset = pos + 2;
                result.status = .complete;
                return result;
            }
            // lone CR — treat as invalid
            result.status = .invalid;
            return result;
        }
        if (buf[pos] == '\n') {
            result.body_offset = pos + 1;
            result.status = .complete;
            return result;
        }

        // header name (up to ':')
        const name_start = pos;
        while (pos < buf.len and buf[pos] != ':' and buf[pos] != '\r' and buf[pos] != '\n') : (pos += 1) {}
        if (pos >= buf.len) return result; // incomplete
        if (buf[pos] != ':') {
            result.status = .invalid;
            return result;
        }
        const name_end = pos;
        pos += 1; // skip ':'

        // skip optional whitespace (OWS)
        while (pos < buf.len and (buf[pos] == ' ' or buf[pos] == '\t')) : (pos += 1) {}

        // header value (up to CRLF)
        const value_start = pos;
        while (pos < buf.len and buf[pos] != '\r' and buf[pos] != '\n') : (pos += 1) {}
        if (pos >= buf.len) return result; // incomplete

        // trim trailing OWS from value
        var value_end = pos;
        while (value_end > value_start and (buf[value_end - 1] == ' ' or buf[value_end - 1] == '\t')) : (value_end -= 1) {}

        // skip CRLF (or bare LF)
        if (buf[pos] == '\r') pos += 1;
        if (pos >= buf.len) return result; // incomplete — saw CR but no LF yet
        if (buf[pos] == '\n') {
            pos += 1;
        } else {
            result.status = .invalid;
            return result;
        }

        if (result.header_count < kMaxHeaders) {
            result.headers[result.header_count] = .{
                .name = buf[name_start..name_end],
                .value = buf[value_start..value_end],
            };
            result.header_count += 1;
        }
    }

    return result; // incomplete — no end-of-headers found yet
}

// ---------------------------------------------------------------------------
// Fast route matching (returns int, no Dart heap allocation)
// ---------------------------------------------------------------------------

/// Route IDs returned by routeRequest().
/// Must stay in sync with lib/zig_http.dart RouteId constants.
pub const RouteId = struct {
    pub const hello:       i64 = 0;  // GET /  or  GET /index.html
    pub const ping:        i64 = 1;  // GET /ping
    pub const not_found:   i64 = -1; // valid request, unknown path
    pub const bad_request: i64 = -2; // malformed request (invalid syntax)
    pub const eof:         i64 = -3; // connection closed or read error
    pub const incomplete:  i64 = -4; // need more data (serve op re-arms recv)
};

/// Result of routeRequestFull — route id + bytes consumed from the buffer.
/// consumed is body_offset for a complete request (all headers + blank line).
/// Used by the loop op to detect and process pipelined requests from leftover buffer bytes.
pub const RouteResult = struct {
    route: i64,
    consumed: usize,
};

/// Fast path: extract path and find body_offset WITHOUT parsing individual headers.
/// Skips all header name/value iteration — ~3x less work than parse() for typical requests.
pub fn routeRequestFull(buf: []const u8) RouteResult {
    var i: usize = 0;

    // Skip method (up to first space).
    while (i < buf.len and buf[i] != ' ') : (i += 1) {}
    if (i >= buf.len) return .{ .route = RouteId.incomplete, .consumed = 0 };
    i += 1; // skip space

    // Read path (up to next space or CR/LF — handles HTTP/0.9).
    const path_start = i;
    while (i < buf.len and buf[i] != ' ' and buf[i] != '\r' and buf[i] != '\n') : (i += 1) {}
    if (i >= buf.len) return .{ .route = RouteId.incomplete, .consumed = 0 };
    const raw_path = buf[path_start..i];

    // Strip query string for routing.
    const path = if (std.mem.indexOfScalar(u8, raw_path, '?')) |q| raw_path[0..q] else raw_path;

    const route: i64 = if (path.len == 1 and path[0] == '/')
        RouteId.hello
    else if (path.len == 12 and std.mem.eql(u8, path, "/index.html"))
        RouteId.hello
    else if (path.len == 5 and std.mem.eql(u8, path, "/ping"))
        RouteId.ping
    else
        RouteId.not_found;

    // Skip to end of request line.
    while (i < buf.len and buf[i] != '\n') : (i += 1) {}
    if (i >= buf.len) return .{ .route = RouteId.incomplete, .consumed = 0 };
    i += 1; // skip LF

    // Single-pass scan for blank line: \r\n\r\n or \n\n — no per-header parsing.
    while (i < buf.len) : (i += 1) {
        if (buf[i] == '\r') {
            if (i + 3 < buf.len and buf[i + 1] == '\n' and buf[i + 2] == '\r' and buf[i + 3] == '\n')
                return .{ .route = route, .consumed = i + 4 };
        } else if (buf[i] == '\n') {
            if (i + 1 < buf.len and buf[i + 1] == '\n')
                return .{ .route = route, .consumed = i + 2 };
        }
    }
    return .{ .route = RouteId.incomplete, .consumed = 0 };
}

/// Parse the request in `buf` and return a RouteId integer.
/// Returns incomplete (-4) when more data is needed — callers should buffer and retry.
/// Returns bad_request (-2) only for definitively malformed requests.
/// Zero allocations — only stack memory used.
pub fn routeRequest(buf: []const u8) i64 {
    return routeRequestFull(buf).route;
}

pub fn frameRequest(buf: []const u8) FramedRequest {
    const parsed = parse(buf);
    if (parsed.status != .complete) {
        return .{ .status = parsed.status };
    }

    var keep_alive = true;
    var chunked = false;
    var content_length: ?usize = null;

    var i: usize = 0;
    while (i < parsed.header_count) : (i += 1) {
        const header = parsed.headers[i];
        if (std.ascii.eqlIgnoreCase(header.name, "connection")) {
            if (std.ascii.eqlIgnoreCase(header.value, "close")) {
                keep_alive = false;
            }
        } else if (std.ascii.eqlIgnoreCase(header.name, "content-length")) {
            content_length = std.fmt.parseInt(usize, header.value, 10) catch {
                return .{ .status = .invalid };
            };
        } else if (std.ascii.eqlIgnoreCase(header.name, "transfer-encoding")) {
            if (std.ascii.indexOfIgnoreCase(header.value, "chunked") != null) {
                chunked = true;
            }
        }
    }

    if (chunked) {
        const end_offset = chunkedEndOffset(buf, parsed.body_offset) orelse {
            return .{ .status = .incomplete };
        };
        return .{
            .status = .complete,
            .method = parsed.method,
            .path = parsed.path,
            .body_offset = parsed.body_offset,
            .end_offset = end_offset,
            .keep_alive = keep_alive,
            .chunked = true,
        };
    }

    const body_len = content_length orelse 0;
    const end_offset = parsed.body_offset + body_len;
    if (buf.len < end_offset) {
        return .{ .status = .incomplete };
    }
    return .{
        .status = .complete,
        .method = parsed.method,
        .path = parsed.path,
        .body_offset = parsed.body_offset,
        .end_offset = end_offset,
        .keep_alive = keep_alive,
        .chunked = false,
    };
}

fn chunkedEndOffset(buf: []const u8, body_offset: usize) ?usize {
    var pos = body_offset;
    while (true) {
        const line_end = findLineEnd(buf, pos) orelse return null;
        const size_text = std.mem.trim(u8, buf[pos..line_end], " \t");
        const semi = std.mem.indexOfScalar(u8, size_text, ';');
        const chunk_size_text = if (semi) |idx| size_text[0..idx] else size_text;
        const chunk_size = std.fmt.parseInt(usize, chunk_size_text, 16) catch return null;
        pos = advancePastLineEnd(buf, line_end) orelse return null;

        if (chunk_size == 0) {
            while (true) {
                const trailer_end = findLineEnd(buf, pos) orelse return null;
                if (trailer_end == pos) {
                    return advancePastLineEnd(buf, trailer_end);
                }
                pos = advancePastLineEnd(buf, trailer_end) orelse return null;
            }
        }

        const chunk_end = pos + chunk_size;
        if (chunk_end >= buf.len) return null;
        pos = chunk_end;

        if (buf[pos] == '\r') {
            if (pos + 1 >= buf.len or buf[pos + 1] != '\n') return null;
            pos += 2;
        } else if (buf[pos] == '\n') {
            pos += 1;
        } else {
            return null;
        }
    }
}

fn findLineEnd(buf: []const u8, start: usize) ?usize {
    var i = start;
    while (i < buf.len) : (i += 1) {
        if (buf[i] == '\n') {
            return if (i > start and buf[i - 1] == '\r') i - 1 else i;
        }
    }
    return null;
}

fn advancePastLineEnd(buf: []const u8, line_end: usize) ?usize {
    if (line_end >= buf.len) return null;
    if (buf[line_end] == '\n') return line_end + 1;
    if (line_end + 1 < buf.len and buf[line_end] == '\r' and buf[line_end + 1] == '\n') {
        return line_end + 2;
    }
    if (line_end + 1 < buf.len and buf[line_end + 1] == '\n') return line_end + 2;
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const std = @import("std");

test "simple GET" {
    const req = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const r = parse(req);
    try std.testing.expectEqual(ParseStatus.complete, r.status);
    try std.testing.expectEqualStrings("GET", r.method);
    try std.testing.expectEqualStrings("/", r.path);
    try std.testing.expectEqual(@as(usize, 1), r.header_count);
    try std.testing.expectEqualStrings("Host", r.headers[0].name);
    try std.testing.expectEqualStrings("localhost", r.headers[0].value);
    try std.testing.expectEqual(req.len, r.body_offset);
}

test "POST with body" {
    const req = "POST /api/data HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello";
    const r = parse(req);
    try std.testing.expectEqual(ParseStatus.complete, r.status);
    try std.testing.expectEqualStrings("POST", r.method);
    try std.testing.expectEqualStrings("/api/data", r.path);
    try std.testing.expectEqual(@as(usize, 1), r.header_count);
    // body_offset points at 'h' in "hello"
    try std.testing.expectEqualStrings("hello", req[r.body_offset..]);
}

test "incomplete request" {
    const r = parse("GET /foo HT");
    try std.testing.expectEqual(ParseStatus.incomplete, r.status);
}

test "multiple headers" {
    const req = "GET /ping HTTP/1.1\r\nHost: x\r\nUser-Agent: test\r\nAccept: */*\r\n\r\n";
    const r = parse(req);
    try std.testing.expectEqual(ParseStatus.complete, r.status);
    try std.testing.expectEqual(@as(usize, 3), r.header_count);
}
