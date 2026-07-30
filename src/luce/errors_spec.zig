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
// Compound assignment (value-only arithmetic sugar)
// ---------------------------------------------------------------------------

test "luce.sema.type: compound assignment is numbers, or += on String" {
    // Objects have no compound assignment.
    try expectError("func main():\n    var xs = [1, 2]\n    xs *= 3\n", "luce.sema.type");
    // Non-+ operators do not apply to String.
    try expectError("func main():\n    var s = \"a\"\n    s -= \"b\"\n", "luce.sema.type");
    // The two sides must share a type.
    try expectError("func main():\n    var n = 1\n    n += 2.0\n", "luce.sema.type");
}

test "luce.sema.let: a let binding cannot be compound-assigned either" {
    try expectError("func main():\n    let n = 1\n    n += 1\n", "luce.sema.let");
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

// ===========================================================================
// The exhaustive suite below extends the seed above, aiming for one case
// per genuinely distinct rejection path (Zig's test/cases/compile_errors
// analog).  The high-fanout codes — sema.type, sema.call, sema.method,
// sema.construct, sema.index, sema.return — get many cases; the lexer and a
// few common sema codes are additionally pinned to a line:column.
// ===========================================================================

/// A three-float-in, two-float-out schema for evaluator-mode cases,
/// mirroring compile.zig's point_schema.
const point_schema: types.PortSchema = .{
    .inputs = &.{
        .{ .name = "x", .declared = .float },
        .{ .name = "y", .declared = .float },
    },
    .outputs = &.{
        .{ .name = "x", .declared = .float },
        .{ .name = "y", .declared = .float },
    },
};

fn expectEvalError(source: []const u8, code: []const u8) !void {
    try expectErrorOptions(source, point_schema, evaluator, code);
}

// ---------------------------------------------------------------------------
// Lexer — pinned spans (the span is the product for an editor)
// ---------------------------------------------------------------------------

test "luce.lex.tab: a tab in indentation is pinned to its column" {
    try expectErrorAt("func main():\n\tlet a = 1\n", "luce.lex.tab", 2, 1);
}

test "luce.lex.tab: a tab mid-line is also rejected" {
    try expectErrorAt("func main():\n    let a =\t1\n", "luce.lex.tab", 2, 12);
}

test "luce.lex.indent: a dedent to no open column is rejected" {
    try expectErrorAt(
        "func main():\n    if 1 < 2:\n        let a = 1\n     let b = 2\n",
        "luce.lex.indent",
        4,
        1,
    );
}

test "luce.lex.number: a malformed literal is pinned to its start" {
    try expectErrorAt("func main():\n    let a = 12ab\n", "luce.lex.number", 2, 13);
}

test "luce.lex.string: an unterminated string is pinned to its opening quote" {
    try expectErrorAt("func main():\n    let a = \"open\n", "luce.lex.string", 2, 13);
}

test "luce.lex.escape: an unknown escape is pinned to the backslash" {
    try expectErrorAt("func main():\n    let a = \"\\q\"\n", "luce.lex.escape", 2, 14);
}

test "luce.lex.character: '!' alone is rejected in favor of 'not'" {
    try expectError("func main():\n    let a = 1\n    if not a == 1:\n        return\n", "luce.sema.type");
    try expectError("func main():\n    let a = 3 ! 4\n", "luce.lex.character");
}

test "luce.lex.character: an unexpected symbol is rejected" {
    try expectError("func main():\n    let a = 1 $ 2\n", "luce.lex.character");
}

test "luce.lex.character: a stray control byte is pinned" {
    try expectErrorAt("func main():\n    let a = 1\x00\n", "luce.lex.character", 2, 14);
}

// ---------------------------------------------------------------------------
// Parser — more paths
// ---------------------------------------------------------------------------

test "luce.parse.top: a bare expression at file scope is rejected" {
    try expectError("1 + 1\n", "luce.parse.top");
}

test "luce.parse.top: a top-level var is rejected with guidance" {
    try expectErrorAt("var counter = 0\n", "luce.parse.top", 1, 1);
}

test "luce.parse.expected: a function needs a name" {
    try expectError("func ():\n    return\n", "luce.parse.expected");
}

test "luce.parse.expected: a struct field needs a type after its colon" {
    try expectError("struct P:\n    x:\n\nfunc main():\n    return\n", "luce.parse.expected");
}

test "luce.parse.type: array shape wildcards must come last" {
    try expectError(
        "func f(a: Array(Int, _, Int)):\n    return\n\nfunc main():\n    return\n",
        "luce.parse.type",
    );
}

test "luce.parse.assign: cannot assign to a literal" {
    try expectError("func main():\n    1 = 2\n", "luce.parse.assign");
}

test "luce.parse.assign: assignment reaches only one field deep" {
    try expectError("func main():\n    a.b.c = 1\n", "luce.parse.assign");
}

test "luce.parse.new: new builds only the four heap types" {
    try expectError("func main():\n    let a = new Point()\n", "luce.parse.new");
}

// ---------------------------------------------------------------------------
// Names, declarations, reserved words — more paths
// ---------------------------------------------------------------------------

test "luce.sema.name: input is not a name in a script" {
    try expectError("func main():\n    let a = input\n", "luce.sema.name");
}

test "luce.sema.name: give needs a name that exists" {
    try expectError("func main():\n    let a = give ghost\n", "luce.sema.name");
}

test "luce.sema.duplicate: a struct cannot be declared twice" {
    try expectError(
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
    try expectError(
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
    try expectError(
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
    try expectError("func print():\n    return\n\nfunc main():\n    return\n", "luce.sema.reserved");
}

test "luce.sema.reserved: a struct cannot take a type keyword's name" {
    try expectError("struct Int:\n    x: Int\n\nfunc main():\n    return\n", "luce.sema.reserved");
}

// ---------------------------------------------------------------------------
// luce.sema.type — the biggest fan-out, distinct paths
// ---------------------------------------------------------------------------

test "luce.sema.type: a wrong argument type is rejected" {
    try expectError(
        \\func f(a: Int):
        \\    return
        \\
        \\func main():
        \\    f("x")
        \\
    , "luce.sema.type");
}

test "luce.sema.type: a returned value must match the declared return type" {
    try expectError(
        \\func f() -> Int:
        \\    return "x"
        \\
        \\func main():
        \\    let y = f()
        \\
    , "luce.sema.type");
}

test "luce.sema.type: a list literal is homogeneous" {
    try expectError("func main():\n    let xs = [1, \"x\"]\n", "luce.sema.type");
}

test "luce.sema.type: a struct field takes its declared type" {
    try expectError(
        \\struct P:
        \\    x: Int
        \\
        \\func main():
        \\    let p = P(x = "s")
        \\
    , "luce.sema.type");
}

test "luce.sema.type: not needs a Bool" {
    try expectError("func main():\n    let a = not 1\n", "luce.sema.type");
}

test "luce.sema.type: negation needs a number" {
    try expectError("func main():\n    let a = -\"x\"\n", "luce.sema.type");
}

test "luce.sema.type: Bool has no ordering" {
    try expectError("func main():\n    let a = true < false\n", "luce.sema.type");
}

test "luce.sema.type: and needs Bool operands" {
    try expectError("func main():\n    let a = 1 and 2\n", "luce.sema.type");
}

test "luce.sema.type: String has no arithmetic operator" {
    try expectError("func main():\n    let a = \"x\" - \"y\"\n", "luce.sema.type");
}

test "luce.sema.type: range bounds must be Int" {
    try expectError("func main():\n    for i in range(1.0, 2.0):\n        return\n", "luce.sema.type");
}

test "luce.sema.type: an output port takes its declared type" {
    try expectEvalError(
        \\func evaluate(input: Input, output: Output):
        \\    output.x = 1
        \\
    , "luce.sema.type");
}

// ---------------------------------------------------------------------------
// luce.sema.convert
// ---------------------------------------------------------------------------

test "luce.sema.convert: a conversion takes exactly one argument" {
    try expectError("func main():\n    let a = Int(1, 2)\n", "luce.sema.convert");
}

// ---------------------------------------------------------------------------
// luce.sema.field
// ---------------------------------------------------------------------------

test "luce.sema.field: a non-struct value has no fields" {
    try expectError("func main():\n    let a = 1\n    let b = a.x\n", "luce.sema.field");
}

test "luce.sema.field: assigning through a non-struct is rejected" {
    try expectError("func main():\n    var a = 1\n    a.x = 2\n", "luce.sema.field");
}

// ---------------------------------------------------------------------------
// luce.sema.call — distinct paths
// ---------------------------------------------------------------------------

test "luce.sema.call: the entry function cannot be called" {
    try expectError("func main():\n    main()\n", "luce.sema.call");
}

test "luce.sema.call: function arguments are positional, not named" {
    try expectError(
        \\func f(a: Int):
        \\    return
        \\
        \\func main():
        \\    f(a = 1)
        \\
    , "luce.sema.call");
}

test "luce.sema.call: a None function's result is not a value" {
    try expectError(
        \\func f():
        \\    return
        \\
        \\func main():
        \\    let x = f()
        \\
    , "luce.sema.call");
}

test "luce.sema.call: a builtin checks its arity" {
    try expectError("func main():\n    let a = len(1, 2)\n", "luce.sema.call");
}

test "luce.sema.call: a builtin's arguments are positional" {
    try expectError("func main():\n    let a = len(x = 1)\n", "luce.sema.call");
}

// ---------------------------------------------------------------------------
// luce.sema.method — distinct paths
// ---------------------------------------------------------------------------

test "luce.sema.method: an unknown method on a List is rejected" {
    try expectError("func main():\n    var xs = [1]\n    xs.frobnicate()\n", "luce.sema.method");
}

test "luce.sema.method: a method checks its arity" {
    try expectError("func main():\n    var xs = [1]\n    xs.append(1, 2)\n", "luce.sema.method");
}

test "luce.sema.method: method arguments are positional" {
    try expectError("func main():\n    var xs = [1]\n    xs.append(v = 1)\n", "luce.sema.method");
}

test "luce.sema.method: no method takes more than two arguments" {
    try expectError("func main():\n    var xs = [1]\n    xs.append(1, 2, 3)\n", "luce.sema.method");
}

test "luce.sema.method: String has no such method" {
    try expectError("func main():\n    let s = \"x\"\n    let n = s.frobnicate()\n", "luce.sema.method");
}

test "luce.sema.method: Map has no such method" {
    try expectError(
        \\func main():
        \\    var m = new Map(String, Int)
        \\    m.frobnicate()
        \\
    , "luce.sema.method");
}

// ---------------------------------------------------------------------------
// luce.sema.index — distinct paths
// ---------------------------------------------------------------------------

test "luce.sema.index: a String is sliced, not indexed" {
    try expectError("func main():\n    let s = \"abc\"\n    let c = s[0]\n", "luce.sema.index");
}

test "luce.sema.index: a List indexes with an Int, not a Bool" {
    try expectError("func main():\n    var xs = [1]\n    let a = xs[true]\n", "luce.sema.index");
}

test "luce.sema.index: an Array wants one index per dimension" {
    try expectError(
        \\func main():
        \\    var grid = new Array(Int, 2, 2)
        \\    let a = grid[0]
        \\
    , "luce.sema.index");
}

test "luce.sema.index: a Map cannot be sliced" {
    try expectError(
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
    try expectError(
        \\struct P:
        \\    x: Int
        \\
        \\func main():
        \\    let p = P(x = 1, z = 2)
        \\
    , "luce.sema.construct");
}

test "luce.sema.construct: a field cannot be given twice" {
    try expectError(
        \\struct P:
        \\    x: Int
        \\
        \\func main():
        \\    let p = P(x = 1, x = 2)
        \\
    , "luce.sema.construct");
}

test "luce.sema.construct: fields are named, not positional" {
    try expectError(
        \\struct P:
        \\    x: Int
        \\
        \\func main():
        \\    let p = P(1)
        \\
    , "luce.sema.construct");
}

test "luce.sema.construct: a function-namespace struct has no value fields" {
    try expectError(
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
    try expectError("func main():\n    var a = new Array(Int, 1, 2, 3, 4, 5)\n", "luce.sema.new");
}

test "luce.sema.new: array dimensions are Int" {
    try expectError("func main():\n    var a = new Array(Int, true)\n", "luce.sema.new");
}

// ---------------------------------------------------------------------------
// luce.sema.loop — distinct paths
// ---------------------------------------------------------------------------

test "luce.sema.loop: continue needs a loop" {
    try expectError("func main():\n    continue\n", "luce.sema.loop");
}

test "luce.sema.loop: a non-iterable cannot drive for-each" {
    try expectError("func main():\n    for x in 5:\n        return\n", "luce.sema.loop");
}

// ---------------------------------------------------------------------------
// luce.sema.return — distinct paths
// ---------------------------------------------------------------------------

test "luce.sema.return: a typed function must return a value" {
    try expectError(
        \\func f() -> Int:
        \\    return
        \\
        \\func main():
        \\    let y = f()
        \\
    , "luce.sema.return");
}

test "luce.sema.return: a None function returns no value" {
    try expectError(
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
    try expectError(
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
    try expectError(
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
    try expectError("let bad = ghost\n\nfunc main():\n    return\n", "luce.sema.const");
}

test "luce.sema.const: a constant cannot depend on itself" {
    try expectError("let bad = bad\n\nfunc main():\n    return\n", "luce.sema.const");
}

test "luce.sema.const: a list literal is an object, not a constant" {
    try expectError("let bad = [1, 2]\n\nfunc main():\n    return\n", "luce.sema.const");
}

// ---------------------------------------------------------------------------
// luce.sema.literal — expression-position literal overflow
// ---------------------------------------------------------------------------

test "luce.sema.literal: an over-large integer literal is rejected" {
    try expectError("func main():\n    let a = 99999999999999999999\n", "luce.sema.literal");
}

// ---------------------------------------------------------------------------
// luce.sema.host — each gated builtin
// ---------------------------------------------------------------------------

test "luce.sema.host: file_read is gated" {
    try expectError("func main():\n    let a = file_read(\"x\")\n", "luce.sema.host");
}

test "luce.sema.host: key_read is gated" {
    try expectError("func main():\n    let a = key_read()\n", "luce.sema.host");
}

test "luce.sema.host: term_write is gated" {
    try expectError("func main():\n    term_write(\"x\")\n", "luce.sema.host");
}

// ---------------------------------------------------------------------------
// luce.sema.fabric — fabric intents off in v2
// ---------------------------------------------------------------------------

test "luce.sema.fabric: fabric builtins are gated off in v2" {
    try expectError("func main():\n    let a = create_texel(1)\n", "luce.sema.fabric");
}

// ---------------------------------------------------------------------------
// luce.sema.import — referencing an unimported module
// ---------------------------------------------------------------------------

test "luce.sema.import: an unknown module in a type is rejected" {
    try expectError(
        "func f(a: geo.Point):\n    return\n\nfunc main():\n    return\n",
        "luce.sema.import",
    );
}

// NOTE: the namespace-in-a-call form of luce.sema.import
// ("unknown namespace geo; import geo to use it") fires only when the head
// names a module that is *loaded elsewhere in the program but not imported
// here* (analyzer.zig methodNamespace).  A bare geo.dist(1) with no such
// module resolves to luce.sema.name instead, so this path needs a
// multi-module project and is not reachable through the single-file
// harness.  The type-resolution form above covers the luce.sema.import code.

// ---------------------------------------------------------------------------
// luce.import.missing — an import with no loader cannot resolve
// ---------------------------------------------------------------------------

test "luce.import.missing: a nonexistent module cannot be loaded" {
    try expectError("import ghost\n\nfunc main():\n    return\n", "luce.import.missing");
}

// ---------------------------------------------------------------------------
// Evaluator-mode ports: luce.sema.port / input / output
// ---------------------------------------------------------------------------

test "luce.sema.port: an unknown output port is rejected" {
    try expectEvalError(
        \\func evaluate(input: Input, output: Output):
        \\    output.ghost = 1.0
        \\
    , "luce.sema.port");
}

test "luce.sema.port: an unknown input port is rejected" {
    try expectEvalError(
        \\func evaluate(input: Input, output: Output):
        \\    let a = input.ghost
        \\
    , "luce.sema.port");
}

test "luce.sema.input: input ports are read-only" {
    try expectEvalError(
        \\func evaluate(input: Input, output: Output):
        \\    input.x = 1.0
        \\
    , "luce.sema.input");
}

test "luce.sema.output: output ports are write-only" {
    try expectEvalError(
        \\func evaluate(input: Input, output: Output):
        \\    let a = output.x
        \\
    , "luce.sema.output");
}
