#!/usr/bin/env bash
# HTTP / HTTPS throughput benchmark — dart-zig vs dart:io (JIT + AOT).
#
# Usage:
#   ./scripts/bench_http.sh                  # full suite (HTTP + HTTPS)
#   ./scripts/bench_http.sh http             # HTTP only
#   ./scripts/bench_http.sh https            # HTTPS only
#   ./scripts/bench_http.sh quick            # quick pass (-d4s -c64)
#
# Requirements:
#   wrk                  (brew install wrk)
#   zig-out/bin/dart-zig and dart-zig-aot built
#   test-snapshots/      built via ./scripts/compile_snapshots.sh
#   bin/dart_io_*.aot    built via ./scripts/compile_snapshots.sh dartio
#   dartaotruntime       (Flutter SDK or system dart SDK bin/)
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SDK="$(cd -- "${ROOT}/.." && pwd)"

ZIG_JIT="${ROOT}/zig-out/bin/dart-zig"
ZIG_AOT="${ROOT}/zig-out/bin/dart-zig-aot"
SNAPS="${ROOT}/test-snapshots"
BIN="${ROOT}/bin"
CERTS="${ROOT}/test-certs"
export DYLD_LIBRARY_PATH="${SDK}/xcodebuild/ReleaseARM64"

DARTAOT="$(command -v dartaotruntime 2>/dev/null || true)"
if [[ -z "$DARTAOT" ]]; then
  for candidate in \
    "${HOME}/Downloads/flutter/bin/cache/dart-sdk/bin/dartaotruntime" \
    "/usr/local/bin/dartaotruntime"; do
    [[ -x "$candidate" ]] && { DARTAOT="$candidate"; break; }
  done
fi
DART_SYSTEM="$(command -v dart)"

# dart:io JIT source — copied to /tmp to avoid SDK 3.12 pubspec constraint
cp "${ROOT}/lib/dart_io_http_server.dart"  /tmp/_bench_dart_io_http.dart
cp "${ROOT}/lib/dart_io_https_server.dart" /tmp/_bench_dart_io_https.dart

SUITE="${1:-all}"
if [[ "${SUITE}" == "quick" ]]; then
  WRK_T=2; WRK_C=64; WRK_D=4s
else
  WRK_T=4; WRK_C=128; WRK_D=10s
fi
NCPU=$(sysctl -n hw.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo 4)
BENCH_PORT=9199   # single port; we start/stop one server at a time

# ── Prerequisite checks ───────────────────────────────────────────────────────
for f in "$ZIG_JIT" "$ZIG_AOT"; do
  [[ -x "$f" ]] || { echo "Missing: $f  →  zig build -Doptimize=ReleaseFast [-Daot=true]"; exit 1; }
done
for f in \
  "${SNAPS}/http_server.dill"        "${SNAPS}/http_server_aot.dylib" \
  "${SNAPS}/https_server.dill"       "${SNAPS}/https_server_aot.dylib" \
  "${BIN}/dart_io_http_server.aot"   "${BIN}/dart_io_https_server.aot"
do
  [[ -f "$f" ]] || { echo "Missing: $f  →  ./scripts/compile_snapshots.sh"; exit 1; }
done
command -v wrk >/dev/null || { echo "wrk not found  →  brew install wrk"; exit 1; }
[[ -n "$DARTAOT" && -x "$DARTAOT" ]] || { echo "dartaotruntime not found"; exit 1; }

# ── Helpers ───────────────────────────────────────────────────────────────────
SERVER_PID=()

start() {
  local label="$1"; shift; local cmd=("$@")
  # Kill any leftover on the bench port
  lsof -ti tcp:"$BENCH_PORT" 2>/dev/null | xargs kill -9 2>/dev/null || true
  sleep 0.1

  "${cmd[@]}" &>/dev/null &
  SERVER_PID=("$!")

  local i=0
  while (( i++ < 30 )); do
    sleep 0.2
    nc -z 127.0.0.1 "$BENCH_PORT" 2>/dev/null && return 0
    kill -0 "${SERVER_PID[0]}" 2>/dev/null || { echo "  ✗ $label (died)"; return 1; }
  done
  echo "  ✗ $label (timeout port $BENCH_PORT)"
  return 1
}

stop() {
  kill "${SERVER_PID[@]}" 2>/dev/null || true
  wait "${SERVER_PID[@]}" 2>/dev/null || true
  SERVER_PID=()
  # Also kill any extras (multi-worker siblings)
  lsof -ti tcp:"$BENCH_PORT" 2>/dev/null | xargs kill -9 2>/dev/null || true
  sleep 0.3
}

