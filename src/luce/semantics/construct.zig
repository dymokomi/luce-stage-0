//! The call-shaped forms that produce a value rather than run a body:
//! struct and variant construction, the eight conversions, and the
//! free builtins.
//!
//! They share the syntax of a call and none of its machinery — no
//! declaration to resolve, no body to enter, no frame — so what they
//! need is a different thing entirely: the layout's fields against the
//! arguments written for them, the conversion ladders and what each
//! pair of types is allowed to mean, and the one big dispatch that
//! turns a spelled builtin into the intrinsic it lowers to
//! (`builtins.zig` is the table that dispatch reads).
//!
//! A file because it is the other half of the call syntax, and because
//! `lowerIntrinsic` is a table-driven switch that has exactly one
//! reader: the builtin whose row it is on.

const std = @import("std");
const source_mod = @import("../source.zig");
const ast = @import("../parse.zig").ast;
const types = @import("../support/types.zig");
const conversionNamed = types.conversionNamed;
const helpers = @import("helpers.zig");
const nodes = @import("../hir.zig").nodes;
const builtins_mod = @import("builtins.zig");
const builtins = builtins_mod.builtins;
const standard_intrinsics = builtins_mod.standard_intrinsics;
const context = @import("context.zig");
const Error = context.Error;
const Span = source_mod.Span;
const Type = types.Type;

const builder = @import("builder.zig");
const calls = @import("calls.zig");
const expressions = @import("expressions.zig");
const ledger = @import("ledger.zig");
const recorder = @import("recorder.zig");
const refusals = @import("refusals.zig");
const defaults = @import("defaults.zig");
const naming = @import("naming.zig");
const resolve = @import("resolve.zig");
const FunctionBuilder = builder.FunctionBuilder;
const RecordedOperand = recorder.RecordedOperand;
const Typed = builder.Typed;

pub fn lowerConstruct(
    self: *FunctionBuilder,
    call_arguments: []const ast.Argument,
    span: Span,
    layout_index: u32,
) Error!?Typed {
    if (self.analyzer.interfaceForLayout(layout_index) != null) {
        try self.fail(
            "luce.sema.interface",
            span,
            "interfaces cannot be constructed; implement the interface on a struct and pass that struct",
            .{},
        );
        return null;
    }
    const layout = self.analyzer.structs.items[layout_index];
    // A marked struct constructed outside its module is the type
    // refusal; construction is never reached (VISIBILITY.md §8).
    const decl_info = self.analyzer.struct_decls.items[layout_index];
    if (decl_info.declaration.visibility == .private and decl_info.module != self.module) {
        try self.fail("luce.sema.private", span, "{s} is private to {s}", .{
            decl_info.declaration.name,
            naming.moduleName(self.analyzer, decl_info.module),
        });
        return null;
    }
    if (layout.fields.len == 0) {
        // A fieldless class has nothing for memberwise construction to
        // fill; an init is its only door.  A fieldless struct is a
        // function namespace and was never constructible.
        if (layout.reference) {
            try self.fail(
                "luce.sema.construct",
                span,
                "{s} has no fields to construct; give it an init to make instances",
                .{layout.name},
            );
            return null;
        }
        try self.fail(
            "luce.sema.construct",
            span,
            context.namespace_has_no_fields_message,
            .{layout.name},
        );
        return null;
    }
    var seen = try self.temporary().alloc(bool, layout.fields.len);
    defer self.temporary().free(seen);
    @memset(seen, false);

    // Which field each argument fills is settled before any of them
    // is lowered: it is what says what type the argument lands in,
    // and a bare `none` has no type until something says.
    const operand_expressions = try self.arena().alloc(*ast.Expression, call_arguments.len);
    const fields = try self.arena().alloc(u32, call_arguments.len);
    const expected_types = try self.arena().alloc(Type, call_arguments.len);
    for (call_arguments, operand_expressions, fields, expected_types) |argument, *slot, *field, *wanted| {
        const name = argument.name orelse {
            try self.fail("luce.sema.construct", argument.span, "{s} is built with named fields: {s}(field = ...)", .{ layout.name, layout.name });
            return null;
        };
        const field_index = layout.findField(name) orelse {
            try refusals.failUnknownField(self, "luce.sema.construct", layout_index, name, argument.span);
            return null;
        };
        // Naming a private field — even one with a default — is
        // refused: a default is the module's chosen value for a
        // slot the module kept (VISIBILITY.md §3).
        if (!try refusals.fieldReachable(self, layout_index, field_index, argument.span)) return null;
        if (seen[field_index]) {
            try self.fail("luce.sema.construct", argument.span, context.duplicate_field_message, .{name});
            return null;
        }
        seen[field_index] = true;
        slot.* = argument.value;
        field.* = field_index;
        wanted.* = layout.fields[field_index].field_type;
    }
    const run = (try self.lowerOperandsIntoTracking(operand_expressions, .{ .places = expected_types })) orelse return null;
    const values = run.values;
    // The recorded batch: written fields in evaluation order with
    // the field slot each fills, then defaults in materialization
    // order — a call's convention, because named-field
    // construction is the named-argument call shape (D8).
    const entries = try self.arena().alloc(RecordedOperand, layout.fields.len);
    for (call_arguments, values, fields, expected_types, 0..) |argument, value, field_index, expected, index| {
        const name = argument.name.?;
        const fitted = (try self.fit(value, expected)) orelse {
            try self.fail("luce.sema.type", argument.span, "{s}.{s} is {s}, got {s}{s}", .{
                layout.name,
                name,
                try self.analyzer.typeName(expected),
                try self.analyzer.typeName(value.value_type),
                try refusals.mismatchAdvice(self, expected, value.value_type, argument.value),
            });
            return null;
        };
        entries[index] = .{
            .node = fitted.node,
            .slot = field_index,
            .copied = run.copied[index],
        };
        // A struct owns its field run and every value in it, so
        // construction is a store like any other (docs/STRINGS.md).
        ledger.ownedForStore(self, fitted);
    }
    // A field nobody wrote takes its default (docs/ARGS.md D8):
    // the constant register the written value would have produced,
    // and the same store it would have taken — so only the
    // required fields can be missing.
    var next_entry = call_arguments.len;
    for (seen, 0..) |given, field_index| {
        if (given) continue;
        if (!defaults.fieldHasDefault(self.analyzer, layout_index, field_index)) continue;
        const filled = (try defaults.fieldDefault(self.analyzer, layout_index, field_index)) orelse return null;
        const made = try expressions.emitConstantValue(self, filled.value, filled.value_type, span);
        ledger.ownedForStore(self, made);
        entries[next_entry] = .{ .node = made.node, .slot = @intCast(field_index) };
        next_entry += 1;
        seen[field_index] = true;
    }
    // A still-missing field has no default.  Missing and *private*
    // makes the struct not constructible here at all, and the
    // diagnostic names the pattern that is: a public function of
    // the declaring module (VISIBILITY.md §3).
    if (decl_info.module != self.module) {
        for (seen, 0..) |given, field_index| {
            if (given) continue;
            if (field_index >= decl_info.field_visibility.len) continue;
            if (decl_info.field_visibility[field_index] != .private) continue;
            try self.fail(
                "luce.sema.private",
                span,
                "{s} cannot be constructed here: {s} is private in {s} and has no default; construction belongs to a public function of {s}",
                .{
                    decl_info.declaration.name,
                    layout.fields[field_index].name,
                    naming.moduleName(self.analyzer, decl_info.module),
                    naming.moduleName(self.analyzer, decl_info.module),
                },
            );
            return null;
        }
    }
    for (seen) |given| {
        if (given) continue;
        var missing: std.ArrayList(u8) = .empty;
        defer missing.deinit(self.temporary());
        try context.writeMissingFields(&missing, self.temporary(), layout, seen);
        try self.fail("luce.sema.construct", span, context.missing_field_message, .{
            layout.name,
            missing.items,
        });
        return null;
    }
    const result_type = try resolve.nominalType(self.analyzer, layout_index);
    return .{
        // Every field is accounted for by now — written or
        // defaulted — so the batch covers the layout exactly.
        .node = try recorder.recordNode(self, .{ .struct_make = .{
            .layout = layout_index,
            .operands = try recorder.recordOperandBatch(self, entries[0..next_entry], call_arguments.len),
            .result = result_type,
            .span = span,
        } }),
        .value_type = result_type,
    };
}

