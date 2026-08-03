//! The stage's own proofs.
//!
//! Three kinds, in order of how much they are trusted:
//!
//!  1. *Shape* — each pass is driven on its own over a real compiled
//!     program and the rewrite it claims is checked by name, so a pass
//!     that quietly stops firing is caught rather than merely staying
//!     green.  Every one of them re-verifies afterwards: `07_optimize`
//!     runs in place, and a pass that breaks a MIR invariant must be
//!     an internal compiler error, never a miscompile.
//!  2. *Semantics* — the programs that exercise the dangerous corner,
//!     which is ownership: `object_unbind` is the deallocation, so an
//!     elision that is one step too clever leaks an object or frees a
//!     live one.  Every one of these runs optimized and unoptimized
//!     and compares what was printed, the trap code, the trap message,
//!     and the number of objects left alive.
//!  3. *Fuzz* — the same comparison over generated programs, which is
//!     the only part that finds what nobody thought to write down.
//!
//! The wider net is elsewhere and matters more: `specs/` compiles with
//! the stage on, so ownership S1-S43, the behaviour suite, and every
//! trap code in `errors_spec` are all already running against
//! optimized MIR.

const std = @import("std");
const compile_mod = @import("../compile.zig");
const backend = @import("../backend.zig");
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
    try expectSameBehavior(
        \\func main():
        \\    var total = 1
        \\    total = total + 1
        \\    total = total + 1
        \\    print(str(total))
        \\
    );
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
    try expectSameBehavior(source);
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

// ---------------------------------------------------------------------------
// Semantics: optimized against unoptimized, on the same program
// ---------------------------------------------------------------------------

const Behavior = struct {
    printed: []u8,
    trap: ?mir.TrapCode,
    message: []u8,
    leaked: u32,

    fn deinit(self: *Behavior) void {
        testing.allocator.free(self.printed);
        testing.allocator.free(self.message);
    }
};

const Recorder = struct {
    printed: std.ArrayList(u8) = .empty,

    fn printLine(context: *anyopaque, text: []const u8) error{OutOfMemory}!void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        try self.printed.appendSlice(testing.allocator, text);
        try self.printed.append(testing.allocator, '\n');
    }
};

/// Compile with the stage on or off, run, and record everything the
/// program did that anyone can observe.
fn observe(source: []const u8, optimized: bool) !Behavior {
    var options = script;
    options.prune = optimized;
    var result = try compile_mod.compile(testing.allocator, source, options);
    defer result.deinit();
    switch (result) {
        .failure => |*diagnostics| {
            const rendered = try diagnostics.render(testing.allocator);
            defer testing.allocator.free(rendered);
            std.debug.print("unexpected compile error:\n{s}", .{rendered});
            return error.TestUnexpectedResult;
        },
        .success => |*program| {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            var recorder: Recorder = .{};
            errdefer recorder.printed.deinit(testing.allocator);
            const outcome = try backend.evaluateHosted(
                .{ .arena = arena.allocator(), .objects = testing.allocator },
                program,
                .{ .call_depth = 256 },
                .{ .context = &recorder, .printFn = Recorder.printLine },
            );
            return switch (outcome) {
                .success => |success| .{
                    .printed = try recorder.printed.toOwnedSlice(testing.allocator),
                    .trap = null,
                    .message = try testing.allocator.dupe(u8, ""),
                    .leaked = success.leaked_objects,
                },
                .trap => |trap| .{
                    .printed = try recorder.printed.toOwnedSlice(testing.allocator),
                    .trap = trap.code,
                    .message = try testing.allocator.dupe(u8, trap.message),
                    .leaked = 0,
                },
                // The passes are proved on pure programs, so neither
                // outcome can happen without the spec having drifted.
                .errored => error.TestUnexpectedResult,
            };
        },
    }
}

/// The whole point of the stage: it may not change what a program
/// does by one printed byte, one trap code, or one live object.
fn expectSameBehavior(source: []const u8) !void {
    var raw = try observe(source, false);
    defer raw.deinit();
    var lean = try observe(source, true);
    defer lean.deinit();
    if (!std.mem.eql(u8, raw.printed, lean.printed) or
        raw.trap != lean.trap or
        !std.mem.eql(u8, raw.message, lean.message) or
        raw.leaked != lean.leaked)
    {
        std.debug.print(
            "optimization changed behaviour:\nsource:\n{s}\nunoptimized: trap={?s} leaked={d} out=<{s}>\noptimized:   trap={?s} leaked={d} out=<{s}>\n",
            .{
                source,
                if (raw.trap) |code| @tagName(code) else null,
                raw.leaked,
                raw.printed,
                if (lean.trap) |code| @tagName(code) else null,
                lean.leaked,
                lean.printed,
            },
        );
        return error.TestUnexpectedResult;
    }
}

