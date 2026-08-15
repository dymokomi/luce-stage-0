# GENERICS.md — a proposal, direction ratified

> **Status.** Direction ratified, not built (2026-08-14). This is the
> design record for parametric generics in Luce. The owner has decided
> to pursue generics — for typed reusable abstractions (`Vec[T]`,
> `Stack[T]`) and to make a UI runtime that fully hides the loop —
> having weighed the honest alternative below and chosen the fully
> hidden loop over a minimal explicit one. The decisions **D1–D6** stand
> as proposed pending the owner's read of this record. Implementation
> begins on that go.
>
> **The honest alternative, on the record.** A declarative,
> boilerplate-free UI framework does **not** strictly need generics.
> Keep the application's state concrete and in the application, give it a
> `view() -> View` (a value tree) and an in-place `step(event)` writing
> method, and have the library hide `begin`/`present`/`cursor`/`flush`
> behind a `Screen` — the result is declarative, allocates no per-event
> copy, and leaves only a three-line `while` in `main`. Generics is what
> moves that last loop into a `run(...)`, and because a writing method
> cannot be passed as a callback (BINDING.md D9), doing so forces the
> state to be *returned* each event and therefore *copied*. The owner
> chose the fully hidden loop knowing that price. Generics' independent
> value — typed widgets and data structures — stands regardless. It follows the survey style of
> [CONCURRENCY_RESEARCH.md](CONCURRENCY_RESEARCH.md) and
> [UNION_RESEARCH.md](UNION_RESEARCH.md): price every option against
> the value/reference model, ARC, and the differential oracle
> before choosing.

## 1. The need, stated precisely

Three things want the same missing capability:

1. **A runtime that hides the loop.** `run(initial, view, update)` must
   name the application's state type to hold it, call `view` on it, and
   store what `update` returns. Today that type is the app's, so the
   library cannot name it. An interface can *hold* the state — an
   interface value is a reference (`docs/MEMORY.md`) — but it erases the
   concrete type, so `run` could no longer name `Model` in `view`'s and
   `update`'s signatures or hand it back unchanged. Generics let the
   library name the type without knowing it in advance.
2. **Typed reusable widgets.** A selection list is `func(long) -> string`
   today because it cannot be `Vec(T)`. Every widget that reads app data
   is stringly typed for the same reason.
3. **Reusable data structures.** A `Stack`, a `Queue`, a `Tree` are
   copy-paste-per-element-type today, or routed through `list`.

Containers (`list(T)`, `map(K,V)`, `array(T, _)`) already answer (3) for
the three the language blesses. Generics is the same capability, opened
to the programmer.

## 2. What Luce already has (the foundation)

The type system **already interns parameterized types.** `HeapType` is
`list: Type | map: {key, value} | array: {element, rank}` (support/
types.zig), and `Type` reaches structs, unions, functions and enums by
interned index. A `list(Point)` and a `list(long)` are two interned heap
types over one code path. So a parameterized type is not a new idea to
the compiler — only a *user-written* one is.

Crucially, the container runtime is **type-erased at the ABI**:
`libluce_rt` moves tagged values and never sees `T`; the type table
knows the element type, the runtime knows only "a run of values with
this tag." That is one of the two implementation strategies below, and
it is the one already in the tree.

## 3. The implementation strategy — D1

Three ways to compile a generic, priced against Luce's commitments
(value copy, ARC, one LLVM backend, a concrete-MIR oracle):

