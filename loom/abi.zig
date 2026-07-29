//! The C ABI of the Loom engine — the implementation of abi/loom.h.
//!
//! Everything here converts at the border and delegates inward: handles
//! wrap engine objects, values and outcomes copy across, and evaluators
//! written in C are bridged into the Spool through an emit sink.  The
//! border owns one process-wide allocator and one Io; single-threaded in
//! this version.

const std = @import("std");
const loom = @import("loom.zig");

const Allocator = std.mem.Allocator;
const TexelId = loom.texel_id.TexelId;
const Value = loom.value.Value;
const ValueType = loom.value.ValueType;
const Texel = loom.texel.Texel;
const InputPort = loom.texel.InputPort;
const OutputPort = loom.texel.OutputPort;
const Store = loom.store.Store;
const Transaction = loom.store.Transaction;
const Spool = loom.spool.Spool;
const Outcome = loom.spool.Outcome;
const OutcomeMap = loom.spool.OutcomeMap;
const Registry = loom.spool.Registry;
const FiberIndex = loom.fiber_index.FiberIndex;

const gpa = std.heap.c_allocator;

// One process-wide Io for file access and entropy; the C side does not
// pass Io explicitly in this version of the border.
var io_state: std.Io.Threaded = undefined;
var io_ready = false;

fn borderIo() std.Io {
    if (!io_ready) {
        io_state = .init(gpa, .{});
        io_ready = true;
    }
    return io_state.io();
}

// ---------------------------------------------------------------------------
// C-visible types (kept in exact sync with abi/loom.h)
// ---------------------------------------------------------------------------

const Status = enum(c_int) {
    ok = 0,
    argument,
    not_found,
    type_mismatch,
    stale,
    image,
    publish,
    ring_gap,
    memory,
};

const Buffer = extern struct {
    data: ?[*]u8 = null,
    size: usize = 0,
};

const CValue = extern struct {
    tag: u8 = 0,
    boolean: bool = false,
    integer: i64 = 0,
    real: f64 = 0,
    data: Buffer = .{},
    texel: [TexelId.size]u8 = @splat(0),
    blob_id: [32]u8 = @splat(0),
    blob_size: u64 = 0,
};

const COutcome = extern struct {
    status: u8 = 1, // unavailable
    value: CValue = .{},
    error_message: Buffer = .{},
};

const CInputInfo = extern struct {
    name: Buffer = .{},
    type: u8 = 0,
    bound: bool = false,
    source: [TexelId.size]u8 = @splat(0),
    source_output: Buffer = .{},
};

const COutputInfo = extern struct {
    name: Buffer = .{},
    type: u8 = 0,
    has_source: bool = false,
    source: CValue = .{},
    revision: u64 = 0,
};

const IdList = extern struct {
    ids: ?[*]u8 = null,
    count: usize = 0,
};

const CEvalInput = extern struct {
    name: [*:0]const u8,
    outcome: *const COutcome,
};

const EmitFn = *const fn (sink: ?*anyopaque, output: [*:0]const u8, outcome: *const COutcome) callconv(.c) void;
const EvaluatorFn = *const fn (
    context: ?*anyopaque,
    inputs: [*]const CEvalInput,
    input_count: usize,
    emit: EmitFn,
    sink: ?*anyopaque,
) callconv(.c) void;

// ---------------------------------------------------------------------------
// Handles
// ---------------------------------------------------------------------------

const StoreHandle = struct {
    file: loom.volume.FileVolume,
    store: Store,
};

const TxnHandle = struct {
    handle: *StoreHandle,
    transaction: Transaction,
    done: bool = false,
};

const Bridge = struct {
    evaluate: EvaluatorFn,
    context: ?*anyopaque,
};

const RegistryHandle = struct {
    registry: Registry,
    bridges: std.ArrayList(*Bridge) = .empty,
};

const SpoolHandle = struct {
    spool: Spool,
};

