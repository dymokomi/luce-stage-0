# Types

Luce is statically typed with inference. Every expression has exactly
one type, known at compile time. Widening is implicit along each
numeric ladder and, across the two, only into `double`. **Nothing
narrows implicitly** — not in any direction and not in any context.

An annotation is optional wherever the initializer decides the type,
and required where nothing does — an empty list literal, a `var` with
no value.

## Values and objects

The line between them decides everything about memory.

**Values** copy on assignment and on call, and nobody frees them: the
seven numbers, `bool`, `string`, and `struct`s. A value never takes an
ownership word.

**Heap objects** are referenced, created with `new` or a literal, and
freed by scope ownership: `list(T)`, `map(K, V)`, `array(T, ...)`,
`builder`. Copying a struct that contains a list copies the
*reference* — both structs see the same list.

## Scalars

| Type | Definition |
|---|---|
| `bool` | `true` or `false`. The only type a condition may have. |
| `byte` | Unsigned 8-bit, 0 … 255. **Storage.** |
| `short` | Signed 16-bit, −32 768 … 32 767. **Storage.** |
| `int` | Signed 32-bit, **checked**: overflow traps. The default for an integer literal. |
| `long` | Signed 64-bit, **checked**: overflow traps. |
| `half` | IEEE 754 binary16, ±65 504. **Storage.** |
| `float` | IEEE 754 binary32. Does not trap. The default for a float literal. |
| `double` | IEEE 754 binary64. Does not trap. |
| `string` | Immutable UTF-8. A value. |

`byte` is the one unsigned type there is and the only one there will
be: a byte is 0 … 255 in files, sockets, images and UTF-8 alike, and
that is the one domain where the answer is unanimous.

## Storage and arithmetic

Three of the seven — `byte`, `short` and `half` — are **storage
types**. They are what an annotation, a parameter, a struct field and
above all an array element may say, and an operator widens them before
it does anything: `byte` and `short` compute at `int`, `half` at
`float`. So there are four arithmetic types and not seven, no checked
arithmetic at 8 or 16 bits, and no binary16 arithmetic on any machine.

Nothing wraps. `byte` 255 plus 1 is 256, an `int`, because the
addition never had type `byte` to overflow.

```luce run
func main():
    var a: byte = 255
    var b: byte = 1
    print(string(a + b))
    var h: half = 0.5
    print(string(h + h))
```

```output
256
1
```

What they are *for* is `array(byte, n)` at one byte an element — an
eighth of what the same array of `long` costs, and the same vector
register holding four `float`s where it held two `double`s.

## Promotion

Along a ladder, every rung reaches every rung above it, exactly:
`byte` → `short` → `int` → `long`, and `half` → `float` → `double`.
Across the two ladders the answer is always `double`, which is exact
for every integer but `long` and, for `long`, exact below 2^53 — the
language's one lossy implicit conversion.

`int` does **not** widen to `float`. It would fit, but the rule is
that there is one cross-family answer rather than a rule about which
values happen to fit — and Java's `int → float`, which loses
everything above 2^24, is the widening this declines to grow.

`/` is real division and always answers a float. `//` is floor
division and `%` the modulus that pairs with it — both answer the
promoted integer type, both floor, so `%` takes the sign of the
divisor, and both trap on a zero divisor. `/` does not trap:
`1 / 0` is `inf`.

Comparison across the ladders does **not** widen — it is exact, so
`9007199254740993 == 9007199254740992.0` is `false`, which widening
would get wrong.

## Conversions

Each conversion is named for the type it produces: `byte(x)`,
`short(x)`, `int(x)`, `long(x)`, `half(x)`, `float(x)`, `double(x)`,
and `string(x)`. One rule per family, not one per pair:

- **Float to integer** rounds half away from zero and **traps**
  `conversion_range` outside the target — NaN and the infinities
  included.
- **Integer to an integer that cannot hold it** traps the same way:
  `byte(300)` is not 44, it is a program that stops.
- **Integer to float** never traps.
- **Float to a narrower float** rounds to nearest, ties to even, and
  reaches `inf` rather than trapping, because `/` is already IEEE
  without traps and the language does not keep a second story about
  infinity.

A widening constructor never traps and is redundant with promotion,
but it stays: it is how you widen where there is no operator to hang
it on.

```luce trap
func main():
    var over: long = 300
    print(string(byte(over)))
```

```output
loom: trap: conversion out of range [conversion_range]
    at main (main.luc:3:5)
```

`string(x)` prints a number with the shortest text that round-trips
**at its own width**, so the width is visible in the answer:

```luce run
func main():
    print(string(1.0 / 3.0))
    print(string(double(1.0) / double(3.0)))
    print(string(half(65504.0)))
```

```output
0.33333334
0.3333333333333333
65500
```

The last line is not a rounding mistake. 65504 is the largest finite
binary16, and no other binary16 lies nearer to 65500 — so four digits
name it exactly, and reading them back gives 65504.

## struct

A named product of fields. Fields are annotated; construction names
its fields — every one without a default; assignment copies.

```luce run
struct Point:
    x: double
    y: double

func main():
    let p = Point(x = 1.5, y = 2.5)
    var q = p                       # a copy
    q.x = 9.0
    print(f"{p.x} {q.x}")
```

