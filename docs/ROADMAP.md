# ROADMAP — the value/reference + ARC pivot

> The sequenced plan for replacing scope ownership with value/reference
> types + ARC (`docs/MEMORY.md`). This is a **big-bang change to the
> foundation**, not an additive feature: the ownership subsystem is woven
> through every stage, so the honest unit of work is "rip and replace,"
> committed at coherent checkpoints. No compatibility is preserved.

## Guiding cuts

- **Delete before you add where you can.** The subsystem's removal is
  most of the win; ARC is smaller than what it replaces.
- **The two-engine guarantee is non-negotiable.** ARC is enforced
  identically in `libluce_rt` and the interpreter oracle, and every spec
  compares them. A phase is not done until both engines agree.
- **`format_version` bumps once**, when the MIR ownership instructions
  become ARC instructions. `abi.version` bumps once, when `libluce_rt`
  gains retain/release. No migration — everything recompiles from source.

## Phases

### Phase 0 — Docs & direction (this step)
Authoritative `docs/MEMORY.md`, this roadmap, superseded banners on the
ownership docs, `CLAUDE.md` and `docs/README.md` updated. The repo tells
one story before code moves. **Leaves the repo green.**

### Phase 1 — Type kinds in the front end
- Parser: `class Name:` declares a reference type beside `struct Name:`
  (a value type). Same field/method grammar.
- Semantics: a `class` type is a reference; a `struct` is a value. The
  built-in containers and `file`/`task` are reclassified as reference
  kinds. `Type` gains nothing new structurally — `strukt` already indexes
  a layout; a per-layout `kind` (value | reference) is the only addition.
- No behavior change yet beyond kind-tracking; assignment/passing still
  compiles as today. This phase is additive and can stay green.

### Phase 2 — ARC in `libluce_rt` and the oracle
- A reference object gains a refcount header. `luce_rt_retain`,
  `luce_rt_release` (release frees at zero, running `deinit`/resource
  close). The interpreter's object table mirrors it exactly.
- Resources (`file`/`task`) close on final release — same determinism as
  scope end gave, now driven by the count.
- `abi.version` bumps. Specs added for retain/release, deterministic
  release, and resource close-at-last-reference, on both engines.

### Phase 3 — Ownership deletion + share/copy semantics
The big cut. Remove from `04_semantics`: `give`/`copy`/`free`, the S1–S46
enforcement, borrow tracking, carrying/fresh/resource categories, the
interface-borrow and read-only-dispatch rules, capture-free-lambda
enforcement, writer-binding refusal, `S22`, and every diagnostic that
policed them (`luce.sema.own`, `use_after_free`, `not_owned`,
`double_free`). Replace the model:
- assigning/passing a **value** copies; a **reference** shares (a retain).
- a reference goes out of scope → a release.
- `new`/literals allocate a reference with count 1.

### Phase 4 — MIR & backend: retain/release
- `06_mir`: the `bind`/`unbind` ownership instructions become
  `retain`/`release`; the verifier checks reference-count discipline
  instead of ownership. `format_version` bumps.
- `08_llvm`: the ownership-elision passes (`ownership.zig`) become
  ARC-elision (drop retain/release pairs LLVM cannot see through, elide
  redundant retains on non-escaping references — the SILGen playbook).
- The interpreter gains the same retain/release counting.

### Phase 5 — Language surface unlocks
Now that references are shared and mutable:
- **Mutating interface methods** (delete the read-only-dispatch rule).
- **Capturing closures** — a lambda captures referenced objects; ARC
  keeps them alive; one function type still covers plain functions and
  closures.
- **`weak`** references (`weak var parent: Node?`), non-retaining, read as
  `T?`.
- Interface values are references that own a share and may mutate.

### Phase 6 — Rewrite the users of the model
- `std/*` — drop `give`/`copy`; containers are shared.
- `examples/editor` — rewrite on the new model (the state coordinator
  gets much smaller: shared mutable buffers, no remember/restore dance).
- `packages/termui` — the retained-tree or SwiftUI-shaped framework the
  reckoning was about (`docs/GENERICS.md`, the UI brainstorm), now
  buildable.
- `bench/*` — value types keep their speed; re-baseline the graph-heavy
  rows that should now improve (sharing beats deep copies).

### Phase 7 — Docs sweep
Rewrite the ~38 docs that describe ownership, feature by feature, each
losing its `give`/`copy`/borrow language. `OWNERSHIP.md` becomes a
historical record like `docs/v1/`. `GENERICS.md` simplifies (no ownership
to price against). Update `TESTING.md`, `ENGINE.md`, `CODEGEN.md`,
`PIPELINE.md` to the ARC pipeline.

## Concurrency, kept
`spawn` unchanged; **value types cross a worker by copy, reference types
do not cross** — so no shared mutable state *between* workers, even with
sharing *within* one (`docs/MEMORY.md` D7). Locks/atomics/actors stay out
until a workload asks.

## Order of attack
Phases 1→2 are additive and stay green. Phase 3 is the break — after it,
the gate is red until Phase 4 lands and the specs are rewritten. Work
Phase 3+4 together toward one green checkpoint. Phases 5–7 are then
incremental and each can be green on its own.

## What "done" looks like
`app.run(App())` hides the loop; a `class` widget tree is retained and
mutated in place; a button's `on_press` closure captures and mutates app
state directly; `struct` numerics keep their benchmark speed; both
engines agree on every spec; and the language surface is *smaller* than
it was with ownership.

## Execution map (where the code lives)

