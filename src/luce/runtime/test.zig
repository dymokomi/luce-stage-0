//! The runtime library proved on its own, without a program, an
//! engine, or a host.
//!
//! The language-level proof of these semantics is `specs/`, which runs
//! real Luce source; these tests hold the library to its own contract:
//! the ownership state machine, the leak census, the trap channel, and
//! the C surface's calling convention.

const std = @import("std");
const mir = @import("../06_mir.zig");
const containers = @import("containers.zig");
const heap = @import("heap.zig");
const operators = @import("operators.zig");
const text = @import("text.zig");
const trace = @import("trace.zig");
const value = @import("value.zig");

const Runtime = heap.Runtime;
const Value = value.Value;
const testing = std.testing;

/// A runtime over test-owned memory, so a leak in the library is a
/// leak the test allocator reports — including an object whose storage
/// `freeObject` failed to give back, since object storage is
/// `testing.allocator` directly rather than the arena.
const Bench = struct {
    arena: std.heap.ArenaAllocator,
    runtime: Runtime,

    fn setup(self: *Bench) void {
        self.arena = .init(testing.allocator);
        self.runtime = .init(.{
            .arena = self.arena.allocator(),
            .objects = testing.allocator,
        });
    }

    fn deinit(self: *Bench) void {
        self.runtime.deinit();
        self.arena.deinit();
    }
};

fn expectTrap(code: mir.TrapCode, runtime: *Runtime, mistake: anytype) !void {
    try testing.expectError(error.Trap, mistake);
    try testing.expectEqual(code, runtime.pending.?.code);
    try testing.expectEqualStrings(code.message(), runtime.pending.?.message);
}

// ---------------------------------------------------------------------------
// The object heap and the census
// ---------------------------------------------------------------------------

test "a fresh object is loose, and the census counts what was not freed" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const first = try runtime.newList();
    const second = try runtime.newMap();
    try testing.expectEqual(@as(u32, 2), runtime.live);
    try testing.expectEqual(heap.Owner.loose, (try runtime.resolve(first)).owner);

    runtime.freeObject(first.asObject());
    try testing.expectEqual(@as(u32, 1), runtime.live);
    // The freed handle stays detectably dead; slots are never reused.
    try expectTrap(.use_after_free, runtime, runtime.resolve(first));
    _ = second;
}

test "the null handle traps before it touches anything" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    try expectTrap(.null_object, &bench.runtime, bench.runtime.resolve(Value.null_object));
}

test "a binding frees at scope exit, and only its own binding does" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const held = try runtime.newList();
    const serial = runtime.takeSerial();
    runtime.bind(held, serial, 3);

    // A different local of the same frame, and the same local of a
    // different frame, both leave it alone.
    runtime.unbind(held, serial, 4);
    runtime.unbind(held, serial + 1, 3);
    try testing.expectEqual(@as(u32, 1), runtime.live);

    runtime.unbind(held, serial, 3);
    try testing.expectEqual(@as(u32, 0), runtime.live);
}

test "a container owns what it adopts and frees it with itself (S20, S22)" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const outer = try runtime.newList();
    const inner = try runtime.newList();
    try containers.append(runtime, outer, inner);
    try testing.expectEqual(heap.Owner.container, (try runtime.resolve(inner)).owner);

    // Giving away what a container owns would forge a second owner.
    try expectTrap(.not_owned, runtime, containers.giveVerb(runtime, inner, null));

    runtime.freeObject(outer.asObject());
    try testing.expectEqual(@as(u32, 0), runtime.live);
}

test "give demands the binding it names still owns the object (S23)" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const held = try runtime.newList();
    const serial = runtime.takeSerial();
    runtime.bind(held, serial, 0);

    _ = try containers.giveVerb(runtime, held, .{ .serial = serial, .local = 0 });
    try expectTrap(
        .not_owned,
        runtime,
        containers.giveVerb(runtime, held, .{ .serial = serial, .local = 1 }),
    );
}

test "a return moves what the finished frame owned out loose (S16)" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const held = try runtime.newList();
    const serial = runtime.takeSerial();
    runtime.bind(held, serial, 0);
    runtime.loosenFromFrame(held, serial);
    try testing.expectEqual(heap.Owner.loose, (try runtime.resolve(held)).owner);
}

