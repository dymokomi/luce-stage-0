//! Which country an address is in, answered from a file rather than a service.
//!
//! The collector runs once an hour over a log full of addresses; asking
//! anyone about them, one at a time, over the network, would turn a
//! local counting job into a dependency on a third party who would then
//! learn every address that visits these sites.  So the answer comes
//! from a table on disk: DB-IP's free country database, converted once
//! by `pack` into ranges that can be binary-searched, and consulted
//! without a socket.
//!
//! Addresses are looked up and thrown away — only the country reaches
//! the database the dashboard is built from.
//!
//! The file is small and dumb on purpose:
//!
//!     "LGEO"  version:u32  v4_count:u32  v6_count:u32
//!     v4_count × { start:u32  end:u32  code:[2]u8  pad:[2]u8 }
//!     v6_count × { start:u128 end:u128 code:[2]u8  pad:[2]u8 }
//!
//! little-endian throughout, ranges sorted by start and non-overlapping.
//! Records are read field by field rather than cast from the mapped
//! bytes: a binary search touches twenty of them, and a file that
//! arrived from somewhere else must not be able to produce a
//! misaligned pointer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const temporary = @import("temporary.zig");

const magic = "LGEO";
const version: u32 = 1;

const header_size = 16;
const v4_size = 12;
const v6_size = 36;

pub const Error = error{
    NotAGeoTable,
    UnsupportedVersion,
    Damaged,
};

/// A loaded table.  Owns its bytes; `deinit` gives them back.
pub const Table = struct {
    gpa: Allocator,
    bytes: []const u8,
    v4_count: usize,
    v6_count: usize,

    pub fn load(gpa: Allocator, io: Io, path: []const u8) !Table {
        const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        errdefer gpa.free(bytes);
        return open(gpa, bytes);
    }

    /// Take ownership of `bytes` and check they are a table.
    pub fn open(gpa: Allocator, bytes: []const u8) Error!Table {
        if (bytes.len < header_size) return error.NotAGeoTable;
        if (!std.mem.eql(u8, bytes[0..4], magic)) return error.NotAGeoTable;
        if (std.mem.readInt(u32, bytes[4..8], .little) != version) return error.UnsupportedVersion;

        const v4_count = std.mem.readInt(u32, bytes[8..12], .little);
        const v6_count = std.mem.readInt(u32, bytes[12..16], .little);
        const expected = header_size +
            @as(usize, v4_count) * v4_size +
            @as(usize, v6_count) * v6_size;
        if (bytes.len != expected) return error.Damaged;

        return .{
            .gpa = gpa,
            .bytes = bytes,
            .v4_count = v4_count,
            .v6_count = v6_count,
        };
    }

    pub fn deinit(self: *Table) void {
        self.gpa.free(self.bytes);
        self.* = undefined;
    }

    /// The two-letter country code for a textual address, or null when
    /// the address is unparseable, private, or in a range DB-IP does
    /// not attribute.  The caller gets a borrow of the table's bytes.
    pub fn lookup(self: Table, address: []const u8) ?[]const u8 {
        if (parseV4(address)) |value| return self.searchV4(value);
        if (parseV6(address)) |value| {
            // An IPv4-mapped address (::ffff:1.2.3.4) is an IPv4 host.
            if (value >> 32 == 0xffff) return self.searchV4(@truncate(value));
            return self.searchV6(value);
        }
        return null;
    }

    fn searchV4(self: Table, value: u32) ?[]const u8 {
        var low: usize = 0;
        var high: usize = self.v4_count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const at = header_size + middle * v4_size;
            const start = std.mem.readInt(u32, self.bytes[at..][0..4], .little);
            const end = std.mem.readInt(u32, self.bytes[at + 4 ..][0..4], .little);
            if (value < start) {
                high = middle;
            } else if (value > end) {
                low = middle + 1;
            } else {
                return named(self.bytes[at + 8 ..][0..2]);
            }
        }
        return null;
    }

    fn searchV6(self: Table, value: u128) ?[]const u8 {
        const base = header_size + self.v4_count * v4_size;
        var low: usize = 0;
        var high: usize = self.v6_count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const at = base + middle * v6_size;
            const start = std.mem.readInt(u128, self.bytes[at..][0..16], .little);
            const end = std.mem.readInt(u128, self.bytes[at + 16 ..][0..16], .little);
            if (value < start) {
                high = middle;
            } else if (value > end) {
                low = middle + 1;
            } else {
                return named(self.bytes[at + 32 ..][0..2]);
            }
        }
        return null;
    }
};

