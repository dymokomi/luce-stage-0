//! The two-engine harness: how the executable specification runs a
//! program.
//!
//! Every spec in this directory states a fact about the language, and
//! a fact about the language is a fact about **both** engines.  So a
//! spec never runs a program once.  It compiles once, then runs the
//! result twice — interpreted through `interpreter.run` against
//! a `Reference` host, and compiled through libLLVM, `cc` and `dlopen`
//! against a `Capture` host built from the same `World` — and demands
//! the same printed bytes, the same trap code, the same trap message,
//! the same call trace frame for frame, the same raised error, and the
//! same leak census.
//!
//! That is the whole point of keeping the interpreter (docs/ENGINE.md):
//! it ships in nothing, it is not an engine, and it exists to
//! disagree.  An oracle consulted by a handful of curated tests can
//! drift; an oracle that is the second arm of every spec cannot drift
//! silently.
//!
//! Nothing here allocates on behalf of a host callback.  The `Capture`
//! callbacks are entered from a `dlopen`ed library, and
//! `std.testing.allocator` captures a stack trace on every allocation:
//! the unwinder cannot walk back through the compiled program's frame
//! and faults inside the panic handler.  Every buffer in `Capture` is
//! therefore fixed, deliberately.
//!
//! **A fixed buffer that fills up says so, in the buffer** (`keepText`
//! below).  The oracle arm allocates and so always holds the whole
//! message; if this arm silently kept a prefix, `settle` would compare
//! a fragment against the whole and print a diff that looks exactly
//! like the two engines disagreeing about the program.  Naming the
//! harness's own limit instead costs one branch and never lies — and a
//! panic, the other thing that used to happen here, would take the
//! whole suite down over a message that was merely long.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

// The language and the emitter both come in as modules.  This file
// belongs to the `specs` module, which is the one place that names
// both: `luce` links no LLVM, `emit` is the only thing that does, and
// a spec needs each of them for one of its two arms.
const luce = @import("luce");
const emit = @import("emit");

const interpreter = luce.interpreter;
const compile = luce.compile;
const mir = luce.mir;
const types = luce.types;
const abi = luce.llvm.abi;
const lower = luce.llvm;

const Allocator = std.mem.Allocator;
const testing = std.testing;
const io = std.testing.io;

// ---------------------------------------------------------------------------
// The world both hosts present
// ---------------------------------------------------------------------------

/// What the two hosts below offer a program: one in-memory file, an
/// argument list, a screen that records instead of drawing, a scripted
/// keyboard, and scripted standard input.
///
/// Written once and shared, so the interpreter's host and the compiled
/// program's host cannot differ in *what* they offer — only in how they
/// are called.  A disagreement is then a lowering bug, which is the
/// only thing these comparisons are trying to find.
///
/// Each arm gets its own copy, so a program that writes a file cannot
/// leave the second run a world the first one changed.
pub const World = struct {
    file_name: [64]u8 = undefined,
    file_name_length: usize = 0,
    file_content: [1024]u8 = undefined,
    file_content_length: usize = 0,
    /// A world that will not take a write, which is the `io_failed`
    /// side of a fallible effect (docs/FAILURE.md).
    refuse_writes: bool = false,
    /// The command line this world was started with.
    arguments: []const []const u8 = &default_arguments,
    /// The keys the program will read.  The script does **not**
    /// repeat: running off the end is end of input, which is the case
    /// `key_read`'s `string?` exists for, and a repeating keyboard is
    /// one no test can ever reach the end of.
    keys: []const Key = &default_keys,
    /// How many keys the program has read.
    keys_read: usize = 0,
    /// The lines standard input will answer.  The script does *not*
    /// repeat: running off the end is end of input, which is the case
    /// a `string?` exists for.
    lines: []const []const u8 = &default_lines,
    /// How many lines of standard input have been taken.
    lines_read: usize = 0,
    /// The one directory this world will list, or null for a world
    /// whose listing fails.
    directory: ?[]const []const u8 = &default_directory,
    /// That listing, NUL-joined — the shape a compiled program takes
    /// it in.  Built from `directory` on demand rather than declared,
    /// so the two hosts can never say different things.
    joined_storage: [1024]u8 = undefined,
    joined_length: usize = 0,
    /// A clock that ticks a fixed amount per reading rather than a
    /// real one.  Two engines cannot agree on a wall clock, and what
    /// is under test is the marshalling, not the calendar.
    clock: i64 = 1_000,
    /// The machine this world claims to be, for the same reason the
    /// clock is not a real one: two engines cannot agree on what the
    /// real machine had free between the two runs, and what is under
    /// test is that the number crosses the boundary intact.
    ///
    /// A plausible machine — eight gibibytes, rather more than half of
    /// them spoken for — so a spec can assert the relations `std.os`
    /// promises (`available <= total`, `used = total - available`) on
    /// numbers a person can check by eye.
    total_memory: i64 = 8 * 1024 * 1024 * 1024,
    available_memory: i64 = 3 * 1024 * 1024 * 1024,
    cpu_count: i64 = 4,
    /// A machine this world cannot measure: every fact answers `no`,
    /// which is the host saying it cannot tell and the program meeting
    /// `host_unavailable` — the refusal a null slot gives, arriving
    /// through a slot that is there.
    unmeasurable: bool = false,

    pub const Key = struct { name: []const u8, text: []const u8 = "" };

    const rows: i64 = 24;
    const cols: i64 = 80;
    const clock_step: i64 = 17;

    const default_arguments = [_][]const u8{ "alpha", "beta" };
    const default_lines = [_][]const u8{ "first line", "second line" };
    const default_directory = [_][]const u8{ "alpha.txt", "beta.txt", "notes" };
    const default_keys = [_]Key{
        .{ .name = "text", .text = "q" },
        .{ .name = "enter" },
        .{ .name = "ctrl_s" },
    };

    const environment = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "LUCE_MODE", .value = "test" },
        .{ .name = "EMPTY", .value = "" },
    };

    /// A world whose one file is already there.  The seed goes in
    /// under `refuse_writes`, because refusing a program's writes says
    /// nothing about what the world started with.
    pub fn withFile(path: []const u8, content: []const u8) World {
        var world: World = .{};
        world.place(path, content);
        return world;
    }

    /// Put a file there without asking the world's permission.
    pub fn place(self: *World, path: []const u8, content: []const u8) void {
        std.debug.assert(path.len != 0 and path.len <= self.file_name.len);
        std.debug.assert(content.len <= self.file_content.len);
        @memcpy(self.file_name[0..path.len], path);
        self.file_name_length = path.len;
        @memcpy(self.file_content[0..content.len], content);
        self.file_content_length = content.len;
    }

    fn variable(name: []const u8) ?[]const u8 {
        for (environment) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.value;
        }
        return null;
    }

    fn nextLine(self: *World) ?[]const u8 {
        if (self.lines_read >= self.lines.len) return null;
        defer self.lines_read += 1;
        return self.lines[self.lines_read];
    }

    fn tick(self: *World) i64 {
        defer self.clock += clock_step;
        return self.clock;
    }

    /// The machine's three facts, or null for a world that cannot
    /// measure itself.  Fixed numbers rather than moving ones: the two
    /// engines run one after the other, and a fact that changed
    /// between them would be a disagreement about the machine rather
    /// than about the lowering.
    fn totalMemory(self: *World) ?i64 {
        return if (self.unmeasurable) null else self.total_memory;
    }

    fn availableMemory(self: *World) ?i64 {
        return if (self.unmeasurable) null else self.available_memory;
    }

    fn cpuCount(self: *World) ?i64 {
        return if (self.unmeasurable) null else self.cpu_count;
    }

    fn append(self: *World, path: []const u8, content: []const u8) bool {
        if (self.refuse_writes) return false;
        if (!self.exists(path)) return self.write(path, content);
        if (self.file_content_length + content.len > self.file_content.len) return false;
        @memcpy(self.file_content[self.file_content_length..][0..content.len], content);
        self.file_content_length += content.len;
        return true;
    }

    fn delete(self: *World, path: []const u8) bool {
        if (!self.exists(path)) return false;
        self.file_name_length = 0;
        self.file_content_length = 0;
        return true;
    }

    fn rename(self: *World, from: []const u8, to: []const u8) bool {
        if (!self.exists(from)) return false;
        if (to.len == 0 or to.len > self.file_name.len) return false;
        @memcpy(self.file_name[0..to.len], to);
        self.file_name_length = to.len;
        return true;
    }

    /// The file's bytes, or null when nothing of that name was written.
    /// Borrowed until the next write.
    fn read(self: *const World, path: []const u8) ?[]const u8 {
        if (!self.exists(path)) return null;
        return self.file_content[0..self.file_content_length];
    }

    fn write(self: *World, path: []const u8, content: []const u8) bool {
        if (self.refuse_writes) return false;
        if (path.len == 0 or path.len > self.file_name.len) return false;
        if (content.len > self.file_content.len) return false;
        self.place(path, content);
        return true;
    }

    fn exists(self: *const World, path: []const u8) bool {
        if (self.file_name_length == 0) return false;
        return std.mem.eql(u8, self.file_name[0..self.file_name_length], path);
    }

    fn argument(self: *const World, index: i64) ?[]const u8 {
        if (index < 0 or index >= self.arguments.len) return null;
        return self.arguments[@intCast(index)];
    }

    fn nextKey(self: *World) ?Key {
        if (self.keys_read >= self.keys.len) return null;
        defer self.keys_read += 1;
        return self.keys[self.keys_read];
    }

    /// The listing a compiled program takes, NUL-joined into this
    /// world's own buffer.  Null when the world will not list.
    fn joinedDirectory(self: *World, path: []const u8) ?[]const u8 {
        const names = self.listing(path) orelse return null;
        self.joined_length = 0;
        for (names) |name| {
            std.debug.assert(self.joined_length + name.len + 1 <= self.joined_storage.len);
            @memcpy(self.joined_storage[self.joined_length..][0..name.len], name);
            self.joined_length += name.len;
            self.joined_storage[self.joined_length] = 0;
            self.joined_length += 1;
        }
        return self.joined_storage[0..self.joined_length];
    }

    /// One directory exists, named "." ; anything else is a listing
    /// the world refuses, which is the `io_failed` side under test.
    fn listing(self: *const World, path: []const u8) ?[]const []const u8 {
        if (!std.mem.eql(u8, path, ".")) return null;
        return self.directory;
    }
};

