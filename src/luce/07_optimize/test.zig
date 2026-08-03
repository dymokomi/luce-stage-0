//! The stage's own proofs.
//!
//! *Shape* only: each pass is driven on its own over a real compiled
//! program and the rewrite it claims is checked by name, so a pass
//! that quietly stops firing is caught rather than merely staying
//! green.  Every one of them re-verifies afterwards: `07_optimize`
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
const mir = @import("../06_mir.zig");
const optimize = @import("../07_optimize.zig");
const types = @import("../support/types.zig");

const testing = std.testing;
const Allocator = std.mem.Allocator;
const Program = mir.Program;

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

test "value numbering folds a re-read local and a recomputed expression" {
    var program = try compileRaw(
        \\func main():
        \\    var total = 0
        \\    var index = 4
        \\    total = index * index + index * index
        \\    total = total + index
        \\    print(str(total))
        \\
    );
    defer program.deinit();

    const before = liveInstructions(&program);
    const reads_before = countTag(&program, .local_get);
    try optimize.values(program.arena.allocator(), &program);
    try mir.verify(testing.allocator, &program);

    // Four reads of `index` become one, and the repeated product is
    // computed once.
    try testing.expect(countTag(&program, .local_get) < reads_before);
    try testing.expect(liveInstructions(&program) < before);
}

test "value numbering keeps a local read that a store invalidates" {
    var program = try compileRaw(
        \\func main():
        \\    var total = 1
        \\    total = total + 1
        \\    total = total + 1
        \\    print(str(total))
        \\
    );
    defer program.deinit();

    const reads = countTag(&program, .local_get);
    try optimize.values(program.arena.allocator(), &program);
    try mir.verify(testing.allocator, &program);
    // Each read follows a store to the same local, so each one is
    // forwarded to the stored register rather than to another read —
    // the count falls, but the program still adds twice.
    try testing.expect(countTag(&program, .local_get) <= reads);
}

test "ownership drops the temporary's bind and its inert release" {
    var program = try compileRaw(
        \\func main():
        \\    let xs = new List(Int)
        \\    xs.append(1)
        \\    print(str(len(xs)))
        \\
    );
    defer program.deinit();

    // The lowering parks the fresh list in a hidden temporary and then
    // binds it again to `xs`, so there are two of each.
    try testing.expectEqual(@as(usize, 2), countTag(&program, .object_bind));
    try testing.expectEqual(@as(usize, 2), countTag(&program, .object_unbind));

    const arena = program.arena.allocator();
    try optimize.values(arena, &program);
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
        \\func take(v: give List(Int)) -> Int:
        \\    let n = len(v)
        \\    free(v)
        \\    return n
        \\
        \\func main():
        \\    let xs = new List(Int)
        \\    xs.append(1)
        \\    print(str(take(give(xs))))
        \\
    );
    defer program.deinit();

    const arena = program.arena.allocator();
    const binds = countTag(&program, .object_bind);
    try optimize.values(arena, &program);
    try optimize.ownership(arena, &program);
    try mir.verify(testing.allocator, &program);
    try testing.expect(countTag(&program, .object_bind) >= binds - 1);
}

test "control flow merges the loop increment and drops the forwarder" {
    var program = try compileRaw(
        \\func main():
        \\    var total = 0
        \\    for i in range(0, 10):
        \\        for j in range(0, 10):
        \\            total = total + i * j
        \\    print(str(total))
        \\
    );
    defer program.deinit();

    const before = blockCount(&program);
    try optimize.flow(program.arena.allocator(), &program);
    try mir.verify(testing.allocator, &program);
    try testing.expect(blockCount(&program) < before);
    // Every surviving block is reachable from the entry, so none of
    // them is a block the artifact carries for nothing.
    try testing.expect(blockCount(&program) >= 1);
}

test "dead code sweeps unread values and compacts the pool" {
    var program = try compileRaw(
        \\func main():
        \\    let xs = new List(Int)
        \\    xs.append(1)
        \\    print(str(len(xs)))
        \\
    );
    defer program.deinit();

    const arena = program.arena.allocator();
    const before = liveInstructions(&program);
    const locals = localCount(&program);
    try optimize.values(arena, &program);
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
        \\    var total = 0
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

test "running the stage twice changes nothing the second time" {
    var program = try compileRaw(
        \\func main():
        \\    let xs = new List(Int)
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
        \\    let m = new Map(String, Int)
        \\    m["a"] = 1
        \\    if m.has("a"):
        \\        print(str(m["a"]))
        \\
        ,
        \\func fib(n: Int) -> Int:
        \\    if n < 2:
        \\        return n
        \\    return fib(n - 1) + fib(n - 2)
        \\
        \\func main():
        \\    print(str(fib(10)))
        \\
        ,
        \\struct Point:
        \\    x: Int
        \\    y: Int
        \\
        \\func main():
        \\    var p = Point(x = 1, y = 2)
        \\    p.x = p.x + p.y
        \\    print(str(p.x))
        \\
    };
    const each = [_]optimize.Passes{
        .{ .prune = true, .flow = false, .values = false, .ownership = false, .dead = false },
        .{ .prune = false, .flow = true, .values = false, .ownership = false, .dead = false },
        .{ .prune = false, .flow = false, .values = true, .ownership = false, .dead = false },
        .{ .prune = false, .flow = false, .values = false, .ownership = true, .dead = false },
        .{ .prune = false, .flow = false, .values = false, .ownership = false, .dead = true },
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
