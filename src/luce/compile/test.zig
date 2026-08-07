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
        \\    let x = long("no")
        \\
    , .{}, &.{.{ .code = "luce.sema.convert", .line = 2, .column = 13 }});
    // An unknown field, pointed at the access.
    try expectDiagnostics(
        \\struct Point:
        \\    x: double
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
    // term_rows():` underlined the `func` as part of a sentence about
    // the word `term_rows`, and `let print = 3` underlined `= 3`.  The
    // message named one word and the caret covered a phrase, which
    // leaves the reader working out which part is meant.
    //
    // Columns, so this cannot pass by pointing at the right line.
    try expectDiagnostics(
        \\func term_rows() -> long:
        \\    return 1
        \\
        \\func main():
        \\    return
        \\
    , .{}, &.{.{ .code = "luce.sema.reserved", .line = 1, .column = 6 }});
    try expectDiagnostics(
        \\struct term_style:
        \\    x: long
        \\
        \\func main():
        \\    return
        \\
    , .{}, &.{.{ .code = "luce.sema.reserved", .line = 1, .column = 8 }});
    try expectDiagnostics(
        \\let print = 3
        \\
        \\func main():
        \\    return
        \\
    , .{}, &.{.{ .code = "luce.sema.reserved", .line = 1, .column = 5 }});
    try expectDiagnostics(
        \\func main():
        \\    let term_cols = 1
        \\
    , .{}, &.{.{ .code = "luce.sema.reserved", .line = 2, .column = 9 }});
    try expectDiagnostics(
        \\func main():
        \\    var term_rows: long
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
        \\    x: long
        \\
        \\struct Point:
        \\    y: long
        \\
        \\func main():
        \\    return
        \\
    , .{}, &.{.{ .code = "luce.sema.duplicate", .line = 4, .column = 8 }});
    try expectDiagnostics(
        \\struct Point:
        \\    x: long
        \\    x: long
        \\
        \\func main():
        \\    return
        \\
    , .{}, &.{.{ .code = "luce.sema.duplicate", .line = 3, .column = 5 }});
    try expectDiagnostics(
        \\func f(a: long, a: long) -> long:
        \\    return a
        \\
        \\func main():
        \\    return
        \\
    , .{}, &.{.{ .code = "luce.sema.duplicate", .line = 1, .column = 17 }});
    try expectDiagnostics(
        \\func main():
        \\    let a = 1
        \\    if true:
        \\        let a = 2
        \\        print(string(a))
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
        .{ .source = "func main():\n    let a: list = []\n", .code = "luce.sema.type" },
        .{ .source = "func main():\n    let a = new array(long)\n", .code = "luce.sema.new" },
        .{ .source = "func main():\n    let a = 99999999999999999999999\n", .code = "luce.sema.literal" },
    };
    for (cases) |case| {
        try expectRejectedOptions(case.source, .{}, case.code);
    }
}

