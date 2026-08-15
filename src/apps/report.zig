//! How a Luce run ended, said and scored.
//!
//! A compiled artifact under loom and a standalone compiled binary have
//! to report the same failure the same way and exit with the same
//! number: a program's behaviour must not depend on who started it, and
//! that includes how it says it failed and what a shell reads
//! afterwards.  So there is one rendering and one exit table, here,
//! and `loom/runner.zig` and `start.zig` both answer from them.
//!
//! Nothing here is a host.  It writes to a `std.Io.Writer` the caller
//! hands over, takes no allocator, and touches no terminal — a trap
//! report has nothing left to allocate from and no message it is
//! allowed to refuse.  Program text still reaches a screen this way, so
//! every word of it goes through `sanitize` first.

const std = @import("std");
const luce = @import("luce");
const sanitize = @import("sanitize");

const abi = luce.llvm.abi;

/// One call in a report: a function, and where in the source it was.
///
/// The four facts an artifact's trace frame and its error origin both
/// carry, in the one shape this file renders.  A `--release` artifact
/// reports line and column zero and still names the function, and a
/// frame with no source reports no position at all.  The names are
/// borrowed for the length of the call.
pub const Frame = struct {
    function: []const u8,
    source: []const u8,
    line: u32,
    column: u32,
};

/// A reported trace prints at most this many frames; a runaway
/// recursion shows its innermost calls and a count of the rest.
pub const max_printed_frames = 12;

// ---------------------------------------------------------------------------
// Exit codes
// ---------------------------------------------------------------------------

/// What a runner exits with, for each way a run can end — one table,
/// because a program's behaviour must not depend on who started it,
/// and that includes the number a shell reads afterwards.  `loom run
/// PROGRAM.lc` and the standalone binary `luce build --emit=exe`
/// writes both answer from here.
///
/// **A trap and an uncaught error get different numbers**, because
/// they are different sentences about the program (docs/FAILURE.md): a
/// trap is a bug, an error is news the program chose not to handle.
/// A script that has to tell them apart should read `$?`, not parse
/// stderr.  Their numbers are the ABI's own (`abi.Status`).
///
/// The other two are not about the program at all, so they take
/// sysexits numbers well clear of anything a program means.
pub const exit_ok: u8 = 0;
pub const exit_trapped: u8 = 1;
pub const exit_errored: u8 = 3;
/// Out of memory: the machine ran out, not the program (EX_SOFTWARE).
pub const exit_exhausted: u8 = 70;
/// The run could not be carried out, or its output could not be
/// delivered — the artifact, the runner, or the pipe (EX_OSERR).
pub const exit_broken: u8 = 71;

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

/// Render a trap — one rendering, for every way a Luce program can be
/// run.
///
/// `reporter` is the binary's own name, `code` the trap's stable code,
/// `message` what the program said, `trace` its calls innermost first,
/// and `dropped` how many frames the runtime's own cap already cut.
///
/// `indent` opens every line, and is `""` for a runner whose whole
/// output is this report.  `luce test` passes spaces, because there a
/// trap belongs *under* the name of the test that took it — one
/// rendering, positioned by whoever is reporting (docs/TESTING.md D4).
///
/// **The program's words are sanitized, like every other host channel
/// that reaches a terminal.**  A trap message carries program text —
/// `trap(f"...")` says whatever the program says — and a source path
/// carries whatever the filesystem allows; stderr is shared with the
/// runner, so raw control bytes there could clear the screen or forge
/// the terminal's state on the way out of a failing program.  Nothing
/// here allocates: the rewriting streams straight onto the writer,
/// because the failure path has no allocator left to fail on.
///
/// Writes are best-effort — a trap report must not fail to be a trap
/// because the pipe closed.
pub fn printTrap(
    err: *std.Io.Writer,
    indent: []const u8,
    reporter: []const u8,
    code: []const u8,
    message: []const u8,
    trace: []const Frame,
    dropped: u32,
) void {
    err.print("{s}{s}: trap: ", .{ indent, reporter }) catch {};
    sanitize.write(err, message);
    err.print(" [{s}]\n", .{code}) catch {};
    // Innermost first, like Zig's own traces.  A --release artifact
    // has no lines; the function names still print.
    for (trace, 0..) |frame, index| {
        if (index == max_printed_frames) break;
        err.print("{s}    at ", .{indent}) catch {};
        sanitize.write(err, frame.function);
        if (frame.line != 0) {
            err.writeAll(" (") catch {};
            sanitize.write(err, frame.source);
            err.print(":{d}:{d})", .{ frame.line, frame.column }) catch {};
        }
        err.writeAll("\n") catch {};
    }
    const hidden = dropped + @as(u32, @intCast(trace.len -| max_printed_frames));
    if (hidden != 0) err.print("{s}    ... {d} more frames\n", .{ indent, hidden }) catch {};
}