/// The screen effects, as words: both hosts record the same ones, so a
/// comparison covers drawing as well as printing.
fn positionText(buffer: []u8, row: i64, col: i64) []const u8 {
    return std.fmt.bufPrint(buffer, "{d},{d}", .{ row, col }) catch unreachable;
}

fn styleText(buffer: []u8, foreground: i64, background: i64, bold: bool) []const u8 {
    return std.fmt.bufPrint(buffer, "{d},{d},{}", .{ foreground, background, bold }) catch unreachable;
}

/// What a host offers: which groups of services exist, how deep it
/// lets calls go, and the world behind them.  Every service in the ABI
/// is optional, and a program that reaches for one that is not there
/// traps `host_unavailable` rather than touching anything — so a spec
/// can withhold a group and demand exactly that.
pub const Provided = struct {
    print: bool = true,
    files: bool = true,
    arguments: bool = true,
    terminal: bool = true,
    /// Standard input, standard error, the clock, and the environment
    /// — four groups because a host may plausibly have any of them
    /// without the others, and each has to fail closed on its own.
    input: bool = true,
    diagnostics: bool = true,
    clock: bool = true,
    environment: bool = true,
    /// The `exited` slot, its own group like every other effect: a
    /// host may run programs whose exits it cannot carry, and `exit`
    /// then fails closed (`host_unavailable`).
    exit: bool = true,
    /// The three machine-fact slots, one group: a host either knows
    /// how to ask its platform about itself or does not, and a program
    /// that reaches one of them without it fails closed like every
    /// other withheld effect.  Distinct from `World.unmeasurable`,
    /// which is a host that *has* the slots and cannot tell — the two
    /// refusals arrive at the same trap by different roads, and both
    /// are worth a spec.
    machine: bool = true,
    /// The depth limit both engines run under.  The ABI's default is
    /// the interpreter's default, so a spec only names this when it
    /// wants a shallower one.
    call_depth: u32 = @intCast(abi.default_call_depth),
    /// The world each arm gets its own copy of.
    world: World = .{},

    /// A host that offers nothing at all: every effect fails closed,
    /// which is what a program given no host must see.
    pub const nothing: Provided = .{
        .print = false,
        .files = false,
        .arguments = false,
        .terminal = false,
        .input = false,
        .diagnostics = false,
        .clock = false,
        .environment = false,
        .exit = false,
        .machine = false,
    };

    /// A host with a console and nothing else: every other service is
    /// optional, and reaching one that is not there must touch nothing
    /// (docs/V2.md's fail-closed rule).
    pub const console_only: Provided = console: {
        var only = nothing;
        only.print = true;
        break :console only;
    };
};

/// One line of a call trace, in the one shape the two engines are
/// compared in.  Written once and used by both hosts, so a difference
/// is a difference in the trace and never in the rendering.
fn traceLine(
    buffer: []u8,
    function: []const u8,
    source: []const u8,
    line: u32,
    column: u32,
) []const u8 {
    return std.fmt.bufPrint(buffer, "{s} {s}:{d}:{d}\n", .{
        function, source, line, column,
    }) catch unreachable;
}

fn droppedLine(buffer: []u8, dropped: u32) []const u8 {
    return std.fmt.bufPrint(buffer, "... {d} more\n", .{dropped}) catch unreachable;
}