test "the pipeline survives every allocation failure" {
    // A ratchet, not a bug-finder (all four pass today): the moment
    // someone adds a non-arena cache or an ArrayList that outlives an
    // error path, this catches the leak or the swallowed OOM.  Also
    // enforces error.NondeterministicMemoryUsage.
    const representative =
        \\struct Point:
        \\    x: double
        \\    tag: string
        \\
        \\func total(values: list(long)) -> long:
        \\    var sum = 0
        \\    for value in values:
        \\        sum = sum + value
        \\    return sum
        \\
        \\func main():
        \\    var xs = [3, 1, 2]
        \\    xs.sort()
        \\    var ages = new map(string, long)
        \\    ages["ada"] = total(xs)
        \\    print(string(ages["ada"]))
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
    try expectRejected(
        \\func helper() -> long:
        \\    return 1
        \\
    , "luce.sema.main");
    try expectRejected(
        \\func main(value: long):
        \\    return
        \\
    , "luce.sema.main");
    try expectRejected(
        \\func main() -> long:
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
        \\    func twice(value: long) -> long:
        \\        return value * 2
        \\
        \\struct Pair:
        \\    left: long
        \\    func sum(left: long, right: long) -> long:
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
        \\    value: long
        \\    func value() -> long:
        \\        return 1
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.duplicate");
    try expectRejected(
        \\struct Helpers:
        \\    func one() -> long:
        \\        return 1
        \\
        \\func main():
        \\    let bad = Helpers.missing()
        \\
    , "luce.sema.call");
    try expectRejected(
        \\struct Helpers:
        \\    func one() -> long:
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
        \\    x: double
        \\    y: double
        \\
        \\func scale_point(point: Point, factor: double) -> Point:
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
        \\    var total: long = 0
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
        \\    print(string("abc".find("b")))
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

// A numeric literal lands at the type of the place it goes into and
// is *parsed* there (docs/TYPES.md D3).  With one integer width and
// one float width, landing and widening-afterwards agree on every
// value, so no program can tell them apart — which is exactly why the
// claim has to be checked here, against the IR, rather than by
// running something.  A landed literal is one `const_double`; a
// promoted one is a `const_long` and a `convert` beside it, and the
// difference stops being cosmetic the moment the widths differ, where
// the promoted form rounds twice.
//
// Every place a type is written down gets a line: an annotation, a
// call argument, a return, and through a leading minus, which does
// not move where a number lands.
test "a literal lands at its context's type, with no conversion behind it" {
    var program = try expectCompiles(
        \\func takes(x: double) -> double:
        \\    return x
        \\
        \\func answers() -> double:
        \\    return 12
        \\
        \\func main():
        \\    let annotated: double = 7
        \\    let negated: double = -3
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
                .const_double => floats += 1,
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
    // Unannotated, so `value` is an `int` and the multiply is at that
    // width — the resize's default, read straight off the IR
    // (docs/TYPES.md, the ladder's rule 1).
    try testing.expect(std.mem.indexOf(u8, first, "local %0 value: int") != null);
    try testing.expect(std.mem.indexOf(u8, first, "multiply.int") != null);
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
        \\func size(width: long, height: long, deep: bool) -> long:
        \\    if deep:
        \\        return width * height * 2
        \\    return width * height
        \\
        \\func main():
        \\    assert(size(3, 4, false) == 12)
        \\
    ;
    const named =
        \\func size(width: long, height: long, deep: bool) -> long:
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

test "the IR dump has a stable golden shape (short-circuit + ownership)" {
    // A full-dump snapshot of the two trickiest lowerings at once:
    // short-circuit `and` splitting a block, and scope ownership
    // inserting object_bind/object_unbind around the list.  Behavior
    // tests can't see block ordering or a lost temp release; this
    // does, and it documents the IR for a reader.  Regenerate
    // deliberately when lowering changes on purpose.
    //
    // This is the *optimized* program — what `luce build` compiles.
    // Stage 7 has already been over it: the hidden temporary's bind and
    // its inert release are gone (07_optimize/ownership.zig).  The
    // re-reads of `xs` are *not* folded, and deliberately: block-local
    // value numbering was the interpreter's pass and went with it, and
    // `default<O3>` folds them downstream (docs/ENGINE.md step 7).
    // `luce ir --full` prints the raw lowering instead.  The temporary
    // is still in the local table: `give`/`free` carry a local id as an
    // integer value, so nothing may renumber locals yet
    // (07_optimize/dead.zig).
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
        \\    local %0 (temporary): list(int)
        \\    local %1 xs: list(int)
        \\    local %2 (temporary): bool
        \\  b0:
        \\    r0 = const 1
        \\    r1 = const 2
        \\    r2 = heap_new list(int)
        \\    intrinsic append_value, r2, r0
        \\    intrinsic append_value, r2, r1
        \\    local_set %1, r2
        \\    object_bind %1, r2
        \\    r7 = local_get %1
        \\    r8 = intrinsic len, r7
        \\    r9 = const 0
        \\    r10 = greater.long r8, r9
        \\    local_set %2, r10
        \\    branch r10, b1, b2
        \\  b1:
        \\    r13 = local_get %1
        \\    r14 = const 0
        \\    r15 = intrinsic index_get, r13, r14
        \\    r16 = const 1
        \\    r17 = equal.int r15, r16
        \\    local_set %2, r17
        \\    jump b2
        \\  b2:
        \\    r20 = local_get %2
        \\    branch r20, b3, b4
        \\  b3:
        \\    r22 = local_get %1
        \\    r23 = const 3
        \\    intrinsic append_value, r22, r23
        \\    jump b4
        \\  b4:
        \\    r26 = local_get %1
        \\    object_unbind %1, r26
        \\    ret
        \\
    , dump);
}

test "no implicit narrowing, no reassigned let, no shadowing" {
    // `long` widens to `double` on its own (docs/NUMERICS.md); nothing
    // goes the other way without being asked, which is what keeps
    // float contagion from ever being silent.
    try expectRejected(
        \\func main():
        \\    let narrowed: long = 2.5
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
        \\func partial(flag: bool) -> long:
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
        \\    red: double
        \\    green: double
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
    // `red = 1` is a widening, not a mismatch (docs/NUMERICS.md); a
    // string is still a string.
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
        \\func helper(value: long) -> long:
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
        \\    x: double
        \\    y: double
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
    try expectRejected(
        \\func main():
        \\    print("hello")
        \\
    , "luce.sema.host");
    try expectRejected(
        \\func main():
        \\    let text = file_read("notes.txt")
        \\
    , "luce.sema.host");

    var hosted = try compile_mod.compile(testing.allocator,
        \\func main(args: list(string)) -> !:
        \\    print("hello " + args[0])
        \\    let text = file_read("notes.txt") catch ""
        \\    try file_write("copy.txt", text)
        \\    print("copied")
        \\    term_clear()
        \\    term_move(0, 0)
        \\    term_style(114, -1, false)
        \\    term_write((key_read() else "eof") + key_text())
        \\    term_flush()
        \\
    , .{ .allow_host = true });
    defer hosted.deinit();
    try testing.expect(hosted == .success);

    // `key_read` answers `string?`, so a program that treats a key
    // that never came as a key is refused where it is written rather
    // than looping on it at run time (docs/FAILURE.md).
    try expectRejectedOptions(
        \\func main():
        \\    term_write(key_read())
        \\
    , .{ .allow_host = true }, "luce.sema.type");

    try expectRejectedOptions(
        \\func main() -> !:
        \\    let bad = try file_read(7)
        \\
    , .{ .allow_host = true }, "luce.sema.type");
    // A call that can fail may not be written as if it could not:
    // this is the shape `if files.write_lines(...)` used to have, and
    // it is the whole of why a swallowed failure is now unwritable.
    try expectRejectedOptions(
        \\func main():
        \\    let text = file_read("notes.txt")
        \\
    , .{ .allow_host = true }, "luce.sema.fallible");
    // And `try` needs a caller that said it can fail.
    try expectRejectedOptions(
        \\func main():
        \\    let text = try file_read("notes.txt")
        \\
    , .{ .allow_host = true }, "luce.sema.fallible");
    try expectRejectedOptions(
        \\func main():
        \\    term_style(1, 2, 3)
        \\
    , .{ .allow_host = true }, "luce.sema.type");
}

test "collections type-check and reject misuse at compile time" {
    const script: types.CompileOptions = .{};

    var featured = try compile_mod.compile(testing.allocator,
        \\func sum(values: list(long)) -> long:
        \\    var total: long = 0
        \\    for value in values:
        \\        total = total + value
        \\    return total
        \\
        \\func label(counts: map(string, long), grid: array(long, _, _)) -> string:
        \\    var b = new builder()
        \\    b.append(string(len(counts) + grid[0, 0]))
        \\    let made = b.build()
        \\    free(b)
        \\    return made
        \\
        \\func main():
        \\    var values: list(long) = []
        \\    values.append(4)
        \\    let total = sum(values[0:])
        \\    free(values)
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
        \\    var m = new map(double, long)
        \\
    , script, "luce.sema.type");
    try expectRejectedOptions(
        \\func main():
        \\    var grid = new array(long, 2, 2)
        \\    let bad = grid[0]
        \\
    , script, "luce.sema.index");
    try expectRejectedOptions(
        \\func main():
        \\    var m = new map(string, long)
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
        return .{ .context = self, .load = load };
    }
};

const geo_module: TestModule = .{ .name = "geo", .source =
    \\import util
    \\
    \\struct Point:
    \\    x: double
    \\    y: double
    \\
    \\struct Text:
    \\    func twice(value: long) -> long:
    \\        return value * 2
    \\
    \\func make(x: double, y: double) -> Point:
    \\    return Point(x = x, y = y)
    \\
    \\func length(point: Point) -> double:
    \\    return util.hypot(point.x, point.y)
    \\
};

const util_module: TestModule = .{ .name = "util", .source =
    \\func hypot(x: double, y: double) -> double:
    \\    return sqrt(x * x + y * y)
    \\
};

test "luce.import.limit: an import graph past the module ceiling is refused" {
    // The backstop on a runaway import graph, and the only diagnostic
    // in the compiler that needs more than a page of source to reach:
    // sixty-four modules is more than any test writes by hand, so it
    // is generated here.  Refusing at the ceiling is what keeps a
    // pathological project from being a compiler that never returns.
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const count = 70;
    const modules = try arena.alloc(TestModule, count);
    var root: std.ArrayList(u8) = .empty;
    for (modules, 0..) |*module, index| {
        module.* = .{
            .name = try std.fmt.allocPrint(arena, "m{d}", .{index}),
            .source = try std.fmt.allocPrint(
                arena,
                "func value{d}() -> long:\n    return {d}\n",
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
        .{},
    );
    defer result.deinit();
    try testing.expect(result == .failure);

    var reported = false;
    for (0..result.failure.count()) |index| {
        const found = result.failure.at(index).?;
        if (!std.mem.eql(u8, found.code, "luce.import.limit")) continue;
        try testing.expect(std.mem.indexOf(u8, found.message, "too many modules") != null);
        reported = true;
    }
    try testing.expect(reported);

    // Well under the ceiling, the same shape compiles: the limit is a
    // backstop, not a budget any real project can feel.
    const few = modules[0..8];
    var small: std.ArrayList(u8) = .empty;
    for (few, 0..) |_, index| try small.print(arena, "import m{d}\n", .{index});
    try small.appendSlice(arena, "\nfunc main():\n    return\n");
    var fewer: TestLoader = .{ .modules = few };
    var fine = try compile_mod.compileProject(
        testing.allocator,
        small.items,
        fewer.loader(),
        .{},
    );
    defer fine.deinit();
    try testing.expect(fine == .success);
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
    \\private func helper() -> long:
    \\    return 41
    \\
    \\func visible() -> long:
    \\    return helper() + 1
    \\
    \\private let seed = 41
    \\let answer = seed + 1
    \\
    \\private struct Inner:
    \\    n: long
    \\
    \\    func make() -> Inner:
    \\        return Inner(n = 1)
    \\
    \\struct Handle:
    \\    private:
    \\        slot: long
    \\    label: long
    \\
    \\func fresh() -> Handle:
    \\    return Handle(slot = 1, label = 2)
    \\
    \\struct Session:
    \\    name: string
    \\    private id: long
    \\    private token: long = 0
    \\
    \\    func title(self) -> string:
    \\        return self.name
    \\
    \\    private func stamp(self) -> long:
    \\        return self.id
    \\
    \\    private func widest() -> long:
    \\        return 64
    \\
    \\func open(name: string) -> Session:
    \\    return Session(name = name, id = 7)
    \\
    \\struct Box:
    \\    held: Handle
    \\
    \\private enum Hidden:
    \\    first
    \\    second
    \\
    \\    func lead() -> Hidden:
    \\        return Hidden.first
    \\
    \\enum Shown(byte):
    \\    open = 0
    \\    shut = 1
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
        \\    print(string(vault.helper()))
        \\
    , &.{vault_module}, "helper is private to vault");
    // A public function calling its module's own private one is
    // ordinary code: visibility gates the reference site's module,
    // never the call graph (D1).
    try expectProjectCompiles(
        \\import vault
        \\
        \\func main():
        \\    print(string(vault.visible()))
        \\
    , &.{vault_module});
}

test "luce.sema.private: a private constant is withheld, and its folded value crosses" {
    try expectPrivateSaying(
        \\import vault
        \\
        \\func main():
        \\    print(string(vault.seed))
        \\
    , &.{vault_module}, "seed is private to vault");
    // D8: a public constant folds from private ones; the value
    // crossed, not the name — in a body and in a constant initializer.
    try expectProjectCompiles(
        \\import vault
        \\
        \\let doubled = vault.answer * 2
        \\
        \\func main():
        \\    print(string(vault.answer + doubled))
        \\
    , &.{vault_module});
    // The same gate holds inside a constant initializer's fold.
    try expectPrivateSaying(
        \\import vault
        \\
        \\let stolen = vault.seed + 1
        \\
        \\func main():
        \\    print(string(stolen))
        \\
    , &.{vault_module}, "seed is private to vault");
}

test "luce.sema.private: a private struct is withheld from annotation, construction, and namespace" {
    try expectPrivateSaying(
        \\import vault
        \\
        \\func read(p: vault.Inner) -> long:
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
        \\    print(string(p.n))
        \\
    , &.{vault_module}, "Inner is private to vault");
    // A namespace function of a private struct is reached through the
    // struct's name, and it is the struct that is withheld.
    try expectPrivateSaying(
        \\import vault
        \\
        \\func main():
        \\    let p = vault.Inner.make()
        \\    print(string(p.n))
        \\
    , &.{vault_module}, "Inner is private to vault");
}

test "luce.sema.private: a private field refuses reads, writes, and construction naming" {
    try expectPrivateSaying(
        \\import vault
        \\
        \\func main():
        \\    var h = vault.fresh()
        \\    print(string(h.slot))
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
        \\    print(string(s.stamp()))
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
        \\func read(m: vault.Hidden) -> long:
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
        \\func spell(s: vault.Shown) -> string:
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
    // of them: the static method spelling, the namespace function of a
    // public struct, the nested place, the compound assignment.  One
    // declaration, one sentence, whichever door (VISIBILITY.md D2).
    try expectPrivateSaying(
        \\import vault
        \\
        \\func main():
        \\    let s = vault.open("dy")
        \\    print(string(vault.Session.stamp(s)))
        \\
    , &.{vault_module}, "stamp is private to vault");
    try expectPrivateSaying(
        \\import vault
        \\
        \\func main():
        \\    print(string(vault.Session.widest()))
        \\
    , &.{vault_module}, "widest is private to vault");
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
        \\    print(string(boxed.held.slot))
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
        \\    print(string(boxed.held.label))
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
        \\    print(string(vault.sed))
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
        \\    print(string(vault.helperr()))
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
        \\private func inner() -> long:
        \\    return 1
        \\
        \\func outer() -> long:
        \\    return inner()
        \\
    };
    const b: TestModule = .{ .name = "b", .source =
        \\import a
        \\
        \\func steal() -> long:
        \\    return a.inner()
        \\
    };
    var files: TestLoader = .{ .modules = &.{ a, b } };
    var result = try compile_mod.compileProject(testing.allocator,
        \\import a
        \\import b
        \\
        \\func main():
        \\    print(string(a.outer() + b.steal()))
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
        \\func check(value: long) -> bool:
        \\    if value == 0:
        \\        return true
        \\    return odd.check(value - 1)
        \\
    };
    const odd_open: TestModule = .{ .name = "odd", .source =
        \\import even
        \\
        \\func check(value: long) -> bool:
        \\    if value == 0:
        \\        return false
        \\    return even.check(value - 1)
        \\
    };
    const root =
        \\import even
        \\
        \\func main():
        \\    print(string(even.check(4)))
        \\
    ;
    try expectProjectCompiles(root, &.{ even, odd_open });
    const odd_marked: TestModule = .{ .name = "odd", .source =
        \\import even
        \\
        \\private func check(value: long) -> bool:
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
        \\        state: long
        \\
        \\    func next(var self) -> long:
        \\        self.state = self.state * 48271 % 2147483647
        \\        return self.state
        \\
        \\func rng(seed: long) -> Rng:
        \\    return Rng(state = seed)
        \\
    };
    const marker: TestModule = .{ .name = "rng", .source =
        \\struct Rng:
        \\    private state: long
        \\
        \\    func next(var self) -> long:
        \\        self.state = self.state * 48271 % 2147483647
        \\        return self.state
        \\
        \\func rng(seed: long) -> Rng:
        \\    return Rng(state = seed)
        \\
    };
    const stealing =
        \\import rng
        \\
        \\func main():
        \\    var r = rng.Rng(state = 42)
        \\    print(string(r.next()))
        \\
    ;
    const using =
        \\import rng
        \\
        \\func main():
        \\    var r = rng.rng(42)
        \\    print(string(r.next()))
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
    // (`luce.sema.import`, 04_semantics/builder.zig) has no input that
    // reaches it — every dotted call is parsed as a method and
    // resolved on the other path, which the next test covers.
    const constant_module: TestModule = .{ .name = "sizes", .source =
        \\let width = 80
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
        \\    x: long
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
        \\func helper() -> long:
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
        .{ .name = "geo", .source = "func area() -> long:\n    return \x00\n" },
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
        .{ .name = "geo", .source = "import geo\n\nfunc area() -> long:\n    return 4\n" },
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
        .{ .name = "math", .source = "func answer() -> long:\n    return 42\n" },
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
        .{ .name = "math", .source = "func answer() -> long:\n    return 42\n" },
        .{ .name = "user", .source = "import math\n\nfunc go() -> long:\n    return math.answer()\n" },
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
        \\func area() -> long:
        \\    return "not an int"
        \\
        },
    } };
    var result = try compile_mod.compileProject(testing.allocator,
        \\import geo
        \\import std.math
        \\
        \\func main():
        \\    let bad: long = geo.area()
        \\    let worse: long = math.pi
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
        .{ .name = "a", .source = "import b\n\nfunc step(v: long) -> long:\n    if v == 0:\n        return 0\n    return b.step(v - 1)\n" },
        .{ .name = "b", .source = "import c\n\nfunc step(v: long) -> long:\n    return c.step(v)\n" },
        .{ .name = "c", .source = "import a\n\nfunc step(v: long) -> long:\n    return a.step(v)\n" },
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
        \\    print(string(a.width))
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

test "constants are compile-time: calls, objects, and verbs are refused" {
    try failsWith(
        \\func answer() -> long:
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
        \\    items: list(long)
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
        \\let broken = 1 // 0
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
        \\func twice() -> long:
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
    // The annotation is checked, and it is the *landing type*: `3`
    // has no type of its own and becomes a double here (docs/TYPES.md
    // D3), so what this proves is the direction that stays refused —
    // a float value does not land on an integer annotation, because
    // narrowing is never implicit.
    try failsWith(
        \\let wrong: long = 3.5
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.type");
    try failsWith(
        \\let wrong: bool = 3
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
    // (r8 feeds the read and the store), which is the "evaluated
    // once" guarantee in instruction form.
    var program = try expectCompilesOptions(
        \\func main():
        \\    var counts = new map(string, long)
        \\    counts["a"] = 7
        \\    counts["b"] += 1
        \\
    , .{});
    defer program.deinit();
    const dump = try mir.print(testing.allocator, &program);
    defer testing.allocator.free(dump);
    try testing.expectEqualStrings(
        \\func main() -> None
        \\    local %0 (temporary): map(string, long)
        \\    local %1 counts: map(string, long)
        \\  b0:
        \\    r0 = heap_new map(string, long)
        \\    local_set %1, r0
        \\    object_bind %1, r0
        \\    r3 = local_get %1
        \\    r4 = const data#0
        \\    r5 = const 7
        \\    intrinsic index_set, r3, r4, r5
        \\    r7 = local_get %1
        \\    r8 = const data#1
        \\    r9 = const 1
        \\    r10 = const 0
        \\    r11 = intrinsic map_place, r7, r8, r10
        \\    r12 = add.long r11, r9
        \\    intrinsic index_set, r7, r8, r12
        \\    r14 = local_get %1
        \\    object_unbind %1, r14
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
        \\    counts: map(string, long)
        \\
        \\func main():
        \\    var t = Tally(counts = new map(string, long))
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
        \\    var grid = new array(long, 2, 2)
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
