const std = @import("std");
const testing = std.testing;
const mir = @import("../06_mir.zig");
const backend = @import("../backend.zig");
const compile_mod = @import("../compile.zig");
const types = @import("../support/types.zig");
const machine_mod = @import("machine.zig");

const Machine = machine_mod.Machine;
const RuntimeValue = backend.RuntimeValue;
const Result = backend.Result;
const Allocator = std.mem.Allocator;
const max_trace_frames = 64;

const Bench = struct {
    program: mir.Program,
    arena: std.heap.ArenaAllocator,

    fn setup(source: []const u8, options: types.CompileOptions) !Bench {
        var result = try compile_mod.compile(testing.allocator, source, options);
        switch (result) {
            .success => {},
            .failure => |*diagnostics| {
                const rendered = try diagnostics.render(testing.allocator);
                defer testing.allocator.free(rendered);
                std.debug.print("unexpected diagnostics:\n{s}", .{rendered});
                result.deinit();
                return error.TestUnexpectedResult;
            },
        }
        return .{
            .program = result.success,
            .arena = std.heap.ArenaAllocator.init(testing.allocator),
        };
    }

    fn deinit(self: *Bench) void {
        self.arena.deinit();
        self.program.deinit();
    }

    fn evaluate(self: *Bench) !Result {
        return backend.evaluate(
            .{ .arena = self.arena.allocator(), .objects = testing.allocator },
            &self.program,
            .{ .call_depth = 64 },
        );
    }

    fn evaluateHosted(self: *Bench, host: backend.Host) !Result {
        return backend.evaluateHosted(
            .{ .arena = self.arena.allocator(), .objects = testing.allocator },
            &self.program,
            .{ .call_depth = 64 },
            host,
        );
    }
};

/// The four bytes of U+1F642, written where a Luce string literal has
/// to carry them: the lexer's escape set is `\n \t \\ \"` and nothing
/// else, so a codepoint above ASCII arrives as itself.
const smiley = "\xF0\x9F\x99\x82";

test "the plan's vertical slice: smooth pointer transform" {
    var bench = try Bench.setup(
        \\struct Point:
        \\    x: Float
        \\    y: Float
        \\
        \\func smooth(current: Point, target: Point, amount: Float) -> Point:
        \\    return Point(
        \\        x = current.x + (target.x - current.x) * amount,
        \\        y = current.y + (target.y - current.y) * amount,
        \\    )
        \\
        \\func main():
        \\    let previous = Point(x = 0.0, y = 0.0)
        \\    let pointer = Point(x = 10.0, y = -4.0)
        \\    let eased = smooth(previous, pointer, 0.25)
        \\    assert(eased.x == 2.5)
        \\    assert(eased.y == -1.0)
        \\
    , script_options);
    defer bench.deinit();

    try testing.expect(try bench.evaluate() == .success);
}

test "namespaced struct functions execute through qualified calls" {
    var bench = try Bench.setup(
        \\struct Math:
        \\    func twice(value: Int) -> Int:
        \\        return value * 2
        \\
        \\    func plus(left: Int, right: Int) -> Int:
        \\        return left + right
        \\
        \\func main():
        \\    assert(Math.twice(Math.plus(3, 4)) == 14)
        \\
    , script_options);
    defer bench.deinit();

    try testing.expect(try bench.evaluate() == .success);
}

test "loops, recursion, strings, and builtins compute" {
    var bench = try Bench.setup(
        \\func factorial(value: Int) -> Int:
        \\    if value <= 1:
        \\        return 1
        \\    return value * factorial(value - 1)
        \\
        \\func main():
        \\    var total = 0
        \\    for index in range(1, 11):
        \\        total = total + index
        \\    assert(total == 55)
        \\    assert(factorial(10) == 3628800)
        \\    assert("sum " + "of ten" == "sum of ten")
        \\    assert(min(clamp(total, 0, 40), abs(-3)) == 3)
        \\
    , script_options);
    defer bench.deinit();

    try testing.expect(try bench.evaluate() == .success);
}

test "checked string intrinsics slice and inspect UTF-8 bytes" {
    var bench = try Bench.setup("func main():\n" ++
        "    let text = \"ab" ++ smiley ++ "cd\\nnext\"\n" ++
        "    assert(text[0:2] == \"ab\")\n" ++
        "    assert(text[2:6] == \"" ++ smiley ++ "\")\n" ++
        "    assert(text.byte_at(2) == 240)\n", script_options);
    defer bench.deinit();

    try testing.expect(try bench.evaluate() == .success);
}

test "string intrinsics implement multiline UTF-8-safe edits" {
    var bench = try Bench.setup("func continuation(byte: Int) -> Bool:\n" ++
        "    return byte >= 128 and byte < 192\n" ++
        "\n" ++
        "func previous(value: String, cursor: Int) -> Int:\n" ++
        "    var at = cursor - 1\n" ++
        "    while at > 0 and continuation(value.byte_at(at)):\n" ++
        "        at = at - 1\n" ++
        "    return at\n" ++
        "\n" ++
        "func inserted(text: String, cursor: Int, added: String) -> String:\n" ++
        "    return text[0:cursor] + added + text[cursor:len(text)]\n" ++
        "\n" ++
        "func erased(text: String, cursor: Int) -> String:\n" ++
        "    let before = previous(text, cursor)\n" ++
        "    return text[0:before] + text[cursor:len(text)]\n" ++
        "\n" ++
        "func main():\n" ++
        "    let original = \"A" ++ smiley ++ "\\nB\"\n" ++
        "    assert(inserted(original, 5, \"x\") == \"A" ++ smiley ++ "x\\nB\")\n" ++
        "    assert(erased(original, 5) == \"A\\nB\")\n" ++
        "    assert(previous(original, 5) == 1)\n", script_options);
    defer bench.deinit();

    try testing.expect(try bench.evaluate() == .success);
}

