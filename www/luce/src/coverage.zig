//! Does the reference still name everything the compiler has?
//!
//! The rest of this generator proves that every sample on the site
//! *runs* and prints what its page claims.  Nothing proved anything
//! about the prose around a sample, and the cost of that was measured:
//! a host expansion landed in the compiler, the standard library and
//! `examples/`, and two pages went on telling readers for a week that
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
//! `highlight.zig` keeps pinned copies of the same tables, because the
//! highlighter must run inside the generator and the generator links no
//! part of the tree it documents.  These checks have no such
//! constraint: they run only under `zig test`, where the repository is
//! right there on disk.  So they read it, and there is nothing to keep
//! in step.
//!
//! Which is why the highlighter's own guard lives down here rather than
//! beside its tables (last section).  It used to sit in `highlight.zig`
//! and check the copies against a *second* copy, so it proved only that
//! the copy equalled the copy; it passed while the tables lost five
//! type names and kept three deleted builtins.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const highlight = @import("highlight.zig");

// ---------------------------------------------------------------------------
// Finding the repository
// ---------------------------------------------------------------------------

/// A file that exists in this repository and nowhere else, used to
/// recognise the root while walking up from the working directory.
const landmark = "src/luce/mir/defs.zig";

/// How far up to look.  `zig build test` runs from the build root and
/// `www/luce/build.sh` runs from wherever it was invoked; both are at or
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

/// Add every whitespace-delimited identifier in a prose roster.  The
/// lexical page deliberately presents its exact keyword and reserved
/// sets as bare code blocks; parsing that small, explicit shape keeps
/// the guard about the roster rather than incidental prose nearby.
fn plainWords(names: *Names, source: []const u8) !void {
    var words = std.mem.tokenizeAny(u8, source, " \t\r\n");
    while (words.next()) |word| {
        if (isPlainName(word)) try names.add(word);
    }
}

/// Exact set equality with useful failures in both directions.  A
/// forward-only documentation check catches additions but lets a page
/// keep names the language removed; vocabulary tables need both halves.
fn expectSameNames(label: []const u8, expected: Names, actual: Names) !void {
    var wrong: usize = 0;
    for (expected.items.items) |name| {
        if (actual.has(name)) continue;
        std.debug.print("{s}: missing '{s}'\n", .{ label, name });
        wrong += 1;
    }
    for (actual.items.items) |name| {
        if (expected.has(name)) continue;
        std.debug.print("{s}: stale '{s}'\n", .{ label, name });
        wrong += 1;
    }
    if (wrong != 0) return error.VocabularyDisagreesWithLanguage;
}

/// The value of `pub const NAME... = <digits>;` in a repository source
/// — how the tree writes a version number.  The declaration must be at
/// column zero and its value a plain integer, which is what makes a
/// renamed or restructured declaration an error here rather than a
/// number that quietly stops being read.
fn declaredNumber(repository: Repository, path: []const u8, name: []const u8) !u32 {
    const source = try repository.read(path);
    defer repository.gpa.free(source);

    const opening = try std.fmt.allocPrint(repository.gpa, "\npub const {s}", .{name});
    defer repository.gpa.free(opening);
    const written = between(source, opening, ";") orelse {
        std.debug.print("coverage: {s} declares no {s}\n", .{ path, name });
        return error.DeclarationNotFound;
    };
    const equals = std.mem.indexOfScalar(u8, written, '=') orelse return error.DeclarationNotFound;
    const digits = std.mem.trim(u8, written[equals + 1 ..], " ");
    return std.fmt.parseInt(u32, digits, 10) catch error.DeclarationNotFound;
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

/// The first quoted field of every row of a `.{ .field = "name", … }`
/// table, where `marker` is the opening of that field.  How four of the
/// compiler's lists are written.
fn rowNames(names: *Names, table: []const u8, marker: []const u8) !void {
    var lines = std.mem.splitScalar(u8, table, '\n');
    while (lines.next()) |line| {
        const start = std.mem.indexOf(u8, line, marker) orelse continue;
        const rest = line[start + marker.len ..];
        const stop = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
        try names.add(rest[0..stop]);
    }
}

/// Every builtin the analyzer dispatches, from the file-scope table it
/// reads — the single place a builtin is added.
fn builtins(repository: Repository) !Names {
    var names: Names = .{ .gpa = repository.gpa };
    errdefer names.deinit();

    const source = try repository.read("src/luce/semantics/builtins.zig");
    defer repository.gpa.free(source);

    // The table's own closing brace, at column zero — not the first
    // `};` at *any* indentation, which is what this used to look for
    // and which ran past the end of the table into whatever declaration
    // came next. Keep the read bounded to the table itself so a later
    // declaration cannot silently become part of the public roster.
    const table = between(source, "const builtins = [_]Builtin{", "\n};") orelse
        return error.BuiltinTableNotFound;

    // A top-level row starts at one indent; a parameter *slot* is a
    // `.{ .name = "…" }` one indent deeper (docs/ARGS.md §3), and
    // must not read as a builtin of its own — `fg` is not a builtin.
    var lines = std.mem.splitScalar(u8, table, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, builtin_row_marker)) continue;
        const rest = line[builtin_row_marker.len..];
        const stop = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
        try names.add(rest[0..stop]);
    }
    if (names.items.items.len < 30) return error.BuiltinTableTooSmall;
    return names;
}

