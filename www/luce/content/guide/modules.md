# Modules and Imports

Each `.luc` file is a module. `import name` loads the sibling
`name.luc` and binds the module under `name`. An import is required before
using another file's declarations.

```luce module file=geometry.luc
struct Point:
    x: double
    y: double

const unit = 1.0

func distance(a: Point, b: Point) -> double:
    let dx = a.x - b.x
    let dy = a.y - b.y
    return sqrt(dx * dx + dy * dy)
```

```luce run
import geometry

func main():
    let a = geometry.Point(x = 0.0, y = 0.0)
    let b = geometry.Point(x = 3.0, y = 4.0)
    print(string(geometry.distance(a, b)))
    print(string(geometry.unit))
```

```output
5
1
```

The module name qualifies functions, structs, methods, constants, and type
annotations. Declarations marked `private` are not reachable from an
importer; [Access Control](/guide/access-control/) explains that boundary.
Imports are
case-sensitive and conditional imports and re-exports are not part of Luce.

## The standard library

`std.*` modules are embedded in the compiler. They are imported like user
modules and are written in Luce source:

```luce run
import std.math
import std.strings

func main():
    print(strings.format_float(math.pi, 5))
    print(string(math.ipow(2, 10)))
    print(strings.format_float(math.ln(math.e), 1))

    var rng = math.rng(42)
    print(f"three rolls: {rng.in_range(1, 7)} {rng.in_range(1, 7)} {rng.in_range(1, 7)}")
```

```output
3.14159
1024
1.0
three rolls: 1 4 6
```

The standard namespace is reserved. A sibling `math.luc` is still imported
by `import math`; it does not replace `std.math`. The compiler rejects an
unknown standard module, importing bare `std`, and an unaliased collision
between a standard and sibling module.

```luce fail
import std.nope

func main():
    print("hi")
```

```output
luce: compile failed
main.luc:1:1: there is no standard module std.nope; the standard library is std.math, std.files, std.strings, std.lists, std.paths, std.os, std.term, std.zip, std.json, std.gpu, std.ui [luce.import.standard]
    import std.nope
    ^~~~~~~~~~~~~~~
```

The current modules are [`math`](/library/math/), [`strings`](/library/strings/),
[`files`](/library/files/), [`lists`](/library/lists/), [`paths`](/library/paths/),
[`os`](/library/os/), [`term`](/library/term/), [`zip`](/library/zip/), and
[`json`](/library/json/), [`gpu`](/library/gpu/), and [`ui`](/library/ui/).

## Source files

Source is UTF-8 text. LF and CRLF line endings are accepted, and imports
from standard input resolve relative to the current directory. Invalid UTF-8,
NUL bytes, unsupported line endings or encoding markers, and an oversized
source file are rejected before parsing. See the
[lexical reference](/guide/reference/lexical/)
for limits and diagnostic codes.

## Projects and aliases

A `luce.yaml` file marks a project root. Dotted imports map to subfolders;
`as` chooses a local binding name when two modules would otherwise collide.

```luce module file=luce.yaml
name: sample
version: 0.1.0
```

```luce module file=geo/shapes.luc
func area(width: double, height: double) -> double:
    return width * height
```

```luce run
import geo.shapes as gs

func main():
    print(string(gs.area(3.0, 4.0)))
```

```output
12
```

Without a project manifest, imports remain single-segment sibling imports.
The [module reference](/guide/reference/modules/) covers manifest resolution
and collision rules. Continue with [Host Services](/guide/host/).
