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

const std = @import("std");
const compile_mod = @import("compile.zig");
const types = @import("types.zig");
const source_mod = @import("source.zig");

const testing = std.testing;

const script: types.CompileOptions = .{ .entry_mode = .script };
const evaluator: types.CompileOptions = .{ .entry_mode = .evaluator };

const Diagnostics = @import("diagnostics.zig").Diagnostics;

fn printAll(diagnostics: *const Diagnostics, source: []const u8) void {
    const rendered = diagnostics.render(testing.allocator, source) catch return;
    defer testing.allocator.free(rendered);
    std.debug.print("got:\n{s}", .{rendered});
}

/// Compile `source` (script mode, no host) and assert it fails with a
/// diagnostic carrying `code` somewhere in the list.  The everyday
/// rejection assertion.
fn expectError(source: []const u8, code: []const u8) !void {
    try expectErrorOptions(source, .{}, script, code);
}

fn expectErrorOptions(
    source: []const u8,
    schema: types.PortSchema,
    options: types.CompileOptions,
    code: []const u8,
) !void {
    var result = try compile_mod.compile(testing.allocator, source, schema, options);
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
            const rendered = try diagnostics.render(testing.allocator, source);
            defer testing.allocator.free(rendered);
            std.debug.print("wanted {s}, got:\n{s}", .{ code, rendered });
            return error.TestUnexpectedResult;
        },
    }
}

/// Assert the FIRST diagnostic is exactly `code` at `line`:`column`.
/// Used where the span itself is the guarantee under test.
fn expectErrorAt(source: []const u8, code: []const u8, line: usize, column: usize) !void {
    var result = try compile_mod.compile(testing.allocator, source, .{}, script);
    defer result.deinit();
    switch (result) {
        .success => return error.TestUnexpectedResult,
        .failure => |diagnostics| {
            const first = diagnostics.at(0) orelse return error.TestUnexpectedResult;
            errdefer printAll(&diagnostics, source);
            try testing.expectEqualStrings(code, first.code);
            const at = source_mod.place(source, first.span.start);
            try testing.expectEqual(line, at.line);
            try testing.expectEqual(column, at.column);
        },
    }
}

// ---------------------------------------------------------------------------
// Lexer
// ---------------------------------------------------------------------------

test "luce.lex.tab: tabs are rejected as indentation" {
    try expectError("func main():\n\tlet a = 1\n", "luce.lex.tab");
}

test "luce.lex.number: a digit run glued to letters is one bad literal" {
    try expectError("func main():\n    let a = 12ab\n", "luce.lex.number");
}

test "luce.lex.string: an unterminated string is caught" {
    try expectError("func main():\n    let a = \"open\n", "luce.lex.string");
}

test "luce.lex.escape: an unknown escape is rejected" {
    try expectError("func main():\n    let a = \"\\q\"\n", "luce.lex.escape");
}

test "luce.lex.character: a stray control byte is rejected" {
    try expectError("func main():\n    let a = 1\x00\n", "luce.lex.character");
}

