# ROADMAP — the reference feature set and how it is built

The memory model is **value types and reference types with automatic
reference counting** (`docs/MEMORY.md`). This document is the plan for
finishing it: the feature set we are building, how each feature works,
and the order the work goes in. It is a plan, not a reference — the
built features are described in their own docs; the ones below marked
"not built" are the design we are aiming at.

## Where we are

The **ARC engine is built and green.** The built-in reference types —
`list`, `map`, `array`, `builder`, `file`, `task` — are reference-counted
with compiler-inserted retain/release, freed at the last release, closing
resources deterministically, on both engines, with zero leaks across the
whole spec suite. The legacy ownership subsystem is gone, and the
documentation describes ARC.

What is **not** built yet is the language surface a user reaches for a
`class`. A `class` parses and type-checks as a reference kind but still
*lowers* as a value: assigning one copies rather than shares. `weak`,
capturing closures, and mutating interface dispatch are still refused.
Wiring those up is the whole of the remaining work, and it is the reason
the rewrite started: **a callback that captures and mutates shared state
is only expressible once references are shared and closures can capture
them.**

## Guiding cuts

- **Smaller is the goal.** Every feature below is chosen to be the
  smallest version that is still whole. Where Swift has three forms of a
  thing, we take the one that cannot be expressed by the others.
- **The two-engine guarantee is non-negotiable.** ARC is enforced
  identically in `libluce_rt` and the interpreter oracle, and every spec
  compares them. A feature is not done until both engines agree.
- **Reversible by construction.** The deferred features (inheritance,
  `unowned`, generics) are all *additive* — the v1 choices leave the door
  open for them without committing now.

---

# The feature set

## The model, recapped

A **value type** — the scalars, `string`, a plain `struct`, an `enum`, a
`union`, a function value — copies when assigned or passed, and costs
nothing at runtime. A **reference type** — a `class`, the containers
`list`/`map`/`array`/`builder`, the resources `file`/`task` — is a shared,
reference-counted object: assigning or passing it shares the same object,
and it is freed at the last reference. You choose with one keyword,
`struct` or `class`. That is the whole model; everything below is how the
reference side behaves (`docs/MEMORY.md`).

## Classes

A `class` is a reference type with identity.

```text
class Counter:
    count: long

func main():
    let a = Counter(count = 0)
    let b = a          # b and a name the same object
    b.count = 5
    print(string(a.count))   # 5 — the mutation is seen through a
```

- **Reference semantics.** `let b = a` makes `b` refer to the same
  object; a mutation through one name is seen through every other.
  Assigning or passing a class never copies it.
- **Identity.** `a === b` asks whether two references name the *same*
  object, distinct from `a == b` (equal contents). `===` is the reference
  question and exists the moment references do.
- **Mutation is ordinary.** A method mutates its receiver with no marker,
  and it may be called through a `let` — a `let` binds the reference, and
  mutating the object it names does not reassign the binding. (This is the
  opposite of a value `struct`, below.)
- **Stored and computed properties.** A stored property holds a value in
  the object (`var`/`let`). A computed property has no storage and gives a
  value from a body — the `@property` a "compiled Python" needs.
- **Construction — `init`, optional.** A class (or struct) with no
  constructor gets the memberwise form `Counter(count = 0)`. It may
  instead declare one or more `init` constructors that take their own
  arguments and run setup; an `init` must assign every stored property
  before the object is used, and it is called by the same
  `TypeName(args)` syntax with its own parameter names. Writing an `init`
  is optional — the memberwise form is what you get for free.

  ```text
  class Temperature:
      celsius: double

      init(fahrenheit: double):
          self.celsius = (fahrenheit - 32.0) / 1.8

  func main():
      let t = Temperature(fahrenheit = 98.6)
      print(string(t.celsius))
  ```
- **`deinit`, optional.** A class may declare a `deinit` that runs at the
  last release — deterministic, driven by the count. It is where a class
  cleans up what ARC's automatic free does not cover; a `file` field, for
  instance, closes on its own, but a `deinit` is the user-level "on
  teardown" hook. A class without one needs nothing — ARC frees the
  object and its reference fields on its own.

  ```text
  class Session:
      log: file

      deinit():
          print("session closed")
  ```
- **`static`.** `static func` and `static const` are type-level members
  with no receiver — the factories and namespace helpers.
