#!/bin/sh
# Build every runnable example as a standalone native executable.
#
#   ./build.sh
#   examples/build_programs.sh
#
# The source for each example lives in examples/NAME/NAME.luc.  The
# executable goes under build/examples/NAME/NAME, keeping generated files
# out of the source tree while preserving the example's identity.
set -eu

examples_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$examples_root/.." && pwd)
luce=${LUCE_BIN:-"$root/build/luce"}
output_root=${EXAMPLES_BUILD_DIR:-"$root/build/examples"}

if [ ! -x "$luce" ]; then
    echo "examples: $luce is missing; run ./build.sh first" >&2
    exit 1
fi

for example in "$examples_root"/*; do
    [ -d "$example" ] || continue
    name=$(basename "$example")
    source="$example/$name.luc"
    [ -f "$source" ] || continue

    output="$output_root/$name/$name"
    mkdir -p "$(dirname "$output")"
    "$luce" build "$source" --emit=exe --release -o "$output"
done
