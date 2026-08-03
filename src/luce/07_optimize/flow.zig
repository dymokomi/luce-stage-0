//! Control-flow simplification: thread jumps through forwarding
//! blocks, merge a block into its only predecessor, and drop what
//! nothing reaches.
//!
//! **What it buys.**  A block boundary is the most expensive thing the
//! interpreter does.  Every other instruction reads a register and
//! writes one; a `jump` costs a dispatch step *and* sends the loop
//! back through `continue :dispatch`, which re-derives the frame, the
//! function, the register window, the local window, and the item list,
//! because pushing a frame may have moved the storage underneath it
//! (`interpreter/machine.zig`).  Lowering `for i in 0..n:` leaves one
//! forwarding block per loop exit and one increment block per loop
//! body, so the cost lands squarely inside loops.
//!
//! **Why LLVM does not make this redundant.**  For the *compiled* path
//! it does: `simplifycfg` runs several times in `default<O2>`, and
//! this pass buys that path nothing.  Two things keep it here anyway.
//! The interpreter gets nothing from LLVM — measured, this pass is
//! about 2% of its time on the scalar benchmarks — and unreachable
//! blocks are *instructions in the artifact*: LLVM never sees the
//! `.lc`, so nothing else will ever drop a block the entry cannot
//! reach, and the interpreter sizes every frame at one slot per
//! instruction in the pool whether it can run or not.  Over
//! `programs/` and `bench/` this drops 830 blocks to 747.
//!
//! **Three rewrites to a fixed point:**
//!
//!   * *threading* — a terminator that targets a block whose only
//!     instruction is `jump T` targets T instead.  Bounded by the
//!     block count so a ring of empty blocks cannot spin.
//!   * *merging* — a block whose single predecessor ends in an
//!     unconditional jump to it is appended to that predecessor,
//!     jump and all.  Legal without renaming anything: MIR registers
//!     never cross a block, so the two definition sets are disjoint
//!     and concatenating them keeps every operand defined above its
//!     use.  The entry block is never merged away, so block 0 stays
//!     the entry.
//!   * *pruning* — blocks nothing reaches are dropped, and the rest
//!     renumbered densely.
//!
//! Merging is also what makes `values.zig` worth more than it looks:
//! two blocks that each read the same local become one block in which
//! the second read is redundant.

const std = @import("std");
const defs = @import("../06_mir/defs.zig");

const Allocator = std.mem.Allocator;
const BlockId = defs.BlockId;
const Block = defs.Block;
const Function = defs.Function;
const Program = defs.Program;

/// Simplify the control-flow graph of every function.
pub fn flow(arena: Allocator, program: *Program) Allocator.Error!void {
    for (program.functions) |*function| try simplify(arena, function);
}

fn simplify(arena: Allocator, function: *Function) Allocator.Error!void {
    const count = function.blocks.len;
    if (count == 0) return;

    const reachable = try arena.alloc(bool, count);
    const touched = try arena.alloc(bool, count);
    const predecessors = try arena.alloc(u32, count);

    // Each round can only shorten the graph, and each rewrite removes
    // at least one block, so `count` rounds is a ceiling and not a
    // heuristic.  The extra one lets the loop notice it is done.
    var rounds: usize = 0;
    while (rounds <= count) : (rounds += 1) {
        markReachable(function, reachable);
        var changed = thread(function, reachable);
        if (try mergeSingleSuccessors(arena, function, reachable, predecessors, touched)) changed = true;
        if (!changed) break;
    }

    markReachable(function, reachable);
    try renumber(arena, function, reachable);
}

/// Which blocks the entry can get to.
fn markReachable(function: *const Function, reachable: []bool) void {
    @memset(reachable, false);
    reachable[0] = true;
    // The graph is small and this runs a handful of times per
    // function: sweep to a fixed point rather than keep a worklist.
    var again = true;
    while (again) {
        again = false;
        for (function.blocks, 0..) |block, index| {
            if (!reachable[index]) continue;
            var edges: [2]BlockId = undefined;
            for (successors(function, block, &edges)) |target| {
                if (reachable[target]) continue;
                reachable[target] = true;
                again = true;
            }
        }
    }
}

fn successors(function: *const Function, block: Block, into: *[2]BlockId) []BlockId {
    return switch (function.instructions[block.items[block.items.len - 1]]) {
        .jump => |target| blk: {
            into[0] = target;
            break :blk into[0..1];
        },
        .branch => |taken| blk: {
            into[0] = taken.then_block;
            into[1] = taken.else_block;
            break :blk into[0..2];
        },
        else => into[0..0],
    };
}

