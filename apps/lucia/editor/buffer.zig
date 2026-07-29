//! The editor's text buffer: lines, a cursor, and Luce-aware editing.
//!
//! Plain line storage with the small set of operations a code editor
//! needs.  Auto-indent copies the previous line's leading spaces and
//! deepens by four after a line ending in ':' — matching Luce's
//! indentation rule.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const indent_width = 4;

pub const Buffer = struct {
    allocator: Allocator,
    lines: std.ArrayList(std.ArrayList(u8)) = .empty,
    row: usize = 0,
    column: usize = 0,
    changed: bool = false,

    pub fn init(allocator: Allocator, initial: []const u8) !Buffer {
        var buffer: Buffer = .{ .allocator = allocator };
        errdefer buffer.deinit();
        var rest = initial;
        while (true) {
            const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse {
                try buffer.appendLine(rest);
                break;
            };
            try buffer.appendLine(rest[0..line_end]);
            rest = rest[line_end + 1 ..];
            if (rest.len == 0) break;
        }
        if (buffer.lines.items.len == 0) try buffer.appendLine("");
        return buffer;
    }

    fn appendLine(self: *Buffer, slice: []const u8) !void {
        var fresh: std.ArrayList(u8) = .empty;
        errdefer fresh.deinit(self.allocator);
        try fresh.appendSlice(self.allocator, slice);
        try self.lines.append(self.allocator, fresh);
    }

    pub fn deinit(self: *Buffer) void {
        for (self.lines.items) |*item| item.deinit(self.allocator);
        self.lines.deinit(self.allocator);
        self.* = undefined;
    }

    /// The whole buffer as one text, newline-terminated.  The caller
    /// owns it.
    pub fn text(self: *const Buffer) ![]u8 {
        var joined: std.ArrayList(u8) = .empty;
        errdefer joined.deinit(self.allocator);
        for (self.lines.items) |item| {
            try joined.appendSlice(self.allocator, item.items);
            try joined.append(self.allocator, '\n');
        }
        return joined.toOwnedSlice(self.allocator);
    }

    pub fn lineCount(self: *const Buffer) usize {
        return self.lines.items.len;
    }

    pub fn line(self: *const Buffer, index: usize) []const u8 {
        return self.lines.items[index].items;
    }

    fn currentLine(self: *Buffer) *std.ArrayList(u8) {
        return &self.lines.items[self.row];
    }

    fn clampColumn(self: *Buffer) void {
        const width = self.lines.items[self.row].items.len;
        if (self.column > width) self.column = width;
    }

    // Editing ---------------------------------------------------------------

    pub fn insert(self: *Buffer, character: u8) !void {
        try self.currentLine().insert(self.allocator, self.column, character);
        self.column += 1;
        self.changed = true;
    }

    pub fn insertSlice(self: *Buffer, slice: []const u8) !void {
        for (slice) |character| try self.insert(character);
    }

    /// Split the line at the cursor.  The new line starts with the old
    /// line's indentation, deepened by one step when the text before
    /// the cursor ends with ':'.
    pub fn newline(self: *Buffer) !void {
        const current = self.currentLine();
        const head = current.items[0..self.column];

        var indent: usize = 0;
        while (indent < head.len and head[indent] == ' ') indent += 1;
        var trimmed = std.mem.trimEnd(u8, head, " ");
        if (std.mem.endsWith(u8, trimmed, ":")) indent += indent_width;
        _ = &trimmed;

        var fresh: std.ArrayList(u8) = .empty;
        errdefer fresh.deinit(self.allocator);
        try fresh.appendNTimes(self.allocator, ' ', indent);
        try fresh.appendSlice(self.allocator, current.items[self.column..]);
        self.currentLine().shrinkRetainingCapacity(self.column);
        try self.lines.insert(self.allocator, self.row + 1, fresh);
        self.row += 1;
        self.column = indent;
        self.changed = true;
    }

    /// Backspace: delete before the cursor, joining lines at column 0.
    /// A pure-indent head retreats one indent step at a time.
    pub fn backspace(self: *Buffer) !void {
        if (self.column == 0) {
            if (self.row == 0) return;
            var removed = self.lines.orderedRemove(self.row);
            defer removed.deinit(self.allocator);
            self.row -= 1;
            self.column = self.currentLine().items.len;
            try self.currentLine().appendSlice(self.allocator, removed.items);
            self.changed = true;
            return;
        }
        const head = self.currentLine().items[0..self.column];
        var step: usize = 1;
        if (self.column % indent_width == 0 and
            std.mem.trimEnd(u8, head, " ").len == 0 and self.column >= indent_width)
        {
            step = indent_width;
        }
        for (0..step) |_| {
            _ = self.currentLine().orderedRemove(self.column - 1);
            self.column -= 1;
        }
        self.changed = true;
    }

    /// Delete under the cursor, joining the next line at line end.
    pub fn delete(self: *Buffer) !void {
        const width = self.currentLine().items.len;
        if (self.column < width) {
            _ = self.currentLine().orderedRemove(self.column);
            self.changed = true;
            return;
        }
        if (self.row + 1 >= self.lines.items.len) return;
        var removed = self.lines.orderedRemove(self.row + 1);
        defer removed.deinit(self.allocator);
        try self.currentLine().appendSlice(self.allocator, removed.items);
        self.changed = true;
    }

    // Movement --------------------------------------------------------------

    pub fn up(self: *Buffer) void {
        if (self.row > 0) self.row -= 1;
        self.clampColumn();
    }

    pub fn down(self: *Buffer) void {
        if (self.row + 1 < self.lines.items.len) self.row += 1;
        self.clampColumn();
    }

    pub fn left(self: *Buffer) void {
        if (self.column > 0) {
            self.column -= 1;
        } else if (self.row > 0) {
            self.row -= 1;
            self.column = self.currentLine().items.len;
        }
    }

    pub fn right(self: *Buffer) void {
        if (self.column < self.currentLine().items.len) {
            self.column += 1;
        } else if (self.row + 1 < self.lines.items.len) {
            self.row += 1;
            self.column = 0;
        }
    }

    pub fn home(self: *Buffer) void {
        self.column = 0;
    }

    pub fn lineEnd(self: *Buffer) void {
        self.column = self.currentLine().items.len;
    }

    pub fn page(self: *Buffer, lines_down: isize) void {
        if (lines_down > 0) {
            self.row = @min(self.row + @as(usize, @intCast(lines_down)), self.lines.items.len - 1);
        } else {
            const back: usize = @intCast(-lines_down);
            self.row = if (self.row > back) self.row - back else 0;
        }
        self.clampColumn();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "buffer round-trips text and edits lines" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator, "fn evaluate():\n    output.x = 1\n");
    defer buffer.deinit();
    try testing.expectEqual(@as(usize, 2), buffer.lineCount());

    const round = try buffer.text();
    defer allocator.free(round);
    try testing.expectEqualStrings("fn evaluate():\n    output.x = 1\n", round);

    // Typing at the end of line 1.
    buffer.down();
    buffer.lineEnd();
    try buffer.insertSlice(" + 2");
    const edited = try buffer.text();
    defer allocator.free(edited);
    try testing.expect(std.mem.indexOf(u8, edited, "output.x = 1 + 2") != null);
}

test "newline auto-indents and deepens after a colon" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator, "fn evaluate():");
    defer buffer.deinit();
    buffer.lineEnd();
    try buffer.newline();
    try testing.expectEqual(@as(usize, 4), buffer.column);
    try buffer.insertSlice("if true:");
    try buffer.newline();
    try testing.expectEqual(@as(usize, 8), buffer.column);
    try buffer.insertSlice("x = 1");

    const text = try buffer.text();
    defer allocator.free(text);
    try testing.expectEqualStrings("fn evaluate():\n    if true:\n        x = 1\n", text);
}

test "backspace retreats indent steps and joins lines" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator, "fn f():\n        deep\nnext");
    defer buffer.deinit();

    // Cursor to start of "deep" (row 1, column 8): backspace removes
    // one whole indent step.
    buffer.down();
    buffer.column = 8;
    try buffer.backspace();
    try testing.expectEqual(@as(usize, 4), buffer.column);
    try testing.expectEqualStrings("    deep", buffer.line(1));

    // At column 0, backspace joins with the line above.
    buffer.home();
    try buffer.backspace();
    try testing.expectEqualStrings("fn f():    deep", buffer.line(0));
    try testing.expectEqual(@as(usize, 2), buffer.lineCount());
}
