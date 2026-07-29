//! Demand-driven, cached, acyclic evaluation.
//!
//! A Spool is a disposable demand cache over one read-only Store and a
//! non-owning evaluator registry.  Push invalidates; pull evaluates:
//! demand walks upstream, runs pure evaluators only where cached
//! revisions are stale, and caches every produced output by a fresh
//! effective revision.  advance stamps clean records across a reconcile
//! step so clean demands cost nothing.  Recurrence only enters through
//! explicit State and Delay texels, which demand treats as sources.

const std = @import("std");
const store_mod = @import("../fabric/store.zig");
const texel_id = @import("../fabric/texel_id.zig");
const value_mod = @import("../fabric/value.zig");
const texel_mod = @import("../fabric/texel.zig");
const encode = @import("../fabric/encode.zig");
const fiber_index = @import("fiber_index.zig");

const Allocator = std.mem.Allocator;
const Store = store_mod.Store;
const TexelId = texel_id.TexelId;
const Value = value_mod.Value;
const Texel = texel_mod.Texel;
const OutputPort = texel_mod.OutputPort;

const IdBytes = [TexelId.size]u8;

pub const Error = error{OutOfMemory};

// ---------------------------------------------------------------------------
// Outcome
// ---------------------------------------------------------------------------
//
// Explicit result of asking for a value: available, not yet available,
// or a structured error.  These travel through the evaluation model
// instead of hiding as process-global state.
//
pub const Outcome = union(enum) {
    available: Value,
    unavailable,
    err: []u8,

    pub fn initError(allocator: Allocator, message: []const u8) !Outcome {
        return .{ .err = try allocator.dupe(u8, message) };
    }

    pub fn clone(self: Outcome, allocator: Allocator) !Outcome {
        return switch (self) {
            .available => |source| .{ .available = try source.clone(allocator) },
            .unavailable => .unavailable,
            .err => |message| .{ .err = try allocator.dupe(u8, message) },
        };
    }

    pub fn deinit(self: *Outcome, allocator: Allocator) void {
        switch (self.*) {
            .available => |*source| source.deinit(allocator),
            .err => |message| allocator.free(message),
            .unavailable => {},
        }
        self.* = .unavailable;
    }
};

/// Port name to outcome, keyed by borrowed names.  Values are owned by
/// whoever holds the map.
pub const OutcomeMap = std.StringHashMapUnmanaged(Outcome);

fn deinitOutcomes(allocator: Allocator, outcomes: *OutcomeMap) void {
    var entries = outcomes.valueIterator();
    while (entries.next()) |outcome| outcome.deinit(allocator);
    outcomes.deinit(allocator);
}