/// Retarget every edge that lands on a block which does nothing but
/// jump somewhere else.
fn thread(function: *Function, reachable: []const bool) bool {
    var changed = false;
    for (function.blocks, 0..) |block, index| {
        if (!reachable[index]) continue;
        const terminator = &function.instructions[block.items[block.items.len - 1]];
        switch (terminator.*) {
            .jump => |target| {
                const settled = follow(function, target);
                if (settled == target) continue;
                terminator.* = .{ .jump = settled };
                changed = true;
            },
            .branch => |taken| {
                const then_block = follow(function, taken.then_block);
                const else_block = follow(function, taken.else_block);
                if (then_block == taken.then_block and else_block == taken.else_block) continue;
                terminator.* = .{ .branch = .{
                    .condition = taken.condition,
                    .then_block = then_block,
                    .else_block = else_block,
                } };
                changed = true;
            },
            else => {},
        }
    }
    return changed;
}

/// Walk a chain of forwarding blocks to whatever it really reaches.
fn follow(function: *const Function, start: BlockId) BlockId {
    var target = start;
    var steps: usize = 0;
    while (steps <= function.blocks.len) : (steps += 1) {
        const block = function.blocks[target];
        if (block.items.len != 1) return target;
        const next = switch (function.instructions[block.items[0]]) {
            .jump => |onwards| onwards,
            else => return target,
        };
        if (next == target) return target;
        target = next;
    }
    return target;
}

/// Append every block that has exactly one way in — an unconditional
/// jump — to the block it comes from.
fn mergeSingleSuccessors(
    arena: Allocator,
    function: *Function,
    reachable: []const bool,
    predecessors: []u32,
    touched: []bool,
) Allocator.Error!bool {
    @memset(predecessors, 0);
    @memset(touched, false);
    for (function.blocks, 0..) |block, index| {
        if (!reachable[index]) continue;
        var edges: [2]BlockId = undefined;
        for (successors(function, block, &edges)) |target| predecessors[target] += 1;
    }

    var changed = false;
    for (function.blocks, 0..) |block, index| {
        // Never the entry: block 0 is the entry by position, so
        // folding it into something else would move the entry.
        if (index == 0 or !reachable[index] or touched[index]) continue;
        if (predecessors[index] != 1) continue;
        const from = onlyPredecessor(function, reachable, @intCast(index)) orelse continue;
        if (from == index or touched[from]) continue;
        const source = function.blocks[from];
        if (function.instructions[source.items[source.items.len - 1]] != .jump) continue;

        // The jump between the two disappears with the boundary.
        const merged = try arena.alloc(defs.Register, source.items.len - 1 + block.items.len);
        @memcpy(merged[0 .. source.items.len - 1], source.items[0 .. source.items.len - 1]);
        @memcpy(merged[source.items.len - 1 ..], block.items);
        function.blocks[from].items = merged;
        // `index` keeps its items, but nothing reaches it any more, so
        // the next reachability sweep drops it and the pool compactor
        // never sees the duplicate.
        touched[from] = true;
        touched[index] = true;
        changed = true;
    }
    return changed;
}

fn onlyPredecessor(function: *const Function, reachable: []const bool, of: BlockId) ?BlockId {
    for (function.blocks, 0..) |block, index| {
        if (!reachable[index]) continue;
        var edges: [2]BlockId = undefined;
        for (successors(function, block, &edges)) |target| {
            if (target == of) return @intCast(index);
        }
    }
    return null;
}

/// Drop unreachable blocks and renumber the rest densely, entry first.
fn renumber(arena: Allocator, function: *Function, reachable: []const bool) Allocator.Error!void {
    var kept: u32 = 0;
    for (reachable) |live| {
        if (live) kept += 1;
    }
    if (kept == function.blocks.len) return;

    const moved = try arena.alloc(BlockId, function.blocks.len);
    var next: BlockId = 0;
    for (reachable, moved) |live, *slot| {
        if (!live) continue;
        slot.* = next;
        next += 1;
    }

    const blocks = try arena.alloc(Block, kept);
    for (function.blocks, 0..) |block, index| {
        if (!reachable[index]) continue;
        const terminator = &function.instructions[block.items[block.items.len - 1]];
        switch (terminator.*) {
            .jump => |target| terminator.* = .{ .jump = moved[target] },
            .branch => |taken| terminator.* = .{ .branch = .{
                .condition = taken.condition,
                .then_block = moved[taken.then_block],
                .else_block = moved[taken.else_block],
            } },
            else => {},
        }
        blocks[moved[index]] = block;
    }
    function.blocks = blocks;
}
