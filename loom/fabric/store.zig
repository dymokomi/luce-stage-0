//! Durable Texel snapshot using two descriptor pages and two body arenas,
//! published atomically by generation.
//!
//! A Transaction is a private working snapshot: changes become visible
//! only after commit has durably published a new generation.  observe is
//! the volatile push path: it updates an observed Output Port in memory
//! only, advancing the logical generation; nothing reaches the volume and
//! reopen reverts to the last durable snapshot.  Every change — durable
//! or volatile — lands in a bounded ChangeSet ring behind changesSince.
//!
//! The descriptor page layout (LUSTORE) is the frozen on-disk contract
//! shared with the reference C++ implementation.

const std = @import("std");
const volume_mod = @import("../storage/volume.zig");
const texel_id = @import("texel_id.zig");
const value_mod = @import("value.zig");
const texel_mod = @import("texel.zig");
const encode = @import("encode.zig");

const Allocator = std.mem.Allocator;
const Volume = volume_mod.Volume;
const Page = volume_mod.Page;
const page_size = volume_mod.page_size;
const TexelId = texel_id.TexelId;
const Value = value_mod.Value;
const BlobRef = value_mod.BlobRef;
const Fiber = texel_mod.Fiber;
const Texel = texel_mod.Texel;
const BlobRecord = encode.BlobRecord;

const store_version: u32 = 1;
const descriptor_magic = [8]u8{ 'L', 'U', 'S', 'T', 'O', 'R', 'E', 0 };
const generation_offset = 16;
const body_size_offset = 24;
const checksum_offset = 32;
const descriptor_used_size = 40;

