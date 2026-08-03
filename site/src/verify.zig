//! Every Luce sample on the site is compiled and run, and the output
//! printed on the page is the output the program actually produced.
//!
//! A fenced block whose info string starts with `luce` must say what
//! is to become of it.  There is no unverified Luce on this site, by
//! construction: a bare ```luce fence is a build error naming the page
//! and the line.
//!
//!   ```luce run              a whole program; must compile and exit 0
//!   ```luce trap             must compile and then trap
//!   ```luce raise            must compile and then end on an uncaught error
//!   ```luce fail             must be refused by `luce check`
//!   ```luce module file=x.luc   a second file for the next program
//!   ```console               a shell transcript; `$ ` lines are run
//!
//! Attributes: `file=NAME.luc` names the file written (default
//! `main.luc`), `include=PATH` shows a file from the repository
//! instead of the fence body, and `args=...` takes the rest of the
//! info string as the program's arguments — split on spaces, with
//! `"..."` holding one argument together.
//!
//! Each of the first three requires an immediately following
//! ```output fence, and the build fails unless it matches byte for
//! byte.  That is the whole point: the page cannot claim an output the
//! program does not produce.
//!
//! **Both engines run every program.**  The native arm runs under
//! `LOOM_ENGINE=native`, so a silent fall back to the interpreter is an
//! error rather than a pass; the reference arm runs under
//! `LOOM_ENGINE=interpreter`.  The two must agree, which is the same
//! claim `docs/MODES.md` makes about the language and is worth
//! re-proving on every page.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("buffer.zig");
const markdown = @import("markdown.zig");
const highlight = @import("highlight.zig");

const Io = std.Io;

pub const Mode = enum { run, trap, raise, fail, module, console };

/// A sample that failed to do what its page says it does.
pub const Failure = struct {
    page: []const u8,
    line: usize,
    reason: []const u8,

    pub fn deinit(self: *const Failure, gpa: Allocator) void {
        gpa.free(self.page);
        gpa.free(self.reason);
    }
};

pub const Counts = struct {
    run: usize = 0,
    trap: usize = 0,
    raise: usize = 0,
    fail: usize = 0,
    console: usize = 0,

    pub fn total(self: Counts) usize {
        return self.run + self.trap + self.raise + self.fail + self.console;
    }
};

const File = struct { name: []const u8, source: []const u8 };

pub const Verifier = struct {
    gpa: Allocator,
    io: Io,
    /// Absolute path of the directory holding `luce` and `loom`.
    toolchain: []const u8,
    /// Absolute path of a scratch directory; one subdirectory per sample.
    work: []const u8,
    /// The repository root, which `include=` paths are relative to.
    repository: []const u8,
    /// Set while a page renders, for failure messages.
    page: []const u8 = "",

    counts: Counts = .{},
    failures: std.ArrayList(Failure) = .empty,
    /// `module` blocks waiting for the program that uses them.
    pending: std.ArrayList(File) = .empty,
    /// The directory the last `console` block ran in.  A second
    /// transcript on the same page with no new files of its own
    /// continues that session, which is what a reader assumes.
    session: ?[]u8 = null,
    sample: usize = 0,

    pub fn deinit(self: *Verifier) void {
        for (self.failures.items) |failure| failure.deinit(self.gpa);
        self.failures.deinit(self.gpa);
        self.clearPending();
        self.pending.deinit(self.gpa);
        self.endSession();
    }

    /// Called between pages: nothing carries over.
    pub fn startPage(self: *Verifier, path: []const u8) void {
        self.page = path;
        self.clearPending();
        self.endSession();
    }

    fn endSession(self: *Verifier) void {
        if (self.session) |directory| self.gpa.free(directory);
        self.session = null;
    }

    fn clearPending(self: *Verifier) void {
        for (self.pending.items) |file| {
            self.gpa.free(file.name);
            self.gpa.free(file.source);
        }
        self.pending.clearRetainingCapacity();
    }

    pub fn sink(self: *Verifier) markdown.Sink {
        return .{ .context = self, .render = renderFence };
    }

    fn note(self: *Verifier, line: usize, comptime format: []const u8, arguments: anytype) !void {
        try self.failures.append(self.gpa, .{
            .page = try self.gpa.dupe(u8, self.page),
            .line = line,
            .reason = try std.fmt.allocPrint(self.gpa, format, arguments),
        });
    }
};

