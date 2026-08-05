//! The compiler at its command line, and the binary it writes.
//!
//! `main.zig`'s tests prove the pieces; these prove the *tool* — the
//! thing a person types and a build system calls.  What a command line
//! costs when it is wrong is the whole of what this file is about: an
//! exit status a `make` rule reads, a sentence on standard error, an
//! artifact that is either there or is not.  None of that can be
//! reached from inside the process, because it is the process: the
//! statuses are `main`'s return value, the usage text is what a caller
//! meets before anything is compiled, and `--emit=exe` produces a file
//! whose whole behaviour is `apps/start.zig` running in a process of
//! its own.
//!
//! So these build a miniature install tree in a temporary directory —
//! `luce` at the root and the two static libraries under `lib/`, which
//! is the layout `zig build --prefix` produces and the one
//! `native.discover` looks for — and use it exactly as a person would.
//! `apps/loom/product.zig` does the same for the pair.
//!
//! Every stream is a real file rather than a pipe.  A pipe that fills
//! while the parent is draining the other one deadlocks, and nothing
//! here should have to know which of a program's two channels talks
//! first; a file also makes standard input something a test can simply
//! write, which is how `luce check -` gets proved.

const std = @import("std");
const build_options = @import("build_options");
const harness = @import("harness");

const testing = std.testing;
const io = std.testing.io;
const Allocator = std.mem.Allocator;
const Install = harness.Install;
const Ran = harness.Ran;

// ---------------------------------------------------------------------------
// A miniature install tree
// ---------------------------------------------------------------------------

/// `luce` at the root and the two static libraries under `lib/`, which
/// is the layout `zig build --prefix` produces and the one
/// `native.discover` looks for.  The tree itself and the way to run
/// what is in it are `apps/harness.zig`'s, shared with the pair's
/// suite; what goes into this one is this suite's.
fn installTree(gpa: Allocator) !Install {
    var tree = try Install.make(gpa);
    errdefer tree.deinit(gpa);
    try tree.place(build_options.luce_binary, "luce");
    try tree.place(build_options.luce_rt_library, "lib/libluce_rt.a");
    try tree.place(build_options.luce_start_library, "lib/libluce_start.a");
    return tree;
}

/// Run the installed compiler, optionally with `input` on its standard
/// input.
fn runLuce(
    gpa: Allocator,
    tree: *const Install,
    arguments: []const []const u8,
    input: ?[]const u8,
) !Ran {
    const compiler = try tree.at(gpa, "luce");
    defer gpa.free(compiler);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, compiler);
    try argv.appendSlice(gpa, arguments);
    return tree.spawn(gpa, argv.items, .{ .input = input });
}

const greeting =
    \\func main():
    \\    print("total " + string(3 * 10))
    \\
;

// ---------------------------------------------------------------------------
// Saying no
// ---------------------------------------------------------------------------

test "a command line with nothing to do prints usage and fails" {
    const gpa = testing.allocator;
    var tree = try installTree(gpa);
    defer tree.deinit(gpa);

    // No arguments at all, a command that does not exist, and a
    // command with no file: all the same answer, because they are all
    // "there is nothing here to compile".
    const empty_handed = [_][]const []const u8{
        &.{},
        &.{"polish"},
        &.{"build"},
        &.{"check"},
        &.{"ir"},
    };
    for (empty_handed) |arguments| {
        var ran = try runLuce(gpa, &tree, arguments, null);
        defer ran.deinit(gpa);
        try testing.expectEqual(@as(u8, 1), ran.status);
        try testing.expectEqualStrings("", ran.out);
        try testing.expect(ran.saysErr("usage:"));
        // Usage that does not name a command is usage that hides one.
        for ([_][]const u8{ "luce build", "luce check", "luce ir" }) |form| {
            try testing.expect(ran.saysErr(form));
        }
    }
}

