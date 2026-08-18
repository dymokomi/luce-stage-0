//! What a declaration is called, where it was written, and who may
//! see it.
//!
//! Three questions that are one vocabulary.  *What it is called* —
//! the module-qualified key every declaration table is keyed by, and
//! the key a written cross-module reference resolves to.  *Where it
//! was written* — the clause a duplicate diagnostic ends with, and
//! the search over the five tables that finds the first declaration
//! of a name.  *Who may see it* — the visibility rule entire
//! (docs/VISIBILITY.md D1), the module a refusal names as the mark's
//! home, and the transitive "does this type mention a private one"
//! that every public surface is checked against.
//!
//! They share a file because they share a subject: a name is
//! qualified by the module that declared it, and that module is what
//! decides whether another one may write it down.  The visibility
//! *checks* are not here — each stands at the declaration it guards,
//! in `layouts.zig` and `signatures.zig` — because what a refusal
//! says depends on what was being declared; what is here is the
//! predicate all of them ask.
//!
//! Free functions over `declarations.zig`'s `*Analyzer`; `pub` means
//! visible to stage 4's own files, nothing wider.

const std = @import("std");
const source_mod = @import("../source.zig");
const ast = @import("../parse.zig").ast;
const types = @import("../support/types.zig");

const context = @import("context.zig");
const Error = context.Error;
const Span = source_mod.Span;
const Type = types.Type;
const Analyzer = @import("declarations.zig").Analyzer;

/// A module-qualified declaration name: "geo" + "Point" ->
/// "geo.Point"; the root module ("") qualifies to the name itself.
pub fn qualify(self: *Analyzer, prefix: []const u8, name: []const u8) Error![]const u8 {
    if (prefix.len == 0) return name;
    return std.fmt.allocPrint(self.arena, "{s}.{s}", .{ prefix, name });
}

/// The name a refusal calls `module` — the namespace a program
/// writes in front of the dot.  Only ever read for a declaring
/// module in a cross-module refusal, and the root module cannot be
/// imported, so the answer is never empty where it is used.
pub fn moduleName(self: *const Analyzer, module: usize) []const u8 {
    return self.modules[module].binding;
}

/// The declared key a written cross-module reference resolves to:
/// the imported module's own qualification prefix, plus the member
/// path.  `written` is "geo.Point" or "geo.Text.width", and the
/// head should already be known to bind an import of `module`
/// (`importsModule`); anything else answers the written text
/// unchanged.  For a module of the program's own root the key *is*
/// the written text; a package module's key carries its root
/// (docs/PACKAGES.md D7), which is how the same written text in
/// two packages names two different declarations.  Arena-allocated
/// when it differs from `written`.
pub fn importedName(self: *Analyzer, module: usize, written: []const u8) Error![]const u8 {
    const dot = std.mem.indexOfScalar(u8, written, '.') orelse return written;
    const head = written[0..dot];
    const prefix = importedPrefix(self, module, head) orelse return written;
    if (std.mem.eql(u8, prefix, head)) return written;
    return std.fmt.allocPrint(self.arena, "{s}.{s}", .{ prefix, written[dot + 1 ..] });
}

/// The qualification prefix of whatever `module` imports bound as
/// `head`, or null when nothing is.  Resolution's claims are the
/// memory read back here: the import's spelled name, asked in the
/// importing file's own namespace, names the file, and the file
/// names its module — which is what tells two same-named package
/// internals apart when two modules each bind a `util`.
///
/// A member import binds its members and nothing else, so it never
/// answers as a namespace here.
fn importedPrefix(self: *const Analyzer, module: usize, head: []const u8) ?[]const u8 {
    for (self.modules[module].tree.imports) |imported| {
        if (imported.members.len != 0) continue;
        if (!std.mem.eql(u8, imported.binding, head)) continue;
        return resolvedPrefix(self, module, imported);
    }
    return null;
}

/// The qualification prefix of `imported`, resolved from `module` —
/// the one registry walk `importedPrefix` and `memberKey` share.
fn resolvedPrefix(self: *const Analyzer, module: usize, imported: ast.Import) []const u8 {
    // The library keys by its binding wherever it is imported from,
    // so the import's own last segment is already the prefix.
    if (imported.origin == .standard) return imported.binding;
    const namespace = self.diagnostics.sources.rootOf(self.modules[module].file);
    const file = self.diagnostics.sources.claim(namespace, imported.name) orelse return imported.binding;
    for (self.modules) |candidate| {
        if (candidate.file == file) return candidate.prefix;
    }
    return imported.binding;
}

