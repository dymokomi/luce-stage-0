//! The declared type tables: enums, unions, and structs — their
//! names first, then what each of them holds.
//!
//! Pass one collects in the order the language's own rules impose,
//! and this file is where that order is written down.  Enum and union
//! *names* before anything else, because a struct field, a parameter
//! or a constant's annotation may name one.  Struct names next, so a
//! field may name a struct declared below it.  Then the contents: a
//! union member's payload fields, which may hold a struct; and an
//! enum member's values, which are folded only after the constant
//! names exist, because `= base + 1` may name one (docs/ENUMS.md D8).
//!
//! What every one of them *costs* — the cycle check and the shape sum
//! — is `shapes.zig`, and runs on the edges these tables are.  What a
//! field's default folds to is `defaults.zig`.  Both are separate
//! because both need every name in the program to exist first, which
//! is exactly what this file finishes.
//!
//! Free functions over `declarations.zig`'s `*Analyzer`; `pub` means
//! visible to stage 4's own files, nothing wider.

const std = @import("std");
const source_mod = @import("../01_source.zig");
const ast = @import("../03_parse.zig").ast;
const types = @import("../support/types.zig");

// Compile-time evaluation: the folder an enum member's value goes
// through (`constants.zig`).
const constants = @import("constants.zig");

const aliases = @import("aliases.zig");
const naming = @import("naming.zig");
const resolve = @import("resolve.zig");
const shapes = @import("shapes.zig");
const interfaces = @import("interfaces.zig");

const context = @import("context.zig");
const Error = context.Error;
const Span = source_mod.Span;
const ModuleTree = context.ModuleTree;
const isReserved = context.isReserved;
const Analyzer = @import("declarations.zig").Analyzer;

// -- pass one: enums and unions, names then contents -------------------

/// Register every declared enum's and union's name, in source
/// order per module, so a duplicate between the two kinds reports
/// at whichever stands second in the file — the same promise the
/// struct-above check keeps one kind at a time.
pub fn collectTypeNames(self: *Analyzer) Error!void {
    for (self.modules, 0..) |module, module_index| {
        self.diagnostics.scope = module.file;
        var next_enum: usize = 0;
        var next_union: usize = 0;
        while (next_enum < module.tree.enums.len or next_union < module.tree.unions.len) {
            const take_enum = next_union >= module.tree.unions.len or
                (next_enum < module.tree.enums.len and
                    module.tree.enums[next_enum].name_span.start <
                        module.tree.unions[next_union].name_span.start);
            if (take_enum) {
                try collectEnumName(self, module, module_index, &module.tree.enums[next_enum]);
                next_enum += 1;
            } else {
                try collectUnionName(self, module, module_index, &module.tree.unions[next_union]);
                next_union += 1;
            }
        }
    }
    self.diagnostics.scope = source_mod.root_file;
}

