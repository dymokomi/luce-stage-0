//! Dead-code elimination for the IR.
//! Drops every function unreachable from the entry point.

const std = @import("std");
const defs = @import("../06_mir/defs.zig");

const Allocator = std.mem.Allocator;
const Function = defs.Function;
const Program = defs.Program;
const Instruction = defs.Instruction;
const Register = defs.Register;

/// Drop every function unreachable from the entry.
///
/// Std modules arrive whole: `import strings` brings eighteen
/// functions where a program may call three, and each one is
/// otherwise encoded into the `.lcm`, decoded by `luce`, and compiled to
/// machine code — the largest single cost in a short program's run
/// (docs/PIPELINE.md, stage 9).  This is the dead-code elimination a compiled
/// language is expected to do, and it belongs here, in the compiler,
/// so the artifact itself is smaller and everything downstream of it
/// gets faster.
///
/// Call targets and the entry are the only function references in the
/// IR, so remapping is a renumber.  Call on verified programs only —
/// the compiler verifies before pruning (an analyzer bug surfaces as
/// a diagnostic, not an index panic here) and again after (proving
/// the renumbering).  `optimize.run` compacts the two constant pools
/// after this pass and the instruction compactor have settled the
/// surviving block items.  Struct layouts and heap-type rows stay;
/// scratch and dead memory stay in the program arena until deinit —
/// the artifact is what gets smaller, not the resident compiler.
pub fn prune(arena: Allocator, program: *Program) Allocator.Error!void {
    const count = program.functions.len;
    if (count == 0) return;

    const reachable = try arena.alloc(bool, count);
    @memset(reachable, false);
    var pending: std.ArrayList(u32) = .empty;
    reachable[program.entry_function] = true;
    try pending.append(arena, program.entry_function);
    while (pending.pop()) |index| {
        for (program.functions[index].instructions) |instruction| {
            const called = switch (instruction) {
                .call, .spawn => |call| call.function,
                .call_inout => |call| call.function,
                // **Naming a function reaches it.**  A function value
                // is a call that has not happened yet, and the call
                // that will happen is a `call_indirect` naming no
                // function at all — so if this arm were missing, a
                // comparator passed to `sort_by` would be pruned out
                // from under the value that names it
                // (docs/FUNCTIONS.md D2).
                .const_function => |named| named,
                else => continue,
            };
            if (reachable[called]) continue;
            reachable[called] = true;
            try pending.append(arena, called);
        }
    }

    var kept: u32 = 0;
    const renumbered = try arena.alloc(u32, count);
    for (reachable, renumbered) |live, *slot| {
        if (!live) continue;
        slot.* = kept;
        kept += 1;
    }
    if (kept == count) return;

    const functions = try arena.alloc(Function, kept);
    for (reachable, 0..) |live, index| {
        if (!live) continue;
        const function = program.functions[index];
        for (function.instructions) |*instruction| {
            switch (instruction.*) {
                .call, .spawn => |*call| call.function = renumbered[call.function],
                .call_inout => |*call| call.function = renumbered[call.function],
                .const_function => |*named| named.* = renumbered[named.*],
                else => {},
            }
        }
        functions[renumbered[index]] = function;
    }
    program.functions = functions;
    program.entry_function = renumbered[program.entry_function];
}

