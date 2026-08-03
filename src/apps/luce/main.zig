//! The luce compiler: .luc source in, .lc module out.
//!
//! Three commands over one pipeline:
//!   luce build FILE.luc [-o FILE.lc]   compile and write a module
//!   luce check FILE.luc                compile, report, write nothing
//!   luce ir FILE.luc                   compile and dump readable IR
//!
//! `build --backend=llvm` runs the same program through the LLVM
//! backend instead and writes a relocatable object (docs/CODEGEN.md);
//! the default backend still writes the interpreter's `.lc`.
//!
//! Programs compile in script mode (`func main():`) with the host
//! builtins allowed; loom is the trusted boundary that decides which
//! host services actually exist at run time.

const std = @import("std");
const luce = @import("luce");
const files = @import("files");

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

    var err_writer = std.Io.File.stderr().writer(io, &.{});
    const err = &err_writer.interface;
    var out_buffer: [4096]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(io, &out_buffer);
    const out = &out_writer.interface;

    if (arguments.len < 3) return usage(err);
    const command = arguments[1];
    const path = arguments[2];

    if (std.mem.eql(u8, command, "build")) {
        var output_path: []const u8 = "";
        var release = false;
        var backend: Backend = .interpreter;
        var index: usize = 3;
        while (index < arguments.len) : (index += 1) {
            if (std.mem.eql(u8, arguments[index], "-o") and index + 1 < arguments.len) {
                index += 1;
                output_path = arguments[index];
            } else if (std.mem.eql(u8, arguments[index], "--release")) {
                release = true;
            } else if (std.mem.eql(u8, arguments[index], "--backend=llvm")) {
                backend = .llvm;
            } else if (std.mem.eql(u8, arguments[index], "--backend=interpreter")) {
                backend = .interpreter;
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
        return switch (backend) {
            .interpreter => build(gpa, io, err, out, path, output_path, release),
            .llvm => buildObject(gpa, io, err, out, path, output_path, release),
        };
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

/// Which code path `build` takes: the portable `.lc` the interpreter
/// runs, or a native object from the LLVM backend.
const Backend = enum { interpreter, llvm };

fn usage(err: *std.Io.Writer) !u8 {
    try err.print(
        "usage:\n" ++
            "  luce build FILE.luc [-o FILE.lc] [--release] [--backend=llvm]\n" ++
            "  luce check FILE.luc\n" ++
            "  luce ir FILE.luc [--full]\n" ++
            "\n" ++
            "FILE may be - to read the program from standard input;\n" ++
            "imports then resolve beside the current directory, and\n" ++
            "build needs -o to say where to write.\n" ++
            "\n" ++
            "build is a debug build unless --release: the module\n" ++
            "carries source locations, so traps report file:line\n" ++
            "and a call trace.  --release strips them for smaller\n" ++
            "modules; the program itself behaves identically.\n" ++
            "\n" ++
            "--backend=llvm compiles through LLVM and writes a\n" ++
            "relocatable object (FILE.o by default) for the host\n" ++
            "target, to be linked against the published host ABI.\n" ++
            "--release means the same thing there: trap locations\n" ++
            "go, function names stay.\n",
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

/// Compile through LLVM and write a relocatable object for the host.
///
/// The object exports one symbol, `luce_main`, and declares none: every
/// effect reaches the outside world through the host table it is
/// handed (`luce.llvm.abi`).  Linking it into a shared library or an
/// executable is the caller's job for now.
fn buildObject(
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

    // The same one thing release means everywhere: the object carries
    // no origins, so a trap names its functions and not their lines.
    if (release) luce.mir.strip(&program);

    const triple = try luce.llvm.hostTriple(gpa);
    defer gpa.free(triple);

    const bitcode = switch (try luce.llvm.lower(gpa, &program, .{
        .triple = triple,
        .name = std.fs.path.basename(path),
    })) {
        .bitcode => |bytes| bytes,
        .unsupported => |what| {
            try err.print(
                "{s}: the LLVM backend has no lowering for {s} yet\n",
                .{ path, what },
            );
            return 1;
        },
    };
    defer gpa.free(bitcode);

    const object = switch (try luce.llvm.compile(gpa, bitcode, .{ .triple = triple })) {
        .object => |bytes| bytes,
        .failed => |why| {
            defer gpa.free(why);
            try err.print("{s}: LLVM failed: {s}\n", .{ path, why });
            return 1;
        },
    };
    defer gpa.free(object);

    const target = if (output_path.len != 0)
        try gpa.dupe(u8, output_path)
    else
        try replaceExtension(gpa, path, ".o");
    defer gpa.free(target);

    files.writeWhole(io, target, object) catch {
        try err.print("luce: cannot write {s}\n", .{target});
        return 1;
    };
    try out.print("{s} -> {s} ({s})\n", .{ path, target, triple });
    try out.flush();
    return 0;
}

/// FILE.luc -> FILE.lc; anything else appends .lc.
fn modulePath(gpa: std.mem.Allocator, source_path: []const u8) ![]u8 {
    return replaceExtension(gpa, source_path, ".lc");
}

/// FILE.luc -> FILE + `extension`; anything else just appends.
fn replaceExtension(
    gpa: std.mem.Allocator,
    source_path: []const u8,
    extension: []const u8,
) ![]u8 {
    const stem = if (std.mem.endsWith(u8, source_path, ".luc"))
        source_path[0 .. source_path.len - ".luc".len]
    else
        source_path;
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ stem, extension });
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

test {
    _ = luce;
}
