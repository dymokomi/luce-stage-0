//! What a type carries, how wide it is, and the one graph walk that
//! settles both.
//!
//! A struct or union that contains itself has no finite value, and a
//! struct that flattens to a million values costs a million
//! instructions to zero.  Those are the same question at two scales,
//! so one pass answers them: Tarjan's components over the combined
//! containment graph — structs and unions in one node space — marking
//! every node on a cycle and summing the shape of every node that is
//! not, in the order that makes the sum valid.  The two reports it
//! feeds are here too, because each is a sentence about a chain this
//! walk found and nothing else can name: the loop a reader has to
//! break, and the field that is worth widening.
//!
//! The predicates the rest of stage 4 asks are the settled tables
//! read back — `carriesObjects` and `valueCount` are array reads, and
//! both were exponential when they were recursive queries — beside
//! the three that need no table at all: `ownsStorage`, which is about
//! a run of bytes rather than an object, and the two iterative walks
//! that keep a legitimately cyclic *type* graph
//! (`struct Node: kids: list[Node]`) linear.  Those two are `carries`,
//! which follows the whole graph because the worker boundary moves the
//! whole graph, and `incomparablePart`, which stops at an object handle
//! because `==` does.  Which frontier a question wants is the question
//! itself, and each walk's doc comment says which and why.
//!
//! Free functions over `declarations.zig`'s `*Analyzer`; `pub` means
//! visible to stage 4's own files, nothing wider.

const std = @import("std");
const source_mod = @import("../source.zig");
const types = @import("../support/types.zig");
const helpers = @import("helpers.zig");

const context = @import("context.zig");
const Error = context.Error;
const Span = source_mod.Span;
const Type = types.Type;
const StructShape = context.StructShape;
const Analyzer = @import("declarations.zig").Analyzer;

// -- what a type carries, and how wide it is --------------------------

/// Whether `of` is the logical `T?` type a weak place may expose. Weak is a
/// storage modifier, never a type constructor: the optional remains the
/// expression type, and its payload must be an ARC object with ordinary
/// identity. Resources deliberately stay strong because their last release
/// performs an effect (close/join).
pub fn weakTarget(self: *const Analyzer, of: Type) bool {
    const held = of.held() orelse return false;
    return switch (held) {
        .heap => |index| switch (self.heap_types.items[index]) {
            .class, .list, .map, .array, .builder => true,
            .handle, .task, .channel => false,
        },
        else => false,
    };
}

/// True for types that transitively hold a heap-backed object: every
/// heap object, including file and task resources, and structs and
/// unions transitively containing one ("object-carrying").  The name
/// says "objects", but it is the broad predicate, not a
/// list/map/array/builder-only test.
/// An array read: `collectStructs` settles every struct's shape
/// once the layouts are known, and struct cycles are rejected
/// before that.  Written function signatures are validated after
/// this pass; they must not make this settled query during layout
/// collection.
pub fn carriesObjects(self: *const Analyzer, of: Type) bool {
    return switch (of) {
        .heap => true,
        // A bound function owns the receiver stored in its value run.  The
        // type does not distinguish bound from unbound functions, so every
        // function follows the carrying path; an unbound receiver is `none`
        // and retain/release are no-ops.
        .function => true,
        .strukt => |layout_index| if (self.structs.items[layout_index].interface)
            true
        else
            self.struct_shapes.items[layout_index].carries,
        // The OR over the members' fields (docs/UNION.md D9): the
        // predicate is static and type-level, so `Json` carries
        // objects unconditionally and `Json.number` pays the verb
        // anyway — S27's own rule, stated there and priced in the
        // memo.
        .variant => |index| self.variant_shapes.items[index].carries,
        // A `list[T]?` holding an object owns it exactly as the
        // unwrapped type would; holding `none` owns nothing (S43),
        // and every ownership walk already no-ops on absence.
        .optional => |payload| carriesObjects(self, payload.asType()),
        else => false,
    };
}

/// What the one type-graph walk can be asked to look for.  Asked by
/// the worker boundary and by nothing else that needs to see through a
/// container — *is one of these anywhere in this type*.
pub const Carried = enum {
    /// A class handle belongs to one Runtime object table. It has shared
    /// identity and is never rebuilt as a worker value snapshot.
    class,
    /// A function value cannot cross a worker boundary because its code
    /// identity is local to one compiled module/runtime.  The type cannot
    /// say whether a value is bound, so the boundary refuses the type — and
    /// since a function can sit in a field or element, the question has to
    /// see through those.
    function,
    /// A weak handle names a row in one Runtime's object table. Copying it
    /// to a worker would make the index/generation pair refer to a different
    /// table and could silently attach to an unrelated object.
    weak,
    /// A resource — a handle, a task, a channel — belongs to the
    /// machinery that made it.  A channel element type asks this: a
    /// value sent through a channel may not carry one (a channel
    /// itself crosses only whole, as a spawn argument).
    resource,
};

