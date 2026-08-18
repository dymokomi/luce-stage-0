# std.math

`std.math` adds scalar functions, fixed-shape array operations, and a small
deterministic random generator to the numeric builtins. It is pure Luce and
does not need a host.

```text
import std.math
```

The builtins already provide `sqrt`, `floor`, `ceil`, `trunc`, `abs`, `min`,
`max`, and `clamp`. Use this module for the operations below.

## Constants and scalar functions

`pi`, `tau`, and `e` are `f64` constants.

| Signature | Behavior |
|---|---|
| `math.round(x: f64) -> f64` | rounds half away from zero (`-2.5` becomes `-3.0`) |
| `math.exp(x: f64) -> f64` | exponential; large values overflow to infinity and very negative values underflow to `0.0` |
| `math.ln(x: f64) -> f64` | natural logarithm; traps when `x <= 0` |
| `math.log2(x: f64) -> f64` | base-2 logarithm; same domain as `ln` |
| `math.log10(x: f64) -> f64` | base-10 logarithm; same domain as `ln` |
| `math.pow(x: f64, y: f64) -> f64` | real power; negative bases require a whole-number exponent, and `0` with a negative exponent traps |
| `math.ipow(base: i64, exponent: i64) -> i64` | checked integer power; negative exponents and overflow trap |
| `math.sin(x: f64) -> f64` | sine of radians for finite `|x| <= 10000` |
| `math.cos(x: f64) -> f64` | cosine of radians for finite `|x| <= 10000` |
| `math.tan(x: f64) -> f64` | tangent of radians; uses the same input domain as `sin` and `cos` |

The trigonometric functions refuse values outside their finite range instead
of returning a result whose range reduction has lost significant digits.

```luce run
import std.math
import std.strings

func main():
    print(strings.format_float(math.pi, 4))
    print(str(math.round(-2.5)))
    print(str(math.ipow(2, 10)))
    print(strings.format_float(math.sin(math.pi / 2.0), 2))
```

```output
3.1416
-3
1024
1.00
```

## Arrays and statistics

These functions take `array[f64, _]`. Reductions visit elements from
left to right. An empty array has sum `0.0`; functions whose answer would
not exist return `none`.

| Signature | Behavior |
|---|---|
| `math.sum(xs) -> f64` | sum of all elements |
| `math.mean(xs) -> f64?` | arithmetic mean, or `none` when empty |
| `math.vmin(xs) -> f64?` | smallest element, or `none` when empty |
| `math.vmax(xs) -> f64?` | largest element, or `none` when empty |
| `math.minmax(xs) -> (f64?, f64?)` | smallest and largest in one pass, or `none, none` when empty |
| `math.dot(xs, ys) -> f64` | dot product; lengths must match |
| `math.norm(xs) -> f64` | Euclidean norm |
| `math.variance(xs) -> f64?` | population variance, or `none` when empty |
| `math.stddev(xs) -> f64?` | square root of population variance |
| `math.fill(xs, value: f64)` | writes `value` to every element |
| `math.scale(xs, factor: f64)` | multiplies every element by `factor` in place |
| `math.axpy(xs, factor: f64, ys)` | writes `xs[i] += factor * ys[i]`; lengths must match |

`dot` and `axpy` trap on a shape mismatch. Optional results are narrowed
with `else`:

```luce run
import std.math

func main():
    var xs = new array[f64](4)
    for i in range(0, 4):
        xs[i] = f64(i + 1)
    print(str(math.sum(xs)))
    print(str(math.mean(xs) else 0.0))
    print(str(math.vmin(xs) else 0.0))

    var empty = new array[f64](0)
    print(str(math.mean(empty) else -1.0))
```

```output
10
2.5
1
-1
```

## `Rng`

`new math.Rng(seed: i64)` creates a deterministic Lehmer/MINSTD
generator. A generator is stateful identity — a class — so handing it to a
helper hands the same sequence rather than a silent copy; the state stays
private and every draw advances it.

| Method | Result |
|---|---|
| `rng.next() -> i64` | next state in `[1, 2³¹ − 2]` |
| `rng.real() -> f64` | a value in the open interval `(0, 1)` |
| `rng.in_range(low, high) -> i64` | a value in `[low, high)`; `high` is exclusive |

An out-of-range seed is normalized on the first draw. `in_range` traps when
`high <= low`; its modulo reduction has slight bias, so use it for games,
sampling, and shuffles—not secrets.

```luce run
import std.math

func main():
    var rng = new math.Rng(2026)
    print(str(rng.in_range(1, 7)))
    var same = new math.Rng(2026)
    print(str(same.in_range(1, 7)))
```

```output
5
5
```

The same seed and call sequence produce the same values. The generator is
not cryptographically secure.
