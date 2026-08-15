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
        \\    if (try path_kind(path)) != 0:
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

// ---------------------------------------------------------------------------
// Making a directory
// ---------------------------------------------------------------------------
//
// Two rules the service publishes and these specs hold it to: it makes
// the parents, and a directory already there is success.  Both are one
// decision — the call means "there is a directory at this path when I
// return" — and both are what keeps a caller out of a check-then-create
// race.

test "dir_create makes the directory, and the parents leading to it" {
    var session = try agree.compare(
        \\func main() -> !:
        \\    try dir_create("store/packages/geo-1.2.0")
        \\    print("made")
        \\
    , .{});
    defer session.deinit();

    var rows: [8][]const u8 = undefined;
    const made = session.directories(&rows);
    try testing.expectEqual(@as(usize, 3), made.len);
    // Parents first, because that is the order they had to be made in.
    try testing.expectEqualStrings("store", made[0]);
    try testing.expectEqualStrings("store/packages", made[1]);
    try testing.expectEqualStrings("store/packages/geo-1.2.0", made[2]);
    try testing.expectEqualStrings("made\n", session.printed());
}

test "a directory already there is success, not an error" {
    // The install path's whole shape: make it, make it again, and get
    // on with the work.  If the second call raised, every caller would
    // write an existence check in front of it, and that check is a
    // race (docs/FAILURE.md).
    var session = try agree.compare(
        \\func main() -> !:
        \\    try dir_create("papers")
        \\    try dir_create("papers")
        \\    dir_create("papers") catch:
        \\        print("refused")
        \\    print("still one")
        \\
    , .{});
    defer session.deinit();

    var rows: [8][]const u8 = undefined;
    const made = session.directories(&rows);
    try testing.expectEqual(@as(usize, 1), made.len);
    try testing.expectEqualStrings("papers", made[0]);
    try testing.expectEqualStrings("still one\n", session.printed());
}

test "a file in the way is an error the caller can catch" {
    // The one refusal idempotence must not swallow: something is
    // there, and it is not a directory.  News rather than a trap, like
    // everything else the world decides.
    var session = try agree.compare(
        \\func main() -> !:
        \\    try dir_create("notes.txt")
        \\
    , .{ .world = .withFile("notes.txt", "body") });
    defer session.deinit();

    try testing.expectEqual(mir.ErrorCode.io_failed, session.end.errored);
    try testing.expectEqualStrings("cannot make directory notes.txt", session.message());
}

test "a world that refuses writes makes no directory at all" {
    var session = try agree.compare(
        \\func main():
        \\    dir_create("a/b/c") catch:
        \\        print("refused")
        \\
    , .{ .world = .{ .refuse_writes = true } });
    defer session.deinit();

    var rows: [8][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 0), session.directories(&rows).len);
    try testing.expectEqualStrings("refused\n", session.printed());
}

// ---------------------------------------------------------------------------
// What is at a path
// ---------------------------------------------------------------------------
//
// The one question `file_exists` could not ask (docs/FILESYSTEM.md
// D11).  Three things can happen and the language has exactly three
// ways to say them, so each gets its own: a number for what is there,
// zero for nothing there, and the error channel for a world that would
// not say.  These specs hold all three apart.

test "path_kind names what is there, and nothing there is an answer" {
    var world: agree.World = .withFile("notes.txt", "body");
    world.kinds = &[_]agree.World.KindRow{
        .{ .path = "notes.txt", .kind = .file },
        .{ .path = "papers", .kind = .directory },
        .{ .path = "wire", .kind = .other },
    };
    var session = try agree.compare(
        \\func main() -> !:
        \\    print(string(try path_kind("notes.txt")))
        \\    print(string(try path_kind("papers")))
        \\    print(string(try path_kind("wire")))
        \\    print(string(try path_kind("ghost.txt")))
        \\
    , .{ .world = world });
    defer session.deinit();

    // 1 file, 2 directory, 3 other, 0 nothing — and the zero arrived
    // as a `yes`, which is the whole point: absence is an answer.
    try testing.expectEqualStrings("1\n2\n3\n0\n", session.printed());
}

