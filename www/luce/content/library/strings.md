# std.strings

The language provides immutable `str` values, literals and f-strings,
concatenation, comparison, scalar-indexed slices, `len`, `byte_at`, and
`find_byte`. `std.strings` supplies operations built on those primitives.

```text
import std.strings
```

With the module imported, method syntax is shorthand: `text.find(needle)` is
`strings.find(text, needle)`, and `parts.join(separator)` is
`strings.join(parts, separator)`.

## Search and ASCII classes

Search positions are Unicode-scalar positions. Raw encoding operations are
explicitly named `byte_at`, `find_byte`, and `bytes`.

| Signature | Result |
|---|---|
| `strings.find(s, needle, start = 0) -> i64?` | first scalar position at or after `start`, or `none`; an empty needle matches at `start` |
| `strings.contains(s, needle) -> bool` | whether a match exists |
| `strings.starts_with(s, prefix) -> bool` | whether `s` begins with `prefix` |
| `strings.ends_with(s, suffix) -> bool` | whether `s` ends with `suffix` |
| `strings.count(s, needle) -> i64` | non-overlapping matches; an empty needle counts every scalar boundary |
| `strings.is_digit(c: char) -> bool` | ASCII `0`–`9` |
| `strings.is_upper(c: char) -> bool` | ASCII `A`–`Z` |
| `strings.is_lower(c: char) -> bool` | ASCII `a`–`z` |
| `strings.is_alpha(c: char) -> bool` | ASCII letter |
| `strings.is_alnum(c: char) -> bool` | ASCII letter or digit |
| `strings.is_space(c: char) -> bool` | ASCII space, tab, carriage return, or newline |

Non-ASCII scalars are in none of the ASCII classes.

```luce run
import std.strings

func main():
    let text = "alpha;beta;gamma"
    print(str(text.find(";", 2) else -1))
    print(f"{text.contains("beta")} {text.starts_with("alpha")}")
    print(str(text.count(";")))
```

```output
5
true true
2
```

## Reshaping text

| Signature | Result |
|---|---|
| `strings.trim(s) -> str` | removes ASCII whitespace from both ends |
| `strings.lower(s) -> str` | folds ASCII uppercase to lowercase; other scalars pass through |
| `strings.upper(s) -> str` | folds ASCII lowercase to uppercase; other scalars pass through |
| `strings.replace(s, old, replacement) -> str` | replaces every non-overlapping occurrence; an empty `old` changes nothing |
| `strings.repeat(s, times) -> str` | repeats `s`; zero or fewer returns `""` |
| `strings.split(s, separator) -> list[str]` | splits text and keeps empty pieces for a non-empty separator |
| `strings.join(parts, separator) -> str` | joins list elements with `separator` |

An empty separator in `split` means whitespace mode: ASCII whitespace runs
are separators and empty pieces are dropped. `split` returns a fresh list that
the caller owns; `join` returns a `str` value.

```luce run
import std.strings

func main():
    let words = "  one   two  three ".split("")
    print(str(len(words)))
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
| `strings.characters(s) -> list[str]` | one-scalar `str` per item |
| `strings.width(s) -> i64` | scalar count in the current version, not terminal-cell width |
| `strings.take(s, cells) -> str` | longest prefix within the requested scalar count; never cuts a scalar |
| `strings.pad_left(s, cells) -> str` | spaces before `s` until its scalar count reaches `cells` |
| `strings.pad_right(s, cells) -> str` | spaces after `s` until its scalar count reaches `cells` |

`len(s)` also reports scalars. `width("日本")` is `2`, even on a terminal
where those glyphs occupy four cells. A future cell-width table belongs in
this module's one width operation rather than in each caller.

```luce run
import std.strings

func main():
    let word = "café"
    print(f"{len(bytes(word))} bytes, {len(word)} characters")
    print(f"[{word.pad_left(6)}]")
    print(f"[{word.take(3)}]")
    print(str(len(word.characters())))
```

```output
5 bytes, 4 characters
[  café]
[caf]
4
```

## Formatting numbers

`strings.format_float(value: f64, decimals: i64) -> str` produces
fixed-point text, rounding half away from zero. A negative `decimals` traps.
For magnitudes above about `1e15`, it returns `str(value)` because there
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
| `strings.to_bytes(s) -> list[u8]` | UTF-8 bytes of `s`; always succeeds |
| `strings.from_bytes(xs) -> str?` | text represented by `xs`, or `none` when the bytes are not valid UTF-8 |

The conversion to bytes is total because a Luce `str` already has a byte
representation. The conversion back is a parse and therefore uses absence.

```luce run
import std.strings

func main():
    let raw = strings.to_bytes("hé")
    print(str(len(raw)))
    print(strings.from_bytes(raw) else "(invalid)")

    var bad: list[u8] = [255]
    print(strings.from_bytes(bad) else "(invalid)")
```

```output
3
hé
(invalid)
```
