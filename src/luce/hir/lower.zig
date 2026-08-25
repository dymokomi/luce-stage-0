//! The lower half of the check/lower seam: lower a recorded `Body`
//! into stage 6's tape.
//!
//! Consumes: `nodes.Body`, the typed tree stage 4's checked walk
//! records, plus the settled declaration tables (`Deps`).
//! Produces: instructions on a `mir.build.Lowering` — **the one
//! emission there is**.  The dual-emission gate that held this pass
//! byte-identical to the fused walk's emissions retired with those
//! emissions, and the recorded corpus it was checked against went with
//! it; what proves the pass now is the suite — every spec program runs
//! on both engines and the two are compared on prints, traps, traces
//! and leaks (docs/ENGINE.md).
//!
//! **This pass is mechanical and diagnostic-free.**  Its error set is
//! `error{OutOfMemory}` and nothing else, by design: every decision —
//! resolution, types, ownership verbs, store kinds, borrow-copy
//! rewrites, park claims — was made during checking and recorded on
//! the tree.  An arm that wants to fail here has found a tree that
//! under-records, and the fix is the *recording* (`builder.zig`),
//! never a widened error set.
//!
//! One decision is this pass's own, and only one: **where a value has
//! to cross a basic-block split** (hir.zig, coupling #4).  It is a
//! question about blocks, which only the half that makes them can
//! answer, so the spill, its slot and its reload are decided, made and
//! emitted here — `markSpills` off `nodes.splitsBlocks`, the slot
//! after the recorded table, and `assertSplitCarried` holding the
//! decision against the block the emission actually left.
//!
//! What is re-derived rather than recorded — the whole list, so a
//! reader can tell a deliberate derivation from a tree that
//! under-records: the zero fill of a late declaration from the
//! slot's type; a `for x in xs:` loop's iteration machinery and
//! per-iteration binding from the sequence's shape and the recorded
//! name rows; a match or catch binding scope's storage releases from
//! the locals table; a compound assignment's read-combine-narrow from
//! the place's type; the writing-receiver keep-copy from the resolved
//! callee; `export_storage` at returns from `carriesText`; a `try`'s
//! failing side from the recorded `temps_floor`, the live park ledger
//! and the scope stack; and every store's take-or-copy from the same
//! ledger walk the checker performed — with the recorded `StoreKind`s
//! held against it as assertions wherever a statement spells one.

const std = @import("std");
const source = @import("../source.zig");
const types = @import("../support/types.zig");
const mir = @import("../mir.zig");
const nodes = @import("nodes.zig");
const context = @import("../semantics/context.zig");

const Allocator = std.mem.Allocator;
const Type = types.Type;
const Register = mir.Register;
const BlockId = mir.BlockId;
const LocalId = mir.LocalId;

pub const Error = error{OutOfMemory};

/// Everything the replay needs beyond the tree and the tape: the
/// settled declaration tables the emission consults, and the facts of
/// the function being lowered.  All slices borrow the analyzer's
/// storage for the duration of the call.
pub const Deps = struct {
    /// Scratch for the replay's own ledgers; freed before return.
    temporary: Allocator,
    /// The interned heap shapes, for container methods and iteration.
    heap_types: []const types.HeapType,
    /// The interned function signatures, for indirect calls.
    signatures: []const types.Signature,
    /// The collected function surface, for resolved callees: receiver
    /// mode, parameter types and modes, results.
    functions: []const context.FunctionDeclInfo,
    /// Per file-scope constant: the folded value a `constant_ref`
    /// materializes.
    constants: []const context.TypedConstant,
    /// The function being lowered — the prologue's parameter rows and
    /// the outer scope's releases come from it.
    function: context.FunctionDeclInfo,
};

/// Lower `body` into `code` — the function whole: the entry block,
/// the receiver and parameter rows and the owning parameters' entry
/// binds (all derived from the declaration facts in `deps.function`),
/// the body's statements, and the outer scope's parameter releases on
/// the way out.  The caller hands over a configured, empty `Lowering`
/// and gets back the one tape there is.
pub fn lowerFunction(deps: Deps, body: *const nodes.Body, code: *mir.build.Lowering) Error!void {
    // A gapped body is the record of a failed check, and the driver
    // refuses to continue past diagnostics — so this pass never sees
    // one, and a gap here is a driver bug rather than a case.
    std.debug.assert(body.gaps == 0);
    var replay: Replay = .{ .deps = deps, .body = body, .code = code };
    defer replay.deinitScratch();
    try replay.replayBody();
}

// ---------------------------------------------------------------------------
// The replay walker
// ---------------------------------------------------------------------------

