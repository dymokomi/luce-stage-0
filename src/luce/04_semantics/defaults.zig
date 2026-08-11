//! The folded defaults: a parameter's, a struct field's, and a union
//! payload field's.
//!
//! Three places a program may write `= EXPRESSION` on a declaration
//! rather than on a binding, and one answer for all three, which is
//! why they are one file: a default is folded **at the declaration**
//! (docs/ARGS.md D2), so a bad one is a compile error whether or not
//! anything ever constructs the thing that carries it, and it is
//! folded **at the declared type**, so what lands is checked by the
//! same landing rule a written value meets.
//!
//! Eager on the outside and lazy underneath, because a default may
//! construct a struct and lean on *its* defaults in turn: each slot
//! carries its own pending/evaluating/ready state, and a default that
//! depends on itself is reported as that rather than recursed into.
//! The ownership rule is the same in all three, and is S24's: a
//! defaulted place is one nobody wrote at the construction site, so
//! there is no owner a shared object could stand in for.
//!
//! The folding itself is `constants.zig`'s — this file decides what
//! may be folded, at which type, and what the refusal says.
//!
//! Free functions over `declarations.zig`'s `*Analyzer`; `pub` means
//! visible to stage 4's own files, nothing wider.

const std = @import("std");
const ast = @import("../03_parse.zig").ast;
const types = @import("../support/types.zig");
const helpers = @import("helpers.zig");

// Compile-time evaluation: the folder every default goes through
// (`constants.zig`).
const constants = @import("constants.zig");

const shapes = @import("shapes.zig");

const context = @import("context.zig");
const Error = context.Error;
const Type = types.Type;
const TypedConstant = context.TypedConstant;
const Analyzer = @import("declarations.zig").Analyzer;

/// Fold one parameter default at the parameter's own type
/// (docs/ARGS.md D2), using the same folder as file-scope `const`.
/// A value default is materialized at each call as the register its
/// written expression would have produced; a container default
/// names one program-root row shared by every omitted call.  Null
/// after reporting.
pub fn foldDefault(
    self: *Analyzer,
    module: usize,
    declaration: *const ast.FuncDecl,
    parameter: ast.Parameter,
    resolved: Type,
    written: *const ast.Expression,
) Error!?TypedConstant {
    // A give parameter takes ownership, while a program-root
    // container has no ownership to transfer.  Borrowed defaults
    // may be container constants: every omitted call then borrows
    // the same per-runtime root (docs/CONSTANTS.md, Surface
    // interactions).
    if (parameter.mode == .give) {
        try self.fail(
            "luce.sema.own",
            parameter.span,
            "a give parameter takes ownership, so its default cannot be a shared constant container [OWNERSHIP.md S13, S32, S46]",
            .{},
        );
        return null;
    }
    if (helpers.deeperThan(written, helpers.max_expression_depth)) {
        try self.fail(
            "luce.sema.nesting",
            parameter.span,
            "expression nested too deeply (limit {d})",
            .{helpers.max_expression_depth},
        );
        return null;
    }
    // A default is folded before any call is made, so no
    // parameter has a value it could read — the fact that keeps
    // signatures from becoming programs (docs/ARGS.md, Refused:
    // call-time defaults).
    if (parameterRead(declaration, written)) |read| {
        try self.fail(
            "luce.sema.const",
            written.span(),
            "a default cannot use {s}: it is folded before any call is made",
            .{read},
        );
        return null;
    }
    const previous_subject = self.fold_subject;
    const previous_name = self.fold_container_name;
    const previous_file = self.fold_container_file;
    const previous_origin = self.fold_container_origin;
    const previous_nesting = self.folding_container;
    self.fold_subject = "a default";
    self.fold_container_name = try std.fmt.allocPrint(
        self.arena,
        "{s}.{s} default",
        .{ declaration.name, parameter.name },
    );
    self.fold_container_file = self.modules[module].file;
    self.fold_container_origin = @intCast(parameter.name_span.start);
    self.folding_container = false;
    defer {
        self.fold_subject = previous_subject;
        self.fold_container_name = previous_name;
        self.fold_container_file = previous_file;
        self.fold_container_origin = previous_origin;
        self.folding_container = previous_nesting;
    }
    const folded = (try constants.fold(self, module, written, resolved)) orelse return null;
    const fitted = constants.fit(folded, resolved) orelse {
        try self.fail("luce.sema.type", parameter.span, "{s} is {s} and its default is {s}", .{
            parameter.name,
            try self.typeName(resolved),
            try self.typeName(folded.value_type),
        });
        return null;
    };
    return fitted;
}

