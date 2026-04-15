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
    pub const bad_request: i64 = -2; // malformed or incomplete
    pub const eof:         i64 = -3; // connection closed or read error (recv_route only)
};

/// Parse the request in `buf` and return a RouteId integer.
/// Zero allocations — only stack memory used.
pub fn routeRequest(buf: []const u8) i64 {
    const r = parse(buf);
    if (r.status != .complete) return RouteId.bad_request;
    const path = r.path;
    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
        return RouteId.hello;
    }
    if (std.mem.eql(u8, path, "/ping")) {
        return RouteId.ping;
    }
    return RouteId.not_found;
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
