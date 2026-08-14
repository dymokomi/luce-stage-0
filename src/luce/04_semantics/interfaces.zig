//! Interface contracts and explicit struct conformance.
//!
//! Interfaces are nominal.  A struct opts in with `: Interface`, and this
//! pass checks the complete method table before any conversion can be made.
//! The runtime representation is deliberately not here: a conversion is
//! lowered later as a small struct run of existing bound function values.

const std = @import("std");
const source_mod = @import("../01_source.zig");
const ast = @import("../03_parse.zig").ast;
const types = @import("../support/types.zig");
const naming = @import("naming.zig");
const resolve = @import("resolve.zig");
const shapes = @import("shapes.zig");
const context = @import("context.zig");
const Error = context.Error;
const Type = types.Type;
const Span = source_mod.Span;
const Analyzer = @import("declarations.zig").Analyzer;

/// Register all interface names and their placeholder layouts.  This runs
/// after ordinary struct names are known (so real struct indexes stay first)
/// and before any field type is resolved (so either kind may mention the
/// other).
pub fn collectDeclarations(self: *Analyzer) Error!void {
    for (self.modules, 0..) |module, module_index| {
        self.diagnostics.scope = module.file;
        for (module.tree.interfaces) |*declaration| {
            if (context.isReserved(declaration.name)) {
                try self.fail("luce.sema.reserved", declaration.name_span, "{s} is a reserved name", .{declaration.name});
                continue;
            }
            if (types.builtinNamed(declaration.name) != null) {
                try self.fail(
                    "luce.sema.reserved",
                    declaration.name_span,
                    "{s} is a builtin type; an interface of your own takes a name of its own",
                    .{declaration.name},
                );
                continue;
            }
            const qualified = try naming.qualify(self, module.prefix, declaration.name);
            if (declaredAbove(module.tree.*, declaration.name, declaration.name_span)) |where| {
                try self.fail("luce.sema.duplicate", declaration.name_span, "duplicate name {s}; the first is{s}", .{
                    declaration.name,
                    try naming.declaredAt(self, module.file, where),
                });
                continue;
            }
            if (try naming.firstDeclarationOf(self, qualified)) |where| {
                try self.fail("luce.sema.duplicate", declaration.name_span, "duplicate name {s}; the first is{s}", .{
                    declaration.name,
                    where,
                });
                continue;
            }
            const layout: u32 = @intCast(self.structs.items.len);
            try self.structs.append(self.arena, .{
                .name = try self.arena.dupe(u8, qualified),
                .fields = &.{},
                .interface = true,
            });
            try self.interface_names.put(self.temporary, qualified, @intCast(self.interface_decls.items.len));
            try self.interface_decls.append(self.temporary, .{
                .declaration = declaration,
                .module = module_index,
                .layout = layout,
            });
        }
    }
    self.diagnostics.scope = source_mod.root_file;
}

