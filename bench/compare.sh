#!/bin/sh
# Same-host A/B — the authoritative regression check.
#
#   bench/compare.sh GIT-REF
#
# Absolute benchmark numbers cannot be compared across machines (or
# across days on shared containers: hosts change under the session,
# and even the C column moves).  This script removes the machine from
# the question: it builds GIT-REF in a scratch worktree, builds the
# working tree, and times both ON THIS HOST, interleaved round-robin
# so slow drift lands on both sides equally.  Each side compiles the
# bench programs with its own luce and runs them with its own loom,
# so artifact format changes between refs don't matter.
#
# **Outputs are compared before anything is timed**, exactly as
# bench/run.sh compares each Luce program against its C twin.  Two
# sides that print different things are not two speeds of the same
# work, and a change that made a program wrong and fast would
# otherwise show up here as a win.
#
# Two columns per side, and the difference between them is process
# startup.  The raw time is the whole wall clock, which is what a
# person waits for; `compute` takes the do-nothing floor off first,
# which is what a change to code generation actually moves.  The
# deltas are computed on both, and a row where they disagree is a row
# short enough that startup is a real fraction of it.
#
# Expect the first run to spend a minute or two building the base
# worktree (its own zig cache).

set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

ref="${1:?usage: bench/compare.sh GIT-REF}"
base="$root/.bench-base"

if [ -e "$base" ]; then
    git worktree remove --force "$base" 2>/dev/null || rm -rf "$base"
fi
git worktree add --detach "$base" "$ref" >/dev/null
trap 'git worktree remove --force "$base" >/dev/null 2>&1 || true' EXIT

# A build that fails is the most likely thing to go wrong here, and it
# used to fail silently: `set -e` killed the script with both channels
# discarded.  Keep the chatter out of the table but print the whole
# log when a build stops.
build_quietly() {
    where="$1"
    what="$2"
    log="$(mktemp)"
    if ! (cd "$where" && zig build --prefix build -Doptimize=ReleaseSafe) >"$log" 2>&1; then
        echo "bench: building $what failed:" >&2
        cat "$log" >&2
        rm -f "$log"
        exit 1
    fi
    rm -f "$log"
}

echo "building base ($ref)..."
build_quietly "$base" "the base ($ref)"
echo "building working tree..."
build_quietly "$root" "the working tree"

# The same list run.sh times.  A row the base does not have is
# skipped rather than failed — every loop below guards on the base's
# artifact existing — so comparing against a commit from before the
# 32-bit rows landed still works and simply reports fewer rows.
names="loops math strings arrays arrays32 matmul matmul32 stats lists"
mkdir -p build/bench "$base/build/bench"
# Each side writes its own `.lc` and each side's tag names its own code
# generator, so neither can run the other's artifact — or one its own
# earlier build left — which is exactly the difference being measured.
for name in $names; do
    build/luce build "bench/$name.luc" -o "build/bench/$name.lc" --release >/dev/null
    if [ -f "$base/bench/$name.luc" ]; then
        "$base/build/luce" build "$base/bench/$name.luc" \
            -o "$base/build/bench/$name.lc" --release >/dev/null
    fi
done

# Linux names the CPU in /proc/cpuinfo, macOS in a sysctl.  The A/B is
# same-host by construction, but the stamp keeps a pasted table honest.
host_stamp() {
    if [ -r /proc/cpuinfo ]; then
        awk -F: '/model name/{gsub(/^ +/, "", $2); print $2; exit}' /proc/cpuinfo
    else
        stamp=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)
        if [ -z "$stamp" ]; then
            stamp=$(system_profiler SPHardwareDataType 2>/dev/null |
                awk -F: '/Chip:|Processor Name:/{gsub(/^ +/, "", $2); print $2; exit}' || true)
        fi
        if [ -z "$stamp" ]; then
            stamp=$(sysctl -n hw.model 2>/dev/null || true)
        fi
        if [ -z "$stamp" ]; then
            stamp="unknown $(uname -m) CPU"
        fi
        printf '%s\n' "$stamp"
    fi
}
echo "host: $(host_stamp) ($(uname -sm))"

