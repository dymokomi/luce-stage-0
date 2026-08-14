//! Where the numbers live between runs.
//!
//! One SQLite file holds three things: how far each log has been read,
//! a count per day per site per dimension, and — for the day still in
//! progress — the salted hashes that make "how many people" a number
//! rather than a guess.
//!
//! ## What is not here
//!
//! No addresses, no user agents, no paths a person asked for tied to
//! anyone who asked for them.  The only row that is ever about an
//! individual is a `visitor` hash, it is salted with a random value
//! generated for that day alone, and both the hashes and the salt are
//! deleted once the day is closed and its total written down.  After
//! that the day is a count, and the count cannot be turned back into
//! the people it counted.
//!
//! ## Why the counts are one table
//!
//! `daily(day, site, kind, key, count)` holds views, visitors, top
//! pages, referrers, countries and downloads in the same shape, so a
//! new thing to count is a new `kind` rather than a migration — which
//! matters, because this is meant to grow into the dashboard for more
//! than three static sites.

const std = @import("std");
const Allocator = std.mem.Allocator;

const sqlite = @import("sqlite.zig");

/// The kinds of count `daily` holds.  Text in the database, because
/// the dashboard reads them and a number would mean nothing there.
pub const Kind = struct {
    /// Page requests by people — the headline "views".
    pub const views = "views";
    /// Distinct people, by the salted-hash estimate.
    pub const visitors = "visitors";
    /// Every request that reached the site, people and robots alike.
    pub const hits = "hits";
    /// Requests attributed to a crawler, scanner or monitor.
    pub const robots = "robots";
    /// `install.sh` fetched: someone read the install line.
    pub const install_script = "install_script";
    /// The toolchain archive fetched: an install actually proceeding.
    pub const install_run = "install_run";
    /// The editor extension fetched.
    pub const extension = "extension";
    /// Bytes served.
    pub const bytes = "bytes";
    /// key = the page's path.
    pub const page = "page";
    /// key = the referring host.
    pub const referrer = "referrer";
    /// key = the two-letter country code.
    pub const country = "country";
    /// key = browser | tool | robot.
    pub const agent = "agent";
    /// key = the HTTP status, so a rash of 404s is visible.
    pub const status = "status";
};

const schema =
    \\PRAGMA journal_mode = WAL;
    \\PRAGMA synchronous = NORMAL;
    \\
    \\CREATE TABLE IF NOT EXISTS daily (
    \\  day   TEXT    NOT NULL,
    \\  site  TEXT    NOT NULL,
    \\  kind  TEXT    NOT NULL,
    \\  key   TEXT    NOT NULL,
    \\  count INTEGER NOT NULL,
    \\  PRIMARY KEY (day, site, kind, key)
    \\) WITHOUT ROWID;
    \\
    \\CREATE INDEX IF NOT EXISTS daily_kind ON daily (kind, day);
    \\
    \\-- How far the live log of each file has been read.  Keyed by path,
    \\-- carrying the inode so a rolled-and-recreated file is noticed.
    \\CREATE TABLE IF NOT EXISTS cursor (
    \\  path   TEXT    PRIMARY KEY,
    \\  inode  INTEGER NOT NULL,
    \\  offset INTEGER NOT NULL,
    \\  seen   INTEGER NOT NULL
    \\) WITHOUT ROWID;
    \\
    \\-- Rolled files already read to the end.  A roll never comes back,
    \\-- so a name here means "done, do not read again".
    \\CREATE TABLE IF NOT EXISTS ingested (
    \\  path TEXT PRIMARY KEY,
    \\  seen INTEGER NOT NULL
    \\) WITHOUT ROWID;
    \\
    \\-- The open day's people, one salted hash each.  Deleted with the
    \\-- salt as soon as the day is closed and counted.
    \\CREATE TABLE IF NOT EXISTS visitor (
    \\  day  TEXT NOT NULL,
    \\  site TEXT NOT NULL,
    \\  hash BLOB NOT NULL,
    \\  PRIMARY KEY (day, site, hash)
    \\) WITHOUT ROWID;
    \\
    \\CREATE TABLE IF NOT EXISTS salt (
    \\  day  TEXT PRIMARY KEY,
    \\  salt BLOB NOT NULL
    \\) WITHOUT ROWID;