/// Whether `of` reaches something of `sought` anywhere in its type
/// graph.
///
/// This is an iterative graph walk, not a recursive type query.  A
/// source program may legitimately make `Node` contain
/// `list[Node]`: the container makes the value's size finite, but it
/// also makes the type graph cyclic.  The two visited tables keep
/// that cycle, and shared subgraphs, linear in the number of layouts
/// and interned heap shapes rather than in the number of paths.
pub fn carries(self: *const Analyzer, of: Type, sought: Carried) Error!bool {
    const seen_structs = try self.temporary.alloc(bool, self.structs.items.len);
    defer self.temporary.free(seen_structs);
    @memset(seen_structs, false);

    const seen_heaps = try self.temporary.alloc(bool, self.heap_types.items.len);
    defer self.temporary.free(seen_heaps);
    @memset(seen_heaps, false);

    const seen_variants = try self.temporary.alloc(bool, self.variants.items.len);
    defer self.temporary.free(seen_variants);
    @memset(seen_variants, false);

    var pending: std.ArrayList(Type) = .empty;
    defer pending.deinit(self.temporary);
    try pending.append(self.temporary, of);

    while (pending.items.len != 0) {
        const current = pending.pop().?;
        switch (current) {
            .optional => |payload| try pending.append(self.temporary, payload.asType()),
            .strukt => |layout| {
                if (seen_structs[layout]) continue;
                seen_structs[layout] = true;
                if (self.structs.items[layout].interface and sought == .function) return true;
                for (self.structs.items[layout].fields) |field| {
                    if (field.weak and sought == .weak) return true;
                    try pending.append(self.temporary, field.field_type);
                }
            },
            .heap => |index| {
                if (seen_heaps[index]) continue;
                seen_heaps[index] = true;
                switch (self.heap_types.items[index]) {
                    .class => if (sought == .class) return true,
                    .channel => |element| {
                        if (sought == .resource) return true;
                        try pending.append(self.temporary, element);
                    },
                    .list => |element| try pending.append(self.temporary, element),
                    .map => |pair| {
                        try pending.append(self.temporary, pair.key);
                        try pending.append(self.temporary, pair.value);
                    },
                    .array => |shape| try pending.append(self.temporary, shape.element),
                    .builder => {},
                    .handle, .task => if (sought == .resource) return true,
                }
            },
            .variant => |index| {
                if (seen_variants[index]) continue;
                seen_variants[index] = true;
                for (self.variants.items[index].members) |member| {
                    for (member.fields) |field| {
                        try pending.append(self.temporary, field.field_type);
                    }
                }
            },
            .function => if (sought == .function) return true,
            .none,
            .boolean,
            .u8,
            .u16,
            .u32,
            .u64,
            .i8,
            .i16,
            .i32,
            .i64,
            .f16,
            .f32,
            .f64,
            .char,
            .str,
            .bytes,
            .foreign,
            .enumeration,
            => {},
        }
    }
    return false;
}

/// What `==` can meet on its way down a value that it has no answer
/// for, and the part of the type that answers to it.
pub const Incomparable = struct {
    pub const Reason = enum {
        /// A function value is the function it names *and* the receiver
        /// it may carry, and its type cannot say which — so two values
        /// of one method with different receivers would compare equal
        /// (docs/BINDING.md D6).
        function,
        /// An existential's concrete type and payload are deliberately
        /// erased, so field-by-field value equality has no stable meaning.
        interface,
        /// `match` is the only door into a union (docs/UNION.md D16):
        /// an inactive payload slot holds a different shape on each
        /// side, so a run-for-run comparison is not even well formed.
        variant,
        /// Weak storage is compared through its public optional snapshot,
        /// not by the hidden row/generation pair. A containing value has no
        /// stable field-by-field equality without performing upgrades.
        weak,
    };

    reason: Reason,
    /// The part of the compared type the reason belongs to — the
    /// operand type itself when the operand is the problem, and a
    /// field of it otherwise, so the sentence can name both.
    part: Type,
};

