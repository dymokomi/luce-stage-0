//! Does the reference still name everything the compiler has?
//!
//! The rest of this generator proves that every sample on the site
//! *runs* and prints what its page claims.  Nothing proved anything
//! about the prose around a sample, and the cost of that was measured:
//! a host expansion landed in the compiler, the standard library and
//! `programs/`, and two pages went on telling readers for a week that
//! nine shipped builtins were "not built".  A false negative does not
//! cost a reader a search; it costs them the feature.
//!
//! So the lists the compiler keeps are read here, out of the source
//! files, at test time — and a name the compiler has that the
//! reference does not is a **failed build**, on the commit that added
//! it, not on whoever next reads the page.
//!
//! ## What counts as "named"
//!
//! A name is documented when it appears, as a whole word, inside
//! inline code — a backtick span — on the page that owns it.  Fenced
//! blocks do not count: those are the samples, and a builtin merely
//! *used* by an example is not a builtin the reference describes.
//! That is a cheap check and deliberately so.  It cannot tell a good
//! table row from a bad one, and it is not trying to; it closes the
//! one failure this site actually had, which is a surface growing
//! while a page stands still.
//!
//! ## Why the sources are read rather than copied
//!
//! `highlight.zig` keeps pinned copies of the same tables and an
//! agreement test over them, because the highlighter must run inside
//! the generator and the generator links no part of the tree it
//! documents.  These checks have no such constraint: they run only
//! under `zig test`, where the repository is right there on disk.  So
//! they read it, and there is nothing to keep in step.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

// ---------------------------------------------------------------------------
// Finding the repository
// ---------------------------------------------------------------------------

/// A file that exists in this repository and nowhere else, used to
/// recognise the root while walking up from the working directory.
const landmark = "src/luce/06_mir/defs.zig";

/// How far up to look.  `zig build test` runs from the build root and
/// `site/build.sh` runs from wherever it was invoked; both are at or
/// under the repository, and nothing is nested eight deep inside it.
const max_ascent = 8;

const Repository = struct {
    gpa: Allocator,
    io: Io,
    /// `""` for the working directory itself, else `../`, `../../`, …
    prefix: []const u8,

    /// The bytes of one repository file, caller-owned.
    fn read(self: Repository, path: []const u8) ![]u8 {
        const full = try std.mem.concat(self.gpa, u8, &.{ self.prefix, path });
        defer self.gpa.free(full);
        return Io.Dir.cwd().readFileAlloc(self.io, full, self.gpa, .unlimited);
    }
};

/// The repository this generator documents, or an error naming what
/// went wrong.  A check that cannot find the tree must fail loudly:
/// silently passing is how a coverage test stops covering anything.
fn open(gpa: Allocator, io: Io) !Repository {
    var ascent: usize = 0;
    while (ascent <= max_ascent) : (ascent += 1) {
        const prefix = try repeat(gpa, "../", ascent);
        errdefer gpa.free(prefix);
        const probe = try std.mem.concat(gpa, u8, &.{ prefix, landmark });
        defer gpa.free(probe);
        if (Io.Dir.cwd().readFileAlloc(io, probe, gpa, .unlimited)) |bytes| {
            gpa.free(bytes);
            return .{ .gpa = gpa, .io = io, .prefix = prefix };
        } else |_| gpa.free(prefix);
    }
    std.debug.print(
        "coverage: no '{s}' within {d} levels above the working directory\n",
        .{ landmark, max_ascent },
    );
    return error.RepositoryNotFound;
}

fn repeat(gpa: Allocator, unit: []const u8, times: usize) ![]u8 {
    const text = try gpa.alloc(u8, unit.len * times);
    var at: usize = 0;
    while (at < text.len) : (at += unit.len) @memcpy(text[at..][0..unit.len], unit);
    return text;
}

// ---------------------------------------------------------------------------
// Reading a list out of a source file
// ---------------------------------------------------------------------------

/// The names collected from one source, and the page they must reach.
const Names = struct {
    gpa: Allocator,
    items: std.ArrayList([]u8) = .empty,

    fn deinit(self: *Names) void {
        for (self.items.items) |name| self.gpa.free(name);
        self.items.deinit(self.gpa);
    }

    fn add(self: *Names, name: []const u8) !void {
        for (self.items.items) |seen| {
            if (std.mem.eql(u8, seen, name)) return;
        }
        try self.items.append(self.gpa, try self.gpa.dupe(u8, name));
    }

    fn has(self: Names, name: []const u8) bool {
        for (self.items.items) |seen| {
            if (std.mem.eql(u8, seen, name)) return true;
        }
        return false;
    }
};

