//! Stages 1-3 for a whole program: loading, lexing, and parsing the
//! root source and every module it reaches.
//!
//! A file is a module and `import geo` loads `geo.luc` through the
//! host's `Loader`.  The walk is breadth-first, each module loads and
//! parses exactly once, and a cycle is simply a name already in the
//! list.  Without a loader, imports are compile errors.
//!
//! `compile.zig` is the driver that calls this; the split exists only
//! so the driver can read as the stage sequence rather than as a graph
//! traversal.

const std = @import("std");
const parse_mod = @import("../03_parse.zig");
const semantics = @import("../04_semantics.zig");
const diagnostics_mod = @import("../support/diagnostics.zig");

const Allocator = std.mem.Allocator;
const Diagnostics = diagnostics_mod.Diagnostics;
const ModuleTree = semantics.ModuleTree;

pub const Error = error{OutOfMemory};

/// Loads the source of `import name` for project compiles.  Returns
/// null when the module cannot be found; the compiler reports it.
/// Loaded bytes may be allocated from `arena` and must stay valid for
/// the compile.
pub const Loader = struct {
    context: *anyopaque,
    loadFn: *const fn (
        context: *anyopaque,
        arena: Allocator,
        name: []const u8,
    ) error{OutOfMemory}!?[]const u8,
};

/// One source file may import at most this many modules transitively;
/// a backstop against runaway import graphs, not a design limit.
const max_modules = 64;

// ---------------------------------------------------------------------------
// The standard library
// ---------------------------------------------------------------------------
//
// Std modules are Luce source embedded in the compiler — the way Zig
// ships lib/std with its compiler, minus the install path: wherever
// the compiler is (the luce CLI, loom, a test), `import math` works.
// They resolve before any loader runs, so std names are reserved and
// a sibling file of the same name is never consulted.  Being ordinary
// modules, they obey every language rule, including the host gate:
// `import files` inside a host-less evaluator is a compile error.

const std_modules = [_]struct { name: []const u8, source: []const u8 }{
    .{ .name = "math", .source = @embedFile("../std/math.luc") },
    .{ .name = "files", .source = @embedFile("../std/files.luc") },
    .{ .name = "strings", .source = @embedFile("../std/strings.luc") },
};

fn stdModule(name: []const u8) ?[]const u8 {
    for (std_modules) |module| {
        if (std.mem.eql(u8, module.name, name)) return module.source;
    }
    return null;
}

/// Load, lex, and parse the root source and everything it imports.
///
/// Trees are allocated from `scaffold` (the AST arena, freed once
/// analysis is done); the returned slice itself belongs to `gpa` and
/// the caller frees it.  Returns null when parsing produced errors —
/// they are in `diagnostics`, and there is nothing to analyse.
pub fn loadAll(
    gpa: Allocator,
    scaffold: Allocator,
    source: []const u8,
    loader: ?Loader,
    diagnostics: *Diagnostics,
) Error!?[]ModuleTree {
    var modules: std.ArrayList(ModuleTree) = .empty;
    errdefer modules.deinit(gpa);

    const root_tree = try scaffold.create(parse_mod.ast.Program);
    root_tree.* = try parse_mod.parse(scaffold, gpa, source, diagnostics);
    if (diagnostics.hasErrors()) {
        modules.deinit(gpa);
        return null;
    }
    try modules.append(gpa, .{ .prefix = "", .tree = root_tree, .source = source });

    // Breadth-first over the import graph; each module loads and
    // parses once, cycles are simply already-loaded names.
    var pending: std.ArrayList(parse_mod.ast.Import) = .empty;
    defer pending.deinit(gpa);
    try pending.appendSlice(gpa, root_tree.imports);
    var next: usize = 0;
    while (next < pending.items.len) : (next += 1) {
        const wanted = pending.items[next];
        var already = false;
        for (modules.items) |module| {
            if (std.mem.eql(u8, module.prefix, wanted.name)) already = true;
        }
        if (already) continue;
        if (modules.items.len >= max_modules) {
            diagnostics.scope = "";
            try diagnostics.add("luce.import.limit", wanted.span, "too many modules (limit {d})", .{max_modules});
            break;
        }

        // The standard library resolves first: std names are a
        // reserved namespace, and a sibling file cannot shadow one.
        var loaded: ?[]const u8 = stdModule(wanted.name);
        if (loaded == null) {
            if (loader) |through| {
                loaded = try through.loadFn(through.context, scaffold, wanted.name);
            }
        }
        const module_source = loaded orelse {
            diagnostics.scope = "";
            try diagnostics.add(
                "luce.import.missing",
                wanted.span,
                "cannot load module {s} (looked for {s}.luc)",
                .{ wanted.name, wanted.name },
            );
            continue;
        };
        try diagnostics.registerSource(wanted.name, module_source);

        diagnostics.scope = wanted.name;
        const tree = try scaffold.create(parse_mod.ast.Program);
        tree.* = try parse_mod.parse(scaffold, gpa, module_source, diagnostics);
        diagnostics.scope = "";
        const prefix = try scaffold.dupe(u8, wanted.name);
        try modules.append(gpa, .{ .prefix = prefix, .tree = tree, .source = module_source });
        try pending.appendSlice(gpa, tree.imports);
    }
    if (diagnostics.hasErrors()) {
        modules.deinit(gpa);
        return null;
    }
    return try modules.toOwnedSlice(gpa);
}