/// Drop container rows no surviving block names, remap their
/// instructions, then compact the shared string pool to the literals
/// and retained row values that remain.
///
/// Equal container rows are copied independently.  Their indices are
/// declaration identities, so content interning here would change the
/// handles a program observes.  Call only after function pruning and
/// instruction compaction, on a verified program.
pub fn compactConstants(arena: Allocator, program: *Program) Allocator.Error!void {
    const container_count = program.container_constants.len;
    const string_count = program.constants.len;
    const used_containers = try arena.alloc(bool, container_count);
    const used_strings = try arena.alloc(bool, string_count);
    @memset(used_containers, false);
    @memset(used_strings, false);

    // The instruction pool may still contain orphans when `dead` is
    // disabled for a bisect.  Blocks are the executable program, so
    // only their items keep a pool row alive.
    for (program.functions) |function| {
        for (function.blocks) |block| {
            for (block.items) |item| switch (function.instructions[item]) {
                .const_container => |index| used_containers[index] = true,
                .const_string => |index| used_strings[index] = true,
                else => {},
            };
        }
    }

    for (program.container_constants, used_containers) |constant, used| {
        if (!used) continue;
        switch (constant.payload) {
            .sequence => |values| for (values) |value| markStrings(value, used_strings),
            .map => |entries| for (entries) |entry| {
                markStrings(entry.key, used_strings);
                markStrings(entry.value, used_strings);
            },
        }
    }

    const moved_containers = try arena.alloc(u32, container_count);
    @memset(moved_containers, std.math.maxInt(u32));
    var kept_containers: u32 = 0;
    for (used_containers, moved_containers) |used, *moved| {
        if (!used) continue;
        moved.* = kept_containers;
        kept_containers += 1;
    }

    if (kept_containers != container_count) {
        const constants = try arena.alloc(defs.ContainerConstant, kept_containers);
        for (program.container_constants, used_containers, moved_containers) |constant, used, moved| {
            if (used) constants[moved] = constant;
        }
        program.container_constants = constants;
        for (program.functions) |function| {
            for (function.blocks) |block| {
                for (block.items) |item| switch (function.instructions[item]) {
                    .const_container => |*index| index.* = moved_containers[index.*],
                    else => {},
                };
            }
        }
    }

    const moved_strings = try arena.alloc(u32, string_count);
    @memset(moved_strings, std.math.maxInt(u32));
    var kept_strings: u32 = 0;
    for (used_strings, moved_strings) |used, *moved| {
        if (!used) continue;
        moved.* = kept_strings;
        kept_strings += 1;
    }

    if (kept_strings != string_count) {
        const constants = try arena.alloc([]const u8, kept_strings);
        for (program.constants, used_strings, moved_strings) |constant, used, moved| {
            if (used) constants[moved] = constant;
        }
        program.constants = constants;
        for (program.functions) |function| {
            for (function.blocks) |block| {
                for (block.items) |item| switch (function.instructions[item]) {
                    .const_string => |*index| index.* = moved_strings[index.*],
                    else => {},
                };
            }
        }
        for (program.container_constants) |*constant| switch (constant.payload) {
            .sequence => |values| for (values) |*value| remapStrings(value, moved_strings),
            .map => |entries| for (entries) |*entry| {
                remapStrings(&entry.key, moved_strings);
                remapStrings(&entry.value, moved_strings);
            },
        };
    }
}

fn markStrings(constant: defs.ConstantValue, used: []bool) void {
    switch (constant) {
        .string => |index| used[index] = true,
        .strukt => |value| for (value.fields) |field| markStrings(field, used),
        .boolean, .long, .double, .absent => {},
    }
}

fn remapStrings(constant: *defs.ConstantValue, moved: []const u32) void {
    switch (constant.*) {
        .string => |*index| index.* = moved[index.*],
        .strukt => |*value| for (value.fields) |*field| remapStrings(field, moved),
        .boolean, .long, .double, .absent => {},
    }
}

const testing = std.testing;
const types_mod = @import("../support/types.zig");

