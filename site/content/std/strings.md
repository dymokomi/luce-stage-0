# std.strings

The language keeps the `String` primitives — literals and f-strings,
`+`, comparison, boundary-checked slices `s[a:b]`, `len(s)`,
`s.byte_at(i)` and `s.find_byte(byte, start)`. Everything built on top
of them is ordinary Luce in this module.

```
import std.strings
```

The familiar method spelling is sugar for it: with the import in
scope, `s.find(x)` **is** `strings.find(s, x)`, and
`parts.join(sep)` is `strings.join(parts, sep)`. Using a String method
without the import is a compile error that says so.

All offsets are **byte** offsets, like the primitives. The module
never splits a UTF-8 character: it slices at ASCII positions or at
match positions of valid UTF-8 needles.

## Searching

| Signature | Returns |
|---|---|
| `strings.find(s, needle) -> Int` | first byte offset, or `-1` |
| `strings.find_from(s, needle, start) -> Int` | first occurrence at or after `start` |
| `strings.contains(s, needle) -> Bool` | |
| `strings.starts_with(s, prefix) -> Bool` | |
| `strings.ends_with(s, suffix) -> Bool` | |
| `strings.count(s, needle) -> Int` | non-overlapping occurrences |

```luce run
import std.strings

func main():
    let path = "src/luce/std/strings.luc"
    print(str(path.find("/")))
    print(str(path.find_from("/", 4)))
    print(str(path.find("nowhere")))
    print(f"{path.contains("std")} {path.starts_with("src")} {path.ends_with(".luc")}")
    print(str(path.count("/")))
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
| `strings.trim(s) -> String` | ASCII whitespace off both ends |
| `strings.lower(s)`, `strings.upper(s)` | ASCII folding; multibyte characters pass through whole |
| `strings.replace(s, old, replacement) -> String` | every occurrence; an empty `old` changes nothing |
| `strings.repeat(s, times) -> String` | zero or fewer gives `""` |
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
| `strings.split(s, separator) -> List(String)` | keeps empty pieces; an empty separator splits on whitespace runs and drops the empties, which is Python's `split()` |
| `strings.join(parts, separator) -> String` | |

Both hand back fresh objects the receiver owns.

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

`strings.format_float(x, decimals) -> String` gives fixed-point
display, rounding half away from zero. `str(x)` gives the shortest
form that round-trips.

```luce run
import std.strings

func main():
    print(strings.format_float(2.5, 2))
    print(strings.format_float(1.0 / 3.0, 5))
    print(strings.format_float(-2.345, 2))
    print(strings.format_float(9.99, 0))
    print(str(1.0 / 3.0))
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
no `String` per character.

That is why searching is a language primitive at all: not because it
is hard, but because it is the seam where a vectorized implementation
enters.

## The one sentinel

`find` and `find_from` answer `-1` for "not found". `Int?` exists now,
so the sentinel is a wart with nothing holding it up
— and `find` also returns `-1` for an *argument* error, which is not
the same fact as "absent". The
[status page](/status/) keeps it on the list.
