# Functions and Closures

Functions name reusable work. Closures are function values that carry the
local state they need. Both have the same `func(...) -> ...` type, so an API
does not need separate callback and function concepts.

## Declare a function

Parameters have types. A result follows `->`; a function with no result omits
the arrow. Every path through a value-returning function must return.

```luce run
func gcd(a: i64, b: i64) -> i64:
    var left = a
    var right = b
    while right != 0:
        let next = left % right
        left = right
        right = next
    return left

func announce(label: str, value: i64):
    print(f"{label}: {value}")

func main():
    announce("gcd", gcd(1071, 462))
```

```output
gcd: 21
```

Arguments are positional by default. A caller may use parameter names, and
trailing parameters may have compile-time defaults:

```luce run
func pad(text: str, width: i64 = 8) -> str:
    return text

func main():
    print(pad(width = 12, text = "luce"))
```

```output
luce
```

Named arguments may be reordered; positional arguments must come first.

## Functions are values

A function type states parameter and result types, not parameter names:

```luce run
func twice(value: i64) -> i64:
    return value * 2

func apply(operation: func(i64) -> i64, value: i64) -> i64:
    return operation(value)

func main():
    let chosen: func(i64) -> i64 = twice
    print(str(chosen(21)))
    print(str(apply((value) -> value + 1, 41)))
```

```output
42
42
```

`(value) -> value + 1` is a one-expression lambda. Its parameter types come
from the function-typed place where it lands. Calls through function values
are positional. Function values have neither equality nor ordering; store a
separate identifier when a program needs one.

## Capture local state

A block closure starts with `func(parameters):`. It may read and write names
from the surrounding function, and it keeps those captures alive after that
scope returns:

```luce run
func make_adder(start: i64) -> func(i64) -> i64:
    var total = start
    let advance: func(i64) -> i64 = func(amount):
        total += amount
        return total
    return advance

func main():
    let add: func(i64) -> i64 = make_adder(10)
    print(str(add(2)))
    print(str(add(5)))
```

```output
12
17
```

An immutable captured value is retained in the closure environment. A
captured `var` becomes one shared cell: writes in the original scope and in
every closure that captures it observe the same value. Different calls to a
factory receive independent environments.

A block closure may contain ordinary statements, control flow, `try`, and
multiple returns. It can return no value, one value, or a multi-value result
just like a named function.

The indentation grammar has one useful boundary: an indented closure body
cannot begin inside another call's parentheses. Bind the closure first, then
pass it, or return it directly from an ordinary block.

## Capture lists {#capture-lists}

Captures are strong and shared by default. A capture list immediately before
`func` requests a different rule for a particular name.

`name = expression` evaluates once and captures a snapshot:

```luce run
func main():
    var number = 1
    let read: func() -> i64 = [saved = number] func():
        return saved
    number = 42
    print(str(read()))
    print(str(number))
```

```output
1
42
```

`weak name` captures a class or other weak-capable reference without keeping
it alive. The captured name is optional inside the closure:

```luce run
class Item:
    value: i64

func make_reader(item: Item) -> func() -> i64:
    return [weak item] func():
        let live = item else Item(value = 0)
        return live.value

func main():
    var read: (func() -> i64)? = none
    if true:
        let item = Item(value = 7)
        read = make_reader(item)
        print(str(read()))
    let call = read else () -> -1
    print(str(call()))
```

```output
7
0
```

Use a weak capture for the back-edge of a cycle—for example, when an object
stores a callback that otherwise captures that object strongly. There is no
unsafe dangling or `unowned` capture.

## Bound methods

Reading `value.method` into a matching function-typed place binds its receiver.
A structure receiver is copied as a snapshot. A class receiver retains and
shares the same identity:

```luce run
struct Scale:
    factor: i64

    func times(value: i64) -> i64:
        return value * self.factor

class Counter:
    value: i64

    func current() -> i64:
        return self.value

func main():
    var scale = Scale(factor = 2)
    let double: func(i64) -> i64 = scale.times
    scale.factor = 100

    let counter = Counter(value = 1)
    let read: func() -> i64 = counter.current
    counter.value = 42

    print(str(double(3)))
    print(str(read()))
```

```output
6
42
```

The function value owns its bound receiver. Reference fields in a structure
snapshot remain shared and retained; a class-bound method can outlive the
binding it came from.

## Store and compose closures

Function values—including closures with different captured environments—can
be returned, placed in optional fields, and stored in lists, maps, and arrays.
A function type has no zero value, so an optional is useful for an initially
empty slot: `(func(i64) -> i64)?`.

Parentheses matter. `(func(i64) -> i64)?` is an optional function;
`func(i64) -> i64?` is a present function whose result may be absent.

Closures are ARC references internally. A stored closure retains its strong
captures, and releasing the last function value releases its environment.
Workers do not accept a function value or a graph containing one; create and
use worker-local closures inside the worker instead.

Continue with [Enumerations](/guide/enums/). The exact forms are in [Function
values](/guide/reference/types/#function) and [Function values and
closures](/guide/reference/expressions/#function-values-and-lambdas).
