# Statements and declarations

## File structure

A file holds, in any order: `import` lines, top-level `let`
constants, `struct` declarations, and `func` declarations. There is no
top-level executable code and no top-level `var`.

## Entry

A program requires exactly one `func main():`, and that is the whole
of it — no parameters, no return type. It may declare `-> !`, in
which case an uncaught error ends the run and is reported by the host.

There is no second entry mode.

## func

```
func name(param: Type, ...) -> Type:
func name(param: Type, ...) -> Type!:
func name(param: Type, ...) -> (Type, Type, ...):
func name(param: Type, ...) -> (Type, Type, ...)!:
func name(param: Type, ...) -> !:
func name(param: Type, ...):
```

A parenthesised list of **two or more** types is a
[return shape](../types/#return-shapes): the function answers that
many values. It is not a type, and it may be written nowhere but here.

A parameter may be prefixed `give` to take ownership of an object.
Every path through a function that declares a value return type must
return; the compiler checks it.

There are no default values, no named arguments, no variadics, no
receivers and no first-class functions.

## struct

```
struct Name:
    field: Type
    ...

    func member(...):
        ...
```

Fields and namespaced functions, in one indented block. Construction
names every field.

## Methods {#methods}

A function declared inside a `struct` is a **method** exactly when its
first parameter is the keyword `self`.

```
func name(self) -> Type:              # reads the receiver
func name(var self, param: Type):     # writes it back
func name(param: Type):               # a namespace function
```

`self` is bare and untyped — inside `struct Point` it can be nothing
but a `Point`, so `self: Point` is refused, and it must come first.

`p.length()` **means** `Point.length(p)`: the same call, resolved at
compile time. There is no dispatch and no bound method value.
`Point.length(p)` stays callable and means the same thing.

`var self` writes the receiver back — `p.scale(2.0)` means
`p = Point.scale(p, 2.0)`. Its receiver must be a place whose root is
a mutable local, so a `let` receiver and a call result are both
refused, and the static form `Point.scale(p, 2.0)` is refused because
it has no place to write to. The struct must carry no objects; one
that does mutates through its fields from a plain `self`.

A `var self` method may answer values of its own, and then its
receiver is result zero: `let roll = rng.next()` writes `rng` back and
binds `roll`, and the declared arity is what the call site sees.

## let and var

`let name = expr` and `let name: Type = expr` bind once. `var` allows
reassignment. `var name: Type` with no initializer declares the
binding and leaves the slot at its type's zero value.

```
let low, high = minmax(xs)
var row, column = grid.find(target)
```

Two or more names is a **destructuring bind**, and the only place a
call answering a [return shape](../types/#return-shapes) may hand its
values to names. One keyword governs the whole bind — `let a, var b`
is refused — and the names take their types from the call, so they
carry no annotations. There is no `_`: an unused name costs nothing
and says what was ignored.

Neither freezes what the name points at: `let xs = [1, 2]` still
permits `xs.append(3)`, and refuses `xs = [9]`. This is JavaScript's
`const`, not Swift's `let`.

No name may shadow one from an enclosing scope. A loop variable is
immutable inside its body.

## Assignment

Plain multi-assignment is **not** a statement: `low, high = f()` is
refused, because a destructuring bind declares its names. What Go
needs multi-assignment for is `v, err = f()`, and Luce has no `err`.

The target is a **place**: a name, a field, or an index, nested
freely.

```
name = expr
name.field = expr
name.inner.field = expr
xs[i] = expr
grid[r, c] = expr
cells[0].value = expr
```

The place is read once — every subscript evaluated exactly once — and
then rebuilt: value structs update functionally up to their root
binding, and the innermost container element is written in place.

A **nested** place assigns a value (a number, a `String`, or a plain
struct). To restock an *object* field use the single-level form:
`bag.items = [1, 2]`.

Compound assignment is `+= -= *= /= //= %=`, value-only arithmetic —
the place is a number, or a `String` for `+=` — and the place is
evaluated once, so `counts[key] += 1` looks the key up a single time.

```luce run
func main():
    var counts = new Map(String, Int)
    counts["a"] = 0
    counts["a"] += 5
    var text = "x"
    text += "y"
    print(f"{counts["a"]} {text}")
```

```output
5 xy
```

## if / elif / else

```
if condition:
    ...
elif condition:
    ...
else:
    ...
```

The condition is `Bool`. There is no ternary operator and no `switch`.

## while

```
while condition:
    ...
```

## for

```
for name in range(low, high):     Int, excluding high
for name in sequence:             list or rank-1 array elements, in order
for name in map:                  map keys, in insertion order
for index, name in sequence:      position and element
for key, value in map:            key and value
```

The loop variable is immutable inside the body. Do not grow, shrink or
free a collection while iterating it: bounds stay checked per step,
but which elements are visited is the program's problem.

## break, continue, return, try

All four leave one or more scopes, and all four free whatever those
scopes still own. `return` additionally moves the returned binding to
the caller.

## Expression statements

A call may stand alone as a statement. A **fallible** call standing
alone must be `try`ed or `catch`ed; ignoring it is
`luce.sema.fallible`.

An ignored returned object is a statement temporary and is freed at
the end of the statement.

## File-scope constants

A top-level `let` declares a compile-time constant.

```luce run
let width = 80
let margin = 4
let usable = width - margin * 2
let title = "loom"
let banner = title + " console"

func main():
    print(f"{banner}: {usable} columns")
```

```output
loom console: 72 columns
```

Initializers fold at compile time. What may be folded is: literals,
other constants (including `module.constant` through an import),
arithmetic, comparisons, `and`/`or`, string concatenation,
`Int()`/`Float()`, and value-struct construction.

Calls are **not** constant. Heap objects are not constant either, and
the reason is ownership rather than an arbitrary limit: a top-level
binding has no scope to die at, so it cannot own an object, so `new`,
list literals, slices and indexing are all refused there, as is a
struct whose layout carries objects.

Constants may reference each other in any order but never in a cycle.
Every use site inlines the folded value, so an unused constant costs
nothing to ship, decode or compile.

## Scope

One scope per **file** (constants, structs, functions), per **struct**
(its namespaced functions), and per **function** — where parameters and
every indented block get one, so `if`, `while` and `for` bodies open
nested scopes.

Nothing is visible without an import. There is no shadowing anywhere.

## Dead code

A statement below one that never comes back — `return`, `break`,
`continue`, `trap(...)`, `error(...)`, or an `if` whose arms all leave
— is refused, naming the terminator and its line.

```luce fail
func main():
    let a = 1
    return
    let b = a
```

```output
luce: compile failed
main.luc:4:5: this cannot run: the return on line 3 leaves the block first; delete it, or move it above the return [luce.sema.unreachable]
        let b = a
        ^~~~~~~~~
```

The compiler has one severity, so this is a refusal or nothing. It is
a refusal for the reason `a < b < c` is: the way the code reads and the
way it runs disagree. An unused local is *not* refused — that is
redundant rather than misleading.

An `if` counts only when **every** arm leaves, so an early-return guard
with no `else` is untouched, and one terminator is one report however
many lines it stranded.

Functions unreachable from the entry point never reach the compiled
module, so an unused `import std.math` costs nothing to ship, decode
or compile.
