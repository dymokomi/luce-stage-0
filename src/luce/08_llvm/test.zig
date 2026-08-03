//! End-to-end proof for the LLVM backend.
//!
//! The interesting test here is `run`: Luce source is compiled to IR,
//! lowered to LLVM IR, turned into an object by libLLVM in-process,
//! linked into a shared library, `dlopen`ed, and run against a host
//! table built in Zig.  Nothing about that path is mocked — if it
//! passes, a Luce program really did execute as machine code.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const emit = @import("emit.zig");

// The language comes in as a module rather than by path: this file
// belongs to `emit`, which links libLLVM, and `luce` does not.
const luce = @import("luce");
const backend = luce.backend;
const compile = luce.compile;
const mir = luce.mir;
const types = luce.types;
const abi = luce.llvm.abi;
const lower = luce.llvm;

const Allocator = std.mem.Allocator;
const io = std.testing.io;

// ---------------------------------------------------------------------------
// The world both hosts present
// ---------------------------------------------------------------------------

/// What the two hosts below offer a program: one in-memory file, a
/// fixed argument list, a screen that records instead of drawing, and a
/// scripted keyboard.
///
/// Written once and shared, so the interpreter's host and the compiled
/// program's host cannot differ in *what* they offer — only in how they
/// are called.  A disagreement in `agree` is then a lowering bug, which
/// is the only thing these tests are trying to find.
const World = struct {
    file_name: [64]u8 = undefined,
    file_name_length: usize = 0,
    file_content: [1024]u8 = undefined,
    file_content_length: usize = 0,
    /// How many keys the program has read; the script repeats.
    keys_read: usize = 0,

    const rows: i64 = 24;
    const cols: i64 = 80;

    const arguments = [_][]const u8{ "alpha", "beta" };

    const Key = struct { name: []const u8, text: []const u8 = "" };
    const keys = [_]Key{
        .{ .name = "text", .text = "q" },
        .{ .name = "enter" },
        .{ .name = "ctrl_s" },
    };

    /// The file's bytes, or null when nothing of that name was written.
    /// Borrowed until the next write.
    fn read(self: *const World, path: []const u8) ?[]const u8 {
        if (!self.exists(path)) return null;
        return self.file_content[0..self.file_content_length];
    }

    fn write(self: *World, path: []const u8, content: []const u8) bool {
        if (path.len == 0 or path.len > self.file_name.len) return false;
        if (content.len > self.file_content.len) return false;
        @memcpy(self.file_name[0..path.len], path);
        self.file_name_length = path.len;
        @memcpy(self.file_content[0..content.len], content);
        self.file_content_length = content.len;
        return true;
    }

    fn exists(self: *const World, path: []const u8) bool {
        if (self.file_name_length == 0) return false;
        return std.mem.eql(u8, self.file_name[0..self.file_name_length], path);
    }

    fn argument(index: i64) ?[]const u8 {
        if (index < 0 or index >= arguments.len) return null;
        return arguments[@intCast(index)];
    }

    fn nextKey(self: *World) Key {
        const answered = keys[self.keys_read % keys.len];
        self.keys_read += 1;
        return answered;
    }
};

/// The screen effects, as words: both hosts record the same ones, so
/// `agree` compares drawing as well as printing.
fn positionText(buffer: []u8, row: i64, col: i64) []const u8 {
    return std.fmt.bufPrint(buffer, "{d},{d}", .{ row, col }) catch unreachable;
}

fn styleText(buffer: []u8, foreground: i64, background: i64, bold: bool) []const u8 {
    return std.fmt.bufPrint(buffer, "{d},{d},{}", .{ foreground, background, bold }) catch unreachable;
}

/// What a host offers: which groups of services exist, and how deep it
/// lets calls go.  Every service in the ABI is optional, and a program
/// that reaches for one that is not there traps `host_unavailable`
/// rather than touching anything — so a test can withhold a group and
/// demand exactly that.
const Provided = struct {
    print: bool = true,
    files: bool = true,
    arguments: bool = true,
    terminal: bool = true,
    /// The depth limit both engines run under.  The ABI's default is
    /// the interpreter's default, so a test only names this when it
    /// wants a shallower one.
    call_depth: u32 = @intCast(abi.default_call_depth),
};

/// One line of a call trace, in the one shape the two engines are
/// compared in.  Written once and used by both hosts, so a difference
/// in `agree` is a difference in the trace and never in the rendering.
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

// ---------------------------------------------------------------------------
// A host, in Zig
// ---------------------------------------------------------------------------