/// Register one declared enum's name and backing width
/// (docs/ENUMS.md D1, D2).  The members are collected here too,
/// with their names and their *positions*; the values are folded by
/// `settleEnumMembers` below, once every name in the program
/// exists.
fn collectEnumName(
    self: *Analyzer,
    module: ModuleTree,
    module_index: usize,
    declaration: *const ast.EnumDecl,
) Error!void {
    if (isReserved(declaration.name)) {
        try self.fail("luce.sema.reserved", declaration.name_span, "{s} is a reserved name", .{declaration.name});
        return;
    }
    if (types.builtinNamed(declaration.name) != null) {
        try self.fail(
            "luce.sema.reserved",
            declaration.name_span,
            "{s} is a builtin type; an enum of your own takes a name of its own",
            .{declaration.name},
        );
        return;
    }
    const qualified = try naming.qualify(self, module.prefix, declaration.name);
    if (try naming.firstDeclarationOf(self, qualified)) |where| {
        try self.fail("luce.sema.duplicate", declaration.name_span, "duplicate name {s}; the first is{s}", .{
            declaration.name,
            where,
        });
        return;
    }
    // **Whichever was written first is the first.**  Enums are
    // collected before structs — a struct field may name one — so
    // a struct of the same name is still invisible here; the one
    // this file *reads* first is decided by where the two stand,
    // not by which table filled first.  A struct above this enum
    // reports here; a struct below it lets the enum register and
    // reports there.
    if (structDeclaredAbove(module.tree.*, declaration.name, declaration.name_span)) |first| {
        try self.fail("luce.sema.duplicate", declaration.name_span, "duplicate name {s}; the first is{s}", .{
            declaration.name,
            try naming.declaredAt(self, module.file, first.name_span),
        });
        return;
    }
    // The width, before the members: it is what says which of them
    // fit, and the default is `int` (D2).
    var backing: types.Type.EnumRef.Backing = .int;
    if (declaration.backing) |written| {
        const resolved = (try resolve.resolveType(self, module_index, written)) orelse return;
        backing = types.Type.EnumRef.Backing.of(resolved) orelse {
            try self.fail(
                "luce.sema.enum",
                written.span,
                "an enum is stored at an integer width: byte, short, int, or long — not {s}",
                .{try self.typeName(resolved)},
            );
            return;
        };
    }
    if (declaration.members.len == 0) {
        try self.fail(
            "luce.sema.enum",
            declaration.span,
            "enum {s} names no members; an enum is the set of names it declares",
            .{declaration.name},
        );
        return;
    }
    var members: std.ArrayList(types.EnumMember) = .empty;
    defer members.deinit(self.arena);
    for (declaration.members) |member| {
        if (isReserved(member.name)) {
            try self.fail("luce.sema.reserved", member.name_span, "{s} is a reserved name", .{member.name});
            continue;
        }
        var duplicate = false;
        for (members.items) |existing| {
            if (std.mem.eql(u8, existing.name, member.name)) duplicate = true;
        }
        if (duplicate) {
            try self.fail(
                "luce.sema.duplicate",
                member.name_span,
                "duplicate member {s} of enum {s}",
                .{ member.name, declaration.name },
            );
            continue;
        }
        // A function of the enum may not wear a member's name:
        // `Method.stored` would mean two things, and the
        // head-names-a-declaration path answers one.
        for (declaration.functions) |function| {
            if (!std.mem.eql(u8, function.name, member.name)) continue;
            try self.fail(
                "luce.sema.duplicate",
                function.span,
                "enum {s} already has member {s}",
                .{ declaration.name, function.name },
            );
        }
        try members.append(self.arena, .{ .name = try self.arena.dupe(u8, member.name), .value = 0 });
    }
    if (members.items.len == 0) return; // every member was refused
    const index: u32 = @intCast(self.enums.items.len);
    try self.enum_names.put(self.temporary, qualified, index);
    try self.enum_decls.append(self.temporary, .{
        .declaration = declaration,
        .module = module_index,
    });
    try self.enums.append(self.arena, .{
        .name = try self.arena.dupe(u8, qualified),
        .backing = backing,
        .members = try members.toOwnedSlice(self.arena),
    });
}

