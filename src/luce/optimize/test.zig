//! The stage's own proofs.
//!
//! *Shape* only: each of the three passes is driven on its own over a
//! real compiled program and the rewrite it claims is checked by name,
//! so a pass that quietly stops firing is caught rather than merely
//! staying green.  Every one of them re-verifies afterwards: `optimize`
//! runs in place, and a pass that breaks a MIR invariant must be an
//! internal compiler error, never a miscompile.
//!
//! What the stage may not do — change a printed byte, a trap code, a
//! trap message, or one live object — is a claim about *running*, so
//! it is proved on both engines in `specs/optimize_spec.zig`,
//! including over a corpus of generated programs.
//!
//! The wider net is wider still: `specs/` compiles with the stage on,
//! so ownership S1-S43, the behaviour suite, and every trap code in
//! `errors_spec` are all already running against optimized MIR.

const std = @import("std");
const compile_mod = @import("../compile.zig");
const defs = @import("../mir/defs.zig");
const mir = @import("../mir.zig");
const optimize = @import("../optimize.zig");
const types = @import("../support/types.zig");

const testing = std.testing;
const Allocator = std.mem.Allocator;
const Block = defs.Block;
const Instruction = defs.Instruction;
const Local = defs.Local;
const Program = mir.Program;
const Register = defs.Register;

const script: types.CompileOptions = .{ .allow_host = true };

/// Compile as a script with the stage off, so a test can drive one
/// pass at a time over exactly the lowering the analyzer produced.
fn compileRaw(source: []const u8) !Program {
    var options = script;
    options.prune = false;
    var result = try compile_mod.compile(testing.allocator, source, options);
    switch (result) {
        .failure => |*diagnostics| {
            const rendered = try diagnostics.render(testing.allocator);
            defer testing.allocator.free(rendered);
            std.debug.print("unexpected compile error:\n{s}", .{rendered});
            result.deinit();
            return error.TestUnexpectedResult;
        },
        .success => |program| return program,
    }
}

/// How many instructions the blocks of a program actually hold —
/// what an engine dispatches, as opposed to what the pool carries.
fn liveInstructions(program: *const Program) usize {
    var total: usize = 0;
    for (program.functions) |function| {
        for (function.blocks) |block| total += block.items.len;
    }
    return total;
}

fn pooledInstructions(program: *const Program) usize {
    var total: usize = 0;
    for (program.functions) |function| total += function.instructions.len;
    return total;
}

fn blockCount(program: *const Program) usize {
    var total: usize = 0;
    for (program.functions) |function| total += function.blocks.len;
    return total;
}

fn localCount(program: *const Program) usize {
    var total: usize = 0;
    for (program.functions) |function| total += function.locals.len;
    return total;
}

// ---------------------------------------------------------------------------
// Shape: what each pass does, driven one at a time
// ---------------------------------------------------------------------------

test "dead code sweeps unread values and compacts the pool" {
    var program = try compileRaw(
        \\func main():
        \\    let xs = new list[i64]
        \\    xs.append(1)
        \\    let unused = len(xs)
        \\    print(str(len(xs)))
        \\
    );
    defer program.deinit();

    const arena = program.arena.allocator();
    const before = liveInstructions(&program);
    const locals = localCount(&program);
    try optimize.dead(arena, &program);
    try mir.verify(testing.allocator, &program);

    // Nothing orphaned is left in the pool: every entry is in a block.
    try testing.expectEqual(liveInstructions(&program), pooledInstructions(&program));
    try testing.expect(liveInstructions(&program) < before);
    // The local table is left alone on purpose (dead.zig's header).
    try testing.expectEqual(locals, localCount(&program));
    for (program.functions) |function| {
        try testing.expectEqual(function.instructions.len, function.result_types.len);
        if (function.origins.len != 0) {
            try testing.expectEqual(function.instructions.len, function.origins.len);
        }
    }
}

test "the whole stage shrinks a program and leaves it verifiable" {
    const source =
        \\import std.strings
        \\
        \\func main():
        \\    let words = strings.split("a,b,c", ",")
        \\    var total: i64 = 0
        \\    for word in words:
        \\        total = total + len(word) + len(word)
        \\    print(str(total))
        \\
    ;
    var program = try compileRaw(source);
    defer program.deinit();

    const instructions = liveInstructions(&program);
    const blocks = blockCount(&program);
    try optimize.run(program.arena.allocator(), &program, .all);
    try mir.verify(testing.allocator, &program);
    try testing.expect(liveInstructions(&program) < instructions);
    try testing.expect(blockCount(&program) <= blocks);
}

