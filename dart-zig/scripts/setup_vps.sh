#!/usr/bin/env bash
# setup_vps.sh — one-shot setup for an x86_64 Linux VPS.
# Run from the dart-zig directory: bash scripts/setup_vps.sh
# Builds: Dart engine (JIT+AOT), BoringSSL, dart-zig binaries, snapshots.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DART_ZIG="$(cd "$SCRIPT_DIR/.." && pwd)"
SDK="$(cd "$DART_ZIG/.." && pwd)"

ARCH=$(uname -m)   # x86_64 or aarch64
NPROC=$(nproc)

echo "[setup] dart-zig VPS setup  arch=$ARCH  cores=$NPROC"
echo "[setup] SDK root: $SDK"
echo "[setup] dart-zig: $DART_ZIG"
echo ""

# ── 1. Zig ────────────────────────────────────────────────────────────────────
ZIG_VER="0.15.2"
if ! command -v zig &>/dev/null || [[ "$(zig version 2>/dev/null)" != "$ZIG_VER" ]]; then
    echo "[zig] Installing Zig $ZIG_VER for $ARCH..."
    case "$ARCH" in
        x86_64)  ZIG_TAR="zig-x86_64-linux-${ZIG_VER}.tar.xz" ;;
        aarch64) ZIG_TAR="zig-aarch64-linux-${ZIG_VER}.tar.xz" ;;
        *) echo "Unsupported arch: $ARCH"; exit 1 ;;
    esac
    curl -fL "https://ziglang.org/download/${ZIG_VER}/${ZIG_TAR}" -o /tmp/zig.tar.xz
    sudo tar -xf /tmp/zig.tar.xz -C /opt/
    ZIG_DIR=$(ls /opt/ | grep "zig-" | tail -1)
    sudo ln -sf "/opt/$ZIG_DIR/zig" /usr/local/bin/zig
    rm /tmp/zig.tar.xz
fi
echo "[zig] $(zig version)"

# ── 2. System deps ────────────────────────────────────────────────────────────
echo "[deps] Installing system packages..."
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
    build-essential git curl python3 python3-pip \
    pkg-config cmake ninja-build \
    liburing-dev \
    wrk 2>/dev/null || true

# wrk may not be in apt — try from source if missing
if ! command -v wrk &>/dev/null; then
    echo "[wrk] Building wrk from source..."
    git clone --depth=1 https://github.com/wg/wrk /tmp/wrk-src
    make -C /tmp/wrk-src -j"$NPROC"
    sudo cp /tmp/wrk-src/wrk /usr/local/bin/wrk
fi

# ── 3. Dart engine ────────────────────────────────────────────────────────────
ENGINE_OUT="$SDK/out/ReleaseX64"
JIT_SO="$ENGINE_OUT/libdart_engine_jit_shared.so"
AOT_SO="$ENGINE_OUT/libdart_engine_aot_shared.so"

if [[ -f "$JIT_SO" && -f "$AOT_SO" ]]; then
    echo "[engine] Already built: $ENGINE_OUT"
else
    echo "[engine] Building Dart engine (JIT + AOT) — this takes 20-40 min..."

    # depot_tools
    if ! command -v gclient &>/dev/null; then
        echo "[engine] Installing depot_tools..."
        git clone --depth=1 https://chromium.googlesource.com/chromium/tools/depot_tools.git \
            "$HOME/depot_tools"
        export PATH="$HOME/depot_tools:$PATH"
        echo "export PATH=\"$HOME/depot_tools:\$PATH\"" >> ~/.bashrc
    fi
    export PATH="$HOME/depot_tools:${PATH:-}"

    # gclient sync (only if out/ReleaseX64 doesn't exist)
    cd "$SDK/.."
    echo "[engine] Running gclient sync (may take a while)..."
    gclient sync -j"$NPROC" --no-history 2>&1 | tail -5

    # Build JIT + AOT shared libs + dart binary
    cd "$SDK"
    echo "[engine] Building dart_engine_jit_shared dart_engine_aot_shared dart..."
    case "$ARCH" in
        x86_64)  BUILD_ARCH="x64" ;;
        aarch64) BUILD_ARCH="arm64" ;;
    esac
    python3 tools/build.py --mode=release --arch="$BUILD_ARCH" \
        -j"$NPROC" \
        dart_engine_jit_shared dart_engine_aot_shared dart gen_snapshot

    echo "[engine] Built:"
    ls -lh "$ENGINE_OUT/libdart_engine_jit_shared.so" \
           "$ENGINE_OUT/libdart_engine_aot_shared.so" \
           "$ENGINE_OUT/dart" \
           "$ENGINE_OUT/gen_snapshot"
