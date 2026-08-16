//! The Markdown subset the site is written in.
//!
//! Small on purpose.  A documentation site that needs a Markdown
//! *dialect* has a content problem, not a tooling problem, so this
//! handles exactly what the pages use and rejects nothing:
//!
//!   headings `#`..`####`   paragraphs         `---` rules
//!   `-`/`1.` lists         `>` block quotes   `|` tables
//!   fenced code blocks     inline `` ` ``, `**`, `*`, `[text](url)`
//!
//! Code fences are handed to a `Sink` rather than rendered here.  That
//! is the seam the example verifier plugs into: it gets the fence, the
//! fence that follows it, and the right to consume both.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("buffer.zig");

/// One fenced block: the text after the backticks, and the body.
pub const Fence = struct {
    info: []const u8,
    code: []const u8,
    /// Line number of the opening fence, for diagnostics.
    line: usize,
};

/// What a page hands the renderer to deal with its code blocks.
pub const Sink = struct {
    context: *anyopaque,
    /// Render `primary` into `out`.  `follower` is the next fenced
    /// block if one follows with nothing but blank lines between; set
    /// `took_follower` to consume it as well.
    render: *const fn (
        context: *anyopaque,
        out: *Buffer,
        primary: Fence,
        follower: ?Fence,
        took_follower: *bool,
    ) anyerror!void,
};

/// A heading, for the page's "on this page" list.
pub const Heading = struct {
    level: u8,
    id: []const u8,
    title: []const u8,
};

pub const Document = struct {
    /// The body HTML, without the `<h1>` — the page shell writes that.
    html: []u8,
    /// The text of the leading `# ` heading.
    title: []u8,
    headings: []Heading,

    pub fn deinit(self: *Document, gpa: Allocator) void {
        gpa.free(self.html);
        gpa.free(self.title);
        for (self.headings) |heading| {
            gpa.free(heading.id);
            gpa.free(heading.title);
        }
        gpa.free(self.headings);
    }
};

pub const Error = error{MissingTitle} || anyerror;

const Renderer = struct {
    gpa: Allocator,
    lines: [][]const u8,
    cursor: usize = 0,
    out: Buffer,
    headings: std.ArrayList(Heading) = .empty,
    sink: ?Sink,

    fn peek(self: *const Renderer) ?[]const u8 {
        if (self.cursor >= self.lines.len) return null;
        return self.lines[self.cursor];
    }
};

pub fn render(gpa: Allocator, source: []const u8, sink: ?Sink) Error!Document {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var walk = std.mem.splitScalar(u8, source, '\n');
    while (walk.next()) |line| {
        // Tolerate CRLF sources, the way the compiler does.
        try lines.append(gpa, std.mem.trimEnd(u8, line, "\r"));
    }

    var renderer: Renderer = .{
        .gpa = gpa,
        .lines = lines.items,
        .out = .init(gpa),
        .sink = sink,
    };
    defer renderer.out.deinit();
    errdefer {
        for (renderer.headings.items) |heading| {
            gpa.free(heading.id);
            gpa.free(heading.title);
        }
        renderer.headings.deinit(gpa);
    }

    // The document must open with its own title.
    while (renderer.peek()) |line| {
        if (line.len != 0) break;
        renderer.cursor += 1;
    }
    const first = renderer.peek() orelse return error.MissingTitle;
    if (!std.mem.startsWith(u8, first, "# ")) return error.MissingTitle;
    const title = try gpa.dupe(u8, std.mem.trim(u8, first[2..], " "));
    errdefer gpa.free(title);
    renderer.cursor += 1;

    try blocks(&renderer);

    return .{
        .html = try renderer.out.take(),
        .title = title,
        .headings = try renderer.headings.toOwnedSlice(gpa),
    };
}

// ---------------------------------------------------------------------------
// Blocks
// ---------------------------------------------------------------------------