test "a world that will not say is an error, not an absence" {
    // The measured case: `chmod 000` on a parent.  The file under it
    // certainly exists, and `file_exists` answered `false` — the same
    // bit it gave a name nothing holds.  Here the two are different
    // sentences.
    var world: agree.World = .{};
    world.refused_kinds = &[_][]const u8{"locked"};
    var session = try agree.compare(
        \\func main() -> !:
        \\    try path_kind("locked/inside.txt")
        \\
    , .{ .world = world });
    defer session.deinit();

    try testing.expectEqual(mir.ErrorCode.io_failed, session.end.errored);
    try testing.expectEqualStrings("cannot inspect locked/inside.txt", session.message());
}

// ---------------------------------------------------------------------------
// The wall clock
// ---------------------------------------------------------------------------

test "epoch_ms answers what time it is, and never goes backwards" {
    // What a spec can prove about a calendar is the shape of the
    // answer and not the date: a plausible number of milliseconds
    // since 1970 — long past the epoch, not yet the far future — and
    // two readings in order.  What the *real* calendar says is
    // `apps/host.zig`'s business, and its own test's.
    try agree.prints(
        \\func main():
        \\    let first = epoch_ms()
        \\    let second = epoch_ms()
        \\    assert(first > 1000000000000)
        \\    assert(first < 100000000000000)
        \\    assert(second >= first)
        \\    print("epoch ok")
        \\
    , "epoch ok\n");
}

test "the two clocks are two questions" {
    // `clock_ms` measures a span and `epoch_ms` names a moment, which
    // is why they are two builtins and not one: this world's monotonic
    // clock starts at a thousand and its calendar in 2025, and a
    // program reading both gets both.
    try agree.prints(
        \\func main():
        \\    print(string(clock_ms()))
        \\    print(string(epoch_ms()))
        \\    print(string(clock_ms()))
        \\    print(string(epoch_ms()))
        \\
    ,
        \\1000
        \\1755000000000
        \\1017
        \\1755000000003
        \\
    );
}

