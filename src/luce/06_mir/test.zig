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
    // cycles before a `.lcm` exists, so this is the decoder's problem
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
        .{ .const_long = 1 },
        .{ .ret = null },
    });
    const result_types = try arena.dupe(types.Type, &.{ .long, .none });
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
    functions[0].result_types[0] = .long;

    const owned_instructions = try arena.dupe(Instruction, &.{
        .{ .const_long = 1 },
        .{ .object_bind = .{ .local = 7, .value = 0 } },
        .{ .ret = 0 },
    });
    const owned_results = try arena.dupe(types.Type, &.{ .long, .none, .none });
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
    functions[0].locals = try arena.dupe(Local, &.{.{ .name = "arg", .local_type = .long }});
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));
    functions[0].parameter_count = 0;
    functions[0].locals = &.{};

    const duplicate = try arena.dupe(Register, &.{ 0, 0, 1 });
    blocks[0].items = duplicate;
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));
    blocks[0].items = items;
    try verify_mod.verify(testing.allocator, &program);
}

// ---------------------------------------------------------------------------
// Many blocks
// ---------------------------------------------------------------------------
//
// The tests above hand the verifier one block, which is the shape a
// straight-line lowering writes.  Everything below hands it several,
// because that is where the invariants the rest of the compiler leans
// on actually live: a register never crosses a block (so a pass may
// keep one table per block, and stage 8 may give a register one
// value), every block ends in exactly one terminator, and every block
// a terminator names exists.  None of these can be reached from
// source — stage 4 does not write them — so a hand-built function is
// the only way to prove the verifier refuses them, and a decoded
// `.lcm` is exactly the input that can carry them.

/// One hand-built function, installed as the program's entry.
///
/// Everything is duplicated into the program's arena, so a test frees
/// the program and nothing else.  The defaults are the common case: a
/// script entry taking nothing, returning nothing, that cannot fail.
const Shape = struct {
    instructions: []const Instruction,
    result_types: []const types.Type,
    /// One item list per block, in block order.
    blocks: []const []const Register,
    locals: []const Local = &.{},
    parameter_count: u32 = 0,
    return_type: types.Type = .none,
    fallible: bool = false,
};

/// A program holding exactly `shape` as its entry, ready to verify.
fn programOf(shape: Shape) !Program {
    var program: Program = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    errdefer program.deinit();
    const arena = program.arena.allocator();

    const blocks = try arena.alloc(Block, shape.blocks.len);
    for (blocks, shape.blocks) |*block, items| {
        block.* = .{ .items = try arena.dupe(Register, items) };
    }
    const functions = try arena.alloc(Function, 1);
    functions[0] = .{
        .name = "main",
        .parameter_count = shape.parameter_count,
        .return_type = shape.return_type,
        .fallible = shape.fallible,
        .locals = try arena.dupe(Local, shape.locals),
        .instructions = try arena.dupe(Instruction, shape.instructions),
        .result_types = try arena.dupe(types.Type, shape.result_types),
        .blocks = blocks,
    };
    program.functions = functions;
    program.entry_function = 0;
    return program;
}

test "a register defined in one block cannot be read in another" {
    // The invariant the whole middle end is built on: registers do not
    // cross blocks, and a value that must survive a branch travels in
    // a local.  `verifyFunction` enforces it by forgetting every
    // definition at each block boundary, and a decoder that admitted a
    // module without it would hand stage 8 a register with no value on
    // one of its paths.
    //
    //   block 0:  r0 = const 1        block 1:  ret r0
    //             jump 1
    var crossing = try programOf(.{
        .instructions = &.{
            .{ .const_long = 1 },
            .{ .jump = 1 },
            .{ .ret = 0 },
        },
        .result_types = &.{ .long, .none, .none },
        .blocks = &.{ &.{ 0, 1 }, &.{2} },
        .return_type = .long,
    });
    defer crossing.deinit();
    try testing.expectError(error.UndefinedRegister, verify_mod.verify(testing.allocator, &crossing));

    // The very same instructions in one block are fine, which is what
    // makes the block boundary — and nothing else — the fault above.
    var together = try programOf(.{
        .instructions = &.{
            .{ .const_long = 1 },
            .{ .ret = 0 },
        },
        .result_types = &.{ .long, .none },
        .blocks = &.{&.{ 0, 1 }},
        .return_type = .long,
    });
    defer together.deinit();
    try verify_mod.verify(testing.allocator, &together);
}

