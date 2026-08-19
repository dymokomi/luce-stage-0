# Types

Luce is statically typed with inference. Every expression has one type known
at compile time. An annotation is optional when an initializer supplies the
type and required when nothing does.

The complete built-in vocabulary is:

```text
bool
u8 u16 u32 u64
i8 i16 i32 i64
f16 f32 f64
char str bytes
list map array builder
task channel
```

User declarations add aliases, structs, classes, enums, unions, and
interfaces.

## Values and references

The kind of a type decides assignment, argument, and return behavior.

| Kind | Current examples | Behavior |
|---|---|---|
| Value | numbers, `bool`, `char`, `str`, `bytes`, structs, enums, unions, function values | copy the value; a captured function retains its ARC environment |
| Reference | classes, `list[T]`, `map[K, V]`, `array[T, ...]`, `builder` | share one ARC object |
| Resource reference | `task[...]` | share one ARC object; join at the last release |
| Resource reference | `channel[T]` | share one ARC wrapper; the last release anywhere closes the row |

A value may contain references. Copying the value copies its value fields and
retains its reference fields. There are no source retain, release, borrow,
move, clone, or free operations.

An open file is not a language type. `std.files` answers `files.File`, an
ordinary class that closes its private descriptor at the last strong release.
The raw descriptor type, `handle`, resolves only inside the embedded standard
library; a user program cannot name it and may freely declare its own `handle`
or `file`. See [`std.files`](/library/files/).

## Type aliases {#type-aliases}

`alias` gives one resolved type another source name:

```text
alias UserId = u64
public alias Rows = list[str]
private alias Handler = func(i64) -> i64
```

The unmarked form is public. An alias creates no wrapper, conversion, nominal
identity, allocation, layout, runtime tag, or dispatch rule. It works anywhere
its target works: annotations, signatures, fields, optionals, containers,
interface conformance lists, enum backing types, constructors, constants,
imports, and member namespaces.

Aliases may refer forward and form chains. Direct and indirect cycles,
unknown targets, duplicate names, private cross-module access, and an optional
applied twice are compile errors even when the alias is unused. Alias names
share the file-scope namespace with every other declaration.

## Numbers

Each numeric name states its exact representation:

| Type | Meaning |
|---|---|
| `u8`, `u16`, `u32`, `u64` | unsigned integers at 8, 16, 32, and 64 bits |
| `i8`, `i16`, `i32`, `i64` | signed integers at 8, 16, 32, and 64 bits |
| `f16`, `f32`, `f64` | IEEE binary16, binary32, and binary64 |

An unconstrained integer literal is `i64`; an unconstrained floating literal
is `f64`. A literal can instead land directly in a contextual numeric type
when it fits. A concrete value never changes width, signedness, or integer/
float family implicitly.

```luce run
func main():
    let small: u8 = 255
    let wide: u16 = u16(small)
    let ratio: f32 = f32(wide) / 2
    print(f"{wide} {ratio}")
```

```output
255 127.5
```

Integer arithmetic is checked at the operand's own width and traps
`integer_overflow` instead of wrapping. `//` is floor division; `%` is its
paired remainder. `/` is true division: same-type integer operands answer
`f64`, while same-type float operands preserve their float width. Concrete
operands of different types require an explicit conversion.

Every numeric type name is a conversion constructor. Integer narrowing and
float-to-integer conversion trap `conversion_range` when the destination
cannot represent the result. Float-to-integer truncates toward zero. Float
conversions round to nearest, ties-to-even.

[Basic Operators](/guide/operators/) teaches the common forms. The exact
operator table is in [Expressions](../expressions/).

## `bool`

`bool` has the values `true` and `false`. It is the only type accepted as a
condition; Luce has no truthiness and numbers do not convert to booleans.

## `char`, `str`, and `bytes`

`char` is one Unicode scalar. A single-quoted literal must decode to exactly
one scalar. `char(integer)` validates a scalar value, `u32(character)` returns
its code point, and `str(character)` encodes it as UTF-8.

`str` is immutable valid UTF-8. Its ordinary sequence unit is `char`:
`len(text)` counts scalars, indexing answers `char`, slicing uses scalar
positions, and iteration yields characters.

