//! The one file the dashboard reads.
//!
//! Everything stats.luciaos.com draws comes out of here: a contiguous
//! run of days, a series per site per measure, the totals over the
//! window, and the top pages, referrers and countries.  The page does
//! no arithmetic beyond scaling a line to its box — if a number is
//! wrong it is wrong in this file, which is a much shorter thing to
//! check than a chart.
//!
//! The days are contiguous on purpose.  A database only holds rows for
//! days something happened, and a graph drawn straight from those rows
//! silently closes the gaps, so a quiet week looks like no week at
//! all.  Missing days are written out as zero.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const classify = @import("classify.zig");
const day = @import("day.zig");
const store_module = @import("store.zig");
const temporary = @import("temporary.zig");

const Store = store_module.Store;
const Kind = store_module.Kind;

pub const Options = struct {
    /// How many days the graphs cover.
    window: i64 = 90,
    /// How many days the top-of lists cover.
    recent: i64 = 30,
    /// How many rows in each top-of list.
    rows: usize = 12,
};

const sites = [_]classify.Site{ .luce, .loom, .luciaos };

fn title(site: classify.Site) []const u8 {
    return switch (site) {
        .luce => "luce.luciaos.com",
        .loom => "loom.luciaos.com",
        .luciaos => "luciaos.com",
    };
}

/// Build the report and write it to `path`.
pub fn write(
    gpa: Allocator,
    io: Io,
    store: Store,
    now: i64,
    options: Options,
    path: []const u8,
) !void {
    var out: Json = .{ .gpa = gpa };
    defer out.deinit();

    // The window, oldest day first, with every day present.
    var days: std.ArrayList([]const u8) = .empty;
    defer {
        for (days.items) |text| gpa.free(text);
        days.deinit(gpa);
    }
    var index: std.StringHashMapUnmanaged(usize) = .empty;
    defer index.deinit(gpa);

    var back: i64 = options.window - 1;
    while (back >= 0) : (back -= 1) {
        var buffer: day.Text = undefined;
        const text = try gpa.dupe(u8, day.before(&buffer, now, back));
        try index.put(gpa, text, days.items.len);
        try days.append(gpa, text);
    }
    const first = days.items[0];

    var recent_buffer: day.Text = undefined;
    const recent = day.before(&recent_buffer, now, options.recent - 1);

    try out.open('{');
    try out.number("generated", now);
    try out.number("window", options.window);
    try out.number("recent", options.recent);

    if (try earliest(gpa, store)) |since| {
        defer gpa.free(since);
        try out.string("since", since);
    } else {
        try out.raw("since", "null");
    }

    try out.key("days");
    try out.open('[');
    for (days.items) |text| try out.item(text);
    try out.close(']');

    // ------------------------------------------------------- series
    try out.key("sites");
    try out.open('[');
    for (sites) |site| {
        try out.begin();
        try out.open('{');
        try out.string("name", site.text());
        try out.string("title", title(site));
        for ([_][]const u8{ Kind.views, Kind.visitors, Kind.hits, Kind.robots, Kind.bytes }) |kind| {
            const series = try scalarSeries(gpa, store, site.text(), kind, first, index, days.items.len);
            defer gpa.free(series);
            try out.numbers(kind, series);
        }
        try out.close('}');
    }
    try out.close(']');

    // Distinct people across all three sites, counted once each — the
    // series behind the page's headline number.  Summing the three site
    // series instead would count a person per site they read.
    {
        const series = try scalarSeries(gpa, store, store_module.everywhere, Kind.visitors, first, index, days.items.len);
        defer gpa.free(series);
        try out.numbers("people", series);
    }

    // The install line is only on luce.luciaos.com today, but nothing
    // here assumes that: both are summed across every site.
    try out.key("installs");
    try out.open('{');
    for ([_]struct { name: []const u8, kind: []const u8 }{
        .{ .name = "script", .kind = Kind.install_script },
        .{ .name = "runs", .kind = Kind.install_run },
        .{ .name = "extension", .kind = Kind.extension },
    }) |measure| {
        const series = try scalarSeries(gpa, store, null, measure.kind, first, index, days.items.len);
        defer gpa.free(series);
        try out.numbers(measure.name, series);
    }
    try out.close('}');

    // ------------------------------------------------------- totals
    try out.key("totals");
    try out.open('{');
    for ([_][]const u8{
        Kind.views, Kind.visitors,       Kind.hits,        Kind.robots,
        Kind.bytes, Kind.install_script, Kind.install_run, Kind.extension,
    }) |kind| {
        // People are counted once, everywhere; everything else adds up.
        const scope: ?[]const u8 = if (std.mem.eql(u8, kind, Kind.visitors))
            store_module.everywhere
        else
            null;
        try out.number(kind, try total(store, kind, scope, first));
    }
    try out.close('}');

    // ---------------------------------------------------------- top
    try out.key("top");
    try out.open('{');

    try out.key("pages");
    try out.open('[');
    for (sites) |site| {
        var list = try topOf(gpa, store, Kind.page, site.text(), recent, options.rows);
        defer list.deinit(gpa);
        for (list.rows.items) |row| {
            try out.begin();
            try out.open('{');
            try out.string("site", site.text());
            try out.string("key", row.key);
            try out.number("count", row.count);
            try out.close('}');
        }
    }
    try out.close(']');

    for ([_]struct { name: []const u8, kind: []const u8 }{
        .{ .name = "referrers", .kind = Kind.referrer },
        .{ .name = "countries", .kind = Kind.country },
        .{ .name = "statuses", .kind = Kind.status },
    }) |list_of| {
        try out.key(list_of.name);
        try out.open('[');
        var list = try topOf(gpa, store, list_of.kind, null, recent, options.rows);
        defer list.deinit(gpa);
        for (list.rows.items) |row| {
            try out.begin();
            try out.open('{');
            try out.string("key", row.key);
            try out.number("count", row.count);
            try out.close('}');
        }
        try out.close(']');
    }

    try out.close('}');
    try out.close('}');
    try out.text.append(gpa, '\n');

    if (std.fs.path.dirname(path)) |directory| try Io.Dir.cwd().createDirPath(io, directory);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.text.items });
}

