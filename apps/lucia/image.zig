//! One Fabric image on host storage.
//!
//! The single place that creates and opens image files — the create
//! command, the open command, and script-created images (the
//! create_image fabric intent) all pass through here, so headless and
//! interactive paths cannot drift apart.

const std = @import("std");
const loom = @import("loom");

const Allocator = std.mem.Allocator;
const FileVolume = loom.volume.FileVolume;
const Store = loom.store.Store;

pub const default_pages = 64;

/// Create a fresh image at path: the volume, and an empty durable
/// Fabric snapshot inside it.
pub fn create(gpa: Allocator, io: std.Io, directory: std.Io.Dir, path: []const u8, pages: u64) !void {
    var file = try FileVolume.create(io, directory, path, pages);
    defer file.close();
    var store = try Store.create(gpa, file.volume());
    store.deinit();
}

// ---------------------------------------------------------------------------
// Opened
// ---------------------------------------------------------------------------
//
// An image opened for a session: the volume and the store over it.
//
pub const Opened = struct {
    file: FileVolume,
    store: Store,

    /// Fills self in place: the store keeps a pointer to self.file, so
    /// an Opened must never move once set up.
    pub fn setup(self: *Opened, gpa: Allocator, io: std.Io, directory: std.Io.Dir, path: []const u8) !void {
        self.file = try FileVolume.open(io, directory, path);
        errdefer self.file.close();
        self.store = try Store.open(gpa, self.file.volume());
    }

    pub fn deinit(self: *Opened) void {
        self.store.deinit();
        self.file.close();
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "create then open round-trips an empty fabric" {
    const io = testing.io;
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();

    try create(testing.allocator, io, scratch.dir, "fresh.img", 16);
    var opened: Opened = undefined;
    try opened.setup(testing.allocator, io, scratch.dir, "fresh.img");
    defer opened.deinit();
    try testing.expectEqual(@as(usize, 0), opened.store.count());
}