/// The union member a fully-qualified name spells — `Shape.circle`
/// with the module prefix already on it — or null when the name's
/// head is no union or its tail no member.
pub fn variantMemberOfQualified(
    self: *const FunctionBuilder,
    qualified: []const u8,
) ?struct { variant: u32, member: u32 } {
    const dot = std.mem.lastIndexOfScalar(u8, qualified, '.') orelse return null;
    const variant_index = self.analyzer.variant_names.get(qualified[0..dot]) orelse return null;
    const member = self.analyzer.variants.items[variant_index].findMember(qualified[dot + 1 ..]) orelse
        return null;
    return .{ .variant = variant_index, .member = member };
}

/// A union's own name written where a call belongs: there is no
/// `Shape(n)` and no bare construction — a member is the only way
/// in (docs/UNION.md D1, D4).
pub fn failVariantAsCallee(
    self: *FunctionBuilder,
    written_name: []const u8,
    variant_index: u32,
    span: Span,
) Error!?Typed {
    const declared = self.analyzer.variants.items[variant_index];
    try self.fail(
        "luce.sema.union",
        span,
        "{s} is a union, and a member is the only way in: write {s}.{s}, or another of its members",
        .{ written_name, written_name, declared.members[0].name },
    );
    return null;
}

/// `Shape.circle(radius = 2.0)` — construction of one union
/// member, which is `docs/ARGS.md` D8's named-only struct
/// construction with a namespace in front of it (docs/UNION.md
/// D4): named fields, defaults allowed, S24's verb rule at every
/// object field, and `variant_make` at the end.
pub fn lowerVariantConstruct(
    self: *FunctionBuilder,
    call_arguments: []const ast.Argument,
    span: Span,
    variant_index: u32,
    member_index: u32,
) Error!?Typed {
    const declared = self.analyzer.variants.items[variant_index];
    const member = declared.members[member_index];
    const decl_info = self.analyzer.variant_decls.items[variant_index];
    if (decl_info.declaration.visibility == .private and decl_info.module != self.module) {
        try self.fail("luce.sema.private", span, "{s} is private to {s}", .{
            decl_info.declaration.name,
            naming.moduleName(self.analyzer, decl_info.module),
        });
        return null;
    }
    // Parentheses mean a payload (D4): a bare member is written
    // bare, and empty parentheses would be a payload of nothing.
    if (member.fields.len == 0) {
        try self.fail(
            "luce.sema.construct",
            span,
            "{s}.{s} carries no payload, so it takes no parentheses: write {s}.{s}",
            .{ declared.name, member.name, decl_info.declaration.name, member.name },
        );
        return null;
    }
    var seen = try self.temporary().alloc(bool, member.fields.len);
    defer self.temporary().free(seen);
    @memset(seen, false);

    // Which field each argument fills is settled before any of
    // them is lowered: it is what says what type the argument
    // lands in, and a bare `none` has no type until something says.
    const operand_expressions = try self.arena().alloc(*ast.Expression, call_arguments.len);
    const fields = try self.arena().alloc(u32, call_arguments.len);
    const expected_types = try self.arena().alloc(Type, call_arguments.len);
    for (call_arguments, operand_expressions, fields, expected_types) |argument, *slot, *field, *wanted| {
        const name = argument.name orelse {
            try self.fail(
                "luce.sema.construct",
                argument.span,
                "{s}.{s} is built with named fields: {s}.{s}(field = ...)",
                .{ declared.name, member.name, decl_info.declaration.name, member.name },
            );
            return null;
        };
        const field_index = member.findField(name) orelse {
            var suggestion = helpers.Suggestion.init(name);
            for (member.fields) |payload| suggestion.offer(payload.name);
            if (suggestion.best()) |closest| {
                try self.fail("luce.sema.construct", argument.span, "{s}.{s} has no field {s}; did you mean {s}?", .{
                    declared.name,
                    member.name,
                    name,
                    closest,
                });
                return null;
            }
            try self.fail("luce.sema.construct", argument.span, "{s}.{s} has no field {s}", .{
                declared.name,
                member.name,
                name,
            });
            return null;
        };
        if (seen[field_index]) {
            try self.fail("luce.sema.construct", argument.span, context.duplicate_field_message, .{name});
            return null;
        }
        seen[field_index] = true;
        slot.* = argument.value;
        field.* = field_index;
        wanted.* = member.fields[field_index].field_type;
    }
    const run = (try self.lowerOperandsIntoTracking(operand_expressions, .{ .places = expected_types })) orelse return null;
    const values = run.values;
    // The recorded batch is `lowerConstruct`'s exactly: a union
    // member is built the way a struct is (docs/UNION.md D4).
    const entries = try self.arena().alloc(RecordedOperand, member.fields.len);
    for (call_arguments, values, fields, expected_types, 0..) |argument, value, field_index, expected, index| {
        const name = argument.name.?;
        const fitted = (try self.fit(value, expected)) orelse {
            try self.fail("luce.sema.type", argument.span, "{s}.{s}.{s} is {s}, got {s}{s}", .{
                declared.name,
                member.name,
                name,
                try self.analyzer.typeName(expected),
                try self.analyzer.typeName(value.value_type),
                try refusals.mismatchAdvice(self, expected, value.value_type, argument.value),
            });
            return null;
        };
        entries[index] = .{
            .node = fitted.node,
            .slot = field_index,
            .copied = run.copied[index],
        };
        // A union owns its run and every value in it, so
        // construction is a store like any other (docs/STRINGS.md).
        ledger.ownedForStore(self, fitted);
    }
    // A field nobody wrote takes its default (docs/UNION.md D4):
    // the constant register the written value would have produced.
    var next_entry = call_arguments.len;
    for (seen, 0..) |given, field_index| {
        if (given) continue;
        if (!defaults.variantFieldHasDefault(self.analyzer, variant_index, member_index, field_index)) continue;
        const filled = (try defaults.variantFieldDefault(self.analyzer, variant_index, member_index, field_index)) orelse
            return null;
        const made = try expressions.emitConstantValue(self, filled.value, filled.value_type, span);
        ledger.ownedForStore(self, made);
        entries[next_entry] = .{ .node = made.node, .slot = @intCast(field_index) };
        next_entry += 1;
        seen[field_index] = true;
    }
    for (seen) |given| {
        if (given) continue;
        var missing: std.ArrayList(u8) = .empty;
        defer missing.deinit(self.temporary());
        try context.writeMissingFields(
            &missing,
            self.temporary(),
            .{ .name = member.name, .fields = member.fields },
            seen,
        );
        const spelled = try std.fmt.allocPrint(self.arena(), "{s}.{s}", .{ declared.name, member.name });
        try self.fail("luce.sema.construct", span, context.missing_field_message, .{
            spelled,
            missing.items,
        });
        return null;
    }
    const result_type: Type = .{ .variant = variant_index };
    return .{
        .node = try recorder.recordNode(self, .{ .variant_make = .{
            .variant = variant_index,
            .member = member_index,
            .operands = try recorder.recordOperandBatch(self, entries[0..next_entry], call_arguments.len),
            .result = result_type,
            .span = span,
        } }),
        .value_type = result_type,
    };
}

