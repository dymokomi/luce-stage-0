//! The documentation site generator: Markdown in, a static tree out,
//! and every Luce sample compiled and run on the way through.
//!
//!   lucedoc --content DIR --assets DIR --out DIR --toolchain DIR --work DIR
//!
//! It fails, loudly and completely, if any sample stops doing what its
//! page says it does — that is the whole reason it exists rather than
//! a Makefile and a pile of HTML.  It also refuses to finish with a
//! dead link, because a documentation site that cannot be walked is
//! not documentation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Buffer = @import("buffer.zig");
const markdown = @import("markdown.zig");
const page = @import("page.zig");
const site = @import("site.zig");
const verify = @import("verify.zig");

/// A rendered page, kept until the link check has seen every other one.
const Built = struct {
    /// Path under the output root, e.g. `tour/hello/index.html`.
    path: []u8,
    url: []u8,
    title: []u8,
    section: []const u8,
    blurb: []const u8,
    html: []u8,
    headings: []markdown.Heading,
    /// Line the page's source began at, for messages: the file itself.
    source: []u8,
};

const Options = struct {
    content: []const u8 = "content",
    assets: []const u8 = "assets",
    out: []const u8 = "out",
    toolchain: []const u8 = "../build",
    work: []const u8 = "work",
    repository: []const u8 = "..",
};

pub fn main(init: std.process.Init.Minimal) !u8 {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{
        .environ = init.environ,
        .argv0 = .init(init.args),
    });
    defer threaded.deinit();
    const io = threaded.io();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const arguments = try init.args.toSlice(arena);

    var options: Options = .{};
    var index: usize = 1;
    while (index + 1 < arguments.len) : (index += 2) {
        const flag = arguments[index];
        const value = arguments[index + 1];
        if (std.mem.eql(u8, flag, "--content")) options.content = value else if (std.mem.eql(u8, flag, "--assets")) options.assets = value else if (std.mem.eql(u8, flag, "--out")) options.out = value else if (std.mem.eql(u8, flag, "--toolchain")) options.toolchain = value else if (std.mem.eql(u8, flag, "--work")) options.work = value else if (std.mem.eql(u8, flag, "--repository")) options.repository = value else {
            std.debug.print("lucedoc: unknown option {s}\n", .{flag});
            return 2;
        }
    }

    return generate(gpa, io, options) catch |failure| {
        std.debug.print("lucedoc: {s}\n", .{@errorName(failure)});
        return 1;
    };
}

fn generate(gpa: Allocator, io: Io, options: Options) !u8 {
    const cwd = Io.Dir.cwd();

    // A build starts from nothing.  Anything left from a page that was
    // deleted or renamed is a dead link waiting to be published — and
    // a *swallowed* failure to clear it is worse than the stale page,
    // because the link check would then pass against the leftovers and
    // the deploy would put them back up.  So it stops the build.
    try clear(io, cwd, options.out);
    try clear(io, cwd, options.work);
    try cwd.createDirPath(io, options.out);
    try cwd.createDirPath(io, options.work);

    var verifier: verify.Verifier = .{
        .gpa = gpa,
        .io = io,
        .toolchain = options.toolchain,
        .work = options.work,
        .repository = options.repository,
    };
    defer verifier.deinit();

    var built: std.ArrayList(Built) = .empty;
    defer {
        for (built.items) |item| release(gpa, item);
        built.deinit(gpa);
    }

    // The home page, then every section: its overview, then its pages.
    try build(gpa, io, options, &verifier, &built, .{
        .source = "index.md",
        .url = "/",
        .section = null,
        .entry = null,
    });
    for (&site.sections) |*section| {
        const overview = try std.fmt.allocPrint(gpa, "{s}/index.md", .{section.slug});
        defer gpa.free(overview);
        const url = try std.fmt.allocPrint(gpa, "/{s}/", .{section.slug});
        defer gpa.free(url);
        try build(gpa, io, options, &verifier, &built, .{
            .source = overview,
            .url = url,
            .section = section,
            .entry = null,
        });
        for (section.pages) |*entry| {
            const source = try std.fmt.allocPrint(gpa, "{s}/{s}.md", .{ section.slug, entry.slug });
            defer gpa.free(source);
            const here = try std.fmt.allocPrint(gpa, "/{s}/{s}/", .{ section.slug, entry.slug });
            defer gpa.free(here);
            try build(gpa, io, options, &verifier, &built, .{
                .source = source,
                .url = here,
                .section = section,
                .entry = entry,
            });
        }
    }

    try copyAssets(gpa, io, options);
    try writeSearchIndex(gpa, io, options, built.items);

    const dead = try checkLinks(gpa, io, options, built.items);

    // ---- the report -------------------------------------------------
    const counts = verifier.counts;
    std.debug.print(
        "lucedoc: {d} pages, {d} samples verified ({d} run, {d} trap, {d} raise, {d} refused, {d} shell)\n",
        .{ built.items.len, counts.total(), counts.run, counts.trap, counts.raise, counts.fail, counts.console },
    );

    if (verifier.failures.items.len == 0 and dead == 0) {
        std.debug.print("lucedoc: every sample matches its page, every link resolves\n", .{});
        return 0;
    }
    for (verifier.failures.items) |failure| {
        std.debug.print("\n{s}:{d}: {s}\n", .{ failure.page, failure.line, failure.reason });
    }
    std.debug.print(
        "\nlucedoc: FAILED — {d} sample(s) do not do what their page says, {d} dead link(s)\n",
        .{ verifier.failures.items.len, dead },
    );
    return 1;
}

