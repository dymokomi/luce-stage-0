# Text processing

The language keeps the `string` primitives; everything else is
`std.strings`, written in ordinary Luce. With the import in scope the
method spelling works: `s.split(x)` *is* `strings.split(s, x)`.

```luce run
import std.strings

func main():
    let line = "  name , age , city  "
    var fields: list(string) = []
    for raw in line.split(","):
        fields.append(raw.trim())
    print(f"{len(fields)}: [{fields.join("][")}]")
```

```output
3: [name][age][city]
```

## Searching and testing

```luce run
import std.strings

func main():
    let path = "src/luce/06_mir/module.zig"
    print(f"find '/': {path.find("/") else -1}")
    print(f"find '/' after 4: {path.find("/", 4) else -1}")
    print(f"contains 'mir': {path.contains("mir")}")
    print(f"starts_with 'src': {path.starts_with("src")}")
    print(f"ends_with '.zig': {path.ends_with(".zig")}")
    print(f"count '/': {path.count("/")}")
```

```output
find '/': 3
find '/' after 4: 8
contains 'mir': true
starts_with 'src': true
ends_with '.zig': true
count '/': 3
```

## Reshaping

```luce run
import std.strings

func main():
    let messy = "\tThe Quick   Brown Fox\n"
    print(f"[{messy.trim()}]")
    print(messy.trim().lower())
    print(messy.trim().upper())
    print(messy.trim().replace("Quick", "Slow"))
    print(f"[{"-".repeat(20)}]")
    print(f"[{"42".pad_left(6)}][{"42".pad_right(6)}]")
```

```output
[The Quick   Brown Fox]
the quick   brown fox
THE QUICK   BROWN FOX
The Slow   Brown Fox
[--------------------]
[    42][42    ]
```

An empty separator splits on runs of whitespace and drops the empty
pieces — Python's `split()`. A real separator keeps them.

```luce run
import std.strings

func main():
    let messy = "  a   b  c  "
    print(f"whitespace: {len(messy.split(""))} pieces")
    print(f"on space:   {len(messy.split(" "))} pieces")
```

```output
whitespace: 3 pieces
on space:   10 pieces
```

## Building text

Repeated `+` allocates every time; a `builder` does not.

```luce run
func main():
    var table = new builder()
    for row in range(0, 4):
        for column in range(0, 4):
            table.append(string(row * column))
            table.append_ascii(9)      # a tab, without allocating a string
        table.append("\n")
    print(table.build())
```

```output
0	0	0	0	
0	1	2	3	
0	2	4	6	
0	3	6	9	
```

## Walking bytes

`len(s)` is bytes, `byte_at(i)` reads one, and `find_byte(byte, start)`
scans. Those three are the primitives everything else is built on, and
the seam where the runtime may vectorize.

```luce run
func main():
    let text = "a,bb,ccc"
    var start: long = 0
    var pieces = 0
    while true:
        let comma = text.find_byte(44, start)
        if comma < 0:
            pieces += 1
            print(f"piece: {text[start:len(text)]}")
            break
        pieces += 1
        print(f"piece: {text[start:comma]}")
        start = comma + 1
    print(f"{pieces} pieces, {len(text)} bytes")
```

```output
piece: a
piece: bb
piece: ccc
3 pieces, 8 bytes
```

## Formatting numbers

`string(x)` gives the shortest round-trip form **at the value's own
width** — nine digits for a `float`, sixteen for a `double`, because
those are what it takes to name each number again.
`strings.format_float(x, decimals)` gives fixed point, rounding half
away from zero.

```luce run
import std.strings

func main():
    print(string(1.0 / 3.0))
    let wide: double = 1.0 / 3.0
    print(string(wide))
    print(strings.format_float(1.0 / 3.0, 4))
    print(strings.format_float(2.5, 0))
    print(strings.format_float(-2.345, 2))
```

```output
0.33333334
0.3333333333333333
0.3333
3
-2.35
```
