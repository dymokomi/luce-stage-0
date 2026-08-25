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

test "runtime-mediated file services need no engine Effects guard" {
    const runtime_guarded = [_]defs.Intrinsic{
        .file_read,
        .file_write,
        .file_append,
        .file_open,
        .handle_read,
        .handle_write,
        .handle_flush,
    };
    for (runtime_guarded) |intrinsic| {
        try testing.expect(!intrinsic.reachesHost());
    }

    // Direct host calls remain the engine's responsibility.
    try testing.expect(defs.Intrinsic.path_kind.reachesHost());
    try testing.expect(defs.Intrinsic.file_delete.reachesHost());
}

test "class deinitializer metadata is exact and never source-callable" {
    var program: Program = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer program.deinit();
    const arena = program.arena.allocator();

    program.structs = try arena.dupe(types.StructLayout, &.{.{
        .name = "Resource",
        .fields = &.{},
        .reference = true,
        .deinitializer = 1,
    }});
    program.heap_types = try arena.dupe(types.HeapType, &.{.{ .class = 0 }});
    const functions = try arena.alloc(Function, 2);
    functions[0] = .{
        .name = "main",
        .parameter_count = 0,
        .return_type = .none,
        .locals = &.{},
        .instructions = try arena.dupe(Instruction, &.{.{ .ret = null }}),
        .result_types = try arena.dupe(types.Type, &.{.none}),
        .blocks = try arena.dupe(Block, &.{.{
            .items = try arena.dupe(Register, &.{0}),
        }}),
    };
    functions[1] = .{
        .name = "Resource.deinit",
        .parameter_count = 1,
        .return_type = .none,
        .locals = try arena.dupe(Local, &.{.{
            .name = "self",
            .local_type = .{ .heap = 0 },
        }}),
        .instructions = try arena.dupe(Instruction, &.{.{ .ret = null }}),
        .result_types = try arena.dupe(types.Type, &.{.none}),
        .blocks = try arena.dupe(Block, &.{.{
            .items = try arena.dupe(Register, &.{0}),
        }}),
    };
    program.functions = functions;
    program.entry_function = 0;
    try verify_mod.verify(testing.allocator, &program);

    program.structs[0].reference = false;
    try testing.expectError(error.BadStruct, verify_mod.verify(testing.allocator, &program));
    program.structs[0].reference = true;
    program.structs[0].deinitializer = 9;
    try testing.expectError(error.BadStruct, verify_mod.verify(testing.allocator, &program));
    program.structs[0].deinitializer = 1;

    functions[1].parameter_count = 0;
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));
    functions[1].parameter_count = 1;
    functions[1].locals[0].inout = true;
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));
    functions[1].locals[0].inout = false;
    functions[1].locals[0].local_type = .i64;
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));
    functions[1].locals[0].local_type = .{ .heap = 0 };
    functions[1].fallible = true;
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));
    functions[1].fallible = false;
    functions[1].return_type = .i64;
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));
    functions[1].return_type = .none;

    const ordinary = functions[0].instructions[0];
    inline for (.{
        Instruction{ .call = .{ .function = 1, .arguments = &.{} } },
        Instruction{ .spawn = .{ .function = 1, .arguments = &.{} } },
        Instruction{ .call_inout = .{ .function = 1, .receiver = 0, .arguments = &.{} } },
        Instruction{ .const_function = .{ .function = 1 } },
    }) |edge| {
        functions[0].instructions[0] = edge;
        try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));
    }
    functions[0].instructions[0] = ordinary;
    try verify_mod.verify(testing.allocator, &program);
}

test "the verifier holds C globals and C-layout structs to their vocabularies" {
    var program: Program = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer program.deinit();
    const arena = program.arena.allocator();

    // Two layouts: a C-layout struct and an ordinary one, so both
    // sides of the boundary's struct rules can be probed.
    const rect_fields = try arena.dupe(types.StructField, &.{.{ .name = "x", .field_type = .i32 }});
    const plain_fields = try arena.dupe(types.StructField, &.{.{ .name = "n", .field_type = .i64 }});
    const layouts = try arena.alloc(types.StructLayout, 2);
    layouts[0] = .{ .name = "Rect", .fields = rect_fields, .c_layout = true };
    layouts[1] = .{ .name = "Plain", .fields = plain_fields };
    program.structs = layouts;

    program.foreign_variables = try arena.dupe(defs.ForeignVariable, &.{.{
        .name = "probe",
        .value_type = .i64,
    }});
    program.foreign_functions = try arena.dupe(defs.ForeignFunction, &.{.{
        .name = "probe_fn",
        .parameters = &.{},
        .result = .none,
    }});

    const instructions = try arena.dupe(Instruction, &.{
        .{ .foreign_get = 0 },
        .{ .foreign_set = .{ .variable = 0, .value = 0 } },
        .{ .call_foreign = .{ .foreign = 0, .arguments = &.{} } },
        .{ .ret = null },
    });
    const result_types = try arena.dupe(types.Type, &.{ .i64, .none, .none, .none });
    const blocks = try arena.alloc(Block, 1);
    blocks[0] = .{ .items = try arena.dupe(Register, &.{ 0, 1, 2, 3 }) };
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

    // A global row outside the Globals vocabulary, or with no symbol.
    program.foreign_variables[0].value_type = .str;
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));
    program.foreign_variables[0].value_type = .{ .strukt = 0 };
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));
    program.foreign_variables[0].value_type = .i64;
    program.foreign_variables[0].name = "";
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));
    program.foreign_variables[0].name = "probe";

    // An out-of-range row index, from either instruction.
    functions[0].instructions[0] = .{ .foreign_get = 3 };
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));
    functions[0].instructions[0] = .{ .foreign_get = 0 };
    functions[0].instructions[1] = .{ .foreign_set = .{ .variable = 3, .value = 0 } };
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));
    functions[0].instructions[1] = .{ .foreign_set = .{ .variable = 0, .value = 0 } };

    // A load at the wrong width, and a store of the wrong type.
    functions[0].result_types[0] = .i32;
    try testing.expectError(error.TypeMismatch, verify_mod.verify(testing.allocator, &program));
    functions[0].result_types[0] = .i64;
    program.foreign_variables[0].value_type = .i32;
    try testing.expectError(error.TypeMismatch, verify_mod.verify(testing.allocator, &program));
    program.foreign_variables[0].value_type = .i64;

    // By-value aggregate return, and an ordinary struct in a slot.
    program.foreign_functions[0].result = .{ .strukt = 0 };
    functions[0].result_types[2] = .{ .strukt = 0 };
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));
    program.foreign_functions[0].result = .none;
    functions[0].result_types[2] = .none;
    program.foreign_functions[0].parameters = try arena.dupe(defs.ForeignFunction.Parameter, &.{.{
        .parameter_type = .{ .strukt = 1 },
    }});
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));
    program.foreign_functions[0].parameters = &.{};

    // A C-layout row must stay a value struct over the closed field
    // vocabulary: no weak fields, no reference/interface kinds, no
    // field without a C byte form.
    layouts[0].fields[0].field_type = .str;
    try testing.expectError(error.BadStruct, verify_mod.verify(testing.allocator, &program));
    layouts[0].fields[0].field_type = .{ .strukt = 1 };
    try testing.expectError(error.BadStruct, verify_mod.verify(testing.allocator, &program));
    layouts[0].fields[0].field_type = .i32;
    layouts[0].reference = true;
    try testing.expectError(error.BadStruct, verify_mod.verify(testing.allocator, &program));
    layouts[0].reference = false;
    try verify_mod.verify(testing.allocator, &program);
}

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
        .{ .const_integer = 1 },
        .{ .ret = null },
    });
    const result_types = try arena.dupe(types.Type, &.{ .i64, .none });
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
    functions[0].result_types[0] = .i64;

    program.entry_function = 9;
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));
    program.entry_function = 0;
    try verify_mod.verify(testing.allocator, &program);

    functions[0].parameter_count = 1;
    functions[0].locals = try arena.dupe(Local, &.{.{ .name = "arg", .local_type = .i64 }});
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));
    functions[0].parameter_count = 0;
    functions[0].locals = &.{};

    const duplicate = try arena.dupe(Register, &.{ 0, 0, 1 });
    blocks[0].items = duplicate;
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));
    blocks[0].items = items;
    try verify_mod.verify(testing.allocator, &program);
}

