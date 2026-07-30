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
