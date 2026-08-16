# The explicit type migration

This is the target contract for Roadmap phases 2 and 3. It is a plan until
the atomic migration is complete; current spellings and behavior remain in
[TYPES.md](TYPES.md), [NUMERICS.md](NUMERICS.md), [STRINGS.md](STRINGS.md),
and [BYTES.md](BYTES.md).

The migration has one purpose: a type name should tell the reader what a
value is without requiring a table of platform assumptions. The resulting
system borrows three proven ideas from Swift: literals take their type from
context, fixed-width numeric values do not implicitly convert into one
another, and ordinary integer arithmetic is checked. Luce keeps its own
smaller surface and Python-shaped division.

## 1. The vocabulary

The complete core vocabulary is:

```text
bool

u8  u16  u32  u64
i8  i16  i32  i64
f16 f32  f64

char
str
bytes

list[T]
map[K, V]
array[T, _, ...]
func(T, ...) -> R
T?
```

The integer and float names state their representation. There is no
platform-sized integer and no type whose width changes with the machine.
`f8` is absent because that name does not identify a floating-point format;
an eventual eight-bit float would say which format it uses. `none` is the
absence value of `T?`, not a type.

`struct`, `class`, `enum`, `union`, and `interface` introduce nominal types.
`alias` introduces another source name for an existing type and no new
identity. Opaque resources such as `file`, `task`, `Window`, and `Surface`
belong to libraries or the runtime boundary rather than the scalar set.

These spellings disappear in the same change:

| Retired | Replacement |
|---|---|
| `byte` | `u8` |
| `short` | `i16` |
| `int` | `i32` |
| `long` | `i64` |
| `half` | `f16` |
| `float` | `f32` |
| `double` | `f64` |
| `string` | `str` |

There is no compatibility-alias period. This repository is pre-release, and
two public names for every primitive would make examples, diagnostics, and
search results ambiguous. A retired spelling is refused with its exact
replacement.

## 2. Literals are contextual

An integer literal has arbitrary precision while it is being checked. It
lands directly in the integer type required by its annotation, argument,
return, field, container element, or concrete numeric operand, provided its
value fits. With no such context it becomes `i64`.

```text
let small: u8 = 255
let count = 42                 # i64
let wide: u64 = 18446744073709551615
let shifted = wide << 8        # 8 is checked as wide's operand context
```

An out-of-range literal is a compile-time error at the literal. It is never
truncated and never deferred to a runtime trap.

A leading minus and its integer literal are checked as one signed literal for
context. This is what makes the minimum values (`-128: i8`,
`-9223372036854775808: i64`) expressible even though their positive
magnitudes do not fit the same signed type. A negative literal cannot inhabit
an unsigned context.

A floating literal similarly lands on `f16`, `f32`, or `f64` from context
and otherwise becomes `f64`. Rounding to a requested float format happens at
compile time with round-to-nearest, ties-to-even. A finite literal that rounds
to infinity is accepted for a float type, matching runtime float conversion.

Context does not flow through an already typed name or call. In `x + 1`, the
literal can become `x`'s numeric type. In `x + y`, two concrete values must
already have the same type.

Expected type flows through a whole literal-only expression. Thus
`let mask: u8 = 1 << 7` computes as `u8`; without the annotation it computes
as `i64`. A literal-only list, map, or array element set uses its container's
expected type or defaults integer elements to `i64` and floating elements to
`f64`. A concrete element fixes later literals, while two differently typed
concrete elements are rejected rather than unified.

## 3. Integers

Every integer type is a real arithmetic type. There are no storage-only
integers and no promotion to a preferred arithmetic width.

- `+`, `-`, `*`, and unary `-` are checked at the operand's own width.
- Overflow traps `integer_overflow`; it never wraps and is never undefined.
- Unary `-` accepts only signed integers. Negating a signed minimum traps.
- `//` is floor division and `%` is its paired remainder. Both return the
  operand type, trap `divide_by_zero`, and preserve
  `b * (a // b) + (a % b) == a`. Unsigned floor division is ordinary
  quotient/remainder.
- Signed minimum divided by `-1` traps `integer_overflow`.
- `&`, `|`, `^`, and `~` operate on every integer type and preserve it.
- `<<` and `>>` preserve the left type. A shift count may be any integer
  value; a negative count or one at least the left width traps `shift_range`.
  Left shift is checked arithmetic rather than a wrapping bit discard.
