#!/usr/bin/env bash
# Run inside the Docker container via:
#   docker run --rm -v /Users/kartik/StudioProjects:/workspace dart-zig-builder bash /workspace/sdk/dart-zig/docker/build-engine.sh
set -e

WORKSPACE=/workspace
SDK=$WORKSPACE/sdk

echo "=== gclient sync (Linux ARM64 deps) ==="
cd $WORKSPACE
gclient sync -j8 --no-history 2>&1

echo "=== Building dart_engine_jit_shared + dart for Linux ARM64 ==="
cd $SDK
python3 tools/build.py --mode=release -j$(nproc) dart_engine_jit_shared dart

echo "=== Build complete ==="
ls -la out/ReleaseARM64/libdart_engine_jit_shared.so out/ReleaseARM64/dart

echo "=== Installing Zig 0.15.2 ==="
if [ ! -f /usr/local/bin/zig ]; then
    curl -L "https://ziglang.org/download/0.15.2/zig-aarch64-linux-0.15.2.tar.xz" -o /tmp/zig.tar.xz
    tar -xf /tmp/zig.tar.xz -C /opt/
    mv /opt/zig-aarch64-linux-0.15.2 /opt/zig
    ln -sf /opt/zig/zig /usr/local/bin/zig
fi
zig version

echo "=== Building dart-zig for Linux ==="
cd $SDK/dart-zig
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache-linux zig build 2>&1

echo "=== dart-zig Linux build complete ==="
ls -la zig-out/bin/dart-zig

echo "=== Smoke test: dart-zig test-snapshots/hello.dill world ==="
# hello.dill is pre-compiled on macOS (kernel format is platform-agnostic)
LD_LIBRARY_PATH=$SDK/out/ReleaseARM64 \
    $SDK/dart-zig/zig-out/bin/dart-zig \
    $SDK/dart-zig/test-snapshots/hello.dill world

echo "=== Smoke test passed ==="
