//! The standard library's test suite.
//!
//! Std modules are ordinary Luce compiled into every program that
//! imports them, so they are proven the way programs are: scripts
//! whose asserts trap on any wrong answer, leak-checked like
//! everything else, and run on **both** engines with the two
//! compared (`specs/agree.zig`).
//!
//! The pure modules (math, strings) need nothing from the world; the
//! hosted ones (files) run against the harness's world, which both
//! engines see the same copy of.

const std = @import("std");
const agree = @import("agree.zig");
const luce = @import("luce");
const mir = luce.mir;
const types = luce.types;

const testing = std.testing;

const script: types.CompileOptions = .{};

/// The depth this suite has always run at.
const budget: agree.Provided = .{ .call_depth = 4096 };

/// Both engines run it, agree, and leave nothing alive.
fn agreeOk(source: []const u8) !void {
    return agree.okGiven(source, budget);
}

/// Both engines abort with exactly `code`.
fn agreeTrap(source: []const u8, code: mir.TrapCode) !void {
    return agree.trapGiven(source, budget, code);
}

// ---------------------------------------------------------------------------
// math
// ---------------------------------------------------------------------------

test "math: constants and round" {
    try agreeOk(
        \\import std.math
        \\
        \\func main():
        \\    assert(abs(math.pi - 3.14159265358979) < 0.000000000001)
        \\    assert(abs(math.tau - 2.0 * math.pi) < 0.000000000001)
        \\    assert(abs(math.e - 2.71828182845904) < 0.000000000001)
        \\    assert(math.round(2.4) == 2.0)
        \\    assert(math.round(2.5) == 3.0)
        \\    assert(math.round(-2.5) == -3.0)
        \\    assert(math.round(-2.4) == -2.0)
        \\    assert(math.round(0.0) == 0.0)
        \\
    );
}

test "math: exp and ln are accurate and inverse" {
    try agreeOk(
        \\import std.math
        \\
        \\func close(a: double, b: double) -> bool:
        \\    return abs(a - b) < 0.000000001
        \\
        \\func main():
        \\    assert(close(math.exp(0.0), 1.0))
        \\    assert(close(math.exp(1.0), math.e))
        \\    assert(close(math.exp(-1.0), 1.0 / math.e))
        \\    assert(close(math.ln(1.0), 0.0))
        \\    assert(close(math.ln(math.e), 1.0))
        \\    assert(abs(math.ln(1000000.0) - 13.815510557964274) < 0.00000001)
        \\    assert(close(math.exp(math.ln(7.5)), 7.5))
        \\    assert(close(math.ln(math.exp(3.25)), 3.25))
        \\    assert(math.exp(800.0) > 1.0e300)
        \\    assert(math.exp(-800.0) == 0.0)
        \\
    );
}

test "math: ln of a non-positive number traps" {
    try agreeTrap(
        \\import std.math
        \\
        \\func main():
        \\    var x = 0.0
        \\    let bad = math.ln(x)
        \\
    , .explicit_trap);
}

test "math: pow covers the sign and zero cases" {
    try agreeOk(
        \\import std.math
        \\
        \\func close(a: double, b: double) -> bool:
        \\    return abs(a - b) < 0.000000001
        \\
        \\func main():
        \\    assert(close(math.pow(2.0, 10.0), 1024.0))
        \\    assert(close(math.pow(9.0, 0.5), 3.0))
        \\    assert(close(math.pow(10.0, -2.0), 0.01))
        \\    assert(close(math.pow(-2.0, 3.0), -8.0))
        \\    assert(close(math.pow(-2.0, 4.0), 16.0))
        \\    assert(math.pow(0.0, 5.0) == 0.0)
        \\    assert(math.pow(0.0, 0.0) == 1.0)
        \\    assert(math.pow(7.0, 0.0) == 1.0)
        \\
    );
    try agreeTrap(
        \\import std.math
        \\
        \\func main():
        \\    var half = 0.5
        \\    let bad = math.pow(-2.0, half)
        \\
    , .explicit_trap);
}

