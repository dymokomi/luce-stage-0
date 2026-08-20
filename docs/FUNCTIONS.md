# Function values and closures

A Luce function may travel as a value. A named function, static function,
union member constructor, bound method, expression lambda, and capturing block
closure all use the same `func(...)` type and the same indirect-call path.

The surface has two anonymous forms:

- `(parameters) -> expression` is a concise, capture-free expression lambda;
- `func(parameters):` opens a block closure that may capture enclosing locals.

## Function types

`func(T, ...) -> R` writes parameter types and a result type. Parameter names
and defaults belong to declarations, not to the function value type. Omitting
`-> R` means no result.

```luce
func twice(value: i64) -> i64:
    return value * 2

func apply(value: i64, operation: func(i64) -> i64) -> i64:
    return operation(value)

func main():
    let operation: func(i64) -> i64 = twice
    assert(apply(21, operation) == 42)
```

A call through a value is positional. The type has no parameter names, so
named arguments are unavailable at that boundary. Function types carry
fallibility (docs/ERRORS.md R3): `func(i64) -> i64!` and `func(i64) -> !`
are types, a call through such a value owes `try` or `catch` exactly as a
direct call does, and a non-fallible function converts *into* a fallible
slot — never the reverse.

## Expression lambdas

The short form takes bare parameter names and one expression. Its types come
from the place where it lands:

```luce
import std.lists

func main():
    var values = [3, 1, 2]
    values.sort_by((left, right) -> left < right)
    assert(values[0] == 1)
```

An expression lambda has no environment. It may use its parameters,
file-scope constants, and visible declarations, but not an enclosing local.
Use a block closure when behavior must carry local state.

## Block closures

A block closure begins with `func(parameters):` and uses ordinary statements
and return checking. It also needs a contextual function type, either from an
annotated binding or from a declared function result:

```luce
func make_adder(start: i64) -> func(i64) -> i64:
    var total = start
    return func(amount):
        total += amount
        return total

func main():
    let add: func(i64) -> i64 = make_adder(10)
    assert(add(2) == 12)
    assert(add(5) == 17)
```

The parameter list contains names only. The contextual type supplies arity,
parameter types, and results. A result-bearing closure must return on every
path. A no-result closure may fall through like an ordinary no-result
function.

An indented block cannot begin inside call parentheses because layout is
suspended there. Bind or return the closure first, then pass that value. A
future trailing-closure convenience is not part of the current grammar.

## What a capture means

The compiler discovers enclosing locals used by a block closure and gives the
closure an ARC-managed environment:

- an immutable value is a snapshot;
- an immutable reference is retained strongly;
- a mutable local moves into one shared cell used by its declaring scope and
  every closure that captures it;
- a captured function or interface retains its complete dispatch state; and
- nested closures retain the environment chain they need.

Two closures that capture the same `var` therefore observe one variable, not
two copies:

```luce
struct CounterPair:
    add: (func(i64) -> i64)?
    read: (func() -> i64)?

func make_pair() -> CounterPair:
    var total = 0
    let add: func(i64) -> i64 = func(amount):
        total += amount
        return total
    let read: func() -> i64 = func():
        return total
    return CounterPair(add = add, read = read)

func main():
    let pair = make_pair()
    let add = pair.add else (value) -> value
    let read = pair.read else () -> -1
    assert(add(40) == 40)
    assert(add(2) == 42)
    assert(read() == 42)
```

The shared-cell rule applies to scalars, text, value structs, optionals,
destructured variables, and weak variables. It is a language rule rather than
a special case for numeric counters.

## Capture lists

A capture list appears before `func` when creation-time behavior must be
explicit:

```text
[name] func():                 # explicitly capture the local normally
[weak model] func():           # non-owning optional reference
[copy = expression] func():    # evaluate once and capture that value
```

An explicit normal capture follows the same value/reference/mutable-cell rule
as an inferred capture. A named snapshot expression is evaluated exactly once
when the closure is created:

```luce
func main():
    var number = 1
    let read: func() -> i64 = [copy = number] func():
        return copy
    number = 42
    assert(read() == 1)
```

`weak` accepts a class, list, map, array, or builder reference and exposes an
optional value inside the body. It never dangles:

```luce
class Model:
    value: i64

func make_reader(model: Model) -> func() -> i64:
    return [weak model] func():
        let live = model else Model(value = 0)
        return live.value

func main():
    let model = Model(value = 42)
    let read: func() -> i64 = make_reader(model)
    assert(read() == 42)
```

Capture names and parameter names must be unique. Luce does not shadow an
enclosing local inside a lifted closure body; a duplicate declaration is
diagnosed at the new name.

## ARC and cycles

A closure environment is a reference-counted object. Copying a function value
retains its environment, and destroying the last copy releases every capture
exactly once. A returned closure can therefore outlive the frame that created
it without borrowing stack storage.

Strong capture is the safe default. It can also form a cycle when an object
stores a closure that captures the same object. Luce diagnoses the direct
`self.field = func(): ... self ...` form and recommends `[weak self]`:

```luce
class Node:
    value: i64
    callback: (func() -> i64)?

    func install():
        self.callback = [weak self] func():
            let live = self else Node(value = 0, callback = none)
            return live.value

func main():
    let node = Node(value = 42, callback = none)
    node.install()
    let callback = node.callback else () -> 0
    assert(callback() == 42)
```

ARC cannot discover every indirect application cycle. The program must make
one back-edge weak when its object graph would otherwise retain itself.
A `deinit` body cannot capture its dying `self`.

## Storage and boundaries

A function value may be returned, placed in an optional, stored in an
aggregate, and used in lists, maps, and arrays. Slots that need an empty state
use `(func(...) -> R)?`; a map value is written bare because `map.get` already
provides the optional layer. A custom initializer may establish a bare
function-valued class field before the class exists. [BINDING.md](BINDING.md)
specifies these shapes and bound receiver ownership.

Function values have no equality or ordering. `str(function)` answers the
function's name for diagnostics and display, not a stable identity key.

Function values cannot cross a worker boundary. A receiver or closure
environment belongs to one runtime's object table, so `spawn` accepts only a
declared call whose arguments and result contain no function value.

The differential closure specification is
[`src/luce/specs/closures_spec.zig`](../src/luce/specs/closures_spec.zig).
Common capture, typing, cycle, and worker mistakes are pinned in
[`src/luce/specs/errors_spec.zig`](../src/luce/specs/errors_spec.zig).