/// Put a host message into one of `Capture`'s fixed buffers, and
/// answer how much of the buffer it filled.
///
/// **One policy for both failure channels.**  A message that does not
/// fit is replaced — not truncated — by a sentence naming this
/// harness's own limit.  The oracle arm allocates and always holds the
/// whole message, so a silent prefix would be compared against the
/// whole one and `settle` would print a diff that reads as the two
/// engines disagreeing about the program; a panic, which is what the
/// trap channel used to do, takes the suite down over a message that
/// was only long.  `raiseIo` builds `verb ++ path` (`runtime/heap.zig`),
/// so a long enough path reaches this for real.
///
/// The sentence itself always fits: `buffer` is 256 bytes and the
/// longest form of it is under 80.
fn keepText(buffer: []u8, words: []const u8) usize {
    if (words.len <= buffer.len) {
        @memcpy(buffer[0..words.len], words);
        return words.len;
    }
    const said = std.fmt.bufPrint(
        buffer,
        "<agree.zig: a {d}-byte message does not fit its {d}-byte capture buffer>",
        .{ words.len, buffer.len },
    ) catch unreachable;
    return said.len;
}

// ---------------------------------------------------------------------------
// A host, in Zig
// ---------------------------------------------------------------------------

/// What a run of a compiled program did: the transcript it produced,
/// how it ended, and what it left unfreed.
pub const Capture = struct {
    world: World = .{},
    printed_storage: [32768]u8 = undefined,
    printed_length: usize = 0,
    trap_code: ?mir.TrapCode = null,
    trap_storage: [256]u8 = undefined,
    trap_length: usize = 0,
    /// The error nobody caught, and the one position it carries — the
    /// other way a run can end (docs/FAILURE.md).
    error_code: ?mir.ErrorCode = null,
    error_storage: [256]u8 = undefined,
    error_length: usize = 0,
    origin_storage: [256]u8 = undefined,
    origin_length: usize = 0,
    /// The call trace that came with the trap, already rendered — the
    /// host has nowhere to allocate, and the text is what is compared.
    trace_storage: [8192]u8 = undefined,
    trace_length: usize = 0,
    /// Objects the run did not free, or null when it never finished.
    leaked: ?i64 = null,
    /// The status `exit(status)` carried, or null when the program
    /// never exited.
    exit_status: ?i64 = null,
    /// What this host answers when asked how deep calls may go.
    call_depth: i64 = abi.default_call_depth,

    // What this run said, each borrowed from a fixed buffer inside
    // this Capture.  **The next run overwrites all five**: a Capture is
    // reused across the two engines on purpose (the header says why the
    // buffers are fixed), so anything a caller needs after the second
    // run has to be copied out before it starts.

    pub fn printed(self: *const Capture) []const u8 {
        return self.printed_storage[0..self.printed_length];
    }

    pub fn trapMessage(self: *const Capture) []const u8 {
        return self.trap_storage[0..self.trap_length];
    }

    pub fn trapTrace(self: *const Capture) []const u8 {
        return self.trace_storage[0..self.trace_length];
    }

    pub fn errorMessage(self: *const Capture) []const u8 {
        return self.error_storage[0..self.error_length];
    }

    pub fn errorOrigin(self: *const Capture) []const u8 {
        return self.origin_storage[0..self.origin_length];
    }

    /// The table the compiled program indexes.  A withheld group leaves
    /// its slots null, which is what the fail-closed rule reads.
    fn table(self: *Capture, provided: Provided) abi.Host {
        self.call_depth = provided.call_depth;
        self.world = provided.world;
        return .{
            .context = self,
            .call_depth = callDepth,
            .print = if (provided.print) print else null,
            .trap = reportTrap,
            .finished = finished,
            .file_read = if (provided.files) fileRead else null,
            .file_write = if (provided.files) fileWrite else null,
            .file_exists = if (provided.files) fileExists else null,
            .arg_count = if (provided.arguments) argCount else null,
            .arg = if (provided.arguments) argAt else null,
            .term_rows = if (provided.terminal) termRows else null,
            .term_cols = if (provided.terminal) termCols else null,
            .term_clear = if (provided.terminal) termClear else null,
            .term_move = if (provided.terminal) termMove else null,
            .term_style = if (provided.terminal) termStyle else null,
            .term_write = if (provided.terminal) termWrite else null,
            .term_flush = if (provided.terminal) termFlush else null,
            .key_read = if (provided.terminal) keyRead else null,
            .raised = raised,
            .file_append = if (provided.files) fileAppend else null,
            .file_delete = if (provided.files) fileDelete else null,
            .file_rename = if (provided.files) fileRename else null,
            .dir_list = if (provided.files) dirList else null,
            .read_line = if (provided.input) readLine else null,
            .print_error = if (provided.diagnostics) printError else null,
            .clock_ms = if (provided.clock) clockMilliseconds else null,
            .sleep_ms = if (provided.clock) sleepMilliseconds else null,
            .exited = if (provided.exit) exited else null,
            .env = if (provided.environment) environmentValue else null,
            .os_total_memory = if (provided.machine) totalMemory else null,
            .os_available_memory = if (provided.machine) availableMemory else null,
            .os_cpu_count = if (provided.machine) cpuCount else null,
        };
    }

    fn of(context: ?*anyopaque) *Capture {
        return @ptrCast(@alignCast(context.?));
    }

    /// One transcript line: a tag naming the effect, then its text.
    fn record(self: *Capture, tag: []const u8, text: []const u8) void {
        const total = tag.len + text.len + 1;
        if (self.printed_length + total > self.printed_storage.len) @panic("printed too much");
        @memcpy(self.printed_storage[self.printed_length..][0..tag.len], tag);
        self.printed_length += tag.len;
        @memcpy(self.printed_storage[self.printed_length..][0..text.len], text);
        self.printed_length += text.len;
        self.printed_storage[self.printed_length] = '\n';
        self.printed_length += 1;
    }

    fn print(context: ?*anyopaque, text: [*]const u8, length: i64) callconv(.c) abi.Answer {
        of(context).record("", text[0..@intCast(length)]);
        return .yes;
    }

    fn raised(
        context: ?*anyopaque,
        code: i32,
        message: [*]const u8,
        message_length: i64,
        origin: *const abi.TraceFrame,
    ) callconv(.c) void {
        const self = of(context);
        const words = message[0..@intCast(message_length)];
        self.error_code = @enumFromInt(code);
        self.error_length = keepText(&self.error_storage, words);
        const rendered = traceLine(
            &self.origin_storage,
            origin.function[0..@intCast(origin.function_length)],
            origin.source[0..@intCast(origin.source_length)],
            origin.line,
            origin.column,
        );
        self.origin_length = rendered.len;
    }

    fn callDepth(context: ?*anyopaque) callconv(.c) i64 {
        return of(context).call_depth;
    }

    fn reportTrap(
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
        self.trap_code = @enumFromInt(code);
        self.trap_length = keepText(&self.trap_storage, words);

        var encoded: [512]u8 = undefined;
        self.trace_length = 0;
        for (frames[0..@intCast(frame_count)]) |frame| {
            self.keepTrace(traceLine(
                &encoded,
                frame.function[0..@intCast(frame.function_length)],
                frame.source[0..@intCast(frame.source_length)],
                frame.line,
                frame.column,
            ));
        }
        if (dropped != 0) self.keepTrace(droppedLine(&encoded, @intCast(dropped)));
    }

    fn keepTrace(self: *Capture, line: []const u8) void {
        if (self.trace_length + line.len > self.trace_storage.len) @panic("trace too long");
        @memcpy(self.trace_storage[self.trace_length..][0..line.len], line);
        self.trace_length += line.len;
    }

    fn finished(context: ?*anyopaque, leaked: i64) callconv(.c) void {
        of(context).leaked = leaked;
    }

    fn exited(context: ?*anyopaque, status: i64) callconv(.c) void {
        of(context).exit_status = status;
    }

    fn fileRead(
        context: ?*anyopaque,
        path: [*]const u8,
        path_length: i64,
        text: *[*]const u8,
        length: *i64,
    ) callconv(.c) abi.Answer {
        const found = of(context).world.read(path[0..@intCast(path_length)]) orelse return .no;
        text.* = found.ptr;
        length.* = @intCast(found.len);
        return .yes;
    }

    fn fileWrite(
        context: ?*anyopaque,
        path: [*]const u8,
        path_length: i64,
        content: [*]const u8,
        content_length: i64,
    ) callconv(.c) abi.Answer {
        const wrote = of(context).world.write(
            path[0..@intCast(path_length)],
            content[0..@intCast(content_length)],
        );
        return if (wrote) .yes else .no;
    }

    fn fileExists(
        context: ?*anyopaque,
        path: [*]const u8,
        path_length: i64,
    ) callconv(.c) abi.Answer {
        return if (of(context).world.exists(path[0..@intCast(path_length)])) .yes else .no;
    }

    fn argCount(context: ?*anyopaque) callconv(.c) i64 {
        return @intCast(of(context).world.arguments.len);
    }

    fn argAt(
        context: ?*anyopaque,
        index: i64,
        text: *[*]const u8,
        length: *i64,
    ) callconv(.c) abi.Answer {
        const found = of(context).world.argument(index) orelse return .no;
        text.* = found.ptr;
        length.* = @intCast(found.len);
        return .yes;
    }

    fn termRows(context: ?*anyopaque) callconv(.c) i64 {
        _ = context;
        return World.rows;
    }

    fn termCols(context: ?*anyopaque) callconv(.c) i64 {
        _ = context;
        return World.cols;
    }

    fn termClear(context: ?*anyopaque) callconv(.c) abi.Answer {
        of(context).record("[clear]", "");
        return .yes;
    }

    fn termMove(context: ?*anyopaque, row: i64, col: i64) callconv(.c) abi.Answer {
        var encoded: [48]u8 = undefined;
        of(context).record("[move]", positionText(&encoded, row, col));
        return .yes;
    }

    fn termStyle(
        context: ?*anyopaque,
        foreground: i64,
        background: i64,
        bold: i32,
    ) callconv(.c) abi.Answer {
        var encoded: [64]u8 = undefined;
        of(context).record("[style]", styleText(&encoded, foreground, background, bold != 0));
        return .yes;
    }

    fn termWrite(context: ?*anyopaque, text: [*]const u8, length: i64) callconv(.c) abi.Answer {
        of(context).record("[write]", text[0..@intCast(length)]);
        return .yes;
    }

    fn termFlush(context: ?*anyopaque) callconv(.c) abi.Answer {
        of(context).record("[flush]", "");
        return .yes;
    }

    fn keyRead(
        context: ?*anyopaque,
        name: *[*]const u8,
        name_length: *i64,
        text: *[*]const u8,
        text_length: *i64,
    ) callconv(.c) abi.Answer {
        const pressed = of(context).world.nextKey() orelse return .no;
        name.* = pressed.name.ptr;
        name_length.* = @intCast(pressed.name.len);
        text.* = pressed.text.ptr;
        text_length.* = @intCast(pressed.text.len);
        return .yes;
    }

    fn fileAppend(
        context: ?*anyopaque,
        path: [*]const u8,
        path_length: i64,
        content: [*]const u8,
        content_length: i64,
    ) callconv(.c) abi.Answer {
        const added = of(context).world.append(
            path[0..@intCast(path_length)],
            content[0..@intCast(content_length)],
        );
        return if (added) .yes else .no;
    }

    fn fileDelete(
        context: ?*anyopaque,
        path: [*]const u8,
        path_length: i64,
    ) callconv(.c) abi.Answer {
        return if (of(context).world.delete(path[0..@intCast(path_length)])) .yes else .no;
    }

    fn fileRename(
        context: ?*anyopaque,
        from: [*]const u8,
        from_length: i64,
        to: [*]const u8,
        to_length: i64,
    ) callconv(.c) abi.Answer {
        const moved = of(context).world.rename(
            from[0..@intCast(from_length)],
            to[0..@intCast(to_length)],
        );
        return if (moved) .yes else .no;
    }

    fn dirList(
        context: ?*anyopaque,
        path: [*]const u8,
        path_length: i64,
        names: *[*]const u8,
        names_length: *i64,
    ) callconv(.c) abi.Answer {
        const self = of(context);
        const joined = self.world.joinedDirectory(path[0..@intCast(path_length)]) orelse return .no;
        names.* = joined.ptr;
        names_length.* = @intCast(joined.len);
        return .yes;
    }

    fn readLine(
        context: ?*anyopaque,
        prompt: [*]const u8,
        prompt_length: i64,
        text: *[*]const u8,
        length: *i64,
    ) callconv(.c) abi.Answer {
        const self = of(context);
        self.record("[prompt]", prompt[0..@intCast(prompt_length)]);
        const line = self.world.nextLine() orelse return .no;
        text.* = line.ptr;
        length.* = @intCast(line.len);
        return .yes;
    }

    fn printError(context: ?*anyopaque, text: [*]const u8, length: i64) callconv(.c) abi.Answer {
        of(context).record("[stderr]", text[0..@intCast(length)]);
        return .yes;
    }

    fn clockMilliseconds(context: ?*anyopaque) callconv(.c) i64 {
        return of(context).world.tick();
    }

    fn totalMemory(context: ?*anyopaque, answer: *i64) callconv(.c) abi.Answer {
        return told(of(context).world.totalMemory(), answer);
    }

    fn availableMemory(context: ?*anyopaque, answer: *i64) callconv(.c) abi.Answer {
        return told(of(context).world.availableMemory(), answer);
    }

    fn cpuCount(context: ?*anyopaque, answer: *i64) callconv(.c) abi.Answer {
        return told(of(context).world.cpuCount(), answer);
    }

    fn told(fact: ?i64, answer: *i64) abi.Answer {
        answer.* = fact orelse return .no;
        return .yes;
    }

    fn sleepMilliseconds(context: ?*anyopaque, milliseconds: i64) callconv(.c) abi.Answer {
        var encoded: [32]u8 = undefined;
        of(context).record("[sleep]", std.fmt.bufPrint(
            &encoded,
            "{d}",
            .{milliseconds},
        ) catch unreachable);
        return .yes;
    }

    fn environmentValue(
        context: ?*anyopaque,
        name: [*]const u8,
        name_length: i64,
        text: *[*]const u8,
        length: *i64,
    ) callconv(.c) abi.Answer {
        _ = context;
        const found = World.variable(name[0..@intCast(name_length)]) orelse return .no;
        text.* = found.ptr;
        length.* = @intCast(found.len);
        return .yes;
    }
};

