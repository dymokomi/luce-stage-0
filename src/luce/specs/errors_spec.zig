//! Compile-error suite for the Luce language.
//!
//! Zig's test/cases/compile_errors pins every rejection path with an
//! expected error; this is our analog, while the language is still
//! small enough to cover exhaustively.  Each case is a program that
//! must NOT compile, asserted by its stable diagnostic code (and, for
//! the cases where the span is the point, its line:column).  Codes are
//! the contract editors read, so a rejection silently changing code —
//! or a check being refactored away — fails a test here.
//!
//! Organized by diagnostic code.  Behavioral correctness lives in
//! behavior_spec.zig; ownership rejections (luce.sema.own) live in
//! ownership_spec.zig, which already covers them per situation.
//!
//! This is the one spec that runs nothing: a program the compiler
//! refuses never reaches an engine, so there is no second arm and
//! nothing for two engines to disagree about.

const std = @import("std");
const luce = @import("luce");

const compile_mod = luce.compile;
const types = luce.types;
const source_mod = luce.source;
const semantics = luce.semantics;

const testing = std.testing;

const script: types.CompileOptions = .{};
const hosted: types.CompileOptions = .{ .allow_host = true };

const Diagnostics = luce.diagnostics.Diagnostics;

fn printAll(diagnostics: *const Diagnostics) void {
    const rendered = diagnostics.render(testing.allocator) catch return;
    defer testing.allocator.free(rendered);
    std.debug.print("got:\n{s}", .{rendered});
}

/// Compile `source` with no host and assert it fails with a
/// diagnostic carrying `code` somewhere in the list.  The everyday
/// rejection assertion.
fn expectRejected(source: []const u8, code: []const u8) !void {
    try expectRejectedOptions(source, script, code);
}

fn expectRejectedOptions(
    source: []const u8,
    options: types.CompileOptions,
    code: []const u8,
) !void {
    var result = try compile_mod.compile(testing.allocator, source, options);
    defer result.deinit();
    switch (result) {
        .success => {
            std.debug.print("expected {s}, but this compiled:\n{s}", .{ code, source });
            return error.TestUnexpectedResult;
        },
        .failure => |diagnostics| {
            for (0..diagnostics.count()) |index| {
                if (std.mem.eql(u8, diagnostics.at(index).?.code, code)) return;
            }
            const rendered = try diagnostics.render(testing.allocator);
            defer testing.allocator.free(rendered);
            std.debug.print("wanted {s}, got:\n{s}", .{ code, rendered });
            return error.TestUnexpectedResult;
        },
    }
}

/// Compile and assert a diagnostic carrying `code` **and saying
/// `saying`**.
///
/// The everyday assertion above names a code, and a code is not a
/// check: `luce.sema.type` is emitted from thirty-nine places and
/// `luce.sema.let` from four, so a test that names only the code goes
/// on passing while three of those four checks are deleted.  The words
/// are what identify the site, so where a code has more than one
/// emission point this is the assertion to use.
fn expectSaying(source: []const u8, code: []const u8, saying: []const u8) !void {
    return expectSayingOptions(source, script, code, saying);
}

fn expectHostSaying(source: []const u8, code: []const u8, saying: []const u8) !void {
    return expectSayingOptions(source, hosted, code, saying);
}

fn expectSayingOptions(
    source: []const u8,
    options: types.CompileOptions,
    code: []const u8,
    saying: []const u8,
) !void {
    var result = try compile_mod.compile(testing.allocator, source, options);
    defer result.deinit();
    switch (result) {
        .success => {
            std.debug.print("expected {s}, but this compiled:\n{s}", .{ code, source });
            return error.TestUnexpectedResult;
        },
        .failure => |diagnostics| {
            for (0..diagnostics.count()) |index| {
                const found = diagnostics.at(index).?;
                if (!std.mem.eql(u8, found.code, code)) continue;
                if (std.mem.indexOf(u8, found.message, saying) != null) return;
            }
            const rendered = try diagnostics.render(testing.allocator);
            defer testing.allocator.free(rendered);
            std.debug.print("wanted {s} saying \"{s}\", got:\n{s}", .{ code, saying, rendered });
            return error.TestUnexpectedResult;
        },
    }
}

/// Assert the FIRST diagnostic is exactly `code` at `line`:`column`.
/// Used where the span itself is the guarantee under test.
fn expectRejectedAt(source: []const u8, code: []const u8, line: usize, column: usize) !void {
    var result = try compile_mod.compile(testing.allocator, source, script);
    defer result.deinit();
    switch (result) {
        .success => return error.TestUnexpectedResult,
        .failure => |diagnostics| {
            const first = diagnostics.at(0) orelse return error.TestUnexpectedResult;
            errdefer printAll(&diagnostics);
            try testing.expectEqualStrings(code, first.code);
            const at = source_mod.place(source, first.span.start);
            try testing.expectEqual(line, at.line);
            try testing.expectEqual(column, at.column);
        },
    }
}

/// Assert the FIRST diagnostic is exactly `code`, says `saying`, and
/// starts at `line`:`column`.
///
/// The three assertions above, taken one at a time, each leave a way
/// for a diagnostic to rot: a code says which family, the words say
/// which check, and the span says what the reader will actually see
/// underlined.  A message can be rewritten while the caret drifts off
/// the thing it names, and nothing built from the weaker helpers
/// notices.  Where a diagnostic's whole job is to point at one
/// argument and say what is wrong with it, all three are the contract.
fn expectSayingAt(
    source: []const u8,
    code: []const u8,
    saying: []const u8,
    line: usize,
    column: usize,
) !void {
    return expectSayingAtOptions(source, script, code, saying, line, column);
}

fn expectHostSayingAt(
    source: []const u8,
    code: []const u8,
    saying: []const u8,
    line: usize,
    column: usize,
) !void {
    return expectSayingAtOptions(source, hosted, code, saying, line, column);
}

fn expectSayingAtOptions(
    source: []const u8,
    options: types.CompileOptions,
    code: []const u8,
    saying: []const u8,
    line: usize,
    column: usize,
) !void {
    var result = try compile_mod.compile(testing.allocator, source, options);
    defer result.deinit();
    switch (result) {
        .success => {
            std.debug.print("expected {s}, but this compiled:\n{s}", .{ code, source });
            return error.TestUnexpectedResult;
        },
        .failure => |diagnostics| {
            const first = diagnostics.at(0) orelse return error.TestUnexpectedResult;
            errdefer printAll(&diagnostics);
            try testing.expectEqualStrings(code, first.code);
            try testing.expectEqualStrings(saying, first.message);
            const at = source_mod.place(source, first.span.start);
            try testing.expectEqual(line, at.line);
            try testing.expectEqual(column, at.column);
        },
    }
}

