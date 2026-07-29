//! The lucia app: create a Fabric image, or open one into the terminal.
//!
//! Two boundaries: a setup boundary (lucia create IMAGE [--pages N]) and
//! a load boundary (lucia open IMAGE) that drops into the interactive
//! terminal over the opened Fabric.

const std = @import("std");
const loom = @import("loom");
const command_line = @import("command_line.zig");
const terminal_mod = @import("terminal.zig");
const image = @import("image.zig");
const luce_service = @import("luce_service.zig");

const Store = loom.store.Store;

const default_pages = image.default_pages;

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
    // lucia run FILE.luc — a standalone Luce script; the script itself
    // creates images with create_image.  lucia --luce FILE is sugar.
    if (std.mem.eql(u8, line.command, "run") or std.mem.eql(u8, line.command, "--luce")) {
        var out_writer = std.Io.File.stdout().writer(io, &.{});
        const source = readScript(gpa, io, path) catch {
            try err.print("lucia: cannot read {s}\n", .{path});
            return 1;
        };
        defer gpa.free(source);
        return runStandalone(gpa, io, .cwd(), &out_writer.interface, err, source);
    }
    return usage(err);
}

fn usage(err: *std.Io.Writer) !u8 {
    try err.print(
        "usage:\n" ++
            "  lucia create IMAGE [--pages N]\n" ++
            "  lucia open IMAGE [--luce FILE]\n" ++
            "  lucia run FILE.luc\n",
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
    image.create(gpa, io, .cwd(), path, pages) catch
        return cannot(err, "create", path);
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
    var opened: image.Opened = undefined;
    opened.setup(gpa, io, .cwd(), path) catch
        return cannot(err, "open", path);
    defer opened.deinit();
    const store = &opened.store;

    var out_buffer: [4096]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(io, &out_buffer);
    const out = &out_writer.interface;

    var terminal: terminal_mod.Terminal = undefined;
    try terminal.setup(gpa, io, store, .cwd(), out, err);
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

/// Run a standalone Luce script: compile with fabric enabled, create
/// the images it asks for, and apply its texel intents into the first
/// created image — the same service and image paths the terminal uses.
pub fn runStandalone(
    gpa: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    source: []const u8,
) !u8 {
    var service = luce_service.LuceService.init(gpa);
    defer service.deinit();

    switch (try service.runScript(source)) {
        .ok => {},
        .diagnostics => |rendered| {
            defer gpa.free(rendered);
            try err.print("lucia: luce compile failed\n{s}", .{rendered});
            return 1;
        },
        .trap => |message| {
            defer gpa.free(message);
            try err.print("lucia: luce trap: {s}\n", .{message});
            return 1;
        },
    }

    const images = service.takePendingImages();
    defer {
        for (images) |*intent| {
            var owned = intent.*;
            owned.deinit(gpa);
        }
        gpa.free(images);
    }
    for (images) |intent| {
        image.create(gpa, io, base, intent.path, intent.pages) catch {
            try err.print("lucia: cannot create image {s}\n", .{intent.path});
            return 1;
        };
        try out.print("created image {s}\n", .{intent.path});
    }

    if (service.pending.items.len != 0) {
        if (images.len == 0) {
            try err.print(
                "lucia: the script creates texels but no image; call create_image first, or use lucia open IMAGE --luce FILE\n",
                .{},
            );
            return 1;
        }
        var opened: image.Opened = undefined;
        opened.setup(gpa, io, base, images[0].path) catch {
            try err.print("lucia: cannot open image {s}\n", .{images[0].path});
            return 1;
        };
        defer opened.deinit();

        const applied = service.applyTexels(io, &opened.store) catch {
            try err.print("lucia: fabric intents failed to commit\n", .{});
            return 1;
        };
        defer {
            for (applied) |made| gpa.free(made.name);
            gpa.free(applied);
        }
        for (applied) |made| {
            var buffer: [loom.texel_id.TexelId.text_size]u8 = undefined;
            try out.print("created {s} {s}\n", .{ made.name, made.id.format(&buffer)[0..8] });
        }
    }
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

test "run mode: a script creates its image and weaves texels into it" {
    const allocator = std.testing.allocator;
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(allocator);
    defer err.deinit();

    const code = try runStandalone(allocator, std.testing.io, scratch.dir, &out.writer, &err.writer,
        \\fn evaluate():
        \\    create_image("woven.img", 32)
        \\    let t = create_texel("greeter")
        \\    texel_output(t, "text", "text")
        \\    texel_set(t, "text", "hello from a script")
        \\
    );
    try std.testing.expectEqual(@as(u8, 0), code);
    const printed = out.written();
    try std.testing.expect(std.mem.indexOf(u8, printed, "created image woven.img") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "created greeter") != null);

    // The woven image persists: reopen and find the texel.
    var opened: image.Opened = undefined;
    try opened.setup(allocator, std.testing.io, scratch.dir, "woven.img");
    defer opened.deinit();
    try std.testing.expectEqual(@as(usize, 1), opened.store.count());

    // Texels with no image is a reported error.
    var bad_err: std.Io.Writer.Allocating = .init(allocator);
    defer bad_err.deinit();
    const failed = try runStandalone(allocator, std.testing.io, scratch.dir, &out.writer, &bad_err.writer,
        \\fn evaluate():
        \\    let t = create_texel("orphan")
        \\
    );
    try std.testing.expectEqual(@as(u8, 1), failed);
    try std.testing.expect(std.mem.indexOf(u8, bad_err.written(), "no image") != null);
}

test {
    _ = @import("command_line.zig");
    _ = @import("terminal.zig");
    _ = @import("image.zig");
    _ = @import("ops.zig");
    _ = @import("editor/key.zig");
    _ = @import("editor/buffer.zig");
    _ = @import("editor/highlight.zig");
    _ = @import("editor/editor.zig");
}