;

/// The site name the *combined* audience is filed under.
///
/// A visitor hash is per person, not per site, so the same person on
/// two sites is two rows under two site names and one row under this
/// one.  Summing the three real sites would count them twice; the
/// headline "people" number reads this instead.
pub const everywhere = "all";

pub const Cursor = struct {
    inode: u64 = 0,
    offset: u64 = 0,
};

pub const Store = struct {
    gpa: Allocator,
    connection: sqlite.Connection,

    pub fn open(gpa: Allocator, path: [*:0]const u8) !Store {
        var connection = try sqlite.Connection.open(path);
        errdefer connection.close();
        try connection.run(schema);
        return .{ .gpa = gpa, .connection = connection };
    }

    pub fn deinit(self: *Store) void {
        self.connection.close();
    }

    pub fn begin(self: Store) !void {
        try self.connection.run("BEGIN IMMEDIATE");
    }

    pub fn commit(self: Store) !void {
        try self.connection.run("COMMIT");
    }

    // ------------------------------------------------------- cursors

    pub fn cursor(self: Store, path: []const u8) !Cursor {
        var query = try self.connection.prepare("SELECT inode, offset FROM cursor WHERE path = ?");
        defer query.finish();
        try query.text(1, path);
        if (!try query.step()) return .{};
        return .{
            .inode = @bitCast(query.readNumber(0)),
            .offset = @bitCast(query.readNumber(1)),
        };
    }

    pub fn setCursor(self: Store, path: []const u8, at: Cursor, now: i64) !void {
        var query = try self.connection.prepare(
            \\INSERT INTO cursor (path, inode, offset, seen) VALUES (?, ?, ?, ?)
            \\ON CONFLICT(path) DO UPDATE SET inode = excluded.inode,
            \\  offset = excluded.offset, seen = excluded.seen
        );
        defer query.finish();
        try query.text(1, path);
        try query.number(2, @bitCast(at.inode));
        try query.number(3, @bitCast(at.offset));
        try query.number(4, now);
        try query.once();
    }

    /// How far a file with this inode has already been read, if any
    /// cursor names it.  After a roll the rolled file *is* the file the
    /// live cursor was following, under a new name — so this is what
    /// keeps its already-read prefix from being counted a second time.
    pub fn offsetForInode(self: Store, inode: u64) !?u64 {
        var query = try self.connection.prepare("SELECT offset FROM cursor WHERE inode = ?");
        defer query.finish();
        try query.number(1, @bitCast(inode));
        if (!try query.step()) return null;
        return @bitCast(query.readNumber(0));
    }

    pub fn wasIngested(self: Store, path: []const u8) !bool {
        var query = try self.connection.prepare("SELECT 1 FROM ingested WHERE path = ?");
        defer query.finish();
        try query.text(1, path);
        return try query.step();
    }

    pub fn markIngested(self: Store, path: []const u8, now: i64) !void {
        var query = try self.connection.prepare(
            "INSERT OR IGNORE INTO ingested (path, seen) VALUES (?, ?)",
        );
        defer query.finish();
        try query.text(1, path);
        try query.number(2, now);
        try query.once();
    }

    // ------------------------------------------------------ visitors

    /// The salt for one day: the stored one if the day has been seen,
    /// otherwise `proposed`, stored and returned.
    ///
    /// The randomness comes from the caller because it comes from the
    /// host, and nothing else in this file touches the host.
    pub fn salt(self: Store, day: []const u8, proposed: [16]u8) ![16]u8 {
        var found: [16]u8 = undefined;
        {
            var query = try self.connection.prepare("SELECT salt FROM salt WHERE day = ?");
            defer query.finish();
            try query.text(1, day);
            if (try query.step()) {
                const stored = query.readText(0);
                if (stored.len == found.len) {
                    @memcpy(&found, stored);
                    return found;
                }
            }
        }

        found = proposed;
        var insert = try self.connection.prepare("INSERT OR REPLACE INTO salt (day, salt) VALUES (?, ?)");
        defer insert.finish();
        try insert.text(1, day);
        try insert.blob(2, &found);
        try insert.once();
        return found;
    }

    /// Note that this person was seen today.  Repeats are ignored, so
    /// the row count is the number of people.
    pub fn sawVisitor(self: Store, day: []const u8, site: []const u8, hash: []const u8) !void {
        var query = try self.connection.prepare(
            "INSERT OR IGNORE INTO visitor (day, site, hash) VALUES (?, ?, ?)",
        );
        defer query.finish();
        try query.text(1, day);
        try query.text(2, site);
        try query.blob(3, hash);
        try query.once();
    }

    /// Write each held day's visitor count into `daily`.  Replaces
    /// rather than adds: it is a recount, not an increment.
    pub fn countVisitors(self: Store) !void {
        try self.connection.run(
            \\INSERT INTO daily (day, site, kind, key, count)
            \\SELECT day, site, 'visitors', '', COUNT(*) FROM visitor GROUP BY day, site
            \\ON CONFLICT(day, site, kind, key) DO UPDATE SET count = excluded.count
        );
    }

    /// Forget the hashes and the salt for every day before `day`.  The
    /// counts written by `countVisitors` stay; the means of recovering
    /// who was counted does not.
    pub fn forgetBefore(self: Store, day: []const u8) !void {
        {
            var query = try self.connection.prepare("DELETE FROM visitor WHERE day < ?");
            defer query.finish();
            try query.text(1, day);
            try query.once();
        }
        var query = try self.connection.prepare("DELETE FROM salt WHERE day < ?");
        defer query.finish();
        try query.text(1, day);
        try query.once();
    }

    // -------------------------------------------------------- counts

    pub fn add(self: Store, day: []const u8, site: []const u8, kind: []const u8, key: []const u8, count: i64) !void {
        var query = try self.connection.prepare(
            \\INSERT INTO daily (day, site, kind, key, count) VALUES (?, ?, ?, ?, ?)
            \\ON CONFLICT(day, site, kind, key) DO UPDATE SET count = count + excluded.count
        );
        defer query.finish();
        try bindAdd(query, day, site, kind, key, count);
        try query.once();
    }

    fn bindAdd(query: sqlite.Query, day: []const u8, site: []const u8, kind: []const u8, key: []const u8, count: i64) !void {
        try query.text(1, day);
        try query.text(2, site);
        try query.text(3, kind);
        try query.text(4, key);
        try query.number(5, count);
    }
};

