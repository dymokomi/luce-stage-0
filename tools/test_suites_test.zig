//! Structural guard for `tools/test_suites.zig`.
//!
//! A new executable-specification file must be assigned deliberately before
//! the release gate can go green.  This is the counterpart to
//! `src/luce/specs.zig`'s import roster: that file makes tests run; this one
//! makes their ownership visible and non-overlapping.

const std = @import("std");
const suites = @import("test_suites.zig");
const testing = std.testing;

test "every executable-specification file has exactly one suite" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var directory = try std.Io.Dir.cwd().openDir(io, "src/luce/specs", .{ .iterate = true });
    defer directory.close(io);

    var seen: usize = 0;
    var entries = directory.iterate();
    while (try entries.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, "_spec.zig")) continue;
        const stem = entry.name[0 .. entry.name.len - ".zig".len];
        var buffer: [128]u8 = undefined;
        const test_name = try std.fmt.bufPrint(&buffer, "specs.{s}.test.audit", .{stem});
        if (suites.matchCount(test_name) != 1) {
            std.debug.print("{s} belongs to {d} test suites\n", .{
                entry.name,
                suites.matchCount(test_name),
            });
        }
        try testing.expectEqual(@as(usize, 1), suites.matchCount(test_name));
        seen += 1;
    }

    // This is a tripwire, not the source of truth: the directory scan above
    // says which names are wrong, while the count ensures a narrowed scan
    // cannot quietly make the guard green.
    try testing.expectEqual(@as(usize, 21), seen);
}

test "harness and backend tests are assigned without catching unit tests" {
    try testing.expectEqual(@as(usize, 1), suites.matchCount("specs.agree.test.audit"));
    try testing.expectEqual(@as(usize, 1), suites.matchCount("specs.hosts.test.audit"));
    try testing.expectEqual(@as(usize, 1), suites.matchCount("08_llvm.test.test.audit"));
    try testing.expectEqual(@as(usize, 0), suites.matchCount("runtime.test.audit"));
}

test "suite definitions and enum rows stay one to one" {
    var seen = [_]bool{false} ** @typeInfo(suites.Suite).@"enum".fields.len;
    for (suites.definitions) |candidate| {
        const index = @intFromEnum(candidate.suite);
        try testing.expect(!seen[index]);
        seen[index] = true;
        try testing.expect(candidate.filters.len != 0);
        try testing.expectEqual(candidate.suite, suites.definition(candidate.suite).suite);
    }
    for (seen) |present| try testing.expect(present);
}
