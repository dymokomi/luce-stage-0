# Interfaces

Use an interface when the caller needs one small behavior but should not
choose which concrete type provides it. An interface is a named contract. A
struct or class opts in explicitly, and the compiler checks the whole contract
before the first value is converted.

An interface declaration contains method signatures, not storage or method
bodies:

```text
interface Name:
    func title() -> str
    func measure(width: i64) -> (i64, i64)
    func load(path: str) -> bytes!
```

The methods are the complete surface visible through an interface value.
Fields, static functions, and extra instance methods remain properties of the
concrete type.

## Start with the behavior

Keep an interface small. List the operations a caller needs, not every
operation a particular struct happens to provide:

```luce run
interface Drawable:
    func render(value: i64) -> i64
    func label() -> str

struct Button: Drawable:
    caption: str
    offset: i64

    func render(value: i64) -> i64:
        return value + self.offset

    func label() -> str:
        return self.caption

struct Badge: Drawable:
    caption: str

    func render(value: i64) -> i64:
        return value + 2

    func label() -> str:
        return self.caption

func describe(item: Drawable) -> str:
    return item.label() + ":" + str(item.render(value = 40))

func main():
    let button = Button(caption = "button", offset = 1)
    let badge = Badge(caption = "badge")
    var items = new list[Drawable]
    items.append(button)
    items.append(badge)
    print(describe(items[0]))
    print(describe(items[1]))
```

```output
button:41
badge:42
```

`Button` and `Badge` are different types, but both can be passed where
`Drawable` is expected. Each interface value remembers the implementation
that belonged to the concrete value that created it. The same pattern works
with `map[str, Drawable]`, arrays, and struct fields.

An interface is explicit polymorphism, not a base class. It supplies no
inherited implementation and creates no override relationship: every
conforming type writes each required method, and `override func` is rejected.
Use composition when you want to share code without a contract.

The conversion is implicit at an interface-typed destination. There is no
cast syntax and no structural conformance: a declaration must write
`struct Name: Drawable:` or `class Name: Drawable:`. A conforming type may
have extra methods; they are simply not visible through `Drawable`.

One type may list several independent contracts:

```text
struct Icon: Drawable, Named, Measured:
    ...
```

This is composition of requirements, not interface inheritance. A caller
that accepts `Named` sees only `Named`, even when the concrete value also
conforms to `Drawable`.

## Let the compiler check the contract

Every declared method is required. The implementation must match its name,
parameter count and order, types, result count, and result types. The receiver
is implied by the method declaration. Parameter names in the interface are the
labels callers use; witness parameter names are local implementation details.
Interface requirements cannot declare default arguments; callers only know the
contract, so every argument in that contract must be supplied.

Put `mutating` on a requirement when a value-struct witness may write `self`:

```text
interface Counter:
    mutating func add(amount: i64)
    func value() -> i64

struct Number: Counter:
    current: i64

    func add(amount: i64):
        self.current += amount

    func value() -> i64:
        return self.current
```

Concrete methods do not write `mutating`; the compiler infers receiver writes
from the body. A non-writing witness may satisfy a `mutating` requirement, but
a writing witness cannot satisfy a non-mutating requirement. Class witnesses
may mutate shared class identity regardless of the value-place rule.

A mutating call on a value interface needs a mutable bare local. A `let`
binding, call result, field projection, or collection element is not writable;
bind it to `var` first. Copies of a struct interface have independent payloads,
while class interfaces retain the same identity. A captured mutable interface
writes its updated value back through the closure cell.

Failure effects are directional. A non-fallible implementation may satisfy
a fallible requirement, so a caller may still write `try`. A fallible
implementation may not satisfy a non-fallible requirement.

An interface contains method signatures only. It cannot inherit another
interface, define a default method body, or use a generic parameter. Those
are separate language features and are not needed for the first interface
design.

The most useful diagnostics occur at the conformance declaration, before a
value reaches a caller:

| Mistake | Why it is refused |
|---|---|
| a required method is absent | the contract would have an empty dispatch slot |
| a method is `static` | an interface method needs an instance receiver |
| a parameter or result differs | the caller and witness would disagree about the call shape |
| a fallible witness satisfies a non-fallible requirement | the caller has no error path |
| a writing witness satisfies a non-mutating requirement | the contract does not permit receiver write-back |
| a mutating call uses `let`, a temporary, a projection, or an element | there is no mutable value place to receive the updated interface |

