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
const source_mod = @import("../source.zig");
const helpers = @import("helpers.zig");
const context = @import("context.zig");
const ast = @import("../parse.zig").ast;
const mir = @import("../mir.zig");
const types = @import("../support/types.zig");
// The fold answers what a run would answer, so where a judgment has
// one implementation in `libluce_rt` this calls it rather than keeping
// a second copy that could drift (docs/NUMERICS.md §5).
const operators = @import("../runtime/operators.zig");

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
        (context.literalLandingType(place) orelse .i64)
    else
        .i64;
    if (lands.isFloating()) {
        const parsed = helpers.parseIntLiteralAsFloat(literal.text, negated, lands) orelse {
            return constantError(analyzer, span, "{s}", .{context.rangeMessage(lands)});
        };
        return .{ .value = .{ .float = parsed }, .value_type = lands };
    }
    const parsed = helpers.parseIntLiteral(literal.text, negated, lands) orelse {
        return constantError(analyzer, span, "{s}", .{context.rangeMessage(lands)});
    };
    return .{ .value = .{ .integer = parsed }, .value_type = lands };
}

/// A folded number's value as an `f64`, whichever family it came from.
/// `ConstantValue` uses wide host storage while `value_type` preserves the
/// source representation.
fn asF64(held: TypedConstant) f64 {
    return switch (held.value) {
        .integer => |whole| @floatFromInt(whole),
        .float => |fraction| fraction,
        else => unreachable, // asked only of a number
    };
}

/// Convert a folded number for a language construct with a specified result
/// representation. Integer true division is the remaining caller; source
/// conversions use the fully checked path below.
pub fn widen(held: TypedConstant, to: Type) TypedConstant {
    if (held.value_type.eql(to)) return held;
    if (to.isInteger()) return .{ .value = held.value, .value_type = to };
    return .{ .value = .{ .float = asF64(held) }, .value_type = to };
}

/// Make one folded value fit the type of its landing place. This is the
/// constant-folding twin of `FunctionBuilder.fit`: concrete values match
/// exactly, while a present `T` may stand in a `T?` place. Presence needs no
/// extra `ConstantValue` tag --
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

const IntegerFoldError = error{
    arithmetic_overflow,
    division_by_zero,
    shift_out_of_range,
};

/// Fold one integer operation at the width the program wrote. The i128
/// constant carrier is only transport; every calculation narrows before it
/// runs so compile-time arithmetic has exactly the runtime's overflow rules.
fn foldIntegerAt(comptime T: type, op: ast.BinaryOp, a: i128, b: i128) IntegerFoldError!i128 {
    const left: T = @intCast(a);
    const right: T = @intCast(b);
    const result: T = switch (op) {
        .add => result: {
            const added = @addWithOverflow(left, right);
            if (added[1] != 0) return error.arithmetic_overflow;
            break :result added[0];
        },
        .subtract => result: {
            const subtracted = @subWithOverflow(left, right);
            if (subtracted[1] != 0) return error.arithmetic_overflow;
            break :result subtracted[0];
        },
        .multiply => result: {
            const multiplied = @mulWithOverflow(left, right);
            if (multiplied[1] != 0) return error.arithmetic_overflow;
            break :result multiplied[0];
        },
        .floor_divide, .modulo => result: {
            if (right == 0) return error.division_by_zero;
            if (comptime @typeInfo(T).int.signedness == .signed) {
                if (left == std.math.minInt(T) and right == -1) {
                    return error.arithmetic_overflow;
                }
            }
            break :result if (op == .floor_divide)
                @divFloor(left, right)
            else
                @mod(left, right);
        },
        .bit_and => left & right,
        .bit_or => left | right,
        .bit_xor => left ^ right,
        .shift_left, .shift_right => result: {
            if (comptime @typeInfo(T).int.signedness == .signed) {
                if (right < 0) return error.shift_out_of_range;
            }
            if (right >= @bitSizeOf(T)) return error.shift_out_of_range;
            const count: std.math.Log2Int(T) = @intCast(right);
            if (op == .shift_left) {
                const shifted = @shlWithOverflow(left, count);
                if (shifted[1] != 0) return error.arithmetic_overflow;
                break :result shifted[0];
            }
            break :result left >> count;
        },
        .divide => unreachable, // integer `/` is converted to f64 first
        else => unreachable,
    };
    return @intCast(result);
}

