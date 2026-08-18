//! The standard library's test suite.
//!
//! Std modules are ordinary Luce compiled into every program that
//! imports them, so they are proven the way programs are: scripts
//! whose asserts trap on any wrong answer, leak-checked like
//! everything else, and run on **both** engines with the two
//! compared (`specs/agree.zig`).
//!
//! The pure modules (math, lists, strings, paths) need nothing from the
//! world; the hosted ones (files, os, term) run against the harness's world,
//! which both engines see the same copy of.  JSON and ZIP have larger
//! format-specific files of their own, but `test-stdlib` gives all three
//! files one owner and one focused lane.

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
// gpu and ui
// ---------------------------------------------------------------------------

test "gpu and ui: the public types compose without a host" {
    // Importing the modules and naming their types is deliberately a
    // host-free check.  A package can describe a window/surface in a
    // platform-neutral way even when it has not opened one yet.
    try agreeOk(
        \\import std.gpu
        \\import std.ui
        \\
        \\func main():
        \\    let backend: gpu.Backend = gpu.Backend.headless
        \\    assert(backend == gpu.Backend.headless)
        \\
    );
}

test "gpu and ui: an unavailable native host fails closed" {
    // The portable test host intentionally installs no graphics callbacks.
    // Opening a window must therefore be the same explicit
    // `host_unavailable` refusal on the oracle and compiled engines.
    var unavailable = budget;
    unavailable.files = false;
    try agree.trapGiven(
        \\import std.ui
        \\
        \\func main() -> !:
        \\    let window = try new ui.Window("test", 320, 240)
        \\    let surface = try window.surface()
        \\    try surface.present()
        \\
    , unavailable, .host_unavailable);
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
        \\func close(a: f64, b: f64) -> bool:
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
        \\func close(a: f64, b: f64) -> bool:
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
        \\    var exponent = 0.5
        \\    let bad = math.pow(-2.0, exponent)
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
        \\func close(a: f64, b: f64) -> bool:
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
        \\    assert(close(math.sin(10000.0), -0.30561438888825215))
        \\    assert(close(math.cos(10000.0), -0.9521553682590148))
        \\    assert(close(math.sin(2.0) * math.sin(2.0) + math.cos(2.0) * math.cos(2.0), 1.0))
        \\
    );
}

test "math: trig refuses angles outside its accuracy domain" {
    try agreeTrap(
        \\import std.math
        \\
        \\func main():
        \\    let wrong = math.sin(1000000.0)
        \\
    , .explicit_trap);
    try agreeTrap(
        \\import std.math
        \\
        \\func main():
        \\    let wrong = math.cos(-1000000.0)
        \\
    , .explicit_trap);
    try agreeTrap(
        \\import std.math
        \\
        \\func main():
        \\    let wrong = math.tan(1000000.0)
        \\
    , .explicit_trap);
}

test "math: log2 and log10" {
    try agreeOk(
        \\import std.math
        \\
        \\func close(a: f64, b: f64) -> bool:
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
        \\    var xs = new array[f64](5)
        \\    for i in range(0, 5):
        \\        xs[i] = f64(i) * 0.5
        \\    assert(math.sum(xs) == 5.0)
        \\    assert((math.mean(xs) else -1.0) == 1.0)
        \\    assert((math.vmin(xs) else -1.0) == 0.0)
        \\    assert((math.vmax(xs) else -1.0) == 2.0)
        \\    var ys = new array[f64](5)
        \\    math.fill(ys, 2.0)
        \\    assert(math.sum(ys) == 10.0)
        \\    assert(math.dot(xs, ys) == 10.0)
        \\    let twenty: f64 = 20.0
        \\    assert(math.norm(ys) == sqrt(twenty))
        \\    math.scale(ys, 0.5)
        \\    assert(math.sum(ys) == 5.0)
        \\    math.axpy(ys, 2.0, xs)
        \\    assert(ys[4] == 5.0)
        \\    assert((math.variance(ys) else -1.0) == 2.0)
        \\    let two: f64 = 2.0
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
        \\    var empty = new array[f64](0)
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
        \\    var a = new array[f64](2)
        \\    var b = new array[f64](3)
        \\    let d = math.dot(a, b)
        \\
    , .explicit_trap);
}

