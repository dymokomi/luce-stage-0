//! The standard library's test suite.
//!
//! Std modules are ordinary Luce compiled into every program that
//! imports them, so they are proven the way programs are: scripts
//! whose asserts trap on any wrong answer, leak-checked like
//! everything else.  math is pure and tests here; files needs a host
//! and tests beside TestHost in interpreter.zig.

const std = @import("std");
const compile_mod = @import("../compile.zig");
const types = @import("../support/types.zig");
const backend = @import("../backend.zig");

const testing = std.testing;

const script: types.CompileOptions = .{ .entry_mode = .script };

fn expectOk(source: []const u8) !void {
    var result = try compile_mod.compile(testing.allocator, source, .{}, script);
    defer result.deinit();
    switch (result) {
        .failure => |*diagnostics| {
            const rendered = try diagnostics.render(testing.allocator);
            defer testing.allocator.free(rendered);
            std.debug.print("unexpected compile error:\n{s}", .{rendered});
            return error.TestUnexpectedResult;
        },
        .success => |*program| {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const outcome = try backend.evaluate(.{ .arena = arena.allocator(), .objects = testing.allocator }, program, &.{}, &.{}, .{
                .steps = 50_000_000,
                .call_depth = 4096,
            });
            switch (outcome) {
                .success => |success| try testing.expectEqual(@as(u32, 0), success.leaked_objects),
                .trap => |trap| {
                    std.debug.print("unexpected trap: {s} ({s})\n", .{ trap.message, @tagName(trap.code) });
                    return error.TestUnexpectedResult;
                },
                .unavailable => return error.TestUnexpectedResult,
            }
        },
    }
}

fn expectTrap(source: []const u8, code: @import("../06_mir.zig").TrapCode) !void {
    var result = try compile_mod.compile(testing.allocator, source, .{}, script);
    defer result.deinit();
    switch (result) {
        .failure => return error.TestUnexpectedResult,
        .success => |*program| {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const outcome = try backend.evaluate(.{ .arena = arena.allocator(), .objects = testing.allocator }, program, &.{}, &.{}, .{
                .steps = 50_000_000,
                .call_depth = 4096,
            });
            if (outcome != .trap or outcome.trap.code != code) return error.TestUnexpectedResult;
        },
    }
}

// ---------------------------------------------------------------------------
// math
// ---------------------------------------------------------------------------

