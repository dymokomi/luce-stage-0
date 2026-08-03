//! The loom host: the trusted boundary behind the Luce host builtins.
//!
//! Programs describe console lines, file paths, and screen drawing;
//! this file owns the real terminal.  Raw mode and the alternate
//! screen engage lazily on the first terminal builtin, every frame is
//! buffered and presented on flush (or before blocking on a key), and
//! program text is sanitized so a Luce program can never emit raw
//! escape sequences — the host writes every control byte itself.
//!
//! The same services are offered twice, over one implementation: as
//! `luce.backend.Host` for the interpreter, and as `luce.llvm.abi`'s
//! C table for a compiled artifact.  Only the calling convention
//! differs — what a program can reach is decided once, here.

const std = @import("std");
const luce = @import("luce");
const key_mod = @import("key.zig");

const Allocator = std.mem.Allocator;
const abi = luce.llvm.abi;

/// How many nested Luce calls loom allows before a program traps
/// `call_depth_exceeded`.  Depth is policy, not a native-stack
/// accident, and the policy is the host's: this one number reaches the
/// interpreter as `backend.Budget.call_depth` and a compiled artifact
/// through the ABI's `call_depth` slot, so runaway recursion traps at
/// the same call whichever engine ran it.  Conservative on purpose —
/// deep enough for any reasonable program, shallow enough that a
/// runaway one reports promptly and well inside the machine's own
/// stack.
pub const call_depth: u32 = 128;

/// A reported trace keeps this many innermost frames; the rest are
/// counted.  The runtime caps at the same number, so this only has to
/// be able to hold what arrives.
const max_trace_frames = 64;

/// Room for the function and file names of a kept trace, copied
/// because everything a trap report hands over is borrowed for the
/// duration of the call.
const trace_text_bytes = 4096;

