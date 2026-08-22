//! Driver tests — integration coverage for the whole compiler, from
//! source bytes through verified, optimized MIR.

const std = @import("std");
const types = @import("../support/types.zig");
const mir = @import("../mir.zig");
const compile_mod = @import("../compile.zig");
const luce_source = @import("../source.zig");

const testing = std.testing;

// ---------------------------------------------------------------------------
// The helpers every test below shares
// ---------------------------------------------------------------------------

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

fn expectRejected(source: []const u8, expected_code: []const u8) !void {
    return expectRejectedOptions(source, .{}, expected_code);
}

fn expectRejectedOptions(
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

const source_mod = @import("../source.zig");

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

// ---------------------------------------------------------------------------
// Diagnostics: the code, the span, and no cascade
// ---------------------------------------------------------------------------

test "func is strict and fn is an ordinary identifier" {
    try expectRejected(
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
        &.{.{ .code = "luce.lex.str", .line = 2, .column = 13 }},
    );
}

test "parser diagnostics carry the right code and location" {
    try expectDiagnostics(
        "const 3 = 4\n",
        .{},
        &.{.{ .code = "luce.parse.expected", .line = 1, .column = 7 }},
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
        \\    let x = i64("no")
        \\
    , .{}, &.{.{ .code = "luce.sema.convert", .line = 2, .column = 13 }});
    // An unknown field, pointed at the access.
    try expectDiagnostics(
        \\struct Point:
        \\    x: f64
        \\
        \\func main():
        \\    var p = Point(x = 1.0)
        \\    let y = p.y
        \\
    , .{}, &.{.{ .code = "luce.sema.field", .line = 6, .column = 13 }});
}

test "a diagnostic about a name points at the name, not at the declaration" {
    // They all pointed at the declaration, because a declaration
    // carried one span and every complaint reused it.  So `func
    // len():` underlined the `func` as part of a sentence about
    // the word `len`, and `const print = 3` underlined `= 3`.  The
    // message named one word and the caret covered a phrase, which
    // leaves the reader working out which part is meant.
    //
    // Columns, so this cannot pass by pointing at the right line.
    try expectDiagnostics(
        \\func len() -> i64:
        \\    return 1
        \\
        \\func main():
        \\    return
        \\
    , .{}, &.{.{ .code = "luce.sema.reserved", .line = 1, .column = 6 }});
    try expectDiagnostics(
        \\struct print:
        \\    x: i64
        \\
        \\func main():
        \\    return
        \\
    , .{}, &.{.{ .code = "luce.sema.reserved", .line = 1, .column = 8 }});
    try expectDiagnostics(
        \\const print = 3
        \\
        \\func main():
        \\    return
        \\
    , .{}, &.{.{ .code = "luce.sema.reserved", .line = 1, .column = 7 }});
    try expectDiagnostics(
        \\func main():
        \\    let len = 1
        \\
    , .{}, &.{.{ .code = "luce.sema.reserved", .line = 2, .column = 9 }});
    try expectDiagnostics(
        \\func main():
        \\    var range: i64
        \\
    , .{}, &.{.{ .code = "luce.sema.reserved", .line = 2, .column = 9 }});
    // The same rule for the duplicates, which read the same spans.
    try expectDiagnostics(
        \\func go():
        \\    return
        \\
        \\func go():
        \\    return
        \\
        \\func main():
        \\    return
        \\
    , .{}, &.{.{ .code = "luce.sema.duplicate", .line = 4, .column = 6 }});
    try expectDiagnostics(
        \\struct Point:
        \\    x: i64
        \\
        \\struct Point:
        \\    y: i64
        \\
        \\func main():
        \\    return
        \\
    , .{}, &.{.{ .code = "luce.sema.duplicate", .line = 4, .column = 8 }});
    try expectDiagnostics(
        \\struct Point:
        \\    x: i64
        \\    x: i64
        \\
        \\func main():
        \\    return
        \\
    , .{}, &.{.{ .code = "luce.sema.duplicate", .line = 3, .column = 5 }});
    try expectDiagnostics(
        \\func f(a: i64, a: i64) -> i64:
        \\    return a
        \\
        \\func main():
        \\    return
        \\
    , .{}, &.{.{ .code = "luce.sema.duplicate", .line = 1, .column = 16 }});
    try expectDiagnostics(
        \\func main():
        \\    let a = 1
        \\    if true:
        \\        let a = 2
        \\        print(str(a))
        \\
    , .{ .allow_host = true }, &.{.{ .code = "luce.sema.duplicate", .line = 4, .column = 13 }});
}

test "a name refused at its declaration is not then an unknown name" {
    // One mistake, one diagnostic.  `var len = 1` is refused because
    // `len` is reserved — and `len` is still a name the reader wrote
    // and meant, so the line below it must not become "unknown name
    // len" on top.  The builder already remembered names whose
    // *initializer* failed for exactly this reason; a name refused for
    // what it is spelled was falling out of that.
    try expectDiagnostics(
        \\func main():
        \\    var len = 1
        \\    len = 2
        \\
    , .{}, &.{.{ .code = "luce.sema.reserved", .line = 2, .column = 9 }});
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
        // A missing operand, not a stray character: `let a = @` is
        // stage 2's mistake, and stage 3 no longer says it again.
        .{ .source = "func main():\n    let a = 1 +\n", .code = "luce.parse.expression" },
        .{ .source = "func main():\n    let a: list = []\n", .code = "luce.sema.container.type" },
        .{ .source = "func main():\n    let a = array[i64]\n", .code = "luce.sema.container.type" },
        .{ .source = "func main():\n    let a = 99999999999999999999999\n", .code = "luce.sema.literal" },
    };
    for (cases) |case| {
        try expectRejectedOptions(case.source, .{}, case.code);
    }
}

// ---------------------------------------------------------------------------
// Allocation failure, swept
// ---------------------------------------------------------------------------

