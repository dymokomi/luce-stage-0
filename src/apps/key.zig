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
    mouse: Mouse,
    /// Bracketed paste delimiters (`CSI 200~` / `CSI 201~`).  The host
    /// accumulates everything between them into one text event, so a
    /// paste is one edit rather than a keystroke replay.
    paste_begin,
    paste_end,
    none,
};

/// The mouse report a terminal sends in SGR mode.  Coordinates are zero
/// based, unlike the one-based coordinates in the escape sequence.  `button`
/// is 0 for left, 1 for middle and 2 for right; wheel reports use `value` of
/// +1 for up and -1 for down.  Modifier bits are shift=1, alt=2 and ctrl=4.
pub const Mouse = struct {
    kind: MouseKind,
    row: i64,
    column: i64,
    button: i64,
    modifiers: i64,
    value: i64 = 0,
};

pub const MouseKind = enum {
    press,
    release,
    drag,
    move,
    wheel,
};

pub const Decoded = struct {
    key: Key,
    used: usize,
    /// Modifier bits held with the key: shift=1, alt=2, ctrl=4 — the
    /// same encoding mouse reports already carry.  A ctrl+letter is
    /// not spelled here: the terminal sends it as a distinct C0 byte
    /// and it stays the distinct `control` key it always was.
    modifiers: i64 = 0,
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
    if (bytes[1] != '[' and bytes[1] != 'O') {
        // Alt sends the key it modifies behind an ESC prefix.  The
        // word-motion pair every terminal agrees on is `ESC b`/`ESC f`
        // (macOS Option-arrow), which *means* alt+left/alt+right; an
        // alt-modified erase arrives as `ESC BS`.  Anything else after
        // a bare ESC stays the escape key it always was.
        const follow: Decoded = switch (bytes[1]) {
            'b' => .{ .key = .left, .used = 2, .modifiers = 2 },
            'f' => .{ .key = .right, .used = 2, .modifiers = 2 },
            0x7f, 0x08 => .{ .key = .backspace, .used = 2, .modifiers = 2 },
            else => .{ .key = .escape, .used = 1 },
        };
        return follow;
    }
    if (bytes.len < 3) return .{ .key = .none, .used = 0 };
    if (bytes[2] == '<') return decodeMouse(bytes);

    // The general CSI key shape: an optional number, an optional
    // `;modifier`, and a final byte — `CSI A` and `CSI 1;2A` are one
    // grammar, not two.  The modifier parameter is one more than its
    // bits (xterm), so `;2` is shift and `;5` is ctrl.
    var at: usize = 2;
    var first: i64 = 0;
    var has_first = false;
    while (at < bytes.len and bytes[at] >= '0' and bytes[at] <= '9') : (at += 1) {
        if (first > 1000) return .{ .key = .none, .used = at };
        first = first * 10 + (bytes[at] - '0');
        has_first = true;
    }
    var modifiers: i64 = 0;
    if (at < bytes.len and bytes[at] == ';') {
        at += 1;
        var parameter: i64 = 0;
        while (at < bytes.len and bytes[at] >= '0' and bytes[at] <= '9') : (at += 1) {
            if (parameter > 1000) return .{ .key = .none, .used = at };
            parameter = parameter * 10 + (bytes[at] - '0');
        }
        if (parameter > 0) modifiers = parameter - 1;
    }
    if (at >= bytes.len) return .{ .key = .none, .used = 0 };
    const final = bytes[at];
    const used = at + 1;

    switch (final) {
        'A' => return .{ .key = .up, .used = used, .modifiers = modifiers },
        'B' => return .{ .key = .down, .used = used, .modifiers = modifiers },
        'C' => return .{ .key = .right, .used = used, .modifiers = modifiers },
        'D' => return .{ .key = .left, .used = used, .modifiers = modifiers },
        'H' => return .{ .key = .home, .used = used, .modifiers = modifiers },
        'F' => return .{ .key = .end, .used = used, .modifiers = modifiers },
        '~' => {
            const key: Key = switch (first) {
                1, 7 => .home,
                4, 8 => .end,
                3 => .delete,
                5 => .page_up,
                6 => .page_down,
                200 => .paste_begin,
                201 => .paste_end,
                else => .none,
            };
            return .{ .key = key, .used = used, .modifiers = modifiers };
        },
        else => return .{ .key = .none, .used = used },
    }
}

/// Decode an xterm SGR mouse report (`CSI < button;column;row M/m`).  The
/// escape sequence can arrive over several reads, so an incomplete report
/// answers `used = 0` and leaves the pending bytes in place.
fn decodeMouse(bytes: []const u8) Decoded {
    var at: usize = 3;
    const encoded_button = mouseNumber(bytes, &at) orelse return incompleteOrInvalid(bytes, at);
    if (!mouseSeparator(bytes, &at)) return incompleteOrInvalid(bytes, at);
    const encoded_column = mouseNumber(bytes, &at) orelse return incompleteOrInvalid(bytes, at);
    if (!mouseSeparator(bytes, &at)) return incompleteOrInvalid(bytes, at);
    const encoded_row = mouseNumber(bytes, &at) orelse return incompleteOrInvalid(bytes, at);
    if (at >= bytes.len) return .{ .key = .none, .used = 0 };
    const final = bytes[at];
    if (final != 'M' and final != 'm') return incompleteOrInvalid(bytes, at);

    const base = encoded_button & 3;
    var modifiers: i64 = 0;
    if (encoded_button & 4 != 0) modifiers |= 1;
    if (encoded_button & 8 != 0) modifiers |= 2;
    if (encoded_button & 16 != 0) modifiers |= 4;
    const wheel = encoded_button & 64 != 0;
    const motion = encoded_button & 32 != 0;
    const kind: MouseKind = if (wheel)
        .wheel
    else if (final == 'm')
        .release
    else if (motion and base == 3)
        .move
    else if (motion)
        .drag
    else
        .press;
    const button = if (wheel or base == 3) @as(i64, -1) else base;
    const value: i64 = if (!wheel)
        0
    else if (base == 0)
        1
    else if (base == 1)
        -1
    else
        0;

    return .{
        .key = .{ .mouse = .{
            .kind = kind,
            .row = if (encoded_row > 0) encoded_row - 1 else 0,
            .column = if (encoded_column > 0) encoded_column - 1 else 0,
            .button = button,
            .modifiers = modifiers,
            .value = value,
        } },
        .used = at + 1,
    };
}

