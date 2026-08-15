# GENERICS.md — a proposal, direction ratified

> **Status.** Direction ratified, not built (2026-08-14). This is the
> design record for parametric generics in Luce. The owner has decided
> to pursue generics — for typed reusable abstractions (`List[T]`,
> `Stack[T]`) and to make a UI runtime that fully hides the loop —
> having weighed the honest alternative below and chosen the fully
> hidden loop over a minimal explicit one. Of the decisions **D1–D6**,
> **D2 is ratified as D2a**; D1 and D3–D6 stand as proposed pending the
> owner's read of this record. Implementation begins on that go.
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
> scope ownership, the no-collector rule, and the differential oracle
> before choosing.

## 1. The need, stated precisely

Three things want the same missing capability:

1. **A runtime that hides the loop.** `run(initial, view, update)` must
   name the application's state type to hold it, call `view` on it, and
   store what `update` returns. Today that type is the app's, so the
   library cannot name it. The interface escape hatch fails the moment
   the state carries a container: `let m: Model = Editor(...)` is refused
   — *"a carrying receiver cannot be returned as an interface because the
   interface borrows its owner"* — because an interface value is a borrow
   and a fresh carrying value dies at the statement's end.
2. **Typed reusable widgets.** A selection list is `func(long) -> string`
   today because it cannot be `List(T)`. Every widget that reads app data
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
(value copy, no collector, one LLVM backend, a concrete-MIR oracle):

| Strategy | What it is | Cost | Fit |
| --- | --- | --- | --- |
| **Monomorphization** | one specialized copy per type argument (Rust, C++, **Zig**) | code size; instantiate at each use | concrete MIR per instantiation — **the oracle, MIR, verifier, LLVM and `libluce_rt` never see a type parameter** |
| Dictionary passing | one copy + a vtable argument (Haskell, Swift) | a runtime indirection per generic call; a new ABI shape | reuses interface dispatch, but adds a second calling convention and hides ownership behind the dictionary |
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

## 4. The crux — generics × scope ownership — D2

This is the decision that is Luce's alone, because no other language
prices a generic against *scope ownership*. Whether `T` copies, moves,
or needs `give`/`copy` depends on whether `T` carries objects or a
resource — a fact a generic body written once cannot know.

```
func keep(x: give T) -> T:      # does `give` move a graph or copy a value?
    return x                    # depends entirely on what T turns out to be
```

Two honest options:

- **D2a — per-instantiation ownership checking (template-style).** The
  generic body is parsed, its names resolved, and its shape recorded,
  but the ownership walk (OWNERSHIP.md's S-rules) runs on each *concrete
  instantiation*, where `T` is a real type and the existing checker is
  exact. Full precision, no new ownership theory. The cost is C++-
  template diagnostics: an ownership error in a generic surfaces at the
  *use* that instantiated it, so the compiler must carry an
  instantiation trace ("`keep(a_file)` instantiated `keep[file]` here,
  which moves a resource…") to keep the message pointed at a fix.

- **D2b — ownership-categorized parameters.** A type parameter declares
  its category up front: `T: value` (copies, takes no verbs — the
  MVU-view case), or `T: any` (may carry, so the body must `give`/`copy`
  conservatively and is checked once against the pessimistic assumption).
  Better diagnostics (the body is checked in isolation), at the cost of a
  new axis on every type parameter and a body that must be written
  ownership-generic even when every instantiation is a value.

**Proposed D2: D2a (per-instantiation), with the instantiation trace as
a first-class diagnostic.** Monomorphization already produces a concrete
program per instantiation; running the ownership checker there reuses
every S-rule exactly and invents no new ownership category. The
diagnostic cost is real but bounded, and the trace is the same idea the
compiled path's call trace already carries. D2b stays available as a
later *optimization* of diagnostics if template-style errors prove hard
to read — it is additive, not a fork.

## 5. Bounds — how a body uses its `T` — D3

An unbounded `T` can only be **moved, copied, stored and compared for
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

    func push(value: give T):
        self.items.append(give value)

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
  instantiation — types, ownership (D2), bounds (D3) — as ordinary
  concrete code. `main`'s reachable set drives which instantiations are
  produced.
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
bounds; argument inference; per-instantiation ownership. This is exactly
enough for `termui.app.run[Model]`, a typed `List[T]`/`Stack[T]` widget
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

`run[Editor]` holds the concrete `Editor` — no interface, no borrow, no
wall. **But note the honest limit:** if `update`/`step` is a *function*
`func(Model, Event) -> Model`, it returns a *new* model, and a value-copy
language copies the whole state each event. For a text editor that copy
is dominated by the content string it already rebuilds per keystroke, so
it is likely acceptable; for very large state it is a real cost.
Mutating the model in place would need a **writing method reachable
through the generic** — and writing methods do not bind as values
(BINDING.md D9) and interface dispatch is read-only. So the immutable-
update cost is a *separate* question generics does not answer; it is
noted here so the editor port measures it rather than assumes it away.

## 10. Decisions to ratify

- **D1** — Monomorphization.
- **D2** — *Ratified.* Per-instantiation ownership checking, with an
  instantiation trace in diagnostics; D2b categorized parameters are a
  later, additive diagnostics upgrade, not a fork.
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
