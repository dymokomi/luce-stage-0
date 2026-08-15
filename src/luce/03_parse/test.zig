//! Parser tests.
//!
//! Three things get proved here, in order: that the grammar accepts
//! exactly what docs/LANGUAGE.md describes and builds the right tree
//! for it; that a broken file yields one useful diagnostic per
//! mistake, at the offending token, instead of a cascade; and that
//! hostile input reports rather than crashing, hanging, or flooding.

const std = @import("std");
const parser_mod = @import("../03_parse.zig");
const source_mod = @import("../01_source.zig");
const ast = @import("ast.zig");
const grammar = @import("grammar.zig");
const diagnostics_mod = @import("../support/diagnostics.zig");

const testing = std.testing;
const Diagnostics = diagnostics_mod.Diagnostics;

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    diagnostics: Diagnostics,
    program: ast.Program,
    source: []const u8,

    fn deinit(self: *Parsed) void {
        self.diagnostics.deinit();
        self.arena.deinit();
    }
};

fn parseText(text: []const u8) !Parsed {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();
    var diagnostics = Diagnostics.init(testing.allocator);
    errdefer diagnostics.deinit();
    const program = try parser_mod.parse(arena.allocator(), testing.allocator, text, &diagnostics);
    return .{ .arena = arena, .diagnostics = diagnostics, .program = program, .source = text };
}

fn dump(parsed: *const Parsed) void {
    for (0..parsed.diagnostics.count()) |index| {
        const item = parsed.diagnostics.at(index).?;
        const at = source_mod.place(parsed.source, item.span.start);
        std.debug.print("  {d}:{d}: {s} [{s}]\n", .{ at.line, at.column, item.message, item.code });
    }
}

/// Parse `text` and require it to be accepted without complaint.
fn expectClean(text: []const u8) !Parsed {
    var parsed = try parseText(text);
    errdefer parsed.deinit();
    if (parsed.diagnostics.count() != 0) {
        std.debug.print("expected a clean parse of:\n{s}got:\n", .{text});
        dump(&parsed);
        return error.TestUnexpectedResult;
    }
    return parsed;
}

const Wanted = struct {
    code: []const u8,
    line: usize,
    column: usize,
    /// A fragment the message must contain — the wording that makes
    /// the diagnostic actionable, not the whole sentence.
    contains: []const u8 = "",
};

/// Parse `text` and require exactly `wanted`, in order: the count is
/// part of the assertion, because "one mistake, one diagnostic" is
/// the property most of these tests exist to hold.
fn expectDiagnostics(text: []const u8, wanted: []const Wanted) !void {
    var parsed = try parseText(text);
    defer parsed.deinit();
    errdefer {
        std.debug.print("for:\n{s}got:\n", .{text});
        dump(&parsed);
    }
    try testing.expectEqual(wanted.len, parsed.diagnostics.count());
    for (wanted, 0..) |want, index| {
        const item = parsed.diagnostics.at(index).?;
        try testing.expectEqualStrings(want.code, item.code);
        const at = source_mod.place(text, item.span.start);
        try testing.expectEqual(want.line, at.line);
        try testing.expectEqual(want.column, at.column);
        if (want.contains.len != 0) {
            if (std.mem.indexOf(u8, item.message, want.contains) == null) {
                std.debug.print("message '{s}' lacks '{s}'\n", .{ item.message, want.contains });
                return error.TestUnexpectedResult;
            }
        }
    }
}

/// A source built by repeating `unit` `count` times between `head` and
/// `tail` — the shape every pathological-input test needs.
fn repeated(head: []const u8, unit: []const u8, count: usize, tail: []const u8) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, head);
    for (0..count) |_| try text.appendSlice(testing.allocator, unit);
    try text.appendSlice(testing.allocator, tail);
    return text.toOwnedSlice(testing.allocator);
}

