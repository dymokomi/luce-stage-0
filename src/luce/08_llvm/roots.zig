//! Which heap-valued MIR registers may name a program-root constant.
//!
//! Inline List and Array writes bypass `Runtime.resolveMutable`, so
//! `lower.zig` has to retain its `immutable_object` check whenever the
//! receiver might have arrived from `const_container`.  Carrying a
//! trusted bit in MIR would make a decoded module able to forge that
//! answer.  This pass instead derives it from the final, verified MIR
//! which LLVM is about to lower.
//!
//! The lattice is deliberately one-sided: `true` means "may be a
//! program root", and facts only move from false to true.  Parameters,
//! inout slots and every heap-producing instruction except `heap_new`
//! begin true.  A new heap row and a non-parameter local's null default
//! begin false; every `local_set` is then joined to a fixed point.  A
//! local is therefore considered non-root only when every value which
//! can reach it is proven non-root, including assignments around loops.
//!
//! This proof stays valid after the register is produced: the constants
//! prologue is the only operation which changes an ordinary row's owner
//! to `.program`, and it finishes before any Luce function executes.

const std = @import("std");
const mir = @import("../06_mir.zig");
const types = @import("../support/types.zig");

const Allocator = std.mem.Allocator;

/// Root reachability for every register in one function.
pub const Plan = struct {
    facts: []bool = &.{},
    register_at: u32 = 0,

    pub fn deinit(self: *Plan, gpa: Allocator) void {
        gpa.free(self.facts);
        self.* = .{};
    }

    /// Whether omitting the runtime's program-owner check would be
    /// unsound for `register`.
    pub fn mayProgramRoot(self: Plan, register: mir.Register) bool {
        return self.facts[self.register_at + register];
    }
};

/// Derive root reachability from exactly the function LLVM will lower.
pub fn plan(gpa: Allocator, function: *const mir.Function) Allocator.Error!Plan {
    // The serialized-module verifier caps both tables far below u32.
    // Keeping node IDs at that width halves the scratch footprint for
    // the largest valid decoded input.
    const register_at: u32 = @intCast(function.locals.len);
    const node_count = function.locals.len + function.instructions.len;

    // A flat CSR graph: `local_get` contributes local -> register and
    // `local_set` contributes register -> local.  Building it takes two
    // linear passes, and the worklist below visits each node and edge at
    // most once.  An adversarial valid module therefore cannot turn the
    // root proof into a repeated whole-function scan.
    const offsets = try gpa.alloc(u32, node_count + 1);
    defer gpa.free(offsets);
    @memset(offsets, 0);
    var edge_count: u32 = 0;
    for (function.instructions, 0..) |instruction, register| {
        if (propagationEdge(function, instruction, @intCast(register), register_at)) |edge| {
            offsets[edge.from + 1] += 1;
            edge_count += 1;
        }
    }
    for (offsets[1..], offsets[0 .. offsets.len - 1]) |*current, previous| {
        current.* += previous;
    }

    const edges = try gpa.alloc(u32, edge_count);
    defer gpa.free(edges);
    const next = try gpa.dupe(u32, offsets[0..node_count]);
    defer gpa.free(next);
    for (function.instructions, 0..) |instruction, register| {
        if (propagationEdge(function, instruction, @intCast(register), register_at)) |edge| {
            edges[next[edge.from]] = edge.to;
            next[edge.from] += 1;
        }
    }

    const facts = try gpa.alloc(bool, node_count);
    errdefer gpa.free(facts);
    @memset(facts, false);
    var worklist: std.ArrayList(u32) = .empty;
    defer worklist.deinit(gpa);

    for (function.locals, 0..) |local, index| {
        if (local.local_type != .heap) continue;
        if (index < function.parameter_count or local.inout) {
            try mark(facts, &worklist, @intCast(index), gpa);
        }
    }

    // Seed everything whose contract does not prove that it creates a
    // new row.  `local_get` is filled through the graph above.
    for (function.instructions, function.result_types, 0..) |instruction, result_type, register| {
        if (result_type == .heap and startsMayRoot(instruction)) {
            try mark(facts, &worklist, register_at + @as(u32, @intCast(register)), gpa);
        }
        if (inoutSeed(function, instruction)) |local| {
            try mark(facts, &worklist, local, gpa);
        }
    }

    var read: usize = 0;
    while (read < worklist.items.len) : (read += 1) {
        const from = worklist.items[read];
        for (edges[offsets[from]..offsets[from + 1]]) |to| {
            if (!facts[to]) {
                facts[to] = true;
                try worklist.append(gpa, to);
            }
        }
    }

    return .{ .facts = facts, .register_at = register_at };
}

