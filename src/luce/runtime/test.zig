//! The runtime library proved on its own, without a program, an
//! engine, or a host.
//!
//! The language-level proof of these semantics is `specs/`, which runs
//! real Luce source; these tests hold the library to its own contract:
//! the ownership state machine, the leak census, the trap channel, and
//! the C surface's calling convention.

const std = @import("std");
const vocabulary = @import("../support/vocabulary.zig");
const containers = @import("containers.zig");
const files = @import("files.zig");
const heap = @import("heap.zig");
const operators = @import("operators.zig");
const text = @import("text.zig");
const trace = @import("trace.zig");
const value = @import("value.zig");
const workers = @import("workers.zig");

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
    /// Values these tests made and nothing stored.  In a program the
    /// statement that produced one owns it and its end gives the
    /// storage back (docs/STRINGS.md); here the bench stands in for
    /// the statement, so a test that forgets one is a reported leak
    /// exactly as a lowering that forgot one would be.
    loose: std.ArrayList(Value),

    fn setup(self: *Bench) void {
        self.arena = .init(testing.allocator);
        self.runtime = .init(.{
            .arena = self.arena.allocator(),
            .objects = testing.allocator,
        });
        self.loose = .empty;
    }

    /// Hand back `held` and remember to release its storage.
    fn made(self: *Bench, held: Value) Value {
        self.loose.append(testing.allocator, held) catch @panic("out of memory");
        return held;
    }

    fn deinit(self: *Bench) void {
        for (self.loose.items) |held| self.runtime.dropStorage(held);
        self.loose.deinit(testing.allocator);
        self.runtime.deinit();
        self.arena.deinit();
    }
};

fn expectTrap(code: vocabulary.TrapCode, runtime: *Runtime, mistake: anytype) !void {
    try testing.expectError(error.Trap, mistake);
    try testing.expectEqual(code, runtime.pending.?.code);
    try testing.expectEqualStrings(code.message(), runtime.pending.?.message);
}

fn expectContainerParent(runtime: *Runtime, child: Value, parent: Value) !void {
    const owner = (try runtime.resolve(child)).owner;
    try testing.expectEqual(heap.Owner.Kind.container, owner.kind);
    try testing.expect(owner.details.parent.same(parent.asObject()));
}

/// One run for `checkAllAllocationFailures`: rollback must be visible
/// before teardown, and teardown must return every target byte.
fn copyWithAllocator(allocator: std.mem.Allocator, source: *Runtime, held: Value) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    var target: Runtime = .init(.{ .arena = arena.allocator(), .objects = allocator });
    defer {
        target.deinit();
        arena.deinit();
    }
    const duplicate = target.copyFrom(source, held) catch |mistake| {
        try testing.expectEqual(@as(u32, 0), target.live);
        return mistake;
    };
    target.freeValue(duplicate);
    try testing.expectEqual(@as(u32, 0), target.live);
}

const CopyShape = enum { list, map, array, strukt };

fn nestedList(runtime: *Runtime) !Value {
    const list = try runtime.newList(Value.none);
    errdefer runtime.freeValue(list);
    const words = try runtime.ownValue(Value.ofString(
        "a nested object owns bytes that its failed copy must return",
    ));
    try containers.append(runtime, list, words);
    return list;
}

fn nestedCopySource(runtime: *Runtime, shape: CopyShape) !Value {
    const first = try nestedList(runtime);
    var first_loose = true;
    errdefer if (first_loose) runtime.freeValue(first);
    const second = try nestedList(runtime);
    var second_loose = true;
    errdefer if (second_loose) runtime.freeValue(second);

    return switch (shape) {
        .list => blk: {
            const outer = try runtime.newList(Value.none);
            errdefer runtime.freeValue(outer);
            try containers.append(runtime, outer, first);
            first_loose = false;
            try containers.append(runtime, outer, second);
            second_loose = false;
            break :blk outer;
        },
        .map => blk: {
            const map = try runtime.newMap();
            errdefer runtime.freeValue(map);
            try containers.indexSet(
                runtime,
                map,
                &.{Value.ofString("the first copied map key owns outside bytes")},
                first,
            );
            first_loose = false;
            try containers.indexSet(
                runtime,
                map,
                &.{Value.ofString("the second copied map key owns outside bytes")},
                second,
            );
            second_loose = false;
            break :blk map;
        },
        .array => blk: {
            const array = try runtime.newArray(&.{2}, Value.none);
            errdefer runtime.freeValue(array);
            try containers.indexSet(runtime, array, &.{Value.ofLong(0)}, first);
            first_loose = false;
            try containers.indexSet(runtime, array, &.{Value.ofLong(1)}, second);
            second_loose = false;
            break :blk array;
        },
        .strukt => blk: {
            var fields = [_]Value{
                first,
                second,
                Value.ofString("the copied struct itself owns outside bytes"),
            };
            const record = try runtime.ownValue(Value.ofStruct(&fields));
            first_loose = false;
            second_loose = false;
            break :blk record;
        },
    };
}

const DerivedCopy = enum { list_slice, map_values };

fn expectDerivedCopyFailures(kind: DerivedCopy) !usize {
    var failures: usize = 0;
    for (0..32) |failure_offset| {
        var objects: std.testing.FailingAllocator = .init(testing.allocator, .{});
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        var runtime: Runtime = .init(.{
            .arena = arena.allocator(),
            .objects = objects.allocator(),
        });
        const source = try nestedCopySource(
            &runtime,
            if (kind == .list_slice) .list else .map,
        );
        const baseline_live = runtime.live;
        objects.fail_index = objects.alloc_index + failure_offset;

        var completed = false;
        var failed_with_oom = false;
        const outcome = switch (kind) {
            .list_slice => containers.listSlice(&runtime, source, 0, 2),
            .map_values => containers.mapValues(&runtime, source, Value.none),
        };
        if (outcome) |duplicate| {
            runtime.freeValue(duplicate);
            completed = true;
        } else |mistake| {
            failed_with_oom = mistake == error.OutOfMemory;
            failures += 1;
        }
        const live_after = runtime.live;
        const induced = objects.has_induced_failure;
        runtime.deinit();
        arena.deinit();

        try testing.expectEqual(baseline_live, live_after);
        try testing.expectEqual(objects.allocated_bytes, objects.freed_bytes);
        if (completed) return failures;
        try testing.expect(failed_with_oom);
        try testing.expect(induced);
    }
    return error.DerivedCopyNeverCompleted;
}

const BuiltList = enum { map_keys, text_slices, joined_text, arguments };

const built_list_words = [_][]const u8{
    "the first list-builder value owns bytes outside its Value",
    "the second list-builder value owns different outside bytes",
};
const built_list_joined =
    "the first list-builder value owns bytes outside its Value\x00" ++
    "the second list-builder value owns different outside bytes";

const BuiltListArguments = struct {
    fn get(
        _: ?*anyopaque,
        index: i64,
        text_out: *[*]const u8,
        length_out: *i64,
    ) callconv(.c) i32 {
        if (index < 0 or index >= @as(i64, built_list_words.len)) return 0;
        const held = built_list_words[@intCast(index)];
        text_out.* = held.ptr;
        length_out.* = @intCast(held.len);
        return 1;
    }
};

fn expectBuiltListFailures(kind: BuiltList) !usize {
    var failures: usize = 0;
    for (0..16) |failure_offset| {
        var objects: std.testing.FailingAllocator = .init(testing.allocator, .{});
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        var runtime: Runtime = .init(.{
            .arena = arena.allocator(),
            .objects = objects.allocator(),
        });
        const source = if (kind == .map_keys) try runtime.newMap() else Value.none;
        if (kind == .map_keys) {
            for (built_list_words, 0..) |key, number| {
                try containers.indexSet(
                    &runtime,
                    source,
                    &.{Value.ofString(key)},
                    Value.ofLong(@intCast(number)),
                );
            }
        }
        const baseline_live = runtime.live;
        objects.fail_index = objects.alloc_index + failure_offset;

        const outcome = switch (kind) {
            .map_keys => containers.mapKeys(&runtime, source, Value.ofString("")),
            .text_slices => containers.listOfText(&runtime, &built_list_words),
            .joined_text => containers.listOfJoinedText(&runtime, built_list_joined),
            .arguments => containers.listOfArguments(
                &runtime,
                built_list_words.len,
                null,
                BuiltListArguments.get,
            ),
        };
        var completed = false;
        var failed_with_oom = false;
        if (outcome) |listed| {
            runtime.freeValue(listed);
            completed = true;
        } else |mistake| {
            failed_with_oom = mistake == error.OutOfMemory;
            failures += 1;
        }
        const live_after = runtime.live;
        const induced = objects.has_induced_failure;
        runtime.deinit();
        arena.deinit();

        try testing.expectEqual(baseline_live, live_after);
        try testing.expectEqual(objects.allocated_bytes, objects.freed_bytes);
        if (completed) return failures;
        try testing.expect(failed_with_oom);
        try testing.expect(induced);
    }
    return error.BuiltListNeverCompleted;
}

const WorkerFailureState = struct {
    child: *Runtime,
    produce_result: bool = false,
    closes: usize = 0,
    child_live_at_close: u32 = 0,
    spawns: usize = 0,
    joins: usize = 0,
    ran: bool = false,

    fn open(context: ?*anyopaque) callconv(.c) ?*Runtime {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        return self.child;
    }

    fn close(context: ?*anyopaque, runtime: *Runtime) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.closes += 1;
        self.child_live_at_close = runtime.live;
        runtime.deinit();
    }

    fn run(
        context: ?*anyopaque,
        runtime: *Runtime,
        _: i64,
        _: [*]const Value,
        _: i64,
        out: *Value,
        _: i64,
    ) callconv(.c) i32 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (!self.produce_result) return workers.survived;
        const words = runtime.ownValue(Value.ofString(
            "the unclaimed worker result owns outside bytes",
        )) catch return workers.raised_trap;
        out.* = runtime.makeStruct(&.{words}) catch return workers.raised_trap;
        self.ran = true;
        return workers.survived;
    }

    fn spawn(
        context: ?*anyopaque,
        body: workers.Body,
        argument: ?*anyopaque,
        thread: *i64,
    ) callconv(.c) i32 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.spawns += 1;
        body(argument);
        thread.* = 9;
        return workers.yes;
    }

    fn join(context: ?*anyopaque, _: i64) callconv(.c) i32 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.joins += 1;
        return workers.yes;
    }

    fn install(self: *@This(), parent: *Runtime) void {
        parent.workers = .{
            .context = self,
            .spawn = spawn,
            .join = join,
        };
        parent.nursery = .{
            .context = self,
            .open = open,
            .close = close,
            .run = run,
        };
    }
};

// ---------------------------------------------------------------------------
// The object heap and the census
// ---------------------------------------------------------------------------

test "a fresh object is loose, and the census counts what was not freed" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const first = try runtime.newList(Value.none);
    const second = try runtime.newMap();
    try testing.expectEqual(@as(u32, 2), runtime.live);
    try testing.expectEqual(heap.Owner.Kind.loose, (try runtime.resolve(first)).owner.kind);

    runtime.freeObject(first.asObject());
    try testing.expectEqual(@as(u32, 1), runtime.live);
    // The freed handle stays detectably dead.
    try expectTrap(.use_after_free, runtime, runtime.resolve(first));
    _ = second;
}

test "a freed row is reused, so the table follows live objects and not allocations" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    // A hundred thousand objects, one at a time.  Retaining rows would
    // make the table a hundred thousand long; reusing them keeps it at
    // the high-water mark, which here is one.
    var made: usize = 0;
    while (made < 100_000) : (made += 1) {
        const held = try runtime.newList(Value.none);
        try containers.append(runtime, held, Value.ofLong(@intCast(made)));
        runtime.freeObject(held.asObject());
    }
    try testing.expectEqual(@as(usize, 1), runtime.table.items.len);
    try testing.expectEqual(@as(u32, 0), runtime.live);

    // And the peak is what it costs: four alive at once needs four
    // rows, however many have come and gone before them.
    var held: [4]Value = undefined;
    for (&held) |*slot| slot.* = try runtime.newList(Value.none);
    try testing.expectEqual(@as(usize, 4), runtime.table.items.len);
    for (held) |slot| runtime.freeObject(slot.asObject());
}

