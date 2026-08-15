//! The one place that knows where an instruction keeps its register
//! operands.
//!
//! Three passes rewrite operands — value numbering folds a duplicate
//! away, the compactor renumbers the pool — and every one of them has
//! to touch *every* operand or it silently corrupts a program.  So the
//! walk is written once, over an exhaustive switch: a new instruction
//! with a register field is a compile error here before it is a bug
//! anywhere else.

const std = @import("std");
const defs = @import("../06_mir/defs.zig");

const Instruction = defs.Instruction;
const Register = defs.Register;

/// Send every register operand of `instruction` through `map`.
///
/// Operand *slices* — `struct_make` fields, call and intrinsic
/// arguments, `heap_new` dimensions — are replaced with fresh copies
/// rather than rewritten where they lie.  Nothing in the lowering is
/// supposed to hand two instructions the same slice, but rewriting in
/// place would map a shared one twice and quietly corrupt a program,
/// and a fresh slice per rewrite makes that unrepresentable.  The
/// abandoned copies stay in the program arena until it is dropped;
/// what shrinks is the artifact, not the resident compiler.
pub fn mapOperands(
    arena: std.mem.Allocator,
    instruction: *Instruction,
    map: []const Register,
) std.mem.Allocator.Error!void {
    switch (instruction.*) {
        .const_boolean,
        .const_long,
        .const_double,
        .const_string,
        .const_container,
        .local_get,
        .jump,
        .trap,
        .unwind,
        => {},
        // A bound function value names a register: the receiver it
        // carries (docs/BINDING.md D12).
        .const_function => |*named| {
            if (named.receiver) |receiver| named.receiver = map[receiver];
        },
        .local_set => |*set| set.value = map[set.value],
        .binary => |*binary| {
            binary.left = map[binary.left];
            binary.right = map[binary.right];
        },
        .unary => |*unary| unary.operand = map[unary.operand],
        .convert => |*operand| operand.* = map[operand.*],
        .struct_make => |*make| make.fields = try mapSlice(arena, make.fields, map),
        .struct_get => |*get| get.target = map[get.target],
        .struct_set => |*set| {
            set.target = map[set.target];
            set.value = map[set.value];
        },
        .variant_make => |*make| make.fields = try mapSlice(arena, make.fields, map),
        .variant_tag => |*tag| tag.target = map[tag.target],
        .variant_field => |*get| get.target = map[get.target],
        .call, .spawn => |*call| call.arguments = try mapSlice(arena, call.arguments, map),
        .call_inout => |*call| call.arguments = try mapSlice(arena, call.arguments, map),
        .call_indirect => |*call| {
            call.callee = map[call.callee];
            call.arguments = try mapSlice(arena, call.arguments, map);
        },
        .intrinsic => |*call| call.arguments = try mapSlice(arena, call.arguments, map),
        .heap_new => |*new| new.dims = try mapSlice(arena, new.dims, map),
        .branch => |*branch| branch.condition = map[branch.condition],
        .ret => |*value| if (value.*) |returned| {
            value.* = map[returned];
        },
    }
}

fn mapSlice(
    arena: std.mem.Allocator,
    operands: []const Register,
    map: []const Register,
) std.mem.Allocator.Error![]Register {
    const copied = try arena.alloc(Register, operands.len);
    for (operands, copied) |operand, *slot| slot.* = map[operand];
    return copied;
}

/// Mark every register `instruction` reads in `used`.
pub fn markOperands(instruction: Instruction, used: []bool) void {
    switch (instruction) {
        .const_boolean,
        .const_long,
        .const_double,
        .const_string,
        .const_container,
        .local_get,
        .jump,
        .trap,
        .unwind,
        => {},
        .const_function => |named| {
            if (named.receiver) |receiver| used[receiver] = true;
        },
        .local_set => |set| used[set.value] = true,
        .binary => |binary| {
            used[binary.left] = true;
            used[binary.right] = true;
        },
        .unary => |unary| used[unary.operand] = true,
        .convert => |operand| used[operand] = true,
        .struct_make => |make| for (make.fields) |field| {
            used[field] = true;
        },
        .struct_get => |get| used[get.target] = true,
        .struct_set => |set| {
            used[set.target] = true;
            used[set.value] = true;
        },
        .variant_make => |make| for (make.fields) |field| {
            used[field] = true;
        },
        .variant_tag => |tag| used[tag.target] = true,
        .variant_field => |get| used[get.target] = true,
        .call_indirect => |call| {
            used[call.callee] = true;
            for (call.arguments) |argument| used[argument] = true;
        },
        .call, .spawn => |call| for (call.arguments) |argument| {
            used[argument] = true;
        },
        .call_inout => |call| for (call.arguments) |argument| {
            used[argument] = true;
        },
        .intrinsic => |call| for (call.arguments) |argument| {
            used[argument] = true;
        },
        .heap_new => |new| for (new.dims) |dimension| {
            used[dimension] = true;
        },
        .branch => |branch| used[branch.condition] = true,
        .ret => |value| if (value) |returned| {
            used[returned] = true;
        },
    }
}

