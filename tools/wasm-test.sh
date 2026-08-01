#!/bin/sh
# Validate the WebAssembly backend (codegen_wasm) against the
# interpreter: compile a corpus of scalar-core programs to .wasm, run
# each in a real wasm runtime (deno), and demand the emitted output —
# and any trap code — match what the interpreter produces.  The wasm
# oracle: a different execution model, held to the same reference.
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

# A program plus its expectation: either the exact printed output
# ("output"), or a trap code ("trap N").  The corpus walks the whole
# scalar core — nested loops, the while form, every operator, the
# branch, boolean compares, recursion and mutual recursion across
# functions, floats through Int()/asserts, the checked conversions and
# each checked-arithmetic trap.
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
            printf '  %-18s OK\n' "$name"
        else
            printf '  %-18s MISMATCH\n    wasm:   %s\n    interp: %s\n' "$name" "$wasm_out" "$interp"
            failed=1
        fi
    else # trap: the wasm must trap with the expected code
        code="$(echo "$trap_line" | awk '{print $2}')"
        if [ "$code" = "$expect" ]; then
            printf '  %-18s OK (trap %s)\n' "$name" "$expect"
        else
            printf '  %-18s MISMATCH — trap %s, wanted %s\n' "$name" "${code:-none}" "$expect"
            failed=1
        fi
    fi
}

echo "wasm backend vs interpreter (scalar core):"

# -- integer core -----------------------------------------------------------

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

run_case bool_compare "func main():
    var a = 3
    var b = 4
    var p = a < b
    var q = a == b
    if p == q:
        print(str(1))
    if p != q:
        print(str(0))
    if (a < b) == (b > a):
        print(str(7))" output

run_case remainder "func main():
    print(str(0 - 17 % 5))
    print(str(17 % (0 - 5)))
    print(str((0 - 9223372036854775807 - 1) % 7))" output

# -- multiple functions, recursion ------------------------------------------

run_case fib "func fib(n: Int) -> Int:
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)

func main():
    for i in range(0, 20):
        print(str(fib(i)))" output

run_case mutual "func even(n: Int) -> Bool:
    if n == 0:
        return true
    return odd(n - 1)

func odd(n: Int) -> Bool:
    if n == 0:
        return false
    return even(n - 1)

func main():
    for i in range(0, 10):
        if even(i):
            print(str(i))" output

run_case factorial "func fact(n: Int) -> Int:
    if n <= 1:
        return 1
    return n * fact(n - 1)

func main():
    print(str(fact(20)))" output

run_case fact_overflow "func fact(n: Int) -> Int:
    if n <= 1:
        return 1
    return n * fact(n - 1)

func main():
    print(str(fact(21)))" trap 0

run_case void_call "func note(x: Int) -> Int:
    return x * x

func main():
    var s = 0
    for i in range(1, 6):
        s += note(i)
    print(str(s))" output

# -- floats, observed through Int() and asserts -----------------------------

run_case float_arith "func main():
    var x = 1.5
    var y = 4.0
    print(str(Int((x + y) * 10.0)))
    print(str(Int((y - x) * 10.0)))
    print(str(Int((x * y) * 10.0)))
    print(str(Int((y / x) * 100.0)))" output

run_case float_funcs "func norm2(x: Float, y: Float) -> Float:
    return sqrt(x * x + y * y)

func main():
    print(str(Int(norm2(3.0, 4.0))))
    print(str(Int(floor(2.7))))
    print(str(Int(ceil(2.1))))
    print(str(Int(abs(0.0 - 5.5) * 10.0)))" output

run_case mandel_count "func main():
    var inside = 0
    for py in range(0, 40):
        for px in range(0, 40):
            let cx = Float(px) * (3.0 / 40.0) - 2.25
            let cy = Float(py) * (2.5 / 40.0) - 1.25
            var x = 0.0
            var y = 0.0
            var it = 0
            while it < 100:
                let xx = x * x - y * y + cx
                let yy = 2.0 * x * y + cy
                x = xx
                y = yy
                if x * x + y * y > 4.0:
                    it = 100
                it += 1
            if it == 100:
                inside += 1
    print(str(inside))" output

run_case int_min_max "func main():
    print(str(min(3, 7)))
    print(str(max(3, 7)))
    print(str(min(0 - 4, 0 - 9)))
    print(str(clamp(15, 0, 10)))
    print(str(clamp(0 - 3, 0, 10)))
    print(str(clamp(5, 0, 10)))
    print(str(abs(0 - 42)))" output

# -- checked conversions and traps ------------------------------------------

run_case conv_roundtrip "func main():
    for i in range(0, 12):
        let f = Float(i) * 1.5
        print(str(Int(f)))" output

run_case conv_range "func main():
    var big = 1.0e19
    print(str(Int(big)))" trap 2

run_case conv_nan "func main():
    var z = 0.0
    var nan = z / z
    print(str(Int(nan)))" trap 2

run_case negate_min "func main():
    var lo = 0 - 9223372036854775807 - 1
    print(str(0 - lo))" trap 0

run_case abs_min "func main():
    var lo = 0 - 9223372036854775807 - 1
    print(str(abs(lo)))" trap 0

run_case div_zero "func main():
    var z = 0
    print(str(10 / z))" trap 1

run_case assert_fail "func main():
    var x = 41
    assert(x == 42)
    print(str(x))" trap 3

run_case depth_ok "func rec(n: Int) -> Int:
    if n == 0:
        return 0
    return rec(n - 1) + 1

func main():
    print(str(rec(126)))" output

run_case depth_exceeded "func rec(n: Int) -> Int:
    return rec(n + 1)

func main():
    print(str(rec(0)))" trap 7

# -- strings ----------------------------------------------------------------

run_case str_build "func tag(n: Int) -> String:
    return \"[\" + str(n) + \"]\"

func main():
    var s = \"\"
    for i in range(0, 6):
        s = s + tag(i * i)
    print(s)
    print(str(len(s)))
    print(str(s < \"zzz\"))
    print(str(\"abc\" == \"abc\"))" output

run_case str_slice_bytes "func main():
    var s = \"hello, world\"
    print(s[0:5])
    print(s[7:12])
    print(str(s.byte_at(0)))
    print(str(s.find_byte(111, 0)))
    print(str(len(s[0:0])))" output

run_case str_unicode "func main():
    var s = chr(72) + chr(128512) + chr(233)
    print(s)
    print(str(len(s)))
    print(str(ord(s)))
    print(str(ord(chr(233))))" output

run_case str_parse "func main():
    print(str(parse_int(\"42\") + parse_int(\"-8\")))
    print(str(parse_int(\"0\")))
    print(str(parse_int(\"9223372036854775807\")))" output

run_case slice_bounds "func main():
    var s = \"abc\"
    print(s[0:9])" trap 11

run_case slice_boundary "func main():
    var s = chr(233)
    print(s[0:1])" trap 12

run_case byte_oob "func main():
    var s = \"ab\"
    print(str(s.byte_at(5)))" trap 11

run_case ord_empty "func main():
    var s = \"\"
    print(str(ord(s)))" trap 22

run_case parse_bad "func main():
    print(str(parse_int(\"12x\")))" trap 21

run_case parse_overflow "func main():
    print(str(parse_int(\"9223372036854775808\")))" trap 21

if [ $failed -eq 0 ]; then
    echo "wasm backend: every program matches the interpreter."
else
    echo "wasm backend: MISMATCHES above."
    exit 1
fi
