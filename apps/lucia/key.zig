//! Raw terminal key events and escape-sequence decoding.

const std = @import("std");

pub const Key = union(enum) {
    text: []const u8,
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
    control: u8,
    none,
};

pub const Decoded = struct {
    key: Key,
    used: usize,
};

/// Decode one key from raw bytes.  Text borrows from `bytes`.
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
        else => {},
    }

    const size = utf8Size(first) orelse return .{ .key = .none, .used = 1 };
    if (bytes.len < size) return .{ .key = .none, .used = 0 };
    const text = bytes[0..size];
    if (!std.unicode.utf8ValidateSlice(text)) return .{ .key = .none, .used = 1 };
    return .{ .key = .{ .text = text }, .used = size };
}

fn utf8Size(first: u8) ?usize {
    return if (first >= 0x20 and first < 0x7f)
        1
    else if (first >= 0xc2 and first <= 0xdf)
        2
    else if (first >= 0xe0 and first <= 0xef)
        3
    else if (first >= 0xf0 and first <= 0xf4)
        4
    else
        null;
}

fn decodeEscape(bytes: []const u8) Decoded {
    if (bytes.len < 2) return .{ .key = .escape, .used = 1 };
    if (bytes[1] != '[' and bytes[1] != 'O') return .{ .key = .escape, .used = 1 };
    if (bytes.len < 3) return .{ .key = .none, .used = 0 };

    switch (bytes[2]) {
        'A' => return .{ .key = .up, .used = 3 },
        'B' => return .{ .key = .down, .used = 3 },
        'C' => return .{ .key = .right, .used = 3 },
        'D' => return .{ .key = .left, .used = 3 },
        'H' => return .{ .key = .home, .used = 3 },
        'F' => return .{ .key = .end, .used = 3 },
        '1', '3', '4', '5', '6', '7', '8' => {
            if (bytes.len < 4) return .{ .key = .none, .used = 0 };
            if (bytes[3] != '~') return .{ .key = .none, .used = 3 };
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

test "keys and printable UTF-8 decode from raw bytes" {
    try std.testing.expectEqualStrings("x", decode("x").key.text);
    try std.testing.expectEqualStrings("λ", decode("λ").key.text);
    try std.testing.expectEqual(Key.enter, decode("\r").key);
    try std.testing.expectEqual(Key{ .control = 's' }, decode(&.{19}).key);
    try std.testing.expectEqual(Key.up, decode("\x1b[A").key);
    try std.testing.expectEqual(Key.delete, decode("\x1b[3~").key);
    try std.testing.expectEqual(@as(usize, 0), decode(&.{0xce}).used);
}
