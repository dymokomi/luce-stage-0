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
- parameter count, types, and `give` modes;
- return count and types; and
- receiver mutability.

Interface methods are read-only. A method whose body writes `self` cannot
satisfy one. A concrete struct may have additional methods; they are not
part of the interface.

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

An interface value owns its dispatch storage. As with a bound read-only
method, object graphs inside a carrying receiver remain borrowed from the
concrete value that supplied them; the interface does not silently create a
second owner. Keep that owner alive, or make an explicit `copy` before a
value is kept beyond the owner's lifetime. A function cannot return a
carrying concrete receiver as an interface, because its local owner would
die at the return; return the concrete owner instead. Value-only receivers
(including strings) are independent copies.

The executable specification is
[`src/luce/specs/interfaces_spec.zig`](../src/luce/specs/interfaces_spec.zig),
which runs every example through both the interpreter and the compiled
backend. Negative cases live in
[`src/luce/specs/errors_spec.zig`](../src/luce/specs/errors_spec.zig).
