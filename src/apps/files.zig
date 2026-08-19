//! File access shared by the luce and loom executables: whole-file
//! reads and writes, reading a source file, the import loader that
//! resolves `import name` as NAME.luc — beside the root source file
//! for a rootless program, under the project root when a `luce.yaml`
//! governs, with `import a.b` mapping dots to folders under that root
//! (docs/PACKAGES.md D1, D2) — and project discovery, the walk that
//! finds the `luce.yaml` governing a root source file.  One copy, so
//! the two programs can never drift on how imports resolve or on what
//! counts as an unreadable file.
//!
//! Only the sibling namespace reaches here: `import std.NAME` is
//! answered by the compiler's own table and is never asked of a host,
//! so a std.luc or a math.luc in the directory is nothing this file
//! has to think about.
//!
//! This is the reference host behind stage 1's `Loader` seam, and it
//! carries the two obligations the compiler cannot check for itself
//! (`source/load.zig`):
//!
//!   * **the match is exact.**  A case-insensitive filesystem — the
//!     macOS default, Windows, a case-folding ext4 directory — will
//!     open `Geo.luc` when asked for `geo.luc`, so `import geo`
//!     compiles here and fails on the build machine.  Every import is
//!     checked against the real directory entry, which is how Python
//!     defends the same ground (`importlib._bootstrap_external`'s
//!     `_fill_cache` / `_relax_case`).  Unlike Python there is no
//!     `PYTHONCASEOK` escape: a name that only resolves on some
//!     filesystems is a bug on all of them.
//!   * **an import is a regular file.**  A fifo answers zero bytes and
//!     would register as an empty module, which then fails as a
//!     baffling unknown name.
//!
//! The *root* is deliberately permissive: it is a path the user typed,
//! not one the compiler derived, and it is allowed to be a pipe, a
//! process substitution, or `-` for standard input, because a
//! formatter or an editor has nothing else to offer.

const std = @import("std");
const luce = @import("luce");
const manifest = @import("manifest.zig");

// Package commands use the same parser and file name as the loader. These
// aliases keep one manifest module in the build graph; importing the source
// file a second time through a separate CLI module would make Zig reject the
// duplicate module ownership.
pub const ProjectManifest = manifest.Manifest;
pub const ManifestEntry = manifest.Entry;
pub const manifest_file_name = manifest.file_name;
pub const parseManifest = manifest.parse;

const Allocator = std.mem.Allocator;

/// The path that means standard input, by the convention every Unix
/// tool shares.
pub const standard_input = "-";

/// How a diagnostic should name the root when it came from a stream.
pub const standard_input_name = "<stdin>";

/// What to print for `path`: itself, or `<stdin>` for `-`.  The name
/// reaches diagnostics and trap traces, so it must not be a `-`.
pub fn displayName(path: []const u8) []const u8 {
    return if (std.mem.eql(u8, path, standard_input)) standard_input_name else path;
}

const too_large = std.fmt.comptimePrint(
    "it is larger than the {d} MiB limit",
    .{luce.source.max_bytes >> 20},
);

/// Read the program's own source: the bytes, or why there are none.
///
/// `-` means standard input.  Anything that is not a seekable regular
/// file — a pipe, a fifo, a `<(...)` process substitution — is read as
/// a stream, because `luce check` on a generated file is table stakes
/// for editor and formatter integration and there is no size to ask
/// for in advance.
///
/// For a regular file the size limit is still checked *before* the
/// read, not after: `luce build` pointed at an 8 GB file answers with
/// a diagnostic rather than an out-of-memory kill.  A stream is capped
/// as it is read, which is the earliest anything can be known.
///
/// Bytes are allocated from `allocator` and belong to the caller; the
/// compiler copies them, so they may be freed as soon as it has.
/// Every `unreadable` reason is a static string — there is nothing
/// else to free on the failure paths.
pub fn readSource(allocator: Allocator, io: std.Io, path: []const u8) error{OutOfMemory}!luce.source.Found {
    if (std.mem.eql(u8, path, standard_input)) {
        return readStream(allocator, io, std.Io.File.stdin(), standard_input_name);
    }
    const file = std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false }) catch |mistake| {
        return failure(mistake);
    };
    defer file.close(io);
    // stat, not length: a pipe has no length and answers Unseekable.
    const info = file.stat(io) catch |mistake| switch (mistake) {
        error.Streaming => return readStream(allocator, io, file, path),
        else => return failure(mistake),
    };
    if (info.kind != .file) return readStream(allocator, io, file, path);
    if (info.size > luce.source.max_bytes) return .{ .unreadable = too_large };
    return readWholeFile(allocator, io, file, path, @intCast(info.size));
}

/// Read a regular file whose size is already known to fit.
///
/// Every answer but `.text` frees the buffer on the way out: for the
/// root that allocator is the compiler's rather than an arena, so a
/// short read used to leak the whole file.
fn readWholeFile(
    allocator: Allocator,
    io: std.Io,
    file: std.Io.File,
    path: []const u8,
    size: usize,
) error{OutOfMemory}!luce.source.Found {
    const content = try allocator.alloc(u8, size);
    const loaded = file.readPositionalAll(io, content, 0) catch |mistake| {
        allocator.free(content);
        return failure(mistake);
    };
    if (loaded != content.len) {
        allocator.free(content);
        return .{ .unreadable = "it changed size while being read" };
    }
    return .{ .text = .{ .bytes = content, .path = path } };
}

/// Read something with no size to ask for: standard input, a pipe, a
/// process substitution.  Capped at the same limit, refused the moment
/// it is passed rather than after the whole thing is in memory.
fn readStream(
    allocator: Allocator,
    io: std.Io,
    file: std.Io.File,
    path: []const u8,
) error{OutOfMemory}!luce.source.Found {
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const content = reader.interface.allocRemaining(
        allocator,
        .limited(luce.source.max_bytes),
    ) catch |mistake| switch (mistake) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return .{ .unreadable = too_large },
        else => return .{ .unreadable = "it could not be read to the end" },
    };
    return .{ .text = .{ .bytes = content, .path = path } };
}

/// Turn a file-system error into the answer stage 1 expects: absent is
/// the ordinary case, everything else is a reason a human can read.
fn failure(mistake: anyerror) luce.source.Found {
    return switch (mistake) {
        error.FileNotFound => .missing,
        error.IsDir => .{ .unreadable = "it is a directory" },
        error.NotDir => .{ .unreadable = "part of the path is not a directory" },
        error.AccessDenied, error.PermissionDenied => .{ .unreadable = "permission denied" },
        error.NameTooLong => .{ .unreadable = "the path is too long" },
        error.SymLinkLoop => .{ .unreadable = "the path loops through symbolic links" },
        else => .{ .unreadable = @errorName(mistake) },
    };
}

// ---------------------------------------------------------------------------
// The project root
// ---------------------------------------------------------------------------

/// What governs a compile: the project whose `luce.yaml` was found by
/// walking up from the root source file's directory, or nothing
/// (docs/PACKAGES.md D1).
pub const Project = union(enum) {
    /// No luce.yaml between the root file's directory and the
    /// filesystem root.  The current behaviour, and nothing changes:
    /// a single directory of .luc files stays exactly as cheap as it
    /// is today.
    rootless,
    /// A luce.yaml governs.  Everything in it is allocated from the
    /// arena `discoverProject` was handed and lives as long as that
    /// arena; the loader borrows both for the compile.
    governed: Governed,
    /// A luce.yaml was found and could not be a manifest.  Refused,
    /// never skipped: skipping would silently change which root
    /// governs, and a broken manifest is a fact about the project, not
    /// about this one compile.  The message names the file and, when
    /// there is one, the line; allocated from the arena.
    refused: []const u8,
};

/// A discovered project: the root, and the manifest that marked it.
pub const Governed = struct {
    /// The directory that holds luce.yaml — the opaque root token the
    /// compile is given as `CompileOptions.source_root`.
    root: []const u8,
    /// The parsed want list the store probes are gated by (D3).
    manifest: manifest.Manifest,
};

/// Find the project governing `root_path` — the root source file as
/// the user typed it.
///
/// The walk is *lexical*: the path as typed, never a realpath, so a
/// symlinked directory resolves against the tree the author addressed
/// rather than the tree the link points into.  A relative path is
/// anchored under the current directory by spelling — a join, not a
/// resolution — and the walk continues to the filesystem root, the
/// way go.mod is found.  Pathless roots get no discovery: standard
/// input compiles rootless wherever it is piped from.
pub fn discoverProject(arena: Allocator, io: std.Io, root_path: []const u8) error{OutOfMemory}!Project {
    if (std.mem.eql(u8, root_path, standard_input)) return .rootless;
    const directory = std.fs.path.dirname(root_path) orelse "";

    const start = if (std.fs.path.isAbsolute(directory))
        directory
    else anchored: {
        const here = std.process.currentPathAlloc(io, arena) catch |mistake| switch (mistake) {
            error.OutOfMemory => return error.OutOfMemory,
            // A process whose working directory has no name cannot
            // anchor a relative walk; it compiles rootless rather
            // than guessing.
            else => return .rootless,
        };
        if (directory.len == 0) break :anchored @as([]const u8, here);
        break :anchored try std.fs.path.join(arena, &.{ here, directory });
    };

    var current: []const u8 = start;
    while (true) {
        const candidate = try std.fs.path.join(arena, &.{ current, manifest.file_name });
        found: {
            const info = std.Io.Dir.cwd().statFile(io, candidate, .{}) catch
                // Not there, or an ancestor that cannot be asked —
                // neither is a manifest, and refusing on an
                // unreadable ancestor would fail every build below
                // it.  The walk continues.
                break :found;
            if (info.kind != .file) {
                return .{ .refused = try std.fmt.allocPrint(
                    arena,
                    "{s} is not a project manifest: {s}",
                    .{ candidate, describe(info.kind) },
                ) };
            }
            return readManifest(arena, io, current, candidate);
        }
        current = std.fs.path.dirname(current) orelse return .rootless;
    }
}

