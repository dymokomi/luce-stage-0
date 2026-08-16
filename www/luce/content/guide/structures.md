# Structures and Methods

Use a `struct` when a value has a small, known set of fields that belong
together. A struct gives those fields names, gives callers a type to name,
and gives you one place for the operations that preserve the value's
invariants.

Use a `list` when order and repetition are the point. Use a `map` when the
keys are discovered at runtime. Use an `enum` when the value is one of a
fixed set of names with no payload, and a [union](/guide/unions/) when its
alternatives carry different data.

## Start with the data shape

Fields are declared with their types. Construction names the fields, which
makes a call readable and keeps it correct when a struct has several values
of the same type. A field with a default may be omitted.

```text
struct Point:
    x: double
    y: double
```

The important property is value semantics: copying a struct copies its value
fields. If a field contains a list, map, array, builder, file, or task, ARC
retains that reference. Both struct values then reach the same object; copying
the struct does not silently clone it.

## Put behavior beside the fields

An ordinary method has an implied `self` and is called through an instance.
A `static func` has no receiver and is called through the struct name. Keep
methods small and make them express the invariant rather than expose a
sequence of field writes to every caller.

```luce run
struct Point:
    x: double
    y: double

    func length() -> double:
        return sqrt(self.x * self.x + self.y * self.y)

    static func plus(a: Point, b: Point) -> Point:
        return Point(x = a.x + b.x, y = a.y + b.y)

func main():
    let a = Point(x = 3.0, y = 4.0)
    let b = Point(x = 1.0, y = 2.0)
    print(string(a.length()))
    let sum = Point.plus(a, b)
    print(f"({sum.x}, {sum.y}) has length {sum.length()}")
```

```output
5
(4, 6) has length 7.211102550927978
```

Choose a method when the receiver is part of the operation. Choose a
static function for a constructor-like operation or an operation involving
several independent values. A function value can hold either a named
function or a bound method; a bound method of a value-only struct captures
the receiver's value at the point it is read.

## Let several structs share a contract

When several structs should answer the same small question, use an interface
as the boundary between the caller and the implementation. The contract,
multi-value returns, heterogeneous collections, and lifetime rules are
explained in [Interfaces](/guide/interfaces/). Keep this
page focused on the data shape; use that chapter when the design question is
which behavior belongs behind a shared type.

## Decide who may construct the value

Declarations are public unless marked `private`. A private field is useful
when callers must go through a factory or method to get a valid value. A
private field with a default can still be filled by outside construction; a
private field without a default makes outside construction illegal, so the
module must expose a public factory.

This is a design boundary, not just an access check:

1. Keep the representation fields private.
2. Expose a public function that validates input and constructs the struct.
3. Expose methods that preserve the invariant after construction.
4. Keep private helpers and implementation types behind the module boundary.

The [Access Control](/guide/access-control/) chapter shows the smallest
example; the [module reference](/guide/reference/modules/#visibility) lists every boundary
that visibility checks, including fields, types, constants, and function
signatures.

## Nested assignment

Fields and indexes are assignable places. A place can be nested, and a
compound assignment evaluates it once:

```luce run
struct Inner:
    value: long

struct Outer:
    label: string
    inner: Inner

func main():
    var box = Outer(label = "answer", inner = Inner(value = 1))
    box.inner.value = 41
    box.inner.value += 1
    print(f"{box.label}: {box.inner.value}")
```

```output
answer: 42
```

## Structures that carry references

A struct containing a `list`, `map`, `array`, `builder`, `file`, or `task` is a
reference-carrying value. The struct still copies as a value, while ARC keeps
each referenced object alive. Passing or returning the struct preserves those
shared identities.

Construction needs no transfer syntax:

```text
var labels = ["new", "ready"]
let job = Job(labels = labels)
```

`job.labels` and `labels` now refer to the same list. Use
`labels[0:len(labels)]` when the field needs an independent list. [Memory and
ARC](/guide/memory/) explains sharing, replacement, and the deterministic
resource-cleanup contract that the current ARC completion phase must finish.

## A practical review

Before adding a struct, ask:

- Are these fields always meaningful together?
- Which operations must preserve an invariant?
- Should callers construct the value directly, or use a factory?
- Does a field carry a reference, and should that object be shared?
- Would a union or enum describe the alternatives more honestly?

If the answers are unclear, keep the data local until the shape becomes
stable. A struct is most useful when it makes an invalid state difficult to
express, not when it merely renames a handful of unrelated variables.

For the exact grammar, defaults, methods, visibility regions, and assignment
rules, use [Statements and Declarations](/guide/reference/statements/),
[Types](/guide/reference/types/), and
[Expressions](/guide/reference/expressions/).
