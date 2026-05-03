#!/usr/bin/env python3
"""
HTTP/1.1 pipelined benchmark for dart-zig.

This script opens persistent TCP connections, sends multiple pipelined GET
requests before reading responses, and measures completed requests/sec.

Example:
  python3 scripts/bench_pipeline.py --host 127.0.0.1 --port 8080 \
    --connections 64 --threads 6 --pipeline 16 --duration 10
"""

from __future__ import annotations

import argparse
import socket
import threading
import time
from dataclasses import dataclass
from typing import Optional


REQUEST_TEMPLATE = (
    "GET {path} HTTP/1.1\r\n"
    "Host: {host}\r\n"
    "Connection: keep-alive\r\n"
    "\r\n"
)


@dataclass
class Stats:
    completed: int = 0
    bytes_read: int = 0
    errors: int = 0


class ResponseParser:
    def __init__(self) -> None:
        self.buf = bytearray()

    def feed(self, data: bytes) -> None:
        self.buf.extend(data)

    def pop_complete(self) -> bool:
        head_end = self.buf.find(b"\r\n\r\n")
        if head_end < 0:
            return False

        header_block = bytes(self.buf[: head_end + 4])
        content_length = 0
        for line in header_block.split(b"\r\n"):
            lower = line.lower()
            if lower.startswith(b"content-length:"):
                try:
                    content_length = int(lower.split(b":", 1)[1].strip())
                except ValueError:
                    return False
                break

        total_len = head_end + 4 + content_length
        if len(self.buf) < total_len:
            return False

        del self.buf[:total_len]
        return True


def recv_exact_responses(
    sock: socket.socket,
    parser: ResponseParser,
    want: int,
    deadline: float,
    stats: Stats,
) -> int:
    got = 0
    while got < want:
        while parser.pop_complete():
            got += 1
            if got == want:
                return got

        timeout = deadline - time.monotonic()
        if timeout <= 0:
            break
        sock.settimeout(timeout)
        chunk = sock.recv(65536)
        if not chunk:
            break
        stats.bytes_read += len(chunk)
        parser.feed(chunk)
    return got


def worker(
    host: str,
    port: int,
    path: str,
    connections: int,
    pipeline: int,
    duration: float,
    results: list[Stats],
    idx: int,
) -> None:
    stats = Stats()
    conns: list[tuple[socket.socket, ResponseParser]] = []
    request = REQUEST_TEMPLATE.format(path=path, host=host).encode("ascii") * pipeline
    deadline = time.monotonic() + duration

    try:
        for _ in range(connections):
            sock = socket.create_connection((host, port), timeout=3.0)
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            conns.append((sock, ResponseParser()))

        while time.monotonic() < deadline:
            for conn_idx, (sock, parser) in enumerate(conns):
                try:
                    sock.sendall(request)
                    got = recv_exact_responses(
                        sock,
                        parser,
                        pipeline,
                        deadline,
                        stats,
                    )
                    stats.completed += got
                    if got != pipeline:
                        if time.monotonic() >= deadline:
                            break
                        stats.errors += 1
                        raise ConnectionError("short response batch")
                except Exception:
                    stats.errors += 1
                    try:
                        sock.close()
                    finally:
                        replacement = socket.create_connection((host, port), timeout=3.0)
                        replacement.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                        conns[conn_idx] = (replacement, ResponseParser())
    finally:
        for sock, _ in conns:
            try:
                sock.close()
            except OSError:
                pass
        results[idx] = stats


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="HTTP/1.1 pipeline benchmark")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--path", default="/")
    parser.add_argument("--threads", type=int, default=6)
    parser.add_argument("--connections", type=int, default=64)
    parser.add_argument("--pipeline", type=int, default=16)
    parser.add_argument("--duration", type=float, default=10.0)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.threads <= 0 or args.connections <= 0 or args.pipeline <= 0:
        raise SystemExit("threads, connections, and pipeline must be > 0")

    base = args.connections // args.threads
    extra = args.connections % args.threads

    results: list[Optional[Stats]] = [None] * args.threads
    threads: list[threading.Thread] = []

    start = time.monotonic()
    for i in range(args.threads):
        conn_count = base + (1 if i < extra else 0)
        t = threading.Thread(
            target=worker,
            args=(
                args.host,
                args.port,
                args.path,
                conn_count,
                args.pipeline,
                args.duration,
                results,
                i,
            ),
            daemon=True,
        )
        threads.append(t)
        t.start()

    for t in threads:
        t.join()
    elapsed = time.monotonic() - start

    final = Stats()
    for item in results:
        if item is None:
            final.errors += 1
            continue
        final.completed += item.completed
        final.bytes_read += item.bytes_read
        final.errors += item.errors

    rps = final.completed / elapsed if elapsed > 0 else 0.0
    mbps = final.bytes_read / elapsed / (1024 * 1024) if elapsed > 0 else 0.0

    print(f"Host:          {args.host}:{args.port}")
    print(f"Threads:       {args.threads}")
    print(f"Connections:   {args.connections}")
    print(f"Pipeline:      {args.pipeline}")
    print(f"Duration:      {args.duration:.2f}s")
    print(f"Completed:     {final.completed}")
    print(f"Requests/sec:  {rps:.2f}")
    print(f"Read MB/sec:   {mbps:.2f}")
    print(f"Errors:        {final.errors}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
