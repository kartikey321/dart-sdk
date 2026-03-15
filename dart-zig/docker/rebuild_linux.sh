#!/usr/bin/env bash
set -e

# Install Zig if not present
if [ ! -f /usr/local/bin/zig ]; then
    echo "=== Installing Zig 0.15.2 ==="
    curl -L "https://ziglang.org/download/0.15.2/zig-aarch64-linux-0.15.2.tar.xz" \
        -o /tmp/zig.tar.xz
    tar -xf /tmp/zig.tar.xz -C /opt/
    # Find extracted dir
    ZIG_DIR=$(ls /opt/ | grep zig | head -1)
    ln -sf /opt/$ZIG_DIR/zig /usr/local/bin/zig
fi
zig version

echo "=== Rebuilding dart-zig for Linux ==="
cd /workspace/sdk/dart-zig
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache-linux zig build 2>&1

echo "=== Build OK ==="
ls -la zig-out/bin/dart-zig

# Quick smoke test
echo "=== Smoke test ==="
export LD_LIBRARY_PATH=/workspace/sdk/out/ReleaseARM64
./zig-out/bin/dart-zig test-snapshots/zig_io_test.dill 2>&1

# Copy to zig-out-linux
cp zig-out/bin/dart-zig zig-out-linux/bin/dart-zig
echo "=== Copied to zig-out-linux ==="