test "a directory listing splits the same list out of both shapes" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    // The interpreter hands over slices and a compiled program hands
    // over the same names NUL-joined; a `dir_list` that answered two
    // different lists would be two engines disagreeing about a value.
    const names = [_][]const u8{ "alpha.txt", "b", "a name with spaces" };
    const joined = "alpha.txt\x00b\x00a name with spaces\x00";

    const from_slices = try containers.listOfText(runtime, &names);
    const from_bytes = try containers.listOfJoinedText(runtime, joined);
    try testing.expectEqual(@as(i64, 3), (try containers.length(runtime, from_slices)).asLong());
    try testing.expectEqual(@as(i64, 3), (try containers.length(runtime, from_bytes)).asLong());
    for (names, 0..) |wanted, at| {
        const index = Value.ofLong(@intCast(at));
        try testing.expectEqualStrings(
            wanted,
            (try containers.indexGet(runtime, from_slices, &.{index})).asString(),
        );
        try testing.expectEqualStrings(
            wanted,
            (try containers.indexGet(runtime, from_bytes, &.{index})).asString(),
        );
    }

    // An empty directory is an empty list, not a list holding one
    // empty name — and a buffer with no trailing separator is still
    // read whole, because a host is not ours to promise for.
    const empty = try containers.listOfJoinedText(runtime, "");
    try testing.expectEqual(@as(i64, 0), (try containers.length(runtime, empty)).asLong());
    const unterminated = try containers.listOfJoinedText(runtime, "one\x00two");
    try testing.expectEqual(@as(i64, 2), (try containers.length(runtime, unterminated)).asLong());

    runtime.freeObject(from_slices.asObject());
    runtime.freeObject(from_bytes.asObject());
    runtime.freeObject(empty.asObject());
    runtime.freeObject(unterminated.asObject());
}

test "a stale handle to a reused row names nobody, not the newcomer" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const first = try runtime.newList(Value.none);
    try containers.append(runtime, first, Value.ofLong(11));
    runtime.freeObject(first.asObject());

    // The very next object takes the row the first one vacated — the
    // whole point of the free list — and is a different object all the
    // same.
    const second = try runtime.newList(Value.none);
    try testing.expectEqual(first.asObject().index, second.asObject().index);
    try testing.expect(!first.asObject().same(second.asObject()));

    // Every door into the row refuses the stale handle, and the live
    // one still opens.
    try expectTrap(.use_after_free, runtime, runtime.resolve(first));
    try expectTrap(.use_after_free, runtime, containers.length(runtime, first));
    try expectTrap(.use_after_free, runtime, containers.indexGet(runtime, first, &.{Value.ofLong(0)}));
    try expectTrap(.use_after_free, runtime, runtime.deepCopy(first));
    try expectTrap(.use_after_free, runtime, runtime.checkGivable(first, null));
    try testing.expectEqual(@as(i64, 0), (try containers.length(runtime, second)).asLong());

    // Identity is the object, not the row: the two handles are not
    // equal, and freeing through the stale one takes nothing.
    try testing.expect(!operators.compare(.equal, first, second));
    runtime.freeObject(first.asObject());
    try testing.expectEqual(@as(u32, 1), runtime.live);

    runtime.freeObject(second.asObject());
    try testing.expectEqual(@as(u32, 0), runtime.live);
}

test "the runtime copy backstop refuses a resource handle" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    // Stage 4 refuses this source spelling.  Keep the shared runtime
    // wall for decoded or otherwise hostile MIR: a second handle would
    // be a second owner of the one host file.
    const file = try runtime.newFile(17, "input.bin");
    try expectTrap(.not_owned, runtime, runtime.deepCopy(file));
    runtime.freeObject(file.asObject());
    try testing.expectEqual(@as(u32, 0), runtime.live);
}

test "a row out of generations is retired rather than handed out again" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    // Wind one row to its last usable generation rather than freeing
    // it four billion times.
    const doomed = try runtime.newList(Value.none);
    const last: value.Handle = .{
        .index = doomed.asObject().index,
        .generation = heap.retired - 1,
    };
    runtime.table.items[last.index].generation = last.generation;
    _ = try runtime.resolve(Value.ofObject(last));

    runtime.freeObject(last);
    try testing.expectEqual(heap.retired, runtime.table.items[last.index].generation);
    try expectTrap(.use_after_free, runtime, runtime.resolve(Value.ofObject(last)));

    // The row is out of the game.  Nothing is ever handed out at the
    // retired generation — the only handle that could name this row
    // again does not exist and cannot be made — so the next object
    // gets a row of its own, and so does the one after it.
    const next = try runtime.newList(Value.none);
    try testing.expect(next.asObject().index != last.index);
    runtime.freeObject(next.asObject());
    const after = try runtime.newList(Value.none);
    try testing.expect(after.asObject().index != last.index);

    // A row that still has generations left does keep coming back, so
    // what was retired is the one row and not the free list.
    try testing.expectEqual(next.asObject().index, after.asObject().index);
    runtime.freeObject(after.asObject());
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

    const held = try runtime.newList(Value.none);
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

    const outer = try runtime.newList(Value.none);
    const inner = try runtime.newList(Value.none);
    try containers.append(runtime, outer, inner);
    try expectContainerParent(runtime, inner, outer);

    // Giving away what a container owns would forge a second owner.
    try expectTrap(.not_owned, runtime, containers.giveVerb(runtime, inner, null));

    runtime.freeObject(outer.asObject());
    try testing.expectEqual(@as(u32, 0), runtime.live);
}

test "every adopting door refuses a direct ownership cycle without changing its target" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const appended = try runtime.newList(Value.none);
    defer runtime.freeValue(appended);
    try expectTrap(.ownership_cycle, runtime, containers.append(runtime, appended, appended));
    runtime.pending = null;
    try testing.expectEqual(@as(i64, 0), (try containers.length(runtime, appended)).asLong());
    try testing.expectEqual(heap.Owner.Kind.loose, (try runtime.resolve(appended)).owner.kind);

    const inserted = try runtime.newList(Value.none);
    defer runtime.freeValue(inserted);
    try expectTrap(.ownership_cycle, runtime, containers.insert(runtime, inserted, 0, inserted));
    runtime.pending = null;
    try testing.expectEqual(@as(i64, 0), (try containers.length(runtime, inserted)).asLong());

    const indexed = try runtime.newList(Value.none);
    defer runtime.freeValue(indexed);
    try containers.append(runtime, indexed, Value.none);
    try expectTrap(
        .ownership_cycle,
        runtime,
        containers.indexSet(runtime, indexed, &.{Value.ofLong(0)}, indexed),
    );
    runtime.pending = null;
    try testing.expect((try containers.indexGet(runtime, indexed, &.{Value.ofLong(0)})).isNone());

    const mapped = try runtime.newMap();
    defer runtime.freeValue(mapped);
    try expectTrap(
        .ownership_cycle,
        runtime,
        containers.indexSet(runtime, mapped, &.{Value.ofString("self")}, mapped),
    );
    runtime.pending = null;
    try testing.expectEqual(@as(i64, 0), (try containers.length(runtime, mapped)).asLong());

    const placed = try runtime.newMap();
    defer runtime.freeValue(placed);
    try expectTrap(
        .ownership_cycle,
        runtime,
        containers.mapPlace(runtime, placed, Value.ofString("self"), placed),
    );
    runtime.pending = null;
    try testing.expectEqual(@as(i64, 0), (try containers.length(runtime, placed)).asLong());

    const array = try runtime.newArray(&.{1}, Value.none);
    defer runtime.freeValue(array);
    try expectTrap(
        .ownership_cycle,
        runtime,
        containers.indexSet(runtime, array, &.{Value.ofLong(0)}, array),
    );
    runtime.pending = null;
    try testing.expect((try containers.indexGet(runtime, array, &.{Value.ofLong(0)})).isNone());

    // A struct is value storage, but every object field in it is still
    // a top ownership root.  Hiding the receiver one value deep cannot
    // evade the same check.
    const through_struct = try runtime.newList(Value.none);
    defer runtime.freeValue(through_struct);
    const safe_field = try runtime.newList(Value.none);
    defer runtime.freeValue(safe_field);
    const record = try runtime.makeStruct(&.{ safe_field, through_struct });
    try expectTrap(
        .ownership_cycle,
        runtime,
        containers.append(runtime, through_struct, record),
    );
    runtime.pending = null;
    try testing.expectEqual(@as(i64, 0), (try containers.length(runtime, through_struct)).asLong());
    try testing.expectEqual(heap.Owner.Kind.loose, (try runtime.resolve(safe_field)).owner.kind);
}

test "the runtime refuses an object-carrying array fill before replacing any cell" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const array = try runtime.newArray(&.{1}, Value.none);
    defer runtime.freeValue(array);
    const kept = try runtime.newList(Value.none);
    try containers.indexSet(runtime, array, &.{Value.ofLong(0)}, kept);
    try expectContainerParent(runtime, kept, array);

    const incoming = try runtime.newList(Value.none);
    defer runtime.freeValue(incoming);
    try expectTrap(.not_owned, runtime, containers.arrayFill(runtime, array, incoming));
    runtime.pending = null;
    const after_direct = try containers.indexGet(runtime, array, &.{Value.ofLong(0)});
    try testing.expect(after_direct.asObject().same(kept.asObject()));
    try expectContainerParent(runtime, kept, array);
    try testing.expectEqual(heap.Owner.Kind.loose, (try runtime.resolve(incoming)).owner.kind);

    const record = try runtime.makeStruct(&.{incoming});
    defer runtime.dropStorage(record);
    try expectTrap(.not_owned, runtime, containers.arrayFill(runtime, array, record));
    runtime.pending = null;
    const after_struct = try containers.indexGet(runtime, array, &.{Value.ofLong(0)});
    try testing.expect(after_struct.asObject().same(kept.asObject()));
    try expectContainerParent(runtime, kept, array);

    // A null object is still an object-typed fill, and the same hostile
    // MIR wall applies without first trying to resolve it.
    try expectTrap(.not_owned, runtime, containers.arrayFill(runtime, array, Value.null_object));
    runtime.pending = null;
    const after_null = try containers.indexGet(runtime, array, &.{Value.ofLong(0)});
    try testing.expect(after_null.asObject().same(kept.asObject()));
}

test "the cycle backstop preserves receiver, mutability, and bounds trap precedence" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const list = try runtime.newList(Value.none);
    defer runtime.freeValue(list);
    try expectTrap(
        .index_bounds,
        runtime,
        containers.indexSet(runtime, list, &.{Value.ofLong(0)}, list),
    );
    runtime.pending = null;
    try expectTrap(.index_bounds, runtime, containers.insert(runtime, list, 1, list));
    runtime.pending = null;
    try testing.expectEqual(@as(i64, 0), (try containers.length(runtime, list)).asLong());

    const stale = try runtime.newList(Value.none);
    runtime.freeValue(stale);
    try expectTrap(.use_after_free, runtime, containers.append(runtime, stale, stale));
    runtime.pending = null;

    try runtime.beginConstants(1);
    const rooted = try runtime.newList(Value.none);
    try runtime.publishConstant(0, rooted);
    runtime.finishConstants();
    try expectTrap(.immutable_object, runtime, containers.append(runtime, rooted, rooted));
    runtime.pending = null;
    try testing.expectEqual(@as(i64, 0), (try containers.length(runtime, rooted)).asLong());
}

test "an ancestor cannot move into its descendant and a rejected overwrite stays intact" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const root = try runtime.newList(Value.none);
    defer runtime.freeValue(root);
    const middle = try runtime.newList(Value.none);
    const leaf = try runtime.newList(Value.none);
    try containers.append(runtime, leaf, Value.none);
    try containers.append(runtime, middle, leaf);
    try containers.append(runtime, root, middle);
    try expectContainerParent(runtime, middle, root);
    try expectContainerParent(runtime, leaf, middle);

    try expectTrap(
        .ownership_cycle,
        runtime,
        containers.indexSet(runtime, leaf, &.{Value.ofLong(0)}, root),
    );
    runtime.pending = null;
    try testing.expect((try containers.indexGet(runtime, leaf, &.{Value.ofLong(0)})).isNone());
    try expectContainerParent(runtime, middle, root);
    try expectContainerParent(runtime, leaf, middle);

    try expectTrap(.ownership_cycle, runtime, containers.append(runtime, leaf, root));
    runtime.pending = null;
    try testing.expectEqual(@as(i64, 1), (try containers.length(runtime, leaf)).asLong());
    try testing.expectEqual(heap.Owner.Kind.loose, (try runtime.resolve(root)).owner.kind);
}

