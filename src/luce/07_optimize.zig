//! Stage 7 — MIR optimization.  MIR in, MIR out.
//!
//! Consumes: a verified `mir.Program`.
//! Produces: the same program, smaller.  The stage runs in place and
//! the result is re-verified, so an optimization that breaks an
//! invariant is an internal compiler error rather than a miscompile.
//!
//! ## What this stage is for, and what it is emphatically not for
//!
//! Not for scalar optimization.  Every artifact goes through
//! `default<O3>`, which folds constants, inlines, does GVN and LICM and
//! loop rotation and dead-store elimination, and — via
//! `constraint-elimination` — bounds-check elimination, all better than
//! anything written here would.  A pass that duplicates `default<O3>`
//! costs compile time to be slower than what we already have, and this
//! stage has just paid that debt off: `flow` and `values` were written
//! for the interpreter, measured at **-2.5% LLVM compile time and 0%
//! compiled runtime**, and went with the interpreter's retirement
//! (docs/ENGINE.md step 7).  Do not write their successors.
//!
//! Nor is this where a container gap gets closed.  Rewriting
//! `index_get` into a typed `array_get_float` would give a code
//! generator nothing it does not already know — the element kind is in
//! MIR's type table — and cost a `format_version` bump.  The fix for
//! that class of problem is stage 8 emitting an inline specialized
//! access instead of a call, and it is not expressible here at all:
//! MIR has no load, no GEP, and no pointer.
//!
//! What is left is narrow, and this stage should stay small:
//!
//!  1. **What LLVM structurally cannot see.**  Ownership is two opaque
//!     `luce_rt_*` calls that LLVM must assume read and write the
//!     world; MIR names them, knows the owner field is one field, and
//!     can prove a store to it dead.  That is the one pass here with an
//!     argument nothing downstream can replace.
//!  2. **Not handing the back end work that will be thrown away.**
//!     A std import brings its whole module in; `prune` drops what the
//!     entry cannot reach before LLVM ever sees it, and `dead` sweeps
//!     what `ownership` orphaned.  Both are about the *size of the
//!     input*, which is the one thing a front end can hand a back end
//!     cheaply.
//!
//! There used to be a third reason — "whatever measurably helps the
//! interpreter" — and it is gone with the engine it named.
//!
//! ## What runs
//!
//! `run` applies them in this order, and `Passes` turns each one off by
//! itself so a bisect can name the one that broke something.
//!
//!   prune.zig     — drop functions the entry cannot reach.  `import
//!                   std.strings` then one call: 26 functions become 2.
//!   ownership.zig — delete `object_bind`s a later bind overwrites and
//!                   `object_unbind`s that provably free nothing.
//!   dead.zig      — sweep instructions nothing reads, then compact the
//!                   instruction pool.  Must run after the instruction
//!                   passes above: they leave orphans on purpose rather
//!                   than renumber.
//!   prune.zig     — after those three settle the surviving block
//!                   items, compact constant-container rows and the
//!                   shared strings they and `const_string` retain.
//!
//! Over the nine bundled programs and six benchmarks, the raw lowering
//! against what the stage leaves (`luce ir --full` against `luce ir`):
//!
//! ```text
//!                  instructions   blocks
//!   raw lowering          12783     1776
//!   optimized              7047      912
//!                        -44.9%   -48.6%
//! ```
//!
//! Almost all of that is `prune`, which is the point: what a program
//! never does should not reach the artifact, the linker, or LLVM.
//! Deleting `flow` and `values` handed 635 instructions and 87 blocks
//! back to the back end, and cost **+0.1%** of `luce build --release`
//! wall time over that corpus (554.4 ms → 555.2 ms, best of five
//! each) and nothing at all at run time (`bench/compare.sh`, every row
//! inside ±0.8%) — which is the whole of what two passes and 498 lines
//! were buying once nothing interpreted MIR.
//!
//! `dead` is not really an optimization at all — it is the compactor
//! the other two rely on, and its own sweep finds four instructions in
//! the whole corpus.
//!
//! ## The line none of them may cross
//!
//! A program's behaviour is identical afterwards, down to the trap's
//! *source location*.  Nothing that can trap is ever deleted (only
//! `pure` instructions go) and nothing is reordered.  Origins travel
//! with their instructions through compaction, so a debug build still
//! reports `file:line:column` from the same place.
//! `specs/optimize_spec.zig` runs the stage off against the stage on —
//! printed bytes, trap code, trap message, call trace, and objects left
//! alive — over hand-written ownership cases and 400 generated
//! programs, on **both** engines, and every spec in `specs/` already
//! compiles with this stage on.
//!
//! ## What deliberately does not run, and why
//!
//! *Constant folding, inlining, LICM, loop unrolling, strength
//! reduction, bounds-check elimination.*  `default<O3>`'s job, and
//! `constraint-elimination` already does the last one.  Stage 4 folds
//! the constants it needs to type-check, and what it leaves behind is a
//! rounding error: two dead pure instructions in the whole corpus.
//!
//! *Block-local value numbering and control-flow threading.*  They were
//! here, they worked, and they bought the shipping engine nothing —
//! `default<O3>` had already found everything they found.  See above.
//!
//! *Typed container instructions* (`array_get_float` and friends).  Not
//! the lever; see above.
//!
//! *CSE of container reads* — `len` of a list nothing has touched,
//! `index_get` with the same index twice.  This one would be genuinely
//! ours, and it still does not pay: every candidate needs a mutation
//! barrier, and a scan of `examples/` and `bench/` finds *zero* pairs
//! to fold.  MIR keeps a value in a local across a block boundary, so
//! the two reads of one container in a loop are in different blocks,
//! and inside a block a container is read once.  The opportunity is a
//! property of source code we do not write.
//!
//! *Eliding a whole `bind`/`unbind` pair.*  Tempting by analogy with
//! Swift's ARC, and wrong here.  `object_unbind` is the deallocation,
//! not a release of a reference count: an object nothing unbinds is
//! never freed, and `ownership_spec`'s S33 counts that as a leak.  Only
//! stores that are provably overwritten and unbinds that are provably
//! inert come out; see ownership.zig.  The cleaner fix is upstream —
//! `04_semantics/builder.zig` could stop emitting the hidden
//! temporary's bind when the value is adopted in the same statement,
//! and then this pass would have nothing to do.
//!
//! *Renumbering locals.*  Cannot be done at all today: `give` and
//! `free` pass the owner's local id to the runtime as an ordinary
//! integer constant, so a local id is a *value* and no rewrite can find
//! it.  dead.zig's header has the full account.
//!
//! Flat pieces beside this file:
//!
//!   effects.zig   — what an instruction may be assumed about: the one
//!                   table every pass consults before it moves,
//!                   duplicates, or deletes anything.  Stage 8 asks it
//!                   too (`viewStable`), so the two stages cannot
//!                   disagree about the same instruction.
//!   registers.zig — where an instruction keeps its register operands,
//!                   written once so no rewrite can miss one.
//!   prune.zig, ownership.zig, dead.zig — the passes, each with its own
//!                   header arguing for itself.
//!   test.zig      — the stage's own proofs: each pass driven alone,
//!                   and the rewrite it claims checked by name.