- **Visibility — the same as a struct.** Everything is public by default;
  `private` written in full marks a field or method; `private:` and
  `public:` regions open indented blocks inside the class body. The unit
  of privacy is the file, and a class with a private field is constructed
  through its own public functions (the factory pattern). This is already
  in place (`docs/VISIBILITY.md`), the same rules structs use.
- **Final.** A class is final: it has no subclasses. Polymorphism comes
  from interfaces, not from a hierarchy (see below).

## No inheritance (a decision)

**Luce has no class inheritance.** A class cannot subclass another class;
there is no `override`, no `super`, no designated-vs-convenience
initializer chain, no vtable.

The reasoning, grounded in Swift's own experience:

- Inheritance is the highest-complexity, lowest-necessity feature in a
  class model. Its two irreplaceable powers are **shared stored state**
  across a hierarchy and **`super`-style override**. Everything else it
  offers, interfaces offer more cheaply.
- Swift — which has inheritance — promotes *protocol-oriented*
  programming over it: reuse through protocol default implementations and
  composition, not base classes. A great deal of modern Swift defines zero
  non-`final` classes.
- The machinery inheritance drags in (two-phase initialization, the
  designated/convenience/required initializer rules, initializer
  inheritance, dynamic dispatch) is Swift's single most complex feature.
  It contradicts "smaller than before."
- The programs that motivated this rewrite — a SwiftUI-shaped UI, an
  editor, an AST — are interface-, composition-, and union-shaped, not
  hierarchy-shaped. An AST is a `union`; a widget is an `interface`; a
  view holds its children, it does not inherit them.

What replaces it: **interface default methods** recover shared
implementation, **composition** (a class holds another as a field and
forwards) recovers shared state, and **unions** recover closed variant
hierarchies. If a genuine need for shared mutable base state appears
later, single inheritance is a strictly additive feature — classes being
final by default means adding an `open` opt-in then costs nothing now.

## Interfaces

An interface is a named call contract; a `struct` or a `class` conforms to
it by listing it and implementing its methods (`docs/INTERFACES.md`). With
inheritance omitted, interfaces are the whole of polymorphism, so they
grow two things they lack today:

- **Default methods.** An interface may give a method a body; a conformer
  that does not implement the method inherits the default. This is the
  reuse mechanism that makes "no base classes" livable — the one thing
  inheritance really bought, without the hierarchy. Defaults are
  overridable and dispatched by the concrete type.
- **A class-only marker.** An interface may be restricted to classes, so
  a reference to it can be held `weak` (a value type has nothing to weaken).

Already true and staying: nominal explicit conformance, method and
multi-value-return requirements, directional failure matching (a
non-fallible method satisfies a fallible requirement), and heterogeneous
`list(Interface)`. Under ARC an interface value is a reference, so a method
reached through it **may mutate its receiver** — the read-only-dispatch
rule that existed only to make a borrowed value safe is removed.

Deferred (see below): interface inheritance/composition, property
requirements beyond methods, associated types, and the generic-vs-boxed
(`some`/`any`) distinction — that frontier waits for generics.

## Methods and mutation

The mutation rule is the observable core of value-vs-reference, and it is
already how structs behave:

- A **value type** (`struct`) method that writes `self` or a `self` field
  is a **writer**, and a writer may be called only on a bare `var`
  binding — never a `let`, because a `let` value is immutable. Luce infers
  which methods are writers from their bodies (no `mutating` keyword); the
  call site tells the truth either way, since `x.advance()` may write and
  `f(x)` never does (`docs/SELF.md`).
- A **reference type** (`class`) method needs no marker and may be called
  through a `let`: it mutates the shared object, not the binding.

So the only work here is the class half — today a class is checked as a
value, which wrongly refuses `let b = a; b.count = 5`. Phase 5 makes a
class method an ordinary reference mutation.

## Capturing closures

**This is the feature the rewrite exists for.** A lambda may capture the
variables of the scope around it; a captured reference is kept alive by
ARC for as long as the closure lives.

```text
class Model:
    total: long

func make_adder(m: Model) -> func():
    return () -> m.total += 1     # captures m; ARC keeps it alive
```

- **Capture by reference.** A closure captures the variable, not a
  snapshot: it reads and writes the live variable, and mutations are seen
  outside. A captured reference object is retained.
