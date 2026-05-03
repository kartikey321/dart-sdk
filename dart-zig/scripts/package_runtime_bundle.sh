#!/usr/bin/env bash
# package_runtime_bundle.sh — build a reusable Linux runtime bundle for
# dart-zig.
#
# Output layout:
#   dist/dart-zig-linux-x64/
#     bin/dart-zig
#     bin/dart-zig-aot
#     lib/libdart_engine_jit_shared.so
#     lib/libdart_engine_aot_shared.so
#     manifest.txt
#
# Tarball:
#   dist/dart-zig-linux-x64.tar.gz
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SDK="$(cd -- "${ROOT}/.." && pwd)"

ENGINE_OUT="${SDK}/out/ReleaseX64"
DIST_DIR="${ROOT}/dist/dart-zig-linux-x64"
TARBALL="${ROOT}/dist/dart-zig-linux-x64.tar.gz"
ZIG_BIN="${ZIG_BIN:-$(command -v zig)}"

[[ -x "$ZIG_BIN" ]] || { echo "zig not found"; exit 1; }
[[ -f "${ENGINE_OUT}/libdart_engine_jit_shared.so" ]] || { echo "missing libdart_engine_jit_shared.so"; exit 1; }
[[ -f "${ENGINE_OUT}/libdart_engine_aot_shared.so" ]] || { echo "missing libdart_engine_aot_shared.so"; exit 1; }

mkdir -p "${ROOT}/dist"

echo "[build] dart-zig JIT runtime"
(cd "$ROOT" && "$ZIG_BIN" build -Doptimize=ReleaseFast)
echo "[build] dart-zig AOT runtime"
(cd "$ROOT" && "$ZIG_BIN" build -Doptimize=ReleaseFast -Daot=true)

echo "[bundle] assembling ${DIST_DIR}"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR/bin" "$DIST_DIR/lib"

cp "${ROOT}/zig-out/bin/dart-zig" "$DIST_DIR/bin/"
cp "${ROOT}/zig-out/bin/dart-zig-aot" "$DIST_DIR/bin/"
cp "${ENGINE_OUT}/libdart_engine_jit_shared.so" "$DIST_DIR/lib/"
cp "${ENGINE_OUT}/libdart_engine_aot_shared.so" "$DIST_DIR/lib/"

cat > "${DIST_DIR}/manifest.txt" <<EOF
name=dart-zig-linux-x64
jit_binary=bin/dart-zig
jit_engine_lib=lib/libdart_engine_jit_shared.so
aot_binary=bin/dart-zig-aot
aot_engine_lib=lib/libdart_engine_aot_shared.so
generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
git_commit=$(git -C "$SDK" rev-parse HEAD 2>/dev/null || echo unknown)
EOF

echo "[bundle] creating ${TARBALL}"
tar -C "${ROOT}/dist" -czf "$TARBALL" "dart-zig-linux-x64"

echo ""
echo "Bundle directory: $DIST_DIR"
echo "Tarball:          $TARBALL"
