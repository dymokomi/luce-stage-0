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

echo "building base ($ref)..."
(cd "$base" && zig build --prefix build -Doptimize=ReleaseSafe) >/dev/null 2>&1
echo "building working tree..."
zig build --prefix build -Doptimize=ReleaseSafe >/dev/null 2>&1

names="loops math strings arrays matmul stats"
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
        sysctl -n machdep.cpu.brand_string 2>/dev/null
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

for round in 1 2 3 4 5; do
    for name in $names; do
        if [ -f "$base/build/bench/$name.lc" ]; then
            elapsed=$(time_once "$base/build/loom" run "$base/build/bench/$name.lc")
            keep_min "$tmp/$name.base" "$elapsed"
        fi
        elapsed=$(time_once build/loom run "build/bench/$name.lc")
        keep_min "$tmp/$name.head" "$elapsed"
    done
done

printf '%-10s %12s %12s %10s\n' "benchmark" "base" "head" "delta"
for name in $names; do
    if [ ! -f "$tmp/$name.base" ]; then
        printf '%-10s %12s\n' "$name" "(absent at $ref)"
        continue
    fi
    awk -v name="$name" -v b="$(cat "$tmp/$name.base")" -v h="$(cat "$tmp/$name.head")" 'BEGIN {
        printf "%-10s %10.1fms %10.1fms %+9.1f%%\n", name, b / 1e6, h / 1e6, (h - b) * 100.0 / b
    }'
done
