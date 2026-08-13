//! The loom host: the trusted boundary behind the Luce host builtins.
//!
//! Programs describe console lines, file paths, screen drawing, and input;
//! this file owns the real terminal.  Raw mode and the alternate
//! screen engage lazily on the first terminal builtin, every frame is
//! buffered and presented on flush (or before blocking on a key), and
//! program text is sanitized so a Luce program can never emit raw
//! escape sequences — the host writes every control byte itself.  Mouse
//! reporting is enabled for the interactive screen and decoded in
//! `key.zig`; the program receives names and numeric event data, never
//! terminal escape sequences.  The sanitizing rule is `sanitize.zig`'s,
//! because a trap report follows it too and a trap report is not a terminal.
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
const builtin = @import("builtin");
const luce = @import("luce");
const key_mod = @import("key.zig");
const machine = @import("machine.zig");
const report = @import("report");
const sanitize = @import("sanitize");

const Allocator = std.mem.Allocator;
const abi = luce.llvm.abi;

/// What a host is asked to run on a thread: one C function and one
/// opaque argument, both `libluce_rt`'s (docs/THREADS.md D8).  Named
/// here because the two spellings of the slot — the ABI's and the
/// runtime library's — take the same pointer.
const WorkerBody = *const fn (argument: ?*anyopaque) callconv(.c) void;

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
    /// Captured stdout/stderr from the last `std.os.shell.run` call.
    /// Borrowed by the generated program until the next command.
    shell_output: std.ArrayList(u8) = .empty,
    /// Every file the byte channel has open (docs/BYTES.md R5).  A
    /// handle is this table's index plus one, so zero is never a
    /// handle; a closed row stays in place and is reused, which is what
    /// makes a stale number land on a row that says "shut" rather than
    /// on whoever moved in.
    open_files: std.ArrayList(OpenFile) = .empty,
    /// Every worker thread this run started (docs/THREADS.md D8).  A
    /// thread is this table's index plus one, so zero is never a
    /// handle; a joined row is emptied and kept in place, so a stale
    /// number lands on nothing rather than on whoever moved in.
    threads: std.ArrayList(?std.Thread) = .empty,
    /// The worker registry has its own lock.  D9's Effects lock guards
    /// host effects, not the lifetime of the threads that may call
    /// them, and a worker may enter this table while another worker is
    /// blocked in a join.  Every process entry point supplies a
    /// `std.Io.Threaded` Io, as does `testing.io`, so its futex-backed
    /// mutex is safe to enter from these raw `std.Thread` callbacks.
    thread_mutex: std.Io.Mutex = .init,
    /// Once teardown starts, a thread that was started concurrently is
    /// joined by its spawner rather than published into a dying table.
    threads_closing: bool = false,
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
    /// The status `exit(status)` carried, recorded by the `exited`
    /// slot; null when the program never exited.
    exit_status: ?i64 = null,
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
        // A worker may still be using any other field below.  Close and
        // drain the registry while the whole host is still alive.
        self.joinThreads();
        self.threads.deinit(self.gpa);
        self.restoreScreen();
        self.screen.buffer.deinit(self.gpa);
        self.read_line_buffer.deinit(self.gpa);
        self.sanitized.deinit(self.gpa);
        self.listed_names.deinit(self.gpa);
        self.shell_output.deinit(self.gpa);
        self.closeOpenFiles();
        self.open_files.deinit(self.gpa);
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
            // Retired at ABI version 12 (docs/BYTES.md R2): the whole-
            // file text services are open-read-close over the byte
            // channel inside `libluce_rt` now, and these three slots
            // keep their positions without being filled.
            .file_read = null,
            .file_write = null,
            // Retired at ABI version 17 (docs/FILESYSTEM.md D16): one
            // bit could not tell "nothing is there" from "I was not
            // allowed to look", and `path_kind` below asks properly.
            .file_exists = null,
            .arg_count = cArgCount,
            .arg = cArg,
            .term_rows = cTermRows,
            .term_cols = cTermCols,
            .term_clear = cTermClear,
            .term_move = cTermMove,
            .term_style = cTermStyle,
            .term_write = cTermWrite,
            .term_flush = cTermFlush,
            .term_event_data = cTermEventData,
            .key_read = cKeyRead,
            .call_depth = cCallDepth,
            .raised = cRaised,
            .read_line = cReadLine,
            .print_error = cPrintError,
            .clock_ms = cClock,
            .sleep_ms = cSleep,
            .env = cEnv,
            .file_append = null,
            .file_delete = cFileDelete,
            .file_rename = cFileRename,
            .dir_list = cDirList,
            .dir_create = cDirCreate,
            .epoch_ms = cEpoch,
            .exited = cExited,
            .os_total_memory = cTotalMemory,
            .os_available_memory = cAvailableMemory,
            .os_cpu_count = cCpuCount,
            .handle_open = cHandleOpen,
            .handle_read = cHandleRead,
            .handle_write = cHandleWrite,
            .handle_flush = cHandleFlush,
            .handle_close = cHandleClose,
            .worker_spawn = cWorkerSpawn,
            .worker_join = cWorkerJoin,
            .shell_run = cShellRun,
            .path_kind = cPathKind,
        };
    }

    /// The thread channel, in the `libluce_rt` spelling the oracle
    /// installs (docs/THREADS.md D8) — the same two functions the
    /// table above publishes, `Answer` unwrapped, exactly as
    /// `fileChannel` does for the handle channel.
    pub fn workerChannel(self: *Host) luce.runtime.workers.Channel {
        return .{ .context = self, .spawn = pWorkerSpawn, .join = pWorkerJoin };
    }

    // -- threads ---------------------------------------------------------
    //
    // A host's whole contribution to concurrency: start a C function on
    // a thread, and wait for it to end (docs/THREADS.md D8).  Nothing
    // here knows what a worker is.  D9 serializes effects, but the
    // registry is machinery beneath that rule and owns its own lock:
    // nested workers and joins can reach it concurrently.
    //
    // The number a thread is known by is its row in `threads` plus one,
    // so zero is never a handle.

    fn startThread(self: *Host, body: WorkerBody, argument: ?*anyopaque) ?i64 {
        const Runner = struct {
            fn go(run: WorkerBody, given: ?*anyopaque) void {
                run(given);
            }
        };

        // Reserve the registry row before starting user code.  Starting
        // first and discovering that the table cannot grow is not a
        // harmless allocation failure: the speculative body may block,
        // while this caller is synchronously joining it and therefore
        // cannot open its gate.  Holding the lock across the short thread
        // creation/publication step is safe — the new thread cannot enter
        // the registry until this lock is released, and nested workers see
        // their parent's row already installed.
        self.thread_mutex.lockUncancelable(self.io);
        if (self.threads_closing) {
            self.thread_mutex.unlock(self.io);
            return null;
        }

        // A null row is a reservation while the OS thread is being
        // created.  No join or teardown can inspect it until publication,
        // because both paths take this same lock.
        self.threads.append(self.gpa, null) catch {
            self.thread_mutex.unlock(self.io);
            return null;
        };
        const handle: i64 = @intCast(self.threads.items.len);
        const started = std.Thread.spawn(.{}, Runner.go, .{ body, argument }) catch {
            self.threads.items.len -= 1;
            self.thread_mutex.unlock(self.io);
            return null;
        };
        self.threads.items[self.threads.items.len - 1] = started;
        self.thread_mutex.unlock(self.io);
        return handle;
    }

    fn cWorkerSpawn(
        context: ?*anyopaque,
        body: WorkerBody,
        argument: ?*anyopaque,
        thread: *i64,
    ) callconv(.c) abi.Answer {
        thread.* = of(context).startThread(body, argument) orelse return .no;
        return .yes;
    }

    fn cWorkerJoin(context: ?*anyopaque, thread: i64) callconv(.c) abi.Answer {
        const self = of(context);
        self.thread_mutex.lockUncancelable(self.io);
        if (thread < 1 or thread > self.threads.items.len) {
            self.thread_mutex.unlock(self.io);
            return .no;
        }
        const row = &self.threads.items[@intCast(thread - 1)];
        const running = row.*;
        row.* = null;
        self.thread_mutex.unlock(self.io);

        // A joining worker can itself be waiting for a nested worker,
        // so no registry lock may be held across this wait.
        if (running) |detached| detached.join();
        return .yes;
    }

    fn pWorkerSpawn(
        context: ?*anyopaque,
        body: WorkerBody,
        argument: ?*anyopaque,
        thread: *i64,
    ) callconv(.c) i32 {
        return @intFromEnum(cWorkerSpawn(context, body, argument, thread));
    }

    fn pWorkerJoin(context: ?*anyopaque, thread: i64) callconv(.c) i32 {
        return @intFromEnum(cWorkerJoin(context, thread));
    }

    /// Wait for anything a program left running.  A worker is joined by
    /// the scope that owned it (D5), so this only ever finds a thread a
    /// trap unwound past — but a process must not outlive its threads,
    /// and this is the run's backstop, beside `closeOpenFiles`.
    pub fn joinThreads(self: *Host) void {
        while (true) {
            self.thread_mutex.lockUncancelable(self.io);
            self.threads_closing = true;

            var running: ?std.Thread = null;
            for (self.threads.items) |*row| {
                if (row.*) |detached| {
                    row.* = null;
                    running = detached;
                    break;
                }
            }
            if (running == null) {
                self.threads.clearRetainingCapacity();
                self.thread_mutex.unlock(self.io);
                return;
            }
            self.thread_mutex.unlock(self.io);

            // Detach one under the lock, then join it without the lock.
            // Repeat because the thread being joined may have published
            // a nested worker before it observed `threads_closing`.
            running.?.join();
        }
    }

    /// Leave the alternate screen, mouse reporting, and raw mode; safe to
    /// call twice.
    /// The runner calls this before reporting traps so messages land
    /// on the ordinary screen.
    pub fn restoreScreen(self: *Host) void {
        if (!self.screen.active) return;
        self.screen.active = false;
        self.out.writeAll("\x1b[0m\x1b[?25h\x1b[?1006l\x1b[?1002l\x1b[?1049l") catch {};
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

    // -- the byte channel (docs/BYTES.md) ------------------------------
    //
    // Five slots, one open-file table, and no opinion about encoding:
    // a read fills the caller's buffer and answers the count, a write
    // takes a buffer and a length.  Whether the bytes are text is
    // `libluce_rt`'s question now, not this file's, which is what puts
    // both engines on one answer.
    //
    // The same five functions serve both arms — `abi.Host`'s slots and
    // the `runtime.files.Channel` the interpreter installs — because
    // neither engine calls them: the runtime holds them and does.

    /// Open `path` and answer the number this host will know it by.
    ///
    /// The number is the row's index in `open_files` plus one, so zero
    /// is never a handle and a stale number lands on a row that says
    /// it is shut rather than on somebody else's file.
    fn openFile(self: *Host, path: []const u8, mode: luce.runtime.files.Mode) ?i64 {
        const opened = switch (mode) {
            .read => std.Io.Dir.cwd().openFile(self.io, path, .{}) catch return null,
            .write => std.Io.Dir.cwd().createFile(self.io, path, .{ .truncate = true }) catch
                return null,
            // No `O_APPEND` in the `Io` file API, so an append handle
            // is a create-without-truncate positioned at the end, and
            // the position is this host's rather than the descriptor's.
            .append => std.Io.Dir.cwd().createFile(self.io, path, .{ .truncate = false }) catch
                return null,
            else => return null,
        };
        var at: u64 = 0;
        if (mode == .append) at = opened.length(self.io) catch 0;
        for (self.open_files.items, 0..) |*row, index| {
            if (row.shut) {
                row.* = .{ .file = opened, .position = at };
                return @intCast(index + 1);
            }
        }
        self.open_files.append(self.gpa, .{ .file = opened, .position = at }) catch {
            opened.close(self.io);
            return null;
        };
        return @intCast(self.open_files.items.len);
    }

    /// The row a handle names, or null when it names none.
    fn openRow(self: *Host, handle: i64) ?*OpenFile {
        if (handle < 1 or handle > self.open_files.items.len) return null;
        const row = &self.open_files.items[@intCast(handle - 1)];
        return if (row.shut) null else row;
    }

    /// Every file the run left open.  A program that leaks a handle is
    /// reported rather than corrected — the leak census is what says so
    /// — but the descriptor still goes back with the run.
    pub fn closeOpenFiles(self: *Host) void {
        for (self.open_files.items) |*row| {
            if (row.shut) continue;
            row.file.close(self.io);
            row.shut = true;
        }
        self.open_files.clearRetainingCapacity();
    }

    /// What is at `path`: 0 nothing, 1 a file, 2 a directory, 3
    /// something else — or null for a world that would not say, which
    /// the program meets as `io_failed` (`abi.PathKindFn`).
    ///
    /// **One `stat`, links followed**, which is what `openFile`,
    /// `deleteFile` and `rename` here already mean, so the kind
    /// describes the same file the next call touches and a dangling
    /// link is 0.
    ///
    /// Only two failures are "nothing is there": the name has no
    /// entry, and a component of the path is not a directory — in
    /// both, the world looked and there was nothing at that name.
    /// Everything else is a refusal and says so, which is the whole
    /// difference from the `file_exists` this replaced: a file under a
    /// `chmod 000` parent used to answer `false`, indistinguishable
    /// from a name nothing holds.
    fn pathKind(self: *Host, path: []const u8) ?i64 {
        const found = std.Io.Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = true }) catch |refused| {
            return switch (refused) {
                error.FileNotFound, error.NotDir => 0,
                else => null,
            };
        };
        return switch (found.kind) {
            .file => 1,
            .directory => 2,
            else => 3,
        };
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

    /// Make a directory and everything that leads to it, answering
    /// whether there is one there now.
    ///
    /// `createDirPath` is `mkdir -p` and answers success for a
    /// directory that was already there, which is exactly the pair of
    /// rules `abi.DirCreateFn` publishes — so loom keeps them by
    /// naming the one call that already has them rather than by
    /// building a loop of its own.  Anything else the world says —
    /// a permission refused, a *file* holding the name — is `false`,
    /// which the program meets as `io_failed`.
    fn createDirectory(self: *Host, path: []const u8) bool {
        std.Io.Dir.cwd().createDirPath(self.io, path) catch return false;
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

    /// Milliseconds since the Unix epoch.  `real` and not `awake`:
    /// this is the one reading whose *value* is the answer, so it is
    /// the settable system clock — the very property that disqualifies
    /// it from `clock_ms` is what makes it a calendar.  Loom always
    /// knows what time it is, so it never answers "cannot tell"; the
    /// slot is shaped to allow that for hosts that do not.
    fn epochMilliseconds(self: *Host) i64 {
        return std.Io.Timestamp.now(self.io, .real).toMilliseconds();
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

    /// Run one shell command for `std.os.shell.run`, keeping the two
    /// output streams and a final status line together as one Luce
    /// string. A non-zero command status is data the caller can show;
    /// only failure to start the shell answers `null`.
    fn runShell(self: *Host, command: []const u8) error{OutOfMemory}!?[]const u8 {
        const shell = if (builtin.os.tag == .windows) "cmd.exe" else "/bin/sh";
        const flag = if (builtin.os.tag == .windows) "/C" else "-c";
        const ran = std.process.run(self.gpa, self.io, .{
            .argv = &.{ shell, flag, command },
        }) catch |mistake| switch (mistake) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        defer self.gpa.free(ran.stdout);
        defer self.gpa.free(ran.stderr);

        self.shell_output.clearRetainingCapacity();
        try self.shell_output.appendSlice(self.gpa, ran.stdout);
        if (ran.stdout.len != 0 and ran.stderr.len != 0 and
            ran.stdout[ran.stdout.len - 1] != '\n')
        {
            try self.shell_output.append(self.gpa, '\n');
        }
        try self.shell_output.appendSlice(self.gpa, ran.stderr);
        if (self.shell_output.items.len != 0 and
            self.shell_output.items[self.shell_output.items.len - 1] != '\n')
        {
            try self.shell_output.append(self.gpa, '\n');
        }
        var status: [64]u8 = undefined;
        const line = switch (ran.term) {
            .exited => |code| std.fmt.bufPrint(&status, "exit status: {d}\n", .{code}) catch unreachable,
            else => |term| std.fmt.bufPrint(&status, "terminated: {s}\n", .{@tagName(term)}) catch unreachable,
        };
        try self.shell_output.appendSlice(self.gpa, line);
        return self.shell_output.items;
    }

    // -- the screen ----------------------------------------------------

    fn ensureScreen(self: *Host) error{OutOfMemory}!void {
        if (self.screen.active) return;
        if (self.screen.raw == .unavailable) return;
        // The system call rather than `std.posix.tcgetattr`, and the
        // reason is in `Screen.raw`: the wrapper's `else` arm reaches
        // `unexpectedErrno`, which *prints a stack trace* before it
        // hands back an error, and a pipe answers with an errno that
        // arm covers.  Reading the number here is the difference
        // between "this is not a terminal" and a screenful of traces.
        var attributes: std.posix.termios = undefined;
        if (std.posix.errno(std.posix.system.tcgetattr(self.screen.handle, &attributes)) != .SUCCESS) {
            self.screen.raw = .unavailable;
            return;
        }
        const saved = attributes;
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
        std.posix.tcsetattr(self.screen.handle, .FLUSH, raw) catch {
            self.screen.raw = .unavailable;
            return;
        };
        self.screen.raw = .available;
        self.screen.saved = saved;
        const size = windowSize();
        self.screen.last_rows = size.rows;
        self.screen.last_columns = size.columns;
        self.screen.event = .{};
        self.screen.active = true;
        // SGR mouse mode is unambiguous for UTF-8 terminals.  Button-event
        // tracking gives clicks and drags without flooding an editor with
        // every pointer movement, while the host still decodes motion reports
        // from terminals that send them.
        self.out.writeAll("\x1b[?1049h\x1b[?1002h\x1b[?1006h\x1b[0m\x1b[2J\x1b[H") catch {};
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
    /// speed of the loop.  That is what it used to do: the editor
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

        const size = windowSize();
        if (size.rows != self.screen.last_rows or size.columns != self.screen.last_columns) {
            self.screen.last_rows = size.rows;
            self.screen.last_columns = size.columns;
            self.screen.event = .{};
            return .{ .name = "resize" };
        }

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
                if (keyView(&self.screen.control_name, decoded.key)) |view| {
                    self.screen.event = view.event;
                    return view;
                }
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
            if (count == 0) {
                self.screen.event = .{};
                return null;
            }
            self.screen.pending_len += count;
        }
    }

    const Screen = struct {
        pub const Raw = enum { unasked, available, unavailable };

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
        /// Whether raw mode can be had on `handle`, asked once.
        ///
        /// A descriptor that is not a terminal is not going to become
        /// one, and `tcgetattr` on a pipe does worse than fail: the
        /// errno it fails with is one Zig's wrapper does not map, so
        /// the standard library dumps a stack trace to standard error
        /// before handing back `error.Unexpected`.  Retrying it per
        /// escape sequence — which is what asking on every call came
        /// to — buries a program's own output in traces the moment it
        /// draws into a pipe.  `loom run editor.lc > frames.txt` is
        /// that program, and so is every package test that presents a
        /// frame.  `isatty` answers the same question without failing.
        raw: Raw = .unasked,
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
        /// Numeric data belonging to the most recently returned terminal
        /// event.  `term_event_data` reads this after `key_read`; the host
        /// owns it and every field is reset when input ends or the window
        /// changes.
        event: EventData = .{},
        last_rows: i64 = 0,
        last_columns: i64 = 0,
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

    /// The program said `exit(status)`.  Recorded here, at the exit
    /// site, while the program is still unwinding; the runner reads it
    /// back once `luce_main` answers `.exited` and maps it onto the
    /// process's own exit code.
    fn cExited(context: ?*anyopaque, status: i64) callconv(.c) void {
        of(context).exit_status = status;
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

    fn cPathKind(
        context: ?*anyopaque,
        path: [*]const u8,
        path_length: i64,
        kind: *i64,
    ) callconv(.c) abi.Answer {
        const found = of(context).pathKind(path[0..@intCast(path_length)]) orelse return .no;
        kind.* = found;
        return .yes;
    }

    // -- the byte channel's five slots ---------------------------------

    fn cHandleOpen(
        context: ?*anyopaque,
        path: [*]const u8,
        path_length: i64,
        mode: i64,
        handle: *i64,
    ) callconv(.c) abi.Answer {
        handle.* = of(context).openFile(
            path[0..@intCast(path_length)],
            @enumFromInt(mode),
        ) orelse return .no;
        return .yes;
    }

    fn cHandleRead(
        context: ?*anyopaque,
        handle: i64,
        into: [*]u8,
        capacity: i64,
        filled: *i64,
    ) callconv(.c) abi.Answer {
        const self = of(context);
        const row = self.openRow(handle) orelse return .no;
        // `readPositionalAll` fills the buffer or stops at the end of
        // the file and answers how far it got, which is exactly the
        // count this slot promises: short is the end, not a failure
        // (docs/BYTES.md R4).
        const landed = row.file.readPositionalAll(
            self.io,
            into[0..@intCast(capacity)],
            row.position,
        ) catch return .no;
        row.position += landed;
        filled.* = @intCast(landed);
        return .yes;
    }

    fn cHandleWrite(
        context: ?*anyopaque,
        handle: i64,
        from: [*]const u8,
        length: i64,
        written: *i64,
    ) callconv(.c) abi.Answer {
        const self = of(context);
        const row = self.openRow(handle) orelse return .no;
        const bytes = from[0..@intCast(length)];
        row.file.writePositionalAll(self.io, bytes, row.position) catch return .no;
        row.position += bytes.len;
        written.* = @intCast(bytes.len);
        return .yes;
    }

    fn cHandleFlush(context: ?*anyopaque, handle: i64) callconv(.c) abi.Answer {
        const self = of(context);
        const row = self.openRow(handle) orelse return .no;
        row.file.sync(self.io) catch return .no;
        return .yes;
    }

    fn cHandleClose(context: ?*anyopaque, handle: i64) callconv(.c) abi.Answer {
        const self = of(context);
        const row = self.openRow(handle) orelse return .no;
        row.file.close(self.io);
        row.shut = true;
        return .yes;
    }

    /// The channel both engines install into `libluce_rt`
    /// (docs/BYTES.md R2).  The `i32` twins are the same five
    /// functions: `abi.Answer` is an `enum(i32)` over the same three
    /// numbers the runtime library's own channel speaks, and the two
    /// spellings exist because one table is the published ABI and the
    /// other is the library's.
    pub fn fileChannel(self: *Host) luce.runtime.files.Channel {
        return .{
            .context = self,
            .open = pHandleOpen,
            .read = pHandleRead,
            .write = pHandleWrite,
            .flush = pHandleFlush,
            .close = pHandleClose,
        };
    }

    fn pHandleOpen(
        context: ?*anyopaque,
        path: [*]const u8,
        path_length: i64,
        mode: i64,
        handle: *i64,
    ) callconv(.c) i32 {
        return @intFromEnum(cHandleOpen(context, path, path_length, mode, handle));
    }

    fn pHandleRead(
        context: ?*anyopaque,
        handle: i64,
        into: [*]u8,
        capacity: i64,
        filled: *i64,
    ) callconv(.c) i32 {
        return @intFromEnum(cHandleRead(context, handle, into, capacity, filled));
    }

    fn pHandleWrite(
        context: ?*anyopaque,
        handle: i64,
        from: [*]const u8,
        length: i64,
        written: *i64,
    ) callconv(.c) i32 {
        return @intFromEnum(cHandleWrite(context, handle, from, length, written));
    }

    fn pHandleFlush(context: ?*anyopaque, handle: i64) callconv(.c) i32 {
        return @intFromEnum(cHandleFlush(context, handle));
    }

    fn pHandleClose(context: ?*anyopaque, handle: i64) callconv(.c) i32 {
        return @intFromEnum(cHandleClose(context, handle));
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

    fn cTermEventData(context: ?*anyopaque, field: i64) callconv(.c) i64 {
        return of(context).screen.event.field(field);
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

    /// The machine's own facts (`machine.zig`), which need nothing of
    /// this Host — but the slot is offered anyway, always, because
    /// loom withholds nothing.  A platform whose numbers we cannot ask
    /// for answers `no`, which the program meets as
    /// `host_unavailable`: the refusal travels, and no number is
    /// invented on the way.
    fn cTotalMemory(_: ?*anyopaque, answer: *i64) callconv(.c) abi.Answer {
        return told(machine.totalMemory(), answer);
    }

    fn cAvailableMemory(_: ?*anyopaque, answer: *i64) callconv(.c) abi.Answer {
        return told(machine.availableMemory(), answer);
    }

    fn cCpuCount(_: ?*anyopaque, answer: *i64) callconv(.c) abi.Answer {
        return told(machine.cpuCount(), answer);
    }

    fn told(fact: ?i64, answer: *i64) abi.Answer {
        answer.* = fact orelse return .no;
        return .yes;
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

    fn cShellRun(
        context: ?*anyopaque,
        command: [*]const u8,
        command_length: i64,
        text: *[*]const u8,
        length: *i64,
    ) callconv(.c) abi.Answer {
        const self = of(context);
        const output = (self.runShell(command[0..@intCast(command_length)]) catch
            return .exhausted) orelse return .no;
        text.* = output.ptr;
        length.* = @intCast(output.len);
        return .yes;
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

    fn cDirCreate(
        context: ?*anyopaque,
        path: [*]const u8,
        path_length: i64,
    ) callconv(.c) abi.Answer {
        return if (of(context).createDirectory(path[0..@intCast(path_length)])) .yes else .no;
    }

    fn cEpoch(context: ?*anyopaque, answer: *i64) callconv(.c) abi.Answer {
        answer.* = of(context).epochMilliseconds();
        return .yes;
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

/// One file the byte channel has open, and where it has got to.
///
/// The position is this host's rather than the descriptor's: the `Io`
/// file API is positional, which is what lets a handle be read and
/// written without a seek and what makes an append handle simply one
/// that started at the end.
const OpenFile = struct {
    file: std.Io.File,
    position: u64 = 0,
    /// A closed row keeps its place so a stale handle lands on it and
    /// is refused, instead of naming whoever moved in.
    shut: bool = false,
};

/// Numeric data belonging to the most recent terminal input event.
/// Coordinates are zero based; keyboard and resize events use row/column
/// zero, button -1, modifiers zero and value zero.  Modifiers use
/// shift=1, alt=2 and ctrl=4.
const EventData = struct {
    row: i64 = 0,
    column: i64 = 0,
    button: i64 = -1,
    modifiers: i64 = 0,
    value: i64 = 0,

    fn field(self: EventData, number: i64) i64 {
        return switch (number) {
            0 => self.row,
            1 => self.column,
            2 => self.button,
            3 => self.modifiers,
            4 => self.value,
            else => 0,
        };
    }
};

/// One decoded key as the host sees it, before either boundary copies
/// it: `name` is static text or `control_name`, `text` points into the
/// pending input buffer, and `event` carries mouse or resize data.
const KeyView = struct {
    name: []const u8,
    text: []const u8 = "",
    event: EventData = .{},
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
        .mouse => |mouse| .{
            .name = switch (mouse.kind) {
                .press => "mouse_press",
                .release => "mouse_release",
                .drag => "mouse_drag",
                .move => "mouse_move",
                .wheel => "mouse_wheel",
            },
            .event = .{
                .row = mouse.row,
                .column = mouse.column,
                .button = mouse.button,
                .modifiers = mouse.modifiers,
                .value = mouse.value,
            },
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

// The two files this host is the only consumer of, so their own tests
// run with it: naming an import is what puts a file's tests in the
// binary, and using its declarations is not.
test {
    _ = key_mod;
    _ = machine;
}

test "worker registry publishes and joins sibling nested threads under contention" {
    const Stress = struct {
        channel: luce.runtime.workers.Channel,
        go: std.atomic.Value(bool) = .init(false),
        ready: std.atomic.Value(u32) = .init(0),
        completed: std.atomic.Value(u32) = .init(0),
        failures: std.atomic.Value(u32) = .init(0),

        fn pause() void {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }

        fn leaf(argument: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(argument.?));
            _ = self.completed.fetchAdd(1, .monotonic);
        }

        fn branch(argument: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(argument.?));
            _ = self.ready.fetchAdd(1, .release);
            while (!self.go.load(.acquire)) pause();

            var nested: i64 = 0;
            if (self.channel.spawn.?(
                self.channel.context,
                leaf,
                self,
                &nested,
            ) != luce.runtime.workers.yes) {
                _ = self.failures.fetchAdd(1, .monotonic);
                return;
            }
            if (self.channel.join.?(self.channel.context, nested) != luce.runtime.workers.yes) {
                _ = self.failures.fetchAdd(1, .monotonic);
            }
        }
    };

    var written: std.Io.Writer.Allocating = .init(testing.allocator);
    defer written.deinit();
    var reported: std.Io.Writer.Allocating = .init(testing.allocator);
    defer reported.deinit();
    var host: Host = undefined;
    host.setup(testing.allocator, testing.io, &written.writer, &reported.writer, &.{});
    defer host.deinit();

    const sibling_count = 8;
    const rounds = 32;
    var stress: Stress = .{ .channel = host.workerChannel() };
    // If publishing one sibling fails, release every branch already
    // waiting at the round's gate before Host.deinit joins it.
    defer stress.go.store(true, .release);
    var siblings: [sibling_count]i64 = undefined;
    for (0..rounds) |_| {
        stress.go.store(false, .release);
        stress.ready.store(0, .release);
        for (&siblings) |*thread| {
            try testing.expectEqual(
                luce.runtime.workers.yes,
                stress.channel.spawn.?(stress.channel.context, Stress.branch, &stress, thread),
            );
        }
        while (stress.ready.load(.acquire) != sibling_count) Stress.pause();
        stress.go.store(true, .release);
        for (siblings) |thread| {
            try testing.expectEqual(
                luce.runtime.workers.yes,
                stress.channel.join.?(stress.channel.context, thread),
            );
        }
    }

    try testing.expectEqual(@as(u32, 0), stress.failures.load(.acquire));
    try testing.expectEqual(@as(u32, sibling_count * rounds), stress.completed.load(.acquire));
    try testing.expectEqual(@as(usize, sibling_count * rounds * 2), host.threads.items.len);
    for (host.threads.items) |thread| try testing.expectEqual(@as(?std.Thread, null), thread);
}

test "worker teardown closes publication and never joins under its registry lock" {
    const Closing = struct {
        channel: luce.runtime.workers.Channel,
        entered: std.atomic.Value(bool) = .init(false),
        go: std.atomic.Value(bool) = .init(false),
        nested_answer: std.atomic.Value(i32) = .init(luce.runtime.workers.exhausted),
        probe_entered: std.atomic.Value(bool) = .init(false),

        fn pause() void {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }

        fn probe(argument: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(argument.?));
            // Re-enter the registry.  If the rejected thread were
            // joined while its publisher still held the lock, this
            // callback and the teardown test would deadlock.
            if (self.channel.join.?(self.channel.context, 0) == luce.runtime.workers.no) {
                self.probe_entered.store(true, .release);
            }
        }

        fn parent(argument: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(argument.?));
            self.entered.store(true, .release);
            while (!self.go.load(.acquire)) pause();

            var nested: i64 = 0;
            const answer = self.channel.spawn.?(
                self.channel.context,
                probe,
                self,
                &nested,
            );
            self.nested_answer.store(answer, .release);
            if (answer == luce.runtime.workers.yes) {
                _ = self.channel.join.?(self.channel.context, nested);
            }
        }

        fn close(host: *Host) void {
            host.joinThreads();
        }
    };

    var written: std.Io.Writer.Allocating = .init(testing.allocator);
    defer written.deinit();
    var reported: std.Io.Writer.Allocating = .init(testing.allocator);
    defer reported.deinit();
    var host: Host = undefined;
    host.setup(testing.allocator, testing.io, &written.writer, &reported.writer, &.{});
    defer host.deinit();

    var closing: Closing = .{ .channel = host.workerChannel() };
    // An OS refusal while starting the teardown probe must not leave
    // the parent parked when the deferred Host.deinit drains it.
    defer closing.go.store(true, .release);
    var parent: i64 = 0;
    try testing.expectEqual(
        luce.runtime.workers.yes,
        closing.channel.spawn.?(closing.channel.context, Closing.parent, &closing, &parent),
    );
    while (!closing.entered.load(.acquire)) Closing.pause();

    const teardown = try std.Thread.spawn(.{}, Closing.close, .{&host});
    while (true) {
        host.thread_mutex.lockUncancelable(host.io);
        const started = host.threads_closing;
        host.thread_mutex.unlock(host.io);
        if (started) break;
        Closing.pause();
    }
    closing.go.store(true, .release);
    teardown.join();

    try testing.expectEqual(luce.runtime.workers.no, closing.nested_answer.load(.acquire));
    try testing.expect(closing.probe_entered.load(.acquire));
    try testing.expectEqual(@as(usize, 0), host.threads.items.len);
    // Teardown retains the old behavior of clearing the table: a
    // handle from the finished run is out of range, not recycled.
    try testing.expectEqual(
        luce.runtime.workers.no,
        closing.channel.join.?(closing.channel.context, parent),
    );
}

test "worker handles are append-only and a repeated join is harmless" {
    const Done = struct {
        fn run(_: ?*anyopaque) callconv(.c) void {}
    };

    var written: std.Io.Writer.Allocating = .init(testing.allocator);
    defer written.deinit();
    var reported: std.Io.Writer.Allocating = .init(testing.allocator);
    defer reported.deinit();
    var host: Host = undefined;
    host.setup(testing.allocator, testing.io, &written.writer, &reported.writer, &.{});
    defer host.deinit();

    const channel = host.workerChannel();
    var first: i64 = 0;
    try testing.expectEqual(
        luce.runtime.workers.yes,
        channel.spawn.?(channel.context, Done.run, null, &first),
    );
    try testing.expectEqual(luce.runtime.workers.yes, channel.join.?(channel.context, first));
    try testing.expectEqual(luce.runtime.workers.yes, channel.join.?(channel.context, first));

    var second: i64 = 0;
    try testing.expectEqual(
        luce.runtime.workers.yes,
        channel.spawn.?(channel.context, Done.run, null, &second),
    );
    try testing.expect(second > first);
    try testing.expectEqual(luce.runtime.workers.yes, channel.join.?(channel.context, second));
    try testing.expectEqual(luce.runtime.workers.no, channel.join.?(channel.context, 0));
}

test "worker table allocation failure rejects before starting user code" {
    const Probe = struct {
        started: std.atomic.Value(bool) = .init(false),
        gate: std.atomic.Value(bool) = .init(false),

        fn run(argument: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(argument.?));
            self.started.store(true, .release);
            while (!self.gate.load(.acquire)) std.Thread.yield() catch {};
        }
    };

    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
    failing.fail_index = failing.alloc_index;
    var written: std.Io.Writer.Allocating = .init(testing.allocator);
    defer written.deinit();
    var reported: std.Io.Writer.Allocating = .init(testing.allocator);
    defer reported.deinit();
    var host: Host = undefined;
    host.setup(failing.allocator(), testing.io, &written.writer, &reported.writer, &.{});
    defer host.deinit();

    var probe: Probe = .{};
    var handle: i64 = 77;
    try testing.expectEqual(
        luce.runtime.workers.no,
        host.workerChannel().spawn.?(
            host.workerChannel().context,
            Probe.run,
            &probe,
            &handle,
        ),
    );
    try testing.expectEqual(@as(i64, 77), handle);
    try testing.expect(!probe.started.load(.acquire));
    try testing.expectEqual(@as(usize, 0), host.threads.items.len);
    probe.gate.store(true, .release);
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

    // Through the byte channel, which is the path a program's file
    // services take (docs/BYTES.md R2).
    const table = host.table();
    var handle: i64 = 0;
    var moved_bytes: i64 = 0;

    // An absolute path, anywhere the process can reach.
    const absolute = try std.fs.path.join(testing.allocator, &.{ directory, "notes.txt" });
    defer testing.allocator.free(absolute);
    try testing.expectEqual(abi.Answer.yes, table.handle_open.?(
        table.context,
        absolute.ptr,
        @intCast(absolute.len),
        @intFromEnum(luce.runtime.files.Mode.write),
        &handle,
    ));
    try testing.expectEqual(
        abi.Answer.yes,
        table.handle_write.?(table.context, handle, "kept", 4, &moved_bytes),
    );
    try testing.expectEqual(abi.Answer.yes, table.handle_close.?(table.context, handle));

    // And a relative one that climbs out of where it started: the
    // directory's own name, reached through its parent.
    const climbing = try std.fs.path.join(testing.allocator, &.{
        directory,
        "..",
        std.fs.path.basename(directory),
        "notes.txt",
    });
    defer testing.allocator.free(climbing);
    try testing.expectEqual(@as(?i64, 1), host.pathKind(climbing));
    var read_back: [16]u8 = undefined;
    var filled: i64 = 0;
    try testing.expectEqual(abi.Answer.yes, table.handle_open.?(
        table.context,
        climbing.ptr,
        @intCast(climbing.len),
        @intFromEnum(luce.runtime.files.Mode.read),
        &handle,
    ));
    try testing.expectEqual(abi.Answer.yes, table.handle_read.?(
        table.context,
        handle,
        &read_back,
        read_back.len,
        &filled,
    ));
    try testing.expectEqualStrings("kept", read_back[0..@intCast(filled)]);
    try testing.expectEqual(abi.Answer.yes, table.handle_close.?(table.context, handle));
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

    // And the question was asked once.  It used to be asked on every
    // escape sequence, because nothing recorded the answer — which
    // cost a failing system call per cell run, and, since a pipe
    // answers `tcgetattr` with an errno `std.posix`'s wrapper does not
    // map, a *stack trace on standard error* per cell run with it.  A
    // program drawing into a pipe is ordinary (`loom run editor.lc >
    // frames.txt`, and every package test that presents a frame), so
    // this is the difference between its output and a wall of traces.
    try testing.expectEqual(Host.Screen.Raw.unavailable, scripted.host.screen.raw);
    try scripted.host.move(0, 0);
    try scripted.host.write("more");
    try testing.expectEqual(Host.Screen.Raw.unavailable, scripted.host.screen.raw);
    try testing.expect(!scripted.host.screen.active);
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
    // loom withholds nothing it still offers, so no slot may be null —
    // except the three the ABI **retired** at version 12, which are
    // deliberately empty because nothing indexes them any more
    // (docs/BYTES.md R2).  Naming them here rather than weakening the
    // sweep is the point: a fourth one going quiet would be caught.
    // `file_exists` joined them at version 17, for its own reason:
    // one bit could not tell absence from refusal (docs/FILESYSTEM.md
    // D16), and `path_kind` is what asks now.
    const retired = [_][]const u8{ "file_read", "file_write", "file_append", "file_exists" };
    inline for (@typeInfo(abi.Host).@"struct".fields) |field| {
        if (@typeInfo(field.type) == .optional) {
            var is_retired = false;
            for (retired) |name| {
                if (std.mem.eql(u8, name, field.name)) is_retired = true;
            }
            if (is_retired) {
                try testing.expect(@field(table, field.name) == null);
            } else {
                try testing.expect(@field(table, field.name) != null);
            }
        }
    }

    try testing.expectEqual(@as(i64, 2), table.arg_count.?(table.context));
    var text: [*]const u8 = undefined;
    var length: i64 = undefined;
    try testing.expectEqual(abi.Answer.yes, table.arg.?(table.context, 1, &text, &length));
    try testing.expectEqualStrings("beta", text[0..@intCast(length)]);
    try testing.expectEqual(abi.Answer.no, table.arg.?(table.context, 2, &text, &length));

    var found_kind: i64 = -1;
    try testing.expectEqual(
        abi.Answer.yes,
        table.path_kind.?(table.context, path.ptr, @intCast(path.len), &found_kind),
    );
    // Nothing there yet: an *answer*, not a refusal.  The two used to
    // be one `false` (docs/FILESYSTEM.md D16).
    try testing.expectEqual(@as(i64, 0), found_kind);
    // Writing and reading go through the byte channel now, which is
    // the whole of ABI version 12: the retired whole-file slots are
    // null above, and this is what stands in their place.
    var handle: i64 = 0;
    try testing.expectEqual(abi.Answer.yes, table.handle_open.?(
        table.context,
        path.ptr,
        @intCast(path.len),
        @intFromEnum(luce.runtime.files.Mode.write),
        &handle,
    ));
    var moved_bytes: i64 = 0;
    try testing.expectEqual(abi.Answer.yes, table.handle_write.?(
        table.context,
        handle,
        "kept",
        4,
        &moved_bytes,
    ));
    try testing.expectEqual(@as(i64, 4), moved_bytes);
    try testing.expectEqual(abi.Answer.yes, table.handle_flush.?(table.context, handle));
    try testing.expectEqual(abi.Answer.yes, table.handle_close.?(table.context, handle));
    // A handle that has been closed names nothing, which is what makes
    // a use after close an error a host can report rather than a
    // descriptor somebody else has since been given.
    try testing.expectEqual(abi.Answer.no, table.handle_close.?(table.context, handle));
    try testing.expectEqual(
        abi.Answer.yes,
        table.path_kind.?(table.context, path.ptr, @intCast(path.len), &found_kind),
    );
    try testing.expectEqual(@as(i64, 1), found_kind);
    // And the directory holding it is a directory, which is the
    // question `file_exists` could not answer at all.
    try testing.expectEqual(
        abi.Answer.yes,
        table.path_kind.?(table.context, directory.ptr, @intCast(directory.len), &found_kind),
    );
    try testing.expectEqual(@as(i64, 2), found_kind);

    var read_back: [16]u8 = undefined;
    var filled: i64 = 0;
    try testing.expectEqual(abi.Answer.yes, table.handle_open.?(
        table.context,
        path.ptr,
        @intCast(path.len),
        @intFromEnum(luce.runtime.files.Mode.read),
        &handle,
    ));
    try testing.expectEqual(abi.Answer.yes, table.handle_read.?(
        table.context,
        handle,
        &read_back,
        read_back.len,
        &filled,
    ));
    try testing.expectEqualStrings("kept", read_back[0..@intCast(filled)]);
    // Reading again at the end of the file answers zero, not a
    // refusal: short is how a file says it is finished.
    try testing.expectEqual(abi.Answer.yes, table.handle_read.?(
        table.context,
        handle,
        &read_back,
        read_back.len,
        &filled,
    ));
    try testing.expectEqual(@as(i64, 0), filled);
    try testing.expectEqual(abi.Answer.yes, table.handle_close.?(table.context, handle));

    try testing.expectEqual(abi.Answer.yes, table.print.?(table.context, "hello", 5));
    try testing.expectEqualStrings("hello\n", written.written());

    // The file operations beside the byte channel, over the same real
    // directory.  An append handle starts at the end of what is there.
    const moved = try std.fs.path.join(testing.allocator, &.{ directory, "kept.txt" });
    defer testing.allocator.free(moved);
    try testing.expectEqual(abi.Answer.yes, table.handle_open.?(
        table.context,
        path.ptr,
        @intCast(path.len),
        @intFromEnum(luce.runtime.files.Mode.append),
        &handle,
    ));
    try testing.expectEqual(abi.Answer.yes, table.handle_write.?(
        table.context,
        handle,
        " more",
        5,
        &moved_bytes,
    ));
    try testing.expectEqual(abi.Answer.yes, table.handle_close.?(table.context, handle));
    try testing.expectEqual(abi.Answer.yes, table.handle_open.?(
        table.context,
        path.ptr,
        @intCast(path.len),
        @intFromEnum(luce.runtime.files.Mode.read),
        &handle,
    ));
    try testing.expectEqual(abi.Answer.yes, table.handle_read.?(
        table.context,
        handle,
        &read_back,
        read_back.len,
        &filled,
    ));
    try testing.expectEqualStrings("kept more", read_back[0..@intCast(filled)]);
    try testing.expectEqual(abi.Answer.yes, table.handle_close.?(table.context, handle));
    try testing.expectEqual(abi.Answer.yes, table.file_rename.?(
        table.context,
        path.ptr,
        @intCast(path.len),
        moved.ptr,
        @intCast(moved.len),
    ));
    try testing.expectEqual(
        abi.Answer.yes,
        table.path_kind.?(table.context, path.ptr, @intCast(path.len), &found_kind),
    );
    try testing.expectEqual(@as(i64, 0), found_kind);
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

    // Making a directory: the parents come with it, saying it twice
    // is success rather than an error, and a *file* holding the name
    // is a refusal — the three rules `abi.DirCreateFn` publishes,
    // against the real file system rather than a model of one.
    const nested = try std.fs.path.join(
        testing.allocator,
        &.{ directory, "store", "packages", "geo-1.2.0" },
    );
    defer testing.allocator.free(nested);
    try testing.expectEqual(abi.Answer.yes, table.dir_create.?(
        table.context,
        nested.ptr,
        @intCast(nested.len),
    ));
    try testing.expectEqual(abi.Answer.yes, table.dir_create.?(
        table.context,
        nested.ptr,
        @intCast(nested.len),
    ));
    // The parents really are there: a listing of the outermost one
    // names the directory below it.
    const store = try std.fs.path.join(testing.allocator, &.{ directory, "store" });
    defer testing.allocator.free(store);
    try testing.expectEqual(abi.Answer.yes, table.dir_list.?(
        table.context,
        store.ptr,
        @intCast(store.len),
        &text,
        &length,
    ));
    try testing.expect(std.mem.indexOf(u8, text[0..@intCast(length)], "packages\x00") != null);
    const occupied = try std.fs.path.join(testing.allocator, &.{ directory, "in_the_way.txt" });
    defer testing.allocator.free(occupied);
    try testing.expectEqual(abi.Answer.yes, table.handle_open.?(
        table.context,
        occupied.ptr,
        @intCast(occupied.len),
        @intFromEnum(luce.runtime.files.Mode.write),
        &handle,
    ));
    try testing.expectEqual(abi.Answer.yes, table.handle_close.?(table.context, handle));
    try testing.expectEqual(abi.Answer.no, table.dir_create.?(
        table.context,
        occupied.ptr,
        @intCast(occupied.len),
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

    // The wall clock, held to what can be true of any calendar rather
    // than to today's date: a reading well past 2001 and well short of
    // 2100, and two readings in order.  A test that asserted a date
    // would be a test that expires.
    var stamped: i64 = undefined;
    var stamped_again: i64 = undefined;
    try testing.expectEqual(abi.Answer.yes, table.epoch_ms.?(table.context, &stamped));
    try testing.expect(stamped > 1_000_000_000_000);
    try testing.expect(stamped < 4_102_444_800_000);
    try testing.expectEqual(abi.Answer.yes, table.epoch_ms.?(table.context, &stamped_again));
    try testing.expect(stamped_again >= stamped);

    try testing.expectEqual(@as(i64, call_depth), table.call_depth.?(table.context));

    // The machine's facts, held to what can be true of any machine
    // rather than to this one's numbers.  `available <= total` is the
    // relation `std.os` promises and the only one that survives being
    // measured a moment apart.
    var total: i64 = undefined;
    var available: i64 = undefined;
    var processors: i64 = undefined;
    try testing.expectEqual(abi.Answer.yes, table.os_total_memory.?(table.context, &total));
    try testing.expect(total > 0);
    try testing.expectEqual(abi.Answer.yes, table.os_cpu_count.?(table.context, &processors));
    try testing.expect(processors >= 1);
    // Available memory is the one fact with platform code of its own:
    // required where that code exists, and permitted to answer `no`
    // where it does not — which is the refusal travelling rather than
    // a number being made up.
    const answered = table.os_available_memory.?(table.context, &available);
    switch (@import("builtin").os.tag) {
        .macos, .linux => {
            try testing.expectEqual(abi.Answer.yes, answered);
            try testing.expect(available > 0);
            try testing.expect(available <= total);
        },
        else => try testing.expect(answered == .yes or answered == .no),
    }

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
