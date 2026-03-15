FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

RUN apt-get update && apt-get install -y \
    git curl python3 python3-pip \
    pkg-config libssl-dev \
    liburing-dev \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# depot_tools
RUN git clone --depth=1 \
    https://chromium.googlesource.com/chromium/tools/depot_tools.git \
    /depot_tools
ENV PATH="/depot_tools:${PATH}"
ENV DEPOT_TOOLS_UPDATE=0

RUN git config --global user.email "builder@dart-zig" && \
    git config --global user.name "Dart-Zig Builder"

# Zig 0.15.2
RUN curl -L https://ziglang.org/builds/zig-linux-aarch64-0.15.0-dev.tar.xz \
    -o /tmp/zig.tar.xz 2>/dev/null || true
# Zig is installed separately via build-engine.sh

WORKDIR /workspace
