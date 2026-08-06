//! The host boundary, as the language sees it.
//!
//! Every effect a Luce program can have is an optional host service
//! (`interpreter.Host` for the oracle, `abi.Host` for compiled code),
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
        \\func main(args: list(string)) -> !:
        \\    print("args: " + string(len(args)))
        \\    let path = args[0]
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
    // The command line is an ordinary list now, so the first of those
    // is the language's own bounds trap (docs/METHODS.md).
    var session = try agree.compare(
        \\func main(args: list(string)):
        \\    file_write("out.txt", "ignored") catch:
        \\        print("refused")
        \\    let missing = args[5]
        \\
    , .{ .world = .{ .refuse_writes = true } });
    defer session.deinit();

    try testing.expectEqual(mir.TrapCode.index_bounds, session.end.trapped);
    try testing.expectEqualStrings("refused\n", session.printed());
}

// ---------------------------------------------------------------------------
// The command line, as `main`'s parameter
// ---------------------------------------------------------------------------
//
// `args` is *handed to* the program rather than called by it, which is
// why none of this is behind the host gate and why a host with nothing
// to offer supplies an empty list rather than a trap (OWNERSHIP.md
// S44, docs/METHODS.md).  The list is built by `libluce_rt` on both
// arms, so what is under test here is that the two hosts marshal the
// same world into the same list — and, through the leak census, that
// `main`'s scope gives it back.

test "main receives the command line, and args[0] is the first user argument" {
    var world: agree.World = .{};
    world.arguments = &one_argument;

    try agree.printsGiven(
        \\func main(args: list(string)):
        \\    print(string(len(args)))
        \\    print(args[0])
        \\
    , .{ .world = world }, "1\nnotes.txt\n");
}

test "args iterates, slices and joins like any other list(string)" {
    // The point of the parameter over `arg(index)`: it composes with
    // everything `list` already has.
    try agree.printsGiven(
        \\import std.strings
        \\
        \\func main(argv: list(string)):
        \\    for name in argv:
        \\        print(name)
        \\    print(strings.join(argv[1:len(argv)], "-"))
        \\    print(string(argv.contains("beta")))
        \\
    , .{}, "alpha\nbeta\nbeta\ntrue\n");
}

test "a host with no arguments to offer hands main an empty list, not a trap" {
    // Fail-closed for the host builtins means a trap; `args` is not one
    // of them, and the entry cannot fail before `main` starts.
    try agree.printsGiven(
        \\func main(args: list(string)):
        \\    print(string(len(args)))
        \\
    , .console_only, "0\n");
}

test "reading past the end of args is the language's own bounds trap" {
    var world: agree.World = .{};
    world.arguments = &one_argument;

    try agree.trapGiven(
        \\func main(args: list(string)):
        \\    print(args[1])
        \\
    , .{ .world = world }, .index_bounds);
}

test "main's args compose with the raising entry" {
    var world: agree.World = .withFile("notes.txt", "file body");
    world.arguments = &one_argument;

    try agree.printsGiven(
        \\func main(args: list(string)) -> !:
        \\    print(try file_read(args[0]))
        \\
    , .{ .world = world }, "file body\n");
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
        \\        print(string(count) + ":" + line)
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
        \\    print("elapsed " + string(clock_ms() - started))
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
        \\    print(string(clock_ms()))
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
        \\func save(path: string) -> !:
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
        \\func check(n: long) -> long!:
        \\    if n < 0:
        \\        error("negative: " + string(n))
        \\    return n
        \\
        \\func main() -> !:
        \\    print(string(check(-1) catch 0))
        \\    print(string(try check(7)))
        \\    print(string(try check(-2)))
        \\
    , .{});
    defer session.deinit();

    try testing.expectEqual(mir.ErrorCode.user_error, session.end.errored);
    try testing.expectEqualStrings("negative: -2", session.message());
    try testing.expectEqualStrings("0\n7\n", session.printed());
}

// ---------------------------------------------------------------------------
// Errors somebody caught, and could read
// ---------------------------------------------------------------------------