test "a damaged parent cycle is bounded and refused rather than walked forever" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const first = try runtime.newList(Value.none);
    defer runtime.freeValue(first);
    const second = try runtime.newList(Value.none);
    defer runtime.freeValue(second);
    const child = try runtime.newList(Value.none);
    defer runtime.freeValue(child);

    (try runtime.resolve(first)).owner = .containedBy(second.asObject());
    (try runtime.resolve(second)).owner = .containedBy(first.asObject());
    try expectTrap(
        .ownership_cycle,
        runtime,
        runtime.ensureAcyclicAdoption(first.asObject(), child),
    );
    runtime.pending = null;
    try testing.expectEqual(heap.Owner.Kind.loose, (try runtime.resolve(child)).owner.kind);

    // Restore the deliberately damaged metadata before the ordinary
    // teardown path proves all three rows still have one death point.
    (try runtime.resolve(first)).owner = .loose;
    (try runtime.resolve(second)).owner = .loose;
}

test "pop, bind, and reinsertion keep one exact acyclic owner tree" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const root = try runtime.newList(Value.none);
    defer runtime.freeValue(root);
    const branch = try runtime.newList(Value.none);
    const leaf = try runtime.newList(Value.none);
    try containers.append(runtime, branch, leaf);
    try containers.append(runtime, root, branch);
    try expectContainerParent(runtime, branch, root);
    try expectContainerParent(runtime, leaf, branch);

    const taken = try containers.pop(runtime, root);
    try testing.expect(taken.asObject().same(branch.asObject()));
    try testing.expectEqual(heap.Owner.Kind.loose, (try runtime.resolve(branch)).owner.kind);
    // The subtree stays a tree while its root changes owner.
    try expectContainerParent(runtime, leaf, branch);

    const serial = runtime.takeSerial();
    runtime.bind(branch, serial, 7);
    const bound = (try runtime.resolve(branch)).owner;
    try testing.expectEqual(heap.Owner.Kind.binding, bound.kind);
    try testing.expectEqual(serial, bound.details.binding.serial);
    try testing.expectEqual(@as(u32, 7), bound.details.binding.local);
    runtime.loosenFromFrame(branch, serial);
    try testing.expectEqual(heap.Owner.Kind.loose, (try runtime.resolve(branch)).owner.kind);

    try containers.insert(runtime, root, 0, branch);
    try expectContainerParent(runtime, branch, root);
    try expectContainerParent(runtime, leaf, branch);

    // Growing below an existing ancestry is the ordinary, legal
    // direction: only moving an ancestor down below itself is refused.
    const twig = try runtime.newList(Value.none);
    try containers.append(runtime, leaf, twig);
    try expectContainerParent(runtime, twig, leaf);
}

test "give demands the binding it names still owns the object (S23)" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const held = try runtime.newList(Value.none);
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

    const held = try runtime.newList(Value.none);
    const serial = runtime.takeSerial();
    runtime.bind(held, serial, 0);
    runtime.loosenFromFrame(held, serial);
    try testing.expectEqual(heap.Owner.Kind.loose, (try runtime.resolve(held)).owner.kind);
}

test "copy duplicates what an object owns, recursively (S31)" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const outer = try runtime.newList(Value.none);
    const inner = try runtime.newList(Value.none);
    try containers.append(runtime, inner, Value.ofLong(7));
    try containers.append(runtime, outer, inner);

    const duplicate = try containers.copyVerb(runtime, outer);
    try testing.expectEqual(@as(u32, 4), runtime.live);

    // The copy's element is a different object that holds equal data.
    const copied_inner = try containers.indexGet(runtime, duplicate, &.{Value.ofLong(0)});
    try testing.expect(!copied_inner.asObject().same(inner.asObject()));
    try expectContainerParent(runtime, copied_inner, duplicate);
    const element = try containers.indexGet(runtime, copied_inner, &.{Value.ofLong(0)});
    try testing.expectEqual(@as(i64, 7), element.asLong());

    // Freeing the copy takes its own element and nothing of the original.
    runtime.freeObject(duplicate.asObject());
    try testing.expectEqual(@as(u32, 2), runtime.live);
    _ = try runtime.resolve(inner);
}

test "deep copies and derived lists name the exact parent they build" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const list_source = try nestedCopySource(runtime, .list);
    defer runtime.freeValue(list_source);
    const list_copy = try runtime.deepCopy(list_source);
    defer runtime.freeValue(list_copy);
    const sliced = try containers.listSlice(runtime, list_source, 0, 2);
    defer runtime.freeValue(sliced);
    for (0..2) |at| {
        const index = Value.ofLong(@intCast(at));
        try expectContainerParent(
            runtime,
            try containers.indexGet(runtime, list_copy, &.{index}),
            list_copy,
        );
        try expectContainerParent(
            runtime,
            try containers.indexGet(runtime, sliced, &.{index}),
            sliced,
        );
    }

    const map_source = try nestedCopySource(runtime, .map);
    defer runtime.freeValue(map_source);
    const map_copy = try runtime.deepCopy(map_source);
    defer runtime.freeValue(map_copy);
    for (0..2) |at| {
        try expectContainerParent(runtime, try containers.valueAt(runtime, map_copy, @intCast(at)), map_copy);
    }
    const values = try containers.mapValues(runtime, map_source, Value.none);
    defer runtime.freeValue(values);
    for (0..2) |at| {
        try expectContainerParent(
            runtime,
            try containers.indexGet(runtime, values, &.{Value.ofLong(@intCast(at))}),
            values,
        );
    }

    const array_source = try nestedCopySource(runtime, .array);
    defer runtime.freeValue(array_source);
    const array_copy = try runtime.deepCopy(array_source);
    defer runtime.freeValue(array_copy);
    for (0..2) |at| {
        try expectContainerParent(
            runtime,
            try containers.indexGet(runtime, array_copy, &.{Value.ofLong(@intCast(at))}),
            array_copy,
        );
    }
}

test "a packed list copy ignores retained spare capacity" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const source = try runtime.newList(Value.ofLong(0));
    defer runtime.freeValue(source);
    for (0..64) |number| {
        try containers.append(runtime, source, Value.ofLong(@intCast(number)));
    }
    try containers.clear(runtime, source);
    try containers.append(runtime, source, Value.ofLong(17));
    try containers.append(runtime, source, Value.ofLong(29));

    const duplicate = try runtime.deepCopy(source);
    defer runtime.freeValue(duplicate);
    try testing.expectEqual(@as(i64, 2), (try containers.length(runtime, duplicate)).asLong());
    try testing.expectEqual(
        @as(i64, 17),
        (try containers.indexGet(runtime, duplicate, &.{Value.ofLong(0)})).asLong(),
    );
    try testing.expectEqual(
        @as(i64, 29),
        (try containers.indexGet(runtime, duplicate, &.{Value.ofLong(1)})).asLong(),
    );
}

test "failed nested list, map, array, and struct copies leave no target" {
    for ([_]CopyShape{ .list, .map, .array, .strukt }) |shape| {
        var bench: Bench = undefined;
        bench.setup();
        defer bench.deinit();
        const source = try nestedCopySource(&bench.runtime, shape);
        defer bench.runtime.freeValue(source);

        // The standard matrix refuses every allocation, including
        // ones after the first child has reached the target table.
        try testing.checkAllAllocationFailures(
            testing.allocator,
            copyWithAllocator,
            .{ &bench.runtime, source },
        );
    }
}

test "failed list slices and map value lists roll copied rows back" {
    try testing.expect((try expectDerivedCopyFailures(.list_slice)) >= 4);
    try testing.expect((try expectDerivedCopyFailures(.map_values)) >= 4);
}

test "failed list builders return their current owned value" {
    for ([_]BuiltList{ .map_keys, .text_slices, .joined_text, .arguments }) |kind| {
        try testing.expect((try expectBuiltListFailures(kind)) >= 2);
    }
}

test "failed worker argument transfer returns carried struct storage" {
    var parent_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer parent_arena.deinit();
    var parent: Runtime = .init(.{
        .arena = parent_arena.allocator(),
        .objects = testing.allocator,
    });
    defer parent.deinit();

    var child_objects: std.testing.FailingAllocator = .init(testing.allocator, .{
        // The argument array and the first argument's struct run and
        // outside String consume three allocations.  Refuse the later
        // List's String after its element run has also been allocated.
        .fail_index = 4,
    });
    var child_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer child_arena.deinit();
    var child: Runtime = .init(.{
        .arena = child_arena.allocator(),
        .objects = child_objects.allocator(),
    });
    var state: WorkerFailureState = .{ .child = &child };
    state.install(&parent);

    var arguments = [_]Value{ Value.none, Value.none };
    defer {
        parent.dropStorage(arguments[0]);
        parent.freeValue(arguments[1]);
    }
    var fields = [_]Value{Value.ofString(
        "the carried worker struct owns these outside bytes",
    )};
    arguments[0] = try parent.ownValue(Value.ofStruct(&fields));
    arguments[1] = try parent.newList(Value.none);
    try containers.append(
        &parent,
        arguments[1],
        try parent.ownValue(Value.ofString("the refused worker object owns other bytes")),
    );

    var task: Value = .none;
    try testing.expectError(error.OutOfMemory, workers.spawn(&parent, 0, &arguments, &task));
    try testing.expect(child_objects.has_induced_failure);
    try testing.expectEqual(@as(usize, 0), state.spawns);
    try testing.expectEqual(@as(usize, 1), state.closes);
    // The first argument's standalone value storage did cross and was
    // returned before close; the second object stayed in the parent.
    try testing.expectEqual(@as(u32, 0), state.child_live_at_close);
    try testing.expectEqual(@as(u32, 1), parent.live);
    parent.dropStorage(arguments[0]);
    arguments[0] = Runtime.emptied(arguments[0]);
    parent.freeValue(arguments[1]);
    arguments[1] = .none;
    try testing.expectEqual(@as(u32, 0), parent.live);
    try testing.expectEqual(child_objects.allocated_bytes, child_objects.freed_bytes);
}

test "failed task allocation discards the worker result before close" {
    var parent_objects: std.testing.FailingAllocator = .init(testing.allocator, .{
        // Effects and Worker succeed; the task table's first row does
        // not.  By then the synchronous worker has returned its value.
        .fail_index = 2,
    });
    var parent_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    var parent: Runtime = .init(.{
        .arena = parent_arena.allocator(),
        .objects = parent_objects.allocator(),
    });

    var child_objects: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var child_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    var child: Runtime = .init(.{
        .arena = child_arena.allocator(),
        .objects = child_objects.allocator(),
    });
    var state: WorkerFailureState = .{
        .child = &child,
        .produce_result = true,
        .child_live_at_close = std.math.maxInt(u32),
    };
    state.install(&parent);

    var task: Value = .none;
    const outcome = workers.spawn(&parent, 0, &.{}, &task);
    const parent_live = parent.live;
    parent.deinit();
    parent_arena.deinit();
    child_arena.deinit();

    try testing.expectError(error.OutOfMemory, outcome);
    try testing.expect(parent_objects.has_induced_failure);
    try testing.expect(state.ran);
    try testing.expectEqual(@as(usize, 1), state.spawns);
    try testing.expectEqual(@as(usize, 1), state.joins);
    try testing.expectEqual(@as(usize, 1), state.closes);
    try testing.expectEqual(@as(u32, 0), state.child_live_at_close);
    try testing.expectEqual(@as(u32, 0), parent_live);
    try testing.expectEqual(parent_objects.allocated_bytes, parent_objects.freed_bytes);
    try testing.expectEqual(child_objects.allocated_bytes, child_objects.freed_bytes);
}