/// Fold every field default, eagerly (docs/ARGS.md D2): a default
/// is evaluated at the declaration, so a bad one is a compile
/// error whether or not anything ever constructs the struct —
/// the same promise a parameter default keeps.  Lazy underneath
/// (`fieldDefault`), because one default may construct a struct
/// whose own defaults are still pending.
pub fn settleFieldDefaults(self: *Analyzer) Error!void {
    for (0..self.struct_decls.items.len) |index| {
        const count = self.struct_decls.items[index].field_defaults.len;
        for (0..count) |field_index| {
            _ = try fieldDefault(self, @intCast(index), field_index);
        }
    }
}

/// Whether one collected field declared a default at all — asked
/// separately from `fieldDefault`, whose null also means "it
/// failed, and the failure is already reported".
pub fn fieldHasDefault(self: *const Analyzer, layout_index: u32, field_index: usize) bool {
    if (layout_index >= self.struct_decls.items.len) return false; // a synthesized shape has no declaration
    const info = self.struct_decls.items[layout_index];
    if (field_index >= info.field_defaults.len) return false;
    return info.field_defaults[field_index].expression != null;
}

/// The folded default of one field (docs/ARGS.md D8), or null when
/// there is none or it failed (already reported).  Lazy and
/// cycle-checked like a file-scope constant, because a default may
/// construct another struct and lean on *its* defaults in turn.
pub fn fieldDefault(self: *Analyzer, layout_index: u32, field_index: usize) Error!?TypedConstant {
    if (layout_index >= self.struct_decls.items.len) return null;
    {
        const info = self.struct_decls.items[layout_index];
        if (field_index >= info.field_defaults.len) return null;
    }
    const slot = &self.struct_decls.items[layout_index].field_defaults[field_index];
    const written = slot.expression orelse return null;
    switch (slot.state) {
        .ready => return .{ .value = slot.value, .value_type = slot.value_type },
        .failed => return null,
        .evaluating => {
            const layout = self.structs.items[layout_index];
            try self.fail("luce.sema.const", written.span(), "the default of {s}.{s} depends on itself", .{
                layout.name,
                layout.fields[field_index].name,
            });
            slot.state = .failed;
            return null;
        },
        .pending => {},
    }
    slot.state = .evaluating;
    const info = self.struct_decls.items[layout_index];
    // The diagnostic points into the file the struct lives in,
    // whichever module's fold walked into it.
    const previous_scope = self.diagnostics.scope;
    self.diagnostics.scope = self.modules[info.module].file;
    defer self.diagnostics.scope = previous_scope;
    const folded = try foldFieldDefault(self, info.module, layout_index, field_index, written);
    // The list may not move while a fold is in flight (it is
    // temporary-allocated and only appended before folding), but
    // re-find the slot the way `evaluateConstant` does rather than
    // lean on that.
    const settled = &self.struct_decls.items[layout_index].field_defaults[field_index];
    const result = folded orelse {
        settled.state = .failed;
        return null;
    };
    settled.value = result.value;
    settled.value_type = result.value_type;
    settled.state = .ready;
    return result;
}

