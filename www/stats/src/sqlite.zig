//! The part of SQLite this collector uses, declared rather than imported.
//!
//! `sqlite3.h` is 690 KB of macros and eighty years of compatibility
//! surface; the collector opens a database, runs some statements and
//! closes it.  Translating the whole header to reach fifteen functions
//! would put a large generated namespace between a reader and what is
//! actually called, so the fifteen are written out here, and anything
//! this file does not name is not used.
//!
//! Ownership: `Database` and `Statement` are opaque handles owned by
//! SQLite.  A `Statement` borrows the text bound into it only until
//! the next `step`, which is why every bind here copies (`transient`).

const std = @import("std");

pub const Database = opaque {};
pub const Statement = opaque {};

pub const Error = error{
    CannotOpen,
    Failed,
};

const ok = 0;
const row = 100;
const done = 101;

const open_readwrite = 0x00000002;
const open_create = 0x00000004;

/// SQLite's "copy this, I may free it" destructor, spelled `-1`.
const transient: ?*const anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

extern "c" fn sqlite3_open_v2(filename: [*:0]const u8, out: *?*Database, flags: c_int, vfs: ?[*:0]const u8) c_int;
extern "c" fn sqlite3_close(database: ?*Database) c_int;
extern "c" fn sqlite3_errmsg(database: ?*Database) [*:0]const u8;
extern "c" fn sqlite3_exec(database: ?*Database, sql: [*:0]const u8, callback: ?*const anyopaque, argument: ?*anyopaque, message: ?*?[*:0]u8) c_int;
extern "c" fn sqlite3_prepare_v2(database: ?*Database, sql: [*]const u8, length: c_int, out: *?*Statement, tail: ?*?[*]const u8) c_int;
extern "c" fn sqlite3_step(statement: ?*Statement) c_int;
extern "c" fn sqlite3_reset(statement: ?*Statement) c_int;
extern "c" fn sqlite3_finalize(statement: ?*Statement) c_int;
extern "c" fn sqlite3_bind_text(statement: ?*Statement, index: c_int, text: [*]const u8, length: c_int, destructor: ?*const anyopaque) c_int;
extern "c" fn sqlite3_bind_int64(statement: ?*Statement, index: c_int, value: i64) c_int;
extern "c" fn sqlite3_bind_blob(statement: ?*Statement, index: c_int, bytes: [*]const u8, length: c_int, destructor: ?*const anyopaque) c_int;
extern "c" fn sqlite3_column_int64(statement: ?*Statement, index: c_int) i64;
extern "c" fn sqlite3_column_text(statement: ?*Statement, index: c_int) ?[*]const u8;
extern "c" fn sqlite3_column_bytes(statement: ?*Statement, index: c_int) c_int;

/// An open database.  `close` is the only way to give it back.
pub const Connection = struct {
    handle: ?*Database,

    pub fn open(path: [*:0]const u8) Error!Connection {
        var handle: ?*Database = null;
        if (sqlite3_open_v2(path, &handle, open_readwrite | open_create, null) != ok) {
            _ = sqlite3_close(handle);
            return error.CannotOpen;
        }
        return .{ .handle = handle };
    }

    pub fn close(self: *Connection) void {
        _ = sqlite3_close(self.handle);
        self.handle = null;
    }

    /// The last thing SQLite complained about.  Borrowed from SQLite,
    /// valid until the next call on this connection.
    pub fn message(self: Connection) []const u8 {
        return std.mem.span(sqlite3_errmsg(self.handle));
    }

    /// Run statements that answer nothing.  `sql` may hold several.
    pub fn run(self: Connection, sql: [*:0]const u8) Error!void {
        if (sqlite3_exec(self.handle, sql, null, null, null) != ok) return error.Failed;
    }

    pub fn prepare(self: Connection, sql: []const u8) Error!Query {
        var statement: ?*Statement = null;
        const length: c_int = @intCast(sql.len);
        if (sqlite3_prepare_v2(self.handle, sql.ptr, length, &statement, null) != ok) {
            return error.Failed;
        }
        return .{ .statement = statement };
    }
};

/// One prepared statement, reused across rows.  `finish` frees it.
pub const Query = struct {
    statement: ?*Statement,

    pub fn finish(self: *Query) void {
        _ = sqlite3_finalize(self.statement);
        self.statement = null;
    }

    /// Forget the bindings and rewind, ready to be bound again.
    pub fn rewind(self: Query) Error!void {
        if (sqlite3_reset(self.statement) != ok) return error.Failed;
    }

    /// Parameters are numbered from one, as SQLite numbers them.
    pub fn text(self: Query, index: c_int, value: []const u8) Error!void {
        const length: c_int = @intCast(value.len);
        if (sqlite3_bind_text(self.statement, index, value.ptr, length, transient) != ok) {
            return error.Failed;
        }
    }

    pub fn number(self: Query, index: c_int, value: i64) Error!void {
        if (sqlite3_bind_int64(self.statement, index, value) != ok) return error.Failed;
    }

    pub fn blob(self: Query, index: c_int, value: []const u8) Error!void {
        const length: c_int = @intCast(value.len);
        if (sqlite3_bind_blob(self.statement, index, value.ptr, length, transient) != ok) {
            return error.Failed;
        }
    }

    /// True while there is a row to read; false when the statement is done.
    pub fn step(self: Query) Error!bool {
        return switch (sqlite3_step(self.statement)) {
            row => true,
            done => false,
            else => error.Failed,
        };
    }

    /// Run a statement that answers no rows.
    pub fn once(self: Query) Error!void {
        if (try self.step()) return error.Failed;
    }

    /// Columns are numbered from zero, as SQLite numbers them.
    pub fn readNumber(self: Query, index: c_int) i64 {
        return sqlite3_column_int64(self.statement, index);
    }

    /// Borrowed from SQLite: valid until the next `step` or `rewind`.
    pub fn readText(self: Query, index: c_int) []const u8 {
        const bytes = sqlite3_column_text(self.statement, index) orelse return "";
        const length: usize = @intCast(sqlite3_column_bytes(self.statement, index));
        return bytes[0..length];
    }
};

test "a database remembers what was put in it" {
    var connection = try Connection.open(":memory:");
    defer connection.close();

    try connection.run("CREATE TABLE t (name TEXT, count INTEGER)");

    var insert = try connection.prepare("INSERT INTO t VALUES (?, ?)");
    try insert.text(1, "luce");
    try insert.number(2, 7);
    try insert.once();
    insert.finish();

    var select = try connection.prepare("SELECT name, count FROM t");
    defer select.finish();
    try std.testing.expect(try select.step());
    try std.testing.expectEqualStrings("luce", select.readText(0));
    try std.testing.expectEqual(@as(i64, 7), select.readNumber(1));
    try std.testing.expect(!try select.step());
}

test "a statement rewinds and binds again" {
    var connection = try Connection.open(":memory:");
    defer connection.close();
    try connection.run("CREATE TABLE t (name TEXT PRIMARY KEY, count INTEGER)");

    var insert = try connection.prepare(
        \\INSERT INTO t VALUES (?, ?)
        \\ON CONFLICT(name) DO UPDATE SET count = count + excluded.count
    );
    defer insert.finish();
    for ([_][]const u8{ "luce", "loom", "luce" }) |name| {
        try insert.rewind();
        try insert.text(1, name);
        try insert.number(2, 1);
        try insert.once();
    }

    var select = try connection.prepare("SELECT count FROM t WHERE name = 'luce'");
    defer select.finish();
    try std.testing.expect(try select.step());
    try std.testing.expectEqual(@as(i64, 2), select.readNumber(0));
}
