#!/bin/sh
# Build LuciaOS v2: installs the luce compiler and the loom terminal at
# build/, plus the compiled bundled programs at build/programs/.
#
# Installed binaries default to ReleaseSafe — the interpreter is a
# trust boundary (.lc files run like executables), so Zig's own safety
# checks stay on at ~15% cost over ReleaseFast (docs/BENCHMARKS.md
# has both measured).  A Debug interpreter is ~4-5x slower: never
# benchmark one.  Override with e.g. ./build.sh -Doptimize=ReleaseFast.
set -e
cd "$(dirname "$0")"
case "$*" in
*-Doptimize*) exec zig build --prefix build "$@" ;;
*) exec zig build --prefix build -Doptimize=ReleaseSafe "$@" ;;
esac
