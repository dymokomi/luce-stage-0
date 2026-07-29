//! Disposable reverse index from source texels to the texels whose Input
//! Ports consume them.
//!
//! An Output Port owns no durable consumer list (LOOM.md); this is the
//! machinery Loom builds instead.  Rebuilt from any Store snapshot, kept
//! current from ChangeSets, and deliberately texel-granular: any change
//! to a texel dirties all of its consumers.  Over-marking costs a
//! revalidation; under-marking would be a bug.

const std = @import("std");
const store_mod = @import("../fabric/store.zig");
const texel_id = @import("../fabric/texel_id.zig");

const Allocator = std.mem.Allocator;
const Store = store_mod.Store;
const TexelId = texel_id.TexelId;

const IdBytes = [TexelId.size]u8;
const EdgeTable = std.AutoHashMapUnmanaged(IdBytes, std.ArrayList(TexelId));

pub const FiberIndex = struct {
    allocator: Allocator,
    consumers: EdgeTable = .empty, // source -> texels bound to one of its outputs
    sources: EdgeTable = .empty, // consumer -> sources it is bound to

    pub fn init(allocator: Allocator) FiberIndex {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *FiberIndex) void {
        clearTable(self.allocator, &self.consumers);
        self.consumers.deinit(self.allocator);
        clearTable(self.allocator, &self.sources);
        self.sources.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn build(self: *FiberIndex, store: *const Store) !void {
        clearTable(self.allocator, &self.consumers);
        clearTable(self.allocator, &self.sources);
        for (store.texels.items) |*texel| {
            try self.learn(texel);
        }
    }

    pub fn apply(self: *FiberIndex, store: *const Store, changed: []const TexelId) !void {
        for (changed) |id| {
            self.forget(id);
            if (store.get(id)) |texel| {
                try self.learn(texel);
            } else {
                // A removed texel can have no remaining consumers; drop its row.
                if (self.consumers.fetchRemove(id.bytes)) |row| {
                    var list = row.value;
                    list.deinit(self.allocator);
                }
            }
        }
    }

    /// Expand changed texels to every transitive consumer, changed
    /// included.  The caller frees the result.
    pub fn downstream(self: *const FiberIndex, allocator: Allocator, changed: []const TexelId) ![]TexelId {
        var dirty: std.ArrayList(TexelId) = .empty;
        errdefer dirty.deinit(allocator);

        try dirty.appendSlice(allocator, changed);
        var next: usize = 0;
        scan: while (next < dirty.items.len) : (next += 1) {
            const id = dirty.items[next];
            for (dirty.items[0..next]) |earlier| {
                if (earlier.eql(id)) continue :scan;
            }
            const row = self.consumers.get(id.bytes) orelse continue;
            for (row.items) |consumer| {
                var seen = false;
                for (dirty.items) |existing| {
                    if (existing.eql(consumer)) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) try dirty.append(allocator, consumer);
            }
        }
        return dirty.toOwnedSlice(allocator);
    }

    pub fn count(self: *const FiberIndex) usize {
        return self.sources.count();
    }

    // Internal ---------------------------------------------------------------

    fn learn(self: *FiberIndex, texel: *const @import("../fabric/texel.zig").Texel) !void {
        for (texel.inputs.items) |input| {
            const fiber = input.binding orelse continue;
            try appendUnique(self.allocator, &self.consumers, fiber.source.bytes, texel.id);
            try appendUnique(self.allocator, &self.sources, texel.id.bytes, fiber.source);
        }
    }

    fn forget(self: *FiberIndex, consumer: TexelId) void {
        const row = self.sources.fetchRemove(consumer.bytes) orelse return;
        var list = row.value;
        for (list.items) |source| {
            const consumers = self.consumers.getPtr(source.bytes) orelse continue;
            for (consumers.items, 0..) |existing, index| {
                if (existing.eql(consumer)) {
                    _ = consumers.swapRemove(index);
                    break;
                }
            }
            if (consumers.items.len == 0) {
                if (self.consumers.fetchRemove(source.bytes)) |empty| {
                    var emptied = empty.value;
                    emptied.deinit(self.allocator);
                }
            }
        }
        list.deinit(self.allocator);
    }

    fn appendUnique(
        allocator: Allocator,
        table: *EdgeTable,
        key: IdBytes,
        id: TexelId,
    ) !void {
        const row = try table.getOrPut(allocator, key);
        if (!row.found_existing) row.value_ptr.* = .empty;
        for (row.value_ptr.items) |existing| {
            if (existing.eql(id)) return;
        }
        try row.value_ptr.append(allocator, id);
    }

    fn clearTable(allocator: Allocator, table: *EdgeTable) void {
        var rows = table.valueIterator();
        while (rows.next()) |row| row.deinit(allocator);
        table.clearRetainingCapacity();
    }
};

pub fn contains(dirty: []const TexelId, id: TexelId) bool {
    for (dirty) |existing| {
        if (existing.eql(id)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const volume_mod = @import("../storage/volume.zig");
const texel_mod = @import("../fabric/texel.zig");
const value_mod = @import("../fabric/value.zig");
const Texel = texel_mod.Texel;
const InputPort = texel_mod.InputPort;
const OutputPort = texel_mod.OutputPort;
const Fiber = texel_mod.Fiber;
const Value = value_mod.Value;

fn sourceTexel(allocator: Allocator, text: []const u8) !Texel {
    var item = Texel.init(TexelId.generate(std.testing.io));
    errdefer item.deinit(allocator);
    var output = try OutputPort.init(allocator, "value", .text);
    try output.setSource(allocator, try Value.initText(allocator, text));
    try item.putOutput(allocator, output);
    return item;
}

test "build, downstream closure, apply after rewiring and removal" {
    const allocator = testing.allocator;
    var memory = try volume_mod.MemoryVolume.init(allocator, 32);
    defer memory.deinit();
    var store = try Store.create(allocator, memory.volume());
    defer store.deinit();

    var left = try sourceTexel(allocator, "left");
    defer left.deinit(allocator);
    var right = try sourceTexel(allocator, "right");
    defer right.deinit(allocator);

    var join = Texel.init(TexelId.generate(std.testing.io));
    defer join.deinit(allocator);
    try join.setEvaluator(allocator, "concat");
    try join.putInput(allocator, try InputPort.init(allocator, "left", .text));
    try join.putInput(allocator, try InputPort.init(allocator, "right", .text));
    try join.putOutput(allocator, try OutputPort.init(allocator, "value", .text));

    var upper = Texel.init(TexelId.generate(std.testing.io));
    defer upper.deinit(allocator);
    try upper.setEvaluator(allocator, "upper");
    try upper.putInput(allocator, try InputPort.init(allocator, "text", .text));
    try upper.putOutput(allocator, try OutputPort.init(allocator, "value", .text));

    {
        var transaction = try store.begin();
        defer transaction.deinit();
        try transaction.put(&left);
        try transaction.put(&right);
        try transaction.put(&join);
        try transaction.put(&upper);
        try transaction.connect(join.id, "left", left.id, "value");
        try transaction.connect(join.id, "right", right.id, "value");
        try transaction.connect(upper.id, "text", join.id, "value");
        try transaction.commit();
    }

    var index = FiberIndex.init(allocator);
    defer index.deinit();
    try index.build(&store);
    try testing.expectEqual(@as(usize, 2), index.count());

    // A changed source dirties its whole downstream chain and only that.
    var dirty = try index.downstream(allocator, &.{left.id});
    try testing.expectEqual(@as(usize, 3), dirty.len);
    try testing.expect(contains(dirty, join.id));
    try testing.expect(contains(dirty, upper.id));
    try testing.expect(!contains(dirty, right.id));
    allocator.free(dirty);

    // A changed sink dirties only itself.
    dirty = try index.downstream(allocator, &.{upper.id});
    try testing.expectEqual(@as(usize, 1), dirty.len);
    allocator.free(dirty);

    // Disconnecting rewrites the consumer, so the delta names it; apply
    // relearns the row and left loses its downstream chain.
    {
        var transaction = try store.begin();
        defer transaction.deinit();
        try transaction.disconnect(join.id, "left");
        try transaction.commit();
    }
    try index.apply(&store, &.{join.id});
    dirty = try index.downstream(allocator, &.{left.id});
    try testing.expectEqual(@as(usize, 1), dirty.len);
    allocator.free(dirty);
    dirty = try index.downstream(allocator, &.{right.id});
    try testing.expectEqual(@as(usize, 3), dirty.len);
    allocator.free(dirty);

    // Removing a consumer drops its edges entirely.
    {
        var transaction = try store.begin();
        defer transaction.deinit();
        try transaction.disconnect(upper.id, "text");
        try transaction.remove(upper.id);
        try transaction.commit();
    }
    try index.apply(&store, &.{upper.id});
    try testing.expectEqual(@as(usize, 1), index.count());
    dirty = try index.downstream(allocator, &.{join.id});
    try testing.expectEqual(@as(usize, 1), dirty.len);
    allocator.free(dirty);

    // A rebuilt index agrees with the applied one.
    var rebuilt = FiberIndex.init(allocator);
    defer rebuilt.deinit();
    try rebuilt.build(&store);
    try testing.expectEqual(index.count(), rebuilt.count());
}