/// Report an uncaught error, in one shape for every runner.
///
/// **Not "trap", and it does not print a stack.**  A trap is a bug and
/// the stack is its diagnosis; an error is news, and the news is what
/// the world said and where the program asked it (docs/FAILURE.md).
/// `origin` is that one place; a frame with no function name prints
/// nothing after the message.  `indent` opens every line, as in
/// `printTrap`.
///
/// The words and the names are sanitized for the same reason
/// `printTrap`'s are, and by the same rule.
pub fn printError(
    err: *std.Io.Writer,
    indent: []const u8,
    reporter: []const u8,
    code: []const u8,
    message: []const u8,
    origin: Frame,
) void {
    err.print("{s}{s}: error: ", .{ indent, reporter }) catch {};
    sanitize.write(err, message);
    err.print(" [{s}]\n", .{code}) catch {};
    if (origin.function.len == 0) return;
    err.print("{s}    raised in ", .{indent}) catch {};
    sanitize.write(err, origin.function);
    if (origin.line != 0) {
        err.writeAll(" (") catch {};
        sanitize.write(err, origin.source);
        err.print(":{d}:{d})", .{ origin.line, origin.column }) catch {};
    }
    err.writeAll("\n") catch {};
}

/// The one thing to say about a run that ended without trapping: whether
/// any reference object outlived it.  ARC frees every reference the moment
/// its last name goes, so a nonzero count is a real leak — a reference the
/// run never released (an emission gap, or a strong cycle a future `weak`
/// would break) — and is reported as one.  It takes the `i64` the ABI
/// hands over rather than a narrowed copy, so no caller has to decide what
/// a negative count means: a number that is not zero is the leak.
pub fn printLeaks(err: *std.Io.Writer, indent: []const u8, reporter: []const u8, leaked: i64) void {
    if (leaked == 0) return;
    err.print(
        "{s}{s}: {d} object{s} leaked — a reference the run never released\n",
        .{ indent, reporter, leaked, if (leaked == 1) "" else "s" },
    ) catch {};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "how a run ended is one table, and every ending has its own number" {
    // A program's behaviour must not depend on who started it, and
    // that includes the number a shell reads afterwards: `loom run`
    // and the standalone binary both answer from here.  A trap and an
    // uncaught error are different sentences about a program, so
    // collapsing their two numbers into one would leave a script
    // parsing stderr to tell them apart.
    const table = [_]u8{ exit_ok, exit_trapped, exit_errored, exit_exhausted, exit_broken };
    try testing.expectEqualSlices(u8, &.{ 0, 1, 3, 70, 71 }, &table);
    for (table, 0..) |code, index| {
        for (table[index + 1 ..]) |other| try testing.expect(code != other);
    }

    // The two the ABI hands over are the ABI's own numbers.
    try testing.expectEqual(@as(i32, exit_ok), @intFromEnum(abi.Status.ok));
    try testing.expectEqual(@as(i32, exit_trapped), @intFromEnum(abi.Status.trapped));
    try testing.expectEqual(@as(i32, exit_errored), @intFromEnum(abi.Status.errored));
}

test "a run that leaked names the count, and one that did not says nothing" {
    // ARC frees every reference at its last release, so a nonzero run-end
    // census is a real leak and is reported; zero says nothing.
    var reported: std.Io.Writer.Allocating = .init(testing.allocator);
    defer reported.deinit();

    printLeaks(&reported.writer, "", "loom", 0);
    try testing.expectEqualStrings("", reported.written());

    printLeaks(&reported.writer, "", "loom", 1);
    try testing.expectEqualStrings(
        "loom: 1 object leaked — a reference the run never released\n",
        reported.written(),
    );

    reported.clearRetainingCapacity();
    printLeaks(&reported.writer, "", "luce", 4);
    try testing.expectEqualStrings(
        "luce: 4 objects leaked — a reference the run never released\n",
        reported.written(),
    );
}

test "a trap report cannot smuggle terminal controls either" {
    // The last channel program text reaches stderr through, and the
    // one that used to be raw: a trap message is whatever the program
    // said, and it is printed while the screen has just been restored.
    // `chr(27) + "[2J"` in a trap message cleared the terminal.
    //
    // Frame names go the same way.  A function name is an identifier
    // and cannot carry one, but a *source* name is a path the world
    // chose, and the ABI hands both over as borrowed bytes.
    var reported: std.Io.Writer.Allocating = .init(testing.allocator);
    defer reported.deinit();

    const trace = [_]Frame{
        .{ .function = "main", .source = "bad\x1b[2J.luc", .line = 3, .column = 5 },
        .{ .function = "helper\x07", .source = "", .line = 0, .column = 0 },
    };
    printTrap(
        &reported.writer,
        "",
        "loom",
        "user_trap",
        "wiping\x1b[2J the screen\x07",
        &trace,
        0,
    );
    try testing.expectEqualStrings(
        "loom: trap: wiping?[2J the screen? [user_trap]\n" ++
            "    at main (bad?[2J.luc:3:5)\n" ++
            "    at helper?\n",
        reported.written(),
    );
    try testing.expect(std.mem.indexOfScalar(u8, reported.written(), 0x1b) == null);

    // An uncaught error takes the same route and the same rule.
    reported.clearRetainingCapacity();
    printError(
        &reported.writer,
        "",
        "loom",
        "io_failed",
        "cannot read \x1b]0;title\x07",
        trace[0],
    );
    try testing.expectEqualStrings(
        "loom: error: cannot read ?]0;title? [io_failed]\n" ++
            "    raised in main (bad?[2J.luc:3:5)\n",
        reported.written(),
    );
    try testing.expect(std.mem.indexOfScalar(u8, reported.written(), 0x1b) == null);
}
