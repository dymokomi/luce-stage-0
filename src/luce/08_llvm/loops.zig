//! Where a container's row can be read once instead of once per
//! iteration.
//!
//! Stage 10 indexes a List or an Array inline (`lower.zig`), and every access
//! begins by *resolving* the handle: load the object table's base out
//! of the runtime, step to the row, then load the row's generation,
//! its element count, and its element pointer.  Four loads before the
//! element itself, and in a loop they are the same four loads every
//! time.
//!
//! **LLVM cannot move them.**  The loop also *stores* an element, and
//! the store goes through a pointer loaded out of the row; nothing in
//! the IR says the two do not overlap, so LICM must assume the store
//! could rewrite the row it just read.  Saying otherwise means TBAA or
//! `!alias.scope`, and `std.zig.llvm.Builder` can attach metadata to a
//! branch and to nothing else.  Measured on matmul's inner loop: with
//! the resolution inside the loop, 52 ms; with it lifted out, 10 ms,
//! against 10 ms for the C twin.  It is the whole remaining gap.
//!
//! So this file finds the place to lift it to: the preheader of the
//! outermost loop that cannot disturb the answer.
//!
//! ## What is lifted, and what is not
//!
//! **The loads move; the checks stay.**  A hoisted resolution reads
//! the row without deciding anything about it — `lower.zig` reads a
//! dead all-zero row instead when the handle is null, so the loads are
//! safe unconditionally — and every access still tests the handle for
//! null and the row for the handle's own generation before it
//! touches an element.  A trap
//! therefore still fires at exactly the instruction that owes it, with
//! exactly the trace it has today, which is the property a
//! bounds-checked language cannot trade away for speed.  What the loop
//! is left with is two comparisons against loop-invariant values,
//! which LLVM's own unswitching lifts, and the bounds check, which it
//! keeps.
//!
//! ## When it is legal
//!
//! A resolution may be lifted out of a loop when **no instruction
//! anywhere in that loop can disturb it**: nothing may attach an
//! object (the table's rows are one allocation and move when it
//! grows), free one (the row's generation would move on and the row
//! could be re-occupied at once, so a check reading a stale generation
//! would miss the trap it owes), or replace a container's storage.
//! That is `optimize.effects.viewStable`, plus the one
//! refinement this stage can make and that one cannot — an
//! `index_set` whose element type owns nothing frees nothing.
//!
//! **A List is lifted under exactly that gate and needs no other.**
//! Its buffer moves under `append` and `insert` — and both, like every
//! call, are already outside `viewStable`, so a loop that could move a
//! buffer never reaches the lifting in the first place.  What is left
//! is the shape that matters: a read, a strided read, or an in-place
//! transform over a list nothing grows while it runs.
//!
//! And the local must not be *assigned* in the loop, or the handle the
//! preheader read is not the handle the body means.

const std = @import("std");
const mir = @import("../06_mir.zig");
const optimize = @import("../07_optimize.zig");
const types = @import("../support/types.zig");

const Allocator = std.mem.Allocator;

/// One resolution lifted out of a loop.
pub const Hoist = struct {
    /// The block to emit the resolution at the end of — in front of
    /// its terminator, so everything the block itself does has already
    /// happened.
    preheader: mir.BlockId,
    /// The local whose handle is resolved.
    local: mir.LocalId,
    /// The container shape it holds, from the program's heap-type
    /// table.  A List is rank 1.
    element: types.Type,
    rank: u8,
};

/// Every resolution one function can lift, and which blocks may read
/// each one.
pub const Plan = struct {
    hoists: []Hoist = &.{},
    /// Per block, the hoists whose value that block may read: the
    /// preheader itself (after it has emitted them) and every block of
    /// the loop.  There are never many, so `lower.zig` scans them.
    readable: [][]u32 = &.{},
    /// Per block, the hoists that block emits.
    emitted: [][]u32 = &.{},

    pub fn deinit(self: *Plan, gpa: Allocator) void {
        gpa.free(self.hoists);
        for (self.readable) |list| gpa.free(list);
        gpa.free(self.readable);
        for (self.emitted) |list| gpa.free(list);
        gpa.free(self.emitted);
        self.* = .{};
    }

    /// The hoist `block` may read for `local`, if there is one.
    pub fn find(self: Plan, block: mir.BlockId, local: mir.LocalId) ?u32 {
        for (self.readable[block]) |index| {
            if (self.hoists[index].local == local) return index;
        }
        return null;
    }
};

