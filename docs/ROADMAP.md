# ROADMAP — building the value/reference + ARC memory model

> The sequenced plan for Luce's memory model: **value and reference
> types with automatic reference counting** (`docs/MEMORY.md`). The model
> touches every stage, so the honest unit of work is a coordinated
> build-out of ARC and removal of the legacy ownership subsystem,
> committed at coherent checkpoints. No compatibility is preserved.

## Where we are

The **ARC engine is built and green.** The built-in reference types —
`list`, `map`, `array`, `builder`, `file`, `task` — are reference-counted
with compiler-inserted retain/release, freed at the last release, on both
engines, with zero leaks across the whole spec suite. The legacy
ownership subsystem (`give`/`copy`/`free`, the S-rules) is gone, and the
documentation is rewritten to describe ARC. That is **Phases 0–4 and 7**.

What is **not** built yet is the language surface a user reaches for a
`class` — **Phase 5**. A `class` parses and type-checks as a reference
kind, but it still *lowers* as a value: assigning one copies rather than
shares, so a mutation through one name is not yet seen through another.
`weak`, capturing closures, and mutating interface dispatch are likewise
still refused. Phase 5 wires the reference-kind flag through the lowering
and lifts those refusals; Phase 6 then rewrites the standard library, the
editor, and termui to use sharing. **Those two phases are the remaining
distance to "full ARC with classes."** Test coverage tracks the build:
everything shipped is exercised on both engines; the unbuilt features have
no specs because they do not exist yet.

## Guiding cuts

- **Delete before you add where you can.** Removing the legacy subsystem
  is most of the win; ARC is smaller than what it replaces.
- **The two-engine guarantee is non-negotiable.** ARC is enforced
  identically in `libluce_rt` and the interpreter oracle, and every spec
  compares them. A phase is not done until both engines agree.
- **`format_version` bumps once**, when the MIR ownership instructions
  become ARC instructions. `abi.version` bumps once, when `libluce_rt`
  gains retain/release. No migration — everything recompiles from source.

## Phases

### Phase 0 — Docs & direction  ✓ done
Authoritative `docs/MEMORY.md`, this roadmap, `CLAUDE.md` and
`docs/README.md` tell one story before code moves. The repo is green.

### Phase 1 — Type kinds in the front end  ✓ done
- Parser: `class Name:` declares a reference type beside `struct Name:`
  (a value type), with the same field/method grammar.
- Semantics: a `class` is a reference; a `struct` is a value. The built-in
  containers and `file`/`task` are reference kinds. A per-layout `kind`
  (value | reference) is the only structural addition to `Type`.
- Additive and green: assignment and passing still compile as before.

### Phase 2 — ARC in `libluce_rt` and the oracle  ✓ done
- A reference object gains a refcount header. `luce_rt_retain`,
  `luce_rt_release` (release frees at zero, running the resource close).
  The interpreter's object table mirrors it exactly.
- Resources (`file`/`task`) close on final release — deterministic, driven
  by the count.
- `abi.version` bumps. Specs added for retain/release, deterministic
  release, and resource close-at-last-reference, on both engines.

### Phase 3 — share/copy semantics; the legacy subsystem removed  ✓ done (built-in references)
The big cut. Remove the legacy ownership walk and its diagnostics from
`04_semantics`, and replace the model with the one rule:
- assigning/passing a **value** copies; a **reference** shares (a retain).
- a reference going out of scope → a release.
- `new`/literals allocate a reference with count 1.

### Phase 4 — MIR & backend: retain/release  ✓ done
- `06_mir`: the ownership instruction pairs become `retain`/`release`;
  the verifier checks reference-count discipline. `format_version` bumps.
- `08_llvm`: the ownership-elision pass becomes ARC-elision (drop
  retain/release pairs LLVM cannot see through, elide redundant retains on
  non-escaping references — the SILGen playbook).
- The interpreter counts identically.

