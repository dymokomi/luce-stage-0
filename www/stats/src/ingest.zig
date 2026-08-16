//! Reading the access logs, once each, across rotation.
//!
//! Caddy writes to `<site>.log` until it reaches 20 MiB, then renames
//! it to `<site>-<timestamp>.log`, optionally gzips it, and starts a
//! new one.  So there are two jobs here: read the live file from where
//! the last run stopped, and read each rolled file exactly once.
//!
//! The live file is followed by inode *and* offset.  Offset alone is
//! the classic mistake: after a roll the new file starts at zero, and
//! a collector that resumed at the old offset would silently skip
//! everything before it — the failure would look like quiet days
//! rather than like a bug.  If the inode is not the one recorded, the
//! file is a different file and reading starts at the beginning.
//!
//! A rolled file is read whole and its name written down.  Names carry
//! the roll timestamp, so a name never comes back, and "have I read
//! this?" is a lookup rather than a guess.
//!
//! Partial lines are left alone: the live file is read only as far as
//! its last newline, and the offset stops there, so a line caught
//! half-written is read in full by the next run.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const access = @import("access.zig");
const classify = @import("classify.zig");
const day = @import("day.zig");
const geo = @import("geo.zig");
const store_module = @import("store.zig");
const temporary = @import("temporary.zig");

const Store = store_module.Store;
const Counters = store_module.Counters;
const Kind = store_module.Kind;

/// The live logs, one per Caddy `output file` in `logging.caddy`.
pub const live_logs = [_][]const u8{ "luce.log", "loom.log", "luciaos.log" };

pub const Summary = struct {
    files: usize = 0,
    lines: usize = 0,
    requests: usize = 0,
    /// Lines that parsed but named a host that is not ours.
    foreign: usize = 0,
    /// Lines that did not parse as a request at all.
    unreadable: usize = 0,
};

/// Read every log in `directory` that has not been read, counting what
/// is found into `store`.  `now` is the run's clock, used for the
/// bookkeeping timestamps and for deciding which days have closed.
pub fn run(
    gpa: Allocator,
    io: Io,
    store: Store,
    table: ?geo.Table,
    directory: []const u8,
    now: i64,
) !Summary {
    var summary: Summary = .{};

    var counters = Counters.init(gpa);
    defer counters.deinit();

    var salts: Salts = .{ .gpa = gpa, .io = io, .store = store };
    defer salts.deinit();

    // Rolled files first, and in name order: a roll is older than the
    // live file it was rolled out of, and its name sorts by time.
    var rolled = try rolledFiles(gpa, io, directory);
    defer {
        for (rolled.items) |name| gpa.free(name);
        rolled.deinit(gpa);
    }

    for (rolled.items) |name| {
        const path = try std.fs.path.join(gpa, &.{ directory, name });
        defer gpa.free(path);
        if (try store.wasIngested(path)) continue;

        const bytes = readWhole(gpa, io, path) catch |failure| {
            std.debug.print("stats: cannot read {s}: {s}\n", .{ path, @errorName(failure) });
            continue;
        };
        defer gpa.free(bytes);

        // This file was the live file until Caddy renamed it, and the
        // live cursor read most of it already.  Its inode is the same
        // one that cursor followed, so start where that stopped —
        // otherwise every roll would count its whole contents twice.
        var from: usize = 0;
        if (Io.Dir.cwd().statFile(io, path, .{})) |stat| {
            if (try store.offsetForInode(@intCast(stat.inode))) |offset| {
                from = @min(@as(usize, @intCast(offset)), bytes.len);
            }
        } else |_| {}

        _ = try consume(&counters, &salts, store, table, bytes[from..], false, &summary);
        try store.markIngested(path, now);
        summary.files += 1;
    }

    for (live_logs) |name| {
        const path = try std.fs.path.join(gpa, &.{ directory, name });
        defer gpa.free(path);

        const stat = Io.Dir.cwd().statFile(io, path, .{}) catch continue;
        const at = try store.cursor(path);

        const bytes = readWhole(gpa, io, path) catch |failure| {
            std.debug.print("stats: cannot read {s}: {s}\n", .{ path, @errorName(failure) });
            continue;
        };
        defer gpa.free(bytes);

        // A different file, or one that has shrunk, is read from the
        // start.  Same file, same or greater length: read what is new.
        const same = at.inode == @as(u64, @intCast(stat.inode)) and at.offset <= bytes.len;
        const from: usize = if (same) @intCast(at.offset) else 0;

        const used = try consume(&counters, &salts, store, table, bytes[from..], true, &summary);
        try store.setCursor(path, .{
            .inode = @intCast(stat.inode),
            .offset = from + used,
        }, now);
        summary.files += 1;
    }

    try counters.flush(store);
    try store.countVisitors();

    // Yesterday and everything before it is counted and closed: the
    // hashes that made those counts are no longer anybody's business,
    // including ours.  Today keeps its own, because it is still being
    // counted.
    var today: day.Text = undefined;
    try store.forgetBefore(day.write(&today, now));

    return summary;
}

