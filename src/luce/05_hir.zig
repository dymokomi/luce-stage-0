//! Stage 5 — high-level lowering (HIR).  **The check/lower seam,
//! built.**
//!
//! Consumes: `nodes.Body`, the typed tree stage 4's checked walk
//! records — resolution, types, ownership verbs, store kinds, parks,
//! batch rewrites, all decided during checking.
//! Produces: stage 6's tape.  `05_hir/lower.zig` is **the one
//! emission**: a mechanical, diagnostic-free lowering of each
//! recorded body, whose error set is `OutOfMemory` alone.  Stage 4's
//! walk checks and records and emits nothing; the driver reaches MIR
//! only through this pass (`04_semantics/declarations.zig` hands each
//! clean body over, because only the analyzer holds the settled
//! declaration tables lower reads).
//!
//! The seam landed family by family, and every landing was held to
//! byte-identical MIR: a corpus of 1637 spec programs and 253 dumped
//! ones was recorded before the first move and checked after each,
//! and the flip itself ran both paths on every clean compile with a
//! Debug gate comparing the two tapes instruction for instruction.
//! All of that was scaffolding and all of it is gone; what proves
//! the pass now is the suite — every spec program still runs on both
//! engines and is compared on prints, traps, traces and leaks
//! (docs/ENGINE.md), which is what proved the emissions before the
//! seam existed.
//!
//! **What an HIR is for: sugar stays a node until one pass removes it.**
//!
//! HIR is tree-shaped like the AST, but resolved and typed like stage 4's
//! output — and crucially it keeps every piece of source-level sugar as
//! an explicit, structured node rather than as whatever it expands to.
//! `x += 10` is not `x = x + 10` here; it is:
//!
//! ```text
//! CompoundAssign
//! ├── target: x
//! ├── op:     +
//! └── value:  10
//! ```
//!
//! Lowering HIR to MIR is then the *one* pass that desugars, and the
//! only place that knows what `+=` expands to — which `lower.zig` now
//! is: compound assignment, `for x in xs`, `for i in range(a, b)`,
//! nested place assignment, `match`, short-circuit `and`/`or` and the
//! fallible forms all reach it as structured nodes and expand there.
//!
//! **One desugaring is still upstream of the tree.**  `03_parse`
//! expands f-strings into `string(x) + ...` and `elif` chains into
//! nested `if`s while it still has nothing but syntax, so those two
//! arrive here pre-expanded.  Moving them down is the remaining half
//! of the picture above, and it changes stage 3's output — its own
//! landing, planned as one.
//!
//! ## The one rule this stage must not break
//!
//! **Whole-array operations survive HIR and MIR as single nodes.  Never
//! expand one into a scalar loop.**
//!
//! `src/luce/std/math.luc` already speaks BLAS-1 — `sum`, `mean`, `dot`,
//! `norm`, `variance`, `scale`, `axpy`, `fill`.  Today each is an
//! ordinary Luce function containing a scalar loop, so by the time MIR
//! exists the array operation has already been destroyed.  MIR is the
//! last level at which `map ∘ map` is still a rewritable algebraic
//! fact; fusing a chain of elementwise operations into one loop nest,
//! with no intermediate arrays, is a local rewrite there and is
//! impossible once the loops are written.  Measured on LLVM 22: two
//! adjacent elementwise loops in separate functions — which is what a
//! library `map` looks like — are fused by *no* configuration of
//! `-O3`, and `LoopFusePass` is off by default with an in-tree FIXME
//! about its place in the pipeline.
//!
//! `docs/OWNERSHIP.md` S3 already licenses the elimination: an unbound
//! temporary dies at the end of its statement, so the intermediates in
//! `a * b + c` are unnamed, statement-scoped, and unobservable.  The
//! legal precondition exists; only the representation is missing.
//!
//! This binds every arm added here, because it is the one decision the
//! stage cannot take back.  Sugar that gets
//! expanded too early is a refactor.  An array operation expanded into
//! a scalar loop is information destroyed, and no later pass, second
//! IR, or dialect recovers it — it forecloses the array-compute and GPU
//! directions permanently.  Desugar `+=`, `for x in xs`, methods and
//! f-strings freely; leave whole-array operations whole.
//!
//! ## The six couplings the seam dissolved
//!
//! Check (names, types, visibility, narrowing, folding, every
//! diagnostic) produces a typed tree; lower (typed tree → MIR,
//! mechanical and diagnostic-free) consumes it.  Getting there was
//! *not* a matter of moving lines: six couplings held the two halves
//! together in `04_semantics/builder.zig`, and each is named here with
//! what it became, because the list was the work.
//!
//! 1. **The walk's currency was a MIR register.**  A checked
//!    expression is now `Typed{ node, value_type }` — a *typed node* —
//!    and every question the checker asks about a value it asks of the
//!    node.
//!
//! 2. **Three ownership questions were answered by reading emitted
//!    code back off the tape.**  What kind of expression produced a
//!    value is now the node kind's own property (`nodes.provenance`),
//!    overridden only by the two recorded batch rewrites (a borrow
//!    copy leaves a value fresh, a spill reload leaves it a view);
//!    `constantLong`'s integer proof reads the tree.
//!
//! 3. **A park could be retracted after it was emitted.**
//!    `takeStorage` — move-instead-of-copy (docs/STRINGS.md) — now
//!    settles the checker's own ledger and the recorded rows; lower
//!    emits the decided form once, with no surgery on emitted code.
//!
//! 4. **`splitsBlocks` asks a MIR question about an AST subtree.**
//!    Still a guess, deliberately: it runs before anything has a type,
//!    `callSplits` over-matches on purpose, and a wrong answer costs
//!    one spill, recorded as the batch's spill flags.  Lower could
//!    compute it exactly — it is the half that knows what a block is —
//!    **but that changes the emitted MIR** (fewer spills), so the
//!    guess outlived the flip on purpose and its deletion is its own
//!    measured landing.
//!
//! 5. **Narrowing keys on `LocalId`.**  The tree's locals table
//!    (`Body.locals`) is now the numbering: the walk allocates every
//!    slot, and lower reproduces stage 6's table by walking the same
//!    declarations in the same order, asserting the lockstep.
//!
//! 6. **The constant pool is filled during checking** — still, and now
//!    by design: nodes carry interned slots, and the walk interns
//!    everything its tree will need (member-name chains included) so
//!    the pool's order never depends on when lower runs.
//!
//! One shape argued for the seam and paid off: a fallible call used to
//! open a basic block mid-expression for the `try` or `catch` in front
//! of it to fill, the two coordinating through a one-hop `opened`
//! field.  As a node that is just `TryCall{ call, temps_floor }`, and
//! the failing side is lower's to spell.

/// The typed tree the seam hands over: node kinds, statements, the
/// per-body local table, and the computed `provenance` property.
pub const nodes = @import("05_hir/nodes.zig");

/// The lower half of the seam — the one emission: lower a recorded
/// `Body` into stage 6's tape.
pub const lower = @import("05_hir/lower.zig");

test {
    _ = nodes;
    _ = lower;
}