/// The same program on the interpreter: the oracle, and the thing a
/// compiled run has to agree with byte for byte.
pub const Reference = struct {
    gpa: Allocator = testing.allocator,
    provided: Provided = .{},
    world: World = .{},
    printed: std.ArrayList(u8) = .empty,
    trap_code: ?mir.TrapCode = null,
    trap_message: []const u8 = "",
    /// The trap's call trace, rendered the same way the compiled host
    /// renders its own.
    trap_trace: std.ArrayList(u8) = .empty,
    /// The error nobody caught, and the one line it carries.
    error_code: ?mir.ErrorCode = null,
    error_message: []const u8 = "",
    error_origin: std.ArrayList(u8) = .empty,
    leaked: ?u32 = null,
    /// The status `exit(status)` carried, or null when the program
    /// never exited.
    exit_status: ?i64 = null,

    pub fn deinit(self: *Reference) void {
        self.printed.deinit(self.gpa);
        self.trap_trace.deinit(self.gpa);
        self.error_origin.deinit(self.gpa);
        self.gpa.free(self.trap_message);
        self.gpa.free(self.error_message);
    }

    fn of(context: *anyopaque) *Reference {
        return @ptrCast(@alignCast(context));
    }

    fn record(self: *Reference, tag: []const u8, text: []const u8) error{OutOfMemory}!void {
        try self.printed.appendSlice(self.gpa, tag);
        try self.printed.appendSlice(self.gpa, text);
        try self.printed.append(self.gpa, '\n');
    }

    fn host(self: *Reference) interpreter.Host {
        return .{
            .context = self,
            .print = if (self.provided.print) take else null,
            .file_read = if (self.provided.files) readFile else null,
            .file_write = if (self.provided.files) writeFile else null,
            .file_exists = if (self.provided.files) fileExists else null,
            .file_append = if (self.provided.files) appendFile else null,
            .file_delete = if (self.provided.files) deleteFile else null,
            .file_rename = if (self.provided.files) renameFile else null,
            .dir_list = if (self.provided.files) listDirectory else null,
            .read_line = if (self.provided.input) readLine else null,
            .print_error = if (self.provided.diagnostics) printError else null,
            .clock_ms = if (self.provided.clock) clockMilliseconds else null,
            .sleep_ms = if (self.provided.clock) sleepMilliseconds else null,
            .env = if (self.provided.environment) environmentValue else null,
            .exited = if (self.provided.exit) exitedHook else null,
            .os_total_memory = if (self.provided.machine) totalMemory else null,
            .os_available_memory = if (self.provided.machine) availableMemory else null,
            .os_cpu_count = if (self.provided.machine) cpuCount else null,
            .arg_count = if (self.provided.arguments) argCount else null,
            .arg = if (self.provided.arguments) argAt else null,
            .terminal = if (self.provided.terminal) .{
                .context = self,
                .term_rows = termRows,
                .term_cols = termCols,
                .term_clear = termClear,
                .term_move = termMove,
                .term_style = termStyle,
                .term_write = termWrite,
                .term_flush = termFlush,
                .key_read = keyRead,
            } else null,
        };
    }

    fn take(context: *anyopaque, text: []const u8) error{OutOfMemory}!void {
        try of(context).record("", text);
    }

    fn readFile(
        context: *anyopaque,
        arena: Allocator,
        path: []const u8,
    ) error{OutOfMemory}!interpreter.FileRead {
        const found = of(context).world.read(path) orelse return .failed;
        return .{ .content = try arena.dupe(u8, found) };
    }

    fn writeFile(context: *anyopaque, path: []const u8, content: []const u8) bool {
        return of(context).world.write(path, content);
    }

    fn fileExists(context: *anyopaque, path: []const u8) bool {
        return of(context).world.exists(path);
    }

    fn appendFile(context: *anyopaque, path: []const u8, content: []const u8) bool {
        return of(context).world.append(path, content);
    }

    fn deleteFile(context: *anyopaque, path: []const u8) bool {
        return of(context).world.delete(path);
    }

    fn renameFile(context: *anyopaque, from: []const u8, to: []const u8) bool {
        return of(context).world.rename(from, to);
    }

    fn listDirectory(
        context: *anyopaque,
        arena: Allocator,
        path: []const u8,
    ) error{OutOfMemory}!?[]const []const u8 {
        _ = arena;
        return of(context).world.listing(path);
    }

    fn readLine(
        context: *anyopaque,
        arena: Allocator,
        prompt: []const u8,
    ) error{OutOfMemory}!?[]const u8 {
        _ = arena;
        const self = of(context);
        try self.record("[prompt]", prompt);
        return self.world.nextLine();
    }

    fn printError(context: *anyopaque, text: []const u8) error{OutOfMemory}!void {
        try of(context).record("[stderr]", text);
    }

    fn clockMilliseconds(context: *anyopaque) i64 {
        return of(context).world.tick();
    }

    fn sleepMilliseconds(context: *anyopaque, milliseconds: i64) void {
        var encoded: [32]u8 = undefined;
        of(context).record("[sleep]", std.fmt.bufPrint(
            &encoded,
            "{d}",
            .{milliseconds},
        ) catch unreachable) catch {};
    }

    fn environmentValue(
        context: *anyopaque,
        arena: Allocator,
        name: []const u8,
    ) error{OutOfMemory}!?[]const u8 {
        _ = context;
        _ = arena;
        return World.variable(name);
    }

    fn argCount(context: *anyopaque) u32 {
        return @intCast(of(context).world.arguments.len);
    }

    fn argAt(context: *anyopaque, arena: Allocator, index: u32) error{OutOfMemory}!?[]const u8 {
        const found = of(context).world.argument(index) orelse return null;
        return try arena.dupe(u8, found);
    }

    fn termRows(context: *anyopaque) i64 {
        _ = context;
        return World.rows;
    }

    fn termCols(context: *anyopaque) i64 {
        _ = context;
        return World.cols;
    }

    fn termClear(context: *anyopaque) error{OutOfMemory}!void {
        try of(context).record("[clear]", "");
    }

    fn termMove(context: *anyopaque, row: i64, col: i64) error{OutOfMemory}!void {
        var encoded: [48]u8 = undefined;
        try of(context).record("[move]", positionText(&encoded, row, col));
    }

    fn termStyle(
        context: *anyopaque,
        foreground: i64,
        background: i64,
        bold: bool,
    ) error{OutOfMemory}!void {
        var encoded: [64]u8 = undefined;
        try of(context).record("[style]", styleText(&encoded, foreground, background, bold));
    }

    fn termWrite(context: *anyopaque, text: []const u8) error{OutOfMemory}!void {
        try of(context).record("[write]", text);
    }

    fn termFlush(context: *anyopaque) error{OutOfMemory}!void {
        try of(context).record("[flush]", "");
    }

    fn keyRead(context: *anyopaque, arena: Allocator) error{OutOfMemory}!?interpreter.KeyEvent {
        _ = arena;
        const pressed = of(context).world.nextKey() orelse return null;
        return .{ .name = pressed.name, .text = pressed.text };
    }

    fn exitedHook(context: *anyopaque, status: i64) void {
        of(context).exit_status = status;
    }

    fn totalMemory(context: *anyopaque) ?i64 {
        return of(context).world.totalMemory();
    }

    fn availableMemory(context: *anyopaque) ?i64 {
        return of(context).world.availableMemory();
    }

    fn cpuCount(context: *anyopaque) ?i64 {
        return of(context).world.cpuCount();
    }

    pub fn run(self: *Reference, compiled: *const mir.Program) !void {
        self.world = self.provided.world;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const result = try interpreter.run(
            .{ .arena = arena.allocator(), .objects = self.gpa },
            compiled,
            .{ .call_depth = self.provided.call_depth },
            self.host(),
        );
        switch (result) {
            .success => |ended| self.leaked = ended.leaked_objects,
            .exited => |ended| {
                self.exit_status = ended.status;
                self.leaked = ended.leaked_objects;
            },
            .trap => |raised| {
                self.trap_code = raised.code;
                // The arena goes at the end of this function, so keep
                // the words rather than a borrow of them.
                self.trap_message = try self.gpa.dupe(u8, raised.message);
                var encoded: [512]u8 = undefined;
                for (raised.trace) |frame| {
                    try self.trap_trace.appendSlice(self.gpa, traceLine(
                        &encoded,
                        frame.function,
                        frame.source,
                        frame.line,
                        frame.column,
                    ));
                }
                if (raised.dropped != 0) {
                    try self.trap_trace.appendSlice(
                        self.gpa,
                        droppedLine(&encoded, raised.dropped),
                    );
                }
            },
            .errored => |raised| {
                self.error_code = raised.code;
                self.error_message = try self.gpa.dupe(u8, raised.message);
                var encoded: [512]u8 = undefined;
                try self.error_origin.appendSlice(self.gpa, traceLine(
                    &encoded,
                    raised.origin.function,
                    raised.origin.source,
                    raised.origin.line,
                    raised.origin.column,
                ));
            },
        }
    }
};

