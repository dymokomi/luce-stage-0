//! The luce compiler: .luc source in, a runnable artifact out.
//!
//! Three commands over one pipeline:
//!   luce build FILE.luc [-o OUT]   compile and write an artifact
//!   luce check FILE.luc            compile, report, write nothing
//!   luce ir FILE.luc               compile and dump readable IR
//!
//! **FILE may be a `.lc` as well as a `.luc`.**  A serialized module is
//! a compiled program in its portable form, and building a native
//! artifact from one asks nothing of the front end — it is decoded and
//! handed straight to stage 8.  That is how `loom` gets a program
//! compiled without carrying a code generator itself: it runs this
//! binary over the module it already has (`apps/loom/runner.zig`).
//!
//! `--emit` says which of four artifacts `build` writes, and it is the
//! only thing that differs between them — the same program walks the
//! same pipeline either way:
//!
//!   module   FILE.lc    portable serialized IR; the interpreter runs it
//!   object   FILE.o     a relocatable object; the caller links it
//!   library  FILE.lcn   a loadable native artifact; loom runs it
//!   exe      FILE       a standalone native executable
//!
//! The last three go through stage 10 (docs/CODEGEN.md) and are
//! tagged with the machine and the host ABI they were built for, so a
//! loader refuses the wrong one by name (`luce.llvm.abi.Artifact`).
//!
//! Programs compile in script mode (`func main():`) with the host
//! builtins allowed; whoever runs the artifact is the trusted boundary
//! that decides which host services actually exist.

const std = @import("std");
const luce = @import("luce");
const files = @import("files");
const native = @import("native");
const object = @import("object.zig");
const streams = @import("streams");

pub fn main(init: std.process.Init.Minimal) !u8 {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{
        .environ = init.environ,
        .argv0 = .init(init.args),
    });
    defer threaded.deinit();
    const io = threaded.io();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arguments = try init.args.toSlice(arena_state.allocator());

    var err_writer = streams.diagnostics(io);
    const err = &err_writer.interface;
    var out_buffer: [4096]u8 = undefined;
    var out_writer = streams.output(io, &out_buffer);
    const out = &out_writer.interface;

    if (arguments.len < 3) return usage(err);
    const command = arguments[1];
    const path = arguments[2];

    if (std.mem.eql(u8, command, "build")) {
        var output_path: []const u8 = "";
        var release = false;
        var emit: Emit = .module;
        var index: usize = 3;
        while (index < arguments.len) : (index += 1) {
            const argument = arguments[index];
            if (std.mem.eql(u8, argument, "-o") and index + 1 < arguments.len) {
                index += 1;
                output_path = arguments[index];
            } else if (std.mem.eql(u8, argument, "--release")) {
                release = true;
            } else if (std.mem.startsWith(u8, argument, "--emit=")) {
                emit = Emit.parse(argument["--emit=".len..]) orelse return usage(err);
            } else if (std.mem.eql(u8, argument, "--backend=llvm")) {
                // The older spelling of `--emit=object`, kept because
                // it is what docs/CODEGEN.md and every note about the
                // backend so far have said.
                emit = .object;
            } else if (std.mem.eql(u8, argument, "--backend=interpreter")) {
                emit = .module;
            } else {
                return usage(err);
            }
        }
        // A stream has no name to derive an output path from, so say
        // so rather than write a file called "-.lc".
        if (std.mem.eql(u8, path, files.standard_input) and output_path.len == 0) {
            try err.print("luce: reading from {s} needs -o to say where to write\n", .{files.standard_input});
            return 1;
        }
        if (emit == .module) return build(gpa, io, err, out, path, output_path, release);

        var environment = try init.environ.createMap(gpa);
        defer environment.deinit();
        return buildNative(gpa, io, err, out, .{
            .path = path,
            .output_path = output_path,
            .release = release,
            .kind = emit.kind(),
            .library_directory = environment.get("LUCE_LIB"),
            .driver = environment.get("LUCE_CC"),
        });
    }
    if (std.mem.eql(u8, command, "check")) {
        if (arguments.len != 3) return usage(err);
        var program = (try compilePath(gpa, io, err, path)) orelse return 1;
        defer program.deinit();
        try out.print("{s}: ok\n", .{files.displayName(path)});
        try out.flush();
        return 0;
    }
    if (std.mem.eql(u8, command, "ir")) {
        // --full keeps functions the entry never reaches (a std module
        // under inspection, a function not yet called) — the artifact
        // commands always prune.
        var keep_unreachable = false;
        if (arguments.len == 4 and std.mem.eql(u8, arguments[3], "--full")) {
            keep_unreachable = true;
        } else if (arguments.len != 3) {
            return usage(err);
        }
        var program = (try compilePathPruned(gpa, io, err, path, !keep_unreachable)) orelse return 1;
        defer program.deinit();
        const dump = try luce.mir.print(gpa, &program);
        defer gpa.free(dump);
        try out.writeAll(dump);
        try out.flush();
        return 0;
    }
    return usage(err);
}