/// The declared key a member-import binding resolves to, or null when
/// `module` binds no member as `head`: after `from geo import Point`,
/// the bare "Point" answers "geo.Point" — through the importing
/// file's own claim registry, so a package member keys under its
/// package root exactly as the qualified spelling would.
pub fn memberKey(self: *Analyzer, module: usize, head: []const u8) Error!?[]const u8 {
    for (self.modules[module].tree.imports) |imported| {
        for (imported.members) |member| {
            if (!std.mem.eql(u8, member.binding, head)) continue;
            return try qualify(self, resolvedPrefix(self, module, imported), member.name);
        }
    }
    return null;
}

/// The visibility rule entire (docs/VISIBILITY.md D1): a
/// declaration of `owner` marked `visibility` is reachable from
/// `from` unless it says private and `from` is another file.
/// Within one file the bit is never consulted.
pub fn reachable(owner: usize, visibility: ast.Visibility, from: usize) bool {
    return visibility != .private or owner == from;
}

/// Where a D4 sentence says the mark lives: the module's name, or
/// "this file" for the root — which nothing can import, but whose
/// own surface checks still run and still land on the marker's
/// author.
pub fn markedIn(self: *const Analyzer, module: usize) []const u8 {
    const binding = self.modules[module].binding;
    return if (binding.len == 0) "this file" else binding;
}

/// The name of the private declaration `of` mentions, if any —
/// transitively through containers and optionals, because a
/// `list[Inner]` in a public signature publishes Inner exactly as a
/// bare `Inner` would (docs/VISIBILITY.md §2).  It does not look
/// *into* a struct's fields: mentioning a public struct that
/// privately holds hidden types publishes nothing, and those fields
/// were checked at their own declaration.
///
/// The **name** rather than an index, because two kinds of
/// declaration can be the hidden one now — a struct and an enum —
/// and every caller wants the same one thing to put in a sentence.
pub fn privateMentioned(self: *const Analyzer, of: Type) ?[]const u8 {
    return switch (of) {
        .strukt => |index| if (self.interfaceForLayout(index)) |interface_index|
            if (self.interface_decls.items[interface_index].declaration.visibility == .private)
                self.interface_decls.items[interface_index].declaration.name
            else
                null
        else if (self.struct_decls.items[index].declaration.visibility == .private)
            self.struct_decls.items[index].declaration.name
        else
            null,
        .enumeration => |reference| if (self.enum_decls.items[reference.index].declaration.visibility == .private)
            self.enum_decls.items[reference.index].declaration.name
        else
            null,
        .variant => |index| if (self.variant_decls.items[index].declaration.visibility == .private)
            self.variant_decls.items[index].declaration.name
        else
            null,
        .heap => |index| switch (self.heap_types.items[index]) {
            .class => |layout| if (self.struct_decls.items[layout].declaration.visibility == .private)
                self.struct_decls.items[layout].declaration.name
            else
                null,
            .list => |element| privateMentioned(self, element),
            // A map key is an explicit integer width, `str`, or an **enum**, and an enum
            // can be private (docs/ENUMS.md, As built 2026-08-12), so
            // the key is walked exactly as the value is: a public
            // `map[Key, i64]` publishes `Key` no less than a public
            // `list[Key]` does.
            .map => |pair| privateMentioned(self, pair.key) orelse
                privateMentioned(self, pair.value),
            .array => |shape| privateMentioned(self, shape.element),
            .builder, .handle => null,
            .task => |work| privateMentioned(self, work.result),
        },
        // A function type publishes every type in its signature.
        // `func(Inner) -> i64` on a public declaration is no less
        // an exposure of private `Inner` than `list[Inner]` is;
        // walking only the outer tag left a quiet second door
        // through VISIBILITY.md D4.
        .function => |index| blk: {
            const signature = self.signatures.items[index];
            for (signature.parameters) |parameter| {
                if (privateMentioned(self, parameter.value_type)) |hidden| break :blk hidden;
            }
            break :blk privateMentioned(self, signature.result);
        },
        .optional => |payload| privateMentioned(self, payload.asType()),
        else => null,
    };
}

/// True when `module` imports something *bound* as `name` — the
/// namespace a call site writes, which is an import's last segment
/// unless an `as` chose otherwise.  A member import binds only its
/// members, so it never makes its module answer as a namespace.
pub fn importsModule(self: *const Analyzer, module: usize, name: []const u8) bool {
    for (self.modules[module].tree.imports) |imported| {
        if (imported.members.len != 0) continue;
        if (std.mem.eql(u8, imported.binding, name)) return true;
    }
    return false;
}

/// True only for the embedded-library spelling `import std.NAME`.
/// A sibling `import NAME` binds the same namespace at use sites,
/// but cannot satisfy a gate that promises compiler-owned source.
pub fn importsStandardModule(self: *const Analyzer, module: usize, name: []const u8) bool {
    for (self.modules[module].tree.imports) |imported| {
        if (imported.origin == .standard and std.mem.eql(u8, imported.name, name)) return true;
    }
    return false;
}

