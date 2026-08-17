//! Resolution: the one place that answers "what are the bytes of
//! module X".
//!
//! Every source the compiler reads arrives through a function here —
//! the root file, a standard library module, a sibling file beside the
//! root — and leaves as a registered `FileId` whose text has passed
//! `encoding.prepare`.  Nothing downstream loads anything.
//!
//! The order is not a search order but a *split*, and it lives here
//! rather than in the driver:
//!
//!   1. `import std.NAME` is the standard library, embedded in the
//!      compiler.  Wherever the compiler runs — the luce CLI, loom, a
//!      test — it resolves, with no install path.
//!   2. `import NAME` is the host's `Loader`, which is where a
//!      filesystem (or an editor's buffer set, or a test's table)
//!      plugs in.
//!
//! The two namespaces are disjoint, so no name is reserved and no
//! file is shadowed: a `math.luc` beside the program is exactly what
//! `import math` reaches, and it takes nothing away from
//! `import std.math`.  Python's famous `random.py` failure cannot be
//! written here, and neither can the cost of avoiding it — Rust
//! (`use std::fs`) and Zig (`@import("std")`) drew the same line.
//!
//! Both resolve *through* the same call and land in the same
//! registry, so a diagnostic inside `std/strings.luc` renders with a
//! path, a line, and a column exactly like one in the program.
//!
//! **Declined: shadowing warnings.**  Python 3.13 added a hint when a
//! std name is shadowed by a neighbouring file
//! (`Objects/moduleobject.c`); it was implemented here and measured,
//! and in this repository it fired twice with two false positives —
//! nothing at import time could tell a library the author meant to
//! reach from a file that merely shares a name.  Namespacing removes
//! the question instead of answering it: there is no shadowing left
//! to warn about.
//!
//! What *is* refused is one name meaning two modules.  `import
//! std.math` binds `math` (Rust's shape: `use std::fs` then
//! `fs::read`), and so do `import math` and `import geo.math` — an
//! import binds its last segment unless an `as` chose another name —
//! so two of them in one program put two modules under one binding
//! and every call site is ambiguous: `luce.import.collision`,
//! reported the moment the second one resolves, with the alias as
//! the named remedy (docs/PACKAGES.md D2).  The mirror image is
//! refused too: one module under two bindings cannot be recorded,
//! because the binding is the prefix its declarations are known by.
//!
//! **What a host guarantees.**  The `Loader` seam resolves a *name*;
//! everything about *how* is the host's.  Two obligations come with
//! it, because a compiler cannot check them from here: the match must
//! be exact (a case-insensitive filesystem answering `Geo.luc` for
//! `import geo` compiles here and fails on the next machine), and the
//! thing opened must be an ordinary file (a fifo answers zero bytes
//! and would register as an empty module).  `src/apps/files.zig` is
//! the reference host and enforces both.
//!
//! Reporting: a load that fails reports here and answers null, so the
//! caller never has to invent a message or, worse, carry on with an
//! empty module.  Every `luce.source.*` message carries a line and a
//! column of its own — the bad file could not be registered, so the
//! registry cannot place the offset and the message must.

const std = @import("std");
const encoding = @import("encoding.zig");
const positions = @import("positions.zig");
const sources_mod = @import("sources.zig");
const diagnostics_mod = @import("../support/diagnostics.zig");

const Allocator = std.mem.Allocator;
const Diagnostics = diagnostics_mod.Diagnostics;
const FileId = sources_mod.FileId;
const Span = positions.Span;

pub const Error = error{OutOfMemory};

/// What a host's loader found for one module name.
pub const Found = union(enum) {
    /// The module's bytes, and where they came from.
    text: Text,
    /// No such module.  The ordinary case: a name that is not there.
    missing,
    /// It is there and could not be read — a directory, a permission,
    /// a short read.  The reason is printed as written; keep it lower
    /// case and human ("permission denied", "it is a directory").
    /// Nothing frees it: hand over a static string, or memory from the
    /// allocator the loader was given.
    unreadable: []const u8,
    /// The name answered in more than one place — a project file and a
    /// declared package, two shelves — and there is no precedence to
    /// pick one, because precedence is silent shadowing with a table
    /// (docs/PACKAGES.md D3).  Carries every answering path, verbatim,
    /// so the refusal names them all.  Nothing frees the paths: static
    /// strings, or memory from the allocator the loader was given.
    ambiguous: []const []const u8,
    /// The name resolved and the host's package machinery refused what
    /// it found: a store directory whose manifest disagrees with its
    /// name, a hash that does not match, a diamond in the transitive
    /// wants (docs/PACKAGES.md D4, D6).  The host names the stable
    /// diagnostic code (`luce.import.version`, `luce.import.diamond`,
    /// `luce.import.missing`) and writes the whole sentence, because
    /// the host is the only side that knows the paths and the numbers;
    /// the compiler prints both verbatim.  Nothing frees either:
    /// static strings, or memory from the allocator the loader was
    /// given.
    refused: Refusal,

    pub const Refusal = struct {
        code: []const u8,
        message: []const u8,
    };

    /// A module's source, with the origin only the host knows.
    ///
    /// Without the origin a diagnostic inside an imported module can
    /// only ever say `NAME.luc`, whatever directory it was really
    /// opened from — which is wrong the moment imports resolve
    /// anywhere but the current directory, and unusable to an editor
    /// that has to jump to the file.
    pub const Text = struct {
        /// Allocated from the allocator the loader was handed.  They
        /// are copied into the registry immediately, so the loader's
        /// buffer may be freed as soon as the call returns.
        bytes: []const u8,
        /// How a diagnostic should name the file: the path actually
        /// opened, exactly as the host resolved it ("lib/geo.luc").
        /// Empty when the loader has no path to offer — an editor
        /// buffer, a test table — and the registry falls back to
        /// NAME.luc.  Copied, like the bytes.
        path: []const u8 = "",
        /// The opaque root token the host chose for this module —
        /// which project root the file belongs to (docs/PACKAGES.md
        /// D7).  The compiler never learns what a root *is*: stage 1
        /// records the token per file, keys the registry by
        /// (root, name), and hands the importing file's token back to
        /// the loader on every load that file causes.  "" is the
        /// rootless program.  Copied, like the bytes.
        root: []const u8 = "",
    };
};

/// Which namespace an import names — the two halves of the split
/// above, decided by the parser from the spelling alone.
pub const Origin = enum {
    /// `import std.math`: the embedded standard library, and nothing
    /// a host could offer.
    standard,
    /// `import geo`: a module beside the program, and nothing the
    /// compiler ships.
    sibling,
};