/// Which artifact `build` writes.  One program, four shapes.
const Emit = enum {
    /// The portable serialized IR the interpreter runs.
    module,
    /// A relocatable object; linking it is the caller's job.
    object,
    /// A loadable native artifact — what loom runs, and what an
    /// embedder opens through the published ABI.
    library,
    /// A standalone native executable.
    exe,

    fn parse(text: []const u8) ?Emit {
        return std.meta.stringToEnum(Emit, text);
    }

    /// What the shared link-and-load code calls the same thing.
    fn kind(self: Emit) native.Kind {
        return switch (self) {
            .module => unreachable, // never reaches stage 10
            .object => .object,
            .library => .library,
            .exe => .executable,
        };
    }
};

fn usage(err: *std.Io.Writer) !u8 {
    try err.print(
        "usage:\n" ++
            "  luce build FILE [-o OUT] [--release] [--emit=WHAT]\n" ++
            "  luce check FILE\n" ++
            "  luce ir FILE [--full]\n" ++
            "\n" ++
            "FILE is a .luc source file, or a .lc module to take up\n" ++
            "from where it was left — the same program either way.\n" ++
            "\n" ++
            "--emit says which artifact to write, and nothing else\n" ++
            "differs between them — the same program walks the same\n" ++
            "pipeline either way:\n" ++
            "\n" ++
            "  module   FILE.lc   portable IR; loom's interpreter runs it\n" ++
            "  object   FILE.o    a relocatable object; you link it\n" ++
            "  library  FILE.lcn  a native artifact; loom runs it directly\n" ++
            "  exe      FILE      a standalone native executable\n" ++
            "\n" ++
            "module is the default.  The last three compile through\n" ++
            "LLVM and are stamped with the machine and the host ABI\n" ++
            "they were built for, so a loader refuses the wrong one\n" ++
            "by name.  Linking uses cc; LUCE_CC names another driver\n" ++
            "and LUCE_LIB the directory holding libluce_rt.a.\n" ++
            "\n" ++
            "FILE may be - to read the program from standard input;\n" ++
            "imports then resolve beside the current directory, and\n" ++
            "build needs -o to say where to write.\n" ++
            "\n" ++
            "build is a debug build unless --release: the artifact\n" ++
            "carries source locations, so traps report file:line\n" ++
            "and a call trace.  --release strips them for smaller\n" ++
            "artifacts; the program itself behaves identically.\n",
        .{},
    );
    return 1;
}

fn build(
    gpa: std.mem.Allocator,
    io: std.Io,
    err: *std.Io.Writer,
    out: *std.Io.Writer,
    path: []const u8,
    output_path: []const u8,
    release: bool,
) !u8 {
    var program = (try compilePath(gpa, io, err, path)) orelse return 1;
    defer program.deinit();

    // Release strips debug info (trap locations); it never changes
    // what the program does — every check traps identically.
    if (release) luce.mir.strip(&program);
    const encoded = try luce.mir.module.encode(gpa, &program);
    defer gpa.free(encoded);

    const target = if (output_path.len != 0)
        try gpa.dupe(u8, output_path)
    else
        try modulePath(gpa, path);
    defer gpa.free(target);

    files.writeWhole(io, target, encoded) catch {
        try err.print("luce: cannot write {s}\n", .{target});
        return 1;
    };
    try out.print("{s} -> {s}\n", .{ files.displayName(path), target });
    try out.flush();
    return 0;
}

/// Compile through LLVM and write an object, a loadable artifact, or a
/// standalone executable.
///
/// The generated code exports `luce_main` and declares no undefined
/// symbol beyond `libluce_rt`: every effect reaches the outside world
/// through the host table it is handed (`luce.llvm.abi`).  What the
/// three shapes differ in is only what is linked around that — nothing
/// for an object, nothing but the runtime for a library, and
/// `libluce_start`'s `main` as well for an executable.
fn buildNative(
    gpa: std.mem.Allocator,
    io: std.Io,
    err: *std.Io.Writer,
    out: *std.Io.Writer,
    request: struct {
        path: []const u8,
        output_path: []const u8,
        release: bool,
        kind: native.Kind,
        library_directory: ?[]const u8,
        driver: ?[]const u8,
    },
) !u8 {
    var program = (try compilePath(gpa, io, err, request.path)) orelse return 1;
    defer program.deinit();

    // The same one thing release means everywhere: the artifact
    // carries no origins, so a trap names its functions and not their
    // lines.
    if (request.release) luce.mir.strip(&program);

    // What the artifact will claim it was built from.  The serialized
    // module is the canonical form of a compiled program, so hashing
    // it is what lets a loader match an artifact to a `.lc` it was
    // handed — and lets `luce build --emit=library` warm a cache that
    // `loom run` will then hit.
    const encoded = try luce.mir.module.encode(gpa, &program);
    defer gpa.free(encoded);
    const source_hash = luce.llvm.abi.sourceHash(encoded);

    var tools = try native.discover(gpa, io, request.library_directory, request.driver);
    defer tools.deinit(gpa);

    const target = if (request.output_path.len != 0)
        try gpa.dupe(u8, request.output_path)
    else
        try replaceExtension(gpa, request.path, request.kind.extension());
    defer gpa.free(target);

    switch (try object.build(gpa, io, &tools, &program, .{
        .kind = request.kind,
        .output = target,
        .source_hash = source_hash,
    })) {
        .written => {},
        .unsupported => |what| {
            try err.print(
                "{s}: the LLVM backend has no lowering for {s} yet\n",
                .{ request.path, what },
            );
            // Its own exit code: this is about the program, not about
            // this attempt, so a caller retrying elsewhere should not.
            return native.exit_unsupported;
        },
        .failed => |why| {
            defer gpa.free(why);
            try err.print("luce: {s}\n", .{why});
            return 1;
        },
    }

    // The machine the tag claims, which is the one a loader checks.
    try out.print("{s} -> {s} ({s})\n", .{ request.path, target, luce.llvm.abi.machine });
    try out.flush();
    return 0;
}