test "a value crosses a block in a local, and the local's type is checked" {
    // The sanctioned way across: store into a local before the jump,
    // load it after.  This is what stage 4 emits for loop state, so it
    // must verify — and the load must answer the local's declared
    // type, so a module claiming otherwise is refused.
    var carried = try programOf(.{
        .instructions = &.{
            .{ .const_long = 7 }, // r0
            .{ .local_set = .{ .local = 0, .value = 0 } }, // r1
            .{ .jump = 1 }, // r2
            .{ .local_get = 0 }, // r3
            .{ .ret = 3 }, // r4
        },
        .result_types = &.{ .long, .none, .none, .long, .none },
        .blocks = &.{ &.{ 0, 1, 2 }, &.{ 3, 4 } },
        .locals = &.{.{ .name = "carried", .local_type = .long }},
        .return_type = .long,
    });
    defer carried.deinit();
    try verify_mod.verify(testing.allocator, &carried);

    // The load claiming a type the slot does not hold.
    carried.functions[0].result_types[3] = .double;
    try testing.expectError(error.TypeMismatch, verify_mod.verify(testing.allocator, &carried));
    carried.functions[0].result_types[3] = .long;

    // A local id past the end of the table, on the load and the store
    // alike.
    carried.functions[0].instructions[3] = .{ .local_get = 4 };
    try testing.expectError(error.BadLocal, verify_mod.verify(testing.allocator, &carried));
    carried.functions[0].instructions[3] = .{ .local_get = 0 };
    carried.functions[0].instructions[1] = .{ .local_set = .{ .local = 4, .value = 0 } };
    try testing.expectError(error.BadLocal, verify_mod.verify(testing.allocator, &carried));
    carried.functions[0].instructions[1] = .{ .local_set = .{ .local = 0, .value = 0 } };

    // The store handing the slot a type it cannot hold.
    carried.functions[0].locals[0].local_type = .double;
    try testing.expectError(error.TypeMismatch, verify_mod.verify(testing.allocator, &carried));
}

test "every block ends in exactly one terminator, wherever the block sits" {
    // A block with no terminator at its end, and a terminator in the
    // middle of one, are different faults with different names — and
    // both must be caught in a *later* block, not only the first.
    var missing = try programOf(.{
        .instructions = &.{
            .{ .jump = 1 }, // r0
            .{ .const_long = 1 }, // r1: block 1 ends here, on a value
        },
        .result_types = &.{ .none, .long },
        .blocks = &.{ &.{0}, &.{1} },
    });
    defer missing.deinit();
    try testing.expectError(error.UnterminatedBlock, verify_mod.verify(testing.allocator, &missing));

    var misplaced = try programOf(.{
        .instructions = &.{
            .{ .jump = 1 }, // r0
            .{ .ret = null }, // r1: a terminator, but not last
            .{ .const_long = 1 }, // r2
        },
        .result_types = &.{ .none, .none, .long },
        .blocks = &.{ &.{0}, &.{ 1, 2 } },
    });
    defer misplaced.deinit();
    try testing.expectError(error.MisplacedTerminator, verify_mod.verify(testing.allocator, &misplaced));

    // An empty block is not a block at all: nothing leaves it.
    var empty = try programOf(.{
        .instructions = &.{.{ .jump = 1 }},
        .result_types = &.{.none},
        .blocks = &.{ &.{0}, &.{} },
    });
    defer empty.deinit();
    try testing.expectError(error.UnterminatedBlock, verify_mod.verify(testing.allocator, &empty));

    // And a function with no blocks has nowhere to start.
    var headless = try programOf(.{
        .instructions = &.{.{ .ret = null }},
        .result_types = &.{.none},
        .blocks = &.{},
    });
    defer headless.deinit();
    try testing.expectError(error.EmptyFunction, verify_mod.verify(testing.allocator, &headless));
}