/// `i32(x)`, `i64(x)`, `f32(x)`, `f64(x)`, `str(x)` — the
/// conversion constructors, each named for the type it produces
/// (docs/TYPES.md §3).  They are matched by name here, before
/// name resolution, which is why they are not in the builtin
/// table and why `str` is a reserved name.
///
/// `str(x)` takes scalar values, enums, and function values.  A
/// `builder` is a heap object and its text comes out through
/// `b.build()`, which is the method it should always have had.
/// `Method(n)` — the number→enum direction, which answers
/// `Method?` (docs/ENUMS.md R2).
///
/// **It is the parse case, not the arithmetic case.**  The number
/// arrives from a file, a wire or a spec field, and *unknown
/// member* is precisely what the caller has to branch on — so this
/// answers absence rather than trapping, and the caller writes
/// `else` or narrows, like every other absence.
///
/// The lowering is the same compare-and-branch tree `match` is: one
/// equality per member against the number at its checked input type, each
/// answering the member it matched, and absence where none did.
/// Nothing is narrowed and nothing traps, which is what lets a
/// `u8`-backed enum be asked about a number no `u8` could hold.
pub fn lowerEnumOfNumber(
    self: *FunctionBuilder,
    written_name: []const u8,
    arguments: []const ast.Argument,
    span: Span,
    enum_index: u32,
) Error!?Typed {
    const info = self.analyzer.enum_decls.items[enum_index];
    if (info.declaration.visibility == .private and info.module != self.module) {
        try self.fail("luce.sema.private", span, "{s} is private to {s}", .{
            info.declaration.name,
            naming.moduleName(self.analyzer, info.module),
        });
        return null;
    }
    if (arguments.len != 1 or !helpers.argumentMayName(arguments[0], "value")) {
        try self.fail("luce.sema.convert", span, "{s}(value) takes one number", .{written_name});
        return null;
    }
    const declared = self.analyzer.enums.items[enum_index];
    const of = self.analyzer.enumType(enum_index);
    const answer = Type.optionalOf(of).?;

    // A literal lands directly on the enum's declared representation.
    const backing = declared.backing.asType();
    self.wanted = backing;
    const number = (try self.lowerExpression(arguments[0].value, false)) orelse return null;
    if (!number.value_type.isInteger()) {
        try self.fail(
            "luce.sema.convert",
            span,
            "{s}(value) reads a whole number and answers {s}?; {s} is not one{s}",
            .{
                written_name,
                declared.name,
                try self.analyzer.typeName(number.value_type),
                try refusals.absenceAdvice(self, number.value_type, arguments[0].value),
            },
        );
        return null;
    }
    if (!number.value_type.eql(backing)) {
        try self.fail(
            "luce.sema.convert",
            span,
            "{s}(value) takes {s}; convert the value explicitly",
            .{ written_name, try self.analyzer.typeName(backing) },
        );
        return null;
    }
    // The compare-and-branch tree — the held slot, the absence
    // default, one arm per member — is lower's, from the enum
    // table; the two hidden slots are recorded here in creation
    // order (the number, then the result).
    _ = try recorder.recordLocal(self, null, backing, false, span);
    _ = try recorder.recordLocal(self, null, answer, false, span);
    return .{
        // `Method(n)` is the other half of the `.enum_name` pair
        // (nodes.ResolvedCallee): same chain, same reload, told
        // apart by the result type. The operand already has the enum's
        // exact backing type.
        .node = try recorder.recordCallNode(
            self,
            .{ .enum_name = enum_index },
            &.{.{ .node = number.node, .slot = 0 }},
            1,
            false,
            answer,
            span,
        ),
        .value_type = answer,
    };
}

pub fn lowerConvert(self: *FunctionBuilder, call: ast.Call) Error!?Typed {
    return lowerConvertAs(self, call, conversionNamed(call.callee).?);
}

/// `foreign(value)` — the one explicit escape from a named handle to
/// the untyped token (docs/FFI.md): pointer-shaped only, never
/// implicit, and never backwards.  `foreign` is not in the conversion
/// table on purpose — it converts exactly one thing, and every other
/// operand earns a sentence about what the escape is for.
pub fn lowerForeignConvert(self: *FunctionBuilder, call: ast.Call) Error!?Typed {
    if (call.arguments.len != 1 or !helpers.argumentMayName(call.arguments[0], "value")) {
        try self.fail("luce.sema.convert", call.span, "foreign(value) takes one argument", .{});
        return null;
    }
    self.wanted = null;
    const value = (try self.lowerExpression(call.arguments[0].value, false)) orelse return null;
    // The identity, by the numeric constructors' precedent: a
    // redundant escape is not a mistake to report.
    if (value.value_type == .foreign) return value;
    if (value.value_type != .extern_type) {
        try self.fail(
            "luce.sema.convert",
            call.span,
            "foreign(value) converts a pointer-shaped handle to the untyped token; {s} is not a handle (docs/FFI.md)",
            .{try self.analyzer.typeName(value.value_type)},
        );
        return null;
    }
    if (value.value_type.extern_type.representation != .foreign) {
        try self.fail(
            "luce.sema.convert",
            call.span,
            "{s} is an integer-shaped handle: its value is an integer, not a token, and foreign() has nothing to strip (docs/FFI.md)",
            .{try self.analyzer.typeName(value.value_type)},
        );
        return null;
    }
    return .{
        .node = try recorder.recordCallNode(
            self,
            .{ .conversion = .foreign },
            &.{.{ .node = value.node, .slot = 0 }},
            1,
            false,
            .foreign,
            call.span,
        ),
        .value_type = .foreign,
    };
}

/// A scalar alias used in constructor position.  The written alias stays in
/// diagnostics, while conversion semantics are selected by the resolved
/// target.  This is the expression-side half of alias transparency:
/// `alias Id = i64; Id(value)` behaves exactly like `i64(value)`.
pub fn lowerAliasConvert(self: *FunctionBuilder, call: ast.Call, target: Type) Error!?Typed {
    const produces: types.Builtin = switch (target) {
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
        else => unreachable, // the alias-call dispatcher admits only these
    };
    return lowerConvertAs(self, call, produces);
}