// ---------------------------------------------------------------------------
// The pipeline, as a test harness
// ---------------------------------------------------------------------------

/// The options every spec compiles under: a script, with the host
/// gate open.  A spec that wants the gate shut is asking about the
/// analyzer, and that is a compile-error test.
pub const hosted: types.CompileOptions = .{
    .allow_host = true,
    .source_name = "test.luc",
};

/// Compile one script; the caller owns the program.  A compile failure
/// is a broken spec, not an outcome under test, so it fails loudly.
pub fn program(source: []const u8) !mir.Program {
    return programWith(source, hosted);
}

pub fn programWith(source: []const u8, options: types.CompileOptions) !mir.Program {
    var result = try compile.compile(testing.allocator, source, options);
    switch (result) {
        .success => |compiled| return compiled,
        .failure => |*diagnostics| {
            const rendered = try diagnostics.render(testing.allocator);
            defer testing.allocator.free(rendered);
            std.debug.print("unexpected compile failure:\n{s}", .{rendered});
            result.deinit();
            return error.CompileFailed;
        },
    }
}

/// One sibling file of a project, for the specs that compile several
/// (`compile/modules.zig`).
pub const File = struct { name: []const u8, source: []const u8 };

/// A loader over an in-memory set of files.  Nothing here touches the
/// disk: what is under test is how the compiler joins several files
/// into one program, not how a host finds them.
const Files = struct {
    all: []const File,

    fn find(
        context: *anyopaque,
        arena: Allocator,
        name: []const u8,
    ) error{OutOfMemory}!luce.source.Found {
        const self: *Files = @ptrCast(@alignCast(context));
        for (self.all) |file| {
            if (std.mem.eql(u8, file.name, name)) {
                return .{ .text = .{ .bytes = try arena.dupe(u8, file.source) } };
            }
        }
        return .missing;
    }
};