test "a host with no calendar refuses rather than inventing a date" {
    // The other road to the same trap: the slot is *there* and the
    // host says it cannot tell.  A number would be a lie the program
    // could not see through (`apps/machine.zig`'s rule).
    var provided: agree.Provided = .{};
    provided.world.timeless = true;
    try agree.trapGiven(
        \\func main():
        \\    print(string(epoch_ms()))
        \\
    , provided, .host_unavailable);
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
        \\
        ,
        \\func main() -> !:
        \\    try dir_create("x")
        \\
        ,
        \\func main() -> !:
        \\    print(string(try path_kind("x")))
        \\
        ,
        \\func main():
        \\    print(string(epoch_ms()))
        \\
        ,
        \\func main():
        \\    print(string(os_total_memory()))
        \\
        ,
        \\func main():
        \\    print(string(os_available_memory()))
        \\
        ,
        \\func main():
        \\    print(string(os_cpu_count()))
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

test "the assignment form takes a binding too, and the place keeps its old value" {
    // `place = call() catch NAME:` is the second statement shape the
    // handler attaches to, and the handler runs where the call raised
    // — so the assignment never happened and `text` still holds what
    // it held (docs/FAILURE.md).
    var session = try agree.compare(
        \\func main():
        \\    var text = "unchanged"
        \\    var note = ""
        \\    text = file_read("missing.txt") catch reason:
        \\        note = reason
        \\    print(text)
        \\    print(note)
        \\
    , .{});
    defer session.deinit();

    try testing.expectEqualStrings(
        "unchanged\n" ++
            "cannot read missing.txt\n",
        session.printed(),
    );
}

test "a call site that raised after it returned gives nothing back twice" {
    // The shape a thousand-line program found and no small one had
    // (`examples/adventure/adventure.luc`, `src/luce/specs/adventure_spec.zig`):
    // **one** call site, run more than once, answering a value that
    // owns storage, and raising on a later turn than the one it
    // returned on.
    //
    // A fallible call's answer has to survive the branch on its
    // outcome, so stage 4 stores it in a slot.  That store used to
    // stand in front of the branch — where the failing edge reaches it
    // too, and a call that raised never wrote its result register.  So
    // the slot took whatever the register held from the *previous* run
    // of the same instruction, which is the last answer, whose storage
    // the merge block had already released.  Releasing the slot then
    // freed it a second time.  It survived every small program in this
    // suite because a first raise finds the register at its zero and
    // two raising sites are two registers: it needs a *loop*, and one
    // turn that worked before one that did not.
    //
    // The store stands on the returning side now, so the failing edge
    // leaves the slot holding the emptied value its own release wrote
    // back — and releasing that frees nothing.
    try agree.ok(
        \\struct Turn:
        \\    at: long = 0
        \\    note: string = "start"
        \\
        \\    func act(order: string) -> !:
        \\        if order == "no":
        \\            error("cannot " + order)
        \\        self.at += 1
        \\        self.note = order + " " + string(self.at)
        \\
        \\func main():
        \\    var turn = Turn()
        \\    let orders = ["go", "no", "go", "no", "go"]
        \\    for order in orders:
        \\        turn.act(order) catch reason:
        \\            print(reason)
        \\    assert(turn.at == 3)
        \\    assert(turn.note == "go 3")
        \\
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
        \\    # And out of a loop from inside a handler: `break` unwinds
        \\    # scopes innermost first, and the binding's is one of them.
        \\    var stopped: long = 0
        \\    while true:
        \\        check(-7) catch reason:
        \\            stopped = len(reason)
        \\            break
        \\    assert(stopped > 22)
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

test "term_style's defaults fill from the table, on both engines" {
    // docs/ARGS.md §3: the table is the builtin's signature, and its
    // two defaults — bg = -1, bold = false — are the whole of what
    // the fifteen-call corpus was writing out by hand.  The host log
    // shows the same three values whichever way the call spelled
    // them.
    var session = try agree.compare(
        \\func main():
        \\    term_style(114)
        \\    term_style(200, bold = true)
        \\    term_style(bold = true, fg = 15, bg = 3)
        \\    term_flush()
        \\
    , .{});
    defer session.deinit();

    try testing.expectEqualStrings("[style]114,-1,false\n" ++
        "[style]200,-1,true\n" ++
        "[style]15,3,true\n" ++
        "[flush]\n", session.printed());
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

// ---------------------------------------------------------------------------
// exit — the fourth way a run ends
// ---------------------------------------------------------------------------
//
// Not a trap (nothing is wrong), not an error (nothing failed): the
// program chose to stop, and the status it chose crosses the host
// boundary at the exit site.  Both engines unwind the same way a trap
// unwinds — no releases run — so the transcript, the status, and the
// census are all compared, and `exit(0)` is still `exited`, distinct
// from a run that finished.

test "exit ends the run with its status, and everything before it happened" {
    // A statement *after* an exit in the same block is refused
    // statically — `luce.sema.unreachable` names the exit that leaves
    // first (the errors_spec has the row) — so the dead branch here is
    // behind a condition the analyzer cannot fold.
    var session = try agree.compare(
        \\func main():
        \\    print("before")
        \\    var stopping = true
        \\    if stopping:
        \\        exit(3)
        \\    print("after")
        \\
    , .{});
    defer session.deinit();
    try std.testing.expectEqualStrings("before\n", session.printed());
    try std.testing.expectEqual(agree.End{ .exited = 3 }, session.end);
}

test "exit(0) is exited, not finished — the program said so" {
    try agree.exits(
        \\func main():
        \\    exit(0)
        \\
    , .{}, 0);
}

test "exit unwinds through nested calls, and the census counts what stood" {
    // The unwind skips releases exactly as a trap's does, on both
    // engines: the list `main` owns and the one `stop` owns are both
    // standing when the run ends, and `settle` holds the two engines
    // to the same census.
    try agree.exits(
        \\func stop(code: long):
        \\    var mine = [1, 2, 3]
        \\    print("stopping " + string(len(mine)))
        \\    exit(code)
        \\
        \\func main():
        \\    var kept = [4, 5]
        \\    print("have " + string(len(kept)))
        \\    stop(7)
        \\
    , .{}, 7);
}

test "exit unwinds a union carrying a callback and an owned list" {
    try agree.exits(
        \\union Job:
        \\    run(action: (func(long) -> long)?, items: list(long))
        \\
        \\func twice(value: long) -> long:
        \\    return value * 2
        \\
        \\func stop(code: long):
        \\    var job = Job.run(action = twice, items = [8, 9])
        \\    exit(code)
        \\
        \\func main():
        \\    var kept = Job.run(action = twice, items = [1, 2, 3])
        \\    stop(7)
        \\
    , .{}, 7);
}

test "a negative and a large status cross the boundary intact" {
    // The host receives the long the program wrote; what an OS does
    // with it is the loader's business (POSIX keeps the low byte),
    // and the boundary itself does not editorialize.
    try agree.exits(
        \\func main():
        \\    exit(-1)
        \\
    , .{}, -1);
    try agree.exits(
        \\func main():
        \\    exit(70000)
        \\
    , .{}, 70000);
}

test "exit fails closed: a host that cannot carry a status refuses the call" {
    try agree.trapGiven(
        \\func main():
        \\    exit(1)
        \\
    , .{ .exit = false }, .host_unavailable);
}

// ---------------------------------------------------------------------------
// The machine's own facts
// ---------------------------------------------------------------------------
//
// Three services of one shape, and the one shape in the table that
// answers a *number* through an out-parameter: the answer carries
// whether the host could tell at all.  These rows exercise the
// builtins directly; `std_spec.zig` exercises `std.os` over them.

test "the three machine facts reach the host and come back as written" {
    try agree.prints(
        \\func main():
        \\    print(string(os_total_memory()))
        \\    print(string(os_available_memory()))
        \\    print(string(os_cpu_count()))
        \\
    ,
        \\8589934592
        \\3221225472
        \\4
        \\
    );
}

test "a fact asked twice is asked twice, not folded to one call" {
    // Available memory moves, which is the reason a program asks it in
    // a loop — so the optimizer must not treat two readings as one.
    // The seeded world answers the same number both times, so what
    // this actually holds is that the second call still *happens* and
    // still crosses both engines the same way.
    try agree.prints(
        \\func main():
        \\    var seen = 0
        \\    for round in range(0, 3):
        \\        seen = seen + 1
        \\        print(string(os_available_memory()))
        \\    print("read " + string(seen))
        \\
    ,
        \\3221225472
        \\3221225472
        \\3221225472
        \\read 3
        \\
    );
}

test "a host that cannot tell refuses exactly as one without the slot does" {
    // Two roads, one trap.  The slot is present and answers `no`; the
    // program must not be able to tell that from a host that never
    // offered the service, because in neither case did anyone measure
    // anything.
    const unmeasurable: agree.Provided = .{ .world = .{ .unmeasurable = true } };
    try agree.trapGiven(
        \\func main():
        \\    print(string(os_total_memory()))
        \\
    , unmeasurable, .host_unavailable);
    try agree.trapGiven(
        \\func main():
        \\    print(string(os_total_memory()))
        \\
    , .{ .machine = false }, .host_unavailable);
}

test "a refused fact stops the program where it stood" {
    // Fail-closed means the trap lands at the call, before the number
    // could reach anything: the print after it never runs, on either
    // engine.
    var session = try agree.compare(
        \\func main():
        \\    print("asking")
        \\    let bytes = os_available_memory()
        \\    print("got " + string(bytes))
        \\
    , .{ .world = .{ .unmeasurable = true } });
    defer session.deinit();
    try testing.expectEqualStrings("asking\n", session.printed());
    try testing.expectEqual(mir.TrapCode.host_unavailable, session.end.trapped);
}