fn blocks(self: *Renderer) !void {
    while (self.peek()) |line| {
        if (line.len == 0) {
            self.cursor += 1;
            continue;
        }
        if (std.mem.startsWith(u8, line, "```")) {
            try fence(self);
        } else if (line[0] == '#' and headingLevel(line) != null) {
            try headingBlock(self);
        } else if (std.mem.eql(u8, line, "---")) {
            try self.out.add("<hr>\n");
            self.cursor += 1;
        } else if (std.mem.startsWith(u8, line, "> ")) {
            try quote(self);
        } else if (line[0] == '|') {
            try table(self);
        } else if (bullet(line) != null) {
            try list(self, 0);
        } else {
            try paragraph(self);
        }
    }
}

fn headingLevel(line: []const u8) ?u8 {
    var level: u8 = 0;
    while (level < line.len and line[level] == '#') level += 1;
    if (level == 0 or level > 4) return null;
    if (level >= line.len or line[level] != ' ') return null;
    return level;
}

fn headingBlock(self: *Renderer) !void {
    const line = self.peek().?;
    const level = headingLevel(line).?;
    var text = std.mem.trim(u8, line[level + 1 ..], " ");
    self.cursor += 1;

    // A trailing `{#name}` fixes the anchor.  The reference uses it to
    // give every numbered rule a short, citable identifier that does
    // not move when its wording does.
    var chosen: ?[]const u8 = null;
    if (std.mem.endsWith(u8, text, "}")) {
        if (std.mem.lastIndexOf(u8, text, "{#")) |open| {
            chosen = text[open + 2 .. text.len - 1];
            text = std.mem.trimEnd(u8, text[0..open], " ");
        }
    }

    const id = if (chosen) |name|
        try self.gpa.dupe(u8, name)
    else
        try slug(self.gpa, text, self.headings.items);
    errdefer self.gpa.free(id);
    const kept = try self.gpa.dupe(u8, text);
    errdefer self.gpa.free(kept);
    try self.headings.append(self.gpa, .{ .level = level, .id = id, .title = kept });

    try self.out.print("<h{d} id=\"{s}\">", .{ level, id });
    try inline_(self, text);
    try self.out.print(
        "<a class=\"anchor\" href=\"#{s}\" aria-label=\"link to this section\">#</a></h{d}>\n",
        .{ id, level },
    );
}

fn fence(self: *Renderer) !void {
    const primary = try collectFence(self);
    defer self.gpa.free(primary.code);

    // Look ahead for an immediately following fence, blank lines apart.
    var lookahead = self.cursor;
    while (lookahead < self.lines.len and self.lines[lookahead].len == 0) lookahead += 1;
    var follower: ?Fence = null;
    defer if (follower) |block| self.gpa.free(block.code);
    const saved = self.cursor;
    if (lookahead < self.lines.len and std.mem.startsWith(u8, self.lines[lookahead], "```")) {
        self.cursor = lookahead;
        follower = try collectFence(self);
    }
    const after_follower = self.cursor;
    self.cursor = saved;

    var took = false;
    if (self.sink) |sink| {
        try sink.render(sink.context, &self.out, primary, follower, &took);
    } else {
        try plainFence(&self.out, primary);
    }
    if (took) self.cursor = after_follower;
}

/// Read the fence the cursor sits on and leave the cursor after it.
fn collectFence(self: *Renderer) !Fence {
    const opening = self.lines[self.cursor];
    const info = std.mem.trim(u8, opening[3..], " ");
    const line = self.cursor + 1;
    self.cursor += 1;
    const start = self.cursor;
    while (self.cursor < self.lines.len and
        !std.mem.startsWith(u8, self.lines[self.cursor], "```")) self.cursor += 1;
    const end = self.cursor;
    if (self.cursor < self.lines.len) self.cursor += 1;

    var body: Buffer = .init(self.gpa);
    defer body.deinit();
    for (self.lines[start..end]) |text| {
        try body.add(text);
        try body.addByte('\n');
    }
    return .{ .info = info, .code = try body.take(), .line = line };
}