/// Compile `root` against `files` as one program; the caller owns it.
pub fn project(root: []const u8, files: []const File) !mir.Program {
    var found: Files = .{ .all = files };
    var result = try compile.compileProject(
        testing.allocator,
        root,
        .{ .context = &found, .load = Files.find },
        hosted,
    );
    switch (result) {
        .success => |compiled| return compiled,
        .failure => |*diagnostics| {
            const rendered = try diagnostics.render(testing.allocator);
            defer testing.allocator.free(rendered);
            std.debug.print("unexpected compile failure:\n{s}", .{rendered});
            result.deinit();
            return error.CompileFailed;
        },
    }
}

/// Lower `source` and hand back the textual LLVM IR; the caller owns
/// it.  Null means the program uses something with no lowering yet.
pub fn render(source: []const u8) !?[]const u8 {
    return renderBuilt(source, .debug);
}

/// The same, in either build mode, so a test can hold the two
/// artifacts side by side (docs/MODES.md).
pub fn renderBuilt(source: []const u8, mode: Mode) !?[]const u8 {
    const gpa = testing.allocator;
    var compiled = try program(source);
    defer compiled.deinit();
    if (mode == .release) mir.strip(&compiled);

    const triple = try emit.hostTriple(gpa);
    defer gpa.free(triple);

    return switch (try lower.lowerToText(gpa, &compiled, .{ .triple = triple })) {
        .text => |rendered| rendered,
        .unsupported => null,
    };
}

/// How the artifact under test was built (docs/MODES.md).  Release
/// strips the origins, which is the only difference there is.
pub const Mode = enum { debug, release };

/// Compile, lower, emit, link, load, and run `source`.  Everything the
/// run produced lands in `capture`.
pub fn run(source: []const u8, capture: *Capture, provided: Provided) !abi.Status {
    return runBuilt(source, capture, provided, .debug);
}

pub fn runBuilt(
    source: []const u8,
    capture: *Capture,
    provided: Provided,
    mode: Mode,
) !abi.Status {
    var compiled = try program(source);
    defer compiled.deinit();
    if (mode == .release) mir.strip(&compiled);
    return runProgram(&compiled, capture, provided);
}

