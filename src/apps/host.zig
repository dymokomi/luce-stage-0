//! The loom host: the trusted boundary behind the Luce host builtins.
//!
//! Programs describe console lines, file paths, and screen drawing;
//! this file owns the real terminal.  Raw mode and the alternate
//! screen engage lazily on the first terminal builtin, every frame is
//! buffered and presented on flush (or before blocking on a key), and
//! program text is sanitized so a Luce program can never emit raw
//! escape sequences — the host writes every control byte itself.  The
//! sanitizing rule is `sanitize.zig`'s, because a trap report follows
//! it too and a trap report is not a terminal.
//!
//! **What a run's ending is called, and what it exits with, is not
//! here**: `report.zig` renders the trap, the uncaught error and the
//! leak census for every runner alike, and never touches a Host.
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
const report = @import("report");
const sanitize = @import("sanitize");

const Allocator = std.mem.Allocator;
const abi = luce.llvm.abi;

// ---------------------------------------------------------------------------
// Limits this host sets
// ---------------------------------------------------------------------------

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
// ---------------------------------------------------------------------------
// The host
// ---------------------------------------------------------------------------

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
    /// through `sanitize.append` and neither can emit a control
    /// sequence (the rule `term_write` follows).
    sanitized: std.ArrayList(u8) = .empty,
    /// One directory listing, NUL-joined, which is the shape the ABI's
    /// `dir_list` hands out (`luce_rt_names_list` splits it).
    listed_names: std.ArrayList(u8) = .empty,
    // -- what a trapped or errored run left behind ------------------------

    /// What a compiled artifact reported through the C table.
    trap_code: ?luce.mir.TrapCode = null,
    trap_storage: [512]u8 = undefined,
    trap_length: usize = 0,
    /// The call trace that came with that trap, innermost first, with
    /// its names copied out of the borrowed report.
    trace_frames: [max_trace_frames]report.Frame = undefined,
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
    error_origin: report.Frame = .{ .function = "", .source = "", .line = 0, .column = 0 },

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
        origin: report.Frame,
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
        /// reports (`luce.interpreter.Trap.trace`), with every name
        /// copied into this Host — what arrives through the C table is
        /// borrowed for the length of the call.
        trace: []const report.Frame,
        dropped: u32,
    };

    // -- setup, teardown, and what the run reported -----------------------

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
        std.posix.tcsetattr(self.screen.handle, .FLUSH, self.screen.saved) catch {};
    }

    // -- console, arguments, files ------------------------------------

    fn printLine(self: *Host, text: []const u8) error{OutOfMemory}!void {
        // A print while the screen is active would scribble over the
        // frame; route it through the frame buffer as plain text.
        if (self.screen.active) {
            try sanitize.append(&self.screen.buffer, self.gpa, text);
            try self.screen.buffer.appendSlice(self.gpa, "\r\n");
            return;
        }
        // A broken pipe must not kill the run: a program that is being
        // read by `head` is not a program that went wrong.  What was
        // lost is reported once, by the runner, out of the final flush
        // (`loom/runner.zig`) — not once per line from in here.
        self.out.writeAll(text) catch return;
        self.out.writeAll("\n") catch return;
        self.out.flush() catch return;
    }

    /// A whole file's bytes, or null when it could not be read.  The
    /// bytes live in this Host and are borrowed until the next read,
    /// which is what the C table hands out; generated code copies them
    /// into the run's own arena before the next call can move them.
    ///
    /// **The bytes must be valid UTF-8**, because they become a Luce
    /// `string` and the language promises that `s[a:b]` is checked
    /// against character boundaries and `len` counts characters.  A
    /// half-read JPEG would make both of those lies, and the trap they
    /// are supposed to raise would fire — or not — on the *contents*
    /// of a file rather than on anything the program did.  Source
    /// bytes have been through `01_source.prepare` since stage 1 was
    /// written; nothing was checking data.  A file that is not text
    /// answers null and the program traps `file_read_failed`, which is
    /// true: it could not be read *as a string*.
    ///
    /// Unlike source, data is **not** normalized: no BOM is stripped
    /// and no CRLF is rewritten.  `file_read` hands back the file, and
    /// a program that reads a CSV and writes it again must get the
    /// same bytes out.
    ///
    /// **There is a size cap** (`max_file_size`, 64 MB), and a file
    /// over it answers null and traps like any other unreadable one.
    /// It is a host policy, not a language limit: `file_read` reads a
    /// whole file into one buffer, so the cap is what stops a program
    /// from being handed the machine's memory by naming a path.  A
    /// program that needs more wants a streaming read, which is a
    /// service the host does not offer yet.
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
        var walk = directory.iterate();
        while (true) {
            const entry = (walk.next(self.io) catch return false) orelse break;
            // NUL is the separator (`luce_rt_names_list` splits on it).
            try self.listed_names.appendSlice(self.gpa, entry.name);
            try self.listed_names.append(self.gpa, 0);
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
            try sanitize.append(&self.sanitized, self.gpa, prompt);
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
                    self.screen.handle,
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
        try sanitize.append(&self.sanitized, self.gpa, text);
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
        const saved = std.posix.tcgetattr(self.screen.handle) catch return;
        var raw = saved;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        // Block until at least one byte arrives, and never on a timer.
        //
        // It was `MIN = 0, TIME = 1` — a tenth-of-a-second poll — and
        // that is two faults in one setting.  It made an idle editor
        // wake ten times a second to read nothing (measured: 52
        // wakeups in five seconds), and it made a read of zero bytes
        // ambiguous, because "the timer expired" and "there will never
        // be another key" arrive as the same answer.  `nextKey` needs
        // to tell those apart to say end of input at all, so the
        // blocking read is not a tuning of this fix but a part of it.
        //
        // A key still cannot be missed while the program is drawing:
        // the bytes wait in the terminal's own queue, and the frame is
        // presented before the read, not instead of it.
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        std.posix.tcsetattr(self.screen.handle, .FLUSH, raw) catch return;
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
        try sanitize.append(&self.screen.buffer, self.gpa, text);
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

    /// Block until one key arrives, or answer null when none ever
    /// will.  Both slices are borrowed until the next call: the name is
    /// static text or this Host's own storage, and the text points into
    /// the pending input.
    ///
    /// **Null is the whole reason this returns an optional.**  A read
    /// of zero bytes on a descriptor set to block is end of input and
    /// nothing else — the pipe closed, the file ran out — so going
    /// round again asks a question already answered, forever, at the
    /// speed of the loop.  That is what it used to do: `loom edit`
    /// with standard input on `/dev/null` never returned, at 97% of a
    /// core.
    ///
    /// The buffer can also be holding an incomplete escape sequence
    /// when input ends — a lone `\x1b`, the prefix of an arrow key
    /// nobody finished.  There is no more input to complete it with,
    /// so it is dropped rather than waited on.
    fn nextKey(self: *Host) error{OutOfMemory}!?KeyView {
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
            // A full buffer that decodes to nothing is not going to
            // decode to anything with one more byte in it: drop it
            // rather than read zero bytes into no room and call that
            // end of input.
            if (self.screen.pending_len == self.screen.pending.len) {
                self.screen.pending_len = 0;
                continue;
            }
            const count = std.posix.read(
                self.screen.handle,
                self.screen.pending[self.screen.pending_len..],
            ) catch 0;
            if (count == 0) return null;
            self.screen.pending_len += count;
        }
    }

    const Screen = struct {
        active: bool = false,
        /// Which descriptor *is* the terminal: raw mode is set on it,
        /// and both `key_read` and `read_line` take their bytes from
        /// it.  Standard input, always, in every shipped binary.
        ///
        /// It is a field rather than the constant it was because a
        /// terminal is the one host service a test cannot simply call:
        /// the rules worth proving here — that a prompt is sanitized
        /// on its way out, that a `\r\n` follows a diagnostic while a
        /// frame is up, that a descriptor which is not a terminal
        /// leaves raw mode alone — are all about what happens *around*
        /// a read, and there is no way to reach them without owning
        /// the descriptor being read.  Nothing sets it but the tests
        /// below, and they set it to a real pipe rather than to a
        /// stand-in, so what they exercise is the shipped path.
        handle: std.posix.fd_t = std.posix.STDIN_FILENO,
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
        const kept = fittingLength(words, self.trap_storage.len);
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
        const kept = fittingLength(words, self.error_storage.len);
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

    /// How much of `words` fits in `capacity` **without cutting a UTF-8
    /// sequence in half**.
    ///
    /// A trap message is text, not bytes: it is built from the
    /// program's own Strings, and half a codepoint is not a shorter
    /// message but a broken one — it prints as `?` at best, and the
    /// site's byte-for-byte output check would compare a fragment
    /// nobody can reproduce.  Messages this long are pathological
    /// (`raiseIo` builds `verb ++ path`, and a path can be long), so
    /// what matters is that the cut is honest, not that it is rare.
    fn fittingLength(words: []const u8, capacity: usize) usize {
        if (words.len <= capacity) return words.len;
        var kept = capacity;
        // A continuation byte is 0b10xxxxxx; step back off the tail of
        // a sequence until the next byte would start a new one.
        while (kept != 0 and words[kept] & 0xc0 == 0x80) kept -= 1;
        return kept;
    }

    /// One number, answered through the ABI's `call_depth` slot.  The
    /// specification hands the oracle the same one, so a program that
    /// recurses away traps at the same call on either arm.
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
        const view = (of(context).nextKey() catch return .exhausted) orelse return .no;
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

// ---------------------------------------------------------------------------
// Reading a file, drawing a key, sizing a window
// ---------------------------------------------------------------------------

const max_file_size = 64 * 1024 * 1024;

/// One decoded key as the host sees it, before either boundary copies
/// it: `name` is static text or `control_name`, `text` points into the
/// pending input buffer.
const KeyView = struct {
    name: []const u8,
    text: []const u8 = "",
};

/// map a decoded key to its stable Luce-visible event, or null for
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

test "file_read refuses bytes that cannot be a string, and normalizes nothing" {
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

test "file_read stops exactly at the ceiling it documents" {
    // The cap is what stops a program from being handed the machine's
    // memory by naming a path, so both sides of it have to be the
    // documented number: a file of exactly 64 MiB is a file, and one
    // byte more is refused the way any unreadable file is.
    //
    // The bytes are never written.  A single byte at the last offset
    // gives the file its length and the filesystem stores a hole, so
    // this costs a `resize` and a read of zeros — which are, as it
    // happens, perfectly good UTF-8.
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var reported: std.Io.Writer.Allocating = .init(testing.allocator);
    defer reported.deinit();

    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory = path_storage[0..try scratch.dir.realPath(testing.io, &path_storage)];

    var host: Host = undefined;
    host.setup(testing.allocator, testing.io, &out.writer, &reported.writer, &.{});
    defer host.deinit();

    const cases = [_]struct { name: []const u8, length: u64, readable: bool }{
        .{ .name = "brim.bin", .length = max_file_size, .readable = true },
        .{ .name = "over.bin", .length = max_file_size + 1, .readable = false },
    };
    for (cases) |case| {
        const path = try std.fs.path.join(testing.allocator, &.{ directory, case.name });
        defer testing.allocator.free(path);
        const file = try std.Io.Dir.cwd().createFile(testing.io, path, .{ .truncate = true });
        try file.writePositionalAll(testing.io, "\x00", case.length - 1);
        file.close(testing.io);

        const found = try host.loadFile(path);
        if (!case.readable) {
            try testing.expect(found == null);
            continue;
        }
        try testing.expectEqual(@as(usize, max_file_size), found.?.len);
    }
}

test "a program may name any path the process itself can" {
    // **The deliberate non-rule** (docs/LANGUAGE.md, "The host").  Loom
    // runs programs the way a shell runs processes: `allow_host` is the
    // gate that decides whether a program may touch files at all, and
    // the operating system is what decides *which* files — the same
    // user, the same working directory, the same permissions as the
    // `luce` and `loom` that started it.  There is no sandbox here and
    // no path prefix a program is confined to.
    //
    // It is tested in both directions so that changing it can never be
    // quiet: a build that starts refusing an absolute path or a `..`
    // fails here, and whoever wrote that refusal has to come and say
    // what the new rule is.
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var reported: std.Io.Writer.Allocating = .init(testing.allocator);
    defer reported.deinit();

    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory = path_storage[0..try scratch.dir.realPath(testing.io, &path_storage)];

    var host: Host = undefined;
    host.setup(testing.allocator, testing.io, &out.writer, &reported.writer, &.{});
    defer host.deinit();

    // An absolute path, anywhere the process can reach.
    const absolute = try std.fs.path.join(testing.allocator, &.{ directory, "notes.txt" });
    defer testing.allocator.free(absolute);
    try testing.expect(host.writeFile(absolute, "kept"));
    try testing.expectEqualStrings("kept", (try host.loadFile(absolute)).?);

    // And a relative one that climbs out of where it started: the
    // directory's own name, reached through its parent.
    const climbing = try std.fs.path.join(testing.allocator, &.{
        directory,
        "..",
        std.fs.path.basename(directory),
        "notes.txt",
    });
    defer testing.allocator.free(climbing);
    try testing.expect(host.fileExists(climbing));
    try testing.expectEqualStrings("kept", (try host.loadFile(climbing)).?);
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
    try sanitize.append(&host.sanitized, host.gpa, hostile);
    try testing.expectEqualStrings("clear?[2Jbell? done", host.sanitized.items);
}

/// A host reading a terminal this test owns.
///
/// The descriptor is a real file holding what the person at the
/// keyboard typed, standing where standard input stands in a shipped
/// binary.  A file rather than a pipe because it is the same thing to
/// everything under test — `tcgetattr` refuses both, `read` drains both
/// and then answers zero — and because a file has no writer that has to
/// stay ahead of the reader for the test not to hang.
const Scripted = struct {
    host: Host,
    scratch: testing.TmpDir,
    input: std.Io.File,
    out: std.Io.Writer.Allocating,
    err: std.Io.Writer.Allocating,

    fn setup(self: *Scripted, script: []const u8) !void {
        self.out = .init(testing.allocator);
        errdefer self.out.deinit();
        self.err = .init(testing.allocator);
        errdefer self.err.deinit();

        self.scratch = testing.tmpDir(.{});
        errdefer self.scratch.cleanup();
        try self.scratch.dir.writeFile(testing.io, .{ .sub_path = "typed", .data = script });
        self.input = try self.scratch.dir.openFile(testing.io, "typed", .{});

        self.host.setup(testing.allocator, testing.io, &self.out.writer, &self.err.writer, &.{});
        self.host.screen.handle = self.input.handle;
    }

    fn deinit(self: *Scripted) void {
        self.host.deinit();
        self.input.close(testing.io);
        self.scratch.cleanup();
        self.out.deinit();
        self.err.deinit();
    }
};

test "a prompt is written through the sanitizer before the line is read" {
    // The reading half of `read_line`, which nothing could reach while
    // the descriptor was a constant: the prompt goes out rewritten and
    // flushed *before* the read, a CRLF line comes back without its
    // carriage return, and the end of input is a `none` rather than an
    // empty string.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var scripted: Scripted = undefined;
    try scripted.setup("first\r\nsecond\nlast");
    defer scripted.deinit();

    const first = (try scripted.host.nextLine("name\x1b[2J? ")).?;
    try testing.expectEqualStrings("first", first);
    // Rewritten, and on the writer before the read — a prompt nobody
    // can see is a program that looks hung.
    try testing.expectEqualStrings("name?[2J? ", scripted.out.written());

    // No prompt writes nothing at all.
    try testing.expectEqualStrings("second", (try scripted.host.nextLine("")).?);
    try testing.expectEqualStrings("name?[2J? ", scripted.out.written());

    // A final line with no newline is still a line; the empty tail
    // after it is not.
    try testing.expectEqualStrings("last", (try scripted.host.nextLine("")).?);
    try testing.expectEqual(@as(?[]const u8, null), try scripted.host.nextLine(""));
}

test "a descriptor that is not a terminal is drawn on without raw mode" {
    // The tty gate.  `ensureScreen` asks the descriptor for its termios
    // and gives up when there is none — a pipe, a file, a program run
    // from a build step.  What must *not* happen is either half of the
    // pair going ahead alone: no alternate screen without raw mode, and
    // above all no `restoreScreen` writing an escape sequence into
    // somebody's output file at the end of a run that never drew.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var scripted: Scripted = undefined;
    try scripted.setup("");
    defer scripted.deinit();

    try scripted.host.clear();
    try scripted.host.write("frame");
    try scripted.host.flush();
    // Drawn, and the frame reached the writer.
    try testing.expect(std.mem.indexOf(u8, scripted.out.written(), "frame") != null);
    // But the screen was never taken: nothing was switched, so there
    // is nothing to switch back.
    try testing.expect(!scripted.host.screen.active);
    const drawn = scripted.out.written().len;
    scripted.host.restoreScreen();
    try testing.expectEqual(drawn, scripted.out.written().len);
}

test "a diagnostic ends its line the way the screen it lands on needs" {
    // `print_error` while a frame is up shares the terminal with the
    // drawing, and raw mode has turned the newline into a line feed
    // that does not return the carriage.  The next line would start
    // wherever the last one ended.
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var reported: std.Io.Writer.Allocating = .init(testing.allocator);
    defer reported.deinit();

    var host: Host = undefined;
    host.setup(testing.allocator, testing.io, &out.writer, &reported.writer, &.{});
    defer host.deinit();

    try host.printDiagnostic("ordinary");
    try testing.expectEqualStrings("ordinary\n", reported.written());

    reported.clearRetainingCapacity();
    host.screen.active = true;
    try host.printDiagnostic("during a frame");
    try testing.expectEqualStrings("during a frame\r\n", reported.written());
    // Nothing here took the screen, so nothing may hand it back.
    host.screen.active = false;
}

test "a message too long for the fixed report buffer is cut on a codepoint" {
    // The trap channel has nowhere to allocate, so a pathological
    // message (a `raiseIo` over a very long path) is cut.  Half a
    // codepoint is not a shorter message but a broken one.
    const dashes = "—" ** 8; // three bytes each
    try testing.expectEqual(@as(usize, 24), Host.fittingLength(dashes, 24));
    try testing.expectEqual(@as(usize, 21), Host.fittingLength(dashes, 23));
    try testing.expectEqual(@as(usize, 21), Host.fittingLength(dashes, 22));
    try testing.expectEqual(@as(usize, 21), Host.fittingLength(dashes, 21));
    // Plain ASCII is cut exactly where asked.
    try testing.expectEqual(@as(usize, 3), Host.fittingLength("abcdef", 3));
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
