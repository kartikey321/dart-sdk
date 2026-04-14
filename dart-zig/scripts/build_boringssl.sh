#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DART_ZIG_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
BORINGSSL_SRC_DIR="${DART_ZIG_DIR}/../third_party/boringssl/src"
BUILD_DIR="${DART_ZIG_DIR}/boringssl-build"

cmake \
  -S "${BORINGSSL_SRC_DIR}" \
  -B "${BUILD_DIR}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF

cmake \
  --build "${BUILD_DIR}" \
  --config Release \
  --target ssl crypto \
  --parallel
