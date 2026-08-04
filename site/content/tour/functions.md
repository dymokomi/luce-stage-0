# Functions and structs

The declaration keyword is `func`, always. Parameters are annotated,
a return type follows `->`, and a function that returns nothing simply
omits it.

```luce run
func gcd(a: Int, b: Int) -> Int:
    var left = a
    var right = b
    while right != 0:
        let next = left % right
        left = right
        right = next
    return left

func announce(label: String, value: Int):
    print(f"{label}: {value}")

func main():
    announce("gcd(1071, 462)", gcd(1071, 462))
    announce("gcd(17, 5)", gcd(17, 5))
```

```output
gcd(1071, 462): 21
gcd(17, 5): 1
```

Arguments are positional. There are no default values and no named
arguments. Every path through a function that declares a return type
must return, and the compiler checks that.

Functions are not values: there are no first-class functions, no
closures and no function pointers. A name in call position is a
function, statically.

## Structs

A `struct` is a value aggregate. Fields are annotated, construction is
by name, and copying a struct copies it.

```luce run
struct Point:
    x: Float
    y: Float

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

Every field must be given a value at construction; there is no partial
initialization and no default.

## Functions inside a struct

A struct may hold functions. They are plain functions in the struct's
namespace — not methods. There is no receiver, no `self`, no dispatch
and no inheritance; `Point.length(p)` is a name.

```luce run
struct Point:
    x: Float
    y: Float

    func length(p: Point) -> Float:
        return sqrt(p.x * p.x + p.y * p.y)

    func plus(a: Point, b: Point) -> Point:
        return Point(x = a.x + b.x, y = a.y + b.y)

func main():
    let a = Point(x = 3.0, y = 4.0)
    let b = Point(x = 1.0, y = 2.0)
    print(String(Point.length(a)))
    let sum = Point.plus(a, b)
    print(f"({sum.x}, {sum.y}) has length {Point.length(sum)}")
```

```output
5
(4, 6) has length 7.211102550927978
```

Some structs in real Luce programs have no fields at all and exist
only to group functions — that is a legitimate use, and the
[status page](/status/) is honest that it is also a sign that
user-defined receivers are missing.

## Nested places

Assignment targets a *place*: a name, a field, or an index, nested as
deeply as you like. The place is read once — every subscript evaluated
exactly once — and then rebuilt.

```luce run
struct Inner:
    n: Int

struct Outer:
    label: String
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
