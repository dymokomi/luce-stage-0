//! The loom shell: a small colored line terminal over the runner.
//!
//! Commands launch Luce programs; everything durable belongs to the
//! programs and the filesystem, not to the shell.  The editor is a
//! Luce program too — its source ships inside the loom binary (see
//! build.zig), and LOOM_EDITOR overrides it with a .luc file on disk.

const std = @import("std");
const runner = @import("runner.zig");
const palette_mod = @import("palette.zig");

const Allocator = std.mem.Allocator;

const embedded_editor = @embedFile("editor.luc");

pub const Shell = struct {
    gpa: Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    palette: palette_mod.Palette,
    editor_override: ?[]const u8,
    /// Which engine programs launched from here run on (runner.zig).
    policy: runner.Policy = .{},

    pub fn run(self: *Shell, reader: *std.Io.Reader, interactive: bool) !u8 {
        if (interactive) try self.banner();
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
                    return 1;
                },
                error.ReadFailed => return 0,
            } orelse {
                if (interactive) try self.out.print("\n", .{});
                try self.out.flush();
                return 0;
            };
            if (!try self.dispatch(line)) {
                try self.out.flush();
                return 0;
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

    /// One line in; false means exit.
    fn dispatch(self: *Shell, line: []const u8) !bool {
        var words: [max_words][]const u8 = undefined;
        const count = split(line, &words);
        if (count == 0) return true;
        if (count == max_words) {
            try self.err.print("loom: too many arguments\n", .{});
            return true;
        }
        const command = words[0];
        const rest = words[1..count];

        if (std.mem.eql(u8, command, "exit") or std.mem.eql(u8, command, "quit")) return false;
        if (std.mem.eql(u8, command, "help")) {
            try self.help();
            return true;
        }
        if (std.mem.eql(u8, command, "clear")) {
            if (self.palette.enabled) try self.out.writeAll("\x1b[2J\x1b[H");
            return true;
        }
        if (std.mem.eql(u8, command, "run")) {
            if (rest.len == 0) return self.complain("run PROGRAM.lc [ARGS]");
            _ = try runner.runModule(self.gpa, self.io, self.out, self.err, rest[0], rest[1..]);
            return true;
        }
        if (std.mem.eql(u8, command, "luce")) {
            if (rest.len == 0) return self.complain("luce PROGRAM.luc [ARGS]");
            _ = try runner.runScript(self.gpa, self.io, self.out, self.err, self.policy, rest[0], rest[1..]);
            return true;
        }
        if (std.mem.eql(u8, command, "edit")) {
            if (rest.len != 1) return self.complain("edit FILE");
            _ = try self.edit(rest[0]);
            return true;
        }

        // A bare program path runs directly: hello.lc, tools/fmt.luc 2 3.
        if (std.mem.endsWith(u8, command, ".lc")) {
            _ = try runner.runModule(self.gpa, self.io, self.out, self.err, command, rest);
            return true;
        }
        if (std.mem.endsWith(u8, command, ".luc")) {
            _ = try runner.runScript(self.gpa, self.io, self.out, self.err, self.policy, command, rest);
            return true;
        }

        try self.err.print("loom: unknown command {s}{s}{s} (try {s}help{s})\n", .{
            self.palette.sgr(.bold),
            command,
            self.palette.sgr(.reset),
            self.palette.sgr(.prompt),
            self.palette.sgr(.reset),
        });
        return true;
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

    fn complain(self: *Shell, wanted: []const u8) !bool {
        try self.err.print("loom: usage: {s}\n", .{wanted});
        return true;
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
