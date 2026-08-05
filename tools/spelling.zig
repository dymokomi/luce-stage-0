//! The guard on the rename: **no Luce source in this repository may
//! spell a builtin type with its retired TitleCase name.**
//!
//! `docs/TYPES.md` asks for this one by name, and gives the reason.
//! The rename it guards was mechanically safe while `Int` and `Float`
//! were aliases for the types `long` and `double` name; the resize
//! after it is safe only if the rename was *complete*.  A missed
//! `array(Float, ...)` is the single migration failure that
//! type-checks: it would quietly become a 32-bit array and change
//! results with no diagnostic anywhere, in a program nobody edited.
//!
//! So the check is a grep that fails the build, and it looks in the
//! three places Luce source lives:
//!
//!   * `.luc` files — the corpus, the standard library, the
//!     benchmarks, the site's included sample programs;
//!   * fenced `luce` blocks in `site/content/**.md` — the samples the
//!     site compiles and runs;
//!   * multiline string literals in `src/luce/specs/**.zig` — the
//!     executable specification's programs.
//!
//! It deliberately does *not* read Zig prose or the compiler's own
//! sources: `std.zig.llvm.Builder` is a real name and the memo's
//! sentences about the old spellings have to be able to say them.
//!
//! Paths are relative to the repository root, which is where the build
//! runs its tests from — the same assumption `tools/grammar.zig`'s pin
//! test makes about the committed grammar.

const std = @import("std");

/// The names that must not appear, and what each is written as now.
/// The same list `support/types.zig`'s `retiredSpelling` answers with,
/// stated again here rather than imported, because this tool's job is
/// to disagree with the tree and a shared constant would let one edit
/// silence both halves.
const retired = [_]struct { was: []const u8, now: []const u8 }{
    .{ .was = "Int", .now = "long" },
    .{ .was = "Float", .now = "double" },
    .{ .was = "Bool", .now = "bool" },
    .{ .was = "String", .now = "string" },
    .{ .was = "List", .now = "list" },
    .{ .was = "Map", .now = "map" },
    .{ .was = "Array", .now = "array" },
    .{ .was = "Builder", .now = "builder" },
};

/// Where Luce source lives, and how much of each file is Luce.
const Scope = enum {
    /// Every line.
    whole_file,
    /// Only the lines inside a fenced ```luce block.
    fenced_luce,
    /// Only the lines that are Zig multiline-string continuations.
    zig_multiline,
};

const Tree = struct { path: []const u8, suffix: []const u8, scope: Scope };

const trees = [_]Tree{
    .{ .path = "programs", .suffix = ".luc", .scope = .whole_file },
    .{ .path = "bench", .suffix = ".luc", .scope = .whole_file },
    .{ .path = "src/luce/std", .suffix = ".luc", .scope = .whole_file },
    .{ .path = "site/content", .suffix = ".md", .scope = .fenced_luce },
    .{ .path = "src/luce/specs", .suffix = ".zig", .scope = .zig_multiline },
};

/// One place a retired name still appears.
pub const Sighting = struct {
    file: []const u8,
    line: usize,
    was: []const u8,
    now: []const u8,
};

/// Every retired spelling still written in Luce source under the
/// repository root.  The caller owns the list and every `file` in it.
pub fn survey(gpa: std.mem.Allocator, io: std.Io) !std.ArrayList(Sighting) {
    var found: std.ArrayList(Sighting) = .empty;
    errdefer {
        for (found.items) |item| gpa.free(item.file);
        found.deinit(gpa);
    }
    for (trees) |tree| {
        try surveyTree(gpa, io, &found, tree, tree.path);
    }
    return found;
}

/// One directory and everything under it.  Written as a recursion
/// rather than a `Walker` because the directory handle is what carries
/// the `Io` here, and the depth involved is three.
fn surveyTree(
    gpa: std.mem.Allocator,
    io: std.Io,
    found: *std.ArrayList(Sighting),
    tree: Tree,
    where: []const u8,
) !void {
    var directory = std.Io.Dir.cwd().openDir(io, where, .{ .iterate = true }) catch return;
    defer directory.close(io);
    var entries = directory.iterate();
    while (try entries.next(io)) |entry| {
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ where, entry.name });
        var kept = false;
        defer if (!kept) gpa.free(path);
        if (entry.kind == .directory) {
            try surveyTree(gpa, io, found, tree, path);
            continue;
        }
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, tree.suffix)) continue;
        const text = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        defer gpa.free(text);
        const before = found.items.len;
        try scan(gpa, found, path, text, tree.scope);
        // The path is borrowed by every sighting in this file, or by
        // none — it is freed above when nothing kept it.
        kept = found.items.len != before;
    }
}

