# Answering more than one thing

A function may answer more than one value. The shape is written after
`->`, the values are returned with a comma, and the caller receives them
with a destructuring bind or a parallel assignment.

```luce
func minmax(xs: array[f64, _]) -> (f64, f64):
    var low = xs[0]
    var high = xs[0]
    for i in range(1, len(xs)):
        low = min(low, xs[i])
        high = max(high, xs[i])
    return low, high

func main():
    let data: array[f64, _] = [3.0, 1.0, 2.0]
    let low, high = minmax(data)
    print(f"{low} {high}")
```

## The declaration

A return shape is a parenthesized, comma-separated list of **two or more**
types after `->`:

```text
func divmod(a: i64, b: i64) -> (i64, i64):
    return a // b, a % b
```

Each element is an ordinary type, so a `T?` element is fine:

```text
func lookup(m: map[str, i64], k: str) -> (i64?, bool):
    if m.has(k):
        return m.get(k), true
    return none, false
```

A return shape is **not a type**, and every attempt to treat it as one
is refused. It cannot annotate a binding, a parameter, a `struct` field,
a container element, or a `map` value; it cannot nest inside another
return shape; and it cannot take a `?`.

| written | refused because |
|---|---|
| `let p: (i64, i64) = …` | a return shape is not a type: a pair that travels together is a `struct` |
| `func f(p: (i64, i64)):` | the same |
| `-> ((i64, i64), i64)` | return shapes do not nest |
| `-> (i64, i64)?` | `?` marks a value that may be absent, and a return shape is not a value |

A pair that travels together is a `struct`. A parenthesized single type
is just that type (`-> (i64)` is `-> i64`), because parentheses group
a type wherever one stands.

## Returning

`return a, b` answers the shape. The count and the types must match the
declaration:

```text
func bounds(xs: list[i64]) -> (i64, i64):
    return xs[0], xs[len(xs) - 1]
```

`return f()` where `f` answers a shape is **refused**, even when the
arities match — a call that answers more than one value is not an
expression, so it cannot stand as the operand of `return`. Bind the
values and return them:

```text
func widest(xs: array[f64, _]) -> (f64, f64):
    let low, high = minmax(xs)
    return low, high
```

## Receiving

A call that answers more than one value may stand in exactly three
places: the right of a destructuring bind, the right of a parallel
assignment, and a statement of its own.

### Destructuring bind

Two or more names, then `=`, then a call whose arity matches:

```text
let low, high = minmax(temperatures)
var row, column = grid_find(target)
```

**One keyword governs the whole bind.** `let a, b` makes both immutable;
`var a, b` makes both reassignable. `let a, var b = f()` is refused. The
names take their types from the call, so per-name annotations
(`let a: i64, b: i64 = …`) are refused: the one place a return shape is
written is the signature.

### Parallel assignment to existing names

A call that answers a shape may be assigned into two or more distinct,
already-declared, mutable bare names:

```text
var position = 0
var value = 0
value, position = scan_number(text, position)
```

The assignment is parallel: the call is made and every returned value is
prepared before any target is replaced. If the call is guarded and
fails, none of the target stores happen (ordinary side effects of
evaluating the right side are not rolled back).

Targets are limited to distinct existing mutable bare names. Fields,
indexes, compound forms (`+=`), and `_` are not assignment targets here.

### Discard

A call that answers a shape may stand as a statement, discarding every
value:

```text
minmax(temperatures)            # values computed and released
```

There is no `_` discard. When a bind wants only some of the values, name
the rest; a named binding is released at the end of its block exactly as
a discarded value would be, and it tells the next reader what was
ignored.

```text
let word, count = heaviest(counts)
print(word)                     # count is simply unused
```

## Fallibility composes

A fallible function may answer a shape: `-> (A, B)!`. The failure travels
in its own channel, the values in theirs, so `try` composes with no new
mechanism:

```luce
import std.files

func read_pair(path: str) -> (i64, i64)!:
    let text = try files.read(path)
    return len(text), 0

func main() -> !:
    let a, b = try read_pair("bounds.txt")
    print(f"{a} {b}")
```

Parallel assignment composes the same way:

```text
var a: i64 = 0
var b: i64 = 0
a, b = try read_pair("bounds.txt")
```

`catch EXPR` supplies a single fallback value, so it cannot handle a
call that answers more than one — `let a, b = f() catch 0, 0` is refused.
A fallible multi-return call is either propagated with `try` or handled
by a statement-position `catch:` block, which supplies no values:

```text
reseed_from("seed.txt") catch:
    print("keeping the old seed")
```

## Memory

`return a, b` needs no memory rule of its own. Each value travels the way
its type does: a value type — a scalar, `str`, a `struct`, an `enum` —
is copied into the caller; a reference type — a `list`, `map`, `array`,
`builder`, `file`, or `task` — is handed back as a shared
reference. A destructuring bind gives each name its value. ARC frees each
object at its last reference. Returning the same reference in two
positions is fine: the caller gets two names for one shared object, and
ARC counts both. See `docs/MEMORY.md`.

## Writing methods

A method that mutates its receiver may also answer results. The receiver
is not one of them: it is written back in place, and the declared results
are exactly what the caller receives.

```luce
struct Rng:
    state: i64

    func next() -> i64:
        self.state = self.state * 48271 % 2147483647
        return self.state

func main():
    var rng = Rng(state = 42)
    let roll = rng.next()       # rng mutated in place; roll is the result
    print(f"{roll}")
```

The receiver must be a mutable bare binding at the call site — the same
permission `xs.append(...)` needs. `self` is implied and never spelled as
a parameter (`docs/SELF.md`). A writing method may declare zero, one, or
several results; if it fails, receiver writes already performed remain
visible.

## Deliberately absent

- **Tuples as values.** There is no anonymous product type. A return
  shape exists only in flight, between a `return` and the assignment that
  consumes it; a program can never hold one. A pair that travels together
  is a `struct`.
- **`return f()` pass-through**, and a multi-valued call used as an
  argument (`g(f())`). Bind the values first.
- **Field and index assignment targets.** Parallel assignment writes only
  distinct existing mutable bare names.
- **`_` as a discard**, and per-value `catch` fallbacks.
