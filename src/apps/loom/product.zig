//! The two binaries, proved together — and loom at its command line.
//!
//! `loom` does not carry a code generator: when it meets a program with
//! no current artifact beside it, it runs the `luce` binary to build
//! one (`runner.zig`).  That hand-off is a property of the *installed
//! pair*, not of either module, so nothing short of running both
//! executables can prove it — these tests build a miniature install
//! tree in a temporary directory and use it exactly as a person would.
//!
//! What they hold to:
//!
//!   * a `.luc` with no artifact present compiles and runs, and leaves
//!     the artifact beside itself for the next run to find;
//!   * the `.lc` `luce build` writes runs under a loom that has no
//!     compiler at all, because a `.lc` is machine code;
//!   * a loom that cannot find `luce` says so, naming the binary that
//!     is missing and where it was looked for — there is no second
//!     engine to fall back to, and a `.luc` needs a compiler exactly
//!     as a `.c` does;
//!   * every form of the command line does what its usage says, and
//!     every one that does not answers with a status a shell can read
//!     and a sentence a person can act on;
//!   * a script piped in ends on the worst thing any line did, because
//!     a build step that swallowed a failure is worse than no build
//!     step;
//!   * and the serialized module a compile hands over is gone
//!     afterwards, whether the compile worked or not — a `.lcm` is a
//!     hand-over, never a deliverable, and one left behind is litter
//!     in somebody's source directory.
//!
//! `apps/loom/artifacts.zig` carries the other half of the perimeter:
//! what loom refuses to load, and what it says about each refusal.
//!
//! Every stream is a real file rather than a pipe.  A pipe that fills
//! while the parent is draining the other one deadlocks, and nothing
//! here should have to know which of a program's two channels talks
//! first; a file also makes standard input something a test can simply
//! write, which is how the piped shell gets proved.

const std = @import("std");
const build_options = @import("build_options");
const harness = @import("harness");
const luce = @import("luce");

const testing = std.testing;
const io = std.testing.io;
const Allocator = std.mem.Allocator;
const Install = harness.Install;
const Ran = harness.Ran;
const environmentWith = harness.environmentWith;

// ---------------------------------------------------------------------------
// A miniature install tree
// ---------------------------------------------------------------------------

/// `loom` and `luce` at the root, the runtime library under `lib/`,
/// which is the layout `zig build --prefix` produces and the one
/// `native.discover` looks for.  The tree itself and the way to run
/// what is in it are `apps/harness.zig`'s, shared with the compiler's
/// suite; what goes into this one is this suite's — and half these
/// tests are about a loom with no compiler beside it, which is what
/// `with_compiler` withholds.
fn installTree(gpa: Allocator, with_compiler: bool) !Install {
    var tree = try Install.make(gpa);
    errdefer tree.deinit(gpa);
    try tree.place(build_options.loom_binary, "loom");
    if (with_compiler) {
        try tree.place(build_options.luce_binary, "luce");
        try tree.place(build_options.luce_rt_library, "lib/libluce_rt.a");
    }
    return tree;
}

/// Run the installed loom, optionally with `script` on its standard
/// input — which is what turns the interactive shell into the
/// non-interactive one, and is the only way to reach the status a piped
/// loom exits with.  `environment` null inherits this process's, which
/// is what gives the compiler a `cc` to link with.
fn runLoom(
    gpa: Allocator,
    install: *const Install,
    arguments: []const []const u8,
    environment: ?*const std.process.Environ.Map,
    script: ?[]const u8,
) !Ran {
    const loom = try install.at(gpa, "loom");
    defer gpa.free(loom);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, loom);
    try argv.appendSlice(gpa, arguments);
    return install.spawn(gpa, argv.items, .{ .environment = environment, .input = script });
}

/// Run the compiler in the tree — for the tests that need a real
/// artifact before they can break one.
fn runLuce(gpa: Allocator, install: *const Install, arguments: []const []const u8) !Ran {
    const compiler = try install.at(gpa, "luce");
    defer gpa.free(compiler);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, compiler);
    try argv.appendSlice(gpa, arguments);
    return install.spawn(gpa, argv.items, .{});
}

// ---------------------------------------------------------------------------
// Stand-ins for the compiler
// ---------------------------------------------------------------------------

/// Put a stand-in where the compiler goes: a script that records having
/// been called, says something, and exits with `status`.
///
/// The real compiler cannot be made to fail on demand — every program a
/// script can express lowers — so the exit-code contract between the
/// two binaries is proved against a stand-in that can.
fn plantCompiler(install: *const Install, gpa: Allocator, status: u8, says: []const u8) !void {
    // `echo` and the redirect are shell builtins; nothing here runs a
    // program, because the PATH these tests hand loom holds only the
    // install tree and there is no `dirname` on it.
    const script = try std.fmt.allocPrint(gpa,
        \\#!/bin/sh
        \\echo call >> "{s}/calls"
        \\echo "{s}" >&2
        \\exit {d}
        \\
    , .{ install.root, says, status });
    defer gpa.free(script);
    try install.writeScript(gpa, "luce", script);
}

