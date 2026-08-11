//! Compile-time evaluation — the folder that turns a written
//! expression into a `TypedConstant`, or reports why it is not one.
//!
//! Three clients, one evaluator: a file-scope `const` (folded eagerly, so
//! a bad constant reports even when nothing reads it), an enum member's
//! value, and a default — a parameter's or a field's.  Each arrives
//! through `fold` with the type its place lands on, and the answer is a
//! value, never an instruction: **nothing here emits**.  Where the
//! walking checker would produce a register, this produces a number,
//! and the two must agree about what `1` is — `foldIntLiteral` here and
//! `builder.zig`'s `lowerIntLiteral` there are deliberate twins
//! (docs/TYPES.md D3).
//!
//! It runs on the collected project (`declarations.zig`'s `Analyzer`)
//! and needs nothing else: a constant may name another constant, an
//! enum member, or a struct's fields, so the whole collection has to be
//! reachable — but the reaching is all through the `Analyzer`'s
//! published surface, which is what makes this a file rather than a
//! region.  Cycles are caught per constant and per field default; a
//! refusal is `luce.sema.const` and names the constant, not the
//! expression it was reached from.

const std = @import("std");
const source_mod = @import("../01_source.zig");
const helpers = @import("helpers.zig");
const context = @import("context.zig");
const ast = @import("../03_parse.zig").ast;
const mir = @import("../06_mir.zig");
const types = @import("../support/types.zig");
// The fold answers what a run would answer, so where a judgment has
// one implementation in `libluce_rt` this calls it rather than keeping
// a second copy that could drift (docs/NUMERICS.md §5).
const operators = @import("../runtime/operators.zig");
const runtime_value = @import("../runtime/value.zig");

const Analyzer = @import("declarations.zig").Analyzer;
const defaults = @import("defaults.zig");
const naming = @import("naming.zig");
const resolve = @import("resolve.zig");
const shapes = @import("shapes.zig");

const Span = source_mod.Span;
const Type = types.Type;
const Error = context.Error;
const TypedConstant = context.TypedConstant;
const ConstantValue = context.ConstantValue;
const isReserved = context.isReserved;
const mismatched_operands_message = context.mismatched_operands_message;
const namespace_has_no_fields_message = context.namespace_has_no_fields_message;
const duplicate_field_message = context.duplicate_field_message;
const missing_field_message = context.missing_field_message;

/// Fold every registered constant, so an error in one reports even
/// when nothing uses it.  Separate from `declarations.zig`'s
/// registration because an enum member's value may name a constant and
/// a constant may name an enum member: the names all exist by the time
/// either fold runs (docs/ENUMS.md D8).
pub fn foldAll(analyzer: *Analyzer) Error!void {
    for (0..analyzer.constant_infos.items.len) |index| {
        const module = analyzer.constant_infos.items[index].module;
        analyzer.diagnostics.scope = analyzer.modules[module].file;
        const folded = try evaluate(analyzer, @intCast(index));
        // D4, for a constant: a reachable constant may not hold a
        // value of a hidden type — an importer could read it and
        // hold what it cannot name.
        if (folded) |value| {
            const info = analyzer.constant_infos.items[index];
            if (info.declaration.visibility == .private) continue;
            if (naming.privateMentioned(analyzer, value.value_type)) |hidden| {
                try analyzer.fail(
                    "luce.sema.private",
                    info.declaration.name_span,
                    "{s} is public and holds {s}, which is marked private in {s}; mark {s} private or remove the mark on {s}",
                    .{
                        info.declaration.name,
                        hidden,
                        naming.markedIn(analyzer, info.module),
                        info.declaration.name,
                        hidden,
                    },
                );
            }
        }
    }
    analyzer.diagnostics.scope = source_mod.root_file;
}

/// Fold one constant, lazily and cycle-checked.  Null after a
/// reported error.
fn evaluate(analyzer: *Analyzer, index: u32) Error!?TypedConstant {
    const info = &analyzer.constant_infos.items[index];
    switch (info.state) {
        .ready => return .{ .value = info.value, .value_type = info.value_type },
        .failed => return null,
        .evaluating => {
            try analyzer.fail(
                "luce.sema.const",
                info.declaration.span,
                "constant {s} depends on itself",
                .{info.declaration.name},
            );
            info.state = .failed;
            return null;
        },
        .pending => {},
    }
    info.state = .evaluating;
    const declaration = info.declaration;
    const module = info.module;
    if (helpers.deeperThan(declaration.value, helpers.max_expression_depth)) {
        try analyzer.fail(
            "luce.sema.nesting",
            declaration.span,
            "expression nested too deeply (limit {d})",
            .{helpers.max_expression_depth},
        );
        analyzer.constant_infos.items[index].state = .failed;
        return null;
    }
    // The annotation is resolved *before* the fold, not after,
    // because it is the landing type: `const x: double = 1` reads its
    // literal at a float rather than folding an integer and being
    // told the two disagree (docs/TYPES.md D3).
    var annotated: ?Type = null;
    if (declaration.annotation) |written| {
        annotated = (try resolve.resolveType(analyzer, module, written)) orelse {
            analyzer.constant_infos.items[index].state = .failed;
            return null;
        };
    }
    // A constant reached from inside a default's fold is still a
    // constant: its own refusals speak of constants, not of the
    // default that happened to read it.
    const previous_subject = analyzer.fold_subject;
    const previous_name = analyzer.fold_container_name;
    const previous_file = analyzer.fold_container_file;
    const previous_origin = analyzer.fold_container_origin;
    const previous_nesting = analyzer.folding_container;
    analyzer.fold_subject = null;
    analyzer.fold_container_name = declaration.name;
    analyzer.fold_container_file = analyzer.modules[module].file;
    analyzer.fold_container_origin = @intCast(declaration.name_span.start);
    analyzer.folding_container = false;
    // Restored by defer, so an error return out of the fold cannot
    // leave a dependent constant's context speaking as this one —
    // the sibling save/restore in declarations.zig does the same.
    defer {
        analyzer.fold_subject = previous_subject;
        analyzer.fold_container_name = previous_name;
        analyzer.fold_container_file = previous_file;
        analyzer.fold_container_origin = previous_origin;
        analyzer.folding_container = previous_nesting;
    }
    const folded = try fold(analyzer, module, declaration.value, annotated);
    // The map may have grown while folding dependencies; re-find.
    const settled = &analyzer.constant_infos.items[index];
    var result = folded orelse {
        settled.state = .failed;
        return null;
    };
    if (annotated) |expected| {
        result = fit(result, expected) orelse {
            try analyzer.fail("luce.sema.type", declaration.span, "{s} declared {s} but its value is {s}", .{
                declaration.name,
                try analyzer.typeName(expected),
                try analyzer.typeName(result.value_type),
            });
            settled.state = .failed;
            return null;
        };
    }
    settled.value = result.value;
    settled.value_type = result.value_type;
    settled.state = .ready;
    return result;
}