fn hasCode(parsed: *const Parsed, code: []const u8) bool {
    for (0..parsed.diagnostics.count()) |index| {
        if (std.mem.eql(u8, parsed.diagnostics.at(index).?.code, code)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Declarations
// ---------------------------------------------------------------------------

test "the plan's scale example parses" {
    var parsed = try expectClean(
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
        \\    var scaled = Point(x = 0.0, y = 0.0)
        \\    let factor = 3.0
        \\    scaled.x = scale_point(scaled, factor).x
        \\
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.program.structs.len);
    try testing.expectEqual(@as(usize, 2), parsed.program.functions.len);
    try testing.expectEqualStrings("Point", parsed.program.structs[0].name);
    try testing.expectEqual(@as(usize, 2), parsed.program.structs[0].fields.len);
    try testing.expectEqualStrings("scale_point", parsed.program.functions[0].name);
    try testing.expectEqual(@as(usize, 2), parsed.program.functions[0].parameters.len);
    try testing.expectEqual(@as(usize, 1), parsed.program.functions[0].returns.len);

    // main's third statement is a field assignment.
    const entry = parsed.program.functions[1];
    try testing.expectEqual(@as(usize, 3), entry.body.statements.len);
    const assign = entry.body.statements[2].assign;
    try testing.expectEqualStrings("scaled", assign.target.field.base);
    try testing.expectEqualStrings("x", assign.target.field.field);
}

test "every declaration form at file scope parses into its own list" {
    var parsed = try expectClean(
        \\import std.math
        \\import geo
        \\
        \\const width = 80
        \\const banner: string = "loom"
        \\
        \\struct Theme:
        \\    keyword: long
        \\    comment: long
        \\
        \\    static func default() -> long:
        \\        return 176
        \\
        \\func main():
        \\    return
        \\
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.program.imports.len);
    // Both spellings bind the bare name; only the origin differs.
    try testing.expectEqualStrings("math", parsed.program.imports[0].name);
    try testing.expectEqualStrings("math", parsed.program.imports[0].binding);
    try testing.expectEqual(source_mod.Origin.standard, parsed.program.imports[0].origin);
    try testing.expectEqualStrings("geo", parsed.program.imports[1].name);
    try testing.expectEqualStrings("geo", parsed.program.imports[1].binding);
    try testing.expectEqual(source_mod.Origin.sibling, parsed.program.imports[1].origin);
    try testing.expectEqual(@as(usize, 2), parsed.program.constants.len);
    try testing.expect(parsed.program.constants[0].annotation == null);
    try testing.expectEqualStrings("string", parsed.program.constants[1].annotation.?.name);
    try testing.expectEqual(@as(usize, 2), parsed.program.structs[0].fields.len);
    try testing.expectEqual(@as(usize, 1), parsed.program.structs[0].functions.len);
    try testing.expectEqual(@as(usize, 1), parsed.program.functions.len);
}

test "dotted imports and the as alias parse: the binding is the last segment or the alias" {
    var parsed = try expectClean(
        \\import geo.shapes
        \\import geo.solids as gs
        \\import tools.text.wrap
        \\import util as helpers
        \\
        \\func main():
        \\    return
        \\
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 4), parsed.program.imports.len);
    // Dots map to folders; the module keeps its full name and binds
    // its last segment (docs/PACKAGES.md D2).
    try testing.expectEqualStrings("geo.shapes", parsed.program.imports[0].name);
    try testing.expectEqualStrings("shapes", parsed.program.imports[0].binding);
    try testing.expectEqual(source_mod.Origin.sibling, parsed.program.imports[0].origin);
    // `as` moves only the binding, never the name.
    try testing.expectEqualStrings("geo.solids", parsed.program.imports[1].name);
    try testing.expectEqualStrings("gs", parsed.program.imports[1].binding);
    // Depth is the filesystem's business, not the grammar's.
    try testing.expectEqualStrings("tools.text.wrap", parsed.program.imports[2].name);
    try testing.expectEqualStrings("wrap", parsed.program.imports[2].binding);
    // A single segment takes an alias the same way.
    try testing.expectEqualStrings("util", parsed.program.imports[3].name);
    try testing.expectEqualStrings("helpers", parsed.program.imports[3].binding);
}

test "as is a word, not a keyword: a binding named as still parses" {
    // The alias marker is read contextually, after the module path
    // only — so nothing is taken from programs, and a variable called
    // `as` keeps working.
    var parsed = try expectClean(
        \\func main():
        \\    let as = 2
        \\    print(string(as))
        \\
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.program.functions.len);
}

test "return types and dotted type names parse" {
    var parsed = try expectClean(
        \\func stash(index: map(string, list(long)), hits: list(long), origin: shapes.Point) -> list(long):
        \\    return hits
        \\
        \\func main():
        \\    return
        \\
    );
    defer parsed.deinit();
    const stash = parsed.program.functions[0];
    try testing.expectEqualStrings("shapes.Point", stash.parameters[2].type_name.name);
    try testing.expectEqualStrings("list", stash.returns[0].name);
    try testing.expectEqualStrings("long", stash.returns[0].arguments[0].name);
}

test "struct bodies parse fields and static namespace functions" {
    var parsed = try expectClean(
        \\struct Helpers:
        \\    value: long
        \\    static func double(value: long) -> long:
        \\        return value * 2
        \\
        \\func main():
        \\    let value = Helpers.double(21)
        \\
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.program.structs[0].fields.len);
    try testing.expectEqual(@as(usize, 1), parsed.program.structs[0].functions.len);
    try testing.expect(parsed.program.structs[0].functions[0].is_static);
    // Dotted calls parse as method nodes; the analyzer decides whether
    // the chain names a namespace or a value.
    const dotted = parsed.program.functions[0].body.statements[0].let.value.method;
    try testing.expectEqualStrings("double", dotted.name);
    try testing.expectEqualStrings("Helpers", dotted.target.name.text);
}

test "const is file-scope, while let and var are function-scope" {
    var parsed = try expectClean(
        \\const width = 80
        \\const banner: string = "loom " + version
        \\const version = "2.0"
        \\
        \\func main():
        \\    let unused = width
        \\
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 3), parsed.program.constants.len);
    try testing.expectEqualStrings("width", parsed.program.constants[0].name);
    try testing.expect(parsed.program.constants[0].annotation == null);
    try testing.expectEqualStrings("string", parsed.program.constants[1].annotation.?.name);
    try testing.expect(parsed.program.constants[1].value.* == .binary);

    try expectDiagnostics("let width = 80\n", &.{
        .{ .code = "luce.parse.top", .line = 1, .column = 1, .contains = "file scope declares with const" },
    });
    try expectDiagnostics("var counter = 0\n", &.{
        .{ .code = "luce.parse.top", .line = 1, .column = 1, .contains = "file scope declares with const" },
    });
    try expectDiagnostics("private let width = 80\n", &.{
        .{ .code = "luce.parse.top", .line = 1, .column = 9, .contains = "file scope declares with const" },
    });
    try expectDiagnostics("func main():\n    const width = 80\n    let okay = 1\n", &.{
        .{ .code = "luce.parse.expected", .line = 2, .column = 5, .contains = "use let or var inside a function" },
    });
}

test "visibility markers parse onto every declaration form, and unmarked stays none" {
    var parsed = try expectClean(
        \\private const seed = 41
        \\public const answer = seed + 1
        \\const quiet = 0
        \\
        \\private struct Inner:
        \\    n: long
        \\
        \\struct Session:
        \\    name: string
        \\    private token: long = 0
        \\    public func label() -> string:
        \\        return self.name
        \\    private func stamp() -> long:
        \\        return self.token
        \\
        \\private func helper() -> long:
        \\    return 1
        \\
        \\func main():
        \\    print(string(helper()))
        \\
    );
    defer parsed.deinit();
    const program = parsed.program;
    try testing.expectEqual(ast.Visibility.private, program.constants[0].visibility);
    try testing.expectEqual(ast.Visibility.public, program.constants[1].visibility);
    try testing.expectEqual(ast.Visibility.none, program.constants[2].visibility);
    try testing.expectEqual(ast.Visibility.private, program.structs[0].visibility);
    try testing.expectEqual(ast.Visibility.none, program.structs[1].visibility);
    const session = program.structs[1];
    try testing.expectEqual(ast.Visibility.none, session.fields[0].visibility);
    try testing.expectEqual(ast.Visibility.private, session.fields[1].visibility);
    try testing.expectEqual(ast.Visibility.public, session.functions[0].visibility);
    try testing.expectEqual(ast.Visibility.private, session.functions[1].visibility);
    try testing.expectEqual(ast.Visibility.private, program.functions[0].visibility);
    try testing.expectEqual(ast.Visibility.none, program.functions[1].visibility);
}

test "a region dissolves onto its members, and equals the per-declaration marker" {
    // The memo's own Rng shape: one private region over the field,
    // members after the region back at the default (VISIBILITY.md §5).
    var parsed = try expectClean(
        \\struct Rng:
        \\    private:
        \\        state: long
        \\
        \\    func next() -> long:
        \\        return self.state
        \\
        \\func main():
        \\    return
        \\
    );
    defer parsed.deinit();
    const rng = parsed.program.structs[0];
    try testing.expectEqual(ast.Visibility.private, rng.fields[0].visibility);
    try testing.expectEqual(ast.Visibility.none, rng.functions[0].visibility);

    // Labels repeat and appear in any order; funcs sit in regions too.
    var mixed = try expectClean(
        \\struct Handle:
        \\    private:
        \\        slot: long
        \\    public:
        \\        label: string
        \\    private:
        \\        generation: long
        \\        func raw() -> long:
        \\            return self.slot
        \\
        \\func main():
        \\    return
        \\
    );
    defer mixed.deinit();
    const handle = mixed.program.structs[0];
    try testing.expectEqual(ast.Visibility.private, handle.fields[0].visibility);
    try testing.expectEqual(ast.Visibility.public, handle.fields[1].visibility);
    try testing.expectEqual(ast.Visibility.private, handle.fields[2].visibility);
    try testing.expectEqual(ast.Visibility.private, handle.functions[0].visibility);
}

test "the visibility refusals land where the memo puts them" {
    // A marker on a local, a parameter, or any statement (§5).
    const rule = "visibility applies to file-scope declarations and struct members";
    try expectDiagnostics("func main():\n    public let x = 1\n", &.{
        .{ .code = "luce.parse.expected", .line = 2, .column = 5, .contains = rule },
    });
    try expectDiagnostics("func f(private x: long):\n    return\n\nfunc main():\n    return\n", &.{
        .{ .code = "luce.parse.expected", .line = 1, .column = 8, .contains = rule },
    });
    // One visibility word per declaration — file scope and struct alike.
    try expectDiagnostics("public private func f():\n    return\n", &.{
        .{ .code = "luce.parse.expected", .line = 1, .column = 8, .contains = "one visibility word" },
    });
    try expectDiagnostics("struct P:\n    public public n: long\n\nfunc main():\n    return\n", &.{
        .{ .code = "luce.parse.expected", .line = 2, .column = 12, .contains = "one visibility word" },
    });
    // A region label at module level points at per-declaration markers.
    try expectDiagnostics("private:\n    func f():\n        return\n", &.{
        .{ .code = "luce.parse.top", .line = 1, .column = 1, .contains = "a visibility region belongs inside a struct" },
    });
    // A marker inside a region: the block already said it.
    try expectDiagnostics(
        "struct Rng:\n    private:\n        private state: long\n\nfunc main():\n    return\n",
        &.{.{
            .code = "luce.parse.expected",
            .line = 3,
            .column = 9,
            .contains = "state is inside a private region, which already says it",
        }},
    );
    try expectDiagnostics(
        "struct Rng:\n    private:\n        public func raw() -> long:\n            return 1\n\nfunc main():\n    return\n",
        &.{.{
            .code = "luce.parse.expected",
            .line = 3,
            .column = 9,
            .contains = "raw is inside a private region, which already says it",
        }},
    );
    // An empty region is refused the way every empty block is; a
    // region whose "members" sit at region level gets the block shape
    // sentence every unindented block gets.
    try expectDiagnostics(
        "struct Rng:\n    private:\n\nfunc main():\n    return\n",
        &.{.{
            .code = "luce.parse.expected",
            .line = 4,
            .column = 1,
            .contains = "this 'private:' block is empty",
        }},
    );
    try expectDiagnostics(
        "struct Rng:\n    private:\n    n: long\n\nfunc main():\n    return\n",
        &.{.{
            .code = "luce.parse.expected",
            .line = 3,
            .column = 5,
            .contains = "expected an indented block under 'private:'",
        }},
    );
    // A marker fronting something unmarkable names what it expected.
    try expectDiagnostics("private import math\n\nfunc main():\n    return\n", &.{
        .{ .code = "luce.parse.top", .line = 1, .column = 1, .contains = "expected func, const, struct, interface, enum, or union" },
    });
}

test "a marked member inside a region still parses, carrying the region's word" {
    // One mistake, one message — and the member is not lost: it lands
    // with the region's visibility, so recovery reads the struct the
    // author meant.
    var parsed = try parseText(
        "struct Rng:\n    private:\n        private state: long\n\nfunc main():\n    return\n",
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.diagnostics.count());
    const rng = parsed.program.structs[0];
    try testing.expectEqual(@as(usize, 1), rng.fields.len);
    try testing.expectEqual(ast.Visibility.private, rng.fields[0].visibility);
}

test "array shape wildcards parse in annotations" {
    var parsed = try expectClean(
        \\func total(grid: array(long, _, _)) -> long:
        \\    return dim(grid, 0)
        \\
        \\func main():
        \\    return
        \\
    );
    defer parsed.deinit();
    const parameter = parsed.program.functions[0].parameters[0];
    try testing.expectEqualStrings("array", parameter.type_name.name);
    try testing.expectEqual(@as(u8, 2), parameter.type_name.wildcards);
}

test "the bare underscore is refused as a declared name, everywhere one declares" {
    // The wildcard keeps its one home — type-argument position, the
    // test above — and every declaring production answers with the
    // same sentence.  The declaration still parses,
    // so each program yields exactly the one diagnostic.
    const wildcard = "_ is the array-shape wildcard";
    try expectDiagnostics("const _ = 1\n\nfunc main():\n    return\n", &.{
        .{ .code = "luce.parse.expected", .line = 1, .column = 7, .contains = wildcard },
    });
    try expectDiagnostics("func _():\n    return\n\nfunc main():\n    return\n", &.{
        .{ .code = "luce.parse.expected", .line = 1, .column = 6, .contains = wildcard },
    });
    try expectDiagnostics("struct _:\n    x: long\n\nfunc main():\n    return\n", &.{
        .{ .code = "luce.parse.expected", .line = 1, .column = 8, .contains = wildcard },
    });
    try expectDiagnostics("struct P:\n    _: long\n\nfunc main():\n    return\n", &.{
        .{ .code = "luce.parse.expected", .line = 2, .column = 5, .contains = wildcard },
    });
    try expectDiagnostics("func f(_: long):\n    return\n\nfunc main():\n    return\n", &.{
        .{ .code = "luce.parse.expected", .line = 1, .column = 8, .contains = wildcard },
    });
    try expectDiagnostics("func main():\n    let _ = 1\n", &.{
        .{ .code = "luce.parse.expected", .line = 2, .column = 9, .contains = "a binding needs a name" },
    });
    try expectDiagnostics("func main():\n    let a, _ = f()\n", &.{
        .{ .code = "luce.parse.expected", .line = 2, .column = 12, .contains = wildcard },
    });
    try expectDiagnostics("func main():\n    for _ in [1]:\n        print(1)\n", &.{
        .{ .code = "luce.parse.expected", .line = 2, .column = 9, .contains = wildcard },
    });
    try expectDiagnostics("func main():\n    print(1) catch _:\n        return\n", &.{
        .{ .code = "luce.parse.expected", .line = 2, .column = 20, .contains = wildcard },
    });
}

// ---------------------------------------------------------------------------
// Statements
// ---------------------------------------------------------------------------

test "late declarations parse: var with annotation only" {
    var parsed = try expectClean(
        \\func main():
        \\    var report: builder
        \\    var grid: array(long, _, _)
        \\    var count: long
        \\    report = new builder()
        \\
    );
    defer parsed.deinit();
    const body = parsed.program.functions[0].body;
    try testing.expect(body.statements[0].variable.value == null);
    try testing.expectEqualStrings("builder", body.statements[0].variable.annotation.?.name);
    try testing.expect(body.statements[1].variable.value == null);
    try testing.expect(body.statements[2].variable.value == null);

    // let never late-declares, and var needs a type or a value.
    try expectDiagnostics("func main():\n    let frozen: long\n", &.{
        .{ .code = "luce.parse.expected", .line = 2, .column = 21, .contains = "let always initializes" },
    });
    try expectDiagnostics("func main():\n    var untyped\n", &.{
        .{ .code = "luce.parse.expected", .line = 2, .column = 16, .contains = "'=' with an initial value" },
    });
}

test "every assignment place parses, nested and compound" {
    var parsed = try expectClean(
        \\func main():
        \\    var n = 0
        \\    var p = Point(x = 1)
        \\    var grid = new array(long, 2, 2)
        \\    var cells = [Point(x = 1)]
        \\    n = 1
        \\    p.x = 2
        \\    grid[0, 1] = 3
        \\    p.inner.n = 4
        \\    cells[0].value = 5
        \\    grid[0, 1] += 1
        \\    n -= 1
        \\    n *= 2
        \\    n /= 2
        \\    n %= 3
        \\
    );
    defer parsed.deinit();
    const body = parsed.program.functions[0].body;
    try testing.expect(body.statements[4].assign.target == .name);
    try testing.expect(body.statements[5].assign.target == .field);
    try testing.expectEqual(@as(usize, 2), body.statements[6].assign.target.index.indices.len);
    // p.inner.n and cells[0].value are nested places: a chain the
    // analyzer reads once and rebuilds.
    try testing.expect(body.statements[7].assign.target == .chain);
    try testing.expect(body.statements[8].assign.target == .chain);
    try testing.expectEqual(ast.BinaryOp.add, body.statements[9].assign.compound.?);
    try testing.expectEqual(ast.BinaryOp.subtract, body.statements[10].assign.compound.?);
    try testing.expectEqual(ast.BinaryOp.multiply, body.statements[11].assign.compound.?);
    try testing.expectEqual(ast.BinaryOp.divide, body.statements[12].assign.compound.?);
    try testing.expectEqual(ast.BinaryOp.modulo, body.statements[13].assign.compound.?);
    // The compound form is still one assignment, never a read plus a
    // write in the tree.
    try testing.expect(body.statements[9].assign.value.* == .int_literal);
}

test "multi-return assignment has its own node, guarded or plain" {
    var parsed = try expectClean(
        \\func main():
        \\    var low = 0
        \\    var high = 0
        \\    low, high = minmax()
        \\    low, high = risky() catch reason:
        \\        print(reason)
        \\
    );
    defer parsed.deinit();
    const body = parsed.program.functions[0].body;
    const plain = body.statements[2].assign_many;
    try testing.expectEqual(@as(usize, 2), plain.names.len);
    try testing.expectEqualStrings("low", plain.names[0].text);
    try testing.expectEqualStrings("high", plain.names[1].text);
    try testing.expect(plain.value.* == .call);

    const guarded = body.statements[3].guarded;
    try testing.expectEqualStrings("reason", guarded.binding.?.text);
    try testing.expect(guarded.attempt.* == .assign_many);
    try testing.expectEqual(@as(usize, 2), guarded.attempt.assign_many.names.len);
}

test "every for form parses into the node its lowering needs" {
    var parsed = try expectClean(
        \\func main():
        \\    var xs = [1]
        \\    var m = new map(string, long)
        \\    for i in range(0, 10):
        \\        print(i)
        \\    for x in xs:
        \\        print(x)
        \\    for key in m:
        \\        print(key)
        \\    for i, x in xs:
        \\        print(x)
        \\    for key, value in m:
        \\        print(value)
        \\    for i in range(0, 10,):
        \\        print(i)
        \\
    );
    defer parsed.deinit();
    const body = parsed.program.functions[0].body;
    try testing.expect(body.statements[2] == .for_range);
    try testing.expectEqualStrings("i", body.statements[2].for_range.name);
    try testing.expect(body.statements[3] == .for_each);
    try testing.expect(body.statements[3].for_each.value_name == null);
    try testing.expect(body.statements[4] == .for_each);
    try testing.expectEqualStrings("i", body.statements[5].for_each.name);
    try testing.expectEqualStrings("x", body.statements[5].for_each.value_name.?);
    try testing.expectEqualStrings("value", body.statements[6].for_each.value_name.?);
    // A trailing comma inside range() is still a range loop.
    try testing.expect(body.statements[7] == .for_range);

    // `range` only means the loop form in a for header with one name.
    var general = try expectClean(
        \\func main():
        \\    for i, x in range(0, 3):
        \\        print(x)
        \\
    );
    defer general.deinit();
    try testing.expect(general.program.functions[0].body.statements[0] == .for_each);
}

test "control flow, precedence, and elif chains parse" {
    var parsed = try expectClean(
        \\func main():
        \\    var total = 0
        \\    for index in range(0, 10):
        \\        if index % 2 == 0 and index != 4:
        \\            total = total + index * 2
        \\        elif index == 5:
        \\            continue
        \\        else:
        \\            break
        \\    while total > 100:
        \\        total = total - 1
        \\    output.total = total
        \\
    );
    defer parsed.deinit();
    const body = parsed.program.functions[0].body;
    try testing.expectEqual(@as(usize, 4), body.statements.len);

    // Precedence: total + index * 2 parses as total + (index * 2).
    const loop = body.statements[1].for_range;
    const conditional = loop.body.statements[0].conditional;
    const sum = conditional.then_block.statements[0].assign.value.binary;
    try testing.expectEqual(ast.BinaryOp.add, sum.op);
    try testing.expectEqual(ast.BinaryOp.multiply, sum.right.binary.op);
    // The elif chain nests inside the else block.
    try testing.expect(conditional.else_block != null);
    const chained = conditional.else_block.?.statements[0].conditional;
    try testing.expect(chained.else_block != null);
    try testing.expect(chained.else_block.?.statements[0] == .break_statement);
}

test "return, break, and continue parse with and without a value" {
    var parsed = try expectClean(
        \\func main():
        \\    while true:
        \\        if true:
        \\            break
        \\        continue
        \\    return
        \\
        \\func value() -> long:
        \\    return 1 + 2
        \\
    );
    defer parsed.deinit();
    const loop = parsed.program.functions[0].body.statements[0].while_loop;
    try testing.expect(loop.body.statements[0].conditional.then_block.statements[0] == .break_statement);
    try testing.expect(loop.body.statements[1] == .continue_statement);
    try testing.expectEqual(@as(usize, 0), parsed.program.functions[0].body.statements[1].return_statement.values.len);
    try testing.expect(parsed.program.functions[1].body.statements[0].return_statement.values[0].* == .binary);
}

// ---------------------------------------------------------------------------
// Expressions
// ---------------------------------------------------------------------------

test "the precedence table binds exactly as docs/LANGUAGE.md states" {
    var parsed = try expectClean(
        \\func main():
        \\    let a = 1 or 2 and 3
        \\    let b = 1 and 2 == 3
        \\    let c = 1 == 2 + 3
        \\    let d = 1 + 2 * 3
        \\    let e = 1 - 2 - 3
        \\    let f = 2 * 3 % 4
        \\    let g = (1 + 2) * 3
        \\    let h = -x * y
        \\    let i = (not a) == b
        \\    let j = not a
        \\    let k = (a < b) == (c < d)
        \\
    );
    defer parsed.deinit();
    const body = parsed.program.functions[0].body;

    // or is loosest: 1 or (2 and 3)
    const a = body.statements[0].let.value.binary;
    try testing.expectEqual(ast.BinaryOp.logic_or, a.op);
    try testing.expectEqual(ast.BinaryOp.logic_and, a.right.binary.op);
    // and binds looser than comparison: 1 and (2 == 3)
    const b = body.statements[1].let.value.binary;
    try testing.expectEqual(ast.BinaryOp.logic_and, b.op);
    try testing.expectEqual(ast.BinaryOp.equal, b.right.binary.op);
    // comparison binds looser than +: 1 == (2 + 3)
    const c = body.statements[2].let.value.binary;
    try testing.expectEqual(ast.BinaryOp.equal, c.op);
    try testing.expectEqual(ast.BinaryOp.add, c.right.binary.op);
    // + binds looser than *: 1 + (2 * 3)
    const d = body.statements[3].let.value.binary;
    try testing.expectEqual(ast.BinaryOp.add, d.op);
    try testing.expectEqual(ast.BinaryOp.multiply, d.right.binary.op);
    // Same-precedence operators associate left: (1 - 2) - 3
    const e = body.statements[4].let.value.binary;
    try testing.expectEqual(ast.BinaryOp.subtract, e.op);
    try testing.expectEqual(ast.BinaryOp.subtract, e.left.binary.op);
    const f = body.statements[5].let.value.binary;
    try testing.expectEqual(ast.BinaryOp.modulo, f.op);
    try testing.expectEqual(ast.BinaryOp.multiply, f.left.binary.op);
    // Parentheses override: (1 + 2) * 3
    const g = body.statements[6].let.value.binary;
    try testing.expectEqual(ast.BinaryOp.multiply, g.op);
    try testing.expectEqual(ast.BinaryOp.add, g.left.binary.op);
    // Prefix binds tighter than any binary operator: (-x) * y
    const h = body.statements[7].let.value.binary;
    try testing.expectEqual(ast.BinaryOp.multiply, h.op);
    try testing.expectEqual(ast.UnaryOp.negate, h.left.unary.op);
    // Parenthesized, `not` in front of a comparison is legal and
    // means what it says; bare, it is refused — see the two tests
    // below.
    const i = body.statements[8].let.value.binary;
    try testing.expectEqual(ast.BinaryOp.equal, i.op);
    try testing.expectEqual(ast.UnaryOp.logic_not, i.left.unary.op);
    try testing.expectEqual(ast.UnaryOp.logic_not, body.statements[9].let.value.unary.op);
    // Two comparisons compared: legal, because each pair of
    // parentheses starts its own chain.
    const k = body.statements[10].let.value.binary;
    try testing.expectEqual(ast.BinaryOp.equal, k.op);
    try testing.expectEqual(ast.BinaryOp.less, k.left.binary.op);
    try testing.expectEqual(ast.BinaryOp.less, k.right.binary.op);
}

test "every adjacent pair of precedence levels binds the tighter one first" {
    // One expression per *adjacency* in `binaryPrecedence`'s table, so
    // that moving any operator to a neighbouring level fails a test
    // named for the table rather than something downstream that
    // happened to depend on it.  The test above pins most of the
    // ladder; what it does not reach is `coalesce`, the level `else`
    // and `catch` share between comparison and arithmetic, and the
    // modulo operator's place among its neighbours.
    var parsed = try expectClean(
        \\func main():
        \\    let a = p or q and r
        \\    let b = p and q == r
        \\    let c = p == q else r
        \\    let d = p else q + r
        \\    let e = p + q % r
        \\    let f = p % q * r
        \\    let g = p else q else r
        \\    let h = p catch q + r
        \\    let i = p catch q else r
        \\
    );
    defer parsed.deinit();
    const body = parsed.program.functions[0].body;

    // or is looser than and: p or (q and r)
    const a = body.statements[0].let.value.binary;
    try testing.expectEqual(ast.BinaryOp.logic_or, a.op);
    try testing.expectEqual(ast.BinaryOp.logic_and, a.right.binary.op);
    // and is looser than comparison: p and (q == r)
    const b = body.statements[1].let.value.binary;
    try testing.expectEqual(ast.BinaryOp.logic_and, b.op);
    try testing.expectEqual(ast.BinaryOp.equal, b.right.binary.op);
    // comparison is looser than the fallback: p == (q else r).  This
    // is what makes `x else 0 > 5` compare the fallback.
    const c = body.statements[2].let.value.binary;
    try testing.expectEqual(ast.BinaryOp.equal, c.op);
    try testing.expectEqual(ast.BinaryOp.coalesce, c.right.binary.op);
    // The fallback is looser than arithmetic: p else (q + r), so
    // `x else n + 1` falls back to the sum.
    const d = body.statements[3].let.value.binary;
    try testing.expectEqual(ast.BinaryOp.coalesce, d.op);
    try testing.expectEqual(ast.BinaryOp.add, d.right.binary.op);
    // Additive is looser than multiplicative, modulo included:
    // p + (q % r).
    const e = body.statements[4].let.value.binary;
    try testing.expectEqual(ast.BinaryOp.add, e.op);
    try testing.expectEqual(ast.BinaryOp.modulo, e.right.binary.op);
    // And modulo sits *with* the other multiplicative operators
    // rather than above or below them, so it associates left with
    // them: (p % q) * r.
    const f = body.statements[5].let.value.binary;
    try testing.expectEqual(ast.BinaryOp.multiply, f.op);
    try testing.expectEqual(ast.BinaryOp.modulo, f.left.binary.op);
    // `else` is the one operator that associates right, so a chain of
    // fallbacks is a real chain: p else (q else r).
    const g = body.statements[6].let.value.binary;
    try testing.expectEqual(ast.BinaryOp.coalesce, g.op);
    try testing.expectEqual(ast.BinaryOp.coalesce, g.right.binary.op);
    // `catch` shares the level, so it reads the same way against
    // arithmetic and against `else`.
    const h = body.statements[7].let.value.binary;
    try testing.expectEqual(ast.BinaryOp.catch_error, h.op);
    try testing.expectEqual(ast.BinaryOp.add, h.right.binary.op);
    const i = body.statements[8].let.value.binary;
    try testing.expectEqual(ast.BinaryOp.catch_error, i.op);
    try testing.expectEqual(ast.BinaryOp.coalesce, i.right.binary.op);
}

test "the three spellings of catch are told apart by what follows the word" {
    // `catch:` opens a handler, `catch NAME:` opens one with a
    // binding, and `catch NAME` anywhere else is the operator with a
    // name for a fallback.  The third is what makes the second need
    // three tokens of lookahead rather than one, and the third token
    // is the newline: a slice takes a whole expression either side of
    // its colon, and the lexer emits no newline inside brackets
    // (docs/FAILURE.md).
    var parsed = try expectClean(
        \\func main():
        \\    risky() catch:
        \\        print("plain")
        \\    risky() catch reason:
        \\        print(reason)
        \\    let a = risky() catch fallback
        \\    let b = xs[risky() catch base : 3]
        \\
    );
    defer parsed.deinit();
    const body = parsed.program.functions[0].body;

    try testing.expect(body.statements[0].guarded.binding == null);
    try testing.expectEqualStrings("reason", body.statements[1].guarded.binding.?.text);

    const fallback = body.statements[2].let.value.binary;
    try testing.expectEqual(ast.BinaryOp.catch_error, fallback.op);
    try testing.expectEqualStrings("fallback", fallback.right.name.text);

    const sliced = body.statements[3].let.value.slice_range;
    try testing.expectEqual(ast.BinaryOp.catch_error, sliced.start.?.binary.op);
    try testing.expectEqualStrings("base", sliced.start.?.binary.right.name.text);
}

test "'not' in front of a comparison is refused, naming both readings" {
    // docs/LANGUAGE.md: `not` is a prefix operator, so `not a == b` is
    // `(not a) == b` here and `not (a == b)` in Python.  With bool
    // operands both parse and disagree, so the parser will not pick.
    for ([_][]const u8{ "==", "!=", "<", "<=", ">", ">=" }) |operator| {
        const source = try std.fmt.allocPrint(
            testing.allocator,
            "func main():\n    let x = not a {s} b\n",
            .{operator},
        );
        defer testing.allocator.free(source);
        try expectDiagnostics(source, &.{
            .{ .code = "luce.parse.precedence", .line = 2, .column = 13, .contains = "for Python's" },
        });
    }
    // The message quotes the operand back, so the two readings are
    // spelled in the reader's own words.
    try expectDiagnostics("func main():\n    if not ready == other:\n        return\n", &.{
        .{
            .code = "luce.parse.precedence",
            .line = 2,
            .column = 8,
            .contains = "write '(not ready) == …' for this reading, or 'not (ready == …)' for Python's",
        },
    });
    // Either pair of parentheses settles it, and `not` in front of
    // anything that is not a comparison is untouched.
    var fine = try expectClean(
        \\func main():
        \\    let a = (not p) == q
        \\    let b = not (p == q)
        \\    let c = not p and q
        \\    let d = not p
        \\    let e = not not p
        \\
    );
    fine.deinit();
}

test "comparison does not chain, and the fix is written out" {
    // docs/LANGUAGE.md: `a < b < c` is one comparison in Python and a
    // bool-versus-long type error here.  Refuse it in the parser, where
    // the operators are still in hand.
    try expectDiagnostics("func main():\n    let x = a < b < c\n", &.{
        .{ .code = "luce.parse.chain", .line = 2, .column = 19, .contains = "write 'a < b and b < c'" },
    });
    // The whole level is non-associative, not just a repeated
    // operator: mixed comparisons chain no better than matched ones.
    try expectDiagnostics("func main():\n    let x = a < b == c\n", &.{
        .{ .code = "luce.parse.chain", .line = 2, .column = 19, .contains = "write 'a < b and b == c'" },
    });
    try expectDiagnostics("func main():\n    if 0 <= i < len(xs):\n        return\n", &.{
        .{ .code = "luce.parse.chain", .line = 2, .column = 15, .contains = "write '0 <= i and i < len(xs)'" },
    });
    // Too long to quote back, so the fix is spelled with placeholders
    // rather than half a screen of the reader's source.
    try expectDiagnostics(
        "func main():\n    let x = alpha_value_number < beta_value_here < gamma\n",
        &.{.{ .code = "luce.parse.chain", .line = 2, .column = 50, .contains = "does not chain" }},
    );
    // Comparisons that are not chained stay legal, parenthesized or
    // separated by `and`.
    var fine = try expectClean(
        \\func main():
        \\    let a = x < y and y < z
        \\    let b = (x < y) == (y < z)
        \\    let c = x + 1 < y + 2
        \\
    );
    fine.deinit();
}

test "every literal form parses" {
    var parsed = try expectClean(
        \\func main():
        \\    let a = 42
        \\    let b = 2.5
        \\    let c = 1.5e2
        \\    let d = 1e3
        \\    let e = true
        \\    let f = false
        \\    let g = "text"
        \\    let h = [1, 2, 3]
        \\    let i = []
        \\    let j = new builder()
        \\    let k = new builder
        \\    let l = new list(long)
        \\    let m = new map(string, long)
        \\    let n = new array(double, 4, 8)
        \\
    );
    defer parsed.deinit();
    const body = parsed.program.functions[0].body;
    try testing.expect(body.statements[0].let.value.* == .int_literal);
    try testing.expect(body.statements[1].let.value.* == .float_literal);
    try testing.expect(body.statements[2].let.value.* == .float_literal);
    try testing.expect(body.statements[3].let.value.* == .float_literal);
    try testing.expect(body.statements[4].let.value.bool_literal.value);
    try testing.expect(!body.statements[5].let.value.bool_literal.value);
    try testing.expectEqualStrings("text", body.statements[6].let.value.string_literal.decoded);
    try testing.expectEqual(@as(usize, 3), body.statements[7].let.value.list_literal.elements.len);
    try testing.expectEqual(@as(usize, 0), body.statements[8].let.value.list_literal.elements.len);
    try testing.expectEqualStrings("builder", body.statements[9].let.value.new_object.type_name.name);
    try testing.expectEqualStrings("builder", body.statements[10].let.value.new_object.type_name.name);
    try testing.expectEqualStrings("long", body.statements[11].let.value.new_object.type_name.arguments[0].name);
    try testing.expectEqualStrings("map", body.statements[12].let.value.new_object.type_name.name);
    try testing.expectEqual(@as(usize, 2), body.statements[13].let.value.new_object.dims.len);
}

test "map literals parse in constant and runtime positions, across lines and with a trailing comma" {
    var parsed = try expectClean(
        \\const months: map(string, long) = {
        \\    "jan": 1,
        \\    "feb": 1 + 1,
        \\}
        \\func main():
        \\    let by_number = {1: "one", 2: "two",}
        \\    let nested = {"numbers": {1: "one"}}
        \\
    );
    defer parsed.deinit();

    const months = parsed.program.constants[0].value.map_literal;
    try testing.expectEqual(@as(usize, 2), months.entries.len);
    try testing.expectEqualStrings("jan", months.entries[0].key.string_literal.decoded);
    try testing.expectEqualStrings("1", months.entries[0].value.int_literal.text);
    try testing.expect(months.entries[1].value.* == .binary);
    try testing.expectEqual(months.entries[0].key.span().start, months.entries[0].span.start);
    try testing.expectEqual(months.entries[0].value.span().end, months.entries[0].span.end);

    const body = parsed.program.functions[0].body.statements;
    const by_number = body[0].let.value.map_literal;
    try testing.expectEqual(@as(usize, 2), by_number.entries.len);
    try testing.expectEqualStrings("1", by_number.entries[0].key.int_literal.text);
    try testing.expectEqualStrings("two", by_number.entries[1].value.string_literal.decoded);
    try testing.expect(body[1].let.value.map_literal.entries[0].value.* == .map_literal);
}

test "empty, malformed, and truncated map literals refuse once and recover" {
    var empty = try parseText(
        \\func main():
        \\    let bad = {}
        \\    let okay = 1
        \\
    );
    defer empty.deinit();
    try testing.expectEqual(@as(usize, 1), empty.diagnostics.count());
    try testing.expectEqualStrings("luce.parse.expression", empty.diagnostics.at(0).?.code);
    try testing.expect(std.mem.indexOf(u8, empty.diagnostics.at(0).?.message, "new map(K, V)") != null);
    try testing.expectEqual(@as(usize, 1), empty.program.functions[0].body.statements.len);
    try testing.expectEqualStrings("okay", empty.program.functions[0].body.statements[0].let.name);

    try expectDiagnostics("func main():\n    let bad = {\"a\", 1}\n    let okay = 1\n", &.{
        .{ .code = "luce.parse.expected", .line = 2, .column = 19, .contains = "between a map key and value" },
    });
    try expectDiagnostics("func main():\n    let bad = {\"a\": 1 \"b\": 2}\n    let okay = 1\n", &.{
        .{ .code = "luce.parse.expected", .line = 2, .column = 23, .contains = "missing ','" },
    });
    try expectDiagnostics("func main():\n    let bad = {\n        \"a\": 1,\n", &.{
        .{ .code = "luce.parse.expected", .line = 2, .column = 15, .contains = "unclosed '{'" },
    });
}

test "collections parse: types, new, literals, indexing, slices, for-in" {
    var parsed = try expectClean(
        \\func main():
        \\    var xs: list(long) = [1, 2, 3]
        \\    var m = new map(string, list(long))
        \\    var grid = new array(double, 4, 8)
        \\    var b = new builder()
        \\    xs[0] = 10
        \\    grid[1, 2] = 3.5
        \\    m["ones"] = xs
        \\    let mid = xs[1:2]
        \\    let head = xs[:1]
        \\    let tail = xs[1:]
        \\    let whole = xs[:]
        \\    for x in xs:
        \\        append(b, string(x))
        \\
    );
    defer parsed.deinit();
    const body = parsed.program.functions[0].body;

    const annotated = body.statements[0].variable;
    try testing.expectEqualStrings("list", annotated.annotation.?.name);
    try testing.expectEqualStrings("long", annotated.annotation.?.arguments[0].name);
    try testing.expectEqual(@as(usize, 3), annotated.value.?.list_literal.elements.len);

    const map_new = body.statements[1].variable.value.?.new_object;
    try testing.expectEqualStrings("map", map_new.type_name.name);
    try testing.expectEqualStrings("list", map_new.type_name.arguments[1].name);

    const array_new = body.statements[2].variable.value.?.new_object;
    try testing.expectEqualStrings("array", array_new.type_name.name);
    try testing.expectEqual(@as(usize, 2), array_new.dims.len);

    try testing.expectEqual(@as(usize, 1), body.statements[4].assign.target.index.indices.len);
    try testing.expectEqual(@as(usize, 2), body.statements[5].assign.target.index.indices.len);
    const mid = body.statements[7].let.value.slice_range;
    try testing.expect(mid.start != null and mid.end != null);
    try testing.expect(body.statements[8].let.value.slice_range.start == null);
    try testing.expect(body.statements[9].let.value.slice_range.end == null);
    const whole = body.statements[10].let.value.slice_range;
    try testing.expect(whole.start == null and whole.end == null);
    try testing.expectEqualStrings("x", body.statements[11].for_each.name);
}

test "method calls parse on any postfix expression" {
    var parsed = try expectClean(
        \\func main():
        \\    var xs = [3, 1]
        \\    xs.append(2)
        \\    xs.sort()
        \\    let n = xs[0:2].find(3)
        \\    let word = "Hello".lower()
        \\    let deep = shapes.Point.origin().x
        \\
    );
    defer parsed.deinit();
    const body = parsed.program.functions[0].body;
    const call = body.statements[1].expression.value.method;
    try testing.expectEqualStrings("append", call.name);
    try testing.expect(body.statements[3].let.value.method.target.* == .slice_range);
    try testing.expect(body.statements[4].let.value.method.target.* == .string_literal);
    // module.Struct.member() is a method node whose target is the
    // dotted chain; the analyzer resolves the namespace.
    const deep = body.statements[5].let.value.field;
    try testing.expectEqualStrings("x", deep.name);
    try testing.expectEqualStrings("origin", deep.target.method.name);
}

test "calls parse positional, named, and trailing-comma argument lists" {
    var parsed = try expectClean(
        \\func main():
        \\    f()
        \\    f(1, 2)
        \\    f(1, 2,)
        \\    let p = Point(x = 1, y = 2)
        \\    let q = Point(x = 1,)
        \\    let xs = [1, 2,]
        \\    g(a = 1 == 2)
        \\
    );
    defer parsed.deinit();
    const body = parsed.program.functions[0].body;
    try testing.expectEqual(@as(usize, 0), body.statements[0].expression.value.call.arguments.len);
    try testing.expectEqual(@as(usize, 2), body.statements[1].expression.value.call.arguments.len);
    try testing.expectEqual(@as(usize, 2), body.statements[2].expression.value.call.arguments.len);
    const named = body.statements[3].let.value.call.arguments;
    try testing.expectEqualStrings("x", named[0].name.?);
    try testing.expectEqualStrings("y", named[1].name.?);
    try testing.expectEqual(@as(usize, 1), body.statements[4].let.value.call.arguments.len);
    try testing.expectEqual(@as(usize, 2), body.statements[5].let.value.list_literal.elements.len);
    // `a = 1 == 2` is one named argument, not a comparison of names.
    const compared = body.statements[6].expression.value.call.arguments[0];
    try testing.expectEqualStrings("a", compared.name.?);
    try testing.expect(compared.value.* == .binary);
}

test "strings decode escapes" {
    var parsed = try expectClean(
        \\func main():
        \\    var text = ""
        \\    text = "line\none\ttab \"quoted\""
        \\
    );
    defer parsed.deinit();
    const value = parsed.program.functions[0].body.statements[1].assign.value;
    try testing.expectEqualStrings("line\none\ttab \"quoted\"", value.string_literal.decoded);
}

test "f-strings expand to string()-wrapped concatenation" {
    var parsed = try expectClean(
        \\func main():
        \\    let a = f"x = {x}, y = {y}"
        \\    let b = f"{{literal}}"
        \\    let c = f""
        \\    let d = f"{a + b}"
        \\    let e = f"{m["key"]}"
        \\    let f = f"{ {"a": 1} }"
        \\    let g = f"{ a + "!" }"
        \\    let h = f"{ len({ "key": a }) }"
        \\
    );
    defer parsed.deinit();
    const body = parsed.program.functions[0].body;
    // "x = " + string(x) + ", y = " + string(y), left-associated.
    const a = body.statements[0].let.value.binary;
    try testing.expectEqual(ast.BinaryOp.add, a.op);
    try testing.expectEqualStrings("string", a.right.call.callee);
    try testing.expectEqualStrings("y", a.right.call.arguments[0].value.name.text);
    // Doubled braces are literal text, with no interpolation at all.
    try testing.expectEqualStrings("{literal}", body.statements[1].let.value.string_literal.decoded);
    try testing.expectEqualStrings("", body.statements[2].let.value.string_literal.decoded);
    // A hole is a whole expression, and may contain a nested string.
    try testing.expect(body.statements[3].let.value.call.arguments[0].value.* == .binary);
    try testing.expect(body.statements[4].let.value.call.arguments[0].value.* == .index);
    // A map's colon is nested syntax, not an f-string format specifier.
    const mapped = body.statements[5].let.value.call.arguments[0].value;
    try testing.expect(mapped.* == .map_literal);
    try testing.expect(body.statements[6].let.value.call.arguments[0].value.* == .binary);
    try testing.expect(body.statements[7].let.value.call.arguments[0].value.* == .call);
    try testing.expect(body.statements[7].let.value.call.arguments[0].value.call.arguments[0].value.* == .map_literal);
}

test "spans point at the source the node came from" {
    const text =
        \\func main():
        \\    let total = alpha + beta
        \\
    ;
    var parsed = try expectClean(text);
    defer parsed.deinit();
    const value = parsed.program.functions[0].body.statements[0].let.value;
    try testing.expectEqualStrings("alpha + beta", value.span().slice(text));
    try testing.expectEqualStrings("alpha", value.binary.left.span().slice(text));
    try testing.expectEqualStrings("beta", value.binary.right.span().slice(text));
}

// ---------------------------------------------------------------------------
// Recovery
// ---------------------------------------------------------------------------

test "five unrelated mistakes yield five diagnostics, one each" {
    // The property that separates a finished parser from a started
    // one: no mistake swallows the next, and none invents an error
    // out of its own wreckage.
    try expectDiagnostics(
        \\func a():
        \\    let x =
        \\
        \\func b()
        \\    return 1
        \\
        \\func c():
        \\    let 3 = 4
        \\
        \\struct D
        \\    x: long
        \\
        \\func e():
        \\    if q = 2:
        \\        return
        \\
    , &.{
        .{ .code = "luce.parse.expression", .line = 2, .column = 12 },
        .{ .code = "luce.parse.expected", .line = 4, .column = 9, .contains = "':' to open the block" },
        .{ .code = "luce.parse.expected", .line = 8, .column = 9, .contains = "a binding name" },
        .{ .code = "luce.parse.expected", .line = 10, .column = 9, .contains = "':' after the struct name" },
        .{ .code = "luce.parse.expected", .line = 14, .column = 10, .contains = "write '=='" },
    });
}

test "a header that fails takes its orphaned body with it" {
    // Without this, one missing ':' reports once for the header and
    // then once per statement of the body it left stranded.
    try expectDiagnostics("func main()\n    let x = 1\n    let y = 2\n    print(x)\n", &.{
        .{ .code = "luce.parse.expected", .line = 1, .column = 12 },
    });
    try expectDiagnostics("func main():\n    if x > 1\n        y = 2\n        z = 3\n    print(4)\n", &.{
        .{ .code = "luce.parse.expected", .line = 2, .column = 13 },
    });
    try expectDiagnostics("struct D\n    x: long\n    y: long\n", &.{
        .{ .code = "luce.parse.expected", .line = 1, .column = 9 },
    });
    // A header whose ':' is the *only* thing wrong is read on anyway:
    // the layout says a block was meant, so the body is parsed and its
    // tree is the one the reader wrote.
    var recovered = try parseText("func main()\n    let x = 1\n    print(x)\n");
    defer recovered.deinit();
    try testing.expectEqual(@as(usize, 1), recovered.diagnostics.count());
    try testing.expectEqual(@as(usize, 1), recovered.program.functions.len);
    try testing.expectEqual(@as(usize, 2), recovered.program.functions[0].body.statements.len);
    // And a real mistake inside that body is still found, rather than
    // being swallowed with the header.
    try expectDiagnostics("func main()\n    let x = 1\n    let y =\n", &.{
        .{ .code = "luce.parse.expected", .line = 1, .column = 12, .contains = "':' to open the block" },
        .{ .code = "luce.parse.expression", .line = 3, .column = 12, .contains = "found end of line" },
    });
    try expectDiagnostics("struct D\n    x: long\n    y:\n", &.{
        .{ .code = "luce.parse.expected", .line = 1, .column = 9, .contains = "':' after the struct name" },
        .{ .code = "luce.parse.expected", .line = 3, .column = 7, .contains = "a type name" },
    });
    // With no body to read on into there is nothing to recover, and
    // the header's own diagnostic stands alone.
    try expectDiagnostics("func main()\n", &.{
        .{ .code = "luce.parse.expected", .line = 1, .column = 12 },
    });
}

test "recovery resumes at the next declaration, not inside the last one" {
    var parsed = try parseText(
        \\func main():
        \\    let = 3
        \\    let ok = 1
        \\    var value = ok +
        \\
        \\func helper() -> long:
        \\    return 2
        \\
    );
    defer parsed.deinit();
    try testing.expect(parsed.diagnostics.count() >= 2);
    // Recovery still sees both functions, and the good statement
    // between the two broken ones.
    try testing.expectEqual(@as(usize, 2), parsed.program.functions.len);
    try testing.expectEqualStrings("helper", parsed.program.functions[1].name);
}

test "a statement that runs past its newline reports once and stops" {
    // `in` is not an operator; the old parser reported the missing
    // newline and then "expected an expression" on the leftovers.
    try expectDiagnostics("func main():\n    let b = x in xs\n    print(1)\n", &.{
        .{ .code = "luce.parse.expected", .line = 2, .column = 15 },
    });
    try expectDiagnostics("func main():\n    let a = 1 let b = 2\n    print(1)\n", &.{
        .{ .code = "luce.parse.expected", .line = 2, .column = 15, .contains = "end of line" },
    });
}

test "a file that starts indented reports the indentation, not the statement" {
    try expectDiagnostics("    let x = 1\nconst y = 2\n", &.{
        .{ .code = "luce.parse.top", .line = 1, .column = 1, .contains = "left margin" },
    });
}

// ---------------------------------------------------------------------------
// Diagnostic quality
// ---------------------------------------------------------------------------

test "the ordinary mistakes name themselves and point at the offending token" {
    const Case = struct { source: []const u8, wanted: Wanted };
    const cases = [_]Case{
        // `=` where `==` was meant, in both condition positions.
        .{
            .source = "func main():\n    if x = 1:\n        return\n",
            .wanted = .{ .code = "luce.parse.expected", .line = 2, .column = 10, .contains = "write '==' to compare" },
        },
        .{
            .source = "func main():\n    while x = 1:\n        return\n",
            .wanted = .{ .code = "luce.parse.expected", .line = 2, .column = 13, .contains = "write '==' to compare" },
        },
        // A keyword used as a name says so, rather than "expected a name".
        .{
            .source = "func main():\n    let for = 1\n",
            .wanted = .{ .code = "luce.parse.expected", .line = 2, .column = 9, .contains = "'for' is a keyword" },
        },
        .{
            .source = "func while():\n    return\n",
            .wanted = .{ .code = "luce.parse.expected", .line = 1, .column = 6, .contains = "'while' is a keyword" },
        },
        // elif/else without an if, and declarations inside a function.
        .{
            .source = "func main():\n    elif x:\n        return\n",
            .wanted = .{ .code = "luce.parse.expected", .line = 2, .column = 5, .contains = "'elif' has no matching 'if'" },
        },
        .{
            .source = "func main():\n    else:\n        return\n",
            .wanted = .{ .code = "luce.parse.expected", .line = 2, .column = 5, .contains = "'else' has no matching 'if'" },
        },
        .{
            .source = "func main():\n    struct S:\n        x: long\n",
            .wanted = .{ .code = "luce.parse.expected", .line = 2, .column = 5, .contains = "belong at file scope" },
        },
        // A missing expression names what it found instead.
        .{
            .source = "func main():\n    let x = 1 +\n",
            .wanted = .{ .code = "luce.parse.expression", .line = 2, .column = 16, .contains = "found end of line" },
        },
        .{
            .source = "func main():\n    f(1, , 2)\n",
            .wanted = .{ .code = "luce.parse.expression", .line = 2, .column = 10, .contains = "found ','" },
        },
        // The std namespace is one level deep; only sibling imports
        // may walk folders (docs/PACKAGES.md D2).
        .{
            .source = "import std.math.pi\n\nfunc main():\n    return\n",
            .wanted = .{ .code = "luce.parse.expected", .line = 1, .column = 16, .contains = "no deeper paths" },
        },
        .{
            .source = "import std.\n\nfunc main():\n    return\n",
            .wanted = .{ .code = "luce.parse.expected", .line = 1, .column = 12, .contains = "after std." },
        },
        // A dotted import ending in a dot wants the next segment.
        .{
            .source = "import geo.\n\nfunc main():\n    return\n",
            .wanted = .{ .code = "luce.parse.expected", .line = 1, .column = 12, .contains = "a module name after the dot" },
        },
        // `as` opens an alias and needs the name.
        .{
            .source = "import geo as\n\nfunc main():\n    return\n",
            .wanted = .{ .code = "luce.parse.expected", .line = 1, .column = 14, .contains = "a binding name after as" },
        },
        // The wildcard is not a name here either (VISIBILITY.md D9).
        .{
            .source = "import geo as _\n\nfunc main():\n    return\n",
            .wanted = .{ .code = "luce.parse.expected", .line = 1, .column = 15, .contains = "a binding needs a name" },
        },
        // A standard module keeps its own name: the alias belongs on
        // the import that collides with it (docs/PACKAGES.md D2).
        .{
            .source = "import std.math as m\n\nfunc main():\n    return\n",
            .wanted = .{ .code = "luce.parse.expected", .line = 1, .column = 20, .contains = "keeps its name" },
        },
        // range is two bounds, and says so instead of "expected ')'".
        .{
            .source = "func main():\n    for i in range(0, 10, 2):\n        return\n",
            .wanted = .{ .code = "luce.parse.expected", .line = 2, .column = 27, .contains = "exactly two bounds" },
        },
        // Assignment to something that is not a place.
        .{
            .source = "func main():\n    f() = 1\n",
            .wanted = .{ .code = "luce.parse.assign", .line = 2, .column = 5, .contains = "cannot assign" },
        },
        .{
            .source = "func main():\n    var xs = [1]\n    xs[0:1] = 2\n",
            .wanted = .{ .code = "luce.parse.assign", .line = 3, .column = 5, .contains = "a slice copies" },
        },
        // new builds the four heap types; a struct is a value.
        .{
            .source = "func main():\n    let a = new Point()\n",
            .wanted = .{ .code = "luce.parse.new", .line = 2, .column = 17, .contains = "structs are values" },
        },
    };
    for (cases) |case| try expectDiagnostics(case.source, &.{case.wanted});
}

test "the mistakes a beginner actually makes name the Luce spelling" {
    // Read what comes out of a genuinely broken program, not a
    // synthetic one: these are the shapes people arrive with from
    // Python, C, Rust and JavaScript.
    const Case = struct { source: []const u8, wanted: Wanted };
    const cases = [_]Case{
        // `else if` is `elif` here, and without this the reader is
        // told the block wanted a ':' and found 'if'.
        .{
            .source = "func main():\n    if a:\n        return\n    else if b:\n        return\n",
            .wanted = .{ .code = "luce.parse.expected", .line = 4, .column = 5, .contains = "write 'elif'" },
        },
        // A call written without its parentheses — the Python 2 and
        // shell reflex.
        .{
            .source = "func main():\n    print \"hello\"\n",
            .wanted = .{ .code = "luce.parse.expected", .line = 2, .column = 11, .contains = "write 'print(...)'" },
        },
        .{
            .source = "func main():\n    f x\n",
            .wanted = .{ .code = "luce.parse.expected", .line = 2, .column = 7, .contains = "write 'f(...)'" },
        },
        // The same shape, but the name is a keyword somewhere else:
        // the word is the better answer than the parentheses.
        .{
            .source = "func main():\n    if a:\n        return\n    elseif b:\n        return\n",
            .wanted = .{ .code = "luce.parse.expected", .line = 4, .column = 5, .contains = "write 'elif'" },
        },
        .{
            .source = "func main():\n    foreach x in xs:\n        print(x)\n",
            .wanted = .{ .code = "luce.parse.expected", .line = 2, .column = 5, .contains = "'for x in xs:'" },
        },
        .{
            .source = "func main():\n    switch x:\n        return\n",
            .wanted = .{ .code = "luce.parse.expected", .line = 2, .column = 5, .contains = "no switch" },
        },
        // Declaration keywords from the languages next door.
        .{
            .source = "def main():\n    return\n",
            .wanted = .{ .code = "luce.parse.top", .line = 1, .column = 1, .contains = "declared with 'func'" },
        },
        .{
            .source = "final width = 80\n",
            .wanted = .{ .code = "luce.parse.top", .line = 1, .column = 1, .contains = "declared with 'const'" },
        },
        .{
            .source = "from math import sqrt\n",
            .wanted = .{ .code = "luce.parse.top", .line = 1, .column = 1, .contains = "for the standard library" },
        },
        // A keyword in the wrong case is the same mistake, answered
        // from the lexer's own table.
        .{
            .source = "Func main():\n    return\n",
            .wanted = .{ .code = "luce.parse.top", .line = 1, .column = 1, .contains = "write 'func', not 'Func'" },
        },
        .{
            .source = "STRUCT Point:\n    x: long\n",
            .wanted = .{ .code = "luce.parse.top", .line = 1, .column = 1, .contains = "write 'struct'" },
        },
        // Tuples do not exist, and "expected ')' , found ','" does not
        // say so.
        .{
            .source = "func main():\n    let t = (1, 2)\n",
            .wanted = .{ .code = "luce.parse.expression", .line = 2, .column = 15, .contains = "no tuples" },
        },
        // A block with nothing in it names the header that is waiting.
        .{
            .source = "func main():\n    while true:\n",
            .wanted = .{ .code = "luce.parse.expected", .line = 3, .column = 1, .contains = "'while' block is empty" },
        },
        .{
            .source = "func main():\n    if a:\n",
            .wanted = .{ .code = "luce.parse.expected", .line = 3, .column = 1, .contains = "'if' block is empty" },
        },
        .{
            .source = "func main():\n    if a {\n        return\n",
            .wanted = .{ .code = "luce.parse.expected", .line = 2, .column = 10, .contains = "blocks open with ':'" },
        },
        .{
            .source = "struct Point:\n",
            .wanted = .{ .code = "luce.parse.expected", .line = 2, .column = 1, .contains = "'struct' block is empty" },
        },
        .{
            .source = "func main():\n    if a:\n    return\n",
            .wanted = .{ .code = "luce.parse.expected", .line = 3, .column = 5, .contains = "indented block under 'if'" },
        },
        // A line indented further than its block, with no header above
        // it to justify the step.
        .{
            .source = "func main():\n    let x = 1\n        let y = 2\n    print(x)\n",
            .wanted = .{ .code = "luce.parse.indent", .line = 3, .column = 1, .contains = "nothing above this line opens a block" },
        },
    };
    for (cases) |case| try expectDiagnostics(case.source, &.{case.wanted});
}

test "a missing comma is reported as a missing comma, in every list there is" {
    // "expected ')' to close '(', found 'y'" describes the parser;
    // "missing ',' before 'y'" describes the fix.
    const Case = struct { source: []const u8, wanted: Wanted };
    const cases = [_]Case{
        .{
            .source = "func main():\n    f(1 2)\n",
            .wanted = .{ .code = "luce.parse.expected", .line = 2, .column = 9, .contains = "missing ',' before a number" },
        },
        .{
            .source = "func main():\n    let p = Point(x = 1 y = 2)\n",
            .wanted = .{ .code = "luce.parse.expected", .line = 2, .column = 25, .contains = "missing ',' before 'y'" },
        },
        .{
            .source = "func main():\n    let xs = [1 2 3]\n",
            .wanted = .{ .code = "luce.parse.expected", .line = 2, .column = 17, .contains = "missing ','" },
        },
        .{
            .source = "func main():\n    let m = new map(string long)\n",
            .wanted = .{ .code = "luce.parse.expected", .line = 2, .column = 28, .contains = "missing ',' before 'long'" },
        },
        .{
            .source = "func main():\n    let v = grid[1 2]\n",
            .wanted = .{ .code = "luce.parse.expected", .line = 2, .column = 20, .contains = "missing ','" },
        },
        .{
            .source = "func main():\n    let g = new array(long 2 3)\n",
            .wanted = .{ .code = "luce.parse.expected", .line = 2, .column = 28, .contains = "missing ','" },
        },
        .{
            .source = "func f(a: long b: long):\n    return\n",
            .wanted = .{ .code = "luce.parse.expected", .line = 1, .column = 16, .contains = "missing ',' before 'b'" },
        },
        .{
            .source = "func main():\n    var x: map(string long) = new map(string, long)\n",
            .wanted = .{ .code = "luce.parse.expected", .line = 2, .column = 23, .contains = "missing ',' before 'long'" },
        },
    };
    for (cases) |case| try expectDiagnostics(case.source, &.{case.wanted});

    // Across a line break the honest answer is the unclosed bracket,
    // not a missing separator: the next line is a statement, not an
    // element.
    try expectDiagnostics("func main():\n    let xs = [1, 2\n    print(3)\n", &.{
        .{ .code = "luce.parse.expected", .line = 2, .column = 14, .contains = "unclosed '['" },
    });
}

test "a list that runs out of input blames the bracket, not the element that never came" {
    // Every one of these used to report "expected an expression, found
    // end of line" at end of file — a lie about a line the reader
    // never wrote.  The bracket is the only actionable place.
    const cases = [_][]const u8{
        "func main():\n    let xs = [1, 2,\n",
        "func main():\n    let x = xs[0,\n",
        "func main():\n    var x: list(long,\n",
        "func main():\n    let g = new array(long, 2,\n",
        "func main():\n    f(a,\n",
        "func f(a: long,\n",
        "func main():\n    let p = Point(x = 1,\n",
    };
    for (cases) |source| {
        var parsed = try parseText(source);
        defer parsed.deinit();
        errdefer {
            std.debug.print("for:\n{s}got:\n", .{source});
            dump(&parsed);
        }
        try testing.expectEqual(@as(usize, 1), parsed.diagnostics.count());
        const item = parsed.diagnostics.at(0).?;
        try testing.expectEqualStrings("luce.parse.expected", item.code);
        if (std.mem.indexOf(u8, item.message, "unclosed") == null) {
            std.debug.print("for:\n{s}got: {s}\n", .{ source, item.message });
            return error.TestUnexpectedResult;
        }
    }
}

test "a truncated string literal is stage 2's error, and only stage 2's" {
    // Stage 2 emits a recovery token for an unterminated literal so the
    // line still has an operand.  The parser must not read the
    // truncated bytes as if they were closed and report a second time
    // about a brace that was never really open.
    const cases = [_][]const u8{
        "func main():\n    let s = f\"{x\n    print(s)\n",
        "func main():\n    let s = \"abc\n    print(s)\n",
        "func main():\n    let s = f\"value: {\n",
        "func main():\n    let s = f\"a}\n",
    };
    for (cases) |source| {
        var parsed = try parseText(source);
        defer parsed.deinit();
        errdefer {
            std.debug.print("for:\n{s}got:\n", .{source});
            dump(&parsed);
        }
        try testing.expectEqual(@as(usize, 1), parsed.diagnostics.count());
        try testing.expectEqualStrings("luce.lex.string", parsed.diagnostics.at(0).?.code);
    }
}

test "'=' where '==' was meant reads on as the comparison, so the body is still checked" {
    // Zig's `wrong_equal_var_decl` move: report the habit once, then
    // parse what was plainly meant, so a second mistake inside the
    // block is still found instead of being swallowed with it.
    try expectDiagnostics(
        \\func main():
        \\    if x = 1:
        \\        let y =
        \\    return
        \\
    , &.{
        .{ .code = "luce.parse.expected", .line = 2, .column = 10, .contains = "write '==' to compare" },
        .{ .code = "luce.parse.expression", .line = 3, .column = 16, .contains = "found end of line" },
    });
    // The recovered condition really is the comparison, not a
    // half-parsed fragment.
    var parsed = try parseText("func main():\n    while count = 0:\n        return\n");
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.diagnostics.count());
    const condition = parsed.program.functions[0].body.statements[0].while_loop.condition;
    try testing.expectEqual(ast.BinaryOp.equal, condition.binary.op);
    try testing.expectEqualStrings("count", condition.binary.left.name.text);
}

