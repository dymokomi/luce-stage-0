# Initialization

Initialization establishes every stored field before a value or object can be
used. Structures use memberwise construction. Classes construct through
`new`, use the same memberwise form by default, and may replace it with one
custom `init` body when construction needs validation, derived state, or a
smaller public surface.

There is no uninitialized object that escapes and becomes somebody else’s
problem.

## Structure construction

Construct a structure by naming its fields. Field order in the declaration
does not force call-site order because construction arguments are named:

```luce run
struct Connection:
    let host: str
    let port: i64 = 443
    let secure: bool = true

func main():
    let primary = Connection(host = "example.com")
    let local = Connection(secure = false, port = 8080, host = "localhost")
    print(f"{primary.host}:{primary.port} {primary.secure}")
    print(f"{local.host}:{local.port} {local.secure}")
```

```output
example.com:443 true
localhost:8080 false
```

A field without a default is required. A field with a folded default may be
omitted. Defaults are evaluated as part of the declaration’s compile-time
contract, not by running arbitrary code for every construction.

Structure construction produces a value. Assigning or passing the result
copies its value fields and retains any reference fields. There is no identity
or partially initialized storage behind the constructor.

## Memberwise class construction

A class without `init` uses the same field-named surface as a structure:
construction is an ordinary call, `User(name = "ada")`, and the reference
identity comes from constructing a class — not from any keyword.

```luce run
class User:
    let name: str
    var visits: i64 = 0

func main():
    let user = User(name = "Ada")
    user.visits += 1
    print(f"{user.name} {user.visits}")
```

```output
Ada 1
```

The completed `new` call creates one ARC object. A `let` binding keeps naming that
object while its fields remain mutable. Use memberwise construction when the
stored representation is already the right public construction API.

Private fields affect who may use the memberwise constructor. If callers
should not know or choose an implementation field, a custom initializer gives
the class an explicit public boundary.

## Custom class initialization

Declare one `init(parameters)` body inside a class to replace memberwise
construction:

```luce run
class Rectangle:
    let label: str = "rectangle"
    let width: i64
    let height: i64
    let area: i64

    init(width: i64, height: i64 = 1):
        self.width = width
        self.height = height
        self.area = self.width * self.height

func main():
    let rectangle = Rectangle(6, height = 7)
    print(rectangle.label)
    print(str(rectangle.area))
```

```output
rectangle
42
```

Write `Rectangle(...)` rather than `Rectangle.init(...)`.
Initializer parameters follow the ordinary function rules: each has a type,
trailing parameters may have compile-time defaults, positional arguments come
first, and named arguments may be reordered.

Declaring `init` removes the memberwise call surface. Callers see `width` and
`height`; they cannot supply the derived `area` or depend on its storage.

## Definite initialization

Every successful path through `init` must establish every stored field.
Declared field defaults count as established. A weak field has an implicit
`none` and also counts. Every other field must be assigned before the body
finishes or takes a bare early `return`.

After a field is established on the current path, the initializer may read it
or update it. Before that point, a read is refused. This makes dependency order
visible:

```luce module file=measurement.luc
class Measurement:
    let width: i64
    let height: i64
    let area: i64

    init(width: i64, height: i64):
        self.width = width
        self.height = height
        self.area = self.width * self.height
```

Both arms of an `if` can establish a field. An exhaustive `match` can do the
same. A loop alone cannot establish a required field because it may execute
zero times. At a failed join, the diagnostic lists the fields still missing
rather than reporting a later, unrelated use.

## `self` before identity exists

During `init`, `self` is a controlled view of field storage, not a finished
class reference. It may read already-established fields and assign fields. It
may not be passed, returned, captured by a closure, stored into another object,
replaced, or used to call an instance method.

This restriction avoids a two-phase object whose identity is visible while
some fields do not exist. Put reusable pure calculations in a static function:

```luce module file=normalized.luc
class Normalized:
    let value: i64

    static func clamp(value: i64) -> i64:
        if value < 0:
            return 0
        if value > 100:
            return 100
        return value

    init(value: i64):
        self.value = Normalized.clamp(value)
```

The class object is allocated and published only after a successful path has
established every field.

## Fallible initialization

An initializer that can reject otherwise well-typed input writes `-> !` and
uses the ordinary recoverable-error mechanism:

```luce run
class Port:
    let number: i64

    init(number: i64) -> !:
        if number < 1 or number > 65535:
            error("port out of range")
        self.number = number

func main() -> !:
    let web = try Port(8080)
    discard(Port(70000)) catch reason:
        print(reason)
    print(str(web.number))
```

```output
port out of range
8080
```

A failed initializer releases fields and temporaries already established on
that path, publishes no class object, and does not run `deinit`. The caller
handles the call with `try` or `catch` because the `new` call itself is
fallible.

## Visibility and factories

An initializer may be private. Code in the same module can then expose public
static functions whose names describe valid construction choices. This is
useful when several named policies share one stored representation, while the
language still keeps exactly one `init` body.

Luce does not have initializer overloads, delegation, convenience versus
designated initializers, subclass phases, or implicit failable construction.
Use default/named parameters for one call surface and static factory functions
for separately named policies.

## Initialization and ARC

Reference-valued fields are retained when they become part of the completed
object. Replacing an already-established field retains the new value before
releasing the old one. A failed path unwinds all established values exactly
once. These are the ordinary assignment and scope rules, applied before the
class identity is published.

The exact declaration and refusal rules are in [Statements and Declarations:
class](/guide/reference/statements/#class). Continue with
[Deinitialization](/guide/deinitialization/).
