//! The two-engine oracle: every program here runs on the interpreter
//! (the reference implementation) and on the native engine, and the
//! outcomes must agree — prints byte for byte, traps code for code,
//! messages included.  This is how Zig keeps its self-hosted
//! backends honest against LLVM, applied to loom's engines.

const std = @import("std");
const compile_mod = @import("compile.zig");
const types = @import("types.zig");
const ir = @import("ir.zig");
const backend = @import("backend.zig");
const interpreter = @import("interpreter.zig");
const native = @import("native.zig");

const testing = std.testing;

const script: types.CompileOptions = .{ .entry_mode = .script, .allow_host = true };

/// Print capture: the same host both engines get.
const Capture = struct {
    arena: Allocator,
    lines: std.ArrayList(u8) = .empty,

    const Allocator = std.mem.Allocator;

    fn printLine(context: *anyopaque, text: []const u8) error{OutOfMemory}!void {
        const self: *Capture = @ptrCast(@alignCast(context));
        try self.lines.appendSlice(self.arena, text);
        try self.lines.append(self.arena, '\n');
    }

    fn host(self: *Capture) backend.Host {
        return .{ .context = self, .printFn = &printLine };
    }
};

const Outcome = struct {
    result: backend.Result,
    printed: []const u8,
};

fn runEngine(
    arena: std.mem.Allocator,
    program: *const ir.Program,
    budget: backend.Budget,
    engine: enum { interpreter, native },
) !Outcome {
    var capture: Capture = .{ .arena = arena };
    const outputs = try arena.alloc(?backend.RuntimeValue, 0);
    const result = switch (engine) {
        .interpreter => try interpreter.run(arena, program, &.{}, outputs, budget, capture.host()),
        .native => try native.run(arena, program, &.{}, outputs, budget, capture.host()),
    };
    return .{ .result = result, .printed = capture.lines.items };
}

/// Compile, run under both engines, and demand identical outcomes.
fn oracle(source: []const u8, budget: backend.Budget) !void {
    var result = try compile_mod.compile(testing.allocator, source, .{}, script);
    defer result.deinit();
    switch (result) {
        .failure => |*diagnostics| {
            const rendered = try diagnostics.render(testing.allocator, source);
            defer testing.allocator.free(rendered);
            std.debug.print("unexpected compile error:\n{s}", .{rendered});
            return error.TestUnexpectedResult;
        },
        .success => {},
    }
    const program = &result.success;
    try testing.expect(native.supported(program));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const reference = try runEngine(arena.allocator(), program, budget, .interpreter);
    const candidate = try runEngine(arena.allocator(), program, budget, .native);

    try testing.expectEqualStrings(reference.printed, candidate.printed);
    try testing.expectEqual(
        std.meta.activeTag(reference.result),
        std.meta.activeTag(candidate.result),
    );
    if (reference.result == .trap) {
        try testing.expectEqual(reference.result.trap.code, candidate.result.trap.code);
        try testing.expectEqualStrings(reference.result.trap.message, candidate.result.trap.message);
    }
    if (reference.result == .success) {
        try testing.expectEqual(
            reference.result.success.leaked_objects,
            candidate.result.success.leaked_objects,
        );
    }
}

const roomy: backend.Budget = .{ .steps = 50_000_000, .call_depth = 256 };

test "oracle: integer arithmetic, comparisons, and loops agree" {
    try oracle(
        \\func main():
        \\    var total = 0
        \\    for i in range(0, 100):
        \\        total += (i * i) % 7 - i / 3
        \\    print(str(total))
        \\    print(str(total == 187))
        \\    print(str(-total))
        \\    var n = 1
        \\    while n < 1000:
        \\        n = n * 3
        \\    print(str(n))
        \\
    , roomy);
}

test "oracle: float arithmetic, conversion, and formatting agree" {
    try oracle(
        \\func main():
        \\    var x = 0.1
        \\    let y = x + 0.2
        \\    print(str(y))
        \\    print(str(1.0 / 3.0))
        \\    print(str(Float(7) / 2.0))
        \\    print(str(Int(2.99)))
        \\    print(str(Int(-2.99)))
        \\    print(str(1.0e17 * 10.0))
        \\    print(str(3.5 % 2.0))
        \\    print(str(y % 0.25))
        \\    print(str(-0.0 - 1.5))
        \\    print(str(2.0 < 3.0))
        \\
    , roomy);
}

