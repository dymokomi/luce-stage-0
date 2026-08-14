# Strings and copies

`string` is an immutable value. Literals, f-strings, concatenation, and
comparison are built into the language; the [standard string module](/library/strings/)
adds search, splitting, case conversion, formatting, and byte conversion.

The important distinction is between **bytes** and **characters**:

- `len(s)`, `s[a:b]`, `s.byte_at(i)`, and `s.find_byte(...)` use byte
  offsets.
- `std.strings.characters`, `width`, `take`, `pad_left`, and `pad_right`
  walk UTF-8 sequences as characters. In the current version `width` counts
  code points, not terminal cells.

Slices must end at UTF-8 boundaries. A slice is still a string value; it is
not a borrowed list or a handle whose lifetime can escape.

## Values make ownership predictable

Assigning or returning a string gives the receiver its own value. Storing a
string in a list, map, array, or struct copies its bytes into that owner.
There is no `give`, `copy`, or `free` word for a string. The trade-off is
visible when a large string is copied; the benefit is that a container never
refers to bytes owned by a shorter-lived scope. See [Memory without a collector](/guide/memory/)
for the general ownership rules.

## Build text once

Repeated `+` in a loop makes a new value each time. A `builder` is the
usual shape for accumulating text:

```luce run
func main():
    var joined = new builder()
    for i in range(0, 4):
        if i > 0:
            joined.append(" ")
        joined.append(string(i))
    print(joined.build())
```

```output
0 1 2 3
```

Use `append_ascii(byte)` when the byte is already known to be ASCII. It
avoids making a one-byte temporary string. For a complete list of builder
operations, see [the builtins reference](/guide/reference/builtins/).

## Search and slicing

`strings.find(s, needle, start = 0)` returns a byte offset or `none`; it
does not use `-1` as a hidden sentinel. `contains`, `starts_with`,
`ends_with`, and `count` build on the same rule. A needle that is not validly
aligned in UTF-8 cannot create a matching slice.

```luce run
import std.strings

func main():
    let path = "src/luce/main.luc"
    print(string(path.find("/", 4) else -1))
    print(f"{path.starts_with("src")} {path.ends_with(".luc")}")
    print(string(path.count("/")))
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

`strings.format_float(value, decimals)` is fixed-point display rounded half
away from zero. A negative `decimals` is a trap; values above about `1e15`
use `string(value)` because fixed-point fractional digits are no longer
meaningful. An f-string format such as `f"{value:.2f}"` uses the same
operation.

`to_bytes(s)` is total because every Luce string has bytes. `from_bytes(xs)`
returns `string?`: invalid UTF-8 is absence, not a host error. The complete
signatures and examples are in [`std.strings`](/library/strings/).