/// Read and validate a manifest the walk found.  In this step a valid
/// manifest only establishes the root; the want list starts resolving
/// when the store does.
fn readManifest(arena: Allocator, io: std.Io, directory: []const u8, path: []const u8) error{OutOfMemory}!Project {
    const text = readWhole(arena, io, path) catch |mistake| switch (mistake) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .refused = try std.fmt.allocPrint(
            arena,
            "{s} cannot be read: {s}",
            .{ path, @errorName(mistake) },
        ) },
    };
    switch (try manifest.parse(arena, text)) {
        // The token is duped so it never borrows the caller's path.
        // The manifest borrows `text`, which the same arena owns.
        .manifest => |parsed| return .{ .governed = .{
            .root = try arena.dupe(u8, directory),
            .manifest = parsed,
        } },
        .refused => |refusal| {
            if (refusal.line == 0) {
                return .{ .refused = try std.fmt.allocPrint(
                    arena,
                    "{s}: {s}",
                    .{ path, refusal.reason },
                ) };
            }
            return .{ .refused = try std.fmt.allocPrint(
                arena,
                "{s}:{d}: {s}",
                .{ path, refusal.line, refusal.reason },
            ) };
        },
    }
}

// ---------------------------------------------------------------------------
// Imports
// ---------------------------------------------------------------------------

/// What a directory really holds for a name the compiler asked for.
const NameMatch = union(enum) {
    /// A directory entry spelled exactly that way.
    exact,
    /// An entry differing only in case.  A case-insensitive filesystem
    /// would open it and the next machine would not; carries the real
    /// spelling, so the message can name the file to rename.
    case_variant: []const u8,
    absent,
    /// The directory could not be listed — a permission, a race.
    /// Nothing can be said, so nothing is.
    unknown,
};

/// Ask the directory itself what it holds, rather than trusting an
/// `open` that a case-folding filesystem answered generously.
///
/// The scan stops at an exact match, so the ordinary path reads as
/// much of the directory as it takes to find the file.
fn matchName(
    io: std.Io,
    arena: Allocator,
    directory: []const u8,
    wanted: []const u8,
) error{OutOfMemory}!NameMatch {
    // cwd() cannot be iterated; "." can.
    const where = if (directory.len == 0) "." else directory;
    var dir = std.Io.Dir.cwd().openDir(io, where, .{ .iterate = true }) catch return .unknown;
    defer dir.close(io);

    var variant: ?[]const u8 = null;
    var entries = dir.iterate();
    while (entries.next(io) catch return .unknown) |entry| {
        if (std.mem.eql(u8, entry.name, wanted)) return .exact;
        if (variant == null and std.ascii.eqlIgnoreCase(entry.name, wanted)) {
            variant = try arena.dupe(u8, entry.name);
        }
    }
    if (variant) |real| return .{ .case_variant = real };
    return .absent;
}

/// What one probe of one tier found for a module name: the file that
/// would answer, nothing, or a reason the probe cannot be walked.
const Probe = union(enum) {
    /// The module file exists at this path; nothing is read yet —
    /// existence has to be known for *every* tier before any one of
    /// them may answer (D3).
    answer: struct { path: []const u8, root: []const u8 },
    missing,
    /// A case variant, a file where a folder should be — today's
    /// refusals, kept verbatim.
    broken: []const u8,
};

/// Loads `import name` as NAME.luc — next to the root source file for
/// a rootless program; under a `luce.yaml`, by probing every tier D3
/// names: the project tree, the store (`.luce/packages/`), and the
/// `LUCE_LIB` shelves, exactly one of which may answer.
///
/// **One anchor per mode** (docs/PACKAGES.md D1): under a `luce.yaml`
/// every import is project-root-relative, the single-segment form
/// included, so `import geo` means the same file from every file in
/// the tree.  `import a.b` maps dots to folders under that root and
/// keeps both Loader obligations at every level — the match exact,
/// and only the last segment a regular file.  Without a root the
/// sibling behaviour is exactly what it always was, single segment
/// only: a folder path needs the anchor, and the refusal names
/// `luce.yaml` as what provides one.
///
/// **A package's files anchor to the package** (D4): an import
/// written inside a package resolves against the package's own tree
/// and its own want list, never the consumer's project — the opaque
/// root token the compiler hands back (`from_root`) is what says
/// where an import was written, and the loader is the only side that
/// interprets it.
///
/// Ownership: the loader itself borrows everything it is given
/// (`project`, `shelves`, `alerts` must outlive it); the resolved
/// package table is its own and `deinit` frees it.
pub const FileLoader = struct {
    io: std.Io,
    /// The root source file's directory — where a *rootless* program's
    /// imports resolve.
    directory: []const u8,
    /// The discovered project root (`discoverProject`'s token), or ""
    /// when no `luce.yaml` governs.  The same string the compile got
    /// as `CompileOptions.source_root`.
    project_root: []const u8 = "",
    /// The governing manifest (`discoverProject`'s), or null.  The
    /// want list in it is the gate on every store and shelf probe: a
    /// package it does not name is unresolvable from any of them (D3).
    project: ?manifest.Manifest = null,
    /// The `LUCE_LIB` shelves, in the order the variable names them
    /// (`splitSearchPath`).  Empty when unset.
    shelves: []const []const u8 = &.{},
    /// Where the loud lines go — a resolution from a shelf or a
    /// `path:` override says so here, one line, every build (D3),
    /// because those bytes are outside the project's control.  Null is
    /// silent (rootless programs never resolve one).
    alerts: ?*std.Io.Writer = null,
    /// Allocator for the resolved package table; must be given when
    /// `project` names packages.
    gpa: ?Allocator = null,
    /// The transitive package set, resolved once per compile on first
    /// need (`resolvePackages`).
    resolved: ?Packages = null,

    pub fn deinit(self: *FileLoader) void {
        if (self.resolved) |*packages| packages.arena.deinit();
        self.resolved = null;
    }

    fn load(context: *anyopaque, arena: Allocator, name: []const u8, from_root: []const u8) error{OutOfMemory}!luce.source.Found {
        const self: *FileLoader = @ptrCast(@alignCast(context));
        const rooted = self.project_root.len != 0;

        if (!rooted) {
            // Rootless: the sibling behaviour, byte for byte.
            if (std.mem.indexOfScalar(u8, name, '.') != null) {
                return .{
                    .unreadable = "subfolder imports need a project root, " ++
                        "and no luce.yaml governs this program",
                };
            }
            return switch (try probeTree(self.io, arena, self.directory, name, from_root)) {
                .answer => |found| try self.open(arena, found.path, found.root),
                .missing => .missing,
                .broken => |why| .{ .unreadable = why },
            };
        }

        // Which anchor the import was written under: the project, or a
        // package (D1, D4).  The token is the loader's own vocabulary
        // coming back — the compiler never interprets it.
        var anchor: []const u8 = self.project_root;
        var anchor_root: []const u8 = from_root;
        var wants: []const manifest.Entry = if (self.project) |governing| governing.packages else &.{};
        if (!std.mem.eql(u8, from_root, self.project_root)) {
            const packages = try self.resolvePackages();
            if (packages.state == .refused) return .{ .refused = packages.state.refused };
            const inside = self.findResolved(from_root) orelse return .missing;
            anchor = inside.directory;
            anchor_root = inside.token;
            wants = inside.wants;
        }

        // Tier one: the tree under the anchor.
        const tree = try probeTree(self.io, arena, anchor, name, anchor_root);
        if (tree == .broken) return .{ .unreadable = tree.broken };

        // Tier two: the store and the shelves, gated by the want list.
        const head = name[0..(std.mem.indexOfScalar(u8, name, '.') orelse name.len)];
        var store: Probe = .missing;
        var store_expected: ?[]const u8 = null;
        if (wantOf(wants, head) != null) {
            const packages = try self.resolvePackages();
            switch (packages.state) {
                .refused => |refusal| return .{ .refused = refusal },
                .table => |table| for (table) |*entry| {
                    if (!std.mem.eql(u8, entry.name, head)) continue;
                    store = try probePackage(self.io, arena, entry, name);
                    if (store == .broken) return .{ .unreadable = store.broken };
                    store_expected = try packagePath(arena, entry.directory, name);
                    break;
                },
            }
        }

        // Exactly one probe may answer (D3).
        if (tree == .answer and store == .answer) {
            const places = try arena.alloc([]const u8, 2);
            places[0] = tree.answer.path;
            places[1] = store.answer.path;
            return .{ .ambiguous = places };
        }
        if (tree == .answer) return try self.open(arena, tree.answer.path, tree.answer.root);
        if (store == .answer) return try self.open(arena, store.answer.path, store.answer.root);
        if (store_expected) |expected| {
            // Two places were probed, so the refusal names both,
            // verbatim (D6).
            return .{ .refused = .{
                .code = "luce.import.missing",
                .message = try std.fmt.allocPrint(
                    arena,
                    "cannot load module {s} (looked for {s} and {s})",
                    .{ name, try treePath(arena, anchor, name), expected },
                ),
            } };
        }
        return .missing;
    }

    /// Read an answering module file — the stat-then-open ritual that
    /// keeps a fifo from hanging the compiler and a directory from
    /// registering as an empty module.
    fn open(self: *FileLoader, arena: Allocator, path: []const u8, root: []const u8) error{OutOfMemory}!luce.source.Found {
        // Stat the *path*, before opening it.  A fifo answers zero
        // bytes and would register as an empty module — but worse than
        // that, opening a fifo for reading blocks until someone opens
        // the other end, so `luce check` on a directory with a stray
        // fifo in it would simply hang.  The check has to come first.
        // (Stat then open leaves a window a fifo could be created in;
        // std.Io has no non-blocking open, and anyone who can create
        // files in your source directory can edit your source.)
        const info = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch |mistake| {
            return failure(mistake);
        };
        if (info.kind != .file) return .{ .unreadable = describe(info.kind) };
        if (info.size > luce.source.max_bytes) return .{ .unreadable = too_large };

        const file = std.Io.Dir.cwd().openFile(self.io, path, .{ .allow_directory = false }) catch |mistake| {
            return failure(mistake);
        };
        defer file.close(self.io);
        var found = try readWholeFile(arena, self.io, file, path, @intCast(info.size));
        if (found == .text) found.text.root = root;
        return found;
    }

    fn findResolved(self: *const FileLoader, token: []const u8) ?*const ResolvedPackage {
        const packages = &(self.resolved orelse return null);
        switch (packages.state) {
            .refused => return null,
            .table => |table| for (table) |*entry| {
                if (std.mem.eql(u8, entry.token, token)) return entry;
            },
        }
        return null;
    }

    /// Resolve the whole transitive package set, once per compile
    /// (D3, D4): locate every wanted package, hold its directory name
    /// and its manifest to agreement, verify every stated hash, refuse
    /// diamonds the root's `override:` does not settle — and say out
    /// loud, on standard error, every resolution the project file
    /// alone could not predict.
    fn resolvePackages(self: *FileLoader) error{OutOfMemory}!*const Packages {
        if (self.resolved != null) return &self.resolved.?;
        const gpa = self.gpa orelse {
            // A loader built without an allocator cannot hold a table;
            // said as what it is rather than answered as "missing",
            // which would send the reader to check their store.
            self.resolved = .{
                .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
                .state = .{ .refused = .{
                    .code = "luce.import.missing",
                    .message = "this loader was built without an allocator for the package store",
                } },
            };
            return &self.resolved.?;
        };
        self.resolved = .{ .arena = std.heap.ArenaAllocator.init(gpa), .state = .{ .table = &.{} } };
        const packages = &self.resolved.?;
        packages.state = try resolveClosure(self, packages.arena.allocator());
        return packages;
    }

    /// One loud line to standard error — the visibility rule on every
    /// resolution the project file alone cannot predict (D3).  Best
    /// effort: a closed stderr does not stop a build.
    fn announce(self: *FileLoader, comptime format: []const u8, arguments: anytype) void {
        const out = self.alerts orelse return;
        out.print(format ++ "\n", arguments) catch return;
        out.flush() catch {};
    }

    pub fn loader(self: *FileLoader) luce.compile.Loader {
        return .{ .context = self, .load = load };
    }
};