fn lowerConvertAs(self: *FunctionBuilder, call: ast.Call, produces: types.Builtin) Error!?Typed {
    // One slot, named `value` like the reference spells it
    // (docs/ARGS.md D1: names are optional everywhere, so the
    // constructors take theirs too).
    if (call.arguments.len != 1 or !helpers.argumentMayName(call.arguments[0], "value")) {
        try self.fail("luce.sema.convert", call.span, "{s}(value) takes one argument", .{call.callee});
        return null;
    }
    // **A constructor is a written-down type, so its literal argument
    // lands on it.** `f64(0.1)` reads the literal directly as binary64,
    // and `i64(3000000000)` is checked as i64. A literal has no type
    // until it meets one (docs/TYPES.md §1), and here it meets the
    // constructor's.
    self.wanted = switch (produces) {
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
        .char => .u32,
        .boolean, .str, .bytes, .foreign, .list, .map, .array, .builder, .handle, .task, .channel => null,
    };
    const value = (try self.lowerExpression(call.arguments[0].value, false)) orelse return null;
    // **A conversion accepts an enum exactly because it is named
    // for what it produces** (docs/ENUMS.md D4): `i32(m)` is the
    // member's number, and `str(m)` is the member's *name* —
    // which is a different act from printing a number, and the one
    // an f-string hole performs for a reader who wrote none.
    if (value.value_type == .enumeration) {
        if (produces == .str) return lowerEnumName(self, value, call.span);
        if (produces == .char or produces == .bytes) return failConvert(self, call, value, produces);
        return lowerEnumToNumber(self, call, value, produces);
    }
    // `str(u)` is the member's **name**, by the enum mechanism
    // unchanged (docs/UNION.md D16) — and the payload is never
    // formatted: that is a formatting protocol, which is a
    // different feature, refused here by being absent.
    if (value.value_type == .variant) {
        if (produces == .str) return lowerVariantName(self, value, call.span);
        return failConvert(self, call, value, produces);
    }
    // `str(f)` is the function's **name** (docs/FUNCTIONS.md
    // D3) — the enum arm above, one type later, and the same act:
    // a value that is a number underneath answers with the word it
    // stands for.  Recorded as the `function_name` intrinsic it
    // resolved to, not as a `.conversion`: the name is a
    // borrowless constant of the program, where conversion to
    // string means fresh bytes (the section comment above).
    if (value.value_type == .function and produces == .str) {
        return .{
            .node = try recorder.recordCallNode(
                self,
                .{ .intrinsic = .function_name },
                &.{.{ .node = value.node, .slot = 0 }},
                1,
                false,
                .str,
                call.span,
            ),
            .value_type = .str,
        };
    }
    if (produces == .char) {
        if (value.value_type == .char) return value;
        if (!value.value_type.isInteger()) return failConvert(self, call, value, produces);
        return .{
            .node = try recorder.recordCallNode(
                self,
                .{ .conversion = .char },
                &.{.{ .node = value.node, .slot = 0 }},
                1,
                false,
                .char,
                call.span,
            ),
            .value_type = .char,
        };
    }
    if (produces == .bytes) {
        if (value.value_type == .bytes) return value;
        const byte_sequence = if (self.analyzer.heapOf(value.value_type)) |descriptor| switch (descriptor) {
            .list => |element| element == .u8,
            .array => |shape| shape.rank == 1 and shape.element == .u8,
            .class, .map, .builder, .handle, .task, .channel => false,
        } else false;
        if (value.value_type != .str and !byte_sequence) {
            return failConvert(self, call, value, produces);
        }
        const answer: Typed = .{
            .node = try recorder.recordCallNode(
                self,
                .{ .conversion = .bytes },
                &.{.{ .node = value.node, .slot = 0 }},
                1,
                false,
                .bytes,
                call.span,
            ),
            .value_type = .bytes,
        };
        try ledger.parkFreshStorage(self, answer, call.span);
        return answer;
    }
    if (produces == .str) {
        switch (value.value_type) {
            // The identity: `str(s)` emits nothing and answers
            // the operand whole, node included — no call node, so
            // `nodes.provenance` never claims fresh bytes an
            // identity does not make (the section comment above).
            .str => return value,
            .u8, .u16, .u32, .u64, .i8, .i16, .i32, .i64, .f16, .f32, .f64, .char, .boolean => {},
            .heap => {
                const descriptor = self.analyzer.heapOf(value.value_type).?;
                if (descriptor == .builder) {
                    try self.fail(
                        "luce.sema.convert",
                        call.span,
                        "str() converts a number, a bool, a str, an enum, a union member, or a function value; a builder hands over its text with .build()",
                        .{},
                    );
                    return null;
                }
                return failConvert(self, call, value, produces);
            },
            else => return failConvert(self, call, value, produces),
        }
        // Fresh bytes nothing parked: the statement's end reclaims
        // them unless a place adopts them (docs/STRINGS.md).
        const answer: Typed = .{
            .node = try recorder.recordCallNode(
                self,
                .{ .conversion = .str },
                &.{.{ .node = value.node, .slot = 0 }},
                1,
                false,
                .str,
                call.span,
            ),
            .value_type = .str,
        };
        try ledger.parkFreshStorage(self, answer, call.span);
        return answer;
    }
    // Every other constructor is named for a numeric type and
    // produces it, from any number: one rule, and it needs no arm
    // per pair (docs/TYPES.md §3).  `i64(x)` where `x` is already
    // an `i64` is the identity — constructors explicitly change numeric
    // representation, so a redundant one
    // is not a mistake to report.
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
        .boolean, .char, .str, .bytes, .foreign, .list, .map, .array, .builder, .handle, .task, .channel => unreachable, // answered above
    };
    // The identity again: nothing emitted, the operand's value and
    // node pass through whole (the section comment above).
    if (value.value_type.eql(target)) return value;
    if (value.value_type == .char) {
        if (target != .u32) return failConvert(self, call, value, produces);
    } else if (!value.value_type.isNumeric()) {
        return failConvert(self, call, value, produces);
    }
    return .{
        .node = try recorder.recordCallNode(
            self,
            .{ .conversion = target },
            &.{.{ .node = value.node, .slot = 0 }},
            1,
            false,
            target,
            call.span,
        ),
        .value_type = target,
    };
}

/// `i32(m)`, `i64(m)`, `u8(m)` — the member's number, at the
/// width the constructor names (docs/ENUMS.md D4).
///
/// **Every numeric constructor takes an enum, and each behaves
/// exactly as if the backing width had been written.**  `u8(m)`
/// traps `conversion_range` where `u8(300)` would; `f64(m)`
/// answers the member's number as an f64. One rule, no table of pairs—the
/// same shape `lowerConvert` gives every numeric type (docs/TYPES.md §3).
fn lowerEnumToNumber(
    self: *FunctionBuilder,
    call: ast.Call,
    value: Typed,
    produces: types.Builtin,
) Error!?Typed {
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
        .boolean, .char, .str, .bytes, .foreign, .list, .map, .array, .builder, .handle, .task, .channel => unreachable, // answered by the caller
    };
    return .{
        // The same node shape as the numeric constructors: one
        // `.conversion` call whose operand happens to be an enum.
        .node = try recorder.recordCallNode(
            self,
            .{ .conversion = target },
            &.{.{ .node = value.node, .slot = 0 }},
            1,
            false,
            target,
            call.span,
        ),
        .value_type = target,
    };
}

/// `str(m)` — the member's name (docs/ENUMS.md D5).
///
/// **The name table is the constant pool.**  Every member's name is
/// interned there once, like every other string a program spells,
/// and this is the tree that picks the row: one equality per member
/// on a value that is already the compare-and-branch shape `match`
/// uses, answering a constant.  So there is nothing new in
/// `libluce_rt` — the two engines agree because they run the same
/// MIR, which is the whole of D10's promise — and no table of
/// pointers has to be emitted into an artifact and kept honest by
/// something other than the program itself.
fn lowerEnumName(self: *FunctionBuilder, value: Typed, span: Span) Error!?Typed {
    // The chain answers a reload of its result slot; the node is
    // the `.enum_name` call around the written operand, and the
    // comparisons are lower's to spell from the enum table.
    const node = try recorder.recordCallNode(
        self,
        .{ .enum_name = value.value_type.enumeration.index },
        &.{.{ .node = value.node, .slot = 0 }},
        1,
        false,
        .str,
        span,
    );
    const declared = self.analyzer.enums.items[value.value_type.enumeration.index];
    // The names are interned now, in member order, so the pool's
    // rows do not depend on when lower runs (coupling #6); the
    // compare-and-branch tree over them is lower's.  The result
    // slot's row, then the held scrutinee's, in creation order.
    for (declared.members) |member| _ = try self.analyzer.pool.intern(member.name);
    _ = try recorder.recordLocal(self, null, .str, false, span);
    if (declared.members.len == 1) {
        return .{ .node = node, .value_type = .str };
    }
    _ = try recorder.recordLocal(self, null, value.value_type, false, span);
    return .{ .node = node, .value_type = .str };
}