/// The text between `opening` and the next `closing`, or null.
fn between(source: []const u8, opening: []const u8, closing: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, source, opening) orelse return null;
    const body = source[start + opening.len ..];
    const stop = std.mem.indexOf(u8, body, closing) orelse return null;
    return body[0..stop];
}

/// Every `"..."` literal in `source` whose contents pass `keep`.
fn quotedWhere(
    names: *Names,
    source: []const u8,
    keep: *const fn ([]const u8) bool,
) !void {
    var at: usize = 0;
    while (std.mem.indexOfScalarPos(u8, source, at, '"')) |opening| {
        const closing = std.mem.indexOfScalarPos(u8, source, opening + 1, '"') orelse return;
        const text = source[opening + 1 .. closing];
        if (keep(text)) try names.add(text);
        at = closing + 1;
    }
}

fn isPlainName(text: []const u8) bool {
    if (text.len == 0) return false;
    if (!std.ascii.isAlphabetic(text[0]) and text[0] != '_') return false;
    for (text) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    }
    return true;
}

/// A line's leading identifier, when the line is `    name,` — how a
/// Zig enum spells its members.
fn enumMember(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (!std.mem.endsWith(u8, trimmed, ",")) return null;
    const name = trimmed[0 .. trimmed.len - 1];
    if (!isPlainName(name)) return null;
    return name;
}

// ---------------------------------------------------------------------------
// The compiler's lists
// ---------------------------------------------------------------------------

/// Every builtin the analyzer dispatches, from `lowerIntrinsic`'s own
/// table — the single place a builtin is added.
fn builtins(repository: Repository) !Names {
    var names: Names = .{ .gpa = repository.gpa };
    errdefer names.deinit();

    const source = try repository.read("src/luce/04_semantics/builder.zig");
    defer repository.gpa.free(source);

    const table = between(source, "const builtins = [_]Builtin{", "\n        };") orelse
        return error.BuiltinTableNotFound;

    var lines = std.mem.splitScalar(u8, table, '\n');
    while (lines.next()) |line| {
        const marker = ".{ .name = \"";
        const start = std.mem.indexOf(u8, line, marker) orelse continue;
        const rest = line[start + marker.len ..];
        const stop = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
        try names.add(rest[0..stop]);
    }
    if (names.items.items.len < 30) return error.BuiltinTableTooSmall;
    return names;
}

/// Every method name a receiver answers to: the four tables beside the
/// dispatch, plus the two String primitives the language keeps.
fn methods(repository: Repository) !Names {
    var names: Names = .{ .gpa = repository.gpa };
    errdefer names.deinit();

    const source = try repository.read("src/luce/04_semantics/builder.zig");
    defer repository.gpa.free(source);

    for ([_][]const u8{
        "const list_methods = [_][]const u8{",
        "const array_methods = [_][]const u8{",
        "const map_methods = [_][]const u8{",
        "const builder_methods = [_][]const u8{",
    }) |opening| {
        const table = between(source, opening, "};") orelse return error.MethodTableNotFound;
        try quotedWhere(&names, table, isPlainName);
    }
    // `byte_at` and `find_byte` are dispatched by name in the same
    // walk rather than out of a table, and are methods all the same.
    try names.add("byte_at");
    try names.add("find_byte");

    if (names.items.items.len < 15) return error.MethodTablesTooSmall;
    return names;
}

/// One Zig enum's members, by name.
fn enumMembers(repository: Repository, path: []const u8, declaration: []const u8) !Names {
    var names: Names = .{ .gpa = repository.gpa };
    errdefer names.deinit();

    const source = try repository.read(path);
    defer repository.gpa.free(source);

    const opening = try std.fmt.allocPrint(repository.gpa, "pub const {s} = enum {{\n", .{declaration});
    defer repository.gpa.free(opening);
    const body = between(source, opening, "\n\n") orelse return error.EnumNotFound;

    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (enumMember(line)) |name| try names.add(name);
    }
    if (names.items.items.len == 0) return error.EnumEmpty;
    return names;
}

/// The declarations one standard-library module exports: `func` for
/// the functions, top-level `let` for the constants.
fn standardModule(repository: Repository, module: []const u8) !Names {
    var names: Names = .{ .gpa = repository.gpa };
    errdefer names.deinit();

    const path = try std.fmt.allocPrint(repository.gpa, "src/luce/std/{s}.luc", .{module});
    defer repository.gpa.free(path);
    const source = try repository.read(path);
    defer repository.gpa.free(source);

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        for ([_][]const u8{ "func ", "let " }) |keyword| {
            if (!std.mem.startsWith(u8, line, keyword)) continue;
            const rest = line[keyword.len..];
            var stop: usize = 0;
            while (stop < rest.len and (std.ascii.isAlphanumeric(rest[stop]) or rest[stop] == '_'))
                stop += 1;
            if (stop != 0) try names.add(rest[0..stop]);
        }
    }
    if (names.items.items.len == 0) return error.StandardModuleEmpty;
    return names;
}

