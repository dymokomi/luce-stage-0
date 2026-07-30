//! Source positions for Luce diagnostics.
//!
//! Luce source lives inside a Texel, not a file: positions are byte
//! offsets plus derived line and column, so diagnostics stay stable
//! against an in-Texel source buffer.

const std = @import("std");

/// Half-open byte range into the source buffer.
pub const Span = struct {
    start: usize,
    end: usize,

    pub fn slice(self: Span, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

pub const Place = struct {
    line: usize, // 1-based
    column: usize, // 1-based, in bytes
};

/// Line and column of a byte offset, counting from 1.
pub fn place(source: []const u8, offset: usize) Place {
    var line: usize = 1;
    var column: usize = 1;
    const end = @min(offset, source.len);
    for (source[0..end]) |character| {
        if (character == '\n') {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
    }
    return .{ .line = line, .column = column };
}

test "place counts lines and columns from one" {
    const text = "ab\ncd\n";
    try std.testing.expectEqual(Place{ .line = 1, .column = 1 }, place(text, 0));
    try std.testing.expectEqual(Place{ .line = 1, .column = 3 }, place(text, 2));
    try std.testing.expectEqual(Place{ .line = 2, .column = 1 }, place(text, 3));
    try std.testing.expectEqual(Place{ .line = 3, .column = 1 }, place(text, 6));
}