test "copy duplicates what an object owns, recursively (S31)" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const outer = try runtime.newList();
    const inner = try runtime.newList();
    try containers.append(runtime, inner, Value.ofInt(7));
    try containers.append(runtime, outer, inner);

    const duplicate = try containers.copyVerb(runtime, outer);
    try testing.expectEqual(@as(u32, 4), runtime.live);

    // The copy's element is a different object that holds equal data.
    const copied_inner = try containers.indexGet(runtime, duplicate, &.{Value.ofInt(0)});
    try testing.expect(copied_inner.asObject() != inner.asObject());
    const element = try containers.indexGet(runtime, copied_inner, &.{Value.ofInt(0)});
    try testing.expectEqual(@as(i64, 7), element.asInt());

    // Freeing the copy takes its own element and nothing of the original.
    runtime.freeObject(duplicate.asObject());
    try testing.expectEqual(@as(u32, 2), runtime.live);
    _ = try runtime.resolve(inner);
}

test "objects inside a struct value are walked, not skipped" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    var fields = [_]Value{ Value.ofInt(1), try runtime.newList() };
    const record = Value.ofStruct(&fields);
    const serial = runtime.takeSerial();
    runtime.bind(record, serial, 0);
    try testing.expectEqual(
        heap.Owner{ .binding = .{ .serial = serial, .local = 0 } },
        (try runtime.resolve(fields[1])).owner,
    );
    runtime.unbind(record, serial, 0);
    try testing.expectEqual(@as(u32, 0), runtime.live);
}

test "freeing an object gives its storage back, during the run" {
    // The census says an object was freed; this says the memory it
    // held came back *while the program was still running*, which is
    // the whole difference between scope ownership and a leak with
    // good manners.  A counting allocator sits under object storage,
    // so the claim is bytes rather than a promise.
    var counted: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var runtime: Runtime = .init(.{
        .arena = arena.allocator(),
        .objects = counted.allocator(),
    });
    defer runtime.deinit();

    const settled = counted.allocated_bytes - counted.freed_bytes;
    // One round of exactly what a scope does: make objects, fill them,
    // let the scope end.  Repeated, because a single round could hide
    // behind an allocator's slack.
    for (0..8) |_| {
        const list = try runtime.newList();
        for (0..64) |number| {
            try containers.append(&runtime, list, Value.ofInt(@intCast(number)));
        }
        const map = try runtime.newMap();
        for (0..64) |number| {
            const key = Value.ofInt(@intCast(number));
            try containers.indexSet(&runtime, map, &.{key}, Value.ofInt(0));
        }
        const builder = try runtime.newBuilder();
        for (0..64) |_| try containers.append(&runtime, builder, Value.ofString("word"));
        const array = try runtime.newArray(&.{ 8, 8 }, Value.ofInt(0));

        runtime.freeObject(list.asObject());
        runtime.freeObject(map.asObject());
        runtime.freeObject(builder.asObject());
        runtime.freeObject(array.asObject());
    }
    try testing.expectEqual(@as(u32, 0), runtime.live);

    // Everything but the object table itself, which grows by design:
    // slots are never reused, so a freed handle stays detectably dead
    // (S9).  32 objects of table is the only thing allowed to remain.
    const remaining = counted.allocated_bytes - counted.freed_bytes - settled;
    try testing.expect(remaining <= 32 * @sizeOf(heap.Object) * 2);
}

test "a map keeps insertion order through growth, lookup, and removal" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    // Past the first few rehashes, so the index is rebuilt more than
    // once and the probe sequences actually collide.
    const count = 200;
    const map = try runtime.newMap();
    for (0..count) |number| {
        const key = Value.ofInt(@intCast(number * 7));
        try containers.indexSet(runtime, map, &.{key}, Value.ofInt(@intCast(number)));
    }
    try testing.expectEqual(@as(i64, count), (try containers.length(runtime, map)).asInt());
    for (0..count) |number| {
        const key = Value.ofInt(@intCast(number * 7));
        const found = try containers.indexGet(runtime, map, &.{key});
        try testing.expectEqual(@as(i64, @intCast(number)), found.asInt());
        try testing.expectEqual(key.asInt(), (try containers.keyAt(runtime, map, @intCast(number))).asInt());
    }
    // A key that was never stored is absent however close it hashes.
    try testing.expect(!(try containers.hasKey(runtime, map, Value.ofInt(3))).asBoolean());

    // Removal renumbers the entries; the survivors keep their order
    // and still look up.
    for (0..count) |number| {
        if (number % 2 == 0) continue;
        try containers.remove(runtime, map, Value.ofInt(@intCast(number * 7)));
    }
    try testing.expectEqual(@as(i64, count / 2), (try containers.length(runtime, map)).asInt());
    for (0..count / 2) |position| {
        const wanted: i64 = @intCast(position * 14);
        try testing.expectEqual(wanted, (try containers.keyAt(runtime, map, @intCast(position))).asInt());
        try testing.expect((try containers.hasKey(runtime, map, Value.ofInt(wanted))).asBoolean());
    }
    runtime.freeObject(map.asObject());
}