- Comparisons require one concrete integer type and answer `bool`.

Two concrete integer operands of different widths or signedness are a type
error. A reader chooses the intended representation with a conversion at the
boundary, not by remembering a promotion table.

## 4. Floats and division

`f16`, `f32`, and `f64` all compute at their own width. `+`, `-`, `*`, unary
`-`, comparisons, `floor`, `ceil`, and `trunc` preserve that width. Float
arithmetic follows IEEE 754, including infinities and NaNs, and does not trap.

Concrete operands of different float widths, or one integer and one float,
do not mix implicitly. A literal may still take the concrete operand's type:

```text
let scale: f32 = 1.5
let doubled = scale * 2        # 2 becomes f32
let precise = f64(scale) * 2   # the written conversion chooses f64
```

`/` keeps Luce's Python-shaped true division:

- two operands of the same float type answer that float type;
- two operands of the same integer type answer `f64`;
- division by zero therefore follows IEEE 754 and answers an infinity or
  NaN rather than trapping.

An integer `/` may lose precision because its result is expressly a floating
answer. Code that needs an integer answer uses `//`; code that needs a chosen
float width converts before `/`.

## 5. Explicit conversions

Every numeric name is a conversion constructor. A conversion to the same
type is legal and redundant.

- Integer to integer checks the destination range and traps
  `conversion_range` when the value does not fit.
- Float to integer truncates toward zero, then checks the destination range.
  NaN and infinities trap `conversion_range`.
- Integer to float rounds to nearest, ties-to-even. A value too large for the
  float may become infinity; it does not trap.
- Float to float rounds to nearest, ties-to-even. Narrowing may become
  infinity; it does not trap.

The constructor is visible at the exact boundary where representation
changes:

```text
let length: u32 = u32(len(data))
let ratio: f32 = f32(done) / f32(total)
```

There are no implicit numeric conversions in assignment, arguments, returns,
container stores, comparisons, or operators. Enum conversion remains
explicit and is renamed with the vocabulary: its declared backing type is one
of the eight integers, conversion out uses that backing type or `str`, and
`Enum(value)` remains the optional checked way in. A declaration that omits
its enum backing uses `i32`, preserving a compact and fully specified default.

## 6. `char`, `str`, and `bytes`

The three types separate a Unicode scalar, text, and binary data.

### `char`

`char` is one Unicode scalar value: `U+0000` through `U+10FFFF`, excluding
the surrogate range. It is a value type stored as a 32-bit scalar.

A single-quoted literal must decode to exactly one scalar:

```text
let letter: char = 'A'
let wave = '\u{1F44B}'
```

Empty, multi-scalar, malformed, surrogate, and out-of-range literals are
compile-time errors. A `char` supports equality and scalar-order comparison,
but no arithmetic. `char(integer)` traps `bad_codepoint` when the integer is
not a scalar; `u32(character)` returns its code point; and `str(character)`
encodes it as UTF-8.

`char` is deliberately not an extended grapheme cluster. Grapheme
segmentation is a Unicode library operation, not a hidden cost in every
index, loop, and length.

### `str`

`str` is immutable, valid UTF-8 and copies as a value. Its ordinary sequence
unit is `char`, never a byte:

- `len(text)` counts Unicode scalars;
- `text[index]` answers one `char`;
- `text[start:end]` slices at scalar positions and answers `str`;
- `for character in text` iterates scalars; and
- concatenation and lexicographic scalar comparison remain available.

Indexes are non-negative `i64` values. Out-of-range indexing and slicing
trap `string_bounds`. Because UTF-8 is variable-width, scalar length and
random indexing are linear unless an optimizer can prove otherwise; the
surface tells the truth rather than calling byte offsets characters.

`len` answers `i64` for text, bytes, and every container. Array extents and
ordinary container indexes are also `i64`; another integer width crosses that
API through an explicit conversion. This gives every size-facing API one
portable type and preserves negative-value diagnostics at its boundary.

`str(value)` is the one textual rendering constructor for booleans, numbers,
characters, enums, unions, and function values. Numeric rendering is the
shortest round-tripping text at the value's own width.

### `bytes`

`bytes` is immutable binary data and copies as a value. It has no UTF-8
invariant. `len(data)` counts bytes, indexing answers `u8`, slicing answers
`bytes`, concatenation joins byte runs, and equality/order are lexicographic
over unsigned bytes.

