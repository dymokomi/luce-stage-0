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

/// Loads the source of `import name` for project compiles.  Returns
/// null when the module cannot be found; the compiler reports it.
/// Loaded bytes may be allocated from `arena` and must stay valid for
/// the compile.
pub const Loader = struct {
    context: *anyopaque,
    loadFn: *const fn (
        context: *anyopaque,
        arena: Allocator,
        name: []const u8,
    ) error{OutOfMemory}!?[]const u8,
};

/// One source file may import at most this many modules transitively;
/// a backstop against runaway import graphs, not a design limit.
const max_modules = 64;

pub fn compile(
    gpa: Allocator,
    source: []const u8,
    schema: PortSchema,
    options: types.CompileOptions,
) Error!CompileResult {
    return compileProject(gpa, source, null, schema, options);
}

/// Compile a root source plus everything it imports (a file is a
/// module; `import geo` loads geo.luc through the loader) into one
/// program.  Without a loader, imports are compile errors.
pub fn compileProject(
    gpa: Allocator,
    source: []const u8,
    loader: ?Loader,
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
    const scaffold = ast_arena.allocator();

    const root_tree = try scaffold.create(@import("ast.zig").Program);
    root_tree.* = try parser_mod.parse(scaffold, gpa, source, &diagnostics);
    if (diagnostics.hasErrors()) {
        program.deinit();
        return .{ .failure = diagnostics };
    }

    var modules: std.ArrayList(analyzer_mod.ModuleTree) = .empty;
    defer modules.deinit(gpa);
    try modules.append(gpa, .{ .prefix = "", .tree = root_tree });

    // Breadth-first over the import graph; each module loads and
    // parses once, cycles are simply already-loaded names.
    var pending: std.ArrayList(@import("ast.zig").Import) = .empty;
    defer pending.deinit(gpa);
    try pending.appendSlice(gpa, root_tree.imports);
    var next: usize = 0;
    while (next < pending.items.len) : (next += 1) {
        const wanted = pending.items[next];
        var already = false;
        for (modules.items) |module| {
            if (std.mem.eql(u8, module.prefix, wanted.name)) already = true;
        }
        if (already) continue;
        if (modules.items.len >= max_modules) {
            diagnostics.scope = "";
            try diagnostics.add("luce.import.limit", wanted.span, "too many modules (limit {d})", .{max_modules});
            break;
        }

        const loaded: ?[]const u8 = if (loader) |through|
            try through.loadFn(through.context, scaffold, wanted.name)
        else
            null;
        const module_source = loaded orelse {
            diagnostics.scope = "";
            try diagnostics.add(
                "luce.import.missing",
                wanted.span,
                "cannot load module {s} (looked for {s}.luc)",
                .{ wanted.name, wanted.name },
            );
            continue;
        };
        try diagnostics.registerSource(wanted.name, module_source);

        diagnostics.scope = wanted.name;
        const tree = try scaffold.create(@import("ast.zig").Program);
        tree.* = try parser_mod.parse(scaffold, gpa, module_source, &diagnostics);
        diagnostics.scope = "";
        const prefix = try scaffold.dupe(u8, wanted.name);
        try modules.append(gpa, .{ .prefix = prefix, .tree = tree });
        try pending.appendSlice(gpa, tree.imports);
    }
    if (diagnostics.hasErrors()) {
        program.deinit();
        return .{ .failure = diagnostics };
    }

    const analyzed = (try analyzer_mod.analyze(arena, gpa, modules.items, schema, options, &diagnostics)) orelse {
        program.deinit();
        return .{ .failure = diagnostics };
    };

    program.structs = analyzed.structs;
    program.heap_types = analyzed.heap_types;
    program.functions = analyzed.functions;
    program.constants = analyzed.constants;
    program.reads = analyzed.reads;
    program.entry_function = analyzed.entry_function;
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
    return expectFailsOptions(source, schema, .{}, expected_code);
}

