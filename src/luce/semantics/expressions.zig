//! The expression forms, one at a time: what each one means, what it
//! is typed as, and what it records.
//!
//! The ownership verbs (`give`, `copy`), the constructors (`new`, the
//! list and map literals), the accessors (index, slice, field, enum
//! and variant members), and the operators — arithmetic, comparison,
//! the exact compares, the absence tests, `??`, `and`/`or`, and the
//! unary forms.  What is *not* here is the dispatch that reaches them:
//! `lowerExpressionInner` stays on the spine, because it is the walk's
//! one door and it reads as the map of this file.
//!
//! A file because these are the leaves — each arm takes the walker,
//! answers a `Typed`, and knows nothing of any other arm.

const std = @import("std");
const source_mod = @import("../source.zig");
const ast = @import("../parse.zig").ast;
const types = @import("../support/types.zig");
const mir = @import("../mir.zig");
const helpers = @import("helpers.zig");
const nodes = @import("../hir.zig").nodes;
const effects = @import("effects.zig");
const context = @import("context.zig");
const ConstantValue = context.ConstantValue;
const Error = context.Error;
const Span = source_mod.Span;
const Type = types.Type;

const assign = @import("assign.zig");
const builder = @import("builder.zig");
const calls = @import("calls.zig");
const construct = @import("construct.zig");
const flow = @import("flow.zig");
const ledger = @import("ledger.zig");
const recorder = @import("recorder.zig");
const refusals = @import("refusals.zig");
const statements = @import("statements.zig");
const naming = @import("naming.zig");
const resolve = @import("resolve.zig");
const shapes = @import("shapes.zig");
const FunctionBuilder = builder.FunctionBuilder;
const Landing = builder.Landing;
const RecordedOperand = recorder.RecordedOperand;
const Typed = builder.Typed;

/// Every string a folded constant will materialize, interned here
/// rather than where it materializes.
///
/// **The pool's order is check order, and it has to stay that
/// way.**  A `constant_ref` records the constant's index and
/// nothing else, so `hir/lower.zig`'s `materializeConstant` is
/// what finally asks the pool for the strings inside it — and a
/// slot number is baked into the instruction that reads it, so a
/// pool filled in lowering order renumbers every constant a
/// program holds.  Interning is idempotent, so asking here first
/// pins the slot at the moment the walk reaches the use site,
/// which is where the fused walk always pinned it, and the replay
/// then asks for a number it already has.  The recursion is
/// `materializeConstant`'s own, step for step: through an
/// optional's payload, then through a struct's fields in
/// declaration order.
fn preinternConstant(
    self: *FunctionBuilder,
    value: context.ConstantValue,
    value_type: Type,
) Error!void {
    if (value_type == .optional and value != .absent) {
        return preinternConstant(self, value, value_type.optional.asType());
    }
    switch (value) {
        .str => |folded| _ = try self.analyzer.pool.intern(folded),
        .strukt => |folded| {
            const layout = self.analyzer.structs.items[folded.layout];
            for (folded.fields, layout.fields) |field, field_layout| {
                try preinternConstant(self, field, field_layout.field_type);
            }
        },
        .integer, .float, .boolean, .container, .absent => {},
    }
}

/// Inline a folded file-scope constant at this use site; `span` is
/// the use site's, which is what the recorded node points at.
pub fn emitConstant(self: *FunctionBuilder, index: u32, span: Span) Error!?Typed {
    const info = self.analyzer.constant_infos.items[index];
    if (info.state != .ready) return null; // already diagnosed
    try preinternConstant(self, info.value, info.value_type);
    return .{
        .node = try recorder.recordNode(self, .{ .constant_ref = .{
            .constant = index,
            .result = info.value_type,
            .span = span,
        } }),
        .value_type = info.value_type,
    };
}

/// Record a folded constant's node — **the single spelling point
/// for every constant shape**, which is what lets a defaulted
/// argument or field of any shape record without its call site
/// knowing (the batch convention at `recordOperandBatch`).  `span`
/// is the use site's — the call or construction that omitted the
/// value — which is what the recorded node points at; the
/// materialization itself is `hir.lower`'s (`materializeConstant`).
pub fn emitConstantValue(self: *FunctionBuilder, value: ConstantValue, value_type: Type, span: Span) Error!Typed {
    // A present folded payload carries no separate union tag in
    // `ConstantValue`; its optional landing type is the decision.
    // Build the payload at T, then wrap it exactly as ordinary
    // expression lowering does (`fit`'s node ruling included).
    // `.absent` remains the zero value handled below.
    if (value_type == .optional and value != .absent) {
        const payload = try emitConstantValue(self, value, value_type.optional.asType(), span);
        return .{
            .node = try recorder.recordNode(self, .{ .wrap_optional = .{
                .operand = payload.node,
                .result = value_type,
                .span = span,
            } }),
            .value_type = value_type,
        };
    }
    return switch (value) {
        // The width is the constant's own, not the widest of its
        // family: a folded constant carries its value at the
        // family's widest member and its `value_type` says where
        // that value landed (docs/TYPES.md §1).
        .integer => |folded| .{
            .node = try recorder.recordNode(self, .{ .const_integer = .{
                .value = folded,
                .result = value_type,
                .span = span,
            } }),
            .value_type = value_type,
        },
        .float => |folded| .{
            .node = try recorder.recordNode(self, .{ .const_float = .{
                .value = folded,
                .result = value_type,
                .span = span,
            } }),
            .value_type = value_type,
        },
        .boolean => |folded| .{
            .node = try recorder.recordNode(self, .{ .const_boolean = .{
                .value = folded,
                .result = value_type,
                .span = span,
            } }),
            .value_type = value_type,
        },
        .str => |folded| .{
            .node = try recorder.recordNode(self, .{ .const_str = .{
                .constant = try self.analyzer.pool.intern(folded),
                .result = value_type,
                .span = span,
            } }),
            .value_type = value_type,
        },
        .strukt => |folded| blk: {
            const layout = self.analyzer.structs.items[folded.layout];
            const entries = try self.arena().alloc(RecordedOperand, folded.fields.len);
            for (folded.fields, layout.fields, entries, 0..) |field, field_layout, *entry, field_index| {
                const filled = try emitConstantValue(self, field, field_layout.field_type, span);
                ledger.ownedForStore(self, filled);
                entry.* = .{ .node = filled.node, .slot = @intCast(field_index) };
            }
            // A struct default materializes as a built value that
            // owns its run, exactly as a written construction
            // does — and records the same node: layout order is
            // its evaluation order, so the slots are the identity
            // and nothing spills or copies.
            break :blk .{
                .node = try recorder.recordNode(self, .{ .struct_make = .{
                    .layout = folded.layout,
                    .operands = try recorder.recordOperandBatch(self, entries, 0),
                    .result = value_type,
                    .span = span,
                } }),
                .value_type = value_type,
            };
        },
        .container => |row| .{
            .node = try recorder.recordNode(self, .{ .container_ref = .{
                .row = row,
                .result = value_type,
                .span = span,
            } }),
            .value_type = value_type,
        },
        // The typed absence a `T?` place gives a bare `none`: the
        // constant's type is the whole of its value (docs/ARGS.md
        // D9), and it inlines as the same zero `lowerTyped` records.
        .absent => .{
            .node = try recorder.recordNode(self, .{ .absent = .{
                .result = value_type,
                .span = span,
            } }),
            .value_type = value_type,
        },
    };
}