/// How a top-level builtin row opens, at the table's own indent.
const builtin_row_marker = "    .{ .name = \"";

/// One builtin and the parameter names its table row declares — the
/// signature docs/ARGS.md §3 says the table is.
const BuiltinSignature = struct {
    name: []const u8,
    parameters: [][]const u8,
};

/// Every builtin's parameter names, parsed from the same table text
/// `builtins` reads.  A one-line row carries its slots inline; a
/// multi-line row (`term_style`) carries one slot per deeper-indented
/// line.  Caller frees with `freeSignatures`.
fn builtinSignatures(repository: Repository) ![]BuiltinSignature {
    const source = try repository.read("src/luce/semantics/builtins.zig");
    defer repository.gpa.free(source);
    const table = between(source, "const builtins = [_]Builtin{", "\n};") orelse
        return error.BuiltinTableNotFound;

    var rows: std.ArrayList(BuiltinSignature) = .empty;
    errdefer freeSignaturesList(repository.gpa, &rows);
    var parameters: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (parameters.items) |parameter| repository.gpa.free(parameter);
        parameters.deinit(repository.gpa);
    }

    var lines = std.mem.splitScalar(u8, table, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, builtin_row_marker)) {
            if (rows.items.len != 0) {
                rows.items[rows.items.len - 1].parameters = try parameters.toOwnedSlice(repository.gpa);
            }
            const rest = line[builtin_row_marker.len..];
            const stop = std.mem.indexOfScalar(u8, rest, '"') orelse return error.BuiltinTableDamaged;
            try rows.append(repository.gpa, .{
                .name = try repository.gpa.dupe(u8, rest[0..stop]),
                .parameters = &.{},
            });
            // Inline slots on the same line, past the builtin's own
            // `.name`.
            try slotNames(repository.gpa, &parameters, rest[stop..]);
            continue;
        }
        // A slot line of a multi-line row.
        if (rows.items.len != 0) try slotNames(repository.gpa, &parameters, line);
    }
    if (rows.items.len != 0) {
        rows.items[rows.items.len - 1].parameters = try parameters.toOwnedSlice(repository.gpa);
    }
    return rows.toOwnedSlice(repository.gpa);
}

/// Every `.name = "…"` in `text` — the slots of one row's remainder.
fn slotNames(gpa: std.mem.Allocator, into: *std.ArrayList([]const u8), text: []const u8) !void {
    const marker = ".name = \"";
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, text, at, marker)) |found| {
        const rest = text[found + marker.len ..];
        const stop = std.mem.indexOfScalar(u8, rest, '"') orelse return;
        try into.append(gpa, try gpa.dupe(u8, rest[0..stop]));
        at = found + marker.len + stop;
    }
}

fn freeSignatures(gpa: std.mem.Allocator, rows: []BuiltinSignature) void {
    for (rows) |row| {
        gpa.free(row.name);
        for (row.parameters) |parameter| gpa.free(parameter);
        gpa.free(row.parameters);
    }
    gpa.free(rows);
}

fn freeSignaturesList(gpa: std.mem.Allocator, rows: *std.ArrayList(BuiltinSignature)) void {
    for (rows.items) |row| {
        gpa.free(row.name);
        for (row.parameters) |parameter| gpa.free(parameter);
        gpa.free(row.parameters);
    }
    rows.deinit(gpa);
}

/// Every word the lexer reserves, from `lex/token.zig`'s one table.
fn lexerKeywords(repository: Repository) !Names {
    var names: Names = .{ .gpa = repository.gpa };
    errdefer names.deinit();

    const source = try repository.read("src/luce/lex/token.zig");
    defer repository.gpa.free(source);

    const table = between(source, "pub const keywords = [_]struct { word: []const u8, kind: Kind }{", "\n};") orelse
        return error.KeywordTableNotFound;

    try rowNames(&names, table, ".{ .word = \"");
    if (names.items.items.len < 20) return error.KeywordTableTooSmall;
    return names;
}

