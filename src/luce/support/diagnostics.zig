//! Structured Luce diagnostics.
//!
//! Diagnostics are part of the editing experience, not terminal noise:
//! each carries a stable code, a severity, a concise message, and the
//! source span it points at — in the file it points into.
//!
//! **Why the source registry lives here.**  A span is a byte range and
//! nothing more; it means something only against the text it indexes,
//! and one compile has many texts (the root, std, imported modules).
//! The list therefore carries stage 1's `Sources` registry: every file
//! the compile loaded, with its path and line index.  That is what
//! lets a failed compile still name `std/strings.luc:41:9` after the
//! compile's arenas are gone — the diagnostics are the thing that
//! outlives the compile, so they are the thing that must own the text.
//!
//! **`Diagnostic` is internal; `Rendered` is the one to hand out.**  A
//! `Diagnostic` is a span and a `FileId`, which mean nothing away from
//! the registry that produced them.  `resolve` turns one into a
//! `Rendered`: path, line, column, end line, end column, the text of
//! the line, the code, and the message — the same shape Python gives
//! `SyntaxError`, and for the same reason.  That is the value that
//! survives being logged, serialised as JSON, or handed to an editor,
//! and it is why `Span` does not need to carry a `FileId`: the file is
//! known where the diagnostic is *made*, and everything downstream
//! wants the resolved form anyway.

const std = @import("std");
const source_mod = @import("../01_source.zig");

const Allocator = std.mem.Allocator;
const Span = source_mod.Span;
const FileId = source_mod.FileId;
const Sources = source_mod.Sources;

/// **The compiler has one severity, and that is the design.**  A Luce
/// diagnostic is a refusal: nothing is reported that does not stop the
/// compile, because a warning is a rule the language did not commit to
/// and a stream of them is how a codebase learns to ignore its
/// compiler.  The enum stays a named type — a reader of `Rendered`
/// should see what the field means, and an editor client reads a name
/// rather than inferring one — but it has exactly one member until
/// there is a second thing to say.
pub const Severity = enum { err };