pub fn lowerNew(
    self: *FunctionBuilder,
    new: ast.NewObject,
    as_statement: bool,
    fallible_allowed: bool,
    shape_position: builder.ShapePosition,
) Error!?Typed {
    var object_type: Type = undefined;
    var recorded_dims: []nodes.Operand = &.{};
    if (types.builtinNamed(new.type_name.name) == .array) {
        // A direct construction writes only the element type. Runtime
        // dimension values establish the rank; `_` belongs to an array
        // type annotation or an alias, not beside the values that make it.
        if (new.type_name.arguments.len != 1 or new.type_name.wildcards != 0) {
            try self.fail(
                "luce.sema.container.type",
                new.type_name.span,
                "array construction writes one element type, then its sizes: array[i64](5, 5)",
                .{},
            );
            return null;
        }
        const element = (try resolve.resolveType(self.analyzer, self.module, new.type_name.arguments[0])) orelse return null;
        if (try resolve.refuseOptionalPart(self.analyzer, element, new.type_name.arguments[0], "array element")) {
            return null;
        }
        const dims = (try arrayDimensions(self, new)) orelse return null;
        recorded_dims = (try lowerArrayDimensions(self, new, dims, null)) orelse return null;
        object_type = try resolve.internHeapType(self.analyzer, .{
            .array = .{ .element = element, .rank = @intCast(dims.len) },
        });
    } else {
        object_type = (try resolve.resolveType(self.analyzer, self.module, new.type_name)) orelse return null;
        if (object_type != .heap) {
            if (object_type == .strukt and self.analyzer.interfaceForLayout(object_type.strukt) != null) {
                try self.fail(
                    "luce.sema.interface",
                    new.span,
                    "interfaces cannot be constructed; implement the interface on a struct and pass that struct",
                    .{},
                );
                return null;
            }
            if (object_type == .variant) {
                return construct.failVariantAsCallee(self, new.type_name.name, object_type.variant, new.span);
            }
            try self.fail(
                "luce.sema.new",
                new.span,
                "{s} is a value type and is constructed as {s}(...)",
                .{ try self.analyzer.typeName(object_type), new.type_name.name },
            );
            return null;
        }
        // **A handle is opened, never made** (docs/BYTES.md R5).  A
        // handle with nothing behind it is the one thing this type
        // must never hold, so the only way in is a host door that
        // takes a path — and only standard source can even write the
        // name, so this wall faces the library's own mistakes.
        if (self.analyzer.heap_types.items[object_type.heap] == .handle) {
            try self.fail(
                "luce.sema.new",
                new.span,
                "a handle is opened, not made; a host door answers one [BYTES.md R5]",
                .{},
            );
            return null;
        }
        // And a task is spawned, not made: a task with no worker
        // behind it is the one state *this* type must never hold.
        if (self.analyzer.heap_types.items[object_type.heap] == .task) {
            try self.fail(
                "luce.sema.new",
                new.span,
                "a task is spawned, not made; write spawn f(…)",
                .{},
            );
            return null;
        }
        const descriptor = self.analyzer.heap_types.items[object_type.heap];
        // `new Counter(...)` — the class construction spelling. The
        // shared fork owns memberwise fields, the `init` factory, and
        // visibility, so `new` adds nothing but the reference-identity
        // requirement it exists to state.
        if (descriptor == .class) {
            return calls.lowerNominalConstruct(
                self,
                descriptor.class,
                new.type_name.name,
                new.arguments,
                new.span,
                as_statement,
                fallible_allowed,
                shape_position,
            );
        }
        if (descriptor == .array) {
            const dims = (try arrayDimensions(self, new)) orelse return null;
            recorded_dims = (try lowerArrayDimensions(self, new, dims, descriptor.array.rank)) orelse return null;
        } else if (new.arguments.len != 0) {
            try self.fail(
                "luce.sema.container.type",
                new.span,
                "{s} takes no construction values; write {s}()",
                .{ try self.analyzer.typeName(object_type), try self.analyzer.typeName(object_type) },
            );
            return null;
        }
    }
    return .{
        .node = try recorder.recordNode(self, .{ .new_object = .{
            .heap_type = object_type.heap,
            .operands = recorded_dims,
            .result = object_type,
            .span = new.span,
        } }),
        .value_type = object_type,
    };
}

/// Construct a container whose type is already resolved — the alias
/// call path, where the name arrived through a namespace and
/// re-resolving the written spelling would lose its qualifier.
pub fn lowerResolvedContainer(
    self: *FunctionBuilder,
    object_type: Type,
    written: []const u8,
    arguments: []ast.Argument,
    span: Span,
) Error!?Typed {
    var recorded_dims: []nodes.Operand = &.{};
    const descriptor = self.analyzer.heap_types.items[object_type.heap];
    const synthetic: ast.NewObject = .{
        .type_name = .{ .name = written, .span = span },
        .arguments = arguments,
        .span = span,
    };
    if (descriptor == .array) {
        const dims = (try arrayDimensions(self, synthetic)) orelse return null;
        recorded_dims = (try lowerArrayDimensions(self, synthetic, dims, descriptor.array.rank)) orelse return null;
    } else if (arguments.len != 0) {
        try self.fail(
            "luce.sema.container.type",
            span,
            "{s} takes no construction values; write {s}()",
            .{ try self.analyzer.typeName(object_type), written },
        );
        return null;
    }
    return .{
        .node = try recorder.recordNode(self, .{ .new_object = .{
            .heap_type = object_type.heap,
            .operands = recorded_dims,
            .result = object_type,
            .span = span,
        } }),
        .value_type = object_type,
    };
}

/// Check and record the runtime extents of an array construction.
/// `rank` is known for an alias and absent for direct `new array[T](...)`,
/// whose value count establishes it.
fn lowerArrayDimensions(
    self: *FunctionBuilder,
    new: ast.NewObject,
    dims: []*ast.Expression,
    rank: ?u8,
) Error!?[]nodes.Operand {
    if (dims.len == 0 or dims.len > 4) {
        try self.fail(
            "luce.sema.container.type",
            new.span,
            "array construction takes 1 to 4 dimension sizes: array[i64](5, 5)",
            .{},
        );
        return null;
    }
    if (rank) |expected| {
        if (dims.len != expected) {
            try self.fail(
                "luce.sema.container.type",
                new.span,
                "{s} needs {d} dimension sizes, got {d}",
                .{ new.type_name.name, expected, dims.len },
            );
            return null;
        }
    }
    const run = (try self.lowerOperandsIntoTracking(dims, .nothing)) orelse return null;
    const dimensions = run.values;
    for (dimensions, dims) |dimension, expression| {
        if (!dimension.value_type.eql(.i64)) {
            try self.fail("luce.sema.container.type", expression.span(), "array dimensions are i64", .{});
            return null;
        }
    }
    return @as(?[]nodes.Operand, try recorder.recordOperandRun(self, dimensions, run.copied));
}

/// An array's construction values are positional sizes. A name would
/// be a field of a nominal construction, and an array has none.
fn arrayDimensions(self: *FunctionBuilder, new: ast.NewObject) Error!?[]*ast.Expression {
    for (new.arguments) |argument| {
        if (argument.name != null) {
            try self.fail(
                "luce.sema.container.type",
                argument.span,
                "array sizes are positional: array[i64](5, 5)",
                .{},
            );
            return null;
        }
    }
    const dims = try self.arena().alloc(*ast.Expression, new.arguments.len);
    for (new.arguments, dims) |argument, *slot| slot.* = argument.value;
    return dims;
}

