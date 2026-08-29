//! What `luce test` will run: which files, and which functions in them
//! (docs/TESTING.md D1, D2).
//!
//! A test is a top-level, public, zero-parameter `func test_*()` whose
//! return shape is nothing or `!`.  Everything else named `test_*` is
//! **refused by name, never skipped** — a parameterized one, one inside
//! a struct or an enum, one that answers a value, and above all a
//! `private` one, which would otherwise be a test that silently never
//! ran.  A function not named `test_*` is a helper and is nobody's
//! business here.
//!
//! Discovery reads the AST and stops.  It compiles nothing, resolves no
//! import and runs no semantic check, because what it decides is a
//! *runner* policy — which functions this tool will call — and the
//! compiler is told the answer rather than asked for it
//! (`luce.types.Entry`).  So "what is a test" is written down once, in
//! `collect` below, and the compiler re-derives none of it: a name that
//! turns out not to exist refuses itself as an ordinary unresolved
//! call.
//!
//! A file that did not parse is `unparsed` rather than described here:
//! discovery paraphrasing a syntax error would be a second, worse
//! diagnostic for something the compiler is about to say properly.

const std = @import("std");
const luce = @import("luce");
const files = @import("files");

const Allocator = std.mem.Allocator;
const ast = luce.parse.ast;

/// The conventional directory a bare `luce test` means, under the
/// current directory — the cwd being wherever the command was typed.
pub const conventional_directory = "tests";

/// The suffix that makes a swept file *claim* to hold tests.  One that
/// claims it and holds none is a mistake; any other swept file that
/// holds none is a helper module (D2).
pub const claiming_suffix = "_test.luc";

const source_suffix = ".luc";

// ---------------------------------------------------------------------------
// What discovery answers
// ---------------------------------------------------------------------------

/// One file, and what discovery made of it.
pub const Found = struct {
    /// The path as it will be reported and compiled — relative to the
    /// current directory when that is how it was reached, because that
    /// is what an editor can jump to.
    path: []const u8,
    what: What,
};

pub const What = union(enum) {
    /// The tests, in declaration order.  Never empty.
    tests: []const []const u8,
    /// D1 or D2 refused this file; one sentence per reason, each
    /// already carrying its own `path:line:column`.  The file is not
    /// run, and the run is red.
    refused: []const []const u8,
    /// A swept file that declares no test and never claimed to: a
    /// helper module.  Skipped, and counted in the summary, so a
    /// wrongly-silent file is one glance away.
    helper,
    /// It did not parse.  Compiled anyway, so the compiler reports the
    /// diagnostics rather than discovery paraphrasing them.
    unparsed,
};

/// Everything one `luce test` invocation will do, in report order.
pub const Plan = struct {
    files: []const Found,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Plan) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// How many swept files held no tests (D2's "2 files without
    /// tests").
    pub fn helpers(self: *const Plan) usize {
        var count: usize = 0;
        for (self.files) |found| {
            if (found.what == .helper) count += 1;
        }
        return count;
    }
};

/// Why there is nothing to plan at all — a whole-command failure, not a
/// per-file one.  The sentence is static; the path belongs to the
/// caller's arguments.
pub const Nothing = union(enum) {
    /// Bare `luce test` with no `tests/` under the current directory.
    /// A plain failure naming what it looked for, never a green run of
    /// no tests.
    no_convention,
    /// A path the caller named that is neither a file nor a directory.
    missing: []const u8,
};

pub const Result = union(enum) {
    plan: Plan,
    nothing: Nothing,
};

pub const Error = error{OutOfMemory};

// ---------------------------------------------------------------------------
// The walk
// ---------------------------------------------------------------------------

/// Plan the run `arguments` asks for.  No arguments means `./tests`.
///
/// Named files are taken as written; directories are walked
/// recursively for `*.luc`, **sorted bytewise at every level**, so the
/// report's order is a property of the tree rather than of the
/// filesystem's iteration order.
pub fn plan(gpa: Allocator, io: std.Io, arguments: []const []const u8) Error!Result {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const kept = arena.allocator();

    var found: std.ArrayList(Found) = .empty;

    if (arguments.len == 0) {
        if (!isDirectory(io, conventional_directory)) {
            arena.deinit();
            return .{ .nothing = .no_convention };
        }
        try sweep(gpa, kept, io, conventional_directory, &found);
    } else for (arguments) |argument| {
        if (isDirectory(io, argument)) {
            try sweep(gpa, kept, io, argument, &found);
            continue;
        }
        if (!isFile(io, argument)) {
            arena.deinit();
            return .{ .nothing = .{ .missing = argument } };
        }
        // A file the caller *named* has to hold tests: they said so by
        // naming it.  Only a swept file gets to be a helper module.
        try found.append(kept, .{
            .path = try kept.dupe(u8, argument),
            .what = try read(gpa, kept, io, argument, .named),
        });
    }

    return .{ .plan = .{ .files = try found.toOwnedSlice(kept), .arena = arena } };
}

