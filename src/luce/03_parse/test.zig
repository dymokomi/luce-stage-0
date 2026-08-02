//! Parser tests — coverage for declarations, statements, and expressions.

const std = @import("std");
const parser_mod = @import("../03_parse.zig");
const ast = @import("ast.zig");
const diagnostics_mod = @import("../support/diagnostics.zig");

const testing = std.testing;
const Diagnostics = diagnostics_mod.Diagnostics;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    diagnostics: Diagnostics,
    program: ast.Program,

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
    return .{ .arena = arena, .diagnostics = diagnostics, .program = program };
}

test "the plan's scale example parses" {
    var parsed = try parseText(
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
        \\func evaluate(input: Input, output: Output):
        \\    let position = input.position
        \\    let factor = input.scale
        \\    output.position = scale_point(position, factor)
        \\
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diagnostics.count());
    try testing.expectEqual(@as(usize, 1), parsed.program.structs.len);
    try testing.expectEqual(@as(usize, 2), parsed.program.functions.len);
    try testing.expectEqualStrings("Point", parsed.program.structs[0].name);
    try testing.expectEqual(@as(usize, 2), parsed.program.structs[0].fields.len);
    try testing.expectEqualStrings("scale_point", parsed.program.functions[0].name);
    try testing.expectEqual(@as(usize, 2), parsed.program.functions[0].parameters.len);
    try testing.expect(parsed.program.functions[0].return_type != null);

    // evaluate's third statement is an output.position assignment.
    const evaluate = parsed.program.functions[1];
    try testing.expectEqual(@as(usize, 3), evaluate.body.statements.len);
    const assign = evaluate.body.statements[2].assign;
    try testing.expectEqualStrings("output", assign.target.field.base);
    try testing.expectEqualStrings("position", assign.target.field.field);
}

test "collections parse: types, new, literals, indexing, slices, for-in" {
    var parsed = try parseText(
        \\func main():
        \\    var xs: List(Int) = [1, 2, 3]
        \\    var m = new Map(String, List(Int))
        \\    var grid = new Array(Float, 4, 8)
        \\    var b = new Builder()
        \\    xs[0] = 10
        \\    grid[1, 2] = 3.5
        \\    m["ones"] = xs
        \\    let mid = xs[1:2]
        \\    let head = xs[:1]
        \\    let tail = xs[1:]
        \\    for x in xs:
        \\        append(b, str(x))
        \\
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diagnostics.count());
    const body = parsed.program.functions[0].body;

    const annotated = body.statements[0].variable;
    try testing.expectEqualStrings("List", annotated.annotation.?.name);
    try testing.expectEqualStrings("Int", annotated.annotation.?.arguments[0].name);
    try testing.expectEqual(@as(usize, 3), annotated.value.?.list_literal.elements.len);

    const map_new = body.statements[1].variable.value.?.new_object;
    try testing.expectEqualStrings("Map", map_new.type_name.name);
    try testing.expectEqualStrings("List", map_new.type_name.arguments[1].name);

    const array_new = body.statements[2].variable.value.?.new_object;
    try testing.expectEqualStrings("Array", array_new.type_name.name);
    try testing.expectEqual(@as(usize, 2), array_new.dims.len);

    try testing.expectEqual(@as(usize, 1), body.statements[4].assign.target.index.indices.len);
    try testing.expectEqual(@as(usize, 2), body.statements[5].assign.target.index.indices.len);
    try testing.expect(body.statements[7].let.value.* == .slice_range);
    try testing.expect(body.statements[8].let.value.slice_range.start == null);
    try testing.expect(body.statements[9].let.value.slice_range.end == null);
    try testing.expectEqualStrings("x", body.statements[10].for_each.name);
}

test "late declarations parse: var with annotation only" {
    var parsed = try parseText(
        \\func main():
        \\    var report: Builder
        \\    var grid: Array(Int, _, _)
        \\    var count: Int
        \\    report = new Builder()
        \\
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diagnostics.count());
    const body = parsed.program.functions[0].body;
    try testing.expect(body.statements[0].variable.value == null);
    try testing.expectEqualStrings("Builder", body.statements[0].variable.annotation.?.name);
    try testing.expect(body.statements[1].variable.value == null);
    try testing.expect(body.statements[2].variable.value == null);

    // let never late-declares, and var needs a type or a value.
    var bad_let = try parseText(
        \\func main():
        \\    let frozen: Int
        \\
    );
    defer bad_let.deinit();
    try testing.expect(bad_let.diagnostics.count() > 0);
    var bad_var = try parseText(
        \\func main():
        \\    var untyped
        \\
    );
    defer bad_var.deinit();
    try testing.expect(bad_var.diagnostics.count() > 0);
}

test "array shape wildcards parse in annotations" {
    var parsed = try parseText(
        \\func total(grid: Array(Int, _, _)) -> Int:
        \\    return dim(grid, 0)
        \\
        \\func main():
        \\    return
        \\
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diagnostics.count());
    const parameter = parsed.program.functions[0].parameters[0];
    try testing.expectEqualStrings("Array", parameter.type_name.name);
    try testing.expectEqual(@as(u8, 2), parameter.type_name.wildcards);
}