/// Fold an integer literal at the type it lands on — the constant
/// folder's twin of the builder's `lowerIntLiteral`, and it has to
/// be a twin, because a file-scope `const` is folded here and a local
/// one is lowered there and the two must agree on what `1` is.
fn foldIntLiteral(
    analyzer: *Analyzer,
    literal: ast.Literal,
    span: Span,
    negated: bool,
    wanted: ?Type,
) Error!?TypedConstant {
    // A literal lands on the place's type only when the place is a
    // number.  `let flag: bool = 3` is not a literal that fits
    // badly, it is a mismatch, and it has to reach the mismatch
    // message rather than be folded into a bool-typed 3.
    const lands: Type = if (wanted) |place|
        (context.literalLandingType(place) orelse .int)
    else
        .int;
    if (lands.isFloating()) {
        const parsed = helpers.parseIntLiteralAsFloat(literal.text, negated, lands) orelse {
            return constantError(analyzer, span, "{s}", .{context.rangeMessage(lands)});
        };
        return .{ .value = .{ .double = parsed }, .value_type = lands };
    }
    const parsed = helpers.parseIntLiteral(literal.text, negated, lands) orelse {
        return constantError(analyzer, span, "{s}", .{context.rangeMessage(lands)});
    };
    return .{ .value = .{ .long = parsed }, .value_type = lands };
}

/// A folded number's value as an `f64`, whichever family it came
/// from.  A constant carries its value at the widest member of its
/// family (`ConstantValue`), so an `int` arrives in `.long` and a
/// `float` in `.double`.
fn asDouble(held: TypedConstant) f64 {
    return switch (held.value) {
        .long => |whole| @floatFromInt(whole),
        .double => |fraction| fraction,
        else => unreachable, // asked only of a number
    };
}

/// One folded number widened along `Type.widensTo`.  A no-op when
/// it is already there, so a caller may apply it to both operands
/// without asking which one moved.
pub fn widen(held: TypedConstant, to: Type) TypedConstant {
    if (held.value_type.eql(to)) return held;
    if (to.isInteger()) return .{ .value = held.value, .value_type = to };
    return .{ .value = .{ .double = asDouble(held) }, .value_type = to };
}

/// Make one folded value fit the type of its landing place.  This is
/// the constant-folding twin of `FunctionBuilder.fit`: numeric values
/// widen along the language lattice, and a present `T` may stand in a
/// `T?` place.  Presence needs no extra `ConstantValue` tag --
/// `.absent` is the exceptional encoding, while every other tag is a
/// present payload whose optional type supplies the wrapper.
pub fn fit(held: TypedConstant, wanted: Type) ?TypedConstant {
    if (held.value_type.eql(wanted)) return held;
    if (held.value_type.widensTo(wanted)) return widen(held, wanted);
    const payload = wanted.held() orelse return null;
    var inner = fit(held, payload) orelse return null;
    inner.value_type = wanted;
    return inner;
}

/// The six float operators at one width, so that folding a `float`
/// expression rounds every step to binary32 exactly as a run
/// would.  `%` is the runtime's own floor modulus and not Zig's
/// `@mod`, which forces a non-negative answer and disagrees with
/// what a program computes for a negative divisor.
fn foldFloat(comptime T: type, op: ast.BinaryOp, a: T, b: T) f64 {
    return switch (op) {
        .add => a + b,
        .subtract => a - b,
        .multiply => a * b,
        .divide => a / b,
        .floor_divide => @floor(a / b),
        .modulo => operators.floorMod(T, a, b),
        else => unreachable,
    };
}

fn constantError(analyzer: *Analyzer, span: Span, comptime format: []const u8, arguments: anytype) Error!?TypedConstant {
    try analyzer.fail("luce.sema.const", span, format, arguments);
    return null;
}

/// Translate one already-checked flat element into the serialized
/// constant-pool vocabulary.  String bytes join the ordinary text
/// pool so pruning and both engines have one spelling for them.
fn encodeValue(
    analyzer: *Analyzer,
    value: ConstantValue,
) Error!mir.ConstantValue {
    return switch (value) {
        .long => |held| .{ .long = held },
        .double => |held| .{ .double = held },
        .boolean => |held| .{ .boolean = held },
        .string => |held| .{ .string = try analyzer.pool.intern(held) },
        .strukt => |held| blk: {
            const fields = try analyzer.arena.alloc(mir.ConstantValue, held.fields.len);
            for (held.fields, fields) |field, *encoded| {
                encoded.* = try encodeValue(analyzer, field);
            }
            break :blk .{ .strukt = .{ .layout = held.layout, .fields = fields } };
        },
        .absent => .absent,
        // A pool row inside another would be a nested constant
        // container.  Its callers reject that before encoding (R-E).
        .container => unreachable,
    };
}

fn nestedContainerError(analyzer: *Analyzer, span: Span) Error!?TypedConstant {
    return constantError(
        analyzer,
        span,
        "constant containers are flat in this version; an element cannot itself carry a list, map, array, builder, file, or task [CONSTANTS.md R-E]",
        .{},
    );
}

fn containerContextError(analyzer: *Analyzer, span: Span) Error!?TypedConstant {
    if (analyzer.fold_subject) |subject| {
        return constantError(analyzer, span, "{s} is a constant, but this container has no program-root construction site", .{subject});
    }
    return constantError(analyzer, span, "a container literal is constant only in a file-scope const or a borrowed parameter default", .{});
}

/// Finish a folded numeric value at the element/key type its container
/// chose.  `Type.widensTo` is the whole implicit numeric lattice; no
/// other conversion happens here.
fn fitElement(value: TypedConstant, wanted: Type) TypedConstant {
    return if (value.value_type.widensTo(wanted)) widen(value, wanted) else value;
}

