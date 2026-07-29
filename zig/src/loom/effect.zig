//! Effects: intents as data, performed once at a trusted boundary.
//!
//! A pure evaluator may be repeated without changing the world; sending a
//! message or charging a card may not.  An effect is therefore data — an
//! intent with a stable request identity — and only the EffectBoundary
//! touches the world: it verifies a connected capability, runs the
//! registered executor once, and persists the observation under a receipt
//! identity derived from the request.  Replays return the stored receipt
//! instead of repeating the action.  The LUEFINT and LUEFOBS encodings
//! are frozen contracts shared with the C++ tree.

const std = @import("std");
const store_mod = @import("../fabric/store.zig");
const spool_mod = @import("spool.zig");
const capability_mod = @import("../realm/capability.zig");
const texel_id = @import("../fabric/texel_id.zig");
const value_mod = @import("../fabric/value.zig");
const texel_mod = @import("../fabric/texel.zig");

const Allocator = std.mem.Allocator;
const Store = store_mod.Store;
const Spool = spool_mod.Spool;
const Authority = capability_mod.Authority;
const Capability = capability_mod.Capability;
const TexelId = texel_id.TexelId;
const Value = value_mod.Value;
const Texel = texel_mod.Texel;
const InputPort = texel_mod.InputPort;
const OutputPort = texel_mod.OutputPort;

pub const request_id_size = 32;
const effect_version: u32 = 1;
const intent_magic = [8]u8{ 'L', 'U', 'E', 'F', 'I', 'N', 'T', 0 };
const observation_magic = [8]u8{ 'L', 'U', 'E', 'F', 'O', 'B', 'S', 0 };
const max_name_size = 4096;

pub const Error = error{ InvalidArgument, OutOfMemory };

pub const RequestId = [request_id_size]u8;

fn validName(name: []const u8) bool {
    return name.len > 0 and name.len <= max_name_size and
        std.mem.findScalar(u8, name, 0) == null;
}

// ---------------------------------------------------------------------------
// Intent
// ---------------------------------------------------------------------------
//
// Deterministic effect request data.  It deliberately carries no Fabric
// identity: request identity belongs to the effect protocol, not to a
// Texel.
//
pub const Intent = struct {
    request_id: RequestId,
    operation: []u8,
    target: []u8,
    payload: []u8,

    pub fn init(
        allocator: Allocator,
        request_id: RequestId,
        operation: []const u8,
        target: []const u8,
        payload: []const u8,
    ) Error!Intent {
        if (std.mem.allEqual(u8, &request_id, 0)) return Error.InvalidArgument;
        if (!validName(operation) or !validName(target)) return Error.InvalidArgument;

        const owned_operation = try allocator.dupe(u8, operation);
        errdefer allocator.free(owned_operation);
        const owned_target = try allocator.dupe(u8, target);
        errdefer allocator.free(owned_target);
        return .{
            .request_id = request_id,
            .operation = owned_operation,
            .target = owned_target,
            .payload = try allocator.dupe(u8, payload),
        };
    }

    pub fn deinit(self: *Intent, allocator: Allocator) void {
        allocator.free(self.operation);
        allocator.free(self.target);
        allocator.free(self.payload);
        self.* = undefined;
    }

    pub fn valid(self: Intent) bool {
        return !std.mem.allEqual(u8, &self.request_id, 0) and
            validName(self.operation) and validName(self.target);
    }
};

pub fn encodeIntent(allocator: Allocator, intent: Intent) Error!Value {
    if (!intent.valid()) return Error.InvalidArgument;

    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, &intent_magic);
    try appendU32(allocator, &bytes, effect_version);
    try bytes.appendSlice(allocator, &intent.request_id);
    try appendU32(allocator, &bytes, @intCast(intent.operation.len));
    try bytes.appendSlice(allocator, intent.operation);
    try appendU32(allocator, &bytes, @intCast(intent.target.len));
    try bytes.appendSlice(allocator, intent.target);
    try appendU32(allocator, &bytes, @intCast(intent.payload.len));
    try bytes.appendSlice(allocator, intent.payload);
    return .{ .bytes = try bytes.toOwnedSlice(allocator) };
}

