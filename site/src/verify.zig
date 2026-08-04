//! Every Luce sample on the site is compiled and run, and the output
//! printed on the page is the output the program actually produced.
//!
//! A fenced block whose info string starts with `luce` must say what
//! is to become of it.  There is no unverified Luce on this site, by
//! construction: a bare ```luce fence is a build error naming the page
//! and the line.
//!
//!   ```luce run              a whole program; must compile and exit 0
//!   ```luce trap             must compile and then trap (loom exits 1)
//!   ```luce raise            must compile and then end on an uncaught
//!                            error (loom exits 3)
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
//! **Every program is compiled and run by the freshly built
//! toolchain**, and the page's claimed output is compared with what the
//! program actually printed.  There is one engine to run it on: `luce
//! build` writes machine code and `loom run` calls it (docs/ENGINE.md).
//!
//! This corpus used to be checked differentially as well — every sample
//! run a second time on the interpreter, with a disagreement failing
//! the build.  That went with the format change: a `.lc` is machine
//! code now and there is nothing to interpret.  What replaced it is
//! `src/luce/specs/`, where every program runs on both engines and is
//! compared frame for frame; if this corpus is ever wanted back as a
//! differential net, the way to have it is to let that harness read
//! these samples rather than to give loom a second engine.

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

    for (self.pending.items) |file| try write(self, directory, file.name, file.source);
    try write(self, directory, name, source);

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

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ terminal, "run", "sample.lc" });
    var words = splitArguments(arguments);
    while (words.next()) |argument| try argv.append(gpa, argument);

    const ran = try run(self, directory, argv.items);
    defer gpa.free(ran.stdout);
    defer gpa.free(ran.stderr);

    const said = try combine(gpa, ran);
    errdefer gpa.free(said);

    // A trap and an uncaught error are two different sentences about
    // a program, and loom says which with its exit status.  Checking
    // only "nonzero" let a sample captioned "traps" pass while it
    // actually raised — the caption is a claim about the language and
    // has to be checked like one.
    switch (mode) {
        .run => if (ran.status != loom_finished) {
            try self.note(line, "this sample is marked `run` but exited {d}", .{ran.status});
        },
        .trap => if (ran.status != loom_trapped) {
            try self.note(
                line,
                "this sample is marked `trap` but exited {d}; a trap exits {d}" ++
                    " and an uncaught error exits {d}",
                .{ ran.status, loom_trapped, loom_errored },
            );
        },
        .raise => if (ran.status != loom_errored) {
            try self.note(
                line,
                "this sample is marked `raise` but exited {d}; an uncaught error exits {d}" ++
                    " and a trap exits {d}",
                .{ ran.status, loom_errored, loom_trapped },
            );
        },
        else => {},
    }
    return said;
}

/// What loom exits with, from `src/apps/host.zig`.  Copied, because
/// this generator links no part of the tree it documents; a sample
/// whose exit status stops matching the number here is exactly the
/// failure this check exists to produce.
const loom_finished: u8 = 0;
const loom_trapped: u8 = 1;
const loom_errored: u8 = 3;

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

/// Put one fence through the sink and hold it to what it should have
/// complained about — `wanted` null meaning it should not have.
///
/// Only fences that are refused *before* anything is run can go
/// through this, and the ones below all are: they are refused by the
/// info string alone, which is the point.  The rule that there is no
/// unverified Luce on this site is a rule about what a fence is
/// allowed to *say*, and it has to hold whether or not any page
/// currently breaks it.
///
/// Without this, the rule was only ever exercised by the corpus — and
/// a corpus with no bad fences in it, which is exactly what the rule
/// produces, proves a check that has been deleted just as happily as
/// one that is there.
fn expectComplaint(
    fence: markdown.Fence,
    follower: ?markdown.Fence,
    wanted: ?[]const u8,
) !void {
    const gpa = std.testing.allocator;
    var verifier: Verifier = .{
        .gpa = gpa,
        .io = std.testing.io,
        .toolchain = "/nowhere",
        .work = "/nowhere",
        .repository = "/nowhere",
        .page = "test.md",
    };
    defer verifier.deinit();

    var out: Buffer = .init(gpa);
    defer out.deinit();
    var took_follower = false;
    try renderFence(&verifier, &out, fence, follower, &took_follower);

    const said = wanted orelse {
        try std.testing.expectEqual(@as(usize, 0), verifier.failures.items.len);
        return;
    };
    // The first complaint, not the only one: a fence can be wrong in
    // two ways at once (a misspelled `file=` leaves a module unnamed
    // as well), and saying both is better than stopping at one.
    try std.testing.expect(verifier.failures.items.len != 0);
    const complaint = verifier.failures.items[0];
    try std.testing.expectEqualStrings("test.md", complaint.page);
    try std.testing.expectEqual(fence.line, complaint.line);
    try std.testing.expect(std.mem.indexOf(u8, complaint.reason, said) != null);
}

test "a luce fence that does not say what becomes of it is a build error" {
    const body = "func main():\n    print(\"hi\")\n";
    const output: markdown.Fence = .{ .info = "output", .code = "hi\n", .line = 9 };

    // A bare ```luce: the whole rule, and the one a new page is most
    // likely to break.
    try expectComplaint(
        .{ .info = "luce", .code = body, .line = 3 },
        output,
        "must say run, trap, raise, fail or module",
    );

    // A word that is not one of the modes, named back so a typo reads
    // as a typo.
    try expectComplaint(
        .{ .info = "luce runs", .code = body, .line = 3 },
        output,
        "unknown luce fence mode 'runs'",
    );

    // An attribute nobody has: a misspelled `file=` would otherwise
    // silently write `main.luc`, and the page would claim the wrong
    // program's output.
    try expectComplaint(
        .{ .info = "luce module fil=other.luc", .code = body, .line = 3 },
        null,
        "unknown attribute 'fil=other.luc'",
    );

    // A module with nothing to be called: the program after it would
    // import a file that is not there.
    try expectComplaint(
        .{ .info = "luce module", .code = body, .line = 3 },
        null,
        "needs file=NAME.luc",
    );

    // And a program with no claimed output is a program nothing is
    // checked against, which is the same hole from the other side.
    try expectComplaint(
        .{ .info = "luce run", .code = body, .line = 3 },
        null,
        "needs a ```output fence after it",
    );
    try expectComplaint(
        .{ .info = "luce run", .code = body, .line = 3 },
        .{ .info = "text", .code = "hi\n", .line = 9 },
        "must be ```output",
    );

    // A fence in another language is not this rule's business and is
    // rendered as it stands — shell snippets, IR dumps, diagnostics
    // quoted from the repository.
    try expectComplaint(.{ .info = "zig", .code = "const x = 1;\n", .line = 3 }, null, null);
}