const IndexHandle = struct {
    index: FiberIndex,
};

// ---------------------------------------------------------------------------
// Conversions
// ---------------------------------------------------------------------------

fn ownedBuffer(bytes: []const u8) !Buffer {
    if (bytes.len == 0) return .{};
    const copy = try gpa.dupe(u8, bytes);
    return .{ .data = copy.ptr, .size = copy.len };
}

fn freeBuffer(buffer: Buffer) void {
    const data = buffer.data orelse return;
    gpa.free(data[0..buffer.size]);
}

fn idFrom(raw: [*c]const u8) TexelId {
    var id: TexelId = .{};
    @memcpy(&id.bytes, raw[0..TexelId.size]);
    return id;
}

fn nameFrom(raw: [*c]const u8) ?[]const u8 {
    if (raw == null) return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
}

/// Borrowed C value to an owned engine Value.
fn valueIn(raw: *const CValue) !Value {
    return switch (@as(ValueType, @enumFromInt(raw.tag))) {
        .none => error.InvalidValue,
        .boolean => .{ .boolean = raw.boolean },
        .int => .{ .int = raw.integer },
        .real => .{ .real = raw.real },
        .text => Value.initText(gpa, borrowedData(raw.data)),
        .bytes => Value.initBytes(gpa, borrowedData(raw.data)),
        .texel => .{ .texel = .{ .bytes = raw.texel } },
        .blob => .{ .blob = .{ .id = raw.blob_id, .size = raw.blob_size } },
    };
}

fn borrowedData(buffer: Buffer) []const u8 {
    const data = buffer.data orelse return &.{};
    return data[0..buffer.size];
}

/// Engine value to a caller-owned C value.
fn valueOut(source: Value) !CValue {
    var out: CValue = .{ .tag = @intFromEnum(source.tag()) };
    switch (source) {
        .none => {},
        .boolean => |flag| out.boolean = flag,
        .int => |number| out.integer = number,
        .real => |number| out.real = number,
        .text => |content| out.data = try ownedBuffer(content),
        .bytes => |content| out.data = try ownedBuffer(content),
        .texel => |id| out.texel = id.bytes,
        .blob => |reference| {
            out.blob_id = reference.id;
            out.blob_size = reference.size;
        },
    }
    return out;
}

fn outcomeOut(source: *const Outcome) !COutcome {
    return switch (source.*) {
        .available => |held| .{ .status = 0, .value = try valueOut(held) },
        .unavailable => .{ .status = 1 },
        .err => |message| .{ .status = 2, .error_message = try ownedBuffer(message) },
    };
}

fn idListOut(ids: []const TexelId) !IdList {
    if (ids.len == 0) return .{};
    const flat = try gpa.alloc(u8, ids.len * TexelId.size);
    for (ids, 0..) |id, index| {
        @memcpy(flat[index * TexelId.size ..][0..TexelId.size], &id.bytes);
    }
    return .{ .ids = flat.ptr, .count = ids.len };
}

fn idListIn(list: *const IdList, scratch: *std.ArrayList(TexelId)) ![]const TexelId {
    const data = list.ids orelse return &.{};
    try scratch.ensureTotalCapacity(gpa, list.count);
    var index: usize = 0;
    while (index < list.count) : (index += 1) {
        scratch.appendAssumeCapacity(idFrom(data + index * TexelId.size));
    }
    return scratch.items;
}

fn storeStatus(err: loom.store.Error) Status {
    return switch (err) {
        error.StoreClosed, error.InvalidArgument => .argument,
        error.NotFound => .not_found,
        error.StaleTransaction => .stale,
        error.PublishFailed => .publish,
        error.BadImage => .image,
        error.OutOfMemory => .memory,
    };
}

// ---------------------------------------------------------------------------
// Buffers, values, outcomes
// ---------------------------------------------------------------------------

export fn loom_buffer_free(buffer: Buffer) void {
    freeBuffer(buffer);
}