/// Every name the language keeps for itself, which no program may
/// redeclare — so every one of them may stand in a sample meaning what
/// the language means by it.
fn reservedNames(repository: Repository) !Names {
    var names: Names = .{ .gpa = repository.gpa };
    errdefer names.deinit();

    const source = try repository.read("src/luce/semantics/context.zig");
    defer repository.gpa.free(source);

    const table = between(source, "pub const reserved_names = [_][]const u8{", "\n};") orelse
        return error.ReservedNamesNotFound;

    try quotedWhere(&names, table, isPlainName);
    if (names.items.items.len < 40) return error.ReservedNamesTooSmall;
    return names;
}

/// Every method name a receiver answers to: the six tables beside the
/// dispatch, plus the two String primitives the language keeps.
fn methods(repository: Repository) !Names {
    var names: Names = .{ .gpa = repository.gpa };
    errdefer names.deinit();

    const source = try repository.read("src/luce/semantics/builtins.zig");
    defer repository.gpa.free(source);

    for ([_][]const u8{
        "const list_methods = [_][]const u8{",
        "const array_methods = [_][]const u8{",
        "const map_methods = [_][]const u8{",
        "const builder_methods = [_][]const u8{",
        "const file_methods = [_][]const u8{",
        "const task_methods = [_][]const u8{",
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

/// Update `depth` for the structural braces on one Zig source line.
/// Strings, character literals, line comments and multiline-string
/// payload lines do not contain syntax braces.
fn scanBraceDepth(line: []const u8, depth: *usize) bool {
    if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "\\\\")) return false;

    var quoted: ?u8 = null;
    var escaped = false;
    var at: usize = 0;
    while (at < line.len) : (at += 1) {
        const byte = line[at];
        if (quoted) |closing| {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == closing) {
                quoted = null;
            }
            continue;
        }
        if (byte == '/' and at + 1 < line.len and line[at + 1] == '/') break;
        if (byte == '"' or byte == '\'') {
            quoted = byte;
        } else if (byte == '{') {
            depth.* += 1;
        } else if (byte == '}') {
            if (depth.* == 0) return true;
            depth.* -= 1;
            if (depth.* == 0) return true;
        }
    }
    return false;
}

/// One Zig enum's top-level members, by name.  Declarations inside an
/// enum may contain blank lines and their own brace trees; neither may
/// truncate the roster or manufacture members from a nested body.
fn enumMembersFromSource(gpa: Allocator, source: []const u8, declaration: []const u8) !Names {
    var names: Names = .{ .gpa = gpa };
    errdefer names.deinit();

    const opening = try std.fmt.allocPrint(gpa, "pub const {s} = enum {{", .{declaration});
    defer gpa.free(opening);
    const start = std.mem.indexOf(u8, source, opening) orelse return error.EnumNotFound;
    const body = source[start + opening.len ..];

    var depth: usize = 1;
    var found_end = false;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (depth == 1) {
            if (enumMember(line)) |name| try names.add(name);
        }
        if (scanBraceDepth(line, &depth)) {
            found_end = true;
            break;
        }
    }
    if (!found_end) return error.EnumNotFound;
    if (names.items.items.len == 0) return error.EnumEmpty;
    return names;
}

test "enum member coverage spans blanks and ignores nested declarations" {
    const source =
        \\pub const Example = enum {
        \\    first,
        \\
        \\    /// A documented member; braces here are prose: { }.
        \\    second,
        \\
        \\    pub fn word(value: Example) []const u8 {
        \\        return switch (value) {
        \\            impostor,
        \\            .first => "{",
        \\            .second => "}",
        \\        };
        \\    }
        \\
        \\    tail,
        \\};
        \\
        \\pub const Later = enum {
        \\    outside,
        \\};
    ;

    var names = try enumMembersFromSource(std.testing.allocator, source, "Example");
    defer names.deinit();
    try std.testing.expectEqual(@as(usize, 3), names.items.items.len);
    try std.testing.expect(names.has("first"));
    try std.testing.expect(names.has("second"));
    try std.testing.expect(names.has("tail"));
    try std.testing.expect(!names.has("impostor"));
    try std.testing.expect(!names.has("outside"));
}

fn enumMembers(repository: Repository, path: []const u8, declaration: []const u8) !Names {
    const source = try repository.read(path);
    defer repository.gpa.free(source);
    return enumMembersFromSource(repository.gpa, source, declaration);
}