/// One measure, one number per day of the window.  `site` of null sums
/// every site.
fn scalarSeries(
    gpa: Allocator,
    store: Store,
    site: ?[]const u8,
    kind: []const u8,
    first: []const u8,
    index: std.StringHashMapUnmanaged(usize),
    length: usize,
) ![]i64 {
    const series = try gpa.alloc(i64, length);
    @memset(series, 0);
    errdefer gpa.free(series);

    var query = if (site == null)
        try store.connection.prepare(
            \\SELECT day, SUM(count) FROM daily
            \\WHERE kind = ? AND key = '' AND day >= ? AND site <> 'all' GROUP BY day
        )
    else
        try store.connection.prepare(
            \\SELECT day, SUM(count) FROM daily
            \\WHERE kind = ? AND key = '' AND day >= ? AND site = ? GROUP BY day
        );
    defer query.finish();

    try query.text(1, kind);
    try query.text(2, first);
    if (site) |name| try query.text(3, name);

    while (try query.step()) {
        const at = index.get(query.readText(0)) orelse continue;
        series[at] = query.readNumber(1);
    }
    return series;
}

/// The window's total for one measure.  `site` of null sums every real
/// site; naming one reads only that site — which is how `visitors`
/// avoids counting a person once per site they happened to read.
fn total(store: Store, kind: []const u8, site: ?[]const u8, first: []const u8) !i64 {
    var query = if (site == null)
        try store.connection.prepare(
            \\SELECT COALESCE(SUM(count), 0) FROM daily
            \\WHERE kind = ? AND key = '' AND day >= ? AND site <> 'all'
        )
    else
        try store.connection.prepare(
            \\SELECT COALESCE(SUM(count), 0) FROM daily
            \\WHERE kind = ? AND key = '' AND day >= ? AND site = ?
        );
    defer query.finish();
    try query.text(1, kind);
    try query.text(2, first);
    if (site) |name| try query.text(3, name);
    if (!try query.step()) return 0;
    return query.readNumber(0);
}

const Row = struct { key: []const u8, count: i64 };