/// True when `module` is embedded standard-library source — the
/// visibility gate every compiler-owned spelling shares: `Builtin.NAME`
/// calls and the standard-only `handle` currency resolve here and
/// nowhere else, so nothing of the host bridge enters a program's
/// vocabulary.
pub fn isStandardSource(self: *const Analyzer, module: usize) bool {
    const source = self.diagnostics.sources.at(self.modules[module].file) orelse return false;
    return source.kind == .standard;
}

/// The builtin a name spells *in this module's vocabulary*: the
/// public table everywhere, plus the standard-only currency inside
/// embedded standard source.  Type resolution and the declaration
/// shadowing checks ask this instead of `types.builtinNamed`, so a
/// user program may own a spelling the library keeps to itself.
pub fn visibleBuiltin(self: *const Analyzer, module: usize, name: []const u8) ?types.Builtin {
    const builtin = types.builtinNamed(name) orelse return null;
    if (types.isStandardOnly(builtin) and !isStandardSource(self, module)) return null;
    return builtin;
}

/// True when `module` is the embedded `std.NAME` itself, rather
/// than a sibling file that happens to be named NAME.
pub fn isStandardModule(self: *const Analyzer, module: usize, name: []const u8) bool {
    if (!std.mem.eql(u8, self.modules[module].binding, name)) return false;
    const source = self.diagnostics.sources.at(self.modules[module].file) orelse return false;
    return source.kind == .standard;
}

/// The import that would make `name` reachable, spelled the way
/// the author has to write it: `std.math` for the library, `geo`
/// for a file beside the program, `geo.shapes` for one in a
/// project subfolder — with the alias appended when the module is
/// bound under a name that is not its own last segment, because
/// any other spelling of the import would bind something else.
///
/// A module already in the program answers for itself — a
/// sibling `math.luc` that another file imports is reached with
/// `import math`, even though `std.math` exists too.  Only when
/// nothing is loaded under the name does the library get to
/// claim it.
pub fn importSpelling(self: *Analyzer, name: []const u8) Error![]const u8 {
    for (self.modules) |module| {
        if (!std.mem.eql(u8, module.binding, name)) continue;
        const spelled = self.diagnostics.sources.at(module.file).?.name;
        const is_tail = spelled.len >= name.len and tail: {
            const at = spelled.len - name.len;
            break :tail std.mem.eql(u8, spelled[at..], name) and
                (at == 0 or spelled[at - 1] == '.');
        };
        if (is_tail) return spelled;
        return std.fmt.allocPrint(self.arena, "{s} as {s}", .{ spelled, name });
    }
    if (!source_mod.isStandard(name)) return name;
    return qualify(self, source_mod.standard_namespace, name);
}

/// Which module declared a qualified key and how visible it is,
/// whichever table holds it — the member-import gate's one lookup.
const DeclarationHome = struct { module: usize, visibility: ast.Visibility };

fn declarationHome(self: *const Analyzer, qualified: []const u8) ?DeclarationHome {
    if (self.alias_names.get(qualified)) |index| {
        const info = self.alias_decls.items[index];
        return .{ .module = info.module, .visibility = info.declaration.visibility };
    }
    if (self.function_names.get(qualified)) |index| {
        const info = self.functions.items[index];
        return .{ .module = info.module, .visibility = info.declaration.visibility };
    }
    if (self.struct_names.get(qualified)) |index| {
        const info = self.struct_decls.items[index];
        return .{ .module = info.module, .visibility = info.declaration.visibility };
    }
    if (self.interface_names.get(qualified)) |index| {
        const info = self.interface_decls.items[index];
        return .{ .module = info.module, .visibility = info.declaration.visibility };
    }
    if (self.enum_names.get(qualified)) |index| {
        const info = self.enum_decls.items[index];
        return .{ .module = info.module, .visibility = info.declaration.visibility };
    }
    if (self.variant_names.get(qualified)) |index| {
        const info = self.variant_decls.items[index];
        return .{ .module = info.module, .visibility = info.declaration.visibility };
    }
    if (self.constant_names.get(qualified)) |index| {
        const info = self.constant_infos.items[index];
        return .{ .module = info.module, .visibility = info.declaration.visibility };
    }
    return null;
}

