//! Raw-terminal shell for any app-level View presenter.

const std = @import("std");
const key_mod = @import("key.zig");
const view = @import("view.zig");

/// Present until the View returns quit.  The interface remains plain;
/// this shell alone emits terminal control sequences.
pub fn run(io: std.Io, presenter: *view.Presenter) !void {
    const stdin_handle = std.posix.STDIN_FILENO;
    var out_buffer: [8192]u8 = undefined;
    var out_writer = std.Io.File.stdout().writerStreaming(io, &out_buffer);
    const out = &out_writer.interface;

    const saved = try std.posix.tcgetattr(stdin_handle);
    var raw = saved;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = false;
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 1;
    try std.posix.tcsetattr(stdin_handle, .FLUSH, raw);
    defer std.posix.tcsetattr(stdin_handle, .FLUSH, saved) catch {};

    try out.writeAll("\x1b[?1049h\x1b[?25h");
    try out.flush();
    defer {
        out.writeAll("\x1b[?1049l") catch {};
        out.flush() catch {};
    }

    var pending: [64]u8 = undefined;
    var pending_len: usize = 0;
    var pending_used: usize = 0;
    var action: view.Action = actionFor(.none, windowSize());

    while (true) {
        const frame = try presenter.step(action);
        if (pending_used != 0) {
            std.mem.copyForwards(u8, pending[0..], pending[pending_used..pending_len]);
            pending_len -= pending_used;
            pending_used = 0;
        }
        try draw(out, frame);
        if (frame.quit) return;

        const count = std.posix.read(stdin_handle, pending[pending_len..]) catch 0;
        pending_len += count;
        const decoded = key_mod.decode(pending[0..pending_len]);
        if (decoded.used == 0) {
            action = actionFor(.none, windowSize());
            continue;
        }
        action = actionFor(decoded.key, windowSize());
        pending_used = decoded.used;
    }
}

fn draw(out: *std.Io.Writer, frame: view.Frame) !void {
    try out.writeAll("\x1b[2J\x1b[H");
    try writePlain(out, frame.interface);
    try out.print("\x1b[{d};{d}H", .{
        @min(@max(frame.cursor_row, 0), 9998) + 1,
        @min(@max(frame.cursor_col, 0), 9998) + 1,
    });
    try out.flush();
}

/// Write UTF-8 display text without allowing terminal controls from
/// the View. Newline is the only control in the interface protocol;
/// every other C0, DEL, C1, or malformed sequence becomes `?`.
fn writePlain(out: *std.Io.Writer, text: []const u8) !void {
    var offset: usize = 0;
    while (offset < text.len) {
        const first = text[offset];
        if (first == '\n') {
            try out.writeByte('\n');
            offset += 1;
            continue;
        }
        const sequence_length = std.unicode.utf8ByteSequenceLength(first) catch {
            try out.writeByte('?');
            offset += 1;
            continue;
        };
        const length: usize = sequence_length;
        if (offset + length > text.len) {
            try out.writeByte('?');
            break;
        }
        const sequence = text[offset .. offset + length];
        const codepoint = std.unicode.utf8Decode(sequence) catch {
            try out.writeByte('?');
            offset += 1;
            continue;
        };
        if (codepoint < 0x20 or (codepoint >= 0x7f and codepoint <= 0x9f)) {
            try out.writeByte('?');
        } else {
            try out.writeAll(sequence);
        }
        offset += length;
    }
}

fn actionFor(key: key_mod.Key, size: Size) view.Action {
    var action: view.Action = .{
        .rows = size.rows,
        .cols = size.columns,
    };
    switch (key) {
        .text => |text| {
            action.key = "text";
            action.text = text;
        },
        .enter => action.key = "enter",
        .tab => {
            action.key = "text";
            action.text = "    ";
        },
        .backspace => action.key = "backspace",
        .delete => action.key = "delete",
        .up => action.key = "up",
        .down => action.key = "down",
        .left => action.key = "left",
        .right => action.key = "right",
        .home => action.key = "home",
        .end => action.key = "end",
        .page_up => action.key = "page_up",
        .page_down => action.key = "page_down",
        .escape, .none => {},
        .control => |letter| switch (letter) {
            's' => action.key = "save",
            'q' => action.key = "quit",
            else => {},
        },
    }
    return action;
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

test "plain View text cannot inject terminal controls" {
    var rendered: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer rendered.deinit();
    try writePlain(
        &rendered.writer,
        "safe\x1b[2J\r\t λ \xc2\x9b tail\xff",
    );
    try std.testing.expectEqualStrings("safe?[2J?? λ ? tail?", rendered.written());
}
