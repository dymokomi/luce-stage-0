//! The plan executor: `build.luc` declares, this runs
//! (docs/BUILD.md phase C).
//!
//! A build script is an ordinary Luce program.  A bare `luce build`
//! under a project holding one compiles it — through the compile
//! cache, so an unchanged script costs one hash — runs it in the
//! project root, and reads the one JSON document it prints: the plan.
//! The steps then execute here, in dependency order, and only the
//! chosen step's own closure runs.  The separation is the point: the
//! script *declares* and has no way to build anything itself, so the
//! graph is inspectable and the tool is the only thing that touches
//! the world (`std/build.luc` says the same contract from its side).
//!
//! Two step kinds, each a whole world: a `luce` step is one source
//! compiled to one artifact by this process — the same seams
//! `luce build FILE` crosses — and a `command` step is one host
//! command run in the project root, argv as given: no shell, no
//! splitting.

const std = @import("std");

const luce = @import("luce");
const native = @import("native");
const object = @import("object.zig");
const front = @import("front.zig");

const Allocator = std.mem.Allocator;

/// What marks a project as script-built, found beside its `luce.yaml`.
pub const script_name = "build.luc";

pub const Options = struct {
    library_path: ?[]const u8,
    driver: ?[]const u8,
};

/// One declared step, as the wire carries it.
const Step = struct {
    name: []const u8,
    kind: enum { luce, command },
    source: []const u8 = "",
    emit: native.Kind = .executable,
    output: []const u8 = "",
    release: bool = false,
    links: []const []const u8 = &.{},
    argv: []const []const u8 = &.{},
    needs: []const []const u8 = &.{},
    /// The DFS marks: 0 untouched, 1 on the path (a repeat is a
    /// cycle), 2 done.
    mark: u8 = 0,
};

pub fn run(
    gpa: Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    root: []const u8,
    options: Options,
) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const spoken = (try planText(gpa, io, arena, err, root, options)) orelse return 1;
    const plan = (try readPlan(arena, err, spoken)) orelse return 1;
    const chosen = (try chooseTarget(err, plan)) orelse return 1;

    // Postorder over the chosen step's closure is dependency order.
    var order: std.ArrayList(*Step) = .empty;
    defer order.deinit(gpa);
    if (try visit(gpa, err, plan.steps, chosen, &order)) return 1;

    for (order.items) |step| {
        const failed = switch (step.kind) {
            .luce => try compileStep(gpa, io, arena, out, err, root, step, options),
            .command => try commandStep(gpa, io, arena, out, err, root, step),
        };
        if (failed) return 1;
    }
    try out.flush();
    return 0;
}

// ---------------------------------------------------------------------------
// Running the script
// ---------------------------------------------------------------------------