export fn loom_value_free(value: ?*CValue) void {
    const held = value orelse return;
    freeBuffer(held.data);
    held.* = .{};
}

export fn loom_outcome_free(outcome: ?*COutcome) void {
    const held = outcome orelse return;
    freeBuffer(held.value.data);
    freeBuffer(held.error_message);
    held.* = .{};
}

export fn loom_input_info_free(info: ?*CInputInfo) void {
    const held = info orelse return;
    freeBuffer(held.name);
    freeBuffer(held.source_output);
    held.* = .{};
}

export fn loom_output_info_free(info: ?*COutputInfo) void {
    const held = info orelse return;
    freeBuffer(held.name);
    freeBuffer(held.source.data);
    held.* = .{};
}

export fn loom_id_list_free(list: IdList) void {
    const data = list.ids orelse return;
    gpa.free(data[0 .. list.count * TexelId.size]);
}

// ---------------------------------------------------------------------------
// Identity
// ---------------------------------------------------------------------------

export fn loom_id_generate(id: [*c]u8) void {
    const generated = TexelId.generate(borderIo());
    @memcpy(id[0..TexelId.size], &generated.bytes);
}

export fn loom_id_parse(text: [*c]const u8, id: [*c]u8) Status {
    const name = nameFrom(text) orelse return .argument;
    const parsed = TexelId.parse(name) orelse return .argument;
    if (parsed.isUnset()) return .argument;
    @memcpy(id[0..TexelId.size], &parsed.bytes);
    return .ok;
}

export fn loom_id_format(id: [*c]const u8, text: [*c]u8) void {
    var buffer: [TexelId.text_size]u8 = undefined;
    _ = idFrom(id).format(&buffer);
    @memcpy(text[0..TexelId.text_size], &buffer);
    text[TexelId.text_size] = 0;
}

// ---------------------------------------------------------------------------
// Store lifecycle
// ---------------------------------------------------------------------------

fn openVolume(path: []const u8, pages: u64, create: bool) !*StoreHandle {
    const handle = try gpa.create(StoreHandle);
    errdefer gpa.destroy(handle);

    const io = borderIo();
    const directory = std.Io.Dir.cwd();
    handle.file = if (create)
        try loom.volume.FileVolume.create(io, directory, path, pages)
    else
        try loom.volume.FileVolume.open(io, directory, path);
    errdefer handle.file.close();

    handle.store = if (create)
        try Store.create(gpa, handle.file.volume())
    else
        try Store.open(gpa, handle.file.volume());
    return handle;
}

export fn loom_store_create(path: [*c]const u8, pages: u64, store: ?**StoreHandle) Status {
    const out = store orelse return .argument;
    const name = nameFrom(path) orelse return .argument;
    out.* = openVolume(name, pages, true) catch |err| return switch (err) {
        error.OutOfMemory => .memory,
        error.BadImage => .image,
        else => .publish,
    };
    return .ok;
}

export fn loom_store_open(path: [*c]const u8, store: ?**StoreHandle) Status {
    const out = store orelse return .argument;
    const name = nameFrom(path) orelse return .argument;
    out.* = openVolume(name, 0, false) catch |err| return switch (err) {
        error.OutOfMemory => .memory,
        else => .image,
    };
    return .ok;
}

export fn loom_store_close(store: ?*StoreHandle) void {
    const handle = store orelse return;
    handle.store.deinit();
    handle.file.close();
    gpa.destroy(handle);
}

// ---------------------------------------------------------------------------
// Store inspection
// ---------------------------------------------------------------------------

export fn loom_store_generation(store: *const StoreHandle) u64 {
    return store.store.generation;
}

export fn loom_store_count(store: *const StoreHandle) usize {
    return store.store.count();
}

export fn loom_store_id_at(store: *const StoreHandle, index: usize, id: [*c]u8) Status {
    const texel = store.store.at(index) orelse return .not_found;
    @memcpy(id[0..TexelId.size], &texel.id.bytes);
    return .ok;
}

