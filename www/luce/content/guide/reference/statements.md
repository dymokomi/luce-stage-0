# Statements and Declarations

## File structure

A file may contain `import` lines and file-scope `alias`, `const`,
`struct`, `class`, `interface`, `enum`, `union`, and `func` declarations in any
order. It has no executable top-level statements and no top-level `var`.

Each declaration form may carry the
[`pub`](#visibility) marker. Without it, the declaration is private to its
file.

## Entry

A program requires exactly one entry in one of four shapes:

```
func main():
func main() -> !:
func main(args: list[str]):
func main(args: list[str]) -> !:
```

The optional `list[str]` parameter receives the command line. With
`-> !`, an uncaught error ends the run and is reported by the host.
Any other parameter list or any value result is refused.

These are the only entry forms.

## alias {#alias}

```text
alias Name = Type
pub alias Name = Type
```

An alias is a transparent second spelling for the complete type on the right.
It is checked eagerly and erased before runtime. Aliases may chain and refer
forward; cycles, unknown targets, reserved names, top-level collisions, and
privacy violations are rejected.

The declaration is file-scoped and private by default. `pub alias` exposes
the name to importers; an unmarked alias stays inside the file. See
[Type aliases](../types/#type-aliases) for construction, namespaces, modules,
and the exact diagnostic matrix.

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

A parameter may declare a trailing default — `start: i64 = 0`, a
compile-time constant a call site may omit; call sites may name
arguments too (see [calls](../expressions/#calls)). Every path through
a function that declares a value return type must return; the compiler
checks it.

A plain function member of a struct, class, enum, or union is a [method](#methods):
its receiver is the implied local `self`. A member written `static
func` is instead a namespace function and has no receiver. There are
no variadics. Top-level and static namespace functions can be used as
values, returned and called indirectly through a [`func(...)`
type](../types/#function); methods become values only when bound to a receiver.
Expression lambdas and block closures are expressions rather than
declarations.

## struct

```
struct Name:
    field: Type
    pub field: Type
    ...

    pub func method(...):
        ...
    static func member(...):
        ...
```

Fields, implied-self methods and static namespace functions, in one indented block. Construction
names every field. A member may carry a [`pub`](#visibility) marker of
its own; without it, the member is private to the file.

## class {#class}

```
class Name:
    field: Type
    weak parent: Name?

    init(parameter: Type):
        self.field = parameter

    func method(...):
        ...

    deinit:
        ...

class Name: Interface, OtherInterface:
    ...
```

A class has the same fields, defaults, visibility regions, methods, static
namespace functions, and explicit interface-conformance list as a structure.
Without `init`, it also takes the same memberwise arguments. One
`init(parameters)` or fallible `init(parameters) -> !` body replaces that call
surface. It answers the class implicitly and must establish every stored field
on every successful path before `self` can exist. During the body, `self` may
only read or assign stored fields; it cannot escape or receive an instance
method call. Construction writes `Name(...)`; a bare `Name(...)` call on
a class is a compile error.

Class values are ARC references: successful `new` makes a new identity,
assignment shares it, and methods may mutate the object through a `let`
binding. `is` compares two references of the same nominal class type.

One bare `deinit` block is permitted. It has no parameters, result,
fallibility marker, visibility, or call syntax. ARC invokes it once at the
last strong release before releasing fields. It may read or update fields and
call methods, but cannot make its dying `self` strongly reachable again.

Classes are final. There is no inheritance, `override`, `super`, initializer
overloading or delegation, computed property, or class metatype.

## interface {#interface}

```
interface Name:
    func method(param: Type) -> Type
    func fallible(param: Type) -> Type!
```

An interface body contains instance-method signatures without bodies. A
conforming struct or class lists the interface after its name and must provide
every requirement exactly. A non-fallible witness may satisfy a fallible
requirement; the reverse is invalid. Interface declarations have no fields,
static methods, default bodies, inheritance, or generic parameters.

## enum {#enum}

```
enum Name:
    member
    member = constant
    ...

    func method(...):
        ...
    static func member(...):
        ...

enum Name(u8):
    ...
```

A set of named constants at one integer width. Members are
snake_case, one per line; a member with no value takes the previous
member's plus one, and an unvalued first member is 0. A written value
is a constant integer expression, folded like every other constant.

- Two members may not hold one number.
- The backing width is `i32` unless the declaration names another
  integer type; a member the width cannot hold is
  refused (`luce.sema.enum`).
- Members are reached only through the type: `Method.stored`, and
  `module.Method.stored` across an import.
- An enum takes the same methods and static namespace functions a
  `struct` takes, under the [same rules](#methods). A
  function may not wear a member's name.
- The declaration may carry a [visibility](#visibility) word; a member
  may not — an enum's members are what the type is.
- The zero value of an enum-typed slot is its **first declared
  member**, which is what `var m: Method` starts at and what
  `array[Method](n)` fills with.

## union {#union}

```
union Name:
    member
    member(field: Type, field: Type = constant)
    ...

    func method(...):
        ...
    static func member(...):
        ...
```

A set of members of which a value holds exactly one, each member
optionally carrying a parenthesized list of **named** payload fields
with optional trailing constant defaults. Members are snake_case, one
per line; [`match`](#match) is the only way to reach a payload.

- At least one member must carry a payload: a union of bare members
  is an enum, and is refused saying so (`luce.sema.union`).
- Payload fields are named, always; a positional payload is refused
  where it is written.
- A member is not a type — `let c: Shape.circle` is refused — and the
  union's own name is not a constructor: there is no `Shape(n)`.
- Construction is a namespaced call with named arguments,
  `Shape.circle(radius = 2.0)`, under the struct-construction rules;
  a bare member takes no parentheses.
- A member may not unconditionally contain its own union; the refusal
  names `?` — the recursion ends at absence or travels through an
  owning container. The 4096-value size bound that structs have
  applies here too, counting a union as `1 +` its largest member.
- A union takes the same methods and static namespace functions a
  `struct` takes, under the [same rules](#methods).
- The declaration may carry a [visibility](#visibility) word; a
  member may not — a union's members are what the type is.

## match {#match}

```
match expression:
    member:
        ...
    member(field, field):
        ...
    else:
        ...
```

```
match expression:
    0:
        ...
    1, 2:
        ...
    10..19:
        ...
    else:
        ...
```

Dispatch over an enum, a [union](#union), or a scalar value — an
integer, `char`, `str`, or `bool`. Over an enum or union, every arm is
a bare member name of that type; over a value, every arm lists
literals. Each arm opens a block, and `else` comes last.

- Without an `else`, **every member must have an arm**, and one that
  is missing is `luce.sema.match`, by name.
- An arm may not be written twice, and an `else` that covers nothing
  is refused.
- Arms are ordinary statement blocks: they declare, assign, loop,
  `break`, `continue` and `return`. A match all of whose arms return
  is a return.
- Over a value, an arm's patterns are literals the compiler can read
  (a folded constant counts), several per arm behind commas, matched
  against the scrutinee's own type. Integers and `char` may write an
  inclusive range, `low .. high`, refused when empty; `str` and `bool`
  list each value. The first arm that admits the value wins, so
  overlapping ranges are a style question — but the same exact literal
  twice is a dead arm and is refused. `else` is **required** unless
  the arms provably cover everything, which only `bool`'s `true` and
  `false` can. A float is refused as a scrutinee: floats never match
  a literal exactly, and `if` with a tolerance says what is meant.
- Over a union, an arm may follow its member with a parenthesized
  list of that member's payload fields. Each binds a local in the
  arm's scope **by the field's own name**; an object payload binds as
  an alias of what the scrutinee owns. The list is **all of the
  member's fields or none** — `member:` binds nothing — and a partial
  list is refused naming the missing fields, as is a name that is not
  a field of the arm's member. Bindings obey the no-shadowing rule
  (`luce.sema.duplicate`). An enum's arms bind nothing.
- There is no other door to a union's payload: no field access on a
  union value, no tag test, and no way to name a payload outside an
  arm — so reading the wrong member's payload is unrepresentable.

## Methods {#methods}

A plain function declared inside a `struct`, `class`, `enum`, or `union`
is a
**method** with an implied `self`. A namespace member says `static`.

```
func name() -> Type:                  # may read implied self
func name(param: Type):               # may write implied self
static func name(param: Type):        # has no self
```

`self` has the enclosing type and is available only in a method body;
writing it as a parameter is refused. `p.length()` resolves from `p`'s
type. There is no dispatch and no `Point.length(p)` type-qualified
form. A static member is called as `Point.origin()` and may be a
function value or worker target. A method may not be spawned, and it
is a function value only as a **bound** one — `p.length` where a
function type is expected, carrying `p`
([expressions](../expressions/#function-values-and-lambdas)).

The compiler infers whether a method writes its receiver. A store to
`self` or a value field, or a transitive call to another writer on
`self`, makes it a writer. Mutating a referenced object through a field does
not replace `self` and does not make the method a writer. For value receivers,
a reader accepts a `let` or temporary while a writer requires a bare mutable binding;
fields, indexes, narrowed values, `let` bindings, and
temporaries are refused. A class method mutates the shared object without
rebinding the receiver, so a `let` class reference, field, element, interface
witness, or bound class method may call it.

The writer aliases that caller slot in place, so it may replace a
reference-carrying receiver. Writes completed before an
error remain visible. Its declared return values are ordinary results;
the receiver is not hidden in the result shape.

## Visibility {#visibility}

A declaration is **private to its file** unless it says `pub`. `pub` is
the one visibility word, written in full immediately before the name it
exposes; there is no word for the default.

```
pub func name(...)
pub alias Name = Type
pub const name = expr
pub struct Name:
pub class Name:
pub field: Type
```

There is no region form. Each declaration and member states its own
visibility on its own line, so reading any one line tells the whole truth
about that member.

```
pub struct Name:
    pub field: Type
    hidden: Type

    pub func member(...):
        ...
```

Exactly one `pub` per declaration, and it stands only where a declaration
does.

| Written | Refusal |
|---|---|
| `pub pub func f()` | `one `pub` per declaration` |
| A `pub` on a local `let`, `var` or parameter | `visibility applies to file-scope declarations and struct members` |
| `pub:` at file scope | `` `pub` marks one declaration; write it before each name, not as a region `` |
| `static pub func f()` inside a struct | `visibility comes before static: write 'pub static func', not 'static pub func'` |

All are parse rules, under `luce.parse.*`.

```luce fail
pub:
    const value = 1

func main():
    print(str(value))
```

```output
luce: compile failed
main.luc:1:1: `pub` marks one declaration; write it before each name, not as a region [luce.parse.top]
    pub:
    ^~~~
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

Two or more names is a **destructuring bind**, one of the two ways a
call answering a [return shape](../types/#return-shapes) may hand its
values to names. One keyword governs the whole bind — `let a, var b`
is refused — and the names take their types from the call, so they
carry no annotations. The other way assigns existing `var` names.
There is no `_`: an unused name costs nothing and says what was
ignored.

Neither freezes what the name points at: `let xs = [1, 2]` still
permits `xs.append(3)`, and refuses `xs = [9]`. This is JavaScript's
`const`, not Swift's `let`.

The rule reaches every spelling of a store, not only the method call.
`xs[0] = 9`, `bag.counts[0] = 9` and `cells[0].value += 1` are all
legal through an immutable name, because the store lands in the heap
object rather than in the name — which is what lets a function fill a
container it was handed, since a parameter is a `let`-bound name. What
`let` refuses is a store that lands in the binding's own storage:
`p.x = 3` and `p.inner.y = 3` on a struct **value**, at any depth,
because a value lives in the name.

```luce run
struct Cell:
    var value: i64

func bump(cells: list[Cell]):
    cells[0].value += 1

func main():
    let cells: list[Cell] = [Cell(value = 1)]
    cells[0].value = 10
    bump(cells)
    print(str(cells[0].value))
```

```output
11
```

No name may shadow one from an enclosing scope. A loop variable is
immutable inside its body.

## Assignment

Two or more existing mutable names may receive one return shape:

```
low, high = minmax(xs)
```

Every target must be a distinct bare `var` name already in scope. The
right side is one call, whether direct, namespaced or a method, and its
arity must match the names. Fields and indexes are not multi-return
targets, and there is no compound form, comma-list right side, or `_`
target. A destructuring `let`/`var` remains the form that declares new
names.

This assignment is parallel and two-phase. It checks every target,
evaluates the right side, and extracts and prepares the whole answer
before any replacement. Only then are the old values replaced, left
to right, so `left, right = swapped(left, right)` is a swap and an
owning target is not released before every answer is safe to store.

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

A **nested** place assigns a value (a number, a `str`, or a plain
struct). To restock an *object* field use the single-level form:
`bag.items = [1, 2]`.

Compound assignment is `+= -= *= /= //= %=`, value-only arithmetic —
the place is a number, or a `str` for `+=` — and the place is
evaluated once, so `counts[key] += 1` looks the key up a single time.
A **map** key that is not there is defined at the value type's zero
and then applied to; a list or array index out of range still traps.

```luce run
func main():
    var counts = map[str, i64]()
    counts["a"] += 5
    var text = "x"
    text += "y"
    print(f"{counts["a"]} {text}")
```

```output
5 xy
```

A compound assignment keeps the place's concrete numeric type: `b += 1` on
a `u8` performs checked `u8` addition and traps `integer_overflow` at 255
rather than widening or wrapping.

## if / elif / else

```
if condition:
    ...
elif condition:
    ...
else:
    ...
```

The condition is `bool`. There is no ternary operator; dispatch over
an enum's members or a scalar's literal cases is [`match`](#match).

## while

```
while condition:
    ...
```

## for

```
for name in range(low, high):     i64, excluding high
for name in sequence:             list or rank-1 array elements, in order
for name in map:                  map keys, in insertion order
for index, name in sequence:      position and element
for key, value in map:            key and value
```

The loop variable is immutable inside the body. Do not grow or shrink a
collection while iterating it: bounds stay checked per step,
but which elements are visited is the program's problem.

## break, continue, return, try

All four leave one or more scopes and release the local references they leave
behind. `return` copies a value result or retains a reference result for the
caller before releasing the frame.

## Expression statements

A call may stand alone as a statement when it answers nothing. An expression
that produces a value and gives it to no one is `luce.sema.unused` — the
shape of a forgotten `let`, of a method mistaken for the mutating one beside
it, and of a result whose failure the caller meant to check.

A **fallible** call standing alone must be `try`ed or `catch`ed; ignoring it
is `luce.sema.fallible`.

### discard {#discard}

`discard(EXPRESSION)` is the one statement that drops a result on purpose:

```text
discard(session.close())
discard(try parse(line))
discard(counter.bump()) catch reason:
    print(reason)
```

It takes exactly one value, positionally, and the value must be one there was
something to drop — `discard` of a call that answers nothing is refused,
because the call belongs on its own line. It accepts any type, including a
multi-value answer, which is why it has no ordinary signature and is a
reserved word instead.

`discard` says nothing about errors. A fallible call inside one is still
`try`ed or `catch`ed as it would be anywhere else; only the value is
dropped.

A discarded returned reference is a statement temporary and is released at the
end of the statement.

## Guarded statements

Three written statement shapes take an indented `catch` handler, and
no others: a call written as a statement, a single-place assignment
whose value is a call, and an existing-name multi-return assignment.

```
CALL catch:                       CALL catch NAME:
    ...                               ...

PLACE = CALL catch:               PLACE = CALL catch NAME:
    ...                               ...

NAMES = CALL catch:               NAMES = CALL catch NAME:
    ...                               ...
```

The handler guards exactly one call, so which statement failed has one
answer. `NAME` binds the error's message — an immutable `str`
scoped to the handler block. For a multi-return assignment, success
performs every replacement store and failure performs none; ordinary
side effects from evaluating the right side remain visible in the
handler. A `let` takes no handler (the handler supplies no value) and
neither does a compound assignment (it reads its place before the call,
so two things stand in front of the word and only one can fail). Both
are `luce.parse.expected`. A handler
behind a call that cannot fail is `luce.sema.fallible`. See
[failure](../failure/).

## File-scope constants

File scope declares with `const`. `let` and `var` declare inside
functions; top-level `let` is retired, and there is no top-level
`var`.

```luce run
const width = 80
const margin = 4
const usable = width - margin * 2
const title = "Luce"
const banner = title + " console"

func main():
    print(f"{banner}: {usable} columns")
```

```output
Luce console: 72 columns
```

Initializers fold at compile time. Foldable forms include literals,
other constants (including `module.constant` through an import),
numeric and bitwise expressions, comparisons and boolean logic, string
concatenation, the eight conversion constructors and `ord()`, enum
members and conversions from enums (`i32(m)`, `str(m)`), and
reference-free value-struct construction.
`none` also folds when a `T?` annotation supplies the absent type; bare
`const x = none` is refused because it supplies no `T`.

Function values, general calls, `new`, and `spawn` are **not** constant.

Constants may reference each other in any order but never in a cycle.
Every value use site inlines the fold. A `const` may also hold one flat
container construction:

```
const ITEMS: list[i64] = [3, 1, 2]
const WORDS = {"and": true, "break": true}
const ORDER: array[i64, _] = [16, 17, 18, 0]
```

- Elements may be scalars, strings, enum values, or reference-free value
  structs. Such a struct may contain an optional field, but an optional
  top-level element or map value is refused.
- A bracket literal is a `list` unless an `array[T, _]` annotation
  makes it rank 1. Empty list and array constants need an annotation,
  but its element type must still be flat and non-optional; zero
  elements do not waive the constant-container boundary.
- Constant containers are flat: no nested container, builder,
  reference-carrying struct, or multidimensional array.
- A constant map rejects duplicate folded keys and names both sites.
  Empty `{}` is not a literal; use `map[K, V]()`.
- One written construction is one identity. Aliases, imports and
  parameter defaults share it; separately written equal
  constructions do not.
- A parameter default may share a constant container, but every attempted
  mutation still traps `immutable_object`.

The reachable rows are eagerly materialized into each runtime's
program root before user code; unreachable rows are pruned. The root
lives until teardown. Reads and iteration are ordinary. A list slice and map
`keys()`/`values()` create fresh reference objects.
Arrays have indexing and iteration, but no slice expression or universal
deep-copy operator. Retaining or returning a constant reference is safe
because it remains immutable for the
runtime's life. Direct or aliased mutation traps
`immutable_object` before writing.

Constants share the module namespace and visibility rules. A `pub`
container may not expose a private element type, just as a `pub`
function signature may not expose one.

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