test "the pipeline survives every allocation failure" {
    // A ratchet, not a bug-finder (all four pass today): the moment
    // someone adds a non-arena cache or an ArrayList that outlives an
    // error path, this catches the leak or the swallowed OOM.  Also
    // enforces error.NondeterministicMemoryUsage.
    const representative =
        \\struct Point:
        \\    x: f64
        \\    tag: str
        \\
        \\func total(values: list[i64]) -> i64:
        \\    var sum = 0
        \\    for value in values:
        \\        sum = sum + value
        \\    return sum
        \\
        \\func main():
        \\    var xs = [3, 1, 2]
        \\    xs.sort()
        \\    var ages = map[str, i64]()
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
    const module = @import("../mir.zig").module;
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

// ---------------------------------------------------------------------------
// The entry, and what a declaration may hold
// ---------------------------------------------------------------------------

test "the entry is exactly func main(), and nothing else will do" {
    try expectRejected(
        \\func helper() -> i64:
        \\    return 1
        \\
    , "luce.sema.main");
    try expectRejected(
        \\func main(value: i64):
        \\    return
        \\
    , "luce.sema.main");
    try expectRejected(
        \\func main() -> i64:
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
        \\    static func twice(value: i64) -> i64:
        \\        return value * 2
        \\
        \\struct Pair:
        \\    left: i64
        \\    static func sum(left: i64, right: i64) -> i64:
        \\        return left + right
        \\
        \\func main():
        \\    assert(Math.twice(Pair.sum(3, 4)) == 14)
        \\
    );
    defer program.deinit();
    try testing.expectEqualStrings("Math.twice", program.functions[1].name);

    try expectRejected(
        \\struct Bad:
        \\    value: i64
        \\    static func value() -> i64:
        \\        return 1
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.duplicate");
    try expectRejected(
        \\struct Helpers:
        \\    static func one() -> i64:
        \\        return 1
        \\
        \\func main():
        \\    let bad = Helpers.missing()
        \\
    , "luce.sema.call");
    try expectRejected(
        \\struct Helpers:
        \\    static func one() -> i64:
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
        \\    x: f64
        \\    y: f64
        \\
        \\func scale_point(point: Point, factor: f64) -> Point:
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
        \\    var total: i64 = 0
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

// ---------------------------------------------------------------------------
// What the lowering produces: pruning, literals, the golden dump
// ---------------------------------------------------------------------------

test "functions unreachable from the entry are pruned from the artifact" {
    // A std import brings its whole module; what is never called must
    // not reach the .lcm, the decoder, or stage 10 (docs/PIPELINE.md,
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
        \\    print(str("abc".find("b") else -1))
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
                    .call_inout => |call| if (!reached[call.function]) {
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

// A numeric literal lands at the type of the place it goes into and is
// *parsed* there (docs/TYPES.md D3). Check the IR as well as behavior:
// a landed literal is one constant at the requested width, never a
// default-width constant followed by a conversion that could round twice.
//
// Every place a type is written down gets a line: an annotation, a
// call argument, a return, and through a leading minus, which does
// not move where a number lands.
test "a literal lands at its context's type, with no conversion behind it" {
    var program = try expectCompiles(
        \\func takes(x: f64) -> f64:
        \\    return x
        \\
        \\func answers() -> f64:
        \\    return 12
        \\
        \\func main():
        \\    let annotated: f64 = 7
        \\    let negated: f64 = -3
        \\    assert(annotated == 7.0)
        \\    assert(negated == -3.0)
        \\    assert(takes(8) == 8.0)
        \\    assert(answers() == 12.0)
        \\
    );
    defer program.deinit();

    var floats: usize = 0;
    var conversions: usize = 0;
    for (program.functions) |function| {
        for (function.instructions) |instruction| {
            switch (instruction) {
                .const_float => floats += 1,
                .convert => conversions += 1,
                else => {},
            }
        }
    }
    // 7, -3 and 8 land as floats where they are written; `answers`
    // returns 12 as one; and the four asserts compare against 7.0,
    // -3.0, 8.0 and 12.0.  What matters is the second count.
    try testing.expect(floats >= 8);
    try testing.expectEqual(@as(usize, 0), conversions);
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
    // Unannotated integer literals default to `i64`, and arithmetic
    // stays at that explicit width.
    try testing.expect(std.mem.indexOf(u8, first, "local %0 value: i64") != null);
    try testing.expect(std.mem.indexOf(u8, first, "multiply.i64") != null);
}

test "a named call lowers to byte-identical MIR — names die in stage 4" {
    // docs/ARGS.md D11: names are resolved away before MIR exists, so
    // the named call (in declared order — reordering moves register
    // numbering with evaluation order, the As-built ledger's point) and
    // the plain positional call are the same program, byte for byte
    // through the printer.  This is the
    // cheapest possible proof that neither the instruction set nor the
    // serialized module moved — format_version stays where it is.
    const positional =
        \\func size(width: i64, height: i64, deep: bool) -> i64:
        \\    if deep:
        \\        return width * height * 2
        \\    return width * height
        \\
        \\func main():
        \\    assert(size(3, 4, false) == 12)
        \\
    ;
    const named =
        \\func size(width: i64, height: i64, deep: bool) -> i64:
        \\    if deep:
        \\        return width * height * 2
        \\    return width * height
        \\
        \\func main():
        \\    assert(size(width = 3, height = 4, deep = false) == 12)
        \\
    ;
    var plain = try expectCompiles(positional);
    defer plain.deinit();
    const plain_dump = try mir.print(testing.allocator, &plain);
    defer testing.allocator.free(plain_dump);

    var permuted = try expectCompiles(named);
    defer permuted.deinit();
    const permuted_dump = try mir.print(testing.allocator, &permuted);
    defer testing.allocator.free(permuted_dump);

    try testing.expectEqualStrings(plain_dump, permuted_dump);
}

test "the IR dump has a stable golden shape (short-circuit)" {
    // A full-dump snapshot of the trickiest lowering: short-circuit `and`
    // splitting a block.  Behavior tests can't see block ordering; this
    // does, and it documents the IR for a reader.  Regenerate
    // deliberately when lowering changes on purpose.
    //
    // This is the *optimized* program — what `luce build` compiles.
    // The re-reads of `xs` are *not* folded, and deliberately: block-local
    // value numbering was the interpreter's pass and went with it, and
    // `default<O3>` folds them downstream (docs/ENGINE.md step 7).
    // `luce ir --full` prints the raw lowering instead.
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
        \\    local %0 (temporary): list[i64]
        \\    local %1 xs: list[i64]
        \\    local %2 (temporary): bool
        \\  b0:
        \\    r0 = const 1
        \\    r1 = const 2
        \\    r2 = heap_new list[i64]
        \\    intrinsic append_value, r2, r0
        \\    intrinsic append_value, r2, r1
        \\    local_set %1, r2
        \\    r6 = local_get %1
        \\    r7 = intrinsic len, r6
        \\    r8 = const 0
        \\    r9 = greater.i64 r7, r8
        \\    local_set %2, r9
        \\    branch r9, b1, b2
        \\  b1:
        \\    r12 = local_get %1
        \\    r13 = const 0
        \\    r14 = intrinsic index_get, r12, r13
        \\    r15 = const 1
        \\    r16 = equal.i64 r14, r15
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
        \\    intrinsic release, r25
        \\    ret
        \\
    , dump);
}

// ---------------------------------------------------------------------------
// What the checker refuses
// ---------------------------------------------------------------------------

test "no implicit narrowing, no reassigned let, no shadowing" {
    // Numeric representations never change implicitly
    // (docs/NUMERICS.md).
    try expectRejected(
        \\func main():
        \\    let narrowed: i64 = 2.5
        \\
    , "luce.sema.type");
    try expectRejected(
        \\func main():
        \\    let once = 1
        \\    once = 2
        \\
    , "luce.sema.let");
    try expectRejected(
        \\func main():
        \\    let name = 1
        \\    if true:
        \\        let name = 2
        \\
    , "luce.sema.duplicate");
}

test "return paths are checked on every branch" {
    try expectRejected(
        \\func partial(flag: bool) -> i64:
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
        \\    red: f64
        \\    green: f64
        \\
    ;
    try expectRejected(source_prefix ++
        \\func main():
        \\    let missing = Color(red = 1.0)
        \\
    , "luce.sema.construct");
    try expectRejected(source_prefix ++
        \\func main():
        \\    let doubled = Color(red = 1.0, red = 2.0, green = 3.0)
        \\
    , "luce.sema.construct");
    // The integer literal in `red = 1` lands directly as f64; text is
    // still a type mismatch.
    try expectRejected(source_prefix ++
        \\func main():
        \\    let wrong = Color(red = "x", green = 2.0)
        \\
    , "luce.sema.type");
    try expectRejected(
        \\struct Loop:
        \\    inner: Loop
        \\
        \\func main():
        \\    let never = 1
        \\
    , "luce.sema.struct");
}

test "calls check arity, types, and none results" {
    try expectRejected(
        \\func helper(value: i64) -> i64:
        \\    return value
        \\
        \\func main():
        \\    let wrong = helper(1, 2)
        \\
    , "luce.sema.call");
    try expectRejected(
        \\func nothing():
        \\    return
        \\
        \\func main():
        \\    let value = nothing()
        \\
    , "luce.sema.call");
    // `sqrt(4)` is not this mistake any more: a literal has no type
    // until it lands, and it lands on `sqrt`'s float (docs/TYPES.md
    // §1).  What is still refused is an integer that has a type.
    try expectRejected(
        \\func main():
        \\    var n = 4
        \\    let bad = sqrt(n)
        \\
    , "luce.sema.type");
    try expectRejected(
        \\func main():
        \\    let bad = unknown_helper(1)
        \\
    , "luce.sema.call");
}

test "break and continue require a loop" {
    try expectRejected(
        \\func main():
        \\    break
        \\
    , "luce.sema.loop");
}

test "var struct fields update through functional struct_set" {
    var program = try expectCompiles(
        \\struct Point:
        \\    x: f64
        \\    y: f64
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

test "the public host surface type-checks and stays host-gated" {
    try expectRejected(
        \\func main():
        \\    print("hello")
        \\
    , "luce.sema.host");
    try expectRejected(
        \\import std.files
        \\
        \\func main():
        \\    let text = files.read("notes.txt")
        \\
    , "luce.sema.host");

    var hosted = try compile_mod.compile(testing.allocator,
        \\import std.files
        \\import std.os
        \\import std.term
        \\
        \\func main(args: list[str]) -> !:
        \\    print("hello " + args[0])
        \\    let text = files.read("notes.txt") catch ""
        \\    try files.write("copy.txt", text)
        \\    print("copied")
        \\    term.clear()
        \\    term.move(0, 0)
        \\    term.style(114, -1, false)
        \\    let event = term.read()
        \\    if event == none:
        \\        term.write("eof")
        \\    term.flush()
        \\
    , .{ .allow_host = true });
    defer hosted.deinit();
    try testing.expect(hosted == .success);

    // `os.read_line` answers `str?`, so a program that treats a line
    // that never came as a line is refused where it is written rather
    // than looping on it at run time (docs/FAILURE.md).
    try expectRejectedOptions(
        \\import std.os
        \\import std.term
        \\
        \\func main():
        \\    term.write(os.read_line(""))
        \\
    , .{ .allow_host = true }, "luce.sema.type");

    try expectRejectedOptions(
        \\import std.files
        \\
        \\func main() -> !:
        \\    let bad = try files.read(7)
        \\
    , .{ .allow_host = true }, "luce.sema.type");
    // A call that can fail may not be written as if it could not:
    // this is the shape `if files.write_lines(...)` used to have, and
    // it is the whole of why a swallowed failure is now unwritable.
    try expectRejectedOptions(
        \\import std.files
        \\
        \\func main():
        \\    let text = files.read("notes.txt")
        \\
    , .{ .allow_host = true }, "luce.sema.fallible");
    // And `try` needs a caller that said it can fail.
    try expectRejectedOptions(
        \\import std.files
        \\
        \\func main():
        \\    let text = try files.read("notes.txt")
        \\
    , .{ .allow_host = true }, "luce.sema.fallible");
    try expectRejectedOptions(
        \\import std.term
        \\
        \\func main():
        \\    term.style(1, 2, 3)
        \\
    , .{ .allow_host = true }, "luce.sema.type");
}

test "collections type-check and reject misuse at compile time" {
    const script: types.CompileOptions = .{};

    var featured = try compile_mod.compile(testing.allocator,
        \\func sum(values: list[i64]) -> i64:
        \\    var total: i64 = 0
        \\    for value in values:
        \\        total = total + value
        \\    return total
        \\
        \\func label(counts: map[str, i64], grid: array[i64, _, _]) -> str:
        \\    var b = builder()
        \\    b.append(str(len(counts) + grid[0, 0]))
        \\    let made = b.build()
        \\    return made
        \\
        \\func main():
        \\    var values: list[i64] = []
        \\    values.append(4)
        \\    let total = sum(values[0:])
        \\
    , script);
    defer featured.deinit();
    try testing.expect(featured == .success);

    try expectRejectedOptions(
        \\func main():
        \\    let mixed = [1, "two"]
        \\
    , script, "luce.sema.type");
    try expectRejectedOptions(
        \\func main():
        \\    var untyped = []
        \\
    , script, "luce.sema.type");
    try expectRejectedOptions(
        \\func main():
        \\    var m = map[f64, i64]()
        \\
    , script, "luce.sema.type");
    try expectRejectedOptions(
        \\func main():
        \\    var grid = array[i64](2, 2)
        \\    let bad = grid[0]
        \\
    , script, "luce.sema.index");
    try expectRejectedOptions(
        \\func main():
        \\    var m = map[str, i64]()
        \\    let bad = m[7]
        \\
    , script, "luce.sema.index");
    try expectRejectedOptions(
        \\func main():
        \\    let bad = 5.append(1)
        \\
    , script, "luce.sema.method");
    try expectRejectedOptions(
        \\func main():
        \\    for x in 7:
        \\        let unused = x
        \\
    , script, "luce.sema.loop");
    try expectRejectedOptions(
        \\func main():
        \\    let xs = [1]
        \\    let bad = xs < xs
        \\
    , script, "luce.sema.type");
    try expectRejectedOptions(
        \\func main():
        \\    var xs = [1]
        \\    xs[0] = "text"
        \\
    , script, "luce.sema.type");
}

// ---------------------------------------------------------------------------
// Modules
// ---------------------------------------------------------------------------

const TestModule = struct {
    name: []const u8,
    source: []const u8,
    /// The root token the answer belongs to; "" is the project.  The
    /// package tests use these two columns the way a store host would
    /// (docs/PACKAGES.md D4, D7).
    root: []const u8 = "",
    /// Answer only when the import was written under this token; null
    /// answers whatever asked.
    from: ?[]const u8 = null,
    path: []const u8 = "",
};

const TestLoader = struct {
    modules: []const TestModule,
    /// Names that exist but cannot be read — a directory, a
    /// permission: the host's other answer.
    locked: []const []const u8 = &.{},

    fn load(context: *anyopaque, arena: std.mem.Allocator, name: []const u8, from_root: []const u8) error{OutOfMemory}!luce_source.Found {
        const self: *TestLoader = @ptrCast(@alignCast(context));
        for (self.locked) |locked| {
            if (std.mem.eql(u8, locked, name)) return .{ .unreadable = "permission denied" };
        }
        for (self.modules) |module| {
            if (!std.mem.eql(u8, module.name, name)) continue;
            if (module.from) |only| {
                if (!std.mem.eql(u8, only, from_root)) continue;
            }
            return .{ .text = .{
                .bytes = try arena.dupe(u8, module.source),
                .path = module.path,
                .root = module.root,
            } };
        }
        return .missing;
    }

    fn loader(self: *TestLoader) compile_mod.Loader {
        return .{ .context = self, .load = load };
    }
};

const geo_module: TestModule = .{ .name = "geo", .source =
    \\import util
    \\
    \\struct Point:
    \\    x: f64
    \\    y: f64
    \\
    \\struct Text:
    \\    static func twice(value: i64) -> i64:
    \\        return value * 2
    \\
    \\func make(x: f64, y: f64) -> Point:
    \\    return Point(x = x, y = y)
    \\
    \\func length(point: Point) -> f64:
    \\    return util.hypot(point.x, point.y)
    \\
};

const util_module: TestModule = .{ .name = "util", .source =
    \\const TABLE = [1]
    \\
    \\func hypot(x: f64, y: f64) -> f64:
    \\    return sqrt(x * x + y * y)
    \\
};

test "an import graph is bounded by available memory, not 64 modules" {
    // Import loading is a finite breadth-first walk with cycle detection.
    // Its allocator is the honest resource boundary; an arbitrary project
    // size ceiling rejects healthy programs and does not make the graph walk
    // safer. Generate enough siblings to cross the former limit so it cannot
    // return unnoticed.
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const count = 128;
    const modules = try arena.alloc(TestModule, count);
    var root: std.ArrayList(u8) = .empty;
    for (modules, 0..) |*module, index| {
        module.* = .{
            .name = try std.fmt.allocPrint(arena, "m{d}", .{index}),
            .source = try std.fmt.allocPrint(
                arena,
                "func value{d}() -> i64:\n    return {d}\n",
                .{ index, index },
            ),
        };
        try root.print(arena, "import m{d}\n", .{index});
    }
    try root.appendSlice(arena, "\nfunc main():\n    return\n");

    var files: TestLoader = .{ .modules = modules };
    var result = try compile_mod.compileProject(
        testing.allocator,
        root.items,
        files.loader(),
        .{ .prune = false },
    );
    defer result.deinit();
    try testing.expect(result == .success);
    try testing.expectEqual(@as(usize, count + 1), result.success.functions.len);
}

// ---------------------------------------------------------------------------
// Visibility (docs/VISIBILITY.md §8: the cross-module rows)
// ---------------------------------------------------------------------------

/// Compile `root` against `modules` and require exactly one refusal
/// whose code is `luce.sema.private` and whose message is `saying`.
fn expectPrivateSaying(root: []const u8, modules: []const TestModule, saying: []const u8) !void {
    var files: TestLoader = .{ .modules = modules };
    var result = try compile_mod.compileProject(testing.allocator, root, files.loader(), .{ .allow_host = true });
    defer result.deinit();
    if (result == .success) {
        std.debug.print("expected '{s}', but this compiled:\n{s}", .{ saying, root });
        return error.TestUnexpectedResult;
    }
    errdefer printDiagnostics(&result);
    try testing.expectEqual(@as(usize, 1), result.failure.count());
    const found = result.failure.at(0).?;
    try testing.expectEqualStrings("luce.sema.private", found.code);
    try testing.expectEqualStrings(saying, found.message);
}

fn expectProjectCompiles(root: []const u8, modules: []const TestModule) !void {
    var files: TestLoader = .{ .modules = modules };
    var result = try compile_mod.compileProject(testing.allocator, root, files.loader(), .{ .allow_host = true });
    defer result.deinit();
    if (result == .failure) {
        printDiagnostics(&result);
        std.debug.print("expected a clean compile of:\n{s}", .{root});
        return error.TestUnexpectedResult;
    }
}

/// The memo's corpus in one module: every marked shape §8's rows need.
const vault_module: TestModule = .{ .name = "vault", .source =
    \\private func helper() -> i64:
    \\    return 41
    \\
    \\func visible() -> i64:
    \\    return helper() + 1
    \\
    \\private const seed = 41
    \\const answer = seed + 1
    \\
    \\private struct Inner:
    \\    n: i64
    \\
    \\    static func make() -> Inner:
    \\        return Inner(n = 1)
    \\
    \\struct Handle:
    \\    private:
    \\        slot: i64
    \\    label: i64
    \\
    \\func fresh() -> Handle:
    \\    return Handle(slot = 1, label = 2)
    \\
    \\struct Session:
    \\    name: str
    \\    private id: i64
    \\    private token: i64 = 0
    \\
    \\    func title() -> str:
    \\        return self.name
    \\
    \\    private func stamp() -> i64:
    \\        return self.id
    \\
    \\    private static func widest() -> i64:
    \\        return 64
    \\
    \\func open(name: str) -> Session:
    \\    return Session(name = name, id = 7)
    \\
    \\struct Box:
    \\    held: Handle
    \\
    \\private enum Hidden:
    \\    first
    \\    second
    \\
    \\    static func lead() -> Hidden:
    \\        return Hidden.first
    \\
    \\enum Shown(u8):
    \\    open = 0
    \\    shut = 1
    \\
    \\    private static func sealed() -> i64:
    \\        return 7
    \\
    \\func opened() -> Shown:
    \\    return Shown.open
    \\
};

test "luce.sema.private: a private function is withheld, and the call graph is not" {
    try expectPrivateSaying(
        \\import vault
        \\
        \\func main():
        \\    print(str(vault.helper()))
        \\
    , &.{vault_module}, "helper is private to vault");
    // A public function calling its module's own private one is
    // ordinary code: visibility gates the reference site's module,
    // never the call graph (D1).
    try expectProjectCompiles(
        \\import vault
        \\
        \\func main():
        \\    print(str(vault.visible()))
        \\
    , &.{vault_module});
}

test "luce.sema.private: a private constant is withheld, and its folded value crosses" {
    try expectPrivateSaying(
        \\import vault
        \\
        \\func main():
        \\    print(str(vault.seed))
        \\
    , &.{vault_module}, "seed is private to vault");
    // D8: a public constant folds from private ones; the value
    // crossed, not the name — in a body and in a constant initializer.
    try expectProjectCompiles(
        \\import vault
        \\
        \\const doubled = vault.answer * 2
        \\
        \\func main():
        \\    print(str(vault.answer + doubled))
        \\
    , &.{vault_module});
    // The same gate holds inside a constant initializer's fold.
    try expectPrivateSaying(
        \\import vault
        \\
        \\const stolen = vault.seed + 1
        \\
        \\func main():
        \\    print(str(stolen))
        \\
    , &.{vault_module}, "seed is private to vault");
}

test "luce.sema.private: a private struct is withheld from annotation, construction, and namespace" {
    try expectPrivateSaying(
        \\import vault
        \\
        \\func read(p: vault.Inner) -> i64:
        \\    return 1
        \\
        \\func main():
        \\    return
        \\
    , &.{vault_module}, "Inner is private to vault");
    try expectPrivateSaying(
        \\import vault
        \\
        \\func main():
        \\    let p = vault.Inner(n = 1)
        \\    print(str(p.n))
        \\
    , &.{vault_module}, "Inner is private to vault");
    // A namespace function of a private struct is reached through the
    // struct's name, and it is the struct that is withheld.
    try expectPrivateSaying(
        \\import vault
        \\
        \\func main():
        \\    let p = vault.Inner.make()
        \\    print(str(p.n))
        \\
    , &.{vault_module}, "Inner is private to vault");
}

test "luce.sema.private: a private field refuses reads, writes, and construction naming" {
    try expectPrivateSaying(
        \\import vault
        \\
        \\func main():
        \\    var h = vault.fresh()
        \\    print(str(h.slot))
        \\
    , &.{vault_module}, "slot of Handle is private to vault");
    try expectPrivateSaying(
        \\import vault
        \\
        \\func main():
        \\    var h = vault.fresh()
        \\    h.slot = 3
        \\
    , &.{vault_module}, "slot of Handle is private to vault");
    // Naming a private field at construction — even one with a
    // default — is refused: the default is the module's chosen value
    // for a slot the module kept (§3).
    try expectPrivateSaying(
        \\import vault
        \\
        \\func main():
        \\    let s = vault.Session(name = "x", token = 9)
        \\    print(s.name)
        \\
    , &.{vault_module}, "token of Session is private to vault");
}

test "luce.sema.private: a required private field forecloses outside construction" {
    try expectPrivateSaying(
        \\import vault
        \\
        \\func main():
        \\    let s = vault.Session(name = "x")
        \\    print(s.name)
        \\
    , &.{vault_module}, "Session cannot be constructed here: id is marked private in vault and has no default; construction belongs to a public function of vault");
    // The pattern the diagnostic names, working: the factory, the
    // public field, and the public method all cross the boundary.
    try expectProjectCompiles(
        \\import vault
        \\
        \\func main():
        \\    let s = vault.open("dy")
        \\    print(s.name)
        \\    print(s.title())
        \\
    , &.{vault_module});
}

test "luce.sema.private: a private method is withheld from the value spelling too" {
    try expectPrivateSaying(
        \\import vault
        \\
        \\func main():
        \\    let s = vault.open("dy")
        \\    print(str(s.stamp()))
        \\
    , &.{vault_module}, "stamp is private to vault");
}

test "luce.sema.private: a private enum is withheld by name, and every door says so" {
    // An enum is a declaration like any other (docs/ENUMS.md D7,
    // VISIBILITY.md D1), and there are four doors to one: the type, a
    // member, the constructor, and a namespace function of it.  Each
    // answers *private*, never unknown.
    try expectPrivateSaying(
        \\import vault
        \\
        \\func read(m: vault.Hidden) -> i64:
        \\    return 1
        \\
        \\func main():
        \\    return
        \\
    , &.{vault_module}, "Hidden is private to vault");
    try expectPrivateSaying(
        \\import vault
        \\
        \\func main():
        \\    let m = vault.Hidden.first
        \\
    , &.{vault_module}, "Hidden is private to vault");
    try expectPrivateSaying(
        \\import vault
        \\
        \\func main():
        \\    let m = vault.Hidden(0)
        \\
    , &.{vault_module}, "Hidden is private to vault");
    try expectPrivateSaying(
        \\import vault
        \\
        \\func main():
        \\    let m = vault.Hidden.lead()
        \\
    , &.{vault_module}, "Hidden is private to vault");
    // The public one beside it crosses whole: the type in an
    // annotation, a member by name, the constructor, and equality.
    try expectProjectCompiles(
        \\import vault
        \\
        \\func spell(s: vault.Shown) -> str:
        \\    match s:
        \\        open:
        \\            return "open"
        \\        shut:
        \\            return "shut"
        \\
        \\func main():
        \\    assert(vault.opened() == vault.Shown.open)
        \\    assert(spell(vault.Shown.shut) == "shut")
        \\    assert(vault.Shown(1) != none)
        \\    assert(vault.Shown(2) == none)
        \\
    , &.{vault_module});
}

test "every spelling of touching a private member gets the same useful sentence" {
    // The §1 funnel has more than one door, and a reader will try all
    // of them: the retired type-qualified method spelling, a private
    // static member of a public struct, the nested place, the compound
    // assignment.  One declaration, one sentence, whichever door
    // (VISIBILITY.md D2).
    try expectPrivateSaying(
        \\import vault
        \\
        \\func main():
        \\    let s = vault.open("dy")
        \\    print(str(vault.Session.stamp(s)))
        \\
    , &.{vault_module}, "stamp is private to vault");
    try expectPrivateSaying(
        \\import vault
        \\
        \\func main():
        \\    print(str(vault.Session.widest()))
        \\
    , &.{vault_module}, "widest is private to vault");
    // Enum function visibility used to be parsed and then discarded;
    // SELF's static member split carries the same mark all the way to
    // the cross-module gate.
    try expectPrivateSaying(
        \\import vault
        \\
        \\func main():
        \\    print(str(vault.Shown.sealed()))
        \\
    , &.{vault_module}, "sealed is private to vault");
    // A nested place: the write walks the chain, and the gate stands
    // at the field it finally names.
    try expectPrivateSaying(
        \\import vault
        \\
        \\func main():
        \\    var boxed = vault.Box(held = vault.fresh())
        \\    boxed.held.slot = 9
        \\
    , &.{vault_module}, "slot of Handle is private to vault");
    // A compound assignment reads and writes the same private field;
    // one refusal, at the place.
    try expectPrivateSaying(
        \\import vault
        \\
        \\func main():
        \\    var h = vault.fresh()
        \\    h.slot += 1
        \\
    , &.{vault_module}, "slot of Handle is private to vault");
    // Reading a private field of a nested place refuses the same way
    // writing it does.
    try expectPrivateSaying(
        \\import vault
        \\
        \\func main():
        \\    var boxed = vault.Box(held = vault.fresh())
        \\    print(str(boxed.held.slot))
        \\
    , &.{vault_module}, "slot of Handle is private to vault");
    // Importing a module and touching only public things is just the
    // import working — nothing about the six markers taxes a caller
    // who never crosses the line.
    try expectProjectCompiles(
        \\import vault
        \\
        \\func main():
        \\    var boxed = vault.Box(held = vault.fresh())
        \\    print(str(boxed.held.label))
        \\
    , &.{vault_module});
}

test "member typos beside private members suggest visible members only" {
    // `vault.sed` sits one edit from the private `seed`; the namespace
    // answers "no member" without leaking the name it withheld.
    var files: TestLoader = .{ .modules = &.{vault_module} };
    var result = try compile_mod.compileProject(testing.allocator,
        \\import vault
        \\
        \\func main():
        \\    print(str(vault.sed))
        \\
    , files.loader(), .{ .allow_host = true });
    defer result.deinit();
    try testing.expect(result == .failure);
    errdefer printDiagnostics(&result);
    try testing.expectEqual(@as(usize, 1), result.failure.count());
    const found = result.failure.at(0).?;
    try testing.expect(std.mem.indexOf(u8, found.message, "no member") != null);
    try testing.expect(std.mem.indexOf(u8, found.message, "seed") == null);
}

test "the std leak is closed through both spellings, with the same sentence" {
    // Item 10's warrant, held as a compile fact rather than only as a
    // site fence: the qualified call and the method sugar route to the
    // same declaration and the same refusal.
    var direct = try compile_mod.compile(testing.allocator,
        \\import std.strings
        \\
        \\func main():
        \\    print(strings.fold_case("MIXED", 65, 90, 32))
        \\
    , .{ .allow_host = true });
    defer direct.deinit();
    try testing.expect(direct == .failure);
    var sugar = try compile_mod.compile(testing.allocator,
        \\import std.strings
        \\
        \\func main():
        \\    print("MIXED".fold_case(65, 90, 32))
        \\
    , .{ .allow_host = true });
    defer sugar.deinit();
    try testing.expect(sugar == .failure);
    for ([_]*compile_mod.CompileResult{ &direct, &sugar }) |result| {
        var found = false;
        for (0..result.failure.count()) |index| {
            const item = result.failure.at(index).?;
            if (!std.mem.eql(u8, item.code, "luce.sema.private")) continue;
            try testing.expectEqualStrings("fold_case is private to strings", item.message);
            found = true;
        }
        try testing.expect(found);
    }
}

test "a typo near a private name is unknown, and the private name is never suggested" {
    var files: TestLoader = .{ .modules = &.{vault_module} };
    var result = try compile_mod.compileProject(testing.allocator,
        \\import vault
        \\
        \\func main():
        \\    print(str(vault.helperr()))
        \\
    , files.loader(), .{ .allow_host = true });
    defer result.deinit();
    try testing.expect(result == .failure);
    errdefer printDiagnostics(&result);
    try testing.expectEqual(@as(usize, 1), result.failure.count());
    const found = result.failure.at(0).?;
    try testing.expectEqualStrings("luce.sema.call", found.code);
    try testing.expect(std.mem.indexOf(u8, found.message, "unknown function") != null);
    try testing.expect(std.mem.indexOf(u8, found.message, "did you mean") == null);
}

test "the private path is checked per module: A sees its own, B does not, one compile" {
    // Module a declares and uses its private helper; module b touches
    // the same helper and is refused by name.  Both facts in one
    // compile, which is what proves the check reads the *reference
    // site's* module and not some global mode.
    const a: TestModule = .{ .name = "a", .source =
        \\private func inner() -> i64:
        \\    return 1
        \\
        \\func outer() -> i64:
        \\    return inner()
        \\
    };
    const b: TestModule = .{ .name = "b", .source =
        \\import a
        \\
        \\func steal() -> i64:
        \\    return a.inner()
        \\
    };
    var files: TestLoader = .{ .modules = &.{ a, b } };
    var result = try compile_mod.compileProject(testing.allocator,
        \\import a
        \\import b
        \\
        \\func main():
        \\    print(str(a.outer() + b.steal()))
        \\
    , files.loader(), .{ .allow_host = true });
    defer result.deinit();
    try testing.expect(result == .failure);
    errdefer printDiagnostics(&result);
    try testing.expectEqual(@as(usize, 1), result.failure.count());
    const found = result.failure.at(0).?;
    try testing.expectEqualStrings("luce.sema.private", found.code);
    try testing.expectEqualStrings("inner is private to a", found.message);
}

test "mutual recursion crosses files unmarked, and is refused by name when one is marked" {
    const even: TestModule = .{ .name = "even", .source =
        \\import odd
        \\
        \\func check(value: i64) -> bool:
        \\    if value == 0:
        \\        return true
        \\    return odd.check(value - 1)
        \\
    };
    const odd_open: TestModule = .{ .name = "odd", .source =
        \\import even
        \\
        \\func check(value: i64) -> bool:
        \\    if value == 0:
        \\        return false
        \\    return even.check(value - 1)
        \\
    };
    const root =
        \\import even
        \\
        \\func main():
        \\    print(str(even.check(4)))
        \\
    ;
    try expectProjectCompiles(root, &.{ even, odd_open });
    const odd_marked: TestModule = .{ .name = "odd", .source =
        \\import even
        \\
        \\private func check(value: i64) -> bool:
        \\    if value == 0:
        \\        return false
        \\    return even.check(value - 1)
        \\
    };
    try expectPrivateSaying(root, &.{ even, odd_marked }, "check is private to odd");
}

test "a private region and a per-declaration marker produce the same stage-4 facts" {
    // The two spellings of Rng's wall, held to the same refusal
    // sentence — which is the observable form of "regions die in
    // stage 3" (D15).
    const region: TestModule = .{ .name = "rng", .source =
        \\struct Rng:
        \\    private:
        \\        state: i64
        \\
        \\    func next() -> i64:
        \\        self.state = self.state * 48271 % 2147483647
        \\        return self.state
        \\
        \\func rng(seed: i64) -> Rng:
        \\    return Rng(state = seed)
        \\
    };
    const marker: TestModule = .{ .name = "rng", .source =
        \\struct Rng:
        \\    private state: i64
        \\
        \\    func next() -> i64:
        \\        self.state = self.state * 48271 % 2147483647
        \\        return self.state
        \\
        \\func rng(seed: i64) -> Rng:
        \\    return Rng(state = seed)
        \\
    };
    const stealing =
        \\import rng
        \\
        \\func main():
        \\    var r = rng.Rng(state = 42)
        \\    print(str(r.next()))
        \\
    ;
    const using =
        \\import rng
        \\
        \\func main():
        \\    var r = rng.rng(42)
        \\    print(str(r.next()))
        \\
    ;
    for ([_]TestModule{ region, marker }) |shape| {
        try expectPrivateSaying(stealing, &.{shape}, "state of Rng is private to rng");
        try expectProjectCompiles(using, &.{shape});
    }
}

test "a namespaced constant resolves through the import that bound it" {
    // The positive half of the namespace rule, which the rejection
    // tests below never state: an imported module's file-scope
    // constant is reachable as `module.name` and folds like any other.
    //
    // The dotted *name* has no unimported-namespace check of its own
    // to pin beside them, and cannot: `ast.Call.callee` is a single
    // identifier token, so the dot branch of `resolveDeclared`
    // (`luce.sema.import`, semantics/builder.zig) has no input that
    // reaches it — every dotted call is parsed as a method and
    // resolved on the other path, which the next test covers.
    const constant_module: TestModule = .{ .name = "sizes", .source =
        \\const width = 80
        \\
    };
    var files: TestLoader = .{ .modules = &.{constant_module} };
    var imported = try compile_mod.compileProject(testing.allocator,
        \\import sizes
        \\
        \\func main():
        \\    let fine = sizes.width
        \\
    , files.loader(), .{});
    defer imported.deinit();
    try testing.expect(imported == .success);
}

test "luce.sema.reserved: a module cannot be imported under a reserved name" {
    // The binding an import introduces is a name like any other, so it
    // goes through the same reserved-word check every declaration
    // does — before the module is even opened.
    const module: TestModule = .{ .name = "trap", .source =
        \\func nothing():
        \\    return
        \\
    };
    var files: TestLoader = .{ .modules = &.{module} };
    var result = try compile_mod.compileProject(testing.allocator,
        \\import trap
        \\
        \\func main():
        \\    return
        \\
    , files.loader(), .{});
    defer result.deinit();
    try testing.expect(result == .failure);

    var reported = false;
    for (0..result.failure.count()) |index| {
        const found = result.failure.at(index).?;
        if (!std.mem.eql(u8, found.code, "luce.sema.reserved")) continue;
        try testing.expect(std.mem.indexOf(u8, found.message, "trap is a reserved name") != null);
        reported = true;
    }
    try testing.expect(reported);
}

test "luce.sema.duplicate: an import cannot take a struct's name" {
    // Both would bind the same word in the same scope, and the reader
    // is told which two things collided rather than being handed a
    // resolution that silently picked one.
    var files: TestLoader = .{ .modules = &.{util_module} };
    var result = try compile_mod.compileProject(testing.allocator,
        \\import util
        \\
        \\struct util:
        \\    x: i64
        \\
        \\func main():
        \\    return
        \\
    , files.loader(), .{});
    defer result.deinit();
    try testing.expect(result == .failure);

    var reported = false;
    for (0..result.failure.count()) |index| {
        const found = result.failure.at(index).?;
        if (!std.mem.eql(u8, found.code, "luce.sema.duplicate")) continue;
        if (std.mem.indexOf(u8, found.message, "collides with a struct of the same name") == null) continue;
        reported = true;
    }
    try testing.expect(reported);
}

// ---------------------------------------------------------------------------
// Tagged unions: the front half (docs/UNION.md)
// ---------------------------------------------------------------------------

test "a union compiles through construction, dispatch, bindings, and str(u)" {
    var program = try expectCompiles(
        \\union Shape:
        \\    empty
        \\    circle(radius: f64)
        \\    rect(width: f64, height: f64 = 1.0)
        \\
        \\    func corners() -> i64:
        \\        match self:
        \\            empty:
        \\                return 0
        \\            circle:
        \\                return 0
        \\            rect:
        \\                return 4
        \\
        \\    static func unit() -> Shape:
        \\        return Shape.circle(radius = 1.0)
        \\
        \\func main():
        \\    var s = Shape.rect(width = 2.0)
        \\    s = Shape.empty
        \\    let u = Shape.unit()
        \\    var total = u.corners()
        \\    match u:
        \\        empty:
        \\            total = 0
        \\        circle(radius):
        \\            total = total + i64(radius)
        \\        rect(width, height):
        \\            total = total + i64(width + height)
        \\    let name = str(u)
        \\    var late: Shape
        \\    assert(len(name) >= 0 and total >= 0)
        \\
    );
    defer program.deinit();

    // The variants table travels on the program, and the three
    // instructions were emitted: construction, the tag dispatch, and a
    // payload read in an arm (docs/UNION.md "Where it lands").
    try testing.expectEqual(@as(usize, 1), program.variants.len);
    try testing.expectEqualStrings("Shape", program.variants[0].name);
    try testing.expectEqual(@as(usize, 3), program.variants[0].members.len);
    try testing.expectEqualStrings("radius", program.variants[0].members[1].fields[0].name);
    var made: usize = 0;
    var tagged: usize = 0;
    var read: usize = 0;
    for (program.functions) |function| {
        for (function.instructions) |instruction| switch (instruction) {
            .variant_make => made += 1,
            .variant_tag => tagged += 1,
            .variant_field => read += 1,
            else => {},
        };
    }
    try testing.expect(made != 0);
    try testing.expect(tagged != 0);
    try testing.expect(read != 0);

    // The printer names what it prints.
    const dump = try mir.print(testing.allocator, &program);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "union Shape:") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "circle(radius: f64)") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "variant_make Shape.circle") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "variant_field") != null);
}

test "a union's refusals land where UNION.md puts them" {
    // D2: a union of bare members is an enum.
    try expectRejected(
        \\union Flag:
        \\    yes
        \\    no
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.union");
    // D3: a member is not a type.
    try expectRejected(
        \\union Shape:
        \\    circle(radius: f64)
        \\
        \\func main():
        \\    let c: Shape.circle = Shape.circle(radius = 1.0)
        \\
    , "luce.sema.union");
    // D12: a member that unconditionally contains the union makes the
    // type infinite, whichever member it is.
    try expectRejected(
        \\union Chain:
        \\    nil
        \\    cons(head: i64, tail: Chain)
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.union");
    // D15: a union may not be a map key.
    try expectRejected(
        \\union Shape:
        \\    empty
        \\    circle(radius: f64)
        \\
        \\func main():
        \\    var m = map[Shape, i64]()
        \\
    , "luce.sema.type");
    // D16: `==` on unions is refused naming match.
    try expectRejected(
        \\union Shape:
        \\    empty
        \\    circle(radius: f64)
        \\
        \\func main():
        \\    let a = Shape.empty
        \\    let b = Shape.empty
        \\    assert(a == b)
        \\
    , "luce.sema.union");
    // D1/D4: the union's own name is not a way in.
    try expectRejected(
        \\union Shape:
        \\    empty
        \\    circle(radius: f64)
        \\
        \\func main():
        \\    let s = Shape(1)
        \\
    , "luce.sema.union");
    // D4: a payload-carrying member is not a bare value...
    try expectRejected(
        \\union Shape:
        \\    empty
        \\    circle(radius: f64)
        \\
        \\func main():
        \\    let s = Shape.circle
        \\
    , "luce.sema.construct");
    // ...and a bare member takes no parentheses.
    try expectRejected(
        \\union Shape:
        \\    empty
        \\    circle(radius: f64)
        \\
        \\func main():
        \\    let s = Shape.empty()
        \\
    , "luce.sema.construct");
    // A construction misses fields by name, like a struct's.
    try expectRejected(
        \\union Shape:
        \\    empty
        \\    rect(width: f64, height: f64)
        \\
        \\func main():
        \\    let s = Shape.rect(width = 1.0)
        \\
    , "luce.sema.construct");
}

test "a union match keeps ENUMS R1 whole and extends it with bindings" {
    // D5: a partial field list is refused naming the missing fields.
    try expectRejected(
        \\union Shape:
        \\    empty
        \\    rect(width: f64, height: f64)
        \\
        \\func main():
        \\    let s = Shape.empty
        \\    match s:
        \\        empty:
        \\            return
        \\        rect(width):
        \\            return
        \\
    , "luce.sema.match");
    // R1: without an else, every member appears.
    try expectRejected(
        \\union Shape:
        \\    empty
        \\    circle(radius: f64)
        \\
        \\func main():
        \\    let s = Shape.empty
        \\    match s:
        \\        empty:
        \\            return
        \\
    , "luce.sema.match");
    // A name no member spells is a diagnostic about the union.
    try expectRejected(
        \\union Shape:
        \\    empty
        \\    circle(radius: f64)
        \\
        \\func main():
        \\    let s = Shape.empty
        \\    match s:
        \\        empty:
        \\            return
        \\        sphere:
        \\            return
        \\
    , "luce.sema.match");
    // D21: a binding is positional and the arm names it itself, so
    // `circle(diameter)` binds the radius under the arm's own name —
    // what the by-name rule refused is now the rename the specs pin.
    // What stays refused is a name repeated inside one arm.
    try expectRejected(
        \\union Shape:
        \\    empty
        \\    rect(width: f64, height: f64)
        \\
        \\func main():
        \\    let s = Shape.empty
        \\    match s:
        \\        empty:
        \\            return
        \\        rect(side, side):
        \\            return
        \\
    , "luce.sema.match");
    // An enum's arms bind nothing (D5 extends match; enums keep R3).
    try expectRejected(
        \\enum Method:
        \\    stored
        \\    deflated
        \\
        \\func main():
        \\    let m = Method.stored
        \\    match m:
        \\        stored(value):
        \\            return
        \\        deflated:
        \\            return
        \\
    , "luce.sema.match");
    // D11: an arm binding obeys no-shadowing, with the ordinary
    // duplicate-name diagnostic.
    try expectRejected(
        \\union Shape:
        \\    empty
        \\    circle(radius: f64)
        \\
        \\func main():
        \\    let radius = 1.0
        \\    let s = Shape.empty
        \\    match s:
        \\        empty:
        \\            return
        \\        circle(radius):
        \\            return
        \\
    , "luce.sema.duplicate");
}

test "imports are explicit, checked, and reported per file" {
    const script: types.CompileOptions = .{};
    var files: TestLoader = .{ .modules = &.{ geo_module, util_module } };

    // Reaching a loaded-but-unimported namespace names the fix in a
    // call, and the same sentence must survive when the member is a
    // value rather than a callable.
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
    // Pinned in full: this is the wording a *written* namespace gets,
    // and it comes from `methodNamespace` — `mod.func()` parses as a
    // method, so it never reaches the `resolveDeclared` site that the
    // f-string lowering does (`specs/errors_spec.zig`, the format-spec
    // case).  The two sentences live in two places for that reason,
    // and this is what holds the reader-facing one still.
    try testing.expectEqualStrings(
        "unknown namespace util; import util to use it",
        unimported.failure.at(0).?.message,
    );

    var unimported_value = try compile_mod.compileProject(testing.allocator,
        \\import geo
        \\
        \\func main():
        \\    let bad = util.TABLE
        \\
    , files.loader(), script);
    defer unimported_value.deinit();
    try testing.expect(unimported_value == .failure);
    try testing.expectEqualStrings("luce.sema.import", unimported_value.failure.at(0).?.code);
    try testing.expectEqualStrings(
        "unknown namespace util; import util to use it",
        unimported_value.failure.at(0).?.message,
    );

    // An indexed write goes through the same dotted value base.  The
    // constant-place preflight must not look through a loaded but
    // unimported namespace and leak the declaration as a const/type
    // error before the namespace gate gets to speak.
    var unimported_store = try compile_mod.compileProject(testing.allocator,
        \\import geo
        \\
        \\func main():
        \\    util.TABLE[0] = 2
        \\
    , files.loader(), script);
    defer unimported_store.deinit();
    try testing.expect(unimported_store == .failure);
    try testing.expectEqualStrings("luce.sema.import", unimported_store.failure.at(0).?.code);
    try testing.expectEqualStrings(
        "unknown namespace util; import util to use it",
        unimported_store.failure.at(0).?.message,
    );

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
        \\func helper() -> i64:
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
        .{ .name = "geo", .source = "func area() -> i64:\n    return \x00\n" },
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
        .{ .name = "geo", .source = "import geo\n\nfunc area() -> i64:\n    return 4\n" },
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
        .{ .name = "math", .source = "func answer() -> i64:\n    return 42\n" },
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

    // Both at once is one binding for two modules: refused, and the
    // message offers the alias on the import that can move.
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
    try testing.expect(std.mem.indexOf(u8, collision.failure.at(0).?.message, "import math as NAME") != null);

    // The remedy works: the sibling aliased out of the way, both
    // modules answer under their own bindings.
    var aliased = try compile_mod.compileProject(testing.allocator,
        \\import std.math
        \\import math as m2
        \\
        \\func main():
        \\    assert(m2.answer() == 42)
        \\    assert(math.ipow(2, 5) == 32)
        \\
    , files.loader(), script);
    defer aliased.deinit();
    if (aliased == .failure) {
        printDiagnostics(&aliased);
        return error.TestUnexpectedResult;
    }
}

test "two imports may not share a last segment, and the alias is the named remedy" {
    // Week one of subfolders: geo/shapes.luc and blocks/shapes.luc
    // both want the binding `shapes` (docs/PACKAGES.md D2).  The
    // refusal offers `as`, and taking the offer compiles.
    const script: types.CompileOptions = .{};
    var files: TestLoader = .{ .modules = &.{
        .{ .name = "geo.shapes", .source = "func area() -> i64:\n    return 4\n" },
        .{ .name = "blocks.shapes", .source = "func area() -> i64:\n    return 9\n" },
    } };

    var collision = try compile_mod.compileProject(testing.allocator,
        \\import geo.shapes
        \\import blocks.shapes
        \\
        \\func main():
        \\    assert(shapes.area() == 4)
        \\
    , files.loader(), script);
    defer collision.deinit();
    try testing.expect(collision == .failure);
    try testing.expectEqualStrings("luce.import.collision", collision.failure.at(0).?.code);
    try testing.expect(std.mem.indexOf(u8, collision.failure.at(0).?.message, "both bind the name shapes") != null);
    try testing.expect(std.mem.indexOf(u8, collision.failure.at(0).?.message, "import blocks.shapes as NAME") != null);

    var aliased = try compile_mod.compileProject(testing.allocator,
        \\import geo.shapes
        \\import blocks.shapes as blocks
        \\
        \\func main():
        \\    assert(shapes.area() == 4)
        \\    assert(blocks.area() == 9)
        \\
    , files.loader(), script);
    defer aliased.deinit();
    if (aliased == .failure) {
        printDiagnostics(&aliased);
        return error.TestUnexpectedResult;
    }
}

test "one module, one binding: a program cannot import geo.shapes under two names" {
    const script: types.CompileOptions = .{};
    var files: TestLoader = .{ .modules = &.{
        .{ .name = "geo.shapes", .source = "func area() -> i64:\n    return 4\n" },
        .{ .name = "user", .source = "import geo.shapes as gs\n\nfunc go() -> i64:\n    return gs.area()\n" },
    } };

    var result = try compile_mod.compileProject(testing.allocator,
        \\import geo.shapes
        \\import user
        \\
        \\func main():
        \\    assert(user.go() == shapes.area())
        \\
    , files.loader(), script);
    defer result.deinit();
    try testing.expect(result == .failure);
    const first = result.failure.at(0).?;
    try testing.expectEqualStrings("luce.import.collision", first.code);
    try testing.expect(std.mem.indexOf(u8, first.message, "already imported as shapes") != null);
}

test "an aliased module's hint spells the import with its alias" {
    // user binds geo.shapes as gs; the root uses gs without importing
    // it.  Any other spelling would bind something else, so the hint
    // carries the alias too.
    const script: types.CompileOptions = .{};
    var files: TestLoader = .{ .modules = &.{
        .{ .name = "geo.shapes", .source = "func area() -> i64:\n    return 4\n" },
        .{ .name = "user", .source = "import geo.shapes as gs\n\nfunc go() -> i64:\n    return gs.area()\n" },
    } };

    var result = try compile_mod.compileProject(testing.allocator,
        \\import user
        \\
        \\func main():
        \\    assert(gs.area() == user.go())
        \\
    , files.loader(), script);
    defer result.deinit();
    try testing.expect(result == .failure);
    const first = result.failure.at(0).?;
    try testing.expectEqualStrings("luce.sema.import", first.code);
    try testing.expect(std.mem.indexOf(u8, first.message, "import geo.shapes as gs") != null);
}

test "a dotted import that is missing names the folder path it was probed as" {
    const script: types.CompileOptions = .{};
    var files: TestLoader = .{ .modules = &.{} };
    var result = try compile_mod.compileProject(testing.allocator,
        \\import geo.shapes
        \\
        \\func main():
        \\    return
        \\
    , files.loader(), script);
    defer result.deinit();
    try testing.expect(result == .failure);
    const first = result.failure.at(0).?;
    try testing.expectEqualStrings("luce.import.missing", first.code);
    try testing.expect(std.mem.indexOf(u8, first.message, "geo/shapes.luc") != null);
}

test "member imports are checked at the import line" {
    const script: types.CompileOptions = .{};
    var files: TestLoader = .{ .modules = &.{.{
        .name = "geo",
        .source = "struct Point:\n    x: i64\n\nprivate func hidden() -> i64:\n    return 1\n\nfunc span(p: Point) -> i64:\n    return p.x\n",
    }} };

    // A member that does not exist is refused where it was asked for.
    var unknown = try compile_mod.compileProject(testing.allocator,
        \\from geo import missing
        \\
        \\func main():
        \\    return
        \\
    , files.loader(), script);
    defer unknown.deinit();
    try testing.expect(unknown == .failure);
    try testing.expectEqualStrings("luce.sema.import", unknown.failure.at(0).?.code);
    try testing.expect(std.mem.indexOf(u8, unknown.failure.at(0).?.message, "geo has no declaration named missing") != null);

    // Private is not unknown: the name exists and is withheld.
    var withheld = try compile_mod.compileProject(testing.allocator,
        \\from geo import hidden
        \\
        \\func main():
        \\    return
        \\
    , files.loader(), script);
    defer withheld.deinit();
    try testing.expect(withheld == .failure);
    try testing.expectEqualStrings("luce.sema.private", withheld.failure.at(0).?.code);
    try testing.expect(std.mem.indexOf(u8, withheld.failure.at(0).?.message, "hidden is private to geo") != null);

    // A member binding is a fresh word: a local declaration owns it.
    var collided = try compile_mod.compileProject(testing.allocator,
        \\from geo import Point
        \\
        \\struct Point:
        \\    z: i64
        \\
        \\func main():
        \\    return
        \\
    , files.loader(), script);
    defer collided.deinit();
    try testing.expect(collided == .failure);
    try testing.expectEqualStrings("luce.sema.duplicate", collided.failure.at(0).?.code);
    try testing.expect(std.mem.indexOf(u8, collided.failure.at(0).?.message, "duplicate name Point") != null);

    // A member import binds only its members; the namespace stays
    // unbound and the advice names the import that would bind it.
    var unbound = try compile_mod.compileProject(testing.allocator,
        \\from geo import Point
        \\
        \\func main():
        \\    let p = geo.Point(x = 1)
        \\
    , files.loader(), script);
    defer unbound.deinit();
    try testing.expect(unbound == .failure);
    try testing.expectEqualStrings("luce.sema.import", unbound.failure.at(0).?.code);
    try testing.expect(std.mem.indexOf(u8, unbound.failure.at(0).?.message, "import geo to use it") != null);

    // One module, one binding, program-wide: an alias binding and a
    // member import of the same module cannot disagree.
    var double = try compile_mod.compileProject(testing.allocator,
        \\import geo as g
        \\from geo import Point
        \\
        \\func main():
        \\    return
        \\
    , files.loader(), script);
    defer double.deinit();
    try testing.expect(double == .failure);
    try testing.expectEqualStrings("luce.import.collision", double.failure.at(0).?.code);

    // The same member twice is a duplicate of this file's own making.
    var twice = try compile_mod.compileProject(testing.allocator,
        \\from geo import Point, Point
        \\
        \\func main():
        \\    return
        \\
    , files.loader(), script);
    defer twice.deinit();
    try testing.expect(twice == .failure);
    try testing.expectEqualStrings("luce.sema.duplicate", twice.failure.at(0).?.code);
    try testing.expect(std.mem.indexOf(u8, twice.failure.at(0).?.message, "already bind it") != null);

    // A binding may not take a builtin type's name.
    var reserved = try compile_mod.compileProject(testing.allocator,
        \\from geo import span as str
        \\
        \\func main():
        \\    return
        \\
    , files.loader(), script);
    defer reserved.deinit();
    try testing.expect(reserved == .failure);
    try testing.expectEqualStrings("luce.sema.reserved", reserved.failure.at(0).?.code);
}

test "the routed list comparator requires std lists, not a sibling named lists" {
    var files: TestLoader = .{ .modules = &.{.{
        .name = "lists",
        .source = "func marker():\n    return\n",
    }} };
    var result = try compile_mod.compileProject(testing.allocator,
        \\import lists
        \\
        \\func before(a: i64, b: i64) -> bool:
        \\    return a < b
        \\
        \\func main():
        \\    var values: list[i64] = [3, 1, 2]
        \\    values.sort_by(before)
        \\
    , files.loader(), .{});
    defer result.deinit();

    try testing.expect(result == .failure);
    const first = result.failure.at(0).?;
    try testing.expectEqualStrings("luce.sema.import", first.code);
    try testing.expect(std.mem.indexOf(u8, first.message, "import std.lists") != null);
}

test "a missing import is spelled the way the author would have to write it" {
    const script: types.CompileOptions = .{};
    var files: TestLoader = .{ .modules = &.{
        .{ .name = "math", .source = "func answer() -> i64:\n    return 42\n" },
        .{ .name = "user", .source = "import math\n\nfunc go() -> i64:\n    return math.answer()\n" },
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
        \\func area() -> i64:
        \\    return "not an int"
        \\
        },
    } };
    var result = try compile_mod.compileProject(testing.allocator,
        \\import geo
        \\import std.math
        \\
        \\func main():
        \\    let bad: i64 = geo.area()
        \\    let worse: i64 = math.pi
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
        .{ .name = "a", .source = "import b\n\nfunc step(v: i64) -> i64:\n    if v == 0:\n        return 0\n    return b.step(v - 1)\n" },
        .{ .name = "b", .source = "import c\n\nfunc step(v: i64) -> i64:\n    return c.step(v)\n" },
        .{ .name = "c", .source = "import a\n\nfunc step(v: i64) -> i64:\n    return a.step(v)\n" },
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
        .{ .name = "a", .source = "import b\n\nconst width = b.height + 1\n" },
        .{ .name = "b", .source = "import a\n\nconst height = a.width + 1\n" },
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
    return expectRejectedOptions(source, script_options, code);
}

test "constants are compile-time: calls and nested objects are refused" {
    try failsWith(
        \\func answer() -> i64:
        \\    return 42
        \\
        \\const bad = answer()
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.const");
    try failsWith(
        \\struct Bag:
        \\    items: list[i64]
        \\
        \\const bad = Bag(items = [1])
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.const");
}

test "constant cycles, unknowns, and arithmetic faults are compile errors" {
    try failsWith(
        \\const a = b + 1
        \\const b = a + 1
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.const");
    try failsWith(
        \\const alone = missing + 1
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.const");
    try failsWith(
        \\const big = 9223372036854775807 + 1
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.const");
    try failsWith(
        \\const broken = 1 // 0
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.const");
}

test "constants share the one namespace and stay immutable" {
    try failsWith(
        \\const twice = 2
        \\
        \\func twice() -> i64:
        \\    return 2
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.duplicate");
    try failsWith(
        \\const width = 80
        \\
        \\func main():
        \\    let width = 3
        \\
    , "luce.sema.duplicate");
    try failsWith(
        \\const width = 80
        \\
        \\func main():
        \\    width = 3
        \\
    , "luce.sema.const");
    try failsWith(
        \\const len = 3
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.reserved");
    // The annotation is checked, and it is the *landing type*: `3`
    // has no type of its own and becomes an f64 here (docs/TYPES.md
    // D3), so what this proves is the direction that stays refused —
    // a floating value does not land on an integer annotation, because
    // numeric conversions are explicit.
    try failsWith(
        \\const wrong: i64 = 3.5
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.type");
    try failsWith(
        \\const wrong: bool = 3
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

// ---------------------------------------------------------------------------
// Stores, and the places they land in
// ---------------------------------------------------------------------------

test "a plain map store reads nothing; only the compound one defines" {
    // The two spellings side by side, because the difference between
    // them *is* the rule (docs/LANGUAGE.md, "Zero values").
    //
    //   `counts["a"] = 7`   one `index_set`, and no read at all.  A
    //                       store into a map has never needed to know
    //                       what was there, and routing it through the
    //                       defining read would cost a hash lookup and
    //                       buy nothing — the two orders reach the
    //                       same map, which is why no behavioural test
    //                       can tell them apart and why this one is
    //                       written against the instructions instead.
    //   `counts["b"] += 1`  `map_place` with the zero as its third
    //                       operand, then the same `index_set`.
    //
    // The key is loaded once for both halves of the compound form
    // (r7 feeds the read and the store), which is the "evaluated
    // once" guarantee in instruction form.
    var program = try expectCompilesOptions(
        \\func main():
        \\    var counts = map[str, i64]()
        \\    counts["a"] = 7
        \\    counts["b"] += 1
        \\
    , .{});
    defer program.deinit();
    const dump = try mir.print(testing.allocator, &program);
    defer testing.allocator.free(dump);
    try testing.expectEqualStrings(
        \\func main() -> None
        \\    local %0 (temporary): map[str, i64]
        \\    local %1 counts: map[str, i64]
        \\  b0:
        \\    r0 = heap_new map[str, i64]
        \\    local_set %1, r0
        \\    r2 = local_get %1
        \\    r3 = const data#0
        \\    r4 = const 7
        \\    intrinsic index_set, r2, r3, r4
        \\    r6 = local_get %1
        \\    r7 = const data#1
        \\    r8 = const 1
        \\    r9 = const 0
        \\    r10 = intrinsic map_place, r6, r7, r9
        \\    r11 = add.i64 r10, r8
        \\    intrinsic index_set, r6, r7, r11
        \\    r13 = local_get %1
        \\    intrinsic release, r13
        \\    ret
        \\
    , dump);
}

test "a plain store through a nested place reads nothing either" {
    // The same rule one step down.  `t.counts["a"] = 7` descends
    // through the field and stores; only `t.counts["b"] += 1` reads,
    // and it is the *leaf* of the chain that reads — every step above
    // it is an ordinary descent and keeps its trap.  Counting the
    // `map_place`s is what says so: exactly one, for the one statement
    // that is a compound store.
    var program = try expectCompilesOptions(
        \\struct Tally:
        \\    counts: map[str, i64]
        \\
        \\func main():
        \\    var t = Tally(counts = map[str, i64]())
        \\    t.counts["a"] = 7
        \\    t.counts["b"] += 1
        \\
    , .{});
    defer program.deinit();
    const dump = try mir.print(testing.allocator, &program);
    defer testing.allocator.free(dump);
    var defines: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, dump, at, "intrinsic map_place")) |found| {
        defines += 1;
        at = found + 1;
    }
    try testing.expectEqual(@as(usize, 1), defines);
}

test "a compound store into a list or an array still reads through index_get" {
    // The non-change, pinned.  `map_place` is a map instruction and
    // the verifier refuses it anywhere else, but stage 4 must not emit
    // it anywhere else either — so the instruction a list compound
    // lowers to is written down here rather than inferred from the
    // absence of a failure.
    var program = try expectCompilesOptions(
        \\func main():
        \\    var xs = [1, 2]
        \\    xs[0] += 1
        \\    var grid = array[i64](2, 2)
        \\    grid[1, 1] += 1
        \\
    , .{});
    defer program.deinit();
    const dump = try mir.print(testing.allocator, &program);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "intrinsic map_place") == null);
    var reads: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, dump, at, "intrinsic index_get")) |found| {
        reads += 1;
        at = found + 1;
    }
    try testing.expectEqual(@as(usize, 2), reads);
}

// ---------------------------------------------------------------------------
// Packages: root isolation and root-qualified serialized names
// ---------------------------------------------------------------------------

test "two packages shipping the same file name both load, apart (docs/PACKAGES.md D4, D7)" {
    // The isolation the (root, name) registry key and the
    // root-qualified prefixes exist for: two packages each carry a
    // `util.luc`, each package's `import util` answers inside its own
    // root, and the program compiles with both — no collision, no
    // cross-package aliasing, no duplicate declaration.
    var packaged: TestLoader = .{ .modules = &.{
        .{
            .name = "alpha",
            .root = "alpha-1.0.0",
            .path = ".luce/packages/alpha-1.0.0/alpha.luc",
            .source = "import util\n\nfunc scaled(v: i64) -> i64:\n    return util.factor() * v\n",
        },
        .{
            .name = "beta",
            .root = "beta-1.0.0",
            .path = ".luce/packages/beta-1.0.0/beta.luc",
            .source = "import util\n\nfunc shifted(v: i64) -> i64:\n    return util.factor() + v\n",
        },
        .{
            .name = "util",
            .from = "alpha-1.0.0",
            .root = "alpha-1.0.0",
            .path = ".luce/packages/alpha-1.0.0/util.luc",
            .source = "func factor() -> i64:\n    return 10\n",
        },
        .{
            .name = "util",
            .from = "beta-1.0.0",
            .root = "beta-1.0.0",
            .path = ".luce/packages/beta-1.0.0/util.luc",
            .source = "func factor() -> i64:\n    return 100\n",
        },
    } };
    var result = try compile_mod.compileProject(testing.allocator,
        \\import alpha
        \\import beta
        \\
        \\func main():
        \\    assert(alpha.scaled(2) == 20)
        \\    assert(beta.shifted(2) == 102)
        \\
    , packaged.loader(), .{});
    var program = switch (result) {
        .success => |compiled| compiled,
        .failure => |*diagnostics| {
            const rendered = try diagnostics.render(testing.allocator);
            defer testing.allocator.free(rendered);
            std.debug.print("unexpected diagnostics:\n{s}", .{rendered});
            result.deinit();
            return error.TestUnexpectedResult;
        },
    };
    defer program.deinit();

    // The serialized module keeps the two utils apart by name: each
    // function carries its root, so the `.lcm` cannot merge them and a
    // trace names the package a frame came from (D7, format 39).
    var saw_alpha = false;
    var saw_beta = false;
    for (program.functions) |function| {
        if (std.mem.eql(u8, function.name, "alpha-1.0.0/util.factor")) saw_alpha = true;
        if (std.mem.eql(u8, function.name, "beta-1.0.0/util.factor")) saw_beta = true;
        // No function of either package serializes under the bare
        // name the two would merge at.
        try testing.expect(!std.mem.eql(u8, function.name, "util.factor"));
    }
    try testing.expect(saw_alpha);
    try testing.expect(saw_beta);

    const encoded = try mir.module.encode(testing.allocator, &program);
    defer testing.allocator.free(encoded);
    try testing.expect(std.mem.indexOf(u8, encoded, "alpha-1.0.0/util.factor") != null);
    try testing.expect(std.mem.indexOf(u8, encoded, "beta-1.0.0/util.factor") != null);
}

test "a package's util and the project's util never answer for each other" {
    // The project has a util.luc of its own; the package carries one
    // too.  Each import means its own file — the project's main sees
    // the project's, the package sees the package's — and both compile
    // in one program.
    var packaged: TestLoader = .{ .modules = &.{
        .{
            .name = "util",
            .from = "",
            .source = "func factor() -> i64:\n    return 2\n",
        },
        .{
            .name = "geo",
            .root = "geo-1.2.0",
            .path = ".luce/packages/geo-1.2.0/geo.luc",
            .source = "import util\n\nfunc measure() -> i64:\n    return util.factor()\n",
        },
        .{
            .name = "util",
            .from = "geo-1.2.0",
            .root = "geo-1.2.0",
            .path = ".luce/packages/geo-1.2.0/util.luc",
            .source = "func factor() -> i64:\n    return 7\n",
        },
    } };
    var result = try compile_mod.compileProject(testing.allocator,
        \\import util
        \\import geo
        \\
        \\func main():
        \\    assert(util.factor() == 2)
        \\    assert(geo.measure() == 7)
        \\
    , packaged.loader(), .{});
    var program = switch (result) {
        .success => |compiled| compiled,
        .failure => |*diagnostics| {
            const rendered = try diagnostics.render(testing.allocator);
            defer testing.allocator.free(rendered);
            std.debug.print("unexpected diagnostics:\n{s}", .{rendered});
            result.deinit();
            return error.TestUnexpectedResult;
        },
    };
    program.deinit();
}

/// One consumer program over one vendored package, compiled and
/// serialized — the bytes the artifact cache keys on.  The package's
/// root token and its internal `util.luc` are the two knobs the cache
/// test below turns.  The caller owns the bytes.
fn encodePackaged(token: []const u8, util_source: []const u8) ![]u8 {
    var packaged: TestLoader = .{ .modules = &.{
        .{
            .name = "geo",
            .root = token,
            .source = "import util\n\nfunc measure() -> i64:\n    return util.factor()\n",
        },
        .{
            .name = "util",
            .from = token,
            .root = token,
            .source = util_source,
        },
    } };
    var result = try compile_mod.compileProject(testing.allocator,
        \\import geo
        \\
        \\func main():
        \\    assert(geo.measure() == geo.measure())
        \\
    , packaged.loader(), .{});
    var program = switch (result) {
        .success => |compiled| compiled,
        .failure => |*diagnostics| {
            const rendered = try diagnostics.render(testing.allocator);
            defer testing.allocator.free(rendered);
            std.debug.print("unexpected diagnostics:\n{s}", .{rendered});
            result.deinit();
            return error.TestUnexpectedResult;
        },
    };
    defer program.deinit();
    return mir.module.encode(testing.allocator, &program);
}

test "the artifact cache key moves with a package file and with its resolution (docs/PACKAGES.md D5)" {
    // `.luce/cache/` keys an artifact on a hash of the encoded module
    // (`apps/loom/runner.zig`), and the encoded module is rebuilt from
    // *all* loaded sources with their root tokens in the serialized
    // names — so an edited package file moves the key, and so does a
    // resolution change that re-roots the very same bytes.  This test
    // is what the loom cache's invalidation story stands on.
    const ten = "func factor() -> i64:\n    return 10\n";
    const eleven = "func factor() -> i64:\n    return 11\n";

    const baseline = try encodePackaged("geo-1.2.0", ten);
    defer testing.allocator.free(baseline);

    // Same sources, same resolution: the same bytes, so a warm cache
    // stays warm.
    const again = try encodePackaged("geo-1.2.0", ten);
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(u8, baseline, again);

    // One edited package file: a different module, a different key.
    const edited = try encodePackaged("geo-1.2.0", eleven);
    defer testing.allocator.free(edited);
    try testing.expect(!std.mem.eql(u8, baseline, edited));

    // The same bytes resolved as a different version: the root token
    // travels in the serialized names, so a `luce.yaml` edit that
    // changes resolution changes the key too.
    const rerooted = try encodePackaged("geo-1.3.0", ten);
    defer testing.allocator.free(rerooted);
    try testing.expect(!std.mem.eql(u8, baseline, rerooted));
}

// The compiler's public contract is deliberately two-valued: trusted MIR or
// diagnostics.  This target walks arbitrary prepared source through every
// front-end stage and checks the boundary that later stages rely on.  It is
// intentionally separate from the parser fuzzer: parser recovery can be
// correct while name resolution, lowering, or optimization still mishandles
// the recovered tree.
test "fuzz: compilation yields verified MIR or bounded diagnostics" {
    try testing.fuzz({}, compileAnything, .{ .corpus = &.{
        "",
        "func main():\n    return\n",
        "func main():\n    let value = (1 + 2) * 3\n",
        "struct Point:\n    x: f64\n    y: f64\n\nfunc main():\n    let p = Point(x = 1.0, y = 2.0)\n",
        "union Shape:\n    circle(radius: f64)\n    square(side: f64)\n\nfunc main():\n    let s = Shape.circle(radius = 1.0)\n",
        "func main():\n    let broken = (1 +\n",
    } });
}

fn compileAnything(_: void, smith: *testing.Smith) anyerror!void {
    var buffer: [512]u8 = undefined;
    const length = smith.sliceWeightedBytes(&buffer, &.{
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .rangeAtMost(u8, 0x20, 0x7e, 5),
        .value(u8, ' ', 5),
        .value(u8, '\n', 5),
        .value(u8, ':', 3),
        .value(u8, '(', 3),
        .value(u8, ')', 3),
        .value(u8, '"', 2),
        .value(u8, '{', 2),
        .value(u8, '}', 2),
    });

    const prepared = try luce_source.prepare(testing.allocator, buffer[0..length]);
    const source = switch (prepared) {
        .problem => return,
        .text => |text| text,
    };
    defer testing.allocator.free(source);

    var result = try compile_mod.compile(testing.allocator, source, .{ .source_name = "fuzz.luc" });
    defer result.deinit();
    switch (result) {
        .success => |*program| try mir.verify(testing.allocator, program),
        .failure => |*diagnostics| {
            try testing.expect(diagnostics.count() != 0);
            for (0..diagnostics.count()) |index| {
                const item = diagnostics.at(index).?;
                try testing.expect(item.code.len != 0);
                try testing.expect(item.span.start <= item.span.end);
                if (diagnostics.sources.at(item.file)) |file| {
                    try testing.expect(item.span.end <= file.text.len);
                } else {
                    try testing.expectEqual(@as(usize, 0), item.span.start);
                    try testing.expectEqual(@as(usize, 0), item.span.end);
                }
            }
            const rendered = try diagnostics.render(testing.allocator);
            defer testing.allocator.free(rendered);
        },
    }
}

test "an inline ':' block holds exactly one statement" {
    // A second statement on the line has no separator between it and
    // the first — Luce has none — so `endOfStatement` refuses it, the
    // same way it refuses two statements run together anywhere.
    try expectRejected(
        \\func main():
        \\    if true: let x = 1 let y = 2
        \\
    , "luce.parse.expected");
    // ':' then a newline is still the indented form, which still wants
    // a body — an inline block never makes an empty block legal.
    try expectRejected(
        \\func main():
        \\    if true:
        \\    print("after")
        \\
    , "luce.parse.expected");
}

test "an expression lambda uses => and the old -> is rejected" {
    // `=>` yields; `->` declares a type. The retired lambda arrow gets
    // a focused diagnostic naming the one-token fix.
    try expectRejected(
        \\func keep(v: i64, p: func(i64) -> bool) -> bool:
        \\    return p(v)
        \\func main():
        \\    print(str(keep(7, (x) -> x > 5)))
        \\
    , "luce.parse.expression");
}

test "an inline ':' body is one simple statement, not a compound one" {
    try expectRejected(
        \\func main():
        \\    if true: if false: print("x")
        \\
    , "luce.parse.expected");
    try expectRejected(
        \\func main():
        \\    for i in range(0, 3): while i > 0: print(str(i))
        \\
    , "luce.parse.expected");
}

test "a bare typed lambda cannot infer its result, and is taught the two forms" {
    try expectRejected(
        \\func main():
        \\    let f = (x: i64) => x > 0
        \\    print(str(f(5)))
        \\
    , "luce.sema.type");
}