/// Which local an instruction names, and how it touches it.  `read`
/// means the slot's *value* is read: `local_get` does that directly,
/// and `call_inout` reads then may replace its receiver.  That is what
/// makes a store to an otherwise never-read receiver live across the
/// call.
pub const LocalUse = union(enum) {
    none,
    read: defs.LocalId,
    write: defs.LocalId,
    read_write: defs.LocalId,
};

pub fn localUse(instruction: Instruction) LocalUse {
    return switch (instruction) {
        .local_get => |local| .{ .read = local },
        .local_set => |set| .{ .write = set.local },
        .call_inout => |call| .{ .read_write = call.receiver },
        // Everything else works in registers.  Listed rather than
        // defaulted, as `markOperands` lists its own: an instruction
        // added later that names a local would otherwise answer "no
        // local" here and have the stores to that slot deleted.
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
        .spawn,
        .call_indirect,
        .intrinsic,
        .heap_new,
        .jump,
        .branch,
        .ret,
        .trap,
        .unwind,
        => .none,
    };
}

const testing = std.testing;

test "every operand of every instruction shape is rewritten" {
    // A map that shifts each register by one: any operand the walk
    // forgets stays behind and is caught by the comparison.
    var map: [8]Register = undefined;
    for (&map, 0..) |*slot, index| slot.* = @intCast(index + 1);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fields = [_]Register{ 0, 1 };
    var arguments = [_]Register{ 2, 3 };
    var dims = [_]Register{4};
    var shapes = [_]Instruction{
        .{ .local_set = .{ .local = 0, .value = 0 } },
        .{ .binary = .{ .op = .add, .operand_type = .long, .left = 2, .right = 3 } },
        .{ .unary = .{ .op = .negate, .operand = 4 } },
        .{ .convert = 5 },
        .{ .struct_make = .{ .layout = 0, .fields = &fields } },
        .{ .struct_get = .{ .target = 6, .layout = 0, .field = 0 } },
        .{ .struct_set = .{ .target = 0, .layout = 0, .field = 0, .value = 1 } },
        .{ .call = .{ .function = 0, .arguments = &arguments } },
        .{ .call_inout = .{ .function = 0, .receiver = 7, .arguments = &arguments } },
        .{ .intrinsic = .{ .kind = .len, .arguments = &arguments } },
        .{ .heap_new = .{ .heap = 0, .dims = &dims } },
        .{ .branch = .{ .condition = 4, .then_block = 0, .else_block = 0 } },
        .{ .ret = 5 },
    };
    var seen: [8]bool = @splat(false);
    for (&shapes) |*shape| markOperands(shape.*, &seen);
    for (&shapes) |*shape| try mapOperands(arena, shape, &map);

    try testing.expectEqual(@as(Register, 1), shapes[0].local_set.value);
    try testing.expectEqual(@as(Register, 3), shapes[1].binary.left);
    try testing.expectEqual(@as(Register, 4), shapes[1].binary.right);
    try testing.expectEqual(@as(Register, 5), shapes[2].unary.operand);
    try testing.expectEqual(@as(Register, 6), shapes[3].convert);
    try testing.expectEqualSlices(Register, &.{ 1, 2 }, shapes[4].struct_make.fields);
    try testing.expectEqual(@as(Register, 7), shapes[5].struct_get.target);
    try testing.expectEqual(@as(Register, 1), shapes[6].struct_set.target);
    try testing.expectEqual(@as(Register, 2), shapes[6].struct_set.value);
    try testing.expectEqualSlices(Register, &.{ 3, 4 }, shapes[7].call.arguments);
    try testing.expectEqualSlices(Register, &.{ 3, 4 }, shapes[8].call_inout.arguments);
    try testing.expectEqual(@as(defs.LocalId, 7), shapes[8].call_inout.receiver);
    try testing.expectEqualSlices(Register, &.{ 3, 4 }, shapes[9].intrinsic.arguments);
    try testing.expectEqualSlices(Register, &.{5}, shapes[10].heap_new.dims);
    try testing.expectEqual(@as(Register, 5), shapes[11].branch.condition);
    try testing.expectEqual(@as(Register, 6), shapes[12].ret.?);
    // Rewriting hands each instruction its own slice, so the two that
    // shared `arguments` above did not map it twice.
    try testing.expectEqualSlices(Register, &.{ 2, 3 }, &arguments);
    for (seen[0..7]) |marked| try testing.expect(marked);
}