test "a cross-runtime move attributes a nested stale-handle trap to its source" {
    var source_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer source_arena.deinit();
    var source: Runtime = .init(.{
        .arena = source_arena.allocator(),
        .objects = testing.allocator,
    });
    defer source.deinit();

    var target_objects: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var target_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer target_arena.deinit();
    var target: Runtime = .init(.{
        .arena = target_arena.allocator(),
        .objects = target_objects.allocator(),
    });
    defer target.deinit();

    // Leave one live target object and one reusable row.  A nested
    // duplicate can then become live before the later stale handle
    // traps, without a table growth obscuring the allocation balance.
    const baseline = try target.newMap();
    const spare = try target.newList(Value.none);
    target.freeObject(spare.asObject());
    const baseline_live = target.live;
    const baseline_bytes = target_objects.allocated_bytes - target_objects.freed_bytes;

    const outer = try source.newList(Value.none);
    const middle = try source.newList(Value.none);
    const good = try source.newList(Value.none);
    try containers.append(&source, middle, good);
    const stale = try source.newList(Value.none);
    source.freeObject(stale.asObject());
    try containers.append(&source, middle, stale);
    try containers.append(&source, outer, middle);

    try expectTrap(.use_after_free, &source, source.moveInto(&target, outer));
    try testing.expect(target.pending == null);
    try testing.expectEqual(baseline_live, target.live);
    try testing.expectEqual(
        baseline_bytes,
        target_objects.allocated_bytes - target_objects.freed_bytes,
    );
    _ = try target.resolve(baseline);
    _ = try source.resolve(outer);
}

test "a cross-runtime move returns a resource refusal to its source" {
    var source_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer source_arena.deinit();
    var source: Runtime = .init(.{
        .arena = source_arena.allocator(),
        .objects = testing.allocator,
    });
    defer source.deinit();

    var target_objects: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var target_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer target_arena.deinit();
    var target: Runtime = .init(.{
        .arena = target_arena.allocator(),
        .objects = target_objects.allocator(),
    });
    defer target.deinit();

    const baseline = try target.newMap();
    const spare = try target.newList(Value.none);
    target.freeObject(spare.asObject());
    const baseline_live = target.live;
    const baseline_bytes = target_objects.allocated_bytes - target_objects.freed_bytes;

    const outer = try source.newList(Value.none);
    const good = try source.newList(Value.none);
    try containers.append(&source, outer, good);
    const file = try source.newFile(17, "worker.txt");
    try containers.append(&source, outer, file);

    try expectTrap(.not_owned, &source, source.moveInto(&target, outer));
    try testing.expect(target.pending == null);
    try testing.expectEqual(baseline_live, target.live);
    try testing.expectEqual(
        baseline_bytes,
        target_objects.allocated_bytes - target_objects.freed_bytes,
    );
    _ = try target.resolve(baseline);
    _ = try source.resolve(outer);
}

test "a cross-runtime move preserves target allocation failure" {
    var source_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer source_arena.deinit();
    var source: Runtime = .init(.{
        .arena = source_arena.allocator(),
        .objects = testing.allocator,
    });
    defer source.deinit();

    var target_objects: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var target_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer target_arena.deinit();
    var target: Runtime = .init(.{
        .arena = target_arena.allocator(),
        .objects = target_objects.allocator(),
    });
    defer target.deinit();

    const baseline = try target.newMap();
    const baseline_live = target.live;
    const baseline_bytes = target_objects.allocated_bytes - target_objects.freed_bytes;
    const carried = try source.newList(Value.none);
    try containers.append(&source, carried, Value.ofLong(7));

    target_objects.fail_index = target_objects.alloc_index;
    try testing.expectError(error.OutOfMemory, source.moveInto(&target, carried));
    target_objects.fail_index = std.math.maxInt(usize);

    try testing.expect(source.pending == null);
    try testing.expect(target.pending == null);
    try testing.expectEqual(baseline_live, target.live);
    try testing.expectEqual(
        baseline_bytes,
        target_objects.allocated_bytes - target_objects.freed_bytes,
    );
    _ = try target.resolve(baseline);
    _ = try source.resolve(carried);
}

test "program roots stay rooted, leave the census, and copy into mutable ownership" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    try runtime.beginConstants(1);
    const rooted = try runtime.newList(Value.ofLong(0));
    try containers.append(runtime, rooted, Value.ofLong(7));
    try runtime.publishConstant(0, rooted);
    runtime.finishConstants();

    try testing.expect(runtime.constant(0).asObject().same(rooted.asObject()));
    try testing.expectEqual(heap.Owner.Kind.program, (try runtime.resolve(rooted)).owner.kind);
    try testing.expectEqual(@as(u32, 1), runtime.live);
    try testing.expectEqual(@as(u32, 1), runtime.program_root_count);
    try testing.expectEqual(@as(i64, 0), runtime.leaked());

    // Every ordinary ownership transition leaves the program root in
    // place, including the defensive release paths damaged IR can
    // reach.  The source front line refuses give/free by name; the
    // runtime keeps them safe and reports not-owned.
    const serial = runtime.takeSerial();
    runtime.bind(rooted, serial, 4);
    const parent = try runtime.newList(Value.none);
    try runtime.ensureAcyclicAdoption(parent.asObject(), rooted);
    runtime.adoptInto(parent.asObject(), rooted);
    runtime.freeValue(parent);
    runtime.loosen(rooted);
    runtime.loosenFromFrame(rooted, serial);
    runtime.unbind(rooted, serial, 4);
    runtime.freeObject(rooted.asObject());
    try testing.expectEqual(heap.Owner.Kind.program, (try runtime.resolve(rooted)).owner.kind);
    try expectTrap(.not_owned, runtime, containers.giveVerb(runtime, rooted, null));
    try expectTrap(.not_owned, runtime, containers.freeVerb(runtime, rooted, null));

    // Copy is the sanctioned door back to ordinary mutable ownership.
    const copied = try containers.copyVerb(runtime, rooted);
    try testing.expectEqual(heap.Owner.Kind.loose, (try runtime.resolve(copied)).owner.kind);
    try containers.append(runtime, copied, Value.ofLong(8));
    try testing.expectEqual(@as(i64, 2), (try containers.length(runtime, copied)).asLong());
    try testing.expectEqual(@as(i64, 1), runtime.leaked());
    runtime.freeObject(copied.asObject());
    try testing.expectEqual(@as(i64, 0), runtime.leaked());
}

test "every boxed container mutation refuses a program root without consuming a borrow" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    try runtime.beginConstants(4);

    const list = try runtime.newList(Value.ofString(""));
    try containers.append(runtime, list, try runtime.ownValue(Value.ofString("three")));
    try containers.append(runtime, list, try runtime.ownValue(Value.ofString("one")));
    try runtime.publishConstant(0, list);

    const map = try runtime.newMap();
    try containers.indexSet(runtime, map, &.{Value.ofString("a")}, Value.ofLong(1));
    try runtime.publishConstant(1, map);

    const array = try runtime.newArray(&.{3}, Value.ofLong(0));
    try runtime.publishConstant(2, array);

    // Builder is not a legal constant-container pool row.  Rooting
    // one by hand proves the shared mutation gate stays total for a
    // damaged artifact instead of leaving one object kind writable.
    const builder = try runtime.newBuilder();
    try containers.append(runtime, builder, Value.ofString("seed"));
    try runtime.publishConstant(3, builder);
    runtime.finishConstants();

    const long_text = "this value owns storage beyond the inline capacity";

    // The three consuming list stores release what they were handed
    // even though the immutable check is the point that rejects them.
    try expectTrap(
        .immutable_object,
        runtime,
        containers.indexSet(
            runtime,
            list,
            &.{Value.ofLong(0)},
            try runtime.ownValue(Value.ofString(long_text)),
        ),
    );
    try expectTrap(
        .immutable_object,
        runtime,
        containers.append(runtime, list, try runtime.ownValue(Value.ofString(long_text))),
    );
    try expectTrap(
        .immutable_object,
        runtime,
        containers.insert(runtime, list, 0, try runtime.ownValue(Value.ofString(long_text))),
    );
    try expectTrap(.immutable_object, runtime, containers.pop(runtime, list));
    try expectTrap(.immutable_object, runtime, containers.remove(runtime, list, Value.ofLong(0)));
    try expectTrap(.immutable_object, runtime, containers.sort(runtime, list));
    try expectTrap(.immutable_object, runtime, containers.reverse(runtime, list));
    try expectTrap(.immutable_object, runtime, containers.clear(runtime, list));

    try expectTrap(
        .immutable_object,
        runtime,
        containers.indexSet(
            runtime,
            map,
            &.{Value.ofString("b")},
            try runtime.ownValue(Value.ofString(long_text)),
        ),
    );
    try expectTrap(.immutable_object, runtime, containers.remove(runtime, map, Value.ofString("a")));
    try expectTrap(
        .immutable_object,
        runtime,
        containers.mapPlace(runtime, map, Value.ofString("a"), Value.ofLong(0)),
    );
    try expectTrap(.immutable_object, runtime, containers.clear(runtime, map));

    try expectTrap(
        .immutable_object,
        runtime,
        containers.indexSet(runtime, array, &.{Value.ofLong(0)}, Value.ofLong(1)),
    );
    try expectTrap(.immutable_object, runtime, containers.arrayFill(runtime, array, Value.ofLong(2)));

    // Builder append is a borrow, unlike List append.  The failed
    // mutation must leave the caller's owned String intact.
    const borrowed = try runtime.ownValue(Value.ofString(long_text));
    defer runtime.dropStorage(borrowed);
    try expectTrap(.immutable_object, runtime, containers.append(runtime, builder, borrowed));
    try testing.expectEqualStrings(long_text, borrowed.asString());
    try expectTrap(.immutable_object, runtime, containers.appendAscii(runtime, builder, 'x'));
    try expectTrap(.immutable_object, runtime, containers.clear(runtime, builder));

    try testing.expectEqual(@as(i64, 0), runtime.leaked());
}

test "a host read cannot write into a program-root byte array" {
    const Host = struct {
        calls: usize = 0,

        fn read(
            context: ?*anyopaque,
            _: i64,
            _: [*]u8,
            _: i64,
            _: *i64,
        ) callconv(.c) i32 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            return files.yes;
        }
    };

    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;
    var host: Host = .{};
    runtime.files = .{ .context = &host, .read = Host.read };

    try runtime.beginConstants(1);
    const bytes = try runtime.newArray(&.{8}, Value.ofByte(0));
    try runtime.publishConstant(0, bytes);
    runtime.finishConstants();
    const file = try runtime.newFile(17, "input.bin");

    try expectTrap(.immutable_object, runtime, files.read(runtime, file, bytes));
    try testing.expectEqual(@as(usize, 0), host.calls);
    runtime.freeObject(file.asObject());
}