test "local storage claims agree with the value representation" {
    var scalar = try programOf(.{
        .instructions = &.{.{ .ret = null }},
        .result_types = &.{.none},
        .blocks = &.{&.{0}},
        .locals = &.{.{ .name = "scalar", .local_type = .i64, .owns_storage = true }},
    });
    defer scalar.deinit();
    try testing.expectError(error.BadLocal, verify_mod.verify(testing.allocator, &scalar));

    scalar.functions[0].locals[0].owns_storage = false;
    scalar.functions[0].locals[0].boxed_storage = true;
    try testing.expectError(error.BadLocal, verify_mod.verify(testing.allocator, &scalar));

    var handle = try programOf(.{
        .instructions = &.{.{ .ret = null }},
        .result_types = &.{.none},
        .blocks = &.{&.{0}},
        .locals = &.{.{ .name = "list", .local_type = .{ .heap = 0 }, .owns_storage = true }},
    });
    defer handle.deinit();
    handle.heap_types = try handle.arena.allocator().dupe(types.HeapType, &.{.{ .list = .i64 }});
    try testing.expectError(error.BadLocal, verify_mod.verify(testing.allocator, &handle));

    handle.functions[0].locals[0].owns_storage = false;
    handle.functions[0].locals[0].boxed_storage = true;
    try testing.expectError(error.BadLocal, verify_mod.verify(testing.allocator, &handle));

    var parameter = try programOf(.{
        .instructions = &.{.{ .ret = null }},
        .result_types = &.{.none},
        .blocks = &.{&.{0}},
        .parameter_count = 1,
        .locals = &.{.{ .name = "text", .local_type = .str, .owns_storage = true }},
    });
    defer parameter.deinit();
    try testing.expectError(error.BadLocal, verify_mod.verify(testing.allocator, &parameter));

    parameter.functions[0].locals[0].owns_storage = false;
    parameter.functions[0].locals[0].boxed_storage = true;
    try testing.expectError(error.BadLocal, verify_mod.verify(testing.allocator, &parameter));

    var optional = try programOf(.{
        .instructions = &.{.{ .ret = null }},
        .result_types = &.{.none},
        .blocks = &.{&.{0}},
        .locals = &.{.{
            .name = "maybe",
            .local_type = .{ .optional = .str },
            .owns_storage = true,
        }},
    });
    defer optional.deinit();
    try verify_mod.verify(testing.allocator, &optional);
    optional.functions[0].locals[0].owns_storage = false;
    optional.functions[0].locals[0].boxed_storage = true;
    try verify_mod.verify(testing.allocator, &optional);
    optional.functions[0].locals[0].owns_storage = true;
    try testing.expectError(error.BadLocal, verify_mod.verify(testing.allocator, &optional));

    var function = try programOf(.{
        .instructions = &.{.{ .ret = null }},
        .result_types = &.{.none},
        .blocks = &.{&.{0}},
        .locals = &.{.{
            .name = "callback",
            .local_type = .{ .function = 0 },
            .owns_storage = true,
        }},
    });
    defer function.deinit();
    function.signatures = try function.arena.allocator().dupe(types.Signature, &.{.{
        .parameters = &.{},
        .result = .none,
    }});
    try verify_mod.verify(testing.allocator, &function);
}

test "weak MIR operations are the only door to weak locals and fields" {
    const optional_list: types.Type = .{ .optional = .{ .heap = 0 } };
    var locals = try programOf(.{
        .instructions = &.{
            .{ .weak_local_get = 0 }, // r0
            .{ .weak_local_set = .{ .local = 0, .value = 0 } }, // r1
            .{ .ret = null }, // r2
        },
        .result_types = &.{ optional_list, .none, .none },
        .blocks = &.{&.{ 0, 1, 2 }},
        .locals = &.{.{ .name = "observed", .local_type = optional_list, .weak = true }},
    });
    defer locals.deinit();
    locals.heap_types = try locals.arena.allocator().dupe(types.HeapType, &.{.{ .list = .i64 }});
    try verify_mod.verify(testing.allocator, &locals);

    locals.functions[0].instructions[0] = .{ .local_get = 0 };
    try testing.expectError(error.BadLocal, verify_mod.verify(testing.allocator, &locals));
    locals.functions[0].instructions[0] = .{ .weak_local_get = 0 };
    locals.functions[0].instructions[1] = .{ .local_set = .{ .local = 0, .value = 0 } };
    try testing.expectError(error.BadLocal, verify_mod.verify(testing.allocator, &locals));
    locals.functions[0].instructions[1] = .{ .weak_local_set = .{ .local = 0, .value = 0 } };

    locals.functions[0].locals[0].weak = false;
    try testing.expectError(error.BadLocal, verify_mod.verify(testing.allocator, &locals));
    locals.functions[0].locals[0].weak = true;
    locals.functions[0].locals[0].owns_storage = true;
    try testing.expectError(error.BadLocal, verify_mod.verify(testing.allocator, &locals));
    locals.functions[0].locals[0].owns_storage = false;
    locals.functions[0].locals[0].inout = true;
    try testing.expectError(error.BadLocal, verify_mod.verify(testing.allocator, &locals));
    locals.functions[0].locals[0].inout = false;
    locals.functions[0].locals[0].local_type = .i64;
    try testing.expectError(error.BadLocal, verify_mod.verify(testing.allocator, &locals));
    locals.functions[0].locals[0].local_type = optional_list;
    locals.heap_types[0] = .handle;
    try testing.expectError(error.BadLocal, verify_mod.verify(testing.allocator, &locals));

    var make_fields = [_]Register{0};
    var fields = try programOf(.{
        .instructions = &.{
            .{ .weak_local_get = 0 }, // r0: logical optional value
            .{ .struct_make = .{ .layout = 0, .fields = &make_fields } }, // r1
            .{ .weak_struct_get = .{ .target = 1, .layout = 0, .field = 0 } }, // r2
            .{ .weak_struct_set = .{ .target = 1, .layout = 0, .field = 0, .value = 2 } }, // r3
            .{ .ret = null }, // r4
        },
        .result_types = &.{ optional_list, .{ .strukt = 0 }, optional_list, .{ .strukt = 0 }, .none },
        .blocks = &.{&.{ 0, 1, 2, 3, 4 }},
        .locals = &.{.{ .name = "observed", .local_type = optional_list, .weak = true }},
    });
    defer fields.deinit();
    const arena = fields.arena.allocator();
    fields.heap_types = try arena.dupe(types.HeapType, &.{.{ .list = .i64 }});
    fields.structs = try arena.dupe(types.StructLayout, &.{.{
        .name = "Observer",
        .fields = try arena.dupe(types.StructField, &.{.{
            .name = "target",
            .field_type = optional_list,
            .weak = true,
        }}),
    }});
    try verify_mod.verify(testing.allocator, &fields);

    fields.functions[0].instructions[2] = .{ .struct_get = .{ .target = 1, .layout = 0, .field = 0 } };
    try testing.expectError(error.BadStruct, verify_mod.verify(testing.allocator, &fields));
    fields.functions[0].instructions[2] = .{ .weak_struct_get = .{ .target = 1, .layout = 0, .field = 0 } };
    fields.functions[0].instructions[3] = .{ .struct_set = .{ .target = 1, .layout = 0, .field = 0, .value = 2 } };
    try testing.expectError(error.BadStruct, verify_mod.verify(testing.allocator, &fields));
    fields.functions[0].instructions[3] = .{ .weak_struct_set = .{
        .target = 1,
        .layout = 0,
        .field = 0,
        .value = 2,
    } };
    fields.structs[0].fields[0].weak = false;
    try testing.expectError(error.BadStruct, verify_mod.verify(testing.allocator, &fields));
    fields.structs[0].fields[0].weak = true;
    fields.structs[0].fields[0].field_type = .i64;
    try testing.expectError(error.BadStruct, verify_mod.verify(testing.allocator, &fields));
}