/// Read one file and decide what it holds, keeping only the answer.
///
/// The bytes, the tree and the diagnostics a parse needs are a whole
/// file's worth of memory and are wanted for the length of one call, so
/// they live in an arena of their own that goes back here.  What
/// survives is a handful of names, copied into the plan's.
fn read(
    gpa: Allocator,
    kept: Allocator,
    io: std.Io,
    path: []const u8,
    reached: Reached,
) Error!What {
    var reading = std.heap.ArenaAllocator.init(gpa);
    defer reading.deinit();
    const scratch = reading.allocator();
    const source = readWhole(scratch, io, path) orelse return .unparsed;
    return adopt(kept, try collect(scratch, path, source, reached));
}

/// Copy a decision out of the reading arena and into the plan's.
fn adopt(kept: Allocator, what: What) Error!What {
    return switch (what) {
        .tests => |names| .{ .tests = try copyAll(kept, names) },
        .refused => |sentences| .{ .refused = try copyAll(kept, sentences) },
        .helper, .unparsed => what,
    };
}

fn copyAll(kept: Allocator, texts: []const []const u8) Error![]const []const u8 {
    const made = try kept.alloc([]const u8, texts.len);
    for (texts, made) |text, *slot| slot.* = try kept.dupe(u8, text);
    return made;
}

/// Whether a swept file's silence is allowed.  A named file's is not;
/// nor is a `*_test.luc`'s, which claimed the name and delivered
/// nothing.
const Reached = enum { named, swept };

/// Walk `directory` for `*.luc`, bytewise sorted, recursing into
/// subdirectories in the same order.  Entries beginning with a dot are
/// left alone: `.luce/cache` holds artifacts, not tests.
fn sweep(
    gpa: Allocator,
    kept: Allocator,
    io: std.Io,
    directory: []const u8,
    into: *std.ArrayList(Found),
) Error!void {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    defer for (names.items) |name| gpa.free(name);

    var opened = std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch return;
    defer opened.close(io);
    var walk = opened.iterate();
    while (walk.next(io) catch null) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (entry.kind != .directory and !std.mem.endsWith(u8, entry.name, source_suffix)) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);

    for (names.items) |name| {
        const path = try std.fs.path.join(kept, &.{ directory, name });
        if (isDirectory(io, path)) {
            try sweep(gpa, kept, io, path, into);
            continue;
        }
        try into.append(kept, .{ .path = path, .what = try read(gpa, kept, io, path, .swept) });
    }
}

fn lessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn isDirectory(io: std.Io, path: []const u8) bool {
    const found = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return found.kind == .directory;
}

fn isFile(io: std.Io, path: []const u8) bool {
    const opened = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    opened.close(io);
    return true;
}