/// Put a stand-in where the compiler goes that *succeeds* and hands
/// back an artifact for a different program.
///
/// Not a contrivance: a build rule with a stale `-o`, a cache that
/// answered the wrong key, a copy that raced — every one of them looks
/// exactly like this from where loom stands, and the loader is the only
/// thing that can tell.  It is the one way to reach the `source`
/// refusal from outside, because the real compiler cannot be made to
/// build the wrong program.
fn plantCopyingCompiler(install: *const Install, gpa: Allocator, artifact: []const u8) !void {
    // `luce build MODULE -o OUTPUT`: the fourth word is where the
    // artifact was asked for.
    const script = try std.fmt.allocPrint(gpa,
        \\#!/bin/sh
        \\echo call >> "{s}/calls"
        \\cp "{s}" "$4"
        \\exit 0
        \\
    , .{ install.root, artifact });
    defer gpa.free(script);
    try install.writeScript(gpa, "luce", script);
}

/// How many times a stand-in was called.
fn calls(install: *const Install, gpa: Allocator) !usize {
    const text = install.read(gpa, "calls") catch return 0;
    defer gpa.free(text);
    return std.mem.count(u8, text, "\n");
}

const greeting =
    \\func main():
    \\    var total: long = 0
    \\    for index in range(0, 5):
    \\        total = total + index * index
    \\    print("total " + string(total))
    \\
;

const expected = "total 30\n";

test "a .luc with no artifact is compiled by luce and runs, warm the next time" {
    const gpa = testing.allocator;
    var install = try installTree(gpa, true);
    defer install.deinit(gpa);
    try install.write("sums.luc", greeting);

    const program = try install.at(gpa, "sums.luc");
    defer gpa.free(program);

    try testing.expect(!install.exists("sums.lc"));
    var cold = try runLoom(gpa, &install, &.{program}, null, null);
    defer cold.deinit(gpa);
    try testing.expectEqualStrings("", cold.err);
    try testing.expectEqualStrings(expected, cold.out);
    try testing.expectEqual(@as(u8, 0), cold.status);

    // The compiler left the artifact where the next run will find it.
    try testing.expect(install.exists("sums.lc"));
    // And took its hand-over back with it: the serialized module a
    // compile is driven by is a seam, not a deliverable, and one left
    // in somebody's source directory is litter they did not make.
    try testing.expect(!try install.holdsAnything(luce.mir.module.extension));

    var warm = try runLoom(gpa, &install, &.{program}, null, null);
    defer warm.deinit(gpa);
    try testing.expectEqualStrings("", warm.err);
    try testing.expectEqualStrings(expected, warm.out);
    try testing.expect(!try install.holdsAnything(luce.mir.module.extension));
}

test "the .lc luce writes runs on a loom with no compiler at all" {
    const gpa = testing.allocator;
    var install = try installTree(gpa, true);
    defer install.deinit(gpa);
    try install.write("sums.luc", greeting);

    const compiler = try install.at(gpa, "luce");
    defer gpa.free(compiler);
    const source = try install.at(gpa, "sums.luc");
    defer gpa.free(source);
    const built = try std.process.run(gpa, io, .{ .argv = &.{ compiler, "build", source } });
    defer gpa.free(built.stdout);
    defer gpa.free(built.stderr);
    try testing.expectEqual(@as(u8, 0), built.term.exited);
    try testing.expect(install.exists("sums.lc"));

    // The compiler is taken away, and so is anything a build could
    // need: what is left is a `.lc`, a loom, and a `dlopen`.
    try install.scratch.dir.deleteFile(io, "luce");
    var bare: std.process.Environ.Map = .init(gpa);
    defer bare.deinit();
    try bare.put("PATH", install.root);

    const artifact = try install.at(gpa, "sums.lc");
    defer gpa.free(artifact);
    var ran = try runLoom(gpa, &install, &.{ "run", artifact }, &bare, null);
    defer ran.deinit(gpa);
    try testing.expectEqualStrings("", ran.err);
    try testing.expectEqualStrings(expected, ran.out);
    try testing.expectEqual(@as(u8, 0), ran.status);

    // The bare path is the same command with the word left off.
    var sugared = try runLoom(gpa, &install, &.{artifact}, &bare, null);
    defer sugared.deinit(gpa);
    try testing.expectEqualStrings("", sugared.err);
    try testing.expectEqualStrings(expected, sugared.out);
    try testing.expectEqual(@as(u8, 0), sugared.status);
}