/// The fallback rendering, used when nothing claims a fence: escaped
/// text in a scrolling box.
pub fn plainFence(out: *Buffer, block: Fence) !void {
    try out.add("<div class=\"code\"><pre><code>");
    try out.addEscaped(block.code);
    try out.add("</code></pre></div>\n");
}

fn quote(self: *Renderer) !void {
    var text: Buffer = .init(self.gpa);
    defer text.deinit();
    while (self.peek()) |line| {
        if (!std.mem.startsWith(u8, line, ">")) break;
        const stripped = if (std.mem.startsWith(u8, line, "> ")) line[2..] else line[1..];
        if (text.text().len != 0) try text.addByte(' ');
        try text.add(stripped);
        self.cursor += 1;
    }
    try self.out.add("<blockquote><p>");
    try inline_(self, text.text());
    try self.out.add("</p></blockquote>\n");
}

fn table(self: *Renderer) !void {
    const header = self.peek().?;
    self.cursor += 1;
    // The separator row is required and carries no content.
    if (self.peek()) |line| {
        if (line.len != 0 and line[0] == '|') self.cursor += 1;
    }

    try self.out.add("<div class=\"table\"><table>\n<thead><tr>");
    try cells(self, header, "th");
    try self.out.add("</tr></thead>\n<tbody>\n");
    while (self.peek()) |line| {
        if (line.len == 0 or line[0] != '|') break;
        self.cursor += 1;
        try self.out.add("<tr>");
        try cells(self, line, "td");
        try self.out.add("</tr>\n");
    }
    try self.out.add("</tbody></table></div>\n");
}

fn cells(self: *Renderer, line: []const u8, tag: []const u8) !void {
    const body = std.mem.trim(u8, line, "|");
    var walk = std.mem.splitScalar(u8, body, '|');
    while (walk.next()) |cell| {
        try self.out.print("<{s}>", .{tag});
        try inline_(self, std.mem.trim(u8, cell, " "));
        try self.out.print("</{s}>", .{tag});
    }
}

/// `- ` / `* ` / `1. ` — returns the offset of the item's text.
fn bullet(line: []const u8) ?usize {
    const indent = leading(line);
    const rest = line[indent..];
    if (std.mem.startsWith(u8, rest, "- ") or std.mem.startsWith(u8, rest, "* ")) {
        return indent + 2;
    }
    var digits: usize = 0;
    while (digits < rest.len and std.ascii.isDigit(rest[digits])) digits += 1;
    if (digits > 0 and digits + 1 < rest.len and rest[digits] == '.' and rest[digits + 1] == ' ') {
        return indent + digits + 2;
    }
    return null;
}

fn ordered(line: []const u8) bool {
    const indent = leading(line);
    return std.ascii.isDigit(line[indent]);
}

fn leading(line: []const u8) usize {
    var count: usize = 0;
    while (count < line.len and line[count] == ' ') count += 1;
    return count;
}

fn list(self: *Renderer, depth: usize) !void {
    const opener = self.peek().?;
    const indent = leading(opener);
    const numbered = ordered(opener);
    const tag: []const u8 = if (numbered) "ol" else "ul";
    try self.out.print("<{s}>\n", .{tag});

    while (self.peek()) |line| {
        if (line.len == 0) {
            // A blank line ends the list unless the next line continues
            // it — same indent or deeper, and the same kind of marker.
            var lookahead = self.cursor;
            while (lookahead < self.lines.len and self.lines[lookahead].len == 0) lookahead += 1;
            if (lookahead >= self.lines.len) break;
            const next = self.lines[lookahead];
            if (bullet(next) == null or leading(next) < indent) break;
            if (leading(next) == indent and ordered(next) != numbered) break;
            self.cursor = lookahead;
            continue;
        }
        const start = bullet(line) orelse break;
        const here = leading(line);
        if (here < indent) break;
        if (here == indent and ordered(line) != numbered) break;
        if (here > indent) {
            if (depth >= 3) break;
            try list(self, depth + 1);
            continue;
        }
        self.cursor += 1;

        var item: Buffer = .init(self.gpa);
        defer item.deinit();
        try item.add(line[start..]);
        // Continuation lines: indented further, and not a new bullet.
        while (self.peek()) |continuation| {
            if (continuation.len == 0) break;
            if (bullet(continuation) != null) break;
            if (leading(continuation) <= indent) break;
            try item.addByte(' ');
            try item.add(std.mem.trim(u8, continuation, " "));
            self.cursor += 1;
        }

        try self.out.add("<li>");
        try inline_(self, item.text());
        // A nested list belongs inside the item it hangs off.
        if (self.peek()) |following| {
            if (following.len != 0 and bullet(following) != null and
                leading(following) > indent and depth < 3)
            {
                try list(self, depth + 1);
            }
        }
        try self.out.add("</li>\n");
    }
    try self.out.print("</{s}>\n", .{tag});
}

