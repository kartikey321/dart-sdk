#!/usr/bin/env bash
# bench_pipeline.sh — HTTP/1.1 pipelined benchmark matrix for dart-zig and dart:io.
#
# Linux-focused helper for measuring pipelined keep-alive throughput with a
# fixed request pipeline depth. Uses bench_pipeline.py as the client.
#
# Usage:
#   bash scripts/bench_pipeline.sh
#   bash scripts/bench_pipeline.sh quick
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SDK="$(cd -- "${ROOT}/.." && pwd)"

MODE="${1:-full}"

ZIG_JIT="${ROOT}/zig-out/bin/dart-zig"
ZIG_AOT="${ROOT}/zig-out/bin/dart-zig-aot"
ZIG_JIT_SNAP="${ROOT}/test-snapshots/http_server.dill"
ZIG_AOT_SNAP="${ROOT}/test-snapshots/http_server_aot.so"
DART="${SDK}/out/ReleaseX64/dart"
DIO_SRC="${ROOT}/lib/dart_io_http_server.dart"
PIPE_CLIENT="${ROOT}/scripts/bench_pipeline.py"
REUSEPORT_SHIM="/tmp/reuseport_shim.so"

export LD_LIBRARY_PATH="${SDK}/out/ReleaseX64"

PORT=18300
NCPU=$(nproc)
if [[ "${MODE}" == "quick" ]]; then
  THREADS=3
  CONNECTIONS=24
  PIPELINE=8
  DURATION=5
else
  THREADS=6
  CONNECTIONS=64
  PIPELINE=16
  DURATION=10
fi

WRK_CORES="3-5"
SERVER_PID=()

need() {
  command -v "$1" >/dev/null || { echo "missing required command: $1"; exit 1; }
}

for f in "$ZIG_JIT" "$ZIG_AOT" "$ZIG_JIT_SNAP" "$ZIG_AOT_SNAP" "$DART" "$DIO_SRC" "$PIPE_CLIENT"; do
  [[ -e "$f" ]] || { echo "missing required file: $f"; exit 1; }
done
need python3
need taskset
need cc
need nproc

build_reuseport_shim() {
  if [[ -f "$REUSEPORT_SHIM" ]]; then
    return
  fi
  cat > /tmp/reuseport_shim.c <<'EOF'
#define _GNU_SOURCE
#include <sys/socket.h>
#include <dlfcn.h>
#include <stddef.h>

typedef int (*bind_fn)(int, const struct sockaddr *, socklen_t);

int bind(int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
    static bind_fn real_bind = (bind_fn)0;
    if (!real_bind)
        real_bind = (bind_fn)dlsym(RTLD_NEXT, "bind");

    int type = 0, opt = 1;
    socklen_t tlen = sizeof(type);
    getsockopt(sockfd, SOL_SOCKET, SO_TYPE, &type, &tlen);
    if (type == SOCK_STREAM)
        setsockopt(sockfd, SOL_SOCKET, SO_REUSEPORT, &opt, sizeof(opt));

    return real_bind(sockfd, addr, addrlen);
}
EOF
  cc -shared -fPIC -O2 -ldl -o "$REUSEPORT_SHIM" /tmp/reuseport_shim.c
}

stop_all() {
  kill "${SERVER_PID[@]}" 2>/dev/null || true
  wait "${SERVER_PID[@]}" 2>/dev/null || true
  SERVER_PID=()
  lsof -ti tcp:"$PORT" 2>/dev/null | xargs kill -9 2>/dev/null || true
  sleep 0.3
}

trap stop_all EXIT

wait_for_port() {
  local i=0
  while (( i++ < 40 )); do
    sleep 0.2
    nc -z 127.0.0.1 "$PORT" 2>/dev/null && return 0
  done
  return 1
}

