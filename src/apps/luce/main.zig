//! The luce compiler: .luc source in, machine code out.
//!
//! Three commands over one pipeline:
//!   luce build FILE.luc [-o OUT]   compile and write an artifact
//!   luce check FILE.luc            compile, report, write nothing
//!   luce ir FILE.luc               compile and dump readable IR
//!
//! **`build` writes a `.lc`, and a `.lc` is machine code** — a tagged
//! shared library `loom` opens and calls (`docs/CODEGEN.md`).  There is
//! no second, slower thing to write: the artifact is the deliverable
//! and the tag is what makes it safe to hand around, because a loader
//! refuses the wrong machine, the wrong host ABI, or another code
//! generator's output by name (`luce.llvm.abi.Artifact`).
//!
//! `--emit` says which of three shapes it takes, and it is the only
//! thing that differs between them — the same program walks the same
//! pipeline either way:
//!
//!   (default)  FILE.lc    a loadable artifact; loom runs it
//!   object     FILE.o     a relocatable object; the caller links it
//!   exe        FILE       a standalone native executable
//!
//! **FILE may be a `.lcm` as well as a `.luc`.**  That is the serialized
//! module (`06_mir/module.zig`) — the front end's hand-over to the back
//! end, not a distribution format — and building from one asks nothing
//! of the front end: it is decoded and handed straight to stage 10.
//! That is how `loom` gets a program compiled without carrying a code
//! generator itself: it runs this binary over the module it already
//! has (`apps/loom/runner.zig`).
//!
//! A program is exactly `func main():`, or `func main() -> !:` when
//! the world can stop it, and compiles with the host builtins allowed;
//! whoever runs the artifact is the trusted boundary that decides
//! which host services actually exist.

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
        var emit: Emit = .library;
        var said_output = false;
        var said_release = false;
        var said_emit = false;
        var index: usize = 3;
        while (index < arguments.len) : (index += 1) {
            const argument = arguments[index];
            if (std.mem.eql(u8, argument, "-o")) {
                if (index + 1 == arguments.len) return refuse(err, "-o needs a path after it", .{});
                if (said_output) return refuse(err, "-o was given twice", .{});
                said_output = true;
                index += 1;
                output_path = arguments[index];
            } else if (std.mem.eql(u8, argument, "--release")) {
                if (said_release) return refuse(err, "--release was given twice", .{});
                said_release = true;
                release = true;
            } else if (std.mem.startsWith(u8, argument, "--emit=")) {
                if (said_emit) return refuse(err, "--emit was given twice", .{});
                said_emit = true;
                const wanted = argument["--emit=".len..];
                emit = Emit.parse(wanted) orelse return refuse(
                    err,
                    "--emit={s} is not one of library, object, exe",
                    .{wanted},
                );
            } else {
                return refuse(err, "{s} is not an option build takes", .{argument});
            }
        }
        // A stream has no name to derive an output path from, so say
        // so rather than write a file called "-.lc".
        if (std.mem.eql(u8, path, files.standard_input) and output_path.len == 0) {
            try err.print("luce: reading from {s} needs -o to say where to write\n", .{files.standard_input});
            return 1;
        }

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
        if (arguments.len != 3) return refuse(err, "check takes one file and no options", .{});
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
            return refuse(err, "ir takes one file and at most --full", .{});
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

/// Which artifact `build` writes.  One program, three shapes.
const Emit = enum {
    /// A loadable `.lc` — what loom runs, what an embedder opens
    /// through the published ABI, and the default.
    library,
    /// A relocatable object; linking it is the caller's job.
    object,
    /// A standalone native executable.
    exe,

    fn parse(text: []const u8) ?Emit {
        return std.meta.stringToEnum(Emit, text);
    }

    /// What the shared link-and-load code calls the same thing.
    fn kind(self: Emit) native.Kind {
        return switch (self) {
            .library => .library,
            .object => .object,
            .exe => .executable,
        };
    }
};

