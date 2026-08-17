# Memory and ARC

Luce manages memory automatically. Source code has no retain, release, move,
clone, borrow, or free operation.

The rule to keep in mind is:

> Values copy. References share identity. ARC keeps references alive. Weak
> references break cycles. Resources close at the last strong release.

## Values copy

Numbers, `bool`, `char`, `str`, `bytes`, structures, enumerations, and unions
are values. Assignment and argument passing copy them.

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

A value can contain references. Copying such a value copies its scalar fields
and retains its reference fields:

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

The structures are independent values; both `values` fields name one list.

## References share identity

Lists, maps, arrays, builders, classes, and tasks are references.
Assignment, parameters, results, optionals, fields, and container elements all
retain the same object.

```luce run
class Counter:
    value: i64

func main():
    let first = Counter(value = 1)
    let second = first
    second.value = 42
    assert(first is second)
    print(str(first.value))
```

```output
42
```

`let` prevents rebinding a name; it does not make a referenced object
immutable. A class uses `is` for identity. Built-in containers expose their
identity through sharing and mutation rather than an identity operator.

Use an operation that explicitly creates an independent outer object when
that is what the program needs. A list slice does so:

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

There is no universal deep-copy operator. The slice copies value elements and
retains reference elements, so nested reference objects remain shared.

## What ARC does

Every reference-holding place contributes one strong reference. Storing into
a new place retains the value. Replacing a place releases its old value.
Leaving a scope through return, break, continue, error propagation, or normal
fallthrough releases the locals that path abandons. A temporary releases at
the end of its statement unless another place retained it.

The final strong release destroys an ordinary object. For resources it also
performs deterministic cleanup: a `files.File` closes its descriptor, and an
unfinished `task` joins its worker and discards the unobserved answer.

A class can run its own `deinit` body at that point. The body runs once while
the fields remain alive, then the fields release. See [Classes: Finish work in
`deinit`](/guide/deinitialization/#the-last-strong-release).

## Break cycles with `weak`

ARC cannot discover an unreachable cycle of strong references. Make the
non-owning back-edge weak:

```luce run
class Node:
    value: i64
    weak parent: Node?

func main():
    weak var observed: Node?
    if true:
        let parent = Node(value = 42)
        let child = Node(value = 1, parent = parent)
        observed = parent
        assert((child.parent else child) is parent)
    print(str(observed == none))
```

```output
true
```

Weakness belongs to a mutable local, field, or closure capture. Its type is
optional because the target may already be gone. Assigning a weak place does
not retain. Reading it once creates an ordinary owned optional snapshot: a
live target becomes `T?`; a dead target becomes `none`.

Weak targets are classes, lists, maps, arrays, and builders. Values,
interfaces, function values, and tasks are not weak targets. A closure
capture list uses `[weak name]` for the same rule. Weak storage cannot cross a
worker boundary.

## Closures own their environments

A block closure retains its immutable captures and shares cells for captured
mutable locals. Its last function value releases that environment. A bound
structure method owns a receiver snapshot and retains the snapshot's reference
fields. A bound class method retains the shared class identity.

These ordinary strong edges can participate in cycles. If a class stores a
closure that refers back to the class, capture the class weakly. [Functions
and Closures](/guide/closures/#snapshot-captures) gives a complete example.

## Interfaces preserve their concrete value

An interface value owns one payload and a static witness identity for its
concrete receiver. A structure conformance owns a copied value; a class
conformance retains the class identity. A class method called through an
interface may mutate that shared object. A value-structure witness may write
through an interface only when the requirement is marked `mutating`, and the
call has a mutable bare local as its receiver. `let` bindings, temporaries,
field projections, and collection elements are not writable value places.

## Workers remain isolated

Each worker has its own runtime and heap. Permitted value and container graphs
are rebuilt in the destination runtime. Aliases inside the source graph remain
aliases inside the independent snapshot, but no object identity is shared
between caller and worker.

A class, task, function value, weak reference, interface value, or graph
containing one cannot cross the boundary. A worker may create and use its own
classes and closures locally. This keeps data races over Luce objects
unrepresentable without introducing a second ownership model.

The [Memory Management reference](/guide/reference/memory/) states every
retain, release, weak, interface, closure, resource, and worker rule precisely.