fn expectFailsOptions(
    source: []const u8,
    schema: PortSchema,
    options: types.CompileOptions,
    expected_code: []const u8,
) !void {
    var result = try compile(testing.allocator, source, schema, options);
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

test "func is strict and fn is an ordinary identifier" {
    try expectFails(
        \\fn evaluate(input: Input, output: Output):
        \\    return
        \\
    , .{}, "luce.parse.top");
}

test "entry mode enforces evaluator and script contracts" {
    try expectFailsOptions(
        \\func main():
        \\    return
        \\
    , .{}, .{ .entry_mode = .evaluator }, "luce.sema.evaluate");
    try expectFailsOptions(
        \\func evaluate(input: Input, output: Output):
        \\    return
        \\
    , .{}, .{ .entry_mode = .script }, "luce.sema.main");
    try expectFailsOptions(
        \\func main(value: Int):
        \\    return
        \\
    , .{}, .{ .entry_mode = .script }, "luce.sema.main");

    var script = try compile(testing.allocator,
        \\func main():
        \\    return
        \\
    , .{}, .{ .entry_mode = .script });
    defer script.deinit();
    try testing.expect(script == .success);
}

test "zero-port evaluators still require exact frame parameters" {
    try expectFails(
        \\func evaluate():
        \\    return
        \\
    , .{}, "luce.sema.evaluate");
    var program = try expectCompiles(
        \\func evaluate(input: Input, output: Output):
        \\    return
        \\
    , .{});
    defer program.deinit();
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
        \\func evaluate(input: Input, output: Output):
        \\    output.value = Math.double(Pair.sum(input.left, input.right))
        \\
    , .{
        .inputs = &.{
            .{ .name = "left", .declared = .int },
            .{ .name = "right", .declared = .int },
        },
        .outputs = &.{.{ .name = "value", .declared = .int }},
    });
    defer program.deinit();
    try testing.expectEqualStrings("Math.double", program.functions[1].name);

    try expectFails(
        \\struct Bad:
        \\    value: Int
        \\    func value() -> Int:
        \\        return 1
        \\
        \\func evaluate(input: Input, output: Output):
        \\    return
        \\
    , .{}, "luce.sema.duplicate");
    try expectFails(
        \\struct Helpers:
        \\    func one() -> Int:
        \\        return 1
        \\
        \\func evaluate(input: Input, output: Output):
        \\    let bad = Helpers.missing()
        \\
    , .{}, "luce.sema.call");
    try expectFails(
        \\struct Helpers:
        \\    func one() -> Int:
        \\        return 1
        \\
        \\func evaluate(input: Input, output: Output):
        \\    let bad = Helpers()
        \\
    , .{}, "luce.sema.construct");
}

test "frame access is scoped to evaluator entry" {
    try expectFails(
        \\func helper() -> Int:
        \\    return input.value
        \\
        \\func evaluate(input: Input, output: Output):
        \\    output.value = helper()
        \\
    , .{
        .inputs = &.{.{ .name = "value", .declared = .int }},
        .outputs = &.{.{ .name = "value", .declared = .int }},
    }, "luce.sema.name");
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
        \\func evaluate(input: Input, output: Output):
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
        \\func evaluate(input: Input, output: Output):
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
        \\func evaluate(input: Input, output: Output):
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
    try testing.expect(std.mem.indexOf(u8, first, "func evaluate() -> None") != null);
    try testing.expect(std.mem.indexOf(u8, first, "input_load value") != null);
    try testing.expect(std.mem.indexOf(u8, first, "output_store value") != null);
    try testing.expect(std.mem.indexOf(u8, first, "multiply.Int") != null);
}

test "unknown ports and port type mismatches diagnose" {
    try expectFails(
        \\func evaluate(input: Input, output: Output):
        \\    output.ghost = 1
        \\
    , point_schema, "luce.sema.port");
    try expectFails(
        \\func evaluate(input: Input, output: Output):
        \\    let missing = input.ghost
        \\
    , point_schema, "luce.sema.port");
    try expectFails(
        \\func evaluate(input: Input, output: Output):
        \\    output.x = 1
        \\
    , point_schema, "luce.sema.type");
    try expectFails(
        \\func evaluate(input: Input, output: Output):
        \\    input.x = 1.0
        \\
    , point_schema, "luce.sema.input");
    try expectFails(
        \\func evaluate(input: Input, output: Output):
        \\    let peek = output.x
        \\
    , point_schema, "luce.sema.output");
}