/// Every option `luce` parses, and every command word both binaries
/// dispatch on.  Options are recognised by shape — `-o`, or `--` and
/// lower-case letters — which is what keeps the sentence in
/// `--emit={s} is not one of …` out of the list.
fn commandLine(repository: Repository) !Names {
    var names: Names = .{ .gpa = repository.gpa };
    errdefer names.deinit();

    var spelled: Names = .{ .gpa = repository.gpa };
    defer spelled.deinit();
    const compiler = try repository.read("src/apps/luce/main.zig");
    defer repository.gpa.free(compiler);
    try quotedWhere(&spelled, compiler, isOption);
    // `--emit=` is matched with its `=` because it takes its value
    // attached; the option a page names is `--emit`.
    for (spelled.items.items) |option| try names.add(std.mem.trimEnd(u8, option, "="));

    // The command words, from the dispatch in each `main`.
    for ([_][]const u8{ "src/apps/luce/main.zig", "src/apps/loom/main.zig" }) |path| {
        const source = try repository.read(path);
        defer repository.gpa.free(source);
        var at: usize = 0;
        const marker = "std.mem.eql(u8, command, \"";
        while (std.mem.indexOfPos(u8, source, at, marker)) |start| {
            const rest = source[start + marker.len ..];
            const stop = std.mem.indexOfScalar(u8, rest, '"') orelse break;
            try names.add(rest[0..stop]);
            at = start + marker.len + stop;
        }
    }
    if (names.items.items.len < 8) return error.CommandLineTooSmall;
    return names;
}

fn isOption(text: []const u8) bool {
    if (std.mem.eql(u8, text, "-o")) return true;
    if (!std.mem.startsWith(u8, text, "--")) return false;
    const body = std.mem.trimEnd(u8, text[2..], "=");
    if (body.len == 0) return false;
    for (body) |byte| {
        if (!std.ascii.isLower(byte) and byte != '-') return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// What a page names
// ---------------------------------------------------------------------------

/// The **descriptive** code on one page: every inline backtick span,
/// plus every fenced block that carries no info string.
///
/// A fence with an info string is a sample or a sample's output —
/// `luce run`, `output`, `sh` — and does not count.  Those are the
/// machine-checked material, and a builtin a sample happens to call is
/// not a builtin the reference *describes*; counting one would let a
/// page lose a table row and still pass, which is the exact failure
/// these tests exist to stop.
///
/// A bare fence is prose set as code — a command synopsis, an import
/// line, a quoted diagnostic — and that is a page naming something.
fn describedCode(repository: Repository, page: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(repository.gpa, "site/content/{s}", .{page});
    defer repository.gpa.free(path);
    const source = try repository.read(path);
    defer repository.gpa.free(source);

    var spans: std.ArrayList(u8) = .empty;
    errdefer spans.deinit(repository.gpa);

    // The info string of the fence we are inside, or null for prose.
    var fence: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const bare = std.mem.trimStart(u8, line, " ");
        if (std.mem.startsWith(u8, bare, "```")) {
            fence = if (fence == null) std.mem.trim(u8, bare[3..], " ") else null;
            continue;
        }
        if (fence) |info| {
            if (info.len == 0) {
                try spans.appendSlice(repository.gpa, line);
                try spans.append(repository.gpa, ' ');
            }
            continue;
        }
        var at: usize = 0;
        while (std.mem.indexOfScalarPos(u8, line, at, '`')) |opening| {
            const closing = std.mem.indexOfScalarPos(u8, line, opening + 1, '`') orelse break;
            try spans.appendSlice(repository.gpa, line[opening + 1 .. closing]);
            try spans.append(repository.gpa, ' ');
            at = closing + 1;
        }
    }
    return spans.toOwnedSlice(repository.gpa);
}

fn isWordByte(byte: u8) bool {
    return byte == '_' or std.ascii.isAlphanumeric(byte);
}

/// Whether `name` stands as a whole word somewhere in `text`, so that
/// `len` is not found inside `length` and `find` is not found inside
/// `find_from`.
fn namesWord(text: []const u8, name: []const u8) bool {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, text, at, name)) |found| {
        const before_ok = found == 0 or !isWordByte(text[found - 1]);
        const after = found + name.len;
        const after_ok = after == text.len or !isWordByte(text[after]);
        if (before_ok and after_ok) return true;
        at = found + 1;
    }
    return false;
}

