//! The Luce compile pipeline: source bytes plus a Port schema in,
//! a verified program or structured diagnostics out.
//!
//! The compiler accepts a byte slice, never a path; diagnostics carry
//! spans into that buffer.  Every successful compile passes the IR
//! verifier before it is returned.

const std = @import("std");
const parser_mod = @import("parser.zig");
const analyzer_mod = @import("analyzer.zig");
const types = @import("types.zig");
const ir = @import("ir.zig");
const diagnostics_mod = @import("diagnostics.zig");

const Allocator = std.mem.Allocator;
const PortSchema = types.PortSchema;
const Diagnostics = diagnostics_mod.Diagnostics;

pub const Error = error{OutOfMemory};

pub const CompileResult = union(enum) {
    /// A verified program; caller owns it (deinit).
    success: ir.Program,
    /// Compile problems; caller owns them (deinit).  The source
    /// revision stays authoritative — there is no runnable blob.
    failure: Diagnostics,

    pub fn deinit(self: *CompileResult) void {
        switch (self.*) {
            .success => |*program| program.deinit(),
            .failure => |*diagnostics| diagnostics.deinit(),
        }
        self.* = undefined;
    }
};

pub fn compile(
    gpa: Allocator,
    source: []const u8,
    schema: PortSchema,
    options: types.CompileOptions,
) Error!CompileResult {
    var diagnostics = Diagnostics.init(gpa);
    errdefer diagnostics.deinit();

    var program: ir.Program = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer program.deinit();
    const arena = program.arena.allocator();

    // The AST is scaffolding: it lives in its own arena and frees as
    // soon as analysis is done with it.
    var ast_arena = std.heap.ArenaAllocator.init(gpa);
    defer ast_arena.deinit();

    const tree = try parser_mod.parse(ast_arena.allocator(), gpa, source, &diagnostics);
    if (diagnostics.hasErrors()) {
        program.deinit();
        return .{ .failure = diagnostics };
    }

    const analyzed = (try analyzer_mod.analyze(arena, gpa, &tree, schema, options, &diagnostics)) orelse {
        program.deinit();
        return .{ .failure = diagnostics };
    };

    program.structs = analyzed.structs;
    program.functions = analyzed.functions;
    program.constants = analyzed.constants;
    program.reads = analyzed.reads;
    program.evaluate_function = analyzed.evaluate_function;
    program.inputs = try copyPorts(arena, schema.inputs);
    program.outputs = try copyPorts(arena, schema.outputs);

    // The verifier is a compiler invariant, not a user diagnostic: a
    // verification failure here is a compiler bug surfaced loudly.
    ir.verify(gpa, &program) catch |mistake| switch (mistake) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try diagnostics.add(
                "luce.compiler.verify",
                .{ .start = 0, .end = 0 },
                "internal compiler error: generated IR failed verification ({s})",
                .{@errorName(mistake)},
            );
            program.deinit();
            return .{ .failure = diagnostics };
        },
    };

    diagnostics.deinit();
    return .{ .success = program };
}

