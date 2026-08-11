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
//! not be doing it.**  `03_parse` expands f-strings into `string(x) + ...`
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
//! ## What stands between here and there
//!
//! The other thing this stage would buy is the seam stage 4 does not
//! have: **check** (names, types, visibility, narrowing, folding, every
//! diagnostic) producing a typed tree, and **lower** (typed tree →
//! MIR, mechanical and diagnostic-free) consuming it.  That seam is
//! real and worth having, and it is *not* a matter of moving lines.
//! Six couplings hold the two halves together in
//! `04_semantics/builder.zig` today; each is named here with what it
//! becomes on the far side, because the list is the work.
//!
//! 1. **The walk's currency is a MIR register.**  A checked expression
//!    is `Typed{ register, value_type }` — a *typed register*.  Every
//!    question the checker asks about a value it asks of a register.
//!    On the far side a checked expression is an HIR node, and the
//!    questions are asked of the node.
//!
//! 2. **Three of those questions were answered by reading emitted code
//!    back off the tape — done, and the first piece of the seam to
//!    land.**  `producesFreshStorage` and `borrowsStoredValue` used to
//!    switch on `code.instructions.items[register]`, with `sourceOf`
//!    following a `carried` link to the instruction that really made
//!    the value; all three were asking what *kind of expression*
//!    produced it, through the instruction as a proxy.  That property
//!    now travels forward as `Typed.provenance`, stamped where each
//!    value is produced, and only `constantLong`'s integer proof still
//!    reads the tape (through `carriedOrigin`, the hop's surviving
//!    name).  A Debug-only oracle, `debugProvenanceOnTape`, re-derives
//!    the old answer at every consumer until the seam lands, and goes
//!    with it.  It was the one part of the move that was an
//!    improvement rather than a relocation, and it landed first, on
//!    its own, with the MIR byte-identical.
//!
//! 3. **A park can be retracted after it is emitted.**  `takeStorage`
//!    is move-instead-of-copy (docs/STRINGS.md): it reaches back into a
//!    statement temporary that has already been recorded, stops its
//!    slot owning storage, and hands the storage to the place being
//!    stored into.  Surgery on emitted code.  On the far side the owner
//!    is decided during check — the ledger of statement temporaries
//!    becomes an HIR-level ledger — and lower emits the decided form
//!    once.
//!
//! 4. **`splitsBlocks` asks a MIR question about an AST subtree.**
//!    Before lowering an operand batch, the checker scans each operand
//!    to guess whether lowering it will end in a different basic block,
//!    and spills the earlier operands if so.  It is a guess: it runs
//!    before anything has a type, `callSplits` over-matches on purpose,
//!    and the comment records that a wrong answer costs one spill.  On
//!    the far side lower computes it exactly, because lower is the only
//!    half that knows what a block is — and `splitsBlocks`,
//!    `callSplits`, `anySplits` and `namesEnum` all go.  **But that
//!    changes the emitted MIR** (fewer spills), so it cannot happen in
//!    the same commit as a move that has to be byte-identical.  Keep
//!    the guess through the move; delete it afterwards, measured.
//!
//! 5. **Narrowing keys on `LocalId`, which is stage 6's local table.**
//!    The flow analysis is a set of `LocalId`s saved and joined around
//!    each branch.  HIR needs a local numbering of its own, and lower
//!    has to reproduce the same ids in the same order — which it will,
//!    walking the same tree in the same order, but it is a thing to
//!    check rather than assume.
//!
//! 6. **The constant pool is filled during checking.**  A string
//!    literal is interned the moment it type-checks and its slot number
//!    is baked into the instruction, so HIR has to carry the interned
//!    slot rather than the bytes, or the pool comes out in a different
//!    order.
//!
//! One shape argues for the move rather than against it: a fallible
//! call opens a basic block in the middle of an expression and leaves
//! it for the `try` or `catch` written in front of it to fill, the two
//! coordinating through a one-hop `opened` field on the walker.  As an
//! HIR node that is just `Try{ call }` — the sugar-stays-a-node
//! argument, in the one place the fused walk is hardest to read.
//!
//! **How far stage 4 got without this stage.**  As far as it honestly
//! can.  What could leave `builder.zig` under the file-boundary rule
//! (docs/CODING_GUIDE.md — a split that forces a declaration `pub` for
//! a sibling is the wrong split) has left it: `builtins.zig` (the
//! tables, which were already published to the grammar tool and the
//! site) and `effects.zig` (the two predicates that need no checker
//! state at all).  Everything else in that file is a method on the
//! walker, reaching the walker's scopes, its tape, or both — so the
//! next legitimate cut is this seam, and there is no smaller one
//! hiding behind it.  `constants.zig` came out of `declarations.zig`
//! the same way, and is the shape to aim at: it answers with a value
//! and never emits, which is exactly what `lower`'s input has to be.
//!
//! Until that pass is written, this file stays empty and honest.

test {}
