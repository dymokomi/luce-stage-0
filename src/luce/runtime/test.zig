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

fn expectStale(runtime: *Runtime, mistake: anytype) !void {
    try expectTrap(.use_after_free, runtime, mistake);
    runtime.pending = null;
}

fn expectContainerParent(runtime: *Runtime, child: Value, parent: Value) !void {
    const owner = (try runtime.resolve(child)).owner;
    try testing.expectEqual(heap.Owner.Kind.container, owner.kind);
    try testing.expect(owner.details.parent.same(parent.asObject()));
}

fn expectBorrowedFunctionReceiver(function: Value, receiver: Value) !void {
    try testing.expectEqual(value.Tag.function, function.tag);
    const slots = function.asStruct();
    try testing.expectEqual(@as(usize, 2), slots.len);
    try testing.expect(slots[1].tag == .object);
    try testing.expect(slots[1].asObject().same(receiver.asObject()));
}

/// A tiny deterministic generator for the ownership state machine.  The
/// seed and the transition count are part of the test contract: when a
/// sequence finds a bad edge, the same trace can be replayed without a
/// process-global random source changing the failure.
const OwnerGraphRng = struct {
    state: u64,

    fn init(seed: u64) @This() {
        return .{ .state = seed };
    }

    fn next(self: *@This()) u64 {
        self.state = self.state *% 6_364_136_223_846_793_005 +% 1_442_695_040_888_963_407;
        return self.state;
    }

    fn below(self: *@This(), upper: usize) usize {
        std.debug.assert(upper != 0);
        return @intCast(self.next() % upper);
    }
};

/// The reference side of the randomized ownership proof.  It deliberately
/// models only object identity and parent edges; list contents remain in the
/// runtime and are audited after every transition, so the model cannot agree
/// with a bug merely because it repeated the implementation's storage walk.
const OwnerGraph = struct {
    const capacity = 96;

    const Node = struct {
        handle: Value,
        parent: ?usize = null,
        live: bool = true,
    };

    nodes: [capacity]Node = undefined,
    count: usize = 0,

    fn add(self: *@This(), handle: Value) !usize {
        if (self.count == capacity) return error.TestExpected;
        const index = self.count;
        self.nodes[index] = .{ .handle = handle };
        self.count += 1;
        return index;
    }

    fn findLive(self: *const @This(), handle: Value) ?usize {
        if (handle.tag != .object) return null;
        const wanted = handle.asObject();
        for (self.nodes[0..self.count], 0..) |node, index| {
            if (node.live and node.handle.asObject().same(wanted)) return index;
        }
        return null;
    }

    fn chooseLive(self: *const @This(), random: *OwnerGraphRng) ?usize {
        var choices: usize = 0;
        for (self.nodes[0..self.count]) |node| {
            if (node.live) choices += 1;
        }
        if (choices == 0) return null;
        var wanted = random.below(choices);
        for (self.nodes[0..self.count], 0..) |node, index| {
            if (!node.live) continue;
            if (wanted == 0) return index;
            wanted -= 1;
        }
        unreachable;
    }

    fn chooseLoose(self: *const @This(), random: *OwnerGraphRng) ?usize {
        var choices: usize = 0;
        for (self.nodes[0..self.count]) |node| {
            if (node.live and node.parent == null) choices += 1;
        }
        if (choices == 0) return null;
        var wanted = random.below(choices);
        for (self.nodes[0..self.count], 0..) |node, index| {
            if (!node.live or node.parent != null) continue;
            if (wanted == 0) return index;
            wanted -= 1;
        }
        unreachable;
    }

    fn chooseContained(self: *const @This(), random: *OwnerGraphRng) ?usize {
        var choices: usize = 0;
        for (self.nodes[0..self.count]) |node| {
            if (node.live and node.parent != null) choices += 1;
        }
        if (choices == 0) return null;
        var wanted = random.below(choices);
        for (self.nodes[0..self.count], 0..) |node, index| {
            if (!node.live or node.parent == null) continue;
            if (wanted == 0) return index;
            wanted -= 1;
        }
        unreachable;
    }

    /// Whether `node` is at or below `ancestor` in the reference tree.
    fn descendsFrom(self: *const @This(), node: usize, ancestor: usize) bool {
        var current: ?usize = node;
        var remaining = self.count + 1;
        while (current) |at| {
            if (at == ancestor) return true;
            if (remaining == 0) return true;
            remaining -= 1;
            current = self.nodes[at].parent;
        }
        return false;
    }

    fn wouldCycle(self: *const @This(), parent: usize, child: usize) bool {
        return parent == child or self.descendsFrom(parent, child);
    }

    fn retireSubtree(self: *@This(), root: usize) void {
        for (self.nodes[0..self.count], 0..) |*node, index| {
            if (node.live and self.descendsFrom(index, root)) node.live = false;
        }
    }

    fn retireChildren(self: *@This(), parent: usize) void {
        for (self.nodes[0..self.count], 0..) |node, index| {
            if (node.live and node.parent == parent) self.retireSubtree(index);
        }
    }

    fn liveCount(self: *const @This()) u32 {
        var count: u32 = 0;
        for (self.nodes[0..self.count]) |node| {
            if (node.live) count += 1;
        }
        return count;
    }
};

fn ownerGraphExpect(condition: bool, seed: u64, step: usize, fact: []const u8) !void {
    if (condition) return;
    std.debug.print("owner graph seed 0x{x}, step {d}: {s}\n", .{ seed, step, fact });
    return error.TestExpected;
}

fn ownerGraphLength(runtime: *Runtime, held: Value) !usize {
    const measured = (try containers.length(runtime, held)).asLong();
    if (measured < 0) return error.TestExpected;
    return @intCast(measured);
}

fn chooseNonemptyOwnerGraph(
    runtime: *Runtime,
    graph: *const OwnerGraph,
    random: *OwnerGraphRng,
) !?usize {
    var choices: [OwnerGraph.capacity]usize = undefined;
    var count: usize = 0;
    for (graph.nodes[0..graph.count], 0..) |node, index| {
        if (!node.live) continue;
        if (try ownerGraphLength(runtime, node.handle) == 0) continue;
        choices[count] = index;
        count += 1;
    }
    if (count == 0) return null;
    return choices[random.below(count)];
}

/// Check both halves of the invariant after every state-machine operation:
/// the runtime's census and owner metadata, then every object edge as seen
/// through the public container API.  This catches a wrong owner field even
/// when the list still appears to contain the expected handle, and catches a
/// duplicate edge even when the table's live count happens to match.
fn auditOwnerGraph(
    runtime: *Runtime,
    graph: *const OwnerGraph,
    seed: u64,
    step: usize,
) !void {
    runtime.debugAssertInvariants();
    try ownerGraphExpect(runtime.live == graph.liveCount(), seed, step, "live census");

    for (graph.nodes[0..graph.count], 0..) |node, index| {
        if (!node.live) continue;
        const object = try runtime.resolve(node.handle);
        if (node.parent) |parent| {
            try ownerGraphExpect(graph.nodes[parent].live, seed, step, "live parent");
            try ownerGraphExpect(object.owner.kind == .container, seed, step, "container owner kind");
            try ownerGraphExpect(
                object.owner.details.parent.same(graph.nodes[parent].handle.asObject()),
                seed,
                step,
                "exact container parent",
            );
        } else {
            try ownerGraphExpect(object.owner.kind == .loose, seed, step, "loose root owner kind");
        }

        const length = try ownerGraphLength(runtime, node.handle);
        for (0..length) |at| {
            const item = try containers.indexGet(runtime, node.handle, &.{Value.ofLong(@intCast(at))});
            if (item.tag != .object) continue;
            const child = graph.findLive(item) orelse {
                std.debug.print("owner graph seed 0x{x}, step {d}: unknown child in node {d}\n", .{ seed, step, index });
                return error.TestExpected;
            };
            try ownerGraphExpect(
                graph.nodes[child].parent == index,
                seed,
                step,
                "edge agrees with child parent",
            );
        }
    }

    // Every model edge must occur exactly once in its parent's list.  The
    // first loop checks that every runtime edge points into the model; this
    // reverse check catches a missing edge and a duplicate edge as well.
    for (graph.nodes[0..graph.count]) |node| {
        if (!node.live) continue;
        const child = graph.findLive(node.handle) orelse unreachable;
        const parent = node.parent orelse continue;
        var occurrences: usize = 0;
        const length = try ownerGraphLength(runtime, graph.nodes[parent].handle);
        for (0..length) |at| {
            const item = try containers.indexGet(
                runtime,
                graph.nodes[parent].handle,
                &.{Value.ofLong(@intCast(at))},
            );
            if (item.tag == .object and item.asObject().same(node.handle.asObject())) {
                occurrences += 1;
            }
        }
        _ = child;
        try ownerGraphExpect(occurrences == 1, seed, step, "one edge per owned child");
    }
}

fn runOwnerGraphSeed(runtime: *Runtime, seed: u64) !void {
    var graph: OwnerGraph = .{};
    var random = OwnerGraphRng.init(seed);

    // Start with several independent roots so the first transitions can
    // build both shallow and deep forests without depending on allocation
    // order or one particular row index.
    for (0..8) |_| {
        _ = try graph.add(try runtime.newList(Value.none));
    }

    const transitions = 700;
    var step: usize = 0;
    while (step < transitions) : (step += 1) {
        runtime.pending = null;
        switch (random.below(100)) {
            // New loose roots exercise row reuse after the release cases
            // below, and eventually hit the fixed model capacity harmlessly.
            0...13 => if (graph.count < OwnerGraph.capacity) {
                _ = try graph.add(try runtime.newList(Value.none));
            },

            // Append and insert are the two growing ownership doors.
            14...27 => {
                const parent = graph.chooseLive(&random) orelse continue;
                const child = graph.chooseLoose(&random) orelse continue;
                if (graph.wouldCycle(parent, child)) {
                    try expectTrap(
                        .ownership_cycle,
                        runtime,
                        containers.append(runtime, graph.nodes[parent].handle, graph.nodes[child].handle),
                    );
                    runtime.pending = null;
                } else {
                    try containers.append(runtime, graph.nodes[parent].handle, graph.nodes[child].handle);
                    graph.nodes[child].parent = parent;
                }
            },
            28...39 => {
                const parent = graph.chooseLive(&random) orelse continue;
                const child = graph.chooseLoose(&random) orelse continue;
                const length = try ownerGraphLength(runtime, graph.nodes[parent].handle);
                const at = random.below(length + 1);
                if (graph.wouldCycle(parent, child)) {
                    try expectTrap(
                        .ownership_cycle,
                        runtime,
                        containers.insert(runtime, graph.nodes[parent].handle, @intCast(at), graph.nodes[child].handle),
                    );
                    runtime.pending = null;
                } else {
                    try containers.insert(
                        runtime,
                        graph.nodes[parent].handle,
                        @intCast(at),
                        graph.nodes[child].handle,
                    );
                    graph.nodes[child].parent = parent;
                }
            },

            // Pop detaches one direct child and leaves its own subtree
            // intact, which is the transition most likely to expose a
            // forgotten loosen step.
            40...49 => {
                const parent = try chooseNonemptyOwnerGraph(runtime, &graph, &random) orelse continue;
                const length = try ownerGraphLength(runtime, graph.nodes[parent].handle);
                const item = try containers.indexGet(
                    runtime,
                    graph.nodes[parent].handle,
                    &.{Value.ofLong(@intCast(length - 1))},
                );
                const taken = try containers.pop(runtime, graph.nodes[parent].handle);
                try ownerGraphExpect(
                    std.meta.eql(item, taken),
                    seed,
                    step,
                    "pop returns the stored value",
                );
                if (taken.tag == .object) {
                    const child = graph.findLive(taken) orelse return error.TestExpected;
                    try ownerGraphExpect(graph.nodes[child].parent == parent, seed, step, "pop child parent");
                    graph.nodes[child].parent = null;
                }
            },
            50...58 => {
                const parent = try chooseNonemptyOwnerGraph(runtime, &graph, &random) orelse continue;
                const length = try ownerGraphLength(runtime, graph.nodes[parent].handle);
                const at = random.below(length);
                const item = try containers.indexGet(
                    runtime,
                    graph.nodes[parent].handle,
                    &.{Value.ofLong(@intCast(at))},
                );
                try containers.remove(runtime, graph.nodes[parent].handle, Value.ofLong(@intCast(at)));
                if (item.tag == .object) {
                    const child = graph.findLive(item) orelse return error.TestExpected;
                    try ownerGraphExpect(graph.nodes[child].parent == parent, seed, step, "removed child parent");
                    graph.retireSubtree(child);
                }
            },

            // Replace an element with either a scalar, absence, or a loose
            // subtree.  The old object dies at the overwrite point.
            59...70 => {
                const parent = try chooseNonemptyOwnerGraph(runtime, &graph, &random) orelse continue;
                const length = try ownerGraphLength(runtime, graph.nodes[parent].handle);
                const at = random.below(length);
                const old = try containers.indexGet(
                    runtime,
                    graph.nodes[parent].handle,
                    &.{Value.ofLong(@intCast(at))},
                );
                var incoming = Value.none;
                var incoming_node: ?usize = null;
                if (random.below(3) == 0) {
                    incoming = Value.ofLong(@intCast(random.next() & 0x7f));
                } else if (random.below(3) == 0) {
                    if (graph.chooseLoose(&random)) |candidate| {
                        incoming = graph.nodes[candidate].handle;
                        incoming_node = candidate;
                    }
                }
                if (incoming_node) |child| {
                    if (graph.wouldCycle(parent, child)) {
                        try expectTrap(
                            .ownership_cycle,
                            runtime,
                            containers.indexSet(
                                runtime,
                                graph.nodes[parent].handle,
                                &.{Value.ofLong(@intCast(at))},
                                incoming,
                            ),
                        );
                        runtime.pending = null;
                        continue;
                    }
                }
                try containers.indexSet(
                    runtime,
                    graph.nodes[parent].handle,
                    &.{Value.ofLong(@intCast(at))},
                    incoming,
                );
                if (old.tag == .object) {
                    const replaced = graph.findLive(old) orelse return error.TestExpected;
                    graph.retireSubtree(replaced);
                }
                if (incoming_node) |child| graph.nodes[child].parent = parent;
            },

            // Clear is a bulk subtree release and is deliberately separate
            // from remove so the model checks both iteration shapes.
            71...76 => {
                const parent = graph.chooseLive(&random) orelse continue;
                graph.retireChildren(parent);
                try containers.clear(runtime, graph.nodes[parent].handle);
            },

            // A contained child is a hostile second-owner attempt.  Probe
            // all three retaining list doors; none may mutate the target or
            // move the child's owner field.
            77...82 => if (graph.chooseContained(&random)) |child| {
                const parent = graph.chooseLive(&random) orelse continue;
                switch (random.below(3)) {
                    0 => try expectTrap(
                        .not_owned,
                        runtime,
                        containers.append(runtime, graph.nodes[parent].handle, graph.nodes[child].handle),
                    ),
                    1 => try expectTrap(
                        .not_owned,
                        runtime,
                        containers.insert(runtime, graph.nodes[parent].handle, 0, graph.nodes[child].handle),
                    ),
                    2 => {
                        const target = try chooseNonemptyOwnerGraph(runtime, &graph, &random) orelse continue;
                        const length = try ownerGraphLength(runtime, graph.nodes[target].handle);
                        try expectTrap(
                            .not_owned,
                            runtime,
                            containers.indexSet(
                                runtime,
                                graph.nodes[target].handle,
                                &.{Value.ofLong(@intCast(random.below(length)))},
                                graph.nodes[child].handle,
                            ),
                        );
                    },
                    else => unreachable,
                }
                runtime.pending = null;
            },

            // Free a loose root, then immediately exercise double release
            // and later generation reuse through the stale-handle lane.
            83...88 => if (graph.chooseLoose(&random)) |root| {
                const held = graph.nodes[root].handle;
                runtime.freeValue(held);
                runtime.freeObject(held.asObject());
                runtime.freeValue(held);
                graph.retireSubtree(root);
            },

            // Bind/return/unbind a loose subtree.  Both paths must preserve
            // all descendants and only the matching binding may destroy it.
            89...94 => if (graph.chooseLoose(&random)) |root| {
                const held = graph.nodes[root].handle;
                const serial = runtime.takeSerial();
                const local: u32 = @intCast(random.below(16));
                runtime.bind(held, serial, local);
                const owner = (try runtime.resolve(held)).owner;
                try ownerGraphExpect(owner.kind == .binding, seed, step, "binding transition");
                runtime.unbind(held, serial + 1, local);
                try ownerGraphExpect(runtime.live == graph.liveCount(), seed, step, "wrong binding leaves graph");
                if (random.below(2) == 0) {
                    runtime.loosenFromFrame(held, serial);
                } else {
                    runtime.unbind(held, serial, local);
                    graph.retireSubtree(root);
                }
            },

            // Stale handles must remain stale through resolution, copying,
            // ownership checks, and a mutating receiver path.
            else => if (graph.count != 0) {
                var dead: [OwnerGraph.capacity]usize = undefined;
                var count: usize = 0;
                for (graph.nodes[0..graph.count], 0..) |node, index| {
                    if (!node.live) {
                        dead[count] = index;
                        count += 1;
                    }
                }
                if (count != 0) {
                    const stale = graph.nodes[dead[random.below(count)]].handle;
                    try expectTrap(.use_after_free, runtime, runtime.resolve(stale));
                    runtime.pending = null;
                    try expectTrap(.use_after_free, runtime, runtime.deepCopy(stale));
                    runtime.pending = null;
                    try expectTrap(.use_after_free, runtime, runtime.checkGivable(stale, null));
                    runtime.pending = null;
                }
            },
        }
        try auditOwnerGraph(runtime, &graph, seed, step);
    }

    // Teardown is part of the state-machine contract, not merely a defer in
    // the test harness: every graph root must be explicitly released before
    // the runtime itself closes.
    for (graph.nodes[0..graph.count], 0..) |node, index| {
        if (node.live and node.parent == null) {
            runtime.freeValue(node.handle);
            graph.retireSubtree(index);
        }
    }
    try auditOwnerGraph(runtime, &graph, seed, transitions);
    try ownerGraphExpect(runtime.live == 0, seed, transitions, "zero live objects after graph teardown");
}

const MixedKind = enum { list, map, array };

const MixedNode = struct {
    handle: Value,
    kind: MixedKind,
    parent: ?usize = null,
    live: bool = true,
};

const MixedOwnerGraph = struct {
    const capacity = 64;

    nodes: [capacity]MixedNode = undefined,
    count: usize = 0,

    fn add(self: *@This(), handle: Value, kind: MixedKind) !usize {
        if (self.count == capacity) return error.TestExpected;
        const index = self.count;
        self.nodes[index] = .{ .handle = handle, .kind = kind };
        self.count += 1;
        return index;
    }

    fn findLive(self: *const @This(), handle: Value) ?usize {
        if (handle.tag != .object) return null;
        for (self.nodes[0..self.count], 0..) |node, index| {
            if (node.live and node.handle.asObject().same(handle.asObject())) return index;
        }
        return null;
    }

    fn chooseLive(self: *const @This(), random: *OwnerGraphRng) ?usize {
        var choices: usize = 0;
        for (self.nodes[0..self.count]) |node| {
            if (node.live) choices += 1;
        }
        if (choices == 0) return null;
        var wanted = random.below(choices);
        for (self.nodes[0..self.count], 0..) |node, index| {
            if (!node.live) continue;
            if (wanted == 0) return index;
            wanted -= 1;
        }
        unreachable;
    }

    fn chooseLoose(self: *const @This(), random: *OwnerGraphRng) ?usize {
        var choices: usize = 0;
        for (self.nodes[0..self.count]) |node| {
            if (node.live and node.parent == null) choices += 1;
        }
        if (choices == 0) return null;
        var wanted = random.below(choices);
        for (self.nodes[0..self.count], 0..) |node, index| {
            if (!node.live or node.parent != null) continue;
            if (wanted == 0) return index;
            wanted -= 1;
        }
        unreachable;
    }

    fn chooseContained(self: *const @This(), random: *OwnerGraphRng) ?usize {
        var choices: usize = 0;
        for (self.nodes[0..self.count]) |node| {
            if (node.live and node.parent != null) choices += 1;
        }
        if (choices == 0) return null;
        var wanted = random.below(choices);
        for (self.nodes[0..self.count], 0..) |node, index| {
            if (!node.live or node.parent == null) continue;
            if (wanted == 0) return index;
            wanted -= 1;
        }
        unreachable;
    }

    fn descendsFrom(self: *const @This(), node: usize, ancestor: usize) bool {
        var current: ?usize = node;
        var remaining = self.count + 1;
        while (current) |at| {
            if (at == ancestor) return true;
            if (remaining == 0) return true;
            remaining -= 1;
            current = self.nodes[at].parent;
        }
        return false;
    }

    fn wouldCycle(self: *const @This(), parent: usize, child: usize) bool {
        return parent == child or self.descendsFrom(parent, child);
    }

    fn retireSubtree(self: *@This(), root: usize) void {
        for (self.nodes[0..self.count], 0..) |*node, index| {
            if (node.live and self.descendsFrom(index, root)) node.live = false;
        }
    }

    fn retireChildren(self: *@This(), parent: usize) void {
        for (self.nodes[0..self.count], 0..) |node, index| {
            if (node.live and node.parent == parent) self.retireSubtree(index);
        }
    }

    fn liveCount(self: *const @This()) u32 {
        var count: u32 = 0;
        for (self.nodes[0..self.count]) |node| {
            if (node.live) count += 1;
        }
        return count;
    }
};

fn mixedLength(runtime: *Runtime, graph: *const MixedOwnerGraph, index: usize) !usize {
    return ownerGraphLength(runtime, graph.nodes[index].handle);
}

fn mixedItem(runtime: *Runtime, graph: *const MixedOwnerGraph, index: usize, at: usize) !Value {
    const node = graph.nodes[index];
    return switch (node.kind) {
        .map => containers.valueAt(runtime, node.handle, @intCast(at)),
        .list, .array => containers.indexGet(runtime, node.handle, &.{Value.ofLong(@intCast(at))}),
    };
}

fn mixedAudit(runtime: *Runtime, graph: *const MixedOwnerGraph, seed: u64, step: usize) !void {
    runtime.debugAssertInvariants();
    try ownerGraphExpect(runtime.live == graph.liveCount(), seed, step, "mixed live census");

    for (graph.nodes[0..graph.count], 0..) |node, index| {
        if (!node.live) continue;
        const object = try runtime.resolve(node.handle);
        if (node.parent) |parent| {
            try ownerGraphExpect(graph.nodes[parent].live, seed, step, "mixed live parent");
            try ownerGraphExpect(object.owner.kind == .container, seed, step, "mixed container owner kind");
            try ownerGraphExpect(
                object.owner.details.parent.same(graph.nodes[parent].handle.asObject()),
                seed,
                step,
                "mixed exact container parent",
            );
        } else {
            try ownerGraphExpect(object.owner.kind == .loose, seed, step, "mixed loose root owner kind");
        }

        const length = try mixedLength(runtime, graph, index);
        for (0..length) |at| {
            const item = try mixedItem(runtime, graph, index, at);
            if (item.tag != .object) continue;
            const child = graph.findLive(item) orelse return error.TestExpected;
            try ownerGraphExpect(graph.nodes[child].parent == index, seed, step, "mixed edge parent");
        }
    }

    for (graph.nodes[0..graph.count], 0..) |node, child| {
        if (!node.live) continue;
        const parent = node.parent orelse continue;
        var occurrences: usize = 0;
        const length = try mixedLength(runtime, graph, parent);
        for (0..length) |at| {
            const item = try mixedItem(runtime, graph, parent, at);
            if (item.tag == .object and item.asObject().same(node.handle.asObject())) occurrences += 1;
        }
        try ownerGraphExpect(occurrences == 1, seed, step, "mixed one edge per child");
        _ = child;
    }
}

fn mixedNew(runtime: *Runtime, kind: MixedKind) !Value {
    return switch (kind) {
        .list => runtime.newList(Value.none),
        .map => runtime.newMap(),
        .array => runtime.newArray(&.{4}, Value.none),
    };
}

fn mixedEmptyArraySlot(runtime: *Runtime, graph: *const MixedOwnerGraph, index: usize) !?usize {
    const length = try mixedLength(runtime, graph, index);
    for (0..length) |at| {
        if ((try mixedItem(runtime, graph, index, at)).tag != .object) return at;
    }
    return null;
}

fn runMixedOwnerGraphSeed(runtime: *Runtime, seed: u64) !void {
    var graph: MixedOwnerGraph = .{};
    var random = OwnerGraphRng.init(seed);
    for ([_]MixedKind{ .list, .map, .array, .list, .map }) |kind| {
        _ = try graph.add(try mixedNew(runtime, kind), kind);
    }

    const transitions = 1_200;
    var step: usize = 0;
    while (step < transitions) : (step += 1) {
        runtime.pending = null;
        switch (random.below(100)) {
            0...11 => if (graph.count < MixedOwnerGraph.capacity) {
                const kind: MixedKind = @enumFromInt(random.below(3));
                _ = try graph.add(try mixedNew(runtime, kind), kind);
            },

            // Every container kind gets a retaining door: append/insert for
            // lists, map_place for maps, and an indexed store for arrays.
            12...36 => {
                const parent = graph.chooseLive(&random) orelse continue;
                const child = graph.chooseLoose(&random) orelse continue;
                if (parent == child) continue;
                if (graph.wouldCycle(parent, child)) {
                    switch (graph.nodes[parent].kind) {
                        .list => try expectTrap(
                            .ownership_cycle,
                            runtime,
                            containers.append(runtime, graph.nodes[parent].handle, graph.nodes[child].handle),
                        ),
                        .map => _ = try expectTrap(
                            .ownership_cycle,
                            runtime,
                            containers.mapPlace(
                                runtime,
                                graph.nodes[parent].handle,
                                Value.ofLong(@intCast(10_000 + step * 100 + child)),
                                graph.nodes[child].handle,
                            ),
                        ),
                        .array => {
                            const at = try mixedEmptyArraySlot(runtime, &graph, parent) orelse continue;
                            try expectTrap(
                                .ownership_cycle,
                                runtime,
                                containers.indexSet(
                                    runtime,
                                    graph.nodes[parent].handle,
                                    &.{Value.ofLong(@intCast(at))},
                                    graph.nodes[child].handle,
                                ),
                            );
                        },
                    }
                    runtime.pending = null;
                    continue;
                }
                switch (graph.nodes[parent].kind) {
                    .list => {
                        if (random.below(2) == 0) {
                            try containers.append(runtime, graph.nodes[parent].handle, graph.nodes[child].handle);
                        } else {
                            const length = try mixedLength(runtime, &graph, parent);
                            try containers.insert(
                                runtime,
                                graph.nodes[parent].handle,
                                @intCast(random.below(length + 1)),
                                graph.nodes[child].handle,
                            );
                        }
                    },
                    .map => {
                        _ = try containers.mapPlace(
                            runtime,
                            graph.nodes[parent].handle,
                            Value.ofLong(@intCast(10_000 + step * 100 + child)),
                            graph.nodes[child].handle,
                        );
                    },
                    .array => {
                        const at = try mixedEmptyArraySlot(runtime, &graph, parent) orelse continue;
                        try containers.indexSet(
                            runtime,
                            graph.nodes[parent].handle,
                            &.{Value.ofLong(@intCast(at))},
                            graph.nodes[child].handle,
                        );
                    },
                }
                graph.nodes[child].parent = parent;
            },

            // Replace a direct value with a scalar or a loose child.  The
            // old subtree must die exactly at the overwrite, while a new
            // child must acquire precisely this parent.
            37...59 => {
                const parent = graph.chooseLive(&random) orelse continue;
                const length = try mixedLength(runtime, &graph, parent);
                if (length == 0) continue;
                const at = random.below(length);
                const old = try mixedItem(runtime, &graph, parent, at);
                var incoming = if (random.below(2) == 0) Value.none else Value.ofLong(@intCast(random.next() & 0x7f));
                var incoming_node: ?usize = null;
                if (random.below(3) == 0) if (graph.chooseLoose(&random)) |candidate| {
                    incoming = graph.nodes[candidate].handle;
                    incoming_node = candidate;
                };
                if (incoming_node) |child| if (graph.wouldCycle(parent, child)) {
                    try expectTrap(
                        .ownership_cycle,
                        runtime,
                        switch (graph.nodes[parent].kind) {
                            .map => containers.indexSet(
                                runtime,
                                graph.nodes[parent].handle,
                                &.{Value.ofLong(@intCast(at))},
                                incoming,
                            ),
                            .list, .array => containers.indexSet(
                                runtime,
                                graph.nodes[parent].handle,
                                &.{Value.ofLong(@intCast(at))},
                                incoming,
                            ),
                        },
                    );
                    runtime.pending = null;
                    continue;
                };

                switch (graph.nodes[parent].kind) {
                    .map => try containers.indexSet(
                        runtime,
                        graph.nodes[parent].handle,
                        &.{try containers.keyAt(runtime, graph.nodes[parent].handle, @intCast(at))},
                        incoming,
                    ),
                    .list, .array => try containers.indexSet(
                        runtime,
                        graph.nodes[parent].handle,
                        &.{Value.ofLong(@intCast(at))},
                        incoming,
                    ),
                }
                if (old.tag == .object) graph.retireSubtree(graph.findLive(old) orelse return error.TestExpected);
                if (incoming_node) |child| graph.nodes[child].parent = parent;
            },

            // Detach a list value, remove a map value, or bulk-fill an array
            // with a scalar.  These are intentionally different lifetime
            // transitions for the same owner graph.
            60...74 => {
                const parent = graph.chooseLive(&random) orelse continue;
                const length = try mixedLength(runtime, &graph, parent);
                if (length == 0) continue;
                switch (graph.nodes[parent].kind) {
                    .list => {
                        const at = length - 1;
                        const taken = try containers.pop(runtime, graph.nodes[parent].handle);
                        if (taken.tag == .object) {
                            const child = graph.findLive(taken) orelse return error.TestExpected;
                            graph.nodes[child].parent = null;
                        }
                        _ = at;
                    },
                    .map => {
                        const key = try containers.keyAt(runtime, graph.nodes[parent].handle, @intCast(random.below(length)));
                        const old = try containers.mapGet(runtime, graph.nodes[parent].handle, key);
                        try containers.remove(runtime, graph.nodes[parent].handle, key);
                        if (old.tag == .object) graph.retireSubtree(graph.findLive(old) orelse return error.TestExpected);
                    },
                    .array => {
                        for (0..length) |at| {
                            const old = try mixedItem(runtime, &graph, parent, at);
                            if (old.tag == .object) graph.retireSubtree(graph.findLive(old) orelse return error.TestExpected);
                        }
                        try containers.arrayFill(runtime, graph.nodes[parent].handle, Value.none);
                    },
                }
            },

            75...82 => {
                const parent = graph.chooseLive(&random) orelse continue;
                if (graph.nodes[parent].kind == .array) continue;
                graph.retireChildren(parent);
                try containers.clear(runtime, graph.nodes[parent].handle);
            },

            // A contained alias must be rejected before a new edge is
            // published; using a root as its own child must reach the cycle
            // wall after the ownership proof.
            83...89 => {
                const parent = graph.chooseLive(&random) orelse continue;
                const child = if (random.below(2) == 0)
                    graph.chooseContained(&random) orelse parent
                else
                    parent;
                const expected: vocabulary.TrapCode = if (graph.nodes[child].parent != null)
                    .not_owned
                else
                    .ownership_cycle;
                switch (graph.nodes[parent].kind) {
                    .list => try expectTrap(
                        expected,
                        runtime,
                        containers.append(runtime, graph.nodes[parent].handle, graph.nodes[child].handle),
                    ),
                    .map => _ = try expectTrap(
                        expected,
                        runtime,
                        containers.mapPlace(
                            runtime,
                            graph.nodes[parent].handle,
                            Value.ofLong(@intCast(80_000 + step)),
                            graph.nodes[child].handle,
                        ),
                    ),
                    .array => {
                        const at = try mixedEmptyArraySlot(runtime, &graph, parent) orelse continue;
                        try expectTrap(
                            expected,
                            runtime,
                            containers.indexSet(
                                runtime,
                                graph.nodes[parent].handle,
                                &.{Value.ofLong(@intCast(at))},
                                graph.nodes[child].handle,
                            ),
                        );
                    },
                }
                runtime.pending = null;
            },

            90...94 => if (graph.chooseLive(&random)) |root| {
                const duplicate = try runtime.deepCopy(graph.nodes[root].handle);
                runtime.freeValue(duplicate);
            },

            else => if (graph.count != 0) {
                var dead: [MixedOwnerGraph.capacity]usize = undefined;
                var count: usize = 0;
                for (graph.nodes[0..graph.count], 0..) |node, index| {
                    if (!node.live) {
                        dead[count] = index;
                        count += 1;
                    }
                }
                if (count != 0) {
                    const stale = graph.nodes[dead[random.below(count)]].handle;
                    try expectTrap(.use_after_free, runtime, runtime.resolve(stale));
                    runtime.pending = null;
                    try expectTrap(.use_after_free, runtime, runtime.deepCopy(stale));
                    runtime.pending = null;
                }
            },
        }
        try mixedAudit(runtime, &graph, seed, step);
    }

    for (graph.nodes[0..graph.count], 0..) |node, index| {
        if (node.live and node.parent == null) {
            runtime.freeValue(node.handle);
            graph.retireSubtree(index);
        }
    }
    try mixedAudit(runtime, &graph, seed, transitions);
    try ownerGraphExpect(runtime.live == 0, seed, transitions, "mixed zero live objects after teardown");
}

test "fixed mixed owner-graph seeds keep lists maps and arrays coherent" {
    for ([_]u64{
        0xA11CE_0001,
        0xA11CE_0021,
        0xA11CE_00A5,
        0xA11CE_F00D,
    }) |seed| {
        var bench: Bench = undefined;
        bench.setup();
        defer bench.deinit();
        try runMixedOwnerGraphSeed(&bench.runtime, seed);
    }
}