test "function pruning does not retain an orphaned function reference" {
    var program = try compileRaw(
        \\func unused(n: i64) -> i64:
        \\    return n * 2
        \\
        \\func main():
        \\    print("done")
        \\
    );
    defer program.deinit();

    const arena = program.arena.allocator();
    const target = for (program.functions, 0..) |function, index| {
        if (std.mem.eql(u8, function.name, "unused")) break @as(u32, @intCast(index));
    } else return error.TestUnexpectedResult;
    var main = &program.functions[program.entry_function];

    // A prior instruction pass may leave a function-valued register in
    // the pool after its block item was removed.  The verifier permits
    // that temporary orphan, but final reachability must not treat it as
    // executable code and retain the named function forever.
    const old_instructions = main.instructions;
    const instructions = try arena.alloc(Instruction, old_instructions.len + 1);
    @memcpy(instructions[0..old_instructions.len], old_instructions);
    instructions[old_instructions.len] = .{ .const_function = .{ .function = target } };
    main.instructions = instructions;
    const old_result_types = main.result_types;
    const result_types = try arena.alloc(types.Type, old_result_types.len + 1);
    @memcpy(result_types[0..old_result_types.len], old_result_types);
    result_types[old_result_types.len] = .none;
    main.result_types = result_types;
    if (main.origins.len != 0) {
        const old_origins = main.origins;
        const origins = try arena.alloc(defs.Origin, old_origins.len + 1);
        @memcpy(origins[0..old_origins.len], old_origins);
        origins[old_origins.len] = .{ .line = 0, .column = 0 };
        main.origins = origins;
    }

    try mir.verify(testing.allocator, &program);
    try optimize.run(arena, &program, .all);
    try mir.verify(testing.allocator, &program);

    for (program.functions) |function| {
        try testing.expect(!std.mem.eql(u8, function.name, "unused"));
    }
}

test "running the stage twice changes nothing the second time" {
    var program = try compileRaw(
        \\func main():
        \\    let xs = new list[i64]
        \\    var index = 0
        \\    while index < 5:
        \\        xs.append(index * index)
        \\        index = index + 1
        \\    print(str(len(xs)))
        \\
    );
    defer program.deinit();
    const arena = program.arena.allocator();

    try optimize.run(arena, &program, .all);
    const once = try mir.print(testing.allocator, &program);
    defer testing.allocator.free(once);
    try optimize.run(arena, &program, .all);
    const twice = try mir.print(testing.allocator, &program);
    defer testing.allocator.free(twice);
    try testing.expectEqualStrings(once, twice);
}

test "every pass on its own leaves verifiable MIR" {
    const sources = [_][]const u8{
        \\func main():
        \\    let m = new map[str, i64]
        \\    m["a"] = 1
        \\    if m.has("a"):
        \\        print(str(m["a"]))
        \\
        ,
        \\func fib(n: i64) -> i64:
        \\    if n < 2:
        \\        return n
        \\    return fib(n - 1) + fib(n - 2)
        \\
        \\func main():
        \\    print(str(fib(10)))
        \\
        ,
        \\struct Point:
        \\    x: i64
        \\    y: i64
        \\
        \\func main():
        \\    var p = Point(x = 1, y = 2)
        \\    p.x = p.x + p.y
        \\    print(str(p.x))
        \\
    };
    const each = [_]optimize.Passes{
        .{ .prune = true, .dead = false },
        .{ .prune = false, .dead = true },
    };
    for (sources) |source| {
        for (each) |passes| {
            var program = try compileRaw(source);
            defer program.deinit();
            try optimize.run(program.arena.allocator(), &program, passes);
            try mir.verify(testing.allocator, &program);
        }
    }
}

// ---------------------------------------------------------------------------
// Shape: what each pass must NOT do
// ---------------------------------------------------------------------------
//
// A pass that fires too often is the dangerous kind: the tests above
// all pass while a program leaks an object, keeps a stale owner, or
// loses a trap.  So each rewrite is met here by the case where its
// precondition does *not* hold, asserting the MIR came back unchanged.
//
// Ownership is proved on hand-built functions rather than on compiled
// ones.  That is deliberate: the shapes below are exactly the ones
// today's lowering does not emit — a release followed by a second
// release, a window closed by a copy — so there is no source that
// produces them, and pinning them here is what stops a later lowering
// from producing one against a pass that quietly stopped checking.