fn foldSequence(
    analyzer: *Analyzer,
    module: usize,
    literal: ast.ListLiteral,
    wanted: ?Type,
) Error!?TypedConstant {
    const name = analyzer.fold_container_name orelse
        return containerContextError(analyzer, literal.span);
    if (analyzer.folding_container) return nestedContainerError(analyzer, literal.span);
    analyzer.folding_container = true;
    defer analyzer.folding_container = false;

    var wanted_element: ?Type = null;
    var expected_container: ?Type = null;
    if (wanted) |place| {
        if (analyzer.heapOf(place)) |descriptor| switch (descriptor) {
            .list => |element| {
                wanted_element = element;
                expected_container = place;
            },
            .array => |shape| {
                if (shape.rank != 1) {
                    return constantError(
                        analyzer,
                        literal.span,
                        "a flat bracket constant builds a rank-1 array; {s} has rank {d}",
                        .{ try analyzer.typeName(place), shape.rank },
                    );
                }
                wanted_element = shape.element;
                expected_container = place;
            },
            .map, .builder, .file, .task => {},
        };
    }
    if (literal.elements.len == 0 and wanted_element == null) {
        return constantError(
            analyzer,
            literal.span,
            "an empty [] needs a list(T) or array(T, _) annotation",
            .{},
        );
    }
    // Flatness belongs to the declared element type, not to today's
    // population.  Without this check an annotated empty list/array
    // skipped the per-element loop below and could install a program
    // root shaped as list(task), list(list(T)), or T? — exactly the
    // graphs R-E says a constant container cannot own.
    if (wanted_element) |element_type| {
        if (element_type == .optional) {
            return constantError(
                analyzer,
                literal.span,
                "constant container elements cannot be optional; choose a present value, or put the optional inside an object-free struct",
                .{},
            );
        }
        if (shapes.carriesObjects(analyzer, element_type)) {
            return nestedContainerError(analyzer, literal.span);
        }
    }

    const folded = try analyzer.temporary.alloc(TypedConstant, literal.elements.len);
    defer analyzer.temporary.free(folded);
    for (literal.elements, folded) |element, *slot| {
        slot.* = (try fold(analyzer, module, element, wanted_element)) orelse return null;
        if (slot.value_type == .optional) {
            return constantError(
                analyzer,
                element.span(),
                "constant container elements cannot be optional; choose a present value, or put the optional inside an object-free struct",
                .{},
            );
        }
        if (slot.value == .container or shapes.carriesObjects(analyzer, slot.value_type)) {
            return nestedContainerError(analyzer, element.span());
        }
    }

    const element_type = wanted_element orelse inferred: {
        var meeting = folded[0].value_type;
        for (folded[1..]) |element| {
            meeting = Type.unified(meeting, element.value_type) orelse
                break :inferred folded[0].value_type;
        }
        break :inferred meeting;
    };
    for (folded, literal.elements) |*element, written| {
        element.* = fitElement(element.*, element_type);
        if (!element.value_type.eql(element_type)) {
            return constantError(analyzer, written.span(), "constant container elements are all {s}, got {s}", .{
                try analyzer.typeName(element_type),
                try analyzer.typeName(element.value_type),
            });
        }
    }

    const container_type = expected_container orelse
        try resolve.internHeapType(analyzer, .{ .list = element_type });
    const values = try analyzer.arena.alloc(mir.ConstantValue, folded.len);
    for (folded, values) |element, *encoded| {
        encoded.* = try encodeValue(analyzer, element.value);
    }
    const row = try analyzer.pool.addContainer(
        name,
        analyzer.fold_container_file,
        analyzer.fold_container_origin,
        container_type.heap,
        .{ .sequence = values },
    );
    return .{ .value = .{ .container = row }, .value_type = container_type };
}

fn sameMapKey(left: TypedConstant, right: TypedConstant) bool {
    if (!left.value_type.eql(right.value_type)) return false;
    const left_value = switch (left.value) {
        .long => |held| runtime_value.Value.ofLong(held),
        .string => |held| runtime_value.Value.ofString(held),
        else => return false,
    };
    const right_value = switch (right.value) {
        .long => |held| runtime_value.Value.ofLong(held),
        .string => |held| runtime_value.Value.ofString(held),
        else => return false,
    };
    return runtime_value.keyEquals(&left_value, &right_value);
}

fn mapKeyName(analyzer: *Analyzer, key: TypedConstant) Error![]const u8 {
    return switch (key.value) {
        .long => |held| std.fmt.allocPrint(analyzer.arena, "{d}", .{held}),
        .string => |held| std.fmt.allocPrint(analyzer.arena, "\"{s}\"", .{held}),
        else => "this key",
    };
}

fn foldMap(
    analyzer: *Analyzer,
    module: usize,
    literal: ast.MapLiteral,
    wanted: ?Type,
) Error!?TypedConstant {
    const name = analyzer.fold_container_name orelse
        return containerContextError(analyzer, literal.span);
    if (analyzer.folding_container) return nestedContainerError(analyzer, literal.span);
    analyzer.folding_container = true;
    defer analyzer.folding_container = false;

    var wanted_key: ?Type = null;
    var wanted_value: ?Type = null;
    var expected_container: ?Type = null;
    if (wanted) |place| {
        if (analyzer.heapOf(place)) |descriptor| {
            if (descriptor == .map) {
                wanted_key = descriptor.map.key;
                wanted_value = descriptor.map.value;
                expected_container = place;
            }
        }
    }

    const keys = try analyzer.temporary.alloc(TypedConstant, literal.entries.len);
    defer analyzer.temporary.free(keys);
    const values = try analyzer.temporary.alloc(TypedConstant, literal.entries.len);
    defer analyzer.temporary.free(values);
    for (literal.entries, 0..) |entry, index| {
        // An unannotated integer key lands directly on long, because
        // map(int, V) is not a type Luce admits (C3).
        const key_place = wanted_key orelse if (index == 0) Type.long else keys[0].value_type;
        var key = (try fold(analyzer, module, entry.key, key_place)) orelse return null;
        if (key.value_type.widensTo(key_place)) key = widen(key, key_place);
        if (index == 0 and wanted_key == null) {
            if (key.value_type == .string) {
                wanted_key = .string;
            } else if (key.value_type.isInteger()) {
                key = fitElement(key, .long);
                wanted_key = .long;
            }
        }
        const key_type = wanted_key orelse key.value_type;
        key = fitElement(key, key_type);
        if (key_type != .long and key_type != .string) {
            return constantError(analyzer, entry.key.span(), "map keys are long or string, got {s}", .{
                try analyzer.typeName(key_type),
            });
        }
        if (!key.value_type.eql(key_type)) {
            return constantError(analyzer, entry.key.span(), "map keys are all {s}, got {s}", .{
                try analyzer.typeName(key_type),
                try analyzer.typeName(key.value_type),
            });
        }
        keys[index] = key;
        values[index] = (try fold(analyzer, module, entry.value, wanted_value)) orelse return null;
        if (values[index].value_type == .optional) {
            return constantError(
                analyzer,
                entry.value.span(),
                "constant map values cannot be optional; choose a present value, or put the optional inside an object-free struct",
                .{},
            );
        }
        if (values[index].value == .container or shapes.carriesObjects(analyzer, values[index].value_type)) {
            return nestedContainerError(analyzer, entry.value.span());
        }
    }

    const value_type = wanted_value orelse inferred: {
        var meeting = values[0].value_type;
        for (values[1..]) |value| {
            meeting = Type.unified(meeting, value.value_type) orelse
                break :inferred values[0].value_type;
        }
        break :inferred meeting;
    };
    for (values, literal.entries) |*value, entry| {
        value.* = fitElement(value.*, value_type);
        if (!value.value_type.eql(value_type)) {
            return constantError(analyzer, entry.value.span(), "map values are all {s}, got {s}", .{
                try analyzer.typeName(value_type),
                try analyzer.typeName(value.value_type),
            });
        }
    }

    for (keys, 0..) |key, index| {
        for (keys[0..index], literal.entries[0..index]) |earlier, first| {
            if (!sameMapKey(earlier, key)) continue;
            const at = analyzer.diagnostics.sources.place(analyzer.modules[module].file, first.key.span().start);
            return constantError(
                analyzer,
                literal.entries[index].key.span(),
                "map key {s} is duplicated; it was first written on line {d}",
                .{ try mapKeyName(analyzer, key), at.line },
            );
        }
    }

    const key_type = wanted_key.?;
    const container_type = expected_container orelse
        try resolve.internHeapType(analyzer, .{ .map = .{ .key = key_type, .value = value_type } });
    const entries = try analyzer.arena.alloc(mir.ContainerConstant.MapEntry, literal.entries.len);
    for (keys, values, entries) |key, value, *encoded| {
        encoded.* = .{
            .key = try encodeValue(analyzer, key.value),
            .value = try encodeValue(analyzer, value.value),
        };
    }
    const row = try analyzer.pool.addContainer(
        name,
        analyzer.fold_container_file,
        analyzer.fold_container_origin,
        container_type.heap,
        .{ .map = entries },
    );
    return .{ .value = .{ .container = row }, .value_type = container_type };
}

