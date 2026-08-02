//! Stage 7 — MIR optimization.  MIR in, MIR out.
//!
//! Consumes: a verified `mir.Program`.
//! Produces: the same program, smaller.  The stage runs in place and
//! the result is re-verified, so an optimization that breaks an
//! invariant is an internal compiler error rather than a miscompile.
//!
//! **One pass exists: dead-code elimination.**  `prune` drops every
//! function unreachable from the entry, which is what makes `import
//! strings` cost nothing when a program calls three of its eighteen
//! functions.  `luce ir --full` turns the stage off to show the
//! unpruned lowering.
//!
//! **What is not done yet — everything else.**  There is no constant
//! folding beyond what stage 4 folds while checking, no inlining, no
//! common-subexpression elimination, no loop work, and no dead *store*
//! or dead *instruction* elimination inside a surviving function.
//! Nothing here is on by cost or off by risk: the passes simply have
//! not been written.  LLVM's `default<O2>` currently does the scalar
//! optimization on the compiled path (docs/CODEGEN.md), and the
//! interpreter gets none of it, which is exactly the asymmetry this
//! stage exists to remove.
//!
//! Flat pieces beside this file:
//!
//!   prune.zig — dead-code elimination, plus the renumbering that
//!               keeps function indices dense afterwards.

pub const prune = @import("07_optimize/prune.zig").prune;

test {
    _ = @import("07_optimize/prune.zig");
}
