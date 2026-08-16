//! Dead instruction elimination, then compaction of the instruction
//! pool.
//!
//! **Two jobs.**  The first is ordinary dead-code elimination inside a
//! function: an instruction whose result nothing reads and which
//! `effects.zig` calls `pure` is deleted, and so is a `local_set` to a
//! local no `local_get` ever reads.  Only `pure` — never `stable` —
//! because a `stable` instruction can trap, and deleting an unread
//! `1 / n` would delete a `divide_by_zero`.  Removing one instruction
//! can make its operands unread, so the sweep runs to a fixed point.
//!
//! The second job is the one that makes every other pass in this stage
//! pay.  MIR registers *are* indices into the instruction pool, so
//! unlinking an instruction from its block leaves it in the pool, and
//! the pool is what everything downstream is sized by: it is written
//! into the `.lcm` and read back by the back end, LLVM allocates one
//! slot per entry, and the oracle gives every frame one
//! `runtime.Value` per pool entry, whether it can run or not
//! (`interpreter/machine.zig`'s `register_count`).  So the pool is
//! rebuilt with only the instructions some block still holds, in their
//! original order, and every register renumbered.
//!
//! This pass must be the last instruction pass, and it must run before
//! function pruning: the passes before it leave orphans behind on
//! purpose, so that none of them has to renumber.  Once this compactor
//! settles the block items, function reachability can no longer be kept
//! alive by an unread function value.  Constant-pool compaction follows
//! pruning and reads the same settled block items without changing
//! instruction shape.
//!
//! **The local table is deliberately not compacted.**  Each local is
//! another slot in every frame, so dropping the hidden temporaries this
//! stage empties out would be worth a little — but renumbering the
//! local table is not this stage's job, and nothing here relies on it.

const std = @import("std");
const defs = @import("../mir/defs.zig");
const types = @import("../support/types.zig");
const effects = @import("effects.zig");
const registers = @import("registers.zig");

const Allocator = std.mem.Allocator;
const Function = defs.Function;
const Instruction = defs.Instruction;
const Program = defs.Program;
const Register = defs.Register;

/// Sweep dead instructions out of every function, then compact.
pub fn dead(arena: Allocator, program: *Program) Allocator.Error!void {
    for (program.functions) |*function| {
        try sweep(arena, function);
        try compactPool(arena, function);
    }
}

fn sweep(arena: Allocator, function: *Function) Allocator.Error!void {
    const count = function.instructions.len;
    if (count == 0) return;
    const used = try arena.alloc(bool, count);
    const read = try arena.alloc(bool, function.locals.len);

    // Each round deletes at least one instruction, so the instruction
    // count bounds the number of rounds.
    var rounds: usize = 0;
    while (rounds <= count) : (rounds += 1) {
        @memset(used, false);
        @memset(read, false);
        for (function.blocks) |block| {
            for (block.items) |item| {
                const instruction = function.instructions[item];
                registers.markOperands(instruction, used);
                switch (registers.localUse(instruction)) {
                    .read => |local| read[local] = true,
                    .read_write => |local| read[local] = true,
                    else => {},
                }
            }
        }

        var changed = false;
        for (function.blocks) |*block| {
            var kept: usize = 0;
            for (block.items) |item| {
                if (isDead(function, used, read, item)) {
                    changed = true;
                    continue;
                }
                block.items[kept] = item;
                kept += 1;
            }
            block.items = block.items[0..kept];
        }
        if (!changed) break;
    }
}

fn isDead(function: *const Function, used: []const bool, read: []const bool, item: Register) bool {
    const instruction = function.instructions[item];
    return switch (instruction) {
        // A store nobody loads.
        //
        // A slot that owns its storage is the exception, and it is not
        // an optimization question.  A trap unwinds past every release
        // and the engine then walks the standing frames to give that
        // storage back (docs/STRINGS.md), so the slot's contents are
        // read by something no block mentions: delete the store and
        // the bytes leak, delete the store-back after a release and
        // they are freed twice.
        .local_set => |set| !read[set.local] and
            !function.locals[set.local].owns_storage and
            !function.locals[set.local].inout,
        else => !used[item] and effects.classify(function, item) == .pure,
    };
}

