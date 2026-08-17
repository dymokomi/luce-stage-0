# Methods

Methods put behavior beside the data or identity it works with. Structures,
classes, enumerations, and unions can declare instance methods; structures and
classes can also declare static functions. A method uses the same parameter,
result, default-argument, failure, and return rules as an ordinary function.

Luce supplies the receiver as an implied `self`. You do not write it in the
parameter list.

## Instance methods

Declare a method inside a type and call it with dot syntax:

```luce run
struct Rectangle:
    width: i64
    height: i64

    func area() -> i64:
        return self.width * self.height

    func scaled(factor: i64 = 2) -> Rectangle:
        return Rectangle(
            width = self.width * factor,
            height = self.height * factor,
        )

func main():
    let small = Rectangle(width = 3, height = 4)
    let large = small.scaled()
    print(f"{small.area()} {large.area()}")
```

```output
12 48
```

`self` has the enclosing type. Field access remains explicit inside a method,
which keeps the distinction between a field and a local name visible. Calls
may use positional or named arguments and may omit trailing defaults exactly
as free-function calls do.

## Reading and writing structure methods

A structure is a value. The compiler infers whether one of its methods writes
the receiver. A reading method may be called on an immutable or mutable value.
A writing method requires a mutable bare receiver so the updated structure can
be stored back into that place.

```luce run
struct Cursor:
    row: i64
    column: i64

    func move_down(lines: i64):
        self.row += lines

    func position() -> str:
        return f"{self.row}:{self.column}"

func main():
    var cursor = Cursor(row = 2, column = 5)
    cursor.move_down(3)
    print(cursor.position())
```

```output
5:5
```

A call such as `make_cursor().move_down(1)` is refused because there is no
stable value place to receive the changed structure. A writing method on a
`let` structure is refused for the same reason. Bind the value to `var` first.

Writing through a reference field is not necessarily a write to the outer
structure. Appending to a list field mutates the list object; replacing the
field would mutate `self`. The inferred effect follows the actual place that
changes.

## Class methods mutate shared identity

A class method can replace class fields through a stable `let` binding. The
binding still names the same object, so no copy-back is needed:

```luce run
class Counter:
    value: i64

    func add(amount: i64) -> i64:
        self.value += amount
        return self.value

func main():
    let first = new Counter(value = 1)
    let second = first
    print(str(second.add(41)))
    print(str(first.value))
```

```output
42
42
```

Use `var` only when the class binding itself will be replaced with another
object. Mutation of the object does not require rebinding the name.

This difference is central to API design: a writing structure method changes
one value place, while a class method changes shared identity visible through
every alias.

## Static functions

A static function belongs to the type rather than an instance. Declare it with
`static func` and call it through the type name:

```luce run
import std.strings

struct Temperature:
    celsius: f64

    static func freezing() -> Temperature:
        return Temperature(celsius = 0.0)

    static func from_fahrenheit(value: f64) -> Temperature:
        return Temperature(celsius = (value - 32.0) * 5.0 / 9.0)

func main():
    let zero = Temperature.freezing()
    let warm = Temperature.from_fahrenheit(68.0)
    print(f"{zero.celsius:.1f} {warm.celsius:.1f}")
```

```output
0.0 20.0
```

A static function has no `self`. It is useful for named construction,
validation, or operations conceptually owned by a type but not by one
instance. It cannot satisfy an instance method requirement in an interface.

## Bound methods

Reading an instance method into a matching function-typed place binds its
receiver:

```luce run
struct Scale:
    factor: i64

    func apply(value: i64) -> i64:
        return value * self.factor

class Counter:
    value: i64

    func current() -> i64:
        return self.value

func main():
    var scale = Scale(factor = 2)
    let double: func(i64) -> i64 = scale.apply
    scale.factor = 100

    let counter = new Counter(value = 1)
    let read: func() -> i64 = counter.current
    counter.value = 42

    print(str(double(3)))
    print(str(read()))
```

```output
6
42
```

A bound structure method owns a receiver snapshot, so later changes to the
original structure do not change the function. A bound class method retains
the shared class identity, so later class mutation is visible. In both cases,
the function value can outlive the local binding from which it was made.

Only the explicit parameters appear in the bound function type; `self` is
already supplied. Calls through function values are positional.

## Enum and union methods

An enumeration method can inspect the current member through comparisons or
matching. A union method can `match self` to reach the payload safely. These
methods remain value methods: a writing call needs a mutable receiver and a
reading call works on either binding kind.

Keep a method on the type when it expresses behavior or an invariant of that
type. Keep a free function free when it coordinates several unrelated values
or belongs to a module-level algorithm. Dot syntax is not a reason by itself
to hide a dependency inside a type.

## Compiler-routed library methods

Some standard-library functions are routed to method syntax after their module
is imported. `std.lists.sort_by` is the canonical example:

```luce run
import std.lists

func before(left: i64, right: i64) -> bool:
    return left < right

func main():
    var values: list[i64] = [3, 1, 2]
    values.sort_by(before)
    print(f"{values[0]} {values[1]} {values[2]}")
```

```output
1 2 3
```

The implementation remains ordinary standard-library source. Importing the
module makes the route available; calling it without the import produces a
diagnostic that names the missing module. Core operations such as `append`
and indexing are built-in methods and need no import.

## Methods and interfaces

An interface requirement is an instance method declaration without a body. A
conforming type lists the interface and supplies a compatible method. Names,
explicit parameters, results, and failure direction are checked.

A class writer can satisfy an interface because it mutates shared class
identity. A writing structure method can satisfy a `mutating` requirement; the
call must use a mutable bare local so the updated interface payload can be
written back. [Interfaces](/guide/interfaces/) explains that boundary without
changing ordinary structure method behavior.

The exact receiver and writer rules are in [Statements and Declarations:
Methods](/guide/reference/statements/#methods). Continue with
[Classes](/guide/classes/).