export fn loom_store_has(store: *const StoreHandle, id: [*c]const u8) bool {
    return store.store.has(idFrom(id));
}

export fn loom_texel_revision(store: *const StoreHandle, id: [*c]const u8, revision: ?*u64) Status {
    const out = revision orelse return .argument;
    const texel = store.store.get(idFrom(id)) orelse return .not_found;
    out.* = texel.revision;
    return .ok;
}

export fn loom_texel_evaluator(store: *const StoreHandle, id: [*c]const u8, name: ?*Buffer) Status {
    const out = name orelse return .argument;
    const texel = store.store.get(idFrom(id)) orelse return .not_found;
    out.* = ownedBuffer(texel.evaluatorName()) catch return .memory;
    return .ok;
}

export fn loom_texel_input_count(store: *const StoreHandle, id: [*c]const u8, count: ?*usize) Status {
    const out = count orelse return .argument;
    const texel = store.store.get(idFrom(id)) orelse return .not_found;
    out.* = texel.inputCount();
    return .ok;
}

export fn loom_texel_input_at(store: *const StoreHandle, id: [*c]const u8, index: usize, info: ?*CInputInfo) Status {
    const out = info orelse return .argument;
    const texel = store.store.get(idFrom(id)) orelse return .not_found;
    const port = texel.inputAt(index) orelse return .not_found;

    var built: CInputInfo = .{
        .name = ownedBuffer(port.name) catch return .memory,
        .type = @intFromEnum(port.declared),
    };
    if (port.binding) |fiber| {
        built.bound = true;
        built.source = fiber.source.bytes;
        built.source_output = ownedBuffer(fiber.output) catch {
            freeBuffer(built.name);
            return .memory;
        };
    }
    out.* = built;
    return .ok;
}

export fn loom_texel_output_count(store: *const StoreHandle, id: [*c]const u8, count: ?*usize) Status {
    const out = count orelse return .argument;
    const texel = store.store.get(idFrom(id)) orelse return .not_found;
    out.* = texel.outputCount();
    return .ok;
}

export fn loom_texel_output_at(store: *const StoreHandle, id: [*c]const u8, index: usize, info: ?*COutputInfo) Status {
    const out = info orelse return .argument;
    const texel = store.store.get(idFrom(id)) orelse return .not_found;
    const port = texel.outputAt(index) orelse return .not_found;

    var built: COutputInfo = .{
        .name = ownedBuffer(port.name) catch return .memory,
        .type = @intFromEnum(port.declared),
        .revision = port.revision,
    };
    if (port.source) |source| {
        built.has_source = true;
        built.source = valueOut(source) catch {
            freeBuffer(built.name);
            return .memory;
        };
    }
    out.* = built;
    return .ok;
}

// ---------------------------------------------------------------------------
// Transactions
// ---------------------------------------------------------------------------

export fn loom_txn_begin(store: ?*StoreHandle, txn: ?**TxnHandle) Status {
    const handle = store orelse return .argument;
    const out = txn orelse return .argument;
    const created = gpa.create(TxnHandle) catch return .memory;
    created.* = .{
        .handle = handle,
        .transaction = handle.store.begin() catch |err| {
            gpa.destroy(created);
            return switch (err) {
                error.OutOfMemory => Status.memory,
                else => Status.argument,
            };
        },
    };
    out.* = created;
    return .ok;
}

export fn loom_txn_commit(txn: ?*TxnHandle) Status {
    const handle = txn orelse return .argument;
    if (handle.done) return .argument;
    handle.transaction.commit() catch |err| return storeStatus(err);
    handle.done = true;
    return .ok;
}

export fn loom_txn_release(txn: ?*TxnHandle) void {
    const handle = txn orelse return;
    handle.transaction.deinit();
    gpa.destroy(handle);
}

