//! Driver tests — integration coverage for the whole compiler, from
//! source bytes through verified, optimized MIR.

const std = @import("std");
const types = @import("../support/types.zig");
const mir = @import("../06_mir.zig");
const compile_mod = @import("../compile.zig");
const luce_source = @import("../01_source.zig");

const testing = std.testing;

fn expectCompiles(source: []const u8) !mir.Program {
    return expectCompilesOptions(source, .{});
}

fn expectCompilesOptions(source: []const u8, options: types.CompileOptions) !mir.Program {
    var result = try compile_mod.compile(testing.allocator, source, options);
    switch (result) {
        .success => |program| return program,
        .failure => |*diagnostics| {
            const rendered = try diagnostics.render(testing.allocator);
            defer testing.allocator.free(rendered);
            std.debug.print("unexpected diagnostics:\n{s}", .{rendered});
            result.deinit();
            return error.TestUnexpectedResult;
        },
    }
}

fn expectFails(source: []const u8, expected_code: []const u8) !void {
    return expectFailsOptions(source, .{}, expected_code);
}

fn expectFailsOptions(
    source: []const u8,
    options: types.CompileOptions,
    expected_code: []const u8,
) !void {
    var result = try compile_mod.compile(testing.allocator, source, options);
    defer result.deinit();
    switch (result) {
        .success => return error.TestUnexpectedResult,
        .failure => |diagnostics| {
            for (0..diagnostics.count()) |index| {
                if (std.mem.eql(u8, diagnostics.at(index).?.code, expected_code)) return;
            }
            const rendered = try diagnostics.render(testing.allocator);
            defer testing.allocator.free(rendered);
            std.debug.print("wanted {s}, got:\n{s}", .{ expected_code, rendered });
            return error.TestUnexpectedResult;
        },
    }
}

const source_mod = @import("../01_source.zig");

fn printDiagnostics(diagnostics: *const compile_mod.CompileResult) void {
    if (diagnostics.* == .success) return;
    const rendered = diagnostics.failure.render(testing.allocator) catch return;
    defer testing.allocator.free(rendered);
    std.debug.print("actual diagnostics:\n{s}", .{rendered});
}

const Expected = struct { code: []const u8, line: usize, column: usize };

/// Assert the full ordered set of diagnostics a bad program produces,
/// each by stable code AND source location.  Zig's test/cases corpus
/// pins line:column on every expected error; nothing in our suite did
/// until here, so a diagnostic silently retargeting to the wrong
/// token — invisible to a code-only check, and this is an
/// editor-facing project where the span IS the product — now fails a
/// test.  Wording stays unasserted per the coding guide.
fn expectDiagnostics(source: []const u8, options: types.CompileOptions, wanted: []const Expected) !void {
    var result = try compile_mod.compile(testing.allocator, source, options);
    defer result.deinit();
    if (result == .success) {
        std.debug.print("expected diagnostics, but this compiled:\n{s}", .{source});
        return error.TestUnexpectedResult;
    }
    const diagnostics = &result.failure;
    errdefer printDiagnostics(&result);
    try testing.expectEqual(wanted.len, diagnostics.count());
    for (wanted, 0..) |want, index| {
        const item = diagnostics.at(index).?;
        try testing.expectEqualStrings(want.code, item.code);
        const at = source_mod.place(source, item.span.start);
        try testing.expectEqual(want.line, at.line);
        try testing.expectEqual(want.column, at.column);
    }
}

test "func is strict and fn is an ordinary identifier" {
    try expectFails(
        \\fn main():
        \\    return
        \\
    , "luce.parse.top");
}

test "lexer diagnostics carry the right code and location, and do not cascade" {
    // A tab indent, a number glued to letters, an unterminated string:
    // each is one lexer diagnostic at a known place and *nothing else*.
    // Stage 2 recovers — the tab still opens the block, the bad number
    // still yields its digits, the broken string still yields a
    // literal — so the parser has no second complaint to make.
    try expectDiagnostics(
        "func main():\n\tlet a = 1\n",
        .{},
        &.{.{ .code = "luce.lex.tab", .line = 2, .column = 1 }},
    );
    try expectDiagnostics(
        "func main():\n    let a = 12ab\n",
        .{},
        &.{.{ .code = "luce.lex.number", .line = 2, .column = 13 }},
    );
    try expectDiagnostics(
        "func main():\n    let a = \"open\n",
        .{},
        &.{.{ .code = "luce.lex.string", .line = 2, .column = 13 }},
    );
}

test "parser diagnostics carry the right code and location" {
    try expectDiagnostics(
        "let 3 = 4\n",
        .{},
        &.{.{ .code = "luce.parse.expected", .line = 1, .column = 5 }},
    );
}

