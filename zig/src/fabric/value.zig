//! Typed Fabric values.
//!
//! A Value is a tagged union; text and bytes own their heap storage, so
//! every holder clones on copy and deinits on drop.  Large content lives
//! out of line behind a BlobRef rather than inside a Value.

const std = @import("std");
const texel_id = @import("texel_id.zig");

const Allocator = std.mem.Allocator;
const TexelId = texel_id.TexelId;

/// Wire values are fixed by the snapshot format; never reorder.
pub const ValueType = enum(u8) {
    none = 0,
    boolean = 1,
    int = 2,
    real = 3,
    text = 4,
    bytes = 5,
    texel = 6,
    blob = 7,
};

// ---------------------------------------------------------------------------
// BlobRef
// ---------------------------------------------------------------------------
//
// Content identifier and byte size for a blob stored outside a Value.
//
pub const BlobRef = struct {
    id: [id_size]u8 = @splat(0),
    size: u64 = 0,

    pub const id_size = 32;

    pub fn isUnset(self: BlobRef) bool {
        return std.mem.allEqual(u8, &self.id, 0);
    }

    pub fn eql(self: BlobRef, other: BlobRef) bool {
        return self.size == other.size and std.mem.eql(u8, &self.id, &other.id);
    }
};

// ---------------------------------------------------------------------------
// Value
// ---------------------------------------------------------------------------
//
// One typed Fabric value.  none represents no value.
//
pub const Value = union(ValueType) {
    none,
    boolean: bool,
    int: i64,
    real: f64,
    text: []u8,
    bytes: []u8,
    texel: TexelId,
    blob: BlobRef,

    pub fn initText(allocator: Allocator, content: []const u8) !Value {
        return .{ .text = try allocator.dupe(u8, content) };
    }

    pub fn initBytes(allocator: Allocator, content: []const u8) !Value {
        return .{ .bytes = try allocator.dupe(u8, content) };
    }

    pub fn clone(self: Value, allocator: Allocator) !Value {
        return switch (self) {
            .text => |content| .{ .text = try allocator.dupe(u8, content) },
            .bytes => |content| .{ .bytes = try allocator.dupe(u8, content) },
            else => self,
        };
    }

    pub fn deinit(self: *Value, allocator: Allocator) void {
        switch (self.*) {
            .text, .bytes => |content| allocator.free(content),
            else => {},
        }
        self.* = .none;
    }

    pub fn tag(self: Value) ValueType {
        return @as(ValueType, self);
    }

    pub fn eql(self: Value, other: Value) bool {
        if (self.tag() != other.tag()) return false;
        return switch (self) {
            .none => true,
            .boolean => |flag| flag == other.boolean,
            .int => |number| number == other.int,
            .real => |number| number == other.real,
            .text => |content| std.mem.eql(u8, content, other.text),
            .bytes => |content| std.mem.eql(u8, content, other.bytes),
            .texel => |id| id.eql(other.texel),
            .blob => |reference| reference.eql(other.blob),
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "values compare by tag and content" {
    const allocator = std.testing.allocator;

    var hello = try Value.initText(allocator, "hello");
    defer hello.deinit(allocator);
    var hello_too = try Value.initText(allocator, "hello");
    defer hello_too.deinit(allocator);
    var world = try Value.initText(allocator, "world");
    defer world.deinit(allocator);

    try std.testing.expect(hello.eql(hello_too));
    try std.testing.expect(!hello.eql(world));
    try std.testing.expect(!hello.eql(.{ .int = 4 }));
    try std.testing.expect((Value{ .int = 4 }).eql(.{ .int = 4 }));
    try std.testing.expect(!(Value{ .boolean = true }).eql(.{ .boolean = false }));
}

test "clone owns its own storage" {
    const allocator = std.testing.allocator;

    var original = try Value.initText(allocator, "material");
    var copied = try original.clone(allocator);
    original.deinit(allocator);
    defer copied.deinit(allocator);

    try std.testing.expectEqualStrings("material", copied.text);
}

test "blob refs are unset only when all id bytes are zero" {
    var reference: BlobRef = .{ .size = 9 };
    try std.testing.expect(reference.isUnset());
    reference.id[3] = 1;
    try std.testing.expect(!reference.isUnset());
}
