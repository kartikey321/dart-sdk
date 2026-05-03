#!/usr/bin/env bash
# package_runtime_bundle.sh — build a reusable Linux runtime bundle for
# dart-zig plus one reference benchmark HTTP app snapshot.
#
# Output layout:
#   dist/dart-zig-linux-x64/
#     bin/dart-zig
#     bin/dart-zig-aot
#     lib/libdart_engine_jit_shared.so
#     lib/libdart_engine_aot_shared.so
#     snapshots/benchmark_http_server.dill
#     snapshots/benchmark_http_server_aot.dill
#     snapshots/benchmark_http_server_aot.so
#     manifest.txt
#
# Tarball:
#   dist/dart-zig-linux-x64.tar.gz
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SDK="$(cd -- "${ROOT}/.." && pwd)"

ENGINE_OUT="${SDK}/out/ReleaseX64"
DART="${ENGINE_OUT}/dart"
GEN_SNAP="${ENGINE_OUT}/gen_snapshot"
PLATFORM="${ENGINE_OUT}/vm_platform.dill"
GEN_KERNEL="${SDK}/pkg/vm/bin/gen_kernel.dart"
PKG_CFG="${SDK}/.dart_tool/package_config.json"
SNAP_DIR="${ROOT}/test-snapshots"
DIST_DIR="${ROOT}/dist/dart-zig-linux-x64"
TARBALL="${ROOT}/dist/dart-zig-linux-x64.tar.gz"
ZIG_BIN="${ZIG_BIN:-$(command -v zig)}"

[[ -x "$ZIG_BIN" ]] || { echo "zig not found"; exit 1; }
[[ -x "$DART" ]] || { echo "missing $DART"; exit 1; }
[[ -x "$GEN_SNAP" ]] || { echo "missing $GEN_SNAP"; exit 1; }
[[ -f "$PLATFORM" ]] || { echo "missing $PLATFORM"; exit 1; }
[[ -f "$PKG_CFG" ]] || { echo "missing $PKG_CFG"; exit 1; }

mkdir -p "$SNAP_DIR" "${ROOT}/dist"

echo "[build] dart-zig JIT runtime"
(cd "$ROOT" && "$ZIG_BIN" build -Doptimize=ReleaseFast)
echo "[build] dart-zig AOT runtime"
(cd "$ROOT" && "$ZIG_BIN" build -Doptimize=ReleaseFast -Daot=true)

echo "[snapshot] benchmark_http_server.dill"
"$DART" "$GEN_KERNEL" \
  --platform "$PLATFORM" \
  --link-platform \
  --packages "$PKG_CFG" \
  -o "${SNAP_DIR}/benchmark_http_server.dill" \
  "${ROOT}/lib/benchmark_http_server.dart"

echo "[snapshot] benchmark_http_server_aot.so"
"$DART" "$GEN_KERNEL" \
  --aot \
  --platform "$PLATFORM" \
  --link-platform \
  --packages "$PKG_CFG" \
  -o "${SNAP_DIR}/benchmark_http_server_aot.dill" \
  "${ROOT}/lib/benchmark_http_server.dart"
"$GEN_SNAP" \
  --snapshot_kind=app-aot-elf \
  --elf="${SNAP_DIR}/benchmark_http_server_aot.so" \
  --strip "${SNAP_DIR}/benchmark_http_server_aot.dill" 2>&1 | grep -v "^Warning:" || true

echo "[bundle] assembling ${DIST_DIR}"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR/bin" "$DIST_DIR/lib" "$DIST_DIR/snapshots"

cp "${ROOT}/zig-out/bin/dart-zig" "$DIST_DIR/bin/"
cp "${ROOT}/zig-out/bin/dart-zig-aot" "$DIST_DIR/bin/"
cp "${ENGINE_OUT}/libdart_engine_jit_shared.so" "$DIST_DIR/lib/"
cp "${ENGINE_OUT}/libdart_engine_aot_shared.so" "$DIST_DIR/lib/"
cp "${SNAP_DIR}/benchmark_http_server.dill" "$DIST_DIR/snapshots/"
cp "${SNAP_DIR}/benchmark_http_server_aot.dill" "$DIST_DIR/snapshots/"
cp "${SNAP_DIR}/benchmark_http_server_aot.so" "$DIST_DIR/snapshots/"

cat > "${DIST_DIR}/manifest.txt" <<EOF
name=dart-zig-linux-x64
jit_binary=bin/dart-zig
jit_engine_lib=lib/libdart_engine_jit_shared.so
aot_binary=bin/dart-zig-aot
aot_engine_lib=lib/libdart_engine_aot_shared.so
reference_jit_snapshot=snapshots/benchmark_http_server.dill
reference_aot_snapshot=snapshots/benchmark_http_server_aot.so
generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
git_commit=$(git -C "$SDK" rev-parse HEAD 2>/dev/null || echo unknown)
EOF

echo "[bundle] creating ${TARBALL}"
tar -C "${ROOT}/dist" -czf "$TARBALL" "dart-zig-linux-x64"

echo ""
echo "Bundle directory: $DIST_DIR"
echo "Tarball:          $TARBALL"
