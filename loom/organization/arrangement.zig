//! Arrangements: contexts made of connections.
//!
//! An arrangement is an ordinary Texel whose content names and orders
//! other Texels — a document outline, folder, playlist, or workspace.
//! The same Texel may live in many arrangements without being copied;
//! names here are context-local and never identity.  The LARR content
//! encoding is a frozen contract shared with the C++ tree.

const std = @import("std");
const store_mod = @import("../fabric/store.zig");
const texel_id = @import("../fabric/texel_id.zig");
const value_mod = @import("../fabric/value.zig");
const texel_mod = @import("../fabric/texel.zig");

const Allocator = std.mem.Allocator;
const Store = store_mod.Store;
const TexelId = texel_id.TexelId;
const Value = value_mod.Value;
const Texel = texel_mod.Texel;

const magic = [4]u8{ 'L', 'A', 'R', 'R' };
const version: u8 = 1;
const header_size = 8;

pub const max_name_size = 255;
pub const max_entries = 4096;
pub const max_content_size = 1024 * 1024;

pub const Error = error{ InvalidArrangement, OutOfMemory };

// ---------------------------------------------------------------------------
// Entries
// ---------------------------------------------------------------------------
//
// A context-local name and the stable identity it references.
//
pub const Entry = struct {
    name: []u8,
    texel: TexelId,
};

pub const Entries = std.ArrayList(Entry);

pub fn deinitEntries(allocator: Allocator, entries: *Entries) void {
    for (entries.items) |entry| allocator.free(entry.name);
    entries.deinit(allocator);
}

fn validName(name: []const u8) bool {
    return name.len > 0 and name.len <= max_name_size and
        std.mem.findScalar(u8, name, 0) == null;
}

fn findEntry(entries: []const Entry, name: []const u8) ?usize {
    for (entries, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.name, name)) return index;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Content encoding
// ---------------------------------------------------------------------------

fn encodeEntries(allocator: Allocator, entries: []const Entry) Error![]u8 {
    if (entries.len > max_entries) return Error.InvalidArrangement;

    var encoded_size: usize = header_size;
    for (entries, 0..) |entry, index| {
        if (!validName(entry.name) or entry.texel.isUnset()) {
            return Error.InvalidArrangement;
        }
        if (findEntry(entries[0..index], entry.name) != null) {
            return Error.InvalidArrangement;
        }
        encoded_size += 1 + entry.name.len + TexelId.size;
        if (encoded_size > max_content_size) return Error.InvalidArrangement;
    }

    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try bytes.ensureTotalCapacity(allocator, encoded_size);
    try bytes.appendSlice(allocator, &magic);
    try bytes.append(allocator, version);
    try bytes.append(allocator, 0);
    try bytes.append(allocator, @intCast(entries.len & 0xff));
    try bytes.append(allocator, @intCast((entries.len >> 8) & 0xff));
    for (entries) |entry| {
        try bytes.append(allocator, @intCast(entry.name.len));
        try bytes.appendSlice(allocator, entry.name);
        try bytes.appendSlice(allocator, &entry.texel.bytes);
    }
    return bytes.toOwnedSlice(allocator);
}

fn decodeEntries(allocator: Allocator, bytes: []const u8) Error!Entries {
    if (bytes.len < header_size or bytes.len > max_content_size) {
        return Error.InvalidArrangement;
    }
    if (!std.mem.eql(u8, bytes[0..magic.len], &magic) or bytes[4] != version or
        bytes[5] != 0)
    {
        return Error.InvalidArrangement;
    }
    const entry_count = @as(usize, bytes[6]) | (@as(usize, bytes[7]) << 8);
    if (entry_count > max_entries) return Error.InvalidArrangement;

    var decoded: Entries = .empty;
    errdefer deinitEntries(allocator, &decoded);

    var offset: usize = header_size;
    var index: usize = 0;
    while (index < entry_count) : (index += 1) {
        if (offset >= bytes.len) return Error.InvalidArrangement;
        const name_size: usize = bytes[offset];
        offset += 1;
        if (name_size == 0 or name_size > bytes.len - offset or
            bytes.len - offset - name_size < TexelId.size)
        {
            return Error.InvalidArrangement;
        }

        const name = bytes[offset..][0..name_size];
        offset += name_size;
        var id: TexelId = .{};
        @memcpy(&id.bytes, bytes[offset..][0..TexelId.size]);
        offset += TexelId.size;

        if (!validName(name) or id.isUnset() or
            findEntry(decoded.items, name) != null)
        {
            return Error.InvalidArrangement;
        }
        const owned = try allocator.dupe(u8, name);
        errdefer allocator.free(owned);
        try decoded.append(allocator, .{ .name = owned, .texel = id });
    }

    if (offset != bytes.len) return Error.InvalidArrangement;
    return decoded;
}

