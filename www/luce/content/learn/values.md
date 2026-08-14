# Values and types

Every expression has one statically known type. You can annotate a value
or let its context infer the type. An unannotated integer literal defaults
to `int`; an unannotated fractional literal defaults to `float`.

```luce run
func main():
    let count = 7                 # int
    let ratio: double = 0.5
    let ready = true              # bool
    let name = "loom"             # string
    print(f"{count} {ratio} {ready} {name}")
```

```output
7 0.5 true loom
```

## The scalar types

| Type | Meaning |
|---|---|
| `bool` | `true` or `false`; only a `bool` can be a condition. |
| `byte` | Unsigned 8-bit storage. |
| `short` | Signed 16-bit storage. |
| `int` | Checked signed 32-bit integer. |
| `long` | Checked signed 64-bit integer. |
| `half` | IEEE binary16 storage. |
| `float` | IEEE binary32. |
| `double` | IEEE binary64. |
| `string` | Immutable UTF-8 text. |

Enums, structs and functions are values too. A function value has a type
such as `func(long) -> long` and is covered in [Functions and structs](../functions/).

Literals may be decimal, hexadecimal (`0xFF`) or binary (`0b1010`), with
underscores between digits. A fraction or exponent makes a floating-point
literal. Octal and hexadecimal floating-point literals are not accepted.

## Storage types

`byte`, `short` and `half` describe storage, not arithmetic. Operations
widen them to `int` or `float` first. Integer arithmetic is checked, so a
value does not wrap merely because it was stored in a narrow type.

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

Narrow arrays are useful when storage size matters:

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

Storing a value outside the destination range traps. Use an explicit
conversion, such as `byte(x % 256)`, when wrapping is intended.

## Numeric widening

The integer ladder is `byte` → `short` → `int` → `long`. The floating
ladder is `half` → `float` → `double`. Widening is implicit in the forward
direction. A value is never narrowed implicitly. When an integer and a
floating value meet, the common type is `double`.

```luce run
func main():
    let steps = 7
    let seconds = 2.5
    print(string(steps * seconds))
    let elapsed: double = steps
    print(string(elapsed))
    print(string(long(seconds)))
```

```output
17.5
7
3
```

Comparisons across numeric types preserve the exact values being compared:

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

## Checked arithmetic and division

Integer overflow, integer division by zero, and integer remainder by zero
are traps in every build mode. Floating-point division follows IEEE
semantics.

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

`/` is real division and returns `double`. `//` is floor division and `%`
is its matching remainder:

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

## Bindings

`let` prevents reassignment of a name. `var` permits it. Neither keyword
changes whether a referenced object is mutable.

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

Multiple mutable names can receive a function's multiple return values:

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

There is no shadowing. Compound assignment evaluates its target once;
`counts[key] += 1` is the map-counting form.

## Conditions and comparisons

`and`, `or` and `not` require `bool` and short-circuit. Equality and order
comparisons support the documented scalar types; they do not turn other
values into conditions. Chained comparisons are refused so that the
parentheses of a compound condition are explicit:

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

## File-scope constants

Use `const` at file scope. Foldable expressions are evaluated when the
program is compiled; function calls and function values do not fold.

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

Constants may refer to other constants in any order but cannot form a
cycle. Flat lists, maps and rank-one arrays are also possible; see
[Constants and shared tables](../constants/).

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

Next: [Control flow](../control/).
