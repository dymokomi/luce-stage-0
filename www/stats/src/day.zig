//! A day, in UTC, spelled the one way everything here spells it.
//!
//! Every count is filed under a `YYYY-MM-DD` string and the dashboard
//! plots those strings in order, so the whole system needs exactly one
//! rule about what day a timestamp falls on.  It is this file, it is
//! UTC, and it does not change with where the server or the reader is.
//!
//! Going backwards is subtraction on the timestamp rather than
//! arithmetic on the date, because a day here is only ever "the day
//! containing this instant" — there is no calendar to get wrong.

const std = @import("std");

pub const length = "YYYY-MM-DD".len;
pub const Text = [length]u8;

/// The UTC day containing `at`, written into `buffer` and returned.
pub fn write(buffer: *Text, at: i64) []const u8 {
    // Before the epoch there are no logs, and `EpochSeconds` is unsigned.
    const seconds: u64 = if (at < 0) 0 else @intCast(at);
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    _ = std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
    }) catch unreachable;
    return buffer[0..];
}

/// The day `count` days before the one containing `at`.
pub fn before(buffer: *Text, at: i64, count: i64) []const u8 {
    return write(buffer, at - count * std.time.s_per_day);
}

const testing = std.testing;

test "a timestamp lands on its UTC day" {
    var buffer: Text = undefined;
    // 2026-08-13T21:07:29Z — the first line the access log ever held.
    try testing.expectEqualStrings("2026-08-13", write(&buffer, 1786655249));
    // Midnight UTC is the first instant of its day...
    try testing.expectEqualStrings("2026-08-13", write(&buffer, 1786579200));
    // ...and one second earlier is the last instant of the day before.
    try testing.expectEqualStrings("2026-08-12", write(&buffer, 1786579199));
    try testing.expectEqualStrings("1970-01-01", write(&buffer, 0));
    try testing.expectEqualStrings("1970-01-01", write(&buffer, -5));
}

test "leap days exist" {
    var buffer: Text = undefined;
    try testing.expectEqualStrings("2024-02-29", write(&buffer, 1709164800));
    try testing.expectEqualStrings("2024-03-01", write(&buffer, 1709251200));
}

test "going back a day crosses a month and a year" {
    var buffer: Text = undefined;
    const at: i64 = 1786655249; // 2026-08-13
    try testing.expectEqualStrings("2026-08-13", before(&buffer, at, 0));
    try testing.expectEqualStrings("2026-08-12", before(&buffer, at, 1));
    try testing.expectEqualStrings("2026-07-31", before(&buffer, at, 13));
    try testing.expectEqualStrings("2025-08-13", before(&buffer, at, 365));
}
