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
match positions of valid UTF-8 needles.

## Searching

| Signature | Returns |
|---|---|
| `strings.find(s, needle) -> long` | first byte offset, or `-1` |
| `strings.find_from(s, needle, start) -> long` | first occurrence at or after `start` |
| `strings.contains(s, needle) -> bool` | |
| `strings.starts_with(s, prefix) -> bool` | |
| `strings.ends_with(s, suffix) -> bool` | |
| `strings.count(s, needle) -> long` | non-overlapping occurrences |

```luce run
import std.strings

func main():
    let path = "src/luce/std/strings.luc"
    print(string(path.find("/")))
    print(string(path.find_from("/", 4)))
    print(string(path.find("nowhere")))
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
| `strings.pad_left(s, width)`, `strings.pad_right(s, width)` | space-padded to `width` bytes |

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
    at strings.format_float (std/strings.luc:186:9)
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
```

```output
2.50
0.33333
-2.35
10
0.3333333333333333
```

## Why this module is fast enough to stay in Luce

Two primitives carry the weight. `find_from` locates a needle's first
byte with `find_byte` and only then compares the rest, so the scan
itself is **one runtime call the implementation may vectorize** rather
than a Luce loop over `byte_at`. And `fold_case`, which `lower` and
`upper` build on, emits folded bytes with `append_ascii`, which needs
no `string` per character.

That is why searching is a language primitive at all: not because it
is hard, but because it is the seam where a vectorized implementation
enters.

## The one sentinel

`find` and `find_from` answer `-1` for "not found". `long?` exists now,
so the sentinel is a wart with nothing holding it up — and
`find_from` overloads it: a `start` below zero or past the end of the
string answers `-1` too, which is an *argument* error and not the same
fact as "absent". `find` is `find_from(s, needle, 0)` and cannot reach
that case, so the sentinel means only one thing there.

The two also disagree with `count` about the empty needle: `find` and
`find_from` treat it as a match at `start`, while `count` counts it
zero times. Both answers are defensible and they are not the same
answer.

The [status page](/status/) keeps this on the list.
