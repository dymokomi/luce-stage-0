# Interfaces

An interface is a named call contract. It lets a function accept several
different structs through one type while keeping the implementation choice
with the value that arrives.

Interfaces are nominal: a struct must list the interface explicitly. A
matching set of methods is not enough on its own.

```text
interface Drawable:
    func draw(scale: long) -> long

struct Button: Drawable:
    label: string

    func draw(scale: long) -> long:
        return scale + 1
```

`Button` can now be passed anywhere `Drawable` is expected:

```text
func paint(item: Drawable) -> long:
    return item.draw(41)
```

The conversion happens when a concrete struct lands in an interface-typed
place. There is no cast syntax and no structural or runtime conformance
check.

## Contract matching

The interface and implementation must agree on:

- method name and instance status;
- parameter count and types; and
- return count and types.

A concrete struct may have additional methods; they are not part of the
interface. A method reached through an interface may mutate its receiver:
an interface value is a reference (see `docs/MEMORY.md`), so dispatch runs
the concrete method with no restriction on what it writes.

Failure effects are directional. A non-fallible implementation may satisfy a
fallible requirement, because it is safe for a caller to write `try` when no
error will be raised. A fallible implementation may not satisfy a
non-fallible requirement.

Interfaces in this release contain methods only. They do not inherit from
other interfaces or expose fields. A method may return a multi-value shape
using the same \`(T, U)\` syntax as an ordinary function; callers receive it
with a destructuring \`let\`, \`var\`, or assignment:

\`\`\`text
interface Measured:
    func span(value: long) -> (long, long)

func total(item: Measured) -> long:
    let low, high = item.span(10)
    return low + high
\`\`\`

The shape cannot be used as one scalar expression or passed as one argument.

## Heterogeneous collections

`list(I)` and `map(K, I)` hold interface values, so each element may come
from a different conforming struct:

```text
var items = new list(Drawable)
items.append(Button(label = "one"))
items.append(OtherDrawable(...))

var named = new map(string, Drawable)
named["button"] = Button(label = "one")
```

Reading an element gives back `I`, and dispatch uses the implementation that
belonged to that element. The same rule applies to arrays and struct fields.

An interface value is a reference to the conforming value it was made from,
paired with its dispatch information. It can be stored in a local, a struct
field, a list, or a map and kept for as long as you like: ARC keeps the
underlying object alive while any interface — or any other reference — names
it, and frees it at the last release. A function may return a concrete value
as an interface, because the reference outlives the frame that produced it.

The executable specification is
[`src/luce/specs/interfaces_spec.zig`](../src/luce/specs/interfaces_spec.zig),
which runs every example through both the interpreter and the compiled
backend. Negative cases live in
[`src/luce/specs/errors_spec.zig`](../src/luce/specs/errors_spec.zig).