pub fn decodeIntent(allocator: Allocator, value: Value) Error!Intent {
    if (value.tag() != .bytes) return Error.InvalidArgument;

    var reader: ByteReader = .{ .data = value.bytes };
    const magic = reader.take(intent_magic.len) orelse return Error.InvalidArgument;
    if (!std.mem.eql(u8, magic, &intent_magic)) return Error.InvalidArgument;
    if ((reader.u32Value() orelse return Error.InvalidArgument) != effect_version) {
        return Error.InvalidArgument;
    }

    var request_id: RequestId = undefined;
    const raw = reader.take(request_id_size) orelse return Error.InvalidArgument;
    @memcpy(&request_id, raw);
    const operation = reader.name() orelse return Error.InvalidArgument;
    const target = reader.name() orelse return Error.InvalidArgument;
    const payload = reader.bytes() orelse return Error.InvalidArgument;
    if (!reader.done()) return Error.InvalidArgument;
    return Intent.init(allocator, request_id, operation, target, payload);
}

// ---------------------------------------------------------------------------
// Observation
// ---------------------------------------------------------------------------
//
// Durable result associated with one request id.  bytes carries the
// executor result on success and structured executor error data on
// failure.
//
pub const Observation = struct {
    request_id: RequestId,
    success: bool,
    bytes: []u8,

    pub fn init(allocator: Allocator, request_id: RequestId, success: bool, bytes: []const u8) Error!Observation {
        if (std.mem.allEqual(u8, &request_id, 0)) return Error.InvalidArgument;
        return .{
            .request_id = request_id,
            .success = success,
            .bytes = try allocator.dupe(u8, bytes),
        };
    }

    pub fn clone(self: Observation, allocator: Allocator) Error!Observation {
        return init(allocator, self.request_id, self.success, self.bytes);
    }

    pub fn deinit(self: *Observation, allocator: Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn valid(self: Observation) bool {
        return !std.mem.allEqual(u8, &self.request_id, 0);
    }
};

pub fn encodeObservation(allocator: Allocator, observation: Observation) Error!Value {
    if (!observation.valid()) return Error.InvalidArgument;

    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, &observation_magic);
    try appendU32(allocator, &bytes, effect_version);
    try bytes.appendSlice(allocator, &observation.request_id);
    try bytes.append(allocator, if (observation.success) 1 else 0);
    try appendU32(allocator, &bytes, @intCast(observation.bytes.len));
    try bytes.appendSlice(allocator, observation.bytes);
    return .{ .bytes = try bytes.toOwnedSlice(allocator) };
}

pub fn decodeObservation(allocator: Allocator, value: Value) Error!Observation {
    if (value.tag() != .bytes) return Error.InvalidArgument;

    var reader: ByteReader = .{ .data = value.bytes };
    const magic = reader.take(observation_magic.len) orelse return Error.InvalidArgument;
    if (!std.mem.eql(u8, magic, &observation_magic)) return Error.InvalidArgument;
    if ((reader.u32Value() orelse return Error.InvalidArgument) != effect_version) {
        return Error.InvalidArgument;
    }

    var request_id: RequestId = undefined;
    const raw = reader.take(request_id_size) orelse return Error.InvalidArgument;
    @memcpy(&request_id, raw);
    const flag = (reader.take(1) orelse return Error.InvalidArgument)[0];
    if (flag > 1) return Error.InvalidArgument;
    const result = reader.bytes() orelse return Error.InvalidArgument;
    if (!reader.done()) return Error.InvalidArgument;
    return Observation.init(allocator, request_id, flag == 1, result);
}

// ---------------------------------------------------------------------------
// Executor
// ---------------------------------------------------------------------------
//
// Executors are trusted and non-owning.  perform must be idempotent by
// request id: retrying the same request must return the same logical
// observation without repeating the outside-world action.  Arbitrary
// exactly-once effects are otherwise impossible, because Store commit
// and the outside world cannot be made crash-atomic.
//
pub const Executor = struct {
    context: *anyopaque,
    performFn: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        intent: *const Intent,
    ) error{ ExecutorFailed, OutOfMemory }!Observation,

    pub fn perform(self: Executor, allocator: Allocator, intent: *const Intent) error{ ExecutorFailed, OutOfMemory }!Observation {
        return self.performFn(self.context, allocator, intent);
    }
};