/// What comparing two values of `of` would reach that `==` has no
/// answer for, or null when the comparison means what it says.
///
/// **This walk stops where `==` stops, which is why it is not
/// `carries`.**  The worker boundary asks what a value would *carry*
/// if its whole graph moved, so its walk goes through a container.
/// Equality never does: `runtime/operators.zig` compares an object
/// handle by identity and never reads what is inside it, so
/// `struct Row: cells: list[Button]` compares two handles and is a
/// perfectly honest `==` even though a `Button` holds a function
/// value.  Refusing that would be a false refusal, so the frontier is
/// the value's own run — struct fields, union runs, optional payloads
/// — and an object handle ends it.
///
/// Iterative and visited-checked for the same reason `carries` is: a
/// `struct Node: next: Node?` makes the *type* graph cyclic without
/// making any value infinite, and the walk must stay linear.  Visited
/// in queue order, so the part it names is the first one a reader
/// would find reading the declaration top to bottom.
pub fn incomparablePart(self: *const Analyzer, of: Type) Error!?Incomparable {
    // Every scalar, every string and every object handle compares by
    // itself, so the overwhelmingly common `==` allocates nothing.
    switch (of) {
        .strukt, .variant, .function, .optional => {},
        else => return null,
    }

    const seen_structs = try self.temporary.alloc(bool, self.structs.items.len);
    defer self.temporary.free(seen_structs);
    @memset(seen_structs, false);

    var pending: std.ArrayList(Type) = .empty;
    defer pending.deinit(self.temporary);
    try pending.append(self.temporary, of);

    var next: usize = 0;
    while (next < pending.items.len) : (next += 1) {
        // Bound before the arms run: appending inside one may move the
        // backing array, and a capture into it would then be stale.
        const current = pending.items[next];
        switch (current) {
            .function => return .{ .reason = .function, .part = current },
            .variant => return .{ .reason = .variant, .part = current },
            .optional => |payload| try pending.append(self.temporary, payload.asType()),
            .strukt => |layout| {
                if (seen_structs[layout]) continue;
                seen_structs[layout] = true;
                if (self.structs.items[layout].interface) {
                    return .{ .reason = .interface, .part = current };
                }
                for (self.structs.items[layout].fields) |field| {
                    if (field.weak) return .{ .reason = .weak, .part = field.field_type };
                    try pending.append(self.temporary, field.field_type);
                }
            },
            // An object compares by identity, so nothing inside it is
            // read; every other type compares as itself.
            .heap,
            .none,
            .boolean,
            .u8,
            .u16,
            .u32,
            .u64,
            .i8,
            .i16,
            .i32,
            .i64,
            .f16,
            .f32,
            .f64,
            .char,
            .str,
            .bytes,
            .foreign,
            .enumeration,
            => {},
        }
    }
    return null;
}

/// True for types that carry *storage* — a string's bytes, a
/// struct's field run — as opposed to objects (docs/STRINGS.md).
///
/// Deliberately not `carriesObjects`, and deliberately not wired to
/// it.  This predicate drives release emission and nothing else:
/// widening `carriesObjects` to Strings would make `xs.append(name)`
/// demand `give name` under S21, which is a language change.  A
/// string takes no verbs (S32) and still gets reclaimed, which is
/// the whole point.
pub fn ownsStorage(self: *const Analyzer, of: Type) bool {
    return switch (of) {
        // A struct owns its field run whatever is in it, so this
        // needs no shape lookup — an all-i64 struct still has a
        // run to give back.  A union value is a run whose slot 0
        // is the tag, and owns it exactly the same way
        // (docs/UNION.md D8, D9).
        // A function value owns the two-slot run that holds the
        // function it names and the receiver it carries, the same way
        // and for the same reason (docs/BINDING.md D12).
        .str, .bytes, .strukt, .variant, .function => true,
        .optional => |payload| ownsStorage(self, payload.asType()),
        else => false,
    };
}