const Edge = struct { from: u32, to: u32 };

fn propagationEdge(
    function: *const mir.Function,
    instruction: mir.Instruction,
    register: mir.Register,
    register_at: u32,
) ?Edge {
    return switch (instruction) {
        .local_get => |local| if (function.result_types[register] == .heap)
            .{ .from = local, .to = register_at + register }
        else
            null,
        .local_set => |set| if (function.locals[set.local].local_type == .heap)
            .{ .from = register_at + set.value, .to = set.local }
        else
            null,
        .const_boolean,
        .const_long,
        .const_double,
        .const_string,
        .const_container,
        .const_function,
        .binary,
        .unary,
        .convert,
        .struct_make,
        .struct_get,
        .struct_set,
        .variant_make,
        .variant_tag,
        .variant_field,
        .call,
        .call_inout,
        .spawn,
        .call_indirect,
        .intrinsic,
        .heap_new,
        .object_bind,
        .object_unbind,
        .jump,
        .branch,
        .ret,
        .trap,
        .unwind,
        => null,
    };
}

/// Whether a heap result must begin at the conservative top of the
/// lattice.  Exhaustive on purpose: a new instruction cannot silently
/// acquire permission to skip the immutable-row guard.
fn startsMayRoot(instruction: mir.Instruction) bool {
    return switch (instruction) {
        .heap_new, .local_get => false,
        .const_boolean,
        .const_long,
        .const_double,
        .const_string,
        .const_container,
        .const_function,
        .local_set,
        .binary,
        .unary,
        .convert,
        .struct_make,
        .struct_get,
        .struct_set,
        .variant_make,
        .variant_tag,
        .variant_field,
        .call,
        .call_inout,
        .spawn,
        .call_indirect,
        .intrinsic,
        .object_bind,
        .object_unbind,
        .jump,
        .branch,
        .ret,
        .trap,
        .unwind,
        => true,
    };
}

/// A decoded module gets the same conservative answer even if it
/// constructs an inout call on a heap local.
fn inoutSeed(function: *const mir.Function, instruction: mir.Instruction) ?u32 {
    return switch (instruction) {
        .call_inout => |call| if (function.locals[call.receiver].local_type == .heap)
            call.receiver
        else
            null,
        .const_boolean,
        .const_long,
        .const_double,
        .const_string,
        .const_container,
        .const_function,
        .local_get,
        .local_set,
        .binary,
        .unary,
        .convert,
        .struct_make,
        .struct_get,
        .struct_set,
        .variant_make,
        .variant_tag,
        .variant_field,
        .call,
        .spawn,
        .call_indirect,
        .intrinsic,
        .heap_new,
        .object_bind,
        .object_unbind,
        .jump,
        .branch,
        .ret,
        .trap,
        .unwind,
        => null,
    };
}

fn mark(
    facts: []bool,
    worklist: *std.ArrayList(u32),
    node: u32,
    gpa: Allocator,
) Allocator.Error!void {
    if (facts[node]) return;
    facts[node] = true;
    try worklist.append(gpa, node);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a heap_new local is proven non-root" {
    const gpa = testing.allocator;
    const heap = types.Type{ .heap = 0 };
    const locals = [_]mir.Local{.{ .name = "values", .local_type = heap }};
    const instructions = [_]mir.Instruction{
        .{ .heap_new = .{ .heap = 0, .dims = &.{} } },
        .{ .local_set = .{ .local = 0, .value = 0 } },
        .{ .local_get = 0 },
    };
    const result_types = [_]types.Type{ heap, .none, heap };
    const function: mir.Function = .{
        .name = "main",
        .parameter_count = 0,
        .return_type = .none,
        .locals = @constCast(&locals),
        .instructions = @constCast(&instructions),
        .result_types = @constCast(&result_types),
        .blocks = &.{},
    };

    var made = try plan(gpa, &function);
    defer made.deinit(gpa);
    try testing.expect(!made.mayProgramRoot(2));
}

