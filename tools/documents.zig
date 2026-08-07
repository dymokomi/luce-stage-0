//! Which documents the guards hold to the language, and in which of
//! the two senses.
//!
//! A list rather than a directory, because `docs/` holds both kinds
//! and only one of them is bound by the strict reading.
//!
//! It lives in a file of its own because two tools read it and neither
//! can import the other: `doccheck.zig` imports `luce` to compile the
//! samples, and `spelling.zig` imports nothing at all and should keep
//! it that way.  They kept a list each, "meant to be read together",
//! and they disagreed by one — `docs/README.md` was spell-guarded and
//! its samples were never compiled.  One declaration, one truth.
//!
//! Paths are relative to the repository root, which is where the build
//! runs its tests from — the same assumption `tools/grammar.zig`
//! makes.

/// **Living** documents: a reader may paste any of this into a file
/// and have it work today.  Their Luce must compile, their prose may
/// not spell a retired type name, and they carry no exemptions.
pub const living = [_][]const u8{
    "docs/LANGUAGE.md",
    "docs/OWNERSHIP.md",
    "docs/STD.md",
    "docs/CODEGEN.md",
    "docs/MISSING.md",
    "docs/ENGINE.md",
    "docs/MODES.md",
    "docs/PIPELINE.md",
    "docs/CODING_GUIDE.md",
    "docs/README.md",
    "README.md",
    "CLAUDE.md",
};

/// **Decision records**: what was decided and when.  Their code is
/// checked too — a memo that shows the language of its day is welcome
/// to, and says so with `historical`; what it may not do is show code
/// that reads as current and is not.  The tag is the whole exemption
/// and one grep lists every use of it.
pub const records = [_][]const u8{
    "docs/METHODS.md",
    "docs/RETURNS.md",
    "docs/NUMERICS.md",
    "docs/STRINGS.md",
    "docs/FAILURE.md",
    "docs/MEMORY.md",
    "docs/V2.md",
    "docs/TYPES.md",
    "docs/VECTOR.md",
    "docs/ARGS.md",
    "docs/VISIBILITY.md",
    "docs/BITWISE.md",
    "docs/ENUMS.md",
    "docs/BYTES.md",
    "docs/CONCURRENCY_RESEARCH.md",
    "docs/UNION_RESEARCH.md",
    "docs/UNION.md",
    "docs/THREADS.md",
    "docs/LINKING_RESEARCH.md",
};

/// Both, living first — so "the living documents carry no exemptions"
/// is a slice rather than a convention.
pub const all = living ++ records;

// ---------------------------------------------------------------------------
// The pin: this list and `docs/README.md` are one catalogue
// ---------------------------------------------------------------------------
//
// `docs/README.md` is the human face of the two arrays above — one
// table per sense, one row per file.  Nothing made them agree, and they
// drifted: three files sat under the wrong heading and five were in
// neither catalogue at all, which is how a reader learned that
// `docs/BYTES.md` existed by running `ls`.  The tests below make the
// two halves one thing.  Adding a document is now: the file, one row,
// one array entry — and forgetting either of the last two fails
// `zig build test` rather than going quiet.

const std = @import("std");
const testing = std.testing;

/// The two senses a document is written in, and the two headings
/// `docs/README.md` sorts them under.
const Sense = enum { living, record };

/// Which sense a document is catalogued in, or `null` for one that is
/// in neither array.
fn senseOf(path: []const u8) ?Sense {
    for (living) |one| if (std.mem.eql(u8, one, path)) return .living;
    for (records) |one| if (std.mem.eql(u8, one, path)) return .record;
    return null;
}

/// `docs/README.md` lists itself nowhere: it is the table, not a row in
/// it.  Everything else in the catalogue that lives under `docs/` is
/// expected to have one.
const index_page = "docs/README.md";

