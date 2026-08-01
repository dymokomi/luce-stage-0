//! Loop analysis over the verified IR: dominators, back edges, and
//! natural loops.  A read-only view a code generator consults to
//! hoist loop-invariant work; it changes nothing in the IR.
//!
//! Functions are small (a handful of blocks), so the dominator
//! computation is the plain iterative fixpoint over boolean sets —
//! clear over clever, and fast enough that it never shows up.

const std = @import("std");
const ir = @import("ir.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const BlockId = ir.BlockId;

/// One natural loop: a header a back edge returns to, the blocks it
/// contains, the latch (the back edge's source), and — when the
/// header has exactly one predecessor from outside the loop — the
/// pre-header to hoist into.  `preheader` is null when the entry is
/// ambiguous (multiple outside predecessors); hoisting then declines.
pub const Loop = struct {
    header: BlockId,
    latch: BlockId,
    blocks: []const BlockId,
    preheader: ?BlockId,

    pub fn contains(self: Loop, block: BlockId) bool {
        for (self.blocks) |member| {
            if (member == block) return true;
        }
        return false;
    }
};

/// The successors of a block, from its terminator (the last item).
fn successors(function: *const ir.Function, block: BlockId, buffer: *[2]BlockId) []const BlockId {
    const items = function.blocks[block].items;
    const terminator = function.instructions[items[items.len - 1]];
    switch (terminator) {
        .jump => |target| {
            buffer[0] = target;
            return buffer[0..1];
        },
        .branch => |branch| {
            buffer[0] = branch.then_block;
            buffer[1] = branch.else_block;
            return buffer[0..2];
        },
        else => return buffer[0..0], // ret, trap
    }
}

/// Every block's predecessor list.
fn predecessors(arena: Allocator, function: *const ir.Function) Allocator.Error![][]BlockId {
    const count = function.blocks.len;
    var lists = try arena.alloc(std.ArrayList(BlockId), count);
    for (lists) |*list| list.* = .empty;
    for (0..count) |b| {
        var buffer: [2]BlockId = undefined;
        for (successors(function, @intCast(b), &buffer)) |s| {
            try lists[s].append(arena, @intCast(b));
        }
    }
    const result = try arena.alloc([]BlockId, count);
    for (lists, result) |*list, *out| out.* = list.items;
    return result;
}

/// dominators[b][d] is true when d dominates b.  Iterative fixpoint:
/// a block is dominated by itself and by everything that dominates
/// all its predecessors.
fn dominators(arena: Allocator, function: *const ir.Function, preds: [][]BlockId) Allocator.Error![][]bool {
    const count = function.blocks.len;
    const dom = try arena.alloc([]bool, count);
    for (dom) |*row| {
        row.* = try arena.alloc(bool, count);
        @memset(row.*, true); // everything dominates everything, to start
    }
    // The entry is dominated only by itself.
    @memset(dom[0], false);
    dom[0][0] = true;

    const scratch = try arena.alloc(bool, count);
    var changed = true;
    while (changed) {
        changed = false;
        for (1..count) |b| {
            @memset(scratch, true);
            for (preds[b]) |p| {
                for (0..count) |d| scratch[d] = scratch[d] and dom[p][d];
            }
            scratch[b] = true; // a block always dominates itself
            if (preds[b].len == 0) @memset(scratch, false); // unreachable
            scratch[b] = true;
            if (!std.mem.eql(bool, dom[b], scratch)) {
                @memcpy(dom[b], scratch);
                changed = true;
            }
        }
    }
    return dom;
}

/// A dominator relation and the natural loops, computed together.
pub const Analysis = struct {
    dom: [][]bool,
    loops: []Loop,

    pub fn dominates(self: Analysis, a: BlockId, b: BlockId) bool {
        return self.dom[b][a]; // a dominates b
    }
};

/// The natural loops of a function, in no particular order.  Each
/// arises from a back edge b -> h where h dominates b; its body is h
/// plus every block that reaches b without passing through h.
pub fn analyze(arena: Allocator, function: *const ir.Function) Allocator.Error![]Loop {
    const preds = try predecessors(arena, function);
    const dom = try dominators(arena, function, preds);
    return naturalLoops(arena, function, preds, dom);
}

fn naturalLoops(arena: Allocator, function: *const ir.Function, preds: [][]BlockId, dom: [][]bool) Allocator.Error![]Loop {
    const count = function.blocks.len;
    var loops: std.ArrayList(Loop) = .empty;
    for (0..count) |b| {
        var buffer: [2]BlockId = undefined;
        for (successors(function, @intCast(b), &buffer)) |h| {
            if (!dom[b][h]) continue; // not a back edge

            // Natural loop body: h, plus everything reaching b
            // backwards without crossing h.
            const in_loop = try arena.alloc(bool, count);
            @memset(in_loop, false);
            in_loop[h] = true;
            var stack: std.ArrayList(BlockId) = .empty;
            if (b != h) {
                in_loop[b] = true;
                try stack.append(arena, @intCast(b));
            }
            while (stack.pop()) |node| {
                for (preds[node]) |p| {
                    if (!in_loop[p]) {
                        in_loop[p] = true;
                        try stack.append(arena, p);
                    }
                }
            }

            var members: std.ArrayList(BlockId) = .empty;
            for (0..count) |i| {
                if (in_loop[i]) try members.append(arena, @intCast(i));
            }

            // The pre-header: the header's predecessor(s) outside the
            // loop.  Exactly one makes a clean hoist point.
            var preheader: ?BlockId = null;
            var outside: usize = 0;
            for (preds[h]) |p| {
                if (!in_loop[p]) {
                    outside += 1;
                    preheader = p;
                }
            }
            if (outside != 1) preheader = null;

            try loops.append(arena, .{
                .header = @intCast(h),
                .latch = @intCast(b),
                .blocks = members.items,
                .preheader = preheader,
            });
        }
    }
    return loops.items;
}

/// Loops plus the dominator relation, for callers that need both.
pub fn analyzeFull(arena: Allocator, function: *const ir.Function) Allocator.Error!Analysis {
    const preds = try predecessors(arena, function);
    const dom = try dominators(arena, function, preds);
    const found = try naturalLoops(arena, function, preds, dom);
    return .{ .dom = dom, .loops = found };
}

/// Array locals whose element storage and length are safe to keep in
/// registers across their whole live range — so index access needs
/// no per-use null/alive check and no per-use field reload.  The
/// sound conditions: the local has exactly one definition, a
/// `new Array(...)` (never null, born alive), that definition
/// dominates every use (so no use can read the null zero value), and
/// the object is never freed or given away (which could invalidate
/// the cached fields).  A trailing scope-exit unbind is fine — it
/// runs after the last use.
pub fn hoistableArrays(arena: Allocator, program: *const ir.Program, function: *const ir.Function) Allocator.Error![]ir.LocalId {
    const analysis = try analyzeFull(arena, function);
    var result: std.ArrayList(ir.LocalId) = .empty;

    // Which block each instruction lives in (for the dominance test).
    const block_of = try arena.alloc(BlockId, function.instructions.len);
    for (function.blocks, 0..) |block, b| {
        for (block.items) |item| block_of[item] = @intCast(b);
    }

    local: for (function.locals, 0..) |local, li| {
        const local_index: ir.LocalId = @intCast(li);
        switch (local.local_type) {
            .heap => |heap| switch (program.heap_types[heap]) {
                .array => {},
                else => continue :local,
            },
            else => continue :local,
        }

        var def_count: usize = 0;
        var def_block: BlockId = 0;
        var uses: std.ArrayList(BlockId) = .empty;
        // Registers that read this local; an index access on one of
        // them is what makes caching the fields worthwhile.
        const reads_local = try arena.alloc(bool, function.instructions.len);
        @memset(reads_local, false);
        var indexed = false;
        for (function.instructions, 0..) |instruction, ii| {
            switch (instruction) {
                .local_set => |set| if (set.local == local_index) {
                    def_count += 1;
                    // The defining value must be a fresh array.
                    if (function.instructions[set.value] != .heap_new) continue :local;
                    def_block = block_of[@intCast(ii)];
                },
                .local_get => |got| if (got == local_index) {
                    try uses.append(arena, block_of[@intCast(ii)]);
                    reads_local[ii] = true;
                },
                // A free or give could invalidate the cached fields.
                .intrinsic => |call| switch (call.kind) {
                    .free_object, .give_object => {
                        for (call.arguments) |arg| {
                            if (function.instructions[arg] == .local_get and
                                function.instructions[arg].local_get == local_index) continue :local;
                        }
                    },
                    .index_get, .index_set => {
                        if (reads_local[call.arguments[0]]) indexed = true;
                    },
                    else => {},
                },
                else => {},
            }
        }
        if (def_count != 1) continue :local;
        if (!indexed) continue :local; // nothing to gain caching an unindexed array
        // The single definition must dominate every use's block.
        for (uses.items) |use_block| {
            if (!analysis.dominates(def_block, use_block)) continue :local;
        }
        try result.append(arena, local_index);
    }
    return result.items;
}

// ---------------------------------------------------------------------------
// Tests — hand-built CFGs; the analysis is proven here in isolation,
// then consulted by the code generators.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Build a function that is just a control-flow skeleton: each block's
/// terminator is the given jump/branch, no real instructions.  Enough
/// to test dominators and loops without the whole compiler.
fn skeleton(arena: Allocator, terminators: []const ir.Instruction) !ir.Function {
    const count = terminators.len;
    const instructions = try arena.dupe(ir.Instruction, terminators);
    const result_types = try arena.alloc(types.Type, count);
    @memset(result_types, .none);
    const blocks = try arena.alloc(ir.Block, count);
    for (blocks, 0..) |*block, i| {
        const items = try arena.alloc(ir.Register, 1);
        items[0] = @intCast(i); // the block's single item is its terminator
        block.* = .{ .items = items };
    }
    return .{
        .name = "test",
        .parameter_count = 0,
        .return_type = .none,
        .locals = &.{},
        .instructions = instructions,
        .result_types = result_types,
        .blocks = blocks,
    };
}

test "a single counted loop is found with its body and pre-header" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // b0 -> b1 (header) -> {b2 body -> b1 back edge, b3 exit}
    var function = try skeleton(a, &.{
        .{ .jump = 1 }, // b0 pre-header
        .{ .branch = .{ .condition = 0, .then_block = 2, .else_block = 3 } }, // b1 header
        .{ .jump = 1 }, // b2 body -> back edge
        .{ .ret = null }, // b3 exit
    });
    const loops = try loops_analyze(a, &function);
    try testing.expectEqual(@as(usize, 1), loops.len);
    try testing.expectEqual(@as(BlockId, 1), loops[0].header);
    try testing.expectEqual(@as(BlockId, 2), loops[0].latch);
    try testing.expectEqual(@as(?BlockId, 0), loops[0].preheader);
    try testing.expect(loops[0].contains(1));
    try testing.expect(loops[0].contains(2));
    try testing.expect(!loops[0].contains(3));
}

