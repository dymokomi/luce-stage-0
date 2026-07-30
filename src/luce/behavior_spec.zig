//! Behavioral correctness suite for the Luce language.
//!
//! Zig's test/behavior proves the language does what it says feature
//! by feature; this is our analog.  Each test is a `func main()` whose
//! `assert(...)`s trap on any wrong answer, so a green run means the
//! stated behavior holds — and stays holding, which is the point:
//! this is the regression net under every future compiler change.
//! Organized by feature area, not by anecdote.  Compile errors live
//! in errors_spec.zig; ownership lives in ownership_spec.zig.

const std = @import("std");
const compile_mod = @import("compile.zig");
const types = @import("types.zig");
const backend = @import("backend.zig");

const testing = std.testing;

const script: types.CompileOptions = .{ .entry_mode = .script };

/// Compile `source` as a script and run it; every `assert` inside
/// must hold, the run must not trap, and nothing may leak (scope
/// ownership frees everything — a nonzero count is an interpreter
/// bug).  The one harness behind every behavioral test.
fn expectOk(source: []const u8) !void {
    var result = try compile_mod.compile(testing.allocator, source, .{}, script);
    defer result.deinit();
    switch (result) {
        .failure => |*diagnostics| {
            const rendered = try diagnostics.render(testing.allocator, source);
            defer testing.allocator.free(rendered);
            std.debug.print("unexpected compile error:\n{s}", .{rendered});
            return error.TestUnexpectedResult;
        },
        .success => |*program| {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const outcome = try backend.evaluate(arena.allocator(), program, &.{}, &.{}, .{
                .steps = 50_000_000,
                .call_depth = 4096,
            });
            switch (outcome) {
                .success => |success| {
                    if (success.leaked_objects != 0) {
                        std.debug.print("{d} objects leaked\n", .{success.leaked_objects});
                        return error.TestUnexpectedResult;
                    }
                },
                .trap => |trap| {
                    std.debug.print("unexpected trap: {s} ({s})\n", .{ trap.message, @tagName(trap.code) });
                    return error.TestUnexpectedResult;
                },
                .unavailable => return error.TestUnexpectedResult,
            }
        },
    }
}

// ---------------------------------------------------------------------------
// Integer arithmetic
// ---------------------------------------------------------------------------

test "integers: the four operations and precedence" {
    try expectOk(
        \\func main():
        \\    assert(2 + 3 == 5)
        \\    assert(10 - 4 == 6)
        \\    assert(6 * 7 == 42)
        \\    assert(20 / 3 == 6)
        \\    assert(2 + 3 * 4 == 14)
        \\    assert((2 + 3) * 4 == 20)
        \\    assert(-5 + 2 == -3)
        \\    assert(- -5 == 5)
        \\
    );
}

test "integers: division truncates toward zero, remainder follows the dividend" {
    try expectOk(
        \\func main():
        \\    assert(7 / 2 == 3)
        \\    assert(-7 / 2 == -3)
        \\    assert(7 / -2 == -3)
        \\    assert(-7 / -2 == 3)
        \\    assert(7 % 3 == 1)
        \\    assert(-7 % 3 == -1)
        \\    assert(7 % -3 == 1)
        \\    assert(0 % 5 == 0)
        \\
    );
}

test "integers: the i64 range is honored" {
    try expectOk(
        \\func main():
        \\    assert(9223372036854775807 > 0)
        \\    assert(9223372036854775807 - 1 == 9223372036854775806)
        \\    let low = 0 - 9223372036854775807
        \\    assert(low - 1 < low)
        \\
    );
}

// ---------------------------------------------------------------------------
// Float arithmetic
// ---------------------------------------------------------------------------

test "floats: arithmetic, IEEE division, and builtins" {
    try expectOk(
        \\func main():
        \\    assert(1.5 + 2.5 == 4.0)
        \\    assert(3.0 * 2.0 == 6.0)
        \\    assert(1.0 / 4.0 == 0.25)
        \\    assert(sqrt(9.0) == 3.0)
        \\    assert(floor(2.7) == 2.0)
        \\    assert(ceil(2.1) == 3.0)
        \\    assert(abs(-2.5) == 2.5)
        \\    assert(1.0 / 0.0 > 9.0e300)
        \\
    );
}

test "floats and ints do not mix without explicit conversion" {
    try expectOk(
        \\func main():
        \\    let n = 7
        \\    let x = 2.0
        \\    assert(Float(n) / x == 3.5)
        \\    assert(Int(x) + n == 9)
        \\    assert(Float(Int(3.9)) == 3.0)
        \\
    );
}

// ---------------------------------------------------------------------------
// Booleans and comparison
// ---------------------------------------------------------------------------