// ---------------------------------------------------------------------------
// The fence sink
// ---------------------------------------------------------------------------

fn renderFence(
    context: *anyopaque,
    out: *Buffer,
    primary: markdown.Fence,
    follower: ?markdown.Fence,
    took_follower: *bool,
) anyerror!void {
    const self: *Verifier = @ptrCast(@alignCast(context));
    var words = std.mem.tokenizeScalar(u8, primary.info, ' ');
    const language = words.next() orelse "";

    if (std.mem.eql(u8, language, "console")) {
        return console(self, out, primary, follower, took_follower);
    }
    if (!std.mem.eql(u8, language, "luce")) {
        // Plain, unclaimed text: shell snippets, IR dumps, diagnostics
        // quoted from the repository.  Rendered, never executed.
        try markdown.plainFence(out, primary);
        return;
    }

    const mode_word = words.next() orelse {
        try self.note(primary.line, "a ```luce fence must say run, trap, raise, fail or module", .{});
        try markdown.plainFence(out, primary);
        return;
    };
    const mode = std.meta.stringToEnum(Mode, mode_word) orelse {
        try self.note(primary.line, "unknown luce fence mode '{s}'", .{mode_word});
        try markdown.plainFence(out, primary);
        return;
    };

    var name: []const u8 = if (mode == .module) "" else "main.luc";
    var arguments: []const u8 = "";
    var include: []const u8 = "";
    while (words.next()) |word| {
        if (std.mem.startsWith(u8, word, "file=")) {
            name = word["file=".len..];
        } else if (std.mem.startsWith(u8, word, "include=")) {
            include = word["include=".len..];
        } else if (std.mem.startsWith(u8, word, "args=")) {
            // Arguments run to the end of the info string.
            arguments = std.mem.trim(u8, primary.info[words.index - word.len + "args=".len ..], " ");
            break;
        } else {
            try self.note(primary.line, "unknown attribute '{s}' on a luce fence", .{word});
        }
    }

    // `include=` shows a file that lives in the repository rather than
    // in the page.  The site then cannot drift from the corpus: change
    // `programs/sort.luc` and this page changes with it, or the build
    // stops.
    var source: []const u8 = primary.code;
    var owned: ?[]u8 = null;
    defer if (owned) |bytes| self.gpa.free(bytes);
    if (include.len != 0) {
        if (std.mem.trim(u8, primary.code, " \n").len != 0) {
            try self.note(primary.line, "an include= fence must have an empty body", .{});
        }
        const path = try std.fs.path.join(self.gpa, &.{ self.repository, include });
        defer self.gpa.free(path);
        owned = Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .unlimited) catch |failure| {
            try self.note(primary.line, "cannot include {s}: {s}", .{ include, @errorName(failure) });
            try markdown.plainFence(out, primary);
            return;
        };
        source = owned.?;
        if (name.len == 0 or std.mem.eql(u8, name, "main.luc")) name = std.fs.path.basename(include);
    }

    if (mode == .module) {
        if (name.len == 0) {
            try self.note(primary.line, "a ```luce module fence needs file=NAME.luc", .{});
        } else {
            try self.pending.append(self.gpa, .{
                .name = try self.gpa.dupe(u8, name),
                .source = try self.gpa.dupe(u8, source),
            });
        }
        try sourceFigure(out, name, source, null, null);
        return;
    }

    const expected = follower orelse {
        try self.note(primary.line, "a ```luce {s} fence needs a ```output fence after it", .{mode_word});
        try sourceFigure(out, name, source, null, null);
        return;
    };
    if (!std.mem.eql(u8, std.mem.trim(u8, expected.info, " "), "output")) {
        try self.note(primary.line, "the fence after a ```luce {s} block must be ```output", .{mode_word});
        try sourceFigure(out, name, source, null, null);
        return;
    }
    took_follower.* = true;

    const produced = try execute(self, mode, name, source, arguments, primary.line);
    defer self.gpa.free(produced);

    if (!sameOutput(produced, expected.code)) {
        try self.note(
            primary.line,
            "the page claims this output:\n--- claimed ---\n{s}\n--- produced ---\n{s}---------------",
            .{ expected.code, produced },
        );
    }

    switch (mode) {
        .run => self.counts.run += 1,
        .trap => self.counts.trap += 1,
        .raise => self.counts.raise += 1,
        .fail => self.counts.fail += 1,
        else => {},
    }

    const label: []const u8 = switch (mode) {
        .run => "Output",
        .trap => "Output — the program traps",
        .raise => "Output — the error reaches the top",
        .fail => "luce check — the program is refused",
        else => "Output",
    };
    const tone: []const u8 = if (mode == .run) "out" else "bad";

    // The page shows what ran, not what the author typed.
    try sourceFigure(out, name, source, label, .{ .text = produced, .tone = tone });
}