/// The checking half of `fieldDefault`: ownership, depth, the
/// fold at the field's type, and the landing check.  Null after
/// reporting.
fn foldFieldDefault(
    self: *Analyzer,
    module: usize,
    layout_index: u32,
    field_index: usize,
    written: *const ast.Expression,
) Error!?TypedConstant {
    const layout = self.structs.items[layout_index];
    const field = layout.fields[field_index];
    // S24: the binding that receives the struct owns its object
    // fields, and a defaulted field is one nobody wrote at the
    // construction site — there is no owner a constant could
    // stand in for (docs/ARGS.md §5).
    if (shapes.carriesObjects(self, field.field_type)) {
        try self.fail(
            "luce.sema.own",
            written.span(),
            "{s}.{s} keeps its object, so its default cannot be a shared object [OWNERSHIP.md S21, S24, S46]",
            .{ layout.name, field.name },
        );
        return null;
    }
    if (helpers.deeperThan(written, helpers.max_expression_depth)) {
        try self.fail(
            "luce.sema.nesting",
            written.span(),
            "expression nested too deeply (limit {d})",
            .{helpers.max_expression_depth},
        );
        return null;
    }
    const previous_subject = self.fold_subject;
    self.fold_subject = "a default";
    defer self.fold_subject = previous_subject;
    const folded = (try constants.fold(self, module, written, field.field_type)) orelse return null;
    const fitted = constants.fit(folded, field.field_type) orelse {
        try self.fail("luce.sema.type", written.span(), "{s}.{s} is {s} and its default is {s}", .{
            layout.name,
            field.name,
            try self.typeName(field.field_type),
            try self.typeName(folded.value_type),
        });
        return null;
    };
    return fitted;
}

/// Fold every union payload field default, eagerly (docs/UNION.md
/// D4, docs/ARGS.md D2): a default is evaluated at the
/// declaration, so a bad one is a compile error whether or not
/// anything ever constructs the member.
pub fn settleVariantDefaults(self: *Analyzer) Error!void {
    for (0..self.variant_decls.items.len) |index| {
        const member_count = self.variant_decls.items[index].member_defaults.len;
        for (0..member_count) |member_index| {
            const field_count = self.variant_decls.items[index].member_defaults[member_index].len;
            for (0..field_count) |field_index| {
                _ = try variantFieldDefault(self, @intCast(index), member_index, field_index);
            }
        }
    }
}

/// Whether one collected member field declared a default at all —
/// asked separately from `variantFieldDefault`, whose null also
/// means "it failed, and the failure is already reported".
pub fn variantFieldHasDefault(
    self: *const Analyzer,
    variant_index: u32,
    member_index: usize,
    field_index: usize,
) bool {
    if (variant_index >= self.variant_decls.items.len) return false;
    const info = self.variant_decls.items[variant_index];
    if (member_index >= info.member_defaults.len) return false;
    if (field_index >= info.member_defaults[member_index].len) return false;
    return info.member_defaults[member_index][field_index].expression != null;
}

/// The folded default of one union payload field (docs/UNION.md
/// D4), or null when there is none or it failed (already
/// reported).  Lazy and cycle-checked like a struct field's,
/// because a default may construct a struct and lean on *its*
/// defaults in turn.
pub fn variantFieldDefault(
    self: *Analyzer,
    variant_index: u32,
    member_index: usize,
    field_index: usize,
) Error!?TypedConstant {
    if (!variantFieldHasDefault(self, variant_index, member_index, field_index)) return null;
    const slot = &self.variant_decls.items[variant_index].member_defaults[member_index][field_index];
    const written = slot.expression orelse return null;
    const declared = self.variants.items[variant_index];
    const member = declared.members[member_index];
    const field = member.fields[field_index];
    switch (slot.state) {
        .ready => return .{ .value = slot.value, .value_type = slot.value_type },
        .failed => return null,
        .evaluating => {
            try self.fail("luce.sema.const", written.span(), "the default of {s}.{s}.{s} depends on itself", .{
                declared.name,
                member.name,
                field.name,
            });
            slot.state = .failed;
            return null;
        },
        .pending => {},
    }
    slot.state = .evaluating;
    const info = self.variant_decls.items[variant_index];
    const previous_scope = self.diagnostics.scope;
    self.diagnostics.scope = self.modules[info.module].file;
    defer self.diagnostics.scope = previous_scope;
    const folded = try foldVariantFieldDefault(self, info.module, declared, member, field, written);
    const settled = &self.variant_decls.items[variant_index].member_defaults[member_index][field_index];
    const result = folded orelse {
        settled.state = .failed;
        return null;
    };
    settled.value = result.value;
    settled.value_type = result.value_type;
    settled.state = .ready;
    return result;
}

