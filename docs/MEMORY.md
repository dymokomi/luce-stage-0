# The memory model

How Luce manages memory, and the source of truth for it.

## What Luce is

**A compiled, statically typed Python.** Familiar indentation-based
syntax, native AOT speed through the LLVM backend, and **memory you
never think about.** The moat is that combination — the joy of Python,
the speed of a compiled language, and a surface small enough to hold in
your head.

## The model, in one paragraph

Every type is one of two kinds. A **value type** — the scalars, `string`,
and a plain `struct` — copies when assigned or passed, lives inline, and
costs nothing at runtime. A **reference type** — a `class`, and the
containers `list`/`map`/`array`/`builder` — is a shared,
reference-counted object: assigning or passing it shares the same object,
and it is freed automatically when the last reference goes away. You
choose value or reference with one keyword (`struct` vs `class`), exactly
as Swift and C# do, and you get value performance where you want it and
reference ergonomics where you need it. There is no ownership verb of any
kind.

## The decisions

- **D1 — Two type kinds: value and reference.** `struct` is a value type
  (copy semantics, inline, no runtime cost). `class` is a reference type
  (shared identity, heap, automatically freed). The built-in containers
  (`list`, `map`, `array`, `builder`) and resources (`file`, `task`) are
  reference types. This is the Swift/C# split, and it is the whole answer
  to "easiest *and* fast": values stay fast, references stay easy.

- **D2 — Automatic Reference Counting.** Reference objects carry a count;
  the compiler inserts retain/release; the object is freed at the last
  release. **Deterministic**, so a `file`/`task` closes the instant its
  last reference dies — no finalizer roulette, no GC pause. ARC over a
  tracing GC specifically because Luce has resources whose cleanup must be
  prompt, and because deterministic destruction is simpler to reason
  about than collection timing.

- **D3 — `weak` for cycles.** ARC's one genuine cost: a reference cycle
  leaks. A `weak` reference does not retain, and reads as `T?` (it may
  have gone). This is the only new concept the model asks a programmer to
  learn. Cycles are rare enough (parent↔child back-edges) that `weak` is
  a footnote, not a daily tax.

- **D4 — Mutation is ordinary; interfaces dispatch to writing methods.**
  A method may mutate its receiver with no ceremony. An `interface`
  method may mutate its receiver, because an interface value is a
  reference. A reference passed to a function is the same object the
  caller holds; mutating it is visible to the caller, as everyone
  expects.

- **D5 — What references make ordinary.** Because a reference is shared
  and a `class` can be mutated through any reference to it, the
  graph-shaped, shared, retained things that are Luce's whole point are
  ordinary: **capturing closures** (a closure holds references, which ARC
  keeps alive), **retained mutable trees** (a window owns a tree of
  `class` nodes), **shared mutable state** (a `class` model referenced by
  many views), **delegates and callbacks**, and the **SwiftUI-shaped
  UI**. The UI framework is easy *and* beautiful, which is the proof the
  model is right.

- **D6 — Concurrency keeps its safety cheaply.** `spawn` runs a function
  on a worker with its own runtime; **value types cross a worker boundary
  by copy, and reference types do not cross at all** — a `class` or
  container stays in the runtime that made it. So there is no shared
  mutable state *between* workers by construction, even though there is
  shared mutable state *within* one. No data races across threads, no
  cost to single-threaded UI code. Locks, atomics, and thread identity
  remain deliberately absent; intra-worker sharing across threads, if ever
  wanted, is an actor-style addition priced separately.

- **D7 — `new` and literals make reference objects; assignment shares.**
  `let a = SomeClass(...)` makes one object; `let b = a` makes `b` refer
  to the *same* object; mutating through `b` is seen through `a`. A value
  `struct` still copies on `let b = a`. This is the one mental model every
  mainstream language shares, and it is what "familiar" means.

## Value or reference, at a glance

| Kind | Types | `let b = a` | Freed |
| --- | --- | --- | --- |
| **Value** | scalars, `string`, `struct`, `enum` | copies; `a` and `b` are independent | with the scope that holds it |
| **Reference** | `class`, `list`, `map`, `array`, `builder`, `file`, `task` | shares; `a` and `b` name one object | at the last reference |

A `weak` reference is the one exception on the reference side: it names an
object without retaining it, and reads as `T?` so a read after the object
is gone is `none`, never a dangling pointer.

## What is preserved

The memory model is the whole of the difference from a plain typed Python;
everything else in the language stands on its own:

- The **type system** — the numeric ladder (`docs/TYPES.md`,
  `docs/NUMERICS.md`), `enum` (`docs/ENUMS.md`), `union`
  (`docs/UNION.md`), `interface` (`docs/INTERFACES.md`), the storable
  function values (`docs/FUNCTIONS.md`), and generics-to-come
  (`docs/GENERICS.md`).
- The **pipeline** — lexer, parser, semantics, HIR, MIR, the LLVM
  backend, the serialized module (`docs/PIPELINE.md`, `docs/CODEGEN.md`).
- The **two-engine differential guarantee** — the interpreter oracle and
  the compiled path run every spec and are compared (`docs/ENGINE.md`).
  ARC is enforced identically on both.
- **Failure handling** (`T!`/`try`/`catch`), **modes**, **visibility**,
  **bitwise**, **packages**, the **host boundary**, and the **std
  library** shape.

## Why value + reference + ARC

It is the proven way (Swift, C#) to have value performance *and* reference
ergonomics. It keeps the language **small** — one keyword chooses the
kind, and there is nothing else to learn but `weak`. It keeps the syntax
**familiar** — reference semantics is what every easy language does. And
it is exactly what "**Python, but compiled, typed, and fast**" needs to be
true: the graph-shaped programs people actually write — UIs, editors,
ASTs — are ordinary, while the tight loops stay on inline values at C
speed.