test "an unclosed bracket is reported at the bracket once it has run past its line" {
    // The lexer suspends newlines inside brackets, so an unclosed one
    // eats the rest of the file; the only actionable place to point
    // is the opener.
    try expectDiagnostics("func main():\n    let x = (1 + 2\n    let y = 3\n", &.{
        .{ .code = "luce.parse.expected", .line = 2, .column = 13, .contains = "unclosed '(' — no matching ')'" },
    });
    try expectDiagnostics("func main():\n    let x = [1, 2\n    let y = 3\n", &.{
        .{ .code = "luce.parse.expected", .line = 2, .column = 13, .contains = "unclosed '['" },
    });
    try expectDiagnostics("func main():\n    let x = xs[0\n    let y = 3\n", &.{
        .{ .code = "luce.parse.expected", .line = 2, .column = 15, .contains = "unclosed '['" },
    });
    // On its own line the offending token is the better place: the
    // group is short enough to see whole, and a token that could have
    // been the next element names the separator instead.
    try expectDiagnostics("func main():\n    f(1 + )\n", &.{
        .{ .code = "luce.parse.expression", .line = 2, .column = 11, .contains = "found ')'" },
    });
    try expectDiagnostics("func main():\n    f(1 2)\n", &.{
        .{ .code = "luce.parse.expected", .line = 2, .column = 9, .contains = "missing ','" },
    });
}