/// Compile the script through the cache, run it in the project root,
/// and answer the plan it printed — or null after saying what went
/// wrong.  The cache key is the same source hash every artifact
/// carries, so an edited script — or a `luce.yaml` edit that changes
/// what its imports mean — misses and rebuilds.
fn planText(
    gpa: Allocator,
    io: std.Io,
    arena: Allocator,
    err: *std.Io.Writer,
    root: []const u8,
    options: Options,
) !?[]const u8 {
    const script = try std.fs.path.join(arena, &.{ root, script_name });
    var program = switch (try front.compilePath(gpa, io, err, script, .{
        .library_path = options.library_path,
    })) {
        .program => |compiled| compiled,
        .refused => return null,
    };
    defer program.deinit();

    const encoded = try luce.mir.module.encode(gpa, &program);
    defer gpa.free(encoded);
    const source_hash = luce.codegen.artifact.sourceHash(encoded);

    const cache = try std.fs.path.join(arena, &.{ root, ".luce", "cache" });
    const runner = try std.fs.path.join(arena, &.{ cache, "build" });
    const stamp_path = try std.fs.path.join(arena, &.{ cache, "build.hash" });
    const stamp = try std.fmt.allocPrint(arena, "{x:0>16}", .{source_hash});

    const warm = warm: {
        const held = std.Io.Dir.cwd().readFileAlloc(io, stamp_path, arena, .limited(64)) catch
            break :warm false;
        if (!std.mem.eql(u8, held, stamp)) break :warm false;
        _ = std.Io.Dir.cwd().statFile(io, runner, .{}) catch break :warm false;
        break :warm true;
    };
    if (!warm) {
        try std.Io.Dir.cwd().createDirPath(io, cache);
        var tools = try native.discover(gpa, io, options.library_path, options.driver);
        defer tools.deinit(gpa);
        switch (try object.build(gpa, io, &tools, &program, .{
            .kind = .executable,
            .output = runner,
            .source_hash = source_hash,
        })) {
            .written => {},
            .unsupported => |what| {
                try err.print("{s}: damaged IR reached the backend ({s}); recompile from source and report this\n", .{ script, what });
                return null;
            },
            .failed => |why| {
                defer gpa.free(why);
                try err.print("luce: {s}\n", .{why});
                return null;
            },
        }
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = stamp_path, .data = stamp }) catch {};
    }

    const ran = std.process.run(gpa, io, .{
        .argv = &.{runner},
        .cwd = .{ .path = root },
    }) catch {
        try err.print("luce build: {s} could not be run\n", .{runner});
        return null;
    };
    defer gpa.free(ran.stderr);
    errdefer gpa.free(ran.stdout);
    if (ran.term != .exited or ran.term.exited != 0) {
        try err.print("luce build: {s} did not finish its plan\n", .{script_name});
        if (ran.stderr.len != 0) try err.writeAll(ran.stderr);
        gpa.free(ran.stdout);
        return null;
    }
    const kept = try arena.dupe(u8, ran.stdout);
    gpa.free(ran.stdout);
    return kept;
}

// ---------------------------------------------------------------------------
// Reading the plan
// ---------------------------------------------------------------------------

const Plan = struct {
    default: []const u8,
    steps: []Step,
};

