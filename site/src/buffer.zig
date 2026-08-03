//! A growable byte buffer that carries its own allocator.
//!
//! The generator builds every page by appending to one of these, so
//! threading an `Allocator` through every `emit` call would be noise.
//! One owner, one `deinit`, no hidden state.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Buffer = @This();

gpa: Allocator,
bytes: std.ArrayList(u8) = .empty,

pub fn init(gpa: Allocator) Buffer {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Buffer) void {
    self.bytes.deinit(self.gpa);
}

/// The bytes written so far.  Borrowed: any later `add` may move them.
pub fn text(self: *const Buffer) []const u8 {
    return self.bytes.items;
}

pub fn add(self: *Buffer, chunk: []const u8) !void {
    try self.bytes.appendSlice(self.gpa, chunk);
}

pub fn addByte(self: *Buffer, byte: u8) !void {
    try self.bytes.append(self.gpa, byte);
}

pub fn print(self: *Buffer, comptime format: []const u8, arguments: anytype) !void {
    try self.bytes.print(self.gpa, format, arguments);
}

/// Append `chunk` with the five HTML metacharacters replaced.  Every
/// path that puts source text or program output into a page goes
/// through here; nothing on this site is written by anyone but the
/// repository, but a generator that escapes only sometimes is a
/// generator whose next author gets it wrong.
pub fn addEscaped(self: *Buffer, chunk: []const u8) !void {
    for (chunk) |byte| switch (byte) {
        '&' => try self.add("&amp;"),
        '<' => try self.add("&lt;"),
        '>' => try self.add("&gt;"),
        '"' => try self.add("&quot;"),
        '\'' => try self.add("&#39;"),
        else => try self.addByte(byte),
    };
}

/// Hand the bytes to the caller and reset to empty.
pub fn take(self: *Buffer) ![]u8 {
    return self.bytes.toOwnedSlice(self.gpa);
}

pub fn clear(self: *Buffer) void {
    self.bytes.clearRetainingCapacity();
}

test "escaping covers every metacharacter" {
    var buffer: Buffer = .init(std.testing.allocator);
    defer buffer.deinit();
    try buffer.addEscaped("<a href=\"x\">&'</a>");
    try std.testing.expectEqualStrings(
        "&lt;a href=&quot;x&quot;&gt;&amp;&#39;&lt;/a&gt;",
        buffer.text(),
    );
}