/// Resolve every method signature and fill the hidden dispatch fields in the
/// interface layout.  The fields are never exposed to source; they are only
/// the existing runtime shape used by `struct_get` and `call_indirect`.
pub fn settleDeclarations(self: *Analyzer) Error!void {
    for (self.interface_decls.items, 0..) |*info, interface_index| {
        self.diagnostics.scope = self.modules[info.module].file;
        const declaration = info.declaration;
        if (declaration.methods.len == 0) {
            try self.fail("luce.sema.interface", declaration.span, "interface {s} has no methods", .{declaration.name});
            continue;
        }
        var methods: std.ArrayList(context.InterfaceMethodInfo) = .empty;
        defer methods.deinit(self.arena);
        var fields: std.ArrayList(types.StructField) = .empty;
        defer fields.deinit(self.arena);
        for (declaration.methods) |*method| {
            var duplicate = false;
            for (methods.items) |existing| {
                if (std.mem.eql(u8, existing.declaration.name, method.name)) {
                    try self.fail("luce.sema.duplicate", method.name_span, "interface {s} declares method {s} twice", .{ declaration.name, method.name });
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) continue;
            if (method.returns.len >= 2) {
                try self.fail(
                    "luce.sema.interface",
                    method.span,
                    "interface method {s}.{s} must answer one value; return shapes cannot be dispatched yet",
                    .{ declaration.name, method.name },
                );
                continue;
            }
            var parameter_types: std.ArrayList(Type) = .empty;
            defer parameter_types.deinit(self.arena);
            var parameter_modes: std.ArrayList(ast.ParameterMode) = .empty;
            defer parameter_modes.deinit(self.arena);
            var signature_parameters: std.ArrayList(types.Signature.Parameter) = .empty;
            defer signature_parameters.deinit(self.arena);
            var valid = true;
            for (method.parameters) |parameter| {
                if (parameter.default != null) {
                    try self.fail("luce.sema.interface", parameter.span, "interface methods cannot declare default arguments", .{});
                    valid = false;
                }
                const resolved = (try resolve.resolveType(self, info.module, parameter.type_name)) orelse {
                    valid = false;
                    continue;
                };
                try parameter_types.append(self.arena, resolved);
                try parameter_modes.append(self.arena, parameter.mode);
                try signature_parameters.append(self.arena, .{
                    .value_type = resolved,
                    .gives = parameter.mode == .give,
                });
            }
            var results: std.ArrayList(Type) = .empty;
            defer results.deinit(self.arena);
            for (method.returns) |written| {
                const resolved = (try resolve.resolveType(self, info.module, written)) orelse {
                    valid = false;
                    continue;
                };
                try results.append(self.arena, resolved);
            }
            if (!valid) continue;
            const return_type: Type = if (results.items.len == 0) .none else results.items[0];
            const signature = (try resolve.internSignature(self, .{
                .parameters = try signature_parameters.toOwnedSlice(self.arena),
                .result = return_type,
            })).function;
            const field: u32 = @intCast(fields.items.len);
            try fields.append(self.arena, .{
                .name = try self.arena.dupe(u8, method.name),
                .field_type = .{ .function = signature },
            });
            try methods.append(self.arena, .{
                .declaration = method,
                .parameter_types = try parameter_types.toOwnedSlice(self.arena),
                .parameter_modes = try parameter_modes.toOwnedSlice(self.arena),
                .results = try results.toOwnedSlice(self.arena),
                .return_type = return_type,
                .fallible = method.fallible,
                .field = field,
                .signature = signature,
            });
        }
        info.methods = try methods.toOwnedSlice(self.arena);
        self.structs.items[info.layout].fields = try fields.toOwnedSlice(self.arena);
        _ = interface_index;
    }
    self.diagnostics.scope = source_mod.root_file;
}

/// Check every `struct S: I` promise against the completed method table and
/// record the function indexes used by later interface conversions.
pub fn settleConformances(self: *Analyzer) Error!void {
    for (self.modules, 0..) |module, module_index| {
        self.diagnostics.scope = module.file;
        for (module.tree.structs) |*declaration| {
            const qualified = try naming.qualify(self, module.prefix, declaration.name);
            const strukt = self.struct_names.get(qualified) orelse continue;
            for (declaration.interfaces) |written| {
                const resolved = (try resolve.resolveType(self, module_index, written)) orelse continue;
                const interface_layout = switch (resolved) {
                    .strukt => |layout| layout,
                    else => {
                        try self.fail(
                            "luce.sema.interface",
                            written.span,
                            "{s} is not an interface; a struct's conformance list names interfaces only",
                            .{written.name},
                        );
                        continue;
                    },
                };
                const interface_index = self.interfaceForLayout(interface_layout) orelse {
                    try self.fail(
                        "luce.sema.interface",
                        written.span,
                        "{s} is not an interface; a struct's conformance list names interfaces only",
                        .{written.name},
                    );
                    continue;
                };
                if (self.conformance(strukt, interface_index) != null) {
                    try self.fail("luce.sema.duplicate", written.span, "{s} lists interface {s} twice", .{ declaration.name, written.name });
                    continue;
                }
                const contract = self.interface_decls.items[interface_index];
                var implementations: std.ArrayList(u32) = .empty;
                defer implementations.deinit(self.arena);
                var valid = true;
                for (contract.methods) |method| {
                    const qualified_method = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ self.structs.items[strukt].name, method.declaration.name });
                    const function = self.function_names.get(qualified_method) orelse {
                        try self.fail(
                            "luce.sema.interface",
                            method.declaration.name_span,
                            "struct {s} does not implement {s}.{s}",
                            .{ declaration.name, contract.declaration.name, method.declaration.name },
                        );
                        valid = false;
                        continue;
                    };
                    const implementation = self.functions.items[function];
                    if (implementation.receiver == .not) {
                        try self.fail(
                            "luce.sema.interface",
                            method.declaration.name_span,
                            "{s}.{s} is static; an interface method needs an instance receiver",
                            .{ declaration.name, method.declaration.name },
                        );
                        valid = false;
                        continue;
                    }
                    if (implementation.receiver == .writes) {
                        try self.fail(
                            "luce.sema.interface",
                            method.declaration.name_span,
                            "{s}.{s} writes self; interface methods are read-only so a value can be dispatched safely",
                            .{ declaration.name, method.declaration.name },
                        );
                        valid = false;
                        continue;
                    }
                    if (implementation.parameter_types.len != method.parameter_types.len + 1 or
                        implementation.results.len != method.results.len or
                        implementation.return_type.eql(method.return_type) == false or
                        // Effects are directional: a non-fallible witness
                        // is safe behind a fallible contract, while a
                        // fallible witness cannot satisfy a non-fallible
                        // call surface.
                        (implementation.fallible and !method.fallible))
                    {
                        try self.fail("luce.sema.interface", method.declaration.name_span, "{s}.{s} does not match interface method {s}.{s}", .{
                            declaration.name,
                            method.declaration.name,
                            contract.declaration.name,
                            method.declaration.name,
                        });
                        valid = false;
                        continue;
                    }
                    for (implementation.parameter_types[1..], method.parameter_types, implementation.parameter_modes[1..], method.parameter_modes) |actual, expected, actual_mode, expected_mode| {
                        if (!actual.eql(expected) or actual_mode != expected_mode) {
                            try self.fail("luce.sema.interface", method.declaration.name_span, "{s}.{s} does not match interface method {s}.{s}", .{
                                declaration.name,
                                method.declaration.name,
                                contract.declaration.name,
                                method.declaration.name,
                            });
                            valid = false;
                            break;
                        }
                    }
                    if (!valid) continue;
                    try implementations.append(self.arena, function);
                }
                if (!valid or implementations.items.len != contract.methods.len) continue;
                try self.conformances.append(self.temporary, .{
                    .interface = interface_index,
                    .strukt = strukt,
                    .methods = try implementations.toOwnedSlice(self.arena),
                });
            }
        }
    }
    self.diagnostics.scope = source_mod.root_file;
}

fn declaredAbove(tree: ast.Program, name: []const u8, span: Span) ?Span {
    for (tree.structs) |declaration| {
        if (declaration.name_span.start < span.start and std.mem.eql(u8, declaration.name, name)) return declaration.name_span;
    }
    for (tree.interfaces) |declaration| {
        if (declaration.name_span.start < span.start and std.mem.eql(u8, declaration.name, name)) return declaration.name_span;
    }
    for (tree.enums) |declaration| {
        if (declaration.name_span.start < span.start and std.mem.eql(u8, declaration.name, name)) return declaration.name_span;
    }
    for (tree.unions) |declaration| {
        if (declaration.name_span.start < span.start and std.mem.eql(u8, declaration.name, name)) return declaration.name_span;
    }
    return null;
}