Grounded in the tree so the surgery starts fast. Scope ownership is woven
through ~22 semantics files, the runtime, MIR, the optimizer, and 18+
specs — this is a multi-week rip-and-replace, not an afternoon.

**Front end (Phase 1 — additive, green).**
- `02_lex/token.zig`: add `keyword_class` (keyword table + `Kind`).
- `03_parse/grammar.zig`: `structDecl` gains a `kind` (reuse the body
  parse; `class` differs only in the header keyword).
- `ast`: `StructDecl.kind: value | reference`.
- `04_semantics/layouts.zig` + `support/types.zig`: a per-layout `kind`
  so `strukt` indices carry value-vs-reference; the containers and
  `file`/`task` are reference by construction.

**Semantics deletion (Phase 3 — the break).** The ownership logic lives
in `04_semantics/`: the dedicated files `ledger.zig` (statement-temporary
ownership), `flow.zig` (root provenance / narrowing), `effects.zig`,
`refusals.zig`, and the ownership arms threaded through `assign.zig`,
`construct.zig`, `calls.zig`, `builder.zig`, `expressions.zig`,
`statements.zig`, `shapes.zig` (`carriesObjects`), `interfaces.zig`
(borrow + read-only dispatch), `receiver.zig`, `context.zig`. Delete the
verbs, the S-rule enforcement, `provenance`, the carrying/fresh/resource
categories, and the diagnostics (`luce.sema.own`, `use_after_free`,
`not_owned`, `double_free`). Replace with the one rule: value → copy,
reference → share.

**Runtime (Phase 2 + 4).** `runtime/heap.zig` + `runtime/value.zig` +
`runtime/containers.zig`: a reference object gains a refcount header;
`ownValue`/`dropStorage` become `retain`/`release`; scope-drop becomes
release. `runtime/exports.zig`: publish `luce_rt_retain`/`_release`;
`abi.version` bumps. `runtime/workers.zig`: keep "references don't cross a
worker boundary."

**MIR & backend (Phase 4).** `06_mir.zig` + `06_mir/`: the ownership
instruction pairs and sealing become `retain`/`release`; the verifier
checks count discipline; `format_version` bumps. `07_optimize/`: the
`ownership` pass becomes ARC-elision. `08_llvm/lower.zig` + `roots.zig`:
emit retain/release; drop the ownership-root guards.

**Oracle (Phase 4).** `interpreter/` mirrors the same retain/release
counting so both engines agree.

**Specs (Phase 3–4).** `specs/ownership_spec.zig` is deleted/replaced by
an ARC spec (sharing, deterministic release, `weak`, resource
close-at-last-reference); the 18 spec files that assert `give`/ownership
behavior are rewritten. Both engines, as always.

**Users (Phase 6).** `src/luce/std/*.luc`, `examples/editor/*`,
`packages/termui/*`, `bench/*` drop the verbs and lean on sharing.

The additive front-end scaffolding (Phase 1) is the safe first commit;
Phases 3–4 are one atomic push to the next green checkpoint.

## Runtime ARC design (grounded in the tree, for Phase 2/4)

What the code actually looks like today, so the surgery is precise:

- `runtime/heap.zig` `Object` carries `generation: u32` (stale-handle
  detection — keep it), `next_free` (the free list — keep it), and
  **`owner: Owner`** — the scope-ownership field that decides who frees.
  There is **no refcount yet**. `Object.release()` and
  `Runtime.freeObject`/`dropStorage`/`freeValue` are the current
  scope-drop path.
- **The one change at the heart of it:** add `references: u32` to
  `Object`; delete `owner: Owner` and the `Owner` type. `newList`/
  `newMap`/`newArray`/`newBuilder`/`newFile`/`newTask`/`newResource`
  (and a new `newClass`) set `references = 1`. `luce_rt_retain(handle)`
  increments; `luce_rt_release(handle)` decrements and, at zero, runs the
  existing free path (`freeObject`, which already recycles the row via
  `generation`+`next_free` and frees `data`/`list`/`array` storage). The
  free machinery is reused wholesale; only *when* it runs changes.
- **Value vs reference at the boundary:** a value `struct` and the
  scalars stay inline in `Value` (no object, no count). A reference —
  `class`, container, resource — is a `Value` holding a `Handle`, and it
  is the thing retain/release act on. `StructLayout.reference` (Phase 1b)
  is the compile-time switch that decides which lowering a `strukt` type
  gets.
- **MIR (`06_mir`)** replaces the ownership instruction pairs (bind/
  unbind/seal) with `retain`/`release`; the verifier checks that every
  reference produced is released on every path (the discipline the
  ownership sealer already enforces, recast as counts). `format_version`
  bumps.
- **Codegen (`08_llvm/lower.zig`)** emits `luce_rt_retain` on a reference
  copy/store and `luce_rt_release` at scope end; `07_optimize`'s
  ownership pass becomes retain/release elision (drop a retain/release
  pair on a reference that does not escape — the SILGen move). The
  interpreter (`interpreter/`) counts identically.
- **What deletes:** `runtime/value.zig`'s `Owner`, the ownership arms in
  `dropStorage`/`freeValue`/`freeObjectsIn`, and the whole
  `04_semantics` ownership walk. Resources still close deterministically
  — `newFile`/`newTask` release at count zero, same instant scope end
  gave, so `docs/FILESYSTEM.md`/`docs/THREADS.md` keep their guarantee.

The retain/release counting is one screenful in `libluce_rt`; the work is
in the coordinated removal of the ownership walk from `04_semantics` and
the MIR/codegen swap, done together so both engines land green at once.
