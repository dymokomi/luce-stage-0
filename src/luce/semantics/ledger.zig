//! The statement-temporary ledger (MEMORY.md): every fresh,
//! unowned object a statement produces is parked in a hidden local,
//! and the end of the statement releases the ones nothing adopted.
//!
//! One table, `FunctionBuilder.temps`, with four questions asked of
//! it — park this (`registerTemp`), is this already parked
//! (`parkedAlready`), does a store get to take its storage instead of
//! copying it (`takeStorage`), and what is left to release at the end
//! of the statement (`flushTemps`) — plus the recording side of the
//! same fact, the park a node carries into stage 5 (`settlePark`).
//! They are a file because they are one data structure with one
//! invariant: a value has exactly one owner, and the ledger is where
//! this walk writes down who it is.

const std = @import("std");
/// Whether the recording's internal consistency asserts run (the
/// settled-park lockstep in `flushTemps`): Debug builds only.
const debug_checks = @import("builtin").mode == .Debug;
const source_mod = @import("../source.zig");
const types = @import("../support/types.zig");
const mir = @import("../mir.zig");
const nodes = @import("../hir.zig").nodes;
const context = @import("context.zig");
const Error = context.Error;
const Span = source_mod.Span;
const Type = types.Type;
const LocalId = mir.LocalId;

const builder = @import("builder.zig");
const recorder = @import("recorder.zig");
const shapes = @import("shapes.zig");
const FunctionBuilder = builder.FunctionBuilder;
const Typed = builder.Typed;

pub const TempSlot = struct {
    local: LocalId,
    /// The parked value's node — the ledger's key: a value is
    /// re-identified here by the node that produced it.  Null for
    /// the two *derived* parks the recording never sees — the
    /// compound concatenation and the writing-receiver keep-copy —
    /// which `hir.lower` re-derives (its `parkDerivedStorage`).
    node: ?nodes.NodeRef,
    /// Whether this temporary owns its value's storage — the question
    /// `context.Release` answers for a named binding.
    storage: bool,
    /// Whether the park may be retracted so a store can take the
    /// storage instead of copying it (`takeStorage`).  True of
    /// every parked temporary, whose slot is written and never
    /// read; false of the slot a fallible call's result crosses
    /// its branch in, which is reloaded (docs/STRINGS.md).
    disownable: bool = true,
    /// Whether a store already took this storage.  One value has
    /// one owner, so the second store of the same value — if a
    /// shape that does that ever exists — copies.
    taken: bool = false,
};

// Nothing is emitted for a release here: the scope-exit releases
// ride the recorded blocks (`closeStatementFrame`), the unwinding
// paths record their floors and moved sets on their statements,
// and `hir.lower` emits every release from those records.

/// Park a fresh value in a hidden local so the end of the statement
/// can release it if nothing adopted it (S3, S19): the object it
/// carries when `objects` is set, its freshly allocated storage
/// when `storage` is (docs/STRINGS.md).  `span` is the parked
/// expression's, for the hidden slot's row in the tree's locals
/// table.
pub fn registerTemp(
    self: *FunctionBuilder,
    value: Typed,
    storage: bool,
    objects: bool,
    span: Span,
) Error!void {
    const local = try recorder.recordLocal(self, null, value.value_type, storage, span);
    // The park records at the park (coupling #3): the at-park claim is
    // what the park emits, and the released half settles in place as an
    // adopting store retracts it.  The object claim rides along; the
    // replay re-derives its retraction, so the record needs only the flag.
    setPark(value.node, .{
        .local = local,
        .storage = storage,
        .released_storage = storage,
        .objects = objects,
    });
    try self.temps.append(self.temporary(), .{
        .local = local,
        .node = value.node,
        .storage = storage,
    });
}

/// Is this exact value already parked?
///
/// **One value, one park.**  A `try` hands back what the call it
/// wraps produced, so the walk sees the same value twice — once
/// for the call and once for the `try` around it — and two hidden
/// locals both claiming one string's bytes free them twice.  The
/// question is asked through the carried links (`parkAnchor`), so
/// the try's wrapper finds the call's park; `a else b` is
/// untouched, because its three nodes are three different values.
pub fn parkedAlready(self: *const FunctionBuilder, node: nodes.NodeRef) bool {
    const anchor = parkAnchor(node);
    for (self.temps.items) |temp| {
        const held = temp.node orelse continue;
        if (parkAnchor(held) == anchor) return true;
    }
    return false;
}

/// The node a park is keyed on: the value behind the wrappers that
/// hand a value through unchanged — `try` and the branch-crossing
/// reload both answer the call's own value, and the storage
/// questions always wanted the call.
fn parkAnchor(node: nodes.NodeRef) nodes.NodeRef {
    return switch (node.*) {
        .carried_get => |carried| parkAnchor(carried.origin),
        .try_call => |wrapped| parkAnchor(wrapped.call),
        else => node,
    };
}

