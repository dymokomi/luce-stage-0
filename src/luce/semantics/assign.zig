//! Assignment, and the three shapes of place it can name: a bare name,
//! a field, an index — and the chain that is any run of the last two.
//!
//! One statement, but among the hardest in the language, because a
//! store is where several of this walk's questions land at once: what
//! type the place holds and whether the value fits it, whether the
//! store takes the value's storage or copies it, and what a compound
//! operator combines before it stores.  Written together so the
//! answers stay one answer.
//!
//! Its interface is `lowerAssign`, the arm `statements.zig` calls, and
//! `checkIndex`, the bounds-and-type check a read shares with a write.

const std = @import("std");
const source_mod = @import("../source.zig");
const ast = @import("../parse.zig").ast;
const types = @import("../support/types.zig");
const mir = @import("../mir.zig");
const nodes = @import("../hir.zig").nodes;
const context = @import("context.zig");
const Error = context.Error;
const Span = source_mod.Span;
const Type = types.Type;

const builder = @import("builder.zig");
const expressions = @import("expressions.zig");
const flow = @import("flow.zig");
const ledger = @import("ledger.zig");
const recorder = @import("recorder.zig");
const refusals = @import("refusals.zig");
const naming = @import("naming.zig");
const shapes = @import("shapes.zig");
const FunctionBuilder = builder.FunctionBuilder;
const Provenance = builder.Provenance;
const Typed = builder.Typed;

pub fn lowerAssign(self: *FunctionBuilder, assign: ast.Assign) Error!void {
    switch (assign.target) {
        .name => |name| try lowerAssignName(self, name.text, name.span, assign),
        .field => |field| try lowerAssignField(self, field, assign),
        .index => |index| try lowerAssignIndex(self, index, assign),
        .chain => |chain| try lowerAssignChain(self, chain, assign),
    }
}

