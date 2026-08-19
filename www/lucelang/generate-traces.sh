#!/bin/sh
# Refresh the checked trace artifacts embedded by lucelang.org. This is a
# deliberate maintenance command, not part of the normal site build. The
# compiler must come from a detached worktree so this site job never builds or
# modifies the shared development tree.
set -e

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
repo=$(CDPATH= cd "$here/../.." && pwd)
destination=${1:-"$here/traces"}
compiler=${LUCELANG_COMPILER:-}

if [ -z "$compiler" ]; then
    echo "traces: set LUCELANG_COMPILER to an inspection build in a detached worktree" >&2
    exit 1
fi
compiler_dir=$(CDPATH= cd "$(dirname "$compiler")" && pwd -P)
compiler="$compiler_dir/$(basename "$compiler")"
case "$compiler" in
    "$repo"/*)
        echo "traces: refusing a compiler from the shared working tree: $compiler" >&2
        exit 1
        ;;
esac
if [ ! -x "$compiler" ]; then
    echo "traces: $compiler is missing or not executable" >&2
    exit 1
fi
if ! command -v objdump >/dev/null 2>&1; then
    echo "traces: objdump is required to produce the assembly views" >&2
    exit 1
fi

mkdir -p "$destination"
traces='journey bindings numerics text control functions structures classes interfaces sum_types failure collections modules memory closures workers standard host'

"$compiler" --build-info > "$destination/build-info.txt"
if ! grep -q '^target aarch64-' "$destination/build-info.txt"; then
    echo "traces: this edition explains ARM64, but the compiler target is different" >&2
    exit 1
fi

for name in $traces; do
    source="$here/examples/$name.luc"
    object="$destination/$name.o"
    if [ ! -f "$source" ]; then
        echo "traces: missing $source" >&2
        exit 1
    fi

    cp "$source" "$destination/$name.luc"
    "$compiler" check "$source"
    "$compiler" ir "$source" > "$destination/$name.mir"
    "$compiler" ir "$source" --llvm > "$destination/$name.ll"
    "$compiler" build "$source" --emit=object -o "$object"
    objdump --source --line-numbers --no-show-raw-insn "$object" > "$destination/$name.asm"

    grep -q '^func ' "$destination/$name.mir"
    grep -q '^target triple = ' "$destination/$name.ll"
    grep -q '@luce_main' "$destination/$name.ll"
    grep -q 'luce_main' "$destination/$name.asm"
done

# The opening chapter explains these exact transformations. Refuse to publish
# it if an optimizer or printer change makes the prose and generated evidence
# disagree.
grep -q 'multiply.i64' "$destination/journey.mir"
grep -q 'llvm.smul.with.overflow.i64' "$destination/journey.ll"
grep -Eq '[[:space:]]lsl[[:space:]].*#1' "$destination/journey.asm"
grep -Eq '[[:space:]]csel[[:space:]].*lt' "$destination/journey.asm"
grep -q '(environment).start' "$destination/closures.mir"

# The module example imports this sibling. Keep the exact source next to the
# primary file so the trace can be reproduced without guessing what was read.
cp "$here/examples/trace_math.luc" "$destination/trace_math.luc"