pub const Error = error{
    StoreClosed,
    NotFound,
    InvalidArgument,
    StaleTransaction,
    PublishFailed,
    BadImage,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// ChangeSet
// ---------------------------------------------------------------------------
//
// The texels one commit or observation changed.  Kept in a bounded
// in-memory ring so interested machinery can ask what moved; never
// persisted — losing the ring costs a rebuild, not correctness.
//
pub const ChangeSet = struct {
    generation: u64,
    changed: []TexelId,
};

pub const change_ring = 64;

// ---------------------------------------------------------------------------
// Store
// ---------------------------------------------------------------------------

pub const Store = struct {
    allocator: Allocator,
    vol: Volume,
    texels: std.ArrayList(Texel) = .empty,
    blobs: std.ArrayList(BlobRecord) = .empty,
    changes: std.ArrayList(ChangeSet) = .empty,
    generation: u64 = 0,
    active_arena: u1 = 0,

    /// Format the volume as an empty Fabric at generation one.  The
    /// volume must outlive the Store and every Transaction begun on it.
    pub fn create(allocator: Allocator, vol: Volume) !Store {
        if (vol.size() < 6) return Error.BadImage;

        const empty: Page = @splat(0);
        vol.write(0, &empty) catch return Error.PublishFailed;
        vol.write(1, &empty) catch return Error.PublishFailed;
        vol.flush() catch return Error.PublishFailed;

        const body = try encode.encodeSnapshot(allocator, &.{}, &.{});
        defer allocator.free(body);
        try publish(vol, 0, 1, body);

        return .{ .allocator = allocator, .vol = vol, .generation = 1 };
    }

    /// Open the newest valid snapshot of an existing Fabric image.
    pub fn open(allocator: Allocator, vol: Volume) !Store {
        if (vol.size() < 6) return Error.BadImage;

        var first = loadSnapshot(allocator, vol, 0) catch null;
        errdefer if (first) |*snapshot| snapshot.deinit(allocator);
        var second = loadSnapshot(allocator, vol, 1) catch null;
        errdefer if (second) |*snapshot| snapshot.deinit(allocator);

        if (first == null and second == null) return Error.BadImage;
        if (first != null and second != null and
            first.?.generation == second.?.generation)
        {
            return Error.BadImage;
        }

        const first_wins = first != null and
            (second == null or first.?.generation > second.?.generation);
        const newest = if (first_wins) first.? else second.?;
        if (first_wins) {
            if (second) |*loser| loser.deinit(allocator);
        } else {
            if (first) |*loser| loser.deinit(allocator);
        }
        first = null;
        second = null;

        return .{
            .allocator = allocator,
            .vol = vol,
            .texels = newest.snapshot.texels,
            .blobs = newest.snapshot.blobs,
            .generation = newest.generation,
            .active_arena = newest.arena,
        };
    }

    pub fn deinit(self: *Store) void {
        for (self.texels.items) |*item| item.deinit(self.allocator);
        self.texels.deinit(self.allocator);
        for (self.blobs.items) |*blob| blob.deinit(self.allocator);
        self.blobs.deinit(self.allocator);
        clearChanges(self);
        self.changes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn count(self: *const Store) usize {
        return self.texels.items.len;
    }

    pub fn at(self: *const Store, index: usize) ?*const Texel {
        if (index >= self.texels.items.len) return null;
        return &self.texels.items[index];
    }

    pub fn has(self: *const Store, id: TexelId) bool {
        return self.get(id) != null;
    }

    /// Borrow a texel; the reference is valid until the next mutation.
    pub fn get(self: *const Store, id: TexelId) ?*const Texel {
        const index = findTexel(self.texels.items, id) orelse return null;
        return &self.texels.items[index];
    }

    /// Borrow blob bytes; valid until the next mutation.
    pub fn getBlob(self: *const Store, reference: BlobRef) ?[]const u8 {
        const index = findBlob(self.blobs.items, reference.id) orelse return null;
        const record = self.blobs.items[index];
        if (record.reference.size != reference.size) return null;
        return record.bytes;
    }

    /// Begin a private working snapshot.  The caller must commit, abort,
    /// or deinit it.
    pub fn begin(self: *Store) !Transaction {
        var transaction: Transaction = .{
            .store = self,
            .base_generation = self.generation,
            .next_revision = nextRevision(self.texels.items) orelse
                return Error.InvalidArgument,
        };
        errdefer transaction.deinit();

        try transaction.texels.ensureTotalCapacity(self.allocator, self.texels.items.len);
        for (self.texels.items) |item| {
            transaction.texels.appendAssumeCapacity(try item.clone(self.allocator));
        }
        try transaction.blobs.ensureTotalCapacity(self.allocator, self.blobs.items.len);
        for (self.blobs.items) |blob| {
            transaction.blobs.appendAssumeCapacity(.{
                .reference = blob.reference,
                .bytes = try self.allocator.dupe(u8, blob.bytes),
            });
        }
        return transaction;
    }

    /// Volatile observation: update an observed Output Port in memory
    /// only, advancing the port, texel, and logical generation and
    /// recording the change.  Takes ownership of the value on success;
    /// the caller keeps it on error.  An observation becomes durable only
    /// when a later commit publishes a snapshot that contains it.
    pub fn observe(self: *Store, id: TexelId, output_name: []const u8, source: Value) Error!void {
        if (id.isUnset() or self.generation == std.math.maxInt(u64)) {
            return Error.InvalidArgument;
        }
        const index = findTexel(self.texels.items, id) orelse return Error.NotFound;
        const target = &self.texels.items[index];
        const output = target.mutableOutput(output_name) orelse return Error.NotFound;
        output.setSource(self.allocator, source) catch return Error.InvalidArgument;

        target.revision = (nextRevision(self.texels.items) orelse
            return Error.InvalidArgument);
        self.generation += 1;

        const changed = try self.allocator.alloc(TexelId, 1);
        changed[0] = id;
        try self.recordChanges(changed);
    }

    /// Union of the texels changed in (baseline, current], or null when
    /// the ring no longer covers that span — the caller must then assume
    /// everything changed and rebuild.  The caller frees the result.
    pub fn changesSince(self: *const Store, allocator: Allocator, baseline: u64) !?[]TexelId {
        if (baseline > self.generation) return null;
        if (baseline == self.generation) return try allocator.alloc(TexelId, 0);
        if (self.changes.items.len == 0 or
            self.changes.items[0].generation > baseline + 1)
        {
            return null;
        }

        var united: std.ArrayList(TexelId) = .empty;
        errdefer united.deinit(allocator);
        for (self.changes.items) |set| {
            if (set.generation <= baseline) continue;
            for (set.changed) |id| {
                var seen = false;
                for (united.items) |existing| {
                    if (existing.eql(id)) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) try united.append(allocator, id);
            }
        }
        return try united.toOwnedSlice(allocator);
    }

    // Internal ---------------------------------------------------------------

    fn commitFrom(self: *Store, transaction: *Transaction) Error!void {
        if (transaction.base_generation != self.generation or
            self.generation == std.math.maxInt(u64))
        {
            return Error.StaleTransaction;
        }

        const body = encode.encodeSnapshot(
            self.allocator,
            transaction.texels.items,
            transaction.blobs.items,
        ) catch |err| switch (err) {
            error.OutOfMemory => return Error.OutOfMemory,
            error.InvalidSnapshot => return Error.InvalidArgument,
        };
        defer self.allocator.free(body);

        const inactive: u1 = self.active_arena ^ 1;
        const new_generation = self.generation + 1;
        try publish(self.vol, inactive, new_generation, body);

        // Swap the tables: the transaction's clones become the store's
        // state, and the old state is released.
        for (self.texels.items) |*item| item.deinit(self.allocator);
        self.texels.deinit(self.allocator);
        for (self.blobs.items) |*blob| blob.deinit(self.allocator);
        self.blobs.deinit(self.allocator);
        self.texels = transaction.texels;
        self.blobs = transaction.blobs;
        transaction.texels = .empty;
        transaction.blobs = .empty;

        self.generation = new_generation;
        self.active_arena = inactive;

        const changed = try transaction.touched.toOwnedSlice(self.allocator);
        try self.recordChanges(changed);
    }

    fn recordChanges(self: *Store, changed: []TexelId) Error!void {
        errdefer self.allocator.free(changed);
        try self.changes.append(self.allocator, .{
            .generation = self.generation,
            .changed = changed,
        });
        if (self.changes.items.len > change_ring) {
            var oldest = self.changes.orderedRemove(0);
            self.allocator.free(oldest.changed);
            oldest = undefined;
        }
    }

    fn clearChanges(self: *Store) void {
        for (self.changes.items) |set| self.allocator.free(set.changed);
        self.changes.clearRetainingCapacity();
    }
};

// ---------------------------------------------------------------------------
// Transaction
// ---------------------------------------------------------------------------

pub const Transaction = struct {
    store: *Store,
    texels: std.ArrayList(Texel) = .empty,
    blobs: std.ArrayList(BlobRecord) = .empty,
    touched: std.ArrayList(TexelId) = .empty,
    base_generation: u64,
    next_revision: u64,
    active: bool = true,

    /// Release the private snapshot without publishing.  Safe after
    /// commit as well; commit already emptied the tables.
    pub fn deinit(self: *Transaction) void {
        const allocator = self.store.allocator;
        for (self.texels.items) |*item| item.deinit(allocator);
        self.texels.deinit(allocator);
        for (self.blobs.items) |*blob| blob.deinit(allocator);
        self.blobs.deinit(allocator);
        self.touched.deinit(allocator);
        self.active = false;
    }

    pub fn count(self: *const Transaction) usize {
        return self.texels.items.len;
    }

    pub fn has(self: *const Transaction, id: TexelId) bool {
        return findTexel(self.texels.items, id) != null;
    }

    pub fn get(self: *const Transaction, id: TexelId) ?*const Texel {
        const index = findTexel(self.texels.items, id) orelse return null;
        return &self.texels.items[index];
    }

    /// Clone the texel into the snapshot with a fresh revision; the
    /// caller keeps ownership of the original.
    pub fn put(self: *Transaction, item: *const Texel) Error!void {
        if (!self.active or !item.valid()) return Error.InvalidArgument;
        var cloned = item.clone(self.store.allocator) catch return Error.OutOfMemory;
        errdefer cloned.deinit(self.store.allocator);
        try self.putChanged(&cloned);
    }

    pub fn remove(self: *Transaction, id: TexelId) Error!void {
        if (!self.active or id.isUnset()) return Error.InvalidArgument;
        const index = findTexel(self.texels.items, id) orelse return Error.NotFound;
        if (self.referenced(id)) return Error.InvalidArgument;
        var removed = self.texels.orderedRemove(index);
        removed.deinit(self.store.allocator);
        try self.touch(id);
    }

    /// Bind target's input to source's output.  Types must match.
    pub fn connect(
        self: *Transaction,
        target: TexelId,
        input_name: []const u8,
        source: TexelId,
        output_name: []const u8,
    ) Error!void {
        if (!self.active or target.isUnset() or source.isUnset()) {
            return Error.InvalidArgument;
        }
        const allocator = self.store.allocator;
        const target_index = findTexel(self.texels.items, target) orelse
            return Error.NotFound;
        const source_index = findTexel(self.texels.items, source) orelse
            return Error.NotFound;

        const offered = self.texels.items[source_index].getOutput(output_name) orelse
            return Error.NotFound;
        const expected = self.texels.items[target_index].getInput(input_name) orelse
            return Error.NotFound;
        if (offered.declared != expected.declared) return Error.InvalidArgument;

        var changed = self.texels.items[target_index].clone(allocator) catch
            return Error.OutOfMemory;
        errdefer changed.deinit(allocator);
        const input = changed.mutableInput(input_name) orelse return Error.NotFound;
        const fiber = Fiber.init(allocator, source, output_name) catch
            return Error.OutOfMemory;
        input.bind(allocator, fiber) catch return Error.InvalidArgument;
        try self.putChanged(&changed);
    }

    pub fn disconnect(self: *Transaction, target: TexelId, input_name: []const u8) Error!void {
        if (!self.active or target.isUnset()) return Error.InvalidArgument;
        const allocator = self.store.allocator;
        const index = findTexel(self.texels.items, target) orelse return Error.NotFound;
        const bound = self.texels.items[index].getInput(input_name) orelse
            return Error.NotFound;
        if (bound.binding == null) return Error.NotFound;

        var changed = self.texels.items[index].clone(allocator) catch
            return Error.OutOfMemory;
        errdefer changed.deinit(allocator);
        changed.mutableInput(input_name).?.unbind(allocator);
        try self.putChanged(&changed);
    }

    /// Deduplicating content-addressed blob insert; the caller keeps the
    /// given bytes.
    pub fn putBlob(self: *Transaction, bytes: []const u8) Error!BlobRef {
        if (!self.active) return Error.InvalidArgument;
        const allocator = self.store.allocator;

        var id: [BlobRef.id_size]u8 = undefined;
        blobIdentifier(bytes, &id);
        if (findBlob(self.blobs.items, id)) |index| {
            const existing = self.blobs.items[index];
            if (!std.mem.eql(u8, existing.bytes, bytes)) return Error.InvalidArgument;
            return existing.reference;
        }

        const record: BlobRecord = .{
            .reference = .{ .id = id, .size = bytes.len },
            .bytes = allocator.dupe(u8, bytes) catch return Error.OutOfMemory,
        };
        const index = blobInsertIndex(self.blobs.items, id);
        self.blobs.insert(allocator, index, record) catch {
            allocator.free(record.bytes);
            return Error.OutOfMemory;
        };
        return record.reference;
    }

    pub fn getBlob(self: *const Transaction, reference: BlobRef) ?[]const u8 {
        const index = findBlob(self.blobs.items, reference.id) orelse return null;
        const record = self.blobs.items[index];
        if (record.reference.size != reference.size) return null;
        return record.bytes;
    }

    /// Durably publish this snapshot as the next generation.  The
    /// transaction is consumed on success; call deinit afterwards either
    /// way.
    pub fn commit(self: *Transaction) Error!void {
        if (!self.active) return Error.InvalidArgument;
        try self.store.commitFrom(self);
        self.active = false;
    }

    pub fn abort(self: *Transaction) void {
        self.active = false;
    }

    // Internal ---------------------------------------------------------------

    /// Take ownership of the texel, stamp the next revision, and place it.
    fn putChanged(self: *Transaction, changed: *Texel) Error!void {
        if (self.next_revision == 0) return Error.InvalidArgument;
        changed.revision = self.next_revision;
        self.next_revision = if (self.next_revision == std.math.maxInt(u64))
            0
        else
            self.next_revision + 1;

        const allocator = self.store.allocator;
        if (findTexel(self.texels.items, changed.id)) |index| {
            self.texels.items[index].deinit(allocator);
            self.texels.items[index] = changed.*;
        } else {
            const index = texelInsertIndex(self.texels.items, changed.id);
            self.texels.insert(allocator, index, changed.*) catch {
                changed.deinit(allocator);
                return Error.OutOfMemory;
            };
        }
        try self.touch(changed.id);
    }

    fn touch(self: *Transaction, id: TexelId) Error!void {
        for (self.touched.items) |existing| {
            if (existing.eql(id)) return;
        }
        try self.touched.append(self.store.allocator, id);
    }

    fn referenced(self: *const Transaction, id: TexelId) bool {
        for (self.texels.items) |item| {
            if (item.content) |content| {
                if (content == .texel and content.texel.eql(id)) return true;
            }
            for (item.inputs.items) |input| {
                const fiber = input.binding orelse continue;
                if (fiber.source.eql(id)) return true;
            }
            for (item.outputs.items) |output| {
                const source = output.source orelse continue;
                if (source == .texel and source.texel.eql(id)) return true;
            }
        }
        return false;
    }
};

// ---------------------------------------------------------------------------
// Sorted table helpers
// ---------------------------------------------------------------------------

fn findTexel(texels: []const Texel, id: TexelId) ?usize {
    var low: usize = 0;
    var high: usize = texels.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, &texels[middle].id.bytes, &id.bytes)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return middle,
        }
    }
    return null;
}