/// The busiest keys of one kind, most first.  Rows borrow `gpa` and
/// are freed with the list.
fn topOf(
    gpa: Allocator,
    store: Store,
    kind: []const u8,
    site: ?[]const u8,
    since: []const u8,
    rows: usize,
) !List {
    var list: List = .{};
    errdefer list.deinit(gpa);

    var query = if (site == null)
        try store.connection.prepare(
            \\SELECT key, SUM(count) AS total FROM daily
            \\WHERE kind = ? AND key <> '' AND day >= ?
            \\GROUP BY key ORDER BY total DESC, key ASC LIMIT ?
        )
    else
        try store.connection.prepare(
            \\SELECT key, SUM(count) AS total FROM daily
            \\WHERE kind = ? AND key <> '' AND day >= ? AND site = ?
            \\GROUP BY key ORDER BY total DESC, key ASC LIMIT ?
        );
    defer query.finish();

    try query.text(1, kind);
    try query.text(2, since);
    if (site) |name| {
        try query.text(3, name);
        try query.number(4, @intCast(rows));
    } else {
        try query.number(3, @intCast(rows));
    }

    while (try query.step()) {
        try list.rows.append(gpa, .{
            .key = try gpa.dupe(u8, query.readText(0)),
            .count = query.readNumber(1),
        });
    }
    return list;
}

const List = struct {
    rows: std.ArrayList(Row) = .empty,

    fn deinit(self: *List, gpa: Allocator) void {
        for (self.rows.items) |row| gpa.free(row.key);
        self.rows.deinit(gpa);
    }
};

fn earliest(gpa: Allocator, store: Store) !?[]const u8 {
    var query = try store.connection.prepare("SELECT MIN(day) FROM daily");
    defer query.finish();
    if (!try query.step()) return null;
    const text = query.readText(0);
    if (text.len == 0) return null;
    return try gpa.dupe(u8, text);
}

// ---------------------------------------------------------------- JSON

/// Just enough JSON to write this one document, with commas handled
/// so no call site has to remember whether it is first.
const Json = struct {
    gpa: Allocator,
    text: std.ArrayList(u8) = .empty,
    fresh: bool = true,

    fn deinit(self: *Json) void {
        self.text.deinit(self.gpa);
    }

    fn open(self: *Json, brace: u8) !void {
        try self.text.append(self.gpa, brace);
        self.fresh = true;
    }

    fn close(self: *Json, brace: u8) !void {
        try self.text.append(self.gpa, brace);
        self.fresh = false;
    }

    /// A comma, unless this is the first thing in its container.
    fn begin(self: *Json) !void {
        if (!self.fresh) try self.text.append(self.gpa, ',');
        self.fresh = false;
    }

    fn key(self: *Json, name: []const u8) !void {
        try self.begin();
        try self.quote(name);
        try self.text.append(self.gpa, ':');
        self.fresh = true;
    }

    fn string(self: *Json, name: []const u8, value: []const u8) !void {
        try self.key(name);
        try self.quote(value);
        self.fresh = false;
    }

    fn number(self: *Json, name: []const u8, value: i64) !void {
        try self.key(name);
        try self.text.print(self.gpa, "{d}", .{value});
        self.fresh = false;
    }

    fn raw(self: *Json, name: []const u8, value: []const u8) !void {
        try self.key(name);
        try self.text.appendSlice(self.gpa, value);
        self.fresh = false;
    }

    fn numbers(self: *Json, name: []const u8, values: []const i64) !void {
        try self.key(name);
        try self.open('[');
        for (values) |value| {
            try self.begin();
            try self.text.print(self.gpa, "{d}", .{value});
        }
        try self.close(']');
    }

    /// One string in an array.
    fn item(self: *Json, value: []const u8) !void {
        try self.begin();
        try self.quote(value);
    }

    /// Page paths and referrer hosts come from requests, so every
    /// string written here is escaped, not just the ones that look
    /// like they need it.
    fn quote(self: *Json, value: []const u8) !void {
        try self.text.append(self.gpa, '"');
        for (value) |byte| switch (byte) {
            '"' => try self.text.appendSlice(self.gpa, "\\\""),
            '\\' => try self.text.appendSlice(self.gpa, "\\\\"),
            '\n' => try self.text.appendSlice(self.gpa, "\\n"),
            '\r' => try self.text.appendSlice(self.gpa, "\\r"),
            '\t' => try self.text.appendSlice(self.gpa, "\\t"),
            else => if (byte < 0x20) {
                try self.text.print(self.gpa, "\\u{x:0>4}", .{byte});
            } else {
                try self.text.append(self.gpa, byte);
            },
        };
        try self.text.append(self.gpa, '"');
    }
};

const testing = std.testing;

