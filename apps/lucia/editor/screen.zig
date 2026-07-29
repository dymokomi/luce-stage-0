//! The raw-terminal shell around the editor.
//!
//! This is the one file that touches the tty directly: termios raw
//! mode, the alternate screen, window size, and the byte-read loop
//! that feeds decoded keys to the editor.  Everything it drives is the
//! headless-testable Editor; a save request is bounced to the host
//! through the commit callback.

const std = @import("std");
const key_mod = @import("key.zig");
const editor_mod = @import("editor.zig");

const Editor = editor_mod.Editor;

pub const CommitFn = *const fn (context: *anyopaque, editor: *Editor) anyerror!void;

/// Run the editor over the controlling terminal until it finishes.
/// `commit` is called on every save request with the editor's current
/// clone and buffer; it reports back through editor.reportSave.
pub fn run(io: std.Io, editor: *Editor, commit: CommitFn, context: *anyopaque) !void {
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
    // Reads return after a tenth of a second so a lone Escape decodes.
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 1;
    try std.posix.tcsetattr(stdin_handle, .FLUSH, raw);
    defer std.posix.tcsetattr(stdin_handle, .FLUSH, saved) catch {};

    try out.writeAll("\x1b[?1049h"); // alternate screen
    try out.flush();
    defer {
        out.writeAll("\x1b[?1049l") catch {};
        out.flush() catch {};
    }

    var pending: [64]u8 = undefined;
    var pending_len: usize = 0;

    while (!editor.done) {
        const size = windowSize();
        editor.resize(size.rows, size.columns);

        // Full redraw each round: clear, draw.
        try out.writeAll("\x1b[2J\x1b[H");
        try editor.render(out);
        try out.flush();

        // Read whatever arrived and feed complete keys.
        const count = std.posix.read(stdin_handle, pending[pending_len..]) catch 0;
        pending_len += count;
        var consumed: usize = 0;
        while (consumed < pending_len) {
            const decoded = key_mod.decode(pending[consumed..pending_len]);
            if (decoded.used == 0) break;
            consumed += decoded.used;
            if (decoded.key == .none) continue;
            try editor.feed(decoded.key);
            if (editor.takeSaveRequest()) {
                try commit(context, editor);
            }
            if (editor.done) break;
        }
        std.mem.copyForwards(u8, pending[0..], pending[consumed..pending_len]);
        pending_len -= consumed;
    }
}

const Size = struct { rows: usize, columns: usize };

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