/// FILE.luc -> FILE.lc; anything else appends .lc.
fn modulePath(gpa: std.mem.Allocator, source_path: []const u8) ![]u8 {
    return replaceExtension(gpa, source_path, ".lc");
}

/// FILE.luc and FILE.lc -> FILE + `extension`; anything else just
/// appends.  An empty extension is how an executable gets the program's
/// bare name.
fn replaceExtension(
    gpa: std.mem.Allocator,
    source_path: []const u8,
    extension: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ stemOf(source_path), extension });
}

/// A program's name without whichever of its two forms it arrived in.
fn stemOf(path: []const u8) []const u8 {
    inline for (.{ ".luc", ".lc" }) |suffix| {
        if (std.mem.endsWith(u8, path, suffix)) return path[0 .. path.len - suffix.len];
    }
    return path;
}

/// Compile one script file; renders diagnostics to `err` and returns
/// null on failure.  The caller owns the returned program.
fn compilePath(
    gpa: std.mem.Allocator,
    io: std.Io,
    err: *std.Io.Writer,
    path: []const u8,
) !?luce.mir.Program {
    return compilePathPruned(gpa, io, err, path, true);
}

fn compilePathPruned(
    gpa: std.mem.Allocator,
    io: std.Io,
    err: *std.Io.Writer,
    path: []const u8,
    prune: bool,
) !?luce.mir.Program {
    if (std.mem.endsWith(u8, path, ".lc")) return decodePath(gpa, io, err, path);

    // The root file goes through the same door as every import, so a
    // directory, a permission, or an oversized file reads the same
    // whether it is the program or something the program imports.
    const found = try files.readSource(gpa, io, path);
    const source = switch (found) {
        .text => |text| text.bytes,
        .missing => {
            try err.print("luce: cannot read {s}: no such file\n", .{path});
            return null;
        },
        .unreadable => |why| {
            try err.print("luce: cannot read {s}: {s}\n", .{ path, why });
            return null;
        },
    };
    defer gpa.free(source);

    // The path as the user wrote it, not its basename: `luce check
    // sub/bad.luc` that answers `bad.luc:1:1` is a location nothing
    // can jump to, and there may be a bad.luc in three directories.
    var loader: files.FileLoader = .{ .io = io, .directory = std.fs.path.dirname(path) orelse "" };
    var result = try luce.compile.compileProject(gpa, source, loader.loader(), .{}, .{
        .entry_mode = .script,
        .allow_host = true,
        .source_name = files.displayName(path),
        .prune = prune,
    });
    switch (result) {
        .success => |program| return program,
        .failure => |*diagnostics| {
            const rendered = try diagnostics.render(gpa);
            defer gpa.free(rendered);
            try err.print("luce: compile failed\n{s}", .{rendered});
            result.deinit();
            return null;
        },
    }
}

/// Read a serialized module back into a program.
///
/// A `.lc` has already been through the front end, so there is nothing
/// to check and nothing to prune — `decode` re-runs the IR verifier,
/// which is the whole of what this path owes a caller.
fn decodePath(
    gpa: std.mem.Allocator,
    io: std.Io,
    err: *std.Io.Writer,
    path: []const u8,
) !?luce.mir.Program {
    const encoded = files.readWhole(gpa, io, path) catch {
        try err.print("luce: cannot read {s}\n", .{path});
        return null;
    };
    defer gpa.free(encoded);

    return luce.mir.module.decode(gpa, encoded) catch |mistake| switch (mistake) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedVersion => {
            try err.print("luce: {s} was built by a different luce; rebuild it from source\n", .{path});
            return null;
        },
        error.InvalidModule => {
            try err.print("luce: {s} is not a valid .lc module\n", .{path});
            return null;
        },
    };
}

test {
    _ = luce;
    _ = object;
}

test "an artifact's name comes from the program's, whichever form it arrived in" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "sub/game.luc", "sub/game.lc" }) |path| {
        const artifact = try replaceExtension(gpa, path, ".lcn");
        defer gpa.free(artifact);
        try std.testing.expectEqualStrings("sub/game.lcn", artifact);

        const binary = try replaceExtension(gpa, path, "");
        defer gpa.free(binary);
        try std.testing.expectEqualStrings("sub/game", binary);
    }
}
