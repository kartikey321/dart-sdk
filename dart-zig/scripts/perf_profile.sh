#!/usr/bin/env bash
# perf_profile.sh — profile dart-zig server with perf during a wrk benchmark.
# Outputs:
#   perf-report.txt    — flat symbol profile (top functions by CPU time)
#   perf-data/         — raw perf.data (load with `perf report -i perf-data/perf.data`)
#   flamegraph.svg     — if FlameGraph is installed (clone into ~/FlameGraph)
#
# Usage:
#   bash scripts/perf_profile.sh [port=8080] [conns=256] [duration=10]
#
# Requires: perf, wrk. Optional: ~/FlameGraph for flamegraph output.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DART_ZIG="$(cd "$SCRIPT_DIR/.." && pwd)"
SDK="$(cd "$DART_ZIG/.." && pwd)"

PORT=${1:-8080}
CONNS=${2:-256}
DURATION=${3:-10}

ENGINE_OUT="$SDK/out/ReleaseX64"
export LD_LIBRARY_PATH="$ENGINE_OUT"

JIT_BIN="$DART_ZIG/zig-out/bin/dart-zig"
JIT_SNAP="$DART_ZIG/test-snapshots/http_server.dill"
PERF_DIR="$DART_ZIG/perf-data"
mkdir -p "$PERF_DIR"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  dart-zig perf profile"
echo "  Binary: $JIT_BIN"
echo "  Conns:  $CONNS   Duration: ${DURATION}s   Port: $PORT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Kill any leftover server
pkill -f "dart-zig.*$PORT" 2>/dev/null || true
sleep 0.5

# Start server
"$JIT_BIN" "$JIT_SNAP" $PORT &
SERVER_PID=$!
echo "Server PID: $SERVER_PID"
sleep 1.5

# Warmup
echo "Warming up (3s)..."
wrk -t4 -c"$CONNS" -d3s "http://127.0.0.1:$PORT/" >/dev/null 2>&1 || true
sleep 0.5

# Start perf recording in background
echo "Starting perf record..."
perf record -F 999 -p "$SERVER_PID" -g \
    -o "$PERF_DIR/perf.data" -- sleep "$DURATION" &
PERF_PID=$!

# Measured run
echo "Running measured wrk (${DURATION}s, $CONNS conns)..."
WRK_OUT=$(wrk -t4 -c"$CONNS" -d"${DURATION}s" "http://127.0.0.1:$PORT/" 2>&1)
echo "$WRK_OUT"

# Wait for perf to finish
wait "$PERF_PID" 2>/dev/null || true

# Cleanup
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Top functions by CPU time:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Flat profile
perf report -i "$PERF_DIR/perf.data" --stdio --no-children \
    --sort=overhead,symbol -n 2>/dev/null | head -60 | tee "$DART_ZIG/perf-report.txt"

# Annotate io_uring syscall if present
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Syscall breakdown (io_uring_enter, recvfrom, etc):"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
perf report -i "$PERF_DIR/perf.data" --stdio --no-children \
    --sort=overhead,symbol -n 2>/dev/null | grep -E "io_uring|recv|send|write|read|memmove|memcpy|route|parse" | head -20 || true

# Flamegraph if available
FLAMEGRAPH_DIR="$HOME/FlameGraph"
if [[ -x "$FLAMEGRAPH_DIR/flamegraph.pl" ]]; then
    echo ""
    echo "Generating flamegraph..."
    perf script -i "$PERF_DIR/perf.data" 2>/dev/null \
        | "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" \
        | "$FLAMEGRAPH_DIR/flamegraph.pl" > "$DART_ZIG/flamegraph.svg"
    echo "Flamegraph: $DART_ZIG/flamegraph.svg"
else
    echo ""
    echo "Tip: install FlameGraph for SVG output:"
    echo "  git clone https://github.com/brendangregg/FlameGraph ~/FlameGraph"
    echo "  Then re-run this script."
    echo ""
    echo "Or view raw data with:"
    echo "  perf report -i $PERF_DIR/perf.data"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Raw perf data: $PERF_DIR/perf.data"
echo "  Flat report:   $DART_ZIG/perf-report.txt"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