/// Register one declared union's name and its members' names
/// (docs/UNION.md D1).  The member *field types* are resolved by
/// `settleVariantMembers` below, once the struct names exist —
/// a payload may hold one, and a struct field may hold a union.
fn collectUnionName(
    self: *Analyzer,
    module: ModuleTree,
    module_index: usize,
    declaration: *const ast.UnionDecl,
) Error!void {
    if (isReserved(declaration.name)) {
        try self.fail("luce.sema.reserved", declaration.name_span, "{s} is a reserved name", .{declaration.name});
        return;
    }
    if (types.builtinNamed(declaration.name) != null) {
        try self.fail(
            "luce.sema.reserved",
            declaration.name_span,
            "{s} is a builtin type; a union of your own takes a name of its own",
            .{declaration.name},
        );
        return;
    }
    const qualified = try naming.qualify(self, module.prefix, declaration.name);
    if (try naming.firstDeclarationOf(self, qualified)) |where| {
        try self.fail("luce.sema.duplicate", declaration.name_span, "duplicate name {s}; the first is{s}", .{
            declaration.name,
            where,
        });
        return;
    }
    if (structDeclaredAbove(module.tree.*, declaration.name, declaration.name_span)) |first| {
        try self.fail("luce.sema.duplicate", declaration.name_span, "duplicate name {s}; the first is{s}", .{
            declaration.name,
            try naming.declaredAt(self, module.file, first.name_span),
        });
        return;
    }
    if (declaration.members.len == 0) {
        try self.fail(
            "luce.sema.union",
            declaration.span,
            "union {s} names no members; a union is the set of members it declares",
            .{declaration.name},
        );
        return;
    }
    // **At least one member must carry a payload** (D2): a union
    // of bare members is an enum — cheaper in every way, with a
    // backing width, `int(m)`, `{s}(n)` and no allocation.
    var carries_payload = false;
    for (declaration.members) |member| {
        if (member.fields.len != 0) carries_payload = true;
    }
    if (!carries_payload) {
        try self.fail(
            "luce.sema.union",
            declaration.span,
            "no member of union {s} carries a payload; a set of bare names is an enum — write enum {s}:",
            .{ declaration.name, declaration.name },
        );
        return;
    }
    var members: std.ArrayList(types.VariantMember) = .empty;
    defer members.deinit(self.arena);
    for (declaration.members) |member| {
        if (isReserved(member.name)) {
            try self.fail("luce.sema.reserved", member.name_span, "{s} is a reserved name", .{member.name});
            continue;
        }
        var duplicate = false;
        for (members.items) |existing| {
            if (std.mem.eql(u8, existing.name, member.name)) duplicate = true;
        }
        if (duplicate) {
            try self.fail(
                "luce.sema.duplicate",
                member.name_span,
                "duplicate member {s} of union {s}",
                .{ member.name, declaration.name },
            );
            continue;
        }
        // A function of the union may not wear a member's name:
        // `Shape.circle` would mean two things (D17).
        for (declaration.functions) |function| {
            if (!std.mem.eql(u8, function.name, member.name)) continue;
            try self.fail(
                "luce.sema.duplicate",
                function.span,
                "union {s} already has member {s}",
                .{ declaration.name, function.name },
            );
        }
        // Field slots are allocated now, in member order, and
        // typed by `settleVariantMembers`; a field refused there
        // keeps its slot so the member's arity stays the
        // declaration's.
        try members.append(self.arena, .{
            .name = try self.arena.dupe(u8, member.name),
            .fields = try self.arena.alloc(types.StructField, member.fields.len),
        });
    }
    if (members.items.len == 0) return; // every member was refused
    const index: u32 = @intCast(self.variants.items.len);
    try self.variant_names.put(self.temporary, qualified, index);
    try self.variant_decls.append(self.temporary, .{
        .declaration = declaration,
        .module = module_index,
    });
    try self.variants.append(self.arena, .{
        .name = try self.arena.dupe(u8, qualified),
        .members = try members.toOwnedSlice(self.arena),
    });
}

/// The struct of this module that takes `name` and stands above
/// `span` in the file, or null.
fn structDeclaredAbove(tree: ast.Program, name: []const u8, span: Span) ?*const ast.StructDecl {
    for (tree.structs) |*strukt| {
        if (!std.mem.eql(u8, strukt.name, name)) continue;
        if (strukt.name_span.start < span.start) return strukt;
    }
    return null;
}

