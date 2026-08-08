# Values and types

Every expression in Luce has one type, known when the program is
compiled. Annotations are optional wherever the initializer decides
the answer: `let n = 1` is an `int`, and `let n: long = 1` says
otherwise out loud.

```luce run
func main():
    let count = 7                 # int
    let ratio: double = 0.5        # said out loud
    let ready = true              # bool
    let name = "loom"             # string
    print(f"{count} {ratio} {ready} {name}")
```

```output
7 0.5 true loom
```

## The scalar types

| Type | What it is |
|---|---|
| `bool` | `true` or `false`. No truthiness: nothing else is a condition. |
| `byte` | An unsigned 8-bit number, 0 … 255. Storage — see below. |
| `short` | A signed 16-bit number. Storage. |
| `int` | A signed 32-bit integer, **checked**: overflow is a trap, not a wrap. |
| `long` | A signed 64-bit integer, checked the same way. |
| `half` | IEEE 754 binary16, about three digits. Storage. |
| `float` | IEEE 754 binary32, about seven digits. |
| `double` | IEEE 754 binary64, about sixteen. |
| `string` | Immutable UTF-8 text. A value, not an object. |

Enums, plain structs and functions are values too, but they are not
scalars. A function value has a signature type such as
`func(long) -> long`; it copies freely and is introduced in the
[functions chapter](../functions/#functions-are-values).

**A literal has no type until it lands on one.** It is read from its
text at the width of the place it reaches, so `let x: double = 0.1` is
binary64's 0.1 and not binary32's widened. With nothing to land on,
`12` is an `int` and `1.5` is a `float`.

Number literals are decimal, hexadecimal (`0xFF`) or binary
(`0b1010`), with `_` digit separators welcome between digits
(`1_000_000`, `0xFF_FF`); a fraction or an exponent makes a float:
`1.5`, `1e10`, `1.5e-3`. There are no octal literals and no hex
floats — writing one is a `luce.lex.number` error naming the reason,
rather than a silent misreading.

## Three of them are storage, not arithmetic

`byte`, `short` and `half` are places to *keep* a number, not widths
to compute at. An operator widens them first — `byte` and `short` to
`int`, `half` to `float` — so no expression ever has one of these
types, and there are four arithmetic types rather than seven.

That is why nothing wraps. A `byte` holding 255 plus one is 256, not
zero, because the addition never had type `byte` in the first place.

```luce run
func main():
    var full: byte = 255
    print(string(full + 1))
    print(string(full * full))
```

```output
256
65025
```

What you gain by writing one down is memory. An `array(byte, n)` is
one byte an element where an `array(long, n)` is eight, and that
eightfold difference is the whole reason the narrow types exist —
image data, byte buffers, the dense numeric arrays a GPU wants.

```luce run
func main():
    var pixels = new array(byte, 4)
    pixels[0] = 255
    pixels[1] = 128
    print(string(pixels[0] + pixels[1]))
```

```output
383
```

Storing into one is the other side of the bargain: a value that does
not fit is a trap, never a truncation. `byte(300)` stops the program;
`byte(x % 256)` is how you say you meant it to wrap.

## Widening is up the ladder, and never back down

Two ladders — `byte` to `short` to `int` to `long`, and `half` to
`float` to `double` — and one rule across them: **a mixed pair meets
at `double`**, whichever way round it was written. Those conversions
are the whole of what Luce does without being asked, and they happen
wherever a value meets a type: an operator, an annotation, an
argument, a return, a field, a list element.

**Nothing narrows on its own** — not `long` into `int`, not `double`
into `float`, not `double` into `long`. A value that reached somewhere
narrower than itself is a compile error at the first place it did not
fit, naming the constructor that would put it there, and never a
silent truncation.

```luce run
func main():
    let steps = 7
    let seconds = 2.5
    print(string(steps * seconds))
    let elapsed: double = steps
    print(string(elapsed))
    print(string(long(seconds)))       # asked for, and it rounds
```

```output
17.5
7
3
```

Comparison crosses the line too — and it is **exact**. `1 < 1.5` is
`true`; so is `9007199254740993 != 9007199254740992.0`, because those
really are two different numbers even though the first does not
survive being turned into a `double`. Luce compares the numbers, not a
conversion of them.

```luce run
func main():
    let after: long = 9007199254740993
    let rounded: double = 9007199254740992.0
    print(string(1 < 1.5))
    print(string(after == rounded))
```

```output
true
false
```

## Arithmetic is checked

Integer arithmetic traps on overflow and on division by zero, at both
widths. There is no build mode in which it does not — Luce is always
what Zig would call `ReleaseSafe`.

```luce trap
func main():
    var n: long = 9223372036854775807
    print("about to add one")
    n += 1
    print(string(n))
```

```output
about to add one
loom: trap: integer overflow [integer_overflow]
    at main (main.luc:4:5)
```

## `/` divides, `//` quotients

`/` is real division and always answers a `double` — `1 / 2` is `0.5`,
not `0`. The quotient people mean when they say "integer division" is
`//`, and `%` is the modulus that pairs with it: they **floor**
together, so `%` takes the sign of the divisor and
`b * (a // b) + (a % b) == a` holds for every pair.

```luce run
func main():
    print(string(1 / 2))
    print(string(7 // 2) + " " + string(7 % 2))
    print(string(-7 // 3) + " " + string(-7 % 3))
    print(string(-1 % 256))
```

```output
0.5
3 1
-3 2
255
```

That last line is why `%` floors: a positive divisor never yields a
negative answer, so `x % 256` wraps a byte for every `x` and
`(row - 1) % height` walks a torus, without the `+ height` other
languages need.

`//` and `%` by zero are traps, because they answer a `long` and
there is no `long` that means "undefined". `/` answers a `double` and is
IEEE like every other `double` operation: `1 / 0` is `inf` and `0 / 0`
is NaN, neither of them a trap.

## let and var

`let` binds a name once; `var` allows reassignment. Neither freezes
what the name points at — `let` is JavaScript's `const`, not Swift's
`let`.

```luce fail
func main():
    let limit = 10
    limit = 11
    print(string(limit))
```

```output
luce: compile failed
main.luc:3:5: limit is let-bound; use var for reassignment [luce.sema.let]
        limit = 11
        ^~~~~
```

Two or more existing `var` names can receive one function's return
shape. The right side is evaluated and all new values are prepared
before any replacement store, so loop-carried state does not need
temporary names.

```luce run
func step(value: long, at: long) -> (long, long):
    return value + at, at + 1

func main():
    var value: long = 0
    var at: long = 0
    while at < 5:
        value, at = step(value, at)
    print(f"{value} {at}")
```

```output
10 5
```

The targets are distinct mutable bare names: fields, indexes,
compound assignment and `_` are not this form. A fallible call may be
preceded by `try` or followed by a `catch:` block; failure enters the
handler before any replacement store, while ordinary side effects of
evaluating the right side remain.

There is **no shadowing** anywhere in the language: a name declared in
an enclosing scope cannot be re-declared in an inner one. A loop
variable is immutable inside the loop body.

Compound assignment applies an operator in place — `n += 1`, `n *= 2`,
`s += "!"` — and evaluates the place exactly once, so
`counts[key] += 1` looks the key up a single time. On a map, a key
that is not there is defined at the value type's zero and then
applied to.

## Booleans and comparison

`and`, `or` and `not` short-circuit and take `bool`s only. The
comparisons are `== != < <= > >=`, and they order `long`, `double` and
`string`.

Two shapes that mean different things in different languages are
refused rather than guessed at, and both are fixed by one pair of
parentheses. `not a == b` is `luce.parse.precedence` — Python reads it
one way and C the other. `a < b < c` is `luce.parse.chain` — Python
reads it as a range test and C as two comparisons; Luce has neither
and asks for `a < b and b < c`.

```luce fail
func main():
    let a = 1
    let b = 2
    let c = 3
    print(string(a < b < c))
```

```output
luce: compile failed
main.luc:5:24: chained comparison: write 'a < b and b < c' [luce.parse.chain]
        print(string(a < b < c))
                           ^
```

## Constants at file scope

File scope declares with `const`; `let` and `var` live inside
functions. A value constant folds when the program is compiled and
inlines at every use.

```luce run
const width = 80
const half_width = width // 2
const version = "2"
const banner = "loom v" + version

func main():
    print(banner)
    print(string(half_width))
```

```output
loom v2
40
```

Constants may reference each other in any order, but never in a cycle.
Foldable forms include literals, other constants, numeric and bitwise
expressions, comparisons and logic, string concatenation, the eight
conversion constructors and `ord()`, enum members and conversions from
enums (`int(m)`, `string(m)`), typed `none`, and object-free
value-struct construction. Function values and general calls do not
fold; the conversion constructors and `ord()` are compile-time
intrinsics, not general function calls:

```luce fail
func label() -> string:
    return "loom"

const banner = label() + " v2"

func main():
    print(banner)
```

```output
luce: compile failed
main.luc:4:16: constants fold at compile time; calls are not constant [luce.sema.const]
    const banner = label() + " v2"
                   ^~~~~~~
```

A flat list, map or rank-1 array can be a constant too, under the
program root rather than a function scope. The dedicated chapter is
[constants and shared tables](../constants/).