/// Plan one function's liftable resolutions.  The caller owns the
/// result and frees it with the same allocator.
pub fn plan(
    gpa: Allocator,
    program: *const mir.Program,
    function: *const mir.Function,
) Allocator.Error!Plan {
    const count = function.blocks.len;
    var made: Plan = .{};
    errdefer made.deinit(gpa);
    made.readable = try gpa.alloc([]u32, count);
    @memset(made.readable, &.{});
    made.emitted = try gpa.alloc([]u32, count);
    @memset(made.emitted, &.{});
    if (count < 2) return made;

    var graph: Graph = try .build(gpa, function);
    defer graph.deinit(gpa);

    var hoists: std.ArrayList(Hoist) = .empty;
    defer hoists.deinit(gpa);
    var readable: []std.ArrayList(u32) = try gpa.alloc(std.ArrayList(u32), count);
    defer gpa.free(readable);
    @memset(readable, .empty);
    var emitted: []std.ArrayList(u32) = try gpa.alloc(std.ArrayList(u32), count);
    defer gpa.free(emitted);
    @memset(emitted, .empty);
    defer for (readable) |*list| list.deinit(gpa);
    defer for (emitted) |*list| list.deinit(gpa);

    // Loops outermost first, so a local accessed in a nest is resolved
    // once, above the whole nest, rather than once per level.
    var loops = try graph.loops(gpa);
    defer loops.deinit(gpa);
    std.mem.sort(Loop, loops.items, {}, Loop.widestFirst);

    const wanted = try gpa.alloc(bool, function.locals.len);
    defer gpa.free(wanted);
    const assigned = try gpa.alloc(bool, function.locals.len);
    defer gpa.free(assigned);

    for (loops.items) |loop| {
        const preheader = graph.preheader(loop) orelse continue;
        // The resolution has to be emitted before it is read, and
        // stage 10 walks blocks in index order.
        if (!emittedFirst(preheader, loop)) continue;

        if (!stable(program, function, loop)) continue;

        @memset(wanted, false);
        @memset(assigned, false);
        collect(program, function, loop, wanted, assigned);

        for (wanted, assigned, 0..) |is_wanted, is_assigned, local| {
            if (!is_wanted or is_assigned) continue;
            if (madeAlready(hoists.items, readable[loop.header].items, @intCast(local))) continue;
            const shape = storedShape(program, function.locals[local].local_type) orelse continue;

            const index: u32 = @intCast(hoists.items.len);
            try hoists.append(gpa, .{
                .preheader = preheader,
                .local = @intCast(local),
                .element = shape.element,
                .rank = shape.rank,
            });
            try emitted[preheader].append(gpa, index);
            for (loop.blocks.items) |block| try readable[block].append(gpa, index);
        }
    }

    made.hoists = try gpa.dupe(Hoist, hoists.items);
    for (readable, made.readable) |*from, *into| into.* = try gpa.dupe(u32, from.items);
    for (emitted, made.emitted) |*from, *into| into.* = try gpa.dupe(u32, from.items);
    return made;
}

/// Whether the preheader is lowered before every block that reads
/// what it emits.  Stage 8 numbers blocks as it walks the source, so
/// this holds for every loop a `for` or a `while` makes; a `.lcm`
/// arriving through `decode` need not be so tidy, and one that is not
/// simply does not lift.
fn emittedFirst(preheader: mir.BlockId, loop: Loop) bool {
    for (loop.blocks.items) |block| {
        if (block <= preheader) return false;
    }
    return true;
}