`bytes` is immutable binary data. Its sequence unit is `u8`: length counts
bytes, indexing answers `u8`, slicing answers `bytes`, and iteration yields
bytes. `bytes(text)` encodes UTF-8; `parse_str(data) -> str?` validates binary
data as text. Mutable binary buffers use `list[u8]` or `array[u8, _]`.

```luce run
func main():
    let text = "A👋é"
    let encoded = bytes(text)
    print(str(len(text)))
    print(str(text[1]))
    print(parse_str(encoded) else "invalid")
```

```output
3
👋
A👋é
```

## Optionals: `T?`

`T?` is a `T` that may be absent. `none` is the absent value. Luce has one
optional layer, so `T??` is invalid. A present `T` lands in `T?` implicitly;
an optional must be narrowed or given a fallback before `T` operations apply.

```text
if value != none:
    use(value)

let present = value else fallback
```

Parentheses group a type: `(T)` is `T`. This matters for optional function
values because `func(str) -> i64?` answers an optional integer, while
`(func(str) -> i64)?` is a function value that may itself be absent.

## Function values {#function}

`func(T, ...) -> R` is a non-fallible function type. It contains parameter
types, not names or defaults. For example, `func(i64, i64) -> bool`:

```text
func(i64, i64) -> bool
func(str)
func(list[i64]) -> i64
```

Named functions, static functions, expression lambdas, block closures, union
member constructors, and compatible bound methods can land in a
function-typed place. Calls through a value are positional. Function values
may be stored and returned, but have no equality or ordering.

A zero-created field or container element uses `(func(...) -> R)?`, because a
function value has no empty value. A map value uses bare `func(...) -> R`
because the key's absence already represents a missing value. A custom class
initializer may also establish a required bare function field: the object is
created only after definite initialization proves that field is present.

A one-expression lambda is `(parameters) -> expression`; it does not capture
locals. A block closure is `func(parameters):` followed by an indented body and
may capture enclosing locals. Its parameter and result types come from the
destination function type. Immutable captures are retained snapshots,
captured mutable locals share one cell, `[name = expression]` captures an
explicit snapshot, and `[weak name]` makes a zeroing optional capture.

A bound method carries its receiver. A value receiver is copied and its
reference fields are retained. A class receiver retains the same identity and
observes later mutation. Captured environments and bound receivers release at
the last function-value copy.

## Interfaces {#interface}

An interface is a nominal set of instance-method requirements. A struct or
class opts in by listing the interface and must implement every requirement:

```luce run
interface Named:
    func name() -> str
    func measure(value: i64) -> (i64, i64)

struct Label: Named:
    text: str

    func name() -> str:
        return self.text

    func measure(value: i64) -> (i64, i64):
        return value, value + 1

func describe(item: Named) -> str:
    let low, high = item.measure(20)
    return item.name() + ":" + str(low + high)

func main():
    print(describe(Label(text = "size")))
```

```output
size:41
```

Conformance is explicit, not structural. Method names, instance status,
parameter count/order/types, and result arity/types must match. Requirement
parameter names are call labels; witness parameter names are not part of the
function type. A non-fallible witness may satisfy a fallible requirement; the
reverse is invalid. Static functions, incomplete conformers, and duplicate
witnesses are rejected. A `mutating` requirement permits a writing
value-struct witness; a writing witness is rejected when the requirement is
not `mutating`. Class witnesses may mutate shared class identity.

Interface values work as locals, parameters, results, optionals, fields, and
heterogeneous list/map/array elements. Dispatch stores one owned payload plus
a static witness identity: a struct receiver is copied and a class receiver
retains identity. A mutating value call requires a mutable bare local; a `let`,
temporary, projection, or collection element cannot receive write-back. There
are no default methods, interface inheritance, associated types, runtime
casts, or generic constraints.

## Structs

A struct is a value aggregate with named fields. Construction names fields;
defaults must be trailing. A copied struct has independent value fields while
reference fields still name the same objects.

```text
struct Point:
    x: f64
    y: f64 = 0.0

let point = Point(x = 2.5)
```