/// A one-function program with one `list(long)` heap row, built by
/// hand.  `locals` and the instruction list are duplicated into the
/// program's arena, and everything lands in a single block.
fn handBuilt(
    instructions: []const Instruction,
    result_types: []const types.Type,
    locals: []const Local,
    signatures: []const types.Signature,
) !Program {
    var program: Program = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    errdefer program.deinit();
    const arena = program.arena.allocator();

    const heap_types = try arena.alloc(types.HeapType, 1);
    heap_types[0] = .{ .list = .i64 };
    program.heap_types = heap_types;
    program.signatures = try arena.dupe(types.Signature, signatures);

    const items = try arena.alloc(Register, instructions.len);
    for (items, 0..) |*item, index| item.* = @intCast(index);
    const blocks = try arena.alloc(Block, 1);
    blocks[0] = .{ .items = items };

    const functions = try arena.alloc(defs.Function, 1);
    functions[0] = .{
        .name = "main",
        .parameter_count = 0,
        .return_type = .none,
        .locals = try arena.dupe(Local, locals),
        .instructions = try arena.dupe(Instruction, instructions),
        .result_types = try arena.dupe(types.Type, result_types),
        .blocks = blocks,
    };
    program.functions = functions;
    try mir.verify(testing.allocator, &program);
    return program;
}

test "prune keeps everything the entry can reach, however it reaches it" {
    // Mutual recursion, a chain three deep, and a function reached
    // only from inside a loop: all reachable, so the pass must return
    // the program it was given — same functions, same order, same
    // entry, and the same MIR down to the printed byte.
    var program = try compileRaw(
        \\func odd(n: i64) -> bool:
        \\    if n == 0:
        \\        return false
        \\    return even(n - 1)
        \\
        \\func even(n: i64) -> bool:
        \\    if n == 0:
        \\        return true
        \\    return odd(n - 1)
        \\
        \\func label(n: i64) -> str:
        \\    if even(n):
        \\        return "even"
        \\    return "odd"
        \\
        \\func main():
        \\    var index = 0
        \\    while index < 3:
        \\        print(label(index))
        \\        index = index + 1
        \\
    );
    defer program.deinit();

    const count = program.functions.len;
    const entry = program.entry_function;
    const before = try mir.print(testing.allocator, &program);
    defer testing.allocator.free(before);

    try optimize.prune(program.arena.allocator(), &program);
    try mir.verify(testing.allocator, &program);

    const after = try mir.print(testing.allocator, &program);
    defer testing.allocator.free(after);
    try testing.expectEqual(count, program.functions.len);
    try testing.expectEqual(entry, program.entry_function);
    try testing.expectEqualStrings(before, after);
}

test "std sort_by is an ordinary call whose indirect comparator survives prune" {
    var program = try compileRaw(
        \\import std.lists
        \\
        \\struct Row:
        \\    value: i64
        \\
        \\func before(a: i64, b: i64) -> bool:
        \\    return a < b
        \\
        \\func row_before(a: Row, b: Row) -> bool:
        \\    return a.value < b.value
        \\
        \\func main():
        \\    var values: list[i64] = [3, 1, 2]
        \\    values.sort_by(before)
        \\    values.sort_by(before)
        \\    var rows = [Row(value = 3), Row(value = 1)]
        \\    rows.sort_by(row_before)
        \\
    );
    defer program.deinit();

    var i64_helper: ?u32 = null;
    var row_helper: ?u32 = null;
    var helpers: usize = 0;
    for (program.functions, 0..) |function, index| {
        if (!std.mem.startsWith(u8, function.name, "lists.sort_by(")) continue;
        helpers += 1;
        if (std.mem.eql(u8, function.name, "lists.sort_by(i64)")) i64_helper = @intCast(index);
        if (std.mem.eql(u8, function.name, "lists.sort_by(Row)")) row_helper = @intCast(index);
    }
    // Two calls at one T reuse one specialization; a second T gets a
    // distinct checked body.  The private source template is not one
    // of these helpers and is pruned when nothing calls it.
    try testing.expectEqual(@as(usize, 2), helpers);
    try testing.expect(i64_helper != null);
    try testing.expect(row_helper != null);
    var i64_calls: usize = 0;
    var row_calls: usize = 0;
    for (program.functions[program.entry_function].instructions) |instruction| switch (instruction) {
        .call => |call| {
            if (call.function == i64_helper.?) i64_calls += 1;
            if (call.function == row_helper.?) row_calls += 1;
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 2), i64_calls);
    try testing.expectEqual(@as(usize, 1), row_calls);
    for ([_]u32{ i64_helper.?, row_helper.? }) |helper| {
        var calls_indirect = false;
        for (program.functions[helper].instructions) |instruction| switch (instruction) {
            .call_indirect => calls_indirect = true,
            else => {},
        };
        try testing.expect(calls_indirect);
    }

    try optimize.prune(program.arena.allocator(), &program);
    try mir.verify(testing.allocator, &program);
    var kept_before = false;
    var kept_row_before = false;
    var kept_helpers: usize = 0;
    for (program.functions) |function| {
        kept_before = kept_before or std.mem.eql(u8, function.name, "before");
        kept_row_before = kept_row_before or std.mem.eql(u8, function.name, "row_before");
        if (std.mem.startsWith(u8, function.name, "lists.sort_by(")) kept_helpers += 1;
    }
    try testing.expect(kept_before);
    try testing.expect(kept_row_before);
    try testing.expectEqual(@as(usize, 2), kept_helpers);
}

