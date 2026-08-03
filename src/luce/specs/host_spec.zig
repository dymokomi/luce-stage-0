//! The host boundary, as the language sees it.
//!
//! Every effect a Luce program can have is an optional host service
//! (`backend.Host` for the interpreter, `abi.Host` for compiled code),
//! and both tables are built here from one `World` — so a program's
//! console, files, arguments, screen, keyboard, standard input, clock
//! and environment are the same world twice, and the two engines are
//! compared on what they printed *and* on what they left in it
//! (`specs/agree.zig`).
//!
//! Two rules are proved here more than anywhere else:
//!
//!  - **A missing service traps rather than touching anything.**  Each
//!    group has to fail closed on its own, on both engines, with the
//!    same `host_unavailable`.
//!  - **A refused effect is news, not a fault.**  A write the world
//!    would not take raises an error the caller can catch; an argument
//!    index no argument could have is the program's mistake and traps
//!    (docs/FAILURE.md).
//!
//! These tests were the interpreter's own suite until the interpreter
//! stopped being an engine (docs/ENGINE.md).  They were always
//! statements about the language, so they live here now and run on
//! both engines like everything else.

const std = @import("std");
const agree = @import("agree.zig");
const luce = @import("luce");
const mir = luce.mir;

const testing = std.testing;

/// One argument, and it names the file this world holds.
const one_argument = [_][]const u8{"notes.txt"};

// ---------------------------------------------------------------------------
// The console, arguments, and files
// ---------------------------------------------------------------------------

test "a host builtin with no host at all traps host_unavailable" {
    try agree.trapGiven(
        \\func main():
        \\    print("hello")
        \\
    , .nothing, .host_unavailable);
}

test "print, arguments, and files flow through the host" {
    var world: agree.World = .withFile("notes.txt", "file body");
    world.arguments = &one_argument;

    var session = try agree.compare(
        \\func main() -> !:
        \\    print("args: " + str(arg_count()))
        \\    let path = arg(0)
        \\    if file_exists(path):
        \\        print(try file_read(path))
        \\    try file_write("out.txt", "saved")
        \\
    , .{ .world = world });
    defer session.deinit();

    try testing.expectEqualStrings("args: 1\nfile body\n", session.printed());
    const left = session.file().?;
    try testing.expectEqualStrings("out.txt", left.name);
    try testing.expectEqualStrings("saved", left.content);
}

test "an argument out of range traps, and a refused write is an error" {
    // The two failures a host can hand back, and the line between
    // them: an index no argument could have is the program's mistake,
    // and a write the world would not take is not (docs/FAILURE.md).
    var session = try agree.compare(
        \\func main():
        \\    file_write("out.txt", "ignored") catch:
        \\        print("refused")
        \\    let missing = arg(5)
        \\
    , .{ .world = .{ .refuse_writes = true } });
    defer session.deinit();

    try testing.expectEqual(mir.TrapCode.argument_bounds, session.end.trapped);
    try testing.expectEqualStrings("refused\n", session.printed());
}

// ---------------------------------------------------------------------------
// Standard input, standard error, the clock, the environment
// ---------------------------------------------------------------------------

test "read_line answers a line, then absence; the prompt goes out in front" {
    // Three reads, three prompts: the third is what discovered the end
    // of input.  Prompts are recorded in the transcript, so the order
    // of prompt against line is compared too.
    try agree.prints(
        \\func main():
        \\    var count = 0
        \\    var line = read_line("> ")
        \\    while line != none:
        \\        count = count + 1
        \\        print(str(count) + ":" + line)
        \\        line = read_line("> ")
        \\    print("done")
        \\
    , "[prompt]> \n" ++
        "1:first line\n" ++
        "[prompt]> \n" ++
        "2:second line\n" ++
        "[prompt]> \n" ++
        "done\n");
}