test "fuzz: mixed owner graphs preserve one owner across container kinds" {
    try testing.fuzz({}, fuzzMixedOwnerGraph, .{ .corpus = &.{
        "mixed list map array owner graph",
        "map replacement and array fill",
        "nested mixed owner row reuse",
    } });
}

fn fuzzMixedOwnerGraph(_: void, smith: *testing.Smith) !void {
    var bytes: [24]u8 = undefined;
    const length = smith.sliceWeightedBytes(&bytes, &.{
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .value(u8, 0x00, 3),
        .value(u8, 0xff, 3),
        .value(u8, '\n', 2),
    });
    var seed: u64 = 0xC0DE_5EED_0011_0001;
    for (bytes[0..length], 0..) |byte, at| {
        seed = seed *% 6_364_136_223_846_793_005 +%
            (@as(u64, byte) +% @as(u64, at) +% 1);
        seed ^= seed >> 31;
    }
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    try runMixedOwnerGraphSeed(&bench.runtime, seed);
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
        target.debugAssertInvariants();
        try testing.expectEqual(@as(u32, 0), target.live);
        return mistake;
    };
    target.freeValue(duplicate);
    target.debugAssertInvariants();
    try testing.expectEqual(@as(u32, 0), target.live);
}

/// Copy one function run through a failing object allocator.  The receiver
/// is deliberately a carrying struct with outside text: a function value
/// owns its run, but only borrows the receiver's object graph.  A failed
/// copy must therefore return the new run and any nested value storage
/// without touching the source graph.
fn copyFunctionWithAllocator(allocator: std.mem.Allocator, held: Value) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    var target: Runtime = .init(.{ .arena = arena.allocator(), .objects = allocator });
    defer {
        target.deinit();
        arena.deinit();
    }
    const duplicate = target.ownValue(held) catch |mistake| {
        target.debugAssertInvariants();
        return mistake;
    };
    target.dropStorage(duplicate);
    target.debugAssertInvariants();
}

fn newArrayWithOwnedFill(allocator: std.mem.Allocator) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    var runtime: Runtime = .init(.{ .arena = arena.allocator(), .objects = allocator });
    defer {
        runtime.deinit();
        arena.deinit();
    }

    const array = runtime.newArray(
        &.{4},
        Value.ofString("a long array fill value that owns outside storage"),
    ) catch |mistake| {
        // The public constructor locates raw element-buffer failure as a
        // runtime allocation trap.  Normalize that boundary back to the
        // allocator error expected by checkAllAllocationFailures.
        if (mistake == error.Trap and
            runtime.pending != null and
            runtime.pending.?.code == .allocation_failed)
        {
            runtime.debugAssertInvariants();
            return error.OutOfMemory;
        }
        runtime.debugAssertInvariants();
        return mistake;
    };
    runtime.freeValue(array);
    runtime.debugAssertInvariants();
}

const CopyShape = enum { list, map, array, strukt };

const RetainingDoor = enum { append, insert, map_index_set };

const CAllocationDoor = enum {
    new_list,
    new_map,
    new_builder,
    new_array,
    struct_make,
    function_make,
    intern_text,
    own_storage,
    names_list,
    args_list,
};

const CValueAllocationDoor = enum {
    export_storage,
    copy,
    list_slice,
    map_keys,
    map_values,
    str,
    set_key_text,
};

const CFileAllocationDoor = enum { open, read_text, write_text };

const CTaskAllocationDoor = enum { wait_result };

const CCompoundAllocationDoor = enum {
    maybe_text,
    struct_set,
    map_place,
    array_fill,
    concat,
    parse_string,
};

const CFileState = struct {
    const handle: i64 = 7_401;

    payload: []const u8,
    opens: usize = 0,
    closes: usize = 0,
    reads: usize = 0,
    writes: usize = 0,
    flushes: usize = 0,
    closed: bool = false,
    duplicate_close: bool = false,
    unknown_close: bool = false,
    read_at: usize = 0,
    written: usize = 0,

    fn init(payload: []const u8) @This() {
        return .{ .payload = payload };
    }

    fn open(
        context: ?*anyopaque,
        _: [*]const u8,
        _: i64,
        _: i64,
        out: *i64,
    ) callconv(.c) i32 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.opens += 1;
        self.closed = false;
        self.read_at = 0;
        self.written = 0;
        out.* = handle;
        return files.yes;
    }

    fn read(
        context: ?*anyopaque,
        held: i64,
        into: [*]u8,
        capacity: i64,
        filled: *i64,
    ) callconv(.c) i32 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (held != handle or self.closed) return files.no;
        const room = std.math.cast(usize, capacity) orelse return files.no;
        const amount = @min(room, self.payload.len - self.read_at);
        @memcpy(into[0..amount], self.payload[self.read_at..][0..amount]);
        self.read_at += amount;
        self.reads += 1;
        filled.* = @intCast(amount);
        return files.yes;
    }

    fn write(
        context: ?*anyopaque,
        held: i64,
        _: [*]const u8,
        length: i64,
        written: *i64,
    ) callconv(.c) i32 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (held != handle or self.closed) return files.no;
        const amount = std.math.cast(usize, length) orelse return files.no;
        self.written += amount;
        self.writes += 1;
        written.* = length;
        return files.yes;
    }

    fn flush(context: ?*anyopaque, held: i64) callconv(.c) i32 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (held != handle or self.closed) return files.no;
        self.flushes += 1;
        return files.yes;
    }

    fn close(context: ?*anyopaque, held: i64) callconv(.c) i32 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (held != handle) {
            self.unknown_close = true;
            return files.yes;
        }
        if (self.closed) self.duplicate_close = true;
        self.closed = true;
        self.closes += 1;
        return files.yes;
    }

    fn install(self: *@This(), runtime: *Runtime) void {
        runtime.files = .{
            .context = self,
            .open = open,
            .read = read,
            .write = write,
            .flush = flush,
            .close = close,
        };
    }
};

fn expectRetainingDoorFailure(door: RetainingDoor) !void {
    var objects: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    var runtime: Runtime = .init(.{
        .arena = arena.allocator(),
        .objects = objects.allocator(),
    });
    var cleaned = false;
    defer if (!cleaned) {
        runtime.deinit();
        arena.deinit();
    };

    const target = switch (door) {
        .append, .insert => blk: {
            const list = try runtime.newList(Value.none);
            // The first eight values establish the initial capacity.  The
            // failing operation is therefore forced to allocate its next
            // element run rather than merely exercising a no-grow write.
            for (0..8) |number| {
                try containers.append(&runtime, list, Value.ofLong(@intCast(number)));
            }
            break :blk list;
        },
        .map_index_set => try runtime.newMap(),
    };
    const held = try runtime.newList(Value.none);
    const baseline_live = runtime.live;
    try testing.expectEqual(@as(u32, 2), baseline_live);

    // `held` has passed through construction as a loose object.  Once the
    // retaining door has accepted its ownership proof, a later allocation
    // failure must consume it as well as a string or struct run.  Otherwise
    // the object becomes a live row with no owner and the next generation
    // audit reports a leak that ordinary scope cleanup cannot explain.
    objects.fail_index = objects.alloc_index;
    const outcome = switch (door) {
        .append => containers.append(&runtime, target, held),
        .insert => containers.insert(&runtime, target, 4, held),
        .map_index_set => containers.indexSet(
            &runtime,
            target,
            &.{Value.ofString("new key")},
            held,
        ),
    };
    try testing.expectError(error.OutOfMemory, outcome);
    try testing.expect(objects.has_induced_failure);
    try testing.expectEqual(baseline_live - 1, runtime.live);
    try expectTrap(.use_after_free, &runtime, runtime.resolve(held));
    runtime.pending = null;

    switch (door) {
        .append, .insert => try testing.expectEqual(
            @as(i64, 8),
            (try containers.length(&runtime, target)).asLong(),
        ),
        .map_index_set => try testing.expectEqual(
            @as(i64, 0),
            (try containers.length(&runtime, target)).asLong(),
        ),
    }

    runtime.freeValue(target);
    try testing.expectEqual(@as(u32, 0), runtime.live);
    runtime.deinit();
    arena.deinit();
    cleaned = true;
    try testing.expectEqual(objects.allocated_bytes, objects.freed_bytes);
}

fn expectNestedListIntact(runtime: *Runtime, held: Value) !void {
    try testing.expectEqual(@as(i64, 1), (try containers.length(runtime, held)).asLong());
    const word = try containers.indexGet(runtime, held, &.{Value.ofLong(0)});
    try testing.expectEqualStrings(
        "a nested object owns bytes that its failed copy must return",
        word.asString(),
    );
}

fn expectNestedSourceIntact(runtime: *Runtime, held: Value, shape: CopyShape) !void {
    switch (shape) {
        .list => {
            try testing.expectEqual(@as(i64, 2), (try containers.length(runtime, held)).asLong());
            for (0..2) |index| {
                try expectNestedListIntact(
                    runtime,
                    try containers.indexGet(runtime, held, &.{Value.ofLong(@intCast(index))}),
                );
            }
        },
        .map => {
            try testing.expectEqual(@as(i64, 2), (try containers.length(runtime, held)).asLong());
            for (0..2) |index| {
                try expectNestedListIntact(
                    runtime,
                    try containers.valueAt(runtime, held, @intCast(index)),
                );
            }
        },
        .array => {
            try testing.expectEqual(@as(i64, 2), (try containers.length(runtime, held)).asLong());
            for (0..2) |index| {
                try expectNestedListIntact(
                    runtime,
                    try containers.indexGet(runtime, held, &.{Value.ofLong(@intCast(index))}),
                );
            }
        },
        .strukt => {
            const fields = held.asStruct();
            try testing.expectEqual(@as(usize, 3), fields.len);
            try expectNestedListIntact(runtime, fields[0]);
            try expectNestedListIntact(runtime, fields[1]);
            try testing.expectEqualStrings(
                "the copied struct itself owns outside bytes",
                fields[2].asString(),
            );
        },
    }
}

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

fn nestedUnionOptionalSource(runtime: *Runtime, optional_present: bool) !Value {
    const union_payload = try nestedList(runtime);
    var union_payload_loose = true;
    errdefer if (union_payload_loose) runtime.freeValue(union_payload);

    // The runtime representation of a union is a value run containing its
    // discriminant and payload.  makeStruct consumes the payload even when
    // allocating the run fails, so close that ownership boundary before
    // returning from the failure arm.
    const union_value = runtime.makeStruct(&.{ Value.ofLong(7), union_payload }) catch |mistake| {
        union_payload_loose = false;
        return mistake;
    };
    union_payload_loose = false;
    var union_loose = true;
    errdefer if (union_loose) runtime.freeValue(union_value);

    const optional_value = if (optional_present) try nestedList(runtime) else Value.none;
    var optional_loose = optional_present;
    errdefer if (optional_loose) runtime.freeValue(optional_value);

    const map_value = try nestedCopySource(runtime, .map);
    var map_loose = true;
    errdefer if (map_loose) runtime.freeValue(map_value);
    const array_value = try nestedCopySource(runtime, .array);
    var array_loose = true;
    errdefer if (array_loose) runtime.freeValue(array_value);
    const note = try runtime.ownValue(Value.ofString(
        "a union and optional record owns outside bytes during its failed copy",
    ));
    var note_owned = true;
    errdefer if (note_owned) runtime.dropStorage(note);

    var fields = [_]Value{ union_value, optional_value, map_value, array_value, note };
    // makeStruct consumes every field on both success and allocation
    // failure.  The flags above therefore become false before either
    // result leaves this helper.
    const record = runtime.makeStruct(&fields) catch |mistake| {
        union_loose = false;
        optional_loose = false;
        map_loose = false;
        array_loose = false;
        note_owned = false;
        return mistake;
    };
    union_loose = false;
    optional_loose = false;
    map_loose = false;
    array_loose = false;
    note_owned = false;
    return record;
}

fn expectUnionOptionalSourceIntact(
    runtime: *Runtime,
    held: Value,
    optional_present: bool,
) !void {
    const fields = held.asStruct();
    try testing.expectEqual(@as(usize, 5), fields.len);

    const union_fields = fields[0].asStruct();
    try testing.expectEqual(@as(usize, 2), union_fields.len);
    try testing.expectEqual(@as(i64, 7), union_fields[0].asLong());
    try expectNestedListIntact(runtime, union_fields[1]);

    if (optional_present) {
        try expectNestedListIntact(runtime, fields[1]);
    } else {
        try testing.expect(fields[1].isNone());
    }
    try expectNestedSourceIntact(runtime, fields[2], .map);
    try expectNestedSourceIntact(runtime, fields[3], .array);
    try testing.expectEqualStrings(
        "a union and optional record owns outside bytes during its failed copy",
        fields[4].asString(),
    );
}

fn expectBindingRoots(runtime: *Runtime, held: Value, serial: u64, local: u32) !void {
    switch (held.view()) {
        .object => {
            const owner = (try runtime.resolve(held)).owner;
            try testing.expectEqual(heap.Owner.Kind.binding, owner.kind);
            try testing.expectEqual(serial, owner.details.binding.serial);
            try testing.expectEqual(local, owner.details.binding.local);
        },
        .strukt => |fields| for (fields) |field| {
            try expectBindingRoots(runtime, field, serial, local);
        },
        .function => {},
        else => {},
    }
}

/// Copy a value-shaped union/optional graph through every destination
/// allocation failure.  The source is checked semantically on each failure,
/// not only after the allocator sweep, so a temporary source mutation cannot
/// hide behind a later cleanup path.
fn copyUnionOptionalWithAllocator(
    allocator: std.mem.Allocator,
    source: *Runtime,
    held: Value,
    optional_present: bool,
) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    var target: Runtime = .init(.{ .arena = arena.allocator(), .objects = allocator });
    defer {
        target.deinit();
        arena.deinit();
    }

    const duplicate = target.copyFrom(source, held) catch |mistake| {
        target.debugAssertInvariants();
        source.debugAssertInvariants();
        try expectUnionOptionalSourceIntact(source, held, optional_present);
        try testing.expectEqual(@as(u32, 0), target.live);
        return mistake;
    };
    target.debugAssertInvariants();
    source.debugAssertInvariants();
    try expectUnionOptionalSourceIntact(source, held, optional_present);
    target.freeValue(duplicate);
    target.debugAssertInvariants();
    try testing.expectEqual(@as(u32, 0), target.live);
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

/// Move a nested owner graph into a second runtime while refusing each
/// destination allocation in turn.  A failed move must leave the source
/// graph readable, the destination's pre-existing logical rows unchanged,
/// and no partial target rows behind for teardown to discover.  A failing
/// allocator may leave spare table capacity, which remains owned and is
/// checked for complete reclamation below.
fn expectNestedMoveFailures(shape: CopyShape) !usize {
    var failures: usize = 0;
    for (0..64) |failure_offset| {
        var source_arena: std.heap.ArenaAllocator = .init(testing.allocator);
        var source: Runtime = .init(.{
            .arena = source_arena.allocator(),
            .objects = testing.allocator,
        });
        const held = try nestedCopySource(&source, shape);
        const source_live = source.live;

        var target_objects: std.testing.FailingAllocator = .init(testing.allocator, .{});
        var target_arena: std.heap.ArenaAllocator = .init(testing.allocator);
        var target: Runtime = .init(.{
            .arena = target_arena.allocator(),
            .objects = target_objects.allocator(),
        });
        const baseline = try target.newMap();
        const reusable = try target.newList(Value.none);
        target.freeObject(reusable.asObject());
        const baseline_live = target.live;
        const baseline_table_len = target.table.items.len;
        const baseline_free_row = target.free_row;
        const baseline_bytes = target_objects.allocated_bytes - target_objects.freed_bytes;
        target_objects.fail_index = target_objects.alloc_index + failure_offset;

        const outcome = source.moveInto(&target, held);
        var completed = false;
        if (outcome) |carried| {
            target.freeValue(carried);
            completed = true;
        } else |mistake| {
            failures += 1;
            try testing.expectEqual(error.OutOfMemory, mistake);
            try testing.expectEqual(source_live, source.live);
            try expectNestedSourceIntact(&source, held, shape);
            try testing.expectEqual(baseline_live, target.live);
            try testing.expectEqual(baseline_table_len, target.table.items.len);
            try testing.expectEqual(baseline_free_row, target.free_row);
            try testing.expectEqual(@as(i64, 0), (try containers.length(&target, baseline)).asLong());
            // A failing allocator may refuse the shrink performed while
            // restoring a grown table.  That retains owned spare capacity,
            // but it is not a leaked row or object and is reclaimed by
            // target.deinit below.
            try testing.expect(
                target_objects.allocated_bytes - target_objects.freed_bytes >= baseline_bytes,
            );
            try testing.expect(target.pending == null);
        }

        source.freeValue(held);
        target.freeValue(baseline);
        const induced = target_objects.has_induced_failure;
        source.deinit();
        source_arena.deinit();
        target.deinit();
        target_arena.deinit();
        try testing.expectEqual(target_objects.allocated_bytes, target_objects.freed_bytes);
        if (completed) return failures;
        try testing.expect(induced);
    }
    return error.NestedMoveNeverCompleted;
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
    fn count(_: ?*anyopaque) callconv(.c) i64 {
        return @intCast(built_list_words.len);
    }

    fn get(
        _: ?*anyopaque,
        index: i64,
        text_out: *[*c]const u8,
        length_out: *i64,
    ) callconv(.c) i32 {
        if (index < 0 or index >= @as(i64, built_list_words.len)) return 0;
        const held = built_list_words[@intCast(index)];
        text_out.* = held.ptr;
        length_out.* = @intCast(held.len);
        return 1;
    }
};

const NullArgument = struct {
    fn count(_: ?*anyopaque) callconv(.c) i64 {
        return 1;
    }

    fn get(
        _: ?*anyopaque,
        _: i64,
        text_out: *[*c]const u8,
        length_out: *i64,
    ) callconv(.c) i32 {
        text_out.* = null;
        length_out.* = 1;
        return 1;
    }
};

const InvalidArgumentAnswer = struct {
    fn count(_: ?*anyopaque) callconv(.c) i64 {
        return 1;
    }

    fn get(
        _: ?*anyopaque,
        _: i64,
        text_out: *[*c]const u8,
        length_out: *i64,
    ) callconv(.c) i32 {
        const words = "malformed answer";
        text_out.* = words.ptr;
        length_out.* = words.len;
        return 2;
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
    produce_graph: bool = false,
    exhausted: bool = false,
    raise_error: bool = false,
    run_answer: ?i32 = null,
    closes: usize = 0,
    child_live_at_close: u32 = 0,
    spawns: usize = 0,
    joins: usize = 0,
    join_answer: i32 = workers.yes,
    spawn_answer: i32 = workers.yes,
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

    fn failed(self: *@This(), runtime: *Runtime, mistake: heap.Error) i32 {
        _ = self;
        if (mistake == error.OutOfMemory) runtime.exhausted = true;
        return workers.raised_trap;
    }

    fn graphResult(self: *@This(), runtime: *Runtime, out: *Value) i32 {
        var leaf: Value = .none;
        var leaf_owned = false;
        var branch: Value = .none;
        var branch_owned = false;
        var words: Value = .none;
        var words_owned = false;
        defer {
            if (words_owned) runtime.freeValue(words);
            if (branch_owned) runtime.freeValue(branch);
            if (leaf_owned) runtime.freeValue(leaf);
        }

        leaf = runtime.newList(Value.none) catch |mistake| return self.failed(runtime, mistake);
        leaf_owned = true;
        containers.append(runtime, leaf, Value.ofLong(11)) catch |mistake|
            return self.failed(runtime, mistake);

        branch = runtime.newList(Value.none) catch |mistake| return self.failed(runtime, mistake);
        branch_owned = true;
        containers.append(runtime, branch, leaf) catch |mistake|
            return self.failed(runtime, mistake);
        // The successful append moved the leaf's object edge into branch.
        leaf_owned = false;

        words = runtime.ownValue(Value.ofString(
            "worker graph result has outside storage",
        )) catch |mistake| return self.failed(runtime, mistake);
        words_owned = true;
        var fields = [_]Value{
            branch,
            words,
        };
        const result = runtime.makeStruct(&fields) catch |mistake| {
            // makeStruct consumes all fields on allocation failure.  Do
            // not let the local cleanup release the same graph twice.
            branch_owned = false;
            words_owned = false;
            return self.failed(runtime, mistake);
        };
        branch_owned = false;
        words_owned = false;
        out.* = result;
        return workers.survived;
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
        if (self.run_answer) |answer| return answer;
        if (self.exhausted) {
            runtime.exhausted = true;
            return workers.raised_trap;
        }
        if (self.raise_error) {
            runtime.raise(.user_error, "the worker raised an error", .{
                .function = "worker",
                .function_length = 6,
                .source = "worker.luc",
                .source_length = 11,
                .line = 1,
                .column = 1,
            });
            return workers.raised_error;
        }
        if (self.produce_graph) {
            const outcome = self.graphResult(runtime, out);
            if (outcome != workers.survived) return outcome;
            self.ran = true;
            return workers.survived;
        }
        if (!self.produce_result) return workers.survived;
        const words = runtime.ownValue(Value.ofString(
            "the unclaimed worker result owns outside bytes",
        )) catch |mistake| return self.failed(runtime, mistake);
        out.* = runtime.makeStruct(&.{words}) catch |mistake| return self.failed(runtime, mistake);
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
        return self.spawn_answer;
    }

    fn join(context: ?*anyopaque, _: i64) callconv(.c) i32 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.joins += 1;
        return self.join_answer;
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

const ConcurrentTeardown = struct {
    const capacity = 4;

    const Child = struct {
        arena: std.heap.ArenaAllocator = undefined,
        runtime: Runtime = undefined,
        active: bool = false,
    };

    const Launch = struct {
        body: workers.Body,
        argument: ?*anyopaque,
    };

    gate: std.atomic.Value(bool) = .init(false),
    started: std.atomic.Value(u32) = .init(0),
    finished: std.atomic.Value(u32) = .init(0),
    children: [capacity]Child = undefined,
    threads: [capacity]?std.Thread = [_]?std.Thread{null} ** capacity,
    spawn_count: usize = 0,
    joins: usize = 0,
    closes: usize = 0,
    child_live_at_close: [capacity]u32 = [_]u32{std.math.maxInt(u32)} ** capacity,

    fn open(context: ?*anyopaque) callconv(.c) ?*Runtime {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        for (&self.children) |*child| {
            if (child.active) continue;
            child.arena = .init(testing.allocator);
            child.runtime = .init(.{
                .arena = child.arena.allocator(),
                .objects = testing.allocator,
            });
            child.active = true;
            return &child.runtime;
        }
        return null;
    }

    fn close(context: ?*anyopaque, runtime: *Runtime) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        for (&self.children, 0..) |*child, index| {
            if (!child.active or runtime != &child.runtime) continue;
            self.child_live_at_close[index] = runtime.live;
            runtime.deinit();
            child.arena.deinit();
            child.active = false;
            self.closes += 1;
            return;
        }
        @panic("concurrent teardown closed an unknown child");
    }

    fn threadMain(launch: Launch) void {
        launch.body(launch.argument);
    }

    fn spawn(
        context: ?*anyopaque,
        body: workers.Body,
        argument: ?*anyopaque,
        thread: *i64,
    ) callconv(.c) i32 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (self.spawn_count == capacity) return workers.no;
        const index = self.spawn_count;
        const made = std.Thread.spawn(.{}, threadMain, .{Launch{
            .body = body,
            .argument = argument,
        }}) catch return workers.no;
        self.threads[index] = made;
        self.spawn_count += 1;
        thread.* = @intCast(index);
        return workers.yes;
    }

    fn join(context: ?*anyopaque, thread: i64) callconv(.c) i32 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const index: usize = @intCast(thread);
        if (index >= capacity) return workers.no;
        const running = self.threads[index] orelse return workers.no;
        // `Runtime.deinit` reaches this callback while the child is still
        // deliberately blocked.  Opening the gate here proves that the
        // release path, not test setup, is what makes teardown progress.
        self.gate.store(true, .release);
        running.join();
        self.threads[index] = null;
        self.joins += 1;
        return workers.yes;
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
        _ = self.started.fetchAdd(1, .acq_rel);
        while (!self.gate.load(.acquire)) std.Thread.yield() catch {};

        const leaf = runtime.newList(Value.none) catch {
            runtime.exhausted = true;
            return workers.raised_trap;
        };
        containers.append(runtime, leaf, Value.ofLong(7)) catch {
            runtime.freeValue(leaf);
            runtime.exhausted = true;
            return workers.raised_trap;
        };
        var fields = [_]Value{ leaf, Value.ofLong(11) };
        const result = runtime.makeStruct(&fields) catch {
            // `makeStruct` consumes the fields on this failure path.
            runtime.exhausted = true;
            return workers.raised_trap;
        };
        out.* = result;
        _ = self.finished.fetchAdd(1, .acq_rel);
        return workers.survived;
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

test "blocked worker teardown joins and closes every nested child" {
    var state: ConcurrentTeardown = .{};
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    var runtime: Runtime = .init(.{
        .arena = arena.allocator(),
        .objects = testing.allocator,
    });
    var cleaned = false;
    defer if (!cleaned) {
        state.gate.store(true, .release);
        for (&state.threads) |*thread| if (thread.*) |running| running.join();
        runtime.deinit();
        arena.deinit();
    };
    state.install(&runtime);

    const tasks = try runtime.newList(Value.none);
    for (0..ConcurrentTeardown.capacity) |_| {
        var task: Value = .none;
        try workers.spawn(&runtime, 0, &.{}, &task);
        try containers.append(&runtime, tasks, task);
    }

    while (state.started.load(.acquire) != ConcurrentTeardown.capacity) {
        std.Thread.yield() catch {};
    }
    try testing.expectEqual(@as(u32, 0), state.finished.load(.acquire));
    try testing.expectEqual(@as(usize, ConcurrentTeardown.capacity), state.spawn_count);

    // Releasing the only parent root is the teardown under test.  Each
    // task is still blocked here; the first join opens the gate and every
    // subsequent join waits for a child that is now building its graph.
    runtime.freeValue(tasks);
    try testing.expectEqual(@as(u32, 0), runtime.live);
    try testing.expectEqual(
        @as(u32, ConcurrentTeardown.capacity),
        state.finished.load(.acquire),
    );
    try testing.expectEqual(ConcurrentTeardown.capacity, state.joins);
    try testing.expectEqual(ConcurrentTeardown.capacity, state.closes);
    for (state.child_live_at_close) |live| try testing.expectEqual(@as(u32, 0), live);
    for (state.children) |child| try testing.expect(!child.active);

    runtime.deinit();
    arena.deinit();
    cleaned = true;
}

const BlockedResourceTeardown = struct {
    const capacity = 2;

    const Child = struct {
        arena: std.heap.ArenaAllocator = undefined,
        runtime: Runtime = undefined,
        active: bool = false,
    };

    const Launch = struct {
        body: workers.Body,
        argument: ?*anyopaque,
    };

    effects: *workers.Effects,
    gate: std.atomic.Value(bool) = .init(false),
    read_started: std.atomic.Value(u32) = .init(0),
    read_returned: std.atomic.Value(u32) = .init(0),
    bad_lock: std.atomic.Value(bool) = .init(false),
    children: [capacity]Child = undefined,
    threads: [capacity]?std.Thread = [_]?std.Thread{null} ** capacity,
    spawn_count: usize = 0,
    joins: std.atomic.Value(usize) = .init(0),
    closes: usize = 0,
    file_opens: usize = 0,
    file_closes: usize = 0,
    close_before_join: usize = 0,
    close_after_join: usize = 0,
    opened_handles: [capacity]i64 = undefined,
    closed_handles: [capacity]bool = [_]bool{false} ** capacity,
    duplicate_close: bool = false,
    unknown_close: bool = false,
    child_live_at_close: [capacity]u32 = [_]u32{std.math.maxInt(u32)} ** capacity,

    fn observe(self: *@This()) void {
        const this_thread: usize = @intCast(std.Thread.getCurrentId());
        if (self.effects.owner.load(.acquire) != this_thread or self.effects.depth != 1) {
            self.bad_lock.store(true, .release);
        }
    }

    fn open(context: ?*anyopaque) callconv(.c) ?*Runtime {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        for (&self.children) |*child| {
            if (child.active) continue;
            child.arena = .init(testing.allocator);
            child.runtime = .init(.{
                .arena = child.arena.allocator(),
                .objects = testing.allocator,
            });
            child.active = true;
            return &child.runtime;
        }
        return null;
    }

    fn close(context: ?*anyopaque, runtime: *Runtime) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        for (&self.children, 0..) |*child, index| {
            if (!child.active or runtime != &child.runtime) continue;
            self.child_live_at_close[index] = runtime.live;
            runtime.debugAssertInvariants();
            runtime.deinit();
            child.arena.deinit();
            child.active = false;
            self.closes += 1;
            return;
        }
        @panic("blocked resource teardown closed an unknown child");
    }

    fn threadMain(launch: Launch) void {
        launch.body(launch.argument);
    }

    fn spawn(
        context: ?*anyopaque,
        body: workers.Body,
        argument: ?*anyopaque,
        thread: *i64,
    ) callconv(.c) i32 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (self.spawn_count == capacity) return workers.no;
        const index = self.spawn_count;
        const made = std.Thread.spawn(.{}, threadMain, .{Launch{
            .body = body,
            .argument = argument,
        }}) catch return workers.no;
        self.threads[index] = made;
        self.spawn_count += 1;
        thread.* = @intCast(index);
        return workers.yes;
    }

    fn join(context: ?*anyopaque, thread: i64) callconv(.c) i32 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const index: usize = @intCast(thread);
        if (index >= capacity) return workers.no;
        const running = self.threads[index] orelse return workers.no;
        // The child is intentionally blocked while holding the effects
        // mutex in `fileRead`.  The parent never needs that mutex to join;
        // opening this gate here proves teardown can release the blocked
        // resource call and then wait for its owner to finish.
        self.gate.store(true, .release);
        running.join();
        self.threads[index] = null;
        _ = self.joins.fetchAdd(1, .acq_rel);
        return workers.yes;
    }

    fn fileOpen(
        context: ?*anyopaque,
        _: [*]const u8,
        _: i64,
        _: i64,
        handle: *i64,
    ) callconv(.c) i32 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.observe();
        if (self.file_opens == capacity) return files.exhausted;
        const next: i64 = @intCast(20_000 + self.file_opens);
        self.opened_handles[self.file_opens] = next;
        self.closed_handles[self.file_opens] = false;
        self.file_opens += 1;
        handle.* = next;
        return files.yes;
    }

    fn fileRead(
        context: ?*anyopaque,
        handle: i64,
        _: [*]u8,
        _: i64,
        filled: *i64,
    ) callconv(.c) i32 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.observe();
        var known = false;
        for (self.opened_handles[0..self.file_opens]) |opened| {
            if (opened == handle) known = true;
        }
        if (!known) return files.no;
        _ = self.read_started.fetchAdd(1, .acq_rel);
        while (!self.gate.load(.acquire)) std.Thread.yield() catch {};
        filled.* = 0;
        _ = self.read_returned.fetchAdd(1, .acq_rel);
        return files.yes;
    }

    fn fileClose(context: ?*anyopaque, handle: i64) callconv(.c) i32 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.observe();
        self.file_closes += 1;
        if (self.joins.load(.acquire) == 0) self.close_before_join += 1 else self.close_after_join += 1;
        for (self.opened_handles[0..self.file_opens], 0..) |opened, index| {
            if (opened != handle) continue;
            if (self.closed_handles[index]) self.duplicate_close = true;
            self.closed_handles[index] = true;
            return files.yes;
        }
        self.unknown_close = true;
        return files.yes;
    }

    fn failed(runtime: *Runtime, mistake: heap.Error) i32 {
        if (mistake == error.OutOfMemory) runtime.exhausted = true;
        return workers.raised_trap;
    }

    fn run(
        _: ?*anyopaque,
        runtime: *Runtime,
        function: i64,
        _: [*]const Value,
        _: i64,
        out: *Value,
        _: i64,
    ) callconv(.c) i32 {
        const held = files.open(
            runtime,
            "blocked-worker-resource.bin",
            @intFromEnum(files.Mode.read),
        ) catch |mistake| return failed(runtime, mistake);
        const file = held orelse {
            _ = runtime.fail(.host_unavailable) catch {};
            return workers.raised_trap;
        };
        const buffer = runtime.newArray(&.{1}, Value.ofByte(0)) catch |mistake| {
            runtime.freeValue(file);
            return failed(runtime, mistake);
        };
        defer runtime.freeValue(buffer);

        const answered = files.read(runtime, file, buffer) catch |mistake| {
            return failed(runtime, mistake);
        };
        if (answered == null) {
            _ = runtime.fail(.host_unavailable) catch {};
            return workers.raised_trap;
        }

        if (function == 0) {
            // This child closes its resource while still running.  The
            // sibling below deliberately leaves its resource live so the
            // child-runtime sweep must close it after the parent joins.
            runtime.freeValue(file);
            out.* = .none;
            return workers.survived;
        }
        _ = runtime.fail(.host_unavailable) catch {};
        return workers.raised_trap;
    }

    fn install(self: *@This(), parent: *Runtime) void {
        parent.files = .{
            .context = self,
            .open = fileOpen,
            .read = fileRead,
            .close = fileClose,
        };
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

test "blocked worker resource calls unwind through normal and exceptional cleanup" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    var runtime: Runtime = .init(.{
        .arena = arena.allocator(),
        .objects = testing.allocator,
    });
    var cleaned = false;
    defer if (!cleaned) {
        runtime.deinit();
        arena.deinit();
    };

    const effects = try runtime.sharedEffects();
    var state: BlockedResourceTeardown = .{ .effects = effects };
    state.install(&runtime);

    var tasks = try runtime.newList(Value.none);
    defer if (!cleaned) {
        state.gate.store(true, .release);
        runtime.freeValue(tasks);
    };
    for (0..BlockedResourceTeardown.capacity) |function| {
        var task: Value = .none;
        try workers.spawn(&runtime, @intCast(function), &.{}, &task);
        containers.append(&runtime, tasks, task) catch |mistake| {
            runtime.freeValue(task);
            return mistake;
        };
    }

    // The first child is inside the host callback.  The effect lock makes
    // the sibling wait before its own callback, which is the serialization
    // contract this test also protects.
    while (state.read_started.load(.acquire) != 1) {
        std.Thread.yield() catch {};
    }
    try testing.expectEqual(@as(u32, 0), state.read_returned.load(.acquire));

    // Releasing the parent root is the operation under test.  It must join
    // both children even though one is inside a blocked host callback and
    // the other is waiting for the effects lock; the first join opens the
    // gate, and each child then owns its own close path before its runtime
    // is returned.
    runtime.freeValue(tasks);
    tasks = .none;
    try testing.expectEqual(
        @as(u32, BlockedResourceTeardown.capacity),
        state.read_returned.load(.acquire),
    );
    try testing.expectEqual(
        @as(u32, BlockedResourceTeardown.capacity),
        state.read_started.load(.acquire),
    );
    try testing.expectEqual(
        BlockedResourceTeardown.capacity,
        state.joins.load(.acquire),
    );
    try testing.expectEqual(BlockedResourceTeardown.capacity, state.closes);
    try testing.expectEqual(BlockedResourceTeardown.capacity, state.file_opens);
    try testing.expectEqual(BlockedResourceTeardown.capacity, state.file_closes);
    try testing.expect(state.close_before_join >= 1);
    try testing.expect(state.close_after_join >= 1);
    try testing.expect(!state.bad_lock.load(.acquire));
    try testing.expect(!state.duplicate_close);
    try testing.expect(!state.unknown_close);
    try testing.expectEqual(
        @as(usize, 0),
        state.spawn_count - state.joins.load(.acquire),
    );
    try testing.expectEqual(@as(u32, 0), runtime.live);
    try testing.expectEqual(@as(i64, 1), runtime.inherited_leaks);
    try testing.expectEqual(@as(i64, 1), runtime.leaked());

    var live_at_close: u32 = 0;
    for (state.child_live_at_close) |live| {
        try testing.expect(live <= 1);
        live_at_close += live;
    }
    // One file was explicitly released by its body; the trapped sibling
    // remained owned by its child runtime and was swept exactly once.
    try testing.expectEqual(@as(u32, 1), live_at_close);
    for (state.children) |child| try testing.expect(!child.active);
    runtime.debugAssertInvariants();

    runtime.deinit();
    arena.deinit();
    cleaned = true;
}

