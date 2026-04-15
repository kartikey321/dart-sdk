/// Comptime-constant HTTP/1.1 response byte slices for all static routes.
/// No heap allocation, no Dart involvement — the fused serve native looks up
/// the response by RouteId and writes it directly from these slices.
/// Must stay in sync with lib/http_server.dart pre-built responses.

const parser = @import("parser.zig");

pub const hello: []const u8 =
    "HTTP/1.1 200 OK\r\n" ++
    "Content-Type: text/plain; charset=utf-8\r\n" ++
    "Content-Length: 20\r\n" ++
    "Connection: keep-alive\r\n" ++
    "\r\n" ++
    "Hello from dart-zig!";

pub const ping: []const u8 =
    "HTTP/1.1 200 OK\r\n" ++
    "Content-Type: text/plain; charset=utf-8\r\n" ++
    "Content-Length: 4\r\n" ++
    "Connection: keep-alive\r\n" ++
    "\r\n" ++
    "pong";

pub const not_found: []const u8 =
    "HTTP/1.1 404 Not Found\r\n" ++
    "Content-Type: text/plain; charset=utf-8\r\n" ++
    "Content-Length: 13\r\n" ++
    "Connection: keep-alive\r\n" ++
    "\r\n" ++
    "404 Not Found";

pub const bad_request: []const u8 =
    "HTTP/1.1 400 Bad Request\r\n" ++
    "Content-Type: text/plain; charset=utf-8\r\n" ++
    "Content-Length: 11\r\n" ++
    "Connection: close\r\n" ++
    "\r\n" ++
    "Bad Request";

/// Return the response slice for a RouteId.
/// Returns null only for eof/hard-error (connection dead — nothing to send).
pub fn forRoute(route_id: i64) ?[]const u8 {
    return switch (route_id) {
        parser.RouteId.hello      => hello,
        parser.RouteId.ping       => ping,
        parser.RouteId.not_found  => not_found,
        parser.RouteId.bad_request => bad_request,
        else => null, // eof (-3) or unknown
    };
}

/// True when the connection should be closed after sending the response.
pub fn shouldClose(route_id: i64) bool {
    return route_id <= parser.RouteId.bad_request; // -2 or worse
}