tmp="$(mktemp -d)"
old_trap='git worktree remove --force "$base" >/dev/null 2>&1 || true'
trap 'rm -rf "$tmp"; '"$old_trap" EXIT

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

# The floor: what a do-nothing program costs on each side — loom's
# startup plus opening a program's artifact.  Each side builds and
# runs its own, because that cost is one of the things a change to the
# toolchain moves.
printf 'func main():\n    print("")\n' > "$tmp/floor.luc"
build/luce build "$tmp/floor.luc" -o "$tmp/floor.head.lc" --release >/dev/null
"$base/build/luce" build "$tmp/floor.luc" -o "$tmp/floor.base.lc" --release >/dev/null

# Nothing is timed until both sides agree about what they printed.  A
# side that produced different bytes is not a second measurement of
# the same work.
for name in $names; do
    [ -f "$base/build/bench/$name.lc" ] || continue
    head_out=$(build/loom run "build/bench/$name.lc")
    base_out=$("$base/build/loom" run "$base/build/bench/$name.lc")
    if [ "$head_out" != "$base_out" ]; then
        echo "bench: $name output changed — base:'$base_out' head:'$head_out'" >&2
        echo "bench: refusing to time two programs that do different work" >&2
        exit 1
    fi
done

for round in 1 2 3 4 5; do
    for name in $names; do
        if [ -f "$base/build/bench/$name.lc" ]; then
            elapsed=$(time_once "$base/build/loom" run "$base/build/bench/$name.lc")
            keep_min "$tmp/$name.base" "$elapsed"
        fi
        elapsed=$(time_once build/loom run "build/bench/$name.lc")
        keep_min "$tmp/$name.head" "$elapsed"
    done
    elapsed=$(time_once "$base/build/loom" run "$tmp/floor.base.lc")
    keep_min "$tmp/floor.base" "$elapsed"
    elapsed=$(time_once build/loom run "$tmp/floor.head.lc")
    keep_min "$tmp/floor.head" "$elapsed"
done

floor_base=$(cat "$tmp/floor.base")
floor_head=$(cat "$tmp/floor.head")

printf '%-10s %10s %10s %8s %10s %10s %8s\n' \
    "benchmark" "base" "head" "delta" "base-cmp" "head-cmp" "delta"
for name in $names; do
    if [ ! -f "$tmp/$name.base" ]; then
        printf '%-10s %10s\n' "$name" "(absent at $ref)"
        continue
    fi
    awk -v name="$name" -v b="$(cat "$tmp/$name.base")" -v h="$(cat "$tmp/$name.head")" \
        -v fb="$floor_base" -v fh="$floor_head" 'BEGIN {
        # A benchmark not clear of the floor cannot report a compute
        # delta honestly, so it reports none.
        net_b = b - fb
        net_h = h - fh
        if (net_b > 0 && net_h > 0) {
            base_compute = sprintf("%.1fms", net_b / 1e6)
            head_compute = sprintf("%.1fms", net_h / 1e6)
            compute_delta = sprintf("%+.1f%%", (net_h - net_b) * 100.0 / net_b)
        } else {
            base_compute = "-"; head_compute = "-"; compute_delta = "-"
        }
        printf "%-10s %8.1fms %8.1fms %+7.1f%% %10s %10s %8s\n",
            name, b / 1e6, h / 1e6, (h - b) * 100.0 / b,
            base_compute, head_compute, compute_delta
    }'
done
awk -v b="$floor_base" -v h="$floor_head" 'BEGIN {
    printf "%-10s %8.1fms %8.1fms %+7.1f%% %10s %10s %8s   (do-nothing program)\n",
        "floor", b / 1e6, h / 1e6, (h - b) * 100.0 / b, "-", "-", "-"
}'