bench_pipeline() {
  taskset -c "$WRK_CORES" python3 "$PIPE_CLIENT" \
    --host 127.0.0.1 \
    --port "$PORT" \
    --threads "$THREADS" \
    --connections "$CONNECTIONS" \
    --pipeline "$PIPELINE" \
    --duration "$DURATION"
}

extract_rps() {
  sed -n 's/^Requests\/sec:[[:space:]]*//p' | head -1
}

row() {
  local label="$1" rps="$2"
  printf "  %-28s %12s req/s\n" "$label" "$rps"
}

start_zig() {
  local mode="$1" workers="$2" bin="$3" snap="$4"
  local pinned_workers=$(( workers < 3 ? workers : 3 ))
  local server_cores="0"
  if [[ $pinned_workers -gt 1 ]]; then
    server_cores="0-$((pinned_workers - 1))"
  fi

  stop_all
  if [[ "$workers" -gt 1 ]]; then
    taskset -c "$server_cores" "$bin" --workers="$workers" "$snap" "$PORT" &>/tmp/bench_pipeline_${mode}_${workers}w.log &
  else
    taskset -c "$server_cores" "$bin" "$snap" "$PORT" &>/tmp/bench_pipeline_${mode}_${workers}w.log &
  fi
  SERVER_PID=("$!")
  wait_for_port
}

start_dio_multi() {
  local procs="$1"
  stop_all
  build_reuseport_shim
  SERVER_PID=()
  for _i in $(seq 1 "$procs"); do
    env LD_PRELOAD="$REUSEPORT_SHIM" taskset -c 0-2 "$DART" "$DIO_SRC" "$PORT" &>/tmp/bench_pipeline_dio_${_i}.log &
    SERVER_PID+=("$!")
  done
  wait_for_port
}

echo ""
echo "dart-zig pipelined benchmark"
echo "  Host cores:     $NCPU"
echo "  Client cores:   $WRK_CORES"
echo "  Threads:        $THREADS"
echo "  Connections:    $CONNECTIONS"
echo "  Pipeline depth: $PIPELINE"
echo "  Duration:       ${DURATION}s"
echo ""

declare -A RESULTS

run_case() {
  local key="$1" label="$2"
  local out rps
  out="$(bench_pipeline)"
  printf '%s\n' "$out"
  rps="$(printf '%s\n' "$out" | extract_rps)"
  RESULTS["$key"]="$rps"
  row "$label" "$rps"
  echo ""
}

for workers in 1 3 6; do
  start_zig "zig_jit" "$workers" "$ZIG_JIT" "$ZIG_JIT_SNAP"
  run_case "zig_jit_${workers}" "dart-zig JIT ${workers}w"
done

for workers in 1 3 6; do
  start_zig "zig_aot" "$workers" "$ZIG_AOT" "$ZIG_AOT_SNAP"
  run_case "zig_aot_${workers}" "dart-zig AOT ${workers}w"
done

start_dio_multi 1
run_case "dio_jit_1" "dart:io JIT 1p"

start_dio_multi 6
run_case "dio_jit_6" "dart:io JIT 6p"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Pipeline summary"
printf "  %-18s %12s %12s %12s\n" "Mode" "1 worker" "3 workers" "6 workers"
printf "  %-18s %12s %12s %12s\n" \
  "dart-zig JIT" \
  "${RESULTS[zig_jit_1]:-n/a}" \
  "${RESULTS[zig_jit_3]:-n/a}" \
  "${RESULTS[zig_jit_6]:-n/a}"
printf "  %-18s %12s %12s %12s\n" \
  "dart-zig AOT" \
  "${RESULTS[zig_aot_1]:-n/a}" \
  "${RESULTS[zig_aot_3]:-n/a}" \
  "${RESULTS[zig_aot_6]:-n/a}"
printf "  %-18s %12s %12s %12s\n" \
  "dart:io JIT" \
  "${RESULTS[dio_jit_1]:-n/a}" \
  "-" \
  "${RESULTS[dio_jit_6]:-n/a}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