/// `str(u)` — the member's name (docs/UNION.md D16), by
/// `lowerEnumName`'s mechanism unchanged: a compare-and-branch
/// tree over the tag answering an interned constant, nothing new
/// in `libluce_rt`.  The tag is the member *index* (D8), so the
/// tree compares indices where the enum tree compares values.
fn lowerVariantName(self: *FunctionBuilder, value: Typed, span: Span) Error!?Typed {
    // As `lowerEnumName`, one table over: the `.variant_name`
    // callee row exists because the two indices name different
    // tables and one number must not wear both hats.
    const node = try recorder.recordCallNode(
        self,
        .{ .variant_name = value.value_type.variant },
        &.{.{ .node = value.node, .slot = 0 }},
        1,
        false,
        .str,
        span,
    );
    const declared = self.analyzer.variants.items[value.value_type.variant];
    // As `lowerEnumName`: intern the names now, record the result
    // slot's row and then the held scrutinee's, and leave the
    // compare-and-branch tree over the tag to lower.
    for (declared.members) |member| _ = try self.analyzer.pool.intern(member.name);
    _ = try recorder.recordLocal(self, null, .str, false, span);
    if (declared.members.len == 1) {
        return .{ .node = node, .value_type = .str };
    }
    _ = try recorder.recordLocal(self, null, value.value_type, false, span);
    return .{ .node = node, .value_type = .str };
}

/// One sentence for every numeric constructor, naming what each takes.
fn failConvert(
    self: *FunctionBuilder,
    call: ast.Call,
    value: Typed,
    produces: types.Builtin,
) Error!?Typed {
    // Name the numeric family rather than duplicating its width roster
    // in a diagnostic that would otherwise drift as the type set changes.
    const takes: []const u8 = if (produces == .str)
        "a number, a bool, a str, an enum, a union member, or a function value"
    else
        "a number";
    try self.fail("luce.sema.convert", call.span, "{s}() converts {s}, not {s}{s}", .{
        call.callee,
        takes,
        try self.analyzer.typeName(value.value_type),
        try refusals.absenceAdvice(self, value.value_type, call.arguments[0].value),
    });
    return null;
}

// Builtins ---------------------------------------------------------------

const IntrinsicResult = union(enum) {
    not_builtin,
    failed,
    value: Typed,
};

pub const IntrinsicSurface = enum {
    prelude,
    standard,
};