const Replay = struct {
    deps: Deps,
    body: *const nodes.Body,
    code: *mir.build.Lowering,

    /// The statement-temporary ledger, mirroring the checker's: parks
    /// enter with their at-park claims and adopting stores retract
    /// them, so mid-statement unwinds release what the checker's did.
    temps: std.ArrayList(Temp) = .empty,
    /// The scope stack: one owned list per open scope, scope zero
    /// being the parameter scope, so return unwinding releases what
    /// the checker's did.
    scopes: std.ArrayList(Scope) = .empty,
    loops: std.ArrayList(Loop) = .empty,
    /// The first unclaimed row of the recorded table.  Most rows replay in
    /// source order.  A conversion fitted after an operand batch can own a
    /// later row while wrapping an earlier operand, however, so recorded
    /// parks claim their explicit id and this cursor skips ids already
    /// reached out of order.  Every row is still type/name checked exactly
    /// once against the recorded table.
    next_slot: LocalId = 0,
    claimed_slots: []bool = &.{},
    /// What the innermost fallible call left for its `try`/`catch` —
    /// the walker's one-hop `opened` hand-over, replayed.
    opened: ?Opened = null,

    const Temp = struct {
        local: LocalId,
        register: Register,
        storage: bool,
        objects: bool = false,
        disownable: bool = true,
        taken: bool = false,
    };

    const Scope = struct { owned: std.ArrayList(Owned) = .empty };
    const Owned = struct { local: LocalId, storage: bool, objects: bool };
    const Loop = struct {
        continue_block: BlockId,
        exit_block: BlockId,
        scope_depth: usize,
        temps_depth: usize,
    };
    const Opened = struct { handler: BlockId, temps_floor: usize };

    fn scratch(self: *Replay) Allocator {
        return self.deps.temporary;
    }

    fn arena(self: *Replay) Allocator {
        return self.code.arena;
    }

    fn deinitScratch(self: *Replay) void {
        self.temps.deinit(self.scratch());
        for (self.scopes.items) |*scope| scope.owned.deinit(self.scratch());
        self.scopes.deinit(self.scratch());
        self.loops.deinit(self.scratch());
        if (self.claimed_slots.len != 0) self.scratch().free(self.claimed_slots);
    }

    fn replayBody(self: *Replay) Error!void {
        const info = self.deps.function;
        const hidden: usize = if (info.receiver == .not) 0 else 1;

        // The prologue: the tree's whole local table, then the entry
        // block, then the receiver and parameter rows in declaration
        // order — the table's leading rows, claimed in order.  A
        // parameter borrows its caller's objects (they are not released
        // here — objects live until the runtime sweeps at exit) and
        // borrows its caller's bytes, so a parameter owns no storage; a
        // writing receiver owns its `self` storage when the type carries
        // any, so writes made through it survive.
        try self.makeLocalTable();
        self.claimed_slots = try self.scratch().alloc(bool, self.body.locals.len);
        @memset(self.claimed_slots, false);
        try self.code.openBlock();
        if (info.receiver != .not) {
            const receiver_type = info.parameter_types[0];
            _ = self.takeSlot("self", receiver_type, info.receiver == .writes and
                self.ownsStorage(receiver_type));
        }
        for (info.declaration.parameters, 0..) |parameter, written_index| {
            const index = written_index + hidden;
            if (index >= info.parameter_types.len) break;
            const parameter_type = info.parameter_types[index];
            _ = self.takeSlot(parameter.name, parameter_type, false);
        }

        // Scope zero is the parameter scope; a parameter owns no
        // storage, so it starts empty.
        try self.pushScope();

        try self.replayBlockParts(self.body.statements, self.body.releases);

        // The outer scope's end: scope zero's own list, emitted the way
        // every scope's is (empty for parameters).
        try self.emitScopeEnd();

        // Every row the tree recorded was reached exactly once; what stands
        // past them are this pass's spill slots and nothing else.
        std.debug.assert(self.next_slot == self.body.locals.len);
    }

    // -- tables and predicates ---------------------------------------------

    fn ownsStorage(self: *const Replay, of: Type) bool {
        return switch (of) {
            .str, .bytes, .strukt, .variant, .function => true,
            .optional => |payload| self.ownsStorage(payload.asType()),
            else => false,
        };
    }

    fn carriesText(of: Type) bool {
        return switch (of) {
            .str, .bytes => true,
            .optional => |payload| carriesText(payload.asType()),
            else => false,
        };
    }

    /// Whether a value of this type names a reference object whose count a
    /// scope's end must lower — a container or a `file`/`task` resource, an
    /// optional of one, a function (whose run may own a bound receiver), or
    /// a struct or union value that carries one in a field.  The walk stops
    /// at a `.heap` reference and never enters it, so a value struct (which
    /// cannot contain itself, only a reference to more of its kind)
    /// terminates.
    fn carriesObjects(self: *const Replay, of: Type) Error!bool {
        // Two visited tables, one per aggregate index space, so a value
        // type that names itself — a `Node?` field on `Node` — is walked
        // once and terminates.  Modelled on `semantics/shapes.zig`,
        // whose `carriesObjects` this recomputes at the MIR layer.
        const seen_structs = try self.deps.temporary.alloc(bool, self.code.structs.len);
        defer self.deps.temporary.free(seen_structs);
        @memset(seen_structs, false);
        const seen_variants = try self.deps.temporary.alloc(bool, self.code.variants.len);
        defer self.deps.temporary.free(seen_variants);
        @memset(seen_variants, false);
        return carriesObjectsIn(self, of, seen_structs, seen_variants);
    }

    fn carriesObjectsIn(self: *const Replay, of: Type, seen_structs: []bool, seen_variants: []bool) bool {
        return switch (of) {
            .heap => true,
            .function => true,
            .optional => |payload| carriesObjectsIn(self, payload.asType(), seen_structs, seen_variants),
            .strukt => |layout| {
                if (seen_structs[layout]) return false;
                seen_structs[layout] = true;
                if (self.code.structs[layout].interface) return true;
                for (self.code.structs[layout].fields) |field| {
                    if (carriesObjectsIn(self, field.field_type, seen_structs, seen_variants)) return true;
                }
                return false;
            },
            .variant => |layout| {
                // An indirect value carries its payload box whatever
                // the payloads hold (docs/UNION.md D20).
                if (self.code.variants[layout].indirect) return true;
                if (seen_variants[layout]) return false;
                seen_variants[layout] = true;
                for (self.code.variants[layout].members) |member| {
                    for (member.fields) |field| {
                        if (carriesObjectsIn(self, field.field_type, seen_structs, seen_variants)) return true;
                    }
                }
                return false;
            },
            else => false,
        };
    }

    fn heapOf(self: *const Replay, of: Type) ?types.HeapType {
        if (of != .heap) return null;
        return self.deps.heap_types[of.heap];
    }

    // -- recorded local rows ------------------------------------------------

    /// Lay the tree's local table down on the tape, row for row,
    /// before the body's first instruction (hir.zig, coupling #5).
    ///
    /// The tree's numbering *is* the tape's, and every recorded slot
    /// is one the checked walk decided; making them all here — rather
    /// than one at a time as the decisions are replayed — leaves the
    /// ids identical to the recorded ones and leaves this pass free to
    /// make the one kind of slot the tree does not carry: the spill,
    /// which is lower's own decision (coupling #4) and lands after the
    /// recorded rows.
    ///
    /// The storage claim is *not* entered here: it is the declaration
    /// point's own answer, and the emission reads it between that
    /// point and any retraction (`disownStorage`), so `takeSlot`
    /// enters it where the declaration replays.
    fn makeLocalTable(self: *Replay) Error!void {
        for (self.body.locals, 0..) |row, index| {
            const id = if (index == 0 and self.deps.function.receiver == .writes)
                try self.code.addInoutLocal(row.name.?, row.local_type, false)
            else if (row.weak)
                try self.code.addWeakLocal(row.name.?, row.local_type)
            else if (row.name) |written|
                try self.code.addLocal(written, row.local_type, false)
            else
                try self.code.hiddenLocal(row.local_type, false);
            std.debug.assert(id == index);
            if (row.boxed_storage) self.code.boxStorage(id);
        }
    }

    /// Take the next unclaimed recorded row.  Derived lowering slots carry no
    /// id in HIR, so they use source order; rows that do carry an id go
    /// through `takeSlotAt` below.
    fn takeSlot(self: *Replay, name: ?[]const u8, local_type: Type, owns: bool) LocalId {
        const id = self.next_slot;
        return self.takeSlotAt(id, name, local_type, owns);
    }

    /// Claim one exact recorded row.  Interface fitting happens after a
    /// batch's written operands have all been checked, while replay visits
    /// the fitted wrapper with its earlier operand.  Its park can therefore
    /// be row N+1 before a nested later operand reaches row N.  The explicit
    /// id is the authority; the bitmap preserves the stronger invariants:
    /// every row once, with the recorded name and type.
    fn takeSlotAt(
        self: *Replay,
        id: LocalId,
        name: ?[]const u8,
        local_type: Type,
        owns: bool,
    ) LocalId {
        std.debug.assert(id < self.body.locals.len);
        std.debug.assert(!self.claimed_slots[id]);
        const row = self.body.locals[id];
        std.debug.assert(row.local_type.eql(local_type));
        if (name) |written| {
            std.debug.assert(row.name != null and std.mem.eql(u8, row.name.?, written));
        } else {
            std.debug.assert(row.name == null);
        }
        self.claimed_slots[id] = true;
        while (self.next_slot < self.claimed_slots.len and self.claimed_slots[self.next_slot]) {
            self.next_slot += 1;
        }
        self.code.claimStorage(id, owns);
        return id;
    }

    /// Take a *named* row whose storage class the recording settled —
    /// the loop-name and declaration rows, whose `owns_storage` embeds
    /// check-side analysis (nodes.LocalDecl).
    fn takeRecordedSlot(self: *Replay, expected: LocalId) LocalId {
        const row = self.body.locals[expected];
        return self.takeSlotAt(expected, row.name, row.local_type, row.owns_storage);
    }

    /// Make a spill slot: a row of **this pass's own**, after the
    /// recorded table, holding one operand's value across a block
    /// split (coupling #4).  It is hidden, it never owns storage — the
    /// reload is a view of what the slot holds — and it dies with the
    /// statement that made it.
    fn makeSpillSlot(self: *Replay, value_type: Type) Error!LocalId {
        return self.code.hiddenLocal(value_type, false);
    }

    // -- scopes, temps, releases -------------------------------------------

    fn pushScope(self: *Replay) Error!void {
        try self.scopes.append(self.scratch(), .{});
    }

    fn popScope(self: *Replay) void {
        var scope = self.scopes.pop().?;
        scope.owned.deinit(self.scratch());
    }

    fn currentScope(self: *Replay) *Scope {
        return &self.scopes.items[self.scopes.items.len - 1];
    }

    fn emitScopeReleases(self: *Replay, from: usize) Error!void {
        var scope_index = self.scopes.items.len;
        while (scope_index > from) {
            scope_index -= 1;
            const owned = self.scopes.items[scope_index].owned.items;
            var owned_index = owned.len;
            while (owned_index > 0) {
                owned_index -= 1;
                const release = owned[owned_index];
                if (release.objects) try self.code.releaseObject(release.local);
                try self.code.release(release.local, release.storage);
            }
        }
    }

    /// The normal end of the innermost scope: its owned list back,
    /// in reverse declaration order (`emitScopeEnd`).
    fn emitScopeEnd(self: *Replay) Error!void {
        try self.emitScopeReleases(self.scopes.items.len - 1);
    }

    fn emitTempReleasesUpTo(self: *Replay, from: usize, limit: usize) Error!void {
        var index = @min(self.temps.items.len, limit);
        while (index > from) {
            index -= 1;
            const temp = self.temps.items[index];
            if (temp.objects) try self.code.releaseObject(temp.local);
            try self.code.release(temp.local, temp.storage);
        }
    }

    fn emitTempReleases(self: *Replay, from: usize) Error!void {
        try self.emitTempReleasesUpTo(from, self.temps.items.len);
    }

    fn flushTemps(self: *Replay, from: usize) Error!void {
        try self.emitTempReleases(from);
        self.temps.shrinkRetainingCapacity(from);
    }

    /// Emit a recorded park: the store into its hidden slot; enter it in
    /// the ledger with its at-park storage claim.
    fn emitPark(self: *Replay, parked: nodes.Park, register: Register, value_type: Type) Error!void {
        const local = self.takeSlotAt(parked.local, null, value_type, parked.storage);
        try self.code.store(local, register);
        try self.temps.append(self.scratch(), .{
            .local = local,
            .register = register,
            .storage = parked.storage,
            .objects = parked.objects,
        });
    }

    /// A park the recording never sees — the compound concatenation
    /// and the writing-receiver keep-copy — re-derived here: always
    /// storage-only, always fresh.
    fn parkDerivedStorage(self: *Replay, register: Register, value_type: Type) Error!void {
        const local = self.takeSlot(null, value_type, true);
        try self.code.store(local, register);
        try self.temps.append(self.scratch(), .{
            .local = local,
            .register = register,
            .storage = true,
        });
    }

    // -- stores: take or copy ----------------------------------------------

    const StoredValue = struct { register: Register, kind: nodes.StoreKind };

    /// The checker's `takeStorage`, replayed over this ledger.
    fn takeStorage(self: *Replay, register: Register, provenance: nodes.Provenance) bool {
        if (provenance != .fresh) return false;
        for (self.temps.items) |*temp| {
            if (temp.register != register) continue;
            if (temp.taken) return false;
            if (!temp.storage) continue;
            if (!temp.disownable) return false;
            self.code.disownStorage(temp.local);
            temp.storage = false;
            temp.taken = true;
            return true;
        }
        return true;
    }

    /// The object half of a store: a reference kept in a place that
    /// outlives the statement must own its own count.  A borrow retains,
    /// so the source binding and the new holder each count.  A fresh
    /// reference is transferred untouched — its one reference moves into
    /// the place — and its statement-temporary park is retracted here so
    /// the end of the statement no longer releases it (`takeObjects`, the
    /// object half of `takeStorage`).  A value naming no object needs
    /// nothing (docs/MEMORY.md).
    fn keepReference(
        self: *Replay,
        register: Register,
        value_type: Type,
        provenance: nodes.Provenance,
    ) Error!void {
        if (!try self.carriesObjects(value_type)) return;
        switch (provenance) {
            // A fresh object transfers into the place: retract its park so
            // the statement's end no longer releases what the place now
            // owns.  A value carried out of a fallible call is parked the
            // same way (`finishFallible`), so its adoption retracts here too.
            .fresh => _ = self.takeObjects(register),
            // A borrow of an object something else holds — a name, a field
            // or element read — which the new holder counts by retaining.
            .view => try self.code.retainObject(register),
            // A fresh object that owns no storage — a `[..]` or `{..}`
            // literal — was parked and now transfers; anything else here is
            // an immortal constant or a narrowed reload, a borrow the new
            // holder retains (a retain on a constant is a no-op).
            .plain => if (!self.takeObjects(register)) try self.code.retainObject(register),
        }
    }

    /// Retract a fresh value's object park: the place that adopts it now
    /// owns its one reference, so the statement's end must not release it.
    /// Answers whether a park was found — a fresh object — or not, a borrow.
    fn takeObjects(self: *Replay, register: Register) bool {
        for (self.temps.items) |*temp| {
            if (temp.register != register) continue;
            if (!temp.objects) continue;
            temp.objects = false;
            return true;
        }
        return false;
    }

    fn ownedForStore(
        self: *Replay,
        register: Register,
        value_type: Type,
        provenance: nodes.Provenance,
    ) Error!StoredValue {
        try self.keepReference(register, value_type, provenance);
        if (!self.ownsStorage(value_type)) return .{ .register = register, .kind = .plain };
        if (self.takeStorage(register, provenance)) return .{ .register = register, .kind = .take };
        return .{ .register = try self.code.ownStorage(register), .kind = .copy };
    }

    /// Store into a local, taking or copying in when the slot owns its
    /// storage — `storeOwnedKind`'s shape, with the recorded decision
    /// asserted where the statement spells one.
    fn storeOwned(
        self: *Replay,
        local: LocalId,
        register: Register,
        value_type: Type,
        provenance: nodes.Provenance,
        recorded: ?nodes.StoreKind,
    ) Error!void {
        if (self.code.localIsWeak(local)) {
            // A weak place keeps no strong reference and owns no value
            // storage. The source temporary remains parked and dies at the
            // statement boundary unless some other strong place adopts it.
            try self.code.store(local, register);
            if (recorded) |kind| std.debug.assert(kind == .plain);
            return;
        }
        if (!self.code.localOwnsStorage(local)) {
            try self.keepReference(register, value_type, provenance);
            try self.code.store(local, register);
            if (recorded) |kind| std.debug.assert(kind == .plain);
            return;
        }
        const stored = try self.ownedForStore(register, value_type, provenance);
        try self.code.store(local, stored.register);
        if (recorded) |kind| std.debug.assert(kind == stored.kind);
    }

    // -- expressions --------------------------------------------------------

    /// Replay one expression node and everything under it: the node's
    /// own instructions, then its recorded park.  `suppress_park` is the batch walk's hook —
    /// a borrow-copied operand's park belongs after the copy.
    fn replayValue(self: *Replay, node: nodes.NodeRef) Error!Register {
        return self.replayValueInner(node, false);
    }

    fn replayValueInner(self: *Replay, node: nodes.NodeRef, suppress_park: bool) Error!Register {
        const register = try self.replayCore(node);
        if (!suppress_park) try self.replayParkOf(node, register);
        return register;
    }

    /// Emit `node`'s recorded park, if any — except a carried slot's,
    /// whose store and bind the fallible machinery places itself.
    fn replayParkOf(self: *Replay, node: nodes.NodeRef, register: Register) Error!void {
        if (node.* == .carried_get) return;
        const parked = node.park() orelse return;
        try self.emitPark(parked, register, node.result());
    }

    fn replayCore(self: *Replay, node: nodes.NodeRef) Error!Register {
        return switch (node.*) {
            .const_integer => |literal| try self.code.emit(.{ .const_integer = literal.value }, literal.result),
            .const_float => |literal| try self.code.emit(.{ .const_float = literal.value }, literal.result),
            .const_boolean => |literal| try self.code.emit(.{ .const_boolean = literal.value }, literal.result),
            .const_str => |literal| try self.code.emit(.{ .const_str = literal.constant }, literal.result),
            .absent => |absent| try self.code.zeroOf(absent.result),
            .local_get => |read| try self.code.load(read.local),
            .narrowed_get => |read| narrowed: {
                const loaded = try self.code.load(read.local);
                const arguments = try self.arena().alloc(Register, 1);
                arguments[0] = loaded;
                break :narrowed try self.code.emit(
                    .{ .intrinsic = .{ .kind = .optional_unwrap, .arguments = arguments } },
                    read.payload,
                );
            },
            .field_get => |read| field: {
                const target = try self.replayValue(read.target);
                const stored_type = read.stored orelse read.result;
                const stored = try self.code.emit(
                    if (read.weak) .{ .weak_struct_get = .{
                        .target = target,
                        .layout = read.layout,
                        .field = read.field,
                    } } else .{ .struct_get = .{
                        .target = target,
                        .layout = read.layout,
                        .field = read.field,
                    } },
                    stored_type,
                );
                if (!read.narrowed) break :field stored;
                const arguments = try self.arena().alloc(Register, 1);
                arguments[0] = stored;
                break :field try self.code.emit(
                    .{ .intrinsic = .{ .kind = .optional_unwrap, .arguments = arguments } },
                    read.result,
                );
            },
            .variant_payload => |read| payload: {
                const target = try self.replayValue(read.target);
                break :payload try self.code.emit(.{ .variant_field = .{
                    .target = target,
                    .variant = read.variant,
                    .member = read.member,
                    .field = read.field,
                } }, read.result);
            },
            .index_get => |read| try self.replayIndexGet(read),
            .constant_ref => |use| (try self.materializeConstant(
                self.deps.constants[use.constant].value,
                use.result,
            )).register,
            .container_ref => |use| try self.code.emit(.{ .const_container = use.row }, use.result),
            .foreign_get => |read| try self.code.emit(.{ .foreign_get = read.variable }, read.result),
            .carried_get => |carried| try self.replayCore(carried.origin),
            .binary => |operation| try self.replayBinary(operation),
            .convert => |conversion| convert: {
                const operand = try self.replayValue(conversion.operand);
                break :convert try self.code.emit(.{ .convert = operand }, conversion.result);
            },
            .wrap_optional => |wrapped| wrap: {
                const operand = try self.replayValue(wrapped.operand);
                const arguments = try self.arena().alloc(Register, 1);
                arguments[0] = operand;
                break :wrap try self.code.emit(
                    .{ .intrinsic = .{ .kind = .optional_wrap, .arguments = arguments } },
                    wrapped.result,
                );
            },
            .unary => |operation| unary: {
                const operand = try self.replayValue(operation.operand);
                break :unary try self.code.emit(
                    .{ .unary = .{ .op = operation.op, .operand = operand } },
                    operation.result,
                );
            },
            .short_circuit => |circuit| try self.replayShortCircuit(circuit),
            .coalesce => |fallback| try self.replayCoalesce(fallback),
            .compare => |comparison| try self.replayCompare(comparison),
            .call => |called| try self.replayCall(called),
            .try_call => |attempt| try self.replayTry(attempt),
            .catch_expr => |caught| try self.replayCatch(caught),
            .struct_make => |built| try self.replayStructMake(built),
            .interface_make => |built| interface: {
                const receiver = try self.replayValue(built.receiver);
                const held = try self.ownedForStore(
                    receiver,
                    built.receiver.result(),
                    .view,
                );
                break :interface try self.code.emit(.{ .interface_make = .{
                    .layout = built.layout,
                    .witness = built.witness,
                    .receiver = held.register,
                } }, built.result);
            },
            .variant_make => |built| try self.replayVariantMake(built),
            .list_literal => |literal| try self.replayListLiteral(literal),
            .map_literal => |literal| try self.replayMapLiteral(literal),
            .slice => |sliced| try self.replaySlice(sliced),
            .new_object => |made| try self.replayNewObject(made),
            .spawn => |worker| try self.replaySpawn(worker),
            .function_value => |named| try self.code.emit(
                .{
                    .const_function = .{
                        .function = named.function,
                        // The value's own fallibility (docs/ERRORS.md R3):
                        // the declared function's, whatever slot it fills.
                        .fallible = self.deps.functions[named.function].fallible,
                    },
                },
                named.result,
            ),
            .lambda_ref => |made| closure: {
                const receiver = if (made.environment) |environment| held: {
                    const value = try self.replayValue(environment);
                    const owned = try self.ownedForStore(
                        value,
                        environment.result(),
                        nodes.provenance(environment),
                    );
                    break :held owned.register;
                } else null;
                break :closure try self.code.emit(.{ .const_function = .{
                    .function = made.function,
                    .receiver = receiver,
                    .fallible = self.deps.functions[made.function].fallible,
                } }, made.result);
            },
            .bound_method => |bound| bind: {
                const receiver = try self.replayValue(bound.receiver);
                // A bound function is an owning value.  A fresh receiver can
                // move into it; a borrowed receiver is copied and retained.
                const held = try self.ownedForStore(
                    receiver,
                    bound.receiver.result(),
                    nodes.provenance(bound.receiver),
                );
                break :bind try self.code.emit(.{ .const_function = .{
                    .function = bound.function,
                    .receiver = held.register,
                    .fallible = self.deps.functions[bound.function].fallible,
                } }, bound.result);
            },
        };
    }

    // -- operand runs: the batch walk --------------------------------------

    /// One operand's replay state through a batch: the register after
    /// the core (and any copy/spill rewrites), and the wrapper chain —
    /// the `convert`/`wrap_optional` nodes the site emits after the
    /// whole batch — innermost first.
    const BatchEntry = struct {
        register: Register = 0,
        core: nodes.NodeRef,
        wrappers: []const nodes.NodeRef,
        /// Whether something lowered after this operand opens a block,
        /// so its value cannot stay in a register — decided by
        /// `markSpills` before the run is replayed (coupling #4).
        needs_spill: bool = false,
        /// The slot it was carried across the split in, once it has
        /// been made.
        spill: ?LocalId = null,
        /// The value's storage provenance as the batch leaves it —
        /// the checker's own answer, re-derived: the core's node-kind
        /// answer, made fresh by a borrow copy, made a view by a
        /// spill reload, made plain by an optional wrap.
        provenance: nodes.Provenance = .plain,
    };

    /// Peel the top `wrap_optional` chain off a recorded operand. A fit into
    /// a batch slot wraps after that batch has evaluated its source
    /// expressions. Explicit numeric conversions are source expressions and
    /// deliberately stay in the core, so a trapping left conversion happens
    /// before the right expression runs.
    fn peel(self: *Replay, node: nodes.NodeRef) Error!BatchEntry {
        var wrappers: std.ArrayList(nodes.NodeRef) = .empty;
        defer wrappers.deinit(self.scratch());
        var core = node;
        while (true) {
            switch (core.*) {
                .wrap_optional => |wrapped| {
                    try wrappers.append(self.scratch(), core);
                    core = wrapped.operand;
                },
                else => break,
            }
        }
        std.mem.reverse(nodes.NodeRef, wrappers.items);
        return .{
            .core = core,
            .wrappers = try self.arena().dupe(nodes.NodeRef, wrappers.items),
            .provenance = nodes.provenance(core),
        };
    }

    /// Replay one batch operand's core with its two rewrites: the
    /// defensive borrow copy the tree records (and the park that rides
    /// it), then the spill store this pass decided.
    fn replayBatchOperand(
        self: *Replay,
        entry: *BatchEntry,
        copied: bool,
    ) Error!void {
        if (copied) {
            const register = try self.replayValueInner(entry.core, true);
            entry.register = try self.code.ownStorage(register);
            // The copy closed a borrow with storage this statement
            // allocated: fresh, whatever the borrow was.
            entry.provenance = .fresh;
            // The copy's park was recorded onto the operand node
            // (nodes.OperandBatch's pre-copy convention).
            if (entry.core.park()) |parked| {
                try self.emitPark(parked, entry.register, entry.core.result());
            }
        } else {
            entry.register = try self.replayValue(entry.core);
        }
        if (entry.needs_spill and entry.core.result() != .none) {
            const slot = try self.makeSpillSlot(entry.core.result());
            try self.code.store(slot, entry.register);
            entry.spill = slot;
        }
    }

    /// The declaration tables `nodes.splitsBlocks` reads — the member
    /// counts that tell a one-constant text conversion from a
    /// compare-and-branch chain.
    fn declarations(self: *const Replay) nodes.Declarations {
        return .{ .enums = self.code.enums, .variants = self.code.variants };
    }

    /// Decide the run's spills before a line of it is emitted: an
    /// operand's value cannot stay in a register past an operand that
    /// opens a block, so it crosses the split in a slot instead.
    ///
    /// The question is a *suffix* one — "does anything after me
    /// split" — so the walk runs backwards, and it is asked of the
    /// recorded nodes, where `nodes.splitsBlocks` answers it exactly
    /// (hir.zig, coupling #4).  The checker asks the same function
    /// about the same nodes to settle the reload's provenance, so the
    /// two halves decide one thing between them and nothing is
    /// recorded.
    ///
    /// `trailing` is what a batch lowers *after* its written operands
    /// — the defaulted suffix — and it is asserted rather than
    /// scanned: a default is a materialized constant and opens no
    /// block, and one that did would put the two halves' answers out
    /// of step, which is a worse failure than the verifier's.
    fn markSpills(
        self: *const Replay,
        entries: []BatchEntry,
        trailing: []const nodes.NodeRef,
    ) void {
        const declared = self.declarations();
        for (trailing) |node| std.debug.assert(!nodes.splitsBlocks(node, declared));
        var later = false;
        var at = entries.len;
        while (at > 0) {
            at -= 1;
            entries[at].needs_spill = later;
            if (nodes.splitsBlocks(entries[at].core, declared)) later = true;
        }
    }

    /// Coupling #4's exactness, held where it costs least: if lowering
    /// an operand did leave the block it started in, every value the
    /// run produced before it is already in a slot.  A node kind whose
    /// lowering opens a block without saying so in `nodes.splitsBlocks`
    /// trips here, on the first program that reaches it, instead of
    /// reaching the MIR verifier as a register crossing a block.
    fn assertSplitCarried(self: *const Replay, earlier: []const BatchEntry, before: BlockId) void {
        if (self.code.current == before) return;
        for (earlier) |entry| {
            std.debug.assert(entry.spill != null or entry.core.result() == .none);
        }
    }

    /// Reload every spilled operand, in operand order — the batch
    /// walk's closing loop.
    fn reloadSpills(self: *Replay, entries: []BatchEntry) Error!void {
        for (entries) |*entry| {
            const slot = entry.spill orelse continue;
            entry.register = try self.code.load(slot);
            // The reload is a view of the spill slot's storage.
            entry.provenance = .view;
        }
    }

    /// Apply one operand's optional wrappers, innermost first. A wrapped value
    /// has no storage stamp of its own (`fit`'s Typed defaults).
    fn applyWrappers(self: *Replay, entry: *BatchEntry) Error!void {
        if (entry.wrappers.len != 0) entry.provenance = .plain;
        for (entry.wrappers) |wrapper| {
            switch (wrapper.*) {
                .wrap_optional => |wrapped| {
                    const arguments = try self.arena().alloc(Register, 1);
                    arguments[0] = entry.register;
                    entry.register = try self.code.emit(
                        .{ .intrinsic = .{ .kind = .optional_wrap, .arguments = arguments } },
                        wrapped.result,
                    );
                },
                else => unreachable, // peel collects only optional wraps
            }
        }
    }

    /// The type an operand's replay answers once its wrappers are on.
    fn wrappedType(entry: *const BatchEntry) Type {
        if (entry.wrappers.len == 0) return entry.core.result();
        return entry.wrappers[entry.wrappers.len - 1].result();
    }

    /// Replay a recorded `OperandBatch`'s written operands: cores in
    /// evaluation order with their copy and spill rewrites, then the
    /// reloads.  Wrappers and defaults are the call site's, because
    /// their timing is the site's own.
    fn replayWrittenOperands(self: *Replay, batch: nodes.OperandBatch) Error![]BatchEntry {
        const written = batch.written;
        const entries = try self.scratch().alloc(BatchEntry, batch.operands.len);
        errdefer self.scratch().free(entries);
        for (batch.operands[0..written], 0..) |operand, index| {
            entries[index] = try self.peel(operand);
        }
        self.markSpills(entries[0..written], batch.operands[written..]);
        for (entries[0..written], 0..) |*entry, index| {
            const opened_in = self.code.current;
            try self.replayBatchOperand(entry, batch.borrow_copy[index]);
            self.assertSplitCarried(entries[0..index], opened_in);
        }
        try self.reloadSpills(entries[0..written]);
        return entries;
    }

    /// Replay a non-permuting operand run (`nodes.Operand`s): cores
    /// with rewrites, reloads — wrappers stay the caller's.
    fn replayOperandRun(self: *Replay, operands: []const nodes.Operand) Error![]BatchEntry {
        const entries = try self.scratch().alloc(BatchEntry, operands.len);
        errdefer self.scratch().free(entries);
        for (operands, entries) |operand, *entry| entry.* = try self.peel(operand.node);
        self.markSpills(entries, &.{});
        for (operands, entries, 0..) |operand, *entry, index| {
            const opened_in = self.code.current;
            try self.replayBatchOperand(entry, operand.copied);
            self.assertSplitCarried(entries[0..index], opened_in);
        }
        try self.reloadSpills(entries);
        return entries;
    }

    /// Replay a batch's defaulted entries. Each is an already-typed
    /// materialized constant emitted whole when the call fills the slot.
    fn replayDefaultEntry(
        self: *Replay,
        entries: []BatchEntry,
        index: usize,
        node: nodes.NodeRef,
    ) Error!void {
        var entry: BatchEntry = .{ .core = node, .wrappers = &.{}, .provenance = nodes.provenance(node) };
        entry.register = try self.replayValue(node);
        entries[index] = entry;
    }

    // -- operators ----------------------------------------------------------

    /// The two-operand pair walk: cores in recorded evaluation order with
    /// their copy/spill rewrites, followed by optional wraps left-to-right.
    fn replaySides(
        self: *Replay,
        left: nodes.NodeRef,
        right: nodes.NodeRef,
        sides: nodes.Expression.Sides,
    ) Error![2]BatchEntry {
        var entries: [2]BatchEntry = .{ try self.peel(left), try self.peel(right) };
        if (sides.right_first) {
            // The typed side runs first and the other side is an
            // untyped literal or a bare function name — a constant,
            // which opens no block, so neither side is ever carried
            // (nodes.Expression.Sides).
            std.debug.assert(!sides.left_copied);
            std.debug.assert(!nodes.splitsBlocks(entries[0].core, self.declarations()));
            try self.replayBatchOperand(&entries[1], false);
            try self.replayBatchOperand(&entries[0], false);
        } else {
            self.markSpills(entries[0..], &.{});
            try self.replayBatchOperand(&entries[0], sides.left_copied);
            const opened_in = self.code.current;
            try self.replayBatchOperand(&entries[1], false);
            self.assertSplitCarried(entries[0..1], opened_in);
            try self.reloadSpills(entries[0..]);
        }
        for (&entries) |*entry| try self.applyWrappers(entry);
        return entries;
    }

    fn replayBinary(self: *Replay, operation: nodes.Expression.Binary) Error!Register {
        const entries = try self.replaySides(operation.left, operation.right, operation.sides);
        return self.code.emit(.{ .binary = .{
            .op = operation.op,
            .operand_type = operation.result,
            .left = entries[0].register,
            .right = entries[1].register,
        } }, operation.result);
    }

    fn replayCompare(self: *Replay, comparison: nodes.Expression.Compare) Error!Register {
        // `x == none` / `x != none`: one side is the written absence,
        // which emits nothing — the test is `is_none` on the other.
        if (comparison.left.* == .absent or comparison.right.* == .absent) {
            const tested = if (comparison.left.* == .absent) comparison.right else comparison.left;
            const register = try self.replayValue(tested);
            const arguments = try self.arena().alloc(Register, 1);
            arguments[0] = register;
            const absent = try self.code.emit(
                .{ .intrinsic = .{ .kind = .is_none, .arguments = arguments } },
                .boolean,
            );
            if (comparison.op == .equal) return absent;
            return self.code.emit(.{ .unary = .{ .op = .logic_not, .operand = absent } }, .boolean);
        }
        const entries = try self.replaySides(comparison.left, comparison.right, comparison.sides);
        const operand_type = wrappedType(&entries[0]);
        // The union tag test (docs/UNION.md): stage 4 admits `==` on a
        // union only when one side is a payload-less member literal, so
        // equal tags mean equal values — the comparison is the tags'.
        if (operand_type == .variant) {
            const left_tag = try self.code.emit(
                .{ .variant_tag = .{ .target = entries[0].register } },
                .i64,
            );
            const right_tag = try self.code.emit(
                .{ .variant_tag = .{ .target = entries[1].register } },
                .i64,
            );
            return self.code.emit(.{ .binary = .{
                .op = comparison.op,
                .operand_type = .i64,
                .left = left_tag,
                .right = right_tag,
            } }, .boolean);
        }
        return self.code.emit(.{ .binary = .{
            .op = comparison.op,
            .operand_type = operand_type,
            .left = entries[0].register,
            .right = entries[1].register,
        } }, .boolean);
    }

    /// The result type under an operand's wrapper chain.
    fn coreTypeOf(node: nodes.NodeRef) Type {
        var core = node;
        while (true) {
            switch (core.*) {
                .convert => |conversion| core = conversion.operand,
                .wrap_optional => |wrapped| core = wrapped.operand,
                else => return core.result(),
            }
        }
    }

    fn replayShortCircuit(self: *Replay, circuit: nodes.Expression.ShortCircuit) Error!Register {
        const left = try self.replayValue(circuit.left);
        // The answer lives in a slot because the two sides are
        // written in different blocks and a register never crosses
        // one; the row comes through the recorded local table.
        const result = self.takeSlot(null, .boolean, false);
        try self.code.store(result, left);
        const right_block = try self.code.reserveBlock();
        const merge = try self.code.reserveBlock();
        if (circuit.op == .logic_and) {
            try self.code.branch(left, right_block, merge);
        } else {
            try self.code.branch(left, merge, right_block);
        }
        self.code.switchTo(right_block);
        const right = try self.replayValue(circuit.right);
        try self.code.store(result, right);
        try self.code.jump(merge);
        self.code.switchTo(merge);
        return self.code.load(result);
    }

    fn replayCoalesce(self: *Replay, fallback: nodes.Expression.Coalesce) Error!Register {
        const left = try self.replayValue(fallback.value);
        const payload = fallback.result;
        const arguments = try self.arena().alloc(Register, 1);
        arguments[0] = left;
        const absent = try self.code.emit(
            .{ .intrinsic = .{ .kind = .is_none, .arguments = arguments } },
            .boolean,
        );
        const unwrap = try self.arena().alloc(Register, 1);
        unwrap[0] = left;
        const present = try self.code.emit(
            .{ .intrinsic = .{ .kind = .optional_unwrap, .arguments = unwrap } },
            payload,
        );
        const either = try self.openMergeSlot(payload, absent, present);
        switch (fallback.fallback) {
            .leaving => |leaving| _ = try self.replayLeaving(leaving),
            .value => |value| {
                const landed = try self.replayValue(value);
                try self.code.store(either.result, landed);
            },
        }
        return self.code.closeShortCircuit(either);
    }

    /// A short circuit's shape with the result typed by the fallback
    /// rather than bool: park the present value, then run the fallback
    /// only where `absent` says there was none.  The merge slot's row
    /// comes through the recorded local table.
    fn openMergeSlot(
        self: *Replay,
        result_type: Type,
        absent: Register,
        present: Register,
    ) Error!mir.build.Lowering.ShortCircuit {
        const result = self.takeSlot(null, result_type, false);
        try self.code.store(result, present);
        const fallback_block = try self.code.reserveBlock();
        const merge = try self.code.reserveBlock();
        try self.code.branch(absent, fallback_block, merge);
        self.code.switchTo(fallback_block);
        return .{ .result = result, .right_block = fallback_block, .merge = merge };
    }

    /// A leaving call in fallback position — `trap("…")`,
    /// `error("…")`, `exit(n)` — evaluated for its exit: the intrinsic
    /// and, for `error`, the unwind it owes.
    fn replayLeaving(self: *Replay, node: nodes.NodeRef) Error!Register {
        return self.replayValue(node);
    }

    // -- calls --------------------------------------------------------------

    fn replayCall(self: *Replay, called: nodes.Expression.Call) Error!Register {
        switch (called.callee) {
            .function => |index| return self.replayDirectCall(called, index),
            .foreign => |index| return self.replayForeignCall(called, index),
            .indirect => |through| return self.replayIndirectCall(called, through),
            .interface => |through| return self.replayInterfaceCall(called, through),
            .intrinsic => |kind| return self.replayIntrinsicCall(called, kind),
            .conversion => |produced| return self.replayConversion(called, produced),
            .enum_name => |index| return self.replayEnumText(called, index),
            .variant_name => |index| return self.replayVariantText(called, index),
        }
    }

    fn replayInterfaceCall(
        self: *Replay,
        called: nodes.Expression.Call,
        through: nodes.ResolvedCallee.Interface,
    ) Error!Register {
        const signature = self.deps.signatures[through.signature];
        const batch = called.operands;
        const entries = try self.replayWrittenOperands(batch);
        defer self.scratch().free(entries);

        for (entries[0..batch.written], batch.slots[0..batch.written], 0..) |*entry, slot, position| {
            try self.applyWrappers(entry);
            if (through.writing and position != 0) {
                const parameter = signature.parameters[slot - 1].value_type;
                if (self.ownsStorage(parameter)) {
                    entry.register = try self.code.ownStorage(entry.register);
                    try self.parkDerivedStorage(entry.register, parameter);
                }
            }
        }

        const registers = try self.arena().alloc(Register, signature.parameters.len + 1);
        for (entries, batch.slots) |entry, slot| registers[slot] = entry.register;
        const arguments = try self.arena().alloc(Register, signature.parameters.len);
        @memcpy(arguments, registers[1..]);
        const writing = if (through.writing)
            try self.prepareWritingReceiver(
                batch.operands[0],
                entries[0].register,
                entries[0].provenance,
            )
        else
            WritingReceiver{ .local = 0 };
        const call = if (through.writing)
            try self.code.emit(.{ .interface_call_inout = .{
                .receiver = writing.local,
                .layout = through.layout,
                .method = through.method,
                .arguments = arguments,
                .fallible = through.fallible,
            } }, signature.result)
        else
            try self.code.emit(.{ .interface_call = .{
                .receiver = registers[0],
                .layout = through.layout,
                .method = through.method,
                .arguments = arguments,
                .fallible = through.fallible,
            } }, signature.result);
        if (through.writing) try self.finishWritingReceiver(writing);
        return self.finishFallible(call, called, .fresh);
    }

    /// A foreign call replays like a direct call with everything a C
    /// boundary cannot have carried: no defaults, no receiver, no
    /// fallibility — every operand crosses borrowed, and the engines
    /// allocate the `out` slots themselves (docs/FFI.md).  What the
    /// call *answers* may own storage — a copied `-> str`, a shape of
    /// out values — and parks through the ordinary fresh-result rules.
    fn replayForeignCall(self: *Replay, called: nodes.Expression.Call, index: u32) Error!Register {
        const batch = called.operands;
        const entries = try self.replayWrittenOperands(batch);
        defer self.scratch().free(entries);
        for (entries) |*entry| try self.applyWrappers(entry);
        const registers = try self.arena().alloc(Register, batch.operands.len);
        for (entries, batch.slots) |entry, slot| registers[slot] = entry.register;
        return self.code.emit(
            .{ .call_foreign = .{ .foreign = index, .arguments = registers } },
            called.result,
        );
    }

    fn replayDirectCall(self: *Replay, called: nodes.Expression.Call, index: u32) Error!Register {
        const info = self.deps.functions[index];
        const batch = called.operands;
        const entries = try self.replayWrittenOperands(batch);
        defer self.scratch().free(entries);
        const writing = info.receiver == .writes;
        // Per written operand, in evaluation order: the fit wrappers,
        // then the writing-receiver keep-copy the resolved callee
        // forces on storage-owning arguments (re-derived, not a batch
        // flag — nodes.OperandBatch).
        for (entries[0..batch.written], batch.slots[0..batch.written], 0..) |*entry, slot, position| {
            try self.applyWrappers(entry);
            if (writing and position != 0 and self.ownsStorage(info.parameter_types[slot])) {
                entry.register = try self.code.ownStorage(entry.register);
                try self.parkDerivedStorage(entry.register, info.parameter_types[slot]);
            }
        }
        // Defaults, in materialization order.
        for (batch.operands[batch.written..], batch.written..) |node, position| {
            try self.replayDefaultEntry(entries, position, node);
        }
        // Permute into declaration order.
        const registers = try self.arena().alloc(Register, info.parameter_types.len);
        for (entries, batch.slots) |entry, slot| registers[slot] = entry.register;
        if (writing) {
            // The receiver travels as a place; the argument run is one
            // shorter, and the place is the receiver operand's local.
            const receiver = try self.prepareWritingReceiver(
                batch.operands[0],
                entries[0].register,
                entries[0].provenance,
            );
            const explicit = try self.arena().alloc(Register, registers.len - 1);
            @memcpy(explicit, registers[1..]);
            const call = try self.code.emit(.{ .call_inout = .{
                .function = index,
                .receiver = receiver.local,
                .arguments = explicit,
            } }, info.return_type);
            try self.finishWritingReceiver(receiver);
            return self.finishFallible(call, called, .fresh);
        }
        const call = try self.code.emit(
            .{ .call = .{ .function = index, .arguments = registers } },
            info.return_type,
        );
        return self.finishFallible(call, called, .fresh);
    }

    const WritingReceiver = struct {
        local: LocalId,
        writeback: ?Writeback = null,
    };

    const Writeback = struct {
        target: nodes.NodeRef,
        layout: u32,
        field: u32,
    };

    /// A writing call normally aliases a local slot directly. A mutable
    /// local captured by a block closure is represented in HIR as a read of
    /// the hidden capture-cell field, however. Materialize that field into
    /// one owned temporary so the existing MIR inout instruction can still
    /// express the call, then copy the changed existential back to the cell.
    /// The temporary is tracked like every other statement storage and is
    /// released on both the success and failure paths.
    fn prepareWritingReceiver(
        self: *Replay,
        node: nodes.NodeRef,
        register: Register,
        provenance: nodes.Provenance,
    ) Error!WritingReceiver {
        return switch (node.*) {
            .local_get => |read| .{ .local = read.local },
            .field_get => |field| receiver: {
                const receiver_type = node.result();
                const stored = try self.ownedForStore(register, receiver_type, provenance);
                const local = try self.makeSpillSlot(receiver_type);
                // The temporary owns the interface run until the writeback
                // consumes it.  Claiming storage here is what makes its MIR
                // slot a boxed `Value` rather than a bare struct pointer;
                // `interface_call_inout` must pass the payload cell to the
                // witness adapter, not reinterpret that pointer as a box.
                self.code.claimStorage(local, true);
                try self.code.store(local, stored.register);
                try self.temps.append(self.scratch(), .{
                    .local = local,
                    .register = stored.register,
                    .storage = true,
                    .objects = try self.carriesObjects(receiver_type),
                });
                break :receiver .{
                    .local = local,
                    .writeback = .{
                        .target = field.target,
                        .layout = field.layout,
                        .field = field.field,
                    },
                };
            },
            else => unreachable, // semantics admits only a bare writable name
        };
    }

    /// Store a captured writer's updated value back into its hidden class
    /// cell. This is deliberately emitted immediately after the call, before
    /// fallible control-flow branches, so a witness that mutates and then
    /// reports an error has the same inout semantics as a direct local call.
    fn finishWritingReceiver(self: *Replay, receiver: WritingReceiver) Error!void {
        const writeback = receiver.writeback orelse return;
        const base = try self.replayValue(writeback.target);
        const value = try self.code.load(receiver.local);
        const receiver_type = self.code.localType(receiver.local);
        const stored = try self.ownedForStore(value, receiver_type, .view);
        const layout = self.code.structs[writeback.layout];
        std.debug.assert(layout.reference);
        const field = layout.fields[writeback.field];
        _ = try self.code.emit(
            if (field.weak) .{ .weak_struct_set = .{
                .target = base,
                .layout = writeback.layout,
                .field = writeback.field,
                .value = stored.register,
            } } else .{ .struct_set = .{
                .target = base,
                .layout = writeback.layout,
                .field = writeback.field,
                .value = stored.register,
            } },
            .none,
        );
    }

    fn replayIndirectCall(
        self: *Replay,
        called: nodes.Expression.Call,
        through: nodes.ResolvedCallee.Indirect,
    ) Error!Register {
        const signature = self.deps.signatures[through.signature];
        const batch = called.operands;
        // **The callee is the run's first operand**
        // (nodes.ResolvedCallee.Indirect): what the reader wrote first
        // runs first, and it rides in the same run as the arguments
        // because `markSpills` is a suffix question that can only be
        // answered about values it can see — an argument that opens a
        // block would otherwise strand the callee's register.
        const entries = try self.scratch().alloc(BatchEntry, batch.operands.len + 1);
        defer self.scratch().free(entries);
        entries[0] = try self.peel(through.callee);
        for (batch.operands, entries[1..]) |operand, *entry| entry.* = try self.peel(operand);
        self.markSpills(entries, &.{});
        for (entries, 0..) |*entry, position| {
            const opened_in = self.code.current;
            const copied = if (position == 0) through.borrow_copy else batch.borrow_copy[position - 1];
            try self.replayBatchOperand(entry, copied);
            self.assertSplitCarried(entries[0..position], opened_in);
        }
        try self.reloadSpills(entries);
        for (entries) |*entry| try self.applyWrappers(entry);
        // A function type has no names and no defaults, so the written
        // run is the whole argument list: slot i is operand i.
        const registers = try self.arena().alloc(Register, batch.operands.len);
        for (entries[1..], batch.slots) |entry, slot| registers[slot] = entry.register;
        const call = try self.code.emit(.{ .call_indirect = .{
            .callee = entries[0].register,
            .signature = through.signature,
            .arguments = registers,
            .fallible = called.fallible,
        } }, signature.result);
        return self.finishFallible(call, called, .fresh);
    }

    fn replayIntrinsicCall(
        self: *Replay,
        called: nodes.Expression.Call,
        kind: mir.Intrinsic,
    ) Error!Register {
        const batch = called.operands;
        const entries = try self.replayWrittenOperands(batch);
        defer self.scratch().free(entries);
        // A free builtin's defaults materialize right after the batch.
        for (batch.operands[batch.written..], batch.written..) |node, position| {
            try self.replayDefaultEntry(entries, position, node);
        }
        // Optional wraps, in slot order.
        const order = try self.scratch().alloc(usize, entries.len);
        defer self.scratch().free(order);
        for (order, 0..) |*slot, position| slot.* = position;
        std.mem.sort(usize, order, batch.slots, slotLessThan);
        for (order) |position| try self.applyWrappers(&entries[position]);
        // A list's stored element takes or copies its storage —
        // `storedElement`, re-derived from the receiver's shape.
        if (kind.storedArgument()) |stored_position| {
            if (entries.len != 0 and self.heapOf(coreTypeOf(batch.operands[0])) != null and
                self.heapOf(coreTypeOf(batch.operands[0])).? == .list)
            {
                const entry = &entries[stored_position];
                const stored = try self.ownedForStore(
                    entry.register,
                    wrappedType(entry),
                    entry.provenance,
                );
                entry.register = stored.register;
            }
        }
        const count = entries.len;
        const registers = try self.arena().alloc(Register, count);
        for (entries, batch.slots) |entry, slot| registers[slot] = entry.register;
        const emitted = try self.code.emit(
            .{ .intrinsic = .{ .kind = kind, .arguments = registers } },
            called.result,
        );
        // `error("…")` leaves the frame: the releases this frame owes,
        // then the unwind (docs/FAILURE.md).
        if (kind == .raise_error) {
            try self.emitTempReleases(0);
            try self.emitScopeReleases(0);
            _ = try self.code.emit(.unwind, .none);
            return emitted;
        }
        return self.finishFallible(emitted, called, nodes.ofIntrinsic(kind));
    }

    fn slotLessThan(slots: []const u32, left: usize, right: usize) bool {
        return slots[left] < slots[right];
    }

    fn replayConversion(self: *Replay, called: nodes.Expression.Call, produced: Type) Error!Register {
        const operand = try self.replayValue(called.operands.operands[0]);
        if (produced == .str or produced == .bytes) {
            const arguments = try self.arena().alloc(Register, 1);
            arguments[0] = operand;
            return self.code.emit(
                .{ .intrinsic = .{
                    .kind = if (produced == .str) .str_value else .bytes_value,
                    .arguments = arguments,
                } },
                produced,
            );
        }
        return self.code.emit(.{ .convert = operand }, produced);
    }

    /// The two enum text forms — `str(m)` and `Method(n)` — told
    /// apart by the result type (nodes.ResolvedCallee).
    fn replayEnumText(self: *Replay, called: nodes.Expression.Call, index: u32) Error!Register {
        const declared = self.code.enums[index];
        if (called.result == .str) {
            const operand = try self.replayValue(called.operands.operands[0]);
            const first = try self.code.emit(
                .{ .const_str = try self.code.pool.intern(declared.members[0].name) },
                .str,
            );
            const result = self.takeSlot(null, .str, false);
            try self.code.store(result, first);
            if (declared.members.len == 1) return self.code.load(result);
            const enum_type = coreTypeOf(called.operands.operands[0]);
            const held = self.takeSlot(null, enum_type, false);
            try self.code.store(held, operand);
            var frames: std.ArrayList(mir.build.Lowering.Conditional) = .empty;
            defer frames.deinit(self.scratch());
            for (declared.members[1..]) |member| {
                const number = try self.code.emit(.{ .const_integer = member.value }, enum_type);
                const same = try self.code.emit(.{ .binary = .{
                    .op = .equal,
                    .operand_type = enum_type,
                    .left = try self.code.load(held),
                    .right = number,
                } }, .boolean);
                const arms = try self.code.openIf(same, true);
                try self.code.store(result, try self.code.emit(
                    .{ .const_str = try self.code.pool.intern(member.name) },
                    .str,
                ));
                try self.code.elseArm(arms);
                try frames.append(self.scratch(), arms);
            }
            while (frames.pop()) |arms| try self.code.closeIf(arms);
            return self.code.load(result);
        }
        // `Method(n)` — the number in, answering `Method?`.
        const operand = try self.replayValue(called.operands.operands[0]);
        const answer = called.result;
        const of = answer.held().?;
        const backing = of.enumeration.backing.asType();
        const held = self.takeSlot(null, backing, false);
        try self.code.store(held, operand);
        const absent = try self.code.emit(
            .{ .intrinsic = .{ .kind = .none_value, .arguments = &.{} } },
            answer,
        );
        const result = self.takeSlot(null, answer, false);
        try self.code.store(result, absent);
        var frames: std.ArrayList(mir.build.Lowering.Conditional) = .empty;
        defer frames.deinit(self.scratch());
        for (declared.members) |member| {
            const number = try self.code.emit(.{ .const_integer = member.value }, backing);
            const same = try self.code.emit(.{ .binary = .{
                .op = .equal,
                .operand_type = backing,
                .left = try self.code.load(held),
                .right = number,
            } }, .boolean);
            const arms = try self.code.openIf(same, true);
            const found = try self.code.emit(.{ .const_integer = member.value }, of);
            const wrapped = try self.arena().alloc(Register, 1);
            wrapped[0] = found;
            try self.code.store(result, try self.code.emit(
                .{ .intrinsic = .{ .kind = .optional_wrap, .arguments = wrapped } },
                answer,
            ));
            try self.code.elseArm(arms);
            try frames.append(self.scratch(), arms);
        }
        while (frames.pop()) |arms| try self.code.closeIf(arms);
        return self.code.load(result);
    }

    fn replayVariantText(self: *Replay, called: nodes.Expression.Call, index: u32) Error!Register {
        const declared = self.code.variants[index];
        const operand = try self.replayValue(called.operands.operands[0]);
        const first = try self.code.emit(
            .{ .const_str = try self.code.pool.intern(declared.members[0].name) },
            .str,
        );
        const result = self.takeSlot(null, .str, false);
        try self.code.store(result, first);
        if (declared.members.len == 1) return self.code.load(result);
        const value_type = coreTypeOf(called.operands.operands[0]);
        const held = self.takeSlot(null, value_type, false);
        try self.code.store(held, operand);
        var frames: std.ArrayList(mir.build.Lowering.Conditional) = .empty;
        defer frames.deinit(self.scratch());
        for (declared.members[1..], 1..) |member, member_index| {
            const tag = try self.code.emit(
                .{ .variant_tag = .{ .target = try self.code.load(held) } },
                .i64,
            );
            const number = try self.code.emit(.{ .const_integer = @intCast(member_index) }, .i64);
            const same = try self.code.emit(.{ .binary = .{
                .op = .equal,
                .operand_type = .i64,
                .left = tag,
                .right = number,
            } }, .boolean);
            const arms = try self.code.openIf(same, true);
            try self.code.store(result, try self.code.emit(
                .{ .const_str = try self.code.pool.intern(member.name) },
                .str,
            ));
            try self.code.elseArm(arms);
            try frames.append(self.scratch(), arms);
        }
        while (frames.pop()) |arms| try self.code.closeIf(arms);
        return self.code.load(result);
    }

    /// Close a call that can come back errored: the question, the
    /// carry, the branch, the reload — `openFallible`, replayed.
    fn finishFallible(
        self: *Replay,
        call: Register,
        called: nodes.Expression.Call,
        answer: nodes.Provenance,
    ) Error!Register {
        _ = answer;
        if (!called.fallible) return call;
        const failed = try self.code.errored(call);
        const storage = self.ownsStorage(called.result);
        var carried: ?LocalId = null;
        if (called.result != .none) {
            const slot = self.takeSlot(null, called.result, storage);
            try self.code.store(slot, call);
            carried = slot;
        }
        const handler = try self.code.reserveBlock();
        const returned = try self.code.reserveBlock();
        try self.code.branch(failed, handler, returned);
        self.code.switchTo(returned);
        self.opened = .{ .handler = handler, .temps_floor = self.temps.items.len };
        const slot = carried orelse return call;
        const reload = try self.code.load(slot);
        // The carried success value is owned here: its storage is this slot's
        // and its object children are the payload's.  Both must be released by
        // the statement's end unless a place adopts the value — a single-value
        // `let x = try f()` retracts the object park through `takeObjects`, a
        // destructure reads each field out under retain and the park's release
        // nets against it.  Registering only the storage leaked every object a
        // fallible result carried — a tuple's `list`, a struct's fields
        // (docs/MEMORY.md).
        const objects = try self.carriesObjects(called.result);
        if (storage or objects) {
            try self.temps.append(self.scratch(), .{
                .local = slot,
                .register = reload,
                .storage = storage,
                .objects = objects,
                .disownable = false,
            });
        }
        return reload;
    }

    fn replayTry(self: *Replay, attempt: nodes.Expression.TryCall) Error!Register {
        const value = try self.replayValue(attempt.call);
        const opened = self.opened.?;
        self.opened = null;
        std.debug.assert(opened.temps_floor == attempt.temps_floor);
        const resume_at = self.code.current;
        self.code.switchTo(opened.handler);
        try self.emitTempReleasesUpTo(0, opened.temps_floor);
        try self.emitScopeReleases(0);
        _ = try self.code.emit(.unwind, .none);
        self.code.switchTo(resume_at);
        return value;
    }

    fn replayCatch(self: *Replay, caught: nodes.Expression.CatchExpr) Error!Register {
        const value = try self.replayValue(caught.call);
        const opened = self.opened.?;
        self.opened = null;
        std.debug.assert(opened.temps_floor == caught.temps_floor);

        if (caught.result == .none) {
            const merge = try self.code.reserveBlock();
            try self.code.jump(merge);
            self.code.switchTo(opened.handler);
            _ = try self.code.emit(
                .{ .intrinsic = .{ .kind = .forget, .arguments = &.{} } },
                .none,
            );
            const floor = self.temps.items.len;
            switch (caught.fallback) {
                .leaving => |leaving| _ = try self.replayLeaving(leaving),
                .value => |fallback| _ = try self.replayValue(fallback),
            }
            try self.flushTemps(floor);
            try self.code.jump(merge);
            self.code.switchTo(merge);
            return value;
        }

        const result = self.takeSlot(null, caught.result, false);
        const merge = try self.code.reserveBlock();
        try self.code.store(result, value);
        try self.code.jump(merge);
        self.code.switchTo(opened.handler);
        _ = try self.code.emit(
            .{ .intrinsic = .{ .kind = .forget, .arguments = &.{} } },
            .none,
        );
        switch (caught.fallback) {
            .leaving => |leaving| _ = try self.replayLeaving(leaving),
            .value => |fallback| {
                const landed = try self.replayValue(fallback);
                try self.code.store(result, landed);
            },
        }
        try self.code.jump(merge);
        self.code.switchTo(merge);
        return self.code.load(result);
    }

    // -- construction --------------------------------------------------------

    fn replayStructMake(self: *Replay, built: nodes.Expression.StructMake) Error!Register {
        const registers = try self.replayConstructionBatch(built.operands, structFieldTypesOf(self, built.layout));
        return self.code.emit(
            .{ .struct_make = .{ .layout = built.layout, .fields = registers } },
            built.result,
        );
    }

    fn structFieldTypesOf(self: *Replay, layout: u32) []const types.StructField {
        return self.code.structs[layout].fields;
    }

    fn replayVariantMake(self: *Replay, built: nodes.Expression.VariantMake) Error!Register {
        const member = self.code.variants[built.variant].members[built.member];
        const registers = try self.replayConstructionBatch(built.operands, member.fields);
        return self.code.emit(.{ .variant_make = .{
            .variant = built.variant,
            .member = built.member,
            .fields = registers,
        } }, built.result);
    }

    /// The named-field construction batch: written operands' cores,
    /// reloads, then per written operand *interleaved* wrappers and
    /// field store, then defaults each with its own store — the shape
    /// `lowerConstruct` emits.
    fn replayConstructionBatch(
        self: *Replay,
        batch: nodes.OperandBatch,
        fields: []const types.StructField,
    ) Error![]Register {
        const entries = try self.replayWrittenOperands(batch);
        defer self.scratch().free(entries);
        const registers = try self.arena().alloc(Register, fields.len);
        for (entries[0..batch.written], batch.slots[0..batch.written], 0..) |*entry, slot, position| {
            try self.applyWrappers(entry);
            if (fields[slot].weak) {
                registers[slot] = entry.register;
            } else if (batch.move.len != 0 and batch.move[position]) {
                registers[slot] = entry.register;
            } else {
                const stored = try self.ownedForStore(
                    entry.register,
                    fields[slot].field_type,
                    entry.provenance,
                );
                registers[slot] = stored.register;
            }
        }
        for (batch.operands[batch.written..], batch.slots[batch.written..], batch.written..) |node, slot, position| {
            try self.replayDefaultEntry(entries, position, node);
            if (fields[slot].weak) {
                registers[slot] = entries[position].register;
            } else {
                const stored = try self.ownedForStore(
                    entries[position].register,
                    fields[slot].field_type,
                    entries[position].provenance,
                );
                registers[slot] = stored.register;
            }
        }
        return registers;
    }

    fn replayListLiteral(self: *Replay, literal: nodes.Expression.ListLiteral) Error!Register {
        const entries = try self.replayOperandRun(literal.elements);
        defer self.scratch().free(entries);
        for (entries) |*entry| try self.applyWrappers(entry);
        const shape = self.heapOf(literal.result).?;
        const builds_array = shape == .array;
        var dims: []Register = &.{};
        if (builds_array) {
            dims = try self.arena().alloc(Register, 1);
            dims[0] = try self.code.emit(.{ .const_integer = @intCast(literal.elements.len) }, .i64);
        }
        const object = try self.code.emit(
            .{ .heap_new = .{ .heap = literal.result.heap, .dims = dims } },
            literal.result,
        );
        const element_type = switch (shape) {
            .list => |element| element,
            .array => |dimensions| dimensions.element,
            else => unreachable, // a bracket literal lands as a list or a rank-1 array
        };
        for (entries, 0..) |entry, index| {
            if (builds_array) {
                const arguments = try self.arena().alloc(Register, 3);
                arguments[0] = object;
                arguments[1] = try self.code.emit(.{ .const_integer = @intCast(index) }, .i64);
                arguments[2] = (try self.ownedForStore(
                    entry.register,
                    element_type,
                    entry.provenance,
                )).register;
                _ = try self.code.emit(.{ .intrinsic = .{ .kind = .index_set, .arguments = arguments } }, .none);
            } else {
                const arguments = try self.arena().alloc(Register, 2);
                arguments[0] = object;
                arguments[1] = (try self.ownedForStore(
                    entry.register,
                    element_type,
                    entry.provenance,
                )).register;
                _ = try self.code.emit(.{ .intrinsic = .{ .kind = .append_value, .arguments = arguments } }, .none);
            }
        }
        return object;
    }

    fn replayMapLiteral(self: *Replay, literal: nodes.Expression.MapLiteral) Error!Register {
        // Keys and values are one interleaved operand run.
        const run = try self.scratch().alloc(nodes.Operand, literal.entries.len * 2);
        defer self.scratch().free(run);
        for (literal.entries, 0..) |entry, index| {
            run[index * 2] = entry.key;
            run[index * 2 + 1] = entry.value;
        }
        const entries = try self.replayOperandRun(run);
        defer self.scratch().free(entries);
        for (entries) |*entry| try self.applyWrappers(entry);
        const shape = self.heapOf(literal.result).?;
        const value_type = shape.map.value;
        const map = try self.code.emit(
            .{ .heap_new = .{ .heap = literal.result.heap, .dims = &.{} } },
            literal.result,
        );
        for (0..literal.entries.len) |index| {
            const arguments = try self.arena().alloc(Register, 3);
            arguments[0] = map;
            arguments[1] = entries[index * 2].register;
            arguments[2] = (try self.ownedForStore(
                entries[index * 2 + 1].register,
                value_type,
                entries[index * 2 + 1].provenance,
            )).register;
            _ = try self.code.emit(.{ .intrinsic = .{ .kind = .index_set, .arguments = arguments } }, .none);
        }
        return map;
    }

    fn replaySlice(self: *Replay, sliced: nodes.Expression.Slice) Error!Register {
        var count: usize = 1;
        if (sliced.start != null) count += 1;
        if (sliced.stop != null) count += 1;
        const run = try self.scratch().alloc(nodes.Operand, count);
        defer self.scratch().free(run);
        run[0] = sliced.target;
        var at: usize = 1;
        if (sliced.start) |bound| {
            run[at] = bound;
            at += 1;
        }
        if (sliced.stop) |bound| run[at] = bound;
        const entries = try self.replayOperandRun(run);
        defer self.scratch().free(entries);
        for (entries[1..]) |*entry| try self.applyWrappers(entry);
        var next: usize = 1;
        var start: Register = undefined;
        if (sliced.start != null) {
            start = entries[next].register;
            next += 1;
        } else {
            start = try self.code.emit(.{ .const_integer = 0 }, .i64);
        }
        var stop: Register = undefined;
        if (sliced.stop != null) {
            stop = entries[next].register;
        } else {
            const whole = try self.arena().alloc(Register, 1);
            whole[0] = entries[0].register;
            stop = try self.code.emit(.{ .intrinsic = .{ .kind = .len, .arguments = whole } }, .i64);
        }
        const arguments = try self.arena().alloc(Register, 3);
        arguments[0] = entries[0].register;
        arguments[1] = start;
        arguments[2] = stop;
        const kind: mir.Intrinsic = if (sliced.result == .str or sliced.result == .bytes) .string_slice else .list_slice;
        return self.code.emit(
            .{ .intrinsic = .{ .kind = kind, .arguments = arguments } },
            sliced.result,
        );
    }

    fn replayNewObject(self: *Replay, made: nodes.Expression.NewObject) Error!Register {
        const entries = try self.replayOperandRun(made.operands);
        defer self.scratch().free(entries);
        for (entries) |*entry| try self.applyWrappers(entry);
        const dims = try self.arena().alloc(Register, entries.len);
        for (entries, dims) |entry, *dim| dim.* = entry.register;
        return self.code.emit(
            .{ .heap_new = .{ .heap = made.heap_type, .dims = dims } },
            made.result,
        );
    }

    fn replayIndexGet(self: *Replay, read: nodes.Expression.IndexGet) Error!Register {
        const run = try self.scratch().alloc(nodes.Operand, read.indices.len + 1);
        defer self.scratch().free(run);
        run[0] = read.target;
        @memcpy(run[1..], read.indices);
        const entries = try self.replayOperandRun(run);
        defer self.scratch().free(entries);
        for (entries[1..]) |*entry| try self.applyWrappers(entry);
        const arguments = try self.arena().alloc(Register, entries.len);
        for (entries, arguments) |entry, *slot| slot.* = entry.register;
        return self.code.emit(
            .{ .intrinsic = .{ .kind = .index_get, .arguments = arguments } },
            read.result,
        );
    }

    fn replaySpawn(self: *Replay, worker: nodes.Expression.Spawn) Error!Register {
        const called = worker.call.call;
        const index = called.callee.function;
        const info = self.deps.functions[index];
        const batch = called.operands;
        const entries = try self.replayWrittenOperands(batch);
        defer self.scratch().free(entries);
        for (entries[0..batch.written]) |*entry| try self.applyWrappers(entry);
        for (batch.operands[batch.written..], batch.written..) |node, position| {
            try self.replayDefaultEntry(entries, position, node);
        }
        const registers = try self.arena().alloc(Register, info.parameter_types.len);
        for (entries, batch.slots) |entry, slot| registers[slot] = entry.register;
        return self.code.emit(
            .{ .spawn = .{ .function = index, .arguments = registers } },
            worker.result,
        );
    }

    // -- constants ----------------------------------------------------------

    const Materialized = struct { register: Register, provenance: nodes.Provenance };

    /// `emitConstantValue`, replayed: a folded constant materializes
    /// in whatever shape its value takes.
    fn materializeConstant(self: *Replay, value: context.ConstantValue, value_type: Type) Error!Materialized {
        if (value_type == .optional and value != .absent) {
            const payload = try self.materializeConstant(value, value_type.optional.asType());
            const arguments = try self.arena().alloc(Register, 1);
            arguments[0] = payload.register;
            return .{
                .register = try self.code.emit(
                    .{ .intrinsic = .{ .kind = .optional_wrap, .arguments = arguments } },
                    value_type,
                ),
                .provenance = .plain,
            };
        }
        return switch (value) {
            .integer => |folded| .{
                .register = try self.code.emit(.{ .const_integer = folded }, value_type),
                .provenance = .plain,
            },
            .float => |folded| .{
                .register = try self.code.emit(.{ .const_float = folded }, value_type),
                .provenance = .plain,
            },
            .boolean => |folded| .{
                .register = try self.code.emit(.{ .const_boolean = folded }, .boolean),
                .provenance = .plain,
            },
            .str => |folded| .{
                .register = try self.code.emit(
                    .{ .const_str = try self.code.pool.intern(folded) },
                    value_type,
                ),
                .provenance = .plain,
            },
            .strukt => |folded| built: {
                const layout = self.code.structs[folded.layout];
                const fields = try self.arena().alloc(Register, folded.fields.len);
                for (folded.fields, layout.fields, fields) |field, field_layout, *slot| {
                    const filled = try self.materializeConstant(field, field_layout.field_type);
                    slot.* = (try self.ownedForStore(
                        filled.register,
                        field_layout.field_type,
                        filled.provenance,
                    )).register;
                }
                break :built .{
                    .register = try self.code.emit(
                        .{ .struct_make = .{ .layout = folded.layout, .fields = fields } },
                        value_type,
                    ),
                    .provenance = .fresh,
                };
            },
            .container => |row| .{
                .register = try self.code.emit(.{ .const_container = row }, value_type),
                .provenance = .plain,
            },
            .absent => .{
                .register = try self.code.zeroOf(value_type),
                .provenance = nodes.zeroOf(value_type),
            },
        };
    }

    // -- statements ----------------------------------------------------------

    fn replayBlock(self: *Replay, block: nodes.Block) Error!void {
        try self.replayBlockParts(block.statements, block.releases);
    }

    fn replayBlockParts(
        self: *Replay,
        statements: []const nodes.Statement,
        releases: []const nodes.Release,
    ) Error!void {
        try self.pushScope();
        for (statements) |*statement| {
            const floor = self.temps.items.len;
            try self.replayStatement(statement);
            try self.flushTemps(floor);
        }
        // The recorded releases are the scope's own, in emission order:
        // the reference first, then the storage, as `emitScopeReleases`.
        for (releases) |release| {
            if (release.objects) try self.code.releaseObject(release.local);
            try self.code.release(release.local, release.storage);
        }
        self.popScope();
    }

    fn replayStatement(self: *Replay, statement: *const nodes.Statement) Error!void {
        // Statement granularity is the trap-location contract
        // (`lowerStatement`), and a guarded attempt re-stamps inside
        // its wrapper exactly as the fused walk does.
        self.code.origin = @intCast(statement.span().start);
        switch (statement.*) {
            .declare => |declared| try self.replayDeclare(declared),
            .destructure => |bind| try self.replayDestructure(bind),
            .assign => |assign| try self.replayAssign(assign),
            .assign_many => |assign| try self.replayAssignMany(assign),
            .compound_assign => |assign| try self.replayCompoundAssign(assign),
            .expression => |expression| _ = try self.replayValue(expression.value),
            .if_else => |conditional| try self.replayIfElse(conditional),
            .while_loop => |loop| try self.replayWhile(loop),
            .for_range => |loop| try self.replayForRange(loop),
            .for_in => |loop| try self.replayForIn(loop),
            .break_ => |broke| try self.replayBreakContinue(broke.unwind, broke.temps_floor, true),
            .continue_ => |continued| try self.replayBreakContinue(continued.unwind, continued.temps_floor, false),
            .return_ => |returned| try self.replayReturn(returned),
            .guarded => |guarded| try self.replayGuarded(guarded),
            .match => |matched| try self.replayMatch(matched),
            .block => |block| try self.replayBlock(block),
        }
    }

    fn replayDeclare(self: *Replay, declared: nodes.Statement.Declare) Error!void {
        const row = self.body.locals[declared.local];
        if (declared.value) |value| {
            const register = try self.replayValue(value);
            const local = self.takeRecordedSlot(declared.local);
            switch (declared.ownership) {
                .normal => {
                    try self.storeOwned(local, register, row.local_type, nodes.provenance(value), declared.store);
                    try self.noteOwned(local);
                },
                .transfer => {
                    const stored = try self.ownedForStore(register, row.local_type, nodes.provenance(value));
                    std.debug.assert(stored.kind == declared.store);
                    try self.code.store(local, stored.register);
                },
                .borrow => {
                    std.debug.assert(declared.store == .plain);
                    try self.code.store(local, register);
                },
            }
            return;
        }
        // The zero fill of a late declaration, re-derived from the
        // slot's type (S40).
        const zero = try self.code.zeroOf(row.local_type);
        const local = self.takeRecordedSlot(declared.local);
        switch (declared.ownership) {
            .normal => {
                try self.storeOwned(local, zero, row.local_type, nodes.zeroOf(row.local_type), declared.store);
                try self.noteOwned(local);
            },
            .transfer => {
                const stored = try self.ownedForStore(zero, row.local_type, nodes.zeroOf(row.local_type));
                std.debug.assert(stored.kind == declared.store);
                try self.code.store(local, stored.register);
            },
            .borrow => {
                std.debug.assert(declared.store == .plain);
                try self.code.store(local, zero);
            },
        }
    }

    /// Enter a declared binding in its scope's owned list when it holds
    /// storage or a reference, so the scope's end gives its bytes back
    /// (`drop_storage`) and drops its reference (`release`).
    fn noteOwned(self: *Replay, local: LocalId) Error!void {
        if (self.code.localIsWeak(local)) return;
        const owns_storage = self.code.localOwnsStorage(local);
        const owns_objects = try self.carriesObjects(self.code.localType(local));
        if (!owns_storage and !owns_objects) return;
        try self.currentScope().owned.append(self.scratch(), .{
            .local = local,
            .storage = owns_storage,
            .objects = owns_objects,
        });
    }

    /// Enter a loop name in its scope's owned list as a storage-only
    /// borrow.  A `for` name copies its element's *shell* (`ownStorage`
    /// in `bindLoopName`) but shares that element's heap children with
    /// the container it iterates — the getter answers a borrow and the
    /// binding never retains it.  So the name owns its bytes and borrows
    /// its objects: the scope's end gives the shell back (`drop_storage`)
    /// and must never release children the container still owns, which
    /// would corrupt the container from under a later read.  An escape —
    /// `append(entry)`, `return entry` — retains through its own store,
    /// as any borrow does (docs/MEMORY.md).
    fn noteLoopName(self: *Replay, local: LocalId) Error!void {
        if (!self.code.localOwnsStorage(local)) return;
        try self.currentScope().owned.append(self.scratch(), .{
            .local = local,
            .storage = true,
            .objects = false,
        });
    }

    fn replayDestructure(self: *Replay, bind: nodes.Statement.Destructure) Error!void {
        const register = try self.replayValue(bind.value);
        const shape_type = bind.value.result();
        const layout = self.code.structs[shape_type.strukt];
        for (bind.locals, bind.stores, 0..) |expected, recorded, position| {
            const field = layout.fields[position];
            const held = try self.code.emit(.{ .struct_get = .{
                .target = register,
                .layout = shape_type.strukt,
                .field = @intCast(position),
            } }, field.field_type);
            const local = self.takeRecordedSlot(expected);
            const ownership = if (bind.ownerships.len == 0) .normal else bind.ownerships[position];
            switch (ownership) {
                .normal => {
                    try self.storeOwned(local, held, field.field_type, .view, recorded);
                    try self.noteOwned(local);
                },
                .transfer => {
                    const stored = try self.ownedForStore(held, field.field_type, .view);
                    std.debug.assert(stored.kind == recorded);
                    try self.code.store(local, stored.register);
                },
                .borrow => {
                    std.debug.assert(recorded == .plain);
                    try self.code.store(local, held);
                },
            }
        }
    }

    fn replayAssignMany(self: *Replay, assign: nodes.Statement.AssignMany) Error!void {
        const register = try self.replayValue(assign.value);
        const shape_type = assign.value.result();
        const layout = self.code.structs[shape_type.strukt];
        const prepared = try self.scratch().alloc(Register, assign.targets.len);
        defer self.scratch().free(prepared);
        for (assign.targets, assign.stores, 0..) |target, recorded, position| {
            const field = layout.fields[position];
            const target_type = self.code.localType(target);
            const held = try self.code.emit(.{ .struct_get = .{
                .target = register,
                .layout = shape_type.strukt,
                .field = @intCast(position),
            } }, field.field_type);
            // The fit into the target's type, re-derived: either exact or
            // one optional wrap. Numeric representation never changes here.
            var fitted = held;
            var fitted_type = field.field_type;
            if (!fitted_type.eql(target_type)) {
                const payload = target_type.held().?;
                std.debug.assert(fitted_type.eql(payload));
                const arguments = try self.arena().alloc(Register, 1);
                arguments[0] = fitted;
                fitted = try self.code.emit(
                    .{ .intrinsic = .{ .kind = .optional_wrap, .arguments = arguments } },
                    target_type,
                );
                fitted_type = target_type;
            }
            const cell = if (assign.cells.len == 0) null else assign.cells[position];
            const weak_cell = if (cell) |place|
                self.code.structs[place.layout].fields[place.field].weak
            else
                false;
            if (weak_cell) {
                std.debug.assert(recorded == .plain);
                prepared[position] = fitted;
            } else if (self.code.localOwnsStorage(target) or cell != null) {
                const stored = try self.ownedForStore(fitted, target_type, .view);
                std.debug.assert(stored.kind == recorded);
                prepared[position] = stored.register;
            } else {
                // A reference read out of the returned shape is a borrow of
                // it; the target that keeps it counts it (the shape is
                // released when the statement's temporary goes).
                try self.keepReference(fitted, target_type, .view);
                std.debug.assert(recorded == .plain);
                prepared[position] = fitted;
            }
        }
        // The new values were prepared (and any borrow retained) above, so
        // each target's old reference and old storage can go now, before
        // the new value replaces it — the object first, as everywhere else.
        for (assign.targets, prepared, 0..) |target, staged, position| {
            if (assign.cells.len != 0) {
                if (assign.cells[position]) |cell| {
                    const base = try self.code.load(cell.base);
                    const field = self.code.structs[cell.layout].fields[cell.field];
                    _ = try self.code.emit(
                        if (field.weak) .{ .weak_struct_set = .{
                            .target = base,
                            .layout = cell.layout,
                            .field = cell.field,
                            .value = staged,
                        } } else .{ .struct_set = .{
                            .target = base,
                            .layout = cell.layout,
                            .field = cell.field,
                            .value = staged,
                        } },
                        .none,
                    );
                    continue;
                }
            }
            if (try self.carriesObjects(self.code.localType(target))) try self.code.releaseObject(target);
            try self.code.release(target, self.code.localOwnsStorage(target));
            try self.code.store(target, staged);
        }
    }

    fn replayAssign(self: *Replay, assign: nodes.Statement.Assign) Error!void {
        switch (assign.place) {
            .local => |local| try self.replayAssignLocal(local, assign.value, assign.store, null),
            .field => |field| try self.replayAssignField(field, assign.value, assign.store, null),
            .foreign => |place| try self.replayAssignForeign(place, assign.value, assign.store, null),
            .index => |index| try self.replayAssignIndex(
                index,
                assign.value,
                assign.store,
                null,
                assign.value_copied,
            ),
            .chain => |chain| try self.replayAssignChain(
                chain,
                assign.value,
                assign.store,
                null,
                assign.value_copied,
            ),
        }
    }

    fn replayCompoundAssign(self: *Replay, assign: nodes.Statement.CompoundAssign) Error!void {
        switch (assign.place) {
            .local => |local| try self.replayAssignLocal(local, assign.value, assign.store, assign.op),
            .field => |field| try self.replayAssignField(field, assign.value, assign.store, assign.op),
            .foreign => |place| try self.replayAssignForeign(place, assign.value, assign.store, assign.op),
            .index => |index| try self.replayAssignIndex(
                index,
                assign.value,
                assign.store,
                assign.op,
                assign.value_copied,
            ),
            .chain => |chain| try self.replayAssignChain(
                chain,
                assign.value,
                assign.store,
                assign.op,
                assign.value_copied,
            ),
        }
    }

    /// The read-combine of `place OP= value`, re-derived from the place's
    /// type (`compoundCombine`). Both sides already have that exact type.
    fn replayCombine(
        self: *Replay,
        op: nodes.BinaryOp,
        current: Register,
        place_type: Type,
        value: Register,
    ) Error!struct { register: Register, provenance: nodes.Provenance } {
        const combined = try self.code.emit(.{ .binary = .{
            .op = op,
            .operand_type = place_type,
            .left = current,
            .right = value,
        } }, place_type);
        const text_concat = op == .add and (place_type == .str or place_type == .bytes);
        if (text_concat) try self.parkDerivedStorage(combined, place_type);
        return .{ .register = combined, .provenance = if (text_concat) .fresh else .plain };
    }

    /// A store into a C global (docs/FFI.md): the value — combined
    /// with the current word for the compound form — moves through
    /// `foreign_set` whole.  The Globals vocabulary owns no storage,
    /// so there is nothing to take, copy, retain or release.
    fn replayAssignForeign(
        self: *Replay,
        place: nodes.Place.Foreign,
        value: nodes.NodeRef,
        recorded: nodes.StoreKind,
        compound: ?nodes.BinaryOp,
    ) Error!void {
        const register = try self.replayValue(value);
        std.debug.assert(recorded == .plain);
        var stored = register;
        if (compound) |op| {
            const current = try self.code.emit(.{ .foreign_get = place.variable }, place.value_type);
            const combined = try self.replayCombine(op, current, place.value_type, register);
            stored = combined.register;
        }
        _ = try self.code.emit(
            .{ .foreign_set = .{ .variable = place.variable, .value = stored } },
            .none,
        );
    }

    fn replayAssignLocal(
        self: *Replay,
        local: LocalId,
        value: nodes.NodeRef,
        recorded: nodes.StoreKind,
        compound: ?nodes.BinaryOp,
    ) Error!void {
        const register = try self.replayValue(value);
        const local_type = self.code.localType(local);
        if (self.code.localIsWeak(local)) {
            std.debug.assert(compound == null);
            std.debug.assert(recorded == .plain);
            try self.code.store(local, register);
            return;
        }
        var stored = register;
        var provenance = nodes.provenance(value);
        if (compound) |op| {
            // A compound place that is optional was proven present, so
            // the read unwraps and the write-back wraps (re-derived).
            const narrowed_place = local_type == .optional;
            const combine_type = if (narrowed_place) local_type.held().? else local_type;
            var current = try self.code.load(local);
            if (narrowed_place) {
                const unwrap = try self.arena().alloc(Register, 1);
                unwrap[0] = current;
                current = try self.code.emit(
                    .{ .intrinsic = .{ .kind = .optional_unwrap, .arguments = unwrap } },
                    combine_type,
                );
            }
            const combined = try self.replayCombine(op, current, combine_type, register);
            stored = combined.register;
            provenance = combined.provenance;
            if (narrowed_place) {
                const arguments = try self.arena().alloc(Register, 1);
                arguments[0] = stored;
                stored = try self.code.emit(
                    .{ .intrinsic = .{ .kind = .optional_wrap, .arguments = arguments } },
                    local_type,
                );
                provenance = .plain;
            }
        }
        var store = stored;
        const owns_storage = self.code.localOwnsStorage(local);
        if (owns_storage) {
            const owned = try self.ownedForStore(stored, local_type, provenance);
            std.debug.assert(owned.kind == recorded);
            store = owned.register;
        } else {
            // Retain a borrowed reference the slot will now hold, before
            // the old one below is let go — so `x = x` nets no change.
            try self.keepReference(stored, local_type, provenance);
            std.debug.assert(recorded == .plain);
        }
        // The slot's old reference and its old storage both go now that a
        // new value replaces them; releasing the old object first would
        // strand a self-assignment, so the retain above comes first.
        if (try self.carriesObjects(local_type)) try self.code.releaseObject(local);
        try self.code.release(local, owns_storage);
        try self.code.store(local, store);
    }

    fn replayAssignField(
        self: *Replay,
        place: nodes.Place.Field,
        value: nodes.NodeRef,
        recorded: nodes.StoreKind,
        compound: ?nodes.BinaryOp,
    ) Error!void {
        const register = try self.replayValue(value);
        const local_type = self.code.localType(place.base);
        const layout = self.code.structs[place.layout];
        const field = layout.fields[place.field];
        const field_type = field.field_type;
        const current = try self.code.load(place.base);
        var stored = register;
        var provenance = nodes.provenance(value);
        if (compound) |op| {
            var old_value = try self.code.emit(.{ .struct_get = .{
                .target = current,
                .layout = place.layout,
                .field = place.field,
            } }, field_type);
            const combine_type = if (place.narrowed) field_type.held().? else field_type;
            if (place.narrowed) {
                const unwrap = try self.arena().alloc(Register, 1);
                unwrap[0] = old_value;
                old_value = try self.code.emit(
                    .{ .intrinsic = .{ .kind = .optional_unwrap, .arguments = unwrap } },
                    combine_type,
                );
            }
            const combined = try self.replayCombine(op, old_value, combine_type, register);
            stored = combined.register;
            provenance = combined.provenance;
            if (place.narrowed) {
                const arguments = try self.arena().alloc(Register, 1);
                arguments[0] = stored;
                stored = try self.code.emit(
                    .{ .intrinsic = .{ .kind = .optional_wrap, .arguments = arguments } },
                    field_type,
                );
                provenance = .plain;
            }
        }
        const stored_field = if (field.weak)
            StoredValue{ .register = stored, .kind = .plain }
        else
            try self.ownedForStore(stored, field_type, provenance);
        std.debug.assert(stored_field.kind == recorded);
        const updated = try self.code.emit(
            if (field.weak) .{ .weak_struct_set = .{
                .target = current,
                .layout = place.layout,
                .field = place.field,
                .value = stored_field.register,
            } } else .{ .struct_set = .{
                .target = current,
                .layout = place.layout,
                .field = place.field,
                .value = stored_field.register,
            } },
            if (layout.reference) .none else local_type,
        );
        if (layout.reference) return;
        try self.code.release(place.base, self.code.localOwnsStorage(place.base));
        try self.code.store(place.base, updated);
    }

    fn replayAssignIndex(
        self: *Replay,
        place: nodes.Place.Index,
        value: nodes.NodeRef,
        recorded: nodes.StoreKind,
        compound: ?nodes.BinaryOp,
        value_copied: bool,
    ) Error!void {
        // One batch: the base, the subscripts, the value.
        const run = try self.scratch().alloc(nodes.Operand, place.indices.len + 2);
        defer self.scratch().free(run);
        run[0] = place.base;
        @memcpy(run[1 .. 1 + place.indices.len], place.indices);
        run[run.len - 1] = .{ .node = value, .copied = value_copied };
        const entries = try self.replayOperandRun(run);
        defer self.scratch().free(entries);
        // Optional wrappers for subscripts and the stored value.
        for (entries[1..]) |*entry| try self.applyWrappers(entry);
        const object = &entries[0];
        const value_entry = &entries[entries.len - 1];
        const element_type = wrappedType(value_entry);
        var stored = value_entry.register;
        var provenance = nodes.provenance(value);
        if (compound) |op| {
            const shape = self.heapOf(coreTypeOf(place.base.node)).?;
            const subscripts = try self.arena().alloc(Register, place.indices.len);
            for (entries[1 .. 1 + place.indices.len], subscripts) |entry, *slot| slot.* = entry.register;
            const current = if (shape == .map) place_read: {
                const arguments = try self.arena().alloc(Register, 3);
                arguments[0] = object.register;
                arguments[1] = subscripts[0];
                arguments[2] = try self.code.zeroOf(element_type);
                break :place_read try self.code.emit(
                    .{ .intrinsic = .{ .kind = .map_place, .arguments = arguments } },
                    element_type,
                );
            } else plain_read: {
                const arguments = try self.arena().alloc(Register, subscripts.len + 1);
                arguments[0] = object.register;
                @memcpy(arguments[1..], subscripts);
                break :plain_read try self.code.emit(
                    .{ .intrinsic = .{ .kind = .index_get, .arguments = arguments } },
                    element_type,
                );
            };
            const combined = try self.replayCombine(op, current, element_type, stored);
            stored = combined.register;
            provenance = combined.provenance;
        }
        const arguments = try self.arena().alloc(Register, entries.len);
        for (entries, arguments) |entry, *slot| slot.* = entry.register;
        const owned = try self.ownedForStore(stored, element_type, provenance);
        std.debug.assert(owned.kind == recorded);
        arguments[arguments.len - 1] = owned.register;
        _ = try self.code.emit(.{ .intrinsic = .{ .kind = .index_set, .arguments = arguments } }, .none);
    }

    fn replayAssignChain(
        self: *Replay,
        chain: nodes.Place.Chain,
        value: nodes.NodeRef,
        recorded: nodes.StoreKind,
        compound: ?nodes.BinaryOp,
        value_copied: bool,
    ) Error!void {
        // One batch: every index step's subscripts, then the value.
        var count: usize = 1;
        for (chain.steps) |step| {
            if (step == .index) count += step.index.len;
        }
        const run = try self.scratch().alloc(nodes.Operand, count);
        defer self.scratch().free(run);
        var fill: usize = 0;
        for (chain.steps) |step| {
            if (step != .index) continue;
            for (step.index) |subscript| {
                run[fill] = subscript;
                fill += 1;
            }
        }
        run[run.len - 1] = .{ .node = value, .copied = value_copied };
        const entries = try self.replayOperandRun(run);
        defer self.scratch().free(entries);

        // The descent, reading each step once.
        const accessors = try self.arena().alloc(mir.build.Lowering.Step, chain.steps.len);
        var current = try self.code.load(chain.root);
        var current_type = self.code.localType(chain.root);
        var next_operand: usize = 0;
        for (chain.steps, accessors) |step, *accessor| {
            switch (step) {
                .field => |field| {
                    const layout = self.code.structs[field.layout];
                    accessor.* = .{ .field = .{
                        .parent = current,
                        .layout = field.layout,
                        .field_index = field.field,
                        .weak = field.weak,
                    } };
                    // A weak leaf is a write-only landing here. Semantics
                    // rejects traversing it and compound assignment, so
                    // upgrading it merely to overwrite it would create an
                    // owned snapshot with no reader.
                    if (!field.weak) {
                        current = try self.code.emit(.{ .struct_get = .{
                            .target = current,
                            .layout = field.layout,
                            .field = field.field,
                        } }, layout.fields[field.field].field_type);
                    }
                    current_type = layout.fields[field.field].field_type;
                },
                .index => |subscript_operands| {
                    // Optional subscript wrappers run here, inside the descent.
                    const lowered = entries[next_operand .. next_operand + subscript_operands.len];
                    next_operand += subscript_operands.len;
                    for (lowered) |*entry| try self.applyWrappers(entry);
                    const shape = self.heapOf(current_type).?;
                    const element_type = switch (shape) {
                        .list => |element| element,
                        .array => |dimensions| dimensions.element,
                        .map => |pair| pair.value,
                        else => unreachable, // only indexable steps descend
                    };
                    const subscripts = try self.arena().alloc(Register, lowered.len);
                    for (lowered, subscripts) |entry, *slot| slot.* = entry.register;
                    accessor.* = .{ .index = .{ .object = current, .subscripts = subscripts } };
                    const read_arguments = try self.arena().alloc(Register, lowered.len + 1);
                    read_arguments[0] = current;
                    @memcpy(read_arguments[1..], subscripts);
                    current = try self.code.emit(
                        .{ .intrinsic = .{ .kind = .index_get, .arguments = read_arguments } },
                        element_type,
                    );
                    current_type = element_type;
                },
            }
        }
        const value_entry = &entries[entries.len - 1];
        try self.applyWrappers(value_entry);
        var stored = value_entry.register;
        var provenance = nodes.provenance(value);
        if (compound) |op| {
            const combined = try self.replayCombine(op, current, current_type, stored);
            stored = combined.register;
            provenance = combined.provenance;
        }
        const leaf_is_weak = chain.steps.len > 0 and
            chain.steps[chain.steps.len - 1] == .field and
            chain.steps[chain.steps.len - 1].field.weak;
        const leaf = if (leaf_is_weak)
            StoredValue{ .register = stored, .kind = .plain }
        else
            try self.ownedForStore(stored, current_type, provenance);
        std.debug.assert(leaf.kind == recorded);
        try self.code.rebuild(chain.root, accessors, leaf.register);
    }

    // -- control flow --------------------------------------------------------

    fn replayIfElse(self: *Replay, conditional: nodes.Statement.IfElse) Error!void {
        const floor = self.temps.items.len;
        const condition = try self.replayValue(conditional.condition);
        try self.flushTemps(floor);
        const arms = try self.code.openIf(condition, conditional.else_body != null);
        try self.replayBlock(conditional.then_body);
        if (conditional.else_body) |else_body| {
            try self.code.elseArm(arms);
            try self.replayBlock(else_body);
        }
        try self.code.closeIf(arms);
    }

    fn replayWhile(self: *Replay, loop: nodes.Statement.WhileLoop) Error!void {
        const shape = try self.code.openWhile();
        try self.loops.append(self.scratch(), .{
            .continue_block = shape.header,
            .exit_block = shape.exit,
            .scope_depth = self.scopes.items.len,
            .temps_depth = self.temps.items.len,
        });
        const floor = self.temps.items.len;
        const condition = try self.replayValue(loop.condition);
        try self.flushTemps(floor);
        try self.code.enterWhileBody(shape, condition);
        try self.replayBlock(loop.body);
        _ = self.loops.pop();
        try self.code.closeWhile(shape);
    }

    fn replayForRange(self: *Replay, loop: nodes.Statement.ForRange) Error!void {
        const floor = self.temps.items.len;
        var entries: [2]BatchEntry = .{ try self.peel(loop.start), try self.peel(loop.stop) };
        // The bounds are one two-operand run: the first crosses a
        // split in the second (bounds are `i64`s, so the borrow copy
        // never applies).
        self.markSpills(entries[0..], &.{});
        try self.replayBatchOperand(&entries[0], false);
        const opened_in = self.code.current;
        try self.replayBatchOperand(&entries[1], false);
        self.assertSplitCarried(entries[0..1], opened_in);
        try self.reloadSpills(entries[0..]);
        try self.applyWrappers(&entries[0]);
        try self.applyWrappers(&entries[1]);
        try self.flushTemps(floor);

        try self.pushScope();
        const counter = self.takeRecordedSlot(loop.counter);
        // The hidden limit slot — the bound is evaluated once —
        // through the recorded local table.
        const limit = self.takeSlot(null, .i64, false);
        try self.code.store(counter, entries[0].register);
        try self.code.store(limit, entries[1].register);
        const header = try self.code.reserveBlock();
        const body = try self.code.reserveBlock();
        const step = try self.code.reserveBlock();
        const exit = try self.code.reserveBlock();
        try self.code.jump(header);
        self.code.switchTo(header);
        const at = try self.code.load(counter);
        const bound = try self.code.load(limit);
        const keep_going = try self.code.emit(.{ .binary = .{
            .op = .less,
            .operand_type = .i64,
            .left = at,
            .right = bound,
        } }, .boolean);
        try self.code.branch(keep_going, body, exit);
        self.code.switchTo(body);

        try self.loops.append(self.scratch(), .{
            .continue_block = step,
            .exit_block = exit,
            .scope_depth = self.scopes.items.len,
            .temps_depth = self.temps.items.len,
        });
        try self.replayBlock(loop.body);
        _ = self.loops.pop();
        try self.code.closeCountedLoop(.{
            .index = counter,
            .limit = limit,
            .header = header,
            .body = body,
            .step = step,
            .exit = exit,
        });
        self.popScope();
    }

    fn replayForIn(self: *Replay, loop: nodes.Statement.ForIn) Error!void {
        const sequence = try self.replayValue(loop.sequence);
        const sequence_type = loop.sequence.result();
        const descriptor = self.heapOf(sequence_type);
        // The iteration's shape, re-derived from the sequence: a map
        // binds its key (or key and value), a list or rank-1 array its
        // element (or index and element).
        const two_names = loop.second != null;
        const map_like = descriptor != null and descriptor.? == .map;
        const payload_kind: mir.Intrinsic = if (map_like) .value_at else .index_get;
        const position_kind: ?mir.Intrinsic = if (map_like) .key_at else null;
        const first_kind: ?mir.Intrinsic = if (two_names or map_like) position_kind else payload_kind;

        try self.pushScope();
        // The iteration's two hidden slots — the collection and the
        // position within it — taken through the recorded local table.
        var shape: mir.build.Lowering.Iteration = .{
            .object = self.takeSlot(null, sequence_type, false),
            .position = self.takeSlot(null, .i64, false),
        };
        const first = self.takeRecordedSlot(loop.first);
        try self.noteLoopName(first);
        const second: ?LocalId = if (loop.second) |expected| owned: {
            const local = self.takeRecordedSlot(expected);
            try self.noteLoopName(local);
            break :owned local;
        } else null;
        try self.code.startIteration(&shape, sequence);

        const first_type = self.code.localType(first);
        const first_value = try self.code.iterationValue(shape, first_kind, first_type);
        try self.bindLoopName(first, first_value);
        if (second) |local| {
            const payload = try self.code.iterationValue(shape, payload_kind, self.code.localType(local));
            try self.bindLoopName(local, payload);
        }
        try self.loops.append(self.scratch(), .{
            .continue_block = shape.step,
            .exit_block = shape.exit,
            .scope_depth = self.scopes.items.len,
            .temps_depth = self.temps.items.len,
        });
        try self.replayBlock(loop.body);
        _ = self.loops.pop();
        try self.code.closeIteration(shape);
        // The loop-name scope's own end: the owning copies go back.
        try self.emitScopeEnd();
        self.popScope();
    }

    /// One iteration's binding of a loop name (`bindLoopName`): a
    /// plain store when the slot borrows, a release-then-copy when the
    /// recorded row says it owns.
    fn bindLoopName(self: *Replay, local: LocalId, value: Register) Error!void {
        if (!self.code.localOwnsStorage(local)) {
            try self.code.store(local, value);
            return;
        }
        try self.code.release(local, true);
        // The getter answers a view; the owning slot copies it in.
        const copied = try self.code.ownStorage(value);
        try self.code.store(local, copied);
    }

    fn replayBreakContinue(self: *Replay, unwind: u32, temps_floor: u32, is_break: bool) Error!void {
        const frame = self.loops.items[self.loops.items.len - 1];
        std.debug.assert(frame.temps_depth == temps_floor);
        std.debug.assert(self.scopes.items.len - frame.scope_depth == unwind);
        try self.emitTempReleases(frame.temps_depth);
        try self.emitScopeReleases(frame.scope_depth);
        try self.code.jump(if (is_break) frame.exit_block else frame.continue_block);
    }

    fn replayReturn(self: *Replay, returned: nodes.Statement.Return) Error!void {
        if (returned.values.len == 0) {
            try self.emitTempReleases(0);
            try self.emitScopeReleases(0);
            try self.code.ret(null);
            return;
        }
        if (returned.values.len == 1) {
            const value = returned.values[0];
            const register = try self.replayValue(value);
            const value_type = value.result();
            if (value.* == .absent) {
                try self.emitTempReleases(0);
                try self.emitScopeReleases(0);
                try self.code.ret(register);
                return;
            }
            const handed = try self.ownedForStore(register, value_type, nodes.provenance(value));
            std.debug.assert(handed.kind == returned.stores[0]);
            var handed_out = handed.register;
            if (carriesText(value_type)) {
                handed_out = try self.code.exportStorage(handed_out);
            }
            try self.emitTempReleases(0);
            try self.emitScopeReleases(0);
            try self.code.ret(handed_out);
            return;
        }
        // The shaped return: one batch, all fits, then the per-value
        // stores, the shape, the export, the unwinding.
        const entries = try self.scratch().alloc(BatchEntry, returned.values.len);
        defer self.scratch().free(entries);
        for (returned.values, 0..) |value, index| entries[index] = try self.peel(value);
        self.markSpills(entries, &.{});
        for (entries, 0..) |*entry, index| {
            const copied = if (index < returned.copied.len) returned.copied[index] else false;
            const opened_in = self.code.current;
            try self.replayBatchOperand(entry, copied);
            self.assertSplitCarried(entries[0..index], opened_in);
        }
        try self.reloadSpills(entries);
        for (entries) |*entry| try self.applyWrappers(entry);
        const registers = try self.arena().alloc(Register, entries.len);
        for (entries, returned.stores, registers) |entry, recorded, *slot| {
            const value_type = wrappedType(&entry);
            const stored = try self.ownedForStore(entry.register, value_type, entry.provenance);
            std.debug.assert(stored.kind == recorded);
            slot.* = stored.register;
        }
        const shape = try self.code.emit(
            .{ .struct_make = .{ .layout = self.code.return_type.strukt, .fields = registers } },
            self.code.return_type,
        );
        const handed_out = try self.code.exportStorage(shape);
        try self.emitTempReleases(0);
        try self.emitScopeReleases(0);
        try self.code.ret(handed_out);
    }

    fn replayGuarded(self: *Replay, guarded: nodes.Statement.Guarded) Error!void {
        self.opened = null;
        try self.replayStatement(guarded.attempt);
        const opened = self.opened.?;
        self.opened = null;

        const merge = try self.code.reserveBlock();
        try self.code.jump(merge);
        self.code.switchTo(opened.handler);
        if (guarded.error_local) |expected| {
            try self.pushScope();
            const bound_type = self.body.locals[expected].local_type;
            const words = if (bound_type == .str)
                try self.code.errorMessage()
            else
                try self.code.errorValue(bound_type);
            const local = self.takeRecordedSlot(expected);
            try self.storeOwned(local, words, bound_type, .plain, null);
            try self.noteOwned(local);
            _ = try self.code.emit(
                .{ .intrinsic = .{ .kind = .forget, .arguments = &.{} } },
                .none,
            );
            try self.replayBlock(guarded.handler);
            // The binding scope's own end, from the locals table.
            try self.emitScopeEnd();
            self.popScope();
        } else {
            _ = try self.code.emit(
                .{ .intrinsic = .{ .kind = .forget, .arguments = &.{} } },
                .none,
            );
            try self.replayBlock(guarded.handler);
        }
        try self.code.jump(merge);
        self.code.switchTo(merge);
    }

    fn replayMatch(self: *Replay, matched: nodes.Statement.Match) Error!void {
        const floor = self.temps.items.len;
        const scrutinee = try self.replayValue(matched.scrutinee);
        const scrutinee_type = matched.scrutinee.result();
        const held = self.takeSlot(null, scrutinee_type, false);
        std.debug.assert(held == matched.held);
        try self.code.store(held, scrutinee);
        const flag: ?LocalId = if (matched.flag) |recorded| taken: {
            const slot = self.takeSlot(null, .boolean, false);
            std.debug.assert(slot == recorded);
            break :taken slot;
        } else null;

        const fallthrough = matched.else_body == null;
        const tested = if (fallthrough) matched.arms.len - 1 else matched.arms.len;
        var frames: std.ArrayList(mir.build.Lowering.Conditional) = .empty;
        defer frames.deinit(self.scratch());
        for (matched.arms[0..tested]) |arm| {
            const same = switch (arm.chooses) {
                .member => |member| if (scrutinee_type == .variant) variant_test: {
                    const tag = try self.code.emit(
                        .{ .variant_tag = .{ .target = try self.code.load(held) } },
                        .i64,
                    );
                    const number = try self.code.emit(.{ .const_integer = @intCast(member) }, .i64);
                    break :variant_test try self.code.emit(.{ .binary = .{
                        .op = .equal,
                        .operand_type = .i64,
                        .left = tag,
                        .right = number,
                    } }, .boolean);
                } else enum_test: {
                    const declared = self.code.enums[scrutinee_type.enumeration.index];
                    const number = try self.code.emit(
                        .{ .const_integer = declared.members[member].value },
                        scrutinee_type,
                    );
                    break :enum_test try self.code.emit(.{ .binary = .{
                        .op = .equal,
                        .operand_type = scrutinee_type,
                        .left = try self.code.load(held),
                        .right = number,
                    } }, .boolean);
                },
                .values => |patterns| try self.replayValueTest(flag.?, held, scrutinee_type, patterns),
            };
            const arms = try self.code.openIf(same, true);
            try self.replayMatchArm(arm);
            try self.code.elseArm(arms);
            try frames.append(self.scratch(), arms);
        }
        if (matched.else_body) |otherwise| {
            try self.replayBlock(otherwise);
        } else {
            try self.replayMatchArm(matched.arms[matched.arms.len - 1]);
        }
        while (frames.pop()) |arms| try self.code.closeIf(arms);
        // The scrutinee's temporary is released here, in the merge,
        // and not before the arms: the held slot borrows the run and
        // an arm's payload binding aliases into it, so a release
        // above the dispatch would free what every arm then reads
        // (S3, docs/UNION.md D10).  An arm that leaves early —
        // `return`, `break`, `continue` — releases it on its own way
        // out, from the floor its statement recorded.
        try self.flushTemps(floor);
    }

    /// One value arm's admission test: any of its patterns admits the
    /// held scrutinee.  MIR has no boolean and/or instructions — the
    /// words are control flow — so the test is a flag slot written by
    /// nested ifs over effect-free comparisons: one body, no
    /// duplication, and LLVM folds the chain the way it folds any
    /// compare tree.
    fn replayValueTest(
        self: *Replay,
        flag: LocalId,
        held: LocalId,
        scrutinee_type: Type,
        patterns: []const nodes.Statement.Match.Pattern,
    ) Error!mir.Register {
        try self.code.store(flag, try self.code.emit(.{ .const_boolean = false }, .boolean));
        for (patterns) |pattern| {
            if (pattern.high) |top| {
                const above = try self.code.emit(.{ .binary = .{
                    .op = .greater_equal,
                    .operand_type = scrutinee_type,
                    .left = try self.code.load(held),
                    .right = try self.replayValue(pattern.low),
                } }, .boolean);
                const low_arm = try self.code.openIf(above, true);
                const below = try self.code.emit(.{ .binary = .{
                    .op = .less_equal,
                    .operand_type = scrutinee_type,
                    .left = try self.code.load(held),
                    .right = try self.replayValue(top),
                } }, .boolean);
                const high_arm = try self.code.openIf(below, true);
                try self.code.store(flag, try self.code.emit(.{ .const_boolean = true }, .boolean));
                try self.code.elseArm(high_arm);
                try self.code.closeIf(high_arm);
                try self.code.elseArm(low_arm);
                try self.code.closeIf(low_arm);
            } else {
                const same = try self.code.emit(.{ .binary = .{
                    .op = .equal,
                    .operand_type = scrutinee_type,
                    .left = try self.code.load(held),
                    .right = try self.replayValue(pattern.low),
                } }, .boolean);
                const arm = try self.code.openIf(same, true);
                try self.code.store(flag, try self.code.emit(.{ .const_boolean = true }, .boolean));
                try self.code.elseArm(arm);
                try self.code.closeIf(arm);
            }
        }
        return self.code.load(flag);
    }

    fn replayMatchArm(self: *Replay, arm: nodes.Statement.Match.Arm) Error!void {
        if (arm.bindings.len == 0) {
            try self.replayBlock(arm.body);
            return;
        }
        try self.pushScope();
        for (arm.bindings) |binding| {
            const register = try self.replayValue(binding.payload);
            const local = self.takeRecordedSlot(binding.local);
            try self.storeOwned(local, register, binding.payload.result(), .view, null);
            try self.noteOwned(local);
        }
        try self.replayBlock(arm.body);
        // The binding scope's own end, from the locals table: an alias
        // never claims objects, so the releases are storage-only, in
        // reverse declaration order.
        try self.emitScopeEnd();
        self.popScope();
    }
};
