//! The loom shell: a small colored line terminal over the runner.
//!
//! Commands launch Luce programs; everything durable belongs to the
//! programs and the filesystem, not to the shell.  The editor is a
//! Luce program too — its source ships inside the loom binary (see
//! build.zig), and LOOM_EDITOR overrides it with a .luc file on disk.
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
const palette_mod = @import("palette.zig");
const host_mod = @import("host");

const Allocator = std.mem.Allocator;

const embedded_editor = @embedFile("editor.luc");

pub const Shell = struct {
    gpa: Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    palette: palette_mod.Palette,
    editor_override: ?[]const u8,
    /// Where a program launched from here gets compiled (runner.zig).
    policy: runner.Policy = .{},

    pub fn run(self: *Shell, reader: *std.Io.Reader, interactive: bool) !u8 {
        if (interactive) try self.banner();
        // The worst thing any line did, which a non-interactive loom
        // returns as its own status.  An interactive one always
        // returns 0: the person saw every failure as it happened.
        var worst: u8 = host_mod.exit_ok;
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
                    return host_mod.exit_trapped;
                },
                // Not end of input — that arrives as null below — but
                // a real failure to read.  A script whose remaining
                // commands were never seen has not succeeded, whatever
                // the ones before it did.
                error.ReadFailed => {
                    if (interactive) return host_mod.exit_ok;
                    try self.err.print("loom: cannot read further input\n", .{});
                    return host_mod.exit_broken;
                },
            } orelse {
                if (interactive) try self.out.print("\n", .{});
                try self.out.flush();
                return if (interactive) host_mod.exit_ok else worst;
            };
            const outcome = try self.dispatch(line);
            if (outcome.status > worst) worst = outcome.status;
            if (!outcome.keep_going) {
                try self.out.flush();
                return if (interactive) host_mod.exit_ok else worst;
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
        status: u8 = host_mod.exit_ok,
    };

    /// One line in.
    fn dispatch(self: *Shell, line: []const u8) !Outcome {
        var words: [max_words][]const u8 = undefined;
        const count = split(line, &words);
        if (count == 0) return .{};
        if (count == max_words) {
            try self.err.print("loom: too many arguments\n", .{});
            return .{ .status = host_mod.exit_trapped };
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
        if (std.mem.eql(u8, command, "edit")) {
            if (rest.len != 1) return self.complain("edit FILE");
            return .{ .status = try self.edit(rest[0]) };
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
        return .{ .status = host_mod.exit_trapped };
    }

    /// Run the editor on one file: the LOOM_EDITOR script when set,
    /// the embedded editor otherwise.
    pub fn edit(self: *Shell, path: []const u8) !u8 {
        const arguments = [_][]const u8{path};
        if (self.editor_override) |editor_path| {
            return runner.runScript(self.gpa, self.io, self.out, self.err, self.policy, editor_path, &arguments);
        }
        return runner.runSource(
            self.gpa,
            self.io,
            self.out,
            self.err,
            self.policy,
            "editor",
            embedded_editor,
            null,
            &arguments,
        );
    }

    fn help(self: *Shell) !void {
        const accent = self.palette.sgr(.prompt);
        const dim = self.palette.sgr(.dim);
        const reset = self.palette.sgr(.reset);
        try self.out.print(
            "  {s}run{s} PROGRAM.lc [ARGS]   {s}run a compiled Luce program{s}\n" ++
                "  {s}luce{s} PROGRAM.luc [ARGS] {s}compile and run a Luce source file{s}\n" ++
                "  {s}edit{s} FILE              {s}open the Luce editor (LOOM_EDITOR overrides){s}\n" ++
                "  {s}clear{s}                  {s}clear the screen{s}\n" ++
                "  {s}exit{s}                   {s}leave loom{s}\n" ++
                "  {s}a bare PROGRAM.lc or .luc path runs it directly{s}\n",
            .{
                accent, reset, dim, reset,
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
        return .{ .status = host_mod.exit_trapped };
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
        .editor_override = null,
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
        .editor_override = null,
    };
    try testing.expectEqual(@as(u8, 0), try shell.run(&reader, true));
}

test "the embedded editor source compiles as a hosted script" {
    var result = try @import("luce").compile.compile(
        testing.allocator,
        embedded_editor,
        runner.compile_options,
    );
    defer result.deinit();
    switch (result) {
        .success => {},
        .failure => |*diagnostics| {
            const rendered = try diagnostics.render(testing.allocator);
            defer testing.allocator.free(rendered);
            std.debug.print("editor diagnostics:\n{s}", .{rendered});
            return error.TestUnexpectedResult;
        },
    }
}