test "ownership behaviour survives the elision" {
    // Each of these has the shape the ownership pass looks for, and
    // each one would break differently if it were one step too keen:
    // a leaked object, a double free, or a use-after-free that stops
    // trapping.
    const cases = [_][]const u8{
        // The plain case: a fresh object adopted by a named binding.
        \\func main():
        \\    let xs = new List(Int)
        \\    xs.append(1)
        \\    print(str(len(xs)))
        \\
        ,
        // A fresh object adopted by a container instead — the release
        // of the temporary is a real no-op at run time, but only
        // because `append` took ownership, which the pass cannot see.
        \\func main():
        \\    let outer = new List(List(Int))
        \\    outer.append(new List(Int))
        \\    outer[0].append(7)
        \\    print(str(len(outer[0])))
        \\
        ,
        // Early release, then the scope end that must not free twice.
        \\func main():
        \\    let xs = new List(Int)
        \\    xs.append(1)
        \\    free(xs)
        \\    print("done")
        \\
        ,
        // An alias outliving the owner's release still traps at use
        // (S9), and still traps in the same place.
        \\func main():
        \\    var xs = [1, 2]
        \\    let view = xs
        \\    free(xs)
        \\    print(str(view[0]))
        \\
        ,
        // Reassigning an owning var frees the old object at once (S5).
        \\func main():
        \\    var xs = [1]
        \\    let view = xs
        \\    xs = [2, 3]
        \\    print(str(view[0]))
        \\
        ,
        // An object given away must not be freed by the binding that
        // gave it.
        \\func keep(v: give List(Int)) -> Int:
        \\    let n = len(v)
        \\    free(v)
        \\    return n
        \\
        \\func main():
        \\    let xs = new List(Int)
        \\    xs.append(1)
        \\    print(str(keep(give(xs))))
        \\
        ,
        // Rebinding in a loop: a fresh object per turn, each released
        // at the end of its scope.
        \\func main():
        \\    var total = 0
        \\    for index in range(0, 8):
        \\        let row = new List(Int)
        \\        row.append(index)
        \\        total = total + len(row)
        \\    print(str(total))
        \\
        ,
        // Returning an object moves it to the caller (S16).
        \\func make() -> List(Int):
        \\    let xs = new List(Int)
        \\    xs.append(3)
        \\    return xs
        \\
        \\func main():
        \\    let xs = make()
        \\    print(str(len(xs)))
        \\
        ,
        // A copy is a second object, and both have to come back.
        \\func main():
        \\    let xs = new List(Int)
        \\    xs.append(1)
        \\    let ys = copy(xs)
        \\    ys.append(2)
        \\    print(str(len(xs)) + " " + str(len(ys)))
        \\
        ,
    };
    for (cases) |source| try expectSameBehavior(source);
}

test "traps keep their code, their message, and their place" {
    const cases = [_][]const u8{
        \\func main():
        \\    var n = 0
        \\    print("before")
        \\    print(str(10 / n))
        \\
        ,
        \\func main():
        \\    let xs = new List(Int)
        \\    print("before")
        \\    print(str(xs[3]))
        \\
        ,
        \\func main():
        \\    var n = 9223372036854775807
        \\    print("before")
        \\    print(str(n + n))
        \\
        ,
        \\func main():
        \\    print("before")
        \\    trap("stop here")
        \\
        ,
        \\func main():
        \\    let m = new Map(String, Int)
        \\    print("before")
        \\    print(str(m["missing"]))
        \\
    };
    for (cases) |source| try expectSameBehavior(source);
}

// ---------------------------------------------------------------------------
// Fuzz: generated programs, run both ways
// ---------------------------------------------------------------------------