fn expectForgedResult(program: *Program, register: Register) !void {
    program.functions[0].result_types[register] = .i64;
    try testing.expectError(error.TypeMismatch, verify_mod.verify(testing.allocator, program));
}

test "every no-result MIR instruction rejects a fabricated result type" {
    var local_set = try programOf(.{
        .instructions = &.{
            .{ .const_integer = 1 },
            .{ .local_set = .{ .local = 0, .value = 0 } },
            .{ .ret = null },
        },
        .result_types = &.{ .i64, .none, .none },
        .blocks = &.{&.{ 0, 1, 2 }},
        .locals = &.{.{ .name = "slot", .local_type = .i64 }},
    });
    defer local_set.deinit();
    try verify_mod.verify(testing.allocator, &local_set);
    try expectForgedResult(&local_set, 1);

    var jump = try programOf(.{
        .instructions = &.{.{ .jump = 0 }},
        .result_types = &.{.none},
        .blocks = &.{&.{0}},
    });
    defer jump.deinit();
    try verify_mod.verify(testing.allocator, &jump);
    try expectForgedResult(&jump, 0);

    var branch = try programOf(.{
        .instructions = &.{
            .{ .const_boolean = true },
            .{ .branch = .{ .condition = 0, .then_block = 1, .else_block = 2 } },
            .{ .ret = null },
            .{ .ret = null },
        },
        .result_types = &.{ .boolean, .none, .none, .none },
        .blocks = &.{ &.{ 0, 1 }, &.{2}, &.{3} },
    });
    defer branch.deinit();
    try verify_mod.verify(testing.allocator, &branch);
    try expectForgedResult(&branch, 1);

    var returned = try programOf(.{
        .instructions = &.{.{ .ret = null }},
        .result_types = &.{.none},
        .blocks = &.{&.{0}},
    });
    defer returned.deinit();
    try verify_mod.verify(testing.allocator, &returned);
    try expectForgedResult(&returned, 0);

    var trap = try programOf(.{
        .instructions = &.{.{ .trap = .missing_return }},
        .result_types = &.{.none},
        .blocks = &.{&.{0}},
    });
    defer trap.deinit();
    try verify_mod.verify(testing.allocator, &trap);
    try expectForgedResult(&trap, 0);

    var unwind = try programOf(.{
        .instructions = &.{.{ .unwind = {} }},
        .result_types = &.{.none},
        .blocks = &.{&.{0}},
        .fallible = true,
    });
    defer unwind.deinit();
    try verify_mod.verify(testing.allocator, &unwind);
    try expectForgedResult(&unwind, 0);
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
            .{ .const_integer = 1 },
            .{ .jump = 1 },
            .{ .ret = 0 },
        },
        .result_types = &.{ .i64, .none, .none },
        .blocks = &.{ &.{ 0, 1 }, &.{2} },
        .return_type = .i64,
    });
    defer crossing.deinit();
    try testing.expectError(error.UndefinedRegister, verify_mod.verify(testing.allocator, &crossing));

    // The very same instructions in one block are fine, which is what
    // makes the block boundary — and nothing else — the fault above.
    var together = try programOf(.{
        .instructions = &.{
            .{ .const_integer = 1 },
            .{ .ret = 0 },
        },
        .result_types = &.{ .i64, .none },
        .blocks = &.{&.{ 0, 1 }},
        .return_type = .i64,
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
            .{ .const_integer = 7 }, // r0
            .{ .local_set = .{ .local = 0, .value = 0 } }, // r1
            .{ .jump = 1 }, // r2
            .{ .local_get = 0 }, // r3
            .{ .ret = 3 }, // r4
        },
        .result_types = &.{ .i64, .none, .none, .i64, .none },
        .blocks = &.{ &.{ 0, 1, 2 }, &.{ 3, 4 } },
        .locals = &.{.{ .name = "carried", .local_type = .i64 }},
        .return_type = .i64,
    });
    defer carried.deinit();
    try verify_mod.verify(testing.allocator, &carried);

    // The load claiming a type the slot does not hold.
    carried.functions[0].result_types[3] = .f64;
    try testing.expectError(error.TypeMismatch, verify_mod.verify(testing.allocator, &carried));
    carried.functions[0].result_types[3] = .i64;

    // A local id past the end of the table, on the load and the store
    // alike.
    carried.functions[0].instructions[3] = .{ .local_get = 4 };
    try testing.expectError(error.BadLocal, verify_mod.verify(testing.allocator, &carried));
    carried.functions[0].instructions[3] = .{ .local_get = 0 };
    carried.functions[0].instructions[1] = .{ .local_set = .{ .local = 4, .value = 0 } };
    try testing.expectError(error.BadLocal, verify_mod.verify(testing.allocator, &carried));
    carried.functions[0].instructions[1] = .{ .local_set = .{ .local = 0, .value = 0 } };

    // The store handing the slot a type it cannot hold.
    carried.functions[0].locals[0].local_type = .f64;
    try testing.expectError(error.TypeMismatch, verify_mod.verify(testing.allocator, &carried));
}