/// The declarations one standard-library module exports: `func` for
/// the functions, file-scope `const` for the constants.
fn standardModule(repository: Repository, module: []const u8) !Names {
    var names: Names = .{ .gpa = repository.gpa };
    errdefer names.deinit();

    const path = try std.fmt.allocPrint(repository.gpa, "src/luce/std/{s}.luc", .{module});
    defer repository.gpa.free(path);
    const source = try repository.read(path);
    defer repository.gpa.free(source);

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        for ([_][]const u8{ "func ", "const " }) |keyword| {
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

/// The method spellings backed by a standard module's private
/// specialization templates. They are not top-level module exports,
/// so `standardModule` is intentionally blind to them; the analyzer's
/// registration string is the public route's single source of truth.
fn routedStandardMethods(repository: Repository, module: []const u8) !Names {
    var names: Names = .{ .gpa = repository.gpa };
    errdefer names.deinit();

    const source = try repository.read("src/luce/semantics/calls.zig");
    defer repository.gpa.free(source);
    const opening = try std.fmt.allocPrint(repository.gpa, "\"{s}.", .{module});
    defer repository.gpa.free(opening);
    const suffix = "_template";

    var at: usize = 0;
    while (std.mem.indexOfPos(u8, source, at, opening)) |start| {
        const rest = source[start + opening.len ..];
        const stop = std.mem.indexOfScalar(u8, rest, '"') orelse break;
        const registered = rest[0..stop];
        if (std.mem.endsWith(u8, registered, suffix)) {
            try names.add(registered[0 .. registered.len - suffix.len]);
        }
        at = start + opening.len + stop + 1;
    }
    if (names.items.items.len == 0) return error.StandardRouteEmpty;
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
    const path = try std.fmt.allocPrint(repository.gpa, "www/luce/content/{s}", .{page});
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

    try expectDocumented(repository, "guide/reference/builtins.md", names, &.{});
}

test "the reference names every builtin's parameters" {
    // One level down from the test above (docs/ARGS.md §3): the table
    // is the builtin's signature, so the line of guide/reference/builtins.md that
    // shows `name(` must carry every parameter name the table
    // declares.  This is what stops the table and the prose drifting
    // the way the old grammar drifted.
    const gpa = std.testing.allocator;
    const repository = try open(gpa, std.testing.io);
    defer gpa.free(repository.prefix);

    const rows = try builtinSignatures(repository);
    defer freeSignatures(gpa, rows);
    try std.testing.expect(rows.len >= 30);

    const page = try repository.read("www/luce/content/guide/reference/builtins.md");
    defer gpa.free(page);

    var missing: usize = 0;
    for (rows) |row| {
        if (row.parameters.len == 0) continue;
        const opened = try std.fmt.allocPrint(gpa, "{s}(", .{row.name});
        defer gpa.free(opened);
        var found_signature = false;
        var lines = std.mem.splitScalar(u8, page, '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, opened) == null) continue;
            found_signature = true;
            for (row.parameters) |parameter| {
                if (namesWord(line, parameter)) continue;
                std.debug.print("guide/reference/builtins.md: the {s} line does not name its parameter '{s}'\n", .{ row.name, parameter });
                missing += 1;
            }
            break;
        }
        if (!found_signature) {
            std.debug.print("guide/reference/builtins.md never shows {s}(…)\n", .{row.name});
            missing += 1;
        }
    }
    if (missing != 0) return error.UndocumentedBuiltinParameters;
}

test "the reference names every method a receiver answers to" {
    const gpa = std.testing.allocator;
    const repository = try open(gpa, std.testing.io);
    defer gpa.free(repository.prefix);

    var names = try methods(repository);
    defer names.deinit();

    try expectDocumented(repository, "guide/reference/builtins.md", names, &.{});
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
    try expectDocumented(repository, "guide/reference/failure.md", traps, &.{});

    var errors = try enumMembers(repository, "src/luce/support/vocabulary.zig", "ErrorCode");
    defer errors.deinit();
    try expectDocumented(repository, "guide/reference/failure.md", errors, &.{});
}

test "each std page names every function and constant its module exports" {
    const gpa = std.testing.allocator;
    const repository = try open(gpa, std.testing.io);
    defer gpa.free(repository.prefix);

    {
        var names = try standardModule(repository, "math");
        defer names.deinit();
        try expectDocumented(repository, "library/math.md", names, &.{});
    }
    {
        var names = try standardModule(repository, "files");
        defer names.deinit();
        try expectDocumented(repository, "library/files.md", names, &.{});
    }
    {
        // `std.lists` exposes routed list methods. Its checked source
        // template is private, so documenting `sort_by_template` as a
        // namespace export would be the wrong contract.
        var names = try routedStandardMethods(repository, "lists");
        defer names.deinit();
        try expectDocumented(repository, "library/lists.md", names, &.{});
    }
    {
        var names = try standardModule(repository, "paths");
        defer names.deinit();
        try expectDocumented(repository, "library/paths.md", names, &.{});
    }
    {
        var names = try standardModule(repository, "os");
        defer names.deinit();
        try expectDocumented(repository, "library/os.md", names, &.{});
    }
    {
        var names = try standardModule(repository, "strings");
        defer names.deinit();
        // No exemptions: `is_space_byte` and `fold_case` are marked
        // `private` now, so they are not surface and the roster above
        // never sees them — the fix item 10 promised, delivered by
        // visibility rather than by documentation.
        try expectDocumented(repository, "library/strings.md", names, &.{});
    }
    {
        var names = try standardModule(repository, "zip");
        defer names.deinit();
        // No exemptions: everything below the surface — the
        // little-endian field readers, the DEFLATE tables, the
        // Huffman construction — is `private`, so the roster is the
        // eight functions the page documents and nothing else.
        try expectDocumented(repository, "library/zip.md", names, &.{});
    }
    {
        var names = try standardModule(repository, "json");
        defer names.deinit();
        // No exemptions: everything below the surface — the scanners,
        // the escape decoder, the byte names of the grammar — is
        // `private`, so the roster is `parse` and `quote`, and the
        // page's tables carry the methods those two hand back.
        try expectDocumented(repository, "library/json.md", names, &.{});
    }
    {
        var names = try standardModule(repository, "gpu");
        defer names.deinit();
        try expectDocumented(repository, "library/gpu.md", names, &.{});
    }
    {
        var names = try standardModule(repository, "ui");
        defer names.deinit();
        try expectDocumented(repository, "library/ui.md", names, &.{});
    }
}

test "the reference keeps function value and lambda syntax visible" {
    // Name rosters catch a missing builtin, but they did not catch two
    // pages continuing to say that functions were not values. Pin the
    // new type and expression spellings and the exact stale claims
    // whose survival exposed that hole.
    const gpa = std.testing.allocator;
    const repository = try open(gpa, std.testing.io);
    defer gpa.free(repository.prefix);

    const types = try describedCode(repository, "guide/reference/types.md");
    defer gpa.free(types);
    try std.testing.expect(std.mem.indexOf(u8, types, "func(i64, i64) -> bool") != null);

    const expressions = try describedCode(repository, "guide/reference/expressions.md");
    defer gpa.free(expressions);
    try std.testing.expect(std.mem.indexOf(u8, expressions, "(n) -> n * 2") != null);

    for ([_][]const u8{ "guide/reference/expressions.md", "guide/reference/statements.md" }) |page| {
        const path = try std.fmt.allocPrint(gpa, "www/luce/content/{s}", .{page});
        defer gpa.free(path);
        const text = try repository.read(path);
        defer gpa.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, "Functions are not values") == null);
        try std.testing.expect(std.mem.indexOf(u8, text, "no first-class functions") == null);
    }
}