test "catch NAME: binds the words the error carried, whichever code it was" {
    // Both codes in one program, because the binding does not care
    // which: `error(...)` raises the program's own words and a refused
    // write raises the library's, and the handler reads a `string`
    // either way (docs/FAILURE.md).
    var session = try agree.compare(
        \\func check(n: long) -> long!:
        \\    if n < 0:
        \\        error("negative: " + string(n))
        \\    return n
        \\
        \\func main():
        \\    check(-4) catch reason:
        \\        print("user: " + reason)
        \\    file_write("out.txt", "body") catch reason:
        \\        print("io: " + reason)
        \\
    , .{ .world = .{ .refuse_writes = true } });
    defer session.deinit();

    try testing.expectEqualStrings(
        "user: negative: -4\n" ++
            "io: cannot write out.txt\n",
        session.printed(),
    );
}

test "the caught error is consumed: the binding reads it, forget still clears it" {
    // A `catch` that read the words must still leave the channel empty
    // — the run finishes rather than ending errored, and the caller
    // above it sees nothing pending.
    var session = try agree.compare(
        \\func check(n: long) -> long!:
        \\    if n < 0:
        \\        error("negative")
        \\    return n
        \\
        \\func guard(n: long) -> long:
        \\    check(n) catch reason:
        \\        print("handled " + reason)
        \\        return 0
        \\    return n
        \\
        \\func main() -> !:
        \\    print(string(guard(-1)))
        \\    print(string(try check(3)))
        \\
    , .{});
    defer session.deinit();

    try testing.expectEqual(@as(u32, 0), session.end.finished);
    try testing.expectEqualStrings("handled negative\n0\n3\n", session.printed());
}

test "a handler's binding is a local: it owns a copy, and gives it back" {
    // Long enough on purpose that the words cannot live in the value
    // (`inline_capacity` is 22 bytes), so the binding really allocates
    // and really has to release — at the end of the block, and on the
    // `return` that leaves it early (S1).  A leak fails the run under
    // the testing allocator; the census fails it too.
    try agree.ok(
        \\func check(n: long) -> long!:
        \\    if n < 0:
        \\        error("a message far too long to live inside a value: " + string(n))
        \\    return n
        \\
        \\func early() -> long:
        \\    check(-1) catch reason:
        \\        assert(len(reason) > 22)
        \\        return len(reason)
        \\    return 0
        \\
        \\func main():
        \\    var seen: long = 0
        \\    var index = 0
        \\    while index < 100:
        \\        check(0 - index - 1) catch reason:
        \\            seen = seen + len(reason)
        \\        index = index + 1
        \\    assert(seen > 2200)
        \\    assert(early() > 22)
        \\
    );
}

test "catches nest: each handler reads the error its own call raised" {
    try agree.ok(
        \\func inner() -> !:
        \\    error("from inner")
        \\
        \\func outer() -> !:
        \\    error("from outer")
        \\
        \\func main():
        \\    var seen = ""
        \\    outer() catch out_reason:
        \\        inner() catch in_reason:
        \\            seen = seen + in_reason + "/"
        \\        # The inner catch cleared the channel; the outer name
        \\        # is a local that still holds what it read.
        \\        seen = seen + out_reason
        \\    assert(seen == "from inner/from outer")
        \\
    );
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
        \\    term_write(key_read() else "?")
        \\    term_write(key_text())
        \\    let quit = key_read()
        \\    term_flush()
        \\    print(quit else "?")
        \\    print(string(term_rows()) + "x" + string(term_cols()))
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

test "a keyboard with nothing left on it answers none, and empties key_text with it" {
    // One key, then the script is spent.  What the second `key_read`
    // answers is the whole of this fix: `none`, so the program can
    // stop, rather than the host being asked again forever because
    // "no key yet" and "no key ever" arrived as the same answer.
    //
    // `key_text()` is checked *after* the dry read on purpose.  The
    // payload of a key that never came is "", not the one before it —
    // otherwise a program that reads the name and the text separately
    // sees a key that is half there.
    const keys = [_]agree.World.Key{.{ .name = "text", .text = "x" }};
    var session = try agree.compare(
        \\func main():
        \\    let first = key_read()
        \\    print((first else "none") + "/" + key_text())
        \\    let second = key_read()
        \\    print((second else "none") + "/" + key_text())
        \\    let third = key_read()
        \\    print((third else "none") + "/" + key_text())
        \\
    , .{ .world = .{ .keys = &keys } });
    defer session.deinit();

    try testing.expectEqualStrings(
        "text/x\n" ++
            "none/\n" ++
            "none/\n",
        session.printed(),
    );
}