test "whole-file callbacks take Effects one callback at a time" {
    const Host = struct {
        effects: *workers.Effects,
        active: std.atomic.Value(u32) = .init(0),
        next_handle: std.atomic.Value(i64) = .init(0),
        opens: std.atomic.Value(u32) = .init(0),
        reads: std.atomic.Value(u32) = .init(0),
        writes: std.atomic.Value(u32) = .init(0),
        flushes: std.atomic.Value(u32) = .init(0),
        closes: std.atomic.Value(u32) = .init(0),
        wrong_depth: std.atomic.Value(bool) = .init(false),
        overlapped: std.atomic.Value(bool) = .init(false),

        fn observe(self: *@This()) void {
            const this_thread: usize = @intCast(std.Thread.getCurrentId());
            const owns = self.effects.owner.load(.acquire) == this_thread;
            if (!owns or self.effects.depth != 1) self.wrong_depth.store(true, .release);
            if (self.active.fetchAdd(1, .acq_rel) != 0) {
                self.overlapped.store(true, .release);
            }
            // Give a competing callback ample opportunity to expose a
            // missing guard without making the test depend on a timer.
            for (0..128) |_| std.Thread.yield() catch {};
            _ = self.active.fetchSub(1, .acq_rel);
        }

        fn open(
            context: ?*anyopaque,
            _: [*]const u8,
            _: i64,
            _: i64,
            handle: *i64,
        ) callconv(.c) i32 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.observe();
            _ = self.opens.fetchAdd(1, .monotonic);
            handle.* = self.next_handle.fetchAdd(1, .monotonic);
            return files.yes;
        }

        fn read(
            context: ?*anyopaque,
            _: i64,
            _: [*]u8,
            _: i64,
            filled: *i64,
        ) callconv(.c) i32 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.observe();
            _ = self.reads.fetchAdd(1, .monotonic);
            filled.* = 0;
            return files.yes;
        }

        fn write(
            context: ?*anyopaque,
            _: i64,
            _: [*]const u8,
            length: i64,
            written: *i64,
        ) callconv(.c) i32 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.observe();
            _ = self.writes.fetchAdd(1, .monotonic);
            written.* = length;
            return files.yes;
        }

        fn flush(context: ?*anyopaque, _: i64) callconv(.c) i32 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.observe();
            _ = self.flushes.fetchAdd(1, .monotonic);
            return files.yes;
        }

        fn close(context: ?*anyopaque, _: i64) callconv(.c) i32 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.observe();
            _ = self.closes.fetchAdd(1, .monotonic);
            return files.yes;
        }
    };

    const Work = struct {
        const Kind = enum { read, write };

        runtime: *Runtime,
        ready: *std.atomic.Value(u32),
        start: *std.atomic.Value(bool),
        kind: Kind,
        worked: bool = false,

        fn run(self: *@This()) void {
            _ = self.ready.fetchAdd(1, .release);
            while (!self.start.load(.acquire)) std.Thread.yield() catch {};
            switch (self.kind) {
                .read => {
                    const answer = files.readText(self.runtime, "read.txt") catch return;
                    const held = answer orelse return;
                    self.runtime.dropStorage(held);
                    self.worked = true;
                },
                .write => self.worked = files.writeText(
                    self.runtime,
                    "write.txt",
                    "bytes",
                    .write,
                ) catch false,
            }
        }
    };

    var first: Bench = undefined;
    first.setup();
    defer first.deinit();
    var second: Bench = undefined;
    second.setup();
    defer second.deinit();

    const effects = try first.runtime.sharedEffects();
    second.runtime.effects = effects;
    var host: Host = .{ .effects = effects };
    const channel: files.Channel = .{
        .context = &host,
        .open = Host.open,
        .read = Host.read,
        .write = Host.write,
        .flush = Host.flush,
        .close = Host.close,
    };
    first.runtime.files = channel;
    second.runtime.files = channel;

    var ready: std.atomic.Value(u32) = .init(0);
    var start: std.atomic.Value(bool) = .init(false);
    var reading: Work = .{
        .runtime = &first.runtime,
        .ready = &ready,
        .start = &start,
        .kind = .read,
    };
    var writing: Work = .{
        .runtime = &second.runtime,
        .ready = &ready,
        .start = &start,
        .kind = .write,
    };
    var reader: ?std.Thread = try std.Thread.spawn(.{}, Work.run, .{&reading});
    errdefer {
        start.store(true, .release);
        if (reader) |thread| thread.join();
    }
    const writer = try std.Thread.spawn(.{}, Work.run, .{&writing});
    while (ready.load(.acquire) != 2) std.Thread.yield() catch {};
    start.store(true, .release);
    reader.?.join();
    reader = null;
    writer.join();

    try testing.expect(reading.worked);
    try testing.expect(writing.worked);
    try testing.expect(!host.wrong_depth.load(.acquire));
    try testing.expect(!host.overlapped.load(.acquire));
    try testing.expectEqual(@as(u32, 2), host.opens.load(.acquire));
    try testing.expectEqual(@as(u32, 1), host.reads.load(.acquire));
    try testing.expectEqual(@as(u32, 1), host.writes.load(.acquire));
    try testing.expectEqual(@as(u32, 1), host.flushes.load(.acquire));
    try testing.expectEqual(@as(u32, 2), host.closes.load(.acquire));
}

test "a failed file allocation closes its successful host open exactly once" {
    const Host = struct {
        effects: *workers.Effects,
        handle: i64,
        opened: usize = 0,
        closed: usize = 0,
        closed_handle: i64 = -1,
        callbacks_guarded: bool = true,

        fn guarded(self: *@This()) bool {
            const this_thread: usize = @intCast(std.Thread.getCurrentId());
            return self.effects.owner.load(.acquire) == this_thread and
                self.effects.depth == 1;
        }

        fn open(
            context: ?*anyopaque,
            _: [*]const u8,
            _: i64,
            _: i64,
            handle: *i64,
        ) callconv(.c) i32 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.callbacks_guarded = self.callbacks_guarded and self.guarded();
            self.opened += 1;
            handle.* = self.handle;
            return files.yes;
        }

        fn close(context: ?*anyopaque, handle: i64) callconv(.c) i32 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.callbacks_guarded = self.callbacks_guarded and self.guarded();
            self.closed += 1;
            self.closed_handle = handle;
            // Close has no error channel at scope end.  Its answer must
            // not replace the allocation failure which led us here.
            return files.no;
        }
    };

    // `newFile` allocates the copied path and then, when there is no
    // reusable row, the object table.  Refuse each in turn.
    for (0..2) |failure_offset| {
        var objects: std.testing.FailingAllocator = .init(testing.allocator, .{});
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        var runtime: Runtime = .init(.{
            .arena = arena.allocator(),
            .objects = objects.allocator(),
        });
        const effects = try runtime.sharedEffects();
        var host: Host = .{
            .effects = effects,
            .handle = 70 + @as(i64, @intCast(failure_offset)),
        };
        runtime.files = .{
            .context = &host,
            .open = Host.open,
            .close = Host.close,
        };
        objects.fail_index = objects.alloc_index + failure_offset;

        const outcome = files.open(&runtime, "allocation.txt", @intFromEnum(files.Mode.read));
        const live = runtime.live;
        const exhausted_run = runtime.exhausted;
        const trapped = runtime.pending != null;
        runtime.deinit();
        arena.deinit();

        try testing.expectError(error.OutOfMemory, outcome);
        try testing.expectEqual(@as(u32, 0), live);
        try testing.expect(!exhausted_run);
        try testing.expect(!trapped);
        try testing.expect(host.callbacks_guarded);
        try testing.expectEqual(@as(usize, 1), host.opened);
        try testing.expectEqual(@as(usize, 1), host.closed);
        try testing.expectEqual(host.handle, host.closed_handle);
        try testing.expectEqual(objects.allocated_bytes, objects.freed_bytes);
    }
}

test "file open fails closed before acquisition when the host cannot close" {
    const Host = struct {
        opened: usize = 0,

        fn open(
            context: ?*anyopaque,
            _: [*]const u8,
            _: i64,
            _: i64,
            _: *i64,
        ) callconv(.c) i32 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.opened += 1;
            return files.yes;
        }
    };

    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    var host: Host = .{};
    bench.runtime.files = .{ .context = &host, .open = Host.open };

    try expectTrap(
        .host_unavailable,
        &bench.runtime,
        files.open(&bench.runtime, "cannot-close.txt", @intFromEnum(files.Mode.read)),
    );
    try testing.expectEqual(@as(usize, 0), host.opened);
    try testing.expectEqual(@as(u32, 0), bench.runtime.live);
}

test "failed materialization discards its partial object and every published root" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    try runtime.beginConstants(2);
    const published = try runtime.newList(Value.ofString(""));
    try containers.append(
        runtime,
        published,
        try runtime.ownValue(Value.ofString("published storage lives here")),
    );
    try runtime.publishConstant(0, published);

    const partial = try runtime.newMap();
    try containers.indexSet(
        runtime,
        partial,
        &.{Value.ofString("long key that owns its bytes")},
        try runtime.ownValue(Value.ofString("partial storage lives here too")),
    );
    runtime.discardLoose(partial);
    runtime.abortConstants();

    try testing.expectEqual(@as(u32, 0), runtime.live);
    try testing.expectEqual(@as(u32, 0), runtime.program_root_count);
    try testing.expectEqual(@as(usize, 0), runtime.constant_roots.len);
    try testing.expect(!runtime.materializing_constants);
    try testing.expectEqual(@as(i64, 0), runtime.leaked());
    try expectTrap(.use_after_free, runtime, runtime.resolve(published));
    try expectTrap(.use_after_free, runtime, runtime.resolve(partial));
}

test "runtime teardown releases ordinary rows before the program root" {
    const Host = struct {
        handles: [2]i64 = undefined,
        count: usize = 0,

        fn close(context: ?*anyopaque, handle: i64) callconv(.c) i32 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.handles[self.count] = handle;
            self.count += 1;
            return files.yes;
        }
    };

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var runtime: Runtime = .init(.{
        .arena = arena.allocator(),
        .objects = testing.allocator,
    });
    var host: Host = .{};
    runtime.files = .{ .context = &host, .close = Host.close };

    // A file cannot be a source-level constant.  It makes destruction
    // order observable, though, so this hand-made runtime state proves
    // the two teardown passes rather than merely reading their code.
    try runtime.beginConstants(1);
    const rooted = try runtime.newFile(11, "root");
    try runtime.publishConstant(0, rooted);
    runtime.finishConstants();
    _ = try runtime.newFile(22, "ordinary");
    try testing.expectEqual(@as(i64, 1), runtime.leaked());

    runtime.deinit();
    try testing.expectEqual(@as(usize, 2), host.count);
    try testing.expectEqual(@as(i64, 22), host.handles[0]);
    try testing.expectEqual(@as(i64, 11), host.handles[1]);
}

test "objects inside a struct value are walked, not skipped" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    var fields = [_]Value{ Value.ofLong(1), try runtime.newList(Value.none) };
    const record = Value.ofStruct(&fields);
    const serial = runtime.takeSerial();
    runtime.bind(record, serial, 0);
    const owner = (try runtime.resolve(fields[1])).owner;
    try testing.expectEqual(heap.Owner.Kind.binding, owner.kind);
    try testing.expectEqual(serial, owner.details.binding.serial);
    try testing.expectEqual(@as(u32, 0), owner.details.binding.local);
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
        const list = try runtime.newList(Value.none);
        for (0..64) |number| {
            try containers.append(&runtime, list, Value.ofLong(@intCast(number)));
        }
        const map = try runtime.newMap();
        for (0..64) |number| {
            const key = Value.ofLong(@intCast(number));
            try containers.indexSet(&runtime, map, &.{key}, Value.ofLong(0));
        }
        const builder = try runtime.newBuilder();
        for (0..64) |_| try containers.append(&runtime, builder, Value.ofString("word"));
        const array = try runtime.newArray(&.{ 8, 8 }, Value.ofLong(0));

        runtime.freeObject(list.asObject());
        runtime.freeObject(map.asObject());
        runtime.freeObject(builder.asObject());
        runtime.freeObject(array.asObject());
    }
    try testing.expectEqual(@as(u32, 0), runtime.live);

    // Everything but the object table itself, which is retained to be
    // reused: this loop makes four objects at a time and frees them,
    // so four rows serve all eight rounds and the table never reaches
    // even its old high-water mark.
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
        const key = Value.ofLong(@intCast(number * 7));
        try containers.indexSet(runtime, map, &.{key}, Value.ofLong(@intCast(number)));
    }
    try testing.expectEqual(@as(i64, count), (try containers.length(runtime, map)).asLong());
    for (0..count) |number| {
        const key = Value.ofLong(@intCast(number * 7));
        const found = try containers.indexGet(runtime, map, &.{key});
        try testing.expectEqual(@as(i64, @intCast(number)), found.asLong());
        try testing.expectEqual(key.asLong(), (try containers.keyAt(runtime, map, @intCast(number))).asLong());
    }
    // A key that was never stored is absent however close it hashes.
    try testing.expect(!(try containers.hasKey(runtime, map, Value.ofLong(3))).asBoolean());

    // Removal renumbers the entries; the survivors keep their order
    // and still look up.
    for (0..count) |number| {
        if (number % 2 == 0) continue;
        try containers.remove(runtime, map, Value.ofLong(@intCast(number * 7)));
    }
    try testing.expectEqual(@as(i64, count / 2), (try containers.length(runtime, map)).asLong());
    for (0..count / 2) |position| {
        const wanted: i64 = @intCast(position * 14);
        try testing.expectEqual(wanted, (try containers.keyAt(runtime, map, @intCast(position))).asLong());
        try testing.expect((try containers.hasKey(runtime, map, Value.ofLong(wanted))).asBoolean());
    }
    runtime.freeObject(map.asObject());
}