test "an option written twice, or one nobody has, is refused rather than resolved" {
    // Silently taking the last `-o` puts the artifact somewhere the
    // caller is not looking and reports success; silently taking the
    // last `--emit` writes a file of the wrong shape and reports
    // success.  Both are failures a build system cannot see, so
    // neither is resolved.
    const gpa = testing.allocator;
    var tree = try installTree(gpa);
    defer tree.deinit(gpa);
    try tree.write("sums.luc", greeting);
    const program = try tree.at(gpa, "sums.luc");
    defer gpa.free(program);

    // Absolute, so that "nothing was written" is a claim about
    // somewhere this test can look.  A relative `-o two.lc` lands in
    // whatever directory the test runner happens to be in, and the
    // check below would pass without ever having been true.
    const one = try tree.at(gpa, "one.lc");
    defer gpa.free(one);
    const two = try tree.at(gpa, "two.lc");
    defer gpa.free(two);

    const refusals = [_]struct { arguments: []const []const u8, says: []const u8 }{
        .{ .arguments = &.{ "-o", one, "-o", two }, .says = "-o was given twice" },
        .{ .arguments = &.{ "--release", "--release" }, .says = "--release was given twice" },
        .{
            .arguments = &.{ "--emit=exe", "--emit=object" },
            .says = "--emit was given twice",
        },
        .{ .arguments = &.{"--emit=wasm"}, .says = "--emit=wasm is not one of library, object, exe" },
        .{ .arguments = &.{"--fast"}, .says = "--fast is not an option build takes" },
        .{ .arguments = &.{"-o"}, .says = "-o needs a path after it" },
    };
    for (refusals) |refusal| {
        var arguments: std.ArrayList([]const u8) = .empty;
        defer arguments.deinit(gpa);
        try arguments.appendSlice(gpa, &.{ "build", program });
        try arguments.appendSlice(gpa, refusal.arguments);

        var ran = try runLuce(gpa, &tree, arguments.items, null);
        defer ran.deinit(gpa);
        try testing.expectEqual(@as(u8, 1), ran.status);
        try testing.expectEqualStrings("", ran.out);
        try testing.expect(ran.saysErr(refusal.says));
        // And nothing was written under either name it was given.
        try testing.expect(!tree.exists("sums.lc"));
        try testing.expect(!tree.exists("one.lc"));
        try testing.expect(!tree.exists("two.lc"));
    }

    // The other two commands take no options at all, and say so.
    var checked = try runLuce(gpa, &tree, &.{ "check", program, "--full" }, null);
    defer checked.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), checked.status);
    try testing.expect(checked.saysErr("check takes one file"));

    var dumped = try runLuce(gpa, &tree, &.{ "ir", program, "--half" }, null);
    defer dumped.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), dumped.status);
    try testing.expect(dumped.saysErr("ir takes one file"));
}

// ---------------------------------------------------------------------------
// check and ir
// ---------------------------------------------------------------------------

test "check compiles, reports, and writes nothing" {
    const gpa = testing.allocator;
    var tree = try installTree(gpa);
    defer tree.deinit(gpa);
    try tree.write("sums.luc", greeting);
    // A path with a directory in it, because a diagnostic that says
    // `sums.luc:2:5` names a file the reader still has to find — and
    // there may be three of them.
    try tree.write("sub/broken.luc",
        \\func main():
        \\    let count: long = "seven"
        \\    print(string(count))
        \\
    );

    const program = try tree.at(gpa, "sums.luc");
    defer gpa.free(program);
    var good = try runLuce(gpa, &tree, &.{ "check", program }, null);
    defer good.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), good.status);
    try testing.expectEqualStrings("", good.err);
    try testing.expect(good.saysOut(": ok\n"));
    try testing.expect(good.saysOut(program));
    // Checking is not building: nothing landed beside the source.
    try testing.expect(!tree.exists("sums.lc"));

    const broken = try tree.at(gpa, "sub/broken.luc");
    defer gpa.free(broken);
    var refused = try runLuce(gpa, &tree, &.{ "check", broken }, null);
    defer refused.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), refused.status);
    try testing.expectEqualStrings("", refused.out);
    try testing.expect(refused.saysErr("compile failed"));
    // The path as it was written, the position, and the stable code —
    // the three things an editor and a person both need.
    try testing.expect(refused.saysErr(broken));
    try testing.expect(refused.saysErr(":2:5:"));
    try testing.expect(refused.saysErr("[luce.sema.type]"));

    const absent = try tree.at(gpa, "nowhere.luc");
    defer gpa.free(absent);
    var missing = try runLuce(gpa, &tree, &.{ "check", absent }, null);
    defer missing.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), missing.status);
    try testing.expect(missing.saysErr("no such file"));
    try testing.expect(missing.saysErr(absent));
}

