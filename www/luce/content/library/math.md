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

`pi`, `tau`, and `e` are `double` constants.

| Signature | Behavior |
|---|---|
| `math.round(x: double) -> double` | rounds half away from zero (`-2.5` becomes `-3.0`) |
| `math.exp(x: double) -> double` | exponential; large values overflow to infinity and very negative values underflow to `0.0` |
| `math.ln(x: double) -> double` | natural logarithm; traps when `x <= 0` |
| `math.log2(x: double) -> double` | base-2 logarithm; same domain as `ln` |
| `math.log10(x: double) -> double` | base-10 logarithm; same domain as `ln` |
| `math.pow(x: double, y: double) -> double` | real power; negative bases require a whole-number exponent, and `0` with a negative exponent traps |
| `math.ipow(base: long, exponent: long) -> long` | checked integer power; negative exponents and overflow trap |
| `math.sin(x: double) -> double` | sine of radians for finite `|x| <= 10000` |
| `math.cos(x: double) -> double` | cosine of radians for finite `|x| <= 10000` |
| `math.tan(x: double) -> double` | tangent of radians; uses the same input domain as `sin` and `cos` |

The trigonometric functions refuse values outside their finite range instead
of returning a result whose range reduction has lost significant digits.

```luce run
import std.math
import std.strings

func main():
    print(strings.format_float(math.pi, 4))
    print(string(math.round(-2.5)))
    print(string(math.ipow(2, 10)))
    print(strings.format_float(math.sin(math.pi / 2.0), 2))
```

```output
3.1416
-3
1024
1.00
```

## Arrays and statistics

These functions take `array(double, _)`. Reductions visit elements from
left to right. An empty array has sum `0.0`; functions whose answer would
not exist return `none`.

| Signature | Behavior |
|---|---|
| `math.sum(xs) -> double` | sum of all elements |
| `math.mean(xs) -> double?` | arithmetic mean, or `none` when empty |
| `math.vmin(xs) -> double?` | smallest element, or `none` when empty |
| `math.vmax(xs) -> double?` | largest element, or `none` when empty |
| `math.minmax(xs) -> (double?, double?)` | smallest and largest in one pass, or `none, none` when empty |
| `math.dot(xs, ys) -> double` | dot product; lengths must match |
| `math.norm(xs) -> double` | Euclidean norm |
| `math.variance(xs) -> double?` | population variance, or `none` when empty |
| `math.stddev(xs) -> double?` | square root of population variance |
| `math.fill(xs, value: double)` | writes `value` to every element |
| `math.scale(xs, factor: double)` | multiplies every element by `factor` in place |
| `math.axpy(xs, factor: double, ys)` | writes `xs[i] += factor * ys[i]`; lengths must match |

`dot` and `axpy` trap on a shape mismatch. Optional results are narrowed
with `else`:

```luce run
import std.math

func main():
    var xs = new array(double, 4)
    for i in range(0, 4):
        xs[i] = double(i + 1)
    print(string(math.sum(xs)))
    print(string(math.mean(xs) else 0.0))
    print(string(math.vmin(xs) else 0.0))

    var empty = new array(double, 0)
    print(string(math.mean(empty) else -1.0))
```

```output
10
2.5
1
-1
```

## `Rng`

`math.rng(seed: long) -> Rng` creates a deterministic Lehmer/MINSTD
generator. The state is private and is updated by its methods, so keep the
receiver in a `var` binding.

| Method | Result |
|---|---|
| `rng.next() -> long` | next state in `[1, 2³¹ − 2]` |
| `rng.real() -> double` | a value in the open interval `(0, 1)` |
| `rng.in_range(low, high) -> long` | a value in `[low, high)`; `high` is exclusive |

An out-of-range seed is normalized on the first draw. `in_range` traps when
`high <= low`; its modulo reduction has slight bias, so use it for games,
sampling, and shuffles—not secrets.

```luce run
import std.math

func main():
    var rng = math.rng(2026)
    print(string(rng.in_range(1, 7)))
    var same = math.rng(2026)
    print(string(same.in_range(1, 7)))
```

```output
5
5
```

The same seed and call sequence produce the same values. The generator is
not cryptographically secure.