/// Remove a directory and everything under it.  A tree that was never
/// there is the ordinary first-build case, and `deleteTree` already
/// counts that as done; anything it does report is a real failure and
/// stops the build with the reason.
fn clear(io: Io, cwd: Io.Dir, path: []const u8) !void {
    cwd.deleteTree(io, path) catch |failure| {
        std.debug.print(
            "lucedoc: cannot clear {s}: {s} — a build must start from nothing\n",
            .{ path, @errorName(failure) },
        );
        return failure;
    };
}

fn release(gpa: Allocator, item: Built) void {
    gpa.free(item.path);
    gpa.free(item.url);
    gpa.free(item.title);
    gpa.free(item.html);
    gpa.free(item.source);
    for (item.headings) |heading| {
        gpa.free(heading.id);
        gpa.free(heading.title);
    }
    gpa.free(item.headings);
}

const Target = struct {
    source: []const u8,
    url: []const u8,
    section: ?*const site.Section,
    entry: ?*const site.Page,
};

fn build(
    gpa: Allocator,
    io: Io,
    options: Options,
    verifier: *verify.Verifier,
    built: *std.ArrayList(Built),
    target: Target,
) !void {
    const source_path = try std.fs.path.join(gpa, &.{ options.content, target.source });
    defer gpa.free(source_path);
    const text = Io.Dir.cwd().readFileAlloc(io, source_path, gpa, .unlimited) catch |failure| {
        std.debug.print("lucedoc: cannot read {s}: {s}\n", .{ source_path, @errorName(failure) });
        return failure;
    };
    defer gpa.free(text);

    verifier.startPage(source_path);
    var document = markdown.render(gpa, text, verifier.sink()) catch |failure| {
        std.debug.print("lucedoc: {s}: {s}\n", .{ source_path, @errorName(failure) });
        return failure;
    };
    errdefer document.deinit(gpa);

    // A page's own heading and its row in the table must agree, so the
    // sidebar can never say one thing and the page another.
    const expected: []const u8 = if (target.entry) |entry|
        entry.title
    else if (target.section) |section| section.title else document.title;
    if (!std.mem.eql(u8, expected, document.title)) {
        std.debug.print(
            "lucedoc: {s}: the page is titled \"{s}\" but site.zig says \"{s}\"\n",
            .{ source_path, document.title, expected },
        );
        return error.TitleMismatch;
    }

    const blurb: []const u8 = if (target.entry) |entry|
        entry.blurb
    else if (target.section) |section| section.blurb else "Luce is a small, statically typed language with no garbage collector and no reference counting.";

    var out: Buffer = .init(gpa);
    defer out.deinit();

    const neighbours = try surroundings(gpa, target);
    defer freeNeighbours(gpa, neighbours);
    try page.open(&out, .{
        .url = target.url,
        .title = document.title,
        .description = blurb,
        .section = target.section,
        .page = target.entry,
        .previous = neighbours.previous,
        .next = neighbours.next,
    }, document.headings);
    try out.add(document.html);
    gpa.free(document.html);
    document.html = &.{};
    if (target.section) |section| {
        if (target.entry == null) try cards(&out, section);
    } else {
        try doors(&out);
    }
    try page.close(&out, .{
        .url = target.url,
        .title = document.title,
        .description = blurb,
        .section = target.section,
        .page = target.entry,
        .previous = neighbours.previous,
        .next = neighbours.next,
    }, document.headings);

    const relative = if (std.mem.eql(u8, target.url, "/"))
        try gpa.dupe(u8, "index.html")
    else
        try std.fmt.allocPrint(gpa, "{s}index.html", .{target.url[1..]});
    errdefer gpa.free(relative);

    const full = try std.fs.path.join(gpa, &.{ options.out, relative });
    defer gpa.free(full);
    if (std.fs.path.dirname(full)) |directory| try Io.Dir.cwd().createDirPath(io, directory);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = full, .data = out.text() });

    try built.append(gpa, .{
        .path = relative,
        .url = try gpa.dupe(u8, target.url),
        .title = document.title,
        .section = if (target.section) |section| section.label else "Luce",
        .blurb = blurb,
        .html = try out.take(),
        .headings = document.headings,
        .source = try gpa.dupe(u8, source_path),
    });
}

