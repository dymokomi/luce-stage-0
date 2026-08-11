# Modules

A file is a module.

## import

```
import name             binds the sibling file `name.luc`
import std.name         binds a module embedded in the compiler
import folder.name      binds `folder/name.luc` under the project root
import folder.name as other   the same file, bound as `other`
```

An import binds the **last segment** — `import std.math` and
`import geo.math` both bind `math` — so call sites read `math.sqrt(x)`
and only the import line records where the module came from.  An
`as` clause picks a different binding; the [projects
section](#projects-and-subfolders) below covers the dotted form, which
needs a project root.  `as` is read contextually, so it is not a
keyword and stays usable as an ordinary name.

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
full, before `func`, before a file-scope `const`, before `struct`, and on
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

private const seed = 41
const answer = seed + 1
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
edits that would restore honesty. The check follows containers and
every nested parameter and result of a function type. A private
field's type is not part of the public surface and may be private —
which is what lets a struct hide an implementation type entirely.

A public constant container is a public surface too: its element or
map-value type may not be private. A private constant may use the
private type, and a public folded value may still be computed from a
private constant because that exposes the value rather than its name.

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
imports, and re-exports.

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
| `import std.math` and `import math` together | `luce.import.collision` — one binding, two modules; alias the sibling (`import math as m2`), because a standard module keeps its own name and `import std.math as m` is refused |

```luce fail
import std.nope

func main():
    print("x")
```

```output
luce: compile failed
main.luc:1:1: there is no standard module std.nope; the standard library is std.math, std.files, std.strings, std.lists, std.paths, std.os, std.term, std.zip, std.json [luce.import.standard]
    import std.nope
    ^~~~~~~~~~~~~~~
```

Standard modules are ordinary Luce source embedded in the compiler.
They obey every language rule including the host gate: `import
std.files` inside a program compiled without host access is a compile
error, because file access genuinely does not exist there.

The modules are [`math`](/std/math/), [`strings`](/std/strings/),
[`files`](/std/files/), [`lists`](/std/lists/),
[`paths`](/std/paths/), [`os`](/std/os/), [`zip`](/std/zip/) and
[`json`](/std/json/). `std.lists` currently contributes the routed
`xs.sort_by(before)` method rather than a namespace function.

## Multi-file programs

```luce module file=shapes.luc
const unit = 1.0

struct Rect:
    width: double
    height: double

    static func area(r: Rect) -> double:
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

## Projects and subfolders

A file named **`luce.yaml`** marks a project root.  It is found by
walking up from the root source file's directory, it needs only the
project's own identity —

```
name: sample
version: 0.1.0
```

— and it changes resolution in two ways.  First, dots map to folders:
`import geo.shapes` reads `geo/shapes.luc` under the project root, at
any depth, still binding the last segment.  Second, **every** import
is root-relative — the single-segment `import util` included — so
`import geo.shapes` means the same file from every file in the tree.
There is exactly one anchor per program: without a `luce.yaml` a
program keeps today's sibling resolution, single segment only, and a
dotted import is refused by name.

```luce fail
import geo.shapes

func main():
    print(string(shapes.area(3.0, 4.0)))
```

```output
luce: compile failed
main.luc:1:1: cannot read geo/shapes.luc for module geo.shapes: subfolder imports need a project root, and no luce.yaml governs this program [luce.import.unreadable]
    import geo.shapes
    ^~~~~~~~~~~~~~~~~
```

With the manifest in place, the same import resolves:

```luce module file=luce.yaml
name: sample
version: 0.1.0
```

```luce module file=geo/shapes.luc
func area(width: double, height: double) -> double:
    return width * height
```

```luce run
import geo.shapes

func main():
    print(string(shapes.area(3.0, 4.0)))
```

```output
12
```

Exact case and regular files are checked at **every** segment, the way
they always were for the file itself: a folder really named `Geo`
refuses `import geo.shapes` with the real spelling in the message,
whatever the filesystem would have tolerated.

Two imports whose last segments agree want one binding for two
modules.  That is `luce.import.collision`, and the remedy is in the
message: **`as`** binds a module under a name of your choosing.

```luce module file=blocks/shapes.luc
func volume(edge: double) -> double:
    return edge * edge * edge
```

```luce fail
import geo.shapes
import blocks.shapes

func main():
    print(string(shapes.area(3.0, 4.0)))
```

```output
luce: compile failed
main.luc:2:1: import geo.shapes and import blocks.shapes both bind the name shapes; give one its own name: import blocks.shapes as NAME [luce.import.collision]
    import blocks.shapes
    ^~~~~~~~~~~~~~~~~~~~
```

```luce run
import geo.shapes
import blocks.shapes as blocks

func main():
    print(string(shapes.area(3.0, 4.0)))
    print(string(blocks.volume(2.0)))
```

```output
12
8
```

The alias moves only the binding, never the file: the module is still
`geo.shapes`, and one module holds one binding for the whole program —
a second import of the same module must agree with the first, or alias
it the same way.  A standard module keeps its own name (`import
std.math as m` is refused at parse time); when a sibling collides with
one, the sibling takes the alias.

## Packages

The manifest's `packages:` section is the **want list**: each entry
names a package and one exact version — no ranges, upgrading is
editing the number.  A wanted package is a directory named
`NAME-VERSION` in the project's store, `.luce/packages/`, put there by
hand today (`cp -r` a checkout, a git submodule): vendoring is just
the store with no tooling.  A package is a directory with a
`luce.yaml` of its own, which must agree with the directory's name and
version or the package is refused by name.

`import geo` reads the entry module `geo.luc` at the package root;
`import geo.shapes` reads `shapes.luc` inside it.  A package's own
imports resolve **inside the package** — its files, then its own
`packages:` — never in the consuming project, so a `util.luc` of the
package and a `util.luc` of the project (or of another package) can
never answer for each other.

```luce module file=luce.yaml
name: sample
version: 0.1.0

packages:
  paint: 0.3.0
```

```luce module file=.luce/packages/paint-0.3.0/luce.yaml
name: paint
version: 0.3.0
```

```luce module file=.luce/packages/paint-0.3.0/paint.luc
import brushes
import util

func area(r: brushes.Rect) -> long:
    return util.scale(r.width * r.height)
```

```luce module file=.luce/packages/paint-0.3.0/brushes.luc
struct Rect:
    width: long
    height: long
```

```luce module file=.luce/packages/paint-0.3.0/util.luc
func scale(v: long) -> long:
    return v * 10
```

```luce run
import paint
import paint.brushes

func main():
    let r = brushes.Rect(width = 2, height = 3)
    print("area " + string(paint.area(r)))
```

```output
area 60
```

Resolution probes **every** tier — the project tree, the store, and
each directory named by the `LUCE_LIB` environment variable
(colon-separated, same `NAME-VERSION` layout) — and exactly one may
answer.  Two answers is `luce.import.ambiguous` with every answering
path named: there is no precedence and no first-hit, because
precedence is silent shadowing.  The want list gates every store and
shelf probe, so a stray install cannot change what a program means —
and a resolution from `LUCE_LIB`, or from a want's `path:` annotation
(the development override: resolve this package from a directory
instead of the store), says so on standard error, every build.  A
want may also carry `sha256:` followed by the package directory's
content hash, verified on every resolution when present.

A package's `luce.yaml` may want packages of its own; the whole
transitive set resolves with exact versions, and one name resolves to
**one** version in the whole build.  Two requirers disagreeing is a
diamond, refused with both edges named — and the remedy is in the
consumer's hands, an `override:` section in the root `luce.yaml`,
because the person meeting the refusal owns neither manifest:

```luce module file=luce.yaml
name: sample
version: 0.1.0

packages:
  tint: 1.2.0
  easel: 0.4.1
```

```luce module file=.luce/packages/tint-1.2.0/luce.yaml
name: tint
version: 1.2.0

packages:
  mixer: 1.1.0
```

```luce module file=.luce/packages/tint-1.2.0/tint.luc
import mixer

func area(w: long, h: long) -> long:
    return mixer.mul(w, h)
```

```luce module file=.luce/packages/easel-0.4.1/luce.yaml
name: easel
version: 0.4.1

packages:
  mixer: 1.2.0
```

```luce module file=.luce/packages/easel-0.4.1/easel.luc
func escape() -> long:
    return 27
```

```luce module file=.luce/packages/mixer-1.1.0/luce.yaml
name: mixer
version: 1.1.0
```

```luce module file=.luce/packages/mixer-1.1.0/mixer.luc
func mul(a: long, b: long) -> long:
    return a * b
```

```luce fail
import tint

func main():
    print(string(tint.area(2, 3)))
```

```output
luce: compile failed
main.luc:1:1: package mixer is wanted at 1.1.0 by tint 1.2.0 and at 1.2.0 by easel 0.4.1; name the decision in the root luce.yaml's override: section [luce.import.diamond]
    import tint
    ^~~~~~~~~~~
```

Writing `override:` with `mixer: 1.1.0` in the root `luce.yaml`
resolves the diamond by stated decision — the pin applies to every
edge, and says so on standard error when it changes one.

What is deliberately not here yet: fetching.  There is no network, no
registry, and no lockfile — exact versions plus optional hashes in
`luce.yaml` are the lock, and the store is filled by hand until the
publishing half exists.