/// Lower a builtin call; .not_builtin when the callee is no
/// builtin, .failed after reporting bad arguments.
pub fn lowerIntrinsic(
    self: *FunctionBuilder,
    call: ast.Call,
    as_statement: bool,
    fallible_allowed: bool,
    wanted: ?Type,
    intrinsic_surface: IntrinsicSurface,
) Error!IntrinsicResult {
    const candidates: []const builtins_mod.Builtin = switch (intrinsic_surface) {
        .prelude => &builtins,
        .standard => &standard_intrinsics,
    };
    const matched = for (candidates) |builtin| {
        if (std.mem.eql(u8, call.callee, builtin.name)) break builtin;
    } else return .not_builtin;

    if (matched.host and !self.analyzer.options.allow_host) {
        if (intrinsic_surface == .standard) {
            try self.fail(
                "luce.sema.host",
                call.span,
                "this standard-library operation requires host access; this host does not allow console, file, or terminal access here",
                .{},
            );
            return .failed;
        }
        try self.fail(
            "luce.sema.host",
            call.span,
            "{s} is a host builtin; this host does not allow console, file, or terminal access here",
            .{matched.name},
        );
        return .failed;
    }
    // Which slot each argument fills: the table is the builtin's
    // signature (docs/ARGS.md §3), so names and defaults resolve
    // through the same machinery a user call's do — the resolver
    // needs nothing but the slots.
    const surface = try calls.builtinSlots(self, matched);
    const seen = try self.temporary().alloc(bool, surface.len);
    defer self.temporary().free(seen);
    @memset(seen, false);
    const slots = (try calls.resolveSlots(self, matched.name, "luce.sema.call", surface, 0, call.arguments, seen, call.span)) orelse
        return .failed;
    if (!(try calls.checkRequiredSlots(self, matched.name, "luce.sema.call", surface, seen, call.span))) return .failed;
    const argument_expressions = try self.arena().alloc(*ast.Expression, call.arguments.len);
    for (call.arguments, 0..) |argument, index| argument_expressions[index] = argument.value;
    const operand_expressions = argument_expressions[0..call.arguments.len];
    // **The builtins that answer their operand's own type land
    // their operands where the whole call lands** (docs/TYPES.md
    // §9). `let x: f64 = sqrt(2.0)` therefore reads `2.0` and computes
    // directly at f64. Every other
    // builtin names its own operand types and takes no landing;
    // the polymorphic landing is one type for every slot, so a
    // reordered name cannot land a literal differently.
    const run = written: {
        const landing = if (matched.polymorphic) context.literalLandingType(wanted orelse .none) else null;
        if (landing) |place| {
            const places = try self.arena().alloc(Type, operand_expressions.len);
            @memset(places, place);
            break :written (try self.lowerOperandsIntoTracking(operand_expressions, .{ .places = places })) orelse
                return .failed;
        }
        break :written (try self.lowerOperandsIntoTracking(operand_expressions, .nothing)) orelse return .failed;
    };
    const written = run.values;
    // Written values land on the slots they resolved to, and a
    // slot nobody filled takes its default from the table — the
    // constant register the written literal would have been
    // (docs/ARGS.md D2, D10). A default's node carries its exact type.
    const arguments = try self.arena().alloc(Typed, surface.len);
    for (written, slots) |value, slot| arguments[slot] = value;
    for (matched.parameters, seen, 0..) |parameter, given, slot| {
        if (given) continue;
        const filled = parameter.default.?;
        arguments[slot] = try expressions.emitConstantValue(self, filled.value, filled.value_type, call.span);
    }

    // Argument and result typing per builtin.
    var result: Type = .none;
    switch (matched.kind) {
        // Channel operations are receiver methods and construction,
        // never `Builtin.` calls: no builtin row names them, so this
        // dispatch cannot be asked.
        .channel_new,
        .channel_send,
        .channel_try_send,
        .channel_receive,
        .channel_try_receive,
        .channel_receive_timeout,
        .channel_receive_by,
        .channel_close,
        .channel_len,
        .channel_cap,
        => unreachable,
        // The address of a list[u8]'s storage, as the opaque token
        // (docs/FFI.md).  std-only through the `Builtin.` spelling;
        // `std.c.with_bytes` is the public door.
        .buffer_address => {
            const takes_buffer = blk: {
                if (arguments[0].value_type != .heap) break :blk false;
                const shape = self.analyzer.heap_types.items[arguments[0].value_type.heap];
                // A dense array's storage may reach C too — the BLAS
                // door (docs/FFI.md).  Scalar elements only: what C
                // sees must be the elements and nothing else.
                break :blk switch (shape) {
                    .list => shape.list == .u8,
                    .array => shape.array.element.isNumeric() or shape.array.element == .u8,
                    else => false,
                };
            };
            if (!takes_buffer) return failIntrinsic(self, call, "buffer_address takes a list[u8] or a numeric array");
            result = .foreign;
        },
        // The C reads (docs/FFI.md): copies out of foreign memory,
        // never borrows.  std-only through the `Builtin.` spelling;
        // `std.c.bytes_at` and `std.c.cstring_at` are the public
        // doors.  The null token traps `null_foreign` at run time;
        // `cstring_at` additionally validates and traps `invalid_utf8`.
        .bytes_at => {
            if (arguments[0].value_type != .foreign)
                return failIntrinsic(self, call, "bytes_at takes (foreign, u64)");
            if (arguments[1].value_type != .u64)
                return failIntrinsic(self, call, "bytes_at takes (foreign, u64)");
            result = .bytes;
        },
        .cstring_at => {
            if (arguments[0].value_type != .foreign)
                return failIntrinsic(self, call, "cstring_at takes a foreign");
            result = .str;
        },
        .abs => {
            if (!arguments[0].value_type.isNumeric()) return failIntrinsic(self, call, "abs takes a number");
            result = arguments[0].value_type;
        },
        // `min`, `max` and `clamp` require one concrete numeric type. A
        // literal can land on a typed argument; two already-typed values do
        // not convert or unify implicitly.
        .min, .max => {
            if (!arguments[0].value_type.isNumeric() or
                !arguments[0].value_type.eql(arguments[1].value_type))
                return failIntrinsic(self, call, "min/max take two numbers of the same type");
            result = arguments[0].value_type;
        },
        .clamp => {
            if (!arguments[0].value_type.isNumeric() or
                !arguments[0].value_type.eql(arguments[1].value_type) or
                !arguments[0].value_type.eql(arguments[2].value_type))
                return failIntrinsic(self, call, "clamp takes three numbers of the same type");
            result = arguments[0].value_type;
        },
        .sqrt, .floor, .ceil, .trunc => {
            // Whichever floating width it was given, and the same one back.
            if (!arguments[0].value_type.isFloating())
                return failIntrinsic(self, call, "this builtin takes f16, f32, or f64");
            result = arguments[0].value_type;
        },
        .len => {
            // **A `file` and a `task` are `.heap` and are not
            // containers.**  The gate used to admit every heap type
            // while the sentence under it listed five, and the two the
            // sentence left out are exactly the two with no length:
            // `len(spawn work())` type-checked, verified, and reached a
            // runtime switch whose file/task arm is `unreachable`.  The
            // gate now asks the descriptor, so the predicate and the
            // sentence say the same thing.
            const measurable = arguments[0].value_type == .str or
                arguments[0].value_type == .bytes or measure: {
                const descriptor = self.analyzer.heapOf(arguments[0].value_type) orelse break :measure false;
                break :measure switch (descriptor) {
                    .list, .map, .array, .builder => true,
                    .class, .handle, .task, .channel => false,
                };
            };
            if (!measurable) {
                if (arguments[0].value_type == .optional) {
                    try refusals.failAbsence(self, call.span, "len", arguments[0].value_type, call.arguments[0].value);
                    return .failed;
                }
                if (arguments[0].value_type == .heap) {
                    try self.fail(
                        "luce.sema.type",
                        call.span,
                        "len takes str, bytes, list, map, array, or builder; {s} is a resource, not a container, and has no length",
                        .{try self.analyzer.typeName(arguments[0].value_type)},
                    );
                    return .failed;
                }
                return failIntrinsic(self, call, "len takes str, bytes, list, map, array, or builder");
            }
            result = .i64;
        },
        .parse_i64, .parse_f64 => {
            if (arguments[0].value_type != .str)
                return failIntrinsic(self, call, "this builtin parses a str");
            // "Not a number" is the same reason every time and the
            // name already implies it, so the answer is absence
            // rather than a trap (docs/FAILURE.md).
            result = if (matched.kind == .parse_i64)
                .{ .optional = .i64 }
            else
                .{ .optional = .f64 };
        },
        // The parse family's third member (docs/BYTES.md R3): the
        // bytes back as text, or absent when they are not text.
        .parse_str => {
            if (arguments[0].value_type != .bytes)
                return failIntrinsic(self, call, "parse_str takes bytes");
            result = .{ .optional = .str };
        },
        // Lowered from syntax or method calls, never from bare names.
        .own_storage,
        .drop_storage,
        .export_storage,
        // Inserted by the MIR builder around stores and scope ends; no
        // name reaches this builtin-typing table.
        .retain,
        .release,
        .copy_object,
        .null_object,
        // Emitted by a mixed comparison; there is no name for it.
        // Emitted by `str(x)` and by `builder.build()`, both of
        // which are resolved before this table is consulted.
        .str_value,
        .bytes_value,
        // The same, one type later: `str(f)` on a function value
        // (docs/FUNCTIONS.md D3).
        .function_name,
        .none_value,
        .is_none,
        .optional_wrap,
        .optional_unwrap,
        .index_get,
        .index_set,
        .list_slice,
        .key_at,
        .value_at,
        .string_slice,
        .string_byte,
        .string_find_byte,
        .append_value,
        .extend_list,
        .append_ascii,
        .pop_value,
        .insert_value,
        .remove_entry,
        .has_key,
        .dim_size,
        .list_sort,
        .list_reverse,
        .list_find,
        .list_contains,
        .clear_object,
        .map_keys,
        .map_values,
        .map_get,
        .map_place,
        .array_fill,
        => unreachable,

        .assert_true => {
            if (arguments[0].value_type != .boolean)
                return failIntrinsic(self, call, "assert takes a bool");
            result = .none;
        },
        .trap_message => {
            if (arguments[0].value_type != .str)
                return failIntrinsic(self, call, "trap takes a str message");
            result = .none;
        },
        .raise_error => {
            // The raised value is what this function declared it
            // fails with (docs/ERRORS.md R2): the bare `!`'s str, or
            // the declared union — checked here, where it is written.
            if (!arguments[0].value_type.eql(self.error_type)) {
                try self.fail(
                    "luce.sema.fallible",
                    call.span,
                    "{s} fails with {s}, and this error is {s}",
                    .{ self.name, try self.analyzer.typeName(self.error_type), try self.analyzer.typeName(arguments[0].value_type) },
                );
                return .failed;
            }
            result = .none;
        },
        // Emitted by `try` and `catch`; never written by a reader.
        .errored, .error_message, .error_value, .forget => unreachable,
        .print, .term_write, .term_copy => {
            if (arguments[0].value_type != .str)
                return failIntrinsic(self, call, "this builtin takes a str");
            result = .none;
        },
        .shell_run => {
            if (arguments[0].value_type != .str or arguments[1].value_type != .str)
                return failIntrinsic(self, call, "shell_run takes (command str, input str)");
            result = .str;
        },
        .os_standard_stream => {
            if (!arguments[0].value_type.eql(.i64))
                return failIntrinsic(self, call, "os_standard_stream takes a stream number");
            result = try resolve.internHeapType(self.analyzer, .handle);
        },
        .process_spawn => {
            if (arguments[0].value_type != .str)
                return failIntrinsic(self, call, "process_spawn takes a str command");
            result = try resolve.internHeapType(self.analyzer, .handle);
        },
        .process_ready => {
            const handle_type = try resolve.internHeapType(self.analyzer, .handle);
            if (!arguments[0].value_type.eql(handle_type))
                return failIntrinsic(self, call, "process_ready takes a process handle");
            result = .boolean;
        },
        .process_wait => {
            const handle_type = try resolve.internHeapType(self.analyzer, .handle);
            if (!arguments[0].value_type.eql(handle_type))
                return failIntrinsic(self, call, "process_wait takes a process handle");
            result = .i64;
        },
        .process_finish_input => {
            const handle_type = try resolve.internHeapType(self.analyzer, .handle);
            if (!arguments[0].value_type.eql(handle_type))
                return failIntrinsic(self, call, "process_finish_input takes a process handle");
            result = .none;
        },
        .file_read => {
            if (arguments[0].value_type != .str)
                return failIntrinsic(self, call, "file_read takes a str path");
            result = .str;
        },
        .file_write => {
            if (arguments[0].value_type != .str or arguments[1].value_type != .str)
                return failIntrinsic(self, call, "file_write takes (path str, content str)");
            // The world decided, so a failed write is news and not
            // a bool nobody looked at (docs/FAILURE.md).  It
            // answers nothing and every call site says which of
            // `try` and `catch` it means.
            result = .none;
        },
        // What is at a path, as a number the library names: 0
        // nothing, 1 file, 2 directory, 3 other.  Fallible, because
        // "the world would not say" is a different answer from
        // "nothing is there" and only one of them fits in the value
        // (docs/FILESYSTEM.md D11).
        .path_kind => {
            if (arguments[0].value_type != .str)
                return failIntrinsic(self, call, "path_kind takes a str path");
            result = .i64;
        },
        .gpu_backend => {
            result = .i64;
        },
        .ui_window_open => {
            if (arguments[0].value_type != .str or
                !arguments[1].value_type.eql(.i64) or
                !arguments[2].value_type.eql(.i64))
                return failIntrinsic(self, call, "ui_window_open takes (title str, width i64, height i64)");
            result = try resolve.internHeapType(self.analyzer, .handle);
        },
        .ui_window_surface => {
            const file_type = try resolve.internHeapType(self.analyzer, .handle);
            if (!arguments[0].value_type.eql(file_type))
                return failIntrinsic(self, call, "ui_window_surface takes a ui window handle");
            result = file_type;
        },
        .gpu_surface_size => {
            const file_type = try resolve.internHeapType(self.analyzer, .handle);
            if (!arguments[0].value_type.eql(file_type) or
                !arguments[1].value_type.eql(.i64))
                return failIntrinsic(self, call, "gpu_surface_size takes (surface handle, axis i64)");
            result = .i64;
        },
        .gpu_surface_clear => {
            const file_type = try resolve.internHeapType(self.analyzer, .handle);
            if (!arguments[0].value_type.eql(file_type) or
                !arguments[1].value_type.eql(.i64) or
                !arguments[2].value_type.eql(.i64) or
                !arguments[3].value_type.eql(.i64) or
                !arguments[4].value_type.eql(.i64))
                return failIntrinsic(self, call, "gpu_surface_clear takes (surface handle, red i64, green i64, blue i64, alpha i64)");
            result = .none;
        },
        .gpu_surface_fill_rect => {
            const file_type = try resolve.internHeapType(self.analyzer, .handle);
            if (!arguments[0].value_type.eql(file_type))
                return failIntrinsic(self, call, "gpu_surface_fill_rect takes a surface first");
            inline for (1..9) |index| {
                if (!arguments[index].value_type.eql(.i64))
                    return failIntrinsic(self, call, "gpu_surface_fill_rect takes i64 coordinates, dimensions, and colors");
            }
            result = .none;
        },
        .gpu_surface_present => {
            const file_type = try resolve.internHeapType(self.analyzer, .handle);
            if (!arguments[0].value_type.eql(file_type))
                return failIntrinsic(self, call, "gpu_surface_present takes a surface");
            result = .none;
        },
        .term_rows, .term_cols => {
            result = .i64;
        },
        .term_event_data => {
            if (!arguments[0].value_type.eql(.i64))
                return failIntrinsic(self, call, "term_event_data takes an i64 field");
            result = .i64;
        },
        .term_clear, .term_flush => {
            result = .none;
        },
        .term_move => {
            if (!arguments[0].value_type.eql(.i64) or
                !arguments[1].value_type.eql(.i64))
                return failIntrinsic(self, call, "term_move takes (row i64, column i64)");
            result = .none;
        },
        .term_style => {
            if (!arguments[0].value_type.eql(.i64) or
                !arguments[1].value_type.eql(.i64) or
                arguments[2].value_type != .boolean)
                return failIntrinsic(self, call, "term_style takes (foreground i64, background i64, bold bool)");
            result = .none;
        },
        .key_read => {
            // A keyboard runs dry — a pipe ends, a terminal
            // closes — and there is nothing there and no reason
            // worth carrying, which is `str?` and not a name
            // in the closed set (docs/FAILURE.md).  The same fact
            // `read_line` already answers `none` for, off the same
            // descriptor.
            if (!arguments[0].value_type.eql(.i64))
                return failIntrinsic(self, call, "key_read takes a timeout in milliseconds");
            result = .{ .optional = .str };
        },
        .key_text => {
            result = .str;
        },
        .read_line => {
            if (arguments[0].value_type != .str)
                return failIntrinsic(self, call, "read_line takes a str prompt");
            // End of input is absence, not failure: `str?`, and
            // `read_line("> ") else ""` is the whole handling
            // (docs/FAILURE.md).
            result = .{ .optional = .str };
        },
        .print_error => {
            if (arguments[0].value_type != .str)
                return failIntrinsic(self, call, "print_error takes a str");
            result = .none;
        },
        // Two clocks, and the name is what tells them apart: `clock_ms`
        // is monotonic and only its differences mean anything, while
        // `epoch_ms` counts from a fixed origin and its reading is the
        // answer (docs/LANGUAGE.md).
        .clock_ms, .epoch_ms => {
            result = .i64;
        },
        // Bytes, bytes and a count.  `i64` and not `i32` for the
        // same reason `clock_ms` is: a machine with more than two
        // gigabytes of memory overflows the narrow ladder, and a
        // fact nobody can hold is not a fact (docs/TYPES.md).
        .os_total_memory, .os_available_memory, .os_cpu_count => {
            result = .i64;
        },
        .sleep_ms => {
            if (!arguments[0].value_type.eql(.i64))
                return failIntrinsic(self, call, "sleep_ms takes an i64 of milliseconds");
            result = .none;
        },
        .exit_program => {
            if (!arguments[0].value_type.eql(.i64))
                return failIntrinsic(self, call, "exit takes an i64 status");
            result = .none;
        },
        .env_get => {
            if (arguments[0].value_type != .str)
                return failIntrinsic(self, call, "env takes a str name");
            result = .{ .optional = .str };
        },
        .file_append => {
            if (arguments[0].value_type != .str or arguments[1].value_type != .str)
                return failIntrinsic(self, call, "file_append takes (path str, content str)");
            result = .none;
        },
        .file_delete => {
            if (arguments[0].value_type != .str)
                return failIntrinsic(self, call, "file_delete takes a str path");
            result = .none;
        },
        // Making a directory answers nothing for the reason a write
        // does: the world decided, so what it said travels in the
        // error channel and every call site says which of `try` and
        // `catch` it means (docs/FAILURE.md).
        .dir_create => {
            if (arguments[0].value_type != .str)
                return failIntrinsic(self, call, "dir_create takes a str path");
            result = .none;
        },
        .file_rename => {
            if (arguments[0].value_type != .str or arguments[1].value_type != .str)
                return failIntrinsic(self, call, "file_rename takes (from str, to str)");
            result = .none;
        },
        // The two removals answer nothing for `dir_create`'s reason:
        // the world decided, and what it said travels in the error
        // channel.
        .dir_remove => {
            if (arguments[0].value_type != .str)
                return failIntrinsic(self, call, "dir_remove takes a str path");
            result = .none;
        },
        .temporary_directory => {
            if (arguments[0].value_type != .str or arguments[1].value_type != .str)
                return failIntrinsic(self, call, "temporary_directory takes a str parent and a str prefix");
            result = .str;
        },
        .tree_remove => {
            if (arguments[0].value_type != .str)
                return failIntrinsic(self, call, "tree_remove takes a str path");
            result = .none;
        },
        // The two stat facts answer numbers: a byte count, and
        // milliseconds since the epoch on `epoch_ms`'s terms.
        .path_size => {
            if (arguments[0].value_type != .str)
                return failIntrinsic(self, call, "path_size takes a str path");
            result = .i64;
        },
        .path_modified => {
            if (arguments[0].value_type != .str)
                return failIntrinsic(self, call, "path_modified takes a str path");
            result = .i64;
        },
        .dir_list => {
            if (arguments[0].value_type != .str)
                return failIntrinsic(self, call, "dir_list takes a str path");
            result = try resolve.internHeapType(self.analyzer, .{ .list = .str });
        },
        // The byte channel's door (docs/BYTES.md R5).  The mode is
        // a number here and a named door in `std.files`, which is
        // where a reader meets it: a builtin speaks what the host
        // slot speaks, and the library is where it gets a name.
        .file_open => {
            if (arguments[0].value_type != .str)
                return failIntrinsic(self, call, "file_open takes (path str, mode i64)");
            if (!arguments[1].value_type.eql(.i64))
                return failIntrinsic(self, call, "file_open takes (path str, mode i64)");
            result = try resolve.internHeapType(self.analyzer, .handle);
        },
        // The transport doors (docs/NETWORK.md).  Like `file_open`,
        // each answers the raw handle currency; `std.network` is where
        // the handles get their Connection and Listener classes.
        .socket_connect => {
            if (arguments[0].value_type != .str or !arguments[1].value_type.eql(.i64))
                return failIntrinsic(self, call, "socket_connect takes (host str, port i64)");
            result = try resolve.internHeapType(self.analyzer, .handle);
        },
        .socket_listen => {
            if (!arguments[0].value_type.eql(.i64))
                return failIntrinsic(self, call, "socket_listen takes a port i64");
            result = try resolve.internHeapType(self.analyzer, .handle);
        },
        .socket_accept => {
            const handle_type = try resolve.internHeapType(self.analyzer, .handle);
            if (!arguments[0].value_type.eql(handle_type))
                return failIntrinsic(self, call, "socket_accept takes a listener handle");
            result = handle_type;
        },
        .socket_port => {
            const handle_type = try resolve.internHeapType(self.analyzer, .handle);
            if (!arguments[0].value_type.eql(handle_type))
                return failIntrinsic(self, call, "socket_port takes a listener handle");
            result = .i64;
        },
        // The byte channel itself (docs/BYTES.md R4): a read fills
        // the caller's rank-1 `array[u8, _]` and answers how many
        // bytes landed — zero is the end — and a write takes the
        // buffer and a count and answers how many landed.  Standard
        // classes (`files.File`) call these on the handle they own;
        // there is no receiver syntax on the raw currency.
        .handle_read => {
            const handle_type = try resolve.internHeapType(self.analyzer, .handle);
            const buffer_type = try resolve.internHeapType(self.analyzer, .{ .array = .{ .element = .u8, .rank = 1 } });
            if (!arguments[0].value_type.eql(handle_type) or
                !arguments[1].value_type.eql(buffer_type))
                return failIntrinsic(self, call, "handle_read takes (from handle, into array[u8, _])");
            result = .i64;
        },
        .handle_write => {
            const handle_type = try resolve.internHeapType(self.analyzer, .handle);
            const buffer_type = try resolve.internHeapType(self.analyzer, .{ .array = .{ .element = .u8, .rank = 1 } });
            if (!arguments[0].value_type.eql(handle_type) or
                !arguments[1].value_type.eql(buffer_type) or
                !arguments[2].value_type.eql(.i64))
                return failIntrinsic(self, call, "handle_write takes (to handle, from array[u8, _], count i64)");
            result = .i64;
        },
        .handle_flush => {
            const handle_type = try resolve.internHeapType(self.analyzer, .handle);
            if (!arguments[0].value_type.eql(handle_type))
                return failIntrinsic(self, call, "handle_flush takes a handle");
            result = .none;
        },
        // `t.wait()` stays a receiver method: the result type is the
        // task's, so only the receiver can say it.
        .task_wait => unreachable,
    }
    // `error("…")` leaves the function, so it can stand where a
    // value belongs the way `trap("…")` can — but only inside a
    // function that said it can fail.
    if (matched.kind == .raise_error and !self.fallible) {
        try self.fail(
            "luce.sema.fallible",
            call.span,
            "error raises, and {s} does not say it can fail; write '-> !' (or '-> T!') on its signature",
            .{self.name},
        );
        return .failed;
    }
    const leaves = matched.kind == .raise_error;
    if (result == .none and !as_statement and !leaves) {
        try self.fail("luce.sema.call", call.span, "{s} returns nothing", .{matched.name});
        return .failed;
    }

    // The recorded batch: written operands in written order — each
    // read back off the slot it landed on — then the defaulted slots,
    // ascending, as they
    // were materialized.  `free`'s hidden trailing argument is
    // derived from the operand's own binding and is not an
    // operand.
    const entries = try self.arena().alloc(RecordedOperand, arguments.len);
    for (slots, 0..) |slot, index| {
        entries[index] = .{
            .node = arguments[slot].node,
            .slot = slot,
            .copied = run.copied[index],
        };
    }
    var next_entry = written.len;
    for (matched.parameters, seen, 0..) |_, given, slot| {
        if (given) continue;
        entries[next_entry] = .{ .node = arguments[slot].node, .slot = @intCast(slot) };
        next_entry += 1;
    }
    const node = try recorder.recordCallNode(
        self,
        .{ .intrinsic = matched.kind },
        entries,
        written.len,
        matched.kind.isFallible(),
        result,
        call.span,
    );

    // Two host services can be told no by the world, and one
    // builtin says no itself.  All three end this frame or hand
    // their caller a branch, exactly as a fallible call does —
    // the raise's unwind and its releases are lower's, from the
    // recorded floors.
    if (leaves) {
        return .{ .value = .{ .node = node, .value_type = .none } };
    }
    if (matched.kind.isFallible()) {
        if (!fallible_allowed) {
            try self.fail(
                "luce.sema.fallible",
                call.span,
                "{s} can fail: write 'try {s}(…)' to pass the error on, or '{s}(…) catch …' to handle it",
                .{ matched.name, matched.name, matched.name },
            );
            return .failed;
        }
        return .{ .value = try self.openFallible(result, node, call.span) };
    }
    return .{ .value = .{ .node = node, .value_type = result } };
}

fn failIntrinsic(self: *FunctionBuilder, call: ast.Call, message: []const u8) Error!IntrinsicResult {
    try self.fail("luce.sema.type", call.span, "{s}", .{message});
    return .failed;
}