test "checked string intrinsics trap on bounds and UTF-8 splits" {
    const text = "\"a" ++ smiley ++ "b\"";
    const cases = [_]struct { edit: []const u8, code: mir.TrapCode }{
        .{ .edit = "assert(len(" ++ text ++ "[-1:0]) == 0)", .code = .string_bounds },
        .{ .edit = "assert(len(" ++ text ++ "[0:7]) == 0)", .code = .string_bounds },
        .{ .edit = "assert(len(" ++ text ++ "[0:2]) == 0)", .code = .string_boundary },
        .{ .edit = "assert(" ++ text ++ ".byte_at(6) == 0)", .code = .string_bounds },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(
            testing.allocator,
            "func main():\n    {s}\n",
            .{case.edit},
        );
        defer testing.allocator.free(source);
        var bench = try Bench.setup(source, script_options);
        defer bench.deinit();
        try expectTrap(&bench, case.code);
    }
}

test "string intrinsics reject wrong argument types" {
    var result = try compile_mod.compile(testing.allocator,
        \\func main():
        \\    let text = 1[0:1]
        \\
    , script_options);
    defer result.deinit();
    try testing.expect(result == .failure);
    try testing.expectEqualStrings("luce.sema.index", result.failure.at(0).?.code);
}

fn expectTrap(bench: *Bench, code: mir.TrapCode) !void {
    const result = try bench.evaluate();
    try testing.expect(result == .trap);
    try testing.expectEqual(code, result.trap.code);
}

test "checked arithmetic and conversions trap" {
    const cases = [_]struct { line: []const u8, code: mir.TrapCode }{
        .{ .line = "assert(9223372036854775807 + 1 == 0)", .code = .integer_overflow },
        .{ .line = "assert(1 / (2 - 2) == 0)", .code = .divide_by_zero },
        .{ .line = "assert(Int(1.0e300) == 0)", .code = .conversion_range },
        .{ .line = "assert(1 == 0)", .code = .assertion_failed },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(
            testing.allocator,
            "func main():\n    {s}\n",
            .{case.line},
        );
        defer testing.allocator.free(source);
        var bench = try Bench.setup(source, script_options);
        defer bench.deinit();
        try expectTrap(&bench, case.code);
    }

    var explicit_bench = try Bench.setup(
        \\func main():
        \\    trap("torn seam")
        \\
    , script_options);
    defer explicit_bench.deinit();
    const explicit = try explicit_bench.evaluate();
    try testing.expect(explicit == .trap);
    try testing.expectEqual(mir.TrapCode.explicit_trap, explicit.trap.code);
    try testing.expectEqualStrings("torn seam", explicit.trap.message);
}

test "unbounded recursion hits the call depth limit" {
    var bench = try Bench.setup(
        \\func dive(depth: Int) -> Int:
        \\    return dive(depth + 1)
        \\
        \\func main():
        \\    assert(dive(0) == 0)
        \\
    , script_options);
    defer bench.deinit();
    try expectTrap(&bench, .call_depth_exceeded);
}