- **One function type.** `func(T) -> R` covers a plain function and a
  capturing closure alike; there is no `@escaping`-style colouring on the
  type.
- **Capture lists break cycles.** A closure a class stores, that captures
  that same class, is a cycle ARC cannot reclaim. A capture list states a
  weaker capture at the point the cycle would form: `[weak m]` captures
  `m` as a `Model?` (weak, may be gone), and `[name = expr]` captures a
  chosen value at creation time.
- **Escape is inferred, not annotated.** The compiler knows whether a
  closure escapes — is stored, returned, or spawned — or is only called in
  place. A closure that cannot escape cannot form a lasting cycle, so it
  needs no capture ceremony at all; the weak/value decision is asked for
  *only* where a closure escapes and captures a reference. This is the
  idea that keeps "memory you never think about" true for closures: the
  ceremony appears exactly where, and only where, a leak is possible.

Not in v1: `@autoclosure`, and `unowned` captures (a capture list offers
`weak` and value capture only — see `weak`, below).

## `weak` references

ARC's one genuine cost is that a reference **cycle** leaks. A `weak`
reference is the answer, and the only new concept the model asks a
programmer to learn.

```text
class Node:
    weak parent: Node?
    children: list(Node)
```

- A `weak` reference does **not** retain its object; it reads as `T?`, and
  becomes `none` the instant the object is freed. A read is therefore
  always safe — there is no dangling reference, only a `none`.
- It applies to reference types only (a `class`, or a class-only
  interface); a value type has no identity to weaken.
- Cycles are rare — a parent↔child back-edge, a delegate — so `weak` is a
  footnote, not a daily tax.

**`weak` only; no `unowned`.** Swift also has `unowned` (a non-optional
non-owning reference that traps or is undefined behaviour if read after
the object is gone). It is purely an ergonomic/perf affordance — it avoids
the optional — bought with a use-after-free hole. For a language whose
thesis is "memory you never think about," a reference that segfaults on a
lifetime mistake is the wrong trade. `weak` expresses every cycle-break
`unowned` can, with an unwrap. If profiling ever shows the weak side-table
matters, `unowned` can be added later as a *safe, trapping* form only
(never the unsafe one) — consistent with Luce's existing trap machinery.

## The small ergonomics that references demand

References and optionals make a few small features stop being optional:

- **`===` identity** — "the same object?", added with classes.
- **Synthesized `==` and hashing** — user `struct`s already compare with a
  synthesized `==`; a type used as a `map` key needs a synthesized hash
  the same way, so user types drop into `map` and `==` with no ceremony.
- **Optional chaining `a?.b?.c`** — short-circuiting member access on an
  optional, the whole expression becoming `T?`. `weak` produces optionals
  everywhere in a reference graph; without chaining, walking one is
  verbose. High value, and it composes with the `else` fallback Luce
  already has (`a?.b else default`).
- **Optional binding** — Luce narrows an optional with `if x != none:`
  today; a binding form (`if let y = x:` / an early-exit `guard`) makes
  the `[weak self]` idiom — capture weak, then check once — read cleanly.

## Deferred, on purpose

Not in the reference feature set, each recoverable later without breaking
what ships:

- **Class inheritance** — composition + interface defaults + unions cover
  it; single inheritance is additive if a real need appears.
- **`unowned`** — `weak` is the safe primitive; add a trapping `unowned`
  only if measured.
- **Generics** (`<T: P>`, and the boxed-`any` vs monomorphized-`some`
  distinction), **associated types**, **`where` clauses** — the type-system
  frontier. Interfaces and heterogeneous collections carry v1; generics
  are their own track (`docs/GENERICS.md`).
- **`lazy` properties, property observers (`willSet`/`didSet`),
  convenience/required/failable initializers** — each a clean later
  addition; none blocks the UI story.
- **`@autoclosure`, `Self` return types, `as!` forced casts** — advanced;
  omitted.

---

# Build order

## Phases 0–4 and 7 — done

- **0. Docs & direction** — `docs/MEMORY.md`, this roadmap, `CLAUDE.md`.
- **1. Type kinds in the front end** — `class` parses beside `struct`; a
  per-layout value/reference kind on `Type`.