test "the clock, the wait and the environment reach the host" {
    // A duration that has already elapsed still reaches the host,
    // which is what decides there is no time left to wait — the
    // language does not make that a trap.
    try agree.prints(
        \\func main():
        \\    let started = clock_ms()
        \\    sleep_ms(30)
        \\    print("elapsed " + str(clock_ms() - started))
        \\    sleep_ms(0)
        \\    sleep_ms(-5)
        \\    print_error("to stderr")
        \\    print(env("LUCE_MODE") else "(unset)")
        \\    print(env("NOTHING") else "(unset)")
        \\
    ,
        \\[sleep]30
        \\elapsed 17
        \\[sleep]0
        \\[sleep]-5
        \\[stderr]to stderr
        \\test
        \\(unset)
        \\
    );
}

test "every host service fails closed when the host withholds it" {
    const cases = [_][]const u8{
        \\func main():
        \\    print(read_line("") else "x")
        \\
        ,
        \\func main():
        \\    print_error("x")
        \\
        ,
        \\func main():
        \\    print(str(clock_ms()))
        \\
        ,
        \\func main():
        \\    sleep_ms(1)
        \\
        ,
        \\func main():
        \\    print(env("X") else "y")
        \\
        ,
        \\func main() -> !:
        \\    try file_append("x", "y")
        \\
        ,
        \\func main() -> !:
        \\    try file_delete("x")
        \\
        ,
        \\func main() -> !:
        \\    try file_rename("x", "y")
        \\
        ,
        \\func main() -> !:
        \\    let names = try dir_list(".")
        \\    free(names)
        \\
        ,
    };
    for (cases) |source| {
        try agree.trapGiven(source, .console_only, .host_unavailable);
    }
}

// ---------------------------------------------------------------------------
// Errors nobody caught
// ---------------------------------------------------------------------------

test "an uncaught error names its code, its words, and where it was raised" {
    var session = try agree.compare(
        \\func save(path: String) -> !:
        \\    try file_write(path, "body")
        \\
        \\func main() -> !:
        \\    print("before")
        \\    try save("out.txt")
        \\    print("never")
        \\
    , .{ .world = .{ .refuse_writes = true } });
    defer session.deinit();

    try testing.expectEqual(mir.ErrorCode.io_failed, session.end.errored);
    try testing.expectEqualStrings("cannot write out.txt", session.message());
    try testing.expectEqualStrings("before\n", session.printed());
    // One position, and it is the raise site rather than a stack: the
    // `try file_write` inside `save`, not the `try save` in `main`.
    try testing.expectEqualStrings("save test.luc:2:5\n", session.trace());
}

test "error() raises the program's own words, and catch discards them" {
    var session = try agree.compare(
        \\func check(n: Int) -> Int!:
        \\    if n < 0:
        \\        error("negative: " + str(n))
        \\    return n
        \\
        \\func main() -> !:
        \\    print(str(check(-1) catch 0))
        \\    print(str(try check(7)))
        \\    print(str(try check(-2)))
        \\
    , .{});
    defer session.deinit();

    try testing.expectEqual(mir.ErrorCode.user_error, session.end.errored);
    try testing.expectEqualStrings("negative: -2", session.message());
    try testing.expectEqualStrings("0\n7\n", session.printed());
}

// ---------------------------------------------------------------------------
// The terminal
// ---------------------------------------------------------------------------

test "terminal builtins drive the host screen and key queue" {
    const keys = [_]agree.World.Key{
        .{ .name = "text", .text = "λ" },
        .{ .name = "ctrl_q" },
    };
    var session = try agree.compare(
        \\func main():
        \\    term_clear()
        \\    term_move(1, 2)
        \\    term_style(114, -1, true)
        \\    term_write("hi ")
        \\    term_write(key_read())
        \\    term_write(key_text())
        \\    let quit = key_read()
        \\    term_flush()
        \\    print(quit)
        \\    print(str(term_rows()) + "x" + str(term_cols()))
        \\
    , .{ .world = .{ .keys = &keys } });
    defer session.deinit();

    try testing.expectEqualStrings("[clear]\n" ++
        "[move]1,2\n" ++
        "[style]114,-1,true\n" ++
        "[write]hi \n" ++
        "[write]text\n" ++
        "[write]\u{3bb}\n" ++
        "[flush]\n" ++
        "ctrl_q\n" ++
        "24x80\n", session.printed());
}