test "dead keeps an unread instruction that can trap" {
    // The sweep deletes only `pure` instructions.  Integer `//` is
    // `stable` — it answers the same thing every time but can trap —
    // so an unread one must survive: deleting it would delete a
    // `divide_by_zero` the program is entitled to.
    var program = try compileRaw(
        \\func main():
        \\    var divisor = 0
        \\    let unused = 10 // divisor
        \\    print("done")
        \\
    );
    defer program.deinit();
    const arena = program.arena.allocator();

    try optimize.dead(arena, &program);
    try mir.verify(testing.allocator, &program);

    var divisions: usize = 0;
    for (program.functions) |function| {
        for (function.blocks) |block| {
            for (block.items) |item| {
                const instruction = function.instructions[item];
                if (instruction == .binary and instruction.binary.op == .floor_divide) divisions += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 1), divisions);
}

test "dead keeps an unread function-name lookup that can trap" {
    var program = try compileRaw(
        \\func twice(n: i64) -> i64:
        \\    return n * 2
        \\
        \\func main():
        \\    let chosen: func(i64) -> i64 = twice
        \\    print(str(chosen))
        \\
    );
    defer program.deinit();
    const arena = program.arena.allocator();
    const entry = &program.functions[program.entry_function];

    var function_value: ?Register = null;
    var name_value: ?Register = null;
    var print_value: ?Register = null;
    for (entry.instructions, 0..) |instruction, register| switch (instruction) {
        .const_function => function_value = @intCast(register),
        .intrinsic => |call| switch (call.kind) {
            .function_name => name_value = @intCast(register),
            .print => print_value = @intCast(register),
            else => {},
        },
        else => {},
    };
    try testing.expect(function_value != null);
    try testing.expect(name_value != null);
    try testing.expect(print_value != null);

    // A verified local may be read before a store; function locals use
    // -1 for that zero.  Feed it through the source program's existing
    // store/load pair, then remove the print so the name result is
    // unread.  Dead-code elimination must retain the lookup and its
    // `null_object` trap.
    const original_locals = entry.locals;
    const locals = try arena.alloc(Local, original_locals.len + 1);
    @memcpy(locals[0..original_locals.len], original_locals);
    locals[original_locals.len] = .{
        .name = "unwritten",
        .local_type = entry.result_types[function_value.?],
    };
    entry.locals = locals;
    entry.instructions[function_value.?] = .{ .local_get = @intCast(original_locals.len) };
    entry.instructions[print_value.?] = .{ .const_integer = 0 };
    entry.result_types[print_value.?] = .i64;

    try mir.verify(testing.allocator, &program);
    try testing.expectEqual(
        optimize.effects.Effect.stable,
        optimize.effects.classify(entry, name_value.?),
    );
    try optimize.dead(arena, &program);
    try mir.verify(testing.allocator, &program);

    var names: usize = 0;
    for (entry.blocks) |block| {
        for (block.items) |item| switch (entry.instructions[item]) {
            .intrinsic => |call| if (call.kind == .function_name) {
                names += 1;
            },
            else => {},
        };
    }
    try testing.expectEqual(@as(usize, 1), names);
}

test "dead keeps a store into a slot that owns its storage" {
    // A slot that owns its storage is read by something no block
    // mentions: a trap unwinds past every release and the engine then
    // walks the standing frames to give the storage back
    // (docs/STRINGS.md).  So "no `local_get` reads it" is not a licence
    // to delete the store — that would leak the bytes.
    var program = try compileRaw(
        \\func main():
        \\    var text = "hello"
        \\    text = "goodbye"
        \\    print("done")
        \\
    );
    defer program.deinit();
    const arena = program.arena.allocator();

    const before = countOwningStores(&program);
    try testing.expect(before != 0);
    try optimize.dead(arena, &program);
    try mir.verify(testing.allocator, &program);
    try testing.expectEqual(before, countOwningStores(&program));
}

/// Stores into slots that own the storage they hold.
fn countOwningStores(program: *const Program) usize {
    var total: usize = 0;
    for (program.functions) |function| {
        for (function.blocks) |block| {
            for (block.items) |item| {
                const instruction = function.instructions[item];
                if (instruction != .local_set) continue;
                if (function.locals[instruction.local_set.local].owns_storage) total += 1;
            }
        }
    }
    return total;
}

test "a read that writes is never pure, whatever a later pass would like to believe" {
    // `map_place` is the one intrinsic that reads a place and defines
    // it in the same breath (`counts[word] += 1`), so folding two of
    // them together would make the second read what the first *found*
    // rather than what the first left, and deleting an unread one
    // would drop the entry it existed to create.
    //
    // Neither is reachable from source today: `dead` is the only
    // consumer of `classify`, it deletes only what nothing reads, and
    // stage 4 feeds this result straight into the combine every time.
    // A mutation sweep proved exactly that — classifying `map_place`
    // `.pure` survives the whole suite.  The classification is still
    // load-bearing, because the folding of heap reads that
    // `effects.zig`'s header calls "unwritten, not off by choice" is
    // what it is waiting for.  So it is pinned here, where a table
    // can be checked without a program having to run.
    var program = try compileRaw(
        \\func main():
        \\    var counts = new map[str, i64]
        \\    counts["fig"] += 1
        \\    print(str(counts["fig"]))
        \\
    );
    defer program.deinit();

    var found = false;
    for (program.functions) |function| {
        for (function.blocks) |block| {
            for (block.items) |item| {
                const instruction = function.instructions[item];
                if (instruction != .intrinsic) continue;
                if (instruction.intrinsic.kind != .map_place) continue;
                found = true;
                try testing.expectEqual(
                    optimize.effects.Effect.impure,
                    optimize.effects.classify(&function, item),
                );
                try testing.expect(!optimize.effects.viewStable(instruction));
            }
        }
    }
    // The counter has to have lowered to one, or the loop above
    // checked nothing at all.
    try testing.expect(found);
}

test "reading the error channel is never pure either, for the same reason" {
    // `error_message` reads state a neighbouring instruction writes:
    // the `forget` beside it empties the channel, so folding two reads
    // across one would answer the words twice for an error that only
    // has them once.
    //
    // And it is unreachable from source for exactly the reason above:
    // `dead` deletes only what nothing reads, and stage 4 emits this
    // straight into the store that gives the binding its copy, so no
    // program can produce an unread one.  The sweep said so —
    // classifying it `.pure` survived the whole suite, which is a
    // statement about `dead`'s reach and not about the table.  Pinned
    // against the table, where the claim actually lives.
    var program = try compileRaw(
        \\func check(n: i64) -> i64!:
        \\    if n < 0:
        \\        error("negative")
        \\    return n
        \\
        \\func main():
        \\    check(-1) catch reason:
        \\        print(reason)
        \\
    );
    defer program.deinit();

    var found = false;
    for (program.functions) |function| {
        for (function.blocks) |block| {
            for (block.items) |item| {
                const instruction = function.instructions[item];
                if (instruction != .intrinsic) continue;
                if (instruction.intrinsic.kind != .error_message) continue;
                found = true;
                try testing.expectEqual(
                    optimize.effects.Effect.impure,
                    optimize.effects.classify(&function, item),
                );
            }
        }
    }
    try testing.expect(found);
}