/// Count one span of log.  When `partial_lines_wait` is true, a final
/// line with no newline is left for the next run and not counted; the
/// number of bytes actually consumed is returned.
fn consume(
    counters: *Counters,
    salts: *Salts,
    store: Store,
    table: ?geo.Table,
    bytes: []const u8,
    partial_lines_wait: bool,
    summary: *Summary,
) !usize {
    var arena_state = std.heap.ArenaAllocator.init(counters.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var used: usize = 0;
    var at: usize = 0;
    while (at < bytes.len) {
        const newline = std.mem.indexOfScalarPos(u8, bytes, at, '\n');
        const line = if (newline) |end| bytes[at..end] else bytes[at..];
        if (newline == null and partial_lines_wait) break;

        at = if (newline) |end| end + 1 else bytes.len;
        used = at;
        summary.lines += 1;

        _ = arena_state.reset(.retain_capacity);
        const record = access.parse(arena, line) orelse {
            if (std.mem.trim(u8, line, " \t\r").len != 0) summary.unreadable += 1;
            continue;
        };
        const site = classify.site(record.host) orelse {
            summary.foreign += 1;
            continue;
        };
        try count(counters, salts, store, table, site, record);
        summary.requests += 1;
    }
    return used;
}

fn count(
    counters: *Counters,
    salts: *Salts,
    store: Store,
    table: ?geo.Table,
    site: classify.Site,
    record: access.Record,
) !void {
    var buffer: day.Text = undefined;
    const today = day.write(&buffer, record.at);
    const name = site.text();

    const who = classify.agent(record.agent);
    try counters.add(today, name, Kind.hits, "", 1);
    try counters.add(today, name, Kind.agent, @tagName(who), 1);
    if (record.size > 0) try counters.add(today, name, Kind.bytes, "", record.size);

    var status_text: [3]u8 = undefined;
    _ = std.fmt.bufPrint(&status_text, "{d:0>3}", .{record.status}) catch unreachable;
    try counters.add(today, name, Kind.status, &status_text, 1);

    // A crawler is counted as traffic and as nothing else: it is not a
    // visitor, it did not read a page, and it is not installing.
    if (who == .robot) {
        try counters.add(today, name, Kind.robots, "", 1);
        return;
    }

    const path = classify.path(record.uri);
    const what = classify.resource(path);
    const served = record.status == 200 or record.status == 304;

    // An asset is fetched because of a page, not instead of one, so it
    // counts towards nothing a person did.
    if (what == .asset) return;

    switch (what) {
        .page => if (served) {
            try counters.add(today, name, Kind.views, "", 1);
            try counters.add(today, name, Kind.page, classify.page(path), 1);
        },
        .install_script => if (served) try counters.add(today, name, Kind.install_script, "", 1),
        .archive => if (served) try counters.add(today, name, Kind.install_run, "", 1),
        .extension => if (served) try counters.add(today, name, Kind.extension, "", 1),
        .asset, .other => {},
    }

    // Where from, and where in the world — asked once per thing a
    // person actually came for, never per asset alongside it.
    if (what == .other) return;

    if (table) |located| {
        if (located.lookup(record.client)) |code| {
            try counters.add(today, name, Kind.country, code, 1);
        }
    }
    const from = classify.referrer(record.referrer);
    if (from.len != 0) try counters.add(today, name, Kind.referrer, from, 1);

    // One person, one day, one site.  The salt is this day's and is
    // destroyed with the day, so the hash cannot outlive its meaning.
    const salt = try salts.get(today);
    var hash: [16]u8 = undefined;
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(&salt);
    hasher.update(record.client);
    hasher.update("\x00");
    hasher.update(record.agent);
    hasher.final(&hash);
    try store.sawVisitor(today, name, &hash);

    // The same hash again under `everywhere`, so one person reading
    // both luce and loom today is two site visitors and one person.
    try store.sawVisitor(today, store_module.everywhere, &hash);
}

/// One salt per day, fetched from the store the first time the day is
/// seen and held for the rest of the run.
const Salts = struct {
    gpa: Allocator,
    io: Io,
    store: Store,
    known: std.StringHashMapUnmanaged([16]u8) = .empty,

    fn deinit(self: *Salts) void {
        var names = self.known.keyIterator();
        while (names.next()) |name| self.gpa.free(name.*);
        self.known.deinit(self.gpa);
    }

    fn get(self: *Salts, today: []const u8) ![16]u8 {
        if (self.known.get(today)) |found| return found;

        // Offered, not imposed: if the day already has a salt, that one
        // is kept, because changing it mid-day would count everyone
        // already seen a second time.
        var proposed: [16]u8 = undefined;
        try Io.randomSecure(self.io, &proposed);
        const made = try self.store.salt(today, proposed);
        try self.known.put(self.gpa, try self.gpa.dupe(u8, today), made);
        return made;
    }
};

/// Every rolled log in `directory`, oldest name first.
fn rolledFiles(gpa: Allocator, io: Io, directory: []const u8) !std.ArrayList([]const u8) {
    var found: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (found.items) |name| gpa.free(name);
        found.deinit(gpa);
    }

    var open = try Io.Dir.cwd().openDir(io, directory, .{ .iterate = true });
    defer open.close(io);

    var walk = open.iterate();
    while (try walk.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (isRoll(entry.name)) try found.append(gpa, try gpa.dupe(u8, entry.name));
    }

    // Lumberjack's roll names carry an ISO timestamp, so the names sort
    // the way the files were written.
    std.mem.sort([]const u8, found.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    return found;
}

/// `luce-2026-08-13T21-06-09.000.log`, with or without a `.gz`.
fn isRoll(name: []const u8) bool {
    for (live_logs) |live| {
        if (std.mem.eql(u8, name, live)) return false;
        const stem = live[0 .. live.len - ".log".len];
        if (!std.mem.startsWith(u8, name, stem)) continue;
        if (name.len <= stem.len or name[stem.len] != '-') continue;
        if (std.mem.endsWith(u8, name, ".log") or std.mem.endsWith(u8, name, ".log.gz")) return true;
    }
    return false;
}

/// A whole log file in memory, decompressed if it was rolled and gzipped.
///
/// Caddy compresses rolled files by default.  Reading them is ten
/// lines, and the alternative — turning compression off and hoping the
/// setting never drifts back — would turn a configuration change into
/// silently missing days.
fn readWhole(gpa: Allocator, io: Io, path: []const u8) ![]u8 {
    const raw = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    if (!std.mem.endsWith(u8, path, ".gz")) return raw;
    defer gpa.free(raw);

    var input: Io.Reader = .fixed(raw);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&input, .gzip, &window);
    return decompress.reader.allocRemaining(gpa, .unlimited);
}