test "semantic diagnostics carry the right code and location" {
    // An unknown type, pointed at the annotation.
    try expectDiagnostics(
        \\func main():
        \\    var x: Widget = 1
        \\
    , .{}, &.{.{ .code = "luce.sema.type", .line = 2, .column = 12 }});
    // A bad conversion argument, pointed at the call.
    try expectDiagnostics(
        \\func main():
        \\    let x = Int("no")
        \\
    , .{}, &.{.{ .code = "luce.sema.convert", .line = 2, .column = 13 }});
    // An unknown field, pointed at the access.
    try expectDiagnostics(
        \\struct Point:
        \\    x: Float
        \\
        \\func main():
        \\    var p = Point(x = 1.0)
        \\    let y = p.y
        \\
    , .{}, &.{.{ .code = "luce.sema.field", .line = 6, .column = 13 }});
}

test "the previously-unasserted diagnostic codes fire" {
    // A single-case-per-code sweep for codes no other test pinned,
    // so each stays reachable and keeps its stable name.
    const Case = struct { source: []const u8, code: []const u8 };
    const cases = [_]Case{
        // A control character the lexer has no use for.  (A NUL byte
        // never gets this far: stage 1 refuses the file.)
        .{ .source = "func main():\n    let a = 1\x01\n", .code = "luce.lex.character" },
        .{ .source = "func main():\n    let a = \"\\q\"\n", .code = "luce.lex.escape" },
        .{ .source = "func main():\n    let a = @\n", .code = "luce.parse.expression" },
        .{ .source = "func main():\n    let a: List = []\n", .code = "luce.sema.type" },
        .{ .source = "func main():\n    let a = new Array(Int)\n", .code = "luce.sema.new" },
        .{ .source = "func main():\n    let a = 99999999999999999999999\n", .code = "luce.sema.literal" },
    };
    for (cases) |case| {
        try expectFailsOptions(case.source, .{}, case.code);
    }
}

test "the pipeline survives every allocation failure" {
    // A ratchet, not a bug-finder (all four pass today): the moment
    // someone adds a non-arena cache or an ArrayList that outlives an
    // error path, this catches the leak or the swallowed OOM.  Also
    // enforces error.NondeterministicMemoryUsage.
    const representative =
        \\struct Point:
        \\    x: Float
        \\    tag: String
        \\
        \\func total(values: List(Int)) -> Int:
        \\    var sum = 0
        \\    for value in values:
        \\        sum = sum + value
        \\    return sum
        \\
        \\func main():
        \\    var xs = [3, 1, 2]
        \\    xs.sort()
        \\    var ages = new Map(String, Int)
        \\    ages["ada"] = total(xs)
        \\    print(str(ages["ada"]))
        \\
    ;
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            var result = try compile_mod.compile(gpa, representative, .{ .allow_host = true });
            result.deinit();
        }
    }.run, .{});
}

test "decode survives every allocation failure" {
    var program = try expectCompiles(
        \\func main():
        \\    var value = 21
        \\    assert(value * 2 == 42)
        \\
    );
    defer program.deinit();
    const module = @import("../06_mir.zig").module;
    const encoded = try module.encode(testing.allocator, &program);
    defer testing.allocator.free(encoded);
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: std.mem.Allocator, bytes: []const u8) !void {
            var decoded = module.decode(gpa, bytes) catch |mistake| switch (mistake) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return,
            };
            decoded.deinit();
        }
    }.run, .{encoded});
}

test "the entry is exactly func main(), and nothing else will do" {
    try expectFails(
        \\func helper() -> Int:
        \\    return 1
        \\
    , "luce.sema.main");
    try expectFails(
        \\func main(value: Int):
        \\    return
        \\
    , "luce.sema.main");
    try expectFails(
        \\func main() -> Int:
        \\    return 1
        \\
    , "luce.sema.main");

    var script = try compile_mod.compile(testing.allocator,
        \\func main():
        \\    return
        \\
    , .{});
    defer script.deinit();
    try testing.expect(script == .success);

    // `func main() -> !:` is the other legal shape: a program that
    // says the world can stop it (docs/FAILURE.md).
    var fallible = try compile_mod.compile(testing.allocator,
        \\func main() -> !:
        \\    return
        \\
    , .{});
    defer fallible.deinit();
    try testing.expect(fallible == .success);
}

