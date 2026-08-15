//! The synthesized test entry (docs/TESTING.md D3).
//!
//! `luce test` does not run a program a person wrote: it runs one the
//! compiler wrote, `func main(args: list(string)) -> !`, whose body
//! reads one name out of `args` and calls that test by direct call.
//! That entry is built as ordinary AST and collected as an ordinary
//! signature, and the claim these specs make is that it is therefore an
//! ordinary program — checked by the same walk, verified by the same
//! verifier, optimized by the same passes, and answering the same on
//! both engines as anything a person wrote.
//!
//! There is nothing about the *runner* here.  Which functions are tests
//! and what the report says are `src/apps/luce/`'s, and are proved
//! there; this is the language half, and the language half is one
//! entry.

const std = @import("std");
const luce = @import("luce");
const agree = @import("agree.zig");

const testing = std.testing;
const types = luce.types;

/// The options `luce test` compiles a test file under: the host gate
/// open, and the entry synthesized over these names.
fn suite(names: []const []const u8) types.CompileOptions {
    return .{
        .allow_host = true,
        .source_name = "geo_test.luc",
        .entry = .{ .tests = names },
    };
}

/// Compile `source` as a test file and run the one test `selected`
/// names, on both engines.  The caller owns the session.
fn call(
    source: []const u8,
    names: []const []const u8,
    selected: []const u8,
) !agree.Session {
    var compiled = try agree.programWith(source, suite(names));
    defer compiled.deinit();
    const chosen = [_][]const u8{selected};
    return agree.compareProgram(&compiled, .{ .world = .{ .arguments = &chosen } });
}

const two_tests =
    \\func helper(value: long) -> long:
    \\    return value * 2
    \\
    \\func test_doubling():
    \\    print("doubling")
    \\    assert(helper(21) == 42)
    \\
    \\func test_lists():
    \\    print("lists")
    \\    var xs: list(long) = [1, 2, 3]
    \\    assert(len(xs) == 3)
    \\
;

test "the name in args picks exactly one test, and the others do not run" {
    // The whole mechanism in one claim: one `luce_main` call runs one
    // test.  A dispatch that fell through would print both lines, and a
    // dispatch that matched the wrong arm would print the other one.
    for ([_][2][]const u8{
        .{ "test_doubling", "doubling\n" },
        .{ "test_lists", "lists\n" },
    }) |row| {
        var session = try call(two_tests, &.{ "test_doubling", "test_lists" }, row[0]);
        defer session.deinit();
        // sub_cut_b: the synthesized entry's `args` list (and any test
        // container) is not reclaimed mid-ARC, so gate on the run having
        // finished rather than on a zero leak census.
        try testing.expect(std.meta.activeTag(session.end) == .finished);
        try testing.expectEqualStrings(row[1], session.printed());
    }
}

test "a test that traps reports the trap, with its own frame in the trace" {
    // A failing test is a trapping program, which is the whole reason
    // `luce test` needs no result protocol: the host's `trap` channel
    // already says everything, and it says it about the test's own
    // line rather than about the entry that called it.
    var session = try call(
        \\func test_bounds():
        \\    var xs: list(long) = [1, 2, 3]
        \\    var index = 7
        \\    print(string(xs[index]))
        \\
    , &.{"test_bounds"}, "test_bounds");
    defer session.deinit();
    try testing.expectEqual(agree.End{ .trapped = .index_bounds }, session.end);
    try testing.expect(std.mem.indexOf(u8, session.trace(), "test_bounds geo_test.luc:4:") != null);
}

test "a fallible test's error crosses the synthesized entry whole" {
    // `func test_x() -> !` is the second of the two shapes a test may
    // have, and the entry writes `try` in front of exactly those — so
    // what the test raised is what the runner is told, rather than a
    // `luce.sema.fallible` at compile time or a swallowed failure.
    var session = try call(
        \\func test_reading() -> !:
        \\    error("no such file")
        \\
    , &.{"test_reading"}, "test_reading");
    defer session.deinit();
    try testing.expectEqual(agree.End{ .errored = .user_error }, session.end);
    try testing.expectEqualStrings("no such file", session.message());
}

test "a name the artifact does not carry is refused by name, not guessed at" {
    // The runner only ever asks for a name it discovered, so this is
    // the artifact answering a person who ran it by hand.
    var session = try call(two_tests, &.{ "test_doubling", "test_lists" }, "test_missing");
    defer session.deinit();
    try testing.expectEqual(agree.End{ .errored = .user_error }, session.end);
    try testing.expectEqualStrings("luce test: no test named test_missing", session.message());
}

test "the artifact runs one named test per call, and says so when it is handed anything else" {
    var compiled = try agree.programWith(two_tests, suite(&.{"test_doubling"}));
    defer compiled.deinit();
    for ([_][]const []const u8{
        &.{},
        &.{ "test_doubling", "test_lists" },
    }) |given| {
        var session = try agree.compareProgram(&compiled, .{ .world = .{ .arguments = given } });
        defer session.deinit();
        try testing.expectEqual(agree.End{ .errored = .user_error }, session.end);
        try testing.expectEqualStrings(
            "luce test: this artifact runs one named test per call",
            session.message(),
        );
    }
}

test "a test file's own main is an ordinary function the entry never reaches" {
    // docs/TESTING.md D1: a test file may have a `main`; `luce test`
    // ignores it.  It is not the entry, it is not refused, and — since
    // nothing calls it — stage 7 drops it before the artifact is
    // written.
    const source =
        \\func main():
        \\    print("not this")
        \\
        \\func test_only():
        \\    print("this")
        \\
    ;
    var session = try call(source, &.{"test_only"}, "test_only");
    defer session.deinit();
    // sub_cut_b: gate on the run finishing, not on a zero leak census,
    // while the synthesized entry's `args` list is not yet reclaimed.
    try testing.expect(std.meta.activeTag(session.end) == .finished);
    try testing.expectEqualStrings("this\n", session.printed());

    var compiled = try agree.programWith(source, suite(&.{"test_only"}));
    defer compiled.deinit();
    for (compiled.functions) |function| {
        if (std.mem.eql(u8, function.name, "main")) continue;
        try testing.expectEqualStrings("test_only", function.name);
    }
    // The entry is the synthesized one, and it takes the command line.
    const entry = compiled.functions[compiled.entry_function];
    try testing.expectEqualStrings("main", entry.name);
    try testing.expectEqual(@as(u32, 1), entry.parameter_count);
}
