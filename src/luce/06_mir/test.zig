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