test "a program named the way a person in its directory names it is the file, not a library" {
    // `cd somewhere; loom run sums.lc` — no directory in the name at
    // all, which is how anybody standing in the directory says it.
    //
    // A platform loader reads a bare word as a *library name* and
    // looks where the system keeps libraries, which is never here;
    // only dyld falls back to the working directory, so this spelling
    // worked on macOS and on nothing else until loom made the path a
    // path (`native.open`).
    const gpa = testing.allocator;
    var install = try installTree(gpa, true);
    defer install.deinit(gpa);
    try install.write("sums.luc", greeting);

    const source = try install.at(gpa, "sums.luc");
    defer gpa.free(source);
    var built = try runLuce(gpa, &install, &.{ "build", source });
    defer built.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), built.status);

    const loom = try install.at(gpa, "loom");
    defer gpa.free(loom);
    var ran = try install.spawn(gpa, &.{ loom, "run", "sums.lc" }, .{ .in_tree = true });
    defer ran.deinit(gpa);
    try testing.expectEqualStrings("", ran.err);
    try testing.expectEqualStrings(expected, ran.out);
    try testing.expectEqual(@as(u8, 0), ran.status);

    // And the same word with `run` left off, which is the spelling the
    // shell offers.
    var sugared = try install.spawn(gpa, &.{ loom, "sums.lc" }, .{ .in_tree = true });
    defer sugared.deinit(gpa);
    try testing.expectEqualStrings("", sugared.err);
    try testing.expectEqualStrings(expected, sugared.out);
    try testing.expectEqual(@as(u8, 0), sugared.status);
}

test "a .luc with no luce to compile it says which binary is missing and where it looked" {
    const gpa = testing.allocator;
    var install = try installTree(gpa, false);
    defer install.deinit(gpa);
    try install.write("sums.luc", greeting);

    const program = try install.at(gpa, "sums.luc");
    defer gpa.free(program);

    // An environment with nowhere to find a compiler: not beside loom,
    // because nothing was installed there, and not on PATH.
    var bare: std.process.Environ.Map = .init(gpa);
    defer bare.deinit();
    try bare.put("PATH", install.root);

    var ran = try runLoom(gpa, &install, &.{program}, &bare, null);
    defer ran.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), ran.status);
    try testing.expectEqualStrings("", ran.out);
    // The tool by name, the directory it should have been in, and the
    // other place that was tried — enough to act on without guessing.
    try testing.expect(ran.saysErr("`luce`"));
    try testing.expect(ran.saysErr(install.root));
    try testing.expect(ran.saysErr("PATH"));
    // Nothing was built, and nothing was left behind pretending to be.
    try testing.expect(!install.exists("sums.lc"));
    try testing.expect(!try install.holdsAnything(luce.mir.module.extension));

    // `loom edit` reaches the same wall, because the editor is a Luce
    // program like any other and there is nothing here to build it
    // with.  This is also the whole of what `edit` does without a
    // terminal to draw on: it says why, and stops.
    var edited = try runLoom(gpa, &install, &.{ "edit", program }, &bare, null);
    defer edited.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), edited.status);
    try testing.expect(edited.saysErr("`luce`"));
}

test "a compiler that refuses the program is asked once; one that fails a place is asked again" {
    const gpa = testing.allocator;

    // Exit 1 is about *this attempt*, so the other place is tried: two
    // calls, one beside the program and one in the temp directory.
    {
        var install = try installTree(gpa, false);
        defer install.deinit(gpa);
        try install.write("sums.luc", greeting);
        try plantCompiler(&install, gpa, 1, "luce: cannot write it");

        const program = try install.at(gpa, "sums.luc");
        defer gpa.free(program);
        var environment: std.process.Environ.Map = .init(gpa);
        defer environment.deinit();
        try environment.put("PATH", install.root);
        try environment.put("TMPDIR", install.root);

        var ran = try runLoom(gpa, &install, &.{program}, &environment, null);
        defer ran.deinit(gpa);
        try testing.expectEqual(@as(u8, 1), ran.status);
        // Whatever the compiler said is what the reader is told.
        try testing.expect(ran.saysErr("cannot write it"));
        try testing.expectEqual(@as(usize, 2), try calls(&install, gpa));
        // Both attempts took their hand-over back: a build that failed
        // leaves no more behind than one that worked.
        try testing.expect(!try install.holdsAnything(luce.mir.module.extension));
    }

    // Exit 2 is about the *program*, and no directory changes that.
    {
        var install = try installTree(gpa, false);
        defer install.deinit(gpa);
        try install.write("sums.luc", greeting);
        try plantCompiler(&install, gpa, 2, "sums.lc: linking failed: no C toolchain");

        const program = try install.at(gpa, "sums.luc");
        defer gpa.free(program);
        var environment: std.process.Environ.Map = .init(gpa);
        defer environment.deinit();
        try environment.put("PATH", install.root);
        try environment.put("TMPDIR", install.root);

        var ran = try runLoom(gpa, &install, &.{program}, &environment, null);
        defer ran.deinit(gpa);
        try testing.expectEqual(@as(u8, 1), ran.status);
        try testing.expect(ran.saysErr("no C toolchain"));
        try testing.expectEqual(@as(usize, 1), try calls(&install, gpa));
        try testing.expect(!try install.holdsAnything(luce.mir.module.extension));
    }
}

// ---------------------------------------------------------------------------
// The command line
// ---------------------------------------------------------------------------

