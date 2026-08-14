# Unions: make alternatives explicit

Use a union when one value can have several shapes and some shapes carry
different data. The active member is part of the value, so a caller cannot
mistake one shape for another. Use an `enum` for a fixed set of names with
no payload; an optional `T?` when the only alternative is “a `T` or no `T`.”

```text
union Shape:
    empty
    circle(radius: double)
    rect(width: double, height: double)
```

Constructors are qualified (`Shape.circle(...)`) and payload fields are
named. `match` is the operation that opens the value and makes the active
shape visible.

## Match the whole shape

An arm binds every payload field by its declared name, or binds none by
writing `member:`. A match without `else` must cover every member. That
combination makes adding a new member a visible compile-time change at every
caller that needs to decide what it means.

```luce run
union Shape:
    empty
    circle(radius: double)
    rect(width: double, height: double)

func area(shape: Shape) -> double:
    match shape:
        empty:
            return 0.0
        circle(radius):
            return 3.0 * radius * radius
        rect(width, height):
            return width * height

func main():
    print(string(area(Shape.circle(radius = 2.0))))
    print(string(area(Shape.rect(width = 3.0, height = 4.0))))
```

```output
12
12
```

Do not match only the fields you happen to need. If an arm should ignore a
payload, write `circle:` or `rect:`. The field names in a binding list are
part of the type, not local aliases chosen for convenience.

## Keep ownership at the boundary

Value payloads copy. A payload that contains a list, map, array, builder,
file, or task carries that object and follows the same ownership rules as a
struct field. Matching gives you access to the existing payload; it does not
create a second owner.

When a named object becomes a union payload, make the transfer explicit:

```text
var items = new list(Json)
items.append(Json.text(value = "ready"))
let document = Json.array(items = give items)
```

Use `copy` if both the old name and the union must continue to own data. A
borrowed object cannot be retained in a union. See [Memory without a
collector](/guide/memory/) for the ownership decision and [Ownership](/guide/reference/ownership/)
for the rule numbers cited by diagnostics.

## Recursive data needs an indirection

A union is a value, so it cannot contain itself directly: that would require
an infinite-sized value. Put recursion behind an optional or a container:

```text
union Json:
    null
    number(value: double)
    array(items: list(Json))
```

This is why JSON arrays can contain JSON values and why a linked structure
usually has `next: Node?` or a `list(Node)` payload. The object owns the
recursive container; the union still has a finite size.

## Separate shape from policy

Keep the union definition focused on the alternatives. Put decisions about
display, validation, serialization, or business rules in methods or nearby
functions. A union can have ordinary methods with an implied `self` and
static functions without a receiver, just like a struct.

When you find yourself adding many boolean flags, consider a union instead:
`loading`, `ready(value)`, and `failed(reason)` communicate which fields are
valid far better than `is_ready`, `has_value`, and `error_text` that can
contradict one another.

For exact arm syntax, zero values, recursive restrictions, optional unions,
and comparison rules, read the [Unions chapter](/guide/unions/) and the
[Types reference](/guide/reference/types/).
