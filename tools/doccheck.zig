//! The guard on the documentation: **every Luce sample in `docs/` is
//! compiled by the real compiler, on every `zig build test`.**
//!
//! The site has had this property since it was written — a fenced
//! `luce` block that does not declare what becomes of it is a build
//! error, and every sample's claimed output is compared with what the
//! program actually printed (`www/luce/src/verify.zig`).  `docs/` did not,
//! and eight language generations of drift went into it: a reference
//! page that still spelled `List(String)` after the rename, a memo
//! whose example used a builtin the language had deleted.  A document
//! showing code that does not compile is worse than one showing none,
//! because a reader cannot tell which sentences are still true.
//!
//! This is the smaller half of what the site does, and deliberately so.
//! The site *runs* its samples and compares their output; a document's
//! snippets only have to be **real** — to compile.  Running them would
//! mean an `output` fence under every one, which is a page format, not
//! a memo's.
//!
//! ## The fence taxonomy
//!
//! An info string is a set of words, and they answer two different
//! questions — *how is this wrapped* and *what must happen to it*:
//!
//!   ```luce              a whole file: declarations, and `func main()`
//!                        if it wants one.  Must pass `luce check`.
//!   ```luce fragment     statements from inside a function body.
//!                        Dedented, indented into a `func main():`,
//!                        and checked.
//!   ```luce refused      a program the compiler must *reject*.  A
//!                        document that shows a mistake is making a
//!                        claim about the compiler exactly as one
//!                        showing working code is, and it goes stale
//!                        the same way: if this ever compiles, the
//!                        sentence around it has stopped being true.
//!                        Combines with `fragment`.
//!   ```luce historical   code a **decision record** shows as an
//!                        illustration rather than as a program: an
//!                        earlier language's spelling, a syntax that
//!                        was proposed and refused, or a fragment
//!                        quoted out of a program nobody wrote.
//!                        Rendered as code, never compiled.
//!
//! `historical` is the one exemption there is, `grep -rn 'luce
//! historical' docs/` lists every use of it in one line each, and it
//! is a decision record's alone: **the living documents below carry
//! none.**  That split is the guard's whole shape — a memo is allowed
//! its history, and a reference page is not.
//!
//! Anything that is not Luce — an API index, a syntax sketch with `…`
//! in it — is a ```text fence and no business of this tool's.
//!
//! ## What counts as living
//!
//! `tools/documents.zig` says, and it is the only place that does — a
//! **living** document describes the language as it is, so a reader is
//! entitled to paste its code into a file and have it compile, and it
//! gets no exemptions; a **decision record** describes what was decided
//! and when, and the parts of it that are the language of their day say
//! so with `historical`.
//!
//! `tools/spelling.zig` reads that same list, for the sentences rather
//! than the samples: a living document may not spell a retired type
//! name in its prose either.  The two used to keep a list each, "meant
//! to be read together", and they disagreed by one.

const std = @import("std");
const luce = @import("luce");
const catalogue = @import("documents.zig");

const Allocator = std.mem.Allocator;

/// The documents whose Luce must compile, living ones first.
pub const documents = catalogue.all;

/// How many of `documents` are living.  The living ones come first so
/// that "the living documents carry no exemptions" is a slice rather
/// than a convention, and the test below asserts it as one.
pub const living_count = catalogue.living.len;

/// How a fence's body becomes a file.
pub const Wrap = enum { file, fragment };

/// What must become of it.
pub const Expect = enum { compiles, refused, nothing };

pub const Fence = struct {
    /// 1-based line of the ``` that opened it.
    line: usize,
    wrap: Wrap,
    expect: Expect,
    body: []const u8,
};

pub const Problem = struct {
    file: []const u8,
    line: usize,
    /// The compiler's report, or the reason the fence itself is wrong.
    reason: []const u8,

    pub fn deinit(self: *const Problem, gpa: Allocator) void {
        gpa.free(self.file);
        gpa.free(self.reason);
    }
};

pub const Census = struct {
    found: usize = 0,
    compiled: usize = 0,
    refused: usize = 0,
    historical: usize = 0,
};