/// Parse and validate the script's one JSON document, or answer null
/// after saying which rule the document broke.  Every refusal names
/// `build.luc`, because that is the file whose author is reading.
fn readPlan(arena: Allocator, err: *std.Io.Writer, spoken: []const u8) !?Plan {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, spoken, .{}) catch {
        try err.print("luce build: {s} printed something that is not a plan\n", .{script_name});
        return null;
    };
    const top = objectOf(parsed) orelse
        return sayNot(err, "the plan is not a JSON object");
    const version = top.get("plan") orelse
        return sayNot(err, "the plan names no plan: version");
    if (version != .integer or version.integer != 1)
        return sayNot(err, "the plan version is not 1");
    const default_name = textOf(top.get("default")) orelse
        return sayNot(err, "the plan's default is not text");
    const rows = arrayOf(top.get("steps")) orelse
        return sayNot(err, "the plan's steps are not an array");

    var steps = try arena.alloc(Step, rows.items.len);
    for (rows.items, 0..) |row, index| {
        const fields = objectOf(row) orelse
            return sayNot(err, "a step is not a JSON object");
        const name = textOf(fields.get("name")) orelse
            return sayNot(err, "a step names no name");
        if (name.len == 0) return sayNot(err, "a step's name is empty");
        for (steps[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.name, name))
                return sayNot(err, "two steps share one name");
        }
        const kind = textOf(fields.get("kind")) orelse
            return sayNot(err, "a step names no kind");
        var step: Step = .{ .name = name, .kind = undefined };
        if (std.mem.eql(u8, kind, "luce")) {
            step.kind = .luce;
            step.source = textOf(fields.get("source")) orelse
                return sayNot(err, "a luce step names no source");
            if (step.source.len == 0) return sayNot(err, "a luce step's source is empty");
            const emit = textOf(fields.get("emit")) orelse
                return sayNot(err, "a luce step names no emit");
            step.emit = if (std.mem.eql(u8, emit, "exe"))
                .executable
            else if (std.mem.eql(u8, emit, "library"))
                .library
            else if (std.mem.eql(u8, emit, "object"))
                .object
            else
                return sayNot(err, "a luce step's emit is not one of exe, library, object");
            step.output = textOf(fields.get("output")) orelse "";
            step.release = if (fields.get("release")) |held| held == .bool and held.bool else false;
            if (fields.get("links")) |carried| {
                const inputs = arrayOf(carried) orelse
                    return sayNot(err, "a luce step's links are not an array");
                const words = try arena.alloc([]const u8, inputs.items.len);
                for (inputs.items, 0..) |input, at| {
                    words[at] = textOf(input) orelse
                        return sayNot(err, "a luce step's links hold a value that is not text");
                }
                step.links = words;
            }
            if (step.emit == .object and step.links.len != 0)
                return sayNot(err, "an object step has no native link");
        } else if (std.mem.eql(u8, kind, "command")) {
            step.kind = .command;
            const argv = arrayOf(fields.get("argv")) orelse
                return sayNot(err, "a command step names no argv");
            if (argv.items.len == 0) return sayNot(err, "a command step's argv is empty");
            const words = try arena.alloc([]const u8, argv.items.len);
            for (argv.items, 0..) |word, at| {
                words[at] = textOf(word) orelse
                    return sayNot(err, "a command step's argv holds a value that is not text");
            }
            step.argv = words;
        } else {
            return sayNot(err, "a step's kind is not one of luce, command");
        }
        const wants = arrayOf(fields.get("needs")) orelse
            return sayNot(err, "a step's needs are not an array");
        const named = try arena.alloc([]const u8, wants.items.len);
        for (wants.items, 0..) |want, at| {
            named[at] = textOf(want) orelse
                return sayNot(err, "a step's needs hold a value that is not text");
        }
        step.needs = named;
        steps[index] = step;
    }

    // Every edge must land on a declared step.
    for (steps) |step| {
        for (step.needs) |want| {
            if (findStep(steps, want) == null) {
                try err.print(
                    "luce build: {s}'s plan: step {s} needs {s}, which no step declares\n",
                    .{ script_name, step.name, want },
                );
                return null;
            }
        }
    }
    return .{ .default = default_name, .steps = steps };
}

fn sayNot(err: *std.Io.Writer, what: []const u8) !?Plan {
    try err.print("luce build: {s}'s plan: {s}\n", .{ script_name, what });
    return null;
}

fn objectOf(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |held| held,
        else => null,
    };
}

fn textOf(value: ?std.json.Value) ?[]const u8 {
    const held = value orelse return null;
    return switch (held) {
        .string => |text| text,
        else => null,
    };
}

fn arrayOf(value: ?std.json.Value) ?std.json.Array {
    const held = value orelse return null;
    return switch (held) {
        .array => |items| items,
        else => null,
    };
}

fn findStep(steps: []Step, name: []const u8) ?*Step {
    for (steps) |*step| {
        if (std.mem.eql(u8, step.name, name)) return step;
    }
    return null;
}

/// The step a bare build builds: the plan's `default` when it names
/// one, the only step when there is exactly one, and otherwise a
/// refusal that lists what there is to choose from.
fn chooseTarget(err: *std.Io.Writer, plan: Plan) !?*Step {
    if (plan.default.len != 0) {
        return findStep(plan.steps, plan.default) orelse {
            try err.print(
                "luce build: {s}'s plan: the default {s} is not a declared step\n",
                .{ script_name, plan.default },
            );
            return null;
        };
    }
    if (plan.steps.len == 1) return &plan.steps[0];
    try err.print(
        "luce build: {s}'s plan declares {d} steps and no default; choose one with default()\n",
        .{ script_name, plan.steps.len },
    );
    return null;
}