/// `[a, b, c]`.  A list place keeps it a list; a rank-1 array place
/// builds an array whose sole dimension is the written element
/// count.  With no place, the first element decides a list as it
/// always has.
pub fn lowerListLiteral(self: *FunctionBuilder, literal: ast.ListLiteral, wanted_container: ?Type) Error!?Typed {
    var wanted_element: ?Type = null;
    var expected_container: ?Type = null;
    if (wanted_container) |place| {
        const descriptor = self.analyzer.heapOf(place).?;
        switch (descriptor) {
            .list => |element| {
                wanted_element = element;
                expected_container = place;
            },
            .array => |shape| {
                std.debug.assert(shape.rank == 1);
                wanted_element = shape.element;
                expected_container = place;
            },
            .class, .map, .builder, .handle, .task => {},
        }
    }
    if (literal.elements.len == 0 and wanted_element == null) {
        try self.fail(
            "luce.sema.type",
            literal.span,
            "an empty [] needs a list[T] or array[T, _] annotation",
            .{},
        );
        return null;
    }
    // **The elements land on the element type when the place names
    // one.**  A literal has no type until it meets one
    // (docs/TYPES.md §1), and what it meets here is the annotation:
    // without this, `var xs: list[u8] = [1, 2, 3]` reads its
    // three literals at `i32` and is then refused for narrowing
    // nobody wrote. Contextual literal landing makes `list[u8]` occupy
    // one byte per element without an implicit conversion, and the same
    // landing is what `xs.append(1)` uses.
    const landing: Landing = if (wanted_element) |element| places: {
        const places = try self.arena().alloc(Type, literal.elements.len);
        @memset(places, element);
        break :places .{ .places = places };
    } else .nothing;
    const run = (try self.lowerOperandsIntoTracking(literal.elements, landing)) orelse
        return null;
    const elements = run.values;
    const element_type = wanted_element orelse unified: {
        // Without an annotation, the first concrete element supplies the
        // type. Later literals can land there; differently typed concrete
        // values are rejected rather than unified.
        var meeting = elements[0].value_type;
        for (elements[1..]) |element| {
            meeting = Type.unified(meeting, element.value_type) orelse
                break :unified elements[0].value_type;
        }
        break :unified meeting;
    };
    for (elements, literal.elements) |element, expression| {
        if (!element.value_type.eql(element_type)) {
            try self.fail("luce.sema.type", expression.span(), "container elements are all {s}, got {s}", .{
                try self.analyzer.typeName(element_type),
                try self.analyzer.typeName(element.value_type),
            });
            return null;
        }
    }
    const object_type = expected_container orelse
        try resolve.internHeapType(self.analyzer, .{ .list = element_type });
    // The per-element stores are lower's; their adopt-or-copy is
    // the settled park plus the node-kind provenance (coupling
    // #3), decided here by the same ledger walk.
    for (elements) |element| ledger.ownedForStore(self, element);
    return .{
        // One node whichever container the literal landed as: the
        // result type carries the list-or-array decision.
        .node = try recorder.recordNode(self, .{ .list_literal = .{
            .elements = try recorder.recordOperandRun(self, elements, run.copied),
            .result = object_type,
            .span = literal.span,
        } }),
        .value_type = object_type,
    };
}

/// `{key: value, ...}`.  Keys and values are evaluated once in
/// written order.  An annotation supplies both types; otherwise an
/// an unannotated integer key lands on the default `i64`; an annotated
/// or already-typed key keeps any explicit integer width.
pub fn lowerMapLiteral(self: *FunctionBuilder, literal: ast.MapLiteral, wanted_container: ?Type) Error!?Typed {
    std.debug.assert(literal.entries.len != 0); // stage 3 refuses `{}`

    var wanted_key: ?Type = null;
    var wanted_value: ?Type = null;
    var expected_container: ?Type = null;
    if (wanted_container) |place| {
        const descriptor = self.analyzer.heapOf(place).?;
        if (descriptor == .map) {
            wanted_key = descriptor.map.key;
            wanted_value = descriptor.map.value;
            expected_container = place;
        }
    }

    const expressions = try self.arena().alloc(*ast.Expression, literal.entries.len * 2);
    const places = try self.arena().alloc(?Type, expressions.len);
    for (literal.entries, 0..) |entry, index| {
        expressions[index * 2] = entry.key;
        expressions[index * 2 + 1] = entry.value;
        places[index * 2] = wanted_key orelse .i64;
        places[index * 2 + 1] = wanted_value;
    }
    const run = (try self.lowerOperandsIntoTracking(expressions, .{ .maybe_places = places })) orelse return null;
    const lowered = run.values;

    const key_type: Type = wanted_key orelse inferred: {
        const first = lowered[0].value_type;
        if (first == .str) break :inferred .str;
        // An enum key keys by *itself*, not by its number: the whole
        // point is that `{Key.left: …}` stays a `map[Key, V]` and comes
        // back out as a `Key` (docs/ENUMS.md, As built 2026-08-12).
        if (first == .enumeration) break :inferred first;
        if (first.isInteger()) break :inferred first;
        try self.fail("luce.sema.type", literal.entries[0].key.span(), "map keys are an integer, str or an enum, got {s}", .{
            try self.analyzer.typeName(first),
        });
        return null;
    };
    const value_type: Type = wanted_value orelse inferred: {
        var meeting = lowered[1].value_type;
        var at: usize = 3;
        while (at < lowered.len) : (at += 2) {
            meeting = Type.unified(meeting, lowered[at].value_type) orelse
                break :inferred lowered[1].value_type;
        }
        break :inferred meeting;
    };

    for (literal.entries, 0..) |entry, index| {
        const key = lowered[index * 2];
        const value = lowered[index * 2 + 1];
        if (!key.value_type.eql(key_type)) {
            try self.fail("luce.sema.type", entry.key.span(), "map keys are all {s}, got {s}", .{
                try self.analyzer.typeName(key_type),
                try self.analyzer.typeName(key.value_type),
            });
            return null;
        }
        if (!value.value_type.eql(value_type)) {
            try self.fail("luce.sema.type", entry.value.span(), "map values are all {s}, got {s}", .{
                try self.analyzer.typeName(value_type),
                try self.analyzer.typeName(value.value_type),
            });
            return null;
        }
    }

    const object_type = expected_container orelse
        try resolve.internHeapType(self.analyzer, .{ .map = .{ .key = key_type, .value = value_type } });
    // The per-entry stores are lower's; the value stores' decide
    // through the same ledger walk (coupling #3).
    for (literal.entries, 0..) |_, index| {
        ledger.ownedForStore(self, lowered[index * 2 + 1]);
    }
    // The written pairs, each half with its own rewrite flags —
    // keys and values are one interleaved run in the emission.
    const entries = try self.arena().alloc(nodes.Expression.MapLiteral.Entry, literal.entries.len);
    for (entries, 0..) |*entry, index| {
        entry.* = .{
            .key = .{
                .node = lowered[index * 2].node,
                .copied = run.copied[index * 2],
            },
            .value = .{
                .node = lowered[index * 2 + 1].node,
                .copied = run.copied[index * 2 + 1],
            },
        };
    }
    return .{
        .node = try recorder.recordNode(self, .{ .map_literal = .{
            .entries = entries,
            .result = object_type,
            .span = literal.span,
        } }),
        .value_type = object_type,
    };
}

pub fn lowerIndex(self: *FunctionBuilder, index: ast.Index) Error!?Typed {
    const expressions = try self.arena().alloc(*ast.Expression, index.indices.len + 1);
    expressions[0] = index.target;
    @memcpy(expressions[1..], index.indices);
    const run = (try self.lowerOperandsIntoTracking(expressions, .subscripts)) orelse return null;
    const values = run.values;
    const element_type = (try assign.checkIndex(self, values[0].value_type, values[1..], index.span)) orelse return null;
    // The whole read is one operand run, so each position carries
    // its batch rewrites (nodes.Operand).
    const subscripts = try self.arena().alloc(nodes.Operand, values.len - 1);
    for (values[1..], run.copied[1..], subscripts) |value, was_copied, *slot| {
        slot.* = .{
            .node = value.node,
            .copied = was_copied,
        };
    }
    return .{
        .node = try recorder.recordNode(self, .{ .index_get = .{
            .target = .{ .node = values[0].node, .copied = run.copied[0] },
            .indices = subscripts,
            .result = element_type,
            .span = index.span,
        } }),
        .value_type = element_type,
    };
}