fn texelInsertIndex(texels: []const Texel, id: TexelId) usize {
    var low: usize = 0;
    var high: usize = texels.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (texels[middle].id.lessThan(id)) low = middle + 1 else high = middle;
    }
    return low;
}

fn findBlob(blobs: []const BlobRecord, id: [BlobRef.id_size]u8) ?usize {
    for (blobs, 0..) |blob, index| {
        if (std.mem.eql(u8, &blob.reference.id, &id)) return index;
    }
    return null;
}

fn blobInsertIndex(blobs: []const BlobRecord, id: [BlobRef.id_size]u8) usize {
    for (blobs, 0..) |blob, index| {
        if (std.mem.order(u8, &id, &blob.reference.id) == .lt) return index;
    }
    return blobs.len;
}

fn nextRevision(texels: []const Texel) ?u64 {
    var highest: u64 = 0;
    for (texels) |item| {
        if (item.revision > highest) highest = item.revision;
    }
    if (highest == std.math.maxInt(u64)) return null;
    return highest + 1;
}

// ---------------------------------------------------------------------------
// Blob identity
// ---------------------------------------------------------------------------
//
// A deterministic, non-security hash expanded into four independent
// words.  Collisions are always checked against the original bytes.
// Byte-identical to the reference implementation.
//
pub fn blobIdentifier(bytes: []const u8, identifier: *[BlobRef.id_size]u8) void {
    const seeds = [4]u64{
        1469598103934665603,
        1099511628211,
        7809847782465536322,
        9650029242287828579,
    };

    var all_zero = true;
    for (seeds, 0..) |seed, word| {
        var hash: u64 = seed ^ @as(u64, bytes.len);
        for (bytes) |byte| {
            hash ^= @as(u64, byte) +% (@as(u64, word + 1) << 8);
            hash *%= 1099511628211;
            hash ^= hash >> 29;
        }
        hash ^= @as(u64, word + 1) *% 0x9e3779b97f4a7c15;
        std.mem.writeInt(u64, identifier[word * 8 ..][0..8], hash, .little);
        if (hash != 0) all_zero = false;
    }
    if (all_zero) {
        identifier[BlobRef.id_size - 1] = 1;
    }
}