pub const ExecutorRegistry = struct {
    allocator: Allocator,
    table: std.StringHashMapUnmanaged(Executor) = .empty,

    pub fn init(allocator: Allocator) ExecutorRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ExecutorRegistry) void {
        var names = self.table.keyIterator();
        while (names.next()) |name| self.allocator.free(name.*);
        self.table.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn put(self: *ExecutorRegistry, operation: []const u8, executor: Executor) !void {
        if (!validName(operation)) return Error.InvalidArgument;
        if (self.table.getPtr(operation)) |existing| {
            existing.* = executor;
            return;
        }
        const owned = try self.allocator.dupe(u8, operation);
        errdefer self.allocator.free(owned);
        try self.table.put(self.allocator, owned, executor);
    }

    pub fn get(self: *const ExecutorRegistry, operation: []const u8) ?Executor {
        return self.table.get(operation);
    }
};

// ---------------------------------------------------------------------------
// Boundary
// ---------------------------------------------------------------------------

pub const BoundaryCode = enum {
    performed,
    replayed,
    invalid_argument,
    missing_effect,
    malformed_effect,
    missing_intent,
    malformed_intent,
    missing_capability,
    malformed_capability,
    capability_denied,
    missing_executor,
    executor_failed,
    invalid_observation,
    store_failed,
    malformed_receipt,
};

// A structured boundary result.  The observation is present only for
// performed or replayed effects; denied and malformed requests perform
// nothing.  Messages are static; the observation is owned.
pub const BoundaryResult = struct {
    code: BoundaryCode,
    message: []const u8 = "",
    observation: ?Observation = null,

    pub fn deinit(self: *BoundaryResult, allocator: Allocator) void {
        if (self.observation) |*observation| observation.deinit(allocator);
        self.* = undefined;
    }

    pub fn succeeded(self: BoundaryResult) bool {
        return self.code == .performed or self.code == .replayed;
    }
};

/// The stable receipt identity for a request id.
pub fn observationId(request_id: RequestId) ?TexelId {
    if (std.mem.allEqual(u8, &request_id, 0)) return null;
    return .{ .bytes = request_id };
}

/// Build an effect texel: an intent output plus a capability input for
/// the connected grant.
pub fn makeEffectTexel(allocator: Allocator, id: TexelId, intent: Intent) Error!Texel {
    if (id.isUnset() or !intent.valid()) return Error.InvalidArgument;
    var encoded = try encodeIntent(allocator, intent);
    errdefer encoded.deinit(allocator);

    var made = Texel.init(id);
    errdefer made.deinit(allocator);
    var output = try OutputPort.init(allocator, "intent", .bytes);
    errdefer output.deinit(allocator);
    output.setSource(allocator, encoded) catch unreachable;
    made.putOutput(allocator, output) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        else => unreachable,
    };
    made.putInput(allocator, try InputPort.init(allocator, "capability", .bytes)) catch |err|
        switch (err) {
            error.OutOfMemory => return Error.OutOfMemory,
            else => unreachable,
        };
    return made;
}

/// Build a capability texel offering the encoded grant on one output.
pub fn makeCapabilityTexel(allocator: Allocator, id: TexelId, held: Capability) Error!Texel {
    if (id.isUnset()) return Error.InvalidArgument;
    var encoded = capability_mod.encodeCapability(allocator, held) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        error.InvalidArgument => return Error.InvalidArgument,
    };
    errdefer encoded.deinit(allocator);

    var made = Texel.init(id);
    errdefer made.deinit(allocator);
    var output = try OutputPort.init(allocator, "capability", .bytes);
    errdefer output.deinit(allocator);
    output.setSource(allocator, encoded) catch unreachable;
    made.putOutput(allocator, output) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        else => unreachable,
    };
    return made;
}

