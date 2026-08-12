//! The function table: every declared function's signature, the two
//! kinds of function the compiler adds to it, and the layout a return
//! shape rides in.
//!
//! One collector serves every spelling — a file-scope function, a
//! method with its implied receiver, a `static func` with none, on a
//! struct, an enum or a union — because they differ only in what
//! `enclosing` is, and a single row shape is what keeps every later
//! lookup one lookup (docs/SELF.md D1-D2).  Two rows are not written
//! by source at all: the top-level function a lambda becomes
//! (docs/FUNCTIONS.md D2), and the closed instantiation of a
//! compiler-owned standard template (D6).  Neither resolves a written
//! signature, which is why neither is `collectFunction`, and both are
//! checked and lowered by the same loop as everything else.
//!
//! Which row the runtime starts is `entry.zig`'s, called from the end
//! of `collectFunctions` because it needs every signature settled — it
//! either selects the declared `main` or writes one for `luce test`.
//! `synthesizeShapes` is here because a return shape is a signature's
//! answer given the struct it travels in — settled after every
//! signature is collected and before any body is lowered, which is
//! load-bearing and argued where it is done.
//!
//! Free functions over `declarations.zig`'s `*Analyzer`; `pub` means
//! visible to stage 4's own files, nothing wider.

const std = @import("std");
const source_mod = @import("../01_source.zig");
const ast = @import("../03_parse.zig").ast;
const types = @import("../support/types.zig");
const helpers = @import("helpers.zig");

const defaults = @import("defaults.zig");
const entry = @import("entry.zig");
const naming = @import("naming.zig");
const resolve = @import("resolve.zig");
const shapes = @import("shapes.zig");

const context = @import("context.zig");
const Error = context.Error;
const Type = types.Type;
const FunctionDeclInfo = context.FunctionDeclInfo;
const TypedConstant = context.TypedConstant;
const isReserved = context.isReserved;
const Analyzer = @import("declarations.zig").Analyzer;

/// One closed instantiation of a compiler-owned standard-library body.
/// This is deliberately not a generic-function table: source cannot
/// add a row, and the only producer validates that its template came
/// from an embedded standard module.
pub const StandardSpecialization = struct {
    template: u32,
    parameters: []const Type,
    function: u32,
};

// -- pass one: function signatures, and the entry ---------------------

pub fn collectFunctions(self: *Analyzer) Error!void {
    for (self.modules, 0..) |module, module_index| {
        self.diagnostics.scope = module.file;
        for (module.tree.functions) |*declaration| {
            const qualified = try naming.qualify(self, module.prefix, declaration.name);
            try collectFunction(self, declaration, qualified, module_index, true, null);
        }
        for (module.tree.structs) |*declaration| {
            const owner = self.struct_names.get(
                try naming.qualify(self, module.prefix, declaration.name),
            );
            for (declaration.functions) |*function| {
                const member = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{
                    declaration.name,
                    function.name,
                });
                const qualified = try naming.qualify(self, module.prefix, member);
                try collectFunction(
                    self,
                    function,
                    qualified,
                    module_index,
                    false,
                    if (owner) |index| .{ .strukt = index } else null,
                );
            }
        }
        // An enum's functions are collected exactly as a struct's
        // are, and named the same way: `Method.name` is one lookup
        // whichever keyword declared `Method` (docs/ENUMS.md D7).
        for (module.tree.enums) |*declaration| {
            const owner = self.enum_names.get(
                try naming.qualify(self, module.prefix, declaration.name),
            );
            for (declaration.functions) |*function| {
                const member = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{
                    declaration.name,
                    function.name,
                });
                const qualified = try naming.qualify(self, module.prefix, member);
                try collectFunction(
                    self,
                    function,
                    qualified,
                    module_index,
                    false,
                    if (owner) |index| .{ .enumeration = self.enumType(index).enumeration } else null,
                );
            }
        }
        // And a union's, under the same rules (docs/UNION.md D17
        // and its SELF amendment): plain member functions are
        // methods with implied self, `static func` declares a
        // namespace function, and receiver writing is inferred.
        for (module.tree.unions) |*declaration| {
            const owner = self.variant_names.get(
                try naming.qualify(self, module.prefix, declaration.name),
            );
            for (declaration.functions) |*function| {
                const member = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{
                    declaration.name,
                    function.name,
                });
                const qualified = try naming.qualify(self, module.prefix, member);
                try collectFunction(
                    self,
                    function,
                    qualified,
                    module_index,
                    false,
                    if (owner) |index| .{ .variant = index } else null,
                );
            }
        }
    }
    self.diagnostics.scope = source_mod.root_file;
    try entry.settle(self);
}

