//! File access shared by the luce and loom executables: whole-file
//! reads and writes, reading a source file, and the import loader that
//! resolves `import name` as NAME.luc beside the root source file.
//! One copy, so the two programs can never drift on how imports
//! resolve or on what counts as an unreadable file.
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

    fn load(context: *anyopaque, arena: Allocator, name: []const u8) error{OutOfMemory}!luce.source.Found {
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
        return readWholeFile(arena, self.io, file, path, @intCast(info.size));
    }

    pub fn loader(self: *FileLoader) luce.compile.Loader {
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

    const found = try resolver.load(resolver.context, arena.allocator(), "geo");
    try testing.expect(found == .text);
    try testing.expect(std.mem.indexOf(u8, found.text.bytes, "return 4") != null);
    // The host says where it really opened the file, so a diagnostic
    // inside geo.luc can name the directory it came from.
    try testing.expect(std.mem.endsWith(u8, found.text.path, "/geo.luc"));

    // An unknown module is missing (the caller reports the failed
    // import), not an error and not an empty module.
    const absent = try resolver.load(resolver.context, arena.allocator(), "nope");
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

    const found = try resolver.load(resolver.context, arena.allocator(), "geo");
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
    const exact = try resolver.load(resolver.context, arena.allocator(), "util");
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

    const found = try resolver.load(resolver.context, arena.allocator(), "geo");
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

    const found = try resolver.load(resolver.context, arena.allocator(), "geo");
    try testing.expect(found == .unreadable);
    try testing.expectEqualStrings("it is a directory", found.unreadable);
}