/// DB-IP writes `ZZ` for a range it will not attribute; so do we, and
/// a caller should hear "unknown" rather than a country named ZZ.
fn named(code: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, code, "ZZ")) return null;
    return code;
}

// ------------------------------------------------------------ building

const V4 = struct { start: u32, end: u32, code: [2]u8 };
const V6 = struct { start: u128, end: u128, code: [2]u8 };

/// Convert DB-IP's `start,end,country` CSV into the table above.
///
/// The CSV holds both families in one file, in no promised order, so
/// both are collected and sorted here rather than trusted.
pub fn pack(gpa: Allocator, io: Io, csv_path: []const u8, out_path: []const u8) !void {
    const text = try Io.Dir.cwd().readFileAlloc(io, csv_path, gpa, .unlimited);
    defer gpa.free(text);

    var v4: std.ArrayList(V4) = .empty;
    defer v4.deinit(gpa);
    var v6: std.ArrayList(V6) = .empty;
    defer v6.deinit(gpa);

    var line_number: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        line_number += 1;
        const row = std.mem.trim(u8, line, " \t\r");
        if (row.len == 0) continue;

        var fields = std.mem.splitScalar(u8, row, ',');
        const start_text = fields.next() orelse continue;
        const end_text = fields.next() orelse continue;
        const code_text = fields.next() orelse continue;
        if (code_text.len != 2) continue;
        const code: [2]u8 = .{
            std.ascii.toUpper(code_text[0]),
            std.ascii.toUpper(code_text[1]),
        };

        if (parseV4(start_text)) |start| {
            const end = parseV4(end_text) orelse continue;
            if (end < start) continue;
            try v4.append(gpa, .{ .start = start, .end = end, .code = code });
        } else if (parseV6(start_text)) |start| {
            const end = parseV6(end_text) orelse continue;
            if (end < start) continue;
            try v6.append(gpa, .{ .start = start, .end = end, .code = code });
        }
    }

    if (v4.items.len == 0 and v6.items.len == 0) return error.NotAGeoTable;

    std.mem.sort(V4, v4.items, {}, struct {
        fn less(_: void, a: V4, b: V4) bool {
            return a.start < b.start;
        }
    }.less);
    std.mem.sort(V6, v6.items, {}, struct {
        fn less(_: void, a: V6, b: V6) bool {
            return a.start < b.start;
        }
    }.less);

    const size = header_size + v4.items.len * v4_size + v6.items.len * v6_size;
    const bytes = try gpa.alloc(u8, size);
    defer gpa.free(bytes);

    @memcpy(bytes[0..4], magic);
    std.mem.writeInt(u32, bytes[4..8], version, .little);
    std.mem.writeInt(u32, bytes[8..12], @intCast(v4.items.len), .little);
    std.mem.writeInt(u32, bytes[12..16], @intCast(v6.items.len), .little);

    var at: usize = header_size;
    for (v4.items) |range| {
        std.mem.writeInt(u32, bytes[at..][0..4], range.start, .little);
        std.mem.writeInt(u32, bytes[at + 4 ..][0..4], range.end, .little);
        bytes[at + 8] = range.code[0];
        bytes[at + 9] = range.code[1];
        bytes[at + 10] = 0;
        bytes[at + 11] = 0;
        at += v4_size;
    }
    for (v6.items) |range| {
        std.mem.writeInt(u128, bytes[at..][0..16], range.start, .little);
        std.mem.writeInt(u128, bytes[at + 16 ..][0..16], range.end, .little);
        bytes[at + 32] = range.code[0];
        bytes[at + 33] = range.code[1];
        bytes[at + 34] = 0;
        bytes[at + 35] = 0;
        at += v6_size;
    }

    if (std.fs.path.dirname(out_path)) |directory| {
        try Io.Dir.cwd().createDirPath(io, directory);
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = bytes });
}

// ------------------------------------------------------------- parsing