test "every form loom does not have answers with usage, and every usage names them all" {
    const gpa = testing.allocator;
    var install = try installTree(gpa, false);
    defer install.deinit(gpa);

    // A command nobody has; a path that is neither of the two
    // extensions loom knows; and each of the three commands with the
    // file left off.  `edit` takes exactly one file, so two is refused
    // rather than half-obeyed.
    const wrong = [_][]const []const u8{
        &.{"polish"},
        &.{"notes.txt"},
        &.{"run"},
        &.{"luce"},
        &.{"edit"},
        &.{ "edit", "one.txt", "two.txt" },
    };
    for (wrong) |arguments| {
        var ran = try runLoom(gpa, &install, arguments, null, null);
        defer ran.deinit(gpa);
        try testing.expectEqual(@as(u8, 1), ran.status);
        try testing.expectEqualStrings("", ran.out);
        try testing.expect(ran.saysErr("usage:"));
        for ([_][]const u8{
            "loom run PROGRAM.lc",
            "loom luce PROGRAM.luc",
            "loom edit FILE",
        }) |form| {
            try testing.expect(ran.saysErr(form));
        }
    }
}

test "a file that is not there and a file that is not a program are different mistakes" {
    // The platform loader says only "no", never why, so loom makes the
    // one distinction that is worth anything to a person: a path that
    // does not exist is theirs to fix, and a file that exists and is
    // not a Luce program is a different problem entirely.
    const gpa = testing.allocator;
    var install = try installTree(gpa, false);
    defer install.deinit(gpa);
    try install.write("notes.lc", "this is not a shared library\n");
    try install.write("empty.lc", "");

    const absent = try install.at(gpa, "nowhere.lc");
    defer gpa.free(absent);
    var missing = try runLoom(gpa, &install, &.{ "run", absent }, null, null);
    defer missing.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), missing.status);
    try testing.expectEqualStrings("", missing.out);
    try testing.expect(missing.saysErr("no such file"));
    try testing.expect(missing.saysErr(absent));

    for ([_][]const u8{ "notes.lc", "empty.lc" }) |name| {
        const path = try install.at(gpa, name);
        defer gpa.free(path);
        var ran = try runLoom(gpa, &install, &.{ "run", path }, null, null);
        defer ran.deinit(gpa);
        try testing.expectEqual(@as(u8, 1), ran.status);
        try testing.expectEqualStrings("", ran.out);
        // And the answer is about the *file*, not the loader's opinion
        // of it: these are read before anything is asked to open them,
        // so what comes back names what is missing rather than
        // relaying a "no" from dyld.
        try testing.expect(ran.saysErr("it is not a compiled Luce artifact"));
    }

    // A source file that is not there says the same thing about
    // itself, before any compiler is looked for.
    const no_source = try install.at(gpa, "nowhere.luc");
    defer gpa.free(no_source);
    var unwritten = try runLoom(gpa, &install, &.{ "luce", no_source }, null, null);
    defer unwritten.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), unwritten.status);
    try testing.expect(unwritten.saysErr("no such file"));
}

test "how a program ended is the number a shell reads, whoever started it" {
    // The same table the standalone binary answers from
    // (`apps/host.zig`): 0 finished, 1 trapped, 3 ended on an uncaught
    // error.  A trap and an error are two different sentences about a
    // program, so a script can tell them apart without parsing stderr.
    const gpa = testing.allocator;
    var install = try installTree(gpa, true);
    defer install.deinit(gpa);

    const endings = [_]struct {
        name: []const u8,
        source: []const u8,
        status: u8,
        out: []const u8,
        says: []const u8,
    }{
        .{ .name = "fine", .source = greeting, .status = 0, .out = expected, .says = "" },
        .{
            .name = "stumble",
            .source =
            \\func main():
            \\    var xs = [1, 2, 3]
            \\    print("before")
            \\    print(string(xs[7]))
            \\
            ,
            .status = 1,
            .out = "before\n",
            .says = "loom: trap: index out of bounds [index_bounds]",
        },
        .{
            .name = "refuse",
            .source =
            \\func main() -> !:
            \\    print("before")
            \\    error("nothing doing")
            \\
            ,
            .status = 3,
            .out = "before\n",
            .says = "loom: error: nothing doing [user_error]",
        },
    };

    for (endings) |ending| {
        const source_name = try std.fmt.allocPrint(gpa, "{s}.luc", .{ending.name});
        defer gpa.free(source_name);
        try install.write(source_name, ending.source);
        const program = try install.at(gpa, source_name);
        defer gpa.free(program);

        var ran = try runLoom(gpa, &install, &.{ "luce", program }, null, null);
        defer ran.deinit(gpa);
        try testing.expectEqual(ending.status, ran.status);
        try testing.expectEqualStrings(ending.out, ran.out);
        if (ending.says.len == 0) {
            try testing.expectEqualStrings("", ran.err);
        } else {
            try testing.expect(ran.saysErr(ending.says));
        }
        try testing.expect(!ran.saysErr("escaped ownership"));
    }
}