test "every block ends in exactly one terminator, wherever the block sits" {
    // A block with no terminator at its end, and a terminator in the
    // middle of one, are different faults with different names — and
    // both must be caught in a *later* block, not only the first.
    var missing = try programOf(.{
        .instructions = &.{
            .{ .jump = 1 }, // r0
            .{ .const_integer = 1 }, // r1: block 1 ends here, on a value
        },
        .result_types = &.{ .none, .i64 },
        .blocks = &.{ &.{0}, &.{1} },
    });
    defer missing.deinit();
    try testing.expectError(error.UnterminatedBlock, verify_mod.verify(testing.allocator, &missing));

    var misplaced = try programOf(.{
        .instructions = &.{
            .{ .jump = 1 }, // r0
            .{ .ret = null }, // r1: a terminator, but not last
            .{ .const_integer = 1 }, // r2
        },
        .result_types = &.{ .none, .none, .i64 },
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
    branching.functions[0].instructions[0] = .{ .const_integer = 1 };
    branching.functions[0].result_types[0] = .i64;
    try testing.expectError(error.TypeMismatch, verify_mod.verify(testing.allocator, &branching));
}

test "one instruction may stand in exactly one block" {
    // Registers are pool indices, so an instruction listed twice would
    // have two definitions and two positions — and `dead`'s compaction
    // would move it under both.  The verifier's `seen` table refuses
    // the repeat whether it is in the same block or a later one.
    var shared = try programOf(.{
        .instructions = &.{
            .{ .const_integer = 1 }, // r0
            .{ .jump = 1 }, // r1
            .{ .ret = null }, // r2
        },
        .result_types = &.{ .i64, .none, .none },
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
            .{ .const_integer = 1 }, // r1
            .{ .ret = null }, // r2
        },
        .result_types = &.{ .i64, .i64, .none },
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
            .{ .const_str = 0 }, // r0
            .{ .intrinsic = .{ .kind = .raise_error, .arguments = &words } }, // r1
            .{ .unwind = {} }, // r2
        },
        .result_types = &.{ .str, .none, .none },
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
    fallible.functions[0].instructions[0] = .{ .const_str = 3 };
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
            .{ .const_str = 0 }, // r0
            .{ .intrinsic = .{ .kind = .print, .arguments = &path } }, // r1: cannot fail
            .{ .intrinsic = .{ .kind = .errored, .arguments = &outcome } }, // r2
            .{ .ret = null }, // r3
        },
        .result_types = &.{ .str, .none, .boolean, .none },
        .blocks = &.{&.{ 0, 1, 2, 3 }},
    });
    defer asking.deinit();
    asking.constants = &.{"a.txt"};
    try testing.expectError(error.BadIntrinsic, verify_mod.verify(testing.allocator, &asking));

    // `file_read` can fail, so the same question is well formed.
    // A value-bearing fallible producer also has to park its answer before
    // branching.  That is the shape the verifier protects, so this fixture
    // supplies the smallest valid two-arm continuation.
    const valid_arena = asking.arena.allocator();
    asking.functions[0].instructions = try valid_arena.dupe(Instruction, &.{
        .{ .const_str = 0 }, // r0
        .{ .intrinsic = .{ .kind = .file_read, .arguments = &path } }, // r1
        .{ .intrinsic = .{ .kind = .errored, .arguments = &outcome } }, // r2
        .{ .local_set = .{ .local = 0, .value = 1 } }, // r3
        .{ .branch = .{ .condition = 2, .then_block = 1, .else_block = 2 } }, // r4
        .{ .ret = null }, // r5
        .{ .ret = null }, // r6
    });
    asking.functions[0].result_types = try valid_arena.dupe(
        types.Type,
        &.{ .str, .str, .boolean, .none, .none, .none, .none },
    );
    asking.functions[0].locals = try valid_arena.dupe(
        Local,
        &.{.{ .name = "answer", .local_type = .str }},
    );
    asking.functions[0].blocks = try valid_arena.dupe(Block, &.{
        .{ .items = try valid_arena.dupe(Register, &.{ 0, 1, 2, 3, 4 }) },
        .{ .items = try valid_arena.dupe(Register, &.{5}) },
        .{ .items = try valid_arena.dupe(Register, &.{6}) },
    });
    try verify_mod.verify(testing.allocator, &asking);

    // `errored` names exactly one instruction.
    asking.functions[0].instructions[2] = .{ .intrinsic = .{ .kind = .errored, .arguments = &twice } };
    try testing.expectError(error.BadIntrinsic, verify_mod.verify(testing.allocator, &asking));

    // Asked across a block boundary: the register it names is not
    // defined here, so there is nothing to ask about.
    const arena = asking.arena.allocator();
    asking.functions[0].instructions = try arena.dupe(Instruction, &.{
        .{ .const_str = 0 }, // r0
        .{ .intrinsic = .{ .kind = .file_read, .arguments = &path } }, // r1
        .{ .jump = 1 }, // r2
        .{ .intrinsic = .{ .kind = .errored, .arguments = &outcome } }, // r3
        .{ .ret = null }, // r4
    });
    asking.functions[0].result_types = try arena.dupe(
        types.Type,
        &.{ .str, .str, .none, .boolean, .none },
    );
    asking.functions[0].blocks = try arena.dupe(Block, &.{
        .{ .items = try arena.dupe(Register, &.{ 0, 1, 2 }) },
        .{ .items = try arena.dupe(Register, &.{ 3, 4 }) },
    });
    try testing.expectError(error.BadIntrinsic, verify_mod.verify(testing.allocator, &asking));
}

test "a fallible producer must be observed before control continues" {
    var program: Program = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer program.deinit();
    const arena = program.arena.allocator();

    const functions = try arena.alloc(Function, 2);
    functions[0] = .{
        .name = "main",
        .parameter_count = 0,
        .return_type = .none,
        .fallible = true,
        .locals = &.{},
        .instructions = try arena.dupe(Instruction, &.{
            .{ .call = .{ .function = 1, .arguments = &.{} } },
            .{ .ret = null },
        }),
        .result_types = try arena.dupe(types.Type, &.{ .none, .none }),
        .blocks = try arena.dupe(Block, &.{
            .{ .items = try arena.dupe(Register, &.{ 0, 1 }) },
        }),
    };
    functions[1] = .{
        .name = "worker",
        .parameter_count = 0,
        .return_type = .none,
        .fallible = true,
        .locals = &.{},
        .instructions = try arena.dupe(Instruction, &.{.{ .unwind = {} }}),
        .result_types = try arena.dupe(types.Type, &.{.none}),
        .blocks = try arena.dupe(Block, &.{
            .{ .items = try arena.dupe(Register, &.{0}) },
        }),
    };
    program.functions = functions;

    // A fallible call that falls through to a return has no outcome
    // consumer.  The compiled path would read an unwritten result slot;
    // the interpreter would continue with the call's stale register.
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));

    const asked = try arena.dupe(Register, &.{0});
    functions[0].instructions = try arena.dupe(Instruction, &.{
        .{ .call = .{ .function = 1, .arguments = &.{} } },
        .{ .intrinsic = .{ .kind = .errored, .arguments = asked } },
        .{ .branch = .{ .condition = 1, .then_block = 1, .else_block = 2 } },
        .{ .ret = null },
        .{ .unwind = {} },
    });
    functions[0].result_types = try arena.dupe(types.Type, &.{ .none, .boolean, .none, .none, .none });
    functions[0].blocks = try arena.dupe(Block, &.{
        .{ .items = try arena.dupe(Register, &.{ 0, 1, 2 }) },
        .{ .items = try arena.dupe(Register, &.{3}) },
        .{ .items = try arena.dupe(Register, &.{4}) },
    });
    try verify_mod.verify(testing.allocator, &program);

    // A value-bearing fallible call parks its answer in one local between
    // the outcome query and the branch.  Keep that second legal shape
    // explicit so the backstop does not accidentally require a void call.
    functions[0].locals = try arena.dupe(Local, &.{.{
        .name = "answer",
        .local_type = .i64,
    }});
    functions[0].instructions = try arena.dupe(Instruction, &.{
        .{ .call = .{ .function = 1, .arguments = &.{} } },
        .{ .intrinsic = .{ .kind = .errored, .arguments = asked } },
        .{ .local_set = .{ .local = 0, .value = 0 } },
        .{ .branch = .{ .condition = 1, .then_block = 1, .else_block = 2 } },
        .{ .ret = null },
        .{ .unwind = {} },
    });
    functions[0].result_types = try arena.dupe(types.Type, &.{ .i64, .boolean, .none, .none, .none, .none });
    functions[0].blocks = try arena.dupe(Block, &.{
        .{ .items = try arena.dupe(Register, &.{ 0, 1, 2, 3 }) },
        .{ .items = try arena.dupe(Register, &.{4}) },
        .{ .items = try arena.dupe(Register, &.{5}) },
    });
    functions[1].return_type = .i64;
    functions[1].instructions = try arena.dupe(Instruction, &.{.{ .trap = .missing_return }});
    try verify_mod.verify(testing.allocator, &program);

    // The same invariant covers a fallible intrinsic, not only a user
    // function call.  This malformed file read has no `errored` query.
    var io_argument = [_]Register{0};
    var unobserved_io = try programOf(.{
        .instructions = &.{
            .{ .const_str = 0 },
            .{ .intrinsic = .{ .kind = .file_read, .arguments = &io_argument } },
            .{ .ret = null },
        },
        .result_types = &.{ .str, .str, .none },
        .blocks = &.{&.{ 0, 1, 2 }},
        .fallible = true,
    });
    defer unobserved_io.deinit();
    unobserved_io.constants = &.{"path"};
    try testing.expectError(error.BadIntrinsic, verify_mod.verify(testing.allocator, &unobserved_io));
}

