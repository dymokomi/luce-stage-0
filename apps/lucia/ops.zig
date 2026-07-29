//! The operations layer: lucia's Fabric semantics, in one place.
//!
//! The same operations are reachable three ways — a terminal command
//! parses words and calls here, a Luce program's fabric intents map
//! here, and plain Zig code (the boundary texels, the editor, tests)
//! calls here directly.  Whatever the direction, this file is where
//! the behavior lives and where it is tested; callers only translate
//! and report.
//!
//! Conventions enforced here: a texel's name is a text source on its
//! `name` Output Port (never identity), every mutation is one
//! transaction (or composes into a caller's open transaction), and
//! nothing publishes on failure.

const std = @import("std");
const loom = @import("loom");

const Allocator = std.mem.Allocator;
const Store = loom.store.Store;
const Transaction = loom.store.Transaction;
const Texel = loom.texel.Texel;
const InputPort = loom.texel.InputPort;
const OutputPort = loom.texel.OutputPort;
const TexelId = loom.texel_id.TexelId;
const Value = loom.value.Value;
const ValueType = loom.value.ValueType;

pub const name_port = "name";

pub const Error = error{
    OutOfMemory,
    StoreFailed,
    MissingTexel,
    MissingPort,
    PortExists,
    TypeMismatch,
};

// ---------------------------------------------------------------------------
// Specs
// ---------------------------------------------------------------------------

pub const PortSpec = struct {
    name: []const u8,
    declared: ValueType,
};

pub const SetSpec = struct {
    output: []const u8,
    /// Borrowed; buildTexel clones what it stores.
    value: Value,
};

/// A complete description of one texel to create: exactly what a Luce
/// fabric intent carries, and what the new command abbreviates.
pub const TexelSpec = struct {
    name: []const u8,
    inputs: []const PortSpec = &.{},
    outputs: []const PortSpec = &.{},
    content: ?[]const u8 = null,
    evaluator: ?[]const u8 = null,
    sets: []const SetSpec = &.{},
};

// ---------------------------------------------------------------------------
// Creation
// ---------------------------------------------------------------------------

/// Compose one new texel into an open transaction: identity, name,
/// typed ports, Luce content, evaluator, initial output sources.
pub fn buildTexel(gpa: Allocator, io: std.Io, transaction: *Transaction, spec: TexelSpec) Error!TexelId {
    var texel = Texel.init(TexelId.generate(io));
    defer texel.deinit(gpa);

    try setName(gpa, &texel, spec.name);
    for (spec.inputs) |port| {
        var made = try InputPort.init(gpa, port.name, port.declared);
        errdefer made.deinit(gpa);
        texel.putInput(gpa, made) catch return Error.StoreFailed;
    }
    for (spec.outputs) |port| {
        var made = try OutputPort.init(gpa, port.name, port.declared);
        errdefer made.deinit(gpa);
        texel.putOutput(gpa, made) catch return Error.StoreFailed;
    }
    if (spec.content) |source| {
        texel.setContent(gpa, try Value.initText(gpa, source)) catch return Error.StoreFailed;
    }
    if (spec.evaluator) |evaluator| {
        texel.setEvaluator(gpa, evaluator) catch return Error.StoreFailed;
    }
    for (spec.sets) |set| {
        const output = texel.mutableOutput(set.output) orelse continue;
        var cloned = try set.value.clone(gpa);
        output.setSource(gpa, cloned) catch cloned.deinit(gpa);
    }
    transaction.put(&texel) catch return Error.StoreFailed;
    return texel.id;
}

/// Create one texel in its own transaction.
pub fn createTexel(gpa: Allocator, io: std.Io, store: *Store, spec: TexelSpec) Error!TexelId {
    var transaction = store.begin() catch return Error.StoreFailed;
    defer transaction.deinit();
    const id = try buildTexel(gpa, io, &transaction, spec);
    transaction.commit() catch return Error.StoreFailed;
    return id;
}