test "no implicit conversion, no reassigned let, no shadowing" {
    try expectFails(
        \\func evaluate(input: Input, output: Output):
        \\    let mixed = 1 + 2.0
        \\
    , .{}, "luce.sema.type");
    try expectFails(
        \\func evaluate(input: Input, output: Output):
        \\    let once = 1
        \\    once = 2
        \\
    , .{}, "luce.sema.let");
    try expectFails(
        \\func evaluate(input: Input, output: Output):
        \\    let name = 1
        \\    if true:
        \\        let name = 2
        \\
    , .{}, "luce.sema.duplicate");
    try expectFails(
        \\func evaluate(input: Input, output: Output):
        \\    let value: Float = 3
        \\
    , .{}, "luce.sema.type");
}

test "return paths and evaluate's shape are checked" {
    try expectFails(
        \\func partial(flag: Bool) -> Int:
        \\    if flag:
        \\        return 1
        \\
        \\func evaluate(input: Input, output: Output):
        \\    let unused = partial(true)
        \\
    , .{}, "luce.sema.return");
    try expectFails(
        \\func helper() -> Int:
        \\    return 1
        \\
    , .{}, "luce.sema.evaluate");
    try expectFails(
        \\func evaluate(input: Input, output: Output) -> Int:
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
        \\func evaluate(input: Input, output: Output):
        \\    let missing = Color(red = 1.0)
        \\
    , .{}, "luce.sema.construct");
    try expectFails(source_prefix ++
        \\func evaluate(input: Input, output: Output):
        \\    let doubled = Color(red = 1.0, red = 2.0, green = 3.0)
        \\
    , .{}, "luce.sema.construct");
    try expectFails(source_prefix ++
        \\func evaluate(input: Input, output: Output):
        \\    let wrong = Color(red = 1, green = 2.0)
        \\
    , .{}, "luce.sema.type");
    try expectFails(
        \\struct Loop:
        \\    inner: Loop
        \\
        \\func evaluate(input: Input, output: Output):
        \\    let never = 1
        \\
    , .{}, "luce.sema.struct");
}

test "calls check arity, types, and none results" {
    try expectFails(
        \\func helper(value: Int) -> Int:
        \\    return value
        \\
        \\func evaluate(input: Input, output: Output):
        \\    let wrong = helper(1, 2)
        \\
    , .{}, "luce.sema.call");
    try expectFails(
        \\func nothing():
        \\    return
        \\
        \\func evaluate(input: Input, output: Output):
        \\    let value = nothing()
        \\
    , .{}, "luce.sema.call");
    try expectFails(
        \\func evaluate(input: Input, output: Output):
        \\    let bad = sqrt(4)
        \\
    , .{}, "luce.sema.type");
    try expectFails(
        \\func evaluate(input: Input, output: Output):
        \\    let bad = unknown_helper(1)
        \\
    , .{}, "luce.sema.call");
}