// The only object here with Store and executor access.  Evaluators stay
// pure: they receive neither.  Store, Spool, Authority, and registry are
// non-owning and must outlive this boundary.
pub const Boundary = struct {
    store: *Store,
    spool: *Spool,
    authority: *const Authority,
    registry: *const ExecutorRegistry,

    /// Perform (or replay) one effect texel.  The caller deinits the
    /// result.
    pub fn perform(self: *Boundary, effect: TexelId) error{OutOfMemory}!BoundaryResult {
        const allocator = self.store.allocator;
        if (effect.isUnset()) {
            return fail(.invalid_argument, "invalid effect boundary");
        }

        const effect_texel = self.store.get(effect) orelse
            return fail(.missing_effect, "effect texel is missing");
        const intent_port = effect_texel.getOutput("intent") orelse
            return fail(.malformed_effect, "effect port shape is invalid");
        const capability_port = effect_texel.getInput("capability") orelse
            return fail(.malformed_effect, "effect port shape is invalid");
        if (intent_port.declared != .bytes or capability_port.declared != .bytes) {
            return fail(.malformed_effect, "effect port shape is invalid");
        }
        const capability_binding = capability_port.binding;

        // Decode the intent into owned data before any further demand
        // can move the Spool's caches under the borrowed outcome.
        var intent: Intent = blk: {
            const outcome = try self.spool.demand(effect, "intent");
            const bytes = availableBytes(outcome) orelse switch (outcome.*) {
                .unavailable => return fail(.missing_intent, "effect intent is unavailable"),
                else => return fail(.malformed_intent, "effect intent demand failed"),
            };
            break :blk decodeIntent(allocator, bytes) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidArgument => return fail(.malformed_intent, "effect intent is malformed"),
            };
        };
        defer intent.deinit(allocator);

        // A stored receipt means the world already moved: replay it.
        const receipt_id = observationId(intent.request_id).?;
        if (self.store.has(receipt_id)) {
            const stored = self.loadObservation(receipt_id) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidArgument => return fail(.malformed_receipt, "stored effect receipt is malformed"),
            };
            if (!std.mem.eql(u8, &stored.request_id, &intent.request_id)) {
                var replay = stored;
                replay.deinit(allocator);
                return fail(.malformed_receipt, "stored effect receipt is malformed");
            }
            return .{ .code = .replayed, .observation = stored };
        }

        // The capability must arrive through an explicit connection and
        // grant exactly this operation on this target.
        const binding = capability_binding orelse
            return fail(.missing_capability, "effect capability is not connected");
        var granted: Capability = blk: {
            const outcome = try self.spool.demand(binding.source, binding.output);
            const bytes = availableBytes(outcome) orelse switch (outcome.*) {
                .unavailable => return fail(.missing_capability, "effect capability is unavailable"),
                else => return fail(.malformed_capability, "effect capability demand failed"),
            };
            break :blk capability_mod.decodeCapability(allocator, bytes) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidArgument => return fail(.malformed_capability, "effect capability is malformed"),
            };
        };
        defer granted.deinit(allocator);
        if (!self.authority.verify(granted, intent.operation, intent.target)) {
            return fail(.capability_denied, "effect capability does not grant intent");
        }

        const executor = self.registry.get(intent.operation) orelse
            return fail(.missing_executor, "effect executor is not registered");
        var observation = executor.perform(allocator, &intent) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ExecutorFailed => return fail(.executor_failed, "effect executor failed"),
        };
        errdefer observation.deinit(allocator);
        if (!observation.valid() or
            !std.mem.eql(u8, &observation.request_id, &intent.request_id))
        {
            return fail(.invalid_observation, "effect executor returned an invalid observation");
        }

        try self.persistReceipt(receipt_id, observation);
        return .{ .code = .performed, .observation = observation };
    }

    // Internal ---------------------------------------------------------------

    fn fail(code: BoundaryCode, message: []const u8) BoundaryResult {
        return .{ .code = code, .message = message };
    }

    fn loadObservation(self: *Boundary, id: TexelId) Error!Observation {
        const receipt = self.store.get(id) orelse return Error.InvalidArgument;
        if (receipt.inputCount() != 0 or receipt.outputCount() != 1) {
            return Error.InvalidArgument;
        }
        const output = receipt.getOutput("observation") orelse return Error.InvalidArgument;
        if (output.declared != .bytes) return Error.InvalidArgument;
        const source = output.source orelse return Error.InvalidArgument;
        return decodeObservation(self.store.allocator, source);
    }

    fn persistReceipt(self: *Boundary, id: TexelId, observation: Observation) error{OutOfMemory}!void {
        const allocator = self.store.allocator;
        var encoded = encodeObservation(allocator, observation) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidArgument => unreachable,
        };
        errdefer encoded.deinit(allocator);

        var receipt = Texel.init(id);
        defer receipt.deinit(allocator);
        var output = try OutputPort.init(allocator, "observation", .bytes);
        errdefer output.deinit(allocator);
        output.setSource(allocator, encoded) catch unreachable;
        receipt.putOutput(allocator, output) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };

        var transaction = self.store.begin() catch return error.OutOfMemory;
        defer transaction.deinit();
        transaction.put(&receipt) catch return error.OutOfMemory;
        transaction.commit() catch return error.OutOfMemory;
    }
};

