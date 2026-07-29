//! Projection manifests — explicit, identity-free maps from Fabric
//! outputs to relative host filenames.
//!
//! A manifest names exactly which outputs a projection exposes and
//! where.  Filenames are relative, slash-separated, and may never
//! escape the projection root: absolute paths, `.`/`..` segments, and
//! backslashes are refused at put time.

const std = @import("std");
const texel_id = @import("../fabric/texel_id.zig");
const value_mod = @import("../fabric/value.zig");

const Allocator = std.mem.Allocator;
const TexelId = texel_id.TexelId;
const ValueType = value_mod.ValueType;

pub const Error = error{ OutOfMemory, InvalidEntry, DuplicateEntry };

/// A projected filename is relative and stays inside the root: no
/// leading or trailing slash, no empty, `.`, or `..` segments, and no
/// backslashes anywhere.
pub fn validFilename(filename: []const u8) bool {
    if (filename.len == 0 or filename[0] == '/' or filename[filename.len - 1] == '/') {
        return false;
    }
    var parts = std.mem.splitScalar(u8, filename, '/');
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
        if (std.mem.indexOfScalar(u8, part, '\\') != null) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------
//
// One Fabric output exposed as one relative host filename.  Only text
// and blob outputs project; everything else has no file shape.
//
pub const Entry = struct {
    texel: TexelId,
    output: []u8,
    declared: ValueType,
    filename: []u8,

    pub fn clone(self: Entry, allocator: Allocator) !Entry {
        const output = try allocator.dupe(u8, self.output);
        errdefer allocator.free(output);
        return .{
            .texel = self.texel,
            .output = output,
            .declared = self.declared,
            .filename = try allocator.dupe(u8, self.filename),
        };
    }

    pub fn deinit(self: *Entry, allocator: Allocator) void {
        allocator.free(self.output);
        allocator.free(self.filename);
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// Manifest
// ---------------------------------------------------------------------------

pub const Manifest = struct {
    entries: std.ArrayList(Entry) = .empty,

    pub fn deinit(self: *Manifest, allocator: Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(allocator);
        self.entries.deinit(allocator);
        self.* = undefined;
    }

    pub fn clone(self: *const Manifest, allocator: Allocator) !Manifest {
        var result: Manifest = .{};
        errdefer result.deinit(allocator);
        for (self.entries.items) |entry| {
            try result.entries.append(allocator, try entry.clone(allocator));
        }
        return result;
    }

    pub fn count(self: *const Manifest) usize {
        return self.entries.items.len;
    }

    pub fn at(self: *const Manifest, index: usize) ?*const Entry {
        if (index >= self.entries.items.len) return null;
        return &self.entries.items[index];
    }

    /// Add one output-to-filename mapping.  Refused when the entry is
    /// invalid, when the filename is already projected, or when the
    /// same output already projects elsewhere.
    pub fn put(
        self: *Manifest,
        allocator: Allocator,
        texel: TexelId,
        output: []const u8,
        declared: ValueType,
        filename: []const u8,
    ) Error!void {
        if (texel.isUnset() or output.len == 0) return error.InvalidEntry;
        if (declared != .text and declared != .blob) return error.InvalidEntry;
        if (!validFilename(filename)) return error.InvalidEntry;
        for (self.entries.items) |existing| {
            if (std.mem.eql(u8, existing.filename, filename)) return error.DuplicateEntry;
            if (existing.texel.eql(texel) and std.mem.eql(u8, existing.output, output)) {
                return error.DuplicateEntry;
            }
        }

        const owned_output = try allocator.dupe(u8, output);
        errdefer allocator.free(owned_output);
        const owned_filename = try allocator.dupe(u8, filename);
        errdefer allocator.free(owned_filename);
        try self.entries.append(allocator, .{
            .texel = texel,
            .output = owned_output,
            .declared = declared,
            .filename = owned_filename,
        });
    }

    pub fn hasFile(self: *const Manifest, filename: []const u8) bool {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.filename, filename)) return true;
        }
        return false;
    }

    /// True when some projected filename lives under the directory.
    pub fn hasDirectory(self: *const Manifest, dirname: []const u8) bool {
        for (self.entries.items) |entry| {
            if (entry.filename.len > dirname.len + 1 and
                std.mem.startsWith(u8, entry.filename, dirname) and
                entry.filename[dirname.len] == '/')
            {
                return true;
            }
        }
        return false;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "filenames must stay relative and inside the root" {
    try testing.expect(validFilename("notes/message.txt"));
    try testing.expect(validFilename("plain.txt"));
    try testing.expect(!validFilename(""));
    try testing.expect(!validFilename("/absolute"));
    try testing.expect(!validFilename("trailing/"));
    try testing.expect(!validFilename("../escape"));
    try testing.expect(!validFilename("a/../../escape"));
    try testing.expect(!validFilename("a//b"));
    try testing.expect(!validFilename("a/./b"));
    try testing.expect(!validFilename("a\\escape"));
}

test "manifest refuses invalid and duplicate entries" {
    const allocator = testing.allocator;
    var manifest: Manifest = .{};
    defer manifest.deinit(allocator);

    const first = TexelId.generate(testing.io);
    const second = TexelId.generate(testing.io);

    try manifest.put(allocator, first, "text", .text, "notes/message.txt");
    try manifest.put(allocator, second, "blob", .blob, "assets/data.bin");

    try testing.expectError(error.InvalidEntry, manifest.put(allocator, first, "text", .text, "/absolute"));
    try testing.expectError(error.InvalidEntry, manifest.put(allocator, first, "text", .bytes, "bytes.bin"));
    try testing.expectError(error.InvalidEntry, manifest.put(allocator, .unset, "text", .text, "unset.txt"));
    try testing.expectError(error.DuplicateEntry, manifest.put(allocator, second, "other", .blob, "assets/data.bin"));
    try testing.expectError(error.DuplicateEntry, manifest.put(allocator, first, "text", .text, "notes/other.txt"));

    try testing.expectEqual(@as(usize, 2), manifest.count());
    try testing.expect(manifest.hasFile("notes/message.txt"));
    try testing.expect(!manifest.hasFile("notes"));
    try testing.expect(manifest.hasDirectory("notes"));
    try testing.expect(manifest.hasDirectory("assets"));
    try testing.expect(!manifest.hasDirectory("else"));

    var copy = try manifest.clone(allocator);
    defer copy.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), copy.count());
    try testing.expectEqualStrings("notes/message.txt", copy.at(0).?.filename);
}