/// How many values a type flattens to: one, unless it is a struct
/// that nests others.
///
/// **An optional answers one whatever its payload is, and that is
/// deliberate.**  The two arms look inconsistent — `Big` flattens
/// and `Big?` does not, for the same data — and the difference is
/// the point: this counts what a value of the type
/// *unconditionally* costs, and an optional's payload is not
/// unconditional.  `zeroOf` is the proof, because it is what the
/// count predicts: it recurses through a struct field emitting an
/// instruction per leaf, and stops dead at an optional one, whose
/// zero is a single `none`.  Measured, with a struct of two struct
/// fields per level: twelve levels is 12,341 MIR instructions and
/// sixty levels of the optional spelling is 201.
///
/// Flattening optionals too is not available even in principle:
/// the shape walk closes a layout only after the layouts it
/// contains, and `struct Node: next: Node?` has no such order.  It
/// would have to be reported as a cycle — destroying the fix the
/// cycle diagnostic itself prescribes, and with it the only way to
/// write a recursive structure.  Flattening *neither* was the other
/// candidate and is worse than wrong: with `.strukt` answering one,
/// the bound never fires, and ninety lines of source took 2.76 GB
/// and 1.6 s to check.
pub fn valueCount(self: *const Analyzer, of: Type) u32 {
    return switch (of) {
        .strukt => |layout_index| if (self.structs.items[layout_index].interface)
            1
        else
            self.struct_shapes.items[layout_index].values,
        .variant => |index| self.variant_shapes.items[index].values,
        else => 1,
    };
}

// -- the containment graph: the cycles it finds and the shapes it sums --

/// A struct or union containing itself (directly or through
/// another) would have no finite value; and what every one carries
/// and costs is settled in the same walk (docs/UNION.md D12 —
/// unions join the same graph as structs, every member counted).
/// Runs after `settleVariantMembers`, because the graph's edges
/// are the resolved field types.
pub fn settleTypeShapes(self: *Analyzer) Error!void {
    const cyclic = try self.temporary.alloc(bool, self.structs.items.len + self.variants.items.len);
    defer self.temporary.free(cyclic);
    @memset(cyclic, false);
    try settleStructGraph(self, cyclic);
    try reportStructCycles(self, cyclic);
    try refuseIndirectZeroCycles(self);

    for (0..self.structs.items.len) |index| {
        if (self.interfaceForLayout(@intCast(index)) != null) continue;
        if (cyclic[index]) continue;
        const info = self.struct_decls.items[index];
        self.diagnostics.scope = self.modules[info.module].file;
        if (self.struct_shapes.items[index].values > helpers.max_struct_values) {
            try reportStructTooWide(self, @intCast(index));
        }
    }
    for (0..self.variants.items.len) |index| {
        if (cyclic[self.structs.items.len + index]) continue;
        const info = self.variant_decls.items[index];
        self.diagnostics.scope = self.modules[info.module].file;
        if (self.variant_shapes.items[index].values > helpers.max_struct_values) {
            try self.fail(
                "luce.sema.union",
                info.declaration.span,
                "union {s} always holds more than {d} values once its largest member is counted; bulk data belongs in a list, map, or array, which is one reference",
                .{ self.variants.items[index].name, helpers.max_struct_values },
            );
        }
    }
    self.diagnostics.scope = source_mod.root_file;
}

/// One step of a containment chain: a combined-graph node, and the
/// field of it that holds the next node along — for a union, the
/// member the field belongs to travels beside it.
const ChainStep = struct { node: u32, member: u32, field: u32 };

/// The struct is past `max_struct_values`, said in terms of what
/// the bound actually bounds.
///
/// It bounds what a value of this type *unconditionally* costs to
/// bring into existence — `zeroOf` emits one instruction per
/// counted value, and a folded constant is re-emitted at every use
/// site — which is why `valueCount` flattens a struct field and
/// stops at an optional one.  That is not a quirk of the counter:
/// a plain field's payload is part of what the struct *is*, and an
/// optional field's payload is a separate value that starts absent
/// and arrives only when a program builds one.  So this check and
/// the cycle check above are the same rule at two scales — a
/// struct's unconditional expansion must be finite, and small —
/// and `?` is what turns "must hold" into "may hold" in both.
/// The old wording said "expands to N values", which reads as a
/// claim about the data and left the reader no way to discover
/// that `?` is an answer here exactly as it is for a cycle.
///
/// The caret goes on the widest struct field, for the same reason
/// the cycle's goes on the field that opens the loop: that is the
/// line that gets edited.  A struct that is too wide from its own
/// scalar fields has no such field to name, and gets the shorter
/// sentence rather than a misleading one.
/// A union's zero is its first member with every payload field at its
/// own zero (docs/UNION.md D13) — which is a *construction*, and for
/// an indirect union it recurses into the first member's fields.  A
/// first member that reaches its own union again through value fields
/// would make that construction infinite, so it is refused here, with
/// the fix in the sentence: a leaf member first.  Only the zero graph
/// is walked — a struct expands every field, a union only its first
/// member — because only the zero construction recurses that way.
fn refuseIndirectZeroCycles(self: *Analyzer) Error!void {
    const count = self.structs.items.len + self.variants.items.len;
    if (count == 0) return;
    const visiting = try self.temporary.alloc(u8, count);
    defer self.temporary.free(visiting);
    for (self.variants.items, 0..) |declared, index| {
        if (!declared.indirect) continue;
        @memset(visiting, 0);
        if (!zeroWalkCycles(self, @intCast(self.structs.items.len + index), visiting)) continue;
        const info = self.variant_decls.items[index];
        self.diagnostics.scope = self.modules[info.module].file;
        try self.fail(
            "luce.sema.union",
            info.declaration.span,
            "union {s}'s first member holds the union itself, and the first member is the union's zero; declare a leaf member first",
            .{declared.name},
        );
    }
    self.diagnostics.scope = source_mod.root_file;
}

