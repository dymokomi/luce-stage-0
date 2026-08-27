//! `luce test`: the runner, the per-test loop, and the report
//! (docs/TESTING.md D3, D4).
//!
//! **The CLI drives and the artifact answers one test per call.**  Each
//! file is compiled once, with a compiler-synthesized
//! `func main(args: list[str]) -> !` over the names discovery found
//! (`discover.zig`, `luce.types.Entry`); the artifact is opened once;
//! and then `luce_main` is called once *per test*, with that test's
//! name as the whole command line.  Every call is a fresh `Runtime`, so
//! per-test heap, scopes, depth budget, leak census and trap report all
//! fall out of machinery that already exists — and a test that traps
//! fails that call and nothing else, because the loop is out here.
//!
//! There is no result protocol between the artifact and this file, and
//! deliberately so.  A run ends in exactly one of five ways and the ABI
//! already says which (`abi.Status`), the host's `trap` and `raised`
//! channels already carry why, and `finished` already carries the leak
//! census.  Parsing the program's own stdout would be inventing a
//! second, worse channel beside four that are already true.
//!
//! **The whole report goes to standard output**, trap renderings and
//! compile diagnostics included, because it is one document a person
//! reads top to bottom and a test's failure is part of it rather than a
//! side channel.  A test's own `print` lands on the same stream, in
//! order, bracketed by the loop.  Its `print_error` is its own and
//! still goes to standard error.
//!
//! The host is the real one (`apps/host.zig`), wielded the way loom
//! wields it — including the screen-restore-before-report duty, so a
//! full-screen test that traps does not leave the terminal raw, and the
//! worker slots, so a test may itself `spawn`.

const std = @import("std");
const luce = @import("luce");
const native = @import("native");
const host_mod = @import("host");
const object = @import("object.zig");
const palette_mod = @import("palette");
const report = @import("report");

const discover = @import("discover.zig");
const front = @import("front.zig");

const Allocator = std.mem.Allocator;
const Palette = palette_mod.Palette;
const abi = luce.codegen.abi;

/// How far a failure's rendering sits under the test name it belongs
/// to.  One rendering, positioned by whoever is reporting.
const under_the_name = "        ";

/// What this run was given beyond its paths.
pub const Options = struct {
    /// `LUCE_LIB` — where `libluce_rt.a` is, and the package shelves
    /// the import loader probes.
    library_path: ?[]const u8 = null,
    /// `LUCE_CC` — another C driver for the link.
    driver: ?[]const u8 = null,
    palette: Palette = .{},
};

/// Run the tests `arguments` asks for and report on them.  Answers the
/// process's exit status: 0 when everything passed, 1 for anything else
/// — a failing test, a refusal, a compile failure — so a build script
/// needs no parsing.
pub fn run(
    gpa: Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    arguments: []const []const u8,
    options: Options,
) !u8 {
    const result = try discover.plan(gpa, io, arguments);
    var planned = switch (result) {
        .plan => |found| found,
        .nothing => |why| {
            switch (why) {
                .no_convention => try err.print(
                    "luce: no {s} directory here; name the files or directories to test\n",
                    .{discover.conventional_directory},
                ),
                .missing => |path| try err.print(
                    "luce: cannot read {s}: no such file or directory\n",
                    .{path},
                ),
            }
            return 1;
        },
    };
    defer planned.deinit();

    var tools = try native.discover(gpa, io, options.library_path, options.driver);
    defer tools.deinit(gpa);

    var tally: Tally = .{};
    for (planned.files) |found| {
        switch (found.what) {
            .helper => {},
            .refused => |sentences| {
                try out.print("{s}\n", .{found.path});
                for (sentences) |sentence| try out.print("  {s}\n", .{sentence});
                tally.unrun += 1;
            },
            // A file that did not parse is compiled with no tests at
            // all: the compile is what reports it, in the compiler's
            // own words, and there is nothing to run afterwards.
            .unparsed => {
                try out.print("{s}\n", .{found.path});
                switch (try compile(gpa, io, out, options.library_path, found.path, &.{})) {
                    .program => |compiled| {
                        var program = compiled;
                        program.deinit();
                    },
                    .refused => {},
                }
                tally.unrun += 1;
            },
            .tests => |names| try runFile(
                gpa,
                io,
                out,
                err,
                &tools,
                options.palette,
                options.library_path,
                found.path,
                names,
                &tally,
            ),
        }
    }

    try summarize(out, options.palette, &tally, planned.helpers());
    try out.flush();
    return if (tally.failed == 0 and tally.unrun == 0) 0 else 1;
}