A `func` declared inside a struct is a method with implied `self`; source does
not declare a receiver parameter. A `static func` has no receiver and is
called through the type name. The compiler infers whether a method writes
`self`; a writing method requires a mutable value receiver today.

Fields and methods are public by default. `private`/`public` regions and
per-member marks follow the ordinary file visibility rules.

## Classes {#classes}

A class is a final ARC reference aggregate. Assignment, parameters, results,
fields, optionals, and container elements retain and share one object. A stable
`let` class binding may mutate that object.

```luce run
class Counter:
    value: i64

    func add(amount: i64) -> i64:
        self.value += amount
        return self.value

func main():
    let first = Counter(value = 1)
    let same = first
    assert(first is same)
    print(str(same.add(41)))
    print(str(first.value))
```

```output
42
42
```

`is` accepts two operands of the same nominal class type and compares
identity. Classes do not synthesize `==`, ordering, or hashing. A class may
conform to interfaces, use weak class fields, and declare one bare `deinit`
body that runs at the last strong release before its fields release. `deinit`
cannot resurrect its dying `self`.

Construction requires `new`—`Name(...)`—the keyword that creates every
reference identity; a bare `Name(...)` call on a class is a compile error.
Without an `init` declaration, the `new` call takes the same memberwise
arguments as a structure constructor. One class-only initializer may replace
that surface:

```text
class Name:
    field: Type
    defaulted: Type = constant

    init(parameter: Type, optional: Type = constant):
        self.field = parameter

    init(parameter: Type) -> !:
        ...
```

The two `init` forms above are alternatives, not overloads. The only permitted
result marker is bare `-> !`; success answers the enclosing class implicitly.
Construction writes `Name(...)`, with ordinary positional, named,
trailing-default, fallibility, and visibility rules. `Name.init(...)` and a
bare `Name(...)` call are invalid.

Every successful fallthrough or bare `return` must have initialized all stored
fields. Declared defaults and implicit weak-field defaults begin initialized.
Facts intersect across continuing `if`, `match`, and guarded-call branches;
loop assignments do not establish facts after the loop. A read, compound
assignment, index, or nested update requires its root field to be initialized
on the current path.

Before success, `self` is only a namespace for those field slots. It cannot be
used as a value, captured, passed, returned, replaced, or used as an instance
method receiver. Successful return creates the ARC object as one complete
value. Failure unwinds initialized slots and creates no object, so `deinit`
does not run for failed construction.

There is no class inheritance, `override`, `super`, initializer overloading or
delegation, computed property, or class metatype.

## Enums {#enum}

An enum is a closed set of names stored at one integer width. The default
backing is `i32`; any of the eight integer types may be written explicitly.
Members start at zero and increment unless a constant value is supplied.

```luce run
enum Method(u8):
    stored = 0
    deflated = 8

func main():
    let method = Method.deflated
    print(f"{method} {u8(method)}")
```

```output
deflated 8
```

Members are always namespaced. Conversion out is explicit through an integer
constructor or `str`. `Enum(value)` checks the backing value and answers
`Enum?`; an unknown member answers `none`. `match` is exhaustive unless it has
an `else` arm.

## Unions {#union}

A union is a tagged value whose members may have named payload fields.
Construction names payloads and `match` is the only way to read them.

```luce run
union Shape:
    empty
    circle(radius: f64)

func area(shape: Shape) -> f64:
    match shape:
        empty:
            return 0.0
        circle(radius):
            return 3.0 * radius * radius

func main():
    print(str(area(Shape.circle(radius = 2.0))))
```

```output
12
```

A union is a value. Value payloads copy and reference payloads remain shared
through ARC. Recursive unions must pass through an optional, where absence
terminates the value chain, or a reference container whose handle has a fixed
size.

## `list[T]`

A growable ARC reference sequence. Non-empty literals infer an element type;
an empty list uses `list[T]()`. Indexes and lengths are `i64`. Slicing
creates a new outer list: value elements copy and reference elements remain
shared.

Function values and optionals have storage restrictions described in the
function and optional sections; otherwise `T` may be any current value or
reference type.