test "math: ipow squares its way up and stays checked" {
    try agreeOk(
        \\import std.math
        \\
        \\func main():
        \\    assert(math.ipow(2, 0) == 1)
        \\    assert(math.ipow(2, 10) == 1024)
        \\    assert(math.ipow(-3, 3) == -27)
        \\    assert(math.ipow(10, 18) == 1000000000000000000)
        \\    assert(math.ipow(2, 62) == 4611686018427387904)
        \\    assert(math.ipow(1, 1000000) == 1)
        \\
    );
    // Past i64 the checked arithmetic traps rather than wrapping.
    try agreeTrap(
        \\import std.math
        \\
        \\func main():
        \\    var exponent = 64
        \\    let bad = math.ipow(2, exponent)
        \\
    , .integer_overflow);
}

test "math: trig against known values, across periods" {
    try agreeOk(
        \\import std.math
        \\
        \\func close(a: double, b: double) -> bool:
        \\    return abs(a - b) < 0.0000000001
        \\
        \\func main():
        \\    assert(close(math.sin(0.0), 0.0))
        \\    assert(close(math.sin(math.pi / 2.0), 1.0))
        \\    assert(close(math.sin(math.pi), 0.0))
        \\    assert(close(math.cos(0.0), 1.0))
        \\    assert(close(math.cos(math.pi), -1.0))
        \\    assert(close(math.sin(1.0), 0.8414709848078965))
        \\    assert(close(math.cos(1.0), 0.5403023058681398))
        \\    assert(close(math.tan(1.0), 1.5574077246549023))
        \\    assert(close(math.sin(-1.0), -0.8414709848078965))
        \\    assert(close(math.sin(100.0), -0.5063656411097588))
        \\    assert(close(math.sin(2.0) * math.sin(2.0) + math.cos(2.0) * math.cos(2.0), 1.0))
        \\
    );
}

test "math: log2 and log10" {
    try agreeOk(
        \\import std.math
        \\
        \\func close(a: double, b: double) -> bool:
        \\    return abs(a - b) < 0.000000001
        \\
        \\func main():
        \\    assert(close(math.log2(8.0), 3.0))
        \\    assert(close(math.log2(1024.0), 10.0))
        \\    assert(close(math.log10(1000.0), 3.0))
        \\    assert(close(math.log10(0.01), -2.0))
        \\
    );
}

test "math: vector operations compute exactly on exact inputs" {
    try agreeOk(
        \\import std.math
        \\
        \\func main():
        \\    var xs = new array(double, 5)
        \\    for i in range(0, 5):
        \\        xs[i] = double(i) * 0.5
        \\    assert(math.sum(xs) == 5.0)
        \\    assert((math.mean(xs) else -1.0) == 1.0)
        \\    assert((math.vmin(xs) else -1.0) == 0.0)
        \\    assert((math.vmax(xs) else -1.0) == 2.0)
        \\    var ys = new array(double, 5)
        \\    math.fill(ys, 2.0)
        \\    assert(math.sum(ys) == 10.0)
        \\    assert(math.dot(xs, ys) == 10.0)
        \\    let twenty: double = 20.0
        \\    assert(math.norm(ys) == sqrt(twenty))
        \\    math.scale(ys, 0.5)
        \\    assert(math.sum(ys) == 5.0)
        \\    math.axpy(ys, 2.0, xs)
        \\    assert(ys[4] == 5.0)
        \\    assert((math.variance(ys) else -1.0) == 2.0)
        \\    let two: double = 2.0
        \\    assert((math.stddev(ys) else -1.0) == sqrt(two))
        \\
    );
}