fn foldIntegerForType(of: Type, op: ast.BinaryOp, a: i128, b: i128) IntegerFoldError!i128 {
    return switch (of) {
        .u8 => foldIntegerAt(u8, op, a, b),
        .u16 => foldIntegerAt(u16, op, a, b),
        .u32 => foldIntegerAt(u32, op, a, b),
        .u64 => foldIntegerAt(u64, op, a, b),
        .i8 => foldIntegerAt(i8, op, a, b),
        .i16 => foldIntegerAt(i16, op, a, b),
        .i32 => foldIntegerAt(i32, op, a, b),
        .i64 => foldIntegerAt(i64, op, a, b),
        else => unreachable,
    };
}

fn foldBitNot(of: Type, held: i128) i128 {
    return switch (of) {
        .u8 => @intCast(~@as(u8, @intCast(held))),
        .u16 => @intCast(~@as(u16, @intCast(held))),
        .u32 => @intCast(~@as(u32, @intCast(held))),
        .u64 => @intCast(~@as(u64, @intCast(held))),
        .i8 => @intCast(~@as(i8, @intCast(held))),
        .i16 => @intCast(~@as(i16, @intCast(held))),
        .i32 => @intCast(~@as(i32, @intCast(held))),
        .i64 => @intCast(~@as(i64, @intCast(held))),
        else => unreachable,
    };
}

fn constantError(analyzer: *Analyzer, span: Span, comptime format: []const u8, arguments: anytype) Error!?TypedConstant {
    try analyzer.fail("luce.sema.const", span, format, arguments);
    return null;
}