## `map[K, V]`

An insertion-ordered ARC reference map. `K` is an integer, `str`, or an enum.
`get(key)` answers `V?`; indexing an absent key traps `key_missing`. `{}` has
no type, so an empty map uses `map[K, V]()`.

## `array[T, ...]`

A fixed-after-construction ARC reference grid. Each `_` in the type records
one rank; runtime extents are arguments to construction:

```text
let pixels: array[u8, _, _] = array[u8](height, width)
```

Arrays are densely packed at the element's declared width and are indexed
with one `i64` coordinate per rank.

## `builder`

An ARC reference text accumulator. Append text or ASCII bytes and call
`build() -> str` to finish a value string. Builders are mutable and have no
type arguments.

## `task[...]` {#task}

An ARC resource produced only by `spawn`. The result shape is written in
brackets: `task`, `task[!]`, `task[i64]`, or `task[i64!]`. Assignment shares
one worker handle. `wait()` observes the result once; the final release joins
an unfinished worker. A task cannot cross another worker boundary or be weak.

## `channel[T]` {#channel}

A bounded conduit between workers, and the one reference a worker
boundary admits ([Threads](/guide/concurrency/)). Constructed by call —
`channel[i64]()` for the default capacity of sixteen, `channel[i64](64)`
for an explicit one, never less than one. `send` parks a deep copy and
`receive` rebuilds it in the receiver, so no identity crosses; the
element type must be sendable, checked where the channel is written
(`luce.sema.channel`). The methods are `send`, `try_send`, `receive`,
`try_receive`, `receive_timeout`, `close`, `len`, and `cap`; the
blocking forms answer the `channel_closed` error rather than trapping.
A channel cannot be weak, and cannot ride inside another sent value —
it crosses whole, as a `spawn` argument.

## Return shapes {#return-shapes}

Two or more types after `->` describe multiple answers:

```text
func bounds(values: list[i64]) -> (i64, i64):
    return values[0], values[len(values) - 1]

let low, high = bounds(values)
```

A return shape is not a tuple or a type. It cannot annotate a parameter,
field, binding, or container element, cannot nest, and cannot take `?`.
Receive it with destructuring, parallel assignment to existing mutable names,
or a statement that discards every answer.

## Fallibility: `-> T!`

`!` marks a function result channel, not a type. `-> T!` may return `T` or
raise a recoverable error; `-> !` returns no value or raises. `try` propagates
the error and `catch` handles it. `T!` cannot be used as a local, field, or
container type.

## Weak storage

`weak` qualifies a mutable local or field; it does not create a type. The
declared type must be an optional class, `list`, `map`, `array`, or `builder`:

```luce run
struct Link:
    weak root: list[Link]?

func main():
    let root: list[Link] = [Link()]
    root[0].root = root
    let snapshot = root[0].root else [Link()]
    print(str(len(snapshot)))
```

```output
1
```

A weak place starts at `none`; a weak field has that implicit default.
Assignment records the target without retaining it. Reading a live target
produces an owned `T?` snapshot. After final strong release it reads `none`,
and object-table reuse cannot revive it. Separate reads do not persistently
narrow one another.

Weak targets exclude scalars, text values, value structs, interfaces,
functions, and tasks. Weak fields disable implicit aggregate equality
and collection search, and weak handles cannot cross worker runtimes. A
closure capture list may use `[weak name]` with the same target rules.

## Zero values and late initialization

`var name: Type` without an initializer creates the type's zero. Numbers are
zero, `bool` is false, `char` is `U+0000`, `str` and `bytes` are empty, and
struct/union fields recursively use their zeros. A container or resource gets
a defensive null handle; using it before assignment traps `null_object`.

This is not optionality. A place that may legitimately hold nothing is `T?`
and says so. `let` always requires an initializer.

## Equality and identity

Value equality descends through value fields. Container and resource `==`/
`!=` compare reference identity, never contents. Function values and values
containing functions or weak fields have no equality. Floats follow IEEE
rules, including NaN not equaling itself. Classes use `is` for identity;
classes do not have `==` or ordering.