/// Counts held in memory for the length of one ingest.
///
/// A run reads tens of thousands of lines and most of them fall on the
/// same handful of counters; sending each one to SQLite would be a
/// statement per request for no gain.  They are folded here and
/// written once.
pub const Counters = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    map: std.StringHashMapUnmanaged(i64) = .empty,

    /// The four parts of a counter's identity, joined by a byte that
    /// cannot occur in any of them.
    const separator = '\x00';

    pub fn init(gpa: Allocator) Counters {
        return .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Counters) void {
        self.map.deinit(self.gpa);
        self.arena.deinit();
    }

    pub fn add(self: *Counters, day: []const u8, site: []const u8, kind: []const u8, key: []const u8, amount: i64) !void {
        var probe: std.ArrayList(u8) = .empty;
        defer probe.deinit(self.gpa);
        try join(self.gpa, &probe, day, site, kind, key);

        if (self.map.getPtr(probe.items)) |existing| {
            existing.* += amount;
            return;
        }
        const owned = try self.arena.allocator().dupe(u8, probe.items);
        try self.map.put(self.gpa, owned, amount);
    }

    fn join(gpa: Allocator, out: *std.ArrayList(u8), day: []const u8, site: []const u8, kind: []const u8, key: []const u8) !void {
        try out.appendSlice(gpa, day);
        try out.append(gpa, separator);
        try out.appendSlice(gpa, site);
        try out.append(gpa, separator);
        try out.appendSlice(gpa, kind);
        try out.append(gpa, separator);
        // A key is the only part that comes from the request, so it is
        // the only one that could carry a separator.  Anything from
        // there on is the key, so joining is still reversible.
        try out.appendSlice(gpa, key);
    }

    pub fn count(self: Counters) usize {
        return self.map.count();
    }

    /// Write every counter into the store, in one prepared statement.
    pub fn flush(self: *Counters, store: Store) !void {
        var query = try store.connection.prepare(
            \\INSERT INTO daily (day, site, kind, key, count) VALUES (?, ?, ?, ?, ?)
            \\ON CONFLICT(day, site, kind, key) DO UPDATE SET count = count + excluded.count
        );
        defer query.finish();

        var entries = self.map.iterator();
        while (entries.next()) |entry| {
            var parts = std.mem.splitScalar(u8, entry.key_ptr.*, separator);
            const day = parts.next() orelse continue;
            const site = parts.next() orelse continue;
            const kind = parts.next() orelse continue;
            const key = parts.rest();

            try query.rewind();
            try Store.bindAdd(query, day, site, kind, key, entry.value_ptr.*);
            try query.once();
        }
    }
};