/// One diagnostic, resolved against the sources that produced it.
///
/// Everything a reader, a log line, a `--json` record, or a language
/// server needs, with nothing left to look up: the compile can be over
/// and the registry the only thing still standing.
///
/// Ownership: every slice borrows from the `Diagnostics` that answered
/// `resolve`, and stays valid exactly as long as it does.  Nothing
/// here is allocated, so nothing here is freed — copy what you mean to
/// keep longer.
pub const Rendered = struct {
    /// Stable, e.g. "luce.parse.expected".
    code: []const u8,
    severity: Severity,
    message: []const u8,
    /// How the file should be named; "" when the diagnostic was raised
    /// before any file was registered, which is why those messages
    /// name their file themselves.
    path: []const u8,
    /// 1-based.  Both are 0 when there is no file to place against.
    line: usize,
    column: usize,
    /// 1-based, and past the last byte of the span — the half-open end
    /// of `Span`, in line and column form.  Equal to `line`/`column`
    /// for an empty span.
    end_line: usize,
    end_column: usize,
    /// The text of `source_line_number`, without its terminator; ""
    /// when there is no file.  Carried rather than re-read: the file on
    /// disk may have changed, and the registry has the bytes the span
    /// actually indexes.
    source_line: []const u8,
    /// Which line `source_line` is, normally `line`.
    ///
    /// It differs for a span at end of file.  A file ending in a
    /// newline gets one more line index than it has lines of text —
    /// deliberately, because that empty line is where "the thing
    /// missing at the end" belongs (`01_source/sources.zig`) — and an
    /// empty line renders as no snippet at all, so `func main():` with
    /// nothing under it reported a correct message with nothing to
    /// look at.  The position stays what it is and the snippet borrows
    /// the last line that has content, with the caret one past its
    /// end: the same byte, and the picture a reader wants.
    source_line_number: usize,
    /// Byte offsets into the file, kept because a tool that has the
    /// text already would rather slice than count.
    span: Span,

    /// "path:line:column: message [code]", plus the source line and a
    /// caret under the span when there is a file to show.
    ///
    /// The caret is padded one space per *character*, tabs copied
    /// through, so it lands under the right place whatever the reader
    /// renders a tab as.  Double-width characters are not accounted
    /// for; nothing portable can.
    pub fn writeTo(self: Rendered, allocator: Allocator, text: *std.ArrayList(u8)) Allocator.Error!void {
        if (self.path.len == 0) {
            try text.print(allocator, "{s} [{s}]\n", .{ self.message, self.code });
            return;
        }
        try text.print(allocator, "{s}:{d}:{d}: {s} [{s}]\n", .{
            self.path,
            self.line,
            self.column,
            self.message,
            self.code,
        });
        if (self.source_line.len == 0) return;

        // A borrowed line (end of file) puts the caret one past its
        // last character, which is the byte the span points at.
        const borrowed = self.source_line_number != self.line;
        const caret_at = if (borrowed)
            self.source_line.len
        else
            @min(self.column - 1, self.source_line.len);
        // A span that runs past this line is underlined to its end;
        // one that ends on it is underlined exactly.
        const stop = if (borrowed)
            self.source_line.len
        else if (self.end_line == self.line)
            @min(self.end_column - 1, self.source_line.len)
        else
            self.source_line.len;

        const shown = self.window(caret_at);
        try text.print(allocator, "{s}{s}{s}{s}\n{s}", .{
            gutter,
            if (shown.start != 0) elision else "",
            self.source_line[shown.start..shown.end],
            if (shown.end != self.source_line.len) elision else "",
            gutter,
        });

        if (shown.start != 0) {
            for (elision) |_| try text.append(allocator, ' ');
        }
        for (self.source_line[shown.start..@min(caret_at, shown.end)]) |character| {
            // Skip UTF-8 continuation bytes: one pad per character.
            if (character & 0xC0 == 0x80) continue;
            try text.append(allocator, if (character == '\t') '\t' else ' ');
        }
        try text.append(allocator, '^');
        var at = @min(caret_at + 1, stop);
        const underline_to = @min(stop, shown.end);
        while (at < underline_to) : (at += 1) {
            if (self.source_line[at] & 0xC0 == 0x80) continue;
            try text.append(allocator, '~');
        }
        try text.append(allocator, '\n');
    }

    /// The byte range of the source line to actually print.
    ///
    /// A line that fits is printed whole, which is every line a person
    /// writes.  A generated or pathological one is not: a 300-deep
    /// paren nest renders a 617-character line with the caret padded
    /// out to column 268, and the padding makes the output longer than
    /// the line it is under.  So a long line is windowed around the
    /// caret, with context in front of it and `...` for what is cut.
    ///
    /// Measured in characters, not bytes, because the caret pads one
    /// space per character.  Double-width characters are not accounted
    /// for here any more than they are below; nothing portable can.
    fn window(self: Rendered, caret_at: usize) struct { start: usize, end: usize } {
        // A line of N bytes holds at most N characters, so this is the
        // cheap test that lets every ordinary line skip the walk.
        if (self.source_line.len <= max_line_width) {
            return .{ .start = 0, .end = self.source_line.len };
        }
        const start = stepBack(self.source_line, caret_at, context_width);
        const end = stepForward(self.source_line, start, max_line_width);
        // A caret near the end of a long line would otherwise get a
        // short window; give it a full one by pulling the start back.
        if (end == self.source_line.len) {
            return .{ .start = stepBack(self.source_line, end, max_line_width), .end = end };
        }
        return .{ .start = start, .end = end };
    }

    /// The indent the source line and its caret share.  Same width as
    /// a trap trace's frames, so a terminal full of both lines up.
    const gutter = "    ";
    /// What stands in for the part of a long line that is not shown.
    /// ASCII, so it costs exactly one caret pad per byte and renders
    /// the same in every terminal.
    const elision = "...";
    /// Characters of a source line worth printing, and how many of
    /// them to keep in front of the caret.
    const max_line_width = 100;
    const context_width = 30;
};

/// The byte offset `count` characters before `at`, stopping at 0.
fn stepBack(line: []const u8, at: usize, count: usize) usize {
    var offset = at;
    var moved: usize = 0;
    while (offset > 0 and moved < count) : (moved += 1) {
        offset -= 1;
        while (offset > 0 and line[offset] & 0xC0 == 0x80) offset -= 1;
    }
    return offset;
}

/// The byte offset `count` characters after `at`, stopping at the end.
fn stepForward(line: []const u8, at: usize, count: usize) usize {
    var offset = at;
    var moved: usize = 0;
    while (offset < line.len and moved < count) : (moved += 1) {
        offset += 1;
        while (offset < line.len and line[offset] & 0xC0 == 0x80) offset += 1;
    }
    return offset;
}

