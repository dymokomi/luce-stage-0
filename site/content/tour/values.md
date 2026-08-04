# Values and types

Every expression in Luce has one type, known when the program is
compiled. Annotations are optional wherever the initializer decides
the answer: `let n = 1` is an `Int`, and `let n: Int = 1` says so out
loud.

```luce run
func main():
    let count = 7                 # Int
    let ratio: Float = 0.5        # said out loud
    let ready = true              # Bool
    let name = "loom"             # String
    print(f"{count} {ratio} {ready} {name}")
```

```output
7 0.5 true loom
```

## The scalar types

| Type | What it is |
|---|---|
| `Bool` | `true` or `false`. No truthiness: nothing else is a condition. |
| `Int` | A signed 64-bit integer, **checked**: overflow is a trap, not a wrap. |
| `Float` | IEEE 754 double precision. |
| `String` | Immutable UTF-8 text. A value, not an object. |

Number literals are decimal. A fraction or an exponent makes a
`Float`: `12` is an `Int`, `1.5` and `1e10` and `1.5e-3` are `Float`s.
There are no hexadecimal, binary or octal literals and no `_` digit
separators — writing one is a `luce.lex.number` error naming the
reason, rather than a silent misreading.

## `Int` widens to `Float`, and never the other way

Mix an `Int` and a `Float` and the `Int` widens: the answer is a
`Float`, wherever the two meet — an operator, an annotation, an
argument, a return, a field, a list element. It is the one conversion
Luce makes without being asked, and it goes in one direction only.
Nothing narrows a `Float` to an `Int` on its own, so a `Float` that
wandered somewhere it should not be is a compile error at the first
place an `Int` is required, not a silent truncation.

```luce run
func main():
    let steps = 7
    let seconds = 2.5
    print(String(steps * seconds))
    let elapsed: Float = steps
    print(String(elapsed))
    print(String(Int(seconds)))       # asked for, and it rounds
```

```output
17.5
7
3
```

Comparison crosses the line too — and it is **exact**. `1 < 1.5` is
`true`; so is `9007199254740993 != 9007199254740992.0`, because those
really are two different numbers even though the first does not
survive being turned into a `Float`. Luce compares the numbers, not a
conversion of them.

```luce run
func main():
    print(String(1 < 1.5))
    print(String(9007199254740993 == 9007199254740992.0))
```

```output
true
false
```

## Arithmetic is checked

`Int` arithmetic traps on overflow and on division by zero. There is
no build mode in which it does not — Luce is always what Zig would
call `ReleaseSafe`.

```luce trap
func main():
    var n = 9223372036854775807
    print("about to add one")
    n += 1
    print(String(n))
```

```output
about to add one
loom: trap: integer overflow [integer_overflow]
    at main (main.luc:4:5)
```

## `/` divides, `//` quotients

`/` is real division and always answers a `Float` — `1 / 2` is `0.5`,
not `0`. The quotient people mean when they say "integer division" is
`//`, and `%` is the modulus that pairs with it: they **floor**
together, so `%` takes the sign of the divisor and
`b * (a // b) + (a % b) == a` holds for every pair.

```luce run
func main():
    print(String(1 / 2))
    print(String(7 // 2) + " " + String(7 % 2))
    print(String(-7 // 3) + " " + String(-7 % 3))
    print(String(-1 % 256))
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

`//` and `%` by zero are traps, because they answer an `Int` and
there is no `Int` that means "undefined". `/` answers a `Float` and is
IEEE like every other `Float` operation: `1 / 0` is `inf` and `0 / 0`
is NaN, neither of them a trap.

## let and var

`let` binds a name once; `var` allows reassignment. Neither freezes
what the name points at — `let` is JavaScript's `const`, not Swift's
`let`.

```luce fail
func main():
    let limit = 10
    limit = 11
    print(String(limit))
```

```output
luce: compile failed
main.luc:3:5: limit is let-bound; use var for reassignment [luce.sema.let]
        limit = 11
        ^~~~~
```

There is **no shadowing** anywhere in the language: a name declared in
an enclosing scope cannot be re-declared in an inner one. A loop
variable is immutable inside the loop body.

Compound assignment applies an operator in place — `n += 1`, `n *= 2`,
`s += "!"` — and evaluates the place exactly once, so
`counts[key] += 1` looks the key up a single time.

## Booleans and comparison

`and`, `or` and `not` short-circuit and take `Bool`s only. The
comparisons are `== != < <= > >=`, and they order `Int`, `Float` and
`String`.

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
    print(String(a < b < c))
```

```output
luce: compile failed
main.luc:5:24: chained comparison: write 'a < b and b < c' [luce.parse.chain]
        print(String(a < b < c))
                           ^
```

## Constants at file scope

A top-level `let` is a compile-time constant. It folds when the
program is compiled and inlines at every use, so an unused constant
costs nothing to ship.

```luce run
let width = 80
let half = width // 2
let version = "2"
let banner = "loom v" + version

func main():
    print(banner)
    print(String(half))
```

```output
loom v2
40
```

Constants may reference each other in any order, but never in a cycle.
What may be folded is literals, other constants, arithmetic,
comparisons, `and`/`or`, string concatenation, the three conversion
constructors `Int()`, `Float()` and `String()`, and value-struct
construction. **Calls are not constant**, and neither are heap
objects, because a top-level binding has no scope to die at and
therefore cannot own one:

```luce fail
func label() -> String:
    return "loom"

let banner = label() + " v2"

func main():
    print(banner)
```

```output
luce: compile failed
main.luc:4:14: constants fold at compile time; calls are not constant [luce.sema.const]
    let banner = label() + " v2"
                 ^~~~~~~
```

There is no top-level `var`.