Extra concrete methods are fine because they do not change any required slot.

## Return more than one value

Interface methods use the same return-shape representation as ordinary
functions. Receive a multi-value answer with a destructuring `let`, `var`, or
assignment:

```luce run
interface Bounds:
    func limits(value: i64) -> (i64, i64)!

struct Window: Bounds:
    width: i64

    func limits(value: i64) -> (i64, i64):
        return value, value + self.width

func total(item: Bounds) -> i64!:
    let low, high = try item.limits(10)
    return low + high

func main() -> !:
    let window = Window(width = 7)
    print(str(try total(window)))
```

```output
27
```

The answer is still one call, but it is not one scalar expression. Passing
`item.limits(10)` as one argument or printing it directly is refused; bind
its components first. A fallible multi-value method follows the ordinary
`try`/`catch` rules.

## Store different concrete types together

Interface values may be locals, parameters, results, optionals, structure
fields, and list, map, or array elements. Each element carries the dispatch
for its own concrete value, so a collection can be heterogeneous without a
tag chosen by the caller.

```luce run
interface Formatter:
    func format(value: i64) -> str

struct Decimal: Formatter:
    marker: i64

    func format(value: i64) -> str:
        return str(value)

struct Brackets: Formatter:
    marker: i64

    func format(value: i64) -> str:
        return "[" + str(value) + "]"

func main():
    let decimal = Decimal(marker = 0)
    let brackets = Brackets(marker = 0)

    var formats = new map[str, Formatter]
    formats["plain"] = decimal
    formats["marked"] = brackets

    let chosen = formats.get("marked") else decimal
    print(chosen.format(42))
```

```output
[42]
```

The fallback above may have another concrete type because both sides convert
to `Formatter`. A function may likewise return one of several conforming
types as its interface result, or return `Formatter?` when no implementation
may be available.

Use a union instead when callers must know which concrete case they received.
An interface deliberately hides that choice and exposes only behavior; there
is no runtime downcast in the current language.

## Class witnesses keep shared identity

Converting a class does not take a snapshot of its fields. The interface
retains the same class identity, so a writing class method remains visible to
all aliases.

```luce run
interface Sequence:
    func next() -> i64

class Counter: Sequence:
    value: i64

    func next() -> i64:
        self.value += 1
        return self.value

func advance(sequence: Sequence) -> i64:
    return sequence.next()

func main():
    let counter = Counter(value = 40)
    print(str(advance(counter)))
    print(str(counter.value))
```

```output
41
41
```

## Values remain alive

Converting a struct to an interface value copies its concrete value into one
owned payload. Converting a class retains its shared identity. In both cases
the interface owns everything its payload can reach, even after the original
binding leaves scope. A class mutation through the interface remains visible
through every alias of that class; copied struct interfaces remain independent.

The payload is paired with a static witness identity. The number of required
methods does not copy the receiver repeatedly, and each interface value in a
heterogeneous collection carries the witness for its own concrete type. This
is an implementation detail that explains the lifetime and collection rules;
it does not add casts, reflection, or interface inheritance.

Copying an interface value retains everything its payload may reach; dropping
the last copy releases it. An interface may therefore safely leave the scope
where its concrete value was created.

The [memory guide](/guide/memory/) explains the lifetime rule. The [interface
reference](/guide/reference/types/#interface) gives the exact matching,
storage, and diagnostic rules.

## A useful boundary

Interfaces work best at a boundary where several implementations are
deliberately interchangeable: a renderer, a reader, a formatter, or a small
service supplied by a caller. They are not a replacement for a struct when
the caller needs fields, and they do not make unrelated data share a shape.

Start with the smallest contract that makes the caller simpler. Add a new
method only when every implementation really has that responsibility; a
separate interface is usually clearer than a large one with methods some
implementations cannot meaningfully provide.

An interface is usually the right boundary when:

- several implementations perform one coherent role;
- callers should not branch on the concrete implementation;
- tests benefit from supplying a small substitute; or
- a list or map needs heterogeneous values with common behavior.

It is usually the wrong boundary when one concrete structure is sufficient,
the caller needs the fields, or the alternatives themselves carry semantic
meaning better modeled by a union.

For exact syntax and every refusal, see
[Types: Interface](/guide/reference/types/#interface).
For the broader choice between structs, unions, and interfaces, see
[Structures](/guide/structures/) and [Classes](/guide/classes/).