test "the public site keeps constant containers and map literals visible" {
    // Grammar generation proves the tokens exist. Pin the cross-page
    // semantic boundary too: one file-scope word, runtime braces, the
    // program root, list-only slicing, and the hidden-provenance trap.
    const gpa = std.testing.allocator;
    const repository = try open(gpa, std.testing.io);
    defer gpa.free(repository.prefix);

    const lexical = try repository.read("www/luce/content/guide/reference/lexical.md");
    defer gpa.free(lexical);
    try std.testing.expect(std.mem.indexOf(u8, lexical, "`const` declares a file-scope") != null);
    try std.testing.expect(std.mem.indexOf(u8, lexical, "map literals") != null);

    const expressions = try repository.read("www/luce/content/guide/reference/expressions.md");
    defer gpa.free(expressions);
    try std.testing.expect(std.mem.indexOf(u8, expressions, "{\"one\": 1, \"two\": 2}") != null);
    try std.testing.expect(std.mem.indexOf(u8, expressions, "Empty `{}` is refused") != null);

    const statements = try repository.read("www/luce/content/guide/reference/statements.md");
    defer gpa.free(statements);
    for ([_][]const u8{
        "program root",
        "Arrays have indexing and iteration",
        "container may not expose a private element type",
        "A parameter default may share a constant container",
    }) |claim| {
        try std.testing.expect(std.mem.indexOf(u8, statements, claim) != null);
    }

    const memory = try repository.read("www/luce/content/guide/reference/memory.md");
    defer gpa.free(memory);
    try std.testing.expect(std.mem.indexOf(u8, memory, "### M11 — constants live in the program root") != null);

    const failure = try repository.read("www/luce/content/guide/reference/failure.md");
    defer gpa.free(failure);
    try std.testing.expect(std.mem.indexOf(u8, failure, "`immutable_object`") != null);

    const zip = try repository.read("www/luce/content/library/zip.md");
    defer gpa.free(zip);
    try std.testing.expect(std.mem.indexOf(u8, zip, "All six are immutable") != null);
}