const NestedWorkerRace = struct {
    const top_count = 2;
    const nested_per_top = 2;
    const capacity = top_count + top_count * nested_per_top;

    const Child = struct {
        arena: std.heap.ArenaAllocator = undefined,
        runtime: Runtime = undefined,
        active: bool = false,
    };

    const Launch = struct {
        body: workers.Body,
        argument: ?*anyopaque,
    };

    gate: std.atomic.Value(bool) = .init(false),
    nested_started: std.atomic.Value(usize) = .init(0),
    nested_finished: std.atomic.Value(usize) = .init(0),
    top_finished: std.atomic.Value(usize) = .init(0),
    opened: std.atomic.Value(usize) = .init(0),
    spawned: std.atomic.Value(usize) = .init(0),
    joined: std.atomic.Value(usize) = .init(0),
    closed: std.atomic.Value(usize) = .init(0),
    children: [capacity]Child = undefined,
    threads: [capacity]?std.Thread = [_]?std.Thread{null} ** capacity,
    child_live_at_close: [capacity]u32 = [_]u32{std.math.maxInt(u32)} ** capacity,

    fn open(context: ?*anyopaque) callconv(.c) ?*Runtime {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const index = self.opened.fetchAdd(1, .acq_rel);
        if (index >= capacity) return null;
        const child = &self.children[index];
        child.arena = .init(testing.allocator);
        child.runtime = .init(.{
            .arena = child.arena.allocator(),
            .objects = testing.allocator,
        });
        child.active = true;
        return &child.runtime;
    }

    fn close(context: ?*anyopaque, runtime: *Runtime) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        for (&self.children, 0..) |*child, index| {
            if (runtime != &child.runtime) continue;
            self.child_live_at_close[index] = runtime.live;
            runtime.debugAssertInvariants();
            runtime.deinit();
            child.arena.deinit();
            child.active = false;
            _ = self.closed.fetchAdd(1, .acq_rel);
            return;
        }
        @panic("nested worker race closed an unknown child");
    }

    fn threadMain(launch: Launch) void {
        launch.body(launch.argument);
    }

    fn spawn(
        context: ?*anyopaque,
        body: workers.Body,
        argument: ?*anyopaque,
        thread: *i64,
    ) callconv(.c) i32 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const index = self.spawned.fetchAdd(1, .acq_rel);
        if (index >= capacity) return workers.no;
        const made = std.Thread.spawn(.{}, threadMain, .{Launch{
            .body = body,
            .argument = argument,
        }}) catch return workers.no;
        self.threads[index] = made;
        thread.* = @intCast(index);
        return workers.yes;
    }

    fn join(context: ?*anyopaque, thread: i64) callconv(.c) i32 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const index: usize = @intCast(thread);
        if (index >= capacity) return workers.no;
        const running = self.threads[index] orelse return workers.no;
        // Only a parent-level join may release the nested barrier.  The
        // first two thread tickets belong to the sibling workers; joins
        // from those workers to their nested children must remain blocked
        // until the parent reaches this graph.
        if (index < top_count) self.gate.store(true, .release);
        running.join();
        self.threads[index] = null;
        _ = self.joined.fetchAdd(1, .acq_rel);
        return workers.yes;
    }

    fn failed(runtime: *Runtime, mistake: heap.Error) i32 {
        if (mistake == error.OutOfMemory) runtime.exhausted = true;
        return workers.raised_trap;
    }

    fn run(
        context: ?*anyopaque,
        runtime: *Runtime,
        function: i64,
        _: [*]const Value,
        _: i64,
        out: *Value,
        _: i64,
    ) callconv(.c) i32 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (function == 1) {
            _ = self.nested_started.fetchAdd(1, .acq_rel);
            while (!self.gate.load(.acquire)) std.Thread.yield() catch {};
            _ = self.nested_finished.fetchAdd(1, .acq_rel);
            out.* = .none;
            return workers.survived;
        }

        const nested_tasks = runtime.newList(Value.none) catch |mistake|
            return failed(runtime, mistake);
        for (0..nested_per_top) |_| {
            var task: Value = .none;
            workers.spawn(runtime, 1, &.{}, &task) catch |mistake| {
                runtime.freeValue(nested_tasks);
                return failed(runtime, mistake);
            };
            containers.append(runtime, nested_tasks, task) catch |mistake| {
                runtime.freeValue(task);
                runtime.freeValue(nested_tasks);
                return failed(runtime, mistake);
            };
        }

        // The top worker owns both nested task values.  Its own release
        // joins the nested children, while the parent may concurrently be
        // joining this top worker.  This is the nested ownership edge that
        // the synchronous lifecycle model cannot exercise.
        runtime.freeValue(nested_tasks);
        _ = self.top_finished.fetchAdd(1, .acq_rel);
        out.* = .none;
        return workers.survived;
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

fn runNestedWorkerRace(wait_first: bool) !void {
    var state: NestedWorkerRace = .{};
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    var runtime: Runtime = .init(.{
        .arena = arena.allocator(),
        .objects = testing.allocator,
    });
    var cleaned = false;
    defer if (!cleaned) {
        state.gate.store(true, .release);
        runtime.deinit();
        arena.deinit();
    };
    state.install(&runtime);

    var top_tasks = try runtime.newList(Value.none);
    defer if (!cleaned) {
        state.gate.store(true, .release);
        runtime.freeValue(top_tasks);
    };
    for (0..NestedWorkerRace.top_count) |_| {
        var task: Value = .none;
        workers.spawn(&runtime, 0, &.{}, &task) catch |mistake| return mistake;
        containers.append(&runtime, top_tasks, task) catch |mistake| {
            runtime.freeValue(task);
            return mistake;
        };
    }

    while (state.nested_started.load(.acquire) !=
        NestedWorkerRace.top_count * NestedWorkerRace.nested_per_top)
    {
        std.Thread.yield() catch {};
    }
    try testing.expectEqual(
        NestedWorkerRace.capacity,
        state.spawned.load(.acquire),
    );
    try testing.expectEqual(
        NestedWorkerRace.capacity,
        state.opened.load(.acquire),
    );
    try testing.expectEqual(
        @as(usize, 0),
        state.nested_finished.load(.acquire),
    );

    if (wait_first) {
        // Consume one sibling explicitly.  Its nested joins open the gate,
        // and the second sibling is then released through list teardown.
        const first = try containers.pop(&runtime, top_tasks);
        var answer: Value = .none;
        try testing.expectEqual(
            workers.survived,
            try workers.wait(&runtime, first, &answer),
        );
        runtime.freeValue(answer);
        runtime.freeValue(first);
    }

    runtime.freeValue(top_tasks);
    top_tasks = .none;
    try testing.expectEqual(
        NestedWorkerRace.top_count * NestedWorkerRace.nested_per_top,
        state.nested_finished.load(.acquire),
    );
    try testing.expectEqual(
        NestedWorkerRace.top_count,
        state.top_finished.load(.acquire),
    );
    try testing.expectEqual(
        NestedWorkerRace.capacity,
        state.joined.load(.acquire),
    );
    try testing.expectEqual(
        NestedWorkerRace.capacity,
        state.closed.load(.acquire),
    );
    try testing.expectEqual(@as(u32, 0), runtime.live);
    try testing.expectEqual(@as(i64, 0), runtime.leaked());
    for (state.child_live_at_close) |live| try testing.expectEqual(@as(u32, 0), live);
    for (state.children) |child| try testing.expect(!child.active);
    runtime.debugAssertInvariants();

    runtime.deinit();
    arena.deinit();
    cleaned = true;
}

test "sibling workers join nested workers through both teardown orders" {
    try runNestedWorkerRace(false);
    try runNestedWorkerRace(true);
}

const ParentStop = enum { trap, exit };

fn runBlockedParentStop(stop: ParentStop) !void {
    var state: ConcurrentTeardown = .{};
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    var runtime: Runtime = .init(.{
        .arena = arena.allocator(),
        .objects = testing.allocator,
    });
    var cleaned = false;
    defer if (!cleaned) {
        state.gate.store(true, .release);
        for (&state.threads) |*thread| if (thread.*) |running| running.join();
        runtime.deinit();
        arena.deinit();
    };
    state.install(&runtime);

    const tasks = try runtime.newList(Value.none);
    for (0..ConcurrentTeardown.capacity) |_| {
        var task: Value = .none;
        try workers.spawn(&runtime, 0, &.{}, &task);
        try containers.append(&runtime, tasks, task);
    }
    while (state.started.load(.acquire) != ConcurrentTeardown.capacity) {
        std.Thread.yield() catch {};
    }
    try testing.expectEqual(@as(u32, 0), state.finished.load(.acquire));

    switch (stop) {
        .trap => _ = runtime.fail(.host_unavailable) catch {},
        .exit => runtime.exit_status = 77,
    }
    runtime.freeValue(tasks);

    try testing.expectEqual(@as(u32, 0), runtime.live);
    try testing.expectEqual(ConcurrentTeardown.capacity, state.joins);
    try testing.expectEqual(ConcurrentTeardown.capacity, state.closes);
    for (state.child_live_at_close) |live| try testing.expectEqual(@as(u32, 0), live);
    switch (stop) {
        .trap => try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code),
        .exit => try testing.expectEqual(@as(i64, 77), runtime.exit_status.?),
    }
    runtime.debugAssertInvariants();

    runtime.deinit();
    arena.deinit();
    cleaned = true;
}

test "blocked workers join while the parent is trapping or exiting" {
    try runBlockedParentStop(.trap);
    try runBlockedParentStop(.exit);
}

test "worker channel exhaustion rejects without orphaning a child" {
    var state: ConcurrentTeardown = .{};
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    var runtime: Runtime = .init(.{
        .arena = arena.allocator(),
        .objects = testing.allocator,
    });
    var cleaned = false;
    defer if (!cleaned) {
        state.gate.store(true, .release);
        for (&state.threads) |*thread| if (thread.*) |running| {
            running.join();
            thread.* = null;
        };
        runtime.deinit();
        arena.deinit();
    };
    state.install(&runtime);

    const tasks = try runtime.newList(Value.none);
    for (0..ConcurrentTeardown.capacity) |_| {
        var task: Value = .none;
        try workers.spawn(&runtime, 0, &.{}, &task);
        try containers.append(&runtime, tasks, task);
    }
    while (state.started.load(.acquire) != ConcurrentTeardown.capacity) {
        std.Thread.yield() catch {};
    }

    const popped = try containers.pop(&runtime, tasks);
    runtime.freeValue(popped);
    try testing.expectEqual(@as(usize, 1), state.joins);
    try testing.expectEqual(@as(usize, 1), state.closes);

    var rejected: Value = Value.ofLong(99);
    try testing.expectError(error.Trap, workers.spawn(&runtime, 0, &.{}, &rejected));
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    try testing.expectEqual(@as(i64, 99), rejected.asLong());
    runtime.pending = null;
    try testing.expectEqual(ConcurrentTeardown.capacity, state.spawn_count);
    try testing.expectEqual(@as(usize, 2), state.closes);

    runtime.freeValue(tasks);
    try testing.expectEqual(@as(u32, 0), runtime.live);
    try testing.expectEqual(ConcurrentTeardown.capacity, state.joins);
    try testing.expectEqual(ConcurrentTeardown.capacity + 1, state.closes);
    for (state.children) |child| try testing.expect(!child.active);
    runtime.debugAssertInvariants();

    runtime.deinit();
    arena.deinit();
    cleaned = true;
}

// ---------------------------------------------------------------------------
// Mixed worker/resource lifecycle model
// ---------------------------------------------------------------------------

/// A synchronous nursery for the randomized lifecycle proof.  It still
/// exercises the complete Worker implementation — argument transfer, body,
/// result ownership, join, finish, and child close — while making the
/// generated transition trace deterministic.  The real threaded channel is
/// covered by `specs/threads_spec.zig`; this model is for hundreds of
/// ownership transitions where scheduling noise would hide the state
/// machine's contract.
const lifecycle_child_capacity = 64;
const lifecycle_record_capacity = 48;
const lifecycle_file_capacity = 256;

const LifecycleChild = struct {
    arena: std.heap.ArenaAllocator = undefined,
    runtime: Runtime = undefined,
    active: bool = false,
};

const LifecycleState = struct {
    slots: [lifecycle_child_capacity]LifecycleChild = undefined,
    opened_handles: [lifecycle_file_capacity]i64 = undefined,
    closed_handles: [lifecycle_file_capacity]bool = undefined,
    opens: usize = 0,
    closes: usize = 0,
    file_opens: usize = 0,
    file_closes: usize = 0,
    spawns: usize = 0,
    joins: usize = 0,
    child_live_at_close: u32 = 0,
    expected_leaks: i64 = 0,
    duplicate_close: bool = false,
    unknown_close: bool = false,
    file_overflow: bool = false,

    fn init() @This() {
        var state: @This() = undefined;
        for (&state.slots) |*slot| slot.* = .{};
        state.opens = 0;
        state.closes = 0;
        state.file_opens = 0;
        state.file_closes = 0;
        state.spawns = 0;
        state.joins = 0;
        state.child_live_at_close = 0;
        state.expected_leaks = 0;
        state.duplicate_close = false;
        state.unknown_close = false;
        state.file_overflow = false;
        return state;
    }

    fn open(context: ?*anyopaque) callconv(.c) ?*Runtime {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        for (&self.slots) |*slot| {
            if (slot.active) continue;
            slot.arena = .init(testing.allocator);
            slot.runtime = Runtime.init(.{
                .arena = slot.arena.allocator(),
                .objects = testing.allocator,
            });
            slot.active = true;
            self.opens += 1;
            return &slot.runtime;
        }
        return null;
    }

    fn close(context: ?*anyopaque, runtime: *Runtime) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        for (&self.slots) |*slot| {
            if (!slot.active or runtime != &slot.runtime) continue;
            runtime.debugAssertInvariants();
            self.child_live_at_close = runtime.live;
            runtime.deinit();
            slot.arena.deinit();
            slot.active = false;
            self.closes += 1;
            return;
        }
        // An unknown child is already a broken nursery contract.  Still
        // close the passed runtime so the test reports the identity error
        // rather than turning it into an allocator leak during cleanup.
        self.unknown_close = true;
        runtime.deinit();
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
        thread.* = @intCast(self.spawns);
        return workers.yes;
    }

    fn join(context: ?*anyopaque, _: i64) callconv(.c) i32 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.joins += 1;
        return workers.yes;
    }

    fn fileOpen(
        context: ?*anyopaque,
        _: [*]const u8,
        _: i64,
        _: i64,
        handle: *i64,
    ) callconv(.c) i32 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (self.file_opens == lifecycle_file_capacity) {
            self.file_overflow = true;
            return files.exhausted;
        }
        const next: i64 = @intCast(10_000 + self.file_opens);
        self.opened_handles[self.file_opens] = next;
        self.closed_handles[self.file_opens] = false;
        self.file_opens += 1;
        handle.* = next;
        return files.yes;
    }

    fn fileClose(context: ?*anyopaque, handle: i64) callconv(.c) i32 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.file_closes += 1;
        for (self.opened_handles[0..self.file_opens], 0..) |opened, index| {
            if (opened != handle) continue;
            if (self.closed_handles[index]) self.duplicate_close = true;
            self.closed_handles[index] = true;
            return files.yes;
        }
        self.unknown_close = true;
        return files.yes;
    }

    fn install(self: *@This(), parent: *Runtime) void {
        parent.files = .{
            .context = self,
            .open = fileOpen,
            .close = fileClose,
        };
        parent.workers = .{
            .context = self,
            .spawn = spawn,
            .join = join,
        };
        parent.nursery = .{
            .context = self,
            .open = open,
            .close = close,
            .run = lifecycleRun,
        };
    }

    fn activeChildren(self: *const @This()) usize {
        var count: usize = 0;
        for (self.slots) |slot| {
            if (slot.active) count += 1;
        }
        return count;
    }
};

const LifecycleAction = enum(u8) {
    clean,
    leak,
    raise_error,
    trap,
    exit,
    result,
    result_resource,
    nested_wait,
    nested_release,
};

const LifecycleGraph = struct {
    root: Value,
    file: Value = .none,
};

const LifecycleTask = struct {
    handle: Value,
    action: LifecycleAction,
    active: bool = true,
    joined: bool = false,
    open_files: usize = 0,
    leaked_objects: i64 = 0,
};

const LifecycleResource = struct {
    root: Value,
    file: Value,
    active: bool = true,
};

fn lifecycleAction(function: i64) LifecycleAction {
    return @enumFromInt(@as(u8, @intCast(@mod(function, 9))));
}

fn lifecycleFailure(runtime: *Runtime, mistake: heap.Error) i32 {
    if (mistake == error.OutOfMemory) runtime.exhausted = true;
    return workers.raised_trap;
}

/// Construct array -> map -> list -> file, with a struct value above the
/// graph.  The graph is deliberately the same shape for parent resources and
/// worker-owned resources so a single lifecycle trace covers both ordinary
/// close and child-runtime close.
fn lifecycleGraph(runtime: *Runtime, with_file: bool, stamp: i64) heap.Error!LifecycleGraph {
    const leaf = try runtime.newList(Value.none);
    var leaf_owned = true;
    errdefer if (leaf_owned) runtime.freeValue(leaf);

    try containers.append(runtime, leaf, Value.ofLong(stamp));

    var file: Value = .none;
    var file_owned = false;
    errdefer if (file_owned) runtime.freeValue(file);
    if (with_file) {
        file = (try files.open(
            runtime,
            "lifecycle-resource.bin",
            @intFromEnum(files.Mode.read),
        )) orelse return runtime.fail(.host_unavailable);
        file_owned = true;
        try containers.append(runtime, leaf, file);
        file_owned = false;
    }

    const branch = try runtime.newMap();
    var branch_owned = true;
    errdefer if (branch_owned) runtime.freeValue(branch);
    try containers.indexSet(
        runtime,
        branch,
        &.{Value.ofString("payload")},
        leaf,
    );
    leaf_owned = false;

    const array = try runtime.newArray(&.{1}, Value.none);
    var array_owned = true;
    errdefer if (array_owned) runtime.freeValue(array);
    try containers.indexSet(
        runtime,
        array,
        &.{Value.ofLong(0)},
        branch,
    );
    branch_owned = false;

    var fields = [_]Value{ array, Value.ofLong(stamp) };
    const root = runtime.makeStruct(&fields) catch |mistake| {
        // `makeStruct` consumes all fields even on allocation failure.
        array_owned = false;
        return mistake;
    };
    array_owned = false;
    return .{ .root = root, .file = file };
}

fn lifecycleNested(runtime: *Runtime, wait_for_result: bool, out: *Value) i32 {
    var task: Value = .none;
    workers.spawn(
        runtime,
        @intFromEnum(LifecycleAction.result),
        &.{},
        &task,
    ) catch |mistake| return lifecycleFailure(runtime, mistake);

    if (!wait_for_result) {
        runtime.freeValue(task);
        return workers.survived;
    }

    var answer: Value = .none;
    const status = workers.wait(runtime, task, &answer) catch |mistake| {
        runtime.freeValue(task);
        return lifecycleFailure(runtime, mistake);
    };
    runtime.freeValue(task);
    if (status == workers.survived) {
        out.* = answer;
    } else {
        runtime.freeValue(answer);
    }
    return status;
}

/// Keep a struct value in a real object root when a worker is intentionally
/// left leaky.  A discarded struct would leak only its field-run bytes — the
/// runtime cannot census a value that no object or result retains — whereas
/// this anchor makes the whole graph visible to child.deinit and proves that
/// resource closure and value-storage cleanup happen together.
fn lifecycleRetainGraph(runtime: *Runtime, root: Value) heap.Error!void {
    const anchor = runtime.newList(Value.none) catch |mistake| {
        runtime.freeValue(root);
        return mistake;
    };
    containers.append(runtime, anchor, root) catch |mistake| {
        // A failed retaining append has already returned the struct's
        // value-storage bytes through its consuming errdefer.  The object
        // handles are still loose, so release only that half here.
        runtime.freeObjectsIn(root);
        runtime.freeObject(anchor.asObject());
        return mistake;
    };
}

fn lifecycleRun(
    _: ?*anyopaque,
    runtime: *Runtime,
    function: i64,
    _: [*]const Value,
    _: i64,
    out: *Value,
    _: i64,
) callconv(.c) i32 {
    const action = lifecycleAction(function);
    switch (action) {
        .nested_wait => return lifecycleNested(runtime, true, out),
        .nested_release => return lifecycleNested(runtime, false, out),
        .result => {
            const graph = lifecycleGraph(runtime, false, function) catch |mistake|
                return lifecycleFailure(runtime, mistake);
            out.* = graph.root;
            return workers.survived;
        },
        .result_resource => {
            const graph = lifecycleGraph(runtime, true, function) catch |mistake|
                return lifecycleFailure(runtime, mistake);
            out.* = graph.root;
            return workers.survived;
        },
        .clean => {
            const graph = lifecycleGraph(runtime, true, function) catch |mistake|
                return lifecycleFailure(runtime, mistake);
            runtime.freeValue(graph.root);
            return workers.survived;
        },
        .leak => {
            const graph = lifecycleGraph(runtime, true, function) catch |mistake|
                return lifecycleFailure(runtime, mistake);
            lifecycleRetainGraph(runtime, graph.root) catch |mistake|
                return lifecycleFailure(runtime, mistake);
            return workers.survived;
        },
        .raise_error => {
            const graph = lifecycleGraph(runtime, true, function) catch |mistake|
                return lifecycleFailure(runtime, mistake);
            lifecycleRetainGraph(runtime, graph.root) catch |mistake|
                return lifecycleFailure(runtime, mistake);
            const name = "lifecycle_worker";
            const source = "lifecycle.test";
            runtime.raise(.user_error, "lifecycle worker error", .{
                .function = name.ptr,
                .function_length = name.len,
                .source = source.ptr,
                .source_length = source.len,
                .line = 1,
                .column = 1,
            });
            return workers.raised_error;
        },
        .trap => {
            const graph = lifecycleGraph(runtime, true, function) catch |mistake|
                return lifecycleFailure(runtime, mistake);
            lifecycleRetainGraph(runtime, graph.root) catch |mistake|
                return lifecycleFailure(runtime, mistake);
            runtime.fail(.index_bounds) catch {};
            return workers.raised_trap;
        },
        .exit => {
            const graph = lifecycleGraph(runtime, true, function) catch |mistake|
                return lifecycleFailure(runtime, mistake);
            lifecycleRetainGraph(runtime, graph.root) catch |mistake|
                return lifecycleFailure(runtime, mistake);
            runtime.exit_status = 700 + function;
            return workers.raised_trap;
        },
    }
}

fn lifecycleActiveTasks(records: []const LifecycleTask) usize {
    var count: usize = 0;
    for (records) |record| {
        if (record.active) count += 1;
    }
    return count;
}

fn lifecycleActiveResources(records: []const LifecycleResource) usize {
    var count: usize = 0;
    for (records) |record| {
        if (record.active) count += 1;
    }
    return count;
}

fn lifecycleTaskAt(records: []LifecycleTask, ordinal: usize) *LifecycleTask {
    var seen: usize = 0;
    for (records) |*record| {
        if (!record.active) continue;
        if (seen == ordinal) return record;
        seen += 1;
    }
    unreachable;
}

fn lifecycleResourceAt(records: []LifecycleResource, ordinal: usize) *LifecycleResource {
    var seen: usize = 0;
    for (records) |*record| {
        if (!record.active) continue;
        if (seen == ordinal) return record;
        seen += 1;
    }
    unreachable;
}

fn lifecycleMarkJoined(state: *LifecycleState, task: *LifecycleTask) void {
    if (task.joined) return;
    task.joined = true;
    state.expected_leaks += task.leaked_objects;
}

fn lifecycleWaitTask(
    runtime: *Runtime,
    state: *LifecycleState,
    task: *LifecycleTask,
) !void {
    if (task.joined) {
        var second: Value = Value.ofLong(99);
        try expectTrap(.use_after_free, runtime, workers.wait(runtime, task.handle, &second));
        try testing.expectEqual(@as(i64, 99), second.asLong());
        runtime.pending = null;
        return;
    }

    var answer: Value = .none;
    const status = workers.wait(runtime, task.handle, &answer) catch |mistake| switch (mistake) {
        error.Trap => blk: {
            switch (task.action) {
                .trap => try testing.expectEqual(.index_bounds, runtime.pending.?.code),
                .exit => try testing.expectEqual(
                    @as(i64, 700) + @as(i64, @intFromEnum(task.action)),
                    runtime.exit_status.?,
                ),
                .result_resource => try testing.expectEqual(.not_owned, runtime.pending.?.code),
                else => return mistake,
            }
            break :blk workers.raised_trap;
        },
        else => return mistake,
    };

    switch (task.action) {
        .raise_error => {
            try testing.expectEqual(workers.raised_error, status);
            try testing.expectEqual(vocabulary.ErrorCode.user_error, runtime.raised.?.code);
            runtime.forget();
        },
        .trap, .exit, .result_resource => try testing.expectEqual(workers.raised_trap, status),
        else => try testing.expectEqual(workers.survived, status),
    }
    runtime.pending = null;
    runtime.exit_status = null;
    if (status == workers.survived) runtime.freeValue(answer);
    lifecycleMarkJoined(state, task);
}

fn lifecycleAudit(
    runtime: *Runtime,
    state: *const LifecycleState,
    tasks: Value,
    task_records: []const LifecycleTask,
    resources: Value,
    resource_records: []const LifecycleResource,
) !void {
    runtime.debugAssertInvariants();

    const active_tasks = lifecycleActiveTasks(task_records);
    const active_resources = lifecycleActiveResources(resource_records);
    try testing.expectEqual(@as(i64, @intCast(active_tasks)), (try containers.length(runtime, tasks)).asLong());
    try testing.expectEqual(@as(i64, @intCast(active_resources)), (try containers.length(runtime, resources)).asLong());

    var live_task_rows: usize = 0;
    var joined_task_rows: usize = 0;
    var expected_files = active_resources;
    for (task_records) |task| {
        if (!task.active) continue;
        const object = try runtime.resolve(task.handle);
        switch (object.data) {
            .task => |worker| {
                if (task.joined) {
                    try testing.expect(worker == null);
                    joined_task_rows += 1;
                } else {
                    try testing.expect(worker != null);
                    live_task_rows += 1;
                    expected_files += task.open_files;
                }
            },
            else => return error.TestExpected,
        }
    }
    for (resource_records) |resource| {
        if (!resource.active) continue;
        _ = try runtime.resolve(resource.file);
        try testing.expectEqual(value.Tag.strukt, resource.root.tag);
        try testing.expect(resource.root.asStruct().len != 0);
    }

    try testing.expectEqual(active_tasks, live_task_rows + joined_task_rows);
    try testing.expectEqual(state.spawns - state.joins, state.activeChildren());
    try testing.expectEqual(state.opens - state.closes, state.activeChildren());
    try testing.expectEqual(expected_files, state.file_opens - state.file_closes);
    try testing.expect(!state.duplicate_close);
    try testing.expect(!state.unknown_close);
    try testing.expect(!state.file_overflow);
    try testing.expectEqual(state.expected_leaks, runtime.inherited_leaks);

    // The parent has exactly two bucket rows, one row per live task, and
    // four rows per nested resource graph (array/map/list/file).
    try testing.expectEqual(
        @as(u32, @intCast(2 + active_tasks + active_resources * 4)),
        runtime.live,
    );
}

fn runLifecycleSeed(seed: u64) !void {
    var state = LifecycleState.init();
    var parent_objects: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var parent_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    var runtime: Runtime = .init(.{
        .arena = parent_arena.allocator(),
        .objects = parent_objects.allocator(),
    });
    state.install(&runtime);

    var tasks: Value = .none;
    var resources: Value = .none;
    var deinitialized = false;
    defer {
        if (!tasks.isNone()) runtime.freeValue(tasks);
        if (!resources.isNone()) runtime.freeValue(resources);
        if (!deinitialized) runtime.deinit();
        parent_arena.deinit();
    }

    tasks = try runtime.newList(Value.none);
    resources = try runtime.newList(Value.none);
    var task_records: [lifecycle_record_capacity]LifecycleTask = undefined;
    var resource_records: [lifecycle_record_capacity]LifecycleResource = undefined;
    var task_used: usize = 0;
    var resource_used: usize = 0;
    var random = OwnerGraphRng.init(seed);

    const transitions = 180;
    for (0..transitions) |_| {
        runtime.pending = null;
        switch (random.below(100)) {
            0...25 => if (task_used < lifecycle_record_capacity) {
                const action: LifecycleAction = @enumFromInt(@as(u8, @intCast(random.below(9))));
                var task: Value = .none;
                try workers.spawn(&runtime, @intFromEnum(action), &.{}, &task);
                try containers.append(&runtime, tasks, task);
                task_records[task_used] = .{
                    .handle = task,
                    .action = action,
                    .open_files = switch (action) {
                        .leak, .raise_error, .trap, .exit, .result_resource => 1,
                        else => 0,
                    },
                    .leaked_objects = switch (action) {
                        .leak, .raise_error, .trap, .exit => 5,
                        else => 0,
                    },
                };
                task_used += 1;
            },
            26...42 => if (resource_used < lifecycle_record_capacity) {
                const graph = try lifecycleGraph(&runtime, true, @intCast(resource_used));
                try containers.append(&runtime, resources, graph.root);
                resource_records[resource_used] = .{
                    .root = graph.root,
                    .file = graph.file,
                };
                resource_used += 1;
            },
            43...58 => if (lifecycleActiveTasks(task_records[0..task_used]) != 0) {
                const task = lifecycleTaskAt(
                    task_records[0..task_used],
                    random.below(lifecycleActiveTasks(task_records[0..task_used])),
                );
                try lifecycleWaitTask(&runtime, &state, task);
            },
            59...65 => if (lifecycleActiveTasks(task_records[0..task_used]) != 0) {
                const task = lifecycleTaskAt(
                    task_records[0..task_used],
                    lifecycleActiveTasks(task_records[0..task_used]) - 1,
                );
                const popped = try containers.pop(&runtime, tasks);
                try testing.expect(std.meta.eql(task.handle, popped));
                runtime.freeValue(popped);
                task.active = false;
                lifecycleMarkJoined(&state, task);
            },
            66...71 => if (lifecycleActiveTasks(task_records[0..task_used]) != 0) {
                const ordinal = random.below(lifecycleActiveTasks(task_records[0..task_used]));
                const task = lifecycleTaskAt(task_records[0..task_used], ordinal);
                try containers.remove(&runtime, tasks, Value.ofLong(@intCast(ordinal)));
                task.active = false;
                lifecycleMarkJoined(&state, task);
            },
            72...75 => {
                try containers.clear(&runtime, tasks);
                for (task_records[0..task_used]) |*task| {
                    if (!task.active) continue;
                    task.active = false;
                    lifecycleMarkJoined(&state, task);
                }
            },
            76...83 => if (lifecycleActiveResources(resource_records[0..resource_used]) != 0) {
                const resource = lifecycleResourceAt(
                    resource_records[0..resource_used],
                    lifecycleActiveResources(resource_records[0..resource_used]) - 1,
                );
                const popped = try containers.pop(&runtime, resources);
                try testing.expect(std.meta.eql(resource.root, popped));
                runtime.freeValue(popped);
                resource.active = false;
                try expectTrap(.use_after_free, &runtime, runtime.resolve(resource.file));
                runtime.pending = null;
            },
            84...89 => if (lifecycleActiveResources(resource_records[0..resource_used]) != 0) {
                const ordinal = random.below(lifecycleActiveResources(resource_records[0..resource_used]));
                const resource = lifecycleResourceAt(resource_records[0..resource_used], ordinal);
                try containers.remove(&runtime, resources, Value.ofLong(@intCast(ordinal)));
                resource.active = false;
                try expectTrap(.use_after_free, &runtime, runtime.resolve(resource.file));
                runtime.pending = null;
            },
            else => {
                try containers.clear(&runtime, resources);
                for (resource_records[0..resource_used]) |*resource| resource.active = false;
            },
        }

        try lifecycleAudit(
            &runtime,
            &state,
            tasks,
            task_records[0..task_used],
            resources,
            resource_records[0..resource_used],
        );
    }

    // Closing the two buckets exercises the same release path as scope
    // exit, including joins for every task not explicitly waited above.
    try containers.clear(&runtime, tasks);
    for (task_records[0..task_used]) |*task| {
        if (!task.active) continue;
        task.active = false;
        lifecycleMarkJoined(&state, task);
    }
    try containers.clear(&runtime, resources);
    for (resource_records[0..resource_used]) |*resource| resource.active = false;
    try lifecycleAudit(
        &runtime,
        &state,
        tasks,
        task_records[0..task_used],
        resources,
        resource_records[0..resource_used],
    );

    runtime.freeValue(tasks);
    tasks = .none;
    runtime.freeValue(resources);
    resources = .none;
    try testing.expectEqual(@as(u32, 0), runtime.live);
    try testing.expectEqual(runtime.inherited_leaks, runtime.leaked());
    try testing.expectEqual(@as(usize, 0), state.activeChildren());
    try testing.expectEqual(state.spawns, state.joins);
    try testing.expectEqual(state.opens, state.closes);
    try testing.expectEqual(state.file_opens, state.file_closes);
    try testing.expect(!state.duplicate_close);
    try testing.expect(!state.unknown_close);
    try testing.expect(!state.file_overflow);

    runtime.deinit();
    deinitialized = true;
    try testing.expectEqual(parent_objects.allocated_bytes, parent_objects.freed_bytes);
}