test "booleans: logic, short-circuit, and comparison chains" {
    try expectOk(
        \\func main():
        \\    assert(true and true)
        \\    assert(not (true and false))
        \\    assert(true or false)
        \\    assert(not false)
        \\    assert(1 < 2 and 2 <= 2 and 3 > 2 and 3 >= 3)
        \\    assert(1 != 2)
        \\    assert(not (1 == 2))
        \\
    );
}

test "short-circuit does not evaluate the dead side" {
    try expectOk(
        \\func boom(x: Int) -> Bool:
        \\    assert(x != 0)
        \\    return true
        \\
        \\func main():
        \\    let a = false and boom(0)
        \\    assert(not a)
        \\    let b = true or boom(0)
        \\    assert(b)
        \\
    );
}

// ---------------------------------------------------------------------------
// Control flow
// ---------------------------------------------------------------------------

test "if / elif / else selects exactly one arm" {
    try expectOk(
        \\func classify(n: Int) -> Int:
        \\    if n < 0:
        \\        return 0 - 1
        \\    elif n == 0:
        \\        return 0
        \\    else:
        \\        return 1
        \\
        \\func main():
        \\    assert(classify(0 - 5) == 0 - 1)
        \\    assert(classify(0) == 0)
        \\    assert(classify(5) == 1)
        \\
    );
}

test "while loops, break, and continue" {
    try expectOk(
        \\func main():
        \\    var sum = 0
        \\    var i = 0
        \\    while i < 10:
        \\        i = i + 1
        \\        if i == 5:
        \\            continue
        \\        if i == 8:
        \\            break
        \\        sum = sum + i
        \\    assert(sum == 1 + 2 + 3 + 4 + 6 + 7)
        \\
    );
}

test "for-range iterates the half-open interval" {
    try expectOk(
        \\func main():
        \\    var total = 0
        \\    for i in range(0, 5):
        \\        total = total + i
        \\    assert(total == 10)
        \\    var count = 0
        \\    for i in range(3, 3):
        \\        count = count + 1
        \\    assert(count == 0)
        \\
    );
}

test "nested loops with labeled-free break only leave the inner loop" {
    try expectOk(
        \\func main():
        \\    var hits = 0
        \\    for i in range(0, 3):
        \\        for j in range(0, 3):
        \\            if j == 2:
        \\                break
        \\            hits = hits + 1
        \\    assert(hits == 6)
        \\
    );
}

// ---------------------------------------------------------------------------
// Functions and recursion
// ---------------------------------------------------------------------------

test "functions: parameters, returns, and recursion" {
    try expectOk(
        \\func factorial(n: Int) -> Int:
        \\    if n <= 1:
        \\        return 1
        \\    return n * factorial(n - 1)
        \\
        \\func fib(n: Int) -> Int:
        \\    if n < 2:
        \\        return n
        \\    return fib(n - 1) + fib(n - 2)
        \\
        \\func main():
        \\    assert(factorial(5) == 120)
        \\    assert(fib(10) == 55)
        \\
    );
}

test "mutual recursion resolves regardless of declaration order" {
    try expectOk(
        \\func is_even(n: Int) -> Bool:
        \\    if n == 0:
        \\        return true
        \\    return is_odd(n - 1)
        \\
        \\func is_odd(n: Int) -> Bool:
        \\    if n == 0:
        \\        return false
        \\    return is_even(n - 1)
        \\
        \\func main():
        \\    assert(is_even(10))
        \\    assert(is_odd(7))
        \\
    );
}

// ---------------------------------------------------------------------------
// Strings
// ---------------------------------------------------------------------------

test "strings: concatenation, comparison, and slicing" {
    try expectOk(
        \\func main():
        \\    let a = "loom"
        \\    assert(a + "!" == "loom!")
        \\    assert(a == "loom")
        \\    assert(a != "luce")
        \\    assert("abc" < "abd")
        \\    assert(a[0:2] == "lo")
        \\    assert(a[2:] == "om")
        \\    assert(a[:2] == "lo")
        \\    assert(len(a) == 4)
        \\
    );
}

test "strings: UTF-8 aware slicing and byte access" {
    // The 🙂 is four bytes (F0 9F 99 82); slices and byte_at see the
    // real UTF-8, and a slice that keeps it whole is exact.
    try expectOk(
        \\func main():
        \\    let s = "a🙂b"
        \\    assert(len(s) == 6)
        \\    assert(s[0:1] == "a")
        \\    assert(s[1:5] == "🙂")
        \\    assert(s.byte_at(0) == 97)
        \\    assert(s.byte_at(1) == 240)
        \\
    );
}

// ---------------------------------------------------------------------------
// Conversions
// ---------------------------------------------------------------------------

