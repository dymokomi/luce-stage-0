//! Stages 1-3 for a whole program: loading, lexing, and parsing the
//! root source and every module it reaches.
//!
//! A file is a module: `import geo` loads `geo.luc` beside the
//! program (under the project root, when one governs), `import
//! geo.shapes` a file the host finds by mapping dots to folders, and
//! `import std.math` the embedded library — each binding its last
//! segment unless an `as` chose otherwise.  Resolution itself is stage 1's
//! (`source/load.zig` answers "what are the bytes of module X",
//! std and host alike, and refuses two modules under one binding);
//! what this file adds is the *graph*: breadth-first from the root,
//! each module loaded and parsed exactly once.
//!
//! **Import cycles are allowed, on purpose.**  `even.luc` and
//! `odd.luc` importing each other is the textbook case and it works:
//! two mutually recursive functions across two files.  This is a
//! decision, not an oversight, and it is sound because a Luce module
//! has no initialization phase to be caught halfway through —
//! Python's "partially initialized module" is a hazard of running
//! code at import time, and nothing runs at import time here.  What
//! *can* be circular is checked at the granularity where circularity
//! actually means something, one stage later and one level down: a
//! top-level `const` that depends on itself through any number of
//! modules is `luce.sema.const`, and a struct that contains itself is
//! `luce.sema.struct`.  Refusing whole files instead would be coarser,
//! would ban working programs, and would catch nothing the finer
//! checks miss.
//!
//! The one import a module may not write is its own
//! (`luce.import.self`) — not because it is a cycle but because a
//! module is not a member of itself, and the alias would name every
//! declaration twice.  Stage 1 extends that to an import that
//! resolves to the importing file under another name.
//!
//! `compile.zig` is the driver that calls this; the split exists only
//! so the driver can read as the stage sequence rather than as a graph
//! traversal.

const std = @import("std");
const source_mod = @import("../source.zig");
const parse_mod = @import("../parse.zig");
const semantics = @import("../semantics.zig");
const diagnostics_mod = @import("../support/diagnostics.zig");
const types = @import("../support/types.zig");

const Allocator = std.mem.Allocator;
const Diagnostics = diagnostics_mod.Diagnostics;
const FileId = source_mod.FileId;
const Loader = source_mod.Loader;
const ModuleTree = semantics.ModuleTree;

pub const Error = error{OutOfMemory};