/// Rebuild the instruction pool with only what some block still holds.
fn compactPool(arena: Allocator, function: *Function) Allocator.Error!void {
    const count = function.instructions.len;
    if (count == 0) return;
    const present = try arena.alloc(bool, count);
    @memset(present, false);
    for (function.blocks) |block| {
        for (block.items) |item| present[item] = true;
    }

    // Absent entries get a register no function can have, so that an
    // operand pointing at something no block holds — which would mean
    // a pass above deleted an instruction somebody still reads — comes
    // out of the verifier as `UndefinedRegister` instead of quietly
    // renumbering into whatever was next to it.
    var kept: u32 = 0;
    const moved = try arena.alloc(Register, count);
    @memset(moved, std.math.maxInt(Register));
    for (present, moved) |live, *slot| {
        if (!live) continue;
        slot.* = kept;
        kept += 1;
    }
    if (kept == count) return;

    const instructions = try arena.alloc(Instruction, kept);
    const result_types = try arena.alloc(types.Type, kept);
    const origins = try arena.alloc(defs.Origin, if (function.origins.len == 0) 0 else kept);
    for (present, 0..) |live, index| {
        if (!live) continue;
        const at = moved[index];
        instructions[at] = function.instructions[index];
        result_types[at] = function.result_types[index];
        if (origins.len != 0) origins[at] = function.origins[index];
        try registers.mapOperands(arena, &instructions[at], moved);
    }
    for (function.blocks) |*block| {
        for (block.items) |*item| item.* = moved[item.*];
    }
    function.instructions = instructions;
    function.result_types = result_types;
    function.origins = origins;
}

const testing = std.testing;

test "inout stores and the receiver value reaching a call survive dead-code elimination" {
    var program: Program = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer program.deinit();
    const arena = program.arena.allocator();
    const functions = try arena.alloc(Function, 2);

    functions[0] = .{
        .name = "caller",
        .parameter_count = 0,
        .return_type = .none,
        .locals = try arena.dupe(defs.Local, &.{.{ .name = "receiver", .local_type = .long }}),
        .instructions = try arena.dupe(Instruction, &.{
            .{ .const_long = 4 },
            .{ .local_set = .{ .local = 0, .value = 0 } },
            .{ .call_inout = .{ .function = 1, .receiver = 0, .arguments = &.{} } },
            .{ .ret = null },
        }),
        .result_types = try arena.dupe(types.Type, &.{ .long, .none, .none, .none }),
        .blocks = try arena.dupe(defs.Block, &.{.{
            .items = try arena.dupe(Register, &.{ 0, 1, 2, 3 }),
        }}),
    };
    functions[1] = .{
        .name = "writer",
        .parameter_count = 1,
        .return_type = .none,
        .locals = try arena.dupe(defs.Local, &.{.{
            .name = "self",
            .local_type = .long,
            .inout = true,
        }}),
        .instructions = try arena.dupe(Instruction, &.{
            .{ .const_long = 9 },
            .{ .local_set = .{ .local = 0, .value = 0 } },
            .{ .ret = null },
        }),
        .result_types = try arena.dupe(types.Type, &.{ .long, .none, .none }),
        .blocks = try arena.dupe(defs.Block, &.{.{
            .items = try arena.dupe(Register, &.{ 0, 1, 2 }),
        }}),
    };
    program.functions = functions;

    try dead(arena, &program);
    for (program.functions) |function| {
        var saw_store = false;
        for (function.instructions) |instruction| {
            if (instruction == .local_set) saw_store = true;
        }
        try testing.expect(saw_store);
    }
}
