#!/usr/bin/env bash
# Recompile all dart-zig and dart:io snapshots.
# Run this after editing any .dart source file.
#
# Usage:
#   ./scripts/compile_snapshots.sh           # all snapshots
#   ./scripts/compile_snapshots.sh http      # HTTP targets only
#   ./scripts/compile_snapshots.sh https     # HTTPS targets only
#   ./scripts/compile_snapshots.sh echo      # echo/bench targets only
#   ./scripts/compile_snapshots.sh dartio    # dart:io AOT exes only
#
# dart-zig snapshots require:
#   xcodebuild/ReleaseARM64/dart       (SDK-bundled dart 3.12)
#   xcodebuild/ReleaseARM64/gen_snapshot
#   xcodebuild/ReleaseARM64/vm_platform.dill
#
# dart:io AOT exes require:
#   dart (system dart, ≥3.11)          used for compile
#   dartaotruntime                      used at bench time (auto-detected)
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SDK="$(cd -- "${ROOT}/.." && pwd)"

DART="${SDK}/xcodebuild/ReleaseARM64/dart"
DART_SYSTEM="$(command -v dart)"
GEN_SNAPSHOT="${SDK}/xcodebuild/ReleaseARM64/gen_snapshot"
PLATFORM="${SDK}/xcodebuild/ReleaseARM64/vm_platform.dill"
GEN_KERNEL="${SDK}/pkg/vm/bin/gen_kernel.dart"
PKG_CFG="${SDK}/.dart_tool/package_config.json"
SNAP_DIR="${ROOT}/test-snapshots"
BIN_DIR="${ROOT}/bin"
LIB="${ROOT}/lib"
CERTS="${ROOT}/test-certs"

SUITE="${1:-all}"

# ── Sanity checks ─────────────────────────────────────────────────────────────
for f in "$DART" "$GEN_SNAPSHOT" "$PLATFORM" "$GEN_KERNEL" "$PKG_CFG"; do
  [[ -f "$f" ]] || { echo "Missing: $f"; exit 1; }
done
mkdir -p "$SNAP_DIR" "$BIN_DIR"

# ── dart-zig helpers ──────────────────────────────────────────────────────────
compile_jit() {
  local src="$1"; local out="$2"
  printf "  [JIT]  %-35s → %s\n" "$(basename "$src")" "$(basename "$out")"
  "$DART" "$GEN_KERNEL" \
    --platform "$PLATFORM" \
    --link-platform \
    --packages "$PKG_CFG" \
    -o "$out" \
    "$src"
}

compile_aot() {
  local src="$1"; local dill_out="$2"; local dylib_out="$3"
  printf "  [AOT]  %-35s → %s\n" "$(basename "$src")" "$(basename "$dylib_out")"
  "$DART" "$GEN_KERNEL" \
    --aot \
    --platform "$PLATFORM" \
    --link-platform \
    --packages "$PKG_CFG" \
    -o "$dill_out" \
    "$src"
  "$GEN_SNAPSHOT" \
    --snapshot_kind=app-aot-macho-dylib \
    --macho="$dylib_out" \
    --strip \
    "$dill_out" 2>&1 | grep -v "^Warning:" || true
}

# ── dart:io AOT helper ────────────────────────────────────────────────────────
# Compiles via system dart (avoids SDK 3.12 pubspec constraint by building
# from a temp directory with no package config).
compile_dartio_aot() {
  local src="$1"; local out="$2"; local extra_args="${3:-}"
  local base; base="$(basename "$src")"
  printf "  [AOT]  %-35s → %s\n" "$base" "$(basename "$out")"

  local tmpdir; tmpdir="$(mktemp -d)"
  local tmpsrc="$tmpdir/$base"
  cp "$src" "$tmpsrc"

  # Patch cert path in HTTPS server so the AOT binary can find certs.
  if [[ "$src" == *https* ]]; then
    sed -i '' \
      "s|return '\$parent/test-certs'|return '${CERTS}'|g" \
      "$tmpsrc" 2>/dev/null || true
  fi

  (cd "$tmpdir" && "$DART_SYSTEM" compile aot-snapshot -o "$out" "$tmpsrc" 2>&1 | grep -v "^$") || true
  rm -rf "$tmpdir"
}

# ── HTTP ──────────────────────────────────────────────────────────────────────
if [[ "$SUITE" == "all" || "$SUITE" == "http" ]]; then
  echo ""
  echo "HTTP snapshots (dart-zig):"
  compile_jit  "${LIB}/http_server.dart"  "${SNAP_DIR}/http_server.dill"
  compile_aot  "${LIB}/http_server.dart"  "${SNAP_DIR}/http_server_aot.dill"  "${SNAP_DIR}/http_server_aot.dylib"

  echo ""
  echo "HTTP snapshots (dart:io AOT):"
  compile_dartio_aot "${LIB}/dart_io_http_server.dart" "${BIN_DIR}/dart_io_http_server.aot"
fi

# ── HTTPS ─────────────────────────────────────────────────────────────────────
if [[ "$SUITE" == "all" || "$SUITE" == "https" ]]; then
  echo ""
  echo "HTTPS snapshots (dart-zig):"
  compile_jit  "${LIB}/https_server.dart"  "${SNAP_DIR}/https_server.dill"
  compile_aot  "${LIB}/https_server.dart"  "${SNAP_DIR}/https_server_aot.dill"  "${SNAP_DIR}/https_server_aot.dylib"

  echo ""
  echo "HTTPS snapshots (dart:io AOT):"
  compile_dartio_aot "${LIB}/dart_io_https_server.dart" "${BIN_DIR}/dart_io_https_server.aot"
fi

# ── Echo (legacy) ─────────────────────────────────────────────────────────────
if [[ "$SUITE" == "all" || "$SUITE" == "echo" ]]; then
  echo ""
  echo "Echo snapshots (dart-zig):"
  compile_jit "${LIB}/echo_server.dart"           "${SNAP_DIR}/echo_server.dill"
  compile_jit "${LIB}/dart_io_echo.dart"          "${SNAP_DIR}/dart_io_echo.dill"
  compile_jit "${LIB}/bench_echo_concurrent.dart" "${SNAP_DIR}/bench_echo_concurrent.dill"
  compile_aot "${LIB}/echo_server.dart"           "${SNAP_DIR}/echo_server_aot.dill"  "${SNAP_DIR}/echo_server_aot.dylib"
fi

echo ""
echo "Done."
echo "  dart-zig snapshots → ${SNAP_DIR}/"
echo "  dart:io AOT exes   → ${BIN_DIR}/"