test "a call agrees with the callee it names, argument for argument" {
    var program: Program = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer program.deinit();
    const arena = program.arena.allocator();

    const functions = try arena.alloc(Function, 2);
    const arguments = try arena.dupe(Register, &.{0});
    // f0: main — calls f1 with one i64.
    functions[0] = .{
        .name = "main",
        .parameter_count = 0,
        .return_type = .none,
        .locals = &.{},
        .instructions = try arena.dupe(Instruction, &.{
            .{ .const_integer = 1 }, // r0
            .{ .call = .{ .function = 1, .arguments = arguments } }, // r1
            .{ .ret = null }, // r2
        }),
        .result_types = try arena.dupe(types.Type, &.{ .i64, .i64, .none }),
        .blocks = try arena.dupe(Block, &.{
            .{ .items = try arena.dupe(Register, &.{ 0, 1, 2 }) },
        }),
    };
    // f1: twice(value: i64) -> i64
    functions[1] = .{
        .name = "twice",
        .parameter_count = 1,
        .return_type = .i64,
        .locals = try arena.dupe(Local, &.{.{ .name = "value", .local_type = .i64 }}),
        .instructions = try arena.dupe(Instruction, &.{
            .{ .local_get = 0 }, // r0
            .{ .ret = 0 }, // r1
        }),
        .result_types = try arena.dupe(types.Type, &.{ .i64, .none }),
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
    functions[0].instructions[0] = .{ .const_float = 1.0 };
    functions[0].result_types[0] = .f64;
    try testing.expectError(error.TypeMismatch, verify_mod.verify(testing.allocator, &program));
    functions[0].instructions[0] = .{ .const_integer = 1 };
    functions[0].result_types[0] = .i64;

    // The call's own result must be what the callee returns.
    functions[0].result_types[1] = .f64;
    try testing.expectError(error.TypeMismatch, verify_mod.verify(testing.allocator, &program));
    functions[0].result_types[1] = .i64;
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
    functions[1].return_type = .f64;
    try testing.expectError(error.TypeMismatch, verify_mod.verify(testing.allocator, &program));
}

test "an inout call aliases exactly local zero and cannot use another call lane" {
    var program: Program = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer program.deinit();
    const arena = program.arena.allocator();
    const one_argument = try arena.dupe(Register, &.{0});

    const functions = try arena.alloc(Function, 2);
    functions[0] = .{
        .name = "main",
        .parameter_count = 0,
        .return_type = .none,
        .locals = try arena.dupe(Local, &.{.{ .name = "value", .local_type = .i64 }}),
        .instructions = try arena.dupe(Instruction, &.{
            .{ .const_integer = 4 },
            .{ .local_set = .{ .local = 0, .value = 0 } },
            .{ .call_inout = .{ .function = 1, .receiver = 0, .arguments = &.{} } },
            .{ .ret = null },
        }),
        .result_types = try arena.dupe(types.Type, &.{ .i64, .none, .none, .none }),
        .blocks = try arena.dupe(Block, &.{
            .{ .items = try arena.dupe(Register, &.{ 0, 1, 2, 3 }) },
        }),
    };
    functions[1] = .{
        .name = "bump",
        .parameter_count = 1,
        .return_type = .none,
        .locals = try arena.dupe(Local, &.{.{
            .name = "self",
            .local_type = .i64,
            .inout = true,
        }}),
        .instructions = try arena.dupe(Instruction, &.{
            .{ .local_get = 0 },
            .{ .const_integer = 1 },
            .{ .binary = .{ .op = .add, .operand_type = .i64, .left = 0, .right = 1 } },
            .{ .local_set = .{ .local = 0, .value = 2 } },
            .{ .ret = null },
        }),
        .result_types = try arena.dupe(types.Type, &.{ .i64, .i64, .i64, .none, .none }),
        .blocks = try arena.dupe(Block, &.{
            .{ .items = try arena.dupe(Register, &.{ 0, 1, 2, 3, 4 }) },
        }),
    };
    program.functions = functions;
    try verify_mod.verify(testing.allocator, &program);

    // The callee, not the call site's spelling, declares the lane.
    functions[1].locals[0].inout = false;
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));
    functions[1].locals[0].inout = true;

    // A plain call cannot copy an inout receiver in as an argument.
    functions[0].instructions[2] = .{ .call = .{ .function = 1, .arguments = one_argument } };
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));
    functions[0].instructions[2] = .{ .call_inout = .{
        .function = 1,
        .receiver = 0,
        .arguments = &.{},
    } };

    // Nor may the method cross a thread boundary.
    program.heap_types = try arena.dupe(types.HeapType, &.{.{
        .task = .{ .result = .none, .fallible = false },
    }});
    functions[0].instructions[2] = .{ .spawn = .{ .function = 1, .arguments = one_argument } };
    functions[0].result_types[2] = .{ .heap = 0 };
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));
    functions[0].result_types[2] = .none;

    // A function value is the indirect-call door. Naming an inout
    // function is refused before that door can be opened.
    program.signatures = try arena.dupe(types.Signature, &.{.{
        .parameters = try arena.dupe(types.Signature.Parameter, &.{.{ .value_type = .i64 }}),
        .result = .none,
    }});
    functions[0].instructions[2] = .{ .const_function = .{ .function = 1 } };
    functions[0].result_types[2] = .{ .function = 0 };
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));
    functions[0].result_types[2] = .none;
    functions[0].instructions[2] = .{ .call_inout = .{
        .function = 1,
        .receiver = 0,
        .arguments = &.{},
    } };

    // The pointer representation on both sides must agree: owning
    // struct slots hold a boxed Value, while ordinary slots hold their
    // register shape directly.
    functions[1].locals[0].owns_storage = true;
    try testing.expectError(error.BadLocal, verify_mod.verify(testing.allocator, &program));
    functions[1].locals[0].owns_storage = false;

    // Inout is parameter zero or it is malformed frame metadata.
    const original_locals = functions[1].locals;
    functions[1].locals = try arena.dupe(Local, &.{
        original_locals[0],
        .{ .name = "other", .local_type = .i64, .inout = true },
    });
    try testing.expectError(error.BadLocal, verify_mod.verify(testing.allocator, &program));
    functions[1].locals = original_locals;
    try verify_mod.verify(testing.allocator, &program);
}

