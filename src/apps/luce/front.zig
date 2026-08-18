//! The compiler's front half: a path in, a verified program out.
//!
//! `object.zig` is the back half — lower, emit, link — and this is
//! everything before it: read the bytes (or the stream), find the
//! `luce.yaml` that governs them, build the import loader the project
//! implies, and run stages 1 through 7.  Every diagnostic goes to the
//! writer the caller hands over before the answer comes back, so no
//! caller renders a compile failure twice and none has to.
//!
//! Its own file because `build`, `check`, `ir` and `test` all need it
//! and none of them needs the others: `main.zig` is a command line, and
//! `suite.zig` is a test runner, and a compile that lived in either
//! would have to be reached from the other.

const std = @import("std");
const luce = @import("luce");
const files = @import("files");

const Allocator = std.mem.Allocator;

/// What a compile needs beyond the path itself.
pub const Options = struct {
    /// `LUCE_LIB` — the package shelves the loader probes
    /// (docs/PACKAGES.md D3).  Null is a search path of nothing.
    library_path: ?[]const u8 = null,
    /// Stage 7.  `luce ir --full` clears it to show the raw lowering.
    prune: bool = true,
    /// Where the entry comes from: the declared `main`, or the one the
    /// compiler writes over a test file's discovered tests
    /// (docs/TESTING.md D3).
    entry: luce.types.Entry = .declared,
};

/// What one compile came to.
pub const Outcome = union(enum) {
    /// The caller owns it.
    program: luce.mir.Program,
    /// It did not compile, and the diagnostics have already been
    /// rendered to the writer — so a caller only has to decide what to
    /// do next, never how to say what went wrong.
    ///
    /// `import_failed` is the one fact a caller may still need: `luce
    /// test` explains what a rootless `tests/` directory means for
    /// imports, and only when that is what went wrong (docs/TESTING.md
    /// D3).  Reading it out of the rendered text would be parsing our
    /// own output, so it travels as what it is.
    refused: struct { import_failed: bool = false },
};

/// Compile one file — a `.luc` source, a `.lcm` module, or `-` for
/// standard input.  Renders diagnostics to `err`; the caller owns a
/// program that came back.
pub fn compilePath(
    gpa: Allocator,
    io: std.Io,
    err: *std.Io.Writer,
    path: []const u8,
    options: Options,
) !Outcome {
    if (std.mem.endsWith(u8, path, luce.mir.module.extension)) return decodePath(gpa, io, err, path);
    var result = switch (try compileSource(gpa, io, err, path, options)) {
        .unreadable => return .{ .refused = .{} },
        .result => |compiled| compiled,
    };
    switch (result) {
        .success => |program| return .{ .program = program },
        .failure => |*diagnostics| {
            const rendered = try diagnostics.render(gpa);
            defer gpa.free(rendered);
            try err.print("luce: compile failed\n{s}", .{rendered});
            const from_import = namedAnImport(diagnostics);
            result.deinit();
            return .{ .refused = .{ .import_failed = from_import } };
        },
    }
}

/// The diagnostics of one compile, as one JSON array on `out` — the
/// machine half of `luce check`, and the door the language server
/// asks through.  The array is the whole answer: a clean compile is
/// `[]`, and each entry carries the stable code, the message, and
/// 1-based start and end positions.  An unreadable file is a failure
/// of the *query* — reported to `err`, nonzero — because "no such
/// file" is not a fact about the program's source.
pub fn queryDiagnostics(
    gpa: Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    path: []const u8,
    options: Options,
) !u8 {
    if (std.mem.endsWith(u8, path, luce.mir.module.extension)) {
        try err.writeAll("luce: query wants source, not a compiled module\n");
        return 1;
    }
    var result = switch (try compileSource(gpa, io, err, path, options)) {
        .unreadable => return 1,
        .result => |compiled| compiled,
    };
    defer result.deinit();
    var stream: std.json.Stringify = .{ .writer = out };
    try stream.beginArray();
    if (result == .failure) {
        const diagnostics = &result.failure;
        for (0..diagnostics.count()) |index| {
            const place = diagnostics.resolve(index).?;
            try stream.beginObject();
            try stream.objectField("code");
            try stream.write(place.code);
            try stream.objectField("severity");
            try stream.write("error");
            try stream.objectField("message");
            try stream.write(place.message);
            try stream.objectField("path");
            try stream.write(place.path);
            try stream.objectField("line");
            try stream.write(place.line);
            try stream.objectField("column");
            try stream.write(place.column);
            try stream.objectField("end_line");
            try stream.write(place.end_line);
            try stream.objectField("end_column");
            try stream.write(place.end_column);
            try stream.endObject();
        }
    }
    try stream.endArray();
    try out.writeAll("\n");
    try out.flush();
    return 0;
}

/// What loading and compiling came to, before any caller's policy:
/// the result with its diagnostics still alive, or a file that could
/// not be read at all (already explained on `err`).
const Front = union(enum) {
    result: luce.compile.CompileResult,
    unreadable,
};