test "f-string holes report their own mistakes, in f-string terms" {
    // `{x:.2f}` is a format spec now (docs/NUMERICS.md §8); one that
    // is not the single supported form still reports here.
    try expectDiagnostics("func main():\n    let s = f\"{x:.2}\"\n", &.{
        .{ .code = "luce.parse.fstring", .line = 2, .column = 17, .contains = "the one form is ':.Nf'" },
    });
    try expectDiagnostics("func main():\n    let s = f\"a{}b\"\n", &.{
        .{ .code = "luce.parse.fstring", .line = 2, .column = 17, .contains = "empty interpolation" },
    });
    try expectDiagnostics("func main():\n    let s = f\"{1 2}\"\n", &.{
        .{ .code = "luce.parse.fstring", .line = 2, .column = 16, .contains = "single expression" },
    });
    try expectDiagnostics("func main():\n    let s = f\"lone }\"\n", &.{
        .{ .code = "luce.parse.fstring", .line = 2, .column = 13, .contains = "unmatched close brace" },
    });
    // A hole's own sub-parse errors carry the sub-parse's code and
    // point into the real source, not into a copy of the hole.
    try expectDiagnostics("func main():\n    let s = f\"{1 +}\"\n", &.{
        .{ .code = "luce.parse.expression", .line = 2, .column = 19 },
    });
}