test "map keys hash as they compare, for long and for String" {
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
    try containers.indexSet(runtime, map, &.{Value.ofString(&first)}, Value.ofLong(1));
    try containers.indexSet(runtime, map, &.{Value.ofString(&second)}, Value.ofLong(2));
    try testing.expectEqual(@as(i64, 1), (try containers.length(runtime, map)).asLong());
    try testing.expectEqual(
        @as(i64, 2),
        (try containers.indexGet(runtime, map, &.{Value.ofString("abc")})).asLong(),
    );

    // Negative long keys travel through the same bit mixer as positive
    // ones and come back.
    const numbers = try runtime.newMap();
    for ([_]i64{ -1, 0, 1, std.math.minInt(i64), std.math.maxInt(i64) }) |key| {
        try containers.indexSet(runtime, numbers, &.{Value.ofLong(key)}, Value.ofLong(key));
    }
    for ([_]i64{ -1, 0, 1, std.math.minInt(i64), std.math.maxInt(i64) }) |key| {
        try testing.expectEqual(
            key,
            (try containers.indexGet(runtime, numbers, &.{Value.ofLong(key)})).asLong(),
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

    const held = try runtime.newList(Value.none);
    try containers.append(runtime, held, Value.ofLong(10));
    try containers.append(runtime, held, Value.ofLong(30));
    try containers.insert(runtime, held, 1, Value.ofLong(20));
    try testing.expectEqual(@as(i64, 3), (try containers.length(runtime, held)).asLong());
    try testing.expectEqual(
        @as(i64, 20),
        (try containers.indexGet(runtime, held, &.{Value.ofLong(1)})).asLong(),
    );

    try containers.indexSet(runtime, held, &.{Value.ofLong(0)}, Value.ofLong(-1));
    try testing.expectEqual(@as(i64, 1), try containers.find(runtime, held, Value.ofLong(20)));
    try testing.expectEqual(@as(i64, -1), try containers.find(runtime, held, Value.ofLong(99)));

    try testing.expectEqual(@as(i64, 30), (try containers.pop(runtime, held)).asLong());
    try containers.remove(runtime, held, Value.ofLong(0));
    try testing.expectEqual(@as(i64, 1), (try containers.length(runtime, held)).asLong());

    try expectTrap(
        .index_bounds,
        runtime,
        containers.indexGet(runtime, held, &.{Value.ofLong(5)}),
    );
    try containers.clear(runtime, held);
    try expectTrap(.empty_collection, runtime, containers.pop(runtime, held));
}

// Every bounded operation, at the index on each side of its bound.
// One-sided coverage is what lets an off-by-one live: a test that only
// ever asks for index 5 of a three-element list passes whether the
// comparison is `>=` or `>`, and the difference between those two is
// a write past the end.  So each of these names a boundary and asks
// for the last legal index and the first illegal one.

test "every list bound is checked at the last legal index and the first illegal one" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const held = try runtime.newList(Value.none);
    for ([_]i64{ 10, 20, 30 }) |element| try containers.append(runtime, held, Value.ofLong(element));

    // Reading: 0 and len-1 answer, -1 and len trap.
    try testing.expectEqual(@as(i64, 10), (try containers.indexGet(runtime, held, &.{Value.ofLong(0)})).asLong());
    try testing.expectEqual(@as(i64, 30), (try containers.indexGet(runtime, held, &.{Value.ofLong(2)})).asLong());
    try expectTrap(.index_bounds, runtime, containers.indexGet(runtime, held, &.{Value.ofLong(3)}));
    try expectTrap(.index_bounds, runtime, containers.indexGet(runtime, held, &.{Value.ofLong(-1)}));

    // Writing has the same bound, and it is a separate comparison.
    try containers.indexSet(runtime, held, &.{Value.ofLong(2)}, Value.ofLong(31));
    try expectTrap(
        .index_bounds,
        runtime,
        containers.indexSet(runtime, held, &.{Value.ofLong(3)}, Value.ofLong(0)),
    );
    try expectTrap(
        .index_bounds,
        runtime,
        containers.indexSet(runtime, held, &.{Value.ofLong(-1)}, Value.ofLong(0)),
    );

    // Insert is the one whose bound is *not* the same as the others:
    // `xs.insert(len, v)` appends, so len is legal and len+1 is not.
    // Reading this bound as "like index_get" is an off-by-one that
    // silently loses the append form.
    try containers.insert(runtime, held, 3, Value.ofLong(40));
    try testing.expectEqual(@as(i64, 4), (try containers.length(runtime, held)).asLong());
    try testing.expectEqual(@as(i64, 40), (try containers.indexGet(runtime, held, &.{Value.ofLong(3)})).asLong());
    try containers.insert(runtime, held, 0, Value.ofLong(5));
    try testing.expectEqual(@as(i64, 5), (try containers.indexGet(runtime, held, &.{Value.ofLong(0)})).asLong());
    try expectTrap(.index_bounds, runtime, containers.insert(runtime, held, 6, Value.ofLong(0)));
    try expectTrap(.index_bounds, runtime, containers.insert(runtime, held, -1, Value.ofLong(0)));
    try testing.expectEqual(@as(i64, 5), (try containers.length(runtime, held)).asLong());

    // Remove is bounded like a read: len-1 is the last element there
    // is to take out.
    try containers.remove(runtime, held, Value.ofLong(4));
    try expectTrap(.index_bounds, runtime, containers.remove(runtime, held, Value.ofLong(4)));
    try expectTrap(.index_bounds, runtime, containers.remove(runtime, held, Value.ofLong(-1)));

    // A slice is half-open: end may be len, start may equal end, and
    // an inverted pair is refused rather than answered empty.
    const whole = bench.made(try containers.listSlice(runtime, held, 0, 4));
    try testing.expectEqual(@as(i64, 4), (try containers.length(runtime, whole)).asLong());
    const empty = bench.made(try containers.listSlice(runtime, held, 4, 4));
    try testing.expectEqual(@as(i64, 0), (try containers.length(runtime, empty)).asLong());
    try expectTrap(.index_bounds, runtime, containers.listSlice(runtime, held, 0, 5));
    try expectTrap(.index_bounds, runtime, containers.listSlice(runtime, held, 3, 2));
    try expectTrap(.index_bounds, runtime, containers.listSlice(runtime, held, -1, 2));

    // And pop empties before it complains: the last element comes out,
    // and only the call after that has nothing to answer.
    for (0..4) |_| _ = try containers.pop(runtime, held);
    try expectTrap(.empty_collection, runtime, containers.pop(runtime, held));
}

test "every map and array bound is checked on both sides too" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const held = try runtime.newMap();
    try containers.indexSet(runtime, held, &.{Value.ofString("a")}, Value.ofLong(1));
    try containers.indexSet(runtime, held, &.{Value.ofString("b")}, Value.ofLong(2));

    // Positional access over a map's entries is bounded by its count.
    try testing.expectEqualStrings("b", (try containers.keyAt(runtime, held, 1)).asString());
    try testing.expectEqual(@as(i64, 2), (try containers.valueAt(runtime, held, 1)).asLong());
    try expectTrap(.index_bounds, runtime, containers.keyAt(runtime, held, 2));
    try expectTrap(.index_bounds, runtime, containers.keyAt(runtime, held, -1));
    try expectTrap(.index_bounds, runtime, containers.valueAt(runtime, held, 2));
    try expectTrap(.index_bounds, runtime, containers.valueAt(runtime, held, -1));

    // A key a map does not hold traps on read, and removing one does
    // nothing at all — the two are different questions on purpose.
    try expectTrap(.key_missing, runtime, containers.indexGet(runtime, held, &.{Value.ofString("z")}));
    try containers.remove(runtime, held, Value.ofString("z"));
    try testing.expectEqual(@as(i64, 2), (try containers.length(runtime, held)).asLong());

    // Every axis of an array is bounded independently, and so is the
    // axis number `dim_size` is asked about.
    const grid = try runtime.newArray(&.{ 2, 3 }, Value.ofLong(0));
    try containers.indexSet(runtime, grid, &.{ Value.ofLong(1), Value.ofLong(2) }, Value.ofLong(7));
    try testing.expectEqual(@as(i64, 7), (try containers.indexGet(
        runtime,
        grid,
        &.{ Value.ofLong(1), Value.ofLong(2) },
    )).asLong());
    try expectTrap(.index_bounds, runtime, containers.indexGet(runtime, grid, &.{ Value.ofLong(2), Value.ofLong(2) }));
    try expectTrap(.index_bounds, runtime, containers.indexGet(runtime, grid, &.{ Value.ofLong(1), Value.ofLong(3) }));
    try expectTrap(.index_bounds, runtime, containers.indexGet(runtime, grid, &.{ Value.ofLong(-1), Value.ofLong(0) }));
    try expectTrap(.index_bounds, runtime, containers.indexGet(runtime, grid, &.{ Value.ofLong(0), Value.ofLong(-1) }));
    try testing.expectEqual(@as(i64, 2), (try containers.dimSize(runtime, grid, 0)).asLong());
    try testing.expectEqual(@as(i64, 3), (try containers.dimSize(runtime, grid, 1)).asLong());
    try expectTrap(.index_bounds, runtime, containers.dimSize(runtime, grid, 2));
    try expectTrap(.index_bounds, runtime, containers.dimSize(runtime, grid, -1));

    // A Builder's bytes are ASCII, so its bound is a codepoint range:
    // 0x7F is the last byte that is one, and 0x80 is the first that is
    // not.
    const builder = try runtime.newBuilder();
    try containers.appendAscii(runtime, builder, 0);
    try containers.appendAscii(runtime, builder, 0x7F);
    try expectTrap(.bad_codepoint, runtime, containers.appendAscii(runtime, builder, 0x80));
    try expectTrap(.bad_codepoint, runtime, containers.appendAscii(runtime, builder, -1));
    try testing.expectEqual(@as(i64, 2), (try containers.length(runtime, builder)).asLong());
}

test "maps keep insertion order and answer for missing keys three ways" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const held = try runtime.newMap();
    try containers.indexSet(runtime, held, &.{Value.ofString("b")}, Value.ofLong(2));
    try containers.indexSet(runtime, held, &.{Value.ofString("a")}, Value.ofLong(1));
    try testing.expectEqualStrings("b", (try containers.keyAt(runtime, held, 0)).asString());
    try testing.expectEqual(@as(i64, 1), (try containers.valueAt(runtime, held, 1)).asLong());

    // has_key answers false, get answers the default, m[key] traps.
    try testing.expect(!(try containers.hasKey(runtime, held, Value.ofString("c"))).asBoolean());
    try testing.expectEqual(@as(i64, 9), (try containers.mapGet(
        runtime,
        held,
        Value.ofString("c"),
        Value.ofLong(9),
    )).asLong());
    try expectTrap(
        .key_missing,
        runtime,
        containers.indexGet(runtime, held, &.{Value.ofString("c")}),
    );

    const keys = try containers.mapKeys(runtime, held, Value.ofString(""));
    try testing.expectEqual(@as(i64, 2), (try containers.length(runtime, keys)).asLong());
}

test "a list the runtime builds is packed the way its element type says" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    // The whole of the inline path below rests on this: an element's
    // storage width is a fact of the program's type, not of the code
    // that happened to build the list (docs/BYTES.md R1).  A map of
    // long to double answers two *packed* lists.
    const held = try runtime.newMap();
    try containers.indexSet(runtime, held, &.{Value.ofLong(7)}, Value.ofDouble(0.5));

    const keys = try containers.mapKeys(runtime, held, Value.ofLong(0));
    try testing.expectEqual(heap.Object.ElementKind.long, (try runtime.resolve(keys)).elements.kind);
    try testing.expectEqual(@as(i64, 7), (try containers.indexGet(
        runtime,
        keys,
        &.{Value.ofLong(0)},
    )).asLong());

    const values = try containers.mapValues(runtime, held, Value.ofDouble(0));
    try testing.expectEqual(
        heap.Object.ElementKind.double,
        (try runtime.resolve(values)).elements.kind,
    );
    try testing.expectEqual(@as(f64, 0.5), (try containers.indexGet(
        runtime,
        values,
        &.{Value.ofLong(0)},
    )).asDouble());
}