/// Every fenced `luce` block in `text`, with what its info string says
/// to do with it.  An info string that says something else is a
/// problem of its own and comes back as `null` in `unknown`.
pub fn fences(
    gpa: Allocator,
    text: []const u8,
    into: *std.ArrayList(Fence),
    unknown: *std.ArrayList(usize),
) !void {
    var number: usize = 0;
    var start: ?usize = null;
    var wrap: Wrap = .file;
    var expect: Expect = .compiles;
    var opened: usize = 0;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        number += 1;
        if (start != null) {
            if (std.mem.startsWith(u8, line, "```")) {
                try into.append(gpa, .{
                    .line = opened,
                    .wrap = wrap,
                    .expect = expect,
                    .body = try gpa.dupe(u8, body.items),
                });
                body.clearRetainingCapacity();
                start = null;
                continue;
            }
            try body.appendSlice(gpa, line);
            try body.append(gpa, '\n');
            continue;
        }
        if (!std.mem.startsWith(u8, line, "```luce")) continue;
        const info = std.mem.trim(u8, line["```luce".len..], " \t\r");
        wrap = .file;
        expect = .compiles;
        var understood = true;
        var words = std.mem.tokenizeAny(u8, info, " \t");
        while (words.next()) |word| {
            if (std.mem.eql(u8, word, "fragment")) {
                wrap = .fragment;
            } else if (std.mem.eql(u8, word, "refused")) {
                expect = .refused;
            } else if (std.mem.eql(u8, word, "historical")) {
                expect = .nothing;
            } else understood = false;
        }
        if (!understood) {
            try unknown.append(gpa, number);
            // Read past it so its body is not mistaken for prose.
            while (lines.next()) |skip| {
                number += 1;
                if (std.mem.startsWith(u8, skip, "```")) break;
            }
            continue;
        }
        start = number;
        opened = number;
    }
}

/// The source a fence becomes before it reaches the compiler.  A
/// `whole` fence is itself, with an entry appended when it declares no
/// `main` — a document that shows two functions should not have to
/// invent a third to be checked.  A `fragment` is indented into one.
pub fn program(gpa: Allocator, fence: Fence) ![]u8 {
    switch (fence.wrap) {
        .file => {
            if (declaresMain(fence.body)) return gpa.dupe(u8, fence.body);
            return std.fmt.allocPrint(gpa, "{s}\nfunc main():\n    return\n", .{fence.body});
        },
        .fragment => {
            // **Dedented to its own left margin first.**  A snippet
            // lifted out of a function keeps the indentation it had
            // there, and re-indenting that would open a block four
            // columns deeper than anything containing it — which the
            // lexer refuses, correctly, and which says nothing about
            // the snippet.
            const margin = commonIndent(fence.body);
            var made: std.ArrayList(u8) = .empty;
            errdefer made.deinit(gpa);
            try made.appendSlice(gpa, "func main():\n");
            var lines = std.mem.splitScalar(u8, fence.body, '\n');
            while (lines.next()) |line| {
                const trimmed = std.mem.trimEnd(u8, line, " \t\r");
                if (trimmed.len == 0) {
                    try made.append(gpa, '\n');
                    continue;
                }
                try made.appendSlice(gpa, "    ");
                try made.appendSlice(gpa, trimmed[@min(margin, trimmed.len)..]);
                try made.append(gpa, '\n');
            }
            try made.appendSlice(gpa, "    return\n");
            return made.toOwnedSlice(gpa);
        },
    }
}

/// The leading spaces every non-blank line of `body` shares.
fn commonIndent(body: []const u8) usize {
    var least: usize = std.math.maxInt(usize);
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        var spaces: usize = 0;
        while (spaces < trimmed.len and trimmed[spaces] == ' ') spaces += 1;
        least = @min(least, spaces);
    }
    return if (least == std.math.maxInt(usize)) 0 else least;
}

fn declaresMain(body: []const u8) bool {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "func main(")) return true;
    }
    return false;
}