/// Hold one page to one list, naming every name it is missing.
///
/// `exempt` is for names the compiler carries that the reference
/// deliberately does not describe; each one needs a reason at its call
/// site, because an exemption is a decision and not an oversight.
fn expectDocumented(
    repository: Repository,
    page: []const u8,
    names: Names,
    exempt: []const []const u8,
) !void {
    const text = try describedCode(repository, page);
    defer repository.gpa.free(text);

    var missing: usize = 0;
    for (names.items.items) |name| {
        var skip = false;
        for (exempt) |allowed| {
            if (std.mem.eql(u8, allowed, name)) skip = true;
        }
        if (skip) continue;
        if (namesWord(text, name)) continue;
        std.debug.print("{s} does not name '{s}'\n", .{ page, name });
        missing += 1;
    }
    if (missing != 0) {
        std.debug.print("{s}: {d} name(s) the compiler has and the page does not\n", .{ page, missing });
        return error.UndocumentedSurface;
    }

    // And the other direction, for the exemptions only: an exemption
    // that names something the compiler no longer has is dead, and
    // would quietly excuse a real gap the day the name came back.
    for (exempt) |allowed| {
        if (names.has(allowed)) continue;
        std.debug.print("{s}: '{s}' is exempted and no longer exists\n", .{ page, allowed });
        return error.StaleExemption;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "the reference names every builtin the analyzer dispatches" {
    const gpa = std.testing.allocator;
    const repository = try open(gpa, std.testing.io);
    defer gpa.free(repository.prefix);

    var names = try builtins(repository);
    defer names.deinit();

    try expectDocumented(repository, "ref/builtins.md", names, &.{});
}

test "the reference names every method a receiver answers to" {
    const gpa = std.testing.allocator;
    const repository = try open(gpa, std.testing.io);
    defer gpa.free(repository.prefix);

    var names = try methods(repository);
    defer names.deinit();

    try expectDocumented(repository, "ref/builtins.md", names, &.{});
}

test "the reference names every trap code and every error code" {
    const gpa = std.testing.allocator;
    const repository = try open(gpa, std.testing.io);
    defer gpa.free(repository.prefix);

    // The codes live in the shared vocabulary — the one layer both the
    // compiler and the runtime read (support/vocabulary.zig); defs.zig
    // only re-exports them.
    var traps = try enumMembers(repository, "src/luce/support/vocabulary.zig", "TrapCode");
    defer traps.deinit();
    try expectDocumented(repository, "ref/failure.md", traps, &.{});

    var errors = try enumMembers(repository, "src/luce/support/vocabulary.zig", "ErrorCode");
    defer errors.deinit();
    try expectDocumented(repository, "ref/failure.md", errors, &.{});
}

test "each std page names every function and constant its module exports" {
    const gpa = std.testing.allocator;
    const repository = try open(gpa, std.testing.io);
    defer gpa.free(repository.prefix);

    {
        var names = try standardModule(repository, "math");
        defer names.deinit();
        try expectDocumented(repository, "std/math.md", names, &.{});
    }
    {
        var names = try standardModule(repository, "files");
        defer names.deinit();
        try expectDocumented(repository, "std/files.md", names, &.{});
    }
    {
        var names = try standardModule(repository, "strings");
        defer names.deinit();
        // `is_space_byte` and `fold_case` are the two internal helpers
        // the language has no `private` to hide, and the status page
        // says so by name.  Giving them table rows would advertise a
        // leak as an API; the fix is visibility, not documentation.
        try expectDocumented(repository, "std/strings.md", names, &.{
            "is_space_byte",
            "fold_case",
        });
    }
}

test "the toolchain page names every option and command word the binaries take" {
    const gpa = std.testing.allocator;
    const repository = try open(gpa, std.testing.io);
    defer gpa.free(repository.prefix);

    var names = try commandLine(repository);
    defer names.deinit();

    try expectDocumented(repository, "guide/toolchain.md", names, &.{});
}

test "a name is found only as a whole word" {
    // The whole check rests on this: a longer name never satisfies a
    // shorter one, or `find` would be documented by `find_from` and
    // `len` by the word "length".
    try std.testing.expect(namesWord("file_rename( dir_list(", "dir_list"));
    try std.testing.expect(!namesWord("file_rename( dir_list(", "file_read"));
    // Whole words only: a longer name never satisfies a shorter one.
    try std.testing.expect(!namesWord("find_from(s, needle, start)", "find"));
    try std.testing.expect(!namesWord("length", "len"));
    try std.testing.expect(namesWord("len(x) -> Int", "len"));
}

test "an option is recognised by shape, and a sentence about one is not" {
    try std.testing.expect(isOption("-o"));
    try std.testing.expect(isOption("--release"));
    try std.testing.expect(isOption("--emit="));
    try std.testing.expect(isOption("--full"));
    try std.testing.expect(!isOption("--emit={s} is not one of library, object, exe"));
    try std.testing.expect(!isOption("-"));
    try std.testing.expect(!isOption("build"));
}