/// Fold a constant expression.  The surface includes literals, other
/// constants (`pi`, `geo.pi`, struct-constant fields), operators,
/// conversion constructors, `ord`, enum members and conversions from
/// enums, typed absence, object-free value structs, and flat literal
/// list/map/rank-1-array constructions.  General calls, runtime object
/// operations and ownership verbs do not fold.
///
/// `wanted` is the type the constant lands on when the declaration
/// wrote one down — a numeric literal has no type of its own and
/// takes its context's (docs/TYPES.md D3).  Null means there is no
/// context and each literal takes the default.
pub fn fold(
    analyzer: *Analyzer,
    module: usize,
    expression: *const ast.Expression,
    wanted: ?Type,
) Error!?TypedConstant {
    switch (expression.*) {
        .int_literal => |literal| return foldIntLiteral(analyzer, literal, literal.span, false, wanted),
        .float_literal => |literal| {
            const lands: Type = if (wanted) |place| blk: {
                const landed = context.literalLandingType(place) orelse break :blk .float;
                break :blk if (landed.isFloating()) landed else .float;
            } else .float;
            const parsed = helpers.parseFloatLiteral(literal.text, lands) orelse {
                return constantError(analyzer, literal.span, "{s}", .{context.rangeMessage(lands)});
            };
            return .{ .value = .{ .double = parsed }, .value_type = lands };
        },
        .bool_literal => |literal| {
            return .{ .value = .{ .boolean = literal.value }, .value_type = .boolean };
        },
        .string_literal => |literal| {
            return .{ .value = .{ .string = literal.decoded }, .value_type = .string };
        },
        // `none` has no type of its own — the place it is written
        // into supplies one.  An annotation is such a place, so
        // `const x: long? = none` folds to the typed absence
        // (docs/ARGS.md D9); with nothing saying what is absent,
        // the refusal stands.
        .none_literal => |literal| {
            if (wanted) |place| {
                if (place == .optional) return .{ .value = .absent, .value_type = place };
                return constantError(analyzer, literal.span, "{s} is always there; only {s}? is ever none", .{
                    try analyzer.typeName(place),
                    try analyzer.typeName(place),
                });
            }
            return constantError(analyzer, literal.span, "none needs a place that says what it is absent of; annotate it: const name: T? = none", .{});
        },
        .name => |name| {
            const qualified = try naming.qualify(analyzer, analyzer.modules[module].prefix, name.text);
            if (analyzer.constant_names.get(qualified)) |index| {
                return evaluate(analyzer, index);
            }
            return constantError(analyzer, name.span, "unknown name {s} in a constant (constants may use literals and other constants)", .{name.text});
        },
        .field => |field| {
            // `Method.stored` — a member *is* a constant, so it
            // folds wherever constants fold (docs/ENUMS.md D8).
            if (try foldEnumMember(analyzer, module, field)) |member| return member;
            // geo.pi — an imported module's constant...
            if (field.target.* == .name) {
                const head = field.target.name.text;
                if (naming.importsModule(analyzer, module, head)) {
                    const joined = try naming.importedName(analyzer, module, try std.fmt.allocPrint(analyzer.arena, "{s}.{s}", .{ head, field.name }));
                    if (analyzer.constant_names.get(joined)) |index| {
                        // The fold happens inside the declaring
                        // module and the *value* crosses (D8); the
                        // gate is on saying the name.
                        const info = analyzer.constant_infos.items[index];
                        if (!naming.reachable(info.module, info.declaration.visibility, module)) {
                            try analyzer.fail(
                                "luce.sema.private",
                                field.span,
                                "{s} is private to {s}",
                                .{ field.name, naming.moduleName(analyzer, info.module) },
                            );
                            return null;
                        }
                        return evaluate(analyzer, index);
                    }
                    return constantError(analyzer, field.span, "{s} has no constant {s}", .{ head, field.name });
                }
            }
            // ...or a field of a struct constant.
            const target = (try fold(analyzer, module, field.target, null)) orelse return null;
            if (target.value != .strukt) {
                return constantError(analyzer, field.span, "{s} has no fields here", .{try analyzer.typeName(target.value_type)});
            }
            const layout = analyzer.structs.items[target.value.strukt.layout];
            const field_index = layout.findField(field.name) orelse {
                return constantError(analyzer, field.span, "{s} has no field {s}", .{ layout.name, field.name });
            };
            const owner = analyzer.struct_decls.items[target.value.strukt.layout];
            if (owner.module != module and
                field_index < owner.field_visibility.len and
                owner.field_visibility[field_index] == .private)
            {
                try analyzer.fail("luce.sema.private", field.span, "{s} of {s} is private to {s}", .{
                    field.name,
                    owner.declaration.name,
                    naming.moduleName(analyzer, owner.module),
                });
                return null;
            }
            return .{
                .value = target.value.strukt.fields[field_index],
                .value_type = layout.fields[field_index].field_type,
            };
        },
        .unary => |unary| {
            // -9223372036854775808 is one literal, not a negated
            // one: the sign folds in before the range is checked.
            if (unary.op == .negate and unary.operand.* == .int_literal) {
                return foldIntLiteral(analyzer, unary.operand.int_literal, unary.span, true, wanted);
            }
            // A minus does not move where a literal lands, so the
            // landing type passes straight through it.
            const inner_wanted = if (unary.op == .negate) wanted else null;
            const operand = (try fold(analyzer, module, unary.operand, inner_wanted)) orelse return null;
            switch (unary.op) {
                .negate => switch (operand.value) {
                    .long => |value| {
                        const arithmetic = operand.value_type.arithmeticType() orelse
                            return constantError(analyzer, unary.span, "cannot negate {s}", .{try analyzer.typeName(operand.value_type)});
                        const smallest: i64 = if (arithmetic == .int)
                            std.math.minInt(i32)
                        else
                            std.math.minInt(i64);
                        if (value == smallest) {
                            return constantError(analyzer, unary.span, "constant arithmetic overflows", .{});
                        }
                        return .{ .value = .{ .long = -value }, .value_type = arithmetic };
                    },
                    .double => |value| {
                        const arithmetic = operand.value_type.arithmeticType() orelse
                            return constantError(analyzer, unary.span, "cannot negate {s}", .{try analyzer.typeName(operand.value_type)});
                        const folded: f64 = if (arithmetic == .float)
                            @as(f32, @floatCast(-@as(f32, @floatCast(value))))
                        else
                            -value;
                        return .{ .value = .{ .double = folded }, .value_type = arithmetic };
                    },
                    else => return constantError(analyzer, unary.span, "cannot negate {s}", .{try analyzer.typeName(operand.value_type)}),
                },
                .logic_not => switch (operand.value) {
                    .boolean => |value| return .{ .value = .{ .boolean = !value }, .value_type = .boolean },
                    else => return constantError(analyzer, unary.span, "not needs a bool", .{}),
                },
                .bit_not => switch (operand.value) {
                    .long => |value| {
                        const arithmetic = operand.value_type.arithmeticType() orelse
                            return constantError(analyzer, unary.span, "~ works on int and long; {s} has no bits a program may see", .{try analyzer.typeName(operand.value_type)});
                        if (arithmetic.isFloating()) {
                            return constantError(analyzer, unary.span, "~ works on int and long; {s} has no bits a program may see", .{try analyzer.typeName(operand.value_type)});
                        }
                        return .{ .value = .{ .long = ~value }, .value_type = arithmetic };
                    },
                    else => return constantError(analyzer, unary.span, "~ works on int and long; {s} has no bits a program may see", .{try analyzer.typeName(operand.value_type)}),
                },
            }
        },
        .binary => |binary| return foldBinary(analyzer, module, binary, wanted),
        .list_literal => |literal| return foldSequence(analyzer, module, literal, wanted),
        .map_literal => |literal| return foldMap(analyzer, module, literal, wanted),
        .call => |call| {
            if (types.conversionNamed(call.callee) != null) {
                if (call.arguments.len != 1 or !helpers.argumentMayName(call.arguments[0], "value")) {
                    return constantError(analyzer, call.span, "{s}(value) takes one argument", .{call.callee});
                }
                const operand = (try fold(analyzer, module, call.arguments[0].value, null)) orelse return null;
                return foldConvert(analyzer, call, operand);
            }
            // ord is the one builtin that folds, so a character
            // can be written as one: `ord("(")` where another
            // language would need character literal syntax.
            if (std.mem.eql(u8, call.callee, "ord")) {
                if (call.arguments.len != 1 or !helpers.argumentMayName(call.arguments[0], "text")) {
                    return constantError(analyzer, call.span, "ord(text) takes one argument", .{});
                }
                const operand = (try fold(analyzer, module, call.arguments[0].value, null)) orelse return null;
                if (operand.value != .string) {
                    return constantError(analyzer, call.span, "ord takes a string, not {s}", .{
                        try analyzer.typeName(operand.value_type),
                    });
                }
                const codepoint = helpers.ordOfLiteral(operand.value.string) orelse {
                    return constantError(analyzer, call.span, "ord has no codepoint to read from an empty string", .{});
                };
                return .{ .value = .{ .long = codepoint }, .value_type = .long };
            }
            const qualified = try naming.qualify(analyzer, analyzer.modules[module].prefix, call.callee);
            if (analyzer.struct_names.get(qualified)) |layout_index| {
                return foldConstruct(analyzer, module, call.arguments, call.span, layout_index);
            }
            // `Method(8)` is a runtime lookup that answers `Method?`
            // (docs/ENUMS.md R2); it is not one of the call-shaped
            // forms this folder evaluates.  An enum member itself is
            // the constant form the reader can name.
            if (analyzer.enum_names.get(qualified)) |enum_index| {
                return constantError(
                    analyzer,
                    call.span,
                    "{s}(…) is a runtime lookup that answers {s}?; name the constant member: {s}.{s}",
                    .{
                        call.callee,
                        analyzer.enums.items[enum_index].name,
                        call.callee,
                        analyzer.enums.items[enum_index].members[0].name,
                    },
                );
            }
            if (analyzer.fold_subject) |subject| {
                return constantError(analyzer, call.span, "{s} is a constant: {s}(…) is a call", .{ subject, call.callee });
            }
            return constantError(analyzer, call.span, "constants fold at compile time; calls are not constant", .{});
        },
        .method => |method| {
            // module.Struct(...) construction reaches imports.
            if (method.target.* == .name) {
                const head = method.target.name.text;
                if (naming.importsModule(analyzer, module, head)) {
                    const joined = try naming.importedName(analyzer, module, try std.fmt.allocPrint(analyzer.arena, "{s}.{s}", .{ head, method.name }));
                    if (analyzer.struct_names.get(joined)) |layout_index| {
                        return foldConstruct(analyzer, module, method.arguments, method.span, layout_index);
                    }
                }
            }
            if (analyzer.fold_subject) |subject| {
                return constantError(analyzer, method.span, "{s} is a constant: {s}(…) is a call", .{ subject, method.name });
            }
            return constantError(analyzer, method.span, "constants fold at compile time; calls are not constant", .{});
        },
        .new_object, .slice_range, .index => {
            if (analyzer.fold_subject) |subject| {
                return constantError(analyzer, expression.span(), "{s} must fold at compile time; new, slicing, and indexing belong in a function", .{subject});
            }
            return constantError(analyzer, expression.span(), "file-scope const folds values or one flat literal container; new, slicing, and indexing belong in a function [CONSTANTS.md R-A, R-E]", .{});
        },
        .give, .copy => {
            return constantError(analyzer, expression.span(), "a constant initializer cannot take an ownership verb; give and copy belong in a function [OWNERSHIP.md S32]", .{});
        },
        .try_call => {
            return constantError(analyzer, expression.span(), "a constant is folded at compile time and nothing can fail there; try belongs in a function", .{});
        },
        // The program root owns materialized constants, not running
        // resources: a task's death point is a join, and only a
        // function scope can arrive at one (OWNERSHIP.md S35, S46).
        .spawn => {
            return constantError(analyzer, expression.span(), "a constant is folded at compile time and nothing runs there; spawn belongs in a function [OWNERSHIP.md S35, S46]", .{});
        },
        // A lambda becomes a function value, which is deliberately not
        // one of the initializer forms a file-scope `const` accepts
        // (docs/FUNCTIONS.md, As built).
        .lambda => {
            return constantError(analyzer, expression.span(), "a function value is not a constant initializer; declare it with func [FUNCTIONS.md]", .{});
        },
    }
}

