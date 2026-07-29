//! Capability-gated traditional-file reads for Luce.
//!
//! FileReader is the long-lived terminal boundary.  Every read decodes
//! its carried capability, verifies its exact directory grant, and
//! opens that directory relative to an explicit base.  ScriptHost is a
//! short-lived grant used only to implement script_directory().

const std = @import("std");
const loom = @import("loom");
const luce = @import("luce");

const Allocator = std.mem.Allocator;
const Authority = loom.capability.Authority;
const Capability = loom.capability.Capability;
const Value = loom.value.Value;

const operation = "file.read";
const max_file_size = 16 * 1024 * 1024;

/// Long-lived reader over one explicit base directory.  The base and
/// authority are borrowed and must outlive this value.
pub const FileReader = struct {
    io: std.Io,
    base: std.Io.Dir,
    authority: *Authority,

    pub const IssueError = error{
        InvalidScope,
        AccessFailed,
        OutOfMemory,
    };

    pub fn init(io: std.Io, base: std.Io.Dir, authority: *Authority) FileReader {
        return .{
            .io = io,
            .base = base,
            .authority = authority,
        };
    }

    pub fn host(self: *FileReader) luce.backend.Host {
        return .{
            .context = self,
            .readFileFn = readFile,
        };
    }

    /// Issue a session-local file.read grant for one exact directory
    /// below base.  The caller owns the returned capability.
    pub fn issue(self: *FileReader, scope: []const u8) IssueError!Capability {
        if (!validScope(scope)) return IssueError.InvalidScope;
        const directory = self.openScope(scope) catch return IssueError.AccessFailed;
        defer directory.close(self.io);
        return self.authority.issue(self.io, operation, scope) catch |mistake| switch (mistake) {
            error.OutOfMemory => IssueError.OutOfMemory,
            else => IssueError.InvalidScope,
        };
    }

    fn readFile(
        context: *anyopaque,
        arena: Allocator,
        encoded: []const u8,
        path: []const u8,
    ) error{OutOfMemory}!luce.backend.FileRead {
        const self: *FileReader = @ptrCast(@alignCast(context));
        return self.read(arena, encoded, path);
    }

    fn read(
        self: *FileReader,
        arena: Allocator,
        encoded: []const u8,
        path: []const u8,
    ) error{OutOfMemory}!luce.backend.FileRead {
        if (!validSibling(path)) return .denied;

        const bytes = try arena.dupe(u8, encoded);
        const value: Value = .{ .bytes = bytes };
        var capability = loom.capability.decodeCapability(arena, value) catch
            return .denied;
        defer capability.deinit(arena);
        if (!validScope(capability.scope) or
            !self.authority.verify(capability, operation, capability.scope))
        {
            return .denied;
        }

        const root = self.openScope(capability.scope) catch return .failed;
        defer root.close(self.io);
        const file = root.directory.openFile(self.io, path, .{
            .follow_symlinks = false,
            .allow_directory = false,
        }) catch return .failed;
        defer file.close(self.io);
        const status = file.stat(self.io) catch return .failed;
        if (status.kind != .file or status.nlink != 1 or status.size > max_file_size) {
            return .failed;
        }

        const content = try arena.alloc(u8, @intCast(status.size));
        const loaded = file.readPositionalAll(self.io, content, 0) catch
            return .failed;
        if (loaded != content.len or !std.unicode.utf8ValidateSlice(content)) {
            return .failed;
        }
        return .{ .content = content };
    }

    const ScopeDir = struct {
        directory: std.Io.Dir,
        owned: bool,

        fn close(self: ScopeDir, io: std.Io) void {
            if (self.owned) self.directory.close(io);
        }
    };

    /// Walk every component relative to base so no intermediate link
    /// can redirect the exact scope outside the trusted root.
    fn openScope(self: *FileReader, scope: []const u8) !ScopeDir {
        if (std.mem.eql(u8, scope, ".")) {
            return .{ .directory = self.base, .owned = false };
        }

        var directory = self.base;
        var owned = false;
        errdefer if (owned) directory.close(self.io);
        var parts = std.mem.splitScalar(u8, scope, '/');
        while (parts.next()) |part| {
            const child = try directory.openDir(self.io, part, .{
                .follow_symlinks = false,
            });
            if (owned) directory.close(self.io);
            directory = child;
            owned = true;
        }
        return .{ .directory = directory, .owned = owned };
    }
};

