//! The interpreter's own mechanics.
//!
//! What is left here after docs/ENGINE.md's step 8 is deliberately
//! small: the interpreter is no longer a specification of the
//! language, it is the **differential oracle** the specification runs
//! against (`src/luce/specs/`).  Everything that was a statement about
//! Luce — what a program computes, which trap code it raises, what a
//! call trace says, how the host boundary behaves, what the standard
//! library does — moved into `specs/`, where it runs on both engines
//! and the two are compared.
//!
//! So what a test may prove here is only what the *dispatch loop* is
//! responsible for and no other engine can be: the explicit
//! heap-allocated frame stack, and the reusable frame storage that
//! makes interpreter memory O(depth) rather than O(calls made).  Both
//! read `Machine`'s internals directly, which is the tell — a test
//! that runs a program and looks only at its answer belongs in
//! `specs/`.

const std = @import("std");
const testing = std.testing;
const mir = @import("../06_mir.zig");
const interpreter = @import("../interpreter.zig");
const compile_mod = @import("../compile.zig");
const types = @import("../support/types.zig");
const machine_mod = @import("machine.zig");

const Machine = machine_mod.Machine;

const script_options: types.CompileOptions = .{};

fn compileScript(source: []const u8) !mir.Program {
    var result = try compile_mod.compile(testing.allocator, source, script_options);
    switch (result) {
        .success => |program| return program,
        .failure => |*diagnostics| {
            const rendered = try diagnostics.render(testing.allocator);
            defer testing.allocator.free(rendered);
            std.debug.print("unexpected diagnostics:\n{s}", .{rendered});
            result.deinit();
            return error.TestUnexpectedResult;
        },
    }
}

test "interpreter memory is bounded by depth and data, not by calls made" {
    var program = try compileScript(
        \\struct Point:
        \\    x: long
        \\    y: long
        \\
        \\func nudge(p: Point) -> long:
        \\    var scratch: Point
        \\    scratch.x = p.x + 1
        \\    return scratch.x + p.y
        \\
        \\func main():
        \\    var total = 0
        \\    for i in range(0, 100000):
        \\        total += nudge(Point(x = i, y = 1))
        \\    assert(total > 0)
        \\
    );
    defer program.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var machine: Machine = .{
        .arena = arena.allocator(),
        .runtime = .init(.{ .arena = arena.allocator(), .objects = testing.allocator }),
        .program = &program,
        .max_depth = 256,
        .host = null,
    };
    defer machine.runtime.deinit();
    const outcome = try machine.execute(program.entry_function);
    try testing.expect(outcome == .value);
    try testing.expectEqual(@as(usize, 0), machine.frame_storage.items.len);
    try testing.expect(machine.frame_storage.capacity < 4096);
    // A struct local that owns its field run starts *empty* rather
    // than at the shared zero template, because the release it is
    // going to get must never hand a shared run back
    // (docs/STRINGS.md) — and an empty slot costs no allocation at
    // all, which is what the template was there to avoid.  So a
    // hundred thousand calls through `nudge` never build one.
    try testing.expectEqual(@as(usize, 0), machine.struct_zeros.len);
}

test "the explicit frame stack survives deep recursion" {
    // Fifty thousand frames is far past any native stack, and the
    // point of running on a heap-allocated one: call depth is policy
    // here, never a segfault.  The compiled engine keeps the same
    // promise a different way — it counts frames — and `specs/` is
    // where the two are compared.
    var program = try compileScript(
        \\func dive(left: long) -> long:
        \\    if left == 0:
        \\        return 0
        \\    return dive(left - 1)
        \\
        \\func main():
        \\    assert(dive(50000) == 0)
        \\
    );
    defer program.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const deep = try interpreter.run(
        .{ .arena = arena.allocator(), .objects = testing.allocator },
        &program,
        .{ .call_depth = 60_000 },
        null,
    );
    try testing.expect(deep == .success);

    _ = arena.reset(.retain_capacity);
    const shallow = try interpreter.run(
        .{ .arena = arena.allocator(), .objects = testing.allocator },
        &program,
        .{ .call_depth = 1_000 },
        null,
    );
    try testing.expectEqual(mir.TrapCode.call_depth_exceeded, shallow.trap.code);
}
