# Types

Luce is statically typed with inference. Every expression has exactly
one type, fixed at compile time. An annotation is optional wherever the
initializer decides the type and required where nothing does — an empty
container literal, or a `var` declared without a value.

This page is the reference for what the types are. The numeric
*semantics* — division, checked arithmetic, and the conversion
constructors — are in `docs/NUMERICS.md`; the memory model is in
`docs/MEMORY.md`.

## Value types and reference types

Every type is one of two kinds, and the kind decides what assignment
and passing do (`docs/MEMORY.md`).

A **value type** copies. Assigning it or passing it to a function makes
an independent value. The value types are the seven numbers, `bool`,
`string`, a `struct`, an `enum`, a `union`, and a plain function value.
A copied value may contain references; copying it retains those fields.

A **reference type** is a shared object. Assigning it or passing it shares the
*same* object — a mutation through one name is seen through every other. The
ARC runtime frees it after the last strong reference.
The reference types implemented today are the containers `list(T)`,
`map(K, V)`, `array(T, ...)`, and `builder`, together with the resources
`file` and `task(...)`.

User-defined reference types are not complete. `class` is accepted as a
front-end scaffold but still lowers with value-struct behavior; `weak` is
not syntax. Do not use either as if the target semantics had shipped.
[ROADMAP.md](ROADMAP.md) specifies their destination and acceptance tests.
[MEMORY.md](MEMORY.md) is the source of truth for current behavior.

## The numeric ladder

There are seven numeric types on two ladders — four integers and three
floats — sized the way Java, C, C# and every GPU API size them.

| Type | Bits | Kind | Range | Role |
|---|---:|---|---|---|
| `byte` | 8 | unsigned integer | 0 … 255 | storage |
| `short` | 16 | signed integer | −32 768 … 32 767 | storage |
| `int` | 32 | signed integer | ±2.147 × 10⁹ | arithmetic; the default for an integer literal |
| `long` | 64 | signed integer | ±9.223 × 10¹⁸ | arithmetic |
| `half` | 16 | binary16 float | ±65 504, ~3 digits | storage |
| `float` | 32 | binary32 float | ±3.4 × 10³⁸, ~7 digits | arithmetic; the default for a float literal |
| `double` | 64 | binary64 float | ±1.8 × 10³⁰⁸, ~16 digits | arithmetic |

`byte` is the only unsigned numeric type, and the only one there is:
`short`, `int` and `long` are signed. The four integer types are
**checked** — an operation whose result does not fit traps
`integer_overflow` rather than wrapping (`docs/NUMERICS.md`). The three
floats follow IEEE 754 and do not trap; they reach `inf` and `NaN`
instead.

## Storage types and arithmetic types

Three of the seven — `byte`, `short` and `half` — are **storage types**.
No expression ever *has* one of them: an operator widens `byte` and
`short` to `int`, and `half` to `float`, before it does anything. So
there are four arithmetic types, not seven, and there is no checked
arithmetic at 8 or 16 bits and no binary16 arithmetic on any machine.

A storage type is what an annotation, a parameter, a struct field, and
above all an array element may say. What they are for is `array(byte, _)`
at one byte an element — an eighth of what the same array of `long`
costs, and the same vector register holding four `float`s where it held
two `double`s.

```luce
func main():
    var a: byte = 255
    var b: byte = 1
    print(string(a + b))     # 256 — the int value, not a wrap

    let pixels = new array(byte, 3)
    pixels[0] = 200          # 200 fits a byte
    print(string(pixels[0]))
```

Storing a value back into a storage type is a checked narrowing:
`pixels[0] = 300` traps `conversion_range`, because 300 is not a `byte`.

## Implicit widening

A value widens **upward on its own ladder** with nothing written down:

- `byte` → `short`, `int`, `long`
- `short` → `int`, `long`
- `int` → `long`
- `half` → `float`

**Across the two ladders the target is always `double`**: `int` and
`long` widen to `double` (an `int` exactly, a `long` exactly below
2⁵³), and `half` and `float` widen to `double`. There is no implicit
`int` → `float`, because a 32-bit float cannot hold every 32-bit
integer; a program that wants one writes `float(x)`.

```luce
func main():
    let n: int = 100
    let wide: long = n       # int widens to long
    let d: double = n        # and to double
    let f: float = 1         # a literal lands on float directly
    print(string(wide + d + f))
```

**Narrowing is never implicit** — not `long` into `int`, not `double`
into `float`, not `int` into `byte`, and not at a store, an argument, or
a return. It is always spelled with a conversion constructor named for
its target (`docs/NUMERICS.md`).

```luce refused
func main():
    let wide: long = 5
    let narrow: int = wide   # narrowing is never implicit
    print(string(narrow))
```

