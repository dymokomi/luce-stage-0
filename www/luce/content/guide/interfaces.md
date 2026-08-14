# Interfaces

Use an interface when the caller needs one small behavior but should not
choose which struct provides it. An interface is a named contract. A struct
opts in explicitly, and the compiler checks the whole contract before the
first value is converted.

## Start with the behavior

Keep an interface small. List the operations a caller needs, not every
operation a particular struct happens to provide:

```luce run
interface Drawable:
    func render(value: long) -> long
    func label() -> string

struct Button: Drawable:
    caption: string
    offset: long

    func render(value: long) -> long:
        return value + self.offset

    func label() -> string:
        return self.caption

struct Badge: Drawable:
    caption: string

    func render(value: long) -> long:
        return value + 2

    func label() -> string:
        return self.caption

func describe(item: Drawable) -> string:
    return item.label() + ":" + string(item.render(value = 40))

func main():
    let button = Button(caption = "button", offset = 1)
    let badge = Badge(caption = "badge")
    var items = new list(Drawable)
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
with `map(string, Drawable)`, arrays, and struct fields.

The conversion is implicit at an interface-typed destination. There is no
cast syntax and no structural conformance: a struct must write
`struct Name: Drawable:`. A struct may have extra methods; they are simply
not visible through `Drawable`.

## Let the compiler check the contract

Every declared method is required. The implementation must match its name,
parameter count, parameter types, `give` modes, result count, and result
types. The receiver is implied by the method declaration and interface
methods are read-only, so a method that writes `self` cannot be a witness.

Failure effects are directional. A non-fallible implementation may satisfy
a fallible requirement, so a caller may still write `try`. A fallible
implementation may not satisfy a non-fallible requirement.

An interface contains method signatures only. It cannot inherit another
interface, define a default method body, or use a generic parameter. Those
are separate language features and are not needed for the first interface
design.

## Return more than one value

Interface methods use the same return-shape representation as ordinary
functions. Receive a multi-value answer with a destructuring `let`, `var`, or
assignment:

```luce run
interface Bounds:
    func limits(value: long) -> (long, long)!

struct Window: Bounds:
    width: long

    func limits(value: long) -> (long, long):
        return value, value + self.width

func total(item: Bounds) -> long!:
    let low, high = try item.limits(10)
    return low + high

func main() -> !:
    let window = Window(width = 7)
    print(string(try total(window)))
```

```output
27
```

The answer is still one call, but it is not one scalar expression. Passing
`item.limits(10)` as one argument or printing it directly is refused; bind
its components first. A fallible multi-value method follows the ordinary
`try`/`catch` rules.

## Ownership is part of the design

An interface value owns its dispatch storage. If the concrete receiver is a
value-only struct, that receiver is independent. If the receiver contains a
list, map, array, builder, file, or task, the interface's receiver copy still
refers to the concrete owner's object graph; the interface does not create a
second owner.

Keep the concrete owner alive for as long as the interface value can be
called. A fresh object-carrying receiver cannot be retained as an interface,
and a function cannot return a carrying receiver as an interface because its
local owner would die at the return. Return the concrete owner instead, or
make a resource-free copy, store that copy in a named owner, and then create
the interface view.

The [memory guide](/guide/memory/) explains the ownership words. The
[interface reference](/guide/reference/types/#interface) gives the exact
matching, storage, and diagnostic rules.

## A useful boundary

Interfaces work best at a boundary where several implementations are
deliberately interchangeable: a renderer, a reader, a formatter, or a small
service supplied by a caller. They are not a replacement for a struct when
the caller needs fields, and they do not make unrelated data share a shape.

Start with the smallest contract that makes the caller simpler. Add a new
method only when every implementation really has that responsibility; a
separate interface is usually clearer than a large one with methods some
implementations cannot meaningfully provide.

For exact syntax and every refusal, see
[Types: Interface](/guide/reference/types/#interface).
For the broader choice between structs, unions, and interfaces, see
[Structures](/guide/structures/).
