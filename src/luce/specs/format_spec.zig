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
        \\    x: Int
        \\    y: Int
        \\
        \\func twice(value: Int) -> Int:
        \\    return value * 2
        \\
        \\func main():
        \\    var xs = new List(Int)
        \\    for i in range(0, 8):
        \\        xs.append(twice(i))
        \\    let here = Point(x = xs[3], y = len(xs))
        \\    assert(here.x == 6 and here.y == 8)
        \\    assert(twice(21) == 42)
        \\    print(String(xs[7]) + " " + String(here.x))
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