// ---------------------------------------------------------------------------
// The store, the shelves, and the transitive want set
// ---------------------------------------------------------------------------

/// One package the closure resolved: where it is, what it wants, and
/// the stable token its files' imports come back under.  Everything in
/// it lives in the `Packages` arena.
const ResolvedPackage = struct {
    name: []const u8,
    version: []const u8,
    /// `name-version` — the opaque root token stamped on every module
    /// answered from this package.  Stable across machines and across
    /// store/shelf/`path:` locations, which is what keeps serialized
    /// root-qualified names (docs/PACKAGES.md D7) and the artifact
    /// hash machine-independent.
    token: []const u8,
    directory: []const u8,
    origin: enum { store, shelf, path_override },
    /// The package's own want list (its luce.yaml's `packages:`), the
    /// gate for imports written inside it.
    wants: []const manifest.Entry,
    /// Who asked for it — "luce.yaml", or "geo 1.2.0" — for the
    /// diamond refusal that has to name both edges.
    wanted_by: []const u8,
    /// The directory's content hash, computed at most once.
    hashed: ?[64]u8 = null,
};

/// The resolved transitive set, or the one refusal every package
/// import now answers with.  Owned by the loader (`FileLoader.deinit`).
const Packages = struct {
    arena: std.heap.ArenaAllocator,
    state: State,

    const State = union(enum) {
        table: []ResolvedPackage,
        refused: luce.source.Found.Refusal,
    };
};

/// The want-list row for `name`, or null — the gate itself: a package
/// the manifest does not name is unresolvable from any store or shelf
/// (D3).
fn wantOf(wants: []const manifest.Entry, name: []const u8) ?*const manifest.Entry {
    for (wants) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

fn overrideFor(overrides: []const manifest.Entry, name: []const u8) ?*const manifest.Entry {
    for (overrides) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

/// Split a `LUCE_LIB` value into its shelf directories: colon-separated
/// (semicolon on Windows), empty entries dropped.  The slices borrow
/// `text`.
pub fn splitSearchPath(arena: Allocator, text: []const u8) error{OutOfMemory}![]const []const u8 {
    var entries: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, text, std.fs.path.delimiter);
    while (parts.next()) |part| {
        if (part.len != 0) try entries.append(arena, part);
    }
    return entries.toOwnedSlice(arena);
}

/// Walk the whole transitive want set (docs/PACKAGES.md D4).  Answers
/// the table, or the first refusal met — allocated from `arena`, which
/// outlives every load that reads it.
fn resolveClosure(self: *FileLoader, arena: Allocator) error{OutOfMemory}!Packages.State {
    const governing = self.project orelse return .{ .table = &.{} };
    var table: std.ArrayList(ResolvedPackage) = .empty;

    const Edge = struct {
        entry: manifest.Entry,
        wanted_by: []const u8,
        from_root: bool,
    };
    var queue: std.ArrayList(Edge) = .empty;
    defer queue.deinit(arena);
    for (governing.packages) |entry| {
        try queue.append(arena, .{ .entry = entry, .wanted_by = "luce.yaml", .from_root = true });
    }

    var next: usize = 0;
    while (next < queue.items.len) : (next += 1) {
        var edge = queue.items[next];

        // `override:` is the root's stated decision and it is final,
        // loudly (D4, D6): the pinned version replaces the edge's, and
        // the pin's own annotations travel with it.
        if (overrideFor(governing.override, edge.entry.name)) |pinned| {
            if (!std.mem.eql(u8, pinned.version, edge.entry.version)) {
                self.announce("package {s}: override: pins {s} over {s} (wanted by {s})", .{
                    edge.entry.name, pinned.version, edge.entry.version, edge.wanted_by,
                });
                edge.entry.version = pinned.version;
            }
            if (pinned.path) |chosen| edge.entry.path = chosen;
            if (pinned.sha256) |stated| edge.entry.sha256 = stated;
        }

        // `path:` keeps every resolution decision in the one file — the
        // root's (D3); a package cannot redirect its own dependencies.
        if (!edge.from_root and edge.entry.path != null) {
            return refuseClosure(arena, "luce.import.version", "package {s} wants {s} with a path: annotation, and path: is the root luce.yaml's decision", .{
                edge.wanted_by, edge.entry.name,
            });
        }

        // A name already resolved either agrees or is a diamond; an
        // extra stated hash is still verified against the one
        // directory (D1).
        if (findPackage(table.items, edge.entry.name)) |already| {
            if (!std.mem.eql(u8, already.version, edge.entry.version)) {
                return refuseClosure(arena, "luce.import.diamond", "package {s} is wanted at {s} by {s} and at {s} by {s}; name the decision in the root luce.yaml's override: section", .{
                    edge.entry.name, already.version, already.wanted_by, edge.entry.version, edge.wanted_by,
                });
            }
            if (edge.entry.sha256) |stated| {
                if (try verifyHash(self, arena, already, stated)) |refusal| return refusal;
            }
            continue;
        }

        // Locate: the store (or the root's `path:`, which replaces
        // exactly that probe), plus every shelf — and exactly one may
        // answer (D3).
        const token = try std.fmt.allocPrint(arena, "{s}-{s}", .{ edge.entry.name, edge.entry.version });
        const Candidate = struct { directory: []const u8, origin: @FieldType(ResolvedPackage, "origin") };
        var candidates: std.ArrayList(Candidate) = .empty;
        defer candidates.deinit(arena);
        if (edge.entry.path) |chosen| {
            const directory = if (std.fs.path.isAbsolute(chosen))
                chosen
            else
                try std.fs.path.join(arena, &.{ self.project_root, chosen });
            try candidates.append(arena, .{ .directory = directory, .origin = .path_override });
        } else {
            try candidates.append(arena, .{
                .directory = try std.fs.path.join(arena, &.{ self.project_root, ".luce", "packages", token }),
                .origin = .store,
            });
        }
        for (self.shelves) |shelf| {
            try candidates.append(arena, .{
                .directory = try std.fs.path.join(arena, &.{ shelf, token }),
                .origin = .shelf,
            });
        }

        var found: std.ArrayList(Candidate) = .empty;
        defer found.deinit(arena);
        for (candidates.items) |candidate| {
            const info = std.Io.Dir.cwd().statFile(self.io, candidate.directory, .{}) catch continue;
            if (info.kind == .directory) try found.append(arena, candidate);
        }
        if (found.items.len == 0) {
            const looked = try joinDirectories(arena, candidates.items.len, candidates.items);
            return refuseClosure(arena, "luce.import.missing", "package {s} {s} is not in the store (looked in {s})", .{
                edge.entry.name, edge.entry.version, looked,
            });
        }
        if (found.items.len > 1) {
            const answering = try joinDirectories(arena, found.items.len, found.items);
            return refuseClosure(arena, "luce.import.ambiguous", "package {s} {s} answers in more than one place: {s}; exactly one may answer", .{
                edge.entry.name, edge.entry.version, answering,
            });
        }
        const chosen = found.items[0];

        // The manifest inside must agree with what was asked for, or
        // the package is refused by name (D4) — the artifact tag's
        // tell-the-truth-or-be-refused rule.
        const manifest_path = try std.fs.path.join(arena, &.{ chosen.directory, manifest.file_name });
        const text = readWhole(arena, self.io, manifest_path) catch {
            return refuseClosure(arena, "luce.import.version", "package {s} {s} at {s} has no luce.yaml; a package is a directory with its own manifest", .{
                edge.entry.name, edge.entry.version, chosen.directory,
            });
        };
        const inside = switch (try manifest.parse(arena, text)) {
            .manifest => |parsed| parsed,
            .refused => |refusal| {
                if (refusal.line == 0) {
                    return refuseClosure(arena, "luce.import.version", "package {s} {s} at {s}: luce.yaml: {s}", .{
                        edge.entry.name, edge.entry.version, chosen.directory, refusal.reason,
                    });
                }
                return refuseClosure(arena, "luce.import.version", "package {s} {s} at {s}: luce.yaml:{d}: {s}", .{
                    edge.entry.name, edge.entry.version, chosen.directory, refusal.line, refusal.reason,
                });
            },
        };
        if (!std.mem.eql(u8, inside.name, edge.entry.name) or
            !std.mem.eql(u8, inside.version, edge.entry.version))
        {
            return refuseClosure(arena, "luce.import.version", "package {s} {s} at {s}: its luce.yaml says {s} {s}; the directory and its manifest must agree", .{
                edge.entry.name, edge.entry.version, chosen.directory, inside.name, inside.version,
            });
        }
        if (inside.override.len != 0) {
            return refuseClosure(arena, "luce.import.version", "package {s} {s} at {s}: its luce.yaml has an override: section, and override: is the root luce.yaml's decision", .{
                edge.entry.name, edge.entry.version, chosen.directory,
            });
        }

        // A resolution the project file alone cannot predict is at
        // least visible: one line, standard error, every build (D3).
        switch (chosen.origin) {
            .store => {},
            .shelf => self.announce("package {s} {s}: resolved outside the project, from LUCE_LIB shelf {s}", .{
                edge.entry.name, edge.entry.version, chosen.directory,
            }),
            .path_override => self.announce("package {s} {s}: resolved outside the store, from path: {s}", .{
                edge.entry.name, edge.entry.version, chosen.directory,
            }),
        }

        try table.append(arena, .{
            .name = try arena.dupe(u8, edge.entry.name),
            .version = try arena.dupe(u8, edge.entry.version),
            .token = token,
            .directory = chosen.directory,
            .origin = chosen.origin,
            .wants = inside.packages,
            .wanted_by = edge.wanted_by,
        });

        if (edge.entry.sha256) |stated| {
            if (try verifyHash(self, arena, &table.items[table.items.len - 1], stated)) |refusal| return refusal;
        }

        const requirer = try std.fmt.allocPrint(arena, "{s} {s}", .{ edge.entry.name, edge.entry.version });
        for (inside.packages) |onward| {
            try queue.append(arena, .{ .entry = onward, .wanted_by = requirer, .from_root = false });
        }
    }
    return .{ .table = try table.toOwnedSlice(arena) };
}

fn findPackage(table: []ResolvedPackage, name: []const u8) ?*ResolvedPackage {
    for (table) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

fn refuseClosure(
    arena: Allocator,
    code: []const u8,
    comptime format: []const u8,
    arguments: anytype,
) error{OutOfMemory}!Packages.State {
    return .{ .refused = .{
        .code = code,
        .message = try std.fmt.allocPrint(arena, format, arguments),
    } };
}

fn joinDirectories(arena: Allocator, count: usize, candidates: anytype) error{OutOfMemory}![]const u8 {
    var names = try arena.alloc([]const u8, count);
    for (candidates, 0..) |candidate, index| names[index] = candidate.directory;
    return std.mem.join(arena, " and ", names);
}

/// Verify a stated `sha256:` against the package directory's content
/// hash (docs/PACKAGES.md D1).  Answers the refusal when they do not
/// agree, null when they do; the hash is computed at most once per
/// package.
fn verifyHash(
    self: *FileLoader,
    arena: Allocator,
    package: *ResolvedPackage,
    stated: []const u8,
) error{OutOfMemory}!?Packages.State {
    if (!isHexDigest(stated)) {
        return try refuseClosure(arena, "luce.import.version", "package {s} {s}: sha256:{s} is not a sha256 hash; the value is 64 hex digits", .{
            package.name, package.version, stated,
        });
    }
    if (package.hashed == null) {
        package.hashed = hashPackageDirectory(self.io, arena, package.directory) catch |mistake| switch (mistake) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unreadable => {
                return try refuseClosure(arena, "luce.import.version", "package {s} {s} at {s} cannot be hashed: a file in it cannot be read", .{
                    package.name, package.version, package.directory,
                });
            },
        };
    }
    const computed = &package.hashed.?;
    if (!std.ascii.eqlIgnoreCase(computed, stated)) {
        return try refuseClosure(arena, "luce.import.version", "package {s} {s} at {s} does not match its stated hash: luce.yaml says sha256:{s}, the directory hashes to sha256:{s}", .{
            package.name, package.version, package.directory, stated, computed,
        });
    }
    return null;
}

fn isHexDigest(text: []const u8) bool {
    if (text.len != 64) return false;
    for (text) |character| {
        if (!std.ascii.isHex(character)) return false;
    }
    return true;
}

/// The content hash of a package directory: SHA-256 over every regular
/// file, taken in sorted relative-path order, each contributing its
/// path, a NUL, its length and its bytes — so a renamed, added,
/// removed or edited file all move the digest, and the walk order of
/// the filesystem never does.  The algorithm is the one the manifest
/// value's prefix states (`sha256:`, docs/PACKAGES.md D1).
pub fn hashPackageDirectory(
    io: std.Io,
    arena: Allocator,
    directory: []const u8,
) error{ OutOfMemory, Unreadable }![64]u8 {
    var relative_paths: std.ArrayList([]const u8) = .empty;
    defer relative_paths.deinit(arena);
    try collectFiles(io, arena, directory, "", &relative_paths);
    std.mem.sort([]const u8, relative_paths.items, {}, stringAscending);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (relative_paths.items) |relative| {
        const full = try std.fs.path.join(arena, &.{ directory, relative });
        const content = readWhole(arena, io, full) catch |mistake| switch (mistake) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Unreadable,
        };
        hasher.update(relative);
        hasher.update(&[_]u8{0});
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, content.len, .little);
        hasher.update(&length);
        hasher.update(content);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn stringAscending(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

/// Every regular file under `base`, as relative paths with `/`
/// separators.  Directories recurse; anything else (a fifo, a device)
/// contributes nothing, because it could never be package content —
/// the module loader refuses it by kind.
fn collectFiles(
    io: std.Io,
    arena: Allocator,
    base: []const u8,
    prefix: []const u8,
    out: *std.ArrayList([]const u8),
) error{ OutOfMemory, Unreadable }!void {
    const where = if (prefix.len == 0)
        base
    else
        std.fs.path.join(arena, &.{ base, prefix }) catch return error.OutOfMemory;
    var dir = std.Io.Dir.cwd().openDir(io, where, .{ .iterate = true }) catch return error.Unreadable;
    defer dir.close(io);
    var entries = dir.iterate();
    while (entries.next(io) catch return error.Unreadable) |entry| {
        const relative = if (prefix.len == 0)
            try arena.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, entry.name });
        switch (entry.kind) {
            .directory => try collectFiles(io, arena, base, relative, out),
            .file => try out.append(arena, relative),
            else => {},
        }
    }
}

