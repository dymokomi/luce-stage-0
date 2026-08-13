//! A serialized module survives a round trip as the same program.
//!
//! `06_mir/module.zig` proves the *format*: what encodes, what decodes,
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
        \\    x: long
        \\    y: long
        \\
        \\func twice(value: long) -> long:
        \\    return value * 2
        \\
        \\func main():
        \\    var xs = new list(long)
        \\    for i in range(0, 8):
        \\        xs.append(twice(i))
        \\    let here = Point(x = xs[3], y = len(xs))
        \\    assert(here.x == 6 and here.y == 8)
        \\    assert(twice(21) == 42)
        \\    print(string(xs[7]) + " " + string(here.x))
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

test "optimized ownership graphs execute after module round-trip" {
    // This is the ownership-heavy composition that a shape-only round-trip
    // test cannot prove: an owned union carries a list of value structs, a
    // match arm borrows one struct as a bound method, and an enclosing
    // struct carries a second callback.  Encode the already optimized MIR,
    // then run the decoded program through both engines.
    var program = try agree.program(
        \\struct Item:
        \\    prefix: string
        \\    scale: long
        \\    func render(value: long) -> string:
        \\        return self.prefix + string(value * self.scale)
        \\
        \\union Work:
        \\    empty
        \\    batch(items: list(Item))
        \\
        \\struct Plan:
        \\    work: Work
        \\    finish: (func(long) -> string)? = none
        \\
        \\func suffix(value: long) -> string:
        \\    return "!" + string(value)
        \\
        \\func evaluate(plan: Plan) -> string:
        \\    let finish = plan.finish
        \\    match plan.work:
        \\        empty:
        \\            return "empty"
        \\        batch(items):
        \\            let render: func(long) -> string = items[0].render
        \\            if finish != none:
        \\                return render(4) + finish(5)
        \\            return render(4)
        \\
        \\func main():
        \\    var items = new list(Item)
        \\    items.append(Item(prefix = "item", scale = 2))
        \\    let plan = Plan(work = Work.batch(items = give items), finish = suffix)
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
