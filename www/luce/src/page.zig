//! The HTML shell every page is poured into.
//!
//! One template, written out longhand.  There is no layout engine and
//! no partial system, because there is one layout: a header bar, the
//! section's pages down the left, the content in the middle, and the
//! page's own headings down the right where there is room for them.
//!
//! Everything the browser loads is served from this origin — the shared
//! LuciaOS stylesheet, this site's frame, one small script, one SVG mark.
//! No fonts, no CDN, no analytics, nothing that phones anywhere.

const std = @import("std");
const Buffer = @import("buffer.zig");
const markdown = @import("markdown.zig");
const site = @import("site.zig");

pub const Where = struct {
    /// URL path, always beginning and ending with `/` except the root.
    url: []const u8,
    title: []const u8,
    description: []const u8,
    /// Null on the home page.
    section: ?*const site.Section,
    /// Null on a section index.
    page: ?*const site.Page,
    previous: ?Link = null,
    next: ?Link = null,
};

pub const Link = struct { url: []const u8, title: []const u8 };

/// Depth of `url` below the root, for the relative asset prefix.  The
/// site is served from a domain root, but keeping the links relative
/// means the `out/` tree also opens correctly from a file:// path,
/// which is how anyone previews a change.
fn upTo(url: []const u8) usize {
    var depth: usize = 0;
    for (url) |byte| {
        if (byte == '/') depth += 1;
    }
    return if (depth >= 2) depth - 1 else 0;
}

fn prefix(out: *Buffer, url: []const u8) !void {
    var remaining = upTo(url);
    if (remaining == 0) {
        try out.add("./");
        return;
    }
    while (remaining > 0) : (remaining -= 1) try out.add("../");
}

pub fn open(out: *Buffer, where: Where, headings: []const markdown.Heading) !void {
    try out.add(
        \\<!doctype html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1">
        \\<title>
    );
    try out.addEscaped(where.title);
    if (!std.mem.eql(u8, where.url, "/")) try out.add(" &middot; Luce");
    try out.add("</title>\n<meta name=\"description\" content=\"");
    try out.addEscaped(where.description);
    try out.add("\">\n<link rel=\"stylesheet\" href=\"");
    try prefix(out, where.url);
    try out.add("assets/core.css\">\n<link rel=\"stylesheet\" href=\"");
    try prefix(out, where.url);
    try out.add("assets/style.css\">\n<link rel=\"icon\" href=\"");
    try prefix(out, where.url);
    try out.add("assets/mark.svg\" type=\"image/svg+xml\">\n");
    // Applied before first paint so a chosen theme never flashes.
    try out.add(
        \\<script>try{var t=localStorage.getItem("luce-theme");if(t)document.documentElement.dataset.theme=t}catch(e){}</script>
        \\</head>
        \\<body>
        \\<a class="skip" href="#content">Skip to content</a>
        \\
    );

    try header(out, where);
    // Every page has the same shape: the list column on the left, the
    // content beside it.  A page with no section list (the home page)
    // fills that column with its own headings instead, in the same
    // dress, so the left rail never jumps sides or changes style.
    try out.add("<div class=\"shell\">\n");
    try sidebar(out, where, headings);
    try out.add("<main id=\"content\">\n<article>\n<h1>");
    try out.addEscaped(where.title);
    try out.add("</h1>\n");
}

pub fn close(out: *Buffer, where: Where, headings: []const markdown.Heading) !void {
    try out.add("</article>\n");

    if (where.previous != null or where.next != null) {
        try out.add("<nav class=\"seq\">\n");
        if (where.previous) |link| {
            try out.add("<a class=\"back\" href=\"");
            try out.addEscaped(link.url);
            try out.add("\"><span>Previous</span>");
            try out.addEscaped(link.title);
            try out.add("</a>\n");
        } else try out.add("<span></span>\n");
        if (where.next) |link| {
            try out.add("<a class=\"on\" href=\"");
            try out.addEscaped(link.url);
            try out.add("\"><span>Next</span>");
            try out.addEscaped(link.title);
            try out.add("</a>\n");
        }
        try out.add("</nav>\n");
    }

    try out.add("</main>\n");
    // A bare page already carries its headings in the left column.
    const bare = where.section == null or where.section.?.pages.len == 0;
    if (bare) {
        try out.add("<div class=\"rail\"></div>\n");
    } else {
        try onThisPage(out, headings);
    }
    try out.add("</div>\n");

    try out.add(
        \\<footer>
        \\<p>Luce is part of LuciaOS. Every Luce sample on this site was checked by the freshly built toolchain; runnable output and expected failure results are verified separately.</p>
        \\</footer>
        \\<script src="
    );
    try prefix(out, where.url);
    try out.add("assets/site.js\" defer></script>\n<script src=\"");
    try prefix(out, where.url);
    try out.add("search-index.js\" defer></script>\n</body>\n</html>\n");
}

