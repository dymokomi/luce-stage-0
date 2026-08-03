//! Stage 7 — MIR optimization.  MIR in, MIR out.
//!
//! Consumes: a verified `mir.Program`.
//! Produces: the same program, smaller.  The stage runs in place and
//! the result is re-verified, so an optimization that breaks an
//! invariant is an internal compiler error rather than a miscompile.
//!
//! ## What this stage is for, and what it is emphatically not for
//!
//! Not for scalar optimization.  `luce build --emit=exe` hands the
//! program to `default<O3>`, which folds constants, inlines, does GVN
//! and LICM and loop rotation and dead-store elimination, and — via
//! `constraint-elimination` — bounds-check elimination, all better than
//! anything written here would.  A pass that duplicates `default<O3>`
//! costs compile time to be slower than what we already have.
//!
//! Nor is this where the container gap gets closed.  Luce's matmul is
//! ~41x C, and the decomposition of that number is a *lowering*
//! problem, not an optimization one: an opaque `luce_rt_index_get` call
//! per element is 14.6x of it, object-table/element aliasing another
//! 1.8x, boxed elements another 1.6x.  The fix is stage 8 emitting an
//! inline specialized access instead of a call, and it is not
//! expressible here at all — MIR has no load, no GEP, and no pointer.
//! Rewriting `index_get` into a typed `array_get_float` would give the
//! interpreter nothing (it would dispatch to the same runtime
//! function) and cost a `format_version` bump.  Do not.
//!
//! What is left is narrow, and this stage should stay small:
//!
//!  1. **What LLVM structurally cannot see.**  Ownership is two opaque
//!     `luce_rt_*` calls that LLVM must assume read and write the
//!     world; MIR names them, knows the owner field is one field, and
//!     can prove a store to it dead.  That is the one pass here with an
//!     argument nothing downstream can replace.
//!  2. **Making the artifact smaller.**  The `.lc` is the interpreter's
//!     executable and LLVM never sees it.  Nothing downstream will ever
//!     remove a block the entry cannot reach, or an instruction no
//!     block holds — and the interpreter sizes *every frame* at one
//!     slot per pool entry, reachable or not.
//!  3. **Whatever measurably helps the interpreter**, which is the
//!     reference engine and what `loom run` executes today.  This one
//!     is a claim about numbers, not about principle, and the numbers
//!     are below.  If the interpreter stops being a shipping engine,
//!     `Passes.values` and `Passes.flow` should go off and then away.
//!
//! ## What runs, and what each one measured
//!
//! `run` applies them in this order, and `Passes` turns each one off by
//! itself so a bisect can name the one that broke something.
//!
//!   prune.zig     — drop functions the entry cannot reach.  `import
//!                   std.strings` then one call: 26 functions become 2.
//!   flow.zig      — thread jumps through forwarding blocks, merge a
//!                   block into its only predecessor, drop what nothing
//!                   reaches.  Runs first because merging gives the
//!                   next pass longer blocks to work in.
//!   values.zig    — block-local value numbering: store-to-load
//!                   forwarding for locals, then CSE of everything
//!                   deterministic.
//!   ownership.zig — delete `object_bind`s a later bind overwrites and
//!                   `object_unbind`s that provably free nothing.
//!   dead.zig      — sweep instructions nothing reads, then compact the
//!                   instruction pool.  Must run last: every pass above
//!                   leaves orphans on purpose rather than renumber.
//!
//! Over the fourteen bundled programs and benchmarks, cumulative,
//! against `prune` alone (which is where this stage started):
//!
//! ```text
//!                     instructions   blocks   .lc bytes
//!   prune only               5178       830      137755
//!   + dead                   5174       830           .   sweeps almost
//!   + flow                   5091       747           .   nothing; it is
//!   + values                 4546       747           .   the compactor
//!   + ownership              4498       747      121659
//!                          -13.1%    -10.0%      -11.7%
//! ```
//!
//! Interpreter, same-host interleaved A/B, best of four (`loops`,
//! `math`, `matmul` scaled to ~0.5 s): **-8.7%, -7.2%, -5.9%**.  On the
//! allocation-bound benchmarks (`strings`, `sort`) it is within noise —
//! those programs are in the runtime, not the dispatch loop.  LLVM
//! compile time over eight programs: **-2.5%**, which is small enough
//! to be worth nothing on its own; the compiled path's *runtime* is
//! unchanged, as it should be, because `default<O3>` had already found
//! everything `flow` and `values` find.
//!
//! So: `ownership` earns its place on an argument.  `flow` and `values`
//! earn theirs on a measurement, and only for the interpreter.  `dead`
//! is not really an optimization at all — it is the compactor the other
//! four rely on, and its own sweep finds four instructions in the whole
//! corpus.
//!
//! ## The line none of them may cross
//!
//! A program's behaviour is identical afterwards, down to the trap's
//! *source location*.  Nothing that can trap is ever deleted (only
//! `pure` instructions go), nothing is reordered, and CSE cannot move
//! a trap either: it folds a duplicate onto an earlier instruction with
//! the same operands, and if the duplicate would have trapped the
//! earlier one already did, at its own line.  Origins travel with their
//! instructions through compaction, so a debug build still reports
//! `file:line:column` from the same place.  `test.zig` runs optimized
//! against unoptimized output — printed bytes, trap code, trap message,
//! and objects left alive — over hand-written ownership cases and 400
//! generated programs, and every spec in `specs/` already compiles with
//! this stage on.
//!
//! ## What deliberately does not run, and why
//!
//! *Constant folding, inlining, LICM, loop unrolling, strength
//! reduction, bounds-check elimination.*  `default<O3>`'s job, and
//! `constraint-elimination` already does the last one.  Stage 4 folds
//! the constants it needs to type-check, and what it leaves behind is a
//! rounding error: two dead pure instructions in the whole corpus.
//!
//! *Typed container instructions* (`array_get_float` and friends).  The
//! 41x is real and this is not the lever; see above.
//!
//! *CSE of container reads* — `len` of a list nothing has touched,
//! `index_get` with the same index twice.  This one would be genuinely
//! ours, and it still does not pay: every candidate needs a mutation
//! barrier, and a scan of `programs/` and `bench/` finds *zero* pairs
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
//!                   duplicates, or deletes anything.  Also the shape
//!                   stage 8 reads to attribute its `luce_rt_*`
//!                   externals.
//!   registers.zig — where an instruction keeps its register operands,
//!                   written once so no rewrite can miss one.
//!   prune.zig, flow.zig, values.zig, ownership.zig, dead.zig — the
//!                   passes, each with its own header arguing for
//!                   itself.
//!   test.zig      — the stage's own proofs, including the fuzz that
//!                   runs optimized against unoptimized output.

const std = @import("std");
const mir = @import("06_mir.zig");

pub const prune = @import("07_optimize/prune.zig").prune;
pub const flow = @import("07_optimize/flow.zig").flow;
pub const values = @import("07_optimize/values.zig").values;
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
pub const Passes = struct {
    prune: bool = true,
    flow: bool = true,
    values: bool = true,
    ownership: bool = true,
    dead: bool = true,

    /// Everything on: what the compiler does.
    pub const all: Passes = .{};
    /// Nothing on: the raw lowering, which is what `luce ir --full`
    /// prints.
    pub const none: Passes = .{
        .prune = false,
        .flow = false,
        .values = false,
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
    if (passes.flow) try flow(arena, program);
    if (passes.values) try values(arena, program);
    if (passes.ownership) try ownership(arena, program);
    if (passes.dead) try dead(arena, program);
}

test {
    _ = @import("07_optimize/dead.zig");
    _ = @import("07_optimize/effects.zig");
    _ = @import("07_optimize/flow.zig");
    _ = @import("07_optimize/ownership.zig");
    _ = @import("07_optimize/prune.zig");
    _ = @import("07_optimize/registers.zig");
    _ = @import("07_optimize/test.zig");
    _ = @import("07_optimize/values.zig");
}