/// Fold every member's value, in declaration order (D1): a written
/// `= EXPRESSION` is folded by the constant folder, an unvalued
/// member takes the one before it plus one, and an unvalued first
/// member is 0 — the C rule, verbatim.  Two members with one value
/// are refused by name, and a value the backing width cannot hold
/// is refused by the sentence a literal already gets.
pub fn settleEnumMembers(self: *Analyzer) Error!void {
    for (0..self.enum_decls.items.len) |index| {
        const info = self.enum_decls.items[index];
        self.diagnostics.scope = self.modules[info.module].file;
        const backing = self.enums.items[index].backing.asType();
        const bounds = backing.integerRange();
        var next: i128 = 0;
        // The declaration's members and the collected ones differ
        // where one was refused, so they are walked by name.
        for (info.declaration.members) |written| {
            const slot = self.enums.items[index].findMember(written.name) orelse continue;
            var value: i128 = next;
            if (written.value) |expression| {
                // Folded at `long` rather than at the backing
                // width, so a value the width cannot hold is
                // refused by *this* stage's sentence — the one that
                // names the enum's width and the fix for it —
                // rather than by the literal's, which would talk
                // about a place the reader never wrote.
                const folded = (try constants.fold(self, info.module, expression, .long)) orelse continue;
                if (folded.value != .long or !folded.value_type.isInteger()) {
                    try self.fail(
                        "luce.sema.enum",
                        expression.span(),
                        "a member's value is a constant integer; {s} is {s}",
                        .{ written.name, try self.typeName(folded.value_type) },
                    );
                    continue;
                }
                value = folded.value.long;
            }
            if (value < bounds.low or value > bounds.high) {
                try self.fail(
                    "luce.sema.enum",
                    written.span,
                    "{s} = {d} does not fit {s}, which holds {d} to {d}; write the enum's width wider — enum {s}(long):",
                    .{
                        written.name,
                        value,
                        try self.typeName(backing),
                        bounds.low,
                        bounds.high,
                        info.declaration.name,
                    },
                );
                continue;
            }
            // An alias is a `let` if a program wants one: two names
            // for one number make `string(m)` a coin toss and
            // `match` a set of arms that cannot all be reached.
            for (self.enums.items[index].members[0..slot]) |earlier| {
                if (earlier.value != @as(i64, @intCast(value))) continue;
                try self.fail(
                    "luce.sema.enum",
                    written.span,
                    "{s} and {s} are both {d}; every member of an enum holds its own number, and a second name for one is a let",
                    .{ earlier.name, written.name, value },
                );
                break;
            }
            self.enums.items[index].members[slot].value = @intCast(value);
            next = value + 1;
        }
        self.enum_decls.items[index].settled = true;
    }
    self.diagnostics.scope = source_mod.root_file;
}

// -- pass one: struct layouts -----------------------------------------

