# Interfaces

An interface is a nominal set of instance-method requirements. A struct or
class opts in explicitly with `: Interface`; a type that merely happens to
have the same methods does not conform. The compiler checks every requirement
before it permits the value to enter an interface-typed place.

```luce
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

func describe(item: Drawable) -> str:
    return item.label() + ":" + str(item.render(40))
```

There is no cast syntax, structural conformance, runtime conformance query,
interface field, or interface constructor. Conversion is implicit when a
conforming value is assigned, passed, returned, or stored where the interface
type is required.

## Contract matching

For every requirement, the witness must have the same method name, instance
receiver, parameter count and order, parameter types, result count and result
types. The requirement's parameter names are the labels callers use; witness
parameter names are not part of the function type. Default arguments are not
allowed in an interface declaration.

Failure is directional: a non-fallible witness may satisfy a fallible
requirement, but a fallible witness cannot satisfy a non-fallible requirement.
A static method cannot witness an instance requirement. Extra concrete methods
are fine and remain hidden through the interface.

An incomplete conformance is rejected at its declaration. The diagnostic also
covers duplicate requirements, duplicate conformance entries, wrong method
shapes, and static witnesses.

## Receiver mutation

Put `mutating` on an interface requirement when callers may need to change a
value-struct receiver:

```luce
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

Concrete methods never write `mutating`; the compiler infers receiver writes
from the body. A writing witness must satisfy a `mutating` requirement. A
non-writing witness may satisfy one as well, because it does not need the
write-back path. A writing witness cannot satisfy a non-mutating requirement.

A mutating call on a value existential needs a mutable bare local, just like a
direct writing method call. A `let` binding, call result, field projection, or
collection element is not a writable place; bind it to `var` first. Struct
existentials copy independently, so copying one mutable interface value does
not connect their value payloads. Class existentials retain one shared class
identity, so class mutation remains visible through every alias. A captured
mutable interface uses its closure cell and writes the updated existential back
to that cell.

## Multiple methods and multiple results

Each requirement has its own witness slot, in declaration order. A method may
return several values using the ordinary Luce result-shape rules:

```luce
interface Bounds:
    func limits(value: i64) -> (i64, i64)!

struct Window: Bounds:
    width: i64

    func limits(value: i64) -> (i64, i64):
        return value, value + self.width

func total(item: Bounds) -> i64!:
    let low, high = try item.limits(10)
    return low + high
```

Multi-value calls must be destructured; they are not a scalar argument or
printable value. `try` follows the same rule as an ordinary fallible function.

## Storage and collections

An interface value is one owned existential payload plus a static witness
identity. The payload is a copied value-struct receiver or a retained class
object. Copying and releasing an interface therefore follow the receiver's
ordinary value/reference rules; the number of interface methods does not copy
the receiver once per method.

Interface values may be locals, parameters, results, optionals, struct fields,
and elements of lists, maps, and arrays. Each element carries its own witness,
so one collection can hold different conforming structs and classes. A type
may conform to multiple independent interfaces; choosing one destination
chooses that contract's witness.

## Deliberate non-goals

The current language does not provide interface inheritance or composition,
default method bodies, associated types, generic interface bounds, properties
or fields as requirements, or runtime casts/downcasts. These are separate
design work and are not implied by the current dispatch representation.

The executable positive specification is
[`src/luce/specs/interfaces_spec.zig`](../src/luce/specs/interfaces_spec.zig).
Conformance and call-site refusals are in
[`src/luce/specs/errors_spec.zig`](../src/luce/specs/errors_spec.zig); MIR
serialization and verifier checks are in
[`src/luce/mir/module.zig`](../src/luce/mir/module.zig) and
[`src/luce/mir/verify.zig`](../src/luce/mir/verify.zig).
