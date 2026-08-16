# Interfaces

This is the current interface contract. The owned existential representation
and mutable class dispatch planned for the ARC language are separate work in
[ROADMAP.md](ROADMAP.md).

An interface is a nominal set of method requirements. A struct opts in by
listing the interface and must implement the complete contract. A matching
struct that does not list the interface does not conform.

```luce
interface UIElement:
    func render(value: long) -> long
    func label() -> string

struct Button: UIElement:
    text: string

    func render(value: long) -> long:
        return value + 1

    func label() -> string:
        return self.text

func describe(item: UIElement) -> string:
    return item.label() + ":" + string(item.render(41))

func main():
    print(describe(Button(text = "ok")))
```

The conversion from `Button` to `UIElement` happens when the concrete value
lands in an interface-typed place. There is no cast syntax, structural
conformance, or runtime “does this type conform?” query.

## Contract matching

For each required method, the witness must agree on:

- the method name and instance status;
- the number, order, names, and types of explicit parameters;
- the number and types of returned values; and
- the failure direction.

A concrete struct may define additional methods. A static function cannot
satisfy an instance requirement. Interface requirements do not declare
default arguments.

Failure matching is directional. A non-fallible witness may satisfy a
fallible requirement because a caller may safely write `try` around a call
that never raises. A fallible witness cannot satisfy a non-fallible
requirement.

Multiple methods occupy distinct dispatch slots. Multi-value answers use the
ordinary return-shape rules and must be received by a destructuring `let`,
`var`, or assignment:

```luce
interface Measured:
    func span(value: long) -> (long, long)

struct Range: Measured:
    width: long

    func span(value: long) -> (long, long):
        return value, value + self.width

func total(item: Measured) -> long:
    let low, high = item.span(10)
    return low + high

func main():
    print(string(total(Range(width = 7))))
```

## Read-only dispatch is a current limitation

A writing struct method cannot satisfy an interface requirement today. The
compiler infers whether a method writes `self`; conformance rejects a writer
with `luce.sema.interface`.

This restriction is not the target design. It exists because the current
interface representation binds value receivers into dispatch fields. The
roadmap replaces that representation with one owned payload plus metadata and
a witness table. Only after that change may a value existential mutate its
boxed copy and a class existential mutate its shared object safely.

Mutation of a reference passed as an ordinary parameter is different. A
read-only struct witness may still mutate a `list`, `map`, or other reference
object that it receives or reaches through a field; that does not write the
struct receiver itself.

## Storage and heterogeneous collections

Interface values may be local variables, return values, optional values,
struct fields, and elements of lists, maps, and arrays. A value-only concrete
receiver is self-contained. A receiver with a reference field is subject to
the current bound-method gap: its interface dispatch values alias that graph
without retaining it, so another live value must keep the graph alive.

```luce
interface Named:
    func name() -> string

struct First: Named:
    marker: long

    func name() -> string:
        return "first"

struct Second: Named:
    marker: long

    func name() -> string:
        return "second"

func main():
    var values = new list(Named)
    values.append(First(marker = 1))
    values.append(Second(marker = 2))
    print(values[0].name())
    print(values[1].name())
```

The same collection may therefore contain different concrete structs. A
struct may list more than one interface, and each conversion selects the
contract requested by the destination type.

## Runtime shape today

The current implementation lowers an interface to a hidden value layout of
bound function values, one per method. A bound value carries the concrete
struct receiver snapshot, but current function-value release walks do not own
references inside that snapshot. Copying the interface copies the value layout
and does not repair that lifetime restriction.

This representation dispatches correctly for the proved lifetime but scales
receiver storage with method count, is not independently safe for a carrying
receiver, and cannot give mutable dispatch the semantics wanted for classes.
It is explicitly scheduled for replacement, not documented as the final ABI.

## Deliberately absent today

- interface fields and property requirements;
- default method bodies;
- interface inheritance or composition syntax;
- associated types;
- runtime casting;
- class-only interfaces; and
- generic constraints.

The executable positive specification is
[`src/luce/specs/interfaces_spec.zig`](../src/luce/specs/interfaces_spec.zig).
Conformance and call-site refusals live in
[`src/luce/specs/errors_spec.zig`](../src/luce/specs/errors_spec.zig). Any new
observable interface rule belongs in those differential specifications before
it is described here.