/// The same, over a program somebody else compiled — a project of
/// several files, or one the caller stripped or optimized by hand.
pub fn runProgram(
    compiled: *const mir.Program,
    capture: *Capture,
    provided: Provided,
) !abi.Status {
    const gpa = testing.allocator;

    const triple = try emit.hostTriple(gpa);
    defer gpa.free(triple);

    const bitcode = switch (try lower.lower(gpa, compiled, .{ .triple = triple })) {
        .bitcode => |bytes| bytes,
        .unsupported => |what| {
            std.debug.print("no lowering for {s}\n", .{what});
            return error.Unsupported;
        },
    };
    defer gpa.free(bitcode);

    const object = switch (try emit.compile(gpa, bitcode, .{ .triple = triple })) {
        .object => |bytes| bytes,
        .failed => |why| {
            defer gpa.free(why);
            std.debug.print("LLVM refused the module: {s}\n", .{why});
            return error.EmitFailed;
        },
    };
    defer gpa.free(object);

    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    try scratch.dir.writeFile(io, .{ .sub_path = "program.o", .data = object });

    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory = path_storage[0..try scratch.dir.realPath(io, &path_storage)];
    const object_path = try std.fs.path.join(gpa, &.{ directory, "program.o" });
    defer gpa.free(object_path);
    const library_path = try std.fs.path.joinZ(gpa, &.{ directory, "program.so" });
    defer gpa.free(library_path);

    // The link is also the proof that the artifact declares no
    // undefined symbols beyond `libluce_rt`, which it links in: every
    // effect arrives through the host table, and every semantic
    // through the runtime library.
    const arguments: []const []const u8 = if (builtin.os.tag.isDarwin())
        &.{ "cc", "-shared", "-o", library_path, object_path, build_options.luce_rt_library }
    else
        &.{
            "cc",                          "-shared",
            "-Wl,--no-undefined",          "-o",
            library_path,                  object_path,
            build_options.luce_rt_library,
        };
    const linked = try std.process.run(gpa, io, .{ .argv = arguments });
    defer gpa.free(linked.stdout);
    defer gpa.free(linked.stderr);
    if (linked.term != .exited or linked.term.exited != 0) {
        std.debug.print("link failed:\n{s}\n", .{linked.stderr});
        return error.LinkFailed;
    }

    var library = try std.DynLib.open(library_path);
    defer library.close();
    const entry = library.lookup(abi.Entry, abi.entry_symbol) orelse return error.NoEntryPoint;

    const table = capture.table(provided);
    return entry(&table);
}

// ---------------------------------------------------------------------------
// The two engines, side by side
// ---------------------------------------------------------------------------

/// How a run ended, in the one vocabulary both engines answer in.
pub const End = union(enum) {
    /// The run finished; the number is what it left alive (S33 says
    /// that is zero for anything the specs run).
    finished: u32,
    trapped: mir.TrapCode,
    errored: mir.ErrorCode,
    /// The program said `exit(status)` — the fourth way a run ends.
    exited: i64,
};

/// One comparison, held open.  Most specs never touch it — they say
/// `ok`, `trap`, `errors` or `prints` below — but a spec that wants
/// the exact transcript, the exact words, or the exact trace asks the
/// session, and by then the two engines have already been made to
/// agree about all three.
pub const Session = struct {
    reference: Reference,
    capture: *Capture,
    /// How the run ended, once both engines said the same thing.
    end: End,

    pub fn deinit(self: *Session) void {
        self.reference.deinit();
        testing.allocator.destroy(self.capture);
    }

    /// What `print` wrote, plus every tagged screen effect, one per
    /// line.  Both engines produced this byte for byte.
    pub fn printed(self: *const Session) []const u8 {
        return self.reference.printed.items;
    }

    /// The words a trap or an uncaught error carried.
    pub fn message(self: *const Session) []const u8 {
        if (self.reference.trap_code != null) return self.reference.trap_message;
        return self.reference.error_message;
    }

    /// The call trace, one `function source:line:column` per line.
    pub fn trace(self: *const Session) []const u8 {
        if (self.reference.trap_code != null) return self.reference.trap_trace.items;
        return self.reference.error_origin.items;
    }

    /// The one file the world holds now, or null when it holds none.
    /// Both engines left it this way — `settle` compared them.
    pub fn file(self: *const Session) ?struct { name: []const u8, content: []const u8 } {
        const world = &self.reference.world;
        if (world.file_name_length == 0) return null;
        return .{
            .name = world.file_name[0..world.file_name_length],
            .content = world.file_content[0..world.file_content_length],
        };
    }
};

/// Run `source` both ways and demand the same bytes, the same trap
/// code, the same words, the same call trace, and the same leak
/// census.
pub fn agree(source: []const u8) !void {
    var session = try compare(source, .{});
    defer session.deinit();
}

/// The same, against a host that offers only `provided` — so a
/// withheld service has to fail closed the same way on both engines.
pub fn agreeGiven(source: []const u8, provided: Provided) !void {
    var session = try compare(source, provided);
    defer session.deinit();
}

/// The comparison itself: compile once, run twice, settle.  The caller
/// owns the session.
pub fn compare(source: []const u8, provided: Provided) !Session {
    var compiled = try program(source);
    defer compiled.deinit();
    return compareProgram(&compiled, provided);
}

/// The same, over an already-compiled program — a project of several
/// files, or one a caller built with the passes turned off.
pub fn compareProgram(compiled: *const mir.Program, provided: Provided) !Session {
    var reference: Reference = .{ .provided = provided };
    errdefer reference.deinit();
    try reference.run(compiled);

    // A `Capture` is forty kilobytes of fixed buffers, which is more
    // than a spec's stack frame should carry.
    const capture = try testing.allocator.create(Capture);
    errdefer testing.allocator.destroy(capture);
    capture.* = .{};
    const status = try runProgram(compiled, capture, provided);

    const end = try settle(&reference, capture, status);
    return .{ .reference = reference, .capture = capture, .end = end };
}

/// Compare the two arms and answer what they agreed on.
fn settle(reference: *Reference, capture: *Capture, status: abi.Status) !End {
    try testing.expectEqualStrings(reference.printed.items, capture.printed());
    try sameWorld(&reference.world, &capture.world);
    if (reference.trap_code) |code| {
        try testing.expectEqual(abi.Status.trapped, status);
        try testing.expectEqual(code, capture.trap_code.?);
        try testing.expectEqualStrings(reference.trap_message, capture.trapMessage());
        // Same frames, same lines, same "... N more" — a trap is not
        // reported identically until its trace is.
        try testing.expectEqualStrings(reference.trap_trace.items, capture.trapTrace());
        return .{ .trapped = code };
    }
    if (reference.error_code) |code| {
        // An error is news, so what has to match is the news: the
        // code, the words, and the one place it was raised
        // (docs/FAILURE.md).  Not the census — a run that ended
        // errored publishes nothing, on either engine.
        try testing.expectEqual(abi.Status.errored, status);
        try testing.expectEqual(code, capture.error_code.?);
        try testing.expectEqualStrings(reference.error_message, capture.errorMessage());
        try testing.expectEqualStrings(reference.error_origin.items, capture.errorOrigin());
        return .{ .errored = code };
    }
    if (reference.exit_status) |chosen| {
        // The program's chosen end: the same status number on both
        // engines, and the same census — the unwind skips releases on
        // both arms, so what was standing is part of what the program
        // did (docs/LANGUAGE.md).
        try testing.expectEqual(abi.Status.exited, status);
        try testing.expectEqual(chosen, capture.exit_status.?);
        try testing.expectEqual(@as(i64, reference.leaked.?), capture.leaked.?);
        return .{ .exited = chosen };
    }
    try testing.expectEqual(abi.Status.ok, status);
    try testing.expectEqual(@as(?mir.TrapCode, null), capture.trap_code);
    try testing.expectEqual(@as(i64, reference.leaked.?), capture.leaked.?);
    return .{ .finished = reference.leaked.? };
}