fn paragraph(self: *Renderer) !void {
    var text: Buffer = .init(self.gpa);
    defer text.deinit();
    while (self.peek()) |line| {
        if (line.len == 0) break;
        if (std.mem.startsWith(u8, line, "```")) break;
        if (headingLevel(line) != null) break;
        if (std.mem.startsWith(u8, line, "> ")) break;
        if (line[0] == '|') break;
        if (std.mem.eql(u8, line, "---")) break;
        if (bullet(line) != null) break;
        if (text.text().len != 0) try text.addByte(' ');
        try text.add(std.mem.trim(u8, line, " "));
        self.cursor += 1;
    }
    try self.out.add("<p>");
    try inline_(self, text.text());
    try self.out.add("</p>\n");
}

// ---------------------------------------------------------------------------
// Inline
// ---------------------------------------------------------------------------

fn inline_(self: *Renderer, text: []const u8) !void {
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];

        if (byte == '`') {
            const close = std.mem.indexOfScalarPos(u8, text, index + 1, '`') orelse {
                try self.out.addEscaped(text[index .. index + 1]);
                index += 1;
                continue;
            };
            try self.out.add("<code>");
            try self.out.addEscaped(text[index + 1 .. close]);
            try self.out.add("</code>");
            index = close + 1;
            continue;
        }

        if (byte == '[') {
            if (linkAt(text, index)) |found| {
                const external = std.mem.startsWith(u8, found.target, "http");
                try self.out.add("<a href=\"");
                try self.out.addEscaped(found.target);
                if (external) {
                    try self.out.add("\" rel=\"noreferrer\">");
                } else {
                    try self.out.add("\">");
                }
                try inline_(self, found.label);
                try self.out.add("</a>");
                index = found.end;
                continue;
            }
        }

        if (byte == '*') {
            const strong = index + 1 < text.len and text[index + 1] == '*';
            const marker: []const u8 = if (strong) "**" else "*";
            if (std.mem.indexOfPos(u8, text, index + marker.len, marker)) |close| {
                if (close > index + marker.len) {
                    try self.out.add(if (strong) "<strong>" else "<em>");
                    try inline_(self, text[index + marker.len .. close]);
                    try self.out.add(if (strong) "</strong>" else "</em>");
                    index = close + marker.len;
                    continue;
                }
            }
        }

        try self.out.addEscaped(text[index .. index + 1]);
        index += 1;
    }
}

const Link = struct { label: []const u8, target: []const u8, end: usize };

fn linkAt(text: []const u8, start: usize) ?Link {
    const label_end = std.mem.indexOfScalarPos(u8, text, start + 1, ']') orelse return null;
    if (label_end + 1 >= text.len or text[label_end + 1] != '(') return null;
    const target_end = std.mem.indexOfScalarPos(u8, text, label_end + 2, ')') orelse return null;
    return .{
        .label = text[start + 1 .. label_end],
        .target = text[label_end + 2 .. target_end],
        .end = target_end + 1,
    };
}

// ---------------------------------------------------------------------------
// Anchors
// ---------------------------------------------------------------------------