fi

# ── 4. BoringSSL ──────────────────────────────────────────────────────────────
BORING_BUILD="$DART_ZIG/boringssl-build"
if [[ -f "$BORING_BUILD/libssl.a" ]]; then
    echo "[boringssl] Already built: $BORING_BUILD"
else
    echo "[boringssl] Building BoringSSL..."
    bash "$DART_ZIG/scripts/build_boringssl.sh"
fi

# ── 5. dart-zig binaries ──────────────────────────────────────────────────────
cd "$DART_ZIG"
echo "[dart-zig] Building dart-zig (JIT) and dart-zig-aot..."
zig build -Doptimize=ReleaseFast
zig build -Doptimize=ReleaseFast -Daot=true
echo "[dart-zig] Built:"
ls -lh zig-out/bin/dart-zig zig-out/bin/dart-zig-aot

# ── 6. Dart snapshots ─────────────────────────────────────────────────────────
echo "[snapshots] Compiling HTTP snapshots..."
export LD_LIBRARY_PATH="$ENGINE_OUT"
DART="$ENGINE_OUT/dart"
GEN_SNAP="$ENGINE_OUT/gen_snapshot"
PLATFORM="$ENGINE_OUT/vm_platform.dill"
GEN_KERNEL="$SDK/pkg/vm/bin/gen_kernel.dart"
PKG_CFG="$SDK/.dart_tool/package_config.json"
SNAP_DIR="$DART_ZIG/test-snapshots"
mkdir -p "$SNAP_DIR"

compile_jit() {
    local src="$1" out="$2"
    echo "  [JIT] $(basename $src) → $(basename $out)"
    "$DART" "$GEN_KERNEL" --platform "$PLATFORM" --link-platform \
        --packages "$PKG_CFG" -o "$out" "$src"
}
compile_aot() {
    local src="$1" dill="$2" dylib="$3"
    echo "  [AOT] $(basename $src) → $(basename $dylib)"
    "$DART" "$GEN_KERNEL" --aot --platform "$PLATFORM" --link-platform \
        --packages "$PKG_CFG" -o "$dill" "$src"
    "$GEN_SNAP" --snapshot_kind=app-aot-elf --elf="$dylib" --strip "$dill" 2>&1 | grep -v "^Warning:" || true
}

compile_jit  "$DART_ZIG/lib/http_server.dart"  "$SNAP_DIR/http_server.dill"
compile_aot  "$DART_ZIG/lib/http_server.dart"  "$SNAP_DIR/http_server_aot.dill"  "$SNAP_DIR/http_server_aot.so"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Setup complete!"
echo "  Engine:    $ENGINE_OUT"
echo "  Binaries:  $DART_ZIG/zig-out/bin/"
echo "  Snapshots: $SNAP_DIR/"
echo ""
echo "  Quick test:"
echo "    export LD_LIBRARY_PATH=$ENGINE_OUT"
echo "    ./zig-out/bin/dart-zig test-snapshots/http_server.dill 8080 &"
echo "    wrk -t4 -c128 -d5s http://127.0.0.1:8080/"
echo ""
echo "  Multi-worker benchmark (CPU-pinned):"
echo "    taskset -c 0-2 ./zig-out/bin/dart-zig-aot --workers=3 test-snapshots/http_server_aot.so 8080 &"
echo "    taskset -c 3-5 wrk -t3 -c256 -d10s http://127.0.0.1:8080/"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