test "ir prints the program, and --full keeps what the entry never reaches" {
    // Pruning is what makes an unused std import cost nothing to ship,
    // so `luce ir` shows the program as it will be compiled.  `--full`
    // is the other question — what does this *file* say — and is how a
    // module under inspection gets looked at at all.
    const gpa = testing.allocator;
    var tree = try installTree(gpa);
    defer tree.deinit(gpa);
    try tree.write("shape.luc",
        \\func unreached() -> long:
        \\    return 7
        \\
        \\func main():
        \\    print("here")
        \\
    );
    const program = try tree.at(gpa, "shape.luc");
    defer gpa.free(program);

    var pruned = try runLuce(gpa, &tree, &.{ "ir", program }, null);
    defer pruned.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), pruned.status);
    try testing.expectEqualStrings("", pruned.err);
    try testing.expect(pruned.saysOut("func main()"));
    try testing.expect(!pruned.saysOut("unreached"));

    var whole = try runLuce(gpa, &tree, &.{ "ir", program, "--full" }, null);
    defer whole.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), whole.status);
    try testing.expect(whole.saysOut("func main()"));
    try testing.expect(whole.saysOut("func unreached()"));

    // Reading is not building here either.
    try testing.expect(!tree.exists("shape.lc"));

    // A program that does not compile has no IR to print.
    try tree.write("broken.luc", "func main():\n    let x: long = \"s\"\n    print(string(x))\n");
    const broken = try tree.at(gpa, "broken.luc");
    defer gpa.free(broken);
    var failed = try runLuce(gpa, &tree, &.{ "ir", broken }, null);
    defer failed.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), failed.status);
    try testing.expectEqualStrings("", failed.out);
    try testing.expect(failed.saysErr("compile failed"));
}

test "a program may arrive on standard input, and is named for what it is" {
    // `luce check <(generate)` and `luce check -` are table stakes for
    // an editor, and a stream has no name to put in a diagnostic — so
    // it gets one, and it is not a dash.
    const gpa = testing.allocator;
    var tree = try installTree(gpa);
    defer tree.deinit(gpa);

    var checked = try runLuce(gpa, &tree, &.{ "check", "-" }, greeting);
    defer checked.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), checked.status);
    try testing.expectEqualStrings("<stdin>: ok\n", checked.out);

    var dumped = try runLuce(gpa, &tree, &.{ "ir", "-" }, greeting);
    defer dumped.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), dumped.status);
    try testing.expect(dumped.saysOut("func main()"));

    var complained = try runLuce(
        gpa,
        &tree,
        &.{ "check", "-" },
        "func main():\n    let x: long = \"s\"\n    print(string(x))\n",
    );
    defer complained.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), complained.status);
    try testing.expect(complained.saysErr("<stdin>:2:5:"));

    // A stream has no name to derive an output path from, so building
    // one says so rather than writing a file called `-.lc`.
    var nameless = try runLuce(gpa, &tree, &.{ "build", "-" }, greeting);
    defer nameless.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), nameless.status);
    try testing.expect(nameless.saysErr("needs -o to say where to write"));
    try testing.expect(!tree.exists("-.lc"));

    const target = try tree.at(gpa, "streamed.lc");
    defer gpa.free(target);
    var built = try runLuce(gpa, &tree, &.{ "build", "-", "-o", target }, greeting);
    defer built.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), built.status);
    try testing.expect(built.saysOut("<stdin> -> "));
    try testing.expect(tree.exists("streamed.lc"));
}

// ---------------------------------------------------------------------------
// The three shapes
// ---------------------------------------------------------------------------

