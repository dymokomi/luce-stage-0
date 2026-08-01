//! Load, compile, and run Luce programs for the loom terminal.
//!
//! One boundary for both entry paths: `runModule` executes a compiled
//! .lc file, `runScript` compiles a .luc file in memory and executes
//! the result.  Programs run with an effectively unlimited step budget
//! — interactive programs block on key_read for as long as they like —
//! and the screen is restored before any trap is reported.

const std = @import("std");
const luce = @import("luce");
const files = @import("files");
const host_mod = @import("host.zig");

const Allocator = std.mem.Allocator;

/// Interactive programs run until they return; the budget guards
/// against runaway recursion, not against long-lived main loops.
/// The interpreter runs on an explicit heap-allocated frame stack,
/// so this is a pure policy limit (frames cost memory, not native
/// stack) and a runaway recursion traps with a clean
/// `call_depth_exceeded` at any setting.
const program_budget: luce.backend.Budget = .{
    .steps = std.math.maxInt(u64),
    .call_depth = 1 << 18,
};

/// A trap trace prints at most this many frames; a runaway recursion
/// reports its innermost calls and a count of the rest.
const max_printed_frames = 12;

/// Process-wide engine policy, set once at startup from LOOM_ENGINE:
/// `auto` picks native when the program fits, `interpreter` forces
/// the reference engine (semantics are identical; this is for
/// debugging and benchmarking the engines against each other).
pub const Engine = enum { auto, interpreter };
pub var engine: Engine = .auto;

/// Process-wide image policy, set once at startup from LOOM_IMAGE:
/// `auto` reads and writes the .lci cache beside a .lc (the native
/// image, docs/NATIVE.md milestone 5b), `off` neither reads nor
/// writes it.  Scripts (.luc) compile in memory and never touch
/// images.
pub const Image = enum { auto, off };
pub var image: Image = .auto;

pub const compile_options: luce.types.CompileOptions = .{
    .entry_mode = .script,
    .allow_host = true,
};

/// Run a compiled module from disk.
pub fn runModule(
    gpa: Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    path: []const u8,
    arguments: []const []const u8,
) !u8 {
    const encoded = files.readWhole(gpa, io, path) catch {
        try err.print("loom: cannot read {s}\n", .{path});
        return 1;
    };
    defer gpa.free(encoded);

    var program = luce.module.decode(gpa, encoded) catch |mistake| switch (mistake) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedVersion => {
            try err.print("loom: {s} was built by a different luce; rebuild it from source\n", .{path});
            return 1;
        },
        error.InvalidModule => {
            try err.print("loom: {s} is not a valid .lc module\n", .{path});
            return 1;
        },
    };
    defer program.deinit();
    return run(gpa, io, out, err, &program, .{ .path = path, .encoded = encoded }, arguments);
}

/// The on-disk identity of a module being run, when there is one:
/// what the image cache keys on and sits beside.
pub const Artifact = struct {
    path: []const u8,
    encoded: []const u8,
};

/// Compile a .luc source file (plus the modules it imports, resolved
/// beside it) and run it immediately.
pub fn runScript(
    gpa: Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    path: []const u8,
    arguments: []const []const u8,
) !u8 {
    const source = files.readWhole(gpa, io, path) catch {
        try err.print("loom: cannot read {s}\n", .{path});
        return 1;
    };
    defer gpa.free(source);
    var loader: files.FileLoader = .{ .io = io, .directory = std.fs.path.dirname(path) orelse "" };
    return runSource(gpa, io, out, err, path, source, loader.loader(), arguments);
}

/// Compile source bytes (already in memory) and run them.
pub fn runSource(
    gpa: Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    name: []const u8,
    source: []const u8,
    loader: ?luce.compile.Loader,
    arguments: []const []const u8,
) !u8 {
    var options = compile_options;
    options.source_name = std.fs.path.basename(name);
    var result = try luce.compile.compileProject(gpa, source, loader, .{}, options);
    switch (result) {
        .success => {},
        .failure => |*diagnostics| {
            const rendered = try diagnostics.render(gpa, source);
            defer gpa.free(rendered);
            try err.print("{s}: compile failed\n{s}", .{ name, rendered });
            result.deinit();
            return 1;
        },
    }
    var program = result.success;
    defer program.deinit();
    return run(gpa, io, out, err, &program, null, arguments);
}