`bytes(text)` encodes a `str` as UTF-8. `bytes(list)` and `bytes(array)` copy
from `list[u8]` and one-dimensional `array[u8, _]`. The inverse text
operation is `parse_str(data) -> str?`: invalid UTF-8 answers `none` rather
than manufacturing text. Mutable byte buffers remain `list[u8]` and
`array[u8, _]`.

A dedicated byte-literal syntax is not part of this migration. It can be
added later if real binary-heavy code shows that constructors are noisy; the
type does not depend on a second literal grammar.

## 7. Container type application and construction

Square brackets mean type application. Parentheses mean a value call. Keeping
those two jobs separate removes the current ambiguity between an array's
element type and its runtime extents.

```text
let names: list[str] = new list[str]
let scores: map[str, i64] = new map[str, i64]
let image: array[u8, _, _] = new array[u8](height, width)
```

- `list[T]` is a growable ARC reference sequence.
- `map[K, V]` is an ARC reference associative container. Its existing key
  restrictions remain until generic hashing exists.
- `array[T, _, ...]` is a fixed-after-construction ARC reference grid. Each
  `_` records one rank in the type; the actual positive extents are runtime
  values supplied to `new array[T](...)`.

Runtime extents deliberately do not become type arguments. Luce matrices,
images, windows, and file buffers routinely derive their sizes from input;
making each size a separate type would remove those use cases or require a
second dynamic array.

An empty `list` or `map` needs its type application. Non-empty literals infer
their element types with the same contextual-literal rules. An array always
uses `new` because its extents are part of construction.

`task` uses the same bracket convention when it carries an answer:
`task`, `task[!]`, `task[T]`, and `task[T!]`. A task remains a resource made
only by `spawn`, never by `new`. Function types keep parentheses because they
describe a call: `func(T, ...) -> R`.

The runtime-only `builder` may remain while the migration is in flight. Its
intended public replacement is `strings.Builder` after the generic library
surface can express it; it is not a reason to delay or duplicate the scalar
rename.

## 8. Target grammar for closures and weak storage

The type migration must leave room for the ARC features that follow it.
These spellings are fixed before parser work so classes do not force another
syntax break.

A block closure is an anonymous `func` expression. Its parameter and answer
types come from the function type at the landing place, like the existing
single-expression lambda:

```text
let advance: func(i64) -> i64 = func(amount):
    total += amount
    return total
```

The existing `(amount) -> total + amount` remains the concise,
single-expression, capture-free form. An anonymous `func` may capture. A
capture list precedes it:

```text
let refresh: func() = [weak model] func():
    if model != none:
        model.refresh()

let announce: func() = [name = current_name] func():
    print(name)
```

An unadorned capture is strong for references and a shared cell for a mutable
local. `weak name` captures an optional weak reference. `name = expression`
captures one value snapshot. No capture default or unsafe `unowned` form
exists.

`weak` describes storage, not a new `Type` value. A class or built-in ARC
object is assigned into an optional weak field or mutable local:

```text
class Node:
    weak parent: Node?
    children: list[Node]

weak var selected: Node? = node
```

A weak read always has `T?`. `weak let` is refused because zeroing can change
what the storage reads even when the program does not assign it. Resources,
function values, and value types cannot be weak. Worker snapshots refuse
weak storage and classes rather than changing identity rules.

## 9. Class lifecycle surface

A class is final, heap allocated, reference counted, and mutable through a
`let` binding. Assignment and parameter passing share identity. `is` compares
class identity; `==` is not synthesized for classes.

The first class release uses memberwise construction and field defaults. An
optional lifecycle hook has one spelling:

```text
class Session:
    path: str

    deinit:
        print(f"closed {self.path}")
```

`deinit` takes no parameters, returns nothing, is never fallible, is not a
method value, and cannot be called. It runs exactly once when the last strong
reference is released, before stored fields are released. It may read and
mutate fields and call ordinary code, but `self` may not escape through a
return, global, object/container store, closure capture, worker, or newly
created strong reference. This bans resurrection while leaving useful
cleanup possible.

Classes have no inheritance, `super`, `override`, synthesized equality or
hashing, computed properties, metaclasses, or user-written initializers in
this milestone. Composition and interfaces are the reuse mechanisms.

## 10. Diagnostic taxonomy