test "each --emit shape writes what it says, and the object links into a program that runs" {
    // The default and `--emit=library` are the same request said two
    // ways; `--emit=exe` is a file a shell can run; and `--emit=object`
    // is the one nothing had ever built, which is the shape whose
    // whole promise is that somebody *else* links it.  So this links
    // it — by hand, with `cc`, over the two installed libraries, which
    // is exactly what `--emit=exe` does internally and exactly what an
    // embedder would type.
    const gpa = testing.allocator;
    var tree = try installTree(gpa);
    defer tree.deinit(gpa);
    try tree.write("sums.luc", greeting);
    const program = try tree.at(gpa, "sums.luc");
    defer gpa.free(program);

    // The default: FILE.luc -> FILE.lc, and one line saying so.
    var implied = try runLuce(gpa, &tree, &.{ "build", program }, null);
    defer implied.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), implied.status);
    try testing.expectEqualStrings("", implied.err);
    try testing.expect(implied.saysOut("sums.luc -> "));
    try testing.expect(implied.saysOut("sums.lc"));
    try testing.expect(tree.exists("sums.lc"));

    // Said out loud, it is the same request.
    try tree.scratch.dir.deleteFile(io, "sums.lc");
    var named = try runLuce(gpa, &tree, &.{ "build", program, "--emit=library" }, null);
    defer named.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), named.status);
    try testing.expect(tree.exists("sums.lc"));

    // An object: FILE.luc -> FILE.o, and nothing that runs yet.
    var relocatable = try runLuce(gpa, &tree, &.{ "build", program, "--emit=object" }, null);
    defer relocatable.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), relocatable.status);
    try testing.expect(relocatable.saysOut("sums.o"));
    try testing.expect(tree.exists("sums.o"));

    // Linked by hand, exactly as the documentation says to: the
    // program's object, `main`, and the semantics.
    const object = try tree.at(gpa, "sums.o");
    defer gpa.free(object);
    const start = try tree.at(gpa, "lib/libluce_start.a");
    defer gpa.free(start);
    const runtime = try tree.at(gpa, "lib/libluce_rt.a");
    defer gpa.free(runtime);
    const linked = try tree.at(gpa, "byhand");
    defer gpa.free(linked);
    var link = try tree.spawn(gpa, &.{ "cc", "-o", linked, object, start, runtime }, .{});
    defer link.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), link.status);

    var byhand = try tree.spawn(gpa, &.{linked}, .{});
    defer byhand.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), byhand.status);
    try testing.expectEqualStrings("total 30\n", byhand.out);

    // And the shape that does that linking itself: a bare name, and a
    // file a shell runs.
    var executable = try runLuce(gpa, &tree, &.{ "build", program, "--emit=exe" }, null);
    defer executable.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), executable.status);
    try testing.expect(executable.saysOut("sums.luc -> "));
    try testing.expect(tree.exists("sums"));

    const standalone = try tree.at(gpa, "sums");
    defer gpa.free(standalone);
    var ran = try tree.spawn(gpa, &.{standalone}, .{});
    defer ran.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), ran.status);
    try testing.expectEqualStrings("total 30\n", ran.out);
    try testing.expectEqualStrings("", ran.err);

    // `-o` names the file whatever the shape, and the extension rule
    // does not get a say.
    const elsewhere = try tree.at(gpa, "chosen.bin");
    defer gpa.free(elsewhere);
    var placed = try runLuce(gpa, &tree, &.{ "build", program, "-o", elsewhere, "--emit=exe" }, null);
    defer placed.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), placed.status);
    try testing.expect(tree.exists("chosen.bin"));
}

// ---------------------------------------------------------------------------
// The two modes, and how a run ends
// ---------------------------------------------------------------------------

const stumbles =
    \\func at(xs: list(long), index: long) -> long:
    \\    return xs[index]
    \\
    \\func main():
    \\    var xs: list(long) = [1, 2, 3]
    \\    print("before")
    \\    print(string(at(xs, 7)))
    \\
;

test "a debug artifact says where it trapped; a release one says what trapped" {
    // The CLI half of docs/MODES.md.  `--release` has exactly one
    // meaning — the artifact carries no origins — and the way to see
    // it is a program that stops: debug names `file:line:column` for
    // every frame, release names the functions and no positions.  Both
    // print the same output, trap at the same call, and exit with the
    // same number, because the mode is not allowed to change the
    // program.
    const gpa = testing.allocator;
    var tree = try installTree(gpa);
    defer tree.deinit(gpa);
    try tree.write("stumble.luc", stumbles);
    const program = try tree.at(gpa, "stumble.luc");
    defer gpa.free(program);

    const debug_path = try tree.at(gpa, "debug");
    defer gpa.free(debug_path);
    var debug_build = try runLuce(gpa, &tree, &.{ "build", program, "--emit=exe", "-o", debug_path }, null);
    defer debug_build.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), debug_build.status);

    const release_path = try tree.at(gpa, "release");
    defer gpa.free(release_path);
    var release_build = try runLuce(
        gpa,
        &tree,
        &.{ "build", program, "--emit=exe", "-o", release_path, "--release" },
        null,
    );
    defer release_build.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), release_build.status);

    var debug_ran = try tree.spawn(gpa, &.{debug_path}, .{});
    defer debug_ran.deinit(gpa);
    var release_ran = try tree.spawn(gpa, &.{release_path}, .{});
    defer release_ran.deinit(gpa);

    // Same program, so: same output, same trap, same status.
    try testing.expectEqualStrings("before\n", debug_ran.out);
    try testing.expectEqualStrings("before\n", release_ran.out);
    try testing.expectEqual(@as(u8, 1), debug_ran.status);
    try testing.expectEqual(@as(u8, 1), release_ran.status);
    for ([_]*const Ran{ &debug_ran, &release_ran }) |ran| {
        try testing.expect(ran.saysErr("trap: index out of bounds [index_bounds]"));
        // Both name the calls, innermost first.
        try testing.expect(ran.saysErr("at at"));
        try testing.expect(ran.saysErr("at main"));
    }

    // The difference, and the only one: debug carries positions.
    try testing.expect(debug_ran.saysErr("stumble.luc:2:5"));
    try testing.expect(debug_ran.saysErr("stumble.luc:7:5"));
    // Release carries none — no source name, no line, not one.
    try testing.expect(!release_ran.saysErr("stumble.luc"));
    try testing.expect(!release_ran.saysErr("("));

    // What is deliberately *not* asserted here: that the release file
    // is smaller.  It is not, at this level — the two executables come
    // out byte-for-byte the same length, because an origin table this
    // small disappears into the segment alignment a linker rounds
    // every Mach-O and ELF section up to, and what is left is mostly
    // libluce_rt either way.  Whether the tables actually left the
    // *artifact* is a question about the artifact, and belongs to a
    // test that reads one; from out here the trap report is the whole
    // of the observable difference, which is exactly the promise
    // docs/MODES.md makes.
}

