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
//! Organized by diagnostic code. Behavioral correctness lives in
//! behavior_spec.zig; this file owns every current source refusal.
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

/// The other half of a refusal: the program one step inside the
/// boundary is accepted, so a message about a *width* is not a
/// message about the whole conversion.
fn expectCompiles(source: []const u8) !void {
    var result = try compile_mod.compile(testing.allocator, source, hosted);
    defer result.deinit();
    if (result == .failure) {
        printAll(&result.failure);
        return error.TestUnexpectedResult;
    }
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

/// `expectOnlySayingAt`, plus the column the underline **stops** at —
/// one past the last character the reader sees marked.
///
/// The helpers above assert where a span starts, which pins every
/// caret that can move sideways.  It does not pin a caret that can only
/// grow: a diagnostic narrowed onto a binary expression's *left*
/// operand starts exactly where the whole expression starts, so
/// widening it back to the whole expression is a change no assertion
/// about the start can see.  `n and true` would go on passing with the
/// underline back under all three tokens, which is the regression the
/// narrowing was the fix for.  Where the *width* of the underline is
/// the claim, this is the assertion.
///
/// `end_column` is 1-based and half-open, matching `Rendered`: for a
/// single-character operand at column 8 it is 9.  The span must start
/// and end on the same line, which every diagnostic that narrows onto
/// an operand does.
fn expectOnlySayingAcross(
    source: []const u8,
    code: []const u8,
    saying: []const u8,
    line: usize,
    column: usize,
    end_column: usize,
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
            const stop = source_mod.place(source, first.span.end);
            try testing.expectEqual(line, stop.line);
            try testing.expectEqual(end_column, stop.column);
            try testing.expectEqual(@as(usize, 1), diagnostics.count());
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
// (source/encoding.zig).  These rejections name the file rather
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
        "func main():\r\n    let a = 1\r\n\r\n    let b = a\r\n    let c: str = b\r\n",
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

test "luce.lex.number: a second decimal point names itself, and advises nothing harmful" {
    // Was "a float needs a digit before the point; write 0.3" — the
    // wrong mistake, and an edit that yields `1.20.3`.
    try expectOnlySayingAt(
        "func main():\n    let x = 1.2.3\n",
        "luce.lex.number",
        "a number has one decimal point; 1.2.3 was read as 1.2",
        2,
        16,
    );
}

test "luce.lex.name: a name starts with a letter, and the sentence names the word" {
    // VISIBILITY.md R3: the underscore has nothing left to encode in a
    // language with a real `private` keyword, so a leading one is a
    // spelling mistake — at every use, not just declarations.
    try expectOnlySayingAt(
        "func main():\n    let _total = 1\n",
        "luce.lex.name",
        "a name starts with a letter: _total is not a name",
        2,
        9,
    );
    try expectRejected("func main():\n    print(_x)\n", "luce.lex.name");
}

test "luce.sema.private: main is the entry and cannot be private" {
    // VISIBILITY.md D7: the one caller main exists for is the runtime,
    // which no marker can gate, so the marker could only assert
    // something false.  `public` on it is inert-legal like any other
    // restated default.
    try expectOnlySayingAt(
        "private func main():\n    return\n",
        "luce.sema.private",
        "main is the entry and cannot be private: the runtime starts it",
        1,
        14,
    );
    try expectCompiles("public func main():\n    return\n");
}

test "luce.sema.private: a public surface names public types, refused at the declaration" {
    // VISIBILITY.md D4 (Rust's side): only the author of the marks can
    // trip this, and the sentence names both edits that would restore
    // honesty.  The refusal fires in the root module too, where the
    // mark lives in "this file".
    try expectOnlySayingAt(
        "private struct Inner:\n    n: i64\n\nfunc read() -> Inner:\n    return Inner(n = 1)\n\nfunc main():\n    return\n",
        "luce.sema.private",
        "read is public and answers Inner, which is marked private in this file; mark read private or remove the mark on Inner",
        4,
        16,
    );
    try expectOnlySayingAt(
        "private struct Inner:\n    n: i64\n\nfunc read(p: Inner) -> i64:\n    return 1\n\nfunc main():\n    return\n",
        "luce.sema.private",
        "read is public and takes Inner, which is marked private in this file; mark read private or remove the mark on Inner",
        4,
        14,
    );
    try expectOnlySayingAt(
        "private struct Inner:\n    n: i64\n\nstruct Outer:\n    held: Inner\n\nfunc main():\n    return\n",
        "luce.sema.private",
        "held of Outer is public and holds Inner, which is marked private in this file; mark held private or remove the mark on Inner",
        5,
        11,
    );
    // A container in the surface publishes its element exactly as the
    // bare name would.
    try expectRejected(
        "private struct Inner:\n    n: i64\n\nfunc read() -> list[Inner]:\n    return [Inner(n = 1)]\n\nfunc main():\n    return\n",
        "luce.sema.private",
    );
    // A map's **key** publishes as its value does, now that a key can
    // be a declared type (docs/ENUMS.md, As built 2026-08-12).
    try expectSaying(
        "private enum Key:\n    left\n\nfunc table() -> map[Key, i64]:\n    return new map[Key, i64]\n\nfunc main():\n    return\n",
        "luce.sema.private",
        "table is public and answers Key, which is marked private",
    );
    // A function type publishes its complete nested signature too.
    // The outer `func` tag must not hide a private parameter or result
    // from the same D4 check containers receive above.
    try expectSaying(
        "private struct Inner:\n    n: i64\n\nfunc use(callback: func(Inner) -> i64) -> i64:\n    return 0\n\nfunc main():\n    return\n",
        "luce.sema.private",
        "use is public and takes Inner, which is marked private",
    );
    try expectSaying(
        "private struct Inner:\n    n: i64\n\nfunc use(callback: func(i64) -> func(i64) -> Inner) -> i64:\n    return 0\n\nfunc main():\n    return\n",
        "luce.sema.private",
        "which is marked private",
    );
    try expectSaying(
        "private struct Inner:\n    n: i64\n\nprivate func reveal(n: i64) -> Inner:\n    return Inner(n = n)\n\nfunc expose() -> func(i64) -> Inner:\n    return reveal\n\nfunc main():\n    return\n",
        "luce.sema.private",
        "expose is public and answers Inner, which is marked private",
    );
    // The quiet common case: a private function may traffic in the
    // private type freely, and a private field may hold one.
    try expectCompiles(
        "private struct Inner:\n    n: i64\n\nprivate func read() -> Inner:\n    return Inner(n = 1)\n\nstruct Outer:\n    private held: Inner\n\nfunc main():\n    let inner = read()\n    let outer = Outer(held = inner)\n    let sum = outer.held.n + inner.n\n    if sum == 0:\n        return\n",
    );
}

test "the bare underscore declares nothing, and the wildcard keeps its one home" {
    // VISIBILITY.md D9: the lone `_` stays what it is — the
    // array-shape wildcard — so the refusal teaches that one place.
    try expectOnlySayingAt(
        "func main():\n    let _ = 1\n",
        "luce.parse.expected",
        "_ is the array-shape wildcard, not a name (array[i64, _]); a binding needs a name",
        2,
        9,
    );
    // The pin: wildcard shapes in annotations survive R3 untouched.
    try expectCompiles(
        \\func corner(grid: array[i64, _, _]) -> i64:
        \\    return grid[grid.dim(0) - 1, grid.dim(1) - 1]
        \\
        \\func main():
        \\    var grid = new array[i64](2, 2)
        \\    print(str(corner(grid)))
        \\
    );
}

test "luce.lex.number: a trailing decimal point mirrors the leading one" {
    try expectOnlySayingAt(
        "func main():\n    let x = 1.\n",
        "luce.lex.number",
        "a float needs a digit after the point; write 1.0",
        2,
        13,
    );
}

test "luce.lex.number: a leading decimal point keeps the message it always had" {
    try expectOnlySayingAt(
        "func main():\n    let x = .5\n",
        "luce.lex.number",
        "a float needs a digit before the point; write 0.5",
        2,
        13,
    );
}

test "luce.lex.str: an unterminated string is caught" {
    try expectRejected("func main():\n    let a = \"open\n", "luce.lex.str");
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

test "luce.lex.str: an unterminated f-string is caught" {
    try expectRejected("func main():\n    let a = f\"open {x}\n", "luce.lex.str");
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

test "luce.sema.convert: an f-string hole must be a scalar" {
    // A hole is a `string(...)` the reader did not write, so a list in
    // one is answered by the constructor's own message, at the hole.
    try expectRejected(
        \\func main():
        \\    var xs = [1, 2]
        \\    let a = f"{xs}"
        \\
    , "luce.sema.convert");
}

test "luce.parse.top: only import/const/struct/enum/func at file scope" {
    try expectRejected("fn main():\n    return\n", "luce.parse.top");
    try expectRejected("var counter = 0\n", "luce.parse.top");
}

test "luce.parse.expression: a missing expression is reported" {
    try expectRejected("func main():\n    let a = 1 +\n", "luce.parse.expression");
}

test "a character stage 2 refused is not refused twice" {
    // `let a = @` is one mistake.  Stage 2 names the character it
    // could not use and drops it; stage 3 then had a binding with no
    // value and said "expected an expression", which is the same
    // mistake in worse words — it cannot name `@`, because `@` never
    // became a token.  One mistake, one report, and the report is the
    // one that names the character.
    try expectOnlySayingAt(
        "func main():\n    let a = @\n",
        "luce.lex.character",
        "unexpected character '@'",
        2,
        13,
    );
    // The suppression is per construct, not per file: a later
    // statement with a mistake of its own still reports.
    var result = try compile_mod.compile(
        testing.allocator,
        "func main():\n    let a = 1 $ 2\n    let b = 1 +\n",
        script,
    );
    defer result.deinit();
    try testing.expect(result == .failure);
    try testing.expectEqual(@as(usize, 2), result.failure.count());
    try testing.expectEqualStrings("luce.lex.character", result.failure.at(0).?.code);
    try testing.expectEqualStrings("luce.parse.expression", result.failure.at(1).?.code);
}

test "a matched pair of typographic quotes is one mistake" {
    // `let a = \u{201C}hello\u{201D}` is a string somebody typed in a
    // word processor.  It used to be two stray-character reports
    // naming neither the pair nor the string it delimits.
    try expectOnlySayingAt(
        "func main():\n    let a = \u{201C}hello\u{201D}\n    print(a)\n",
        "luce.lex.character",
        "typographic quotes (U+201C and U+201D) around a string; text is written \"like this\"",
        2,
        13,
    );
    // Unmatched, there is no pair to name and the single character
    // keeps its own answer.
    try expectSayingAt(
        "func main():\n    let a = \u{201C}hello\n",
        "luce.lex.character",
        "unexpected character '\u{201C}' (U+201C): a typographic quote; text is written \"like this\"",
        2,
        13,
    );
    // And the search does not cross a line: an opening quote with its
    // partner three lines down is two unrelated mistakes, not one
    // literal swallowing the file.
    try expectSayingAt(
        "func main():\n    let a = \u{201C}x\n    let b = 1\n    let c = \u{201D}y\n",
        "luce.lex.character",
        "unexpected character '\u{201C}' (U+201C): a typographic quote; text is written \"like this\"",
        2,
        13,
    );
}

test "luce.parse.expected: a malformed binding name is reported at the name" {
    try expectRejectedAt("func main():\n    let 3 = 4\n", "luce.parse.expected", 2, 9);
}

test "luce.parse.precedence: 'not' in front of a comparison must be parenthesized" {
    // Two languages Luce reads like disagree about what this means and
    // both readings are legal bool expressions, so the parser refuses
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

test "luce.lex.indent: an over-nested file is one message, not a hundred and fifty" {
    // The guard fired once per line past the bound with no once-only
    // flag, and the recovery then handed the parser a run of bodyless
    // block headers to complain about in turn: 62 diagnostics and
    // 65 KB of output for one mistake.
    const allocator = testing.allocator;
    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(allocator);
    try deep.appendSlice(allocator, "func main():\n");
    for (1..140) |level| {
        try deep.appendNTimes(allocator, ' ', level * 4);
        try deep.appendSlice(allocator, "if true:\n");
    }
    try deep.appendNTimes(allocator, ' ', 140 * 4);
    try deep.appendSlice(allocator, "return\n");

    var result = try compile_mod.compile(allocator, deep.items, script);
    defer result.deinit();
    const diagnostics = result.failure;
    errdefer printAll(&diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.count());
    try testing.expectEqualStrings("luce.lex.indent", diagnostics.at(0).?.code);
    try testing.expectEqualStrings("blocks may not nest more than 100 deep", diagnostics.at(0).?.message);
    // On the block being opened, not on the four hundred columns of
    // indentation in front of it: line 101 is `if true:` at 100 levels
    // of four spaces, so the keyword starts at column 401.
    const at = source_mod.place(deep.items, diagnostics.at(0).?.span.start);
    try testing.expectEqual(@as(usize, 101), at.line);
    try testing.expectEqual(@as(usize, 401), at.column);

    // And the whole rendering stays small, which is the property a
    // reader actually feels.  It used to be 65 KB.
    const rendered = try diagnostics.render(allocator);
    defer allocator.free(rendered);
    try testing.expect(rendered.len < 1024);
}

// ---------------------------------------------------------------------------
// Return shapes: there is no tuple
// ---------------------------------------------------------------------------
//
// Every clause of the rule is a diagnostic (docs/RETURNS.md §1): a
// return shape is written in exactly one place, it cannot annotate
// anything, it cannot nest, it cannot take a `?`, and there is no
// expression that produces one.

test "luce.parse.type: the three shapes a return list is not" {
    try expectSaying(
        \\func f() -> ():
        \\    return
        \\
        \\func main():
        \\    return
        \\
    , "luce.parse.type", "a function that answers nothing writes no arrow");

    // A nested list is still refused, and now by the sentence that says
    // what parentheses around one type *do* mean: `(long, long)` is a
    // return shape wherever it is written, and a return shape is not a
    // type (docs/RETURNS.md).  `-> (long)` is no longer here, because a
    // parenthesized type is that type and it means `-> long`.
    try expectSaying(
        \\func f() -> ((i64, i64), i64):
        \\    return 1
        \\
        \\func main():
        \\    return
        \\
    , "luce.parse.type", "a return shape is not a type: a pair that travels together is a struct");

    try expectSaying(
        \\func f() -> (i64, i64)?:
        \\    return 1, 2
        \\
        \\func main():
        \\    return
        \\
    , "luce.parse.type", "'?' marks a value that may be absent, and a return shape is not a value");
}

test "luce.parse.type: a return shape is not a type, in any position" {
    // A binding, a parameter, a struct field, a container element.
    // The sentence to keep is the second half.
    for ([_][]const u8{
        "func main():\n    let p: (i64, i64) = 1\n",
        "func f(p: (i64, i64)):\n    return\n\nfunc main():\n    return\n",
        "struct Pair:\n    both: (i64, i64)\n\nfunc main():\n    return\n",
        "func main():\n    var xs: list[(i64, i64)] = []\n",
    }) |source| {
        try expectSaying(
            source,
            "luce.parse.type",
            "a return shape is not a type: a pair that travels together is a struct",
        );
    }
}

test "luce.parse.expression: there are still no tuples, and the parser already said so" {
    try expectSaying(
        "func main():\n    let p = (1, 2)\n",
        "luce.parse.expression",
        "there are no tuples: group values in a list '[a, b]' or a struct",
    );
}

test "luce.parse.assign: one keyword governs a bind, and catch cannot invent a tuple" {
    try expectSaying(
        \\func minmax() -> (i64, i64):
        \\    return 1, 2
        \\
        \\func main():
        \\    let a, var b = minmax()
        \\
    , "luce.parse.assign", "one let or one var governs the whole bind");

    try expectSaying(
        \\func minmax() -> (i64, i64)!:
        \\    return 1, 2
        \\
        \\func main():
        \\    let a, b = minmax() catch 0, 0
        \\
    , "luce.parse.assign", "catch can supply only one value: write try, or handle it as a statement");
}

test "luce.parse.assign: multi-return assignment has bare names, one equals, and one call" {
    try expectSaying(
        \\func main():
        \\    var point = Point(x = 1)
        \\    var other = 0
        \\    point.x, other = pair()
        \\
    , "luce.parse.assign", "multi-return assignment targets bare var names, not fields or indexes");

    try expectSaying(
        \\func main():
        \\    var xs = [1]
        \\    var other = 0
        \\    other, xs[0] = pair()
        \\
    , "luce.parse.assign", "multi-return assignment targets bare var names, not fields or indexes");

    try expectSaying(
        \\func main():
        \\    var left = 1
        \\    var right = 2
        \\    left, right += pair()
        \\
    , "luce.parse.assign", "multi-return assignment has no compound form");

    try expectSaying(
        \\func main():
        \\    var left = 1
        \\    var right = 2
        \\    left, right = 3, 4
        \\
    , "luce.parse.assign", "multi-return assignment takes one call on the right");

    try expectSaying(
        \\func main():
        \\    var left = 1
        \\    left, _ = pair()
        \\
    , "luce.parse.assign", "_ is the array-shape wildcard, not an assignment target");
}

test "luce.parse.type: a destructuring bind takes its types from the call" {
    try expectSaying(
        \\func minmax() -> (i64, i64):
        \\    return 1, 2
        \\
        \\func main():
        \\    let low: i64, high: i64 = minmax()
        \\
    , "luce.parse.type", "a destructuring bind takes its types from the call");
}

test "luce.sema.shape: the bind's arity is the call's" {
    try expectSaying(
        \\func minmax() -> (i64, i64):
        \\    return 1, 2
        \\
        \\func main():
        \\    let a, b, c = minmax()
        \\
    , "luce.sema.shape", "minmax answers 2 values, got 3 names");

    // One value, two names: the call is named, because that is what
    // makes the sentence actionable.
    try expectSaying(
        \\func one() -> i64:
        \\    return 1
        \\
        \\func main():
        \\    let a, b = one()
        \\
    , "luce.sema.shape", "one answers 1 value, got 2 names");

    try expectSaying(
        \\func pair() -> (i64, i64):
        \\    return 1, 2
        \\
        \\func main():
        \\    var a = 0
        \\    var b = 0
        \\    var c = 0
        \\    a, b, c = pair()
        \\
    , "luce.sema.shape", "pair answers 2 values, got 3 names");

    try expectSaying(
        \\func one() -> i64:
        \\    return 1
        \\
        \\func main():
        \\    var a = 0
        \\    var b = 0
        \\    a, b = one()
        \\
    , "luce.sema.shape", "one answers 1 value, got 2 names");
}

test "existing-name destructuring checks every target before replacing any" {
    try expectSaying(
        \\func pair() -> (i64, i64):
        \\    return 1, 2
        \\
        \\func main():
        \\    let fixed = 0
        \\    var other = 0
        \\    fixed, other = pair()
        \\
    , "luce.sema.let", "fixed is let-bound; use var for reassignment");

    try expectSaying(
        \\func pair() -> (i64, i64):
        \\    return 1, 2
        \\
        \\func main():
        \\    var other = 0
        \\    missing, other = pair()
        \\
    , "luce.sema.name", "unknown name missing");

    try expectSaying(
        \\func pair() -> (i64, i64):
        \\    return 1, 2
        \\
        \\func main():
        \\    var value = 0
        \\    value, value = pair()
        \\
    , "luce.sema.duplicate", "value is assigned twice in this statement");

    try expectSaying(
        \\func pair() -> (i64, str):
        \\    return 1, "two"
        \\
        \\func main():
        \\    var number: i64 = 0
        \\    var other = 0
        \\    number, other = pair()
        \\
    , "luce.sema.type", "other is i64, but value 2 from pair is str");

    try expectSaying(
        \\func pair() -> (i64, i64)!:
        \\    return 1, 2
        \\
        \\func main():
        \\    var left: i64 = 0
        \\    var right: i64 = 0
        \\    left, right = pair()
        \\
    , "luce.sema.fallible", "pair can fail: write 'try pair(");

    // The expression form of catch still supplies one value.  It
    // cannot synthesize a return shape; use the statement handler.
    try expectSaying(
        \\func pair() -> (i64, i64)!:
        \\    return 1, 2
        \\
        \\func main():
        \\    var left: i64 = 0
        \\    var right: i64 = 0
        \\    left, right = pair() catch 0
        \\
    , "luce.sema.call", "only a destructuring let, var, or assignment can receive them");
}

test "luce.sema.return: the return's arity is the signature's" {
    try expectSaying(
        \\func minmax() -> (i64, i64):
        \\    return 1
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.return", "minmax answers 2 values, got 1");

    try expectSaying(
        \\func count() -> i64:
        \\    return 1, 2
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.return", "count answers 1 value, got 2");

    try expectSaying(
        \\func nothing():
        \\    return 1, 2
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.return", "this function returns nothing");

    // Two shapes that disagree, which is the count this check is
    // actually about: the two cases above are each answered a step
    // earlier, by the arms that route a `return` to the single-value
    // channel or refuse a comma outright.
    try expectSaying(
        \\func minmax() -> (i64, i64):
        \\    return 1, 2, 3
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.return", "minmax answers 2 values, got 3");

    // And the same count inside a writing method: the implicit
    // receiver is separate from the declared return arity.
    try expectSaying(
        \\struct Rng:
        \\    state: i64
        \\
        \\    func next() -> i64:
        \\        return self.state, 1
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.return", "next answers 1 value, got 2");
}

test "luce.sema.call: a return shape is never an ordinary tuple value" {
    // An argument, an operand, a container element — and the
    // pass-through, which Go allows and this language does not,
    // because refusing it is what makes the rule have no exceptions.
    for ([_][]const u8{
        "func minmax() -> (i64, i64):\n    return 1, 2\n\nfunc main():\n    assert(minmax() == 1)\n",
        "func minmax() -> (i64, i64):\n    return 1, 2\n\nfunc main():\n    let x = minmax() + 1\n",
        "func minmax() -> (i64, i64):\n    return 1, 2\n\nfunc main():\n    var xs = [1]\n    xs.append(minmax())\n",
    }) |source| {
        try expectSaying(
            source,
            "luce.sema.call",
            "minmax answers 2 values, and only a destructuring let, var, or assignment can receive them",
        );
    }

    try expectSaying(
        \\func minmax() -> (i64, i64):
        \\    return 1, 2
        \\
        \\func pass() -> (i64, i64):
        \\    return minmax()
        \\
        \\func main():
        \\    return
        \\
    ,
        "luce.sema.call",
        "minmax answers 2 values, and only a destructuring let, var, or assignment can receive them — bind them, then return them",
    );
}

// ---------------------------------------------------------------------------
// Methods: implied `self`
// ---------------------------------------------------------------------------

test "luce.parse.self: an explicit receiver parameter is retired everywhere" {
    try expectSaying(
        \\func loose(self) -> i64:
        \\    return 1
        \\
        \\func main():
        \\    return
        \\
    , "luce.parse.self", "self is implied; remove the parameter");

    try expectSaying(
        \\struct Point:
        \\    x: i64
        \\
        \\    func grow(var self):
        \\        self.x += 1
        \\
        \\func main():
        \\    return
        \\
    , "luce.parse.self", "self is implied; remove the parameter");
}

test "luce.parse.static: self: static is only a struct or enum member modifier" {
    try expectSaying(
        \\static func helper() -> i64:
        \\    return 1
        \\
        \\func main():
        \\    return
        \\
    , "luce.parse.static", "static belongs before func inside a struct or enum");
}

test "luce.sema.self: a static member cannot read self" {
    try expectSaying(
        \\struct Point:
        \\    x: i64
        \\
        \\    static func read() -> i64:
        \\        return self.x
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.self", "self is unavailable in a static function; remove static to make this a method");
}

test "luce.sema.self: a static member is not callable through a value" {
    try expectSaying(
        \\struct Point:
        \\    x: i64
        \\
        \\    static func origin() -> Point:
        \\        return Point(x = 0)
        \\
        \\func main():
        \\    let p = Point(x = 1)
        \\    let q = p.origin()
        \\
    , "luce.sema.self", "origin is static and has no self; call it as Point.origin(");
}

test "luce.sema.self: a method is not callable through its type" {
    try expectSaying(
        \\struct Point:
        \\    x: i64
        \\
        \\    func read() -> i64:
        \\        return self.x
        \\
        \\func main():
        \\    let p = Point(x = 1)
        \\    let value = Point.read(p)
        \\
    , "luce.sema.self", "read is a method with implicit self; call it as p.read(");
}

test "luce.sema.method: a struct has no method by that name, and the closest one is offered" {
    try expectSaying(
        \\struct Point:
        \\    x: i64
        \\
        \\    func length() -> i64:
        \\        return self.x
        \\
        \\func main():
        \\    let p = Point(x = 1)
        \\    assert(p.lenght() == 1)
        \\
    ,
        "luce.sema.method",
        "Point has no method lenght; did you mean length?",
    );
    // With nothing close, the sentence still names both.
    try expectSaying(
        \\struct Point:
        \\    x: i64
        \\
        \\func main():
        \\    let p = Point(x = 1)
        \\    assert(p.frobnicate() == 1)
        \\
    ,
        "luce.sema.method",
        "Point has no method frobnicate",
    );
}

test "luce.sema.name: a method reference with no landing place is not a value" {
    try expectSaying(
        \\struct Point:
        \\    x: i64
        \\
        \\    func length() -> i64:
        \\        return self.x
        \\
        \\func main():
        \\    let f = p_of().length
        \\
        \\func p_of() -> Point:
        \\    return Point(x = 1)
        \\
    ,
        "luce.sema.name",
        "is a function; write",
    );
}

test "luce.sema.call: a writing method does not bind (BINDING.md D9)" {
    try expectSaying(
        \\struct Counter:
        \\    total: i64
        \\
        \\    func bump(by: i64):
        \\        self.total = self.total + by
        \\
        \\func apply(f: func(i64)):
        \\    f(1)
        \\
        \\func main():
        \\    var counter = Counter(total = 0)
        \\    apply(counter.bump)
        \\
    ,
        "luce.sema.call",
        "writes its receiver, and a writing method is not a function value",
    );
}

test "luce.sema.own: a function value does not cross a worker boundary (BINDING.md D4)" {
    try expectSaying(
        \\func twice(n: i64) -> i64:
        \\    return n * 2
        \\
        \\func work(f: func(i64) -> i64, n: i64) -> i64:
        \\    return f(n)
        \\
        \\func main():
        \\    let job = spawn work(twice, 21)
        \\    assert(job.wait() == 42)
        \\
    ,
        "luce.sema.own",
        "a function value borrows the receiver it may carry",
    );
}

test "luce.sema.own: a worker cannot answer a function value (BINDING.md D4)" {
    try expectSaying(
        \\func twice(n: i64) -> i64:
        \\    return n * 2
        \\
        \\func pick() -> func(i64) -> i64:
        \\    return twice
        \\
        \\func main():
        \\    let job = spawn pick()
        \\    let f = job.wait()
        \\    assert(f(21) == 42)
        \\
    ,
        "luce.sema.own",
        "a function value borrows the receiver it may carry",
    );
}

test "luce.sema.type: a function value has no equality (BINDING.md D6)" {
    try expectSaying(
        \\func up(a: i64, b: i64) -> bool:
        \\    return a < b
        \\
        \\func main():
        \\    let f: func(i64, i64) -> bool = up
        \\    let g: func(i64, i64) -> bool = up
        \\    assert(f == g)
        \\
    ,
        "luce.sema.type",
        "the function it names and the receiver it may carry",
    );
}

test "luce.sema.type: a bound value has no equality either (BINDING.md D6)" {
    try expectSaying(
        \\struct Scale:
        \\    factor: i64
        \\
        \\    func times(n: i64) -> i64:
        \\        return n * self.factor
        \\
        \\func main():
        \\    let two = Scale(factor = 2)
        \\    let three = Scale(factor = 3)
        \\    let f: func(i64) -> i64 = two.times
        \\    let g: func(i64) -> i64 = three.times
        \\    assert(f != g)
        \\
    ,
        "luce.sema.type",
        "different workers",
    );
}

test "luce.sema.method: searching a container of function values is equality too (BINDING.md D6)" {
    // `find` and `contains` are `==` under another spelling, and they
    // were accepted while `f == g` was refused: the search reached the
    // runtime's comparator, which has no sentence to say and answered
    // with its `unreachable` — a program the compiler took, crashing
    // in both engines.  The refusal is where the comparison is
    // written, and it names what to search instead.
    try expectSaying(
        \\func twice(n: i64) -> str:
        \\    return str(n * 2)
        \\
        \\func main():
        \\    var xs = new list[(func(i64) -> str)?]
        \\    xs.append(twice)
        \\    assert(xs.contains(twice))
        \\
    ,
        "luce.sema.method",
        "a function value has no equality",
    );
    try expectSaying(
        \\func twice(n: i64) -> str:
        \\    return str(n * 2)
        \\
        \\func main():
        \\    var cells = new array[(func(i64) -> str)?](2)
        \\    cells.fill(twice)
        \\    let at = cells.find(twice)
        \\
    ,
        "luce.sema.method",
        "a function value has no equality",
    );
}

// ---------------------------------------------------------------------------
// What a comparison reaches, not what its outermost tag says
// ---------------------------------------------------------------------------
//
// Three refusals were written as `type == .function` or
// `type == .variant` where the honest question is *what does comparing
// this value reach* — and a struct's `==` is field-by-field `==`, so a
// wrapper was all it took to walk past every one of them.  Each of the
// three programs below compiled, and each panicked the runtime from
// ordinary source: a union's payload run has a different length on each
// arm, so `Cell == Cell` walked two slices of unequal length, and a
// stored function value reached a comparator whose `.function` arm is
// `unreachable` because there is no honest answer to give.  One walk
// answers for all three now (`semantics/shapes.zig`'s
// `incomparablePart`), and it stops where `==` stops.

test "luce.sema.union: a struct carrying a union is not compared either (UNION.md D16)" {
    // `==` on a union is refused because `match` is the only door into
    // one.  A struct's `==` *is* field-by-field `==`, so comparing a
    // struct that holds one asks exactly the refused question through a
    // wrapper — and answered it by walking the inactive payload slot,
    // whose shape differs per arm.  With a `Point` on one side and a
    // `long` on the other that is two runs of different lengths: a
    // panic in a checked build, a read off the end of a slice in an
    // unchecked one.
    try expectSaying(
        \\struct Point:
        \\    x: i64
        \\    y: i64
        \\
        \\union Shape:
        \\    at(p: Point)
        \\    count(n: i64)
        \\
        \\struct Cell:
        \\    what: Shape
        \\
        \\func main():
        \\    let a = Cell(what = Shape.at(p = Point(x = 1, y = 2)))
        \\    let b = Cell(what = Shape.count(n = 3))
        \\    assert(a == b)
        \\
    ,
        "luce.sema.union",
        "match is the only door into one",
    );
    // The same refusal one level deeper, and with both payloads the
    // same width — so nothing about it depends on the run lengths
    // happening to differ.  This is the shape that answered "different"
    // rather than crashing, which is the worse of the two failures: a
    // program that quietly compares an inactive slot.
    try expectSaying(
        \\union Shape:
        \\    circle(radius: f64)
        \\    square(side: f64)
        \\
        \\struct Box:
        \\    s: Shape
        \\
        \\struct Crate:
        \\    b: Box
        \\
        \\func main():
        \\    let a = Crate(b = Box(s = Shape.circle(radius = 1.0)))
        \\    let b = Crate(b = Box(s = Shape.square(side = 1.0)))
        \\    assert(a != b)
        \\
    ,
        "luce.sema.union",
        "match is the only door into one",
    );
}

test "luce.sema.type: a struct carrying a function value is not compared either (BINDING.md D6)" {
    // D7 blesses `(func(...) -> R)?` as a struct field, and D6 refuses
    // `==` on a function value — but the refusal asked the operand's
    // own tag, so the field shape D7 exists to allow walked straight
    // past it into the runtime comparator's `unreachable`.
    try expectSaying(
        \\func twice(n: i64) -> i64:
        \\    return n * 2
        \\
        \\struct Button:
        \\    label: str
        \\    on_click: (func(i64) -> i64)?
        \\
        \\func main():
        \\    let a = Button(label = "ok", on_click = twice)
        \\    let b = Button(label = "ok", on_click = twice)
        \\    assert(a == b)
        \\
    ,
        "luce.sema.type",
        "a function value has no equality",
    );
    // Two levels deeper, so the walk is a walk and not one hop.
    try expectSaying(
        \\func twice(n: i64) -> i64:
        \\    return n * 2
        \\
        \\struct Button:
        \\    on_click: (func(i64) -> i64)?
        \\
        \\struct Row:
        \\    b: Button
        \\
        \\struct Panel:
        \\    r: Row
        \\
        \\func main():
        \\    let a = Panel(r = Row(b = Button(on_click = twice)))
        \\    assert(a == a)
        \\
    ,
        "luce.sema.type",
        "a function value has no equality",
    );
}

test "luce.sema.method: a search asks what the element reaches, not what it is" {
    // `find` and `contains` are `==` under another spelling, so they
    // refuse exactly what `==` refuses — which stopped being true the
    // moment the element was a struct rather than the function value
    // itself.  A struct in a list is one level; a struct in a list in a
    // struct is the level that proves the walk.
    try expectSaying(
        \\func twice(n: i64) -> i64:
        \\    return n * 2
        \\
        \\struct Button:
        \\    label: str
        \\    on_click: (func(i64) -> i64)?
        \\
        \\func main():
        \\    var xs = new list[Button]
        \\    xs.append(Button(label = "ok", on_click = twice))
        \\    assert(xs.contains(Button(label = "ok", on_click = twice)))
        \\
    ,
        "luce.sema.method",
        "a function value has no equality",
    );
    try expectSaying(
        \\func twice(n: i64) -> i64:
        \\    return n * 2
        \\
        \\struct Button:
        \\    on_click: (func(i64) -> i64)?
        \\
        \\struct Row:
        \\    b: Button
        \\
        \\func main():
        \\    var rows = new list[Row]
        \\    rows.append(Row(b = Button(on_click = twice)))
        \\    let at = rows.find(Row(b = Button(on_click = twice)))
        \\
    ,
        "luce.sema.method",
        "a function value has no equality",
    );
    // A union element is the other half of the same rule: `match` is
    // the only door, so a container of unions cannot be searched — as
    // an element, and as a field of one.
    try expectSaying(
        \\union Shape:
        \\    circle(radius: f64)
        \\    square(side: f64)
        \\
        \\func main():
        \\    var xs = new list[Shape]
        \\    xs.append(Shape.circle(radius = 1.0))
        \\    assert(xs.contains(Shape.square(side = 2.0)))
        \\
    ,
        "luce.sema.method",
        "match is the only door into one",
    );
    try expectSaying(
        \\union Shape:
        \\    circle(radius: f64)
        \\    square(side: f64)
        \\
        \\struct Box:
        \\    s: Shape
        \\
        \\func main():
        \\    var xs = new list[Box]
        \\    xs.append(Box(s = Shape.circle(radius = 1.0)))
        \\    assert(xs.contains(Box(s = Shape.square(side = 2.0))))
        \\
    ,
        "luce.sema.method",
        "match is the only door into one",
    );
}

test "luce.sema.type: len measures a container, and a resource is not one" {
    // The gate admitted every `.heap` type while the sentence under it
    // listed five, and the two the sentence left out are exactly the
    // two with no length.  `len(spawn work())` type-checked, passed the
    // MIR verifier, and reached a runtime switch whose file/task arm is
    // `unreachable` — the predicate and its own message disagreeing,
    // which is the whole bug.
    try expectSaying(
        \\func work() -> i64:
        \\    return 1
        \\
        \\func main():
        \\    let t = spawn work()
        \\    assert(len(t) == 0)
        \\
    ,
        "luce.sema.type",
        "is a resource, not a container, and has no length",
    );
    try expectHostSaying(
        \\func main() -> !:
        \\    let f = try file_open("/tmp/luce-len-of-a-file", 1)
        \\    assert(len(f) == 0)
        \\
    ,
        "luce.sema.type",
        "is a resource, not a container, and has no length",
    );
}

test "luce.sema.type: values() of a map of function values is refused (BINDING.md D7)" {
    // A map value is the one slot written bare, because `get` already
    // answers `V?` — so `map(string, func(long) -> long)` is legal
    // while `list(func(long) -> long)` is a type no program can write.
    // `values()` manufactured one anyway: `luce check` said ok and
    // `luce build` aborted the compiler with no diagnostic at all,
    // because a list cell has no shape for a bare function value.
    try expectSaying(
        \\func twice(n: i64) -> i64:
        \\    return n * 2
        \\
        \\func main():
        \\    var m = new map[str, func(i64) -> i64]
        \\    m["a"] = twice
        \\    let vs = m.values()
        \\    assert(len(vs) == 1)
        \\
    ,
        "luce.sema.type",
        "a bare function type is not a list element",
    );
}

test "luce.sema.type: a member constructor whose shape does not fit the place is refused (BINDING.md D11)" {
    try expectSaying(
        \\union Msg:
        \\    quit
        \\    query_changed(query: str)
        \\
        \\func apply(f: func(i64) -> Msg) -> Msg:
        \\    return f(1)
        \\
        \\func main():
        \\    assert(apply(Msg.query_changed) == Msg.quit)
        \\
    ,
        "luce.sema.type",
        "and Msg.query_changed is func(str) -> Msg",
    );
}

test "luce.sema.type: a bind whose shape does not fit the place is refused" {
    try expectSaying(
        \\struct Scale:
        \\    factor: i64
        \\
        \\    func times(n: i64) -> i64:
        \\        return n * self.factor
        \\
        \\func apply(f: func(i64, i64) -> i64) -> i64:
        \\    return f(1, 2)
        \\
        \\func main():
        \\    let doubling = Scale(factor = 2)
        \\    assert(apply(doubling.times) == 2)
        \\
    ,
        "luce.sema.type",
        "bound is",
    );
}

test "luce.sema.fallible: a fallible method does not bind yet (BINDING.md D8)" {
    try expectSaying(
        \\struct Reader:
        \\    at: i64
        \\
        \\    func value(n: i64) -> i64!:
        \\        if n < 0:
        \\            error("negative")
        \\        return n + self.at
        \\
        \\func apply(f: func(i64) -> i64) -> i64:
        \\    return f(1)
        \\
        \\func main():
        \\    let reader = Reader(at = 1)
        \\    assert(apply(reader.value) == 2)
        \\
    ,
        "luce.sema.fallible",
        "a fallible method is not a value yet",
    );
}

test "luce.sema.self: a writer needs a bare var receiver" {
    try expectSaying(
        \\struct Point:
        \\    x: i64
        \\
        \\    func grow():
        \\        self.x = self.x + 1
        \\
        \\func main():
        \\    let q = Point(x = 1)
        \\    q.grow()
        \\
    , "luce.sema.let", "q is let-bound; grow writes its implicit self — use var");

    try expectSaying(
        \\struct Point:
        \\    x: i64
        \\
        \\    static func origin() -> Point:
        \\        return Point(x = 0)
        \\
        \\    func grow():
        \\        self.x = self.x + 1
        \\
        \\func main():
        \\    Point.origin().grow()
        \\
    , "luce.sema.self", "grow writes its implicit self, so its receiver must be a var binding — not a call result or temporary");

    for ([_][]const u8{
        "holder.point.grow()",
        "points[0].grow()",
    }) |call| {
        const source = try std.fmt.allocPrint(std.testing.allocator,
            \\struct Point:
            \\    x: i64
            \\
            \\    func grow():
            \\        self.x += 1
            \\
            \\struct Holder:
            \\    point: Point
            \\
            \\func main():
            \\    var holder = Holder(point = Point(x = 1))
            \\    var points = [Point(x = 1)]
            \\    {s}
            \\
        , .{call});
        defer std.testing.allocator.free(source);
        try expectSaying(source, "luce.sema.self", "grow writes its implicit self, so its receiver must be a var binding");
    }
}

test "luce.sema.self: an optional narrowing is not a receiver place" {
    try expectSaying(
        \\struct Point:
        \\    x: i64
        \\
        \\    func grow():
        \\        self.x += 1
        \\
        \\func chosen() -> Point?:
        \\    return Point(x = 1)
        \\
        \\func main():
        \\    var maybe = chosen()
        \\    if maybe != none:
        \\        maybe.grow()
        \\
    , "luce.sema.self", "narrowed value is not a writable receiver — bind a var Point first");
}

test "luce.sema.self: the receiver is separate from declared return values" {
    try expectSaying(
        \\struct Rng:
        \\    state: i64
        \\
        \\    func next() -> i64:
        \\        self.state = self.state + 1
        \\        return self.state
        \\
        \\func main():
        \\    var rng = Rng(state = 1)
        \\    let receiver, roll = rng.next()
        \\
    , "luce.sema.shape", "next answers 1 value, got 2 names");
}

test "luce.sema.method: a missing method argument is named, without the receiver" {
    try expectSaying(
        \\struct Point:
        \\    x: i64
        \\
        \\    func moved(dx: i64, dy: i64) -> i64:
        \\        return self.x + dx + dy
        \\
        \\func main():
        \\    let p = Point(x = 1)
        \\    assert(p.moved(1) == 1)
        \\
    ,
        "luce.sema.method",
        "moved is missing dy",
    );
}

test "luce.sema.method: a method checks its arity against its written parameters" {
    try expectSaying(
        \\struct Point:
        \\    x: i64
        \\
        \\    func moved(dx: i64, dy: i64) -> i64:
        \\        return self.x + dx + dy
        \\
        \\func main():
        \\    let p = Point(x = 1)
        \\    assert(p.moved(1, 2, 3) == 1)
        \\
    ,
        "luce.sema.method",
        "moved takes 2 arguments, got 3",
    );
}

test "luce.sema.call: self: reader and writer methods are not function values" {
    try expectSaying(
        \\struct Point:
        \\    x: i64
        \\
        \\    func read() -> i64:
        \\        return self.x
        \\
        \\func main():
        \\    let f: func(Point) -> i64 = Point.read
        \\
    , "luce.sema.call", "a method reference would carry its receiver; write a lambda that takes the receiver");

    try expectSaying(
        \\struct Point:
        \\    x: i64
        \\
        \\    func grow() -> i64:
        \\        self.x += 1
        \\        return self.x
        \\
        \\func main():
        \\    let f: func(Point) -> i64 = Point.grow
        \\
    , "luce.sema.call", "writes its implicit self and is not a function value; move the operation into a top-level or static function");
}

test "luce.sema.name: self: a lambda cannot capture the implicit receiver" {
    try expectSaying(
        \\struct Point:
        \\    x: i64
        \\
        \\    func read() -> i64:
        \\        let f: func() -> i64 = () -> self.x
        \\        return f()
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.name", "a lambda carries no environment, and self belongs to the scope around it");
}

// ---------------------------------------------------------------------------
// Entry contract
// ---------------------------------------------------------------------------

test "luce.sema.main: a script needs func main(), with or without the command line" {
    try expectRejected("func other():\n    return\n", "luce.sema.main");
    try expectRejected("func main(x: i64):\n    return\n", "luce.sema.main");
}

// "script entry must be exactly func main():" was not true —
// `func main() -> !:` is legal and `examples/dice/dice.luc` writes it, as
// the comment three lines above the message said.  It also answered
// two different mistakes with one sentence, and pointed at `func main`
// rather than at the part that is wrong.

test "luce.sema.main: a return type on the entry names the other legal form" {
    try expectOnlySayingAt(
        \\func main() -> i64:
        \\    return 1
        \\
    ,
        "luce.sema.main",
        "main returns nothing; use func main():, func main() -> !:, func main(args: list[str]):, or func main(args: list[str]) -> !:",
        1,
        16,
    );
}

// The entry's parameter is the command line and its type is fixed
// (docs/LANGUAGE.md).  The name is free — `args` is a binding like any
// other — so there is no misspelling of it to diagnose, and the three
// mistakes that are left get one sentence each and a caret on the part
// that is wrong.

test "luce.sema.main: the entry's parameter is the command line and must be list[str]" {
    try expectOnlySayingAt(
        \\func main(n: i64):
        \\    return
        \\
    ,
        "luce.sema.main",
        "main's parameter is the command line and must be list[str]; it is i64 here",
        1,
        14,
    );
    // A list of the wrong thing is the same mistake and says so with
    // the type it was actually given.
    try expectSaying(
        \\func main(xs: list[i64]):
        \\    return
        \\
    ,
        "luce.sema.main",
        "main's parameter is the command line and must be list[str]; it is list[i64] here",
    );
}

test "luce.sema.main: the entry takes at most the one parameter" {
    try expectOnlySayingAt(
        \\func main(a: list[str], b: i64):
        \\    return
        \\
    ,
        "luce.sema.main",
        "main takes at most one parameter, the command line; it has 2",
        1,
        25,
    );
}

test "luce.sema.retired: arg and arg_count name their replacement" {
    // A name the language used to spell is not a typo, and the site
    // still teaches the old one; a bare `unknown function arg` points
    // nowhere.  One release of a pointer (docs/LANGUAGE.md).
    try expectHostSaying(
        \\func main():
        \\    print(arg(0))
        \\
    ,
        "luce.sema.retired",
        "arg was retired: declare func main(args: list[str]): and index args",
    );
    try expectHostSaying(
        \\func main():
        \\    print(str(arg_count()))
        \\
    ,
        "luce.sema.retired",
        "arg_count was retired: declare func main(args: list[str]): and write len(args)",
    );
}

test "arg is an ordinary word again, and a program that declares one gets its own" {
    // The retirement message is reached only once nothing else
    // resolved: the two names left `reserved_names` with the builtins,
    // so they are available to a program like any other.
    var result = try compile_mod.compile(testing.allocator,
        \\func arg(index: i64) -> i64:
        \\    return index * 2
        \\
        \\func main():
        \\    let arg_count = arg(3)
        \\    assert(arg_count == 6)
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

test "luce.sema.main: all four legal entry shapes compile" {
    // `-> !:` is how a program says the world can stop it, and the
    // command line composes with it (docs/LANGUAGE.md).  The parameter's
    // name is the program's to choose.
    for ([_][]const u8{
        "func main():\n    return\n",
        "func main() -> !:\n    return\n",
        "func main(args: list[str]):\n    return\n",
        "func main(command_line: list[str]) -> !:\n    return\n",
    }) |source| {
        var result = try compile_mod.compile(testing.allocator, source, script);
        defer result.deinit();
        switch (result) {
            .success => {},
            .failure => |diagnostics| {
                std.debug.print("this should compile:\n{s}", .{source});
                printAll(&diagnostics);
                return error.TestUnexpectedResult;
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Compound assignment (value-only arithmetic sugar)
// ---------------------------------------------------------------------------

test "luce.sema.type: compound assignment is numbers, or += on string" {
    // Objects have no compound assignment.
    try expectRejected("func main():\n    var xs = [1, 2]\n    xs *= 3\n", "luce.sema.type");
    // Non-+ operators do not apply to string.
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
// A function **is** a value where a function type is expected
// (docs/FUNCTIONS.md S1), so what is left here is a bare name where
// nothing said which shape it should wear — and the compiler checked
// the declaration moments earlier, so answering "unknown name math"
// about an import on line 1 sends the reader to look for a missing
// import that is right there.  Every one of these used to do exactly
// that.

test "luce.sema.name: a function used as a value is named, not denied" {
    try expectOnlySayingAt(
        \\func helper() -> i64:
        \\    return 1
        \\
        \\func main():
        \\    let f = helper
        \\
    ,
        "luce.sema.name",
        "helper is a function; write helper(...) to call it, or annotate the place it goes with the function type it should wear [FUNCTIONS.md]",
        5,
        13,
    );
}

test "luce.sema.name: a struct used as a value says how to build one" {
    try expectOnlySayingAt(
        \\struct Point:
        \\    x: i64
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
        "math.round is a function; write math.round(...) to call it, or annotate the place it goes with the function type it should wear [FUNCTIONS.md]",
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
        \\    count: i64
        \\
        \\    static func classify() -> i64:
        \\        return 1
        \\
        \\func main():
        \\    let f = Words.classify
        \\
    ,
        "luce.sema.name",
        "Words.classify is a function; write Words.classify(...) to call it, or annotate the place it goes with the function type it should wear [FUNCTIONS.md]",
        8,
        13,
    );
}

test "luce.sema.name: a struct namespace with no such member says so" {
    try expectOnlySayingAt(
        \\struct Words:
        \\    count: i64
        \\
        \\    static func classify() -> i64:
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

// Where the other one is, is the single most useful thing a duplicate
// message can carry, and none of the four spellings carried anything.

test "luce.sema.duplicate: a duplicate struct points at the first" {
    try expectOnlySayingAt(
        \\struct P:
        \\    x: i64
        \\
        \\struct P:
        \\    y: i64
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.duplicate", "duplicate name P; the first is on line 1", 4, 8);
}

test "luce.sema.duplicate: a duplicate field points at the first" {
    try expectOnlySayingAt(
        \\struct S:
        \\    x: i64
        \\    y: i64
        \\    x: i64
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.duplicate", "duplicate field x; the first is on line 2", 4, 5);
}

test "luce.sema.duplicate: a duplicate function points at the first" {
    try expectOnlySayingAt(
        \\func go():
        \\    return
        \\
        \\func go():
        \\    return
        \\
        \\func main():
        \\    go()
        \\
    , "luce.sema.duplicate", "duplicate name go; the first is on line 1", 4, 6);
}

test "luce.sema.duplicate: a duplicate constant points at the first" {
    try expectOnlySayingAt(
        \\const k = 1
        \\
        \\const k = 2
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.duplicate", "duplicate name k; the first is on line 1", 3, 7);
}

test "luce.sema.duplicate: a redeclared local points at the first" {
    try expectOnlySayingAt(
        \\func main():
        \\    let n = 1
        \\    let n = 2
        \\    return
        \\
    , "luce.sema.duplicate", "n is already declared on line 2", 3, 9);
}

test "luce.sema.duplicate: a lambda parameter cannot shadow an enclosing local" {
    try expectSaying(
        \\func main():
        \\    let n = 10
        \\    let chosen: func(i64) -> i64 = (n) -> n + 1
        \\
    , "luce.sema.duplicate", "n is already declared on line 2");

    // The same lexical scope survives a synthesized lambda in between:
    // an inner parameter cannot shadow a grandparent local merely
    // because the middle lambda has been lifted to the function table.
    try expectSaying(
        \\func apply(f: func(i64) -> i64, x: i64) -> i64:
        \\    return f(x)
        \\
        \\func main():
        \\    let n = 10
        \\    let nested: func(i64) -> i64 = (x) -> apply((n) -> n + 1, x)
        \\
    , "luce.sema.duplicate", "n is already declared on line 5");
}

test "luce.sema.duplicate: a local over a declaration says which kind, and where" {
    try expectOnlySayingAt(
        \\func helper():
        \\    return
        \\
        \\func main():
        \\    let helper = 1
        \\    return
        \\
    , "luce.sema.duplicate", "helper is already a top-level declaration on line 1", 5, 9);
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

// The mismatch message ends with a fact, not with advice.  It used to
// offer one particular conversion. Concrete numeric conversions are
// explicit now, while unrelated types genuinely have no conversion.

test "luce.sema.type: a mismatch with no conversion says so" {
    try expectOnlySayingAt(
        \\func main():
        \\    let a = 1
        \\    let b = "s"
        \\    let c = a + b
        \\
    ,
        "luce.sema.type",
        "operands of + are i64 and str, and there is no conversion between them",
        4,
        13,
    );
}

test "luce.sema.type: an annotation says so when nothing converts" {
    try expectOnlySayingAt(
        "func main():\n    let s: str = 1\n",
        "luce.sema.type",
        "s declared str but initialized with i64, and there is no conversion between them",
        2,
        5,
    );
}

// Integer division always answers f64. It cannot be stored back into an
// integer place without choosing integer division or converting it.

test "luce.sema.type: n /= 2 on an int place names the one-character fix" {
    // The migration's sharpest edge (docs/NUMERICS.md §9): `/` answers
    // a double, so this is a narrowing nobody wrote.  That it is an
    // error rather than a silent truncation is the whole safety story.
    try expectOnlySayingAt(
        \\func main():
        \\    var n = 10
        \\    n /= 2
        \\
    ,
        "luce.sema.type",
        "/ answers f64 and this place is i64; write '//=' for the integer quotient",
        3,
        5,
    );
}

test "luce.sema.type: n /= 2 on a long place says the same thing" {
    // The guard is per-width or it is nothing: naming one integer
    // type and letting the other through would leave `/=` silently
    // truncating at exactly the width the resize made the default.
    try expectOnlySayingAt(
        \\func main():
        \\    var n: i64 = 10
        \\    n /= 2
        \\
    ,
        "luce.sema.type",
        "/ answers f64 and this place is i64; write '//=' for the integer quotient",
        3,
        5,
    );
}

test "luce.sema.type: a double where a long is required is still refused" {
    try expectRejectedAt(
        \\func take(n: i64) -> i64:
        \\    return n
        \\
        \\func main():
        \\    let x = 2.5
        \\    let bad = take(x)
        \\
    , "luce.sema.type", 6, 20);
    try expectRejected(
        \\func main():
        \\    var n = 10
        \\    n += 1.5
        \\
    , "luce.sema.type");
    try expectRejected(
        \\func main():
        \\    let n: i64 = 2.5
        \\
    , "luce.sema.type");
}

// The two sentences the ladder made necessary, pinned to the word and
// the column (docs/TYPES.md §11).  Both are about a *place*: the first
// says a literal did not fit the one it landed on and names the width
// that would hold it, the second says a value did not fit and names
// the constructor that would put it there.  A width mistake is the one
// kind of mistake seven types create that two did not, so these are
// the messages the whole change is judged by.

test "luce.sema.literal: an integer past an int names the width that holds it" {
    try expectOnlySayingAt(
        \\func main():
        \\    var n: i32 = 3000000000
        \\
    ,
        "luce.sema.literal",
        "integer literal out of range; i32 holds -2147483648 to 2147483647 — write the place as i64",
        2,
        18,
    );
    // And at the top of the ladder there is no wider place to name, so
    // the sentence stops after the range rather than offering one.
    try expectOnlySayingAt(
        \\func main():
        \\    var n: i64 = 99223372036854775808
        \\
    ,
        "luce.sema.literal",
        "integer literal out of range; i64 holds -9223372036854775808 to 9223372036854775807",
        2,
        18,
    );
}

test "luce.sema.literal: a float past a float names the width that holds it" {
    try expectOnlySayingAt(
        \\func main():
        \\    var x: f32 = 1.0e300
        \\
    ,
        "luce.sema.literal",
        "float literal is not a finite f32; f32 holds up to about 3.4e38 — write the place as f64",
        2,
        18,
    );
    try expectOnlySayingAt(
        \\func main():
        \\    var x: f64 = 1.0e400
        \\
    ,
        "luce.sema.literal",
        "float literal is not a finite number; f64 holds up to about 1.8e308",
        2,
        18,
    );
}

test "luce.sema.type: a refused narrowing names the constructor that would do it" {
    // The tail used to say "and there is no conversion between them",
    // which was true when `long` against `double` was the only
    // mismatch a constructor could repair and is false the moment
    // there is a ladder: there *is* a conversion, and what Luce
    // refuses is performing it unasked.
    try expectOnlySayingAt(
        \\func main():
        \\    var wide: i64 = 5
        \\    var narrow: i32 = wide
        \\
    ,
        "luce.sema.type",
        "narrow declared i32 but initialized with i64; narrowing is never implicit — write i32(…)",
        3,
        5,
    );
    try expectOnlySayingAt(
        \\func main():
        \\    var wide: f64 = 0.5
        \\    var narrow: f32 = wide
        \\
    ,
        "luce.sema.type",
        "narrow declared f32 but initialized with f64; narrowing is never implicit — write f32(…)",
        3,
        5,
    );
    // A pair with genuinely nothing between it still says so, so the
    // two sentences stay distinguishable.
    try expectOnlySayingAt(
        \\func main():
        \\    var s: str = 1
        \\
    ,
        "luce.sema.type",
        "s declared str but initialized with i64, and there is no conversion between them",
        2,
        5,
    );
}

test "luce.sema.type: a narrowing argument earns the same sentence" {
    try expectOnlySayingAt(
        \\func take(n: i32) -> i32:
        \\    return n
        \\
        \\func main():
        \\    var wide: i64 = 5
        \\    let bad = take(wide)
        \\
    ,
        "luce.sema.type",
        "argument 1 of take is i32, got i64; narrowing is never implicit — write i32(…)",
        6,
        20,
    );
}

test "luce.sema.type: a percent formatting mistake names f-strings" {
    try expectSaying(
        \\func main():
        \\    let name = "world"
        \\    let text = "hello %s" % name
        \\    print(text)
        \\
    , "luce.sema.type", "str does not support '%'; use an f-string");
}

// A conversion the constant folder performs is the *same* conversion
// the runtime would, per width and at the same boundary — a fold that
// disagrees with a run is a different language (docs/TYPES.md §3).
// Both of these are refused at compile time where the run would trap
// `conversion_range`, which is the only difference between them.

test "luce.sema.const: a folded narrowing is range-checked at its own width" {
    try expectOnlySayingAt(
        \\const wide: i64 = 3000000000
        \\const narrowed = i32(wide)
        \\
        \\func main():
        \\    print(str(narrowed))
        \\
    , "luce.sema.const", "constant conversion out of range", 2, 18);
    // One below the top fits, so the check is the boundary and not a
    // refusal of the whole conversion.
    try expectCompiles(
        \\const wide: i64 = 2147483647
        \\const narrowed = i32(wide)
        \\
        \\func main():
        \\    print(str(narrowed))
        \\
    );
}

test "luce.sema.const: a folded f32-to-integer is range-checked at its own width" {
    try expectOnlySayingAt(
        \\const big: f64 = 3.0e9
        \\const narrowed = i32(big)
        \\
        \\func main():
        \\    print(str(narrowed))
        \\
    , "luce.sema.const", "constant conversion out of range", 2, 18);
    // The same value reaches a `long` without complaint, which is what
    // makes the message above a statement about the width rather than
    // about the number.
    try expectCompiles(
        \\const big: f64 = 3.0e9
        \\const widened = i64(big)
        \\
        \\func main():
        \\    print(str(widened))
        \\
    );
}

// `and`/`or` used to underline both operands and name neither, in a
// compiler where `condition must be bool, not long` already did both.
//
// The left-operand case pins its *end* as well as its start, because
// those are the same column here: `n and true` and `n` both begin at
// column 8, so only the width tells the narrowed span from the whole
// expression it was narrowed out of.

test "luce.sema.type: a bad left operand of and is named, and underlined alone" {
    try expectOnlySayingAcross(
        \\func main():
        \\    let n = 1
        \\    if n and true:
        \\        return
        \\
    , "luce.sema.type", "the left operand of and must be bool, not i64", 3, 8, 9);
}

test "luce.sema.type: a bad left operand of or is named, and underlined alone" {
    // `total + 1` as the left operand: the underline stops at the end
    // of the operand, not at the end of the condition.
    try expectOnlySayingAcross(
        \\func main():
        \\    let total = 1
        \\    if total + 1 or false:
        \\        return
        \\
    , "luce.sema.type", "the left operand of or must be bool, not i64", 3, 8, 17);
}

test "luce.sema.type: a bad right operand of or is named, and underlined alone" {
    try expectOnlySayingAcross(
        \\func main():
        \\    let n = 1
        \\    if true or n:
        \\        return
        \\
    , "luce.sema.type", "the right operand of or must be bool, not i64", 3, 16, 17);
}

test "luce.sema.absent: a type name takes no article" {
    // Was "n is i64, and an i64 is always there; only an i64? is ever
    // none" — twice ungrammatical, and tautological besides.
    try expectOnlySayingAt(
        "func main():\n    let n: i64 = none\n",
        "luce.sema.absent",
        "n is i64, which is always there; only i64? is ever none",
        2,
        18,
    );
}

test "luce.sema.return: a returned type takes no article either" {
    try expectOnlySayingAt(
        \\func f() -> i64:
        \\    return
        \\
        \\func main():
        \\    let x = f()
        \\
    , "luce.sema.return", "return needs a value of type i64", 2, 5);
}

// `//` is floor division, and the message that used to greet a
// C-style comment was spent buying that spelling (docs/NUMERICS.md
// §3).  It is not gone: prefix position is where the comment reading
// is unambiguous — an operator with nothing on its left cannot be
// arithmetic — and that is where a `// comment` is written every
// time.  With a left operand it is division, and meant to be.

test "luce.parse.comment: a line that starts with // is told what // is" {
    try expectOnlySayingAt(
        \\func main():
        \\    // this is a comment
        \\    print("hi")
        \\
    ,
        "luce.parse.comment",
        "'//' is floor division and needs a number on its left; a comment starts with '#'",
        2,
        5,
    );
}

// One spec form, and the message names it (docs/NUMERICS.md §8).  The
// `f` is redundant and required anyway: `{x:.2}` means two
// *significant digits* in Python, and letting it mean two decimal
// places here would be a silent divergence from the language Luce is
// shaped after.

test "luce.parse.fstring: an unknown format spec names the one that exists" {
    try expectOnlySayingAt(
        \\import std.strings
        \\
        \\func main():
        \\    let x = 1.5
        \\    print(f"{x:.2}")
        \\
    ,
        "luce.parse.fstring",
        "unknown format spec ':.2'; the one form is ':.Nf' — N decimal places of an f64",
        5,
        15,
    );
    try expectRejected(
        \\import std.strings
        \\
        \\func main():
        \\    let x = 1.5
        \\    print(f"{x:8.2f}")
        \\
    , "luce.parse.fstring");
    try expectRejected(
        \\import std.strings
        \\
        \\func main():
        \\    let x = 1.5
        \\    print(f"{x:%.2f}")
        \\
    , "luce.parse.fstring");
}

test "luce.sema.import: a format spec is std.strings, and says so" {
    // It lowers to `strings.format_float`, so it needs the import that
    // every other string service needs — the same rule, not a new one.
    //
    // The rule was always right and the words were not: this said
    // "unknown namespace strings; import std.strings to use it",
    // naming a namespace that appears nowhere in the program, under a
    // caret inside an f-string hole.  A reader who never wrote
    // `strings.` cannot act on that.  Pinned in full and to the
    // column, because the substring this used to assert
    // ("import std.strings") was true of the wrong sentence too.
    try expectHostSayingAt(
        \\func main():
        \\    let x = 1.5
        \\    print(f"{x:.2f}")
        \\
    ,
        "luce.sema.import",
        "a format spec like {x:.2f} formats through std.strings; add import std.strings",
        3,
        14,
    );
    // The namespace form a reader *did* write keeps the original
    // words; that arm needs a loaded-but-unimported sibling, so its
    // control lives with the multi-file harness in
    // `compile/test.zig` ("imports are explicit, checked, and
    // reported per file").
}

test "luce.sema.convert: string() names its value domain and build() for a builder" {
    // The one reason `str` could not simply be renamed: it took a heap
    // object, and a scalar constructor should not (docs/NUMERICS.md §7).
    try expectOnlySayingAt(
        \\func main():
        \\    var b = new builder
        \\    b.append("x")
        \\    let text = str(b)
        \\
    ,
        "luce.sema.convert",
        "str() converts a number, a bool, a str, an enum, a union member, or a function value; a builder hands over its text with .build()",
        4,
        16,
    );
    try expectOnlySayingAt(
        \\func main():
        \\    var xs = [1, 2]
        \\    let text = str(xs)
        \\
    ,
        "luce.sema.convert",
        "str() converts a number, a bool, a str, an enum, a union member, or a function value, not list[i64]",
        3,
        16,
    );
}

test "luce.sema.type.retired: the old text conversion names its replacement" {
    try expectSaying(
        \\func main():
        \\    let text = string(1)
        \\
    , "luce.sema.type.retired", "string is retired; write str");
}

test "luce.sema.type: a condition must be bool" {
    try expectRejected("func main():\n    if 1:\n        return\n", "luce.sema.type");
}

test "luce.sema.type: an annotation must match the initializer" {
    try expectRejected("func main():\n    let a: i64 = \"x\"\n", "luce.sema.type");
}

test "luce.sema.convert: long and double convert only their opposite" {
    try expectRejected("func main():\n    let a = i64(\"x\")\n", "luce.sema.convert");
    try expectRejected("func main():\n    let a = f64(true)\n", "luce.sema.convert");
}

// ---------------------------------------------------------------------------
// Fields, calls, methods, indexing
// ---------------------------------------------------------------------------

test "luce.sema.field: an unknown struct field is rejected" {
    try expectRejected(
        \\struct P:
        \\    x: i64
        \\
        \\func main():
        \\    let p = P(x = 1)
        \\    let y = p.y
        \\
    , "luce.sema.field");
}

test "luce.sema.call: arity and unknown callees are checked" {
    try expectRejected(
        \\func add(a: i64, b: i64) -> i64:
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

test "luce.sema.method: map get takes exactly its key" {
    // The old fallback parameter is spelled `m.get(k) else d` now, so
    // a second argument is a count mistake and says both counts.
    try expectSayingAt(
        \\func main():
        \\    var m = new map[str, i64]
        \\    let x = m.get("k", 0)
        \\
    , "luce.sema.method", "get takes 1 argument, got 2", 3, 13);
    // The wrong key type is a *type* mistake, and is reported as one,
    // at the argument rather than at the call.
    try expectSayingAt(
        \\func main():
        \\    var m = new map[str, i64]
        \\    let x = m.get(7)
        \\
    , "luce.sema.type", "argument 1 of get is str, got i64", 3, 19);
}

test "luce.sema.loop: two-name for needs a map or a sequence" {
    // A builder is not iterable at all.
    try expectRejected(
        \\func main():
        \\    var b = new builder
        \\    for a, c in b:
        \\        b.append("x")
        \\
    , "luce.sema.loop");
}

test "luce.sema.duplicate: the two for-loop names must differ" {
    try expectRejected(
        \\func main():
        \\    var m = new map[i64, i64]
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
        \\    x: i64
        \\    y: i64
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
        \\    a: i64
        \\    b: i64
        \\
        \\func main():
        \\    let p = P(a = 1)
        \\
    , "luce.sema.construct", "P is missing field b", 6, 13);
}

test "luce.sema.construct: two missing fields take no serial comma" {
    try expectOnlySayingAt(
        \\struct P:
        \\    a: i64
        \\    b: i64
        \\    c: i64
        \\
        \\func main():
        \\    let p = P(a = 1)
        \\
    , "luce.sema.construct", "P is missing fields b and c", 7, 13);
}

test "luce.sema.construct: every missing field is named, in declaration order" {
    try expectOnlySayingAt(
        \\struct P:
        \\    a: i64
        \\    b: i64
        \\    c: i64
        \\    d: i64
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
        \\    a: i64
        \\    b: i64
        \\    c: i64
        \\
        \\const origin = P(a = 1)
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.const", "P is missing fields b and c", 6, 16);
}

test "luce.sema.container.type: an array construction needs its extents" {
    try expectRejected("func main():\n    let a = new array[i64]\n", "luce.sema.container.type");
}

test "luce.sema.loop: break and continue need a loop" {
    try expectRejected("func main():\n    break\n", "luce.sema.loop");
}

test "luce.sema.return: return paths and value shape are checked" {
    try expectRejected(
        \\func f() -> i64:
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
        \\    value: i64
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
        \\    n: i64
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
        \\    value: i64
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

test "luce.sema.const: a top-level const is not a computation" {
    try expectRejected("const bad = new list[i64]\n\nfunc main():\n    return\n", "luce.sema.const");
}

test "luce.sema.host: host builtins are gated off by default" {
    try expectRejected("func main():\n    print(\"hi\")\n", "luce.sema.host");
    // `exit` ends the process, which is the host's world exactly as
    // much as its console is.
    try expectRejected("func main():\n    exit(0)\n", "luce.sema.host");
    // So is how big the machine is: a program compiled without a host
    // has no machine to ask about, and asking is refused where it is
    // written rather than where it would run.
    try expectRejected(
        "func main():\n    print(str(os_total_memory()))\n",
        "luce.sema.host",
    );
    try expectRejected(
        "func main():\n    print(str(os_available_memory()))\n",
        "luce.sema.host",
    );
    try expectRejected(
        "func main():\n    print(str(os_cpu_count()))\n",
        "luce.sema.host",
    );
}

test "luce.sema.type: exit takes a long status, said when it is not one" {
    try expectRejectedOptions(
        "func main():\n    exit(\"done\")\n",
        hosted,
        "luce.sema.type",
    );
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

test "luce.lex.str: an unterminated string is pinned to its opening quote" {
    try expectRejectedAt("func main():\n    let a = \"open\n", "luce.lex.str", 2, 13);
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

// ---------------------------------------------------------------------------
// Operators other languages have
// ---------------------------------------------------------------------------
//
// Every one of these used to be answered by naming the second
// character — "expected an expression, found '+'" for `x++`.  The
// caret spans the whole operator as written, and the sentence names
// what Luce writes instead.

test "luce.parse.expression: '++' is answered with '+=', in either position" {
    try expectOnlySayingAcross(
        "func main():\n    var i = 0\n    i++\n",
        "luce.parse.expression",
        "there is no '++' operator: write 'x += 1' to increment",
        3,
        6,
        8,
    );
    try expectOnlySayingAcross(
        "func main():\n    var i = 0\n    ++i\n",
        "luce.parse.expression",
        "there is no '++' operator: write 'x += 1' to increment",
        3,
        5,
        7,
    );
}

test "luce.parse.expression: '--' is claimed only where it cannot be a negation" {
    // Postfix, with nothing after it, is the decrement.
    try expectOnlySayingAcross(
        "func main():\n    var i = 0\n    i--\n",
        "luce.parse.expression",
        "there is no '--' operator: write 'x -= 1' to decrement",
        3,
        6,
        8,
    );
    // `a--b` is `a - (-b)` and has always compiled.  Reading it as a
    // decrement would break working code, so an operand after the pair
    // is what tells the two apart.
    var result = try compile_mod.compile(
        testing.allocator,
        "func main():\n    let a = 5\n    let b = 3\n    assert(a--b == 8)\n",
        script,
    );
    defer result.deinit();
    if (result == .failure) printAll(&result.failure);
    try testing.expect(result == .success);
    // And prefix `--a` is a double negation, for the same reason.
    var twice = try compile_mod.compile(
        testing.allocator,
        "func main():\n    let a = 5\n    assert(--a == 5)\n",
        script,
    );
    defer twice.deinit();
    if (twice == .failure) printAll(&twice.failure);
    try testing.expect(twice == .success);
}

test "luce.parse.expression: the comparison operators of other languages" {
    try expectOnlySayingAcross(
        "func main():\n    let a = 1\n    if a === 1:\n        return\n",
        "luce.parse.expression",
        "there is no '===' operator: '==' compares, and compares by value",
        3,
        10,
        13,
    );
    try expectOnlySayingAcross(
        "func main():\n    let a = 1\n    if a !== 1:\n        return\n",
        "luce.parse.expression",
        "there is no '!==' operator: '!=' compares, and compares by value",
        3,
        10,
        13,
    );
    try expectOnlySayingAcross(
        "func main():\n    let a = 1\n    if a <> 2:\n        return\n",
        "luce.parse.expression",
        "there is no '<>' operator: write '!=' to compare for difference",
        3,
        10,
        12,
    );
}

test "luce.parse.expression: '**' names the std function that does it" {
    try expectOnlySayingAcross(
        "func main():\n    let a = 2 ** 3\n    print(str(a))\n",
        "luce.parse.expression",
        "there is no '**' operator: import std.math and call math.pow(x, y), or math.ipow(x, y) for i64",
        2,
        15,
        17,
    );
}

test "luce.sema.type: the bit set works on integers, said with the fact that refused it" {
    // docs/BITWISE.md D2: a double has no bits a program may see.
    try expectRejected(
        "func main():\n    let a = 1.5 & 2.0\n    print_error(str(a))\n",
        "luce.sema.type",
    );
    try expectSayingAt(
        "func main():\n    let x = 1.5\n    let b = x << 2.0\n",
        "luce.sema.type",
        "<< works on integers; f64 has no bits a program may see",
        3,
        13,
    );
    try expectSayingAt(
        "func main():\n    let x = 1.5\n    let b = ~x\n",
        "luce.sema.type",
        "~ works on integers; f64 has no bits a program may see",
        3,
        13,
    );
}

test "luce.sema.const: a constant shift with a bad count is the trap's compile-time face" {
    // docs/BITWISE.md D6: the folder answers what a run answers, and
    // a count out of range cannot quietly fold to anything.
    try expectRejected("const bad = 1 << 64\n\nfunc main():\n    return\n", "luce.sema.const");
    try expectRejected("const bad = 1 << -1\n\nfunc main():\n    return\n", "luce.sema.const");
    try expectCompiles("const fine: i64 = 1 << 62\n\nfunc main():\n    let x = fine\n    if x > 0:\n        return\n");
}

test "luce.parse.expression: '&&' and '||' name the Luce keyword" {
    // `&` and `|` are operators now (docs/BITWISE.md), so the doubled
    // forms reach the parser — with the same kindness they always got.
    try expectSayingAt(
        "func main():\n    let a = true\n    if a && a:\n        return\n",
        "luce.parse.expression",
        "there is no '&&' operator: write 'and'; a single '&' is bitwise",
        3,
        10,
    );
    try expectSayingAt(
        "func main():\n    let a = true\n    if a || a:\n        return\n",
        "luce.parse.expression",
        "there is no '||' operator: write 'or'; a single '|' is bitwise",
        3,
        10,
    );
    // A tripled habit reads as `&` then `&&`, and the doubled pair
    // is where the sentence lands.
    try expectSaying(
        "func main():\n    let a = 1 &&& 2\n",
        "luce.parse.expression",
        "there is no '&&' operator: write 'and'; a single '&' is bitwise",
    );
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
        "func f(a: array[i64, _, i64]):\n    return\n\nfunc main():\n    return\n",
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
        \\    n: i64
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

test "luce.sema.new: new builds only the heap constructors" {
    try expectSaying(
        "struct Point:\n    x: i64\n\nfunc main():\n    let a = new Point()\n",
        "luce.sema.new",
        "Point is a value type",
    );
}

// ---------------------------------------------------------------------------
// Transparent type aliases
// ---------------------------------------------------------------------------

test "luce.sema.alias: direct and indirect alias cycles name the complete loop" {
    try expectSaying(
        "alias Loop = Loop\n\nfunc main():\n    return\n",
        "luce.sema.alias",
        "Loop -> Loop",
    );
    try expectSaying(
        "alias A = B\nalias B = C\nalias C = A\n\nfunc main():\n    return\n",
        "luce.sema.alias",
        "A -> B -> C -> A",
    );
}

test "luce.sema.type: an alias target must exist and have the written shape" {
    try expectSaying(
        "alias UserId = Missing\n\nfunc main():\n    return\n",
        "luce.sema.type",
        "unknown type Missing",
    );
    try expectSaying(
        "alias UserId = i64(str)\n\nfunc main():\n    return\n",
        "luce.parse.type",
        "type arguments use brackets: write i64[...]",
    );
    try expectSaying(
        "alias MaybeId = i64?\n\nfunc main():\n    let value: MaybeId? = none\n",
        "luce.sema.type",
        "MaybeId? is not a type: i64? is already optional",
    );
}

test "luce.sema.reserved: an alias cannot replace a builtin type or reserved name" {
    try expectSaying(
        "alias i64 = i32\n\nfunc main():\n    return\n",
        "luce.sema.reserved",
        "i64 is a builtin type",
    );
    try expectSaying(
        "alias print = i64\n\nfunc main():\n    return\n",
        "luce.sema.reserved",
        "print is a reserved name",
    );
}

test "luce.sema.duplicate: aliases share the top-level declaration namespace" {
    const cases = [_][]const u8{
        "alias Thing = i64\nalias Thing = str\n",
        "struct Thing:\n    value: i64\nalias Thing = i64\n",
        "alias Thing = i64\nstruct Thing:\n    value: i64\n",
        "class Thing:\n    value: i64\nalias Thing = i64\n",
        "interface Thing:\n    func value() -> i64\nalias Thing = i64\n",
        "enum Thing:\n    one\nalias Thing = i64\n",
        "union Thing:\n    one(value: i64)\nalias Thing = i64\n",
        "const Thing = 1\nalias Thing = i64\n",
        "func Thing() -> i64:\n    return 1\nalias Thing = i64\n",
        "alias Thing = i64\nfunc Thing() -> i64:\n    return 1\n",
        "import std.math\nalias math = i64\n",
        "alias math = i64\nimport std.math\n",
    };
    for (cases) |declarations| {
        const source = try std.fmt.allocPrint(testing.allocator, "{s}\nfunc main():\n    return\n", .{declarations});
        defer testing.allocator.free(source);
        try expectRejected(source, "luce.sema.duplicate");
    }
}

test "luce.sema.private: a public alias cannot expose a private nominal type" {
    try expectSaying(
        "private struct Secret:\n    value: i64\n\nalias PublicSecret = Secret\n\nfunc main():\n    return\n",
        "luce.sema.private",
        "alias PublicSecret is public and names Secret",
    );
    try expectCompiles(
        "private struct Secret:\n    value: i64\n\nprivate alias HiddenSecret = Secret\n\nfunc main():\n    let value: HiddenSecret = Secret(value = 1)\n    assert(value.value == 1)\n",
    );
}

test "luce.sema.call: an alias is callable only when its target has constructor syntax" {
    try expectSaying(
        "alias Names = list[i64]\n\nfunc main():\n    let values = Names()\n",
        "luce.sema.call",
        "construct it with new Names",
    );
    try expectSaying(
        "alias Flag = bool\n\nfunc main():\n    let value = Flag(true)\n",
        "luce.sema.call",
        "Flag is a type alias for bool, not a callable value",
    );
}

test "luce.sema.name: a bare alias is a type rather than a runtime value" {
    try expectSaying(
        "alias UserId = i64\n\nfunc main():\n    let value = UserId\n",
        "luce.sema.name",
        "UserId is a type alias for i64, not a value",
    );
}

// ---------------------------------------------------------------------------
// Names, declarations, reserved words — more paths
// ---------------------------------------------------------------------------

test "luce.sema.name: input is not a name in a script" {
    try expectRejected("func main():\n    let a = input\n", "luce.sema.name");
}

test "luce.sema.duplicate: a struct cannot be declared twice" {
    try expectRejected(
        \\struct P:
        \\    x: i64
        \\
        \\struct P:
        \\    y: i64
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.duplicate");
}

test "luce.sema.duplicate: a struct cannot repeat a field" {
    try expectRejected(
        \\struct P:
        \\    x: i64
        \\    x: i64
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
    try expectRejected("struct i64:\n    x: i64\n\nfunc main():\n    return\n", "luce.sema.reserved");
}

// spelling:off — these two programs exist to be refused, so they are
// the one place in the tree that still writes the retired names.
//
// The rename is a breaking change and every program written before it
// says `Int`.  A reader who writes one of the retired spellings is
// told what it is called now, by name, in both places one can appear:
// a type annotation and a conversion call.  Edit distance cannot find
// `i64` from `Int`, so nothing else would answer at all.
test "luce.sema.type.retired: a retired TitleCase type name names its replacement" {
    try expectMessage(
        \\func main():
        \\    let n: Int = 1
        \\    assert(n == 1)
        \\
    , "Int is retired; write i64");
    try expectMessage(
        \\func main():
        \\    let x: Float = 1.5
        \\    assert(x == 1.5)
        \\
    , "Float is retired; write f64");
    try expectMessage(
        \\func main():
        \\    var xs: List[i64] = []
        \\    assert(len(xs) == 0)
        \\
    , "List is retired; write list");
}

test "luce.sema.type.retired: a retired conversion constructor names its replacement" {
    try expectMessage(
        \\func main():
        \\    let n = Int(1.5)
        \\    assert(n == 2)
        \\
    , "Int is retired; write i64");
    try expectMessage(
        \\func main():
        \\    assert(String(1) == "1")
        \\
    , "String is retired; write str");
}

// spelling:on

test "luce.sema.reserved: a struct cannot take a builtin type's name" {
    // Lowercase names are the language's (docs/TYPES.md D8).  A struct
    // spelled `list` would be a type nothing could write down, because
    // `resolveBase` answers that name first — so it is refused where it
    // is declared rather than shadowed where it is used.
    try expectRejected("struct list:\n    x: i64\n\nfunc main():\n    return\n", "luce.sema.reserved");
    try expectRejected("struct f64:\n    x: i64\n\nfunc main():\n    return\n", "luce.sema.reserved");
    try expectRejected("struct builder:\n    x: i64\n\nfunc main():\n    return\n", "luce.sema.reserved");
}

test "luce.sema.reserved: a function cannot take a conversion's name" {
    // The container names are not reserved as callables — `files.list`
    // is the right name for what it does and collides with nothing —
    // but scalar conversions are answers to a bare call and a
    // declaration would stand in front of one.
    try expectRejected("func i64():\n    return\n\nfunc main():\n    return\n", "luce.sema.reserved");
    try expectRejected("func f64():\n    return\n\nfunc main():\n    return\n", "luce.sema.reserved");
    try expectRejected("func str():\n    return\n\nfunc main():\n    return\n", "luce.sema.reserved");
}

test "luce.sema.reserved: a function cannot take a terminal service's name" {
    // The seven `term_*` builtins were dispatched and not reserved, so
    // this program compiled and the declaration stood in front of the
    // builtin.  One per shape: no arguments, some arguments, and the
    // one whose name a program is most likely to reach for.
    try expectRejected(
        "func term_rows() -> i64:\n    return 1\n\nfunc main():\n    return\n",
        "luce.sema.reserved",
    );
    try expectRejected(
        "func term_write(text: str):\n    return\n\nfunc main():\n    return\n",
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
        "struct term_style:\n    x: i64\n\nfunc main():\n    return\n",
        "luce.sema.reserved",
    );
}

// ---------------------------------------------------------------------------
// luce.sema.type — the biggest fan-out, distinct paths
// ---------------------------------------------------------------------------

test "luce.sema.type: a wrong argument type is rejected" {
    try expectRejected(
        \\func f(a: i64):
        \\    return
        \\
        \\func main():
        \\    f("x")
        \\
    , "luce.sema.type");
}

test "luce.sema.type: a returned value must match the declared return type" {
    try expectRejected(
        \\func f() -> i64:
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
        \\    x: i64
        \\
        \\func main():
        \\    let p = P(x = "s")
        \\
    , "luce.sema.type");
}

test "luce.sema.type: not needs a bool" {
    try expectRejected("func main():\n    let a = not 1\n", "luce.sema.type");
}

test "luce.sema.type: negation needs a number" {
    try expectRejected("func main():\n    let a = -\"x\"\n", "luce.sema.type");
}

test "luce.sema.type: bool has no ordering" {
    try expectRejected("func main():\n    let a = true < false\n", "luce.sema.type");
}

test "luce.sema.type: and needs bool operands" {
    try expectRejected("func main():\n    let a = 1 and 2\n", "luce.sema.type");
}

test "luce.sema.type: string has no arithmetic operator" {
    try expectRejected("func main():\n    let a = \"x\" - \"y\"\n", "luce.sema.type");
}

test "luce.sema.type: range bounds must be long" {
    try expectRejected("func main():\n    for i in range(1.0, 2.0):\n        return\n", "luce.sema.type");
}

// ---------------------------------------------------------------------------
// luce.sema.convert
// ---------------------------------------------------------------------------

test "luce.sema.convert: a conversion takes exactly one argument" {
    try expectRejected("func main():\n    let a = i64(1, 2)\n", "luce.sema.convert");
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

// Named arguments (docs/ARGS.md §8).  `f(a = 1)` compiles now — the
// "function arguments are positional" refusal is gone — and each rule
// that replaced it gets its own sentence, pinned by its words because
// luce.sema.call is emitted from many sites.

test "luce.sema.call: a positional argument cannot follow a named one" {
    try expectSaying(
        \\func size(width: i64, height: i64) -> i64:
        \\    return width * height
        \\
        \\func main():
        \\    let a = size(width = 1, 2)
        \\
    , "luce.sema.call", "a positional argument cannot follow a named one; write height = ");
}

test "luce.sema.call: an unknown argument name offers the closest parameter" {
    try expectSaying(
        \\func size(width: i64, height: i64) -> i64:
        \\    return width * height
        \\
        \\func main():
        \\    let a = size(1, heigt = 2)
        \\
    , "luce.sema.call", "size has no parameter heigt; did you mean height?");
}

test "luce.sema.call: an unknown argument name with nothing close enumerates the surface" {
    try expectSaying(
        \\func size(width: i64, height: i64) -> i64:
        \\    return width * height
        \\
        \\func main():
        \\    let a = size(1, x = 2)
        \\
    , "luce.sema.call", "size has no parameter x (takes width, height)");
}

test "luce.sema.call: a parameter given by position and by name is refused" {
    try expectSaying(
        \\func size(width: i64, height: i64) -> i64:
        \\    return width * height
        \\
        \\func main():
        \\    let a = size(1, width = 2)
        \\
    , "luce.sema.call", "width was given twice, by position and by name");
}

test "luce.sema.call: a parameter named twice is refused" {
    try expectSaying(
        \\func size(width: i64, height: i64) -> i64:
        \\    return width * height
        \\
        \\func main():
        \\    let a = size(width = 1, width = 2)
        \\
    , "luce.sema.call", "width was given twice");
}

test "luce.sema.call: every missing argument is named at once" {
    try expectSaying(
        \\func volume(width: i64, height: i64, depth: i64) -> i64:
        \\    return width * height * depth
        \\
        \\func main():
        \\    let a = volume(1)
        \\
    , "luce.sema.call", "volume is missing height and depth");
}

test "luce.sema.self: the type spelling cannot name a method receiver" {
    try expectSaying(
        \\struct Point:
        \\    x: i64
        \\
        \\    func read() -> i64:
        \\        return self.x
        \\
        \\func main():
        \\    let p = Point(x = 1)
        \\    let a = Point.read(p)
        \\
    , "luce.sema.self", "read is a method with implicit self; call it as p.read(");
}

test "luce.sema.self: self is not a nameable argument on the method form" {
    try expectSaying(
        \\struct Point:
        \\    x: i64
        \\
        \\    func plus(other: i64) -> i64:
        \\        return self.x + other
        \\
        \\func main():
        \\    let p = Point(x = 1)
        \\    let a = p.plus(self = 2)
        \\
    , "luce.sema.self", "self is the receiver; it is written in front of the dot, not named");
}

// Defaults (docs/ARGS.md §8, Order step 4).

test "luce.sema.call: defaults are trailing" {
    try expectSaying(
        \\func range_of(start: i64 = 0, finish: i64):
        \\    return
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.call", "start has a default, so finish needs one too — the parameters with defaults come last");
}

test "luce.sema.const: a call is not a default" {
    try expectSaying(
        \\func cost() -> i64:
        \\    return 1
        \\
        \\func f(a: i64 = cost()):
        \\    return
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.const", "a default is a constant: cost(…) is a call");
}

test "luce.sema.const: a runtime-created object is not a default" {
    try expectSaying(
        \\func f(xs: list[i64] = new list[i64]):
        \\    return
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.const", "a default must fold at compile time; new, slicing, and indexing belong in a function");
}

test "luce.sema.const: a default cannot read an earlier parameter" {
    try expectSaying(
        \\func f(a: i64, b: i64 = a):
        \\    return
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.const", "a default cannot use a: it is folded before any call is made");
}

test "luce.sema.type: a default lands at the parameter's type or is refused" {
    try expectSaying(
        \\func f(start: i64 = "zero"):
        \\    return
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.type", "start is i64 and its default is str");
}

test "luce.sema.const: a default folds once, at the declaration, called or not" {
    // The fold happens where the declaration is, so `1 // 0` is a
    // compile error even though nothing ever calls f — the proof the
    // evaluation is declaration-time (docs/ARGS.md §2).
    try expectSaying(
        \\func f(a: i64 = 1 // 0):
        \\    return
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.const", "constant division by zero");
}

test "luce.parse.self: an explicit self with a default gets the retirement diagnostic" {
    try expectSaying(
        \\struct Point:
        \\    x: i64
        \\
        \\    func f(self = 1) -> i64:
        \\        return 0
        \\
        \\func main():
        \\    return
        \\
    , "luce.parse.self", "self is implied; remove the parameter");
}

test "luce.sema.call: the count sentence names the defaults" {
    try expectSaying(
        \\func grown(base: i64, step: i64 = 5, twice: bool = false) -> i64:
        \\    return base + step
        \\
        \\func main():
        \\    let a = grown(1, 2, false, 4)
        \\
    , "luce.sema.call", "grown takes 1 argument and 2 with a default, got 4");
}

test "luce.sema.call: only the required slots are ever missing" {
    try expectSaying(
        \\func f(a: i64, b: i64, c: i64 = 0) -> i64:
        \\    return a + b + c
        \\
        \\func main():
        \\    let x = f()
        \\
    , "luce.sema.call", "f is missing a and b");
}

// Struct field defaults (docs/ARGS.md D8, Order step 5).

test "luce.sema.struct: field defaults are trailing" {
    try expectSaying(
        \\struct State:
        \\    cursor: i64 = 0
        \\    path: str
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.struct", "cursor has a default, so path needs one too — the fields with defaults come last");
}

test "luce.sema.const: a field default is a constant, called or not" {
    // Nothing constructs Config, and the refusal fires anyway: a
    // default is evaluated at the declaration (docs/ARGS.md D2).
    try expectSaying(
        \\func cost() -> i64:
        \\    return 1
        \\
        \\struct Config:
        \\    budget: i64 = cost()
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.const", "a default is a constant: cost(…) is a call");
}

test "luce.sema.type: a field default lands at the field's type or is refused" {
    try expectSaying(
        \\struct Config:
        \\    budget: i64 = "much"
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.type", "Config.budget is i64 and its default is str");
}

test "luce.sema.const: field defaults cannot lean on each other in a loop" {
    try expectSaying(
        \\struct A:
        \\    x: i64 = B().y
        \\
        \\struct B:
        \\    y: i64 = A().x
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.const", "depends on itself");
}

test "luce.sema.type: a named argument's type mistake names the parameter" {
    try expectSaying(
        \\func size(width: i64, height: i64) -> i64:
        \\    return width * height
        \\
        \\func main():
        \\    let a = size(1, height = "x")
        \\
    , "luce.sema.type", "height of size is i64, got str");
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

test "luce.sema.call: a builtin's argument names come from its table" {
    // `len(value = 1)` is legal now — the "builtin arguments are
    // positional" refusal went with docs/ARGS.md step 6 — so a wrong
    // name gets the same sentence a user function's would.
    try expectSaying(
        "func main():\n    let a = len(x = 1)\n",
        "luce.sema.call",
        "len has no parameter x (takes value)",
    );
}

test "luce.sema.call: a wrong builtin parameter name offers the closest slot" {
    try expectHostSaying(
        "func main():\n    term_style(114, bald = true)\n",
        "luce.sema.call",
        "term_style has no parameter bald; did you mean bold?",
    );
}

// ---------------------------------------------------------------------------
// luce.sema.method — distinct paths
// ---------------------------------------------------------------------------

test "luce.sema.method: an unknown method on a list is rejected" {
    try expectRejected("func main():\n    var xs = [1]\n    xs.frobnicate()\n", "luce.sema.method");
}

test "luce.sema.method: a method checks its arity" {
    try expectRejected("func main():\n    var xs = [1]\n    xs.append(1, 2)\n", "luce.sema.method");
}

test "luce.sema.method: a method the receiver does not have answers before its arguments do" {
    // **The receiver's answer comes first.**  A bare function name has
    // no type until it lands (FUNCTIONS.md D2), so an argument written
    // to a method that does not exist used to be refused for wanting a
    // place — *"twice is a function; write twice(...) to call it, or
    // annotate the place it goes"* — which sends the reader to annotate
    // a place the call never had, and buries the one fact that matters.
    // The landing reaches "no such method" with the receiver lowered
    // and nothing else, which is why it can say it first.
    try expectSayingAt(
        \\func twice(n: i64) -> str:
        \\    return str(n * 2)
        \\
        \\func main():
        \\    var m = new map[str, func(i64) -> str]
        \\    m.put("a", twice)
        \\
    , "luce.sema.method", "map has no method put (has get remove keys values clear)", 6, 5);
    try expectSayingAt(
        \\func twice(n: i64) -> str:
        \\    return str(n * 2)
        \\
        \\func main():
        \\    var xs = new list[(func(i64) -> str)?]
        \\    xs.push(twice)
        \\
    ,
        "luce.sema.method",
        "list has no method push (has append insert remove pop sort reverse find contains clear; sort_by lives in lists; join lives in strings)",
        6,
        5,
    );
    // A declared receiver answers the same way, out of the same place.
    try expectSayingAt(
        \\func twice(n: i64) -> str:
        \\    return str(n * 2)
        \\
        \\struct Box:
        \\    v: i64
        \\
        \\func main():
        \\    var b = Box(v = 1)
        \\    b.set(twice)
        \\
    , "luce.sema.method", "Box has no method set", 9, 5);
}

test "luce.sema.method: one argument too many is a count, not a question about the argument" {
    // The same fact one step along: the method exists, the extra
    // argument has no slot to land in, and the count is knowable
    // before it is lowered.
    try expectSayingAt(
        \\func twice(n: i64) -> str:
        \\    return str(n * 2)
        \\
        \\func main():
        \\    var xs = new list[(func(i64) -> str)?]
        \\    xs.append(twice, twice)
        \\
    , "luce.sema.method", "append takes 1 argument, got 2", 6, 5);
}

test "luce.sema.method: a builtin method's arguments are positional" {
    // Its table holds types computed from the receiver and no names
    // (docs/ARGS.md D10) — while a *struct* method's arguments may be
    // named, because its declaration is readable source.
    try expectSaying(
        "func main():\n    var xs = [1]\n    xs.append(v = 1)\n",
        "luce.sema.method",
        "append is a builtin method and its arguments are positional",
    );
}

test "luce.sema.method: a routed string method stays positional and names the spelling that isn't" {
    try expectSaying(
        \\import std.strings
        \\
        \\func main():
        \\    let n = "abc".find(needle = "b")
        \\
    , "luce.sema.method", "find routes to std.strings and its arguments are positional here; write strings.find(");
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

test "luce.sema.import: str methods need import strings" {
    try expectRejected("func main():\n    let s = \"x\"\n    let n = s.find(\"y\")\n", "luce.sema.import");
}

test "luce.sema.import: join on list[str] needs import strings" {
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

test "luce.sema.method: map has no such method" {
    try expectRejected(
        \\func main():
        \\    var m = new map[str, i64]
        \\    m.frobnicate()
        \\
    , "luce.sema.method");
}

// ---------------------------------------------------------------------------
// luce.sema.index — distinct paths
// ---------------------------------------------------------------------------

test "luce.sema.index: only a string is sliced, so a number is refused" {
    try expectRejected("func main():\n    let text = 1[0:1]\n", "luce.sema.index");
}

test "luce.sema.index: a string index must be i64" {
    try expectRejected("func main():\n    let s = \"abc\"\n    let c = s[true]\n", "luce.sema.index");
}

test "luce.sema.index: a list indexes with a long, not a bool" {
    try expectRejected("func main():\n    var xs = [1]\n    let a = xs[true]\n", "luce.sema.index");
}

test "luce.sema.index: an array wants one index per dimension" {
    try expectRejected(
        \\func main():
        \\    var grid = new array[i64](2, 2)
        \\    let a = grid[0]
        \\
    , "luce.sema.index");
}

test "luce.sema.index: a map cannot be sliced" {
    try expectRejected(
        \\func main():
        \\    var m = new map[i64, i64]
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
        \\    x: i64
        \\
        \\func main():
        \\    let p = P(x = 1, z = 2)
        \\
    , "luce.sema.construct");
}

test "luce.sema.construct: a field cannot be given twice" {
    try expectRejected(
        \\struct P:
        \\    x: i64
        \\
        \\func main():
        \\    let p = P(x = 1, x = 2)
        \\
    , "luce.sema.construct");
}

test "luce.sema.construct: fields are named, not positional" {
    try expectRejected(
        \\struct P:
        \\    x: i64
        \\
        \\func main():
        \\    let p = P(1)
        \\
    , "luce.sema.construct");
}

test "luce.sema.construct: a function-namespace struct has no value fields" {
    try expectRejected(
        \\struct Util:
        \\    static func helper() -> i64:
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

// The two sentences the byte channel adds (docs/BYTES.md R5).  A file
// is opened, never made — a handle with no file behind it is the one
// state the type must not hold — and it cannot be copied, because one
// open file cannot have two owners.  Both are refused by name in stage
// 4 rather than met as a trap; the runtime and the verifier stand
// behind them for IR that arrived some other way.
test "luce.sema.new: a file is opened, not made" {
    try expectRejected("func main():\n    var f = new file\n", "luce.sema.new");
}

test "luce.sema.method: a file has read, write and flush and nothing else" {
    try expectRejected(
        \\import std.files
        \\
        \\func main() -> !:
        \\    var f = try files.open("notes.txt")
        \\    f.close()
        \\
    , "luce.sema.method");
}

test "luce.sema.method: close is refused by name, with both halves of the answer" {
    // The one name a Python programmer will certainly type
    // (docs/FILESYSTEM.md D9).  It is refused rather than offered —
    // a working `close` would be `free` under a second name, and an
    // idempotent one would need a state a resource must never hold —
    // so the diagnostic has to teach both the early close and the
    // automatic one, and say why `with` is missing too.
    try expectHostSaying(
        \\import std.files
        \\
        \\func main() -> !:
        \\    var f = try files.open("notes.txt")
        \\    f.close()
        \\
    , "luce.sema.method", "file has no method close: free f closes it, and the end of the owning scope closes it anyway");
}

test "luce.sema.fallible: an ignored files.exists is refused, not silently dropped" {
    // The whole reason `exists` changed type (docs/FILESYSTEM.md
    // D13): the answer it could not give is the refused one, so
    // dropping the outcome has to be a compile error rather than a
    // bool nobody looked at.
    try expectHostSaying(
        \\import std.files
        \\
        \\func main():
        \\    if files.exists("notes.txt"):
        \\        print("there")
        \\
    , "luce.sema.fallible", "files.exists can fail");
}

test "luce.sema.fallible: an ignored files.kind is refused too" {
    try expectHostSaying(
        \\import std.files
        \\
        \\func main():
        \\    let what = files.kind("notes.txt")
        \\
    , "luce.sema.fallible", "files.kind can fail");
}

test "luce.sema.retired: file_exists names what replaced it" {
    // A published builtin for the whole of v2, and on the
    // documentation site — so a reader who types it is owed the
    // replacement rather than "unknown function".
    try expectHostSaying(
        \\func main():
        \\    print(str(file_exists("notes.txt")))
        \\
    , "luce.sema.retired", "file_exists was retired");
}

test "luce.sema.fallible: a handle's read is fallible like every file service" {
    try expectRejected(
        \\import std.files
        \\
        \\func main() -> !:
        \\    var f = try files.open("notes.txt")
        \\    var buffer = new array[u8](4)
        \\    let got = f.read(buffer)
        \\
    , "luce.sema.fallible");
}

test "luce.sema.container.type: new array takes one to four dimension sizes" {
    try expectRejected("func main():\n    var a = new array[i64](1, 2, 3, 4, 5)\n", "luce.sema.container.type");
}

test "luce.sema.container.type: array dimensions are i64" {
    try expectRejected("func main():\n    var a = new array[i64](true)\n", "luce.sema.container.type");
}

test "luce.sema.container.type: construction values belong only to arrays" {
    try expectSaying(
        "func main():\n    var xs = new list[i64](4)\n",
        "luce.sema.container.type",
        "new list[i64] takes no construction values",
    );
}

test "luce.sema.container.type: an array alias keeps and checks its rank" {
    try expectSaying(
        "alias Grid = array[i64, _, _]\n\nfunc main():\n    var grid = new Grid(4)\n",
        "luce.sema.container.type",
        "new Grid needs 2 dimension sizes, got 1",
    );
}

test "luce.sema.container.type: direct new array takes no rank wildcards" {
    try expectSaying(
        "func main():\n    var grid = new array[i64, _, _](4, 4)\n",
        "luce.sema.container.type",
        "new array writes one element type, then its sizes",
    );
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
        \\func f() -> i64:
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
        \\func f() -> i64:
        \\    return 1
        \\
        \\const bad = f()
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.const");
}

test "luce.sema.const: an unknown name is not a constant" {
    try expectRejected("const bad = ghost\n\nfunc main():\n    return\n", "luce.sema.const");
}

test "luce.sema.const: a constant cannot depend on itself" {
    try expectRejected("const bad = bad\n\nfunc main():\n    return\n", "luce.sema.const");
}

test "luce.sema.const: a constant container cannot contain another container" {
    try expectRejected("const bad = [[1], [2]]\n\nfunc main():\n    return\n", "luce.sema.const");
}

test "luce.sema.const: a bare none is still refused — nothing says what is absent" {
    // `const x: long? = none` folds (docs/ARGS.md D9); without the
    // annotation there is no type to be absent at, and the refusal
    // stands.
    try expectSaying(
        "const bad = none\n\nfunc main():\n    return\n",
        "luce.sema.const",
        "annotate it: const name: T? = none",
    );
}

test "luce.sema.const: none refuses a place that is always there" {
    try expectSaying(
        "const bad: i64 = none\n\nfunc main():\n    return\n",
        "luce.sema.const",
        "i64 is always there; only i64? is ever none",
    );
}

test "luce.sema.const: optional fallback is a runtime operation" {
    try expectSaying(
        \\const missing: i64? = none
        \\const bad = missing else 1
        \\
        \\func main():
        \\    return
        \\
    ,
        "luce.sema.const",
        "else is a runtime optional operation and does not fold in a constant initializer",
    );
}

// ---------------------------------------------------------------------------
// luce.sema.literal — expression-position literal overflow
// ---------------------------------------------------------------------------

test "luce.sema.literal: an over-large integer literal is rejected" {
    try expectRejected("func main():\n    let a = 99999999999999999999\n", "luce.sema.literal");
}

test "luce.sema.literal: a negated literal past long's minimum is rejected too" {
    try expectRejected("func main():\n    let a = -9223372036854775809\n", "luce.sema.literal");
    try expectRejected("func main():\n    let a = 9223372036854775808\n", "luce.sema.literal");
}

test "luce.sema.literal: a float literal that is not finite is rejected" {
    // parseFloat is happy to hand back infinity; a program that says
    // 1e400 did not ask for infinity, it made a mistake.
    try expectRejected("func main():\n    let a = 1e400\n", "luce.sema.literal");
    try expectRejected("func main():\n    let a = -1e400\n", "luce.sema.literal");
}

test "luce.sema.const: a non-finite default f64 constant is rejected as well" {
    try expectRejected("const a = 1e400\n\nfunc main():\n    let b = a\n", "luce.sema.const");
}

test "luce.sema.const: an invalid char constant has no value to fold" {
    try expectRejected("const a = char(1114112)\n\nfunc main():\n    let b = a\n", "luce.sema.const");
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
    const source = try longChain(testing.allocator, "const a = ", "1", 5000, "\n\nfunc main():\n    let b = a\n");
    defer testing.allocator.free(source);
    try expectRejected(source, "luce.sema.nesting");
}

test "luce.sema.nesting: an f-string with thousands of holes is bounded" {
    // f"{x}{x}..." desugars to string(x) + string(x) + ..., which is the
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
        \\    var flag: bool? = none
        \\    if flag:
        \\        return
        \\
    , "test it first (if flag != none:)");
    // As a method receiver.
    try expectRejected(
        \\func main():
        \\    var xs: list[i64]? = none
        \\    xs.append(1)
        \\
    , "luce.sema.absent");
    // As something to index.
    try expectRejected(
        \\func main():
        \\    var xs: list[i64]? = none
        \\    let first = xs[0]
        \\
    , "luce.sema.index");
    // As something to iterate.
    try expectRejected(
        \\func main():
        \\    var xs: list[i64]? = none
        \\    for x in xs:
        \\        return
        \\
    , "luce.sema.loop");
    // As something to hand over.
    try expectRejected(
        \\func consume(xs: list[i64]):
        \\    return
        \\
        \\func main():
        \\    var xs: list[i64]? = none
        \\    consume(xs)
        \\
    , "luce.sema.type");
}

test "luce.sema.absent: a field is not a local, so it is told to bind a name" {
    try expectMessage(
        \\struct Bag:
        \\    items: list[i64]?
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
        \\    var n: i64 = none
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
    // Bare none supplies no payload type; an annotated optional
    // constant is covered by the constants surface below.
    try expectRejected(
        \\const missing = none
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.const");
}

test "luce.sema.absent: a test or a fallback that can never fire is refused" {
    try expectMessage(
        \\func main():
        \\    var n: i64? = none
        \\    n = 4
        \\    assert(n != none)
        \\
    , "n already holds a value here");
    try expectMessage(
        \\func main():
        \\    var n: i64? = none
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
        \\    var n: i64? = 1
        \\    var total: i64 = 0
        \\    while total < 10:
        \\        total = total + n
        \\        n = none
        \\
    , "operands of + are i64 and i64?");
    // One arm narrowing is not both arms narrowing.  (Where *both*
    // arms do — `if n == none: n = 1` — the join keeps it, and that is
    // the point of a join.)
    try expectMessage(
        \\func maybe(flag: bool) -> i64:
        \\    var n: i64? = none
        \\    if flag:
        \\        n = 1
        \\    return n * 2
        \\
        \\func main():
        \\    assert(maybe(true) == 2)
        \\
    , "operands of * are i64? and i64");
    // A call cannot narrow: only the name itself.
    try expectRejected(
        \\func check(n: i64?) -> bool:
        \\    return n != none
        \\
        \\func main():
        \\    let n = parse_int("1")
        \\    if check(n):
        \\        let doubled = n * 2
        \\
    , "luce.sema.type");

    // A guarded assignment only runs on the successful side of the
    // call.  Its catch handler begins with the entry facts, and the
    // merge cannot retain a presence proof that only success made.
    try expectSaying(
        \\func maybe() -> i64!:
        \\    error("missing")
        \\
        \\func main():
        \\    var n: i64? = none
        \\    n = maybe() catch:
        \\        assert(true)
        \\    let result = n + 1
        \\
    , "luce.sema.type", "operands of + are i64? and i64");

    try expectSaying(
        \\func maybe() -> (i64?, i64)!:
        \\    error("missing")
        \\
        \\func main():
        \\    var n: i64? = 1
        \\    var count = 0
        \\    while count < 1:
        \\        let result = n + 1
        \\        n, count = maybe() catch:
        \\            count = count + 1
        \\
    , "luce.sema.type", "operands of + are i64? and i64");
}

test "luce.parse.type: T?? is refused where it is written" {
    try expectRejected(
        \\func main():
        \\    var n: i64?? = none
        \\
    , "luce.parse.type");
}

test "luce.sema.type: a container element may not be optional" {
    try expectMessage(
        \\func main():
        \\    var xs = new list[i64?]
        \\
    , "a list element cannot be optional");
    try expectRejected(
        \\func main():
        \\    var m = new map[str, i64?]
        \\
    , "luce.sema.type");
    try expectRejected(
        \\func main():
        \\    var grid = new array[i64?](2)
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
        try text.appendSlice(testing.allocator, try std.fmt.bufPrint(&line, "    let a{d}: i64 = \"x\"\n", .{index}));
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
        \\    let a: i64 = "x"
        \\    let b: bool = 1
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
        \\func compute(a: i64) -> i64:
        \\    return a
        \\
        \\func main():
        \\    assert(comptue(1) == 1)
        \\
    , "did you mean compute?");
    try expectMessage(
        \\struct Point:
        \\    across: i64
        \\    down: i64
        \\
        \\func main():
        \\    let p = Point(across = 1, down = 2)
        \\    assert(p.acros == 1)
        \\
    , "did you mean across?");
    // The builtin names are lowercase, so a typo of one is lowercase
    // too.  A reader who writes the retired TitleCase spelling exactly
    // is answered by name instead, which is a better sentence than any
    // guess (docs/TYPES.md D8) — the spec for it is below.
    try expectMessage(
        \\func main():
        \\    let a: strr = "x"
        \\    assert(len(a) == 1)
        \\
    , "did you mean str?");
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
        \\    x: i64
        \\    y: i64
        \\
        \\func main():
        \\    let p = Point(x = 1, y = 2)
        \\    assert(p.z == 1)
        \\
    , "Point has no field z");
}

test "a function that can fall off the end names the type it owes" {
    try expectMessage(
        \\func pick(a: i64) -> f64:
        \\    if a > 0:
        \\        return 1.0
        \\
        \\func main():
        \\    assert(pick(1) == 1.0)
        \\
    , "pick must return f64 on every path");
}

test "an f-string hole is underlined, not the whole literal" {
    // The synthesized `string(...)` used to carry the whole f-string's
    // span, so a reader with four holes on one line was shown all four
    // and told one of them was wrong.
    try expectHostSayingAt(
        \\func main():
        \\    let a = 1
        \\    let b = 2
        \\    let xs = [1]
        \\    let c = 3
        \\    print(f"{a} and {b} and {xs} and {c}")
        \\    free(xs)
        \\
    ,
        "luce.sema.convert",
        "str() converts a number, a bool, a str, an enum, a union member, or a function value, not list[i64]",
        6,
        30,
    );
}

test "luce.parse.expected: a slice has no third field" {
    // `s[0:4:2]` answered "expected ']' to close '['", which names the
    // bracket and leaves the reader to find out that this language has
    // two slice fields rather than three.
    const say = "a slice is [start:end] and has no step; take every nth with a loop";
    try expectSayingAt(
        "func main():\n    let s = \"hello\"\n    let t = s[0:4:2]\n",
        "luce.parse.expected",
        say,
        3,
        18,
    );
    // The open-start form takes the same answer.
    try expectSayingAt(
        "func main():\n    let s = \"hello\"\n    let t = s[:4:2]\n",
        "luce.parse.expected",
        say,
        3,
        17,
    );
    // Both real slice shapes keep working.
    var result = try compile_mod.compile(
        testing.allocator,
        "func main():\n    let s = \"hello\"\n    assert(s[0:2] == \"he\")\n    assert(s[:2] == \"he\")\n    assert(s[3:] == \"lo\")\n",
        script,
    );
    defer result.deinit();
    if (result == .failure) printAll(&result.failure);
    try testing.expect(result == .success);
}

test "luce.sema.fallible: a try with nothing to try says so, in either kind of function" {
    // The order of these two checks *is* the diagnostic.  Asked the
    // other way round, the same mistake in a plain `main` answered
    // "main does not say it can fail; write '-> !'", which is wrong,
    // and wrong in the expensive direction: following it changes a
    // signature, recompiles, and produces the real message.
    const say = "try applies to a call that can fail, and this one cannot; drop the try";
    try expectOnlySayingAt(
        \\func plain() -> i64:
        \\    return 1
        \\
        \\func main():
        \\    let a = try plain()
        \\    assert(a == 1)
        \\
    ,
        "luce.sema.fallible",
        say,
        5,
        13,
    );
    // The arm that was always right, kept honest.
    try expectOnlySayingAt(
        \\func plain() -> i64:
        \\    return 1
        \\
        \\func main() -> !:
        \\    let a = try plain()
        \\    assert(a == 1)
        \\
    ,
        "luce.sema.fallible",
        say,
        5,
        13,
    );
    // And a try that really does hand an error up still says that.
    try expectOnlySayingAt(
        \\func risky() -> i64!:
        \\    return 1
        \\
        \\func main():
        \\    let a = try risky()
        \\    assert(a == 1)
        \\
    ,
        "luce.sema.fallible",
        "try hands the error to the caller, and main does not say it can fail; " ++
            "write '-> !' (or '-> T!') on its signature, or handle it with catch",
        5,
        13,
    );
}

test "luce.parse.expected: a catch block cannot initialize a binding" {
    // The block form guards a statement or an assignment; it supplies
    // no value, and a binding is nothing but a value (docs/FAILURE.md).
    // The old answer was "expected end of line after the binding,
    // found the keyword 'catch'", which leaves the reader to work out
    // which of the two catch forms they have met.
    try expectSayingAt(
        \\func risky() -> i64!:
        \\    return 1
        \\
        \\func main():
        \\    let a = risky() catch:
        \\        assert(false)
        \\    assert(a == 1)
        \\
    ,
        "luce.parse.expected",
        "a catch block supplies no value, so it cannot initialize a: " ++
            "write 'let a = … catch VALUE', or declare a first and guard the assignment",
        5,
        21,
    );
    try expectSayingAt(
        \\func risky() -> i64!:
        \\    return 1
        \\
        \\func main():
        \\    var total = risky() catch:
        \\        assert(false)
        \\    assert(total == 1)
        \\
    ,
        "luce.parse.expected",
        "a catch block supplies no value, so it cannot initialize total: " ++
            "write 'var total = … catch VALUE', or declare total first and guard the assignment",
        5,
        25,
    );
    // Both fixes the message names actually compile.
    var fallback = try compile_mod.compile(
        testing.allocator,
        \\func risky() -> i64!:
        \\    return 1
        \\
        \\func main():
        \\    let a = risky() catch 0
        \\    assert(a == 1)
        \\
    ,
        script,
    );
    defer fallback.deinit();
    if (fallback == .failure) printAll(&fallback.failure);
    try testing.expect(fallback == .success);

    var guarded = try compile_mod.compile(
        testing.allocator,
        \\func risky() -> i64!:
        \\    return 1
        \\
        \\func main():
        \\    var a: i64 = 0
        \\    a = risky() catch:
        \\        a = -1
        \\    assert(a == 1)
        \\
    ,
        script,
    );
    defer guarded.deinit();
    if (guarded == .failure) printAll(&guarded.failure);
    try testing.expect(guarded == .success);
}

test "luce.parse.expected: a catch block with a binding cannot initialize one either" {
    // The same refusal, and it has to reach the binding form too: the
    // Pratt loop declines `catch NAME:` for the statement, so without
    // this the reader would get "expected end of line after the
    // binding" back again for exactly the mistake the message above
    // was written for.
    try expectHostSayingAt(
        \\func risky() -> i64!:
        \\    return 1
        \\
        \\func main():
        \\    let a = risky() catch reason:
        \\        print(reason)
        \\
    ,
        "luce.parse.expected",
        "a catch block supplies no value, so it cannot initialize a: " ++
            "write 'let a = … catch VALUE', or declare a first and guard the assignment",
        5,
        21,
    );
}

test "luce.parse.expected: a catch handler's body goes on the next line" {
    // `catch NAME:` needs the newline behind its colon to be told from
    // a slice whose start ends in a fallback name, so a handler written
    // on one line reads as the operator form and leaves a colon behind.
    // "Expected end of line, found ':'" is true and useless.
    try expectHostSayingAt(
        \\func risky() -> i64!:
        \\    return 1
        \\
        \\func main():
        \\    risky() catch reason: print(reason)
        \\
    ,
        "luce.parse.expected",
        "a catch handler is a block: put its body on the next line, indented under 'reason:'",
        5,
        25,
    );
}

test "luce.sema.fallible: catch with a binding names the binding in the refusal" {
    // The plain form says "drop the catch".  With a binding that is
    // half the advice, because the name goes too — and the reason it
    // goes is the sentence worth reading.
    try expectHostSayingAt(
        \\func plain(n: i64) -> i64:
        \\    return n
        \\
        \\func main():
        \\    plain(1) catch reason:
        \\        print(reason)
        \\
    ,
        "luce.sema.fallible",
        "catch guards a call that can fail, and this statement has none; " ++
            "drop the catch, and reason with it — there is no error for it to name",
        5,
        5,
    );
}

test "luce.sema.duplicate: a handler's binding obeys the no-shadowing rule" {
    try expectHostSayingAt(
        \\func risky() -> i64!:
        \\    error("no")
        \\
        \\func main():
        \\    let reason = "already here"
        \\    risky() catch reason:
        \\        print(reason)
        \\
    ,
        "luce.sema.duplicate",
        "reason is already declared on line 5",
        6,
        19,
    );
}

test "luce.sema.name: a handler's binding does not outlive its block" {
    try expectHostSayingAt(
        \\func risky() -> !:
        \\    error("no")
        \\
        \\func main():
        \\    risky() catch reason:
        \\        print(reason)
        \\    print(reason)
        \\
    ,
        "luce.sema.name",
        "unknown name reason",
        7,
        11,
    );
}

test "a slice whose start falls back to a name is still a slice" {
    // The lookahead that tells `catch NAME:` from the operator form
    // turns on the newline, and this is the program that says why: no
    // newline lives inside brackets, so the colon here is the slice's.
    try expectCompiles(
        \\func first(xs: list[i64]) -> i64!:
        \\    if len(xs) == 0:
        \\        error("empty")
        \\    return xs[0]
        \\
        \\func main():
        \\    let xs = new list[i64]
        \\    xs.append(1)
        \\    xs.append(2)
        \\    xs.append(3)
        \\    let base = 0
        \\    let part = xs[first(xs) catch base : 3]
        \\    assert(len(part) == 2)
        \\
    );
}

// ---------------------------------------------------------------------------
// luce.sema.unreachable — a statement below one that never comes back
// ---------------------------------------------------------------------------
//
// Refused rather than tolerated, because Luce has one severity and the
// line it already draws puts this on the refusing side: it refuses
// `a < b < c` and `not a == b`, where the way the code reads and the
// way it runs disagree, and it accepts an unused local, which is
// merely redundant.  A statement after `return` is the first kind.

test "luce.sema.unreachable: each terminator is named, with its line" {
    try expectOnlySayingAt(
        "func main():\n    let a = 1\n    return\n    let b = a\n",
        "luce.sema.unreachable",
        "this cannot run: the return on line 3 leaves the block first; delete it, or move it above the return",
        4,
        5,
    );
    try expectOnlySayingAt(
        "func main():\n    trap(\"no\")\n    let b = 1\n",
        "luce.sema.unreachable",
        "this cannot run: the trap on line 2 leaves the block first; delete it, or move it above the trap",
        3,
        5,
    );
    // Hosted, because `exit` itself is behind the gate; the sentence
    // under test is the same shape every terminator gets.
    try expectHostSayingAt(
        "func main():\n    exit(0)\n    let after = 1\n",
        "luce.sema.unreachable",
        "this cannot run: the exit on line 2 leaves the block first; delete it, or move it above the exit",
        3,
        5,
    );
    try expectOnlySayingAt(
        "func main():\n    var i = 0\n    while i < 3:\n        break\n        i += 1\n",
        "luce.sema.unreachable",
        "this cannot run: the break on line 4 leaves the block first; delete it, or move it above the break",
        5,
        9,
    );
    try expectOnlySayingAt(
        "func main():\n    var i = 0\n    while i < 3:\n        i += 1\n        continue\n        i += 2\n",
        "luce.sema.unreachable",
        "this cannot run: the continue on line 5 leaves the block first; delete it, or move it above the continue",
        6,
        9,
    );
}

test "luce.sema.unreachable: an if counts only when both arms leave" {
    // Both arms return, so nothing below the `if` runs.
    try expectOnlySayingAt(
        \\func pick(n: i64) -> i64:
        \\    if n > 0:
        \\        return 1
        \\    else:
        \\        return 2
        \\    let never = n
        \\    return never
        \\
        \\func main():
        \\    assert(pick(1) == 1)
        \\
    ,
        "luce.sema.unreachable",
        "this cannot run: the if on line 2 leaves the block first; delete it, or move it above the if",
        6,
        5,
    );
    // One arm falling through is the ordinary early-return guard, and
    // it must keep compiling — this is the shape half the corpus is
    // written in.
    var guard = try compile_mod.compile(
        testing.allocator,
        \\func pick(n: i64) -> i64:
        \\    if n > 0:
        \\        return 1
        \\    let reached = n
        \\    return reached
        \\
        \\func main():
        \\    assert(pick(0) == 0)
        \\
    ,
        script,
    );
    defer guard.deinit();
    if (guard == .failure) printAll(&guard.failure);
    try testing.expect(guard == .success);
}

test "luce.sema.unreachable: one terminator is one mistake, however many lines it strands" {
    try expectOnlySayingAt(
        "func main():\n    return\n    let a = 1\n    let b = 2\n    let c = 3\n",
        "luce.sema.unreachable",
        "this cannot run: the return on line 2 leaves the block first; delete it, or move it above the return",
        3,
        5,
    );
}

test "a terminator as the last statement of its block is the ordinary case" {
    // Everything the rule must not touch: a `return` at the end of a
    // function, a `break` at the end of a loop body, a `return` inside
    // an arm with code after the `if`.
    var result = try compile_mod.compile(
        testing.allocator,
        \\func first(n: i64) -> i64:
        \\    var i = 0
        \\    while i < n:
        \\        if i == 2:
        \\            break
        \\        i += 1
        \\    return i
        \\
        \\func main():
        \\    assert(first(5) == 2)
        \\
    ,
        script,
    );
    defer result.deinit();
    if (result == .failure) printAll(&result.failure);
    try testing.expect(result == .success);
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
    try text.appendSlice(testing.allocator, "struct S0:\n    v: i64\n");
    for (1..21) |level| {
        var line: [64]u8 = undefined;
        try text.appendSlice(testing.allocator, try std.fmt.bufPrint(&line, "struct S{d}:\n    a: S{d}\n    b: S{d}\n", .{ level, level - 1, level - 1 }));
    }
    try text.appendSlice(testing.allocator, "func main():\n    var g: S20\n");
    try expectRejected(text.items, "luce.sema.struct");
}

/// `struct S0: v: long`, then `levels` layouts of two fields each, so
/// `S{levels}` is exactly `2^levels` values.  The header of `S{k}` is
/// on line `3k` and its first field on line `3k + 1`.
fn doublingStructs(text: *std.ArrayList(u8), levels: usize) !void {
    try text.appendSlice(testing.allocator, "struct S0:\n    v: i64\n");
    for (1..levels + 1) |level| {
        var line: [64]u8 = undefined;
        try text.appendSlice(testing.allocator, try std.fmt.bufPrint(
            &line,
            "struct S{d}:\n    a: S{d}\n    b: S{d}\n",
            .{ level, level - 1, level - 1 },
        ));
    }
}

test "luce.sema.struct: the value limit is exact in both directions" {
    // 2^12 is 4096, which is the limit and not past it; 2^13 is the
    // first refusal.  A bound nobody stands on either side of drifts.
    {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(testing.allocator);
        try doublingStructs(&text, 12);
        try text.appendSlice(testing.allocator, "func main():\n    var g: S12\n    assert(g.a.a.a.a.a.a.a.a.a.a.a.a.v == 0)\n");
        var result = try compile_mod.compile(testing.allocator, text.items, script);
        defer result.deinit();
        if (result == .failure) printAll(&result.failure);
        try testing.expect(result == .success);
    }
    {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(testing.allocator);
        try doublingStructs(&text, 13);
        try text.appendSlice(testing.allocator, "func main():\n    var g: S13\n");
        // The caret is on the widest field, never the `struct`
        // keyword: that is the line that gets edited, and `?` is one
        // of the two edits that work.
        try expectOnlySayingAt(
            text.items,
            "luce.sema.struct",
            "struct S13 always holds more than 4096 values once its nested structs are counted; " ++
                "a is S12, which is 4096 of them on its own; write a: S12? to hold those only when " ++
                "they are there, or move bulk data into a list, map, or array, which is one reference",
            40,
            5,
        );
    }
}

test "luce.sema.struct: a struct too wide from its own fields names no field" {
    // 4097 long fields: nothing is nested, so there is no widest
    // struct field to point at and the shorter sentence is the honest
    // one.  Naming `f0: long` as the culprit would be advice that does
    // not work.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "struct Wide:\n");
    for (0..4097) |index| {
        var line: [32]u8 = undefined;
        try text.appendSlice(testing.allocator, try std.fmt.bufPrint(&line, "    f{d}: i64\n", .{index}));
    }
    try text.appendSlice(testing.allocator, "func main():\n    var g: Wide\n");
    try expectOnlySayingAt(
        text.items,
        "luce.sema.struct",
        "struct Wide always holds more than 4096 values; bulk data belongs in a list, map, or array, which is one reference",
        1,
        1,
    );
}

test "the value limit counts what a struct always holds, so `?` is an answer" {
    // The pair that reads as an inconsistency and is not one.  Both
    // Holders describe the same data; only the first *always* holds
    // it.  An optional field starts absent and its payload arrives
    // when a program builds one, which is why `valueCount` stops
    // there — and why the refusal above offers `?` as a fix.
    //
    // Flattening optionals too is not available: the shape walk closes
    // a layout only after the layouts it contains, and `next: Node?`
    // has no such order, so it would have to be reported as a cycle —
    // destroying the fix the cycle diagnostic itself prescribes.  The
    // last block is that fix, still compiling.
    var plain: std.ArrayList(u8) = .empty;
    defer plain.deinit(testing.allocator);
    try doublingStructs(&plain, 13);
    try plain.appendSlice(testing.allocator, "func main():\n    var g: S13\n");
    try expectRejected(plain.items, "luce.sema.struct");

    var optional: std.ArrayList(u8) = .empty;
    defer optional.deinit(testing.allocator);
    try optional.appendSlice(testing.allocator, "struct S0:\n    v: i64\n");
    for (1..14) |level| {
        var line: [64]u8 = undefined;
        try optional.appendSlice(testing.allocator, try std.fmt.bufPrint(
            &line,
            "struct S{d}:\n    a: S{d}?\n    b: S{d}?\n",
            .{ level, level - 1, level - 1 },
        ));
    }
    try optional.appendSlice(testing.allocator, "func main():\n    var g: S13\n    assert(g.a == none)\n");
    var result = try compile_mod.compile(testing.allocator, optional.items, script);
    defer result.deinit();
    if (result == .failure) printAll(&result.failure);
    try testing.expect(result == .success);

    // The recursive structure the whole rule exists to permit.
    var recursive = try compile_mod.compile(
        testing.allocator,
        \\struct Node:
        \\    value: i64
        \\    next: Node?
        \\
        \\func main():
        \\    var n: Node
        \\    assert(n.next == none)
        \\
    ,
        script,
    );
    defer recursive.deinit();
    if (recursive == .failure) printAll(&recursive.failure);
    try testing.expect(recursive == .success);
}

test "a wide struct graph with no cycle compiles, and quickly" {
    // The same shape, kept under the limit.  Answering "does this
    // contain itself" or "does it carry an object" by walking every
    // path is exponential here; both are settled once instead.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "struct S0:\n    v: i64\n");
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
        \\    value: i64
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

test "luce.sema.host: file_open is gated" {
    try expectRejected("func main():\n    let f = file_open(\"x\", 0)\n", "luce.sema.host");
}

test "luce.sema.host: path_kind is gated" {
    try expectRejected("func main() -> !:\n    let k = try path_kind(\"x\")\n", "luce.sema.host");
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
// here* (semantics/builder.zig methodNamespace).  A bare geo.dist(1) with no such
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
    // What `if files.write_lines(...)` became.  There is no bool left
    // to swallow, so the mistake is unwritable rather than silent.
    try expectHostError(
        \\func main() -> !:
        \\    if try file_write("out.txt", "body"):
        \\        print("wrote")
        \\
    , "luce.sema.call");
}

test "luce.sema.name: a fallback that names nothing is unknown, not disagreeing about ownership" {
    // A diagnostic about a thing must not fire when the thing does not
    // exist.  Both operators ask their fallback whether it hands over a
    // fresh object, and that question is a reading of the written tree:
    // it answers "no" for a name nobody declared exactly as it does for
    // a borrow.  Asked before the fallback resolved, an unknown name
    // came back as an ownership disagreement — a sentence about the
    // ownership of something that is not there, which sends the reader
    // looking for a `give` when what they wrote is a typo.  Both are
    // now asked after the fallback has lowered, so the resolution
    // failure wins and it is the *only* thing reported.
    try expectOnlySayingAt(
        \\func maybe() -> list[i64]?:
        \\    return new list[i64]
        \\
        \\func main():
        \\    let xs = maybe() else Nope.empty
        \\
    , "luce.sema.name", "unknown name Nope", 5, 27);

    try expectOnlySayingAt(
        \\func attempt() -> list[i64]!:
        \\    return new list[i64]
        \\
        \\func main():
        \\    let xs = attempt() catch Nope.empty
        \\
    , "luce.sema.name", "unknown name Nope", 5, 30);
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
        \\func main() -> i64!:
        \\    return 1
        \\
    , "luce.sema.main");
    try expectRejected(
        \\func main() -> i64:
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
        \\    x: i64
        \\    y: i64
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
        \\    value: i64
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
        \\    value: i64
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
        \\const width = 80
        \\
        \\func main():
        \\    width = 3
        \\
    , "luce.sema.const", "width is a file-scope constant");

    // Existing-name multi-assignment performs the same preflight before
    // the call runs and keeps constants in the constants diagnostic
    // family rather than calling them let-bound locals.
    try expectSaying(
        \\func pair() -> (i64, i64):
        \\    return 1, 2
        \\
        \\const left = 0
        \\
        \\func main():
        \\    var right: i64 = 0
        \\    left, right = pair()
        \\
    , "luce.sema.const", "left is a file-scope constant");

    // A writing method is a mutation of its receiver, so a file-scope
    // constant refuses it in the constants family too — and never
    // silently drops the call (the compile that reports success while
    // deleting a statement is the one failure a build cannot see).
    try expectSaying(
        \\struct Counter:
        \\    value: i64
        \\
        \\    func bump():
        \\        self.value += 1
        \\
        \\const START = Counter(value = 1)
        \\
        \\func main():
        \\    START.bump()
        \\
    , "luce.sema.const", "START is a file-scope constant; bump writes its implicit self");
}

test "luce.sema.field: an unknown field is named wherever the chain meets it" {
    // The same helper answers for a read, a single-level write, and a
    // nested place; each reaches it by its own path.
    try expectSaying(
        \\struct Point:
        \\    x: i64
        \\
        \\func main():
        \\    let p = Point(x = 1)
        \\    let bad = p.z
        \\
    , "luce.sema.field", "Point has no field z");
    try expectSaying(
        \\struct Point:
        \\    x: i64
        \\
        \\func main():
        \\    var p = Point(x = 1)
        \\    p.z = 2
        \\
    , "luce.sema.field", "Point has no field z");
    try expectSaying(
        \\struct Inner:
        \\    value: i64
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
        \\    value: i64
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
        \\    value: i64
        \\
        \\struct Outer:
        \\    inner: Inner
        \\
        \\func main():
        \\    var held = Outer(inner = Inner(value = 1))
        \\    held.inner.value = 1.5
        \\
    , "luce.sema.type", "this place holds i64 but the value is f64");
    // `compoundCombine`'s own "needs matching types" has no case
    // here, and cannot: all four callers — name, field, element,
    // chain — compare the place with the value before they combine,
    // each in its own words, so the helper's copy of the check is
    // never the one that fires.  What the helper *does* answer for is
    // the place that has no compound form at all, which is where a
    // bool lands.
    try expectSaying(
        \\func main():
        \\    var flags = [true, false]
        \\    flags[0] += true
        \\
    , "luce.sema.type", "has no compound assignment");
}

test "luce.sema.type: an empty bracket literal needs a container annotation" {
    // The same literal can build a list or a rank-1 array now, so all
    // three contexts name the two annotations that can decide it.
    try expectSaying(
        \\func main():
        \\    var xs = []
        \\
    , "luce.sema.type", "an empty [] needs a list[T] or array[T, _] annotation");
    try expectSaying(
        \\func main():
        \\    var xs: i64 = []
        \\
    , "luce.sema.type", "an empty [] needs a list[T] or array[T, _] annotation");
    try expectSaying(
        \\func main():
        \\    let size = len([])
        \\
    , "luce.sema.type", "an empty [] needs a list[T] or array[T, _] annotation");
}

test "luce.sema.index: every shape of index says what it will accept" {
    try expectSaying(
        \\func main():
        \\    var grid = new array[i64](2, 2, 2, 2)
        \\    let bad = grid[0, 0, 0, 0, 0]
        \\
    , "luce.sema.index", "at most 4 index dimensions");
    try expectSaying(
        \\func main():
        \\    var grid = new array[i64](2, 2)
        \\    let bad = grid[0, 1.5]
        \\
    , "luce.sema.index", "array indices are i64");
    try expectSaying(
        \\func main():
        \\    var b = new builder
        \\    let bad = b[0]
        \\
    , "luce.sema.index", "builder has no index");
    // A slice's bounds are a *type* fault rather than an indexing one:
    // what is wrong is the value written, not the shape of the access.
    try expectSaying(
        \\func main():
        \\    var xs = [1, 2, 3]
        \\    let bad = xs[0:1.5]
        \\
    , "luce.sema.type", "slice bounds are i64");
    try expectSaying(
        \\func main():
        \\    var b = new builder
        \\    let bad = b[0:1]
        \\
    , "luce.sema.index", "cannot be sliced");
}

test "luce.sema.loop: for takes a rank-1 array and nothing wider" {
    try expectSaying(
        \\func main():
        \\    var grid = new array[i64](2, 2)
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
    , "luce.sema.type", "argument 1 of byte_at is i64, got str", 3, 25);
    try expectSayingAt(
        \\func main():
        \\    var s = "abc"
        \\    let bad = s.find_byte("x", 0)
        \\
    , "luce.sema.type", "argument 1 of find_byte is u8, got str", 3, 27);
    try expectSaying(
        \\func main():
        \\    var grid = new array[i64](2, 2)
        \\    grid.sort()
        \\
    , "luce.sema.method", "only rank-1 arrays have sort");
    try expectSaying(
        \\func main():
        \\    var m = new map[str, i64]
        \\    let bad = m.hass("a")
        \\
    , "luce.sema.method", "did you mean has?");
    try expectSaying(
        \\func main():
        \\    var b = new builder
        \\    b.appen("x")
        \\
    , "luce.sema.method", "did you mean append?");
    try expectSaying(
        \\func main():
        \\    var b = new builder
        \\    b.zzzzzz()
        \\
    , "luce.sema.method", "(append append_ascii build clear)");
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
// "argument 2 of add is long, got string" for a type, the latter
// underlined at the argument itself.  The built-in methods wrote one
// sentence for both, phrased as a count: `xs.append("hi")` on a
// `list(long)` was told "append takes one element value" while holding
// exactly one element value, and the caret covered the whole call.
//
// These pin the sentence, the code and the caret column together,
// because the three rot separately: nothing here failed when the
// message said one thing and the underline pointed at another.

test "luce.sema.method: a count mistake names the method and both counts" {
    try expectSayingAt(
        \\func main():
        \\    var xs = new list[i64]
        \\    xs.append(1, 2)
        \\
    , "luce.sema.method", "append takes 1 argument, got 2", 3, 5);
    // Zero is a count like any other, and reads differently from two.
    try expectSayingAt(
        \\func main():
        \\    var xs = new list[i64]
        \\    xs.append()
        \\
    , "luce.sema.method", "append takes 1 argument, got 0", 3, 5);
    // A method that takes none says "0 arguments", not "no arguments":
    // one sentence for every arity is one sentence to keep true.
    try expectSayingAt(
        \\func main():
        \\    var xs = new list[i64]
        \\    xs.sort(1)
        \\
    , "luce.sema.method", "sort takes 0 arguments, got 1", 3, 5);
    // Three arguments used to be answered by "no method takes more
    // than 2 arguments", which named neither the method nor a count —
    // an internal limit of the dispatch, worded as advice.  The
    // per-method count check had always been able to answer it.
    try expectSayingAt(
        \\func main():
        \\    var m = new map[str, i64]
        \\    let x = m.get("a", 1, 2)
        \\
    , "luce.sema.method", "get takes 1 argument, got 3", 3, 13);
}

test "luce.sema.type: a wrong argument type names the position, both types, and underlines the argument" {
    try expectSayingAt(
        \\func main():
        \\    var xs = new list[i64]
        \\    xs.append("hello")
        \\
    , "luce.sema.type", "argument 1 of append is i64, got str", 3, 15);
    // The second slot is reported as the second slot, and the caret
    // moves to it rather than staying on the receiver.
    try expectSayingAt(
        \\func main():
        \\    var xs = new list[str]
        \\    xs.insert("zero", 0)
        \\
    , "luce.sema.type", "argument 1 of insert is i64, got str", 3, 15);
    try expectSayingAt(
        \\func main():
        \\    var b = new builder
        \\    b.append(65)
        \\
    , "luce.sema.type", "argument 1 of append is str, got i64", 3, 14);
    // The map says what its key and value types *are*, rather than
    // calling them "the map's key and value types".
    try expectSayingAt(
        \\func main():
        \\    var m = new map[str, i64]
        \\    let x = m.get(1)
        \\
    , "luce.sema.type", "argument 1 of get is str, got i64", 3, 19);
}

test "luce.sema.type: a T? argument to a method earns the same advice it earns anywhere" {
    // This is the sentence that teaches optionals, and the method
    // path used to drop it: the reader got "append takes one element
    // value" and no mention of absence at all.  It is now the one
    // `lowerUserCall` writes, down to the name in the parentheses.
    try expectSayingAt(
        \\func maybe() -> i64?:
        \\    return none
        \\
        \\func main():
        \\    var xs = new list[i64]
        \\    let m = maybe()
        \\    xs.append(m)
        \\
    ,
        "luce.sema.type",
        "argument 1 of append is i64, got i64?; test it first (if m != none:) or supply a fallback (m else …)",
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
    // Too few arguments names the slots left open, exactly as a user
    // function's call would (docs/ARGS.md §8).
    try expectSayingAt(
        \\func main():
        \\    let x = min(1)
        \\
    , "luce.sema.call", "min is missing b", 2, 13);
    // Too many is still the count sentence.
    try expectSayingAt(
        \\func main():
        \\    let x = min(1, 2, 3)
        \\
    , "luce.sema.call", "min takes 2 arguments, got 3", 2, 13);
}

test "luce.sema.method: a missing method names the receiver it is missing from" {
    // map and builder always said which they were; list and array
    // said "no method sortt here", where "here" named nothing.
    try expectSayingAt(
        \\func main():
        \\    var xs = new list[i64]
        \\    xs.sortt()
        \\
    , "luce.sema.method", "list has no method sortt; did you mean sort?", 3, 5);
    try expectSayingAt(
        \\func main():
        \\    var xs = new list[i64]
        \\    xs.zzzzzz()
        \\
    ,
        "luce.sema.method",
        "list has no method zzzzzz (has append insert remove pop sort reverse find contains clear; sort_by lives in lists; join lives in strings)",
        3,
        5,
    );
    // An array is offered the methods an array has, not a list's.
    try expectSayingAt(
        \\func main():
        \\    var grid = new array[i64](4)
        \\    grid.zzzzzz()
        \\
    , "luce.sema.method", "array has no method zzzzzz (has dim fill sort reverse find contains)", 3, 5);
    // A string method routes through the strings module, but the
    // reader wrote a string — answering "strings has no function"
    // names a desugaring target they never typed.
    try expectSayingAt(
        \\import std.strings
        \\
        \\func main():
        \\    let s = "x"
        \\    let n = s.frobnicate()
        \\
    , "luce.sema.method", "str has no method frobnicate, and neither has the strings module", 5, 13);
}

test "luce.sema.call: a user function agrees with itself about one argument" {
    try expectSayingAt(
        \\func twice(a: i64) -> i64:
        \\    return a * 2
        \\
        \\func main():
        \\    let x = twice(1, 2)
        \\
    , "luce.sema.call", "twice takes 1 argument, got 2", 5, 13);
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
        \\    var x: i64(str) = 1
        \\
    , "luce.parse.type", "type arguments use brackets: write i64[...]");
    try expectSaying(
        \\func main():
        \\    var m: map[i64] = new map[i64, i64]
        \\
    , "luce.sema.container.type", "map takes key and value types");
    try expectSaying(
        \\func main():
        \\    var a: array[i64] = new array[i64](2)
        \\
    , "luce.sema.type", "array spells element and rank");
    try expectSaying(
        \\func main():
        \\    var b: builder[i64] = new builder
        \\
    , "luce.sema.type", "builder takes no type arguments");
    try expectSaying(
        \\struct Point:
        \\    x: i64
        \\
        \\func main():
        \\    var p: Point[i64] = Point(x = 1)
        \\
    , "luce.sema.type", "Point takes no type arguments");
    // `None?` has no test because it has no input: `resolveBase`
    // answers bool, long, double, string, a struct or a heap type and
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
        \\const width = 80
        \\const width = 90
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.duplicate", "duplicate name width");
}

// The storage widths' own diagnostics (docs/TYPES.md step 5).  These
// are the three rungs `rangeMessage` used to answer for with `long`'s
// sentence — a literal past a `byte` was told about nine quintillion,
// and a `half` literal was called an integer.
test "luce.sema.literal: an integer past a byte names byte's range and a short" {
    try expectOnlySayingAt(
        \\func main():
        \\    var b: u8 = 300
        \\
    ,
        "luce.sema.literal",
        "integer literal out of range; u8 holds 0 to 255 — write the place as i16",
        2,
        17,
    );
    // A byte is the one unsigned type there is (D4), so below zero is
    // out of range in exactly the same way as above 255.
    try expectOnlySayingAt(
        \\func main():
        \\    var b: u8 = -1
        \\
    ,
        "luce.sema.literal",
        "integer literal out of range; u8 holds 0 to 255 — write the place as i16",
        2,
        17,
    );
}

test "luce.sema.literal: an integer past a short names short's range and an int" {
    try expectOnlySayingAt(
        \\func main():
        \\    var s: i16 = 32768
        \\
    ,
        "luce.sema.literal",
        "integer literal out of range; i16 holds -32768 to 32767 — write the place as i32",
        2,
        18,
    );
}

test "luce.sema.literal: a float past a half names half's range and a float" {
    try expectOnlySayingAt(
        \\func main():
        \\    var h: f16 = 100000.0
        \\
    ,
        "luce.sema.literal",
        "float literal is not a finite f16; f16 holds up to about 65504 — write the place as f32",
        2,
        18,
    );
}

test "luce.sema.type: narrowing into a storage width is refused like any other" {
    try expectOnlySayingAt(
        \\func main():
        \\    var wide: i64 = 5
        \\    var narrow: u8 = wide
        \\
    ,
        "luce.sema.type",
        "narrow declared u8 but initialized with i64; narrowing is never implicit — write u8(…)",
        3,
        5,
    );
    try expectOnlySayingAt(
        \\func main():
        \\    var wide: f64 = 5.0
        \\    var narrow: f16 = wide
        \\
    ,
        "luce.sema.type",
        "narrow declared f16 but initialized with f64; narrowing is never implicit — write f16(…)",
        3,
        5,
    );
}

test "luce.sema.type: a byte reaches a double unbidden but never a float" {
    // Rule 3 of the ladder: widening is implicit along a ladder, and
    // *across* the two only into `double`.  A `byte` is exact in a
    // `float`, which is exactly why this has to be refused on purpose
    // rather than by accident — the rule is about there being one
    // cross-family answer, not about which values happen to fit.
    // Java's `int -> float` is the widening this declines to grow, one
    // rung lower down.  The allowed direction, `double d = b`, is in
    // behavior_spec beside the rest of the promotion.
    try expectOnlySayingAt(
        \\func main():
        \\    var b: u8 = 7
        \\    var f: f32 = b
        \\
    ,
        "luce.sema.type",
        "f declared f32 but initialized with u8; narrowing is never implicit — write f32(…)",
        3,
        5,
    );
    // A `short` is the same decision one rung up, and a `half` is the
    // mirror image on the other ladder: it reaches a `float` and a
    // `double` and no integer at all.
    try expectOnlySayingAt(
        \\func main():
        \\    var h: f16 = 1.5
        \\    var n: i64 = h
        \\
    ,
        "luce.sema.type",
        "n declared i64 but initialized with f16; narrowing is never implicit — write i64(…)",
        3,
        5,
    );
}

// ---------------------------------------------------------------------------
// Enums, and the match statement (docs/ENUMS.md)
// ---------------------------------------------------------------------------
//
// The refusals the memo names, each pinned by its sentence.  The rule
// they are all one rule of: an enum is a *set of names*, so everything
// that would quietly turn it back into a number, or leave a name
// unaccounted for, is refused where it is written.

test "luce.sema.enum: two members may not hold one number" {
    try expectSaying(
        \\enum Method:
        \\    stored = 0
        \\    also_stored = 0
        \\
        \\func main():
        \\    return
        \\
    ,
        "luce.sema.enum",
        "stored and also_stored are both 0; every member of an enum holds its own number",
    );
    // Sequential defaults collide the same way, and are caught the
    // same way: `c` is written 1 and `b` was given it.
    try expectSaying(
        \\enum Step:
        \\    a
        \\    b = 1
        \\    c = 1
        \\
        \\func main():
        \\    return
        \\
    ,
        "luce.sema.enum",
        "b and c are both 1",
    );
}

test "luce.sema.enum: a member past the backing width is refused, naming the width" {
    try expectSaying(
        \\enum Method(u8):
        \\    stored = 0
        \\    deflated = 300
        \\
        \\func main():
        \\    return
        \\
    ,
        "luce.sema.enum",
        "deflated = 300 does not fit u8, which holds 0 to 255",
    );
    // The width one rung up holds it, which is what the sentence
    // suggests and what this proves.
    try expectCompiles(
        \\enum Method(i16):
        \\    stored = 0
        \\    deflated = 300
        \\
        \\func main():
        \\    return
        \\
    );
}

test "luce.sema.enum: the backing type is one of the eight integer widths" {
    try expectSaying(
        \\enum Method(f64):
        \\    stored
        \\
        \\func main():
        \\    return
        \\
    ,
        "luce.sema.enum",
        "an enum is stored at an integer width: u8, u16, u32, u64, i8, i16, i32, or i64 — not f64",
    );
}

test "luce.sema.enum: an enum with no members is not a set of anything" {
    try expectRejected(
        \\enum Method:
        \\    static func none_of_them() -> i64:
        \\        return 0
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.enum");
}

test "luce.sema.match: a missing member is named, and so are all of them" {
    try expectSaying(
        \\enum Colour:
        \\    red
        \\    green
        \\    blue
        \\
        \\func main():
        \\    let c = Colour.red
        \\    match c:
        \\        red:
        \\            return
        \\        green:
        \\            return
        \\
    ,
        "luce.sema.match",
        "this match has no arm for member blue of Colour",
    );
    try expectSaying(
        \\enum Colour:
        \\    red
        \\    green
        \\    blue
        \\
        \\func main():
        \\    let c = Colour.red
        \\    match c:
        \\        red:
        \\            return
        \\
    ,
        "luce.sema.match",
        "this match has no arm for members green and blue of Colour",
    );
}

test "luce.sema.match: an arm may not be written twice" {
    try expectSaying(
        \\enum Colour:
        \\    red
        \\    green
        \\
        \\func main():
        \\    let c = Colour.red
        \\    match c:
        \\        red:
        \\            return
        \\        red:
        \\            return
        \\        green:
        \\            return
        \\
    ,
        "luce.sema.match",
        "red already has an arm in this match",
    );
}

test "luce.sema.match: an arm that names no member says so, and offers one" {
    try expectSaying(
        \\enum Colour:
        \\    red
        \\    green
        \\
        \\func main():
        \\    let c = Colour.red
        \\    match c:
        \\        redd:
        \\            return
        \\        green:
        \\            return
        \\
    ,
        "luce.sema.match",
        "redd is not a member of Colour; did you mean red?",
    );
}

test "luce.sema.match: an else that can never run is refused, like every dead arm" {
    try expectSaying(
        \\enum Colour:
        \\    red
        \\    green
        \\
        \\func main():
        \\    let c = Colour.red
        \\    match c:
        \\        red:
        \\            return
        \\        green:
        \\            return
        \\        else:
        \\            return
        \\
    ,
        "luce.sema.match",
        "every member of Colour already has an arm, so this else can never run; drop it",
    );
}

test "luce.sema.match: the scrutinee is an enum and nothing else" {
    try expectSaying(
        \\func main():
        \\    let n = 3
        \\    match n:
        \\        one:
        \\            return
        \\
    ,
        "luce.sema.match",
        "match dispatches over an enum or a union, and i64 is neither",
    );
}

test "luce.sema.type: an enum has no order, and the sentence says what does" {
    try expectSaying(
        \\enum Method:
        \\    stored
        \\    deflated
        \\
        \\func main():
        \\    let a = Method.stored
        \\    let b = Method.deflated
        \\    assert(a < b)
        \\
    ,
        "luce.sema.type",
        "Method is a set of names and has no order; write i64(a) < i64(b)",
    );
}

test "luce.sema.type: a member is not a number and a number is not a member" {
    // Neither direction is implicit (D4): the number has to be asked
    // for, and so does the member.
    try expectSaying(
        \\enum Method:
        \\    stored
        \\    deflated
        \\
        \\func main():
        \\    let m = Method.deflated
        \\    assert(m == 1)
        \\
    ,
        "luce.sema.type",
        "operands of == are Method and i64, and there is no conversion between them",
    );
    try expectSaying(
        \\enum Method:
        \\    stored
        \\    deflated
        \\
        \\func main():
        \\    let m: Method = 1
        \\
    ,
        "luce.sema.type",
        "m declared Method but initialized with i64",
    );
    try expectSaying(
        \\enum Method:
        \\    stored
        \\    deflated
        \\
        \\func want(n: i64) -> i64:
        \\    return n
        \\
        \\func main():
        \\    assert(want(Method.stored) == 0)
        \\
    ,
        "luce.sema.type",
        "argument 1 of want is i64, got Method",
    );
}

test "luce.sema.convert: Method(x) reads a whole number" {
    try expectSaying(
        \\enum Method:
        \\    stored
        \\    deflated
        \\
        \\func main():
        \\    let m = Method(1.5)
        \\
    ,
        "luce.sema.convert",
        "Method(value) reads a whole number and answers Method?; f64 is not one",
    );
}

test "luce.sema.match: a member that does not exist is not a value either" {
    try expectSaying(
        \\enum Method:
        \\    stored
        \\    deflated
        \\
        \\func main():
        \\    let m = Method.stord
        \\
    ,
        "luce.sema.match",
        "stord is not a member of Method; did you mean stored?",
    );
}

test "luce.sema.duplicate: an enum shares the type-name space, and its members the member space" {
    try expectSaying(
        \\struct Method:
        \\    size: i64
        \\
        \\enum Method:
        \\    stored
        \\
        \\func main():
        \\    return
        \\
    ,
        "luce.sema.duplicate",
        "duplicate name Method; the first is on line 1",
    );
    try expectSaying(
        \\enum Method:
        \\    stored
        \\
        \\    static func stored() -> i64:
        \\        return 0
        \\
        \\func main():
        \\    return
        \\
    ,
        "luce.sema.duplicate",
        "enum Method already has member stored",
    );
    try expectSaying(
        \\enum Method:
        \\    stored
        \\    stored
        \\
        \\func main():
        \\    return
        \\
    ,
        "luce.sema.duplicate",
        "duplicate member stored of enum Method",
    );
}

test "luce.sema.const: a member folds, and Method(n) does not" {
    try expectSaying(
        \\enum Method:
        \\    stored
        \\    deflated
        \\
        \\const chosen = Method(1)
        \\
        \\func main():
        \\    return
        \\
    ,
        "luce.sema.const",
        "Method(…) is a runtime lookup that answers Method?; name the constant member: Method.stored",
    );
}

test "private on an enum gates nothing inside its own file" {
    // Visibility is about the module boundary and there is no smaller
    // one (VISIBILITY.md D1), so the mark is inert here.  What it does
    // across a boundary — the type, a member, the constructor and a
    // namespace function all withheld by name — needs two files, and
    // is proved in `compile/test.zig`.
    try expectCompiles(
        \\private enum Method:
        \\    stored
        \\    deflated
        \\
        \\    static func first() -> Method:
        \\        return Method.stored
        \\
        \\func main():
        \\    let m = Method.stored
        \\    assert(m == Method.first())
        \\
    );
}

test "luce.sema.type: a map keys by every integer width, str, or an enum" {
    try expectCompiles(
        \\enum Method:
        \\    stored
        \\    deflated
        \\
        \\func main():
        \\    var counts = new map[Method, i64]
        \\    counts[Method.deflated] = 1
        \\    assert(counts.has(Method.deflated))
        \\
    );
    try expectCompiles(
        \\enum Method:
        \\    stored
        \\    deflated
        \\
        \\func main():
        \\    var chosen = new map[str, Method]
        \\    chosen["a"] = Method.deflated
        \\    assert(chosen["a"] == Method.deflated)
        \\
    );
    try expectCompiles(
        \\func main():
        \\    var counts = new map[i32, i64]
        \\    counts[i32(1)] = 2
        \\    assert(counts[i32(1)] == 2)
        \\
    );
    try expectSaying(
        \\func main():
        \\    var counts = new map[f64, i64]
        \\
    ,
        "luce.sema.type",
        "map keys are an integer, str or an enum, got f64",
    );
    try expectSaying(
        \\struct Point:
        \\    x: i64
        \\
        \\func main():
        \\    var counts = new map[Point, i64]
        \\
    ,
        "luce.sema.type",
        "map keys are an integer, str or an enum, got Point",
    );
    try expectSaying(
        \\func main():
        \\    var counts = new map[list[i64], i64]
        \\
    ,
        "luce.sema.type",
        "map keys are an integer, str or an enum, got list[i64]",
    );
}

test "luce.sema.type: an enum key is that enum, and no other type reaches it" {
    // The hole this closes: `map(Key, V)` typed at `Key` accepts a
    // `Key`, and a number is a type error rather than a coercion — an
    // enum reaches no number with nothing written down and no number
    // reaches an enum at all (D4, `Type.widensTo`).
    try expectSaying(
        \\enum Key:
        \\    left
        \\    right
        \\
        \\func main():
        \\    var counts = new map[Key, i64]
        \\    counts[0] = 1
        \\
    ,
        "luce.sema.index",
        "this map is keyed by Key",
    );
    try expectSaying(
        \\enum Key:
        \\    left
        \\
        \\enum Other:
        \\    first
        \\
        \\func main():
        \\    var counts = new map[Key, i64]
        \\    counts[Other.first] = 1
        \\
    ,
        "luce.sema.index",
        "this map is keyed by Key",
    );
    try expectSaying(
        \\enum Key:
        \\    left
        \\
        \\func main():
        \\    var counts = new map[i64, i64]
        \\    counts[Key.left] = 1
        \\
    ,
        "luce.sema.index",
        "this map is keyed by i64",
    );
    try expectSaying(
        \\enum Key:
        \\    left
        \\
        \\func main():
        \\    var counts = new map[Key, i64]
        \\    assert(counts.has(0))
        \\
    ,
        "luce.sema.type",
        "argument 1 of has is Key, got i64",
    );
    // A union is still refused, with the advice that is its own.
    try expectSaying(
        \\union Shape:
        \\    circle(radius: f64)
        \\    square(side: f64)
        \\
        \\func main():
        \\    var counts = new map[Shape, i64]
        \\
    ,
        "luce.sema.type",
        "a union has no key form — keep Shape in the value",
    );
}

test "luce.sema.const: a constant keymap refuses a duplicated member" {
    // Duplicate folded keys are refused whatever the key type is: an
    // enum key folds to its member's number, and `verifyDistinctKeys`
    // compares keys as they are stored (docs/CONSTANTS.md).
    try expectSaying(
        \\enum Key:
        \\    left
        \\    right
        \\
        \\const bindings = {Key.left: 1, Key.right: 2, Key.left: 3}
        \\
        \\func main():
        \\    return
        \\
    ,
        "luce.sema.const",
        "map key Key.left is duplicated; it was first written on line 5",
    );
}

// ---------------------------------------------------------------------------
// Workers (docs/THREADS.md)
// ---------------------------------------------------------------------------
//
// The refusals *are* the design: a worker has a runtime of its own, so
// every one of them is the same sentence said at a different site.

test "luce.sema.type: call arguments fit before ownership advice" {
    try expectOnlySayingAt(
        \\func consume(items: list[i64]):
        \\    return
        \\
        \\func main():
        \\    var running = new list[task[i64]]
        \\    consume(running)
        \\
    ,
        "luce.sema.type",
        "argument 1 of consume is list[i64], got list[task[i64]]",
        6,
        13,
    );

    try expectOnlySayingAt(
        \\func count(items: list[i64]) -> i64:
        \\    return len(items)
        \\
        \\func main():
        \\    let chosen: func(list[i64]) -> i64 = count
        \\    var running = new list[task[i64]]
        \\    let result = chosen(running)
        \\
    ,
        "luce.sema.type",
        "argument 1 of chosen is list[i64], got list[task[i64]]",
        7,
        25,
    );

    try expectOnlySayingAt(
        \\struct Sink:
        \\    marker: i64
        \\
        \\    func consume(items: list[i64]) -> i64:
        \\        return len(items) + self.marker
        \\
        \\func main():
        \\    let sink = Sink(marker = 0)
        \\    var running = new list[task[i64]]
        \\    let result = sink.consume(running)
        \\
    ,
        "luce.sema.type",
        "argument 1 of consume is list[i64], got list[task[i64]]",
        10,
        31,
    );

    // The reverse mismatch proves advice is based on the source type,
    // not on a resource-bearing destination type.
    try expectSaying(
        \\func keep(items: list[task[i64]]):
        \\    return
        \\
        \\func main():
        \\    var numbers = new list[i64]
        \\    keep(numbers)
        \\
    , "luce.sema.type", "argument 1 of keep is list[task[i64]], got list[i64]");

    // Indexed stores obey the same precedence.
    try expectSaying(
        \\func main():
        \\    var tasks = new list[task[i64]]
        \\    var numbers = new list[i64]
        \\    tasks[0] = numbers
        \\
    , "luce.sema.type", "this place holds task[i64] but the value is list[i64]");
}

test "luce.sema.new: a task is spawned, not made" {
    try expectSaying(
        \\func main():
        \\    var t = new task[i64]
        \\
    , "luce.sema.new", "a task is spawned, not made");
}

test "luce.sema.self: a method cannot be spawned" {
    try expectSaying(
        \\struct Point:
        \\    x: i64
        \\
        \\    func doubled() -> i64:
        \\        return self.x * 2
        \\
        \\func main():
        \\    let p = Point(x = 3)
        \\    let t = spawn p.doubled()
        \\
    , "luce.sema.self", "a worker cannot reach it");
}

test "luce.sema.call: spawn runs a function you declared" {
    try expectRejectedOptions(
        \\func main():
        \\    let t = spawn print("hello")
        \\
    , hosted, "luce.sema.call");
    // Function values cross the worker boundary as ordinary value
    // arguments and results, but the spawn target itself remains the
    // declaration-index channel THREADS.md specifies.
    try expectHostSaying(
        \\func twice(n: i64) -> i64:
        \\    return n * 2
        \\
        \\func main():
        \\    let chosen: func(i64) -> i64 = twice
        \\    let work = spawn chosen(21)
        \\
    , "luce.sema.call", "spawn runs a function you declared");
}

test "luce.sema.call: a worker answers one value, so a return shape is refused" {
    try expectSaying(
        \\func pair() -> (i64, i64):
        \\    return 1, 2
        \\
        \\func main():
        \\    let t = spawn pair()
        \\
    , "luce.sema.call", "a task carries one");
}

test "luce.parse.spawn: spawn takes a call and nothing else" {
    try expectRejected(
        \\func main():
        \\    var xs: list[i64] = [1]
        \\    let t = spawn xs
        \\
    , "luce.parse.spawn");
}

test "luce.sema.method: a task has wait and nothing else" {
    try expectRejected(
        \\func work() -> i64:
        \\    return 1
        \\
        \\func main():
        \\    let t = spawn work()
        \\    t.cancel()
        \\
    , "luce.sema.method");
}

test "luce.sema.const: a constant cannot spawn" {
    // The program root owns materialized constants, not a running
    // worker: a task's death point is a join and only a function scope
    // can reach one (MEMORY.md).
    try expectRejected(
        \\func work() -> i64:
        \\    return 1
        \\
        \\const started = spawn work()
        \\
        \\func main():
        \\    print("hi")
        \\
    , "luce.sema.const");
}

test "spawn is gated by nothing, because threads are the language" {
    // A host that cannot thread refuses at run time with
    // `host_unavailable` — the fail-closed rule every effect follows —
    // so there is no analyzer gate to write and none to test for.
    try expectCompiles(
        \\func work() -> i64:
        \\    return 1
        \\
        \\func main():
        \\    let t = spawn work()
        \\    assert(t.wait() == 1)
        \\
    );
}

// ---------------------------------------------------------------------------
// Functions as values, and the line at capture
// ---------------------------------------------------------------------------
//
// Every refusal docs/FUNCTIONS.md names, and each one says the thing
// that would fix it.  The two halves the design divides at are here
// together on purpose: what is *in* is proved in
// `specs/functions_spec.zig`, and what is out is proved here, so the
// line itself is readable in one place.

test "luce.sema.call: a method reference is refused, and taught" {
    // D1: a method reference is a closure over `self`, which is the far
    // side of the capture line — so the sentence shows the honest form,
    // which re-receives the receiver and therefore carries nothing.
    try expectHostSaying(
        \\struct Point:
        \\    x: i64
        \\
        \\    func length() -> i64:
        \\        return self.x
        \\
        \\func apply(f: func(Point) -> i64, p: Point) -> i64:
        \\    return f(p)
        \\
        \\func main():
        \\    let p = Point(x = 5)
        \\    print(str(apply(Point.length, p)))
        \\
    , "luce.sema.call", "a method reference would carry its receiver");
}

test "luce.sema.name: a lambda reaching an enclosing local is refused, and taught" {
    try expectHostSaying(
        \\func apply(f: func(i64) -> i64, x: i64) -> i64:
        \\    return f(x)
        \\
        \\func main():
        \\    let scale = 3
        \\    print(str(apply((n) -> n * scale, 2)))
        \\
    , "luce.sema.name", "a lambda carries no environment");

    // A captured function-valued local is still a capture when the
    // source writes it as a callee.  This used to take the unresolved
    // direct-call path and say "unknown function", even though the
    // declaration is visible two lines above.
    try expectHostSaying(
        \\func twice(n: i64) -> i64:
        \\    return n * 2
        \\
        \\func apply(f: func(i64) -> i64, x: i64) -> i64:
        \\    return f(x)
        \\
        \\func main():
        \\    let chosen: func(i64) -> i64 = twice
        \\    print(str(apply((n) -> chosen(n), 2)))
        \\
    , "luce.sema.name", "a lambda carries no environment");

    // Lexical shadowing still wins when the local happens to have an
    // imported module's name.  Synthesizing a top-level lambda must
    // not make the local disappear and silently expose that namespace.
    try expectHostSaying(
        \\import std.math
        \\
        \\func identity(n: f64) -> f64:
        \\    return n
        \\
        \\func apply(f: func(f64) -> f64, x: f64) -> f64:
        \\    return f(x)
        \\
        \\func main():
        \\    let math: func(f64) -> f64 = identity
        \\    print(str(apply((x) -> math.round(x), 2.5)))
        \\
    , "luce.sema.name", "a lambda carries no environment");
    try expectHostSaying(
        \\import std.math
        \\
        \\func read(f: func() -> f64) -> f64:
        \\    return f()
        \\
        \\func main():
        \\    let math = 1.0
        \\    print(str(read(() -> math.pi)))
        \\
    , "luce.sema.name", "a lambda carries no environment");

    // That capture set crosses every synthesized-lambda boundary.  A
    // grandparent local must neither become merely "unknown" nor be
    // mistaken for an imported namespace after the middle lambda is
    // lifted to the top level.
    try expectHostSaying(
        \\func apply(f: func(i64) -> i64, x: i64) -> i64:
        \\    return f(x)
        \\
        \\func main():
        \\    let step = 4
        \\    let nested: func(i64) -> i64 = (x) -> apply((y) -> y + step, x)
        \\    print(str(nested(1)))
        \\
    , "luce.sema.name", "a lambda carries no environment");
    try expectHostSaying(
        \\import std.math
        \\
        \\func apply(f: func(f64) -> f64, x: f64) -> f64:
        \\    return f(x)
        \\
        \\func main():
        \\    let math = 1.0
        \\    let nested: func(f64) -> f64 = (x) -> apply((y) -> math.round(y), x)
        \\    print(str(nested(2.75)))
        \\
    , "luce.sema.name", "a lambda carries no environment");
}

test "luce.sema.type: function values have neither ordering nor equality" {
    try expectHostSaying(
        \\func before(a: i64, b: i64) -> bool:
        \\    return a < b
        \\
        \\func main():
        \\    let left: func(i64, i64) -> bool = before
        \\    let right: func(i64, i64) -> bool = before
        \\    print(str(left < right))
        \\
    , "luce.sema.type", "a function value has no order, and no equality either");
}

test "luce.sema.import: sort_by is routed through std lists" {
    try expectHostSaying(
        \\func before(a: i64, b: i64) -> bool:
        \\    return a < b
        \\
        \\func main():
        \\    var values: list[i64] = [3, 1, 2]
        \\    values.sort_by(before)
        \\
    , "luce.sema.import", "import std.lists");
}

test "luce.sema.type: sort_by's comparator has the receiver's element shape" {
    try expectHostSaying(
        \\import std.lists
        \\
        \\func unary(a: i64) -> bool:
        \\    return a > 0
        \\
        \\func main():
        \\    var values: list[i64] = [3, 1, 2]
        \\    values.sort_by(unary)
        \\
    , "luce.sema.type", "func(i64, i64) -> bool");
    try expectHostSaying(
        \\import std.lists
        \\
        \\func before(a: str, b: str) -> bool:
        \\    return a < b
        \\
        \\func main():
        \\    var values: list[i64] = [3, 1, 2]
        \\    values.sort_by(before)
        \\
    , "luce.sema.type", "func(i64, i64) -> bool");
    try expectHostSaying(
        \\import std.lists
        \\
        \\func difference(a: i64, b: i64) -> i64:
        \\    return a - b
        \\
        \\func main():
        \\    var values: list[i64] = [3, 1, 2]
        \\    values.sort_by(difference)
        \\
    , "luce.sema.type", "func(i64, i64) -> bool");
}

test "luce.sema.method: sort_by's routed method spelling is positional and list-only" {
    try expectHostSaying(
        \\import std.lists
        \\
        \\func before(a: i64, b: i64) -> bool:
        \\    return a < b
        \\
        \\func main():
        \\    var values: list[i64] = [3, 1, 2]
        \\    values.sort_by(before = before)
        \\
    , "luce.sema.method", "its comparator is positional here");
    try expectHostSaying(
        \\import std.lists
        \\
        \\func before(a: i64, b: i64) -> bool:
        \\    return a < b
        \\
        \\func main():
        \\    let comparator: func(i64, i64) -> bool = before
        \\    var values = new array[i64](3)
        \\    values.sort_by(comparator)
        \\
    , "luce.sema.method", "array has no method sort_by");
}

test "luce.sema.type: a lambda needs a place that expects a function" {
    try expectHostSaying(
        \\func main():
        \\    let f = (x) -> x + 1
        \\    print(str(f(1)))
        \\
    , "luce.sema.type", "a lambda needs a place that expects a function");
}

test "luce.parse.expression: a lambda is one expression, not a block" {
    try expectHostSaying(
        \\func apply(f: func(i64) -> i64, x: i64) -> i64:
        \\    return f(x)
        \\
        \\func main():
        \\    print(str(apply((x) ->:
        \\        return x, 1)))
        \\
    , "luce.parse.expression", "a lambda is one expression, not a block");
}

test "luce.sema.type: a lambda's parameter count must be the place's" {
    try expectHostSaying(
        \\func apply(f: func(i64) -> i64, x: i64) -> i64:
        \\    return f(x)
        \\
        \\func main():
        \\    print(str(apply((a, b) -> a + b, 2)))
        \\
    , "luce.sema.type", "this lambda writes 2");
}

test "luce.sema.type: a named function of the wrong shape is refused by shape" {
    try expectHostSaying(
        \\func wide(a: i64, b: i64) -> bool:
        \\    return a < b
        \\
        \\func apply(f: func(i64) -> i64, x: i64) -> i64:
        \\    return f(x)
        \\
        \\func main():
        \\    print(str(apply(wide, 2)))
        \\
    , "luce.sema.type", "func(i64) -> i64");
}

test "luce.sema.fallible: a fallible function is not a value yet" {
    // Its `!` is an obligation its call sites carry, and a function
    // type has nowhere to write one — so letting one become a value
    // would drop the obligation in silence.
    try expectHostSaying(
        \\func risky(path: str) -> str!:
        \\    return try file_read(path)
        \\
        \\func apply(f: func(str) -> str, x: str) -> str:
        \\    return f(x)
        \\
        \\func main():
        \\    print(apply(risky, "a.txt"))
        \\
    , "luce.sema.fallible", "a function type carries no '!'");
}

test "luce.parse.type: a function type carries no bang" {
    try expectHostSaying(
        \\func apply(f: func(str) -> str!, x: str) -> str:
        \\    return f(x)
        \\
        \\func main():
        \\    print("hi")
        \\
    , "luce.parse.type", "a function type carries no '!'");
}

test "luce.sema.type: a slot holds the optional form of a function value" {
    // Not a wall: a slot exists before anything fills it and a
    // function value has no zero, so the storable form is the optional
    // and the sentence spells it (docs/BINDING.md D7).  A list
    // element, an array element, a map value, a struct field and a
    // union payload field are the five slots there are.
    try expectHostSaying(
        \\func main():
        \\    var fs = new list[func(i64) -> i64]
        \\    print(str(len(fs)))
        \\
    , "luce.sema.type", "a list element starts before anything fills it and a function value has no zero: write (func(i64) -> i64)?");

    // The map is the exception, and it is stated as one: `get` already
    // answers `V?`, so the function type is written bare there and the
    // `?` would be a `V??`.
    try expectHostSaying(
        \\func main():
        \\    var fs = new map[str, (func(i64) -> i64)?]
        \\    print(str(len(fs)))
        \\
    , "luce.sema.type", "a map value is written bare: get already answers (func(i64) -> i64)?, and a second '?' would be a V??");

    try expectHostSaying(
        \\struct Handler:
        \\    run: func(i64) -> i64
        \\
        \\func main():
        \\    print("hi")
        \\
    , "luce.sema.type", "a struct field starts before anything fills it and a function value has no zero: write (func(i64) -> i64)?");

    try expectHostSaying(
        \\union Step:
        \\    run(with: func(i64) -> i64)
        \\
        \\func main():
        \\    print("hi")
        \\
    , "luce.sema.type", "a union payload field starts before anything fills it");
}

test "luce.sema.call: an unwrapped optional function is not callable" {
    // The storable form may hold none, so calling one takes the proof
    // every other `T?` takes (docs/BINDING.md D7).
    try expectHostSaying(
        \\struct Row:
        \\    action: (func(i64) -> i64)?
        \\
        \\func main():
        \\    let row = Row(action = (n) -> n + 1)
        \\    let held = row.action
        \\    print(str(held(1)))
        \\
    , "luce.sema.call", "held is (func(i64) -> i64)? and may hold none; test it first (if held != none:)");
}

test "luce.parse.type: one '?' is all there is, inside parentheses too" {
    try expectSaying(
        \\func main():
        \\    var n: (i64?)? = none
        \\
    , "luce.parse.type", "one '?' is all there is");
}

test "luce.sema.type: a function value has no zero, so a late var is refused" {
    try expectHostSaying(
        \\func main():
        \\    var f: func(i64) -> i64
        \\    print(str(f(1)))
        \\
    , "luce.sema.type", "a function value has no zero: write f = the function it names, or var f: (func(i64) -> i64)? for a slot that starts empty");
}

test "luce.sema.call: a value that is not a function cannot be called" {
    try expectHostSaying(
        \\func main():
        \\    let n = 3
        \\    print(str(n(1)))
        \\
    , "luce.sema.call", "which is not a function");
}

test "luce.sema.call: a call through a value takes the arity its type wrote" {
    try expectHostSaying(
        \\func apply(f: func(i64, i64) -> i64, x: i64) -> i64:
        \\    return f(x)
        \\
        \\func main():
        \\    print("hi")
        \\
    , "luce.sema.call", "takes 2 arguments, got 1");
}

test "luce.sema.call: a function type has no parameter names to call by" {
    try expectHostSaying(
        \\func apply(f: func(i64) -> i64, x: i64) -> i64:
        \\    return f(n = x)
        \\
        \\func main():
        \\    print("hi")
        \\
    , "luce.sema.call", "a function type has no parameter names");
}

test "luce.sema.const: a top-level const is not a place for a lambda" {
    try expectRejectedOptions(
        \\const f = (x) -> x + 1
        \\
        \\func main():
        \\    print("hi")
        \\
    , hosted, "luce.sema.const");
}

// ---------------------------------------------------------------------------
// The call suffix's refusals (docs/FUNCTIONS.md, docs/BINDING.md D7)
// ---------------------------------------------------------------------------

test "luce.sema.call: a field holding a function value is not a method" {
    try expectHostSaying(
        \\struct Rows:
        \\    render: (func(i64) -> str)?
        \\
        \\func label(index: i64) -> str:
        \\    return str(index)
        \\
        \\func main():
        \\    let rows = Rows(render = label)
        \\    print(rows.render(3))
        \\
    , "luce.sema.call", "bind it first (let render = rows.render)");
}

test "luce.sema.call: an element that may hold none is not called in place" {
    try expectHostSaying(
        \\func label(index: i64) -> str:
        \\    return str(index)
        \\
        \\func main():
        \\    var steps = new list[(func(i64) -> str)?]
        \\    steps.append(label)
        \\    print(steps[0](1))
        \\
    , "luce.sema.call", "only a local or a parameter narrows");
}

test "luce.sema.call: a field read through a grouping is refused the same way" {
    try expectHostSaying(
        \\struct Rows:
        \\    render: (func(i64) -> str)?
        \\
        \\func label(index: i64) -> str:
        \\    return str(index)
        \\
        \\func main():
        \\    let rows = Rows(render = label)
        \\    print((rows.render)(3))
        \\
    , "luce.sema.call", "bind it first (let render = rows.render)");
}

test "luce.sema.call: a callee that is not a function says so" {
    try expectHostSaying(
        \\func main():
        \\    var counts = new list[i64]
        \\    counts.append(1)
        \\    print(str(counts[0](2)))
        \\
    , "luce.sema.call", "which is not a function");
}

test "luce.sema.call: a call suffix with the wrong arity is counted" {
    try expectHostSaying(
        \\func plain(n: i64) -> str:
        \\    return str(n)
        \\
        \\func chooser() -> func(i64) -> str:
        \\    return plain
        \\
        \\func main():
        \\    print(chooser()(1, 2))
        \\
    , "luce.sema.call", "takes 1 argument, got 2");
}

test "luce.sema.type: a call suffix's argument is typed by the signature" {
    try expectHostSaying(
        \\func plain(n: i64) -> str:
        \\    return str(n)
        \\
        \\func chooser() -> func(i64) -> str:
        \\    return plain
        \\
        \\func main():
        \\    print(chooser()("two"))
        \\
    , "luce.sema.type", "argument 1 of");
}

test "luce.sema.call: a call suffix has no parameter names either" {
    try expectHostSaying(
        \\func plain(n: i64) -> str:
        \\    return str(n)
        \\
        \\func chooser() -> func(i64) -> str:
        \\    return plain
        \\
        \\func main():
        \\    print(chooser()(n = 1))
        \\
    , "luce.sema.call", "a function type has no parameter names");
}

test "luce.sema.fallible: a call through a value can never fail, so try is refused" {
    // A function type carries no `!` (docs/BINDING.md D8), so nothing
    // reached through one is fallible and `try` has nothing to pass on.
    try expectHostSaying(
        \\func plain(n: i64) -> str:
        \\    return str(n)
        \\
        \\func chooser() -> func(i64) -> str:
        \\    return plain
        \\
        \\func main():
        \\    print(try chooser()(1))
        \\
    , "luce.sema.fallible", "drop the try");
}

test "luce.parse.spawn: a worker runs a declared call, not a call suffix" {
    try expectHostSaying(
        \\func plain(n: i64) -> str:
        \\    return str(n)
        \\
        \\func chooser() -> func(i64) -> str:
        \\    return plain
        \\
        \\func main():
        \\    let t = spawn chooser()(1)
        \\    print(t.wait())
        \\
    , "luce.parse.spawn", "spawn runs a call on a worker");
}

test "luce.sema.interface: a struct must implement every interface method" {
    try expectHostSaying(
        \\interface UIElement:
        \\    func render(value: i64) -> i64
        \\
        \\struct UIButton: UIElement:
        \\    label: str
        \\
        \\func main():
        \\    let button = UIButton(label = "ok")
        \\    _ = button
        \\
    , "luce.sema.interface", "does not implement UIElement.render");
}

test "luce.sema.interface: a multi-method conformance checks every slot" {
    try expectHostSaying(
        \\interface Drawable:
        \\    func render(value: i64) -> i64
        \\    func label() -> str
        \\
        \\struct Button: Drawable:
        \\    marker: i64
        \\    func render(value: i64) -> i64:
        \\        return value + self.marker
        \\
        \\func main():
        \\    let button = Button(marker = 1)
        \\    _ = button
        \\
    , "luce.sema.interface", "does not implement Drawable.label");
}

test "luce.sema.interface: an implementation must match the contract signature" {
    try expectHostSaying(
        \\interface UIElement:
        \\    func render(value: i64) -> i64
        \\
        \\struct UIButton: UIElement:
        \\    label: str
        \\    func render(value: i64) -> str:
        \\        return value
        \\
        \\func main():
        \\    let button = UIButton(label = "ok")
        \\    _ = button
        \\
    , "luce.sema.interface", "does not match interface method");
}

test "luce.sema.interface: a writing method cannot satisfy a read-only interface" {
    try expectHostSaying(
        \\interface Counter:
        \\    func update(value: i64)
        \\
        \\struct Box: Counter:
        \\    value: i64
        \\    func update(value: i64):
        \\        self.value = value
        \\
        \\func main():
        \\    let box = Box(value = 0)
        \\    _ = box
        \\
    , "luce.sema.interface", "writes self");
}

test "luce.sema.interface: a conformance list names interfaces only" {
    try expectHostSaying(
        \\struct Box: i64:
        \\    value: i64
        \\
        \\func main():
        \\    let box = Box(value = 0)
        \\    _ = box
        \\
    , "luce.sema.interface", "names interfaces only");
}

test "luce.sema.interface: hidden dispatch fields cannot be read" {
    try expectHostSaying(
        \\interface UIElement:
        \\    func render(value: i64) -> i64
        \\
        \\struct UIButton: UIElement:
        \\    label: str
        \\    func render(value: i64) -> i64:
        \\        return value
        \\
        \\func read(element: UIElement) -> i64:
        \\    return element.render
        \\
        \\func main():
        \\    let button = UIButton(label = "ok")
        \\    print(str(read(button)))
        \\
    , "luce.sema.interface", "expose methods, not fields");
}

test "luce.sema.interface: a fallible witness cannot satisfy a non-fallible requirement" {
    try expectHostSaying(
        \\interface Reader:
        \\    func read(value: i64) -> i64
        \\
        \\struct Buffer: Reader:
        \\    marker: i64
        \\    func read(value: i64) -> i64!:
        \\        return value
        \\
        \\func main():
        \\    let buffer = Buffer(marker = 0)
        \\    _ = buffer
        \\
    , "luce.sema.interface", "does not match interface method");
}

test "luce.sema.interface: duplicate method requirements are rejected once" {
    try expectHostSaying(
        \\interface Duplicate:
        \\    func run(value: i64) -> i64
        \\    func run(other: i64) -> i64
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.duplicate", "interface Duplicate declares method run twice");
}

test "luce.sema.interface: static methods cannot be witnesses" {
    try expectHostSaying(
        \\interface Renderable:
        \\    func render(value: i64) -> i64
        \\
        \\struct Button: Renderable:
        \\    marker: i64
        \\    static func render(value: i64) -> i64:
        \\        return value
        \\
        \\func main():
        \\    let button = Button(marker = 0)
        \\    _ = button
        \\
    , "luce.sema.interface", "is static; an interface method needs an instance receiver");
}

test "luce.sema.interface: a conformance cannot be listed twice" {
    try expectHostSaying(
        \\interface Renderable:
        \\    func render(value: i64) -> i64
        \\
        \\struct Button: Renderable, Renderable:
        \\    marker: i64
        \\    func render(value: i64) -> i64:
        \\        return value
        \\
        \\func main():
        \\    let button = Button(marker = 0)
        \\    _ = button
        \\
    , "luce.sema.duplicate", "lists interface Renderable twice");
}

test "luce.sema.interface: a non-conforming struct cannot be passed as the contract" {
    try expectHostSaying(
        \\interface Renderable:
        \\    func render(value: i64) -> i64
        \\
        \\struct Button:
        \\    marker: i64
        \\    func render(value: i64) -> i64:
        \\        return value
        \\
        \\func draw(item: Renderable) -> i64:
        \\    return item.render(1)
        \\
        \\func main():
        \\    let button = Button(marker = 0)
        \\    print(str(draw(button)))
        \\
    , "luce.sema.type", "argument 1 of draw is Renderable, got Button");
}

test "luce.parse.interface: an interface must have at least one method" {
    try expectHostSaying(
        \\interface Empty:
        \\
        \\func main():
        \\    return
        \\
    , "luce.parse.expected", "expected an indented block under 'interface'");
}

test "luce.sema.interface: a multi-value witness must match every result" {
    try expectHostSaying(
        \\interface Measured:
        \\    func span(value: i64) -> (i64, i64)
        \\
        \\struct Range: Measured:
        \\    marker: i64
        \\    func span(value: i64) -> (i64, str):
        \\        return value, "wrong"
        \\
        \\func main():
        \\    let range = Range(marker = 0)
        \\    _ = range
        \\
    , "luce.sema.interface", "does not match interface method");
}

test "luce.sema.interface: a fallible dispatch must be handled" {
    try expectHostSaying(
        \\interface Reader:
        \\    func read(value: i64) -> i64!
        \\
        \\struct Buffer: Reader:
        \\    marker: i64
        \\    func read(value: i64) -> i64:
        \\        return value
        \\
        \\func main():
        \\    let buffer = Buffer(marker = 0)
        \\    let reader: Reader = buffer
        \\    print(str(reader.read(1)))
        \\
    , "luce.sema.fallible", "read can fail");
}

test "luce.parse.interface: interface methods cannot declare defaults" {
    try expectHostSaying(
        \\interface Defaulted:
        \\    func run(value: i64 = 1) -> i64
        \\
        \\func main():
        \\    return
        \\
    , "luce.parse.interface", "interface methods cannot declare defaults");
}

test "luce.parse.interface: interface bodies contain signatures only" {
    try expectHostSaying(
        \\interface Bad:
        \\    let value = 1
        \\
        \\func main():
        \\    return
        \\
    , "luce.parse.interface", "an interface contains method signatures");
}

test "luce.parse.self: interface methods imply their receiver" {
    try expectHostSaying(
        \\interface Bad:
        \\    func render(self: i64) -> i64
        \\
        \\func main():
        \\    return
        \\
    , "luce.parse.self", "self is implied in an interface method");
}

test "luce.sema.interface: an interface variable needs a conforming value" {
    try expectHostSaying(
        \\interface Renderable:
        \\    func render(value: i64) -> i64
        \\
        \\func main():
        \\    var item: Renderable
        \\    _ = item
        \\
    , "luce.sema.interface", "has no default implementation");
}

test "luce.sema.interface: an interface cannot be constructed directly" {
    try expectHostSaying(
        \\interface Renderable:
        \\    func render(value: i64) -> i64
        \\
        \\func main():
        \\    let item = Renderable()
        \\    _ = item
        \\
    , "luce.sema.interface", "interfaces cannot be constructed");
}

test "luce.sema.method: dispatch exposes only declared interface methods" {
    try expectHostSaying(
        \\interface Renderable:
        \\    func render(value: i64) -> i64
        \\
        \\struct Button: Renderable:
        \\    marker: i64
        \\    func render(value: i64) -> i64:
        \\        return value
        \\
        \\func main():
        \\    let item: Renderable = Button(marker = 0)
        \\    print(str(item.missing(1)))
        \\
    , "luce.sema.method", "interface Renderable has no method missing");
}

test "luce.sema.call: a multi-value interface call must be destructured" {
    try expectHostSaying(
        \\interface Measured:
        \\    func span(value: i64) -> (i64, i64)
        \\
        \\struct Range: Measured:
        \\    marker: i64
        \\    func span(value: i64) -> (i64, i64):
        \\        return value, value + 1
        \\
        \\func main():
        \\    let item: Measured = Range(marker = 0)
        \\    print(str(item.span(1)))
        \\
    , "luce.sema.call", "answers 2 values");
}
