//! Verifier tests — structural damage a decoder could admit.

const std = @import("std");
const defs = @import("defs.zig");
const types = @import("../support/types.zig");
const verify_mod = @import("verify.zig");

const testing = std.testing;
const Program = defs.Program;
const Function = defs.Function;
const Instruction = defs.Instruction;
const Register = defs.Register;
const Block = defs.Block;
const Local = defs.Local;

test "a struct graph is checked for cycles in one pass, not one per path" {
    // Forty layouts, each holding the next one twice: no cycle, but
    // 2^39 distinct paths from the first to the last.  A per-path walk
    // never returns; a per-node one is instant.  Stage 4 refuses
    // cycles before a `.lc` exists, so this is the decoder's problem
    // and only the decoder's — which is the point.
    var program: Program = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer program.deinit();
    const arena = program.arena.allocator();

    const depth = 40;
    const layouts = try arena.alloc(types.StructLayout, depth);
    for (layouts, 0..) |*layout, index| {
        const held: u32 = @intCast((index + 1) % depth);
        const fields = try arena.alloc(types.StructField, if (index + 1 == depth) 0 else 2);
        for (fields) |*field| field.* = .{ .name = "next", .field_type = .{ .strukt = held } };
        layout.* = .{ .name = "Deep", .fields = fields };
    }
    program.structs = layouts;

    const instructions = try arena.dupe(Instruction, &.{.{ .ret = null }});
    const result_types = try arena.dupe(types.Type, &.{.none});
    const blocks = try arena.alloc(Block, 1);
    blocks[0] = .{ .items = try arena.dupe(Register, &.{0}) };
    const functions = try arena.alloc(Function, 1);
    functions[0] = .{
        .name = "main",
        .parameter_count = 0,
        .return_type = .none,
        .locals = &.{},
        .instructions = instructions,
        .result_types = result_types,
        .blocks = blocks,
    };
    program.functions = functions;
    try verify_mod.verify(testing.allocator, &program);

    // Close the chain: now every layout is on one cycle.
    const closing = try arena.alloc(types.StructField, 1);
    closing[0] = .{ .name = "next", .field_type = .{ .strukt = 0 } };
    layouts[depth - 1].fields = closing;
    try testing.expectError(error.BadStruct, verify_mod.verify(testing.allocator, &program));

    // A layout holding itself directly is the same answer.
    layouts[depth - 1].fields = &.{};
    layouts[0].fields[0].field_type = .{ .strukt = 0 };
    try testing.expectError(error.BadStruct, verify_mod.verify(testing.allocator, &program));
}

test "the verifier rejects structural damage a decoder could admit" {
    var program: Program = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer program.deinit();
    const arena = program.arena.allocator();

    const instructions = try arena.dupe(Instruction, &.{
        .{ .const_int = 1 },
        .{ .ret = null },
    });
    const result_types = try arena.dupe(types.Type, &.{ .int, .none });
    const items = try arena.dupe(Register, &.{ 0, 1 });
    const blocks = try arena.alloc(Block, 1);
    blocks[0] = .{ .items = items };
    const functions = try arena.alloc(Function, 1);
    functions[0] = .{
        .name = try arena.dupe(u8, "main"),
        .parameter_count = 0,
        .return_type = .none,
        .locals = &.{},
        .instructions = instructions,
        .result_types = result_types,
        .blocks = blocks,
    };
    program.functions = functions;
    try verify_mod.verify(testing.allocator, &program);

    functions[0].instructions[1] = .{ .ret = 5 };
    try testing.expectError(error.UndefinedRegister, verify_mod.verify(testing.allocator, &program));
    functions[0].instructions[1] = .{ .ret = null };

    blocks[0].items = items[0..1];
    try testing.expectError(error.UnterminatedBlock, verify_mod.verify(testing.allocator, &program));
    blocks[0].items = items;

    const reordered = try arena.dupe(Register, &.{ 1, 0 });
    blocks[0].items = reordered;
    try testing.expectError(error.MisplacedTerminator, verify_mod.verify(testing.allocator, &program));
    blocks[0].items = items;

    functions[0].result_types[0] = .boolean;
    try testing.expectError(error.TypeMismatch, verify_mod.verify(testing.allocator, &program));
    functions[0].result_types[0] = .int;

    const owned_instructions = try arena.dupe(Instruction, &.{
        .{ .const_int = 1 },
        .{ .object_bind = .{ .local = 7, .value = 0 } },
        .{ .ret = 0 },
    });
    const owned_results = try arena.dupe(types.Type, &.{ .int, .none, .none });
    const owned_items = try arena.dupe(Register, &.{ 0, 1, 2 });
    functions[0].instructions = owned_instructions;
    functions[0].result_types = owned_results;
    blocks[0].items = owned_items;
    try testing.expectError(error.BadLocal, verify_mod.verify(testing.allocator, &program));
    functions[0].instructions = instructions;
    functions[0].result_types = result_types;
    blocks[0].items = items;

    program.entry_function = 9;
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));
    program.entry_function = 0;
    try verify_mod.verify(testing.allocator, &program);

    functions[0].parameter_count = 1;
    functions[0].locals = try arena.dupe(Local, &.{.{ .name = "arg", .local_type = .int }});
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));
    functions[0].parameter_count = 0;
    functions[0].locals = &.{};

    const duplicate = try arena.dupe(Register, &.{ 0, 0, 1 });
    blocks[0].items = duplicate;
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));
    blocks[0].items = items;
    try verify_mod.verify(testing.allocator, &program);
}