/// True when the zero construction rooted at `node` re-enters a node
/// already on the walk.  0 unvisited, 1 on the path, 2 done.
fn zeroWalkCycles(self: *const Analyzer, node: u32, visiting: []u8) bool {
    if (visiting[node] == 1) return true;
    if (visiting[node] == 2) return false;
    visiting[node] = 1;
    defer visiting[node] = 2;
    if (node < self.structs.items.len) {
        for (self.structs.items[node].fields) |field| {
            if (graphNode(self, field.field_type)) |held| {
                if (zeroWalkCycles(self, held, visiting)) return true;
            }
        }
        return false;
    }
    const declared = self.variants.items[node - self.structs.items.len];
    if (declared.members.len == 0) return false;
    for (declared.members[0].fields) |field| {
        if (graphNode(self, field.field_type)) |held| {
            if (zeroWalkCycles(self, held, visiting)) return true;
        }
    }
    return false;
}

fn reportStructTooWide(self: *Analyzer, index: u32) Error!void {
    const layout = self.structs.items[index];

    // The widest struct field, which is the one worth naming.  A
    // tie goes to the first, so the message is deterministic.
    var widest: ?struct { name: []const u8, of: Type, values: u32 } = null;
    for (layout.fields) |field| {
        if (field.field_type != .strukt) continue;
        const values = valueCount(self, field.field_type);
        if (widest) |found| {
            if (values <= found.values) continue;
        }
        widest = .{ .name = field.name, .of = field.field_type, .values = values };
    }

    const found = widest orelse return self.fail(
        "luce.sema.struct",
        self.struct_decls.items[index].declaration.span,
        "struct {s} always holds more than {d} values; bulk data belongs in a list, map, or array, which is one reference",
        .{ layout.name, helpers.max_struct_values },
    );
    try self.fail(
        "luce.sema.struct",
        fieldSpan(self, index, found.name),
        "struct {s} always holds more than {d} values once its nested structs are counted; {s} is {s}, which is {d} of them on its own; write {s}: {s}? to hold those only when they are there, or move bulk data into a list, map, or array, which is one reference",
        .{
            layout.name,
            helpers.max_struct_values,
            found.name,
            try self.typeName(found.of),
            found.values,
            found.name,
            try self.typeName(found.of),
        },
    );
}

