//! The project manifest: `luce.yaml`, read as a strictly defined
//! subset of YAML (docs/PACKAGES.md D1).
//!
//! The subset is scalars, one level of nesting — top-level keys and
//! one indented map level — string values, and `#` comments.  No
//! anchors, no aliases, no flow style, no multi-document markers, no
//! type tags, no quoting: a manifest that uses YAML the subset
//! refuses is refused by name, with a line number, and never
//! half-read.  A hand-written parser is the point — `std.yaml` will
//! later speak the same subset from Luce, and a file both can read in
//! full is a file neither has to guess about.
//!
//! This is host-side machinery, beside the loader it will feed: the
//! compiler core never touches a filesystem and never learns what a
//! manifest is.  In this step a parsed manifest only establishes the
//! project root (`files.discoverProject`); the want list starts
//! resolving when the store does.
//!
//! Ownership: everything `parse` answers points into `text` or into
//! the arena it was given, so there is nothing to free — the caller
//! keeps both alive as long as the result.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// What the file is called, everywhere it is looked for.
pub const file_name = "luce.yaml";

/// One row of the want list (or of the override section): an exact
/// version, and the two optional annotations.
pub const Entry = struct {
    name: []const u8,
    /// Exact, always — no ranges, no `^`/`~`.  Upgrading is editing
    /// the number.
    version: []const u8,
    /// Content hash, verified when present; null means unverified.
    sha256: ?[]const u8 = null,
    /// Development override: resolve from this directory instead of
    /// the store.
    path: ?[]const u8 = null,
};

/// A well-formed project file.
pub const Manifest = struct {
    name: []const u8,
    version: []const u8,
    /// What a bare `luce build` builds: a project-root-relative source
    /// path, or null for a project that names none — the bare form
    /// then refuses and names this key as the remedy.  Optional
    /// because a library project has no entry program.
    main: ?[]const u8 = null,
    packages: []const Entry = &.{},
    override: []const Entry = &.{},
};

/// Why a file could not be a manifest.  The reason names the exact
/// rule; the line is where it was met, or 0 when the problem is the
/// whole file (a required key that never appeared).
pub const Refusal = struct {
    line: usize,
    reason: []const u8,
};

pub const Result = union(enum) {
    manifest: Manifest,
    refused: Refusal,
};