/// A stable, readable id for a heading: lowercase, words joined with
/// `-`, and a numeric suffix if the page says the same thing twice.
fn slug(gpa: Allocator, text: []const u8, taken: []const Heading) ![]u8 {
    var base: std.ArrayList(u8) = .empty;
    defer base.deinit(gpa);
    var previous_dash = true;
    for (text) |byte| {
        if (std.ascii.isAlphanumeric(byte)) {
            try base.append(gpa, std.ascii.toLower(byte));
            previous_dash = false;
        } else if (!previous_dash) {
            try base.append(gpa, '-');
            previous_dash = true;
        }
    }
    while (base.items.len > 0 and base.items[base.items.len - 1] == '-') {
        _ = base.pop();
    }
    if (base.items.len == 0) try base.appendSlice(gpa, "section");

    var candidate = try gpa.dupe(u8, base.items);
    var suffix: usize = 2;
    while (true) {
        var clash = false;
        for (taken) |heading| {
            if (std.mem.eql(u8, heading.id, candidate)) clash = true;
        }
        if (!clash) return candidate;
        gpa.free(candidate);
        candidate = try std.fmt.allocPrint(gpa, "{s}-{d}", .{ base.items, suffix });
        suffix += 1;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "a document reports its title and renders paragraphs and inline marks" {
    const gpa = std.testing.allocator;
    var document = try render(gpa,
        \\# Title
        \\
        \\A **bold** and *slanted* line with `code` and a
        \\[link](/start/).
        \\
    , null);
    defer document.deinit(gpa);

    try std.testing.expectEqualStrings("Title", document.title);
    try std.testing.expect(std.mem.indexOf(u8, document.html, "<strong>bold</strong>") != null);
    try std.testing.expect(std.mem.indexOf(u8, document.html, "<em>slanted</em>") != null);
    try std.testing.expect(std.mem.indexOf(u8, document.html, "<code>code</code>") != null);
    try std.testing.expect(std.mem.indexOf(u8, document.html, "href=\"/start/\"") != null);
}

test "headings carry stable, unique anchors" {
    const gpa = std.testing.allocator;
    var document = try render(gpa,
        \\# Title
        \\
        \\## Values and references
        \\
        \\## Values and references
        \\
    , null);
    defer document.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), document.headings.len);
    try std.testing.expectEqualStrings("values-and-references", document.headings[0].id);
    try std.testing.expectEqualStrings("values-and-references-2", document.headings[1].id);
}

test "lists, tables and quotes render" {
    const gpa = std.testing.allocator;
    var document = try render(gpa,
        \\# Title
        \\
        \\- one
        \\- two
        \\    - nested
        \\
        \\1. first
        \\2. second
        \\
        \\| a | b |
        \\|---|---|
        \\| 1 | 2 |
        \\
        \\> a quote
        \\
    , null);
    defer document.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, document.html, "<li>one</li>") != null);
    try std.testing.expect(std.mem.indexOf(u8, document.html, "<li>nested</li>") != null);
    try std.testing.expect(std.mem.indexOf(u8, document.html, "<ol>") != null);
    try std.testing.expect(std.mem.indexOf(u8, document.html, "<th>a</th>") != null);
    try std.testing.expect(std.mem.indexOf(u8, document.html, "<td>2</td>") != null);
    try std.testing.expect(std.mem.indexOf(u8, document.html, "<blockquote><p>a quote</p>") != null);
}

test "a heading may fix its own anchor" {
    const gpa = std.testing.allocator;
    var document = try render(gpa,
        \\# Title
        \\
        \\## M11 — constants live in the program root {#m11}
        \\
    , null);
    defer document.deinit(gpa);
    try std.testing.expectEqualStrings("m11", document.headings[0].id);
    try std.testing.expectEqualStrings("M11 — constants live in the program root", document.headings[0].title);
}

test "a document without a leading heading is refused" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.MissingTitle, render(gpa, "no title here\n", null));
}