// ---------------------------------------------------------------------------
// One file
// ---------------------------------------------------------------------------

/// Compile one test file, build its artifact, and call it once per
/// test.
///
/// The artifact is written beside the source under a name nothing else
/// can pick (`native.writerTag`), claimed before it is built
/// (`native.Scratch`) and removed when the file's tests are done — so
/// `luce test` leaves a directory exactly as it found it, can never
/// delete the `NAME.lc` a `luce build --emit=library` put there, and stops rather than
/// removing any other file that happens to wear the name.
fn runFile(
    gpa: Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    tools: *const native.Tools,
    palette: Palette,
    library_path: ?[]const u8,
    path: []const u8,
    names: []const []const u8,
    tally: *Tally,
) !void {
    try out.print("{s}\n", .{path});

    var program = switch (try compile(gpa, io, out, library_path, path, names)) {
        .program => |compiled| compiled,
        .refused => |why| {
            // An import that could not be reached from a rootless test
            // file is the one compile failure whose cause is *where the
            // file is*, and a `tests/` directory is exactly where that
            // surprises people (docs/TESTING.md D3).
            if (why.import_failed and try front.rootless(gpa, io, path)) {
                try out.print(
                    "  note: no luce.yaml governs {s}, so its imports resolve beside it\n",
                    .{path},
                );
            }
            tally.unrun += 1;
            return;
        },
    };
    defer program.deinit();

    const encoded = try luce.mir.module.encode(gpa, &program);
    defer gpa.free(encoded);
    const source_hash = luce.codegen.artifact.sourceHash(encoded);

    const artifact_path = try artifactFor(gpa, path);
    defer gpa.free(artifact_path);
    // Claimed before it is built, because this is a file the runner
    // *removes* when the file's tests are done, and nothing the tooling
    // removes may be a file a person owns (`native.Scratch`).  The link
    // renames its own result onto the claim.
    var scratch = switch (native.Scratch.claim(io, artifact_path)) {
        .made => |claimed| claimed,
        .taken => {
            try out.print(
                "  luce: {s} is already there, and a test run will not write over a file it did not make\n",
                .{artifact_path},
            );
            tally.unrun += 1;
            return;
        },
        .unwritable => {
            try out.print("  luce: cannot write {s}\n", .{artifact_path});
            tally.unrun += 1;
            return;
        },
    };
    defer scratch.release(io);

    switch (try object.build(gpa, io, tools, &program, .{
        .kind = .library,
        .output = artifact_path,
        .source_hash = source_hash,
    })) {
        .written => {},
        .unsupported => |what| {
            try out.print("  luce: damaged IR reached the backend ({s}); recompile from source and report this\n", .{what});
            tally.unrun += 1;
            return;
        },
        .failed => |why| {
            defer gpa.free(why);
            try out.print("  luce: {s}\n", .{why});
            tally.unrun += 1;
            return;
        },
    }

    var loaded = switch (native.open(io, artifact_path, source_hash)) {
        .loaded => |opened| opened,
        .unopenable => {
            try out.print("  luce: the artifact just built could not be loaded\n", .{});
            tally.unrun += 1;
            return;
        },
        .mismatch => |why| {
            var sentence: [native.explanation_bytes]u8 = undefined;
            try out.print("  luce: {s}\n", .{native.explain(why, &sentence)});
            tally.unrun += 1;
            return;
        },
    };
    defer loaded.close();

    tally.files += 1;
    for (names) |name| try runOne(gpa, io, out, err, palette, &loaded, name, tally);
}