/// Parse manifest text, whole or not at all.
pub fn parse(arena: Allocator, text: []const u8) error{OutOfMemory}!Result {
    var project_name: ?[]const u8 = null;
    var project_version: ?[]const u8 = null;
    var project_main: ?[]const u8 = null;
    var packages: std.ArrayList(Entry) = .empty;
    var overrides: std.ArrayList(Entry) = .empty;
    var seen_packages = false;
    var seen_override = false;

    const Section = enum { none, packages, override };
    var section: Section = .none;
    // The indent the open map's first entry chose; every entry after
    // it must match, which is what makes a second level impossible.
    var section_indent: ?usize = null;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_number: usize = 0;
    while (lines.next()) |raw| {
        line_number += 1;
        const line = std.mem.trimEnd(u8, raw, "\r");

        var indent: usize = 0;
        while (indent < line.len and line[indent] == ' ') indent += 1;
        if (indent < line.len and line[indent] == '\t') {
            return refuse(arena, line_number, "indentation uses a tab; the manifest subset indents with spaces", .{});
        }
        const rest = line[indent..];
        if (rest.len == 0) continue;
        if (rest[0] == '#') continue;

        if (std.mem.eql(u8, rest, "---") or std.mem.startsWith(u8, rest, "--- ") or std.mem.eql(u8, rest, "...")) {
            return refuse(arena, line_number, "multi-document markers are not in the manifest subset", .{});
        }
        if (rest[0] == '%') {
            return refuse(arena, line_number, "directives are not in the manifest subset", .{});
        }

        const colon = std.mem.indexOfScalar(u8, rest, ':') orelse
            return refuse(arena, line_number, "a manifest line is written key: value", .{});
        const key = std.mem.trimEnd(u8, rest[0..colon], " ");
        if (key.len == 0) return refuse(arena, line_number, "a manifest line is written key: value", .{});
        if (colon + 1 < rest.len and rest[colon + 1] != ' ') {
            return refuse(arena, line_number, "a space separates {s}: from its value", .{key});
        }
        const value_text = rest[colon + 1 ..];

        if (indent == 0) {
            // A top-level construct closes whatever map was open.
            section = .none;
            section_indent = null;

            const is_name = std.mem.eql(u8, key, "name");
            const is_version = std.mem.eql(u8, key, "version");
            if (is_name or is_version or std.mem.eql(u8, key, "main")) {
                var words = std.mem.tokenizeAny(u8, value_text, " \t");
                var value: ?[]const u8 = null;
                while (words.next()) |word| {
                    if (word[0] == '#') break;
                    if (badToken(word)) |reason| return refuse(arena, line_number, "{s}", .{reason});
                    if (value != null) return refuse(arena, line_number, "{s}: takes one value", .{key});
                    value = word;
                }
                const given = value orelse return refuse(arena, line_number, "{s}: names nothing", .{key});
                const slot = if (is_name) &project_name else if (is_version) &project_version else &project_main;
                if (slot.* != null) return refuse(arena, line_number, "{s}: is given twice", .{key});
                slot.* = given;
                continue;
            }

            const is_packages = std.mem.eql(u8, key, "packages");
            if (is_packages or std.mem.eql(u8, key, "override")) {
                var words = std.mem.tokenizeAny(u8, value_text, " \t");
                while (words.next()) |word| {
                    if (word[0] == '#') break;
                    if (badToken(word)) |reason| return refuse(arena, line_number, "{s}", .{reason});
                    return refuse(arena, line_number, "{s}: opens a map; its entries are indented below it", .{key});
                }
                const seen = if (is_packages) &seen_packages else &seen_override;
                if (seen.*) return refuse(arena, line_number, "{s}: is given twice", .{key});
                seen.* = true;
                section = if (is_packages) .packages else .override;
                section_indent = null;
                continue;
            }

            return refuse(arena, line_number, "{s} is not a manifest key; the keys are name, version, main, packages and override", .{key});
        }

        // Indented: an entry of the open map.
        if (section == .none) {
            return refuse(arena, line_number, "this line is indented, but nothing above it opens a map", .{});
        }
        if (section_indent) |expected| {
            if (indent > expected) return refuse(arena, line_number, "nesting deeper than one level is not in the manifest subset", .{});
            if (indent < expected) return refuse(arena, line_number, "this line indents {d} spaces where the map indents {d}", .{ indent, expected });
        } else {
            section_indent = indent;
        }

        if (!isPackageName(key)) {
            return refuse(arena, line_number, "{s} cannot name a package; a package name is a letter followed by letters, digits or underscores", .{key});
        }
        if (std.mem.eql(u8, key, "std")) {
            return refuse(arena, line_number, "a package cannot be named std; that namespace is reserved for the standard library", .{});
        }

        const list = if (section == .packages) &packages else &overrides;
        for (list.items) |entry| {
            if (std.mem.eql(u8, entry.name, key)) {
                return refuse(arena, line_number, "package {s} is named twice", .{key});
            }
        }

        var words = std.mem.tokenizeAny(u8, value_text, " \t");
        var version: ?[]const u8 = null;
        var sha256: ?[]const u8 = null;
        var override_path: ?[]const u8 = null;
        while (words.next()) |word| {
            if (word[0] == '#') break;
            if (badToken(word)) |reason| return refuse(arena, line_number, "{s}", .{reason});
            if (version == null) {
                if (std.mem.indexOfScalar(u8, word, ':') != null) {
                    return refuse(arena, line_number, "package {s} must name its version before any annotation", .{key});
                }
                version = word;
                continue;
            }
            const split = std.mem.indexOfScalar(u8, word, ':') orelse
                return refuse(arena, line_number, "{s} is not a package annotation; sha256: and path: are", .{word});
            const prefix = word[0..split];
            const payload = word[split + 1 ..];
            if (payload.len == 0) return refuse(arena, line_number, "{s}: names nothing", .{prefix});
            if (std.mem.eql(u8, prefix, "sha256")) {
                if (sha256 != null) return refuse(arena, line_number, "sha256: is given twice", .{});
                sha256 = payload;
            } else if (std.mem.eql(u8, prefix, "path")) {
                if (override_path != null) return refuse(arena, line_number, "path: is given twice", .{});
                override_path = payload;
            } else {
                return refuse(arena, line_number, "{s}: is not a package annotation; sha256: and path: are", .{prefix});
            }
        }
        const wanted = version orelse
            return refuse(arena, line_number, "package {s} names no version; a want is exact, like geo: 1.2.0", .{key});
        try list.append(arena, .{ .name = key, .version = wanted, .sha256 = sha256, .path = override_path });
    }

    const named = project_name orelse
        return refuse(arena, 0, "the manifest names no project; name: is required", .{});
    const versioned = project_version orelse
        return refuse(arena, 0, "the manifest names no version; version: is required", .{});
    return .{ .manifest = .{
        .name = named,
        .version = versioned,
        .main = project_main,
        .packages = try packages.toOwnedSlice(arena),
        .override = try overrides.toOwnedSlice(arena),
    } };
}