const testing = std.testing;

fn memory() !Store {
    return Store.open(testing.allocator, ":memory:");
}

test "counters fold in memory and land as one row each" {
    var store = try memory();
    defer store.deinit();

    var counters = Counters.init(testing.allocator);
    defer counters.deinit();

    try counters.add("2026-08-13", "luce", Kind.views, "", 1);
    try counters.add("2026-08-13", "luce", Kind.views, "", 1);
    try counters.add("2026-08-13", "luce", Kind.page, "/guides/", 3);
    try counters.add("2026-08-13", "loom", Kind.views, "", 5);
    try testing.expectEqual(@as(usize, 3), counters.count());

    try counters.flush(store);

    var query = try store.connection.prepare(
        "SELECT count FROM daily WHERE day='2026-08-13' AND site='luce' AND kind='views'",
    );
    defer query.finish();
    try testing.expect(try query.step());
    try testing.expectEqual(@as(i64, 2), query.readNumber(0));
}

test "flushing twice adds rather than replaces" {
    var store = try memory();
    defer store.deinit();

    for (0..2) |_| {
        var counters = Counters.init(testing.allocator);
        defer counters.deinit();
        try counters.add("2026-08-13", "luce", Kind.views, "", 4);
        try counters.flush(store);
    }

    var query = try store.connection.prepare("SELECT count FROM daily WHERE kind='views'");
    defer query.finish();
    try testing.expect(try query.step());
    try testing.expectEqual(@as(i64, 8), query.readNumber(0));
}

test "a key holding the separator still round-trips" {
    var store = try memory();
    defer store.deinit();

    var counters = Counters.init(testing.allocator);
    defer counters.deinit();
    try counters.add("2026-08-13", "luce", Kind.page, "/a\x00b", 1);
    try counters.flush(store);

    var query = try store.connection.prepare("SELECT key FROM daily WHERE kind='page'");
    defer query.finish();
    try testing.expect(try query.step());
    try testing.expectEqualStrings("/a\x00b", query.readText(0));
}

test "a cursor is remembered and moved" {
    var store = try memory();
    defer store.deinit();

    try testing.expectEqual(Cursor{}, try store.cursor("/var/log/caddy/luce.log"));
    try store.setCursor("/var/log/caddy/luce.log", .{ .inode = 7, .offset = 100 }, 1);
    try store.setCursor("/var/log/caddy/luce.log", .{ .inode = 7, .offset = 250 }, 2);

    const at = try store.cursor("/var/log/caddy/luce.log");
    try testing.expectEqual(@as(u64, 7), at.inode);
    try testing.expectEqual(@as(u64, 250), at.offset);
}

test "a cursor can be found by the inode it followed" {
    var store = try memory();
    defer store.deinit();

    try store.setCursor("/var/log/caddy/luce.log", .{ .inode = 41, .offset = 900 }, 1);
    try testing.expectEqual(@as(?u64, 900), try store.offsetForInode(41));
    try testing.expectEqual(@as(?u64, null), try store.offsetForInode(42));
}

