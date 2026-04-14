FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

RUN apt-get update && apt-get install -y \
    git curl python3 python3-pip \
    xz-utils \
    pkg-config libssl-dev \
    liburing-dev \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Zig 0.15.2 — pre-baked into the image so runtime scripts (rebuild_linux.sh,
# run_bench.sh) skip the download step.  URL and naming convention matches the
# scripts so the `if [ ! -f /usr/local/bin/zig ]` guard is always satisfied.
RUN curl -fL "https://ziglang.org/download/0.15.2/zig-aarch64-linux-0.15.2.tar.xz" \
        -o /tmp/zig.tar.xz \
    && tar -xf /tmp/zig.tar.xz -C /opt/ \
    && ln -sf /opt/zig-aarch64-linux-0.15.2/zig /usr/local/bin/zig \
    && rm /tmp/zig.tar.xz \
    && zig version

# depot_tools — only needed for gclient sync / building the Dart engine from
# source (build-engine.sh).  Not required for dart-zig builds or benchmarks.
RUN git clone --depth=1 \
    https://chromium.googlesource.com/chromium/tools/depot_tools.git \
    /depot_tools
ENV PATH="/depot_tools:${PATH}"
ENV DEPOT_TOOLS_UPDATE=0

RUN git config --global user.email "builder@dart-zig" && \
    git config --global user.name "Dart-Zig Builder"

WORKDIR /workspace