/// Depth-first postorder over the chosen step's closure — dependency
/// order — refusing a cycle by naming the step that closed it.
fn visit(
    gpa: Allocator,
    err: *std.Io.Writer,
    steps: []Step,
    step: *Step,
    order: *std.ArrayList(*Step),
) error{ OutOfMemory, WriteFailed }!bool {
    if (step.mark == 2) return false;
    if (step.mark == 1) {
        try err.print(
            "luce build: {s}'s plan: step {s} depends on itself\n",
            .{ script_name, step.name },
        );
        return true;
    }
    step.mark = 1;
    for (step.needs) |want| {
        const wanted = findStep(steps, want).?;
        if (try visit(gpa, err, steps, wanted, order)) return true;
    }
    step.mark = 2;
    try order.append(gpa, step);
    return false;
}

// ---------------------------------------------------------------------------
// Executing the steps
// ---------------------------------------------------------------------------

/// One `luce` step: the same seams `luce build FILE` crosses, the
/// paths root-relative because the plan is the project's.  Answers
/// whether it failed.
fn compileStep(
    gpa: Allocator,
    io: std.Io,
    arena: Allocator,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    root: []const u8,
    step: *Step,
    options: Options,
) !bool {
    const source = try std.fs.path.join(arena, &.{ root, step.source });
    var program = switch (try front.compilePath(gpa, io, err, source, .{
        .library_path = options.library_path,
    })) {
        .program => |compiled| compiled,
        .refused => return true,
    };
    defer program.deinit();
    if (step.release) luce.mir.strip(&program);

    const encoded = try luce.mir.module.encode(gpa, &program);
    defer gpa.free(encoded);
    const source_hash = luce.codegen.artifact.sourceHash(encoded);

    var tools = try native.discover(gpa, io, options.library_path, options.driver);
    defer tools.deinit(gpa);

    // The report speaks the project's own relative names; the absolute
    // form is only for the toolchain, because the plan is the
    // project's and a transcript should read the same from any
    // machine.
    const spoken = if (step.output.len != 0)
        step.output
    else named: {
        const stem = step.source[0 .. step.source.len - ".luc".len];
        break :named try std.fmt.allocPrint(arena, "{s}{s}", .{ stem, step.emit.extension() });
    };
    const target = try std.fs.path.join(arena, &.{ root, spoken });

    // Link inputs are the project's names, like source and output; a
    // `-lNAME` request and an absolute path pass through as spoken.
    const links = try arena.alloc([]const u8, step.links.len);
    for (step.links, 0..) |input, at| {
        links[at] = if (std.mem.startsWith(u8, input, "-") or std.fs.path.isAbsolute(input))
            input
        else
            try std.fs.path.join(arena, &.{ root, input });
    }

    switch (try object.build(gpa, io, &tools, &program, .{
        .kind = step.emit,
        .output = target,
        .source_hash = source_hash,
        .links = links,
    })) {
        .written => {},
        .unsupported => |what| {
            try err.print("{s}: damaged IR reached the backend ({s}); recompile from source and report this\n", .{ step.source, what });
            return true;
        },
        .failed => |why| {
            defer gpa.free(why);
            try err.print("luce: {s}\n", .{why});
            return true;
        },
    }
    try out.print("{s}: {s} -> {s}\n", .{ step.name, step.source, spoken });
    return false;
}

/// One host command, argv as given, run in the project root.  What it
/// printed is shown either way; a status other than zero stops the
/// plan and says which step stopped it.
fn commandStep(
    gpa: Allocator,
    io: std.Io,
    arena: Allocator,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    root: []const u8,
    step: *Step,
) !bool {
    _ = arena;
    const ran = std.process.run(gpa, io, .{
        .argv = step.argv,
        .cwd = .{ .path = root },
    }) catch {
        try err.print(
            "luce build: step {s}: {s} could not be started\n",
            .{ step.name, step.argv[0] },
        );
        return true;
    };
    defer gpa.free(ran.stdout);
    defer gpa.free(ran.stderr);
    if (ran.stdout.len != 0) try out.writeAll(ran.stdout);
    if (ran.term != .exited or ran.term.exited != 0) {
        if (ran.stderr.len != 0) try err.writeAll(ran.stderr);
        try err.print("luce build: step {s} failed\n", .{step.name});
        return true;
    }
    try out.print("{s}: ran {s}\n", .{ step.name, step.argv[0] });
    return false;
}