test "the words after a program are the program's, not loom's" {
    const gpa = testing.allocator;
    var install = try installTree(gpa, true);
    defer install.deinit(gpa);
    try install.write("echo.luc",
        \\func main(args: list(string)):
        \\    print(string(len(args)))
        \\    for word in args:
        \\        print(word)
        \\
    );
    const program = try install.at(gpa, "echo.luc");
    defer gpa.free(program);

    // Through `luce`, through `run` on what that left behind, and
    // through the bare path — a program's behaviour must not depend on
    // which of the three the person typed.
    var compiled = try runLoom(gpa, &install, &.{ "luce", program, "alpha", "beta" }, null, null);
    defer compiled.deinit(gpa);
    try testing.expectEqualStrings("2\nalpha\nbeta\n", compiled.out);

    const artifact = try install.at(gpa, "echo.lc");
    defer gpa.free(artifact);
    var run_form = try runLoom(gpa, &install, &.{ "run", artifact, "alpha", "beta" }, null, null);
    defer run_form.deinit(gpa);
    try testing.expectEqualStrings("2\nalpha\nbeta\n", run_form.out);

    var bare = try runLoom(gpa, &install, &.{ artifact, "alpha", "beta" }, null, null);
    defer bare.deinit(gpa);
    try testing.expectEqualStrings("2\nalpha\nbeta\n", bare.out);

    // And loom's own words are not among them.
    var none = try runLoom(gpa, &install, &.{ "run", artifact }, null, null);
    defer none.deinit(gpa);
    try testing.expectEqualStrings("0\n", none.out);
}

// ---------------------------------------------------------------------------
// The shell, read from a pipe
// ---------------------------------------------------------------------------

test "a script piped into loom ends on the worst thing any line did" {
    // `echo "run boom.lc" | loom` in a build is the only thing that
    // will ever know a program failed, so the worst status any line
    // produced becomes loom's own.  The in-process tests beside
    // `shell.zig` prove the rule; this proves the *product* has it —
    // that the pipe really makes loom non-interactive, and that the
    // number reaches the shell.
    const gpa = testing.allocator;
    var install = try installTree(gpa, true);
    defer install.deinit(gpa);
    try install.write("sums.luc", greeting);
    const program = try install.at(gpa, "sums.luc");
    defer gpa.free(program);

    const good = try std.fmt.allocPrint(gpa, "help\nluce {s}\nexit\n", .{program});
    defer gpa.free(good);
    var clean = try runLoom(gpa, &install, &.{}, null, good);
    defer clean.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), clean.status);
    try testing.expect(clean.saysOut(expected));
    // No banner and no prompt: a pipe is not a person.
    try testing.expect(!clean.saysOut("\u{25b8}"));
    try testing.expect(!clean.saysOut("the luce environment"));

    // One failing line is the answer, even with good lines after it,
    // and even though the shell keeps going.
    const mixed = try std.fmt.allocPrint(
        gpa,
        "luce {s}\nrun no/such/program.lc\nluce {s}\n",
        .{ program, program },
    );
    defer gpa.free(mixed);
    var worst = try runLoom(gpa, &install, &.{}, null, mixed);
    defer worst.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), worst.status);
    try testing.expect(worst.saysErr("no such file"));
    // The lines after it still ran.
    try testing.expectEqualStrings(expected ++ expected, worst.out);

    // An uncaught error is a worse ending than a trap, and the worst
    // ending is what a script is told.
    try install.write("refuse.luc", "func main() -> !:\n    error(\"nothing doing\")\n");
    const refusing = try install.at(gpa, "refuse.luc");
    defer gpa.free(refusing);
    const raising = try std.fmt.allocPrint(
        gpa,
        "run no/such/program.lc\nluce {s}\n",
        .{refusing},
    );
    defer gpa.free(raising);
    var raised = try runLoom(gpa, &install, &.{}, null, raising);
    defer raised.deinit(gpa);
    try testing.expectEqual(@as(u8, 3), raised.status);
}

test "LOOM_EDITOR names the program edit runs, in place of the embedded one" {
    // The override is what lets a person keep their own editor, and it
    // is the one thing about `edit` that can be proved without a
    // terminal to draw on.
    const gpa = testing.allocator;
    var install = try installTree(gpa, true);
    defer install.deinit(gpa);
    try install.write("mine.luc",
        \\func main(args: list(string)):
        \\    print("editing " + args[0])
        \\
    );
    const editor = try install.at(gpa, "mine.luc");
    defer gpa.free(editor);

    var environment = try environmentWith(gpa, &.{.{ "LOOM_EDITOR", editor }});
    defer environment.deinit();

    var ran = try runLoom(gpa, &install, &.{ "edit", "notes.txt" }, &environment, null);
    defer ran.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), ran.status);
    try testing.expectEqualStrings("editing notes.txt\n", ran.out);

    // And through the shell, where `edit` is a command rather than a
    // command line.
    var piped = try runLoom(gpa, &install, &.{}, &environment, "edit other.txt\nexit\n");
    defer piped.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), piped.status);
    try testing.expect(piped.saysOut("editing other.txt\n"));
}

