//! Editor key events and escape-sequence decoding.

pub const Key = union(enum) {
    character: u8, // printable ASCII
    enter,
    tab,
    backspace,
    delete,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    escape,
    control: u8, // 'a'..'z' for Ctrl+letter
    none, // unrecognized or incomplete
};

pub const Decoded = struct { key: Key, used: usize };

/// Decode one key from raw bytes.  Returns the key and how many bytes
/// it consumed; an incomplete escape sequence consumes what it saw.
pub fn decode(bytes: []const u8) Decoded {
    if (bytes.len == 0) return .{ .key = .none, .used = 0 };
    const first = bytes[0];
    switch (first) {
        0x1b => return decodeEscape(bytes),
        '\r', '\n' => return .{ .key = .enter, .used = 1 },
        '\t' => return .{ .key = .tab, .used = 1 },
        0x7f, 0x08 => return .{ .key = .backspace, .used = 1 },
        1...7, 11, 12, 14...26 => return .{
            .key = .{ .control = 'a' + first - 1 },
            .used = 1,
        },
        else => {
            if (first >= 0x20 and first < 0x7f) {
                return .{ .key = .{ .character = first }, .used = 1 };
            }
            return .{ .key = .none, .used = 1 };
        },
    }
}

fn decodeEscape(bytes: []const u8) Decoded {
    if (bytes.len < 2) return .{ .key = .escape, .used = 1 };
    if (bytes[1] != '[' and bytes[1] != 'O') return .{ .key = .escape, .used = 1 };
    if (bytes.len < 3) return .{ .key = .escape, .used = 2 };

    switch (bytes[2]) {
        'A' => return .{ .key = .up, .used = 3 },
        'B' => return .{ .key = .down, .used = 3 },
        'C' => return .{ .key = .right, .used = 3 },
        'D' => return .{ .key = .left, .used = 3 },
        'H' => return .{ .key = .home, .used = 3 },
        'F' => return .{ .key = .end, .used = 3 },
        '1', '3', '4', '5', '6', '7', '8' => {
            if (bytes.len < 4 or bytes[3] != '~') return .{ .key = .none, .used = 3 };
            const key: Key = switch (bytes[2]) {
                '1', '7' => .home,
                '4', '8' => .end,
                '3' => .delete,
                '5' => .page_up,
                '6' => .page_down,
                else => .none,
            };
            return .{ .key = key, .used = 4 };
        },
        else => return .{ .key = .none, .used = 3 },
    }
}

const std = @import("std");

test "keys decode from raw bytes" {
    try std.testing.expectEqual(Key{ .character = 'x' }, decode("x").key);
    try std.testing.expectEqual(Key.enter, decode("\r").key);
    try std.testing.expectEqual(Key.backspace, decode(&.{0x7f}).key);
    try std.testing.expectEqual(Key{ .control = 's' }, decode(&.{19}).key);
    try std.testing.expectEqual(Key{ .control = 'q' }, decode(&.{17}).key);
    try std.testing.expectEqual(Key.up, decode("\x1b[A").key);
    try std.testing.expectEqual(Key.delete, decode("\x1b[3~").key);
    try std.testing.expectEqual(@as(usize, 4), decode("\x1b[3~").used);
    try std.testing.expectEqual(Key.escape, decode("\x1b").key);
}