const testing = std.testing;

test "a live log is told from its rolls" {
    try testing.expect(!isRoll("luce.log"));
    try testing.expect(!isRoll("loom.log"));
    try testing.expect(!isRoll("luciaos.log"));
    try testing.expect(isRoll("luce-2026-08-13T21-06-09.000.log"));
    try testing.expect(isRoll("luce-2026-08-13T21-06-09.000.log.gz"));
    try testing.expect(isRoll("loom-2026-08-13T21-06-09.000.log.gz"));
    try testing.expect(!isRoll("other.log"));
    try testing.expect(!isRoll("luce.log.bak"));
    try testing.expect(!isRoll("luceberry-2026.log"));
    try testing.expect(!isRoll(".gitkeep"));
}

/// A whole ingest against a temporary directory and an in-memory store.
const Harness = struct {
    arena_state: std.heap.ArenaAllocator,
    threaded: Io.Threaded,
    directory: std.testing.TmpDir,
    store: Store,
    root: []const u8,

    fn init() !Harness {
        var self: Harness = .{
            .arena_state = std.heap.ArenaAllocator.init(testing.allocator),
            .threaded = undefined,
            .directory = testing.tmpDir(.{}),
            .store = try Store.open(testing.allocator, ":memory:"),
            .root = undefined,
        };
        self.threaded = .init(testing.allocator, .{});
        self.root = try temporary.path(self.arena_state.allocator(), self.directory);
        return self;
    }

    fn deinit(self: *Harness) void {
        self.store.deinit();
        self.directory.cleanup();
        self.threaded.deinit();
        self.arena_state.deinit();
    }

    fn io(self: *Harness) Io {
        return self.threaded.io();
    }

    fn write(self: *Harness, name: []const u8, text: []const u8) !void {
        try self.directory.dir.writeFile(self.io(), .{ .sub_path = name, .data = text });
    }

    /// What Caddy does when a log reaches its roll size: the live file
    /// keeps its inode under a new name, and the next line written
    /// creates a brand new live file.
    fn roll(self: *Harness, from: []const u8, to: []const u8) !void {
        try self.directory.dir.rename(from, self.directory.dir, to, self.io());
    }

    fn ingest(self: *Harness, now: i64) !Summary {
        return run(testing.allocator, self.io(), self.store, null, self.root, now);
    }

    fn number(self: *Harness, sql: []const u8) !i64 {
        var query = try self.store.connection.prepare(sql);
        defer query.finish();
        if (!try query.step()) return 0;
        return query.readNumber(0);
    }
};