const std = @import("std");
const mir = @import("06_mir.zig");
const prune_pass = @import("07_optimize/prune.zig");

pub const prune = prune_pass.prune;
pub const ownership = @import("07_optimize/ownership.zig").ownership;
pub const dead = @import("07_optimize/dead.zig").dead;

pub const effects = @import("07_optimize/effects.zig");

/// Which passes `run` applies.  Every one defaults on; turn one off to
/// bisect a miscompile down to the pass that caused it.
///
/// `dead` is not merely another optimization: it is the compactor the
/// others rely on, so turning it off leaves the pool full of orphaned
/// instructions.  That is legal MIR — the verifier only checks what a
/// block holds — and it is what makes the switches independent.
/// Constant-pool compaction is the final half of `prune`, after the
/// selected instruction passes have settled those block items.
pub const Passes = struct {
    prune: bool = true,
    ownership: bool = true,
    dead: bool = true,

    /// Everything on: what the compiler does.
    pub const all: Passes = .{};
    /// Nothing on: the raw lowering, which is what `luce ir --full`
    /// prints.
    pub const none: Passes = .{
        .prune = false,
        .ownership = false,
        .dead = false,
    };
};

/// Optimize `program` in place.  `arena` is the program's own arena:
/// scratch and rebuilt tables live there and come back with it, so the
/// artifact shrinks while the resident compiler does not.
///
/// Call on verified programs only, and verify again afterwards — the
/// driver does both (`compile.zig`).
pub fn run(arena: std.mem.Allocator, program: *mir.Program, passes: Passes) std.mem.Allocator.Error!void {
    if (passes.prune) try prune(arena, program);
    if (passes.ownership) try ownership(arena, program);
    if (passes.dead) try dead(arena, program);
    // Pool reachability is defined by the final block items, so this
    // is prune's last act and necessarily follows instruction
    // compaction.  `--full` clears `prune` and retains the raw pools.
    if (passes.prune) try prune_pass.compactConstants(arena, program);
}

test {
    _ = @import("07_optimize/dead.zig");
    _ = @import("07_optimize/effects.zig");
    _ = @import("07_optimize/ownership.zig");
    _ = @import("07_optimize/prune.zig");
    _ = @import("07_optimize/registers.zig");
    _ = @import("07_optimize/test.zig");
}
