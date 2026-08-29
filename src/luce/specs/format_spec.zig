//! A serialized module survives a round trip as the same program.
//!
//! `mir/module.zig` proves the *format*: what encodes, what decodes,
//! what the verifier refuses, and that a damaged module can never
//! crash a decoder.  Those are all facts about bytes and live beside
//! the encoder.
//!
//! This is the one fact about a `.lcm` that is a fact about the
//! language: a module written out and read back is the same program —
//! it computes the same answers, on both engines, and the artifact is
//! keyed on those bytes (`artifact.sourceHash`), so a round trip that
//! changed anything would change what a cached artifact runs.

const std = @import("std");
const agree = @import("agree.zig");
const luce = @import("luce");
const mir = luce.mir;

const testing = std.testing;

test "a module encoded and decoded again is the same program on both engines" {
    var program = try agree.program(
        \\struct Point:
        \\    var x: i64
        \\    var y: i64
        \\
        \\func twice(value: i64) -> i64:
        \\    return value * 2
        \\
        \\func main():
        \\    var xs = list[i64]()
        \\    for i in range(0, 8):
        \\        xs.append(twice(i))
        \\    let here = Point(x = xs[3], y = len(xs))
        \\    assert(here.x == 6 and here.y == 8)
        \\    assert(twice(21) == 42)
        \\    print(str(xs[7]) + " " + str(here.x))
        \\
    );
    defer program.deinit();

    const encoded = try mir.module.encode(testing.allocator, &program);
    defer testing.allocator.free(encoded);
    var loaded = try mir.module.decode(testing.allocator, encoded);
    defer loaded.deinit();

    var direct = try agree.compareProgram(&program, .{});
    defer direct.deinit();
    var round_tripped = try agree.compareProgram(&loaded, .{});
    defer round_tripped.deinit();

    // The two engines agreed on each of them; now the two *programs*
    // have to agree with each other.
    try testing.expectEqualStrings(direct.printed(), round_tripped.printed());
    try testing.expectEqual(direct.end, round_tripped.end);

    // And the bytes are stable, which is what makes them an artifact
    // key: re-encoding what was decoded is byte-identical.
    const again = try mir.module.encode(testing.allocator, &loaded);
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(u8, encoded, again);
}

test "optimized object graphs execute after module round-trip" {
    // This is the composition that a shape-only round-trip test cannot
    // prove: a union carries a list of value structs, a match arm binds
    // one struct as a bound method, and an enclosing struct carries a
    // second callback.  Encode the already optimized MIR, then run the
    // decoded program through both engines.
    var program = try agree.program(
        \\struct Item:
        \\    let prefix: str
        \\    let scale: i64
        \\    func render(value: i64) -> str:
        \\        return self.prefix + str(value * self.scale)
        \\
        \\union Work:
        \\    empty
        \\    batch(items: list[Item])
        \\
        \\struct Plan:
        \\    let work: Work
        \\    let finish: (func(i64) -> str)? = none
        \\
        \\func suffix(value: i64) -> str:
        \\    return "!" + str(value)
        \\
        \\func consume(values: list[i64]) -> i64:
        \\    var total: i64 = 0
        \\    for value in values:
        \\        total = total + value
        \\    return total
        \\
        \\struct Counter:
        \\    var value: i64
        \\    func add(amount: i64):
        \\        self.value = self.value + amount
        \\
        \\func evaluate(plan: Plan) -> str:
        \\    let finish = plan.finish
        \\    match plan.work:
        \\        empty:
        \\            return "empty"
        \\        batch(items):
        \\            let render: func(i64) -> str = items[0].render
        \\            if finish != none:
        \\                return render(4) + finish(5)
        \\            return render(4)
        \\
        \\func main():
        \\    var values: list[i64] = [1, 2, 3]
        \\    assert(consume(values) == 6)
        \\    var counter = Counter(value = 1)
        \\    counter.add(2)
        \\    assert(counter.value == 3)
        \\
        \\    var items = list[Item]()
        \\    items.append(Item(prefix = "item", scale = 2))
        \\    let plan = Plan(work = Work.batch(items = items), finish = suffix)
        \\    print(evaluate(plan))
        \\
    );
    defer program.deinit();

    const encoded = try mir.module.encode(testing.allocator, &program);
    defer testing.allocator.free(encoded);
    var loaded = try mir.module.decode(testing.allocator, encoded);
    defer loaded.deinit();

    var direct = try agree.compareProgram(&program, .{});
    defer direct.deinit();
    var round_tripped = try agree.compareProgram(&loaded, .{});
    defer round_tripped.deinit();

    try testing.expectEqualStrings("item8!5\n", direct.printed());
    try testing.expectEqualStrings(direct.printed(), round_tripped.printed());
    try testing.expectEqual(direct.end, round_tripped.end);
}