test "math: the generator is deterministic, in range, and covers its die" {
    try agreeOk(
        \\import std.math
        \\
        \\func main():
        \\    var rng = new math.Rng(42)
        \\    var again = new math.Rng(42)
        \\    for i in range(0, 10):
        \\        assert(rng.next() == again.next())
        \\    var negative_seed = new math.Rng(-7)
        \\    assert(negative_seed.next() >= 1)
        \\    var die = new math.Rng(2026)
        \\    var seen = new map[i64, bool]
        \\    for i in range(0, 200):
        \\        let roll = die.in_range(1, 7)
        \\        assert(roll >= 1 and roll <= 6)
        \\        seen[roll] = true
        \\    assert(len(seen) == 6)
        \\    var floats = new math.Rng(9)
        \\    for i in range(0, 100):
        \\        let f = floats.real()
        \\        assert(f > 0.0 and f < 1.0)
        \\
    );
    try agreeTrap(
        \\import std.math
        \\
        \\func main():
        \\    var rng = new math.Rng(1)
        \\    let bad = rng.in_range(5, 5)
        \\
    , .explicit_trap);
}

// ---------------------------------------------------------------------------
// lists
// ---------------------------------------------------------------------------
// `sort_by` is docs/FUNCTIONS.md D6's proving standard-library customer:
// callbacks exercise the language mechanism, while ordering, stability, and
// moving the elements are promises made by std.lists and therefore live here.

test "lists: sort_by specializes for a struct and accepts a lambda" {
    try agreeOk(
        \\import std.lists
        \\
        \\struct Player:
        \\    score: i64
        \\    order: i64
        \\
        \\func by_score(a: Player, b: Player) -> bool:
        \\    return a.score < b.score
        \\
        \\func main():
        \\    var empty = new list[Player]
        \\    empty.sort_by(by_score)
        \\    assert(len(empty) == 0)
        \\    var one = [Player(score = 7, order = 9)]
        \\    one.sort_by(by_score)
        \\    assert(one[0].order == 9)
        \\    var players = [
        \\        Player(score = 20, order = 0),
        \\        Player(score = 10, order = 1),
        \\        Player(score = 20, order = 2),
        \\        Player(score = 30, order = 3),
        \\    ]
        \\    players.sort_by(by_score)
        \\    assert(players[0].score == 10)
        \\    assert(players[1].score == 20)
        \\    assert(players[1].order == 0)
        \\    assert(players[2].score == 20)
        \\    assert(players[2].order == 2)
        \\    assert(players[3].score == 30)
        \\    players.sort_by((a, b) -> a.score > b.score)
        \\    assert(players[0].score == 30)
        \\    assert(players[1].score == 20)
        \\    assert(players[1].order == 0)
        \\    assert(players[2].score == 20)
        \\    assert(players[2].order == 2)
        \\    assert(players[3].score == 10)
        \\    var numbers: list[i64] = [3, 1, 2]
        \\    numbers.sort_by((a, b) -> a < b)
        \\    assert(numbers[0] == 1)
        \\    assert(numbers[1] == 2)
        \\    assert(numbers[2] == 3)
        \\
    );
}

test "lists: sort_by moves object elements without copying them" {
    try agreeOk(
        \\import std.lists
        \\
        \\func row_before(a: list[i64], b: list[i64]) -> bool:
        \\    return a[0] < b[0]
        \\
        \\func main():
        \\    var rows = new list[list[i64]]
        \\    rows.append([3])
        \\    rows.append([1])
        \\    rows.append([2])
        \\    rows.sort_by(row_before)
        \\    assert(rows[0][0] == 1)
        \\    assert(rows[1][0] == 2)
        \\    assert(rows[2][0] == 3)
        \\
    );
}