pub fn collectStructs(self: *Analyzer) Error!void {
    // Imports first: bindings must be usable and free of
    // collisions — the binding, not the module's name, because the
    // binding is the word that has to coexist with declarations.
    for (self.modules, 0..) |module, module_index| {
        self.diagnostics.scope = module.file;
        for (module.tree.imports) |imported| {
            if (isReserved(imported.binding) or std.mem.eql(u8, imported.binding, "evaluate")) {
                try self.fail("luce.sema.reserved", imported.span, "{s} is a reserved name", .{imported.binding});
            }
            for (module.tree.structs) |declaration| {
                if (std.mem.eql(u8, declaration.name, imported.binding)) {
                    try self.fail("luce.sema.duplicate", imported.span, "import {s} collides with a struct of the same name", .{imported.binding});
                }
            }
            for (module.tree.enums) |declaration| {
                if (std.mem.eql(u8, declaration.name, imported.binding)) {
                    try self.fail("luce.sema.duplicate", imported.span, "import {s} collides with an enum of the same name", .{imported.binding});
                }
            }
            for (module.tree.unions) |declaration| {
                if (std.mem.eql(u8, declaration.name, imported.binding)) {
                    try self.fail("luce.sema.duplicate", imported.span, "import {s} collides with a union of the same name", .{imported.binding});
                }
            }
        }
        _ = module_index;
    }

    // Names first so fields may reference structs in any order.
    for (self.modules, 0..) |module, module_index| {
        self.diagnostics.scope = module.file;
        for (module.tree.structs) |*declaration| {
            if (isReserved(declaration.name)) {
                try self.fail("luce.sema.reserved", declaration.name_span, "{s} is a reserved name", .{declaration.name});
                continue;
            }
            // A struct may not take a builtin type's name.  It is
            // refused here rather than shadowed silently, because
            // `resolveBase` answers first and the declaration
            // would be a type nothing could ever write down.
            if (types.builtinNamed(declaration.name) != null) {
                try self.fail(
                    "luce.sema.reserved",
                    declaration.name_span,
                    "{s} is a builtin type; a struct of your own takes a name of its own",
                    .{declaration.name},
                );
                continue;
            }
            const qualified = try naming.qualify(self, module.prefix, declaration.name);
            // Structs and enums share the type-name space: one
            // name, one declaration, whichever keyword wrote it.
            if (try naming.firstDeclarationOf(self, qualified)) |where| {
                try self.fail("luce.sema.duplicate", declaration.name_span, "duplicate name {s}; the first is{s}", .{
                    declaration.name,
                    where,
                });
                continue;
            }
            const index: u32 = @intCast(self.structs.items.len);
            try self.struct_names.put(self.temporary, qualified, index);
            try self.struct_decls.append(self.temporary, .{
                .declaration = declaration,
                .module = module_index,
            });
            try self.structs.append(self.arena, .{
                .name = try self.arena.dupe(u8, qualified),
                .fields = &.{},
                .reference = declaration.kind == .reference,
            });
        }
    }

    // Interfaces reserve their hidden layouts before struct fields are
    // resolved, so a struct may name an interface regardless of order.
    try interfaces.collectDeclarations(self);
    // Every nominal name now exists.  Resolve aliases once, before the first
    // field or interface signature asks for one, so unused cycles and unknown
    // targets are diagnostics too.
    try aliases.settleDeclarations(self);
    try interfaces.settleDeclarations(self);

    for (self.struct_decls.items) |info| {
        const declaration = info.declaration;
        self.diagnostics.scope = self.modules[info.module].file;
        const qualified = try naming.qualify(self, self.modules[info.module].prefix, declaration.name);
        const index = self.struct_names.get(qualified) orelse continue;
        var fields: std.ArrayList(types.StructField) = .empty;
        defer fields.deinit(self.arena);
        var field_defaults: std.ArrayList(context.FieldDefault) = .empty;
        defer field_defaults.deinit(self.arena);
        var field_visibility: std.ArrayList(ast.Visibility) = .empty;
        defer field_visibility.deinit(self.arena);
        // The first field that declared a default, for D3's
        // sentence when a required one follows it — the same
        // trailing rule a parameter list keeps (docs/ARGS.md D8).
        var first_defaulted: ?[]const u8 = null;
        for (declaration.fields) |field| {
            if (field.default == null) {
                if (first_defaulted) |earlier| {
                    try self.fail(
                        "luce.sema.struct",
                        field.span,
                        "{s} has a default, so {s} needs one too — the fields with defaults come last",
                        .{ earlier, field.name },
                    );
                    continue;
                }
            } else if (first_defaulted == null) {
                first_defaulted = field.name;
            }
            var duplicate = false;
            for (fields.items) |existing| {
                if (std.mem.eql(u8, existing.name, field.name)) duplicate = true;
            }
            if (duplicate) {
                try self.fail("luce.sema.duplicate", field.name_span, "duplicate field {s}; the first is{s}", .{
                    field.name,
                    try naming.declaredAt(self, self.modules[info.module].file, shapes.fieldSpan(self, index, field.name)),
                });
                continue;
            }
            const field_type = (try resolve.resolveType(self, info.module, field.type_name)) orelse continue;
            // A struct that carries behaviour is dispatch, and
            // dispatch is a question of its own — deferred rather
            // than refused (docs/FUNCTIONS.md S2).
            if (try resolve.refuseFunctionPart(self, field_type, field.type_name.span, "struct field")) continue;
            // D4, for a field: a reachable field may not publish a
            // hidden type.  Only the author of the marks can trip
            // this — nothing is private until someone writes it —
            // and the refusal lands on the line that can be fixed.
            // The field is still collected: its type resolved, and
            // dropping it would turn one mistake into a cascade
            // about the struct that holds it.
            if (declaration.visibility != .private and field.visibility != .private) {
                if (naming.privateMentioned(self, field_type)) |hidden| {
                    try self.fail(
                        "luce.sema.private",
                        field.type_name.span,
                        "{s} of {s} is public and holds {s}, which is marked private in {s}; mark {s} private or remove the mark on {s}",
                        .{
                            field.name,
                            declaration.name,
                            hidden,
                            naming.markedIn(self, info.module),
                            field.name,
                            hidden,
                        },
                    );
                }
            }
            try fields.append(self.arena, .{
                .name = try self.arena.dupe(u8, field.name),
                .field_type = field_type,
            });
            try field_defaults.append(self.arena, .{ .expression = field.default });
            try field_visibility.append(self.arena, field.visibility);
        }
        for (declaration.functions) |function| {
            for (declaration.fields) |field| {
                if (std.mem.eql(u8, function.name, field.name)) {
                    try self.fail(
                        "luce.sema.duplicate",
                        function.span,
                        "struct {s} already has field {s}",
                        .{ declaration.name, function.name },
                    );
                }
            }
        }
        if (fields.items.len == 0 and declaration.functions.len == 0) {
            try self.fail("luce.sema.struct", declaration.span, "struct {s} has an empty body", .{declaration.name});
        }
        self.structs.items[index].fields = try fields.toOwnedSlice(self.arena);
        self.struct_decls.items[index].field_defaults = try field_defaults.toOwnedSlice(self.arena);
        self.struct_decls.items[index].field_visibility = try field_visibility.toOwnedSlice(self.arena);
    }

    self.diagnostics.scope = source_mod.root_file;
}