test "the reference keeps implied self and static visible" {
    // Keyword coverage proves `static` is coloured, not that the site
    // explains the call and mutation rules it creates. Pin the public
    // pages that carry the surface and the version split SELF added.
    const gpa = std.testing.allocator;
    const repository = try open(gpa, std.testing.io);
    defer gpa.free(repository.prefix);

    const statements = try repository.read("www/luce/content/guide/reference/statements.md");
    defer gpa.free(statements);
    for ([_][]const u8{
        "**method** with an implied `self`",
        "static func name(param: Type)",
        "bare mutable binding",
        "Writes completed before an",
    }) |claim| {
        try std.testing.expect(std.mem.indexOf(u8, statements, claim) != null);
    }

    const expressions = try repository.read("www/luce/content/guide/reference/expressions.md");
    defer gpa.free(expressions);
    try std.testing.expect(std.mem.indexOf(u8, expressions, "`Point.length(p)` is refused") != null);

    const types = try repository.read("www/luce/content/guide/reference/types.md");
    defer gpa.free(types);
    try std.testing.expect(std.mem.indexOf(u8, types, "inside a struct is a method with implied") != null);
    try std.testing.expect(std.mem.indexOf(u8, types, "A `static func` has no receiver") != null);

    const lexical = try repository.read("www/luce/content/guide/reference/lexical.md");
    defer gpa.free(lexical);
    try std.testing.expect(std.mem.indexOf(u8, lexical, "`static` belongs immediately before `func`") != null);

    const toolchain = try repository.read("www/luce/content/tools/command-line.md");
    defer gpa.free(toolchain);
    try std.testing.expect(std.mem.indexOf(u8, toolchain, "Current release label:") != null);
}

test "the toolchain page carries the module format and host ABI the tree has" {
    // **Derived, never pinned.**  A literal here would enforce whatever
    // the page said on the day it was written: the numbers were 38 and
    // 15 while the tree said 39, and this check was what kept the page
    // saying so.  Both numbers are read out of the sources that declare
    // them, so the page can only disagree with the compiler by failing
    // the build.
    const gpa = std.testing.allocator;
    const repository = try open(gpa, std.testing.io);
    defer gpa.free(repository.prefix);

    const toolchain = try repository.read("www/luce/content/tools/command-line.md");
    defer gpa.free(toolchain);

    const format = try declaredNumber(repository, "src/luce/mir/module.zig", "format_version");
    const published = try declaredNumber(repository, "src/luce/codegen/abi.zig", "version");

    const claims = [_][]u8{
        try std.fmt.allocPrint(gpa, "`format_version = {d}`", .{format}),
        try std.fmt.allocPrint(gpa, "`abi.version = {d}`", .{published}),
        // The number is written twice on the page — once as prose,
        // once as the split from the release label — and both are the
        // compiler's.
        try std.fmt.allocPrint(gpa, "current `.lcm` format is **{d}**", .{format}),
        try std.fmt.allocPrint(gpa, "published host ABI is **{d}**", .{published}),
    };
    defer for (claims) |claim| gpa.free(claim);
    for (claims) |claim| {
        if (std.mem.indexOf(u8, toolchain, claim) != null) continue;
        std.debug.print("tools/command-line.md does not say {s}\n", .{claim});
        return error.TestUnexpectedResult;
    }
}

test "the reference keeps existing-name multi-return assignment visible" {
    // The implementation can be correct while the prose still says
    // the old refusal. Pin both the receiving syntax and the guarded
    // all-or-nothing form, then reject the exact claims they retired.
    const gpa = std.testing.allocator;
    const repository = try open(gpa, std.testing.io);
    defer gpa.free(repository.prefix);

    for ([_][]const u8{ "guide/reference/statements.md", "guide/reference/expressions.md" }) |page| {
        const code = try describedCode(repository, page);
        defer gpa.free(code);
        try std.testing.expect(std.mem.indexOf(u8, code, "low, high = minmax(xs)") != null);
    }

    const failure = try describedCode(repository, "guide/reference/failure.md");
    defer gpa.free(failure);
    try std.testing.expect(std.mem.indexOf(u8, failure, "left, right = read_pair() catch reason:") != null);

    for ([_][]const u8{ "guide/reference/statements.md", "guide/reference/expressions.md" }) |page| {
        const path = try std.fmt.allocPrint(gpa, "www/luce/content/{s}", .{page});
        defer gpa.free(path);
        const source = try repository.read(path);
        defer gpa.free(source);
        try std.testing.expect(std.mem.indexOf(u8, source, "Plain multi-assignment is **not** a statement") == null);
        try std.testing.expect(std.mem.indexOf(u8, source, "may stand in exactly two places") == null);
        try std.testing.expect(std.mem.indexOf(u8, source, "propagated with `try`, or discarded as a statement") == null);
    }
}