test "struct namespaces collect functions and reject invalid members" {
    var program = try expectCompiles(
        \\struct Math:
        \\    func double(value: Int) -> Int:
        \\        return value * 2
        \\
        \\struct Pair:
        \\    left: Int
        \\    func sum(left: Int, right: Int) -> Int:
        \\        return left + right
        \\
        \\func main():
        \\    assert(Math.double(Pair.sum(3, 4)) == 14)
        \\
    );
    defer program.deinit();
    try testing.expectEqualStrings("Math.double", program.functions[1].name);

    try expectFails(
        \\struct Bad:
        \\    value: Int
        \\    func value() -> Int:
        \\        return 1
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.duplicate");
    try expectFails(
        \\struct Helpers:
        \\    func one() -> Int:
        \\        return 1
        \\
        \\func main():
        \\    let bad = Helpers.missing()
        \\
    , "luce.sema.call");
    try expectFails(
        \\struct Helpers:
        \\    func one() -> Int:
        \\        return 1
        \\
        \\func main():
        \\    let bad = Helpers()
        \\
    , "luce.sema.construct");
}

test "the plan's scale example compiles and verifies" {
    var program = try expectCompiles(
        \\struct Point:
        \\    x: Float
        \\    y: Float
        \\
        \\func scale_point(point: Point, factor: Float) -> Point:
        \\    return Point(
        \\        x = point.x * factor,
        \\        y = point.y * factor,
        \\    )
        \\
        \\func main():
        \\    let position = Point(x = 1.0, y = 2.0)
        \\    let scaled = scale_point(position, 3.0)
        \\    assert(scaled.x == 3.0)
        \\    assert(scaled.y == 6.0)
        \\
    );
    defer program.deinit();

    try testing.expectEqual(@as(usize, 1), program.structs.len);
    try testing.expectEqual(@as(usize, 2), program.functions.len);
}

test "control flow, loops, and builtins compile and verify" {
    var program = try expectCompiles(
        \\func main():
        \\    var total = 0
        \\    for index in range(0, 10):
        \\        if index % 2 == 0 and index != 4:
        \\            total = total + index
        \\        elif index == 5:
        \\            continue
        \\        else:
        \\            total = max(total, index)
        \\    while total > 100:
        \\        total = total - 1
        \\    assert(clamp(total, 0, 50) == 20)
        \\
    );
    defer program.deinit();
}

test "functions unreachable from the entry are pruned from the artifact" {
    // A std import brings its whole module; what is never called must
    // not reach the .lc, the decoder, or an engine (docs/PIPELINE.md,
    // stage 9).
    var unused = try expectCompilesOptions(
        \\import std.strings
        \\
        \\func main():
        \\    print("hi")
        \\
    , .{ .allow_host = true });
    defer unused.deinit();
    try testing.expectEqual(@as(usize, 1), unused.functions.len);

    // Calling one std function keeps it (and its callees) by name and
    // still drops the rest of the module — asserted by name, not by
    // count, so an innocent std refactor cannot break this test.
    var used = try expectCompilesOptions(
        \\import std.strings
        \\
        \\func main():
        \\    print(str("abc".find("b")))
        \\
    , .{ .allow_host = true });
    defer used.deinit();
    var kept_find = false;
    var kept_dead = false;
    for (used.functions) |function| {
        if (std.mem.endsWith(u8, function.name, "find")) kept_find = true;
        if (std.mem.endsWith(u8, function.name, "split") or
            std.mem.endsWith(u8, function.name, "upper")) kept_dead = true;
    }
    try testing.expect(kept_find);
    try testing.expect(!kept_dead);

    // Nothing dead survived: every kept function is reachable from
    // the entry by re-walking the call graph.
    const reached = try testing.allocator.alloc(bool, used.functions.len);
    defer testing.allocator.free(reached);
    @memset(reached, false);
    reached[used.entry_function] = true;
    var scan = true;
    while (scan) {
        scan = false;
        for (used.functions, 0..) |function, index| {
            if (!reached[index]) continue;
            for (function.instructions) |instruction| {
                switch (instruction) {
                    .call => |call| if (!reached[call.function]) {
                        reached[call.function] = true;
                        scan = true;
                    },
                    else => {},
                }
            }
        }
    }
    for (reached) |live| try testing.expect(live);
}

test "the IR dump is readable and deterministic" {
    const source =
        \\func main():
        \\    var value = 21
        \\    let doubled = value * 2
        \\    assert(doubled == 42)
        \\
    ;
    var program = try expectCompiles(source);
    defer program.deinit();
    const first = try mir.print(testing.allocator, &program);
    defer testing.allocator.free(first);

    var again = try expectCompiles(source);
    defer again.deinit();
    const second = try mir.print(testing.allocator, &again);
    defer testing.allocator.free(second);

    try testing.expectEqualStrings(first, second);
    try testing.expect(std.mem.indexOf(u8, first, "func main() -> None") != null);
    try testing.expect(std.mem.indexOf(u8, first, "local %0 value: Int") != null);
    try testing.expect(std.mem.indexOf(u8, first, "multiply.Int") != null);
}

test "the IR dump has a stable golden shape (short-circuit + ownership)" {
    // A full-dump snapshot of the two trickiest lowerings at once:
    // short-circuit `and` splitting a block, and scope ownership
    // inserting object_bind/object_unbind around the list.  Behavior
    // tests can't see block ordering or a lost temp release; this
    // does, and it documents the IR for a reader.  Regenerate
    // deliberately when lowering changes on purpose.
    //
    // This is the *optimized* program — what `luce build` writes and
    // what an engine runs.  Stage 7 has already been over it: the
    // hidden temporary's bind and its inert release are gone
    // (07_optimize/ownership.zig), and the reads of `xs` inside the
    // first block are the register the list was stored from
    // (07_optimize/values.zig).  `luce ir --full` prints the raw
    // lowering instead.  The temporary is still in the local table:
    // `give`/`free` carry a local id as an integer value, so nothing
    // may renumber locals yet (07_optimize/dead.zig).
    var program = try expectCompilesOptions(
        \\func main():
        \\    var xs = [1, 2]
        \\    if len(xs) > 0 and xs[0] == 1:
        \\        xs.append(3)
        \\
    , .{});
    defer program.deinit();
    const dump = try mir.print(testing.allocator, &program);
    defer testing.allocator.free(dump);
    try testing.expectEqualStrings(
        \\func main() -> None
        \\    local %0 (temporary): List(Int)
        \\    local %1 xs: List(Int)
        \\    local %2 (temporary): Bool
        \\  b0:
        \\    r0 = const 1
        \\    r1 = const 2
        \\    r2 = heap_new List(Int)
        \\    intrinsic append_value, r2, r0
        \\    intrinsic append_value, r2, r1
        \\    local_set %1, r2
        \\    object_bind %1, r2
        \\    r7 = intrinsic len, r2
        \\    r8 = const 0
        \\    r9 = greater.Int r7, r8
        \\    local_set %2, r9
        \\    branch r9, b1, b2
        \\  b1:
        \\    r12 = local_get %1
        \\    r13 = const 0
        \\    r14 = intrinsic index_get, r12, r13
        \\    r15 = const 1
        \\    r16 = equal.Int r14, r15
        \\    local_set %2, r16
        \\    jump b2
        \\  b2:
        \\    r19 = local_get %2
        \\    branch r19, b3, b4
        \\  b3:
        \\    r21 = local_get %1
        \\    r22 = const 3
        \\    intrinsic append_value, r21, r22
        \\    jump b4
        \\  b4:
        \\    r25 = local_get %1
        \\    object_unbind %1, r25
        \\    ret
        \\
    , dump);
}

test "no implicit conversion, no reassigned let, no shadowing" {
    try expectFails(
        \\func main():
        \\    let mixed = 1 + 2.0
        \\
    , "luce.sema.type");
    try expectFails(
        \\func main():
        \\    let once = 1
        \\    once = 2
        \\
    , "luce.sema.let");
    try expectFails(
        \\func main():
        \\    let name = 1
        \\    if true:
        \\        let name = 2
        \\
    , "luce.sema.duplicate");
    try expectFails(
        \\func main():
        \\    let value: Float = 3
        \\
    , "luce.sema.type");
}

test "return paths are checked on every branch" {
    try expectFails(
        \\func partial(flag: Bool) -> Int:
        \\    if flag:
        \\        return 1
        \\
        \\func main():
        \\    let unused = partial(true)
        \\
    , "luce.sema.return");
}

test "struct construction is complete, named, and typed" {
    const source_prefix =
        \\struct Color:
        \\    red: Float
        \\    green: Float
        \\
    ;
    try expectFails(source_prefix ++
        \\func main():
        \\    let missing = Color(red = 1.0)
        \\
    , "luce.sema.construct");
    try expectFails(source_prefix ++
        \\func main():
        \\    let doubled = Color(red = 1.0, red = 2.0, green = 3.0)
        \\
    , "luce.sema.construct");
    try expectFails(source_prefix ++
        \\func main():
        \\    let wrong = Color(red = 1, green = 2.0)
        \\
    , "luce.sema.type");
    try expectFails(
        \\struct Loop:
        \\    inner: Loop
        \\
        \\func main():
        \\    let never = 1
        \\
    , "luce.sema.struct");
}

test "calls check arity, types, and none results" {
    try expectFails(
        \\func helper(value: Int) -> Int:
        \\    return value
        \\
        \\func main():
        \\    let wrong = helper(1, 2)
        \\
    , "luce.sema.call");
    try expectFails(
        \\func nothing():
        \\    return
        \\
        \\func main():
        \\    let value = nothing()
        \\
    , "luce.sema.call");
    try expectFails(
        \\func main():
        \\    let bad = sqrt(4)
        \\
    , "luce.sema.type");
    try expectFails(
        \\func main():
        \\    let bad = unknown_helper(1)
        \\
    , "luce.sema.call");
}

test "break and continue require a loop" {
    try expectFails(
        \\func main():
        \\    break
        \\
    , "luce.sema.loop");
}

test "var struct fields update through functional struct_set" {
    var program = try expectCompiles(
        \\struct Point:
        \\    x: Float
        \\    y: Float
        \\
        \\func main():
        \\    var point = Point(x = 0.0, y = 0.0)
        \\    point.x = 4.5
        \\    assert(point.x == 4.5)
        \\
    );
    defer program.deinit();
    const dump = try mir.print(testing.allocator, &program);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "struct_set") != null);
}

