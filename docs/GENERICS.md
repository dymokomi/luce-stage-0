# Generics — a proposed direction

> **Status: proposed, not built.** This document describes the intended
> design for parametric generics in Luce. Nothing here exists in the
> tree yet; when it is built, this file becomes its reference.

Generics would let a function or type be written once over a type it does
not name in advance — `Stack[T]`, `Vec[T]`, a `run(...)` loop that holds
an application's own state type. Luce's containers (`list(T)`,
`map(K, V)`, `array(T, _)`) already answer this for the three shapes the
language blesses; generics is the same capability opened to the
programmer.

## What wants it

Three things need the same missing capability:

1. **A runtime that hides the loop.** A UI runtime
   `run(initial, view, update)` must name the application's state type to
   hold it, call `view` on it, and store what `update` returns. Today
   that type is the application's own, so a library cannot name it. An
   `interface` can *hold* the state — an interface value is a reference
   (`docs/MEMORY.md`) — but it erases the concrete type, so `run` could
   no longer name the model in `view`'s and `update`'s signatures or hand
   it back unchanged. Generics let the library name the type without
   knowing it in advance.
2. **Typed reusable widgets.** A selection list is a `func(long) ->
   string` today because it cannot be a `Vec(T)`; every widget that reads
   application data is stringly typed for the same reason.
3. **Reusable data structures.** A stack, a queue, a tree are
   copy-paste-per-element-type today, or routed through `list`.

A declarative UI framework does not strictly *need* generics — an
application can keep its state concrete, expose a `view() -> View` and an
in-place mutating `step(event)`, and let a library hide the frame loop
behind a screen type, leaving only a short `while` in `main`. Generics is
what moves that last loop into a `run(...)`. Its independent value —
typed widgets and reusable data structures — stands on its own.

## The foundation Luce already has

The type system **already interns parameterized types.** A heap type is
one of `list: Type`, `map: {key, value}`, or `array: {element, rank}`,
and a `list(Point)` and a `list(long)` are two interned heap types over
one code path. A parameterized type is therefore not a new idea to the
compiler — only a *user-written* one is.

The container runtime is also **type-erased at the ABI**: `libluce_rt`
moves tagged values and never sees the element type. The type table knows
the element type; the runtime knows only "a run of values with this tag."

## Monomorphization

The proposed strategy is **monomorphization**: expand a generic to one
specialized copy per type argument during checking and lowering, the way
Rust, C++, and Zig do. Under it, *nothing below the check/lower seam
changes* — a generic becomes concrete functions and structs before it
reaches MIR, so the MIR, the serialized module, the interpreter oracle,
the LLVM backend, and the runtime library are exactly what they are
today. Both engines run identical concrete MIR, so the differential
guarantee is untouched. The price is code size per instantiation, the
accepted price of the same choice elsewhere, and `07_optimize/prune`
already drops the instantiations a program does not reach.

The two alternatives are weaker fits. **Dictionary passing** (a vtable
argument per generic call) reuses interface dispatch but adds a second
calling convention and a runtime indirection. **Type erasure** over a
uniform boxed value is how containers already work, but generalizing it
would box every scalar and struct, a representation Luce's value types do
not have.

## Memory needs no reasoning of its own

Under the value/reference model with ARC (`docs/MEMORY.md`), a generic
body needs no memory reasoning. A `T` that resolves to a value type
copies; a `T` that resolves to a reference type is shared and
reference-counted; ARC inserts every retain and release from the concrete
type, not from the generic body:

```text
func keep(x: T) -> T:      # copies a value, shares a reference…
    return x               # …decided by the concrete T, not the body
```

Monomorphization makes this exact: each instantiation substitutes a
concrete `T`, and the ordinary checker runs on concrete code where every
copy, share, retain, and release is already settled by the type. There is
no new category on a type parameter and no per-use diagnostic about
memory — a generic is checked exactly as the hand-written concrete code
it expands to would be.

