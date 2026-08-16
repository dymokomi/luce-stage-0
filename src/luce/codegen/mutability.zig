//! Which heap-valued MIR registers may name an immutable program constant.
//!
//! Inline list and array writes bypass `Runtime.requireMutable`, so lowering
//! must keep its `immutable_object` guard whenever the receiver might have
//! arrived from `const_container`. A trusted bit in MIR would let a decoded
//! module forge that answer. This pass derives it from the final, verified
//! MIR that code generation is about to consume.
//!
//! The lattice is deliberately one-sided: `true` means "may be constant",
//! and facts only move from false to true. Parameters, inout slots, and every
//! heap-producing instruction except `heap_new` begin true. A new heap row
//! and a non-parameter local's null default begin false; `local_get` and
//! `local_set` edges then propagate the facts to a fixed point. A receiver is
//! therefore proven writable only when every value that can reach it is a
//! locally created row, including assignments around loops.
//!
//! The proof remains true after a register is produced: the constants
//! prologue is the only operation that marks an ordinary row constant, and
//! it finishes before any Luce function executes. ARC changes how references
//! are retained and released; it does not change that provenance fact.

const std = @import("std");
const mir = @import("../mir.zig");
const types = @import("../support/types.zig");

const Allocator = std.mem.Allocator;

/// Constant reachability for every register in one function.
pub const Plan = struct {
    facts: []bool = &.{},
    register_at: u32 = 0,

    pub fn deinit(self: *Plan, gpa: Allocator) void {
        gpa.free(self.facts);
        self.* = .{};
    }

    /// Whether omitting the runtime's constant-row check would be unsound.
    pub fn mayBeConstant(self: Plan, register: mir.Register) bool {
        return self.facts[self.register_at + register];
    }
};

/// Derive constant reachability from exactly the function LLVM will lower.
pub fn plan(gpa: Allocator, function: *const mir.Function) Allocator.Error!Plan {
    // The module verifier caps both tables far below u32. Keeping node IDs at
    // that width halves the scratch footprint for the largest valid input.
    const register_at: u32 = @intCast(function.locals.len);
    const node_count = function.locals.len + function.instructions.len;

    // Flat CSR graph: local_get contributes local -> register, and local_set
    // contributes register -> local. The worklist visits every node and edge
    // at most once, so hostile but valid modules cannot force repeated scans.
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

    // Seed everything whose contract does not prove it creates a new row.
    // local_get receives its fact through the graph above.
    for (function.instructions, function.result_types, 0..) |instruction, result_type, register| {
        if (result_type == .heap and startsMayBeConstant(instruction)) {
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
            if (facts[to]) continue;
            facts[to] = true;
            try worklist.append(gpa, to);
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
        .const_integer,
        .const_float,
        .const_str,
        .const_container,
        .const_function,
        .weak_local_get,
        .weak_local_set,
        .binary,
        .unary,
        .convert,
        .struct_make,
        .struct_get,
        .struct_set,
        .weak_struct_get,
        .weak_struct_set,
        .variant_make,
        .variant_tag,
        .variant_field,
        .call,
        .call_inout,
        .spawn,
        .call_indirect,
        .intrinsic,
        .heap_new,
        .jump,
        .branch,
        .ret,
        .trap,
        .unwind,
        => null,
    };
}

/// Seed all heap results not guaranteed to be a newly allocated row.
/// Exhaustive so a new instruction cannot silently gain permission to skip
/// the immutable-row guard.
fn startsMayBeConstant(instruction: mir.Instruction) bool {
    return switch (instruction) {
        .heap_new, .local_get => false,
        .const_boolean,
        .const_integer,
        .const_float,
        .const_str,
        .const_container,
        .const_function,
        .local_set,
        .weak_local_get,
        .weak_local_set,
        .binary,
        .unary,
        .convert,
        .struct_make,
        .struct_get,
        .struct_set,
        .weak_struct_get,
        .weak_struct_set,
        .variant_make,
        .variant_tag,
        .variant_field,
        .call,
        .call_inout,
        .spawn,
        .call_indirect,
        .intrinsic,
        .jump,
        .branch,
        .ret,
        .trap,
        .unwind,
        => true,
    };
}

/// A decoded module gets the conservative answer when an inout call may
/// replace a heap local through its aliased receiver slot.
fn inoutSeed(function: *const mir.Function, instruction: mir.Instruction) ?u32 {
    return switch (instruction) {
        .call_inout => |call| if (function.locals[call.receiver].local_type == .heap)
            call.receiver
        else
            null,
        .const_boolean,
        .const_integer,
        .const_float,
        .const_str,
        .const_container,
        .const_function,
        .local_get,
        .local_set,
        .weak_local_get,
        .weak_local_set,
        .binary,
        .unary,
        .convert,
        .struct_make,
        .struct_get,
        .struct_set,
        .weak_struct_get,
        .weak_struct_set,
        .variant_make,
        .variant_tag,
        .variant_field,
        .call,
        .spawn,
        .call_indirect,
        .intrinsic,
        .heap_new,
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

test "a heap_new local is proven writable" {
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
    try testing.expect(!made.mayBeConstant(2));
}

test "a hostile constant assignment taints every direct alias" {
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
    try testing.expect(made.mayBeConstant(2));
    try testing.expect(made.mayBeConstant(4));
}

test "a reverse-ordered hostile alias chain reaches a fixed point" {
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
    try testing.expect(made.mayBeConstant(0));
    try testing.expect(made.mayBeConstant(2));
    try testing.expect(made.mayBeConstant(6));
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
    try testing.expect(made.mayBeConstant(0));
    try testing.expect(made.mayBeConstant(1));
}
