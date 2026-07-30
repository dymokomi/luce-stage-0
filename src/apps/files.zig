//! File access shared by the luce and loom executables: whole-file
//! reads and writes, and the import loader that resolves
//! `import name` as NAME.luc beside the root source file.  One copy,
//! so the two programs can never drift on how imports resolve.

const std = @import("std");
const luce = @import("luce");

const Allocator = std.mem.Allocator;

/// Loads `import name` as NAME.luc next to the root source file.
pub const FileLoader = struct {
    io: std.Io,
    directory: []const u8,

    fn load(context: *anyopaque, arena: Allocator, name: []const u8) error{OutOfMemory}!?[]const u8 {
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

    pub fn loader(self: *FileLoader) luce.compile.Loader {
        return .{ .context = self, .loadFn = load };
    }
};

/// Read a whole file into caller-owned bytes.
pub fn readWhole(gpa: Allocator, io: std.Io, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const size: usize = @intCast(try file.length(io));
    const content = try gpa.alloc(u8, size);
    errdefer gpa.free(content);
    const loaded = try file.readPositionalAll(io, content, 0);
    if (loaded != content.len) return error.ReadFailed;
    return content;
}

/// Write (create or truncate) a whole file and sync it — durability
/// is never hidden from the caller, per the coding guide.
pub fn writeWhole(io: std.Io, path: []const u8, content: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writePositionalAll(io, content, 0);
    try file.sync(io);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "whole-file write then read round-trips; a missing file errors" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // tmpDir lives under .zig-cache/tmp/<sub>; files.zig resolves
    // paths relative to cwd, so build the cwd-relative prefix.
    const directory = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(directory);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/note.txt", .{directory});
    defer testing.allocator.free(path);

    try writeWhole(io, path, "hello loom");
    const read = try readWhole(testing.allocator, io, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("hello loom", read);

    const absent = try std.fmt.allocPrint(testing.allocator, "{s}/absent.txt", .{directory});
    defer testing.allocator.free(absent);
    try testing.expectError(error.FileNotFound, readWhole(testing.allocator, io, absent));
}

test "the import loader resolves NAME.luc beside the root and returns null otherwise" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(directory);
    const geo_path = try std.fmt.allocPrint(testing.allocator, "{s}/geo.luc", .{directory});
    defer testing.allocator.free(geo_path);
    try writeWhole(io, geo_path, "func area() -> Int:\n    return 4\n");

    var loader: FileLoader = .{ .io = io, .directory = directory };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const resolver = loader.loader();

    const found = try resolver.loadFn(resolver.context, arena.allocator(), "geo");
    try testing.expect(found != null);
    try testing.expect(std.mem.indexOf(u8, found.?, "return 4") != null);

    // An unknown module resolves to null (the caller reports the
    // missing import), not an error.
    const missing = try resolver.loadFn(resolver.context, arena.allocator(), "nope");
    try testing.expectEqual(@as(?[]const u8, null), missing);
}
