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
//! not be doing it.**  `03_parse` expands f-strings into `str(x) + ...`
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
//! Until that pass is written, this file stays empty and honest.

test {}
