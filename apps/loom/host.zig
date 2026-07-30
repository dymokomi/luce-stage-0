//! The loom host: the trusted boundary behind the Luce host builtins.
//!
//! Programs describe console lines, file paths, and screen drawing;
//! this file owns the real terminal.  Raw mode and the alternate
//! screen engage lazily on the first terminal builtin, every frame is
//! buffered and presented on flush (or before blocking on a key), and
//! program text is sanitized so a Luce program can never emit raw
//! escape sequences — the host writes every control byte itself.

const std = @import("std");
const luce = @import("luce");
const key_mod = @import("key.zig");

const Allocator = std.mem.Allocator;

/// One program run's host services.  Must not move after `host()` is
/// taken (the vtable captures a pointer): use the in-place setup
/// pattern and call `deinit` (which restores the screen) when done.
pub const Host = struct {
    gpa: Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    arguments: []const []const u8,
    screen: Screen,

    pub fn setup(
        self: *Host,
        gpa: Allocator,
        io: std.Io,
        out: *std.Io.Writer,
        arguments: []const []const u8,
    ) void {
        self.* = .{
            .gpa = gpa,
            .io = io,
            .out = out,
            .arguments = arguments,
            .screen = .{},
        };
    }

    pub fn deinit(self: *Host) void {
        self.restoreScreen();
        self.screen.buffer.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn host(self: *Host) luce.backend.Host {
        return .{
            .context = self,
            .printFn = printLine,
            .argCountFn = argCount,
            .argFn = argAt,
            .readFileFn = readFile,
            .writeFileFn = writeFile,
            .fileExistsFn = fileExists,
            .terminal = .{
                .context = self,
                .rowsFn = rows,
                .colsFn = cols,
                .clearFn = clear,
                .moveFn = move,
                .styleFn = style,
                .writeFn = write,
                .flushFn = flush,
                .keyFn = key,
            },
        };
    }

    /// Leave the alternate screen and raw mode; safe to call twice.
    /// The runner calls this before reporting traps so messages land
    /// on the ordinary screen.
    pub fn restoreScreen(self: *Host) void {
        if (!self.screen.active) return;
        self.screen.active = false;
        self.out.writeAll("\x1b[0m\x1b[?25h\x1b[?1049l") catch {};
        self.out.flush() catch {};
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.screen.saved) catch {};
    }

    // -- console, arguments, files ------------------------------------

    fn printLine(context: *anyopaque, text: []const u8) error{OutOfMemory}!void {
        const self: *Host = @ptrCast(@alignCast(context));
        // A print while the screen is active would scribble over the
        // frame; route it through the frame buffer as plain text.
        if (self.screen.active) {
            try appendSanitized(&self.screen.buffer, self.gpa, text);
            try self.screen.buffer.appendSlice(self.gpa, "\r\n");
            return;
        }
        var failed = false;
        self.out.writeAll(text) catch {
            failed = true;
        };
        self.out.writeAll("\n") catch {
            failed = true;
        };
        self.out.flush() catch {
            failed = true;
        };
        if (failed) return; // a broken pipe must not kill the evaluation
    }

    fn argCount(context: *anyopaque) u32 {
        const self: *Host = @ptrCast(@alignCast(context));
        return @intCast(self.arguments.len);
    }

    fn argAt(context: *anyopaque, arena: Allocator, index: u32) error{OutOfMemory}!?[]const u8 {
        const self: *Host = @ptrCast(@alignCast(context));
        if (index >= self.arguments.len) return null;
        return try arena.dupe(u8, self.arguments[index]);
    }

    fn readFile(context: *anyopaque, arena: Allocator, path: []const u8) error{OutOfMemory}!luce.backend.FileRead {
        const self: *Host = @ptrCast(@alignCast(context));
        const file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch return .failed;
        defer file.close(self.io);
        const size: usize = @intCast(file.length(self.io) catch return .failed);
        if (size > max_file_size) return .failed;
        const content = try arena.alloc(u8, size);
        const loaded = file.readPositionalAll(self.io, content, 0) catch return .failed;
        if (loaded != content.len) return .failed;
        return .{ .content = content };
    }

    fn writeFile(context: *anyopaque, path: []const u8, content: []const u8) bool {
        const self: *Host = @ptrCast(@alignCast(context));
        const file = std.Io.Dir.cwd().createFile(self.io, path, .{ .truncate = true }) catch return false;
        defer file.close(self.io);
        file.writePositionalAll(self.io, content, 0) catch return false;
        file.sync(self.io) catch return false;
        return true;
    }

    fn fileExists(context: *anyopaque, path: []const u8) bool {
        const self: *Host = @ptrCast(@alignCast(context));
        const file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch return false;
        file.close(self.io);
        return true;
    }

    // -- the screen ----------------------------------------------------

    fn ensureScreen(self: *Host) error{OutOfMemory}!void {
        if (self.screen.active) return;
        const saved = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch return;
        var raw = saved;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 1;
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw) catch return;
        self.screen.saved = saved;
        self.screen.active = true;
        self.out.writeAll("\x1b[?1049h\x1b[2J\x1b[H") catch {};
        self.out.flush() catch {};
    }

    fn rows(context: *anyopaque) i64 {
        _ = context;
        return windowSize().rows;
    }

    fn cols(context: *anyopaque) i64 {
        _ = context;
        return windowSize().columns;
    }

    fn clear(context: *anyopaque) error{OutOfMemory}!void {
        const self: *Host = @ptrCast(@alignCast(context));
        try self.ensureScreen();
        try self.screen.buffer.appendSlice(self.gpa, "\x1b[?25l\x1b[2J\x1b[H");
    }

    fn move(context: *anyopaque, row: i64, col: i64) error{OutOfMemory}!void {
        const self: *Host = @ptrCast(@alignCast(context));
        try self.ensureScreen();
        var encoded: [32]u8 = undefined;
        const sequence = std.fmt.bufPrint(&encoded, "\x1b[{d};{d}H", .{
            std.math.clamp(row, 0, 9998) + 1,
            std.math.clamp(col, 0, 9998) + 1,
        }) catch unreachable;
        try self.screen.buffer.appendSlice(self.gpa, sequence);
    }

    fn style(context: *anyopaque, foreground: i64, background: i64, bold: bool) error{OutOfMemory}!void {
        const self: *Host = @ptrCast(@alignCast(context));
        try self.ensureScreen();
        try appendStyle(&self.screen.buffer, self.gpa, foreground, background, bold);
    }

    fn write(context: *anyopaque, text: []const u8) error{OutOfMemory}!void {
        const self: *Host = @ptrCast(@alignCast(context));
        try self.ensureScreen();
        try appendSanitized(&self.screen.buffer, self.gpa, text);
    }

    fn flush(context: *anyopaque) error{OutOfMemory}!void {
        const self: *Host = @ptrCast(@alignCast(context));
        try self.ensureScreen();
        try self.present();
    }

    fn present(self: *Host) error{OutOfMemory}!void {
        try self.screen.buffer.appendSlice(self.gpa, "\x1b[?25h");
        self.out.writeAll(self.screen.buffer.items) catch {};
        self.out.flush() catch {};
        self.screen.buffer.clearRetainingCapacity();
    }

    fn key(context: *anyopaque, arena: Allocator) error{OutOfMemory}!luce.backend.KeyEvent {
        const self: *Host = @ptrCast(@alignCast(context));
        try self.ensureScreen();
        // Present whatever the program drew before blocking: key_read
        // is the natural end of a frame.
        if (self.screen.buffer.items.len != 0) try self.present();

        while (true) {
            if (self.screen.pending_used != 0) {
                std.mem.copyForwards(
                    u8,
                    self.screen.pending[0..],
                    self.screen.pending[self.screen.pending_used..self.screen.pending_len],
                );
                self.screen.pending_len -= self.screen.pending_used;
                self.screen.pending_used = 0;
            }
            const decoded = key_mod.decode(self.screen.pending[0..self.screen.pending_len]);
            if (decoded.used != 0) {
                self.screen.pending_used = decoded.used;
                if (try keyEvent(arena, decoded.key)) |event| return event;
                continue;
            }
            const count = std.posix.read(
                std.posix.STDIN_FILENO,
                self.screen.pending[self.screen.pending_len..],
            ) catch 0;
            self.screen.pending_len += count;
        }
    }

    const Screen = struct {
        active: bool = false,
        saved: std.posix.termios = undefined,
        buffer: std.ArrayList(u8) = .empty,
        pending: [64]u8 = undefined,
        pending_len: usize = 0,
        pending_used: usize = 0,
    };
};