test "map keys hash as they compare, for Int and for String" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    // Two Strings with the same bytes are the same key even though
    // they are different pointers: `keyEquals` says so, and the hash
    // has to agree or the second store would make a second entry.
    var first: [3]u8 = "abc".*;
    var second: [3]u8 = "abc".*;
    const map = try runtime.newMap();
    try containers.indexSet(runtime, map, &.{Value.ofString(&first)}, Value.ofInt(1));
    try containers.indexSet(runtime, map, &.{Value.ofString(&second)}, Value.ofInt(2));
    try testing.expectEqual(@as(i64, 1), (try containers.length(runtime, map)).asInt());
    try testing.expectEqual(
        @as(i64, 2),
        (try containers.indexGet(runtime, map, &.{Value.ofString("abc")})).asInt(),
    );

    // Negative Int keys travel through the same bit mixer as positive
    // ones and come back.
    const numbers = try runtime.newMap();
    for ([_]i64{ -1, 0, 1, std.math.minInt(i64), std.math.maxInt(i64) }) |key| {
        try containers.indexSet(runtime, numbers, &.{Value.ofInt(key)}, Value.ofInt(key));
    }
    for ([_]i64{ -1, 0, 1, std.math.minInt(i64), std.math.maxInt(i64) }) |key| {
        try testing.expectEqual(
            key,
            (try containers.indexGet(runtime, numbers, &.{Value.ofInt(key)})).asInt(),
        );
    }
    runtime.freeObject(map.asObject());
    runtime.freeObject(numbers.asObject());
}

// ---------------------------------------------------------------------------
// Containers
// ---------------------------------------------------------------------------

test "lists index, append, pop, insert, remove, and bound-check" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const held = try runtime.newList();
    try containers.append(runtime, held, Value.ofInt(10));
    try containers.append(runtime, held, Value.ofInt(30));
    try containers.insert(runtime, held, 1, Value.ofInt(20));
    try testing.expectEqual(@as(i64, 3), (try containers.length(runtime, held)).asInt());
    try testing.expectEqual(
        @as(i64, 20),
        (try containers.indexGet(runtime, held, &.{Value.ofInt(1)})).asInt(),
    );

    try containers.indexSet(runtime, held, &.{Value.ofInt(0)}, Value.ofInt(-1));
    try testing.expectEqual(@as(i64, 1), try containers.find(runtime, held, Value.ofInt(20)));
    try testing.expectEqual(@as(i64, -1), try containers.find(runtime, held, Value.ofInt(99)));

    try testing.expectEqual(@as(i64, 30), (try containers.pop(runtime, held)).asInt());
    try containers.remove(runtime, held, Value.ofInt(0));
    try testing.expectEqual(@as(i64, 1), (try containers.length(runtime, held)).asInt());

    try expectTrap(
        .index_bounds,
        runtime,
        containers.indexGet(runtime, held, &.{Value.ofInt(5)}),
    );
    try containers.clear(runtime, held);
    try expectTrap(.empty_collection, runtime, containers.pop(runtime, held));
}