export fn loom_txn_create_texel(txn: ?*TxnHandle, id: [*c]u8) Status {
    const handle = txn orelse return .argument;
    const created = TexelId.generate(borderIo());
    var texel = Texel.init(created);
    defer texel.deinit(gpa);
    handle.transaction.put(&texel) catch |err| return storeStatus(err);
    @memcpy(id[0..TexelId.size], &created.bytes);
    return .ok;
}

export fn loom_txn_remove_texel(txn: ?*TxnHandle, id: [*c]const u8) Status {
    const handle = txn orelse return .argument;
    handle.transaction.remove(idFrom(id)) catch |err| return storeStatus(err);
    return .ok;
}

// Clone-modify-place: every port operation works on a private copy of
// the texel inside the transaction snapshot.
fn changeTexel(
    handle: *TxnHandle,
    id: TexelId,
    context: anytype,
    change: fn (@TypeOf(context), *Texel) Status,
) Status {
    const current = handle.transaction.get(id) orelse return .not_found;
    var changed = current.clone(gpa) catch return .memory;
    defer changed.deinit(gpa);
    const outcome = change(context, &changed);
    if (outcome != .ok) return outcome;
    handle.transaction.put(&changed) catch |err| return storeStatus(err);
    return .ok;
}

export fn loom_txn_put_input(txn: ?*TxnHandle, id: [*c]const u8, name: [*c]const u8, value_type: u8) Status {
    const handle = txn orelse return .argument;
    const port_name = nameFrom(name) orelse return .argument;
    if (value_type == 0 or value_type > @intFromEnum(ValueType.blob)) return .type_mismatch;
    const Context = struct { name: []const u8, declared: ValueType };
    return changeTexel(handle, idFrom(id), Context{
        .name = port_name,
        .declared = @enumFromInt(value_type),
    }, struct {
        fn change(context: Context, texel: *Texel) Status {
            const port = InputPort.init(gpa, context.name, context.declared) catch
                return .memory;
            texel.putInput(gpa, port) catch return .memory;
            return .ok;
        }
    }.change);
}

export fn loom_txn_put_output(txn: ?*TxnHandle, id: [*c]const u8, name: [*c]const u8, value_type: u8) Status {
    const handle = txn orelse return .argument;
    const port_name = nameFrom(name) orelse return .argument;
    if (value_type == 0 or value_type > @intFromEnum(ValueType.blob)) return .type_mismatch;
    const Context = struct { name: []const u8, declared: ValueType };
    return changeTexel(handle, idFrom(id), Context{
        .name = port_name,
        .declared = @enumFromInt(value_type),
    }, struct {
        fn change(context: Context, texel: *Texel) Status {
            const port = OutputPort.init(gpa, context.name, context.declared) catch
                return .memory;
            texel.putOutput(gpa, port) catch return .memory;
            return .ok;
        }
    }.change);
}

export fn loom_txn_remove_input(txn: ?*TxnHandle, id: [*c]const u8, name: [*c]const u8) Status {
    const handle = txn orelse return .argument;
    const port_name = nameFrom(name) orelse return .argument;
    return changeTexel(handle, idFrom(id), port_name, struct {
        fn change(context: []const u8, texel: *Texel) Status {
            return if (texel.removeInput(gpa, context)) .ok else .not_found;
        }
    }.change);
}

export fn loom_txn_remove_output(txn: ?*TxnHandle, id: [*c]const u8, name: [*c]const u8) Status {
    const handle = txn orelse return .argument;
    const port_name = nameFrom(name) orelse return .argument;
    return changeTexel(handle, idFrom(id), port_name, struct {
        fn change(context: []const u8, texel: *Texel) Status {
            return if (texel.removeOutput(gpa, context)) .ok else .not_found;
        }
    }.change);
}

