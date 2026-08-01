#!/bin/sh
# Validate the WebAssembly backend (codegen_wasm) against the
# interpreter: compile a corpus of integer-core programs to .wasm,
# run each in a real wasm runtime (deno), and demand the emitted
# output — and any trap code — match what the interpreter produces.
# The wasm oracle: a different execution model, held to the same
# reference.
#
#   ./build.sh && tools/wasm-test.sh
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if [ ! -x build/luce ] || [ ! -x build/loom ]; then
    echo "wasm-test: run ./build.sh first" >&2
    exit 1
fi
command -v deno >/dev/null || { echo "wasm-test: needs deno" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0

# A program plus its expectation: either the exact printed output, or
# a trap code.  The corpus walks the integer core: nested loops, the
# while form, every arithmetic operator, negation, remainder, the
# comparison-driven branch, and each checked-arithmetic trap.
run_case() {
    name="$1"; src="$2"; kind="$3"; expect="$4"
    printf '%s\n' "$src" > "$work/$name.luc"
    build/luce build "$work/$name.luc" -o "$work/$name.lc" >/dev/null
    build/luce wasm "$work/$name.luc" -o "$work/$name.wasm" >/dev/null

    interp="$(LOOM_ENGINE=interpreter build/loom run "$work/$name.lc" 2>/dev/null || true)"
    wasm_out="$(deno run --allow-read tools/wasm-run.js "$work/$name.wasm" 2>"$work/$name.err" || true)"
    trap_line="$(grep '^TRAP ' "$work/$name.err" || true)"

    if [ "$kind" = output ]; then
        if [ "$wasm_out" = "$interp" ]; then
            printf '  %-16s OK\n' "$name"
        else
            printf '  %-16s MISMATCH\n    wasm:   %s\n    interp: %s\n' "$name" "$wasm_out" "$interp"
            failed=1
        fi
    else # trap: the wasm must trap with the expected code
        code="$(echo "$trap_line" | awk '{print $2}')"
        if [ "$code" = "$expect" ]; then
            printf '  %-16s OK (trap %s)\n' "$name" "$expect"
        else
            printf '  %-16s MISMATCH — trap %s, wanted %s\n' "$name" "${code:-none}" "$expect"
            failed=1
        fi
    fi
}

echo "wasm backend vs interpreter:"

run_case loops "func main():
    var total = 0
    for i in range(0, 30):
        for j in range(0, 30):
            total += (i * j) % 7 - i / 3
    print(str(total))
    print(str(0 - total))" output

run_case while_mul "func main():
    var n = 1
    while n < 100000:
        n = n * 3
    print(str(n))" output

run_case branch "func main():
    var acc = 0
    for i in range(0, 50):
        if i % 2 == 0:
            acc += i
        elif i % 3 == 0:
            acc -= i
        else:
            acc += 1
    print(str(acc))" output

run_case remainder "func main():
    print(str(0 - 17 % 5))
    print(str(17 % (0 - 5)))
    print(str((0 - 9223372036854775807 - 1) % 7))" output

run_case overflow_add "func main():
    var a = 9223372036854775807
    print(str(a + 1))" trap 0

run_case div_zero "func main():
    var z = 0
    print(str(10 / z))" trap 1

run_case negate_min "func main():
    var lo = 0 - 9223372036854775807 - 1
    print(str(0 - lo))" trap 0

run_case div_overflow "func main():
    var lo = 0 - 9223372036854775807 - 1
    var minus = 0 - 1
    print(str(lo / minus))" trap 0

run_case assert_fail "func main():
    var x = 41
    assert(x == 42)
    print(str(x))" trap 3

if [ $failed -eq 0 ]; then
    echo "wasm backend: every program matches the interpreter."
else
    echo "wasm backend: MISMATCHES above."
    exit 1
fi