/// Compile `path` as a test file, with the entry synthesized over
/// `names`.  Diagnostics go to the report, which is the one document a
/// person reads.
fn compile(
    gpa: Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    library_path: ?[]const u8,
    path: []const u8,
    names: []const []const u8,
) !front.Outcome {
    return front.compilePath(gpa, io, out, path, .{
        // The same `LUCE_LIB` a build reads, for the same reason: a
        // test file imports what its program imports, and a package
        // that resolves for `luce build` and not for `luce test` is a
        // suite that cannot be run (docs/PACKAGES.md D3).
        .library_path = library_path,
        // `luce test` takes no build options and always builds debug:
        // the report leans on trap origins, and `--release` strips
        // them (docs/TESTING.md D2).
        .entry = .{ .tests = names },
    });
}

/// Where a test file's artifact goes: beside the source, under a name
/// distinct per writer, so two `luce test` runs over one tree cannot
/// write each other's half-linked file.
fn artifactFor(gpa: Allocator, path: []const u8) ![:0]u8 {
    var tag_storage: [native.writer_tag_bytes]u8 = undefined;
    return std.fmt.allocPrintSentinel(
        gpa,
        "{s}.{s}.test.lc",
        .{ path, native.writerTag(&tag_storage) },
        0,
    );
}

// ---------------------------------------------------------------------------
// One test
// ---------------------------------------------------------------------------

/// What one call came to.
///
/// A run ends in exactly one of five ways and the ABI says which
/// (`abi.Status`); this is that answer read as a *verdict* about a
/// test, which is a shorter list — a test passes by returning, having
/// left nothing behind, and fails every other way there is.
///
/// It is a value rather than a branch inside the loop because three of
/// its arms cannot be reached from Luce source at all: scope ownership
/// frees everything (MEMORY.md), a host that ran out of memory
/// is not a program that went wrong, and an unknown status is an ABI
/// nobody speaks.  They are guards, and a guard nothing can test is a
/// guard nobody has read.
pub const Verdict = union(enum) {
    passed,
    /// A leaking test is a failing program even when its asserts held.
    leaked: i64,
    trapped,
    errored,
    exhausted,
    /// A test's job is to return.  An early `exit` is also the one way
    /// generated code could skip the census, so it is named rather
    /// than scored.
    exited: i64,
    unknown,
};

/// How a run's ending reads as a verdict.  `leaked` and `chosen` are
/// what the host recorded through `finished` and `exited`; a host that
/// was never told answers zero, which is the ordinary case for every
/// ending but the two that carry a number.
pub fn verdictOf(status: abi.Status, leaked: i64, chosen: i64) Verdict {
    return switch (status) {
        .ok => if (leaked == 0) .passed else .{ .leaked = leaked },
        .trapped => .trapped,
        .errored => .errored,
        .exhausted => .exhausted,
        .exited => .{ .exited = chosen },
        _ => .unknown,
    };
}