test "lists: sort_by moves task resources and keeps equivalent elements stable" {
    try agree.printsGiven(
        \\import std.lists
        \\
        \\func answer(n: i64) -> i64:
        \\    return n
        \\
        \\func equivalent(a: task[i64], b: task[i64]) -> bool:
        \\    return false
        \\
        \\func main():
        \\    var tasks = new list[task[i64]]
        \\    tasks.append(spawn answer(1))
        \\    tasks.append(spawn answer(2))
        \\    tasks.sort_by(equivalent)
        \\    var joined: i64 = 0
        \\    for work in tasks:
        \\        joined = joined * 10 + work.wait()
        \\    print(str(joined))
        \\
    , budget, "12\n");
}

// ---------------------------------------------------------------------------
// strings
// ---------------------------------------------------------------------------

test "strings: find (with its start default), contains, starts_with, ends_with, count" {
    // `find_from` merged into `find(s, needle, start = 0)`
    // (docs/ARGS.md §9): one declaration, one answer to a `start`
    // outside the string — absence, like a match that never comes;
    // `find(...) else -1` is how a caller who wants the sentinel
    // spells it.
    try agreeOk(
        \\import std.strings
        \\
        \\func main():
        \\    let s = "hello world"
        \\    assert((strings.find(s, "world") else -1) == 6)
        \\    assert(strings.find(s, "xyz") == none)
        \\    assert((strings.find(s, "") else -1) == 0)
        \\    assert((strings.find(s, "o", 5) else -1) == 7)
        \\    assert(strings.find(s, "o", start = 8) == none)
        \\    assert((strings.find(s, "", 3) else -1) == 3)
        \\    assert(strings.find(s, "o", -1) == none)
        \\    assert(strings.find(s, "o", 99) == none)
        \\    assert(("hello world".find("o", 5) else -1) == 7)
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
        \\    assert(strings.count("abc", "") == 4)
        \\    assert((strings.find("aé🙂b", "🙂") else -1) == 2)
        \\    assert((strings.find("aé🙂b", "b", 2) else -1) == 3)
        \\
    );
}

test "strings: the ASCII character classes answer char values" {
    try agreeOk(
        \\import std.strings
        \\
        \\func main():
        \\    let s = "aZ3 _\té"
        \\    assert(strings.is_lower(s[0]))
        \\    assert(not strings.is_upper(s[0]))
        \\    assert(strings.is_upper(s[1]))
        \\    assert(strings.is_alpha(s[0]) and strings.is_alpha(s[1]))
        \\    assert(strings.is_digit(s[2]))
        \\    assert(not strings.is_alpha(s[2]))
        \\    assert(strings.is_alnum(s[0]) and strings.is_alnum(s[2]))
        \\    assert(strings.is_space(s[3]))
        \\    assert(strings.is_space(s[5]))
        \\    assert(not strings.is_alnum(s[4]))
        \\    assert(not strings.is_space(s[4]))
        \\    # The helpers are deliberately ASCII-only.
        \\    assert(not strings.is_alpha(s[6]))
        \\    assert(not strings.is_alnum(s[6]))
        \\
    );
}

test "strings: the method sugar routes to the module" {
    try agreeOk(
        \\import std.strings
        \\
        \\func main():
        \\    let s = "hello world"
        \\    assert((s.find("world") else -1) == (strings.find(s, "world") else -2))
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
        \\    assert(strings.trim("\t\nhi" + str(char(13)) + "\n") == "hi")
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
        \\    let empty: list[str] = []
        \\    assert(strings.join(empty, ", ") == "")
        \\    assert(strings.join(["only"], ", ") == "only")
        \\
    );
}

test "strings: len and character helpers count Unicode scalars" {
    try agreeOk(
        \\import std.strings
        \\
        \\func main():
        \\    let mixed = "aé日🙂"
        \\    assert(len(mixed) == 4)
        \\    assert(len(bytes(mixed)) == 1 + 2 + 3 + 4)
        \\    assert(strings.width(mixed) == 4)
        \\    let parts = strings.characters(mixed)
        \\    assert(len(parts) == 4)
        \\    assert(parts[0] == "a" and parts[1] == "é")
        \\    assert(parts[2] == "日" and parts[3] == "🙂")
        \\    assert(strings.join(parts, "") == mixed)
        \\    assert(strings.width("ascii") == len("ascii"))
        \\    assert(strings.width("") == 0)
        \\    assert(len(strings.characters("")) == 0)
        \\    assert(strings.width(mixed) == len(strings.characters(mixed)))
        \\
    );
    // The named v0.1 limitation, pinned so that landing a width table
    // is a visible change and not a silent one (docs/TERMUI.md D11):
    // a wide character is one cell here, and a combining mark is a
    // cell of its own.
    try agreeOk(
        \\import std.strings
        \\
        \\func main():
        \\    assert(strings.width("日本") == 2)
        \\    assert(strings.width("e" + str(char(769))) == 2)
        \\
    );
}