pub fn lowerSliceRange(self: *FunctionBuilder, slice: ast.SliceRange) Error!?Typed {
    var whole_sequence: std.ArrayList(*ast.Expression) = .empty;
    defer whole_sequence.deinit(self.temporary());
    try whole_sequence.append(self.temporary(), slice.target);
    if (slice.start) |expression| try whole_sequence.append(self.temporary(), expression);
    if (slice.end) |expression| try whole_sequence.append(self.temporary(), expression);
    const run = (try self.lowerOperandsIntoTracking(whole_sequence.items, .subscripts)) orelse return null;
    const sequence = run.values;
    const target = sequence[0];
    const is_text_sequence = target.value_type == .str or target.value_type == .bytes;
    const descriptor = self.analyzer.heapOf(target.value_type);
    if (!is_text_sequence and (descriptor == null or descriptor.? != .list)) {
        try self.fail("luce.sema.index", slice.span, "{s} cannot be sliced; slices work on list, str, and bytes", .{
            try self.analyzer.typeName(target.value_type),
        });
        return null;
    }
    const lowered_bounds = sequence[1..];
    for (lowered_bounds) |value| {
        if (!value.value_type.eql(.i64)) {
            try self.fail("luce.sema.type", slice.span, "slice bounds are i64", .{});
            return null;
        }
    }
    // A null bound is the defaulted end (nodes.Slice); the 0 and
    // `len` a defaulted bound materializes as are re-derived by
    // lower.
    var at: usize = 1;
    var start_operand: ?nodes.Operand = null;
    if (slice.start != null) {
        start_operand = .{
            .node = sequence[at].node,
            .copied = run.copied[at],
        };
        at += 1;
    }
    var stop_operand: ?nodes.Operand = null;
    if (slice.end != null) {
        stop_operand = .{
            .node = sequence[at].node,
            .copied = run.copied[at],
        };
    }
    return .{
        .node = try recorder.recordNode(self, .{ .slice = .{
            .target = .{
                .node = sequence[0].node,
                .copied = run.copied[0],
            },
            .start = start_operand,
            .stop = stop_operand,
            .result = target.value_type,
            .span = slice.span,
        } }),
        .value_type = target.value_type,
    };
}

/// `Method.stored` — an enum member, as the constant it is
/// (docs/ENUMS.md D3, D8).  Null when the dotted head names no
/// enum, which leaves every other reading of a `.` to the caller.
///
/// The lookup is the head-names-a-declaration path `Struct.func`
/// and `module.name` already travel: a head that a local shadows is
/// a value, a bare head is this module's, and one dotted level
/// reaches an imported enum.
fn enumMemberAccess(self: *FunctionBuilder, field: ast.FieldAccess) Error!MemberAccess {
    const chain = helpers.dottedChain(field.target) orelse return .not_a_member;
    if (self.findLocal(chain.head()) != null) return .not_a_member;

    var written: std.ArrayList(u8) = .empty;
    defer written.deinit(self.temporary());
    var at = chain.count;
    while (at > 0) {
        at -= 1;
        if (written.items.len != 0) try written.append(self.temporary(), '.');
        try written.appendSlice(self.temporary(), chain.parts[at]);
    }
    const spelled = written.items;

    // A bare name is this module's; a dotted one is an import's,
    // and only an imported module may be the head.
    const index = found: {
        if (chain.count == 1) {
            const local = try naming.qualify(self.analyzer, self.prefix, spelled);
            if (self.analyzer.enum_names.get(local)) |index| break :found index;
            if (self.analyzer.alias_names.get(local)) |alias_index| {
                const target = (try resolve.resolveAlias(self.analyzer, self.module, alias_index, field.span)) orelse
                    return .reported;
                if (target == .enumeration) break :found target.enumeration.index;
            }
            // `from geo import Color` binds the bare enum name; the
            // import line already settled reachability.
            if (try naming.memberKey(self.analyzer, self.module, spelled)) |key| {
                if (self.analyzer.enum_names.get(key)) |index| break :found index;
                if (self.analyzer.alias_names.get(key)) |alias_index| {
                    const target = (try resolve.resolveAlias(self.analyzer, self.module, alias_index, field.span)) orelse
                        return .reported;
                    if (target == .enumeration) break :found target.enumeration.index;
                }
            }
            return .not_a_member;
        }
        if (!naming.importsModule(self.analyzer, self.module, chain.head())) return .not_a_member;
        const imported = try self.importedName(spelled);
        if (self.analyzer.enum_names.get(imported)) |index| break :found index;
        if (self.analyzer.alias_names.get(imported)) |alias_index| {
            const target = (try resolve.resolveAlias(self.analyzer, self.module, alias_index, field.span)) orelse
                return .reported;
            if (target == .enumeration) break :found target.enumeration.index;
        }
        return .not_a_member;
    };
    const info = self.analyzer.enum_decls.items[index];
    if (info.declaration.visibility == .private and info.module != self.module) {
        try self.fail("luce.sema.private", field.span, "{s} is private to {s}", .{
            info.declaration.name,
            naming.moduleName(self.analyzer, info.module),
        });
        return .reported;
    }
    const declared = self.analyzer.enums.items[index];
    const of = self.analyzer.enumType(index);
    const member = declared.findMember(field.name) orelse {
        // `Method.deflated()` written without its parentheses is a
        // function of the enum, and it is not a value either
        // (docs/SELF.md); the shared sentence says so.
        const qualified = try std.fmt.allocPrint(self.arena(), "{s}.{s}", .{ declared.name, field.name });
        const spelling = try std.fmt.allocPrint(self.arena(), "{s}.{s}", .{ spelled, field.name });
        if (try refusals.failNotAValue(self, spelling, qualified, field.span)) return .reported;
        try statements.failUnknownMember(self, declared, field.name, field.span);
        return .reported;
    };
    return .{
        .value = .{
            // The resolved member is its number at the enum's own type
            // — MIR's reading exactly (`Type.storage()`), and the
            // member identity is recoverable from value and type, so
            // the constant node is the whole of it.
            .node = try recorder.recordNode(self, .{ .const_integer = .{
                .value = declared.members[member].value,
                .result = of,
                .span = field.span,
            } }),
            .value_type = of,
        },
    };
}

/// What a dotted access turned out to be: not a member of this kind
/// at all, one that was refused and reported, or the member's value.
/// The middle case is why this is not an optional — a name that was
/// already answered must not be lowered a second time as something
/// else, which is how one mistake became two messages.
///
/// Stage 4 asks a dotted name three questions in turn — is it an enum
/// member, a union member, a method bound to its receiver — and each
/// answers with this, so `p.at` that was refused as a bind is never
/// re-read as the field it is not (docs/BINDING.md D4).
pub const MemberAccess = union(enum) {
    not_a_member,
    reported,
    value: Typed,
};