// ---------------------------------------------------------------------------
// What loom refuses to load
// ---------------------------------------------------------------------------
//
// A native artifact is not portable and its name cannot be trusted to
// say so, so every one carries a tag and a loader reads it — **out of
// the file's own bytes, before the file is loaded at all** — before a
// single instruction runs (`luce.llvm.artifact.Artifact`).  Seven ways
// an artifact can be wrong, seven sentences, and the sentences are the
// whole point: "no" tells a person nothing, and three of these name
// both sides, because the loader is one of them and is holding the
// other.
//
// These take a **real artifact** and change one field of its tag in
// the file, because that is what a stale, copied, or hand-edited `.lc`
// actually is.  `native.zig` proves the seven sentences differ from
// each other; this proves each one is what comes out of loom when the
// matching field is the one that is wrong.

/// Where each field of the tag sits, from `08_llvm/artifact.zig` —
/// whose own test holds these offsets against what the code generator
/// emits.
const tag = struct {
    const magic = 0;
    const source_hash = 8;
    const generator = 16;
    const format = 24;
    const abi_version = 28;
    const machine_length = 40;
};

/// Change one 64-bit field of an artifact's tag, in place.
///
/// The tag is found by its magic rather than by asking a loader where
/// it is: a test that used the loader to locate what it is about to
/// break would be leaning on the thing under test.
fn corrupt(
    gpa: Allocator,
    install: *const Install,
    name: []const u8,
    offset: usize,
    value: u64,
) !void {
    return change(gpa, install, name, offset, std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
}

/// The same for a 32-bit field.  Two functions rather than one with a
/// width, because half the tag is words and half is halves and a
/// caller that gets it wrong writes over the field *after* the one it
/// meant — which is exactly the kind of quiet wrongness these tests
/// exist to catch.
fn corruptHalf(
    gpa: Allocator,
    install: *const Install,
    name: []const u8,
    offset: usize,
    value: u32,
) !void {
    return change(gpa, install, name, offset, std.mem.toBytes(std.mem.nativeToLittle(u32, value)));
}

fn change(
    gpa: Allocator,
    install: *const Install,
    name: []const u8,
    offset: usize,
    written: anytype,
) !void {
    const bytes = try install.read(gpa, name);
    defer gpa.free(bytes);

    var magic_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &magic_bytes, luce.llvm.artifact.magic, .little);
    const at = std.mem.indexOf(u8, bytes, &magic_bytes) orelse return error.NoArtifactTag;
    @memcpy(bytes[at + offset ..][0..written.len], &written);

    try install.scratch.dir.writeFile(io, .{ .sub_path = name, .data = bytes });
    try resign(gpa, install, name);
}

/// Put a signature back on a file that was edited by hand.
///
/// Not part of what is being proved, and not something the shipped
/// code ever does: on Apple Silicon the kernel checks every Mach-O's
/// signature as it is mapped, so a byte changed here would have the
/// process killed before a loader read one field of the tag — which
/// would prove the platform's rule and none of Luce's.  Everywhere
/// else there is nothing to sign and nothing to do.
fn resign(gpa: Allocator, install: *const Install, name: []const u8) !void {
    if (!@import("builtin").os.tag.isDarwin()) return;
    const path = try install.at(gpa, name);
    defer gpa.free(path);
    var ran = try install.spawn(gpa, &.{ "codesign", "-f", "-s", "-", path }, .{});
    defer ran.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), ran.status);
}