// ---------------------------------------------------------------------------
// Descriptor pages and arenas
// ---------------------------------------------------------------------------
//
// Pages 0 and 1 are descriptors; the remaining pages split into two body
// arenas.  A commit writes the inactive arena, flushes, then writes that
// arena's descriptor and flushes again — the descriptor flip is the
// atomic publication point.
//

fn arenaPages(vol: Volume) u64 {
    return (vol.size() - 2) / 2;
}

fn arenaFirst(vol: Volume, arena: u1) u64 {
    return 2 + @as(u64, arena) * arenaPages(vol);
}

/// Corruption detection only; never a security boundary.
fn bodyChecksum(data: []const u8) u64 {
    var hash: u64 = 1469598103934665603;
    for (data) |byte| {
        hash ^= byte;
        hash *%= 1099511628211;
    }
    hash ^= @as(u64, data.len);
    hash *%= 1099511628211;
    return hash;
}

fn publish(vol: Volume, arena: u1, generation: u64, body: []const u8) Error!void {
    const needed = (body.len + page_size - 1) / page_size;
    if (needed == 0 or needed > arenaPages(vol)) return Error.PublishFailed;

    var page: Page = undefined;
    var offset: usize = 0;
    var index: u64 = 0;
    while (index < needed) : (index += 1) {
        @memset(&page, 0);
        const chunk = @min(body.len - offset, page_size);
        @memcpy(page[0..chunk], body[offset..][0..chunk]);
        vol.write(arenaFirst(vol, arena) + index, &page) catch return Error.PublishFailed;
        offset += chunk;
    }
    vol.flush() catch return Error.PublishFailed;

    @memset(&page, 0);
    @memcpy(page[0..descriptor_magic.len], &descriptor_magic);
    std.mem.writeInt(u32, page[8..12], store_version, .little);
    std.mem.writeInt(u64, page[generation_offset..][0..8], generation, .little);
    std.mem.writeInt(u64, page[body_size_offset..][0..8], body.len, .little);
    std.mem.writeInt(u64, page[checksum_offset..][0..8], bodyChecksum(body), .little);
    vol.write(arena, &page) catch return Error.PublishFailed;
    vol.flush() catch return Error.PublishFailed;
}

