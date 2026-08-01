#!/bin/sh
# Verify the x86-64 Zig backend on an aarch64 host, via Docker's
# amd64 emulation.  The x86 emitter (codegen_x86.zig) produces real
# x86-64 machine code; qemu runs it; the two-/three-engine oracle
# holds it to the interpreter.  So `codegen_x86` is testable on a Mac
# with no x86 hardware — the point the session missed the first time
# around.
#
#   tools/x86-test.sh verify       # x86 zig backend vs interpreter (reliable)
#   tools/x86-test.sh test         # full `zig build test` (MIR oracle tests
#                                  #   SIGABRT under qemu — see x86-verify.sh)
#   tools/x86-test.sh build        # (re)build the image only
#   tools/x86-test.sh sh           # a shell in the container, repo mounted
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
    # LOOM_TEST_NO_MIR: the emulator can't host MIR's JIT under the
    # test binary's many-context churn (native_spec.zig) — every
    # program runs fine standalone, so this validates the interpreter
    # against the self-written x86 backend and leaves the vendored JIT
    # to real hardware / CI.  Off in production.
    docker run --rm --platform "$platform" \
        -e LOOM_TEST_NO_MIR=1 \
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
    test)
        ensure_image
        run zig build test
        ;;
    bench)
        # Timings under emulation are meaningless; this only
        # cross-checks outputs across engines, like run.sh's equality
        # gate.  Real-x86 timing stays a job for actual hardware.
        ensure_image
        run sh -c 'cd /work && ./build.sh >/dev/null 2>&1 && bench/run.sh'
        ;;
    *)
        echo "usage: tools/x86-test.sh [verify|test|build|sh]" >&2
        exit 1
        ;;
esac