const Shown = struct { text: []const u8, tone: []const u8 };

fn sourceFigure(
    out: *Buffer,
    name: []const u8,
    source: []const u8,
    label: ?[]const u8,
    result: ?Shown,
) !void {
    try out.add("<figure class=\"sample\">\n");
    if (name.len != 0) {
        try out.add("<figcaption class=\"cap luc\"><cite>");
        try out.addEscaped(name);
        try out.add("</cite></figcaption>\n");
    }
    try out.add("<div class=\"code\"><button class=\"copy\" type=\"button\">copy</button><pre><code>");
    // Only Luce source gets Luce colours; a data file a sample needs
    // is shown as what it is.
    if (name.len == 0 or std.mem.endsWith(u8, name, ".luc")) {
        try highlight.render(out, std.mem.trimEnd(u8, source, "\n"));
    } else {
        try out.addEscaped(std.mem.trimEnd(u8, source, "\n"));
    }
    try out.add("</code></pre></div>\n");
    if (result) |shown| {
        try out.print("<figcaption class=\"cap {s}\">", .{shown.tone});
        try out.addEscaped(label orelse "Output");
        try out.add("</figcaption>\n");
        try out.print("<div class=\"code result {s}\"><pre><samp>", .{shown.tone});
        try out.addEscaped(std.mem.trimEnd(u8, shown.text, "\n"));
        try out.add("</samp></pre></div>\n");
    }
    try out.add("</figure>\n");
}

/// Trailing blank lines are not content; everything else is compared
/// byte for byte.
fn sameOutput(produced: []const u8, claimed: []const u8) bool {
    return std.mem.eql(
        u8,
        std.mem.trimEnd(u8, produced, "\n "),
        std.mem.trimEnd(u8, claimed, "\n "),
    );
}

// ---------------------------------------------------------------------------
// Running things
// ---------------------------------------------------------------------------

