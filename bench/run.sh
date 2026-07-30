#!/bin/sh
# Paired C / Luce benchmarks — the speed regression guard.
#
# Each bench/NAME.luc has a bench/NAME.c twin running the same
# algorithm and printing the same output; the harness refuses to time
# anything whose outputs disagree, so this doubles as a correctness
# check.  C compiles with `zig cc -O3 -march=native` (auto-vectorized,
# full speed); Luce compiles --release and runs under loom.  Both
# timings include process startup.  Best of three runs.
#
#   ./build.sh && bench/run.sh
#
# Ratios are the number to watch across interpreter changes; absolute
# times move with the machine.  The current snapshot lives in
# docs/BENCHMARKS.md.

set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if [ ! -x build/luce ] || [ ! -x build/loom ]; then
    echo "bench: run ./build.sh first" >&2
    exit 1
fi
mkdir -p build/bench

names="loops math strings arrays"

# -ffp-contract=off: Luce's determinism guarantee is strict IEEE
# (no fused multiply-add), so C plays by the same float rules —
# otherwise the mandelbrot checksums genuinely differ.  Everything
# else (-O3, vectorization) stays on.
for name in $names; do
    build/luce build "bench/$name.luc" -o "build/bench/$name.lc" --release >/dev/null
    zig cc -O3 -march=native -ffp-contract=off -o "build/bench/$name" "bench/$name.c"
done

# Best-of-three wall time in nanoseconds.
best_ns() {
    best=""
    for _ in 1 2 3; do
        start=$(date +%s%N)
        "$@" >/dev/null
        end=$(date +%s%N)
        took=$((end - start))
        if [ -z "$best" ] || [ "$took" -lt "$best" ]; then best=$took; fi
    done
    echo "$best"
}

printf '%-10s %12s %12s %10s\n' "benchmark" "C" "Luce" "Luce/C"
for name in $names; do
    c_out=$(build/bench/"$name")
    luce_out=$(build/loom run build/bench/"$name".lc)
    if [ "$c_out" != "$luce_out" ]; then
        echo "bench: $name output mismatch — C: '$c_out'  Luce: '$luce_out'" >&2
        exit 1
    fi
    c_ns=$(best_ns build/bench/"$name")
    luce_ns=$(best_ns build/loom run build/bench/"$name".lc)
    awk -v name="$name" -v c="$c_ns" -v luce="$luce_ns" 'BEGIN {
        printf "%-10s %10.1fms %10.1fms %9.0fx\n", name, c / 1e6, luce / 1e6, luce / c
    }'
done