/// One access line, spelled the way Caddy spells it.
fn accessLine(host: []const u8, uri: []const u8, agent: []const u8, client: []const u8, status: u16) []const u8 {
    const template =
        \\{{"level":"info","ts":1786655249.5,"msg":"handled request","request":{{"client_ip":"{s}","method":"GET","host":"{s}","uri":"{s}","headers":{{"User-Agent":["{s}"]}}}},"size":100,"status":{d}}}
    ;
    return std.fmt.allocPrint(
        std.testing.allocator,
        template,
        .{ client, host, uri, agent, status },
    ) catch @panic("out of memory");
}

test "a page read by a person is a view, a visitor and a hit" {
    var harness = try Harness.init();
    defer harness.deinit();

    const browser = "Mozilla/5.0 (Macintosh) Safari/605.1.15";
    const text = accessLine("luce.luciaos.com", "/guides/toolchain/", browser, "9.9.9.9", 200);
    defer testing.allocator.free(text);
    const both = try std.fmt.allocPrint(testing.allocator, "{s}\n", .{text});
    defer testing.allocator.free(both);

    try harness.write("luce.log", both);
    const summary = try harness.ingest(1786655249);

    try testing.expectEqual(@as(usize, 1), summary.requests);
    try testing.expectEqual(@as(i64, 1), try harness.number("SELECT count FROM daily WHERE kind='views'"));
    try testing.expectEqual(@as(i64, 1), try harness.number("SELECT count FROM daily WHERE kind='hits'"));
    try testing.expectEqual(@as(i64, 1), try harness.number("SELECT count FROM daily WHERE kind='visitors'"));
    try testing.expectEqual(@as(i64, 1), try harness.number(
        "SELECT count FROM daily WHERE kind='page' AND key='/guides/toolchain/'",
    ));
}

test "a crawler is traffic but never a visitor" {
    var harness = try Harness.init();
    defer harness.deinit();

    const text = accessLine("luce.luciaos.com", "/", "Googlebot/2.1", "9.9.9.9", 200);
    defer testing.allocator.free(text);
    const both = try std.fmt.allocPrint(testing.allocator, "{s}\n", .{text});
    defer testing.allocator.free(both);

    try harness.write("luce.log", both);
    _ = try harness.ingest(1786655249);

    try testing.expectEqual(@as(i64, 1), try harness.number("SELECT count FROM daily WHERE kind='hits'"));
    try testing.expectEqual(@as(i64, 1), try harness.number("SELECT count FROM daily WHERE kind='robots'"));
    try testing.expectEqual(@as(i64, 0), try harness.number("SELECT count FROM daily WHERE kind='views'"));
    try testing.expectEqual(@as(i64, 0), try harness.number("SELECT count FROM daily WHERE kind='visitors'"));
}