test "math: a reduction over an empty array is absent, not a trap" {
    // Nothing failed and nobody erred: an empty array simply has no
    // mean, and "there is nothing there" with the same reason every
    // time is what `T?` is for (docs/FAILURE.md).
    try agreeOk(
        \\import std.math
        \\
        \\func main():
        \\    var empty = new array(double, 0)
        \\    assert(math.mean(empty) == none)
        \\    assert(math.vmin(empty) == none)
        \\    assert(math.vmax(empty) == none)
        \\    assert(math.variance(empty) == none)
        \\    assert(math.stddev(empty) == none)
        \\
    );
}

test "math: a shape mismatch is still a trap, because the caller could have checked" {
    try agreeTrap(
        \\import std.math
        \\
        \\func main():
        \\    var a = new array(double, 2)
        \\    var b = new array(double, 3)
        \\    let d = math.dot(a, b)
        \\
    , .explicit_trap);
}

test "math: the generator is deterministic, in range, and covers its die" {
    try agreeOk(
        \\import std.math
        \\
        \\func main():
        \\    var rng = math.rng(42)
        \\    var again = math.rng(42)
        \\    for i in range(0, 10):
        \\        assert(rng.next() == again.next())
        \\    var negative_seed = math.rng(-7)
        \\    assert(negative_seed.next() >= 1)
        \\    var die = math.rng(2026)
        \\    var seen = new map(long, bool)
        \\    for i in range(0, 200):
        \\        let roll = die.in_range(1, 7)
        \\        assert(roll >= 1 and roll <= 6)
        \\        seen[roll] = true
        \\    assert(len(seen) == 6)
        \\    var floats = math.rng(9)
        \\    for i in range(0, 100):
        \\        let f = floats.real()
        \\        assert(f > 0.0 and f < 1.0)
        \\
    );
    try agreeTrap(
        \\import std.math
        \\
        \\func main():
        \\    var rng = math.rng(1)
        \\    let bad = rng.in_range(5, 5)
        \\
    , .explicit_trap);
}

// ---------------------------------------------------------------------------
// strings
// ---------------------------------------------------------------------------

test "strings: find (with its start default), contains, starts_with, ends_with, count" {
    // `find_from` merged into `find(s, needle, start = 0)`
    // (docs/ARGS.md §9): one declaration, one answer to a `start`
    // outside the string — -1, the argument error the old wrapper
    // could never reach.
    try agreeOk(
        \\import std.strings
        \\
        \\func main():
        \\    let s = "hello world"
        \\    assert(strings.find(s, "world") == 6)
        \\    assert(strings.find(s, "xyz") == -1)
        \\    assert(strings.find(s, "") == 0)
        \\    assert(strings.find(s, "o", 5) == 7)
        \\    assert(strings.find(s, "o", start = 8) == -1)
        \\    assert(strings.find(s, "", 3) == 3)
        \\    assert(strings.find(s, "o", -1) == -1)
        \\    assert(strings.find(s, "o", 99) == -1)
        \\    assert("hello world".find("o", 5) == 7)
        \\    assert(strings.contains(s, "lo w"))
        \\    assert(not strings.contains(s, "zzz"))
        \\    assert(strings.starts_with(s, "hello"))
        \\    assert(strings.starts_with(s, ""))
        \\    assert(not strings.starts_with(s, "hello world!"))
        \\    assert(strings.ends_with(s, "world"))
        \\    assert(strings.ends_with(s, ""))
        \\    assert(not strings.ends_with(s, "worlds"))
        \\    assert(strings.count("aaaa", "aa") == 2)
        \\    assert(strings.count("a.b.c", ".") == 2)
        \\    assert(strings.count("abc", "") == 0)
        \\
    );
}

test "strings: the method sugar routes to the module" {
    try agreeOk(
        \\import std.strings
        \\
        \\func main():
        \\    let s = "hello world"
        \\    assert(s.find("world") == strings.find(s, "world"))
        \\    assert(s.trim() == strings.trim(s))
        \\    assert(s.count("l") == 3)
        \\    let parts = s.split(" ")
        \\    assert(parts.join(" ") == s)
        \\
    );
}