// ---------------------------------------------------------------------------
// Probes
// ---------------------------------------------------------------------------

/// The path a tree probe would answer `name` with, for the messages
/// that have to say what was looked for.
fn treePath(arena: Allocator, anchor: []const u8, name: []const u8) error{OutOfMemory}![]const u8 {
    const relative = try std.fmt.allocPrint(arena, "{s}.luc", .{name});
    std.mem.replaceScalar(u8, relative[0 .. relative.len - ".luc".len], '.', '/');
    if (anchor.len == 0) return relative;
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ anchor, relative });
}

/// The path a package probe would answer `name` with: the entry
/// module `NAME.luc` at the package root, or the dotted rest walked
/// inside it (docs/PACKAGES.md D4).
fn packagePath(arena: Allocator, directory: []const u8, name: []const u8) error{OutOfMemory}![]const u8 {
    if (std.mem.indexOfScalar(u8, name, '.')) |dot| {
        return treePath(arena, directory, name[dot + 1 ..]);
    }
    return std.fmt.allocPrint(arena, "{s}/{s}.luc", .{ directory, name });
}

/// Probe a directory tree for a dotted module name, one exact-case
/// level at a time.  `root` is the token an answer belongs to.
fn probeTree(
    io: std.Io,
    arena: Allocator,
    anchor: []const u8,
    name: []const u8,
    root: []const u8,
) error{OutOfMemory}!Probe {
    var where: []const u8 = anchor;
    var rest = name;
    while (std.mem.indexOfScalar(u8, rest, '.')) |dot| {
        const segment = rest[0..dot];
        rest = rest[dot + 1 ..];
        switch (try matchName(io, arena, where, segment)) {
            .exact, .unknown => {},
            .absent => return .missing,
            .case_variant => |real| return .{ .broken = try std.fmt.allocPrint(
                arena,
                "the folder is named {s}; module names are case-sensitive " ++
                    "even where the filesystem is not",
                .{real},
            ) },
        }
        where = if (where.len == 0)
            segment
        else
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ where, segment });
        // The segment must really be a folder — asked directly,
        // because what a failed descent errors with differs by
        // platform.  A stat the race gods deny is left to the
        // final open to explain.
        const info = std.Io.Dir.cwd().statFile(io, where, .{}) catch continue;
        if (info.kind != .directory) {
            return .{ .broken = "part of the path is not a directory" };
        }
    }

    const file_name = try std.fmt.allocPrint(arena, "{s}.luc", .{rest});
    switch (try matchName(io, arena, where, file_name)) {
        .exact, .unknown => {},
        .absent => return .missing,
        .case_variant => |real| return .{ .broken = try std.fmt.allocPrint(
            arena,
            "the file beside it is named {s}; module names are case-sensitive " ++
                "even where the filesystem is not",
            .{real},
        ) },
    }
    const path = if (where.len == 0)
        file_name
    else
        try std.fmt.allocPrint(arena, "{s}/{s}", .{ where, file_name });
    return .{ .answer = .{ .path = path, .root = root } };
}

/// Probe one resolved package for a module: `import geo` is the entry
/// module `geo.luc` at the package root, `import geo.sub` is
/// `sub.luc` inside it, dotted deeper the way the project tree is.
/// An answer belongs to the package's own token, which is how its
/// internal imports come back to the package (D4, D7).
fn probePackage(
    io: std.Io,
    arena: Allocator,
    package: *const ResolvedPackage,
    name: []const u8,
) error{OutOfMemory}!Probe {
    if (std.mem.indexOfScalar(u8, name, '.')) |dot| {
        return probeTree(io, arena, package.directory, name[dot + 1 ..], package.token);
    }
    return probeTree(io, arena, package.directory, name, package.token);
}

/// Why a thing that is not a regular file cannot be a module.  Saying
/// which kind it is costs nothing and is the difference between "fix
/// the path" and "why not?".
fn describe(kind: std.Io.File.Kind) []const u8 {
    return switch (kind) {
        .directory => "it is a directory",
        .named_pipe => "it is a named pipe",
        .character_device, .block_device => "it is a device",
        .unix_domain_socket => "it is a socket",
        else => not_a_file,
    };
}

const not_a_file = "it is not a regular file";

/// Read a whole file into caller-owned bytes.
pub fn readWhole(gpa: Allocator, io: std.Io, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false });
    defer file.close(io);
    const size = std.math.cast(usize, try file.length(io)) orelse return error.FileTooBig;
    const content = try gpa.alloc(u8, size);
    errdefer gpa.free(content);
    const loaded = try file.readPositionalAll(io, content, 0);
    if (loaded != content.len) return error.ReadFailed;
    return content;
}