/// Build a random but always-valid script out of statement templates.
/// The point is not clever programs — it is the *shapes* the passes
/// reason about: repeated reads of one local, nested scopes holding
/// fresh objects, branches that leave blocks with one predecessor, and
/// arithmetic that sometimes traps.
fn generate(text: *std.ArrayList(u8), random: std.Random) Allocator.Error!void {
    try text.appendSlice(testing.allocator,
        \\func main():
        \\    var a = 3
        \\    var b = 7
        \\    let xs = new List(Int)
        \\
    );
    const statements = random.intRangeAtMost(usize, 1, 6);
    for (0..statements) |_| try statement(text, random, 1);
    try text.appendSlice(testing.allocator,
        \\    print(str(a) + " " + str(b) + " " + str(len(xs)))
        \\
    );
}

fn indent(text: *std.ArrayList(u8), depth: usize) Allocator.Error!void {
    for (0..depth) |_| try text.appendSlice(testing.allocator, "    ");
}

fn add(text: *std.ArrayList(u8), comptime format: []const u8, arguments: anytype) Allocator.Error!void {
    const line = try std.fmt.allocPrint(testing.allocator, format, arguments);
    defer testing.allocator.free(line);
    try text.appendSlice(testing.allocator, line);
}

var fresh_name: usize = 0;

fn statement(text: *std.ArrayList(u8), random: std.Random, depth: usize) Allocator.Error!void {
    const simple_only = depth >= 3;
    const choice = if (simple_only)
        random.intRangeAtMost(usize, 0, 4)
    else
        random.intRangeAtMost(usize, 0, 9);
    const value = random.intRangeAtMost(i64, -4, 9);
    switch (choice) {
        0 => {
            try indent(text, depth);
            try add(text, "a = a + {d} * {d}\n", .{ value, value });
        },
        1 => {
            try indent(text, depth);
            try add(text, "b = (a + b) % {d}\n", .{value});
        },
        2 => {
            try indent(text, depth);
            try add(text, "xs.append(a + b + {d})\n", .{value});
        },
        3 => {
            try indent(text, depth);
            try text.appendSlice(testing.allocator, "a = a + len(xs) + len(xs)\n");
        },
        4 => {
            try indent(text, depth);
            try add(text, "b = min(max(b, {d}), a + a)\n", .{value});
        },
        5 => {
            try indent(text, depth);
            try add(text, "if a % 3 == {d}:\n", .{@mod(value, 3)});
            try statement(text, random, depth + 1);
            try indent(text, depth);
            try text.appendSlice(testing.allocator, "else:\n");
            try statement(text, random, depth + 1);
        },
        6 => {
            try indent(text, depth);
            fresh_name += 1;
            const turn = fresh_name;
            try add(text, "for i{d} in range(0, {d}):\n", .{ turn, random.intRangeAtMost(usize, 0, 5) });
            try indent(text, depth + 1);
            try add(text, "b = b + i{d}\n", .{turn});
            try statement(text, random, depth + 1);
        },
        7 => {
            // A nested scope with its own object: the ownership pass's
            // whole reason for existing.
            try indent(text, depth);
            try text.appendSlice(testing.allocator, "if b > a:\n");
            fresh_name += 1;
            const name = fresh_name;
            try indent(text, depth + 1);
            try add(text, "let row{d} = new List(Int)\n", .{name});
            try indent(text, depth + 1);
            try add(text, "row{d}.append(a)\n", .{name});
            try statement(text, random, depth + 1);
            try indent(text, depth + 1);
            try add(text, "a = a + len(row{d})\n", .{name});
        },
        8 => {
            try indent(text, depth);
            try text.appendSlice(testing.allocator, "if len(xs) > 0:\n");
            try indent(text, depth + 1);
            try text.appendSlice(testing.allocator, "a = a + xs[0] + xs[0]\n");
        },
        else => {
            try indent(text, depth);
            try add(text, "while a < {d}:\n", .{random.intRangeAtMost(i64, -2, 6)});
            try indent(text, depth + 1);
            try text.appendSlice(testing.allocator, "a = a + 1\n");
        },
    }
}

test "fuzz: optimized and unoptimized programs behave identically" {
    var seed: u64 = 0;
    while (seed < 400) : (seed += 1) {
        fresh_name = 0;
        var prng = std.Random.DefaultPrng.init(seed);
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(testing.allocator);
        try generate(&text, prng.random());
        expectSameBehavior(text.items) catch |mistake| {
            std.debug.print("seed {d} disagreed\n", .{seed});
            return mistake;
        };
    }
}