/// `Json.null` — a bare union member, which is a construction with
/// nothing to fill in (docs/UNION.md D4).  Null when the dotted
/// head names no union; a member that carries a payload is refused
/// here naming the fields it wants, because a bare spelling of one
/// is a construction missing everything.
///
/// The lookup is `enumMemberAccess`'s, one table over.
fn variantMemberAccess(self: *FunctionBuilder, field: ast.FieldAccess) Error!MemberAccess {
    const chain = helpers.dottedChain(field.target) orelse return .not_a_member;
    if (self.findLocal(chain.head()) != null) return .not_a_member;

    var written: std.ArrayList(u8) = .empty;
    defer written.deinit(self.temporary());
    var at = chain.count;
    while (at > 0) {
        at -= 1;
        if (written.items.len != 0) try written.append(self.temporary(), '.');
        try written.appendSlice(self.temporary(), chain.parts[at]);
    }
    const spelled = written.items;

    // A bare name is this module's; a dotted one is an import's,
    // and only an imported module may be the head.
    const index = found: {
        if (chain.count == 1) {
            const local = try naming.qualify(self.analyzer, self.prefix, spelled);
            if (self.analyzer.variant_names.get(local)) |index| break :found index;
            if (self.analyzer.alias_names.get(local)) |alias_index| {
                const target = (try resolve.resolveAlias(self.analyzer, self.module, alias_index, field.span)) orelse
                    return .reported;
                if (target == .variant) break :found target.variant;
            }
            // `from geo import Shape` binds the bare union name; the
            // import line already settled reachability.
            if (try naming.memberKey(self.analyzer, self.module, spelled)) |key| {
                if (self.analyzer.variant_names.get(key)) |index| break :found index;
                if (self.analyzer.alias_names.get(key)) |alias_index| {
                    const target = (try resolve.resolveAlias(self.analyzer, self.module, alias_index, field.span)) orelse
                        return .reported;
                    if (target == .variant) break :found target.variant;
                }
            }
            return .not_a_member;
        }
        if (!naming.importsModule(self.analyzer, self.module, chain.head())) return .not_a_member;
        const imported = try self.importedName(spelled);
        if (self.analyzer.variant_names.get(imported)) |index| break :found index;
        if (self.analyzer.alias_names.get(imported)) |alias_index| {
            const target = (try resolve.resolveAlias(self.analyzer, self.module, alias_index, field.span)) orelse
                return .reported;
            if (target == .variant) break :found target.variant;
        }
        return .not_a_member;
    };
    const info = self.analyzer.variant_decls.items[index];
    if (info.declaration.visibility == .private and info.module != self.module) {
        try self.fail("luce.sema.private", field.span, "{s} is private to {s}", .{
            info.declaration.name,
            naming.moduleName(self.analyzer, info.module),
        });
        return .reported;
    }
    const declared = self.analyzer.variants.items[index];
    const member_index = declared.findMember(field.name) orelse {
        // `Shape.area` written without its parentheses is a
        // function of the union, and it is not a value either
        // (docs/SELF.md); the shared sentence says so.
        const qualified = try std.fmt.allocPrint(self.arena(), "{s}.{s}", .{ declared.name, field.name });
        const spelling = try std.fmt.allocPrint(self.arena(), "{s}.{s}", .{ spelled, field.name });
        if (try refusals.failNotAValue(self, spelling, qualified, field.span)) return .reported;
        try statements.failUnknownVariantMember(self, declared, field.name, field.span);
        return .reported;
    };
    const member = declared.members[member_index];
    if (member.fields.len != 0) {
        var wanted: std.ArrayList(u8) = .empty;
        defer wanted.deinit(self.temporary());
        for (member.fields, 0..) |payload, position| {
            if (position != 0) try wanted.appendSlice(self.temporary(), ", ");
            try wanted.print(self.temporary(), "{s} = ...", .{payload.name});
        }
        try self.fail(
            "luce.sema.construct",
            field.span,
            "{s}.{s} carries a payload: write {s}.{s}({s})",
            .{ declared.name, member.name, spelled, member.name, wanted.items },
        );
        return .reported;
    }
    const of: Type = .{ .variant = index };
    return .{
        .value = .{
            // A bare member is a construction with nothing to
            // fill in (D4): the batch is empty, never missing.
            .node = try recorder.recordNode(self, .{ .variant_make = .{
                .variant = index,
                .member = member_index,
                .operands = .{
                    .operands = &.{},
                    .slots = &.{},
                    .borrow_copy = &.{},
                },
                .result = of,
                .span = field.span,
            } }),
            .value_type = of,
        },
    };
}

pub fn lowerField(self: *FunctionBuilder, field: ast.FieldAccess) Error!?Typed {
    // During init, `self.field` names the compiler-owned field slot. There
    // is no receiver object yet: the object is made only at the successful
    // return after all of these slots are established.
    if (self.initializer) |state| {
        if (builder.isBareSelf(field.target)) {
            for (state.fields) |held| {
                if (!std.mem.eql(u8, held.name, field.name)) continue;
                if (held.storage_type.eql(held.value_type)) {
                    return .{
                        .node = try recorder.recordNode(self, .{ .local_get = .{
                            .local = held.local,
                            .result = held.value_type,
                            .span = field.span,
                        } }),
                        .value_type = held.value_type,
                    };
                }
                return .{
                    .node = try recorder.recordNode(self, .{ .narrowed_get = .{
                        .local = held.local,
                        .payload = held.value_type,
                        .result = held.value_type,
                        .span = field.span,
                    } }),
                    .value_type = held.value_type,
                };
            }
            // Validation already named the unknown stored field.
            return null;
        }
    }
    // A dotted chain whose head is a bare declaration name is a
    // namespace, exactly as it is in front of a call
    // (`methodNamespace`).  Without this the whole access falls
    // through to lowering the head as a value, which reports
    // "unknown name math" about an import the compiler just
    // checked.  Locals shadow nothing, so a head that names a
    // local is always a value.
    // `Method.stored`, `zip.Method.stored` — a member, which is a
    // constant of the enum's own type and namespaced always
    // (docs/ENUMS.md D3, D8).  It is asked first because it is the
    // one dotted form whose head names a *type* and whose answer is
    // a value; everything below reads a field of one.
    switch (try enumMemberAccess(self, field)) {
        .not_a_member => {},
        .reported => return null,
        .value => |member| return member,
    }
    // `Json.null`, `zip.Shape.circle` — a union member, which is a
    // construction of the member with nothing to fill in
    // (docs/UNION.md D4).  Asked beside the enum form, because it
    // is the same dotted shape one table over.
    switch (try variantMemberAccess(self, field)) {
        .not_a_member => {},
        .reported => return null,
        .value => |member| return member,
    }
    if (field.target.* == .name and self.findLocal(field.target.name.text) == null) {
        const base = field.target.name.text;
        if (naming.importsModule(self.analyzer, self.module, base)) {
            const joined = try std.fmt.allocPrint(self.arena(), "{s}.{s}", .{ base, field.name });
            // geo.pi — an imported module's file-scope constant.
            if (self.analyzer.constant_names.get(try self.importedName(joined))) |constant| {
                const info = self.analyzer.constant_infos.items[constant];
                if (info.declaration.visibility == .private and info.module != self.module) {
                    try self.fail("luce.sema.private", field.span, "{s} is private to {s}", .{
                        field.name,
                        naming.moduleName(self.analyzer, info.module),
                    });
                    return null;
                }
                return emitConstant(self, constant, field.span);
            }
            try refusals.failNamespaceMember(self, base, field.name, joined, field.span);
            return null;
        }
        // Words.classify — a struct of this module as a namespace.
        const head_qualified = try naming.qualify(self.analyzer, self.prefix, base);
        if (self.analyzer.alias_names.get(head_qualified)) |alias_index| {
            const target = (try resolve.resolveAlias(self.analyzer, self.module, alias_index, field.span)) orelse
                return null;
            const namespace = resolve.namespaceName(self.analyzer, target) orelse {
                try self.fail(
                    "luce.sema.name",
                    field.span,
                    "{s} is a type alias for {s}, which has no static members",
                    .{ base, try self.analyzer.typeName(target) },
                );
                return null;
            };
            const joined = try std.fmt.allocPrint(self.arena(), "{s}.{s}", .{ namespace, field.name });
            try refusals.failNamespaceMember(self, base, field.name, joined, field.span);
            return null;
        }
        if (self.analyzer.struct_names.contains(head_qualified)) {
            const joined = try std.fmt.allocPrint(self.arena(), "{s}.{s}", .{ head_qualified, field.name });
            try refusals.failNamespaceMember(self, base, field.name, joined, field.span);
            return null;
        }
        if (try refusals.failUnimportedNamespace(self, base, field.span)) return null;
    }
    const target = lifecycle_target: {
        const previous_permission = self.allow_deinitializer_self;
        defer self.allow_deinitializer_self = previous_permission;
        if (self.lifecycle == .deinitializer and builder.isBareSelf(field.target)) {
            self.allow_deinitializer_self = true;
        }
        break :lifecycle_target (try self.lowerExpression(field.target, false)) orelse return null;
    };
    const layout_index = self.analyzer.nominalLayout(target.value_type) orelse {
        try self.fail("luce.sema.field", field.span, "{s} has no fields{s}", .{
            try self.analyzer.typeName(target.value_type),
            try refusals.absenceAdvice(self, target.value_type, field.target),
        });
        return null;
    };
    if (target.value_type == .strukt and self.analyzer.interfaceForLayout(layout_index) != null) {
        try self.fail(
            "luce.sema.interface",
            field.span,
            "interfaces expose methods, not fields; call {s}.{s}(…) directly",
            .{ try self.analyzer.typeName(target.value_type), field.name },
        );
        return null;
    }
    const layout = self.analyzer.structs.items[layout_index];
    const field_index = layout.findField(field.name) orelse {
        // `let f = p.length` — a *bound method value*, which is a
        // closure over `p` by another name and first among the
        // things docs/LANGUAGE.md deliberately does not have.  The
        // sentence is the same implicit-self rule a typed
        // `Point.length` reference gets through `functionValue`.
        const member = try std.fmt.allocPrint(self.arena(), "{s}.{s}", .{ layout.name, field.name });
        // Spelled the way the reader wrote it where the receiver
        // has a name, and by its struct where it does not:
        // "the receiver.length" is not a phrase anybody typed.
        const written = switch (field.target.*) {
            .name => |name| try std.fmt.allocPrint(self.arena(), "{s}.{s}", .{ name.text, field.name }),
            else => member,
        };
        if (try refusals.failNotAValue(self, written, member, field.span)) return null;
        try refusals.failUnknownField(self, "luce.sema.field", layout_index, field.name, field.span);
        return null;
    };
    if (!try refusals.fieldReachable(self, layout_index, field_index, field.span)) return null;
    const field_type = layout.fields[field_index].field_type;
    // A field read is a view into the struct's run.
    return .{
        .node = try recorder.recordNode(self, .{ .field_get = .{
            .target = target.node,
            .layout = layout_index,
            .field = field_index,
            .weak = layout.fields[field_index].weak,
            .result = field_type,
            .span = field.span,
        } }),
        .value_type = field_type,
    };
}

