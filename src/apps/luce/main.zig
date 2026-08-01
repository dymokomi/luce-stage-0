//! The luce compiler: .luc source in, .lc module out.
//!
//! Three commands over one pipeline:
//!   luce build FILE.luc [-o FILE.lc]   compile and write a module
//!   luce check FILE.luc                compile, report, write nothing
//!   luce ir FILE.luc                   compile and dump readable IR
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
        var index: usize = 3;
        while (index < arguments.len) : (index += 1) {
            if (std.mem.eql(u8, arguments[index], "-o") and index + 1 < arguments.len) {
                index += 1;
                output_path = arguments[index];
            } else if (std.mem.eql(u8, arguments[index], "--release")) {
                release = true;
            } else {
                return usage(err);
            }
        }
        return build(gpa, io, err, out, path, output_path, release);
    }
    if (std.mem.eql(u8, command, "wasm")) {
        var output_path: []const u8 = "";
        if (arguments.len == 5 and std.mem.eql(u8, arguments[3], "-o")) {
            output_path = arguments[4];
        } else if (arguments.len != 3) {
            return usage(err);
        }
        return buildWasm(gpa, io, err, out, path, output_path);
    }
    if (std.mem.eql(u8, command, "check")) {
        if (arguments.len != 3) return usage(err);
        var program = (try compilePath(gpa, io, err, path)) orelse return 1;
        defer program.deinit();
        try out.print("{s}: ok\n", .{path});
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
        const dump = try luce.ir.print(gpa, &program);
        defer gpa.free(dump);
        try out.writeAll(dump);
        try out.flush();
        return 0;
    }
    return usage(err);
}

fn usage(err: *std.Io.Writer) !u8 {
    try err.print(
        "usage:\n" ++
            "  luce build FILE.luc [-o FILE.lc] [--release]\n" ++
            "  luce check FILE.luc\n" ++
            "  luce ir FILE.luc [--full]\n" ++
            "  luce wasm FILE.luc [-o FILE.wasm]\n" ++
            "\n" ++
            "build is a debug build unless --release: the module\n" ++
            "carries source locations, so traps report file:line\n" ++
            "and a call trace.  --release strips them for smaller\n" ++
            "modules; the program itself behaves identically.\n",
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
    if (release) luce.ir.strip(&program);
    const encoded = try luce.module.encode(gpa, &program);
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
    try out.print("{s} -> {s}\n", .{ path, target });
    try out.flush();
    return 0;
}

/// FILE.luc -> FILE.lc; anything else appends .lc.
fn modulePath(gpa: std.mem.Allocator, source_path: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, source_path, ".luc")) {
        return std.fmt.allocPrint(gpa, "{s}.lc", .{source_path[0 .. source_path.len - ".luc".len]});
    }
    return std.fmt.allocPrint(gpa, "{s}.lc", .{source_path});
}

/// Compile one script file; renders diagnostics to `err` and returns
/// null on failure.  The caller owns the returned program.
fn buildWasm(
    gpa: std.mem.Allocator,
    io: std.Io,
    err: *std.Io.Writer,
    out: *std.Io.Writer,
    path: []const u8,
    output_path: []const u8,
) !u8 {
    var program = (try compilePath(gpa, io, err, path)) orelse return 1;
    defer program.deinit();
    if (!luce.codegen_wasm.supported(&program)) {
        try err.print("{s}: outside the wasm backend's core (milestone 0: integer/bool, print(str(Int)))\n", .{path});
        return 1;
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const bytes = try luce.codegen_wasm.compile(arena_state.allocator(), &program);
    const target = if (output_path.len != 0) output_path else try defaultWasmPath(arena_state.allocator(), path);
    try files.writeWhole(io, target, bytes);
    try out.print("{s}\n", .{target});
    try out.flush();
    return 0;
}

fn defaultWasmPath(arena: std.mem.Allocator, source: []const u8) ![]const u8 {
    const stem = if (std.mem.endsWith(u8, source, ".luc")) source[0 .. source.len - 4] else source;
    return std.fmt.allocPrint(arena, "{s}.wasm", .{stem});
}

fn compilePath(
    gpa: std.mem.Allocator,
    io: std.Io,
    err: *std.Io.Writer,
    path: []const u8,
) !?luce.ir.Program {
    return compilePathPruned(gpa, io, err, path, true);
}

fn compilePathPruned(
    gpa: std.mem.Allocator,
    io: std.Io,
    err: *std.Io.Writer,
    path: []const u8,
    prune: bool,
) !?luce.ir.Program {
    const source = files.readWhole(gpa, io, path) catch {
        try err.print("luce: cannot read {s}\n", .{path});
        return null;
    };
    defer gpa.free(source);

    var loader: files.FileLoader = .{ .io = io, .directory = std.fs.path.dirname(path) orelse "" };
    var result = try luce.compile.compileProject(gpa, source, loader.loader(), .{}, .{
        .entry_mode = .script,
        .allow_host = true,
        .source_name = std.fs.path.basename(path),
        .prune = prune,
    });
    switch (result) {
        .success => |program| return program,
        .failure => |*diagnostics| {
            const rendered = try diagnostics.render(gpa, source);
            defer gpa.free(rendered);
            try err.print("{s}: compile failed\n{s}", .{ path, rendered });
            result.deinit();
            return null;
        },
    }
}

test {
    _ = luce;
}