export fn loom_txn_set_evaluator(txn: ?*TxnHandle, id: [*c]const u8, name: [*c]const u8) Status {
    const handle = txn orelse return .argument;
    const evaluator = nameFrom(name) orelse return .argument;
    return changeTexel(handle, idFrom(id), evaluator, struct {
        fn change(context: []const u8, texel: *Texel) Status {
            texel.setEvaluator(gpa, context) catch |err| return switch (err) {
                error.OutOfMemory => Status.memory,
                error.EmptyName => Status.argument,
            };
            return .ok;
        }
    }.change);
}

export fn loom_txn_set_source(txn: ?*TxnHandle, id: [*c]const u8, output: [*c]const u8, value: ?*const CValue) Status {
    const handle = txn orelse return .argument;
    const port_name = nameFrom(output) orelse return .argument;
    const raw = value orelse return .argument;
    const Context = struct { name: []const u8, raw: *const CValue };
    return changeTexel(handle, idFrom(id), Context{ .name = port_name, .raw = raw }, struct {
        fn change(context: Context, texel: *Texel) Status {
            const port = texel.mutableOutput(context.name) orelse return .not_found;
            var incoming = valueIn(context.raw) catch |err| return switch (err) {
                error.OutOfMemory => Status.memory,
                error.InvalidValue => Status.type_mismatch,
            };
            port.setSource(gpa, incoming) catch {
                incoming.deinit(gpa);
                return .type_mismatch;
            };
            return .ok;
        }
    }.change);
}

export fn loom_txn_connect(txn: ?*TxnHandle, target: [*c]const u8, input: [*c]const u8, source: [*c]const u8, output: [*c]const u8) Status {
    const handle = txn orelse return .argument;
    const input_name = nameFrom(input) orelse return .argument;
    const output_name = nameFrom(output) orelse return .argument;
    handle.transaction.connect(idFrom(target), input_name, idFrom(source), output_name) catch |err|
        return storeStatus(err);
    return .ok;
}

export fn loom_txn_disconnect(txn: ?*TxnHandle, target: [*c]const u8, input: [*c]const u8) Status {
    const handle = txn orelse return .argument;
    const input_name = nameFrom(input) orelse return .argument;
    handle.transaction.disconnect(idFrom(target), input_name) catch |err|
        return storeStatus(err);
    return .ok;
}

// ---------------------------------------------------------------------------
// Observation and the change feed
// ---------------------------------------------------------------------------

export fn loom_store_observe(store: ?*StoreHandle, id: [*c]const u8, output: [*c]const u8, value: ?*const CValue) Status {
    const handle = store orelse return .argument;
    const port_name = nameFrom(output) orelse return .argument;
    const raw = value orelse return .argument;
    var incoming = valueIn(raw) catch |err| return switch (err) {
        error.OutOfMemory => Status.memory,
        error.InvalidValue => Status.type_mismatch,
    };
    handle.store.observe(idFrom(id), port_name, incoming) catch |err| {
        incoming.deinit(gpa);
        return switch (err) {
            error.NotFound => Status.not_found,
            error.InvalidArgument => Status.type_mismatch,
            error.OutOfMemory => Status.memory,
            else => Status.argument,
        };
    };
    return .ok;
}

export fn loom_store_changes_since(store: *const StoreHandle, baseline: u64, changed: ?*IdList) Status {
    const out = changed orelse return .argument;
    const delta = store.store.changesSince(gpa, baseline) catch return .memory;
    const held = delta orelse return .ring_gap;
    defer gpa.free(held);
    out.* = idListOut(held) catch return .memory;
    return .ok;
}

// ---------------------------------------------------------------------------
// Fiber index
// ---------------------------------------------------------------------------

export fn loom_index_new(index: ?**IndexHandle) Status {
    const out = index orelse return .argument;
    const created = gpa.create(IndexHandle) catch return .memory;
    created.* = .{ .index = FiberIndex.init(gpa) };
    out.* = created;
    return .ok;
}

export fn loom_index_free(index: ?*IndexHandle) void {
    const handle = index orelse return;
    handle.index.deinit();
    gpa.destroy(handle);
}

