#!/bin/sh
# Parallel mutation sweep: one throwaway worktree per mutation, run
# concurrently.  Each mutation must be tested alone — separate trees
# make that true by construction, which is what lets them run at the
# same time.
#
#   tools/sweep.sh MUTATIONS.tsv
#
# MUTATIONS.tsv: one mutation per line, three tab-separated fields:
#   name <TAB> file <TAB> perl -0pi expression applying the mutation
#
# For each line: a detached worktree at HEAD, the expression applied,
# **verified to have changed the file** (an unapplied mutation reports
# NOT-APPLIED, never SURVIVED — the lesson of two earlier harness
# bugs), then `zig build test`.  A failing suite is a KILL and the
# first failing test is named; a green suite is a SURVIVOR.  Worktrees
# are removed afterwards, pass or fail.
#
# Never run timing benchmarks while a sweep is out — it owns the CPU.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
plan="$1"
sweep="$root/.sweep"
rm -rf "$sweep" && mkdir -p "$sweep"

n=0
while IFS="$(printf '\t')" read -r name file expr; do
    [ -z "$name" ] && continue
    n=$((n + 1))
    (
        tree="$sweep/$n"
        git -C "$root" worktree add --detach --quiet "$tree" HEAD || {
            echo "$name: WORKTREE-FAILED"; exit 0; }
        # The vendored LLVM lives outside the tree; give the worktree
        # the same symlink main has, falling back to system LLVM if
        # absent (build.zig handles both).
        [ -e "$root/.llvm" ] && ln -s "$(readlink "$root/.llvm" || echo "$root/.llvm")" "$tree/.llvm" 2>/dev/null
        perl -0pi -e "$expr" "$tree/$file"
        if git -C "$tree" diff --quiet -- "$file"; then
            echo "$name: NOT-APPLIED"
        elif out=$(cd "$tree" && zig build test 2>&1); then
            echo "$name: SURVIVED"
        else
            killer=$(printf '%s\n' "$out" | grep -m1 -oE "error: '[^']+'" | head -1)
            echo "$name: KILLED by ${killer:-a failing step}"
        fi
        git -C "$root" worktree remove --force "$tree" >/dev/null 2>&1
    ) &
done < "$plan"
wait
git -C "$root" worktree prune >/dev/null 2>&1
rm -rf "$sweep"
