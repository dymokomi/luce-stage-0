//! Stable 32-byte identity for a Texel.  The all-zero value is unset.
//! Identity is independent of name, path, machine, and presentation.

const std = @import("std");

pub const TexelId = struct {
    bytes: [size]u8 = @splat(0),

    pub const size = 32;
    pub const text_size = 64;

    pub const unset: TexelId = .{};

    /// Fresh identity from host entropy.  Randomness is nondeterminism,
    /// so it crosses the explicit Io boundary like any other effect.
    pub fn generate(io: std.Io) TexelId {
        var id: TexelId = .{};
        io.random(&id.bytes);
        if (id.isUnset()) {
            id.bytes[size - 1] = 1;
        }
        return id;
    }

    /// Parse exactly text_size lowercase or uppercase hex characters.
    pub fn parse(text: []const u8) ?TexelId {
        if (text.len != text_size) return null;

        var id: TexelId = .{};
        for (&id.bytes, 0..) |*byte, i| {
            const high = hexValue(text[i * 2]) orelse return null;
            const low = hexValue(text[i * 2 + 1]) orelse return null;
            byte.* = (high << 4) | low;
        }
        return id;
    }

    /// Format as lowercase hex into a caller-owned buffer.
    pub fn format(self: TexelId, buffer: *[text_size]u8) []const u8 {
        const hex = "0123456789abcdef";
        for (self.bytes, 0..) |byte, i| {
            buffer[i * 2] = hex[byte >> 4];
            buffer[i * 2 + 1] = hex[byte & 0x0f];
        }
        return buffer;
    }

    pub fn isUnset(self: TexelId) bool {
        return std.mem.allEqual(u8, &self.bytes, 0);
    }

    pub fn eql(self: TexelId, other: TexelId) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }

    pub fn lessThan(self: TexelId, other: TexelId) bool {
        return std.mem.order(u8, &self.bytes, &other.bytes) == .lt;
    }

    fn hexValue(character: u8) ?u8 {
        return switch (character) {
            '0'...'9' => character - '0',
            'a'...'f' => character - 'a' + 10,
            'A'...'F' => character - 'A' + 10,
            else => null,
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "generated ids are set, distinct, and round-trip through text" {
    const one = TexelId.generate(std.testing.io);
    const two = TexelId.generate(std.testing.io);
    try std.testing.expect(!one.isUnset());
    try std.testing.expect(!one.eql(two));

    var buffer: [TexelId.text_size]u8 = undefined;
    const text = one.format(&buffer);
    const parsed = TexelId.parse(text) orelse return error.ParseFailed;
    try std.testing.expect(parsed.eql(one));
}

test "parse rejects bad lengths and bad characters" {
    try std.testing.expect(TexelId.parse("abc") == null);
    var text: [TexelId.text_size]u8 = @splat('0');
    text[10] = 'g';
    try std.testing.expect(TexelId.parse(&text) == null);
}

test "ordering follows byte order" {
    var low: TexelId = .{};
    var high: TexelId = .{};
    low.bytes[0] = 1;
    high.bytes[0] = 2;
    try std.testing.expect(low.lessThan(high));
    try std.testing.expect(!high.lessThan(low));
    try std.testing.expect(!low.lessThan(low));
}
