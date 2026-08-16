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

## Numeric types

There are eight fixed-width integers and three IEEE floating-point types.
Every one is a real arithmetic type; no value promotes implicitly.

| Type | Bits | Kind | Range | Role |
|---|---:|---|---|---|
| `u8` | 8 | unsigned integer | 0 … 255 | arithmetic and storage |
| `u16` | 16 | unsigned integer | 0 … 65 535 | arithmetic and storage |
| `u32` | 32 | unsigned integer | 0 … 2³²−1 | arithmetic and storage |
| `u64` | 64 | unsigned integer | 0 … 2⁶⁴−1 | arithmetic and storage |
| `i8` | 8 | signed integer | −128 … 127 | arithmetic and storage |
| `i16` | 16 | signed integer | −32 768 … 32 767 | arithmetic and storage |
| `i32` | 32 | signed integer | −2³¹ … 2³¹−1 | arithmetic and storage |
| `i64` | 64 | signed integer | −2⁶³ … 2⁶³−1 | arithmetic; default integer |
| `f16` | 16 | IEEE binary16 | finite through ±65 504 | arithmetic and storage |
| `f32` | 32 | IEEE binary32 | about 7 decimal digits | arithmetic and storage |
| `f64` | 64 | IEEE binary64 | about 16 decimal digits | arithmetic; default float |

The integer types are **checked** — an operation whose result does not fit traps
`integer_overflow` rather than wrapping (`docs/NUMERICS.md`). The three
floats follow IEEE 754 and do not trap; they reach `inf` and `NaN`
instead.

Every numeric type computes at its own width. This keeps an annotation,
parameter, field, and array element honest about both storage and arithmetic.

```luce
func main():
    var a: u8 = 255
    var b: u8 = 1
    print(str(a + b))     # traps integer_overflow at u8

    let pixels = new array[u8](3)
    pixels[0] = 200          # 200 fits a u8
    print(str(pixels[0]))
```

An out-of-range literal is rejected at compile time. A runtime conversion
such as `u8(wide)` traps `conversion_range` when the value does not fit.

## Explicit representation changes

Concrete numeric types never widen or narrow implicitly. Literals take a
type from context; values cross a representation boundary through a
constructor named for the destination.

```luce
func main():
    let n: i32 = 100
    let wide: i64 = i64(n)
    let d: f64 = f64(n)
    let f: f32 = 1         # a literal lands on f32 directly
    print(str(wide) + " " + str(d) + " " + str(f))
```

This rule applies to assignment, calls, returns, comparisons, operators,
and container stores (`docs/NUMERICS.md`).

```luce refused
func main():
    let wide: i64 = 5
    let narrow: i32 = wide   # representation changes are never implicit
    print(str(narrow))
```

## `bool`, `char`, `str`, and `bytes`

`bool` is `true` or `false`, and is the only type a condition may have —
there is no truthiness, and no numeric type is a `bool`.

`char` is one Unicode scalar. `str` is immutable valid UTF-8 whose length,
indexing, slicing, and iteration use scalar positions. `bytes` is immutable
binary data whose element is `u8`. Raw text bytes remain available through
`byte_at` and `find_byte`; richer text operations live in `std.strings`.

## Optionals: `T?`

`T?` is a `T` that may be absent. Its one absent value is `none`, and
there is exactly one level of absence: `T??` cannot be written and
`none?` does not exist. An optional is not the type it wraps, so a `T?`
must be narrowed to a `T` before the `T`'s operations apply — test it
(`if x != none:`) or supply a fallback (`… else …`).

```luce fragment
let totals = {"a": 1}
let value = totals.get("b") else 0   # a T, whatever get answered
print(str(value))
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
let xs = new list[i64]
xs.append(10)
xs.append(20)
let totals = {"a": 1, "b": 2}
print(str(xs[0] + (totals.get("a") else 0)))
```

Sharing a struct that holds a container shares the container: the
reference is what copies, and both struct values see the one object.

## Structs, enums, unions, and interfaces

A `struct` is a value aggregate of named, typed fields, built by naming
each field:

```luce
struct Point:
    x: f64
    y: f64

func main():
    let p = Point(x = 1.0, y = 2.0)
    print(str(p.x))
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
    print(str(s))         # hearts
    print(str(i32(s)))    # 0
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