/// Build and run one sample.  Returns what the page should print —
/// which is what the toolchain actually said, always.
fn execute(
    self: *Verifier,
    mode: Mode,
    name: []const u8,
    source: []const u8,
    arguments: []const u8,
    line: usize,
) ![]u8 {
    const gpa = self.gpa;
    const directory = try makeSampleDirectory(self);
    defer gpa.free(directory);

    // Remember what the sample was given, so each engine can be handed
    // its own untouched copy: a program that writes a file must not see
    // what the other engine's run left behind.
    var inputs: std.ArrayList(File) = .empty;
    defer inputs.deinit(gpa);

    for (self.pending.items) |file| {
        try write(self, directory, file.name, file.source);
        try inputs.append(gpa, file);
    }
    try write(self, directory, name, source);
    try inputs.append(gpa, .{ .name = name, .source = source });

    const compiler = try std.fs.path.join(gpa, &.{ self.toolchain, "luce" });
    defer gpa.free(compiler);
    const terminal = try std.fs.path.join(gpa, &.{ self.toolchain, "loom" });
    defer gpa.free(terminal);

    if (mode == .fail) {
        const checked = try run(self, directory, &.{ compiler, "check", name });
        defer gpa.free(checked.stdout);
        defer gpa.free(checked.stderr);
        if (checked.status == 0) {
            try self.note(line, "this sample is marked `fail` but `luce check` accepted it", .{});
        }
        return combine(gpa, checked);
    }

    const built = try run(self, directory, &.{ compiler, "build", name, "-o", "sample.lc" });
    defer gpa.free(built.stdout);
    defer gpa.free(built.stderr);
    if (built.status != 0) {
        try self.note(line, "this sample does not compile:\n{s}{s}", .{ built.stdout, built.stderr });
        return combine(gpa, built);
    }

    const module_path = try pathIn(gpa, directory, "sample.lc");
    defer gpa.free(module_path);
    const module = try Io.Dir.cwd().readFileAlloc(self.io, module_path, gpa, .unlimited);
    defer gpa.free(module);

    const native_room = try stage(self, directory, "native", inputs.items, module);
    defer gpa.free(native_room);
    const reference_room = try stage(self, directory, "reference", inputs.items, module);
    defer gpa.free(reference_room);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "/usr/bin/env", "LOOM_ENGINE=native", terminal, "run", "sample.lc" });
    var words = splitArguments(arguments);
    while (words.next()) |argument| try argv.append(gpa, argument);

    const native = try run(self, native_room, argv.items);
    defer gpa.free(native.stdout);
    defer gpa.free(native.stderr);

    // The reference engine, on the same module and its own untouched
    // copy of the inputs, must say the same thing.
    argv.items[1] = "LOOM_ENGINE=interpreter";
    const reference = try run(self, reference_room, argv.items);
    defer gpa.free(reference.stdout);
    defer gpa.free(reference.stderr);

    const native_text = try combine(gpa, native);
    errdefer gpa.free(native_text);
    const reference_text = try combine(gpa, reference);
    defer gpa.free(reference_text);

    if (!std.mem.eql(u8, native_text, reference_text) or native.status != reference.status) {
        try self.note(
            line,
            "the two engines disagree:\n--- compiled ({d}) ---\n{s}--- interpreter ({d}) ---\n{s}",
            .{ native.status, native_text, reference.status, reference_text },
        );
    }

    switch (mode) {
        .run => if (native.status != 0) {
            try self.note(line, "this sample is marked `run` but exited {d}", .{native.status});
        },
        .trap, .raise => if (native.status == 0) {
            try self.note(line, "this sample is marked `{s}` but exited cleanly", .{@tagName(mode)});
        },
        else => {},
    }
    return native_text;
}

/// A `console` fence: `$ ` lines are commands, everything else is what
/// they are claimed to print.  The transcript on the page is rebuilt
/// from what the commands really printed.
fn console(
    self: *Verifier,
    out: *Buffer,
    primary: markdown.Fence,
    follower: ?markdown.Fence,
    took_follower: *bool,
) !void {
    _ = follower;
    _ = took_follower;
    const gpa = self.gpa;

    // A transcript with files of its own starts a new session; one
    // without continues where the last transcript on this page left
    // off, files and all.
    if (self.pending.items.len != 0 or self.session == null) {
        self.endSession();
        self.session = try makeSampleDirectory(self);
    }
    const directory = self.session.?;
    for (self.pending.items) |file| try write(self, directory, file.name, file.source);
    self.clearPending();

    var transcript: Buffer = .init(gpa);
    defer transcript.deinit();

    var claimed: Buffer = .init(gpa);
    defer claimed.deinit();

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, primary.code, "\n"), '\n');
    var ran: usize = 0;
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "$ ")) {
            try claimed.add(line);
            try claimed.addByte('\n');
            continue;
        }
        const command = line[2..];
        try transcript.print("$ {s}\n", .{command});
        try claimed.print("$ {s}\n", .{command});

        // The toolchain under test comes first on PATH, so `luce` and
        // `loom` in a transcript are the binaries just built.
        const script = try std.fmt.allocPrint(gpa, "PATH={s}:$PATH; {s}", .{ self.toolchain, command });
        defer gpa.free(script);
        const result = try run(self, directory, &.{ "/bin/sh", "-c", script });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try transcript.add(result.stdout);
        try transcript.add(result.stderr);
        ran += 1;
    }

    if (ran == 0) try self.note(primary.line, "a ```console fence has no `$ ` command lines", .{});
    if (!sameOutput(transcript.text(), claimed.text())) {
        try self.note(
            primary.line,
            "the page claims this transcript:\n--- claimed ---\n{s}--- produced ---\n{s}---------------",
            .{ claimed.text(), transcript.text() },
        );
    }
    self.counts.console += 1;

    try out.add("<figure class=\"sample\">\n");
    try out.add("<figcaption class=\"cap shell\">Shell</figcaption>\n");
    try out.add("<div class=\"code\"><pre><samp>");
    var shown = std.mem.splitScalar(u8, std.mem.trimEnd(u8, transcript.text(), "\n"), '\n');
    var first = true;
    while (shown.next()) |line| {
        if (!first) try out.addByte('\n');
        first = false;
        if (std.mem.startsWith(u8, line, "$ ")) {
            try out.add("<span class=\"prompt\">$</span> <kbd>");
            try out.addEscaped(line[2..]);
            try out.add("</kbd>");
        } else {
            try out.addEscaped(line);
        }
    }
    try out.add("</samp></pre></div>\n</figure>\n");
}