fn refuse(arena: Allocator, line: usize, comptime format: []const u8, arguments: anytype) error{OutOfMemory}!Result {
    return .{ .refused = .{
        .line = line,
        .reason = try std.fmt.allocPrint(arena, format, arguments),
    } };
}

/// The YAML the subset refuses, named at the first byte of a value
/// word — which is the one place any of it could begin.
fn badToken(word: []const u8) ?[]const u8 {
    return switch (word[0]) {
        '&' => "anchors are not in the manifest subset",
        '*' => "aliases are not in the manifest subset",
        '!' => "type tags are not in the manifest subset",
        '[', '{' => "flow style is not in the manifest subset",
        '"', '\'' => "quoted values are not in the manifest subset; write the value bare",
        else => null,
    };
}

/// A package name has to be importable one day: a letter, then
/// letters, digits or underscores — the shape of a Luce module name.
fn isPackageName(name: []const u8) bool {
    if (name.len == 0 or !std.ascii.isAlphabetic(name[0])) return false;
    for (name[1..]) |character| {
        if (!std.ascii.isAlphanumeric(character) and character != '_') return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn parsed(arena: Allocator, text: []const u8) !Manifest {
    switch (try parse(arena, text)) {
        .manifest => |manifest| return manifest,
        .refused => |refusal| {
            std.debug.print("unexpected refusal at line {d}: {s}\n", .{ refusal.line, refusal.reason });
            return error.TestUnexpectedResult;
        },
    }
}

test "the example manifest parses whole" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const manifest = try parsed(arena.allocator(),
        \\name: atlas
        \\version: 0.3.0
        \\
        \\packages:
        \\  geo: 1.2.0
        \\  ansi: 0.4.1 sha256:9f2a...        # hash verified when present
        \\  mathx: 1.1.0 path:../mathx       # development override (D3)
        \\
    );
    try testing.expectEqualStrings("atlas", manifest.name);
    try testing.expectEqualStrings("0.3.0", manifest.version);
    try testing.expectEqual(@as(usize, 3), manifest.packages.len);
    try testing.expectEqual(@as(usize, 0), manifest.override.len);

    try testing.expectEqualStrings("geo", manifest.packages[0].name);
    try testing.expectEqualStrings("1.2.0", manifest.packages[0].version);
    try testing.expect(manifest.packages[0].sha256 == null);
    try testing.expect(manifest.packages[0].path == null);

    try testing.expectEqualStrings("9f2a...", manifest.packages[1].sha256.?);
    try testing.expectEqualStrings("../mathx", manifest.packages[2].path.?);
    try testing.expectEqualStrings("1.1.0", manifest.packages[2].version);
}

test "the override section is the same shape as the want list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const manifest = try parsed(arena.allocator(),
        \\name: atlas
        \\version: 0.3.0
        \\packages:
        \\  geo: 1.2.0
        \\override:
        \\  json: 2.0.1
        \\
    );
    try testing.expectEqual(@as(usize, 1), manifest.override.len);
    try testing.expectEqualStrings("json", manifest.override[0].name);
    try testing.expectEqualStrings("2.0.1", manifest.override[0].version);
}

test "comments vanish: whole lines, trailing words, inside a map" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const manifest = try parsed(arena.allocator(),
        \\# the project file
        \\name: atlas # the project
        \\version: 0.3.0
        \\packages:
        \\  # the want list
        \\  geo: 1.2.0   # exact
        \\
    );
    try testing.expectEqualStrings("atlas", manifest.name);
    try testing.expectEqual(@as(usize, 1), manifest.packages.len);
    try testing.expectEqualStrings("1.2.0", manifest.packages[0].version);
}