/// Translate one already-checked flat element into the serialized
/// constant-pool vocabulary. str bytes join the ordinary text
/// pool so pruning and both engines have one spelling for them.
fn encodeValue(
    analyzer: *Analyzer,
    value: ConstantValue,
) Error!mir.ConstantValue {
    return switch (value) {
        .integer => |held| .{ .integer = held },
        .float => |held| .{ .float = held },
        .boolean => |held| .{ .boolean = held },
        .str => |held| .{ .str = try analyzer.pool.intern(held) },
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

/// Return a folded element unchanged. Contextual literals already landed at
/// the container's element type, and concrete values never convert here.
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
            .class, .map, .builder, .file, .task => {},
        };
    }
    if (literal.elements.len == 0 and wanted_element == null) {
        return constantError(
            analyzer,
            literal.span,
            "an empty [] needs a list[T] or array[T, _] annotation",
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
    return switch (left.value) {
        .integer => |held| right.value == .integer and right.value.integer == held,
        .str => |held| right.value == .str and std.mem.eql(u8, held, right.value.str),
        else => false,
    };
}

fn mapKeyName(analyzer: *Analyzer, key: TypedConstant) Error![]const u8 {
    // An enum key is a number underneath, but nobody wrote the number:
    // the duplicate the reader has to find is spelled `Key.left`
    // (docs/ENUMS.md, As built 2026-08-12).
    if (key.value_type == .enumeration and key.value == .integer) {
        const declared = analyzer.enums.items[key.value_type.enumeration.index];
        if (declared.memberOfValue(key.value.integer)) |member| {
            return std.fmt.allocPrint(analyzer.arena, "{s}.{s}", .{
                declared.name,
                declared.members[member].name,
            });
        }
    }
    return switch (key.value) {
        .integer => |held| std.fmt.allocPrint(analyzer.arena, "{d}", .{held}),
        .str => |held| std.fmt.allocPrint(analyzer.arena, "\"{s}\"", .{held}),
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
        // An unannotated integer key lands directly on the default
        // `i64`; an annotation may contextualize it to any width.
        const key_place = wanted_key orelse if (index == 0) Type.i64 else keys[0].value_type;
        var key = (try fold(analyzer, module, entry.key, key_place)) orelse return null;
        if (key.value_type.widensTo(key_place)) key = widen(key, key_place);
        if (index == 0 and wanted_key == null) {
            if (key.value_type == .str) {
                wanted_key = .str;
            } else if (key.value_type == .enumeration) {
                // An enum member is a constant by construction (D8), so
                // a keymap folds into the program root like any other
                // constant map — keyed by the enum, not by its number
                // (docs/ENUMS.md, As built 2026-08-12).
                wanted_key = key.value_type;
            } else if (key.value_type.isInteger()) {
                wanted_key = key.value_type;
            }
        }
        const key_type = wanted_key orelse key.value_type;
        key = fitElement(key, key_type);
        if (!key_type.isInteger() and key_type != .str and key_type != .enumeration) {
            return constantError(analyzer, entry.key.span(), "map keys are an integer, str or an enum, got {s}", .{
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
/// conversion constructors, enum members and conversions from enums,
/// typed absence, object-free value structs, and flat literal
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
                const landed = context.literalLandingType(place) orelse break :blk .f64;
                break :blk if (landed.isFloating()) landed else .f64;
            } else .f64;
            const parsed = helpers.parseFloatLiteral(literal.text, lands) orelse {
                return constantError(analyzer, literal.span, "{s}", .{context.rangeMessage(lands)});
            };
            return .{ .value = .{ .float = parsed }, .value_type = lands };
        },
        .bool_literal => |literal| {
            return .{ .value = .{ .boolean = literal.value }, .value_type = .boolean };
        },
        .char_literal => |literal| {
            return .{ .value = .{ .integer = literal.value }, .value_type = .char };
        },
        .string_literal => |literal| {
            return .{ .value = .{ .str = literal.decoded }, .value_type = .str };
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
                    .integer => |value| {
                        const arithmetic = operand.value_type.arithmeticType() orelse
                            return constantError(analyzer, unary.span, "cannot negate {s}", .{try analyzer.typeName(operand.value_type)});
                        if (arithmetic.isUnsigned()) {
                            return constantError(analyzer, unary.span, "cannot negate {s}; unsigned integers have no negative values", .{try analyzer.typeName(operand.value_type)});
                        }
                        if (value == arithmetic.integerRange().low) {
                            return constantError(analyzer, unary.span, "constant arithmetic overflows", .{});
                        }
                        return .{ .value = .{ .integer = -value }, .value_type = arithmetic };
                    },
                    .float => |value| {
                        const arithmetic = operand.value_type.arithmeticType() orelse
                            return constantError(analyzer, unary.span, "cannot negate {s}", .{try analyzer.typeName(operand.value_type)});
                        const folded: f64 = switch (arithmetic) {
                            .f16 => @as(f16, @floatCast(-@as(f16, @floatCast(value)))),
                            .f32 => @as(f32, @floatCast(-@as(f32, @floatCast(value)))),
                            .f64 => -value,
                            else => unreachable,
                        };
                        return .{ .value = .{ .float = folded }, .value_type = arithmetic };
                    },
                    else => return constantError(analyzer, unary.span, "cannot negate {s}", .{try analyzer.typeName(operand.value_type)}),
                },
                .logic_not => switch (operand.value) {
                    .boolean => |value| return .{ .value = .{ .boolean = !value }, .value_type = .boolean },
                    else => return constantError(analyzer, unary.span, "not needs a bool", .{}),
                },
                .bit_not => switch (operand.value) {
                    .integer => |value| {
                        const arithmetic = operand.value_type.arithmeticType() orelse
                            return constantError(analyzer, unary.span, "~ works on integers; {s} has no bits a program may see", .{try analyzer.typeName(operand.value_type)});
                        if (arithmetic.isFloating()) {
                            return constantError(analyzer, unary.span, "~ works on integers; {s} has no bits a program may see", .{try analyzer.typeName(operand.value_type)});
                        }
                        return .{ .value = .{ .integer = foldBitNot(arithmetic, value) }, .value_type = arithmetic };
                    },
                    else => return constantError(analyzer, unary.span, "~ works on integers; {s} has no bits a program may see", .{try analyzer.typeName(operand.value_type)}),
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
            const qualified = try naming.qualify(analyzer, analyzer.modules[module].prefix, call.callee);
            if (analyzer.alias_names.get(qualified)) |alias_index| {
                const target = (try resolve.resolveAlias(analyzer, module, alias_index, call.span)) orelse
                    return null;
                switch (target) {
                    .strukt => |layout_index| return foldConstruct(analyzer, module, call.arguments, call.span, layout_index),
                    .enumeration => |reference| {
                        return constantError(
                            analyzer,
                            call.span,
                            "{s}(…) is a runtime lookup that answers {s}?; name a constant member through {s}.member",
                            .{ call.callee, analyzer.enums.items[reference.index].name, call.callee },
                        );
                    },
                    .u8, .u16, .u32, .u64, .i8, .i16, .i32, .i64, .f16, .f32, .f64, .char, .str, .bytes => {
                        if (call.arguments.len != 1 or !helpers.argumentMayName(call.arguments[0], "value")) {
                            return constantError(analyzer, call.span, "{s}(value) takes one argument", .{call.callee});
                        }
                        const operand = (try fold(analyzer, module, call.arguments[0].value, null)) orelse return null;
                        return foldConvertAs(analyzer, call, operand, builtinForScalar(target));
                    },
                    else => return constantError(
                        analyzer,
                        call.span,
                        "{s} is a type alias for {s}, not a constant constructor",
                        .{ call.callee, try analyzer.typeName(target) },
                    ),
                }
            }
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
                    if (analyzer.alias_names.get(joined)) |alias_index| {
                        const target = (try resolve.resolveAlias(analyzer, module, alias_index, method.span)) orelse
                            return null;
                        switch (target) {
                            .strukt => |layout_index| return foldConstruct(analyzer, module, method.arguments, method.span, layout_index),
                            .u8, .u16, .u32, .u64, .i8, .i16, .i32, .i64, .f16, .f32, .f64, .char, .str, .bytes => {
                                if (method.arguments.len != 1 or !helpers.argumentMayName(method.arguments[0], "value")) {
                                    return constantError(analyzer, method.span, "{s}(value) takes one argument", .{method.name});
                                }
                                const operand = (try fold(analyzer, module, method.arguments[0].value, null)) orelse return null;
                                const call: ast.Call = .{
                                    .callee = method.name,
                                    .arguments = method.arguments,
                                    .span = method.span,
                                };
                                return foldConvertAs(analyzer, call, operand, builtinForScalar(target));
                            },
                            else => return constantError(
                                analyzer,
                                method.span,
                                "{s}.{s} is a type alias for {s}, not a constant constructor",
                                .{ head, method.name, try analyzer.typeName(target) },
                            ),
                        }
                    }
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
        // A call suffix is a call whatever stands in front of it.
        .value_call => |written| {
            if (analyzer.fold_subject) |subject| {
                return constantError(analyzer, written.span, "{s} is a constant: a call is not", .{subject});
            }
            return constantError(analyzer, written.span, "constants fold at compile time; calls are not constant", .{});
        },
        .new_object, .slice_range, .index => {
            if (analyzer.fold_subject) |subject| {
                return constantError(analyzer, expression.span(), "{s} must fold at compile time; new, slicing, and indexing belong in a function", .{subject});
            }
            return constantError(analyzer, expression.span(), "file-scope const folds values or one flat literal container; new, slicing, and indexing belong in a function [CONSTANTS.md R-A, R-E]", .{});
        },
        .try_call => {
            return constantError(analyzer, expression.span(), "a constant is folded at compile time and nothing can fail there; try belongs in a function", .{});
        },
        // The program root owns materialized constants, not running
        // resources: a task's death point is a join, and only a
        // function scope can arrive at one (MEMORY.md).
        .spawn => {
            return constantError(analyzer, expression.span(), "a constant is folded at compile time and nothing runs there; spawn belongs in a function", .{});
        },
        // A lambda becomes a function value, which is deliberately not
        // one of the initializer forms a file-scope `const` accepts
        // (docs/FUNCTIONS.md, As built).
        .lambda, .closure => {
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
            if (analyzer.enum_names.get(local)) |index| break :found index;
            if (analyzer.alias_names.get(local)) |alias_index| {
                const target = (try resolve.resolveAlias(analyzer, module, alias_index, field.span)) orelse
                    return null;
                if (target == .enumeration) break :found target.enumeration.index;
            }
            return null;
        }
        if (!naming.importsModule(analyzer, module, chain.head())) return null;
        const imported = try naming.importedName(analyzer, module, written.items);
        if (analyzer.enum_names.get(imported)) |index| break :found index;
        if (analyzer.alias_names.get(imported)) |alias_index| {
            const target = (try resolve.resolveAlias(analyzer, module, alias_index, field.span)) orelse
                return null;
            if (target == .enumeration) break :found target.enumeration.index;
        }
        return null;
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
        .value = .{ .integer = declared.members[member].value },
        .value_type = analyzer.enumType(index),
    };
}

fn foldConvert(analyzer: *Analyzer, call: ast.Call, operand: TypedConstant) Error!?TypedConstant {
    return foldConvertAs(analyzer, call, operand, types.conversionNamed(call.callee).?);
}

fn foldConvertAs(
    analyzer: *Analyzer,
    call: ast.Call,
    operand: TypedConstant,
    produces: types.Builtin,
) Error!?TypedConstant {
    // An enum's two conversions fold like everything else here, and
    // to the same answers a run gives: `string(m)` is the member's
    // *name* and every numeric constructor is its number at that
    // width (docs/ENUMS.md D4, D5).
    if (operand.value_type == .enumeration) {
        const declared = analyzer.enums.items[operand.value_type.enumeration.index];
        if (produces == .str) {
            const member = declared.memberOfValue(operand.value.integer).?;
            return .{ .value = .{ .str = declared.members[member].name }, .value_type = .str };
        }
        if (produces == .char or produces == .bytes) {
            return constantError(analyzer, call.span, "{s}() cannot convert an enum", .{call.callee});
        }
        return foldConvertAs(analyzer, call, .{
            .value = operand.value,
            .value_type = declared.backing.asType(),
        }, produces);
    }
    if (produces == .char) {
        if (operand.value_type == .char) return operand;
        if (!operand.value_type.isInteger()) {
            return constantError(analyzer, call.span, "char() converts an integer", .{});
        }
        const scalar = operand.value.integer;
        if (scalar < 0 or scalar > 0x10ffff or (scalar >= 0xd800 and scalar <= 0xdfff)) {
            return constantError(analyzer, call.span, "integer is not a Unicode scalar value", .{});
        }
        return .{ .value = .{ .integer = scalar }, .value_type = .char };
    }
    if (produces == .bytes) {
        if (operand.value_type == .bytes) return operand;
        if (operand.value_type != .str) {
            return constantError(analyzer, call.span, "bytes() converts str, list[u8], or array[u8, _]", .{});
        }
        return .{ .value = operand.value, .value_type = .bytes };
    }
    if (produces == .str) {
        // The same text a run would print, spelled by the same
        // rules — but from a constant, so it is arena-owned here
        // rather than made by the runtime.
        // `{d}` on both, which is exactly what `runtime/text.zig`
        // writes: a double's text is Zig's Ryū-derived shortest
        // representation that round-trips, and a folded constant
        // has to be the same bytes a run would produce.
        const printed: []const u8 = switch (operand.value) {
            .integer => |held| if (operand.value_type == .char)
                try encodeScalar(analyzer.arena, held)
            else
                try std.fmt.allocPrint(analyzer.arena, "{d}", .{held}),
            .float => |held| try std.fmt.allocPrint(analyzer.arena, "{d}", .{held}),
            .boolean => |held| if (held) "true" else "false",
            .str => |held| held,
            else => return constantError(analyzer, call.span, "str() converts a number, a bool, a str, or an enum", .{}),
        };
        return .{ .value = .{ .str = printed }, .value_type = .str };
    }
    // Every other constructor is named for a numeric type and
    // takes any number (docs/TYPES.md §3): four destinations and
    // one rule, not sixteen pairs.
    const target: Type = switch (produces) {
        .u8 => .u8,
        .u16 => .u16,
        .u32 => .u32,
        .u64 => .u64,
        .i8 => .i8,
        .i16 => .i16,
        .i32 => .i32,
        .i64 => .i64,
        .f16 => .f16,
        .f32 => .f32,
        .f64 => .f64,
        .boolean, .char, .str, .bytes, .list, .map, .array, .builder, .file, .task => unreachable, // answered above
    };
    if (operand.value_type == .char) {
        if (target != .u32) {
            return constantError(analyzer, call.span, "only u32() converts a char code point", .{});
        }
        return .{ .value = operand.value, .value_type = .u32 };
    }
    if (!operand.value_type.isNumeric()) {
        return constantError(analyzer, call.span, "{s}() converts a number", .{call.callee});
    }
    if (operand.value_type.eql(target)) return operand;

    if (target.isFloating()) {
        const held = asF64(operand);
        // Floating-point narrowing rounds to nearest, ties to even,
        // and reaches `inf` rather than trapping — the same
        // `@floatCast` `runtime/operators.zig` performs, so the
        // fold and the run answer the same bits.  A narrow float
        // is carried in the wide slot at its own precision,
        // exactly as its literal is.
        const narrowed: f64 = switch (target) {
            .f16 => @as(f16, @floatCast(held)),
            .f32 => @as(f32, @floatCast(held)),
            .f64 => held,
            else => unreachable, // isFloating names three
        };
        return .{ .value = .{ .float = narrowed }, .value_type = target };
    }

    // An integer destination.  The two sources fail differently
    // and neither may travel through the other's arithmetic: a
    // `long` past 2^53 does not survive a detour through f64.
    const bounds = target.integerRange();
    if (operand.value_type.isInteger()) {
        const whole = operand.value.integer;
        if (whole < bounds.low or whole > bounds.high) {
            return constantError(analyzer, call.span, "constant conversion out of range", .{});
        }
        return .{ .value = .{ .integer = whole }, .value_type = target };
    }
    // The same guard as `runtime/operators.zig` and
    // `codegen/lower.zig`, value for value: a conversion that
    // disagrees at the boundary is a different language.  And the
    // same rounding — half away from zero (docs/NUMERICS.md §7),
    // through the runtime's own function so there is one of it,
    // with the range checked *after* it.
    const rounded = @trunc(operand.value.float);
    // One past the top, tested with `>=`: every bound here is a
    // small integer or a power of two and so exact in binary64,
    // where `maxInt` itself stops being once the width reaches 64.
    const lowest: f64 = @floatFromInt(bounds.low);
    const past_top: f64 = @floatFromInt(bounds.high + 1);
    if (std.math.isNan(rounded) or rounded < lowest or rounded >= past_top) {
        return constantError(analyzer, call.span, "constant conversion out of range", .{});
    }
    return .{ .value = .{ .integer = @intFromFloat(rounded) }, .value_type = target };
}

fn builtinForScalar(target: Type) types.Builtin {
    return switch (target) {
        .u8 => .u8,
        .u16 => .u16,
        .u32 => .u32,
        .u64 => .u64,
        .i8 => .i8,
        .i16 => .i16,
        .i32 => .i32,
        .i64 => .i64,
        .f16 => .f16,
        .f32 => .f32,
        .f64 => .f64,
        .char => .char,
        .str => .str,
        .bytes => .bytes,
        else => unreachable,
    };
}

fn encodeScalar(arena: std.mem.Allocator, held: i128) Error![]const u8 {
    var buffer: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(@intCast(held), &buffer) catch unreachable;
    return try arena.dupe(u8, buffer[0..length]);
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
    if (binary.op == .identity) {
        return constantError(analyzer, binary.span, "is compares class identity at runtime and cannot be used in a constant", .{});
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

    // Concrete numeric values never meet through an implicit conversion.
    // Literal contextualization happens while each operand is folded; once
    // both values are concrete, differing widths are a source error.

    // `/` is real division and answers a float whatever it
    // divides, so two integer constants widen here too — and
    // `1 / 0` folds to `inf` rather than refusing
    // (docs/NUMERICS.md §2).
    if (binary.op == .divide and left.value_type.isInteger() and right.value_type.isInteger()) {
        left = widen(left, .f64);
        right = widen(right, .f64);
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
            if (left.value != .integer or !left.value_type.isInteger()) {
                return constantError(analyzer, binary.span, "{s} works on integers; {s} has no bits a program may see", .{
                    context.operatorText(binary.op),
                    try analyzer.typeName(left.value_type),
                });
            }
            const a = left.value.integer;
            const b = right.value.integer;
            const folded = foldIntegerForType(left.value_type, binary.op, a, b) catch |mistake| switch (mistake) {
                error.shift_out_of_range => return constantError(analyzer, binary.span, "constant shift count out of range", .{}),
                error.arithmetic_overflow => return constantError(analyzer, binary.span, "constant arithmetic overflows", .{}),
                error.division_by_zero => unreachable,
            };
            return .{ .value = .{ .integer = folded }, .value_type = left.value_type };
        },
        .add, .subtract, .multiply, .divide, .floor_divide, .modulo => switch (left.value) {
            .integer => |a| {
                if (!left.value_type.isInteger()) {
                    return constantError(analyzer, binary.span, "{s} does not support this operator", .{try analyzer.typeName(left.value_type)});
                }
                const b = right.value.integer;
                const folded = foldIntegerForType(left.value_type, binary.op, a, b) catch |mistake| switch (mistake) {
                    error.division_by_zero => return constantError(analyzer, binary.span, "constant division by zero", .{}),
                    error.arithmetic_overflow => return constantError(analyzer, binary.span, "constant arithmetic overflows", .{}),
                    error.shift_out_of_range => unreachable,
                };
                return .{ .value = .{ .integer = folded }, .value_type = left.value_type };
            },
            .float => |a| {
                const b = right.value.float;
                // At `float` every operand and every answer is
                // rounded to binary32, because that is what a run
                // would compute; folding at binary64 and narrowing
                // afterwards is a double rounding.
                const folded: f64 = switch (left.value_type) {
                    .f16 => foldFloat(f16, binary.op, @floatCast(a), @floatCast(b)),
                    .f32 => foldFloat(f32, binary.op, @floatCast(a), @floatCast(b)),
                    .f64 => foldFloat(f64, binary.op, a, b),
                    else => unreachable,
                };
                return .{ .value = .{ .float = folded }, .value_type = left.value_type };
            },
            .str => |a| {
                if (binary.op != .add) {
                    return constantError(analyzer, binary.span, "{s} supports + only", .{try analyzer.typeName(left.value_type)});
                }
                const joined = try std.mem.concat(analyzer.arena, u8, &.{ a, right.value.str });
                return .{ .value = .{ .str = joined }, .value_type = left.value_type };
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
                    "{s} is a set of names and has no order; write i64(…) on both sides to compare the numbers behind them",
                    .{try analyzer.typeName(left.value_type)},
                );
            }
            const folded: bool = switch (left.value) {
                .integer => |a| helpers.compareOrder(binary.op, a, right.value.integer),
                .float => |a| helpers.compareOrder(binary.op, a, right.value.float),
                .str => |a| blk: {
                    const order = std.mem.order(u8, a, right.value.str);
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
        .coalesce, .catch_error, .identity => unreachable, // answered above
    }
}