test "spawn rejects worker parameters carrying functions, resources, or weak storage" {
    var program: Program = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer program.deinit();
    const arena = program.arena.allocator();

    const functions = try arena.alloc(Function, 2);
    const arguments = try arena.dupe(Register, &.{0});
    functions[0] = .{
        .name = "main",
        .parameter_count = 0,
        .return_type = .none,
        .locals = &.{},
        .instructions = try arena.dupe(Instruction, &.{
            .{ .heap_new = .{ .heap = 1, .dims = &.{} } },
            .{ .spawn = .{ .function = 1, .arguments = arguments } },
            .{ .ret = null },
        }),
        .result_types = try arena.dupe(types.Type, &.{ .{ .heap = 1 }, .{ .heap = 0 }, .none }),
        .blocks = try arena.dupe(Block, &.{
            .{ .items = try arena.dupe(Register, &.{ 0, 1, 2 }) },
        }),
    };
    functions[1] = .{
        .name = "worker",
        .parameter_count = 1,
        .return_type = .none,
        .locals = try arena.dupe(Local, &.{.{
            .name = "value",
            .local_type = .{ .heap = 1 },
        }}),
        .instructions = try arena.dupe(Instruction, &.{.{ .trap = .missing_return }}),
        .result_types = try arena.dupe(types.Type, &.{.none}),
        .blocks = try arena.dupe(Block, &.{
            .{ .items = try arena.dupe(Register, &.{0}) },
        }),
    };
    program.functions = functions;
    program.signatures = try arena.dupe(types.Signature, &.{.{
        .parameters = &.{},
        .result = .none,
    }});
    program.heap_types = try arena.dupe(types.HeapType, &.{
        .{ .task = .{ .result = .none, .fallible = false } },
        .{ .list = .{ .optional = .{ .function = 0 } } },
        .handle,
    });

    // A function value can borrow a receiver, even when it is nested in
    // an otherwise ordinary list.  The source boundary refuses that
    // whole graph before MIR is written; a decoded module must not make
    // the worker runtime cross it by omission.
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));

    // The same boundary applies to resources.  Keep the list shape so
    // this proves the walk is transitive rather than only checking a
    // direct file/task parameter.
    program.heap_types[1] = .{ .list = .{ .heap = 2 } };
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));

    // A weak handle is meaningful only in the runtime whose generation
    // table created it.  Nest one inside an otherwise copyable list so a
    // decoded module must prove the complete parameter graph.
    program.structs = try arena.dupe(types.StructLayout, &.{.{
        .name = "Observer",
        .fields = try arena.dupe(types.StructField, &.{.{
            .name = "target",
            .field_type = .{ .optional = .{ .heap = 1 } },
            .weak = true,
        }}),
    }});
    program.heap_types[1] = .{ .list = .{ .strukt = 0 } };
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));
}

test "spawn rejects worker results carrying functions, resources, or weak storage" {
    var program: Program = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer program.deinit();
    const arena = program.arena.allocator();

    const functions = try arena.alloc(Function, 2);
    functions[0] = .{
        .name = "main",
        .parameter_count = 0,
        .return_type = .none,
        .locals = &.{},
        .instructions = try arena.dupe(Instruction, &.{
            .{ .spawn = .{ .function = 1, .arguments = &.{} } },
            .{ .ret = null },
        }),
        .result_types = try arena.dupe(types.Type, &.{ .{ .heap = 0 }, .none }),
        .blocks = try arena.dupe(Block, &.{
            .{ .items = try arena.dupe(Register, &.{ 0, 1 }) },
        }),
    };
    functions[1] = .{
        .name = "worker",
        .parameter_count = 0,
        .return_type = .{ .heap = 1 },
        .locals = &.{},
        .instructions = try arena.dupe(Instruction, &.{.{ .trap = .missing_return }}),
        .result_types = try arena.dupe(types.Type, &.{.none}),
        .blocks = try arena.dupe(Block, &.{
            .{ .items = try arena.dupe(Register, &.{0}) },
        }),
    };
    program.functions = functions;
    program.signatures = try arena.dupe(types.Signature, &.{.{
        .parameters = &.{},
        .result = .none,
    }});
    program.heap_types = try arena.dupe(types.HeapType, &.{
        .{ .task = .{ .result = .{ .heap = 1 }, .fallible = false } },
        .{ .list = .{ .optional = .{ .function = 0 } } },
        .handle,
    });

    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));

    // A returned resource is just as invalid as a resource argument: the
    // wait would have to re-own a file or task made by another runtime.
    program.heap_types[1] = .{ .list = .{ .heap = 2 } };
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));

    program.structs = try arena.dupe(types.StructLayout, &.{.{
        .name = "Observer",
        .fields = try arena.dupe(types.StructField, &.{.{
            .name = "target",
            .field_type = .{ .optional = .{ .heap = 1 } },
            .weak = true,
        }}),
    }});
    program.heap_types[1] = .{ .list = .{ .strukt = 0 } };
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));
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
    heap_types[0] = .{ .list = .i64 };
    program.heap_types = heap_types;
    try verify_mod.verify(testing.allocator, &program);

    // Resource rows are made only by file-open and worker-spawn.  A
    // decoded module may name their table rows, but `heap_new` has no
    // valid resource constructor in either engine.
    heap_types[0] = .handle;
    try testing.expectError(error.BadIntrinsic, verify_mod.verify(testing.allocator, &program));
    heap_types[0] = .{ .task = .{ .result = .i64, .fallible = false } };
    try testing.expectError(error.BadIntrinsic, verify_mod.verify(testing.allocator, &program));

    // A map keyed by something that cannot be a key.
    heap_types[0] = .{ .map = .{ .key = .f64, .value = .i64 } };
    try testing.expectError(error.BadStruct, verify_mod.verify(testing.allocator, &program));

    // An array with no axes, and one with more than the four the
    // language spells.
    heap_types[0] = .{ .array = .{ .element = .i64, .rank = 0 } };
    try testing.expectError(error.BadStruct, verify_mod.verify(testing.allocator, &program));
    heap_types[0] = .{ .array = .{ .element = .i64, .rank = 5 } };
    try testing.expectError(error.BadStruct, verify_mod.verify(testing.allocator, &program));

    // A rank the `heap_new` supplies no sizes for.
    heap_types[0] = .{ .array = .{ .element = .i64, .rank = 2 } };
    try testing.expectError(error.BadStruct, verify_mod.verify(testing.allocator, &program));

    // An element type naming a struct row that is not there.
    heap_types[0] = .{ .list = .{ .strukt = 3 } };
    try testing.expectError(error.BadStruct, verify_mod.verify(testing.allocator, &program));

    // And what `heap_new` answers must be the row it allocated.
    heap_types[0] = .{ .list = .i64 };
    program.functions[0].result_types[0] = .{ .heap = 1 };
    try testing.expectError(error.BadStruct, verify_mod.verify(testing.allocator, &program));
}

test "every function signature and function type index is bounded" {
    var program = try programOf(.{
        .instructions = &.{.{ .ret = null }},
        .result_types = &.{.none},
        .blocks = &.{&.{0}},
    });
    defer program.deinit();
    const arena = program.arena.allocator();

    // The second row is deliberately unused.  It is still part of the
    // decoded type table, so its parameter and result must be safe to
    // inspect independently of whether an instruction names the row.
    const nested_parameters = try arena.dupe(types.Signature.Parameter, &.{.{
        .value_type = .{ .function = 0 },
    }});
    const signatures = try arena.dupe(types.Signature, &.{
        .{ .parameters = &.{}, .result = .none },
        .{ .parameters = nested_parameters, .result = .{ .function = 0 } },
    });
    program.signatures = signatures;
    try verify_mod.verify(testing.allocator, &program);

    nested_parameters[0].value_type = .{ .function = 2 };
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));
    nested_parameters[0].value_type = .{ .function = 0 };

    signatures[1].result = .{ .function = 2 };
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));
    signatures[1].result = .{ .function = 0 };

    // Types outside the signature table use the same bound.  This local
    // is never read, which is exactly why an instruction-local check is
    // not sufficient.
    program.functions[0].locals = try arena.dupe(Local, &.{.{
        .name = "unused",
        .local_type = .{ .function = 2 },
    }});
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));
}

