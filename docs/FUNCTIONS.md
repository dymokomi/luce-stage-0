# Functions as values

A function is a value in Luce. Where a `func(...)` type is expected, a
named function stands as a value, and a one-expression **lambda** may be
written in place. This is the reference for both forms: how they are
spelled, how they are typed, and how a call through a value behaves.
Bound methods — `receiver.method` as a value carrying its receiver — are
a related form with their own reference (`docs/BINDING.md`).

## The line the feature draws

An inline function that touches **only its own parameters** is a function
pointer wearing clean syntax — no environment, nothing hidden. A function
that reaches a variable from an enclosing scope is a *closure*, and
closures carry an environment the reader cannot see on the page. Luce's
lambdas are **capture-free**: the compiler enforces it today, and a body
that needs state that travels with behavior names a struct
with a method instead — the state explicit, named, and visible. Capturing
closures are the memory model's direction (`docs/MEMORY.md`); until they
land, the lambda stays capture-free.

## A named function is a value

A named top-level function, a `static func` member, and a function
reached through an import are all values where a function type is
expected. Write the bare name, no call parentheses:

```luce
import std.lists

struct Player:
    score: i64

func by_score(a: Player, b: Player) -> bool:
    return a.score < b.score

func main():
    var xs = [Player(score = 3), Player(score = 1), Player(score = 2)]
    xs.sort_by(by_score)
    for p in xs:
        print(str(p.score))
```

Resolution runs through the same head-names-a-declaration path that
serves `Struct.helper` and `module.func`. A **method** is not a plain
value this way — it carries a receiver, and `receiver.method` is the form
that binds it (`docs/BINDING.md`).

## Function types

`func(T, ...) -> R` in type position writes a function's shape:
parameter types only, no names, and `-> R` optional exactly as it is on a
declaration. It annotates a parameter, a `let`, a struct field, a
container element, a map value, and a union payload field:

```luce
import std.lists

struct Player:
    score: i64

func sort_players(xs: list[Player], before: func(Player, Player) -> bool):
    xs.sort_by(before)

func main():
    var xs = [Player(score = 2), Player(score = 1)]
    sort_players(xs, (a, b) -> a.score < b.score)
    print(str(xs[0].score))
```

Where a value must exist before anything fills it — a field, an array
cell, a list element, a union payload field — a function type is written
as an **optional**, `(func(...) -> R)?`, because a function value has no
zero and absence is that zero. The grammar and the storable form are set
out in `docs/BINDING.md`.

## The lambda: a parameter list, an arrow, one expression

A lambda is a parenthesized parameter list, an arrow, and a single
expression:

```luce
import std.lists

struct Player:
    score: i64

func main():
    var xs = [Player(score = 3), Player(score = 1), Player(score = 2)]
    xs.sort_by((a, b) -> a.score < b.score)
    print(str(xs[0].score))
```

- **Parameters are bare names.** Their types come from the function type
  the lambda lands on — a lambda has no type until it lands on one, the
  same rule a numeric literal lives by. A lambda in a place that expects
  no function type is refused: *a lambda needs a place that expects a
  function.*
- **One expression, no block.** A body that wants statements is a named
  function wanting a name. The single expression keeps the form from
  secretly growing state and sidesteps the return-inside-lambda question.
- **The parse is unambiguous.** `(a, b)` can open nothing else — there
  are no tuples — and the single-parameter case `(x) -> …` resolves at
  the arrow.
- **No capture.** The body may name its parameters, file-scope constants,
  and visible functions — the set a top-level function's body may name.
  Reaching an enclosing local is refused: *a lambda carries no
  environment; state that travels with behavior is a struct with a
  method.*

A lambda lowers to a compiler-named top-level function: after the
analyzer runs it *is* the named case, the same MIR instruction and the
same dispatch. Both forms dispatch through the program's function table,
and `libluce_rt` learns nothing about lambdas as such.

## Calling through a value

A call through a value is positional. The interned function type states
the arity and the argument types; a function type has no parameter names
and no defaults, so a named argument is refused where it is written. A
call suffix `EXPR(args)` applies to **any** expression whose type is a
`func(...)`, and it is checked exactly as a call through a named value:

```luce
func scale(n: i64) -> i64:
    return n * 2

func main():
    var actions: map[str, func(i64) -> i64] = {"double": scale}
    print(str(actions["double"](21)))
```

`EXPR(args)` parses wherever `EXPR[i]` does — one more postfix suffix
beside the index and the field access — so `chooser()(5)`, `m["a"](1)`
and `(f)(x)` are all calls, not parse errors. The head-names-a-declaration
forms — `f(x)`, `Struct.helper(x)`, `module.func(x)`,
`receiver.method(x)`, `Union.member(field = v)`, `Enum(n)`, and every
builtin — resolve through their written text and win; the suffix takes
what is left, exactly the set that has no name to resolve. A call through
a value is never fallible, because a function type carries no `!`, so
`try EXPR(args)` is refused. `spawn` takes a declared call and nothing
else.

## No equality, no ordering

Function values have no equality or ordering, and copying one costs
nothing. `string(f)` answers the function's name:

```luce
func by_score(a: i64, b: i64) -> bool:
    return a < b

func main():
    let f: func(i64, i64) -> bool = by_score
    print(str(f))
```

Two function values cannot be compared with `==` or `!=`: a value is the
function it names *and* the receiver it may carry, and its type cannot
say which, so comparing by function alone would call two binds of one
method equal whatever they carry. The refusal is transitive — it reaches
`==` on a struct that holds a function value and `find`/`contains` over a
container of them — and the honest workaround is to keep a name or an
enum beside the values and search that (`docs/BINDING.md`).

## The standard-library customer

`std.lists` provides stable `xs.sort_by(before)` for every list element
type, taking a `func(T, T) -> bool`. It is routed through method syntax
after `import std.lists`, not a runtime builtin. It is the proving
customer for function values: sorting by a computed key is a comparator a
call site writes, as a named function or a lambda, and hands in.
