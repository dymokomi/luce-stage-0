# Modules and Imports

Each `.luc` file is a module. `import name` loads the sibling
`name.luc` and binds the module under `name`. An import is required before
using another file's declarations.

Modules are namespaces, not runtime objects. Importing a file adds its
declarations to the program graph; it does not run an initialization body,
and there is no mutable module state. This makes source organization a
compile-time concern rather than an order-dependent startup mechanism.

## Split a program by responsibility

Start with `main.luc`. Move a coherent set of types and functions into a
sibling when the new name makes the program easier to navigate:

```text
sample/
├── main.luc
└── geometry.luc
```

```luce module file=geometry.luc
struct Point:
    x: f64
    y: f64

const unit = 1.0

func distance(a: Point, b: Point) -> f64:
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

The module name qualifies functions, structs, methods, constants, and type
annotations. Declarations marked `private` are not reachable from an
importer; [Access Control](/guide/access-control/) explains that boundary.
Imports are case-sensitive. The file name, import spelling, and filesystem
entry must agree exactly even on a host whose filesystem would otherwise
ignore case.

Import only the module, then keep its qualification at the use site. The
prefix tells a reader where a declaration came from and lets two modules use
the same declaration name without flattening them into one scope.

Modules may import one another. Each file is loaded once, and the complete
graph is compiled into one artifact, so mutually recursive functions across
files are valid. A module cannot import itself. Conditional imports, wildcard
imports, executable import bodies, and source-level re-export declarations
are not part of Luce.

## The standard library

`std.*` modules are embedded in the compiler. They are imported like user
modules and are written in Luce source:

```luce run
import std.math
import std.strings

func main():
    print(strings.format_float(math.pi, 5))
    print(str(math.ipow(2, 10)))
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
[`json`](/library/json/), plus [`gpu`](/library/gpu/) and [`ui`](/library/ui/).

## Source files

Source is UTF-8 text. LF and CRLF line endings are accepted, and imports
from standard input resolve relative to the current directory. Invalid UTF-8,
NUL bytes, unsupported line endings or encoding markers, and an oversized
source file are rejected before parsing. See the
[lexical reference](/guide/reference/lexical/)
for limits and diagnostic codes.

An error inside an imported module is reported at that module's real path,
with its own source line. The compiler does not copy declarations into the
importing file for diagnostics. This matters when a project has several
modules with similar names.

## Project roots and subfolders

A `luce.yaml` file marks a project root. Dotted imports map to subfolders;
`as` chooses a local binding name when two modules would otherwise collide.

```luce module file=luce.yaml
name: sample
version: 0.1.0
```

```luce module file=geo/shapes.luc
func area(width: f64, height: f64) -> f64:
    return width * height
```

```luce run
import geo.shapes as gs

func main():
    print(str(gs.area(3.0, 4.0)))
```

```output
12
```

With a manifest, every project import is resolved from that one root—even a
single-segment `import util` written inside a subfolder. A stable root means
moving the importing file does not silently change which `util.luc` it sees.
Without a manifest, Luce deliberately keeps the small-script rule: imports
are single-segment siblings, and dotted imports are refused with a message
that asks for a project root.

The minimum manifest names the project and version:

```yaml
name: sample
version: 0.1.0
```

The manifest is also the exact dependency want list when packages are added.
It is not executable configuration and does not control language semantics.

## Rename a module binding

The `as gs` clause renames a module binding only. A type alias is a different
declaration:

```text
alias PointId = i64
private alias Cache = map[PointId, str]
```

A public type alias is reachable as `module.PointId` and may deliberately
re-export an imported public type. A private one stays inside its file. See
[Naming a type](/guide/basics/#naming-a-type) for the first use and the
[type-alias reference](/guide/reference/types/#type-aliases) for exact rules.

Two imports whose last path segment is the same would otherwise claim one
binding. Rename one explicitly:

```text
import geometry.shapes
import controls.shapes as control_shapes
```

The alias changes only the local namespace. It does not rename the file,
package, or declarations inside it.

## Source packages and installed packages

A package begins as an ordinary direct subfolder of the project:

```text
sample/
├── luce.yaml
├── main.luc
└── paint/
    ├── luce.yaml
    ├── paint.luc
    └── brushes.luc
```

The project manifest points at that authoring folder with `path:paint`. This
copy belongs to the source tree and is edited normally. An installed package
has the same internal layout under `.luce/packages/paint-VERSION/`; it is a
resolved dependency and should not be edited in place.

Package imports are namespaced by the package: `import paint` loads its entry
module and `import paint.brushes` loads another public module inside it. A
package resolves its own imports and dependencies within its package context,
not by accidentally reaching into the consuming project.

The toolchain can create and version local packages. Registry upload and
download are not implemented yet, so `luce package publish` reports that
boundary rather than pretending a release occurred. [Packages and
Projects](/tools/packages/) walks through the complete authoring workflow,
manifest fields, local installation shape, dependency conflicts, and current
registry limit.

Without a project manifest, imports remain single-segment sibling imports.
The [module reference](/guide/reference/modules/) covers manifest resolution
and collision rules. Continue with [Host Effects](/guide/host/).
