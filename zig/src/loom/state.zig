//! Durable recurrence: State and Delay.
//!
//! Ordinary computation is acyclic; recurrence enters only through an
//! explicit State or Delay texel whose previous value becomes a later
//! input.  The Spool treats a temporal texel as a source — demanding it
//! never evaluates upstream — and the TemporalRuntime advances it in one
//! durable step: demand the bound next value, then commit it as the new
//! current value.

const std = @import("std");
const store_mod = @import("../fabric/store.zig");
const spool_mod = @import("spool.zig");
const texel_id = @import("../fabric/texel_id.zig");
const value_mod = @import("../fabric/value.zig");
const texel_mod = @import("../fabric/texel.zig");

const Allocator = std.mem.Allocator;
const Store = store_mod.Store;
const Spool = spool_mod.Spool;
const TexelId = texel_id.TexelId;
const Value = value_mod.Value;
const ValueType = value_mod.ValueType;
const Texel = texel_mod.Texel;
const InputPort = texel_mod.InputPort;
const OutputPort = texel_mod.OutputPort;

pub const state_evaluator = "loom.state";
pub const delay_evaluator = "loom.delay";

pub const CreateError = error{ InvalidArgument, OutOfMemory };

pub const AdvanceError = error{
    MissingTexel,
    InvalidTemporal,
    NextUnbound,
    NextUnavailable,
    NextFailed,
    TypeMismatch,
    CommitFailed,
    OutOfMemory,
};

/// Build a State texel: one next input, one value output holding the
/// initial value.  Takes ownership of initial on success; the caller
/// keeps it on error.
pub fn createState(allocator: Allocator, id: TexelId, declared: ValueType, initial: Value) CreateError!Texel {
    return createTemporal(allocator, id, state_evaluator, declared, initial);
}

/// Build a Delay texel; identical shape, delayed advance semantics.
pub fn createDelay(allocator: Allocator, id: TexelId, declared: ValueType, initial: Value) CreateError!Texel {
    return createTemporal(allocator, id, delay_evaluator, declared, initial);
}

fn createTemporal(
    allocator: Allocator,
    id: TexelId,
    evaluator: []const u8,
    declared: ValueType,
    initial: Value,
) CreateError!Texel {
    if (id.isUnset() or declared == .none or initial.tag() != declared) {
        return CreateError.InvalidArgument;
    }

    var created = Texel.init(id);
    errdefer created.deinit(allocator);
    created.setEvaluator(allocator, evaluator) catch |err| switch (err) {
        error.OutOfMemory => return CreateError.OutOfMemory,
        error.EmptyName => unreachable,
    };
    created.putInput(allocator, try InputPort.init(allocator, "next", declared)) catch |err|
        switch (err) {
            error.OutOfMemory => return CreateError.OutOfMemory,
            else => unreachable,
        };

    var value = try OutputPort.init(allocator, "value", declared);
    errdefer value.deinit(allocator);
    value.setSource(allocator, initial) catch return CreateError.InvalidArgument;
    created.putOutput(allocator, value) catch |err| switch (err) {
        error.OutOfMemory => return CreateError.OutOfMemory,
        else => unreachable,
    };
    return created;
}

const TemporalShape = struct {
    next: *const InputPort,
    value: *const OutputPort,
};

fn temporalShape(texel: *const Texel) ?TemporalShape {
    const encode = @import("../fabric/encode.zig");
    if (!encode.temporalEvaluator(texel.evaluatorName())) return null;
    if (texel.inputCount() != 1 or texel.outputCount() != 1) return null;
    const next = texel.getInput("next") orelse return null;
    const value = texel.getOutput("value") orelse return null;
    const source = value.source orelse return null;
    if (next.declared != value.declared or source.tag() != value.declared) return null;
    return .{ .next = next, .value = value };
}

