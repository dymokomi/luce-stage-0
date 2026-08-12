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
behavior plus state is a struct with a method.

Calls through values are positional because a function type has no
parameter names or defaults. Function values copy freely, have neither
equality nor ordering — the reason is below, where a value picks up a
receiver — and `string(f)` gives the function's name. There are
first-class functions and capture-free lambdas, but no closures.

## A method travels with its struct

"Behavior plus state is a struct with a method" is not advice — it is
something you can write down. A **reading method written where a
function type is expected** becomes a function value whose environment
is the receiver:

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

There is no marker. `doubling.times` is the ordinary member spelling,
and what makes it a value rather than a call is the place it lands in —
exactly as a bare `ascending` becomes a value by landing. The written
type drops the receiver's parameter: `Scale.times` takes one `long` at
the call site, so the value is a `func(long) -> long`.

The receiver is **copied into the value**. What the value carries is
its own from then on, so writing the original afterwards does not reach
it:

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

That makes a bound value an ordinary value: it copies freely, takes no
ownership verb, and releases nothing you have to think about.
`string(f)` answers the method's qualified name — `Scale.times`.

A receiver that **carries objects** — a list, a map, an array, or a
struct holding one — is **borrowed** instead of copied. The value holds
its own little run, and the handles inside it name the receiver's
graph, exactly as a struct copy does: appending to the receiver's list
is visible through the bound value.

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

So a function value **never owns objects**. That is a guarantee, not an
accident: `give bag.at` and `copy bag.at` are refused, and nothing else
can make a bound value the sole owner of a graph. It buys the thing
worth having — a struct that holds a handler stays a *value* struct,
and `let b = a` still copies it — and it costs the one thing every
alias in Luce costs: keep the receiver alive. A bound value whose
receiver's owner is gone meets `use_after_free` at the call, on the
line that made it.

## Keeping one for later

A function value goes in a struct field, a list, an array — anywhere a
value goes. The written type takes a `?`, and the parentheses matter:

```text
(func(long) -> long)?
```

A slot exists before anything fills it, and a function value has no
zero: every value of the type names a function, and an empty slot
names none. So the storable form is the optional, absence is the zero,
and you reach the value the way you reach any other optional.

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

The parentheses are there because `func(long) -> string?` already means
*a function answering an optional string* — the result type takes its
own `?` first. Closing the function type before the `?` is what says
the function may be absent. A parenthesized type is just that type, so
`(long)?` is `long?` and nothing you have written needs changing.

A **map value** is the one place you write the function type bare:
`m.get(k)` already answers `V?`, so the absence is the missing key.

Storing a bound value changes nothing about who owns what. The
receiver is still borrowed, the container owns the run and not the
graph, and a stored bind whose receiver's owner is gone still meets
`use_after_free` at the call — never a stale read.

Two facts follow from the same place, because a function type cannot
say which of its values carries a receiver. A function value has **no
equality**: two binds of one method with different receivers are
different workers, and comparing the names is what you meant, so
compare `string(f)`. And a function value does **not cross a worker
boundary**, in either direction — a borrow has nothing to borrow from
over there.

The proving customer is sorting by state the comparator carries, which
had no honest spelling before:

```luce run
import std.lists

struct Nearest:
    origin: long

    func before(a: long, b: long) -> bool:
        return abs(a - self.origin) < abs(b - self.origin)

func main():
    let near = Nearest(origin = 10)
    var xs = new list(long)
    xs.append(1)
    xs.append(14)
    xs.append(9)
    xs.sort_by(near.before)
    for x in xs:
        print(string(x))
```

```output
9
14
1
```

Four things do not bind, and each says so by name. A **writing** method
does not — a writer needs the binding that owns its receiver, so call
it there. A **fallible** method does not — a function type still
carries no `!`. A receiver carrying a **file** or a **task** does not —
a resource stays with the binding that owns it. And a **fresh**
carrying receiver does not: its objects die at the end of the statement
that made them, so there would be nothing left to borrow.

A **union member constructor** is a function value in the same places.
`Msg.query_changed` where a `func(string) -> Msg` is expected builds
that member, with the payload fields as parameters in declaration
order; a payload-less member such as `Msg.quit` stays a value.

```luce run
union Msg:
    quit
    query_changed(query: string)

func describe(m: Msg) -> string:
    match m:
        quit:
            return "quit"
        query_changed(query):
            return "query " + query

func route(make: func(string) -> Msg, text: string) -> string:
    return describe(make(text))

func main():
    print(route(Msg.query_changed, "abc"))
    print(describe(Msg.quit))
```

```output
query abc
quit
```

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
