#!/bin/sh
# Build LuciaOS: installs the loom terminal at build/loom and the C
# border library at build/lib/libloom.a.  Extra arguments pass through
# to zig build (e.g. ./build.sh -Doptimize=ReleaseSafe).
set -e
cd "$(dirname "$0")"
exec zig build --prefix build "$@"
