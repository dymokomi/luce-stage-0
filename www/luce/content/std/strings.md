# std.strings

The language keeps the `string` primitives — literals and f-strings,
`+`, comparison, boundary-checked slices `s[a:b]`, `len(s)`,
`s.byte_at(i)` and `s.find_byte(byte, start)`. Everything built on top
of them is ordinary Luce in this module.

```
import std.strings
```

The familiar method spelling is sugar for it: with the import in
scope, `s.find(x)` **is** `strings.find(s, x)`, and
`parts.join(sep)` is `strings.join(parts, sep)`. Using a string method
without the import is a compile error that says so.

All offsets are **byte** offsets, like the primitives. The module
never splits a UTF-8 character: it slices at ASCII positions or at
match positions of valid UTF-8 needles. The one deliberate exception
is the [character vocabulary](#characters) — `characters`, `width`,
`take` and the two pads count characters, not bytes.

## Searching

| Signature | Returns |
|---|---|
| `strings.find(s, needle, start = 0) -> long?` | first occurrence at or after `start`, or absence |
| `strings.contains(s, needle) -> bool` | |
| `strings.starts_with(s, prefix) -> bool` | |
| `strings.ends_with(s, suffix) -> bool` | |
| `strings.count(s, needle) -> long` | non-overlapping occurrences; an empty needle counts every `len(s) + 1` byte boundary |
| `strings.is_digit(b) -> bool` | the ASCII classes, on the byte `byte_at` answers |
| `strings.is_alpha(b)`, `is_alnum(b)`, `is_upper(b)`, `is_lower(b)`, `is_space(b)` | bytes above 127 are in none of them |

```luce run
import std.strings

func main():
    let path = "src/luce/std/strings.luc"
    print(string(path.find("/") else -1))
    print(string(path.find("/", 4) else -1))
    print(string(path.find("nowhere") else -1))
    print(f"{path.contains("std")} {path.starts_with("src")} {path.ends_with(".luc")}")
    print(string(path.count("/")))
```

```output
3
8
-1
true true true
3
```

## Reshaping

| Signature | Notes |
|---|---|
| `strings.trim(s) -> string` | ASCII whitespace off both ends |
| `strings.lower(s)`, `strings.upper(s)` | ASCII folding; multibyte characters pass through whole |
| `strings.replace(s, old, replacement) -> string` | every occurrence; an empty `old` changes nothing |
| `strings.repeat(s, times) -> string` | zero or fewer gives `""` |
| `strings.pad_left(s, cells)`, `strings.pad_right(s, cells)` | space-padded to `cells` display cells |

```luce run
import std.strings

func main():
    let raw = "\t  Mixed CASE text  \n"
    print(f"[{raw.trim()}]")
    print(raw.trim().lower())
    print(raw.trim().upper())
    print(raw.trim().replace("text", "words"))
    print(f"[{"ab".repeat(3)}]")
    print(f"[{"7".pad_left(5)}][{"7".pad_right(5)}]")
```

```output
[Mixed CASE text]
mixed case text
MIXED CASE TEXT
Mixed CASE words
[ababab]
[    7][7    ]
```

## Characters

Everything else in this module counts **bytes**, because the
primitives do. These three count **characters**, and so do the two
pads above, because a person reading a column does.

| Signature | Notes |
|---|---|
| `strings.characters(s) -> list(string)` | the code points, one string each, in order |
| `strings.width(s) -> long` | display cells |
| `strings.take(s, cells) -> string` | the longest prefix that fits; never cuts a character in half |

A UTF-8 sequence is a lead byte followed by its continuation bytes, so
a character begins at every byte that is **not** a continuation byte
and runs to the next byte that does — the same rule
[`s[a:b]`](/ref/types/) enforces, which is why every slice these cut
is a legal one.

```luce run
import std.strings

func main():
    let label = "café"
    print(f"{len(label)} bytes, {label.width()} cells")
    print(f"[{label.pad_left(6)}]")
    print(f"[{label.take(3)}]")
    print(string(len(label.characters())))
```

```output
5 bytes, 4 cells
[  café]
[caf]
4
```

The middle line is the fix: `pad_left` counted **bytes** until this
landed, so `café` measured five wide and the column lost a space to
`é`'s second byte. Every label with a non-ASCII character in it did.

**v0.1 counts code points, not terminal cells.** `width("日本")` is 2
where a terminal draws 4, and a combining mark counts as a cell of its
own. That is exactly what a Luce program walking text counted for
itself before this existed, so nothing regressed — and unlike before,
it is wrong in **one body** instead of in every program. `width` is
the seam: `take` asks it what one character costs and the pads ask it
what the whole text costs, so a width table lands there and nowhere
else.

**Malformed bytes are answered, never refused.** A `string` can hold
bytes nobody checked — `read_line` and `env` carry the world's — so
the walk validates nothing and terminates on any bytes at all. A stray
continuation byte belongs to the character before it, a truncated
sequence is the character it began, and continuation bytes at the very
start of a string begin no character and are stepped over. Nothing
here traps.

## Splitting and joining

| Signature | Notes |
|---|---|
| `strings.split(s, separator) -> list(string)` | keeps empty pieces; an empty separator splits on whitespace runs and drops the empties, which is Python's `split()` |
| `strings.join(parts, separator) -> string` | |

`split` hands back a fresh **object** — a `list(string)` the receiver
owns and must give away or free. `join` hands back a `string`, which
is a **value**: it copies like any other, and there is nothing to own.
That distinction is the one the whole
[memory model](/ref/ownership/) rests on.

```luce run
import std.strings

func main():
    let csv = "a,,b,c"
    let pieces = csv.split(",")
    print(f"{len(pieces)} pieces: [{pieces.join("|")}]")

    let messy = "  one   two  three "
    print(f"{len(messy.split(""))} words")
    print(f"{len(messy.split(" "))} space-separated pieces")
```

```output
4 pieces: [a||b|c]
3 words
9 space-separated pieces
```

## Formatting

`strings.format_float(x, decimals) -> string` gives fixed-point
display, rounding half away from zero. `string(x)` gives the shortest
form that round-trips.

**An f-string spec is this function**: `f"{x:.2f}"` *is*
`strings.format_float(x, 2)`, which is why a spec needs this import
like any other string service. Write the call where a format is not
in a string; write the spec where it is.

It is for **display of ordinary magnitudes**, and it says so at both
edges rather than pretending otherwise:

- `decimals` below zero **traps** `explicit_trap`. A negative digit
  count is not a request this function can round; it is a bug at the
  call site.
- above about 1e15 there are no fractional digits left to print, so it
  falls back to `string(value)` — `format_float(1.0e20, 2)` is
  `100000000000000000000`, with no `.00`.

```luce trap
import std.strings

func main():
    print(strings.format_float(1.0e20, 2))
    print(strings.format_float(2.5, -1))
```

```output
100000000000000000000
loom: trap: format_float needs decimals >= 0 [explicit_trap]
    at strings.format_float (std/strings.luc:309:9)
    at main (main.luc:5:5)
```

```luce run
import std.strings

func main():
    print(strings.format_float(2.5, 2))
    print(strings.format_float(1.0 / 3.0, 5))
    print(strings.format_float(-2.345, 2))
    print(strings.format_float(9.99, 0))
    print(string(1.0 / 3.0))
    let third: double = 1.0 / 3.0
    print(string(third))
```

```output
2.50
0.33333
-2.35
10
0.33333334
0.3333333333333333
```

The last two lines are the same division at two widths. `string(x)`
prints the shortest text that round-trips **at the value's own width**,
so an unannotated `1.0 / 3.0` is a `float` and nine digits are enough
to name it again; the `double` needs sixteen. Neither is rounded for
display — both are exact descriptions of different numbers.

## Bytes

| Signature | Notes |
|---|---|
| `strings.to_bytes(s) -> list(byte)` | the string's bytes; total, because a string always has some |
| `strings.from_bytes(xs) -> string?` | those bytes as text, or absent when they are not valid UTF-8 |

The asymmetry is the whole content of the pair. **One direction cannot
fail and the other is a parse.** A `string` is already valid UTF-8, so
taking its bytes is a reading of something that is certainly there;
handing bytes back is a claim about them, and the claim can be false.

`from_bytes` answers `string?` and not `string!` for the reason
[`parse_int`](/ref/builtins/) does: "not UTF-8" is the same reason
every time, and a message that says it adds nothing a reader did not
already know from the name.

```luce run
import std.strings

func main():
    let bytes = strings.to_bytes("héllo")
    print(string(len(bytes)))
    print(strings.from_bytes(bytes) else "(not text)")
    var broken = new list(byte)
    broken.append(byte(0xFF))
    print(strings.from_bytes(broken) else "(not text)")
```

```output
6
héllo
(not text)
```

Six, not five: `len` counts bytes on both sides of the conversion, and
`é` is two of them. The `list(byte)` costs one byte an element, so
carrying a file's contents around as bytes costs what the file costs.

## Why this module is fast enough to stay in Luce

Two primitives carry the weight. `find` locates a needle's first
byte with `find_byte` and only then compares the rest, so the scan
itself is **one runtime call the implementation may vectorize** rather
than a Luce loop over `byte_at`. And `fold_case`, which `lower` and
`upper` build on, emits folded bytes with `append_ascii`, which needs
no `string` per character.

That is why searching is a language primitive at all: not because it
is hard, but because it is the seam where a vectorized implementation
enters.

`fold_case` is the module's one internal, and it is marked
[`private`](/tour/visibility/): reaching it — as
`strings.fold_case(...)` or through the method spelling
`s.fold_case(...)`, which routes to the same declaration — is
`luce.sema.private`. It used to be reachable, which made an internal
helper look like a blessed string method; the marker is what closed
that door, and the roster above is the module's whole surface. (The
old space helper graduated: it is the public `is_space` in the ASCII
class table above.)

## The sentinel that was

`find` used to answer `-1` for "not found", and overloaded it for a
`start` outside the string. It answers `long?` now: absence for a
match that never comes and for a `start` where no match could begin,
with `find(s, x) else -1` as the one-keystroke spelling for anyone
who wants the number back. Nothing compares against a magic value by
accident anymore, and the [status page](/status/) no longer keeps
this on a list.

The empty-needle rule is explicit: `find` matches at the requested
`start`, while `count` counts every byte boundary, `len(s) + 1` in all.
They answer different questions without disagreeing about the boundaries.