export fn loom_index_build(index: ?*IndexHandle, store: *const StoreHandle) Status {
    const handle = index orelse return .argument;
    handle.index.build(&store.store) catch return .memory;
    return .ok;
}

export fn loom_index_apply(index: ?*IndexHandle, store: *const StoreHandle, changed: ?*const IdList) Status {
    const handle = index orelse return .argument;
    const list = changed orelse return .argument;
    var scratch: std.ArrayList(TexelId) = .empty;
    defer scratch.deinit(gpa);
    const ids = idListIn(list, &scratch) catch return .memory;
    handle.index.apply(&store.store, ids) catch return .memory;
    return .ok;
}

export fn loom_index_downstream(index: ?*const IndexHandle, changed: ?*const IdList, dirty: ?*IdList) Status {
    const handle = index orelse return .argument;
    const list = changed orelse return .argument;
    const out = dirty orelse return .argument;
    var scratch: std.ArrayList(TexelId) = .empty;
    defer scratch.deinit(gpa);
    const ids = idListIn(list, &scratch) catch return .memory;
    const closure = handle.index.downstream(gpa, ids) catch return .memory;
    defer gpa.free(closure);
    out.* = idListOut(closure) catch return .memory;
    return .ok;
}

// ---------------------------------------------------------------------------
// Evaluation
// ---------------------------------------------------------------------------

const EmitSink = struct {
    texel: *const Texel,
    outputs: *OutcomeMap,
    failed: bool = false,
};

fn bridgeEmit(sink: ?*anyopaque, output: [*:0]const u8, outcome: *const COutcome) callconv(.c) void {
    const state: *EmitSink = @ptrCast(@alignCast(sink.?));
    if (state.failed) return;
    const emitted = std.mem.span(output);

    // Intern the name against a declared output port so the key outlives
    // this callback; unknown names poison the evaluation, which the
    // Spool then caches as an evaluator error.
    const declared = state.texel.getOutput(emitted) orelse {
        state.failed = true;
        return;
    };
    var built: Outcome = switch (outcome.status) {
        0 => blk: {
            const incoming = valueIn(&outcome.value) catch {
                state.failed = true;
                return;
            };
            break :blk .{ .available = incoming };
        },
        1 => .unavailable,
        else => Outcome.initError(gpa, borrowedData(outcome.error_message)) catch {
            state.failed = true;
            return;
        },
    };
    state.outputs.put(gpa, declared.name, built) catch {
        built.deinit(gpa);
        state.failed = true;
    };
}

fn bridgeEvaluate(
    context: *anyopaque,
    allocator: Allocator,
    texel: *const Texel,
    inputs: *const OutcomeMap,
    outputs: *OutcomeMap,
) loom.spool.Error!void {
    _ = allocator;
    const bridge: *Bridge = @ptrCast(@alignCast(context));

    // Marshal borrowed inputs: NUL-terminated names plus C outcomes.
    var names: std.ArrayList([:0]u8) = .empty;
    defer {
        for (names.items) |name| gpa.free(name);
        names.deinit(gpa);
    }
    var outcomes: std.ArrayList(COutcome) = .empty;
    defer {
        for (outcomes.items) |*held| {
            freeBuffer(held.value.data);
            freeBuffer(held.error_message);
        }
        outcomes.deinit(gpa);
    }
    var marshaled: std.ArrayList(CEvalInput) = .empty;
    defer marshaled.deinit(gpa);

    for (texel.inputs.items) |port| {
        const held = inputs.get(port.name) orelse continue;
        try names.append(gpa, try gpa.dupeZ(u8, port.name));
        try outcomes.append(gpa, try outcomeOut(&held));
    }
    try marshaled.ensureTotalCapacity(gpa, outcomes.items.len);
    for (names.items, outcomes.items) |name, *held| {
        marshaled.appendAssumeCapacity(.{ .name = name, .outcome = held });
    }

    var sink: EmitSink = .{ .texel = texel, .outputs = outputs };
    bridge.evaluate(bridge.context, marshaled.items.ptr, marshaled.items.len, bridgeEmit, &sink);
    if (sink.failed) {
        // Drop everything emitted; the Spool records the omission as an
        // evaluator error for every declared output.
        var entries = outputs.valueIterator();
        while (entries.next()) |entry| entry.deinit(gpa);
        outputs.clearRetainingCapacity();
        return;
    }

    // Border convention: declared outputs the evaluator did not emit fall
    // back to their stored source values (a name port beside computed
    // outputs, for example).  Outputs with neither stay missing and the
    // Spool reports the omission.
    for (texel.outputs.items) |port| {
        if (outputs.contains(port.name)) continue;
        const source = port.source orelse continue;
        try outputs.put(gpa, port.name, .{ .available = try source.clone(gpa) });
    }
}

