//! The loom host: the trusted boundary behind the Luce host builtins.
//!
//! Programs describe console lines, file paths, and screen drawing;
//! this file owns the real terminal.  Raw mode and the alternate
//! screen engage lazily on the first terminal builtin, every frame is
//! buffered and presented on flush (or before blocking on a key), and
//! program text is sanitized so a Luce program can never emit raw
//! escape sequences — the host writes every control byte itself.
//!
//! The services reach a program as `luce.llvm.abi`'s C table, which is
//! the one calling convention there is: a compiled artifact indexes it
//! with `getelementptr`, and every slot is filled, because loom
//! withholds nothing.  This file built a second table as well until
//! the interpreter stopped being an engine; the specification carries
//! its own host now (docs/ENGINE.md).

const std = @import("std");
const luce = @import("luce");
const key_mod = @import("key.zig");

const Allocator = std.mem.Allocator;
const abi = luce.llvm.abi;

/// How many nested Luce calls loom allows before a program traps
/// `call_depth_exceeded`.  Depth is policy, not a native-stack
/// accident, and the policy is the host's: this one number reaches a
/// compiled artifact through the ABI's `call_depth` slot, and the
/// specification hands the oracle the same one, so runaway recursion
/// traps at the same call on either.  Conservative on purpose —
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
    /// Where `print_error` goes.  Injected like `out` rather than
    /// opened here, because the caller already has the one stderr the
    /// three binaries agree on (`apps/streams.zig`) — and because a
    /// test that wants to read what a program said needs somewhere to
    /// read it from.
    err: *std.Io.Writer,
    arguments: []const []const u8,
    screen: Screen,
    /// Where `file_read` puts a file's bytes for the C table, which
    /// hands out borrows rather than allocations.  Reused per call.
    loaded_file: std.ArrayList(u8) = .empty,
    /// The line `read_line` last read, without its newline — borrowed
    /// until the next call, like every other answer this host gives.
    read_line_buffer: std.ArrayList(u8) = .empty,
    /// Where program text is rewritten before it reaches a real
    /// terminal: a `read_line` prompt and a `print_error` line.  Both
    /// are the program's bytes on a channel the host owns, so both go
    /// through `appendSanitized` and neither can emit a control
    /// sequence (the rule `term_write` follows).
    sanitized: std.ArrayList(u8) = .empty,
    /// One directory listing, kept in both shapes the two engines
    /// want: the names NUL-joined for the C table, and slices into
    /// that same text for the interpreter.  One listing, read twice.
    listed_names: std.ArrayList(u8) = .empty,
    listed_index: std.ArrayList([]const u8) = .empty,
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
    /// What a compiled artifact raised and nobody caught, if it did.
    /// One position and not a trace, which is the whole of what an
    /// error carries (docs/FAILURE.md).
    error_code: ?luce.mir.ErrorCode = null,
    error_storage: [512]u8 = undefined,
    error_length: usize = 0,
    error_origin: Reported.Frame = .{ .function = "", .source = "", .line = 0, .column = 0 },

    pub fn setup(
        self: *Host,
        gpa: Allocator,
        io: std.Io,
        out: *std.Io.Writer,
        err: *std.Io.Writer,
        arguments: []const []const u8,
    ) void {
        self.* = .{
            .gpa = gpa,
            .io = io,
            .out = out,
            .err = err,
            .arguments = arguments,
            .screen = .{},
        };
    }

    pub fn deinit(self: *Host) void {
        self.restoreScreen();
        self.screen.buffer.deinit(self.gpa);
        self.loaded_file.deinit(self.gpa);
        self.read_line_buffer.deinit(self.gpa);
        self.sanitized.deinit(self.gpa);
        self.listed_names.deinit(self.gpa);
        self.listed_index.deinit(self.gpa);
        self.* = undefined;
    }

    /// The error a compiled artifact reported, if it did.  Borrowed
    /// from this Host and valid until the next run.
    pub fn reportedError(self: *const Host) ?Raised {
        return .{
            .code = self.error_code orelse return null,
            .message = self.error_storage[0..self.error_length],
            .origin = self.error_origin,
        };
    }

    pub const Raised = struct {
        code: luce.mir.ErrorCode,
        message: []const u8,
        origin: Reported.Frame,
    };

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
        /// Innermost first, the same order and shape the oracle
        /// reports (`luce.interpreter.Trap.trace`).
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

    /// The services, as the C table a compiled artifact is handed
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
            .raised = cRaised,
            .read_line = cReadLine,
            .print_error = cPrintError,
            .clock_ms = cClock,
            .sleep_ms = cSleep,
            .env = cEnv,
            .file_append = cFileAppend,
            .file_delete = cFileDelete,
            .file_rename = cFileRename,
            .dir_list = cDirList,
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

    fn printLine(self: *Host, text: []const u8) error{OutOfMemory}!void {
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

    fn writeFile(self: *Host, path: []const u8, content: []const u8) bool {
        const file = std.Io.Dir.cwd().createFile(self.io, path, .{ .truncate = true }) catch return false;
        defer file.close(self.io);
        file.writePositionalAll(self.io, content, 0) catch return false;
        file.sync(self.io) catch return false;
        return true;
    }

    fn fileExists(self: *Host, path: []const u8) bool {
        const file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch return false;
        file.close(self.io);
        return true;
    }

    /// Add to the end of a file, creating it if it is not there.
    ///
    /// Read the length and write past it, because the `Io` file API
    /// exposes no O_APPEND: one process appending to its own log is
    /// what this is for, and two writers racing for the same tail is
    /// not something a flag here would fix anyway.
    fn appendFile(self: *Host, path: []const u8, content: []const u8) bool {
        const file = std.Io.Dir.cwd().createFile(self.io, path, .{ .truncate = false }) catch
            return false;
        defer file.close(self.io);
        const end = file.length(self.io) catch return false;
        file.writePositionalAll(self.io, content, end) catch return false;
        file.sync(self.io) catch return false;
        return true;
    }

    fn deleteFile(self: *Host, path: []const u8) bool {
        std.Io.Dir.cwd().deleteFile(self.io, path) catch return false;
        return true;
    }

    fn renameFile(self: *Host, from: []const u8, to: []const u8) bool {
        const cwd = std.Io.Dir.cwd();
        cwd.rename(from, cwd, to, self.io) catch return false;
        return true;
    }

    /// The names in a directory, without `.` and `..` — the iterator
    /// never yields them — kept in this Host in both shapes the two
    /// engines read.  Borrowed until the next listing.
    ///
    /// Sub-directories are named like everything else: a listing says
    /// what is there, and `file_read` on a directory answers no, which
    /// is the honest sequence.
    fn loadDirectory(self: *Host, path: []const u8) error{OutOfMemory}!bool {
        var directory = std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true }) catch
            return false;
        defer directory.close(self.io);
        self.listed_names.clearRetainingCapacity();
        self.listed_index.clearRetainingCapacity();
        var walk = directory.iterate();
        while (true) {
            const entry = (walk.next(self.io) catch return false) orelse break;
            // NUL is the separator, so a name is written once and the
            // index remembers where it started.
            const at = self.listed_names.items.len;
            try self.listed_names.appendSlice(self.gpa, entry.name);
            try self.listed_index.append(self.gpa, self.listed_names.items[at..]);
            try self.listed_names.append(self.gpa, 0);
        }
        // The names moved while the list grew, so the index is rebuilt
        // against where they finally sit.
        var start: usize = 0;
        for (self.listed_index.items) |*name| {
            const length = name.len;
            name.* = self.listed_names.items[start..][0..length];
            start += length + 1;
        }
        return true;
    }

    // -- standard input, standard error, the clock, the environment ----

    /// One line of standard input, without its newline, or null at end
    /// of input.  Borrowed until the next call.
    ///
    /// **The alternate screen goes first.**  A line read and a raw-mode
    /// key loop are two ways to own one stdin, and only one of them can
    /// be live: canonical mode is what gives the person editing, echo
    /// and a newline to press.  So asking for a line hands the terminal
    /// back its line discipline, and the next terminal builtin takes it
    /// again — `ensureScreen` is lazy for exactly this reason.
    fn nextLine(self: *Host, prompt: []const u8) error{OutOfMemory}!?[]const u8 {
        self.restoreScreen();
        if (prompt.len != 0) {
            self.sanitized.clearRetainingCapacity();
            // Program text on a real terminal: sanitized like every
            // other byte a program hands this host to display.
            try appendSanitized(&self.sanitized, self.gpa, prompt);
            self.out.writeAll(self.sanitized.items) catch {};
            // Flushed before the read, for the reason `key_read`
            // presents the frame first: a prompt nobody can see is a
            // program that looks hung.
            self.out.flush() catch {};
        }
        self.read_line_buffer.clearRetainingCapacity();
        while (true) {
            if (self.screen.pending_used == self.screen.pending_len) {
                self.screen.pending_used = 0;
                self.screen.pending_len = std.posix.read(
                    std.posix.STDIN_FILENO,
                    &self.screen.pending,
                ) catch 0;
                if (self.screen.pending_len == 0) {
                    // End of input.  A final line with no newline is
                    // still a line; a truly empty tail is nothing.
                    if (self.read_line_buffer.items.len == 0) return null;
                    return self.read_line_buffer.items;
                }
            }
            const waiting = self.screen.pending[self.screen.pending_used..self.screen.pending_len];
            const stop = std.mem.indexOfScalar(u8, waiting, '\n') orelse {
                try self.read_line_buffer.appendSlice(self.gpa, waiting);
                self.screen.pending_used = self.screen.pending_len;
                continue;
            };
            try self.read_line_buffer.appendSlice(self.gpa, waiting[0..stop]);
            self.screen.pending_used += stop + 1;
            // A CRLF line ends with a carriage return this side owns:
            // the language's Strings are text, not wire bytes.
            const line = self.read_line_buffer.items;
            if (line.len != 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
            return line;
        }
    }

    /// A line of standard error.
    ///
    /// **Always sanitized, unlike `print`.**  stdout is the program's
    /// own channel and may be a pipe or a file, where an escape
    /// sequence is just bytes.  stderr is shared with loom — it is
    /// where a trap is reported and where a diagnostic lands while the
    /// alternate screen is up — so a program that could write raw
    /// control bytes there could scribble over a frame it does not own
    /// or forge the terminal's state.  It is host-written text on a
    /// host channel, and the same rule `term_write` follows applies.
    fn printDiagnostic(self: *Host, text: []const u8) error{OutOfMemory}!void {
        self.sanitized.clearRetainingCapacity();
        try appendSanitized(&self.sanitized, self.gpa, text);
        self.err.writeAll(self.sanitized.items) catch return;
        self.err.writeAll(if (self.screen.active) "\r\n" else "\n") catch return;
        self.err.flush() catch return;
    }

    /// Milliseconds on a monotonic clock.  `awake` and not `real`: the
    /// language promises only that differences mean something, and a
    /// clock the system administrator can move backwards would break
    /// even that.
    fn clockMilliseconds(self: *Host) i64 {
        return std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
    }

    /// Wait at least this long.  A duration that has already elapsed —
    /// zero, or a negative one out of `deadline - clock_ms()` — is not
    /// a bug and not a failure: there is no time left to wait.
    fn sleepMilliseconds(self: *Host, milliseconds: i64) void {
        if (milliseconds <= 0) return;
        // The pending frame goes out first, for the reason `key_read`
        // presents before blocking: a program that draws and then
        // sleeps is animating, and a frame still in the buffer is a
        // frame nobody sees.
        if (self.screen.active and self.screen.buffer.items.len != 0) {
            self.present() catch {};
        }
        self.io.sleep(.{ .nanoseconds = milliseconds * std.time.ns_per_ms }, .awake) catch {};
    }

    /// One environment variable, or null when it is unset — which the
    /// program meets as `none`.
    ///
    /// The bytes belong to the process's own environment block and
    /// outlive every run, so nothing is copied and nothing is freed.
    fn lookUpEnvironment(self: *Host, name: []const u8) error{OutOfMemory}!?[]const u8 {
        _ = self;
        return processEnvironment().getPosix(name);
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

    fn clear(self: *Host) error{OutOfMemory}!void {
        try self.ensureScreen();
        // Reset styles before erasing: terminals fill cleared cells
        // with the *current* background, so clearing while the last
        // frame's colors are active would tint every empty cell.
        try self.screen.buffer.appendSlice(self.gpa, "\x1b[?25l\x1b[0m\x1b[2J\x1b[H");
    }

    fn move(self: *Host, row: i64, col: i64) error{OutOfMemory}!void {
        try self.ensureScreen();
        var encoded: [32]u8 = undefined;
        const sequence = std.fmt.bufPrint(&encoded, "\x1b[{d};{d}H", .{
            std.math.clamp(row, 0, 9998) + 1,
            std.math.clamp(col, 0, 9998) + 1,
        }) catch unreachable;
        try self.screen.buffer.appendSlice(self.gpa, sequence);
    }

    fn style(self: *Host, foreground: i64, background: i64, bold: bool) error{OutOfMemory}!void {
        try self.ensureScreen();
        try appendStyle(&self.screen.buffer, self.gpa, foreground, background, bold);
    }

    fn write(self: *Host, text: []const u8) error{OutOfMemory}!void {
        try self.ensureScreen();
        try appendSanitized(&self.screen.buffer, self.gpa, text);
    }

    fn flush(self: *Host) error{OutOfMemory}!void {
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

    const Screen = struct {
        active: bool = false,
        saved: std.posix.termios = undefined,
        buffer: std.ArrayList(u8) = .empty,
        /// Bytes read from standard input and not yet consumed — one
        /// queue, because there is one file descriptor.  `key_read`
        /// decodes escape sequences out of it and `read_line` takes
        /// text up to the next newline; a byte read for one is not
        /// lost to the other.  Big enough that a piped line costs one
        /// syscall rather than one per character.
        pending: [4096]u8 = undefined,
        pending_len: usize = 0,
        pending_used: usize = 0,
        /// Where a control key's name ("ctrl_s") is written, so naming
        /// one costs no allocation.
        control_name: [6]u8 = undefined,
    };

    // -- the services, as the C table -----------------------------------
    //
    // A thin layer over the methods above and nothing more: what it
    // adds is how a failure travels.  C cannot carry a Zig error, so
    // running out of memory answers `.exhausted` and the run ends
    // without a trap, because nothing about the program was wrong.

    fn of(context: ?*anyopaque) *Host {
        return @ptrCast(@alignCast(context.?));
    }

    fn cPrint(context: ?*anyopaque, text: [*]const u8, length: i64) callconv(.c) abi.Answer {
        of(context).printLine(text[0..@intCast(length)]) catch return .exhausted;
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

    fn cRaised(
        context: ?*anyopaque,
        code: i32,
        message: [*]const u8,
        message_length: i64,
        origin: *const abi.TraceFrame,
    ) callconv(.c) void {
        const self = of(context);
        const words = message[0..@intCast(message_length)];
        const kept = @min(words.len, self.error_storage.len);
        self.error_code = @enumFromInt(code);
        @memcpy(self.error_storage[0..kept], words[0..kept]);
        self.error_length = kept;
        // The names come out of the artifact's constant data and are
        // borrowed for this call only, so they are copied like a
        // trap's — into the same pool, which nothing else is using
        // because a run ends one way or the other.
        self.trace_used = 0;
        self.error_origin = .{
            .function = self.keepText(origin.function[0..@intCast(origin.function_length)]) orelse "",
            .source = self.keepText(origin.source[0..@intCast(origin.source_length)]) orelse "",
            .line = origin.line,
            .column = origin.column,
        };
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
        const wrote = of(context).writeFile(
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
        return if (of(context).fileExists(path[0..@intCast(path_length)])) .yes else .no;
    }

    fn cArgCount(context: ?*anyopaque) callconv(.c) i64 {
        return @intCast(of(context).arguments.len);
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

    fn cTermRows(_: ?*anyopaque) callconv(.c) i64 {
        return windowSize().rows;
    }

    fn cTermCols(_: ?*anyopaque) callconv(.c) i64 {
        return windowSize().columns;
    }

    fn cTermClear(context: ?*anyopaque) callconv(.c) abi.Answer {
        of(context).clear() catch return .exhausted;
        return .yes;
    }

    fn cTermMove(context: ?*anyopaque, row: i64, col: i64) callconv(.c) abi.Answer {
        of(context).move(row, col) catch return .exhausted;
        return .yes;
    }

    fn cTermStyle(
        context: ?*anyopaque,
        foreground: i64,
        background: i64,
        bold: i32,
    ) callconv(.c) abi.Answer {
        of(context).style(foreground, background, bold != 0) catch return .exhausted;
        return .yes;
    }

    fn cTermWrite(context: ?*anyopaque, text: [*]const u8, length: i64) callconv(.c) abi.Answer {
        of(context).write(text[0..@intCast(length)]) catch return .exhausted;
        return .yes;
    }

    fn cTermFlush(context: ?*anyopaque) callconv(.c) abi.Answer {
        of(context).flush() catch return .exhausted;
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

    fn cReadLine(
        context: ?*anyopaque,
        prompt: [*]const u8,
        prompt_length: i64,
        text: *[*]const u8,
        length: *i64,
    ) callconv(.c) abi.Answer {
        const self = of(context);
        const line = (self.nextLine(prompt[0..@intCast(prompt_length)]) catch
            return .exhausted) orelse return .no;
        text.* = line.ptr;
        length.* = @intCast(line.len);
        return .yes;
    }

    fn cPrintError(context: ?*anyopaque, text: [*]const u8, length: i64) callconv(.c) abi.Answer {
        of(context).printDiagnostic(text[0..@intCast(length)]) catch return .exhausted;
        return .yes;
    }

    fn cClock(context: ?*anyopaque) callconv(.c) i64 {
        return of(context).clockMilliseconds();
    }

    fn cSleep(context: ?*anyopaque, milliseconds: i64) callconv(.c) abi.Answer {
        of(context).sleepMilliseconds(milliseconds);
        return .yes;
    }

    fn cEnv(
        context: ?*anyopaque,
        name: [*]const u8,
        name_length: i64,
        text: *[*]const u8,
        length: *i64,
    ) callconv(.c) abi.Answer {
        const self = of(context);
        const found = (self.lookUpEnvironment(name[0..@intCast(name_length)]) catch
            return .exhausted) orelse return .no;
        text.* = found.ptr;
        length.* = @intCast(found.len);
        return .yes;
    }

    fn cFileAppend(
        context: ?*anyopaque,
        path: [*]const u8,
        path_length: i64,
        content: [*]const u8,
        content_length: i64,
    ) callconv(.c) abi.Answer {
        const added = of(context).appendFile(
            path[0..@intCast(path_length)],
            content[0..@intCast(content_length)],
        );
        return if (added) .yes else .no;
    }

    fn cFileDelete(
        context: ?*anyopaque,
        path: [*]const u8,
        path_length: i64,
    ) callconv(.c) abi.Answer {
        return if (of(context).deleteFile(path[0..@intCast(path_length)])) .yes else .no;
    }

    fn cFileRename(
        context: ?*anyopaque,
        from: [*]const u8,
        from_length: i64,
        to: [*]const u8,
        to_length: i64,
    ) callconv(.c) abi.Answer {
        const moved = of(context).renameFile(
            from[0..@intCast(from_length)],
            to[0..@intCast(to_length)],
        );
        return if (moved) .yes else .no;
    }

    fn cDirList(
        context: ?*anyopaque,
        path: [*]const u8,
        path_length: i64,
        names: *[*]const u8,
        names_length: *i64,
    ) callconv(.c) abi.Answer {
        const self = of(context);
        const listed = self.loadDirectory(path[0..@intCast(path_length)]) catch
            return .exhausted;
        if (!listed) return .no;
        names.* = self.listed_names.items.ptr;
        names_length.* = @intCast(self.listed_names.items.len);
        return .yes;
    }
};

const max_file_size = 64 * 1024 * 1024;

/// A reported trace prints at most this many frames; a runaway
/// recursion shows its innermost calls and a count of the rest.
pub const max_printed_frames = 12;

/// Render a trap — one rendering, for every way a Luce program can be
/// run.
///
/// The interpreter, a compiled artifact under loom, and a standalone
/// compiled binary all have to report the same failure the same way,
/// or "the two engines agree" stops being checkable by reading the
/// output.  `trace` is any slice of frames carrying `function`,
/// `source`, `line` and `column`: the interpreter's frame and the
/// ABI's are the same four facts in two structs, and copying one into
/// the other to share this function would allocate on the failure
/// path for nothing.
///
/// Writes are best-effort — a trap report must not fail to be a trap
/// because the pipe closed.
pub fn printTrap(
    err: *std.Io.Writer,
    reporter: []const u8,
    code: []const u8,
    message: []const u8,
    trace: anytype,
    dropped: u32,
) void {
    err.print("{s}: trap: {s} [{s}]\n", .{ reporter, message, code }) catch {};
    // Innermost first, like Zig's own traces.  A --release artifact
    // has no lines; the function names still print.
    for (trace, 0..) |frame, index| {
        if (index == max_printed_frames) break;
        if (frame.line != 0) {
            err.print("    at {s} ({s}:{d}:{d})\n", .{
                frame.function, frame.source, frame.line, frame.column,
            }) catch {};
        } else {
            err.print("    at {s}\n", .{frame.function}) catch {};
        }
    }
    const hidden = dropped + @as(u32, @intCast(trace.len -| max_printed_frames));
    if (hidden != 0) err.print("    ... {d} more frames\n", .{hidden}) catch {};
}

/// Report an uncaught error, in the one shape both engines produce.
///
/// **Not "trap", and it does not print a stack.**  A trap is a bug and
/// the stack is its diagnosis; an error is news, and the news is what
/// the world said and where the program asked it (docs/FAILURE.md).
/// `origin` carries `function`, `source`, `line` and `column` — the
/// interpreter's frame and the ABI's are the same four facts in two
/// structs, so this takes either.
pub fn printError(
    err: *std.Io.Writer,
    reporter: []const u8,
    code: []const u8,
    message: []const u8,
    origin: anytype,
) void {
    err.print("{s}: error: {s} [{s}]\n", .{ reporter, message, code }) catch {};
    if (origin.function.len == 0) return;
    if (origin.line != 0) {
        err.print("    raised in {s} ({s}:{d}:{d})\n", .{
            origin.function, origin.source, origin.line, origin.column,
        }) catch {};
    } else {
        err.print("    raised in {s}\n", .{origin.function}) catch {};
    }
}

/// The one thing to say about a run that ended without trapping.
/// Scope ownership frees everything (OWNERSHIP.md S33), so a nonzero
/// count is an engine bug rather than a program's.
pub fn printLeaks(err: *std.Io.Writer, reporter: []const u8, leaked: u64) void {
    if (leaked == 0) return;
    err.print(
        "{s}: internal error: {d} object{s} escaped ownership — please report this\n",
        .{ reporter, leaked, if (leaked == 1) "" else "s" },
    ) catch {};
}

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

/// The process's own environment block.
///
/// Taken here rather than handed in, exactly as `Dir.cwd()` is: this
/// file *is* the trusted boundary, and ambient process state is what a
/// host is for.  The language never sees any of it except through the
/// one service above.
fn processEnvironment() std.process.Environ {
    var count: usize = 0;
    while (std.c.environ[count] != null) : (count += 1) {}
    return .{ .block = .{ .slice = std.c.environ[0..count :null] } };
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

    var reported: std.Io.Writer.Allocating = .init(testing.allocator);
    defer reported.deinit();

    var host: Host = undefined;
    host.setup(testing.allocator, testing.io, &written.writer, &reported.writer, &.{});
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

test "a program cannot smuggle terminal controls onto stderr or into a prompt" {
    // `term_write` has always been sanitized; standard error and a
    // `read_line` prompt are the two new ways program text reaches a
    // real terminal, and both go through the same rewriting.  stdout
    // is deliberately *not* in this list: it is the program's own
    // channel and may be a pipe or a file, where an escape sequence is
    // simply bytes.  stderr is shared with loom — it is where a trap
    // is reported, and where a diagnostic lands while the alternate
    // screen is up — so a program that could write raw control bytes
    // there could scribble over a frame it does not own.
    var written: std.Io.Writer.Allocating = .init(testing.allocator);
    defer written.deinit();
    var reported: std.Io.Writer.Allocating = .init(testing.allocator);
    defer reported.deinit();

    var host: Host = undefined;
    host.setup(testing.allocator, testing.io, &written.writer, &reported.writer, &.{});
    defer host.deinit();

    const hostile = "clear\x1b[2Jbell\x07 done";
    try Host.printDiagnostic(&host, hostile);
    try testing.expectEqualStrings("clear?[2Jbell? done\n", reported.written());
    try testing.expect(std.mem.indexOfScalar(u8, reported.written(), 0x1b) == null);

    // The prompt takes the same path.  Nothing is read here — this is
    // the writing half, and stdin is not a test's to script.
    host.sanitized.clearRetainingCapacity();
    try appendSanitized(&host.sanitized, host.gpa, hostile);
    try testing.expectEqualStrings("clear?[2Jbell? done", host.sanitized.items);
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

    var diagnostics: std.Io.Writer.Allocating = .init(testing.allocator);
    defer diagnostics.deinit();

    var host: Host = undefined;
    host.setup(
        testing.allocator,
        testing.io,
        &written.writer,
        &diagnostics.writer,
        &.{ "alpha", "beta" },
    );
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

    // The four file operations that arrived with the rest of the host
    // surface, over the same real directory.
    const moved = try std.fs.path.join(testing.allocator, &.{ directory, "kept.txt" });
    defer testing.allocator.free(moved);
    try testing.expectEqual(abi.Answer.yes, table.file_append.?(
        table.context,
        path.ptr,
        @intCast(path.len),
        " more",
        5,
    ));
    try testing.expectEqual(
        abi.Answer.yes,
        table.file_read.?(table.context, path.ptr, @intCast(path.len), &text, &length),
    );
    try testing.expectEqualStrings("kept more", text[0..@intCast(length)]);
    try testing.expectEqual(abi.Answer.yes, table.file_rename.?(
        table.context,
        path.ptr,
        @intCast(path.len),
        moved.ptr,
        @intCast(moved.len),
    ));
    try testing.expectEqual(
        abi.Answer.no,
        table.file_exists.?(table.context, path.ptr, @intCast(path.len)),
    );
    // The listing arrives NUL-joined, which is the one shape the table
    // carries, and it holds the name the rename produced.
    try testing.expectEqual(abi.Answer.yes, table.dir_list.?(
        table.context,
        directory.ptr,
        @intCast(directory.len),
        &text,
        &length,
    ));
    const joined = text[0..@intCast(length)];
    try testing.expect(std.mem.indexOf(u8, joined, "kept.txt\x00") != null);
    try testing.expectEqual(abi.Answer.yes, table.file_delete.?(
        table.context,
        moved.ptr,
        @intCast(moved.len),
    ));
    try testing.expectEqual(abi.Answer.no, table.file_delete.?(
        table.context,
        moved.ptr,
        @intCast(moved.len),
    ));
    try testing.expectEqual(abi.Answer.no, table.dir_list.?(
        table.context,
        moved.ptr,
        @intCast(moved.len),
        &text,
        &length,
    ));

    // The clock only promises that differences mean something, so
    // that is all this checks.
    const began = table.clock_ms.?(table.context);
    try testing.expectEqual(abi.Answer.yes, table.sleep_ms.?(table.context, 2));
    try testing.expect(table.clock_ms.?(table.context) >= began);
    // A duration already elapsed is not a failure.
    try testing.expectEqual(abi.Answer.yes, table.sleep_ms.?(table.context, -1));
    try testing.expectEqual(abi.Answer.yes, table.sleep_ms.?(table.context, 0));

    // Something every process has, and something nothing sets.
    try testing.expectEqual(abi.Answer.yes, table.env.?(table.context, "PATH", 4, &text, &length));
    try testing.expect(length > 0);
    const absent = "LUCE_NOTHING_SETS_THIS";
    try testing.expectEqual(abi.Answer.no, table.env.?(
        table.context,
        absent.ptr,
        absent.len,
        &text,
        &length,
    ));

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