fn madeAlready(hoists: []const Hoist, readable: []const u32, local: mir.LocalId) bool {
    for (readable) |index| {
        if (hoists[index].local == local) return true;
    }
    return false;
}

const Shape = struct { element: types.Type, rank: u8 };

/// The shape of the List or Array a type names — the same question
/// `lower.zig`'s `elementShape` asks, of a type rather than a
/// register, and the two must answer alike or a lifted resolution
/// would be read by an access that did not expect one.
fn storedShape(program: *const mir.Program, of: types.Type) ?Shape {
    if (of != .heap) return null;
    return switch (program.heap_types[of.heap]) {
        .array => |shape| .{ .element = shape.element, .rank = shape.rank },
        // A List has one bound and it is `count`, which is where a
        // rank-1 array's bound already comes from.
        .list => |element| .{ .element = element, .rank = 1 },
        .map, .builder, .file, .task => null,
    };
}

/// Whether nothing in `loop` can disturb a resolved row.
fn stable(program: *const mir.Program, function: *const mir.Function, loop: Loop) bool {
    for (loop.blocks.items) |block| {
        for (function.blocks[block].items) |item| {
            const instruction = function.instructions[item];
            if (optimize.effects.viewStable(instruction)) continue;
            // The one refinement this stage can make and stage 9
            // cannot: writing an element frees the element it replaced
            // (S22), and a double, a long or a String owns nothing to
            // free.  Stage 9 has the instruction but not the program's
            // heap-type table, so it answers conservatively.
            if (!writesPlainElement(program, function, instruction)) return false;
        }
    }
    return true;
}

fn writesPlainElement(
    program: *const mir.Program,
    function: *const mir.Function,
    instruction: mir.Instruction,
) bool {
    if (instruction != .intrinsic) return false;
    if (instruction.intrinsic.kind != .index_set) return false;
    const target = instruction.intrinsic.arguments[0];
    const shape = storedShape(program, function.result_types[target]) orelse return false;
    // An enum element is a number in a cell and owns nothing to free
    // (docs/ENUMS.md D9), so it joins the plain kinds by being one.
    return switch (shape.element.storage()) {
        // The storage widths join the plain kinds: a `byte`, a `short`
        // and a `half` own nothing to free, so writing one cannot
        // disturb the row a hoist resolved — which is what puts
        // `array(byte, n)` inside the vectorisation gate rather than
        // outside it (docs/TYPES.md §6).
        .boolean,
        .byte,
        .short,
        .int,
        .long,
        .half,
        .float,
        .double,
        .string,
        => true,
        .none, .strukt, .variant, .heap, .optional => false,
        .enumeration => unreachable, // answered by storage() above
        .function => unreachable, // answered by storage() above
    };
}

/// Which List and Array locals the loop reads through, and which it
/// assigns.
fn collect(
    program: *const mir.Program,
    function: *const mir.Function,
    loop: Loop,
    wanted: []bool,
    assigned: []bool,
) void {
    for (loop.blocks.items) |block| {
        for (function.blocks[block].items) |item| {
            switch (function.instructions[item]) {
                .local_set => |set| assigned[set.local] = true,
                .call_inout => |call| assigned[call.receiver] = true,
                .object_bind => |bind| assigned[bind.local] = true,
                .object_unbind => |unbind| assigned[unbind.local] = true,
                .intrinsic => |call| {
                    switch (call.kind) {
                        .index_get, .index_set, .len, .dim_size => {},
                        else => continue,
                    }
                    const target = call.arguments[0];
                    if (storedShape(program, function.result_types[target]) == null) continue;
                    // Only a handle read straight out of a local can be
                    // read again in the preheader; anything else is a
                    // value this loop computed.
                    switch (function.instructions[target]) {
                        .local_get => |local| wanted[local] = true,
                        else => {},
                    }
                },
                else => {},
            }
        }
    }
}