const Neighbours = struct { previous: ?page.Link = null, next: ?page.Link = null };

/// Reading order inside a section: overview, then each page in turn.
/// Link targets are allocated from `gpa`; `release` frees them.
fn surroundings(gpa: Allocator, target: Target) !Neighbours {
    const section = target.section orelse return .{};
    if (section.pages.len == 0) return .{};

    if (target.entry) |entry| {
        for (section.pages, 0..) |*candidate, position| {
            if (candidate != entry) continue;
            var found: Neighbours = .{};
            if (position == 0) {
                found.previous = .{ .url = try gpa.dupe(u8, "../"), .title = section.title };
            } else {
                const before = section.pages[position - 1];
                found.previous = .{
                    .url = try std.fmt.allocPrint(gpa, "../{s}/", .{before.slug}),
                    .title = before.title,
                };
            }
            if (position + 1 < section.pages.len) {
                const after = section.pages[position + 1];
                found.next = .{
                    .url = try std.fmt.allocPrint(gpa, "../{s}/", .{after.slug}),
                    .title = after.title,
                };
            }
            return found;
        }
        return .{};
    }
    return .{ .next = .{
        .url = try std.fmt.allocPrint(gpa, "{s}/", .{section.pages[0].slug}),
        .title = section.pages[0].title,
    } };
}

fn freeNeighbours(gpa: Allocator, neighbours: Neighbours) void {
    if (neighbours.previous) |link| gpa.free(link.url);
    if (neighbours.next) |link| gpa.free(link.url);
}

/// The home page ends with one card per section — the whole site in
/// six lines, so nobody has to guess which door is theirs.
fn doors(out: *Buffer) !void {
    try out.add("<div class=\"cards doors\">\n");
    for (&site.sections) |*section| {
        try out.print("<a class=\"card\" href=\"{s}/\"><strong>", .{section.slug});
        try out.addEscaped(section.title);
        try out.add("</strong><span>");
        try out.addEscaped(section.blurb);
        try out.add("</span></a>\n");
    }
    try out.add("</div>\n");
}

