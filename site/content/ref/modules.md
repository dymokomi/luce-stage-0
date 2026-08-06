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

An import reaches the imported file's top level — **all of it, unless
a declaration is marked `private`**. Scope stays per file. Nothing is
visible without an import, and using a namespace you did not import is
`luce.sema.import`.

Modules may import each other; the graph loads each file once, so
cross-file mutual recursion works. A module importing itself is
`luce.import.self`. The whole graph compiles as one program and writes
one module file.

Errors inside an imported file render at the path it was really opened
from, with the source line and a caret.

## Visibility

A declaration is **public** unless it says `private` — written in
full, before `func`, before a top-level `let`, before `struct`, and on
a struct field. `public` may be written anywhere `private` may; where
it restates the default it is legal and inert. Inside a struct — and
only there — `private:` and `public:` open an indented **region** of
members, the way every colon in the language opens a block; regions
may repeat and appear in any order, and members outside any region
take the default. Where each word may stand, and the parse rules that
police it, are on [statements](../statements/#visibility); the
[tour chapter](/tour/visibility/) works the whole feature through.

The unit is the **file**, never the struct: within its own module a
private declaration is reachable from anywhere, including from public
declarations — visibility gates the reference site's module, not the
call graph. Touching a marked name from outside is
`luce.sema.private`, and it is answered as *private*, never as
*unknown*: the name exists, is withheld, and the refusal traces to a
`private` marker somebody wrote. A did-you-mean suggestion offers
visible names only, so a private name is never suggested and never
leaks through the typo path.

Every reference site checks the same bit: a call, a constant read, a
method on an imported struct's value, a type annotation, a
construction, and the `s.method(...)` string sugar that routes to
`std.strings`.

| Written, from outside | Said |
|---|---|
| `geo.helper()`, marked | `helper is private to geo` |
| `geo.seed`, marked constant | `seed is private to geo` |
| `p: store.Inner`, marked struct | `Inner is private to store` |
| `h.slot`, marked field | `slot of Handle is private to handle` |
| `session.Session(token = 7)`, marked field named | `token of Session is private to session` |
| `geo.helperr`, a typo near a marked name | `unknown function helperr` — and no suggestion names a private one |

```luce module file=geo.luc
private func helper() -> long:
    return 41

func visible() -> long:
    return helper() + 1

private let seed = 41
let answer = seed + 1
```

```luce fail
import geo

func main():
    print(string(geo.helper()))
```

```output
luce: compile failed
main.luc:4:18: helper is private to geo [luce.sema.private]
        print(string(geo.helper()))
                     ^~~~~~~~~~~~
```

The public surface crosses untouched — and a public constant may fold
from private ones, because the *value* crosses the boundary, not the
name:

```luce run
import geo

func main():
    print(string(geo.visible()))
    print(string(geo.answer))
```

```output
42
42
```

A private **field** composes with construction: an outside site may
name unmarked fields only, and every private field must carry a
default or the struct is not constructible outside its module — the
factory pattern, named in the diagnostic.

```luce module file=session.luc
struct Session:
    name: string
    private id: long
    private token: long = 0

func open(name: string) -> Session:
    return Session(name = name, id = 7)
```

```luce fail
import session

func main():
    let s = session.Session(name = "dy")
    print(s.name)
```

```output
luce: compile failed
main.luc:4:13: Session cannot be constructed here: id is marked private in session and has no default; construction belongs to a public function of session [luce.sema.private]
        let s = session.Session(name = "dy")
                ^~~~~~~~~~~~~~~~~~~~~~~~~~~~
```

```luce run
import session

func main():
    let s = session.open("dy")
    print(s.name)
```

```output
dy
```

A private field *with* a default is filled from it silently; only a
required one closes construction. A struct with no marked fields
constructs from outside exactly as it always did.

A public declaration's surface may name only public types: a public
function whose parameter or result mentions a private struct is
refused at the declaration, on the line that can fix it, naming both
edits that would restore honesty. A private field's type is not part
of the public surface and may be private — which is what lets a struct
hide an implementation type entirely.

```luce fail
private struct Inner:
    n: long

func read() -> Inner:
    return Inner(n = 1)

func main():
    print(string(read().n))
```

```output
luce: compile failed
main.luc:4:16: read is public and answers Inner, which is marked private in this file; mark read private or remove the mark on Inner [luce.sema.private]
    func read() -> Inner:
                   ^~~~~
```

`main` never needs marking. The runtime starts it by name rather than
through an import, so `public` on it is inert like any other restated
default and `private` on it is refused: an entry the world cannot
start is a contradiction.

```luce fail
private func main():
    print("x")
```

```output
luce: compile failed
main.luc:1:14: main is the entry and cannot be private: the runtime starts it [luce.sema.private]
    private func main():
                 ^~~~
```

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
main.luc:1:1: there is no standard module std.nope; the standard library is std.math, std.files, std.strings, std.paths [luce.import.standard]
    import std.nope
    ^~~~~~~~~~~~~~~
```

Standard modules are ordinary Luce source embedded in the compiler.
They obey every language rule including the host gate: `import
std.files` inside a program compiled without host access is a compile
error, because file access genuinely does not exist there.

The modules are [`math`](/std/math/), [`strings`](/std/strings/),
[`files`](/std/files/) and [`paths`](/std/paths/).

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