fn mouseNumber(bytes: []const u8, at: *usize) ?i64 {
    if (at.* >= bytes.len or bytes[at.*] < '0' or bytes[at.*] > '9') return null;
    var value: i64 = 0;
    while (at.* < bytes.len and bytes[at.*] >= '0' and bytes[at.*] <= '9') : (at.* += 1) {
        const digit: i64 = bytes[at.*] - '0';
        if (value > @divTrunc(std.math.maxInt(i64) - digit, 10)) return null;
        value = value * 10 + digit;
    }
    return value;
}

fn mouseSeparator(bytes: []const u8, at: *usize) bool {
    if (at.* >= bytes.len) return false;
    if (bytes[at.*] != ';') return false;
    at.* += 1;
    return true;
}

fn incompleteOrInvalid(bytes: []const u8, at: usize) Decoded {
    if (at >= bytes.len) return .{ .key = .none, .used = 0 };
    return .{ .key = .none, .used = @min(at + 1, bytes.len) };
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

test "modified CSI sequences carry their modifier bits" {
    // Shift, alt, and ctrl arrive as the xterm `;parameter` — one more
    // than the bits — on the same finals the bare keys use.
    const shifted = decode("\x1b[1;2D");
    try std.testing.expectEqual(Key.left, shifted.key);
    try std.testing.expectEqual(@as(i64, 1), shifted.modifiers);
    try std.testing.expectEqual(@as(usize, 6), shifted.used);

    const worded = decode("\x1b[1;5C");
    try std.testing.expectEqual(Key.right, worded.key);
    try std.testing.expectEqual(@as(i64, 4), worded.modifiers);

    const both = decode("\x1b[1;6H");
    try std.testing.expectEqual(Key.home, both.key);
    try std.testing.expectEqual(@as(i64, 5), both.modifiers);

    const paged = decode("\x1b[5;2~");
    try std.testing.expectEqual(Key.page_up, paged.key);
    try std.testing.expectEqual(@as(i64, 1), paged.modifiers);

    // A bare key still carries no modifiers, and an incomplete
    // modified sequence waits for the rest.
    try std.testing.expectEqual(@as(i64, 0), decode("\x1b[D").modifiers);
    try std.testing.expectEqual(@as(usize, 0), decode("\x1b[1;2").used);
}

test "alt's ESC-prefixed word and erase keys decode as modified keys" {
    const back = decode("\x1bb");
    try std.testing.expectEqual(Key.left, back.key);
    try std.testing.expectEqual(@as(i64, 2), back.modifiers);

    const forward = decode("\x1bf");
    try std.testing.expectEqual(Key.right, forward.key);
    try std.testing.expectEqual(@as(i64, 2), forward.modifiers);

    const erase = decode("\x1b\x7f");
    try std.testing.expectEqual(Key.backspace, erase.key);
    try std.testing.expectEqual(@as(i64, 2), erase.modifiers);

    // Anything else behind a bare ESC is still the escape key.
    try std.testing.expectEqual(Key.escape, decode("\x1bq").key);
}

test "bracketed paste delimiters decode as markers" {
    try std.testing.expectEqual(Key.paste_begin, decode("\x1b[200~").key);
    try std.testing.expectEqual(Key.paste_end, decode("\x1b[201~").key);
    try std.testing.expectEqual(@as(usize, 6), decode("\x1b[200~").used);
}

test "SGR mouse reports decode into zero-based events" {
    const pressed = decode("\x1b[<0;11;7M").key.mouse;
    try std.testing.expectEqual(MouseKind.press, pressed.kind);
    try std.testing.expectEqual(@as(i64, 6), pressed.row);
    try std.testing.expectEqual(@as(i64, 10), pressed.column);
    try std.testing.expectEqual(@as(i64, 0), pressed.button);
    try std.testing.expectEqual(@as(i64, 0), pressed.modifiers);

    const dragged = decode("\x1b[<41;3;4M").key.mouse;
    try std.testing.expectEqual(MouseKind.drag, dragged.kind);
    try std.testing.expectEqual(@as(i64, 2), dragged.column);
    try std.testing.expectEqual(@as(i64, 2), dragged.modifiers);

    const wheel = decode("\x1b[<64;5;9M").key.mouse;
    try std.testing.expectEqual(MouseKind.wheel, wheel.kind);
    try std.testing.expectEqual(@as(i64, 1), wheel.value);
    try std.testing.expectEqual(@as(i64, -1), wheel.button);

    try std.testing.expectEqual(MouseKind.release, decode("\x1b[<0;11;7m").key.mouse.kind);
    try std.testing.expectEqual(@as(usize, 0), decode("\x1b[<0;11").used);
}