test "what the subset refuses, it refuses by name with a line number" {
    const refusals = [_]struct {
        text: []const u8,
        line: usize,
        naming: []const u8,
    }{
        .{ .text = "name: &a atlas\nversion: 1.0.0\n", .line = 1, .naming = "anchors" },
        .{ .text = "name: atlas\nversion: *a\n", .line = 2, .naming = "aliases" },
        .{ .text = "name: !!str atlas\nversion: 1.0.0\n", .line = 1, .naming = "type tags" },
        .{ .text = "name: atlas\nversion: 1.0.0\npackages: {geo: 1.2.0}\n", .line = 3, .naming = "flow style" },
        .{ .text = "name: [atlas]\nversion: 1.0.0\n", .line = 1, .naming = "flow style" },
        .{ .text = "name: \"atlas\"\nversion: 1.0.0\n", .line = 1, .naming = "quoted" },
        .{ .text = "---\nname: atlas\nversion: 1.0.0\n", .line = 1, .naming = "multi-document" },
        .{ .text = "%YAML 1.2\nname: atlas\nversion: 1.0.0\n", .line = 1, .naming = "directives" },
        .{ .text = "name: atlas\nversion: 1.0.0\npackages:\n\tgeo: 1.2.0\n", .line = 4, .naming = "tab" },
        .{ .text = "name: atlas\nversion: 1.0.0\npackages:\n  geo: 1.2.0\n    extra: 1\n", .line = 5, .naming = "deeper than one level" },
        .{ .text = "name: atlas\nversion: 1.0.0\npackages:\n    geo: 1.2.0\n  ansi: 0.4.1\n", .line = 5, .naming = "indents" },
        .{ .text = "version: 1.0.0\n", .line = 0, .naming = "name: is required" },
        .{ .text = "name: atlas\n", .line = 0, .naming = "version: is required" },
        .{ .text = "", .line = 0, .naming = "name: is required" },
        .{ .text = "name: atlas\nname: other\nversion: 1.0.0\n", .line = 2, .naming = "given twice" },
        .{ .text = "name: atlas\nversion: 1.0.0\npackages:\n  geo: 1.2.0\n  geo: 1.3.0\n", .line = 5, .naming = "named twice" },
        .{ .text = "name: atlas\nversion: 1.0.0\npackage:\n  geo: 1.2.0\n", .line = 3, .naming = "not a manifest key" },
        .{ .text = "name: atlas\nversion: 1.0.0\n  geo: 1.2.0\n", .line = 3, .naming = "nothing above it opens a map" },
        .{ .text = "name: atlas\nversion: 1.0.0\npackages:\n  std: 1.0.0\n", .line = 4, .naming = "reserved" },
        .{ .text = "name: atlas\nversion: 1.0.0\npackages:\n  geo: 1.2.0 md5:abc\n", .line = 4, .naming = "not a package annotation" },
        .{ .text = "name: atlas\nversion: 1.0.0\npackages:\n  geo:\n", .line = 4, .naming = "names no version" },
        .{ .text = "name: atlas\nversion: 1.0.0\npackages:\n  geo: sha256:abc\n", .line = 4, .naming = "version before any annotation" },
        .{ .text = "name: atlas\nversion: 1.0.0\npackages:\n  9lives: 1.0.0\n", .line = 4, .naming = "cannot name a package" },
        .{ .text = "name atlas\nversion: 1.0.0\n", .line = 1, .naming = "key: value" },
        .{ .text = "name:atlas\nversion: 1.0.0\n", .line = 1, .naming = "space separates" },
        .{ .text = "name: atlas extra\nversion: 1.0.0\n", .line = 1, .naming = "takes one value" },
        .{ .text = "name: atlas\nversion: 1.0.0\npackages: geo\n", .line = 3, .naming = "opens a map" },
    };
    for (refusals) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        switch (try parse(arena.allocator(), case.text)) {
            .manifest => {
                std.debug.print("expected a refusal naming '{s}', but this parsed:\n{s}\n", .{ case.naming, case.text });
                return error.TestUnexpectedResult;
            },
            .refused => |refusal| {
                try testing.expectEqual(case.line, refusal.line);
                if (std.mem.indexOf(u8, refusal.reason, case.naming) == null) {
                    std.debug.print("refusal '{s}' does not name '{s}'\n", .{ refusal.reason, case.naming });
                    return error.TestUnexpectedResult;
                }
            },
        }
    }
}
