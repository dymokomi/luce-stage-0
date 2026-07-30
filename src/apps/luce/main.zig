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
        var index: usize = 3;
        while (index < arguments.len) : (index += 1) {
            if (std.mem.eql(u8, arguments[index], "-o") and index + 1 < arguments.len) {
                index += 1;
                output_path = arguments[index];
            } else {
                return usage(err);
            }
        }
        return build(gpa, io, err, out, path, output_path);
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
        if (arguments.len != 3) return usage(err);
        var program = (try compilePath(gpa, io, err, path)) orelse return 1;
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
            "  luce build FILE.luc [-o FILE.lc]\n" ++
            "  luce check FILE.luc\n" ++
            "  luce ir FILE.luc\n",
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
) !u8 {
    var program = (try compilePath(gpa, io, err, path)) orelse return 1;
    defer program.deinit();

    const encoded = try luce.module.encode(gpa, &program);
    defer gpa.free(encoded);

    const target = if (output_path.len != 0)
        try gpa.dupe(u8, output_path)
    else
        try modulePath(gpa, path);
    defer gpa.free(target);

    writeWhole(io, target, encoded) catch {
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
fn compilePath(
    gpa: std.mem.Allocator,
    io: std.Io,
    err: *std.Io.Writer,
    path: []const u8,
) !?luce.ir.Program {
    const source = readWhole(gpa, io, path) catch {
        try err.print("luce: cannot read {s}\n", .{path});
        return null;
    };
    defer gpa.free(source);

    var files: FileLoader = .{ .io = io, .directory = std.fs.path.dirname(path) orelse "" };
    var result = try luce.compile.compileProject(gpa, source, files.loader(), .{}, .{
        .entry_mode = .script,
        .allow_host = true,
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

/// Loads `import name` as NAME.luc next to the root source file.
const FileLoader = struct {
    io: std.Io,
    directory: []const u8,

    fn load(context: *anyopaque, arena: std.mem.Allocator, name: []const u8) error{OutOfMemory}!?[]const u8 {
        const self: *FileLoader = @ptrCast(@alignCast(context));
        const path = if (self.directory.len == 0)
            try std.fmt.allocPrint(arena, "{s}.luc", .{name})
        else
            try std.fmt.allocPrint(arena, "{s}/{s}.luc", .{ self.directory, name });
        const file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch return null;
        defer file.close(self.io);
        const size: usize = @intCast(file.length(self.io) catch return null);
        const content = try arena.alloc(u8, size);
        const loaded = file.readPositionalAll(self.io, content, 0) catch return null;
        if (loaded != content.len) return null;
        return content;
    }

    fn loader(self: *FileLoader) luce.compile.Loader {
        return .{ .context = self, .loadFn = load };
    }
};

fn readWhole(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const size: usize = @intCast(try file.length(io));
    const content = try gpa.alloc(u8, size);
    errdefer gpa.free(content);
    const loaded = try file.readPositionalAll(io, content, 0);
    if (loaded != content.len) return error.ReadFailed;
    return content;
}

fn writeWhole(io: std.Io, path: []const u8, content: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writePositionalAll(io, content, 0);
    try file.sync(io);
}

test {
    _ = luce;
}
