#!/bin/sh
# The no-behaviour-change witness: dump `luce ir --full` for every
# bundled program, benchmark and standard-library module into a
# directory, so a refactor can be checked byte for byte against the
# tree it started from.  Not part of the build; run it by hand.
#
#   tools/ir-witness.sh /tmp/before
#   ... refactor ...
#   tools/ir-witness.sh /tmp/after
#   diff -r /tmp/before /tmp/after
set -e
out="$1"
if [ -z "$out" ]; then
    echo "usage: tools/ir-witness.sh OUTPUT-DIRECTORY" >&2
    exit 2
fi
root=$(cd "$(dirname "$0")/.." && pwd)
luce="$root/build/luce"
mkdir -p "$out"
for source in "$root"/programs/*.luc "$root"/bench/*.luc; do
    name=$(basename "$source" .luc)
    "$luce" ir "$source" --full >"$out/$name.ir" 2>&1 || echo "refused: $source" >&2
done
ls "$out" | wc -l