test "a rolled file is read once" {
    var store = try memory();
    defer store.deinit();

    try testing.expect(!try store.wasIngested("luce-2026-08-13.log"));
    try store.markIngested("luce-2026-08-13.log", 1);
    try testing.expect(try store.wasIngested("luce-2026-08-13.log"));
    // Marking again is not an error, and does not duplicate.
    try store.markIngested("luce-2026-08-13.log", 2);
    try testing.expect(try store.wasIngested("luce-2026-08-13.log"));
}

test "a day's salt is stable while the day is open" {
    var store = try memory();
    defer store.deinit();

    const one: [16]u8 = .{1} ** 16;
    const two: [16]u8 = .{2} ** 16;

    const first = try store.salt("2026-08-13", one);
    // A second ask on the same day keeps the salt already stored, so a
    // person hashed this morning is the same person this afternoon.
    const again = try store.salt("2026-08-13", two);
    try testing.expectEqualSlices(u8, &one, &first);
    try testing.expectEqualSlices(u8, &one, &again);

    const other = try store.salt("2026-08-14", two);
    try testing.expectEqualSlices(u8, &two, &other);
}

test "visitors are counted, then the means of recounting them is destroyed" {
    var store = try memory();
    defer store.deinit();

    try store.sawVisitor("2026-08-12", "luce", "aaaaaaaaaaaaaaaa");
    try store.sawVisitor("2026-08-12", "luce", "aaaaaaaaaaaaaaaa"); // same person again
    try store.sawVisitor("2026-08-12", "luce", "bbbbbbbbbbbbbbbb");
    try store.sawVisitor("2026-08-13", "luce", "cccccccccccccccc");
    _ = try store.salt("2026-08-12", .{1} ** 16);
    _ = try store.salt("2026-08-13", .{2} ** 16);

    try store.countVisitors();

    {
        var query = try store.connection.prepare(
            "SELECT day, count FROM daily WHERE kind='visitors' ORDER BY day",
        );
        defer query.finish();
        try testing.expect(try query.step());
        try testing.expectEqualStrings("2026-08-12", query.readText(0));
        try testing.expectEqual(@as(i64, 2), query.readNumber(1));
        try testing.expect(try query.step());
        try testing.expectEqual(@as(i64, 1), query.readNumber(1));
    }

    try store.forgetBefore("2026-08-13");

    // The closed day's count survives; its hashes and salt do not.
    var counted = try store.connection.prepare("SELECT count FROM daily WHERE kind='visitors' AND day='2026-08-12'");
    defer counted.finish();
    try testing.expect(try counted.step());
    try testing.expectEqual(@as(i64, 2), counted.readNumber(0));

    var hashes = try store.connection.prepare("SELECT COUNT(*) FROM visitor WHERE day='2026-08-12'");
    defer hashes.finish();
    try testing.expect(try hashes.step());
    try testing.expectEqual(@as(i64, 0), hashes.readNumber(0));

    var salts = try store.connection.prepare("SELECT COUNT(*) FROM salt WHERE day='2026-08-12'");
    defer salts.finish();
    try testing.expect(try salts.step());
    try testing.expectEqual(@as(i64, 0), salts.readNumber(0));

    // The open day keeps both, because it is still being counted.
    var open = try store.connection.prepare("SELECT COUNT(*) FROM visitor WHERE day='2026-08-13'");
    defer open.finish();
    try testing.expect(try open.step());
    try testing.expectEqual(@as(i64, 1), open.readNumber(0));
}

test "recounting a day replaces its visitor number" {
    var store = try memory();
    defer store.deinit();

    try store.sawVisitor("2026-08-13", "luce", "aaaaaaaaaaaaaaaa");
    try store.countVisitors();
    try store.sawVisitor("2026-08-13", "luce", "bbbbbbbbbbbbbbbb");
    try store.countVisitors();

    var query = try store.connection.prepare("SELECT count FROM daily WHERE kind='visitors'");
    defer query.finish();
    try testing.expect(try query.step());
    try testing.expectEqual(@as(i64, 2), query.readNumber(0));
}