fn expectWorkerAcquisitionFailures() !usize {
    var failures: usize = 0;
    for (0..32) |failure_offset| {
        var parent_objects: std.testing.FailingAllocator = .init(testing.allocator, .{});
        var parent_arena: std.heap.ArenaAllocator = .init(testing.allocator);
        var parent: Runtime = .init(.{
            .arena = parent_arena.allocator(),
            .objects = parent_objects.allocator(),
        });

        var child_arena: std.heap.ArenaAllocator = .init(testing.allocator);
        var child: Runtime = .init(.{
            .arena = child_arena.allocator(),
            .objects = testing.allocator,
        });
        var state: WorkerFailureState = .{
            .child = &child,
            .child_live_at_close = std.math.maxInt(u32),
        };
        state.install(&parent);
        parent_objects.fail_index = parent_objects.alloc_index + failure_offset;

        var task: Value = .none;
        const outcome = workers.spawn(&parent, 0, &.{}, &task);
        var completed = false;
        if (outcome) |_| {
            completed = true;
            try testing.expect(!task.isNone());
            parent.freeValue(task);
        } else |mistake| {
            failures += 1;
            try testing.expectEqual(error.OutOfMemory, mistake);
            try testing.expect(task.isNone());
            try testing.expect(state.spawns == 0 or state.spawns == 1);
        }

        try testing.expectEqual(@as(u32, 0), parent.live);
        if (state.closes == 0) child.deinit();
        const induced = parent_objects.has_induced_failure;
        parent.deinit();
        parent_arena.deinit();
        child_arena.deinit();

        try testing.expectEqual(parent_objects.allocated_bytes, parent_objects.freed_bytes);
        try testing.expectEqual(@as(usize, state.closes), state.joins);
        if (state.closes != 0) try testing.expectEqual(@as(u32, 0), state.child_live_at_close);
        if (completed) return failures;
        try testing.expect(induced);
    }
    return error.WorkerAcquisitionNeverCompleted;
}

fn expectLifecycleResourceFailures() !usize {
    var failures: usize = 0;
    for (0..64) |failure_offset| {
        var state = LifecycleState.init();
        var objects: std.testing.FailingAllocator = .init(testing.allocator, .{});
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        var runtime: Runtime = .init(.{
            .arena = arena.allocator(),
            .objects = objects.allocator(),
        });
        state.install(&runtime);
        objects.fail_index = objects.alloc_index + failure_offset;

        const outcome = lifecycleGraph(&runtime, true, @intCast(failure_offset));
        var completed = false;
        if (outcome) |graph| {
            runtime.freeValue(graph.root);
            completed = true;
        } else |mistake| {
            failures += 1;
            if (mistake == error.Trap) {
                try testing.expectEqual(
                    vocabulary.TrapCode.allocation_failed,
                    runtime.pending.?.code,
                );
                runtime.pending = null;
            } else {
                try testing.expectEqual(error.OutOfMemory, mistake);
                try testing.expect(runtime.pending == null);
            }
        }

        try testing.expectEqual(@as(u32, 0), runtime.live);
        try testing.expectEqual(state.file_opens, state.file_closes);
        try testing.expect(!state.duplicate_close);
        try testing.expect(!state.unknown_close);
        const induced = objects.has_induced_failure;
        runtime.deinit();
        arena.deinit();
        try testing.expectEqual(objects.allocated_bytes, objects.freed_bytes);
        if (completed) return failures;
        try testing.expect(induced);
    }
    return error.LifecycleResourceNeverCompleted;
}

test "worker acquisition failures roll every parent allocation back" {
    try testing.expect((try expectWorkerAcquisitionFailures()) >= 2);
}

test "nested resource graph failures close every acquired file" {
    try testing.expect((try expectLifecycleResourceFailures()) >= 5);
}

test "fixed worker and resource lifecycle seeds preserve joins and closes" {
    for ([_]u64{
        0x0B_0700_0001,
        0x0B_0700_0021,
        0x0B_0700_00A5,
        0x0B_0700_F00D,
    }) |seed| try runLifecycleSeed(seed);
}

test "fuzz: worker and resource lifecycles preserve ownership" {
    try testing.fuzz({}, fuzzLifecycle, .{ .corpus = &.{
        "worker resource lifecycle seed",
        "\x00\x01\x02\x03\x04\x05",
        "\xff\x00\x13\x37\xa5\x5a",
    } });
}

fn fuzzLifecycle(_: void, smith: *testing.Smith) !void {
    var bytes: [24]u8 = undefined;
    const length = smith.sliceWeightedBytes(&bytes, &.{
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .value(u8, 0x00, 3),
        .value(u8, 0xff, 3),
        .value(u8, '\n', 2),
    });

    var seed: u64 = 0xD1CE_BAAD_51A7_0001;
    for (bytes[0..length], 0..) |byte, at| {
        seed = seed *% 6_364_136_223_846_793_005 +%
            (@as(u64, byte) +% @as(u64, at) +% 1);
        seed ^= seed >> 31;
    }
    try runLifecycleSeed(seed);
}

fn expectWorkerGraphFailures() !usize {
    var failures: usize = 0;
    for (0..32) |failure_offset| {
        var parent_arena: std.heap.ArenaAllocator = .init(testing.allocator);
        var parent: Runtime = .init(.{
            .arena = parent_arena.allocator(),
            .objects = testing.allocator,
        });
        var child_objects: std.testing.FailingAllocator = .init(testing.allocator, .{});
        var child_arena: std.heap.ArenaAllocator = .init(testing.allocator);
        var child: Runtime = .init(.{
            .arena = child_arena.allocator(),
            .objects = child_objects.allocator(),
        });
        var state: WorkerFailureState = .{
            .child = &child,
            .produce_graph = true,
            .child_live_at_close = std.math.maxInt(u32),
        };
        state.install(&parent);
        child_objects.fail_index = child_objects.alloc_index + failure_offset;

        var task: Value = .none;
        try workers.spawn(&parent, 0, &.{}, &task);
        var answer: Value = .none;
        const outcome = workers.wait(&parent, task, &answer);
        var completed = false;
        if (outcome) |status| {
            try testing.expectEqual(workers.survived, status);
            try testing.expect(state.ran);
            parent.freeValue(answer);
            completed = true;
        } else |mistake| {
            failures += 1;
            try testing.expectEqual(error.OutOfMemory, mistake);
            try testing.expect(answer.isNone());
        }
        try testing.expectEqual(@as(usize, 1), state.joins);
        try testing.expectEqual(@as(usize, 1), state.closes);
        try testing.expectEqual(@as(u32, 0), state.child_live_at_close);

        // wait consumes the worker but leaves the task row for its owner.
        parent.freeValue(task);
        try testing.expectEqual(@as(u32, 0), parent.live);
        const induced = child_objects.has_induced_failure;
        parent.deinit();
        parent_arena.deinit();
        child_arena.deinit();
        try testing.expectEqual(child_objects.allocated_bytes, child_objects.freed_bytes);
        if (completed) return failures;
        try testing.expect(induced);
    }
    return error.WorkerGraphNeverCompleted;
}

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

test "a forged handle using a freed row generation still traps" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const released = try runtime.newList(Value.none);
    const index = released.asObject().index;
    runtime.freeObject(released.asObject());
    const forged = Value.ofObject(.{
        .index = index,
        .generation = runtime.table.items[index].generation,
    });

    // Generation equality alone is not enough: the current generation of a
    // free row is deliberately representable to a damaged artifact. The
    // occupancy bit must reject it before an empty row can be read or freed.
    try expectTrap(.use_after_free, runtime, runtime.resolve(forged));
    runtime.pending = null;
    runtime.freeObject(forged.asObject());
    try testing.expectEqual(@as(u32, 0), runtime.live);
    runtime.debugAssertInvariants();

    const replacement = try runtime.newList(Value.none);
    try testing.expect((replacement.asObject().generation & 1) == 0);
    runtime.freeValue(replacement);
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

test "stale handles reject every container operation after row reuse" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const stale_list = try runtime.newList(Value.none);
    runtime.freeObject(stale_list.asObject());
    const live_list = try runtime.newList(Value.none);
    try expectStale(runtime, containers.length(runtime, stale_list));
    try expectStale(runtime, containers.indexGet(runtime, stale_list, &.{Value.ofLong(0)}));
    try expectStale(
        runtime,
        containers.indexSet(runtime, stale_list, &.{Value.ofLong(0)}, Value.none),
    );
    try expectStale(runtime, containers.append(runtime, stale_list, Value.none));
    try expectStale(runtime, containers.insert(runtime, stale_list, 0, Value.none));
    try expectStale(runtime, containers.pop(runtime, stale_list));
    try expectStale(runtime, containers.remove(runtime, stale_list, Value.ofLong(0)));
    try expectStale(runtime, containers.clear(runtime, stale_list));
    try expectStale(runtime, containers.sort(runtime, stale_list));
    try expectStale(runtime, containers.reverse(runtime, stale_list));
    try expectStale(runtime, containers.listSlice(runtime, stale_list, 0, 0));
    try expectStale(runtime, runtime.deepCopy(stale_list));
    try expectStale(runtime, runtime.checkGivable(stale_list, null));
    runtime.freeValue(stale_list);
    runtime.freeValue(live_list);

    const stale_map = try runtime.newMap();
    runtime.freeObject(stale_map.asObject());
    const live_map = try runtime.newMap();
    try expectStale(runtime, containers.length(runtime, stale_map));
    try expectStale(runtime, containers.indexGet(runtime, stale_map, &.{Value.ofString("k")}));
    try expectStale(
        runtime,
        containers.indexSet(runtime, stale_map, &.{Value.ofString("k")}, Value.ofLong(1)),
    );
    try expectStale(runtime, containers.remove(runtime, stale_map, Value.ofString("k")));
    try expectStale(runtime, containers.clear(runtime, stale_map));
    try expectStale(runtime, containers.mapKeys(runtime, stale_map, Value.ofString("")));
    try expectStale(runtime, containers.mapValues(runtime, stale_map, Value.none));
    try expectStale(
        runtime,
        containers.mapPlace(runtime, stale_map, Value.ofString("k"), Value.ofLong(0)),
    );
    try expectStale(runtime, runtime.deepCopy(stale_map));
    try expectStale(runtime, runtime.checkGivable(stale_map, null));
    runtime.freeValue(stale_map);
    runtime.freeValue(live_map);

    const stale_array = try runtime.newArray(&.{2}, Value.none);
    runtime.freeObject(stale_array.asObject());
    const live_array = try runtime.newArray(&.{2}, Value.none);
    try expectStale(runtime, containers.length(runtime, stale_array));
    try expectStale(runtime, containers.dimSize(runtime, stale_array, 0));
    try expectStale(runtime, containers.indexGet(runtime, stale_array, &.{Value.ofLong(0)}));
    try expectStale(
        runtime,
        containers.indexSet(runtime, stale_array, &.{Value.ofLong(0)}, Value.none),
    );
    try expectStale(runtime, containers.arrayFill(runtime, stale_array, Value.none));
    try expectStale(runtime, containers.listSlice(runtime, stale_array, 0, 0));
    try expectStale(runtime, runtime.deepCopy(stale_array));
    try expectStale(runtime, runtime.checkGivable(stale_array, null));
    runtime.freeValue(stale_array);
    runtime.freeValue(live_array);

    const stale_builder = try runtime.newBuilder();
    runtime.freeObject(stale_builder.asObject());
    const live_builder = try runtime.newBuilder();
    try expectStale(runtime, containers.length(runtime, stale_builder));
    try expectStale(runtime, containers.append(runtime, stale_builder, Value.ofString("x")));
    try expectStale(runtime, containers.appendAscii(runtime, stale_builder, 'x'));
    try expectStale(runtime, containers.clear(runtime, stale_builder));
    try expectStale(runtime, runtime.deepCopy(stale_builder));
    try expectStale(runtime, runtime.checkGivable(stale_builder, null));
    runtime.freeValue(stale_builder);
    runtime.freeValue(live_builder);
    try testing.expectEqual(@as(u32, 0), runtime.live);
}

test "stale file operations trap before touching the host" {
    const Host = struct {
        reads: usize = 0,
        writes: usize = 0,
        flushes: usize = 0,
        closes: usize = 0,

        fn read(
            context: ?*anyopaque,
            _: i64,
            _: [*]u8,
            _: i64,
            filled: *i64,
        ) callconv(.c) i32 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.reads += 1;
            filled.* = 0;
            return files.yes;
        }

        fn write(
            context: ?*anyopaque,
            _: i64,
            _: [*]const u8,
            _: i64,
            written: *i64,
        ) callconv(.c) i32 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.writes += 1;
            written.* = 0;
            return files.yes;
        }

        fn flush(context: ?*anyopaque, _: i64) callconv(.c) i32 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.flushes += 1;
            return files.yes;
        }

        fn close(context: ?*anyopaque, _: i64) callconv(.c) i32 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.closes += 1;
            return files.yes;
        }
    };

    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;
    var host: Host = .{};
    runtime.files = .{
        .context = &host,
        .read = Host.read,
        .write = Host.write,
        .flush = Host.flush,
        .close = Host.close,
    };

    const stale = try runtime.newFile(17, "stale.bin");
    const bytes = try runtime.newArray(&.{4}, Value.ofByte(0));
    runtime.freeObject(stale.asObject());
    const replacement = try runtime.newFile(29, "replacement.bin");
    try testing.expect(!stale.asObject().same(replacement.asObject()));

    try expectStale(runtime, files.read(runtime, stale, bytes));
    try expectStale(runtime, files.write(runtime, stale, bytes, 0));
    try expectStale(runtime, files.flush(runtime, stale));
    try expectStale(runtime, runtime.deepCopy(stale));
    try expectStale(runtime, runtime.checkGivable(stale, null));
    try testing.expectEqualStrings("", files.pathOf(runtime, stale));
    runtime.freeValue(stale);
    runtime.freeValue(replacement);
    runtime.freeValue(bytes);

    try testing.expectEqual(@as(usize, 0), host.reads);
    try testing.expectEqual(@as(usize, 0), host.writes);
    try testing.expectEqual(@as(usize, 0), host.flushes);
    try testing.expectEqual(@as(usize, 2), host.closes);
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

test "nested resource graphs close once and stale handles stay stale" {
    const Host = struct {
        closed: [3]i64 = undefined,
        count: usize = 0,

        fn close(context: ?*anyopaque, handle: i64) callconv(.c) i32 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.closed[self.count] = handle;
            self.count += 1;
            return files.yes;
        }
    };

    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;
    var host: Host = .{};
    runtime.files = .{ .context = &host, .close = Host.close };

    const file = try runtime.newFile(17, "nested-input.bin");
    const record = try runtime.makeStruct(&.{file});
    const packet = try runtime.newList(Value.none);
    try containers.append(runtime, packet, record);

    // A copy would create a second owner of the host handle.  Rejection
    // must leave the original graph and its one close edge untouched.
    try expectTrap(.not_owned, runtime, runtime.deepCopy(packet));
    try testing.expectEqual(@as(i64, 1), (try containers.length(runtime, packet)).asLong());
    try testing.expectEqual(@as(u32, 2), runtime.live);

    runtime.freeValue(packet);
    try testing.expectEqual(@as(usize, 1), host.count);
    try testing.expectEqual(@as(i64, 17), host.closed[0]);
    try testing.expectEqual(@as(u32, 0), runtime.live);
    try expectTrap(.use_after_free, runtime, runtime.resolve(file));

    // Reusing the row must not make the old file handle name the new one.
    const replacement = try runtime.newFile(29, "replacement.bin");
    try testing.expect(!file.asObject().same(replacement.asObject()));
    try expectTrap(.use_after_free, runtime, runtime.resolve(file));
    runtime.freeValue(replacement);
    try testing.expectEqual(@as(usize, 2), host.count);
    try testing.expectEqual(@as(i64, 29), host.closed[1]);
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

test "scope release uses a worklist for a deep object graph" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const root = try runtime.newList(Value.none);
    var current = root;
    // This is deliberately deeper than a typical native stack can safely
    // recurse through.  The language's object graph is user data, so its
    // depth must not be bounded by the host call stack.
    for (0..40_000) |_| {
        const child = try runtime.newList(Value.none);
        try containers.append(runtime, current, child);
        current = child;
    }

    runtime.freeValue(root);
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

test "fixed owner-graph seeds keep one owner through hostile transitions" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();

    // These seeds are intentionally stable corpus entries rather than a
    // time-based fuzz source.  Each run builds and tears down a fresh forest
    // on the same runtime, so row generations are exercised across seeds as
    // well as within each sequence.
    for ([_]u64{
        0x0A_0300_0001,
        0x0A_0300_0002,
        0x0A_0300_00A5,
        0x0A_0300_F00D,
    }) |seed| {
        try runOwnerGraphSeed(&bench.runtime, seed);
        try testing.expectEqual(@as(u32, 0), bench.runtime.live);
    }
}

// The fixed corpus above is the readable regression set.  This target makes
// the same reference model a coverage-guided property: the fuzzer mutates a
// byte trace into a seed, and every seed still has to preserve exact owner
// edges, stale generations, and zero-live teardown.  Keeping the generator
// deterministic is important here; a failing seed can be copied directly
// into the fixed corpus without depending on a process-global random source.
test "fuzz: owner graphs preserve one owner through arbitrary traces" {
    try testing.fuzz({}, fuzzOwnerGraph, .{ .corpus = &.{
        "owner graph list/map/array seed",
        "\x00\x00\x00\x01\xA5\x5A\xF0\x0D",
        "\xFF\xFF\xFF\xFF\x00\x13\x37\x42",
    } });
}

fn fuzzOwnerGraph(_: void, smith: *testing.Smith) !void {
    var bytes: [32]u8 = undefined;
    const length = smith.sliceWeightedBytes(&bytes, &.{
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .value(u8, 0x00, 3),
        .value(u8, 0xff, 3),
        .value(u8, '\n', 2),
    });

    // A small mixing step prevents short inputs from exercising only the
    // low bits of the LCG while retaining a one-number replay contract.
    var seed: u64 = 0x9E37_79B9_7F4A_7C15;
    for (bytes[0..length], 0..) |byte, at| {
        seed = seed *% 6_364_136_223_846_793_005 +%
            (@as(u64, byte) +% @as(u64, at) +% 1);
        seed ^= seed >> 29;
    }

    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    try runOwnerGraphSeed(&bench.runtime, seed);
    try testing.expectEqual(@as(u32, 0), bench.runtime.live);
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

test "deep copy uses a worklist for a deep object graph" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const root = try runtime.newList(Value.none);
    var current = root;
    for (0..40_000) |_| {
        const child = try runtime.newList(Value.none);
        try containers.append(runtime, current, child);
        current = child;
    }

    const duplicate = try runtime.deepCopy(root);
    try testing.expectEqual(@as(u32, 80_002), runtime.live);
    runtime.freeValue(duplicate);
    runtime.freeValue(root);
    try testing.expectEqual(@as(u32, 0), runtime.live);
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

test "list growth keeps every raw capacity on an element boundary" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    // The geometric step used to add `grown / 2` before the element
    // width, which can make a later capacity (for example 164 bytes for
    // an eight-byte cell) impossible to divide into cells.  Exercise
    // packed and boxed widths through several such steps and inspect the
    // storage contract directly.
    for ([_]Value{
        Value.ofLong(0),
        Value.ofShort(0),
        Value.ofByte(0),
        Value.none,
    }) |zero| {
        const list = try runtime.newList(zero);
        for (0..96) |_| try containers.append(runtime, list, zero);
        const object = try runtime.resolve(list);
        try testing.expectEqual(@as(usize, 0), object.elements.bytes.len % object.elements.kind.width());
        try testing.expectEqual(@as(usize, 96), object.elements.count);
        runtime.freeValue(list);
    }
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

test "failed union and optional-shaped copies preserve every source field" {
    for ([_]bool{ false, true }) |optional_present| {
        var bench: Bench = undefined;
        bench.setup();
        defer bench.deinit();
        const source = try nestedUnionOptionalSource(&bench.runtime, optional_present);
        defer bench.runtime.freeValue(source);

        try testing.checkAllAllocationFailures(
            testing.allocator,
            copyUnionOptionalWithAllocator,
            .{ &bench.runtime, source, optional_present },
        );
        bench.runtime.debugAssertInvariants();
        try expectUnionOptionalSourceIntact(&bench.runtime, source, optional_present);
    }
}

test "inout replacement failures preserve the bound union and optional receiver" {
    for ([_]bool{ false, true }) |optional_present| {
        var objects: std.testing.FailingAllocator = .init(testing.allocator, .{});
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        var runtime: Runtime = .init(.{
            .arena = arena.allocator(),
            .objects = objects.allocator(),
        });
        var receiver: Value = .none;
        var serial: u64 = 0;
        const local: u32 = 0;
        var receiver_owned = false;
        var cleaned = false;
        defer {
            if (!cleaned) {
                if (receiver_owned) {
                    runtime.unbind(receiver, serial, local);
                    runtime.dropStorage(receiver);
                }
                runtime.deinit();
                arena.deinit();
            }
        }

        receiver = try nestedUnionOptionalSource(&runtime, optional_present);
        receiver_owned = true;
        serial = runtime.takeSerial();
        runtime.bind(receiver, serial, local);
        const baseline_live = runtime.live;
        const baseline_bytes = objects.allocated_bytes - objects.freed_bytes;
        runtime.debugAssertInvariants();
        try expectUnionOptionalSourceIntact(&runtime, receiver, optional_present);
        try expectBindingRoots(&runtime, receiver, serial, local);

        var failures: usize = 0;
        var completed = false;
        for (0..128) |failure_offset| {
            objects.fail_index = objects.alloc_index + failure_offset;
            const replacement = nestedUnionOptionalSource(&runtime, optional_present);
            objects.fail_index = std.math.maxInt(usize);

            if (replacement) |fresh| {
                // This is the inout write-back sequence: only after the
                // replacement exists may the caller's old receiver be
                // released and the new graph be bound to that same slot.
                runtime.unbind(receiver, serial, local);
                runtime.dropStorage(receiver);
                receiver_owned = false;
                receiver = fresh;
                receiver_owned = true;
                runtime.bind(fresh, serial, local);
                try expectUnionOptionalSourceIntact(&runtime, fresh, optional_present);
                try expectBindingRoots(&runtime, fresh, serial, local);
                runtime.debugAssertInvariants();
                runtime.unbind(fresh, serial, local);
                runtime.dropStorage(fresh);
                receiver_owned = false;
                runtime.debugAssertInvariants();
                try testing.expectEqual(@as(u32, 0), runtime.live);
                completed = true;
                break;
            } else |mistake| {
                failures += 1;
                if (mistake == error.Trap) {
                    try testing.expect(runtime.pending != null);
                    try testing.expectEqual(
                        vocabulary.TrapCode.allocation_failed,
                        runtime.pending.?.code,
                    );
                    runtime.pending = null;
                } else {
                    try testing.expectEqual(error.OutOfMemory, mistake);
                }
                try testing.expect(objects.has_induced_failure);
                try testing.expectEqual(baseline_live, runtime.live);
                // A failed nested construction may retain a larger
                // reusable table capacity; it must never give back bytes
                // that belong to the still-bound receiver.  Full teardown
                // below checks that the retained capacity is reclaimable.
                try testing.expect(
                    objects.allocated_bytes - objects.freed_bytes >= baseline_bytes,
                );
                try testing.expect(runtime.pending == null);
                runtime.debugAssertInvariants();
                try expectUnionOptionalSourceIntact(&runtime, receiver, optional_present);
                try expectBindingRoots(&runtime, receiver, serial, local);
            }
        }
        try testing.expect(completed);
        try testing.expect(failures >= 4);
        runtime.deinit();
        arena.deinit();
        cleaned = true;
        try testing.expectEqual(objects.allocated_bytes, objects.freed_bytes);
    }
}

test "failed retaining stores consume accepted objects without damaging rejected aliases" {
    for ([_]RetainingDoor{ .append, .insert, .map_index_set }) |door| {
        try expectRetainingDoorFailure(door);
    }

    // The ownership proof is deliberately before the release arm: a
    // container-owned alias must remain attached when the backstop refuses
    // it, and a self-adoption must leave its target untouched.  These are
    // the two failures that make an unconditional `freeValue(held)` just as
    // wrong as the old storage-only cleanup.
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const target = try runtime.newList(Value.none);
    const child = try runtime.newList(Value.none);
    try containers.append(runtime, target, child);
    try expectTrap(.not_owned, runtime, containers.append(runtime, target, child));
    runtime.pending = null;
    try testing.expectEqual(@as(i64, 1), (try containers.length(runtime, target)).asLong());
    _ = try runtime.resolve(child);

    try expectTrap(.ownership_cycle, runtime, containers.append(runtime, target, target));
    runtime.pending = null;
    try testing.expectEqual(@as(i64, 1), (try containers.length(runtime, target)).asLong());
    _ = try runtime.resolve(target);
}

test "map place rolls every key value and entry allocation back" {
    const long_key = "a map key that must be copied before it can be retained";
    const long_zero = "a map zero that must be copied before it can be retained";
    var failures: usize = 0;
    var completed = false;

    // The map starts empty, so the first fresh-key path exercises the key
    // copy, the value copy, the hash index, and the entry array in order.
    // Walk beyond the implementation's current allocation count as well:
    // the test proves success after every real refusal rather than baking
    // an allocation-count assumption into the contract.
    for (0..16) |failure_offset| {
        var objects: std.testing.FailingAllocator = .init(testing.allocator, .{});
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        var runtime: Runtime = .init(.{
            .arena = arena.allocator(),
            .objects = objects.allocator(),
        });

        const map = try runtime.newMap();
        const baseline_live = runtime.live;
        objects.fail_index = objects.alloc_index + failure_offset;
        const outcome = containers.mapPlace(
            &runtime,
            map,
            Value.ofString(long_key),
            Value.ofString(long_zero),
        );
        objects.fail_index = std.math.maxInt(usize);

        if (outcome) |placed| {
            try testing.expect(placed.tag == .string);
            try testing.expectEqualStrings(long_zero, placed.asString());
            try testing.expectEqual(@as(i64, 1), (try containers.length(&runtime, map)).asLong());
            try testing.expectEqual(baseline_live, runtime.live);
            completed = true;
            runtime.freeValue(map);
        } else |mistake| {
            try testing.expectEqual(error.OutOfMemory, mistake);
            try testing.expect(objects.has_induced_failure);
            try testing.expectEqual(baseline_live, runtime.live);
            try testing.expectEqual(@as(i64, 0), (try containers.length(&runtime, map)).asLong());
            failures += 1;
            runtime.freeValue(map);
        }

        try testing.expectEqual(@as(u32, 0), runtime.live);
        runtime.deinit();
        arena.deinit();
        try testing.expectEqual(objects.allocated_bytes, objects.freed_bytes);
        if (completed) break;
    }

    try testing.expect(completed);
    try testing.expect(failures >= 3);
}

test "builder growth and snapshots preserve bytes through allocation failure" {
    const long_text = "builder bytes long enough to force a replacement allocation" ++
        "builder bytes long enough to force a replacement allocation" ++
        "builder bytes long enough to force a replacement allocation" ++
        "builder bytes long enough to force a replacement allocation";

    var growth_failures: usize = 0;
    var growth_completed = false;
    for (0..8) |failure_offset| {
        var objects: std.testing.FailingAllocator = .init(testing.allocator, .{});
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        var runtime: Runtime = .init(.{
            .arena = arena.allocator(),
            .objects = objects.allocator(),
        });
        const builder = try runtime.newBuilder();
        try containers.append(&runtime, builder, Value.ofString("seed"));
        objects.fail_index = objects.alloc_index + failure_offset;

        const outcome = containers.append(&runtime, builder, Value.ofString(long_text));
        objects.fail_index = std.math.maxInt(usize);
        if (outcome) |_| {
            const object = try runtime.resolve(builder);
            try testing.expectEqualStrings("seed" ++ long_text, object.data.builder.items);
            growth_completed = true;
            runtime.freeValue(builder);
        } else |mistake| {
            try testing.expectEqual(error.OutOfMemory, mistake);
            const object = try runtime.resolve(builder);
            try testing.expectEqualStrings("seed", object.data.builder.items);
            growth_failures += 1;
            runtime.freeValue(builder);
        }
        try testing.expectEqual(@as(u32, 0), runtime.live);
        runtime.deinit();
        arena.deinit();
        try testing.expectEqual(objects.allocated_bytes, objects.freed_bytes);
        if (growth_completed) break;
    }
    try testing.expect(growth_completed);
    try testing.expect(growth_failures >= 1);

    var snapshot_failures: usize = 0;
    var snapshot_completed = false;
    for (0..8) |failure_offset| {
        var objects: std.testing.FailingAllocator = .init(testing.allocator, .{});
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        var runtime: Runtime = .init(.{
            .arena = arena.allocator(),
            .objects = objects.allocator(),
        });
        const builder = try runtime.newBuilder();
        try containers.append(&runtime, builder, Value.ofString(long_text));
        objects.fail_index = objects.alloc_index + failure_offset;

        const outcome = text.str(&runtime, builder);
        objects.fail_index = std.math.maxInt(usize);
        if (outcome) |snapshot| {
            try testing.expectEqualStrings(long_text, snapshot.asString());
            runtime.dropStorage(snapshot);
            snapshot_completed = true;
        } else |mistake| {
            try testing.expectEqual(error.OutOfMemory, mistake);
            const object = try runtime.resolve(builder);
            try testing.expectEqualStrings(long_text, object.data.builder.items);
            snapshot_failures += 1;
        }
        runtime.freeValue(builder);
        try testing.expectEqual(@as(u32, 0), runtime.live);
        runtime.deinit();
        arena.deinit();
        try testing.expectEqual(objects.allocated_bytes, objects.freed_bytes);
        if (snapshot_completed) break;
    }
    try testing.expect(snapshot_completed);
    try testing.expect(snapshot_failures >= 1);
}

test "runtime index and struct doors reject malformed rank without touching ownership" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const list = try runtime.newList(Value.none);
    try containers.append(runtime, list, Value.ofLong(7));
    try expectTrap(.index_bounds, runtime, containers.indexGet(runtime, list, &.{}));
    runtime.pending = null;
    try expectTrap(
        .index_bounds,
        runtime,
        containers.indexGet(runtime, list, &.{ Value.ofLong(0), Value.ofLong(1) }),
    );
    runtime.pending = null;
    try expectTrap(
        .index_bounds,
        runtime,
        containers.indexSet(runtime, list, &.{}, Value.ofLong(8)),
    );
    runtime.pending = null;
    try testing.expectEqual(@as(i64, 7), (try containers.indexGet(
        runtime,
        list,
        &.{Value.ofLong(0)},
    )).asLong());

    const map = try runtime.newMap();
    try expectTrap(.index_bounds, runtime, containers.indexGet(runtime, map, &.{}));
    runtime.pending = null;
    try expectTrap(
        .index_bounds,
        runtime,
        containers.indexSet(
            runtime,
            map,
            &.{ Value.ofString("a"), Value.ofString("b") },
            Value.ofLong(1),
        ),
    );
    runtime.pending = null;
    try testing.expectEqual(@as(i64, 0), (try containers.length(runtime, map)).asLong());

    const grid = try runtime.newArray(&.{ 2, 2 }, Value.ofLong(0));
    try expectTrap(
        .index_bounds,
        runtime,
        containers.indexGet(runtime, grid, &.{Value.ofLong(0)}),
    );
    runtime.pending = null;
    try expectTrap(
        .index_bounds,
        runtime,
        containers.indexSet(
            runtime,
            grid,
            &.{ Value.ofLong(0), Value.ofLong(0), Value.ofLong(0) },
            Value.ofLong(1),
        ),
    );
    runtime.pending = null;
    try testing.expectEqual(
        @as(i64, 0),
        (try containers.indexGet(runtime, grid, &.{ Value.ofLong(0), Value.ofLong(0) })).asLong(),
    );
    try testing.expectEqual(
        @as(?usize, null),
        heap.flattenIndex(
            &.{ std.math.maxInt(i64), std.math.maxInt(i64), std.math.maxInt(i64) },
            &.{ Value.ofLong(1), Value.ofLong(1), Value.ofLong(1) },
        ),
    );
    try testing.expectEqual(
        @as(?usize, null),
        heap.flattenIndex(&.{-1}, &.{Value.ofLong(0)}),
    );
    // Every axis of a multidimensional store is a long.  The runtime must
    // reject a forged later index before flattenIndex reads its payload, and
    // the rejected store must leave the destination untouched.
    try expectTrap(
        .not_owned,
        runtime,
        containers.indexSet(
            runtime,
            grid,
            &.{ Value.ofLong(0), Value.ofBoolean(true) },
            Value.ofLong(9),
        ),
    );
    runtime.pending = null;
    try testing.expectEqual(
        @as(i64, 0),
        (try containers.indexGet(runtime, grid, &.{ Value.ofLong(0), Value.ofLong(0) })).asLong(),
    );

    const child = try runtime.newList(Value.none);
    const record = try runtime.makeStruct(&.{child});
    const replacement = try runtime.newList(Value.none);
    const baseline_live = runtime.live;
    try expectTrap(.index_bounds, runtime, runtime.setField(record, 1, replacement));
    runtime.pending = null;
    try testing.expectEqual(baseline_live, runtime.live);
    try testing.expectEqual(@as(usize, 1), record.asStruct().len);
    try testing.expect(record.asStruct()[0].asObject().same(child.asObject()));
    _ = try runtime.resolve(replacement);

    // The C door must reject a negative field before converting it to usize,
    // and must leave its out slot untouched on the trapped call.
    var out = Value.ofLong(99);
    try testing.expectEqual(
        @as(i32, 1),
        luce_rt_struct_set(runtime, &record, -1, &Value.ofLong(3), &out),
    );
    try testing.expectEqual(@as(i64, 99), out.asLong());
    try testing.expectEqual(vocabulary.TrapCode.index_bounds, runtime.pending.?.code);
    runtime.pending = null;

    runtime.freeValue(replacement);
    runtime.freeValue(record);
    runtime.freeValue(map);
    runtime.freeValue(grid);
    runtime.freeValue(list);
    try testing.expectEqual(@as(u32, 0), runtime.live);
}

