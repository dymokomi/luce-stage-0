# Classes

A class represents one object with shared identity. Use a class when several
parts of a program must observe and change the same state. Use a
[structure](/guide/structures/) when assignment should make an independent
value instead.

The distinction is small and deliberate:

| Declaration | Assignment | Mutation through `let` | Comparison |
|---|---|---|---|
| `struct` | copies a value | no | value equality, when its fields support it |
| `class` | shares one object | yes | identity with `is` |

## Declare and construct a class

Fields and methods look like structure members. Construction names every
required field:

```luce run
class Counter:
    count: i64

    func add(amount: i64) -> i64:
        self.count += amount
        return self.count

func main():
    let first = Counter(count = 1)
    let second = first
    print(str(second.add(41)))
    print(str(first.count))
```

```output
42
42
```

`first` and `second` name the same object. The `let` prevents rebinding either
name; it does not freeze the object. Use `var` only when the binding itself
must later name another object.

Fields without defaults are required. Fields with defaults may be omitted.
Construction is memberwise: Luce does not currently have custom initializer
bodies.

## Compare identity with `is`

Two independently constructed objects remain distinct even when their fields
have equal values:

```luce run
class Token:
    value: i64

func main():
    let first = Token(value = 7)
    let same = first
    let separate = Token(value = 7)
    assert(first is same)
    assert(not (first is separate))
    print("two identities")
```

```output
two identities
```

Both operands of `is` must have the same nominal class type. Luce does not
synthesize `==`, ordering, or hashing for classes. Compare a stable field when
the program needs value equality.

## Classes fit ordinary storage

A class reference can be a parameter, result, optional, field, or element of a
list, map, or array. Every such place retains the same object. Removing or
replacing the value releases that reference.

Classes can conform to interfaces, including interfaces whose methods mutate
the object:

```luce run
interface Incrementing:
    func add(amount: i64) -> i64

class Counter: Incrementing:
    count: i64

    func add(amount: i64) -> i64:
        self.count += amount
        return self.count

func apply(item: Incrementing, amount: i64) -> i64:
    return item.add(amount)

func main():
    let counter = Counter(count = 1)
    let items = new list[Incrementing]
    items.append(counter)
    print(str(apply(items[0], 41)))
    print(str(counter.count))
```

```output
42
42
```

The interface value retains the class identity, so mutation through the
interface is visible through `counter`.

## Break cycles with `weak`

Automatic reference counting cannot reclaim a cycle made entirely of strong
references. Mark a back-edge `weak` when observing its target must not keep
that target alive:

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

A weak place is optional. Reading it takes one owned snapshot: a live target
becomes `T?`; after the last strong reference disappears it reads `none`.
Stored closures can create the same kind of cycle, so a capture list can use
`[weak self]` or another class name. [Functions and
Closures](/guide/functions/#capture-lists) shows that form.

## Finish work in `deinit`

A class may declare one bare `deinit` body. It runs exactly once at the last
strong release, while the object's fields are still alive. Those fields are
released after the body returns.

```luce run
class Resource:
    name: str

    deinit:
        print("closed " + self.name)

func main():
    if true:
        let first = Resource(name = "cache")
        let second = first
        assert(first is second)
    print("after")
```

```output
closed cache
after
```

`deinit` has no parameters, result, fallibility marker, visibility, or direct
call syntax. It may inspect and update fields or call methods. It cannot make
the dying object strongly reachable again; resurrection is rejected by the
compiler and defended by the runtime.

## Deliberate limits

Classes are final. There is no inheritance, `override`, `super`, custom
initializer, computed property, synthesized equality, or class metatype.
Reuse behavior with composition and nominal interfaces.

Continue with [Constants](/guide/constants/), or read the exact [class type
rules](/guide/reference/types/#classes) and [ARC
rules](/guide/reference/memory/).