/// `expectSayingAt`, plus: this is the *only* diagnostic the program
/// produced.
///
/// One mistake, one report is a house rule, and it is a property no
/// assertion about the first diagnostic can see.  Where a check used
/// to fire once per subsequent line, or once per member of a cycle,
/// the count is the thing that regressed and the count is what has to
/// be pinned.
fn expectOnlySayingAt(
    source: []const u8,
    code: []const u8,
    saying: []const u8,
    line: usize,
    column: usize,
) !void {
    var result = try compile_mod.compile(testing.allocator, source, script);
    defer result.deinit();
    switch (result) {
        .success => {
            std.debug.print("expected {s}, but this compiled:\n{s}", .{ code, source });
            return error.TestUnexpectedResult;
        },
        .failure => |diagnostics| {
            const first = diagnostics.at(0) orelse return error.TestUnexpectedResult;
            errdefer printAll(&diagnostics);
            try testing.expectEqualStrings(code, first.code);
            try testing.expectEqualStrings(saying, first.message);
            const at = source_mod.place(source, first.span.start);
            try testing.expectEqual(line, at.line);
            try testing.expectEqual(column, at.column);
            try testing.expectEqual(@as(usize, 1), diagnostics.count());
        },
    }
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------
//
// What a *file* can be wrong about, decided before it is ever lexed
// (01_source/encoding.zig).  These rejections name the file rather
// than a line, because the file never became source.

test "luce.source.utf8: a file that is not valid UTF-8 is refused" {
    try expectRejected("func main():\n    let a = \"\xff\xfe\"\n", "luce.source.utf8");
    // Anywhere, not only in a string.
    try expectRejected("func m\xffain():\n    return\n", "luce.source.utf8");
}

test "luce.source.binary: a NUL byte means this is not a text file" {
    try expectRejected("func main():\n    let a = 1\x00\n", "luce.source.binary");
}

test "luce.source.line_ending: a stray carriage return is refused" {
    try expectRejected("func main():\r    return\n", "luce.source.line_ending");
}

test "CRLF line endings compile, and keep every line and column" {
    // A Windows-edited file must behave exactly like any other,
    // blank lines inside a block included — collapsing CRLF at load
    // is what makes the layout rules see the same text.
    var result = try compile_mod.compile(
        testing.allocator,
        "func main():\r\n    let a = 1\r\n\r\n    let b = a\r\n    let c: String = b\r\n",
        script,
    );
    defer result.deinit();
    try testing.expect(result == .failure);
    const first = result.failure.at(0).?;
    try testing.expectEqualStrings("luce.sema.type", first.code);
    const at = result.failure.sources.place(first.file, first.span.start);
    try testing.expectEqual(@as(usize, 5), at.line);
}

test "a byte-order mark is not a syntax error" {
    var result = try compile_mod.compile(
        testing.allocator,
        "\xEF\xBB\xBFfunc main():\n    return\n",
        script,
    );
    defer result.deinit();
    try testing.expect(result == .success);
}

// ---------------------------------------------------------------------------
// Lexer
// ---------------------------------------------------------------------------

test "luce.lex.tab: tabs are rejected as indentation" {
    try expectRejected("func main():\n\tlet a = 1\n", "luce.lex.tab");
}

test "luce.lex.number: a digit run glued to letters is one bad literal" {
    try expectRejected("func main():\n    let a = 12ab\n", "luce.lex.number");
}

test "luce.lex.string: an unterminated string is caught" {
    try expectRejected("func main():\n    let a = \"open\n", "luce.lex.string");
}

test "luce.lex.escape: an unknown escape is rejected" {
    try expectRejected("func main():\n    let a = \"\\q\"\n", "luce.lex.escape");
}

test "luce.lex.character: a stray control byte is rejected" {
    try expectRejected("func main():\n    let a = 1\x01\n", "luce.lex.character");
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

test "luce.lex.string: an unterminated f-string is caught" {
    try expectRejected("func main():\n    let a = f\"open {x}\n", "luce.lex.string");
}

test "luce.parse.fstring: a malformed or unmatched hole is rejected" {
    // A hole that does not lex.
    try expectRejected("func main():\n    let a = f\"{@}\"\n", "luce.parse.fstring");
    // Two expressions where one is expected.
    try expectRejected("func main():\n    let a = f\"{1 2}\"\n", "luce.parse.fstring");
    // A bare close brace without doubling.
    try expectRejected("func main():\n    let a = f\"lone }\"\n", "luce.parse.fstring");
}

test "luce.parse.expression: a broken f-string hole reports the sub-parse error" {
    try expectRejected("func main():\n    let a = f\"{1 +}\"\n", "luce.parse.expression");
}

test "luce.sema.type: an f-string hole must be str-able" {
    // A List has no str(); interpolation rejects it.
    try expectRejected(
        \\func main():
        \\    var xs = [1, 2]
        \\    let a = f"{xs}"
        \\
    , "luce.sema.type");
}

test "luce.parse.top: only func/struct/let/import at file scope" {
    try expectRejected("fn main():\n    return\n", "luce.parse.top");
    try expectRejected("var counter = 0\n", "luce.parse.top");
}

test "luce.parse.expression: a missing expression is reported" {
    try expectRejected("func main():\n    let a = @\n", "luce.parse.expression");
}

test "luce.parse.expected: a malformed binding name is reported at the name" {
    try expectRejectedAt("let 3 = 4\n", "luce.parse.expected", 1, 5);
}

test "luce.parse.precedence: 'not' in front of a comparison must be parenthesized" {
    // Two languages Luce reads like disagree about what this means and
    // both readings are legal Bool expressions, so the parser refuses
    // to pick (docs/LANGUAGE.md).  Either pair of parentheses settles
    // it, and each spelling then means what it says.
    try expectRejectedAt(
        "func main():\n    let a = true\n    let b = false\n    let c = not a == b\n",
        "luce.parse.precedence",
        4,
        13,
    );
    for ([_][]const u8{ "!=", "<", "<=", ">", ">=" }) |operator| {
        const source = try std.fmt.allocPrint(
            testing.allocator,
            "func main():\n    let c = not a {s} b\n",
            .{operator},
        );
        defer testing.allocator.free(source);
        try expectRejected(source, "luce.parse.precedence");
    }
}

test "luce.parse.chain: comparison operators do not chain" {
    try expectRejectedAt(
        "func main():\n    let a = 1\n    let c = 0 < a < 10\n",
        "luce.parse.chain",
        3,
        19,
    );
    // The whole precedence level is non-associative, not just a
    // repeated operator.
    try expectRejected("func main():\n    let c = 1 < 2 == 3\n", "luce.parse.chain");
    // Parentheses start a new chain, so comparing two Bools is legal
    // and reaches the type checker unharmed.
    var result = try compile_mod.compile(
        testing.allocator,
        "func main():\n    let a = 1\n    let c = (0 < a) == (a < 10)\n    print(str(c))\n",
        .{ .allow_host = true },
    );
    defer result.deinit();
    if (result == .failure) printAll(&result.failure);
    try testing.expect(result == .success);
}

test "luce.parse.nesting: pathological nesting is rejected, not overflowed" {
    const allocator = testing.allocator;
    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(allocator);
    try deep.appendSlice(allocator, "func main():\n    let x = ");
    for (0..2000) |_| try deep.append(allocator, '(');
    try deep.append(allocator, '1');
    try expectRejected(deep.items, "luce.parse.nesting");
}

// ---------------------------------------------------------------------------
// Entry contract
// ---------------------------------------------------------------------------

test "luce.sema.main: a script needs exactly func main()" {
    try expectRejected("func other():\n    return\n", "luce.sema.main");
    try expectRejected("func main(x: Int):\n    return\n", "luce.sema.main");
}

// ---------------------------------------------------------------------------
// Compound assignment (value-only arithmetic sugar)
// ---------------------------------------------------------------------------

test "luce.sema.type: compound assignment is numbers, or += on String" {
    // Objects have no compound assignment.
    try expectRejected("func main():\n    var xs = [1, 2]\n    xs *= 3\n", "luce.sema.type");
    // Non-+ operators do not apply to String.
    try expectRejected("func main():\n    var s = \"a\"\n    s -= \"b\"\n", "luce.sema.type");
    // The two sides must share a type.
    try expectRejected("func main():\n    var n = 1\n    n += 2.0\n", "luce.sema.type");
}

test "luce.sema.let: a let binding cannot be compound-assigned either" {
    try expectRejected("func main():\n    let n = 1\n    n += 1\n", "luce.sema.let");
}

// ---------------------------------------------------------------------------
// Names, declarations, reserved words
// ---------------------------------------------------------------------------

test "luce.sema.name: an unknown name is rejected" {
    try expectRejected("func main():\n    let a = ghost\n", "luce.sema.name");
}

// A name in value position that names a *declaration* is not unknown.
// Luce has no function values, so these are all mistakes — but the
// compiler checked the declaration moments earlier, and answering
// "unknown name math" about an import on line 1 sends the reader to
// look for a missing import that is right there.  Every one of these
// used to do exactly that.

test "luce.sema.name: a function used as a value is named, not denied" {
    try expectOnlySayingAt(
        \\func helper() -> Int:
        \\    return 1
        \\
        \\func main():
        \\    let f = helper
        \\
    ,
        "luce.sema.name",
        "helper is a function, and Luce has no function values; write helper(...) to call it",
        5,
        13,
    );
}

test "luce.sema.name: a struct used as a value says how to build one" {
    try expectOnlySayingAt(
        \\struct Point:
        \\    x: Int
        \\
        \\func main():
        \\    let p = Point
        \\
    ,
        "luce.sema.name",
        "Point is a struct, not a value; write Point(field = ...) to build one",
        5,
        13,
    );
}

test "luce.sema.name: a std function reached without a call keeps its namespace" {
    try expectOnlySayingAt(
        \\import std.math
        \\
        \\func main():
        \\    let x = math.round
        \\
    ,
        "luce.sema.name",
        "math.round is a function, and Luce has no function values; write math.round(...) to call it",
        4,
        13,
    );
}

test "luce.sema.name: a missing namespace member offers one of that namespace" {
    try expectOnlySayingAt(
        \\import std.math
        \\
        \\func main():
        \\    let x = math.rond
        \\
    ,
        "luce.sema.name",
        "math has no member rond; did you mean math.round?",
        4,
        13,
    );
}

test "luce.sema.name: a struct namespace answers for its own members" {
    try expectOnlySayingAt(
        \\struct Words:
        \\    count: Int
        \\
        \\    func classify() -> Int:
        \\        return 1
        \\
        \\func main():
        \\    let f = Words.classify
        \\
    ,
        "luce.sema.name",
        "Words.classify is a function, and Luce has no function values; write Words.classify(...) to call it",
        8,
        13,
    );
}

test "luce.sema.name: a struct namespace with no such member says so" {
    try expectOnlySayingAt(
        \\struct Words:
        \\    count: Int
        \\
        \\    func classify() -> Int:
        \\        return 1
        \\
        \\func main():
        \\    let f = Words.nope
        \\
    ,
        "luce.sema.name",
        "Words has no member nope",
        8,
        13,
    );
}

test "luce.sema.duplicate: a name cannot be declared twice" {
    try expectRejected("func main():\n    let a = 1\n    let a = 2\n", "luce.sema.duplicate");
}

test "luce.sema.reserved: builtins cannot be shadowed" {
    try expectRejected("func main():\n    let len = 1\n", "luce.sema.reserved");
}

test "luce.sema.let: a let binding cannot be reassigned" {
    try expectRejected("func main():\n    let a = 1\n    a = 2\n", "luce.sema.let");
}

// ---------------------------------------------------------------------------
// Types and conversions
// ---------------------------------------------------------------------------

test "luce.sema.type: no implicit numeric conversion" {
    try expectRejected("func main():\n    let a = 1 + 2.0\n", "luce.sema.type");
}

test "luce.sema.type: a condition must be Bool" {
    try expectRejected("func main():\n    if 1:\n        return\n", "luce.sema.type");
}

test "luce.sema.type: an annotation must match the initializer" {
    try expectRejected("func main():\n    let a: Int = \"x\"\n", "luce.sema.type");
}

test "luce.sema.convert: Int and Float convert only their opposite" {
    try expectRejected("func main():\n    let a = Int(\"x\")\n", "luce.sema.convert");
    try expectRejected("func main():\n    let a = Float(true)\n", "luce.sema.convert");
}

// ---------------------------------------------------------------------------
// Fields, calls, methods, indexing
// ---------------------------------------------------------------------------

test "luce.sema.field: an unknown struct field is rejected" {
    try expectRejected(
        \\struct P:
        \\    x: Int
        \\
        \\func main():
        \\    let p = P(x = 1)
        \\    let y = p.y
        \\
    , "luce.sema.field");
}

test "luce.sema.call: arity and unknown callees are checked" {
    try expectRejected(
        \\func add(a: Int, b: Int) -> Int:
        \\    return a + b
        \\
        \\func main():
        \\    let x = add(1)
        \\
    , "luce.sema.call");
    try expectRejected("func main():\n    let x = nope(1)\n", "luce.sema.call");
}

test "luce.sema.method: a method must exist on its receiver type" {
    try expectRejected("func main():\n    let a = 5.append(1)\n", "luce.sema.method");
}

test "luce.sema.method: map get takes (key, default) of the right types" {
    // Too few is a count mistake and says both counts.
    try expectSayingAt(
        \\func main():
        \\    var m = new Map(String, Int)
        \\    let x = m.get("k")
        \\
    , "luce.sema.method", "get takes 2 arguments, got 1", 3, 13);
    // The wrong type in the second slot is a *type* mistake, and is
    // reported as one, at the argument rather than at the call.
    try expectSayingAt(
        \\func main():
        \\    var m = new Map(String, Int)
        \\    let x = m.get("k", "wrong")
        \\
    , "luce.sema.type", "argument 2 of get is Int, got String", 3, 24);
}

test "luce.sema.loop: two-name for needs a Map or a sequence" {
    // A Builder is not iterable at all.
    try expectRejected(
        \\func main():
        \\    var b = new Builder()
        \\    for a, c in b:
        \\        b.append("x")
        \\
    , "luce.sema.loop");
}

test "luce.sema.duplicate: the two for-loop names must differ" {
    try expectRejected(
        \\func main():
        \\    var m = new Map(Int, Int)
        \\    m[1] = 1
        \\    for k, k in m:
        \\        let unused = k
        \\
    , "luce.sema.duplicate");
}

test "luce.sema.index: only heap containers index, with the right key" {
    try expectRejected("func main():\n    let a = 1[0]\n", "luce.sema.index");
}

// ---------------------------------------------------------------------------
// Construction, new, loops, returns
// ---------------------------------------------------------------------------

test "luce.sema.construct: a struct needs all fields, named, once" {
    try expectRejected(
        \\struct P:
        \\    x: Int
        \\    y: Int
        \\
        \\func main():
        \\    let p = P(x = 1)
        \\
    , "luce.sema.construct");
}

// Every hole at once.  Reporting the first made a fourteen-field
// struct take thirteen compile rounds to finish, one field revealed
// per round — the whole set is known where the message is written.

test "luce.sema.construct: one missing field is named in the singular" {
    try expectOnlySayingAt(
        \\struct P:
        \\    a: Int
        \\    b: Int
        \\
        \\func main():
        \\    let p = P(a = 1)
        \\
    , "luce.sema.construct", "P is missing field b", 6, 13);
}

test "luce.sema.construct: two missing fields take no serial comma" {
    try expectOnlySayingAt(
        \\struct P:
        \\    a: Int
        \\    b: Int
        \\    c: Int
        \\
        \\func main():
        \\    let p = P(a = 1)
        \\
    , "luce.sema.construct", "P is missing fields b and c", 7, 13);
}

test "luce.sema.construct: every missing field is named, in declaration order" {
    try expectOnlySayingAt(
        \\struct P:
        \\    a: Int
        \\    b: Int
        \\    c: Int
        \\    d: Int
        \\
        \\func main():
        \\    let p = P(b = 1)
        \\
    , "luce.sema.construct", "P is missing fields a, c, and d", 8, 13);
}

test "luce.sema.const: a folded constant says the same thing as a body" {
    // Same sentence from the other pass: a reader must not meet
    // different words for the same mistake at file scope (context.zig).
    try expectOnlySayingAt(
        \\struct P:
        \\    a: Int
        \\    b: Int
        \\    c: Int
        \\
        \\let origin = P(a = 1)
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.const", "P is missing fields b and c", 6, 14);
}

test "luce.sema.new: new builds only the heap types" {
    try expectRejected("func main():\n    let a = new Array(Int)\n", "luce.sema.new");
}

test "luce.sema.loop: break and continue need a loop" {
    try expectRejected("func main():\n    break\n", "luce.sema.loop");
}

test "luce.sema.return: return paths and value shape are checked" {
    try expectRejected(
        \\func f() -> Int:
        \\    let x = 1
        \\
        \\func main():
        \\    let y = f()
        \\
    , "luce.sema.return");
}

// ---------------------------------------------------------------------------
// Structs, constants, host gate
// ---------------------------------------------------------------------------

test "luce.sema.struct: a struct cannot be empty or self-containing" {
    try expectRejected(
        \\struct Loop:
        \\    inner: Loop
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.struct");
}

// A containment cycle is one mistake with one fix, however many
// structs it runs through.  It used to be reported once per struct on
// the loop, each saying "struct X contains itself" — which is false of
// every member of a mutual cycle, names neither the other struct nor
// the field that closes it, and puts the caret on the `struct` keyword
// rather than the line that gets edited.

test "luce.sema.struct: a direct cycle names the field and the fix" {
    try expectOnlySayingAt(
        \\struct Node:
        \\    value: Int
        \\    next: Node
        \\
        \\func main():
        \\    return
        \\
    ,
        "luce.sema.struct",
        "struct Node contains itself: Node.next is Node; a struct is a value, " ++
            "so write next: Node? to let the chain end at absence",
        3,
        5,
    );
}

test "luce.sema.struct: a mutual cycle is one message that walks the loop" {
    try expectOnlySayingAt(
        \\struct A:
        \\    b: B
        \\
        \\struct B:
        \\    a: A
        \\
        \\func main():
        \\    return
        \\
    ,
        "luce.sema.struct",
        "struct A contains itself: A.b is B, and B.a is A; a struct is a value, " ++
            "so write b: B? to let the chain end at absence",
        2,
        5,
    );
}

test "luce.sema.struct: a three-struct cycle reads the whole way round" {
    try expectOnlySayingAt(
        \\struct A:
        \\    n: Int
        \\    b: B
        \\
        \\struct B:
        \\    c: C
        \\
        \\struct C:
        \\    a: A
        \\
        \\func main():
        \\    return
        \\
    ,
        "luce.sema.struct",
        "struct A contains itself: A.b is B, B.c is C, and C.a is A; a struct is a value, " ++
            "so write b: B? to let the chain end at absence",
        3,
        5,
    );
}

test "luce.sema.struct: two independent cycles are two mistakes" {
    var result = try compile_mod.compile(testing.allocator,
        \\struct A:
        \\    b: B
        \\
        \\struct B:
        \\    a: A
        \\
        \\struct C:
        \\    d: D
        \\
        \\struct D:
        \\    c: C
        \\
        \\func main():
        \\    return
        \\
    , script);
    defer result.deinit();
    const diagnostics = result.failure;
    errdefer printAll(&diagnostics);
    try testing.expectEqual(@as(usize, 2), diagnostics.count());
    try testing.expect(std.mem.startsWith(u8, diagnostics.at(0).?.message, "struct A contains itself"));
    try testing.expect(std.mem.startsWith(u8, diagnostics.at(1).?.message, "struct C contains itself"));
}

test "luce.sema.struct: the fix the cycle diagnostic names actually compiles" {
    // The one thing worse than a message that does not help is a
    // message whose suggested edit does not work.  This is that
    // suggestion, compiled.
    var result = try compile_mod.compile(testing.allocator,
        \\struct Node:
        \\    value: Int
        \\    next: Node?
        \\
        \\func main():
        \\    let tail = Node(value = 2, next = none)
        \\    let head = Node(value = 1, next = tail)
        \\    let rest = head.next
        \\    if rest != none:
        \\        let seen = rest.value
        \\
    , script);
    defer result.deinit();
    switch (result) {
        .success => {},
        .failure => |diagnostics| {
            printAll(&diagnostics);
            return error.TestUnexpectedResult;
        },
    }
}

test "luce.sema.const: a top-level let is a constant, not a computation" {
    try expectRejected("let bad = new List(Int)\n\nfunc main():\n    return\n", "luce.sema.const");
}

test "luce.sema.host: host builtins are gated off by default" {
    try expectRejected("func main():\n    print(\"hi\")\n", "luce.sema.host");
}

// ===========================================================================
// The exhaustive suite below extends the seed above, aiming for one case
// per genuinely distinct rejection path (Zig's test/cases/compile_errors
// analog).  The high-fanout codes — sema.type, sema.call, sema.method,
// sema.construct, sema.index, sema.return — get many cases; the lexer and a
// few common sema codes are additionally pinned to a line:column.
// ===========================================================================

/// For a program that reaches the host: every file builtin does, and
/// so does the standard `files` module.
fn expectHostError(source: []const u8, code: []const u8) !void {
    try expectRejectedOptions(source, hosted, code);
}

// ---------------------------------------------------------------------------
// Lexer — pinned spans (the span is the product for an editor)
// ---------------------------------------------------------------------------

test "luce.lex.tab: a tab in indentation is pinned to its column" {
    try expectRejectedAt("func main():\n\tlet a = 1\n", "luce.lex.tab", 2, 1);
}

test "luce.lex.tab: a tab mid-line is also rejected" {
    try expectRejectedAt("func main():\n    let a =\t1\n", "luce.lex.tab", 2, 12);
}

test "luce.lex.indent: a dedent to no open column is rejected" {
    try expectRejectedAt(
        "func main():\n    if 1 < 2:\n        let a = 1\n     let b = 2\n",
        "luce.lex.indent",
        4,
        1,
    );
}

test "luce.lex.number: a malformed literal is pinned to its start" {
    try expectRejectedAt("func main():\n    let a = 12ab\n", "luce.lex.number", 2, 13);
}

test "luce.lex.string: an unterminated string is pinned to its opening quote" {
    try expectRejectedAt("func main():\n    let a = \"open\n", "luce.lex.string", 2, 13);
}

test "luce.lex.escape: an unknown escape is pinned to the backslash" {
    try expectRejectedAt("func main():\n    let a = \"\\q\"\n", "luce.lex.escape", 2, 14);
}

test "luce.parse.expression: '!' is not an operator, in either position" {
    // `not` binds tighter than a comparison, so `not a == 1` is
    // `(not a) == 1` and refused at the parser rather than left to
    // become a type error (docs/LANGUAGE.md); parenthesized, the same
    // spelling reaches the type checker it always did.
    try expectRejected("func main():\n    let a = 1\n    if not a == 1:\n        return\n", "luce.parse.precedence");
    try expectRejected("func main():\n    let a = 1\n    if (not a) == 1:\n        return\n", "luce.sema.type");
    // `!` lexes now — it is the fallibility mark on a return type —
    // so the hint toward `not` moved to the parser with it.
    try expectRejected("func main():\n    let a = 3 ! 4\n", "luce.parse.expression");
}

test "luce.lex.character: an unexpected symbol is rejected" {
    try expectRejected("func main():\n    let a = 1 $ 2\n", "luce.lex.character");
}

test "luce.lex.character: a stray control byte is pinned" {
    try expectRejectedAt("func main():\n    let a = 1\x01\n", "luce.lex.character", 2, 14);
}

// ---------------------------------------------------------------------------
// Parser — more paths
// ---------------------------------------------------------------------------

test "luce.parse.top: a bare expression at file scope is rejected" {
    try expectRejected("1 + 1\n", "luce.parse.top");
}

test "luce.parse.top: a top-level var is rejected with guidance" {
    try expectRejectedAt("var counter = 0\n", "luce.parse.top", 1, 1);
}

test "luce.parse.expected: a function needs a name" {
    try expectRejected("func ():\n    return\n", "luce.parse.expected");
}

test "luce.parse.expected: a struct field needs a type after its colon" {
    try expectRejected("struct P:\n    x:\n\nfunc main():\n    return\n", "luce.parse.expected");
}

test "luce.parse.type: array shape wildcards must come last" {
    try expectRejected(
        "func f(a: Array(Int, _, Int)):\n    return\n\nfunc main():\n    return\n",
        "luce.parse.type",
    );
}

test "luce.parse.assign: cannot assign to a literal" {
    try expectRejected("func main():\n    1 = 2\n", "luce.parse.assign");
}

test "luce.parse.assign: cannot assign through a call result" {
    // Nested field/index places are allowed now; a call in the place
    // chain is not a place.
    try expectRejected("func main():\n    f().x = 1\n", "luce.parse.assign");
}

test "luce.sema.field: a nested place checks each field on the way down" {
    try expectRejected(
        \\struct Inner:
        \\    n: Int
        \\
        \\struct Outer:
        \\    inner: Inner
        \\
        \\func main():
        \\    var o = Outer(inner = Inner(n = 1))
        \\    o.inner.ghost = 2
        \\
    , "luce.sema.field");
}

test "luce.sema.own: a nested place cannot assign an object slot" {
    // The single-level form (bag.items = [1, 2]) is the way to
    // restock an object field; a chain leaf must be a value.
    try expectRejected(
        \\struct Bag:
        \\    items: List(Int)
        \\
        \\struct Holder:
        \\    bag: Bag
        \\
        \\func main():
        \\    var h = Holder(bag = Bag(items = [1]))
        \\    h.bag.items = [2, 3]
        \\
    , "luce.sema.own");
}

test "luce.sema.own: cannot index into object-carrying elements in a chain" {
    try expectRejected(
        \\struct Bag:
        \\    label: String
        \\    items: List(Int)
        \\
        \\func main():
        \\    var bags = new List(Bag)
        \\    bags.append(Bag(label = "a", items = [1]))
        \\    bags[0].label = "b"
        \\
    , "luce.sema.own");
}

test "luce.parse.new: new builds only the four heap types" {
    try expectRejected("func main():\n    let a = new Point()\n", "luce.parse.new");
}

// ---------------------------------------------------------------------------
// Names, declarations, reserved words — more paths
// ---------------------------------------------------------------------------

test "luce.sema.name: input is not a name in a script" {
    try expectRejected("func main():\n    let a = input\n", "luce.sema.name");
}

test "luce.sema.name: give needs a name that exists" {
    try expectRejected("func main():\n    let a = give ghost\n", "luce.sema.name");
}

test "luce.sema.duplicate: a struct cannot be declared twice" {
    try expectRejected(
        \\struct P:
        \\    x: Int
        \\
        \\struct P:
        \\    y: Int
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.duplicate");
}

test "luce.sema.duplicate: a struct cannot repeat a field" {
    try expectRejected(
        \\struct P:
        \\    x: Int
        \\    x: Int
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.duplicate");
}

test "luce.sema.duplicate: a function cannot be declared twice" {
    try expectRejected(
        \\func f():
        \\    return
        \\
        \\func f():
        \\    return
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.duplicate");
}

test "luce.sema.reserved: a function cannot take a builtin's name" {
    try expectRejected("func print():\n    return\n\nfunc main():\n    return\n", "luce.sema.reserved");
}

test "luce.sema.reserved: a struct cannot take a type keyword's name" {
    try expectRejected("struct Int:\n    x: Int\n\nfunc main():\n    return\n", "luce.sema.reserved");
}

test "luce.sema.reserved: a function cannot take a terminal service's name" {
    // The seven `term_*` builtins were dispatched and not reserved, so
    // this program compiled and the declaration stood in front of the
    // builtin.  One per shape: no arguments, some arguments, and the
    // one whose name a program is most likely to reach for.
    try expectRejected(
        "func term_rows() -> Int:\n    return 1\n\nfunc main():\n    return\n",
        "luce.sema.reserved",
    );
    try expectRejected(
        "func term_write(text: String):\n    return\n\nfunc main():\n    return\n",
        "luce.sema.reserved",
    );
    try expectRejected(
        "func term_clear():\n    return\n\nfunc main():\n    return\n",
        "luce.sema.reserved",
    );
}

test "luce.sema.reserved: a local cannot take a terminal service's name" {
    try expectRejected("func main():\n    let term_cols = 1\n", "luce.sema.reserved");
}

test "luce.sema.reserved: a struct cannot take a terminal service's name" {
    try expectRejected(
        "struct term_style:\n    x: Int\n\nfunc main():\n    return\n",
        "luce.sema.reserved",
    );
}

// ---------------------------------------------------------------------------
// luce.sema.type — the biggest fan-out, distinct paths
// ---------------------------------------------------------------------------

test "luce.sema.type: a wrong argument type is rejected" {
    try expectRejected(
        \\func f(a: Int):
        \\    return
        \\
        \\func main():
        \\    f("x")
        \\
    , "luce.sema.type");
}

test "luce.sema.type: a returned value must match the declared return type" {
    try expectRejected(
        \\func f() -> Int:
        \\    return "x"
        \\
        \\func main():
        \\    let y = f()
        \\
    , "luce.sema.type");
}

test "luce.sema.type: a list literal is homogeneous" {
    try expectRejected("func main():\n    let xs = [1, \"x\"]\n", "luce.sema.type");
}

test "luce.sema.type: a struct field takes its declared type" {
    try expectRejected(
        \\struct P:
        \\    x: Int
        \\
        \\func main():
        \\    let p = P(x = "s")
        \\
    , "luce.sema.type");
}

test "luce.sema.type: not needs a Bool" {
    try expectRejected("func main():\n    let a = not 1\n", "luce.sema.type");
}

test "luce.sema.type: negation needs a number" {
    try expectRejected("func main():\n    let a = -\"x\"\n", "luce.sema.type");
}

test "luce.sema.type: Bool has no ordering" {
    try expectRejected("func main():\n    let a = true < false\n", "luce.sema.type");
}

test "luce.sema.type: and needs Bool operands" {
    try expectRejected("func main():\n    let a = 1 and 2\n", "luce.sema.type");
}

test "luce.sema.type: String has no arithmetic operator" {
    try expectRejected("func main():\n    let a = \"x\" - \"y\"\n", "luce.sema.type");
}

test "luce.sema.type: range bounds must be Int" {
    try expectRejected("func main():\n    for i in range(1.0, 2.0):\n        return\n", "luce.sema.type");
}

// ---------------------------------------------------------------------------
// luce.sema.convert
// ---------------------------------------------------------------------------

test "luce.sema.convert: a conversion takes exactly one argument" {
    try expectRejected("func main():\n    let a = Int(1, 2)\n", "luce.sema.convert");
}

// ---------------------------------------------------------------------------
// luce.sema.field
// ---------------------------------------------------------------------------

test "luce.sema.field: a non-struct value has no fields" {
    try expectRejected("func main():\n    let a = 1\n    let b = a.x\n", "luce.sema.field");
}

test "luce.sema.field: assigning through a non-struct is rejected" {
    try expectRejected("func main():\n    var a = 1\n    a.x = 2\n", "luce.sema.field");
}

// ---------------------------------------------------------------------------
// luce.sema.call — distinct paths
// ---------------------------------------------------------------------------

test "luce.sema.call: the entry function cannot be called" {
    try expectRejected("func main():\n    main()\n", "luce.sema.call");
}

test "luce.sema.call: function arguments are positional, not named" {
    try expectRejected(
        \\func f(a: Int):
        \\    return
        \\
        \\func main():
        \\    f(a = 1)
        \\
    , "luce.sema.call");
}

test "luce.sema.call: a None function's result is not a value" {
    try expectRejected(
        \\func f():
        \\    return
        \\
        \\func main():
        \\    let x = f()
        \\
    , "luce.sema.call");
}

test "luce.sema.call: a builtin checks its arity" {
    try expectRejected("func main():\n    let a = len(1, 2)\n", "luce.sema.call");
}

test "luce.sema.call: a builtin's arguments are positional" {
    try expectRejected("func main():\n    let a = len(x = 1)\n", "luce.sema.call");
}

// ---------------------------------------------------------------------------
// luce.sema.method — distinct paths
// ---------------------------------------------------------------------------

test "luce.sema.method: an unknown method on a List is rejected" {
    try expectRejected("func main():\n    var xs = [1]\n    xs.frobnicate()\n", "luce.sema.method");
}

test "luce.sema.method: a method checks its arity" {
    try expectRejected("func main():\n    var xs = [1]\n    xs.append(1, 2)\n", "luce.sema.method");
}

test "luce.sema.method: method arguments are positional" {
    try expectRejected("func main():\n    var xs = [1]\n    xs.append(v = 1)\n", "luce.sema.method");
}

test "luce.sema.method: more arguments than any method takes is still that method's count" {
    // There used to be a blanket refusal above the dispatch — "no
    // method takes more than 2 arguments" — that caught this before
    // `append` could answer for itself.  It named neither the method
    // nor a count, and it was never needed: every method checks its
    // own arity first, and Zig's `or` short-circuits the indexing
    // that the blanket check was guarding.
    try expectSayingAt(
        "func main():\n    var xs = [1]\n    xs.append(1, 2, 3)\n",
        "luce.sema.method",
        "append takes 1 argument, got 3",
        3,
        5,
    );
}

test "luce.sema.method: strings has no such function" {
    try expectRejected(
        \\import std.strings
        \\
        \\func main():
        \\    let s = "x"
        \\    let n = s.frobnicate()
        \\
    , "luce.sema.method");
}

test "luce.sema.import: String methods need import strings" {
    try expectRejected("func main():\n    let s = \"x\"\n    let n = s.find(\"y\")\n", "luce.sema.import");
}

test "luce.sema.import: join on List(String) needs import strings" {
    try expectRejected(
        \\func main():
        \\    let parts = ["a", "b"]
        \\    let s = parts.join(",")
        \\
    , "luce.sema.import");
}

test "luce.sema.call: a routed strings call checks its arity" {
    try expectRejected(
        \\import std.strings
        \\
        \\func main():
        \\    let n = "abc".find("b", 1, 2)
        \\
    , "luce.sema.call");
}

test "luce.sema.type: a routed strings call checks argument types" {
    try expectRejected(
        \\import std.strings
        \\
        \\func main():
        \\    let n = "abc".find(7)
        \\
    , "luce.sema.type");
}

test "luce.sema.method: Map has no such method" {
    try expectRejected(
        \\func main():
        \\    var m = new Map(String, Int)
        \\    m.frobnicate()
        \\
    , "luce.sema.method");
}

// ---------------------------------------------------------------------------
// luce.sema.index — distinct paths
// ---------------------------------------------------------------------------

test "luce.sema.index: only a String is sliced, so a number is refused" {
    try expectRejected("func main():\n    let text = 1[0:1]\n", "luce.sema.index");
}

test "luce.sema.index: a String is sliced, not indexed" {
    try expectRejected("func main():\n    let s = \"abc\"\n    let c = s[0]\n", "luce.sema.index");
}

test "luce.sema.index: a List indexes with an Int, not a Bool" {
    try expectRejected("func main():\n    var xs = [1]\n    let a = xs[true]\n", "luce.sema.index");
}

test "luce.sema.index: an Array wants one index per dimension" {
    try expectRejected(
        \\func main():
        \\    var grid = new Array(Int, 2, 2)
        \\    let a = grid[0]
        \\
    , "luce.sema.index");
}

test "luce.sema.index: a Map cannot be sliced" {
    try expectRejected(
        \\func main():
        \\    var m = new Map(Int, Int)
        \\    let a = m[0:1]
        \\
    , "luce.sema.index");
}

// ---------------------------------------------------------------------------
// luce.sema.construct — distinct paths
// ---------------------------------------------------------------------------

test "luce.sema.construct: an unknown field is rejected" {
    try expectRejected(
        \\struct P:
        \\    x: Int
        \\
        \\func main():
        \\    let p = P(x = 1, z = 2)
        \\
    , "luce.sema.construct");
}

test "luce.sema.construct: a field cannot be given twice" {
    try expectRejected(
        \\struct P:
        \\    x: Int
        \\
        \\func main():
        \\    let p = P(x = 1, x = 2)
        \\
    , "luce.sema.construct");
}

test "luce.sema.construct: fields are named, not positional" {
    try expectRejected(
        \\struct P:
        \\    x: Int
        \\
        \\func main():
        \\    let p = P(1)
        \\
    , "luce.sema.construct");
}

test "luce.sema.construct: a function-namespace struct has no value fields" {
    try expectRejected(
        \\struct Util:
        \\    func helper() -> Int:
        \\        return 1
        \\
        \\func main():
        \\    let u = Util(x = 1)
        \\
    , "luce.sema.construct");
}

// ---------------------------------------------------------------------------
// luce.sema.new — distinct paths
// ---------------------------------------------------------------------------

test "luce.sema.new: new Array takes one to four dimension sizes" {
    try expectRejected("func main():\n    var a = new Array(Int, 1, 2, 3, 4, 5)\n", "luce.sema.new");
}

test "luce.sema.new: array dimensions are Int" {
    try expectRejected("func main():\n    var a = new Array(Int, true)\n", "luce.sema.new");
}

// ---------------------------------------------------------------------------
// luce.sema.loop — distinct paths
// ---------------------------------------------------------------------------

test "luce.sema.loop: continue needs a loop" {
    try expectRejected("func main():\n    continue\n", "luce.sema.loop");
}

test "luce.sema.loop: a non-iterable cannot drive for-each" {
    try expectRejected("func main():\n    for x in 5:\n        return\n", "luce.sema.loop");
}

// ---------------------------------------------------------------------------
// luce.sema.return — distinct paths
// ---------------------------------------------------------------------------

test "luce.sema.return: a typed function must return a value" {
    try expectRejected(
        \\func f() -> Int:
        \\    return
        \\
        \\func main():
        \\    let y = f()
        \\
    , "luce.sema.return");
}

test "luce.sema.return: a None function returns no value" {
    try expectRejected(
        \\func f():
        \\    return 1
        \\
        \\func main():
        \\    f()
        \\
    , "luce.sema.return");
}

// ---------------------------------------------------------------------------
// luce.sema.struct — distinct paths
// ---------------------------------------------------------------------------

test "luce.sema.struct: mutually recursive structs have no finite value" {
    try expectRejected(
        \\struct A:
        \\    b: B
        \\
        \\struct B:
        \\    a: A
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.struct");
}

// ---------------------------------------------------------------------------
// luce.sema.const — distinct paths
// ---------------------------------------------------------------------------

test "luce.sema.const: a call is not a constant" {
    try expectRejected(
        \\func f() -> Int:
        \\    return 1
        \\
        \\let bad = f()
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.const");
}

test "luce.sema.const: an unknown name is not a constant" {
    try expectRejected("let bad = ghost\n\nfunc main():\n    return\n", "luce.sema.const");
}

test "luce.sema.const: a constant cannot depend on itself" {
    try expectRejected("let bad = bad\n\nfunc main():\n    return\n", "luce.sema.const");
}

test "luce.sema.const: a list literal is an object, not a constant" {
    try expectRejected("let bad = [1, 2]\n\nfunc main():\n    return\n", "luce.sema.const");
}

// ---------------------------------------------------------------------------
// luce.sema.literal — expression-position literal overflow
// ---------------------------------------------------------------------------

test "luce.sema.literal: an over-large integer literal is rejected" {
    try expectRejected("func main():\n    let a = 99999999999999999999\n", "luce.sema.literal");
}

test "luce.sema.literal: a negated literal past Int's minimum is rejected too" {
    try expectRejected("func main():\n    let a = -9223372036854775809\n", "luce.sema.literal");
    try expectRejected("func main():\n    let a = 9223372036854775808\n", "luce.sema.literal");
}

test "luce.sema.literal: a float literal that is not finite is rejected" {
    // parseFloat is happy to hand back infinity; a program that says
    // 1e400 did not ask for infinity, it made a mistake.
    try expectRejected("func main():\n    let a = 1e400\n", "luce.sema.literal");
    try expectRejected("func main():\n    let a = -1e400\n", "luce.sema.literal");
}

test "luce.sema.const: a non-finite float constant is rejected as well" {
    try expectRejected("let a = 1e400\n\nfunc main():\n    let b = a\n", "luce.sema.const");
}

test "luce.sema.const: ord of an empty String has no codepoint to fold" {
    try expectRejected("let a = ord(\"\")\n\nfunc main():\n    let b = a\n", "luce.sema.const");
}

// ---------------------------------------------------------------------------
// luce.sema.nesting — this stage's own recursion bound
// ---------------------------------------------------------------------------
//
// Stage 3 bounds recursive *descent*, which a left-leaning chain never
// exercises: `1 + 1 + ... + 1` parses in a Pratt loop at depth one and
// yields a tree as deep as the chain is long.  This stage walks that
// tree recursively, so a long enough chain used to segfault the
// compiler — an f-string with enough holes was enough, since it
// desugars to exactly such a chain.

fn longChain(allocator: std.mem.Allocator, prefix: []const u8, term: []const u8, count: usize, suffix: []const u8) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    try text.appendSlice(allocator, prefix);
    for (0..count) |index| {
        if (index != 0) try text.appendSlice(allocator, " + ");
        try text.appendSlice(allocator, term);
    }
    try text.appendSlice(allocator, suffix);
    return text.toOwnedSlice(allocator);
}

test "luce.sema.nesting: a flat operator chain is bounded, not overflowed" {
    const source = try longChain(testing.allocator, "func main():\n    let a = ", "1", 5000, "\n");
    defer testing.allocator.free(source);
    try expectRejected(source, "luce.sema.nesting");
}

test "luce.sema.nesting: a flat chain in a constant is bounded too" {
    const source = try longChain(testing.allocator, "let a = ", "1", 5000, "\n\nfunc main():\n    let b = a\n");
    defer testing.allocator.free(source);
    try expectRejected(source, "luce.sema.nesting");
}

test "luce.sema.nesting: an f-string with thousands of holes is bounded" {
    // f"{x}{x}..." desugars to str(x) + str(x) + ..., which is the
    // same flat chain wearing different clothes.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "func main():\n    let x = 1\n    let s = f\"");
    for (0..4000) |_| try text.appendSlice(testing.allocator, "{x}");
    try text.appendSlice(testing.allocator, "\"\n");
    try expectRejected(text.items, "luce.sema.nesting");
}

test "an ordinary deep expression still compiles" {
    // The bound must sit well above anything a person writes.
    const source = try longChain(testing.allocator, "func main():\n    let a = ", "1", 200, "\n");
    defer testing.allocator.free(source);
    var result = try compile_mod.compile(testing.allocator, source, script);
    defer result.deinit();
    if (result == .failure) printAll(&result.failure);
    try testing.expect(result == .success);
}

// ---------------------------------------------------------------------------
// luce.sema.absent — a T? where a T belongs (docs/FAILURE.md)
// ---------------------------------------------------------------------------
//
// Getting these right is most of the value of optionals: a reader who
// meets one has to be told which of the two ways out to take, and on
// which name.  Every message here names both.

test "luce.sema.absent: a T? in an operator says how to make it a T" {
    try expectRejected(
        \\func main():
        \\    let n = parse_int("1")
        \\    let doubled = n * 2
        \\
    , "luce.sema.type");
    try expectMessage(
        \\func main():
        \\    let n = parse_int("1")
        \\    let doubled = n * 2
        \\
    , "test it first (if n != none:) or supply a fallback (n else …)");
}

test "luce.sema.absent: a T? used unnarrowed names the two ways out" {
    // As a condition.
    try expectMessage(
        \\func main():
        \\    var flag: Bool? = none
        \\    if flag:
        \\        return
        \\
    , "test it first (if flag != none:)");
    // As a method receiver.
    try expectRejected(
        \\func main():
        \\    var xs: List(Int)? = none
        \\    xs.append(1)
        \\
    , "luce.sema.absent");
    // As something to index.
    try expectRejected(
        \\func main():
        \\    var xs: List(Int)? = none
        \\    let first = xs[0]
        \\
    , "luce.sema.index");
    // As something to iterate.
    try expectRejected(
        \\func main():
        \\    var xs: List(Int)? = none
        \\    for x in xs:
        \\        return
        \\
    , "luce.sema.loop");
    // As something to hand over, or to free.
    try expectRejected(
        \\func consume(xs: give List(Int)):
        \\    free(xs)
        \\
        \\func main():
        \\    var xs: List(Int)? = none
        \\    consume(give xs)
        \\
    , "luce.sema.absent");
    try expectRejected(
        \\func main():
        \\    var xs: List(Int)? = none
        \\    free(xs)
        \\
    , "luce.sema.absent");
}

test "luce.sema.absent: a field is not a local, so it is told to bind a name" {
    try expectMessage(
        \\struct Bag:
        \\    items: List(Int)?
        \\
        \\func main():
        \\    let bag = Bag(items = none)
        \\    bag.items.append(1)
        \\
    , "bind it to a name and test that");
}

test "luce.sema.absent: none needs somewhere to be none of" {
    try expectRejected(
        \\func main():
        \\    let x = none
        \\
    , "luce.sema.absent");
    try expectMessage(
        \\func main():
        \\    assert(str(none) == "")
        \\
    , "none needs a type here");
    // A place that is always there cannot be none.
    try expectRejected(
        \\func main():
        \\    var n: Int = none
        \\
    , "luce.sema.absent");
    try expectRejected(
        \\func main():
        \\    let n = 1
        \\    assert(n == none)
        \\
    , "luce.sema.absent");
    // Absence has no ordering, and nothing to be equal to but a T?.
    try expectRejected(
        \\func main():
        \\    let n = parse_int("1")
        \\    assert(n < none)
        \\
    , "luce.sema.absent");
    try expectRejected(
        \\func main():
        \\    assert(none == none)
        \\
    , "luce.sema.absent");
    // A constant is a value that is there.
    try expectRejected(
        \\let missing = none
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.const");
}

test "luce.sema.absent: a test or a fallback that can never fire is refused" {
    try expectMessage(
        \\func main():
        \\    var n: Int? = none
        \\    n = 4
        \\    assert(n != none)
        \\
    , "n already holds a value here");
    try expectMessage(
        \\func main():
        \\    var n: Int? = none
        \\    n = 4
        \\    assert((n else 0) == 4)
        \\
    , "n already holds a value here, so the else can never run");
    try expectMessage(
        \\func main():
        \\    assert((1 else 0) == 1)
        \\
    , "else supplies the value a T? does not have");
}

test "luce.sema.absent: narrowing does not survive what could undo it" {
    // A loop body that reassigns the name re-enters with whatever it
    // left, so the narrowing from outside does not hold inside.
    try expectMessage(
        \\func main():
        \\    var n: Int? = 1
        \\    var total = 0
        \\    while total < 10:
        \\        total = total + n
        \\        n = none
        \\
    , "operands are Int and Int?");
    // One arm narrowing is not both arms narrowing.  (Where *both*
    // arms do — `if n == none: n = 1` — the join keeps it, and that is
    // the point of a join.)
    try expectMessage(
        \\func maybe(flag: Bool) -> Int:
        \\    var n: Int? = none
        \\    if flag:
        \\        n = 1
        \\    return n * 2
        \\
        \\func main():
        \\    assert(maybe(true) == 2)
        \\
    , "operands are Int? and Int");
    // A call cannot narrow: only the name itself.
    try expectRejected(
        \\func check(n: Int?) -> Bool:
        \\    return n != none
        \\
        \\func main():
        \\    let n = parse_int("1")
        \\    if check(n):
        \\        let doubled = n * 2
        \\
    , "luce.sema.type");
}

test "luce.parse.type: T?? is refused where it is written" {
    try expectRejected(
        \\func main():
        \\    var n: Int?? = none
        \\
    , "luce.parse.type");
}

test "luce.sema.type: a container element may not be optional" {
    try expectMessage(
        \\func main():
        \\    var xs = new List(Int?)
        \\
    , "a list element cannot be optional");
    try expectRejected(
        \\func main():
        \\    var m = new Map(String, Int?)
        \\
    , "luce.sema.type");
    try expectRejected(
        \\func main():
        \\    var grid = new Array(Int?, 2)
        \\
    , "luce.sema.type");
}

test "none is a keyword, so nothing can be named it" {
    try expectRejected(
        \\func main():
        \\    let none = 1
        \\
    , "luce.parse.expected");
}

// ---------------------------------------------------------------------------
// luce.sema.limit — the reporting cap
// ---------------------------------------------------------------------------

test "luce.sema.limit: reporting is capped so one broken file cannot flood" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "func main():\n");
    for (0..5000) |index| {
        var line: [64]u8 = undefined;
        try text.appendSlice(testing.allocator, try std.fmt.bufPrint(&line, "    let a{d}: Int = \"x\"\n", .{index}));
    }
    var result = try compile_mod.compile(testing.allocator, text.items, script);
    defer result.deinit();
    try testing.expect(result == .failure);
    // The cap, plus the one diagnostic that says the cap was reached.
    try testing.expect(result.failure.count() <= semantics.max_diagnostics + 1);
    var capped = false;
    for (0..result.failure.count()) |index| {
        if (std.mem.eql(u8, result.failure.at(index).?.code, "luce.sema.limit")) capped = true;
    }
    try testing.expect(capped);
}

// ---------------------------------------------------------------------------
// Recovery — one mistake should cost one message
// ---------------------------------------------------------------------------

test "every statement is checked, not just the first that fails" {
    var result = try compile_mod.compile(testing.allocator,
        \\func main():
        \\    let a: Int = "x"
        \\    let b: Float = 1
        \\    let c = 1 < true
        \\
    , script);
    defer result.deinit();
    try testing.expect(result == .failure);
    try testing.expectEqual(@as(usize, 3), result.failure.count());
}

test "a binding whose initializer failed does not make every later use an error" {
    // rustc gives the binding an error type so its uses stay quiet;
    // this stage has no type to spare and remembers the name instead.
    // Either way the reader gets the one mistake they made.
    var result = try compile_mod.compile(testing.allocator,
        \\func main():
        \\    let total = nope
        \\    assert(total == 1)
        \\    assert(total + 1 == 2)
        \\    let doubled = total * 2
        \\    assert(doubled == 2)
        \\
    , script);
    defer result.deinit();
    try testing.expect(result == .failure);
    errdefer printAll(&result.failure);
    try testing.expectEqual(@as(usize, 1), result.failure.count());
    try testing.expectEqualStrings("luce.sema.name", result.failure.at(0).?.code);
}

// ---------------------------------------------------------------------------
// Suggestions — the closest name the reader could have meant
// ---------------------------------------------------------------------------

/// Compile `source`, expect failure, and require the first message to
/// contain `fragment`.  Used where the *advice* is the guarantee.
fn expectMessage(source: []const u8, fragment: []const u8) !void {
    var result = try compile_mod.compile(testing.allocator, source, script);
    defer result.deinit();
    switch (result) {
        .success => return error.TestUnexpectedResult,
        .failure => |diagnostics| {
            errdefer printAll(&diagnostics);
            const first = diagnostics.at(0) orelse return error.TestUnexpectedResult;
            if (std.mem.indexOf(u8, first.message, fragment) == null) {
                std.debug.print("wanted \"{s}\" in:\n{s}\n", .{ fragment, first.message });
                return error.TestUnexpectedResult;
            }
        },
    }
}

test "a misspelled local name suggests the one in scope" {
    try expectMessage(
        \\func main():
        \\    let total = 1
        \\    assert(totl == 1)
        \\
    , "did you mean total?");
}

test "a misspelled function, field, type, and method each suggest the real one" {
    try expectMessage(
        \\func compute(a: Int) -> Int:
        \\    return a
        \\
        \\func main():
        \\    assert(comptue(1) == 1)
        \\
    , "did you mean compute?");
    try expectMessage(
        \\struct Point:
        \\    across: Int
        \\    down: Int
        \\
        \\func main():
        \\    let p = Point(across = 1, down = 2)
        \\    assert(p.acros == 1)
        \\
    , "did you mean across?");
    try expectMessage(
        \\func main():
        \\    let a: Strng = "x"
        \\    assert(len(a) == 1)
        \\
    , "did you mean String?");
    try expectMessage(
        \\func main():
        \\    var xs = [1, 2]
        \\    xs.appnd(3)
        \\
    , "did you mean append?");
}

test "a name too short to guess from suggests nothing" {
    // `z` is one edit from `x` and means nothing like it.
    try expectMessage(
        \\struct Point:
        \\    x: Int
        \\    y: Int
        \\
        \\func main():
        \\    let p = Point(x = 1, y = 2)
        \\    assert(p.z == 1)
        \\
    , "Point has no field z");
}

test "a function that can fall off the end names the type it owes" {
    try expectMessage(
        \\func pick(a: Int) -> Float:
        \\    if a > 0:
        \\        return 1.0
        \\
        \\func main():
        \\    assert(pick(1) == 1.0)
        \\
    , "pick must return Float on every path");
}

test "storing a borrowed parameter is not told to give it" {
    // give on a borrow is its own error (S12), so advising it would
    // only earn the reader a second message one keystroke later.
    try expectMessage(
        \\func stash(index: Map(String, List(Int)), hits: List(Int)):
        \\    index["latest"] = hits
        \\
        \\func main():
        \\    var m = new Map(String, List(Int))
        \\
    , "borrowed parameter and can never be given away");
}

// ---------------------------------------------------------------------------
// luce.sema.struct — a struct that cannot be built
// ---------------------------------------------------------------------------

test "luce.sema.struct: a struct that expands past the value limit is rejected" {
    // Twenty layouts with two struct fields each is a million values
    // from forty lines of source: every one costs an instruction to
    // zero and a register to build.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "struct S0:\n    v: Int\n");
    for (1..21) |level| {
        var line: [64]u8 = undefined;
        try text.appendSlice(testing.allocator, try std.fmt.bufPrint(&line, "struct S{d}:\n    a: S{d}\n    b: S{d}\n", .{ level, level - 1, level - 1 }));
    }
    try text.appendSlice(testing.allocator, "func main():\n    var g: S20\n");
    try expectRejected(text.items, "luce.sema.struct");
}

test "a wide struct graph with no cycle compiles, and quickly" {
    // The same shape, kept under the limit.  Answering "does this
    // contain itself" or "does it carry an object" by walking every
    // path is exponential here; both are settled once instead.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "struct S0:\n    v: Int\n");
    for (1..11) |level| {
        var line: [64]u8 = undefined;
        try text.appendSlice(testing.allocator, try std.fmt.bufPrint(&line, "struct S{d}:\n    a: S{d}\n    b: S{d}\n", .{ level, level - 1, level - 1 }));
    }
    try text.appendSlice(testing.allocator, "func main():\n    var g: S10\n    assert(g.a.a.a.a.a.a.a.a.a.a.v == 0)\n");
    var result = try compile_mod.compile(testing.allocator, text.items, script);
    defer result.deinit();
    if (result == .failure) printAll(&result.failure);
    try testing.expect(result == .success);
}

test "luce.sema.struct: a cycle through a wide graph is still found" {
    try expectRejected(
        \\struct A:
        \\    left: B
        \\    right: B
        \\
        \\struct B:
        \\    left: C
        \\    right: C
        \\
        \\struct C:
        \\    back: A
        \\    value: Int
        \\
        \\func main():
        \\    assert(true)
        \\
    , "luce.sema.struct");
}

// ---------------------------------------------------------------------------
// luce.sema.host — each gated builtin
// ---------------------------------------------------------------------------

test "luce.sema.host: file_read is gated" {
    try expectRejected("func main():\n    let a = file_read(\"x\")\n", "luce.sema.host");
}

test "luce.sema.host: key_read is gated" {
    try expectRejected("func main():\n    let a = key_read()\n", "luce.sema.host");
}

test "luce.sema.host: term_write is gated" {
    try expectRejected("func main():\n    term_write(\"x\")\n", "luce.sema.host");
}

// ---------------------------------------------------------------------------
// luce.sema.import — referencing an unimported module
// ---------------------------------------------------------------------------

test "luce.sema.import: an unknown module in a type is rejected" {
    try expectRejected(
        "func f(a: geo.Point):\n    return\n\nfunc main():\n    return\n",
        "luce.sema.import",
    );
}

// NOTE: the namespace-in-a-call form of luce.sema.import
// ("unknown namespace geo; import geo to use it") fires only when the head
// names a module that is *loaded elsewhere in the program but not imported
// here* (04_semantics/builder.zig methodNamespace).  A bare geo.dist(1) with no such
// module resolves to luce.sema.name instead, so this path needs a
// multi-module project and is not reachable through the single-file
// harness.  The type-resolution form above covers the luce.sema.import code.

// ---------------------------------------------------------------------------
// luce.import.missing — an import with no loader cannot resolve
// ---------------------------------------------------------------------------

test "luce.import.missing: a nonexistent module cannot be loaded" {
    try expectRejected("import ghost\n\nfunc main():\n    return\n", "luce.import.missing");
}

// ---------------------------------------------------------------------------
// luce.import.standard / reserved — the std namespace
// ---------------------------------------------------------------------------

test "luce.import.standard: the library has no such module" {
    try expectRejected("import std.ghost\n\nfunc main():\n    return\n", "luce.import.standard");
}

test "luce.import.reserved: std is a namespace, not a module" {
    try expectRejected("import std\n\nfunc main():\n    return\n", "luce.import.reserved");
}

// NOTE: luce.import.collision — `import std.math` and `import math`
// binding one name — needs a loader with a sibling module in it, so it
// is proven in compile/test.zig rather than through this single-file
// harness.

// ---------------------------------------------------------------------------
// Failure: luce.sema.fallible
// ---------------------------------------------------------------------------

test "luce.sema.fallible: a call that can fail must say try or catch" {
    // The whole point of the diagnostic, and the shape the live bug in
    // `dice.luc` had: a fallible call written as if it could not fail
    // (docs/FAILURE.md).
    try expectHostError(
        \\func main():
        \\    file_write("out.txt", "body")
        \\
    , "luce.sema.fallible");
    try expectHostError(
        \\import std.files
        \\
        \\func main():
        \\    let text = files.read("notes.txt")
        \\
    , "luce.sema.fallible");
}

test "luce.sema.fallible: try needs a caller that said it can fail" {
    try expectHostError(
        \\func main():
        \\    let text = try file_read("notes.txt")
        \\
    , "luce.sema.fallible");
}

test "luce.sema.fallible: try and catch need a call that can fail" {
    try expectHostError(
        \\func main() -> !:
        \\    let n = try len("abc")
        \\
    , "luce.sema.fallible");
    try expectHostError(
        \\func main() -> !:
        \\    let n = len("abc") catch 0
        \\
    , "luce.sema.fallible");
    try expectHostError(
        \\func main() -> !:
        \\    print("hi") catch:
        \\        print("no")
        \\
    , "luce.sema.fallible");
}

test "luce.sema.fallible: error() needs a caller that said it can fail" {
    try expectRejected(
        \\func main():
        \\    error("no")
        \\
    , "luce.sema.fallible");
}

test "luce.sema.call: a fallible builtin that answers nothing has nothing to test" {
    // What `if files.write_lines(...)` became.  There is no Bool left
    // to swallow, so the mistake is unwritable rather than silent.
    try expectHostError(
        \\func main() -> !:
        \\    if try file_write("out.txt", "body"):
        \\        print("wrote")
        \\
    , "luce.sema.call");
}

test "luce.sema.own: the two sides of catch agree on ownership" {
    try expectHostError(
        \\func load(path: String) -> List(String)!:
        \\    let lines = new List(String)
        \\    lines.append(try file_read(path))
        \\    return lines
        \\
        \\func main():
        \\    let kept = new List(String)
        \\    let got = load("notes.txt") catch kept
        \\    free(kept)
        \\
    , "luce.sema.own");
}

test "luce.parse.expected: catch guards a plain assignment, not a compound one" {
    try expectHostError(
        \\func main():
        \\    var text = ""
        \\    text += file_read("notes.txt") catch:
        \\        print("no")
        \\
    , "luce.parse.expected");
}

test "luce.sema.main: a script entry may say ! and nothing else" {
    try expectRejected(
        \\func main() -> Int!:
        \\    return 1
        \\
    , "luce.sema.main");
    try expectRejected(
        \\func main() -> Int:
        \\    return 1
        \\
    , "luce.sema.main");
}

// ---------------------------------------------------------------------------
// One case per check, where the code alone cannot say which check ran
// ---------------------------------------------------------------------------
//
// Stage 4 emits 186 diagnostics from 186 places, and the tests above
// reach 145 of them.  The rest are pinned here, each by its own words,
// because a code shared between checks is a code that stays green
// while a check is deleted: `luce.sema.let` guards four assignment
// forms and the everyday tests only ever wrote the simplest one, so
// removing the check on the other three changed no test at all.
//
// Every case below names the *form* it refuses rather than the code,
// and asserts the sentence that only that check writes.
//
// Six of the 186 have no case here because they have no input, and
// each is written down where it stands rather than left looking
// untested:
//
//   * `luce.sema.import` in `resolveDeclared` — `ast.Call.callee` is
//     one identifier token, so a dotted call is parsed as a method and
//     answered on the other path (`compile/test.zig`).
//   * `luce.sema.type` "compound assignment needs matching types" —
//     all four callers compare the place with the value first.
//   * `luce.sema.type` "value has no type" — a `none` operand is
//     "returns nothing" one check earlier.
//   * `luce.sema.type` "None? is not a type" — `resolveBase` never
//     answers `none`, so the `?` never has nothing to widen.
//   * `luce.sema.fallible` and `luce.sema.call` in `stringsCall` — no
//     function in std `strings` is fallible or returns nothing.  These
//     two are the only ones a *library* change makes reachable, and
//     they are the reason they stay.
//
// They are all null arms of shared helpers, which is why they are
// written and why they are cheap; what they are not is coverage.

test "luce.sema.let: every assignment form refuses a let, not only the plain one" {
    // Four checks, one per shape of place.  The plain name is the one
    // everything else already covered; the other three are here.
    try expectSaying(
        \\func main():
        \\    let count = 1
        \\    count = 2
        \\
    , "luce.sema.let", "count is let-bound");

    // A field of a let-bound struct.
    try expectSaying(
        \\struct Point:
        \\    x: Int
        \\    y: Int
        \\
        \\func main():
        \\    let p = Point(x = 1, y = 2)
        \\    p.x = 3
        \\
    , "luce.sema.let", "p is let-bound");

    // A nested place: the root is what has to be mutable, however
    // many steps down the leaf sits.
    try expectSaying(
        \\struct Inner:
        \\    value: Int
        \\
        \\struct Outer:
        \\    inner: Inner
        \\
        \\func main():
        \\    let held = Outer(inner = Inner(value = 1))
        \\    held.inner.value = 2
        \\
    , "luce.sema.let", "held is let-bound");

    // And compound assignment through a chain is an assignment too.
    try expectSaying(
        \\struct Inner:
        \\    value: Int
        \\
        \\struct Outer:
        \\    inner: Inner
        \\
        \\func main():
        \\    let held = Outer(inner = Inner(value = 1))
        \\    held.inner.value += 2
        \\
    , "luce.sema.let", "held is let-bound");

    // A file-scope constant is immutable for a different reason, and
    // says so in different words.
    try expectSaying(
        \\let width = 80
        \\
        \\func main():
        \\    width = 3
        \\
    , "luce.sema.let", "width is a file-scope constant");
}

test "luce.sema.field: an unknown field is named wherever the chain meets it" {
    // The same helper answers for a read, a single-level write, and a
    // nested place; each reaches it by its own path.
    try expectSaying(
        \\struct Point:
        \\    x: Int
        \\
        \\func main():
        \\    let p = Point(x = 1)
        \\    let bad = p.z
        \\
    , "luce.sema.field", "Point has no field z");
    try expectSaying(
        \\struct Point:
        \\    x: Int
        \\
        \\func main():
        \\    var p = Point(x = 1)
        \\    p.z = 2
        \\
    , "luce.sema.field", "Point has no field z");
    try expectSaying(
        \\struct Inner:
        \\    value: Int
        \\
        \\struct Outer:
        \\    inner: Inner
        \\
        \\func main():
        \\    var held = Outer(inner = Inner(value = 1))
        \\    held.inner.missing = 2
        \\
    , "luce.sema.field", "Inner has no field missing");
    // A near miss is spelled out; a name nothing resembles is not.
    try expectSaying(
        \\struct Point:
        \\    value: Int
        \\
        \\func main():
        \\    let p = Point(value = 1)
        \\    let bad = p.valu
        \\
    , "luce.sema.field", "did you mean value?");
}

test "luce.sema.type: a nested place and a compound assignment check their own types" {
    try expectSaying(
        \\struct Inner:
        \\    value: Int
        \\
        \\struct Outer:
        \\    inner: Inner
        \\
        \\func main():
        \\    var held = Outer(inner = Inner(value = 1))
        \\    held.inner.value = 1.5
        \\
    , "luce.sema.type", "this place holds Int but the value is Float");
    // `compoundCombine`'s own "needs matching types" has no case
    // here, and cannot: all four callers — name, field, element,
    // chain — compare the place with the value before they combine,
    // each in its own words, so the helper's copy of the check is
    // never the one that fires.  What the helper *does* answer for is
    // the place that has no compound form at all, which is where a
    // Bool lands.
    try expectSaying(
        \\func main():
        \\    var flags = [true, false]
        \\    flags[0] += true
        \\
    , "luce.sema.type", "has no compound assignment");
}

test "luce.sema.type: an empty list literal needs somewhere to learn its element from" {
    // Three different checks, three different sentences: annotated
    // with a list type, annotated with something else, and not
    // annotated at all.
    try expectSaying(
        \\func main():
        \\    var xs = []
        \\
    , "luce.sema.type", "an empty [] needs an annotation");
    try expectSaying(
        \\func main():
        \\    var xs: Int = []
        \\
    , "luce.sema.type", "[] builds a List, but xs is annotated Int");
    try expectSaying(
        \\func main():
        \\    let size = len([])
        \\
    , "luce.sema.type", "an empty [] needs an annotated binding");
}

test "luce.sema.index: every shape of index says what it will accept" {
    try expectSaying(
        \\func main():
        \\    var grid = new Array(Int, 2, 2, 2, 2)
        \\    let bad = grid[0, 0, 0, 0, 0]
        \\
    , "luce.sema.index", "at most 4 index dimensions");
    try expectSaying(
        \\func main():
        \\    var grid = new Array(Int, 2, 2)
        \\    let bad = grid[0, 1.5]
        \\
    , "luce.sema.index", "array indices are Int");
    try expectSaying(
        \\func main():
        \\    var b = new Builder()
        \\    let bad = b[0]
        \\
    , "luce.sema.index", "Builder has no index");
    // A slice's bounds are a *type* fault rather than an indexing one:
    // what is wrong is the value written, not the shape of the access.
    try expectSaying(
        \\func main():
        \\    var xs = [1, 2, 3]
        \\    let bad = xs[0:1.5]
        \\
    , "luce.sema.type", "slice bounds are Int");
    try expectSaying(
        \\func main():
        \\    var b = new Builder()
        \\    let bad = b[0:1]
        \\
    , "luce.sema.index", "cannot be sliced");
}

test "luce.sema.loop: for takes a rank-1 array and nothing wider" {
    try expectSaying(
        \\func main():
        \\    var grid = new Array(Int, 2, 2)
        \\    for cell in grid:
        \\        let unused = cell
        \\
    , "luce.sema.loop", "for iterates rank-1 arrays");
}

test "luce.sema.method: each receiver kind names the methods it has" {
    try expectSayingAt(
        \\func main():
        \\    var s = "abc"
        \\    let bad = s.byte_at("x")
        \\
    , "luce.sema.type", "argument 1 of byte_at is Int, got String", 3, 25);
    try expectSayingAt(
        \\func main():
        \\    var s = "abc"
        \\    let bad = s.find_byte("x", 0)
        \\
    , "luce.sema.type", "argument 1 of find_byte is Int, got String", 3, 27);
    try expectSaying(
        \\func main():
        \\    var grid = new Array(Int, 2, 2)
        \\    grid.sort()
        \\
    , "luce.sema.method", "only rank-1 arrays have sort");
    try expectSaying(
        \\func main():
        \\    var m = new Map(String, Int)
        \\    let bad = m.hass("a")
        \\
    , "luce.sema.method", "did you mean has?");
    try expectSaying(
        \\func main():
        \\    var b = new Builder()
        \\    b.appen("x")
        \\
    , "luce.sema.method", "did you mean append?");
    try expectSaying(
        \\func main():
        \\    var b = new Builder()
        \\    b.zzzzzz()
        \\
    , "luce.sema.method", "(append append_ascii clear)");
    try expectSaying(
        \\import std.strings
        \\
        \\func main():
        \\    var s = "a,b"
        \\    let bad = s.spli(",")
        \\
    , "luce.sema.method", "did you mean split?");
}

// ---------------------------------------------------------------------------
// A built-in method's arguments are judged like a user function's
// ---------------------------------------------------------------------------
//
// `lowerUserCall` has always written two different sentences for two
// different mistakes — "add takes 2 arguments, got 1" for a count and
// "argument 2 of add is Int, got String" for a type, the latter
// underlined at the argument itself.  The built-in methods wrote one
// sentence for both, phrased as a count: `xs.append("hi")` on a
// `List(Int)` was told "append takes one element value" while holding
// exactly one element value, and the caret covered the whole call.
//
// These pin the sentence, the code and the caret column together,
// because the three rot separately: nothing here failed when the
// message said one thing and the underline pointed at another.

test "luce.sema.method: a count mistake names the method and both counts" {
    try expectSayingAt(
        \\func main():
        \\    var xs = new List(Int)
        \\    xs.append(1, 2)
        \\
    , "luce.sema.method", "append takes 1 argument, got 2", 3, 5);
    // Zero is a count like any other, and reads differently from two.
    try expectSayingAt(
        \\func main():
        \\    var xs = new List(Int)
        \\    xs.append()
        \\
    , "luce.sema.method", "append takes 1 argument, got 0", 3, 5);
    // A method that takes none says "0 arguments", not "no arguments":
    // one sentence for every arity is one sentence to keep true.
    try expectSayingAt(
        \\func main():
        \\    var xs = new List(Int)
        \\    xs.sort(1)
        \\
    , "luce.sema.method", "sort takes 0 arguments, got 1", 3, 5);
    // Three arguments used to be answered by "no method takes more
    // than 2 arguments", which named neither the method nor a count —
    // an internal limit of the dispatch, worded as advice.  The
    // per-method count check had always been able to answer it.
    try expectSayingAt(
        \\func main():
        \\    var m = new Map(String, Int)
        \\    let x = m.get("a", 1, 2)
        \\
    , "luce.sema.method", "get takes 2 arguments, got 3", 3, 13);
}

test "luce.sema.type: a wrong argument type names the position, both types, and underlines the argument" {
    try expectSayingAt(
        \\func main():
        \\    var xs = new List(Int)
        \\    xs.append("hello")
        \\
    , "luce.sema.type", "argument 1 of append is Int, got String", 3, 15);
    // The second slot is reported as the second slot, and the caret
    // moves to it rather than staying on the receiver.
    try expectSayingAt(
        \\func main():
        \\    var xs = new List(String)
        \\    xs.insert("zero", 0)
        \\
    , "luce.sema.type", "argument 1 of insert is Int, got String", 3, 15);
    try expectSayingAt(
        \\func main():
        \\    var b = new Builder()
        \\    b.append(65)
        \\
    , "luce.sema.type", "argument 1 of append is String, got Int", 3, 14);
    // The map says what its key and value types *are*, rather than
    // calling them "the map's key and value types".
    try expectSayingAt(
        \\func main():
        \\    var m = new Map(String, Int)
        \\    let x = m.get(1, 2)
        \\
    , "luce.sema.type", "argument 1 of get is String, got Int", 3, 19);
}

test "luce.sema.type: a T? argument to a method earns the same advice it earns anywhere" {
    // This is the sentence that teaches optionals, and the method
    // path used to drop it: the reader got "append takes one element
    // value" and no mention of absence at all.  It is now the one
    // `lowerUserCall` writes, down to the name in the parentheses.
    try expectSayingAt(
        \\func maybe() -> Int?:
        \\    return none
        \\
        \\func main():
        \\    var xs = new List(Int)
        \\    let m = maybe()
        \\    xs.append(m)
        \\
    ,
        "luce.sema.type",
        "argument 1 of append is Int, got Int?; test it first (if m != none:) or supply a fallback (m else …)",
        7,
        15,
    );
}

test "luce.sema.call: a builtin counts its arguments the way a function does" {
    // "print takes 1 arguments" miscounted its own grammar and never
    // said how many it got.  Hosted, because the host gate is checked
    // before the count and would otherwise answer first — which is the
    // right order: a program with no console has a bigger problem
    // than how many things it tried to print.
    try expectHostSayingAt(
        \\func main():
        \\    print("hi", "there")
        \\
    , "luce.sema.call", "print takes 1 argument, got 2", 2, 5);
    try expectSayingAt(
        \\func main():
        \\    let x = min(1)
        \\
    , "luce.sema.call", "min takes 2 arguments, got 1", 2, 13);
}

test "luce.sema.method: a missing method names the receiver it is missing from" {
    // Map and Builder always said which they were; List and Array
    // said "no method sortt here", where "here" named nothing.
    try expectSayingAt(
        \\func main():
        \\    var xs = new List(Int)
        \\    xs.sortt()
        \\
    , "luce.sema.method", "List has no method sortt; did you mean sort?", 3, 5);
    try expectSayingAt(
        \\func main():
        \\    var xs = new List(Int)
        \\    xs.zzzzzz()
        \\
    ,
        "luce.sema.method",
        "List has no method zzzzzz (has append insert remove pop sort reverse find contains clear; join lives in strings)",
        3,
        5,
    );
    // An Array is offered the methods an Array has, not a List's.
    try expectSayingAt(
        \\func main():
        \\    var grid = new Array(Int, 4)
        \\    grid.zzzzzz()
        \\
    , "luce.sema.method", "Array has no method zzzzzz (has dim fill sort reverse find contains)", 3, 5);
    // A String method routes through the strings module, but the
    // reader wrote a String — answering "strings has no function"
    // names a desugaring target they never typed.
    try expectSayingAt(
        \\import std.strings
        \\
        \\func main():
        \\    let s = "x"
        \\    let n = s.frobnicate()
        \\
    , "luce.sema.method", "String has no method frobnicate, and neither has the strings module", 5, 13);
}

test "luce.sema.call: a user function agrees with itself about one argument" {
    try expectSayingAt(
        \\func double(a: Int) -> Int:
        \\    return a * 2
        \\
        \\func main():
        \\    let x = double(1, 2)
        \\
    , "luce.sema.call", "double takes 1 argument, got 2", 5, 13);
}

test "luce.sema.own: the checks that have no name to suggest still say what to do" {
    // `failNeedsOwnership` has three endings: a borrowed parameter, a
    // name that could be given, and an expression that is neither.
    // The third is what a container element read reaches.
    try expectSaying(
        \\func main():
        \\    var outer = new List(List(Int))
        \\    var source = new List(List(Int))
        \\    outer.append(source[0])
        \\    free(outer)
        \\    free(source)
        \\
    , "luce.sema.own", "store something fresh, give NAME, or copy NAME");

    // Both arms of `else` decide ownership together, because the
    // binding that receives the answer either owns or does not.
    try expectHostSaying(
        \\func pick(which: Bool) -> List(Int)?:
        \\    if which:
        \\        return new List(Int)
        \\    return none
        \\
        \\func main():
        \\    let kept = new List(Int)
        \\    let got = pick(true) else kept
        \\    free(kept)
        \\
    , "luce.sema.own", "the two sides of else must agree on ownership");

    // std strings borrows, so a give at one of its arguments has no
    // owner to become.
    try expectSaying(
        \\import std.strings
        \\
        \\func main():
        \\    var parts = new List(String)
        \\    var other = new List(String)
        \\    let joined = parts.join(give other)
        \\    free(parts)
        \\
    , "luce.sema.own", "only borrows its arguments");
}

test "luce.sema.name: a port is not a place, however it is written" {
    try expectSaying(
        \\func main():
        \\    output.total.value = 1
        \\
    , "luce.sema.name", "ports are not nested places");
}

test "luce.sema.type: a written type is checked against the arguments it may take" {
    try expectSaying(
        \\func main():
        \\    var x: Int(String) = 1
        \\
    , "luce.sema.type", "Int takes no type arguments");
    try expectSaying(
        \\func main():
        \\    var m: Map(Int) = new Map(Int, Int)
        \\
    , "luce.sema.type", "Map takes key and value types");
    try expectSaying(
        \\func main():
        \\    var a: Array(Int) = new Array(Int, 2)
        \\
    , "luce.sema.type", "Array spells element and shape");
    try expectSaying(
        \\func main():
        \\    var b: Builder(Int) = new Builder()
        \\
    , "luce.sema.type", "Builder takes no type arguments");
    try expectSaying(
        \\struct Point:
        \\    x: Int
        \\
        \\func main():
        \\    var p: Point(Int) = Point(x = 1)
        \\
    , "luce.sema.type", "Point takes no type arguments");
    // `None?` has no test because it has no input: `resolveBase`
    // answers Bool, Int, Float, String, a struct or a heap type and
    // nothing else, and `Type.optionalOf` refuses only `none` and a
    // second `?`.  Writing `None?` is `unknown type None` one step
    // earlier.  The guard stays because it is the null arm of a shared
    // helper, but there is no program that reaches it.
}

test "luce.sema.struct: a struct whose fields all fell away has an empty body" {
    // Reached by a field whose type does not resolve: the field is
    // skipped, and a struct with no fields and no functions is not a
    // value at all.  Both sentences are owed here — dropping the
    // second would leave a struct in the table that nothing can build
    // and nothing said why.
    try expectSaying(
        \\struct Bad:
        \\    value: Nope
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.struct", "struct Bad has an empty body");
    try expectSaying(
        \\struct Bad:
        \\    value: Nope
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.type", "unknown type Nope");
}

test "luce.sema.duplicate: two file-scope constants cannot share a name" {
    try expectSaying(
        \\let width = 80
        \\let width = 90
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.duplicate", "duplicate name width");
}