test "rank-zero arrays are rejected before allocation" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    // A source array always has at least one axis.  The direct runtime door
    // must reject a forged zero-rank shape before it allocates the one
    // otherwise-unreachable element cell.
    try expectTrap(.index_bounds, runtime, runtime.newArray(&.{}, Value.none));
    runtime.pending = null;
    try testing.expectEqual(@as(u32, 0), runtime.live);

    // The exported C constructor has to preserve its destination too.  The
    // dimension pointer is deliberately non-null here so this isolates the
    // malformed rank from the separate null-pointer contract.
    const dimensions = [_]i64{7};
    var out = Value.ofLong(99);
    try testing.expectEqual(
        @as(i32, 1),
        luce_rt_new_array(runtime, &dimensions, 0, &Value.none, &out),
    );
    try testing.expectEqual(@as(i64, 99), out.asLong());
    try testing.expectEqual(vocabulary.TrapCode.index_bounds, runtime.pending.?.code);
    runtime.pending = null;
    runtime.debugAssertInvariants();
    try testing.expectEqual(@as(u32, 0), runtime.live);
}

test "failed function-value copies return every nested storage allocation" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();

    const label = try bench.runtime.ownValue(Value.ofString(
        "a receiver string that must be duplicated with the function run",
    ));
    const receiver = try bench.runtime.makeStruct(&.{label});
    const function = try bench.runtime.makeFunction(&.{ Value.ofLong(7), receiver });
    defer bench.runtime.dropStorage(function);

    try testing.checkAllAllocationFailures(
        testing.allocator,
        copyFunctionWithAllocator,
        .{function},
    );
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

test "failed struct construction releases objects but function runs keep receivers borrowed" {
    var struct_objects: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var struct_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    var struct_runtime: Runtime = .init(.{
        .arena = struct_arena.allocator(),
        .objects = struct_objects.allocator(),
    });
    const child = try struct_runtime.newList(Value.none);
    struct_objects.fail_index = struct_objects.alloc_index;

    try testing.expectError(
        error.OutOfMemory,
        struct_runtime.makeStruct(&.{child}),
    );
    try testing.expectEqual(@as(u32, 0), struct_runtime.live);
    struct_runtime.deinit();
    struct_arena.deinit();
    try testing.expectEqual(struct_objects.allocated_bytes, struct_objects.freed_bytes);

    var function_objects: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var function_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    var function_runtime: Runtime = .init(.{
        .arena = function_arena.allocator(),
        .objects = function_objects.allocator(),
    });
    const receiver = try function_runtime.newList(Value.none);
    function_objects.fail_index = function_objects.alloc_index;

    try testing.expectError(
        error.OutOfMemory,
        function_runtime.makeFunction(&.{ Value.ofLong(0), receiver }),
    );
    try testing.expectEqual(@as(u32, 1), function_runtime.live);
    try testing.expectEqual(@as(i64, 0), (try containers.length(&function_runtime, receiver)).asLong());
    function_runtime.freeValue(receiver);
    try testing.expectEqual(@as(u32, 0), function_runtime.live);
    function_runtime.deinit();
    function_arena.deinit();
    try testing.expectEqual(function_objects.allocated_bytes, function_objects.freed_bytes);
}

test "failed struct replacement consumes an object field without freeing the old source" {
    var objects: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    var runtime: Runtime = .init(.{
        .arena = arena.allocator(),
        .objects = objects.allocator(),
    });
    var cleaned = false;
    defer if (!cleaned) {
        runtime.deinit();
        arena.deinit();
    };

    const old_child = try runtime.newList(Value.none);
    const record = try runtime.makeStruct(&.{old_child});
    const replacement = try runtime.newList(Value.none);
    const baseline_live = runtime.live;
    objects.fail_index = objects.alloc_index;

    try testing.expectError(error.OutOfMemory, runtime.setField(record, 0, replacement));
    try testing.expect(objects.has_induced_failure);
    try testing.expectEqual(baseline_live - 1, runtime.live);
    try expectTrap(.use_after_free, &runtime, runtime.resolve(replacement));
    runtime.pending = null;
    try testing.expectEqual(@as(i64, 0), (try containers.length(&runtime, old_child)).asLong());

    runtime.freeValue(record);
    try testing.expectEqual(@as(u32, 0), runtime.live);
    runtime.deinit();
    arena.deinit();
    cleaned = true;
    try testing.expectEqual(objects.allocated_bytes, objects.freed_bytes);
}

test "struct replacement rejects a container-owned alias before allocating" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const child = try runtime.newList(Value.none);
    const record = try runtime.makeStruct(&.{child});
    const holder = try runtime.newList(Value.none);
    try containers.append(runtime, holder, record);
    const baseline_live = runtime.live;

    try expectTrap(.not_owned, runtime, runtime.setField(record, 0, child));
    runtime.pending = null;
    try testing.expectEqual(baseline_live, runtime.live);
    try testing.expectEqual(@as(i64, 1), (try containers.length(runtime, holder)).asLong());
    try testing.expectEqual(@as(i64, 0), (try containers.length(runtime, child)).asLong());
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

test "worker inputs fail closed before allocation or start" {
    var parent_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer parent_arena.deinit();
    var parent: Runtime = .init(.{
        .arena = parent_arena.allocator(),
        .objects = testing.allocator,
    });
    var child_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer child_arena.deinit();
    var child: Runtime = .init(.{
        .arena = child_arena.allocator(),
        .objects = testing.allocator,
    });
    var state: WorkerFailureState = .{ .child = &child };
    state.install(&parent);

    var out = Value.ofLong(99);
    try expectTrap(.host_unavailable, &parent, workers.spawn(&parent, -1, &.{}, &out));
    parent.pending = null;
    try testing.expectEqual(@as(i64, 99), out.asLong());
    try testing.expectEqual(@as(usize, 0), state.spawns);
    try testing.expectEqual(@as(u32, 0), parent.live);

    parent.depth_budget = -1;
    try expectTrap(.host_unavailable, &parent, workers.spawn(&parent, 0, &.{}, &out));
    parent.pending = null;
    parent.depth_budget = std.math.maxInt(i64);
    try expectTrap(.host_unavailable, &parent, workers.spawn(&parent, 0, &.{}, &out));
    parent.pending = null;
    try testing.expectEqual(@as(usize, 0), state.spawns);
    try testing.expectEqual(@as(usize, 0), state.joins);
    try testing.expectEqual(@as(usize, 0), state.closes);
    try testing.expectEqual(@as(u32, 0), parent.live);
    parent.debugAssertInvariants();
    child.debugAssertInvariants();
}

test "a failed spawn joins a callback-published thread before child close" {
    for ([_]i32{ workers.no, -1, 2 }) |spawn_answer| {
        var parent_arena: std.heap.ArenaAllocator = .init(testing.allocator);
        var parent: Runtime = .init(.{
            .arena = parent_arena.allocator(),
            .objects = testing.allocator,
        });
        var child_arena: std.heap.ArenaAllocator = .init(testing.allocator);
        var child: Runtime = .init(.{
            .arena = child_arena.allocator(),
            .objects = testing.allocator,
        });
        var state: WorkerFailureState = .{
            .child = &child,
            .spawn_answer = spawn_answer,
            .produce_result = true,
            .child_live_at_close = std.math.maxInt(u32),
        };
        state.install(&parent);

        var task = Value.ofLong(99);
        try expectTrap(.host_unavailable, &parent, workers.spawn(&parent, 0, &.{}, &task));
        try testing.expectEqual(@as(i64, 99), task.asLong());
        try testing.expectEqual(@as(usize, 1), state.spawns);
        try testing.expectEqual(@as(usize, 1), state.joins);
        try testing.expectEqual(@as(usize, 1), state.closes);
        try testing.expectEqual(@as(u32, 0), state.child_live_at_close);
        try testing.expectEqual(@as(u32, 0), parent.live);
        parent.pending = null;
        parent.deinit();
        parent_arena.deinit();
        child_arena.deinit();
    }
}

test "worker arena exhaustion crosses the join as out of memory" {
    var parent_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer parent_arena.deinit();
    var parent: Runtime = .init(.{
        .arena = parent_arena.allocator(),
        .objects = testing.allocator,
    });
    defer parent.deinit();

    var child_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer child_arena.deinit();
    var child: Runtime = .init(.{
        .arena = child_arena.allocator(),
        .objects = testing.allocator,
    });
    var state: WorkerFailureState = .{
        .child = &child,
        .exhausted = true,
    };
    state.install(&parent);

    var task: Value = .none;
    try workers.spawn(&parent, 0, &.{}, &task);
    var answer: Value = .none;
    try testing.expectError(error.OutOfMemory, workers.wait(&parent, task, &answer));
    try testing.expectEqual(@as(usize, 1), state.joins);
    try testing.expectEqual(@as(usize, 1), state.closes);
    try testing.expectEqual(@as(u32, 0), state.child_live_at_close);
    try testing.expect(parent.pending == null);
    parent.freeValue(task);
    try testing.expectEqual(@as(u32, 0), parent.live);
}

test "a worker result copies and releases a nested object graph" {
    var parent_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer parent_arena.deinit();
    var parent: Runtime = .init(.{
        .arena = parent_arena.allocator(),
        .objects = testing.allocator,
    });
    defer parent.deinit();

    var child_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer child_arena.deinit();
    var child: Runtime = .init(.{
        .arena = child_arena.allocator(),
        .objects = testing.allocator,
    });
    var state: WorkerFailureState = .{
        .child = &child,
        .produce_graph = true,
    };
    state.install(&parent);

    var task: Value = .none;
    try workers.spawn(&parent, 0, &.{}, &task);
    var answer: Value = .none;
    try testing.expectEqual(workers.survived, try workers.wait(&parent, task, &answer));
    try testing.expect(state.ran);
    try testing.expectEqual(@as(usize, 1), state.joins);
    try testing.expectEqual(@as(usize, 1), state.closes);
    try testing.expectEqual(@as(u32, 0), state.child_live_at_close);

    const fields = answer.asStruct();
    try testing.expectEqual(@as(usize, 2), fields.len);
    try testing.expectEqualStrings("worker graph result has outside storage", fields[1].asString());
    const branch = fields[0];
    try testing.expectEqual(@as(i64, 1), (try containers.length(&parent, branch)).asLong());
    const leaf = try containers.indexGet(&parent, branch, &.{Value.ofLong(0)});
    try expectContainerParent(&parent, leaf, branch);
    try testing.expectEqual(@as(i64, 11), (try containers.indexGet(&parent, leaf, &.{Value.ofLong(0)})).asLong());
    try testing.expectEqual(heap.Owner.Kind.loose, (try parent.resolve(branch)).owner.kind);

    parent.freeValue(answer);
    parent.freeValue(task);
    try testing.expectEqual(@as(u32, 0), parent.live);
}

test "nested tasks wait and release through value-shaped containers" {
    var state = LifecycleState.init();
    var parent_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer parent_arena.deinit();
    var parent: Runtime = .init(.{
        .arena = parent_arena.allocator(),
        .objects = testing.allocator,
    });
    defer parent.deinit();
    state.install(&parent);

    const map = try parent.newMap();
    const list = try parent.newList(Value.none);
    const array = try parent.newArray(&.{1}, Value.none);

    var rejected_task: Value = .none;
    try workers.spawn(
        &parent,
        @intFromEnum(LifecycleAction.result_resource),
        &.{},
        &rejected_task,
    );
    const rejected_packet = try parent.makeStruct(&.{ rejected_task, Value.none });
    try containers.indexSet(
        &parent,
        map,
        &.{Value.ofInlineText(.string, "resource-result")},
        rejected_packet,
    );

    var released_task: Value = .none;
    try workers.spawn(
        &parent,
        @intFromEnum(LifecycleAction.clean),
        &.{},
        &released_task,
    );
    const released_packet = try parent.makeStruct(&.{ released_task, Value.none });
    try containers.append(&parent, list, released_packet);

    var waited_task: Value = .none;
    try workers.spawn(
        &parent,
        @intFromEnum(LifecycleAction.clean),
        &.{},
        &waited_task,
    );
    const waited_packet = try parent.makeStruct(&.{ waited_task, Value.none });
    try containers.indexSet(&parent, array, &.{Value.ofLong(0)}, waited_packet);

    const map_packet = try containers.mapGet(
        &parent,
        map,
        Value.ofInlineText(.string, "resource-result"),
    );
    try expectContainerParent(&parent, map_packet.asStruct()[0], map);
    const list_packet = try containers.indexGet(&parent, list, &.{Value.ofLong(0)});
    try expectContainerParent(&parent, list_packet.asStruct()[0], list);
    const array_packet = try containers.indexGet(&parent, array, &.{Value.ofLong(0)});
    try expectContainerParent(&parent, array_packet.asStruct()[0], array);
    try testing.expectEqual(@as(usize, 3), state.spawns);
    try testing.expectEqual(@as(usize, 3), state.opens);
    parent.debugAssertInvariants();

    // A resource-bearing child result cannot cross into the parent runtime.
    // The task is already detached, so the failed copy must still close its
    // file and child exactly once while leaving the nested task row for the
    // enclosing map to release later.
    var answer = Value.ofLong(99);
    try expectTrap(
        .not_owned,
        &parent,
        workers.wait(&parent, map_packet.asStruct()[0], &answer),
    );
    try testing.expectEqual(@as(i64, 99), answer.asLong());
    parent.pending = null;
    try testing.expectEqual(@as(usize, 1), state.joins);
    try testing.expectEqual(@as(usize, 1), state.closes);
    try testing.expectEqual(@as(u32, 0), state.child_live_at_close);
    parent.debugAssertInvariants();

    // Releasing the list joins its nested task without observing its result;
    // waiting the array's task does the observing path.  All three task rows
    // remain in their value-shaped holders until those holders are freed.
    parent.freeValue(list);
    try testing.expectEqual(@as(usize, 2), state.joins);
    try testing.expectEqual(@as(usize, 2), state.closes);

    var second_answer = Value.ofLong(98);
    try testing.expectEqual(
        workers.survived,
        try workers.wait(&parent, array_packet.asStruct()[0], &second_answer),
    );
    try testing.expect(second_answer.isNone());
    try testing.expectEqual(@as(usize, 3), state.joins);
    try testing.expectEqual(@as(usize, 3), state.closes);
    parent.pending = null;

    parent.freeValue(array);
    parent.freeValue(map);
    try testing.expectEqual(@as(usize, 3), state.file_opens);
    try testing.expectEqual(@as(usize, 3), state.file_closes);
    try testing.expectEqual(@as(usize, 0), state.activeChildren());
    try testing.expect(!state.duplicate_close);
    try testing.expect(!state.unknown_close);
    try testing.expectEqual(@as(u32, 0), parent.live);
    try testing.expectEqual(@as(i64, 0), parent.leaked());
}

test "failed worker graph construction closes every partial child allocation" {
    try testing.expect((try expectWorkerGraphFailures()) >= 7);
}

test "failed worker graph result copy closes the child before returning" {
    var parent_objects: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var parent_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    var parent: Runtime = .init(.{
        .arena = parent_arena.allocator(),
        .objects = parent_objects.allocator(),
    });

    var child_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    var child: Runtime = .init(.{
        .arena = child_arena.allocator(),
        .objects = testing.allocator,
    });
    var state: WorkerFailureState = .{
        .child = &child,
        .produce_graph = true,
        .child_live_at_close = std.math.maxInt(u32),
    };
    state.install(&parent);

    var task: Value = .none;
    try workers.spawn(&parent, 0, &.{}, &task);
    // Leave spawn's parent allocations available, then refuse the first
    // destination allocation in wait's cross-runtime copy.
    parent_objects.fail_index = parent_objects.alloc_index;
    var answer: Value = .none;
    try testing.expectError(error.OutOfMemory, workers.wait(&parent, task, &answer));
    try testing.expect(answer.isNone());
    try testing.expect(state.ran);
    try testing.expectEqual(@as(usize, 1), state.joins);
    try testing.expectEqual(@as(usize, 1), state.closes);
    try testing.expectEqual(@as(u32, 0), state.child_live_at_close);

    parent.freeValue(task);
    try testing.expectEqual(@as(u32, 0), parent.live);
    parent.deinit();
    parent_arena.deinit();
    child_arena.deinit();
    try testing.expectEqual(parent_objects.allocated_bytes, parent_objects.freed_bytes);
}

test "waiting a task is one-shot and releasing its row never joins twice" {
    var parent_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer parent_arena.deinit();
    var parent: Runtime = .init(.{
        .arena = parent_arena.allocator(),
        .objects = testing.allocator,
    });
    defer parent.deinit();

    var child_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer child_arena.deinit();
    var child: Runtime = .init(.{
        .arena = child_arena.allocator(),
        .objects = testing.allocator,
    });
    var state: WorkerFailureState = .{ .child = &child };
    state.install(&parent);

    var task: Value = .none;
    try workers.spawn(&parent, 0, &.{}, &task);
    var answer: Value = .none;
    try testing.expectEqual(workers.survived, try workers.wait(&parent, task, &answer));
    try testing.expect(answer.isNone());
    try testing.expectEqual(@as(usize, 1), state.joins);
    try testing.expectEqual(@as(usize, 1), state.closes);

    var second: Value = .ofLong(99);
    try expectTrap(.use_after_free, &parent, workers.wait(&parent, task, &second));
    try testing.expectEqual(@as(i64, 99), second.asLong());
    parent.freeValue(task);
    parent.freeValue(task);
    try testing.expectEqual(@as(u32, 0), parent.live);
}

test "waiting a task fails closed when the host rejects the join" {
    for ([_]i32{ workers.no, 2, -7 }) |join_answer| {
        var parent_arena: std.heap.ArenaAllocator = .init(testing.allocator);
        var parent: Runtime = .init(.{
            .arena = parent_arena.allocator(),
            .objects = testing.allocator,
        });
        var child_arena: std.heap.ArenaAllocator = .init(testing.allocator);
        var child: Runtime = .init(.{
            .arena = child_arena.allocator(),
            .objects = testing.allocator,
        });
        var state: WorkerFailureState = .{
            .child = &child,
            .child_live_at_close = std.math.maxInt(u32),
            .join_answer = join_answer,
        };
        state.install(&parent);

        var task: Value = .none;
        try workers.spawn(&parent, 0, &.{}, &task);
        var answer = Value.ofLong(99);
        try testing.expectError(error.Trap, workers.wait(&parent, task, &answer));
        try testing.expectEqual(vocabulary.TrapCode.host_unavailable, parent.pending.?.code);
        try testing.expectEqual(@as(i64, 99), answer.asLong());
        try testing.expectEqual(@as(usize, 1), state.spawns);
        try testing.expectEqual(@as(usize, 1), state.joins);
        try testing.expectEqual(@as(usize, 1), state.closes);
        try testing.expectEqual(@as(u32, 0), state.child_live_at_close);

        // `wait` consumes the worker but leaves the task row as caller
        // storage, even when the host rejected the join.
        parent.pending = null;
        parent.freeValue(task);
        try testing.expectEqual(@as(u32, 0), parent.live);
        parent.deinit();
        parent_arena.deinit();
        child_arena.deinit();
    }
}

test "malformed worker outcomes fail closed before wait copies a result" {
    for ([_]i32{ -1, 3 }) |run_answer| {
        var parent_arena: std.heap.ArenaAllocator = .init(testing.allocator);
        var parent: Runtime = .init(.{
            .arena = parent_arena.allocator(),
            .objects = testing.allocator,
        });
        var child_arena: std.heap.ArenaAllocator = .init(testing.allocator);
        var child: Runtime = .init(.{
            .arena = child_arena.allocator(),
            .objects = testing.allocator,
        });
        var state: WorkerFailureState = .{
            .child = &child,
            .child_live_at_close = std.math.maxInt(u32),
            .run_answer = run_answer,
        };
        state.install(&parent);

        var task: Value = .none;
        try workers.spawn(&parent, 0, &.{}, &task);
        var answer = Value.ofLong(99);
        try testing.expectError(error.Trap, workers.wait(&parent, task, &answer));
        try testing.expectEqual(vocabulary.TrapCode.host_unavailable, parent.pending.?.code);
        try testing.expectEqual(@as(i64, 99), answer.asLong());
        try testing.expectEqual(@as(usize, 1), state.spawns);
        try testing.expectEqual(@as(usize, 1), state.joins);
        try testing.expectEqual(@as(usize, 1), state.closes);
        try testing.expectEqual(@as(u32, 0), state.child_live_at_close);

        parent.pending = null;
        parent.freeValue(task);
        try testing.expectEqual(@as(u32, 0), parent.live);
        parent.deinit();
        parent_arena.deinit();
        child_arena.deinit();
    }
}

test "a failed struct store consumes only its replacement and preserves the source" {
    var objects: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var runtime: Runtime = .init(.{
        .arena = arena.allocator(),
        .objects = objects.allocator(),
    });
    defer runtime.deinit();

    const child = try runtime.newList(Value.none);
    var fields = [_]Value{ Value.ofLong(1), child };
    const record = try runtime.makeStruct(&fields);
    const replacement = try runtime.ownValue(Value.ofString(
        "replacement text that is outside the value",
    ));
    objects.fail_index = objects.alloc_index;

    try testing.expectError(error.OutOfMemory, runtime.setField(record, 0, replacement));
    objects.fail_index = std.math.maxInt(usize);
    try testing.expectEqual(@as(u32, 1), runtime.live);
    try testing.expect(record.asStruct()[1].asObject().same(child.asObject()));
    try testing.expectEqual(@as(i64, 0), (try containers.length(&runtime, child)).asLong());
    try testing.expect(runtime.pending == null);

    runtime.freeValue(record);
    try testing.expectEqual(@as(u32, 0), runtime.live);
}

test "failed worker error adoption still closes the child runtime" {
    var parent_memory: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var parent_arena: std.heap.ArenaAllocator = .init(parent_memory.allocator());
    defer parent_arena.deinit();
    var parent: Runtime = .init(.{
        .arena = parent_arena.allocator(),
        .objects = testing.allocator,
    });

    var child_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer child_arena.deinit();
    var child: Runtime = .init(.{
        .arena = child_arena.allocator(),
        .objects = testing.allocator,
    });
    var state: WorkerFailureState = .{
        .child = &child,
        .raise_error = true,
        .child_live_at_close = std.math.maxInt(u32),
    };
    state.install(&parent);

    var task: Value = .none;
    try workers.spawn(&parent, 0, &.{}, &task);
    // No parent-arena allocation has happened yet.  Refuse the message
    // copy in adoptError, after the worker has already been detached.
    parent_memory.fail_index = parent_memory.alloc_index;

    var answer: Value = .none;
    try testing.expectError(error.OutOfMemory, workers.wait(&parent, task, &answer));
    try testing.expect(answer.isNone());
    try testing.expectEqual(@as(usize, 1), state.joins);
    try testing.expectEqual(@as(usize, 1), state.closes);
    try testing.expectEqual(@as(u32, 0), state.child_live_at_close);

    // `wait` consumed the Worker, but the task row remains the caller's
    // storage and must still be released after the failed join.
    parent.freeValue(task);
    try testing.expectEqual(@as(u32, 0), parent.live);
    parent.deinit();
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
    // This is deliberately malformed input for the cross-runtime copy
    // backstop.  The public retaining door now rejects a stale handle, so
    // forge the damaged source row directly inside this runtime test rather
    // than weakening that boundary just to construct the hostile fixture.
    const middle_object = try source.resolve(middle);
    try middle_object.elements.append(source.objects, stale);
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

test "cross-runtime moves roll back every nested allocation" {
    for ([_]CopyShape{ .list, .map, .array, .strukt }) |shape| {
        try testing.expect((try expectNestedMoveFailures(shape)) >= 4);
    }
}

test "cross-runtime moves reject function receiver handles" {
    var source_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer source_arena.deinit();
    var source: Runtime = .init(.{
        .arena = source_arena.allocator(),
        .objects = testing.allocator,
    });
    defer source.deinit();

    var target_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer target_arena.deinit();
    var target: Runtime = .init(.{
        .arena = target_arena.allocator(),
        .objects = testing.allocator,
    });
    defer target.deinit();

    const receiver = try source.newList(Value.none);
    const function = try source.makeFunction(&.{ Value.ofLong(7), receiver });
    try expectTrap(.not_owned, &source, source.moveInto(&target, function));
    source.pending = null;
    try testing.expectEqual(@as(u32, 0), target.live);
    _ = try source.resolve(receiver);
    source.freeValue(function);
    source.freeValue(receiver);

    const nested_receiver = try source.newList(Value.none);
    const nested_function = try source.makeFunction(&.{ Value.ofLong(9), nested_receiver });
    const record = try source.makeStruct(&.{nested_function});
    try expectTrap(.not_owned, &source, source.moveInto(&target, record));
    source.pending = null;
    try testing.expectEqual(@as(u32, 0), target.live);
    _ = try source.resolve(nested_receiver);
    source.freeValue(record);
    source.freeValue(nested_receiver);
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

test "file open rejects the post-close handle sentinel" {
    const Host = struct {
        opened: usize = 0,
        closed: usize = 0,
        closed_handle: i64 = 0,

        fn open(
            context: ?*anyopaque,
            _: [*]const u8,
            _: i64,
            _: i64,
            _: *i64,
        ) callconv(.c) i32 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.opened += 1;
            // The caller initializes the output to `heap.no_file`; leave it
            // untouched while claiming success to model a malformed host.
            return files.yes;
        }

        fn close(context: ?*anyopaque, handle: i64) callconv(.c) i32 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.closed += 1;
            self.closed_handle = handle;
            return files.yes;
        }
    };

    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    var host: Host = .{};
    bench.runtime.files = .{
        .context = &host,
        .open = Host.open,
        .close = Host.close,
    };

    try expectTrap(
        .host_unavailable,
        &bench.runtime,
        files.open(&bench.runtime, "sentinel.bin", @intFromEnum(files.Mode.read)),
    );
    try testing.expectEqual(@as(usize, 1), host.opened);
    try testing.expectEqual(@as(usize, 1), host.closed);
    try testing.expectEqual(heap.no_file, host.closed_handle);
    try testing.expectEqual(@as(u32, 0), bench.runtime.live);
    bench.runtime.pending = null;
}

test "host byte counts are bounded before runtime slices or advances" {
    const Host = struct {
        const Mode = enum { negative, oversized, zero };

        mode: Mode,
        opened: usize = 0,
        closed: usize = 0,
        flushes: usize = 0,

        fn open(
            context: ?*anyopaque,
            _: [*]const u8,
            _: i64,
            _: i64,
            handle: *i64,
        ) callconv(.c) i32 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.opened += 1;
            handle.* = 41;
            return files.yes;
        }

        fn read(
            context: ?*anyopaque,
            _: i64,
            _: [*]u8,
            capacity: i64,
            filled: *i64,
        ) callconv(.c) i32 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            filled.* = switch (self.mode) {
                .negative => -1,
                .oversized => capacity + 1,
                .zero => 0,
            };
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
            written.* = switch (self.mode) {
                .negative => -1,
                .oversized => length + 1,
                .zero => 0,
            };
            return files.yes;
        }

        fn flush(context: ?*anyopaque, _: i64) callconv(.c) i32 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.flushes += 1;
            return files.yes;
        }

        fn close(context: ?*anyopaque, _: i64) callconv(.c) i32 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.closed += 1;
            return files.yes;
        }
    };

    // The primitive doors validate both directions before returning a count
    // to their caller.  A malformed answer must not become a negative slice
    // bound or an oversized progress increment.
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;
    var host: Host = .{ .mode = .negative };
    runtime.files = .{
        .context = &host,
        .read = Host.read,
        .write = Host.write,
        .close = Host.close,
    };
    const file = try runtime.newFile(41, "counts.bin");
    const buffer = try runtime.newArray(&.{8}, Value.ofByte(0));

    try expectTrap(.host_unavailable, runtime, files.read(runtime, file, buffer));
    runtime.pending = null;
    host.mode = .oversized;
    try expectTrap(.host_unavailable, runtime, files.read(runtime, file, buffer));
    runtime.pending = null;
    try expectTrap(.host_unavailable, runtime, files.write(runtime, file, buffer, 8));
    runtime.pending = null;
    host.mode = .zero;
    try testing.expectEqual(@as(?i64, 0), try files.read(runtime, file, buffer));
    try testing.expectEqual(@as(?i64, 0), try files.write(runtime, file, buffer, 8));
    try testing.expectEqual(@as(usize, 0), host.flushes);
    runtime.freeValue(buffer);
    runtime.freeValue(file);
    try testing.expectEqual(@as(usize, 1), host.closed);

    // Whole-file conveniences use the same count wall and still close a
    // successfully opened resource when the callback violates the protocol.
    for ([_]Host.Mode{ .negative, .oversized }) |mode| {
        var convenience: Bench = undefined;
        convenience.setup();
        const convenience_runtime = &convenience.runtime;
        var convenience_host: Host = .{ .mode = mode };
        convenience_runtime.files = .{
            .context = &convenience_host,
            .open = Host.open,
            .read = Host.read,
            .write = Host.write,
            .flush = Host.flush,
            .close = Host.close,
        };
        try expectTrap(
            .host_unavailable,
            convenience_runtime,
            files.readText(convenience_runtime, "read.bin"),
        );
        convenience_runtime.pending = null;
        try expectTrap(
            .host_unavailable,
            convenience_runtime,
            files.writeText(convenience_runtime, "write.bin", "payload", .write),
        );
        try testing.expectEqual(@as(usize, 2), convenience_host.opened);
        try testing.expectEqual(@as(usize, 2), convenience_host.closed);
        try testing.expectEqual(@as(usize, 0), convenience_host.flushes);
        convenience.deinit();
    }

    var zero_progress: Bench = undefined;
    zero_progress.setup();
    var zero_host: Host = .{ .mode = .zero };
    zero_progress.runtime.files = .{
        .context = &zero_host,
        .open = Host.open,
        .write = Host.write,
        .flush = Host.flush,
        .close = Host.close,
    };
    try testing.expect(!try files.writeText(
        &zero_progress.runtime,
        "zero.bin",
        "payload",
        .write,
    ));
    try testing.expectEqual(@as(usize, 1), zero_host.opened);
    try testing.expectEqual(@as(usize, 1), zero_host.closed);
    try testing.expectEqual(@as(usize, 0), zero_host.flushes);
    zero_progress.deinit();
}

