# Types

Luce is statically typed with inference. Every expression has exactly
one type, known at compile time. Widening is implicit along each
numeric ladder and, across the two, only into `double`. **Nothing
narrows implicitly** — not in any direction and not in any context.

An annotation is optional wherever the initializer decides the type,
and required where nothing does — an empty list literal, a `var` with
no value.

## Values, container objects, and resources

The lines between them decide everything about memory.

**Values** copy on assignment and on call, and nobody frees them: the
seven numbers, `bool`, `string`, structs and unions carrying no object
or resource,
enums and function values. A value never takes an ownership word.

**Container objects** are referenced, created with `new` or a literal,
and freed by scope ownership: `list(T)`, `map(K, V)`, `array(T, ...)`,
`builder`. Assigning or passing a struct value that contains a list
copies the *reference* — both struct values see the same list. The
explicit `copy` verb instead deep-copies a resource-free owned graph.

**Resources** are heap-backed so scope ownership can give them one
owner and one death point, but they are not containers: `file` and
`task(...)`. They move with `give` or `return`, release with `free` or
scope end, and cannot be copied because there is one file or worker
behind the handle.

A struct that transitively carries a container object or resource is an
**ownership-carrying struct**. The compiler's older internal and
diagnostic term is *object-carrying*; that class includes resources. The
whole struct follows what it carries, and one carrying a resource is
non-copyable.

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

`byte` is the one unsigned type there is and the only one there will
be: a byte is 0 … 255 in files, sockets, images and UTF-8 alike, and
that is the one domain where the answer is unanimous.

## Storage and arithmetic

Three of the seven — `byte`, `short` and `half` — are **storage
types**. They are what an annotation, a parameter, a struct field and
above all an array element may say, and an operator widens them before
it does anything: `byte` and `short` compute at `int`, `half` at
`float`. So there are four arithmetic types and not seven, no checked
arithmetic at 8 or 16 bits, and no binary16 arithmetic on any machine.

Nothing wraps. `byte` 255 plus 1 is 256, an `int`, because the
addition never had type `byte` to overflow.

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

Along a ladder, every rung reaches every rung above it, exactly:
`byte` → `short` → `int` → `long`, and `half` → `float` → `double`.
Across the two ladders the answer is always `double`, which is exact
for every integer but `long` and, for `long`, exact below 2^53 — the
language's one lossy implicit conversion.

`int` does **not** widen to `float`. It would fit, but the rule is
that there is one cross-family answer rather than a rule about which
values happen to fit — and Java's `int → float`, which loses
everything above 2^24, is the widening this declines to grow.

`/` is real division and always answers a `double`. `//` is floor
division and `%` the modulus that pairs with it — both answer the
promoted integer type, both floor, so `%` takes the sign of the
divisor, and both trap on a zero divisor. `/` does not trap:
`1 / 0` is `inf`.

Comparison across the ladders does **not** widen — it is exact, so
`9007199254740993 == 9007199254740992.0` is `false`, which widening
would get wrong.

## Conversions

Each conversion is named for the type it produces: `byte(x)`,
`short(x)`, `int(x)`, `long(x)`, `half(x)`, `float(x)`, `double(x)`,
and `string(x)`. One rule per family, not one per pair:

- **Float to integer** rounds half away from zero and **traps**
  `conversion_range` outside the target — NaN and the infinities
  included.
- **Integer to an integer that cannot hold it** traps the same way:
  `byte(300)` is not 44, it is a program that stops.
- **Integer to float** never traps.
- **Float to a narrower float** rounds to nearest, ties to even, and
  reaches `inf` rather than trapping, because `/` is already IEEE
  without traps and the language does not keep a second story about
  infinity.

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

## function

A function value's type is its signature with parameter names and
defaults removed:

```
func(long, long) -> bool
func(string)
func(give list(long)) -> long
```

A function type is worn by four things: a named top-level or `static`
function, a lambda, a **bound method** (`receiver.method`, whose
environment is that receiver), and a **union member constructor**
(`Msg.query_changed`). One place holds any of them and no reader can
tell which — which is also why a function value has no equality, and
why one never crosses a worker boundary. A function value owns the run
that holds it and never owns objects: a value-only receiver is copied
in, a carrying one is borrowed, and `give receiver.method` is refused.

The result is omitted when the function returns nothing. `give`
remains because ownership is part of calling the value. Fallibility
does not: a fallible function cannot be used as a value because a
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

A struct type is **object-carrying** — the established compiler term —
if it transitively contains a container object or resource. Such structs
follow the owned member's rules when they are *kept*; one carrying
`file` or `task` cannot be copied, while plain-value structs never take
an ownership verb.

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
[`enum`](../statements/#enum). It is a value type: it copies, it takes
no ownership word, and a container holds it at its backing width.

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
- **Ownership is a struct's.** A union carries objects when *any*
  member's payload field does; the predicate is type-level, so keeping
  a value of such a union takes `give` or `copy` whichever member it
  holds. An arm's payload binding **aliases** what the scrutinee owns.
  `free(u)` is refused, as it is for a struct; scope end releases
  whatever the live member owns. A union of value-only members takes
  no verbs.
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
    let doc = Json.array(items = give xs)
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

`T` may be any value, container object, or resource type. When `T`
carries an owned thing, the list **owns** its elements.

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

It is a **resource**, and scope ownership is what gives a resource a
death point. The binding that received the handle owns it, the end of
that scope closes the file, `free(f)` closes it early, `give` and
`return` move it, and using one after it is closed traps
`use_after_free` — because that is the same mistake.

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

A file cannot be copied: there is one open file behind a handle, and a
second Luce handle on it would be two owners of one resource. The
methods are `f.read(buffer)`, `f.write(buffer, count)` and `f.flush()`,
all three fallible; [`std.files`](/std/files/) is where the loops over
them live.

## task

A running worker (see the [Workers](/tour/threads/) chapter). The
`file` precedent exactly: a resource rather than a container, with no
`new task` — `spawn` is the only door in — and a scope-owned death
point. What "release" *is* differs: for a file it is a close, for a
task it is a **join**.

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

A task cannot be copied: there is one worker behind it, and a second
handle would be two joiners of one thread. Its one method is
`t.wait()`, which consumes it; `free(t)` joins early and the end of
the owning scope joins automatically.

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

Absence owns nothing: a `list(T)?` holding an object owns it exactly
as a `list(T)` would, and holding `none` owns nothing.

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
identity — whether two names denote the same owned thing — never
contents.