/// place = value / place OP= value for a nested place
/// (`root.a.b`, `cells[0].value`).  The chain is read exactly once
/// (every subscript evaluated once), then rebuilt from the leaf:
/// structs functionally update up to the root local, and the first
/// container index writes in place and stops.  Restricted to
/// value leaves and value structs — nesting object ownership
/// through a chain stays the single-level form's job.
fn lowerAssignChain(self: *FunctionBuilder, chain: ast.ChainTarget, assign: ast.Assign) Error!void {
    // Collect the accessor chain outer-to-inner, then find the
    // root name.
    var steps: std.ArrayList(*const ast.Expression) = .empty;
    defer steps.deinit(self.temporary());
    var walk: *const ast.Expression = chain.place;
    const root: ast.Name = while (true) {
        switch (walk.*) {
            .name => |name| break name,
            .field => |field| {
                try steps.append(self.temporary(), walk);
                walk = field.target;
            },
            .index => |index| {
                try steps.append(self.temporary(), walk);
                walk = index.target;
            },
            else => {
                try self.fail("luce.parse.assign", chain.span, "assignment targets a name, a field, or an index of one", .{});
                return;
            },
        }
    };
    std.mem.reverse(*const ast.Expression, steps.items);

    // **Does this store land in the root's own slot?**  It does
    // when every step is a field: the rebuild below functionally
    // updates each struct outward and finishes with a `store` into
    // the local, so the local is genuinely reassigned and `let`
    // forbids it.  It does *not* when any step is an index: the
    // rebuild stops at the innermost `index_set`, which writes
    // through the object reference and never reaches the local
    // (`mir/build.zig`'s `rebuild` — "the object mutated in
    // place").
    //
    // `let` freezes the binding, not the object, everywhere else
    // in the language — `xs.append(v)`, `xs.sort()`, `xs[0] = v`
    // and `bag.counts[0] = v` are all legal through an immutable
    // name, because none of them writes the name.  Asking `var` of
    // `xs[0].field = v` alone made two spellings of one store
    // disagree, and said so in a sentence about a reassignment the
    // emitted code provably does not perform.
    var writes_root = true;
    for (steps.items) |node| {
        if (node.* == .index) {
            writes_root = false;
            break;
        }
    }

    // The root must be a usable local, and a mutable one when the
    // store lands in it.
    if (std.mem.eql(u8, root.text, "input") or std.mem.eql(u8, root.text, "output")) {
        try self.fail("luce.sema.name", root.span, "ports are not nested places", .{});
        return;
    }
    const found = self.findLocal(root.text) orelse {
        const qualified = try naming.qualify(self.analyzer, self.prefix, root.text);
        if (self.analyzer.constant_names.contains(qualified)) {
            try self.fail("luce.sema.const", chain.span, "{s} is a file-scope constant and cannot be assigned", .{root.text});
            return;
        }
        try refusals.failUnknownName(self, root.text, root.span);
        return;
    };
    const info = found.info;
    if (!info.mutable and writes_root) {
        try self.fail("luce.sema.let", root.span, "{s} is let-bound; use var for reassignment", .{root.text});
        return;
    }
    const root_local = info.local;
    const root_type = recorder.localType(self, root_local);

    // Lower every subscript across the chain plus the right-hand
    // side in one pass: lowerOperands keeps the batch's rewrite
    // facts together even across short-circuit block splits, so
    // the descent below is pure structure and every recorded
    // subscript carries its own flags.
    //
    // **The written path is the landing** (`Landing.chain`): each
    // subscript lands where its container is addressed, and the
    // value lands on the leaf — which the path names before
    // anything is lowered, at any depth.  So a bare function name,
    // a lambda, a union constructor and a bare `none` reach a slot
    // three steps in exactly as they reach one a single field away
    // (docs/BINDING.md D7, docs/FUNCTIONS.md D2).
    var operand_list: std.ArrayList(*ast.Expression) = .empty;
    defer operand_list.deinit(self.temporary());
    for (steps.items) |node| {
        if (node.* == .index) {
            for (node.index.indices) |subscript| try operand_list.append(self.temporary(), subscript);
        }
    }
    try operand_list.append(self.temporary(), assign.value);
    const landing: builder.Landing = .{ .chain = .{ .root = root_type, .steps = steps.items } };
    const run = (try self.lowerOperandsIntoTracking(operand_list.items, landing)) orelse return;
    const operands = run.values;
    const value = operands[operands.len - 1];
    var next_operand: usize = 0;

    // Descend, checking each step and recording the mirror of the
    // descent (nodes.Place.Chain): one step per accessor, with
    // subscript nodes pre-rewrite.  The reads themselves — each
    // struct_get and index_get on the way down, and the rebuild
    // back up — are lower's to spell from these steps.
    const recorded_steps = try self.arena().alloc(nodes.Place.Step, steps.items.len);
    var current_type = root_type;
    for (steps.items, recorded_steps) |node, *recorded_step| {
        switch (node.*) {
            .field => |field| {
                if (current_type != .strukt) {
                    try self.fail("luce.sema.field", field.span, "{s} has no fields", .{
                        try self.analyzer.typeName(current_type),
                    });
                    return;
                }
                const layout_index = current_type.strukt;
                const layout = self.analyzer.structs.items[layout_index];
                const field_index = layout.findField(field.name) orelse {
                    try refusals.failUnknownField(self, "luce.sema.field", layout_index, field.name, field.span);
                    return;
                };
                if (!try refusals.fieldReachable(self, layout_index, field_index, field.span)) return;
                recorded_step.* = .{ .field = .{ .layout = layout_index, .field = field_index } };
                current_type = layout.fields[field_index].field_type;
            },
            .index => |index| {
                const lowered = operands[next_operand .. next_operand + index.indices.len];
                next_operand += index.indices.len;
                const element_type = (try checkIndex(self, current_type, lowered, index.span)) orelse return;
                const subscript_nodes = try self.arena().alloc(nodes.Operand, lowered.len);
                recorded_step.* = .{ .index = subscript_nodes };
                for (lowered, 0..) |value_operand, at_subscript| {
                    subscript_nodes[at_subscript] = .{
                        .node = value_operand.node,
                        .copied = run.copied[next_operand - lowered.len + at_subscript],
                    };
                }
                // **Always an ordinary read, never a defining
                // one**, and the parser is what guarantees it: a
                // target ending in `[...]` becomes an `.index`
                // target whatever its base, so a chain's last step
                // is always a field (`targetFrom`).  Every index
                // here is therefore a step on the way *down* — and
                // `m["k"].value += 5` reads `m["k"]` to reach a
                // field of it, which is asking, not writing.  It
                // keeps `key_missing`.
                //
                // `t.counts["w"] += 1` is not this case: it is an
                // `.index` target with `t.counts` for a base, and
                // it defines like any other (`lowerAssignIndex`).
                current_type = element_type;
            },
            else => unreachable, // only field/index steps are collected
        }
    }

    // The value was lowered before the chain named a type for it,
    // so `fit` applies the language's two implicit conversions here —
    // a wider number widens, and a `T` reaching a `T?` wraps, which is
    // how a function value reaches its storable form
    // (docs/TYPES.md §2, docs/BINDING.md D7).
    var placed = value;
    if (try self.fit(placed, current_type)) |fitted| placed = fitted;
    if (!placed.value_type.eql(current_type)) {
        try self.fail("luce.sema.type", assign.span, "this place holds {s} but the value is {s}", .{
            try self.analyzer.typeName(current_type),
            try self.analyzer.typeName(placed.value_type),
        });
        return;
    }
    // The leaf is a store into whatever the chain descended to, so
    // it takes or copies its storage; every step above it moves
    // the value the step below just built (docs/STRINGS.md).
    const store_kind = if (assign.compound) |op| kind: {
        const combined = (try compoundCombine(self, op, current_type, placed, assign.span)) orelse return;
        break :kind storedKindOf(self, current_type, combined);
    } else ledger.ownedForStoreKind(self, placed);
    const place: nodes.Place = .{ .chain = .{ .root = root_local, .steps = recorded_steps } };
    const value_copied = run.copied[run.copied.len - 1];
    if (assign.compound) |op| {
        try recorder.recordStatement(self, .{ .compound_assign = .{
            .place = place,
            .op = compoundOperation(op),
            .value = placed.node,
            .store = store_kind,
            .span = assign.span,
            .value_copied = value_copied,
        } });
    } else {
        try recorder.recordStatement(self, .{ .assign = .{
            .place = place,
            .value = placed.node,
            .store = store_kind,
            .span = assign.span,
            .value_copied = value_copied,
        } });
    }
}