/// The file's bytes, or null when it cannot be read at all.
fn readWhole(scratch: Allocator, io: std.Io, path: []const u8) ?[]const u8 {
    const found = files.readSource(scratch, io, path) catch return null;
    return switch (found) {
        .text => |text| text.bytes,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// What a test is
// ---------------------------------------------------------------------------

/// The prefix that makes a function a test.
pub const prefix = "test_";

/// Read one file's declarations and decide what it holds.
///
/// The only place in this tree that says what a test is.  It parses and
/// nothing more: a diagnostic from stage 2 or 3 makes the file
/// `unparsed`, and the compiler says what is wrong with it.
fn collect(
    scratch: Allocator,
    path: []const u8,
    source: []const u8,
    reached: Reached,
) Error!What {
    var diagnostics = luce.diagnostics.Diagnostics.init(scratch);
    defer diagnostics.deinit();
    if ((try luce.source.openRoot(&diagnostics, path, "", source)) == null) return .unparsed;
    const tree = try luce.parse.parse(scratch, scratch, source, &diagnostics);
    if (diagnostics.hasErrors()) return .unparsed;

    var names: std.ArrayList([]const u8) = .empty;
    var refusals: std.ArrayList([]const u8) = .empty;

    for (tree.functions) |declaration| {
        if (!std.mem.startsWith(u8, declaration.name, prefix)) continue;
        if (try refusalFor(scratch, &diagnostics, path, declaration)) |sentence| {
            try refusals.append(scratch, sentence);
            continue;
        }
        try names.append(scratch, declaration.name);
    }

    // A test inside a struct or an enum can never be reached by name
    // from the entry, and is the one refusal whose *place* is the
    // mistake rather than its shape.
    for (tree.structs) |declaration| {
        try refuseMembers(scratch, &diagnostics, path, "a struct", declaration.name, declaration.functions, &refusals);
    }
    for (tree.enums) |declaration| {
        try refuseMembers(scratch, &diagnostics, path, "an enum", declaration.name, declaration.functions, &refusals);
    }
    for (tree.unions) |declaration| {
        try refuseMembers(scratch, &diagnostics, path, "a union", declaration.name, declaration.functions, &refusals);
    }

    if (refusals.items.len != 0) return .{ .refused = try refusals.toOwnedSlice(scratch) };
    if (names.items.len != 0) return .{ .tests = try names.toOwnedSlice(scratch) };
    if (reached == .swept and !std.mem.endsWith(u8, path, claiming_suffix)) return .helper;
    return .{ .refused = try one(scratch, try std.fmt.allocPrint(
        scratch,
        "{s}: no tests here; a test is a pub func test_*() taking nothing",
        .{path},
    )) };
}

/// Why this `test_*` cannot be run, or null when it can.
fn refusalFor(
    scratch: Allocator,
    diagnostics: *const luce.diagnostics.Diagnostics,
    path: []const u8,
    declaration: ast.FuncDecl,
) Error!?[]const u8 {
    const at = try position(scratch, diagnostics, path, declaration.name_span);
    if (declaration.visibility != .public) {
        return try std.fmt.allocPrint(
            scratch,
            "{s}: {s} is not public and would never run; mark it pub, or rename it if it is a helper",
            .{ at, declaration.name },
        );
    }
    if (declaration.parameters.len != 0) {
        return try std.fmt.allocPrint(
            scratch,
            "{s}: {s} takes {d} parameter{s}; a test takes none — pass what it needs from inside it",
            .{
                at,
                declaration.name,
                declaration.parameters.len,
                if (declaration.parameters.len == 1) "" else "s",
            },
        );
    }
    if (declaration.returns.len != 0) {
        return try std.fmt.allocPrint(
            scratch,
            "{s}: {s} answers a value; a test answers nothing, or -> ! when the world can stop it",
            .{ at, declaration.name },
        );
    }
    return null;
}

fn refuseMembers(
    scratch: Allocator,
    diagnostics: *const luce.diagnostics.Diagnostics,
    path: []const u8,
    /// The kind with its article — "a struct", "an enum", "a union" —
    /// because the sentence reads it and English does not take one
    /// article for all three.
    keyword: []const u8,
    owner: []const u8,
    members: []const ast.FuncDecl,
    into: *std.ArrayList([]const u8),
) Error!void {
    for (members) |member| {
        if (!std.mem.startsWith(u8, member.name, prefix)) continue;
        const at = try position(scratch, diagnostics, path, member.name_span);
        try into.append(scratch, try std.fmt.allocPrint(
            scratch,
            "{s}: {s}.{s} is inside {s}; a test is a top-level function — move it out",
            .{ at, owner, member.name, keyword },
        ));
    }
}

/// `path:line:column` for a span — the three things an editor and a
/// person both need, taken from the same line index a diagnostic uses.
fn position(
    scratch: Allocator,
    diagnostics: *const luce.diagnostics.Diagnostics,
    path: []const u8,
    span: luce.source.Span,
) Error![]const u8 {
    const at = diagnostics.sources.place(luce.source.root_file, span.start);
    return std.fmt.allocPrint(scratch, "{s}:{d}:{d}", .{ path, at.line, at.column });
}

fn one(scratch: Allocator, value: []const u8) Error![]const []const u8 {
    const made = try scratch.alloc([]const u8, 1);
    made[0] = value;
    return made;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Discovery over one file's bytes, without a filesystem — what
/// `collect` decides is the whole of D1, and it decides it from the
/// text.
fn decide(scratch: Allocator, path: []const u8, source: []const u8, reached: Reached) !What {
    return collect(scratch, path, source, reached);
}

test "a test is a top-level public zero-parameter test_* answering nothing or !" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const decided = try decide(scratch, "tests/geo_test.luc",
        \\pub func helper(value: i64) -> i64:
        \\    return value
        \\
        \\pub func test_plain():
        \\    assert(helper(1) == 1)
        \\
        \\pub func test_fallible() -> !:
        \\    assert(true)
        \\
        \\pub func test_said_so():
        \\    assert(true)
        \\
        \\func main():
        \\    print("ignored")
        \\
    , .swept);
    // Declaration order, and a `pub func` that is not a test (`helper`)
    // and `main` are both left alone: only the `test_*` names run.
    try testing.expectEqual(@as(usize, 3), decided.tests.len);
    try testing.expectEqualStrings("test_plain", decided.tests[0]);
    try testing.expectEqualStrings("test_fallible", decided.tests[1]);
    try testing.expectEqualStrings("test_said_so", decided.tests[2]);
}

test "a test that cannot run is refused by name, and the sentence names the fix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const refusals = [_]struct { source: []const u8, says: []const u8 }{
        .{
            // The one that matters most: it would otherwise be a test
            // that silently never ran.
            .source = "func test_hidden():\n    assert(true)\n",
            .says = "test_hidden is not public and would never run",
        },
        .{
            .source = "pub func test_parameterized(value: i64):\n    assert(value == 1)\n",
            .says = "test_parameterized takes 1 parameter; a test takes none",
        },
        .{
            .source = "pub func test_answers() -> i64:\n    return 1\n",
            .says = "test_answers answers a value",
        },
        .{
            .source = "struct Box:\n    let value: i64\n\n    func test_inside():\n        assert(true)\n",
            .says = "Box.test_inside is inside a struct",
        },
        .{
            .source = "enum Method:\n    stored\n\n    static func test_inside():\n        assert(true)\n",
            .says = "Method.test_inside is inside an enum",
        },
    };
    for (refusals) |refusal| {
        const decided = try decide(scratch, "tests/bad_test.luc", refusal.source, .swept);
        try testing.expectEqual(@as(usize, 1), decided.refused.len);
        try testing.expect(std.mem.indexOf(u8, decided.refused[0], refusal.says) != null);
        // Every refusal is positioned, so an editor can jump to it.
        try testing.expect(std.mem.startsWith(u8, decided.refused[0], "tests/bad_test.luc:"));
    }
}