/// Forget the temporaries above `from`: the end of the statement
/// (or of a condition) that created them.  The releases themselves
/// are `hir.lower`'s, replayed from the parks this walk recorded.
///
/// This is where the settled ledger meets the tree (coupling #3):
/// every claim an adopting store was going to retract has been
/// retracted by now, so each temporary's surviving claims must
/// already stand on its value's node as the recorded park —
/// including a fully retracted one, whose release frees nothing
/// but whose slot is still made and stored.
pub fn flushTemps(self: *FunctionBuilder, from: usize) void {
    if (debug_checks) {
        for (self.temps.items[from..]) |temp| {
            const node = temp.node orelse continue;
            const parked = node.park().?;
            std.debug.assert(parked.local == temp.local);
            std.debug.assert(parked.released_storage == temp.storage);
        }
    }
    self.temps.shrinkRetainingCapacity(from);
}

/// Enter a *derived* park — the compound concatenation and the
/// writing-receiver keep-copy, whose slots `hir.lower` re-derives
/// rather than reads off a node (`parkDerivedStorage` there):
/// always storage-only, always fresh.  Answers the ledger index,
/// so the store that adopts the value can retract exactly this
/// entry (`takeDerivedStorage`).
pub fn parkDerivedTemp(self: *FunctionBuilder, value_type: Type, span: Span) Error!usize {
    const local = try recorder.recordLocal(self, null, value_type, true, span);
    try self.temps.append(self.temporary(), .{
        .local = local,
        .node = null,
        .storage = true,
    });
    return self.temps.items.len - 1;
}

/// `takeStorage` for a derived park: retract the named ledger
/// entry so the place adopts the storage — the decision is `.take`
/// exactly when the entry still holds it.
pub fn takeDerivedStorage(self: *FunctionBuilder, index: usize) bool {
    const temp = &self.temps.items[index];
    if (temp.taken or !temp.storage) return false;
    self.recorded_locals.items[temp.local].boxed_storage = true;
    self.recorded_locals.items[temp.local].owns_storage = false;
    temp.storage = false;
    temp.taken = true;
    return true;
}

/// Write a park onto its value's node (S3), at the park itself:
/// the at-park claims say what the park emitted, and the released
/// halves start equal and settle in place as the ledger's
/// retractions land (coupling #3) — so the tree carries both the
/// emission and the ledger's final answer.
pub fn setPark(node: nodes.NodeRef, parked: nodes.Park) void {
    switch (node.*) {
        inline else => |*payload| payload.park = parked,
    }
}

/// Settle one storage retraction onto a parked node — the recording
/// half of `takeStorage`.  A derived park has no node and nothing to
/// settle.
fn settlePark(node: ?nodes.NodeRef, storage: bool) void {
    const parked_node = node orelse return;
    switch (parked_node.*) {
        inline else => |*payload| {
            if (payload.park) |*parked| {
                if (!storage) parked.released_storage = false;
            }
        },
    }
}

/// Is this value's storage parked in a statement temporary?
fn parkedForStorage(self: *const FunctionBuilder, node: nodes.NodeRef) bool {
    const anchor = parkAnchor(node);
    for (self.temps.items) |temp| {
        const held = temp.node orelse continue;
        if (parkAnchor(held) == anchor and temp.storage) return true;
    }
    return false;
}

/// Take `register`'s storage for a place that outlives the
/// statement, if it can be taken — otherwise say so and let the
/// place copy.
///
/// It can be taken when this statement allocated it and nothing
/// else will give it back.  A parked temporary *is* something
/// else, so the park is retracted here: its slot stops owning
/// storage, the statement's release goes with it, and the place
/// becomes the one owner.  That is the whole of move-instead-of-
/// copy, and it is why this is not a question — asking it hands
/// the storage over (docs/STRINGS.md).
///
/// One park is kept rather than retracted: a slot that is read back
/// cannot stop owning storage, because a borrowing slot hands a
/// reload the register shape and a string's form does not survive
/// that — which is exactly the slot a fallible call's result crosses
/// its branch in.
fn takeStorage(self: *FunctionBuilder, value: Typed) bool {
    if (value.provenance() != .fresh) return false;
    const anchor = parkAnchor(value.node);
    for (self.temps.items) |*temp| {
        const held = temp.node orelse continue;
        if (parkAnchor(held) != anchor) continue;
        if (temp.taken) return false;
        if (!temp.storage) continue;
        if (!temp.disownable) return false;
        // The tree's locals table carries the retraction: the
        // settled answer is that the place, not the slot, owns the
        // storage (coupling #3), and `hir.lower` reads exactly
        // this settled row.
        self.recorded_locals.items[temp.local].boxed_storage = true;
        self.recorded_locals.items[temp.local].owns_storage = false;
        // Emptied rather than forgotten: the record is what keeps
        // one value from being parked twice, and every index into
        // this list is a floor some other unwinding path recorded.
        temp.storage = false;
        temp.taken = true;
        settlePark(temp.node, false);
        return true;
    }
    return true;
}

