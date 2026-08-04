//! Stage 5 — high-level lowering (HIR).  **Nothing runs here yet.**
//!
//! Consumes: nothing.
//! Produces: nothing.  The validated tree stage 4 produces goes
//! straight on to MIR, so this stage is a pass-through in the literal
//! sense — the driver names it and does not call it.
//!
//! There is no `05_hir/` directory because there is no code to put in
//! one.  The barrel exists on its own so the stage has a place in the
//! listing, in `luce.zig`, and in `compile.zig`, and so the gap is
//! visible rather than inferred from a number that never appears.
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
//! only place that knows what `+=` expands to.
//!
//! **Today the desugaring is scattered across two stages that should
//! not be doing it.**  `03_parse` expands f-strings into `String(x) + ...`
//! and `elif` chains into nested `if`s while it still has nothing but
//! syntax.  `04_semantics/builder.zig` expands methods, `for x in xs`,
//! `for i in range(a, b)`, compound assignment, nested place
//! assignment, and short-circuit `and`/`or` while it is busy type
//! checking.  Neither of those is "the desugaring"; each is a stage
//! doing its own job and quietly doing this one too.
//!
//! So building this stage is not only additive: **the parser has to
//! stop desugaring** and start producing the sugar as nodes.  That is
//! the part to plan for, because it changes stage 3's output.
//!
//! What it buys, concretely: diagnostics can talk about `+=` instead of
//! the expansion; a formatter, an IDE, or any source-level rewrite has
//! a faithful tree to read; and the expansion rules live in one file
//! that can be tested directly rather than being spread over a parser
//! and a type checker.
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
//! This matters now, while the stage is unwritten, because it is the
//! one decision here that cannot be taken back.  Sugar that gets
//! expanded too early is a refactor.  An array operation expanded into
//! a scalar loop is information destroyed, and no later pass, second
//! IR, or dialect recovers it — it forecloses the array-compute and GPU
//! directions permanently.  Desugar `+=`, `for x in xs`, methods and
//! f-strings freely; leave whole-array operations whole.
//!
//! Until that pass is written, this file stays empty and honest.

test {}
