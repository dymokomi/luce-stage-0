//! The loom shell: a small colored line terminal over the runner.
//!
//! Commands launch Luce programs; everything durable belongs to the
//! programs and the filesystem, not to the shell.  The editor is an
//! ordinary installed program — `examples/editor/editor.lc`, run like
//! any other (owner, 2026-08-12: loom does not carry one).
//!
//! ## Interactive and not are different about failure
//!
//! A person at a prompt has already been told a program failed — the
//! trap is on their screen — and wants the prompt back, so the shell
//! exits 0 when they leave it.  A *script* piped into loom has nobody
//! watching: `echo "run boom.lc" | loom` in a build is the only thing
//! that will ever know, so the worst status any line produced becomes
//! loom's own (`apps/host.zig` names the numbers).

const std = @import("std");
const runner = @import("runner.zig");
const palette_mod = @import("palette");
const report = @import("report");

const Allocator = std.mem.Allocator;

pub const Shell = struct {
    gpa: Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    palette: palette_mod.Palette,
    /// Where a program launched from here gets compiled (runner.zig).
    policy: runner.Policy = .{},

    pub fn run(self: *Shell, reader: *std.Io.Reader, interactive: bool) !u8 {
        if (interactive) try self.banner();
        // The worst thing any line did, which a non-interactive loom
        // returns as its own status.  An interactive one always
        // returns 0: the person saw every failure as it happened.
        var worst: u8 = report.exit_ok;
        while (true) {
            if (interactive) {
                try self.out.print("{s}loom{s} \u{25b8} ", .{
                    self.palette.sgr(.prompt),
                    self.palette.sgr(.reset),
                });
            }
            try self.out.flush();
            const line = reader.takeDelimiter('\n') catch |mistake| switch (mistake) {
                error.StreamTooLong => {
                    try self.err.print("loom: line too long\n", .{});
                    return report.exit_trapped;
                },
                // Not end of input — that arrives as null below — but
                // a real failure to read.  A script whose remaining
                // commands were never seen has not succeeded, whatever
                // the ones before it did.
                error.ReadFailed => {
                    if (interactive) return report.exit_ok;
                    try self.err.print("loom: cannot read further input\n", .{});
                    return report.exit_broken;
                },
            } orelse {
                if (interactive) try self.out.print("\n", .{});
                try self.out.flush();
                return if (interactive) report.exit_ok else worst;
            };
            const outcome = try self.dispatch(line);
            if (outcome.status > worst) worst = outcome.status;
            if (!outcome.keep_going) {
                try self.out.flush();
                return if (interactive) report.exit_ok else worst;
            }
        }
    }

    fn banner(self: *Shell) !void {
        try self.out.print("{s}loom{s} — the luce environment. {s}help{s} lists commands.\n", .{
            self.palette.sgr(.bold),
            self.palette.sgr(.reset),
            self.palette.sgr(.prompt),
            self.palette.sgr(.reset),
        });
    }

    /// What one line did: whether the shell keeps reading, and the
    /// status it would have exited with had it been the only line.
    const Outcome = struct {
        keep_going: bool = true,
        status: u8 = report.exit_ok,
    };

    /// One line in.
    fn dispatch(self: *Shell, line: []const u8) !Outcome {
        var words: [max_words][]const u8 = undefined;
        const count = split(line, &words);
        if (count == 0) return .{};
        if (count == max_words) {
            try self.err.print("loom: too many arguments\n", .{});
            return .{ .status = report.exit_trapped };
        }
        const command = words[0];
        const rest = words[1..count];

        if (std.mem.eql(u8, command, "exit") or std.mem.eql(u8, command, "quit")) {
            return .{ .keep_going = false };
        }
        if (std.mem.eql(u8, command, "help")) {
            try self.help();
            return .{};
        }
        if (std.mem.eql(u8, command, "clear")) {
            if (self.palette.enabled) try self.out.writeAll("\x1b[2J\x1b[H");
            return .{};
        }
        if (std.mem.eql(u8, command, "run")) {
            if (rest.len == 0) return self.complain("run PROGRAM.lc [ARGS]");
            return .{ .status = try runner.runModule(
                self.gpa,
                self.io,
                self.out,
                self.err,
                rest[0],
                rest[1..],
            ) };
        }
        if (std.mem.eql(u8, command, "luce")) {
            if (rest.len == 0) return self.complain("luce PROGRAM.luc [ARGS]");
            return .{ .status = try runner.runScript(
                self.gpa,
                self.io,
                self.out,
                self.err,
                self.policy,
                rest[0],
                rest[1..],
            ) };
        }
        // A bare program path runs directly: hello.lc, tools/fmt.luc 2 3.
        if (std.mem.endsWith(u8, command, ".lc")) {
            return .{ .status = try runner.runModule(
                self.gpa,
                self.io,
                self.out,
                self.err,
                command,
                rest,
            ) };
        }
        if (std.mem.endsWith(u8, command, ".luc")) {
            return .{ .status = try runner.runScript(
                self.gpa,
                self.io,
                self.out,
                self.err,
                self.policy,
                command,
                rest,
            ) };
        }

        try self.err.print("loom: unknown command {s}{s}{s} (try {s}help{s})\n", .{
            self.palette.sgr(.bold),
            command,
            self.palette.sgr(.reset),
            self.palette.sgr(.prompt),
            self.palette.sgr(.reset),
        });
        return .{ .status = report.exit_trapped };
    }

    fn help(self: *Shell) !void {
        const accent = self.palette.sgr(.prompt);
        const dim = self.palette.sgr(.dim);
        const reset = self.palette.sgr(.reset);
        try self.out.print(
            "  {s}run{s} PROGRAM.lc [ARGS]   {s}run a compiled Luce program{s}\n" ++
                "  {s}luce{s} PROGRAM.luc [ARGS] {s}compile and run a Luce source file{s}\n" ++
                "  {s}clear{s}                  {s}clear the screen{s}\n" ++
                "  {s}exit{s}                   {s}leave loom{s}\n" ++
                "  {s}a bare PROGRAM.lc or .luc path runs it directly{s}\n",
            .{
                accent, reset, dim, reset,
                accent, reset, dim, reset,
                accent, reset, dim, reset,
                accent, reset, dim, reset,
                dim,    reset,
            },
        );
    }

    fn complain(self: *Shell, wanted: []const u8) !Outcome {
        try self.err.print("loom: usage: {s}\n", .{wanted});
        return .{ .status = report.exit_trapped };
    }
};