test "an artifact whose tag is wrong in one field is refused by naming that field" {
    const gpa = testing.allocator;
    var install = try installTree(gpa, true);
    defer install.deinit(gpa);
    try install.write("sums.luc", greeting);

    const source = try install.at(gpa, "sums.luc");
    defer gpa.free(source);
    const artifact = try install.at(gpa, "sums.lc");
    defer gpa.free(artifact);
    var built = try runLuce(gpa, &install, &.{ "build", source });
    defer built.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), built.status);

    // The control: untouched, it runs.  Without this every case below
    // could be passing for the wrong reason.
    var whole = try runLoom(gpa, &install, &.{ "run", artifact }, null, null);
    defer whole.deinit(gpa);
    try testing.expectEqualStrings(expected, whole.out);

    // A byte-for-byte copy of the good artifact to restore from, so
    // each case starts from a working one and breaks exactly one
    // thing.
    const good = try install.read(gpa, "sums.lc");
    defer gpa.free(good);

    const machine = luce.llvm.artifact.machine;
    const shortened = machine[0 .. machine.len - 1];
    const refusals = [_]struct { offset: usize, value: u64, half: bool = false, says: []const u8 }{
        // No magic at the front: whatever this file is, no Luce
        // compiler wrote it.
        .{ .offset = tag.magic, .value = 0, .says = "it is not a compiled Luce artifact" },
        // A tag whose own shape this loader cannot read — the check
        // that has to come before every other one, because the fields
        // after it would be read at the wrong offsets.  It says which
        // layout it found and which one it reads, because "a layout
        // this loader cannot read" leaves a person nothing to act on.
        .{
            .offset = tag.format,
            .value = 99,
            .half = true,
            .says = std.fmt.comptimePrint(
                "its tag is layout version 99, and this loader reads version {d}",
                .{luce.llvm.artifact.format},
            ),
        },
        .{
            .offset = tag.abi_version,
            .value = 9999,
            .half = true,
            .says = std.fmt.comptimePrint(
                "it was built against host ABI 9999, and this loader speaks {d}",
                .{luce.llvm.abi.version},
            ),
        },
        // One character short of this machine's name is a different
        // machine's name — and the sentence names both, which is the
        // whole difference between a refusal and a shrug.
        .{
            .offset = tag.machine_length,
            .value = machine.len - 1,
            .half = true,
            .says = "it was built for " ++ shortened ++ ", and this machine is " ++ machine,
        },
        // A name longer than the room it lives in is not a foreign
        // machine, it is a tag nobody can reason from.
        .{
            .offset = tag.machine_length,
            .value = luce.llvm.artifact.machine_capacity + 1,
            .half = true,
            .says = "it is truncated, or its object file is damaged",
        },
        .{
            .offset = tag.generator,
            .value = ~luce.llvm.artifact.generator,
            .says = "it was built by a different code generator",
        },
    };

    for (refusals) |refusal| {
        try install.scratch.dir.writeFile(io, .{ .sub_path = "sums.lc", .data = good });
        try resign(gpa, &install, "sums.lc");
        if (refusal.half) {
            try corruptHalf(gpa, &install, "sums.lc", refusal.offset, @intCast(refusal.value));
        } else {
            try corrupt(gpa, &install, "sums.lc", refusal.offset, refusal.value);
        }

        var ran = try runLoom(gpa, &install, &.{ "run", artifact }, null, null);
        defer ran.deinit(gpa);
        try testing.expectEqual(@as(u8, 1), ran.status);
        // Nothing of the program ran: the tag is read first, and a
        // refusal that had already printed something would mean it
        // was not.
        try testing.expectEqualStrings("", ran.out);
        const sentence = try std.fmt.allocPrint(
            gpa,
            "loom: cannot run {s}: {s}\n",
            .{ artifact, refusal.says },
        );
        defer gpa.free(sentence);
        try testing.expectEqualStrings(sentence, ran.err);
    }
}

test "an artifact with a tag and no entry point is not an artifact" {
    // The one refusal that cannot be made by editing a field: a
    // library whose tag says everything right and which has no
    // `luce_main` to call.  It is what a half-linked object, or
    // something built against a future ABI that moved the entry, would
    // look like — and the loader must refuse it rather than call
    // whatever it does find.
    //
    // Written in C because that is the only way to say it: the tag has
    // to be the one this loader accepts, and the entry has to be
    // absent, and no Luce program compiles to that.
    const gpa = testing.allocator;
    var install = try installTree(gpa, false);
    defer install.deinit(gpa);

    const artifact = luce.llvm.artifact;
    const abi = luce.llvm.abi;
    const source = try std.fmt.allocPrint(gpa,
        \\#include <stdint.h>
        \\
        \\struct LuceArtifact {{
        \\    uint64_t magic;
        \\    uint64_t source_hash;
        \\    uint64_t generator;
        \\    uint32_t format;
        \\    uint32_t abi_version;
        \\    int32_t debug;
        \\    int32_t reserved;
        \\    uint32_t machine_length;
        \\    char machine[{d}];
        \\}};
        \\
        \\const struct LuceArtifact luce_artifact
        \\    __attribute__((section("{s}"))) = {{
        \\    {d}ULL, 0ULL, {d}ULL,
        \\    {d}U, {d}U, 1, 0,
        \\    {d}U, "{s}"
        \\}};
        \\
    , .{
        artifact.machine_capacity,
        if (@import("builtin").os.tag.isDarwin())
            artifact.section.mach
        else
            artifact.section.elf,
        artifact.magic,
        artifact.generator,
        artifact.format,
        abi.version,
        artifact.machine.len,
        artifact.machine,
    });
    defer gpa.free(source);
    try install.write("hollow.c", source);

    const c_path = try install.at(gpa, "hollow.c");
    defer gpa.free(c_path);
    const hollow = try install.at(gpa, "hollow.lc");
    defer gpa.free(hollow);
    var compiled = try install.spawn(gpa, &.{ "cc", "-shared", "-o", hollow, c_path }, .{});
    defer compiled.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), compiled.status);

    var ran = try runLoom(gpa, &install, &.{ "run", hollow }, null, null);
    defer ran.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), ran.status);
    try testing.expectEqualStrings("", ran.out);
    const sentence = try std.fmt.allocPrint(
        gpa,
        "loom: cannot run {s}: it is not a compiled Luce artifact\n",
        .{hollow},
    );
    defer gpa.free(sentence);
    try testing.expectEqualStrings(sentence, ran.err);
}

