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
    return run(gpa, io, out, err, &program, arguments);
}

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
    var result = try luce.compile.compileProject(gpa, source, loader, .{}, compile_options);
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
    return run(gpa, io, out, err, &program, arguments);
}

/// The execution boundary: one hosted evaluation against the real
/// terminal, filesystem, and arguments.
pub fn run(
    gpa: Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    program: *const luce.ir.Program,
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

    const result = try luce.backend.evaluateHosted(
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
            try err.print("loom: trap: {s}\n", .{trap.message});
            return 1;
        },
        .unavailable => {
            try err.print("loom: program inputs unavailable; is this a script module?\n", .{});
            return 1;
        },
    }
}