/// Compile every fence in one document, appending what did not.
///
/// `allow_host` is on: a document's samples print, and a reader who
/// pasted one into a file would run it under a host that allows it.
pub fn check(
    gpa: Allocator,
    io: std.Io,
    base: []const u8,
    file: []const u8,
    into: *std.ArrayList(Problem),
    census: *Census,
) !void {
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, file });
    defer gpa.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |mistake| {
        try into.append(gpa, .{
            .file = try gpa.dupe(u8, file),
            .line = 0,
            .reason = try std.fmt.allocPrint(gpa, "cannot be read: {s}", .{@errorName(mistake)}),
        });
        return;
    };
    defer gpa.free(text);

    var found: std.ArrayList(Fence) = .empty;
    defer {
        for (found.items) |one| gpa.free(one.body);
        found.deinit(gpa);
    }
    var unknown: std.ArrayList(usize) = .empty;
    defer unknown.deinit(gpa);
    try fences(gpa, text, &found, &unknown);

    for (unknown.items) |line| {
        try into.append(gpa, .{
            .file = try gpa.dupe(u8, file),
            .line = line,
            .reason = try gpa.dupe(
                u8,
                "a ```luce fence in a living document says nothing, `fragment`, `refused`, or `historical`",
            ),
        });
    }

    for (found.items) |one| {
        census.found += 1;
        if (one.expect == .nothing) {
            census.historical += 1;
            continue;
        }
        const source = try program(gpa, one);
        defer gpa.free(source);
        var result = try luce.compile.compile(gpa, source, .{ .allow_host = true });
        defer result.deinit();
        if (one.expect == .refused) {
            // The claim is the refusal.  A sample that starts
            // compiling has outlived the sentence around it exactly as
            // one that stops compiling has.
            if (result == .success) {
                try into.append(gpa, .{
                    .file = try gpa.dupe(u8, file),
                    .line = one.line,
                    .reason = try gpa.dupe(u8, "    this ```luce refused sample compiles\n"),
                });
            } else census.refused += 1;
            continue;
        }
        switch (result) {
            .success => census.compiled += 1,
            .failure => |diagnostics| {
                var said: std.ArrayList(u8) = .empty;
                errdefer said.deinit(gpa);
                var index: usize = 0;
                while (diagnostics.at(index)) |one_diagnostic| : (index += 1) {
                    const at = luce.source.place(source, one_diagnostic.span.start);
                    try said.print(gpa, "    +{d}:{d}: {s} [{s}]\n", .{
                        at.line,
                        at.column,
                        one_diagnostic.message,
                        one_diagnostic.code,
                    });
                    if (index == 2) break;
                }
                try into.append(gpa, .{
                    .file = try gpa.dupe(u8, file),
                    .line = one.line,
                    .reason = try said.toOwnedSlice(gpa),
                });
            },
        }
    }
}

/// Every living document under `base`.  `base` is the repository root
/// in earnest and a fixture directory under test, for the reason
/// `tools/spelling.zig`'s `survey` takes one: a guard whose document
/// list nothing exercises can be emptied without a test noticing.
pub fn survey(
    gpa: Allocator,
    io: std.Io,
    base: []const u8,
    files: []const []const u8,
    census: *Census,
) !std.ArrayList(Problem) {
    var problems: std.ArrayList(Problem) = .empty;
    errdefer {
        for (problems.items) |one| one.deinit(gpa);
        problems.deinit(gpa);
    }
    for (files) |file| try check(gpa, io, base, file, &problems, census);
    return problems;
}

const testing = std.testing;

test "the fence taxonomy is read off the info string" {
    const gpa = testing.allocator;
    var found: std.ArrayList(Fence) = .empty;
    defer {
        for (found.items) |one| gpa.free(one.body);
        found.deinit(gpa);
    }
    var unknown: std.ArrayList(usize) = .empty;
    defer unknown.deinit(gpa);
    try fences(gpa,
        \\Prose.
        \\```luce
        \\func main():
        \\    return
        \\```
        \\```luce fragment
        \\let n = 1
        \\```
        \\```luce historical
        \\let n: Int = 1
        \\```
        \\```luce refused fragment
        \\let n = 1
        \\n = 2
        \\```
        \\```zig
        \\const x = 1;
        \\```
        \\```luce run
        \\func main():
        \\    return
        \\```
    , &found, &unknown);
    try testing.expectEqual(@as(usize, 4), found.items.len);
    try testing.expectEqual(Wrap.file, found.items[0].wrap);
    try testing.expectEqual(Expect.compiles, found.items[0].expect);
    try testing.expectEqual(Wrap.fragment, found.items[1].wrap);
    try testing.expectEqual(Expect.nothing, found.items[2].expect);
    // The two words are orthogonal and combine.
    try testing.expectEqual(Wrap.fragment, found.items[3].wrap);
    try testing.expectEqual(Expect.refused, found.items[3].expect);
    try testing.expectEqual(@as(usize, 2), found.items[0].line);
    // A `zig` fence opens nothing, and `luce run` is the site's word,
    // not a document's.
    try testing.expectEqual(@as(usize, 1), unknown.items.len);
    try testing.expectEqual(@as(usize, 19), unknown.items[0]);
}

