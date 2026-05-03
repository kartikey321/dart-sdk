#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
WORK_PARENT="$(cd -- "${REPO_ROOT}/.." && pwd)"
DEPOT_TOOLS_DIR="${DEPOT_TOOLS_DIR:-/tmp/depot_tools}"
LOCAL_BIN_DIR="${LOCAL_BIN_DIR:-${HOME}/.local/bin}"
LOCAL_OPT_DIR="${LOCAL_OPT_DIR:-${HOME}/.local/opt}"
JOBS="${JOBS:-$(nproc)}"
USE_DOCKER_IMAGE_BUILD="${USE_DOCKER_IMAGE_BUILD:-1}"
USE_SMOKE_TEST="${USE_SMOKE_TEST:-0}"
SMOKE_PORT="${SMOKE_PORT:-18080}"
RUNTIME_IMAGE_TAG="${RUNTIME_IMAGE_TAG:-dart-zig-runtime:local}"

log() {
  printf '\n[%s] %s\n' "$1" "$2"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

phase_checkout_bootstrap() {
  log phase "bootstrap SDK deps via depot_tools + gclient"
  need_cmd git
  need_cmd python3
  need_cmd curl

  if [[ ! -d "${DEPOT_TOOLS_DIR}" ]]; then
    git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "${DEPOT_TOOLS_DIR}"
  fi
  export PATH="${DEPOT_TOOLS_DIR}:$PATH"
  need_cmd gclient

  pushd "${WORK_PARENT}" >/dev/null
  ln -sfn "$(basename "${REPO_ROOT}")" sdk
  cat > .gclient <<'GCLIENTEOF'
solutions = [
  {
    "name": "sdk",
    "url": "https://dart.googlesource.com/sdk.git",
    "managed": False,
    "custom_deps": {},
  },
]
GCLIENTEOF
  gclient sync -j"${JOBS}" --no-history
  gclient runhooks
  popd >/dev/null
}

phase_install_zig() {
  log phase "ensure Zig 0.15.2 is available"
  if command -v zig >/dev/null 2>&1; then
    local ver
    ver="$(zig version || true)"
    if [[ "${ver}" == "0.15.2" ]]; then
      echo "using system zig ${ver}"
      return
    fi
  fi

  mkdir -p "${LOCAL_BIN_DIR}" "${LOCAL_OPT_DIR}"
  export PATH="${LOCAL_BIN_DIR}:$PATH"

  local zig_root="${LOCAL_OPT_DIR}/zig-x86_64-linux-0.15.2"
  if [[ ! -x "${zig_root}/zig" ]]; then
    curl -fL https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz -o /tmp/zig.tar.xz
    rm -rf "${zig_root}"
    tar -xf /tmp/zig.tar.xz -C "${LOCAL_OPT_DIR}"
  fi
  ln -sfn "${zig_root}/zig" "${LOCAL_BIN_DIR}/zig"
  zig version
}

phase_build_engine() {
  log phase "build Dart engine prerequisites"
  pushd "${REPO_ROOT}" >/dev/null
  python3 tools/build.py --mode=release --arch=x64 -j"${JOBS}" \
    dartvm dart_engine_jit_shared dart_engine_aot_shared dart gen_snapshot
  popd >/dev/null
}

phase_build_boringssl() {
  log phase "build BoringSSL static libraries"
  pushd "${REPO_ROOT}" >/dev/null
  chmod +x dart-zig/scripts/build_boringssl.sh
  dart-zig/scripts/build_boringssl.sh
  popd >/dev/null
}

phase_package_bundle() {
  log phase "package generic runtime bundle"
  pushd "${REPO_ROOT}" >/dev/null
  chmod +x dart-zig/scripts/package_runtime_bundle.sh
  dart-zig/scripts/package_runtime_bundle.sh
  popd >/dev/null
}

phase_build_runtime_image() {
  if [[ "${USE_DOCKER_IMAGE_BUILD}" != "1" ]]; then
    return
  fi
  log phase "build local runtime Docker image"
  docker build \
    -f "${REPO_ROOT}/dart-zig/docker/Dockerfile.runtime-base" \
    -t "${RUNTIME_IMAGE_TAG}" \
    "${REPO_ROOT}/dart-zig/dist"
}

phase_smoke_test() {
  if [[ "${USE_SMOKE_TEST}" != "1" ]]; then
    return
  fi
  log phase "smoke test runtime image"
  local cid
  cid="$(docker run -d --rm \
    --security-opt seccomp=unconfined \
    -p "${SMOKE_PORT}:8080" \
    "${RUNTIME_IMAGE_TAG}" \
    /opt/dart-zig/bin/dart-zig /opt/dart-zig/snapshots/benchmark_http_server.dill 8080)"
  trap 'docker rm -f "${cid}" >/dev/null 2>&1 || true' EXIT
  sleep 3
  curl -fsS "http://127.0.0.1:${SMOKE_PORT}/pipeline"
  curl -fsS "http://127.0.0.1:${SMOKE_PORT}/baseline11?a=1&b=2"
  docker rm -f "${cid}" >/dev/null 2>&1 || true
  trap - EXIT
}

main() {
  phase_checkout_bootstrap
  phase_install_zig
  phase_build_engine
  phase_build_boringssl
  phase_package_bundle
  phase_build_runtime_image
  phase_smoke_test
  log done "workflow phases completed"
}

main "$@"