| Strategy | What it is | Cost | Fit |
| --- | --- | --- | --- |
| **Monomorphization** | one specialized copy per type argument (Rust, C++, **Zig**) | code size; instantiate at each use | concrete MIR per instantiation — **the oracle, MIR, verifier, LLVM and `libluce_rt` never see a type parameter** |
| Dictionary passing | one copy + a vtable argument (Haskell, Swift) | a runtime indirection per generic call; a new ABI shape | reuses interface dispatch, but adds a second calling convention |
| Type erasure | one copy over a uniform boxed value (Java; Luce's own containers) | boxing every `T`; a uniform representation Luce scalars/structs do not have | already how containers work, but generalizing it boxes everything |

**Proposed D1: monomorphization.** It is the only strategy under which
*nothing below stage 5 changes*: a generic is expanded to concrete
functions and structs during checking/lowering, and the MIR, the
serialized module (`format_version` aside), the interpreter oracle, the
LLVM backend and the runtime library are exactly what they are today.
Both engines run identical concrete MIR, so the differential guarantee
is untouched. It is also the strategy Luce's own implementation language
uses, so the team already reasons in it. The price — code for each
instantiation — is the accepted price of the same choice in Rust and
Zig, and `07_optimize/prune` already drops the instantiations a program
does not reach.

## 4. Generics need no memory reasoning — D2

Under Luce's memory model (`docs/MEMORY.md`) a generic body needs no
memory reasoning of its own. A `T` that resolves to a value type copies;
a `T` that resolves to a reference type shares and is reference-counted;
ARC inserts every retain and release automatically. There are no
ownership verbs a generic body could get wrong, so the question that
would once have been Luce's alone — how a generic prices against an
ownership discipline — simply does not arise.

```
func keep(x: T) -> T:      # copies a value, shares a reference…
    return x               # …ARC decides from the concrete T, not the body
```

Monomorphization (D1) makes this exact: each instantiation substitutes a
concrete `T`, and the ordinary checker runs on concrete code where every
copy, share, retain and release is already settled by the type. No new
theory, no new category on a type parameter, and no per-use diagnostic
about memory — a generic is checked exactly as the hand-written concrete
code it expands to would be.

**Proposed D2: nothing to decide.** ARC over value/reference types makes
a generic body memory-agnostic, and monomorphization checks each
instantiation as ordinary concrete code.

## 5. Bounds — how a body uses its `T` — D3

An unbounded `T` can only be **copied, shared, stored and compared for
identity** — the operations that need no knowledge of the type. To call
a method on a `T`, the parameter must be **bounded by an interface**,
which is the mechanism the language already has:

```
func largest[T: Comparable](xs: list(T)) -> T?:   # T.less(other) is callable
    ...
```

`T: Comparable` means "any type that conforms to `Comparable`," checked
once at the *use* (the instantiation supplies a concrete type, and its
conformance is the existing `conformance` check). A bound is the generic
generalization of the interface-argument rule that works today.

**Proposed D3: bounds are interfaces, reusing INTERFACES.md wholesale.**
No new constraint language, no traits-with-associated-types in v1. A
multi-bound `T: A + B` is a natural later extension; v1 is one interface
per parameter.

## 6. Syntax — D4

Luce prefers the explicit over the magical. A type parameter is
declared in brackets after the name, with an optional bound:

```
func run[Model](start: Model, view: func(Model) -> ui.View, update: func(Model, ui.Event) -> Model):
    ...

struct Stack[T]:
    items: list(T)

    func push(value: T):
        self.items.append(value)

    func pop() -> T?:
        ...

func largest[T: Comparable](xs: list(T)) -> T?:
    ...
```

At a use, type arguments are **inferred from the value arguments** where
possible (`run(counter, view, update)` infers `Model = Counter`), and
written explicitly where inference cannot reach them
(`new Stack[long]()`). A bare `T` inside a generic is a *type name* in
scope exactly as `long` is; outside, it is nothing.

**Proposed D4: `[T]` / `[T: Bound]` declaration; inference from
arguments; explicit `[…]` at construction when a struct's parameter is
not fixed by an argument.** Brackets, not `<…>`, because `<` and `>` are
comparison operators and Luce has bitwise `<<`/`>>` (BITWISE.md) — angle
brackets would make the parser guess, and Luce does not guess.

## 7. Where it lives in the pipeline — D5

Monomorphization makes this a **front-end-only** change:

- **Parser**: `[T]`/`[T: Bound]` on `func`/`struct`; `T` as a written
  type; `[…]` type arguments at a call/construction.
- **Stage 4 (semantics)**: a generic declaration is a *template* — named,
  scoped, its signature recorded with `T` as a fresh type-parameter
  `Type` variant (`parameter: u32`, valid only inside its template).
  Each use collects/infers the type arguments, **instantiates** the
  template by substituting `T`, interns the instantiation by (template,
  arguments) so `Stack[long]` is one type program-wide, and checks the
  instantiation — types and bounds (D3), memory settled by the concrete
  types (D2) — as ordinary concrete code. `main`'s reachable set drives
  which instantiations are produced.
- **Stage 5+ (HIR, MIR, optimize, LLVM, runtime)**: **unchanged.** They
  only ever see the concrete instantiations. `format_version` bumps for
  the new AST/HIR nodes; the host **`abi.version` does not move**, and
  `libluce_rt` learns nothing — the same sentence enums and unions
  earned.
- **The oracle**: enters at the same concrete MIR, so both engines agree
  by construction.

**Proposed D5: generics is desugared entirely above the check/lower
seam; the `parameter` type exists only inside a template and never
reaches MIR.** The one `unreachable` this earns — a `parameter` type in
lowering — is a *never*, and it owes a stage-4 refusal like every other.

## 8. Scope for v1 — D6

**In:** generic `func`s and generic `struct`s; monomorphized; interface
bounds; argument inference. This is exactly
enough for `termui.app.run[Model]`, a typed `Vec[T]`/`Stack[T]` widget
family, and reusable data structures.

**Deferred, named:** generic `enum`/`union`s (the recursive-union `View`
tree does not need them — a concrete union suffices); multiple bounds
`T: A + B`; variance and subtyping of instantiations; higher-kinded
parameters; associated types; specialization/overloading on type
arguments. Each is additive over D1–D5.

## 9. The payoff, and the one thing generics does *not* fix

With D1–D6, the MVU runtime is writable and the loop disappears for any
app, carrying state included:

```
func main():
    app.run(Editor.open(args), Editor.view, Editor.step)
```

`run[Editor]` holds the concrete `Editor` — no interface, no wall.
**Note where the cost lives:** if `update`/`step` is a *function*
`func(Model, Event) -> Model` over a value-type `Model`, it returns a
*new* model, and copying a value type copies the whole state each event.
For a text editor that copy is dominated by the content string it already
rebuilds per keystroke, so it is likely acceptable; for very large state,
make `Model` a `class` — a reference is shared, so an `update` that
mutates it in place needs no copy at all. So the immutable-update cost is
a *choice* the memory model already answers (`docs/MEMORY.md`); it is
noted here so the editor port measures it rather than assumes it away.

## 10. Decisions to ratify

- **D1** — Monomorphization.
- **D2** — Generics need no memory reasoning: under value/reference +
  ARC, each instantiation's copies, shares, retains and releases are
  settled by its concrete types (§4).
- **D3** — Bounds are interfaces (INTERFACES.md), one per parameter in
  v1.
- **D4** — `[T]`/`[T: Bound]` syntax; argument inference; explicit `[…]`
  at construction; brackets not angle brackets.
- **D5** — Front-end-only desugaring; `parameter` type never crosses the
  check/lower seam; `format_version` bumps, `abi.version` does not.
- **D6** — v1 = generic functions + structs; enums/unions, multi-bounds,
  variance, HKT, associated types, specialization deferred.

Nothing here is built. On ratification, the work is: parser, the
`parameter` `Type` and the template/instantiation tables in stage 4, the
instantiation-driven checking, the `format_version` bump and its spec,
and — the proof — an executable specification that runs a generic on
**both engines** and compares them, exactly as every other language
feature earned its place.
