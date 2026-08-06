//! The stage's own proofs.
//!
//! *Shape* only: each of the three passes is driven on its own over a
//! real compiled program and the rewrite it claims is checked by name,
//! so a pass that quietly stops firing is caught rather than merely
//! staying green.  Every one of them re-verifies afterwards: `07_optimize`
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
const defs = @import("../06_mir/defs.zig");
const mir = @import("../06_mir.zig");
const optimize = @import("../07_optimize.zig");
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

fn countTag(program: *const Program, tag: std.meta.Tag(mir.Instruction)) usize {
    var total: usize = 0;
    for (program.functions) |function| {
        for (function.blocks) |block| {
            for (block.items) |item| {
                if (std.meta.activeTag(function.instructions[item]) == tag) total += 1;
            }
        }
    }
    return total;
}

// ---------------------------------------------------------------------------
// Shape: what each pass does, driven one at a time
// ---------------------------------------------------------------------------

test "ownership drops the temporary's bind and its inert release" {
    var program = try compileRaw(
        \\func main():
        \\    let xs = new list(long)
        \\    xs.append(1)
        \\    print(string(len(xs)))
        \\
    );
    defer program.deinit();

    // The lowering parks the fresh list in a hidden temporary and then
    // binds it again to `xs`, so there are two of each.
    try testing.expectEqual(@as(usize, 2), countTag(&program, .object_bind));
    try testing.expectEqual(@as(usize, 2), countTag(&program, .object_unbind));

    const arena = program.arena.allocator();
    try optimize.ownership(arena, &program);
    try mir.verify(testing.allocator, &program);

    // One bind and one release survive: the ones that actually own and
    // actually free.
    try testing.expectEqual(@as(usize, 1), countTag(&program, .object_bind));
    try testing.expectEqual(@as(usize, 1), countTag(&program, .object_unbind));
}

test "ownership leaves a bind alone across a call" {
    // `give` hands the object to the callee, and a call can rebind or
    // free anything it is passed, so the window closes and both the
    // bind and the release stay.
    var program = try compileRaw(
        \\func take(v: give list(long)) -> long:
        \\    let n = len(v)
        \\    free(v)
        \\    return n
        \\
        \\func main():
        \\    let xs = new list(long)
        \\    xs.append(1)
        \\    print(string(take(give(xs))))
        \\
    );
    defer program.deinit();

    const arena = program.arena.allocator();
    const binds = countTag(&program, .object_bind);
    try optimize.ownership(arena, &program);
    try mir.verify(testing.allocator, &program);
    try testing.expect(countTag(&program, .object_bind) >= binds - 1);
}

