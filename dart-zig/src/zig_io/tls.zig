const std = @import("std");
const posix = std.posix;
const state = @import("state.zig");

const c = @cImport({
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/bio.h");
    @cInclude("openssl/err.h");
});

pub const TlsConn = struct {
    ssl: ?*c.SSL = null,
    rbio: ?*c.BIO = null,
    wbio: ?*c.BIO = null,
    fd: posix.fd_t = -1,
    pending_cipher: [state.kBufSize]u8 = undefined,
    pending_len: usize = 0,
    pending_off: usize = 0,
    in_use: bool = false,
};

pub const HandshakeState = enum {
    done,
    want_read,
    want_write,
    err,
};

const FlushState = enum {
    ok,
    want_write,
    err,
};

pub var g_ctx: ?*c.SSL_CTX = null;
pub var tls_pool: [state.kPoolSize]TlsConn = [_]TlsConn{.{}} ** state.kPoolSize;
pub var tls_alloc: state.SlotAllocator = undefined;

var tls_pool_ready = false;

fn ensurePoolInit() void {
    if (tls_pool_ready) return;
    tls_alloc.init();
    tls_pool_ready = true;
}

fn allocTlsSlot() ?usize {
    if (tls_alloc.free_len == 0) return null;
    tls_alloc.free_len -= 1;
    const idx: usize = @intCast(tls_alloc.free_stack[tls_alloc.free_len]);
    std.debug.assert(!tls_pool[idx].in_use);
    tls_pool[idx].in_use = true;
    return idx;
}

fn freeTlsSlot(idx: usize) void {
    std.debug.assert(idx < state.kPoolSize);
    std.debug.assert(tls_pool[idx].in_use);
    std.debug.assert(tls_alloc.free_len < state.kPoolSize);
    tls_pool[idx].in_use = false;
    tls_alloc.free_stack[tls_alloc.free_len] = @intCast(idx);
    tls_alloc.free_len += 1;
}

fn getConn(tls_id: u16) ?*TlsConn {
    if (tls_id == 0) return null;
    const idx: usize = @as(usize, tls_id) - 1;
    if (idx >= state.kPoolSize) return null;
    if (!tls_pool[idx].in_use) return null;
    return &tls_pool[idx];
}

pub fn getFd(tls_id: u16) ?posix.fd_t {
    const conn = getConn(tls_id) orelse return null;
    return conn.fd;
}

pub fn configure(cert_file: []const u8, key_file: []const u8) i32 {
    ensurePoolInit();

    if (g_ctx != null) {
        // Keep configure idempotent for repeated startup calls.
        return 0;
    }

    const method = c.TLS_server_method();
    if (method == null) return -1;

    const ctx = c.SSL_CTX_new(method);
    if (ctx == null) return -1;

    c.SSL_CTX_set_quiet_shutdown(ctx, 1);

    if (c.SSL_CTX_use_certificate_file(ctx, cert_file.ptr, c.SSL_FILETYPE_PEM) != 1) {
        c.SSL_CTX_free(ctx);
        return -1;
    }
    if (c.SSL_CTX_use_PrivateKey_file(ctx, key_file.ptr, c.SSL_FILETYPE_PEM) != 1) {
        c.SSL_CTX_free(ctx);
        return -1;
    }
    if (c.SSL_CTX_check_private_key(ctx) != 1) {
        c.SSL_CTX_free(ctx);
        return -1;
    }

    g_ctx = ctx;
    return 0;
}

pub fn allocConn(fd: posix.fd_t) u16 {
    ensurePoolInit();

    const ctx = g_ctx orelse return 0;
    const idx = allocTlsSlot() orelse return 0;
    const conn = &tls_pool[idx];
    conn.* = .{ .in_use = true, .fd = fd };

    const ssl = c.SSL_new(ctx);
    if (ssl == null) {
        freeTlsSlot(idx);
        conn.* = .{};
        return 0;
    }

    var ssl_rbio: ?*c.BIO = null;
    var app_rbio: ?*c.BIO = null;
    if (c.BIO_new_bio_pair(&ssl_rbio, 0, &app_rbio, 0) != 1 or ssl_rbio == null or app_rbio == null) {
        c.SSL_free(ssl);
        freeTlsSlot(idx);
        conn.* = .{};
        return 0;
    }

    var ssl_wbio: ?*c.BIO = null;
    var app_wbio: ?*c.BIO = null;
    if (c.BIO_new_bio_pair(&ssl_wbio, 0, &app_wbio, 0) != 1 or ssl_wbio == null or app_wbio == null) {
        _ = c.BIO_free(ssl_rbio.?);
        _ = c.BIO_free(app_rbio.?);
        c.SSL_free(ssl);
        freeTlsSlot(idx);
        conn.* = .{};
        return 0;
    }

    c.SSL_set_bio(ssl, ssl_rbio, ssl_wbio);
    c.SSL_set_accept_state(ssl);

    conn.ssl = ssl;
    conn.rbio = app_rbio;
    conn.wbio = app_wbio;

    return @intCast(idx + 1);
}