/// The resolved operator a compound assignment combines under —
/// the parser's spellings onto stage 6's vocabulary, spelled once
/// for `compoundCombine` and for the recorded statement
/// (nodes.Statement.CompoundAssign).
fn compoundOperation(op: ast.BinaryOp) mir.BinaryOp {
    return switch (op) {
        .add => .add,
        .subtract => .subtract,
        .multiply => .multiply,
        .divide => .divide,
        .floor_divide => .floor_divide,
        .modulo => .modulo,
        .bit_and => .bit_and,
        .bit_or => .bit_or,
        .bit_xor => .bit_xor,
        .shift_left => .shift_left,
        .shift_right => .shift_right,
        else => unreachable, // the parser only builds these ten
    };
}

/// What a compound combine leaves to store: the combined value's
/// storage provenance, and the derived-park ledger entry a string
/// concatenation enters (`parkDerivedTemp`) — the park the
/// recording never sees, which `hir.lower` re-derives.
const Combined = struct { provenance: Provenance, derived: ?usize = null };

/// The store kind for a value that is not a checked expression —
/// a compound combine's answer, identified by its provenance and
/// its derived park rather than by a node (`ownedForStoreKind`'s
/// decision, spelled for the derived ledger).
fn storedKindOf(self: *FunctionBuilder, value_type: Type, combined: Combined) nodes.StoreKind {
    if (!shapes.ownsStorage(self.analyzer, value_type)) return .plain;
    if (combined.provenance == .fresh) {
        if (combined.derived) |index| {
            return if (ledger.takeDerivedStorage(self, index)) .take else .copy;
        }
        return .take;
    }
    return .copy;
}

