#!/usr/bin/env bash
# bench_vps.sh — pull latest, rebuild, and benchmark all worker/mode combos.
# Run from the dart-zig directory on the 6-core Linux VPS:
#   bash scripts/bench_vps.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DART_ZIG="$(cd "$SCRIPT_DIR/.." && pwd)"
SDK="$(cd "$DART_ZIG/.." && pwd)"

NPROC=$(nproc)
ENGINE_OUT="$SDK/out/ReleaseX64"
export LD_LIBRARY_PATH="$ENGINE_OUT"

DART="$ENGINE_OUT/dart"
GEN_KERNEL="$SDK/pkg/vm/bin/gen_kernel.dart"
GEN_SNAP="$ENGINE_OUT/gen_snapshot"
PLATFORM="$ENGINE_OUT/vm_platform.dill"
PKG_CFG="$SDK/.dart_tool/package_config.json"
SNAP_DIR="$DART_ZIG/test-snapshots"

ZIG_BIN=$(command -v zig)
# Prefer the pinned 0.15.2 snap if available
if [[ -x /snap/zig/15308/zig ]]; then
    ZIG_BIN=/snap/zig/15308/zig
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  dart-zig VPS benchmark"
echo "  Zig:    $($ZIG_BIN version)"
echo "  Cores:  $NPROC"
echo "  Engine: $ENGINE_OUT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 1. Pull latest ────────────────────────────────────────────────────────────
echo ""
echo "[pull] Fetching latest dart-zig from fork..."
cd "$SDK"
git fetch fork dart-zig
# Fast-forward if possible, otherwise hard-reset to fork
git merge --ff-only fork/dart-zig 2>/dev/null || {
    echo "[pull] Fast-forward failed, hard-resetting to fork/dart-zig..."
    git checkout -B dart-zig-test fork/dart-zig
}
echo "[pull] HEAD: $(git rev-parse --short HEAD)"

# ── 2. Build Zig binaries ─────────────────────────────────────────────────────
cd "$DART_ZIG"
echo ""
echo "[build] Building JIT binary..."
"$ZIG_BIN" build -Doptimize=ReleaseFast
echo "[build] Building AOT binary..."
"$ZIG_BIN" build -Doptimize=ReleaseFast -Daot=true
echo "[build] Binaries:"
ls -lh zig-out/bin/dart-zig zig-out/bin/dart-zig-aot

# ── 3. Compile snapshots ──────────────────────────────────────────────────────
mkdir -p "$SNAP_DIR"
echo ""
echo "[snapshots] Compiling http_server.dill (JIT)..."
"$DART" "$GEN_KERNEL" --platform "$PLATFORM" --link-platform \
    --packages "$PKG_CFG" -o "$SNAP_DIR/http_server.dill" "$DART_ZIG/lib/http_server.dart"

echo "[snapshots] Compiling http_server_aot.so (AOT)..."
"$DART" "$GEN_KERNEL" --aot --platform "$PLATFORM" --link-platform \
    --packages "$PKG_CFG" -o "$SNAP_DIR/http_server_aot.dill" "$DART_ZIG/lib/http_server.dart"
"$GEN_SNAP" --snapshot_kind=app-aot-elf --elf="$SNAP_DIR/http_server_aot.so" \
    --strip "$SNAP_DIR/http_server_aot.dill" 2>&1 | grep -v "^Warning:" || true
echo "[snapshots] Done:"
ls -lh "$SNAP_DIR/http_server.dill" "$SNAP_DIR/http_server_aot.so"

# ── 4. Benchmark helper ───────────────────────────────────────────────────────
JIT_BIN="$DART_ZIG/zig-out/bin/dart-zig"
AOT_BIN="$DART_ZIG/zig-out/bin/dart-zig-aot"
JIT_SNAP="$SNAP_DIR/http_server.dill"
AOT_SNAP="$SNAP_DIR/http_server_aot.so"
PORT=8080

# Server cores: 0..WORKERS-1  (max 3, leaving cores 3-5 for wrk)
# Wrk cores: always 3-5
WRK_CORES="3-5"
WRK_THREADS=3
WRK_CONNS=256
WRK_DURATION=10s

declare -A RESULTS

run_bench() {
    local label="$1"
    local workers="$2"
    local bin="$3"
    local snap="$4"

    # Pin server to cores 0..(workers-1)
    local server_cores="0"
    if [[ $workers -gt 1 ]]; then
        server_cores="0-$((workers - 1))"
    fi

    # Kill any leftover server
    pkill -f "dart-zig.*$PORT" 2>/dev/null || true
    sleep 0.3

    echo -n "  [$label / ${workers}w] starting server on cores $server_cores ... "
    if [[ $workers -gt 1 ]]; then
        taskset -c "$server_cores" "$bin" --workers="$workers" "$snap" $PORT &
    else
        taskset -c "$server_cores" "$bin" "$snap" $PORT &
    fi
    local SERVER_PID=$!
    sleep 1.5

    # Warm-up (not recorded)
    taskset -c "$WRK_CORES" wrk -t"$WRK_THREADS" -c"$WRK_CONNS" -d3s \
        "http://127.0.0.1:$PORT/" >/dev/null 2>&1 || true

    # Measured run
    local output
    output=$(taskset -c "$WRK_CORES" wrk -t"$WRK_THREADS" -c"$WRK_CONNS" \
        -d"$WRK_DURATION" "http://127.0.0.1:$PORT/" 2>&1)
    local rps
    rps=$(echo "$output" | grep "Requests/sec:" | awk '{printf "%.0f", $2}')

    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    sleep 0.5

    RESULTS["$label/$workers"]="$rps"
    echo "$rps req/s"
}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Running benchmarks (wrk -t3 -c256 -d10s, pinned)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

run_bench "JIT" 1 "$JIT_BIN" "$JIT_SNAP"
run_bench "JIT" 3 "$JIT_BIN" "$JIT_SNAP"
run_bench "JIT" 6 "$JIT_BIN" "$JIT_SNAP"
run_bench "AOT" 1 "$AOT_BIN" "$AOT_SNAP"
run_bench "AOT" 3 "$AOT_BIN" "$AOT_SNAP"
run_bench "AOT" 6 "$AOT_BIN" "$AOT_SNAP"

# ── 5. Summary table ──────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Results  (wrk -t3 -c256 -d10s, taskset pinned)"
printf "  %-8s %10s %10s %10s\n" "Mode" "1 worker" "3 workers" "6 workers"
echo "  ──────────────────────────────────────────────"
for mode in JIT AOT; do
    printf "  %-8s %10s %10s %10s\n" \
        "$mode" \
        "${RESULTS[$mode/1]:-n/a}" \
        "${RESULTS[$mode/3]:-n/a}" \
        "${RESULTS[$mode/6]:-n/a}"
done

# Scaling ratios
echo ""
echo "  Scaling ratios (vs 1 worker):"
for mode in JIT AOT; do
    r1="${RESULTS[$mode/1]:-0}"
    r3="${RESULTS[$mode/3]:-0}"
    r6="${RESULTS[$mode/6]:-0}"
    if [[ $r1 -gt 0 ]]; then
        s3=$(awk "BEGIN {printf \"%.2f\", $r3 / $r1}")
        s6=$(awk "BEGIN {printf \"%.2f\", $r6 / $r1}")
        printf "  %-8s  3w = %sx   6w = %sx\n" "$mode" "$s3" "$s6"
    fi
done
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