test "string operations type-check" {
    var program = try expectCompiles(
        \\func main():
        \\    var name = "world"
        \\    let greeting = "hello, " + name
        \\    var text = ""
        \\    if len(greeting) > 3 and greeting != "":
        \\        text = greeting
        \\    else:
        \\        text = "short"
        \\    assert(text == "hello, world")
        \\
    );
    defer program.deinit();
}

test "host builtins type-check and stay host-gated" {
    try expectFails(
        \\func main():
        \\    print("hello")
        \\
    , "luce.sema.host");
    try expectFails(
        \\func main():
        \\    let text = file_read("notes.txt")
        \\
    , "luce.sema.host");

    var hosted = try compile_mod.compile(testing.allocator,
        \\func main() -> !:
        \\    print("hello " + arg(0))
        \\    let text = file_read("notes.txt") catch ""
        \\    try file_write("copy.txt", text)
        \\    print("copied")
        \\    term_clear()
        \\    term_move(0, 0)
        \\    term_style(114, -1, false)
        \\    term_write(key_read() + key_text())
        \\    term_flush()
        \\
    , .{ .allow_host = true });
    defer hosted.deinit();
    try testing.expect(hosted == .success);

    try expectFailsOptions(
        \\func main() -> !:
        \\    let bad = try file_read(7)
        \\
    , .{ .allow_host = true }, "luce.sema.type");
    // A call that can fail may not be written as if it could not:
    // this is the shape `if files.write_lines(...)` used to have, and
    // it is the whole of why a swallowed failure is now unwritable.
    try expectFailsOptions(
        \\func main():
        \\    let text = file_read("notes.txt")
        \\
    , .{ .allow_host = true }, "luce.sema.fallible");
    // And `try` needs a caller that said it can fail.
    try expectFailsOptions(
        \\func main():
        \\    let text = try file_read("notes.txt")
        \\
    , .{ .allow_host = true }, "luce.sema.fallible");
    try expectFailsOptions(
        \\func main():
        \\    term_style(1, 2, 3)
        \\
    , .{ .allow_host = true }, "luce.sema.type");
}