test "file callbacks reject unknown answers before using their outputs" {
    const Host = struct {
        open_answer: i32 = files.yes,
        operation_answer: i32 = files.yes,
        opened: usize = 0,
        closed: usize = 0,

        fn open(
            context: ?*anyopaque,
            _: [*]const u8,
            _: i64,
            _: i64,
            handle: *i64,
        ) callconv(.c) i32 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.opened += 1;
            handle.* = 51;
            return self.open_answer;
        }

        fn read(
            context: ?*anyopaque,
            _: i64,
            _: [*]u8,
            _: i64,
            filled: *i64,
        ) callconv(.c) i32 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            filled.* = 0;
            return self.operation_answer;
        }

        fn write(
            context: ?*anyopaque,
            _: i64,
            _: [*]const u8,
            _: i64,
            written: *i64,
        ) callconv(.c) i32 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            written.* = 0;
            return self.operation_answer;
        }

        fn flush(context: ?*anyopaque, _: i64) callconv(.c) i32 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return self.operation_answer;
        }

        fn close(context: ?*anyopaque, _: i64) callconv(.c) i32 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.closed += 1;
            return files.yes;
        }
    };

    // Neither an arbitrary positive value nor an arbitrary negative value is
    // an answer in the file protocol.  In particular, -2 must not inherit
    // the old "any negative means exhausted" behavior.  A callback that
    // writes a raw handle on any non-yes answer is malformed too, but the
    // runtime still closes the handle before returning the refusal.
    for ([_]i32{ files.no, 2, -2 }) |answer| {
        var bench: Bench = undefined;
        bench.setup();
        const runtime = &bench.runtime;
        var host: Host = .{ .open_answer = answer };
        runtime.files = .{
            .context = &host,
            .open = Host.open,
            .close = Host.close,
        };
        if (answer == files.no) {
            try testing.expectEqual(
                @as(?Value, null),
                try files.open(runtime, "malformed-open.txt", @intFromEnum(files.Mode.read)),
            );
        } else {
            try expectTrap(
                .host_unavailable,
                runtime,
                files.open(runtime, "malformed-open.txt", @intFromEnum(files.Mode.read)),
            );
        }
        try testing.expectEqual(@as(u32, 0), runtime.live);
        try testing.expectEqual(@as(usize, 1), host.opened);
        try testing.expectEqual(@as(usize, 1), host.closed);
        bench.deinit();
    }

    var exhausted_bench: Bench = undefined;
    exhausted_bench.setup();
    const exhausted_runtime = &exhausted_bench.runtime;
    var exhausted_host: Host = .{ .open_answer = files.exhausted };
    exhausted_runtime.files = .{
        .context = &exhausted_host,
        .open = Host.open,
        .close = Host.close,
    };
    try testing.expectError(
        error.OutOfMemory,
        files.open(exhausted_runtime, "exhausted-open.txt", @intFromEnum(files.Mode.read)),
    );
    try testing.expect(exhausted_runtime.exhausted);
    try testing.expectEqual(@as(u32, 0), exhausted_runtime.live);
    try testing.expectEqual(@as(usize, 1), exhausted_host.closed);
    exhausted_bench.deinit();

    for ([_]i32{ 2, -2 }) |malformed| {
        var bench: Bench = undefined;
        bench.setup();
        const runtime = &bench.runtime;
        var host: Host = .{ .operation_answer = malformed };
        runtime.files = .{
            .context = &host,
            .read = Host.read,
            .write = Host.write,
            .flush = Host.flush,
            .close = Host.close,
        };
        const file = try runtime.newFile(51, "malformed-operation.txt");
        const buffer = try runtime.newArray(&.{4}, Value.ofByte(0));

        try expectTrap(.host_unavailable, runtime, files.read(runtime, file, buffer));
        runtime.pending = null;
        try expectTrap(.host_unavailable, runtime, files.write(runtime, file, buffer, 4));
        runtime.pending = null;
        try expectTrap(.host_unavailable, runtime, files.flush(runtime, file));
        runtime.pending = null;
        runtime.freeValue(buffer);
        runtime.freeValue(file);
        try testing.expectEqual(@as(usize, 1), host.closed);
        bench.deinit();
    }

    for ([_]i32{ 2, -2 }) |malformed| {
        var bench: Bench = undefined;
        bench.setup();
        const runtime = &bench.runtime;
        var host: Host = .{ .operation_answer = malformed };
        runtime.files = .{
            .context = &host,
            .open = Host.open,
            .read = Host.read,
            .write = Host.write,
            .flush = Host.flush,
            .close = Host.close,
        };

        try expectTrap(.host_unavailable, runtime, files.readText(runtime, "malformed-read.txt"));
        runtime.pending = null;
        try expectTrap(
            .host_unavailable,
            runtime,
            files.writeText(runtime, "malformed-write.txt", "payload", .write),
        );
        try testing.expectEqual(@as(usize, 2), host.opened);
        try testing.expectEqual(@as(usize, 2), host.closed);
        bench.deinit();
    }
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

test "maps and struct values preserve one owner across retaining doors" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const first = try runtime.newMap();
    const second = try runtime.newMap();
    const child = try runtime.newList(Value.none);
    const placed = try containers.mapPlace(runtime, first, Value.ofString("item"), child);
    try testing.expect(placed.asObject().same(child.asObject()));
    try expectContainerParent(runtime, child, first);

    // A map's missing-key path is an ownership door just like list append:
    // a second map cannot publish the same child or change its first owner.
    try expectTrap(
        .not_owned,
        runtime,
        containers.mapPlace(runtime, second, Value.ofString("item"), child),
    );
    runtime.pending = null;
    try testing.expectEqual(@as(i64, 0), (try containers.length(runtime, second)).asLong());
    try expectContainerParent(runtime, child, first);

    // Indexed map replacement releases the old child before the new one is
    // adopted, and keeps the exact key's map owner in the metadata.
    const replacement = try runtime.newList(Value.none);
    try containers.indexSet(runtime, first, &.{Value.ofString("item")}, replacement);
    try expectTrap(.use_after_free, runtime, runtime.resolve(child));
    runtime.pending = null;
    try expectContainerParent(runtime, replacement, first);

    try expectTrap(
        .not_owned,
        runtime,
        containers.mapPlace(runtime, second, Value.ofString("replacement"), replacement),
    );
    runtime.pending = null;

    // Struct runs own their value storage, while the object fields remain
    // graph roots.  Nest two runs before storing the outer value so the walk
    // must cross both layers and still assign the container as the owner.
    const nested_child = try runtime.newList(Value.none);
    const inner = try runtime.makeStruct(&.{nested_child});
    const record = try runtime.makeStruct(&.{inner});
    const outer = try runtime.newList(Value.none);
    try containers.append(runtime, outer, record);
    try expectContainerParent(runtime, nested_child, outer);

    // The same second-owner wall must walk through both value runs, not
    // merely inspect a direct object argument.
    const forged_record = try runtime.makeStruct(&.{nested_child});
    const other = try runtime.newList(Value.none);
    try expectTrap(.not_owned, runtime, containers.append(runtime, other, forged_record));
    runtime.pending = null;
    try expectContainerParent(runtime, nested_child, outer);

    runtime.freeValue(first);
    runtime.freeValue(second);
    runtime.freeValue(other);
    runtime.freeValue(outer);
    try testing.expectEqual(@as(u32, 0), runtime.live);
}

test "checked owner invariants cover maps arrays structs and borrowed functions" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    const mapped = try runtime.newMap();
    const map_child = try runtime.newList(Value.none);
    const map_record = try runtime.makeStruct(&.{map_child});
    try containers.indexSet(runtime, mapped, &.{Value.ofString("record")}, map_record);

    const array = try runtime.newArray(&.{1}, Value.none);
    const array_child = try runtime.newList(Value.none);
    const array_record = try runtime.makeStruct(&.{array_child});
    try containers.indexSet(runtime, array, &.{Value.ofLong(0)}, array_record);

    // A function run owns its field storage but borrows the receiver graph.
    // The checked walk must follow the struct wrapper and stop at the
    // function value rather than inventing a second edge to `receiver`.
    const receiver = try runtime.newList(Value.none);
    const callback = try runtime.makeFunction(&.{ Value.ofLong(0), receiver });
    const callback_record = try runtime.makeStruct(&.{callback});
    try containers.indexSet(runtime, mapped, &.{Value.ofString("callback")}, callback_record);

    runtime.debugAssertInvariants();
    runtime.freeValue(mapped);
    runtime.freeValue(array);
    runtime.freeValue(receiver);
    runtime.debugAssertInvariants();
    try testing.expectEqual(@as(u32, 0), runtime.live);
}

test "a union-shaped optional callback keeps borrowed receivers out of ownership walks" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    // The runtime deliberately sees a union as a struct-shaped value.  This
    // shape carries an optional callback, an owned object payload, and an
    // absent optional slot all at once; only the callback's run is owned by
    // the value, while its receiver remains a borrow.
    const receiver = try runtime.newList(Value.none);
    try containers.append(runtime, receiver, Value.ofLong(5));
    const callback = try runtime.makeFunction(&.{ Value.ofLong(0), receiver });
    const payload = try runtime.newList(Value.none);
    try containers.append(runtime, payload, Value.ofLong(9));
    const packet = try runtime.makeStruct(&.{ callback, payload, Value.none });
    const bag = try runtime.newList(Value.none);
    try containers.append(runtime, bag, packet);
    try expectContainerParent(runtime, payload, bag);
    try testing.expectEqual(heap.Owner.Kind.loose, (try runtime.resolve(receiver)).owner.kind);

    const copied_bag = try runtime.deepCopy(bag);
    const copied_packet = try containers.indexGet(runtime, copied_bag, &.{Value.ofLong(0)});
    const copied_fields = copied_packet.asStruct();
    try testing.expectEqual(@as(usize, 3), copied_fields.len);
    try testing.expectEqual(value.Tag.function, copied_fields[0].tag);
    try testing.expect(copied_fields[2].isNone());
    const copied_payload = copied_fields[1];
    try testing.expect(!copied_payload.asObject().same(payload.asObject()));
    try expectContainerParent(runtime, copied_payload, copied_bag);
    try testing.expectEqual(heap.Owner.Kind.loose, (try runtime.resolve(receiver)).owner.kind);

    runtime.freeValue(bag);
    runtime.freeValue(copied_bag);
    runtime.freeValue(receiver);
    try testing.expectEqual(@as(u32, 0), runtime.live);
}

test "function values stay receiver-borrowed through every value container" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    // The receiver owns a second object and outside text.  Every function
    // below names this same graph, but none of the function runs may become
    // a second owner of either row.
    const receiver = try runtime.newList(Value.none);
    const nested = try runtime.newList(Value.none);
    try containers.append(runtime, nested, try runtime.ownValue(Value.ofString(
        "receiver bytes outlive every borrowed callback run",
    )));
    try containers.append(runtime, receiver, nested);

    const list = try runtime.newList(Value.none);
    var list_function = try runtime.makeFunction(&.{ Value.ofLong(1), receiver });
    try containers.append(runtime, list, list_function);
    list_function = .none;

    const map = try runtime.newMap();
    var map_function = try runtime.makeFunction(&.{ Value.ofLong(2), receiver });
    try containers.indexSet(runtime, map, &.{Value.ofInlineText(.string, "callback")}, map_function);
    map_function = .none;

    // A function value is a value-shaped array element.  `arrayFill` makes a
    // fresh run per cell, so this covers both the array replacement buffer and
    // repeated copies of a run whose receiver remains borrowed.
    const array = try runtime.newArray(&.{3}, Value.none);
    var fill_function = try runtime.makeFunction(&.{ Value.ofLong(3), receiver });
    try containers.arrayFill(runtime, array, fill_function);
    runtime.dropStorage(fill_function);
    fill_function = .none;

    var record_function = try runtime.makeFunction(&.{ Value.ofLong(4), receiver });
    const record = try runtime.makeStruct(&.{record_function});
    record_function = .none;

    try expectBorrowedFunctionReceiver(
        try containers.indexGet(runtime, list, &.{Value.ofLong(0)}),
        receiver,
    );
    try expectBorrowedFunctionReceiver(
        try containers.mapGet(runtime, map, Value.ofInlineText(.string, "callback")),
        receiver,
    );
    for (0..3) |index| {
        try expectBorrowedFunctionReceiver(
            try containers.indexGet(runtime, array, &.{Value.ofLong(@intCast(index))}),
            receiver,
        );
    }
    try expectBorrowedFunctionReceiver(record.asStruct()[0], receiver);
    runtime.debugAssertInvariants();

    // Copying every holder duplicates only the function run.  The receiver
    // handle must remain the same borrowed handle in each copy.
    const copied_list = try runtime.deepCopy(list);
    const copied_map = try runtime.deepCopy(map);
    const copied_array = try runtime.deepCopy(array);
    const copied_record = try runtime.deepCopy(record);
    try expectBorrowedFunctionReceiver(
        try containers.indexGet(runtime, copied_list, &.{Value.ofLong(0)}),
        receiver,
    );
    try expectBorrowedFunctionReceiver(
        try containers.mapGet(runtime, copied_map, Value.ofInlineText(.string, "callback")),
        receiver,
    );
    for (0..3) |index| {
        try expectBorrowedFunctionReceiver(
            try containers.indexGet(runtime, copied_array, &.{Value.ofLong(@intCast(index))}),
            receiver,
        );
    }
    try expectBorrowedFunctionReceiver(copied_record.asStruct()[0], receiver);
    runtime.debugAssertInvariants();

    // Function values are not a hidden owner.  Retiring the receiver while
    // the holders still contain stale borrowed handles must be safe, and
    // releasing those holders must return only their own runs.
    runtime.freeValue(receiver);
    try expectStale(runtime, runtime.resolve(receiver));
    runtime.debugAssertInvariants();

    runtime.freeValue(copied_list);
    runtime.freeValue(copied_map);
    runtime.freeValue(copied_array);
    runtime.freeValue(copied_record);
    runtime.freeValue(list);
    runtime.freeValue(map);
    runtime.freeValue(array);
    runtime.freeValue(record);
    runtime.debugAssertInvariants();
    try testing.expectEqual(@as(u32, 0), runtime.live);
    try testing.expectEqual(@as(i64, 0), runtime.leaked());
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
    try testing.expectEqual(@as(i64, 1), (try containers.find(runtime, held, Value.ofLong(20))).asLong());
    try testing.expect((try containers.find(runtime, held, Value.ofLong(99))).isNone());

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

test "array fill releases forged object cells before scalar replacement" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    // Source-level analysis rejects an object array's fill method, but the
    // runtime must still be total for decoded or hand-built values.  Put two
    // owned children into a value array, then replace them with a scalar.
    const array = try runtime.newArray(&.{2}, Value.none);
    const first = try runtime.newList(Value.none);
    const second = try runtime.newList(Value.none);
    try containers.indexSet(runtime, array, &.{Value.ofLong(0)}, first);
    try containers.indexSet(runtime, array, &.{Value.ofLong(1)}, second);
    try testing.expectEqual(@as(u32, 3), runtime.live);

    try containers.arrayFill(runtime, array, Value.ofLong(7));
    try testing.expectEqual(@as(u32, 1), runtime.live);
    try expectTrap(.use_after_free, runtime, runtime.resolve(first));
    runtime.pending = null;
    try expectTrap(.use_after_free, runtime, runtime.resolve(second));
    runtime.pending = null;
    try testing.expectEqual(
        @as(i64, 7),
        (try containers.indexGet(runtime, array, &.{Value.ofLong(0)})).asLong(),
    );
    try testing.expectEqual(
        @as(i64, 7),
        (try containers.indexGet(runtime, array, &.{Value.ofLong(1)})).asLong(),
    );
    runtime.freeValue(array);
    try testing.expectEqual(@as(u32, 0), runtime.live);
}

test "array fill keeps its old values through every copy allocation failure" {
    const long_text = "a long fill value that must be copied into every array cell";
    // One array has one shape allocation, one element run and one table row;
    // the fill then has one replacement run followed by one String copy per
    // cell.  Walk beyond that range too, proving success after the failure
    // points rather than relying on an assumed allocation count.
    for (0..8) |offset| {
        var objects: std.testing.FailingAllocator = .init(testing.allocator, .{});
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        var runtime: Runtime = .init(.{
            .arena = arena.allocator(),
            .objects = objects.allocator(),
        });
        const array = try runtime.newArray(&.{3}, Value.ofString("old"));
        objects.fail_index = objects.alloc_index + offset;

        const outcome = containers.arrayFill(
            &runtime,
            array,
            Value.ofString(long_text),
        );
        objects.fail_index = std.math.maxInt(usize);
        if (outcome) |_| {
            for (0..3) |index| {
                try testing.expectEqualStrings(
                    long_text,
                    (try containers.indexGet(&runtime, array, &.{Value.ofLong(@intCast(index))})).asString(),
                );
            }
        } else |mistake| {
            try testing.expectEqual(error.OutOfMemory, mistake);
            for (0..3) |index| {
                try testing.expectEqualStrings(
                    "old",
                    (try containers.indexGet(&runtime, array, &.{Value.ofLong(@intCast(index))})).asString(),
                );
            }
        }
        runtime.debugAssertInvariants();
        runtime.freeValue(array);
        runtime.debugAssertInvariants();
        try testing.expectEqual(@as(u32, 0), runtime.live);
        runtime.deinit();
        arena.deinit();
        try testing.expectEqual(objects.allocated_bytes, objects.freed_bytes);
    }
}

test "array fill rolls borrowed function runs back at every allocation failure" {
    var failures: usize = 0;
    var completed = false;

    // The setup is complete before the failing allocator is armed.  Every
    // refusal below is therefore inside the replacement buffer or one of
    // the function runs copied into it, not a construction failure that
    // would leave the test unable to inspect the old array.
    for (0..24) |offset| {
        var objects: std.testing.FailingAllocator = .init(testing.allocator, .{});
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        var runtime: Runtime = .init(.{
            .arena = arena.allocator(),
            .objects = objects.allocator(),
        });

        const receiver = try runtime.newList(Value.none);
        const nested = try runtime.newList(Value.none);
        try containers.append(&runtime, nested, try runtime.ownValue(Value.ofString(
            "borrowed receiver graph remains outside function storage",
        )));
        try containers.append(&runtime, receiver, nested);
        const array = try runtime.newArray(&.{3}, Value.none);
        const function = try runtime.makeFunction(&.{ Value.ofLong(9), receiver });

        objects.fail_index = objects.alloc_index + offset;
        const outcome = containers.arrayFill(&runtime, array, function);
        objects.fail_index = std.math.maxInt(usize);

        // arrayFill borrows the source function.  Its storage is released
        // here on both paths; any successful cell owns an independent copy.
        runtime.dropStorage(function);
        if (outcome) |_| {
            for (0..3) |index| {
                const cell = try containers.indexGet(
                    &runtime,
                    array,
                    &.{Value.ofLong(@intCast(index))},
                );
                try testing.expectEqual(value.Tag.function, cell.tag);
                try testing.expectEqual(@as(i64, 9), cell.asStruct()[0].asLong());
                try testing.expect(cell.asStruct()[1].asObject().same(receiver.asObject()));
            }
            completed = true;
        } else |mistake| {
            try testing.expectEqual(error.OutOfMemory, mistake);
            try testing.expect(objects.has_induced_failure);
            try testing.expect(runtime.pending == null);
            try testing.expectEqual(@as(u32, 3), runtime.live);
            for (0..3) |index| {
                try testing.expect(
                    (try containers.indexGet(
                        &runtime,
                        array,
                        &.{Value.ofLong(@intCast(index))},
                    )).isNone(),
                );
            }
            try testing.expectEqual(
                @as(i64, 1),
                (try containers.length(&runtime, receiver)).asLong(),
            );
            failures += 1;
        }

        runtime.debugAssertInvariants();
        // The receiver is never adopted by a function run.  Retire it before
        // releasing the array so stale borrowed handles exercise the same
        // no-object-walk rule on both successful and rollback paths.
        runtime.freeValue(receiver);
        try expectStale(&runtime, runtime.resolve(receiver));
        runtime.freeValue(array);
        runtime.debugAssertInvariants();
        try testing.expectEqual(@as(u32, 0), runtime.live);
        runtime.deinit();
        arena.deinit();
        try testing.expectEqual(objects.allocated_bytes, objects.freed_bytes);
        if (completed) break;
    }

    try testing.expect(completed);
    try testing.expect(failures >= 1);
}

test "new arrays roll every owned cell back when construction allocation fails" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        newArrayWithOwnedFill,
        .{},
    );
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

    // has_key answers false, get answers absence, m[key] traps.
    try testing.expect(!(try containers.hasKey(runtime, held, Value.ofString("c"))).asBoolean());
    try testing.expect((try containers.mapGet(runtime, held, Value.ofString("c"))).isNone());
    try testing.expectEqual(
        @as(i64, 2),
        (try containers.mapGet(runtime, held, Value.ofString("b"))).asLong(),
    );
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

test "direct text primitives reject non-string values before decoding payloads" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;
    const forged = Value.ofLong(0);

    try expectTrap(.not_owned, runtime, text.slice(runtime, forged, 0, 1));
    runtime.pending = null;
    try expectTrap(.not_owned, runtime, text.byteAt(runtime, forged, 0));
    runtime.pending = null;
    try expectTrap(.not_owned, runtime, text.findByte(runtime, forged, 'x', 0));
    runtime.pending = null;
    try expectTrap(.not_owned, runtime, text.parseInt(runtime, forged));
    runtime.pending = null;
    try expectTrap(.not_owned, runtime, text.parseFloat(runtime, forged));
    runtime.pending = null;
    try expectTrap(.not_owned, runtime, text.ord(runtime, forged));
    runtime.pending = null;
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
    // Every NaN renders as "nan", whichever sign bit the hardware
    // chose — the formatter is the one place the sign could ever be
    // observed, and it declines to show it (both bit patterns, so a
    // host that produces the other one cannot regress this silently).
    try testing.expectEqualStrings(
        "nan",
        bench.made(try text.str(runtime, Value.ofDouble(@bitCast(@as(u64, 0x7ff8000000000000))))).asString(),
    );
    try testing.expectEqualStrings(
        "nan",
        bench.made(try text.str(runtime, Value.ofDouble(@bitCast(@as(u64, 0xfff8000000000000))))).asString(),
    );
    try testing.expectEqualStrings("inf", bench.made(try text.str(runtime, Value.ofDouble(std.math.inf(f64)))).asString());
    try testing.expectEqualStrings("-inf", bench.made(try text.str(runtime, Value.ofDouble(-std.math.inf(f64)))).asString());

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
    report: ?trace.ReportFn,
) callconv(.c) void;
extern fn luce_rt_report_error(
    runtime: *const Runtime,
    context: ?*anyopaque,
    report: ?trace.ErrorReportFn,
) callconv(.c) void;
extern fn luce_rt_leaked(runtime: *const Runtime) callconv(.c) i64;
extern fn luce_rt_constants_begin(runtime: *Runtime, count: u32) callconv(.c) i32;
extern fn luce_rt_constant_publish(
    runtime: *Runtime,
    slot: u32,
    held: [*c]const Value,
) callconv(.c) i32;
extern fn luce_rt_constant_load(
    runtime: *Runtime,
    slot: u32,
    out: [*c]Value,
) callconv(.c) void;
extern fn luce_rt_error_message(runtime: *Runtime, out: [*c]Value) callconv(.c) void;
extern fn luce_rt_key_text(runtime: *Runtime, out: [*c]Value) callconv(.c) void;
extern fn luce_rt_constants_finish(runtime: *Runtime) callconv(.c) void;
extern fn luce_rt_constants_abort(runtime: *Runtime) callconv(.c) void;
extern fn luce_rt_discard_loose(runtime: *Runtime, held: [*c]const Value) callconv(.c) void;
extern fn luce_rt_raise(
    runtime: *Runtime,
    code: i32,
    message: [*c]const u8,
    length: i64,
) callconv(.c) void;
extern fn luce_rt_raise_error(
    runtime: *Runtime,
    code: i32,
    message: [*c]const u8,
    length: i64,
    function: u32,
    instruction: u32,
) callconv(.c) void;
extern fn luce_rt_raise_io(
    runtime: *Runtime,
    act: i32,
    path: [*c]const u8,
    length: i64,
    function: u32,
    instruction: u32,
) callconv(.c) void;
extern fn luce_rt_intern_text(
    runtime: *Runtime,
    bytes: [*c]const u8,
    length: i64,
    out: [*c]Value,
) callconv(.c) i32;
extern fn luce_rt_maybe_text(
    runtime: *Runtime,
    present: i32,
    bytes: [*c]const u8,
    length: i64,
    out: [*c]Value,
) callconv(.c) i32;
extern fn luce_rt_names_list(
    runtime: *Runtime,
    bytes: [*c]const u8,
    length: i64,
    out: [*c]Value,
) callconv(.c) i32;
extern fn luce_rt_set_key_text(runtime: *Runtime, bytes: [*c]const u8, length: i64) callconv(.c) i32;
extern fn luce_rt_args_list(
    runtime: *Runtime,
    context: ?*anyopaque,
    count: ?*const fn (context: ?*anyopaque) callconv(.c) i64,
    get: ?containers.ArgumentFn,
    out: [*c]Value,
) callconv(.c) i32;
extern fn luce_rt_new_list(runtime: *Runtime, zero: [*c]const Value, out: [*c]Value) callconv(.c) i32;
extern fn luce_rt_new_map(runtime: *Runtime, out: [*c]Value) callconv(.c) i32;
extern fn luce_rt_new_builder(runtime: *Runtime, out: [*c]Value) callconv(.c) i32;
extern fn luce_rt_new_array(
    runtime: *Runtime,
    dims: [*c]const i64,
    rank: i64,
    zero: [*c]const Value,
    out: [*c]Value,
) callconv(.c) i32;
extern fn luce_rt_struct_make(
    runtime: *Runtime,
    fields: [*c]const Value,
    count: i64,
    out: [*c]Value,
) callconv(.c) i32;
extern fn luce_rt_function_make(
    runtime: *Runtime,
    slots: [*c]const Value,
    count: i64,
    out: [*c]Value,
) callconv(.c) i32;
extern fn luce_rt_own_storage(runtime: *Runtime, held: [*c]const Value, out: [*c]Value) callconv(.c) i32;
extern fn luce_rt_export_storage(runtime: *Runtime, held: [*c]const Value, out: [*c]Value) callconv(.c) i32;
extern fn luce_rt_copy(runtime: *Runtime, held: [*c]const Value, out: [*c]Value) callconv(.c) i32;
extern fn luce_rt_bind(runtime: *Runtime, held: [*c]const Value, serial: u64, local: u32) callconv(.c) void;
extern fn luce_rt_unbind(runtime: *Runtime, held: [*c]const Value, serial: u64, local: u32) callconv(.c) void;
extern fn luce_rt_loosen_from_frame(runtime: *Runtime, held: [*c]const Value, serial: u64) callconv(.c) void;
extern fn luce_rt_free(
    runtime: *Runtime,
    held: [*c]const Value,
    owned: i32,
    serial: u64,
    local: u32,
) callconv(.c) i32;
extern fn luce_rt_give(
    runtime: *Runtime,
    held: [*c]const Value,
    owned: i32,
    serial: u64,
    local: u32,
    out: [*c]Value,
) callconv(.c) i32;
extern fn luce_rt_drop_storage(
    runtime: *Runtime,
    held: [*c]const Value,
    out: [*c]Value,
) callconv(.c) void;
extern fn luce_rt_append(runtime: *Runtime, target: [*c]const Value, held: [*c]const Value) callconv(.c) i32;
extern fn luce_rt_append_ascii(runtime: *Runtime, target: [*c]const Value, code: i64) callconv(.c) i32;
extern fn luce_rt_insert(
    runtime: *Runtime,
    target: [*c]const Value,
    index: i64,
    held: [*c]const Value,
) callconv(.c) i32;
extern fn luce_rt_remove(
    runtime: *Runtime,
    target: [*c]const Value,
    which: [*c]const Value,
) callconv(.c) i32;
extern fn luce_rt_sort(runtime: *Runtime, target: [*c]const Value) callconv(.c) i32;
extern fn luce_rt_reverse(runtime: *Runtime, target: [*c]const Value) callconv(.c) i32;
extern fn luce_rt_clear(runtime: *Runtime, target: [*c]const Value) callconv(.c) i32;
extern fn luce_rt_len(runtime: *Runtime, target: [*c]const Value, out: [*c]Value) callconv(.c) i32;
extern fn luce_rt_index_get(
    runtime: *Runtime,
    target: [*c]const Value,
    indices: [*c]const Value,
    rank: i64,
    out: [*c]Value,
) callconv(.c) i32;
extern fn luce_rt_index_set(
    runtime: *Runtime,
    target: [*c]const Value,
    indices: [*c]const Value,
    rank: i64,
    held: [*c]const Value,
) callconv(.c) i32;
extern fn luce_rt_list_slice(
    runtime: *Runtime,
    target: [*c]const Value,
    start: i64,
    end: i64,
    out: [*c]Value,
) callconv(.c) i32;
extern fn luce_rt_pop(runtime: *Runtime, target: [*c]const Value, out: [*c]Value) callconv(.c) i32;
extern fn luce_rt_has_key(
    runtime: *Runtime,
    target: [*c]const Value,
    key: [*c]const Value,
    out: [*c]Value,
) callconv(.c) i32;
extern fn luce_rt_key_at(
    runtime: *Runtime,
    target: [*c]const Value,
    index: i64,
    out: [*c]Value,
) callconv(.c) i32;
extern fn luce_rt_value_at(
    runtime: *Runtime,
    target: [*c]const Value,
    index: i64,
    out: [*c]Value,
) callconv(.c) i32;
extern fn luce_rt_dim_size(
    runtime: *Runtime,
    target: [*c]const Value,
    axis: i64,
    out: [*c]Value,
) callconv(.c) i32;
extern fn luce_rt_find(
    runtime: *Runtime,
    target: [*c]const Value,
    wanted: [*c]const Value,
    out: [*c]Value,
) callconv(.c) i32;
extern fn luce_rt_contains(
    runtime: *Runtime,
    target: [*c]const Value,
    wanted: [*c]const Value,
    out: [*c]Value,
) callconv(.c) i32;
extern fn luce_rt_map_keys(
    runtime: *Runtime,
    target: [*c]const Value,
    zero: [*c]const Value,
    out: [*c]Value,
) callconv(.c) i32;
extern fn luce_rt_map_values(
    runtime: *Runtime,
    target: [*c]const Value,
    zero: [*c]const Value,
    out: [*c]Value,
) callconv(.c) i32;
extern fn luce_rt_map_place(
    runtime: *Runtime,
    target: [*c]const Value,
    key: [*c]const Value,
    zero: [*c]const Value,
    out: [*c]Value,
) callconv(.c) i32;
extern fn luce_rt_map_get(
    runtime: *Runtime,
    target: [*c]const Value,
    key: [*c]const Value,
    out: [*c]Value,
) callconv(.c) i32;
extern fn luce_rt_array_fill(
    runtime: *Runtime,
    target: [*c]const Value,
    held: [*c]const Value,
) callconv(.c) i32;
extern fn luce_rt_concat(
    runtime: *Runtime,
    left: [*c]const Value,
    right: [*c]const Value,
    out: [*c]Value,
) callconv(.c) i32;
extern fn luce_rt_string_slice(
    runtime: *Runtime,
    held: [*c]const Value,
    start: i64,
    end: i64,
    out: [*c]Value,
) callconv(.c) i32;
extern fn luce_rt_string_byte(
    runtime: *Runtime,
    held: [*c]const Value,
    index: i64,
    out: [*c]Value,
) callconv(.c) i32;
extern fn luce_rt_string_find_byte(
    runtime: *Runtime,
    held: [*c]const Value,
    byte: i64,
    start: i64,
    out: [*c]Value,
) callconv(.c) i32;
extern fn luce_rt_parse_string(runtime: *Runtime, held: [*c]const Value, out: [*c]Value) callconv(.c) i32;
extern fn luce_rt_spawn(
    runtime: *Runtime,
    function: i64,
    arguments: [*c]const Value,
    count: i64,
    out: [*c]Value,
) callconv(.c) i32;
extern fn luce_rt_task_wait(runtime: *Runtime, task: [*c]const Value, out: [*c]Value) callconv(.c) i32;
extern fn luce_rt_file_open(
    runtime: *Runtime,
    path: [*c]const u8,
    length: i64,
    mode: i64,
    out: [*c]Value,
    opened: [*c]i32,
    function: u32,
    instruction: u32,
) callconv(.c) i32;
extern fn luce_rt_file_read_text(
    runtime: *Runtime,
    path: [*c]const u8,
    length: i64,
    out: [*c]Value,
    ok: [*c]i32,
    function: u32,
    instruction: u32,
) callconv(.c) i32;
extern fn luce_rt_file_write_text(
    runtime: *Runtime,
    path: [*c]const u8,
    path_length: i64,
    content: [*c]const u8,
    content_length: i64,
    mode: i64,
    ok: [*c]i32,
    function: u32,
    instruction: u32,
) callconv(.c) i32;
extern fn luce_rt_file_read(
    runtime: *Runtime,
    held: [*c]const Value,
    buffer: [*c]const Value,
    filled: [*c]i64,
    ok: [*c]i32,
    function: u32,
    instruction: u32,
) callconv(.c) i32;
extern fn luce_rt_file_write(
    runtime: *Runtime,
    held: [*c]const Value,
    buffer: [*c]const Value,
    count: i64,
    written: [*c]i64,
    ok: [*c]i32,
    function: u32,
    instruction: u32,
) callconv(.c) i32;
extern fn luce_rt_file_flush(
    runtime: *Runtime,
    held: [*c]const Value,
    ok: [*c]i32,
    function: u32,
    instruction: u32,
) callconv(.c) i32;
extern fn luce_rt_str(runtime: *Runtime, held: [*c]const Value, out: [*c]Value) callconv(.c) i32;
extern fn luce_rt_parse_int(runtime: *Runtime, held: [*c]const Value, out: [*c]Value) callconv(.c) i32;
extern fn luce_rt_parse_float(runtime: *Runtime, held: [*c]const Value, out: [*c]Value) callconv(.c) i32;
extern fn luce_rt_chr(runtime: *Runtime, code: i64, out: [*c]Value) callconv(.c) i32;
extern fn luce_rt_ord(runtime: *Runtime, held: [*c]const Value, out: [*c]Value) callconv(.c) i32;
extern fn luce_rt_struct_set(
    runtime: *Runtime,
    held: [*c]const Value,
    field: i64,
    to: [*c]const Value,
    out: [*c]Value,
) callconv(.c) i32;
extern fn luce_rt_compare(op: i32, left: [*c]const Value, right: [*c]const Value) callconv(.c) i32;
extern fn luce_rt_compare_long_double(op: i32, left: i64, right: f64) callconv(.c) i32;

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