fn header(out: *Buffer, where: Where) !void {
    try out.add("<header class=\"top\">\n<a class=\"mark\" href=\"");
    try prefix(out, where.url);
    try out.add("\">Luce</a>\n<nav class=\"tabs\">\n");
    for (&site.sections) |*section| {
        const current = where.section != null and where.section.? == section;
        try out.add(if (current) "<a class=\"here\" href=\"" else "<a href=\"");
        try prefix(out, where.url);
        try out.print("{s}/\">{s}</a>\n", .{ section.slug, section.label });
    }
    try out.add(
        \\</nav>
        \\<div class="tools">
        \\<label class="find"><span class="sr">Search</span><input id="q" type="search" placeholder="Search" autocomplete="off"></label>
        \\<a class="cross" href="https://lucelang.org">Engineering</a>
        \\<a class="cross" href="https://loom.luciaos.com">loom</a>
        \\<a class="cross" href="https://luciaos.com">LuciaOS</a>
        \\<button id="theme" type="button" aria-label="Switch between light and dark">◑</button>
        \\</div>
        \\<div id="hits" hidden></div>
        \\</header>
        \\
    );
}

fn sidebar(out: *Buffer, where: Where, headings: []const markdown.Heading) !void {
    const section = where.section orelse {
        try headingsAside(out, headings);
        return;
    };
    if (section.pages.len == 0) {
        try headingsAside(out, headings);
        return;
    }

    try out.add("<div class=\"side\">\n<details class=\"nav\" open>\n<summary>");
    try out.addEscaped(section.title);
    try out.add("</summary>\n<ul>\n");

    const on_index = where.page == null;
    try out.add(if (on_index) "<li><a class=\"here\" href=\"" else "<li><a href=\"");
    try prefix(out, where.url);
    try out.print("{s}/\">Overview</a></li>\n", .{section.slug});

    var current_part: []const u8 = "";
    for (section.pages) |*page| {
        if (!std.mem.eql(u8, current_part, page.part)) {
            current_part = page.part;
            try out.add("<li class=\"part\">");
            try out.addEscaped(current_part);
            try out.add("</li>\n");
        }
        const current = where.page != null and where.page.? == page;
        try out.add(if (current) "<li><a class=\"here\" href=\"" else "<li><a href=\"");
        try prefix(out, where.url);
        try out.print("{s}/{s}/\">", .{ section.slug, page.slug });
        try out.addEscaped(page.title);
        try out.add("</a></li>\n");
    }
    try out.add("</ul>\n</details>\n</div>\n");
}

/// The left column of a page with no section list: its own headings,
/// in exactly the sidebar's dress, so the column reads the same on
/// every page of the site.
fn headingsAside(out: *Buffer, headings: []const markdown.Heading) !void {
    var shown: usize = 0;
    for (headings) |heading| {
        if (heading.level == 2 or heading.level == 3) shown += 1;
    }
    if (shown < 2) {
        try out.add("<div class=\"side\"></div>\n");
        return;
    }
    try out.add("<div class=\"side\">\n<details class=\"nav\" open>\n<summary>On this page</summary>\n<ul>\n");
    for (headings) |heading| {
        if (heading.level != 2 and heading.level != 3) continue;
        try out.print("<li class=\"h{d}\"><a href=\"#{s}\">", .{ heading.level, heading.id });
        try out.addEscaped(heading.title);
        try out.add("</a></li>\n");
    }
    try out.add("</ul>\n</details>\n</div>\n");
}

fn onThisPage(out: *Buffer, headings: []const markdown.Heading) !void {
    var shown: usize = 0;
    for (headings) |heading| {
        if (heading.level == 2 or heading.level == 3) shown += 1;
    }
    if (shown < 2) {
        try out.add("<div class=\"rail\"></div>\n");
        return;
    }
    try out.add("<div class=\"rail\"><nav aria-label=\"On this page\">\n<h2>On this page</h2>\n<ul>\n");
    for (headings) |heading| {
        if (heading.level != 2 and heading.level != 3) continue;
        try out.print("<li class=\"h{d}\"><a href=\"#{s}\">", .{ heading.level, heading.id });
        try out.addEscaped(heading.title);
        try out.add("</a></li>\n");
    }
    try out.add("</ul>\n</nav></div>\n");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "the asset prefix climbs exactly as far as the page is deep" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { url: []const u8, want: []const u8 }{
        .{ .url = "/", .want = "./" },
        .{ .url = "/guide/", .want = "../" },
        .{ .url = "/guide/basics/", .want = "../../" },
        .{ .url = "/guide/reference/types/", .want = "../../../" },
    };
    for (cases) |case| {
        var out: Buffer = .init(gpa);
        defer out.deinit();
        try prefix(&out, case.url);
        try std.testing.expectEqualStrings(case.want, out.text());
    }
}

test "the shared visual language loads before the documentation frame" {
    const gpa = std.testing.allocator;
    var out: Buffer = .init(gpa);
    defer out.deinit();
    try open(&out, .{
        .url = "/guide/basics/",
        .title = "The Basics",
        .description = "A page",
        .section = &site.sections[1],
        .page = &site.sections[1].pages[0],
    }, &.{});

    const core = std.mem.indexOf(u8, out.text(), "../../assets/core.css");
    const frame = std.mem.indexOf(u8, out.text(), "../../assets/style.css");
    try std.testing.expect(core != null);
    try std.testing.expect(frame != null);
    try std.testing.expect(core.? < frame.?);
}
