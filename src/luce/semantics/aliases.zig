//! Transparent type-alias declarations.
//!
//! Collection gives every alias a qualified source name before any type is
//! resolved.  Resolution itself lives in `resolve.zig`, beside every other
//! written-type rule; this file owns only declaration validity and the eager
//! pass that proves even an unused alias is meaningful.  Nothing here emits a
//! layout or survives into HIR.

const std = @import("std");
const source_mod = @import("../source.zig");
const ast = @import("../parse.zig").ast;
const types = @import("../support/types.zig");
const context = @import("context.zig");
const naming = @import("naming.zig");
const resolve = @import("resolve.zig");

const Analyzer = @import("declarations.zig").Analyzer;
const Error = context.Error;
const Span = source_mod.Span;

/// Register every alias name before nominal types begin resolving fields and
/// signatures.  If another declaration precedes an alias in the same file,
/// the alias is the duplicate and is not registered.  If the alias precedes
/// it, the ordinary collector sees this table and diagnoses that later row.
pub fn collectDeclarations(self: *Analyzer) Error!void {
    for (self.modules, 0..) |module, module_index| {
        self.diagnostics.scope = module.file;
        for (module.tree.aliases) |*declaration| {
            if (naming.visibleBuiltin(self, module_index, declaration.name) != null) {
                try self.fail(
                    "luce.sema.reserved",
                    declaration.name_span,
                    "{s} is a builtin type; an alias takes a name of its own",
                    .{declaration.name},
                );
                continue;
            }
            if (context.isReserved(declaration.name)) {
                try self.fail("luce.sema.reserved", declaration.name_span, "{s} is a reserved name", .{declaration.name});
                continue;
            }
            if (declarationAbove(module.tree.*, declaration.name, declaration.name_span)) |first| {
                try self.fail("luce.sema.duplicate", declaration.name_span, "duplicate name {s}; the first is{s}", .{
                    declaration.name,
                    try naming.declaredAt(self, module.file, first),
                });
                continue;
            }

            var import_precedes = false;
            for (module.tree.imports) |imported| {
                // A member import's module binding is unbound; its
                // member bindings have their own collision gate.
                if (imported.members.len != 0) continue;
                if (!std.mem.eql(u8, imported.binding, declaration.name)) continue;
                if (imported.span.start < declaration.name_span.start) {
                    import_precedes = true;
                    try self.fail(
                        "luce.sema.duplicate",
                        declaration.name_span,
                        "alias {s} collides with an import of the same name",
                        .{declaration.name},
                    );
                } else {
                    try self.fail(
                        "luce.sema.duplicate",
                        imported.span,
                        "import {s} collides with a type alias of the same name",
                        .{declaration.name},
                    );
                }
                break;
            }
            // Keep the declaration that came first registered so later uses
            // do not cascade into "unknown type" after the one real
            // collision.  Where the import came first, it owns the name.
            if (import_precedes) continue;

            const qualified = try naming.qualify(self, module.prefix, declaration.name);
            if (try naming.firstDeclarationOf(self, qualified)) |where| {
                try self.fail("luce.sema.duplicate", declaration.name_span, "duplicate name {s}; the first is{s}", .{
                    declaration.name,
                    where,
                });
                continue;
            }
            const index: u32 = @intCast(self.alias_decls.items.len);
            try self.alias_names.put(self.temporary, qualified, index);
            try self.alias_decls.append(self.temporary, .{
                .declaration = declaration,
                .module = module_index,
            });
        }
    }
    self.diagnostics.scope = source_mod.root_file;
}

/// Resolve every alias, including aliases nobody uses.  This is both a cache
/// warm-up and the completeness gate for cycles and unknown targets.
pub fn settleDeclarations(self: *Analyzer) Error!void {
    for (0..self.alias_decls.items.len) |index| {
        const info = self.alias_decls.items[index];
        self.diagnostics.scope = self.modules[info.module].file;
        const target = (try resolve.resolveAlias(self, info.module, @intCast(index), info.declaration.target.span)) orelse continue;
        if (info.declaration.visibility == .private) continue;
        if (naming.privateMentioned(self, target)) |hidden| {
            try self.fail(
                "luce.sema.private",
                info.declaration.target.span,
                "alias {s} is public and names {s}, which is private in {s}; remove pub from {s} or mark {s} pub",
                .{
                    info.declaration.name,
                    hidden,
                    naming.markedIn(self, info.module),
                    info.declaration.name,
                    hidden,
                },
            );
        }
    }
    self.diagnostics.scope = source_mod.root_file;
}

/// The earliest non-alias declaration of `name` above `span` in this file.
/// Alias/alias order is already represented by the table as it is filled.
fn declarationAbove(tree: ast.Program, name: []const u8, span: Span) ?Span {
    var first: ?Span = null;
    inline for (.{ tree.constants, tree.structs, tree.interfaces, tree.enums, tree.unions, tree.functions }) |declarations| {
        for (declarations) |declaration| {
            if (declaration.name_span.start >= span.start) continue;
            if (!std.mem.eql(u8, declaration.name, name)) continue;
            if (first == null or declaration.name_span.start < first.?.start) first = declaration.name_span;
        }
    }
    return first;
}