const Loaded = struct {
    snapshot: encode.Snapshot,
    generation: u64,
    arena: u1,

    fn deinit(self: *Loaded, allocator: Allocator) void {
        self.snapshot.deinit(allocator);
        self.* = undefined;
    }
};

fn loadSnapshot(allocator: Allocator, vol: Volume, arena: u1) !Loaded {
    var descriptor: Page = undefined;
    vol.read(arena, &descriptor) catch return Error.BadImage;

    if (!std.mem.eql(u8, descriptor[0..descriptor_magic.len], &descriptor_magic)) {
        return Error.BadImage;
    }
    if (std.mem.readInt(u32, descriptor[8..12], .little) != store_version) {
        return Error.BadImage;
    }
    if (std.mem.readInt(u32, descriptor[12..16], .little) != 0) return Error.BadImage;
    if (!std.mem.allEqual(u8, descriptor[descriptor_used_size..], 0)) {
        return Error.BadImage;
    }

    const generation = std.mem.readInt(u64, descriptor[generation_offset..][0..8], .little);
    const byte_size = std.mem.readInt(u64, descriptor[body_size_offset..][0..8], .little);
    const checksum = std.mem.readInt(u64, descriptor[checksum_offset..][0..8], .little);
    if (generation == 0 or byte_size == 0) return Error.BadImage;

    const needed = (byte_size + page_size - 1) / page_size;
    if (needed > arenaPages(vol)) return Error.BadImage;

    const body = try allocator.alloc(u8, @intCast(byte_size));
    defer allocator.free(body);
    var page: Page = undefined;
    var offset: usize = 0;
    var index: u64 = 0;
    while (index < needed) : (index += 1) {
        vol.read(arenaFirst(vol, arena) + index, &page) catch return Error.BadImage;
        const chunk = @min(body.len - offset, page_size);
        @memcpy(body[offset..][0..chunk], page[0..chunk]);
        offset += chunk;
    }
    if (bodyChecksum(body) != checksum) return Error.BadImage;

    const snapshot = encode.decodeSnapshot(allocator, body) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        error.InvalidSnapshot => return Error.BadImage,
    };
    return .{ .snapshot = snapshot, .generation = generation, .arena = arena };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const OutputPort = texel_mod.OutputPort;