test "break and continue require a loop" {
    try expectFails(
        \\func evaluate(input: Input, output: Output):
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
        \\func evaluate(input: Input, output: Output):
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
        \\func evaluate(input: Input, output: Output):
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

test "host builtins type-check and stay host-gated" {
    try expectFails(
        \\func evaluate(input: Input, output: Output):
        \\    print("hello")
        \\
    , .{}, "luce.sema.host");
    try expectFails(
        \\func evaluate(input: Input, output: Output):
        \\    let text = file_read("notes.txt")
        \\
    , .{}, "luce.sema.host");

    var hosted = try compile(testing.allocator,
        \\func main():
        \\    print("hello " + arg(0))
        \\    if file_exists("notes.txt"):
        \\        let text = file_read("notes.txt")
        \\        if file_write("copy.txt", text):
        \\            print("copied")
        \\    term_clear()
        \\    term_move(0, 0)
        \\    term_style(114, -1, false)
        \\    term_write(key_read() + key_text())
        \\    term_flush()
        \\
    , .{}, .{ .entry_mode = .script, .allow_host = true });
    defer hosted.deinit();
    try testing.expect(hosted == .success);

    try expectFailsOptions(
        \\func main():
        \\    let bad = file_read(7)
        \\
    , .{}, .{ .entry_mode = .script, .allow_host = true }, "luce.sema.type");
    try expectFailsOptions(
        \\func main():
        \\    term_style(1, 2, 3)
        \\
    , .{}, .{ .entry_mode = .script, .allow_host = true }, "luce.sema.type");
}

test "collections type-check and reject misuse at compile time" {
    const script: types.CompileOptions = .{ .entry_mode = .script };

    var featured = try compile(testing.allocator,
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
    , .{}, script);
    defer featured.deinit();
    try testing.expect(featured == .success);

    try expectFailsOptions(
        \\func main():
        \\    let mixed = [1, "two"]
        \\
    , .{}, script, "luce.sema.type");
    try expectFailsOptions(
        \\func main():
        \\    var untyped = []
        \\
    , .{}, script, "luce.sema.type");
    try expectFailsOptions(
        \\func main():
        \\    var m = new Map(Float, Int)
        \\
    , .{}, script, "luce.sema.type");
    try expectFailsOptions(
        \\func main():
        \\    var grid = new Array(Int, 2, 2)
        \\    let bad = grid[0]
        \\
    , .{}, script, "luce.sema.index");
    try expectFailsOptions(
        \\func main():
        \\    var m = new Map(String, Int)
        \\    let bad = m[7]
        \\
    , .{}, script, "luce.sema.index");
    try expectFailsOptions(
        \\func main():
        \\    let bad = 5.append(1)
        \\
    , .{}, script, "luce.sema.method");
    try expectFailsOptions(
        \\func main():
        \\    for x in 7:
        \\        let unused = x
        \\
    , .{}, script, "luce.sema.loop");
    try expectFailsOptions(
        \\func main():
        \\    let xs = [1]
        \\    let bad = xs < xs
        \\
    , .{}, script, "luce.sema.type");
    try expectFailsOptions(
        \\func main():
        \\    var xs = [1]
        \\    xs[0] = "text"
        \\
    , .{}, script, "luce.sema.type");
}

// ---------------------------------------------------------------------------
// Modules
// ---------------------------------------------------------------------------

const TestModule = struct { name: []const u8, source: []const u8 };

const TestLoader = struct {
    modules: []const TestModule,

    fn load(context: *anyopaque, arena: Allocator, name: []const u8) error{OutOfMemory}!?[]const u8 {
        const self: *TestLoader = @ptrCast(@alignCast(context));
        for (self.modules) |module| {
            if (std.mem.eql(u8, module.name, name)) {
                return try arena.dupe(u8, module.source);
            }
        }
        return null;
    }

    fn loader(self: *TestLoader) Loader {
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

test "a file is a module: imports, qualified names, and shared types" {
    var files: TestLoader = .{ .modules = &.{ geo_module, util_module } };
    var result = try compileProject(testing.allocator,
        \\import geo
        \\
        \\func main():
        \\    let made = geo.make(3.0, 4.0)
        \\    assert(geo.length(made) == 5.0)
        \\    let direct = geo.Point(x = 1.0, y = 2.0)
        \\    let copied: geo.Point = direct
        \\    assert(copied.y == 2.0)
        \\    assert(geo.Text.double(21) == 42)
        \\
    , files.loader(), .{}, .{ .entry_mode = .script });
    switch (result) {
        .success => {},
        .failure => |*diagnostics| {
            const rendered = try diagnostics.render(testing.allocator, "");
            defer testing.allocator.free(rendered);
            std.debug.print("unexpected diagnostics:\n{s}", .{rendered});
            result.deinit();
            return error.TestUnexpectedResult;
        },
    }
    var program = result.success;
    defer program.deinit();

    // The whole project runs as one program.
    const backend = @import("backend.zig");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ran = try backend.evaluate(arena.allocator(), &program, &.{}, &.{}, .{});
    try testing.expect(ran == .success);
}

test "imports are explicit, checked, and reported per file" {
    const script: types.CompileOptions = .{ .entry_mode = .script };
    var files: TestLoader = .{ .modules = &.{ geo_module, util_module } };

    // Reaching a loaded-but-unimported namespace names the fix; a
    // namespace nothing loaded is an ordinary unknown name.
    var unimported = try compileProject(testing.allocator,
        \\import geo
        \\
        \\func main():
        \\    let bad = util.hypot(3.0, 4.0)
        \\
    , files.loader(), .{}, script);
    defer unimported.deinit();
    try testing.expect(unimported == .failure);
    try testing.expectEqualStrings("luce.sema.import", unimported.failure.at(0).?.code);
    var unknown = try compileProject(testing.allocator,
        \\func main():
        \\    let bad = geo.make(1.0, 2.0)
        \\
    , files.loader(), .{}, script);
    defer unknown.deinit();
    try testing.expect(unknown == .failure);
    try testing.expectEqualStrings("luce.sema.name", unknown.failure.at(0).?.code);

    // A missing module file reports where the import was written.
    var missing = try compileProject(testing.allocator,
        \\import ghost
        \\
        \\func main():
        \\    return
        \\
    , files.loader(), .{}, script);
    defer missing.deinit();
    try testing.expect(missing == .failure);
    try testing.expectEqualStrings("luce.import.missing", missing.failure.at(0).?.code);

    // Without a loader, imports cannot resolve at all.
    var lonely = try compile(testing.allocator,
        \\import geo
        \\
        \\func main():
        \\    return
        \\
    , .{}, script);
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
    var imported_error = try compileProject(testing.allocator,
        \\import broken
        \\
        \\func main():
        \\    let bad = broken.helper()
        \\
    , broken_files.loader(), .{}, script);
    defer imported_error.deinit();
    try testing.expect(imported_error == .failure);
    const rendered = try imported_error.failure.render(testing.allocator, "");
    defer testing.allocator.free(rendered);
    try testing.expect(std.mem.indexOf(u8, rendered, "broken.luc:2:") != null);
}

test "modules may import each other; mutual recursion crosses files" {
    const even_module: TestModule = .{ .name = "even", .source =
        \\import odd
        \\
        \\func check(value: Int) -> Bool:
        \\    if value == 0:
        \\        return true
        \\    return odd.check(value - 1)
        \\
    };
    const odd_module: TestModule = .{ .name = "odd", .source =
        \\import even
        \\
        \\func check(value: Int) -> Bool:
        \\    if value == 0:
        \\        return false
        \\    return even.check(value - 1)
        \\
    };
    var files: TestLoader = .{ .modules = &.{ even_module, odd_module } };
    var result = try compileProject(testing.allocator,
        \\import even
        \\
        \\func main():
        \\    assert(even.check(10))
        \\    assert(not even.check(7))
        \\
    , files.loader(), .{}, .{ .entry_mode = .script });
    defer result.deinit();
    try testing.expect(result == .success);

    const backend = @import("backend.zig");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ran = try backend.evaluate(arena.allocator(), &result.success, &.{}, &.{}, .{});
    try testing.expect(ran == .success);
}

test "short-circuit operands survive block splits everywhere" {
    // Every multi-operand construct with a splitting (and/or) operand
    // once emitted registers across block boundaries; the verifier
    // rejected the program as an internal compiler error.
    const script: types.CompileOptions = .{ .entry_mode = .script };
    var featured = try compile(testing.allocator,
        \\struct Flags:
        \\    left: Bool
        \\    right: Bool
        \\
        \\func pick(first: Bool, second: Bool) -> Bool:
        \\    return first or second
        \\
        \\func main():
        \\    let a = true
        \\    let b = false
        \\    var cells = new Array(Bool, 2, 2)
        \\    cells[0, 1] = a == b or a
        \\    let chosen = pick(a and b, a or b)
        \\    let pair = Flags(left = a or b, right = a and b)
        \\    var flags = [a or b, pair.left, cells[0, 1] and chosen]
        \\    flags.append(a or b)
        \\    let compared = (a or b) == (a and b)
        \\    let sliced = flags[0:len(flags)]
        \\    for index in range(0, len(sliced)):
        \\        let unused = sliced[index] or compared
        \\    free(sliced)
        \\    free(flags)
        \\    free(cells)
        \\
    , .{}, script);
    defer featured.deinit();
    switch (featured) {
        .success => {},
        .failure => |*diagnostics| {
            const rendered = try diagnostics.render(testing.allocator, "");
            defer testing.allocator.free(rendered);
            std.debug.print("unexpected diagnostics:\n{s}", .{rendered});
            return error.TestUnexpectedResult;
        },
    }

    const backend = @import("backend.zig");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ran = try backend.evaluate(arena.allocator(), &featured.success, &.{}, &.{}, .{});
    try testing.expect(ran == .success);
    try testing.expectEqual(@as(u32, 0), ran.success.leaked_objects);
}
