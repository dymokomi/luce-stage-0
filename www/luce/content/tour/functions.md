# Functions and structs

The declaration keyword is `func`, always. Parameters are annotated,
a return type follows `->`, and a function that returns nothing simply
omits it.

```luce run
func gcd(a: long, b: long) -> long:
    var left = a
    var right = b
    while right != 0:
        let next = left % right
        left = right
        right = next
    return left

func announce(label: string, value: long):
    print(f"{label}: {value}")

func main():
    announce("gcd(1071, 462)", gcd(1071, 462))
    announce("gcd(17, 5)", gcd(17, 5))
```

```output
gcd(1071, 462): 21
gcd(17, 5): 1
```

Arguments fill parameters left to right, and a call site may name
them — `gcd(a = 1071, b = 462)` — in any order, with the first named
argument ending the positional run. A parameter may declare a
trailing default, checked at compile time and supplied when a call
omits it, so `func pad(s: string, width: long = 8)` answers both
`pad(s)` and `pad(s, 12)`. Every path through a function that declares
a return type must return, and the compiler checks that.

## Functions are values

A function type is its signature without parameter names:
`func(long) -> long`, `func(string)`, or
`func(give list(long)) -> long` when the call takes ownership. A named
function is a value wherever that type is expected, and a local holding
one is called like any other function.

```luce run
func twice(n: long) -> long:
    return n * 2

func apply(f: func(long) -> long, value: long) -> long:
    return f(value)

func main():
    let chosen: func(long) -> long = twice
    print(string(chosen(21)))
    print(string(apply((n) -> n + 1, 41)))
```

```output
42
42
```

`(n) -> n + 1` is a **lambda**: parenthesized parameter names, an
arrow, and one expression. Its parameter and answer types come from
the function type at the place it lands. With no such place the
compiler asks for an annotation.

A lambda carries no environment. It may use its parameters, functions
and file-scope constants, but not a local from the function around it;
behavior plus state is a struct with a method. A method reference is
refused for the same reason — it would carry its receiver — while a
static namespace function such as `Scale.twice` is an ordinary function
value.

Calls through values are positional because a function type has no
parameter names or defaults. Function values copy freely, compare with
`==` and `!=`, have no ordering, and `string(f)` gives the function's
name. There are first-class functions and capture-free lambdas, but no
closures.

## Structs

A `struct` is a value aggregate. Fields are annotated, construction is
by name, and copying a struct copies it.

```luce run
struct Point:
    x: double
    y: double

func main():
    let origin = Point(x = 0.0, y = 0.0)
    var here = Point(x = 3.0, y = 4.0)
    var there = here            # a copy, not a reference
    there.x = 10.0
    print(f"here {here.x},{here.y}  there {there.x},{there.y}")
    print(f"origin {origin.x},{origin.y}")
```

```output
here 3,4  there 10,4
origin 0,0
```

Every field without a default must be given a value at construction;
a field may declare one — `cursor: long = 0` — and then a
construction site that says nothing gets the declaration's value.
There is no partial initialization: a slot is written by the site or
by the declaration, always.

Within one file every field is reachable, which is what the samples
above rely on. A field may also be marked `private`, and then it is
the module's own — that is [visibility](../visibility/), later in the
tour, and it is what makes a struct opaque to the files that import
it.

## Functions inside a struct

A struct may hold functions, and they come in two kinds — told apart
by one word.

A plain member is a **method**: the struct is a type, `self` is implied,
and the receiver is the thing in front of the dot. A member written
`static func` is a **namespace function**: the struct is a folder and
there is no `self`. There is still no dispatch and no inheritance.

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

Some structs in real Luce programs have no fields at all and exist
only to group static functions. That is a legitimate namespace. A
method is called only through a value and cannot become a function
value or worker target; a static member is called through its type and
can do both.

## Nested places

Assignment targets a *place*: a name, a field, or an index, nested as
deeply as you like. The place is read once — every subscript evaluated
exactly once — and then rebuilt.

```luce run
struct Inner:
    n: long

struct Outer:
    label: string
    inner: Inner

func main():
    var box = Outer(label = "b", inner = Inner(n = 1))
    box.inner.n = 41
    box.inner.n += 1
    print(f"{box.label} {box.inner.n}")
```

```output
b 42
```

A struct may hold one of *itself* through a `Node?` field — absence is
where the recursion stops, so a linked list of value structs needs no
new machinery. That is on the [next page but one](../absence/).