const InputPort = texel_mod.InputPort;

fn sourceTexel(allocator: Allocator, text: []const u8) !Texel {
    var item = Texel.init(TexelId.generate(std.testing.io));
    errdefer item.deinit(allocator);
    var output = try OutputPort.init(allocator, "value", .text);
    try output.setSource(allocator, try Value.initText(allocator, text));
    try item.putOutput(allocator, output);
    return item;
}

test "transactions publish atomically and survive reopen" {
    const allocator = testing.allocator;
    var memory = try volume_mod.MemoryVolume.init(allocator, 32);
    defer memory.deinit();

    var left = try sourceTexel(allocator, "hello ");
    defer left.deinit(allocator);
    var right = try sourceTexel(allocator, "world");
    defer right.deinit(allocator);
    var joined = Texel.init(TexelId.generate(std.testing.io));
    defer joined.deinit(allocator);
    try joined.setEvaluator(allocator, "concat");
    try joined.putInput(allocator, try InputPort.init(allocator, "left", .text));
    try joined.putInput(allocator, try InputPort.init(allocator, "right", .text));
    try joined.putOutput(allocator, try OutputPort.init(allocator, "value", .text));

    {
        var store = try Store.create(allocator, memory.volume());
        defer store.deinit();
        try testing.expectEqual(@as(u64, 1), store.generation);

        var transaction = try store.begin();
        defer transaction.deinit();
        try transaction.put(&left);
        try transaction.put(&right);
        try transaction.put(&joined);
        try transaction.connect(joined.id, "left", left.id, "value");
        try transaction.connect(joined.id, "right", right.id, "value");
        try transaction.commit();
        try testing.expectEqual(@as(u64, 2), store.generation);
        try testing.expectEqual(@as(usize, 3), store.count());
    }
    {
        var store = try Store.open(allocator, memory.volume());
        defer store.deinit();
        try testing.expectEqual(@as(u64, 2), store.generation);
        try testing.expectEqual(@as(usize, 3), store.count());

        const reloaded = store.get(joined.id) orelse return error.Missing;
        try testing.expectEqualStrings("concat", reloaded.evaluatorName());
        const binding = reloaded.getInput("left").?.binding orelse return error.Missing;
        try testing.expect(binding.source.eql(left.id));

        const source = store.get(left.id) orelse return error.Missing;
        try testing.expectEqualStrings("hello ", source.getOutput("value").?.source.?.text);
    }
}