/// Atomically replace a whole file and sync its contents.  Writing a
/// sibling temporary and renaming it means readers see either complete
/// version, a final symlink is replaced rather than followed, and an
/// error removes the temporary.
pub fn writeWhole(io: std.Io, path: []const u8, content: []const u8) !void {
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
        .permissions = .default_file,
        .replace = true,
    });
    defer atomic.deinit(io);
    try atomic.file.writePositionalAll(io, content, 0);
    try atomic.file.sync(io);
    try atomic.replace(io);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

// The loader is the manifest's only consumer, so the manifest's own
// tests run with it: naming an import is what puts a file's tests in
// the binary, and using its declarations is not.
test {
    _ = manifest;
}

/// tmpDir lives under .zig-cache/tmp/<sub>; files.zig resolves paths
/// relative to cwd, so tests build the cwd-relative prefix.
fn tmpPrefix(sub_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{sub_path});
}

test "whole-file write then read round-trips; a missing file errors" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmpPrefix(&tmp.sub_path);
    defer testing.allocator.free(directory);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/note.txt", .{directory});
    defer testing.allocator.free(path);

    try writeWhole(io, path, "hello loom");
    const read = try readWhole(testing.allocator, io, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("hello loom", read);

    const absent = try std.fmt.allocPrint(testing.allocator, "{s}/absent.txt", .{directory});
    defer testing.allocator.free(absent);
    try testing.expectError(error.FileNotFound, readWhole(testing.allocator, io, absent));
}

test "the import loader resolves NAME.luc beside the root and returns missing otherwise" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmpPrefix(&tmp.sub_path);
    defer testing.allocator.free(directory);
    const geo_path = try std.fmt.allocPrint(testing.allocator, "{s}/geo.luc", .{directory});
    defer testing.allocator.free(geo_path);
    try writeWhole(io, geo_path, "func area() -> i64:\n    return 4\n");

    var loader: FileLoader = .{ .io = io, .directory = directory };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const resolver = loader.loader();

    const found = try resolver.load(resolver.context, arena.allocator(), "geo", "");
    try testing.expect(found == .text);
    try testing.expect(std.mem.indexOf(u8, found.text.bytes, "return 4") != null);
    // The host says where it really opened the file, so a diagnostic
    // inside geo.luc can name the directory it came from.
    try testing.expect(std.mem.endsWith(u8, found.text.path, "/geo.luc"));

    // An unknown module is missing (the caller reports the failed
    // import), not an error and not an empty module.
    const absent = try resolver.load(resolver.context, arena.allocator(), "nope", "");
    try testing.expect(absent == .missing);
}

test "an import matches the directory entry exactly, whatever the filesystem thinks" {
    // The bug this exists for: `import geo` opens Geo.luc on macOS and
    // Windows, so the program builds here and fails on Linux CI.  The
    // check reads the directory rather than trusting `open`, so this
    // test proves the same thing on a case-sensitive filesystem (where
    // the open would simply fail) and on a case-insensitive one (where
    // it would succeed and lie).
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmpPrefix(&tmp.sub_path);
    defer testing.allocator.free(directory);
    const wrong_case = try std.fmt.allocPrint(testing.allocator, "{s}/Geo.luc", .{directory});
    defer testing.allocator.free(wrong_case);
    try writeWhole(io, wrong_case, "func area() -> i64:\n    return 4\n");

    var loader: FileLoader = .{ .io = io, .directory = directory };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const resolver = loader.loader();

    const found = try resolver.load(resolver.context, arena.allocator(), "geo", "");
    try testing.expect(found == .unreadable);
    // Naming the real spelling is the whole point: "cannot load module
    // geo" would send the author looking for a file that is right
    // there.
    try testing.expect(std.mem.indexOf(u8, found.unreadable, "Geo.luc") != null);

    // A name spelled the way it is on disk resolves as it always did.
    // (A second file cannot re-test `geo` here: a case-insensitive
    // filesystem keeps the original dirent when Geo.luc is rewritten
    // as geo.luc, which is exactly the trap being guarded against.)
    const exact_path = try std.fmt.allocPrint(testing.allocator, "{s}/util.luc", .{directory});
    defer testing.allocator.free(exact_path);
    try writeWhole(io, exact_path, "func twice(v: i64) -> i64:\n    return v * 2\n");
    const exact = try resolver.load(resolver.context, arena.allocator(), "util", "");
    try testing.expect(exact == .text);
    try testing.expect(std.mem.indexOf(u8, exact.text.bytes, "v * 2") != null);
}

test "under a project root, dots map to folders and every import is root-relative" {
    // The one-anchor rule (docs/PACKAGES.md D1, D2): with a root, both
    // `import geo.shapes` and the single-segment `import util` resolve
    // against the project root, wherever the importing file sits —
    // this loader's `directory` (the root file's own) plays no part.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpPrefix(&tmp.sub_path);
    defer testing.allocator.free(root);
    try tmp.dir.createDir(io, "geo", .default_dir);
    try tmp.dir.createDir(io, "src", .default_dir);
    const shapes_path = try std.fmt.allocPrint(testing.allocator, "{s}/geo/shapes.luc", .{root});
    defer testing.allocator.free(shapes_path);
    try writeWhole(io, shapes_path, "func area() -> i64:\n    return 4\n");
    const util_path = try std.fmt.allocPrint(testing.allocator, "{s}/util.luc", .{root});
    defer testing.allocator.free(util_path);
    try writeWhole(io, util_path, "func twice(v: i64) -> i64:\n    return v * 2\n");

    // The root file lives in src/, which holds neither module.
    const nested = try std.fmt.allocPrint(testing.allocator, "{s}/src", .{root});
    defer testing.allocator.free(nested);
    var loader: FileLoader = .{ .io = io, .directory = nested, .project_root = root };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const resolver = loader.loader();

    const shapes = try resolver.load(resolver.context, arena.allocator(), "geo.shapes", root);
    try testing.expect(shapes == .text);
    try testing.expect(std.mem.indexOf(u8, shapes.text.bytes, "return 4") != null);
    try testing.expect(std.mem.endsWith(u8, shapes.text.path, "/geo/shapes.luc"));

    const util = try resolver.load(resolver.context, arena.allocator(), "util", root);
    try testing.expect(util == .text);
    try testing.expect(std.mem.indexOf(u8, util.text.bytes, "v * 2") != null);

    // The folder exists and the file does not: an ordinary missing
    // module, reported by the caller with the full path it probed.
    const absent = try resolver.load(resolver.context, arena.allocator(), "geo.circles", root);
    try testing.expect(absent == .missing);

    // A folder that is not there is missing too, not an error.
    const nowhere = try resolver.load(resolver.context, arena.allocator(), "maps.tiles", root);
    try testing.expect(nowhere == .missing);
}

test "a dotted import checks the folder's case at every level" {
    // `import geo.shapes` with a folder really named Geo: a
    // case-folding filesystem would descend happily and the next
    // machine would not, so the directory entry is checked per level
    // and the refusal names the real spelling.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpPrefix(&tmp.sub_path);
    defer testing.allocator.free(root);
    try tmp.dir.createDir(io, "Geo", .default_dir);
    const shapes_path = try std.fmt.allocPrint(testing.allocator, "{s}/Geo/shapes.luc", .{root});
    defer testing.allocator.free(shapes_path);
    try writeWhole(io, shapes_path, "func area() -> i64:\n    return 4\n");

    var loader: FileLoader = .{ .io = io, .directory = root, .project_root = root };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const resolver = loader.loader();

    const found = try resolver.load(resolver.context, arena.allocator(), "geo.shapes", root);
    try testing.expect(found == .unreadable);
    try testing.expect(std.mem.indexOf(u8, found.unreadable, "Geo") != null);
    try testing.expect(std.mem.indexOf(u8, found.unreadable, "case-sensitive") != null);
}

test "a dotted import without a project root is refused, naming luce.yaml" {
    // Rootless programs keep exactly the sibling behaviour, single
    // segment only: a folder path needs the anchor a luce.yaml
    // provides (docs/PACKAGES.md D1), and the refusal says so rather
    // than resolving against an anchor nobody chose.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmpPrefix(&tmp.sub_path);
    defer testing.allocator.free(directory);
    try tmp.dir.createDir(io, "geo", .default_dir);
    const shapes_path = try std.fmt.allocPrint(testing.allocator, "{s}/geo/shapes.luc", .{directory});
    defer testing.allocator.free(shapes_path);
    try writeWhole(io, shapes_path, "func area() -> i64:\n    return 4\n");

    var loader: FileLoader = .{ .io = io, .directory = directory };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const resolver = loader.loader();

    // The file is right there; without the anchor it is still refused,
    // because sibling-relative folder walks are the two-anchor mistake
    // the root exists to kill.
    const found = try resolver.load(resolver.context, arena.allocator(), "geo.shapes", "");
    try testing.expect(found == .unreadable);
    try testing.expect(std.mem.indexOf(u8, found.unreadable, "luce.yaml") != null);

    // Single segments are untouched: today's behaviour exactly.
    const missing = try resolver.load(resolver.context, arena.allocator(), "shapes", "");
    try testing.expect(missing == .missing);
}

test "a middle segment that is a file, not a folder, is unreadable by name" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpPrefix(&tmp.sub_path);
    defer testing.allocator.free(root);
    // `geo` exists, but as a file — the walk cannot descend into it.
    const geo_path = try std.fmt.allocPrint(testing.allocator, "{s}/geo", .{root});
    defer testing.allocator.free(geo_path);
    try writeWhole(io, geo_path, "not a folder");

    var loader: FileLoader = .{ .io = io, .directory = root, .project_root = root };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const resolver = loader.loader();

    const found = try resolver.load(resolver.context, arena.allocator(), "geo.shapes", root);
    try testing.expect(found == .unreadable);
    try testing.expectEqualStrings("part of the path is not a directory", found.unreadable);
}

test "an import must be a regular file, not a device or a fifo" {
    // A character device answers zero bytes, and stage 1 would happily
    // register a module with no declarations in it — which then fails
    // as a baffling unknown name a dozen lines later.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmpPrefix(&tmp.sub_path);
    defer testing.allocator.free(directory);
    tmp.dir.symLink(io, "/dev/null", "geo.luc", .{}) catch return error.SkipZigTest;

    var loader: FileLoader = .{ .io = io, .directory = directory };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const resolver = loader.loader();

    const found = try resolver.load(resolver.context, arena.allocator(), "geo", "");
    try testing.expect(found == .unreadable);
    // Naming the kind, not just refusing: /dev/null is a device.
    try testing.expectEqualStrings("it is a device", found.unreadable);
}