test "collections type-check and reject misuse at compile time" {
    const script: types.CompileOptions = .{};

    var featured = try compile_mod.compile(testing.allocator,
        \\func sum(values: List(Int)) -> Int:
        \\    var total = 0
        \\    for value in values:
        \\        total = total + value
        \\    return total
        \\
        \\func label(counts: Map(String, Int), grid: Array(Int, _, _)) -> String:
        \\    var b = new Builder()
        \\    b.append(str(len(counts) + grid[0, 0]))
        \\    let made = str(b)
        \\    free(b)
        \\    return made
        \\
        \\func main():
        \\    var values: List(Int) = []
        \\    values.append(4)
        \\    let total = sum(values[0:])
        \\    free(values)
        \\
    , script);
    defer featured.deinit();
    try testing.expect(featured == .success);

    try expectFailsOptions(
        \\func main():
        \\    let mixed = [1, "two"]
        \\
    , script, "luce.sema.type");
    try expectFailsOptions(
        \\func main():
        \\    var untyped = []
        \\
    , script, "luce.sema.type");
    try expectFailsOptions(
        \\func main():
        \\    var m = new Map(Float, Int)
        \\
    , script, "luce.sema.type");
    try expectFailsOptions(
        \\func main():
        \\    var grid = new Array(Int, 2, 2)
        \\    let bad = grid[0]
        \\
    , script, "luce.sema.index");
    try expectFailsOptions(
        \\func main():
        \\    var m = new Map(String, Int)
        \\    let bad = m[7]
        \\
    , script, "luce.sema.index");
    try expectFailsOptions(
        \\func main():
        \\    let bad = 5.append(1)
        \\
    , script, "luce.sema.method");
    try expectFailsOptions(
        \\func main():
        \\    for x in 7:
        \\        let unused = x
        \\
    , script, "luce.sema.loop");
    try expectFailsOptions(
        \\func main():
        \\    let xs = [1]
        \\    let bad = xs < xs
        \\
    , script, "luce.sema.type");
    try expectFailsOptions(
        \\func main():
        \\    var xs = [1]
        \\    xs[0] = "text"
        \\
    , script, "luce.sema.type");
}

// ---------------------------------------------------------------------------
// Modules
// ---------------------------------------------------------------------------

const TestModule = struct { name: []const u8, source: []const u8 };

const TestLoader = struct {
    modules: []const TestModule,
    /// Names that exist but cannot be read — a directory, a
    /// permission: the host's other answer.
    locked: []const []const u8 = &.{},

    fn load(context: *anyopaque, arena: std.mem.Allocator, name: []const u8) error{OutOfMemory}!luce_source.Found {
        const self: *TestLoader = @ptrCast(@alignCast(context));
        for (self.locked) |locked| {
            if (std.mem.eql(u8, locked, name)) return .{ .unreadable = "permission denied" };
        }
        for (self.modules) |module| {
            if (std.mem.eql(u8, module.name, name)) {
                return .{ .text = .{ .bytes = try arena.dupe(u8, module.source) } };
            }
        }
        return .missing;
    }

    fn loader(self: *TestLoader) compile_mod.Loader {
        return .{ .context = self, .loadFn = load };
    }
};

