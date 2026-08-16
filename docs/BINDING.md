# Bound methods — the method travels with its receiver

A **bound method** is `receiver.method` written where a `func(T, ...) ->
R` value is expected: a function value whose environment is the receiver.
Nothing anonymous enters the language — the environment is a struct or
enum the program declared, with a name, a layout, and visible
fields. This is the reference for how a bind is spelled, typed, stored,
and called. Plain function values and lambdas have their own reference
(`docs/FUNCTIONS.md`).

One sentence carries the feature: **a bound method is a function value
that carries its receiver.** A value receiver — a plain `struct` or an
`enum` — is copied into the value. Reference fields inside that receiver remain
aliases of the same objects and are retained by the bind until the function
value dies. User-defined class receivers and capturing closure environments
are planned rather than current behavior.

## The bind, spelled and typed

`receiver.method` binds where a matching `func` type lands, with the
receiver's parameter dropped from the written signature. There is **no
marker**: the member-access spelling is the whole syntax, and what makes
it a bind is the landing place — exactly as a bare function name becomes a
value by landing (`docs/FUNCTIONS.md`).

```luce
struct Scale:
    factor: long

    func times(n: long) -> long:
        return n * self.factor

func apply(n: long, f: func(long) -> long) -> long:
    return f(n)

func main():
    let s = Scale(factor = 3)
    let f: func(long) -> long = s.times
    print(string(apply(5, f)))
    print(string(f(10)))
```

`Scale.times` is declared `func times(n: long) -> long` with an implied
`self`; bound, it wears `func(long) -> long` — the receiver parameter
gone, the passed parameter kept. Stage 4 resolves the bind in the same
`.field` arm that resolves `Struct.helper`: when the head does not name a
declaration, the target lowers as a value and its type is asked for a
method of that name. A miss is *not a bind*, and the field path says what
it always said about `p.x`.

The receiver a bind carries is its own value copy, so writing the original
afterwards does not reach its value fields. References inside that copied
receiver name the same objects but are currently borrowed from the original
owner. Returning or storing the bound value past that owner's lifetime is
unsafe in the current implementation and is a Phase 0 fix.

## No equality, no ordering

A function value has no equality or ordering. It is the function it names
*and* the receiver it may carry, and its type cannot say which — so
comparing by function alone would call two binds of one method equal
whatever they carry, which is not an honest answer. `==` and `!=` are
refused, and the refusal is **transitive**: it reaches every comparison
that descends into a function value — `==` on a struct that holds one, and
`find`/`contains` over a container of them. The walk that decides it is
the walk `==` itself uses (`04_semantics/shapes.zig`'s
`incomparablePart`): it descends a struct's field run, a union's run and
an optional's payload, and it **stops at a reference**, because `==` does —
reference equality is identity and never reads the contents. So a struct
holding `list(Button)` still compares by the references it holds, an
honest `==`. `06_mir/verify.zig` refuses the same shape in a decoded
module, which makes the runtime comparator's function arm unreachable
rather than merely unreached. `string(f)` is how a program asks what a
value names, and the honest workaround for a search is to keep a name or
an enum beside the values and search that.

## A function value is storable

A function value lives in a struct field, a list element, an
array cell, a union payload field, and a map value. In the four slots that
exist before anything fills them it is written as an **optional**,
`(func(...) -> R)?`, because a function value has no zero and absence is
the zero `T?` already means:

```luce
struct Button:
    label: string
    on_click: (func(long) -> long)?

func twice(n: long) -> long:
    return n * 2

func main():
    let b = Button(label = "ok", on_click = twice)
    let handler = b.on_click
    if handler != none:
        print(string(handler(21)))
```

### The grammar rule: a parenthesized type is that type

`func(long) -> string?` already means *a function answering an optional
string* — the result type is parsed by the ordinary type production and
consumes its own `?` first, which is how `parse_int` is written as a
value. To say "a function that may be absent" the function type must close
before the `?` reaches it. The rule is uniform: **`(T)` is `T`**, accepted
wherever a type may stand and required nowhere. `long?` is unchanged,
`(long)?` parses to the same type and says nothing extra, and
`(func(long) -> string)?` is the one thing that becomes newly writable. In
return position the arity separates the two productions — one type in
parentheses is a parenthesized type, two or more is a return shape.
`writeTypeName` parenthesizes a function payload and nothing else, so a
diagnostic's spelling reads back as the same type.

Every stored function value owns its two-slot run. A bound method also owns its
copied value receiver and retains every reference that receiver carries. It
may therefore be returned, placed in an aggregate, or called after the
original receiver binding has ended. Destroying the function value releases
those references exactly once.

### Where a function value stands, and why the map is different

| slot | written | why |
|---|---|---|
| struct field | `(func(...) -> R)?` | `var row: Row` creates it zeroed |
| array cell | `(func(...) -> R)?` | `new array(T, n)` creates it filled |
| list element | `(func(...) -> R)?` | uniform with the two above |
| union payload field | `(func(...) -> R)?` | a union's zero is its first member, fields at their own zeros |
| **map value** | `func(...) -> R` | see below |
| parameter, `let`, return | `func(...) -> R` | a value is always present |

