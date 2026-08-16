# Unions

Use a union when one value can have several shapes and some shapes carry
different data. The active member is part of the value, so a caller cannot
mistake one shape for another. Use an `enum` for a fixed set of names with
no payload; an optional `T?` when the only alternative is “a `T` or no `T`.”

```text
union Shape:
    empty
    circle(radius: f64)
    rect(width: f64, height: f64)
```

Constructors are qualified (`Shape.circle(...)`) and payload fields are
named. `match` is the operation that opens the value and makes the active
shape visible.

## Declare and construct members

A union has at least one payload-carrying member; if every member is only a
name, use an enum instead. Payload fields have names, types, and optional
constant defaults. A bare member is selected without parentheses, while a
payload member is called with named arguments.

```luce run
union Response:
    not_modified
    ok(body: str, status: i64 = 200)

func main():
    let cached = Response.not_modified
    let fresh = Response.ok(body = "ready")
    match cached:
        not_modified:
            print("cached")
        ok:
            print("fresh")
    match fresh:
        not_modified:
            print("cached")
        ok(body, status):
            print(f"{status} {body}")
```

```output
cached
200 ready
```

`Response.ok` is a constructor function, but `Response.ok` is not a type. The
union name itself is not a constructor. These rules keep the active member
visible wherever a value enters the program.

## Match the whole shape

An arm binds every payload field by its declared name, or binds none by
writing `member:`. A match without `else` must cover every member. That
combination makes adding a new member a visible compile-time change at every
caller that needs to decide what it means.

```luce run
union Shape:
    empty
    circle(radius: f64)
    rect(width: f64, height: f64)

func area(shape: Shape) -> f64:
    match shape:
        empty:
            return 0.0
        circle(radius):
            return 3.0 * radius * radius
        rect(width, height):
            return width * height

func main():
    print(str(area(Shape.circle(radius = 2.0))))
    print(str(area(Shape.rect(width = 3.0, height = 4.0))))
```

```output
12
12
```

Do not match only the fields you happen to need. If an arm should ignore a
payload, write `circle:` or `rect:`. The field names in a binding list are
part of the type, not local aliases chosen for convenience.

Use `else` only when every remaining member intentionally has the same
behavior. An exhaustive match is often better for domain policy because
adding a member then produces a diagnostic at each decision that must be
revisited. Duplicate arms, a payload name from the wrong member, and an
`else` that covers no member are all refused.

Bindings live in the arm's scope. A value payload is copied into its binding;
a reference payload aliases the object the union already owns. The union
continues to keep that reference alive while the arm runs and after it ends.

## References inside a payload

Value payloads copy. A payload containing a list, map, array, builder, file, or
task retains that reference through ARC, just like a struct field. Matching
gives access to the payload and keeps its references alive.

```text
var items = new list[Json]
items.append(Json.text(value = "ready"))
let document = Json.array(items = items)
```

`document` and `items` reach the same list. Take a list slice before
construction when the payload must be an independent list. See [Memory and
ARC](/guide/memory/) for the value/reference boundary and deterministic
resource cleanup.

## Recursive data needs an indirection

A union is a value, so it cannot contain itself unconditionally: that would
require an infinite-sized value. Put recursion behind an optional, where
absence terminates the chain, or behind an owning container, whose reference
has a fixed size:

```text
union Json:
    null
    number(value: f64)
    array(items: list[Json])
```

This is why JSON arrays can contain JSON values and why a linked structure
usually has `next: Node?` or a `list[Node]` payload. The indirection gives the
union a finite size. If the recursive links are references, remember that
strong cycles need a weak link under the completed ARC design.

## Zero values and equality

The zero value of a union is its first declared member, with that member's
payload fields at their own zero values. This matters for a late `var` and for
storage that creates elements before a caller fills them. Put the safest
empty state first when a union will be zero-created.

Unions do not define `==` or ordering. Two members with the same spelling can
still contain payloads whose comparison has domain-specific meaning, and two
different members may be considered equivalent by a particular application.
Match each value and write the comparison your model requires.

An optional union is useful when the complete closed state may itself be
absent. It is still only one optional layer: `State?` is valid, `State??` is
not.

## Separate shape from policy

Keep the union definition focused on the alternatives. Put decisions about
display, validation, serialization, or business rules in methods or nearby
functions. A union can have ordinary methods with an implied `self` and
static functions without a receiver, just like a struct.

When you find yourself adding many boolean flags, consider a union instead:
`loading`, `ready(value)`, and `failed(reason)` communicate which fields are
valid far better than `is_ready`, `has_value`, and `error_text` that can
contradict one another.

Use a structure when all fields exist together, an enum when alternatives
carry no data, an optional for present-or-absent, and an interface when
different concrete types share behavior. A union is the choice when the
alternatives themselves are the data model.

For exact declaration and arm syntax, recursive restrictions, and layout
rules, read [Statements and Declarations: union](/guide/reference/statements/#union)
and [Types: Unions](/guide/reference/types/#union). Continue with [Error
Handling](/guide/errors/).