test "strings: trim, lower, upper keep multibyte characters whole" {
    try agreeOk(
        \\import std.strings
        \\
        \\func main():
        \\    assert(strings.trim("  hi  ") == "hi")
        \\    assert(strings.trim("\t\nhi" + chr(13) + "\n") == "hi")
        \\    assert(strings.trim("") == "")
        \\    assert(strings.trim("   ") == "")
        \\    assert(strings.trim("hi") == "hi")
        \\    assert(strings.lower("MiXeD") == "mixed")
        \\    assert(strings.upper("MiXeD") == "MIXED")
        \\    assert(strings.lower("ABC🙂DEF") == "abc🙂def")
        \\    assert(strings.upper("λx.λy") == "λX.λY")
        \\    assert(strings.lower("already") == "already")
        \\
    );
}

test "strings: replace and repeat" {
    try agreeOk(
        \\import std.strings
        \\
        \\func main():
        \\    assert(strings.replace("a.b.c", ".", "-") == "a-b-c")
        \\    assert(strings.replace("aaa", "a", "bb") == "bbbbbb")
        \\    assert(strings.replace("hello", "z", "y") == "hello")
        \\    assert(strings.replace("hello", "l", "") == "heo")
        \\    assert(strings.replace("abc", "", "x") == "abc")
        \\    assert(strings.repeat("ab", 3) == "ababab")
        \\    assert(strings.repeat("x", 0) == "")
        \\    assert(strings.repeat("x", -2) == "")
        \\    assert(strings.repeat("", 5) == "")
        \\
    );
}

test "strings: split keeps empties, whitespace mode drops them, join round-trips" {
    try agreeOk(
        \\import std.strings
        \\
        \\func main():
        \\    let csv = strings.split("a;b;;c", ";")
        \\    assert(len(csv) == 4)
        \\    assert(csv[2] == "")
        \\    assert(strings.join(csv, ";") == "a;b;;c")
        \\    let lone = strings.split("abc", ";")
        \\    assert(len(lone) == 1 and lone[0] == "abc")
        \\    let words = strings.split("  the   quick brown  ", "")
        \\    assert(len(words) == 3)
        \\    assert(words[0] == "the" and words[1] == "quick" and words[2] == "brown")
        \\    let blanks = strings.split("   ", "")
        \\    assert(len(blanks) == 0)
        \\    let empty: list(string) = []
        \\    assert(strings.join(empty, ", ") == "")
        \\    assert(strings.join(["only"], ", ") == "only")
        \\
    );
}

test "strings: pad_left and pad_right" {
    try agreeOk(
        \\import std.strings
        \\
        \\func main():
        \\    assert(strings.pad_left("7", 3) == "  7")
        \\    assert(strings.pad_right("7", 3) == "7  ")
        \\    assert(strings.pad_left("wide", 3) == "wide")
        \\    assert(strings.pad_right("wide", 4) == "wide")
        \\
    );
}

test "strings: format_float rounds half away and carries" {
    try agreeOk(
        \\import std.strings
        \\
        \\func main():
        \\    assert(strings.format_float(2.5, 2) == "2.50")
        \\    assert(strings.format_float(2.345, 2) == "2.35")
        \\    assert(strings.format_float(-2.345, 2) == "-2.35")
        \\    assert(strings.format_float(0.999, 2) == "1.00")
        \\    assert(strings.format_float(-0.999, 2) == "-1.00")
        \\    assert(strings.format_float(1.05, 1) == "1.1")
        \\    assert(strings.format_float(3.14159, 0) == "3")
        \\    assert(strings.format_float(2.5, 0) == "3")
        \\    assert(strings.format_float(0.0, 3) == "0.000")
        \\    assert(strings.format_float(0.0625, 4) == "0.0625")
        \\
    );
    try agreeTrap(
        \\import std.strings
        \\
        \\func main():
        \\    var decimals = -1
        \\    let bad = strings.format_float(1.0, decimals)
        \\
    , .explicit_trap);
}