test "silence is a helper module once, and a mistake twice" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const quiet = "func area(side: i64) -> i64:\n    return side * side\n";
    // Swept, unclaimed: a helper module, skipped and counted.
    try testing.expectEqual(What.helper, try decide(scratch, "tests/geo.luc", quiet, .swept));
    // Swept and claiming the name: a file that promised tests.
    const claimed = try decide(scratch, "tests/geo_test.luc", quiet, .swept);
    try testing.expect(std.mem.indexOf(u8, claimed.refused[0], "no tests here") != null);
    // Named by the caller: they said so by naming it.
    const named = try decide(scratch, "tests/geo.luc", quiet, .named);
    try testing.expect(std.mem.indexOf(u8, named.refused[0], "no tests here") != null);
}

test "a file that does not parse is left for the compiler to describe" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    // Discovery paraphrasing a syntax error would be a second, worse
    // diagnostic for something the compiler is about to say properly.
    try testing.expectEqual(
        What.unparsed,
        try decide(scratch, "tests/broken_test.luc", "func test_x(:\n", .swept),
    );
}

test "a directory is walked bytewise, into its subdirectories, and dot entries are left alone" {
    // The report's order has to be a property of the tree: two runs on
    // two machines must list the same files in the same order, and a
    // `.luce/cache` full of artifacts is not a test suite.
    const gpa = testing.allocator;
    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_storage[0..try scratch.dir.realPath(testing.io, &path_storage)];

    const body = "pub func test_one():\n    assert(true)\n";
    for ([_][]const u8{ "zeta_test.luc", "alpha_test.luc", "middle_test.luc" }) |name| {
        try scratch.dir.writeFile(testing.io, .{ .sub_path = name, .data = body });
    }
    try scratch.dir.createDirPath(testing.io, "nested");
    try scratch.dir.writeFile(testing.io, .{ .sub_path = "nested/inner_test.luc", .data = body });
    try scratch.dir.createDirPath(testing.io, ".luce/cache");
    try scratch.dir.writeFile(testing.io, .{ .sub_path = ".luce/cache/hidden_test.luc", .data = body });
    try scratch.dir.writeFile(testing.io, .{ .sub_path = "notes.txt", .data = "not a program" });

    const result = try plan(gpa, testing.io, &.{root});
    var planned = result.plan;
    defer planned.deinit();

    try testing.expectEqual(@as(usize, 4), planned.files.len);
    const expected = [_][]const u8{
        "alpha_test.luc",
        "middle_test.luc",
        // A directory sorts among the files by name, and its contents
        // follow immediately — one order, one walk.
        "nested/inner_test.luc",
        "zeta_test.luc",
    };
    for (planned.files, expected) |file, tail| {
        try testing.expect(std.mem.endsWith(u8, file.path, tail));
        try testing.expectEqual(@as(usize, 1), file.what.tests.len);
    }
}

test "a named path that is neither file nor directory stops the whole command" {
    const gpa = testing.allocator;
    const result = try plan(gpa, testing.io, &.{"no/such/place_test.luc"});
    try testing.expectEqualStrings("no/such/place_test.luc", result.nothing.missing);
}