test "struct bodies parse fields and namespaced functions" {
    var parsed = try parseText(
        \\struct Helpers:
        \\    value: Int
        \\    func double(value: Int) -> Int:
        \\        return value * 2
        \\
        \\func evaluate(input: Input, output: Output):
        \\    output.value = Helpers.double(input.value)
        \\
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diagnostics.count());
    try testing.expectEqual(@as(usize, 1), parsed.program.structs[0].fields.len);
    try testing.expectEqual(@as(usize, 1), parsed.program.structs[0].functions.len);
    // Dotted calls parse as method nodes; the analyzer decides whether
    // the chain names a namespace or a value.
    const dotted = parsed.program.functions[0].body.statements[0].assign.value.method;
    try testing.expectEqualStrings("double", dotted.name);
    try testing.expectEqualStrings("Helpers", dotted.target.name.text);
}

test "method calls parse on any postfix expression" {
    var parsed = try parseText(
        \\func main():
        \\    var xs = [3, 1]
        \\    xs.append(2)
        \\    xs.sort()
        \\    let n = xs[0:2].find(3)
        \\    let word = "Hello".lower()
        \\
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diagnostics.count());
    const body = parsed.program.functions[0].body;
    const call = body.statements[1].expression.value.method;
    try testing.expectEqualStrings("append", call.name);
    try testing.expect(body.statements[3].let.value.method.target.* == .slice_range);
    try testing.expect(body.statements[4].let.value.method.target.* == .string_literal);
}

test "deeply nested expressions report instead of overflowing the stack" {
    const allocator = testing.allocator;
    var opens: std.ArrayList(u8) = .empty;
    defer opens.deinit(allocator);
    try opens.appendSlice(allocator, "func main():\n    let x = ");
    for (0..5000) |_| try opens.append(allocator, '(');
    try opens.append(allocator, '1');
    for (0..5000) |_| try opens.append(allocator, ')');
    try opens.append(allocator, '\n');

    var parsed = try parseText(opens.items);
    defer parsed.deinit();
    // The point is that this returns at all (no crash); it must also
    // have reported the nesting limit.
    var saw_nesting = false;
    for (0..parsed.diagnostics.count()) |index| {
        if (std.mem.eql(u8, parsed.diagnostics.at(index).?.code, "luce.parse.nesting")) saw_nesting = true;
    }
    try testing.expect(saw_nesting);
}

test "fuzz: parsing any bytes terminates with spans inside the source" {
    try testing.fuzz({}, parseAnything, .{ .corpus = &.{
        "func main():\n    let x = 1 + 2\n",
        "func f(a: give List(Int)) -> Int:\n    return len(a)\n",
        "struct P:\n    x: Float\n",
        "let k = 3\n",
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
        .value(u8, ':', 2),
    });
    const source = buffer[0..length];

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

test "ownership verbs parse: give/copy expressions and give parameters" {
    var parsed = try parseText(
        \\func stash(index: Map(String, List(Int)), hits: give List(Int)):
        \\    index["latest"] = give hits
        \\
        \\func main():
        \\    var mine = [1, 2]
        \\    let moved = give mine
        \\    let doubled = copy moved
        \\    var index = new Map(String, List(Int))
        \\    stash(index, give doubled)
        \\
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diagnostics.count());

    const stash = parsed.program.functions[0];
    try testing.expectEqual(ast.ParameterMode.borrow, stash.parameters[0].mode);
    try testing.expectEqual(ast.ParameterMode.give, stash.parameters[1].mode);
    try testing.expect(stash.body.statements[0].assign.value.* == .give);

    const body = parsed.program.functions[1].body;
    const moved = body.statements[1].let.value;
    try testing.expect(moved.* == .give);
    try testing.expectEqualStrings("mine", moved.give.operand.name.text);
    try testing.expect(body.statements[2].let.value.* == .copy);
    const call_arguments = body.statements[4].expression.value.call.arguments;
    try testing.expect(call_arguments[1].value.* == .give);
}

test "top-level let constants parse; top-level var is refused" {
    var parsed = try parseText(
        \\let width = 80
        \\let banner: String = "loom " + version
        \\let version = "2.0"
        \\
        \\func main():
        \\    let unused = width
        \\
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diagnostics.count());
    try testing.expectEqual(@as(usize, 3), parsed.program.constants.len);
    try testing.expectEqualStrings("width", parsed.program.constants[0].name);
    try testing.expect(parsed.program.constants[0].annotation == null);
    try testing.expectEqualStrings("String", parsed.program.constants[1].annotation.?.name);
    try testing.expect(parsed.program.constants[1].value.* == .binary);

    var refused = try parseText(
        \\var counter = 0
        \\
        \\func main():
        \\    return
        \\
    );
    defer refused.deinit();
    try testing.expect(refused.diagnostics.count() > 0);
    try testing.expectEqualStrings("luce.parse.top", refused.diagnostics.at(0).?.code);
}

test "control flow, precedence, and elif chains parse" {
    var parsed = try parseText(
        \\func evaluate(input: Input, output: Output):
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
    try testing.expectEqual(@as(usize, 0), parsed.diagnostics.count());
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
}

test "malformed statements recover and keep reporting" {
    var parsed = try parseText(
        \\func evaluate(input: Input, output: Output):
        \\    let = 3
        \\    let ok = 1
        \\    output.value = ok +
        \\
        \\func helper() -> Int:
        \\    return 2
        \\
    );
    defer parsed.deinit();
    try testing.expect(parsed.diagnostics.count() >= 2);
    // Recovery still sees both functions.
    try testing.expectEqual(@as(usize, 2), parsed.program.functions.len);
}

test "strings decode escapes" {
    var parsed = try parseText(
        \\func evaluate(input: Input, output: Output):
        \\    output.text = "line\none\ttab \"quoted\""
        \\
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diagnostics.count());
    const value = parsed.program.functions[0].body.statements[0].assign.value;
    try testing.expectEqualStrings("line\none\ttab \"quoted\"", value.string_literal.decoded);
}