test "oracle: calls and recursion agree" {
    try oracle(
        \\func fib(n: Int) -> Int:
        \\    if n < 2:
        \\        return n
        \\    return fib(n - 1) + fib(n - 2)
        \\
        \\func choose(flag: Bool, a: Int, b: Int) -> Int:
        \\    if flag:
        \\        return a
        \\    return b
        \\
        \\func main():
        \\    print(str(fib(20)))
        \\    print(str(choose(fib(5) == 5, 1, 2)))
        \\
    , roomy);
}

test "oracle: string constants and str() agree" {
    try oracle(
        \\func main():
        \\    print("hello, native")
        \\    let text = "kept"
        \\    print(str(text))
        \\    print(str(true))
        \\    print(str(false))
        \\
    , roomy);
}

test "oracle: integer overflow traps identically" {
    try oracle(
        \\func big() -> Int:
        \\    return 9223372036854775807
        \\
        \\func main():
        \\    print(str(big() + 1))
        \\
    , roomy);
}

test "oracle: negation overflow traps identically" {
    try oracle(
        \\func lowest() -> Int:
        \\    return -9223372036854775807 - 1
        \\
        \\func main():
        \\    print(str(-lowest()))
        \\
    , roomy);
}

test "oracle: division traps identically" {
    try oracle(
        \\func zero() -> Int:
        \\    return 0
        \\
        \\func main():
        \\    print(str(1 / zero()))
        \\
    , roomy);
    try oracle(
        \\func lowest() -> Int:
        \\    return -9223372036854775807 - 1
        \\
        \\func minus() -> Int:
        \\    return -1
        \\
        \\func main():
        \\    print(str(lowest() / minus()))
        \\
    , roomy);
    try oracle(
        \\func zero() -> Int:
        \\    return 0
        \\
        \\func main():
        \\    print(str(7 % zero()))
        \\
    , roomy);
}

test "oracle: conversion range traps identically" {
    try oracle(
        \\func huge() -> Float:
        \\    return 1.0e300
        \\
        \\func main():
        \\    print(str(Int(huge())))
        \\
    , roomy);
    try oracle(
        \\func zero() -> Float:
        \\    return 0.0
        \\
        \\func main():
        \\    print(str(Int(zero() / zero())))
        \\
    , roomy);
}

test "oracle: assert and explicit trap agree, message included" {
    try oracle(
        \\func answer() -> Int:
        \\    return 41
        \\
        \\func main():
        \\    assert(answer() == 42)
        \\
    , roomy);
    try oracle(
        \\func main():
        \\    trap("torn seam")
        \\
    , roomy);
}

test "oracle: the call-depth budget traps identically" {
    try oracle(
        \\func spiral(n: Int) -> Int:
        \\    return spiral(n + 1)
        \\
        \\func main():
        \\    print(str(spiral(0)))
        \\
    , .{ .steps = 50_000_000, .call_depth = 64 });
}

test "the native engine reports a source location on trap" {
    var result = try compile_mod.compile(testing.allocator,
        \\func boom(n: Int) -> Int:
        \\    return 1 / n
        \\
        \\func main():
        \\    print(str(boom(0)))
        \\
    , .{}, script);
    defer result.deinit();
    const program = &result.success;
    try testing.expect(native.supported(program));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const outcome = try runEngine(arena.allocator(), program, roomy, .native);
    try testing.expect(outcome.result == .trap);
    const trap = outcome.result.trap;
    try testing.expectEqual(ir.TrapCode.divide_by_zero, trap.code);
    try testing.expectEqual(@as(usize, 1), trap.trace.len);
    try testing.expectEqualStrings("boom", trap.trace[0].function);
    try testing.expectEqualStrings("main.luc", trap.trace[0].source);
    try testing.expectEqual(@as(u32, 2), trap.trace[0].line);
}

test "programs beyond the arithmetic core are refused, not broken" {
    var result = try compile_mod.compile(testing.allocator,
        \\func main():
        \\    var xs = [1, 2, 3]
        \\    print(str(xs[0]))
        \\
    , .{}, script);
    defer result.deinit();
    try testing.expect(!native.supported(&result.success));
}

test "string comparison stays on the interpreter for now" {
    var result = try compile_mod.compile(testing.allocator,
        \\func main():
        \\    let a = "x"
        \\    print(str(a == "x"))
        \\
    , .{}, script);
    defer result.deinit();
    try testing.expect(!native.supported(&result.success));
}