const max_file_size = 64 * 1024 * 1024;

/// Map a decoded key to its stable Luce-visible event, or null for
/// bytes that decode to nothing a program should see.
fn keyEvent(arena: Allocator, decoded: key_mod.Key) error{OutOfMemory}!?luce.backend.KeyEvent {
    return switch (decoded) {
        .text => |text| .{ .name = "text", .text = try arena.dupe(u8, text) },
        .enter => .{ .name = "enter" },
        .tab => .{ .name = "tab" },
        .backspace => .{ .name = "backspace" },
        .delete => .{ .name = "delete" },
        .up => .{ .name = "up" },
        .down => .{ .name = "down" },
        .left => .{ .name = "left" },
        .right => .{ .name = "right" },
        .home => .{ .name = "home" },
        .end => .{ .name = "end" },
        .page_up => .{ .name = "page_up" },
        .page_down => .{ .name = "page_down" },
        .escape => .{ .name = "escape" },
        .control => |letter| blk: {
            const name = try arena.alloc(u8, 6);
            @memcpy(name[0..5], "ctrl_");
            name[5] = letter;
            break :blk .{ .name = name };
        },
        .none => null,
    };
}

/// Append one SGR run: reset, then bold and 256-color foreground and
/// background as requested.  Negative color indices mean default.
fn appendStyle(
    buffer: *std.ArrayList(u8),
    gpa: Allocator,
    foreground: i64,
    background: i64,
    bold: bool,
) error{OutOfMemory}!void {
    try buffer.appendSlice(gpa, "\x1b[0m");
    if (bold) try buffer.appendSlice(gpa, "\x1b[1m");
    var encoded: [24]u8 = undefined;
    if (foreground >= 0 and foreground <= 255) {
        const sequence = std.fmt.bufPrint(&encoded, "\x1b[38;5;{d}m", .{foreground}) catch unreachable;
        try buffer.appendSlice(gpa, sequence);
    }
    if (background >= 0 and background <= 255) {
        const sequence = std.fmt.bufPrint(&encoded, "\x1b[48;5;{d}m", .{background}) catch unreachable;
        try buffer.appendSlice(gpa, sequence);
    }
}