test "arrays flatten multi-dimensional indices and refuse an oversized shape" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const grid = try runtime.newArray(&.{ 2, 3 }, Value.ofLong(0));
    try containers.indexSet(runtime, grid, &.{ Value.ofLong(1), Value.ofLong(2) }, Value.ofLong(5));
    try testing.expectEqual(@as(i64, 5), (try containers.indexGet(
        runtime,
        grid,
        &.{ Value.ofLong(1), Value.ofLong(2) },
    )).asLong());
    try testing.expectEqual(@as(i64, 3), (try containers.dimSize(runtime, grid, 1)).asLong());
    try expectTrap(
        .index_bounds,
        runtime,
        containers.indexGet(runtime, grid, &.{ Value.ofLong(2), Value.ofLong(0) }),
    );

    // Both refusals happen before anything is allocated, which is what
    // makes them testable: the first shape's product overflows a
    // `usize`, and the second is past the `byte` ceiling docs/VECTOR.md's
    // reduction proof depends on.  A shape that merely needs more memory
    // than the machine has reaches the same trap from the allocator.
    try testing.expectError(error.Trap, runtime.newArray(&.{ 1 << 40, 1 << 40 }, Value.none));
    try testing.expectEqual(vocabulary.TrapCode.allocation_failed, runtime.pending.?.code);
    try testing.expectError(error.Trap, runtime.newArray(&.{1 << 41}, Value.ofByte(0)));
    try testing.expectEqual(vocabulary.TrapCode.allocation_failed, runtime.pending.?.code);
}

test "the element ceilings are the ones docs/VECTOR.md's proof needs" {
    // Recomputed from the proof's own obligation rather than read off
    // the table: `N · M` must stay inside a `long`, in `i128` because
    // `i64` is the width the arithmetic is about.
    const largest: i128 = std.math.maxInt(i64);
    inline for (.{
        .{ heap.Object.ElementKind.byte, 255 * 32768 },
        .{ heap.Object.ElementKind.short, 1 << 30 },
        .{ heap.Object.ElementKind.int, 1 << 31 },
    }) |row| {
        const ceiling: i128 = heap.maxElements(row[0]);
        try testing.expect(ceiling * row[1] <= largest);
        try testing.expect((ceiling + 1) * row[1] > largest);
    }
    // The kinds no integer reduction can name carry no obligation, so
    // their only ceiling is what keeps a byte count addressable.
    try testing.expectEqual(
        @as(usize, std.math.maxInt(usize) / 8),
        heap.maxElements(.long),
    );
}

test "compiled code's byte offsets find the fields they name" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const grid = try runtime.newArray(&.{ 2, 3 }, Value.ofDouble(0.0));
    try containers.indexSet(runtime, grid, &.{ Value.ofLong(1), Value.ofLong(2) }, Value.ofDouble(7.5));
    try runtime.beginConstants(1);
    const rooted = try runtime.newList(Value.ofLong(0));
    try runtime.publishConstant(0, rooted);
    runtime.finishConstants();

    // Exactly the walk `08_llvm/lower.zig` emits: the table base out of
    // the `Runtime`, the row by handle, then `generation`, `count`,
    // `dims`, and `elements` out of the row — every step through
    // `heap.layout`'s numbers and nothing through a field name.
    const base: [*]const u8 = @ptrCast(runtime);
    const table: [*]const u8 = @as(*const [*]const u8, @ptrCast(@alignCast(
        base + heap.layout.table_pointer,
    ))).*;
    try testing.expectEqual(@intFromPtr(runtime.table.items.ptr), @intFromPtr(table));

    // The other direct walk generated code makes: a constant-pool
    // slot through the runtime's program-root table, followed by the
    // owner-kind check used at inline writes.
    const roots: [*]const Value = @ptrCast(@alignCast(@as(*const [*]const u8, @ptrCast(@alignCast(
        base + heap.layout.constant_roots_pointer,
    ))).*));
    try testing.expectEqual(@intFromPtr(runtime.constant_roots.ptr), @intFromPtr(roots));
    try testing.expectEqual(@as(usize, 1), @as(*const usize, @ptrCast(@alignCast(
        base + heap.layout.constant_roots_count,
    ))).*);
    try testing.expect(roots[0].asObject().same(rooted.asObject()));
    const rooted_row = table + heap.layout.row_size * rooted.asObject().index;
    const owner_kind: *const u32 = @ptrCast(@alignCast(rooted_row + heap.layout.owner_kind));
    try testing.expectEqual(heap.layout.owner_program, owner_kind.*);

    const row = table + heap.layout.row_size * grid.asObject().index;
    const generation: *const u32 = @ptrCast(@alignCast(row + heap.layout.generation));
    try testing.expectEqual(grid.asObject().generation, generation.*);
    const dims: [*]const i64 = @ptrCast(@alignCast(@as(*const [*]const u8, @ptrCast(@alignCast(
        row + heap.layout.array_dims,
    ))).*));
    try testing.expectEqual(@as(i64, 2), dims[0]);
    try testing.expectEqual(@as(i64, 3), dims[1]);
    try testing.expectEqual(@as(usize, 6), @as(*const usize, @ptrCast(@alignCast(
        row + heap.layout.elements_count,
    ))).*);
    // An `Array(double)` stores `f64`s, so the element is one load and
    // no unboxing — which is the whole reason the storage is typed.
    const elements: [*]const f64 = @ptrCast(@alignCast(@as(*const [*]const u8, @ptrCast(@alignCast(
        row + heap.layout.elements_pointer,
    ))).*));
    try testing.expectEqual(@as(f64, 7.5), elements[1 * 3 + 2]);

    // A freed row reads dead through the same offset, which is what
    // makes the inline `use_after_free` check one load and one
    // compare: the generation has moved past the handle's.
    runtime.freeObject(grid.asObject());
    try testing.expect(generation.* != grid.asObject().generation);

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

test "text owns, releases and leaves the frame the same on both sides of 22 bytes" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    var words: [128]u8 = undefined;
    for (&words, 0..) |*byte, index| byte.* = @intCast('a' + index % 26);

    // Every length the two forms meet at, and one well past it.  Each
    // one goes the whole way round: owned into a place, read back,
    // handed out of a frame, and released — under the test allocator,
    // so a storage class that frees what it does not own or keeps what
    // it does is a reported double free or a reported leak.
    const lengths = [_]usize{ 0, 1, 21, 22, 23, 64 };
    for (lengths) |length| {
        const wanted = words[0..length];
        const owned = try runtime.ownValue(Value.ofString(wanted));
        try testing.expectEqualStrings(wanted, owned.asString());
        try testing.expectEqual(Value.fitsInline(length), owned.textIsInline());
        try testing.expectEqual(!Value.fitsInline(length), owned.ownsStorage());

        // A slice of owned text follows the form it came from, so a
        // view of inline bytes is never a view of somebody's frame.
        const cut = try text.slice(runtime, owned, 0, @intCast(length));
        try testing.expectEqual(owned.textIsInline(), cut.textIsInline());
        try testing.expectEqualStrings(wanted, cut.asString());

        // Leaving the frame always answers text with an address, and
        // does it by transfer when there already was one.
        const handed = try runtime.exportValue(owned);
        try testing.expect(!handed.textIsInline());
        try testing.expectEqualStrings(wanted, handed.asString());
        if (!Value.fitsInline(length)) {
            try testing.expectEqual(owned.bits, handed.bits);
        }
        runtime.dropStorage(handed);

        // And releasing a place twice frees nothing the second time.
        const emptied = heap.Runtime.emptied(handed);
        try testing.expectEqualStrings("", emptied.asString());
        runtime.dropStorage(emptied);
    }

    // A store keeps what it is given, in whichever form fits, and the
    // container gives it back — while a map's key is still a borrow it
    // copies for itself (docs/STRINGS.md).
    const kept = try runtime.newList(Value.none);
    const table = try runtime.newMap();
    for (lengths) |length| {
        const wanted = words[0..length];
        try containers.append(runtime, kept, try runtime.ownValue(Value.ofString(wanted)));
        try containers.indexSet(runtime, table, &.{Value.ofString(wanted)}, Value.ofLong(1));
    }
    for (lengths, 0..) |length, index| {
        const held = try containers.indexGet(runtime, kept, &.{Value.ofLong(@intCast(index))});
        try testing.expectEqualStrings(words[0..length], held.asString());
    }
    try testing.expectEqual(@as(i64, lengths.len), (try containers.length(runtime, table)).asLong());
    runtime.freeObject(kept.asObject());
    runtime.freeObject(table.asObject());
}

test "str and chr answer text that needs no allocation at all" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    // Twenty digits and a sign is the widest an i64 gets, so no
    // number's text ever leaves the value it is answered in.
    for ([_]i64{ 0, -1, 9, 1234567, std.math.minInt(i64), std.math.maxInt(i64) }) |number| {
        const made = try text.str(runtime, Value.ofLong(number));
        try testing.expect(made.textIsInline());
        try testing.expect(!made.ownsStorage());
        var digits: [24]u8 = undefined;
        try testing.expectEqualStrings(
            try std.fmt.bufPrint(&digits, "{d}", .{number}),
            made.asString(),
        );
    }
    // A codepoint is four bytes at the most.
    for ([_]i64{ 0, 'a', 0x00e9, 0x10FFFF }) |code| {
        const made = try text.chr(runtime, code);
        try testing.expect(made.textIsInline());
    }
    // Text long enough to need one still allocates, and is released
    // like any other owned storage.
    const long = try text.str(runtime, Value.ofString("a" ** 40));
    try testing.expect(long.ownsStorage());
    runtime.dropStorage(long);
}

test "a builder collects bytes and str takes a snapshot of them" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const held = try runtime.newBuilder();
    try containers.append(runtime, held, Value.ofString("ab"));
    try containers.appendAscii(runtime, held, 'c');
    const taken = bench.made(try text.str(runtime, held));
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

    const held = try runtime.newList(Value.none);
    for ([_]i64{ 3, 1, 2 }) |number| try containers.append(runtime, held, Value.ofLong(number));
    try containers.sort(runtime, held);
    try testing.expectEqual(@as(i64, 1), (try containers.indexGet(runtime, held, &.{Value.ofLong(0)})).asLong());
    try containers.reverse(runtime, held);
    try testing.expectEqual(@as(i64, 3), (try containers.indexGet(runtime, held, &.{Value.ofLong(0)})).asLong());
}

test "a list slice copies its object elements rather than sharing them" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const held = try runtime.newList(Value.none);
    try containers.append(runtime, held, try runtime.newList(Value.none));
    const taken = try containers.listSlice(runtime, held, 0, 1);

    const original = try containers.indexGet(runtime, held, &.{Value.ofLong(0)});
    const copied = try containers.indexGet(runtime, taken, &.{Value.ofLong(0)});
    try testing.expect(!original.asObject().same(copied.asObject()));
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

    try testing.expectEqual(@as(i64, 0xf0), (try text.byteAt(runtime, held, 1)).asLong());
    try testing.expectEqual(@as(i64, 5), (try text.findByte(runtime, held, 'b', 0)).asLong());
    try testing.expectEqual(@as(i64, -1), (try text.findByte(runtime, held, 'z', 0)).asLong());
}

