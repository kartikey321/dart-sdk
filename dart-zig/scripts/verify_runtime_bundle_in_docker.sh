#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SDK_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
IMAGE="${DART_ZIG_VERIFY_IMAGE:-ubuntu:24.04}"
JOBS="${JOBS:-$(nproc)}"
CONTAINER_REPO="/work/dart-sdk"
CONTAINER_PARENT="/work"

cat <<MSG
[verify] runtime bundle build in Docker
  image: ${IMAGE}
  repo:  ${SDK_ROOT}
  jobs:  ${JOBS}
MSG

docker run --rm \
  -v "${SDK_ROOT}:${CONTAINER_REPO}" \
  -w "${CONTAINER_REPO}" \
  "${IMAGE}" \
  bash -lc "set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  build-essential curl git python3 pkg-config cmake ninja-build \
  liburing-dev ca-certificates xz-utils file

rm -rf /tmp/depot_tools
git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git /tmp/depot_tools
export PATH=/tmp/depot_tools:\$PATH

cd ${CONTAINER_PARENT}
ln -sfn dart-sdk sdk
cat > .gclient <<'GCLIENTEOF'
solutions = [
  {
    \"name\": \"sdk\",
    \"url\": \"https://dart.googlesource.com/sdk.git\",
    \"managed\": False,
    \"custom_deps\": {},
  },
]
GCLIENTEOF

gclient sync -j${JOBS} --no-history
gclient runhooks

curl -fL https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz -o /tmp/zig.tar.xz
rm -rf /opt/zig-x86_64-linux-0.15.2
mkdir -p /opt

tar -xf /tmp/zig.tar.xz -C /opt/
ln -sf /opt/zig-x86_64-linux-0.15.2/zig /usr/local/bin/zig
zig version

cd ${CONTAINER_REPO}
python3 tools/build.py --mode=release --arch=x64 -j${JOBS} \
  dart_engine_jit_shared dart_engine_aot_shared dart gen_snapshot

chmod +x dart-zig/scripts/build_boringssl.sh
chmod +x dart-zig/scripts/package_runtime_bundle.sh

dart-zig/scripts/build_boringssl.sh
dart-zig/scripts/package_runtime_bundle.sh

ls -lh dart-zig/dist/dart-zig-linux-x64.tar.gz
find dart-zig/dist/dart-zig-linux-x64 -maxdepth 2 -type f | sort
"

cat <<MSG
[verify] bundle built in container.
[verify] final host image build:
  docker build \\
    -f dart-zig/docker/Dockerfile.runtime-base \\
    -t dart-zig-runtime:local \\
    dart-zig/dist
MSG