- **2. ARC in `libluce_rt` and the oracle** — a refcount on every
  reference object; `luce_rt_retain`/`_release`; deterministic free and
  resource close; both engines mirror it. `abi.version` is 19.
- **3. Share/copy semantics; legacy subsystem removed** — the ownership
  walk and its diagnostics are gone; a value copies, a built-in reference
  shares, `new`/literals allocate with count 1.
- **4. MIR & backend: retain/release** — the ownership instructions are
  now `retain`/`release`; the verifier checks the discipline; codegen
  emits and elides them; `format_version` is 47.
- **7. Docs sweep** — every doc rewritten to the ARC model.

## Phase 5 — the reference feature set  ← next

Each step is additive and can land green on its own.

- **5a — a `class` lowers as a reference.** The central change: a `strukt`
  layout whose kind is `reference` allocates a heap object and lowers
  through the container path — assigning shares and retains, scope end
  releases, a method mutates the shared object (legal through a `let`).
  Add `===`, optional `init` constructors, and an optional `deinit`
  release-time hook. After 5a, the `Counter` example above prints `5`.
- **5b — interfaces carry implementation.** Default methods; the
  class-only marker; conformance for classes as well as structs; remove
  the read-only-dispatch rule so an interface method may mutate.
- **5c — capturing closures.** Capture enclosing variables by reference;
  capture lists (`[weak x]`, `[name = expr]`); escape inference so the
  weak/value decision is asked only where a closure escapes.
- **5d — `weak`.** The non-retaining `T?` reference that auto-nils at
  free; parsing, checking, and the runtime side-table on both engines.
- **5e — the small ergonomics.** Optional chaining `a?.b`, an optional
  binding form, and synthesized hashing for user map keys.

## Phase 6 — rewrite the users of the model

- **`std/*`** — containers are shared; drop any remaining defensive copies.
- **`examples/editor`** — the state coordinator shrinks: shared mutable
  buffers, no remember/restore dance.
- **`packages/termui`** — the retained-tree, SwiftUI-shaped framework,
  now expressible: a `class` view tree, mutated in place, with `on_press`
  closures that capture and mutate app state directly. This is the proof
  the model is right.
- **`bench/*`** — value types keep their speed; re-baseline the
  graph-heavy rows that sharing should improve.

## What "done" looks like

`app.run(App())` hides the loop; a `class` widget tree is retained and
mutated in place; a button's `on_press` closure captures and mutates app
state directly; `weak` closes the one back-edge that would leak; `struct`
numerics keep their benchmark speed; both engines agree on every spec; and
the language surface is *smaller* than it was before ARC.

---

# Concurrency, kept

`spawn` is unchanged: **value types cross a worker by copy, reference
types do not cross at all** — so there is no shared mutable state
*between* workers even though there is sharing *within* one
(`docs/MEMORY.md`, `docs/THREADS.md`). Locks, atomics, and actors stay out
until a workload asks.

# Runtime ARC design (grounded in the tree, for Phase 5a)

What the code looks like, so the surgery is precise:

- `runtime/heap.zig` `Object` carries `references: u32` (set to 1 by every
  `new*`), `generation` (stale-handle detection), and `next_free` (the
  free list). `luce_rt_retain` increments; `luce_rt_release` decrements
  and, at zero, runs the existing `freeObject` path. This is built.
- **Value vs reference at the boundary:** a value `struct` and the scalars
  stay inline in `Value`; a reference — `class`, container, resource — is a
  `Value` holding a `Handle`, and it is the thing retain/release act on.
  The per-layout `reference` flag is the compile-time switch that decides
  which lowering a `strukt` type gets. **5a is wiring that flag through the
  `strukt` lowering** so a `class` follows the reference path the
  containers already do, rather than the value-copy path it follows today.
- **MIR/codegen** already emit `retain`/`release` for the built-in
  references and elide redundant pairs; a `class` joins that path once 5a
  flips its lowering. The interpreter counts identically.
- Resources still close deterministically — a `file`/`task` releases at
  count zero, the same instant scope end gave, so `docs/FILESYSTEM.md` and
  `docs/THREADS.md` keep their guarantee.

The counting is one screenful in `libluce_rt` and is done; the remaining
work is the front-end lowering (5a), the surface features (5b–5e), and the
rewrite of the model's users (6).