/// A store's decided form (nodes.StoreKind).  The decision is
/// *made* here — the one place — and the store sites the statement
/// tree spells it on record the kind, so `hir.lower` emits the
/// decided form once (hir.zig, coupling #3).
///
/// **Every store goes through here** — a binding, a reassignment, a
/// list element, a map value, a struct field, a return — because
/// `libluce_rt` never copies at a store: the copy is decided once,
/// here, where the decision that elides it can be seen
/// (docs/STRINGS.md).
pub fn ownedForStoreKind(self: *FunctionBuilder, value: Typed) nodes.StoreKind {
    if (!shapes.ownsStorage(self.analyzer, value.value_type)) return .plain;
    if (takeStorage(self, value)) {
        // Move-instead-of-copy: the place adopts storage this
        // statement made and nothing else claims (docs/STRINGS.md).
        return .take;
    }
    return .copy;
}

/// `ownedForStoreKind` for the sites whose statement family does
/// not spell the decision — the kind is still decided (and parked
/// ledgers settled) identically.
pub fn ownedForStore(self: *FunctionBuilder, value: Typed) void {
    _ = ownedForStoreKind(self, value);
}

/// Whether a value of this type can be text in its own right —
/// the one payload whose storage might be inside the value rather
/// than an allocation of its own, and so the one that cannot
/// simply be handed out of the frame that made it.
fn carriesText(of: Type) bool {
    return switch (of) {
        .str, .bytes => true,
        .optional => |payload| carriesText(payload.asType()),
        else => false,
    };
}

/// Decide a store into a local, taking or copying the value's
/// storage in when the local is the one that will have to give it
/// back — answering which of the three the store was, for the
/// statement families that record it.
pub fn storeOwnedKind(self: *FunctionBuilder, local: LocalId, value: Typed) nodes.StoreKind {
    if (!recorder.localOwnsStorage(self, local)) return .plain;
    return ownedForStoreKind(self, value);
}

/// `storeOwnedKind` for the sites that do not spell the decision.
pub fn storeOwned(self: *FunctionBuilder, local: LocalId, value: Typed) void {
    _ = storeOwnedKind(self, local, value);
}

/// Park a freshly allocated string or struct value that was not
/// produced through `lowerExpression` — a compound assignment's
/// concatenation, say — so the statement's end reclaims it.
pub fn parkFreshStorage(self: *FunctionBuilder, value: Typed, span: Span) Error!void {
    if (!shapes.ownsStorage(self.analyzer, value.value_type)) return;
    if (value.provenance() != .fresh) return;
    if (parkedForStorage(self, value.node)) return;
    try registerTemp(self, value, true, false, span);
}

/// Park a borrow closed by a storage copy — the operand batch's
/// defensive rewrite.  The copy owns fresh storage, but it *shares* the
/// borrow's objects: a struct's list rides the copied run as the same
/// reference, so the copy must count it (the replay retains exactly
/// when this park claims objects).  An adopting store then transfers
/// both halves; an unadopted copy releases both at the statement's end.
pub fn parkCopiedBorrow(self: *FunctionBuilder, value: Typed, span: Span) Error!void {
    if (!shapes.ownsStorage(self.analyzer, value.value_type)) return;
    if (parkedForStorage(self, value.node)) return;
    const objects = shapes.carriesObjects(self.analyzer, value.value_type);
    try registerTemp(self, value, true, objects, span);
}

/// Explicitly park both halves of a fresh owning value before the generic
/// expression boundary sees it. Interface fitting is the important caller:
/// it constructs and retains bound witnesses during operand landing, then its
/// early storage park would otherwise prevent `lowerExpression` from adding
/// the matching object release.
pub fn parkFreshValue(self: *FunctionBuilder, value: Typed, span: Span) Error!void {
    if (parkedAlready(self, value.node)) return;
    const storage = value.provenance() == .fresh and
        shapes.ownsStorage(self.analyzer, value.value_type);
    const objects = nodes.freshObject(value.node) and
        shapes.carriesObjects(self.analyzer, value.value_type);
    if (storage or objects) try registerTemp(self, value, storage, objects, span);
}