// ---------------------------------------------------------------------------
// The control-flow graph
// ---------------------------------------------------------------------------

const Loop = struct {
    header: mir.BlockId,
    blocks: std.ArrayList(mir.BlockId),

    fn widestFirst(_: void, left: Loop, right: Loop) bool {
        return left.blocks.items.len > right.blocks.items.len;
    }
};

const Loops = struct {
    items: []Loop,

    fn deinit(self: *Loops, gpa: Allocator) void {
        for (self.items) |*loop| loop.blocks.deinit(gpa);
        gpa.free(self.items);
        self.* = .{ .items = &.{} };
    }
};

/// A function's blocks, their edges, and which block dominates which.
const Graph = struct {
    successors: [][]mir.BlockId,
    predecessors: [][]mir.BlockId,
    /// `dominates[a * count + b]` — does block `a` dominate block `b`?
    dominates: []bool,
    count: usize,

    fn build(gpa: Allocator, function: *const mir.Function) Allocator.Error!Graph {
        const count = function.blocks.len;
        var self: Graph = .{
            .successors = try gpa.alloc([]mir.BlockId, count),
            .predecessors = try gpa.alloc([]mir.BlockId, count),
            .dominates = try gpa.alloc(bool, count * count),
            .count = count,
        };
        @memset(self.successors, &.{});
        @memset(self.predecessors, &.{});

        var edges: std.ArrayList(mir.BlockId) = .empty;
        defer edges.deinit(gpa);
        var incoming: []std.ArrayList(mir.BlockId) = try gpa.alloc(std.ArrayList(mir.BlockId), count);
        defer gpa.free(incoming);
        @memset(incoming, .empty);
        defer for (incoming) |*list| list.deinit(gpa);

        for (function.blocks, 0..) |block, index| {
            edges.clearRetainingCapacity();
            const last = block.items[block.items.len - 1];
            switch (function.instructions[last]) {
                .jump => |target| try edges.append(gpa, target),
                .branch => |taken| {
                    try edges.append(gpa, taken.then_block);
                    if (taken.else_block != taken.then_block) {
                        try edges.append(gpa, taken.else_block);
                    }
                },
                else => {},
            }
            self.successors[index] = try gpa.dupe(mir.BlockId, edges.items);
            for (edges.items) |target| try incoming[target].append(gpa, @intCast(index));
        }
        for (incoming, self.predecessors) |*from, *into| {
            into.* = try gpa.dupe(mir.BlockId, from.items);
        }

        self.findDominators();
        return self;
    }

    fn deinit(self: *Graph, gpa: Allocator) void {
        for (self.successors) |list| gpa.free(list);
        gpa.free(self.successors);
        for (self.predecessors) |list| gpa.free(list);
        gpa.free(self.predecessors);
        gpa.free(self.dominates);
        self.* = undefined;
    }

    /// The classic iterative dominator computation: everything
    /// dominates everything, then shrink by intersecting predecessors
    /// until nothing moves.  Blocks number in a reverse-postorder-ish
    /// order already (stage 8 emits them as it walks the source), so
    /// this settles in two or three sweeps.
    fn findDominators(self: *Graph) void {
        @memset(self.dominates, true);
        // Only block 0 dominates the entry.
        for (0..self.count) |candidate| {
            self.dominates[candidate * self.count] = candidate == 0;
        }
        var moved = true;
        while (moved) {
            moved = false;
            for (1..self.count) |block| {
                for (0..self.count) |candidate| {
                    const at = candidate * self.count + block;
                    if (!self.dominates[at]) continue;
                    if (candidate == block) continue;
                    // `candidate` dominates `block` only if it
                    // dominates every way in — and a block nothing
                    // reaches is dominated by nothing but itself.
                    var holds = self.predecessors[block].len > 0;
                    for (self.predecessors[block]) |from| {
                        if (!self.dominates[candidate * self.count + from]) {
                            holds = false;
                            break;
                        }
                    }
                    if (!holds) {
                        self.dominates[at] = false;
                        moved = true;
                    }
                }
            }
        }
    }

    fn dominatesBlock(self: Graph, candidate: mir.BlockId, block: mir.BlockId) bool {
        return self.dominates[@as(usize, candidate) * self.count + block];
    }

    /// Every natural loop: one per header, holding the header and
    /// everything that reaches a back edge without leaving through it.
    fn loops(self: Graph, gpa: Allocator) Allocator.Error!Loops {
        var found: std.ArrayList(Loop) = .empty;
        errdefer {
            for (found.items) |*loop| loop.blocks.deinit(gpa);
            found.deinit(gpa);
        }
        var inside = try gpa.alloc(bool, self.count);
        defer gpa.free(inside);
        var stack: std.ArrayList(mir.BlockId) = .empty;
        defer stack.deinit(gpa);

        for (0..self.count) |header| {
            @memset(inside, false);
            var latched = false;
            for (self.predecessors[header]) |latch| {
                if (!self.dominatesBlock(@intCast(header), latch)) continue;
                latched = true;
                if (!inside[latch]) {
                    inside[latch] = true;
                    try stack.append(gpa, latch);
                }
            }
            if (!latched) continue;
            inside[header] = true;
            while (stack.pop()) |block| {
                if (block == header) continue;
                for (self.predecessors[block]) |from| {
                    if (inside[from]) continue;
                    inside[from] = true;
                    try stack.append(gpa, from);
                }
            }
            var blocks: std.ArrayList(mir.BlockId) = .empty;
            errdefer blocks.deinit(gpa);
            for (inside, 0..) |is_member, block| {
                if (is_member) try blocks.append(gpa, @intCast(block));
            }
            try found.append(gpa, .{ .header = @intCast(header), .blocks = blocks });
        }
        return .{ .items = try found.toOwnedSlice(gpa) };
    }

    /// The one block outside `loop` that enters it, when there is
    /// exactly one and it enters nowhere else.  Anything less and
    /// there is no single place a resolution could go.
    fn preheader(self: Graph, loop: Loop) ?mir.BlockId {
        var only: ?mir.BlockId = null;
        for (self.predecessors[loop.header]) |from| {
            if (std.mem.indexOfScalar(mir.BlockId, loop.blocks.items, from) != null) continue;
            if (only != null) return null;
            only = from;
        }
        const found = only orelse return null;
        if (self.successors[found].len != 1) return null;
        return found;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const compile = @import("../compile.zig");
const testing = std.testing;

/// Compile `source` and plan its entry function.  A compile failure is
/// a broken test, not an outcome under test, so it fails loudly.
const Planned = struct {
    program: mir.Program,
    made: Plan,

    fn deinit(self: *Planned, gpa: Allocator) void {
        self.made.deinit(gpa);
        self.program.deinit();
    }
};

fn planned(gpa: Allocator, source: []const u8) !Planned {
    var result = try compile.compile(gpa, source, .{
        .allow_host = true,
        .source_name = "test.luc",
    });
    switch (result) {
        .success => |compiled| {
            var program = compiled;
            errdefer program.deinit();
            const made = try plan(gpa, &program, &program.functions[program.entry_function]);
            return .{ .program = program, .made = made };
        },
        .failure => |*diagnostics| {
            const rendered = try diagnostics.render(gpa);
            defer gpa.free(rendered);
            std.debug.print("unexpected compile failure:\n{s}", .{rendered});
            result.deinit();
            return error.CompileFailed;
        },
    }
}

test "a loop that only reads an array lifts its resolution to the preheader" {
    const gpa = testing.allocator;
    var built = try planned(gpa,
        \\func main():
        \\    var a = new array(double, 8)
        \\    var total: double = 0.0
        \\    for i in range(0, 8):
        \\        total = total + a[i]
        \\    print(string(long(total)))
        \\
    );
    defer built.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), built.made.hoists.len);
    const hoist = built.made.hoists[0];
    try testing.expectEqual(types.Type.double, hoist.element);
    try testing.expectEqual(@as(u8, 1), hoist.rank);
    // The preheader emits it — at the end, after everything the block
    // itself does — and the loop's blocks read it.
    try testing.expectEqual(@as(usize, 1), built.made.emitted[hoist.preheader].len);
    try testing.expectEqual(@as(?u32, null), built.made.find(hoist.preheader, hoist.local));
    var readers: usize = 0;
    for (built.made.readable) |list| readers += list.len;
    try testing.expect(readers > 0);
}