test "luce.lex.utf8: a string of invalid UTF-8 is rejected" {
    try expectError("func main():\n    let a = \"\xff\xfe\"\n", "luce.lex.utf8");
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

test "luce.parse.top: only func/struct/let/import at file scope" {
    try expectError("fn main():\n    return\n", "luce.parse.top");
    try expectError("var counter = 0\n", "luce.parse.top");
}

test "luce.parse.expression: a missing expression is reported" {
    try expectError("func main():\n    let a = @\n", "luce.parse.expression");
}

test "luce.parse.expected: a malformed binding name is reported at the name" {
    try expectErrorAt("let 3 = 4\n", "luce.parse.expected", 1, 5);
}

test "luce.parse.nesting: pathological nesting is rejected, not overflowed" {
    const allocator = testing.allocator;
    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(allocator);
    try deep.appendSlice(allocator, "func main():\n    let x = ");
    for (0..2000) |_| try deep.append(allocator, '(');
    try deep.append(allocator, '1');
    try expectError(deep.items, "luce.parse.nesting");
}

// ---------------------------------------------------------------------------
// Entry contract
// ---------------------------------------------------------------------------

test "luce.sema.main: a script needs exactly func main()" {
    try expectError("func other():\n    return\n", "luce.sema.main");
    try expectError("func main(x: Int):\n    return\n", "luce.sema.main");
}

test "luce.sema.evaluate: an evaluator needs exactly the two-port entry" {
    try expectErrorOptions("func main():\n    return\n", .{}, evaluator, "luce.sema.evaluate");
}

// ---------------------------------------------------------------------------
// Names, declarations, reserved words
// ---------------------------------------------------------------------------

test "luce.sema.name: an unknown name is rejected" {
    try expectError("func main():\n    let a = ghost\n", "luce.sema.name");
}

test "luce.sema.duplicate: a name cannot be declared twice" {
    try expectError("func main():\n    let a = 1\n    let a = 2\n", "luce.sema.duplicate");
}

test "luce.sema.reserved: builtins cannot be shadowed" {
    try expectError("func main():\n    let len = 1\n", "luce.sema.reserved");
}

test "luce.sema.let: a let binding cannot be reassigned" {
    try expectError("func main():\n    let a = 1\n    a = 2\n", "luce.sema.let");
}

// ---------------------------------------------------------------------------
// Types and conversions
// ---------------------------------------------------------------------------

test "luce.sema.type: no implicit numeric conversion" {
    try expectError("func main():\n    let a = 1 + 2.0\n", "luce.sema.type");
}

test "luce.sema.type: a condition must be Bool" {
    try expectError("func main():\n    if 1:\n        return\n", "luce.sema.type");
}

test "luce.sema.type: an annotation must match the initializer" {
    try expectError("func main():\n    let a: Int = \"x\"\n", "luce.sema.type");
}

test "luce.sema.convert: Int and Float convert only their opposite" {
    try expectError("func main():\n    let a = Int(\"x\")\n", "luce.sema.convert");
    try expectError("func main():\n    let a = Float(true)\n", "luce.sema.convert");
}

// ---------------------------------------------------------------------------
// Fields, calls, methods, indexing
// ---------------------------------------------------------------------------

test "luce.sema.field: an unknown struct field is rejected" {
    try expectError(
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
    try expectError(
        \\func add(a: Int, b: Int) -> Int:
        \\    return a + b
        \\
        \\func main():
        \\    let x = add(1)
        \\
    , "luce.sema.call");
    try expectError("func main():\n    let x = nope(1)\n", "luce.sema.call");
}

test "luce.sema.method: a method must exist on its receiver type" {
    try expectError("func main():\n    let a = 5.append(1)\n", "luce.sema.method");
}

test "luce.sema.index: only heap containers index, with the right key" {
    try expectError("func main():\n    let a = 1[0]\n", "luce.sema.index");
}

// ---------------------------------------------------------------------------
// Construction, new, loops, returns
// ---------------------------------------------------------------------------

test "luce.sema.construct: a struct needs all fields, named, once" {
    try expectError(
        \\struct P:
        \\    x: Int
        \\    y: Int
        \\
        \\func main():
        \\    let p = P(x = 1)
        \\
    , "luce.sema.construct");
}

test "luce.sema.new: new builds only the heap types" {
    try expectError("func main():\n    let a = new Array(Int)\n", "luce.sema.new");
}

test "luce.sema.loop: break and continue need a loop" {
    try expectError("func main():\n    break\n", "luce.sema.loop");
}

test "luce.sema.return: return paths and value shape are checked" {
    try expectError(
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
    try expectError(
        \\struct Loop:
        \\    inner: Loop
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.struct");
}

test "luce.sema.const: a top-level let is a constant, not a computation" {
    try expectError("let bad = new List(Int)\n\nfunc main():\n    return\n", "luce.sema.const");
}

test "luce.sema.host: host builtins are gated off by default" {
    try expectError("func main():\n    print(\"hi\")\n", "luce.sema.host");
}