/// The checking half of `variantFieldDefault`: ownership, depth,
/// the fold at the field's type, and the landing check — S24's
/// struct-field rule verbatim, because a payload field is a place
/// that stores (docs/UNION.md).  Null after reporting.
fn foldVariantFieldDefault(
    self: *Analyzer,
    module: usize,
    declared: types.VariantType,
    member: types.VariantMember,
    field: types.StructField,
    written: *const ast.Expression,
) Error!?TypedConstant {
    if (shapes.carriesObjects(self, field.field_type)) {
        try self.fail(
            "luce.sema.own",
            written.span(),
            "{s}.{s}.{s} keeps its object, so its default cannot be a shared object [OWNERSHIP.md S21, S24, S46]",
            .{ declared.name, member.name, field.name },
        );
        return null;
    }
    if (helpers.deeperThan(written, helpers.max_expression_depth)) {
        try self.fail(
            "luce.sema.nesting",
            written.span(),
            "expression nested too deeply (limit {d})",
            .{helpers.max_expression_depth},
        );
        return null;
    }
    const previous_subject = self.fold_subject;
    self.fold_subject = "a default";
    defer self.fold_subject = previous_subject;
    const folded = (try constants.fold(self, module, written, field.field_type)) orelse return null;
    const fitted = constants.fit(folded, field.field_type) orelse {
        try self.fail("luce.sema.type", written.span(), "{s}.{s}.{s} is {s} and its default is {s}", .{
            declared.name,
            member.name,
            field.name,
            try self.typeName(field.field_type),
            try self.typeName(folded.value_type),
        });
        return null;
    };
    return fitted;
}

/// The first of the declaration's parameter names `expression`
/// reads — `self` included — or null when it reads none.  A pure
/// syntactic walk: whether the name means anything else is the
/// folder's question, asked after this one so the better sentence
/// wins.
fn parameterRead(declaration: *const ast.FuncDecl, expression: *const ast.Expression) ?[]const u8 {
    switch (expression.*) {
        .int_literal, .float_literal, .bool_literal, .string_literal, .none_literal => return null,
        .name => |name| {
            for (declaration.parameters) |parameter| {
                if (std.mem.eql(u8, parameter.name, name.text)) return name.text;
            }
            return null;
        },
        .field => |field| return parameterRead(declaration, field.target),
        .spawn => |worker| return parameterRead(declaration, worker.call),
        .lambda => |written| return parameterRead(declaration, written.body),
        .call => |call| {
            for (call.arguments) |argument| {
                if (parameterRead(declaration, argument.value)) |read| return read;
            }
            return null;
        },
        .method => |method| {
            if (parameterRead(declaration, method.target)) |read| return read;
            for (method.arguments) |argument| {
                if (parameterRead(declaration, argument.value)) |read| return read;
            }
            return null;
        },
        .binary => |binary| {
            if (parameterRead(declaration, binary.left)) |read| return read;
            return parameterRead(declaration, binary.right);
        },
        .unary => |unary| return parameterRead(declaration, unary.operand),
        .new_object => |made| {
            for (made.dims) |dim| {
                if (parameterRead(declaration, dim)) |read| return read;
            }
            return null;
        },
        .list_literal => |list| {
            for (list.elements) |element| {
                if (parameterRead(declaration, element)) |read| return read;
            }
            return null;
        },
        .map_literal => |map| {
            for (map.entries) |entry| {
                if (parameterRead(declaration, entry.key)) |read| return read;
                if (parameterRead(declaration, entry.value)) |read| return read;
            }
            return null;
        },
        .index => |indexed| {
            if (parameterRead(declaration, indexed.target)) |read| return read;
            for (indexed.indices) |position| {
                if (parameterRead(declaration, position)) |read| return read;
            }
            return null;
        },
        .slice_range => |slice| {
            if (parameterRead(declaration, slice.target)) |read| return read;
            if (slice.start) |start| {
                if (parameterRead(declaration, start)) |read| return read;
            }
            if (slice.end) |end| {
                if (parameterRead(declaration, end)) |read| return read;
            }
            return null;
        },
        .give => |verb| return parameterRead(declaration, verb.operand),
        .copy => |verb| return parameterRead(declaration, verb.operand),
        .try_call => |tried| return parameterRead(declaration, tried.operand),
    }
}