/// Check the combine of `place OP= value` — `place OP= value`
/// reads the place once and stores the combination back.  Type
/// rules are a binary expression's exactly: numeric arithmetic,
/// plus string concat for `+=`.  A storage-width place combines at
/// its arithmetic type and narrows back with the range check, so
/// the answer is always at `place_type` — the read-combine-narrow
/// itself is `hir.lower`'s to spell (its `replayCombine`), from
/// the same pair of types.  Returns the combine's storage answer,
/// or null after reporting.
fn compoundCombine(
    self: *FunctionBuilder,
    op: ast.BinaryOp,
    place_type: Type,
    value: Typed,
    span: Span,
) Error!?Combined {
    if (!value.value_type.eql(place_type)) {
        try self.fail("luce.sema.type", span, "compound assignment needs matching types: place is {s}, value is {s}", .{
            try self.analyzer.typeName(place_type),
            try self.analyzer.typeName(value.value_type),
        });
        return null;
    }
    // `/` answers a double whatever it divides (docs/NUMERICS.md
    // §2), so `n /= 2` on an integer place is a narrowing nobody
    // wrote.  It is a compile error rather than a silent
    // truncation, which is this design's whole safety story in
    // one line — and the fix is one character.
    //
    // **At every integer width.**  Naming one of them here would
    // leave the other silently truncating, which is the one
    // failure the message exists to prevent.
    if (op == .divide and place_type.isInteger()) {
        try self.fail(
            "luce.sema.type",
            span,
            "/ answers f64 and this place is {s}; write '//=' for the integer quotient",
            .{try self.analyzer.typeName(place_type)},
        );
        return null;
    }
    const string_concat = op == .add and (place_type == .str or place_type == .bytes);
    if (!place_type.isNumeric() and !string_concat) {
        try self.fail("luce.sema.type", span, "{s} has no compound assignment (numbers, or += on str/bytes){s}", .{
            try self.analyzer.typeName(place_type),
            try refusals.absenceAdvice(self, place_type, null),
        });
        return null;
    }
    // The bit set has its compound forms too (docs/BITWISE.md
    // D5), and its own gate: every explicit integer width, no floats.
    switch (op) {
        .bit_and, .bit_or, .bit_xor, .shift_left, .shift_right => {
            if (!place_type.isInteger()) {
                try self.fail(
                    "luce.sema.type",
                    span,
                    "{s} works on integers; {s} has no bits a program may see",
                    .{
                        context.operatorText(op),
                        try self.analyzer.typeName(place_type),
                    },
                );
                return null;
            }
        },
        else => {},
    }
    // `s += t` concatenates into fresh storage that no expression
    // parked, so a place that keeps a copy would leave the join
    // behind (docs/STRINGS.md).  The derived park makes the
    // statement's end reclaim it either way; every numeric combine
    // answers a scalar.
    if (string_concat) {
        return .{ .provenance = .fresh, .derived = try ledger.parkDerivedTemp(self, place_type, span) };
    }
    return .{ .provenance = .plain };
}