const geo_module: TestModule = .{ .name = "geo", .source =
    \\import util
    \\
    \\struct Point:
    \\    x: Float
    \\    y: Float
    \\
    \\struct Text:
    \\    func double(value: Int) -> Int:
    \\        return value * 2
    \\
    \\func make(x: Float, y: Float) -> Point:
    \\    return Point(x = x, y = y)
    \\
    \\func length(point: Point) -> Float:
    \\    return util.hypot(point.x, point.y)
    \\
};

const util_module: TestModule = .{ .name = "util", .source =
    \\func hypot(x: Float, y: Float) -> Float:
    \\    return sqrt(x * x + y * y)
    \\
};

test "imports are explicit, checked, and reported per file" {
    const script: types.CompileOptions = .{};
    var files: TestLoader = .{ .modules = &.{ geo_module, util_module } };

    // Reaching a loaded-but-unimported namespace names the fix; a
    // namespace nothing loaded is an ordinary unknown name.
    var unimported = try compile_mod.compileProject(testing.allocator,
        \\import geo
        \\
        \\func main():
        \\    let bad = util.hypot(3.0, 4.0)
        \\
    , files.loader(), script);
    defer unimported.deinit();
    try testing.expect(unimported == .failure);
    try testing.expectEqualStrings("luce.sema.import", unimported.failure.at(0).?.code);
    var unknown = try compile_mod.compileProject(testing.allocator,
        \\func main():
        \\    let bad = geo.make(1.0, 2.0)
        \\
    , files.loader(), script);
    defer unknown.deinit();
    try testing.expect(unknown == .failure);
    try testing.expectEqualStrings("luce.sema.name", unknown.failure.at(0).?.code);

    // A missing module file reports where the import was written.
    var missing = try compile_mod.compileProject(testing.allocator,
        \\import ghost
        \\
        \\func main():
        \\    return
        \\
    , files.loader(), script);
    defer missing.deinit();
    try testing.expect(missing == .failure);
    try testing.expectEqualStrings("luce.import.missing", missing.failure.at(0).?.code);

    // Without a loader, imports cannot resolve at all.
    var lonely = try compile_mod.compile(testing.allocator,
        \\import geo
        \\
        \\func main():
        \\    return
        \\
    , script);
    defer lonely.deinit();
    try testing.expect(lonely == .failure);
    try testing.expectEqualStrings("luce.import.missing", lonely.failure.at(0).?.code);

    // An error inside an imported module renders against that file.
    const broken: TestModule = .{ .name = "broken", .source =
        \\func helper() -> Int:
        \\    return "not an int"
        \\
    };
    var broken_files: TestLoader = .{ .modules = &.{broken} };
    var imported_error = try compile_mod.compileProject(testing.allocator,
        \\import broken
        \\
        \\func main():
        \\    let bad = broken.helper()
        \\
    , broken_files.loader(), script);
    defer imported_error.deinit();
    try testing.expect(imported_error == .failure);
    const rendered = try imported_error.failure.render(testing.allocator);
    defer testing.allocator.free(rendered);
    try testing.expect(std.mem.indexOf(u8, rendered, "broken.luc:2:") != null);
}

test "every way an import can fail is a diagnostic, not a crash or an empty module" {
    const script: types.CompileOptions = .{};
    const uses_geo =
        \\import geo
        \\
        \\func main():
        \\    let bad = geo.area()
        \\
    ;

    // Present but unreadable is not the same as absent: the message
    // says why, so the fix is different.
    var locked: TestLoader = .{ .modules = &.{}, .locked = &.{"geo"} };
    var unreadable = try compile_mod.compileProject(testing.allocator, uses_geo, locked.loader(), script);
    defer unreadable.deinit();
    try testing.expect(unreadable == .failure);
    try testing.expectEqualStrings("luce.import.unreadable", unreadable.failure.at(0).?.code);
    try testing.expect(std.mem.indexOf(u8, unreadable.failure.at(0).?.message, "permission denied") != null);

    // A module whose bytes are not text is refused at the import that
    // asked for it, naming the file it could not become.
    var binary: TestLoader = .{ .modules = &.{
        .{ .name = "geo", .source = "func area() -> Int:\n    return \x00\n" },
    } };
    var not_text = try compile_mod.compileProject(testing.allocator, uses_geo, binary.loader(), script);
    defer not_text.deinit();
    try testing.expect(not_text == .failure);
    try testing.expectEqualStrings("luce.source.binary", not_text.failure.at(0).?.code);
    try testing.expect(std.mem.indexOf(u8, not_text.failure.at(0).?.message, "geo.luc") != null);
    // Attributed to the file that wrote the import, at line 1.
    const at = not_text.failure.sources.place(
        not_text.failure.at(0).?.file,
        not_text.failure.at(0).?.span.start,
    );
    try testing.expectEqual(@as(usize, 1), at.line);

    // A module that imports itself says so, instead of quietly
    // resolving to the module already being loaded.
    var recursive: TestLoader = .{ .modules = &.{
        .{ .name = "geo", .source = "import geo\n\nfunc area() -> Int:\n    return 4\n" },
    } };
    var itself = try compile_mod.compileProject(testing.allocator, uses_geo, recursive.loader(), script);
    defer itself.deinit();
    try testing.expect(itself == .failure);
    try testing.expectEqualStrings("luce.import.self", itself.failure.at(0).?.code);
    try testing.expectEqualStrings("geo.luc", itself.failure.sources.pathOf(itself.failure.at(0).?.file));
}