test "remove refuses referenced texels until disconnected" {
    const allocator = testing.allocator;
    var memory = try volume_mod.MemoryVolume.init(allocator, 32);
    defer memory.deinit();
    var store = try Store.create(allocator, memory.volume());
    defer store.deinit();

    var source = try sourceTexel(allocator, "kept");
    defer source.deinit(allocator);
    var consumer = Texel.init(TexelId.generate(std.testing.io));
    defer consumer.deinit(allocator);
    try consumer.setEvaluator(allocator, "copy");
    try consumer.putInput(allocator, try InputPort.init(allocator, "input", .text));
    try consumer.putOutput(allocator, try OutputPort.init(allocator, "value", .text));

    {
        var transaction = try store.begin();
        defer transaction.deinit();
        try transaction.put(&source);
        try transaction.put(&consumer);
        try transaction.connect(consumer.id, "input", source.id, "value");
        try transaction.commit();
    }
    {
        var transaction = try store.begin();
        defer transaction.deinit();
        try testing.expectError(Error.InvalidArgument, transaction.remove(source.id));
        try transaction.disconnect(consumer.id, "input");
        try transaction.remove(source.id);
        try transaction.commit();
    }
    try testing.expect(!store.has(source.id));
    try testing.expect(store.has(consumer.id));
}

test "changes since unions deltas and loses coverage past the ring" {
    const allocator = testing.allocator;
    var memory = try volume_mod.MemoryVolume.init(allocator, 32);
    defer memory.deinit();
    var store = try Store.create(allocator, memory.volume());
    defer store.deinit();

    const base = store.generation;
    const empty = (try store.changesSince(allocator, base)) orelse return error.Missing;
    allocator.free(empty);
    try testing.expect((try store.changesSince(allocator, base + 1)) == null);

    var one = try sourceTexel(allocator, "one");
    defer one.deinit(allocator);
    var two = try sourceTexel(allocator, "two");
    defer two.deinit(allocator);
    {
        var transaction = try store.begin();
        defer transaction.deinit();
        try transaction.put(&one);
        try transaction.commit();
    }
    {
        var transaction = try store.begin();
        defer transaction.deinit();
        try transaction.put(&two);
        try transaction.commit();
    }

    const both = (try store.changesSince(allocator, base)) orelse return error.Missing;
    defer allocator.free(both);
    try testing.expectEqual(@as(usize, 2), both.len);

    const second = (try store.changesSince(allocator, base + 1)) orelse return error.Missing;
    defer allocator.free(second);
    try testing.expectEqual(@as(usize, 1), second.len);
    try testing.expect(second[0].eql(two.id));

    var round: usize = 0;
    while (round < change_ring + 4) : (round += 1) {
        var transaction = try store.begin();
        defer transaction.deinit();
        try transaction.put(&one);
        try transaction.commit();
    }
    try testing.expect((try store.changesSince(allocator, base)) == null);
    const last = (try store.changesSince(allocator, store.generation - 1)) orelse
        return error.Missing;
    defer allocator.free(last);
    try testing.expectEqual(@as(usize, 1), last.len);
    try testing.expect(last[0].eql(one.id));
}