```output
1.5 9
```

A field may declare a trailing **default**, the same clause a
parameter takes: a compile-time constant the construction site may
omit. Defaults come last, and a struct every one of whose fields has
one constructs bare.

```luce run
struct Options:
    depth: long = 3
    wide: bool = false

func main():
    let plain = Options()
    let tuned = Options(depth = 9)
    print(f"{plain.depth} {plain.wide} {tuned.depth}")
```

```output
3 false 9
```

A struct may declare functions in its own namespace. They are plain
functions reached as `Struct.name(...)` — no receiver, no dispatch, no
inheritance.

A struct type is **object-carrying** if it transitively contains a
field of object type. Object-carrying structs follow the object
ownership rules when they are *kept*; plain-value structs never do.

Struct definitions may not be cyclic through plain fields. Recursion
goes through an optional field:

```luce run
struct Node:
    value: long
    next: Node?

func main():
    let tail = Node(value = 2, next = none)
    let head = Node(value = 1, next = tail)
    let second = head.next            # bind the field, then test the name
    if second != none:
        print(f"{head.value} then {second.value}")
```

```output
1 then 2
```

Narrowing applies to locals and parameters, never to a field — which
could change between the test and the use — so the field is bound to a
name first.

The cycle rule is one scale of a single rule: **a struct's
unconditional size must be finite, and small.** A plain field's
payload is part of what the struct is, so it is counted through — a
struct of two struct fields doubles per level — and past 4096 values
the declaration is refused, just as an infinite one is. An optional
field counts as one whatever it holds, because its payload starts
absent and arrives only when a program builds one. So `?` answers both
refusals, and so does a container: a `list`, `map` or `array` is one
reference however much it holds.

## list(T)

A growable sequence. Created with a literal or `new list(T)`. An empty
literal requires an annotated binding.

`T` may be any value type or any object type. When `T` is an object
type the list **owns** its elements.

## map(K, V)

An insertion-ordered dictionary. `K` is `long` or `string`; `V` is any
type other than an optional. Index get, index set, `has` and `get`
are O(1): the entries stay a dense array in arrival order with a hash
index over it. Iteration is in insertion order.

## array(T, ...)

Fixed shape, one to four dimensions, sizes given as runtime values at
`new`. Elements begin at the type's zero value: `0`, `0.0`, `false`,
`""`, a field-by-field zeroed struct, or — for object element types —
the null object, which traps on use until something is stored.

In a type annotation the shape is spelled with `_` for each axis:
`array(long, _, _)`.

`array(double, _)` is the numeric vector type `std.math`'s whole-array
operations take.

## builder

Accumulates text. `string(builder)` hands back the `string`.

## Return shapes {#return-shapes}

`(long, long)` after a function's `->` says it answers two values.

**It is not a type.** It is a shape a *signature* has, and it may be
written nowhere else: not on a binding, not on a parameter, not on a
struct field, not inside a `list`, not nested inside another shape,
and not with a `?` (which would be marking the shape rather than a
value). There is no expression that produces one.

```luce fail
func main():
    let p: (long, long) = 1
```

```output
luce: compile failed
main.luc:2:12: a return shape is not a type: a pair that travels together is a struct [luce.parse.type]
        let p: (long, long) = 1
               ^
```

A pair that travels together is a struct. A pair that only ever
travels *outward* — never a parameter, never a field, never a
container element, only ever read one value at a time — is a return
shape, and the question is greppable rather than a matter of taste.

Every element is an ordinary type, so `-> (long?, bool)` is fine, and
`-> (A, B)!` composes with `try` like any other fallible signature.

## Optionals: `T?`

A trailing `?` makes a type nullable. `none` is the absent value, and
it is legal only where a `T?` is expected — a plain type can never
hold it.

`T?` may be:

- a local variable
- a parameter
- a return type
- a struct field

`T?` may **not** be a container element type or a map value type, and
there is no `T??` — one `?` is all there is.

Absence owns nothing: a `list(T)?` holding an object owns it exactly
as a `list(T)` would, and holding `none` owns nothing.

Narrowing is described in [expressions](../expressions/#narrowing).

## Fallibility: `-> T!`

A trailing `!` on a **return type** says the function may raise an
error. `-> !` means it returns nothing or an error.

**`T!` is not a type.** Fallibility is an attribute of the function.
There is no `T!` to declare a variable of, to use as a container
element, or to write in a struct field, and `return x` in a `-> T!`
function returns `x` with nothing wrapped around it.

```luce fail
struct Holder:
    value: long!

func main():
    print("unreachable")
```

```output
luce: compile failed
main.luc:2:16: expected end of line after the field, found '!' [luce.parse.expected]
        value: long!
                   ^
```

## Zero values and late initialization

`var name: Type` with no initializer declares the binding, its type
and its scope. The slot holds the type's zero value until it is
assigned. For an object type that is the null object, and using it
traps `null_object`.

`let` always requires an initializer: a name that can never be
reassigned and holds nothing is a contradiction.

This is zero-initialization, not nullability. A slot that may
genuinely hold nothing is a `T?` and says so.

## Identity

`==` and `!=` on objects compare identity — whether two names denote
the same object — never contents.