/// The two sides of an operator, each landing where it should.
///
/// Two rules, and between them they are the whole of "a number has
/// no type until it meets one" (docs/TYPES.md D3) inside an
/// operator:
///
///   * **Both sides untyped** — `2 * 0.1` — and the *place* the
///     whole expression lands in decides, so `let x: f64 =
///     2 * 0.1` computes at binary64 throughout. `wanted` is
///     pushed into both and reaches every literal under them.
///   * **One side typed** — `x * 0.1` — and that side decides,
///     because what the literal met is `x`.  This is Go's rule and
///     Luce needs it for the same reason: binary32's nearest 0.1 is
///     not binary64's nearest 0.1. The literal must take the concrete
///     typed operand's width rather than its context-free f64 default.
///
/// In the second case the typed side is lowered **first**, so its
/// type is known before the literal is parsed.  That reorders
/// nothing observable: the sides swap only when one of them is a
/// constant expression over literals, which evaluates to itself
/// with no effects, no calls and no traps.
///
/// `semantics/declarations.zig` folds a file-scope `const` by the
/// same two rules, because the two must agree about what `2 * 0.1`
/// is.
/// Whether this expression is a **bare declaration name** that a
/// function type would give a meaning to: `ascending`,
/// `Struct.helper`, `module.helper`.  A local of the same name is
/// not one — a local is a value already — and neither is anything
/// with parentheses after it.
///
/// Asked only where one operand can supply the other's type; it
/// answers *maybe*, and `functionValue` is what decides.
fn namesAFunction(self: *FunctionBuilder, expression: *const ast.Expression) bool {
    switch (expression.*) {
        .name => |name| {
            if (self.findLocal(name.text) != null) return false;
            const qualified = naming.qualify(self.analyzer, self.prefix, name.text) catch return false;
            return self.analyzer.function_names.contains(qualified);
        },
        .field => |field| {
            const chain = helpers.dottedChain(field.target) orelse return false;
            if (chain.count != 1) return false;
            if (self.findLocal(chain.head()) != null) return false;
            const written = std.fmt.allocPrint(self.arena(), "{s}.{s}", .{
                chain.head(),
                field.name,
            }) catch return false;
            const local = naming.qualify(self.analyzer, self.prefix, written) catch return false;
            return self.analyzer.function_names.contains(local) or
                self.analyzer.function_names.contains(written);
        },
        else => return false,
    }
}

/// A lowered operator pair with the evaluation facts the tree
/// records (nodes.Expression.Sides): the typed-side-first order,
/// and the batch rewrites of the left operand.
const BinarySides = struct {
    values: []Typed,
    sides: nodes.Expression.Sides = .{},
};

fn lowerBinaryOperands(
    self: *FunctionBuilder,
    binary: ast.Binary,
    wanted: ?Type,
) Error!?BinarySides {
    // **An operand with no type of its own takes the other's.**
    // Two kinds have none: a numeric literal (docs/TYPES.md D3) and
    // a bare function name, which is not a value until something
    // says which shape it wears (docs/FUNCTIONS.md S1).  Both are
    // answered the same way and always have been — lower the side
    // that knows, then land the side that does not on it.
    const left_untyped = helpers.isUntypedNumber(binary.left) or namesAFunction(self, binary.left);
    const right_untyped = helpers.isUntypedNumber(binary.right) or namesAFunction(self, binary.right);
    if (left_untyped and right_untyped) {
        const values = try self.arena().alloc(Typed, 2);
        const expressions = [_]*ast.Expression{ binary.left, binary.right };
        for (expressions, 0..) |expression, index| {
            if (wanted) |place| self.wantPlace(place);
            values[index] = (try self.lowerExpression(expression, false)) orelse return null;
        }
        return .{ .values = values };
    }
    if (left_untyped == right_untyped) {
        const run = (try self.lowerOperandsIntoTracking(
            &.{ binary.left, binary.right },
            .nothing,
        )) orelse return null;
        return .{ .values = run.values, .sides = .{
            .left_copied = run.copied[0],
        } };
    }
    const values = try self.arena().alloc(Typed, 2);
    const written_first: usize = if (left_untyped) 1 else 0;
    const written_second: usize = 1 - written_first;
    const expressions = [_]*ast.Expression{ binary.left, binary.right };
    values[written_first] =
        (try self.lowerExpression(expressions[written_first], false)) orelse return null;
    self.wantPlace(values[written_first].value_type);
    values[written_second] =
        (try self.lowerExpression(expressions[written_second], false)) orelse return null;
    return .{ .values = values, .sides = .{ .right_first = left_untyped } };
}