test "a truncated artifact is refused by name, wherever it was cut" {
    // A file cut short by a full disk, an interrupted copy, or a
    // half-finished download.  **This is the row that used to be a
    // macOS-only premise**: it read "refused by the platform", and the
    // platform is not the same everywhere — dyld declines to open such
    // a file, while a Linux loader opens one cut anywhere from a
    // quarter of the way to nearly all of it and *runs* it, or maps a
    // segment past the end of the file and takes a SIGBUS on the first
    // touch of that page.  Neither of those is an answer about the
    // file.
    //
    // So the tag is read out of the file's bytes first, and reading it
    // means walking the container's headers, and a header describing
    // bytes the file does not have is what "truncated" *is*.  Six cuts,
    // spread across the file so that some fall before the tag and some
    // after it: every one is one sentence, on every platform, and the
    // loader is never handed the file at all.
    const gpa = testing.allocator;
    var install = try installTree(gpa, true);
    defer install.deinit(gpa);
    try install.write("sums.luc", greeting);

    const source = try install.at(gpa, "sums.luc");
    defer gpa.free(source);
    var built = try runLuce(gpa, &install, &.{ "build", source });
    defer built.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), built.status);

    const whole = try install.read(gpa, "sums.lc");
    defer gpa.free(whole);
    try testing.expect(whole.len > 64);

    const cut = try install.at(gpa, "cut.lc");
    defer gpa.free(cut);
    const sentence = try std.fmt.allocPrint(
        gpa,
        "loom: cannot run {s}: it is truncated, or its object file is damaged\n",
        .{cut},
    );
    defer gpa.free(sentence);

    for ([_]usize{ 10, 25, 50, 75, 90, 99 }) |part| {
        try install.scratch.dir.writeFile(io, .{
            .sub_path = "cut.lc",
            .data = whole[0 .. whole.len * part / 100],
        });
        // Deliberately not re-signed: nothing signs a half-copied
        // file, and nothing here loads one either.

        var ran = try runLoom(gpa, &install, &.{ "run", cut }, null, null);
        defer ran.deinit(gpa);
        try testing.expectEqual(@as(u8, 1), ran.status);
        try testing.expectEqualStrings("", ran.out);
        try testing.expectEqualStrings(sentence, ran.err);
    }
}

test "an artifact built from another program is rebuilt, and said so when it cannot be" {
    // The sixth refusal is the one that is normally invisible, because
    // it is the cache working: an artifact whose `source_hash` is not
    // this program's is not an error, it is a miss, and loom compiles
    // over it.  What makes the sentence reachable at all is a compiler
    // that reports success and hands back an artifact for a *different*
    // program — which is what a stale build rule, or a mixed-up `-o`,
    // really does.
    const gpa = testing.allocator;

    // First: a stale artifact beside a source is quietly rebuilt.
    {
        var install = try installTree(gpa, true);
        defer install.deinit(gpa);
        try install.write("sums.luc", greeting);
        const source = try install.at(gpa, "sums.luc");
        defer gpa.free(source);
        var built = try runLuce(gpa, &install, &.{ "build", source });
        defer built.deinit(gpa);
        try testing.expectEqual(@as(u8, 0), built.status);

        try corrupt(gpa, &install, "sums.lc", tag.source_hash, 0xdeadbeef);
        var ran = try runLoom(gpa, &install, &.{ "luce", source }, null, null);
        defer ran.deinit(gpa);
        try testing.expectEqualStrings("", ran.err);
        try testing.expectEqualStrings(expected, ran.out);
        try testing.expectEqual(@as(u8, 0), ran.status);
        // And what is beside the program now is this program's.
        var warm = try runLoom(gpa, &install, &.{ "luce", source }, null, null);
        defer warm.deinit(gpa);
        try testing.expectEqualStrings(expected, warm.out);
    }

    // Then: a compiler that succeeds and produces the wrong artifact.
    {
        var install = try installTree(gpa, true);
        defer install.deinit(gpa);
        try install.write("other.luc", "func main():\n    print(\"other\")\n");
        const other_source = try install.at(gpa, "other.luc");
        defer gpa.free(other_source);
        var built = try runLuce(gpa, &install, &.{ "build", other_source });
        defer built.deinit(gpa);
        try testing.expectEqual(@as(u8, 0), built.status);

        try install.write("sums.luc", greeting);
        const other = try install.at(gpa, "other.lc");
        defer gpa.free(other);
        try plantCopyingCompiler(&install, gpa, other);

        const source = try install.at(gpa, "sums.luc");
        defer gpa.free(source);
        // The real environment, minus where temporary artifacts go:
        // the stand-in has to run `cp`, and a PATH holding only the
        // install tree has no `cp` on it.
        var environment = try environmentWith(gpa, &.{.{ "TMPDIR", install.root }});
        defer environment.deinit();

        var ran = try runLoom(gpa, &install, &.{ "luce", source }, &environment, null);
        defer ran.deinit(gpa);
        try testing.expectEqual(@as(u8, 1), ran.status);
        try testing.expectEqualStrings("", ran.out);
        // Not "the compiler failed" — it did not.  What is wrong is
        // the artifact, and the sentence says which way.
        try testing.expect(ran.saysErr("the program it was built from has changed"));
        // And nothing of the wrong program was run.
        try testing.expect(!ran.saysOut("other"));
    }
}