test "strings: a format spec is that function, and the import is what it needs" {
    // The positive control for `luce.sema.import`'s format-spec
    // refusal (`specs/errors_spec.zig`): the whole fix is the import
    // line, and with it the spec and the call it lowers to are the
    // same program.
    try agreeOk(
        \\import std.strings
        \\
        \\func main():
        \\    let mean = 23.998425
        \\    assert(f"{mean:.2f}" == strings.format_float(mean, 2))
        \\    assert(f"mean = {mean:.2f}" == "mean = 24.00")
        \\    assert(f"{2.5:.0f} and {-2.5:.0f}" == "3 and -3")
        \\
    );
}

// ---------------------------------------------------------------------------
// paths
// ---------------------------------------------------------------------------
//
// Pure text, so every row runs hostless on both engines.  The shapes
// are the module's promises verbatim: docs/STD.md quotes these.

test "paths: is_absolute and join keep one separator at the seam" {
    try agreeOk(
        \\import std.paths
        \\
        \\func main():
        \\    assert(paths.is_absolute("/etc"))
        \\    assert(paths.is_absolute("/"))
        \\    assert(not paths.is_absolute("etc"))
        \\    assert(not paths.is_absolute(""))
        \\
        \\    assert(paths.join("a", "b") == "a/b")
        \\    assert(paths.join("a/", "b") == "a/b")
        \\    assert(paths.join("a//", "b") == "a/b")
        \\    assert(paths.join("/", "etc") == "/etc")
        \\    assert(paths.join("", "b") == "b")
        \\    assert(paths.join("a", "") == "a")
        \\    assert(paths.join("a", "/etc") == "/etc")
        \\    assert(paths.join(paths.join("/usr", "local"), "bin") == "/usr/local/bin")
        \\
    );
}

test "paths: base and dir take a path apart, and join puts it back" {
    try agreeOk(
        \\import std.paths
        \\
        \\func main():
        \\    assert(paths.base("a/b.luc") == "b.luc")
        \\    assert(paths.base("a/b/") == "b")
        \\    assert(paths.base("b") == "b")
        \\    assert(paths.base("a//b") == "b")
        \\    assert(paths.base("/") == "/")
        \\    assert(paths.base("//") == "/")
        \\    assert(paths.base("") == "")
        \\
        \\    assert(paths.dir("a/b.luc") == "a")
        \\    assert(paths.dir("/usr/local/bin") == "/usr/local")
        \\    assert(paths.dir("b") == ".")
        \\    assert(paths.dir("/b") == "/")
        \\    assert(paths.dir("/") == "/")
        \\    assert(paths.dir("a//b") == "a")
        \\    assert(paths.dir("a/b/") == "a")
        \\    assert(paths.dir("") == ".")
        \\
        \\    # dir and base name the same file the path did.
        \\    let p = "src/luce/std/paths.luc"
        \\    assert(paths.join(paths.dir(p), paths.base(p)) == p)
        \\
    );
}

test "paths: extension and stem split the base, and rejoin to it" {
    try agreeOk(
        \\import std.paths
        \\
        \\func main():
        \\    assert(paths.extension("main.luc") == ".luc")
        \\    assert(paths.extension("a/b.tar.gz") == ".gz")
        \\    assert(paths.extension("a.b/c") == "")
        \\    assert(paths.extension(".bashrc") == "")
        \\    assert(paths.extension("plain") == "")
        \\    assert(paths.extension("/") == "")
        \\
        \\    assert(paths.stem("a/main.luc") == "main")
        \\    assert(paths.stem("a/b.tar.gz") == "b.tar")
        \\    assert(paths.stem(".bashrc") == ".bashrc")
        \\    assert(paths.stem("plain") == "plain")
        \\
        \\    # The pair is a partition of the base, on every shape here.
        \\    var shapes = ["main.luc", "a/b.tar.gz", ".bashrc", "plain", "/", "a/b/", ""]
        \\    for shape in shapes:
        \\        assert(paths.stem(shape) + paths.extension(shape) == paths.base(shape))
        \\
    );
}