pub fn freeConn(tls_id: u16) void {
    const conn = getConn(tls_id) orelse return;
    const idx: usize = @as(usize, tls_id) - 1;

    if (conn.ssl) |ssl| c.SSL_free(ssl);   // SSL_free also frees ssl_rbio/ssl_wbio
    if (conn.rbio) |rbio| _ = c.BIO_free(rbio);  // free app-side of pair 1
    if (conn.wbio) |wbio| _ = c.BIO_free(wbio);  // free app-side of pair 2
    if (conn.fd >= 0) posix.close(conn.fd);

    // freeTlsSlot asserts in_use — must call before clearing the struct.
    freeTlsSlot(idx);
    conn.* = .{};
}

pub fn advanceHandshake(tls_id: u16) HandshakeState {
    const conn = getConn(tls_id) orelse return .err;

    var spins: usize = 0;
    while (spins < 16) : (spins += 1) {
        switch (flushWbio(tls_id)) {
            .ok => {},
            .want_write => return .want_write,
            .err => return .err,
        }

        const rc = c.SSL_do_handshake(conn.ssl.?);
        if (rc == 1) {
            return switch (flushWbio(tls_id)) {
                .ok => .done,
                .want_write => .want_write,
                .err => .err,
            };
        }

        const ssl_err = c.SSL_get_error(conn.ssl.?, rc);
        switch (ssl_err) {
            c.SSL_ERROR_WANT_READ => {
                return switch (flushWbio(tls_id)) {
                    .ok => .want_read,
                    .want_write => .want_write,
                    .err => .err,
                };
            },
            c.SSL_ERROR_WANT_WRITE => {
                switch (flushWbio(tls_id)) {
                    .ok => continue,
                    .want_write => return .want_write,
                    .err => return .err,
                }
            },
            else => {
                std.debug.print("[TLS] advanceHandshake: ssl_err={}\n", .{ssl_err});
                return .err;
            },
        }
    }

    return .err;
}

pub fn feedRecv(tls_id: u16, data: []const u8) bool {
    const conn = getConn(tls_id) orelse return false;
    if (data.len == 0) return true;

    var off: usize = 0;
    while (off < data.len) {
        const remaining = data.len - off;
        const chunk_len = @min(remaining, @as(usize, @intCast(std.math.maxInt(c_int))));
        const n = c.BIO_write(conn.rbio.?, @ptrCast(data.ptr + off), @intCast(chunk_len));
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

pub fn pendingPlaintext(tls_id: u16) usize {
    const conn = getConn(tls_id) orelse return 0;
    const n = c.SSL_pending(conn.ssl.?);
    return if (n > 0) @intCast(n) else 0;
}

pub fn readPlaintext(tls_id: u16, buf: []u8) isize {
    const conn = getConn(tls_id) orelse return -1;
    if (buf.len == 0) return 0;

    const read_len = @min(buf.len, @as(usize, @intCast(std.math.maxInt(c_int))));
    const n = c.SSL_read(conn.ssl.?, @ptrCast(buf.ptr), @intCast(read_len));
    if (n > 0) {
        _ = flushWbio(tls_id);
    }
    return n;
}

pub fn writePlaintext(tls_id: u16, data: []const u8) isize {
    const conn = getConn(tls_id) orelse return -1;
    if (data.len == 0) return 0;

    const write_len = @min(data.len, @as(usize, @intCast(std.math.maxInt(c_int))));
    const n = c.SSL_write(conn.ssl.?, @ptrCast(data.ptr), @intCast(write_len));
    if (n <= 0) return -1;

    return switch (flushWbio(tls_id)) {
        .ok => n,
        .want_write => -1,
        .err => -1,
    };
}

fn flushWbio(tls_id: u16) FlushState {
    const conn = getConn(tls_id) orelse return .err;

    while (conn.pending_off < conn.pending_len) {
        const wrote = posix.write(conn.fd, conn.pending_cipher[conn.pending_off..conn.pending_len]) catch |err| switch (err) {
            error.WouldBlock => return .want_write,
            else => return .err,
        };
        if (wrote == 0) return .want_write;
        conn.pending_off += wrote;
    }
    conn.pending_off = 0;
    conn.pending_len = 0;

    var tmp: [state.kBufSize]u8 = undefined;
    while (true) {
        const n = c.BIO_read(conn.wbio.?, @ptrCast(tmp[0..].ptr), @intCast(tmp.len));
        if (n > 0) {
            var off: usize = 0;
            const out_len: usize = @intCast(n);
                while (off < out_len) {
                const wrote = posix.write(conn.fd, tmp[off..out_len]) catch |err| switch (err) {
                    error.WouldBlock => {
                        const rem = out_len - off;
                        std.mem.copyForwards(u8, conn.pending_cipher[0..rem], tmp[off..out_len]);
                        conn.pending_len = rem;
                        conn.pending_off = 0;
                        return .want_write;
                    },
                    else => return .err,
                };
                if (wrote == 0) {
                    const rem = out_len - off;
                    std.mem.copyForwards(u8, conn.pending_cipher[0..rem], tmp[off..out_len]);
                    conn.pending_len = rem;
                    conn.pending_off = 0;
                    return .want_write;
                }
                off += wrote;
            }
            continue;
        }
        if (n == 0) return .ok;
        if (c.BIO_should_retry(conn.wbio.?) != 0) return .ok;
        return .err;
    }
}