// ---------------------------------------------------------------------------
// Robustness
// ---------------------------------------------------------------------------

test "every recursive construct is bounded, and hitting the bound is one clean diagnostic" {
    // Each of these once walked off the native stack; the guard is
    // shared, so each one has to be proved through its own path.
    const Case = struct {
        name: []const u8,
        head: []const u8,
        unit: []const u8,
        tail: []const u8,
        code: []const u8 = "luce.parse.nesting",
    };
    const cases = [_]Case{
        .{ .name = "unary minus", .head = "func main():\n    let x = ", .unit = "-", .tail = "1\n" },
        .{ .name = "not", .head = "func main():\n    let x = ", .unit = "not ", .tail = "true\n" },
        .{ .name = "parentheses", .head = "func main():\n    let x = ", .unit = "(", .tail = "1\n" },
        .{ .name = "list literals", .head = "func main():\n    let x = ", .unit = "[", .tail = "1\n" },
        .{ .name = "calls", .head = "func main():\n    let x = ", .unit = "f(", .tail = "1\n" },
        .{ .name = "type arguments", .head = "func main():\n    var x: ", .unit = "list(", .tail = "long\n" },
    };
    for (cases) |case| {
        const text = try repeated(case.head, case.unit, 4000, case.tail);
        defer testing.allocator.free(text);
        var parsed = try parseText(text);
        defer parsed.deinit();
        if (!hasCode(&parsed, case.code)) {
            std.debug.print("{s}: no {s} diagnostic\n", .{ case.name, case.code });
            dump(&parsed);
            return error.TestUnexpectedResult;
        }
    }

    // Nested blocks and elif chains recurse through the statement
    // grammar rather than the expression grammar.
    var nested: std.ArrayList(u8) = .empty;
    defer nested.deinit(testing.allocator);
    try nested.appendSlice(testing.allocator, "func main():\n");
    for (0..1500) |level| {
        for (0..level + 1) |_| try nested.appendSlice(testing.allocator, "    ");
        try nested.appendSlice(testing.allocator, "if x:\n");
    }
    for (0..1501) |_| try nested.appendSlice(testing.allocator, "    ");
    try nested.appendSlice(testing.allocator, "return\n");
    var blocks = try parseText(nested.items);
    defer blocks.deinit();
    // A tower of *indented* blocks is stage 2's answer now — it caps
    // indentation nesting well below the depth this stage would reach,
    // and the earlier stage rightly wins.  What stage 3 owes here is
    // that it still reports and still returns.
    try testing.expect(blocks.diagnostics.count() != 0);
    try testing.expect(hasCode(&blocks, "luce.lex.indent") or hasCode(&blocks, "luce.parse.nesting"));

    const elifs = try repeated(
        "func main():\n    if a:\n        return\n",
        "    elif b:\n        return\n",
        4000,
        "",
    );
    defer testing.allocator.free(elifs);
    var chain = try parseText(elifs);
    defer chain.deinit();
    try testing.expect(hasCode(&chain, "luce.parse.nesting"));
}