test "C scalar lengths counts and tags fail closed without writing outputs" {
    try testing.expect(luce_rt_open(null, -1) == null);
    try testing.expect(luce_rt_open(null, 1) == null);

    const Host = struct {
        fn negativeCount(_: ?*anyopaque) callconv(.c) i64 {
            return -1;
        }
    };

    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;
    const bytes = "x";

    var out = Value.ofLong(99);
    try testing.expectEqual(@as(i32, 1), luce_rt_intern_text(runtime, bytes, -1, &out));
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    try testing.expectEqual(@as(i64, 99), out.asLong());
    runtime.pending = null;

    try testing.expectEqual(@as(i32, 1), luce_rt_maybe_text(runtime, 1, bytes, -1, &out));
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    try testing.expectEqual(@as(i64, 99), out.asLong());
    runtime.pending = null;

    // `present` is a Boolean produced by the compiler, not a general
    // truthy flag.  A damaged artifact must be rejected before the runtime
    // looks at the borrowed bytes or writes the result slot.
    for ([_]i32{ -1, 2 }) |raw| {
        out = Value.ofLong(99);
        try testing.expectEqual(@as(i32, 1), luce_rt_maybe_text(runtime, raw, null, 1, &out));
        try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
        try testing.expectEqual(@as(i64, 99), out.asLong());
        runtime.pending = null;
    }

    try testing.expectEqual(@as(i32, 1), luce_rt_names_list(runtime, bytes, -1, &out));
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    try testing.expectEqual(@as(i64, 99), out.asLong());
    runtime.pending = null;

    try testing.expectEqual(@as(i32, 1), luce_rt_set_key_text(runtime, bytes, -1));
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    runtime.pending = null;

    try testing.expectEqual(@as(i32, 1), luce_rt_args_list(runtime, null, Host.negativeCount, null, &out));
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    try testing.expectEqual(@as(i64, 99), out.asLong());
    runtime.pending = null;

    const dims = [_]i64{1};
    try testing.expectEqual(@as(i32, 1), luce_rt_new_array(runtime, &dims, -1, &Value.none, &out));
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    try testing.expectEqual(@as(i64, 99), out.asLong());
    runtime.pending = null;

    const fields = [_]Value{Value.ofLong(1)};
    try testing.expectEqual(@as(i32, 1), luce_rt_struct_make(runtime, &fields, -1, &out));
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    try testing.expectEqual(@as(i64, 99), out.asLong());
    runtime.pending = null;

    try testing.expectEqual(@as(i32, 1), luce_rt_function_make(runtime, &fields, -1, &out));
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    try testing.expectEqual(@as(i64, 99), out.asLong());
    runtime.pending = null;

    const indices = [_]Value{Value.ofLong(0)};
    try testing.expectEqual(@as(i32, 1), luce_rt_index_get(runtime, &Value.none, &indices, -1, &out));
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    try testing.expectEqual(@as(i64, 99), out.asLong());
    runtime.pending = null;

    try testing.expectEqual(@as(i32, 1), luce_rt_index_set(runtime, &Value.none, &indices, -1, &Value.none));
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    runtime.pending = null;

    const arguments = [_]Value{Value.ofLong(1)};
    try testing.expectEqual(@as(i32, 1), luce_rt_spawn(runtime, 0, &arguments, -1, &out));
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    try testing.expectEqual(@as(i64, 99), out.asLong());
    runtime.pending = null;

    var opened: i32 = 17;
    try testing.expectEqual(
        @as(i32, 1),
        luce_rt_file_open(runtime, bytes, -1, @intFromEnum(files.Mode.read), &out, &opened, 0, 0),
    );
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    try testing.expectEqual(@as(i64, 99), out.asLong());
    try testing.expectEqual(@as(i32, 17), opened);
    runtime.pending = null;

    var ok: i32 = 23;
    try testing.expectEqual(
        @as(i32, 1),
        luce_rt_file_read_text(runtime, bytes, -1, &out, &ok, 0, 0),
    );
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    try testing.expectEqual(@as(i64, 99), out.asLong());
    try testing.expectEqual(@as(i32, 23), ok);
    runtime.pending = null;

    try testing.expectEqual(
        @as(i32, 1),
        luce_rt_file_write_text(runtime, bytes, 1, bytes, -1, @intFromEnum(files.Mode.write), &ok, 0, 0),
    );
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    try testing.expectEqual(@as(i32, 23), ok);
    runtime.pending = null;

    out = Value.ofLong(99);
    try testing.expectEqual(@as(i32, 0), luce_rt_maybe_text(runtime, 0, bytes, -1, &out));
    try testing.expect(out.isNone());

    luce_rt_raise(runtime, std.math.maxInt(i32), bytes, 1);
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    runtime.pending = null;
    luce_rt_raise_error(runtime, std.math.maxInt(i32), bytes, 1, 0, 0);
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    runtime.pending = null;
    luce_rt_raise_io(runtime, std.math.maxInt(i32), bytes, 1, 0, 0);
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    runtime.pending = null;

    try testing.expectEqual(
        @as(i32, 1),
        luce_rt_file_write_text(runtime, bytes, 1, bytes, 1, 99, &ok, 0, 0),
    );
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    try testing.expectEqual(@as(i32, 23), ok);
    runtime.pending = null;

    try testing.expectEqual(@as(i32, 0), luce_rt_compare(999, &Value.ofLong(1), &Value.ofLong(1)));
    try testing.expectEqual(
        @as(i32, 0),
        luce_rt_compare_long_double(999, 1, 1.0),
    );
}

test "C byte pointers reject null before slicing or host access" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;
    const null_bytes: [*c]const u8 = null;
    const bytes = "path";
    var out = Value.ofLong(99);

    try testing.expectEqual(
        @as(i32, 1),
        luce_rt_intern_text(runtime, null_bytes, 1, &out),
    );
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    try testing.expectEqual(@as(i64, 99), out.asLong());
    runtime.pending = null;

    try testing.expectEqual(
        @as(i32, 1),
        luce_rt_maybe_text(runtime, 1, null_bytes, 1, &out),
    );
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    try testing.expectEqual(@as(i64, 99), out.asLong());
    runtime.pending = null;

    try testing.expectEqual(
        @as(i32, 1),
        luce_rt_names_list(runtime, null_bytes, 1, &out),
    );
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    try testing.expectEqual(@as(i64, 99), out.asLong());
    runtime.pending = null;

    try testing.expectEqual(@as(i32, 1), luce_rt_set_key_text(runtime, null_bytes, 1));
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    runtime.pending = null;

    var opened: i32 = 17;
    try testing.expectEqual(
        @as(i32, 1),
        luce_rt_file_open(
            runtime,
            null_bytes,
            1,
            @intFromEnum(files.Mode.read),
            &out,
            &opened,
            0,
            0,
        ),
    );
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    try testing.expectEqual(@as(i64, 99), out.asLong());
    try testing.expectEqual(@as(i32, 17), opened);
    runtime.pending = null;

    var ok: i32 = 23;
    try testing.expectEqual(
        @as(i32, 1),
        luce_rt_file_read_text(runtime, null_bytes, 1, &out, &ok, 0, 0),
    );
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    try testing.expectEqual(@as(i64, 99), out.asLong());
    try testing.expectEqual(@as(i32, 23), ok);
    runtime.pending = null;

    try testing.expectEqual(
        @as(i32, 1),
        luce_rt_file_write_text(
            runtime,
            null_bytes,
            1,
            bytes,
            bytes.len,
            @intFromEnum(files.Mode.write),
            &ok,
            0,
            0,
        ),
    );
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    try testing.expectEqual(@as(i32, 23), ok);
    runtime.pending = null;

    try testing.expectEqual(
        @as(i32, 1),
        luce_rt_file_write_text(
            runtime,
            bytes,
            bytes.len,
            null_bytes,
            1,
            @intFromEnum(files.Mode.write),
            &ok,
            0,
            0,
        ),
    );
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    try testing.expectEqual(@as(i32, 23), ok);
    runtime.pending = null;

    luce_rt_raise(runtime, 0, null_bytes, 1);
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    runtime.pending = null;
    luce_rt_raise_error(runtime, 0, null_bytes, 1, 0, 0);
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    runtime.pending = null;
    luce_rt_raise_io(runtime, 0, null_bytes, 1, 0, 0);
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    runtime.pending = null;

    // An absent optional result does not read the byte pointer at all;
    // the null buffer is therefore irrelevant and the call succeeds.
    out = Value.ofLong(99);
    try testing.expectEqual(@as(i32, 0), luce_rt_maybe_text(runtime, 0, null_bytes, 1, &out));
    try testing.expect(out.isNone());

    // A non-null pointer can still describe a byte run whose endpoint wraps
    // the host address space.  Every C text/path/message door shares
    // checkedBytes, so exercise several consumers without ever dereferencing
    // the forged pointer.
    const wrapping_bytes: [*c]const u8 = @ptrFromInt(std.math.maxInt(usize) - 3);
    out = Value.ofLong(99);
    try testing.expectEqual(@as(i32, 1), luce_rt_intern_text(runtime, wrapping_bytes, 8, &out));
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    try testing.expectEqual(@as(i64, 99), out.asLong());
    runtime.pending = null;

    try testing.expectEqual(@as(i32, 1), luce_rt_names_list(runtime, wrapping_bytes, 8, &out));
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    try testing.expectEqual(@as(i64, 99), out.asLong());
    runtime.pending = null;

    try testing.expectEqual(@as(i32, 1), luce_rt_set_key_text(runtime, wrapping_bytes, 8));
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    runtime.pending = null;

    try testing.expectEqual(@as(i32, 1), luce_rt_maybe_text(runtime, 1, wrapping_bytes, 8, &out));
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    try testing.expectEqual(@as(i64, 99), out.asLong());
    runtime.pending = null;

    luce_rt_raise(runtime, 0, wrapping_bytes, 8);
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    runtime.pending = null;
    luce_rt_raise_error(runtime, 0, wrapping_bytes, 8, 0, 0);
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    runtime.pending = null;
    luce_rt_raise_io(runtime, 0, wrapping_bytes, 8, 0, 0);
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    runtime.pending = null;
}

fn expectCNullValueTrap(runtime: *Runtime, status: i32) !void {
    try testing.expectEqual(@as(i32, 1), status);
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    runtime.pending = null;
}

test "C ownership verbs reject forged value tags without releasing a live row" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    var live: Value = .none;
    try testing.expectEqual(@as(i32, 0), luce_rt_new_list(runtime, &Value.none, &live));
    try testing.expectEqual(@as(u32, 1), runtime.live);

    // The first object row is index zero with generation zero.  A scalar
    // carrying zero therefore looks like a tempting forged object handle
    // to code that forgets to check the tag before resolving it.
    const forged = Value.ofLong(0);
    var out = Value.ofLong(99);

    try testing.expectEqual(@as(i32, 1), luce_rt_free(runtime, &forged, 0, 0, 0));
    try testing.expectEqual(vocabulary.TrapCode.not_owned, runtime.pending.?.code);
    try testing.expectEqual(@as(u32, 1), runtime.live);
    runtime.pending = null;

    try testing.expectEqual(@as(i32, 1), luce_rt_give(runtime, &forged, 0, 0, 0, &out));
    try testing.expectEqual(vocabulary.TrapCode.not_owned, runtime.pending.?.code);
    try testing.expectEqual(@as(i64, 99), out.asLong());
    try testing.expectEqual(@as(u32, 1), runtime.live);
    runtime.pending = null;

    try testing.expectEqual(@as(i32, 1), luce_rt_copy(runtime, &forged, &out));
    try testing.expectEqual(vocabulary.TrapCode.not_owned, runtime.pending.?.code);
    try testing.expectEqual(@as(i64, 99), out.asLong());
    try testing.expectEqual(@as(u32, 1), runtime.live);
    runtime.pending = null;

    const bogus_fields = [_]Value{Value.ofLong(1)};
    const malformed_record = Value{
        .tag = .long,
        .bits = @intFromPtr(&bogus_fields),
        .length = 1,
    };
    try testing.expectEqual(@as(i32, 1), luce_rt_struct_set(runtime, &malformed_record, 0, &forged, &out));
    try testing.expectEqual(vocabulary.TrapCode.not_owned, runtime.pending.?.code);
    try testing.expectEqual(@as(i64, 99), out.asLong());
    try testing.expectEqual(@as(u32, 1), runtime.live);
    runtime.pending = null;

    // An invalid Boolean is rejected before the ownership verb can even
    // inspect its binding identity.
    try testing.expectEqual(@as(i32, 1), luce_rt_free(runtime, &live, 2, 0, 0));
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    try testing.expectEqual(@as(u32, 1), runtime.live);
    runtime.pending = null;
}

fn expectCNullValueVoid(runtime: *Runtime) !void {
    try testing.expectEqual(vocabulary.TrapCode.host_unavailable, runtime.pending.?.code);
    runtime.pending = null;
}

fn expectCTrapCode(runtime: *Runtime, status: i32, code: vocabulary.TrapCode) !void {
    try testing.expectEqual(@as(i32, 1), status);
    try testing.expectEqual(code, runtime.pending.?.code);
    runtime.pending = null;
}

test "C container doors reject wrong tags and object shapes before mutation" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;

    var list: Value = .none;
    try testing.expectEqual(@as(i32, 0), luce_rt_new_list(runtime, &Value.none, &list));
    const forged_scalar = Value.ofLong(0);
    const index = [_]Value{Value.ofLong(0)};
    var out = Value.ofLong(99);

    // A scalar with object-like bits is rejected before any resolver sees it.
    try expectCTrapCode(runtime, luce_rt_len(runtime, &forged_scalar, &out), .not_owned);
    try testing.expectEqual(@as(i64, 99), out.asLong());
    try expectCTrapCode(runtime, luce_rt_index_get(runtime, &forged_scalar, &index, 1, &out), .not_owned);
    try testing.expectEqual(@as(i64, 99), out.asLong());
    try expectCTrapCode(runtime, luce_rt_append_ascii(runtime, &forged_scalar, 'x'), .not_owned);
    try expectCTrapCode(runtime, luce_rt_parse_string(runtime, &forged_scalar, &out), .not_owned);
    try testing.expectEqual(@as(i64, 99), out.asLong());
    try expectCTrapCode(runtime, luce_rt_string_slice(runtime, &forged_scalar, 0, 1, &out), .not_owned);
    try testing.expectEqual(@as(i64, 99), out.asLong());

    // An object tag alone is not enough: map-only doors must also validate
    // the row's data variant before reading union fields.
    try expectCTrapCode(runtime, luce_rt_map_get(runtime, &list, &Value.ofLong(0), &out), .not_owned);
    try testing.expectEqual(@as(i64, 99), out.asLong());
    try expectCTrapCode(runtime, luce_rt_key_at(runtime, &list, 0, &out), .not_owned);
    try testing.expectEqual(@as(i64, 99), out.asLong());
    try expectCTrapCode(runtime, luce_rt_value_at(runtime, &list, 0, &out), .not_owned);
    try testing.expectEqual(@as(i64, 99), out.asLong());
    try expectCTrapCode(runtime, luce_rt_map_keys(runtime, &list, &Value.none, &out), .not_owned);
    try testing.expectEqual(@as(i64, 99), out.asLong());
    try expectCTrapCode(runtime, luce_rt_map_values(runtime, &list, &Value.none, &out), .not_owned);
    try testing.expectEqual(@as(i64, 99), out.asLong());
    try expectCTrapCode(runtime, luce_rt_map_place(runtime, &list, &Value.ofLong(0), &Value.none, &out), .not_owned);
    try testing.expectEqual(@as(i64, 99), out.asLong());
    try expectCTrapCode(runtime, luce_rt_array_fill(runtime, &list, &Value.none), .not_owned);
    try testing.expectEqual(@as(u32, 1), runtime.live);

    // `string(builder)` accepts only a Builder object.  A list must not be
    // interpreted through the builder arm of the same union.
    try expectCTrapCode(runtime, luce_rt_str(runtime, &list, &out), .not_owned);
    try testing.expectEqual(@as(i64, 99), out.asLong());
    var map: Value = .none;
    try testing.expectEqual(@as(i32, 0), luce_rt_new_map(runtime, &map));
    const map_key = Value.ofString("stored key");
    const map_zero = Value.ofLong(17);
    try testing.expectEqual(@as(i32, 0), luce_rt_map_place(runtime, &map, &map_key, &map_zero, &out));
    const forged_key = Value.ofBoolean(true);
    try expectCTrapCode(runtime, luce_rt_map_get(runtime, &map, &forged_key, &out), .not_owned);
    try expectCTrapCode(runtime, luce_rt_index_get(runtime, &map, &forged_key, 1, &out), .not_owned);
    try expectCTrapCode(runtime, luce_rt_map_place(runtime, &map, &forged_key, &map_zero, &out), .not_owned);
    try testing.expectEqual(@as(i64, 17), (try containers.mapGet(runtime, map, map_key)).asLong());

    var malformed_inline = Value.ofInlineText(.string, "x");
    malformed_inline.inline_length = value.inline_capacity + 1;
    try expectCTrapCode(runtime, luce_rt_string_slice(runtime, &malformed_inline, 0, 1, &out), .not_owned);
    var malformed_outside: Value = .{
        .tag = .string,
        .inline_length = value.text_outside,
        .bits = 0,
        .length = 1,
    };
    try expectCTrapCode(runtime, luce_rt_string_byte(runtime, &malformed_outside, 0, &out), .not_owned);

    const wrapping_string: Value = .{
        .tag = .string,
        .inline_length = value.text_outside,
        .bits = std.math.maxInt(u64) - 3,
        .length = 8,
    };
    try expectCTrapCode(runtime, luce_rt_string_byte(runtime, &wrapping_string, 0, &out), .not_owned);

    const aligned_wrapping_run: Value = .{
        .tag = .strukt,
        .bits = @intCast(std.math.maxInt(usize) - (@alignOf(Value) - 1)),
        .length = 1,
    };
    try expectCTrapCode(runtime, luce_rt_copy(runtime, &aligned_wrapping_run, &out), .not_owned);

    var invalid_function_slots = [_]Value{ Value.ofLong(1), Value.none, Value.none };
    const invalid_function = Value.ofFunction(&invalid_function_slots);
    try expectCTrapCode(runtime, luce_rt_copy(runtime, &invalid_function, &out), .not_owned);
    try expectCTrapCode(
        runtime,
        luce_rt_function_make(runtime, &invalid_function_slots, invalid_function_slots.len, &out),
        .not_owned,
    );

    const overflowing_left: Value = .{
        .tag = .string,
        .inline_length = value.text_outside,
        .bits = 1,
        .length = @intCast(std.math.maxInt(usize) - 3),
    };
    const overflowing_right: Value = .{
        .tag = .string,
        .inline_length = value.text_outside,
        .bits = 1,
        .length = 8,
    };
    out = Value.ofLong(99);
    try testing.expectEqual(
        @as(i32, 1),
        luce_rt_concat(runtime, &overflowing_left, &overflowing_right, &out),
    );
    try testing.expect(runtime.exhausted);
    try testing.expectEqual(@as(i64, 99), out.asLong());
    runtime.exhausted = false;

    out = Value.ofLong(99);
    // Composite values carry a pointer/length run too.  A null run with a
    // nonzero length must be rejected before give/copy or any ownership walk
    // can reinterpret it as an empty or foreign graph.  Function values are
    // additionally required to retain their fixed two-slot representation.
    const malformed_struct: Value = .{ .tag = .strukt, .length = 1 };
    try expectCTrapCode(runtime, luce_rt_copy(runtime, &malformed_struct, &out), .not_owned);
    try testing.expectEqual(@as(i64, 99), out.asLong());
    try expectCTrapCode(runtime, luce_rt_give(runtime, &malformed_struct, 0, 0, 0, &out), .not_owned);
    try testing.expectEqual(@as(i64, 99), out.asLong());
    const malformed_function: Value = .{ .tag = .function, .length = 2 };
    try expectCTrapCode(runtime, luce_rt_copy(runtime, &malformed_function, &out), .not_owned);
    try testing.expectEqual(@as(i64, 99), out.asLong());

    try testing.expectEqual(@as(i64, 17), (try containers.mapGet(runtime, map, map_key)).asLong());
    try testing.expectEqual(@as(i64, 2), luce_rt_leaked(runtime));
}

test "C Value output pointers reject null before work" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;
    const null_out: [*c]Value = null;
    const held = Value.ofLong(7);
    const text_value = Value.ofString("value output");
    const bytes = "path";
    const dimensions = [_]i64{2};
    const fields = [_]Value{Value.ofLong(1)};
    const indices = [_]Value{Value.ofLong(0)};

    luce_rt_error_message(runtime, null_out);
    try expectCNullValueVoid(runtime);
    luce_rt_key_text(runtime, null_out);
    try expectCNullValueVoid(runtime);
    luce_rt_constant_load(runtime, 0, null_out);
    try expectCNullValueVoid(runtime);

    try expectCNullValueTrap(runtime, luce_rt_intern_text(runtime, bytes, bytes.len, null_out));
    try expectCNullValueTrap(runtime, luce_rt_maybe_text(runtime, 0, null, 1, null_out));
    try expectCNullValueTrap(runtime, luce_rt_names_list(runtime, bytes, bytes.len, null_out));
    try expectCNullValueTrap(runtime, luce_rt_args_list(runtime, null, null, null, null_out));

    try expectCNullValueTrap(runtime, luce_rt_new_list(runtime, &Value.none, null_out));
    try expectCNullValueTrap(runtime, luce_rt_new_map(runtime, null_out));
    try expectCNullValueTrap(runtime, luce_rt_new_builder(runtime, null_out));
    try expectCNullValueTrap(runtime, luce_rt_new_array(runtime, &dimensions, dimensions.len, &Value.none, null_out));
    try expectCNullValueTrap(runtime, luce_rt_struct_make(runtime, &fields, fields.len, null_out));
    try expectCNullValueTrap(runtime, luce_rt_function_make(runtime, &fields, fields.len, null_out));

    try expectCNullValueTrap(runtime, luce_rt_own_storage(runtime, &text_value, null_out));
    try expectCNullValueTrap(runtime, luce_rt_export_storage(runtime, &text_value, null_out));
    try expectCNullValueTrap(runtime, luce_rt_give(runtime, &held, 0, 0, 0, null_out));
    luce_rt_drop_storage(runtime, &held, null_out);
    try expectCNullValueVoid(runtime);
    try expectCNullValueTrap(runtime, luce_rt_copy(runtime, &held, null_out));
    try expectCNullValueTrap(runtime, luce_rt_parse_string(runtime, &held, null_out));
    try expectCNullValueTrap(runtime, luce_rt_struct_set(runtime, &held, 0, &held, null_out));

    try expectCNullValueTrap(runtime, luce_rt_spawn(runtime, 0, &fields, fields.len, null_out));
    try expectCNullValueTrap(runtime, luce_rt_task_wait(runtime, &held, null_out));

    var opened: i32 = 17;
    try expectCNullValueTrap(
        runtime,
        luce_rt_file_open(runtime, bytes, bytes.len, @intFromEnum(files.Mode.read), null_out, &opened, 0, 0),
    );
    try testing.expectEqual(@as(i32, 17), opened);
    var ok: i32 = 23;
    try expectCNullValueTrap(runtime, luce_rt_file_read_text(runtime, bytes, bytes.len, null_out, &ok, 0, 0));
    try testing.expectEqual(@as(i32, 23), ok);

    try expectCNullValueTrap(runtime, luce_rt_len(runtime, &held, null_out));
    try expectCNullValueTrap(runtime, luce_rt_index_get(runtime, &held, &indices, indices.len, null_out));
    try expectCNullValueTrap(runtime, luce_rt_list_slice(runtime, &held, 0, 1, null_out));
    try expectCNullValueTrap(runtime, luce_rt_pop(runtime, &held, null_out));
    try expectCNullValueTrap(runtime, luce_rt_has_key(runtime, &held, &held, null_out));
    try expectCNullValueTrap(runtime, luce_rt_key_at(runtime, &held, 0, null_out));
    try expectCNullValueTrap(runtime, luce_rt_value_at(runtime, &held, 0, null_out));
    try expectCNullValueTrap(runtime, luce_rt_dim_size(runtime, &held, 0, null_out));
    try expectCNullValueTrap(runtime, luce_rt_find(runtime, &held, &held, null_out));
    try expectCNullValueTrap(runtime, luce_rt_contains(runtime, &held, &held, null_out));
    try expectCNullValueTrap(runtime, luce_rt_map_keys(runtime, &held, &held, null_out));
    try expectCNullValueTrap(runtime, luce_rt_map_values(runtime, &held, &held, null_out));
    try expectCNullValueTrap(runtime, luce_rt_map_get(runtime, &held, &held, null_out));
    try expectCNullValueTrap(runtime, luce_rt_map_place(runtime, &held, &held, &held, null_out));

    try expectCNullValueTrap(runtime, luce_rt_concat(runtime, &text_value, &text_value, null_out));
    try expectCNullValueTrap(runtime, luce_rt_string_slice(runtime, &text_value, 0, 1, null_out));
    try expectCNullValueTrap(runtime, luce_rt_string_byte(runtime, &text_value, 0, null_out));
    try expectCNullValueTrap(runtime, luce_rt_string_find_byte(runtime, &text_value, 'v', 0, null_out));
    try expectCNullValueTrap(runtime, luce_rt_str(runtime, &held, null_out));
    try expectCNullValueTrap(runtime, luce_rt_parse_int(runtime, &text_value, null_out));
    try expectCNullValueTrap(runtime, luce_rt_parse_float(runtime, &text_value, null_out));
    try expectCNullValueTrap(runtime, luce_rt_chr(runtime, 'v', null_out));
    try expectCNullValueTrap(runtime, luce_rt_ord(runtime, &text_value, null_out));

    try testing.expectEqual(@as(u32, 0), runtime.live);
    runtime.debugAssertInvariants();
}

test "C status output pointers reject null before host file work" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;
    const bytes = "path";
    const held = Value.none;
    var out = Value.ofLong(99);
    const opened: i32 = 17;
    var ok: i32 = 23;
    var filled: i64 = 29;
    var written: i64 = 31;
    const null_i32: [*c]i32 = null;
    const null_i64: [*c]i64 = null;

    try expectCNullValueTrap(
        runtime,
        luce_rt_file_open(
            runtime,
            bytes,
            bytes.len,
            @intFromEnum(files.Mode.read),
            &out,
            null_i32,
            0,
            0,
        ),
    );
    try testing.expectEqual(@as(i64, 99), out.asLong());
    try testing.expectEqual(@as(i32, 17), opened);

    try expectCNullValueTrap(
        runtime,
        luce_rt_file_read(runtime, &held, &held, null_i64, &ok, 0, 0),
    );
    try testing.expectEqual(@as(i32, 23), ok);
    try testing.expectEqual(@as(i64, 29), filled);
    try expectCNullValueTrap(
        runtime,
        luce_rt_file_read(runtime, &held, &held, &filled, null_i32, 0, 0),
    );
    try testing.expectEqual(@as(i64, 29), filled);

    try expectCNullValueTrap(
        runtime,
        luce_rt_file_write(runtime, &held, &held, 1, null_i64, &ok, 0, 0),
    );
    try testing.expectEqual(@as(i32, 23), ok);
    try testing.expectEqual(@as(i64, 31), written);
    try expectCNullValueTrap(
        runtime,
        luce_rt_file_write(runtime, &held, &held, 1, &written, null_i32, 0, 0),
    );
    try testing.expectEqual(@as(i64, 31), written);

    try expectCNullValueTrap(runtime, luce_rt_file_flush(runtime, &held, null_i32, 0, 0));
    try expectCNullValueTrap(
        runtime,
        luce_rt_file_read_text(runtime, bytes, bytes.len, &out, null_i32, 0, 0),
    );
    try testing.expectEqual(@as(i64, 99), out.asLong());
    try expectCNullValueTrap(
        runtime,
        luce_rt_file_write_text(
            runtime,
            bytes,
            bytes.len,
            bytes,
            bytes.len,
            @intFromEnum(files.Mode.write),
            null_i32,
            0,
            0,
        ),
    );

    try testing.expectEqual(@as(u32, 0), runtime.live);
    runtime.debugAssertInvariants();
}

test "C borrowed Value and array pointers reject null before work" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;
    const null_value: [*c]const Value = null;
    const null_values: [*c]const Value = null;
    const null_dims: [*c]const i64 = null;
    const held = Value.ofLong(7);
    const text_value = Value.ofString("borrowed input");
    const dimensions = [_]i64{2};
    const indices = [_]Value{Value.ofLong(0)};
    var out = Value.ofLong(99);
    var ok: i32 = 23;
    var filled: i64 = 29;
    var written: i64 = 31;

    try expectCNullValueTrap(runtime, luce_rt_constant_publish(runtime, 0, null_value));
    luce_rt_discard_loose(runtime, null_value);
    try expectCNullValueVoid(runtime);
    try expectCNullValueTrap(runtime, luce_rt_new_list(runtime, null_value, &out));
    try expectCNullValueTrap(runtime, luce_rt_new_array(runtime, null_dims, 1, &Value.none, &out));
    try expectCNullValueTrap(runtime, luce_rt_new_array(runtime, &dimensions, dimensions.len, null_value, &out));
    try expectCNullValueTrap(runtime, luce_rt_struct_make(runtime, null_values, 1, &out));
    try expectCNullValueTrap(runtime, luce_rt_function_make(runtime, null_values, 1, &out));

    luce_rt_bind(runtime, null_value, 1, 0);
    try expectCNullValueVoid(runtime);
    luce_rt_unbind(runtime, null_value, 1, 0);
    try expectCNullValueVoid(runtime);
    luce_rt_loosen_from_frame(runtime, null_value, 1);
    try expectCNullValueVoid(runtime);
    try expectCNullValueTrap(runtime, luce_rt_free(runtime, null_value, 0, 0, 0));
    try expectCNullValueTrap(runtime, luce_rt_give(runtime, null_value, 0, 0, 0, &out));
    try expectCNullValueTrap(runtime, luce_rt_own_storage(runtime, null_value, &out));
    try expectCNullValueTrap(runtime, luce_rt_export_storage(runtime, null_value, &out));
    luce_rt_drop_storage(runtime, null_value, &out);
    try expectCNullValueVoid(runtime);
    try expectCNullValueTrap(runtime, luce_rt_copy(runtime, null_value, &out));
    try expectCNullValueTrap(runtime, luce_rt_struct_set(runtime, null_value, 0, &held, &out));
    try expectCNullValueTrap(runtime, luce_rt_struct_set(runtime, &held, 0, null_value, &out));
    try expectCNullValueTrap(runtime, luce_rt_parse_string(runtime, null_value, &out));

    try expectCNullValueTrap(runtime, luce_rt_spawn(runtime, 0, null_values, 1, &out));
    try expectCNullValueTrap(runtime, luce_rt_task_wait(runtime, null_value, &out));

    try expectCNullValueTrap(
        runtime,
        luce_rt_file_read(runtime, null_value, &held, &filled, &ok, 0, 0),
    );
    try testing.expectEqual(@as(i64, 29), filled);
    try testing.expectEqual(@as(i32, 23), ok);
    try expectCNullValueTrap(
        runtime,
        luce_rt_file_read(runtime, &held, null_value, &filled, &ok, 0, 0),
    );
    try testing.expectEqual(@as(i64, 29), filled);
    try testing.expectEqual(@as(i32, 23), ok);
    try expectCNullValueTrap(
        runtime,
        luce_rt_file_write(runtime, null_value, &held, 1, &written, &ok, 0, 0),
    );
    try testing.expectEqual(@as(i64, 31), written);
    try testing.expectEqual(@as(i32, 23), ok);
    try expectCNullValueTrap(
        runtime,
        luce_rt_file_write(runtime, &held, null_value, 1, &written, &ok, 0, 0),
    );
    try testing.expectEqual(@as(i64, 31), written);
    try testing.expectEqual(@as(i32, 23), ok);
    try expectCNullValueTrap(runtime, luce_rt_file_flush(runtime, null_value, &ok, 0, 0));
    try testing.expectEqual(@as(i32, 23), ok);

    try expectCNullValueTrap(runtime, luce_rt_len(runtime, null_value, &out));
    try expectCNullValueTrap(runtime, luce_rt_index_get(runtime, null_value, &indices, 1, &out));
    try expectCNullValueTrap(runtime, luce_rt_index_get(runtime, &held, null_values, 1, &out));
    try expectCNullValueTrap(runtime, luce_rt_index_set(runtime, null_value, &indices, 1, &held));
    try expectCNullValueTrap(runtime, luce_rt_index_set(runtime, &held, null_values, 1, &held));
    try expectCNullValueTrap(runtime, luce_rt_index_set(runtime, &held, &indices, 1, null_value));
    try expectCNullValueTrap(runtime, luce_rt_list_slice(runtime, null_value, 0, 1, &out));
    try expectCNullValueTrap(runtime, luce_rt_append(runtime, null_value, &held));
    try expectCNullValueTrap(runtime, luce_rt_append(runtime, &held, null_value));
    try expectCNullValueTrap(runtime, luce_rt_append_ascii(runtime, null_value, 'x'));
    try expectCNullValueTrap(runtime, luce_rt_pop(runtime, null_value, &out));
    try expectCNullValueTrap(runtime, luce_rt_insert(runtime, null_value, 0, &held));
    try expectCNullValueTrap(runtime, luce_rt_insert(runtime, &held, 0, null_value));
    try expectCNullValueTrap(runtime, luce_rt_remove(runtime, null_value, &held));
    try expectCNullValueTrap(runtime, luce_rt_remove(runtime, &held, null_value));
    try expectCNullValueTrap(runtime, luce_rt_has_key(runtime, null_value, &held, &out));
    try expectCNullValueTrap(runtime, luce_rt_has_key(runtime, &held, null_value, &out));
    try expectCNullValueTrap(runtime, luce_rt_key_at(runtime, null_value, 0, &out));
    try expectCNullValueTrap(runtime, luce_rt_value_at(runtime, null_value, 0, &out));
    try expectCNullValueTrap(runtime, luce_rt_dim_size(runtime, null_value, 0, &out));
    try expectCNullValueTrap(runtime, luce_rt_sort(runtime, null_value));
    try expectCNullValueTrap(runtime, luce_rt_reverse(runtime, null_value));
    try expectCNullValueTrap(runtime, luce_rt_clear(runtime, null_value));
    try expectCNullValueTrap(runtime, luce_rt_find(runtime, null_value, &held, &out));
    try expectCNullValueTrap(runtime, luce_rt_find(runtime, &held, null_value, &out));
    try expectCNullValueTrap(runtime, luce_rt_contains(runtime, null_value, &held, &out));
    try expectCNullValueTrap(runtime, luce_rt_contains(runtime, &held, null_value, &out));
    try expectCNullValueTrap(runtime, luce_rt_map_keys(runtime, null_value, &held, &out));
    try expectCNullValueTrap(runtime, luce_rt_map_keys(runtime, &held, null_value, &out));
    try expectCNullValueTrap(runtime, luce_rt_map_values(runtime, null_value, &held, &out));
    try expectCNullValueTrap(runtime, luce_rt_map_values(runtime, &held, null_value, &out));
    try expectCNullValueTrap(runtime, luce_rt_map_get(runtime, null_value, &held, &out));
    try expectCNullValueTrap(runtime, luce_rt_map_get(runtime, &held, null_value, &out));
    try expectCNullValueTrap(runtime, luce_rt_map_place(runtime, null_value, &held, &held, &out));
    try expectCNullValueTrap(runtime, luce_rt_map_place(runtime, &held, null_value, &held, &out));
    try expectCNullValueTrap(runtime, luce_rt_map_place(runtime, &held, &held, null_value, &out));
    try expectCNullValueTrap(runtime, luce_rt_array_fill(runtime, null_value, &held));
    try expectCNullValueTrap(runtime, luce_rt_array_fill(runtime, &held, null_value));

    try expectCNullValueTrap(runtime, luce_rt_concat(runtime, null_value, &text_value, &out));
    try expectCNullValueTrap(runtime, luce_rt_concat(runtime, &text_value, null_value, &out));
    try expectCNullValueTrap(runtime, luce_rt_string_slice(runtime, null_value, 0, 1, &out));
    try expectCNullValueTrap(runtime, luce_rt_string_byte(runtime, null_value, 0, &out));
    try expectCNullValueTrap(runtime, luce_rt_string_find_byte(runtime, null_value, 'b', 0, &out));
    try expectCNullValueTrap(runtime, luce_rt_str(runtime, null_value, &out));
    try expectCNullValueTrap(runtime, luce_rt_parse_int(runtime, null_value, &out));
    try expectCNullValueTrap(runtime, luce_rt_parse_float(runtime, null_value, &out));
    try expectCNullValueTrap(runtime, luce_rt_ord(runtime, null_value, &out));

    try testing.expectEqual(@as(i32, 0), luce_rt_compare(0, null_value, &held));
    try testing.expectEqual(@as(i32, 0), luce_rt_compare(0, &held, null_value));
    try testing.expectEqual(@as(i32, 0), luce_rt_compare(0, null_value, null_value));
    try testing.expectEqual(@as(i64, 99), out.asLong());
    try testing.expectEqual(@as(i32, 23), ok);
    try testing.expectEqual(@as(i64, 29), filled);
    try testing.expectEqual(@as(i64, 31), written);
    try testing.expectEqual(@as(u32, 0), runtime.live);
    runtime.debugAssertInvariants();
}