pub const Diagnostic = struct {
    code: []const u8, // stable, e.g. "luce.parse.expected"
    severity: Severity,
    message: []u8, // owned by the list
    span: Span,
    /// Which loaded file the span indexes; resolve it through
    /// `sources`.  Defaults to the root, which is what a diagnostic
    /// raised before anything was loaded means.
    file: FileId,
};

// ---------------------------------------------------------------------------
// Diagnostics
// ---------------------------------------------------------------------------
//
// An append-only diagnostic list.  Owns every message, and the source
// registry every span is measured against.
//
pub const Diagnostics = struct {
    allocator: Allocator,
    list: std.ArrayList(Diagnostic) = .empty,
    /// Every file this compile loaded (stage 1 fills it in).
    sources: Sources,
    /// Stamped onto every added diagnostic; the loader and the
    /// analyzer set it to the file being worked on.
    scope: FileId = source_mod.root_file,

    pub fn init(allocator: Allocator) Diagnostics {
        return .{ .allocator = allocator, .sources = Sources.init(allocator) };
    }

    pub fn deinit(self: *Diagnostics) void {
        for (self.list.items) |item| self.allocator.free(item.message);
        self.list.deinit(self.allocator);
        self.sources.deinit();
        self.* = undefined;
    }

    pub fn add(
        self: *Diagnostics,
        code: []const u8,
        span: Span,
        comptime format: []const u8,
        arguments: anytype,
    ) error{OutOfMemory}!void {
        const message = try std.fmt.allocPrint(self.allocator, format, arguments);
        errdefer self.allocator.free(message);
        try self.list.append(self.allocator, .{
            .code = code,
            .severity = .err,
            .message = message,
            .span = span,
            .file = self.scope,
        });
    }

    pub fn count(self: *const Diagnostics) usize {
        return self.list.items.len;
    }

    pub fn at(self: *const Diagnostics, index: usize) ?*const Diagnostic {
        if (index >= self.list.items.len) return null;
        return &self.list.items[index];
    }

    /// Whether the compile is refused.  Every diagnostic is an error
    /// (`Severity`), so this is "did anything get reported" — said
    /// plainly, rather than as a walk looking for a severity there is
    /// only one of.
    pub fn hasErrors(self: *const Diagnostics) bool {
        return self.list.items.len != 0;
    }

    /// Diagnostic `index`, resolved against the registry: the value to
    /// hand to anything that is not this compile.  Null past the end.
    ///
    /// The result borrows from this list and its registry; see
    /// `Rendered`.
    pub fn resolve(self: *const Diagnostics, index: usize) ?Rendered {
        const item = self.at(index) orelse return null;
        const file = self.sources.at(item.file) orelse return .{
            .code = item.code,
            .severity = item.severity,
            .message = item.message,
            .path = "",
            .line = 0,
            .column = 0,
            .end_line = 0,
            .end_column = 0,
            .source_line = "",
            .source_line_number = 0,
            .span = item.span,
        };
        const start = self.sources.place(item.file, item.span.start);
        const end = self.sources.place(item.file, @max(item.span.end, item.span.start));
        // A span at end of file lands past the last line of text, and
        // that line renders as nothing.  Borrow the last line that has
        // content — but only at end of file, so a diagnostic on a blank
        // line in the middle still shows the blank line it names.
        var shown_line = start.line;
        var shown_text = self.sources.lineText(item.file, shown_line);
        if (item.span.start >= file.text.len) {
            while (shown_text.len == 0 and shown_line > 1) {
                shown_line -= 1;
                shown_text = self.sources.lineText(item.file, shown_line);
            }
        }
        return .{
            .code = item.code,
            .severity = item.severity,
            .message = item.message,
            .path = file.path,
            .line = start.line,
            .column = start.column,
            .end_line = end.line,
            .end_column = end.column,
            .source_line = shown_text,
            .source_line_number = shown_line,
            .span = item.span,
        };
    }

    /// Render every diagnostic for a terminal: the location line, then
    /// the source line and a caret under the span.  A diagnostic whose
    /// file was never registered — one raised before or instead of a
    /// load — prints its message alone, which is why those messages
    /// name their file themselves.  The caller owns the text.
    pub fn render(self: *const Diagnostics, allocator: Allocator) ![]u8 {
        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(allocator);
        for (0..self.list.items.len) |index| {
            try self.resolve(index).?.writeTo(allocator, &text);
        }
        return text.toOwnedSlice(allocator);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn register(diagnostics: *Diagnostics, kind: source_mod.Kind, name: []const u8, path: []const u8, text: []const u8) !FileId {
    const owned = try testing.allocator.dupe(u8, text);
    return diagnostics.sources.add(kind, "", name, path, owned);
}

test "diagnostics own their messages and render places" {
    var diagnostics = Diagnostics.init(testing.allocator);
    defer diagnostics.deinit();
    _ = try register(&diagnostics, .root, "", "main.luc", "ab\ncd");

    try diagnostics.add("luce.test", .{ .start = 3, .end = 4 }, "unexpected {s}", .{"thing"});
    try testing.expectEqual(@as(usize, 1), diagnostics.count());
    try testing.expect(diagnostics.hasErrors());

    const rendered = try diagnostics.render(testing.allocator);
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings(
        \\main.luc:2:1: unexpected thing [luce.test]
        \\    cd
        \\    ^
        \\
    , rendered);
}

test "each diagnostic renders against the file its span indexes" {
    var diagnostics = Diagnostics.init(testing.allocator);
    defer diagnostics.deinit();
    _ = try register(&diagnostics, .root, "", "main.luc", "import geo\n\nfunc main():\n    return\n");
    const geo = try register(&diagnostics, .imported, "geo", "geo.luc", "func area():\n    return 1\n");

    try diagnostics.add("luce.sema.name", .{ .start = 12, .end = 16 }, "root problem", .{});
    diagnostics.scope = geo;
    try diagnostics.add("luce.sema.type", .{ .start = 17, .end = 25 }, "module problem", .{});

    const rendered = try diagnostics.render(testing.allocator);
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings(
        \\main.luc:3:1: root problem [luce.sema.name]
        \\    func main():
        \\    ^~~~
        \\geo.luc:2:5: module problem [luce.sema.type]
        \\        return 1
        \\        ^~~~~~~~
        \\
    , rendered);
}

test "a diagnostic at end of file shows the last line and points past it" {
    // `func main():` with nothing under it reports on the empty line
    // after the last newline — which is where the missing statement
    // belongs, and which renders as nothing at all.  So the snippet
    // borrows the last line with content, and the caret sits one past
    // its end: the same byte the span names.
    var diagnostics = Diagnostics.init(testing.allocator);
    defer diagnostics.deinit();
    const text = "func main():\n";
    _ = try register(&diagnostics, .root, "", "main.luc", text);
    try diagnostics.add("luce.parse.expected", .{ .start = 13, .end = 13 }, "this 'func' block is empty", .{});

    const rendered = try diagnostics.render(testing.allocator);
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings(
        \\main.luc:2:1: this 'func' block is empty [luce.parse.expected]
        \\    func main():
        \\                ^
        \\
    , rendered);

    // The reported position is unchanged — only the snippet is
    // borrowed, and it says which line it came from.
    const resolved = diagnostics.resolve(0).?;
    try testing.expectEqual(@as(usize, 2), resolved.line);
    try testing.expectEqual(@as(usize, 1), resolved.column);
    try testing.expectEqual(@as(usize, 1), resolved.source_line_number);
    try testing.expectEqualStrings("func main():", resolved.source_line);
}

test "the borrowed line is only borrowed at end of file" {
    var diagnostics = Diagnostics.init(testing.allocator);
    defer diagnostics.deinit();
    // A blank line in the middle keeps its own emptiness: the reader
    // is being told about *that* line, and showing the one above it
    // under a different line number would be a lie.
    const text = "func main():\n\n    return\n";
    _ = try register(&diagnostics, .root, "", "main.luc", text);
    try diagnostics.add("luce.parse.expected", .{ .start = 13, .end = 13 }, "blank", .{});
    const resolved = diagnostics.resolve(0).?;
    try testing.expectEqual(@as(usize, 2), resolved.line);
    try testing.expectEqual(@as(usize, 2), resolved.source_line_number);
    try testing.expectEqualStrings("", resolved.source_line);

    // An empty file has no line to borrow and renders no snippet.
    var empty = Diagnostics.init(testing.allocator);
    defer empty.deinit();
    _ = try register(&empty, .root, "", "empty.luc", "");
    try empty.add("luce.sema.main", .{ .start = 0, .end = 0 }, "missing func main():", .{});
    const rendered = try empty.render(testing.allocator);
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings("empty.luc:1:1: missing func main(): [luce.sema.main]\n", rendered);
}

test "a diagnostic with no registered file still renders its message" {
    var diagnostics = Diagnostics.init(testing.allocator);
    defer diagnostics.deinit();
    try diagnostics.add("luce.source.utf8", .{ .start = 0, .end = 0 }, "photo.luc is not valid UTF-8", .{});

    const rendered = try diagnostics.render(testing.allocator);
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings("photo.luc is not valid UTF-8 [luce.source.utf8]\n", rendered);

    // And it resolves to a value that says so, rather than to a
    // plausible-looking 1:1 in a file that does not exist.
    const resolved = diagnostics.resolve(0).?;
    try testing.expectEqualStrings("", resolved.path);
    try testing.expectEqual(@as(usize, 0), resolved.line);
    try testing.expect(diagnostics.resolve(1) == null);
}

test "a resolved diagnostic carries everything a tool needs" {
    // The shape Python gives SyntaxError — filename, lineno, offset,
    // end_lineno, end_offset, and the text of the line — because that
    // is what survives being logged, serialised, or sent elsewhere.
    var diagnostics = Diagnostics.init(testing.allocator);
    defer diagnostics.deinit();
    const text = "func main():\n    let a = 1 +\n    return\n";
    _ = try register(&diagnostics, .root, "", "sub/main.luc", text);
    try diagnostics.add("luce.parse.expected", .{ .start = 27, .end = 28 }, "expected a value", .{});

    const resolved = diagnostics.resolve(0).?;
    try testing.expectEqualStrings("luce.parse.expected", resolved.code);
    try testing.expectEqual(Severity.err, resolved.severity);
    try testing.expectEqualStrings("expected a value", resolved.message);
    try testing.expectEqualStrings("sub/main.luc", resolved.path);
    try testing.expectEqual(@as(usize, 2), resolved.line);
    try testing.expectEqual(@as(usize, 15), resolved.column);
    try testing.expectEqual(@as(usize, 2), resolved.end_line);
    try testing.expectEqual(@as(usize, 16), resolved.end_column);
    try testing.expectEqualStrings("    let a = 1 +", resolved.source_line);
    // The line is the registry's own bytes, not a promise to re-read.
    try testing.expect(std.mem.indexOf(u8, text, resolved.source_line) != null);
}

test "the caret lands under the span, through tabs and multi-byte text" {
    var diagnostics = Diagnostics.init(testing.allocator);
    defer diagnostics.deinit();
    // A tab, then an accented character, then the word to point at.
    _ = try register(&diagnostics, .root, "", "main.luc", "\tlet caf\xC3\xA9 = bad\n");
    try diagnostics.add("luce.sema.name", .{ .start = 13, .end = 16 }, "unknown name", .{});

    const rendered = try diagnostics.render(testing.allocator);
    defer testing.allocator.free(rendered);
    // One pad per character with the tab copied through: the accented
    // é pads once, not twice, so the caret lands on "bad".
    try testing.expectEqualStrings(
        "main.luc:1:14: unknown name [luce.sema.name]\n" ++
            "    \tlet caf\xC3\xA9 = bad\n" ++
            "    \t           ^~~\n",
        rendered,
    );
}

test "a long line is windowed around the caret, at both ends and in the middle" {
    const allocator = testing.allocator;
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);
    // 300 'a's, a 'bad' to point at in the middle, 300 more, newline.
    try line.appendNTimes(allocator, 'a', 300);
    try line.appendSlice(allocator, "bad");
    try line.appendNTimes(allocator, 'a', 300);
    try line.append(allocator, '\n');

    var diagnostics = Diagnostics.init(allocator);
    defer diagnostics.deinit();
    _ = try register(&diagnostics, .root, "", "main.luc", line.items);
    try diagnostics.add("luce.sema.name", .{ .start = 300, .end = 303 }, "unknown name", .{});

    const rendered = try diagnostics.render(allocator);
    defer allocator.free(rendered);
    // Cut at both ends, the caret 30 characters into the window, and
    // the whole thing bounded rather than 600 columns of 'a' followed
    // by 300 columns of padding.
    try testing.expectEqualStrings(
        "main.luc:1:301: unknown name [luce.sema.name]\n" ++
            "    ..." ++ ("a" ** 30) ++ "bad" ++ ("a" ** 67) ++ "...\n" ++
            "       " ++ (" " ** 30) ++ "^~~\n",
        rendered,
    );
}

test "a long line keeps a full window when the caret is at either end" {
    const allocator = testing.allocator;
    var diagnostics = Diagnostics.init(allocator);
    defer diagnostics.deinit();
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);
    try line.appendSlice(allocator, "bad");
    try line.appendNTimes(allocator, 'a', 300);
    try line.append(allocator, '\n');
    _ = try register(&diagnostics, .root, "", "main.luc", line.items);
    // At the very start: nothing is cut in front, 100 characters shown.
    try diagnostics.add("luce.sema.name", .{ .start = 0, .end = 3 }, "at the start", .{});
    // At the very end: nothing is cut behind, still 100 characters.
    try diagnostics.add("luce.sema.name", .{ .start = 302, .end = 303 }, "at the end", .{});

    const rendered = try diagnostics.render(allocator);
    defer allocator.free(rendered);
    try testing.expectEqualStrings(
        "main.luc:1:1: at the start [luce.sema.name]\n" ++
            "    bad" ++ ("a" ** 97) ++ "...\n" ++
            "    ^~~\n" ++
            "main.luc:1:303: at the end [luce.sema.name]\n" ++
            "    ..." ++ ("a" ** 100) ++ "\n" ++
            "       " ++ (" " ** 99) ++ "^\n",
        rendered,
    );
}

