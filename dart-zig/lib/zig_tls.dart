// dart-zig TLS library — Phase 15.
// Wraps BoringSSL TLS termination via the batch dispatcher in zig_io.dart.
// Import alongside zig_io.dart; both share the same batch port.

// ignore_for_file: camel_case_types

import 'dart:typed_data' show Uint8List;

import 'zig_io.dart';

// ---------------------------------------------------------------------------
// Native declarations
// ---------------------------------------------------------------------------

/// Configure the global TLS server context (call once at startup).
/// [certFile]: path to PEM certificate (or chain).
/// [keyFile]:  path to PEM private key.
/// Returns 0 on success, -1 on error.
@pragma('vm:external-name', 'ZigTls_Configure')
external int _zigTlsConfigure(String certFile, String keyFile);

/// Begin async TLS handshake on an accepted TCP fd.
/// Posts [token, tls_id] on success, [token, -1] on failure.
@pragma('vm:external-name', 'ZigTls_UpgradeToken')
external void _zigTlsUpgradeToken(int connFd, int token);

/// Submit async read of plaintext from a TLS connection.
/// Posts [token, Uint8List] on success, [token, null] on EOF/error.
@pragma('vm:external-name', 'ZigTls_ReadToken')
external void _zigTlsReadToken(int tlsId, int maxBytes, int token);

/// Write plaintext bytes to a TLS connection (synchronous encrypt + flush).
/// Posts [token, bytesWritten] on completion.
@pragma('vm:external-name', 'ZigTls_WriteBytesToken')
external void _zigTlsWriteBytesToken(int tlsId, Uint8List bytes, int token);

/// Shutdown and free the TLS connection (SSL_free + close fd).
@pragma('vm:external-name', 'ZigTls_Close')
external void _zigTlsClose(int tlsId);

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Configure the TLS server context. Call once before accepting connections.
/// Returns 0 on success, -1 on error.
int zigTlsConfigure(String certFile, String keyFile) =>
    _zigTlsConfigure(certFile, keyFile);

/// Upgrade an accepted TCP [connFd] to TLS by performing the handshake.
/// Returns a tls_id > 0 on success, or -1 on handshake failure.
/// The TCP fd is owned by the TLS layer after this call.
Future<int> zigTlsUpgradeFuture(int connFd) =>
    zigIoDispatcher.submit<int>((t) => _zigTlsUpgradeToken(connFd, t));

/// Read up to [maxBytes] plaintext bytes from a TLS connection.
/// Returns null on EOF or fatal error.
Future<Uint8List?> zigTlsReadFuture(int tlsId, int maxBytes) =>
    zigIoDispatcher
        .submit<Uint8List?>((t) => _zigTlsReadToken(tlsId, maxBytes, t))
        .then((v) => v as Uint8List?);

/// Write plaintext [bytes] to a TLS connection.
/// Returns bytes written, or -1 on error.
Future<int> zigTlsWriteBytesFuture(int tlsId, Uint8List bytes) =>
    zigIoDispatcher
        .submit<int>((t) => _zigTlsWriteBytesToken(tlsId, bytes, t))
        .then((v) => (v as int?) ?? -1);

/// Shutdown and free the TLS connection.
void zigTlsClose(int tlsId) => _zigTlsClose(tlsId);