const max_words = 17;

/// Split on spaces and tabs; returns the word count, capped at the
/// buffer size (a full buffer signals "too many").
fn split(line: []const u8, words: *[max_words][]const u8) usize {
    var count: usize = 0;
    var iterator = std.mem.tokenizeAny(u8, line, " \t\r");
    while (iterator.next()) |word| {
        if (count == max_words) return count;
        words[count] = word;
        count += 1;
    }
    return count;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "lines split into command words" {
    var words: [max_words][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 0), split("   ", &words));
    try testing.expectEqual(@as(usize, 3), split("run editor.lc notes.txt", &words));
    try testing.expectEqualStrings("run", words[0]);
    try testing.expectEqualStrings("notes.txt", words[2]);
}

/// A shell reading a script, with both channels captured.
fn scripted(text: []const u8, out: *std.Io.Writer.Allocating, err: *std.Io.Writer.Allocating) !u8 {
    var reader: std.Io.Reader = .fixed(text);
    var shell: Shell = .{
        .gpa = testing.allocator,
        .io = testing.io,
        .out = &out.writer,
        .err = &err.writer,
        .palette = .{ .enabled = false },
    };
    return shell.run(&reader, false);
}

test "a non-interactive loom exits with the worst status any line produced" {
    // A script piped into loom is usually a build step, and a build
    // step that swallowed a failure is worse than no build step: for
    // as long as this was `_ = try runner.runModule(...)`, `echo "run
    // boom.lc" | loom` exited 0 on a program that never ran at all.
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(testing.allocator);
    defer err.deinit();

    // Lines that all succeed say so.
    try testing.expectEqual(@as(u8, 0), try scripted("help\nclear\nexit\n", &out, &err));

    // One that does not is the answer, even with good lines after it
    // and even though the shell keeps going — a shell is not a `set
    // -e` script, but it does remember.
    out.clearRetainingCapacity();
    err.clearRetainingCapacity();
    const status = try scripted("help\nrun no/such/program.lc\nhelp\n", &out, &err);
    try testing.expectEqual(@as(u8, 1), status);
    try testing.expect(std.mem.indexOf(u8, err.written(), "no such file") != null);

    // An unrecognised command counts too: a typo in a script is a
    // command that did not run.
    out.clearRetainingCapacity();
    err.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 1), try scripted("rnu hello.lc\n", &out, &err));

    // And `exit` in the middle does not wipe what came before it.
    out.clearRetainingCapacity();
    err.clearRetainingCapacity();
    try testing.expectEqual(
        @as(u8, 1),
        try scripted("run no/such/program.lc\nexit\n", &out, &err),
    );
}