test "a fragment is indented into an entry, and a whole file keeps its own" {
    const gpa = testing.allocator;
    const fragment = try program(gpa, .{ .line = 1, .wrap = .fragment, .expect = .compiles, .body = "let n = 1\nlet m = n\n" });
    defer gpa.free(fragment);
    try testing.expectEqualStrings("func main():\n    let n = 1\n    let m = n\n\n    return\n", fragment);

    // A snippet lifted out of a function keeps its old indentation,
    // and is put back at the new one rather than four columns past it.
    const lifted = try program(gpa, .{ .line = 1, .wrap = .fragment, .expect = .compiles, .body = "        let n = 1\n        if n > 0:\n            let m = n\n" });
    defer gpa.free(lifted);
    try testing.expectEqualStrings(
        "func main():\n    let n = 1\n    if n > 0:\n        let m = n\n\n    return\n",
        lifted,
    );

    const whole = try program(gpa, .{ .line = 1, .wrap = .file, .expect = .compiles, .body = "func main():\n    return\n" });
    defer gpa.free(whole);
    try testing.expectEqualStrings("func main():\n    return\n", whole);

    // Declarations with no entry get one, so a document that shows a
    // struct does not have to show a `main` beside it.
    const declared = try program(gpa, .{ .line = 1, .wrap = .file, .expect = .compiles, .body = "struct Point:\n    x: long\n" });
    defer gpa.free(declared);
    try testing.expectEqualStrings("struct Point:\n    x: long\n\nfunc main():\n    return\n", declared);
}

test "every Luce sample in every living document compiles" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var census: Census = .{};
    var problems = try survey(gpa, threaded.io(), ".", &documents, &census);
    defer {
        for (problems.items) |one| one.deinit(gpa);
        problems.deinit(gpa);
    }
    if (problems.items.len != 0) {
        for (problems.items) |one| {
            std.debug.print("{s}:{d}: this sample does not compile:\n{s}", .{
                one.file,
                one.line,
                one.reason,
            });
        }
        return error.TestUnexpectedResult;
    }
    // Written down rather than derived: a document list that empties
    // itself passes vacuously, which is exactly the failure this guard
    // exists to prevent.
    try testing.expectEqual(@as(usize, 39), documents.len);
    try testing.expect(census.found >= 90);
    // And the exemption stays a decision record's: a living document
    // that reaches for `historical` is a living document that has
    // stopped being one.
    var living_census: Census = .{};
    var living_problems = try survey(gpa, threaded.io(), ".", documents[0..living_count], &living_census);
    defer {
        for (living_problems.items) |one| one.deinit(gpa);
        living_problems.deinit(gpa);
    }
    try testing.expectEqual(@as(usize, 0), living_census.historical);
}

test "the guard finds a sample that does not compile" {
    // The real test above runs against a clean tree, where a check
    // that has been deleted and a check that holds look alike.  This
    // one runs against a fixture built to be broken and requires the
    // guard to say so — and to leave the `historical` fence beside it
    // alone, which is the exemption's whole contract.
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var census: Census = .{};
    const fixture = [_][]const u8{"docs/BROKEN.md"};
    var problems = try survey(gpa, threaded.io(), "tools/testdata", &fixture, &census);
    defer {
        for (problems.items) |one| one.deinit(gpa);
        problems.deinit(gpa);
    }
    try testing.expectEqual(@as(usize, 4), census.found);
    try testing.expectEqual(@as(usize, 1), census.compiled);
    try testing.expectEqual(@as(usize, 1), census.refused);
    try testing.expectEqual(@as(usize, 1), census.historical);
    try testing.expectEqual(@as(usize, 1), problems.items.len);
    try testing.expectEqual(@as(usize, 20), problems.items[0].line);
}