test "the install line and the install are counted apart" {
    var harness = try Harness.init();
    defer harness.deinit();

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    for ([_][]const u8{
        "/install/0.18/install.sh",
        "/install/0.18/install.sh",
        "/install/0.18/luce-0.18-linux-x86_64.tar.gz",
    }) |uri| {
        const one = accessLine("luce.luciaos.com", uri, "curl/8.7.1", "9.9.9.9", 200);
        defer testing.allocator.free(one);
        try text.appendSlice(testing.allocator, one);
        try text.append(testing.allocator, '\n');
    }

    try harness.write("luce.log", text.items);
    _ = try harness.ingest(1786655249);

    try testing.expectEqual(@as(i64, 2), try harness.number("SELECT count FROM daily WHERE kind='install_script'"));
    try testing.expectEqual(@as(i64, 1), try harness.number("SELECT count FROM daily WHERE kind='install_run'"));
    // curl is a person: three requests from one address are one visitor.
    try testing.expectEqual(@as(i64, 1), try harness.number("SELECT count FROM daily WHERE kind='visitors'"));
}

test "a second run reads only what is new" {
    var harness = try Harness.init();
    defer harness.deinit();

    const first = accessLine("luce.luciaos.com", "/", "Safari/605.1.15", "9.9.9.9", 200);
    defer testing.allocator.free(first);
    const one = try std.fmt.allocPrint(testing.allocator, "{s}\n", .{first});
    defer testing.allocator.free(one);

    try harness.write("luce.log", one);
    _ = try harness.ingest(1786655249);
    try testing.expectEqual(@as(i64, 1), try harness.number("SELECT count FROM daily WHERE kind='hits'"));

    // Nothing new: running again must not count the same line twice.
    const again = try harness.ingest(1786655250);
    try testing.expectEqual(@as(usize, 0), again.requests);
    try testing.expectEqual(@as(i64, 1), try harness.number("SELECT count FROM daily WHERE kind='hits'"));

    // One more line appended is one more hit, and only one.
    const two = try std.fmt.allocPrint(testing.allocator, "{s}\n{s}\n", .{ first, first });
    defer testing.allocator.free(two);
    try harness.write("luce.log", two);
    _ = try harness.ingest(1786655251);
    try testing.expectEqual(@as(i64, 2), try harness.number("SELECT count FROM daily WHERE kind='hits'"));
}

test "a half-written line waits for the rest of itself" {
    var harness = try Harness.init();
    defer harness.deinit();

    const whole = accessLine("luce.luciaos.com", "/", "Safari/605.1.15", "9.9.9.9", 200);
    defer testing.allocator.free(whole);

    // A complete line, then half of another.
    const partial = try std.fmt.allocPrint(testing.allocator, "{s}\n{s}", .{ whole, whole[0 .. whole.len / 2] });
    defer testing.allocator.free(partial);
    try harness.write("luce.log", partial);
    _ = try harness.ingest(1786655249);
    try testing.expectEqual(@as(i64, 1), try harness.number("SELECT count FROM daily WHERE kind='hits'"));
    try testing.expectEqual(@as(i64, 0), try harness.number("SELECT count FROM daily WHERE kind='hits' AND count > 1"));

    // The rest arrives: now it is two, not one and a fragment.
    const finished = try std.fmt.allocPrint(testing.allocator, "{s}\n{s}\n", .{ whole, whole });
    defer testing.allocator.free(finished);
    try harness.write("luce.log", finished);
    _ = try harness.ingest(1786655250);
    try testing.expectEqual(@as(i64, 2), try harness.number("SELECT count FROM daily WHERE kind='hits'"));
}

test "a rolled file is read once and the live file starts over" {
    var harness = try Harness.init();
    defer harness.deinit();

    const one = accessLine("luce.luciaos.com", "/", "Safari/605.1.15", "9.9.9.9", 200);
    defer testing.allocator.free(one);
    const text = try std.fmt.allocPrint(testing.allocator, "{s}\n", .{one});
    defer testing.allocator.free(text);

    try harness.write("luce.log", text);
    _ = try harness.ingest(1786655249);
    try testing.expectEqual(@as(i64, 1), try harness.number("SELECT count FROM daily WHERE kind='hits'"));

    // Caddy rolls: the file we were following becomes the roll, and a
    // brand new live file takes its place.  The roll is the same file
    // we already read to the end, so it must contribute nothing; the
    // new live file contributes its one line.
    try harness.roll("luce.log", "luce-2026-08-13T21-06-09.000.log");
    try harness.write("luce.log", text);
    _ = try harness.ingest(1786655250);
    try testing.expectEqual(@as(i64, 2), try harness.number("SELECT count FROM daily WHERE kind='hits'"));

    // Running again reads neither file a second time.
    _ = try harness.ingest(1786655251);
    try testing.expectEqual(@as(i64, 2), try harness.number("SELECT count FROM daily WHERE kind='hits'"));
}

