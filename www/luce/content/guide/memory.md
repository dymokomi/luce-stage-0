# Memory and ARC

Luce's source language manages memory automatically: you do not write retain,
release, move, clone, or free. Values copy; references share identity and are
reclaimed by automatic reference counting.

The useful rule is short:

> Values copy. References share one object. Automatic reference counting
> frees that object after its last reference goes away.

## Values copy

Numbers, booleans, strings, structs, enums, unions, and plain function values
are values. Assignment and function calls give the destination a value copy.

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

The two points are independent. A struct may still contain a reference; in
that case the struct itself copies while both copies may share the referenced
object.

## References share

Lists, maps, arrays, and builders are reference objects. Files and tasks are
reference resources. Assignment and parameter passing retain the same object
instead of duplicating its contents.

```luce run
func add_one(values: list[i64]):
    values.append(3)

func main():
    let first: list[i64] = [1, 2]
    let second = first
    add_one(second)
    print(f"{len(first)} {first[2]}")
```

```output
3 3
```

`first`, `second`, and the parameter temporarily name one list. Mutating the
list does not reassign any binding, so a `let` reference may still mutate its
object.

Use an ordinary value transformation when you need independent data. A list
slice creates a new list, for example:

```luce run
func main():
    let source: list[i64] = [1, 2, 3]
    let separate = source[0:len(source)]
    separate.append(4)
    print(f"{len(source)} {len(separate)}")
```

```output
3 4
```

There is no universal deep-copy operator. A list slice creates a new outer
list. Value elements copy; reference elements remain shared and are retained
by the new list.

## Structs may carry shared references

Copying a struct copies its scalar fields and retains its reference fields:

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

The titles are independent `str` values. The `values` fields refer to one
list. This value/reference distinction is part of each field's type; it is not
changed by how the enclosing struct is passed.

## The release rule

Each reference-holding place contributes a strong reference. Reassignment
releases the old value before the slot takes its new one. Leaving a function,
returning, breaking, continuing, or propagating an error releases the locals
that control-flow edge leaves behind. A temporary releases at the end of its
statement unless another place retained it.

The optimizer may remove a retain/release pair only when that cannot change
resource cleanup, traps, or any other observable result.

## Break cycles with `weak`

ARC cannot reclaim a graph whose objects keep one another alive. Mark the
back-edge as weak so it observes the object without owning it:

```luce run
struct Link:
    weak root: list[Link]?

func main():
    let root: list[Link] = [Link()]
    root[0].root = root
    let snapshot = root[0].root else [Link()]
    print(str(len(snapshot)))
```

```output
1
```

Weakness belongs to a local or field, not to a standalone type. A weak place
has an explicit optional `list`, `map`, `array`, or `builder` type and starts
as `none`. Assignment does not keep the target alive. A read of a live target
creates an ordinary owned snapshot; after the final strong reference goes
away, the weak place reads `none`.

Read once, unwrap, and use that snapshot. A separate read may happen after the
last strong reference disappears, so testing a weak place does not permanently
narrow later reads.

Files, tasks, functions, interfaces, scalars, text values, and value structs
cannot be weak targets. Weak handles also cannot cross a worker boundary.
Classes will use this same storage rule when class reference semantics ship.

## Files and tasks must close deterministically

A `file` closes at its last release. A task joins its worker at its last
release, even when no code calls `wait()`. Sharing either reference shares one
underlying resource.

## Interfaces and bound methods

A current interface value carries bound dispatch values for one concrete
struct. Each dispatch value owns its copied receiver and retains every
reference that receiver carries. Interface dispatch is read-only today.

A bound method also carries a receiver. A struct receiver is copied into the
function value; reference fields remain shared and are retained by the bound
value. The callable may outlive the binding it came from.

## Workers remain isolated

Every worker has its own runtime and heap. Values copy directly, and permitted
container graphs are rebuilt recursively in the receiving runtime. No object
identity is shared. Aliases within and between argument roots remain aliases
inside the snapshot, and the caller's graph remains independently usable.
Graphs carrying a `file`, `task`, or function value are refused as arguments
or results.

That rule makes data races over Luce objects unrepresentable without adding a
second ownership language.

## What has not shipped yet

`class` is only a compiler scaffold; mutable owned interface values and
capturing closures have not shipped. [Status](/status/) gives their order.

The [Memory Management reference](/guide/reference/memory/) gives the exact
current rules. [Concurrency](/guide/concurrency/) applies them at the worker
boundary.