test "strings: take cuts on a character boundary, at the end, and below zero" {
    try agreeOk(
        \\import std.strings
        \\
        \\func main():
        \\    let word = "héllo"
        \\    assert(len(word) == 5)
        \\    # The boundary case: two scalars occupy three UTF-8 bytes.
        \\    assert(strings.take(word, 2) == "hé")
        \\    assert(len(bytes(strings.take(word, 2))) == 3)
        \\    assert(strings.take(word, 1) == "h")
        \\    assert(strings.take(word, 5) == word)
        \\    # Past the end is the whole str, not a trap.
        \\    assert(strings.take(word, 99) == word)
        \\    assert(strings.take(word, 0) == "")
        \\    assert(strings.take(word, -4) == "")
        \\    assert(strings.take("", 4) == "")
        \\    assert(strings.width(strings.take(word, 3)) == 3)
        \\
    );
}

test "strings: pad_left and pad_right pad by cells, and ASCII is unchanged" {
    // The regression guard.  Every ASCII answer this module has ever
    // given is byte-counted and cell-counted at once, which is what
    // makes counting cells a correction rather than a break.
    try agreeOk(
        \\import std.strings
        \\
        \\func main():
        \\    assert(strings.pad_left("7", 3) == "  7")
        \\    assert(strings.pad_right("7", 3) == "7  ")
        \\    assert(strings.pad_left("wide", 3) == "wide")
        \\    assert(strings.pad_right("wide", 4) == "wide")
        \\    assert(strings.pad_left("", 2) == "  ")
        \\    assert(strings.pad_right("x", -1) == "x")
        \\
    );
    // And the bug D11 named: `é` is two bytes and one column, so the
    // byte-counted pad dropped a space at every non-ASCII label and
    // the column stopped lining up.
    try agreeOk(
        \\import std.strings
        \\
        \\func main():
        \\    assert(strings.pad_left("é", 3) == "  é")
        \\    assert(strings.pad_right("é", 3) == "é  ")
        \\    assert(strings.pad_left("naïve", 6) == " naïve")
        \\    assert(strings.pad_left("🙂", 2) == " 🙂")
        \\    assert(len(strings.pad_left("naïve", 6)) == 6)
        \\    assert(len(bytes(strings.pad_left("naïve", 6))) == 7)
        \\
    );
}