/// One line, put through `dispatch` with both channels captured.
///
/// Every command the shell has goes through that one function, and
/// until this existed nothing had ever called it: the two tests above
/// reach it through `run`, which can only see the status a whole
/// script ended with.  What a *line* did — whether the shell keeps
/// reading, what it printed, what it printed it on — is what a person
/// at a prompt actually meets.
const Dispatched = struct {
    outcome: Shell.Outcome,
    out: std.Io.Writer.Allocating,
    err: std.Io.Writer.Allocating,

    fn of(self: *Dispatched, line: []const u8, colored: bool) !void {
        self.out = .init(testing.allocator);
        errdefer self.out.deinit();
        self.err = .init(testing.allocator);
        errdefer self.err.deinit();
        var shell: Shell = .{
            .gpa = testing.allocator,
            .io = testing.io,
            .out = &self.out.writer,
            .err = &self.err.writer,
            .palette = .{ .enabled = colored },
        };
        self.outcome = try shell.dispatch(line);
    }

    fn deinit(self: *Dispatched) void {
        self.out.deinit();
        self.err.deinit();
    }
};

/// A line that should be accepted, keep the shell reading, and say
/// nothing on standard error.
fn expectQuiet(line: []const u8) !void {
    var ran: Dispatched = undefined;
    try ran.of(line, false);
    defer ran.deinit();
    try testing.expect(ran.outcome.keep_going);
    try testing.expectEqual(@as(u8, report.exit_ok), ran.outcome.status);
    try testing.expectEqualStrings("", ran.err.written());
}

/// A line the shell refuses: it keeps reading, says something on
/// standard error, and scores the line as failed.
fn expectRejected(line: []const u8, mentioning: []const u8) !void {
    var ran: Dispatched = undefined;
    try ran.of(line, false);
    defer ran.deinit();
    try testing.expect(ran.outcome.keep_going);
    try testing.expectEqual(@as(u8, report.exit_trapped), ran.outcome.status);
    try testing.expect(std.mem.indexOf(u8, ran.err.written(), mentioning) != null);
    // A refusal is a refusal wherever it is read: nothing about it
    // goes to the program's own channel.
    try testing.expectEqualStrings("", ran.out.written());
}

test "a blank line is not a command, and too many words is not one either" {
    try expectQuiet("");
    try expectQuiet("   ");
    try expectQuiet("\t \r");

    // The word buffer is a fixed size, and a line that filled it may
    // have had more words after it — running the part that fits would
    // be running a different command from the one that was typed.
    const gpa = testing.allocator;
    var crowded: std.ArrayList(u8) = .empty;
    defer crowded.deinit(gpa);
    try crowded.appendSlice(gpa, "run x.lc");
    for (0..max_words) |index| try crowded.print(gpa, " a{d}", .{index});
    try expectRejected(crowded.items, "too many arguments");
}