fn lowerAssignName(self: *FunctionBuilder, base: []const u8, span: Span, assign: ast.Assign) Error!void {
    const found = self.findLocal(base) orelse {
        const qualified = try naming.qualify(self.analyzer, self.prefix, base);
        if (self.analyzer.constant_names.contains(qualified)) {
            try self.fail("luce.sema.const", span, "{s} is a file-scope constant and cannot be assigned", .{base});
        } else {
            try refusals.failUnknownName(self, base, span);
        }
        return;
    };
    const info = found.info;
    if (!info.mutable) {
        try self.fail("luce.sema.let", span, "{s} is let-bound; use var for reassignment", .{base});
        return;
    }
    if (info.iterating) {
        try self.fail(
            "luce.sema.own",
            span,
            "{s} is being iterated; reassigning it would invalidate the collection under the loop",
            .{base},
        );
        return;
    }
    const local = info.local;
    const local_type = recorder.localType(self, local);
    // A compound assignment works on the value the place holds, so
    // a narrowed `T?` combines at `T` and widens the result back.
    const narrowed_place = local_type == .optional and flow.isNarrowed(self, local);
    const combine_type = if (narrowed_place) local_type.held().? else local_type;
    const wanted = if (assign.compound != null) combine_type else local_type;

    const fitted = (try self.lowerTyped(assign.value, wanted, assign.span, base)) orelse return;
    const value = fitted.value;
    // What the slot now holds decides whether the name reads as
    // its payload from here on: a plain `T` is present, a `T?` or
    // a `none` is back to being a question.  A compound assignment
    // reads the place, so it can only leave what was already there.
    if (local_type == .optional and assign.compound == null) {
        if (fitted.present) try flow.narrow(self, local) else flow.widen(self, local);
    }
    var store_kind: nodes.StoreKind = .plain;
    const owns_storage = recorder.localOwnsStorage(self, local);
    if (assign.compound) |op| {
        var combined = (try compoundCombine(self, op, combine_type, value, assign.span)) orelse return;
        // A narrowed place wraps the combination back to `T?` —
        // a new plain value (`fit`'s rule, re-derived by lower).
        if (narrowed_place) combined.provenance = .plain;
        if (owns_storage) store_kind = storedKindOf(self, local_type, combined);
    } else if (owns_storage) {
        // The value being stored may be a view of the storage in
        // this same slot, so the take-or-copy decision is made
        // before the store overwrites it: `s = s[1:]` is legal
        // (docs/STRINGS.md).
        store_kind = ledger.ownedForStoreKind(self, value);
    }
    // The recorded statement: the sugar as written — the compound
    // form keeps its operator and its right side, and lower spells
    // the read-combine-narrow (hir.zig's own picture).
    if (assign.compound) |op| {
        try recorder.recordStatement(self, .{ .compound_assign = .{
            .place = .{ .local = local },
            .op = compoundOperation(op),
            .value = value.node,
            .store = store_kind,
            .span = assign.span,
        } });
    } else {
        try recorder.recordStatement(self, .{ .assign = .{
            .place = .{ .local = local },
            .value = value.node,
            .store = store_kind,
            .span = assign.span,
        } });
    }
}

