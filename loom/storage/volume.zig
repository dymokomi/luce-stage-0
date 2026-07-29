//! Fixed-size page stores.
//!
//! Every volume is a sequence of fixed pages; higher layers address
//! storage only through this unit.  Callers may assume that read and
//! write move exactly one page, that a write is not durable until flush
//! succeeds, and that page indexes are checked against the volume size.

const std = @import("std");

pub const page_size = 4096;

pub const Page = [page_size]u8;

pub const Error = error{
    OutOfRange,
    ReadFailed,
    WriteFailed,
    FlushFailed,
};

// ---------------------------------------------------------------------------
// Volume
// ---------------------------------------------------------------------------
//
// The one substitution point of the storage layer.  A tagged union rather
// than a vtable: the set of real volumes is closed and visible.
//
pub const Volume = union(enum) {
    memory: *MemoryVolume,
    file: *FileVolume,

    pub fn size(self: Volume) u64 {
        return switch (self) {
            .memory => |m| m.size(),
            .file => |f| f.size(),
        };
    }

    pub fn read(self: Volume, page_index: u64, destination: *Page) Error!void {
        return switch (self) {
            .memory => |m| m.read(page_index, destination),
            .file => |f| f.read(page_index, destination),
        };
    }

    pub fn write(self: Volume, page_index: u64, source: *const Page) Error!void {
        return switch (self) {
            .memory => |m| m.write(page_index, source),
            .file => |f| f.write(page_index, source),
        };
    }

    pub fn flush(self: Volume) Error!void {
        return switch (self) {
            .memory => |m| m.flush(),
            .file => |f| f.flush(),
        };
    }
};

// ---------------------------------------------------------------------------
// MemoryVolume
// ---------------------------------------------------------------------------
//
// Page store held entirely in memory; the substitution used by tests.
//
pub const MemoryVolume = struct {
    allocator: std.mem.Allocator,
    pages: []Page,

    pub fn init(allocator: std.mem.Allocator, page_count: u64) !MemoryVolume {
        const pages = try allocator.alloc(Page, page_count);
        for (pages) |*page| @memset(page, 0);
        return .{ .allocator = allocator, .pages = pages };
    }

    pub fn deinit(self: *MemoryVolume) void {
        self.allocator.free(self.pages);
        self.* = undefined;
    }

    pub fn size(self: *const MemoryVolume) u64 {
        return self.pages.len;
    }

    pub fn read(self: *const MemoryVolume, page_index: u64, destination: *Page) Error!void {
        if (page_index >= self.pages.len) return Error.OutOfRange;
        @memcpy(destination, &self.pages[page_index]);
    }

    pub fn write(self: *MemoryVolume, page_index: u64, source: *const Page) Error!void {
        if (page_index >= self.pages.len) return Error.OutOfRange;
        @memcpy(&self.pages[page_index], source);
    }

    pub fn flush(self: *MemoryVolume) Error!void {
        _ = self;
    }

    pub fn volume(self: *MemoryVolume) Volume {
        return .{ .memory = self };
    }
};

// ---------------------------------------------------------------------------
// FileVolume
// ---------------------------------------------------------------------------
//
// Page store backed by one host file (for example lucia.img).  Anything
// that may block crosses the explicit Io handed in at create or open —
// the volume is the storage layer's boundary to the host.  The hot path
// stays visible: positional read, positional write, sync.
//
pub const FileVolume = struct {
    io: std.Io,
    file: std.Io.File,
    pages: u64,

    /// Open a brand-new zero-filled image, replacing any existing file.
    pub fn create(io: std.Io, directory: std.Io.Dir, path: []const u8, page_count: u64) !FileVolume {
        const file = try directory.createFile(io, path, .{ .read = true, .truncate = true });
        errdefer file.close(io);

        const zero: Page = @splat(0);
        var index: u64 = 0;
        while (index < page_count) : (index += 1) {
            try file.writePositionalAll(io, &zero, index * page_size);
        }
        try file.sync(io);
        return .{ .io = io, .file = file, .pages = page_count };
    }

    /// Open an existing image.  File size must be a multiple of the page size.
    pub fn open(io: std.Io, directory: std.Io.Dir, path: []const u8) !FileVolume {
        const file = try directory.openFile(io, path, .{ .mode = .read_write });
        errdefer file.close(io);

        const byte_size = try file.length(io);
        if (byte_size % page_size != 0) return error.BadImageSize;
        return .{ .io = io, .file = file, .pages = byte_size / page_size };
    }

    pub fn close(self: *FileVolume) void {
        self.file.close(self.io);
        self.* = undefined;
    }

    pub fn size(self: *const FileVolume) u64 {
        return self.pages;
    }

    pub fn read(self: *const FileVolume, page_index: u64, destination: *Page) Error!void {
        if (page_index >= self.pages) return Error.OutOfRange;
        const got = self.file.readPositionalAll(self.io, destination, page_index * page_size) catch
            return Error.ReadFailed;
        if (got != page_size) return Error.ReadFailed;
    }

    pub fn write(self: *FileVolume, page_index: u64, source: *const Page) Error!void {
        if (page_index >= self.pages) return Error.OutOfRange;
        self.file.writePositionalAll(self.io, source, page_index * page_size) catch
            return Error.WriteFailed;
    }

    pub fn flush(self: *FileVolume) Error!void {
        self.file.sync(self.io) catch return Error.FlushFailed;
    }

    pub fn volume(self: *FileVolume) Volume {
        return .{ .file = self };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "memory volume reads back writes and checks bounds" {
    var memory = try MemoryVolume.init(std.testing.allocator, 4);
    defer memory.deinit();
    const v = memory.volume();

    try std.testing.expectEqual(@as(u64, 4), v.size());

    var page: Page = @splat(0xab);
    try v.write(2, &page);
    try v.flush();

    var loaded: Page = @splat(0);
    try v.read(2, &loaded);
    try std.testing.expectEqualSlices(u8, &page, &loaded);

    try v.read(0, &loaded);
    try std.testing.expectEqual(@as(u8, 0), loaded[0]);

    try std.testing.expectError(Error.OutOfRange, v.read(4, &loaded));
    try std.testing.expectError(Error.OutOfRange, v.write(4, &page));
}

test "file volume persists across close and reopen" {
    const io = std.testing.io;
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();

    var page: Page = @splat(0x5c);
    {
        var file = try FileVolume.create(io, scratch.dir, "test.img", 3);
        defer file.close();
        const v = file.volume();

        try std.testing.expectEqual(@as(u64, 3), v.size());
        try v.write(1, &page);
        try v.flush();
    }
    {
        var file = try FileVolume.open(io, scratch.dir, "test.img");
        defer file.close();
        const v = file.volume();

        try std.testing.expectEqual(@as(u64, 3), v.size());
        var loaded: Page = @splat(0);
        try v.read(1, &loaded);
        try std.testing.expectEqualSlices(u8, &page, &loaded);
        try std.testing.expectError(Error.OutOfRange, v.read(3, &loaded));
    }
}

test "file volume rejects a truncated image" {
    const io = std.testing.io;
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();

    const file = try scratch.dir.createFile(io, "odd.img", .{});
    try file.writePositionalAll(io, &[_]u8{ 1, 2, 3 }, 0);
    file.close(io);

    try std.testing.expectError(error.BadImageSize, FileVolume.open(io, scratch.dir, "odd.img"));
}