## Bounds are interfaces

An unbounded `T` can only be **copied, shared, stored, and compared for
identity** — the operations that need no knowledge of the type. To call a
method on a `T`, the parameter must be **bounded by an interface**, the
mechanism the language already has:

```text
func largest[T: Comparable](xs: list(T)) -> T?:   # T.less(other) is callable
    ...
```

`T: Comparable` means "any type that conforms to `Comparable`," checked
at the *use*, where the instantiation supplies a concrete type and its
conformance is the existing interface-conformance check. A bound is the
generic generalization of the interface-argument rule that works today.
The proposal reuses `docs/INTERFACES.md` wholesale: no new constraint
language, one interface per parameter to start. A multi-bound `T: A + B`
is a natural later extension.

## Syntax

A type parameter is declared in brackets after the name, with an optional
bound:

```text
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
possible (`run(counter, view, update)` infers `Model = Counter`) and
written explicitly where inference cannot reach them (`new Stack[long]()`).
A bare `T` inside a generic is a *type name* in scope exactly as `long`
is; outside, it is nothing. Brackets are used rather than angle brackets
because `<` and `>` are comparison operators and Luce has bitwise `<<`
and `>>` — angle brackets would make the parser guess, and Luce does not
guess.

## Where it lives in the pipeline

Monomorphization makes generics a **front-end-only** change:

- **Parser**: `[T]` / `[T: Bound]` on `func` and `struct`; `T` as a
  written type; `[…]` type arguments at a call or construction.
- **Semantics**: a generic declaration is a *template* — named, scoped,
  its signature recorded with `T` as a fresh type-parameter type variant
  valid only inside its template. Each use collects or infers the type
  arguments, **instantiates** the template by substituting `T`, interns
  the instantiation by (template, arguments) so `Stack[long]` is one type
  program-wide, and checks the instantiation as ordinary concrete code.
  `main`'s reachable set drives which instantiations are produced.
- **HIR, MIR, optimize, LLVM, runtime**: **unchanged.** They only ever
  see the concrete instantiations. The serialized module's
  `format_version` bumps for the new AST/HIR nodes; the host
  `abi.version` does not move, and `libluce_rt` learns nothing — the same
  sentence enums and unions earned. The type-parameter variant exists
  only inside a template and never reaches MIR; a `parameter` type in
  lowering would be a *never*, owed a stage-4 refusal like every other.
- **The oracle** enters at the same concrete MIR, so both engines agree
  by construction.

## Scope for a first version

**In:** generic `func`s and generic `struct`s, monomorphized, with
interface bounds and argument inference — enough for a `run[Model]` UI
loop, a typed `Vec[T]`/`Stack[T]` widget family, and reusable data
structures.

**Deferred:** generic `enum`/`union`s (a concrete union suffices for a
recursive `View` tree); multiple bounds `T: A + B`; variance and
subtyping of instantiations; higher-kinded parameters; associated types;
and specialization or overloading on type arguments. Each is additive
over the core.

## The payoff, and the one thing generics does not fix

With generics, a UI runtime is writable and the loop disappears for any
application, carrying state included:

```text
func main():
    app.run(Editor.open(args), Editor.view, Editor.step)
```

`run[Editor]` holds the concrete `Editor` — no interface, no erasure.
Where the cost lives is worth stating: if `update`/`step` is a *function*
`func(Model, Event) -> Model` over a value-type `Model`, it returns a new
model, and copying a value type copies the whole state each event. For a
text editor that copy is dominated by the content it already rebuilds per
keystroke, so it is likely acceptable; for very large state, make `Model`
a `class` — a reference is shared, so an `update` that mutates it in place
needs no copy at all. The immutable-update cost is a *choice* the memory
model already answers (`docs/MEMORY.md`); it is noted here so a port
measures it rather than assumes it away.

When this is built, its proof is an executable specification that runs a
generic on **both engines** and compares them, exactly as every other
language feature earns its place.