/// A command line this compiler will not guess at: one sentence
/// naming what is wrong, and where to read the rest.
///
/// **Nothing is taken twice and nothing silently wins.**  A `luce
/// build x.luc --emit=exe --emit=object` was written by somebody or
/// generated by something, and either way one of the two was meant;
/// quietly taking the last writes a file of the wrong shape and
/// reports success, which is the failure a build system cannot see.
/// The same goes for two `-o`s: the artifact would land somewhere the
/// caller is not looking.  Repeating an option is cheap to detect and
/// free to fix, so it is refused.
fn refuse(err: *std.Io.Writer, comptime reason: []const u8, arguments: anytype) !u8 {
    try err.print("luce: " ++ reason ++ "\n", arguments);
    try err.writeAll("run `luce` with no arguments for usage\n");
    return 1;
}

fn usage(err: *std.Io.Writer) !u8 {
    try err.print(
        "usage:\n" ++
            "  luce build FILE [-o OUT] [--release] [--emit=WHAT]\n" ++
            "  luce check FILE\n" ++
            "  luce ir FILE [--full]\n" ++
            "\n" ++
            "FILE is a .luc source file, or a .lcm module to take up\n" ++
            "from where it was left — the same program either way.\n" ++
            "A .lcm is the front end's hand-over to the back end, not\n" ++
            "something to ship; loom writes one when it needs a\n" ++
            "program compiled.\n" ++
            "\n" ++
            "--emit says which shape to write, and nothing else\n" ++
            "differs between them — the same program walks the same\n" ++
            "pipeline either way:\n" ++
            "\n" ++
            "  library  FILE.lc   a native artifact loom runs (default)\n" ++
            "  object   FILE.o    a relocatable object; you link it\n" ++
            "  exe      FILE      a standalone native executable\n" ++
            "\n" ++
            "All three compile through LLVM and are stamped with the\n" ++
            "machine, the host ABI and the code generator they were\n" ++
            "built for, so a loader refuses the wrong one by name.\n" ++
            "Linking uses cc; LUCE_CC names another driver and\n" ++
            "LUCE_LIB the directory holding libluce_rt.a.\n" ++
            "\n" ++
            "FILE may be - to read the program from standard input;\n" ++
            "imports then resolve beside the current directory, and\n" ++
            "build needs -o to say where to write.\n" ++
            "\n" ++
            "build is a debug build unless --release: the artifact\n" ++
            "carries source locations, so traps report file:line\n" ++
            "and a call trace.  --release strips them for smaller\n" ++
            "artifacts; the program itself behaves identically.\n" ++
            "\n" ++
            "Each option may be given once.  Writing one twice is\n" ++
            "refused rather than resolved: taking the last -o or the\n" ++
            "last --emit would put a file somewhere the caller is not\n" ++
            "looking, and say it worked.\n",
        .{},
    );
    return 1;
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
    // module is the canonical form of a program, so hashing it is what
    // lets a loader decide whether the `.lc` beside a source is still
    // the one that source makes — and lets `luce build` warm a cache
    // that `loom luce` will then hit.
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

    // One line, the same on every host: what went in and what came
    // out.  The machine is deliberately not in it — every artifact is
    // for the machine that built it, the tag is where that fact is
    // written down, and a loader is what reads it (`llvm.abi.machine`).
    // A build line that named the host would also make every recorded
    // transcript of one host-specific, which the site's samples are
    // compared against byte for byte.
    try out.print("{s} -> {s}\n", .{ files.displayName(request.path), target });
    try out.flush();
    return 0;
}

/// FILE.luc and FILE.lcm -> FILE + `extension`; anything else just
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
    inline for (.{ ".luc", luce.mir.module.extension }) |suffix| {
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
    if (std.mem.endsWith(u8, path, luce.mir.module.extension)) return decodePath(gpa, io, err, path);

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
    var result = try luce.compile.compileProject(gpa, source, loader.loader(), .{
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
/// A `.lcm` has already been through the front end, so there is nothing
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
            try err.print("luce: {s} is not a valid Luce module\n", .{path});
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
    for ([_][]const u8{ "sub/game.luc", "sub/game.lcm" }) |path| {
        const artifact = try replaceExtension(gpa, path, ".lc");
        defer gpa.free(artifact);
        try std.testing.expectEqualStrings("sub/game.lc", artifact);

        const binary = try replaceExtension(gpa, path, "");
        defer gpa.free(binary);
        try std.testing.expectEqualStrings("sub/game", binary);
    }
}