pub fn lowerBinary(self: *FunctionBuilder, binary: ast.Binary, wanted: ?Type) Error!?Typed {
    switch (binary.op) {
        .logic_and, .logic_or => return lowerShortCircuit(self, binary),
        .coalesce => return lowerCoalesce(self, binary),
        .identity => return lowerIdentity(self, binary),
        else => {},
    }
    if (binary.left.* == .none_literal or binary.right.* == .none_literal) {
        return lowerAbsenceTest(self, binary);
    }
    const pair = (try lowerBinaryOperands(self, binary, wanted)) orelse return null;
    var left = pair.values[0];
    var right = pair.values[1];

    const operation: mir.BinaryOp = switch (binary.op) {
        .add => .add,
        .subtract => .subtract,
        .multiply => .multiply,
        .divide => .divide,
        .floor_divide => .floor_divide,
        .modulo => .modulo,
        .equal => .equal,
        .not_equal => .not_equal,
        .less => .less,
        .less_equal => .less_equal,
        .greater => .greater,
        .greater_equal => .greater_equal,
        .bit_and => .bit_and,
        .bit_or => .bit_or,
        .bit_xor => .bit_xor,
        .shift_left => .shift_left,
        .shift_right => .shift_right,
        .logic_and, .logic_or, .coalesce, .catch_error, .identity => unreachable, // answered above
    };

    // `/` is **real division** and always answers `f64` for integer
    // operands, so there is no integer `/` left in
    // the IR (docs/NUMERICS.md §2).  `1 / 2` is `0.5`; the
    // quotient that answers `0` is `1 // 2`.
    //
    // This one operator has an explicit result rule independent of operand
    // width. Use `//` for an integer quotient or convert both inputs before
    // `/` when the result must have another floating width.
    if (operation == .divide and left.value_type.isInteger() and right.value_type.isInteger()) {
        left = try self.convertNumeric(left, .f64);
        right = try self.convertNumeric(right, .f64);
    }

    if (!left.value_type.eql(right.value_type)) {
        const absent = if (left.value_type == .optional) left else right;
        const written = if (left.value_type == .optional) binary.left else binary.right;
        try self.fail("luce.sema.type", binary.span, context.mismatched_operands_message ++ "{s}", .{
            context.operatorText(binary.op),
            try self.analyzer.typeName(left.value_type),
            try self.analyzer.typeName(right.value_type),
            try refusals.absenceAdvice(self, absent.value_type, written),
        });
        return null;
    }
    const operand_type = left.value_type;

    // An operator wants a value, and a `T?` may not be one.  Said
    // here rather than left to "does not support this operator",
    // because the fix is narrowing and the reader needs told.
    if (try refusals.refusesAbsence(self, left, "this operator", binary.span, binary.left)) return null;
    if (try refusals.refusesAbsence(self, right, "this operator", binary.span, binary.right)) return null;

    const arithmetic = switch (operation) {
        .add,
        .subtract,
        .multiply,
        .divide,
        .floor_divide,
        .modulo,
        .bit_and,
        .bit_or,
        .bit_xor,
        .shift_left,
        .shift_right,
        => true,
        else => false,
    };
    if (arithmetic) {
        // The bit set operates on the integers and nothing else
        // (docs/BITWISE.md D2): a float has no bits a program may
        // see, and the sentence says which fact refused it.
        switch (operation) {
            .bit_and, .bit_or, .bit_xor, .shift_left, .shift_right => {
                if (!operand_type.isInteger()) {
                    try self.fail(
                        "luce.sema.type",
                        binary.span,
                        "{s} works on integers; {s} has no bits a program may see",
                        .{
                            context.operatorText(binary.op),
                            try self.analyzer.typeName(operand_type),
                        },
                    );
                    return null;
                }
            },
            else => {},
        }
        const text_concat = operation == .add and (operand_type == .str or operand_type == .bytes);
        if (operation == .modulo and operand_type == .str) {
            try self.fail(
                "luce.sema.type",
                binary.span,
                "str does not support '%'; use an f-string such as f\"hello {{name}}\" for interpolation",
                .{},
            );
            return null;
        }
        if (!operand_type.isNumeric() and !text_concat) {
            try self.fail("luce.sema.type", binary.span, "{s} does not support this operator", .{
                try self.analyzer.typeName(operand_type),
            });
            return null;
        }
        return .{
            .node = try recorder.recordNode(self, .{ .binary = .{
                .op = operation,
                .left = left.node,
                .right = right.node,
                .result = operand_type,
                .span = binary.span,
                .sides = pair.sides,
            } }),
            .value_type = operand_type,
        };
    }

    // Comparisons: equality everywhere; ordering for numeric values,
    // char, str, and bytes.
    const ordering = operation != .equal and operation != .not_equal;
    if (ordering and !(operand_type.isNumeric() or operand_type == .char or operand_type == .str or operand_type == .bytes)) {
        // **An enum is a set of names, not a number line**
        // (docs/ENUMS.md D6), and the reader who wanted the numbers
        // is one word away from having them — so the sentence says
        // the word rather than stopping at "has no ordering".
        if (operand_type == .enumeration) {
            try self.fail(
                "luce.sema.type",
                binary.span,
                "{s} is a set of names and has no order; write i64({s}) {s} i64({s}) to compare the numbers behind them",
                .{
                    try self.analyzer.typeName(operand_type),
                    try calls.writtenTarget(self, binary.left),
                    context.operatorText(binary.op),
                    try calls.writtenTarget(self, binary.right),
                },
            );
            return null;
        }
        // **A function value has no order** (docs/FUNCTIONS.md D3) —
        // and since D6 it has no equality either, so the sentence
        // names the one comparison a program can make instead rather
        // than pointing at an `==` that is also refused.
        if (operand_type == .function) {
            try self.fail(
                "luce.sema.type",
                binary.span,
                "a function value has no order, and no equality either; compare str(f) if the name is what you meant",
                .{},
            );
            return null;
        }
        try self.fail("luce.sema.type", binary.span, "{s} has no ordering", .{
            try self.analyzer.typeName(operand_type),
        });
        return null;
    }
    if (operand_type == .none) {
        try self.fail("luce.sema.type", binary.span, "value has no type", .{});
        return null;
    }
    if (self.analyzer.classLayout(operand_type) != null) {
        try self.fail(
            "luce.sema.class.equality",
            binary.span,
            "class values have identity, not value equality; write 'left is right' (or 'not (left is right)')",
            .{},
        );
        return null;
    }
    // **Both refusals below are about the whole compared value, not
    // about its outermost tag.**  A struct's `==` is field-by-field
    // `==` (`runtime/operators.zig`), so a struct whose field is a
    // union asks exactly the question UNION.md D16 refuses, and a
    // struct whose field holds a function value asks exactly the one
    // BINDING.md D6 refuses — through a wrapper the reader did not
    // think of as a comparison. `incomparablePart` is the one walk
    // that answers for both, and it stops where `==` stops.
    if (try shapes.incomparablePart(self.analyzer, operand_type)) |found| {
        try refusals.failIncomparable(
            self,
            found,
            operand_type,
            context.operatorText(binary.op),
            binary.span,
        );
        return null;
    }
    return .{
        .node = try recorder.recordNode(self, .{ .compare = .{
            .op = operation,
            .left = left.node,
            .right = right.node,
            .result = .boolean,
            .span = binary.span,
            .sides = pair.sides,
        } }),
        .value_type = .boolean,
    };
}

/// `a is b` — identity of two references to the same nominal class.
/// The MIR already compares object handles by row and generation, so the
/// distinct source operator is a semantic gate and lowers to that primitive
/// equality only after both class rules have been proved.
fn lowerIdentity(self: *FunctionBuilder, binary: ast.Binary) Error!?Typed {
    const pair = (try lowerBinaryOperands(self, binary, null)) orelse return null;
    const left = pair.values[0];
    const right = pair.values[1];
    const left_layout = self.analyzer.classLayout(left.value_type) orelse {
        try self.fail("luce.sema.class.identity", binary.left.span(), "the left side of 'is' is {s}, not a class reference", .{
            try self.analyzer.typeName(left.value_type),
        });
        return null;
    };
    const right_layout = self.analyzer.classLayout(right.value_type) orelse {
        try self.fail("luce.sema.class.identity", binary.right.span(), "the right side of 'is' is {s}, not a class reference", .{
            try self.analyzer.typeName(right.value_type),
        });
        return null;
    };
    if (left_layout != right_layout) {
        try self.fail("luce.sema.class.identity", binary.span, "'is' needs two references to the same class, got {s} and {s}", .{
            try self.analyzer.typeName(left.value_type),
            try self.analyzer.typeName(right.value_type),
        });
        return null;
    }
    return .{
        .node = try recorder.recordNode(self, .{ .compare = .{
            .op = .equal,
            .left = left.node,
            .right = right.node,
            .result = .boolean,
            .span = binary.span,
            .sides = pair.sides,
        } }),
        .value_type = .boolean,
    };
}

/// `x == none` / `x != none` — the test that narrows.  It is the
/// one comparison `none` takes part in: absence has no ordering
/// and nothing else to be equal to.
fn lowerAbsenceTest(self: *FunctionBuilder, binary: ast.Binary) Error!?Typed {
    if (binary.op != .equal and binary.op != .not_equal) {
        try self.fail("luce.sema.absent", binary.span, "none only compares with == and !=", .{});
        return null;
    }
    if (binary.left.* == .none_literal and binary.right.* == .none_literal) {
        try self.fail("luce.sema.absent", binary.span, "none == none says nothing; test a T? against none", .{});
        return null;
    }
    const written = if (binary.right.* == .none_literal) binary.left else binary.right;
    const already = refusals.narrowedName(self, written);
    const tested = (try self.lowerExpression(written, false)) orelse return null;
    if (tested.value_type != .optional) {
        if (already) |name| {
            try self.fail("luce.sema.absent", binary.span, "{s} already holds a value here, so this test has one answer; drop it", .{name});
            return null;
        }
        try self.fail("luce.sema.absent", binary.span, "{s} is always there; only a T? is ever none", .{
            try self.analyzer.typeName(tested.value_type),
        });
        return null;
    }
    // The tree records the comparison as written: the tested side
    // against a typed absence — `absent` at the tested `T?` is the
    // node form of the bare `none` (hir.zig), and lower spells
    // `is_none` (and `!=`'s complement) back out of the pair.
    const none_side = if (binary.right.* == .none_literal) binary.right else binary.left;
    const written_absent = try recorder.recordNode(self, .{ .absent = .{
        .result = tested.value_type,
        .span = none_side.span(),
    } });
    const op: nodes.BinaryOp = if (binary.op == .equal) .equal else .not_equal;
    return .{
        .node = try recorder.recordNode(self, .{ .compare = .{
            .op = op,
            .left = if (binary.right.* == .none_literal) tested.node else written_absent,
            .right = if (binary.right.* == .none_literal) written_absent else tested.node,
            .result = .boolean,
            .span = binary.span,
        } }),
        .value_type = .boolean,
    };
}

