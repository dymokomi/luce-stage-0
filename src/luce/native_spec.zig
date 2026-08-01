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
const image = @import("image.zig");
const codegen = @import("codegen.zig");

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

/// Run a program through the zig backend's full pipeline — emit,
/// map into fresh executable pages, execute with native.runCode.
fn runZigBackend(
    arena: std.mem.Allocator,
    program: *const ir.Program,
    budget: backend.Budget,
) !Outcome {
    var capture: Capture = .{ .arena = arena };
    const outputs = try arena.alloc(?backend.RuntimeValue, 0);
    const spans = try codegen.compile(arena, program);
    var loaded = try image.map(testing.allocator, spans);
    defer loaded.deinit(testing.allocator);
    const result = try native.runCode(arena, program, loaded.addresses, &.{}, outputs, budget, capture.host());
    return .{ .result = result, .printed = capture.lines.items };
}

fn expectSameOutcome(reference: Outcome, candidate: Outcome) !void {
    try testing.expectEqualStrings(reference.printed, candidate.printed);
    try testing.expectEqual(
        std.meta.activeTag(reference.result),
        std.meta.activeTag(candidate.result),
    );
    if (reference.result == .trap) {
        try testing.expectEqual(reference.result.trap.code, candidate.result.trap.code);
        try testing.expectEqualStrings(reference.result.trap.message, candidate.result.trap.message);
    }
}