fn parseV4(text: []const u8) ?u32 {
    var value: u32 = 0;
    var parts: usize = 0;
    var octets = std.mem.splitScalar(u8, text, '.');
    while (octets.next()) |part| {
        parts += 1;
        if (parts > 4) return null;
        if (part.len == 0 or part.len > 3) return null;
        var octet: u32 = 0;
        for (part) |byte| {
            if (byte < '0' or byte > '9') return null;
            octet = octet * 10 + (byte - '0');
        }
        if (octet > 255) return null;
        value = (value << 8) | octet;
    }
    if (parts != 4) return null;
    return value;
}

fn parseV6(text: []const u8) ?u128 {
    const address = Io.net.Ip6Address.parse(text, 0) catch return null;
    return std.mem.readInt(u128, &address.bytes, .big);
}

const testing = std.testing;

test "addresses read as numbers, and rubbish does not" {
    try testing.expectEqual(@as(u32, 0x01020304), parseV4("1.2.3.4").?);
    try testing.expectEqual(@as(u32, 0), parseV4("0.0.0.0").?);
    try testing.expectEqual(@as(u32, 0xffffffff), parseV4("255.255.255.255").?);
    try testing.expect(parseV4("256.0.0.1") == null);
    try testing.expect(parseV4("1.2.3") == null);
    try testing.expect(parseV4("1.2.3.4.5") == null);
    try testing.expect(parseV4("1.2.3.x") == null);
    try testing.expect(parseV4("") == null);
    try testing.expect(parseV4("2001:db8::1") == null);
    try testing.expectEqual(@as(u128, 1), parseV6("::1").?);
}

test "a packed table answers the ranges it was built from" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded: Io.Threaded = .init(arena, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var directory = testing.tmpDir(.{});
    defer directory.cleanup();
    const root = try temporary.path(arena, directory);
    const csv = try std.fs.path.join(arena, &.{ root, "in.csv" });
    const out = try std.fs.path.join(arena, &.{ root, "countries.bin" });

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = csv, .data =
        \\0.0.0.0,0.255.255.255,ZZ
        \\1.0.0.0,1.0.0.255,AU
        \\9.9.9.0,9.9.9.255,DE
        \\5.5.5.0,5.5.5.255,GB
        \\2001:db8::,2001:db8::ffff,JP
        \\
    });

    try pack(arena, io, csv, out);

    var table = try Table.load(arena, io, out);
    defer table.deinit();

    try testing.expectEqualStrings("AU", table.lookup("1.0.0.7").?);
    try testing.expectEqualStrings("GB", table.lookup("5.5.5.5").?);
    try testing.expectEqualStrings("DE", table.lookup("9.9.9.9").?);
    try testing.expectEqualStrings("JP", table.lookup("2001:db8::5").?);
    // Ranges DB-IP will not attribute answer nothing, not "ZZ".
    try testing.expect(table.lookup("0.0.0.1") == null);
    // Outside every range.
    try testing.expect(table.lookup("8.8.8.8") == null);
    try testing.expect(table.lookup("2001:dead::1") == null);
    // Not an address at all.
    try testing.expect(table.lookup("") == null);
    try testing.expect(table.lookup("localhost") == null);
    // An IPv4-mapped address is looked up as the IPv4 host it is.
    try testing.expectEqualStrings("AU", table.lookup("::ffff:1.0.0.7").?);
}

test "a file that is not a table is refused rather than read" {
    try testing.expectError(error.NotAGeoTable, Table.open(testing.allocator, "no"));
    try testing.expectError(error.NotAGeoTable, Table.open(testing.allocator, "XXXX____________"));

    var wrong: [16]u8 = .{0} ** 16;
    @memcpy(wrong[0..4], magic);
    std.mem.writeInt(u32, wrong[4..8], 99, .little);
    try testing.expectError(error.UnsupportedVersion, Table.open(testing.allocator, &wrong));

    var short: [16]u8 = .{0} ** 16;
    @memcpy(short[0..4], magic);
    std.mem.writeInt(u32, short[4..8], version, .little);
    std.mem.writeInt(u32, short[8..12], 5, .little);
    try testing.expectError(error.Damaged, Table.open(testing.allocator, &short));
}