fn write(allocator: Allocator, arrangement: *Texel, entries: []const Entry) Error!void {
    const bytes = try encodeEntries(allocator, entries);
    arrangement.setContent(allocator, .{ .bytes = bytes }) catch unreachable;
}

// ---------------------------------------------------------------------------
// Operations
// ---------------------------------------------------------------------------

/// Create an ordinary Texel with empty arrangement content.
pub fn create(allocator: Allocator, id: TexelId) Error!Texel {
    if (id.isUnset()) return Error.InvalidArrangement;
    var arrangement = Texel.init(id);
    errdefer arrangement.deinit(allocator);
    try write(allocator, &arrangement, &.{});
    return arrangement;
}

/// Strictly decode all arrangement content; the caller owns the result.
pub fn inspect(allocator: Allocator, arrangement: *const Texel) Error!Entries {
    const content = arrangement.content orelse return Error.InvalidArrangement;
    if (content.tag() != .bytes) return Error.InvalidArrangement;
    return decodeEntries(allocator, content.bytes);
}

/// Inspect, and additionally require every referenced Texel to exist.
pub fn validate(allocator: Allocator, arrangement: *const Texel, store: *const Store) Error!void {
    var entries = try inspect(allocator, arrangement);
    defer deinitEntries(allocator, &entries);
    for (entries.items) |entry| {
        if (!store.has(entry.texel)) return Error.InvalidArrangement;
    }
}

/// Append one named reference; the name must be new.
pub fn add(allocator: Allocator, arrangement: *Texel, name: []const u8, id: TexelId) Error!void {
    if (id.isUnset() or !validName(name)) return Error.InvalidArrangement;
    var entries = try inspect(allocator, arrangement);
    defer deinitEntries(allocator, &entries);
    if (findEntry(entries.items, name) != null) return Error.InvalidArrangement;

    const owned = try allocator.dupe(u8, name);
    errdefer allocator.free(owned);
    try entries.append(allocator, .{ .name = owned, .texel = id });
    try write(allocator, arrangement, entries.items);
}

/// Rename a context-local entry; identity is untouched.
pub fn rename(allocator: Allocator, arrangement: *Texel, name: []const u8, replacement: []const u8) Error!void {
    var entries = try inspect(allocator, arrangement);
    defer deinitEntries(allocator, &entries);
    const current = findEntry(entries.items, name) orelse
        return Error.InvalidArrangement;
    if (findEntry(entries.items, replacement)) |duplicate| {
        if (duplicate != current) return Error.InvalidArrangement;
    }

    const owned = try allocator.dupe(u8, replacement);
    allocator.free(entries.items[current].name);
    entries.items[current].name = owned;
    try write(allocator, arrangement, entries.items);
}

/// Move an entry to a new position, preserving the order of the rest.
pub fn reorder(allocator: Allocator, arrangement: *Texel, name: []const u8, index: usize) Error!void {
    var entries = try inspect(allocator, arrangement);
    defer deinitEntries(allocator, &entries);
    if (index >= entries.items.len) return Error.InvalidArrangement;
    const current = findEntry(entries.items, name) orelse
        return Error.InvalidArrangement;

    const moved = entries.orderedRemove(current);
    entries.insert(allocator, index, moved) catch |err| {
        allocator.free(moved.name);
        return err;
    };
    try write(allocator, arrangement, entries.items);
}