/// `Method.stored` in a constant position — the folder's twin of
/// `builder.enumMemberAccess`, and it has to be a twin: a file-scope
/// `const` is folded here and a local value is lowered there, and the
/// two must agree about what a member is (docs/ENUMS.md D8).
///
/// Null when the dotted head names no enum this module can see,
/// which leaves every other reading of a `.` to the caller.
fn foldEnumMember(analyzer: *Analyzer, module: usize, field: ast.FieldAccess) Error!?TypedConstant {
    const chain = helpers.dottedChain(field.target) orelse return null;
    var written: std.ArrayList(u8) = .empty;
    defer written.deinit(analyzer.temporary);
    var at = chain.count;
    while (at > 0) {
        at -= 1;
        if (written.items.len != 0) try written.append(analyzer.temporary, '.');
        try written.appendSlice(analyzer.temporary, chain.parts[at]);
    }
    const index = found: {
        if (chain.count == 1) {
            const local = try naming.qualify(analyzer, analyzer.modules[module].prefix, written.items);
            break :found analyzer.enum_names.get(local) orelse return null;
        }
        if (!naming.importsModule(analyzer, module, chain.head())) return null;
        const imported = try naming.importedName(analyzer, module, written.items);
        break :found analyzer.enum_names.get(imported) orelse return null;
    };
    const info = analyzer.enum_decls.items[index];
    if (info.declaration.visibility == .private and info.module != module) {
        try analyzer.fail("luce.sema.private", field.span, "{s} is private to {s}", .{
            info.declaration.name,
            naming.moduleName(analyzer, info.module),
        });
        return null;
    }
    // Member values are folded in declaration order, so an enum the
    // fold has not reached yet has nothing to answer with.
    if (!info.settled) {
        return constantError(
            analyzer,
            field.span,
            "{s} is not settled yet: an enum's members are folded in declaration order, so {s} has to be declared above this one",
            .{ analyzer.enums.items[index].name, analyzer.enums.items[index].name },
        );
    }
    const declared = analyzer.enums.items[index];
    const member = declared.findMember(field.name) orelse {
        return constantError(analyzer, field.span, "{s} is not a member of {s}", .{ field.name, declared.name });
    };
    return .{
        .value = .{ .long = declared.members[member].value },
        .value_type = analyzer.enumType(index),
    };
}

