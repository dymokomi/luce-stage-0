# Types

Luce is statically typed with inference. Every expression has exactly
one type, fixed at compile time. An annotation is optional wherever the
initializer decides the type and required where nothing does — an empty
container literal or a `var` declared without a value.

This page is the reference for what the types are. The numeric
*semantics* — division, checked arithmetic, and the conversion
constructors — are in `docs/NUMERICS.md`; the memory model is in
`docs/MEMORY.md`.

## Value types and reference types

Every type is one of two kinds, and the kind decides what assignment
and passing do (`docs/MEMORY.md`).

A **value type** copies. Assigning it or passing it to a function makes
an independent value. The value types are the eleven numbers, `bool`,
`char`, `str`, `bytes`, a `struct`, an `enum`, a `union`, and a plain function value.
A copied value may contain references; copying it retains those fields.

A **reference type** is a shared object. Assigning it or passing it shares the
*same* object — a mutation through one name is seen through every other. The
ARC runtime frees it after the last strong reference.
The reference types implemented today are user-declared `class` types; the
containers `list[T]`, `map[K, V]`, `array[T, ...]`, and `builder`; and the
resources `file` and `task[...]`. Capturing closures use an internal ARC
environment while retaining the ordinary function-value type.

`weak` is non-owning storage for an optional ARC object reference. It is a
property of a local or field rather than a type; see [Weak storage](#weak-storage).
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

- `list[T]` — a growable sequence. `xs.append(v)`, `xs[i]`, `xs[a:b]`,
  `for x in xs:`.
- `map[K, V]` — an associative table. `m.has(k)`, `m.get(k)` (which
  answers `V?`), `m[k] = v`.
- `array[T, _, ...]` — a fixed-shape, densely packed grid. Each `_` is
  one rank; the extents are given at construction (`new array[i32](rows,
  cols)`) and indexed `grid[r, c]`. An `array` packs each element at
  that type's width.
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

## Weak storage

`weak` qualifies one mutable storage place; it does not construct a type.
The declared type must be an optional class, `list`, `map`, `array`, or
`builder`:

```luce
func main():
    weak var observed: list[i64]?
    assert(observed == none)
    if true:
        let values = [42]
        observed = values
        let snapshot = observed else [0]
        assert(snapshot[0] == 42)
    assert(observed == none)
```

A weak field has the same rule and an implicit `none` default. Assignment
does not retain the target. Reading a live weak place retains and returns an
owned `T?` snapshot; reading after final strong release returns `none`.
Generation checks prevent a freed object-table row from reviving an old weak
handle.

Weak storage cannot target a scalar, text value, value struct, interface,
function, `file`, or `task`, and cannot cross a worker boundary. A value that
contains a weak field has no synthesized equality or collection-search
semantics. `[weak name]` uses the same runtime representation for a closure
capture.

## Structs, classes, enums, unions, and interfaces

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

A `class` declares fields and methods like a structure, but its value is an ARC
reference with identity. Without `init` it uses memberwise construction; one
`init(parameters)` body may replace that surface and must establish every
field before the new identity exists. Assignment shares the object, `let`
permits object-field mutation, and `left is right` compares identity. A class
may conform to interfaces, appear in ordinary storage, and declare one
ARC-driven `deinit`. [CLASSES.md](CLASSES.md) is the complete contract.

An `enum` is a set of named constants stored at one integer width
(`docs/ENUMS.md`); members are always namespaced, an explicit integer
constructor and `str(m)` convert out, and `Suit(n)` — answering `Suit?` — is the only
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

A **function value** — `func(T, ...) -> R`, or the optional slot form
`(func(T, ...) -> R)?` — is also a value; it is covered in
`docs/FUNCTIONS.md` and `docs/BINDING.md`. A custom-initialized class may hold
a required bare function field because the object is created only after that
field is present.

## The names the language answers to

The builtin type names are **lowercase**: `bool`; `u8`, `u16`, `u32`,
`u64`; `i8`, `i16`, `i32`, `i64`; `f16`, `f32`, `f64`; `char`, `str`,
`bytes`; the containers `list`, `map`, `array`, `builder`; and the resources
`file` and `task`.
A name you declare — a type alias, struct, class, enum, union, or interface —
is TitleCase by convention, so the case of a type name says who defined it.

Parentheses in a type are grouping: `(T)` is `T`, accepted wherever a
type may stand and required nowhere. `i64?` and `(i64)?` are the same
type. The one place the grouping is load-bearing is the storable
function value: a bare `func(i64) -> str?` is a function *answering*
a `str?`, so "a function that may be absent" is written
`(func(i64) -> str)?`.

## Transparent aliases

`alias Name = Type` creates another source name for exactly the resolved
target type. It does not create another numeric type, a wrapper, a distinct
nominal identity, or a runtime representation.

An alias may stand anywhere its target type can stand and may use the target's
construction and member namespace. For example, an alias of a structure may
construct it, an alias of an enum may name its members, and an alias of a list
may follow `new`. Chains and forward references resolve eagerly; cycles and
unknown targets are rejected even when unused. [ALIASES.md](ALIASES.md)
specifies visibility, privacy, construction, diagnostics, and compiler
erasure.

## Conversions

Every numeric type has a conversion constructor named for it — `u8(x)`,
`u16(x)`, `u32(x)`, `u64(x)`, `i8(x)`, `i16(x)`, `i32(x)`, `i64(x)`,
`f16(x)`, `f32(x)`, and `f64(x)` — and `str(x)` converts a number,
`bool`, enum member, union member, or
function value to text. What each one rounds, and when it traps, is in
`docs/NUMERICS.md`.