/// Append UTF-8 display text without letting the program smuggle
/// terminal controls.  Newline becomes a real line break (CR LF in raw
/// mode); every other C0, DEL, C1, or malformed sequence becomes `?`.
fn appendSanitized(
    buffer: *std.ArrayList(u8),
    gpa: Allocator,
    text: []const u8,
) error{OutOfMemory}!void {
    var offset: usize = 0;
    while (offset < text.len) {
        const first = text[offset];
        if (first == '\n') {
            try buffer.appendSlice(gpa, "\r\n");
            offset += 1;
            continue;
        }
        const sequence_length = std.unicode.utf8ByteSequenceLength(first) catch {
            try buffer.append(gpa, '?');
            offset += 1;
            continue;
        };
        const length: usize = sequence_length;
        if (offset + length > text.len) {
            try buffer.append(gpa, '?');
            break;
        }
        const sequence = text[offset .. offset + length];
        const codepoint = std.unicode.utf8Decode(sequence) catch {
            try buffer.append(gpa, '?');
            offset += 1;
            continue;
        };
        if (codepoint < 0x20 or (codepoint >= 0x7f and codepoint <= 0x9f)) {
            try buffer.append(gpa, '?');
        } else {
            try buffer.appendSlice(gpa, sequence);
        }
        offset += length;
    }
}

const Size = struct {
    rows: i64,
    columns: i64,
};

fn windowSize() Size {
    var size: std.posix.winsize = undefined;
    const request = std.posix.T.IOCGWINSZ;
    if (std.posix.system.ioctl(std.posix.STDOUT_FILENO, request, @intFromPtr(&size)) == 0 and
        size.row != 0 and size.col != 0)
    {
        return .{ .rows = size.row, .columns = size.col };
    }
    return .{ .rows = 24, .columns = 80 };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "program text cannot inject terminal controls" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(testing.allocator);
    try appendSanitized(&buffer, testing.allocator, "safe\x1b[2J\r\t λ \xc2\x9b tail\xff\nnext");
    try testing.expectEqualStrings("safe?[2J?? λ ? tail?\r\nnext", buffer.items);
}

test "styles render 256-color SGR runs and clamp to defaults" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(testing.allocator);
    try appendStyle(&buffer, testing.allocator, 114, 236, true);
    try appendStyle(&buffer, testing.allocator, -1, -1, false);
    try appendStyle(&buffer, testing.allocator, 999, 256, false);
    try testing.expectEqualStrings(
        "\x1b[0m\x1b[1m\x1b[38;5;114m\x1b[48;5;236m" ++ "\x1b[0m" ++ "\x1b[0m",
        buffer.items,
    );
}

test "decoded keys map to stable event names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text = (try keyEvent(arena.allocator(), .{ .text = "λ" })).?;
    try testing.expectEqualStrings("text", text.name);
    try testing.expectEqualStrings("λ", text.text);
    const save = (try keyEvent(arena.allocator(), .{ .control = 's' })).?;
    try testing.expectEqualStrings("ctrl_s", save.name);
    try testing.expectEqual(@as(?luce.backend.KeyEvent, null), try keyEvent(arena.allocator(), .none));
}
