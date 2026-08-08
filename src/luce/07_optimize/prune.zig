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
/// the renumbering).  Functions are all that shrinks: constants,
/// struct layouts, and heap-type rows they referenced stay, and the
/// scratch plus the dead functions' memory stay in the program arena
/// until deinit — the artifact is what gets smaller, not the
/// resident compiler.
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
                .const_function => |*named| named.* = renumbered[named.*],
                else => {},
            }
        }
        functions[renumbered[index]] = function;
    }
    program.functions = functions;
    program.entry_function = renumbered[program.entry_function];
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
    functions[1].instructions[0] = .{ .call = .{ .function = 3, .arguments = &.{} } };
    functions[3].name = try arena.dupe(u8, "mid");
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
    try testing.expectEqual(@as(u32, 1), program.functions[0].instructions[0].call.function);
    try testing.expectEqual(@as(u32, 2), program.functions[1].instructions[0].call.function);
    try @import("../06_mir/verify.zig").verify(testing.allocator, &program);

    try prune(arena, &program);
    try testing.expectEqual(@as(usize, 3), program.functions.len);
    try testing.expectEqual(@as(u32, 0), program.entry_function);
}