test "recursive heap and function type tables are rejected before names render" {
    var program = try programOf(.{
        .instructions = &.{.{ .ret = null }},
        .result_types = &.{.none},
        .blocks = &.{&.{0}},
    });
    defer program.deinit();
    const arena = program.arena.allocator();

    // A signature directly naming itself has no finite spelling.
    program.signatures = try arena.dupe(types.Signature, &.{.{
        .parameters = try arena.dupe(types.Signature.Parameter, &.{.{
            .value_type = .{ .function = 0 },
        }}),
        .result = .none,
    }});
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));

    // Nor do two otherwise-bounded signature rows naming each other.
    program.signatures = try arena.dupe(types.Signature, &.{
        .{ .parameters = &.{}, .result = .{ .function = 1 } },
        .{ .parameters = &.{}, .result = .{ .function = 0 } },
    });
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));

    // Heap rows render recursively too, both alone and through a
    // function signature, so they belong to the same graph.
    program.signatures = &.{};
    program.heap_types = try arena.dupe(types.HeapType, &.{.{ .list = .{ .heap = 0 } }});
    try testing.expectError(error.BadStruct, verify_mod.verify(testing.allocator, &program));

    // Optional heap payloads render the same anonymous row after the
    // question mark, so they cannot hide the cycle either.
    program.heap_types[0] = .{ .list = .{ .optional = .{ .heap = 0 } } };
    try testing.expectError(error.BadStruct, verify_mod.verify(testing.allocator, &program));

    // A function value reaches a list as `(func(...) -> R)?` and in no
    // other spelling (docs/BINDING.md D7 — a bare function type is not
    // an element type, and the table check above refuses one), so the
    // cycle is written through the optional the language can actually
    // produce.
    program.heap_types = try arena.dupe(types.HeapType, &.{.{ .list = .{ .optional = .{ .function = 0 } } }});
    program.signatures = try arena.dupe(types.Signature, &.{.{
        .parameters = &.{},
        .result = .{ .heap = 0 },
    }});
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));

    // A named struct is a printed leaf.  The legal recursive-data
    // spelling `Node` through `list[Node]` must not be mistaken for a
    // recursively expanded anonymous type.
    program.signatures = &.{};
    program.heap_types = try arena.dupe(types.HeapType, &.{.{ .list = .{ .strukt = 0 } }});
    program.structs = try arena.dupe(types.StructLayout, &.{.{
        .name = "Node",
        .fields = try arena.dupe(types.StructField, &.{.{
            .name = "children",
            .field_type = .{ .heap = 0 },
        }}),
    }});
    try verify_mod.verify(testing.allocator, &program);
}

test "bare function fields require whole-object or compiler-owned storage" {
    var program = try programOf(.{
        .instructions = &.{.{ .ret = null }},
        .result_types = &.{.none},
        .blocks = &.{&.{0}},
    });
    defer program.deinit();
    const arena = program.arena.allocator();
    program.signatures = try arena.dupe(types.Signature, &.{.{
        .parameters = &.{},
        .result = .none,
    }});

    const struct_fields = try arena.dupe(types.StructField, &.{.{
        .name = "callback",
        .field_type = .{ .function = 0 },
    }});
    program.structs = try arena.dupe(types.StructLayout, &.{.{
        .name = "Button",
        .fields = struct_fields,
    }});
    try testing.expectError(error.BadStruct, verify_mod.verify(testing.allocator, &program));

    // The optional wrapper is the ratified stored representation: its
    // absence is a real zero, and a later narrowing operation obtains the
    // function value.  It must remain accepted while the bare spelling is
    // refused.
    struct_fields[0].field_type = .{ .optional = .{ .function = 0 } };
    try verify_mod.verify(testing.allocator, &program);

    // A closure environment is private compiler storage. It may hold the
    // function value directly, but only when it is also an ARC reference
    // layout; a value-shaped forged environment does not inherit this
    // exception.
    struct_fields[0].field_type = .{ .function = 0 };
    program.structs[0].closure_storage = true;
    try testing.expectError(error.BadStruct, verify_mod.verify(testing.allocator, &program));
    program.structs[0].reference = true;
    try verify_mod.verify(testing.allocator, &program);

    // An ordinary class has the same sound storage property: its nullable
    // handle is the zero, and construction installs the object as a whole.
    // This is what permits a custom initializer to supply a required callback.
    program.structs[0].closure_storage = false;
    try verify_mod.verify(testing.allocator, &program);
    program.structs[0].reference = false;
    try testing.expectError(error.BadStruct, verify_mod.verify(testing.allocator, &program));

    // An interface is the other compiler-owned whole-object layout. Its
    // witness slots live in the static method table, not in source-addressable
    // fields; the existential remains a value layout and weak storage cannot
    // be forged into it.
    program.structs[0].fields = &.{};
    program.structs[0].interface_methods = try arena.dupe(types.InterfaceMethod, &.{.{
        .name = "callback",
        .signature = 0,
    }});
    program.structs[0].interface = true;
    try verify_mod.verify(testing.allocator, &program);
    program.structs[0].reference = true;
    try testing.expectError(error.BadStruct, verify_mod.verify(testing.allocator, &program));
    program.structs[0].reference = false;
    program.structs[0].fields = try arena.dupe(types.StructField, &.{.{
        .name = "forged",
        .weak = true,
        .field_type = .i64,
    }});
    try testing.expectError(error.BadStruct, verify_mod.verify(testing.allocator, &program));
    program.structs[0].fields = &.{};
    program.structs[0].interface = false;

    const member_fields = try arena.dupe(types.StructField, &.{.{
        .name = "callback",
        .field_type = .{ .function = 0 },
    }});
    const members = try arena.dupe(types.VariantMember, &.{.{
        .name = "event",
        .fields = member_fields,
    }});
    program.structs = &.{};
    program.variants = try arena.dupe(types.VariantType, &.{.{
        .name = "Event",
        .members = members,
    }});
    try testing.expectError(error.BadStruct, verify_mod.verify(testing.allocator, &program));

    member_fields[0].field_type = .{ .optional = .{ .function = 0 } };
    try verify_mod.verify(testing.allocator, &program);
}

test "map values cannot be optional while bare function values remain legal" {
    var program = try programOf(.{
        .instructions = &.{.{ .ret = null }},
        .result_types = &.{.none},
        .blocks = &.{&.{0}},
    });
    defer program.deinit();
    const arena = program.arena.allocator();
    program.signatures = try arena.dupe(types.Signature, &.{.{
        .parameters = &.{},
        .result = .none,
    }});
    program.heap_types = try arena.dupe(types.HeapType, &.{.{ .map = .{
        .key = .i64,
        .value = .{ .optional = .i64 },
    } }});

    // `get` adds the missing-key absence itself, so a decoded map row
    // cannot smuggle in a second optional layer.
    try testing.expectError(error.BadStruct, verify_mod.verify(testing.allocator, &program));

    // The special function-value rule is narrower: a bare function is
    // a legal map value because the entry exists only after `put`, and
    // `get` supplies its optional wrapper.  Keep that valid distinction
    // pinned while refusing every explicitly optional map value.
    program.heap_types[0] = .{ .map = .{
        .key = .i64,
        .value = .{ .function = 0 },
    } };
    try verify_mod.verify(testing.allocator, &program);

    program.heap_types[0] = .{ .map = .{
        .key = .i64,
        .value = .{ .optional = .{ .function = 0 } },
    } };
    try testing.expectError(error.BadStruct, verify_mod.verify(testing.allocator, &program));
}