/// One diagnostic per cycle, naming the chain that closes it.
///
/// `cyclic` marks every layout *on* a cycle, which for
/// `struct A: b: B` with `struct B: a: A` is both of them — and a
/// report per marked layout said "struct A contains itself" and
/// "struct B contains itself": twice, and false both times.
/// Neither contains itself.  Together they contain each other,
/// which is one mistake with one fix, so it gets one message that
/// walks the loop the reader has to break.
///
/// The chain is the shortest walk from a layout back to itself,
/// breadth-first over the combined graph's fields — a union's
/// members' payload fields beside a struct's own — and confined to
/// nodes that are on a cycle.  The caret goes on the field that
/// opens it, never the declaration keyword, because the field is
/// the line that gets edited — and `T?` is the edit, because a
/// value that may be absent is where the recursion stops
/// (docs/LANGUAGE.md, docs/UNION.md D12).
fn reportStructCycles(self: *Analyzer, cyclic: []const bool) Error!void {
    const count = self.structs.items.len + self.variants.items.len;
    const unvisited = std.math.maxInt(u32);

    const reported = try self.temporary.alloc(bool, count);
    defer self.temporary.free(reported);
    @memset(reported, false);
    const came_from = try self.temporary.alloc(u32, count);
    defer self.temporary.free(came_from);
    const came_via = try self.temporary.alloc(u32, count);
    defer self.temporary.free(came_via);
    const came_member = try self.temporary.alloc(u32, count);
    defer self.temporary.free(came_member);

    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(self.temporary);
    var chain: std.ArrayList(ChainStep) = .empty;
    defer chain.deinit(self.temporary);
    var written: std.ArrayList(u8) = .empty;
    defer written.deinit(self.temporary);

    for (0..count) |start_index| {
        const start: u32 = @intCast(start_index);
        if (!cyclic[start] or reported[start]) continue;

        // Breadth-first from `start`, stopping at the first edge
        // that points back at it: the first such edge found closes
        // the shortest cycle through `start`.
        @memset(came_from, unvisited);
        came_from[start] = start; // visited; never re-entered
        queue.clearRetainingCapacity();
        try queue.append(self.temporary, start);
        var closing: ?ChainStep = null;
        var head: usize = 0;
        search: while (head < queue.items.len) : (head += 1) {
            const node = queue.items[head];
            var cursor: GraphStep = .{ .node = node };
            while (containedNodeAt(self, &cursor)) |held| {
                // The cursor has already moved past the field it
                // just answered from, so the edge is one back.
                const edge: ChainStep = .{
                    .node = node,
                    .member = cursor.member,
                    .field = cursor.field - 1,
                };
                if (held == start) {
                    closing = edge;
                    break :search;
                }
                if (!cyclic[held] or came_from[held] != unvisited) continue;
                came_from[held] = node;
                came_member[held] = edge.member;
                came_via[held] = edge.field;
                try queue.append(self.temporary, held);
            }
        }
        // `start` is marked cyclic, so an edge back to it exists.
        const closed = closing orelse continue;

        // Walk the parent links back to `start`, then turn the
        // chain around so it reads the way the source does.
        chain.clearRetainingCapacity();
        try chain.append(self.temporary, closed);
        var cursor = closed.node;
        while (cursor != start) {
            const parent = came_from[cursor];
            try chain.append(self.temporary, .{
                .node = parent,
                .member = came_member[cursor],
                .field = came_via[cursor],
            });
            cursor = parent;
        }
        std.mem.reverse(ChainStep, chain.items);
        for (chain.items) |step| reported[step.node] = true;

        written.clearRetainingCapacity();
        for (chain.items, 0..) |step, position| {
            if (position != 0) {
                try written.appendSlice(self.temporary, ", ");
                if (position + 1 == chain.items.len) try written.appendSlice(self.temporary, "and ");
            }
            const field = chainField(self, step);
            try written.print(self.temporary, "{s} is {s}", .{
                try chainPlace(self, step),
                try self.typeName(field.field_type),
            });
        }

        const opening = chain.items[0];
        const opening_field = chainField(self, opening);
        self.diagnostics.scope = self.modules[nodeModule(self, opening.node)].file;
        try self.fail(
            if (start < self.structs.items.len) "luce.sema.struct" else "luce.sema.union",
            chainSpan(self, opening),
            "{s} {s} contains itself: {s}; a {s} is a value, so write {s}: {s}? to let the chain end at absence",
            .{
                nodeKind(self, start),
                nodeName(self, start),
                written.items,
                nodeKind(self, start),
                opening_field.name,
                try self.typeName(opening_field.field_type),
            },
        );
    }
}

/// The declaring module of one combined-graph node.
fn nodeModule(self: *const Analyzer, node: u32) usize {
    if (node < self.structs.items.len) return self.struct_decls.items[node].module;
    return self.variant_decls.items[node - self.structs.items.len].module;
}

/// The declaration keyword of one combined-graph node, for a
/// sentence: `struct` or `union`, as the reader wrote it.
fn nodeKind(self: *const Analyzer, node: u32) []const u8 {
    return if (node < self.structs.items.len) "struct" else "union";
}

fn nodeName(self: *const Analyzer, node: u32) []const u8 {
    if (node < self.structs.items.len) return self.structs.items[node].name;
    return self.variants.items[node - self.structs.items.len].name;
}

/// The field one chain step names — a struct's own, or a union
/// member's payload field.
fn chainField(self: *const Analyzer, step: ChainStep) types.StructField {
    if (step.node < self.structs.items.len) {
        return self.structs.items[step.node].fields[step.field];
    }
    const declared = self.variants.items[step.node - self.structs.items.len];
    return declared.members[step.member].fields[step.field];
}

/// One chain step as a reader would spell it: `Node.next` for a
/// struct field, `Json.array.items` for a union member's.
fn chainPlace(self: *Analyzer, step: ChainStep) Error![]const u8 {
    if (step.node < self.structs.items.len) {
        const layout = self.structs.items[step.node];
        return std.fmt.allocPrint(self.arena, "{s}.{s}", .{
            layout.name,
            layout.fields[step.field].name,
        });
    }
    const declared = self.variants.items[step.node - self.structs.items.len];
    const member = declared.members[step.member];
    return std.fmt.allocPrint(self.arena, "{s}.{s}.{s}", .{
        declared.name,
        member.name,
        member.fields[step.field].name,
    });
}

