# Structures

A structure groups related fields into one value. Use one when assignment and
parameter passing should produce an independent outer value and when the data
has no shared object identity of its own.

Structures are the ordinary building blocks for coordinates, configuration,
parsed records, small state descriptions, and values returned from a module.

## Declaring and constructing a structure

Fields state their types inside a `struct` declaration. Construct a value by
naming every required field:

```luce run
struct Point:
    x: i64
    y: i64

func distance_squared(point: Point) -> i64:
    return point.x * point.x + point.y * point.y

func main():
    let point = Point(y = 4, x = 3)
    print(f"{point.x},{point.y}: {distance_squared(point)}")
```

```output
3,4: 25
```

Named construction makes the relationship between each argument and field
visible, and argument order does not need to repeat declaration order. A
missing, duplicated, unknown, or wrongly typed field is reported at the
construction.

Fields can have folded defaults:

```luce run
struct Request:
    path: str
    retries: i64 = 3
    verbose: bool = false

func main():
    let normal = Request(path = "/status")
    let loud = Request(verbose = true, path = "/debug", retries = 1)
    print(f"{normal.retries} {loud.verbose}")
```

```output
3 true
```

Defaults are part of the declaration and may be omitted by callers. Structure
construction does not run a custom initializer; classes own the current
custom-`init` feature.

## Structures are values

Assigning, passing, or returning a structure copies the outer value. Changing
one copy does not change another:

```luce run
struct Point:
    x: i64
    y: i64

func main():
    var first = Point(x = 2, y = 3)
    var second = first
    second.x = 10
    print(f"{first.x} {second.x}")
```

```output
2 10
```

The assignment creates another `Point`; it does not create a second name for
one point object. A structure has no reference identity, so `is` does not apply
to it.

When every field supports equality, structure equality compares the value.
That is different from class identity: two independently built structures with
the same fields are equal values, while two independently built classes remain
separate objects.

## Mutability belongs to the place

A `let` structure binding cannot have one of its fields replaced. A `var`
binding can:

```luce run
struct Point:
    x: i64
    y: i64

struct Scene:
    origin: Point
    title: str

func main():
    var scene = Scene(origin = Point(x = 1, y = 2), title = "draft")
    scene.origin.x = 40
    scene.title = "ready"
    print(f"{scene.title}: {scene.origin.x + scene.origin.y}")
```

```output
ready: 42
```

For nested value fields, Luce rebuilds the changed path back to the mutable
root. If `scene` were `let`, there would be no mutable outer place to receive
that rebuilt value.

The same rule applies to a writing structure method. A reading method can use
either binding; a writer needs a mutable bare receiver. [Methods](/guide/methods/)
explains the inferred receiver effect and bound-method behavior.

## Reference fields remain shared

A structure may contain lists, maps, arrays, classes, files, tasks, closures,
or other references. Copying the structure copies its value fields and retains
the same referenced objects:

```luce run
struct Model:
    title: str
    values: list[i64]

func main():
    var first = Model(title = "first", values = [1])
    var second = first
    second.title = "second"
    second.values.append(2)
    print(f"{first.title} {second.title}")
    print(f"{len(first.values)} {len(second.values)}")
```

```output
first second
2 2
```

The two `Model` values have independent `title` fields. Their `values` fields
are aliases of one list object. This is a shallow value copy with correct ARC,
not a recursive deep clone.

Choose a fresh reference object explicitly when the copies should stop
sharing it. There is no universal deep-copy operator because applications
need different answers for nested identity, resources, callbacks, and cycles.

## Zero values and late declaration

Scalar and aggregate fields have defined zero values where their types do.
Local `var` declarations can use a type annotation without an initializer and
begin at that zero. Function and interface values have no meaningful zero, so
they require an initializer or an optional type when absence is part of the
model.

A good structure usually constructs all conceptually required state at once.
Use late zero initialization for algorithms that genuinely fill a result in
steps, not to recreate a partially initialized object convention.

## Visibility and module boundaries

Structure declarations and fields are public by default. `private` can keep a
declaration, individual field, or a field region inside its source file. A
public signature cannot expose a private type.

Private fields let a module preserve an invariant while returning the
structure value through a public function or static factory. Another module
may hold, pass, return, and store that value without being able to name the
private field.

[Access Control](/guide/access-control/) covers field regions, public
signatures, construction, and import diagnostics in detail.

## Structures and interfaces

A structure can opt into one or more interfaces by listing them after its
name. The compiler checks that every required method is present with compatible
parameters, results, and fallibility. Landing the structure in an
interface-typed place owns a receiver snapshot and retains reference fields in
that snapshot.

Read-only structure witnesses work in locals, returns, fields, optionals, and
heterogeneous containers. A writing structure method is not yet an interface
witness because the current interface representation does not provide one
mutable boxed payload. Ordinary writing structure methods are fully supported.

See [Interfaces](/guide/interfaces/) for conformance and dispatch, and
[Status](/status/#interfaces) for the planned owned-existential improvement.

## Choosing another type

Use a structure when the whole value should copy. Choose another declaration
when the model says something else:

- use a [class](/guide/classes/) when several parts of a program must observe
  and mutate one identity;
- use an [enumeration](/guide/enums/) for one value from a closed set of names;
- use a [union](/guide/unions/) when a value can have several payload shapes;
  and
- use an [interface](/guide/interfaces/) when several concrete types share a
  behavioral contract.

Avoid turning every group of fields into a class. Shared identity is useful,
but it also introduces aliasing and possible cycles. A value structure is the
simpler model when independent copies are correct.

The exact structure declaration, construction, assignment, and visibility
rules are in [Statements and Declarations](/guide/reference/statements/).
Continue with [Methods](/guide/methods/).