test "wide input is linear, not recursive: a ten-thousand element list parses" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "func main():\n    let xs = [");
    var number: [16]u8 = undefined;
    for (0..10000) |value| {
        try text.appendSlice(testing.allocator, try std.fmt.bufPrint(&number, "{d}, ", .{value}));
    }
    try text.appendSlice(testing.allocator, "]\n");

    var parsed = try expectClean(text.items);
    defer parsed.deinit();
    const elements = parsed.program.functions[0].body.statements[0].let.value.list_literal.elements;
    try testing.expectEqual(@as(usize, 10000), elements.len);

    // Long flat chains are loops, not recursion, in every postfix and
    // binary form.
    for ([_][]const u8{ "[0]", ".b", ".b()", " + 1" }) |unit| {
        const chained = try repeated("func main():\n    let x = a", unit, 20000, "\n");
        defer testing.allocator.free(chained);
        var flat = try parseText(chained);
        defer flat.deinit();
        try testing.expectEqual(@as(usize, 0), flat.diagnostics.count());
    }
}

test "reporting is capped so a file of noise cannot flood the diagnostics" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    var line: [48]u8 = undefined;
    for (0..5000) |index| {
        try text.appendSlice(testing.allocator, try std.fmt.bufPrint(&line, "let {d} = = )\n", .{index}));
    }
    var parsed = try parseText(text.items);
    defer parsed.deinit();
    try testing.expect(parsed.diagnostics.count() <= 102);
    try testing.expect(hasCode(&parsed, "luce.parse.limit"));
}

test "truncated input at every prefix terminates and stays inside the source" {
    // Cutting a well-formed program at each byte is the cheapest
    // exhaustive source of half-finished constructs there is.
    const whole =
        \\import math
        \\
        \\const width = 80
        \\
        \\struct Point:
        \\    x: double
        \\    func length() -> double:
        \\        return self.x
        \\    private static func origin() -> Point:
        \\        return Point(x = 0.0)
        \\
        \\func main():
        \\    var xs = [1, 2]
        \\    var m = new map(string, long)
        \\    for i, x in xs:
        \\        if x % 2 == 0 and x > width:
        \\            m[f"k{i}"] += x
        \\        elif not x:
        \\            xs.append(x)
        \\        else:
        \\            return
        \\    while len(xs) > 0:
        \\        xs[0:1] = m
        \\
    ;
    for (0..whole.len + 1) |cut| {
        var parsed = try parseText(whole[0..cut]);
        defer parsed.deinit();
        for (0..parsed.diagnostics.count()) |index| {
            const item = parsed.diagnostics.at(index).?;
            try testing.expect(item.span.start <= item.span.end);
            try testing.expect(item.span.end <= cut);
        }
    }
}

/// The vocabulary the structure-aware fuzzer draws from: whole tokens
/// and whole lines of real Luce, so that what it generates is a
/// *nearly* valid program rather than noise.  Random bytes exercise
/// the lexer and the outermost recovery; this exercises the grammar
/// itself, which is where the recovery bugs live.
const fragments = [_][]const u8{
    "func main():",          "func f(a: long) -> long:", "static func make():",   "struct P:",
    "import math",           "let x = ",                 "var y: long",           "return ",
    "if ",                   "elif ",                    "else:",                 "while ",
    "for i in range(0, 3):", "for x in xs:",             "break",                 "continue",
    "print(x)",              "xs.append(",               "new map(string, long)", "new list(",
    "new array(long, 2, 2)", "not ",                     "and ",                  "or ",
    "==",                    "<",                        "+",                     "(",
    ")",                     "[",                        "]",                     ",",
    ":",                     ".",                        "=",                     "f\"{x}\"",
    "\"text\"",              "1",                        "2.5",                   "true",
    "xs",                    "Point(x = 1)",
};

/// The indentation a generated line may carry — the layout dimension
/// a token-only fuzzer never reaches.
const indents = [_][]const u8{ "", "    ", "        ", "            ", "  " };

test "fuzz: parsing any bytes terminates with spans inside the source" {
    try testing.fuzz({}, parseAnything, .{ .corpus = &.{
        "func main():\n    let x = 1 + 2\n",
        "func f(a: list(long)) -> long:\n    return len(a)\n",
        "struct P:\n    x: double\n    static func zero() -> P:\n        return P(x = 0.0)\n",
        "enum Method:\n    stored\n    func compressed() -> bool:\n        return self != Method.stored\n",
        "let k = 3\n",
        "func main():\n    if x = 1:\n        for i in range(0, 2):\n            m[f\"{i}\"] += 1\n",
        "func main()\n    let y = (1 + [2, 3\n",
    } });
}

fn parseAnything(_: void, smith: *testing.Smith) anyerror!void {
    var buffer: [512]u8 = undefined;
    const length = smith.sliceWeightedBytes(&buffer, &.{
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .rangeAtMost(u8, 0x20, 0x7e, 5),
        .value(u8, ' ', 5),
        .value(u8, '\n', 5),
        .value(u8, '(', 3),
        .value(u8, ')', 3),
        .value(u8, '[', 2),
        .value(u8, ']', 2),
        .value(u8, ':', 2),
        .value(u8, '"', 2),
        .value(u8, '{', 2),
        .value(u8, '}', 2),
    });
    // Stage 1 is the gate every byte passes through, and stages 2 and
    // 3 are written to its guarantees; feeding raw bytes past it would
    // test a program that cannot happen.  Bytes it refuses are stage
    // 1's answer, not this stage's.
    const prepared = try source_mod.prepare(testing.allocator, buffer[0..length]);
    const source = switch (prepared) {
        .problem => return,
        .text => |text| text,
    };
    defer testing.allocator.free(source);

    var parsed = try parseText(source);
    defer parsed.deinit();

    // Every produced diagnostic points inside the source (parsing
    // itself terminating is the other half of the property — a hang
    // or crash fails the test by never returning).
    for (0..parsed.diagnostics.count()) |index| {
        const item = parsed.diagnostics.at(index).?;
        try testing.expect(item.span.start <= item.span.end);
        try testing.expect(item.span.end <= source.len);
    }
}

test "near-miss programs report, terminate, and never lie about where" {
    // Random bytes mostly die in the lexer; the recovery bugs live
    // behind programs that are *nearly* valid — real fragments and
    // real indentation in an order the grammar does not allow.  A
    // fixed seed, so a failure reproduces exactly.
    var prng = std.Random.DefaultPrng.init(0x03_9a_11_5e);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);

    for (0..20000) |_| {
        text.clearRetainingCapacity();
        try writeNearMiss(prng.random(), &text);
        var parsed = try parseText(text.items);
        defer parsed.deinit();
        errdefer {
            std.debug.print("for:\n{s}got:\n", .{text.items});
            dump(&parsed);
        }
        // The report cap is 100 parse diagnostics plus its own
        // `luce.parse.limit`, on top of whatever stage 2 said.
        try testing.expect(parsed.diagnostics.count() <= 202);
        for (0..parsed.diagnostics.count()) |index| {
            const item = parsed.diagnostics.at(index).?;
            try testing.expect(item.span.start <= item.span.end);
            try testing.expect(item.span.end <= text.items.len);
            try testing.expect(item.message.len != 0);
            try testing.expect(std.mem.startsWith(u8, item.code, "luce."));
        }
    }
}

/// Assemble one near-miss program: a handful of lines, each an
/// indentation followed by a few whole fragments of real Luce.
fn writeNearMiss(random: std.Random, text: *std.ArrayList(u8)) !void {
    const lines = random.intRangeAtMost(usize, 1, 12);
    for (0..lines) |_| {
        try text.appendSlice(testing.allocator, indents[random.uintLessThan(usize, indents.len)]);
        const pieces = random.intRangeAtMost(usize, 1, 6);
        for (0..pieces) |_| {
            try text.appendSlice(
                testing.allocator,
                fragments[random.uintLessThan(usize, fragments.len)],
            );
            if (random.boolean()) try text.append(testing.allocator, ' ');
        }
        try text.append(testing.allocator, '\n');
    }
}

