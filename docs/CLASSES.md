# Classes

A `class` is a final ARC reference type. A class value names one object with
stable identity; assigning it, passing it, returning it, or storing it retains
and shares that object. The object is destroyed after its last strong
reference disappears.

This is the distinction from a `struct`:

| Declaration | Assignment | Mutation through `let` | Comparison |
|---|---|---|---|
| `struct` | copies the value | no | value equality when every field supports it |
| `class` | shares one object | yes | identity with `is` |

## Declaring and constructing a class

A class declares fields, methods, defaults, and visibility with the same
member grammar as a structure. Without an `init` body, construction is
memberwise:

```luce
class Counter:
    count: i64

    func add(amount: i64) -> i64:
        self.count += amount
        return self.count

func main():
    let first = Counter(count = 1)
    let second = first
    assert(second.add(41) == 42)
    assert(first.count == 42)
```

`first` is an immutable binding: it cannot be rebound to another `Counter`.
The object it names is mutable, so a method or field assignment may change
that object through either alias. A `var` is needed only when the binding
itself must later name a different object.

Fields without defaults must be supplied to the memberwise constructor.
Defaulted and private fields follow the structure rules.

## Custom initialization

One `init(parameters)` body replaces the memberwise constructor with a
purpose-built call surface:

```luce
class Rectangle:
    label: str = "rectangle"
    width: i64
    height: i64
    area: i64

    init(width: i64, height: i64 = 1):
        self.width = width
        self.height = height
        self.area = self.width * self.height

func main():
    let rectangle = Rectangle(6, height = 7)
    assert(rectangle.label == "rectangle")
    assert(rectangle.area == 42)
```

Initializer parameters use the ordinary argument rules: their types are
explicit, defaults are trailing, and a call may be positional or switch once
to names. Call the class name, not `Class.init`. The initializer's visibility
controls whether another module may construct the class. A private initializer
can therefore expose construction through a public static function.

Every successful path must establish every stored field. A declared field
default and a weak field's implicit `none` count as established. A field may
be read or updated only after the current path has assigned it. Assignments in
both arms of an `if` or exhaustive `match` establish a field after the branch;
an assignment inside a loop does not, because the loop may run zero times.
The compiler reports all fields still missing at a bare `return` or at the end
of the body.

`self` is deliberately narrow during `init`: it may only read or assign stored
fields. The class identity does not exist yet, so `self` cannot be passed,
returned, captured, replaced, or used to call an instance method. A static
function is the appropriate reusable helper. On success the compiler creates
the object once, with every field present; an initializer that fails never
publishes a partly initialized object and never runs `deinit`.

A fallible initializer writes `-> !` and uses the ordinary `try`/`catch`
rules:

```luce
class Port:
    number: i64

    init(number: i64) -> !:
        if number < 1:
            error("port must be positive")
        self.number = number

func open() -> Port!:
    return try Port(8080)
```

`init` answers the finished class implicitly. A written early return is bare
`return`; an explicit return value is invalid. Luce has one initializer per
class, not overloads, delegation, inheritance-oriented phases, or a second
partially initialized object model.

## Identity

`is` asks whether two values name the same object:

```luce
class Token:
    value: i64

func main():
    let first = Token(value = 7)
    let same = first
    let separate = Token(value = 7)
    assert(first is same)
    assert(not (first is separate))
```

Both operands of `is` must have the same nominal class type. Classes do not
synthesize `==`, ordering, or hashing from their fields. Compare a stable
field explicitly when the program needs value equality; use `is` when object
identity is the question.

## Methods, nested places, and bound methods

An instance method has an implied `self`. Class methods may write fields even
when the receiver binding is a `let`. A nested assignment rebuilds intervening
value fields until it reaches the nearest class identity:

```luce
struct Point:
    x: i64
    y: i64

class Scene:
    point: Point

func main():
    let scene = Scene(point = Point(x = 1, y = 2))
    scene.point.x = 40
    assert(scene.point.x + scene.point.y == 42)
```

`object.method` may land in a matching function-typed place. The resulting
bound method retains the class object and observes later mutations of that
same identity. [BINDING.md](BINDING.md) specifies function storage and calls.

## Interfaces and ordinary storage

A class opts into an interface by listing it after its name. A class witness
may mutate the shared object:

```luce
interface Incrementing:
    func add(amount: i64) -> i64

class Counter: Incrementing:
    count: i64

    func add(amount: i64) -> i64:
        self.count += amount
        return self.count

func apply(item: Incrementing) -> i64:
    return item.add(1)

func main():
    let counter = Counter(count = 41)
    assert(apply(counter) == 42)
    assert(counter.count == 42)
```

Class references may be parameters, results, fields, optionals, interface
values, and elements of lists, maps, and arrays. Every such place owns one
strong reference. Removing or replacing the value releases that reference.
Class objects cannot cross a worker boundary; a worker may construct and use
its own classes inside its private runtime.

## Weak references and cycles

ARC does not collect a strong cycle. A class back-edge that must not keep its
target alive is declared `weak` and therefore has an optional type:

```luce
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
        assert(live.value + child.value == 42)
    assert(observed == none)
```

A weak assignment does not retain its target. Each read produces an owned
optional snapshot: a live target becomes `T?`, and a dead target reads `none`.
Capture a class weakly with `[weak self]` or `[weak model]` when a stored
closure would otherwise point strongly back to its owner.

## Destruction

A class may declare one bare `deinit` body. ARC runs it exactly once, at the
last strong release, while all fields are still alive. Fields release after
the body returns:

```luce
class Resource:
    name: str

    deinit:
        print("closed " + self.name)

func main():
    if true:
        let resource = Resource(name = "cache")
        let same = resource
        assert(resource is same)
    print("after")
```

`deinit` has no parameters, result, fallibility marker, visibility, or direct
call syntax. It may read and mutate the dying object's fields and call its
methods. It may store `self` weakly, but it may not create a new strong
reference to `self`; resurrection is refused at compile time and defended by
the runtime. A trap in `deinit` is a program trap with the ordinary call trace.

## Deliberate boundaries

The current class model has no inheritance, `override`, `super`, synthesized
equality or hashing, initializer overloads or delegation, computed properties,
or class metatypes. Reuse is composition plus nominal interfaces. These are
explicit boundaries, not partially implemented alternate object models.

Positive behavior is exercised in
[`src/luce/specs/classes_spec.zig`](../src/luce/specs/classes_spec.zig); class
misuse and lifecycle refusals live in
[`src/luce/specs/errors_spec.zig`](../src/luce/specs/errors_spec.zig).