test "a function's integer storage is not a numeric conversion" {
    var program = try programOf(.{
        .instructions = &.{
            .{ .const_function = .{ .function = 0 } }, // r0
            .{ .const_integer = 0 }, // r1, made a convert below
            .{ .ret = null }, // r2
        },
        .result_types = &.{ .{ .function = 0 }, .i32, .none },
        .blocks = &.{&.{ 0, 1, 2 }},
    });
    defer program.deinit();
    program.signatures = try program.arena.allocator().dupe(types.Signature, &.{.{
        .parameters = &.{},
        .result = .none,
    }});

    // The function constant and signature are otherwise a valid module:
    // main itself has the `func()` shape the constant claims.
    try verify_mod.verify(testing.allocator, &program);
    program.functions[0].instructions[1] = .{ .convert = 0 };
    try testing.expectError(error.TypeMismatch, verify_mod.verify(testing.allocator, &program));
}

test "an intrinsic is checked for its own arity and operand types" {
    var of = [_]Register{0};
    var seven = [_]Register{ 0, 0, 0, 0, 0, 0, 0 };
    var program = try programOf(.{
        .instructions = &.{
            .{ .const_float = 4.0 }, // r0
            .{ .intrinsic = .{ .kind = .sqrt, .arguments = &of } }, // r1
            .{ .ret = null }, // r2
        },
        .result_types = &.{ .f64, .f64, .none },
        .blocks = &.{&.{ 0, 1, 2 }},
    });
    defer program.deinit();
    try verify_mod.verify(testing.allocator, &program);

    // Every explicit width is a computation width. The verifier must
    // accept the narrowest float for float-only math and the narrowest
    // integer for width-preserving scalar math.
    program.functions[0].result_types[0] = .f16;
    program.functions[0].result_types[1] = .f16;
    try verify_mod.verify(testing.allocator, &program);
    program.functions[0].instructions[0] = .{ .const_integer = 4 };
    program.functions[0].instructions[1].intrinsic.kind = .abs;
    program.functions[0].result_types[0] = .i8;
    program.functions[0].result_types[1] = .i8;
    try verify_mod.verify(testing.allocator, &program);

    program.functions[0].instructions[0] = .{ .const_float = 4.0 };
    program.functions[0].instructions[1].intrinsic.kind = .sqrt;
    program.functions[0].result_types[0] = .f64;
    program.functions[0].result_types[1] = .f64;

    // Too few arguments for what it does.
    program.functions[0].instructions[1].intrinsic.arguments = of[0..0];
    try testing.expectError(error.BadIntrinsic, verify_mod.verify(testing.allocator, &program));

    // More than this intrinsic takes. Operand collection has no fixed
    // ceiling; the intrinsic's own signature is what refuses the call.
    program.functions[0].instructions[1].intrinsic.arguments = &seven;
    try testing.expectError(error.BadIntrinsic, verify_mod.verify(testing.allocator, &program));

    // The right arity and a float operand, but not the width the
    // result claims: `sqrt` answers whichever float it was handed
    // (docs/TYPES.md §9), so a `f32` in and a `f64` out is a
    // module that disagrees with itself.
    program.functions[0].instructions[1].intrinsic.arguments = &of;
    program.functions[0].result_types[0] = .f32;
    try testing.expectError(error.TypeMismatch, verify_mod.verify(testing.allocator, &program));

    // The right arity and no float anywhere.  That is not a width
    // mistake and does not answer as one: there is no `sqrt` of a
    // `i64` for the widths to disagree about.
    program.functions[0].instructions[0] = .{ .const_integer = 4 };
    program.functions[0].result_types[0] = .i64;
    try testing.expectError(error.BadIntrinsic, verify_mod.verify(testing.allocator, &program));
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
        &.{.{ .name = "argument", .local_type = .i64 }},
    );
    try testing.expectError(error.BadFunction, verify_mod.verify(testing.allocator, &program));
    program.functions[0].parameter_count = 0;
    program.functions[0].locals = &.{};
}

test "the side tables are exactly as long as the instruction pool" {
    var program = try programOf(.{
        .instructions = &.{
            .{ .const_integer = 1 }, // r0
            .{ .ret = null }, // r1
        },
        .result_types = &.{ .i64, .none },
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

test "every explicit numeric width computes at its own width" {
    var program = try programOf(.{
        .instructions = &.{
            .{ .const_integer = 3 }, // r0
            .{ .const_integer = 4 }, // r1
            .{ .binary = .{ .op = .add, .operand_type = .i32, .left = 0, .right = 1 } }, // r2
            .{ .ret = 2 }, // r3
        },
        .result_types = &.{ .i32, .i32, .i32, .none },
        .blocks = &.{&.{ 0, 1, 2, 3 }},
        .locals = &.{},
        .return_type = .i32,
    });
    defer program.deinit();

    for ([_]types.Type{ .u8, .u16, .u32, .u64, .i8, .i16, .i32, .i64 }) |numeric| {
        program.functions[0].result_types[0] = numeric;
        program.functions[0].result_types[1] = numeric;
        program.functions[0].result_types[2] = numeric;
        program.functions[0].return_type = numeric;
        program.functions[0].instructions[0] = .{ .const_integer = 3 };
        program.functions[0].instructions[1] = .{ .const_integer = 4 };
        program.functions[0].instructions[2] =
            .{ .binary = .{ .op = .add, .operand_type = numeric, .left = 0, .right = 1 } };
        try verify_mod.verify(testing.allocator, &program);

        program.functions[0].result_types[2] = .boolean;
        program.functions[0].return_type = .boolean;
        program.functions[0].instructions[2] =
            .{ .binary = .{ .op = .less, .operand_type = numeric, .left = 0, .right = 1 } };
        try verify_mod.verify(testing.allocator, &program);

        program.functions[0].result_types[2] = numeric;
        program.functions[0].return_type = numeric;
        program.functions[0].instructions[2] =
            .{ .unary = .{ .op = .bit_not, .operand = 0 } };
        try verify_mod.verify(testing.allocator, &program);

        program.functions[0].instructions[2] =
            .{ .unary = .{ .op = .negate, .operand = 0 } };
        if (numeric.isUnsigned()) {
            try testing.expectError(
                error.TypeMismatch,
                verify_mod.verify(testing.allocator, &program),
            );
        } else {
            try verify_mod.verify(testing.allocator, &program);
        }

        // Integer `/` is never an integer instruction: source lowering
        // converts both operands to f64 before it emits real division.
        program.functions[0].instructions[2] =
            .{ .binary = .{ .op = .divide, .operand_type = numeric, .left = 0, .right = 1 } };
        try testing.expectError(
            error.TypeMismatch,
            verify_mod.verify(testing.allocator, &program),
        );
    }

    for ([_]types.Type{ .f16, .f32, .f64 }) |numeric| {
        program.functions[0].result_types[0] = numeric;
        program.functions[0].result_types[1] = numeric;
        program.functions[0].result_types[2] = numeric;
        program.functions[0].return_type = numeric;
        program.functions[0].instructions[0] = .{ .const_float = 3.0 };
        program.functions[0].instructions[1] = .{ .const_float = 4.0 };
        program.functions[0].instructions[2] =
            .{ .binary = .{ .op = .add, .operand_type = numeric, .left = 0, .right = 1 } };
        try verify_mod.verify(testing.allocator, &program);

        program.functions[0].result_types[2] = .boolean;
        program.functions[0].return_type = .boolean;
        program.functions[0].instructions[2] =
            .{ .binary = .{ .op = .less, .operand_type = numeric, .left = 0, .right = 1 } };
        try verify_mod.verify(testing.allocator, &program);

        program.functions[0].result_types[2] = numeric;
        program.functions[0].return_type = numeric;
        program.functions[0].instructions[2] =
            .{ .unary = .{ .op = .negate, .operand = 0 } };
        try verify_mod.verify(testing.allocator, &program);
    }
}