fn copyPorts(arena: Allocator, ports: []const types.Port) Error![]types.Port {
    const copied = try arena.alloc(types.Port, ports.len);
    for (ports, copied) |port, *slot| {
        slot.* = .{ .name = try arena.dupe(u8, port.name), .declared = port.declared };
    }
    return copied;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const point_schema: PortSchema = .{
    .inputs = &.{
        .{ .name = "x", .declared = .float },
        .{ .name = "y", .declared = .float },
        .{ .name = "scale", .declared = .float },
    },
    .outputs = &.{
        .{ .name = "x", .declared = .float },
        .{ .name = "y", .declared = .float },
    },
};

fn expectCompiles(source: []const u8, schema: PortSchema) !ir.Program {
    var result = try compile(testing.allocator, source, schema, .{});
    switch (result) {
        .success => |program| return program,
        .failure => |*diagnostics| {
            const rendered = try diagnostics.render(testing.allocator, source);
            defer testing.allocator.free(rendered);
            std.debug.print("unexpected diagnostics:\n{s}", .{rendered});
            result.deinit();
            return error.TestUnexpectedResult;
        },
    }
}

fn expectFails(source: []const u8, schema: PortSchema, expected_code: []const u8) !void {
    var result = try compile(testing.allocator, source, schema, .{});
    defer result.deinit();
    switch (result) {
        .success => return error.TestUnexpectedResult,
        .failure => |diagnostics| {
            for (0..diagnostics.count()) |index| {
                if (std.mem.eql(u8, diagnostics.at(index).?.code, expected_code)) return;
            }
            const rendered = try diagnostics.render(testing.allocator, source);
            defer testing.allocator.free(rendered);
            std.debug.print("wanted {s}, got:\n{s}", .{ expected_code, rendered });
            return error.TestUnexpectedResult;
        },
    }
}

test "the plan's scale example compiles and verifies" {
    var program = try expectCompiles(
        \\struct Point:
        \\    x: Float
        \\    y: Float
        \\
        \\fn scale_point(point: Point, factor: Float) -> Point:
        \\    return Point(
        \\        x = point.x * factor,
        \\        y = point.y * factor,
        \\    )
        \\
        \\fn evaluate():
        \\    let position = Point(x = input.x, y = input.y)
        \\    let scaled = scale_point(position, input.scale)
        \\    output.x = scaled.x
        \\    output.y = scaled.y
        \\
    , point_schema);
    defer program.deinit();

    try testing.expectEqual(@as(usize, 1), program.structs.len);
    try testing.expectEqual(@as(usize, 2), program.functions.len);
    // The program reads all three declared inputs.
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, program.reads);
}

test "control flow, loops, and builtins compile and verify" {
    var program = try expectCompiles(
        \\fn evaluate():
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
        \\    output.total = clamp(total, 0, 50)
        \\
    , .{ .outputs = &.{.{ .name = "total", .declared = .int }} });
    defer program.deinit();
    try testing.expectEqual(@as(usize, 0), program.reads.len);
}

test "the IR dump is readable and deterministic" {
    const source =
        \\fn evaluate():
        \\    let doubled = input.value * 2
        \\    output.value = doubled
        \\
    ;
    const schema: PortSchema = .{
        .inputs = &.{.{ .name = "value", .declared = .int }},
        .outputs = &.{.{ .name = "value", .declared = .int }},
    };
    var program = try expectCompiles(source, schema);
    defer program.deinit();
    const first = try ir.print(testing.allocator, &program);
    defer testing.allocator.free(first);

    var again = try expectCompiles(source, schema);
    defer again.deinit();
    const second = try ir.print(testing.allocator, &again);
    defer testing.allocator.free(second);

    try testing.expectEqualStrings(first, second);
    try testing.expect(std.mem.indexOf(u8, first, "fn evaluate() -> None") != null);
    try testing.expect(std.mem.indexOf(u8, first, "input_load value") != null);
    try testing.expect(std.mem.indexOf(u8, first, "output_store value") != null);
    try testing.expect(std.mem.indexOf(u8, first, "multiply.Int") != null);
}

test "unknown ports and port type mismatches diagnose" {
    try expectFails(
        \\fn evaluate():
        \\    output.ghost = 1
        \\
    , point_schema, "luce.sema.port");
    try expectFails(
        \\fn evaluate():
        \\    let missing = input.ghost
        \\
    , point_schema, "luce.sema.port");
    try expectFails(
        \\fn evaluate():
        \\    output.x = 1
        \\
    , point_schema, "luce.sema.type");
    try expectFails(
        \\fn evaluate():
        \\    input.x = 1.0
        \\
    , point_schema, "luce.sema.input");
    try expectFails(
        \\fn evaluate():
        \\    let peek = output.x
        \\
    , point_schema, "luce.sema.output");
}

