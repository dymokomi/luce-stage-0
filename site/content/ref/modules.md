# Modules

A file is a module.

## import

```
import name          binds the sibling file `name.luc`
import std.name      binds a module embedded in the compiler
```

Both bind the **bare name**, so call sites read `math.sqrt(x)` and
only the import line records where the module came from.

An import reaches the imported file's top level:

```
name.func(args)
name.Struct(field = expr, ...)
name.Struct.member(args)
name.constant
p: name.Struct              in an annotation
```

Scope stays per file. Nothing is visible without an import, and using
a namespace you did not import is `luce.sema.import`.

Modules may import each other; the graph loads each file once, so
cross-file mutual recursion works. A module importing itself is
`luce.import.self`. The whole graph compiles as one program and writes
one module file.

Errors inside an imported file render at the path it was really opened
from, with the source line and a caret.

## Sibling resolution

A sibling import names the file exactly, **including its case**, and
the file must be an ordinary file. A case-insensitive filesystem would
happily open `Geo.luc` for `import geo`, so the directory entry is
checked rather than the open — a program that builds on one machine
builds on the machine that ships it. A name with no file beside it is
`luce.import.missing`, and it names the path it looked for.

```luce fail
import geometry

func main():
    print("x")
```

```output
luce: compile failed
main.luc:1:1: cannot load module geometry (looked for geometry.luc) [luce.import.missing]
    import geometry
    ^~~~~~~~~~~~~~~
```

Deliberately absent: package managers, search paths, conditional
imports, re-exports, and any `as` clause.

## The `std.` namespace

`std` is reserved. No **module name** is. The two namespaces are
disjoint, so a `math.luc` beside your program is exactly what
`import math` reaches, and a standard module can neither be shadowed
nor make a file of yours unreachable.

Three rules keep it honest.

| Written | Diagnostic |
|---|---|
| `import std.nope` | `luce.import.standard` — the error lists the modules that exist |
| `import std` | `luce.import.reserved` — the namespace is not a module, so no `std.luc` can ever be imported |
| `import std.math` and `import math` together | `luce.import.collision` — one binding, two modules; rename the file |

```luce fail
import std.nope

func main():
    print("x")
```

```output
luce: compile failed
main.luc:1:1: there is no standard module std.nope; the standard library is std.math, std.files, std.strings [luce.import.standard]
    import std.nope
    ^~~~~~~~~~~~~~~
```

Standard modules are ordinary Luce source embedded in the compiler.
They obey every language rule including the host gate: `import
std.files` inside a program compiled without host access is a compile
error, because file access genuinely does not exist there.

The modules are [`math`](/std/math/), [`strings`](/std/strings/) and
[`files`](/std/files/).

## Multi-file programs

```luce module file=shapes.luc
let unit = 1.0

struct Rect:
    width: double
    height: double

    func area(r: Rect) -> double:
        return r.width * r.height

func square(side: double) -> Rect:
    return Rect(width = side, height = side)
```

```luce run
import shapes

func main():
    let r = shapes.square(3.0)
    print(f"{r.width}x{r.height} area {shapes.Rect.area(r)} unit {shapes.unit}")
```

```output
3x3 area 9 unit 1
```