export fn loom_registry_new(registry: ?**RegistryHandle) Status {
    const out = registry orelse return .argument;
    const created = gpa.create(RegistryHandle) catch return .memory;
    created.* = .{ .registry = Registry.init(gpa) };
    out.* = created;
    return .ok;
}

export fn loom_registry_free(registry: ?*RegistryHandle) void {
    const handle = registry orelse return;
    for (handle.bridges.items) |bridge| gpa.destroy(bridge);
    handle.bridges.deinit(gpa);
    handle.registry.deinit();
    gpa.destroy(handle);
}

export fn loom_registry_put(registry: ?*RegistryHandle, name: [*c]const u8, evaluator: ?EvaluatorFn, context: ?*anyopaque) Status {
    const handle = registry orelse return .argument;
    const evaluator_name = nameFrom(name) orelse return .argument;
    const function = evaluator orelse return .argument;

    const bridge = gpa.create(Bridge) catch return .memory;
    bridge.* = .{ .evaluate = function, .context = context };
    handle.bridges.append(gpa, bridge) catch {
        gpa.destroy(bridge);
        return .memory;
    };
    handle.registry.put(evaluator_name, .{
        .context = bridge,
        .evaluateFn = bridgeEvaluate,
    }) catch return .memory;
    return .ok;
}

export fn loom_spool_new(store: ?*StoreHandle, registry: ?*const RegistryHandle, spool: ?**SpoolHandle) Status {
    const store_handle = store orelse return .argument;
    const registry_handle = registry orelse return .argument;
    const out = spool orelse return .argument;
    const created = gpa.create(SpoolHandle) catch return .memory;
    created.* = .{
        .spool = Spool.init(gpa, &store_handle.store, &registry_handle.registry),
    };
    out.* = created;
    return .ok;
}

export fn loom_spool_free(spool: ?*SpoolHandle) void {
    const handle = spool orelse return;
    handle.spool.deinit();
    gpa.destroy(handle);
}

export fn loom_spool_demand(spool: ?*SpoolHandle, id: [*c]const u8, output: [*c]const u8, outcome: ?*COutcome) Status {
    const handle = spool orelse return .argument;
    const port_name = nameFrom(output) orelse return .argument;
    const out = outcome orelse return .argument;
    const result = handle.spool.demand(idFrom(id), port_name) catch return .memory;
    out.* = outcomeOut(result) catch return .memory;
    return .ok;
}

export fn loom_spool_advance(spool: ?*SpoolHandle, from_generation: u64, to_generation: u64, dirty: ?*const IdList) void {
    const handle = spool orelse return;
    const list = dirty orelse return;
    var scratch: std.ArrayList(TexelId) = .empty;
    defer scratch.deinit(gpa);
    const ids = idListIn(list, &scratch) catch return;
    handle.spool.advance(from_generation, to_generation, ids);
}

export fn loom_spool_clear(spool: ?*SpoolHandle) void {
    const handle = spool orelse return;
    handle.spool.clear();
}
