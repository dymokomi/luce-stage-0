# Text: `char` and `str`

Luce separates a Unicode scalar, text, and binary data:

- `char` is one Unicode scalar value;
- `str` is immutable valid UTF-8 whose sequence unit is `char`; and
- `bytes` is immutable binary data whose sequence unit is `u8`.

All three are value types. They copy on assignment, argument passing, return,
and container storage. Programs never retain, release, or free them.

## `char` is one Unicode scalar

`char` represents `U+0000` through `U+10FFFF`, excluding the surrogate range.
A single-quoted literal must decode to exactly one scalar:

```luce
func main():
    let letter: char = 'A'
    let wave: char = '\u{1F44B}'
    assert(letter < wave)
```

Empty, multi-scalar, malformed, surrogate, and out-of-range literals are
compile-time errors. A `char` supports equality and scalar-order comparison,
but no arithmetic.

- `char(integer)` checks that the integer is a Unicode scalar and traps
  `bad_codepoint` otherwise.
- `u32(character)` returns the scalar value.
- `str(character)` encodes the scalar as UTF-8.

`char` is not an extended grapheme cluster. Grapheme segmentation belongs in
a Unicode library rather than as a hidden cost in every index and loop.

## `str` is a scalar sequence

`str` is immutable valid UTF-8. Its ordinary sequence operations use Unicode
scalar positions, never byte offsets:

| Operation | Result |
|---|---|
| `len(text)` | number of scalars as `i64` |
| `text[index]` | one `char` |
| `text[start:end]` | a `str` sliced at scalar positions |
| `for character in text` | iterates `char` values |
| `left + right` | concatenated `str` |
| equality and ordering | lexicographic scalar comparison |

```luce
func main():
    let text = "A👋é"
    assert(len(text) == 3)
    assert(text[1] == '👋')
    assert(text[1:3] == "👋é")
```

Indexes and slice bounds are non-negative integers of any width — a
position is a position whatever type carries it, through the same checked
conversion an explicit `i64(…)` would make, so a `u64` past `i64`'s top is
`conversion_range` at the index. An out-of-range position traps
`str_bounds`. The API does not pretend byte offsets are characters.

### What an index costs

UTF-8 is variable-width, so a scalar position and a byte offset are the same
number only when every scalar is one byte. **A `str` remembers which case it
is in**, and the answer decides what an index costs:

| the text | `len`, `text[i]`, `text[a:b]` |
|---|---|
| all ASCII | a load — the index *is* the offset |
| anything else | a walk from the start, so O(i) |

A string is classified once, where its bytes are already being handled: a
literal at compile time, an allocation as it is filled, a join from its two
halves, a slice from the whole it came out of. The answer is a declared field
of the value — `encoding`, beside the length that says which form the text is
in — so it reads the same whether the text lives inside the value or outside
it, and generated code carries the same answer in the register a `str` travels
through. Nothing rediscovers it, and a value that never learned keeps the walk
rather than guessing (`runtime.Encoding`, `codegen/lower.zig`).

This is why a pass over a large ASCII string is a pass and not a quadratic
one, which is the difference between a program that can read a source file
and one that cannot. Text with multi-byte scalars still walks, so a hot loop
over one is better written over `bytes`.

## Raw UTF-8 access

Byte-oriented algorithms can inspect a string's encoding explicitly:

- `text.byte_at(index) -> u8` reads one UTF-8 byte;
- `text.find_byte(value, start) -> i64` searches from a byte offset; and
- `bytes(text)` copies the UTF-8 encoding into a `bytes` value.

These are encoding operations, not the ordinary text sequence model. Mutable
binary buffers use `list[u8]` or `array[u8, _]`.

## Converting text and bytes

`bytes(text)` always succeeds because every `str` is valid UTF-8.
`parse_str(data) -> str?` validates a `bytes`, `list[u8]`, or one-dimensional
`array[u8, _]`; invalid UTF-8 answers `none`.

```luce
func main():
    let encoded = bytes("hello")
    let decoded = parse_str(encoded) else "not text"
    assert(decoded == "hello")
```

There is no dedicated byte-literal syntax, and the need it waited for
arrived with a different answer (the self-host lexer probe, #24 item 13):
character literals are contextual over integer widths, so `data[at] == '"'`
and `c >= 'a'` over a `u8` are the spelling — the scalar lands as the
integer when it fits (docs/TYPES.md). The type and validation boundary
are unchanged.

## Rendering values

`str(value)` renders booleans, numbers, characters, strings, enum and union
members, and function values. Numeric rendering is the shortest text that
round-trips at the source width.

An f-string applies the same rendering to each hole. A float hole accepts the
optional `:.Nf` fixed-point format described in [NUMERICS.md](NUMERICS.md).

## Representation

A runtime `Value` is 24 bytes. Short strings use inline storage; longer strings
use private outside storage owned by the value. A stored `str` never borrows
storage from another place. The compiler may move a fresh temporary instead
of copying it, but that optimization cannot change value semantics.

Both execution paths call the same runtime text operations. Scalar decoding,
bounds checks, UTF-8 validation, conversions, and ownership therefore have one
implementation and one observable answer.