test "nested loops each surface with the inner body a subset" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // b0 -> b1 outer header -> b2 inner header -> {b3 inner body -> b2,
    // and b2 -> b4 outer latch -> b1, b1 -> b5 exit}
    var function = try skeleton(a, &.{
        .{ .jump = 1 }, // b0
        .{ .branch = .{ .condition = 0, .then_block = 2, .else_block = 5 } }, // b1 outer header
        .{ .branch = .{ .condition = 0, .then_block = 3, .else_block = 4 } }, // b2 inner header
        .{ .jump = 2 }, // b3 inner body -> inner back edge
        .{ .jump = 1 }, // b4 outer latch -> outer back edge
        .{ .ret = null }, // b5 exit
    });
    const loops = try loops_analyze(a, &function);
    try testing.expectEqual(@as(usize, 2), loops.len);
    var inner: ?Loop = null;
    var outer: ?Loop = null;
    for (loops) |loop| {
        if (loop.header == 2) inner = loop;
        if (loop.header == 1) outer = loop;
    }
    try testing.expect(inner != null and outer != null);
    // The inner body is {b2, b3}; the outer contains everything the
    // inner does plus b1 and b4.
    try testing.expect(inner.?.contains(2) and inner.?.contains(3));
    try testing.expect(!inner.?.contains(1));
    try testing.expect(outer.?.contains(1) and outer.?.contains(2) and
        outer.?.contains(3) and outer.?.contains(4));
}

