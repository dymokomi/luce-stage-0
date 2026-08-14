# Structures: keep data and invariants together

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

The complete construction and copy example is in [Structs](/guide/structs/).
The important property is value semantics: copying a struct copies its
value fields. If a field contains a list, map, array, builder, file, or task,
the struct carries that object and follows the ordinary [ownership
rules](/guide/memory/); copying the struct does not silently deep-copy the
object.

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

The [visibility chapter](/guide/reference/modules/) shows the smallest example;
the [module reference](/guide/reference/modules/#visibility) lists every boundary
that visibility checks, including fields, types, constants, and function
signatures.

## Structs that carry objects

A struct containing a `list`, `map`, `array`, `builder`, `file`, or `task` is
an object-carrying value. The struct itself is still a value, but its object
fields have an owner and a lifetime. Passing the struct by value preserves
the alias to those fields; it does not create an accidental second owner.

When a struct is the new owner of a named object, say so at the boundary:

```text
var labels = ["new", "ready"]
let job = Job(labels = give labels)
```

Use `copy labels` when the new struct needs an independent object. Use a
borrow when a function only needs to inspect or mutate an object during the
call. The [memory guide](/guide/memory/) explains the four ownership words
and the [ownership reference](/guide/reference/ownership/) gives the exact rule
for each place a struct can occur.

## A practical review

Before adding a struct, ask:

- Are these fields always meaningful together?
- Which operations must preserve an invariant?
- Should callers construct the value directly, or use a factory?
- Does a field carry an object, and where is that object transferred?
- Would a union or enum describe the alternatives more honestly?

If the answers are unclear, keep the data local until the shape becomes
stable. A struct is most useful when it makes an invalid state difficult to
express, not when it merely renames a handful of unrelated variables.

For the exact grammar, defaults, methods, visibility regions, and assignment
rules, use [Statements and declarations](/guide/reference/statements/), [Types](/guide/reference/types/),
and [Expressions](/guide/reference/expressions/).
