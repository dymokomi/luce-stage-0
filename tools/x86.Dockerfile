# x86-64 Linux verification image for the Zig backend (codegen_x86.zig).
#
# On an Apple-silicon Mac this runs under Docker's qemu emulation:
# `zig build test` cross-checks the x86-64 emitter's machine code
# against the interpreter, so the second backend's correctness is
# provable locally with no x86 hardware.  Timing under emulation is
# meaningless — real-x86 benchmarks stay a separate job — but every
# oracle and unit test is a true test of the emitted instructions.
#
# glibc base to match a typical Linux cloud host; MIR builds with the
# container's zig cc, the image mapper uses ordinary anonymous mmap.
FROM --platform=linux/amd64 debian:bookworm-slim

ARG ZIG_VERSION=0.16.0
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
        | tar -xJ -C /opt \
    && ln -s "/opt/zig-x86_64-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig \
    && zig version

WORKDIR /work