// ---------------------------------------------------------------------------
// Evaluator
// ---------------------------------------------------------------------------
//
// Pure computation supplied to the Spool.  Inputs arrive keyed by input
// port name; the evaluator must place an outcome for every declared
// output into the outputs map (keys may be literals; the Spool copies
// what it caches).  Evaluators own no state the Fabric can see.
//
pub const Evaluator = struct {
    context: *anyopaque,
    evaluateFn: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        texel: *const Texel,
        inputs: *const OutcomeMap,
        outputs: *OutcomeMap,
    ) Error!void,

    pub fn evaluate(
        self: Evaluator,
        allocator: Allocator,
        texel: *const Texel,
        inputs: *const OutcomeMap,
        outputs: *OutcomeMap,
    ) Error!void {
        return self.evaluateFn(self.context, allocator, texel, inputs, outputs);
    }
};

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------
//
// Non-owning lookup table from persisted evaluator names to
// implementations.
//
pub const Registry = struct {
    allocator: Allocator,
    table: std.StringHashMapUnmanaged(Evaluator) = .empty,

    pub fn init(allocator: Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        var names = self.table.keyIterator();
        while (names.next()) |name| self.allocator.free(name.*);
        self.table.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn put(self: *Registry, name: []const u8, evaluator: Evaluator) !void {
        if (name.len == 0) return error.EmptyName;
        if (self.table.getPtr(name)) |existing| {
            existing.* = evaluator;
            return;
        }
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        try self.table.put(self.allocator, owned, evaluator);
    }

    pub fn get(self: *const Registry, name: []const u8) ?Evaluator {
        return self.table.get(name);
    }

    pub fn count(self: *const Registry) usize {
        return self.table.count();
    }
};

// ---------------------------------------------------------------------------
// Spool
// ---------------------------------------------------------------------------

const CachedOutput = struct {
    outcome: Outcome,
    effective_revision: u64,
};

const SourceRecord = struct {
    checked_generation: u64,
    texel_revision: u64,
    output_revision: u64,
    output: CachedOutput,
};

const ComputeRecord = struct {
    checked_generation: u64,
    texel_revision: u64,
    input_revisions: []u64,
    outputs: std.StringHashMapUnmanaged(CachedOutput),

    fn deinit(self: *ComputeRecord, allocator: Allocator) void {
        allocator.free(self.input_revisions);
        var entries = self.outputs.iterator();
        while (entries.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.outcome.deinit(allocator);
        }
        self.outputs.deinit(allocator);
        self.* = undefined;
    }
};

const DemandResult = struct {
    outcome: *const Outcome,
    effective_revision: u64,
};

pub const Spool = struct {
    allocator: Allocator,
    store: *const Store,
    registry: *const Registry,
    source_cache: std.StringHashMapUnmanaged(SourceRecord) = .empty,
    compute_cache: std.AutoHashMapUnmanaged(IdBytes, ComputeRecord) = .empty,
    active: std.AutoHashMapUnmanaged(IdBytes, void) = .empty,
    next_revision: u64 = 1,
    transient: Outcome = .unavailable,

    pub fn init(allocator: Allocator, store: *const Store, registry: *const Registry) Spool {
        return .{ .allocator = allocator, .store = store, .registry = registry };
    }

    pub fn deinit(self: *Spool) void {
        self.clear();
        self.source_cache.deinit(self.allocator);
        self.compute_cache.deinit(self.allocator);
        self.active.deinit(self.allocator);
        self.transient.deinit(self.allocator);
        self.* = undefined;
    }

    /// Demand one output.  The returned outcome is borrowed from the
    /// Spool and valid until the next call that mutates it.
    pub fn demand(self: *Spool, id: TexelId, output: []const u8) Error!*const Outcome {
        if (id.isUnset()) return self.transientError("demand has unset texel id");
        if (output.len == 0) return self.transientError("demand has empty output name");

        const generation = self.store.generation;
        const result = try self.demandInternal(id, output, generation);
        self.active.clearRetainingCapacity();
        return result.outcome;
    }

    /// Advance the cache across one reconcile step: records checked at
    /// from_generation whose texel is not dirty are stamped as checked
    /// at to_generation without touching the Store.  The dirty set must
    /// be a conservative transitive closure of everything changed in
    /// between; anything else revalidates lazily on its next demand.
    pub fn advance(self: *Spool, from_generation: u64, to_generation: u64, dirty: []const TexelId) void {
        var sources = self.source_cache.iterator();
        while (sources.next()) |entry| {
            if (entry.value_ptr.checked_generation != from_generation) continue;
            var id: TexelId = .{};
            @memcpy(&id.bytes, entry.key_ptr.*[0..TexelId.size]);
            if (fiber_index.contains(dirty, id)) continue;
            entry.value_ptr.checked_generation = to_generation;
        }
        var computes = self.compute_cache.iterator();
        while (computes.next()) |entry| {
            if (entry.value_ptr.checked_generation != from_generation) continue;
            var id: TexelId = .{};
            @memcpy(&id.bytes, entry.key_ptr);
            if (fiber_index.contains(dirty, id)) continue;
            entry.value_ptr.checked_generation = to_generation;
        }
    }

    pub fn clear(self: *Spool) void {
        var sources = self.source_cache.iterator();
        while (sources.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.output.outcome.deinit(self.allocator);
        }
        self.source_cache.clearRetainingCapacity();
        var computes = self.compute_cache.valueIterator();
        while (computes.next()) |record| record.deinit(self.allocator);
        self.compute_cache.clearRetainingCapacity();
        self.active.clearRetainingCapacity();
    }

    pub fn cacheSize(self: *const Spool) usize {
        var total: usize = self.source_cache.count();
        var computes = self.compute_cache.valueIterator();
        while (computes.next()) |record| total += record.outputs.count();
        return total;
    }

    // Internal ---------------------------------------------------------------

    fn transientError(self: *Spool, message: []const u8) Error!*const Outcome {
        self.transient.deinit(self.allocator);
        self.transient = try Outcome.initError(self.allocator, message);
        return &self.transient;
    }

    fn transientResult(self: *Spool, message: []const u8) Error!DemandResult {
        return .{ .outcome = try self.transientError(message), .effective_revision = 0 };
    }

    fn endpointKey(self: *Spool, id: TexelId, output: []const u8) Error![]u8 {
        const key = try self.allocator.alloc(u8, TexelId.size + output.len);
        @memcpy(key[0..TexelId.size], &id.bytes);
        @memcpy(key[TexelId.size..], output);
        return key;
    }

    fn demandInternal(self: *Spool, id: TexelId, output: []const u8, generation: u64) Error!DemandResult {
        // A cached endpoint already checked against this generation wins.
        {
            const key = try self.endpointKey(id, output);
            defer self.allocator.free(key);
            if (self.source_cache.getPtr(key)) |record| {
                if (record.checked_generation == generation) {
                    return .{
                        .outcome = &record.output.outcome,
                        .effective_revision = record.output.effective_revision,
                    };
                }
            }
        }
        if (self.compute_cache.getPtr(id.bytes)) |record| {
            if (record.checked_generation == generation) {
                if (record.outputs.getPtr(output)) |cached| {
                    return .{
                        .outcome = &cached.outcome,
                        .effective_revision = cached.effective_revision,
                    };
                }
            }
        }

        const current = self.store.get(id) orelse
            return self.transientResult("missing texel");
        const declared = current.getOutput(output) orelse
            return self.transientResult("missing output");

        if (current.evaluator == null or encode.temporalEvaluator(current.evaluatorName())) {
            return self.demandSource(current, declared, generation);
        }

        if (self.active.contains(id.bytes)) {
            return self.transientResult("recursive demand cycle");
        }
        try self.active.put(self.allocator, id.bytes, {});
        defer _ = self.active.remove(id.bytes);
        return self.demandComputed(current, output, generation);
    }

    fn demandSource(self: *Spool, current: *const Texel, declared: *const OutputPort, generation: u64) Error!DemandResult {
        const key = try self.endpointKey(current.id, declared.name);
        var keep_key = false;
        defer if (!keep_key) self.allocator.free(key);

        if (self.source_cache.getPtr(key)) |record| {
            if (record.texel_revision == current.revision and
                record.output_revision == declared.revision)
            {
                record.checked_generation = generation;
                return .{
                    .outcome = &record.output.outcome,
                    .effective_revision = record.output.effective_revision,
                };
            }
        }

        var outcome: Outcome = .unavailable;
        errdefer outcome.deinit(self.allocator);
        if (declared.source) |source| {
            if (source.tag() != declared.declared) {
                outcome = try Outcome.initError(self.allocator, "source type mismatch");
            } else {
                outcome = .{ .available = try source.clone(self.allocator) };
            }
        }

        const effective = self.nextEffectiveRevision() orelse
            return self.transientResult("spool effective revisions exhausted");
        const record: SourceRecord = .{
            .checked_generation = generation,
            .texel_revision = current.revision,
            .output_revision = declared.revision,
            .output = .{ .outcome = outcome, .effective_revision = effective },
        };

        if (self.source_cache.getPtr(key)) |existing| {
            existing.output.outcome.deinit(self.allocator);
            existing.* = record;
        } else {
            try self.source_cache.put(self.allocator, key, record);
            keep_key = true;
        }
        const stored = self.source_cache.getPtr(key).?;
        return .{
            .outcome = &stored.output.outcome,
            .effective_revision = stored.output.effective_revision,
        };
    }

    fn demandComputed(self: *Spool, current: *const Texel, output: []const u8, generation: u64) Error!DemandResult {
        var inputs: OutcomeMap = .empty;
        defer deinitOutcomes(self.allocator, &inputs);
        var revisions: std.ArrayList(u64) = .empty;
        defer revisions.deinit(self.allocator);

        for (current.inputs.items) |input| {
            const binding = input.binding orelse {
                try inputs.put(self.allocator, input.name, .unavailable);
                try revisions.append(self.allocator, 0);
                continue;
            };

            const source = self.store.get(binding.source) orelse
                return self.cacheError(current, output, generation, revisions.items, "missing source texel");
            const offered = source.getOutput(binding.output) orelse
                return self.cacheError(current, output, generation, revisions.items, "missing source output");
            if (offered.declared != input.declared) {
                return self.cacheError(current, output, generation, revisions.items, "input type mismatch");
            }

            const upstream = try self.demandInternal(binding.source, binding.output, generation);
            try inputs.put(self.allocator, input.name, try upstream.outcome.clone(self.allocator));
            try revisions.append(self.allocator, upstream.effective_revision);
            if (upstream.outcome.* == .err) {
                return self.cacheError(current, output, generation, revisions.items, upstream.outcome.err);
            }
        }

        // Unchanged texel and input revisions mean the cached outputs are
        // still true; the evaluator never runs (early cutoff).
        if (self.compute_cache.getPtr(current.id.bytes)) |record| {
            if (record.texel_revision == current.revision and
                std.mem.eql(u64, record.input_revisions, revisions.items))
            {
                if (record.outputs.getPtr(output)) |cached| {
                    record.checked_generation = generation;
                    return .{
                        .outcome = &cached.outcome,
                        .effective_revision = cached.effective_revision,
                    };
                }
            }
        }

        return self.evaluate(current, output, generation, &inputs, revisions.items);
    }

    fn evaluate(
        self: *Spool,
        current: *const Texel,
        output: []const u8,
        generation: u64,
        inputs: *const OutcomeMap,
        revisions: []const u64,
    ) Error!DemandResult {
        const evaluator = self.registry.get(current.evaluatorName()) orelse
            return self.cacheError(current, output, generation, revisions, "missing evaluator");

        var evaluated: OutcomeMap = .empty;
        defer deinitOutcomes(self.allocator, &evaluated);
        try evaluator.evaluate(self.allocator, current, inputs, &evaluated);

        // Every returned name must be declared with a matching type, and
        // every declared output must have been produced.
        var returned = evaluated.iterator();
        while (returned.next()) |entry| {
            const declared = current.getOutput(entry.key_ptr.*) orelse
                return self.cacheError(current, output, generation, revisions, "evaluator returned unknown output");
            if (entry.value_ptr.* == .available and
                entry.value_ptr.available.tag() != declared.declared)
            {
                return self.cacheError(current, output, generation, revisions, "evaluator output type mismatch");
            }
        }
        for (current.outputs.items) |declared| {
            if (!evaluated.contains(declared.name)) {
                return self.cacheError(current, output, generation, revisions, "evaluator omitted output");
            }
        }

        var record: ComputeRecord = .{
            .checked_generation = generation,
            .texel_revision = current.revision,
            .input_revisions = try self.allocator.dupe(u64, revisions),
            .outputs = .empty,
        };
        errdefer record.deinit(self.allocator);

        for (current.outputs.items) |declared| {
            const effective = self.nextEffectiveRevision() orelse
                return self.transientResult("spool effective revisions exhausted");
            const produced = evaluated.getPtr(declared.name).?;
            const cached: CachedOutput = .{
                .outcome = produced.*,
                .effective_revision = effective,
            };
            produced.* = .unavailable; // ownership moved into the cache
            const owned_name = try self.allocator.dupe(u8, declared.name);
            errdefer self.allocator.free(owned_name);
            try record.outputs.put(self.allocator, owned_name, cached);
        }

        try self.replaceComputeRecord(current.id, record);
        const stored = self.compute_cache.getPtr(current.id.bytes).?;
        const demanded = stored.outputs.getPtr(output).?;
        return .{
            .outcome = &demanded.outcome,
            .effective_revision = demanded.effective_revision,
        };
    }

    /// A failed computation is cached like any other result: every
    /// declared output carries the error until inputs move again.
    fn cacheError(
        self: *Spool,
        current: *const Texel,
        output: []const u8,
        generation: u64,
        revisions: []const u64,
        message: []const u8,
    ) Error!DemandResult {
        var record: ComputeRecord = .{
            .checked_generation = generation,
            .texel_revision = current.revision,
            .input_revisions = try self.allocator.dupe(u64, revisions),
            .outputs = .empty,
        };
        errdefer record.deinit(self.allocator);

        for (current.outputs.items) |declared| {
            const effective = self.nextEffectiveRevision() orelse
                return self.transientResult("spool effective revisions exhausted");
            const owned_name = try self.allocator.dupe(u8, declared.name);
            errdefer self.allocator.free(owned_name);
            try record.outputs.put(self.allocator, owned_name, .{
                .outcome = try Outcome.initError(self.allocator, message),
                .effective_revision = effective,
            });
        }

        try self.replaceComputeRecord(current.id, record);
        const stored = self.compute_cache.getPtr(current.id.bytes).?;
        if (stored.outputs.getPtr(output)) |demanded| {
            return .{
                .outcome = &demanded.outcome,
                .effective_revision = demanded.effective_revision,
            };
        }
        return self.transientResult(message);
    }

    fn replaceComputeRecord(self: *Spool, id: TexelId, record: ComputeRecord) Error!void {
        if (self.compute_cache.getPtr(id.bytes)) |existing| {
            existing.deinit(self.allocator);
            self.compute_cache.getPtr(id.bytes).?.* = record;
            return;
        }
        try self.compute_cache.put(self.allocator, id.bytes, record);
    }

    fn nextEffectiveRevision(self: *Spool) ?u64 {
        if (self.next_revision == std.math.maxInt(u64)) return null;
        const revision = self.next_revision;
        self.next_revision += 1;
        return revision;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const volume_mod = @import("../storage/volume.zig");
const InputPort = texel_mod.InputPort;
const FiberIndex = fiber_index.FiberIndex;

const ConcatEvaluator = struct {
    calls: usize = 0,

    fn evaluator(self: *ConcatEvaluator) Evaluator {
        return .{ .context = self, .evaluateFn = run };
    }

    fn run(
        context: *anyopaque,
        allocator: Allocator,
        texel: *const Texel,
        inputs: *const OutcomeMap,
        outputs: *OutcomeMap,
    ) Error!void {
        _ = texel;
        const self: *ConcatEvaluator = @ptrCast(@alignCast(context));
        self.calls += 1;

        const left = inputs.get("left") orelse .unavailable;
        const right = inputs.get("right") orelse .unavailable;
        if (left != .available or right != .available) {
            try outputs.put(allocator, "value", .unavailable);
            return;
        }
        const joined = try std.mem.concat(allocator, u8, &.{
            left.available.text,
            right.available.text,
        });
        try outputs.put(allocator, "value", .{ .available = .{ .text = joined } });
    }
};

fn sourceTexel(allocator: Allocator, text: []const u8) !Texel {
    var item = Texel.init(TexelId.generate(std.testing.io));
    errdefer item.deinit(allocator);
    var output = try OutputPort.init(allocator, "value", .text);
    try output.setSource(allocator, try Value.initText(allocator, text));
    try item.putOutput(allocator, output);
    return item;
}

const Graph = struct {
    memory: volume_mod.MemoryVolume,
    store: Store,
    left: Texel,
    right: Texel,
    unrelated: Texel,
    joined: Texel,

    // Fills self in place: the store keeps a pointer to self.memory, so
    // a Graph must never move once set up.
    fn setup(self: *Graph, allocator: Allocator) !void {
        self.memory = try volume_mod.MemoryVolume.init(allocator, 32);
        errdefer self.memory.deinit();
        self.store = try Store.create(allocator, self.memory.volume());
        errdefer self.store.deinit();

        self.left = try sourceTexel(allocator, "hello ");
        errdefer self.left.deinit(allocator);
        self.right = try sourceTexel(allocator, "world");
        errdefer self.right.deinit(allocator);
        self.unrelated = try sourceTexel(allocator, "elsewhere");
        errdefer self.unrelated.deinit(allocator);

        self.joined = Texel.init(TexelId.generate(std.testing.io));
        errdefer self.joined.deinit(allocator);
        try self.joined.setEvaluator(allocator, "concat");
        try self.joined.putInput(allocator, try InputPort.init(allocator, "left", .text));
        try self.joined.putInput(allocator, try InputPort.init(allocator, "right", .text));
        try self.joined.putOutput(allocator, try OutputPort.init(allocator, "value", .text));

        var transaction = try self.store.begin();
        defer transaction.deinit();
        try transaction.put(&self.left);
        try transaction.put(&self.right);
        try transaction.put(&self.unrelated);
        try transaction.put(&self.joined);
        try transaction.connect(self.joined.id, "left", self.left.id, "value");
        try transaction.connect(self.joined.id, "right", self.right.id, "value");
        try transaction.commit();
    }

    fn deinit(self: *Graph, allocator: Allocator) void {
        self.left.deinit(allocator);
        self.right.deinit(allocator);
        self.unrelated.deinit(allocator);
        self.joined.deinit(allocator);
        self.store.deinit();
        self.memory.deinit();
    }

    fn setSource(self: *Graph, allocator: Allocator, id: TexelId, text: []const u8) !void {
        var transaction = try self.store.begin();
        defer transaction.deinit();
        var changed = try self.store.get(id).?.clone(allocator);
        defer changed.deinit(allocator);
        try changed.mutableOutput("value").?.setSource(allocator, try Value.initText(allocator, text));
        try transaction.put(&changed);
        try transaction.commit();
    }
};

test "demand caches, invalidates on change, and ignores unrelated commits" {
    const allocator = testing.allocator;
    var graph: Graph = undefined;
    try graph.setup(allocator);
    defer graph.deinit(allocator);

    var concat: ConcatEvaluator = .{};
    var registry = Registry.init(allocator);
    defer registry.deinit();
    try registry.put("concat", concat.evaluator());

    var spool = Spool.init(allocator, &graph.store, &registry);
    defer spool.deinit();

    var outcome = try spool.demand(graph.joined.id, "value");
    try testing.expectEqualStrings("hello world", outcome.available.text);
    try testing.expectEqual(@as(usize, 1), concat.calls);

    outcome = try spool.demand(graph.joined.id, "value");
    try testing.expectEqual(@as(usize, 1), concat.calls);

    try graph.setSource(allocator, graph.left.id, "goodbye ");
    outcome = try spool.demand(graph.joined.id, "value");
    try testing.expectEqualStrings("goodbye world", outcome.available.text);
    try testing.expectEqual(@as(usize, 2), concat.calls);

    // An unrelated commit revalidates without evaluating.
    try graph.setSource(allocator, graph.unrelated.id, "moved");
    outcome = try spool.demand(graph.joined.id, "value");
    try testing.expectEqual(@as(usize, 2), concat.calls);
}

test "missing evaluator and missing endpoints produce error outcomes" {
    const allocator = testing.allocator;
    var graph: Graph = undefined;
    try graph.setup(allocator);
    defer graph.deinit(allocator);

    var registry = Registry.init(allocator);
    defer registry.deinit();
    var spool = Spool.init(allocator, &graph.store, &registry);
    defer spool.deinit();

    var outcome = try spool.demand(graph.joined.id, "value");
    try testing.expect(outcome.* == .err);
    try testing.expectEqualStrings("missing evaluator", outcome.err);

    outcome = try spool.demand(graph.joined.id, "absent");
    try testing.expect(outcome.* == .err);
    outcome = try spool.demand(TexelId.generate(std.testing.io), "value");
    try testing.expect(outcome.* == .err);
}

test "advance keeps clean records hot and dirty paths lazy" {
    const allocator = testing.allocator;
    var graph: Graph = undefined;
    try graph.setup(allocator);
    defer graph.deinit(allocator);

    var concat: ConcatEvaluator = .{};
    var registry = Registry.init(allocator);
    defer registry.deinit();
    try registry.put("concat", concat.evaluator());

    var spool = Spool.init(allocator, &graph.store, &registry);
    defer spool.deinit();
    var index = FiberIndex.init(allocator);
    defer index.deinit();
    try index.build(&graph.store);

    var seen = graph.store.generation;
    var outcome = try spool.demand(graph.joined.id, "value");
    try testing.expectEqualStrings("hello world", outcome.available.text);
    try testing.expectEqual(@as(usize, 1), concat.calls);

    // Unrelated commit: reconcile stamps the clean records.
    try graph.setSource(allocator, graph.unrelated.id, "moved");
    {
        const changed = (try graph.store.changesSince(allocator, seen)).?;
        defer allocator.free(changed);
        try index.apply(&graph.store, changed);
        const dirty = try index.downstream(allocator, changed);
        defer allocator.free(dirty);
        try testing.expectEqual(@as(usize, 1), dirty.len);
        spool.advance(seen, graph.store.generation, dirty);
        seen = graph.store.generation;
    }
    outcome = try spool.demand(graph.joined.id, "value");
    try testing.expectEqual(@as(usize, 1), concat.calls);

    // Upstream observation: the dirty closure reaches the join and only
    // that path recomputes on demand.
    try graph.store.observe(graph.left.id, "value", try Value.initText(allocator, "observed "));
    {
        const changed = (try graph.store.changesSince(allocator, seen)).?;
        defer allocator.free(changed);
        try index.apply(&graph.store, changed);
        const dirty = try index.downstream(allocator, changed);
        defer allocator.free(dirty);
        try testing.expect(fiber_index.contains(dirty, graph.joined.id));
        spool.advance(seen, graph.store.generation, dirty);
        seen = graph.store.generation;
    }
    outcome = try spool.demand(graph.joined.id, "value");
    try testing.expectEqualStrings("observed world", outcome.available.text);
    try testing.expectEqual(@as(usize, 2), concat.calls);
}