test "std is a namespace, not a reserved name: a sibling module may be called math" {
    const script: types.CompileOptions = .{};
    var files: TestLoader = .{ .modules = &.{
        .{ .name = "math", .source = "func answer() -> Int:\n    return 42\n" },
    } };

    // `import math` is the file beside the program.  The library takes
    // nothing away from it — `answer` exists nowhere else, so compiling
    // at all proves which module was reached.
    var sibling = try compile_mod.compileProject(testing.allocator,
        \\import math
        \\
        \\func main():
        \\    assert(math.answer() == 42)
        \\
    , files.loader(), script);
    defer sibling.deinit();
    if (sibling == .failure) {
        printDiagnostics(&sibling);
        return error.TestUnexpectedResult;
    }

    // `import std.math` is the library, with no loader at all.
    var library = try compile_mod.compile(testing.allocator,
        \\import std.math
        \\
        \\func main():
        \\    assert(math.ipow(2, 5) == 32)
        \\
    , script);
    defer library.deinit();
    if (library == .failure) {
        printDiagnostics(&library);
        return error.TestUnexpectedResult;
    }

    // Both at once is one binding for two modules, and there is no
    // `as` to tell them apart: the message names the file to rename.
    var collision = try compile_mod.compileProject(testing.allocator,
        \\import std.math
        \\import math
        \\
        \\func main():
        \\    assert(math.answer() == 42)
        \\
    , files.loader(), script);
    defer collision.deinit();
    try testing.expect(collision == .failure);
    try testing.expectEqualStrings("luce.import.collision", collision.failure.at(0).?.code);
    try testing.expect(std.mem.indexOf(u8, collision.failure.at(0).?.message, "std.math") != null);
    try testing.expect(std.mem.indexOf(u8, collision.failure.at(0).?.message, "math.luc") != null);
}

test "a missing import is spelled the way the author would have to write it" {
    const script: types.CompileOptions = .{};
    var files: TestLoader = .{ .modules = &.{
        .{ .name = "math", .source = "func answer() -> Int:\n    return 42\n" },
        .{ .name = "user", .source = "import math\n\nfunc go() -> Int:\n    return math.answer()\n" },
    } };

    // A sibling math.luc is in the program, so the fix is `import
    // math` — the library must not claim a name it does not hold here.
    var sibling = try compile_mod.compileProject(testing.allocator,
        \\import user
        \\
        \\func main():
        \\    assert(math.answer() == user.go())
        \\
    , files.loader(), script);
    defer sibling.deinit();
    try testing.expect(sibling == .failure);
    try testing.expectEqualStrings("luce.sema.import", sibling.failure.at(0).?.code);
    try testing.expect(std.mem.indexOf(u8, sibling.failure.at(0).?.message, "import math to use it") != null);

    // Nothing is loaded under the name, and the library does hold it:
    // the hint carries the namespace.
    var library = try compile_mod.compileProject(testing.allocator,
        \\func main():
        \\    let p: math.Angle = 1
        \\
    , files.loader(), script);
    defer library.deinit();
    try testing.expect(library == .failure);
    try testing.expectEqualStrings("luce.sema.import", library.failure.at(0).?.code);
    try testing.expect(std.mem.indexOf(u8, library.failure.at(0).?.message, "import std.math") != null);
}

test "the std namespace holds the library and nothing else" {
    const script: types.CompileOptions = .{};
    // A file really named std.luc, which the namespace makes
    // unreachable — said plainly rather than resolved behind the
    // author's back.
    var files: TestLoader = .{ .modules = &.{
        .{ .name = "std", .source = "func nothing():\n    return\n" },
    } };

    var absent = try compile_mod.compileProject(testing.allocator,
        \\import std.nope
        \\
        \\func main():
        \\    return
        \\
    , files.loader(), script);
    defer absent.deinit();
    try testing.expect(absent == .failure);
    try testing.expectEqualStrings("luce.import.standard", absent.failure.at(0).?.code);
    // Naming what does exist is the whole value of the message.
    try testing.expect(std.mem.indexOf(u8, absent.failure.at(0).?.message, "std.strings") != null);

    var bare = try compile_mod.compileProject(testing.allocator,
        \\import std
        \\
        \\func main():
        \\    return
        \\
    , files.loader(), script);
    defer bare.deinit();
    try testing.expect(bare == .failure);
    try testing.expectEqualStrings("luce.import.reserved", bare.failure.at(0).?.code);
    try testing.expect(std.mem.indexOf(u8, bare.failure.at(0).?.message, "std.luc") != null);
}

