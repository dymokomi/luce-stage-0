# Classes

A class represents one object with shared identity. Use one when several parts
of a program must observe and change the same state, or when callbacks and
interfaces should keep one model alive. Use a [structure](/guide/structures/)
when assignment should make an independent outer value instead.

| Declaration | Assignment | Mutation through `let` | Comparison |
|---|---|---|---|
| `struct` | copies a value | no | value equality when its fields support it |
| `class` | retains and shares one object | yes | identity with `is` |

## Declaring a class

Fields and methods use the same member syntax as a structure. Without a custom
initializer, construction names required fields and may omit defaulted fields:

```luce run
class Counter:
    value: i64 = 0

    func add(amount: i64) -> i64:
        self.value += amount
        return self.value

func main():
    let counter = Counter()
    print(str(counter.add(2)))
    print(str(counter.add(3)))
```

```output
2
5
```

The constructor creates one ARC object. One custom `init` body may replace the
memberwise call surface and establish derived or validated fields before the
object exists. [Initialization](/guide/initialization/) covers memberwise
construction, defaults, definite initialization, fallible calls, visibility,
and the restrictions on `self` before identity is published.

## Aliases observe one object

Assignment, parameter passing, returns, fields, optionals, and collection
storage retain the same object rather than copying its fields:

```luce run
class Counter:
    value: i64

func change(counter: Counter):
    counter.value = 42

func main():
    let first = Counter(value = 1)
    let second = first
    change(second)
    print(str(first.value))
```

```output
42
```

`first`, `second`, and the parameter in `change` are three strong references
to one `Counter`. Each keeps the object alive; dropping one name does not
invalidate the others.

This is the reason to choose a class. If observing the mutation through
`first` would be surprising or incorrect, the model should probably be a
structure value instead.

## `let` keeps the binding stable

A `let` class binding cannot be rebound to another class object, but its
object remains mutable. A `var` is needed only when the name itself will later
refer to a different object:

```luce run
class Box:
    value: i64

func main():
    let stable = Box(value = 1)
    stable.value = 2

    var replaceable = Box(value = 10)
    replaceable = Box(value = 20)
    print(f"{stable.value} {replaceable.value}")
```

```output
2 20
```

This distinction keeps binding intent useful. `let` still promises that the
name’s identity does not change, even when the object intentionally has
mutable state.

## Comparing identity

`is` asks whether two values name the same object:

```luce run
class Token:
    value: i64

func main():
    let first = Token(value = 7)
    let same = first
    let separate = Token(value = 7)
    print(str(first is same))
    print(str(first is separate))
```

```output
true
false
```

Equal field contents do not make two class instances identical. Classes do
not synthesize `==`, ordering, or hashing from their fields. Compare a stable
field explicitly when the application needs value equality; use `is` only
when shared identity is the actual question.

Both operands of `is` have the same nominal class type. It is not a runtime
cast or a general pointer comparison.

## Nested value fields

A class may contain structure fields. Assigning through a nested path rebuilds
the value portion until it reaches the surrounding class identity:

```luce run
struct Point:
    x: i64
    y: i64

class Scene:
    origin: Point

func main():
    let scene = Scene(origin = Point(x = 1, y = 2))
    scene.origin.x = 40
    print(str(scene.origin.x + scene.origin.y))
```

```output
42
```

`Point` remains a value. The nested assignment installs a changed `Point` back
into the nearest mutable identity, `scene`. Copying `scene.origin` into a
separate structure binding would still produce an independent point value.

## Classes in ordinary storage

Classes may be returned, made optional, stored in structure/class fields, and
placed in lists, maps, and arrays. Every place retains the same identity:

```luce run
class Item:
    name: str
    count: i64

func find(items: list[Item], name: str) -> Item?:
    for item in items:
        if item.name == name:
            return item
    return none

func main():
    let apples = Item(name = "apple", count = 1)
    let items: list[Item] = [apples]
    let found = find(items, "apple") else Item(name = "missing", count = 0)
    found.count += 2
    print(str(apples.count))
```

```output
3
```

The list and optional result do not create independent `Item` objects. They
retain and return the same one.

## Weak relationships

ARC cannot collect an unreachable cycle of strong references. A parent may
own children strongly while each child observes its parent weakly:

```luce run
class Node:
    value: i64
    weak parent: Node?

func main():
    weak var observed: Node?
    if true:
        let parent = Node(value = 41)
        let child = Node(value = 1, parent = parent)
        observed = parent
        let live = child.parent else child
        print(str(live.value + child.value))
    print(str(observed == none))
```

```output
42
true
```

A weak field does not retain. Its type is optional because the target may be
gone. Each read produces an owned optional snapshot, so bind the read once
when several operations must use the same observed lifetime.

A class that stores a callback can form the same ownership cycle through a
closure environment. [Closures: Weak captures](/guide/closures/#weak-captures)
uses `[weak self]` to make that back-edge non-owning.

## Classes and interfaces

A class may explicitly conform to one or more interfaces. Landing it in an
interface-typed place retains the class identity, and methods called through
the interface can mutate that shared object:

```luce run
interface Adjustable:
    func adjust(amount: i64) -> i64

class Counter: Adjustable:
    value: i64

    func adjust(amount: i64) -> i64:
        self.value += amount
        return self.value

func apply(item: Adjustable, amount: i64) -> i64:
    return item.adjust(amount)

func main():
    let counter = Counter(value = 1)
    print(str(apply(counter, 41)))
    print(str(counter.value))
```

```output
42
42
```

Heterogeneous containers can hold different class and structure conformers.
Class interface values retain shared identity, so a class witness can mutate
the same object observed through other aliases. Value-struct witnesses that
write `self` require a `mutating` interface requirement and a mutable bare
local at the call site.

## Lifetime and deinitialization

ARC destroys a class after its last strong reference disappears. An optional
`deinit` body runs once while fields are still alive, then reference fields
release. Returning, storing, binding a method, capturing strongly, or converting
to an interface can all extend the lifetime because each creates a real owner.

[Deinitialization](/guide/deinitialization/) explains ordering, cleanup across
normal/error/worker paths, cycles, resource fields, and the ban on resurrecting
a dying object.

## Worker boundary

A class reference or graph containing one cannot cross `spawn` or be returned
through `wait()`. Workers have separate runtimes and never share object
identity. A worker may declare, construct, mutate, and destroy its own classes
locally.

Send plain data that describes the work, then create worker-local identity
inside the worker if needed. This keeps ordinary class programs free of data
races without adding locks to the object model.

## Deliberate limits

Classes are final. Luce has no subclassing, inheritance, `override`, `super`,
metaclasses, synthesized class equality, or initializer overload set. Reuse
comes from composition, free functions, methods, closures, and interfaces.

These limits keep construction, dispatch, identity, and ARC understandable
from the declaration in front of the reader. They can be reconsidered only
for a concrete program that cannot express its design cleanly with the
existing smaller tools.

The exact type and declaration rules are in [Types: Classes](/guide/reference/types/#classes)
and [Statements and Declarations: class](/guide/reference/statements/#class).
Continue with [Initialization](/guide/initialization/).