/// Call the artifact once, for one test, against a host of its own.
fn runOne(
    gpa: Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    palette: Palette,
    loaded: *native.Loaded,
    name: []const u8,
    tally: *Tally,
) !void {
    // Name the call before entering it, then force that progress out.
    // A slow or hung test must identify itself, and a redirected report
    // keeps the same two-line lifecycle as a terminal instead of relying
    // on cursor movement to rewrite one line in place.
    try announce(out, name);
    try out.flush();

    // The test's own two channels: `print` onto the report's stream,
    // in order, and `print_error` onto standard error, which is the
    // program's and not the report's.
    const selector = [_][]const u8{name};
    var services: host_mod.Host = undefined;
    services.setup(gpa, io, out, err, &selector);
    defer services.deinit();

    const table = services.table();
    const status = host_mod.enterProgram(loaded.entry, &table);

    // Land back on the ordinary screen before reporting anything: a
    // full-screen test that trapped must not leave the terminal raw.
    services.restoreScreen();

    const verdict = verdictOf(status, services.leaked orelse 0, services.exit_status orelse 0);
    if (verdict == .passed) {
        try pass(out, palette, name);
        tally.passed += 1;
        return;
    }

    try fail(out, palette, name);
    switch (verdict) {
        .passed => unreachable,
        // One rendering, the same words loom and a standalone binary
        // use — a census that is not zero is an engine bug, and asking
        // for it to be reported is more use than counting it again.
        .leaked => |count| report.printLeaks(out, under_the_name, "luce", count),
        .trapped => if (services.reportedTrap()) |trap| {
            report.printTrap(
                out,
                under_the_name,
                "luce",
                @tagName(trap.code),
                trap.message,
                trap.trace,
                trap.dropped,
            );
        } else {
            try out.print("{s}it trapped and said nothing\n", .{under_the_name});
        },
        .errored => if (services.reportedError()) |raised| {
            report.printError(
                out,
                under_the_name,
                "luce",
                @tagName(raised.code),
                raised.message,
                raised.origin,
            );
        } else {
            try out.print("{s}it failed and said nothing\n", .{under_the_name});
        },
        .exhausted => try out.print("{s}out of memory\n", .{under_the_name}),
        .exited => |chosen| try out.print(
            "{s}it called exit({d}); a test returns\n",
            .{ under_the_name, chosen },
        ),
        .unknown => try out.print("{s}it returned an unknown status\n", .{under_the_name}),
    }
    tally.failed += 1;
}

fn announce(out: *std.Io.Writer, name: []const u8) !void {
    try out.print("  test  {s}\n", .{name});
}

fn pass(out: *std.Io.Writer, palette: Palette, name: []const u8) !void {
    try out.print("  {s}ok{s}    {s}\n", .{
        palette.sgr(.pass),
        palette.sgr(.reset),
        name,
    });
}

fn fail(out: *std.Io.Writer, palette: Palette, name: []const u8) !void {
    try out.print("  {s}FAIL{s}  {s}\n", .{
        palette.sgr(.fail),
        palette.sgr(.reset),
        name,
    });
}

// ---------------------------------------------------------------------------
// The summary
// ---------------------------------------------------------------------------

/// What the run has come to so far.  `unrun` counts files, not tests:
/// a refusal and a compile failure are both "this file did not run",
/// and both make the run red.
pub const Tally = struct {
    passed: usize = 0,
    failed: usize = 0,
    files: usize = 0,
    unrun: usize = 0,
};

/// One line, whatever happened.  The counts a person actually reads
/// come first; the two that are only sometimes true follow, and are
/// left out when they are zero rather than written as "0 files".
pub fn summarize(
    out: *std.Io.Writer,
    palette: Palette,
    tally: *const Tally,
    helpers: usize,
) !void {
    const red = tally.failed != 0 or tally.unrun != 0;
    try out.print("\n{s}{d} passed, {d} failed, {d} test{s} in {d} file{s}", .{
        palette.sgr(if (red) .fail else .pass),
        tally.passed,
        tally.failed,
        tally.passed + tally.failed,
        if (tally.passed + tally.failed == 1) "" else "s",
        tally.files,
        if (tally.files == 1) "" else "s",
    });
    if (tally.unrun != 0) {
        try out.print(", {d} file{s} not run", .{ tally.unrun, if (tally.unrun == 1) "" else "s" });
    }
    if (helpers != 0) {
        try out.print(", {d} file{s} without tests", .{
            helpers,
            if (helpers == 1) "" else "s",
        });
    }
    try out.print("{s}\n", .{palette.sgr(.reset)});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the summary counts what happened, and says only what is true" {
    var written: std.Io.Writer.Allocating = .init(testing.allocator);
    defer written.deinit();
    const plain: Palette = .{};

    try summarize(&written.writer, plain, &.{ .passed = 7, .failed = 1, .files = 3 }, 0);
    try testing.expectEqualStrings("\n7 passed, 1 failed, 8 tests in 3 files\n", written.written());

    // The two occasional clauses appear only when they are not zero —
    // "0 files without tests" is a sentence nobody needs to read.
    written.clearRetainingCapacity();
    try summarize(&written.writer, plain, &.{ .passed = 4, .files = 2, .unrun = 1 }, 2);
    try testing.expectEqualStrings(
        "\n4 passed, 0 failed, 4 tests in 2 files, 1 file not run, 2 files without tests\n",
        written.written(),
    );

    // One of anything is singular, including the one test in one file.
    written.clearRetainingCapacity();
    try summarize(&written.writer, plain, &.{ .passed = 1, .files = 1 }, 1);
    try testing.expectEqualStrings(
        "\n1 passed, 0 failed, 1 test in 1 file, 1 file without tests\n",
        written.written(),
    );
}