test "C callbacks fail closed on null report and argument buffers" {
    var bench: Bench = undefined;
    bench.setup();
    defer bench.deinit();
    const runtime = &bench.runtime;
    var out = Value.ofLong(99);

    try expectCNullValueTrap(
        runtime,
        luce_rt_args_list(runtime, null, NullArgument.count, NullArgument.get, &out),
    );
    try testing.expectEqual(@as(i64, 99), out.asLong());
    try testing.expectEqual(@as(u32, 0), runtime.live);

    try expectCNullValueTrap(
        runtime,
        luce_rt_args_list(
            runtime,
            null,
            InvalidArgumentAnswer.count,
            InvalidArgumentAnswer.get,
            &out,
        ),
    );
    try testing.expectEqual(@as(i64, 99), out.asLong());
    try testing.expectEqual(@as(u32, 0), runtime.live);

    _ = runtime.fail(.host_unavailable) catch {};
    const pending_code = runtime.pending.?.code;
    luce_rt_report(runtime, null, null);
    try testing.expectEqual(pending_code, runtime.pending.?.code);
    runtime.pending = null;

    runtime.raise(.user_error, "callback report", .{
        .function = "main",
        .function_length = 4,
        .source = "callback.luc",
        .source_length = 13,
        .line = 1,
        .column = 1,
    });
    const raised_code = runtime.raised.?.code;
    luce_rt_report_error(runtime, null, null);
    try testing.expectEqual(raised_code, runtime.raised.?.code);
    runtime.raised = null;
    runtime.debugAssertInvariants();
}

test "allocating C doors preserve outputs and rows at every failure point" {
    const long_text = "a host string long enough to require owned storage";
    const dims = [_]i64{3};
    const fields = [_]Value{ Value.ofLong(1), Value.ofLong(2) };
    const slots = [_]Value{ Value.ofLong(3), Value.ofLong(4) };
    const doors = [_]CAllocationDoor{
        .new_list,
        .new_map,
        .new_builder,
        .new_array,
        .struct_make,
        .function_make,
        .intern_text,
        .own_storage,
        .names_list,
        .args_list,
    };

    for (doors) |door| {
        var failures: usize = 0;
        var completed = false;
        for (0..24) |failure_offset| {
            var objects: std.testing.FailingAllocator = .init(testing.allocator, .{});
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            var runtime: Runtime = .init(.{
                .arena = arena.allocator(),
                .objects = objects.allocator(),
            });
            var out = Value.ofLong(99);
            objects.fail_index = objects.alloc_index + failure_offset;

            const status = switch (door) {
                .new_list => luce_rt_new_list(&runtime, &Value.none, &out),
                .new_map => luce_rt_new_map(&runtime, &out),
                .new_builder => luce_rt_new_builder(&runtime, &out),
                .new_array => luce_rt_new_array(&runtime, &dims, dims.len, &Value.ofLong(0), &out),
                .struct_make => luce_rt_struct_make(&runtime, &fields, fields.len, &out),
                .function_make => luce_rt_function_make(&runtime, &slots, slots.len, &out),
                .intern_text => luce_rt_intern_text(&runtime, long_text, long_text.len, &out),
                .own_storage => luce_rt_own_storage(&runtime, &Value.ofString(long_text), &out),
                .names_list => luce_rt_names_list(&runtime, built_list_joined, built_list_joined.len, &out),
                .args_list => luce_rt_args_list(
                    &runtime,
                    null,
                    BuiltListArguments.count,
                    BuiltListArguments.get,
                    &out,
                ),
            };
            objects.fail_index = std.math.maxInt(usize);

            if (status == 0) {
                switch (door) {
                    .struct_make, .function_make, .intern_text, .own_storage => runtime.dropStorage(out),
                    else => runtime.freeValue(out),
                }
                completed = true;
            } else {
                try testing.expectEqual(@as(i32, 1), status);
                try testing.expectEqual(@as(i64, 99), out.asLong());
                try testing.expectEqual(@as(u32, 0), runtime.live);
                if (runtime.pending) |pending| {
                    try testing.expectEqual(CAllocationDoor.new_array, door);
                    try testing.expectEqual(vocabulary.TrapCode.allocation_failed, pending.code);
                } else {
                    try testing.expect(runtime.exhausted);
                }
                failures += 1;
            }

            try testing.expectEqual(@as(u32, 0), runtime.live);
            runtime.debugAssertInvariants();
            runtime.deinit();
            arena.deinit();
            try testing.expectEqual(objects.allocated_bytes, objects.freed_bytes);
            if (completed) break;
        }
        try testing.expect(completed);
        try testing.expect(failures >= 1);
    }
}

test "a function value allocation failure preserves its borrowed receiver graph" {
    const long_text = "receiver storage that needs its own allocation";
    var failures: usize = 0;
    var completed = false;

    // The receiver is a struct with both an object edge and outside text.
    // The function run receives a storage copy of that struct, but its
    // object edge remains borrowed from the original receiver.
    for (0..4) |failure_offset| {
        var objects: std.testing.FailingAllocator = .init(testing.allocator, .{});
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        var runtime: Runtime = .init(.{
            .arena = arena.allocator(),
            .objects = objects.allocator(),
        });
        var cleaned = false;
        defer if (!cleaned) {
            runtime.deinit();
            arena.deinit();
        };

        const list = try runtime.newList(Value.none);
        try containers.append(&runtime, list, Value.ofLong(7));
        const owned_text = try runtime.ownValue(Value.ofString(long_text));
        const receiver = try runtime.makeStruct(&.{ list, owned_text });
        const copied_receiver = try runtime.ownValue(receiver);
        var slots = [_]Value{ Value.ofInt(3), copied_receiver };
        var out = Value.ofLong(99);

        objects.fail_index = objects.alloc_index + failure_offset;
        const status = luce_rt_function_make(&runtime, &slots, slots.len, &out);
        objects.fail_index = std.math.maxInt(usize);

        if (status == 0) {
            try testing.expect(out.tag == .function);
            runtime.dropStorage(out);
            runtime.freeValue(receiver);
            completed = true;
        } else {
            try testing.expectEqual(@as(i32, 1), status);
            try testing.expectEqual(@as(i64, 99), out.asLong());
            try testing.expect(runtime.exhausted);
            const fields = receiver.asStruct();
            try testing.expectEqual(@as(i64, 1), (try containers.length(&runtime, fields[0])).asLong());
            try testing.expectEqualStrings(long_text, fields[1].asString());
            runtime.freeValue(receiver);
            failures += 1;
        }

        try testing.expectEqual(@as(u32, 0), runtime.live);
        runtime.debugAssertInvariants();
        runtime.deinit();
        arena.deinit();
        cleaned = true;
        try testing.expectEqual(objects.allocated_bytes, objects.freed_bytes);
        if (completed) break;
    }

    try testing.expect(completed);
    try testing.expect(failures >= 1);
}

test "allocating C value doors preserve graphs and slots at every failure point" {
    const long_text = "a C value door string long enough to require owned storage";
    const inline_text = Value.ofInlineText(.string, "inline return bytes");
    const previous_key = "the previous key text remains on a failed replacement";
    const next_key = "the next key text replaces it only after allocation succeeds";
    const doors = [_]CValueAllocationDoor{
        .export_storage,
        .copy,
        .list_slice,
        .map_keys,
        .map_values,
        .str,
        .set_key_text,
    };

    for (doors) |door| {
        var failures: usize = 0;
        var completed = false;
        for (0..64) |failure_offset| {
            var objects: std.testing.FailingAllocator = .init(testing.allocator, .{});
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            var runtime: Runtime = .init(.{
                .arena = arena.allocator(),
                .objects = objects.allocator(),
            });
            var cleaned = false;
            defer if (!cleaned) {
                runtime.deinit();
                arena.deinit();
            };

            const source = switch (door) {
                .copy, .list_slice => try nestedCopySource(&runtime, .list),
                .map_keys, .map_values => try nestedCopySource(&runtime, .map),
                else => Value.none,
            };
            const baseline_live = runtime.live;
            if (door == .set_key_text) {
                try testing.expectEqual(
                    @as(i32, 0),
                    luce_rt_set_key_text(&runtime, previous_key, previous_key.len),
                );
            }

            var out = Value.ofLong(99);
            objects.fail_index = objects.alloc_index + failure_offset;
            const status = switch (door) {
                .export_storage => luce_rt_export_storage(&runtime, &inline_text, &out),
                .copy => luce_rt_copy(&runtime, &source, &out),
                .list_slice => luce_rt_list_slice(&runtime, &source, 0, 2, &out),
                .map_keys => luce_rt_map_keys(&runtime, &source, &Value.ofString(""), &out),
                .map_values => luce_rt_map_values(&runtime, &source, &Value.none, &out),
                .str => luce_rt_str(&runtime, &Value.ofString(long_text), &out),
                .set_key_text => luce_rt_set_key_text(&runtime, next_key, next_key.len),
            };
            objects.fail_index = std.math.maxInt(usize);

            if (status == 0) {
                switch (door) {
                    .export_storage => {
                        try testing.expectEqualStrings(inline_text.asString(), out.asString());
                        try testing.expect(!out.textIsInline());
                        runtime.dropStorage(out);
                    },
                    .copy, .list_slice, .map_values => {
                        try expectNestedSourceIntact(&runtime, out, .list);
                        runtime.freeValue(out);
                    },
                    .map_keys => {
                        try testing.expectEqual(@as(i64, 2), (try containers.length(&runtime, out)).asLong());
                        try testing.expectEqualStrings(
                            "the first copied map key owns outside bytes",
                            (try containers.indexGet(&runtime, out, &.{Value.ofLong(0)})).asString(),
                        );
                        try testing.expectEqualStrings(
                            "the second copied map key owns outside bytes",
                            (try containers.indexGet(&runtime, out, &.{Value.ofLong(1)})).asString(),
                        );
                        runtime.freeValue(out);
                    },
                    .str => {
                        try testing.expectEqualStrings(long_text, out.asString());
                        try testing.expect(out.ownsStorage());
                        runtime.dropStorage(out);
                    },
                    .set_key_text => try testing.expectEqualStrings(next_key, runtime.last_key_text),
                }
                completed = true;
            } else {
                try testing.expectEqual(@as(i32, 1), status);
                try testing.expectEqual(@as(i64, 99), out.asLong());
                try testing.expect(runtime.pending == null);
                try testing.expect(runtime.exhausted);
                try testing.expect(objects.has_induced_failure);
                try testing.expectEqual(baseline_live, runtime.live);
                if (source.tag == .object) {
                    try expectNestedSourceIntact(
                        &runtime,
                        source,
                        if (door == .map_keys or door == .map_values) .map else .list,
                    );
                }
                if (door == .set_key_text) {
                    try testing.expectEqualStrings(previous_key, runtime.last_key_text);
                }
                failures += 1;
            }

            runtime.debugAssertInvariants();
            if (source.tag == .object) runtime.freeValue(source);
            runtime.debugAssertInvariants();
            try testing.expectEqual(@as(u32, 0), runtime.live);
            runtime.deinit();
            arena.deinit();
            cleaned = true;
            try testing.expectEqual(objects.allocated_bytes, objects.freed_bytes);
            if (completed) break;
        }
        try testing.expect(completed);
        try testing.expect(failures >= 1);
    }
}

test "C file acquisition closes raw handles through every allocation failure" {
    const path = "a file path long enough to require owned resource storage";
    const payload = "file text long enough to require an owned returned String";
    const content = "content written through the whole-file C door";
    const doors = [_]CFileAllocationDoor{ .open, .read_text, .write_text };

    for (doors) |door| {
        var failures: usize = 0;
        var completed = false;
        for (0..32) |failure_offset| {
            var state = CFileState.init(payload);
            var objects: std.testing.FailingAllocator = .init(testing.allocator, .{});
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            var runtime: Runtime = .init(.{
                .arena = arena.allocator(),
                .objects = objects.allocator(),
            });
            var cleaned = false;
            defer if (!cleaned) {
                runtime.deinit();
                arena.deinit();
            };
            state.install(&runtime);

            var out = Value.ofLong(99);
            var opened: i32 = 17;
            var ok: i32 = 23;
            objects.fail_index = objects.alloc_index + failure_offset;
            const status = switch (door) {
                .open => luce_rt_file_open(
                    &runtime,
                    path,
                    path.len,
                    @intFromEnum(files.Mode.read),
                    &out,
                    &opened,
                    0,
                    0,
                ),
                .read_text => luce_rt_file_read_text(
                    &runtime,
                    path,
                    path.len,
                    &out,
                    &ok,
                    0,
                    0,
                ),
                .write_text => luce_rt_file_write_text(
                    &runtime,
                    path,
                    path.len,
                    content,
                    content.len,
                    @intFromEnum(files.Mode.write),
                    &ok,
                    0,
                    0,
                ),
            };
            objects.fail_index = std.math.maxInt(usize);

            if (status == 0) {
                switch (door) {
                    .open => {
                        try testing.expectEqual(@as(i32, 1), opened);
                        try testing.expectEqual(@as(usize, 1), state.opens);
                        runtime.freeValue(out);
                    },
                    .read_text => {
                        try testing.expectEqual(@as(i32, 1), ok);
                        try testing.expectEqualStrings(payload, out.asString());
                        runtime.dropStorage(out);
                    },
                    .write_text => {
                        try testing.expectEqual(@as(i32, 1), ok);
                        try testing.expectEqual(content.len, state.written);
                        try testing.expectEqual(@as(usize, 1), state.writes);
                        try testing.expectEqual(@as(usize, 1), state.flushes);
                    },
                }
                completed = true;
            } else {
                try testing.expectEqual(@as(i32, 1), status);
                try testing.expectEqual(@as(i64, 99), out.asLong());
                try testing.expectEqual(@as(i32, 17), opened);
                try testing.expectEqual(@as(i32, 23), ok);
                try testing.expect(runtime.pending == null);
                try testing.expect(runtime.exhausted);
                try testing.expect(objects.has_induced_failure);
                failures += 1;
            }

            try testing.expectEqual(@as(usize, 1), state.opens);
            try testing.expectEqual(state.opens, state.closes);
            try testing.expect(!state.duplicate_close);
            try testing.expect(!state.unknown_close);
            try testing.expectEqual(@as(u32, 0), runtime.live);
            runtime.debugAssertInvariants();
            runtime.deinit();
            arena.deinit();
            cleaned = true;
            try testing.expectEqual(objects.allocated_bytes, objects.freed_bytes);
            if (completed) break;
        }
        try testing.expect(completed);
        try testing.expect(failures >= 1);
    }
}

test "the C spawn door rolls worker acquisition back before publishing a task" {
    var failures: usize = 0;
    var completed = false;
    for (0..32) |failure_offset| {
        var parent_objects: std.testing.FailingAllocator = .init(testing.allocator, .{});
        var parent_arena: std.heap.ArenaAllocator = .init(testing.allocator);
        var parent: Runtime = .init(.{
            .arena = parent_arena.allocator(),
            .objects = parent_objects.allocator(),
        });
        var child_arena: std.heap.ArenaAllocator = .init(testing.allocator);
        var child: Runtime = .init(.{
            .arena = child_arena.allocator(),
            .objects = testing.allocator,
        });
        var state: WorkerFailureState = .{
            .child = &child,
            .child_live_at_close = std.math.maxInt(u32),
        };
        state.install(&parent);
        var cleaned = false;
        defer if (!cleaned) {
            if (state.closes == 0) child.deinit();
            parent.deinit();
            parent_arena.deinit();
            child_arena.deinit();
        };

        var out = Value.ofLong(99);
        parent_objects.fail_index = parent_objects.alloc_index + failure_offset;
        // The generated ABI passes a null argument pointer for an empty
        // call.  It is valid at count zero, including on every rollback
        // point exercised by this failing allocator sweep.
        const status = luce_rt_spawn(&parent, 0, null, 0, &out);
        parent_objects.fail_index = std.math.maxInt(usize);

        if (status == 0) {
            try testing.expect(out.tag == .object);
            parent.freeValue(out);
            try testing.expectEqual(@as(usize, 1), state.spawns);
            try testing.expectEqual(@as(usize, 1), state.joins);
            completed = true;
        } else {
            try testing.expectEqual(@as(i32, 1), status);
            try testing.expectEqual(@as(i64, 99), out.asLong());
            try testing.expect(parent.pending == null);
            try testing.expect(parent.exhausted);
            try testing.expect(parent_objects.has_induced_failure);
            try testing.expectEqual(@as(u32, 0), parent.live);
            failures += 1;
        }

        try testing.expectEqual(state.spawns, state.joins);
        try testing.expectEqual(state.joins, state.closes);
        if (state.closes != 0) try testing.expectEqual(@as(u32, 0), state.child_live_at_close);
        try testing.expectEqual(@as(u32, 0), parent.live);
        parent.debugAssertInvariants();
        parent.deinit();
        parent_arena.deinit();
        child_arena.deinit();
        cleaned = true;
        try testing.expectEqual(parent_objects.allocated_bytes, parent_objects.freed_bytes);
        if (completed) break;
    }
    try testing.expect(completed);
    try testing.expect(failures >= 1);
}

test "C task wait rolls nested result transfer back and detaches exactly once" {
    const doors = [_]CTaskAllocationDoor{.wait_result};
    for (doors) |door| {
        var failures: usize = 0;
        var completed = false;
        for (0..64) |failure_offset| {
            var parent_objects: std.testing.FailingAllocator = .init(testing.allocator, .{});
            var parent_arena: std.heap.ArenaAllocator = .init(testing.allocator);
            var parent: Runtime = .init(.{
                .arena = parent_arena.allocator(),
                .objects = parent_objects.allocator(),
            });
            var child_arena: std.heap.ArenaAllocator = .init(testing.allocator);
            var child: Runtime = .init(.{
                .arena = child_arena.allocator(),
                .objects = testing.allocator,
            });
            var state: WorkerFailureState = .{
                .child = &child,
                .produce_graph = true,
                .child_live_at_close = std.math.maxInt(u32),
            };
            state.install(&parent);
            var cleaned = false;
            defer if (!cleaned) {
                parent.deinit();
                parent_arena.deinit();
                child_arena.deinit();
            };

            var task: Value = .none;
            try testing.expectEqual(@as(i32, 0), luce_rt_spawn(&parent, 0, &.{}, 0, &task));
            try testing.expect(task.tag == .object);
            const task_live = parent.live;

            var answer = Value.ofLong(99);
            parent_objects.fail_index = parent_objects.alloc_index + failure_offset;
            const status = switch (door) {
                .wait_result => luce_rt_task_wait(&parent, &task, &answer),
            };
            parent_objects.fail_index = std.math.maxInt(usize);

            if (status == 0) {
                try testing.expectEqual(workers.survived, status);
                try testing.expect(state.ran);
                try testing.expectEqual(@as(usize, 1), state.joins);
                try testing.expectEqual(@as(usize, 1), state.closes);
                try testing.expectEqual(@as(u32, 0), state.child_live_at_close);
                try testing.expect(answer.tag == .strukt);
                const fields = answer.asStruct();
                try testing.expectEqual(@as(usize, 2), fields.len);
                try testing.expectEqualStrings(
                    "worker graph result has outside storage",
                    fields[1].asString(),
                );
                const branch = fields[0];
                try testing.expectEqual(@as(i64, 1), (try containers.length(&parent, branch)).asLong());
                const leaf = try containers.indexGet(&parent, branch, &.{Value.ofLong(0)});
                try testing.expectEqual(@as(i64, 11), (try containers.indexGet(
                    &parent,
                    leaf,
                    &.{Value.ofLong(0)},
                )).asLong());
                parent.freeValue(answer);
                completed = true;
            } else {
                try testing.expectEqual(@as(i32, 1), status);
                try testing.expectEqual(@as(i64, 99), answer.asLong());
                try testing.expect(state.ran);
                try testing.expect(parent.exhausted);
                try testing.expect(parent.pending == null);
                try testing.expect(parent.live == task_live);
                try testing.expect(state.joins == 1);
                try testing.expect(state.closes == 1);
                try testing.expectEqual(@as(u32, 0), state.child_live_at_close);
                failures += 1;
            }

            // `wait` detaches before copying.  A second C wait must trap
            // without joining or touching the sentinel result, regardless
            // of whether the first wait copied or failed.
            var second = Value.ofLong(77);
            try testing.expectEqual(@as(i32, 1), luce_rt_task_wait(&parent, &task, &second));
            try testing.expectEqual(@as(i64, 77), second.asLong());
            try testing.expectEqual(vocabulary.TrapCode.use_after_free, parent.pending.?.code);
            try testing.expectEqual(@as(usize, 1), state.joins);
            try testing.expectEqual(@as(usize, 1), state.closes);
            parent.pending = null;

            parent.freeValue(task);
            parent.debugAssertInvariants();
            try testing.expectEqual(@as(u32, 0), parent.live);
            parent.deinit();
            parent_arena.deinit();
            child_arena.deinit();
            cleaned = true;
            try testing.expectEqual(parent_objects.allocated_bytes, parent_objects.freed_bytes);
            if (completed) break;
        }
        try testing.expect(completed);
        try testing.expect(failures >= 1);
    }
}

test "C compound value doors preserve destinations through every allocation failure" {
    const old_field = "the old struct field remains after replacement refuses";
    const other_field = "the untouched struct field keeps its owned bytes";
    const new_field = "the replacement struct field owns a separate long string";
    const map_key = "the fresh map key is copied before the zero value";
    const map_zero = "the fresh map zero is copied and returned as a borrow";
    const fill_text = "the array fill value is copied into every destination cell";
    const left_text = "the left side of a long concatenation owns no borrowed result";
    const right_text = "the right side of a long concatenation becomes owned output";
    const parse_text = "parse_string copies a packed byte array into owned text";
    const doors = [_]CCompoundAllocationDoor{
        .maybe_text,
        .struct_set,
        .map_place,
        .array_fill,
        .concat,
        .parse_string,
    };

    for (doors) |door| {
        var failures: usize = 0;
        var completed = false;
        for (0..64) |failure_offset| {
            var objects: std.testing.FailingAllocator = .init(testing.allocator, .{});
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            var runtime: Runtime = .init(.{
                .arena = arena.allocator(),
                .objects = objects.allocator(),
            });
            var source = Value.none;
            var source_owned = false;
            var replacement = Value.none;
            var replacement_owned = false;
            var cleaned = false;
            defer if (!cleaned) {
                if (replacement_owned) runtime.dropStorage(replacement);
                if (source_owned) switch (source.tag) {
                    .object => runtime.freeValue(source),
                    else => runtime.dropStorage(source),
                };
                runtime.deinit();
                arena.deinit();
            };

            switch (door) {
                .struct_set => {
                    const first = try runtime.ownValue(Value.ofString(old_field));
                    const second = try runtime.ownValue(Value.ofString(other_field));
                    source = try runtime.makeStruct(&.{ first, second });
                    source_owned = true;
                    replacement = try runtime.ownValue(Value.ofString(new_field));
                    replacement_owned = true;
                },
                .map_place => {
                    source = try runtime.newMap();
                    source_owned = true;
                },
                .array_fill => {
                    source = try runtime.newArray(&.{3}, Value.ofInlineText(.string, "old"));
                    source_owned = true;
                },
                .parse_string => {
                    source = try runtime.newList(Value.ofByte(0));
                    source_owned = true;
                    for (parse_text) |byte| {
                        try containers.append(&runtime, source, Value.ofByte(byte));
                    }
                },
                .maybe_text, .concat => {},
            }
            const baseline_live = runtime.live;

            var out = Value.ofLong(99);
            objects.fail_index = objects.alloc_index + failure_offset;
            const status = switch (door) {
                .maybe_text => luce_rt_maybe_text(&runtime, 1, parse_text, parse_text.len, &out),
                .struct_set => blk: {
                    const answered = luce_rt_struct_set(&runtime, &source, 0, &replacement, &out);
                    // `setField` consumes the incoming value on both
                    // success and allocation failure.
                    replacement_owned = false;
                    break :blk answered;
                },
                .map_place => luce_rt_map_place(
                    &runtime,
                    &source,
                    &Value.ofString(map_key),
                    &Value.ofString(map_zero),
                    &out,
                ),
                .array_fill => luce_rt_array_fill(
                    &runtime,
                    &source,
                    &Value.ofString(fill_text),
                ),
                .concat => luce_rt_concat(
                    &runtime,
                    &Value.ofString(left_text),
                    &Value.ofString(right_text),
                    &out,
                ),
                .parse_string => luce_rt_parse_string(&runtime, &source, &out),
            };
            objects.fail_index = std.math.maxInt(usize);

            if (status == 0) {
                switch (door) {
                    .maybe_text => {
                        try testing.expectEqualStrings(parse_text, out.asString());
                        try testing.expect(out.ownsStorage());
                        runtime.dropStorage(out);
                    },
                    .struct_set => {
                        const fields = out.asStruct();
                        try testing.expectEqual(@as(usize, 2), fields.len);
                        try testing.expectEqualStrings(new_field, fields[0].asString());
                        try testing.expectEqualStrings(other_field, fields[1].asString());
                        runtime.dropStorage(out);
                        try testing.expectEqualStrings(old_field, source.asStruct()[0].asString());
                        try testing.expectEqualStrings(other_field, source.asStruct()[1].asString());
                    },
                    .map_place => {
                        try testing.expectEqual(@as(i64, 1), (try containers.length(&runtime, source)).asLong());
                        try testing.expectEqualStrings(map_zero, out.asString());
                        try testing.expectEqualStrings(
                            map_key,
                            (try containers.keyAt(&runtime, source, 0)).asString(),
                        );
                    },
                    .array_fill => {
                        for (0..3) |index| try testing.expectEqualStrings(
                            fill_text,
                            (try containers.indexGet(
                                &runtime,
                                source,
                                &.{Value.ofLong(@intCast(index))},
                            )).asString(),
                        );
                    },
                    .concat => {
                        try testing.expectEqualStrings(left_text ++ right_text, out.asString());
                        try testing.expect(out.ownsStorage());
                        runtime.dropStorage(out);
                    },
                    .parse_string => {
                        try testing.expectEqualStrings(parse_text, out.asString());
                        try testing.expect(out.ownsStorage());
                        runtime.dropStorage(out);
                    },
                }
                completed = true;
            } else {
                try testing.expectEqual(@as(i32, 1), status);
                if (door != .array_fill) try testing.expectEqual(@as(i64, 99), out.asLong());
                try testing.expect(runtime.pending == null);
                try testing.expect(runtime.exhausted);
                try testing.expect(objects.has_induced_failure);
                try testing.expectEqual(baseline_live, runtime.live);
                switch (door) {
                    .struct_set => {
                        try testing.expectEqualStrings(old_field, source.asStruct()[0].asString());
                        try testing.expectEqualStrings(other_field, source.asStruct()[1].asString());
                    },
                    .map_place => try testing.expectEqual(
                        @as(i64, 0),
                        (try containers.length(&runtime, source)).asLong(),
                    ),
                    .array_fill => for (0..3) |index| try testing.expectEqualStrings(
                        "old",
                        (try containers.indexGet(
                            &runtime,
                            source,
                            &.{Value.ofLong(@intCast(index))},
                        )).asString(),
                    ),
                    .parse_string => try testing.expectEqualSlices(
                        u8,
                        parse_text,
                        (try runtime.resolve(source)).elements.cells(u8),
                    ),
                    .maybe_text, .concat => {},
                }
                failures += 1;
            }

            runtime.debugAssertInvariants();
            if (source_owned) switch (source.tag) {
                .object => runtime.freeValue(source),
                else => runtime.dropStorage(source),
            };
            source_owned = false;
            runtime.debugAssertInvariants();
            try testing.expectEqual(@as(u32, 0), runtime.live);
            runtime.deinit();
            arena.deinit();
            cleaned = true;
            try testing.expectEqual(objects.allocated_bytes, objects.freed_bytes);
            if (completed) break;
        }
        try testing.expect(completed);
        try testing.expect(failures >= 1);
    }
}

test "C string slices preserve views and refuse invalid boundaries" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    var runtime: Runtime = .init(.{
        .arena = arena.allocator(),
        .objects = testing.allocator,
    });
    defer {
        runtime.deinit();
        arena.deinit();
    }

    const outside = Value.ofString("outside text remains behind the view");
    var out = Value.ofLong(99);
    try testing.expectEqual(
        @as(i32, 0),
        luce_rt_string_slice(&runtime, &outside, 8, 12, &out),
    );
    try testing.expectEqualStrings("text", out.asString());
    // An outside view and owned outside text have the same wire shape;
    // this result is a borrow because its pointer is inside the source.
    // The caller must not pass it to dropStorage.
    try testing.expect(!out.textIsInline());
    try testing.expectEqual(@intFromPtr(outside.asString().ptr) + 8, @intFromPtr(out.asString().ptr));

    const inline_text = Value.ofInlineText(.string, "inline🙂text");
    out = Value.ofLong(99);
    try testing.expectEqual(
        @as(i32, 0),
        luce_rt_string_slice(&runtime, &inline_text, 0, 6, &out),
    );
    try testing.expectEqualStrings("inline", out.asString());
    try testing.expect(out.textIsInline());

    out = Value.ofLong(99);
    try testing.expectEqual(
        @as(i32, 1),
        luce_rt_string_slice(&runtime, &outside, 0, -1, &out),
    );
    try testing.expectEqual(@as(i64, 99), out.asLong());
    try testing.expectEqual(vocabulary.TrapCode.string_bounds, runtime.pending.?.code);
    runtime.pending = null;

    out = Value.ofLong(99);
    try testing.expectEqual(
        @as(i32, 1),
        luce_rt_string_slice(&runtime, &inline_text, 6, 7, &out),
    );
    try testing.expectEqual(@as(i64, 99), out.asLong());
    try testing.expectEqual(vocabulary.TrapCode.string_boundary, runtime.pending.?.code);
    runtime.pending = null;
}

test "the C materialization surface roots, loads, freezes, and excludes a constant" {
    const runtime = luce_rt_open(null, 0).?;
    defer luce_rt_close(runtime);

    var invalid: Value = Value.ofLong(99);
    luce_rt_constant_load(runtime, 0, &invalid);
    try testing.expectEqual(vocabulary.TrapCode.not_owned, runtime.pending.?.code);
    try testing.expectEqual(@as(i64, 99), invalid.asLong());
    runtime.pending = null;

    try testing.expectEqual(@as(i32, 0), luce_rt_constants_begin(runtime, 1));
    var rooted: Value = .none;
    try testing.expectEqual(@as(i32, 0), luce_rt_new_list(runtime, &Value.none, &rooted));
    try testing.expectEqual(@as(i32, 0), luce_rt_append(runtime, &rooted, &Value.ofLong(3)));
    try testing.expectEqual(@as(i32, 0), luce_rt_constant_publish(runtime, 0, &rooted));
    invalid = Value.ofLong(98);
    luce_rt_constant_load(runtime, 1, &invalid);
    try testing.expectEqual(vocabulary.TrapCode.not_owned, runtime.pending.?.code);
    try testing.expectEqual(@as(i64, 98), invalid.asLong());
    runtime.pending = null;
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