// -- pass one: union member fields --------------------------------------

/// Resolve every union member's payload field types (docs/UNION.md
/// D1) — after `collectStructs`, because a payload may hold a
/// struct, and before the shape walk, whose edges these are.
/// Member field types resolve exactly like struct fields: same
/// duplicate rule, same function-type deferral, same D4 exposure
/// check, same trailing-defaults rule (D4).
pub fn settleVariantMembers(self: *Analyzer) Error!void {
    for (0..self.variant_decls.items.len) |index| {
        const info = self.variant_decls.items[index];
        self.diagnostics.scope = self.modules[info.module].file;
        const declaration = info.declaration;
        const collected = self.variants.items[index].members;
        const member_defaults = try self.arena.alloc([]context.FieldDefault, collected.len);
        const settled = try self.temporary.alloc(bool, collected.len);
        defer self.temporary.free(settled);
        @memset(settled, false);
        // Declared and collected members differ where one was
        // refused, so they are matched by name — first written
        // occupant wins, exactly as collection kept it; a refused
        // duplicate must not settle the survivor's slot again.
        for (declaration.members) |written| {
            const slot = self.variants.items[index].findMember(written.name) orelse continue;
            if (settled[slot]) continue;
            settled[slot] = true;
            const member = collected[slot];
            const defaults = try self.arena.alloc(context.FieldDefault, written.fields.len);
            member_defaults[slot] = defaults;
            var first_defaulted: ?[]const u8 = null;
            for (written.fields, member.fields, defaults) |field, *resolved_slot, *default_slot| {
                default_slot.* = .{ .expression = field.default };
                // The slot stays well-formed whatever the checks
                // below decide, so a refused field costs one
                // message and never an undefined read.
                resolved_slot.* = .{
                    .name = try self.arena.dupe(u8, field.name),
                    .field_type = .long,
                };
                if (field.default == null) {
                    if (first_defaulted) |earlier| {
                        try self.fail(
                            "luce.sema.union",
                            field.span,
                            "{s} has a default, so {s} needs one too — the fields with defaults come last",
                            .{ earlier, field.name },
                        );
                        continue;
                    }
                } else if (first_defaulted == null) {
                    first_defaulted = field.name;
                }
                var duplicate = false;
                for (written.fields) |other| {
                    if (other.name_span.start >= field.name_span.start) break;
                    if (std.mem.eql(u8, other.name, field.name)) duplicate = true;
                }
                if (duplicate) {
                    try self.fail(
                        "luce.sema.duplicate",
                        field.name_span,
                        "duplicate field {s} of {s}.{s}",
                        .{ field.name, declaration.name, written.name },
                    );
                    continue;
                }
                const field_type = (try resolve.resolveType(self, info.module, field.type_name)) orelse continue;
                if (try resolve.refuseFunctionPart(self, field_type, field.type_name.span, "union payload field")) continue;
                // D4's rule for a member field: a union's members
                // are always as visible as the union, so a
                // reachable union may not publish a hidden type
                // through one (docs/VISIBILITY.md D4).
                if (declaration.visibility != .private) {
                    if (naming.privateMentioned(self, field_type)) |hidden| {
                        try self.fail(
                            "luce.sema.private",
                            field.type_name.span,
                            "{s} of {s} is public and holds {s}, which is marked private in {s}; mark {s} private or remove the mark on {s}",
                            .{
                                field.name,
                                declaration.name,
                                hidden,
                                naming.markedIn(self, info.module),
                                declaration.name,
                                hidden,
                            },
                        );
                    }
                }
                resolved_slot.field_type = field_type;
            }
        }
        self.variant_decls.items[index].member_defaults = member_defaults;
    }
    self.diagnostics.scope = source_mod.root_file;
}
