#!/usr/bin/env bash
set -euo pipefail

SDK=/workspace/sdk
DART_ZIG=$SDK/dart-zig
ENGINE_LIB=$SDK/out/ReleaseARM64
SNAPS=$DART_ZIG/test-snapshots

# Install Zig and rebuild if needed
if [ ! -f /usr/local/bin/zig ]; then
    curl -sL "https://ziglang.org/download/0.15.2/zig-aarch64-linux-0.15.2.tar.xz" -o /tmp/zig.tar.xz
    tar -xf /tmp/zig.tar.xz -C /opt/
    ZIG_DIR=$(ls /opt/ | grep zig | head -1)
    ln -sf /opt/$ZIG_DIR/zig /usr/local/bin/zig
fi

echo "=== Rebuilding dart-zig (Linux / io_uring) ==="
cd $DART_ZIG && ZIG_GLOBAL_CACHE_DIR=.zig-global-cache-linux zig build 2>&1
BIN=$DART_ZIG/zig-out/bin/dart-zig
echo "Built: $BIN"

# Persist the freshly-built Linux binary to zig-out-linux/bin/ on the volume
# so callers outside Docker (e.g. CI) can reference it without re-running Docker.
mkdir -p $DART_ZIG/zig-out-linux/bin
cp $BIN $DART_ZIG/zig-out-linux/bin/dart-zig
echo "Copied to: $DART_ZIG/zig-out-linux/bin/dart-zig"
echo ""

export LD_LIBRARY_PATH=$ENGINE_LIB

echo "=== Starting dart-zig echo server (io_uring) on :9090 ==="
ZIG_LOG=/tmp/dart_zig_echo.log
IO_LOG=/tmp/dart_io_echo.log
: > "$ZIG_LOG"
: > "$IO_LOG"

cleanup() {
  kill ${ZIG_PID:-} ${IO_PID:-} 2>/dev/null || true
  wait ${ZIG_PID:-} ${IO_PID:-} 2>/dev/null || true
}
trap cleanup EXIT

$BIN $SNAPS/echo_server.dill 9090 > "$ZIG_LOG" 2>&1 &
ZIG_PID=$!

echo "=== Starting dart:io echo server on :9091 ==="
$BIN $SNAPS/dart_io_echo.dill 9091 > "$IO_LOG" 2>&1 &
IO_PID=$!

wait_for_ready() {
  local name=$1
  local pid=$2
  local log=$3
  local ready_pattern=$4
  local i

  for i in $(seq 1 30); do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "ERROR: $name exited before becoming ready."
      sed -n '1,120p' "$log" || true
      exit 1
    fi

    if grep -Eq "bind failed|Unhandled exception|SocketException|Error handling isolate message" "$log"; then
      echo "ERROR: $name failed during startup."
      sed -n '1,120p' "$log" || true
      exit 1
    fi

    if grep -q "$ready_pattern" "$log"; then
      return 0
    fi

    sleep 0.2
  done

  echo "ERROR: timed out waiting for $name startup."
  sed -n '1,120p' "$log" || true
  exit 1
}

wait_for_ready "dart-zig server" "$ZIG_PID" "$ZIG_LOG" "dart-zig echo server on port"
wait_for_ready "dart:io server" "$IO_PID" "$IO_LOG" "dart:io echo server on port"

echo ""
echo "========================================"
echo "  dart-zig  (zig_io / io_uring)"
echo "========================================"
$BIN $SNAPS/bench_echo_concurrent.dill 127.0.0.1 9090 200 100

echo ""
echo "========================================"
echo "  dart:io  (dart:io / io_uring host)"
echo "========================================"
$BIN $SNAPS/bench_echo_concurrent.dill 127.0.0.1 9091 200 100

echo ""
echo "=== done ==="