/// The list of pages a section overview ends with.
fn cards(out: *Buffer, section: *const site.Section) !void {
    if (section.pages.len == 0) return;
    try out.add("<div class=\"cards\">\n");
    for (section.pages) |entry| {
        try out.print("<a class=\"card\" href=\"{s}/\"><strong>", .{entry.slug});
        try out.addEscaped(entry.title);
        try out.add("</strong><span>");
        try out.addEscaped(entry.blurb);
        try out.add("</span></a>\n");
    }
    try out.add("</div>\n");
}

// ---------------------------------------------------------------------------
// Assets and search
// ---------------------------------------------------------------------------

fn copyAssets(gpa: Allocator, io: Io, options: Options) !void {
    const destination = try std.fs.path.join(gpa, &.{ options.out, "assets" });
    defer gpa.free(destination);
    try Io.Dir.cwd().createDirPath(io, destination);

    var directory = try Io.Dir.cwd().openDir(io, options.assets, .{ .iterate = true });
    defer directory.close(io);
    var walk = directory.iterate();
    while (try walk.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const from = try std.fs.path.join(gpa, &.{ options.assets, entry.name });
        defer gpa.free(from);
        const to = try std.fs.path.join(gpa, &.{ destination, entry.name });
        defer gpa.free(to);
        const bytes = try Io.Dir.cwd().readFileAlloc(io, from, gpa, .unlimited);
        defer gpa.free(bytes);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = to, .data = bytes });
    }
}

/// Search runs in the browser over this: one row per page, with its
/// headings, as a plain JavaScript array.  A few tens of kilobytes for
/// a site this size, and no server to ask.
fn writeSearchIndex(gpa: Allocator, io: Io, options: Options, pages: []const Built) !void {
    var out: Buffer = .init(gpa);
    defer out.deinit();
    try out.add("window.LUCE_SEARCH=[\n");
    for (pages) |item| {
        try out.add("{u:");
        try json(&out, item.url);
        try out.add(",t:");
        try json(&out, item.title);
        try out.add(",s:");
        try json(&out, item.section);
        try out.add(",b:");
        try json(&out, item.blurb);
        try out.add(",h:[");
        var first = true;
        for (item.headings) |heading| {
            if (heading.level > 3) continue;
            if (!first) try out.addByte(',');
            first = false;
            try out.add("[");
            try json(&out, heading.title);
            try out.add(",");
            try json(&out, heading.id);
            try out.add("]");
        }
        try out.add("]},\n");
    }
    try out.add("];\n");

    const path = try std.fs.path.join(gpa, &.{ options.out, "search-index.js" });
    defer gpa.free(path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.text() });
}

fn json(out: *Buffer, text: []const u8) !void {
    try out.addByte('"');
    for (text) |byte| switch (byte) {
        '"' => try out.add("\\\""),
        '\\' => try out.add("\\\\"),
        '\n' => try out.add("\\n"),
        '<' => try out.add("\\u003c"),
        else => try out.addByte(byte),
    };
    try out.addByte('"');
}

// ---------------------------------------------------------------------------
// Links
// ---------------------------------------------------------------------------