test "the standalone binary answers 0 for finished, 1 for a trap, 3 for an uncaught error" {
    // `apps/start.zig` is a whole product with no process of its own
    // to be tested in: it is the `main` a compiled program becomes an
    // executable with, and everything it does — checking the tag it
    // was linked against, running, restoring the screen, reporting,
    // scoring — happens between a shell's `exec` and its `$?`.
    //
    // A trap and an uncaught error are two different sentences about a
    // program (docs/FAILURE.md), so they are two different numbers,
    // and a script can tell them apart without parsing stderr.
    const gpa = testing.allocator;
    var tree = try installTree(gpa);
    defer tree.deinit(gpa);

    const endings = [_]struct {
        name: []const u8,
        source: []const u8,
        status: u8,
        out: []const u8,
        says: []const u8,
    }{
        .{
            .name = "fine",
            .source = greeting,
            .status = 0,
            .out = "total 30\n",
            .says = "",
        },
        .{
            .name = "stumble",
            .source = stumbles,
            .status = 1,
            .out = "before\n",
            .says = "luce: trap: index out of bounds [index_bounds]",
        },
        .{
            .name = "refuse",
            .source =
            \\func check(value: long) -> long!:
            \\    if value < 0:
            \\        error(f"negative: {value}")
            \\    return value
            \\
            \\func main() -> !:
            \\    print(string(try check(1)))
            \\    print(string(try check(-5)))
            \\
            ,
            .status = 3,
            .out = "1\n",
            .says = "luce: error: negative: -5 [user_error]",
        },
    };

    for (endings) |ending| {
        const source_name = try std.fmt.allocPrint(gpa, "{s}.luc", .{ending.name});
        defer gpa.free(source_name);
        try tree.write(source_name, ending.source);
        const program = try tree.at(gpa, source_name);
        defer gpa.free(program);

        var built = try runLuce(gpa, &tree, &.{ "build", program, "--emit=exe" }, null);
        defer built.deinit(gpa);
        try testing.expectEqual(@as(u8, 0), built.status);

        const binary = try tree.at(gpa, ending.name);
        defer gpa.free(binary);
        var ran = try tree.spawn(gpa, &.{binary}, .{});
        defer ran.deinit(gpa);
        try testing.expectEqual(ending.status, ran.status);
        try testing.expectEqualStrings(ending.out, ran.out);
        if (ending.says.len == 0) {
            try testing.expectEqualStrings("", ran.err);
        } else {
            try testing.expect(ran.saysErr(ending.says));
        }
        // Nothing ever escaped ownership: that report is an engine
        // bug, and it must not appear on any of these three paths.
        try testing.expect(!ran.saysErr("escaped ownership"));
    }
}

test "a standalone binary reads the arguments it was given, past its own name" {
    // `args[0]` is the first thing the person typed after the program,
    // which is what `loom run PROGRAM a b` gives too — a program's
    // behaviour must not depend on who started it (OWNERSHIP.md S44).
    const gpa = testing.allocator;
    var tree = try installTree(gpa);
    defer tree.deinit(gpa);
    try tree.write("echo.luc",
        \\func main(args: list(string)):
        \\    print(string(len(args)))
        \\    for word in args:
        \\        print(word)
        \\
    );
    const program = try tree.at(gpa, "echo.luc");
    defer gpa.free(program);
    var built = try runLuce(gpa, &tree, &.{ "build", program, "--emit=exe" }, null);
    defer built.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), built.status);

    const binary = try tree.at(gpa, "echo");
    defer gpa.free(binary);
    var bare = try tree.spawn(gpa, &.{binary}, .{});
    defer bare.deinit(gpa);
    try testing.expectEqualStrings("0\n", bare.out);

    var given = try tree.spawn(gpa, &.{ binary, "alpha", "beta" }, .{});
    defer given.deinit(gpa);
    try testing.expectEqualStrings("2\nalpha\nbeta\n", given.out);
}
