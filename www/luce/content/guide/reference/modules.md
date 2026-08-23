# Modules

Each `.luc` file is a module. Imports are explicit, and declarations are
private to their file unless marked `pub`.

## import

```
import name             binds the sibling file `name.luc`
import std.name         binds a module embedded in the compiler
import folder.name      binds `folder/name.luc` under the project root
import folder.name as other   the same file, bound as `other`
from name import a, b   binds the named members bare
from name import a as c   the same member, bound as `c`
```

An import binds the last path segment: `import std.math` and
`import geo.math` both bind `math`. `as` chooses another module binding
name; it is contextual syntax, not a reserved keyword — and so is `from`.
This is separate from an `alias Name = Type` declaration, which names a
type rather than a module.

An import reaches the imported file's top level:

```
name.func(args)
name.Struct(field = expr, ...)
name.Struct.member(args)
name.constant
p: name.Struct              in an annotation
p: name.Alias               a `pub` type alias
```

An import exposes the imported file's `pub` top-level declarations.
Unmarked declarations remain available inside their defining file only.
Using an unimported namespace is `luce.sema.import`.

Modules may import one another; each file is loaded once, so mutual
recursion across files is allowed. A self-import is
`luce.import.self`. The graph compiles to one module artifact.

## Member imports

`from name import a, b` loads the module exactly as `import name` loads
it, and binds the named `pub` declarations bare instead of binding the
module namespace. A member may be any `pub` file-scope declaration:
function, struct, class, interface, enum, union, constant, or type alias.
`as` renames one member. There is no wildcard form.

The rules, each checked on the import line:

- an unknown member is `luce.sema.import` ("name has no declaration
  named member");
- an unexposed member is `luce.sema.private` — private is not unknown;
- a member binding that collides with a local declaration, another
  import's member, or an import's namespace binding is
  `luce.sema.duplicate`;
- a member binding may not take a reserved or builtin type name
  (`luce.sema.reserved`); rename it with `as`;
- the module namespace stays unbound: `name.other` after only a member
  import is `luce.sema.import` with the advice to `import name`. The
  whole-module and member forms may coexist in one file;
- one module keeps one binding program-wide, so `import name as other`
  in one file and `from name import a` in another still collide
  (`luce.import.collision`) — the member import claims the module's own
  last segment.

`from std.name import a` works, including `as`: the standard module
keeps-its-name rule protects the module binding, which a member import
never touches.

Errors inside an imported file render at the path it was really opened
from, with the source line and a caret.

## Visibility

A declaration is private to its file unless it says `pub`. `pub` is the
one visibility word; there is no region form, so each declaration and
member states its own visibility. The syntax and parse restrictions are
listed on [statements](../statements/#visibility).

Visibility is checked at the module boundary, not by the call graph.
Code in a module may use that module's private declarations. An outside
reference to one is `luce.sema.private`; private names are not included
in suggestions.

Every reference site checks the same bit: a call, a constant read, a
method on an imported struct's value, a type annotation, a
construction, and the `s.method(...)` string sugar that routes to
`std.strings`.

| Written, from outside | Said |
|---|---|
| `geo.helper()`, not `pub` | `helper is private to geo` |
| `geo.seed`, private constant | `seed is private to geo` |
| `p: store.Inner`, private struct | `Inner is private to store` |
| `p: store.InternalId`, private alias | `InternalId is private to store` |
| `h.slot`, private field | `slot of Handle is private to handle` |
| `session.Session(token = 7)`, private field named | `token of Session is private to session` |
| `geo.helperr`, a typo near a private name | `unknown function helperr` — and no suggestion names a private one |

```luce module file=geo.luc
func helper() -> i64:
    return 41

pub func visible() -> i64:
    return helper() + 1

const seed = 41
pub const answer = seed + 1
```

```luce fail
import geo

func main():
    print(str(geo.helper()))
```

```output
luce: compile failed
main.luc:4:15: helper is private to geo [luce.sema.private]
        print(str(geo.helper()))
                  ^~~~~~~~~~~~
```

The public surface crosses untouched — and a public constant may fold
from private ones, because the *value* crosses the boundary, not the
name:

```luce run
import geo

func main():
    print(str(geo.visible()))
    print(str(geo.answer))
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
pub struct Session:
    pub name: str
    id: i64
    token: i64 = 0

pub func open(name: str) -> Session:
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
main.luc:4:13: Session cannot be constructed here: id is private in session and has no default; construction belongs to a public function of session [luce.sema.private]
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

A `pub` declaration's surface may name only `pub` types: a `pub`
function whose parameter or result mentions a private struct is
refused at the declaration, on the line that can fix it, naming both
edits that would restore honesty. The check follows containers and
every nested parameter and result of a function type. A private
field's type is not part of the public surface and may stay private —
which is what lets a struct hide an implementation type entirely.

A `pub` constant container is a public surface too: its element or
map-value type may not be private. A private constant may use the
private type, and a `pub` folded value may still be computed from a
private constant because that exposes the value rather than its name.

A `pub` type alias is itself part of the module surface. It may name or
re-export a `pub` local or imported type. It may not expose a private nominal
type; the declaration is refused with the two available fixes. A private
alias may name a private type and remains usable throughout its own
file.

```luce fail
struct Inner:
    n: i64

pub func read() -> Inner:
    return Inner(n = 1)

func main():
    print(str(read().n))
```

```output
luce: compile failed
main.luc:4:20: read is public and answers Inner, which is private in this file; remove pub from read or mark Inner pub [luce.sema.private]
    pub func read() -> Inner:
                       ^~~~~
```

`main` never needs marking. The runtime starts it by name rather than
through an import, so the default — private, like any unmarked
declaration — is exactly right, and `pub` on it is inert.

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

Deliberately absent at this level: arbitrary search paths, conditional
imports, wildcard imports, and executable import bodies. Project and package
resolution are defined below; registry fetch and upload remain unavailable.

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
main.luc:1:1: there is no standard module std.nope; the standard library is std.io, std.math, std.files, std.strings, std.lists, std.paths, std.os, std.term, std.zip, std.json, std.gpu, std.ui, std.network, std.http, std.build, std.c [luce.import.standard]
    import std.nope
    ^~~~~~~~~~~~~~~
```

Standard modules are ordinary Luce source embedded in the compiler.
They obey every language rule including the host gate: `import
std.files` inside a program compiled without host access is a compile
error, because file access genuinely does not exist there.

The modules are [`io`](/library/io/), [`math`](/library/math/),
[`strings`](/library/strings/), [`files`](/library/files/),
[`lists`](/library/lists/), [`paths`](/library/paths/),
[`os`](/library/os/), [`term`](/library/term/), [`zip`](/library/zip/),
[`json`](/library/json/), [`gpu`](/library/gpu/), [`ui`](/library/ui/),
[`network`](/library/network/) and [`http`](/library/http/).
`std.lists` currently contributes the routed
`xs.sort_by(before)` method rather than a namespace function.

## Multi-file programs

```luce module file=shapes.luc
pub const unit = 1.0

pub struct Rect:
    pub width: f64
    pub height: f64

    pub static func area(r: Rect) -> f64:
        return r.width * r.height

pub func square(side: f64) -> Rect:
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
    print(str(shapes.area(3.0, 4.0)))
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
pub func area(width: f64, height: f64) -> f64:
    return width * height
```

```luce run
import geo.shapes

func main():
    print(str(shapes.area(3.0, 4.0)))
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
pub func volume(edge: f64) -> f64:
    return edge * edge * edge
```

```luce fail
import geo.shapes
import blocks.shapes

func main():
    print(str(shapes.area(3.0, 4.0)))
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
    print(str(shapes.area(3.0, 4.0)))
    print(str(blocks.volume(2.0)))
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
editing the number.  There are two places a package can live:

- while you author it, use a direct source directory such as `paint/`
  beside `main.luc` and point the root want at it with `path:paint`;
- when it is installed, use a directory named `NAME-VERSION` in the
  project's store, `.luce/packages/`.  The store is filled by hand today
  (`cp -r` a checkout, a git submodule): vendoring is just the store with no
  tooling.

Both forms contain a `luce.yaml` of their own, with `name` and `version`.
The source form does not need a version suffix in its directory.  The
installed form must agree with the want, its directory name, and its own
manifest, or the package is refused by name.  Edit the source directory;
do not edit an installed copy.  When a package manager exists, promotion
from the source form to the installed form is the boundary where it can
verify hashes and publish the package.

The local authoring commands keep the two manifests in step:

```text
luce package NAME() [VERSION]
luce package version NAME VERSION
luce package publish NAME
```

`new` creates a direct `NAME/` source folder, its manifest and entry module,
and adds a root want with `path:NAME`. `version` updates the package manifest
and that root want together. `publish` currently refuses because no registry
or upload protocol is configured; it is not a fake network operation.

For example, a source package can start as:

```text
project/
├── luce.yaml
├── main.luc
└── paint/
    ├── luce.yaml
    ├── paint.luc
    └── brushes.luc
```

```yaml
packages:
  paint: 0.3.0 path:paint
```

When that package is installed, the same source files are under
`.luce/packages/paint-0.3.0/` and the root want drops `path:`.

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

pub func area(r: brushes.Rect) -> i64:
    return util.scale(r.width * r.height)
```

```luce module file=.luce/packages/paint-0.3.0/brushes.luc
pub struct Rect:
    pub width: i64
    pub height: i64
```

```luce module file=.luce/packages/paint-0.3.0/util.luc
pub func scale(v: i64) -> i64:
    return v * 10
```

```luce run
import paint
import paint.brushes

func main():
    let r = brushes.Rect(width = 2, height = 3)
    print("area " + str(paint.area(r)))
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

pub func area(w: i64, h: i64) -> i64:
    return mixer.mul(w, h)
```

```luce module file=.luce/packages/easel-0.4.1/luce.yaml
name: easel
version: 0.4.1

packages:
  mixer: 1.2.0
```

```luce module file=.luce/packages/easel-0.4.1/easel.luc
pub func escape() -> i64:
    return 27
```

```luce module file=.luce/packages/mixer-1.1.0/luce.yaml
name: mixer
version: 1.1.0
```

```luce module file=.luce/packages/mixer-1.1.0/mixer.luc
pub func mul(a: i64, b: i64) -> i64:
    return a * b
```

```luce fail
import tint

func main():
    print(str(tint.area(2, 3)))
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