fn lowerAssignField(self: *FunctionBuilder, target: ast.FieldTarget, assign: ast.Assign) Error!void {
    const found = self.findLocal(target.base) orelse {
        const qualified = try naming.qualify(self.analyzer, self.prefix, target.base);
        if (self.analyzer.constant_names.contains(qualified)) {
            try self.fail("luce.sema.const", target.span, "{s} is a file-scope constant and cannot be assigned", .{target.base});
            return;
        }
        try refusals.failUnknownName(self, target.base, target.span);
        return;
    };
    const info = found.info;
    if (!info.mutable) {
        try self.fail("luce.sema.let", target.span, "{s} is let-bound; use var for reassignment", .{target.base});
        return;
    }
    const local = info.local;
    const local_type = recorder.localType(self, local);
    if (local_type != .strukt) {
        try self.fail("luce.sema.field", target.span, "{s} is {s}, not a struct", .{
            target.base,
            try self.analyzer.typeName(local_type),
        });
        return;
    }
    const layout_index = local_type.strukt;
    const layout = self.analyzer.structs.items[layout_index];
    const field_index = layout.findField(target.field) orelse {
        try refusals.failUnknownField(self, "luce.sema.field", layout_index, target.field, target.span);
        return;
    };
    if (!try refusals.fieldReachable(self, layout_index, field_index, target.span)) return;
    const expected = layout.fields[field_index].field_type;
    const named = try std.fmt.allocPrint(self.arena(), "{s}.{s}", .{ target.base, target.field });
    const value = ((try self.lowerTyped(assign.value, expected, assign.span, named)) orelse return).value;
    // The new field is a store into the run `struct_set` builds,
    // decided here and spelled by lower.  A field that carries
    // objects stores the reference plainly; only value storage — a
    // string's bytes, a nested struct's run — is taken or copied.
    const store_kind = if (assign.compound) |op| kind: {
        const combined = (try compoundCombine(self, op, expected, value, assign.span)) orelse return;
        break :kind storedKindOf(self, expected, combined);
    } else ledger.ownedForStoreKind(self, value);
    if (assign.compound) |op| {
        try recorder.recordStatement(self, .{ .compound_assign = .{
            .place = .{ .field = .{ .base = local, .layout = layout_index, .field = field_index } },
            .op = compoundOperation(op),
            .value = value.node,
            .store = store_kind,
            .span = assign.span,
        } });
    } else {
        try recorder.recordStatement(self, .{ .assign = .{
            .place = .{ .field = .{ .base = local, .layout = layout_index, .field = field_index } },
            .value = value.node,
            .store = store_kind,
            .span = assign.span,
        } });
    }
}

/// place[i] = v, grid[r, c] = v, m[key] = v.  The base may be any
/// expression: objects mutate through the reference, so no local
/// write-back is needed.
fn lowerAssignIndex(self: *FunctionBuilder, target: ast.IndexTarget, assign: ast.Assign) Error!void {
    const operand_expressions = try self.arena().alloc(*ast.Expression, target.indices.len + 2);
    operand_expressions[0] = target.base;
    @memcpy(operand_expressions[1 .. 1 + target.indices.len], target.indices);
    operand_expressions[operand_expressions.len - 1] = assign.value;
    const run = (try self.lowerOperandsIntoTracking(operand_expressions, .stored_element)) orelse return;
    const values = run.values;

    const object = values[0];
    const indices = values[1 .. values.len - 1];
    const value = &values[values.len - 1];
    if (object.value_type == .str or object.value_type == .bytes) {
        try self.fail(
            "luce.sema.assign",
            target.span,
            "{s} is immutable; slicing or concatenation makes a new value",
            .{try self.analyzer.typeName(object.value_type)},
        );
        return;
    }
    const element_type = (try checkIndex(self, object.value_type, indices, target.span)) orelse return;
    // The value was lowered before the container named a type for
    // it, so `fit` applies both implicit conversions here — a wider
    // number widens, and a `T` reaching a `T?` wraps, which is how a
    // function value reaches its storable form (docs/TYPES.md §2,
    // docs/BINDING.md D7).
    if (try self.fit(value.*, element_type)) |fitted| value.* = fitted;
    if (!value.value_type.eql(element_type)) {
        try self.fail("luce.sema.type", assign.span, "this place holds {s} but the value is {s}", .{
            try self.analyzer.typeName(element_type),
            try self.analyzer.typeName(value.value_type),
        });
        return;
    }
    // The element is a store; the key beside it is not — a map
    // looks a key up before it keeps one (docs/STRINGS.md).  The
    // compound form reads the element once and combines; lower
    // spells the read (`map_place` for a map, `index_get`
    // otherwise) from the same facts.
    const store_kind = if (assign.compound) |op| kind: {
        const combined = (try compoundCombine(self, op, element_type, value.*, assign.span)) orelse return;
        break :kind storedKindOf(self, element_type, combined);
    } else ledger.ownedForStoreKind(self, value.*);
    // The recorded place: the container expression and the written
    // subscripts, pre-rewrite (nodes.Place.Index); the value is
    // the right side as written, with the compound form keeping
    // its operator.
    const subscript_nodes = try self.arena().alloc(nodes.Operand, indices.len);
    for (indices, run.copied[1 .. 1 + indices.len], subscript_nodes) |index_value, was_copied, *slot| {
        slot.* = .{
            .node = index_value.node,
            .copied = was_copied,
        };
    }
    const place: nodes.Place = .{ .index = .{
        .base = .{ .node = object.node, .copied = run.copied[0] },
        .indices = subscript_nodes,
    } };
    const value_copied = run.copied[run.copied.len - 1];
    if (assign.compound) |op| {
        try recorder.recordStatement(self, .{ .compound_assign = .{
            .place = place,
            .op = compoundOperation(op),
            .value = value.node,
            .store = store_kind,
            .span = assign.span,
            .value_copied = value_copied,
        } });
    } else {
        try recorder.recordStatement(self, .{ .assign = .{
            .place = place,
            .value = value.node,
            .store = store_kind,
            .span = assign.span,
            .value_copied = value_copied,
        } });
    }
}

