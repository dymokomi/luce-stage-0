# The memory model decision

> **Status.** Ratified 2026-08-15. This is the source of truth for how
> Luce manages memory. It supersedes scope ownership (`give`/`copy`, the
> S-rules in `docs/OWNERSHIP.md`), which was built, shipped, proven on a
> real flagship program — and then found to fight the language's own
> goals. The record of *why scope ownership was tried and what it cost*
> is kept at the end of this file, because that evidence is exactly what
> justifies the change. Docs that still describe the old model carry a
> superseded banner until they are rewritten feature by feature
> (`docs/ROADMAP.md`).

## What Luce is

**A compiled, statically typed Python.** Familiar indentation-based
syntax, native AOT speed through the LLVM backend, and **memory you
never think about.** The moat is that combination — the joy of Python,
the speed of a compiled language, and a surface small enough to hold in
your head — not a novel memory model. Everything below serves that.

## The model, in one paragraph

Every type is one of two kinds. A **value type** — the scalars, `string`,
and a plain `struct` — copies when assigned or passed, lives inline, and
costs nothing at runtime. A **reference type** — a `class`, and the
containers `list`/`map`/`array`/`builder` — is a shared, reference-counted
object: assigning or passing it shares the same object, and it is freed
automatically when the last reference goes away. You choose value or
reference with one keyword (`struct` vs `class`), exactly as Swift and C#
do, and you get value performance where you want it and reference
ergonomics where you need it. There is no `give`, no `copy`, no borrow,
no ownership verb of any kind.

## The decisions

- **D1 — Two type kinds: value and reference.** `struct` is a value type
  (copy semantics, inline, no runtime cost). `class` is a reference type
  (shared identity, heap, automatically freed). The built-in containers
  (`list`, `map`, `array`, `builder`) and resources (`file`, `task`) are
  reference types. This is the Swift/C# split, and it is the whole
  answer to "easiest *and* fast": values stay fast, references stay easy.

- **D2 — Automatic Reference Counting.** Reference objects carry a count;
  the compiler inserts retain/release; the object is freed at the last
  release. **Deterministic**, so a `file`/`task` still closes the instant
  its last reference dies — no finalizer roulette, no GC pause. ARC over
  a tracing GC specifically because Luce has resources whose cleanup must
  be prompt, and because deterministic destruction is simpler to reason
  about than collection timing.

- **D3 — `weak` for cycles.** ARC's one genuine cost: a reference cycle
  leaks. A `weak` reference does not retain, and reads as `T?` (it may
  have gone). This is the *only* new concept the model asks a programmer
  to learn — against the dozens the ownership model imposed. Cycles are
  rare enough (parent↔child back-edges) that `weak` is a footnote, not a
  daily tax.

- **D4 — Everything the ownership subsystem added is deleted.** Gone:
  `give`, `copy`, `free`, the S1–S46 situations, `use_after_free` /
  `not_owned` / `double_free`, the borrow-vs-own distinction, the
  carrying/fresh/resource categories, the interface-borrows-its-receiver
  rule, the writer-method-can't-bind rule, capture-free lambdas, the
  no-shadowing-of-ownership constraints, and every diagnostic that
  policed them. This is the largest single subtraction available to the
  language, and subtraction is the moat.

- **D5 — What the deletion *unlocks*.** Because a reference is shared and
  a `class` can be mutated through any reference to it, the things two
  weeks of walls could not express become ordinary: **capturing
  closures** (a closure holds references, which ARC keeps alive),
  **retained mutable trees** (a window owns a tree of `class` nodes),
  **shared mutable state** (a `class` model referenced by many views),
  **delegates and callbacks**, and the **SwiftUI-shaped UI** that started
  this reckoning. The UI framework becomes easy *and* beautiful, which is
  the proof the model is right.

- **D6 — Mutation is ordinary; interfaces dispatch to writing methods.**
  A method may mutate its receiver with no ceremony. An `interface`
  method may mutate its receiver — the read-only-dispatch rule existed
  only to make a *borrowed* value safe to dispatch, and there are no
  borrows now. A reference passed to a function is the same object the
  caller holds; mutating it is visible to the caller, as everyone
  expects.

- **D7 — Concurrency keeps its safety cheaply.** Losing "ownership *is*
  the concurrency model" costs less than it seems. `spawn` still runs a
  function on a worker with its own runtime; **value types cross a worker
  boundary by copy, and reference types do not cross at all** — a `class`
  or container stays in the runtime that made it. So there is no shared
  mutable state *between* workers by construction, even though there is
  now shared mutable state *within* one. Same guarantee where it mattered
  (no data races across threads), no cost to single-threaded UI code.
  Locks, atomics, and thread identity remain deliberately absent; if
  intra-worker sharing across threads is ever wanted, it is an actor-style
  addition, priced separately.