const TestHost = struct {
    printed: std.ArrayList(u8) = .empty,
    screen: std.ArrayList(u8) = .empty,
    arguments: []const []const u8 = &.{},
    file_path: []const u8 = "",
    file_content: []const u8 = "",
    /// Copies, not views.  A host service borrows the bytes it is
    /// handed for the duration of the call and no longer — a Luce
    /// String belongs to the binding or statement that holds it, and
    /// that may die the moment the call returns (docs/STRINGS.md).
    written_path: std.ArrayList(u8) = .empty,
    written_content: std.ArrayList(u8) = .empty,
    fail_write: bool = false,
    keys: []const backend.KeyEvent = &.{},
    next_key: usize = 0,
    /// Scripted standard input, taken in order; running off the end is
    /// end of input.
    lines: []const []const u8 = &.{},
    next_line: usize = 0,
    /// What went to standard error, and the prompts `read_line` wrote
    /// — both kept apart from `printed`, because they are different
    /// channels and a test that mixed them could not tell them apart.
    reported: std.ArrayList(u8) = .empty,
    prompted: std.ArrayList(u8) = .empty,
    /// A clock that ticks a fixed amount per reading, and the waits
    /// the program asked for.
    clock: i64 = 1_000,
    slept: std.ArrayList(i64) = .empty,
    /// The directory this host will list, or null for a host whose
    /// listing fails.
    directory: ?[]const []const u8 = null,
    /// What `file_append`, `file_delete` and `file_rename` were told.
    appended: std.ArrayList(u8) = .empty,
    deleted: std.ArrayList(u8) = .empty,
    renamed: std.ArrayList(u8) = .empty,

    fn deinit(self: *TestHost) void {
        self.printed.deinit(testing.allocator);
        self.screen.deinit(testing.allocator);
        self.written_path.deinit(testing.allocator);
        self.written_content.deinit(testing.allocator);
        self.reported.deinit(testing.allocator);
        self.prompted.deinit(testing.allocator);
        self.slept.deinit(testing.allocator);
        self.appended.deinit(testing.allocator);
        self.deleted.deinit(testing.allocator);
        self.renamed.deinit(testing.allocator);
    }

    fn printLine(context: *anyopaque, text: []const u8) error{OutOfMemory}!void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        try self.printed.appendSlice(testing.allocator, text);
        try self.printed.append(testing.allocator, '\n');
    }

    fn argCount(context: *anyopaque) u32 {
        const self: *TestHost = @ptrCast(@alignCast(context));
        return @intCast(self.arguments.len);
    }

    fn argAt(context: *anyopaque, arena: Allocator, index: u32) error{OutOfMemory}!?[]const u8 {
        const self: *TestHost = @ptrCast(@alignCast(context));
        if (index >= self.arguments.len) return null;
        return try arena.dupe(u8, self.arguments[index]);
    }

    fn readFile(context: *anyopaque, arena: Allocator, path: []const u8) error{OutOfMemory}!backend.FileRead {
        const self: *TestHost = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, path, self.file_path)) return .failed;
        return .{ .content = try arena.dupe(u8, self.file_content) };
    }

    fn writeFile(context: *anyopaque, path: []const u8, content: []const u8) bool {
        const self: *TestHost = @ptrCast(@alignCast(context));
        if (self.fail_write) return false;
        self.written_path.clearRetainingCapacity();
        self.written_content.clearRetainingCapacity();
        self.written_path.appendSlice(testing.allocator, path) catch return false;
        self.written_content.appendSlice(testing.allocator, content) catch return false;
        return true;
    }

    fn fileExists(context: *anyopaque, path: []const u8) bool {
        const self: *TestHost = @ptrCast(@alignCast(context));
        return std.mem.eql(u8, path, self.file_path);
    }

    fn appendFile(context: *anyopaque, path: []const u8, content: []const u8) bool {
        const self: *TestHost = @ptrCast(@alignCast(context));
        if (self.fail_write) return false;
        self.appended.appendSlice(testing.allocator, path) catch return false;
        self.appended.append(testing.allocator, ':') catch return false;
        self.appended.appendSlice(testing.allocator, content) catch return false;
        return true;
    }

    fn deleteFile(context: *anyopaque, path: []const u8) bool {
        const self: *TestHost = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, path, self.file_path)) return false;
        self.deleted.appendSlice(testing.allocator, path) catch return false;
        return true;
    }

    fn renameFile(context: *anyopaque, from: []const u8, to: []const u8) bool {
        const self: *TestHost = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, from, self.file_path)) return false;
        self.renamed.appendSlice(testing.allocator, from) catch return false;
        self.renamed.append(testing.allocator, '>') catch return false;
        self.renamed.appendSlice(testing.allocator, to) catch return false;
        return true;
    }

    fn listDirectory(
        context: *anyopaque,
        arena: Allocator,
        path: []const u8,
    ) error{OutOfMemory}!?[]const []const u8 {
        _ = arena;
        _ = path;
        const self: *TestHost = @ptrCast(@alignCast(context));
        return self.directory;
    }

    fn readLine(
        context: *anyopaque,
        arena: Allocator,
        prompt: []const u8,
    ) error{OutOfMemory}!?[]const u8 {
        _ = arena;
        const self: *TestHost = @ptrCast(@alignCast(context));
        try self.prompted.appendSlice(testing.allocator, prompt);
        if (self.next_line >= self.lines.len) return null;
        defer self.next_line += 1;
        return self.lines[self.next_line];
    }

    fn printError(context: *anyopaque, text: []const u8) error{OutOfMemory}!void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        try self.reported.appendSlice(testing.allocator, text);
        try self.reported.append(testing.allocator, '\n');
    }

    fn clockMilliseconds(context: *anyopaque) i64 {
        const self: *TestHost = @ptrCast(@alignCast(context));
        defer self.clock += 17;
        return self.clock;
    }

    fn sleepMilliseconds(context: *anyopaque, milliseconds: i64) void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        self.slept.append(testing.allocator, milliseconds) catch {};
    }

    fn environmentValue(
        context: *anyopaque,
        arena: Allocator,
        name: []const u8,
    ) error{OutOfMemory}!?[]const u8 {
        _ = context;
        _ = arena;
        if (std.mem.eql(u8, name, "LUCE_MODE")) return "test";
        return null;
    }

    fn rows(context: *anyopaque) i64 {
        _ = context;
        return 24;
    }

    fn cols(context: *anyopaque) i64 {
        _ = context;
        return 80;
    }

    fn record(self: *TestHost, comptime format: []const u8, values: anytype) error{OutOfMemory}!void {
        const line = try std.fmt.allocPrint(testing.allocator, format, values);
        defer testing.allocator.free(line);
        try self.screen.appendSlice(testing.allocator, line);
    }

    fn clear(context: *anyopaque) error{OutOfMemory}!void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        try self.record("[clear]", .{});
    }

    fn move(context: *anyopaque, row: i64, col: i64) error{OutOfMemory}!void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        try self.record("[move {d},{d}]", .{ row, col });
    }

    fn style(context: *anyopaque, foreground: i64, background: i64, bold: bool) error{OutOfMemory}!void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        try self.record("[style {d},{d},{}]", .{ foreground, background, bold });
    }

    fn write(context: *anyopaque, text: []const u8) error{OutOfMemory}!void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        try self.record("{s}", .{text});
    }

    fn flush(context: *anyopaque) error{OutOfMemory}!void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        try self.record("[flush]", .{});
    }

    fn key(context: *anyopaque, arena: Allocator) error{OutOfMemory}!backend.KeyEvent {
        const self: *TestHost = @ptrCast(@alignCast(context));
        if (self.next_key >= self.keys.len) return .{ .name = "none" };
        const event = self.keys[self.next_key];
        self.next_key += 1;
        return .{
            .name = try arena.dupe(u8, event.name),
            .text = try arena.dupe(u8, event.text),
        };
    }

    fn host(self: *TestHost) backend.Host {
        return .{
            .context = self,
            .printFn = printLine,
            .argCountFn = argCount,
            .argFn = argAt,
            .readFileFn = readFile,
            .writeFileFn = writeFile,
            .fileExistsFn = fileExists,
            .appendFileFn = appendFile,
            .deleteFileFn = deleteFile,
            .renameFileFn = renameFile,
            .listDirectoryFn = listDirectory,
            .readLineFn = readLine,
            .printErrorFn = printError,
            .clockFn = clockMilliseconds,
            .sleepFn = sleepMilliseconds,
            .envFn = environmentValue,
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
};

const hosted_options: types.CompileOptions = .{ .allow_host = true };

test "host builtins fail closed without a host" {
    var bench = try Bench.setup(
        \\func main():
        \\    print("hello")
        \\
    , hosted_options);
    defer bench.deinit();
    try expectTrap(&bench, .host_unavailable);
}

test "print, arguments, and files flow through the host" {
    var bench = try Bench.setup(
        \\func main() -> !:
        \\    print("args: " + Int_to_text(arg_count()))
        \\    let path = arg(0)
        \\    if file_exists(path):
        \\        print(try file_read(path))
        \\    try file_write("out.txt", "saved")
        \\
        \\func Int_to_text(value: Int) -> String:
        \\    if value == 0:
        \\        return "0"
        \\    var text = ""
        \\    var left = value
        \\    while left > 0:
        \\        let digit = left % 10
        \\        text = "0123456789"[digit:digit + 1] + text
        \\        left = left / 10
        \\    return text
        \\
    , hosted_options);
    defer bench.deinit();

    var host: TestHost = .{
        .arguments = &.{"notes.txt"},
        .file_path = "notes.txt",
        .file_content = "file body",
    };
    defer host.deinit();
    const result = try bench.evaluateHosted(host.host());
    try testing.expect(result == .success);
    try testing.expectEqualStrings("args: 1\nfile body\n", host.printed.items);
    try testing.expectEqualStrings("out.txt", host.written_path.items);
    try testing.expectEqualStrings("saved", host.written_content.items);
}

test "std files wraps the host builtins faithfully" {
    var bench = try Bench.setup(
        \\import std.files
        \\
        \\func main() -> !:
        \\    assert(files.exists("notes.txt"))
        \\    assert(not files.exists("ghost.txt"))
        \\    var lines = try files.read_lines("notes.txt")
        \\    assert(len(lines) == 2)
        \\    assert(lines[0] == "alpha" and lines[1] == "beta")
        \\    lines.append("gamma")
        \\    try files.write_lines("out.txt", lines)
        \\    try files.write("plain.txt", try files.read("notes.txt"))
        \\
    , hosted_options);
    defer bench.deinit();

    var host: TestHost = .{
        .file_path = "notes.txt",
        .file_content = "alpha\nbeta\n",
    };
    defer host.deinit();
    const result = try bench.evaluateHosted(host.host());
    try testing.expect(result == .success);
    try testing.expectEqual(@as(u32, 0), result.success.leaked_objects);
    try testing.expectEqualStrings("plain.txt", host.written_path.items);
    try testing.expectEqualStrings("alpha\nbeta\n", host.written_content.items);
}

test "std files reaches the four services beyond read and write" {
    var bench = try Bench.setup(
        \\import std.files
        \\import std.strings
        \\
        \\func main() -> !:
        \\    try files.append_text("log.txt", "one line\n")
        \\    try files.append_lines("log.txt", ["two", "three"])
        \\    try files.append_lines("log.txt", new List(String))
        \\    try files.rename("notes.txt", "kept.txt")
        \\    try files.delete("notes.txt")
        \\    let names = try files.list(".")
        \\    print(names.join(","))
        \\    free(names)
        \\
    , hosted_options);
    defer bench.deinit();

    var host: TestHost = .{
        .file_path = "notes.txt",
        // Deliberately out of order: `files.list` sorts, so that a
        // listing does not depend on what the file system felt like.
        .directory = &.{ "gamma", "alpha", "beta" },
    };
    defer host.deinit();
    const result = try bench.evaluateHosted(host.host());
    try testing.expect(result == .success);
    try testing.expectEqual(@as(u32, 0), result.success.leaked_objects);
    try testing.expectEqualStrings(
        "log.txt:one line\nlog.txt:two\nthree\n",
        host.appended.items,
    );
    try testing.expectEqualStrings("notes.txt>kept.txt", host.renamed.items);
    try testing.expectEqualStrings("notes.txt", host.deleted.items);
    try testing.expectEqualStrings("alpha,beta,gamma\n", host.printed.items);
}

test "a listing the world refuses is an error naming the path" {
    var bench = try Bench.setup(
        \\import std.files
        \\
        \\func main() -> !:
        \\    let names = try files.list("nowhere")
        \\    free(names)
        \\
    , hosted_options);
    defer bench.deinit();

    var host: TestHost = .{};
    defer host.deinit();
    const result = try bench.evaluateHosted(host.host());
    try testing.expectEqual(mir.ErrorCode.io_failed, result.errored.code);
    try testing.expectEqualStrings("cannot list nowhere", result.errored.message);
}

test "read_line answers a line, then absence; the prompt goes out in front" {
    var bench = try Bench.setup(
        \\func main():
        \\    var count = 0
        \\    var line = read_line("> ")
        \\    while line != none:
        \\        count = count + 1
        \\        print(str(count) + ":" + line)
        \\        line = read_line("> ")
        \\    print("done")
        \\
    , hosted_options);
    defer bench.deinit();

    var host: TestHost = .{ .lines = &.{ "alpha", "beta" } };
    defer host.deinit();
    const result = try bench.evaluateHosted(host.host());
    try testing.expect(result == .success);
    try testing.expectEqualStrings("1:alpha\n2:beta\ndone\n", host.printed.items);
    // Three reads, three prompts: the third is what discovered the
    // end of input.
    try testing.expectEqualStrings("> > > ", host.prompted.items);
}

test "the clock, the wait and the environment reach the host" {
    var bench = try Bench.setup(
        \\func main():
        \\    let started = clock_ms()
        \\    sleep_ms(30)
        \\    print("elapsed " + str(clock_ms() - started))
        \\    sleep_ms(0)
        \\    sleep_ms(-5)
        \\    print_error("to stderr")
        \\    print(env("LUCE_MODE") else "(unset)")
        \\    print(env("NOTHING") else "(unset)")
        \\
    , hosted_options);
    defer bench.deinit();

    var host: TestHost = .{};
    defer host.deinit();
    const result = try bench.evaluateHosted(host.host());
    try testing.expect(result == .success);
    try testing.expectEqualStrings("elapsed 17\ntest\n(unset)\n", host.printed.items);
    try testing.expectEqualStrings("to stderr\n", host.reported.items);
    // A duration that has already elapsed still reaches the host,
    // which is what decides there is no time left to wait — the
    // language does not make that a trap.
    try testing.expectEqualSlices(i64, &.{ 30, 0, -5 }, host.slept.items);
}

test "every new host service fails closed when the host withholds it" {
    const cases = [_][]const u8{
        \\func main():
        \\    print(read_line("") else "x")
        \\
        ,
        \\func main():
        \\    print_error("x")
        \\
        ,
        \\func main():
        \\    print(str(clock_ms()))
        \\
        ,
        \\func main():
        \\    sleep_ms(1)
        \\
        ,
        \\func main():
        \\    print(env("X") else "y")
        \\
        ,
        \\func main() -> !:
        \\    try file_append("x", "y")
        \\
        ,
        \\func main() -> !:
        \\    try file_delete("x")
        \\
        ,
        \\func main() -> !:
        \\    try file_rename("x", "y")
        \\
        ,
        \\func main() -> !:
        \\    let names = try dir_list(".")
        \\    free(names)
        \\
        ,
    };
    for (cases) |source| {
        var bench = try Bench.setup(source, hosted_options);
        defer bench.deinit();
        // A host with a console and nothing else: every service below
        // is optional, and reaching one that is not there touches
        // nothing (docs/V2.md's fail-closed rule).
        var host: TestHost = .{};
        defer host.deinit();
        const result = try bench.evaluateHosted(.{
            .context = &host,
            .printFn = TestHost.printLine,
        });
        try testing.expectEqual(mir.TrapCode.host_unavailable, result.trap.code);
    }
}

test "an argument out of range traps, and a refused write is an error" {
    // The two failures a host can hand back, and the line between
    // them: an index no argument could have is the program's mistake,
    // and a write the world would not take is not (docs/FAILURE.md).
    var bench = try Bench.setup(
        \\func main():
        \\    file_write("out.txt", "ignored") catch:
        \\        print("refused")
        \\    let missing = arg(5)
        \\
    , hosted_options);
    defer bench.deinit();

    var host: TestHost = .{ .fail_write = true };
    defer host.deinit();
    const result = try bench.evaluateHosted(host.host());
    try testing.expectEqual(mir.TrapCode.argument_bounds, result.trap.code);
    try testing.expectEqualStrings("refused\n", host.printed.items);
}

test "an uncaught error names its code, its words, and where it was raised" {
    var bench = try Bench.setup(
        \\func save(path: String) -> !:
        \\    try file_write(path, "body")
        \\
        \\func main() -> !:
        \\    print("before")
        \\    try save("out.txt")
        \\    print("never")
        \\
    , hosted_options);
    defer bench.deinit();

    var host: TestHost = .{ .fail_write = true };
    defer host.deinit();
    const result = try bench.evaluateHosted(host.host());
    try testing.expectEqual(mir.ErrorCode.io_failed, result.errored.code);
    try testing.expectEqualStrings("cannot write out.txt", result.errored.message);
    // One position, and it is the raise site rather than a stack: the
    // `try file_write` inside `save`, not the `try save` in `main`.
    try testing.expectEqualStrings("save", result.errored.origin.function);
    try testing.expect(result.errored.origin.line != 0);
    try testing.expectEqualStrings("before\n", host.printed.items);
}

test "error() raises the program's own words, and catch discards them" {
    var bench = try Bench.setup(
        \\func check(n: Int) -> Int!:
        \\    if n < 0:
        \\        error("negative: " + str(n))
        \\    return n
        \\
        \\func main() -> !:
        \\    print(str(check(-1) catch 0))
        \\    print(str(try check(7)))
        \\    print(str(try check(-2)))
        \\
    , hosted_options);
    defer bench.deinit();

    var host: TestHost = .{};
    defer host.deinit();
    const result = try bench.evaluateHosted(host.host());
    try testing.expectEqual(mir.ErrorCode.user_error, result.errored.code);
    try testing.expectEqualStrings("negative: -2", result.errored.message);
    try testing.expectEqualStrings("0\n7\n", host.printed.items);
}

test "terminal builtins drive the host screen and key queue" {
    var bench = try Bench.setup(
        \\func main():
        \\    term_clear()
        \\    term_move(1, 2)
        \\    term_style(114, -1, true)
        \\    term_write("hi ")
        \\    term_write(key_read())
        \\    term_write(key_text())
        \\    let quit = key_read()
        \\    term_flush()
        \\    print(quit)
        \\    print(Int_pair(term_rows(), term_cols()))
        \\
        \\func Int_pair(rows: Int, cols: Int) -> String:
        \\    var text = ""
        \\    if rows == 24 and cols == 80:
        \\        text = "24x80"
        \\    return text
        \\
    , hosted_options);
    defer bench.deinit();

    var host: TestHost = .{
        .keys = &.{
            .{ .name = "text", .text = "λ" },
            .{ .name = "ctrl_q" },
        },
    };
    defer host.deinit();
    const result = try bench.evaluateHosted(host.host());
    try testing.expect(result == .success);
    try testing.expectEqualStrings(
        "[clear][move 1,2][style 114,-1,true]hi textλ[flush]",
        host.screen.items,
    );
    try testing.expectEqualStrings("ctrl_q\n24x80\n", host.printed.items);
}

// ---------------------------------------------------------------------------
// Collections, explicit memory, and conversions
// ---------------------------------------------------------------------------

const script_options: types.CompileOptions = .{};

fn expectLeaks(bench: *Bench, wanted: u32) !void {
    const result = try bench.evaluate();
    try testing.expect(result == .success);
    try testing.expectEqual(wanted, result.success.leaked_objects);
}

test "lists grow, index, slice, iterate, and free explicitly" {
    var bench = try Bench.setup(
        \\func main():
        \\    var xs = [3, 1, 2]
        \\    assert(len(xs) == 3)
        \\    xs.append(9)
        \\    assert(xs[3] == 9)
        \\    xs[0] = 30
        \\    assert(xs[0] == 30)
        \\    xs.insert(1, 7)
        \\    assert(xs[1] == 7)
        \\    xs.remove(0)
        \\    assert(xs[0] == 7)
        \\    assert(xs.pop() == 9)
        \\    var total = 0
        \\    for x in xs:
        \\        total = total + x
        \\    assert(total == 10)
        \\    let mid = xs[1:]
        \\    assert(len(mid) == 2)
        \\    assert(mid[0] == 1)
        \\    assert(mid != xs)
        \\    assert(xs == xs)
        \\    free(mid)
        \\    free(xs)
        \\
    , script_options);
    defer bench.deinit();
    try expectLeaks(&bench, 0);
}

test "maps upsert, look up, and iterate keys in insertion order" {
    var bench = try Bench.setup(
        \\func main():
        \\    var ages = new Map(String, Int)
        \\    ages["ada"] = 36
        \\    ages["alan"] = 41
        \\    ages["ada"] = 37
        \\    assert(len(ages) == 2)
        \\    assert(ages["ada"] == 37)
        \\    assert(ages.has("alan"))
        \\    var joined = new Builder()
        \\    for key in ages:
        \\        joined.append(key)
        \\    assert(str(joined) == "adaalan")
        \\    ages.remove("alan")
        \\    assert(not ages.has("alan"))
        \\    ages.remove("ghost")
        \\    assert(len(ages) == 1)
        \\    free(ages)
        \\    free(joined)
        \\
    , script_options);
    defer bench.deinit();
    try expectLeaks(&bench, 0);
}

test "arrays are fixed, zeroed, multi-dimensional, and typed" {
    var bench = try Bench.setup(
        \\func corner(grid: Array(Int, _, _)) -> Int:
        \\    return grid[grid.dim(0) - 1, grid.dim(1) - 1]
        \\
        \\func main():
        \\    var grid = new Array(Int, 3, 4)
        \\    assert(grid.dim(0) == 3)
        \\    assert(grid.dim(1) == 4)
        \\    assert(len(grid) == 3)
        \\    assert(grid[2, 3] == 0)
        \\    grid[2, 3] = 7
        \\    assert(corner(grid) == 7)
        \\    var row = new Array(Float, 4)
        \\    row[0] = 2.5
        \\    var total = 0.0
        \\    for value in row:
        \\        total = total + value
        \\    assert(total == 2.5)
        \\    free(grid)
        \\    free(row)
        \\
    , script_options);
    defer bench.deinit();
    try expectLeaks(&bench, 0);
}

test "conversions: str, parse_int, parse_float, chr, ord" {
    var bench = try Bench.setup(
        \\func main():
        \\    assert(str(42) == "42")
        \\    assert(str(-7) == "-7")
        \\    assert(str(true) == "true")
        \\    assert(str(2.5) == "2.5")
        \\    assert((parse_int("123") else 0) == 123)
        \\    assert((parse_int("-9") else 0) == 0 - 9)
        \\    assert((parse_float("2.5") else 0.0) == 2.5)
        \\    assert(parse_int("twelve") == none)
        \\    assert(chr(65) == "A")
        \\    assert(chr(955) == "λ")
        \\    assert(ord("λ") == 955)
        \\    assert(ord("A") == 65)
        \\
    , script_options);
    defer bench.deinit();
    const result = try bench.evaluate();
    try testing.expect(result == .success);
}

test "structs and nested collections share objects by reference" {
    var bench = try Bench.setup(
        \\struct Bag:
        \\    label: String
        \\    items: List(Int)
        \\
        \\func main():
        \\    var inner = [1, 2]
        \\    var bag = Bag(label = "first", items = give inner)
        \\    let same_bag = bag
        \\    same_bag.items.append(3)
        \\    assert(len(bag.items) == 3)
        \\    var nested = new List(List(Int))
        \\    nested.append(copy bag.items)
        \\    nested[0].append(4)
        \\    assert(len(nested[0]) == 4)
        \\    assert(len(bag.items) == 3)
        \\
    , script_options);
    defer bench.deinit();
    try expectLeaks(&bench, 0);
}

test "collection misuse traps with stable codes" {
    const cases = [_]struct { source: []const u8, code: mir.TrapCode }{
        .{ .source =
        \\func main():
        \\    let xs = [1]
        \\    let bad = xs[5]
        \\
        , .code = .index_bounds },
        .{ .source =
        \\func main():
        \\    var xs: List(Int) = []
        \\    let bad = xs.pop()
        \\
        , .code = .empty_collection },
        .{ .source =
        \\func main():
        \\    var m = new Map(String, Int)
        \\    let bad = m["ghost"]
        \\
        , .code = .key_missing },
        .{ .source =
        \\func main():
        \\    var xs = [1]
        \\    let view = xs
        \\    free(xs)
        \\    view.append(2)
        \\
        , .code = .use_after_free },
        .{ .source =
        \\func main():
        \\    var xs = [1]
        \\    let view = xs
        \\    free(xs)
        \\    let bad = view[0]
        \\
        , .code = .use_after_free },
        .{ .source =
        \\func main():
        \\    var cells = new Array(List(Int), 2)
        \\    cells[0].append(1)
        \\
        , .code = .null_object },
        .{ .source =
        \\func main():
        \\    let bad = chr(11141111)
        \\
        , .code = .bad_codepoint },
        .{ .source =
        \\func main():
        \\    var grid = new Array(Int, 2, 2)
        \\    grid[2, 0] = 1
        \\
        , .code = .index_bounds },
    };
    for (cases) |case| {
        var bench = try Bench.setup(case.source, script_options);
        defer bench.deinit();
        try expectTrap(&bench, case.code);
    }
}

test "S33: nothing leaks — scope ownership frees what free() used to" {
    var bench = try Bench.setup(
        \\func main():
        \\    let kept = [1, 2, 3]
        \\    let copied = kept[0:2]
        \\    var released = new Builder()
        \\    free(released)
        \\    assert(len(copied) == 2)
        \\
    , script_options);
    defer bench.deinit();
    try expectLeaks(&bench, 0);
}

test "interpreter memory is bounded by depth and data, not by calls made" {
    var result = try compile_mod.compile(testing.allocator,
        \\struct Point:
        \\    x: Int
        \\    y: Int
        \\
        \\func nudge(p: Point) -> Int:
        \\    var scratch: Point
        \\    scratch.x = p.x + 1
        \\    return scratch.x + p.y
        \\
        \\func main():
        \\    var total = 0
        \\    for i in range(0, 100000):
        \\        total += nudge(Point(x = i, y = 1))
        \\    assert(total > 0)
        \\
    , script_options);
    defer result.deinit();
    try testing.expect(result == .success);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var machine: Machine = .{
        .arena = arena.allocator(),
        .runtime = .init(.{ .arena = arena.allocator(), .objects = testing.allocator }),
        .program = &result.success,
        .max_depth = 256,
        .host = null,
    };
    defer machine.runtime.deinit();
    const outcome = try machine.execute(result.success.entry_function);
    try testing.expect(outcome == .value);
    try testing.expectEqual(@as(usize, 0), machine.frame_storage.items.len);
    try testing.expect(machine.frame_storage.capacity < 4096);
    // A struct local that owns its field run starts *empty* rather
    // than at the shared zero template, because the release it is
    // going to get must never hand a shared run back
    // (docs/STRINGS.md) — and an empty slot costs no allocation at
    // all, which is what the template was there to avoid.  So a
    // hundred thousand calls through `nudge` never build one.
    try testing.expectEqual(@as(usize, 0), machine.struct_zeros.len);
}

test "the explicit frame stack survives deep recursion" {
    var result = try compile_mod.compile(testing.allocator,
        \\func dive(left: Int) -> Int:
        \\    if left == 0:
        \\        return 0
        \\    return dive(left - 1)
        \\
        \\func main():
        \\    assert(dive(50000) == 0)
        \\
    , script_options);
    defer result.deinit();
    try testing.expect(result == .success);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const deep = try backend.evaluate(.{ .arena = arena.allocator(), .objects = testing.allocator }, &result.success, .{
        .call_depth = 60_000,
    });
    try testing.expect(deep == .success);

    _ = arena.reset(.retain_capacity);
    const shallow = try backend.evaluate(.{ .arena = arena.allocator(), .objects = testing.allocator }, &result.success, .{
        .call_depth = 1_000,
    });
    try testing.expectEqual(mir.TrapCode.call_depth_exceeded, shallow.trap.code);
}

test "string methods: search, case, trim, replace, repeat, split" {
    var bench = try Bench.setup(
        \\import std.strings
        \\
        \\func main():
        \\    let text = "  Hello, Luce World  "
        \\    let cleaned = text.trim()
        \\    assert(cleaned == "Hello, Luce World")
        \\    assert(cleaned.find("Luce") == 7)
        \\    assert(cleaned.find("zig") == -1)
        \\    assert(cleaned.contains("World"))
        \\    assert(cleaned.starts_with("Hello"))
        \\    assert(cleaned.ends_with("World"))
        \\    assert(cleaned.lower() == "hello, luce world")
        \\    assert(cleaned.upper() == "HELLO, LUCE WORLD")
        \\    assert(cleaned.replace("Luce", "brave") == "Hello, brave World")
        \\    assert("ab".repeat(3) == "ababab")
        \\    assert("x".repeat(0) == "")
        \\    assert("na".byte_at(0) == 110)
        \\    var words = cleaned.replace(",", "").split("")
        \\    assert(len(words) == 3)
        \\    assert(words[0] == "Hello")
        \\    var csv = "a;b;;c".split(";")
        \\    assert(len(csv) == 4)
        \\    assert(csv[2] == "")
        \\    assert(csv.join("|") == "a|b||c")
        \\    free(words)
        \\    free(csv)
        \\
    , script_options);
    defer bench.deinit();
    try expectLeaks(&bench, 0);
}

test "list and array methods: sort, reverse, find, contains, fill, clear" {
    var bench = try Bench.setup(
        \\import std.strings
        \\
        \\func main():
        \\    var xs = [3, 1, 4, 1, 5]
        \\    xs.sort()
        \\    assert(xs[0] == 1)
        \\    assert(xs[4] == 5)
        \\    xs.reverse()
        \\    assert(xs[0] == 5)
        \\    assert(xs.find(4) == 1)
        \\    assert(xs.find(9) == -1)
        \\    assert(xs.contains(3))
        \\    assert(not xs.contains(9))
        \\    xs.clear()
        \\    assert(len(xs) == 0)
        \\    var names = ["cyan", "amber"]
        \\    names.sort()
        \\    assert(names[0] == "amber")
        \\    var row = new Array(Int, 4)
        \\    row.fill(7)
        \\    assert(row[3] == 7)
        \\    assert(row.contains(7))
        \\    row[1] = 2
        \\    row.sort()
        \\    assert(row[0] == 2)
        \\    var ages = new Map(String, Int)
        \\    ages["ada"] = 36
        \\    ages["alan"] = 41
        \\    var listed = ages.keys()
        \\    assert(listed.join(",") == "ada,alan")
        \\    ages.clear()
        \\    assert(len(ages) == 0)
        \\    free(xs)
        \\    free(names)
        \\    free(row)
        \\    free(ages)
        \\    free(listed)
        \\
    , script_options);
    defer bench.deinit();
    try expectLeaks(&bench, 0);
}

// ---------------------------------------------------------------------------
// Trap locations and traces
// ---------------------------------------------------------------------------

test "a trap reports its statement's line and the full call trace" {
    var bench = try Bench.setup(
        \\func divide(a: Int, b: Int) -> Int:
        \\    return a / b
        \\
        \\func ratio(n: Int) -> Int:
        \\    return divide(100, n)
        \\
        \\func main():
        \\    let x = ratio(0)
        \\
    , script_options);
    defer bench.deinit();

    const result = try bench.evaluate();
    try testing.expect(result == .trap);
    const trap = result.trap;
    try testing.expectEqual(mir.TrapCode.divide_by_zero, trap.code);
    try testing.expectEqual(@as(usize, 3), trap.trace.len);
    try testing.expectEqual(@as(u32, 0), trap.dropped);

    try testing.expectEqualStrings("divide", trap.trace[0].function);
    try testing.expectEqualStrings("main.luc", trap.trace[0].source);
    try testing.expectEqual(@as(u32, 2), trap.trace[0].line);
    try testing.expectEqual(@as(u32, 5), trap.trace[0].column);

    try testing.expectEqualStrings("ratio", trap.trace[1].function);
    try testing.expectEqual(@as(u32, 5), trap.trace[1].line);

    try testing.expectEqualStrings("main", trap.trace[2].function);
    try testing.expectEqual(@as(u32, 8), trap.trace[2].line);
}

test "a stripped program still names its trap frames, without lines" {
    var bench = try Bench.setup(
        \\func boom() -> Int:
        \\    return 1 / 0
        \\
        \\func main():
        \\    let x = boom()
        \\
    , script_options);
    defer bench.deinit();
    mir.strip(&bench.program);

    const result = try bench.evaluate();
    try testing.expect(result == .trap);
    const trap = result.trap;
    try testing.expectEqual(@as(usize, 2), trap.trace.len);
    try testing.expectEqualStrings("boom", trap.trace[0].function);
    try testing.expectEqualStrings("", trap.trace[0].source);
    try testing.expectEqual(@as(u32, 0), trap.trace[0].line);
    try testing.expectEqual(@as(u32, 0), trap.trace[0].column);
}

test "a trap inside std code points into the std module" {
    var bench = try Bench.setup(
        \\import std.strings
        \\
        \\func main():
        \\    var decimals = -1
        \\    let bad = strings.format_float(1.0, decimals)
        \\
    , script_options);
    defer bench.deinit();

    const result = try bench.evaluate();
    try testing.expect(result == .trap);
    const trap = result.trap;
    try testing.expectEqual(mir.TrapCode.explicit_trap, trap.code);
    try testing.expect(trap.trace.len == 2);
    try testing.expectEqualStrings("strings.format_float", trap.trace[0].function);
    try testing.expectEqualStrings("std/strings.luc", trap.trace[0].source);
    try testing.expect(trap.trace[0].line != 0);
    try testing.expectEqualStrings("main", trap.trace[1].function);
    try testing.expectEqualStrings("main.luc", trap.trace[1].source);
    try testing.expectEqual(@as(u32, 5), trap.trace[1].line);
}

test "a runaway recursion reports a capped trace and counts the rest" {
    var bench = try Bench.setup(
        \\func spiral(n: Int) -> Int:
        \\    return spiral(n + 1)
        \\
        \\func main():
        \\    let x = spiral(0)
        \\
    , script_options);
    defer bench.deinit();

    const result = try backend.evaluate(
        .{ .arena = bench.arena.allocator(), .objects = testing.allocator },
        &bench.program,
        .{ .call_depth = 100 },
    );
    try testing.expect(result == .trap);
    const trap = result.trap;
    try testing.expectEqual(mir.TrapCode.call_depth_exceeded, trap.code);
    try testing.expectEqual(@as(usize, max_trace_frames), trap.trace.len);
    try testing.expectEqual(@as(u32, 100 - max_trace_frames), trap.dropped);
    try testing.expectEqualStrings("spiral", trap.trace[0].function);
    try testing.expectEqual(@as(u32, 2), trap.trace[0].line);
}