test "maps keep insertion order and answer for missing keys three ways" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const held = try runtime.newMap();
    try containers.indexSet(runtime, held, &.{Value.ofString("b")}, Value.ofInt(2));
    try containers.indexSet(runtime, held, &.{Value.ofString("a")}, Value.ofInt(1));
    try testing.expectEqualStrings("b", (try containers.keyAt(runtime, held, 0)).asString());
    try testing.expectEqual(@as(i64, 1), (try containers.valueAt(runtime, held, 1)).asInt());

    // has_key answers false, get answers the default, m[key] traps.
    try testing.expect(!(try containers.hasKey(runtime, held, Value.ofString("c"))).asBoolean());
    try testing.expectEqual(@as(i64, 9), (try containers.mapGet(
        runtime,
        held,
        Value.ofString("c"),
        Value.ofInt(9),
    )).asInt());
    try expectTrap(
        .key_missing,
        runtime,
        containers.indexGet(runtime, held, &.{Value.ofString("c")}),
    );

    const keys = try containers.mapKeys(runtime, held);
    try testing.expectEqual(@as(i64, 2), (try containers.length(runtime, keys)).asInt());
}

test "arrays flatten multi-dimensional indices and refuse an oversized shape" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const grid = try runtime.newArray(&.{ 2, 3 }, Value.ofInt(0));
    try containers.indexSet(runtime, grid, &.{ Value.ofInt(1), Value.ofInt(2) }, Value.ofInt(5));
    try testing.expectEqual(@as(i64, 5), (try containers.indexGet(
        runtime,
        grid,
        &.{ Value.ofInt(1), Value.ofInt(2) },
    )).asInt());
    try testing.expectEqual(@as(i64, 3), (try containers.dimSize(runtime, grid, 1)).asInt());
    try expectTrap(
        .index_bounds,
        runtime,
        containers.indexGet(runtime, grid, &.{ Value.ofInt(2), Value.ofInt(0) }),
    );

    try testing.expectError(error.Trap, runtime.newArray(&.{ 1 << 20, 1 << 20 }, Value.none));
    try testing.expectEqual(mir.TrapCode.index_bounds, runtime.pending.?.code);
}

test "compiled code's byte offsets find the fields they name" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const grid = try runtime.newArray(&.{ 2, 3 }, Value.ofFloat(0.0));
    try containers.indexSet(runtime, grid, &.{ Value.ofInt(1), Value.ofInt(2) }, Value.ofFloat(7.5));

    // Exactly the walk `08_llvm/lower.zig` emits: the table base out of
    // the `Runtime`, the row by handle, then `alive`, `count`, `dims`,
    // and `elements` out of the row — every step through
    // `heap.layout`'s numbers and nothing through a field name.
    const base: [*]const u8 = @ptrCast(runtime);
    const table: [*]const u8 = @as(*const [*]const u8, @ptrCast(@alignCast(
        base + heap.layout.table_pointer,
    ))).*;
    try testing.expectEqual(@intFromPtr(runtime.table.items.ptr), @intFromPtr(table));

    const row = table + heap.layout.row_size * grid.asObject();
    try testing.expectEqual(@as(u8, 1), (row + heap.layout.alive)[0]);
    const dims: [*]const i64 = @ptrCast(@alignCast(@as(*const [*]const u8, @ptrCast(@alignCast(
        row + heap.layout.array_dims,
    ))).*));
    try testing.expectEqual(@as(i64, 2), dims[0]);
    try testing.expectEqual(@as(i64, 3), dims[1]);
    try testing.expectEqual(@as(usize, 6), @as(*const usize, @ptrCast(@alignCast(
        row + heap.layout.array_count,
    ))).*);
    // An `Array(Float)` stores `f64`s, so the element is one load and
    // no unboxing — which is the whole reason the storage is typed.
    const elements: [*]const f64 = @ptrCast(@alignCast(@as(*const [*]const u8, @ptrCast(@alignCast(
        row + heap.layout.array_elements,
    ))).*));
    try testing.expectEqual(@as(f64, 7.5), elements[1 * 3 + 2]);

    // A freed row reads dead through the same offset, which is what
    // makes the inline `use_after_free` check a one-byte load.
    runtime.freeObject(grid.asObject());
    try testing.expectEqual(@as(u8, 0), (row + heap.layout.alive)[0]);

    // And the slice layout the three pointer reads assume.
    var measured: []const u8 = "ab";
    measured.len = 2;
    const words: *const [2]usize = @ptrCast(&measured);
    try testing.expectEqual(
        @intFromPtr(measured.ptr),
        words[heap.layout.slice_pointer / @sizeOf(usize)],
    );
    try testing.expectEqual(measured.len, words[heap.layout.slice_count / @sizeOf(usize)]);
}