fn collectFunction(
    self: *Analyzer,
    declaration: *const ast.FuncDecl,
    name: []const u8,
    module: usize,
    top_level: bool,
    /// The declaration this one sits inside, or null at file scope.
    /// It is what gives `self` its type, and what makes `self` at
    /// file scope a diagnostic rather than a crash.
    enclosing: ?context.Enclosing,
) Error!void {
    const in_root = self.modules[module].prefix.len == 0;
    if (isReserved(declaration.name)) {
        try self.fail("luce.sema.reserved", declaration.name_span, "{s} is a reserved name", .{declaration.name});
        return;
    }
    if (self.function_names.contains(name) or
        self.constant_names.contains(name) or
        (top_level and (self.struct_names.contains(name) or self.enum_names.contains(name))))
    {
        try self.fail("luce.sema.duplicate", declaration.name_span, "duplicate name {s}; the first is{s}", .{
            declaration.name,
            (try naming.firstDeclarationOf(self, name)) orelse "",
        });
        return;
    }

    // `main` is the entry only where a program's entry is the declared
    // one.  Under `luce test` the compiler writes the entry itself
    // (`entry.zig`), and a `main` the test file happens to declare is
    // an ordinary function nothing calls (docs/TESTING.md D1).
    const is_entry = self.options.entry == .declared and
        top_level and in_root and std.mem.eql(u8, declaration.name, "main");
    // The entry is selected by name and called by the runtime
    // through the ABI — there is no import edge for a marker to
    // gate, so `private` on it could only assert something false
    // (VISIBILITY.md D7).  `public` is inert-legal like any other
    // restated default.
    if (is_entry and declaration.visibility == .private) {
        try self.fail(
            "luce.sema.private",
            declaration.name_span,
            "main is the entry and cannot be private: the runtime starts it",
            .{},
        );
    }
    // Whether this declaration is part of the module's reachable
    // surface, for D4 below: a private function, or any member of
    // a private struct, publishes nothing.
    const surface = declaration.visibility != .private and
        (enclosing == null or switch (enclosing.?) {
            .strukt => |index| self.struct_decls.items[index].declaration.visibility != .private,
            .enumeration => |reference| self.enum_decls.items[reference.index].declaration.visibility != .private,
            .variant => |index| self.variant_decls.items[index].declaration.visibility != .private,
        });
    var parameter_types: std.ArrayList(Type) = .empty;
    defer parameter_types.deinit(self.arena);
    var parameter_modes: std.ArrayList(ast.ParameterMode) = .empty;
    defer parameter_modes.deinit(self.arena);
    var parameter_defaults: std.ArrayList(?TypedConstant) = .empty;
    defer parameter_defaults.deinit(self.arena);
    // The first parameter that declared a default, for D3's
    // sentence when a required one follows it.
    var first_defaulted: ?[]const u8 = null;
    // A plain function inside a struct or enum has one implicit
    // leading receiver.  `static` is the explicit exception.  The
    // source parameter list contains only what the caller writes;
    // MIR still keeps self as logical parameter zero so every
    // existing method lookup keeps one shape (docs/SELF.md D1-D2).
    var receiver: context.Receiver = .not;
    if (enclosing != null and !declaration.is_static) {
        receiver = .reads;
        try parameter_types.append(self.arena, enclosing.?.asType());
        try parameter_modes.append(self.arena, .borrow);
        try parameter_defaults.append(self.arena, null);
    }
    // The entry's written parameter is collected like every other
    // one: it is the command line, it has a type, and `entry.check`
    // is what says which type it has to be (S44).
    for (declaration.parameters) |parameter| {
        const resolved = (try resolve.resolveType(self, module, parameter.type_name)) orelse continue;
        // D4: a public surface names public types.  Only the
        // author of the marks can trip this, and the refusal names
        // both edits that would restore honesty (VISIBILITY.md §2).
        if (surface) {
            if (naming.privateMentioned(self, resolved)) |hidden| {
                try self.fail(
                    "luce.sema.private",
                    parameter.type_name.span,
                    "{s} is public and takes {s}, which is marked private in {s}; mark {s} private or remove the mark on {s}",
                    .{ declaration.name, hidden, naming.markedIn(self, module), declaration.name, hidden },
                );
                continue;
            }
        }
        if (parameter.mode == .give and !shapes.carriesObjects(self, resolved)) {
            try self.fail(
                "luce.sema.own",
                parameter.span,
                "give applies to containers and resources (list, map, array, builder, file, task) and structs that carry them, not values [OWNERSHIP.md S32]",
                .{},
            );
            continue;
        }
        // Defaults are trailing (docs/ARGS.md D3): a parameter
        // with one may be followed only by parameters with one.
        // It is what keeps a defaulted signature one signature
        // with a shorter legal spelling rather than an overload
        // set, and what stops a must-be-named parameter arriving
        // through a hole in the ordering rule.
        if (parameter.default == null) {
            if (first_defaulted) |earlier| {
                try self.fail(
                    "luce.sema.call",
                    parameter.span,
                    "{s} has a default, so {s} needs one too — the parameters with defaults come last",
                    .{ earlier, parameter.name },
                );
                continue;
            }
        } else if (first_defaulted == null) {
            first_defaulted = parameter.name;
        }
        var folded: ?TypedConstant = null;
        if (parameter.default) |written| {
            folded = (try defaults.foldDefault(self, module, declaration, parameter, resolved, written)) orelse continue;
        }
        try parameter_types.append(self.arena, resolved);
        try parameter_modes.append(self.arena, parameter.mode);
        try parameter_defaults.append(self.arena, folded);
    }
    var results: std.ArrayList(Type) = .empty;
    defer results.deinit(self.arena);
    for (declaration.returns) |written| {
        const resolved = (try resolve.resolveType(self, module, written)) orelse continue;
        if (surface) {
            if (naming.privateMentioned(self, resolved)) |hidden| {
                try self.fail(
                    "luce.sema.private",
                    written.span,
                    "{s} is public and answers {s}, which is marked private in {s}; mark {s} private or remove the mark on {s}",
                    .{ declaration.name, hidden, naming.markedIn(self, module), declaration.name, hidden },
                );
                continue;
            }
        }
        try results.append(self.arena, resolved);
    }
    // SELF retired the old receiver-at-result-zero channel.  A
    // writing receiver now travels through MIR's inout call edge;
    // the ordinary answer is exactly what the declaration says.
    var channel: std.ArrayList(Type) = .empty;
    defer channel.deinit(self.arena);
    try channel.appendSlice(self.arena, results.items);
    // The synthesized layout a return shape rides in is settled
    // after every signature is collected — `synthesizeShapes`
    // below — because the layout table must not grow while a body
    // is being lowered against a snapshot of it.
    const return_type: Type = if (channel.items.len == 1) channel.items[0] else .none;

    const index: u32 = @intCast(self.functions.items.len);
    try self.function_names.put(self.temporary, name, index);
    try self.functions.append(self.arena, .{
        .declaration = declaration,
        .name = try self.arena.dupe(u8, name),
        .module = module,
        .parameter_types = try parameter_types.toOwnedSlice(self.arena),
        .parameter_modes = try parameter_modes.toOwnedSlice(self.arena),
        .parameter_defaults = try parameter_defaults.toOwnedSlice(self.arena),
        .receiver = receiver,
        .enclosing = enclosing,
        .results = try results.toOwnedSlice(self.arena),
        .channel = try channel.toOwnedSlice(self.arena),
        .return_type = return_type,
        .fallible = declaration.fallible,
        .is_entry = is_entry,
    });
}

