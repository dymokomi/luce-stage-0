# Numeric semantics

This page is the reference for how Luce's numbers behave: how the two
ladders mix, what `/`, `//` and `%` do, when arithmetic traps, how
values compare across the ladders, and what each conversion constructor
rounds. The types themselves — the seven-rung ladder, the storage
types, and the widening rules — are in `docs/TYPES.md`.

## Promotion

An operator first takes each operand to its **arithmetic type**: `byte`
and `short` to `int`, `half` to `float`, and `int`, `long`, `float` and
`double` to themselves. No expression ever has a storage type, so
arithmetic happens at four types, never seven.

The two arithmetic operands then meet at a common type:

- Two of the same type meet at that type.
- Two integers meet at the wider (`long`).
- Two floats meet at the wider (`double`).
- An integer and a float meet at `double`, whichever way round they were
  written.

Promotion is implicit and one-directional: it only ever widens, and it
targets `double` across the ladders — never `float` — because a 32-bit
float cannot hold every 32-bit integer. Nothing narrows implicitly
(`docs/TYPES.md`).

## `/` is true division

`/` always divides. It promotes both operands to a float and answers a
float — `double` unless both operands are already `float` — so
`7 / 2` is `3.5`, not `3`.

```luce
func main():
    print(str(7 / 2))         # 3.5
    print(str(23 / 7))        # 3.2857142857142856 — a f64
```

Integer operands promote to `double`, so integer division answers full
`double` precision even when it divides evenly (`6 / 3` is the `double`
value `2`). The result is `float` only when both operands are already
`float`.

`/` follows IEEE 754 and never traps: dividing by zero yields `inf` or
`NaN`, exactly as any other float operation would.

## `//` and `%`: the floor pair

`//` is floor division and `%` is the modulus that pairs with it. For
integer operands both answer the promoted integer type; they floor
together, so `%` takes the sign of the **divisor** and
`b * (a // b) + (a % b) == a` holds for every sign.

```luce
func main():
    print(str(7 // 2))        # 3
    print(str(7 % 3))         # 1
    print(str(-7 % 3))        # 2 — sign of the divisor
    print(str(-7 // 3))       # -3
```

`//` and `%` accept mixed operands too, promoting like every other
arithmetic operator: `7.5 // 2.0` is `3.0` (`floor(a / b)`), and on
floats they follow IEEE — `1.0 // 0.0` is `inf`. To floor a float to an
integer *value*, convert the floored result: `long(floor(x))`.

## Division by zero

The operators that produce an integer trap; the one that produces a
float is IEEE.

| Expression | Result |
|---|---|
| `1 / 0` | `inf` |
| `0 / 0` | `NaN` |
| `1 // 0` | trap `divide_by_zero` |
| `1 % 0` | trap `divide_by_zero` |

```luce
func main():
    var a: i32 = 1
    var b: i32 = 0
    print(str(a // b))
```

```output
loom: trap: division by zero [divide_by_zero]
    at main (main.luc:4:5)
```

## Checked arithmetic

The four integer types are checked: `+`, `-`, `*` and negation trap
`integer_overflow` when the true result does not fit, rather than
wrapping. This holds at both arithmetic integer widths — an `int`
counter overflows at ±2³¹, a `long` at ±2⁶³.

```luce
func main():
    var x: i32 = 46341
    print(str(x * x))         # 2147488281 > 2^31 - 1
```

```output
loom: trap: integer overflow [integer_overflow]
    at main (main.luc:3:5)
```

Storage types have no arithmetic and therefore no overflow: `byte` 255
plus 1 does not wrap and does not trap, because the addition happens at
`int` and its result is the `int` value 256. What can fail is storing
that result back into a storage type, which is a **checked narrowing**:

```luce
func main():
    var b: u8 = 255
    b += 1                       # b = u8(b + 1); 256 does not fit
    print(str(b))
```

```output
loom: trap: conversion out of range [conversion_range]
    at main (main.luc:3:5)
```

The floats never trap on arithmetic; they reach `inf` and `NaN` under
IEEE 754.

## Comparison across the ladders

`==`, `<` and the other comparisons work between an integer and a float,
and the comparison is **exact** — it compares the two numbers, not a
lossy conversion of one to the other. Widening the integer first would
answer wrongly at the boundary:

```luce
func main():
    var n: i64 = 9007199254740993
    print(str(n == 9007199254740992.0))   # false
```

The two values differ by one, and `9007199254740993` cannot be
represented in `double`; an exact comparison reports `false`, where a
naive widening would report `true`.

## Conversions

Every numeric type has a conversion constructor named for the type it
produces — `byte(x)`, `short(x)`, `int(x)`, `long(x)`, `half(x)`,
`float(x)`, `double(x)` — and `string(x)` renders to text. A conversion
is the only way to narrow, since narrowing is never implicit.

- **A float to an integer** rounds half away from zero and traps
  `conversion_range` outside the target's range — `NaN` and the
  infinities included. `int(3.9)` is `4`; `int(-2.5)` is `-3`.
- **An integer to an integer that cannot hold it** traps the same way:
  `byte(300)` is a program that stops, not `300` modulo anything.
- **An integer to a float** rounds to nearest and never traps.
- **A float to a narrower float** rounds to nearest, ties to even, and
  may produce `inf` rather than trapping.
- **A widening constructor never traps.** It is redundant with promotion
  but stays, because it is how you widen where there is no operator to
  hang the widening on.

```luce
func main():
    let x = 3.9
    print(str(i32(x)))            # 4 — rounds
    print(str(i64(floor(x))))    # 3 — floor, then convert
```

```luce
func main():
    var over: i64 = 300
    print(str(u8(over)))
```

```output
loom: trap: conversion out of range [conversion_range]
    at main (main.luc:3:5)
```

### `floor`, `ceil`, `trunc`

`floor`, `ceil` and `trunc` take a float and answer a float of the same
width — they round without narrowing. Pair one with a conversion
constructor to reach an integer value: `long(floor(x))`,
`int(ceil(x))`.

### `string(x)`

`string(x)` prints a number with the shortest text that round-trips **at
its own width**, so the width is visible in the answer: a `float`
divided out prints fewer digits than the same `double` would. It also
renders a `bool`, a `string` (unchanged), an enum or union member's name,
and a function value's name.

```luce
func main():
    print(str(f64(1.0) / f64(3.0)))   # 0.3333333333333333
    print(str(f32(1.0) / f32(3.0)))     # 0.33333334
```

### Formatting in f-strings

A float interpolated into an f-string takes an optional `:.Nf` spec —
`N` decimal places, rounded half away from zero:

```luce
import std.strings

func main():
    let mean = 23.99
    print(f"mean = {mean:.2f}")      # mean = 23.99
```
