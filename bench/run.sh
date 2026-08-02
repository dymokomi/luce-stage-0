#!/bin/sh
# Paired C / Luce benchmarks — the speed regression guard.
#
# Each bench/NAME.luc has a bench/NAME.c twin running the same
# algorithm and printing the same output; the harness refuses to time
# anything whose outputs disagree, so this doubles as a correctness
# check.  C compiles with `zig cc -O3 -march=native` (auto-vectorized,
# full speed); Luce compiles --release and runs under loom.  Both
# timings include process startup.  Best of five runs.
#
#   ./build.sh && bench/run.sh
#
# Ratios are the number to watch across interpreter changes; absolute
# times move with the machine.  The current snapshot lives in
# docs/CODEGEN.md.

set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if [ ! -x build/luce ] || [ ! -x build/loom ]; then
    echo "bench: run ./build.sh first" >&2
    exit 1
fi
mkdir -p build/bench

names="loops math strings arrays matmul stats"

# -ffp-contract=off: Luce's determinism guarantee is strict IEEE
# (no fused multiply-add), so C plays by the same float rules —
# otherwise the mandelbrot checksums genuinely differ.  Everything
# else (-O3, vectorization) stays on.
for name in $names; do
    build/luce build "bench/$name.luc" -o "build/bench/$name.lc" --release >/dev/null
    zig cc -O3 -march=native -ffp-contract=off -o "build/bench/$name" "bench/$name.c"
done

time_once() {
    start=$(date +%s%N)
    if ! "$@" >/dev/null; then
        echo "bench: timed command failed: $*" >&2
        return 1
    fi
    end=$(date +%s%N)
    echo $((end - start))
}

keep_min() {
    file="$1"
    value="$2"
    if [ ! -f "$file" ] || [ "$value" -lt "$(cat "$file")" ]; then
        echo "$value" > "$file"
    fi
}

# Two implementations of every benchmark: C at full optimization and
# Luce under loom.  Both outputs must agree before anything is timed.
for name in $names; do
    c_out=$(build/bench/"$name")
    luce_out=$(build/loom run build/bench/"$name".lc)
    if [ "$c_out" != "$luce_out" ]; then
        echo "bench: $name output mismatch — C:'$c_out' luce:'$luce_out'" >&2
        exit 1
    fi
done

# The machine stamps every table: absolute numbers mean nothing off
# this host — compare against another commit with bench/compare.sh,
# never against a table from a different machine or day.  Linux names
# the CPU in /proc/cpuinfo, macOS in a sysctl; an unknown host still
# gets stamped, so a table is never silently machine-less.
host_stamp() {
    if [ -r /proc/cpuinfo ]; then
        awk -F: '/model name/{gsub(/^ +/, "", $2); print $2; exit}' /proc/cpuinfo
    else
        sysctl -n machdep.cpu.brand_string 2>/dev/null
    fi
}
echo "host: $(host_stamp) ($(uname -sm))"

# Interleaved rounds, best of five: slow host drift lands on every
# column equally instead of biasing whichever ran last.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
for round in 1 2 3 4 5; do
    for name in $names; do
        elapsed=$(time_once build/bench/"$name")
        keep_min "$tmp/$name.c" "$elapsed"
        elapsed=$(time_once build/loom run build/bench/"$name".lc)
        keep_min "$tmp/$name.luce" "$elapsed"
    done
done
# The floor: what a do-nothing program costs on each side — process
# startup for C, and for loom startup plus decoding the program and
# every std function it imports.  Printed rather than
# subtracted, so the reader can see how much of a row is not
# computation.  Keep the benchmarks large enough that this stays
# small; see docs/CODEGEN.md.
printf 'func main():\n    print("")\n' > "$tmp/floor.luc"
printf 'int main(void){return 0;}\n' > "$tmp/floor.c"
build/luce build "$tmp/floor.luc" -o "$tmp/floor.lc" --release >/dev/null
zig cc -O3 -o "$tmp/floor" "$tmp/floor.c"
for round in 1 2 3; do
    elapsed=$(time_once "$tmp/floor")
    keep_min "$tmp/floor.c.ns" "$elapsed"
    elapsed=$(time_once build/loom run "$tmp/floor.lc")
    keep_min "$tmp/floor.luce.ns" "$elapsed"
done

printf '%-10s %12s %12s %10s\n' "benchmark" "C" "luce" "luce/C"
for name in $names; do
    awk -v name="$name" -v c="$(cat "$tmp/$name.c")" -v luce="$(cat "$tmp/$name.luce")" 'BEGIN {
        printf "%-10s %10.1fms %10.1fms %9.1fx\n", name, c / 1e6, luce / 1e6, luce / c
    }'
done
awk -v c="$(cat "$tmp/floor.c.ns")" -v luce="$(cat "$tmp/floor.luce.ns")" 'BEGIN {
    printf "%-10s %10.1fms %10.1fms %10s   (do-nothing program)\n",
        "floor", c / 1e6, luce / 1e6, "-"
}'
