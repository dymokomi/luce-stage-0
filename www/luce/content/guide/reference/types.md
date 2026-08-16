# Types

Luce is statically typed and supports inference. Every expression has exactly
one type, known at compile time. Widening is implicit along each
numeric ladder and, across the two, only into `double`. **Nothing
narrows implicitly** — not in any direction and not in any context.

An annotation is optional wherever the initializer decides the type,
and required where nothing does — an empty list literal, a `var` with
no value.

## Values and references

The lines between them decide everything about memory.

**Values** copy on assignment and on call: the seven numbers, `bool`,
`string`, structs, unions, enums, and plain function values. A value may
contain references. Copying it copies value fields and retains reference
fields.

**References** share one runtime object: `list(T)`, `map(K, V)`,
`array(T, ...)`, `builder`, `file`, and `task(...)`. They are created by
a literal, `new`, a host/library operation, or `spawn`. Assignment,
arguments, results, fields, optionals, and container slots share the same
object. Last-release destruction is the ARC contract, but current development
builds still have the [listed lifecycle gaps](../memory/#current-completion-blockers).

There are no source ownership operators and no universal deep copy. A
program constructs an independent value explicitly when that is what its
data model requires. `class` is currently a front-end scaffold, not a
completed reference type; see [Status](/status/).

## Scalars

| Type | Definition |
|---|---|
| `bool` | `true` or `false`. The only type a condition may have. |
| `byte` | Unsigned 8-bit, 0 … 255. **Storage.** |
| `short` | Signed 16-bit, −32 768 … 32 767. **Storage.** |
| `int` | Signed 32-bit, **checked**: overflow traps. The default for an integer literal. |
| `long` | Signed 64-bit, **checked**: overflow traps. |
| `half` | IEEE 754 binary16, ±65 504. **Storage.** |
| `float` | IEEE 754 binary32. Does not trap. The default for a float literal. |
| `double` | IEEE 754 binary64. Does not trap. |
| `string` | Immutable UTF-8. A value. |

`byte` is the only unsigned numeric type and stores values from 0
through 255.

## Storage and arithmetic

Three of the seven — `byte`, `short` and `half` — are **storage
types**. They are what an annotation, a parameter, a struct field and
above all an array element may say, and an operator widens them before
it does anything: `byte` and `short` compute at `int`, `half` at
`float`. So there are four arithmetic types and not seven, no checked
arithmetic at 8 or 16 bits, and no binary16 arithmetic on any machine.

Operators widen storage types before arithmetic. For example, `byte`
255 plus 1 is the `int` value 256; it does not wrap.

```luce run
func main():
    var a: byte = 255
    var b: byte = 1
    print(string(a + b))
    var h: half = 0.5
    print(string(h + h))
```

```output
256
1
```

What they are *for* is `array(byte, _)` at one byte an element — the
underscore is the type's rank-only extent, with the actual dimension
given to `new array(byte, n)` — an eighth of what the same array of
`long` costs, and the same vector register holding four `float`s where
it held two `double`s.

## Promotion

The integer ladder is `byte` → `short` → `int` → `long`; the floating
ladder is `half` → `float` → `double`. A value widens only upward on its
ladder. Mixing the ladders widens to `double`; `long` values above 2^53
are not all exactly representable there.

`int` does not widen to `float`; cross-family promotion always chooses
`double`.

`/` is real division and always answers a `double`. `//` is floor
division and `%` the modulus that pairs with it — both answer the
promoted integer type, both floor, so `%` takes the sign of the
divisor, and both trap on a zero divisor. `/` does not trap:
`1 / 0` is `inf`.

Comparison across the ladders does **not** widen — it is exact, so
`9007199254740993 == 9007199254740992.0` is `false`, which widening
would get wrong.

## Conversions

Conversions are named for their result type: `byte(x)`, `short(x)`,
`int(x)`, `long(x)`, `half(x)`, `float(x)`, `double(x)`, and
`string(x)`.

- **Float to integer** rounds half away from zero and traps
  `conversion_range` outside the target — NaN and the infinities
  included.
- **Integer to an integer that cannot hold it** traps the same way:
  `byte(300)` is not 44, it is a program that stops.
- **Integer to float** never traps.
- **Float to a narrower float** rounds to nearest, ties to even, and
  may produce `inf` rather than trapping.

A widening constructor never traps and is redundant with promotion,
but it stays: it is how you widen where there is no operator to hang
it on.

```luce trap
func main():
    var over: long = 300
    print(string(byte(over)))
```

```output
loom: trap: conversion out of range [conversion_range]
    at main (main.luc:3:5)
```

`string(x)` prints a number with the shortest text that round-trips
**at its own width**, so the width is visible in the answer. It also
prints a `bool`, a string, an enum or union member's name, or a
function value's
name. Container objects, resources and structs are not accepted.

```luce run
func main():
    print(string(1.0 / 3.0))
    print(string(double(1.0) / double(3.0)))
    print(string(half(65504.0)))
```

```output
0.33333334
0.3333333333333333
65500
```

The last line is not a rounding mistake. 65504 is the largest finite
binary16, and no other binary16 lies nearer to 65500 — so four digits
name it exactly, and reading them back gives 65504.

## Function

A function value's type is its signature with parameter names and
defaults removed:

```
func(long, long) -> bool
func(string)
func(list(long)) -> long
```

A function type is worn by four things: a named top-level or `static`
function, a lambda, a **bound method** (`receiver.method`, whose
environment is that receiver), and a **union member constructor**
(`Msg.query_changed`). One place holds any of them and no reader can
tell which — which is also why a function value has no equality, and
why one never crosses a worker boundary. A bound value copies its struct
receiver into the function value and retains every reference carried by that
copy. The bound value may outlive the original concrete binding.

That lack of equality follows the value wherever a comparison reaches
it: a struct holding a `(func(...) -> R)?` field is not compared with
`==` either, and `xs.find(v)` and `xs.contains(v)` over a container of
such structs are refused for the same reason, because a search is `==`
under another spelling. Keep what you meant to look for beside the
values — a name, an enum — and compare that.

The result is omitted when the function returns nothing. Fallibility
does not appear in a function type: a fallible function cannot be used as a value because a
function type has no `!` with which to carry the obligation.

A function type may annotate a parameter or local, be a function's
result, and nest inside another function signature. A file-scope
`const` cannot hold one because function declarations and lambdas are
not constant expressions.

**A slot holds the optional form: `(func(...) -> R)?`.** A struct
field, a list element, an array cell and a union payload field all
exist before anything fills them, and a function value has no zero —
every value of the type names a function, and an empty slot names
none. So absence is the zero, and reaching the value takes the
narrowing or the `else` any other optional takes. A late `var` is the
same slot and takes the same form.

```luce run
struct Button:
    label: string
    on_click: (func(long) -> long)?

func main():
    let wired = Button(label = "double", on_click = (n) -> n * 2)
    let action = wired.on_click
    if action != none:
        print(wired.label + " " + string(action(21)))
```

```output
double 42
```

A **map value** is the one slot no container ever creates — it exists
because a store created it — and `m.get(k)` already answers `V?`, so
the function type is written bare there and the absence is the missing
key. Writing the `?` as well would make `get` answer a `V??`, which
does not exist.

```luce run
func twice(n: long) -> long:
    return n * 2

func main():
    var actions = new map(string, func(long) -> long)
    actions["double"] = twice
    let found = actions.get("double")
    if found != none:
        print(string(found(4)))
    print(string(actions.get("missing") == none))
```

```output
8
true
```

A top-level or static namespace function becomes a value where a function
type is expected, and so does a **reading method bound to its
receiver** — `doubling.times`, whose type is the method's with the
receiver's parameter dropped. The expected signature supplies the
landing shape, so an unannotated `let f = named_function` is refused.
Function values copy freely and have neither ordering nor equality —
a value is the function it names *and* the receiver it may carry, and
its type cannot say which, so no comparison has an honest answer.
`string(f)` gives the declared or compiler-generated function name —
for a bound value, the method's qualified name.
See [calls and lambdas](../expressions/#function-values-and-lambdas)
for the expression forms, the bind and the capture rule.

## Interface

An interface is a nominal, method-only contract. A struct opts in by naming
the interface after its name; a matching method set without that declaration
is not enough.

```text
interface Drawable:
    func draw(scale: long) -> long

struct Button: Drawable:
    label: string

    func draw(scale: long) -> long:
        return scale + 1
```

The contract is checked at the declaration. Method names, parameter count and
types, return count and types, and receiver mutability must
match. Interface methods are read-only, so an implementation that writes
`self` is rejected. Extra methods on the struct are harmless. A non-fallible
implementation may satisfy a fallible requirement; the reverse is rejected.

An interface may declare several distinct methods. Every method is a required
dispatch slot, and the implementation must provide every slot:

```text
interface Drawable:
    func render(value: long) -> long
    func label() -> string
```

The following are part of the contract check:

| Requirement | Rule |
| --- | --- |
| Receiver | The witness is an instance method; `static` functions cannot satisfy it. |
| Parameters | Count, types, and order match exactly. Interface methods cannot declare default arguments. |
| Results | Count and types match exactly. Two or more results use the ordinary return shape. |
| Effects | A non-fallible witness may satisfy a fallible requirement; a fallible witness may not satisfy a non-fallible one. |
| Mutation | The witness may not write `self`. |

The conversion is nominal and implicit: a concrete value enters an interface
when an interface-typed parameter, local, field, collection element, or
return slot expects it. There is no cast and no structural conformance. An
interface itself cannot be constructed and an interface-typed variable has no
default implementation; initialize it with a value from a conforming struct.
Interfaces do not convert to one another because this release has no
inheritance.

An interface exposes methods, not the concrete struct's fields. Calling a
method uses the implementation carried by the value:

```luce run
interface Drawable:
    func draw(scale: long) -> long

struct Button: Drawable:
    label: string

    func draw(scale: long) -> long:
        return scale + 1

struct Badge: Drawable:
    label: string

    func draw(scale: long) -> long:
        return scale + 2

func paint(item: Drawable) -> long:
    return item.draw(40)

func main():
    var items = new list(Drawable)
    items.append(Button(label = "button"))
    items.append(Badge(label = "badge"))
    var named = new map(string, Drawable)
    named["button"] = Button(label = "button")
    named["badge"] = Badge(label = "badge")
    print(string(items[0].draw(40)))
    print(string(items[1].draw(40)))
    let found = named.get("badge") else Button(label = "fallback")
    print(string(paint(found)))
```

```output
41
42
42
```

`list(I)` and `map(K, I)` are heterogeneous: each element may have a
different concrete type. The same interface value can be stored in an array
or a struct field, returned, or wrapped in an optional. The current hidden
layout stores bound dispatch values and copies the concrete struct receiver
state. Reference fields are currently aliases that the dispatch value does not
retain, so another concrete value must keep them alive. Interface methods are
read-only until the planned owned-existential representation replaces this
layout.

Interfaces do not inherit from one another or expose fields. Interface
methods may use the ordinary multi-value return shape:

```text
interface Measured:
    func span(value: long) -> (long, long)

func total(item: Measured) -> long:
    let low, high = item.span(10)
    return low + high
```

Receive the shape with a destructuring `let`, `var`, or assignment; it is not
a scalar expression and cannot be passed as one argument. The exact
declaration and conformance rules are summarized above; compiler diagnostics
point to the offending method or conformance list.

## struct

A named product of fields. Fields are annotated; construction names
its fields — every one without a default; assignment copies.

```luce run
struct Point:
    x: double
    y: double

func main():
    let p = Point(x = 1.5, y = 2.5)
    var q = p                       # a copy
    q.x = 9.0
    print(f"{p.x} {q.x}")
```

```output
1.5 9
```

A field may declare a trailing **default**, the same clause a
parameter takes: a compile-time constant the construction site may
omit. Defaults come last, and a struct every one of whose fields has
one constructs bare.

```luce run
struct Options:
    depth: long = 3
    wide: bool = false

func main():
    let plain = Options()
    let tuned = Options(depth = 9)
    print(f"{plain.depth} {plain.wide} {tuned.depth}")
```

```output
3 false 9
```

A plain function declared inside a struct is a method with implied
`self`, called as `value.name(...)`.  A `static func` has no receiver
and is the namespace form reached as `Struct.name(...)`.  Neither form
adds dynamic dispatch or inheritance.

A struct remains a value when it contains a reference. Copying the struct
copies its value fields and retains its reference fields, so the two struct
values are independent while a `list`, `file`, or `task` field may still name
one shared object.

Struct definitions may not be cyclic through plain fields. Recursion
goes through an optional field:

```luce run
struct Node:
    value: long
    next: Node?

func main():
    let tail = Node(value = 2, next = none)
    let head = Node(value = 1, next = tail)
    let second = head.next            # bind the field, then test the name
    if second != none:
        print(f"{head.value} then {second.value}")
```

```output
1 then 2
```

Narrowing applies to locals and parameters, never to a field — which
could change between the test and the use — so the field is bound to a
name first.

The cycle rule is one scale of a single rule: **a struct's
unconditional size must be finite, and small.** A plain field's
payload is part of what the struct is, so it is counted through — a
struct of two struct fields doubles per level — and past 4096 values
the declaration is refused, just as an infinite one is. An optional
field counts as one whatever it holds, because its payload starts
absent and arrives only when a program builds one. So `?` answers both
refusals, and so does a container: a `list`, `map` or `array` is one
reference however much it holds.

## enum {#enum}

A set of named constants at one integer width, declared with
[`enum`](../statements/#enum). It is a value type: it copies, and a
container holds it at its backing width.

- **No implicit conversion in either direction.** `int(m)` and every
  other numeric constructor answer the member's number at that width,
  trapping exactly where the same constructor would on the number
  itself; `string(m)` answers the member's **name**, and an f-string
  hole is a `string(...)` nobody wrote.
- `Method(n)` is the other direction and is fallible: it answers
  `Method?`, with `none` where no member holds `n`. Nothing else
  produces an enum value, which is why every value of an enum is one
  of its members.
- **Equality only.** `==` and `!=` compare members; `<` and its
  relatives are refused, naming `int(…)`.
- Members fold: a member is a constant, so it stands in a file-scope
  `const`, a parameter default and a field default.

```luce run
enum Method(byte):
    stored = 0
    deflated = 8

func main():
    var seen = new list(Method)
    seen.append(Method.deflated)
    print(f"{seen[0]} is {int(seen[0])}, and 3 is {string(Method(3) != none)}")
```

```output
deflated is 8, and 3 is false
```

## union {#union}

A value that is exactly one of a set of declared members, each member
optionally carrying named payload fields; declared with
[`union`](../statements/#union). The member is part of the value:
there is no way to construct one without choosing a member, and no way
to reach a payload except a [`match`](../statements/#match) arm that
proved which member the value holds.

- **Construction is a namespaced call with named arguments** —
  `Shape.circle(radius = 2.0)` — under the same rules as struct
  construction, defaults included. A bare member is written without
  parentheses: `Shape.empty`. The union's own name is not a
  constructor.
- **Memory follows each payload field.** A union is a value. Copying it
  copies value payloads and retains reference payloads. An arm's reference
  binding names the same object the scrutinee holds, and ARC balances both
  references.
- **The zero is the first declared member**, every payload field at
  its own zero — what `var s: Shape` starts at and what container
  cells hold.
- A member may not unconditionally contain its own union — the same
  finite-size rule structs have, refused with `?` and the containers
  named as the fixes. `Shape?` is an ordinary optional and is the
  recursion terminator that is not a container.
- `string(u)` answers the member's **name**; the payload is never
  formatted. `==` on two union values is refused, naming `match`. A
  union may not be a map key.
- A union takes methods and static namespace functions under the
  [same rules](../statements/#methods) as a struct.

```luce run
union Json:
    null
    number(value: double)
    array(items: list(Json))

func main():
    var xs = new list(Json)
    xs.append(Json.number(value = 2.5))
    let doc = Json.array(items = xs)
    match doc:
        array(items):
            print(f"an {doc} of {len(items)}")
        else:
            print("not an array")
```

```output
an array of 1
```

## list(T)

A growable sequence. Created with a literal or `new list(T)`. An empty
literal requires an annotated binding.

`T` may be any value, reference, or resource type. A list copies value
elements and retains reference elements; removing or replacing an element
releases what that slot held.

## map(K, V)

An insertion-ordered dictionary. `K` is `long`, `string` or an enum;
`V` is any
type other than an optional. Index get, index set, `has` and `get`
are O(1): the entries stay a dense array in arrival order with a hash
index over it. Iteration is in insertion order.

## array(T, ...)

Fixed shape, one to four dimensions, sizes given as runtime values at
`new`. Elements begin at the type's zero value: `0`, `0.0`, `false`,
`""`, a field-by-field zeroed struct, or — for container/resource
handle element types — the null handle, which traps on use until
something is stored.

In a type annotation the shape is spelled with `_` for each axis:
`array(long, _, _)`.

`array(double, _)` is the numeric vector type `std.math`'s whole-array
operations take.

## builder

Accumulates text. `builder.build()` hands back the `string`.

## file

An open file. A heap-backed resource rather than a fifth container. It
takes no type argument, and there is no `new file`. The raw
`file_open(path, mode)` host builtin is the primitive door; `std.files`
wraps it as `open`, `create`, and `append_to`. A handle with no file
behind it is the one thing this type must never hold.

It is a reference **resource**. Assignment and return share the same handle.
The completed ARC contract closes it at the last release; current builds have
the [listed file-lifecycle gap](../memory/#current-completion-blockers). A null
or stale runtime handle traps rather than becoming undefined memory access.

```luce run
import std.files

func main() -> !:
    try files.write("note.txt", "abc")
    var f = try files.open("note.txt")
    var buffer = new array(byte, 8)
    print(string(try f.read(buffer)))
    try files.delete("note.txt")
```

```output
3
```

A file reference may be shared, but that does not duplicate the open file.
The methods are `f.read(buffer)`, `f.write(buffer, count)` and `f.flush()`,
all three fallible; [`std.files`](/library/files/) is where the loops over
them live.

## task

A running worker (see the [Workers](/guide/concurrency/) chapter). The
`file` precedent exactly: a resource rather than a container, with no
`new task` — `spawn` is the only door in — and an ARC lifetime. The completed
contract closes a file and **joins** a task at the last release; current
lifecycle tests must still prove every automatic path.

What stands inside the parentheses is a **return shape**, written the
way it would be written after a function's `->`:

| written | the worker's function answers |
|---|---|
| `task` | nothing, and cannot fail |
| `task(!)` | nothing, or a failure |
| `task(double)` | a `double` |
| `task(double!)` | a `double`, or a failure |

A `spawn` is admitted only when its worker's return shape is
resource-free. A worker function that answers `file`, `task`, or any
container or struct carrying one is refused there, because that resource
belongs to the runtime that created it and cannot cross back through
`wait`. The type spelling itself remains valid for an unfilled slot.

The `!` is the spawned function's own attribute travelling with the
call the task carries — the same fact `-> T!` states, one level out —
and it decides whether `t.wait()` is a site that has to say `try` or
`catch`.

```luce run
func square(n: long) -> long:
    return n * n

func main():
    var tasks = new list(task(long))
    for i in range(1, 4):
        tasks.append(spawn square(i))
    var total: long = 0
    for t in tasks:
        total = total + t.wait()
    print(string(total))
```

```output
14
```

A task reference may be shared, but there is still one worker behind it. Its
one method is `t.wait()`, which observes the answer once. Automatic
last-reference joining is the ARC completion contract, not yet a fully proved
current guarantee.

## Return shapes {#return-shapes}

`(long, long)` after a function's `->` says it answers two values.

**It is not a type.** It is a shape a *signature* has, and it may be
written nowhere else: not on a binding, not on a parameter, not on a
struct field, not inside a `list`, not nested inside another shape,
and not with a `?` (which would be marking the shape rather than a
value). There is no expression that produces one.

```luce fail
func main():
    let p: (long, long) = 1
```

```output
luce: compile failed
main.luc:2:12: a return shape is not a type: a pair that travels together is a struct [luce.parse.type]
        let p: (long, long) = 1
               ^~~~~~
```

The comma is what makes it a shape. **One type in parentheses is a
parenthesized type**, which is that type — so `-> (long)` answers a
`long`, exactly as `(long)` is `long` wherever a type stands.

A pair that travels together is a struct. A pair that only ever
travels *outward* — never a parameter, never a field, never a
container element, only ever read one value at a time — is a return
shape, and the question is greppable rather than a matter of taste.

Every element is an ordinary type, so `-> (long?, bool)` is fine, and
`-> (A, B)!` composes with `try` like any other fallible signature.

## Optionals: `T?`

A trailing `?` makes a type nullable. `none` is the absent value, and
it is legal only where a `T?` is expected — a plain type can never
hold it.

`T?` may be:

- a local variable
- a parameter
- a return type
- a struct field
- a union member's payload field — which is what lets a recursive
  union end at absence

`T?` may **not** be a container element type or a map value type, and
there is no `T??` — one `?` is all there is. The one exception is a
**function value**, whose storable form *is* the optional: see
[function](#function).

### Parentheses in a type {#parenthesized-types}

`(T)` is `T`, wherever a type may stand. Parentheses group and are
required nowhere — `long?` and `(long)?` are one type.

They exist for one shape. A function type's result consumes its own
`?`, so `func(string) -> long?` means *a function answering a `long?`*
— which is how `parse_int` is written as a value. Closing the function
type first is what says the **function** may be absent:

```text
func(string) -> long?     a function answering long?
(func(string) -> long)?   a function, or none
```

After `->` in a declaration a `(` may instead open a
[return shape](#return-shapes); the arity decides, so `-> (long)` is
`-> long` and `-> (long, long)` is two answers.

Absence holds no reference: a `list(T)?` containing a list retains it
exactly as a `list(T)` place would, while `none` retains nothing.

Narrowing is described in [expressions](../expressions/#narrowing).

## Fallibility: `-> T!`

A trailing `!` on a **return type** says the function may raise an
error. `-> !` means it returns nothing or an error.

**`T!` is not a type.** Fallibility is an attribute of the function.
There is no `T!` to declare a variable of, to use as a container
element, or to write in a struct field, and `return x` in a `-> T!`
function returns `x` with nothing wrapped around it.

```luce fail
struct Holder:
    value: long!

func main():
    print("unreachable")
```

```output
luce: compile failed
main.luc:2:16: expected end of line after the field, found '!' [luce.parse.expected]
        value: long!
                   ^
```

## Zero values and late initialization

`var name: Type` with no initializer declares the binding, its type
and its scope. The slot holds the type's zero value until it is
assigned. For a container object or resource type that is the null
handle, and using it traps `null_object`; the stable code uses the
runtime's older broad “object” term. For an enum it is the **first declared member**:
zero is a number no member need hold, and every value of an enum is a
member. For a union it is likewise the first declared member, with
every payload field at its own zero.

`let` always requires an initializer: a name that can never be
reassigned and holds nothing is a contradiction.

This is zero-initialization, not nullability. A slot that may
genuinely hold nothing is a `T?` and says so.

## Identity

`==` and `!=` on container objects and resources compare handle
identity — whether two names denote the same reference object — never
contents.