// ---------------------------------------------------------------------------
// TemporalRuntime
// ---------------------------------------------------------------------------
//
// Advances one durable State or Delay from its bound next value.  The
// demand happens against the current snapshot; the commit publishes the
// pulled value as the texel's new current value.
//
pub const TemporalRuntime = struct {
    pub fn advance(store: *Store, spool: *Spool, id: TexelId) AdvanceError!void {
        if (id.isUnset()) return AdvanceError.MissingTexel;
        const allocator = store.allocator;

        const temporal = store.get(id) orelse return AdvanceError.MissingTexel;
        const shape = temporalShape(temporal) orelse return AdvanceError.InvalidTemporal;
        const binding = shape.next.binding orelse return AdvanceError.NextUnbound;
        const revision = temporal.revision;

        const outcome = spool.demand(binding.source, binding.output) catch
            return AdvanceError.OutOfMemory;
        switch (outcome.*) {
            .err => return AdvanceError.NextFailed,
            .unavailable => return AdvanceError.NextUnavailable,
            .available => {},
        }
        if (outcome.available.tag() != shape.value.declared) {
            return AdvanceError.TypeMismatch;
        }
        // The outcome is borrowed from the Spool; copy the value out
        // before any mutation can move the cache under it.
        var pulled = outcome.available.clone(allocator) catch
            return AdvanceError.OutOfMemory;
        errdefer pulled.deinit(allocator);

        var transaction = store.begin() catch return AdvanceError.CommitFailed;
        defer transaction.deinit();

        const current = transaction.get(id) orelse return AdvanceError.MissingTexel;
        if (temporalShape(current) == null or current.revision != revision) {
            return AdvanceError.InvalidTemporal;
        }
        var changed = current.clone(allocator) catch return AdvanceError.OutOfMemory;
        defer changed.deinit(allocator);
        changed.mutableOutput("value").?.setSource(allocator, pulled) catch
            return AdvanceError.TypeMismatch;
        pulled = .none;

        transaction.put(&changed) catch return AdvanceError.CommitFailed;
        transaction.commit() catch return AdvanceError.CommitFailed;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const volume_mod = @import("../storage/volume.zig");
const Registry = spool_mod.Registry;
const Evaluator = spool_mod.Evaluator;
const OutcomeMap = spool_mod.OutcomeMap;

// next = value + 1, the smallest possible feedback computation.
const IncrementEvaluator = struct {
    fn evaluator(self: *IncrementEvaluator) Evaluator {
        return .{ .context = self, .evaluateFn = run };
    }

    fn run(
        context: *anyopaque,
        allocator: Allocator,
        texel: *const Texel,
        inputs: *const OutcomeMap,
        outputs: *OutcomeMap,
    ) spool_mod.Error!void {
        _ = context;
        _ = texel;
        const current = inputs.get("value") orelse .unavailable;
        if (current != .available) {
            try outputs.put(allocator, "next", .unavailable);
            return;
        }
        try outputs.put(allocator, "next", .{
            .available = .{ .int = current.available.int + 1 },
        });
    }
};

test "create validates identity, type, and initial value" {
    const allocator = testing.allocator;

    try testing.expectError(
        CreateError.InvalidArgument,
        createState(allocator, .unset, .int, .{ .int = 0 }),
    );
    try testing.expectError(
        CreateError.InvalidArgument,
        createState(allocator, TexelId.generate(std.testing.io), .int, .{ .boolean = true }),
    );

    var state = try createState(allocator, TexelId.generate(std.testing.io), .int, .{ .int = 5 });
    defer state.deinit(allocator);
    try testing.expectEqualStrings(state_evaluator, state.evaluatorName());
    try testing.expectEqual(@as(i64, 5), state.getOutput("value").?.source.?.int);
}

test "a state counter advances through its feedback loop" {
    const allocator = testing.allocator;
    var memory = try volume_mod.MemoryVolume.init(allocator, 32);
    defer memory.deinit();
    var store = try Store.create(allocator, memory.volume());
    defer store.deinit();

    var counter = try createState(allocator, TexelId.generate(std.testing.io), .int, .{ .int = 0 });
    defer counter.deinit(allocator);

    var increment = Texel.init(TexelId.generate(std.testing.io));
    defer increment.deinit(allocator);
    try increment.setEvaluator(allocator, "increment");
    try increment.putInput(allocator, try InputPort.init(allocator, "value", .int));
    try increment.putOutput(allocator, try OutputPort.init(allocator, "next", .int));

    {
        var transaction = try store.begin();
        defer transaction.deinit();
        try transaction.put(&counter);
        try transaction.put(&increment);
        // The loop: increment reads the counter, the counter's next is
        // the incremented value.  Only the State makes this legal.
        try transaction.connect(increment.id, "value", counter.id, "value");
        try transaction.connect(counter.id, "next", increment.id, "next");
        try transaction.commit();
    }

    var evaluator: IncrementEvaluator = .{};
    var registry = Registry.init(allocator);
    defer registry.deinit();
    try registry.put("increment", evaluator.evaluator());
    var spool = Spool.init(allocator, &store, &registry);
    defer spool.deinit();

    var round: i64 = 1;
    while (round <= 3) : (round += 1) {
        try TemporalRuntime.advance(&store, &spool, counter.id);
        const current = store.get(counter.id).?.getOutput("value").?.source.?;
        try testing.expectEqual(round, current.int);
    }
}

test "advance refuses missing, malformed, and unbound temporals" {
    const allocator = testing.allocator;
    var memory = try volume_mod.MemoryVolume.init(allocator, 32);
    defer memory.deinit();
    var store = try Store.create(allocator, memory.volume());
    defer store.deinit();

    var registry = Registry.init(allocator);
    defer registry.deinit();
    var spool = Spool.init(allocator, &store, &registry);
    defer spool.deinit();

    try testing.expectError(
        AdvanceError.MissingTexel,
        TemporalRuntime.advance(&store, &spool, TexelId.generate(std.testing.io)),
    );

    // A state whose next is never connected cannot advance.
    var lonely = try createState(allocator, TexelId.generate(std.testing.io), .int, .{ .int = 0 });
    defer lonely.deinit(allocator);
    var ordinary = Texel.init(TexelId.generate(std.testing.io));
    defer ordinary.deinit(allocator);
    var plain = try OutputPort.init(allocator, "value", .int);
    try plain.setSource(allocator, .{ .int = 9 });
    try ordinary.putOutput(allocator, plain);
    {
        var transaction = try store.begin();
        defer transaction.deinit();
        try transaction.put(&lonely);
        try transaction.put(&ordinary);
        try transaction.commit();
    }
    try testing.expectError(
        AdvanceError.NextUnbound,
        TemporalRuntime.advance(&store, &spool, lonely.id),
    );
    try testing.expectError(
        AdvanceError.InvalidTemporal,
        TemporalRuntime.advance(&store, &spool, ordinary.id),
    );
}
