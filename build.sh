#!/bin/sh
# Build LuciaOS v2: installs the luce compiler and the loom terminal at
# build/, plus the compiled bundled programs at build/programs/.  Extra
# arguments pass through to zig build (e.g. ./build.sh -Doptimize=ReleaseSafe).
set -e
cd "$(dirname "$0")"
exec zig build --prefix build "$@"
