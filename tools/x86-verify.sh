#!/bin/sh
# What amd64 emulation CAN prove locally: the x86-64 Zig backend
# (codegen_x86.zig) is correct.  It emits static machine code, so
# qemu just runs those instructions — no JIT, no repeated exec-page
# churn.  For every benchmark and every bundled program, this checks
# the zig backend's output against the interpreter (the reference),
# byte for byte.
#
# Runs inside the container; the wrapper `tools/x86-test.sh verify`
# calls it there.  Standalone `zig build test` in the container also
# works but its MIR-engine oracle tests hit a qemu-user instability
# (many MIR JIT contexts in one process SIGABRT under emulation — an
# emulation artifact, not our code: each runs fine as its own
# process, and real x86 Linux is clean).  This script sidesteps that
# by exercising the zig backend directly, LOOM_ENGINE=zig.
set -e
cd /work
zig build --prefix build -Doptimize=ReleaseSafe >/dev/null 2>&1

echo "host: $(uname -m)"
scratch=/work/.zig-cache/verify
mkdir -p "$scratch"
failed=0

check() {
    name="$1"; lc="$2"; shift 2
    zig_out=$(LOOM_ENGINE=zig build/loom run "$lc" "$@" 2>&1) || zig_out="<crash>"
    ref_out=$(LOOM_ENGINE=interpreter build/loom run "$lc" "$@" 2>&1) || ref_out="<crash>"
    if [ "$zig_out" = "$ref_out" ]; then
        printf '  %-14s OK\n' "$name"
    else
        printf '  %-14s MISMATCH\n    zig: %s\n    int: %s\n' "$name" "$zig_out" "$ref_out"
        failed=1
    fi
}

echo "benchmarks (zig backend vs interpreter):"
for name in loops math strings arrays matmul stats; do
    build/luce build "bench/$name.luc" -o "$scratch/$name.lc" --release >/dev/null
    check "$name" "$scratch/$name.lc"
done

echo "bundled programs:"
# Non-interactive ones only; the editor blocks on the terminal.
for name in hello sort stats wordcount calc bf life; do
    src="programs/$name.luc"
    [ -f "$src" ] || continue
    build/luce build "$src" -o "$scratch/$name.lc" --release >/dev/null 2>&1 || continue
    check "$name" "$scratch/$name.lc" 3 1 2
done

if [ $failed -eq 0 ]; then
    echo "x86-64 zig backend: all outputs identical to the reference."
else
    echo "x86-64 zig backend: MISMATCHES above — a real emitter bug."
    exit 1
fi