test "unreachable functions are pruned and call targets renumbered" {
    var program: Program = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer program.deinit();
    const arena = program.arena.allocator();

    const functions = try arena.alloc(Function, 5);
    for (functions, 0..) |*function, index| {
        const instructions = try arena.dupe(Instruction, &.{
            .{ .const_long = 1 },
            .{ .ret = 0 },
        });
        const items = try arena.dupe(Register, &.{ 0, 1 });
        const blocks = try arena.alloc(defs.Block, 1);
        blocks[0] = .{ .items = items };
        function.* = .{
            .name = try std.fmt.allocPrint(arena, "f{d}", .{index}),
            .parameter_count = 0,
            .return_type = .long,
            .locals = &.{},
            .instructions = instructions,
            .result_types = try arena.dupe(types_mod.Type, &.{ .long, .none }),
            .blocks = blocks,
        };
    }
    functions[1].name = try arena.dupe(u8, "main");
    functions[1].locals = try arena.dupe(defs.Local, &.{.{
        .name = "receiver",
        .local_type = .long,
    }});
    functions[1].instructions[0] = .{ .call_inout = .{
        .function = 3,
        .receiver = 0,
        .arguments = &.{},
    } };
    functions[3].name = try arena.dupe(u8, "mid");
    functions[3].parameter_count = 1;
    functions[3].locals = try arena.dupe(defs.Local, &.{.{
        .name = "self",
        .local_type = .long,
        .inout = true,
    }});
    functions[3].instructions[0] = .{ .call = .{ .function = 4, .arguments = &.{} } };
    functions[4].name = try arena.dupe(u8, "leaf");
    program.functions = functions;
    program.entry_function = 1;
    try @import("../06_mir/verify.zig").verify(testing.allocator, &program);

    try prune(arena, &program);
    try testing.expectEqual(@as(usize, 3), program.functions.len);
    try testing.expectEqual(@as(u32, 0), program.entry_function);
    try testing.expectEqualStrings("main", program.functions[0].name);
    try testing.expectEqualStrings("mid", program.functions[1].name);
    try testing.expectEqualStrings("leaf", program.functions[2].name);
    try testing.expectEqual(@as(u32, 1), program.functions[0].instructions[0].call_inout.function);
    try testing.expectEqual(@as(u32, 2), program.functions[1].instructions[0].call.function);
    try @import("../06_mir/verify.zig").verify(testing.allocator, &program);

    try prune(arena, &program);
    try testing.expectEqual(@as(usize, 3), program.functions.len);
    try testing.expectEqual(@as(u32, 0), program.entry_function);
}

