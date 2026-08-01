#!/bin/sh
# Verify the x86-64 Zig backend on an aarch64 host, via Docker's
# amd64 emulation.  The x86 emitter (codegen_x86.zig) produces real
# x86-64 machine code; qemu runs it; the two-/three-engine oracle
# holds it to the interpreter.  So `codegen_x86` is testable on a Mac
# with no x86 hardware — the point the session missed the first time
# around.
#
#   tools/x86-test.sh verify       # x86 zig backend vs interpreter, every
#                                  #   bench + bundled program
#   tools/x86-test.sh bench        # output cross-check (not timed)
#   tools/x86-test.sh build        # (re)build the image only
#   tools/x86-test.sh sh           # a shell in the container, repo mounted
#
# What this validates is the *self-written x86 backend* (codegen_x86):
# static machine code the emulator runs faithfully.  It does NOT run
# the full `zig build test`, because that exercises MIR's JIT —
# generating and running code at run time — which an emulator cannot
# host (Rosetta mistranslates it; every program runs correctly on real
# x86).  MIR on x86 is tested on real hardware: tools/aws-test.sh.
#
# The image caches Zig; the first run downloads it.  The repo is
# mounted read-write, but zig's cache lands in a named volume so the
# host .zig-cache (aarch64 objects) is never mixed with amd64 ones.
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

image=luce-x86-test
platform=linux/amd64

ensure_image() {
    docker image inspect "$image" >/dev/null 2>&1 || \
        docker build --platform "$platform" -t "$image" -f tools/x86.Dockerfile tools
}

run() {
    docker run --rm --platform "$platform" \
        -v "$root:/work" -v luce-x86-zig-cache:/work/.zig-cache \
        "$image" "$@"
}

case "${1:-verify}" in
    build)
        docker build --platform "$platform" -t "$image" -f tools/x86.Dockerfile tools
        ;;
    sh)
        ensure_image
        docker run --rm -it --platform "$platform" \
            -v "$root:/work" -v luce-x86-zig-cache:/work/.zig-cache \
            "$image" /bin/sh
        ;;
    verify)
        ensure_image
        run sh tools/x86-verify.sh
        ;;
    bench)
        # Timings under emulation are meaningless; this only
        # cross-checks outputs across engines, like run.sh's equality
        # gate.  Real-x86 timing stays a job for actual hardware.
        ensure_image
        run sh -c 'cd /work && ./build.sh >/dev/null 2>&1 && bench/run.sh'
        ;;
    *)
        echo "usage: tools/x86-test.sh [verify|bench|build|sh]" >&2
        exit 1
        ;;
esac