// ---------------------------------------------------------------------------
// The token vocabulary these messages are written in
// ---------------------------------------------------------------------------

test "a trailing ? makes a type optional, and there is no second one" {
    var parsed = try expectClean(
        \\struct Slot:
        \\    held: string?
        \\
        \\func find(key: map(string, long)?, fallback: long) -> long?:
        \\    var seen: list(long)? = none
        \\    return fallback
        \\
    );
    defer parsed.deinit();

    try testing.expect(parsed.program.structs[0].fields[0].type_name.optional);
    const found = parsed.program.functions[0];
    try testing.expect(found.parameters[0].type_name.optional);
    try testing.expectEqualStrings("map", found.parameters[0].type_name.name);
    try testing.expect(!found.parameters[1].type_name.optional);
    try testing.expect(found.returns[0].optional);
    try testing.expect(found.body.statements[0].variable.annotation.?.optional);
    try testing.expect(found.body.statements[0].variable.value.?.* == .none_literal);

    try expectDiagnostics(
        \\func main():
        \\    var n: long?? = none
        \\
    , &.{.{
        .code = "luce.parse.type",
        .line = 2,
        .column = 17,
        .contains = "one '?' is all there is",
    }});
}

test "a parenthesized type is that type, and grouping is never required" {
    // The uniform rule (docs/BINDING.md D7): parentheses group a type
    // and change nothing about it.  What matters is what did *not*
    // move — `long?` and `func(long) -> string?` parse exactly as they
    // always did, and the parenthesized spellings land on the same
    // shapes rather than on new ones.
    var parsed = try expectClean(
        \\func f(bare: long?, grouped: (long)?, answering: func(long) -> string?, absent: (func(long) -> string)?) -> (long):
        \\    return 1
        \\
    );
    defer parsed.deinit();
    const found = parsed.program.functions[0];

    // `long?` and `(long)?` are one type written two ways.
    try testing.expectEqualStrings("long", found.parameters[0].type_name.name);
    try testing.expect(found.parameters[0].type_name.optional);
    try testing.expectEqualStrings("long", found.parameters[1].type_name.name);
    try testing.expect(found.parameters[1].type_name.optional);

    // `func(long) -> string?` still answers an optional string, and
    // the function type itself is present.
    const answering = found.parameters[2].type_name;
    try testing.expectEqualStrings("func", answering.name);
    try testing.expect(!answering.optional);
    try testing.expect(answering.result.?.optional);

    // `(func(long) -> string)?` is the one thing newly writable: the
    // `?` lands on the function and the result keeps its own.
    const absent = found.parameters[3].type_name;
    try testing.expectEqualStrings("func", absent.name);
    try testing.expect(absent.optional);
    try testing.expect(!absent.result.?.optional);

    // `-> (long)` is one type in parentheses, so it is `-> long` —
    // the arity is what separates a parenthesized type from a return
    // shape, and one element is never a shape.
    try testing.expectEqual(@as(usize, 1), found.returns.len);
    try testing.expectEqualStrings("long", found.returns[0].name);

    // A `?` inside the parentheses has taken the one level of absence
    // there is, wherever the parentheses stand.
    try expectDiagnostics("func main():\n    var n: (long?)? = none\n", &.{.{
        .code = "luce.parse.type",
        .line = 2,
        .column = 19,
        .contains = "one '?' is all there is",
    }});
    try expectDiagnostics("func f() -> (long?)?:\n    return none\n", &.{.{
        .code = "luce.parse.type",
        .line = 1,
        .column = 20,
        .contains = "one '?' is all there is",
    }});
}

test "else is an infix operator: right-associative, above comparison, below +" {
    var parsed = try expectClean(
        \\func main():
        \\    let a = x else y else z
        \\    let b = x else y + 1
        \\    let c = x else y == z
        \\
    );
    defer parsed.deinit();
    const body = parsed.program.functions[0].body.statements;

    // Right-associative: `x else (y else z)`.
    const chained = body[0].let.value.binary;
    try testing.expectEqual(ast.BinaryOp.coalesce, chained.op);
    try testing.expect(chained.left.* == .name);
    try testing.expectEqual(ast.BinaryOp.coalesce, chained.right.binary.op);

    // Tighter than `+` binds it: `x else (y + 1)`.
    const arithmetic = body[1].let.value.binary;
    try testing.expectEqual(ast.BinaryOp.coalesce, arithmetic.op);
    try testing.expectEqual(ast.BinaryOp.add, arithmetic.right.binary.op);

    // Looser than comparison: `(x else y) == z`.
    const compared = body[2].let.value.binary;
    try testing.expectEqual(ast.BinaryOp.equal, compared.op);
    try testing.expectEqual(ast.BinaryOp.coalesce, compared.left.binary.op);
}

test "an else block still reads as a block, not as a fallback" {
    var parsed = try expectClean(
        \\func main():
        \\    if a:
        \\        b = 1
        \\    else:
        \\        b = 2
        \\
    );
    defer parsed.deinit();
    const conditional = parsed.program.functions[0].body.statements[0].conditional;
    try testing.expect(conditional.else_block != null);
    try testing.expectEqual(@as(usize, 1), conditional.then_block.statements.len);
    try testing.expectEqual(@as(usize, 1), conditional.else_block.?.statements.len);
}

// ---------------------------------------------------------------------------
// Implied self and static members (docs/SELF.md)
// ---------------------------------------------------------------------------

test "plain members imply self and static is an AST distinction" {
    var parsed = try expectClean(
        \\struct Point:
        \\    x: double
        \\
        \\    func length() -> double:
        \\        return self.x
        \\
        \\    func scale(factor: double):
        \\        self.x = self.x * factor
        \\
        \\    static func origin(offset: double = 0.0) -> Point:
        \\        return Point(x = offset)
        \\
        \\func main():
        \\    return
        \\
    );
    defer parsed.deinit();

    const functions = parsed.program.structs[0].functions;
    try testing.expectEqual(@as(usize, 3), functions.len);

    try testing.expect(!functions[0].is_static);
    try testing.expectEqual(@as(usize, 0), functions[0].parameters.len);
    try testing.expect(functions[0].body.statements[0].return_statement.values[0].* == .field);

    try testing.expect(!functions[1].is_static);
    try testing.expectEqual(@as(usize, 1), functions[1].parameters.len);
    try testing.expectEqualStrings("factor", functions[1].parameters[0].name);

    try testing.expect(functions[2].is_static);
    try testing.expectEqual(@as(usize, 1), functions[2].parameters.len);
    try testing.expectEqualStrings("offset", functions[2].parameters[0].name);
    try testing.expect(std.mem.startsWith(
        u8,
        parsed.source[functions[2].span.start..],
        "static func origin",
    ));
    // File-scope functions are never marked static in the AST.
    try testing.expect(!parsed.program.functions[0].is_static);
}

test "static composes with direct visibility, regions, and enums" {
    var parsed = try expectClean(
        \\struct Tools:
        \\    private static func hidden(value: long) -> long:
        \\        return value
        \\    public:
        \\        static func shown() -> long:
        \\            return 1
        \\        func read() -> long:
        \\            return 2
        \\
        \\enum Method:
        \\    stored
        \\    private static func of(value: long) -> Method:
        \\        return Method.stored
        \\    public func compressed() -> bool:
        \\        return self != Method.stored
        \\
        \\func main():
        \\    return
        \\
    );
    defer parsed.deinit();

    const tools = parsed.program.structs[0].functions;
    try testing.expect(tools[0].is_static);
    try testing.expectEqual(ast.Visibility.private, tools[0].visibility);
    try testing.expect(tools[1].is_static);
    try testing.expectEqual(ast.Visibility.public, tools[1].visibility);
    try testing.expect(!tools[2].is_static);
    try testing.expectEqual(ast.Visibility.public, tools[2].visibility);

    const methods = parsed.program.enums[0].functions;
    try testing.expect(methods[0].is_static);
    try testing.expectEqual(ast.Visibility.private, methods[0].visibility);
    try testing.expect(!methods[1].is_static);
    try testing.expectEqual(ast.Visibility.public, methods[1].visibility);
}

test "written self parameters are refused with the migration" {
    const teaching = "self is implied; remove the parameter";
    try expectDiagnostics(
        \\func f(self):
        \\    return
        \\
    , &.{.{
        .code = "luce.parse.self",
        .line = 1,
        .column = 8,
        .contains = teaching,
    }});

    try expectDiagnostics(
        \\struct Point:
        \\    func f(var self):
        \\        return
        \\
    , &.{.{
        .code = "luce.parse.self",
        .line = 2,
        .column = 12,
        .contains = teaching,
    }});

    try expectDiagnostics(
        \\struct Point:
        \\    func f(a: long, self):
        \\        return
        \\
    , &.{.{
        .code = "luce.parse.self",
        .line = 2,
        .column = 21,
        .contains = teaching,
    }});

    try expectDiagnostics(
        \\enum Method:
        \\    stored
        \\    static func f(self: Method):
        \\        return
        \\
    , &.{.{
        .code = "luce.parse.self",
        .line = 3,
        .column = 19,
        .contains = teaching,
    }});

    try expectDiagnostics(
        \\func adjust(var value: long):
        \\    return
        \\
    , &.{.{
        .code = "luce.parse.self",
        .line = 1,
        .column = 13,
        .contains = "parameters are values and never var",
    }});
}

test "static is member-only, ordered, and recovers at the next declaration" {
    try expectDiagnostics(
        "static func helper():\n    return\n\nfunc main():\n    return\n",
        &.{.{
            .code = "luce.parse.static",
            .line = 1,
            .column = 1,
            .contains = "inside a struct or enum",
        }},
    );
    try expectDiagnostics(
        "private static func helper():\n    return\n",
        &.{.{
            .code = "luce.parse.static",
            .line = 1,
            .column = 9,
            .contains = "file-scope function is already a namespace function",
        }},
    );
    try expectDiagnostics(
        "struct Tools:\n    static value: long\n",
        &.{.{
            .code = "luce.parse.static",
            .line = 2,
            .column = 5,
            .contains = "static func name",
        }},
    );
    try expectDiagnostics(
        "struct Tools:\n    static private func hidden():\n        return\n",
        &.{.{
            .code = "luce.parse.static",
            .line = 2,
            .column = 12,
            .contains = "visibility comes before static",
        }},
    );
    try expectDiagnostics(
        "struct Tools:\n    static static func hidden():\n        return\n",
        &.{.{
            .code = "luce.parse.static",
            .line = 2,
            .column = 12,
            .contains = "write static once",
        }},
    );
    try expectDiagnostics(
        "func main():\n    static func local():\n        return\n",
        &.{.{
            .code = "luce.parse.static",
            .line = 2,
            .column = 5,
            .contains = "not inside a function body",
        }},
    );

    var recovered = try parseText(
        "struct Tools:\n    static value: long\n    static func okay():\n        return\n\nfunc main():\n    return\n",
    );
    defer recovered.deinit();
    try testing.expectEqual(@as(usize, 1), recovered.diagnostics.count());
    try testing.expectEqual(@as(usize, 1), recovered.program.structs[0].functions.len);
    try testing.expectEqualStrings("okay", recovered.program.structs[0].functions[0].name);
    try testing.expect(recovered.program.structs[0].functions[0].is_static);
    try testing.expectEqualStrings("main", recovered.program.functions[0].name);

    var redundant = try parseText(
        "struct Tools:\n    private:\n        public static func shown():\n            return\n",
    );
    defer redundant.deinit();
    try testing.expectEqual(@as(usize, 1), redundant.diagnostics.count());
    try testing.expectEqualStrings("luce.parse.expected", redundant.diagnostics.at(0).?.code);
    try testing.expectEqual(@as(usize, 1), redundant.program.structs[0].functions.len);
    try testing.expect(redundant.program.structs[0].functions[0].is_static);
    try testing.expectEqual(ast.Visibility.private, redundant.program.structs[0].functions[0].visibility);

    var enum_recovered = try parseText(
        "enum Method:\n    stored\n    static value\n    static func okay() -> Method:\n        return Method.stored\n\nfunc main():\n    return\n",
    );
    defer enum_recovered.deinit();
    try testing.expectEqual(@as(usize, 1), enum_recovered.diagnostics.count());
    try testing.expectEqualStrings("luce.parse.static", enum_recovered.diagnostics.at(0).?.code);
    try testing.expectEqual(@as(usize, 1), enum_recovered.program.enums[0].functions.len);
    try testing.expectEqualStrings("okay", enum_recovered.program.enums[0].functions[0].name);
    try testing.expect(enum_recovered.program.enums[0].functions[0].is_static);
    try testing.expectEqualStrings("main", enum_recovered.program.functions[0].name);
}

test "self is a keyword, so nothing else may be called one" {
    // The word is reserved for the implied receiver in a method body;
    // no declaration or binding can give it another meaning.  That is
    // what makes `p.length()` readable as a call on `p` and nothing else.
    try expectDiagnostics(
        \\func main():
        \\    let self = 3
        \\
    , &.{.{ .code = "luce.parse.expected", .line = 2, .column = 9 }});
}

test "every token kind has a name a diagnostic can print" {
    // describe() is exhaustive by construction (no else arm), so this
    // guards the other half: that no name is empty, and that keyword
    // names agree with the lexer's own table.
    for (std.enums.values(@import("../02_lex.zig").Kind)) |kind| {
        try testing.expect(grammar.describe(kind).len != 0);
        if (grammar.keywordWord(kind)) |word| {
            try testing.expect(std.mem.indexOf(u8, grammar.describe(kind), word) != null);
        }
    }
}