Stable diagnostic codes identify the rule, while messages name the concrete
types and the repair. The migration adds these families rather than routing
every mistake through a generic type mismatch:

| Code | Meaning |
|---|---|
| `luce.sema.type.retired` | an old builtin spelling, with the replacement |
| `luce.sema.numeric.literal` | a literal cannot inhabit its contextual type |
| `luce.sema.numeric.operands` | concrete numeric operands differ or an operator is unavailable |
| `luce.sema.numeric.conversion` | a conversion constructor has the wrong source shape |
| `luce.parse.char` | malformed or non-scalar character literal |
| `luce.sema.container.type` | wrong type arguments, rank, or construction form |
| `luce.sema.weak.target` | storage attempts to weaken an unsupported kind |
| `luce.sema.weak.storage` | non-optional or immutable weak storage |
| `luce.sema.class.lifecycle` | malformed `deinit` or escaping/resurrecting `self` |
| `luce.sema.class.identity` | `is` is used outside class references |
| `luce.sema.worker.send` | a class, weak value, resource, or closure environment crosses a worker |

Runtime failures keep the existing stable trap taxonomy:
`integer_overflow`, `conversion_range`, `divide_by_zero`, `shift_range`,
`bad_codepoint`, bounds traps, and resource/host traps. A compile-time literal
failure is never recast as a runtime conversion trap.

## 11. Atomic migration manifest

The rename is complete only when every row moves in the same commit series:

| Layer | Required change |
|---|---|
| Source and syntax | token/grammar data, scalar names, single-quoted `char`, bracket type application, new-array construction |
| Semantic model | type tags, arbitrary-precision literal checking, conversions, operators, equality/order, zero values, enum backing types |
| HIR | typed constants and operation result types for all widths, `char`, `str`, and `bytes` |
| MIR | append/replace scalar tags and constants, verifier range checks, printer names, serializer round trips, format bump |
| Runtime | `Value` tags/accessors, checked operations/conversions, text/binary ownership, scalar iteration, container packing and zeros |
| Oracle | the same runtime calls and observable traps as compiled code; no independent numeric semantics |
| LLVM | integer widths/signedness, checked intrinsics, float widths, conversions, comparisons, division, shift checks, boxing/unboxing |
| ABI | retain the 24-byte value layout; preserve the numeric values of representation-compatible old tags under their new internal names, append new tags, and bump the published ABI because hosts may now receive the additional value kinds |
| Userland | embedded standard library, packages, examples, editor, benchmark sources, install samples, and package fixtures |
| Tools | syntax highlighters, grammar inventories, document guards, test classification, MIR corpus, and diagnostics snapshots |
| Documentation | current references and public Guide/Library replace every old spelling; Status moves the feature from planned to current |
| Release | module format/version, tool version when published, archive, installer smoke, site build, push, and deploy |

Searches for retired spellings must distinguish Luce source/prose from Zig's
own `u8`, `i64`, and `f64` implementation types. Migration tests are the only
living files allowed to mention a retired Luce spelling, and each such test
must assert the replacement diagnostic.

## 12. Acceptance matrix

The phase does not exit on a few happy examples. It proves:

1. minimum, maximum, just-inside, and just-outside literals for all eleven
   numeric types;
2. every integer arithmetic operation at every width, including overflow,
   division, remainder, negation, and shifts;
3. every ordered pair of numeric conversions, with boundary, NaN, infinity,
   rounding, signedness, and narrowing cases;
4. contextual literals in locals, arguments, returns, fields, constants,
   aliases, enums, optionals, lists, maps, and arrays;
5. mixed concrete numeric operands are rejected with both types named;
6. `char` literal escapes and invalid scalar cases, UTF-8 scalar iteration,
   indexing, slicing, and `char`/`str`/`bytes` round trips;
7. immutable `bytes` alongside mutable `list[u8]` and `array[u8, _]` file
   buffers;
8. bracket application and construction across aliases, nested containers,
   functions, tasks, imports, signatures, fields, and diagnostics;
9. every retired spelling refused with exact replacement advice; and
10. MIR encode/decode mutation tests, compiled/oracle differential behavior,
    zero live objects, LLVM structural checks, and performance comparison to
    the Phase 0 baseline.

Every executable Luce case belongs in `src/luce/specs/` and runs on both
engines. Layer-structure tests stay beside the layer they inspect. The full
repository and public-site gates run once at the phase boundary after focused
lanes are clean.