fn compileSource(
    gpa: Allocator,
    io: std.Io,
    err: *std.Io.Writer,
    path: []const u8,
    options: Options,
) !Front {

    // The root file goes through the same door as every import, so a
    // directory, a permission, or an oversized file reads the same
    // whether it is the program or something the program imports.
    const found = try files.readSource(gpa, io, path);
    const source = switch (found) {
        .text => |text| text.bytes,
        .missing => {
            try err.print("luce: cannot read {s}: no such file\n", .{path});
            return .unreadable;
        },
        .unreadable => |why| {
            try err.print("luce: cannot read {s}: {s}\n", .{ path, why });
            return .unreadable;
        },
        // The root is one path the user typed; no host answers it in
        // two places and no store machinery refuses it.  The arms
        // exist because the seam carries them.
        .ambiguous => {
            try err.print("luce: cannot read {s}: it answered in more than one place\n", .{path});
            return .unreadable;
        },
        .refused => |refusal| {
            try err.print("luce: cannot read {s}: {s}\n", .{ path, refusal.message });
            return .unreadable;
        },
    };
    defer gpa.free(source);

    // The luce.yaml governing the program, when one does: the root
    // token the module registry keys by, and the want list the store
    // probes are gated by (docs/PACKAGES.md D1, D3).  A broken
    // manifest is refused here, early, by name.
    var discovery = std.heap.ArenaAllocator.init(gpa);
    defer discovery.deinit();
    const governed: ?files.Governed = switch (try files.discoverProject(discovery.allocator(), io, path)) {
        .rootless => null,
        .governed => |project| project,
        .refused => |why| {
            try err.print("luce: {s}\n", .{why});
            return .unreadable;
        },
    };
    const source_root: []const u8 = if (governed) |project| project.root else "";
    const shelves: []const []const u8 = if (options.library_path) |text|
        try files.splitSearchPath(discovery.allocator(), text)
    else
        &.{};

    // The path as the user wrote it, not its basename: `luce check
    // sub/bad.luc` that answers `bad.luc:1:1` is a location nothing
    // can jump to, and there may be a bad.luc in three directories.
    var loader: files.FileLoader = .{
        .io = io,
        .directory = std.fs.path.dirname(path) orelse "",
        .project_root = source_root,
        .project = if (governed) |project| project.manifest else null,
        .shelves = shelves,
        .alerts = err,
        .gpa = gpa,
    };
    defer loader.deinit();
    return .{ .result = try luce.compile.compileProject(gpa, source, loader.loader(), .{
        .allow_host = true,
        .source_name = files.displayName(path),
        .source_root = source_root,
        .prune = options.prune,
        .entry = options.entry,
    }) };
}

/// Whether anything in this failure is about reaching another module.
/// Stage 1 files its refusals under `luce.import.*` and stage 4 files
/// the unresolved-namespace half under `luce.sema.import`; both mean
/// "the file could not reach what it named".
fn namedAnImport(diagnostics: *const luce.diagnostics.Diagnostics) bool {
    var index: usize = 0;
    while (diagnostics.at(index)) |reported| : (index += 1) {
        if (std.mem.startsWith(u8, reported.code, "luce.import.")) return true;
        if (std.mem.eql(u8, reported.code, "luce.sema.import")) return true;
    }
    return false;
}

/// Whether a rootless program's imports resolve beside it — which is
/// what a failing import under `luce test` needs said, because a
/// `tests/` directory is exactly where the answer is surprising
/// (docs/TESTING.md D3).
pub fn rootless(gpa: Allocator, io: std.Io, path: []const u8) !bool {
    var discovery = std.heap.ArenaAllocator.init(gpa);
    defer discovery.deinit();
    return switch (try files.discoverProject(discovery.allocator(), io, path)) {
        .rootless => true,
        .governed, .refused => false,
    };
}

/// Read a serialized module back into a program.
///
/// A `.lcm` has already been through the front end, so there is nothing
/// to check and nothing to prune — `decode` re-runs the IR verifier,
/// which is the whole of what this path owes a caller.
fn decodePath(
    gpa: Allocator,
    io: std.Io,
    err: *std.Io.Writer,
    path: []const u8,
) !Outcome {
    const encoded = files.readWhole(gpa, io, path) catch {
        try err.print("luce: cannot read {s}\n", .{path});
        return .{ .refused = .{} };
    };
    defer gpa.free(encoded);

    const decoded = luce.mir.module.decode(gpa, encoded) catch |mistake| switch (mistake) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedVersion => {
            try err.print("luce: {s} was built by a different luce; rebuild it from source\n", .{path});
            return .{ .refused = .{} };
        },
        error.InvalidModule => {
            try err.print("luce: {s} is not a valid Luce module\n", .{path});
            return .{ .refused = .{} };
        },
    };
    return .{ .program = decoded };
}