fn foldConvert(analyzer: *Analyzer, call: ast.Call, operand: TypedConstant) Error!?TypedConstant {
    const produces = types.conversionNamed(call.callee).?;
    // An enum's two conversions fold like everything else here, and
    // to the same answers a run gives: `string(m)` is the member's
    // *name* and every numeric constructor is its number at that
    // width (docs/ENUMS.md D4, D5).
    if (operand.value_type == .enumeration) {
        const declared = analyzer.enums.items[operand.value_type.enumeration.index];
        if (produces == .string) {
            const member = declared.memberOfValue(operand.value.long).?;
            return .{ .value = .{ .string = declared.members[member].name }, .value_type = .string };
        }
        return foldConvert(analyzer, call, .{
            .value = operand.value,
            .value_type = declared.backing.asType(),
        });
    }
    if (produces == .string) {
        // The same text a run would print, spelled by the same
        // rules — but from a constant, so it is arena-owned here
        // rather than made by the runtime.
        // `{d}` on both, which is exactly what `runtime/text.zig`
        // writes: a double's text is Zig's Ryū-derived shortest
        // representation that round-trips, and a folded constant
        // has to be the same bytes a run would produce.
        const printed: []const u8 = switch (operand.value) {
            .long => |held| try std.fmt.allocPrint(analyzer.arena, "{d}", .{held}),
            .double => |held| try std.fmt.allocPrint(analyzer.arena, "{d}", .{held}),
            .boolean => |held| if (held) "true" else "false",
            .string => |held| held,
            else => return constantError(analyzer, call.span, "string() converts a number, a bool, a string, or an enum", .{}),
        };
        return .{ .value = .{ .string = printed }, .value_type = .string };
    }
    // Every other constructor is named for a numeric type and
    // takes any number (docs/TYPES.md §3): four destinations and
    // one rule, not sixteen pairs.
    const target: Type = switch (produces) {
        .byte => .byte,
        .short => .short,
        .int => .int,
        .long => .long,
        .half => .half,
        .float => .float,
        .double => .double,
        .boolean, .string, .list, .map, .array, .builder, .file, .task => unreachable, // answered above
    };
    if (!operand.value_type.isNumeric()) {
        return constantError(analyzer, call.span, "{s}() converts a number", .{call.callee});
    }
    if (operand.value_type.eql(target)) return operand;

    if (target.isFloating()) {
        const held = asDouble(operand);
        // Float to narrower float rounds to nearest, ties to even,
        // and reaches `inf` rather than trapping — the same
        // `@floatCast` `runtime/operators.zig` performs, so the
        // fold and the run answer the same bits.  A narrow float
        // is carried in the wide slot at its own precision,
        // exactly as its literal is.
        const narrowed: f64 = switch (target) {
            .half => @as(f16, @floatCast(held)),
            .float => @as(f32, @floatCast(held)),
            .double => held,
            else => unreachable, // isFloating names three
        };
        return .{ .value = .{ .double = narrowed }, .value_type = target };
    }

    // An integer destination.  The two sources fail differently
    // and neither may travel through the other's arithmetic: a
    // `long` past 2^53 does not survive a detour through f64.
    const bounds = target.integerRange();
    if (operand.value_type.isInteger()) {
        const whole = operand.value.long;
        if (whole < bounds.low or whole > bounds.high) {
            return constantError(analyzer, call.span, "constant conversion out of range", .{});
        }
        return .{ .value = .{ .long = whole }, .value_type = target };
    }
    // The same guard as `runtime/operators.zig` and
    // `08_llvm/lower.zig`, value for value: a conversion that
    // disagrees at the boundary is a different language.  And the
    // same rounding — half away from zero (docs/NUMERICS.md §7),
    // through the runtime's own function so there is one of it,
    // with the range checked *after* it.
    const rounded = operators.roundHalfAway(f64, operand.value.double);
    // One past the top, tested with `>=`: every bound here is a
    // small integer or a power of two and so exact in binary64,
    // where `maxInt` itself stops being once the width reaches 64.
    const lowest: f64 = @floatFromInt(bounds.low);
    const past_top: f64 = @floatFromInt(bounds.high + 1);
    if (std.math.isNan(rounded) or rounded < lowest or rounded >= past_top) {
        return constantError(analyzer, call.span, "constant conversion out of range", .{});
    }
    return .{ .value = .{ .long = @intFromFloat(rounded) }, .value_type = target };
}