/// Compile, run under every engine, and demand identical outcomes —
/// the interpreter is the reference, the MIR engine and the zig
/// backend the candidates.
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

    try expectSameOutcome(reference, candidate);
    if (reference.result == .success) {
        try testing.expectEqual(
            reference.result.success.leaked_objects,
            candidate.result.success.leaked_objects,
        );
    }
    // The zig backend runs every program it claims support for,
    // identically to the reference.  On aarch64 its gate is the whole
    // MIR core, so it must cover every oracle program (the strong
    // assert stays); the x86-64 backend's milestone-1 gate is the
    // scalar arithmetic core, so there it runs on the programs it
    // takes and MIR proves it right on the rest.
    if (codegen.available) {
        const covers = codegen.supported(program);
        if (@import("builtin").cpu.arch == .aarch64) try testing.expect(covers);
        if (covers) {
            const third = try runZigBackend(arena.allocator(), program, budget);
            try expectSameOutcome(reference, third);
            if (reference.result == .success) {
                try testing.expectEqual(
                    reference.result.success.leaked_objects,
                    third.result.success.leaked_objects,
                );
            }
        }
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

test "oracle: a pinned parameter drives a loop and accumulates" {
    // The x86 backend pins the first integer/heap locals to callee-saved
    // registers.  A binary op whose left operand is such a pinned value
    // (an alias, never a scratch register) once let the destination reuse
    // the *right* operand's register, which `mov dest, left` then
    // clobbered — turning `i + 1` into `i + i` and `s + n` into `s + s`.
    // The bound is read from the pinned register and the sum feeds back
    // into another, so a corrupt right operand diverges immediately.
    try oracle(
        \\func total(n: Int) -> Int:
        \\    var s = 0
        \\    var i = 0
        \\    while i < n:
        \\        s = s + i * 2 - 1
        \\        i = i + 1
        \\    return s
        \\func main():
        \\    print(str(total(9)))
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

// ---------------------------------------------------------------------------
// Milestone 2: collections, ownership, structs, strings — the
// generic services route every heap-shaped instruction through the
// interpreter's own machine, and the oracle proves it.
// ---------------------------------------------------------------------------

test "oracle: lists grow, index, slice, sort, and free" {
    try oracle(
        \\func main():
        \\    var xs = [3, 1, 4, 1, 5, 9, 2, 6]
        \\    xs.append(53)
        \\    xs.insert(0, 58)
        \\    xs.remove(1)
        \\    xs.sort()
        \\    var total = 0
        \\    for x in xs:
        \\        total += x
        \\    print(str(total))
        \\    print(str(xs.find(9)))
        \\    print(str(xs.contains(58)))
        \\    print(str(xs.pop()))
        \\    let front = xs[0:3]
        \\    print(str(len(front)))
        \\    xs.reverse()
        \\    print(str(xs[0]))
        \\    xs.clear()
        \\    print(str(len(xs)))
        \\
    , roomy);
}

test "oracle: maps insert, look up, iterate, and report misses" {
    try oracle(
        \\import strings
        \\
        \\func main():
        \\    var ages = new Map(String, Int)
        \\    ages["ada"] = 36
        \\    ages["alan"] = 41
        \\    ages["ada"] = 37
        \\    print(str(len(ages)))
        \\    print(str(ages["ada"]))
        \\    print(str(ages.has("alan")))
        \\    print(str(ages.get("grace", 0)))
        \\    for name, age in ages:
        \\        print(f"{name}: {age}")
        \\    let keys = ages.keys()
        \\    print(keys.join(","))
        \\    ages.remove("alan")
        \\    print(str(len(ages)))
        \\
    , roomy);
    try oracle(
        \\func main():
        \\    var m = new Map(Int, Int)
        \\    let missing = m[7]
        \\
    , roomy);
}

test "oracle: arrays fill, index in two dimensions, and bound-check" {
    try oracle(
        \\func main():
        \\    var grid = new Array(Int, 3, 4)
        \\    grid.fill(7)
        \\    grid[2, 3] = 42
        \\    var total = 0
        \\    for r in range(0, 3):
        \\        for c in range(0, 4):
        \\            total += grid[r, c]
        \\    print(str(total))
        \\    print(str(grid.dim(0) * grid.dim(1)))
        \\
    , roomy);
    try oracle(
        \\func edge() -> Int:
        \\    return 5
        \\
        \\func main():
        \\    var row = new Array(Int, 5)
        \\    print(str(row[edge()]))
        \\
    , roomy);
}

test "oracle: builders accumulate and str() them" {
    try oracle(
        \\func main():
        \\    var b = new Builder()
        \\    for i in range(0, 5):
        \\        b.append(str(i * i))
        \\        b.append(";")
        \\    print(str(b))
        \\    print(str(len(b)))
        \\    b.clear()
        \\    print(str(len(b)))
        \\
    , roomy);
}

test "oracle: string concat, comparison, slices, and byte access" {
    try oracle(
        \\func main():
        \\    let a = "loom"
        \\    let b = a + "!"
        \\    print(b)
        \\    print(str(a == "loom"))
        \\    print(str(a != b))
        \\    print(str("abc" < "abd"))
        \\    print(b[0:2])
        \\    print(str(len("a🙂b")))
        \\    print(str("a🙂b"[1:5]))
        \\    print(str("na".byte_at(0)))
        \\    print(str(chr(955)))
        \\    print(str(ord("λ")))
        \\    print(str(parse_int("42") + 1))
        \\    print(str(parse_float("2.5") * 2.0))
        \\
    , roomy);
    // A slice that splits a codepoint traps identically.
    try oracle(
        \\func edge() -> Int:
        \\    return 2
        \\
        \\func main():
        \\    let s = "a🙂b"
        \\    print(s[0:edge()])
        \\
    , roomy);
    try oracle(
        \\func main():
        \\    let n = parse_int("not a number")
        \\
    , roomy);
}

test "oracle: find_byte scans and append_ascii builds identically" {
    try oracle(
        \\func main():
        \\    let s = "hello world, hello"
        \\    print(str(s.find_byte(111, 0)))
        \\    print(str(s.find_byte(111, 5)))
        \\    print(str(s.find_byte(122, 0)))
        \\    print(str(s.find_byte(104, len(s))))
        \\    print(str("".find_byte(97, 0)))
        \\    let u = "aλb🙂c"
        \\    print(str(u.find_byte(98, 0)))
        \\    print(str(u.find_byte(99, 0)))
        \\    var out = new Builder()
        \\    for code in range(65, 91):
        \\        out.append_ascii(code)
        \\    print(str(out))
        \\    print(str(str(out) == "ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
        \\
    , roomy);
    // Every rejection the two engines must share: a byte outside
    // 0..255, a start past the end, and a non-ASCII append.
    try oracle(
        \\func main():
        \\    print(str("abc".find_byte(256, 0)))
        \\
    , roomy);
    try oracle(
        \\func main():
        \\    print(str("abc".find_byte(97, -1)))
        \\
    , roomy);
    try oracle(
        \\func main():
        \\    print(str("abc".find_byte(97, 4)))
        \\
    , roomy);
    try oracle(
        \\func main():
        \\    var out = new Builder()
        \\    out.append_ascii(200)
        \\    print(str(out))
        \\
    , roomy);
}

test "oracle: the std strings module runs natively" {
    try oracle(
        \\import strings
        \\
        \\func main():
        \\    let text = "  Hello, Luce World  "
        \\    let cleaned = text.trim()
        \\    print(cleaned)
        \\    print(str(cleaned.find("Luce")))
        \\    print(cleaned.upper())
        \\    print(cleaned.replace("Luce", "native"))
        \\    let pieces = "a;b;;c".split(";")
        \\    print(str(len(pieces)))
        \\    print(pieces.join("|"))
        \\    print(strings.format_float(2.345, 2))
        \\    print(strings.pad_left("7", 3))
        \\
    , roomy);
}

test "oracle: the std math module runs natively" {
    try oracle(
        \\import math
        \\
        \\func close(a: Float, b: Float) -> Bool:
        \\    return abs(a - b) < 0.000000001
        \\
        \\func main():
        \\    print(str(math.ipow(2, 10)))
        \\    print(str(close(math.exp(math.ln(7.5)), 7.5)))
        \\    print(str(close(math.pow(2.0, 10.0), 1024.0)))
        \\    print(str(math.round(-2.5)))
        \\    var rng = math.seed(42)
        \\    print(str(math.random_int(rng, 1, 7)))
        \\    print(str(sqrt(49.0) + floor(2.9) + ceil(0.1)))
        \\    print(str(min(3, 7) + max(3, 7) + clamp(10, 0, 5)))
        \\
    , roomy);
}

test "the zig backend agrees with the interpreter on its integer core" {
    // The self-written backend (codegen.zig, docs/SPEED.md §16) held
    // to the same contract as every other engine: identical prints,
    // trap codes, and messages, through the real pipeline — emit,
    // map into executable pages, run with native.runCode.  The
    // corpus walks the whole M0 surface: nested loops, every checked
    // arithmetic trap, comparisons, branches, negation, not,
    // literals, assert, trap messages, and str(Int) formatting.
    if (!codegen.available) return;
    const sources = [_][]const u8{
        \\func main():
        \\    var total = 0
        \\    for i in range(0, 40):
        \\        for j in range(0, 40):
        \\            total += (i * j) % 7 - i / 3
        \\    print(str(total))
        \\    print(str(-total))
        \\    print(str(total == 1867))
        \\
        ,
        \\func main():
        \\    var a = 9223372036854775807
        \\    var b = a
        \\    print(str(a + b))
        \\
        ,
        \\func main():
        \\    var z = 0
        \\    print(str(10 / z))
        \\
        ,
        \\func main():
        \\    var z = 0
        \\    print(str(10 % z))
        \\
        ,
        \\func main():
        \\    var lowest = -9223372036854775807 - 1
        \\    var minus = 1 - 2
        \\    print(str(lowest / minus))
        \\
        ,
        \\func main():
        \\    var lowest = -9223372036854775807 - 1
        \\    print(str(-lowest))
        \\
        ,
        \\func main():
        \\    var lowest = -9223372036854775807 - 1
        \\    var seven = 7
        \\    print(str(lowest / seven))
        \\    print(str(lowest % seven))
        \\    print(str(0 - 3 % 2))
        \\
        ,
        \\func main():
        \\    var flag = 5 > 3
        \\    if not flag:
        \\        print("wrong")
        \\    else:
        \\        print("right")
        \\    var n = 1
        \\    while n < 1000:
        \\        n = n * 3
        \\    print(str(n))
        \\
        ,
        // Register pressure: a balanced expression five levels deep
        // holds more temporaries than the four-register scratch pool,
        // so eviction and reload must both work.
        \\func main():
        \\    var a = 3
        \\    var b = 5
        \\    var c = 7
        \\    var d = 11
        \\    print(str(((((a + b) * (c + d)) + ((a + c) * (b + d))) * (((a + d) * (b + c)) + ((a * b) + (c * d)))) + ((((b + c) * (a + d)) + ((b * d) + (a * c))) * (((c + d) * (a + b)) + ((d * a) + (c * b))))))
        \\
        ,
        // Immediate-form edges: 4095 is the widest add/cmp immediate,
        // 4096 falls back to a register; negative immediates flip the
        // op with the same flags.
        \\func main():
        \\    var x = 100
        \\    print(str(x + 4095))
        \\    print(str(x + 4096))
        \\    print(str(x - 4095))
        \\    print(str(4095 - x))
        \\    print(str(x + 0 - 4096))
        \\    print(str(x > 4095))
        \\    print(str(4095 > x))
        \\
        ,
        // A constant -1 divisor keeps the MIN guard (and must trap);
        // constant benign divisors elide every guard.
        \\func main():
        \\    var lowest = -9223372036854775807 - 1
        \\    print(str(lowest / 7))
        \\    print(str(lowest % 7))
        \\    print(str(lowest / -1))
        \\
        ,
        \\func main():
        \\    var answer = 41
        \\    assert(answer == 42)
        \\
        ,
        \\func main():
        \\    print("before")
        \\    trap("torn seam")
        \\
    };
    for (sources) |source| {
        var result = try compile_mod.compile(testing.allocator, source, .{}, script);
        defer result.deinit();
        try testing.expect(result == .success);
        const program = &result.success;
        try testing.expect(codegen.supported(program));

        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const reference = try runEngine(arena.allocator(), program, roomy, .interpreter);

        const spans = try codegen.compile(arena.allocator(), program);
        var loaded = try image.map(testing.allocator, spans);
        defer loaded.deinit(testing.allocator);
        var capture: Capture = .{ .arena = arena.allocator() };
        const outputs = try arena.allocator().alloc(?backend.RuntimeValue, 0);
        const candidate = try native.runCode(
            arena.allocator(),
            program,
            loaded.addresses,
            &.{},
            outputs,
            roomy,
            capture.host(),
        );
        try testing.expectEqualStrings(reference.printed, capture.lines.items);
        try testing.expectEqual(
            std.meta.activeTag(reference.result),
            std.meta.activeTag(candidate),
        );
        if (reference.result == .trap) {
            try testing.expectEqual(reference.result.trap.code, candidate.trap.code);
            try testing.expectEqualStrings(reference.result.trap.message, candidate.trap.message);
        }
    }
}

test "the image is a third engine with identical semantics" {
    // The full milestone-5b pipeline — compile, capture, encode,
    // decode, map into fresh executable pages, run with no MIR
    // context — held to the oracle's contract: prints and traps
    // identical to the interpreter, on a program that computes and
    // on one that traps (origins resolve from the .lc side, never
    // from code).
    if (!native.available or !image.supported) return;
    const sources = [_][]const u8{
        \\import strings
        \\
        \\func shout(text: String) -> String:
        \\    return text.upper()
        \\
        \\func main():
        \\    var xs: List(Int) = [3, 1, 2]
        \\    xs.sort()
        \\    print(f"{xs[0]}{xs[1]}{xs[2]} {shout("ok")} {1.5 * 4.0}")
        \\
        ,
        \\func half(value: Int) -> Int:
        \\    return 10 / value
        \\
        \\func main():
        \\    print(str(half(2)))
        \\    print(str(half(0)))
        \\
    };
    for (sources) |source| {
        var result = try compile_mod.compile(testing.allocator, source, .{}, script);
        defer result.deinit();
        try testing.expect(result == .success);
        const program = &result.success;
        try testing.expect(native.supported(program));

        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const reference = try runEngine(arena.allocator(), program, roomy, .interpreter);

        // Capture through the real cache pipeline.
        const keys: image.Keys = .{
            .fingerprint = native.fingerprint(),
            .module_hash = 1,
            .text_hash = try native.textHash(arena.allocator(), program),
        };
        const compiled = try native.compile(arena.allocator(), program);
        const spans = try arena.allocator().alloc([]const u8, program.functions.len);
        for (spans, 0..) |*span, index| span.* = compiled.code(index);
        const encoded = try image.encode(arena.allocator(), spans, keys);
        compiled.deinit(); // the image must carry the code on its own

        const decoded = try image.decode(arena.allocator(), encoded, keys, program.functions.len);
        var loaded = try image.map(testing.allocator, decoded);
        defer loaded.deinit(testing.allocator);

        var capture: Capture = .{ .arena = arena.allocator() };
        const outputs = try arena.allocator().alloc(?backend.RuntimeValue, 0);
        const candidate = try native.runCode(
            arena.allocator(),
            program,
            loaded.addresses,
            &.{},
            outputs,
            roomy,
            capture.host(),
        );
        try testing.expectEqualStrings(reference.printed, capture.lines.items);
        try testing.expectEqual(
            std.meta.activeTag(reference.result),
            std.meta.activeTag(candidate),
        );
        if (reference.result == .trap) {
            try testing.expectEqual(reference.result.trap.code, candidate.trap.code);
            try testing.expectEqualStrings(reference.result.trap.message, candidate.trap.message);
        }
    }
}

test "hermeticity: generated code is byte-identical across contexts" {
    // The M1 contract (docs/NATIVE.md milestone 5): the emitted code
    // contains no host address — services, constant descriptors, and
    // Luce function targets are all read from the State address
    // table at run time.  Two compilations in two fresh MIR contexts
    // land their code and their would-be addresses at different
    // places; if any address leaked into the code, the bytes differ.
    // Covers every absolute-address class the audit inventoried:
    // service calls (print, builder, generic), constant descriptors,
    // the "" zero value, inter-function calls, float constants,
    // array views, and string access.
    if (!native.available) return;
    const source =
        \\import strings
        \\
        \\struct Point:
        \\    x: Float
        \\    y: Float
        \\
        \\func total(p: Point, tail: String) -> Float:
        \\    var zero: String
        \\    assert(zero == "")
        \\    return p.x + p.y + Float(len(tail))
        \\
        \\func main():
        \\    var b = new Builder()
        \\    var grid = new Array(Float, 3)
        \\    for i in range(0, 3):
        \\        grid[i] = Float(i) * 1.5
        \\        b.append(str(i))
        \\        b.append_ascii(59)
        \\    let text = str(b)
        \\    let pieces = text.split(";")
        \\    let p = Point(x = grid[1], y = grid[2])
        \\    print(str(total(p, text.upper())))
        \\    print(str(len(pieces) + text.find_byte(59, 0) + Int(p.x)))
        \\
    ;
    var result = try compile_mod.compile(testing.allocator, source, .{}, script);
    defer result.deinit();
    try testing.expect(result == .success);
    try testing.expect(native.supported(&result.success));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Both contexts stay alive until after the comparison: a
    // sequential compile-free-compile can land its allocations at
    // the exact addresses the freed context vacated, and identical
    // baked-in addresses would read as identical bytes.  That
    // masking is precisely how the float-constant leak (module data
    // items, milestone 5b) escaped this oracle's first edition.
    const first = try native.compile(arena.allocator(), &result.success);
    defer first.deinit();
    const second = try native.compile(arena.allocator(), &result.success);
    defer second.deinit();
    try testing.expectEqual(first.addresses.len, second.addresses.len);
    for (0..first.addresses.len) |index| {
        const one = first.code(index);
        const two = second.code(index);
        try testing.expect(one.len > 0);
        try testing.expect(first.addresses[index] != second.addresses[index]);
        testing.expectEqualSlices(u8, one, two) catch |mistake| {
            std.debug.print("function {d} code differs between contexts\n", .{index});
            return mistake;
        };
    }
}

test "oracle: struct equality is field-wise in both engines" {
    // A struct travels natively as its field-array address, so a
    // naive lowering compares pointers and calls equal structs
    // unequal — the exact bug this corpus exists to catch.
    try oracle(
        \\struct Point:
        \\    x: Int
        \\    y: Int
        \\
        \\struct Tag:
        \\    name: String
        \\    at: Point
        \\
        \\func make(x: Int, y: Int) -> Point:
        \\    return Point(x = x, y = y)
        \\
        \\func main():
        \\    print(str(make(1, 2) == make(1, 2)))
        \\    print(str(make(1, 2) == make(1, 3)))
        \\    print(str(make(1, 2) != make(1, 2)))
        \\    let a = Tag(name = "he" + "llo", at = make(4, 5))
        \\    let b = Tag(name = "hello", at = make(4, 5))
        \\    let c = Tag(name = "hello", at = make(4, 6))
        \\    print(str(a == b))
        \\    print(str(a == c))
        \\    print(str(a != c))
        \\
    , roomy);
}

test "oracle: structs make, read, rebuild, and nest" {
    try oracle(
        \\struct Point:
        \\    x: Float
        \\    y: Float
        \\
        \\struct Box:
        \\    corner: Point
        \\    label: String
        \\    count: Int
        \\
        \\func shifted(p: Point, dx: Float) -> Point:
        \\    return Point(x = p.x + dx, y = p.y)
        \\
        \\func main():
        \\    var box = Box(corner = Point(x = 1.0, y = 2.0), label = "crate", count = 3)
        \\    box.count += 4
        \\    box.corner.x = 9.5
        \\    print(str(box.count))
        \\    print(str(box.corner.x))
        \\    print(box.label)
        \\    let moved = shifted(box.corner, 0.5)
        \\    print(str(moved.x))
        \\    var early: Point
        \\    print(str(early.x))
        \\
    , roomy);
}

test "oracle: ownership — give, copy, free, and the traps" {
    try oracle(
        \\func take(xs: give List(Int)) -> Int:
        \\    return len(xs)
        \\
        \\func main():
        \\    var xs = [1, 2, 3]
        \\    print(str(take(give xs)))
        \\
    , roomy);
    try oracle(
        \\func main():
        \\    var xs = [1, 2, 3]
        \\    var snapshot = copy xs
        \\    xs.append(4)
        \\    print(str(len(xs)))
        \\    print(str(len(snapshot)))
        \\    free(xs)
        \\    print(str(len(snapshot)))
        \\
    , roomy);
    // Use after free through an alias traps identically.
    try oracle(
        \\func main():
        \\    var xs = [1, 2, 3]
        \\    let alias = xs
        \\    free(xs)
        \\    print(str(len(alias)))
        \\
    , roomy);
    // S23: the alias dodge is caught dynamically, either engine.
    try oracle(
        \\func main():
        \\    var a = new List(List(Int))
        \\    var b = new List(List(Int))
        \\    var item = [2]
        \\    let alias = item
        \\    a.append(give item)
        \\    b.append(give alias)
        \\
    , roomy);
    // Two distinct heap objects live at once, each bound to its own
    // name, the first freed and the second released at scope exit.  The
    // second object's handle is non-zero, so a generic instruction that
    // failed to marshal its object operand (leaving a stale slot) would
    // bind or free the wrong object — an ownership divergence the
    // single-object cases above cannot see.
    try oracle(
        \\func main():
        \\    var xs = [3, 1, 4]
        \\    xs.sort()
        \\    var m = new Map(String, Int)
        \\    m["ada"] = 36
        \\    print(str(xs[0]))
        \\    print(str(m["ada"]))
        \\    free(xs)
        \\    free(m)
        \\
    , roomy);
}

test "oracle: nested containers free recursively with zero leaks" {
    try oracle(
        \\func build() -> List(List(Int)):
        \\    var rows: List(List(Int)) = []
        \\    for i in range(0, 10):
        \\        var row: List(Int) = []
        \\        for j in range(0, 10):
        \\            row.append(i * j)
        \\        rows.append(give row)
        \\    return rows
        \\
        \\func main():
        \\    var rows = build()
        \\    var total = 0
        \\    for row in rows:
        \\        total += row[9]
        \\    print(str(total))
        \\
    , roomy);
}

test "oracle: hostless file access traps identically" {
    try oracle(
        \\func main():
        \\    let text = file_read("nowhere.txt")
        \\
    , roomy);
}

test "oracle: the sort program shape agrees end to end" {
    try oracle(
        \\import strings
        \\
        \\func main():
        \\    var values = [42, 7, -3, 99, 0, 13, -40, 8, 77, 1]
        \\    values.sort()
        \\    var pieces: List(String) = []
        \\    for value in values:
        \\        pieces.append(str(value))
        \\    print(pieces.join(" "))
        \\    assert(values.find(13) == 6)
        \\    assert(values.contains(99))
        \\
    , roomy);
}

test "only ports and the Bytes stub stay off the native core" {
    var result = try compile_mod.compile(testing.allocator,
        \\func evaluate(input: Input, output: Output):
        \\    output.value = input.value * 2
        \\
    , .{
        .inputs = &.{.{ .name = "value", .declared = .int }},
        .outputs = &.{.{ .name = "value", .declared = .int }},
    }, .{});
    defer result.deinit();
    try testing.expect(!native.supported(&result.success));
}