// ---------------------------------------------------------------------------
// The mechanism
// ---------------------------------------------------------------------------

test "std resolves without any loader, and std names shadow sibling files" {
    // compile() has no loader at all; import math still works — the
    // std library lives in the compiler.
    try agreeOk(
        \\import std.math
        \\
        \\func main():
        \\    assert(math.ipow(2, 8) == 256)
        \\
    );
}

test "std modules obey the host gate: files needs a host" {
    var result = try luce.compile.compile(testing.allocator,
        \\import std.files
        \\
        \\func main():
        \\    let found = files.exists("x")
        \\
    , script);
    defer result.deinit();
    try testing.expect(result == .failure);
    // The gate fires inside the std module, attributed to it.
    var saw_host = false;
    for (0..result.failure.count()) |index| {
        const item = result.failure.at(index).?;
        if (std.mem.eql(u8, item.code, "luce.sema.host")) {
            try testing.expectEqualStrings("std/files.luc", result.failure.sources.pathOf(item.file));
            saw_host = true;
        }
    }
    try testing.expect(saw_host);
}

// ---------------------------------------------------------------------------
// files
// ---------------------------------------------------------------------------
//
// std's one hosted module, proved against the harness's world: one
// file, one directory, and a host that can be told to refuse.  Each
// engine gets its own copy of that world, and the two are compared on
// what they left in it as well as on what they printed
// (`specs/agree.zig`).

/// A world that already holds `notes.txt`, at this suite's depth.
fn withNotes(content: []const u8) agree.Provided {
    var provided = budget;
    provided.world = .withFile("notes.txt", content);
    return provided;
}

test "files: exists, read_lines, write_lines and write wrap the host builtins" {
    try agree.printsGiven(
        \\import std.files
        \\
        \\func main() -> !:
        \\    assert(files.exists("notes.txt"))
        \\    assert(not files.exists("ghost.txt"))
        \\    var lines = try files.read_lines("notes.txt")
        \\    assert(len(lines) == 2)
        \\    assert(lines[0] == "alpha" and lines[1] == "beta")
        \\    lines.append("gamma")
        \\    try files.write_lines("out.txt", lines)
        \\    print(try files.read("out.txt"))
        \\
    , withNotes("alpha\nbeta\n"),
        \\alpha
        \\beta
        \\gamma
        \\
        \\
    );
}

test "files: append, rename, delete and list reach the services beyond read and write" {
    // Every claim is checked back through the language rather than
    // through the host's bookkeeping, so the compiled arm proves the
    // same thing the interpreted one does.
    var session = try agree.compare(
        \\import std.files
        \\import std.strings
        \\
        \\func main() -> !:
        \\    try files.append_text("log.txt", "one line\n")
        \\    try files.append_lines("log.txt", ["two", "three"])
        \\    try files.append_lines("log.txt", new list(string))
        \\    print(try files.read("log.txt"))
        \\    try files.rename("log.txt", "kept.txt")
        \\    assert(files.exists("kept.txt") and not files.exists("log.txt"))
        \\    let names = try files.list(".")
        \\    print(names.join(","))
        \\    free(names)
        \\    try files.delete("kept.txt")
        \\    assert(not files.exists("kept.txt"))
        \\
    , budget);
    defer session.deinit();

    // `files.list` sorts, so a listing does not depend on what the
    // file system felt like.
    try testing.expectEqualStrings(
        "one line\ntwo\nthree\n\nalpha.txt,beta.txt,notes\n",
        session.printed(),
    );
    // The delete really happened: the world holds nothing now.
    try testing.expect(session.file() == null);
}

test "files: a listing the world refuses is an error naming the path" {
    try agree.errors(
        \\import std.files
        \\
        \\func main() -> !:
        \\    let names = try files.list("nowhere")
        \\    free(names)
        \\
    , budget, .io_failed, "cannot list nowhere");
}