/// Suspends and resumes the scan.  There is exactly one thing these
/// are for: **a program whose whole subject is the refusal has to be
/// able to write the refused name.**  The specs that pin
/// `luce.sema.type: Int is written long` are the only such programs,
/// and a grep for `spelling:off` lists every exemption in the tree in
/// one line each, which is the property that keeps it honest.
const suppress = "spelling:off";
const resume_scan = "spelling:on";

fn scan(
    gpa: std.mem.Allocator,
    into: *std.ArrayList(Sighting),
    where: []const u8,
    text: []const u8,
    scope: Scope,
) !void {
    var inside_fence = false;
    var suppressed = false;
    var number: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        number += 1;
        if (std.mem.indexOf(u8, line, suppress) != null) suppressed = true;
        if (std.mem.indexOf(u8, line, resume_scan) != null) suppressed = false;
        if (suppressed) continue;
        const trimmed = std.mem.trimStart(u8, line, " \t");
        const looking = switch (scope) {
            .whole_file => true,
            .fenced_luce => fence: {
                if (std.mem.startsWith(u8, trimmed, "```")) {
                    // A fence either opens a luce block or closes one.
                    inside_fence = !inside_fence and
                        std.mem.startsWith(u8, trimmed["```".len..], "luce");
                    break :fence false;
                }
                break :fence inside_fence;
            },
            .zig_multiline => std.mem.startsWith(u8, trimmed, "\\\\"),
        };
        if (!looking) continue;
        for (retired) |gone| {
            if (!wordIn(line, gone.was)) continue;
            try into.append(gpa, .{
                .file = where,
                .line = number,
                .was = gone.was,
                .now = gone.now,
            });
        }
    }
}

/// True when `word` appears in `line` as a whole word — bounded on
/// both sides by something that is not an identifier character, so
/// `Int` is found in `array(Int, _)` and not in `parseInt` or `Integer`.
fn wordIn(line: []const u8, word: []const u8) bool {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, line, at, word)) |found| {
        at = found + 1;
        if (found > 0 and isWordByte(line[found - 1])) continue;
        const after = found + word.len;
        if (after < line.len and isWordByte(line[after])) continue;
        return true;
    }
    return false;
}

fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

const testing = std.testing;

test "no Luce source in the tree spells a builtin type the retired way" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var found = try survey(gpa, threaded.io());
    defer {
        for (found.items) |item| gpa.free(item.file);
        found.deinit(gpa);
    }
    if (found.items.len == 0) return;
    // Every one of them, not the first: a partial rename is the one
    // state from which the resize does damage, so the reader wants the
    // whole list in one run rather than one line per rebuild.
    for (found.items) |item| {
        std.debug.print(
            "{s}:{d}: {s} is written {s} now (docs/TYPES.md D8)\n",
            .{ item.file, item.line, item.was, item.now },
        );
    }
    return error.TestUnexpectedResult;
}

test "the scan reads only the part of a file that is Luce" {
    const gpa = testing.allocator;
    var found: std.ArrayList(Sighting) = .empty;
    defer found.deinit(gpa);

    // Markdown: inside a luce fence counts, outside it does not, and a
    // fence of another language does not open one.
    try scan(gpa, &found, "page.md",
        \\Prose about Int, which is only prose.
        \\```zig
        \\const x: Int = 1;
        \\```
        \\```luce
        \\let a: Int = 1
        \\```
        \\More prose about Float.
    , .fenced_luce);
    try testing.expectEqual(@as(usize, 1), found.items.len);
    try testing.expectEqual(@as(usize, 6), found.items[0].line);
    found.clearRetainingCapacity();

    // Zig: only the continuation lines.
    try scan(gpa, &found, "spec.zig",
        \\// A comment mentioning Int.
        \\    \\func main():
        \\    \\    let a: Int = 1
        \\const Builder = @This();
    , .zig_multiline);
    try testing.expectEqual(@as(usize, 1), found.items.len);
    try testing.expectEqual(@as(usize, 3), found.items[0].line);
    found.clearRetainingCapacity();

    // Whole word only: the guard must not fire on `parseInt`.
    try scan(gpa, &found, "main.luc", "let n = parse_int(s)\nlet m: Integer = 1\n", .whole_file);
    try testing.expectEqual(@as(usize, 0), found.items.len);
}

test "the scan can be suspended, and resumes where it is told to" {
    const gpa = testing.allocator;
    var found: std.ArrayList(Sighting) = .empty;
    defer found.deinit(gpa);
    try scan(gpa, &found, "spec.zig",
        \\// spelling:off — this program's subject is the refusal
        \\    \\let a: Int = 1
        \\// spelling:on
        \\    \\let b: Float = 1.5
    , .zig_multiline);
    try testing.expectEqual(@as(usize, 1), found.items.len);
    try testing.expectEqual(@as(usize, 4), found.items[0].line);
    try testing.expectEqualStrings("Float", found.items[0].was);
}