fn availableBytes(outcome: *const spool_mod.Outcome) ?Value {
    if (outcome.* != .available) return null;
    if (outcome.available.tag() != .bytes) return null;
    return outcome.available;
}

// ---------------------------------------------------------------------------
// Byte reading
// ---------------------------------------------------------------------------

const ByteReader = struct {
    data: []const u8,
    offset: usize = 0,

    fn take(self: *ByteReader, size: usize) ?[]const u8 {
        if (size > self.data.len - self.offset) return null;
        const slice = self.data[self.offset..][0..size];
        self.offset += size;
        return slice;
    }

    fn u32Value(self: *ByteReader) ?u32 {
        const slice = self.take(4) orelse return null;
        return std.mem.readInt(u32, slice[0..4], .little);
    }

    fn name(self: *ByteReader) ?[]const u8 {
        const text = self.bytes() orelse return null;
        if (!validName(text)) return null;
        return text;
    }

    fn bytes(self: *ByteReader) ?[]const u8 {
        const length = self.u32Value() orelse return null;
        return self.take(length);
    }

    fn done(self: *const ByteReader) bool {
        return self.offset == self.data.len;
    }
};

fn appendU32(allocator: Allocator, list: *std.ArrayList(u8), value: u32) !void {
    var encoded: [4]u8 = undefined;
    std.mem.writeInt(u32, &encoded, value, .little);
    try list.appendSlice(allocator, &encoded);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const volume_mod = @import("../storage/volume.zig");

const EchoExecutor = struct {
    calls: usize = 0,

    fn executor(self: *EchoExecutor) Executor {
        return .{ .context = self, .performFn = run };
    }

    fn run(
        context: *anyopaque,
        allocator: Allocator,
        intent: *const Intent,
    ) error{ ExecutorFailed, OutOfMemory }!Observation {
        const self: *EchoExecutor = @ptrCast(@alignCast(context));
        self.calls += 1;
        return Observation.init(allocator, intent.request_id, true, intent.payload) catch
            error.ExecutorFailed;
    }
};

fn freshRequestId() RequestId {
    var id: RequestId = undefined;
    std.testing.io.random(&id);
    if (std.mem.allEqual(u8, &id, 0)) id[0] = 1;
    return id;
}

test "intent and observation encodings round-trip and reject corruption" {
    const allocator = testing.allocator;

    var intent = try Intent.init(allocator, freshRequestId(), "send", "mailbox", "hello");
    defer intent.deinit(allocator);
    var encoded = try encodeIntent(allocator, intent);
    defer encoded.deinit(allocator);
    var decoded = try decodeIntent(allocator, encoded);
    defer decoded.deinit(allocator);
    try testing.expect(std.mem.eql(u8, &intent.request_id, &decoded.request_id));
    try testing.expectEqualStrings("send", decoded.operation);
    try testing.expectEqualStrings("hello", decoded.payload);

    encoded.bytes[0] ^= 1;
    try testing.expectError(Error.InvalidArgument, decodeIntent(allocator, encoded));

    var observation = try Observation.init(allocator, intent.request_id, true, "done");
    defer observation.deinit(allocator);
    var receipt = try encodeObservation(allocator, observation);
    defer receipt.deinit(allocator);
    var restored = try decodeObservation(allocator, receipt);
    defer restored.deinit(allocator);
    try testing.expect(restored.success);
    try testing.expectEqualStrings("done", restored.bytes);
}

const Rig = struct {
    memory: volume_mod.MemoryVolume,
    store: Store,
    authority: Authority,
    registry: ExecutorRegistry,
    spool_registry: spool_mod.Registry,
    spool: Spool,
    effect_id: TexelId,
    request: RequestId,

    // In place: the store and spool hold pointers into this struct.
    fn setup(self: *Rig, allocator: Allocator, operation: []const u8, target: []const u8) !void {
        const io = std.testing.io;
        self.memory = try volume_mod.MemoryVolume.init(allocator, 32);
        errdefer self.memory.deinit();
        self.store = try Store.create(allocator, self.memory.volume());
        errdefer self.store.deinit();
        self.authority = Authority.init(allocator);
        errdefer self.authority.deinit();
        self.registry = ExecutorRegistry.init(allocator);
        errdefer self.registry.deinit();
        self.spool_registry = spool_mod.Registry.init(allocator);
        errdefer self.spool_registry.deinit();
        self.spool = Spool.init(allocator, &self.store, &self.spool_registry);
        errdefer self.spool.deinit();

        // One capability texel and one effect texel, wired together.
        var held = try self.authority.issue(io, operation, target);
        defer held.deinit(allocator);
        var capability_texel = try makeCapabilityTexel(allocator, TexelId.generate(io), held);
        defer capability_texel.deinit(allocator);

        self.request = freshRequestId();
        var intent = try Intent.init(allocator, self.request, "send", "mailbox", "payload");
        defer intent.deinit(allocator);
        self.effect_id = TexelId.generate(io);
        var effect_texel = try makeEffectTexel(allocator, self.effect_id, intent);
        defer effect_texel.deinit(allocator);

        var transaction = try self.store.begin();
        defer transaction.deinit();
        try transaction.put(&capability_texel);
        try transaction.put(&effect_texel);
        try transaction.connect(self.effect_id, "capability", capability_texel.id, "capability");
        try transaction.commit();
    }

    fn deinit(self: *Rig) void {
        self.spool.deinit();
        self.spool_registry.deinit();
        self.registry.deinit();
        self.authority.deinit();
        self.store.deinit();
        self.memory.deinit();
    }
};

test "an effect performs once and replays from its receipt" {
    const allocator = testing.allocator;
    var rig: Rig = undefined;
    try rig.setup(allocator, "send", "mailbox");
    defer rig.deinit();

    var echo: EchoExecutor = .{};
    try rig.registry.put("send", echo.executor());

    var boundary: Boundary = .{
        .store = &rig.store,
        .spool = &rig.spool,
        .authority = &rig.authority,
        .registry = &rig.registry,
    };

    var first = try boundary.perform(rig.effect_id);
    defer first.deinit(allocator);
    try testing.expectEqual(BoundaryCode.performed, first.code);
    try testing.expect(first.succeeded());
    try testing.expectEqualStrings("payload", first.observation.?.bytes);
    try testing.expectEqual(@as(usize, 1), echo.calls);

    // The receipt is durable Fabric state under the request identity.
    try testing.expect(rig.store.has(observationId(rig.request).?));

    // Performing again replays the stored receipt; the world moves once.
    var second = try boundary.perform(rig.effect_id);
    defer second.deinit(allocator);
    try testing.expectEqual(BoundaryCode.replayed, second.code);
    try testing.expectEqualStrings("payload", second.observation.?.bytes);
    try testing.expectEqual(@as(usize, 1), echo.calls);
}

test "the boundary refuses denied, unwired, and unregistered effects" {
    const allocator = testing.allocator;

    // A capability for the wrong operation is denied and performs nothing.
    var denied: Rig = undefined;
    try denied.setup(allocator, "read", "mailbox");
    defer denied.deinit();
    var echo: EchoExecutor = .{};
    try denied.registry.put("send", echo.executor());
    var boundary: Boundary = .{
        .store = &denied.store,
        .spool = &denied.spool,
        .authority = &denied.authority,
        .registry = &denied.registry,
    };
    var result = try boundary.perform(denied.effect_id);
    defer result.deinit(allocator);
    try testing.expectEqual(BoundaryCode.capability_denied, result.code);
    try testing.expectEqual(@as(usize, 0), echo.calls);
    try testing.expect(!denied.store.has(observationId(denied.request).?));

    // No registered executor for the operation.
    var missing: Rig = undefined;
    try missing.setup(allocator, "send", "mailbox");
    defer missing.deinit();
    var unregistered: Boundary = .{
        .store = &missing.store,
        .spool = &missing.spool,
        .authority = &missing.authority,
        .registry = &missing.registry,
    };
    var absent = try unregistered.perform(missing.effect_id);
    defer absent.deinit(allocator);
    try testing.expectEqual(BoundaryCode.missing_executor, absent.code);

    // A missing effect texel.
    var ghost = try unregistered.perform(TexelId.generate(std.testing.io));
    defer ghost.deinit(allocator);
    try testing.expectEqual(BoundaryCode.missing_effect, ghost.code);
}
