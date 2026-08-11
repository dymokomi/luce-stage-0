//! File access shared by the luce and loom executables: whole-file
//! reads and writes, reading a source file, the import loader that
//! resolves `import name` as NAME.luc beside the root source file,
//! and project discovery — the walk that finds the `luce.yaml`
//! governing a root source file (docs/PACKAGES.md D1).  One copy, so
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
//! (`01_source/load.zig`):
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
    /// The directory that holds luce.yaml — the opaque root token the
    /// compile is given as `CompileOptions.source_root`.  Allocated
    /// from the arena `discoverProject` was handed.
    root: []const u8,
    /// A luce.yaml was found and could not be a manifest.  Refused,
    /// never skipped: skipping would silently change which root
    /// governs, and a broken manifest is a fact about the project, not
    /// about this one compile.  The message names the file and, when
    /// there is one, the line; allocated from the arena.
    refused: []const u8,
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
        .manifest => return .{ .root = try arena.dupe(u8, directory) },
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

/// Loads `import name` as NAME.luc next to the root source file.
pub const FileLoader = struct {
    io: std.Io,
    directory: []const u8,

    fn load(context: *anyopaque, arena: Allocator, name: []const u8, from_root: []const u8) error{OutOfMemory}!luce.source.Found {
        const self: *FileLoader = @ptrCast(@alignCast(context));
        const wanted = try std.fmt.allocPrint(arena, "{s}.luc", .{name});
        const path = if (self.directory.len == 0)
            wanted
        else
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ self.directory, wanted });

        switch (try matchName(self.io, arena, self.directory, wanted)) {
            .exact, .unknown => {},
            .absent => return .missing,
            .case_variant => |real| return .{ .unreadable = try std.fmt.allocPrint(
                arena,
                "the file beside it is named {s}; module names are case-sensitive " ++
                    "even where the filesystem is not",
                .{real},
            ) },
        }

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
        // Every module this loader can answer resolves beside the
        // root, inside the importing file's own project, so the root
        // token it belongs to is the token the compiler handed in —
        // recorded per file and handed back on that file's imports.
        // The tiers that could answer with another root's file are
        // the store and the shelf, and they are not built yet.
        if (found == .text) found.text.root = from_root;
        return found;
    }

    pub fn loader(self: *FileLoader) luce.compile.Loader {
        return .{ .context = self, .load = load };
    }
};

/// A loader for a small set of sources already held by the host.  Loom
/// uses it for the editor bundled inside the binary: the root editor and
/// its sibling modules still go through the ordinary project loader, but
/// no temporary source files have to be created just to start `loom edit`.
pub const MemoryFile = struct {
    name: []const u8,
    source: []const u8,
};

pub const MemoryLoader = struct {
    files: []const MemoryFile,

    fn load(
        context: *anyopaque,
        arena: Allocator,
        name: []const u8,
        from_root: []const u8,
    ) error{OutOfMemory}!luce.source.Found {
        const self: *MemoryLoader = @ptrCast(@alignCast(context));
        for (self.files) |file| {
            if (!std.mem.eql(u8, file.name, name)) continue;
            return .{
                .text = .{
                    .bytes = try arena.dupe(u8, file.source),
                    .path = try std.fmt.allocPrint(arena, "{s}.luc", .{name}),
                    // No discovery ever ran for these files, so the only
                    // token in play is the one the compile was given.
                    .root = from_root,
                },
            };
        }
        return .missing;
    }

    pub fn loader(self: *MemoryLoader) luce.compile.Loader {
        return .{ .context = self, .load = load };
    }
};

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
    try writeWhole(io, geo_path, "func area() -> long:\n    return 4\n");

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
    try writeWhole(io, wrong_case, "func area() -> long:\n    return 4\n");

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
    try writeWhole(io, exact_path, "func twice(v: long) -> long:\n    return v * 2\n");
    const exact = try resolver.load(resolver.context, arena.allocator(), "util", "");
    try testing.expect(exact == .text);
    try testing.expect(std.mem.indexOf(u8, exact.text.bytes, "v * 2") != null);
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
    try writeWhole(io, geo_path, "func area() -> long:\n    return 4\n");

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
    try testing.expect(nearest == .root);
    try testing.expect(std.mem.endsWith(u8, nearest.root, "/a"));

    // Beside the outer manifest, that one governs.
    const shallow = try std.fmt.allocPrint(testing.allocator, "{s}/main.luc", .{directory});
    defer testing.allocator.free(shallow);
    const outer_found = try discoverProject(arena.allocator(), io, shallow);
    try testing.expect(outer_found == .root);
    try testing.expect(std.mem.endsWith(u8, outer_found.root, &tmp.sub_path));
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
    try testing.expect(found == .root);
    try testing.expect(std.mem.endsWith(u8, found.root, "/aside"));
}

test "standard input gets no discovery" {
    // `loom edit` inside somebody's project must not resolve against
    // that project, and neither may a program piped from anywhere: a
    // pathless root has no directory to walk from, so none is invented.
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
    if (deep == .root) try testing.expectEqualStrings(above.root, deep.root);
}