/// One program run's host services.  Must not move after `host()` or
/// `table()` is taken (both capture a pointer): use the in-place setup
/// pattern and call `deinit` (which restores the screen) when done.
pub const Host = struct {
    gpa: Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    arguments: []const []const u8,
    screen: Screen,
    /// Where `file_read` puts a file's bytes for the C table, which
    /// hands out borrows rather than allocations.  Reused per call.
    loaded_file: std.ArrayList(u8) = .empty,
    /// What a compiled artifact reported through the C table.  The
    /// interpreter answers with a `Result` instead, so these stay unset
    /// on that path.
    trap_code: ?luce.mir.TrapCode = null,
    trap_storage: [512]u8 = undefined,
    trap_length: usize = 0,
    /// The call trace that came with that trap, innermost first, with
    /// its names copied out of the borrowed report.
    trace_frames: [max_trace_frames]Reported.Frame = undefined,
    trace_count: usize = 0,
    /// Frames the runtime's cap cut, plus any this host had no room
    /// for — what "... N more frames" counts.
    trace_dropped: u32 = 0,
    trace_storage: [trace_text_bytes]u8 = undefined,
    trace_used: usize = 0,
    leaked: ?i64 = null,

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
        self.loaded_file.deinit(self.gpa);
        self.* = undefined;
    }

    /// The trap a compiled artifact reported, if it did.  The words are
    /// borrowed from this Host and last until the next run.
    pub fn reportedTrap(self: *const Host) ?Reported {
        return .{
            .code = self.trap_code orelse return null,
            .message = self.trap_storage[0..self.trap_length],
            .trace = self.trace_frames[0..self.trace_count],
            .dropped = self.trace_dropped,
        };
    }

    pub const Reported = struct {
        code: luce.mir.TrapCode,
        message: []const u8,
        /// Innermost first, the same order and shape the interpreter
        /// reports (`backend.Trap.trace`).
        trace: []const Frame,
        dropped: u32,

        /// One call, with its names copied into this Host.  A
        /// `--release` artifact reports line zero and still names the
        /// function.
        pub const Frame = struct {
            function: []const u8,
            source: []const u8,
            line: u32,
            column: u32,
        };
    };

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

    /// The same services as a C table, for a compiled artifact
    /// (`luce.llvm.abi`).  Every slot is filled: loom withholds
    /// nothing, and a host that withheld something would make the
    /// program trap `host_unavailable` rather than proceed.
    pub fn table(self: *Host) abi.Host {
        return .{
            .context = self,
            .print = cPrint,
            .trap = cTrap,
            .finished = cFinished,
            .file_read = cFileRead,
            .file_write = cFileWrite,
            .file_exists = cFileExists,
            .arg_count = cArgCount,
            .arg = cArg,
            .term_rows = cTermRows,
            .term_cols = cTermCols,
            .term_clear = cTermClear,
            .term_move = cTermMove,
            .term_style = cTermStyle,
            .term_write = cTermWrite,
            .term_flush = cTermFlush,
            .key_read = cKeyRead,
            .call_depth = cCallDepth,
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

    /// A whole file's bytes, or null when it could not be read.  The
    /// bytes live in this Host and are borrowed until the next read —
    /// which is what the C table hands out, and what the interpreter's
    /// callback copies into the evaluation arena.
    ///
    /// **The bytes must be valid UTF-8**, because they become a Luce
    /// `String` and the language promises that `s[a:b]` is checked
    /// against character boundaries and `len` counts characters.  A
    /// half-read JPEG would make both of those lies, and the trap they
    /// are supposed to raise would fire — or not — on the *contents*
    /// of a file rather than on anything the program did.  Source
    /// bytes have been through `01_source.prepare` since stage 1 was
    /// written; nothing was checking data.  A file that is not text
    /// answers null and the program traps `file_read_failed`, which is
    /// true: it could not be read *as a String*.
    ///
    /// Unlike source, data is **not** normalized: no BOM is stripped
    /// and no CRLF is rewritten.  `file_read` hands back the file, and
    /// a program that reads a CSV and writes it again must get the
    /// same bytes out.
    fn loadFile(self: *Host, path: []const u8) error{OutOfMemory}!?[]const u8 {
        const file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch return null;
        defer file.close(self.io);
        const size: usize = @intCast(file.length(self.io) catch return null);
        if (size > max_file_size) return null;
        self.loaded_file.clearRetainingCapacity();
        try self.loaded_file.resize(self.gpa, size);
        const loaded = file.readPositionalAll(self.io, self.loaded_file.items, 0) catch
            return null;
        if (loaded != size) return null;
        if (!std.unicode.utf8ValidateSlice(self.loaded_file.items)) return null;
        return self.loaded_file.items;
    }

    fn readFile(context: *anyopaque, arena: Allocator, path: []const u8) error{OutOfMemory}!luce.backend.FileRead {
        const self: *Host = @ptrCast(@alignCast(context));
        const found = (try self.loadFile(path)) orelse return .failed;
        return .{ .content = try arena.dupe(u8, found) };
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
        self.out.writeAll("\x1b[?1049h\x1b[0m\x1b[2J\x1b[H") catch {};
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
        // Reset styles before erasing: terminals fill cleared cells
        // with the *current* background, so clearing while the last
        // frame's colors are active would tint every empty cell.
        try self.screen.buffer.appendSlice(self.gpa, "\x1b[?25l\x1b[0m\x1b[2J\x1b[H");
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

    /// Block until one key arrives.  Both slices are borrowed until the
    /// next call: the name is static text or this Host's own storage,
    /// and the text points into the pending input.
    fn nextKey(self: *Host) error{OutOfMemory}!KeyView {
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
                if (keyView(&self.screen.control_name, decoded.key)) |view| return view;
                continue;
            }
            const count = std.posix.read(
                std.posix.STDIN_FILENO,
                self.screen.pending[self.screen.pending_len..],
            ) catch 0;
            self.screen.pending_len += count;
        }
    }

    fn key(context: *anyopaque, arena: Allocator) error{OutOfMemory}!luce.backend.KeyEvent {
        const self: *Host = @ptrCast(@alignCast(context));
        const view = try self.nextKey();
        return .{
            .name = try arena.dupe(u8, view.name),
            .text = try arena.dupe(u8, view.text),
        };
    }

    const Screen = struct {
        active: bool = false,
        saved: std.posix.termios = undefined,
        buffer: std.ArrayList(u8) = .empty,
        pending: [64]u8 = undefined,
        pending_len: usize = 0,
        pending_used: usize = 0,
        /// Where a control key's name ("ctrl_s") is written, so naming
        /// one costs no allocation.
        control_name: [6]u8 = undefined,
    };

    // -- the same services, as the C table ------------------------------
    //
    // A thin layer over the callbacks above and nothing more: the two
    // paths differ only in how a failure travels.  C cannot carry a Zig
    // error, so running out of memory answers `.exhausted` and the run
    // ends without a trap, because nothing about the program was wrong.

    fn of(context: ?*anyopaque) *Host {
        return @ptrCast(@alignCast(context.?));
    }

    fn cPrint(context: ?*anyopaque, text: [*]const u8, length: i64) callconv(.c) abi.Answer {
        printLine(context.?, text[0..@intCast(length)]) catch return .exhausted;
        return .yes;
    }

    fn cTrap(
        context: ?*anyopaque,
        code: i32,
        message: [*]const u8,
        message_length: i64,
        frames: [*]const abi.TraceFrame,
        frame_count: i64,
        dropped: i64,
    ) callconv(.c) void {
        const self = of(context);
        const words = message[0..@intCast(message_length)];
        const kept = @min(words.len, self.trap_storage.len);
        self.trap_code = @enumFromInt(code);
        @memcpy(self.trap_storage[0..kept], words[0..kept]);
        self.trap_length = kept;

        self.trace_count = 0;
        self.trace_used = 0;
        self.trace_dropped = @intCast(dropped);
        for (frames[0..@intCast(frame_count)]) |frame| {
            const named = self.keepText(frame.function[0..@intCast(frame.function_length)]);
            const came_from = self.keepText(frame.source[0..@intCast(frame.source_length)]);
            if (self.trace_count == self.trace_frames.len or named == null or came_from == null) {
                self.trace_dropped +|= 1;
                continue;
            }
            self.trace_frames[self.trace_count] = .{
                .function = named.?,
                .source = came_from.?,
                .line = frame.line,
                .column = frame.column,
            };
            self.trace_count += 1;
        }
    }

    /// Copy borrowed trace text into this Host, or answer null when
    /// the pool is full — a frame nobody can name is a frame dropped,
    /// never a truncated name.
    fn keepText(self: *Host, text: []const u8) ?[]const u8 {
        if (self.trace_used + text.len > self.trace_storage.len) return null;
        const kept = self.trace_storage[self.trace_used..][0..text.len];
        @memcpy(kept, text);
        self.trace_used += text.len;
        return kept;
    }

    fn cFinished(context: ?*anyopaque, leaked: i64) callconv(.c) void {
        of(context).leaked = leaked;
    }

    /// The same limit the interpreter runs under, so a program that
    /// recurses away traps at the same call on either engine.
    fn cCallDepth(context: ?*anyopaque) callconv(.c) i64 {
        _ = context;
        return call_depth;
    }

    fn cFileRead(
        context: ?*anyopaque,
        path: [*]const u8,
        path_length: i64,
        text: *[*]const u8,
        length: *i64,
    ) callconv(.c) abi.Answer {
        const self = of(context);
        const found = (self.loadFile(path[0..@intCast(path_length)]) catch
            return .exhausted) orelse return .no;
        text.* = found.ptr;
        length.* = @intCast(found.len);
        return .yes;
    }

    fn cFileWrite(
        context: ?*anyopaque,
        path: [*]const u8,
        path_length: i64,
        content: [*]const u8,
        content_length: i64,
    ) callconv(.c) abi.Answer {
        const wrote = writeFile(
            context.?,
            path[0..@intCast(path_length)],
            content[0..@intCast(content_length)],
        );
        return if (wrote) .yes else .no;
    }

    fn cFileExists(
        context: ?*anyopaque,
        path: [*]const u8,
        path_length: i64,
    ) callconv(.c) abi.Answer {
        return if (fileExists(context.?, path[0..@intCast(path_length)])) .yes else .no;
    }

    fn cArgCount(context: ?*anyopaque) callconv(.c) i64 {
        return argCount(context.?);
    }

    fn cArg(
        context: ?*anyopaque,
        index: i64,
        text: *[*]const u8,
        length: *i64,
    ) callconv(.c) abi.Answer {
        const self = of(context);
        if (index < 0 or index >= self.arguments.len) return .no;
        const found = self.arguments[@intCast(index)];
        text.* = found.ptr;
        length.* = @intCast(found.len);
        return .yes;
    }

    fn cTermRows(context: ?*anyopaque) callconv(.c) i64 {
        return rows(context.?);
    }

    fn cTermCols(context: ?*anyopaque) callconv(.c) i64 {
        return cols(context.?);
    }

    fn cTermClear(context: ?*anyopaque) callconv(.c) abi.Answer {
        clear(context.?) catch return .exhausted;
        return .yes;
    }

    fn cTermMove(context: ?*anyopaque, row: i64, col: i64) callconv(.c) abi.Answer {
        move(context.?, row, col) catch return .exhausted;
        return .yes;
    }

    fn cTermStyle(
        context: ?*anyopaque,
        foreground: i64,
        background: i64,
        bold: i32,
    ) callconv(.c) abi.Answer {
        style(context.?, foreground, background, bold != 0) catch return .exhausted;
        return .yes;
    }

    fn cTermWrite(context: ?*anyopaque, text: [*]const u8, length: i64) callconv(.c) abi.Answer {
        write(context.?, text[0..@intCast(length)]) catch return .exhausted;
        return .yes;
    }

    fn cTermFlush(context: ?*anyopaque) callconv(.c) abi.Answer {
        flush(context.?) catch return .exhausted;
        return .yes;
    }

    fn cKeyRead(
        context: ?*anyopaque,
        name: *[*]const u8,
        name_length: *i64,
        text: *[*]const u8,
        text_length: *i64,
    ) callconv(.c) abi.Answer {
        const view = of(context).nextKey() catch return .exhausted;
        name.* = view.name.ptr;
        name_length.* = @intCast(view.name.len);
        text.* = view.text.ptr;
        text_length.* = @intCast(view.text.len);
        return .yes;
    }
};