test "a new live file is read from its beginning, not from the old offset" {
    var harness = try Harness.init();
    defer harness.deinit();

    const one = accessLine("luce.luciaos.com", "/", "Safari/605.1.15", "9.9.9.9", 200);
    defer testing.allocator.free(one);

    // Four lines read, so the cursor is well past the start of a file.
    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(testing.allocator);
    for (0..4) |_| {
        try many.appendSlice(testing.allocator, one);
        try many.append(testing.allocator, '\n');
    }
    try harness.write("luce.log", many.items);
    _ = try harness.ingest(1786655249);
    try testing.expectEqual(@as(i64, 4), try harness.number("SELECT count FROM daily WHERE kind='hits'"));

    // The file is replaced by a shorter one whose first bytes sit
    // *before* the recorded offset.  Resuming at that offset would
    // silently lose these lines; the inode says it is a new file.
    try harness.roll("luce.log", "luce-2026-08-13T22-00-00.000.log");
    var two: std.ArrayList(u8) = .empty;
    defer two.deinit(testing.allocator);
    for (0..2) |_| {
        try two.appendSlice(testing.allocator, one);
        try two.append(testing.allocator, '\n');
    }
    try harness.write("luce.log", two.items);
    _ = try harness.ingest(1786655250);

    // 4 already counted, nothing new from the roll, 2 from the new
    // live file — read from its own beginning, not from offset 4.
    try testing.expectEqual(@as(i64, 6), try harness.number("SELECT count FROM daily WHERE kind='hits'"));
}

test "one person on two sites is two site visitors and one person" {
    var harness = try Harness.init();
    defer harness.deinit();

    // The same address and browser, reading luce and then loom.
    const browser = "Mozilla/5.0 (Macintosh) Safari/605.1.15";
    for ([_][]const u8{ "luce", "loom" }) |name| {
        const one = accessLine(
            if (std.mem.eql(u8, name, "luce")) "luce.luciaos.com" else "loom.luciaos.com",
            "/",
            browser,
            "9.9.9.9",
            200,
        );
        defer testing.allocator.free(one);
        const text = try std.fmt.allocPrint(testing.allocator, "{s}\n", .{one});
        defer testing.allocator.free(text);
        try harness.write(
            if (std.mem.eql(u8, name, "luce")) "luce.log" else "loom.log",
            text,
        );
    }
    _ = try harness.ingest(1786655249);

    try testing.expectEqual(@as(i64, 1), try harness.number(
        "SELECT count FROM daily WHERE kind='visitors' AND site='luce'",
    ));
    try testing.expectEqual(@as(i64, 1), try harness.number(
        "SELECT count FROM daily WHERE kind='visitors' AND site='loom'",
    ));
    // Summing those two would say two people.  There was one.
    try testing.expectEqual(@as(i64, 1), try harness.number(
        "SELECT count FROM daily WHERE kind='visitors' AND site='all'",
    ));
}

test "a host that is not ours is counted as nothing" {
    var harness = try Harness.init();
    defer harness.deinit();

    const foreign = accessLine("example.com", "/", "Safari/605.1.15", "9.9.9.9", 200);
    defer testing.allocator.free(foreign);
    const text = try std.fmt.allocPrint(testing.allocator, "{s}\n", .{foreign});
    defer testing.allocator.free(text);

    try harness.write("luce.log", text);
    const summary = try harness.ingest(1786655249);
    try testing.expectEqual(@as(usize, 1), summary.foreign);
    try testing.expectEqual(@as(usize, 0), summary.requests);
    try testing.expectEqual(@as(i64, 0), try harness.number("SELECT COUNT(*) FROM daily"));
}