/// `trap("…")` written where a value belongs.  It is the one
/// expression that never yields one and is still legal there,
/// because it never comes back; `trap` is a reserved name, so
/// nothing else can wear it.
pub fn isLeavingCall(expression: *const ast.Expression) bool {
    if (expression.* != .call) return false;
    const callee = expression.call.callee;
    return std.mem.eql(u8, callee, "trap") or
        std.mem.eql(u8, callee, "error") or
        std.mem.eql(u8, callee, "exit");
}

/// `a else b` — `a` when it is there, `b` when it is not.  The
/// fallback runs only on the absent side, which is what makes
/// `x else trap("…")` the assert-unwrap (docs/FAILURE.md).
fn lowerCoalesce(self: *FunctionBuilder, binary: ast.Binary) Error!?Typed {
    const already = refusals.narrowedName(self, binary.left);
    const left = (try self.lowerExpression(binary.left, false)) orelse return null;
    const payload = left.value_type.held() orelse {
        // A name already proved present is the likely case, and
        // "i64 always has a value" would only puzzle a reader who
        // wrote `i64?`.
        if (already) |name| {
            try self.fail("luce.sema.absent", binary.span, "{s} already holds a value here, so the else can never run; drop it", .{name});
            return null;
        }
        try self.fail("luce.sema.absent", binary.span, "else supplies the value a T? does not have, and {s} always has one", .{
            try self.analyzer.typeName(left.value_type),
        });
        return null;
    };
    // The hidden merge slot both arms store into; the answer is
    // its reload — a view of what the slot holds.
    _ = try recorder.recordLocal(self, null, payload, false, binary.span);
    var fallback: ?nodes.Expression.Coalesce.Fallback = null;
    if (isLeavingCall(binary.right)) {
        // `x else trap("…")` is the assert-unwrap, and it is
        // greppable — which is why Luce has no force-unwrap sigil
        // (docs/FAILURE.md).  The fallback leaves nothing behind
        // because it never comes back — no fallback *value*, so
        // the node files the call under `.leaving`, the union arm
        // that stores nothing (nodes.Coalesce.Fallback).
        if (try self.lowerExpression(binary.right, true)) |gone| {
            fallback = .{ .leaving = gone.node };
        }
    } else if (try self.lowerTyped(binary.right, payload, binary.span, "the else fallback")) |landed| {
        fallback = .{ .value = landed.value.node };
    }
    const filed = fallback orelse return null;

    return .{
        .node = try recorder.recordNode(self, .{ .coalesce = .{
            .value = left.node,
            .fallback = filed,
            .result = payload,
            .span = binary.span,
        } }),
        .value_type = payload,
    };
}

fn lowerShortCircuit(self: *FunctionBuilder, binary: ast.Binary) Error!?Typed {
    const operator: []const u8 = if (binary.op == .logic_and) "and" else "or";
    const left = (try self.lowerExpression(binary.left, false)) orelse return null;
    if (left.value_type != .boolean) {
        // Which side, and what it is: the type is in hand and the
        // operand has its own span, so underlining both of them and
        // naming neither — which is what "and needs bool operands"
        // did — throws away everything the reader needs.
        // `condition must be bool, not i64` is the model.
        try self.fail("luce.sema.type", binary.left.span(), "the left operand of {s} must be bool, not {s}{s}", .{
            operator,
            try self.analyzer.typeName(left.value_type),
            try refusals.absenceAdvice(self, left.value_type, binary.left),
        });
        return null;
    }
    // `and` evaluates its right side when the left is true, `or`
    // when it is false; the hidden merge slot is the answer's.
    _ = try recorder.recordLocal(self, null, .boolean, false, binary.span);
    // Inside the right operand, the left one has already decided:
    // `x != none and x > 3` narrows `x` for the comparison, which
    // is the shape this feature exists for.  Nothing inside an
    // expression can widen, so the facts unwind by truncation.
    const facts_floor = self.narrowed.items.len;
    try flow.applyFacts(self, binary.left, binary.op == .logic_and, flow.fact_search_depth);
    defer self.narrowed.shrinkRetainingCapacity(facts_floor);
    var right_node: ?nodes.NodeRef = null;
    if (try self.lowerExpression(binary.right, false)) |right| {
        if (right.value_type != .boolean) {
            try self.fail("luce.sema.type", binary.right.span(), "the right operand of {s} must be bool, not {s}{s}", .{
                operator,
                try self.analyzer.typeName(right.value_type),
                try refusals.absenceAdvice(self, right.value_type, binary.right),
            });
        } else {
            right_node = right.node;
        }
    }
    const filed = right_node orelse return null;
    return .{
        .node = try recorder.recordNode(self, .{ .short_circuit = .{
            .op = if (binary.op == .logic_and) .logic_and else .logic_or,
            .left = left.node,
            .right = filed,
            .result = .boolean,
            .span = binary.span,
        } }),
        .value_type = .boolean,
    };
}

pub fn lowerUnary(self: *FunctionBuilder, unary: ast.Unary, wanted: ?Type) Error!?Typed {
    // -9223372036854775808 is one literal, not a negated one: the
    // magnitude alone is past i64's maximum, so the sign has to
    // fold in before the range is checked or the smallest i64 is
    // the one number nobody can write.
    if (unary.op == .negate and unary.operand.* == .int_literal) {
        return self.lowerIntLiteral(unary.operand.int_literal, unary.span, true, wanted);
    }
    // A minus does not change where a literal lands, so the
    // landing type passes straight through it: `let x: f64 =
    // -1.5` reads its text at a f32 exactly as `1.5` would.
    //
    // **No test kills this line yet, and none can.**  A negated
    // *integer* literal takes the branch above; what is left is a
    // negated floating literal, which lands on a floating type whether it
    // was told to or not, and a negated name, whose concrete type is
    // unchanged. Explicit-width tests now make this landing rule observable.
    if (unary.op == .negate) self.wanted = wanted;
    const operand = (try self.lowerExpression(unary.operand, false)) orelse return null;
    switch (unary.op) {
        .negate => {
            if (!operand.value_type.isNumeric()) {
                try self.fail("luce.sema.type", unary.span, "cannot negate {s}", .{
                    try self.analyzer.typeName(operand.value_type),
                });
                return null;
            }
            return .{
                .node = try recorder.recordNode(self, .{ .unary = .{
                    .op = .negate,
                    .operand = operand.node,
                    .result = operand.value_type,
                    .span = unary.span,
                } }),
                .value_type = operand.value_type,
            };
        },
        .logic_not => {
            if (operand.value_type != .boolean) {
                try self.fail("luce.sema.type", unary.span, "not needs a bool", .{});
                return null;
            }
            return .{
                .node = try recorder.recordNode(self, .{ .unary = .{
                    .op = .logic_not,
                    .operand = operand.node,
                    .result = .boolean,
                    .span = unary.span,
                } }),
                .value_type = .boolean,
            };
        },
        .bit_not => {
            // Integers only (docs/BITWISE.md D2); the operand's explicit
            // width is also the result width.
            if (!operand.value_type.isNumeric() or operand.value_type.isFloating()) {
                try self.fail("luce.sema.type", unary.span, "~ works on integers; {s} has no bits a program may see", .{
                    try self.analyzer.typeName(operand.value_type),
                });
                return null;
            }
            return .{
                .node = try recorder.recordNode(self, .{ .unary = .{
                    .op = .bit_not,
                    .operand = operand.node,
                    .result = operand.value_type,
                    .span = unary.span,
                } }),
                .value_type = operand.value_type,
            };
        },
    }
}