/// Give a texel value its name: a text source on the name output.
pub fn setName(gpa: Allocator, texel: *Texel, name: []const u8) Error!void {
    var output = try OutputPort.init(gpa, name_port, .text);
    errdefer output.deinit(gpa);
    output.setSource(gpa, try Value.initText(gpa, name)) catch return Error.StoreFailed;
    texel.putOutput(gpa, output) catch return Error.StoreFailed;
}

// ---------------------------------------------------------------------------
// Edits on existing texels
// ---------------------------------------------------------------------------

const Edit = struct {
    transaction: Transaction,
    texel: Texel,

    fn commit(self: *Edit, gpa: Allocator) Error!void {
        defer self.texel.deinit(gpa);
        self.transaction.put(&self.texel) catch {
            self.transaction.deinit();
            return Error.StoreFailed;
        };
        defer self.transaction.deinit();
        self.transaction.commit() catch return Error.StoreFailed;
    }

    fn abort(self: *Edit, gpa: Allocator) void {
        self.texel.deinit(gpa);
        self.transaction.deinit();
    }
};

fn beginEdit(gpa: Allocator, store: *Store, id: TexelId) Error!Edit {
    var transaction = store.begin() catch return Error.StoreFailed;
    errdefer transaction.deinit();
    const current = transaction.get(id) orelse return Error.MissingTexel;
    const texel = try current.clone(gpa);
    return .{ .transaction = transaction, .texel = texel };
}

/// Rename: replace the name output's text source.
pub fn rename(gpa: Allocator, store: *Store, id: TexelId, name: []const u8) Error!void {
    var edit = try beginEdit(gpa, store, id);
    setName(gpa, &edit.texel, name) catch |mistake| {
        edit.abort(gpa);
        return mistake;
    };
    try edit.commit(gpa);
}

/// Add a typed Input Port.
pub fn addInput(gpa: Allocator, store: *Store, id: TexelId, name: []const u8, declared: ValueType) Error!void {
    var edit = try beginEdit(gpa, store, id);
    if (edit.texel.hasInput(name)) {
        edit.abort(gpa);
        return Error.PortExists;
    }
    const port = InputPort.init(gpa, name, declared) catch {
        edit.abort(gpa);
        return Error.OutOfMemory;
    };
    edit.texel.putInput(gpa, port) catch {
        edit.abort(gpa);
        return Error.StoreFailed;
    };
    try edit.commit(gpa);
}

/// Add a typed Output Port.
pub fn addOutput(gpa: Allocator, store: *Store, id: TexelId, name: []const u8, declared: ValueType) Error!void {
    var edit = try beginEdit(gpa, store, id);
    if (edit.texel.hasOutput(name)) {
        edit.abort(gpa);
        return Error.PortExists;
    }
    const port = OutputPort.init(gpa, name, declared) catch {
        edit.abort(gpa);
        return Error.OutOfMemory;
    };
    edit.texel.putOutput(gpa, port) catch {
        edit.abort(gpa);
        return Error.StoreFailed;
    };
    try edit.commit(gpa);
}

/// Set a source value on an Output Port.  Takes ownership of the
/// value; the port's declared type must match.
pub fn setSource(gpa: Allocator, store: *Store, id: TexelId, output_name: []const u8, value: Value) Error!void {
    var owned = value;
    var edit = beginEdit(gpa, store, id) catch |mistake| {
        owned.deinit(gpa);
        return mistake;
    };
    const output = edit.texel.mutableOutput(output_name) orelse {
        owned.deinit(gpa);
        edit.abort(gpa);
        return Error.MissingPort;
    };
    output.setSource(gpa, owned) catch {
        owned.deinit(gpa);
        edit.abort(gpa);
        return Error.TypeMismatch;
    };
    try edit.commit(gpa);
}

/// Set (or clear, with empty text) a texel's Luce content.
pub fn setContent(gpa: Allocator, store: *Store, id: TexelId, source: []const u8) Error!void {
    var edit = try beginEdit(gpa, store, id);
    if (std.mem.trim(u8, source, " \n").len == 0) {
        edit.texel.clearContent(gpa);
    } else {
        const value = Value.initText(gpa, source) catch {
            edit.abort(gpa);
            return Error.OutOfMemory;
        };
        edit.texel.setContent(gpa, value) catch {
            edit.abort(gpa);
            return Error.StoreFailed;
        };
    }
    try edit.commit(gpa);
}