/// Remove one entry; the referenced Texel is untouched.
pub fn remove(allocator: Allocator, arrangement: *Texel, name: []const u8) Error!void {
    var entries = try inspect(allocator, arrangement);
    defer deinitEntries(allocator, &entries);
    const current = findEntry(entries.items, name) orelse
        return Error.InvalidArrangement;
    const removed = entries.orderedRemove(current);
    allocator.free(removed.name);
    try write(allocator, arrangement, entries.items);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "arrangements add, rename, reorder, remove, and round-trip" {
    const allocator = testing.allocator;
    const io = std.testing.io;

    var arrangement = try create(allocator, TexelId.generate(io));
    defer arrangement.deinit(allocator);

    const first = TexelId.generate(io);
    const second = TexelId.generate(io);
    try add(allocator, &arrangement, "chapter one", first);
    try add(allocator, &arrangement, "chapter two", second);
    try testing.expectError(
        Error.InvalidArrangement,
        add(allocator, &arrangement, "chapter one", TexelId.generate(io)),
    );

    var entries = try inspect(allocator, &arrangement);
    try testing.expectEqual(@as(usize, 2), entries.items.len);
    try testing.expectEqualStrings("chapter one", entries.items[0].name);
    try testing.expect(entries.items[0].texel.eql(first));
    deinitEntries(allocator, &entries);

    try rename(allocator, &arrangement, "chapter one", "prologue");
    try reorder(allocator, &arrangement, "prologue", 1);
    entries = try inspect(allocator, &arrangement);
    try testing.expectEqualStrings("chapter two", entries.items[0].name);
    try testing.expectEqualStrings("prologue", entries.items[1].name);
    try testing.expect(entries.items[1].texel.eql(first));
    deinitEntries(allocator, &entries);

    try remove(allocator, &arrangement, "chapter two");
    entries = try inspect(allocator, &arrangement);
    try testing.expectEqual(@as(usize, 1), entries.items.len);
    deinitEntries(allocator, &entries);

    try testing.expectError(
        Error.InvalidArrangement,
        remove(allocator, &arrangement, "chapter two"),
    );
}

test "validate requires every referenced texel to exist" {
    const allocator = testing.allocator;
    const io = std.testing.io;
    const volume_mod = @import("../storage/volume.zig");

    var memory = try volume_mod.MemoryVolume.init(allocator, 32);
    defer memory.deinit();
    var store = try Store.create(allocator, memory.volume());
    defer store.deinit();

    var member = Texel.init(TexelId.generate(io));
    defer member.deinit(allocator);
    var output = try texel_mod.OutputPort.init(allocator, "value", .text);
    try output.setSource(allocator, try Value.initText(allocator, "member"));
    try member.putOutput(allocator, output);
    {
        var transaction = try store.begin();
        defer transaction.deinit();
        try transaction.put(&member);
        try transaction.commit();
    }

    var arrangement = try create(allocator, TexelId.generate(io));
    defer arrangement.deinit(allocator);
    try add(allocator, &arrangement, "member", member.id);
    try validate(allocator, &arrangement, &store);

    try add(allocator, &arrangement, "ghost", TexelId.generate(io));
    try testing.expectError(
        Error.InvalidArrangement,
        validate(allocator, &arrangement, &store),
    );
}

test "decode rejects corruption and duplicates" {
    const allocator = testing.allocator;
    const io = std.testing.io;

    var arrangement = try create(allocator, TexelId.generate(io));
    defer arrangement.deinit(allocator);
    try add(allocator, &arrangement, "only", TexelId.generate(io));

    var broken = try arrangement.content.?.clone(allocator);
    defer broken.deinit(allocator);
    broken.bytes[0] ^= 1;
    try testing.expectError(Error.InvalidArrangement, decodeEntries(allocator, broken.bytes));

    const truncated = arrangement.content.?.bytes;
    try testing.expectError(
        Error.InvalidArrangement,
        decodeEntries(allocator, truncated[0 .. truncated.len - 1]),
    );
}