test "constant rows and shared strings compact from surviving block items" {
    var program: Program = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer program.deinit();
    const arena = program.arena.allocator();

    program.constants = try arena.dupe([]const u8, &.{
        "dead direct",
        "live direct",
        "shared row",
        "dead row",
        "orphan",
        "unused",
    });
    program.structs = try arena.dupe(types_mod.StructLayout, &.{.{
        .name = "Label",
        .fields = try arena.dupe(types_mod.StructField, &.{.{ .name = "text", .field_type = .string }}),
    }});
    program.heap_types = try arena.dupe(types_mod.HeapType, &.{.{ .list = .{ .strukt = 0 } }});
    const dead_fields = try arena.dupe(defs.ConstantValue, &.{.{ .string = 3 }});
    const first_fields = try arena.dupe(defs.ConstantValue, &.{.{ .string = 2 }});
    const second_fields = try arena.dupe(defs.ConstantValue, &.{.{ .string = 2 }});
    const orphan_fields = try arena.dupe(defs.ConstantValue, &.{.{ .string = 4 }});
    const dead_values = try arena.dupe(defs.ConstantValue, &.{.{ .strukt = .{ .layout = 0, .fields = dead_fields } }});
    const first_values = try arena.dupe(defs.ConstantValue, &.{.{ .strukt = .{ .layout = 0, .fields = first_fields } }});
    const second_values = try arena.dupe(defs.ConstantValue, &.{.{ .strukt = .{ .layout = 0, .fields = second_fields } }});
    const orphan_values = try arena.dupe(defs.ConstantValue, &.{.{ .strukt = .{ .layout = 0, .fields = orphan_fields } }});
    program.container_constants = try arena.dupe(defs.ContainerConstant, &.{
        .{ .name = "dead", .heap = 0, .payload = .{ .sequence = dead_values } },
        .{ .name = "first", .heap = 0, .payload = .{ .sequence = first_values } },
        .{ .name = "second", .heap = 0, .payload = .{ .sequence = second_values } },
        .{ .name = "orphan", .heap = 0, .payload = .{ .sequence = orphan_values } },
    });

    const functions = try arena.alloc(Function, 2);
    functions[0] = .{
        .name = "dead",
        .parameter_count = 0,
        .return_type = .none,
        .locals = &.{},
        .instructions = try arena.dupe(Instruction, &.{
            .{ .const_container = 0 },
            .{ .intrinsic = .{ .kind = .len, .arguments = try arena.dupe(Register, &.{0}) } },
            .{ .const_string = 0 },
            .{ .intrinsic = .{ .kind = .print, .arguments = try arena.dupe(Register, &.{2}) } },
            .{ .ret = null },
        }),
        .result_types = try arena.dupe(types_mod.Type, &.{ .{ .heap = 0 }, .long, .string, .none, .none }),
        .blocks = try arena.dupe(defs.Block, &.{.{
            .items = try arena.dupe(Register, &.{ 0, 1, 2, 3, 4 }),
        }}),
    };
    functions[1] = .{
        .name = "main",
        .parameter_count = 0,
        .return_type = .none,
        .locals = &.{},
        .instructions = try arena.dupe(Instruction, &.{
            .{ .const_container = 1 },
            .{ .intrinsic = .{ .kind = .len, .arguments = try arena.dupe(Register, &.{0}) } },
            .{ .const_container = 2 },
            .{ .intrinsic = .{ .kind = .len, .arguments = try arena.dupe(Register, &.{2}) } },
            .{ .const_string = 1 },
            .{ .intrinsic = .{ .kind = .print, .arguments = try arena.dupe(Register, &.{4}) } },
            // Neither orphan belongs to a block.  A pool scan over the
            // raw instruction slice would retain both by mistake.
            .{ .const_container = 3 },
            .{ .const_string = 4 },
            .{ .ret = null },
        }),
        .result_types = try arena.dupe(types_mod.Type, &.{
            .{ .heap = 0 },
            .long,
            .{ .heap = 0 },
            .long,
            .string,
            .none,
            .{ .heap = 0 },
            .string,
            .none,
        }),
        .blocks = try arena.dupe(defs.Block, &.{.{
            .items = try arena.dupe(Register, &.{ 0, 1, 2, 3, 4, 5, 8 }),
        }}),
    };
    program.functions = functions;
    program.entry_function = 1;

    try @import("../06_mir/verify.zig").verify(testing.allocator, &program);
    try prune(arena, &program);
    try @import("dead.zig").dead(arena, &program);
    try compactConstants(arena, &program);
    try @import("../06_mir/verify.zig").verify(testing.allocator, &program);

    try testing.expectEqual(@as(usize, 1), program.functions.len);
    try testing.expectEqual(@as(usize, 2), program.container_constants.len);
    try testing.expectEqualStrings("first", program.container_constants[0].name);
    try testing.expectEqualStrings("second", program.container_constants[1].name);
    try testing.expectEqual(
        @as(u32, 1),
        program.container_constants[0].payload.sequence[0].strukt.fields[0].string,
    );
    try testing.expectEqual(@as(usize, 2), program.constants.len);
    try testing.expectEqualStrings("live direct", program.constants[0]);
    try testing.expectEqualStrings("shared row", program.constants[1]);
    try testing.expectEqual(@as(u32, 0), program.functions[0].instructions[0].const_container);
    try testing.expectEqual(@as(u32, 1), program.functions[0].instructions[2].const_container);
    try testing.expectEqual(@as(u32, 0), program.functions[0].instructions[4].const_string);

    try compactConstants(arena, &program);
    try testing.expectEqual(@as(usize, 2), program.container_constants.len);
    try testing.expectEqual(@as(usize, 2), program.constants.len);
    try @import("../06_mir/verify.zig").verify(testing.allocator, &program);
}
