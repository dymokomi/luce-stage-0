# std.strings

The language provides immutable `string` values, literals and f-strings,
concatenation, comparison, byte-offset slices, `len`, `byte_at`, and
`find_byte`. `std.strings` supplies the operations built on those primitives.

```text
import std.strings
```

With the module imported, method syntax is shorthand: `text.find(needle)` is
`strings.find(text, needle)`, and `parts.join(separator)` is
`strings.join(parts, separator)`.

## Search and ASCII classes

Offsets are bytes. The search functions do not split a valid UTF-8 sequence.

| Signature | Result |
|---|---|
| `strings.find(s, needle, start = 0) -> long?` | first byte offset at or after `start`, or `none`; an empty needle matches at `start` |
| `strings.contains(s, needle) -> bool` | whether a match exists |
| `strings.starts_with(s, prefix) -> bool` | whether `s` begins with `prefix` |
| `strings.ends_with(s, suffix) -> bool` | whether `s` ends with `suffix` |
| `strings.count(s, needle) -> long` | non-overlapping matches; an empty needle counts every byte boundary |
| `strings.is_digit(b: byte) -> bool` | ASCII `0`–`9` |
| `strings.is_upper(b: byte) -> bool` | ASCII `A`–`Z` |
| `strings.is_lower(b: byte) -> bool` | ASCII `a`–`z` |
| `strings.is_alpha(b: byte) -> bool` | ASCII letter |
| `strings.is_alnum(b: byte) -> bool` | ASCII letter or digit |
| `strings.is_space(b: byte) -> bool` | ASCII space, tab, carriage return, or newline |

Bytes at or above 128 are in none of the ASCII classes.

```luce run
import std.strings

func main():
    let text = "alpha;beta;gamma"
    print(string(text.find(";", 2) else -1))
    print(f"{text.contains("beta")} {text.starts_with("alpha")}")
    print(string(text.count(";")))
```

```output
5
true true
2
```

## Reshaping text

| Signature | Result |
|---|---|
| `strings.trim(s) -> string` | removes ASCII whitespace from both ends |
| `strings.lower(s) -> string` | folds ASCII uppercase to lowercase; other bytes pass through |
| `strings.upper(s) -> string` | folds ASCII lowercase to uppercase; other bytes pass through |
| `strings.replace(s, old, replacement) -> string` | replaces every non-overlapping occurrence; an empty `old` changes nothing |
| `strings.repeat(s, times) -> string` | repeats `s`; zero or fewer returns `""` |
| `strings.split(s, separator) -> list(string)` | splits text and keeps empty pieces for a non-empty separator |
| `strings.join(parts, separator) -> string` | joins list elements with `separator` |

An empty separator in `split` means whitespace mode: ASCII whitespace runs
are separators and empty pieces are dropped. `split` returns a fresh list that
the caller owns; `join` returns a string value.

```luce run
import std.strings

func main():
    let words = "  one   two  three ".split("")
    print(string(len(words)))
    print("a,,b".split(",").join("|"))
    print("AbC".lower())
    print("ha".repeat(3))
```

```output
3
a||b
abc
hahaha
```

## Characters and width

The following functions count UTF-8 code points rather than bytes:

| Signature | Result |
|---|---|
| `strings.characters(s) -> list(string)` | one code-point string per item |
| `strings.width(s) -> long` | code-point count in the current version, not terminal-cell width |
| `strings.take(s, cells) -> string` | longest prefix within the requested code-point count; never cuts a sequence |
| `strings.pad_left(s, cells) -> string` | spaces before `s` until its code-point count reaches `cells` |
| `strings.pad_right(s, cells) -> string` | spaces after `s` until its code-point count reaches `cells` |

`len(s)` still reports bytes. `width("日本")` is `2`, even on a terminal
where those glyphs occupy four cells. A future cell-width table belongs in
this module's one width operation rather than in each caller.

```luce run
import std.strings

func main():
    let word = "café"
    print(f"{len(word)} bytes, {word.width()} characters")
    print(f"[{word.pad_left(6)}]")
    print(f"[{word.take(3)}]")
    print(string(len(word.characters())))
```

```output
5 bytes, 4 characters
[  café]
[caf]
4
```

## Formatting numbers

`strings.format_float(value: double, decimals: long) -> string` produces
fixed-point text, rounding half away from zero. A negative `decimals` traps.
For magnitudes above about `1e15`, it returns `string(value)` because there
are no meaningful fractional digits left. An f-string spec such as
`f"{value:.2f}"` uses the same operation.

```luce run
import std.strings

func main():
    print(strings.format_float(2.5, 2))
    print(strings.format_float(-2.345, 2))
    print(strings.format_float(9.99, 0))
```

```output
2.50
-2.35
10
```

## Bytes and text

| Signature | Result |
|---|---|
| `strings.to_bytes(s) -> list(byte)` | UTF-8 bytes of `s`; always succeeds |
| `strings.from_bytes(xs) -> string?` | text represented by `xs`, or `none` when the bytes are not valid UTF-8 |

The conversion to bytes is total because a Luce string already has a byte
representation. The conversion back is a parse and therefore uses absence.

```luce run
import std.strings

func main():
    let bytes = strings.to_bytes("hé")
    print(string(len(bytes)))
    print(strings.from_bytes(bytes) else "(invalid)")

    var bad: list(byte) = [255]
    print(strings.from_bytes(bad) else "(invalid)")
```

```output
3
hé
(invalid)
```
