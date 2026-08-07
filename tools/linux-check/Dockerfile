# Linux verification image for the Luce toolchain (linux/arm64).
#
#   docker build --platform linux/arm64 -t luce-linux /tmp/luciaos-linux-check
#   docker run --rm -v /path/to/luciaos:/src:ro luce-linux /work/verify.sh
#
# Contents: Zig pinned to the version build.zig.zon requires, LLVM 22
# (the major vendor-llvm.sh pins) from apt.llvm.org, a C toolchain for
# `cc`, Info-ZIP's zip/unzip so the zipper agreement test actually runs
# rather than skipping, and python3.
FROM debian:trixie-slim

ARG ZIG_VERSION=0.16.0
ARG LLVM_MAJOR=22

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg xz-utils \
        build-essential git zip unzip python3 file less procps \
    && rm -rf /var/lib/apt/lists/*

# LLVM 22 from apt.llvm.org (Debian trixie ships 19, which predates the
# bitcode Zig 0.16's std.zig.llvm.Builder writes).
RUN curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/llvm.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/llvm.gpg] https://apt.llvm.org/trixie/ llvm-toolchain-trixie-${LLVM_MAJOR} main" \
        > /etc/apt/sources.list.d/llvm.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends llvm-${LLVM_MAJOR}-dev libpolly-${LLVM_MAJOR}-dev \
    && rm -rf /var/lib/apt/lists/*
ENV PATH=/usr/lib/llvm-22/bin:$PATH

# Zig, pinned to build.zig.zon's minimum_zig_version.
RUN arch=$(uname -m) \
    && curl -fL "https://ziglang.org/download/${ZIG_VERSION}/zig-${arch}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz \
    && mkdir -p /opt/zig \
    && tar xf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && rm /tmp/zig.tar.xz \
    && ln -s /opt/zig/zig /usr/local/bin/zig

WORKDIR /work