/// Register a top-level function stage 4 synthesized, and answer its
/// index — a lambda (docs/FUNCTIONS.md D2), or a union member
/// constructor landing where a function type is wanted
/// (docs/BINDING.md D11).
///
/// Not `collectFunction`: there is no written signature to resolve
/// — the caller hands over the settled one — no name to check for
/// collisions, because nothing in the program's own namespace can
/// spell it, and no visibility to read, because nothing can name this
/// function but the value that was just made of it.  What it shares
/// with a declared function is everything after that: it is lowered by
/// the same loop, checked by the same walk, and called through the
/// same instruction.
///
/// **One registration per reference site**, for both callers: two
/// mentions of one lambda or one constructor are two functions with
/// one name, which is what `string(f)` answers and all it promises.
pub fn registerLambda(
    self: *Analyzer,
    declaration: *const ast.FuncDecl,
    module: usize,
    signature: types.Signature,
    /// Every local in scope where the lambda was written.  Its name
    /// drives capture diagnostics and its span preserves the normal
    /// no-shadowing diagnostic after the body is lifted.
    enclosing_locals: []const context.EnclosingLocal,
) Error!u32 {
    const parameter_types = try self.arena.alloc(Type, signature.parameters.len);
    const parameter_modes = try self.arena.alloc(ast.ParameterMode, signature.parameters.len);
    const parameter_defaults = try self.arena.alloc(?TypedConstant, signature.parameters.len);
    for (signature.parameters, parameter_types, parameter_modes, parameter_defaults) |parameter, *held, *mode, *default| {
        held.* = parameter.value_type;
        mode.* = if (parameter.gives) .give else .borrow;
        default.* = null;
    }
    const results = try self.arena.alloc(Type, if (signature.result == .none) 0 else 1);
    if (results.len == 1) results[0] = signature.result;
    const index: u32 = @intCast(self.functions.items.len);
    try self.functions.append(self.arena, .{
        .declaration = declaration,
        .name = declaration.name,
        .module = module,
        .parameter_types = parameter_types,
        .parameter_modes = parameter_modes,
        .parameter_defaults = parameter_defaults,
        .results = results,
        .channel = results,
        .return_type = signature.result,
        .fallible = false,
        .is_entry = false,
        .enclosing_locals = enclosing_locals,
    });
    return index;
}