/// Reads `docs/README.md` and answers, for each row, which heading it
/// was written under.  A row is a table line whose first cell is a
/// markdown link — `| [NAME.md](NAME.md) | … |` — and the heading it
/// belongs to is whichever `## Current` / `## Decision records` last
/// went by.  Caller owns the map and its keys.
fn readIndexRows(
    gpa: std.mem.Allocator,
    io: std.Io,
) !std.StringHashMapUnmanaged(Sense) {
    var rows: std.StringHashMapUnmanaged(Sense) = .empty;
    errdefer {
        var keys = rows.keyIterator();
        while (keys.next()) |key| gpa.free(key.*);
        rows.deinit(gpa);
    }

    const text = try std.Io.Dir.cwd().readFileAlloc(io, index_page, gpa, .unlimited);
    defer gpa.free(text);

    var heading: ?Sense = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "## Current")) heading = .living;
        if (std.mem.startsWith(u8, line, "## Decision records")) heading = .record;
        if (std.mem.startsWith(u8, line, "## History")) heading = null;
        if (std.mem.startsWith(u8, line, "## Audits")) heading = null;

        const sense = heading orelse continue;
        if (!std.mem.startsWith(u8, line, "| [")) continue;

        // `| [MODES.md](MODES.md) | …` — the target, which is relative
        // to `docs/`, is what names the file.
        const opens = std.mem.indexOfScalar(u8, line, '(') orelse continue;
        const closes = std.mem.indexOfScalarPos(u8, line, opens, ')') orelse continue;
        const target = line[opens + 1 .. closes];
        if (!std.mem.endsWith(u8, target, ".md")) continue;

        const path = try std.fmt.allocPrint(gpa, "docs/{s}", .{target});
        errdefer gpa.free(path);
        try rows.put(gpa, path, sense);
    }
    return rows;
}

test "every catalogued document has a row in docs/README.md, under the right heading" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var rows = try readIndexRows(gpa, threaded.io());
    defer {
        var keys = rows.keyIterator();
        while (keys.next()) |key| gpa.free(key.*);
        rows.deinit(gpa);
    }

    var missing: usize = 0;
    for (all) |path| {
        // The two repository-root documents are not `docs/`'s to list,
        // and the index does not list itself.
        if (!std.mem.startsWith(u8, path, "docs/")) continue;
        if (std.mem.eql(u8, path, index_page)) continue;

        const row = rows.get(path) orelse {
            std.debug.print("{s} is catalogued but has no row in {s}\n", .{ path, index_page });
            missing += 1;
            continue;
        };
        const sense = senseOf(path).?;
        if (row != sense) {
            std.debug.print(
                "{s} is {s} in documents.zig and {s} in {s}\n",
                .{ path, @tagName(sense), @tagName(row), index_page },
            );
            missing += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), missing);
}

test "every row in docs/README.md names a catalogued document" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var rows = try readIndexRows(gpa, threaded.io());
    defer {
        var keys = rows.keyIterator();
        while (keys.next()) |key| gpa.free(key.*);
        rows.deinit(gpa);
    }

    var stray: usize = 0;
    var listed = rows.keyIterator();
    while (listed.next()) |path| {
        if (senseOf(path.*) == null) {
            std.debug.print("{s} has a row in {s} and is in neither array\n", .{ path.*, index_page });
            stray += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), stray);
    // A parse that reads nothing agrees with everything, which is the
    // one way these two tests could pass while saying nothing.
    try testing.expect(rows.count() >= 20);
}

test "no document in docs/ is outside the catalogue" {
    // The check that makes the two above worth having: a new memo
    // dropped into `docs/` is in neither array and so in neither table,
    // and nothing would have noticed.  Sub-directories are deliberately
    // not walked — `docs/v1/` is the frozen Fabric era and `docs/audit/`
    // is dated point-in-time review, and neither is catalogued.
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var directory = try std.Io.Dir.cwd().openDir(io, "docs", .{ .iterate = true });
    defer directory.close(io);

    var uncatalogued: usize = 0;
    var seen: usize = 0;
    var entries = directory.iterate();
    while (try entries.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        seen += 1;

        var buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&buffer, "docs/{s}", .{entry.name});
        if (senseOf(path) == null) {
            std.debug.print("{s} is in neither documents.zig array\n", .{path});
            uncatalogued += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), uncatalogued);
    try testing.expect(seen >= 20);
}