- **D8 — `new` and literals make reference objects; assignment shares.**
  `let a = SomeClass(...)` makes one object; `let b = a` makes `b` refer
  to the *same* object; mutating through `b` is seen through `a`. A value
  `struct` still copies on `let b = a`. This is the one mental model
  every mainstream language shares, and it is what "familiar" means.

## What is preserved

The pivot replaces the *memory subsystem*, not the language. These
survive essentially unchanged and are why this is a rewrite, not a
restart:

- The **type system** — the numeric ladder (`docs/TYPES.md`,
  `docs/NUMERICS.md`), `enum` (`docs/ENUMS.md`), `union`
  (`docs/UNION.md`), `interface` (`docs/INTERFACES.md`), the storable
  function values, and generics-to-come (`docs/GENERICS.md`, now *much*
  simpler without ownership to price against).
- The **pipeline** — lexer, parser, semantics, HIR, MIR, the LLVM
  backend, the serialized module (`docs/PIPELINE.md`, `docs/CODEGEN.md`).
- The **two-engine differential guarantee** — the interpreter oracle and
  the compiled path still run every spec and are compared
  (`docs/ENGINE.md`). ARC is enforced identically on both.
- **Failure handling** (`T!`/`try`/`catch`), **modes**, **visibility**,
  **bitwise**, **packages**, the **host boundary**, and the **std
  library** shape.

## What changes for the programmer, concretely

| Before (scope ownership) | After (value/reference + ARC) |
| --- | --- |
| `let b = give a` to move a container | `let b = a` shares it; both name one object |
| `copy x` to duplicate a graph | assign a value `struct`; a `class` is shared, copy explicitly if wanted |
| `free(x)` / leak reports | nothing — freed at last reference |
| a lambda cannot capture | a lambda captures by reference, ARC keeps captures alive |
| an interface value borrows, cannot own or mutate | an interface value is a reference; it owns a share and may mutate |
| a widget tree cannot be retained behind an interface | a `class` tree is retained naturally |
| `S22`, writer-binding, carrying/fresh rules | none of it exists |

## Why this is the right call, not a retreat

Scope ownership put Luce on the one bad square: **Rust's pain without
Rust's safety, and less ease than Swift or Go.** It taxed the programmer
with ownership ceremony and still could not express the graph-shaped,
shared, retained things — UIs, editors, ASTs — that are Luce's whole
point, while giving a coarser guarantee than a real borrow checker. The
walls were not papercuts; they were one decision speaking repeatedly.

Value + reference + ARC is the proven way (Swift, C#) to have value
performance *and* reference ergonomics, it makes the language **smaller**
(deleting the largest subsystem), it makes the syntax **familiar**
(reference semantics is what every easy language does), and it sharpens
the identity from "Python with a research memory model" to "**Python, but
compiled, typed, and fast**" — a thing the world wants and no one has
nailed. The two weeks on scope ownership were not wasted: they are the
evidence that makes this decision, on a flagship program, with eyes open.

---

## Historical: why scope ownership was tried (and what it cost)

Kept because it is the evidence for the decision above.

Luce began with **manual explicit memory**: `new`/literals to create,
`free(x)` to release, deterministic use-after-free and double-free traps,
loom reporting leaks after each run. Honest and fast, but `free` at every
exit path is the thing no one wants to write — the reason Python and Go
and Swift exist.

The answer chosen was **scope ownership**: the binding that received a
fresh owned object owned it; `let y = x` aliased; keeping a resource-free
container needed `give`/`copy`; calls borrowed unless a parameter said
`give`; scope end released everything. No collector, no refcount, values
copy. It was ratified as S1–S46 (`docs/OWNERSHIP.md`), built into the
compiler and `libluce_rt`, and proven by `ownership_spec.zig`.

It worked — and then a real UI was attempted, and every path hit the same
wall, because a UI is a retained graph of shared mutable objects and
scope ownership forbids exactly that:

- an `interface` value **borrows** its receiver, so a tree of widgets
  could not be **owned** behind one;
- interface dispatch was **read-only**, so a widget's `event` could not
  mutate it through the interface;
- lambdas were **capture-free**, so a callback could not touch app state;
- a **writing method could not bind** as a value (BINDING.md D9);
- a **carrying value could not become an interface** ("a carrying
  receiver cannot be returned as an interface");
- `params are values`, so a free function could not mutate caller state;
- `xs[i].field = v` was refused for carrying elements (S22).

Each of these is scope ownership refusing shared mutable retained state —
the substance of every UI framework from AppKit to Qt to SwiftUI. The
model was internally consistent and genuinely novel. It was also the
wrong trade for a language whose goal is to be the *easiest* one that is
still fast. So it is retired, with thanks for the lesson.
