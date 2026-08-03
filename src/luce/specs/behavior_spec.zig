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
const compile_mod = @import("../compile.zig");
const types = @import("../support/types.zig");
const backend = @import("../backend.zig");
const mir = @import("../06_mir.zig");

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
                .success => |success| {
                    if (success.leaked_objects != 0) {
                        std.debug.print("{d} objects leaked\n", .{success.leaked_objects});
                        return error.TestUnexpectedResult;
                    }
                },
                .errored => |raised| {
                    std.debug.print("unexpected error: {s} ({s})\n", .{ raised.message, @tagName(raised.code) });
                    return error.TestUnexpectedResult;
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

/// Compile `source` as a script, run it, and require the run to abort
/// with exactly `code` — the mirror image of `expectOk` for the
/// runtime failure modes.  A clean success, the wrong trap code, or a
/// compile error all fail the test, so each entry pins one TrapCode to
/// the shortest program that provokes it.  Operands are deliberately
/// held in mutable locals: a compile-time-constant fault would be
/// caught by the analyzer instead and never reach the interpreter.
fn expectTrap(source: []const u8, code: mir.TrapCode) !void {
    var result = try compile_mod.compile(testing.allocator, source, .{}, script);
    defer result.deinit();
    switch (result) {
        .failure => |*diagnostics| {
            const rendered = try diagnostics.render(testing.allocator);
            defer testing.allocator.free(rendered);
            std.debug.print("unexpected compile error (wanted trap {s}):\n{s}", .{ @tagName(code), rendered });
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
                .success => {
                    std.debug.print("expected trap {s}, ran clean\n", .{@tagName(code)});
                    return error.TestUnexpectedResult;
                },
                .errored => |raised| {
                    std.debug.print("expected trap {s}, got error {s}\n", .{ @tagName(code), @tagName(raised.code) });
                    return error.TestUnexpectedResult;
                },
                .trap => |trap| {
                    if (trap.code != code) {
                        std.debug.print("expected trap {s}, got {s}\n", .{ @tagName(code), @tagName(trap.code) });
                        return error.TestUnexpectedResult;
                    }
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

test "integers: Int's minimum is written the way it reads" {
    // `-9223372036854775808` is a minus and a literal whose magnitude
    // is one past the largest positive Int.  Range-checking the
    // magnitude on its own makes the smallest Int the one number
    // nobody can spell, so the sign folds into the literal first.
    try expectOk(
        \\func main():
        \\    let low = -9223372036854775808
        \\    assert(low < 0)
        \\    assert(low + 1 == -9223372036854775807)
        \\    assert(low == 0 - 9223372036854775807 - 1)
        \\    let step = -9223372036854775808 / 2
        \\    assert(step == -4611686018427387904)
        \\
    );
}

test "integers: Int's minimum folds in a file-scope constant too" {
    try expectOk(
        \\let low = -9223372036854775808
        \\let high = 9223372036854775807
        \\
        \\func main():
        \\    assert(low < high)
        \\    assert(low + high == -1)
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
// Compound assignment
// ---------------------------------------------------------------------------

test "compound assignment on names: every operator, Int and Float" {
    try expectOk(
        \\func main():
        \\    var n = 10
        \\    n += 5
        \\    assert(n == 15)
        \\    n -= 3
        \\    assert(n == 12)
        \\    n *= 2
        \\    assert(n == 24)
        \\    n /= 5
        \\    assert(n == 4)
        \\    n %= 3
        \\    assert(n == 1)
        \\    var f = 2.0
        \\    f += 0.5
        \\    f *= 4.0
        \\    assert(f == 10.0)
        \\
    );
}

test "compound assignment concatenates strings with +=" {
    try expectOk(
        \\func main():
        \\    var s = "a"
        \\    s += "b"
        \\    s += "c" + "d"
        \\    assert(s == "abcd")
        \\
    );
}

test "compound assignment on struct fields and container elements" {
    try expectOk(
        \\struct Counter:
        \\    value: Int
        \\
        \\func main():
        \\    var c = Counter(value = 1)
        \\    c.value += 9
        \\    c.value *= 2
        \\    assert(c.value == 20)
        \\    var xs = [1, 2, 3]
        \\    xs[1] += 10
        \\    assert(xs[1] == 12)
        \\    var grid = new Array(Int, 2, 2)
        \\    grid[1, 1] += 7
        \\    grid[1, 1] -= 2
        \\    assert(grid[1, 1] == 5)
        \\    var m = new Map(String, Int)
        \\    m["k"] = 5
        \\    m["k"] *= 4
        \\    assert(m["k"] == 20)
        \\
    );
}

test "a compound index target evaluates its index expression once" {
    // If `xs[next()]` were evaluated twice the counter would land on
    // 2 and the wrong slot would change; once, it lands on 1.
    try expectOk(
        \\func main():
        \\    var calls = [0]
        \\    var xs = [100, 200, 300]
        \\    xs[bump(calls)] += 5
        \\    assert(calls[0] == 1)
        \\    assert(xs[1] == 205)
        \\    assert(xs[0] == 100)
        \\    assert(xs[2] == 300)
        \\
        \\func bump(counter: List(Int)) -> Int:
        \\    counter[0] = counter[0] + 1
        \\    return 1
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
        \\    assert((parse_int("100") else 0) == 100)
        \\    assert((parse_float("1.5") else 0.0) == 1.5)
        \\    assert(chr(65) == "A")
        \\    assert(ord("A") == 65)
        \\    assert(chr(955) == "λ")
        \\    assert(ord("λ") == 955)
        \\
    );
}

test "ord of a literal is a compile-time constant" {
    // Folding `ord` is what lets the language do without character
    // literal syntax at all: `byte_at(s, i) == ord("(")` should cost
    // exactly what `== 40` costs, or nobody will write it.
    var result = try compile_mod.compile(testing.allocator,
        \\func main():
        \\    let text = "(x)"
        \\    assert(text.byte_at(0) == ord("("))
        \\
    , .{}, script);
    defer result.deinit();
    try testing.expect(result == .success);
    for (result.success.functions) |function| {
        for (function.instructions) |instruction| {
            if (instruction == .intrinsic and instruction.intrinsic.kind == .ord_text) {
                std.debug.print("ord survived to run time\n", .{});
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "ord folds in a file-scope constant, and an empty one still traps at run time" {
    try expectOk(
        \\let open_paren = ord("(")
        \\let lambda = ord("λ")
        \\
        \\func main():
        \\    assert(open_paren == 40)
        \\    assert(lambda == 955)
        \\    assert("(a)".byte_at(0) == open_paren)
        \\
    );
    // A literal with no codepoint is left to the run time, so the
    // fold cannot quietly change what the program does.
    try expectTrap(
        \\func main():
        \\    var empty = ""
        \\    assert(ord(empty) == 0)
        \\
    , .bad_codepoint);
}

// ---------------------------------------------------------------------------
// String interpolation (f-strings)
// ---------------------------------------------------------------------------

test "f-strings interpolate names, expressions, and every str-able type" {
    try expectOk(
        \\func main():
        \\    let x = 7
        \\    let y = 3
        \\    assert(f"x = {x}, y = {y}" == "x = 7, y = 3")
        \\    assert(f"sum = {x + y}" == "sum = 10")
        \\    assert(f"{x}" == "7")
        \\    assert(f"{x}{y}" == "73")
        \\    let name = "loom"
        \\    assert(f"hi {name}!" == "hi loom!")
        \\    let flag = true
        \\    assert(f"flag={flag}" == "flag=true")
        \\    assert(f"ratio={2.5}" == "ratio=2.5")
        \\
    );
}

test "f-strings: empty, no holes, escapes, literal braces, nested strings" {
    try expectOk(
        \\func main():
        \\    assert(f"" == "")
        \\    assert(f"plain" == "plain")
        \\    assert(f"tab\tend" == "tab\tend")
        \\    assert(f"braces: {{ }}" == "braces: { }")
        \\    let name = "x"
        \\    assert(f"{name + "!"}" == "x!")
        \\    let n = 5
        \\    assert(f"{n * n} squared" == "25 squared")
        \\
    );
}

test "f-strings compose with methods and calls in holes" {
    try expectOk(
        \\import std.strings
        \\
        \\func twice(n: Int) -> Int:
        \\    return n * 2
        \\
        \\func main():
        \\    let s = "Loom"
        \\    assert(f"{s.lower()} and {s.upper()}" == "loom and LOOM")
        \\    assert(f"twice(21) = {twice(21)}" == "twice(21) = 42")
        \\    var xs = [1, 2, 3]
        \\    assert(f"len is {len(xs)}" == "len is 3")
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
// Nested-place assignment
// ---------------------------------------------------------------------------

test "chained assignment through nested struct fields" {
    try expectOk(
        \\struct Inner:
        \\    n: Int
        \\
        \\struct Outer:
        \\    label: String
        \\    inner: Inner
        \\
        \\func main():
        \\    var o = Outer(label = "x", inner = Inner(n = 1))
        \\    o.inner.n = 42
        \\    assert(o.inner.n == 42)
        \\    assert(o.label == "x")
        \\    o.inner.n += 8
        \\    assert(o.inner.n == 50)
        \\    let snapshot = o
        \\    o.inner.n = 0
        \\    assert(snapshot.inner.n == 50)
        \\
    );
}

test "chained assignment into struct elements of lists and arrays" {
    try expectOk(
        \\struct Cell:
        \\    value: Int
        \\
        \\func main():
        \\    var cells = [Cell(value = 10), Cell(value = 20)]
        \\    cells[1].value = 99
        \\    assert(cells[1].value == 99)
        \\    assert(cells[0].value == 10)
        \\    cells[0].value += 5
        \\    assert(cells[0].value == 15)
        \\    var grid = new Array(Cell, 2, 2)
        \\    grid[1, 1].value = 7
        \\    assert(grid[1, 1].value == 7)
        \\    assert(grid[0, 0].value == 0)
        \\
    );
}

test "a chained index place evaluates its subscript once" {
    try expectOk(
        \\struct Cell:
        \\    value: Int
        \\
        \\func bump(counter: List(Int)) -> Int:
        \\    counter[0] = counter[0] + 1
        \\    return 1
        \\
        \\func main():
        \\    var calls = [0]
        \\    var cells = [Cell(value = 100), Cell(value = 200)]
        \\    cells[bump(calls)].value += 5
        \\    assert(calls[0] == 1)
        \\    assert(cells[1].value == 205)
        \\    assert(cells[0].value == 100)
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

test "maps: for key, value iteration, values(), and get with default" {
    try expectOk(
        \\func main():
        \\    var m = new Map(String, Int)
        \\    m["a"] = 1
        \\    m["b"] = 2
        \\    m["c"] = 3
        \\    var keys = new Builder()
        \\    var total = 0
        \\    for k, v in m:
        \\        keys.append(k)
        \\        total += v
        \\    assert(str(keys) == "abc")
        \\    assert(total == 6)
        \\    assert(m.get("b", 0) == 2)
        \\    assert(m.get("missing", 99) == 99)
        \\    var vs = m.values()
        \\    assert(len(vs) == 3)
        \\    assert(vs[0] == 1 and vs[2] == 3)
        \\    assert(vs.contains(2))
        \\
    );
}

test "sequences: for index, element enumerates lists and rank-1 arrays" {
    try expectOk(
        \\func main():
        \\    var xs = [10, 20, 30]
        \\    var sum_index = 0
        \\    var sum_value = 0
        \\    for i, x in xs:
        \\        sum_index += i
        \\        sum_value += x
        \\    assert(sum_index == 0 + 1 + 2)
        \\    assert(sum_value == 60)
        \\    var row = new Array(Int, 4)
        \\    row.fill(5)
        \\    var seen = 0
        \\    for i, v in row:
        \\        seen += i
        \\        assert(v == 5)
        \\    assert(seen == 0 + 1 + 2 + 3)
        \\
    );
}

test "single-name for still binds keys for maps and elements for sequences" {
    try expectOk(
        \\func main():
        \\    var m = new Map(Int, Int)
        \\    m[7] = 70
        \\    m[8] = 80
        \\    var key_sum = 0
        \\    for k in m:
        \\        key_sum += k
        \\    assert(key_sum == 15)
        \\    var xs = [1, 2, 3]
        \\    var element_sum = 0
        \\    for x in xs:
        \\        element_sum += x
        \\    assert(element_sum == 6)
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

// ---------------------------------------------------------------------------
// Numeric builtins: abs / min / max / clamp
// ---------------------------------------------------------------------------

test "abs, min, max, clamp on Int" {
    try expectOk(
        \\func main():
        \\    assert(abs(0 - 7) == 7)
        \\    assert(abs(7) == 7)
        \\    assert(abs(0) == 0)
        \\    assert(min(3, 8) == 3)
        \\    assert(max(3, 8) == 8)
        \\    assert(min(0 - 2, 0 - 5) == 0 - 5)
        \\    assert(clamp(5, 0, 10) == 5)
        \\    assert(clamp(0 - 3, 0, 10) == 0)
        \\    assert(clamp(42, 0, 10) == 10)
        \\
    );
}

test "abs, min, max, clamp on Float" {
    try expectOk(
        \\func main():
        \\    assert(abs(0.0 - 2.5) == 2.5)
        \\    assert(min(1.5, 2.5) == 1.5)
        \\    assert(max(1.5, 2.5) == 2.5)
        \\    assert(clamp(0.5, 0.0, 1.0) == 0.5)
        \\    assert(clamp(0.0 - 1.0, 0.0, 1.0) == 0.0)
        \\    assert(clamp(9.0, 0.0, 1.0) == 1.0)
        \\
    );
}

test "float builtins: sqrt, floor, ceil on exact and fractional inputs" {
    try expectOk(
        \\func main():
        \\    assert(sqrt(16.0) == 4.0)
        \\    assert(sqrt(0.0) == 0.0)
        \\    assert(floor(2.999) == 2.0)
        \\    assert(floor(0.0 - 0.5) == 0.0 - 1.0)
        \\    assert(ceil(2.001) == 3.0)
        \\    assert(ceil(0.0 - 0.5) == 0.0)
        \\
    );
}

// ---------------------------------------------------------------------------
// Comparison operators across the ordered types
// ---------------------------------------------------------------------------

test "all six comparisons on Int" {
    try expectOk(
        \\func main():
        \\    assert(1 < 2)
        \\    assert(not (2 < 2))
        \\    assert(2 <= 2)
        \\    assert(not (3 <= 2))
        \\    assert(3 > 2)
        \\    assert(not (2 > 2))
        \\    assert(2 >= 2)
        \\    assert(not (2 >= 3))
        \\    assert(2 == 2)
        \\    assert(2 != 3)
        \\
    );
}

test "all six comparisons on Float" {
    try expectOk(
        \\func main():
        \\    assert(1.5 < 1.6)
        \\    assert(1.5 <= 1.5)
        \\    assert(1.6 > 1.5)
        \\    assert(1.5 >= 1.5)
        \\    assert(1.5 == 1.5)
        \\    assert(1.5 != 1.6)
        \\    assert(0.0 - 1.0 < 0.0)
        \\
    );
}

test "all six comparisons on String use lexicographic byte order" {
    try expectOk(
        \\func main():
        \\    assert("a" < "b")
        \\    assert("abc" < "abd")
        \\    assert("ab" < "abc")
        \\    assert("abc" <= "abc")
        \\    assert("b" > "a")
        \\    assert("abc" >= "abc")
        \\    assert("" < "a")
        \\    assert("Z" < "a")
        \\    assert("abc" == "abc")
        \\    assert("abc" != "abcd")
        \\
    );
}

// ---------------------------------------------------------------------------
// Equality by type: Bool, String, struct value, object identity
// ---------------------------------------------------------------------------

test "equality: Bool truth table" {
    try expectOk(
        \\func main():
        \\    assert(true == true)
        \\    assert(false == false)
        \\    assert(true != false)
        \\    assert((1 < 2) == (3 < 4))
        \\    assert((1 < 2) != (3 > 4))
        \\
    );
}

test "equality: lists compare by identity, not contents" {
    // Two independent lists with equal contents are not equal; a name
    // aliasing the same object is.
    try expectOk(
        \\func main():
        \\    let a = [1, 2, 3]
        \\    let b = [1, 2, 3]
        \\    assert(a != b)
        \\    let same = a
        \\    assert(same == a)
        \\
    );
}

test "equality: structs compare field by field (value semantics)" {
    try expectOk(
        \\struct Pair:
        \\    a: Int
        \\    b: Int
        \\
        \\func main():
        \\    let p = Pair(a = 1, b = 2)
        \\    let q = Pair(a = 1, b = 2)
        \\    let r = Pair(a = 1, b = 3)
        \\    assert(p == q)
        \\    assert(p != r)
        \\
    );
}

// ---------------------------------------------------------------------------
// Boolean operators: full truth tables and short-circuit on both sides
// ---------------------------------------------------------------------------

test "and / or / not full truth tables" {
    try expectOk(
        \\func main():
        \\    assert((true and true) == true)
        \\    assert((true and false) == false)
        \\    assert((false and true) == false)
        \\    assert((false and false) == false)
        \\    assert((true or true) == true)
        \\    assert((true or false) == true)
        \\    assert((false or true) == true)
        \\    assert((false or false) == false)
        \\    assert((not true) == false)
        \\    assert((not false) == true)
        \\
    );
}

// ---------------------------------------------------------------------------
// Control flow: for-each shapes, empty ranges, continue, deep recursion
// ---------------------------------------------------------------------------

test "for-range over a reversed interval iterates zero times" {
    try expectOk(
        \\func main():
        \\    var count = 0
        \\    for i in range(5, 2):
        \\        count = count + 1
        \\    assert(count == 0)
        \\    var count2 = 0
        \\    for i in range(0, 0):
        \\        count2 = count2 + 1
        \\    assert(count2 == 0)
        \\
    );
}

test "for-each over a List sums its elements in order" {
    try expectOk(
        \\func main():
        \\    let xs = [4, 5, 6]
        \\    var out = new Builder()
        \\    for x in xs:
        \\        out.append(str(x))
        \\    assert(str(out) == "456")
        \\
    );
}

test "for-each over a rank-1 Array visits every slot" {
    try expectOk(
        \\func main():
        \\    var row = new Array(Int, 4)
        \\    row[0] = 1
        \\    row[1] = 2
        \\    row[2] = 3
        \\    row[3] = 4
        \\    var total = 0
        \\    for v in row:
        \\        total = total + v
        \\    assert(total == 10)
        \\
    );
}

test "for-each over Map keys walks insertion order" {
    try expectOk(
        \\func main():
        \\    var m = new Map(String, Int)
        \\    m["x"] = 1
        \\    m["y"] = 2
        \\    m["z"] = 3
        \\    var joined = new Builder()
        \\    for k in m.keys():
        \\        joined.append(k)
        \\    assert(str(joined) == "xyz")
        \\
    );
}

test "continue in a for-loop skips the rest of the body" {
    try expectOk(
        \\func main():
        \\    var total = 0
        \\    for i in range(0, 10):
        \\        if i % 2 == 0:
        \\            continue
        \\        total = total + i
        \\    assert(total == 1 + 3 + 5 + 7 + 9)
        \\
    );
}

test "continue in a nested loop affects only the inner loop" {
    try expectOk(
        \\func main():
        \\    var hits = 0
        \\    for i in range(0, 3):
        \\        for j in range(0, 3):
        \\            if j == 1:
        \\                continue
        \\            hits = hits + 1
        \\    assert(hits == 6)
        \\
    );
}

test "the explicit frame stack survives a deep iterative-recursive sum" {
    try expectOk(
        \\func sum_to(n: Int) -> Int:
        \\    if n == 0:
        \\        return 0
        \\    return n + sum_to(n - 1)
        \\
        \\func main():
        \\    assert(sum_to(4000) == 8002000)
        \\
    );
}

// ---------------------------------------------------------------------------
// Strings: the full method surface
// ---------------------------------------------------------------------------

test "strings: find, contains, starts_with, ends_with" {
    try expectOk(
        \\import std.strings
        \\
        \\func main():
        \\    let s = "hello world"
        \\    assert(s.find("world") == 6)
        \\    assert(s.find("xyz") == 0 - 1)
        \\    assert(s.find("hello") == 0)
        \\    assert(s.contains("lo w"))
        \\    assert(not s.contains("zzz"))
        \\    assert(s.starts_with("hello"))
        \\    assert(not s.starts_with("world"))
        \\    assert(s.ends_with("world"))
        \\    assert(not s.ends_with("hello"))
        \\
    );
}

test "strings: trim, lower, upper, repeat" {
    try expectOk(
        \\import std.strings
        \\
        \\func main():
        \\    assert("  hi  ".trim() == "hi")
        \\    assert("\t\nhi\n".trim() == "hi")
        \\    assert("".trim() == "")
        \\    assert("MiXeD".lower() == "mixed")
        \\    assert("MiXeD".upper() == "MIXED")
        \\    assert("ab".repeat(3) == "ababab")
        \\    assert("ab".repeat(0) == "")
        \\    assert("x".repeat(1) == "x")
        \\
    );
}

test "strings: replace substitutes every occurrence" {
    try expectOk(
        \\import std.strings
        \\
        \\func main():
        \\    assert("a.b.c".replace(".", "-") == "a-b-c")
        \\    assert("aaa".replace("a", "bb") == "bbbbbb")
        \\    assert("hello".replace("z", "y") == "hello")
        \\    assert("hello".replace("l", "") == "heo")
        \\
    );
}

test "strings: split on a separator and split on whitespace" {
    try expectOk(
        \\import std.strings
        \\
        \\func main():
        \\    let a = "1,2,3".split(",")
        \\    assert(len(a) == 3)
        \\    assert(a[0] == "1" and a[1] == "2" and a[2] == "3")
        \\    let b = "  the   quick brown  ".split("")
        \\    assert(len(b) == 3)
        \\    assert(b[0] == "the" and b[1] == "quick" and b[2] == "brown")
        \\    let c = "solo".split(",")
        \\    assert(len(c) == 1 and c[0] == "solo")
        \\
    );
}

test "strings: join round-trips split" {
    try expectOk(
        \\import std.strings
        \\
        \\func main():
        \\    let parts = "a-b-c".split("-")
        \\    assert(parts.join("-") == "a-b-c")
        \\    assert(parts.join("") == "abc")
        \\    let two = ["x", "y"]
        \\    assert(two.join(", ") == "x, y")
        \\    let one = ["only"]
        \\    assert(one.join(",") == "only")
        \\
    );
}

test "strings: slicing corners — empty, full, and open ends" {
    try expectOk(
        \\func main():
        \\    let s = "abcde"
        \\    assert(s[0:0] == "")
        \\    assert(s[2:2] == "")
        \\    assert(s[0:5] == "abcde")
        \\    assert(s[:] == "abcde")
        \\    assert(s[:3] == "abc")
        \\    assert(s[3:] == "de")
        \\    assert(s[5:5] == "")
        \\
    );
}

test "strings: byte_at reads raw UTF-8 bytes of a multibyte string" {
    // λ is two bytes (CE BB); byte_at exposes each byte and len counts
    // bytes, not codepoints.
    try expectOk(
        \\func main():
        \\    let s = "λ"
        \\    assert(len(s) == 2)
        \\    assert(s.byte_at(0) == 206)
        \\    assert(s.byte_at(1) == 187)
        \\    let mix = "aλb"
        \\    assert(len(mix) == 4)
        \\    assert(mix.byte_at(0) == 97)
        \\    assert(mix[0:1] == "a")
        \\    assert(mix[1:3] == "λ")
        \\    assert(mix[3:4] == "b")
        \\
    );
}

// ---------------------------------------------------------------------------
// Conversions in depth
// ---------------------------------------------------------------------------

test "str renders every scalar and a Builder" {
    try expectOk(
        \\func main():
        \\    assert(str(0) == "0")
        \\    assert(str(1000000) == "1000000")
        \\    assert(str(1.5) == "1.5")
        \\    assert(str(3.0) == "3")
        \\    assert(str(true) == "true")
        \\    assert(str("already") == "already")
        \\    var b = new Builder()
        \\    b.append("bld")
        \\    assert(str(b) == "bld")
        \\
    );
}

test "parse_int and parse_float accept signs and round-trip str" {
    try expectOk(
        \\func main():
        \\    assert((parse_int("0") else 1) == 0)
        \\    assert((parse_int("-42") else 0) == 0 - 42)
        \\    assert((parse_int("+7") else 0) == 7)
        \\    assert((parse_float("3.25") else 0.0) == 3.25)
        \\    assert((parse_float("-0.5") else 0.0) == 0.0 - 0.5)
        \\    assert((parse_int(str(98765)) else 0) == 98765)
        \\
    );
}

test "parse_int and parse_float answer none rather than trapping" {
    try expectOk(
        \\func main():
        \\    assert(parse_int("not a number") == none)
        \\    assert(parse_int("4 2") == none)
        \\    assert(parse_int("") == none)
        \\    assert(parse_float("abc") == none)
        \\    assert(parse_float("inf") == none)
        \\    assert(parse_float("nan") == none)
        \\    assert(parse_int("7") != none)
        \\    assert((parse_int("nope") else 0 - 1) == 0 - 1)
        \\    assert((parse_float("nope") else 2.5) == 2.5)
        \\
    );
}

test "chr and ord round-trip across ASCII and multibyte codepoints" {
    try expectOk(
        \\func main():
        \\    assert(chr(97) == "a")
        \\    assert(ord("a") == 97)
        \\    assert(ord(chr(0)) == 0)
        \\    assert(chr(955) == "λ")
        \\    assert(ord("λ") == 955)
        \\    assert(chr(128578) == "🙂")
        \\    assert(ord("🙂") == 128578)
        \\    assert(ord(chr(128578)) == 128578)
        \\
    );
}

// ---------------------------------------------------------------------------
// Lists: methods, slicing independence, nesting, structs
// ---------------------------------------------------------------------------

test "lists: sort orders Int, Float, and String in place" {
    try expectOk(
        \\func main():
        \\    var ints = [3, 1, 2]
        \\    ints.sort()
        \\    assert(ints[0] == 1 and ints[1] == 2 and ints[2] == 3)
        \\    var floats = [2.5, 0.5, 1.5]
        \\    floats.sort()
        \\    assert(floats[0] == 0.5 and floats[2] == 2.5)
        \\    var words = ["cherry", "apple", "banana"]
        \\    words.sort()
        \\    assert(words[0] == "apple" and words[2] == "cherry")
        \\
    );
}

test "lists: sort is stable — equal elements keep their order" {
    // -0.0 and 0.0 compare equal and print differently, so the order
    // a sort leaves them in is observable from a Luce program.  That
    // makes stability part of the language, not an implementation
    // detail: this test fails outright under an unstable sort.
    try expectOk(
        \\func main():
        \\    var xs: List(Float) = []
        \\    var i = 0
        \\    while i < 40:
        \\        xs.append(1.0)
        \\        xs.append(-0.0)
        \\        xs.append(0.0)
        \\        i += 1
        \\    xs.sort()
        \\    i = 0
        \\    while i < 40:
        \\        assert(str(xs[i * 2]) == "-0")
        \\        assert(str(xs[i * 2 + 1]) == "0")
        \\        i += 1
        \\    assert(xs[80] == 1.0)
        \\
    );
}

test "lists: reverse, find, contains, clear" {
    try expectOk(
        \\func main():
        \\    var xs = [1, 2, 3, 4]
        \\    xs.reverse()
        \\    assert(xs[0] == 4 and xs[3] == 1)
        \\    assert(xs.find(3) == 1)
        \\    assert(xs.find(99) == 0 - 1)
        \\    assert(xs.contains(2))
        \\    assert(not xs.contains(99))
        \\    xs.clear()
        \\    assert(len(xs) == 0)
        \\
    );
}

test "lists: a slice is an independent copy" {
    try expectOk(
        \\func main():
        \\    var xs = [1, 2, 3, 4, 5]
        \\    var mid = xs[1:4]
        \\    assert(len(mid) == 3)
        \\    assert(mid[0] == 2 and mid[2] == 4)
        \\    mid[0] = 99
        \\    assert(xs[1] == 2)
        \\    xs[2] = 88
        \\    assert(mid[1] == 3)
        \\    assert(len(xs[:]) == 5)
        \\    assert(len(xs[2:2]) == 0)
        \\
    );
}

test "lists: nested lists are references shared until copied" {
    try expectOk(
        \\func main():
        \\    var outer = new List(List(Int))
        \\    var inner = [1, 2]
        \\    outer.append(give inner)
        \\    outer[0].append(3)
        \\    assert(len(outer[0]) == 3)
        \\    var dup = new List(List(Int))
        \\    dup.append(copy outer[0])
        \\    dup[0].append(4)
        \\    assert(len(dup[0]) == 4)
        \\    assert(len(outer[0]) == 3)
        \\
    );
}

test "lists: value structs stored by copy are independent" {
    // append copies the value struct; later mutating the source or
    // replacing one slot leaves the other stored copies untouched.
    // (Assignment targets are a single field or a single index, so a
    // slot is replaced whole with cells[i] = ..., not cells[i].v = ...)
    try expectOk(
        \\struct Cell:
        \\    v: Int
        \\
        \\func main():
        \\    var cells = new List(Cell)
        \\    var c = Cell(v = 1)
        \\    cells.append(c)
        \\    cells.append(c)
        \\    c.v = 99
        \\    assert(cells[0].v == 1 and cells[1].v == 1)
        \\    cells[0] = Cell(v = 5)
        \\    assert(cells[0].v == 5 and cells[1].v == 1)
        \\    assert(c.v == 99)
        \\
    );
}

// ---------------------------------------------------------------------------
// Maps: key types, removal, clear
// ---------------------------------------------------------------------------

test "maps: Int keys, lookup, has, and len" {
    try expectOk(
        \\func main():
        \\    var m = new Map(Int, String)
        \\    m[1] = "one"
        \\    m[2] = "two"
        \\    m[10] = "ten"
        \\    assert(len(m) == 3)
        \\    assert(m[10] == "ten")
        \\    assert(m.has(1))
        \\    assert(not m.has(3))
        \\    m[1] = "uno"
        \\    assert(m[1] == "uno")
        \\    assert(len(m) == 3)
        \\
    );
}

test "maps: removing an absent key is a no-op; clear empties" {
    try expectOk(
        \\func main():
        \\    var m = new Map(String, Int)
        \\    m["a"] = 1
        \\    m["b"] = 2
        \\    m.remove("ghost")
        \\    assert(len(m) == 2)
        \\    m.remove("a")
        \\    assert(len(m) == 1 and not m.has("a"))
        \\    m.clear()
        \\    assert(len(m) == 0)
        \\    m["c"] = 3
        \\    assert(m["c"] == 3)
        \\
    );
}

test "maps: hundreds of keys keep insertion order and every lookup hits" {
    // Small maps say nothing about the hash index: this one grows
    // past several rebuilds, so keys collide, probe sequences run
    // long, and removal renumbers every entry behind the one it took
    // out.  Insertion order is a promise of the language (iteration,
    // keys()), and it has to survive all of that.
    try expectOk(
        \\func main():
        \\    var m = new Map(String, Int)
        \\    var i = 0
        \\    while i < 300:
        \\        m["k" + str(i)] = i
        \\        i += 1
        \\    assert(len(m) == 300)
        \\    var seen = 0
        \\    for key, held in m:
        \\        assert(key == "k" + str(held))
        \\        assert(held == seen)
        \\        seen += 1
        \\    assert(seen == 300)
        \\    i = 0
        \\    while i < 300:
        \\        assert(m["k" + str(i)] == i)
        \\        assert(m.has("k" + str(i)))
        \\        i += 1
        \\    i = 0
        \\    while i < 300:
        \\        if i % 2 == 0:
        \\            m.remove("k" + str(i))
        \\        i += 1
        \\    assert(len(m) == 150)
        \\    var next = 1
        \\    for key in m:
        \\        assert(key == "k" + str(next))
        \\        next += 2
        \\    assert(m.get("k5", 0 - 1) == 5)
        \\    assert(m.get("k4", 0 - 1) == 0 - 1)
        \\
    );
}

test "maps: Int keys survive growth, negatives, and the extremes" {
    try expectOk(
        \\func main():
        \\    var m = new Map(Int, Int)
        \\    var i = 0 - 200
        \\    while i < 200:
        \\        m[i * 3] = i
        \\        i += 1
        \\    assert(len(m) == 400)
        \\    i = 0 - 200
        \\    while i < 200:
        \\        assert(m[i * 3] == i)
        \\        i += 1
        \\    assert(not m.has(1))
        \\    m[9223372036854775807] = 1
        \\    m[0 - 9223372036854775807 - 1] = 2
        \\    assert(m[9223372036854775807] == 1)
        \\    assert(m[0 - 9223372036854775807 - 1] == 2)
        \\
    );
}

// ---------------------------------------------------------------------------
// Arrays: ranks 1..4, dims, fill, rank-1 methods
// ---------------------------------------------------------------------------

test "arrays: ranks one through four report their dims and zero-init" {
    try expectOk(
        \\func main():
        \\    var a1 = new Array(Int, 5)
        \\    assert(a1.dim(0) == 5 and a1[4] == 0)
        \\    var a2 = new Array(Int, 2, 3)
        \\    assert(a2.dim(0) == 2 and a2.dim(1) == 3)
        \\    assert(a2[1, 2] == 0)
        \\    var a3 = new Array(Int, 2, 2, 2)
        \\    assert(a3.dim(2) == 2 and a3[1, 1, 1] == 0)
        \\    a3[1, 1, 1] = 7
        \\    assert(a3[1, 1, 1] == 7 and a3[0, 0, 0] == 0)
        \\    var a4 = new Array(Int, 2, 2, 2, 2)
        \\    assert(a4.dim(3) == 2 and a4[1, 1, 1, 1] == 0)
        \\    a4[1, 1, 1, 1] = 9
        \\    assert(a4[1, 1, 1, 1] == 9)
        \\
    );
}

test "arrays: fill sets every slot; len is the first dimension" {
    try expectOk(
        \\func main():
        \\    var row = new Array(Float, 4)
        \\    row.fill(1.5)
        \\    assert(row[0] == 1.5 and row[3] == 1.5)
        \\    assert(len(row) == 4)
        \\    var grid = new Array(Int, 3, 5)
        \\    assert(len(grid) == 3)
        \\
    );
}

test "arrays: rank-1 sort, reverse, find, contains" {
    try expectOk(
        \\func main():
        \\    var row = new Array(Int, 4)
        \\    row[0] = 3
        \\    row[1] = 1
        \\    row[2] = 4
        \\    row[3] = 2
        \\    row.sort()
        \\    assert(row[0] == 1 and row[3] == 4)
        \\    assert(row.find(4) == 3)
        \\    assert(row.contains(2))
        \\    assert(not row.contains(99))
        \\    row.reverse()
        \\    assert(row[0] == 4 and row[3] == 1)
        \\
    );
}

// ---------------------------------------------------------------------------
// Structs: functional update independence, nesting, in collections
// ---------------------------------------------------------------------------

test "structs: assigning a copy leaves the source untouched for value fields" {
    try expectOk(
        \\struct Point:
        \\    x: Int
        \\    y: Int
        \\
        \\func main():
        \\    var a = Point(x = 1, y = 2)
        \\    var b = a
        \\    b.x = 100
        \\    b.y = 200
        \\    assert(a.x == 1 and a.y == 2)
        \\    assert(b.x == 100 and b.y == 200)
        \\
    );
}

test "structs: nested value structs copy deeply" {
    // Copying a struct duplicates its nested value struct; replacing
    // the inner field on the copy does not reach the original.  (A
    // nested field cannot be an assignment target — p.inner.n = ... is
    // rejected — so the whole inner field is replaced instead.)
    try expectOk(
        \\struct Inner:
        \\    n: Int
        \\
        \\struct Outer:
        \\    inner: Inner
        \\    tag: Int
        \\
        \\func main():
        \\    var o = Outer(inner = Inner(n = 1), tag = 0)
        \\    var p = o
        \\    p.inner = Inner(n = 99)
        \\    p.tag = 7
        \\    assert(o.inner.n == 1)
        \\    assert(o.tag == 0)
        \\    assert(p.inner.n == 99 and p.tag == 7)
        \\
    );
}

test "structs: namespaced functions can recurse and call peers" {
    try expectOk(
        \\struct Math:
        \\    dummy: Int
        \\
        \\    func square(n: Int) -> Int:
        \\        return n * n
        \\
        \\    func hypot_sq(a: Int, b: Int) -> Int:
        \\        return Math.square(a) + Math.square(b)
        \\
        \\func main():
        \\    assert(Math.square(5) == 25)
        \\    assert(Math.hypot_sq(3, 4) == 25)
        \\
    );
}

// ---------------------------------------------------------------------------
// Ownership: behavioral positives (transfer, deep copy, drop, late slots)
// ---------------------------------------------------------------------------

test "ownership: give transfers an object into a new owner" {
    try expectOk(
        \\func main():
        \\    var original = [1, 2, 3]
        \\    var moved = give original
        \\    moved.append(4)
        \\    assert(len(moved) == 4)
        \\    assert(moved[3] == 4)
        \\
    );
}

test "ownership: copy is a deep, independent duplicate" {
    try expectOk(
        \\func main():
        \\    var source = [1, 2, 3]
        \\    var dup = copy source
        \\    dup.append(4)
        \\    assert(len(dup) == 4)
        \\    assert(len(source) == 3)
        \\    source[0] = 99
        \\    assert(dup[0] == 1)
        \\
    );
}

test "ownership: reassigning an owning var frees the old object with no leak" {
    try expectOk(
        \\func main():
        \\    var b = new Builder()
        \\    b.append("first")
        \\    b = new Builder()
        \\    b.append("second")
        \\    assert(str(b) == "second")
        \\
    );
}

test "ownership: a late-declared object slot can be filled and used" {
    try expectOk(
        \\func main():
        \\    var xs: List(Int)
        \\    xs = [7, 8, 9]
        \\    assert(len(xs) == 3)
        \\    xs.append(10)
        \\    assert(xs[3] == 10)
        \\
    );
}

test "ownership: return moves an object out of a function" {
    try expectOk(
        \\func make() -> List(Int):
        \\    var xs = new List(Int)
        \\    xs.append(1)
        \\    xs.append(2)
        \\    return xs
        \\
        \\func main():
        \\    var got = make()
        \\    assert(len(got) == 2)
        \\    assert(got[0] == 1 and got[1] == 2)
        \\
    );
}

test "ownership: a borrowed parameter is read without transfer" {
    try expectOk(
        \\func total(xs: List(Int)) -> Int:
        \\    var sum = 0
        \\    for x in xs:
        \\        sum = sum + x
        \\    return sum
        \\
        \\func main():
        \\    var xs = [1, 2, 3, 4]
        \\    assert(total(xs) == 10)
        \\    assert(len(xs) == 4)
        \\    assert(total(xs) == 10)
        \\
    );
}

// ---------------------------------------------------------------------------
// Late declarations and zero values
// ---------------------------------------------------------------------------

test "late var declarations hold the zero value of their type" {
    try expectOk(
        \\struct Vec3:
        \\    x: Int
        \\    y: Int
        \\    z: Int
        \\
        \\func main():
        \\    var n: Int
        \\    assert(n == 0)
        \\    var f: Float
        \\    assert(f == 0.0)
        \\    var flag: Bool
        \\    assert(not flag)
        \\    var s: String
        \\    assert(s == "")
        \\    assert(len(s) == 0)
        \\    var v: Vec3
        \\    assert(v.x == 0 and v.y == 0 and v.z == 0)
        \\
    );
}

test "a late var can be assigned after a branch decides its value" {
    try expectOk(
        \\func pick(flag: Bool) -> Int:
        \\    var out: Int
        \\    if flag:
        \\        out = 10
        \\    else:
        \\        out = 20
        \\    return out
        \\
        \\func main():
        \\    assert(pick(true) == 10)
        \\    assert(pick(false) == 20)
        \\
    );
}

// ---------------------------------------------------------------------------
// Constants: every scalar type, cross-references, use inside functions
// ---------------------------------------------------------------------------

test "constants of every scalar type fold and inline" {
    try expectOk(
        \\let limit = 3 * 4
        \\let ratio = 1.0 / 4.0
        \\let enabled = true and not false
        \\let prefix = "id_"
        \\
        \\func label(n: Int) -> String:
        \\    return prefix + str(n)
        \\
        \\func main():
        \\    assert(limit == 12)
        \\    assert(ratio == 0.25)
        \\    assert(enabled)
        \\    assert(label(7) == "id_7")
        \\
    );
}

test "constants reference earlier constants" {
    try expectOk(
        \\let base = 10
        \\let doubled = base * 2
        \\let quadrupled = doubled * 2
        \\let name = "core"
        \\let full = name + "!"
        \\
        \\func main():
        \\    assert(doubled == 20)
        \\    assert(quadrupled == 40)
        \\    assert(full == "core!")
        \\
    );
}

// ---------------------------------------------------------------------------
// Absence: T?, none, narrowing, else (docs/FAILURE.md)
// ---------------------------------------------------------------------------

test "a T? holds either a value or none, and says which" {
    try expectOk(
        \\func passthrough(n: Int?) -> Int?:
        \\    return n
        \\
        \\func text(t: String?) -> String?:
        \\    return t
        \\
        \\func main():
        \\    var n: Int? = none
        \\    assert(n == none)
        \\    assert(not (n != none))
        \\    n = 7
        \\    # Through a call the narrowing is gone and the question is
        \\    # a real one again.
        \\    assert(passthrough(n) != none)
        \\    assert(not (passthrough(n) == none))
        \\    var t: String? = "hi"
        \\    assert(text(t) != none)
        \\    t = none
        \\    assert(t == none)
        \\
    );
}

test "narrowing: a tested name is its payload inside the branch, and both branches see it" {
    try expectOk(
        \\func main():
        \\    let n = parse_int("41")
        \\    var seen = 0
        \\    if n != none:
        \\        seen = n + 1
        \\    else:
        \\        seen = 0 - 1
        \\    assert(seen == 42)
        \\
        \\    let bad = parse_int("x")
        \\    var other = 0
        \\    if bad == none:
        \\        other = 5
        \\    else:
        \\        other = bad * 2
        \\    assert(other == 5)
        \\
    );
}

test "narrowing: an early-return guard narrows the rest of the block" {
    try expectOk(
        \\func doubled(text: String) -> Int:
        \\    let n = parse_int(text)
        \\    if n == none:
        \\        return 0 - 1
        \\    return n * 2
        \\
        \\func main():
        \\    assert(doubled("21") == 42)
        \\    assert(doubled("nope") == 0 - 1)
        \\
    );
}

test "narrowing: continue and break guards narrow what follows them" {
    try expectOk(
        \\func main():
        \\    let inputs = ["1", "x", "3"]
        \\    var total = 0
        \\    for text in inputs:
        \\        let n = parse_int(text)
        \\        if n == none:
        \\            continue
        \\        total = total + n
        \\    assert(total == 4)
        \\
        \\    var index = 0
        \\    var first = 0
        \\    while index < len(inputs):
        \\        let n = parse_int(inputs[index])
        \\        index = index + 1
        \\        if n == none:
        \\            break
        \\        first = first + n
        \\    assert(first == 1)
        \\    free(inputs)
        \\
    );
}

test "narrowing: and carries the test into the rest of the condition" {
    try expectOk(
        \\func main():
        \\    let n = parse_int("5")
        \\    var hit = false
        \\    if n != none and n > 3:
        \\        hit = true
        \\    assert(hit)
        \\
        \\    let bad = parse_int("x")
        \\    var missed = false
        \\    if bad != none and bad > 3:
        \\        missed = true
        \\    assert(not missed)
        \\
        \\    # `or` narrows on its false side, which is the dual.
        \\    var reached = false
        \\    if bad == none or bad > 3:
        \\        reached = true
        \\    assert(reached)
        \\
    );
}

test "narrowing: an assignment of a plain value proves the name present" {
    try expectOk(
        \\func main():
        \\    var n: Int? = none
        \\    n = 3
        \\    assert(n * 2 == 6)
        \\    var xs: List(Int)? = none
        \\    xs = new List(Int)
        \\    xs.append(4)
        \\    assert(len(xs) == 1)
        \\    free(xs)
        \\
    );
}

test "narrowing: a while condition narrows its body" {
    try expectOk(
        \\func main():
        \\    var countdown: Int? = 3
        \\    var steps = 0
        \\    while countdown != none:
        \\        steps = steps + 1
        \\        if countdown == 1:
        \\            countdown = none
        \\        else:
        \\            countdown = countdown - 1
        \\    assert(steps == 3)
        \\
    );
}

test "else supplies the fallback, lazily, and chains to the right" {
    try expectOk(
        \\func main():
        \\    assert((parse_int("8") else 0) == 8)
        \\    assert((parse_int("x") else 0) == 0)
        \\    # right-associative: the first that is there wins.
        \\    assert((parse_int("x") else parse_int("9") else 0) == 9)
        \\    assert((parse_int("x") else parse_int("y") else 3) == 3)
        \\    # `else` binds tighter than comparison and looser than +.
        \\    assert((parse_int("x") else 2 + 3) == 5)
        \\    assert(((parse_int("x") else 1) == 1) == true)
        \\
    );
}

test "else runs its fallback only when the value is absent" {
    try expectOk(
        \\func note(log: Builder, mark: String) -> Int:
        \\    log.append(mark)
        \\    return 0
        \\
        \\func main():
        \\    let log = new Builder
        \\    assert((parse_int("1") else note(log, "a")) == 1)
        \\    assert((parse_int("x") else note(log, "b")) == 0)
        \\    assert(str(log) == "b")
        \\    free(log)
        \\
    );
}

test "x else trap is the assert-unwrap" {
    try expectOk(
        \\func main():
        \\    let n = parse_int("12") else trap("unreachable")
        \\    assert(n == 12)
        \\
    );
    try expectTrap(
        \\func main():
        \\    var text = "not a number"
        \\    let n = parse_int(text) else trap("bad input")
        \\    assert(n == 0)
        \\
    , .explicit_trap);
}

test "an optional crosses a call, a return, and a struct field" {
    try expectOk(
        \\struct Setting:
        \\    name: String
        \\    limit: Int?
        \\
        \\func describe(limit: Int?) -> String:
        \\    if limit == none:
        \\        return "unlimited"
        \\    return str(limit)
        \\
        \\func lookup(found: Bool) -> Int?:
        \\    if found:
        \\        return 4
        \\    return none
        \\
        \\func main():
        \\    assert(describe(none) == "unlimited")
        \\    assert(describe(9) == "9")
        \\    assert(describe(lookup(true)) == "4")
        \\    assert(describe(lookup(false)) == "unlimited")
        \\    let open = Setting(name = "open", limit = none)
        \\    let capped = Setting(name = "capped", limit = 10)
        \\    assert(open.limit == none)
        \\    assert(describe(capped.limit) == "10")
        \\
    );
}

test "a value struct may hold an optional of itself, and walking it terminates" {
    // `Node?` gives a struct a finite shape where `Node` could not:
    // the recursion stops at absence rather than at a layout, so a
    // linked list of value structs falls out with no new machinery
    // and no reference counting anywhere.
    try expectOk(
        \\struct Node:
        \\    value: Int
        \\    next: Node?
        \\
        \\func total(head: Node?) -> Int:
        \\    var sum = 0
        \\    var walk = head
        \\    while walk != none:
        \\        sum = sum + walk.value
        \\        walk = walk.next
        \\    return sum
        \\
        \\func main():
        \\    let three = Node(value = 3, next = none)
        \\    let two = Node(value = 2, next = three)
        \\    let one = Node(value = 1, next = two)
        \\    assert(total(one) == 6)
        \\    assert(total(none) == 0)
        \\
    );
}

test "a compound assignment combines at the payload and stays present" {
    try expectOk(
        \\func main():
        \\    var n: Int? = none
        \\    n = 10
        \\    n += 5
        \\    n *= 2
        \\    assert(n == 30)
        \\    var s: String? = "a"
        \\    s += "b"
        \\    assert(s == "ab")
        \\
    );
}

test "absence survives a round trip through a struct field and a var" {
    try expectOk(
        \\struct Slot:
        \\    held: String?
        \\
        \\func main():
        \\    var slot = Slot(held = none)
        \\    assert(slot.held == none)
        \\    slot.held = "there"
        \\    assert(slot.held != none)
        \\    assert((slot.held else "") == "there")
        \\    slot.held = none
        \\    assert(slot.held == none)
        \\
    );
}

// ---------------------------------------------------------------------------
// Runtime traps: one program per stable TrapCode
// ---------------------------------------------------------------------------

test "trap: integer overflow on addition" {
    try expectTrap(
        \\func main():
        \\    var x = 9223372036854775807
        \\    x = x + 1
        \\
    , .integer_overflow);
}

test "trap: integer overflow negating the minimum" {
    try expectTrap(
        \\func main():
        \\    var n = 0 - 9223372036854775807
        \\    n = n - 1
        \\    let bad = 0 - n
        \\
    , .integer_overflow);
}

test "trap: integer overflow taking abs of the minimum" {
    try expectTrap(
        \\func main():
        \\    var n = 0 - 9223372036854775807
        \\    n = n - 1
        \\    let bad = abs(n)
        \\
    , .integer_overflow);
}

test "trap: divide by zero" {
    try expectTrap(
        \\func main():
        \\    var z = 0
        \\    let bad = 1 / z
        \\
    , .divide_by_zero);
}

test "trap: remainder by zero" {
    try expectTrap(
        \\func main():
        \\    var z = 0
        \\    let bad = 1 % z
        \\
    , .divide_by_zero);
}

test "trap: float-to-int conversion out of range" {
    try expectTrap(
        \\func main():
        \\    var big = 1.0
        \\    while big < 1.0e30:
        \\        big = big * 10.0
        \\    let bad = Int(big)
        \\
    , .conversion_range);
}

test "trap: a failed assertion" {
    try expectTrap(
        \\func main():
        \\    var ok = false
        \\    assert(ok)
        \\
    , .assertion_failed);
}

test "trap: an explicit trap call" {
    try expectTrap(
        \\func main():
        \\    trap("stop here")
        \\
    , .explicit_trap);
}

test "trap: list index out of bounds" {
    try expectTrap(
        \\func main():
        \\    var xs = [1, 2, 3]
        \\    let bad = xs[3]
        \\
    , .index_bounds);
}

test "trap: array index out of bounds" {
    try expectTrap(
        \\func main():
        \\    var grid = new Array(Int, 2, 2)
        \\    grid[2, 0] = 1
        \\
    , .index_bounds);
}

test "trap: missing map key" {
    try expectTrap(
        \\func main():
        \\    var m = new Map(String, Int)
        \\    m["present"] = 1
        \\    let bad = m["absent"]
        \\
    , .key_missing);
}

test "trap: popping an empty list" {
    try expectTrap(
        \\func main():
        \\    var xs = new List(Int)
        \\    let bad = xs.pop()
        \\
    , .empty_collection);
}

test "trap: string index out of bounds" {
    try expectTrap(
        \\func main():
        \\    var s = "ab"
        \\    let bad = s[0:9]
        \\
    , .string_bounds);
}

test "trap: byte_at past the end of a string" {
    try expectTrap(
        \\func main():
        \\    var s = "ab"
        \\    let bad = s.byte_at(5)
        \\
    , .string_bounds);
}

test "trap: slicing through the middle of a UTF-8 character" {
    try expectTrap(
        \\func main():
        \\    var s = "🙂"
        \\    let bad = s[0:1]
        \\
    , .string_boundary);
}

test "trap: use after free" {
    try expectTrap(
        \\func main():
        \\    var xs = [1, 2]
        \\    let view = xs
        \\    free(xs)
        \\    let bad = view[0]
        \\
    , .use_after_free);
}

test "trap: using an unfilled late object slot" {
    try expectTrap(
        \\func main():
        \\    var xs: List(Int)
        \\    let bad = len(xs)
        \\
    , .null_object);
}

test "trap: unfilled object slot inside an array of objects" {
    try expectTrap(
        \\func main():
        \\    var cells = new Array(List(Int), 2)
        \\    cells[0].append(1)
        \\
    , .null_object);
}

test "trap: chr of a codepoint beyond Unicode's range" {
    try expectTrap(
        \\func main():
        \\    var code = 11141111
        \\    let bad = chr(code)
        \\
    , .bad_codepoint);
}

test "trap: ord of an empty string" {
    try expectTrap(
        \\func main():
        \\    var s = ""
        \\    let bad = ord(s)
        \\
    , .bad_codepoint);
}
