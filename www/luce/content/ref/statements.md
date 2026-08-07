# Statements and declarations

## File structure

A file holds, in any order: `import` lines, top-level `let`
constants, `struct` declarations, `enum` declarations, and `func`
declarations. There is no top-level executable code and no top-level
`var`.

Each of the four declaration forms may carry a
[visibility](#visibility) word. Without one it is public.

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

A parameter may be prefixed `give` to take ownership of an object,
and may declare a trailing default — `start: long = 0`, a
compile-time constant a call site may omit; call sites may also name
arguments (see [calls](../expressions/#calls)). Every path through a
function that declares a value return type must return; the compiler
checks it.

A function declared inside a struct whose first parameter is the word
`self` is a [method](#methods), called on a receiver. There are no
variadics and no first-class functions.

## struct

```
struct Name:
    field: Type
    private field: Type
    ...

    private:
        field: Type
        func member(...):
            ...

    func member(...):
        ...
```

Fields and namespaced functions, in one indented block. Construction
names every field. A member may carry a [visibility](#visibility) word
of its own, or sit in a region that carries one for the group; without
either it is public.

## enum {#enum}

```
enum Name:
    member
    member = constant
    ...

    func member(...):
        ...

enum Name(byte):
    ...
```

A set of named constants at one integer width. Members are
snake_case, one per line; a member with no value takes the previous
member's plus one, and an unvalued first member is 0. A written value
is a constant integer expression, folded like every other constant.

- Two members may not hold one number.
- The backing width is `int` unless the declaration names one of
  `byte`, `short`, `int`, `long`; a member the width cannot hold is
  refused (`luce.sema.enum`).
- Members are reached only through the type: `Method.stored`, and
  `module.Method.stored` across an import.
- An enum takes the same methods and namespace functions a `struct`
  takes, under the [same rules](#methods), `var self` included. A
  function may not wear a member's name.
- The declaration may carry a [visibility](#visibility) word; a member
  may not — an enum's members are what the type is.
- The zero value of an enum-typed slot is its **first declared
  member**, which is what `var m: Method` starts at and what
  `new array(Method, n)` fills with.

## match {#match}

```
match expression:
    member:
        ...
    member:
        ...
    else:
        ...
```

Dispatch over an enum. The scrutinee must be one; every arm is a bare
member name of that enum, and each opens a block. `else` is optional
and comes last.

- Without an `else`, **every member must have an arm**, and one that
  is missing is `luce.sema.match`, by name.
- An arm may not be written twice, and an `else` that covers nothing
  is refused.
- Arms are ordinary statement blocks: they declare, assign, loop,
  `break`, `continue` and `return`. A match all of whose arms return
  is a return.

## Methods {#methods}

A function declared inside a `struct` or an `enum` is a **method**
exactly when its first parameter is the keyword `self`.

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

## Visibility {#visibility}

A declaration is **public** unless it says `private`. Both words are
keywords, both are written in full, and `public` where public is
already the default is legal and inert.

```
private func name(...)        public func name(...)
private let name = expr       public let name = expr
private struct Name:          public struct Name:
private field: Type           public field: Type
```

Inside a `struct`, and nowhere else, a **region** label opens an
indented block of members — fields and functions alike — and every
member of the block takes the label's visibility.

```
struct Name:
    private:
        field: Type

        func member(...):
            ...
```

Labels may repeat and appear in any order, and a member outside every
region takes the default. The parser resolves each label onto its
members, so a region and a per-declaration word produce exactly the
same program.

Exactly one word per declaration, and the word stands only where a
declaration does.

| Written | Refusal |
|---|---|
| `public private func f()` | `one visibility word per declaration` |
| A word on a local `let`, `var` or parameter | `visibility applies to file-scope declarations and struct members` |
| `private:` at file scope | `a visibility region belongs inside a struct; at file scope mark each declaration` |
| A word on a member already inside a region | `NAME is inside a private region, which already says it` |
| A region label with no member under it | the refusal every empty block gets |

All five are parse rules, under `luce.parse.*`.

```luce fail
struct Box:
    private:
        private value: long

func main():
    var b = Box(value = 1)
    print(string(b.value))
```

```output
luce: compile failed
main.luc:3:9: value is inside a private region, which already says it [luce.parse.expected]
            private value: long
            ^~~~~~~
```

What a marker *means* across a module boundary — reference sites,
construction, fields, public surfaces, and `main` — is
[modules](../modules/#visibility).

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

A **nested** place assigns a value (a number, a `string`, or a plain
struct). To restock an *object* field use the single-level form:
`bag.items = [1, 2]`.

Compound assignment is `+= -= *= /= //= %=`, value-only arithmetic —
the place is a number, or a `string` for `+=` — and the place is
evaluated once, so `counts[key] += 1` looks the key up a single time.
A **map** key that is not there is defined at the value type's zero
and then applied to; a list or array index out of range still traps.

```luce run
func main():
    var counts = new map(string, long)
    counts["a"] += 5
    var text = "x"
    text += "y"
    print(f"{counts["a"]} {text}")
```

```output
5 xy
```

A storage-width place combines at its arithmetic type and narrows
back: `b += 1` on a `byte` is `b = byte(b + 1)`, and it traps
`conversion_range` at 255 rather than wrapping.

## if / elif / else

```
if condition:
    ...
elif condition:
    ...
else:
    ...
```

The condition is `bool`. There is no ternary operator; dispatch over a
value whose cases have names is [`match`](#match).

## while

```
while condition:
    ...
```

## for

```
for name in range(low, high):     long, excluding high
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

## Guarded statements

Two statement shapes take an indented `catch` handler, and no others:
a call written as a statement, and a plain assignment whose value is a
call.

```
CALL catch:                       CALL catch NAME:
    ...                               ...

PLACE = CALL catch:               PLACE = CALL catch NAME:
    ...                               ...
```

The handler guards exactly one call, so which statement failed has one
answer. `NAME` binds the error's message — an immutable `string`
scoped to the handler block. A `let` takes no handler (the handler
supplies no value) and neither does a compound assignment (it reads
its place before the call, so two things stand in front of the word
and only one can fail). Both are `luce.parse.expected`. A handler
behind a call that cannot fail is `luce.sema.fallible`. See
[failure](../failure/).

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
`long()`/`double()`, and value-struct construction.

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