/// A one-run script_directory grant.  Setup fills this in place because
/// the backend callback retains its address.
pub const ScriptHost = struct {
    allocator: Allocator,
    reader: *FileReader,
    capability: Capability,
    encoded: Value,

    pub fn setup(
        self: *ScriptHost,
        allocator: Allocator,
        reader: *FileReader,
        script_path: []const u8,
    ) !void {
        const directory = directoryOf(script_path);
        var capability = try reader.issue(directory);
        errdefer {
            _ = reader.authority.revoke(capability);
            capability.deinit(allocator);
        }
        const encoded = try loom.capability.encodeCapability(allocator, capability);

        self.* = .{
            .allocator = allocator,
            .reader = reader,
            .capability = capability,
            .encoded = encoded,
        };
    }

    pub fn deinit(self: *ScriptHost) void {
        self.encoded.deinit(self.allocator);
        _ = self.reader.authority.revoke(self.capability);
        self.capability.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn host(self: *ScriptHost) luce.backend.Host {
        return .{
            .context = self,
            .readFileFn = readFile,
            .scriptDirectoryFn = scriptDirectory,
        };
    }

    fn scriptDirectory(
        context: *anyopaque,
        arena: Allocator,
    ) error{OutOfMemory}!?[]const u8 {
        const self: *ScriptHost = @ptrCast(@alignCast(context));
        return try arena.dupe(u8, self.encoded.bytes);
    }

    fn readFile(
        context: *anyopaque,
        arena: Allocator,
        encoded: []const u8,
        path: []const u8,
    ) error{OutOfMemory}!luce.backend.FileRead {
        const self: *ScriptHost = @ptrCast(@alignCast(context));
        return self.reader.read(arena, encoded, path);
    }
};

fn directoryOf(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return ".";
    if (slash == 0) return path[0..1];
    return path[0..slash];
}

fn validScope(scope: []const u8) bool {
    if (scope.len == 0 or scope.len > 4096) return false;
    if (std.mem.eql(u8, scope, ".")) return true;
    if (scope[0] == '/' or scope[scope.len - 1] == '/') return false;
    if (std.mem.findScalar(u8, scope, 0) != null or
        std.mem.findScalar(u8, scope, '\\') != null)
    {
        return false;
    }
    var parts = std.mem.splitScalar(u8, scope, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or
            std.mem.eql(u8, part, ".."))
        {
            return false;
        }
    }
    return true;
}

fn validSibling(path: []const u8) bool {
    if (path.len == 0 or path.len > 4096) return false;
    if (std.mem.eql(u8, path, ".") or std.mem.eql(u8, path, "..")) return false;
    return std.mem.findScalar(u8, path, 0) == null and
        std.mem.findScalar(u8, path, '/') == null and
        std.mem.findScalar(u8, path, '\\') == null;
}

test "file reader verifies exact scopes and confines reads to sibling files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();

    const sibling = try scratch.dir.createFile(io, "sibling.luc", .{});
    try sibling.writePositionalAll(io, "sibling source", 0);
    sibling.close(io);
    try scratch.dir.symLink(io, "sibling.luc", "linked.luc", .{});
    try scratch.dir.createDir(io, "real", .default_dir);
    try scratch.dir.symLink(io, "real", "linked-dir", .{});

    var authority = Authority.init(allocator);
    defer authority.deinit();
    var reader = FileReader.init(io, scratch.dir, &authority);
    try std.testing.expectError(FileReader.IssueError.AccessFailed, reader.issue("linked-dir"));
    var host: ScriptHost = undefined;
    try host.setup(allocator, &reader, "bootstrap.luc");
    defer host.deinit();
    try std.testing.expectEqual(@as(usize, 1), authority.count());

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const hosted = host.host();
    const encoded = (try hosted.scriptDirectoryFn.?(hosted.context, arena)).?;

    const loaded = try hosted.readFileFn(hosted.context, arena, encoded, "sibling.luc");
    try std.testing.expectEqualStrings("sibling source", loaded.content);
    try std.testing.expectEqual(
        luce.backend.FileRead.denied,
        try hosted.readFileFn(hosted.context, arena, encoded, "../sibling.luc"),
    );
    try std.testing.expectEqual(
        luce.backend.FileRead.failed,
        try hosted.readFileFn(hosted.context, arena, encoded, "linked.luc"),
    );
    try std.testing.expectEqual(
        luce.backend.FileRead.denied,
        try hosted.readFileFn(hosted.context, arena, "bad capability", "sibling.luc"),
    );

    var foreign = Authority.init(allocator);
    defer foreign.deinit();
    var foreign_capability = try foreign.issue(io, operation, ".");
    defer foreign_capability.deinit(allocator);
    var foreign_value = try loom.capability.encodeCapability(allocator, foreign_capability);
    defer foreign_value.deinit(allocator);
    try std.testing.expectEqual(
        luce.backend.FileRead.denied,
        try hosted.readFileFn(hosted.context, arena, foreign_value.bytes, "sibling.luc"),
    );
}

test "script host revokes its one-run grant" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();

    var authority = Authority.init(allocator);
    defer authority.deinit();
    var reader = FileReader.init(io, scratch.dir, &authority);
    var host: ScriptHost = undefined;
    try host.setup(allocator, &reader, "bootstrap.luc");
    try std.testing.expectEqual(@as(usize, 1), authority.count());
    host.deinit();
    try std.testing.expectEqual(@as(usize, 0), authority.count());
}