test "a terminator may only name a block that exists" {
    var jumping = try programOf(.{
        .instructions = &.{.{ .jump = 0 }},
        .result_types = &.{.none},
        .blocks = &.{&.{0}},
    });
    defer jumping.deinit();
    try verify_mod.verify(testing.allocator, &jumping);
    jumping.functions[0].instructions[0] = .{ .jump = 1 };
    try testing.expectError(error.BadBlock, verify_mod.verify(testing.allocator, &jumping));

    // Both arms of a branch, independently.
    var branching = try programOf(.{
        .instructions = &.{
            .{ .const_boolean = true }, // r0
            .{ .branch = .{ .condition = 0, .then_block = 1, .else_block = 1 } }, // r1
            .{ .ret = null }, // r2
        },
        .result_types = &.{ .boolean, .none, .none },
        .blocks = &.{ &.{ 0, 1 }, &.{2} },
    });
    defer branching.deinit();
    try verify_mod.verify(testing.allocator, &branching);

    branching.functions[0].instructions[1].branch.then_block = 2;
    try testing.expectError(error.BadBlock, verify_mod.verify(testing.allocator, &branching));
    branching.functions[0].instructions[1].branch.then_block = 1;
    branching.functions[0].instructions[1].branch.else_block = 7;
    try testing.expectError(error.BadBlock, verify_mod.verify(testing.allocator, &branching));
    branching.functions[0].instructions[1].branch.else_block = 1;

    // A branch decides on a bool and on nothing else.
    branching.functions[0].instructions[0] = .{ .const_long = 1 };
    branching.functions[0].result_types[0] = .long;
    try testing.expectError(error.TypeMismatch, verify_mod.verify(testing.allocator, &branching));
}

test "one instruction may stand in exactly one block" {
    // Registers are pool indices, so an instruction listed twice would
    // have two definitions and two positions — and `dead`'s compaction
    // would move it under both.  The verifier's `seen` table refuses
    // the repeat whether it is in the same block or a later one.
    var shared = try programOf(.{
        .instructions = &.{
            .{ .const_long = 1 }, // r0
            .{ .jump = 1 }, // r1
            .{ .ret = null }, // r2
        },
        .result_types = &.{ .long, .none, .none },
        .blocks = &.{ &.{ 0, 1 }, &.{ 0, 2 } },
    });
    defer shared.deinit();
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &shared));
}

test "a register is defined before it is read, never after" {
    // Within a block the walk is in order, so an operand naming an
    // instruction that comes later has no value yet.  The pool index
    // exists, which is what makes this a check rather than a bounds
    // test.
    var forward = try programOf(.{
        .instructions = &.{
            .{ .unary = .{ .op = .negate, .operand = 1 } }, // r0 reads r1
            .{ .const_long = 1 }, // r1
            .{ .ret = null }, // r2
        },
        .result_types = &.{ .long, .long, .none },
        .blocks = &.{&.{ 0, 1, 2 }},
    });
    defer forward.deinit();
    try testing.expectError(error.UndefinedRegister, verify_mod.verify(testing.allocator, &forward));
}

test "a register that answers nothing cannot be used as a value" {
    // `assert_true` has result type `none`.  Naming it as an operand
    // is a module reading a value that was never produced, which is a
    // different mistake from naming a register that is not defined.
    var asserted = [_]Register{0};
    var valueless = try programOf(.{
        .instructions = &.{
            .{ .const_boolean = true }, // r0
            .{ .intrinsic = .{ .kind = .assert_true, .arguments = &asserted } }, // r1 -> none
            .{ .unary = .{ .op = .logic_not, .operand = 1 } }, // r2 reads it anyway
            .{ .ret = null }, // r3
        },
        .result_types = &.{ .boolean, .none, .boolean, .none },
        .blocks = &.{&.{ 0, 1, 2, 3 }},
    });
    defer valueless.deinit();
    try testing.expectError(error.ValuelessRegister, verify_mod.verify(testing.allocator, &valueless));
}

