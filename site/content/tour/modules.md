# Modules

A file is a module, like Zig. `import name` binds the sibling file
`name.luc` as a namespace, and nothing is visible without an import.

```luce module file=geometry.luc
struct Point:
    x: Float
    y: Float

let unit = 1.0

func distance(a: Point, b: Point) -> Float:
    let dx = a.x - b.x
    let dy = a.y - b.y
    return sqrt(dx * dx + dy * dy)
```

```luce run
import geometry

func main():
    let a = geometry.Point(x = 0.0, y = 0.0)
    let b = geometry.Point(x = 3.0, y = 4.0)
    print(str(geometry.distance(a, b)))
    print(str(geometry.unit))
```

```output
5
1
```

An import reaches the imported file's top level: `name.func(...)`,
`name.Struct(x = ...)`, `name.Struct.member(...)`, `name.constant`,
and `p: name.Struct` in an annotation.

Modules may import each other; the graph loads each file once, so
cross-file mutual recursion just works. A module importing *itself* is
a mistake rather than a cycle, and says so. The whole graph compiles
as one program and writes one `.lc`.

A sibling import must name the file **exactly**, including its case,
and the file must be an ordinary one. A case-insensitive filesystem
would happily open `Geo.luc` for `import geo`, so the directory entry
is checked rather than the open — a program that builds on a Mac
builds on the machine that ships it.

Deliberately absent: package managers, search paths, conditional
imports, re-exports, and any `as` clause.

## The standard library lives under std

`import std.math` reaches a module embedded in the compiler itself, so
it works everywhere the compiler does with no install path at all.

```luce run
import std.math
import std.strings

func main():
    print(strings.format_float(math.pi, 5))
    print(str(math.ipow(2, 10)))
    print(strings.format_float(math.ln(math.e), 1))

    var rng = math.seed(42)
    print(f"three rolls: {math.random_int(rng, 1, 7)} {math.random_int(rng, 1, 7)} {math.random_int(rng, 1, 7)}")
```

```output
3.14159
1024
1.0
three rolls: 2 4 6
```

The import **binds the bare name**, so call sites read `math.sqrt(x)`
and only the import line records where the module came from. That is
Rust's shape — `use std::fs;` then `fs::read`.

The two namespaces are disjoint, and that is the point. `std` is
reserved; no *module name* is. So a `math.luc` sitting beside your
program is exactly what `import math` reaches, and Python's
`random.py` problem — a neighbouring file silently taking the
library's name — cannot be written here. Neither can its opposite, a
file made unreachable because the library got there first.

Three rules keep it honest:

| Written | Result |
|---|---|
| `import std.nope` | `luce.import.standard` — and the error lists the modules that do exist |
| `import std` | `luce.import.reserved` — the namespace is not a module, so no `std.luc` beside your program can ever be imported |
| `import std.math` **and** `import math` | `luce.import.collision` — one name for two modules; rename the file |

```luce fail
import std.nope

func main():
    print("hi")
```

```output
luce: compile failed
main.luc:1:1: there is no standard module std.nope; the standard library is std.math, std.files, std.strings [luce.import.standard]
    import std.nope
    ^~~~~~~~~~~~~~~
```

There are three standard modules today: [`math`](/std/math/),
[`strings`](/std/strings/) and [`files`](/std/files/). They are
ordinary Luce source and they obey every language rule, including the
host gate — `import std.files` inside a host-less program is a compile
error, because file access genuinely does not exist there.

## Source files

A source file is UTF-8 text. Lines end with LF or CRLF, so a file
edited on Windows compiles identically and reports the same line
numbers; a leading byte-order mark is ignored; and a file may be up to
64 MiB.

What is *not* text is refused before anything is parsed, once, naming
the file and the position inside it: invalid UTF-8
(`luce.source.utf8`, which prints the byte that broke it), a NUL byte
(`luce.source.binary`), a carriage return that does not end a line
(`luce.source.line_ending`), a UTF-16 or UTF-32 byte-order mark
(`luce.source.encoding` — PowerShell's `>` writes these), and an
oversized file (`luce.source.too_large`).

A program may also come from standard input: `luce check -`, or any
pipe. Diagnostics then name it `<stdin>`, and imports resolve beside
the current directory.