test "a builder collects bytes and str takes a snapshot of them" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const held = try runtime.newBuilder();
    try containers.append(runtime, held, Value.ofString("ab"));
    try containers.appendAscii(runtime, held, 'c');
    const taken = try text.str(runtime, held);
    try testing.expectEqualStrings("abc", taken.asString());

    // The snapshot does not change when the builder grows again.
    try containers.appendAscii(runtime, held, 'd');
    try testing.expectEqualStrings("abc", taken.asString());
    try expectTrap(.bad_codepoint, runtime, containers.appendAscii(runtime, held, 200));
}

test "sort and reverse work in place on lists and arrays alike" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const held = try runtime.newList();
    for ([_]i64{ 3, 1, 2 }) |number| try containers.append(runtime, held, Value.ofInt(number));
    try containers.sort(runtime, held);
    try testing.expectEqual(@as(i64, 1), (try containers.indexGet(runtime, held, &.{Value.ofInt(0)})).asInt());
    try containers.reverse(runtime, held);
    try testing.expectEqual(@as(i64, 3), (try containers.indexGet(runtime, held, &.{Value.ofInt(0)})).asInt());
}

test "a list slice copies its object elements rather than sharing them" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const held = try runtime.newList();
    try containers.append(runtime, held, try runtime.newList());
    const taken = try containers.listSlice(runtime, held, 0, 1);

    const original = try containers.indexGet(runtime, held, &.{Value.ofInt(0)});
    const copied = try containers.indexGet(runtime, taken, &.{Value.ofInt(0)});
    try testing.expect(original.asObject() != copied.asObject());
}

// ---------------------------------------------------------------------------
// Strings, conversions, and arithmetic
// ---------------------------------------------------------------------------

test "string slicing is checked twice: in range, and on a UTF-8 boundary" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const held = Value.ofString("a\xF0\x9F\x99\x82b");
    try testing.expectEqualStrings("a", (try text.slice(runtime, held, 0, 1)).asString());
    try testing.expectEqualStrings("\xF0\x9F\x99\x82", (try text.slice(runtime, held, 1, 5)).asString());
    try expectTrap(.string_boundary, runtime, text.slice(runtime, held, 0, 2));
    try expectTrap(.string_bounds, runtime, text.slice(runtime, held, 0, 99));

    try testing.expectEqual(@as(i64, 0xf0), (try text.byteAt(runtime, held, 1)).asInt());
    try testing.expectEqual(@as(i64, 5), (try text.findByte(runtime, held, 'b', 0)).asInt());
    try testing.expectEqual(@as(i64, -1), (try text.findByte(runtime, held, 'z', 0)).asInt());
}

test "the conversions round trip and refuse what they cannot represent" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    try testing.expectEqualStrings("-12", (try text.str(runtime, Value.ofInt(-12))).asString());
    try testing.expectEqualStrings("true", (try text.str(runtime, Value.ofBoolean(true))).asString());
    // Shortest text that round trips, not a fixed number of digits.
    try testing.expectEqualStrings("0.1", (try text.str(runtime, Value.ofFloat(0.1))).asString());
    try testing.expectEqualStrings(
        "1000000000000000000000",
        (try text.str(runtime, Value.ofFloat(1e21))).asString(),
    );

    // The parsers answer absence rather than trapping: "not a number"
    // is the same reason every time and the name says it already.
    try testing.expectEqual(@as(i64, 42), (try text.parseInt(runtime, Value.ofString("42"))).asInt());
    try testing.expect((try text.parseInt(runtime, Value.ofString("4 2"))).isNone());
    try testing.expect((try text.parseInt(runtime, Value.ofString(""))).isNone());
    try testing.expectEqual(@as(f64, 1.5), (try text.parseFloat(runtime, Value.ofString("1.5"))).asFloat());
    try testing.expect((try text.parseFloat(runtime, Value.ofString("inf"))).isNone());
    try testing.expect((try text.parseFloat(runtime, Value.ofString("nan"))).isNone());
    try testing.expect((try text.parseFloat(runtime, Value.ofString("zero"))).isNone());

    try testing.expectEqualStrings("\xF0\x9F\x99\x82", (try text.chr(runtime, 0x1F642)).asString());
    try expectTrap(.bad_codepoint, runtime, text.chr(runtime, 0x110000));
    try testing.expectEqual(@as(i64, 0x1F642), (try text.ord(runtime, Value.ofString("\xF0\x9F\x99\x82"))).asInt());
    try expectTrap(.bad_codepoint, runtime, text.ord(runtime, Value.ofString("")));
}