test "the root may be something with no length to ask for" {
    // `luce check <(generate)` and `luce check -` both land here: a
    // stream has no size, so the old length()-then-read refused it
    // with a bare "Unseekable" — and leaked the buffer it had already
    // allocated on the way out.  The root is deliberately permissive
    // where an import is not; an editor has nothing else to offer.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const found = try readSource(testing.allocator, testing.io, "/dev/null");
    switch (found) {
        .text => |text| {
            defer testing.allocator.free(text.bytes);
            try testing.expectEqualStrings("", text.bytes);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "the name a stream is known by is not a dash" {
    try testing.expectEqualStrings("<stdin>", displayName("-"));
    try testing.expectEqualStrings("sub/main.luc", displayName("sub/main.luc"));
}

test "a directory where a module should be is unreadable, not missing" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmpPrefix(&tmp.sub_path);
    defer testing.allocator.free(directory);
    try tmp.dir.createDir(io, "geo.luc", .default_dir);

    var loader: FileLoader = .{ .io = io, .directory = directory };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const resolver = loader.loader();

    const found = try resolver.load(resolver.context, arena.allocator(), "geo", "");
    try testing.expect(found == .unreadable);
    try testing.expectEqualStrings("it is a directory", found.unreadable);
}

test "the loader answers modules under the root token it was handed" {
    // The token travels: the compiler hands the importing file's root
    // in, and every module this loader resolves belongs to that same
    // project, so the answer carries it back out (docs/PACKAGES.md D7).
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmpPrefix(&tmp.sub_path);
    defer testing.allocator.free(directory);
    const geo_path = try std.fmt.allocPrint(testing.allocator, "{s}/geo.luc", .{directory});
    defer testing.allocator.free(geo_path);
    try writeWhole(io, geo_path, "func area() -> i64:\n    return 4\n");

    var loader: FileLoader = .{ .io = io, .directory = directory };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const resolver = loader.loader();

    const found = try resolver.load(resolver.context, arena.allocator(), "geo", "/somewhere/project");
    try testing.expect(found == .text);
    try testing.expectEqualStrings("/somewhere/project", found.text.root);
}

test "discovery walks up from the root file's directory and the nearest manifest wins" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmpPrefix(&tmp.sub_path);
    defer testing.allocator.free(directory);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try tmp.dir.createDir(io, "a", .default_dir);
    try tmp.dir.createDir(io, "a/b", .default_dir);
    const outer = try std.fmt.allocPrint(testing.allocator, "{s}/luce.yaml", .{directory});
    defer testing.allocator.free(outer);
    try writeWhole(io, outer, "name: outer\nversion: 0.1.0\n");
    const inner = try std.fmt.allocPrint(testing.allocator, "{s}/a/luce.yaml", .{directory});
    defer testing.allocator.free(inner);
    try writeWhole(io, inner, "name: inner\nversion: 0.1.0\n");

    // Two directories below the inner manifest: the nearest governs,
    // and the outer one is shadowed rather than merged.
    const deep = try std.fmt.allocPrint(testing.allocator, "{s}/a/b/main.luc", .{directory});
    defer testing.allocator.free(deep);
    const nearest = try discoverProject(arena.allocator(), io, deep);
    try testing.expect(nearest == .governed);
    try testing.expect(std.mem.endsWith(u8, nearest.governed.root, "/a"));
    try testing.expectEqualStrings("inner", nearest.governed.manifest.name);

    // Beside the outer manifest, that one governs.
    const shallow = try std.fmt.allocPrint(testing.allocator, "{s}/main.luc", .{directory});
    defer testing.allocator.free(shallow);
    const outer_found = try discoverProject(arena.allocator(), io, shallow);
    try testing.expect(outer_found == .governed);
    try testing.expect(std.mem.endsWith(u8, outer_found.governed.root, &tmp.sub_path));
    try testing.expectEqualStrings("outer", outer_found.governed.manifest.name);
}

test "a broken manifest is refused with its file and line, never skipped" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmpPrefix(&tmp.sub_path);
    defer testing.allocator.free(directory);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const path = try std.fmt.allocPrint(testing.allocator, "{s}/luce.yaml", .{directory});
    defer testing.allocator.free(path);
    try writeWhole(io, path, "name: atlas\nversion: [0.1.0]\n");

    const wanted = try std.fmt.allocPrint(testing.allocator, "{s}/main.luc", .{directory});
    defer testing.allocator.free(wanted);
    const found = try discoverProject(arena.allocator(), io, wanted);
    try testing.expect(found == .refused);
    // The message names the manifest, the line, and the rule by name.
    try testing.expect(std.mem.indexOf(u8, found.refused, "luce.yaml:2") != null);
    try testing.expect(std.mem.indexOf(u8, found.refused, "flow style") != null);
}

test "discovery is lexical: a symlinked directory resolves against the tree that addressed it" {
    // The author typed a path through `aside/link`; the manifest that
    // governs is the one above that spelling.  A realpath walk would
    // leave for the link's target and find the outer manifest instead.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmpPrefix(&tmp.sub_path);
    defer testing.allocator.free(directory);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try tmp.dir.createDir(io, "aside", .default_dir);
    try tmp.dir.createDir(io, "real", .default_dir);
    const outer = try std.fmt.allocPrint(testing.allocator, "{s}/luce.yaml", .{directory});
    defer testing.allocator.free(outer);
    try writeWhole(io, outer, "name: outer\nversion: 0.1.0\n");
    const aside = try std.fmt.allocPrint(testing.allocator, "{s}/aside/luce.yaml", .{directory});
    defer testing.allocator.free(aside);
    try writeWhole(io, aside, "name: aside\nversion: 0.1.0\n");
    tmp.dir.symLink(io, "../real", "aside/link", .{ .is_directory = true }) catch return error.SkipZigTest;

    const through = try std.fmt.allocPrint(testing.allocator, "{s}/aside/link/main.luc", .{directory});
    defer testing.allocator.free(through);
    const found = try discoverProject(arena.allocator(), io, through);
    try testing.expect(found == .governed);
    try testing.expect(std.mem.endsWith(u8, found.governed.root, "/aside"));
}

test "standard input gets no discovery" {
    // A program piped from anywhere must not resolve against whatever
    // project the cwd happens to sit in: a pathless root has no
    // directory to walk from, so none is invented.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try discoverProject(arena.allocator(), testing.io, standard_input)) == .rootless);
}

test "no manifest anywhere above answers rootless" {
    // Hermetic against the machine: an empty subtree adds nothing to
    // the walk, so it answers exactly what walking from above it
    // answers — in this repository, rootless.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmpPrefix(&tmp.sub_path);
    defer testing.allocator.free(directory);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try tmp.dir.createDir(io, "a", .default_dir);
    const deep_path = try std.fmt.allocPrint(testing.allocator, "{s}/a/main.luc", .{directory});
    defer testing.allocator.free(deep_path);
    const deep = try discoverProject(arena.allocator(), io, deep_path);
    const above = try discoverProject(arena.allocator(), io, ".zig-cache/tmp/main.luc");

    try testing.expectEqual(std.meta.activeTag(above), std.meta.activeTag(deep));
    if (deep == .governed) try testing.expectEqualStrings(above.governed.root, deep.governed.root);
}

// ---------------------------------------------------------------------------
// The store, proven with the geo fixture (docs/PACKAGES.md D3, D4)
// ---------------------------------------------------------------------------