/// Split an `args=` value into arguments: spaces separate, and a
/// double-quoted run is one argument, so a sample can hand a program
/// `"2 + 3 * (10 - 4)"` the way a shell would.
const Arguments = struct {
    text: []const u8,
    at: usize = 0,

    fn next(self: *Arguments) ?[]const u8 {
        while (self.at < self.text.len and self.text[self.at] == ' ') self.at += 1;
        if (self.at >= self.text.len) return null;
        if (self.text[self.at] == '"') {
            const start = self.at + 1;
            const close = std.mem.indexOfScalarPos(u8, self.text, start, '"') orelse self.text.len;
            self.at = @min(close + 1, self.text.len);
            return self.text[start..close];
        }
        const start = self.at;
        while (self.at < self.text.len and self.text[self.at] != ' ') self.at += 1;
        return self.text[start..self.at];
    }
};

fn splitArguments(text: []const u8) Arguments {
    return .{ .text = text };
}

const Result = struct { stdout: []u8, stderr: []u8, status: u8 };

fn combine(gpa: Allocator, result: Result) ![]u8 {
    return std.mem.concat(gpa, u8, &.{ result.stdout, result.stderr });
}

fn makeSampleDirectory(self: *Verifier) ![]u8 {
    self.sample += 1;
    const name = try std.fmt.allocPrint(self.gpa, "{s}/s{d:0>4}", .{ self.work, self.sample });
    errdefer self.gpa.free(name);
    try Io.Dir.cwd().createDirPath(self.io, name);
    return name;
}

/// One engine's run directory: the sample's own files and the module,
/// and nothing either run left behind.
fn stage(
    self: *Verifier,
    directory: []const u8,
    name: []const u8,
    inputs: []const File,
    module: []const u8,
) ![]u8 {
    const room = try std.fs.path.join(self.gpa, &.{ directory, name });
    errdefer self.gpa.free(room);
    try Io.Dir.cwd().createDirPath(self.io, room);
    for (inputs) |file| try write(self, room, file.name, file.source);
    try write(self, room, "sample.lc", module);
    return room;
}

fn pathIn(gpa: Allocator, directory: []const u8, name: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ directory, name });
}

fn write(self: *Verifier, directory: []const u8, name: []const u8, source: []const u8) !void {
    const path = try std.fs.path.join(self.gpa, &.{ directory, name });
    defer self.gpa.free(path);
    try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = source });
}

fn run(self: *Verifier, directory: []const u8, argv: []const []const u8) !Result {
    const result = try std.process.run(self.gpa, self.io, .{
        .argv = argv,
        .cwd = .{ .path = directory },
    });
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .status = switch (result.term) {
            .exited => |code| code,
            else => 255,
        },
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "a quoted run of an args= value is one argument" {
    var words = splitArguments("2 \"a b\" 3");
    try std.testing.expectEqualStrings("2", words.next().?);
    try std.testing.expectEqualStrings("a b", words.next().?);
    try std.testing.expectEqualStrings("3", words.next().?);
    try std.testing.expect(words.next() == null);
}

test "trailing blank lines do not count as a mismatch, but content does" {
    try std.testing.expect(sameOutput("hello\n", "hello"));
    try std.testing.expect(sameOutput("hello\n\n\n", "hello\n"));
    try std.testing.expect(!sameOutput("hello\n", "hell\n"));
    try std.testing.expect(!sameOutput("a\nb\n", "a\n\nb\n"));
}