## `bool` and `string`

`bool` is `true` or `false`, and is the only type a condition may have —
there is no truthiness, and no numeric type is a `bool`.

`string` is an immutable UTF-8 value. It copies like any value type,
compares with `==` and `<`, concatenates with `+`, and supports slicing
`s[a:b]`, `len(s)`, and byte access; the richer operations live in
`std.strings`. Because it is a value, sharing a `string` never shares
mutable state.

## Optionals: `T?`

`T?` is a `T` that may be absent. Its one absent value is `none`, and
there is exactly one level of absence: `T??` cannot be written and
`none?` does not exist. An optional is not the type it wraps, so a `T?`
must be narrowed to a `T` before the `T`'s operations apply — test it
(`if x != none:`) or supply a fallback (`… else …`).

```luce fragment
let totals = {"a": 1}
let value = totals.get("b") else 0   # a T, whatever get answered
print(string(value))
```

`T?` is the widening every value type has: a `T` reaches a `T?` place
implicitly, which is why `T <: T?` is the language's one subtyping
relation.

## Containers

The four containers are reference types, created with `new` or a
literal, and parameterized by their element types:

- `list(T)` — a growable sequence. `xs.append(v)`, `xs[i]`, `xs[a:b]`,
  `for x in xs:`.
- `map(K, V)` — an associative table. `m.has(k)`, `m.get(k)` (which
  answers `V?`), `m[k] = v`.
- `array(T, _, ...)` — a fixed-shape, densely packed grid. Each `_` is
  one rank; the extents are given at construction (`new array(int, rows,
  cols)`) and indexed `grid[r, c]`. An `array` of a storage type packs
  at that type's width.
- `builder` — an append-only text buffer, finished with `b.build()`.

```luce fragment
let xs = new list(int)
xs.append(10)
xs.append(20)
let totals = {"a": 1, "b": 2}
print(string(xs[0] + (totals.get("a") else 0)))
```

Sharing a struct that holds a container shares the container: the
reference is what copies, and both struct values see the one object.

## Structs, enums, unions, and interfaces

A `struct` is a value aggregate of named, typed fields, built by naming
each field:

```luce
struct Point:
    x: double
    y: double

func main():
    let p = Point(x = 1.0, y = 2.0)
    print(string(p.x))
```

An `enum` is a set of named constants stored at one integer width
(`docs/ENUMS.md`); members are always namespaced, `int(m)` and
`string(m)` convert out, and `Suit(n)` — answering `Suit?` — is the only
way in.

```luce
enum Suit:
    hearts
    spades

func main():
    let s = Suit.hearts
    print(string(s))         # hearts
    print(string(int(s)))    # 0
```

A `union` is a tagged choice whose members may carry payload fields, and
`match` is the only way to read one (`docs/UNION.md`). Enums and unions
are value types.

A **function value** — `func(T, ...) -> R`, or the storable form
`(func(T, ...) -> R)?` — is also a value; it is covered in
`docs/FUNCTIONS.md` and `docs/BINDING.md`.

## The names the language answers to

The builtin type names are **lowercase**: `byte`, `short`, `int`,
`long`, `half`, `float`, `double`, `bool`, `string`, and the containers
`list`, `map`, `array`, `builder`, plus the resources `file` and `task`.
A name you declare — a type alias, struct, enum, union, or interface — is TitleCase
by convention, so the case of a type name says who defined it. `class`
will join that set only when its reference lowering is complete.

Parentheses in a type are grouping: `(T)` is `T`, accepted wherever a
type may stand and required nowhere. `long?` and `(long)?` are the same
type. The one place the grouping is load-bearing is the storable
function value: a bare `func(long) -> string?` is a function *answering*
a `string?`, so "a function that may be absent" is written
`(func(long) -> string)?`.

## Transparent aliases

`alias Name = Type` creates another source name for exactly the resolved
target type. It does not create an eighth numeric type, a wrapper, a distinct
nominal identity, or a runtime representation.

An alias may stand anywhere its target type can stand and may use the target's
construction and member namespace. For example, an alias of a structure may
construct it, an alias of an enum may name its members, and an alias of a list
may follow `new`. Chains and forward references resolve eagerly; cycles and
unknown targets are rejected even when unused. [ALIASES.md](ALIASES.md)
specifies visibility, privacy, construction, diagnostics, and compiler
erasure.

## Conversions

Every numeric type has a conversion constructor named for it — `byte(x)`,
`short(x)`, `int(x)`, `long(x)`, `half(x)`, `float(x)`, `double(x)` —
and `string(x)` converts a number, `bool`, enum member, union member, or
function value to text. What each one rounds, and when it traps, is in
`docs/NUMERICS.md`.
