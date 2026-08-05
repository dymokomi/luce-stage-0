# std.math

Pure Luce over the checked builtins. `sqrt`, `floor`, `ceil`, `trunc`,
`abs`, `min`, `max` and `clamp` stay [builtins](/ref/builtins/);
`math` adds what they lack.

```
import std.math
```

## Constants

`math.pi`, `math.tau`, `math.e`, `math.ln2`, `math.ln10`. All five are
compile-time constants and fold at their use sites.

## Scalar functions

| Signature | Notes |
|---|---|
| `math.round(x: Float) -> Float` | half **away from zero**: `round(-2.5)` is `-3.0`; the same rounding `Int(x)` does |
| `math.exp(x: Float) -> Float` | overflow yields infinity, underflow yields `0.0` |
| `math.ln(x: Float) -> Float` | traps for `x <= 0` |
| `math.log2(x)`, `math.log10(x)` | |
| `math.pow(x: Float, y: Float) -> Float` | negative `x` needs a whole `y` or it traps; `0^negative` traps; `0^0` is `1` |
| `math.ipow(base: Int, n: Int) -> Int` | integer power by squaring; checked, so overflow traps; negative `n` traps |
| `math.sin(x)`, `math.cos(x)`, `math.tan(x)` | radians; every `Float` is in the domain, but see the accuracy note below |

Series are range-reduced, and `exp` and `ln` hold to about 1e-14
relative.

**The trigonometric accuracy depends on the magnitude.** Range
reduction is `x - floor(x / tau) * tau` in ordinary double precision,
so the error in the reduced angle grows with the size of `x` and the
result loses digits with it. Measured against the system libm on one
host:

| magnitude of `x` | absolute error of `sin` |
|---|---|
| 1 | exact |
| 1e3 | 1e-14 |
| 1e4 | 1.4e-12 |
| 1e6 | 6.8e-11 |
| 1e9 | 1.3e-8 |
| 1e15 | 8.0e-3 |

So "about 1e-12 absolute" is a promise for arguments up to roughly
1e4, and nothing bigger. There is no domain error and nothing traps —
a huge argument returns a plausible number that is simply wrong,
which is the usual shape of this problem and the reason it is written
down here. Reduce large angles yourself if you need them.

```luce run
import std.math
import std.strings

func main():
    print(strings.format_float(math.pi, 6))
    print(String(math.round(2.5)) + " " + String(math.round(-2.5)))
    print(strings.format_float(math.exp(1.0), 6))
    print(strings.format_float(math.ln(math.e), 6))
    print(strings.format_float(math.log2(1024.0), 1))
    print(String(math.ipow(2, 20)))
    print(strings.format_float(math.pow(2.0, 0.5), 6))
    print(strings.format_float(math.sin(math.pi / 2.0), 6))
```

```output
3.141593
3 -3
2.718282
1.000000
10.0
1048576
1.414214
1.000000
```

## Vectors and statistics

Whole-array operations over `Array(Float, _)`, the numeric vector
type — the numpy-shaped tranche. Reductions accumulate left to right,
so they are bit-reproducible, including against the benchmark's C
twins.

| Signature | Notes |
|---|---|
| `math.sum(xs) -> Float` | |
| `math.mean(xs) -> Float?` | `none` for an empty array |
| `math.vmin(xs) -> Float?`, `math.vmax(xs) -> Float?` | extrema; `min`/`max` are the scalar builtins |
| `math.minmax(xs) -> (Float?, Float?)` | both, in **one** traversal. There could not have been one before multiple returns: writing it would have meant inventing a bag struct in the standard library |
| `math.dot(xs, ys) -> Float` | a shape mismatch traps |
| `math.norm(xs) -> Float` | Euclidean |
| `math.variance(xs) -> Float?`, `math.stddev(xs) -> Float?` | population |
| `math.fill(xs, value)` | in place |
| `math.scale(xs, factor)` | in place |
| `math.axpy(xs, factor, ys)` | in place: `xs[i] += factor * ys[i]`; a shape mismatch traps |

The five that answer `Float?` do so because an empty array has no
mean, and "there is nothing there" is the same fact every time with no
reason worth carrying.

```luce run
import std.math
import std.strings

func main():
    var xs = new Array(Float, 5)
    for i in range(0, 5):
        xs[i] = Float(i) * 2.0 + 1.0

    print(f"sum {math.sum(xs)}")
    print(f"mean {math.mean(xs) else 0.0}")
    print(f"min {math.vmin(xs) else 0.0} max {math.vmax(xs) else 0.0}")
    print(strings.format_float(math.stddev(xs) else 0.0, 4))
    print(strings.format_float(math.norm(xs), 4))

    var ys = new Array(Float, 5)
    math.fill(ys, 2.0)
    print(f"dot {math.dot(xs, ys)}")
    math.scale(ys, 0.5)
    math.axpy(ys, 10.0, xs)
    print(f"ys[0] {ys[0]}, ys[4] {ys[4]}")

    var empty = new Array(Float, 0)
    print(f"mean of nothing: {math.mean(empty) else -1.0}")
```

```output
sum 25
mean 5
min 1 max 9
2.8284
12.8452
dot 50
ys[0] 11, ys[4] 91
mean of nothing: -1
```

## Randomness

A Lehmer/MINSTD generator whose state is one `Int` in a struct. Every
draw is a `var self` method, so the state
is *written back* rather than mutated through a reference: there are
no hidden globals, no allocation, and every stream is deterministic
from its seed.

| Signature | Notes |
|---|---|
| `math.Rng(state: Int)` | a generator. Any seed works — `folded` puts it in `[1, 2³¹ − 2]` |
| `rng.next() -> Int` | the raw next state in `[1, 2³¹ − 2]`; the two below are the friendly faces over it |
| `rng.real() -> Float` | in the open interval (0, 1) |
| `rng.in_range(low, high) -> Int` | in `[low, high)`, `high` exclusive like `range`; an empty range traps. Slightly modulo-biased, which is meaningless at the spans a game uses |

The receiver must be a `var`: `var rng = math.Rng(state = 42)`.

Period 2³¹ − 2. Good for games and shuffles; **never for secrets**.

```luce run
import std.math

func main():
    var rng = math.Rng(state = 2026)
    var rolls: List(Int) = []
    for i in range(0, 8):
        rolls.append(rng.in_range(1, 7))

    var text = new Builder()
    for roll in rolls:
        text.append(String(roll))
        text.append(" ")
    print(text.build())

    # The same seed gives the same stream, always.
    var again = math.Rng(state = 2026)
    print(f"first roll again: {again.in_range(1, 7)}")
```

```output
5 3 1 5 6 3 4 1 
first roll again: 5
```

## The traps that remain

Seven, and each is a domain the caller was handed and could have
checked: `ln` of a non-positive number, `pow` and `ipow` outside
theirs, a shape mismatch in `dot` or `axpy`, and `random_int` with an
empty range. Those are bugs, and
[bugs trap](/guide/failure/).

```luce trap
import std.math

func main():
    print("about to take a logarithm")
    print(String(math.ln(0.0)))
```

```output
about to take a logarithm
loom: trap: ln of a non-positive number [explicit_trap]
    at math.ln (std/math.luc:67:9)
    at main (main.luc:5:5)
```