/// Instantiate one closed, compiler-owned standard-library
/// template at concrete monomorphic parameter types.
///
/// Luce exposes no user generics.  `std.lists.sort_by` nevertheless
/// has to serve `list(T)` for the receiver's actual T, so its routed
/// method takes the same narrow route lambdas take: the ordinary
/// Luce body is collected once, this method gives a clone concrete
/// parameter types, and the normal lowering loop checks and lowers
/// it like every other function.  No MIR instruction or runtime
/// callback is added (FUNCTIONS.md D2, D6).
pub fn registerStandardSpecialization(
    self: *Analyzer,
    template_name: []const u8,
    specialized_name: []const u8,
    parameter_types: []const Type,
) Error!?u32 {
    const template_index = self.function_names.get(template_name) orelse return null;
    const template = self.functions.items[template_index];
    const source = self.diagnostics.sources.at(self.modules[template.module].file) orelse return null;
    if (source.kind != .standard or
        template.declaration.visibility != .private or
        template.parameter_types.len != parameter_types.len or
        template.return_type != .none or
        template.fallible or
        template.is_entry or
        template.receiver != .not or
        template.enclosing != null)
    {
        return null;
    }
    for (template.parameter_modes) |mode| {
        if (mode != .borrow) return null;
    }
    for (template.parameter_defaults) |default| {
        if (default != null) return null;
    }

    // Cache on types, not their rendered names.  Names are for
    // traces; `Type.eql` is the language's identity relation.
    for (self.standard_specializations.items) |existing| {
        if (existing.template != template_index or existing.parameters.len != parameter_types.len) continue;
        var same = true;
        for (existing.parameters, parameter_types) |held, wanted| {
            if (!held.eql(wanted)) {
                same = false;
                break;
            }
        }
        if (same) return existing.function;
    }

    const declaration = try self.arena.create(ast.FuncDecl);
    declaration.* = template.declaration.*;
    declaration.name = try self.arena.dupe(u8, specialized_name);
    // The import and routing gate visibility at the call site.  The
    // clone itself must be callable from that site even when its
    // checked source template is private (the object-owning arm).
    declaration.visibility = .public;

    const index: u32 = @intCast(self.functions.items.len);
    try self.functions.append(self.arena, .{
        .declaration = declaration,
        .name = declaration.name,
        .module = template.module,
        .parameter_types = try self.arena.dupe(Type, parameter_types),
        .parameter_modes = template.parameter_modes,
        .parameter_defaults = template.parameter_defaults,
        .receiver = template.receiver,
        .enclosing = template.enclosing,
        .results = template.results,
        .channel = template.channel,
        .return_type = template.return_type,
        .fallible = template.fallible,
        .is_entry = false,
    });
    try self.standard_specializations.append(self.arena, .{
        .template = template_index,
        .parameters = self.functions.items[index].parameter_types,
        .function = index,
    });
    return index;
}

// -- pass one and a half: the layouts a return shape rides in -------
//
// `(double, double)` **is** a two-field product value, so it is
// lowered as one: `return low, high` is a `struct_make` and
// `let low, high = …` is two `struct_get`s.  Nothing below stage 4
// grows a case for multiple results — no MIR instruction, no wire
// change, no ABI field — and the oracle needs no edit at all,
// which is why it is the arm that proves this resolved right
// (docs/RETURNS.md §4).
//
// The alternative was multiple result registers on `call` and
// `ret`.  What kills it is not its size: **LLVM has no multiple
// returns either**, so it would build in stage 6 a shape stage 8
// has to collapse back into an aggregate.