test "a line that fits is printed whole, ellipsis and all" {
    const allocator = testing.allocator;
    var diagnostics = Diagnostics.init(allocator);
    defer diagnostics.deinit();
    // Exactly at the bound: still printed entire, with no marker.
    var line: [101]u8 = undefined;
    @memset(&line, 'a');
    line[97] = 'b';
    line[100] = '\n';
    _ = try register(&diagnostics, .root, "", "main.luc", &line);
    try diagnostics.add("luce.sema.name", .{ .start = 97, .end = 98 }, "unknown name", .{});

    const rendered = try diagnostics.render(allocator);
    defer allocator.free(rendered);
    try testing.expectEqualStrings(
        "main.luc:1:98: unknown name [luce.sema.name]\n" ++
            "    " ++ ("a" ** 97) ++ "b" ++ ("a" ** 2) ++ "\n" ++
            "    " ++ (" " ** 97) ++ "^\n",
        rendered,
    );
}

test "a span that runs past its line underlines to the end of it" {
    var diagnostics = Diagnostics.init(testing.allocator);
    defer diagnostics.deinit();
    _ = try register(&diagnostics, .root, "", "main.luc", "if a:\n    b\nc\n");
    // From "if" to the start of line 3.
    try diagnostics.add("luce.parse.block", .{ .start = 0, .end = 12 }, "unclosed block", .{});

    const rendered = try diagnostics.render(testing.allocator);
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings(
        \\main.luc:1:1: unclosed block [luce.parse.block]
        \\    if a:
        \\    ^~~~~
        \\
    , rendered);
}

test "an empty file invents no line, and a span at the end borrows one" {
    var diagnostics = Diagnostics.init(testing.allocator);
    defer diagnostics.deinit();
    _ = try register(&diagnostics, .root, "", "empty.luc", "");
    try diagnostics.add("luce.parse.expected", .{ .start = 0, .end = 0 }, "expected a program", .{});
    // The empty line after a final newline: where an end-of-file span
    // lands.  It has no text of its own, so it shows the line above it
    // and points one past the end — the byte the span actually names.
    const ended = try register(&diagnostics, .imported, "geo", "geo.luc", "a\n");
    diagnostics.scope = ended;
    try diagnostics.add("luce.parse.expected", .{ .start = 2, .end = 2 }, "expected a body", .{});

    const rendered = try diagnostics.render(testing.allocator);
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings(
        \\empty.luc:1:1: expected a program [luce.parse.expected]
        \\geo.luc:2:1: expected a body [luce.parse.expected]
        \\    a
        \\     ^
        \\
    , rendered);
}