test "a loop that writes plain elements still lifts; matmul's nest lifts all three" {
    const gpa = testing.allocator;
    var built = try planned(gpa,
        \\func main():
        \\    let n = 4
        \\    var a = new array(double, n * n)
        \\    var b = new array(double, n * n)
        \\    var c = new array(double, n * n)
        \\    for i in range(0, n):
        \\        for k in range(0, n):
        \\            let pivot = a[i * n + k]
        \\            for j in range(0, n):
        \\                c[i * n + j] += pivot * b[k * n + j]
        \\    print(string(long(c[0])))
        \\
    );
    defer built.deinit(gpa);

    // One per array, all three above the whole nest rather than one
    // per loop level.
    try testing.expectEqual(@as(usize, 3), built.made.hoists.len);
    const outermost = built.made.hoists[0].preheader;
    for (built.made.hoists) |hoist| {
        try testing.expectEqual(outermost, hoist.preheader);
    }
}

test "a loop that can free, allocate, or call refuses to lift" {
    const gpa = testing.allocator;
    for ([_][]const u8{
        // A call can do anything at all.
        \\func touch(xs: array(double, _)) -> double:
        \\    return xs[0]
        \\
        \\func main():
        \\    var a = new array(double, 8)
        \\    var total: double = 0.0
        \\    for i in range(0, 8):
        \\        total = total + touch(a)
        \\    print(string(long(total)))
        \\
        ,
        // A fresh object grows the table, and the rows move with it.
        \\func main():
        \\    var a = new array(double, 8)
        \\    var total: double = 0.0
        \\    for i in range(0, 8):
        \\        var xs = new list(long)
        \\        total = total + a[i]
        \\        free(xs)
        \\    print(string(long(total)))
        \\
    }) |source| {
        var built = try planned(gpa, source);
        defer built.deinit(gpa);
        try testing.expectEqual(@as(usize, 0), built.made.hoists.len);
    }
}