test "strings: malformed UTF-8 remains binary and parses as absent" {
    try agreeOk(
        \\import std.strings
        \\
        \\func main():
        \\    var invalid: list[u8] = [u8(0x61), u8(0x80), u8(0x62)]
        \\    assert(strings.from_bytes(invalid) == none)
        \\    var truncated: list[u8] = [u8(0x63), u8(0x61), u8(0x66), u8(0xC3)]
        \\    assert(strings.from_bytes(truncated) == none)
        \\    assert((strings.from_bytes(strings.to_bytes("café")) else "") == "café")
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

test "paths: joined folds join, and an empty list answers the empty path" {
    var session = try agree.compare(
        \\import std.paths
        \\
        \\func main():
        \\    print("[" + paths.joined(new list[str]) + "]")
        \\    print(paths.joined(["only"]))
        \\    print(paths.joined(["a", "b", "c.luc"]))
        \\    # An absolute part starts again, exactly as join does.
        \\    print(paths.joined(["a", "/etc", "hosts"]))
        \\    # Piled separators collapse at the seam, and an empty
        \\    # part contributes nothing.
        \\    print(paths.joined(["a/", "", "b"]))
        \\    print(paths.joined(["/", "etc"]))
        \\
    , budget);
    defer session.deinit();

    try testing.expectEqualStrings(
        "[]\nonly\na/b/c.luc\n/etc/hosts\na/b\n/etc\n",
        session.printed(),
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
// io
// ---------------------------------------------------------------------------
//
// The byte-stream contract is pure: a program's own conformers feed
// `drain` and `send` with no host in the room, which is exactly the
// claim the interfaces make — the loops are written over the contract,
// not over any particular stream.

test "io: a program's own reader and writer feed drain and send" {
    try agreeOk(
        \\import std.io
        \\
        \\class Feed: io.Reader:
        \\    private data: list[u8]
        \\    private at: i64
        \\
        \\    init(data: list[u8]):
        \\        self.data = data
        \\        self.at = 0
        \\
        \\    func read(buffer: array[u8, _]) -> i64!:
        \\        var filled: i64 = 0
        \\        while filled < len(buffer) and self.at < len(self.data):
        \\            buffer[filled] = self.data[self.at]
        \\            filled += 1
        \\            self.at += 1
        \\        return filled
        \\
        \\class Sink: io.Writer:
        \\    private got: list[u8]
        \\
        \\    init():
        \\        self.got = new list[u8]
        \\
        \\    func write(buffer: array[u8, _], count: i64) -> i64!:
        \\        var at: i64 = 0
        \\        while at < count:
        \\            self.got.append(buffer[at])
        \\            at += 1
        \\        return count
        \\
        \\    func flush() -> !:
        \\        return
        \\
        \\    func held() -> i64:
        \\        return len(self.got)
        \\
        \\func main() -> !:
        \\    var data = new list[u8]
        \\    var fill: i64 = 0
        \\    while fill < 300:
        \\        data.append(u8(fill % 251))
        \\        fill += 1
        \\    let drained = try io.drain(new Feed(data))
        \\    assert(len(drained) == 300)
        \\    assert(drained[0] == 0 and drained[299] == 48)
        \\    var sink = new Sink()
        \\    try io.send(sink, drained)
        \\    assert(sink.held() == 300)
        \\
    );
}

test "io: a source that stops writing is an error, not a spin" {
    try agreeOk(
        \\import std.io
        \\
        \\class Stuck: io.Writer:
        \\    marker: i64
        \\
        \\    init():
        \\        self.marker = 0
        \\
        \\    func write(buffer: array[u8, _], count: i64) -> i64!:
        \\        return 0
        \\
        \\    func flush() -> !:
        \\        return
        \\
        \\func main():
        \\    var refused = false
        \\    io.send(new Stuck(), [1, 2, 3]) catch reason:
        \\        refused = len(reason) > 0
        \\    assert(refused)
        \\
    );
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

test "files: a File opens through its init and travels as an io.Reader" {
    try agree.printsGiven(
        \\import std.files
        \\import std.io
        \\
        \\func gulp(source: io.Reader) -> list[u8]!:
        \\    return try io.drain(source)
        \\
        \\func main() -> !:
        \\    var f = try new files.File("notes.txt")
        \\    let all = try gulp(f)
        \\    print(str(len(all)))
        \\
    , withNotes("alpha\n"),
        \\6
        \\
    );
}

test "files: the three Mode doors open, empty, and extend" {
    // Each door opens inside its own frame: the harness world holds
    // one handle at a time, and ARC closing the file at frame exit is
    // exactly the shape a real program has.
    try agree.printsGiven(
        \\import std.files
        \\import std.io
        \\
        \\func start(path: str) -> !:
        \\    var made = try new files.File(path, files.Mode.create)
        \\    try io.send(made, [104, 105])
        \\
        \\func extend(path: str) -> !:
        \\    var more = try new files.File(path, files.Mode.append)
        \\    try io.send(more, [33])
        \\
        \\func main() -> !:
        \\    try start("out.txt")
        \\    try extend("out.txt")
        \\    print(try files.read("out.txt"))
        \\
    , withNotes("alpha\n"),
        \\hi!
        \\
    );
}

test "files: exists, read_lines, write_lines and write wrap the host builtins" {
    try agree.printsGiven(
        \\import std.files
        \\
        \\func main() -> !:
        \\    assert(try files.exists("notes.txt"))
        \\    assert(not try files.exists("ghost.txt"))
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
        \\    try files.append("log.txt", "one line\n")
        \\    try files.append_lines("log.txt", ["two", "three"])
        \\    try files.append_lines("log.txt", new list[str])
        \\    print(try files.read("log.txt"))
        \\    try files.rename("log.txt", "kept.txt")
        \\    assert((try files.exists("kept.txt")) and not try files.exists("log.txt"))
        \\    let names = try files.list(".")
        \\    print(names.join(","))
        \\    try files.delete("kept.txt")
        \\    assert(not try files.exists("kept.txt"))
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

test "files: kind answers each member, and none for a name nothing holds" {
    var world: agree.World = .withFile("notes.txt", "body");
    world.kinds = &[_]agree.World.KindRow{
        .{ .path = "notes.txt", .kind = .file },
        .{ .path = "papers", .kind = .directory },
        .{ .path = "wire", .kind = .other },
    };
    var provided = budget;
    provided.world = world;
    var session = try agree.compare(
        \\import std.files
        \\
        \\func name_of(path: str) -> str!:
        \\    let what = try files.kind(path)
        \\    if what == none:
        \\        return "nothing"
        \\    match what:
        \\        file:
        \\            return "file"
        \\        directory:
        \\            return "directory"
        \\        other:
        \\            return "other"
        \\
        \\func main() -> !:
        \\    print(try name_of("notes.txt"))
        \\    print(try name_of("papers"))
        \\    print(try name_of("wire"))
        \\    print(try name_of("ghost.txt"))
        \\
    , provided);
    defer session.deinit();

    try testing.expectEqualStrings("file\ndirectory\nother\nnothing\n", session.printed());
}

test "files: exists, is_file and is_dir answer bool! and let a refusal through" {
    var world: agree.World = .withFile("notes.txt", "body");
    world.kinds = &[_]agree.World.KindRow{
        .{ .path = "notes.txt", .kind = .file },
        .{ .path = "papers", .kind = .directory },
    };
    world.refused_kinds = &[_][]const u8{"locked"};
    var provided = budget;
    provided.world = world;
    var session = try agree.compare(
        \\import std.files
        \\
        \\func main() -> !:
        \\    print(str(try files.exists("notes.txt")))
        \\    print(str(try files.is_file("notes.txt")))
        \\    print(str(try files.is_dir("notes.txt")))
        \\    print(str(try files.is_dir("papers")))
        \\    print(str(try files.is_file("papers")))
        \\    print(str(try files.exists("ghost.txt")))
        \\    files.exists("locked/inside.txt") catch reason:
        \\        print(reason)
        \\    print(str(files.exists("locked/inside.txt") catch false))
        \\
    , provided);
    defer session.deinit();

    // The last line is Python's behaviour, spelled in three visible
    // words rather than chosen for the caller by the library.
    try testing.expectEqualStrings(
        "true\ntrue\nfalse\ntrue\nfalse\nfalse\n" ++
            "cannot inspect locked/inside.txt\nfalse\n",
        session.printed(),
    );
}

test "files: entries carries kinds, sorted, with a path that reaches each one" {
    // The default world lists three names into ".", and one of them
    // is a directory — so one listing carries two kinds and a walk
    // written against it has both branches to take.
    var session = try agree.compare(
        \\import std.files
        \\
        \\func main() -> !:
        \\    for entry in try files.entries("."):
        \\        match entry.kind:
        \\            file:
        \\                print("file " + entry.name + " " + entry.path)
        \\            directory:
        \\                print("dir  " + entry.name + " " + entry.path)
        \\            other:
        \\                print("othr " + entry.name + " " + entry.path)
        \\
    , budget);
    defer session.deinit();

    try testing.expectEqualStrings(
        "file alpha.txt ./alpha.txt\n" ++
            "file beta.txt ./beta.txt\n" ++
            "dir  notes ./notes\n",
        session.printed(),
    );
}

test "files: list answers names alone, while entries carries kinds" {
    var session = try agree.compare(
        \\import std.files
        \\import std.strings
        \\
        \\func main() -> !:
        \\    let names = try files.list(".")
        \\    print(names.join(","))
        \\    let listed = try files.entries(".")
        \\    print(str(len(listed)))
        \\
    , budget);
    defer session.deinit();

    try testing.expectEqualStrings("alpha.txt,beta.txt,notes\n3\n", session.printed());
}

test "files: a refused entries listing is an error on both engines" {
    var session = try agree.compare(
        \\import std.files
        \\
        \\func main():
        \\    files.entries("elsewhere") catch reason:
        \\        print(reason)
        \\
    , budget);
    defer session.deinit();

    try testing.expectEqualStrings("cannot list elsewhere\n", session.printed());
}

test "files: a listing the world refuses is an error naming the path" {
    try agree.errors(
        \\import std.files
        \\
        \\func main() -> !:
        \\    let names = try files.list("nowhere")
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

test "term: Unicode borders keep their junctions intact" {
    try agreeOk(
        \\import std.term
        \\
        \\func main():
        \\    assert(term.horizontal == "─")
        \\    assert(term.vertical == "│")
        \\    assert(term.top_left == "┌")
        \\    assert(term.bottom_right == "┘")
        \\    assert(term.junction(top = true, right = true, bottom = true, left = true) == "┼")
        \\    assert(term.junction(top = true, right = true, bottom = false, left = true) == "┴")
        \\    assert(term.junction(top = false, right = true, bottom = true, left = true) == "┬")
        \\    assert(term.shadow == "░")
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
        \\    print(str(os.total_memory()))
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
        \\    print(str(os.available_memory()))
        \\
    , unmeasurable, .host_unavailable);
    try agree.trapGiven(
        \\import std.os
        \\
        \\func main():
        \\    print(str(os.cpu_count()))
        \\
    , unmeasurable, .host_unavailable);
}

test "os: run crosses the host boundary as captured text" {
    try agree.printsGiven(
        \\import std.os
        \\
        \\func main() -> !:
        \\    print(try os.run("echo hi"))
        \\
    , budget, "mock shell: echo hi\nexit status: 0\n\n");
}

test "os: run traps when the host withholds the shell" {
    var no_shell = budget;
    no_shell.shell = false;
    try agree.trapGiven(
        \\import std.os
        \\
        \\func main() -> !:
        \\    print(try os.run("echo hi"))
        \\
    , no_shell, .host_unavailable);
}

// ---------------------------------------------------------------------------
// term
// ---------------------------------------------------------------------------

test "term: a mouse event carries its coordinates, modifiers, and wheel" {
    const keys = [_]agree.World.Key{
        .{
            .name = "mouse_press",
            .row = 6,
            .column = 10,
            .button = 0,
            .modifiers = 1,
        },
        .{
            .name = "mouse_wheel",
            .row = 8,
            .column = 4,
            .value = -1,
        },
    };
    var provided = budget;
    provided.world.keys = &keys;
    var session = try agree.compare(
        \\import std.term
        \\
        \\func mouse_of(event: term.Event?) -> term.Mouse:
        \\    if event == none:
        \\        trap("the keyboard ran dry")
        \\    match event:
        \\        mouse(pointer):
        \\            return pointer
        \\        else:
        \\            trap("not a mouse event")
        \\
        \\func main():
        \\    let press = mouse_of(term.read())
        \\    let wheel = mouse_of(term.read())
        \\    # The press was copied whole before the wheel was read: a
        \\    # held event never changes under a later read.
        \\    assert(press.kind == term.Pointer.press)
        \\    assert(press.row == 6)
        \\    assert(press.column == 10)
        \\    assert(press.button == 0)
        \\    assert(press.modifiers == 1)
        \\    assert(press.has_shift())
        \\    assert(not press.has_alt())
        \\    assert(not press.has_control())
        \\    assert(wheel.kind == term.Pointer.wheel)
        \\    assert(wheel.row == 8)
        \\    assert(wheel.column == 4)
        \\    assert(wheel.wheel == -1)
        \\
    , provided);
    defer session.deinit();
}