/// How a module reaches the source of what it imports.  The compiler
/// never opens a file itself: a host fills this in (`src/apps/
/// files.zig` resolves NAME.luc beside the root; a test hands over a
/// table) and everything else about loading is decided above.
///
/// `from_root` is the opaque root token of the file the import was
/// written in — recorded from `Found.Text.root` when that file was
/// loaded (the root's own token arrives as
/// `CompileOptions.source_root`).  The host chose it and the host
/// interprets it; the compiler only carries it, which is how a
/// package's internal imports will one day resolve inside the package
/// without the compiler learning what a package is.
pub const Loader = struct {
    context: *anyopaque,
    load: *const fn (
        context: *anyopaque,
        arena: Allocator,
        name: []const u8,
        from_root: []const u8,
    ) error{OutOfMemory}!Found,
};

// ---------------------------------------------------------------------------
// The standard library
// ---------------------------------------------------------------------------
//
// Std modules are Luce source embedded in the compiler — the way Zig
// ships lib/std with its compiler, minus the install path.  Being
// ordinary modules, they obey every language rule, including the host
// gate: `import std.files` inside a host-less program is a compile
// error, reported against std/files.luc's own line and column.

/// The namespace the standard library lives under, spelled as it is
/// written.  It is the one word the import grammar knows.
pub const standard_namespace = "std";

const standard_modules = [_]struct { name: []const u8, source: []const u8 }{
    .{ .name = "math", .source = @embedFile("../std/math.luc") },
    .{ .name = "files", .source = @embedFile("../std/files.luc") },
    .{ .name = "strings", .source = @embedFile("../std/strings.luc") },
    .{ .name = "lists", .source = @embedFile("../std/lists.luc") },
    .{ .name = "paths", .source = @embedFile("../std/paths.luc") },
    .{ .name = "os", .source = @embedFile("../std/os.luc") },
    .{ .name = "term", .source = @embedFile("../std/term.luc") },
    .{ .name = "zip", .source = @embedFile("../std/zip.luc") },
    .{ .name = "json", .source = @embedFile("../std/json.luc") },
    .{ .name = "gpu", .source = @embedFile("../std/gpu.luc") },
    .{ .name = "ui", .source = @embedFile("../std/ui.luc") },
    .{ .name = "network", .source = @embedFile("../std/network.luc") },
};

/// The whole library, spelled as it is imported — for the messages
/// that have to say what does exist.  Built here so adding a module
/// is still one row.
pub const standard_list = whole: {
    var text: []const u8 = "";
    for (standard_modules, 0..) |module, index| {
        if (index != 0) text = text ++ ", ";
        text = text ++ standard_namespace ++ "." ++ module.name;
    }
    break :whole text;
};

/// True when `std.name` is a module of the standard library.
///
/// This is a question about the library, not a reservation: `name`
/// alone still means a file beside the program, whatever it is
/// called.  Stage 4 asks so a hint can spell an import the way the
/// author would have to write it.
pub fn isStandard(name: []const u8) bool {
    return standardSource(name) != null;
}