test "only a function that says it can fail may raise or unwind" {
    // `fallible` is what a caller was compiled against: a module that
    // unwinds out of a function whose signature promised a return has
    // no branch waiting for it on the other side.
    var words = [_]Register{0};
    var fallible = try programOf(.{
        .instructions = &.{
            .{ .const_string = 0 }, // r0
            .{ .intrinsic = .{ .kind = .raise_error, .arguments = &words } }, // r1
            .{ .unwind = {} }, // r2
        },
        .result_types = &.{ .string, .none, .none },
        .blocks = &.{&.{ 0, 1, 2 }},
        .fallible = true,
    });
    defer fallible.deinit();
    fallible.constants = &.{"boom"};
    try verify_mod.verify(testing.allocator, &fallible);

    fallible.functions[0].fallible = false;
    try testing.expectError(error.NotFallible, verify_mod.verify(testing.allocator, &fallible));
    fallible.functions[0].fallible = true;

    // The words a raise carries must be in the constant table.
    fallible.functions[0].instructions[0] = .{ .const_string = 3 };
    try testing.expectError(error.BadConstant, verify_mod.verify(testing.allocator, &fallible));

    // The terminator on its own, with no `raise_error` in front of it,
    // is refused on the same grounds.
    var bare = try programOf(.{
        .instructions = &.{.{ .unwind = {} }},
        .result_types = &.{.none},
        .blocks = &.{&.{0}},
    });
    defer bare.deinit();
    try testing.expectError(error.NotFallible, verify_mod.verify(testing.allocator, &bare));
    bare.functions[0].fallible = true;
    try verify_mod.verify(testing.allocator, &bare);
}

test "errored asks about a call that can fail, and must stand in its block" {
    // `errored` is the one instruction that reads another's outcome
    // rather than its value, so the verifier checks that the thing it
    // names really can come back errored — and that it was defined in
    // this block, since a register does not cross one.
    var path = [_]Register{0};
    var outcome = [_]Register{1};
    var twice = [_]Register{ 1, 1 };
    var asking = try programOf(.{
        .instructions = &.{
            .{ .const_string = 0 }, // r0
            .{ .intrinsic = .{ .kind = .file_exists, .arguments = &path } }, // r1: cannot fail
            .{ .intrinsic = .{ .kind = .errored, .arguments = &outcome } }, // r2
            .{ .ret = null }, // r3
        },
        .result_types = &.{ .string, .boolean, .boolean, .none },
        .blocks = &.{&.{ 0, 1, 2, 3 }},
    });
    defer asking.deinit();
    asking.constants = &.{"a.txt"};
    try testing.expectError(error.BadIntrinsic, verify_mod.verify(testing.allocator, &asking));

    // `file_read` can fail, so the same question is well formed.
    asking.functions[0].instructions[1] = .{ .intrinsic = .{ .kind = .file_read, .arguments = &path } };
    asking.functions[0].result_types[1] = .string;
    try verify_mod.verify(testing.allocator, &asking);

    // `errored` names exactly one instruction.
    asking.functions[0].instructions[2] = .{ .intrinsic = .{ .kind = .errored, .arguments = &twice } };
    try testing.expectError(error.BadIntrinsic, verify_mod.verify(testing.allocator, &asking));

    // Asked across a block boundary: the register it names is not
    // defined here, so there is nothing to ask about.
    const arena = asking.arena.allocator();
    asking.functions[0].instructions = try arena.dupe(Instruction, &.{
        .{ .const_string = 0 }, // r0
        .{ .intrinsic = .{ .kind = .file_read, .arguments = &path } }, // r1
        .{ .jump = 1 }, // r2
        .{ .intrinsic = .{ .kind = .errored, .arguments = &outcome } }, // r3
        .{ .ret = null }, // r4
    });
    asking.functions[0].result_types = try arena.dupe(
        types.Type,
        &.{ .string, .string, .none, .boolean, .none },
    );
    asking.functions[0].blocks = try arena.dupe(Block, &.{
        .{ .items = try arena.dupe(Register, &.{ 0, 1, 2 }) },
        .{ .items = try arena.dupe(Register, &.{ 3, 4 }) },
    });
    try testing.expectError(error.UndefinedRegister, verify_mod.verify(testing.allocator, &asking));
}