test "observe stays volatile and refuses stale transactions" {
    const allocator = testing.allocator;
    var memory = try volume_mod.MemoryVolume.init(allocator, 32);
    defer memory.deinit();
    var store = try Store.create(allocator, memory.volume());
    defer store.deinit();

    var eye = try sourceTexel(allocator, "seen");
    defer eye.deinit(allocator);
    {
        var transaction = try store.begin();
        defer transaction.deinit();
        try transaction.put(&eye);
        try transaction.commit();
    }

    const durable = store.generation;
    const before = store.get(eye.id).?.revision;
    try store.observe(eye.id, "value", try Value.initText(allocator, "newer"));
    try testing.expectEqual(durable + 1, store.generation);

    const observed = store.get(eye.id) orelse return error.Missing;
    try testing.expectEqualStrings("newer", observed.getOutput("value").?.source.?.text);
    try testing.expect(observed.revision > before);

    const delta = (try store.changesSince(allocator, durable)) orelse return error.Missing;
    defer allocator.free(delta);
    try testing.expectEqual(@as(usize, 1), delta.len);
    try testing.expect(delta[0].eql(eye.id));

    // Wrong type and missing endpoints refuse; the caller keeps the value.
    try testing.expectError(
        Error.InvalidArgument,
        store.observe(eye.id, "value", .{ .boolean = true }),
    );
    try testing.expectError(
        Error.NotFound,
        store.observe(eye.id, "missing", .{ .int = 4 }),
    );

    // A transaction begun before an observation cannot commit over it.
    var stale = try store.begin();
    defer stale.deinit();
    try store.observe(eye.id, "value", try Value.initText(allocator, "race"));
    try testing.expectError(Error.StaleTransaction, stale.commit());

    // Reopen: the observation is gone, the durable value remains.
    var reopened = try Store.open(allocator, memory.volume());
    defer reopened.deinit();
    const durable_texel = reopened.get(eye.id) orelse return error.Missing;
    try testing.expectEqualStrings("seen", durable_texel.getOutput("value").?.source.?.text);
}

test "blobs deduplicate by content and survive reopen" {
    const allocator = testing.allocator;
    var memory = try volume_mod.MemoryVolume.init(allocator, 32);
    defer memory.deinit();
    var store = try Store.create(allocator, memory.volume());
    defer store.deinit();

    var holder = Texel.init(TexelId.generate(std.testing.io));
    defer holder.deinit(allocator);
    try holder.putOutput(allocator, try OutputPort.init(allocator, "data", .blob));

    var reference: BlobRef = undefined;
    {
        var transaction = try store.begin();
        defer transaction.deinit();
        reference = try transaction.putBlob("large content");
        const again = try transaction.putBlob("large content");
        try testing.expect(reference.eql(again));

        var keeper = try holder.clone(allocator);
        defer keeper.deinit(allocator);
        try keeper.mutableOutput("data").?.setSource(allocator, .{ .blob = reference });
        try transaction.put(&keeper);
        try transaction.commit();
    }

    var reopened = try Store.open(allocator, memory.volume());
    defer reopened.deinit();
    const bytes = reopened.getBlob(reference) orelse return error.Missing;
    try testing.expectEqualStrings("large content", bytes);
}

test "golden image written by the reference implementation opens" {
    const allocator = testing.allocator;
    const io = std.testing.io;

    var file = volume_mod.FileVolume.open(io, std.Io.Dir.cwd(), "testdata/golden_store.bin") catch
        return error.SkipZigTest;
    defer file.close();

    var store = try Store.open(allocator, file.volume());
    defer store.deinit();
    try testing.expect(store.count() >= 4);

    // Find texels by their name Output Port, the terminal's convention.
    var alpha: ?*const Texel = null;
    var found_keyboard = false;
    var found_mouse = false;
    for (store.texels.items) |*item| {
        const name_port = item.getOutput("name") orelse continue;
        const source = name_port.source orelse continue;
        if (source != .text) continue;
        if (std.mem.eql(u8, source.text, "alpha")) alpha = item;
        if (std.mem.eql(u8, source.text, "keyboard")) found_keyboard = true;
        if (std.mem.eql(u8, source.text, "mouse")) found_mouse = true;
    }
    try testing.expect(found_keyboard);
    try testing.expect(found_mouse);

    const found = alpha orelse return error.Missing;
    const num = found.getOutput("num") orelse return error.Missing;
    try testing.expectEqual(value_mod.ValueType.int, num.declared);
    try testing.expectEqual(@as(i64, 42), num.source.?.int);
}
