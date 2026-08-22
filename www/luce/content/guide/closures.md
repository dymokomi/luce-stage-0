# Closures

A closure is a function value that carries names from the scope where it was
created. Use one when behavior and a small amount of local state belong
together: a callback, a configured operation, a deferred action, or the next
step of a stateful computation.

Closures and named functions have the same `func(...) -> ...` type. An API can
accept either without declaring a separate callback type.

## Expression lambdas

The shortest function value is an expression lambda:

```luce run
func apply(operation: func(i64) -> i64, value: i64) -> i64:
    return operation(value)

func main():
    let doubled: func(i64) -> i64 = (value) => value * 2
    print(str(apply(doubled, 21)))
    print(str(apply((value) => value + 1, 41)))
```

```output
42
42
```

The landing function type supplies parameter types (or write them yourself:
`(value: i64) => value * 2`). The `=>` **yields** the body's value, so it needs
no `return`. This concise form captures its environment like the block closure
it desugars to; reach for a block closure when the function must carry a local
name or contain statements.

## Block closures

A block closure starts with `func(parameters):` and uses an ordinary indented
function body:

```luce run
func make_counter(start: i64) -> func(i64) -> i64:
    var total = start
    let advance: func(i64) -> i64 = func(amount):
        total += amount
        return total
    return advance

func main():
    let next = make_counter(10)
    print(str(next(2)))
    print(str(next(5)))
```

```output
12
17
```

`advance` survives the call to `make_counter` because its closure environment
owns the captured state. A block closure may use conditionals, loops, local
declarations, `try`, `catch`, and multiple `return` statements just like a
named function.

The function-typed destination remains important. It tells the compiler the
parameter and result types before the body is checked. A closure with no
typed destination and no surrounding signature is refused rather than having
its callable shape guessed from use.

## Capturing immutable and mutable bindings

An immutable captured value is a creation-time value in the environment. If it
contains references, those references are retained. A captured `var` is
different: the surrounding scope and every closure that captures it share one
mutable cell.

```luce run
func main():
    var value = 1
    let add: func(i64) -> i64 = func(amount):
        value += amount
        return value
    let read: func() -> i64 = func():
        return value

    value = 10
    print(str(add(5)))
    print(str(read()))
```

```output
15
15
```

The closures do not receive independent copies of `value`; they and the outer
function observe the same cell. Separate calls to a closure factory create
separate cells.

This rule works for scalar, text, optional, structure, and reference-valued
mutable locals. ARC operations are derived from the cell’s concrete type, so a
replaced reference is retained before the old value is released.

## Snapshot captures

A capture list before `func` can give the closure an explicit creation-time
snapshot:

```luce run
func main():
    var number = 1
    let read: func() -> i64 = [saved = number] func():
        return saved
    number = 42
    print(str(read()))
    print(str(number))
```

```output
1
42
```

The expression to the right of `=` is evaluated exactly once when the closure
is created. The name on the left is local to the closure. Use this form when
the later value of a mutable binding is deliberately irrelevant—for example,
capturing the query associated with one queued action.

Do not use snapshot capture merely to avoid understanding shared state. A
plain capture communicates that the closure participates in the same evolving
value; a named snapshot communicates a deliberate point-in-time choice.

## Weak captures

References are captured strongly by default. Strong capture is safe and is
usually what keeps a callback’s model alive. Use `[weak name]` for a non-owning
back-edge, most commonly when an object stores a closure that refers to the
same object.

Inside the closure, a weak capture is optional because the target may have
already disappeared:

```luce run
class Item:
    value: i64

func make_reader(item: Item) -> func() -> i64:
    return [weak item] func():
        let live = item else Item(value = 0)
        return live.value

func main():
    var reader: (func() -> i64)? = none
    if true:
        let item = Item(value = 7)
        reader = make_reader(item)
        print(str(reader()))
    let read = reader else () => -1
    print(str(read()))
```

```output
7
0
```

The read of `item` upgrades the current weak target to an owned optional
snapshot. If the target is alive, that snapshot keeps it alive for the local
use. If it has been destroyed, the read is `none`. There is no unsafe dangling
or `unowned` capture.

## Breaking a stored callback cycle

An object that strongly owns a closure and is strongly captured by that
closure would keep both objects alive forever. Make the callback’s edge back
to the owner weak:

```luce run
class Node:
    value: i64
    callback: (func() -> i64)?

    func install():
        self.callback = [weak self] func():
            let live = self else Node(value = 0, callback = none)
            return live.value

func main():
    var callback: (func() -> i64)? = none
    if true:
        let node = Node(value = 42, callback = none)
        node.install()
        let installed = node.callback else () => -1
        callback = installed
        print(str(installed()))
    let read = callback else () => -1
    print(str(read()))
```

```output
42
0
```

The compiler diagnoses the direct stored-`self` strong-cycle form and points
toward a weak capture. Indirect object graphs can form cycles the compiler
cannot prove; the programmer still chooses one semantically non-owning edge.
ARC does not pretend to be a tracing cycle collector.

## Storing and returning closures

A closure may be returned, put in an optional, stored in a field, or placed in
a list, map, or array of a matching function type. Different elements may
carry different environments even though their callable type is the same.

Function types have no zero value. Use an optional slot when “no callback yet”
is meaningful, or require a present function through a custom initializer:

```luce module file=action.luc
class Action:
    apply: func(i64) -> i64

    init(apply: func(i64) -> i64):
        self.apply = apply
```

Parentheses distinguish an optional function from an optional answer:

- `(func(i64) -> i64)?` is either no function or a present function; and
- `func(i64) -> i64?` is always a function whose answer may be absent.

Function values have no equality or ordering. If callbacks need identity in
an application, store an explicit ID beside them rather than relying on their
hidden environment representation.

## Fallible and multi-value closures

Effects and return shape are part of the function type. A block closure may be
fallible, and it may answer several values using the same return-shape rules as
a named function. The caller must use `try` or `catch` for a fallible value and
destructure a multi-value answer.

The closure’s environment follows ordinary cleanup on every exit: return,
propagated error, handled error, and trap reporting all release the abandoned
locals and temporaries through the same ARC machinery.

## Worker boundary

A function value or a graph containing one cannot cross `spawn` or return from
a worker. Its environment can carry arbitrary references and mutable cells,
and Luce’s workers never share object identity. Pass plain data to a named
worker function and create worker-local closures inside that function instead.

The exact function grammar and storage forms are in [Types: Function
values](/guide/reference/types/#function) and [Expressions: Function values
and lambdas](/guide/reference/expressions/#function-values-and-lambdas).
Continue with [Enumerations](/guide/enums/).