test "integer arithmetic is checked and float arithmetic is IEEE" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const biggest = Value.ofInt(std.math.maxInt(i64));
    try expectTrap(.integer_overflow, runtime, operators.binary(runtime, .add, biggest, Value.ofInt(1)));
    try expectTrap(.divide_by_zero, runtime, operators.binary(runtime, .divide, biggest, Value.ofInt(0)));
    try expectTrap(
        .integer_overflow,
        runtime,
        operators.binary(runtime, .divide, Value.ofInt(std.math.minInt(i64)), Value.ofInt(-1)),
    );
    try expectTrap(.integer_overflow, runtime, operators.negate(runtime, Value.ofInt(std.math.minInt(i64))));

    const divided = try operators.binary(runtime, .divide, Value.ofFloat(1.0), Value.ofFloat(0.0));
    try testing.expect(std.math.isInf(divided.asFloat()));
    // Negation keeps the sign of zero, which `0.0 - x` would not.
    try testing.expect(std.math.signbit((try operators.negate(runtime, Value.ofFloat(0.0))).asFloat()));

    try expectTrap(.conversion_range, runtime, operators.floatToInt(runtime, Value.ofFloat(1e30)));
    try testing.expectEqual(@as(i64, -1), (try operators.floatToInt(runtime, Value.ofFloat(-1.9))).asInt());

    const joined = try operators.binary(runtime, .add, Value.ofString("a"), Value.ofString("b"));
    try testing.expectEqualStrings("ab", joined.asString());
}

test "object comparison is identity, struct comparison is by field" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const first = try runtime.newList();
    const second = try runtime.newList();
    try testing.expect(operators.compare(.equal, first, first));
    try testing.expect(operators.compare(.not_equal, first, second));

    var left = [_]Value{ Value.ofInt(1), Value.ofString("x") };
    var right = [_]Value{ Value.ofInt(1), Value.ofString("x") };
    try testing.expect(operators.compare(.equal, Value.ofStruct(&left), Value.ofStruct(&right)));
    right[0] = Value.ofInt(2);
    try testing.expect(operators.compare(.not_equal, Value.ofStruct(&left), Value.ofStruct(&right)));
}

// ---------------------------------------------------------------------------
// The C surface
// ---------------------------------------------------------------------------

extern fn luce_rt_open(
    functions: ?[*]const trace.FunctionInfo,
    count: i64,
) callconv(.c) ?*Runtime;
extern fn luce_rt_close(runtime: *Runtime) callconv(.c) void;
extern fn luce_rt_unwound(runtime: *Runtime, function: u32, instruction: u32) callconv(.c) void;
extern fn luce_rt_report(
    runtime: *const Runtime,
    context: ?*anyopaque,
    report: trace.ReportFn,
) callconv(.c) void;
extern fn luce_rt_leaked(runtime: *const Runtime) callconv(.c) i64;
extern fn luce_rt_new_list(runtime: *Runtime, out: *Value) callconv(.c) i32;
extern fn luce_rt_append(runtime: *Runtime, target: *const Value, held: *const Value) callconv(.c) i32;
extern fn luce_rt_index_get(
    runtime: *Runtime,
    target: *const Value,
    indices: [*]const Value,
    rank: i64,
    out: *Value,
) callconv(.c) i32;
extern fn luce_rt_str(runtime: *Runtime, held: *const Value, out: *Value) callconv(.c) i32;

