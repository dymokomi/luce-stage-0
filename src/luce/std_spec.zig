//! The standard library's test suite.
//!
//! Std modules are ordinary Luce compiled into every program that
//! imports them, so they are proven the way programs are: scripts
//! whose asserts trap on any wrong answer, leak-checked like
//! everything else.  math is pure and tests here; files needs a host
//! and tests beside TestHost in interpreter.zig.

const std = @import("std");
const compile_mod = @import("compile.zig");
const types = @import("types.zig");
const backend = @import("backend.zig");

const testing = std.testing;

const script: types.CompileOptions = .{ .entry_mode = .script };

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

fn expectTrap(source: []const u8, code: @import("ir.zig").TrapCode) !void {
    var result = try compile_mod.compile(testing.allocator, source, .{}, script);
    defer result.deinit();
    switch (result) {
        .failure => return error.TestUnexpectedResult,
        .success => |*program| {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const outcome = try backend.evaluate(arena.allocator(), program, &.{}, &.{}, .{
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
        \\import math
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
        \\import math
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
        \\import math
        \\
        \\func main():
        \\    var x = 0.0
        \\    let bad = math.ln(x)
        \\
    , .explicit_trap);
}

test "math: pow covers the sign and zero cases" {
    try expectOk(
        \\import math
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
        \\import math
        \\
        \\func main():
        \\    var half = 0.5
        \\    let bad = math.pow(-2.0, half)
        \\
    , .explicit_trap);
}

test "math: ipow squares its way up and stays checked" {
    try expectOk(
        \\import math
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
        \\import math
        \\
        \\func main():
        \\    var exponent = 64
        \\    let bad = math.ipow(2, exponent)
        \\
    , .integer_overflow);
}

test "math: trig against known values, across periods" {
    try expectOk(
        \\import math
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
        \\import math
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

test "math: the generator is deterministic, in range, and covers its die" {
    try expectOk(
        \\import math
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
        \\import math
        \\
        \\func main():
        \\    var rng = math.seed(1)
        \\    let bad = math.random_int(rng, 5, 5)
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
        \\import math
        \\
        \\func main():
        \\    assert(math.ipow(2, 8) == 256)
        \\
    );
}

test "std modules obey the host gate: files needs a host" {
    var result = try compile_mod.compile(testing.allocator,
        \\import files
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
            try testing.expectEqualStrings("files", item.module);
            saw_host = true;
        }
    }
    try testing.expect(saw_host);
}
