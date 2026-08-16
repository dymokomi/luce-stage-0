# Strings and Text

`string` is an immutable value. Literals, f-strings, concatenation, and
comparison are built into the language; the [standard string module](/library/strings/)
adds search, splitting, case conversion, formatting, and byte conversion.

The important distinction is between **bytes** and **characters**:

- `len(s)`, `s[a:b]`, `s.byte_at(i)`, and `s.find_byte(...)` use byte
  offsets.
- `std.strings.characters`, `width`, `take`, `pad_left`, and `pad_right`
  walk UTF-8 sequences as characters. In the current version `width` counts
  code points, not terminal cells.

Slices must end at UTF-8 boundaries. A slice is still an independent string
value, not a view into another string's storage.

## String values

Assigning or returning a string gives the receiver its own value. Storing a
string in a list, map, array, or struct copies its bytes into that value. The
cost is visible when a large string is copied; the benefit is that the new
value does not depend on another string's lifetime. See [Memory and
ARC](/guide/memory/) for the distinction between values and shared references.

## Splitting and joining

`std.strings` is written in ordinary Luce on top of the language's string
primitives. With the module imported, `s.split(x)` is method syntax for
`strings.split(s, x)`.

```luce run
import std.strings

func main():
    let line = "  name , age , city  "
    var fields: list[str] = []
    for raw in line.split(","):
        fields.append(raw.trim())
    print(f"{len(fields)}: [{fields.join("][")}]")
```

```output
3: [name][age][city]
```

An empty separator splits on runs of whitespace and drops empty pieces. A
nonempty separator keeps empty pieces between adjacent separators.

## Building text

Repeated `+` in a loop makes a new value each time. A `builder` is the
usual shape for accumulating text:

```luce run
func main():
    var joined = new builder
    for i in range(0, 4):
        if i > 0:
            joined.append(" ")
        joined.append(str(i))
    print(joined.build())
```

```output
0 1 2 3
```

Use `append_ascii(byte)` when the byte is already known to be ASCII. It
avoids making a one-byte temporary string. For a complete list of builder
operations, see [Built-in Functions and Methods](/guide/reference/builtins/).

## Search and slicing

`strings.find(s, needle, start = 0)` returns a byte offset or `none`; it
does not use `-1` as a hidden sentinel. `contains`, `starts_with`,
`ends_with`, and `count` build on the same rule. A needle that is not validly
aligned in UTF-8 cannot create a matching slice.

```luce run
import std.strings

func main():
    let path = "src/luce/main.luc"
    print(str(path.find("/", 4) else -1))
    print(f"{path.starts_with("src")} {path.ends_with(".luc")}")
    print(str(path.count("/")))
```

```output
8
true true
2
```

When a match is optional, narrow it with `else`:

```text
let offset = text.find(":") else 0
```

That bare fence is explanatory code, not a runnable sample; complete
programs on the [library page](/library/strings/) show each function's edge
cases.

## Reshaping text

Trimming, case conversion, replacement, repetition, and padding all return
new strings. The original remains unchanged.

```luce run
import std.strings

func main():
    let messy = "\tThe Quick   Brown Fox\n"
    print(f"[{messy.trim()}]")
    print(messy.trim().lower())
    print(messy.trim().upper())
    print(messy.trim().replace("Quick", "Slow"))
    print(f"[{"-".repeat(20)}]")
```

```output
[The Quick   Brown Fox]
the quick   brown fox
THE QUICK   BROWN FOX
The Slow   Brown Fox
[--------------------]
```

## Walking bytes

`len(s)` reports bytes, `byte_at(i)` reads one, and
`find_byte(byte, start)` scans. Byte-oriented operations are useful for
ASCII delimiters and protocol formats, but a resulting slice must still end
at valid UTF-8 boundaries.

```luce run
func main():
    let text = "a,bb,ccc"
    var start: i64 = 0
    while true:
        let comma = text.find_byte(44, start)
        if comma < 0:
            print(f"piece: {text[start:len(text)]}")
            break
        print(f"piece: {text[start:comma]}")
        start = comma + 1
```

```output
piece: a
piece: bb
piece: ccc
```

## Characters and display width

`characters(s)` returns a new `list(string)`, one UTF-8 code point per item.
`width(s)` counts those code points. `take(s, n)` returns the longest prefix
whose code-point count is at most `n` and never cuts a sequence. The padding
functions use the same count:

```luce run
import std.strings

func main():
    let word = "café"
    print(f"{len(word)} bytes, {word.width()} characters")
    print(f"[{word.pad_left(6)}]")
    print(f"[{word.take(3)}]")
```

```output
5 bytes, 4 characters
[  café]
[caf]
```

The module does not validate arbitrary byte lists here. `from_bytes` is the
explicit conversion that returns `string?` when a byte list is not valid
UTF-8.

## Formatting and byte conversion

`string(x)` produces the shortest round-trip representation at the value's
own width. `strings.format_float(value, decimals)` produces fixed-point
display rounded half away from zero. A negative `decimals` is a trap;
values above about `1e15` use `string(value)` because fixed-point
fractional digits are no longer meaningful. An f-string format such as
`f"{value:.2f}"` uses the same operation.

```luce run
import std.strings

func main():
    print(str(1.0 / 3.0))
    let wide: f64 = 1.0 / 3.0
    print(str(wide))
    print(strings.format_float(wide, 4))
    print(strings.format_float(-2.345, 2))
```

```output
0.33333334
0.3333333333333333
0.3333
-2.35
```

`to_bytes(s)` is total because every Luce string has bytes. `from_bytes(xs)`
returns `string?`: invalid UTF-8 is absence, not a host error. The complete
signatures and examples are in [`std.strings`](/library/strings/).