test "a call agrees with the callee it names, argument for argument" {
    var program: Program = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer program.deinit();
    const arena = program.arena.allocator();

    const functions = try arena.alloc(Function, 2);
    const arguments = try arena.dupe(Register, &.{0});
    // f0: main — calls f1 with one long.
    functions[0] = .{
        .name = "main",
        .parameter_count = 0,
        .return_type = .none,
        .locals = &.{},
        .instructions = try arena.dupe(Instruction, &.{
            .{ .const_long = 1 }, // r0
            .{ .call = .{ .function = 1, .arguments = arguments } }, // r1
            .{ .ret = null }, // r2
        }),
        .result_types = try arena.dupe(types.Type, &.{ .long, .long, .none }),
        .blocks = try arena.dupe(Block, &.{
            .{ .items = try arena.dupe(Register, &.{ 0, 1, 2 }) },
        }),
    };
    // f1: twice(value: long) -> long
    functions[1] = .{
        .name = "twice",
        .parameter_count = 1,
        .return_type = .long,
        .locals = try arena.dupe(Local, &.{.{ .name = "value", .local_type = .long }}),
        .instructions = try arena.dupe(Instruction, &.{
            .{ .local_get = 0 }, // r0
            .{ .ret = 0 }, // r1
        }),
        .result_types = try arena.dupe(types.Type, &.{ .long, .none }),
        .blocks = try arena.dupe(Block, &.{
            .{ .items = try arena.dupe(Register, &.{ 0, 1 }) },
        }),
    };
    program.functions = functions;
    try verify_mod.verify(testing.allocator, &program);

    // A callee that does not exist.
    functions[0].instructions[1].call.function = 4;
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));
    functions[0].instructions[1].call.function = 1;

    // The wrong number of arguments.
    functions[0].instructions[1].call.arguments = arguments[0..0];
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));
    functions[0].instructions[1].call.arguments = arguments;

    // The right count, the wrong type.
    functions[0].instructions[0] = .{ .const_double = 1.0 };
    functions[0].result_types[0] = .double;
    try testing.expectError(error.TypeMismatch, verify_mod.verify(testing.allocator, &program));
    functions[0].instructions[0] = .{ .const_long = 1 };
    functions[0].result_types[0] = .long;

    // The call's own result must be what the callee returns.
    functions[0].result_types[1] = .double;
    try testing.expectError(error.TypeMismatch, verify_mod.verify(testing.allocator, &program));
    functions[0].result_types[1] = .long;
    try verify_mod.verify(testing.allocator, &program);

    // A callee's parameters are its first locals, so fewer locals than
    // parameters is a function that cannot receive what it declares.
    // The caller is verified first and reads the callee's parameter
    // table to type its arguments, so this has to be refused before
    // any body is walked — otherwise the read runs off the end.
    functions[0].instructions[1].call.arguments = try arena.dupe(Register, &.{ 0, 0 });
    functions[1].parameter_count = 2;
    try testing.expectError(error.BadLocal, verify_mod.verify(testing.allocator, &program));
    functions[0].instructions[1].call.arguments = arguments;
    functions[1].parameter_count = 1;

    // What a function returns is checked against what it says it
    // returns, in the callee as well as at the call.
    functions[1].return_type = .double;
    try testing.expectError(error.TypeMismatch, verify_mod.verify(testing.allocator, &program));
}

test "the heap type table is checked before anything indexes it" {
    var program = try programOf(.{
        .instructions = &.{
            .{ .heap_new = .{ .heap = 0, .dims = &.{} } }, // r0
            .{ .ret = null }, // r1
        },
        .result_types = &.{ .{ .heap = 0 }, .none },
        .blocks = &.{&.{ 0, 1 }},
    });
    defer program.deinit();
    const heap_types = try program.arena.allocator().alloc(types.HeapType, 1);
    heap_types[0] = .{ .list = .long };
    program.heap_types = heap_types;
    try verify_mod.verify(testing.allocator, &program);

    // A map keyed by something that cannot be a key.
    heap_types[0] = .{ .map = .{ .key = .double, .value = .long } };
    try testing.expectError(error.BadStruct, verify_mod.verify(testing.allocator, &program));

    // An array with no axes, and one with more than the four the
    // language spells.
    heap_types[0] = .{ .array = .{ .element = .long, .rank = 0 } };
    try testing.expectError(error.BadStruct, verify_mod.verify(testing.allocator, &program));
    heap_types[0] = .{ .array = .{ .element = .long, .rank = 5 } };
    try testing.expectError(error.BadStruct, verify_mod.verify(testing.allocator, &program));

    // A rank the `heap_new` supplies no sizes for.
    heap_types[0] = .{ .array = .{ .element = .long, .rank = 2 } };
    try testing.expectError(error.BadStruct, verify_mod.verify(testing.allocator, &program));

    // An element type naming a struct row that is not there.
    heap_types[0] = .{ .list = .{ .strukt = 3 } };
    try testing.expectError(error.BadStruct, verify_mod.verify(testing.allocator, &program));

    // And what `heap_new` answers must be the row it allocated.
    heap_types[0] = .{ .list = .long };
    program.functions[0].result_types[0] = .{ .heap = 1 };
    try testing.expectError(error.BadStruct, verify_mod.verify(testing.allocator, &program));
}