/// Give every function that answers a return shape the synthesized
/// layout its values travel in.
///
/// **Between `collectFunctions` and any lowering, and that is
/// load-bearing.**  `Lowering.structs` is a snapshot slice taken
/// per function and documented as settled before lowering runs, so
/// appending a layout while a body is in flight would reallocate
/// the list and leave that slice stale and short.  Every shape a
/// program can return is known from the signatures alone, so there
/// is no reason to.
pub fn synthesizeShapes(self: *Analyzer) Error!void {
    for (self.functions.items) |*info| {
        if (info.channel.len < 2) continue;
        self.diagnostics.scope = self.modules[info.module].file;
        info.return_type = (try internShape(self, info)) orelse continue;
    }
    self.diagnostics.scope = source_mod.root_file;
}

/// The layout for one return shape, interned by the name the shape
/// is written with.
///
/// **The name is the shape as written** — `(double, double)` — and it
/// is unforgeable from source: a struct name is an identifier,
/// qualified with a module prefix, so nothing a program can declare
/// collides with a name containing `(`.  It reads correctly in
/// `luce ir` and it reads correctly if it ever reaches a
/// diagnostic through `types.typeName`.  Two functions with the
/// same shape intern to one layout, as heap type shapes already do.
fn internShape(self: *Analyzer, info: *const FunctionDeclInfo) Error!?Type {
    const name = try writtenResults(self, info);
    for (self.structs.items, 0..) |layout, index| {
        if (std.mem.eql(u8, layout.name, name)) return .{ .strukt = @intCast(index) };
    }

    var fields: std.ArrayList(types.StructField) = .empty;
    defer fields.deinit(self.arena);
    var values: u32 = 0;
    var carries = false;
    for (info.channel, 0..) |result, position| {
        try fields.append(self.arena, .{
            .name = try std.fmt.allocPrint(self.arena, "field{d}", .{position}),
            .field_type = result,
        });
        values +|= shapes.valueCount(self, result);
        if (shapes.carriesObjects(self, result)) carries = true;
    }
    // The same bound every other width in the language takes, and
    // for the same reason: `zeroOf` emits one instruction per
    // counted leaf.  A signature that approaches it has other
    // problems, but the bound must be the same bound and not a
    // second number.
    if (values > helpers.max_struct_values) {
        try self.fail(
            "luce.sema.return",
            info.declaration.returnsSpan() orelse info.declaration.span,
            "{s} answers {d} values in all, past the limit of {d}",
            .{ info.declaration.name, values, helpers.max_struct_values },
        );
        return null;
    }

    const index: u32 = @intCast(self.structs.items.len);
    try self.structs.append(self.arena, .{
        .name = name,
        .fields = try fields.toOwnedSlice(self.arena),
    });
    // `carriesObjects` and `valueCount` index this table directly,
    // and the ownership walk asks both of a returned shape — so a
    // layout without a shape entry is an out-of-bounds read the
    // first time `lowerReturn` asks whether it carries objects.
    try self.struct_shapes.append(self.temporary, .{ .carries = carries, .values = values });
    return .{ .strukt = index };
}

/// What a function answers, as a reader wrote it: `long` for one
/// value, `(long, long)` for a shape, `None` for nothing.  Also the
/// synthesized layout's name, so the two can never disagree.
pub fn writtenResults(self: *Analyzer, info: *const FunctionDeclInfo) Error![]const u8 {
    if (info.channel.len == 0) return "None";
    if (info.channel.len == 1) return self.typeName(info.channel[0]);
    var written: std.ArrayList(u8) = .empty;
    errdefer written.deinit(self.arena);
    try written.append(self.arena, '(');
    for (info.channel, 0..) |result, position| {
        if (position != 0) try written.appendSlice(self.arena, ", ");
        try written.appendSlice(self.arena, try self.typeName(result));
    }
    try written.append(self.arena, ')');
    return written.toOwnedSlice(self.arena);
}

/// The layout behind a return shape, or null for every other type
/// — including every struct a program declared.
///
/// Told apart by the name, which is the shape as written and
/// therefore **unforgeable from source**: a struct name is an
/// identifier, qualified with a module prefix, so nothing a
/// program can declare begins with `(`.  That is what lets a
/// return shape be a struct underneath and still not be a type a
/// program can name (docs/RETURNS.md).
pub fn returnShapeOf(self: *const Analyzer, of: Type) ?types.StructLayout {
    if (of != .strukt) return null;
    const layout = self.structs.items[of.strukt];
    if (layout.name.len == 0 or layout.name[0] != '(') return null;
    return layout;
}