fn foldConstruct(
    analyzer: *Analyzer,
    module: usize,
    call_arguments: []const ast.Argument,
    span: Span,
    layout_index: u32,
) Error!?TypedConstant {
    const layout = analyzer.structs.items[layout_index];
    const result_type: Type = .{ .strukt = layout_index };
    // The construction gates a body's construction has, in fold
    // order (VISIBILITY.md §3): the folder is a second front door
    // to the same struct, and it holds the same door policy.
    const decl_info = analyzer.struct_decls.items[layout_index];
    if (decl_info.declaration.visibility == .private and decl_info.module != module) {
        try analyzer.fail("luce.sema.private", span, "{s} is private to {s}", .{
            decl_info.declaration.name,
            naming.moduleName(analyzer, decl_info.module),
        });
        return null;
    }
    if (shapes.carriesObjects(analyzer, result_type)) {
        return constantError(analyzer, span, "{s} carries objects; only object-free structs fold in a constant [CONSTANTS.md R-E]", .{layout.name});
    }
    if (layout.fields.len == 0) {
        return constantError(analyzer, span, namespace_has_no_fields_message, .{layout.name});
    }
    const fields = try analyzer.arena.alloc(ConstantValue, layout.fields.len);
    const seen = try analyzer.temporary.alloc(bool, layout.fields.len);
    defer analyzer.temporary.free(seen);
    @memset(seen, false);
    for (call_arguments) |argument| {
        const name = argument.name orelse {
            return constantError(analyzer, argument.span, "{s} is built with named fields: {s}(field = ...)", .{ layout.name, layout.name });
        };
        const field_index = layout.findField(name) orelse {
            return constantError(analyzer, argument.span, "{s} has no field {s}", .{ layout.name, name });
        };
        if (decl_info.module != module and
            field_index < decl_info.field_visibility.len and
            decl_info.field_visibility[field_index] == .private)
        {
            try analyzer.fail("luce.sema.private", argument.span, "{s} of {s} is private to {s}", .{
                name,
                decl_info.declaration.name,
                naming.moduleName(analyzer, decl_info.module),
            });
            return null;
        }
        if (seen[field_index]) {
            return constantError(analyzer, argument.span, duplicate_field_message, .{name});
        }
        // The field's type is the place, so a literal lands on it
        // rather than taking the default and then failing to be it.
        const wanted_field = layout.fields[field_index].field_type;
        const value = (try fold(analyzer, module, argument.value, wanted_field)) orelse return null;
        const fitted = fit(value, wanted_field) orelse {
            return constantError(analyzer, argument.span, "{s}.{s} is {s}, got {s}", .{
                layout.name,
                name,
                try analyzer.typeName(layout.fields[field_index].field_type),
                try analyzer.typeName(value.value_type),
            });
        };
        seen[field_index] = true;
        fields[field_index] = fitted.value;
    }
    // A field nobody wrote takes its default (docs/ARGS.md D8), so
    // only the required ones can be missing.
    for (seen, 0..) |given, field_index| {
        if (given) continue;
        if (!defaults.fieldHasDefault(analyzer, layout_index, field_index)) continue;
        const filled = (try defaults.fieldDefault(analyzer, layout_index, field_index)) orelse return null;
        fields[field_index] = filled.value;
        seen[field_index] = true;
    }
    if (decl_info.module != module) {
        for (seen, 0..) |given, field_index| {
            if (given) continue;
            if (field_index >= decl_info.field_visibility.len) continue;
            if (decl_info.field_visibility[field_index] != .private) continue;
            try analyzer.fail(
                "luce.sema.private",
                span,
                "{s} cannot be constructed here: {s} is marked private in {s} and has no default; construction belongs to a public function of {s}",
                .{
                    decl_info.declaration.name,
                    layout.fields[field_index].name,
                    naming.moduleName(analyzer, decl_info.module),
                    naming.moduleName(analyzer, decl_info.module),
                },
            );
            return null;
        }
    }
    for (seen) |given| {
        if (given) continue;
        var missing: std.ArrayList(u8) = .empty;
        defer missing.deinit(analyzer.temporary);
        try context.writeMissingFields(&missing, analyzer.temporary, layout, seen);
        return constantError(analyzer, span, missing_field_message, .{ layout.name, missing.items });
    }
    return .{
        .value = .{ .strukt = .{ .layout = layout_index, .fields = fields } },
        .value_type = result_type,
    };
}