# Run wrk, capture req/s as integer
bench_http()  { wrk -t"$WRK_T" -c"$WRK_C" -d"$WRK_D" "http://127.0.0.1:${BENCH_PORT}/"  2>/dev/null | awk '/Requests\/sec/{printf "%.0f", $2}'; }
bench_https() { wrk -t"$WRK_T" -c"$WRK_C" -d"$WRK_D" "https://127.0.0.1:${BENCH_PORT}/" 2>/dev/null | awk '/Requests\/sec/{printf "%.0f", $2}'; }

# Print a result row; $3 = baseline for multiplier (empty = no multiplier)
row() {
  local lbl="$1" rps="$2" base="${3:-}"
  if [[ -n "$base" && "$base" -gt 0 ]] 2>/dev/null; then
    local x; x=$(awk "BEGIN{printf \"%.1fx\", $rps/$base}")
    printf "  %-46s %9s req/s  %s\n" "$lbl" "$rps" "$x"
  else
    printf "  %-46s %9s req/s\n" "$lbl" "$rps"
  fi
}

hr()  { printf '\n%s\n' "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }
sec() { printf '\n\033[1m  %s\033[0m\n\n' "$1"; }

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
printf "dart-zig benchmark  ·  wrk %st %sc %s  ·  %d-core host\n" \
  "$WRK_T" "$WRK_C" "$WRK_D" "$NCPU"

# ════════════════════════════════════════════════════════════════════════════
#  HTTP
# ════════════════════════════════════════════════════════════════════════════
if [[ "$SUITE" == "all" || "$SUITE" == "http" || "$SUITE" == "quick" ]]; then
hr; sec "HTTP — 1 worker"

  # dart:io JIT
  start "dart:io HTTP JIT 1w" \
    "$DART_SYSTEM" /tmp/_bench_dart_io_http.dart "$BENCH_PORT"
  DIO_HTTP_JIT=$(bench_http); stop
  row "dart:io   HTTP  JIT  1-worker" "$DIO_HTTP_JIT"

  # dart:io AOT
  start "dart:io HTTP AOT 1w" \
    "$DARTAOT" "${BIN}/dart_io_http_server.aot" "$BENCH_PORT"
  DIO_HTTP_AOT=$(bench_http); stop
  row "dart:io   HTTP  AOT  1-worker" "$DIO_HTTP_AOT" "$DIO_HTTP_JIT"

  # dart-zig JIT 1w
  start "dart-zig HTTP JIT 1w" \
    "$ZIG_JIT" --workers=1 "${SNAPS}/http_server.dill" "$BENCH_PORT"
  ZIG_HTTP_JIT_1=$(bench_http); stop
  row "dart-zig  HTTP  JIT  1-worker" "$ZIG_HTTP_JIT_1" "$DIO_HTTP_JIT"

  # dart-zig AOT 1w
  start "dart-zig HTTP AOT 1w" \
    "$ZIG_AOT" --workers=1 "${SNAPS}/http_server_aot.dylib" "$BENCH_PORT"
  ZIG_HTTP_AOT_1=$(bench_http); stop
  row "dart-zig  HTTP  AOT  1-worker" "$ZIG_HTTP_AOT_1" "$DIO_HTTP_JIT"

hr; sec "HTTP — ${NCPU} workers (SO_REUSEPORT)"

  # dart:io AOT multi-worker (shared: true — N processes, same port)
  lsof -ti tcp:"$BENCH_PORT" 2>/dev/null | xargs kill -9 2>/dev/null || true; sleep 0.1
  SERVER_PID=()
  for _i in $(seq 1 "$NCPU"); do
    "$DARTAOT" "${BIN}/dart_io_http_server.aot" "$BENCH_PORT" &>/dev/null &
    SERVER_PID+=("$!")
  done
  sleep 1
  DIO_HTTP_AOT_N=$(bench_http)
  kill "${SERVER_PID[@]}" 2>/dev/null || true
  wait "${SERVER_PID[@]}" 2>/dev/null || true
  lsof -ti tcp:"$BENCH_PORT" 2>/dev/null | xargs kill -9 2>/dev/null || true
  sleep 0.3
  row "dart:io   HTTP  AOT  ${NCPU}-workers" "$DIO_HTTP_AOT_N" "$DIO_HTTP_JIT"

  # dart-zig JIT multi
  start "dart-zig HTTP JIT ${NCPU}w" \
    "$ZIG_JIT" --workers="$NCPU" "${SNAPS}/http_server.dill" "$BENCH_PORT"
  ZIG_HTTP_JIT_N=$(bench_http); stop
  row "dart-zig  HTTP  JIT  ${NCPU}-workers" "$ZIG_HTTP_JIT_N" "$DIO_HTTP_JIT"

  # dart-zig AOT multi
  start "dart-zig HTTP AOT ${NCPU}w" \
    "$ZIG_AOT" --workers="$NCPU" "${SNAPS}/http_server_aot.dylib" "$BENCH_PORT"
  ZIG_HTTP_AOT_N=$(bench_http); stop
  row "dart-zig  HTTP  AOT  ${NCPU}-workers" "$ZIG_HTTP_AOT_N" "$DIO_HTTP_JIT"
fi

# ════════════════════════════════════════════════════════════════════════════
#  HTTPS
# ════════════════════════════════════════════════════════════════════════════
if [[ "$SUITE" == "all" || "$SUITE" == "https" || "$SUITE" == "quick" ]]; then
hr; sec "HTTPS (TLS) — 1 worker"

  # dart:io JIT
  start "dart:io HTTPS JIT 1w" \
    "$DART_SYSTEM" /tmp/_bench_dart_io_https.dart "$BENCH_PORT" "$CERTS"
  DIO_HTTPS_JIT=$(bench_https); stop
  row "dart:io   HTTPS  JIT  1-worker" "$DIO_HTTPS_JIT"

  # dart:io AOT
  start "dart:io HTTPS AOT 1w" \
    "$DARTAOT" "${BIN}/dart_io_https_server.aot" "$BENCH_PORT" "$CERTS"
  DIO_HTTPS_AOT=$(bench_https); stop
  row "dart:io   HTTPS  AOT  1-worker" "$DIO_HTTPS_AOT" "$DIO_HTTPS_JIT"

  # dart-zig JIT 1w
  start "dart-zig HTTPS JIT 1w" \
    "$ZIG_JIT" --workers=1 "${SNAPS}/https_server.dill" "$BENCH_PORT"
  ZIG_HTTPS_JIT_1=$(bench_https); stop
  row "dart-zig  HTTPS  JIT  1-worker" "$ZIG_HTTPS_JIT_1" "$DIO_HTTPS_JIT"

  # dart-zig AOT 1w
  start "dart-zig HTTPS AOT 1w" \
    "$ZIG_AOT" --workers=1 "${SNAPS}/https_server_aot.dylib" "$BENCH_PORT"
  ZIG_HTTPS_AOT_1=$(bench_https); stop
  row "dart-zig  HTTPS  AOT  1-worker" "$ZIG_HTTPS_AOT_1" "$DIO_HTTPS_JIT"

hr; sec "HTTPS (TLS) — ${NCPU} workers (SO_REUSEPORT)"

  # dart:io AOT multi
  lsof -ti tcp:"$BENCH_PORT" 2>/dev/null | xargs kill -9 2>/dev/null || true; sleep 0.1
  SERVER_PID=()
  for _i in $(seq 1 "$NCPU"); do
    "$DARTAOT" "${BIN}/dart_io_https_server.aot" "$BENCH_PORT" "$CERTS" &>/dev/null &
    SERVER_PID+=("$!")
  done
  sleep 1
  DIO_HTTPS_AOT_N=$(bench_https)
  kill "${SERVER_PID[@]}" 2>/dev/null || true
  wait "${SERVER_PID[@]}" 2>/dev/null || true
  lsof -ti tcp:"$BENCH_PORT" 2>/dev/null | xargs kill -9 2>/dev/null || true
  sleep 0.3
  row "dart:io   HTTPS  AOT  ${NCPU}-workers" "$DIO_HTTPS_AOT_N" "$DIO_HTTPS_JIT"

  # dart-zig JIT multi
  start "dart-zig HTTPS JIT ${NCPU}w" \
    "$ZIG_JIT" --workers="$NCPU" "${SNAPS}/https_server.dill" "$BENCH_PORT"
  ZIG_HTTPS_JIT_N=$(bench_https); stop
  row "dart-zig  HTTPS  JIT  ${NCPU}-workers" "$ZIG_HTTPS_JIT_N" "$DIO_HTTPS_JIT"

  # dart-zig AOT multi
  start "dart-zig HTTPS AOT ${NCPU}w" \
    "$ZIG_AOT" --workers="$NCPU" "${SNAPS}/https_server_aot.dylib" "$BENCH_PORT"
  ZIG_HTTPS_AOT_N=$(bench_https); stop
  row "dart-zig  HTTPS  AOT  ${NCPU}-workers" "$ZIG_HTTPS_AOT_N" "$DIO_HTTPS_JIT"
fi

hr
echo ""
echo "  Multipliers vs dart:io JIT 1-worker baseline."
echo ""
