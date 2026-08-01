//! File access shared by the luce and loom executables: whole-file
//! reads and writes, and the import loader that resolves
//! `import name` as NAME.luc beside the root source file.  One copy,
//! so the two programs can never drift on how imports resolve.

const std = @import("std");
const builtin = @import("builtin");
const luce = @import("luce");

const Allocator = std.mem.Allocator;
const has_posix_permissions = builtin.os.tag != .windows and std.posix.mode_t != u0;
const max_image_file_size: u64 = 64 * 1024 * 1024;

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
    // A native image is an ambient executable cache, not the path the
    // user explicitly asked to run.  Never follow a final sidecar
    // symlink into an unrelated file; an unreadable link is simply a
    // cache miss to the runner and the atomic writer replaces the link
    // itself after regenerating the image.
    const image_cache = std.mem.endsWith(u8, path, ".lci");
    const file = try std.Io.Dir.cwd().openFile(io, path, .{
        .allow_directory = false,
        .follow_symlinks = !image_cache,
    });
    defer file.close(io);
    const file_size = if (image_cache) cache: {
        // Validate metadata on the opened handle, not the path: a
        // concurrent rename cannot swap in a different object between
        // this check and the read.
        const stat = try file.stat(io);
        if (stat.kind != .file) return error.AccessDenied;
        if (comptime has_posix_permissions) {
            if (stat.permissions.toMode() & 0o7777 != 0o600) {
                return error.AccessDenied;
            }
        }
        break :cache stat.size;
    } else try file.length(io);
    if (image_cache and file_size > max_image_file_size) return error.FileTooBig;
    const size = std.math.cast(usize, file_size) orelse return error.FileTooBig;
    const content = try gpa.alloc(u8, size);
    errdefer gpa.free(content);
    const loaded = try file.readPositionalAll(io, content, 0);
    if (loaded != content.len) return error.ReadFailed;
    return content;
}

/// Atomically replace a whole file and sync its contents.  Writing a
/// sibling temporary and renaming it means readers see either complete
/// version, a final symlink is replaced rather than followed, and an
/// error removes the temporary.  Native image caches are private to the
/// user; ordinary compiler outputs retain the platform's default mode.
pub fn writeWhole(io: std.Io, path: []const u8, content: []const u8) !void {
    const image_cache = std.mem.endsWith(u8, path, ".lci");
    const permissions: std.Io.File.Permissions = if (image_cache and has_posix_permissions)
        .fromMode(0o600)
    else
        .default_file;
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
        .permissions = permissions,
        .replace = true,
    });
    defer atomic.deinit(io);
    // POSIX creation honors umask.  Apply the requested private mode
    // on the still-private temporary so a restrictive/unusual umask
    // cannot make the writer produce a cache its reader rejects.
    if (comptime has_posix_permissions) {
        if (image_cache) try atomic.file.setPermissions(io, permissions);
    }
    try atomic.file.writePositionalAll(io, content, 0);
    try atomic.file.sync(io);
    try atomic.replace(io);
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

test "whole-file replacement is atomic and does not follow a cache symlink" {
    if (builtin.os.tag == .windows) return; // symlink creation needs privileges there
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(directory);
    const target_path = try std.fmt.allocPrint(testing.allocator, "{s}/target.txt", .{directory});
    defer testing.allocator.free(target_path);
    const cache_path = try std.fmt.allocPrint(testing.allocator, "{s}/program.lci", .{directory});
    defer testing.allocator.free(cache_path);

    try writeWhole(io, target_path, "sentinel");
    try std.Io.Dir.cwd().symLink(io, "target.txt", cache_path, .{});

    // Reads of an ambient executable cache reject the link rather than
    // accepting bytes from wherever it points.
    if (readWhole(testing.allocator, io, cache_path)) |unexpected| {
        testing.allocator.free(unexpected);
        return error.TestUnexpectedResult;
    } else |_| {}

    try writeWhole(io, cache_path, "first image");
    try writeWhole(io, cache_path, "second image");

    const target = try readWhole(testing.allocator, io, target_path);
    defer testing.allocator.free(target);
    try testing.expectEqualStrings("sentinel", target);
    const cache = try readWhole(testing.allocator, io, cache_path);
    defer testing.allocator.free(cache);
    try testing.expectEqualStrings("second image", cache);

    const cache_stat = try std.Io.Dir.cwd().statFile(io, cache_path, .{ .follow_symlinks = false });
    try testing.expectEqual(std.Io.File.Kind.file, cache_stat.kind);
    if (has_posix_permissions) {
        try testing.expectEqual(@as(std.posix.mode_t, 0o600), cache_stat.permissions.toMode() & 0o777);
    }
}

test "native image reads have a bounded allocation" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(directory);
    const cache_path = try std.fmt.allocPrint(testing.allocator, "{s}/oversized.lci", .{directory});
    defer testing.allocator.free(cache_path);

    try writeWhole(io, cache_path, "");
    const file = try std.Io.Dir.cwd().openFile(io, cache_path, .{ .mode = .read_write });
    defer file.close(io);
    // This is sparse on the test filesystems: it exercises the length
    // guard without allocating or writing a 64 MiB fixture.
    try file.setLength(io, max_image_file_size + 1);
    try testing.expectError(
        error.FileTooBig,
        readWhole(testing.allocator, io, cache_path),
    );
}

test "native image reads reject non-private permissions" {
    if (!has_posix_permissions) return;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(directory);
    const cache_path = try std.fmt.allocPrint(testing.allocator, "{s}/shared.lci", .{directory});
    defer testing.allocator.free(cache_path);

    try writeWhole(io, cache_path, "private image");
    const valid = try readWhole(testing.allocator, io, cache_path);
    testing.allocator.free(valid);
    {
        const file = try std.Io.Dir.cwd().openFile(io, cache_path, .{ .mode = .read_write });
        defer file.close(io);
        try file.setPermissions(io, .fromMode(0o644));
    }
    try testing.expectError(
        error.AccessDenied,
        readWhole(testing.allocator, io, cache_path),
    );
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