test "math: constants and round" {
    try expectOk(
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
    try expectOk(
        \\import std.math
        \\
        \\func close(a: Float, b: Float) -> Bool:
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
    try expectTrap(
        \\import std.math
        \\
        \\func main():
        \\    var x = 0.0
        \\    let bad = math.ln(x)
        \\
    , .explicit_trap);
}

test "math: pow covers the sign and zero cases" {
    try expectOk(
        \\import std.math
        \\
        \\func close(a: Float, b: Float) -> Bool:
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
    try expectTrap(
        \\import std.math
        \\
        \\func main():
        \\    var half = 0.5
        \\    let bad = math.pow(-2.0, half)
        \\
    , .explicit_trap);
}

test "math: ipow squares its way up and stays checked" {
    try expectOk(
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
    try expectTrap(
        \\import std.math
        \\
        \\func main():
        \\    var exponent = 64
        \\    let bad = math.ipow(2, exponent)
        \\
    , .integer_overflow);
}

test "math: trig against known values, across periods" {
    try expectOk(
        \\import std.math
        \\
        \\func close(a: Float, b: Float) -> Bool:
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
    try expectOk(
        \\import std.math
        \\
        \\func close(a: Float, b: Float) -> Bool:
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
    try expectOk(
        \\import std.math
        \\
        \\func main():
        \\    var xs = new Array(Float, 5)
        \\    for i in range(0, 5):
        \\        xs[i] = Float(i) * 0.5
        \\    assert(math.sum(xs) == 5.0)
        \\    assert(math.mean(xs) == 1.0)
        \\    assert(math.vmin(xs) == 0.0)
        \\    assert(math.vmax(xs) == 2.0)
        \\    var ys = new Array(Float, 5)
        \\    math.fill(ys, 2.0)
        \\    assert(math.sum(ys) == 10.0)
        \\    assert(math.dot(xs, ys) == 10.0)
        \\    assert(math.norm(ys) == sqrt(20.0))
        \\    math.scale(ys, 0.5)
        \\    assert(math.sum(ys) == 5.0)
        \\    math.axpy(ys, 2.0, xs)
        \\    assert(ys[4] == 5.0)
        \\    assert(math.variance(ys) == 2.0)
        \\    assert(math.stddev(ys) == sqrt(2.0))
        \\
    );
}

test "math: vector operations trap on empty and mismatched shapes" {
    try expectTrap(
        \\import std.math
        \\
        \\func main():
        \\    var empty = new Array(Float, 0)
        \\    let m = math.mean(empty)
        \\
    , .explicit_trap);
    try expectTrap(
        \\import std.math
        \\
        \\func main():
        \\    var a = new Array(Float, 2)
        \\    var b = new Array(Float, 3)
        \\    let d = math.dot(a, b)
        \\
    , .explicit_trap);
}

test "math: the generator is deterministic, in range, and covers its die" {
    try expectOk(
        \\import std.math
        \\
        \\func main():
        \\    var rng = math.seed(42)
        \\    var again = math.seed(42)
        \\    for i in range(0, 10):
        \\        assert(math.random_step(rng) == math.random_step(again))
        \\    var negative_seed = math.seed(-7)
        \\    assert(math.random_step(negative_seed) >= 1)
        \\    var die = math.seed(2026)
        \\    var seen = new Map(Int, Bool)
        \\    for i in range(0, 200):
        \\        let roll = math.random_int(die, 1, 7)
        \\        assert(roll >= 1 and roll <= 6)
        \\        seen[roll] = true
        \\    assert(len(seen) == 6)
        \\    var floats = math.seed(9)
        \\    for i in range(0, 100):
        \\        let f = math.random(floats)
        \\        assert(f > 0.0 and f < 1.0)
        \\
    );
    try expectTrap(
        \\import std.math
        \\
        \\func main():
        \\    var rng = math.seed(1)
        \\    let bad = math.random_int(rng, 5, 5)
        \\
    , .explicit_trap);
}

// ---------------------------------------------------------------------------
// strings
// ---------------------------------------------------------------------------

test "strings: find, find_from, contains, starts_with, ends_with, count" {
    try expectOk(
        \\import std.strings
        \\
        \\func main():
        \\    let s = "hello world"
        \\    assert(strings.find(s, "world") == 6)
        \\    assert(strings.find(s, "xyz") == -1)
        \\    assert(strings.find(s, "") == 0)
        \\    assert(strings.find_from(s, "o", 5) == 7)
        \\    assert(strings.find_from(s, "o", 8) == -1)
        \\    assert(strings.find_from(s, "", 3) == 3)
        \\    assert(strings.find_from(s, "o", -1) == -1)
        \\    assert(strings.find_from(s, "o", 99) == -1)
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
    try expectOk(
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
    try expectOk(
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
    try expectOk(
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
    try expectOk(
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
        \\    let empty: List(String) = []
        \\    assert(strings.join(empty, ", ") == "")
        \\    assert(strings.join(["only"], ", ") == "only")
        \\
    );
}

test "strings: pad_left and pad_right" {
    try expectOk(
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
    try expectOk(
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
    try expectTrap(
        \\import std.strings
        \\
        \\func main():
        \\    var decimals = -1
        \\    let bad = strings.format_float(1.0, decimals)
        \\
    , .explicit_trap);
}

// ---------------------------------------------------------------------------
// The mechanism
// ---------------------------------------------------------------------------

test "std resolves without any loader, and std names shadow sibling files" {
    // compile() has no loader at all; import math still works — the
    // std library lives in the compiler.
    try expectOk(
        \\import std.math
        \\
        \\func main():
        \\    assert(math.ipow(2, 8) == 256)
        \\
    );
}

test "std modules obey the host gate: files needs a host" {
    var result = try compile_mod.compile(testing.allocator,
        \\import std.files
        \\
        \\func main():
        \\    let found = files.exists("x")
        \\
    , .{}, script);
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
