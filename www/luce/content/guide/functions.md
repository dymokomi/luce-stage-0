# Functions and structs

Functions define reusable work. Parameters have types, a return type
follows `->`, and a function with no return value omits it. A return value
must be produced on every path.

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

Arguments are positional by default. Callers may use parameter names, and
trailing parameters may have compile-time defaults, for example
`func pad(s: string, width: long = 8) -> string`. Named arguments can be
reordered, but positional arguments must come first.

## Functions are values

A function's value type contains its parameter and return types, not
parameter names. Named functions and capture-free lambdas can be passed to
another function.

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

`(n) -> n + 1` is a lambda. Its types come from the function type at the
place where it is used. A lambda can use its parameters, named functions,
and file-scope constants. It cannot capture a local variable. Luce has
function values and lambdas, but not closures.

Calls through a function value are positional. Function values do not have
equality or ordering; use a separate value if the program needs an identity.

## Bound methods

A method can become a function value when its receiver is read in a context
that expects one. The receiver is copied when it is a value-only struct:

```luce run
struct Scale:
    factor: long

    func times(n: long) -> long:
        return n * self.factor

func apply(f: func(long) -> long, value: long) -> long:
    return f(value)

func main():
    let doubling = Scale(factor = 2)
    let tripling = Scale(factor = 3)
    print(string(apply(doubling.times, 21)))
    print(string(apply(tripling.times, 21)))
```

```output
42
63
```

The receiver snapshot is independent of a later change to the original:

```luce run
struct Scale:
    factor: long

    func times(n: long) -> long:
        return n * self.factor

func main():
    var scale = Scale(factor = 2)
    let doubling: func(long) -> long = scale.times
    scale.factor = 100
    print(string(doubling(3)))
    print(string(scale.times(3)))
```

```output
6
300
```

When the receiver contains a container, the receiver's value copy still
refers to that container. The bound method therefore borrows the object:

```luce run
struct Bag:
    items: list(long)

    func at(i: long) -> long:
        return self.items[i]

func main():
    var bag = Bag(items = [7, 8])
    let read: func(long) -> long = bag.at
    print(string(read(0)))
    bag.items.append(99)
    print(string(read(2)))
```

```output
7
99
```

The bound value does not own the receiver's objects. Keep the receiver
alive for as long as the bound value may be called.

## Storing a function value

Function types have no zero value, so an optional is the storable form when
a slot may be empty. Parentheses distinguish an optional function from a
function whose result is optional: `(func(long) -> long)?` versus
`func(long) -> long?`.

```luce run
struct Scale:
    factor: long

    func times(n: long) -> long:
        return n * self.factor

struct Step:
    name: string
    action: (func(long) -> long)?

func main():
    let three = Scale(factor = 3)
    let steps = [
        Step(name = "triple", action = three.times),
        Step(name = "nothing", action = none),
    ]
    for step in steps:
        let action = step.action
        if action != none:
            print(step.name + " " + string(action(7)))
        else:
            print(step.name)
```

```output
triple 21
nothing
```

An optional function is narrowed in the same way as any other optional.

## Structs

A `struct` is a value aggregate. Fields are named and typed; fields with a
default may be omitted at construction. Copying a struct copies its value
fields and follows the ownership rules for any fields that hold objects.

```luce run
struct Point:
    x: double
    y: double

func main():
    let origin = Point(x = 0.0, y = 0.0)
    var here = Point(x = 3.0, y = 4.0)
    var there = here
    there.x = 10.0
    print(f"here {here.x},{here.y}  there {there.x},{there.y}")
    print(f"origin {origin.x},{origin.y}")
```

```output
here 3,4  there 10,4
origin 0,0
```

## Methods and static functions

An ordinary member function has an implied `self` and is called through an
instance. A `static func` has no receiver and is called through the struct
name.

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

## Nested assignment

Fields and indexes are places. A place can be nested, and compound
assignment evaluates it once:

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

Next: [Enums](/guide/enums/).