const max_file_size = 64 * 1024 * 1024;

/// One decoded key as the host sees it, before either boundary copies
/// it: `name` is static text or `control_name`, `text` points into the
/// pending input buffer.
const KeyView = struct {
    name: []const u8,
    text: []const u8 = "",
};

/// Map a decoded key to its stable Luce-visible event, or null for
/// bytes that decode to nothing a program should see.  A control key's
/// name is written into `control_name`, which the caller owns.
fn keyView(control_name: *[6]u8, decoded: key_mod.Key) ?KeyView {
    return switch (decoded) {
        .text => |text| .{ .name = "text", .text = text },
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
            @memcpy(control_name[0..5], "ctrl_");
            control_name[5] = letter;
            break :blk .{ .name = control_name };
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

test "file_read refuses bytes that cannot be a String, and normalizes nothing" {
    var written: std.Io.Writer.Allocating = .init(testing.allocator);
    defer written.deinit();

    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory = path_storage[0..try scratch.dir.realPath(testing.io, &path_storage)];

    var host: Host = undefined;
    host.setup(testing.allocator, testing.io, &written.writer, &.{});
    defer host.deinit();

    const cases = [_]struct { name: []const u8, content: []const u8, readable: bool }{
        // Every shape the language would then be lying about: a lone
        // continuation byte, a truncated sequence, a NUL-riddled
        // binary, an overlong encoding.
        .{ .name = "loose.bin", .content = "ok\x80\n", .readable = false },
        .{ .name = "cut.bin", .content = "caf\xC3", .readable = false },
        .{ .name = "photo.jpg", .content = "\xFF\xD8\xFF\xE0\x00\x10", .readable = false },
        .{ .name = "overlong.bin", .content = "\xC0\xAF", .readable = false },
        // And what data is allowed to be, untouched: a BOM, CRLF, a
        // lone CR, an empty file.  Source normalizes these; data must
        // not, or a program that reads a file and writes it back
        // changes it.
        .{ .name = "windows.csv", .content = "\xEF\xBB\xBFa,b\r\nc,d\r\n", .readable = true },
        .{ .name = "classic.txt", .content = "one\rtwo\r", .readable = true },
        .{ .name = "empty.txt", .content = "", .readable = true },
        .{ .name = "unicode.txt", .content = "héllo — ok\n", .readable = true },
    };
    for (cases) |case| {
        const path = try std.fs.path.join(testing.allocator, &.{ directory, case.name });
        defer testing.allocator.free(path);
        try testing.expect(Host.writeFile(&host, path, case.content));

        const found = try host.loadFile(path);
        if (!case.readable) {
            try testing.expect(found == null);
            continue;
        }
        // Byte for byte: no BOM stripped, no CRLF rewritten.
        try testing.expectEqualStrings(case.content, found.?);
    }
}

test "decoded keys map to stable event names" {
    var control_name: [6]u8 = undefined;
    const text = keyView(&control_name, .{ .text = "λ" }).?;
    try testing.expectEqualStrings("text", text.name);
    try testing.expectEqualStrings("λ", text.text);
    const save = keyView(&control_name, .{ .control = 's' }).?;
    try testing.expectEqualStrings("ctrl_s", save.name);
    try testing.expectEqual(@as(?KeyView, null), keyView(&control_name, .none));
}

test "the C table offers every service, over the same implementation" {
    var written: std.Io.Writer.Allocating = .init(testing.allocator);
    defer written.deinit();

    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory = path_storage[0..try scratch.dir.realPath(testing.io, &path_storage)];
    const path = try std.fs.path.join(testing.allocator, &.{ directory, "notes.txt" });
    defer testing.allocator.free(path);

    var host: Host = undefined;
    host.setup(testing.allocator, testing.io, &written.writer, &.{ "alpha", "beta" });
    defer host.deinit();

    const table = host.table();
    // Fail-closed is a property of the *host*, not of the table shape:
    // loom withholds nothing, so no slot may be null.
    inline for (@typeInfo(abi.Host).@"struct".fields) |field| {
        if (@typeInfo(field.type) == .optional) {
            try testing.expect(@field(table, field.name) != null);
        }
    }

    try testing.expectEqual(@as(i64, 2), table.arg_count.?(table.context));
    var text: [*]const u8 = undefined;
    var length: i64 = undefined;
    try testing.expectEqual(abi.Answer.yes, table.arg.?(table.context, 1, &text, &length));
    try testing.expectEqualStrings("beta", text[0..@intCast(length)]);
    try testing.expectEqual(abi.Answer.no, table.arg.?(table.context, 2, &text, &length));

    try testing.expectEqual(
        abi.Answer.no,
        table.file_exists.?(table.context, path.ptr, @intCast(path.len)),
    );
    try testing.expectEqual(abi.Answer.yes, table.file_write.?(
        table.context,
        path.ptr,
        @intCast(path.len),
        "kept",
        4,
    ));
    try testing.expectEqual(
        abi.Answer.yes,
        table.file_exists.?(table.context, path.ptr, @intCast(path.len)),
    );
    try testing.expectEqual(
        abi.Answer.yes,
        table.file_read.?(table.context, path.ptr, @intCast(path.len), &text, &length),
    );
    try testing.expectEqualStrings("kept", text[0..@intCast(length)]);

    try testing.expectEqual(abi.Answer.yes, table.print.?(table.context, "hello", 5));
    try testing.expectEqualStrings("hello\n", written.written());

    try testing.expectEqual(@as(i64, call_depth), table.call_depth.?(table.context));

    // What a compiled artifact reports comes back through the Host:
    // the trap, and the call trace that came with it.
    try testing.expect(host.reportedTrap() == null);
    const frames = [_]abi.TraceFrame{
        .{
            .function = "divide",
            .function_length = 6,
            .source = "crash.luc",
            .source_length = 9,
            .line = 5,
            .column = 5,
        },
        .{
            .function = "main",
            .function_length = 4,
            .source = "crash.luc",
            .source_length = 9,
            .line = 12,
            .column = 5,
        },
    };
    table.trap(
        table.context,
        @intFromEnum(luce.mir.TrapCode.null_object),
        "boom",
        4,
        &frames,
        frames.len,
        9,
    );
    table.finished.?(table.context, 3);
    const reported = host.reportedTrap().?;
    try testing.expectEqual(luce.mir.TrapCode.null_object, reported.code);
    try testing.expectEqualStrings("boom", reported.message);
    try testing.expectEqual(@as(usize, 2), reported.trace.len);
    try testing.expectEqualStrings("divide", reported.trace[0].function);
    try testing.expectEqualStrings("crash.luc", reported.trace[0].source);
    try testing.expectEqual(@as(u32, 5), reported.trace[0].line);
    try testing.expectEqualStrings("main", reported.trace[1].function);
    try testing.expectEqual(@as(u32, 12), reported.trace[1].line);
    try testing.expectEqual(@as(u32, 9), reported.dropped);
    try testing.expectEqual(@as(?i64, 3), host.leaked);
}