/// Load, lex, and parse the root source and everything it imports.
///
/// Every module's text is registered in `diagnostics.sources`, which
/// owns it: the trees returned point at registry text and at scaffold
/// memory, and the returned slice itself belongs to `gpa`.  Answers
/// null when loading or parsing produced errors — they are in
/// `diagnostics`, and there is nothing to analyse.
pub fn loadAll(
    gpa: Allocator,
    scaffold: Allocator,
    source: []const u8,
    loader: ?Loader,
    options: types.CompileOptions,
    diagnostics: *Diagnostics,
) Error!?[]ModuleTree {
    var modules: std.ArrayList(ModuleTree) = .empty;
    errdefer modules.deinit(gpa);

    const root = (try source_mod.openRoot(diagnostics, options.source_name, options.source_root, source)) orelse {
        modules.deinit(gpa);
        return null;
    };
    // A tree with parse errors is still a tree: recovery dropped the
    // broken statements and kept the rest, and semantics running over
    // what parsed is what lets one syntax error stop hiding every
    // name and type problem below it.  The program still never runs —
    // stage 4's lowering gate refuses any diagnosed program.
    const root_tree = try parseModule(gpa, scaffold, root, diagnostics);
    try modules.append(gpa, .{ .prefix = "", .binding = "", .tree = root_tree, .file = root });

    // Breadth-first over the import graph.  `pending` carries the file
    // each import was written in, so a diagnostic about it points at
    // the line that asked rather than at the root.
    const Wanted = struct { from: FileId, import: parse_mod.ast.Import };
    var pending: std.ArrayList(Wanted) = .empty;
    defer pending.deinit(gpa);
    for (root_tree.imports) |wanted| try pending.append(gpa, .{ .from = root, .import = wanted });

    var next: usize = 0;
    while (next < pending.items.len) : (next += 1) {
        const wanted = pending.items[next];
        const name = wanted.import.name;
        // The self-check comes first: a module that imports itself
        // resolves to a file already in the list, so the "already
        // loaded" test below would otherwise swallow it in silence.
        // Only a sibling import can be one — a math.luc reaching for
        // `std.math` names the other namespace, not itself.
        if (wanted.import.origin == .sibling and
            std.mem.eql(u8, diagnostics.sources.at(wanted.from).?.name, name))
        {
            try reportIn(diagnostics, wanted.from, "luce.import.self", wanted.import.span, "module {s} imports itself", .{name});
            continue;
        }
        // Resolution answers the id of a module already loaded, so
        // asking again is how a cycle terminates — and how stage 1
        // sees that `import math` and `import std.math` want one name
        // for two modules.
        const file = (try source_mod.openImport(
            diagnostics,
            loader,
            wanted.from,
            name,
            wanted.import.binding,
            wanted.import.origin,
            wanted.import.span,
        )) orelse continue;
        if (isLoaded(modules.items, file)) continue;

        const tree = try parseModule(gpa, scaffold, file, diagnostics);
        // The namespace call sites use — resolution has already made
        // sure a re-import agrees on it, so the first spelling is the
        // only spelling.
        const binding = try scaffold.dupe(u8, wanted.import.binding);
        // The qualification prefix its declarations will carry.  A
        // module of the program's own root — and the standard library,
        // which belongs to no root — keys by its binding, as it always
        // has; a module of a *foreign* root is a package's, and its
        // prefix carries the root token, so two packages' same-named
        // internals can never share a qualified name or merge in a
        // serialized module (docs/PACKAGES.md D7).  The token is the
        // host's stable package identity ("geo-1.2.0"), never a
        // machine path, so the serialized names it reaches stay the
        // same on every machine.
        const loaded = diagnostics.sources.at(file).?;
        const home = diagnostics.sources.rootOf(root);
        const prefix = if (loaded.kind == .standard or std.mem.eql(u8, loaded.root, home))
            binding
        else
            try std.fmt.allocPrint(scaffold, "{s}/{s}", .{ loaded.root, binding });
        try modules.append(gpa, .{ .prefix = prefix, .binding = binding, .tree = tree, .file = file });
        for (tree.imports) |onward| try pending.append(gpa, .{ .from = file, .import = onward });
    }
    return try modules.toOwnedSlice(gpa);
}

/// True when this file has already been loaded and parsed.  Asked by
/// file rather than by name, so a module that registered and then
/// failed to parse is not parsed a second time either.
fn isLoaded(modules: []const ModuleTree, file: FileId) bool {
    for (modules) |module| {
        if (module.file == file) return true;
    }
    return false;
}

/// Report a problem with an import against the file that wrote it,
/// leaving the scope as it was found.
fn reportIn(
    diagnostics: *Diagnostics,
    file: FileId,
    code: []const u8,
    span: source_mod.Span,
    comptime format: []const u8,
    arguments: anytype,
) Error!void {
    const previous_scope = diagnostics.scope;
    diagnostics.scope = file;
    defer diagnostics.scope = previous_scope;
    try diagnostics.add(code, span, format, arguments);
}

/// Stages 2-3 for one registered file, with diagnostics attributed to
/// it.  The tree lives in `scaffold`.
fn parseModule(
    gpa: Allocator,
    scaffold: Allocator,
    file: FileId,
    diagnostics: *Diagnostics,
) Error!*parse_mod.ast.Program {
    const previous_scope = diagnostics.scope;
    diagnostics.scope = file;
    defer diagnostics.scope = previous_scope;
    const tree = try scaffold.create(parse_mod.ast.Program);
    tree.* = try parse_mod.parse(scaffold, gpa, diagnostics.sources.textOf(file), diagnostics);
    return tree;
}
