# Strings

`string` is a value type. It copies when assigned, passed, or stored,
exactly as a scalar or a plain `struct` does, and it takes no memory
verbs of any kind. `docs/MEMORY.md` is the model this rests on: values
copy, reference types are shared and reference-counted. This document is
how a `string` is stored, what a program can spell on one directly, and
what the compiled code looks like.

## A string is a value

Assigning or passing a `string` gives the destination its own copy of
the bytes:

```luce
func main():
    let a = "hello"
    var b = a
    b = b + "!"
    print(a)          # hello
    print(b)          # hello!
```

Storing a `string` into anything that outlives the current statement — a
binding, a container element, a `struct` field, a `map` key — copies the
bytes into that place, so no place ever holds a view of bytes it did not
allocate. Every stored string has independent storage, and that storage is
reclaimed when the value goes away: the scope that holds a
binding, the entry that holds a map key, the container that holds an
element. A program never frees a string; the runtime reclaims it.

## How the bytes are stored

A runtime `Value` is 24 bytes. A string that fits carries its bytes
**inside** that value with no allocation at all; a longer string points
**outside** to a separate allocation used only by that value.

- **Small-string optimization.** A string of **22 bytes or fewer** lives
  in the value's own bytes. A one-byte form field records the inline
  length, and the remaining bytes hold the text. No heap allocation, no
  pointer to chase — the value *is* the string. This is the same
  in-situ threshold libc++ reaches in the same 24 bytes.
- **Outside storage.** A string longer than 22 bytes uses a private heap
  allocation holding its bytes; the value carries a pointer and a length.
  The allocation is freed when the place holding the value dies.

The threshold covers what programs actually store — split pieces,
`string(n)` results, short map keys — so the common case allocates
nothing. Because a store copies, a stored value has independent bytes,
and reclaiming them is unconditional, with no shared bit, no
counter, and no side table: a string is a value, not a
reference-counted object.

### A fresh value moves rather than copies

The one store that does not duplicate bytes is the one that hands over a
value the current statement just made and keeps nothing else. In
`xs.append(a + b)` or `field = strings.upper(text)`, the concatenation
or the built result is a fresh allocation with no other reference, so the
store takes that allocation instead of copying it. This is an internal
optimization with no surface: a program cannot tell a move from a copy,
because both leave the same independent values.

## Slices are views

`s[a:b]` is a **view** into `s`: pointer arithmetic over the same bytes,
with no allocation. The compiled form is a bounds check, two UTF-8
boundary checks, and an address adjustment. A slice out of bounds traps
`string_bounds`; a slice that would split a UTF-8 sequence traps
`string_boundary`.

A view costs nothing until you keep one. Storing a slice — appending it
to a `list`, binding it, putting it in a field — copies at the store,
like any other value, so the kept string never pins the parent it was
sliced from:

```luce
import std.strings

func main():
    let line = "one,two,three"
    let pieces = strings.split(line, ",")   # each piece copied on append
    print(pieces[1])                        # two
```

Returning a slice of a parameter or of a constant is legal, because a
string return copies. A string-returning function may hand back a view
of its argument, a view of a constant, or freshly made bytes, and the
caller receives its own copy either way — there is no annotation that
distinguishes them and none is needed. `strings.trim` returning
`s[first:last]` is ordinary.

## The primitives

The language spells only a small set of string operations directly.
Everything else is a method that routes to the standard `strings` module.

| operation | form | result |
|---|---|---|
| literal | `"text"`, `f"{x}"` | `string` |
| concatenation | `a + b` | `string` |
| comparison | `==` `!=` `<` `<=` `>` `>=` | `bool` |
| length in bytes | `len(s)` | `long` |
| byte at an index | `s.byte_at(i)` | `byte` |
| find a byte from an index | `s.find_byte(b, start)` | `long` |
| slice | `s[a:b]` | `string` (a view) |

`byte_at` and `find_byte` work in bytes: `find_byte` is the scanning
primitive that substring search in `std.strings` is built on, and it is
where SIMD enters. `len` is a byte count.

Every other string operation is a method that desugars to a
`std.strings` call and requires `import std.strings`. `s.split(",")` is
`strings.split(s, ",")`; `s.upper()`, `s.trim()`, `s.contains(x)`,
`s.starts_with(p)`, `s.replace(old, new)`, `s.find(needle)` and the rest
resolve the same way:

```luce
import std.strings

func main():
    let name = "  Ada  "
    print(name.trim().upper())      # ADA
    print(f"{name.contains("da")}")  # true
```

`strings.find` answers `long?` — `none` when the needle is absent, so a
caller narrows rather than testing a sentinel. The `strings` module is
ordinary Luce source and obeys every language rule, the host gate
included.

## The compiled representation

Reads are unboxed. The backend holds a `string` in a register as an
aggregate of a pointer and an `i64` length, promoted into SSA registers:

- `len(s)` extracts the length field.
- `s.byte_at(i)` is an address computation and an `i8` load.
- `s[a:b]` is an address computation and a subtraction.
- A `string` local is a stack slot the optimizer promotes into
  registers.

Stores cross into the runtime as a boxed 24-byte value, where the copy
(or the move of a fresh allocation) happens behind a call the code was
already making, so a store's generated code is unchanged by the value
model. A local acquires no bookkeeping beyond the release the runtime
already emits for the scope that owns it.

Because a string that fits is stored inside its value, a register form
derived from an inline string points into the value it was read out of;
reading such a string materializes a small copy into a statement
temporary so the register form stays uniform and never outlives its
source. `string(n)` and `chr(code)` always fit inline and never
allocate; `chr` of an invalid code point traps `bad_codepoint`.

## Performance

A program that holds no strings pays nothing for the string model: the
numeric and array benchmarks touch a string only when printing a final
result, and run at C's speed. Programs that build many strings pay for allocation, not
for copying — a small copy is a handful of nanoseconds while an
allocation is an order of magnitude more, so the design keeps allocations
down (inline storage, moving fresh values) and treats the copy as free.
The one necessary copy the design keeps is the store of a kept slice: it
is what lets a small substring not pin a large parent, the same reason Go
ships `strings.Clone`.