test "a hostile const_container assignment taints aliases to a fixed point" {
    // This is the shape a hand-built or decoded MIR module can use to
    // hide a constant behind locals.  No front-end provenance is
    // trusted: the instruction itself makes both aliases guarded.
    const gpa = testing.allocator;
    const heap = types.Type{ .heap = 0 };
    const locals = [_]mir.Local{
        .{ .name = "first", .local_type = heap },
        .{ .name = "second", .local_type = heap },
    };
    const instructions = [_]mir.Instruction{
        .{ .const_container = 0 },
        .{ .local_set = .{ .local = 0, .value = 0 } },
        .{ .local_get = 0 },
        .{ .local_set = .{ .local = 1, .value = 2 } },
        .{ .local_get = 1 },
    };
    const result_types = [_]types.Type{ heap, .none, heap, .none, heap };
    const function: mir.Function = .{
        .name = "main",
        .parameter_count = 0,
        .return_type = .none,
        .locals = @constCast(&locals),
        .instructions = @constCast(&instructions),
        .result_types = @constCast(&result_types),
        .blocks = &.{},
    };

    var made = try plan(gpa, &function);
    defer made.deinit(gpa);
    try testing.expect(made.mayProgramRoot(2));
    try testing.expect(made.mayProgramRoot(4));
}

test "a reverse-ordered hostile alias chain reaches every dependent" {
    // The dependency edges deliberately run backward through the
    // instruction pool.  A scan-until-stable implementation needs one
    // full pass per alias; the worklist follows each edge exactly once.
    const gpa = testing.allocator;
    const heap = types.Type{ .heap = 0 };
    const locals = [_]mir.Local{
        .{ .name = "first", .local_type = heap },
        .{ .name = "second", .local_type = heap },
        .{ .name = "third", .local_type = heap },
    };
    const instructions = [_]mir.Instruction{
        .{ .local_get = 1 },
        .{ .local_set = .{ .local = 2, .value = 0 } },
        .{ .local_get = 0 },
        .{ .local_set = .{ .local = 1, .value = 2 } },
        .{ .const_container = 0 },
        .{ .local_set = .{ .local = 0, .value = 4 } },
        .{ .local_get = 2 },
    };
    const result_types = [_]types.Type{ heap, .none, heap, .none, heap, .none, heap };
    const function: mir.Function = .{
        .name = "main",
        .parameter_count = 0,
        .return_type = .none,
        .locals = @constCast(&locals),
        .instructions = @constCast(&instructions),
        .result_types = @constCast(&result_types),
        .blocks = &.{},
    };

    var made = try plan(gpa, &function);
    defer made.deinit(gpa);
    try testing.expect(made.mayProgramRoot(0));
    try testing.expect(made.mayProgramRoot(2));
    try testing.expect(made.mayProgramRoot(6));
}

test "parameters and unknown heap results stay guarded" {
    const gpa = testing.allocator;
    const heap = types.Type{ .heap = 0 };
    const locals = [_]mir.Local{.{ .name = "values", .local_type = heap }};
    const instructions = [_]mir.Instruction{
        .{ .local_get = 0 },
        .{ .call = .{ .function = 1, .arguments = &.{} } },
    };
    const result_types = [_]types.Type{ heap, heap };
    const function: mir.Function = .{
        .name = "mutate",
        .parameter_count = 1,
        .return_type = .none,
        .locals = @constCast(&locals),
        .instructions = @constCast(&instructions),
        .result_types = @constCast(&result_types),
        .blocks = &.{},
    };

    var made = try plan(gpa, &function);
    defer made.deinit(gpa);
    try testing.expect(made.mayProgramRoot(0));
    try testing.expect(made.mayProgramRoot(1));
}