/// The two arms started from one world and each got a copy; they must
/// have left their copies in the same state.  The transcript catches a
/// wrong *effect*; this catches a wrong *result* of one — a file
/// written with the bytes of the previous statement, a key read one
/// time too many, a clock read that never happened.
fn sameWorld(reference: *const World, capture: *const World) !void {
    try testing.expectEqualStrings(
        reference.file_name[0..reference.file_name_length],
        capture.file_name[0..capture.file_name_length],
    );
    try testing.expectEqualStrings(
        reference.file_content[0..reference.file_content_length],
        capture.file_content[0..capture.file_content_length],
    );
    try testing.expectEqual(reference.keys_read, capture.keys_read);
    try testing.expectEqual(reference.lines_read, capture.lines_read);
    try testing.expectEqual(reference.clock, capture.clock);
}

// ---------------------------------------------------------------------------
// What a spec says
// ---------------------------------------------------------------------------
//
// Four assertions, each one "the engines agree, and here is what they
// agreed on".  A spec never reaches past these for an ordinary claim:
// the comparison is not an extra a spec opts into, it is how running a
// program works here.

/// The program runs, every `assert` in it holds, and nothing is left
/// alive — scope ownership frees everything (S33).
pub fn ok(source: []const u8) !void {
    return okGiven(source, .{});
}

pub fn okGiven(source: []const u8, provided: Provided) !void {
    var session = try compare(source, provided);
    defer session.deinit();
    return expectClean(&session);
}

/// The same, over a program the caller compiled.
pub fn okProgram(compiled: *const mir.Program, provided: Provided) !void {
    var session = try compareProgram(compiled, provided);
    defer session.deinit();
    return expectClean(&session);
}

fn expectClean(session: *const Session) !void {
    switch (session.end) {
        .finished => |left| {
            if (left == 0) return;
            std.debug.print("{d} objects leaked\n", .{left});
            return error.TestUnexpectedResult;
        },
        .trapped => |code| {
            std.debug.print("unexpected trap: {s} ({s})\n", .{ session.message(), @tagName(code) });
            return error.TestUnexpectedResult;
        },
        .errored => |code| {
            std.debug.print("unexpected error: {s} ({s})\n", .{ session.message(), @tagName(code) });
            return error.TestUnexpectedResult;
        },
        .exited => |status| {
            std.debug.print("unexpected exit({d})\n", .{status});
            return error.TestUnexpectedResult;
        },
    }
}

/// The run aborts with exactly `code`, on both engines, at the same
/// place.  Operands are deliberately held in mutable locals in these
/// programs: a compile-time-constant fault would be caught by the
/// analyzer instead and never reach an engine.
pub fn trap(source: []const u8, code: mir.TrapCode) !void {
    return trapGiven(source, .{}, code);
}

pub fn trapGiven(source: []const u8, provided: Provided, code: mir.TrapCode) !void {
    var session = try compare(source, provided);
    defer session.deinit();
    return expectTrapped(&session, code);
}

/// The same, over a program the caller compiled — and, for the checks
/// stage 4 now makes statically, over one the caller went on to
/// damage.  A trap no source program can still reach is reached from
/// here or nowhere (`src/luce/specs/ownership_spec.zig`'s S23).
pub fn trapProgram(compiled: *const mir.Program, provided: Provided, code: mir.TrapCode) !void {
    var session = try compareProgram(compiled, provided);
    defer session.deinit();
    return expectTrapped(&session, code);
}

fn expectTrapped(session: *const Session, code: mir.TrapCode) !void {
    switch (session.end) {
        .trapped => |raised| {
            if (raised == code) return;
            std.debug.print("expected trap {s}, got {s}\n", .{ @tagName(code), @tagName(raised) });
            return error.TestUnexpectedResult;
        },
        .finished => {
            std.debug.print("expected trap {s}, ran clean\n", .{@tagName(code)});
            return error.TestUnexpectedResult;
        },
        .errored => |raised| {
            std.debug.print("expected trap {s}, got error {s}\n", .{
                @tagName(code), @tagName(raised),
            });
            return error.TestUnexpectedResult;
        },
        .exited => |status| {
            std.debug.print("expected trap {s}, got exit({d})\n", .{ @tagName(code), status });
            return error.TestUnexpectedResult;
        },
    }
}

/// The run ends because the program said `exit(status)`, with exactly
/// this status on both engines — and the same transcript and census in
/// front of it, which `settle` already held them to.
pub fn exits(source: []const u8, provided: Provided, status: i64) !void {
    var session = try compare(source, provided);
    defer session.deinit();
    switch (session.end) {
        .exited => |chosen| try testing.expectEqual(status, chosen),
        .finished => {
            std.debug.print("expected exit({d}), the run finished\n", .{status});
            return error.TestUnexpectedResult;
        },
        .trapped => |raised| {
            std.debug.print("expected exit({d}), got trap {s}\n", .{ status, @tagName(raised) });
            return error.TestUnexpectedResult;
        },
        .errored => |raised| {
            std.debug.print("expected exit({d}), got error {s}\n", .{ status, @tagName(raised) });
            return error.TestUnexpectedResult;
        },
    }
}

/// The run ends as an error nobody caught, carrying exactly these
/// words (docs/FAILURE.md).
pub fn errors(
    source: []const u8,
    provided: Provided,
    code: mir.ErrorCode,
    message: []const u8,
) !void {
    var session = try compare(source, provided);
    defer session.deinit();
    switch (session.end) {
        .errored => |raised| try testing.expectEqual(code, raised),
        else => {
            std.debug.print("expected error {s}, the run did not raise\n", .{@tagName(code)});
            return error.TestUnexpectedResult;
        },
    }
    try testing.expectEqualStrings(message, session.message());
}

/// The engines agree, and this is the transcript they agreed on.
pub fn prints(source: []const u8, expected: []const u8) !void {
    return printsGiven(source, .{}, expected);
}

pub fn printsGiven(source: []const u8, provided: Provided, expected: []const u8) !void {
    var session = try compare(source, provided);
    defer session.deinit();
    try testing.expectEqualStrings(expected, session.printed());
}

// ---------------------------------------------------------------------------
// The harness's own tests
// ---------------------------------------------------------------------------

test "a message too long for a capture buffer names the harness, not a diff" {
    // The two failure channels used to answer this differently — the
    // error channel kept a silent 256-byte prefix, the trap channel
    // panicked — and the truncating one was reachable: `raiseIo`
    // builds `verb ++ path` and a path can be longer than that.  One
    // policy now, and one that reads as what it is in a failure.
    var buffer: [256]u8 = undefined;

    const short = "cannot read notes.txt";
    try testing.expectEqual(short.len, keepText(&buffer, short));
    try testing.expectEqualStrings(short, buffer[0..short.len]);

    // Exactly full still fits, whole.
    const exact = "x" ** 256;
    try testing.expectEqual(@as(usize, 256), keepText(&buffer, exact));
    try testing.expectEqualStrings(exact, buffer[0..256]);

    // One byte over, and the buffer holds a sentence about the buffer.
    const over = "x" ** 257;
    const length = keepText(&buffer, over);
    try testing.expect(length < buffer.len);
    try testing.expectEqualStrings(
        "<agree.zig: a 257-byte message does not fit its 256-byte capture buffer>",
        buffer[0..length],
    );
}