/// What a host learns from the trap callback, without allocating: these
/// are entered from C and must stay simple.
const Reported = struct {
    code: i32 = -1,
    storage: [64]u8 = undefined,
    length: usize = 0,
    frames: [8]trace.Frame = undefined,
    frame_count: usize = 0,
    dropped: i64 = 0,

    fn take(
        context: ?*anyopaque,
        code: i32,
        words: [*]const u8,
        length: i64,
        frames: [*]const trace.Frame,
        frame_count: i64,
        dropped: i64,
    ) callconv(.c) void {
        const self: *Reported = @ptrCast(@alignCast(context.?));
        self.code = code;
        self.length = @intCast(length);
        @memcpy(self.storage[0..self.length], words[0..self.length]);
        self.frame_count = @min(@as(usize, @intCast(frame_count)), self.frames.len);
        @memcpy(self.frames[0..self.frame_count], frames[0..self.frame_count]);
        self.dropped = dropped;
    }

    fn message(self: *const Reported) []const u8 {
        return self.storage[0..self.length];
    }

    fn frameName(self: *const Reported, index: usize) []const u8 {
        const frame = self.frames[index];
        return frame.function[0..@intCast(frame.function_length)];
    }
};

/// What a two-function artifact would hand `luce_rt_open`: one debug
/// entry carrying origins, one stripped entry carrying none.
const described = [_]trace.FunctionInfo{
    .{
        .name = "divide",
        .name_length = 6,
        .source = "crash.luc",
        .source_length = 9,
        .origins = &[_]trace.Origin{ .{ .line = 5, .column = 5 }, .{ .line = 6, .column = 9 } },
        .origin_count = 2,
    },
    .{
        .name = "main",
        .name_length = 4,
        .source = "",
        .source_length = 0,
        .origins = null,
        .origin_count = 0,
    },
};

test "the C surface opens a run, carries values, and reports its own traps" {
    var reported: Reported = .{};
    const runtime = luce_rt_open(&described, described.len).?;
    defer luce_rt_close(runtime);

    var held: Value = .none;
    try testing.expectEqual(0, luce_rt_new_list(runtime, &held));
    try testing.expectEqual(0, luce_rt_append(runtime, &held, &Value.ofInt(21)));

    var read: Value = .none;
    try testing.expectEqual(0, luce_rt_index_get(runtime, &held, &[_]Value{Value.ofInt(0)}, 1, &read));
    var printed: Value = .none;
    try testing.expectEqual(0, luce_rt_str(runtime, &read, &printed));
    try testing.expectEqualStrings("21", printed.asString());

    // Out of range: the call answers trapped, and the trap waits in the
    // runtime while the frames record themselves on the way out.
    try testing.expectEqual(1, luce_rt_index_get(runtime, &held, &[_]Value{Value.ofInt(1)}, 1, &read));
    luce_rt_unwound(runtime, 0, 1);
    luce_rt_unwound(runtime, 1, 0);
    luce_rt_report(runtime, &reported, Reported.take);

    try testing.expectEqual(@intFromEnum(mir.TrapCode.index_bounds), reported.code);
    try testing.expectEqualStrings("index out of bounds", reported.message());
    try testing.expectEqual(@as(usize, 2), reported.frame_count);
    try testing.expectEqual(@as(i64, 0), reported.dropped);
    // Innermost first, and only the described function carries lines.
    try testing.expectEqualStrings("divide", reported.frameName(0));
    try testing.expectEqual(@as(u32, 6), reported.frames[0].line);
    try testing.expectEqual(@as(u32, 9), reported.frames[0].column);
    try testing.expectEqualStrings("main", reported.frameName(1));
    try testing.expectEqual(@as(u32, 0), reported.frames[1].line);

    // The census sees the one list nobody freed.
    try testing.expectEqual(@as(i64, 1), luce_rt_leaked(runtime));
}

test "a trace keeps the innermost frames and counts the rest" {
    var reported: Reported = .{};
    const runtime = luce_rt_open(&described, described.len).?;
    defer luce_rt_close(runtime);

    // Nothing trapped, so nothing is reported however many frames the
    // unwind recorded.
    luce_rt_unwound(runtime, 0, 0);
    luce_rt_report(runtime, &reported, Reported.take);
    try testing.expectEqual(@as(i32, -1), reported.code);

    var read: Value = .none;
    try testing.expectEqual(1, luce_rt_index_get(runtime, &Value.ofObject(9), &.{}, 0, &read));
    var recorded: usize = 1;
    while (recorded < trace.max_frames + 7) : (recorded += 1) luce_rt_unwound(runtime, 1, 0);
    luce_rt_report(runtime, &reported, Reported.take);
    try testing.expectEqual(@as(i64, 7), reported.dropped);
}