// ---------------------------------------------------------------------------
// Enums and match (docs/ENUMS.md)
// ---------------------------------------------------------------------------

test "an enum declares members, a width, and the functions a struct declares" {
    var parsed = try expectClean(
        \\enum Method(byte):
        \\    stored
        \\    deflated = 8
        \\
        \\    func compressed() -> bool:
        \\        return self != Method.stored
        \\
        \\func main():
        \\    return
        \\
    );
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 1), parsed.program.enums.len);
    const declared = parsed.program.enums[0];
    try testing.expectEqualStrings("Method", declared.name);
    try testing.expectEqualStrings("byte", declared.backing.?.name);
    try testing.expectEqual(@as(usize, 2), declared.members.len);
    try testing.expectEqualStrings("stored", declared.members[0].name);
    try testing.expect(declared.members[0].value == null);
    try testing.expectEqualStrings("deflated", declared.members[1].name);
    try testing.expect(declared.members[1].value != null);
    try testing.expectEqual(@as(usize, 1), declared.functions.len);
    try testing.expectEqualStrings("compressed", declared.functions[0].name);
}

test "an enum takes a visibility marker, and its members do not" {
    var parsed = try expectClean(
        \\private enum Method:
        \\    stored
        \\
        \\func main():
        \\    return
        \\
    );
    defer parsed.deinit();
    try testing.expectEqual(ast.Visibility.private, parsed.program.enums[0].visibility);

    // A member is what the type *is*, and a match arm cannot name one
    // the file it stands in cannot see.
    try expectDiagnostics(
        \\enum Method:
        \\    private stored
        \\
        \\func main():
        \\    return
        \\
    , &.{.{
        .code = "luce.parse.expected",
        .line = 2,
        .column = 5,
        .contains = "an enum member is part of the type and is always visible",
    }});
    try expectDiagnostics(
        \\enum Method:
        \\    private:
        \\        stored
        \\
        \\func main():
        \\    return
        \\
    , &.{.{
        .code = "luce.parse.expected",
        .line = 2,
        .column = 5,
        .contains = "an enum's members are the type and are always visible",
    }});
}

test "a member takes a value, not a type" {
    try expectDiagnostics(
        \\enum Method:
        \\    stored: long
        \\
        \\func main():
        \\    return
        \\
    , &.{.{
        .code = "luce.parse.expected",
        .line = 2,
        .column = 11,
        .contains = "an enum member takes a value, not a type",
    }});
}

test "a union declares members, field lists, and the functions a struct declares" {
    var parsed = try expectClean(
        \\union Shape:
        \\    empty
        \\    circle(radius: double)
        \\    rect(width: double, height: double = 1.0)
        \\
        \\    func wide() -> bool:
        \\        return true
        \\
        \\    static func unit() -> Shape:
        \\        return Shape.circle(radius = 1.0)
        \\
        \\func main():
        \\    return
        \\
    );
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 1), parsed.program.unions.len);
    const declared = parsed.program.unions[0];
    try testing.expectEqualStrings("Shape", declared.name);
    try testing.expectEqual(@as(usize, 3), declared.members.len);
    try testing.expectEqualStrings("empty", declared.members[0].name);
    try testing.expectEqual(@as(usize, 0), declared.members[0].fields.len);
    try testing.expectEqualStrings("circle", declared.members[1].name);
    try testing.expectEqual(@as(usize, 1), declared.members[1].fields.len);
    try testing.expectEqualStrings("radius", declared.members[1].fields[0].name);
    try testing.expectEqualStrings("double", declared.members[1].fields[0].type_name.name);
    try testing.expect(declared.members[1].fields[0].default == null);
    try testing.expectEqual(@as(usize, 2), declared.members[2].fields.len);
    try testing.expect(declared.members[2].fields[1].default != null);
    try testing.expectEqual(@as(usize, 2), declared.functions.len);
    try testing.expectEqualStrings("wide", declared.functions[0].name);
    try testing.expect(!declared.functions[0].is_static);
    try testing.expect(declared.functions[1].is_static);
}

test "a union takes a visibility marker, and its members do not" {
    var parsed = try expectClean(
        \\private union Shape:
        \\    circle(radius: double)
        \\
        \\func main():
        \\    return
        \\
    );
    defer parsed.deinit();
    try testing.expectEqual(ast.Visibility.private, parsed.program.unions[0].visibility);

    // A member is what the type *is*, and a match arm cannot name one
    // the file it stands in cannot see.
    try expectDiagnostics(
        \\union Shape:
        \\    private circle(radius: double)
        \\
        \\func main():
        \\    return
        \\
    , &.{.{
        .code = "luce.parse.expected",
        .line = 2,
        .column = 5,
        .contains = "a union member is part of the type and is always visible",
    }});
    try expectDiagnostics(
        \\union Shape:
        \\    private:
        \\        circle(radius: double)
        \\
        \\func main():
        \\    return
        \\
    , &.{.{
        .code = "luce.parse.expected",
        .line = 2,
        .column = 5,
        .contains = "a union's members are the type and are always visible",
    }});
}

test "a union member's payload fields are named, always" {
    // `circle(double)` is a tuple with a name in front of it
    // (docs/UNION.md D1, docs/RETURNS.md).
    try expectDiagnostics(
        \\union Shape:
        \\    circle(double)
        \\
        \\func main():
        \\    return
        \\
    , &.{.{
        .code = "luce.parse.expected",
        .line = 2,
        .column = 12,
        .contains = "a payload field is named, always: write circle(name: double)",
    }});
    // The struct field's colon, in the one body that parenthesizes.
    try expectDiagnostics(
        \\union Shape:
        \\    circle: double
        \\
        \\func main():
        \\    return
        \\
    , &.{.{
        .code = "luce.parse.expected",
        .line = 2,
        .column = 11,
        .contains = "a union member's payload is parenthesized",
    }});
    // The enum habit: a member is not a number (D1).
    try expectDiagnostics(
        \\union Shape:
        \\    circle = 1
        \\
        \\func main():
        \\    return
        \\
    , &.{.{
        .code = "luce.parse.expected",
        .line = 2,
        .column = 12,
        .contains = "a union member holds no number",
    }});
    // Parentheses mean a payload (D4), so empty ones mean nothing.
    try expectDiagnostics(
        \\union Shape:
        \\    circle()
        \\
        \\func main():
        \\    return
        \\
    , &.{.{
        .code = "luce.parse.expected",
        .line = 2,
        .column = 11,
        .contains = "parentheses mean a payload",
    }});
    // Zig's tag reuse is not taken in this run (docs/UNION.md R2).
    try expectDiagnostics(
        \\union Shape(Kind):
        \\    circle(radius: double)
        \\
        \\func main():
        \\    return
        \\
    , &.{.{
        .code = "luce.parse.expected",
        .line = 1,
        .column = 12,
        .contains = "a union names no discriminant",
    }});
}

test "a match arm binds payload fields by name alone" {
    var parsed = try expectClean(
        \\union Shape:
        \\    empty
        \\    rect(width: double, height: double)
        \\
        \\func main():
        \\    let s = Shape.empty
        \\    match s:
        \\        empty:
        \\            print("e")
        \\        rect(width, height):
        \\            print(string(width + height))
        \\
    );
    defer parsed.deinit();
    const body = parsed.program.functions[0].body;
    const matched = body.statements[body.statements.len - 1].match;
    try testing.expectEqual(@as(usize, 2), matched.arms.len);
    try testing.expectEqual(@as(usize, 0), matched.arms[0].bindings.len);
    try testing.expectEqual(@as(usize, 2), matched.arms[1].bindings.len);
    try testing.expectEqualStrings("width", matched.arms[1].bindings[0].text);
    try testing.expectEqualStrings("height", matched.arms[1].bindings[1].text);

    // An arm's parentheses bind at least one field, or are not written.
    try expectDiagnostics(
        \\func main():
        \\    match s:
        \\        circle():
        \\            return
        \\
    , &.{.{
        .code = "luce.parse.expected",
        .line = 3,
        .column = 15,
        .contains = "parentheses bind payload fields",
    }});
    // The declaration's field list where the binding list belongs.
    try expectDiagnostics(
        \\func main():
        \\    match s:
        \\        circle(radius: double):
        \\            return
        \\
    , &.{.{
        .code = "luce.parse.expected",
        .line = 3,
        .column = 22,
        .contains = "an arm binds fields by name alone: write circle(radius)",
    }});
}

test "union declares at file scope" {
    try expectDiagnostics(
        \\func main():
        \\    union Shape:
        \\        circle(radius: double)
        \\
    , &.{.{
        .code = "luce.parse.expected",
        .line = 2,
        .column = 5,
        .contains = "'union' declarations belong at file scope",
    }});
}

test "match parses arms, an else, and the two shapes a reader arrives with" {
    var parsed = try expectClean(
        \\enum Colour:
        \\    red
        \\    green
        \\
        \\func main():
        \\    let c = Colour.red
        \\    match c:
        \\        red:
        \\            print("red")
        \\        else:
        \\            print("other")
        \\
    );
    defer parsed.deinit();
    const body = parsed.program.functions[0].body;
    const matched = body.statements[body.statements.len - 1].match;
    try testing.expectEqual(@as(usize, 1), matched.arms.len);
    try testing.expectEqualStrings("red", matched.arms[0].name);
    try testing.expect(matched.else_block != null);

    // `case stored:` — Python's second keyword, carrying nothing the
    // colon does not (docs/ENUMS.md Q3).
    try expectDiagnostics(
        \\func main():
        \\    match c:
        \\        case red:
        \\            return
        \\
    , &.{.{
        .code = "luce.parse.expected",
        .line = 3,
        .column = 9,
        .contains = "a match arm is a bare member name: write 'red:'",
    }});
    // And the qualified form, which says every line what the scrutinee
    // already said once (R3).
    try expectDiagnostics(
        \\func main():
        \\    match c:
        \\        Colour.red:
        \\            return
        \\
    , &.{.{
        .code = "luce.parse.expected",
        .line = 3,
        .column = 9,
        .contains = "write 'red:', not 'Colour.red:'",
    }});
}

test "else is the last arm of a match, and there is one of it" {
    try expectDiagnostics(
        \\func main():
        \\    match c:
        \\        else:
        \\            return
        \\        red:
        \\            return
        \\
    , &.{.{
        .code = "luce.parse.expected",
        .line = 5,
        .column = 9,
        .contains = "else catches everything the arms above it did not",
    }});
    try expectDiagnostics(
        \\func main():
        \\    match c:
        \\        else:
        \\            return
        \\        else:
        \\            return
        \\
    , &.{.{
        .code = "luce.parse.expected",
        .line = 5,
        .column = 9,
        .contains = "one else per match",
    }});
}

test "enum declares at file scope, and match is a statement" {
    try expectDiagnostics(
        \\func main():
        \\    enum Method:
        \\        stored
        \\
    , &.{.{
        .code = "luce.parse.expected",
        .line = 2,
        .column = 5,
        .contains = "'enum' declarations belong at file scope",
    }});
    // The habit from every other language, answered with the word Luce
    // uses now that it has one.
    try expectDiagnostics(
        \\func main():
        \\    switch c:
        \\        return
        \\
    , &.{.{
        .code = "luce.parse.expected",
        .line = 2,
        .column = 5,
        .contains = "write 'match' over an enum",
    }});
}

test "a call is a postfix suffix, on the same footing as an index" {
    // The grammar half of docs/FUNCTIONS.md's *As built — the call
    // suffix*: `EXPR(args)` parses wherever `EXPR[i]` does.  The two
    // forms whose head names a declaration keep their own nodes,
    // because only their written text can resolve one.
    var parsed = try expectClean(
        \\func main():
        \\    print(chooser()(5))
        \\    print(actions["double"](21))
        \\    print(rows.render(3))
        \\    print(pick()()(7))
        \\
    );
    defer parsed.deinit();
    const body = parsed.program.functions[0].body.statements;

    // `chooser()(5)` — a call suffix whose callee is a named call.
    const first = body[0].expression.value.call.arguments[0].value;
    try testing.expect(first.* == .value_call);
    try testing.expect(first.value_call.callee.* == .call);
    try testing.expectEqualStrings("chooser", first.value_call.callee.call.callee);
    try testing.expectEqual(@as(usize, 1), first.value_call.arguments.len);

    // `actions["double"](21)` — a call suffix on an index.
    const second = body[1].expression.value.call.arguments[0].value;
    try testing.expect(second.* == .value_call);
    try testing.expect(second.value_call.callee.* == .index);

    // `rows.render(3)` is still a *method*: the dot takes it before
    // the suffix can, which is what keeps every declaration form
    // resolving through the name the reader wrote.
    const third = body[2].expression.value.call.arguments[0].value;
    try testing.expect(third.* == .method);
    try testing.expectEqualStrings("render", third.method.name);

    // The suffix chains, left to right.
    const fourth = body[3].expression.value.call.arguments[0].value;
    try testing.expect(fourth.* == .value_call);
    try testing.expect(fourth.value_call.callee.* == .value_call);
    try testing.expect(fourth.value_call.callee.value_call.callee.* == .call);
}

test "a call suffix does not cross a line break" {
    // The suffix ends at a newline exactly as an index chain does, and
    // for the same reason: the lexer suspends newlines only inside an
    // open group, so `f` on one line and `(4)` on the next stay two
    // statements and keep meaning what they meant.
    var parsed = try expectClean(
        \\func main():
        \\    let f = pick()
        \\    f
        \\    (4)
        \\
    );
    defer parsed.deinit();
    const body = parsed.program.functions[0].body.statements;
    try testing.expectEqual(@as(usize, 3), body.len);
    try testing.expect(body[1].expression.value.* == .name);
    try testing.expect(body[2].expression.value.* == .int_literal);
}