fn foldBinary(analyzer: *Analyzer, module: usize, binary: ast.Binary, wanted: ?Type) Error!?TypedConstant {
    // Coalescing is deliberately not one of the operators this folder
    // evaluates.  Optional values can be constants; selecting their
    // payload remains a runtime expression.
    if (binary.op == .coalesce) {
        return constantError(analyzer, binary.span, "else is a runtime optional operation and does not fold in a constant initializer", .{});
    }
    // Nor is there anything for a catch to catch: a constant is
    // folded at compile time and no call is made at all.
    if (binary.op == .catch_error) {
        return constantError(analyzer, binary.span, "catch has nothing to do in a constant: nothing is called there", .{});
    }
    // Where each side lands, by the two rules the lowering walk
    // uses (`builder.lowerBinaryOperands`), because a file-scope
    // `const` and a local expression must agree about what `2 * 0.1` is:
    // two untyped sides take the *place's* type, and otherwise the
    // typed side decides for the untyped one.
    const left_untyped = helpers.isUntypedNumber(binary.left);
    const right_untyped = helpers.isUntypedNumber(binary.right);
    var left: TypedConstant = undefined;
    var right: TypedConstant = undefined;
    if (left_untyped and !right_untyped) {
        // Short-circuit folds without evaluating the other side's
        // side effects — there are none, so plain evaluation is
        // fine, in whichever order the widths need.
        right = (try fold(analyzer, module, binary.right, wanted)) orelse return null;
        const decided = if (right.value_type.isNumeric()) right.value_type else null;
        left = (try fold(analyzer, module, binary.left, decided orelse wanted)) orelse return null;
    } else if (right_untyped and !left_untyped) {
        left = (try fold(analyzer, module, binary.left, wanted)) orelse return null;
        const decided = if (left.value_type.isNumeric()) left.value_type else null;
        right = (try fold(analyzer, module, binary.right, decided orelse wanted)) orelse return null;
    } else {
        left = (try fold(analyzer, module, binary.left, wanted)) orelse return null;
        right = (try fold(analyzer, module, binary.right, wanted)) orelse return null;
    }

    // Numbers that mix, folded (docs/TYPES.md §2).  A constant has
    // to reach the same answer a run would, so arithmetic widens
    // to the type the two meet at and comparison across the
    // ladders stays exact — the comparison calls the runtime's own
    // function rather than a second copy of it, because two
    // implementations of one judgment is how they come to
    // disagree.
    if (left.value_type.isNumeric() and right.value_type.isNumeric() and
        !left.value_type.eql(right.value_type))
    {
        // Across the ladders, a comparison compares the numbers
        // and not a conversion of them.  Both sides widen into
        // the pair the intrinsic speaks — `int` into `i64` and
        // `float` into `f64`, both lossless by construction — so
        // four pairs need one function (docs/TYPES.md §5).
        const crosses = left.value_type.isInteger() != right.value_type.isInteger();
        if (crosses) {
            if (helpers.comparisonOf(binary.op)) |written| {
                const int_first = left.value_type.isInteger();
                const whole = if (int_first) left else right;
                const fraction = if (int_first) right else left;
                return .{
                    .value = .{ .boolean = operators.compareLongDouble(
                        if (int_first) written else written.mirrored(),
                        whole.value.long,
                        asDouble(fraction),
                    ) },
                    .value_type = .boolean,
                };
            }
        }
        const meeting = Type.unified(left.value_type, right.value_type).?;
        left = widen(left, meeting);
        right = widen(right, meeting);
    }

    // `/` is real division and answers a float whatever it
    // divides, so two integer constants widen here too — and
    // `1 / 0` folds to `inf` rather than refusing
    // (docs/NUMERICS.md §2).
    if (binary.op == .divide and left.value_type.isInteger() and right.value_type.isInteger()) {
        left = widen(left, .double);
        right = widen(right, .double);
    }

    if (!left.value_type.eql(right.value_type)) {
        return constantError(analyzer, binary.span, mismatched_operands_message, .{
            context.operatorText(binary.op),
            try analyzer.typeName(left.value_type),
            try analyzer.typeName(right.value_type),
        });
    }
    switch (binary.op) {
        .logic_and, .logic_or => {
            if (left.value != .boolean) return constantError(analyzer, binary.span, "and/or need bool operands", .{});
            const folded = if (binary.op == .logic_and)
                left.value.boolean and right.value.boolean
            else
                left.value.boolean or right.value.boolean;
            return .{ .value = .{ .boolean = folded }, .value_type = .boolean };
        },
        // The bit set folds with the run's own semantics
        // (docs/BITWISE.md D6): transport, two's complement, and
        // the count as the one refusal — a constant shift with a
        // bad count is the compile-time face of the trap.
        .bit_and, .bit_or, .bit_xor, .shift_left, .shift_right => {
            if (left.value != .long or
                (left.value_type != .int and left.value_type != .long))
            {
                return constantError(analyzer, binary.span, "{s} works on int and long; {s} has no bits a program may see", .{
                    context.operatorText(binary.op),
                    try analyzer.typeName(left.value_type),
                });
            }
            const a = left.value.long;
            const b = right.value.long;
            const narrow = left.value_type == .int;
            const folded: i64 = switch (binary.op) {
                .bit_and => a & b,
                .bit_or => a | b,
                .bit_xor => a ^ b,
                .shift_left, .shift_right => blk: {
                    const width: i64 = if (narrow) 32 else 64;
                    if (b < 0 or b >= width) {
                        return constantError(analyzer, binary.span, "constant shift count out of range", .{});
                    }
                    if (narrow) {
                        const held: i32 = @intCast(a);
                        const count: u5 = @intCast(b);
                        break :blk if (binary.op == .shift_left)
                            held << count
                        else
                            held >> count;
                    }
                    const count: u6 = @intCast(b);
                    break :blk if (binary.op == .shift_left)
                        a << count
                    else
                        a >> count;
                },
                else => unreachable,
            };
            return .{ .value = .{ .long = folded }, .value_type = left.value_type };
        },
        .add, .subtract, .multiply, .divide, .floor_divide, .modulo => switch (left.value) {
            .long => |a| {
                const b = right.value.long;
                const narrow = left.value_type == .int;
                const smallest: i64 = if (narrow) std.math.minInt(i32) else std.math.minInt(i64);
                const folded: i64 = switch (binary.op) {
                    .add => blk: {
                        const result = @addWithOverflow(a, b);
                        if (result[1] != 0) return constantError(analyzer, binary.span, "constant arithmetic overflows", .{});
                        break :blk result[0];
                    },
                    .subtract => blk: {
                        const result = @subWithOverflow(a, b);
                        if (result[1] != 0) return constantError(analyzer, binary.span, "constant arithmetic overflows", .{});
                        break :blk result[0];
                    },
                    .multiply => blk: {
                        const result = @mulWithOverflow(a, b);
                        if (result[1] != 0) return constantError(analyzer, binary.span, "constant arithmetic overflows", .{});
                        break :blk result[0];
                    },
                    // `/` widened both sides before this switch,
                    // so an integer one cannot arrive here
                    // (docs/NUMERICS.md §2).
                    .divide => unreachable,
                    // `//` and `%` floor together
                    // (docs/NUMERICS.md §3); the folder answers
                    // what a run answers.
                    .floor_divide => blk: {
                        if (b == 0) return constantError(analyzer, binary.span, "constant division by zero", .{});
                        if (a == smallest and b == -1) {
                            return constantError(analyzer, binary.span, "constant arithmetic overflows", .{});
                        }
                        break :blk @divFloor(a, b);
                    },
                    .modulo => blk: {
                        if (b == 0) return constantError(analyzer, binary.span, "constant division by zero", .{});
                        if (a == smallest and b == -1) {
                            return constantError(analyzer, binary.span, "constant arithmetic overflows", .{});
                        }
                        break :blk @mod(a, b);
                    },
                    else => unreachable,
                };
                // At `int` the i64 arithmetic above cannot itself
                // overflow, so the width's own range is checked
                // here — and it is checked, because `int` traps at
                // 2^31 when a program runs and a constant must not
                // quietly say otherwise (docs/TYPES.md §4).
                if (narrow and (folded < std.math.minInt(i32) or folded > std.math.maxInt(i32))) {
                    return constantError(analyzer, binary.span, "constant arithmetic overflows", .{});
                }
                return .{ .value = .{ .long = folded }, .value_type = left.value_type };
            },
            .double => |a| {
                const b = right.value.double;
                // At `float` every operand and every answer is
                // rounded to binary32, because that is what a run
                // would compute; folding at binary64 and narrowing
                // afterwards is a double rounding.
                const narrow = left.value_type == .float;
                const folded: f64 = if (narrow)
                    foldFloat(f32, binary.op, @floatCast(a), @floatCast(b))
                else
                    foldFloat(f64, binary.op, a, b);
                return .{ .value = .{ .double = folded }, .value_type = left.value_type };
            },
            .string => |a| {
                if (binary.op != .add) {
                    return constantError(analyzer, binary.span, "string supports + only", .{});
                }
                const joined = try std.mem.concat(analyzer.arena, u8, &.{ a, right.value.string });
                return .{ .value = .{ .string = joined }, .value_type = .string };
            },
            else => return constantError(analyzer, binary.span, "{s} does not support this operator", .{
                try analyzer.typeName(left.value_type),
            }),
        },
        .equal, .not_equal, .less, .less_equal, .greater, .greater_equal => {
            const ordering = binary.op != .equal and binary.op != .not_equal;
            // Equality only, folded or run (docs/ENUMS.md D6).
            if (ordering and left.value_type == .enumeration) {
                return constantError(
                    analyzer,
                    binary.span,
                    "{s} is a set of names and has no order; write int(…) on both sides to compare the numbers behind them",
                    .{try analyzer.typeName(left.value_type)},
                );
            }
            const folded: bool = switch (left.value) {
                .long => |a| helpers.compareOrder(binary.op, a, right.value.long),
                .double => |a| helpers.compareOrder(binary.op, a, right.value.double),
                .string => |a| blk: {
                    const order = std.mem.order(u8, a, right.value.string);
                    break :blk switch (binary.op) {
                        .equal => order == .eq,
                        .not_equal => order != .eq,
                        .less => order == .lt,
                        .less_equal => order != .gt,
                        .greater => order == .gt,
                        .greater_equal => order != .lt,
                        else => unreachable,
                    };
                },
                .boolean => |a| blk: {
                    if (ordering) return constantError(analyzer, binary.span, "bool has no ordering", .{});
                    const same = a == right.value.boolean;
                    break :blk if (binary.op == .equal) same else !same;
                },
                .strukt => return constantError(analyzer, binary.span, "struct constants have no comparison", .{}),
                .container => |row| blk: {
                    if (ordering) return constantError(analyzer, binary.span, "constant containers have identity but no ordering", .{});
                    const same = row == right.value.container;
                    break :blk if (binary.op == .equal) same else !same;
                },
                // An absent constant reaches an operator only through
                // another constant's name; the test for absence is a
                // function's `!= none`, and a fold has no narrowing
                // to make of the answer.
                .absent => return constantError(analyzer, binary.span, "an absent constant has no operators; test it in a function", .{}),
            };
            return .{ .value = .{ .boolean = folded }, .value_type = .boolean };
        },
        .coalesce, .catch_error => unreachable, // answered above
    }
}
