#!/bin/sh
# Paired C / Luce benchmarks — the speed regression guard.
#
# Each bench/NAME.luc has a bench/NAME.c twin running the same
# algorithm and printing the same output; the harness refuses to time
# anything whose outputs disagree, so this doubles as a correctness
# check.  C compiles with `zig cc -O3 -march=native` (auto-vectorized,
# full speed); Luce compiles --release into a `.lc`, which is machine
# code, and loom opens and calls it.  Both timings include process
# startup.  Best of five runs.
#
#   ./build.sh && bench/run.sh
#
# Two ratios per row, and the difference between them is process
# startup.  `luce/C` is the whole wall clock, which is what a person
# actually waits for.  `compute` takes the do-nothing floor off both
# sides first, which is what a change to code generation moves.  A row
# where the two disagree is a row whose benchmark is short enough that
# startup is a real fraction of it — read both, never one.
#
# Absolute times move with the machine; the current snapshot lives in
# docs/CODEGEN.md, and bench/compare.sh is the same-host A/B.

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
#
# Nothing sweeps the artifacts a previous run left, and nothing needs
# to: each is overwritten by the `luce build` below, and if one were
# not, its tag names the code generator that wrote it and loom would
# refuse it by name rather than time the wrong instructions.
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
# startup for C, and for loom startup plus opening the program's
# artifact.  It is both printed *and* subtracted, in two columns, so
# neither half can mislead: the raw ratio is the wait, the floor-free
# one is the computation.
printf 'func main():\n    print("")\n' > "$tmp/floor.luc"
printf 'int main(void){return 0;}\n' > "$tmp/floor.c"
build/luce build "$tmp/floor.luc" -o "$tmp/floor.lc" --release >/dev/null
zig cc -O3 -o "$tmp/floor" "$tmp/floor.c"
build/loom run "$tmp/floor.lc" >/dev/null
for round in 1 2 3 4 5; do
    elapsed=$(time_once "$tmp/floor")
    keep_min "$tmp/floor.c.ns" "$elapsed"
    elapsed=$(time_once build/loom run "$tmp/floor.lc")
    keep_min "$tmp/floor.luce.ns" "$elapsed"
done

floor_c=$(cat "$tmp/floor.c.ns")
floor_luce=$(cat "$tmp/floor.luce.ns")

printf '%-10s %12s %12s %10s %10s\n' "benchmark" "C" "luce" "luce/C" "compute"
for name in $names; do
    awk -v name="$name" \
        -v c="$(cat "$tmp/$name.c")" -v luce="$(cat "$tmp/$name.luce")" \
        -v floor_c="$floor_c" -v floor_luce="$floor_luce" 'BEGIN {
        # A benchmark that is not clear of the floor cannot report a
        # compute ratio honestly, so it reports none.
        net_c = c - floor_c
        net_luce = luce - floor_luce
        if (net_c > 0 && net_luce > 0)
            compute = sprintf("%.2fx", net_luce / net_c)
        else
            compute = "-"
        printf "%-10s %10.1fms %10.1fms %9.2fx %10s\n", name, c / 1e6, luce / 1e6, luce / c, compute
    }'
done
awk -v c="$floor_c" -v luce="$floor_luce" 'BEGIN {
    printf "%-10s %10.1fms %10.1fms %10s %10s   (do-nothing program)\n",
        "floor", c / 1e6, luce / 1e6, "-", "-"
}'