/// The memo's worked example, written into a temporary project: a
/// `luce.yaml`, a `main.luc`, and a vendored `geo-1.2.0` in the store
/// with an entry module, a submodule, and a private `util.luc`.
const Fixture = struct {
    tmp: testing.TmpDir,
    root: []u8,
    manifest_arena: std.heap.ArenaAllocator,
    parsed: manifest.Manifest,

    fn deinit(self: *Fixture) void {
        self.manifest_arena.deinit();
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn loaderOf(self: *Fixture, alerts: ?*std.Io.Writer) FileLoader {
        return .{
            .io = testing.io,
            .directory = self.root,
            .project_root = self.root,
            .project = self.parsed,
            .alerts = alerts,
            .gpa = testing.allocator,
        };
    }
};

/// A project with `manifest_text` for its luce.yaml, plus the standard
/// geo package placed at `store_home` ("" skips it).
fn makeFixture(manifest_text: []const u8, with_geo_in_store: bool) !Fixture {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    errdefer tmp.cleanup();
    const root = try tmpPrefix(&tmp.sub_path);
    errdefer testing.allocator.free(root);

    try writeUnder(root, "luce.yaml", manifest_text);
    try writeUnder(root, "main.luc", "import geo\n\nfunc main():\n    print(str(geo.area(2.0, 3.0)))\n");
    if (with_geo_in_store) try placeGeo(root, ".luce/packages/geo-1.2.0");

    var manifest_arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer manifest_arena.deinit();
    const text = try readWhole(manifest_arena.allocator(), io, try std.fs.path.join(manifest_arena.allocator(), &.{ root, "luce.yaml" }));
    const parsed = switch (try manifest.parse(manifest_arena.allocator(), text)) {
        .manifest => |parsed| parsed,
        .refused => return error.TestUnexpectedResult,
    };
    return .{ .tmp = tmp, .root = root, .manifest_arena = manifest_arena, .parsed = parsed };
}

/// Write the geo package — entry, submodule, internal util — under
/// `home` relative to `root`.
fn placeGeo(root: []const u8, home: []const u8) !void {
    const base = try std.fs.path.join(testing.allocator, &.{ root, home });
    defer testing.allocator.free(base);
    try writeUnder(base, "luce.yaml", "name: geo\nversion: 1.2.0\n");
    try writeUnder(base, "geo.luc", "import util\n\nfunc area(w: f64, h: f64) -> f64:\n    return util.scale(w * h)\n");
    try writeUnder(base, "shapes.luc", "struct Rect:\n    width: f64\n    height: f64\n");
    try writeUnder(base, "util.luc", "func scale(v: f64) -> f64:\n    return v * 10.0\n");
}

fn writeUnder(base: []const u8, relative: []const u8, content: []const u8) !void {
    const path = try std.fs.path.join(testing.allocator, &.{ base, relative });
    defer testing.allocator.free(path);
    if (std.fs.path.dirname(path)) |parent| {
        try std.Io.Dir.cwd().createDirPath(testing.io, parent);
    }
    try writeWhole(testing.io, path, content);
}

fn loadFrom(loader: *FileLoader, arena: Allocator, name: []const u8, from_root: []const u8) !luce.source.Found {
    const resolver = loader.loader();
    return resolver.load(resolver.context, arena, name, from_root);
}

const want_geo = "name: atlas\nversion: 0.1.0\npackages:\n  geo: 1.2.0\n";

test "a wanted package resolves from the store: entry, submodule, and internal anchor" {
    var fixture = try makeFixture(want_geo, true);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var loader = fixture.loaderOf(null);
    defer loader.deinit();

    // `import geo` is the entry module NAME.luc at the package root,
    // and its modules come back under the package's token.
    const entry = try loadFrom(&loader, arena.allocator(), "geo", fixture.root);
    try testing.expect(entry == .text);
    try testing.expectEqualStrings("geo-1.2.0", entry.text.root);
    try testing.expect(std.mem.endsWith(u8, entry.text.path, ".luce/packages/geo-1.2.0/geo.luc"));

    // `import geo.shapes` reaches shapes.luc inside it.
    const shapes = try loadFrom(&loader, arena.allocator(), "geo.shapes", fixture.root);
    try testing.expect(shapes == .text);
    try testing.expect(std.mem.endsWith(u8, shapes.text.path, "geo-1.2.0/shapes.luc"));

    // The package's own `import util` anchors to the package root —
    // never the consumer's tree, which holds no util at all.
    const util = try loadFrom(&loader, arena.allocator(), "util", "geo-1.2.0");
    try testing.expect(util == .text);
    try testing.expect(std.mem.endsWith(u8, util.text.path, "geo-1.2.0/util.luc"));
    try testing.expectEqualStrings("geo-1.2.0", util.text.root);

    // And the consumer's single-segment imports still resolve in the
    // project tree, not in anybody's package.
    const main_again = try loadFrom(&loader, arena.allocator(), "main", fixture.root);
    try testing.expect(main_again == .text);
    try testing.expectEqualStrings(fixture.root, main_again.text.root);
}

test "the package anchor wins over the consumer's tree for package-internal imports" {
    // The consumer also has a util.luc; the package's import must not
    // see it (D4), and the consumer's must not see the package's.
    var fixture = try makeFixture(want_geo, true);
    defer fixture.deinit();
    try writeUnder(fixture.root, "util.luc", "func scale(v: f64) -> f64:\n    return v\n");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var loader = fixture.loaderOf(null);
    defer loader.deinit();

    const inside = try loadFrom(&loader, arena.allocator(), "util", "geo-1.2.0");
    try testing.expect(inside == .text);
    try testing.expect(std.mem.indexOf(u8, inside.text.bytes, "* 10.0") != null);

    const outside = try loadFrom(&loader, arena.allocator(), "util", fixture.root);
    try testing.expect(outside == .text);
    try testing.expect(std.mem.indexOf(u8, outside.text.bytes, "* 10.0") == null);
}

test "a package not in the want list is unresolvable from any store" {
    // The store holds ansi-0.4.1; luce.yaml does not name it; a stray
    // install cannot change what a program means (D3).
    var fixture = try makeFixture(want_geo, true);
    defer fixture.deinit();
    const base = try std.fs.path.join(testing.allocator, &.{ fixture.root, ".luce/packages/ansi-0.4.1" });
    defer testing.allocator.free(base);
    try writeUnder(base, "luce.yaml", "name: ansi\nversion: 0.4.1\n");
    try writeUnder(base, "ansi.luc", "func code() -> i64:\n    return 27\n");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var loader = fixture.loaderOf(null);
    defer loader.deinit();

    const found = try loadFrom(&loader, arena.allocator(), "ansi", fixture.root);
    try testing.expect(found == .missing);
}

test "a project file and a declared package answering together is ambiguous" {
    var fixture = try makeFixture(want_geo, true);
    defer fixture.deinit();
    try writeUnder(fixture.root, "geo.luc", "func area(w: f64, h: f64) -> f64:\n    return w * h\n");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var loader = fixture.loaderOf(null);
    defer loader.deinit();

    const found = try loadFrom(&loader, arena.allocator(), "geo", fixture.root);
    try testing.expect(found == .ambiguous);
    try testing.expectEqual(@as(usize, 2), found.ambiguous.len);
    try testing.expect(std.mem.endsWith(u8, found.ambiguous[0], "/geo.luc"));
    try testing.expect(std.mem.indexOf(u8, found.ambiguous[1], ".luce/packages/geo-1.2.0/geo.luc") != null);
}

test "a wanted package absent everywhere says where it was expected, verbatim" {
    var fixture = try makeFixture(want_geo, false);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var loader = fixture.loaderOf(null);
    defer loader.deinit();
    const shelf = try std.fs.path.join(arena.allocator(), &.{ fixture.root, "shelf" });
    loader.shelves = &.{shelf};

    const found = try loadFrom(&loader, arena.allocator(), "geo", fixture.root);
    try testing.expect(found == .refused);
    try testing.expectEqualStrings("luce.import.missing", found.refused.code);
    const store_path = try std.fs.path.join(arena.allocator(), &.{ fixture.root, ".luce", "packages", "geo-1.2.0" });
    const shelf_path = try std.fs.path.join(arena.allocator(), &.{ shelf, "geo-1.2.0" });
    try testing.expect(std.mem.indexOf(u8, found.refused.message, store_path) != null);
    try testing.expect(std.mem.indexOf(u8, found.refused.message, shelf_path) != null);
}

test "a module missing from a resolved package names both probed places" {
    var fixture = try makeFixture(want_geo, true);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var loader = fixture.loaderOf(null);
    defer loader.deinit();

    const found = try loadFrom(&loader, arena.allocator(), "geo.circles", fixture.root);
    try testing.expect(found == .refused);
    try testing.expectEqualStrings("luce.import.missing", found.refused.code);
    try testing.expect(std.mem.indexOf(u8, found.refused.message, "geo/circles.luc") != null);
    try testing.expect(std.mem.indexOf(u8, found.refused.message, "geo-1.2.0/circles.luc") != null);
}

test "a store package whose manifest disagrees is refused with both identities named" {
    var fixture = try makeFixture(want_geo, false);
    defer fixture.deinit();
    const base = try std.fs.path.join(testing.allocator, &.{ fixture.root, ".luce/packages/geo-1.2.0" });
    defer testing.allocator.free(base);
    try writeUnder(base, "luce.yaml", "name: geo\nversion: 1.3.0\n");
    try writeUnder(base, "geo.luc", "func area(w: f64, h: f64) -> f64:\n    return w * h\n");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var loader = fixture.loaderOf(null);
    defer loader.deinit();

    const found = try loadFrom(&loader, arena.allocator(), "geo", fixture.root);
    try testing.expect(found == .refused);
    try testing.expectEqualStrings("luce.import.version", found.refused.code);
    try testing.expect(std.mem.indexOf(u8, found.refused.message, "geo 1.2.0") != null);
    try testing.expect(std.mem.indexOf(u8, found.refused.message, "geo 1.3.0") != null);
}

test "a store package with no manifest at all is refused by name" {
    var fixture = try makeFixture(want_geo, false);
    defer fixture.deinit();
    const base = try std.fs.path.join(testing.allocator, &.{ fixture.root, ".luce/packages/geo-1.2.0" });
    defer testing.allocator.free(base);
    try writeUnder(base, "geo.luc", "func area(w: f64, h: f64) -> f64:\n    return w * h\n");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var loader = fixture.loaderOf(null);
    defer loader.deinit();

    const found = try loadFrom(&loader, arena.allocator(), "geo", fixture.root);
    try testing.expect(found == .refused);
    try testing.expectEqualStrings("luce.import.version", found.refused.code);
    try testing.expect(std.mem.indexOf(u8, found.refused.message, "has no luce.yaml") != null);
}

test "a package on a shelf and in the store is ambiguous, never precedence" {
    var fixture = try makeFixture(want_geo, true);
    defer fixture.deinit();
    try placeGeo(fixture.root, "shelf/geo-1.2.0");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var loader = fixture.loaderOf(null);
    defer loader.deinit();
    const shelf = try std.fs.path.join(arena.allocator(), &.{ fixture.root, "shelf" });
    loader.shelves = &.{shelf};

    const found = try loadFrom(&loader, arena.allocator(), "geo", fixture.root);
    try testing.expect(found == .refused);
    try testing.expectEqualStrings("luce.import.ambiguous", found.refused.code);
    try testing.expect(std.mem.indexOf(u8, found.refused.message, ".luce/packages/geo-1.2.0") != null);
    try testing.expect(std.mem.indexOf(u8, found.refused.message, "shelf/geo-1.2.0") != null);
}

test "a LUCE_LIB resolution is loud: one line to standard error, every build" {
    var fixture = try makeFixture(want_geo, false);
    defer fixture.deinit();
    try placeGeo(fixture.root, "shelf/geo-1.2.0");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var said: std.Io.Writer.Allocating = .init(testing.allocator);
    defer said.deinit();
    var loader = fixture.loaderOf(&said.writer);
    defer loader.deinit();
    const shelf = try std.fs.path.join(arena.allocator(), &.{ fixture.root, "shelf" });
    loader.shelves = &.{shelf};

    const found = try loadFrom(&loader, arena.allocator(), "geo", fixture.root);
    try testing.expect(found == .text);
    try testing.expectEqualStrings("geo-1.2.0", found.text.root);
    try testing.expect(std.mem.indexOf(u8, said.written(), "package geo 1.2.0") != null);
    try testing.expect(std.mem.indexOf(u8, said.written(), "LUCE_LIB") != null);
}

test "a path: override replaces the store probe, resolves, and is loud" {
    var fixture = try makeFixture("name: atlas\nversion: 0.1.0\npackages:\n  geo: 1.2.0 path:vendored/geo\n", false);
    defer fixture.deinit();
    // The store also holds it; the override replaces that probe rather
    // than fighting it (D3).
    try placeGeo(fixture.root, ".luce/packages/geo-1.2.0");
    try placeGeo(fixture.root, "vendored/geo");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var said: std.Io.Writer.Allocating = .init(testing.allocator);
    defer said.deinit();
    var loader = fixture.loaderOf(&said.writer);
    defer loader.deinit();

    const found = try loadFrom(&loader, arena.allocator(), "geo", fixture.root);
    try testing.expect(found == .text);
    try testing.expect(std.mem.indexOf(u8, found.text.path, "vendored/geo") != null);
    try testing.expect(std.mem.indexOf(u8, said.written(), "path:") != null);
}

test "a diamond is refused naming both edges; override: in the root resolves it" {
    // geo wants mathx 1.1.0, ansi wants mathx 1.2.0 — refused with
    // both requirers named, and the remedy is the consumer's (D4).
    const disagreeing = "name: atlas\nversion: 0.1.0\npackages:\n  geo: 1.2.0\n  ansi: 0.4.1\n";
    var fixture = try makeFixture(disagreeing, false);
    defer fixture.deinit();
    const store = ".luce/packages";
    const geo_base = try std.fs.path.join(testing.allocator, &.{ fixture.root, store, "geo-1.2.0" });
    defer testing.allocator.free(geo_base);
    try writeUnder(geo_base, "luce.yaml", "name: geo\nversion: 1.2.0\npackages:\n  mathx: 1.1.0\n");
    try writeUnder(geo_base, "geo.luc", "import mathx\n\nfunc area(w: f64, h: f64) -> f64:\n    return mathx.mul(w, h)\n");
    const ansi_base = try std.fs.path.join(testing.allocator, &.{ fixture.root, store, "ansi-0.4.1" });
    defer testing.allocator.free(ansi_base);
    try writeUnder(ansi_base, "luce.yaml", "name: ansi\nversion: 0.4.1\npackages:\n  mathx: 1.2.0\n");
    try writeUnder(ansi_base, "ansi.luc", "func code() -> i64:\n    return 27\n");
    for ([_][]const u8{ "mathx-1.1.0", "mathx-1.2.0" }) |dashed| {
        const base = try std.fs.path.join(testing.allocator, &.{ fixture.root, store, dashed });
        defer testing.allocator.free(base);
        const version = dashed["mathx-".len..];
        const text = try std.fmt.allocPrint(testing.allocator, "name: mathx\nversion: {s}\n", .{version});
        defer testing.allocator.free(text);
        try writeUnder(base, "luce.yaml", text);
        try writeUnder(base, "mathx.luc", "func mul(a: f64, b: f64) -> f64:\n    return a * b\n");
    }

    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var loader = fixture.loaderOf(null);
        defer loader.deinit();
        const found = try loadFrom(&loader, arena.allocator(), "geo", fixture.root);
        try testing.expect(found == .refused);
        try testing.expectEqualStrings("luce.import.diamond", found.refused.code);
        try testing.expect(std.mem.indexOf(u8, found.refused.message, "geo 1.2.0") != null);
        try testing.expect(std.mem.indexOf(u8, found.refused.message, "ansi 0.4.1") != null);
        try testing.expect(std.mem.indexOf(u8, found.refused.message, "override:") != null);
    }

    // The named remedy, taken: the root pins mathx and the same store
    // resolves, loudly.
    try writeUnder(fixture.root, "luce.yaml", disagreeing ++ "override:\n  mathx: 1.1.0\n");
    var override_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer override_arena.deinit();
    const text = try readWhole(override_arena.allocator(), testing.io, try std.fs.path.join(override_arena.allocator(), &.{ fixture.root, "luce.yaml" }));
    const pinned = switch (try manifest.parse(override_arena.allocator(), text)) {
        .manifest => |parsed| parsed,
        .refused => return error.TestUnexpectedResult,
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var said: std.Io.Writer.Allocating = .init(testing.allocator);
    defer said.deinit();
    var loader = fixture.loaderOf(&said.writer);
    loader.project = pinned;
    defer loader.deinit();

    const resolved = try loadFrom(&loader, arena.allocator(), "geo", fixture.root);
    try testing.expect(resolved == .text);
    const dependency = try loadFrom(&loader, arena.allocator(), "mathx", "geo-1.2.0");
    try testing.expect(dependency == .text);
    try testing.expect(std.mem.indexOf(u8, dependency.text.path, "mathx-1.1.0") != null);
    try testing.expect(std.mem.indexOf(u8, said.written(), "override: pins 1.1.0 over 1.2.0") != null);
}

test "a stated hash is verified; a mismatch is refused with both digests named" {
    var fixture = try makeFixture(want_geo, true);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const store_dir = try std.fs.path.join(arena.allocator(), &.{ fixture.root, ".luce", "packages", "geo-1.2.0" });
    const digest = try hashPackageDirectory(testing.io, arena.allocator(), store_dir);

    // The right hash: resolves.
    {
        const text = try std.fmt.allocPrint(arena.allocator(), "name: atlas\nversion: 0.1.0\npackages:\n  geo: 1.2.0 sha256:{s}\n", .{digest});
        const parsed = switch (try manifest.parse(arena.allocator(), text)) {
            .manifest => |parsed| parsed,
            .refused => return error.TestUnexpectedResult,
        };
        var loader = fixture.loaderOf(null);
        loader.project = parsed;
        defer loader.deinit();
        const found = try loadFrom(&loader, arena.allocator(), "geo", fixture.root);
        try testing.expect(found == .text);
    }

    // One flipped digit: refused, both numbers named.
    {
        var wrong = digest;
        wrong[0] = if (wrong[0] == 'a') 'b' else 'a';
        const text = try std.fmt.allocPrint(arena.allocator(), "name: atlas\nversion: 0.1.0\npackages:\n  geo: 1.2.0 sha256:{s}\n", .{wrong});
        const parsed = switch (try manifest.parse(arena.allocator(), text)) {
            .manifest => |parsed| parsed,
            .refused => return error.TestUnexpectedResult,
        };
        var loader = fixture.loaderOf(null);
        loader.project = parsed;
        defer loader.deinit();
        const found = try loadFrom(&loader, arena.allocator(), "geo", fixture.root);
        try testing.expect(found == .refused);
        try testing.expectEqualStrings("luce.import.version", found.refused.code);
        try testing.expect(std.mem.indexOf(u8, found.refused.message, &wrong) != null);
        try testing.expect(std.mem.indexOf(u8, found.refused.message, &digest) != null);
    }

    // A value that cannot be a sha256 is refused by shape.
    {
        const text = "name: atlas\nversion: 0.1.0\npackages:\n  geo: 1.2.0 sha256:9f2a\n";
        const parsed = switch (try manifest.parse(arena.allocator(), text)) {
            .manifest => |parsed| parsed,
            .refused => return error.TestUnexpectedResult,
        };
        var loader = fixture.loaderOf(null);
        loader.project = parsed;
        defer loader.deinit();
        const found = try loadFrom(&loader, arena.allocator(), "geo", fixture.root);
        try testing.expect(found == .refused);
        try testing.expect(std.mem.indexOf(u8, found.refused.message, "64 hex digits") != null);
    }
}

test "the directory hash moves with content, name, and layout — and with nothing else" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpPrefix(&tmp.sub_path);
    defer testing.allocator.free(root);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try writeUnder(root, "one/luce.yaml", "name: geo\nversion: 1.2.0\n");
    try writeUnder(root, "one/geo.luc", "func f() -> i64:\n    return 1\n");
    try writeUnder(root, "two/luce.yaml", "name: geo\nversion: 1.2.0\n");
    try writeUnder(root, "two/geo.luc", "func f() -> i64:\n    return 1\n");

    const one = try std.fs.path.join(arena.allocator(), &.{ root, "one" });
    const two = try std.fs.path.join(arena.allocator(), &.{ root, "two" });
    const first = try hashPackageDirectory(io, arena.allocator(), one);
    const same = try hashPackageDirectory(io, arena.allocator(), two);
    try testing.expectEqualStrings(&first, &same);

    // Edited content moves it.
    try writeUnder(root, "two/geo.luc", "func f() -> i64:\n    return 2\n");
    const edited = try hashPackageDirectory(io, arena.allocator(), two);
    try testing.expect(!std.mem.eql(u8, &first, &edited));

    // A renamed file moves it even with identical bytes.
    try writeUnder(root, "two/geo.luc", "func f() -> i64:\n    return 1\n");
    try writeUnder(root, "two/sub/extra.luc", "func g() -> i64:\n    return 3\n");
    const grown = try hashPackageDirectory(io, arena.allocator(), two);
    try testing.expect(!std.mem.eql(u8, &first, &grown));
}