test "an acyclic function has no loops" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var function = try skeleton(a, &.{
        .{ .branch = .{ .condition = 0, .then_block = 1, .else_block = 2 } },
        .{ .jump = 3 },
        .{ .jump = 3 },
        .{ .ret = null },
    });
    const loops = try loops_analyze(a, &function);
    try testing.expectEqual(@as(usize, 0), loops.len);
}

/// Local alias so the tests read `loops_analyze` rather than shadowing
/// the module name `analyze` inside a test file that also imports it.
const loops_analyze = analyze;

const compile_mod = @import("compile.zig");

test "hoistableArrays finds a fresh, unfreed array used in a loop" {
    var result = try compile_mod.compile(testing.allocator,
        \\func main():
        \\    let n = 8
        \\    var a = new Array(Int, n)
        \\    var b = new Array(Int, n)
        \\    var total = 0
        \\    for i in range(0, n):
        \\        a[i] = i
        \\        total += a[i] * b[i]
        \\    print(str(total))
        \\
    , .{}, .{ .entry_mode = .script, .allow_host = true });
    defer result.deinit();
    try testing.expect(result == .success);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const program = &result.success;
    const hoistable = try hoistableArrays(arena.allocator(), program, &program.functions[program.entry_function]);
    // Both a and b qualify: fresh arrays, never freed, def dominates use.
    try testing.expectEqual(@as(usize, 2), hoistable.len);
}

test "an array freed inside its scope is not hoistable" {
    var result = try compile_mod.compile(testing.allocator,
        \\func main():
        \\    var a = new Array(Int, 4)
        \\    a[0] = 1
        \\    print(str(a[0]))
        \\    free(a)
        \\
    , .{}, .{ .entry_mode = .script, .allow_host = true });
    defer result.deinit();
    try testing.expect(result == .success);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const program = &result.success;
    const hoistable = try hoistableArrays(arena.allocator(), program, &program.functions[program.entry_function]);
    try testing.expectEqual(@as(usize, 0), hoistable.len);
}