/// Type-check lowered index values against a heap object: lists
/// take one long, arrays take rank Ints, maps take one key.
/// Returns the element/value type.
pub fn checkIndex(
    self: *FunctionBuilder,
    object_type: Type,
    indices: []Typed,
    span: Span,
) Error!?Type {
    if (object_type == .str or object_type == .bytes) {
        if (indices.len != 1 or !try self.widensInto(&indices[0], .i64)) {
            try self.fail("luce.sema.index", span, "{s} indexes with one i64", .{try self.analyzer.typeName(object_type)});
            return null;
        }
        return if (object_type == .str) .char else .u8;
    }
    const descriptor = self.analyzer.heapOf(object_type) orelse {
        try self.fail("luce.sema.index", span, "{s} cannot be indexed{s}", .{
            try self.analyzer.typeName(object_type),
            try refusals.absenceAdvice(self, object_type, null),
        });
        return null;
    };
    if (indices.len > 4) {
        try self.fail("luce.sema.index", span, "at most 4 index dimensions", .{});
        return null;
    }

    switch (descriptor) {
        .list => |element| {
            if (indices.len != 1 or !try self.widensInto(&indices[0], .i64)) {
                try self.fail("luce.sema.index", span, "lists index with one i64", .{});
                return null;
            }
            return element;
        },
        .array => |shape| {
            if (indices.len != shape.rank) {
                try self.fail("luce.sema.index", span, "this array has {d} dimensions, got {d} indices", .{
                    shape.rank,
                    indices.len,
                });
                return null;
            }
            for (indices) |*index_value| {
                if (!try self.widensInto(index_value, .i64)) {
                    try self.fail("luce.sema.index", span, "array indices are i64", .{});
                    return null;
                }
            }
            return shape.element;
        },
        .map => |pair| {
            // A key widens into the key type the way an index
            // widens into a `long`: `m[1]` on a `map(long, …)` is
            // the same key `m[1] = …` stores, and refusing one
            // while accepting the other would be a rule about
            // which side of the equals sign a literal sits on.
            // The other direction stays refused, because
            // `widensInto` never narrows.
            if (indices.len != 1 or !try self.widensInto(&indices[0], pair.key)) {
                try self.fail("luce.sema.index", span, "this map is keyed by {s}", .{
                    try self.analyzer.typeName(pair.key),
                });
                return null;
            }
            return pair.value;
        },
        .builder => {
            try self.fail("luce.sema.index", span, "builder has no index; b.build() reads it", .{});
            return null;
        },
        .file => {
            try self.fail("luce.sema.index", span, "file has no index; f.read(buffer) reads bytes", .{});
            return null;
        },
        .task => {
            try self.fail("luce.sema.index", span, "task has no index; t.wait() answers what the worker did", .{});
            return null;
        },
    }
}