test "dead code sweeps unread values and compacts the pool" {
    var program = try compileRaw(
        \\func main():
        \\    let xs = new list(long)
        \\    xs.append(1)
        \\    print(string(len(xs)))
        \\
    );
    defer program.deinit();

    const arena = program.arena.allocator();
    const before = liveInstructions(&program);
    const locals = localCount(&program);
    try optimize.ownership(arena, &program);
    try optimize.dead(arena, &program);
    try mir.verify(testing.allocator, &program);

    // Nothing orphaned is left in the pool: every entry is in a block.
    try testing.expectEqual(liveInstructions(&program), pooledInstructions(&program));
    try testing.expect(liveInstructions(&program) < before);
    // The local table is left alone on purpose — `give`/`free` carry a
    // local id as an integer value, so renumbering locals is unsafe
    // until the representation changes (dead.zig's header).
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
        \\    var total: long = 0
        \\    for word in words:
        \\        total = total + len(word) + len(word)
        \\    print(string(total))
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

test "running the stage twice changes nothing the second time" {
    var program = try compileRaw(
        \\func main():
        \\    let xs = new list(long)
        \\    var index = 0
        \\    while index < 5:
        \\        xs.append(index * index)
        \\        index = index + 1
        \\    print(string(len(xs)))
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
        \\    let m = new map(string, long)
        \\    m["a"] = 1
        \\    if m.has("a"):
        \\        print(string(m["a"]))
        \\
        ,
        \\func fib(n: long) -> long:
        \\    if n < 2:
        \\        return n
        \\    return fib(n - 1) + fib(n - 2)
        \\
        \\func main():
        \\    print(string(fib(10)))
        \\
        ,
        \\struct Point:
        \\    x: long
        \\    y: long
        \\
        \\func main():
        \\    var p = Point(x = 1, y = 2)
        \\    p.x = p.x + p.y
        \\    print(string(p.x))
        \\
    };
    const each = [_]optimize.Passes{
        .{ .prune = true, .ownership = false, .dead = false },
        .{ .prune = false, .ownership = true, .dead = false },
        .{ .prune = false, .ownership = false, .dead = true },
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
) !Program {
    var program: Program = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    errdefer program.deinit();
    const arena = program.arena.allocator();

    const heap_types = try arena.alloc(types.HeapType, 1);
    heap_types[0] = .{ .list = .long };
    program.heap_types = heap_types;

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

/// How many instructions the one block still holds.
fn blockLength(program: *const Program) usize {
    return program.functions[0].blocks[0].items.len;
}

test "ownership keeps the release that follows a real release" {
    // The window closes at a release that matches: the objects are
    // freed and every other handle to them is stale, so nothing after
    // it may be judged against what was known before it.
    //
    //   r0 = heap_new list(long)
    //   object_bind   %0, r0     # %0 owns it
    //   object_unbind %0, r0     # ... and gives it back: a real free
    //   object_unbind %1, r0     # a different name, on a stale handle
    //
    // Keeping the claim past the free would let the second release be
    // read as "owned by somebody else, so this frees nothing" and
    // struck out — a conclusion drawn from an owner field that no
    // longer exists.
    var program = try handBuilt(
        &.{
            .{ .heap_new = .{ .heap = 0, .dims = &.{} } },
            .{ .object_bind = .{ .local = 0, .value = 0 } },
            .{ .object_unbind = .{ .local = 0, .value = 0 } },
            .{ .object_unbind = .{ .local = 1, .value = 0 } },
            .{ .ret = null },
        },
        &.{ .{ .heap = 0 }, .none, .none, .none, .none },
        &.{
            .{ .name = "owner", .local_type = .{ .heap = 0 } },
            .{ .name = "other", .local_type = .{ .heap = 0 } },
        },
    );
    defer program.deinit();

    try optimize.ownership(program.arena.allocator(), &program);
    try mir.verify(testing.allocator, &program);
    try testing.expectEqual(@as(usize, 5), blockLength(&program));
    try testing.expectEqual(@as(usize, 1), countTag(&program, .object_bind));
    try testing.expectEqual(@as(usize, 2), countTag(&program, .object_unbind));
}

test "ownership keeps a bind when an opaque instruction closes the window" {
    // `copy_object` allocates and adopts, so it is not ownership
    // transparent: everything known about who owns what is forgotten
    // at it.  The bind in front of it therefore cannot be called dead
    // by the bind behind it.
    var one = [_]Register{0};
    var program = try handBuilt(
        &.{
            .{ .heap_new = .{ .heap = 0, .dims = &.{} } },
            .{ .object_bind = .{ .local = 0, .value = 0 } },
            .{ .intrinsic = .{ .kind = .copy_object, .arguments = &one } },
            .{ .object_bind = .{ .local = 1, .value = 0 } },
            .{ .object_unbind = .{ .local = 1, .value = 0 } },
            .{ .ret = null },
        },
        &.{ .{ .heap = 0 }, .none, .{ .heap = 0 }, .none, .none, .none },
        &.{
            .{ .name = "first", .local_type = .{ .heap = 0 } },
            .{ .name = "second", .local_type = .{ .heap = 0 } },
        },
    );
    defer program.deinit();

    try optimize.ownership(program.arena.allocator(), &program);
    try mir.verify(testing.allocator, &program);
    try testing.expectEqual(@as(usize, 6), blockLength(&program));
    try testing.expectEqual(@as(usize, 2), countTag(&program, .object_bind));
}

test "ownership never forwards a load out of a slot that owns its storage" {
    // A slot that owns its storage holds a copy the runtime made, not
    // the register that was stored into it (docs/STRINGS.md), so the
    // load answers a value the store says nothing about.  Forwarding
    // it anyway would make the two binds below look like a bind of one
    // register twice, and the first would be struck out — deleting the
    // claim the owning name actually holds.
    //
    // A struct carrying a list is the real shape of such a slot: the
    // frame slot owns the field run.
    var program: Program = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer program.deinit();
    const arena = program.arena.allocator();

    const heap_types = try arena.alloc(types.HeapType, 1);
    heap_types[0] = .{ .list = .long };
    program.heap_types = heap_types;
    const layouts = try arena.alloc(types.StructLayout, 1);
    const fields = try arena.alloc(types.StructField, 1);
    fields[0] = .{ .name = "items", .field_type = .{ .heap = 0 } };
    layouts[0] = .{ .name = "Holder", .fields = fields };
    program.structs = layouts;

    var made = [_]Register{0};
    const instructions = try arena.dupe(Instruction, &.{
        .{ .heap_new = .{ .heap = 0, .dims = &.{} } }, // r0
        .{ .struct_make = .{ .layout = 0, .fields = &made } }, // r1
        .{ .local_set = .{ .local = 0, .value = 1 } }, // r2
        .{ .object_bind = .{ .local = 0, .value = 1 } }, // r3
        .{ .local_get = 0 }, // r4
        .{ .object_bind = .{ .local = 1, .value = 4 } }, // r5
        .{ .object_unbind = .{ .local = 1, .value = 4 } }, // r6
        .{ .ret = null }, // r7
    });
    const items = try arena.alloc(Register, instructions.len);
    for (items, 0..) |*item, index| item.* = @intCast(index);
    const blocks = try arena.alloc(Block, 1);
    blocks[0] = .{ .items = items };
    const functions = try arena.alloc(defs.Function, 1);
    functions[0] = .{
        .name = "main",
        .parameter_count = 0,
        .return_type = .none,
        .locals = try arena.dupe(Local, &.{
            .{ .name = "held", .local_type = .{ .strukt = 0 }, .owns_storage = true },
            .{ .name = "borrowed", .local_type = .{ .strukt = 0 } },
        }),
        .instructions = instructions,
        .result_types = try arena.dupe(types.Type, &.{
            .{ .heap = 0 },
            .{ .strukt = 0 },
            .none,
            .none,
            .{ .strukt = 0 },
            .none,
            .none,
            .none,
        }),
        .blocks = blocks,
    };
    program.functions = functions;
    try mir.verify(testing.allocator, &program);

    try optimize.ownership(arena, &program);
    try mir.verify(testing.allocator, &program);
    try testing.expectEqual(@as(usize, 8), blockLength(&program));
    try testing.expectEqual(@as(usize, 2), countTag(&program, .object_bind));
}

test "ownership forwards the last store into a local, not the first" {
    // Store-to-load forwarding is what lets the pass key by register
    // at all, and its whole invalidation rule is "another store to the
    // same local".  A load after a second store answers the second
    // one, so the claim recorded against the first register must not
    // be found through it.
    var program = try handBuilt(
        &.{
            .{ .heap_new = .{ .heap = 0, .dims = &.{} } }, // r0
            .{ .local_set = .{ .local = 0, .value = 0 } }, // r1
            .{ .heap_new = .{ .heap = 0, .dims = &.{} } }, // r2
            .{ .local_set = .{ .local = 0, .value = 2 } }, // r3
            .{ .local_get = 0 }, // r4 — this is r2, not r0
            .{ .object_bind = .{ .local = 0, .value = 0 } }, // r5
            .{ .object_bind = .{ .local = 1, .value = 4 } }, // r6
            .{ .object_unbind = .{ .local = 1, .value = 4 } }, // r7
            .{ .ret = null }, // r8
        },
        &.{
            .{ .heap = 0 },
            .none,
            .{ .heap = 0 },
            .none,
            .{ .heap = 0 },
            .none,
            .none,
            .none,
            .none,
        },
        &.{
            .{ .name = "slot", .local_type = .{ .heap = 0 } },
            .{ .name = "other", .local_type = .{ .heap = 0 } },
        },
    );
    defer program.deinit();

    try optimize.ownership(program.arena.allocator(), &program);
    try mir.verify(testing.allocator, &program);
    try testing.expectEqual(@as(usize, 2), countTag(&program, .object_bind));
}

test "ownership leaves a program with nothing to rewrite byte for byte alone" {
    // The pass rebuilds a block's item list only when it struck
    // something out of it.  A program whose binds all stand for
    // themselves must come back identical, not merely equivalent.
    var program = try compileRaw(
        \\func main():
        \\    var total = 0
        \\    var index = 0
        \\    while index < 5:
        \\        total = total + index
        \\        index = index + 1
        \\    print(string(total))
        \\
    );
    defer program.deinit();

    const before = try mir.print(testing.allocator, &program);
    defer testing.allocator.free(before);
    try optimize.ownership(program.arena.allocator(), &program);
    const after = try mir.print(testing.allocator, &program);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
}

test "prune keeps everything the entry can reach, however it reaches it" {
    // Mutual recursion, a chain three deep, and a function reached
    // only from inside a loop: all reachable, so the pass must return
    // the program it was given — same functions, same order, same
    // entry, and the same MIR down to the printed byte.
    var program = try compileRaw(
        \\func odd(n: long) -> bool:
        \\    if n == 0:
        \\        return false
        \\    return even(n - 1)
        \\
        \\func even(n: long) -> bool:
        \\    if n == 0:
        \\        return true
        \\    return odd(n - 1)
        \\
        \\func label(n: long) -> string:
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
        \\    var counts = new map(string, long)
        \\    counts["fig"] += 1
        \\    print(string(counts["fig"]))
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
        \\func check(n: long) -> long!:
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