/// The member imports' own gate, run once every declaration table is
/// filled: each named member must exist in its module and be
/// reachable from the importing one, and each binding must be a
/// fresh word there — not reserved, not a builtin, not a local
/// declaration, not an import's namespace, not another member.
/// Settling all of this at the import line is what lets every
/// bare-name resolution skip per-use privacy checks.
pub fn validateMemberImports(self: *Analyzer) Error!void {
    for (self.modules, 0..) |module, module_index| {
        if (module.tree.imports.len == 0) continue;
        self.diagnostics.scope = module.file;
        var bound: std.StringHashMapUnmanaged(void) = .empty;
        defer bound.deinit(self.temporary);
        for (module.tree.imports) |imported| {
            for (imported.members) |member| {
                const key = try qualify(self, resolvedPrefix(self, module_index, imported), member.name);
                const home = declarationHome(self, key) orelse {
                    try self.fail(
                        "luce.sema.import",
                        member.span,
                        "{s} has no declaration named {s}",
                        .{ imported.name, member.name },
                    );
                    continue;
                };
                if (!reachable(home.module, home.visibility, module_index)) {
                    try self.fail("luce.sema.private", member.span, "{s} is private to {s}", .{
                        member.name,
                        moduleName(self, home.module),
                    });
                    continue;
                }
                if (context.isReserved(member.binding)) {
                    try self.fail("luce.sema.reserved", member.span, "{s} is a reserved name", .{member.binding});
                    continue;
                }
                if (visibleBuiltin(self, module_index, member.binding) != null) {
                    try self.fail(
                        "luce.sema.reserved",
                        member.span,
                        "{s} is a builtin type; bind the member under another name with as",
                        .{member.binding},
                    );
                    continue;
                }
                const local = try qualify(self, module.prefix, member.binding);
                if (try firstDeclarationOf(self, local)) |where| {
                    try self.fail("luce.sema.duplicate", member.span, "duplicate name {s}; the first is{s}", .{
                        member.binding,
                        where,
                    });
                    continue;
                }
                if (importsModule(self, module_index, member.binding)) {
                    try self.fail(
                        "luce.sema.duplicate",
                        member.span,
                        "{s} is already an import's namespace in this file",
                        .{member.binding},
                    );
                    continue;
                }
                const entry = try bound.getOrPut(self.temporary, member.binding);
                if (entry.found_existing) {
                    try self.fail(
                        "luce.sema.duplicate",
                        member.span,
                        "duplicate name {s}; this file's imports already bind it",
                        .{member.binding},
                    );
                }
            }
        }
    }
}

/// True when any declaration table holds this qualified key — the
/// one-bit form of `firstDeclarationOf`, for callers that only need
/// to know whether a name means something before trying another
/// resolution.
pub fn declares(self: *const Analyzer, qualified: []const u8) bool {
    return self.alias_names.contains(qualified) or
        self.function_names.contains(qualified) or
        self.struct_names.contains(qualified) or
        self.interface_names.contains(qualified) or
        self.enum_names.contains(qualified) or
        self.variant_names.contains(qualified) or
        self.constant_names.contains(qualified);
}

/// Where a fully-qualified name is already declared, whichever of
/// the three tables holds it — or null when none does.
pub fn firstDeclarationOf(self: *Analyzer, qualified: []const u8) Error!?[]const u8 {
    if (self.alias_names.get(qualified)) |index| {
        const info = self.alias_decls.items[index];
        return try declaredAt(self, self.modules[info.module].file, info.declaration.name_span);
    }
    if (self.function_names.get(qualified)) |index| {
        const info = self.functions.items[index];
        return try declaredAt(self, self.modules[info.module].file, info.declaration.name_span);
    }
    if (self.struct_names.get(qualified)) |index| {
        const info = self.struct_decls.items[index];
        return try declaredAt(self, self.modules[info.module].file, info.declaration.name_span);
    }
    if (self.interface_names.get(qualified)) |index| {
        const info = self.interface_decls.items[index];
        return try declaredAt(self, self.modules[info.module].file, info.declaration.name_span);
    }
    if (self.enum_names.get(qualified)) |index| {
        const info = self.enum_decls.items[index];
        return try declaredAt(self, self.modules[info.module].file, info.declaration.name_span);
    }
    if (self.variant_names.get(qualified)) |index| {
        const info = self.variant_decls.items[index];
        return try declaredAt(self, self.modules[info.module].file, info.declaration.name_span);
    }
    if (self.constant_names.get(qualified)) |index| {
        const info = self.constant_infos.items[index];
        return try declaredAt(self, self.modules[info.module].file, info.declaration.name_span);
    }
    return null;
}

/// Where a name was already declared, for a message about the
/// second one: " on line 7", or " in geo.luc on line 7" when the
/// first is in another file.
///
/// Where the other one is, is the single most useful thing a
/// duplicate diagnostic can carry, and none of the four spellings
/// of it carried anything at all.
pub fn declaredAt(self: *Analyzer, file: source_mod.FileId, span: Span) Error![]const u8 {
    const at = self.diagnostics.sources.place(file, span.start);
    if (file == self.diagnostics.scope) {
        return std.fmt.allocPrint(self.arena, " on line {d}", .{at.line});
    }
    return std.fmt.allocPrint(self.arena, " in {s} on line {d}", .{
        self.diagnostics.sources.pathOf(file),
        at.line,
    });
}
