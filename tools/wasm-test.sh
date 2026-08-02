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

# -- lists and builders (heap phase B1) --------------------------------------

run_case list_ops "func main():
    var xs = new List(Int)
    for i in range(0, 10):
        xs.append((i * 7) % 13)
    print(str(len(xs)))
    var total = 0
    for x in xs:
        total += x
    print(str(total))
    xs[0] = 99
    print(str(xs[0]))
    print(str(xs.pop()))
    xs.insert(0, 5)
    xs.remove(1)
    xs.sort()
    print(str(xs[0]) + \",\" + str(xs[len(xs) - 1]))
    xs.reverse()
    print(str(xs[0]))
    print(str(xs.find(5)) + \" \" + str(xs.contains(99)))" output

run_case list_string "func main():
    var ws = new List(String)
    ws.append(\"pear\")
    ws.append(\"apple\")
    ws.append(\"fig\")
    ws.sort()
    for w in ws:
        print(w)
    print(str(ws.find(\"fig\")))" output

run_case builder "func main():
    var b = new Builder()
    for i in range(0, 26):
        b.append_ascii(97 + i)
    b.append(\"-done\")
    print(str(b))
    print(str(len(b)))" output

run_case list_slice "func main():
    var xs = new List(Int)
    for i in range(0, 6):
        xs.append(i)
    var ys = xs[1:4]
    print(str(len(ys)))
    for y in ys:
        print(str(y))" output

run_case list_return "func build(n: Int) -> List(Int):
    var r = new List(Int)
    for i in range(0, n):
        r.append(i * i)
    return r

func total(xs: List(Int)) -> Int:
    var t = 0
    for x in xs:
        t += x
    return t

func main():
    var a = build(5)
    print(str(total(a)))
    print(str(len(a)))" output

run_case list_empty_pop "func main():
    var xs = new List(Int)
    print(str(xs.pop()))" trap 18

run_case list_oob "func main():
    var xs = new List(Int)
    xs.append(1)
    print(str(xs[5]))" trap 16

# -- arrays (heap phase B2) --------------------------------------------------

run_case array_2d "func main():
    var g = new Array(Int, 4, 5)
    for r in range(0, 4):
        for c in range(0, 5):
            g[r, c] = r * 5 + c
    var total = 0
    for r in range(0, 4):
        for c in range(0, 5):
            total += g[r, c]
    print(str(total))
    print(str(g[3, 4]))
    print(str(len(g)))" output

run_case array_fill_sort "func main():
    var v = new Array(Int, 8)
    v.fill(3)
    v[0] = 9
    v[7] = 1
    var s = 0
    for i in range(0, 8):
        s += v[i]
    print(str(s))
    v.sort()
    print(str(v[0]) + \",\" + str(v[7]))
    v.reverse()
    print(str(v[0]))" output

run_case array_float "func main():
    var a = new Array(Float, 4)
    a.fill(1.5)
    a[1] = 2.5
    var s = 0.0
    for i in range(0, 4):
        s += a[i]
    print(str(Int(s * 10.0)))" output

run_case array_oob "func main():
    var g = new Array(Int, 2, 3)
    print(str(g[1, 5]))" trap 16

run_case array_neg_dim "func main():
    var n = 0 - 1
    var g = new Array(Int, n)
    print(str(len(g)))" trap 16

# -- maps (heap phase B3) ----------------------------------------------------

run_case map_string "func main():
    var m = new Map(String, Int)
    var words = new List(String)
    words.append(\"a\")
    words.append(\"b\")
    words.append(\"a\")
    words.append(\"c\")
    words.append(\"a\")
    for w in words:
        m[w] = m.get(w, 0) + 1
    print(str(m[\"a\"]))
    print(str(m[\"b\"]))
    print(str(len(m)))
    print(str(m.has(\"c\")) + \" \" + str(m.has(\"z\")))
    var keys = m.keys()
    keys.sort()
    for k in keys:
        print(k)" output

run_case map_int "func main():
    var m = new Map(Int, Int)
    for i in range(0, 6):
        m[i % 3] = m.get(i % 3, 0) + i
    print(str(m[0]) + \",\" + str(m[1]) + \",\" + str(m[2]))
    m.remove(1)
    print(str(m.has(1)))
    var vs = m.values()
    var total = 0
    for v in vs:
        total += v
    print(str(total))" output

run_case map_missing "func main():
    var m = new Map(String, Int)
    m[\"a\"] = 1
    print(str(m[\"b\"]))" trap 17

# -- give / copy / free (heap phase B4) --------------------------------------

run_case copy_independent "func main():
    var xs = new List(Int)
    xs.append(1)
    xs.append(2)
    var ys = copy xs
    ys.append(3)
    xs[0] = 99
    print(str(len(xs)) + \" \" + str(len(ys)))
    print(str(ys[0]) + \" \" + str(xs[0]))
    free(xs)
    free(ys)" output

run_case give_free "func consume(g: give List(Int)) -> Int:
    var t = 0
    for x in g:
        t += x
    free(g)
    return t

func main():
    var xs = new List(Int)
    for i in range(0, 5):
        xs.append(i)
    print(str(consume(give xs)))" output

run_case copy_array "func main():
    var a = new Array(Int, 3)
    a.fill(4)
    var b = copy a
    b[0] = 9
    print(str(a[0]) + \" \" + str(b[0]))
    free(a)
    free(b)" output

# -- structs (heap phase B5) -------------------------------------------------

run_case float_str "func main():
    print(str(1.5))
    print(str(2.0))
    print(str(0.1))
    print(str(1.0 / 3.0))
    print(str(0.0 - 2.5))
    print(str(0.0 * (0.0 - 1.0)))
    print(str(1.0e300))
    print(str(5.0e-324))
    var z = 0.0
    print(str(z / z))
    print(str(1.0 / z))
    print(str((0.0 - 1.0) / z))" output

run_case struct_basic "struct Vec:
    x: Int
    y: Int
    z: Int

func norm2(v: Vec) -> Int:
    return v.x * v.x + v.y * v.y + v.z * v.z

func main():
    var v = Vec(x = 1, y = 2, z = 3)
    print(str(norm2(v)))
    var w = Vec(x = v.x + 10, y = v.y, z = v.z)
    print(str(w.x) + \",\" + str(w.y) + \",\" + str(w.z))
    print(str(norm2(v)))" output

run_case struct_eq "struct Rec:
    tag: String
    n: Int
    r: Float

func main():
    var a = Rec(tag = \"hi\", n = 5, r = 1.5)
    var b = Rec(tag = \"hi\", n = 5, r = 1.5)
    var c = Rec(tag = \"hi\", n = 6, r = 1.5)
    print(str(a == b))
    print(str(a == c))
    print(str(a != c))
    print(a.tag + \" \" + str(a.n) + \" \" + str(Int(a.r * 10.0)))" output

# -- float min/max/clamp and float % ----------------------------------------

run_case float_minmax "func main():
    var z = 0.0
    var nan = z / z
    var nz = 0.0 * (0.0 - 1.0)
    print(str(Int(min(nan, 3.0))))
    print(str(Int(max(nan, 7.0))))
    print(str(1.0 / min(nz, 0.0) < 0.0))
    print(str(1.0 / max(nz, 0.0) < 0.0))
    print(str(Int(clamp(9.0, 1.0, 5.0))))
    print(str(Int(min(2.5, 7.5) * 10.0)))" output

run_case float_rem "func main():
    var r = 5.5 % 2.0
    print(str(Int(r * 10.0)))
    var s = (0.0 - 5.5) % 2.0
    print(str(1.0 / s < 0.0))
    print(str(Int(abs(s) * 10.0)))
    var t = 6.0 % 3.0
    print(str(1.0 / t < 0.0))
    var big = 1.0e300 % 3.7
    print(str(Int(big * 1000000.0)))
    var bad = 1.0 % 0.0
    print(str(bad != bad))" output

run_case struct_in_list "struct P:
    x: Int
    y: Int

func main():
    var pts = new List(P)
    for i in range(0, 4):
        pts.append(P(x = i, y = i * i))
    var total = 0
    for p in pts:
        total += p.x + p.y
    print(str(total))
    print(str(pts[2].y))" output

if [ $failed -eq 0 ]; then
    echo "wasm backend: every program matches the interpreter."
else
    echo "wasm backend: MISMATCHES above."
    exit 1
fi