test "a case variant inside a package is refused naming the real spelling" {
    var fixture = try makeFixture(want_geo, false);
    defer fixture.deinit();
    const base = try std.fs.path.join(testing.allocator, &.{ fixture.root, ".luce/packages/geo-1.2.0" });
    defer testing.allocator.free(base);
    try writeUnder(base, "luce.yaml", "name: geo\nversion: 1.2.0\n");
    try writeUnder(base, "Geo.luc", "func area(w: f64, h: f64) -> f64:\n    return w * h\n");
    try writeUnder(base, "Shapes.luc", "struct Rect:\n    width: f64\n    height: f64\n");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var loader = fixture.loaderOf(null);
    defer loader.deinit();

    const entry = try loadFrom(&loader, arena.allocator(), "geo", fixture.root);
    try testing.expect(entry == .unreadable);
    try testing.expect(std.mem.indexOf(u8, entry.unreadable, "Geo.luc") != null);

    const submodule = try loadFrom(&loader, arena.allocator(), "geo.shapes", fixture.root);
    try testing.expect(submodule == .unreadable);
    try testing.expect(std.mem.indexOf(u8, submodule.unreadable, "Shapes.luc") != null);
}

test "LUCE_LIB splits on the platform's separator and drops empty entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text = try std.fmt.allocPrint(arena.allocator(), "/a{c}{c}/b/c{c}", .{
        std.fs.path.delimiter, std.fs.path.delimiter, std.fs.path.delimiter,
    });
    const shelves = try splitSearchPath(arena.allocator(), text);
    try testing.expectEqual(@as(usize, 2), shelves.len);
    try testing.expectEqualStrings("/a", shelves[0]);
    try testing.expectEqualStrings("/b/c", shelves[1]);
}