/// Where a chain step's field is written in its own source.
fn chainSpan(self: *const Analyzer, step: ChainStep) Span {
    const field = chainField(self, step);
    if (step.node < self.structs.items.len) {
        return fieldSpan(self, step.node, field.name);
    }
    const info = self.variant_decls.items[step.node - self.structs.items.len];
    const member = self.variants.items[step.node - self.structs.items.len].members[step.member];
    for (info.declaration.members) |written| {
        if (!std.mem.eql(u8, written.name, member.name)) continue;
        for (written.fields) |declared| {
            if (std.mem.eql(u8, declared.name, field.name)) return declared.span;
        }
        return written.span;
    }
    return info.declaration.span;
}

/// Where a layout's field is written in its own source.  Layout
/// fields are a subset of declared ones — a duplicate or an
/// unresolvable type is reported and dropped — so the match is by
/// name, and the declaration stands in if it somehow fails.
pub fn fieldSpan(self: *const Analyzer, layout: u32, name: []const u8) Span {
    const declaration = self.struct_decls.items[layout].declaration;
    for (declaration.fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field.span;
    }
    return declaration.span;
}

/// One pass over the containment graph — structs and unions in one
/// node space, structs first — marking every layout on a cycle and
/// filling in the shape of every one that is not (docs/UNION.md
/// D12: only one member is ever live, but every member is an edge,
/// so a member that contains the union makes it infinite whichever
/// member it is).
///
/// This is Tarjan's strongly connected components, written with an
/// explicit stack.  Both jobs were recursive one-question-at-a-time
/// walks before, and both were exponential: asking "does this
/// struct contain an object" or "does it contain itself" re-walked
/// every *path* through the graph, so a struct with two struct
/// fields doubled the work per level — twenty levels of that is a
/// million walks, from forty lines of source, per question.  A
/// component with more than one member (or a layout naming itself)
/// is a cycle; everything else closes after the layouts it
/// contains, which is exactly when its shape can be summed.
fn settleStructGraph(self: *Analyzer, cyclic: []bool) Error!void {
    const struct_count = self.structs.items.len;
    const count = struct_count + self.variants.items.len;
    try self.struct_shapes.appendNTimes(self.temporary, .{ .values = 1 }, struct_count);
    try self.variant_shapes.appendNTimes(self.temporary, .{ .values = 1 }, self.variants.items.len);
    if (count == 0) return;

    const unvisited = std.math.maxInt(u32);
    const order = try self.temporary.alloc(u32, count);
    defer self.temporary.free(order);
    const lowest = try self.temporary.alloc(u32, count);
    defer self.temporary.free(lowest);
    const open = try self.temporary.alloc(bool, count);
    defer self.temporary.free(open);
    @memset(order, unvisited);
    @memset(open, false);

    // Tarjan's component stack, and the explicit depth-first one.
    var pending: std.ArrayList(u32) = .empty;
    defer pending.deinit(self.temporary);
    var path: std.ArrayList(GraphStep) = .empty;
    defer path.deinit(self.temporary);

    var next_order: u32 = 0;
    for (0..count) |root| {
        if (order[root] != unvisited) continue;
        order[root] = next_order;
        lowest[root] = next_order;
        next_order += 1;
        open[root] = true;
        try pending.append(self.temporary, @intCast(root));
        try path.append(self.temporary, .{ .node = @intCast(root) });

        while (path.items.len != 0) {
            // `step` points into `path`, which the descent below
            // may grow: everything read through it is read before
            // that append, and nothing is read after.
            const step = &path.items[path.items.len - 1];
            const node = step.node;
            if (containedNodeAt(self, step)) |held| {
                if (held == node) cyclic[node] = true;
                if (order[held] == unvisited) {
                    order[held] = next_order;
                    lowest[held] = next_order;
                    next_order += 1;
                    open[held] = true;
                    try pending.append(self.temporary, held);
                    try path.append(self.temporary, .{ .node = held });
                } else if (open[held]) {
                    lowest[node] = @min(lowest[node], order[held]);
                }
                continue;
            }

            // Every field visited: this node closes.  The layouts
            // it holds are either closed (their shapes are final)
            // or still open, which means a cycle the component
            // check below is about to catch.
            if (node < struct_count) {
                self.struct_shapes.items[node] = sumShape(self, node);
            } else {
                self.variant_shapes.items[node - struct_count] =
                    sumVariantShape(self, @intCast(node - struct_count));
            }
            _ = path.pop();
            if (path.items.len != 0) {
                const parent = path.items[path.items.len - 1].node;
                lowest[parent] = @min(lowest[parent], lowest[node]);
            }
            if (lowest[node] != order[node]) continue;

            // The root of a component: everything pushed at or
            // after it is a member.  More than one member means
            // they hold each other, so none has a finite value.
            var first = pending.items.len;
            while (pending.items[first - 1] != node) first -= 1;
            first -= 1;
            const members = pending.items[first..];
            for (members) |member| open[member] = false;
            if (members.len > 1) {
                for (members) |member| cyclic[member] = true;
            }
            pending.shrinkRetainingCapacity(first);
        }
    }
    for (cyclic, 0..) |on_cycle, index| {
        if (!on_cycle) continue;
        if (index < struct_count) {
            self.struct_shapes.items[index] = .{ .values = 1 };
        } else {
            self.variant_shapes.items[index - struct_count] = .{ .values = 1 };
        }
    }
}

