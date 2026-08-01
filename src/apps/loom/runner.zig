//! Load, compile, and run Luce programs for the loom terminal.
//!
//! One boundary for both entry paths: `runModule` executes a compiled
//! .lc file, `runScript` compiles a .luc file in memory and executes
//! the result.  Programs run with an effectively unlimited step budget
//! — interactive programs block on key_read for as long as they like —
//! and the screen is restored before any trap is reported.

const std = @import("std");
const builtin = @import("builtin");
const luce = @import("luce");
const files = @import("files");
const host_mod = @import("host.zig");

const Allocator = std.mem.Allocator;

/// Interactive programs run until they return; the step budget is
/// intentionally open-ended.  Call depth is conservative because the
/// native engines use the OS stack (the self-written backend permits
/// frames up to about 32 KiB); 128 frames remain below the normal
/// macOS/Linux main-thread stack while still giving useful recursion.
const program_budget: luce.backend.Budget = .{
    .steps = std.math.maxInt(u64),
    .call_depth = luce.native.max_call_depth,
};

/// A trap trace prints at most this many frames; a runaway recursion
/// reports its innermost calls and a count of the rest.
const max_printed_frames = 12;

/// Process-wide engine policy, set once at startup from LOOM_ENGINE:
/// `auto` prefers the self-written backend on ARM macOS and MIR on
/// other native hosts.  Explicit modes are strict, which keeps tests
/// and benchmarks from silently measuring a fallback engine.
pub const Engine = enum {
    auto,
    interpreter,
    zig,
    mir,

    pub fn parse(name: []const u8) ?Engine {
        inline for (std.meta.fields(Engine)) |field| {
            if (std.mem.eql(u8, name, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }
};
pub var engine: Engine = .auto;

const SelectedEngine = enum { zig, mir, interpreter, unavailable };

fn selectEngine(policy: Engine, zig_ok: bool, mir_ok: bool) SelectedEngine {
    return switch (policy) {
        .interpreter => .interpreter,
        .zig => if (zig_ok) .zig else .unavailable,
        .mir => if (mir_ok) .mir else .unavailable,
        .auto => if (builtin.cpu.arch == .aarch64 and builtin.os.tag == .macos and zig_ok)
            .zig
        else if (mir_ok)
            .mir
        else
            .interpreter,
    };
}

/// Process-wide image policy, set once at startup from LOOM_IMAGE:
/// `auto` reads and writes the .lci cache beside a .lc (the native
/// image, docs/NATIVE.md milestone 5b), `off` neither reads nor
/// writes it.  Scripts (.luc) compile in memory and never touch
/// images.
pub const Image = enum {
    auto,
    off,

    pub fn parse(name: []const u8) ?Image {
        if (std.mem.eql(u8, name, "auto")) return .auto;
        if (std.mem.eql(u8, name, "off")) return .off;
        return null;
    }
};
pub var image: Image = .auto;

fn imageCacheEnabled(policy: Image, platform_supported: bool, has_artifact: bool) bool {
    return policy == .auto and platform_supported and has_artifact;
}

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

fn zigImageKeys(artifact: Artifact) luce.image.Keys {
    return .{
        .fingerprint = luce.codegen.fingerprint(),
        .module_hash = luce.image.hashModule(artifact.encoded),
        .text_hash = luce.codegen.imageTextHash(artifact.encoded),
    };
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
    const cache = imageCacheEnabled(image, luce.image.supported, artifact != null);
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

/// The self-written backend's persistent image path.  A module cache
/// hit maps and runs with no code emission; a miss emits hermetic
/// spans, writes the same .lci format MIR uses, then maps and runs.
/// Backend-specific keys make the shared path safe when engine policy
/// changes.  Scripts and LOOM_IMAGE=off never enter the cache path.
fn runZig(
    gpa: Allocator,
    io: std.Io,
    arena: Allocator,
    program: *const luce.ir.Program,
    artifact: ?Artifact,
    inputs: []const luce.backend.InputValue,
    outputs: []?luce.backend.RuntimeValue,
    host: ?luce.backend.Host,
) !luce.backend.Result {
    const cache = imageCacheEnabled(image, luce.image.supported, artifact != null);
    const keys: ?luce.image.Keys = if (cache) zigImageKeys(artifact.?) else null;

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

    const spans = try luce.codegen.compile(arena, program);

    if (keys) |fresh| write_image: {
        const bytes = try luce.image.encode(arena, spans, fresh);
        const image_path = try imagePath(arena, artifact.?.path);
        files.writeWhole(io, image_path, bytes) catch break :write_image;
    }

    var loaded = luce.image.map(gpa, spans) catch |mistake| switch (mistake) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeFailed,
    };
    defer loaded.deinit(gpa);
    return luce.native.runCode(arena, program, loaded.addresses, inputs, outputs, program_budget, host);
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

    const zig_ok = luce.codegen.available and luce.codegen.supported(program);
    const mir_ok = luce.native.available and luce.native.supported(program);
    const selected = selectEngine(engine, zig_ok, mir_ok);
    if (selected == .unavailable) {
        try err.print("loom: requested {s} engine does not support this program on this host\n", .{@tagName(engine)});
        return 1;
    }

    const result = switch (selected) {
        .zig => runZig(
            gpa,
            io,
            arena.allocator(),
            program,
            artifact,
            inputs,
            outputs,
            services.host(),
        ) catch |mistake| switch (mistake) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NativeFailed => if (engine == .zig) {
                try err.print("loom: zig engine failed to compile or map this program\n", .{});
                return 1;
            } else if (mir_ok) runNative(
                gpa,
                io,
                arena.allocator(),
                program,
                artifact,
                inputs,
                outputs,
                services.host(),
            ) catch |native_mistake| switch (native_mistake) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NativeFailed => try luce.backend.evaluateHosted(
                    arena.allocator(),
                    program,
                    inputs,
                    outputs,
                    program_budget,
                    services.host(),
                ),
            } else try luce.backend.evaluateHosted(
                arena.allocator(),
                program,
                inputs,
                outputs,
                program_budget,
                services.host(),
            ),
        },
        .mir => runNative(
            gpa,
            io,
            arena.allocator(),
            program,
            artifact,
            inputs,
            outputs,
            services.host(),
        ) catch |mistake| switch (mistake) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NativeFailed => if (engine == .mir) {
                try err.print("loom: MIR engine failed to compile this program\n", .{});
                return 1;
            } else try luce.backend.evaluateHosted(
                arena.allocator(),
                program,
                inputs,
                outputs,
                program_budget,
                services.host(),
            ),
        },
        .interpreter => try luce.backend.evaluateHosted(
            arena.allocator(),
            program,
            inputs,
            outputs,
            program_budget,
            services.host(),
        ),
        .unavailable => unreachable,
    };

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

test "engine policy is strict when forced and auto follows the platform ladder" {
    try std.testing.expectEqual(Engine.zig, Engine.parse("zig").?);
    try std.testing.expectEqual(Engine.mir, Engine.parse("mir").?);
    try std.testing.expect(Engine.parse("mri") == null);
    try std.testing.expectEqual(Image.off, Image.parse("off").?);
    try std.testing.expect(Image.parse("sometimes") == null);

    try std.testing.expectEqual(SelectedEngine.interpreter, selectEngine(.interpreter, true, true));
    try std.testing.expectEqual(SelectedEngine.zig, selectEngine(.zig, true, true));
    try std.testing.expectEqual(SelectedEngine.unavailable, selectEngine(.zig, false, true));
    try std.testing.expectEqual(SelectedEngine.mir, selectEngine(.mir, true, true));
    try std.testing.expectEqual(SelectedEngine.unavailable, selectEngine(.mir, true, false));

    const auto_with_both: SelectedEngine = if (builtin.cpu.arch == .aarch64 and builtin.os.tag == .macos)
        .zig
    else
        .mir;
    try std.testing.expectEqual(auto_with_both, selectEngine(.auto, true, true));
    try std.testing.expectEqual(SelectedEngine.mir, selectEngine(.auto, false, true));
    try std.testing.expectEqual(SelectedEngine.interpreter, selectEngine(.auto, false, false));
}

test "zig image caching requires auto policy, platform support, and a module artifact" {
    try std.testing.expect(imageCacheEnabled(.auto, true, true));
    try std.testing.expect(!imageCacheEnabled(.off, true, true));
    try std.testing.expect(!imageCacheEnabled(.auto, false, true));
    try std.testing.expect(!imageCacheEnabled(.auto, true, false)); // source scripts

    const artifact: Artifact = .{ .path = "program.lc", .encoded = "portable module" };
    const keys = zigImageKeys(artifact);
    try std.testing.expectEqual(luce.codegen.fingerprint(), keys.fingerprint);
    try std.testing.expectEqual(luce.image.hashModule(artifact.encoded), keys.module_hash);
    try std.testing.expectEqual(luce.codegen.imageTextHash(artifact.encoded), keys.text_hash);
    try std.testing.expect(keys.fingerprint != luce.native.fingerprint());
}