test "the report is valid JSON with a contiguous run of days" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var store = try Store.open(testing.allocator, ":memory:");
    defer store.deinit();

    const now: i64 = 1786655249; // 2026-08-13
    // Two days with traffic, four days apart, so the gap must be filled.
    try store.add("2026-08-13", "luce", Kind.views, "", 10);
    try store.add("2026-08-09", "luce", Kind.views, "", 4);
    try store.add("2026-08-13", "luce", Kind.visitors, "", 6);
    try store.add("2026-08-13", "loom", Kind.visitors, "", 3);
    // Seven people read one or both: not the nine the two sites sum to.
    try store.add("2026-08-13", "all", Kind.visitors, "", 7);
    try store.add("2026-08-13", "luce", Kind.page, "/guides/", 7);
    try store.add("2026-08-13", "luce", Kind.install_script, "", 3);
    try store.add("2026-08-13", "luce", Kind.install_run, "", 1);
    try store.add("2026-08-13", "loom", Kind.views, "", 2);
    try store.add("2026-08-13", "luce", Kind.referrer, "news.ycombinator.com", 5);
    try store.add("2026-08-13", "luce", Kind.country, "US", 8);

    var directory = testing.tmpDir(.{});
    defer directory.cleanup();
    const root = try temporary.path(arena, directory);
    const path = try std.fs.path.join(arena, &.{ root, "stats.json" });

    try write(testing.allocator, io, store, now, .{ .window = 7, .recent = 7 }, path);

    const text = try Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    const top = parsed.object;

    const days = top.get("days").?.array;
    try testing.expectEqual(@as(usize, 7), days.items.len);
    try testing.expectEqualStrings("2026-08-07", days.items[0].string);
    try testing.expectEqualStrings("2026-08-13", days.items[6].string);
    try testing.expectEqualStrings("2026-08-09", top.get("since").?.string);

    const luce = top.get("sites").?.array.items[0].object;
    try testing.expectEqualStrings("luce", luce.get("name").?.string);
    const views = luce.get("views").?.array;
    try testing.expectEqual(@as(usize, 7), views.items.len);
    try testing.expectEqual(@as(i64, 4), views.items[2].integer); // 08-09
    try testing.expectEqual(@as(i64, 0), views.items[3].integer); // 08-10, quiet
    try testing.expectEqual(@as(i64, 10), views.items[6].integer); // 08-13

    // Totals sum every site, installs sum every site too.
    // 10 and 4 on luce, 2 on loom: totals sum sites and days alike.
    try testing.expectEqual(@as(i64, 16), top.get("totals").?.object.get("views").?.integer);
    try testing.expectEqual(@as(i64, 3), top.get("installs").?.object.get("script").?.array.items[6].integer);

    const pages = top.get("top").?.object.get("pages").?.array;
    try testing.expectEqualStrings("/guides/", pages.items[0].object.get("key").?.string);
    try testing.expectEqualStrings("luce", pages.items[0].object.get("site").?.string);
    const referrers = top.get("top").?.object.get("referrers").?.array;
    try testing.expectEqualStrings("news.ycombinator.com", referrers.items[0].object.get("key").?.string);
}

test "an empty database still produces a readable report" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var store = try Store.open(testing.allocator, ":memory:");
    defer store.deinit();

    var directory = testing.tmpDir(.{});
    defer directory.cleanup();
    const root = try temporary.path(arena, directory);
    const path = try std.fs.path.join(arena, &.{ root, "stats.json" });

    try write(testing.allocator, io, store, 1786655249, .{ .window = 3 }, path);

    const text = try Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    try testing.expectEqual(std.json.Value.null, parsed.object.get("since").?);
    try testing.expectEqual(@as(usize, 3), parsed.object.get("days").?.array.items.len);
    try testing.expectEqual(@as(i64, 0), parsed.object.get("totals").?.object.get("views").?.integer);
    try testing.expectEqual(@as(usize, 0), parsed.object.get("top").?.object.get("pages").?.array.items.len);
}

test "a page path with a quote in it does not break the document" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var store = try Store.open(testing.allocator, ":memory:");
    defer store.deinit();
    try store.add("2026-08-13", "luce", Kind.page, "/a\"b\\c\nd", 1);

    var directory = testing.tmpDir(.{});
    defer directory.cleanup();
    const root = try temporary.path(arena, directory);
    const path = try std.fs.path.join(arena, &.{ root, "stats.json" });
    try write(testing.allocator, io, store, 1786655249, .{ .window = 2 }, path);

    const text = try Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    const pages = parsed.object.get("top").?.object.get("pages").?.array;
    try testing.expectEqualStrings("/a\"b\\c\nd", pages.items[0].object.get("key").?.string);
}