test "conversions: str, parse, chr, ord" {
    try expectOk(
        \\func main():
        \\    assert(str(42) == "42")
        \\    assert(str(0 - 7) == "-7")
        \\    assert(str(true) == "true")
        \\    assert(str(false) == "false")
        \\    assert(parse_int("100") == 100)
        \\    assert(parse_float("1.5") == 1.5)
        \\    assert(chr(65) == "A")
        \\    assert(ord("A") == 65)
        \\    assert(chr(955) == "λ")
        \\    assert(ord("λ") == 955)
        \\
    );
}

// ---------------------------------------------------------------------------
// Structs
// ---------------------------------------------------------------------------

test "structs: construction, field read, functional update, value copy" {
    try expectOk(
        \\struct Point:
        \\    x: Int
        \\    y: Int
        \\
        \\func main():
        \\    var p = Point(x = 1, y = 2)
        \\    assert(p.x == 1 and p.y == 2)
        \\    p.x = 10
        \\    assert(p.x == 10 and p.y == 2)
        \\    let q = p
        \\    p.y = 99
        \\    assert(q.y == 2)
        \\    assert(p == p)
        \\    assert(q != p)
        \\
    );
}

test "structs: namespaced functions and nested structs" {
    try expectOk(
        \\struct Vec:
        \\    x: Int
        \\    y: Int
        \\
        \\    func add(a: Vec, b: Vec) -> Vec:
        \\        return Vec(x = a.x + b.x, y = a.y + b.y)
        \\
        \\struct Line:
        \\    from: Vec
        \\    to: Vec
        \\
        \\func main():
        \\    let sum = Vec.add(Vec(x = 1, y = 2), Vec(x = 3, y = 4))
        \\    assert(sum.x == 4 and sum.y == 6)
        \\    let line = Line(from = Vec(x = 0, y = 0), to = sum)
        \\    assert(line.to.y == 6)
        \\
    );
}

// ---------------------------------------------------------------------------
// Collections
// ---------------------------------------------------------------------------

test "lists: literals, indexing, growth, and iteration" {
    try expectOk(
        \\func main():
        \\    var xs = [10, 20, 30]
        \\    assert(len(xs) == 3)
        \\    assert(xs[1] == 20)
        \\    xs[1] = 25
        \\    assert(xs[1] == 25)
        \\    xs.append(40)
        \\    assert(xs[3] == 40)
        \\    xs.insert(0, 5)
        \\    assert(xs[0] == 5 and len(xs) == 5)
        \\    xs.remove(0)
        \\    assert(xs[0] == 10)
        \\    assert(xs.pop() == 40)
        \\    var total = 0
        \\    for x in xs:
        \\        total = total + x
        \\    assert(total == 10 + 25 + 30)
        \\
    );
}

test "maps: upsert, lookup, membership, keys in insertion order" {
    try expectOk(
        \\func main():
        \\    var m = new Map(String, Int)
        \\    m["a"] = 1
        \\    m["b"] = 2
        \\    m["a"] = 3
        \\    assert(len(m) == 2)
        \\    assert(m["a"] == 3)
        \\    assert(m.has("b"))
        \\    assert(not m.has("z"))
        \\    var order = new Builder()
        \\    for k in m.keys():
        \\        order.append(k)
        \\    assert(str(order) == "ab")
        \\    m.remove("a")
        \\    assert(not m.has("a") and len(m) == 1)
        \\
    );
}

test "arrays: fixed shape, zero-init, multi-dimensional indexing" {
    try expectOk(
        \\func main():
        \\    var grid = new Array(Int, 3, 4)
        \\    assert(grid.dim(0) == 3 and grid.dim(1) == 4)
        \\    assert(grid[2, 3] == 0)
        \\    grid[2, 3] = 7
        \\    assert(grid[2, 3] == 7)
        \\    var row = new Array(Int, 5)
        \\    row.fill(9)
        \\    assert(row[0] == 9 and row[4] == 9)
        \\    assert(len(row) == 5)
        \\
    );
}

test "builders accumulate text" {
    try expectOk(
        \\func main():
        \\    var b = new Builder()
        \\    b.append("he")
        \\    b.append("llo")
        \\    assert(str(b) == "hello")
        \\    assert(len(b) == 5)
        \\    b.clear()
        \\    assert(len(b) == 0)
        \\
    );
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

test "file-scope constants fold and inline" {
    try expectOk(
        \\let width = 80
        \\let half = width / 2
        \\let name = "loom"
        \\let greeting = "hi " + name
        \\
        \\func main():
        \\    assert(width == 80)
        \\    assert(half == 40)
        \\    assert(greeting == "hi loom")
        \\
    );
}