/// One node of the combined containment graph with the cursor of
/// the depth-first walk over its fields: structs advance `field`
/// alone, unions advance `member` and `field` together, so a
/// resumed scan never re-reads a field it already passed.
const GraphStep = struct { node: u32, member: u32 = 0, field: u32 = 0 };

/// The next combined-graph node one of the step's fields names,
/// advancing the cursor past it, or null once the fields run out.
fn containedNodeAt(self: *const Analyzer, step: *GraphStep) ?u32 {
    if (step.node < self.structs.items.len) {
        const fields = self.structs.items[step.node].fields;
        while (step.field < fields.len) {
            const held = fields[step.field].field_type;
            step.field += 1;
            if (graphNode(self, held)) |node| return node;
        }
        return null;
    }
    const declared = self.variants.items[step.node - self.structs.items.len];
    // An indirect union's payloads live behind a box (docs/UNION.md
    // D20): any containment chain entering one is finite, so it
    // contributes no edges — which is exactly what lets a member hold
    // the union itself.
    if (declared.indirect) return null;
    const members = declared.members;
    while (step.member < members.len) {
        const fields = members[step.member].fields;
        while (step.field < fields.len) {
            const held = fields[step.field].field_type;
            step.field += 1;
            if (graphNode(self, held)) |node| return node;
        }
        step.member += 1;
        step.field = 0;
    }
    return null;
}

/// The combined-graph node a field type expands into, or null for
/// a type that stops the walk — a container is a handle, an
/// optional stops at absence, and both are the prescribed fixes.
fn graphNode(self: *const Analyzer, of: Type) ?u32 {
    return switch (of) {
        .strukt => |index| index,
        .variant => |index| @intCast(self.structs.items.len + index),
        else => null,
    };
}

/// Sum one layout's shape from its fields' — valid only once every
/// struct field's own shape is final, which is what the closing
/// order above guarantees.
fn sumShape(self: *const Analyzer, layout: u32) StructShape {
    var shape: StructShape = .{};
    for (self.structs.items[layout].fields) |field| {
        if (carriesObjects(self, field.field_type)) shape.carries = true;
        shape.values +|= valueCount(self, field.field_type);
    }
    shape.values = @min(shape.values, helpers.max_struct_values + 1);
    return shape;
}

/// Sum one union's shape from its members' (docs/UNION.md D9,
/// D12): `carries` is the OR over every member's fields — the
/// predicate is type-level, and the compiler does not know which
/// member a value holds — and the expansion is 1 for the tag plus
/// the *largest* member's, because only one member is ever live.
fn sumVariantShape(self: *const Analyzer, index: u32) StructShape {
    // An indirect value is [tag, box] whatever its members hold, and
    // the box is an object reference, so the value always carries.
    if (self.variants.items[index].indirect)
        return .{ .values = 2, .carries = true };
    var shape: StructShape = .{ .values = 0 };
    var widest: u32 = 0;
    for (self.variants.items[index].members) |member| {
        var member_values: u32 = 0;
        for (member.fields) |field| {
            if (carriesObjects(self, field.field_type)) shape.carries = true;
            member_values +|= valueCount(self, field.field_type);
        }
        widest = @max(widest, member_values);
    }
    shape.values = @min(1 +| widest, helpers.max_struct_values + 1);
    return shape;
}