/// The native path with the image cache around it (docs/NATIVE.md
/// milestone 5b).  A valid `.lci` beside the `.lc` runs with zero
/// code generation and no MIR context; anything else — no image, a
/// stale one, a foreign one — falls through to the JIT, which then
/// rewrites the cache best-effort before the program runs (it may
/// never return).  Cache failures are never the program's problem.
fn runNative(
    gpa: Allocator,
    io: std.Io,
    arena: Allocator,
    program: *const luce.ir.Program,
    artifact: ?Artifact,
    inputs: []const luce.backend.InputValue,
    outputs: []?luce.backend.RuntimeValue,
    host: ?luce.backend.Host,
) !luce.backend.Result {
    const cache = image == .auto and luce.image.supported and artifact != null;
    const keys: ?luce.image.Keys = if (cache) .{
        .fingerprint = luce.native.fingerprint(),
        .module_hash = luce.image.hashModule(artifact.?.encoded),
        .text_hash = try luce.native.textHash(arena, program),
    } else null;

    if (keys) |wanted| from_image: {
        const image_path = try imagePath(arena, artifact.?.path);
        const bytes = files.readWhole(arena, io, image_path) catch break :from_image;
        const spans = luce.image.decode(arena, bytes, wanted, program.functions.len) catch |mistake| switch (mistake) {
            error.OutOfMemory => return error.OutOfMemory,
            else => break :from_image,
        };
        var loaded = luce.image.map(gpa, spans) catch |mistake| switch (mistake) {
            error.OutOfMemory => return error.OutOfMemory,
            else => break :from_image,
        };
        defer loaded.deinit(gpa);
        return luce.native.runCode(arena, program, loaded.addresses, inputs, outputs, program_budget, host);
    }

    const compiled = try luce.native.compile(arena, program);
    defer compiled.deinit();

    if (keys) |fresh| write_image: {
        const spans = try arena.alloc([]const u8, program.functions.len);
        for (spans, 0..) |*span, index| span.* = compiled.code(index);
        const bytes = try luce.image.encode(arena, spans, fresh);
        const image_path = try imagePath(arena, artifact.?.path);
        files.writeWhole(io, image_path, bytes) catch break :write_image;
    }

    return compiled.run(arena, program, inputs, outputs, program_budget, host);
}

/// FILE.lc gets FILE.lci beside it; anything else gets .lci appended.
fn imagePath(arena: Allocator, module_path: []const u8) error{OutOfMemory}![]const u8 {
    if (std.mem.endsWith(u8, module_path, ".lc")) {
        return std.fmt.allocPrint(arena, "{s}i", .{module_path});
    }
    return std.fmt.allocPrint(arena, "{s}.lci", .{module_path});
}

/// The execution boundary: one hosted evaluation against the real
/// terminal, filesystem, and arguments.
pub fn run(
    gpa: Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    program: *const luce.ir.Program,
    artifact: ?Artifact,
    arguments: []const []const u8,
) !u8 {
    var services: host_mod.Host = undefined;
    services.setup(gpa, io, out, arguments);
    defer services.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const outputs = try arena.allocator().alloc(?luce.backend.RuntimeValue, program.outputs.len);
    @memset(outputs, null);
    const inputs = try arena.allocator().alloc(luce.backend.InputValue, program.inputs.len);
    @memset(inputs, .unavailable);

    // Engine choice: native (MIR-compiled at load) whenever the whole
    // program fits its supported core, the interpreter otherwise —
    // identical semantics either way.
    const use_native = engine == .auto and
        luce.native.available and
        luce.native.supported(program);
    const result = if (use_native)
        runNative(gpa, io, arena.allocator(), program, artifact, inputs, outputs, services.host()) catch |mistake| switch (mistake) {
            error.OutOfMemory => return error.OutOfMemory,
            // A native-compile failure is a loom bug; the program
            // still runs, on the reference engine.
            error.NativeFailed => try luce.backend.evaluateHosted(
                arena.allocator(),
                program,
                inputs,
                outputs,
                program_budget,
                services.host(),
            ),
        }
    else
        try luce.backend.evaluateHosted(
            arena.allocator(),
            program,
            inputs,
            outputs,
            program_budget,
            services.host(),
        );

    // Land back on the ordinary screen before reporting anything.
    services.restoreScreen();
    switch (result) {
        .success => |success| {
            // Scope ownership frees everything (OWNERSHIP.md S33);
            // a nonzero count is an interpreter bug, not a program's.
            if (success.leaked_objects != 0) {
                try err.print(
                    "loom: internal error: {d} object{s} escaped ownership — please report this\n",
                    .{ success.leaked_objects, if (success.leaked_objects == 1) "" else "s" },
                );
            }
            return 0;
        },
        .trap => |trap| {
            try err.print("loom: trap: {s} [{s}]\n", .{ trap.message, @tagName(trap.code) });
            // Innermost first, like Zig's own traces.  A --release
            // module has no lines; the function names still print.
            for (trap.trace, 0..) |frame, index| {
                if (index == max_printed_frames) break;
                if (frame.line != 0) {
                    try err.print("    at {s} ({s}:{d}:{d})\n", .{
                        frame.function, frame.source, frame.line, frame.column,
                    });
                } else {
                    try err.print("    at {s}\n", .{frame.function});
                }
            }
            const hidden = trap.dropped +
                @as(u32, @intCast(trap.trace.len -| max_printed_frames));
            if (hidden != 0) try err.print("    ... {d} more frames\n", .{hidden});
            return 1;
        },
        .unavailable => {
            try err.print("loom: program inputs unavailable; is this a script module?\n", .{});
            return 1;
        },
    }
}