test "an intrinsic is checked for its own arity and operand types" {
    var of = [_]Register{0};
    var seven = [_]Register{ 0, 0, 0, 0, 0, 0, 0 };
    var program = try programOf(.{
        .instructions = &.{
            .{ .const_double = 4.0 }, // r0
            .{ .intrinsic = .{ .kind = .sqrt, .arguments = &of } }, // r1
            .{ .ret = null }, // r2
        },
        .result_types = &.{ .double, .double, .none },
        .blocks = &.{&.{ 0, 1, 2 }},
    });
    defer program.deinit();
    try verify_mod.verify(testing.allocator, &program);

    // Too few arguments for what it does.
    program.functions[0].instructions[1].intrinsic.arguments = of[0..0];
    try testing.expectError(error.BadIntrinsic, verify_mod.verify(testing.allocator, &program));

    // More than any intrinsic takes, refused before the operands are
    // typed at all — the buffer that types them is six wide, and a
    // module naming seven must not be allowed to reach it.
    program.functions[0].instructions[1].intrinsic.arguments = &seven;
    try testing.expectError(error.BadIntrinsic, verify_mod.verify(testing.allocator, &program));

    // The right arity, the wrong operand type.
    program.functions[0].instructions[1].intrinsic.arguments = &of;
    program.functions[0].instructions[0] = .{ .const_long = 4 };
    program.functions[0].result_types[0] = .long;
    try testing.expectError(error.TypeMismatch, verify_mod.verify(testing.allocator, &program));
}

test "the entry is a function that exists and takes nothing" {
    var program = try programOf(.{
        .instructions = &.{.{ .ret = null }},
        .result_types = &.{.none},
        .blocks = &.{&.{0}},
    });
    defer program.deinit();
    try verify_mod.verify(testing.allocator, &program);

    program.entry_function = 1;
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));
    program.entry_function = 0;

    // A host calls the entry with nothing to give it, so an entry that
    // declares a parameter could never be started.
    program.functions[0].parameter_count = 1;
    program.functions[0].locals = try program.arena.allocator().dupe(
        Local,
        &.{.{ .name = "argument", .local_type = .long }},
    );
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));
}

test "the side tables are exactly as long as the instruction pool" {
    var program = try programOf(.{
        .instructions = &.{
            .{ .const_long = 1 }, // r0
            .{ .ret = null }, // r1
        },
        .result_types = &.{ .long, .none },
        .blocks = &.{&.{ 0, 1 }},
    });
    defer program.deinit();
    try verify_mod.verify(testing.allocator, &program);

    // One result type per instruction, always.
    const full = program.functions[0].result_types;
    program.functions[0].result_types = full[0..1];
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));
    program.functions[0].result_types = full;

    // Origins are all or nothing: a debug module carries one per
    // instruction and a release module carries none, and a table of
    // any other length would place a trap at the wrong line
    // (docs/MODES.md).
    const origins = try program.arena.allocator().alloc(defs.Origin, 2);
    for (origins) |*origin| origin.* = .{ .line = 1, .column = 1 };
    program.functions[0].origins = origins;
    try verify_mod.verify(testing.allocator, &program);
    program.functions[0].origins = origins[0..1];
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));
    program.functions[0].origins = &.{};
    try verify_mod.verify(testing.allocator, &program);
}