test "the summary is green only when nothing went wrong" {
    var written: std.Io.Writer.Allocating = .init(testing.allocator);
    defer written.deinit();
    const colored: Palette = .{ .enabled = true };

    try summarize(&written.writer, colored, &.{ .passed = 2, .files = 1 }, 0);
    try testing.expect(std.mem.startsWith(u8, written.written(), "\n\x1b[32m"));

    // A failing test, and a file that never ran: two different ways to
    // be red, and both are red.
    for ([_]Tally{
        .{ .passed = 2, .failed = 1, .files = 1 },
        .{ .passed = 2, .files = 1, .unrun = 1 },
    }) |tally| {
        written.clearRetainingCapacity();
        try summarize(&written.writer, colored, &tally, 0);
        try testing.expect(std.mem.startsWith(u8, written.written(), "\n\x1b[31m"));
    }
}

test "a test has a progress line followed by its verdict" {
    var written: std.Io.Writer.Allocating = .init(testing.allocator);
    defer written.deinit();

    try announce(&written.writer, "test_area");
    try pass(&written.writer, .{}, "test_area");
    try fail(&written.writer, .{}, "test_bounds");
    // Progress is plain and both verdict columns are wide enough that
    // the names line up under each other.
    try testing.expectEqualStrings(
        "  test  test_area\n  ok    test_area\n  FAIL  test_bounds\n",
        written.written(),
    );

    written.clearRetainingCapacity();
    try announce(&written.writer, "test_area");
    try pass(&written.writer, .{ .enabled = true }, "test_area");
    try testing.expectEqualStrings(
        "  test  test_area\n  \x1b[32mok\x1b[0m    test_area\n",
        written.written(),
    );
}

test "a test passes by returning with nothing left behind, and fails every other way" {
    // Five ABI endings, six verdicts, and three of them are arms no
    // Luce source can reach — a run that leaked (S33 frees
    // everything), a host that ran out of memory, and a status nobody
    // speaks.  They are guards, and this is where they are read.
    try testing.expectEqual(Verdict.passed, verdictOf(.ok, 0, 0));
    try testing.expectEqual(Verdict{ .leaked = 3 }, verdictOf(.ok, 3, 0));
    try testing.expectEqual(Verdict.trapped, verdictOf(.trapped, 0, 0));
    try testing.expectEqual(Verdict.errored, verdictOf(.errored, 0, 0));
    try testing.expectEqual(Verdict.exhausted, verdictOf(.exhausted, 0, 0));
    // An exit is a failure whatever status it chose, zero included:
    // what is wrong is that the test did not return.
    try testing.expectEqual(Verdict{ .exited = 0 }, verdictOf(.exited, 0, 0));
    try testing.expectEqual(Verdict{ .exited = 3 }, verdictOf(.exited, 0, 3));
    try testing.expectEqual(Verdict.unknown, verdictOf(@enumFromInt(99), 0, 0));
}

test "an artifact is named beside its source, distinctly per writer" {
    // Two `luce test` runs over one tree must not write each other's
    // half-linked file, and neither may ever land on the `NAME.lc` a
    // `luce build --emit=library` put there — which is why it is not that name.
    const gpa = testing.allocator;
    const path = try artifactFor(gpa, "tests/geo_test.luc");
    defer gpa.free(path);
    try testing.expect(std.mem.startsWith(u8, path, "tests/geo_test.luc."));
    try testing.expect(std.mem.endsWith(u8, path, ".test.lc"));
    try testing.expect(!std.mem.eql(u8, path, "tests/geo_test.lc"));
}