/// Every `href` on every generated page must resolve to a file in the
/// output tree, and every fragment must name an id on the page it
/// points at.  Returns how many did not.
///
/// It scans the **rendered HTML**, not the Markdown, and that is the
/// point: most of a page's links are not in its source at all — the
/// nav, the sidebar, the section cards, the previous/next pair and the
/// assets are all written by `page.zig`, and a dead link in the shell
/// is as dead as one in a paragraph.
fn checkLinks(gpa: Allocator, io: Io, options: Options, pages: []const Built) !usize {
    var dead: usize = 0;
    for (pages) |item| {
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, item.html, cursor, "href=\"")) |found| {
            const start = found + "href=\"".len;
            const end = std.mem.indexOfScalarPos(u8, item.html, start, '"') orelse break;
            cursor = end + 1;
            const href = item.html[start..end];
            if (href.len == 0) continue;
            if (std.mem.startsWith(u8, href, "http")) continue;
            if (std.mem.startsWith(u8, href, "mailto:")) continue;

            const hash = std.mem.indexOfScalar(u8, href, '#');
            const path = if (hash) |at| href[0..at] else href;
            const fragment = if (hash) |at| href[at + 1 ..] else "";

            // A same-page fragment is checked against this page; every
            // other link is checked against the file it names, which
            // has to exist before its anchors can.
            var loaded: ?[]u8 = null;
            defer if (loaded) |bytes| gpa.free(bytes);
            if (path.len != 0) {
                const resolved = try resolve(gpa, item.path, path);
                defer gpa.free(resolved);
                const target = try std.fs.path.join(gpa, &.{ options.out, resolved });
                defer gpa.free(target);
                loaded = Io.Dir.cwd().readFileAlloc(io, target, gpa, .unlimited) catch {
                    std.debug.print("lucedoc: {s}: dead link \"{s}\" (no {s})\n", .{ item.source, href, resolved });
                    dead += 1;
                    continue;
                };
            }
            if (fragment.len == 0) continue;

            const holder: []const u8 = loaded orelse item.html;
            const anchor = try std.fmt.allocPrint(gpa, "id=\"{s}\"", .{fragment});
            defer gpa.free(anchor);
            if (std.mem.indexOf(u8, holder, anchor) == null) {
                std.debug.print("lucedoc: {s}: dead anchor \"{s}\"\n", .{ item.source, href });
                dead += 1;
            }
        }
    }
    return dead;
}

/// Resolve `href` against the directory holding `from`, and turn a
/// directory URL into the index file that serves it.
fn resolve(gpa: Allocator, from: []const u8, href: []const u8) ![]u8 {
    var target: std.ArrayList(u8) = .empty;
    defer target.deinit(gpa);

    if (std.mem.startsWith(u8, href, "/")) {
        try target.appendSlice(gpa, href[1..]);
    } else {
        const base = std.fs.path.dirname(from) orelse "";
        // `std.fs.path.resolve` wants absolute-looking input; a manual
        // walk keeps everything relative to the output root.
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(gpa);
        var walk = std.mem.tokenizeScalar(u8, base, '/');
        while (walk.next()) |part| try parts.append(gpa, part);
        var steps = std.mem.tokenizeScalar(u8, href, '/');
        while (steps.next()) |step| {
            if (std.mem.eql(u8, step, ".")) continue;
            if (std.mem.eql(u8, step, "..")) {
                if (parts.items.len > 0) _ = parts.pop();
                continue;
            }
            try parts.append(gpa, step);
        }
        for (parts.items, 0..) |part, index| {
            if (index != 0) try target.append(gpa, '/');
            try target.appendSlice(gpa, part);
        }
        if (std.mem.endsWith(u8, href, "/")) try target.append(gpa, '/');
    }

    if (target.items.len == 0 or target.items[target.items.len - 1] == '/') {
        try target.appendSlice(gpa, "index.html");
    }
    return target.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "links resolve against the page that carries them" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { from: []const u8, href: []const u8, want: []const u8 }{
        .{ .from = "index.html", .href = "tour/", .want = "tour/index.html" },
        .{ .from = "tour/hello/index.html", .href = "../values/", .want = "tour/values/index.html" },
        .{ .from = "tour/hello/index.html", .href = "../../ref/types/", .want = "ref/types/index.html" },
        .{ .from = "tour/index.html", .href = "/status/", .want = "status/index.html" },
        .{ .from = "tour/hello/index.html", .href = "../../assets/style.css", .want = "assets/style.css" },
    };
    for (cases) |case| {
        const got = try resolve(gpa, case.from, case.href);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(case.want, got);
    }
}

test "the generator's own units" {
    // `main` too, and not for the sake of running it: a test build
    // analyzes only what a test reaches, so without this line
    // everything from `main` down — the whole generator — would be
    // *compiled by nobody* under `zig build test`, and only the units
    // below would be checked at all.
    _ = &main;
    _ = @import("buffer.zig");
    _ = @import("coverage.zig");
    _ = @import("highlight.zig");
    _ = @import("markdown.zig");
    _ = @import("page.zig");
    _ = @import("site.zig");
    _ = @import("verify.zig");
}