fn standardSource(name: []const u8) ?[]const u8 {
    for (standard_modules) |module| {
        if (std.mem.eql(u8, module.name, name)) return module.source;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Opening files
// ---------------------------------------------------------------------------

/// Register the root source and answer its id (always `root_file`).
///
/// `path` is how diagnostics and trap traces name it ("editor.luc");
/// `root` is the opaque host root token the root module belongs to
/// (`CompileOptions.source_root`, "" for a rootless program); `bytes`
/// belong to the caller and are copied.  Reports and answers null when
/// the bytes cannot be Luce source.
pub fn openRoot(
    diagnostics: *Diagnostics,
    path: []const u8,
    root: []const u8,
    bytes: []const u8,
) Error!?FileId {
    // The root is what everything else hangs off, so it is loaded
    // first and its id is the one every default refers to.
    std.debug.assert(diagnostics.sources.count() == 0);
    const display = if (path.len != 0) path else "main.luc";
    const prepared = try encoding.prepare(diagnostics.sources.allocator, bytes);
    switch (prepared) {
        .text => |text| return try diagnostics.sources.add(.root, root, "", "", display, text),
        .problem => |problem| {
            // Nothing is registered, so there is no file to point at
            // and the message has to name it itself.
            try report(diagnostics, .{ .start = 0, .end = 0 }, display, bytes, problem);
            return null;
        },
    }
}

/// Resolve and register an import written at `span` in `from`.
///
/// `name` is the module as the import spells it — "math" for both
/// `import std.math` and `import math`, told apart by `origin`, and
/// "geo.shapes" for the subfolder form.  `binding` is the namespace
/// the import claims at call sites: the name's last segment, or the
/// alias an `import ... as` chose (docs/PACKAGES.md D2).
///
/// Answers the id of an already-loaded module when the pair
/// (importing file's root, name) is one — which is what makes an
/// import cycle terminate rather than recurse, and what keeps two
/// roots' same-named modules from answering for each other.  Reports
/// and answers null when the module cannot be loaded, when the
/// binding already means another module, or when the module is
/// already bound under another name — one module holds one binding,
/// because the binding is the prefix its declarations are known by.
pub fn openImport(
    diagnostics: *Diagnostics,
    loader: ?Loader,
    from: FileId,
    name: []const u8,
    binding: []const u8,
    origin: Origin,
    span: Span,
) Error!?FileId {
    const previous_scope = diagnostics.scope;
    diagnostics.scope = from;
    defer diagnostics.scope = previous_scope;

    // How a message names what was looked for: dots map to folders
    // (docs/PACKAGES.md D2), so "geo.shapes" was probed as a path.
    const path = try probedPath(diagnostics.allocator, name);
    defer diagnostics.allocator.free(path);

    // The module's identity in the registry: its name with the std
    // namespace back on the front, so `import std.math` and a
    // sibling math.luc are two entries that never dedup to each
    // other — the binding, not the identity, is what they fight over.
    const spelled = switch (origin) {
        .standard => try std.fmt.allocPrint(diagnostics.allocator, "{s}.{s}", .{ standard_namespace, name }),
        .sibling => name,
    };
    defer if (origin == .standard) diagnostics.allocator.free(spelled);

    // The import binds `binding` in the importing file's namespace,
    // and a namespace is a root: every registry question below asks
    // with the importing file's token, so collision is
    // per-importing-namespace and never reaches across roots.
    const from_root = diagnostics.sources.rootOf(from);

    if (diagnostics.sources.claim(from_root, spelled)) |already| {
        // This spelling has resolved here before; the question left is
        // the binding.  A second one cannot be recorded — the first is
        // the prefix every qualified name was built from — so it is
        // refused rather than half-honored.
        if (try boundOtherwise(diagnostics, already, spelled, binding, span)) return null;
        return already;
    }

    if (origin == .standard) {
        const embedded = standardSource(name) orelse {
            try diagnostics.add(
                "luce.import.standard",
                span,
                "there is no standard module {s}.{s}; the standard library is {s}",
                .{ standard_namespace, name, standard_list },
            );
            return null;
        };
        if (try bindingHeld(diagnostics, from_root, spelled, binding, origin, span)) return null;
        // The library is embedded and identical wherever it is imported
        // from, so one program holds one copy of each std module — a
        // second namespace importing it claims the copy already loaded,
        // which is what keeps a std struct one type across a package
        // boundary.
        if (diagnostics.sources.findStandard(spelled)) |already| {
            if (try boundOtherwise(diagnostics, already, spelled, binding, span)) return null;
            try diagnostics.sources.recordClaim(from_root, spelled, already);
            return already;
        }
        const inside = try std.fmt.allocPrint(
            diagnostics.allocator,
            "{s}/{s}",
            .{ standard_namespace, path },
        );
        defer diagnostics.allocator.free(inside);
        // No host chose a token for the library; the copy registers
        // under the first importer's root, and the token is never read
        // back — std imports nothing a host resolves.
        const id = (try open(diagnostics, .standard, from_root, spelled, binding, inside, embedded, span)) orelse return null;
        try diagnostics.sources.recordClaim(from_root, spelled, id);
        return id;
    }

    // `std` is the namespace, so it is not a module and std.luc is a
    // file no import can reach.  Said here rather than in the parser,
    // which has no business knowing what the library contains.
    if (std.mem.eql(u8, name, standard_namespace)) {
        try diagnostics.add(
            "luce.import.reserved",
            span,
            "{s} is a reserved namespace, not a module, so {s}.luc cannot be imported; " ++
                "the standard library is {s}",
            .{ standard_namespace, standard_namespace, standard_list },
        );
        return null;
    }

    if (try bindingHeld(diagnostics, from_root, spelled, binding, origin, span)) return null;

    // The host's loader gets a scratch arena of its own: whatever it
    // allocates to answer is copied into the registry and dropped
    // here, rather than living as long as the compile.
    var scratch = std.heap.ArenaAllocator.init(diagnostics.allocator);
    defer scratch.deinit();
    const found: Found = if (loader) |through|
        try through.load(through.context, scratch.allocator(), name, from_root)
    else
        .missing;

    switch (found) {
        .text => |source| {
            const opened = if (source.path.len != 0) source.path else path;
            // Resolving to the file that asked is a self-import under
            // another name: main.luc writing `import main` would
            // otherwise load the whole program a second time, under a
            // prefix, and every function would exist twice.  Textual,
            // because two spellings of one path are the host's problem
            // and it is the host that answered with this one.
            const asked_from = diagnostics.sources.pathOf(from);
            if (asked_from.len != 0 and std.mem.eql(u8, asked_from, opened)) {
                try diagnostics.add(
                    "luce.import.self",
                    span,
                    "{s} imports itself: module {s} is the same file",
                    .{ opened, name },
                );
                return null;
            }
            // Whatever the import said, the host answered with a file
            // already loaded for this root: one file is one module,
            // whichever spelling reached it first — `geo.shapes` from
            // the consumer and `shapes` from inside the package are
            // claims on one set of declarations (docs/PACKAGES.md D4).
            if (diagnostics.sources.findByPath(source.root, opened)) |already| {
                if (try boundOtherwise(diagnostics, already, spelled, binding, span)) return null;
                try diagnostics.sources.recordClaim(from_root, spelled, already);
                return already;
            }
            const id = (try open(diagnostics, .imported, source.root, spelled, binding, opened, source.bytes, span)) orelse return null;
            try diagnostics.sources.recordClaim(from_root, spelled, id);
            return id;
        },
        .missing => {
            try diagnostics.add(
                "luce.import.missing",
                span,
                "cannot load module {s} (looked for {s})",
                .{ name, path },
            );
            return null;
        },
        .unreadable => |why| {
            try diagnostics.add(
                "luce.import.unreadable",
                span,
                "cannot read {s} for module {s}: {s}",
                .{ path, name, why },
            );
            return null;
        },
        .ambiguous => |places| {
            // Every answering path, verbatim: there is no precedence
            // to pick one, and a refusal that names only the winner
            // would send the author hunting for the others
            // (docs/PACKAGES.md D3).
            const named = try std.mem.join(diagnostics.allocator, ", ", places);
            defer diagnostics.allocator.free(named);
            try diagnostics.add(
                "luce.import.ambiguous",
                span,
                "module {s} answers in more than one place: {s}; exactly one may answer",
                .{ name, named },
            );
            return null;
        },
        .refused => |refusal| {
            // The host's package machinery said no and wrote the whole
            // sentence — it is the only side that knows the paths and
            // the numbers — and named the stable code it belongs
            // under.  Both travel verbatim (docs/PACKAGES.md D6).
            try diagnostics.add(refusal.code, span, "{s}", .{refusal.message});
            return null;
        },
    }
}

/// True when `already` is bound under a name other than `binding` —
/// in which case the second spelling was refused and reported.  One
/// module holds one binding for the whole program, because the
/// binding is the prefix its qualified declaration names carry.
fn boundOtherwise(
    diagnostics: *Diagnostics,
    already: FileId,
    spelled: []const u8,
    binding: []const u8,
    span: Span,
) Error!bool {
    const held = diagnostics.sources.bindingOf(already);
    if (std.mem.eql(u8, held, binding)) return false;
    try diagnostics.add(
        "luce.import.collision",
        span,
        "module {s} is already imported as {s}; a module has one binding " ++
            "for the whole program, so use {s} here too",
        .{ spelled, held, held },
    );
    return true;
}

/// The relative path an import's name was probed as: dots map to
/// folders (docs/PACKAGES.md D2), so module geo.shapes was looked for
/// at geo/shapes.luc.  Allocated from `allocator`; the caller frees.
fn probedPath(allocator: Allocator, name: []const u8) Error![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}.luc", .{name});
    std.mem.replaceScalar(u8, path[0 .. path.len - ".luc".len], '.', '/');
    return path;
}

/// True when `binding` already means another module in `root` — one
/// binding, two modules, and every call site ambiguous.  Reported as
/// `luce.import.collision` with the alias as the named remedy
/// (docs/PACKAGES.md D2); the import offered for aliasing is the one
/// that can move, which is never the standard library's.
fn bindingHeld(
    diagnostics: *Diagnostics,
    root: []const u8,
    spelled: []const u8,
    binding: []const u8,
    origin: Origin,
    span: Span,
) Error!bool {
    const holder = diagnostics.sources.findBinding(root, binding) orelse return false;
    const other = diagnostics.sources.at(holder).?;
    const aliasable = if (origin == .standard) other.name else spelled;
    try diagnostics.add(
        "luce.import.collision",
        span,
        "import {s} and import {s} both bind the name {s}; " ++
            "give one its own name: import {s} as NAME",
        .{ other.name, spelled, binding, aliasable },
    );
    return true;
}

/// Prepare and register bytes that have been found; report and answer
/// null when they cannot be source.  `span` points at the import that
/// asked for them.
fn open(
    diagnostics: *Diagnostics,
    kind: sources_mod.Kind,
    root: []const u8,
    name: []const u8,
    binding: []const u8,
    path: []const u8,
    bytes: []const u8,
    span: Span,
) Error!?FileId {
    const prepared = try encoding.prepare(diagnostics.sources.allocator, bytes);
    switch (prepared) {
        .text => |text| return try diagnostics.sources.add(kind, root, name, binding, path, text),
        .problem => |problem| {
            try report(diagnostics, span, path, bytes, problem);
            return null;
        },
    }
}

/// One message per way a file can fail to be source.
///
/// The path *and the position* are in the message because the file it
/// names was never registered: there is no id for `render` to place
/// the offset against, and a bare byte offset is not something anyone
/// can act on.  Counting the prefix is honest work here — everything
/// before the break is well formed by definition, and this is an
/// error path, so a scan costs nothing that matters.
fn report(
    diagnostics: *Diagnostics,
    span: Span,
    path: []const u8,
    bytes: []const u8,
    problem: encoding.Problem,
) Error!void {
    switch (problem) {
        .too_large => |size| try diagnostics.add(
            "luce.source.too_large",
            span,
            "{s} is {d} bytes; the limit is {d}",
            .{ path, size, encoding.max_bytes },
        ),
        .wrong_encoding => |wrong| try diagnostics.add(
            "luce.source.encoding",
            span,
            "{s} begins with a {s} byte-order mark; Luce source must be UTF-8",
            .{ path, wrong.label() },
        ),
        .nul_byte => |offset| {
            const at = positions.place(bytes, offset);
            try diagnostics.add(
                "luce.source.binary",
                span,
                "{s}:{d}:{d}: NUL byte; this is not a text file",
                .{ path, at.line, at.column },
            );
        },
        .stray_carriage_return => |offset| {
            const at = positions.place(bytes, offset);
            try diagnostics.add(
                "luce.source.line_ending",
                span,
                "{s}:{d}:{d}: stray carriage return; " ++
                    "Luce source ends lines with LF or CRLF",
                .{ path, at.line, at.column },
            );
        },
        .invalid_utf8 => |offset| {
            const at = positions.place(bytes, offset);
            try diagnostics.add(
                "luce.source.utf8",
                span,
                "{s}:{d}:{d}: not valid UTF-8 (byte \\x{x:0>2})",
                .{ path, at.line, at.column, bytes[offset] },
            );
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const TableLoader = struct {
    entries: []const struct {
        name: []const u8,
        text: []const u8,
        /// What the host would call the file; "" leaves the fallback.
        path: []const u8 = "",
        /// The root token the host chose for the answered module.
        root: []const u8 = "",
        /// Answer only when the import came from this root; null
        /// answers whatever root asked.
        from: ?[]const u8 = null,
    } = &.{},
    /// Names that exist but refuse to be read.
    locked: []const []const u8 = &.{},
    /// Names that answer in more than one place, with the places.
    contested: []const struct {
        name: []const u8,
        places: []const []const u8,
    } = &.{},
    /// Names the host's package machinery refuses, code and sentence
    /// chosen by the host (docs/PACKAGES.md D6).
    vetoed: []const struct {
        name: []const u8,
        code: []const u8,
        message: []const u8,
    } = &.{},

    fn load(context: *anyopaque, arena: Allocator, name: []const u8, from_root: []const u8) error{OutOfMemory}!Found {
        const self: *TableLoader = @ptrCast(@alignCast(context));
        for (self.locked) |locked| {
            if (std.mem.eql(u8, locked, name)) return .{ .unreadable = "permission denied" };
        }
        for (self.contested) |contest| {
            if (std.mem.eql(u8, contest.name, name)) return .{ .ambiguous = contest.places };
        }
        for (self.vetoed) |veto| {
            if (std.mem.eql(u8, veto.name, name)) {
                return .{ .refused = .{ .code = veto.code, .message = veto.message } };
            }
        }
        for (self.entries) |entry| {
            if (!std.mem.eql(u8, entry.name, name)) continue;
            if (entry.from) |only| {
                if (!std.mem.eql(u8, only, from_root)) continue;
            }
            return .{ .text = .{
                .bytes = try arena.dupe(u8, entry.text),
                .path = entry.path,
                .root = entry.root,
            } };
        }
        return .missing;
    }

    fn loader(self: *TableLoader) Loader {
        return .{ .context = self, .load = load };
    }
};

const nowhere: Span = .{ .start = 0, .end = 0 };

test "the root registers as file zero under the name it was given" {
    var diagnostics = Diagnostics.init(testing.allocator);
    defer diagnostics.deinit();
    const root = (try openRoot(&diagnostics, "editor.luc", "", "func main():\r\n    return\r\n")).?;
    try testing.expectEqual(sources_mod.root_file, root);
    try testing.expectEqualStrings("editor.luc", diagnostics.sources.pathOf(root));
    // Loading normalizes: the registry holds LF text, and every span
    // downstream indexes that.
    try testing.expectEqualStrings("func main():\n    return\n", diagnostics.sources.textOf(root));
    try testing.expectEqual(@as(usize, 0), diagnostics.count());
}

test "a nameless root still has a path to print" {
    var diagnostics = Diagnostics.init(testing.allocator);
    defer diagnostics.deinit();
    const root = (try openRoot(&diagnostics, "", "", "func main():\n    return\n")).?;
    try testing.expectEqualStrings("main.luc", diagnostics.sources.pathOf(root));
}

test "a root that is not text is refused with its own diagnostic" {
    var diagnostics = Diagnostics.init(testing.allocator);
    defer diagnostics.deinit();
    try testing.expect((try openRoot(&diagnostics, "photo.luc", "", "\xFF\xD8\xFF\xE0")) == null);
    try testing.expectEqual(@as(usize, 1), diagnostics.count());
    try testing.expectEqualStrings("luce.source.utf8", diagnostics.at(0).?.code);
    // The message names the file, because no file was registered.
    try testing.expect(std.mem.indexOf(u8, diagnostics.at(0).?.message, "photo.luc") != null);
    try testing.expectEqual(@as(usize, 0), diagnostics.sources.count());
}

test "a bad byte is reported at a line and a column, not a raw offset" {
    // A registered file's offsets are placed by the registry; these
    // never got that far, so the message has to do it.  The prefix
    // before a break is well formed by definition, so the line is a
    // free count.
    const cases = [_]struct {
        bytes: []const u8,
        code: []const u8,
        wanted: []const u8,
    }{
        .{
            .bytes = "func main():\n    let a = 1\n    let b = \xE9\n",
            .code = "luce.source.utf8",
            .wanted = "bad.luc:3:13: not valid UTF-8 (byte \\xe9)",
        },
        .{
            .bytes = "func main():\n    return\x00\n",
            .code = "luce.source.binary",
            .wanted = "bad.luc:2:11: NUL byte",
        },
        .{
            .bytes = "a = 1\nb = 2\rc = 3\n",
            .code = "luce.source.line_ending",
            .wanted = "bad.luc:2:6: stray carriage return",
        },
        .{
            .bytes = "\xFF\xFEf\x00u\x00n\x00c\x00",
            .code = "luce.source.encoding",
            .wanted = "bad.luc begins with a UTF-16 (little-endian) byte-order mark",
        },
    };
    for (cases) |case| {
        var diagnostics = Diagnostics.init(testing.allocator);
        defer diagnostics.deinit();
        try testing.expect((try openRoot(&diagnostics, "bad.luc", "", case.bytes)) == null);
        try testing.expectEqualStrings(case.code, diagnostics.at(0).?.code);
        try testing.expect(std.mem.startsWith(u8, diagnostics.at(0).?.message, case.wanted));
    }
}

test "luce.source.too_large: a file past the ceiling is refused before it is read" {
    // The ceiling is the one refusal that costs its own size to prove,
    // which is why nothing else reaches it — and why it is worth one
    // test of its own: the check stands between a hostile or corrupt
    // file and every offset, line index and span the compiler would
    // otherwise build over it.  The message carries both numbers,
    // because "too large" without them is not something a reader can
    // act on.
    const oversized = try testing.allocator.alloc(u8, encoding.max_bytes + 1);
    defer testing.allocator.free(oversized);
    @memset(oversized, 'a');

    var diagnostics = Diagnostics.init(testing.allocator);
    defer diagnostics.deinit();
    try testing.expect((try openRoot(&diagnostics, "huge.luc", "", oversized)) == null);
    try testing.expectEqual(@as(usize, 1), diagnostics.count());
    try testing.expectEqualStrings("luce.source.too_large", diagnostics.at(0).?.code);
    try testing.expect(std.mem.indexOf(u8, diagnostics.at(0).?.message, "huge.luc") != null);
    try testing.expect(std.mem.indexOf(u8, diagnostics.at(0).?.message, "the limit is") != null);
    // Nothing was registered: a file this size never became source.
    try testing.expectEqual(@as(usize, 0), diagnostics.sources.count());

    // One byte under, and it is ordinary text.
    var accepted = Diagnostics.init(testing.allocator);
    defer accepted.deinit();
    try testing.expect((try openRoot(&accepted, "big.luc", "", oversized[0..encoding.max_bytes])) != null);
    try testing.expectEqual(@as(usize, 0), accepted.count());
}

test "a byte-order mark counts toward the offsets a message reports" {
    // The BOM is three bytes of the file even though it is not three
    // bytes of the text, so a position must count it — otherwise the
    // column is off by three on every Windows-edited file.
    var diagnostics = Diagnostics.init(testing.allocator);
    defer diagnostics.deinit();
    try testing.expect((try openRoot(&diagnostics, "bad.luc", "", "\xEF\xBB\xBFa\x00")) == null);
    try testing.expect(std.mem.startsWith(u8, diagnostics.at(0).?.message, "bad.luc:1:5:"));
}

test "the two namespaces are disjoint: std.math is embedded, math is the file" {
    var table: TableLoader = .{ .entries = &.{
        .{ .name = "math", .text = "func local() -> i64:\n    return 0\n" },
        .{ .name = "geo", .text = "func area() -> i64:\n    return 4\n" },
    } };
    var diagnostics = Diagnostics.init(testing.allocator);
    defer diagnostics.deinit();
    _ = (try openRoot(&diagnostics, "main.luc", "", "import std.math\n")).?;

    const math = (try openImport(&diagnostics, table.loader(), sources_mod.root_file, "math", "math", .standard, nowhere)).?;
    try testing.expectEqual(sources_mod.Kind.standard, diagnostics.sources.at(math).?.kind);
    // Named by the namespace it came from, so no diagnostic inside the
    // library can be mistaken for one in a file called math.luc.
    try testing.expectEqualStrings("std/math.luc", diagnostics.sources.pathOf(math));
    try testing.expect(std.mem.indexOf(u8, diagnostics.sources.textOf(math), "func local") == null);
    try testing.expect(isStandard("math") and isStandard("lists") and !isStandard("geo"));

    const geo = (try openImport(&diagnostics, table.loader(), sources_mod.root_file, "geo", "geo", .sibling, nowhere)).?;
    try testing.expectEqual(sources_mod.Kind.imported, diagnostics.sources.at(geo).?.kind);
    try testing.expectEqualStrings("geo.luc", diagnostics.sources.pathOf(geo));

    // Asking twice answers the same file rather than loading again.
    try testing.expectEqual(geo, (try openImport(&diagnostics, table.loader(), sources_mod.root_file, "geo", "geo", .sibling, nowhere)).?);
    try testing.expectEqual(@as(usize, 3), diagnostics.sources.count());
    try testing.expectEqual(@as(usize, 0), diagnostics.count());
}

test "a sibling module is reached by its own name, whatever the library is called" {
    // The point of the namespace: math.luc beside the program is not
    // shadowed, not warned about, and not reserved — it is simply what
    // `import math` means.
    var table: TableLoader = .{ .entries = &.{
        .{ .name = "math", .text = "func local() -> i64:\n    return 7\n" },
    } };
    var diagnostics = Diagnostics.init(testing.allocator);
    defer diagnostics.deinit();
    _ = (try openRoot(&diagnostics, "main.luc", "", "import math\n")).?;

    const math = (try openImport(&diagnostics, table.loader(), sources_mod.root_file, "math", "math", .sibling, nowhere)).?;
    try testing.expectEqual(sources_mod.Kind.imported, diagnostics.sources.at(math).?.kind);
    try testing.expect(std.mem.indexOf(u8, diagnostics.sources.textOf(math), "func local") != null);
    try testing.expectEqual(@as(usize, 0), diagnostics.count());
}

test "one name cannot mean two modules, and the remedy is the alias" {
    // `import std.math` binds `math`, and so does `import math`.  The
    // second one to resolve is refused, whichever order they are in,
    // and the message offers `as` on the import that can move — which
    // is never the standard library's (docs/PACKAGES.md D2).
    const orders = [_][2]Origin{ .{ .standard, .sibling }, .{ .sibling, .standard } };
    for (orders) |order| {
        var table: TableLoader = .{ .entries = &.{
            .{ .name = "math", .text = "func local() -> i64:\n    return 7\n", .path = "lib/math.luc" },
        } };
        var diagnostics = Diagnostics.init(testing.allocator);
        defer diagnostics.deinit();
        _ = (try openRoot(&diagnostics, "main.luc", "", "import std.math\nimport math\n")).?;

        try testing.expect((try openImport(&diagnostics, table.loader(), sources_mod.root_file, "math", "math", order[0], nowhere)) != null);
        try testing.expect((try openImport(&diagnostics, table.loader(), sources_mod.root_file, "math", "math", order[1], nowhere)) == null);
        try testing.expectEqualStrings("luce.import.collision", diagnostics.at(0).?.code);
        try testing.expect(std.mem.indexOf(u8, diagnostics.at(0).?.message, "std.math") != null);
        try testing.expect(std.mem.indexOf(u8, diagnostics.at(0).?.message, "both bind the name math") != null);
        // Whichever came second, the alias lands on the sibling.
        try testing.expect(std.mem.indexOf(u8, diagnostics.at(0).?.message, "import math as NAME") != null);
        try testing.expectEqual(@as(usize, 1), diagnostics.count());
    }
}

test "an alias frees the binding: std.math and math coexist as sm and math" {
    // The collision above, resolved the way its message says: the
    // sibling keeps `math` and the library answers under `sm` — or the
    // other way around, since only the binding moves, never the name.
    var table: TableLoader = .{ .entries = &.{
        .{ .name = "math", .text = "func local() -> i64:\n    return 7\n" },
    } };
    var diagnostics = Diagnostics.init(testing.allocator);
    defer diagnostics.deinit();
    _ = (try openRoot(&diagnostics, "main.luc", "", "import std.math\nimport math as m2\n")).?;

    const library = (try openImport(&diagnostics, table.loader(), sources_mod.root_file, "math", "math", .standard, nowhere)).?;
    const sibling = (try openImport(&diagnostics, table.loader(), sources_mod.root_file, "math", "m2", .sibling, nowhere)).?;
    try testing.expect(library != sibling);
    try testing.expectEqualStrings("math", diagnostics.sources.bindingOf(library));
    try testing.expectEqualStrings("m2", diagnostics.sources.bindingOf(sibling));
    try testing.expectEqualStrings("std.math", diagnostics.sources.at(library).?.name);
    try testing.expectEqualStrings("math", diagnostics.sources.at(sibling).?.name);
    try testing.expectEqual(@as(usize, 0), diagnostics.count());
}

test "a module has one binding: a second spelling is refused, naming the first" {
    // `import geo.shapes` in one file and `import geo.shapes as gs` in
    // another want two prefixes for one module, and qualified names
    // can carry only one.  The refusal names the binding that holds.
    var table: TableLoader = .{ .entries = &.{
        .{ .name = "geo.shapes", .text = "func area() -> i64:\n    return 4\n" },
    } };
    var diagnostics = Diagnostics.init(testing.allocator);
    defer diagnostics.deinit();
    _ = (try openRoot(&diagnostics, "main.luc", "", "import geo.shapes\n")).?;

    const first = (try openImport(&diagnostics, table.loader(), sources_mod.root_file, "geo.shapes", "shapes", .sibling, nowhere)).?;
    try testing.expectEqualStrings("shapes", diagnostics.sources.bindingOf(first));

    try testing.expect((try openImport(&diagnostics, table.loader(), sources_mod.root_file, "geo.shapes", "gs", .sibling, nowhere)) == null);
    try testing.expectEqualStrings("luce.import.collision", diagnostics.at(0).?.code);
    try testing.expect(std.mem.indexOf(u8, diagnostics.at(0).?.message, "already imported as shapes") != null);
    try testing.expectEqual(@as(usize, 1), diagnostics.count());
}

test "a dotted module that is missing names the folder path it was probed as" {
    var diagnostics = Diagnostics.init(testing.allocator);
    defer diagnostics.deinit();
    _ = (try openRoot(&diagnostics, "main.luc", "", "import geo.shapes\n")).?;

    var table: TableLoader = .{};
    try testing.expect((try openImport(&diagnostics, table.loader(), sources_mod.root_file, "geo.shapes", "shapes", .sibling, nowhere)) == null);
    try testing.expectEqualStrings("luce.import.missing", diagnostics.at(0).?.code);
    // Dots map to folders (docs/PACKAGES.md D2): the message says
    // geo/shapes.luc, not geo.shapes.luc.
    try testing.expect(std.mem.indexOf(u8, diagnostics.at(0).?.message, "geo/shapes.luc") != null);
}

test "the registry keys modules by (root, name): one name, two roots, two modules" {
    // The pair key is what will keep a package's private `util` from
    // answering the project's `import util` (docs/PACKAGES.md D7).
    // The host answers `geo` with a root token of its own; an import
    // written *in* geo then resolves under that token, so the two
    // `helper` modules load separately and neither dedups to the other.
    var table: TableLoader = .{ .entries = &.{
        .{ .name = "geo", .text = "import helper\n", .root = "pkg" },
        .{ .name = "helper", .text = "func ours() -> i64:\n    return 1\n", .from = "" },
        .{ .name = "helper", .text = "func theirs() -> i64:\n    return 2\n", .root = "pkg", .from = "pkg" },
    } };
    var diagnostics = Diagnostics.init(testing.allocator);
    defer diagnostics.deinit();
    _ = (try openRoot(&diagnostics, "main.luc", "", "import geo\nimport helper\n")).?;

    const geo = (try openImport(&diagnostics, table.loader(), sources_mod.root_file, "geo", "geo", .sibling, nowhere)).?;
    try testing.expectEqualStrings("pkg", diagnostics.sources.rootOf(geo));

    const ours = (try openImport(&diagnostics, table.loader(), sources_mod.root_file, "helper", "helper", .sibling, nowhere)).?;
    const theirs = (try openImport(&diagnostics, table.loader(), geo, "helper", "helper", .sibling, nowhere)).?;
    try testing.expect(ours != theirs);
    try testing.expect(std.mem.indexOf(u8, diagnostics.sources.textOf(ours), "func ours") != null);
    try testing.expect(std.mem.indexOf(u8, diagnostics.sources.textOf(theirs), "func theirs") != null);

    // Asking again answers the module already loaded *for that root* —
    // dedup and cycle termination moved to the pair with everything
    // else.
    try testing.expectEqual(ours, (try openImport(&diagnostics, table.loader(), sources_mod.root_file, "helper", "helper", .sibling, nowhere)).?);
    try testing.expectEqual(theirs, (try openImport(&diagnostics, table.loader(), geo, "helper", "helper", .sibling, nowhere)).?);
    try testing.expectEqual(@as(usize, 4), diagnostics.sources.count());
    try testing.expectEqual(@as(usize, 0), diagnostics.count());
}

test "collision is per importing namespace, not program-global" {
    // Under one root, `import std.math` and `import math` still fight
    // over the binding `math` — but a file in *another* root importing
    // a sibling `math` is claiming a different namespace's binding,
    // and is no collision at all.
    var table: TableLoader = .{ .entries = &.{
        .{ .name = "geo", .text = "import math\n", .root = "pkg" },
        .{ .name = "math", .text = "func local() -> i64:\n    return 7\n", .path = "pkg/math.luc", .root = "pkg", .from = "pkg" },
        .{ .name = "math", .text = "func local() -> i64:\n    return 8\n", .from = "" },
    } };
    var diagnostics = Diagnostics.init(testing.allocator);
    defer diagnostics.deinit();
    _ = (try openRoot(&diagnostics, "main.luc", "", "import std.math\nimport geo\nimport math\n")).?;

    _ = (try openImport(&diagnostics, table.loader(), sources_mod.root_file, "math", "math", .standard, nowhere)).?;
    const geo = (try openImport(&diagnostics, table.loader(), sources_mod.root_file, "geo", "geo", .sibling, nowhere)).?;

    // geo's own `import math` binds math in geo's namespace: fine.
    try testing.expect((try openImport(&diagnostics, table.loader(), geo, "math", "math", .sibling, nowhere)) != null);
    try testing.expectEqual(@as(usize, 0), diagnostics.count());

    // The root's `import math` claims a binding std.math holds: refused.
    try testing.expect((try openImport(&diagnostics, table.loader(), sources_mod.root_file, "math", "math", .sibling, nowhere)) == null);
    try testing.expectEqualStrings("luce.import.collision", diagnostics.at(0).?.code);
    try testing.expectEqual(@as(usize, 1), diagnostics.count());
}

test "luce.import.ambiguous: a name that answers twice is refused with every path named" {
    // Nothing fires this today — resolution has one place to look —
    // but the seam carries the refusal so D3's probe-everything rule
    // arrives as a stable code, not free text through `.unreadable`.
    var table: TableLoader = .{ .contested = &.{
        .{ .name = "geo", .places = &.{ "geo.luc", ".luce/packages/geo-1.2.0/geo.luc" } },
    } };
    var diagnostics = Diagnostics.init(testing.allocator);
    defer diagnostics.deinit();
    _ = (try openRoot(&diagnostics, "main.luc", "", "import geo\n")).?;

    try testing.expect((try openImport(&diagnostics, table.loader(), sources_mod.root_file, "geo", "geo", .sibling, nowhere)) == null);
    try testing.expectEqualStrings("luce.import.ambiguous", diagnostics.at(0).?.code);
    try testing.expect(std.mem.indexOf(u8, diagnostics.at(0).?.message, "geo.luc") != null);
    try testing.expect(std.mem.indexOf(u8, diagnostics.at(0).?.message, ".luce/packages/geo-1.2.0/geo.luc") != null);
    // Refused means refused: nothing was registered under the name.
    try testing.expectEqual(@as(usize, 1), diagnostics.sources.count());
    try testing.expectEqual(@as(usize, 1), diagnostics.count());
}

test "a host refusal travels verbatim, under the code the host named" {
    // The store machinery's refusals — a version disagreement, a
    // diamond, a hash mismatch — are sentences only the host can
    // write, and codes the taxonomy already ratified (docs/PACKAGES.md
    // D6).  The seam carries both through untouched.
    var table: TableLoader = .{ .vetoed = &.{.{
        .name = "geo",
        .code = "luce.import.version",
        .message = "package geo 1.2.0 at .luce/packages/geo-1.2.0: its luce.yaml says geo 1.3.0; the directory and its manifest must agree",
    }} };
    var diagnostics = Diagnostics.init(testing.allocator);
    defer diagnostics.deinit();
    _ = (try openRoot(&diagnostics, "main.luc", "", "import geo\n")).?;

    try testing.expect((try openImport(&diagnostics, table.loader(), sources_mod.root_file, "geo", "geo", .sibling, nowhere)) == null);
    try testing.expectEqualStrings("luce.import.version", diagnostics.at(0).?.code);
    try testing.expect(std.mem.indexOf(u8, diagnostics.at(0).?.message, "geo 1.3.0") != null);
    try testing.expectEqual(@as(usize, 1), diagnostics.sources.count());
}

test "one file reached under two spellings is one module, and the binding still holds" {
    // `geo.shapes` from the consumer and `shapes` from inside the
    // package are two claims on one file (docs/PACKAGES.md D4): the
    // host answers the same (root, path) for both, the registry
    // answers the module already loaded, and an alias that would give
    // the one module a second binding is refused.
    var table: TableLoader = .{ .entries = &.{
        .{
            .name = "geo.shapes",
            .text = "func area() -> i64:\n    return 4\n",
            .path = ".luce/packages/geo-1.2.0/shapes.luc",
            .root = "geo-1.2.0",
            .from = "",
        },
        .{
            .name = "shapes",
            .text = "func area() -> i64:\n    return 4\n",
            .path = ".luce/packages/geo-1.2.0/shapes.luc",
            .root = "geo-1.2.0",
            .from = "geo-1.2.0",
        },
        .{ .name = "geo", .text = "import shapes\n", .path = ".luce/packages/geo-1.2.0/geo.luc", .root = "geo-1.2.0" },
    } };
    var diagnostics = Diagnostics.init(testing.allocator);
    defer diagnostics.deinit();
    _ = (try openRoot(&diagnostics, "main.luc", "", "import geo\nimport geo.shapes\n")).?;

    const geo = (try openImport(&diagnostics, table.loader(), sources_mod.root_file, "geo", "geo", .sibling, nowhere)).?;
    const outside = (try openImport(&diagnostics, table.loader(), sources_mod.root_file, "geo.shapes", "shapes", .sibling, nowhere)).?;
    const inside = (try openImport(&diagnostics, table.loader(), geo, "shapes", "shapes", .sibling, nowhere)).?;
    try testing.expectEqual(outside, inside);
    try testing.expectEqual(@as(usize, 3), diagnostics.sources.count());
    try testing.expectEqual(@as(usize, 0), diagnostics.count());

    // A second spelling from a third place cannot re-bind it.
    try testing.expect((try openImport(&diagnostics, table.loader(), sources_mod.root_file, "geo.shapes", "gs", .sibling, nowhere)) == null);
    try testing.expectEqualStrings("luce.import.collision", diagnostics.at(0).?.code);
    try testing.expect(std.mem.indexOf(u8, diagnostics.at(0).?.message, "already imported as shapes") != null);
}

test "the std namespace holds exactly the library, and nothing else" {
    var diagnostics = Diagnostics.init(testing.allocator);
    defer diagnostics.deinit();
    _ = (try openRoot(&diagnostics, "main.luc", "", "import std.nope\n")).?;

    // A module the library does not have: say what it does have.
    try testing.expect((try openImport(&diagnostics, null, sources_mod.root_file, "nope", "nope", .standard, nowhere)) == null);
    try testing.expectEqualStrings("luce.import.standard", diagnostics.at(0).?.code);
    try testing.expect(std.mem.indexOf(u8, diagnostics.at(0).?.message, "std.math") != null);
    try testing.expect(std.mem.indexOf(u8, diagnostics.at(0).?.message, "std.strings") != null);

    // `import std` names the namespace, which is not a module — and no
    // std.luc beside the program can claim it either.
    try testing.expect((try openImport(&diagnostics, null, sources_mod.root_file, "std", "std", .sibling, nowhere)) == null);
    try testing.expectEqualStrings("luce.import.reserved", diagnostics.at(1).?.code);
    try testing.expect(std.mem.indexOf(u8, diagnostics.at(1).?.message, "std.luc") != null);
    // Nothing was registered by either: the root is still the only file.
    try testing.expectEqual(@as(usize, 1), diagnostics.sources.count());
}

test "an imported module is named by the path the host really opened" {
    var table: TableLoader = .{ .entries = &.{
        .{ .name = "geo", .text = "func area() -> i64:\n    return \"no\"\n", .path = "lib/geo.luc" },
        .{ .name = "util", .text = "func twice(v: i64) -> i64:\n    return v * 2\n" },
    } };
    var diagnostics = Diagnostics.init(testing.allocator);
    defer diagnostics.deinit();
    _ = (try openRoot(&diagnostics, "src/main.luc", "", "import geo\n")).?;

    const geo = (try openImport(&diagnostics, table.loader(), sources_mod.root_file, "geo", "geo", .sibling, nowhere)).?;
    try testing.expectEqualStrings("lib/geo.luc", diagnostics.sources.pathOf(geo));
    // A loader with no path to offer still gets the old fallback.
    const util = (try openImport(&diagnostics, table.loader(), sources_mod.root_file, "util", "util", .sibling, nowhere)).?;
    try testing.expectEqualStrings("util.luc", diagnostics.sources.pathOf(util));
}

test "missing and unreadable modules are different diagnostics" {
    var table: TableLoader = .{
        .entries = &.{},
        .locked = &.{"secret"},
    };
    var diagnostics = Diagnostics.init(testing.allocator);
    defer diagnostics.deinit();
    _ = (try openRoot(&diagnostics, "main.luc", "", "import ghost\n")).?;

    try testing.expect((try openImport(&diagnostics, table.loader(), sources_mod.root_file, "ghost", "ghost", .sibling, nowhere)) == null);
    try testing.expectEqualStrings("luce.import.missing", diagnostics.at(0).?.code);

    try testing.expect((try openImport(&diagnostics, table.loader(), sources_mod.root_file, "secret", "secret", .sibling, nowhere)) == null);
    try testing.expectEqualStrings("luce.import.unreadable", diagnostics.at(1).?.code);
    try testing.expect(std.mem.indexOf(u8, diagnostics.at(1).?.message, "permission denied") != null);

    // Without a loader nothing but std can resolve at all.
    try testing.expect((try openImport(&diagnostics, null, sources_mod.root_file, "geo", "geo", .sibling, nowhere)) == null);
    try testing.expectEqualStrings("luce.import.missing", diagnostics.at(2).?.code);
}

test "an imported module that is not text is refused where it was imported" {
    var table: TableLoader = .{ .entries = &.{
        .{ .name = "broken", .text = "func helper():\n    return\x00\n" },
    } };
    var diagnostics = Diagnostics.init(testing.allocator);
    defer diagnostics.deinit();
    _ = (try openRoot(&diagnostics, "main.luc", "", "import broken\n")).?;

    const at: Span = .{ .start = 7, .end = 13 };
    try testing.expect((try openImport(&diagnostics, table.loader(), sources_mod.root_file, "broken", "broken", .sibling, at)) == null);
    try testing.expectEqualStrings("luce.source.binary", diagnostics.at(0).?.code);
    // The span points at the import statement in the file that wrote
    // it, since the broken file has no positions to point at.
    try testing.expectEqual(@as(usize, 7), diagnostics.at(0).?.span.start);
    try testing.expectEqual(sources_mod.root_file, diagnostics.at(0).?.file);
}

test "an import that resolves back to the importing file is a self-import" {
    // main.luc writing `import main` used to load the whole program a
    // second time under a prefix — every function twice, silently.
    var table: TableLoader = .{ .entries = &.{
        .{ .name = "main", .text = "func main():\n    return\n", .path = "sub/main.luc" },
    } };
    var diagnostics = Diagnostics.init(testing.allocator);
    defer diagnostics.deinit();
    _ = (try openRoot(&diagnostics, "sub/main.luc", "", "import main\n")).?;

    try testing.expect((try openImport(&diagnostics, table.loader(), sources_mod.root_file, "main", "main", .sibling, nowhere)) == null);
    try testing.expectEqualStrings("luce.import.self", diagnostics.at(0).?.code);
    try testing.expectEqual(@as(usize, 1), diagnostics.sources.count());
}

// Property fuzzing: the loader is the compiler's outermost door, so
// the invariant worth proving is that there is no third answer.  Under
// `zig build test` this runs the corpus; `zig build test --fuzz`
// explores from it.
test "fuzz: any bytes either register as trustworthy text or report" {
    try testing.fuzz({}, loadAnything, .{ .corpus = &.{
        "func main():\n    return\n",
        "\xEF\xBB\xBFimport geo\r\n",
        "\xFE\xFF\x00f\x00u\x00n",
        "import geo\n\x00",
        "a\rb",
        "\xC0\xAF",
        "",
    } });
}

fn loadAnything(_: void, smith: *testing.Smith) anyerror!void {
    var root_buffer: [256]u8 = undefined;
    var module_buffer: [256]u8 = undefined;
    const weights = [_]testing.Smith.Weight{
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .rangeAtMost(u8, 0x20, 0x7e, 4),
        .value(u8, 0x00, 3),
        .value(u8, 0xff, 3),
        .value(u8, 0xfe, 3),
        .value(u8, '\n', 4),
        .value(u8, '\r', 4),
    };
    const root_bytes = root_buffer[0..smith.sliceWeightedBytes(&root_buffer, &weights)];
    const module_bytes = module_buffer[0..smith.sliceWeightedBytes(&module_buffer, &weights)];

    var table: TableLoader = .{ .entries = &.{.{ .name = "geo", .text = module_bytes }} };
    var diagnostics = Diagnostics.init(testing.allocator);
    defer diagnostics.deinit();

    const root = try openRoot(&diagnostics, "main.luc", "", root_bytes);
    if (root == null) {
        // Refused: something was said, and nothing was kept.
        try testing.expect(diagnostics.count() != 0);
        try testing.expectEqual(@as(usize, 0), diagnostics.sources.count());
        return;
    }
    _ = try openImport(&diagnostics, table.loader(), root.?, "geo", "geo", .sibling, nowhere);
    // Whatever happened, every file that made it into the registry is
    // one later stages may trust, and every diagnostic still renders.
    for (0..diagnostics.sources.count()) |index| {
        const text = diagnostics.sources.textOf(@intCast(index));
        try testing.expect(std.unicode.utf8ValidateSlice(text));
        try testing.expect(std.mem.indexOfScalar(u8, text, 0) == null);
        try testing.expect(std.mem.indexOfScalar(u8, text, '\r') == null);
    }
    const rendered = try diagnostics.render(testing.allocator);
    testing.allocator.free(rendered);
}