/// Assign a persisted evaluator name.
pub fn setEvaluator(gpa: Allocator, store: *Store, id: TexelId, name: []const u8) Error!void {
    var edit = try beginEdit(gpa, store, id);
    edit.texel.setEvaluator(gpa, name) catch {
        edit.abort(gpa);
        return Error.StoreFailed;
    };
    try edit.commit(gpa);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const volume_mod = loom.volume;

const Rig = struct {
    memory: volume_mod.MemoryVolume,
    store: Store,

    fn setup(self: *Rig, gpa: Allocator) !void {
        self.memory = try volume_mod.MemoryVolume.init(gpa, 32);
        errdefer self.memory.deinit();
        self.store = try Store.create(gpa, self.memory.volume());
    }

    fn deinit(self: *Rig) void {
        self.store.deinit();
        self.memory.deinit();
    }
};

test "createTexel builds the whole spec in one commit" {
    const gpa = testing.allocator;
    var rig: Rig = undefined;
    try rig.setup(gpa);
    defer rig.deinit();

    var initial = try Value.initText(gpa, "ready");
    defer initial.deinit(gpa);
    const id = try createTexel(gpa, testing.io, &rig.store, .{
        .name = "worker",
        .inputs = &.{.{ .name = "left", .declared = .int }},
        .outputs = &.{
            .{ .name = "value", .declared = .int },
            .{ .name = "state", .declared = .text },
        },
        .content = "fn evaluate():\n    output.value = input.left\n",
        .evaluator = "luce",
        .sets = &.{.{ .output = "state", .value = initial }},
    });

    const texel = rig.store.get(id).?;
    try testing.expect(texel.hasInput("left"));
    try testing.expect(texel.hasOutput("value"));
    try testing.expectEqualStrings("worker", texel.getOutput(name_port).?.source.?.text);
    try testing.expectEqualStrings("ready", texel.getOutput("state").?.source.?.text);
    try testing.expectEqualStrings("luce", texel.evaluatorName());
    try testing.expect(texel.content != null);
}

test "edits are typed, guarded, and atomic" {
    const gpa = testing.allocator;
    var rig: Rig = undefined;
    try rig.setup(gpa);
    defer rig.deinit();

    const id = try createTexel(gpa, testing.io, &rig.store, .{ .name = "plain" });
    try addInput(gpa, &rig.store, id, "value", .int);
    try testing.expectError(Error.PortExists, addInput(gpa, &rig.store, id, "value", .int));
    try addOutput(gpa, &rig.store, id, "value", .int);
    try testing.expectError(Error.PortExists, addOutput(gpa, &rig.store, id, "value", .int));

    try setSource(gpa, &rig.store, id, "value", .{ .int = 9 });
    try testing.expectEqual(@as(i64, 9), rig.store.get(id).?.getOutput("value").?.source.?.int);
    try testing.expectError(
        Error.TypeMismatch,
        setSource(gpa, &rig.store, id, "value", try Value.initText(gpa, "no")),
    );
    try testing.expectError(
        Error.MissingPort,
        setSource(gpa, &rig.store, id, "ghost", .{ .int = 1 }),
    );

    try rename(gpa, &rig.store, id, "renamed");
    try testing.expectEqualStrings("renamed", rig.store.get(id).?.getOutput(name_port).?.source.?.text);

    try setContent(gpa, &rig.store, id, "fn evaluate():\n    output.value = 1\n");
    try testing.expect(rig.store.get(id).?.content != null);
    try setContent(gpa, &rig.store, id, "  \n");
    try testing.expect(rig.store.get(id).?.content == null);

    try setEvaluator(gpa, &rig.store, id, "luce");
    try testing.expectEqualStrings("luce", rig.store.get(id).?.evaluatorName());

    try testing.expectError(
        Error.MissingTexel,
        addInput(gpa, &rig.store, TexelId.generate(testing.io), "x", .int),
    );
}