test "the conversions round trip and refuse what they cannot represent" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    try testing.expectEqualStrings("-12", bench.made(try text.str(runtime, Value.ofLong(-12))).asString());
    try testing.expectEqualStrings("true", bench.made(try text.str(runtime, Value.ofBoolean(true))).asString());
    // Shortest text that round trips, not a fixed number of digits.
    try testing.expectEqualStrings("0.1", bench.made(try text.str(runtime, Value.ofDouble(0.1))).asString());
    try testing.expectEqualStrings(
        "1000000000000000000000",
        bench.made(try text.str(runtime, Value.ofDouble(1e21))).asString(),
    );

    // The parsers answer absence rather than trapping: "not a number"
    // is the same reason every time and the name says it already.
    try testing.expectEqual(@as(i64, 42), (try text.parseInt(runtime, Value.ofString("42"))).asLong());
    try testing.expect((try text.parseInt(runtime, Value.ofString("4 2"))).isNone());
    try testing.expect((try text.parseInt(runtime, Value.ofString(""))).isNone());
    try testing.expectEqual(@as(f64, 1.5), (try text.parseFloat(runtime, Value.ofString("1.5"))).asDouble());
    try testing.expect((try text.parseFloat(runtime, Value.ofString("inf"))).isNone());
    try testing.expect((try text.parseFloat(runtime, Value.ofString("nan"))).isNone());
    try testing.expect((try text.parseFloat(runtime, Value.ofString("zero"))).isNone());

    try testing.expectEqualStrings(
        "\xF0\x9F\x99\x82",
        bench.made(try text.chr(runtime, 0x1F642)).asString(),
    );
    try expectTrap(.bad_codepoint, runtime, text.chr(runtime, 0x110000));
    try testing.expectEqual(@as(i64, 0x1F642), (try text.ord(runtime, Value.ofString("\xF0\x9F\x99\x82"))).asLong());
    try expectTrap(.bad_codepoint, runtime, text.ord(runtime, Value.ofString("")));
}

test "integer arithmetic is checked and float arithmetic is IEEE" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const biggest = Value.ofLong(std.math.maxInt(i64));
    try expectTrap(.integer_overflow, runtime, operators.binary(runtime, .add, biggest, Value.ofLong(1)));
    // The operators that still produce a long are the ones that still
    // trap: `/` answers a double and is IEEE (docs/NUMERICS.md §4).
    try expectTrap(.divide_by_zero, runtime, operators.binary(runtime, .floor_divide, biggest, Value.ofLong(0)));
    try expectTrap(.divide_by_zero, runtime, operators.binary(runtime, .modulo, biggest, Value.ofLong(0)));
    try expectTrap(
        .integer_overflow,
        runtime,
        operators.binary(runtime, .floor_divide, Value.ofLong(std.math.minInt(i64)), Value.ofLong(-1)),
    );
    try expectTrap(.integer_overflow, runtime, operators.negate(runtime, Value.ofLong(std.math.minInt(i64))));

    const divided = try operators.binary(runtime, .divide, Value.ofDouble(1.0), Value.ofDouble(0.0));
    try testing.expect(std.math.isInf(divided.asDouble()));
    // Negation keeps the sign of zero, which `0.0 - x` would not.
    try testing.expect(std.math.signbit((try operators.negate(runtime, Value.ofDouble(0.0))).asDouble()));

    try expectTrap(.conversion_range, runtime, operators.convert(runtime, Value.ofDouble(1e30), .long));
    // `long(x)` rounds half away from zero (docs/NUMERICS.md §7);
    // `trunc(x)` is how truncation is spelled now.
    try testing.expectEqual(@as(i64, -2), (try operators.convert(runtime, Value.ofDouble(-1.9), .long)).asLong());
    try testing.expectEqual(@as(i64, 3), (try operators.convert(runtime, Value.ofDouble(2.5), .long)).asLong());
    try testing.expectEqual(@as(i64, -3), (try operators.convert(runtime, Value.ofDouble(-2.5), .long)).asLong());
    try testing.expectEqual(@as(f64, -1.0), operators.truncate(Value.ofDouble(-1.9)).asDouble());

    const joined = bench.made(try operators.binary(runtime, .add, Value.ofString("a"), Value.ofString("b")));
    try testing.expectEqualStrings("ab", joined.asString());
}

test "object comparison is identity, struct comparison is by field" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const first = try runtime.newList(Value.none);
    const second = try runtime.newList(Value.none);
    try testing.expect(operators.compare(.equal, first, first));
    try testing.expect(operators.compare(.not_equal, first, second));

    var left = [_]Value{ Value.ofLong(1), Value.ofString("x") };
    var right = [_]Value{ Value.ofLong(1), Value.ofString("x") };
    try testing.expect(operators.compare(.equal, Value.ofStruct(&left), Value.ofStruct(&right)));
    right[0] = Value.ofLong(2);
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
extern fn luce_rt_constants_begin(runtime: *Runtime, count: u32) callconv(.c) i32;
extern fn luce_rt_constant_publish(
    runtime: *Runtime,
    slot: u32,
    held: *const Value,
) callconv(.c) i32;
extern fn luce_rt_constant_load(
    runtime: *const Runtime,
    slot: u32,
    out: *Value,
) callconv(.c) void;
extern fn luce_rt_constants_finish(runtime: *Runtime) callconv(.c) void;
extern fn luce_rt_constants_abort(runtime: *Runtime) callconv(.c) void;
extern fn luce_rt_discard_loose(runtime: *Runtime, held: *const Value) callconv(.c) void;
extern fn luce_rt_new_list(runtime: *Runtime, zero: *const Value, out: *Value) callconv(.c) i32;
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
    try testing.expectEqual(0, luce_rt_new_list(runtime, &Value.none, &held));
    try testing.expectEqual(0, luce_rt_append(runtime, &held, &Value.ofLong(21)));

    var read: Value = .none;
    try testing.expectEqual(0, luce_rt_index_get(runtime, &held, &[_]Value{Value.ofLong(0)}, 1, &read));
    var printed: Value = .none;
    try testing.expectEqual(0, luce_rt_str(runtime, &read, &printed));
    try testing.expectEqualStrings("21", printed.asString());

    // Out of range: the call answers trapped, and the trap waits in the
    // runtime while the frames record themselves on the way out.
    try testing.expectEqual(1, luce_rt_index_get(runtime, &held, &[_]Value{Value.ofLong(1)}, 1, &read));
    luce_rt_unwound(runtime, 0, 1);
    luce_rt_unwound(runtime, 1, 0);
    luce_rt_report(runtime, &reported, Reported.take);

    try testing.expectEqual(@intFromEnum(vocabulary.TrapCode.index_bounds), reported.code);
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

test "the C materialization surface roots, loads, freezes, and excludes a constant" {
    const runtime = luce_rt_open(null, 0).?;
    defer luce_rt_close(runtime);

    try testing.expectEqual(@as(i32, 0), luce_rt_constants_begin(runtime, 1));
    var rooted: Value = .none;
    try testing.expectEqual(@as(i32, 0), luce_rt_new_list(runtime, &Value.none, &rooted));
    try testing.expectEqual(@as(i32, 0), luce_rt_append(runtime, &rooted, &Value.ofLong(3)));
    try testing.expectEqual(@as(i32, 0), luce_rt_constant_publish(runtime, 0, &rooted));
    luce_rt_constants_finish(runtime);

    var loaded: Value = .none;
    luce_rt_constant_load(runtime, 0, &loaded);
    try testing.expect(loaded.asObject().same(rooted.asObject()));
    try testing.expectEqual(@as(i64, 0), luce_rt_leaked(runtime));
    try testing.expectEqual(@as(i32, 1), luce_rt_append(runtime, &loaded, &Value.ofLong(4)));
    try testing.expectEqual(vocabulary.TrapCode.immutable_object, runtime.pending.?.code);
}

test "materialization allocation failure traps and its C cleanup leaves no rows" {
    var objects: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    var runtime: Runtime = .init(.{
        .arena = arena.allocator(),
        .objects = objects.allocator(),
    });

    // The root table itself can be the allocation RAM refuses.  It is
    // still a located container failure, not an exhausted run.
    objects.fail_index = objects.alloc_index;
    try testing.expectEqual(@as(i32, 1), luce_rt_constants_begin(&runtime, 1));
    try testing.expectEqual(vocabulary.TrapCode.allocation_failed, runtime.pending.?.code);
    try testing.expect(!runtime.exhausted);
    try testing.expect(!runtime.materializing_constants);

    // Start again, then fail an ordinary runtime export while the
    // prologue is active.  The shared `failed` funnel must make the
    // same trap and the explicit cleanup must reclaim both table and
    // half-built object.
    objects.fail_index = std.math.maxInt(usize);
    runtime.pending = null;
    try testing.expectEqual(@as(i32, 0), luce_rt_constants_begin(&runtime, 1));
    var partial: Value = .none;
    try testing.expectEqual(@as(i32, 0), luce_rt_new_list(&runtime, &Value.none, &partial));
    objects.fail_index = objects.alloc_index;
    try testing.expectEqual(@as(i32, 1), luce_rt_append(&runtime, &partial, &Value.ofLong(1)));
    try testing.expectEqual(vocabulary.TrapCode.allocation_failed, runtime.pending.?.code);
    try testing.expect(!runtime.exhausted);
    luce_rt_discard_loose(&runtime, &partial);
    luce_rt_constants_abort(&runtime);
    try testing.expectEqual(@as(u32, 0), runtime.live);
    try testing.expectEqual(@as(i64, 0), runtime.leaked());

    runtime.deinit();
    arena.deinit();
    try testing.expectEqual(objects.allocated_bytes, objects.freed_bytes);
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
    try testing.expectEqual(1, luce_rt_index_get(runtime, &Value.ofObject(.{ .index = 9 }), &.{}, 0, &read));
    var recorded: usize = 1;
    while (recorded < trace.max_frames + 7) : (recorded += 1) luce_rt_unwound(runtime, 1, 0);
    luce_rt_report(runtime, &reported, Reported.take);
    try testing.expectEqual(@as(i64, 7), reported.dropped);
}

test "an array's cells are exactly as wide as its element, which is the prize" {
    // The 8x saving `array(byte, n)` exists for is a *layout* claim,
    // and nothing else in the suite would notice it going away: a
    // wider cell over-allocates and still reads back the right value,
    // so every behavioural test stays green while the memory quietly
    // doubles.  This asserts the widths themselves.
    const Kind = heap.Object.ElementKind;
    try testing.expectEqual(@as(usize, 1), Kind.width(.byte));
    try testing.expectEqual(@as(usize, 1), Kind.width(.boolean));
    try testing.expectEqual(@as(usize, 2), Kind.width(.short));
    try testing.expectEqual(@as(usize, 2), Kind.width(.half));
    try testing.expectEqual(@as(usize, 4), Kind.width(.int));
    try testing.expectEqual(@as(usize, 4), Kind.width(.float));
    try testing.expectEqual(@as(usize, 8), Kind.width(.long));
    try testing.expectEqual(@as(usize, 8), Kind.width(.double));
    try testing.expectEqual(@as(usize, 24), Kind.width(.value));

    // And the element zero's tag is what picks the kind, because the
    // runtime is handed a zero and never the program's type table.
    try testing.expectEqual(Kind.byte, Kind.of(Value.ofByte(0)));
    try testing.expectEqual(Kind.short, Kind.of(Value.ofShort(0)));
    try testing.expectEqual(Kind.half, Kind.of(Value.ofHalf(0.0)));

    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    // End to end: a byte array of a thousand elements occupies a
    // thousand bytes and a long array of the same length eight
    // thousand.  The ratio is the measurement, and it is 8.
    const bytes = try runtime.newArray(&.{1000}, Value.ofByte(0));
    const longs = try runtime.newArray(&.{1000}, Value.ofLong(0));
    const byte_row = try runtime.resolve(bytes);
    const long_row = try runtime.resolve(longs);
    try testing.expectEqual(@as(usize, 1000), byte_row.elements.bytes.len);
    try testing.expectEqual(@as(usize, 8000), long_row.elements.bytes.len);

    // Every value a byte can hold survives the round trip through a
    // one-byte cell, which is what says the width is honest rather
    // than merely small.  128 and 255 are the two that would come
    // back negative if anything on the way read the bits as signed.
    for (0..256) |at| byte_row.elements.put(at, Value.ofByte(@intCast(at)));
    try testing.expectEqual(@as(u8, 0), byte_row.elements.at(0).asByte());
    try testing.expectEqual(@as(u8, 128), byte_row.elements.at(128).asByte());
    try testing.expectEqual(@as(u8, 255), byte_row.elements.at(255).asByte());
}