test "no implicit conversion, no reassigned let, no shadowing" {
    try expectFails(
        \\fn evaluate():
        \\    let mixed = 1 + 2.0
        \\
    , .{}, "luce.sema.type");
    try expectFails(
        \\fn evaluate():
        \\    let once = 1
        \\    once = 2
        \\
    , .{}, "luce.sema.let");
    try expectFails(
        \\fn evaluate():
        \\    let name = 1
        \\    if true:
        \\        let name = 2
        \\
    , .{}, "luce.sema.duplicate");
    try expectFails(
        \\fn evaluate():
        \\    let value: Float = 3
        \\
    , .{}, "luce.sema.type");
}

test "return paths and evaluate's shape are checked" {
    try expectFails(
        \\fn partial(flag: Bool) -> Int:
        \\    if flag:
        \\        return 1
        \\
        \\fn evaluate():
        \\    let unused = partial(true)
        \\
    , .{}, "luce.sema.return");
    try expectFails(
        \\fn helper() -> Int:
        \\    return 1
        \\
    , .{}, "luce.sema.evaluate");
    try expectFails(
        \\fn evaluate() -> Int:
        \\    return 1
        \\
    , .{}, "luce.sema.evaluate");
}

test "struct construction is complete, named, and typed" {
    const source_prefix =
        \\struct Color:
        \\    red: Float
        \\    green: Float
        \\
    ;
    try expectFails(source_prefix ++
        \\fn evaluate():
        \\    let missing = Color(red = 1.0)
        \\
    , .{}, "luce.sema.construct");
    try expectFails(source_prefix ++
        \\fn evaluate():
        \\    let doubled = Color(red = 1.0, red = 2.0, green = 3.0)
        \\
    , .{}, "luce.sema.construct");
    try expectFails(source_prefix ++
        \\fn evaluate():
        \\    let wrong = Color(red = 1, green = 2.0)
        \\
    , .{}, "luce.sema.type");
    try expectFails(
        \\struct Loop:
        \\    inner: Loop
        \\
        \\fn evaluate():
        \\    let never = 1
        \\
    , .{}, "luce.sema.struct");
}

test "calls check arity, types, and none results" {
    try expectFails(
        \\fn helper(value: Int) -> Int:
        \\    return value
        \\
        \\fn evaluate():
        \\    let wrong = helper(1, 2)
        \\
    , .{}, "luce.sema.call");
    try expectFails(
        \\fn nothing():
        \\    return
        \\
        \\fn evaluate():
        \\    let value = nothing()
        \\
    , .{}, "luce.sema.call");
    try expectFails(
        \\fn evaluate():
        \\    let bad = sqrt(4)
        \\
    , .{}, "luce.sema.type");
    try expectFails(
        \\fn evaluate():
        \\    let bad = unknown_helper(1)
        \\
    , .{}, "luce.sema.call");
}

test "break and continue require a loop" {
    try expectFails(
        \\fn evaluate():
        \\    break
        \\
    , .{}, "luce.sema.loop");
}

test "var struct fields update through functional struct_set" {
    var program = try expectCompiles(
        \\struct Point:
        \\    x: Float
        \\    y: Float
        \\
        \\fn evaluate():
        \\    var point = Point(x = 0.0, y = 0.0)
        \\    point.x = 4.5
        \\    output.x = point.x
        \\
    , point_schema);
    defer program.deinit();
    const dump = try ir.print(testing.allocator, &program);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "struct_set") != null);
}

test "string operations type-check" {
    var program = try expectCompiles(
        \\fn evaluate():
        \\    let greeting = "hello, " + input.name
        \\    if len(greeting) > 3 and greeting != "":
        \\        output.text = greeting
        \\    else:
        \\        output.text = "short"
        \\
    , .{
        .inputs = &.{.{ .name = "name", .declared = .string }},
        .outputs = &.{.{ .name = "text", .declared = .string }},
    });
    defer program.deinit();
}