A **map value** is the one slot no container ever creates: it exists
because `put` created it, and `m.get(k)` already answers `V?`. So the
absence is the missing key, the type is written bare, and
`map(K, (func(...) -> R)?)` is refused because it would make `get` answer
a `V??`, which has no representation. `m.values()` is refused on that one
map — it answers `list(V)`, and a bare `func` type is legal as a map value
but not as a list element, so `values()` would manufacture a type no
program can write; the refusal names the loop that works (walk `m.keys()`
and read `m.get(k)`). `m.keys()` is untouched, because every key type is
also an element type.

### Storing and calling in place

A bare map value is callable where it is read — the receiver rides in the
value, so calling it in place calls it on the state it carries:

```luce
func scale(n: long) -> long:
    return n * 2

func main():
    var actions: map(string, func(long) -> long) = {"double": scale}
    print(string(actions["double"](21)))
```

The four optional slots are **not** callable in place. Narrowing is
locals-and-parameters-only — a field or an element can change between the
test and the use — so a `(func(...) -> R)?` field must be bound to a local,
tested, and called through the local. The refusal names the field, says
it may hold none, and writes out the three lines that work:

```text
rows.render is (func(long) -> string)? and may hold none; only a local
or a parameter narrows, so bind it first (let render = rows.render),
test it (if render != none:), then call render(…) [BINDING.md]
```

## Union member constructors are function values

A union member constructor is a function value the same way a named
function is:

```luce
union Msg:
    query_changed(query: string)
    quit

func build(f: func(string) -> Msg) -> Msg:
    return f("hi")

func main():
    let m = build(Msg.query_changed)
    match m:
        query_changed(query):
            print(query)
        quit:
            print("quit")
```

`Msg.query_changed` where a `func(string) -> Msg` lands is the constructor
for that member: the payload fields are the parameters in declaration
order, and the union is the result. A payload-less member — `Msg.quit` —
stays a value, not a function, and the landing place says which it wanted.
Nothing downstream of stage 4 learns that a constructor exists: the
analyzer synthesizes the top-level function the reader would have written
and emits the `const_function` a named function emits, reusing the written
head so an imported union resolves from the reference site's own module.

## Refusals

- **A writing method does not bind.** A writer requires one bare mutable
  receiver aliased in place (`docs/SELF.md`); binding one would make an
  inout closure whose store-back discipline is a separate question. The
  refusal names the reading form.
- **A fallible function type does not exist.** `func(T) -> R!` and
  `func() -> !` are refused where they are written, so a fallible method
  does not bind and `try EXPR(args)` on a function value is refused by
  name — a function type carries no `!`.
- **A function value does not cross a worker boundary**, as a spawned
  function's parameter or as its result, because it may hold a bound receiver
  and callable environments are not part of the worker graph-copy contract
  (`docs/MEMORY.md`, `docs/THREADS.md`).
  A call *through* a value type-checks its arguments exactly as a direct
  call does.
- **Captures are refused today.** A lambda that needs state currently
  names a struct and binds a method. ARC closure environments are planned
  in `docs/ROADMAP.md`.

## Representation and dispatch

A function value is the pair `{function, receiver}`, carried by both
engines as a **two-slot run**: slot 0 the function's index in the program
table, slot 1 the receiver or `none`. The run length and the two slot
numbers are stated once, in `06_mir/defs.zig` beside `boxTag`. The run is
built the same way whether the value carries a receiver or not, which
costs a plain function value one allocation it would not otherwise make
and buys the thing worth having: no reader of a function value branches on
boundness, so a place that holds a `func(...)` cannot tell — and must not
be able to tell — which of a plain function, a lambda, or a bind it holds.
`luce_rt_function_make` is the run's constructor beside
`luce_rt_struct_make`; copying a function value copies the two-slot run
and shares whatever reference sits in slot 1.

The backend dispatches through **adapters**. A call site cannot know
whether the value in its hand carries a receiver — one `func(Point, Point)
-> bool` place accepts a plain function, a lambda, and a bind — but a C
signature is chosen at compile time. So the function table holds one
adapter per function some `const_function` names: `luce.bound.N` takes a
receiver slot after the depth, unboxes it into the callee's parameter zero
when the value is a bind, and ignores it when it is not. Every indirect
call passes the receiver slot of the run it is calling through, at the
price of one extra call frame per call *through a function value* — the
alternative was two calling conventions at a site that cannot tell them
apart. The interpreter needs none of this: it has the program in front of
it and prepends the receiver to the argument run.

In `05_hir`, a call's `ResolvedCallee.Indirect` carries the callee **node**
rather than a local id and a narrowed flag, so a narrowed name records the
same `narrowed_get` every other read of it produces and the storable form
needs no bookkeeping of its own. The callee is the call's first operand in
evaluation order, the way a method's receiver is, and it rides the same
spill machinery the arguments do.