### Phase 5 — Language surface unlocks  ← next
Now that references are shared and mutable:
- **Mutating interface methods** — an interface value is a reference.
- **Capturing closures** — a lambda captures referenced objects; ARC keeps
  them alive; one function type still covers plain functions and closures.
- **`weak`** references (`weak var parent: Node?`), non-retaining, read as
  `T?`.

### Phase 6 — Rewrite the users of the model  (after 5)
- `std/*` — containers are shared; no verbs.
- `examples/editor` — the state coordinator shrinks: shared mutable
  buffers, no remember/restore dance.
- `packages/termui` — the retained-tree / SwiftUI-shaped framework, now
  buildable (`docs/GENERICS.md`, the UI brainstorm).
- `bench/*` — value types keep their speed; re-baseline the graph-heavy
  rows that sharing should improve.

### Phase 7 — Docs sweep  ✓ done
Rewrite the remaining docs to the ARC pipeline, feature by feature.
`GENERICS.md` simplifies (no ownership to price against). Update
`TESTING.md`, `ENGINE.md`, `CODEGEN.md`, `PIPELINE.md`.

## Concurrency, kept
`spawn` unchanged; **value types cross a worker by copy, reference types
do not cross** — so no shared mutable state *between* workers, even with
sharing *within* one (`docs/MEMORY.md` D6). Locks, atomics, and actors
stay out until a workload asks.

## Order of attack
Phases 1→2 are additive and stay green. Phase 3 is the break — after it,
the gate is red until Phase 4 lands and the specs are rewritten. Work
Phase 3+4 together toward one green checkpoint. Phases 5–7 are then
incremental and each can be green on its own.

## What "done" looks like
`app.run(App())` hides the loop; a `class` widget tree is retained and
mutated in place; a button's `on_press` closure captures and mutates app
state directly; `struct` numerics keep their benchmark speed; both engines
agree on every spec; and the language surface is *smaller* than it was
before ARC.

## Runtime ARC design (grounded in the tree, for Phase 2/4)

What the code looks like today, so the surgery is precise:

- `runtime/heap.zig` `Object` carries `generation: u32` (stale-handle
  detection — keep it) and `next_free` (the free list — keep it). The
  central change: add `references: u32` to `Object`; `newList`/`newMap`/
  `newArray`/`newBuilder`/`newFile`/`newTask` (and a new `newClass`) set
  `references = 1`. `luce_rt_retain(handle)` increments; `luce_rt_release`
  decrements and, at zero, runs the existing free path (`freeObject`,
  which already recycles the row via `generation`+`next_free` and frees the
  storage). The free machinery is reused wholesale; only *when* it runs
  changes.
- **Value vs reference at the boundary:** a value `struct` and the scalars
  stay inline in `Value` (no object, no count). A reference — `class`,
  container, resource — is a `Value` holding a `Handle`, and it is the
  thing retain/release act on. The per-layout `reference` flag is the
  compile-time switch that decides which lowering a `strukt` type gets.
- **MIR (`06_mir`)** replaces the ownership instruction pairs with
  `retain`/`release`; the verifier checks that every reference produced is
  released on every path. `format_version` bumps.
- **Codegen (`08_llvm/lower.zig`)** emits `luce_rt_retain` on a reference
  copy/store and `luce_rt_release` at scope end; `07_optimize`'s pass
  becomes retain/release elision (drop a pair on a reference that does not
  escape — the SILGen move). The interpreter (`interpreter/`) counts
  identically.
- Resources still close deterministically — `newFile`/`newTask` release at
  count zero, the same instant scope end gave, so `docs/FILESYSTEM.md` and
  `docs/THREADS.md` keep their guarantee.

The retain/release counting is one screenful in `libluce_rt`; the work is
in the coordinated removal of the legacy walk from `04_semantics` and the
MIR/codegen swap, done together so both engines land green at once.
