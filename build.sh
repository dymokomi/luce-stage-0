#!/bin/sh
# Build LuciaOS v2: installs the luce compiler and the loom terminal at
# build/, plus the compiled bundled programs at build/programs/.
#
# Installed binaries default to ReleaseSafe — the compiler and the
# runtime are a trust boundary (a .lc runs like the executable it is,
# and a .lcm is decoded from bytes), so Zig's own safety checks stay
# on.  A Debug build is ~4-5x slower: never benchmark one.  Override
# with e.g. ./build.sh -Doptimize=ReleaseFast.
set -e
cd "$(dirname "$0")"
case "$*" in
*-Doptimize*) exec zig build --prefix build "$@" ;;
*) exec zig build --prefix build -Doptimize=ReleaseSafe "$@" ;;
esac