/// What a run of a compiled program did: the transcript it produced,
/// how it ended, and what it left unfreed.
///
/// Every buffer here is fixed, and that is deliberate rather than
/// lazy.  These callbacks are entered from a `dlopen`ed library, and
/// `std.testing.allocator` captures a stack trace on every allocation:
/// the unwinder cannot walk back through the compiled program's frame
/// and faults inside the panic handler.  A host called from generated
/// code must not walk the Zig stack, so this one never allocates.
const Capture = struct {
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
    /// What this host answers when asked how deep calls may go.
    call_depth: i64 = abi.default_call_depth,

    fn printed(self: *const Capture) []const u8 {
        return self.printed_storage[0..self.printed_length];
    }

    fn trapMessage(self: *const Capture) []const u8 {
        return self.trap_storage[0..self.trap_length];
    }

    fn trapTrace(self: *const Capture) []const u8 {
        return self.trace_storage[0..self.trace_length];
    }

    fn errorMessage(self: *const Capture) []const u8 {
        return self.error_storage[0..self.error_length];
    }

    fn errorOrigin(self: *const Capture) []const u8 {
        return self.origin_storage[0..self.origin_length];
    }

    /// The table the compiled program indexes.  A withheld group leaves
    /// its slots null, which is what the fail-closed rule reads.
    fn table(self: *Capture, provided: Provided) abi.Host {
        self.call_depth = provided.call_depth;
        return .{
            .context = self,
            .call_depth = callDepth,
            .print = if (provided.print) print else null,
            .trap = trap,
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
        self.error_length = @min(words.len, self.error_storage.len);
        @memcpy(self.error_storage[0..self.error_length], words[0..self.error_length]);
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

    fn trap(
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
        if (words.len > self.trap_storage.len) @panic("trap message too long");
        self.trap_code = @enumFromInt(code);
        @memcpy(self.trap_storage[0..words.len], words);
        self.trap_length = words.len;

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
        _ = context;
        return World.arguments.len;
    }

    fn argAt(
        context: ?*anyopaque,
        index: i64,
        text: *[*]const u8,
        length: *i64,
    ) callconv(.c) abi.Answer {
        _ = context;
        const found = World.argument(index) orelse return .no;
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
        const pressed = of(context).world.nextKey();
        name.* = pressed.name.ptr;
        name_length.* = @intCast(pressed.name.len);
        text.* = pressed.text.ptr;
        text_length.* = @intCast(pressed.text.len);
        return .yes;
    }
};

/// The same program on the interpreter: the engine the specs proved,
/// and the thing a compiled run has to agree with byte for byte.
const Reference = struct {
    gpa: Allocator,
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

    fn deinit(self: *Reference) void {
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

    fn host(self: *Reference) backend.Host {
        return .{
            .context = self,
            .printFn = if (self.provided.print) take else null,
            .readFileFn = if (self.provided.files) readFile else null,
            .writeFileFn = if (self.provided.files) writeFile else null,
            .fileExistsFn = if (self.provided.files) fileExists else null,
            .argCountFn = if (self.provided.arguments) argCount else null,
            .argFn = if (self.provided.arguments) argAt else null,
            .terminal = if (self.provided.terminal) .{
                .context = self,
                .rowsFn = termRows,
                .colsFn = termCols,
                .clearFn = termClear,
                .moveFn = termMove,
                .styleFn = termStyle,
                .writeFn = termWrite,
                .flushFn = termFlush,
                .keyFn = keyRead,
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
    ) error{OutOfMemory}!backend.FileRead {
        const found = of(context).world.read(path) orelse return .failed;
        return .{ .content = try arena.dupe(u8, found) };
    }

    fn writeFile(context: *anyopaque, path: []const u8, content: []const u8) bool {
        return of(context).world.write(path, content);
    }

    fn fileExists(context: *anyopaque, path: []const u8) bool {
        return of(context).world.exists(path);
    }

    fn argCount(context: *anyopaque) u32 {
        _ = context;
        return World.arguments.len;
    }

    fn argAt(context: *anyopaque, arena: Allocator, index: u32) error{OutOfMemory}!?[]const u8 {
        _ = context;
        const found = World.argument(index) orelse return null;
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

    fn keyRead(context: *anyopaque, arena: Allocator) error{OutOfMemory}!backend.KeyEvent {
        _ = arena;
        const pressed = of(context).world.nextKey();
        return .{ .name = pressed.name, .text = pressed.text };
    }

    fn run(self: *Reference, compiled: *const mir.Program) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const result = try backend.evaluateHosted(
            .{ .arena = arena.allocator(), .objects = self.gpa },
            compiled,
            &.{},
            &.{},
            .{ .call_depth = self.provided.call_depth },
            self.host(),
        );
        switch (result) {
            .success => |ended| self.leaked = ended.leaked_objects,
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
            .unavailable => return error.UnexpectedlyUnavailable,
        }
    }
};

// ---------------------------------------------------------------------------
// The pipeline, as a test harness
// ---------------------------------------------------------------------------

/// Compile one script; the caller owns the program.  A compile failure
/// is a broken test, not an outcome under test, so it fails loudly.
fn program(gpa: Allocator, source: []const u8) !mir.Program {
    var result = try compile.compile(gpa, source, .{}, .{
        .entry_mode = .script,
        .allow_host = true,
        .source_name = "test.luc",
    });
    switch (result) {
        .success => |compiled| return compiled,
        .failure => |*diagnostics| {
            const rendered = try diagnostics.render(gpa);
            defer gpa.free(rendered);
            std.debug.print("unexpected compile failure:\n{s}", .{rendered});
            result.deinit();
            return error.CompileFailed;
        },
    }
}

/// Lower `source` and hand back the textual LLVM IR; the caller owns
/// it.  Null means the program uses something with no lowering yet.
fn render(gpa: Allocator, source: []const u8) !?[]const u8 {
    var compiled = try program(gpa, source);
    defer compiled.deinit();

    const triple = try emit.hostTriple(gpa);
    defer gpa.free(triple);

    return switch (try lower.lowerToText(gpa, &compiled, .{ .triple = triple })) {
        .text => |rendered| rendered,
        .unsupported => null,
    };
}

/// Lower a script and hand back the tag it could not lower.
fn scriptGap(gpa: Allocator, source: []const u8) ![]const u8 {
    var compiled = try program(gpa, source);
    defer compiled.deinit();

    const triple = try emit.hostTriple(gpa);
    defer gpa.free(triple);

    switch (try lower.lower(gpa, &compiled, .{ .triple = triple })) {
        .bitcode => |bytes| {
            gpa.free(bytes);
            return error.ShouldNotHaveLowered;
        },
        .unsupported => |what| return what,
    }
}

/// Lower an evaluator against `schema` and hand back the tag it could
/// not lower.  Evaluator ports are what the backend still has no
/// lowering for, and they are only reachable in evaluator mode.
fn evaluatorGap(gpa: Allocator, source: []const u8, schema: types.PortSchema) ![]const u8 {
    var result = try compile.compile(gpa, source, schema, .{
        .entry_mode = .evaluator,
        .source_name = "test.luc",
    });
    var compiled = switch (result) {
        .success => |produced| produced,
        .failure => {
            result.deinit();
            return error.CompileFailed;
        },
    };
    defer compiled.deinit();

    const triple = try emit.hostTriple(gpa);
    defer gpa.free(triple);

    switch (try lower.lower(gpa, &compiled, .{ .triple = triple })) {
        .bitcode => |bytes| {
            gpa.free(bytes);
            return error.ShouldNotHaveLowered;
        },
        .unsupported => |what| return what,
    }
}

/// How the artifact under test was built (docs/MODES.md).  Release
/// strips the origins, which is the only difference there is.
const Mode = enum { debug, release };

/// Compile, lower, emit, link, load, and run `source`.  Everything the
/// run produced lands in `capture`.
fn run(gpa: Allocator, source: []const u8, capture: *Capture, provided: Provided) !abi.Status {
    return runBuilt(gpa, source, capture, provided, .debug);
}

fn runBuilt(
    gpa: Allocator,
    source: []const u8,
    capture: *Capture,
    provided: Provided,
    mode: Mode,
) !abi.Status {
    var compiled = try program(gpa, source);
    defer compiled.deinit();
    if (mode == .release) mir.strip(&compiled);

    const triple = try emit.hostTriple(gpa);
    defer gpa.free(triple);

    const bitcode = switch (try lower.lower(gpa, &compiled, .{ .triple = triple })) {
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
// The shape of what is generated
// ---------------------------------------------------------------------------

test "the entry point is exported and every Luce function is internal" {
    const gpa = std.testing.allocator;
    const rendered = (try render(gpa,
        \\func main():
        \\    print("hi")
        \\
    )).?;
    defer gpa.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "define i32 @luce_main(ptr") != null);
    // The result is the *outcome* word, not a bit: a Luce function
    // answers ok, trapped, or errored (docs/FAILURE.md).
    try std.testing.expect(std.mem.indexOf(u8, rendered, "define internal i32 @luce.") != null);
}

test "checked integer arithmetic lowers to the overflow intrinsics" {
    const gpa = std.testing.allocator;
    const rendered = (try render(gpa,
        \\func main():
        \\    let a = 2
        \\    let b = 3
        \\    assert(a * b + a - b == 5)
        \\
    )).?;
    defer gpa.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "smul.with.overflow") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "sadd.with.overflow") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "ssub.with.overflow") != null);
}

test "an optional lowers to its payload beside a presence bit" {
    const gpa = std.testing.allocator;
    const rendered = (try render(gpa,
        \\func main():
        \\    let n = parse_int(arg(0))
        \\    print(str(n else 0))
        \\
    )).?;
    defer gpa.free(rendered);

    // `{ i64, i1 }` is the whole representation, and nothing about it
    // reaches memory or the runtime: absence is `extractvalue`, and
    // the fallback is a branch on the bit.
    try std.testing.expect(std.mem.indexOf(u8, rendered, "{ i64, i1 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "extractvalue") != null);
}

test "a construct with no lowering yet names itself" {
    const gpa = std.testing.allocator;
    // Everything a script can say now lowers; evaluator ports are what
    // is left, and they say so rather than miscompiling.
    try std.testing.expectEqualStrings("input_load (evaluator ports)", try evaluatorGap(
        gpa,
        \\func evaluate(input: Input, output: Output):
        \\    output.doubled = input.value * 2
        \\
    ,
        .{
            .inputs = &.{.{ .name = "value", .declared = .int }},
            .outputs = &.{.{ .name = "doubled", .declared = .int }},
        },
    ));
}

test "floats, structs, and the host services all lower" {
    const gpa = std.testing.allocator;
    const rendered = (try render(gpa,
        \\struct Point:
        \\    x: Float
        \\    y: Float
        \\
        \\func main():
        \\    let p = Point(x = 1.5, y = -0.0)
        \\    print(str(p.x * 2.0) + str(Int(p.y)) + str(sqrt(4.0)))
        \\    print(arg(0) + str(arg_count()) + str(file_exists("nowhere")))
        \\    term_move(term_rows(), term_cols())
        \\    term_flush()
        \\
    )).?;
    defer gpa.free(rendered);

    for ([_][]const u8{
        "fmul",
        "fneg",
        "fptosi",
        "llvm.sqrt.f64",
        "declare i32 @luce_rt_struct_make",
        "declare i32 @luce_rt_intern_text",
    }) |wanted| {
        if (std.mem.indexOf(u8, rendered, wanted) == null) {
            std.debug.print("missing: {s}\n", .{wanted});
            return error.NotGenerated;
        }
    }
}

test "the runtime library is called, not reimplemented" {
    const gpa = std.testing.allocator;
    const rendered = (try render(gpa,
        \\func main():
        \\    let xs = new List(Int)
        \\    xs.append(1)
        \\    print(str(len(xs)))
        \\    free(xs)
        \\
    )).?;
    defer gpa.free(rendered);

    for ([_][]const u8{
        "declare i32 @luce_rt_new_list",
        "declare i32 @luce_rt_append",
        "declare i32 @luce_rt_len",
        "declare i32 @luce_rt_str",
        "declare i32 @luce_rt_free",
        "declare void @luce_rt_bind",
        "declare noalias ptr @luce_rt_open",
    }) |wanted| {
        if (std.mem.indexOf(u8, rendered, wanted) == null) {
            std.debug.print("missing: {s}\n", .{wanted});
            return error.NotCalled;
        }
    }
}

test "every runtime declaration carries what the compiler knows about it" {
    const gpa = std.testing.allocator;
    // A bare `declare` is the most pessimistic thing LLVM can be told:
    // reads and writes all memory, may unwind, may never come back.
    // `effects.zig` says otherwise for every entry point, and this is
    // what proves the saying reaches the module.
    const rendered = (try render(gpa,
        \\func main():
        \\    let xs = new List(Int)
        \\    xs.append(1)
        \\    print(str(len(xs)) + str(xs[0]))
        \\    free(xs)
        \\
    )).?;
    defer gpa.free(rendered);

    var line_start: usize = 0;
    var checked: usize = 0;
    while (std.mem.indexOfScalarPos(u8, rendered, line_start, '\n')) |line_end| {
        const line = rendered[line_start..line_end];
        line_start = line_end + 1;
        if (!std.mem.startsWith(u8, line, "declare ")) continue;
        if (std.mem.indexOf(u8, line, "@luce_rt_") == null) continue;
        checked += 1;
        // `luce_rt_report` is the one that hands control to the host,
        // so it is the one that promises nothing.
        if (std.mem.indexOf(u8, line, "@luce_rt_report") != null) continue;
        // Function attributes travel in a numbered group; the
        // declaration names the group it belongs to.
        const marker = std.mem.lastIndexOfScalar(u8, line, '#') orelse {
            std.debug.print("bare declaration: {s}\n", .{line});
            return error.Undescribed;
        };
        const group = try std.fmt.allocPrint(gpa, "attributes {s} = ", .{line[marker..]});
        defer gpa.free(group);
        const at = std.mem.indexOf(u8, rendered, group) orelse return error.Undescribed;
        const end = std.mem.indexOfScalarPos(u8, rendered, at, '\n').?;
        const described = rendered[at..end];
        for ([_][]const u8{ "nounwind", "willreturn" }) |wanted| {
            if (std.mem.indexOf(u8, described, wanted) == null) {
                std.debug.print("{s}\n  is {s}\n", .{ line, described });
                return error.Undescribed;
            }
        }
    }
    try std.testing.expect(checked >= 8);

    // `luce_rt_len(rt, target, out)` carries the whole vocabulary: a
    // runtime pointer, a box it only borrows, a box it only fills.
    const at_len = std.mem.indexOf(u8, rendered, "declare i32 @luce_rt_len(").?;
    const len_line = rendered[at_len..std.mem.indexOfScalarPos(u8, rendered, at_len, '\n').?];
    for ([_][]const u8{
        "nocapture",
        "readonly",
        "writeonly",
        "nonnull",
        "noundef",
        "dereferenceable(24)",
        "align 8",
    }) |wanted| {
        if (std.mem.indexOf(u8, len_line, wanted) == null) {
            std.debug.print("{s}\n  wants {s}\n", .{ len_line, wanted });
            return error.Undescribed;
        }
    }
    // A reader of the heap is not a writer of it: it may write its own
    // arguments, and everything else it only looks at.  A *mutator*
    // says nothing, because since inline container access the heap is
    // memory this module can reach and "may move anything" is the
    // truth — see `runtime_effects.zig`, and note that `memory(...)`
    // prints nothing when it claims the default.
    try std.testing.expect(std.mem.indexOf(
        u8,
        rendered,
        "memory(read, argmem: readwrite)",
    ) != null);
    // The trap machinery is off the straight-line path.
    try std.testing.expect(std.mem.indexOf(u8, rendered, "cold") != null);
}

// ---------------------------------------------------------------------------
// Running the machine code
// ---------------------------------------------------------------------------

test "a compiled program prints through the host table" {
    const gpa = std.testing.allocator;
    var capture: Capture = .{};

    const status = try run(gpa,
        \\func main():
        \\    print("hello from a compiled .lc")
        \\
    , &capture, .{});

    try std.testing.expectEqual(abi.Status.ok, status);
    try std.testing.expectEqualStrings("hello from a compiled .lc\n", capture.printed());
    try std.testing.expectEqual(@as(?mir.TrapCode, null), capture.trap_code);
}

test "arithmetic, comparison, control flow, locals, and str(Int) run" {
    const gpa = std.testing.allocator;
    var capture: Capture = .{};

    const status = try run(gpa,
        \\func main():
        \\    var total = 0
        \\    var index = 1
        \\    while index <= 10:
        \\        if index % 2 == 0:
        \\            total = total + index * index
        \\        else:
        \\            total = total - index
        \\        index = index + 1
        \\    print(str(total))
        \\    print(str(-total))
        \\    print(str(total / 4))
        \\
    , &capture, .{});

    // 4 + 16 + 36 + 64 + 100 = 220; 1 + 3 + 5 + 7 + 9 = 25; 220 - 25 = 195.
    try std.testing.expectEqual(abi.Status.ok, status);
    try std.testing.expectEqualStrings("195\n-195\n48\n", capture.printed());
}

test "calls and recursion carry values back and traps forward" {
    const gpa = std.testing.allocator;
    var capture: Capture = .{};

    const status = try run(gpa,
        \\func fib(n: Int) -> Int:
        \\    if n < 2:
        \\        return n
        \\    return fib(n - 1) + fib(n - 2)
        \\
        \\func name_of(name: String, value: Int) -> String:
        \\    if value > 0:
        \\        return name
        \\    return "none"
        \\
        \\func main():
        \\    print(name_of("fib", fib(20)))
        \\    print(str(fib(20)))
        \\
    , &capture, .{});

    try std.testing.expectEqual(abi.Status.ok, status);
    try std.testing.expectEqualStrings("fib\n6765\n", capture.printed());
}

test "a call inside a loop does not grow the frame" {
    const gpa = std.testing.allocator;
    var capture: Capture = .{};

    // The scratch slot for the call result lives in the entry block, so
    // a million iterations cost one stack slot, not a million.
    const status = try run(gpa,
        \\func step(total: Int, index: Int) -> Int:
        \\    if index % 7 == 0:
        \\        return total + index
        \\    return total
        \\
        \\func main():
        \\    var total = 0
        \\    var index = 0
        \\    while index < 1000000:
        \\        total = step(total, index)
        \\        index = index + 1
        \\    print(str(total))
        \\
    , &capture, .{});

    try std.testing.expectEqual(abi.Status.ok, status);
    try std.testing.expectEqualStrings("71428928571\n", capture.printed());
}

test "booleans and not run" {
    const gpa = std.testing.allocator;
    var capture: Capture = .{};

    const status = try run(gpa,
        \\func main():
        \\    let yes = true
        \\    let no = not yes
        \\    assert(not no)
        \\    assert(yes != no)
        \\    if no:
        \\        print("wrong")
        \\    else:
        \\        print("right")
        \\
    , &capture, .{});

    try std.testing.expectEqual(abi.Status.ok, status);
    try std.testing.expectEqualStrings("right\n", capture.printed());
}

test "division by zero traps with the interpreter's code and message" {
    const gpa = std.testing.allocator;
    var capture: Capture = .{};

    const status = try run(gpa,
        \\func divide(a: Int, b: Int) -> Int:
        \\    return a / b
        \\
        \\func main():
        \\    print("before")
        \\    print(str(divide(1, 0)))
        \\    print("after")
        \\
    , &capture, .{});

    try std.testing.expectEqual(abi.Status.trapped, status);
    try std.testing.expectEqual(mir.TrapCode.divide_by_zero, capture.trap_code.?);
    try std.testing.expectEqualStrings("division by zero", capture.trapMessage());
    // The trap unwound out of `divide` without running the rest of main.
    try std.testing.expectEqualStrings("before\n", capture.printed());
}

test "integer overflow traps instead of wrapping" {
    const gpa = std.testing.allocator;
    var capture: Capture = .{};

    const status = try run(gpa,
        \\func main():
        \\    var value = 1
        \\    var step = 0
        \\    while step < 100:
        \\        value = value * 3
        \\        step = step + 1
        \\    print(str(value))
        \\
    , &capture, .{});

    try std.testing.expectEqual(abi.Status.trapped, status);
    try std.testing.expectEqual(mir.TrapCode.integer_overflow, capture.trap_code.?);
    try std.testing.expectEqualStrings("", capture.printed());
}

test "a failed assertion traps" {
    const gpa = std.testing.allocator;
    var capture: Capture = .{};

    const status = try run(gpa,
        \\func main():
        \\    assert(1 == 2)
        \\
    , &capture, .{});

    try std.testing.expectEqual(abi.Status.trapped, status);
    try std.testing.expectEqual(mir.TrapCode.assertion_failed, capture.trap_code.?);
    try std.testing.expectEqualStrings("assertion failed", capture.trapMessage());
}

test "trap(message) reports the program's own words" {
    const gpa = std.testing.allocator;
    var capture: Capture = .{};

    const status = try run(gpa,
        \\func main():
        \\    print("starting")
        \\    trap("nothing left to do")
        \\
    , &capture, .{});

    try std.testing.expectEqual(abi.Status.trapped, status);
    try std.testing.expectEqual(mir.TrapCode.explicit_trap, capture.trap_code.?);
    try std.testing.expectEqualStrings("nothing left to do", capture.trapMessage());
    try std.testing.expectEqualStrings("starting\n", capture.printed());
}

// ---------------------------------------------------------------------------
// Call depth and the call trace
// ---------------------------------------------------------------------------

test "the ABI's default depth is the interpreter's, so neither engine is deeper" {
    try std.testing.expectEqual(
        @as(i64, (backend.Budget{}).call_depth),
        abi.default_call_depth,
    );
}

test "runaway recursion traps instead of overflowing the machine's stack" {
    // A million frames is more than any native stack holds.  Compiled
    // code counts frames rather than hoping, so this is a trap with a
    // message and a trace, the way docs/LANGUAGE.md says it is — on
    // both engines, at the same call.
    try agree(std.testing.allocator,
        \\func deep(n: Int) -> Int:
        \\    return 1 + deep(n - 1)
        \\
        \\func main():
        \\    print("before")
        \\    print(str(deep(1000000)))
        \\
    );
}

test "mutual recursion and a shallow limit agree on where the depth ran out" {
    const gpa = std.testing.allocator;
    try agreeGiven(gpa,
        \\func ping(n: Int) -> Int:
        \\    return pong(n + 1)
        \\
        \\func pong(n: Int) -> Int:
        \\    return ping(n + 1)
        \\
        \\func main():
        \\    print(str(ping(0)))
        \\
    , .{ .call_depth = 7 });
    // A host that allows no frames at all refuses `main` itself.
    try agreeGiven(gpa,
        \\func main():
        \\    print("never runs")
        \\
    , .{ .call_depth = 0 });
    // One frame is exactly enough for a program that calls nothing.
    try agreeGiven(gpa,
        \\func main():
        \\    print("just main")
        \\
    , .{ .call_depth = 1 });
}

test "a debug build reports file, line, column, and the whole call stack" {
    const gpa = std.testing.allocator;
    var capture: Capture = .{};

    const status = try runBuilt(gpa,
        \\func divide(a: Int, b: Int) -> Int:
        \\    return a / b
        \\
        \\func ratio(n: Int) -> Int:
        \\    return divide(n, 0)
        \\
        \\func main():
        \\    print(str(ratio(7)))
        \\
    , &capture, .{}, .debug);

    try std.testing.expectEqual(abi.Status.trapped, status);
    try std.testing.expectEqual(mir.TrapCode.divide_by_zero, capture.trap_code.?);
    try std.testing.expectEqualStrings(
        \\divide test.luc:2:5
        \\ratio test.luc:5:5
        \\main test.luc:8:5
        \\
    , capture.trapTrace());
}

test "a release build strips the lines and still names the functions" {
    const gpa = std.testing.allocator;
    var capture: Capture = .{};

    const status = try runBuilt(gpa,
        \\func divide(a: Int, b: Int) -> Int:
        \\    return a / b
        \\
        \\func ratio(n: Int) -> Int:
        \\    return divide(n, 0)
        \\
        \\func main():
        \\    print(str(ratio(7)))
        \\
    , &capture, .{}, .release);

    // Names are structure, not debug info (docs/MODES.md): the same
    // three frames, with nowhere to point.
    try std.testing.expectEqual(abi.Status.trapped, status);
    try std.testing.expectEqual(mir.TrapCode.divide_by_zero, capture.trap_code.?);
    try std.testing.expectEqualStrings(
        \\divide :0:0
        \\ratio :0:0
        \\main :0:0
        \\
    , capture.trapTrace());
}

test "a deep trace keeps its innermost frames and counts the rest" {
    const gpa = std.testing.allocator;
    var capture: Capture = .{};

    _ = try run(gpa,
        \\func deep(n: Int) -> Int:
        \\    return 1 + deep(n - 1)
        \\
        \\func main():
        \\    print(str(deep(1000000)))
        \\
    , &capture, .{ .call_depth = 200 });

    // 200 frames live, 64 kept: 136 counted, and the innermost frame
    // is the recursive call that was refused.
    try std.testing.expectEqual(mir.TrapCode.call_depth_exceeded, capture.trap_code.?);
    const reported = capture.trapTrace();
    try std.testing.expect(std.mem.startsWith(u8, reported, "deep test.luc:2:5\n"));
    try std.testing.expect(std.mem.endsWith(u8, reported, "... 136 more\n"));
}

test "a missing host service fails closed" {
    const gpa = std.testing.allocator;
    var capture: Capture = .{};

    const status = try run(gpa,
        \\func main():
        \\    print("this host has no console")
        \\
    , &capture, .{ .print = false });

    try std.testing.expectEqual(abi.Status.trapped, status);
    try std.testing.expectEqual(mir.TrapCode.host_unavailable, capture.trap_code.?);
    try std.testing.expectEqualStrings("", capture.printed());
}

// ---------------------------------------------------------------------------
// The two engines, side by side
// ---------------------------------------------------------------------------
//
// The old architecture had a differential oracle because it had four
// engines (docs/CODEGEN.md).  There are two left — the interpreter and
// compiled code — and they now share one implementation of every
// semantic below the instruction level, so the oracle's job is smaller:
// prove that sharing is real.  A disagreement here means the lowering
// marshalled something wrongly, not that a semantic was written twice.

/// Run `source` both ways and demand the same bytes, the same trap
/// code, the same words, the same call trace, and the same leak census.
fn agree(gpa: Allocator, source: []const u8) !void {
    return agreeGiven(gpa, source, .{});
}

/// The same, against a host that offers only `provided` — so a
/// withheld service has to fail closed the same way on both engines.
fn agreeGiven(gpa: Allocator, source: []const u8, provided: Provided) !void {
    var compiled = try program(gpa, source);
    defer compiled.deinit();

    var reference: Reference = .{ .gpa = gpa, .provided = provided };
    defer reference.deinit();
    try reference.run(&compiled);

    var capture: Capture = .{};
    const status = try run(gpa, source, &capture, provided);

    try std.testing.expectEqualStrings(reference.printed.items, capture.printed());
    if (reference.trap_code) |code| {
        try std.testing.expectEqual(abi.Status.trapped, status);
        try std.testing.expectEqual(code, capture.trap_code.?);
        try std.testing.expectEqualStrings(reference.trap_message, capture.trapMessage());
        // Same frames, same lines, same "... N more" — a trap is not
        // reported identically until its trace is.
        try std.testing.expectEqualStrings(reference.trap_trace.items, capture.trapTrace());
    } else if (reference.error_code) |code| {
        // An error is news, so what has to match is the news: the
        // code, the words, and the one place it was raised
        // (docs/FAILURE.md).  Not the census — a run that ended
        // errored publishes nothing, on either engine.
        try std.testing.expectEqual(abi.Status.errored, status);
        try std.testing.expectEqual(code, capture.error_code.?);
        try std.testing.expectEqualStrings(reference.error_message, capture.errorMessage());
        try std.testing.expectEqualStrings(reference.error_origin.items, capture.errorOrigin());
    } else {
        try std.testing.expectEqual(abi.Status.ok, status);
        try std.testing.expectEqual(@as(?mir.TrapCode, null), capture.trap_code);
        try std.testing.expectEqual(@as(i64, reference.leaked.?), capture.leaked.?);
    }
}

test "lists, maps, strings, and ownership agree with the interpreter" {
    try agree(std.testing.allocator,
        \\func total(xs: List(Int)) -> Int:
        \\    var sum = 0
        \\    for x in xs:
        \\        sum = sum + x
        \\    return sum
        \\
        \\func main():
        \\    let xs = new List(Int)
        \\    var i = 1
        \\    while i <= 5:
        \\        xs.append(i * i)
        \\        i = i + 1
        \\    xs.append(0)
        \\    xs.sort()
        \\    print(str(xs[0]) + "," + str(xs[5]) + "," + str(len(xs)))
        \\    print(str(total(xs)))
        \\    print(str(xs.find(9)) + " " + str(xs.contains(7)))
        \\
        \\    let names = new Map(String, Int)
        \\    names["one"] = 1
        \\    names["two"] = 2
        \\    names["one"] = 11
        \\    print(str(len(names)) + " " + str(names["one"]) + " " + str(names.get("three", -1)))
        \\    for name, count in names:
        \\        print(name + "=" + str(count))
        \\    print(str(names.has("two")) + " " + str(len(names.keys())))
        \\
        \\    let text = new Builder
        \\    text.append("ab")
        \\    text.append_ascii(99)
        \\    let word = str(text)
        \\    print(word + " " + str(len(word)) + " " + str(word.byte_at(0)))
        \\    print(word[1:3] + " " + str(word.find_byte(99, 0)))
        \\    print(str(41 + 1) + chr(33) + str(ord("A")))
        \\    print(str("abc" < "abd") + str("abc" == "abc"))
        \\
        \\    let kept = copy xs
        \\    print(str(len(kept)))
        \\    free(kept)
        \\    free(names)
        \\    free(text)
        \\    free(xs)
        \\
    );
}

test "a nested container agrees, and the leak census counts the same" {
    try agree(std.testing.allocator,
        \\func main():
        \\    let rows = new List(List(Int))
        \\    var r = 0
        \\    while r < 3:
        \\        let row = new List(Int)
        \\        row.append(r)
        \\        row.append(r * 10)
        \\        rows.append(give row)
        \\        r = r + 1
        \\    print(str(len(rows)) + " " + str(rows[2][1]))
        \\    let leaked = new List(Int)
        \\    leaked.append(1)
        \\    print("done")
        \\    free(rows)
        \\
    );
}

test "an alias used after the owner freed agrees: use_after_free (S9)" {
    try agree(std.testing.allocator,
        \\func main():
        \\    var xs = new List(Int)
        \\    xs.append(1)
        \\    let view = xs
        \\    free(xs)
        \\    print("freed")
        \\    print(str(len(view)))
        \\
    );
}

test "a stale alias whose row was reused agrees: still use_after_free (S9)" {
    // The row `xs` vacates is the row `fresh` moves into, so the two
    // handles differ only in their generation — and that is the whole
    // of what keeps `stale` from quietly becoming a second name for
    // `fresh` on either engine.  Compiled code makes this test itself,
    // inline, with the row's generation against the handle's.
    try agree(std.testing.allocator,
        \\func main():
        \\    var xs = new List(Int)
        \\    xs.append(1)
        \\    let stale = xs
        \\    free(xs)
        \\    let fresh = new List(Int)
        \\    fresh.append(10)
        \\    fresh.append(20)
        \\    if stale == fresh:
        \\        print("aliased")
        \\    else:
        \\        print("distinct")
        \\    print(str(len(fresh)))
        \\    print(str(len(stale)))
        \\
    );
}

test "a reused row is refused by every door, and the newcomer by none" {
    // The same reuse reached through indexing, iteration and the
    // ownership verbs rather than through `len`, because each takes a
    // different route to the row.
    try agree(std.testing.allocator,
        \\func main():
        \\    var rows = new List(List(Int))
        \\    var doomed = new List(Int)
        \\    doomed.append(7)
        \\    let stale = doomed
        \\    free(doomed)
        \\    let fresh = new List(Int)
        \\    fresh.append(3)
        \\    rows.append(give fresh)
        \\    print(str(rows[0][0]))
        \\    print(str(stale[0]))
        \\
    );
}

test "the alias dodge agrees: not_owned (S23)" {
    try agree(std.testing.allocator,
        \\func main():
        \\    var a = new List(List(Int))
        \\    var b = new List(List(Int))
        \\    var item = new List(Int)
        \\    item.append(2)
        \\    let alias = item
        \\    a.append(give item)
        \\    print("adopted")
        \\    b.append(give alias)
        \\
    );
}

test "an index out of bounds agrees" {
    try agree(std.testing.allocator,
        \\func main():
        \\    let xs = new List(Int)
        \\    xs.append(1)
        \\    print("one")
        \\    print(str(xs[3]))
        \\
    );
}

// ---------------------------------------------------------------------------
// Floats
// ---------------------------------------------------------------------------
//
// The special values travel through a `List(Float)`, which no optimizer
// can see into: without that, LLVM would fold the whole table at
// compile time and the test would only prove that its constant folder
// agrees, not that the generated instructions do.

test "float arithmetic, comparison, and formatting agree over the special values" {
    try agree(std.testing.allocator,
        \\func main():
        \\    let values = new List(Float)
        \\    values.append(0.0)
        \\    values.append(-0.0)
        \\    values.append(1.5)
        \\    values.append(-2.5)
        \\    values.append(1.0 / 0.0)
        \\    values.append(-1.0 / 0.0)
        \\    values.append(0.0 / 0.0)
        \\    var i = 0
        \\    while i < len(values):
        \\        var j = 0
        \\        while j < len(values):
        \\            let a = values[i]
        \\            let b = values[j]
        \\            print(str(a) + " " + str(b) + " = " + str(a + b) + " " + str(a - b) +
        \\                " " + str(a * b) + " " + str(a / b) + " " + str(a % b))
        \\            print("  " + str(a == b) + str(a != b) + str(a < b) +
        \\                str(a <= b) + str(a > b) + str(a >= b))
        \\            print("  " + str(min(a, b)) + " " + str(max(a, b)) + " " +
        \\                str(clamp(a, -1.0, 1.0)) + " " + str(abs(a)) + " " + str(-a))
        \\            j = j + 1
        \\        i = i + 1
        \\    free(values)
        \\
    );
}

test "negating a float flips the sign bit, so -0.0 survives" {
    try agree(std.testing.allocator,
        \\func main():
        \\    var zero = 0.0
        \\    let negative = -zero
        \\    print(str(negative) + " " + str(1.0 / negative))
        \\    print(str(zero == negative) + str(1.0 / zero == 1.0 / negative))
        \\    print(str(-negative) + " " + str(0.0 - zero))
        \\
    );
}

// A `min`/`max` reduction is the one float loop LLVM may reorder
// without being told to reassociate anything, because
// `llvm.minimumnum` is associative and commutative on the nose — so
// `lower.emitExtremum` lets it, and the vectorized loop has to answer
// what the interpreter's one-at-a-time loop answers, down to which
// zero it kept.  Nothing below is a constant to the optimizer: the
// values come out of a List and the length out of `len`, so the
// reductions stay loops long enough to be vectorized.
test "min and max reductions over an array agree, signed zeros and all" {
    try agree(std.testing.allocator,
        \\func lowest(xs: Array(Float, _)) -> Float:
        \\    var smallest = xs[0]
        \\    for i in range(1, len(xs)):
        \\        smallest = min(smallest, xs[i])
        \\    return smallest
        \\
        \\func highest(xs: Array(Float, _)) -> Float:
        \\    var largest = xs[0]
        \\    for i in range(1, len(xs)):
        \\        largest = max(largest, xs[i])
        \\    return largest
        \\
        \\func main():
        \\    let control = new List(Float)
        \\    control.append(0.0)
        \\    control.append(-0.0)
        \\    control.append(0.0 / 0.0)
        \\    let n = len(control) * 5
        \\    var xs = new Array(Float, n)
        \\    for pattern in range(0, 32):
        \\        for i in range(0, n):
        \\            xs[i] = control[(pattern / (i % 5 + 1)) % 2]
        \\        let low = lowest(xs)
        \\        let high = highest(xs)
        \\        print(str(low) + " " + str(1.0 / low) + " " +
        \\            str(high) + " " + str(1.0 / high))
        \\    for at in range(0, n):
        \\        for i in range(0, n):
        \\            xs[i] = Float(i + 1)
        \\        xs[at] = control[2]
        \\        print(str(lowest(xs)) + " " + str(highest(xs)))
        \\    free(xs)
        \\    free(control)
        \\
    );
}

test "clamp agrees when the bounds cross and when they are not numbers" {
    try agree(std.testing.allocator,
        \\func main():
        \\    let bounds = new List(Float)
        \\    bounds.append(-1.0)
        \\    bounds.append(1.0)
        \\    bounds.append(0.0)
        \\    bounds.append(-0.0)
        \\    bounds.append(0.0 / 0.0)
        \\    var low = 0
        \\    while low < len(bounds):
        \\        var high = 0
        \\        while high < len(bounds):
        \\            let held = Float(low) - Float(high) * 0.5
        \\            print(str(clamp(held, bounds[low], bounds[high])))
        \\            high = high + 1
        \\        low = low + 1
        \\    print(str(clamp(5, 9, 2)) + " " + str(clamp(0, 9, 2)))
        \\    free(bounds)
        \\
    );
}

test "the float builtins agree" {
    try agree(std.testing.allocator,
        \\func main():
        \\    let xs = new List(Float)
        \\    xs.append(0.0)
        \\    xs.append(4.0)
        \\    xs.append(2.999)
        \\    xs.append(-2.999)
        \\    xs.append(1.0 / 0.0)
        \\    for x in xs:
        \\        print(str(x) + ": " + str(sqrt(abs(x))) + " " + str(floor(x)) +
        \\            " " + str(ceil(x)) + " " + str(Float(Int(clamp(x, -9.0, 9.0)))))
        \\    free(xs)
        \\
    );
}

test "Int(Float) agrees at the range boundaries" {
    try agree(std.testing.allocator,
        \\func main():
        \\    var scale = 1.0
        \\    var step = 0
        \\    while step < 63:
        \\        scale = scale * 2.0
        \\        step = step + 1
        \\    print(str(Int(0.0 - scale)))
        \\    print(str(Int(scale - 1024.0)))
        \\    print(str(Int(2.7)) + " " + str(Int(-2.7)) + " " + str(Int(-0.0)))
        \\    print("at the edge")
        \\    print(str(Int(scale)))
        \\
    );
}

test "Int(NaN) and Int(infinity) trap the same way" {
    const gpa = std.testing.allocator;
    try agree(gpa,
        \\func main():
        \\    let nan = 0.0 / 0.0
        \\    print("before")
        \\    print(str(Int(nan)))
        \\
    );
    try agree(gpa,
        \\func main():
        \\    let far = -1.0 / 0.0
        \\    print("before")
        \\    print(str(Int(far)))
        \\
    );
}

test "the Int math builtins agree, and abs of the smallest Int traps" {
    const gpa = std.testing.allocator;
    try agree(gpa,
        \\func main():
        \\    let xs = new List(Int)
        \\    xs.append(0)
        \\    xs.append(7)
        \\    xs.append(-7)
        \\    xs.append(9223372036854775807)
        \\    xs.append(0 - 9223372036854775807 - 1)
        \\    for x in xs:
        \\        print(str(min(x, 3)) + " " + str(max(x, 3)) + " " + str(clamp(x, -2, 2)))
        \\    free(xs)
        \\
    );
    try agree(gpa,
        \\func main():
        \\    let xs = new List(Int)
        \\    xs.append(0 - 9223372036854775807 - 1)
        \\    print(str(abs(7)) + " " + str(abs(-7)))
        \\    print(str(abs(xs[0])))
        \\
    );
}

// ---------------------------------------------------------------------------
// Struct values
// ---------------------------------------------------------------------------

test "nested struct equality recurses into fields, not the slots holding them" {
    try agree(std.testing.allocator,
        \\struct Inner:
        \\    n: Int
        \\    tag: String
        \\
        \\struct Outer:
        \\    left: Inner
        \\    right: Inner
        \\
        \\func main():
        \\    let a = Outer(left = Inner(n = 1, tag = "x"), right = Inner(n = 2, tag = "y"))
        \\    let b = Outer(left = Inner(n = 1, tag = "x"), right = Inner(n = 2, tag = "y"))
        \\    let c = Outer(left = Inner(n = 1, tag = "x"), right = Inner(n = 3, tag = "y"))
        \\    print(str(a == b) + str(a != b))
        \\    print(str(a == c) + str(a != c))
        \\    print(str(a.left == b.left) + str(a.right == c.right))
        \\
    );
}

test "a struct carrying a String copies by value and agrees" {
    try agree(std.testing.allocator,
        \\struct Person:
        \\    name: String
        \\    age: Int
        \\    score: Float
        \\
        \\func renamed(who: Person, to: String) -> Person:
        \\    var changed = who
        \\    changed.name = to
        \\    return changed
        \\
        \\func main():
        \\    var ada = Person(name = "ada", age = 36, score = 1.5)
        \\    let grace = renamed(ada, "grace")
        \\    print(ada.name + " " + str(ada.age) + " " + str(ada.score))
        \\    print(grace.name + " " + str(grace.age) + " " + str(grace.score))
        \\    ada.age = 37
        \\    print(str(ada.age) + " " + str(grace.age) + " " + str(ada == grace))
        \\
    );
}

test "zero-initialized structs agree, nested ones included" {
    try agree(std.testing.allocator,
        \\struct Inner:
        \\    n: Int
        \\    tag: String
        \\
        \\struct Outer:
        \\    label: String
        \\    inner: Inner
        \\    weight: Float
        \\
        \\func main():
        \\    var grid = new Array(Outer, 2, 2)
        \\    print("[" + grid[0, 0].label + "][" + grid[0, 0].inner.tag + "]")
        \\    print(str(grid[1, 1].inner.n) + " " + str(grid[1, 1].weight))
        \\    grid[1, 0].inner.n = 7
        \\    print(str(grid[1, 0].inner.n) + " " + str(grid[0, 1].inner.n))
        \\    print(str(grid[0, 0] == grid[0, 1]) + str(grid[0, 0] == grid[1, 0]))
        \\    free(grid)
        \\
    );
}

test "an inline array access agrees on every element kind and rank" {
    // Since `Array` storage is typed (`runtime/heap.zig`), a Float
    // array is `f64`s and a Bool array is bytes, while a String or an
    // object element keeps the 24-byte slot — and compiled code reads
    // each one inline rather than through the runtime.  Four kinds,
    // two ranks, both engines.
    try agree(std.testing.allocator,
        \\func main():
        \\    var grid = new Array(Int, 3, 4)
        \\    for r in range(0, 3):
        \\        for c in range(0, 4):
        \\            grid[r, c] = r * 10 + c
        \\    var total = 0
        \\    for r in range(0, 3):
        \\        for c in range(0, 4):
        \\            total += grid[r, c]
        \\    print(str(total) + " " + str(grid.dim(0)) + " " + str(grid.dim(1)) + " " + str(len(grid)))
        \\
        \\    var names = new Array(String, 3)
        \\    var flags = new Array(Bool, 3)
        \\    var weights = new Array(Float, 3)
        \\    for i in range(0, 3):
        \\        names[i] = "n" + str(i)
        \\        flags[i] = i % 2 == 0
        \\        weights[i] = Float(i) * 0.5
        \\    for i in range(0, 3):
        \\        print(names[i] + " " + str(flags[i]) + " " + str(weights[i]))
        \\
        \\    var rows = new Array(List(Int), 2)
        \\    for i in range(0, 2):
        \\        var row = new List(Int)
        \\        row.append(i)
        \\        rows[i] = give row
        \\    print(str(rows[0][0] + rows[1][0]))
        \\
        \\    free(rows)
        \\    free(weights)
        \\    free(flags)
        \\    free(names)
        \\    free(grid)
        \\
    );
}

test "a resolution lifted out of a loop still traps where the access is" {
    // `loops.zig` reads an Array's row once per loop instead of once
    // per access.  What must not move with it is the *deciding*: a
    // loop that never runs must not trap for an array that is already
    // freed, and one that does run must trap at the access, not at the
    // preheader.  Both engines, one source, twice.
    try agree(std.testing.allocator,
        \\func drop(xs: give Array(Float, _)):
        \\    free(xs)
        \\
        \\func main():
        \\    var a = new Array(Float, 4)
        \\    let alias = a
        \\    drop(give a)
        \\    var total = 0.0
        \\    for i in range(0, 0):
        \\        total += alias[i]
        \\    print("survived " + str(Int(total)))
        \\
    );
    try agree(std.testing.allocator,
        \\func drop(xs: give Array(Float, _)):
        \\    free(xs)
        \\
        \\func main():
        \\    var a = new Array(Float, 4)
        \\    let alias = a
        \\    drop(give a)
        \\    var total = 0.0
        \\    for i in range(0, 4):
        \\        total += alias[i]
        \\    print("unreachable " + str(Int(total)))
        \\
    );
    // And an index past the end still traps at the access it was made
    // at, with the loop's resolution already lifted above it.
    try agree(std.testing.allocator,
        \\func main():
        \\    var a = new Array(Float, 4)
        \\    var total = 0.0
        \\    for i in range(0, 6):
        \\        total += a[i]
        \\    print("unreachable " + str(Int(total)))
        \\
    );
}

test "a lifted resolution sees the generation, so a reoccupied row still traps" {
    // The row `a` vacates is the row `reborn` moves into, and the
    // lifted resolution reads that row in the preheader — so what
    // stands between `alias` and `reborn`'s elements is the one
    // comparison the loop kept: the row's generation against the
    // handle's.
    try agree(std.testing.allocator,
        \\func main():
        \\    var a = new Array(Int, 4)
        \\    a.fill(5)
        \\    let alias = a
        \\    free(a)
        \\    var reborn = new Array(Int, 4)
        \\    reborn.fill(1)
        \\    var total = 0
        \\    for i in range(0, 3):
        \\        total += alias[i]
        \\    print("unreachable " + str(total))
        \\
    );
    // And the null handle, whose lifted resolution reads the module's
    // retired row rather than the table: still `null_object`, still at
    // the access.
    try agree(std.testing.allocator,
        \\func main():
        \\    var rows = new Array(Array(Int, _), 2)
        \\    var inner = rows[0]
        \\    var total = 0
        \\    for i in range(0, 3):
        \\        total += inner[i]
        \\    print("unreachable " + str(total))
        \\
    );
}

test "inline String length, byte_at and slicing agree, boundaries included" {
    try agree(std.testing.allocator,
        \\func main():
        \\    let text = "héllo wörld"
        \\    print(str(len(text)) + " " + str(text.byte_at(0)) + " " + str(text.byte_at(1)))
        \\    print(text[0:1] + "|" + text[1:3] + "|" + text[0:0] + "|" + text[3:len(text)])
        \\    var i = 0
        \\    var total = 0
        \\    while i < len(text):
        \\        total += text.byte_at(i)
        \\        i += 1
        \\    print(str(total))
        \\
    );
    // The end of a String is a legal bound and the byte there is not
    // ours to read; splitting a sequence is a trap, not a wrong answer.
    try agree(std.testing.allocator,
        \\func main():
        \\    let text = "héllo"
        \\    print(text[0:2])
        \\
    );
    try agree(std.testing.allocator,
        \\func main():
        \\    let text = "abc"
        \\    print(str(text.byte_at(3)))
        \\
    );
}

test "structs inside containers agree" {
    try agree(std.testing.allocator,
        \\struct Cell:
        \\    value: Int
        \\    name: String
        \\
        \\func main():
        \\    var cells = [Cell(value = 10, name = "a"), Cell(value = 20, name = "b")]
        \\    cells[1].value = 99
        \\    for cell in cells:
        \\        print(cell.name + "=" + str(cell.value))
        \\    print(str(cells[0] == cells[1]) + str(len(cells)))
        \\    free(cells)
        \\
    );
}

test "a struct carrying an object is owned and released through its fields" {
    // The struct crosses a return, so the ownership walk has to reach
    // into its fields on both the loosen and the release side; the leak
    // census is what says it did.
    try agree(std.testing.allocator,
        \\struct Bag:
        \\    items: List(Int)
        \\    label: String
        \\
        \\func fill(label: String) -> Bag:
        \\    let xs = new List(Int)
        \\    xs.append(1)
        \\    xs.append(2)
        \\    return Bag(items = give xs, label = label)
        \\
        \\func main():
        \\    var bag = fill("b")
        \\    print(str(len(bag.items)) + bag.label)
        \\    bag.items.append(3)
        \\    print(str(len(bag.items)))
        \\
    );
}

// ---------------------------------------------------------------------------
// Absence
// ---------------------------------------------------------------------------
//
// A `T?` lowers to `{T, i1}` and absence on the interpreter is
// `Value.Tag.none`, so these two are the least alike of anything the
// oracle compares: neither engine's representation is the other's.
// What has to match is every answer either can be asked for.

test "a value-typed optional agrees on absence, narrowing, and else" {
    try agree(std.testing.allocator,
        \\func maybe(want: Bool) -> Int?:
        \\    if want:
        \\        return 7
        \\    return none
        \\
        \\func main():
        \\    let there = maybe(true)
        \\    if there != none:
        \\        print("there=" + str(there))
        \\    let gone = maybe(false)
        \\    if gone == none:
        \\        print("gone")
        \\    print(str(maybe(false) else -1) + " " + str(maybe(true) else -1))
        \\    var slot: Int? = none
        \\    print(str(slot else -2))
        \\    slot = maybe(true)
        \\    print(str(slot else -2))
        \\
    );
}

test "the else fallback runs only where there was no value, and chains" {
    // The fallback is lazy: `loud` prints, so the printed bytes are
    // what says which side ran.  A chain is the same shape nested, and
    // its middle link must not run either once the first supplies one.
    try agree(std.testing.allocator,
        \\func maybe(want: Bool) -> Int?:
        \\    if want:
        \\        return 7
        \\    return none
        \\
        \\func loud(answer: Int) -> Int:
        \\    print("fallback ran")
        \\    return answer
        \\
        \\func main():
        \\    print(str(maybe(true) else loud(1)))
        \\    print(str(maybe(false) else loud(2)))
        \\    print(str(maybe(true) else maybe(false) else loud(3)))
        \\    print(str(maybe(false) else maybe(true) else loud(4)))
        \\    print(str(maybe(false) else maybe(false) else loud(5)))
        \\
    );
}

test "parse_int and parse_float agree when the text is a number and when it is not" {
    // The `Int?`/`Float?` that made optionals load-bearing on day one.
    try agree(std.testing.allocator,
        \\func main():
        \\    print(str(parse_int("41") else -1))
        \\    print(str(parse_int("") else -1))
        \\    print(str(parse_int("12x") else -1))
        \\    print(str(parse_int("-9") else -1))
        \\    print(str(parse_float("2.5") else -1.0))
        \\    print(str(parse_float("nope") else -1.0))
        \\    let n = parse_int("77")
        \\    if n != none:
        \\        print("narrowed=" + str(n + 1))
        \\
    );
}

test "x else trap is the assert-unwrap, and it traps where it is written" {
    // The trap code, the message, and every frame of the trace have to
    // match — which is the whole of `calc.luc`'s error path.
    try agree(std.testing.allocator,
        \\func want(text: String) -> Int:
        \\    return parse_int(text) else trap("not a number: " + text)
        \\
        \\func middle(text: String) -> Int:
        \\    return want(text) + 1
        \\
        \\func main():
        \\    print(str(middle("41")))
        \\    print(str(middle("oops")))
        \\
    );
}

test "an optional struct field agrees, absent and present" {
    // A `T?` field is stored as a `runtime.Value` on both engines, so
    // this is where the lowered pair meets the tagged slot: absence has
    // to box as the `none` tag and read back as the absent pair.
    try agree(std.testing.allocator,
        \\struct Slot:
        \\    label: String
        \\    room: Int?
        \\
        \\func main():
        \\    var empty = Slot(label = "a", room = none)
        \\    if empty.room == none:
        \\        print("a has no room")
        \\    empty.room = 12
        \\    print("a=" + str(empty.room else 0))
        \\    let filled = Slot(label = "b", room = 3)
        \\    let room = filled.room
        \\    if room != none:
        \\        print("b=" + str(room))
        \\    var zeroed: Slot
        \\    print(str(zeroed.room else -1))
        \\
    );
}

test "a struct recurses through an optional field, which is what ends it" {
    // `Node` holds a `Node?`, and the optional is what makes a struct
    // cycle finite: the field is one `Value` whether or not anything is
    // in it.  Reading one back is the boxed `strukt` payload.
    try agree(std.testing.allocator,
        \\struct Node:
        \\    value: Int
        \\    next: Node?
        \\
        \\func total(from: Node) -> Int:
        \\    var sum = from.value
        \\    let step = from.next
        \\    if step != none:
        \\        sum = sum + total(step)
        \\    return sum
        \\
        \\func main():
        \\    let tail = Node(value = 2, next = none)
        \\    let head = Node(value = 1, next = tail)
        \\    print(str(total(head)))
        \\    print(str(total(tail)))
        \\    let step = head.next
        \\    if step != none:
        \\        print("next=" + str(step.value))
        \\
    );
}

test "a heap optional agrees, and holding none owns nothing (S43)" {
    // The leak census is the proof: the object that came back inside a
    // `T?` is released at the end of the scope that received it, and
    // the absent one leaves nothing behind to release.  A `none` owns
    // nothing, so neither engine may count it.
    try agree(std.testing.allocator,
        \\func pick(want: Bool) -> List(Int)?:
        \\    if want:
        \\        let made = new List(Int)
        \\        made.append(3)
        \\        made.append(4)
        \\        return made
        \\    return none
        \\
        \\func main():
        \\    var held: List(Int)? = none
        \\    if held == none:
        \\        print("absent")
        \\    let got = pick(true)
        \\    if got != none:
        \\        print("len=" + str(len(got)) + " first=" + str(got[0]))
        \\        free(got)
        \\    let missing = pick(false)
        \\    if missing == none:
        \\        print("nothing came back")
        \\    let owned = pick(true)
        \\    if owned != none:
        \\        print("owned=" + str(len(owned)))
        \\
    );
}

test "optionals in a loop agree, boxed into container cells and back" {
    // Three seams at once: a `T?` rebuilt every iteration through the
    // one scratch box the call site owns, a `T?` local carrying loop
    // state, and structs with an optional field stored in a `List` —
    // where the field is a `runtime.Value` in a container cell rather
    // than in a frame slot.
    try agree(std.testing.allocator,
        \\struct Cell:
        \\    tag: String
        \\    room: Int?
        \\
        \\func even(n: Int) -> Int?:
        \\    if n % 2 == 0:
        \\        return n
        \\    return none
        \\
        \\func show(room: Int?) -> String:
        \\    if room == none:
        \\        return "-"
        \\    return str(room)
        \\
        \\func main():
        \\    var seen = 0
        \\    var i = 0
        \\    while i < 8:
        \\        let maybe = even(i)
        \\        if maybe != none:
        \\            seen = seen + maybe
        \\        i = i + 1
        \\    print("sum of evens=" + str(seen))
        \\    var last: Int? = none
        \\    var j = 0
        \\    while j < 5:
        \\        last = even(j)
        \\        j = j + 1
        \\    print("last=" + str(last else -1))
        \\    let cells = new List(Cell)
        \\    var k = 0
        \\    while k < 4:
        \\        cells.append(Cell(tag = str(k), room = even(k)))
        \\        k = k + 1
        \\    var out = ""
        \\    for cell in cells:
        \\        out = out + cell.tag + ":" + show(cell.room) + " "
        \\    print(out)
        \\    free(cells)
        \\    print(show(even(2)) + "/" + show(even(3)))
        \\
    );
}

test "every payload a T? can hold survives being returned" {
    // A returned `T?` travels through `%out`, whose `dereferenceable`
    // comes from `resultSize` — a hand-written table, and the one place
    // a wrong number would be a fault rather than a wrong answer.
    // `Bool?` is the corner: `{i1, i1}` really is two bytes, not the
    // eight every other payload rounds up to.
    try agree(std.testing.allocator,
        \\struct Point:
        \\    x: Int
        \\    y: Int
        \\
        \\func flag(want: Bool) -> Bool?:
        \\    if want:
        \\        return false
        \\    return none
        \\
        \\func text(want: Bool) -> String?:
        \\    if want:
        \\        return "hi"
        \\    return none
        \\
        \\func ratio(want: Bool) -> Float?:
        \\    if want:
        \\        return 2.5
        \\    return none
        \\
        \\func spot(want: Bool) -> Point?:
        \\    if want:
        \\        return Point(x = 1, y = 2)
        \\    return none
        \\
        \\func main():
        \\    print(str(flag(true) else true) + " " + str(flag(false) else true))
        \\    print((text(true) else "-") + " " + (text(false) else "-"))
        \\    print(str(ratio(true) else -1.0) + " " + str(ratio(false) else -1.0))
        \\    let here = spot(true)
        \\    if here != none:
        \\        print("x=" + str(here.x) + " y=" + str(here.y))
        \\    if spot(false) == none:
        \\        print("no spot")
        \\    let f = flag(true)
        \\    if f != none:
        \\        if f:
        \\            print("true branch")
        \\        else:
        \\            print("false branch")
        \\
    );
}

test "the null object put in a T? is present, because absence is not a handle" {
    // The case that decides the representation.  `raw` is the zero of
    // an object-typed place — the null handle, a value that is *there*
    // and traps on use (S40) — and borrowing it into a `List(Int)?`
    // is accepted without a diagnostic.  The interpreter answers
    // "present" because absence there is the tag.  Had the lowering
    // spent the null index on `none`, as docs/FAILURE.md first
    // proposed, this program would answer "absent" instead and the two
    // engines would part company here and nowhere else.
    try agree(std.testing.allocator,
        \\func look(xs: List(Int)?) -> Bool:
        \\    return xs == none
        \\
        \\func main():
        \\    var raw: List(Int)
        \\    print("absent=" + str(look(raw)))
        \\    let real = new List(Int)
        \\    real.append(1)
        \\    print("absent=" + str(look(real)))
        \\    free(real)
        \\
    );
}

// ---------------------------------------------------------------------------
// The host services
// ---------------------------------------------------------------------------

test "files, arguments, the screen, and the keyboard agree" {
    try agree(std.testing.allocator,
        \\func main() -> !:
        \\    print(str(arg_count()) + " " + arg(0) + "," + arg(1))
        \\    print(str(file_exists("notes.txt")))
        \\    try file_write("notes.txt", "hello world")
        \\    print(str(file_exists("notes.txt")) + " " + try file_read("notes.txt"))
        \\    print(str(term_rows()) + "x" + str(term_cols()))
        \\    term_clear()
        \\    term_move(2, 3)
        \\    term_style(114, 236, true)
        \\    term_write("drawn")
        \\    term_flush()
        \\    var pressed = 0
        \\    while pressed < 4:
        \\        print(key_read() + "/" + key_text())
        \\        pressed = pressed + 1
        \\
    );
}

test "a file that was never written errors on both engines" {
    // The world said no, so this is news and not a bug: the two
    // engines have to agree on the code, the words, and the one line
    // the error records (docs/FAILURE.md).
    try agree(std.testing.allocator,
        \\func main() -> !:
        \\    print("before")
        \\    print(try file_read("nothing-here.txt"))
        \\
    );
}

test "a caught error is handled and the run finishes clean" {
    try agree(std.testing.allocator,
        \\func main():
        \\    let text = file_read("nothing-here.txt") catch "(none)"
        \\    print(text)
        \\    file_write("/nowhere/at/all/notes.txt", "x") catch:
        \\        print("write refused")
        \\    print("still running")
        \\
    );
}

test "error() crosses several frames, and the origin is the raise site" {
    try agree(std.testing.allocator,
        \\func inner(n: Int) -> Int!:
        \\    if n > 2:
        \\        error("too big: " + str(n))
        \\    return n * 2
        \\
        \\func middle(n: Int) -> Int!:
        \\    return try inner(n)
        \\
        \\func outer(n: Int) -> Int!:
        \\    return try middle(n)
        \\
        \\func main() -> !:
        \\    print(str(try outer(1)))
        \\    print(str(try outer(5)))
        \\
    );
}

test "an error path releases the objects and the String storage it owns" {
    // The leak census is the proof: every frame the error left
    // through released what it owned, so a caught error leaves the
    // heap exactly where a returning call would (S4, S34).
    try agree(std.testing.allocator,
        \\func gather(path: String) -> Int!:
        \\    let words = new List(String)
        \\    words.append("alpha")
        \\    words.append("beta")
        \\    let held = "prefix-" + path
        \\    let text = try file_read(path)
        \\    words.append(held + text)
        \\    return len(words)
        \\
        \\func main():
        \\    var total = 0
        \\    var round = 0
        \\    while round < 3:
        \\        total = total + (gather("nothing-here.txt") catch -1)
        \\        round = round + 1
        \\    print(str(total))
        \\
    );
}

test "text carried across a try keeps the form it was in" {
    // The crossing a `try` needs is where errors and small-string
    // optimisation meet.  A fallible call's result has to survive the
    // branch on its outcome, and the slot it crosses in is the slot
    // that owns it — so short text stays inside the value and long
    // text keeps pointing where it did (docs/STRINGS.md).  Carrying
    // it in a borrowing slot instead marked inline text as *outside*,
    // and the release at the end of the statement freed a pointer into
    // the frame.
    try agree(std.testing.allocator,
        \\func main() -> !:
        \\    try file_write("notes.txt", "hello world")
        \\    let short = try file_read("notes.txt")
        \\    print(short + "/" + str(len(short)))
        \\    try file_write("notes.txt", "a string well past the inline capacity of a value")
        \\    let long = try file_read("notes.txt")
        \\    print(long + "/" + str(len(long)))
        \\    print(str(file_exists("notes.txt")) + " " + try file_read("notes.txt"))
        \\
    );
}

test "a caught error leaves the value it never produced releasable" {
    // A fallible function that errors writes nothing through `%out`,
    // and the store that carries its result across the branch runs on
    // that path too.  So the errored edge empties `%out` on the way
    // out, and what the caller carries is the empty String rather than
    // whatever the stack held — which the census then proves.
    try agree(std.testing.allocator,
        \\func load(path: String) -> String!:
        \\    return try file_read(path)
        \\
        \\func main():
        \\    var round = 0
        \\    while round < 3:
        \\        let text = load("nothing-here.txt") catch "(none)"
        \\        print(text)
        \\        round = round + 1
        \\
    );
}

test "a fallible call handing back an object gives it up on both paths" {
    try agree(std.testing.allocator,
        \\func load(path: String) -> List(String)!:
        \\    let lines = new List(String)
        \\    lines.append(try file_read(path))
        \\    return lines
        \\
        \\func main():
        \\    let missing = load("nothing-here.txt") catch new List(String)
        \\    print(str(len(missing)))
        \\    free(missing)
        \\
    );
}

test "an argument index out of range traps argument_bounds on both engines" {
    try agree(std.testing.allocator,
        \\func main():
        \\    print(arg(0))
        \\    print(arg(9))
        \\
    );
}

test "a withheld service group fails closed on both engines" {
    const gpa = std.testing.allocator;
    try agreeGiven(gpa,
        \\func main():
        \\    print(str(file_exists("notes.txt")))
        \\
    , .{ .files = false });
    try agreeGiven(gpa,
        \\func main():
        \\    print(str(arg_count()))
        \\
    , .{ .arguments = false });
    try agreeGiven(gpa,
        \\func main():
        \\    print(str(term_rows()))
        \\
    , .{ .terminal = false });
    try agreeGiven(gpa,
        \\func main():
        \\    print(key_text())
        \\
    , .{ .terminal = false });
}

test "owned String bytes agree, census included" {
    // docs/STRINGS.md's store sites, all on one page: a returned view
    // of a parameter, a container that keeps what it is handed, a copy
    // that outlives its original, a field assigned twice, a map's keys
    // and values, and a read that survives a call emptying the
    // container it came from.  `agree` compares the leak census as
    // well as the bytes, so a store that forgot to copy shows up here
    // even when it prints the same.
    try agree(std.testing.allocator,
        \\import std.strings
        \\
        \\struct Tag:
        \\    label: String
        \\    count: Int
        \\
        \\func widen(s: String) -> String:
        \\    return strings.trim(s)
        \\
        \\func drop_first(pieces: List(String)) -> Int:
        \\    pieces.remove(0)
        \\    return 1
        \\
        \\func measure(left: String, right: Int) -> Int:
        \\    return len(left) + right
        \\
        \\func main():
        \\    let trimmed = widen("   padded   ")
        \\    print(trimmed)
        \\
        \\    var names = new List(String)
        \\    names.append("ada")
        \\    names.append(trimmed + "-lovelace")
        \\    names[0] = names[1]
        \\    print(names[0] + " " + str(len(names)))
        \\    var duplicate = copy names
        \\    free(names)
        \\    print(duplicate[1])
        \\    free(duplicate)
        \\
        \\    var tag = Tag(label = "one", count = 1)
        \\    tag.label = "two"
        \\    tag.label = tag.label + "-three"
        \\    var copied = tag
        \\    copied.label = "other"
        \\    print(tag.label + " " + copied.label)
        \\
        \\    var table = new Map(String, String)
        \\    table["k" + str(1)] = "v1"
        \\    table["k1"] = "v" + str(2)
        \\    var keys = table.keys()
        \\    var values = table.values()
        \\    print(keys[0] + values[0])
        \\    free(keys)
        \\    free(values)
        \\    table.remove("k1")
        \\    free(table)
        \\
        \\    var pieces = new List(String)
        \\    pieces.append("first-piece")
        \\    pieces.append("second")
        \\    print(str(measure(pieces[0], drop_first(pieces))))
        \\    free(pieces)
        \\
        \\    var text = "abcdef"
        \\    text = text[1:5]
        \\    text = text + text
        \\    print(text)
        \\
        \\    var cells = new Array(String, 3)
        \\    cells[0] = "x" + str(0)
        \\    cells[1] = cells[0]
        \\    cells[0] = "y"
        \\    print(cells[0] + cells[1] + str(len(cells[2])))
        \\    free(cells)
        \\
    );
}

test "text agrees on both sides of the boundary between its two forms" {
    // Short text lives inside the value and long text behind a pointer
    // (docs/STRINGS.md), and the two engines choose the same form for
    // the same bytes — but nothing in the language says so, which is
    // exactly why every length around the boundary is checked here on
    // every path a String can take: a binding, a container element, a
    // map key, a struct field, a return, a slice, and a concat.
    //
    // 22 is `runtime.inline_capacity`.  If that number ever moves,
    // these lengths must move with it.
    try agree(std.testing.allocator,
        \\import std.strings
        \\
        \\struct Held:
        \\    label: String
        \\
        \\func echo(s: String) -> String:
        \\    return s
        \\
        \\func grow(s: String) -> String:
        \\    return s + s
        \\
        \\func main():
        \\    var words = new List(String)
        \\    var table = new Map(String, String)
        \\    for size in [0, 1, 21, 22, 23, 64]:
        \\        let text = strings.repeat("a", size)
        \\        let kept = echo(text)
        \\        words.append(kept)
        \\        table[kept] = kept
        \\        let held = Held(label = kept)
        \\        print(str(size) + " " + str(len(kept)) + " " + str(len(held.label)) +
        \\            " " + str(len(words[len(words) - 1])) + " " + str(len(table[kept])) +
        \\            " " + str(table.has(kept)))
        \\    free(words)
        \\    free(table)
        \\
    );
    // The transitions in both directions: short grown long by `+`,
    // long cut back to short by a slice, and both stored afterwards.
    try agree(std.testing.allocator,
        \\import std.strings
        \\
        \\func grow(s: String) -> String:
        \\    return s + s
        \\
        \\func main():
        \\    var kept = new List(String)
        \\    for size in [1, 11, 12, 21, 22, 23]:
        \\        var text = strings.repeat("b", size)
        \\        text = grow(text)
        \\        kept.append(text)
        \\        var cut = text[0:1]
        \\        cut = cut + text[0:size]
        \\        kept.append(cut)
        \\        print(str(len(text)) + ":" + text + " " + str(len(cut)) + ":" + cut)
        \\    var joined = ""
        \\    for piece in kept:
        \\        joined = joined + str(len(piece)) + ","
        \\    print(joined)
        \\    free(kept)
        \\
    );
    // A long String cut down to short, kept, and then the original
    // overwritten — the case where a borrow of the long bytes would
    // still be looking at them.
    try agree(std.testing.allocator,
        \\import std.strings
        \\
        \\func main():
        \\    var source = strings.repeat("cd", 40)
        \\    var small = source[0:6]
        \\    var cells = new Array(String, 2)
        \\    cells[0] = small
        \\    cells[1] = source
        \\    source = "replaced"
        \\    small = small + "!"
        \\    print(cells[0] + " " + str(len(cells[1])) + " " + small + " " + source)
        \\    free(cells)
        \\
    );
}

test "a loop name agrees whether it borrows its element or copies it" {
    try agree(std.testing.allocator,
        \\func main():
        \\    var words = new List(String)
        \\    words.append("aa")
        \\    words.append("bb")
        \\    words.append("cc")
        \\    var total = 0
        \\    for w in words:
        \\        total += len(w)
        \\    print(str(total))
        \\    var seen = ""
        \\    for w in words:
        \\        seen = seen + w
        \\        words[0] = "zz"
        \\    print(seen)
        \\    free(words)
        \\
        \\    var table = new Map(String, String)
        \\    table["a"] = "1"
        \\    table["b"] = "2"
        \\    var joined = ""
        \\    for key, value in table:
        \\        joined = joined + key + value
        \\    print(joined)
        \\    free(table)
        \\
    );
}

test "a trap agrees while every frame is still holding String bytes" {
    try agree(std.testing.allocator,
        \\struct Tag:
        \\    label: String
        \\    count: Int
        \\
        \\func deeper(name: String) -> Int:
        \\    let held = name + "-held"
        \\    var tag = Tag(label = held, count = 1)
        \\    trap(tag.label)
        \\    return 0
        \\
        \\func main():
        \\    let outer = "kept" + "-here"
        \\    var also = Tag(label = outer, count = 2)
        \\    print(str(deeper(also.label)))
        \\
    );
}