test "an inner loop lifts even when the loop around it cannot" {
    const gpa = testing.allocator;
    var built = try planned(gpa,
        \\func main():
        \\    var total: double = 0.0
        \\    for r in range(0, 2):
        \\        var a = new array(double, 8)
        \\        for i in range(0, 8):
        \\            total = total + a[i]
        \\        free(a)
        \\    print(string(long(total)))
        \\
    );
    defer built.deinit(gpa);

    // The outer loop allocates and frees, so nothing lifts out of it;
    // the inner one only reads, so `a` resolves once per outer pass
    // instead of once per element.
    try testing.expectEqual(@as(usize, 1), built.made.hoists.len);
    try testing.expect(built.made.hoists[0].preheader > 0);
}

test "the reassignment guard has no way to fire from source, and is kept anyway" {
    // `a = give b` and `free(a)` inside a loop over a name declared
    // outside it are both refused by scope ownership (S21, S30), so a
    // MIR `local_set` of a live Array local cannot appear inside a loop
    // that also reads it.  `collect` checks for one all the same:
    // nothing in this file should depend on a rule enforced four stages
    // away, and a `.lcm` reaches stage 10 through `decode` without ever
    // passing the analyzer.
    const gpa = testing.allocator;
    var built = try planned(gpa,
        \\func main():
        \\    var a = new array(double, 8)
        \\    var total: double = 0.0
        \\    for i in range(0, 8):
        \\        total = total + a[i]
        \\    print(string(long(total)))
        \\
    );
    defer built.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), built.made.hoists.len);
}