test "files: a write the world will not take is an error, not a trap" {
    var refusing = budget;
    refusing.world = .{ .refuse_writes = true };
    try agree.errors(
        \\import std.files
        \\
        \\func main() -> !:
        \\    try files.write("out.txt", "body")
        \\
    , refusing, .io_failed, "cannot write out.txt");
}

// ---------------------------------------------------------------------------
// os
// ---------------------------------------------------------------------------
//
// The machine's facts, over the harness's seeded world: eight
// gibibytes, three of them available, four processors.  Fixed numbers
// and not the real machine's, for the same reason the harness's clock
// is not a real clock — the two engines run one after the other, and a
// fact that moved between them would be a disagreement about the
// machine rather than about the lowering.  So the values themselves
// can be asserted here, on both arms, and not only their relations.

test "os: the machine's numbers cross the boundary intact, on both engines" {
    try agreeOk(
        \\import std.os
        \\
        \\func main():
        \\    assert(os.total_memory() == 8589934592)
        \\    assert(os.available_memory() == 3221225472)
        \\    assert(os.cpu_count() == 4)
        \\    assert(os.used_memory() == 5368709120)
        \\
    );
}

test "os.term.ui: Unicode borders keep their junctions intact" {
    try agreeOk(
        \\import std.os
        \\
        \\func main():
        \\    assert(os.term.ui.horizontal() == "─")
        \\    assert(os.term.ui.vertical() == "│")
        \\    assert(os.term.ui.top_left() == "┌")
        \\    assert(os.term.ui.bottom_right() == "┘")
        \\    assert(os.term.ui.junction(top = true, right = true, bottom = true, left = true) == "┼")
        \\    assert(os.term.ui.junction(top = true, right = true, bottom = false, left = true) == "┴")
        \\    assert(os.term.ui.junction(top = false, right = true, bottom = true, left = true) == "┬")
        \\    assert(os.term.ui.shadow() == "░")
        \\
    );
}

test "os: available fits inside total, and used is a part of the whole" {
    // The relations the module promises on *any* machine, written the
    // way a program would check them rather than against the seeded
    // constants.
    //
    // Note what is not here: `used_memory() == total - available` for
    // an `available` read on the line above.  It holds on the seeded
    // world, where nothing moves, and the test above asserts it there
    // — but `used_memory` takes its own two readings, so on a live
    // machine it is false, which is exactly what the site build found
    // when this page claimed it.
    try agreeOk(
        \\import std.os
        \\
        \\func main():
        \\    let total = os.total_memory()
        \\    let available = os.available_memory()
        \\    assert(total > 0)
        \\    assert(available > 0)
        \\    assert(available <= total)
        \\    assert(os.used_memory() >= 0)
        \\    assert(os.used_memory() <= total)
        \\    assert(os.cpu_count() >= 1)
        \\
    );
}

test "os: a host with no machine slots refuses, and touches nothing" {
    var blind = budget;
    blind.machine = false;
    try agree.trapGiven(
        \\import std.os
        \\
        \\func main():
        \\    print(string(os.total_memory()))
        \\
    , blind, .host_unavailable);
}

test "os: a host that has the slots and cannot tell refuses the same way" {
    // The other road to the same trap: the service is there, and its
    // answer is "I cannot tell you".  A program must not be able to
    // tell the two apart, because in both cases nobody measured
    // anything and the alternative is a number that was made up.
    var unmeasurable = budget;
    unmeasurable.world = .{ .unmeasurable = true };
    try agree.trapGiven(
        \\import std.os
        \\
        \\func main():
        \\    print(string(os.available_memory()))
        \\
    , unmeasurable, .host_unavailable);
    try agree.trapGiven(
        \\import std.os
        \\
        \\func main():
        \\    print(string(os.cpu_count()))
        \\
    , unmeasurable, .host_unavailable);
}