test "the toolchain page names every option and command word the binaries take" {
    const gpa = std.testing.allocator;
    const repository = try open(gpa, std.testing.io);
    defer gpa.free(repository.prefix);

    var names = try commandLine(repository);
    defer names.deinit();

    try expectDocumented(repository, "tools/command-line.md", names, &.{});
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

/// Every name the language answers to as a *type*, out of the one
/// table both the parser and the analyzer resolve through.
///
/// These reach a program two ways and the reference owes a reader
/// both: as an annotation (`var n: i16 = 1`) and, for the scalars,
/// as the conversion constructor named for the type it produces
/// (`i16(x)` — docs/NUMERICS.md §7).  Neither was checked until the
/// ladder grew to seven, and the gap was the same shape as the one
/// this file was written for: `u8`, `i16` and `f16` landed in the
/// compiler and `guide/reference/builtins.md` went on listing four conversions.
fn typeNames(repository: Repository) !Names {
    var names: Names = .{ .gpa = repository.gpa };
    errdefer names.deinit();

    const source = try repository.read("src/luce/support/types.zig");
    defer repository.gpa.free(source);

    const table = between(source, "const builtin_table = [_]struct { name: []const u8, is: Builtin }{", "\n};") orelse
        return error.TypeTableNotFound;

    try rowNames(&names, table, ".{ .name = \"");
    if (names.items.items.len < 10) return error.TypeTableTooSmall;
    return names;
}

test "the reference names every type the language answers to" {
    const gpa = std.testing.allocator;
    const repository = try open(gpa, std.testing.io);
    defer gpa.free(repository.prefix);

    var names = try typeNames(repository);
    defer names.deinit();

    try expectDocumented(repository, "guide/reference/types.md", names, &.{});
}

test "the reference names every conversion constructor" {
    // The scalars from the same table are also functions — `u8(x)`,
    // `f16(x)`, `str(x)` — and `guide/reference/builtins.md` is where a reader
    // looks for a function.  `bool` and the four containers are not
    // conversions (`types.conversionNamed` refuses them), so they are
    // exempt here and covered by the type test above.
    const gpa = std.testing.allocator;
    const repository = try open(gpa, std.testing.io);
    defer gpa.free(repository.prefix);

    var names = try typeNames(repository);
    defer names.deinit();

    try expectDocumented(repository, "guide/reference/builtins.md", names, &.{
        "bool",
        "list",
        "map",
        "array",
        "builder",
        // `file` and `task` are resources rather than conversions, and
        // neither is a function at all: one is opened and the other is
        // spawned.  `guide/reference/types.md` is where a reader looks for them.
        "task",
    });
}

// ---------------------------------------------------------------------------
// The highlighter's word tables
// ---------------------------------------------------------------------------

/// Every name the language spells, out of the six tables that spell
/// them.  The caller owns it.
fn vocabulary(repository: Repository) !Names {
    var names: Names = .{ .gpa = repository.gpa };
    errdefer names.deinit();

    const readers = [_]*const fn (Repository) anyerror!Names{
        lexerKeywords,
        reservedNames,
        builtins,
        methods,
        typeNames,
    };
    for (readers) |read| {
        var found = try read(repository);
        defer found.deinit();
        for (found.items.items) |name| try names.add(name);
    }
    return names;
}

test "the lexical keyword and reserved rosters exactly match the compiler" {
    const gpa = std.testing.allocator;
    const repository = try open(gpa, std.testing.io);
    defer gpa.free(repository.prefix);

    const lexical = try repository.read("www/luce/content/guide/reference/lexical.md");
    defer gpa.free(lexical);

    var documented_keywords: Names = .{ .gpa = gpa };
    defer documented_keywords.deinit();
    const keyword_block = between(lexical, "## Keywords\n\n```\n", "\n```") orelse
        return error.KeywordRosterNotFound;
    try plainWords(&documented_keywords, keyword_block);
    var compiler_keywords = try lexerKeywords(repository);
    defer compiler_keywords.deinit();
    try expectSameNames("guide/reference/lexical.md keywords", compiler_keywords, documented_keywords);

    var documented_reserved: Names = .{ .gpa = gpa };
    defer documented_reserved.deinit();
    const reserved_heading = std.mem.indexOf(u8, lexical, "## Reserved names\n") orelse
        return error.ReservedRosterNotFound;
    const reserved_section = lexical[reserved_heading + "## Reserved names\n".len ..];
    const fence = std.mem.indexOf(u8, reserved_section, "```\n") orelse
        return error.ReservedRosterNotFound;
    const after_fence = reserved_section[fence + 4 ..];
    const reserved_stop = std.mem.indexOf(u8, after_fence, "\n```") orelse
        return error.ReservedRosterNotFound;
    try plainWords(&documented_reserved, after_fence[0..reserved_stop]);
    var compiler_reserved = try reservedNames(repository);
    defer compiler_reserved.deinit();
    try expectSameNames("guide/reference/lexical.md reserved names", compiler_reserved, documented_reserved);
}

fn editorWordTable(gpa: Allocator, source: []const u8, declaration: []const u8) !Names {
    var names: Names = .{ .gpa = gpa };
    errdefer names.deinit();
    const opening = try std.fmt.allocPrint(gpa, "private const {s} = {{", .{declaration});
    defer gpa.free(opening);
    const table = between(source, opening, "\n}") orelse return error.EditorWordTableNotFound;
    try quotedWhere(&names, table, isPlainName);
    return names;
}

test "the example editor word maps exactly match the compiler" {
    // The editor is a Luce program and cannot import Zig compiler
    // tables.  Keep its runtime maps local, but derive the test's
    // expected sets from the compiler so additions and removals fail
    // the same build that changed the language.
    const gpa = std.testing.allocator;
    const repository = try open(gpa, std.testing.io);
    defer gpa.free(repository.prefix);

    // The highlighter's word tables moved out of `editor.luc` into
    // `highlight.luc` when the editor was split into modules; the tables
    // are what this test holds to the compiler, so it reads them where
    // they now live.
    const editor = try repository.read("examples/editor/highlight.luc");
    defer gpa.free(editor);

    var editor_keywords = try editorWordTable(gpa, editor, "keyword_words");
    defer editor_keywords.deinit();
    var compiler_keywords = try lexerKeywords(repository);
    defer compiler_keywords.deinit();
    try expectSameNames("examples/editor keyword_words", compiler_keywords, editor_keywords);

    var editor_types = try editorWordTable(gpa, editor, "type_words");
    defer editor_types.deinit();
    var compiler_types = try typeNames(repository);
    defer compiler_types.deinit();
    try expectSameNames("examples/editor type_words", compiler_types, editor_types);

    var editor_builtins = try editorWordTable(gpa, editor, "builtin_words");
    defer editor_builtins.deinit();
    var compiler_builtins = try builtins(repository);
    defer compiler_builtins.deinit();
    try compiler_builtins.add("range");
    try expectSameNames("examples/editor builtin_words", compiler_builtins, editor_builtins);
}

/// The five word tables `render` classifies against, in class order.
const highlight_tables = [_][]const []const u8{
    &highlight.keywords,
    &highlight.verbs,
    &highlight.type_names,
    &highlight.builtins,
    &highlight.methods,
};

test "the highlighter spells the language, and only the language" {
    // `highlight.zig` cannot import the compiler — it runs inside the
    // generator, which links no part of the tree it documents — so its
    // word tables are copies.  This is what keeps them honest, and it
    // reads the compiler's own sources rather than a snapshot of them.
    // The guard this replaces was a snapshot, and it passed while the
    // tables lost five type names and kept three deleted builtins.
    const gpa = std.testing.allocator;
    const repository = try open(gpa, std.testing.io);
    defer gpa.free(repository.prefix);

    var spelled = try vocabulary(repository);
    defer spelled.deinit();

    var wrong: usize = 0;

    // Forward: a name the language spells reads as the language.
    for (spelled.items.items) |name| {
        var classes: usize = 0;
        for (highlight_tables) |table| {
            if (highlight.inTable(table, name)) classes += 1;
        }
        // A capitalised name no table spells is still a type: that is
        // the rule `render` applies to any struct a sample declares,
        // and `None` reaches it that way.
        if (classes == 0 and std.ascii.isUpper(name[0])) continue;
        if (classes == 1) continue;
        std.debug.print("highlight.zig: '{s}' has {d} classes, want 1\n", .{ name, classes });
        wrong += 1;
    }

    // Backward: a name that reads as the language is one the language
    // has.  This is the half a snapshot cannot do — `str`, `arg` and
    // `arg_count` were coloured as builtins after they were deleted,
    // and a forward-only check never sees them.
    for (highlight_tables) |table| {
        for (table) |name| {
            if (spelled.has(name)) continue;
            std.debug.print("highlight.zig: '{s}' is not a name the language spells\n", .{name});
            wrong += 1;
        }
    }

    if (wrong != 0) return error.HighlighterDisagreesWithLanguage;
}

test "no word the highlighter spells is filed under two classes" {
    for (highlight_tables, 0..) |table, position| {
        for (table) |word| {
            for (highlight_tables[position + 1 ..]) |other| {
                if (!highlight.inTable(other, word)) continue;
                std.debug.print("highlight.zig: '{s}' is in two tables\n", .{word});
                return error.TestUnexpectedResult;
            }
        }
    }
}
