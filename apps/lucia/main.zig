//! The lucia app: create a Fabric image, or open one into the terminal.
//!
//! Two boundaries: a setup boundary (lucia create IMAGE [--pages N]) and
//! a load boundary (lucia open IMAGE) that drops into the interactive
//! terminal over the opened Fabric.

const std = @import("std");
const loom = @import("loom");
const command_line = @import("command_line.zig");
const terminal_mod = @import("terminal.zig");

const FileVolume = loom.volume.FileVolume;
const Store = loom.store.Store;

const default_pages = 64;

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

    var line = try command_line.CommandLine.parse(gpa, arguments) orelse return usage(err);
    defer line.deinit(gpa);
    if (line.positionalCount() != 1) return usage(err);
    const path = line.positional(0).?;

    if (std.mem.eql(u8, line.command, "create")) {
        return runCreate(gpa, io, err, path, line.optionU64("--pages", default_pages));
    }
    if (std.mem.eql(u8, line.command, "open")) {
        var environ_map = try init.environ.createMap(gpa);
        defer environ_map.deinit();
        const no_color = environ_map.get("NO_COLOR") != null;
        const script_path = line.option("--luce", "");
        return runOpen(gpa, io, err, path, no_color, script_path);
    }
    return usage(err);
}

fn usage(err: *std.Io.Writer) !u8 {
    try err.print(
        "usage:\n" ++
            "  lucia create IMAGE [--pages N]\n" ++
            "  lucia open IMAGE [--luce FILE]\n",
        .{},
    );
    return 1;
}

fn runCreate(
    gpa: std.mem.Allocator,
    io: std.Io,
    err: *std.Io.Writer,
    path: []const u8,
    pages: u64,
) !u8 {
    var file = FileVolume.create(io, .cwd(), path, pages) catch
        return cannot(err, "create", path);
    defer file.close();
    var store = Store.create(gpa, file.volume()) catch
        return cannot(err, "create", path);
    store.deinit();

    var out_writer = std.Io.File.stdout().writer(io, &.{});
    try out_writer.interface.print("created {s}\n", .{path});
    return 0;
}

fn runOpen(
    gpa: std.mem.Allocator,
    io: std.Io,
    err: *std.Io.Writer,
    path: []const u8,
    no_color: bool,
    script_path: []const u8,
) !u8 {
    var file = FileVolume.open(io, .cwd(), path) catch
        return cannot(err, "open", path);
    defer file.close();
    var store = Store.open(gpa, file.volume()) catch
        return cannot(err, "open", path);
    defer store.deinit();

    var out_buffer: [4096]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(io, &out_buffer);
    const out = &out_writer.interface;

    var terminal: terminal_mod.Terminal = undefined;
    try terminal.setup(gpa, io, &store, out, err);
    defer terminal.deinit();

    const stdin = std.Io.File.stdin();
    const interactive = stdin.isTty(io) catch false;
    const colored = !no_color and (std.Io.File.stdout().isTty(io) catch false);
    terminal.session.palette = .{ .enabled = colored };

    // --luce FILE: run bootstrap source against the opened Fabric,
    // then drop into the terminal only when a person is attached.
    if (script_path.len != 0) {
        const source = readScript(gpa, io, script_path) catch {
            try err.print("lucia: cannot read {s}\n", .{script_path});
            return 1;
        };
        defer gpa.free(source);
        try terminal.script(source);
        if (!interactive) {
            try out.flush();
            return 0;
        }
    }

    var in_buffer: [4096]u8 = undefined;
    var reader = stdin.reader(io, &in_buffer);
    try terminal.run(&reader.interface, interactive);
    try out.flush();
    return 0;
}

fn readScript(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const size: usize = @intCast(try file.length(io));
    const source = try gpa.alloc(u8, size);
    errdefer gpa.free(source);
    const loaded = try file.readPositionalAll(io, source, 0);
    if (loaded != source.len) return error.ReadFailed;
    return source;
}

fn cannot(err: *std.Io.Writer, what: []const u8, path: []const u8) !u8 {
    try err.print("lucia: cannot {s} image {s}\n", .{ what, path });
    return 1;
}

test {
    _ = @import("command_line.zig");
    _ = @import("terminal.zig");
}