test "leaving is spelled two ways and both stop the shell without a word" {
    for ([_][]const u8{ "exit", "quit" }) |word| {
        var ran: Dispatched = undefined;
        try ran.of(word, false);
        defer ran.deinit();
        try testing.expect(!ran.outcome.keep_going);
        try testing.expectEqual(@as(u8, report.exit_ok), ran.outcome.status);
        try testing.expectEqualStrings("", ran.err.written());
        try testing.expectEqualStrings("", ran.out.written());
    }
    // Arguments after it are not an error: `exit 0` is what a hand
    // types, and there is nothing for the number to mean here.
    var with_argument: Dispatched = undefined;
    try with_argument.of("exit 0", false);
    defer with_argument.deinit();
    try testing.expect(!with_argument.outcome.keep_going);
}

test "help names every command the shell has" {
    var ran: Dispatched = undefined;
    try ran.of("help", false);
    defer ran.deinit();
    try testing.expect(ran.outcome.keep_going);
    try testing.expectEqualStrings("", ran.err.written());
    // Help that does not list a command is help that hides one.
    for ([_][]const u8{ "run", "luce", "clear", "exit" }) |command| {
        try testing.expect(std.mem.indexOf(u8, ran.out.written(), command) != null);
    }
}

test "clear writes the escape sequence only where escapes are read" {
    var colored: Dispatched = undefined;
    try colored.of("clear", true);
    defer colored.deinit();
    try testing.expectEqualStrings("\x1b[2J\x1b[H", colored.out.written());

    // Not a terminal, or NO_COLOR: the same rule the palette follows,
    // because a `clear` in a piped script would otherwise put an
    // escape sequence in somebody's log file.
    var plain: Dispatched = undefined;
    try plain.of("clear", false);
    defer plain.deinit();
    try testing.expectEqualStrings("", plain.out.written());
}

test "every command that takes a file says so when it is given none" {
    try expectRejected("run", "run PROGRAM.lc [ARGS]");
    try expectRejected("luce", "luce PROGRAM.luc [ARGS]");
}

test "a command nobody has is named back, and counts as a line that failed" {
    var ran: Dispatched = undefined;
    try ran.of("rnu hello.lc", false);
    defer ran.deinit();
    try testing.expect(ran.outcome.keep_going);
    try testing.expectEqual(@as(u8, report.exit_trapped), ran.outcome.status);
    // The word that was typed, so a typo is visible as a typo, and the
    // one command that lists the rest.
    try testing.expect(std.mem.indexOf(u8, ran.err.written(), "rnu") != null);
    try testing.expect(std.mem.indexOf(u8, ran.err.written(), "help") != null);
}

test "a bare path runs, and reaches the same refusals the named commands do" {
    // The sugar: `hello.lc` is `run hello.lc` and `tools/fmt.luc` is
    // `luce tools/fmt.luc`.  Neither file is there, so what is proved
    // is that the line reached the runner at all — a bare path that
    // fell through to "unknown command" would say something else.
    for ([_][]const u8{ "no/such/program.lc", "run no/such/program.lc" }) |line| {
        try expectRejected(line, "no such file");
    }
    for ([_][]const u8{ "no/such/program.luc", "luce no/such/program.luc" }) |line| {
        try expectRejected(line, "no such file");
    }
    // Arguments after the path are the program's, not the shell's.
    try expectRejected("no/such/program.lc alpha beta", "no such file");
}

test "an interactive loom always leaves cleanly" {
    // The other half of the rule: a person at a prompt has already
    // been shown every failure, and a shell that exited nonzero
    // because of something they typed an hour ago would be reporting
    // on them rather than on a program.
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(testing.allocator);
    defer err.deinit();

    var reader: std.Io.Reader = .fixed("run no/such/program.lc\nexit\n");
    var shell: Shell = .{
        .gpa = testing.allocator,
        .io = testing.io,
        .out = &out.writer,
        .err = &err.writer,
        .palette = .{ .enabled = false },
    };
    try testing.expectEqual(@as(u8, 0), try shell.run(&reader, true));
}