test "a project's diagnostics name every file they come from" {
    // Three files, three problems, one rendering: the root, a sibling
    // module, and the standard library.  Without a per-diagnostic
    // file this could only ever print one file's line numbers.
    var files: TestLoader = .{ .modules = &.{
        .{ .name = "geo", .source =
        \\func area() -> Int:
        \\    return "not an int"
        \\
        },
    } };
    var result = try compile_mod.compileProject(testing.allocator,
        \\import geo
        \\import std.math
        \\
        \\func main():
        \\    let bad: Int = geo.area()
        \\    let worse: Int = math.pi
        \\
    , files.loader(), .{ .source_name = "program.luc" });
    defer result.deinit();
    try testing.expect(result == .failure);

    const rendered = try result.failure.render(testing.allocator);
    defer testing.allocator.free(rendered);
    try testing.expect(std.mem.indexOf(u8, rendered, "geo.luc:2:") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "program.luc:6:") != null);
    // The root is named too, not left as a bare line:column.
    try testing.expect(std.mem.indexOf(u8, rendered, "program.luc:") != null);
}

test "an import cycle compiles; what may not be circular is checked finer" {
    // The policy, written down (compile/modules.zig): a Luce module
    // has no initialization phase, so there is nothing to catch half
    // done and no reason to inherit Python's partially initialized
    // module.  A three-file ring loads and compiles; that it also
    // *runs* is a two-engine fact and is proved in
    // `specs/modules_spec.zig`.
    const script: types.CompileOptions = .{};
    var ring: TestLoader = .{ .modules = &.{
        .{ .name = "a", .source = "import b\n\nfunc step(v: Int) -> Int:\n    if v == 0:\n        return 0\n    return b.step(v - 1)\n" },
        .{ .name = "b", .source = "import c\n\nfunc step(v: Int) -> Int:\n    return c.step(v)\n" },
        .{ .name = "c", .source = "import a\n\nfunc step(v: Int) -> Int:\n    return a.step(v)\n" },
    } };
    var looped = try compile_mod.compileProject(testing.allocator,
        \\import a
        \\
        \\func main():
        \\    assert(a.step(9) == 0)
        \\
    , ring.loader(), script);
    defer looped.deinit();
    printDiagnostics(&looped);
    try testing.expect(looped == .success);

    // The circularity that *does* mean something is caught where it
    // means it: a constant that depends on itself through two files
    // terminates with a diagnostic rather than folding forever.
    var constants: TestLoader = .{ .modules = &.{
        .{ .name = "a", .source = "import b\n\nlet width = b.height + 1\n" },
        .{ .name = "b", .source = "import a\n\nlet height = a.width + 1\n" },
    } };
    var knotted = try compile_mod.compileProject(testing.allocator,
        \\import a
        \\
        \\func main():
        \\    print(str(a.width))
        \\
    , constants.loader(), script);
    defer knotted.deinit();
    try testing.expect(knotted == .failure);
    try testing.expectEqualStrings("luce.sema.const", knotted.failure.at(0).?.code);
}

// ---------------------------------------------------------------------------
// File-scope constants (docs/V2.md Phase 2)
// ---------------------------------------------------------------------------

// What a constant *is* — the folding, and what it may not name — is
// here, beside the driver that folds it.  What a folded constant
// evaluates to is a two-engine fact and lives in
// `specs/behavior_spec.zig`.

const script_options: types.CompileOptions = .{};

fn failsWith(source: []const u8, code: []const u8) !void {
    return expectFailsOptions(source, script_options, code);
}

test "constants are compile-time: calls, objects, and verbs are refused" {
    try failsWith(
        \\func answer() -> Int:
        \\    return 42
        \\
        \\let bad = answer()
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.const");
    try failsWith(
        \\let bad = [1, 2]
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.const");
    try failsWith(
        \\struct Bag:
        \\    items: List(Int)
        \\
        \\let bad = Bag(items = [1])
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.const");
    try failsWith(
        \\let source = "x"
        \\let bad = copy source
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.const");
}

test "constant cycles, unknowns, and arithmetic faults are compile errors" {
    try failsWith(
        \\let a = b + 1
        \\let b = a + 1
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.const");
    try failsWith(
        \\let alone = missing + 1
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.const");
    try failsWith(
        \\let big = 9223372036854775807 + 1
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.const");
    try failsWith(
        \\let broken = 1 / 0
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.const");
}

test "constants share the one namespace and stay immutable" {
    try failsWith(
        \\let twice = 2
        \\
        \\func twice() -> Int:
        \\    return 2
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.duplicate");
    try failsWith(
        \\let width = 80
        \\
        \\func main():
        \\    let width = 3
        \\
    , "luce.sema.duplicate");
    try failsWith(
        \\let width = 80
        \\
        \\func main():
        \\    width = 3
        \\
    , "luce.sema.let");
    try failsWith(
        \\let len = 3
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.reserved");
    try failsWith(
        \\let wrong: Float = 3
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.type");
}

test "top-level var is refused with directions" {
    try failsWith(
        \\var counter = 0
        \\
        \\func main():
        \\    return
        \\
    , "luce.parse.top");
}
