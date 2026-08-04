//! Finding the tools, linking an object, and loading an artifact.
//!
//! Stage 8 stops at LLVM bitcode and `emit` turns that into a
//! relocatable object (`docs/CODEGEN.md`).  What stands between that
//! and a program a person can run is a linker invocation and — for the
//! loadable form — a loader that refuses the wrong artifact by name.
//!
//! **Nothing here links libLLVM, and that is the shape of the two
//! binaries.**  `luce` is the compiler: it lowers, emits, and links.
//! `loom` is the environment: it opens artifacts, runs them, and when
//! one has to be built it runs the `luce` binary (`findCompiler`).  So
//! this module holds exactly what both of them need — the tool search,
//! the link, the tag, the load — and `src/apps/luce/object.zig` holds
//! the half that needs a code generator in the process.
//!
//! **Linking runs `cc`, and only when something is being built.**  A
//! link is a build-time act: it happens when `luce build --emit=exe`
//! is typed, or the first time loom meets a program it has no cached
//! artifact for.  Running an artifact that already exists invokes
//! nothing — one `dlopen`, one symbol lookup, one call — which is the
//! promise docs/CODEGEN.md makes about the *run* path.
//!
//! Why `cc` and not LLD in-process: LLD is not part of what
//! `llvm-config` describes (Homebrew ships it as a separate formula
//! and `llvm-config --libs` never names it), so reaching it would mean
//! discovering a second toolchain or vendoring one.  `cc` is present
//! wherever a C toolchain is, knows its own platform's SDK paths,
//! system libraries and crt objects, and is what `08_llvm/test.zig`
//! has been linking with all along.  `LUCE_CC` names a different
//! driver.

const std = @import("std");
const luce = @import("luce");

const Allocator = std.mem.Allocator;
const abi = luce.llvm.abi;
const artifact = luce.llvm.artifact;

// ---------------------------------------------------------------------------
// What is being produced
// ---------------------------------------------------------------------------

/// The three shapes a compiled program is asked for.
pub const Kind = enum {
    /// A relocatable object; the caller links it (`docs/CODEGEN.md`).
    object,
    /// A shared library a loader opens: **the `.lc`** — what `luce
    /// build` writes, what loom runs, and what an embedder loads.
    /// Carries the artifact tag.
    library,
    /// A standalone executable: the same code plus `libluce_start`'s
    /// `main`.
    executable,

    /// The extension the artifact is given when the caller named no
    /// output path.
    pub fn extension(self: Kind) []const u8 {
        return switch (self) {
            .object => ".o",
            // Not `.so`/`.dylib`: it *is* one, but it is also a Luce
            // program with a tag, and `.lc` is what a Luce program a
            // person can run has been called since there was one.
            .library => ".lc",
            .executable => "",
        };
    }
};

// ---------------------------------------------------------------------------
// Finding the pieces a link needs
// ---------------------------------------------------------------------------

/// The libraries and the driver a link needs.  Found once and reused.
pub const Tools = struct {
    /// The C compiler driver used as the linker.
    driver: []const u8,
    /// `libluce_rt.a` — the semantics every artifact calls.
    runtime: []const u8,
    /// `libluce_start.a` — `main`, needed only for an executable.
    /// Empty when it was not found, which is only an error if an
    /// executable is asked for.
    start: []const u8,
    /// Where the two libraries were looked for, for the error message
    /// when one is missing.
    searched: []const u8,

    pub fn deinit(self: *Tools, gpa: Allocator) void {
        gpa.free(self.driver);
        gpa.free(self.runtime);
        gpa.free(self.start);
        gpa.free(self.searched);
        self.* = undefined;
    }
};

/// Where the installed libraries sit relative to the running binary.
///
/// `zig build --prefix build` installs the executables at the prefix
/// root and the libraries under `lib/`, so a binary at `build/luce`
/// looks in `build/lib`.  A plain `zig build` puts binaries in
/// `zig-out/bin`, so the sibling `../lib` is checked too.  `LUCE_LIB`
/// overrides both, which is what a relocated install or a test tree
/// uses.
const library_directories = [_][]const u8{ "lib", "../lib" };

pub const FindError = error{OutOfMemory};

/// Find the driver and the libraries.  Never fails for a missing
/// library — `link` reports that, with the paths it tried, at the
/// moment it actually matters.
pub fn discover(gpa: Allocator, io: std.Io, override_lib: ?[]const u8, override_cc: ?[]const u8) FindError!Tools {
    var searched: std.ArrayList(u8) = .empty;
    defer searched.deinit(gpa);

    var runtime: []const u8 = "";
    var start: []const u8 = "";

    if (override_lib) |directory| {
        try searched.appendSlice(gpa, directory);
        runtime = try fileIn(gpa, io, directory, "libluce_rt.a");
        start = try fileIn(gpa, io, directory, "libluce_start.a");
    } else if (std.process.executableDirPathAlloc(io, gpa)) |beside| {
        defer gpa.free(beside);
        for (library_directories) |relative| {
            const directory = try std.fs.path.join(gpa, &.{ beside, relative });
            defer gpa.free(directory);
            if (searched.items.len != 0) try searched.appendSlice(gpa, ", ");
            try searched.appendSlice(gpa, directory);
            if (runtime.len == 0) runtime = try fileIn(gpa, io, directory, "libluce_rt.a");
            if (start.len == 0) start = try fileIn(gpa, io, directory, "libluce_start.a");
        }
    } else |_| {}

    return .{
        .driver = try gpa.dupe(u8, override_cc orelse "cc"),
        .runtime = runtime,
        .start = start,
        .searched = try searched.toOwnedSlice(gpa),
    };
}

/// The path of `name` inside `directory` when it is really there, or
/// an empty string.  The caller owns a non-empty answer.
fn fileIn(gpa: Allocator, io: std.Io, directory: []const u8, name: []const u8) FindError![]const u8 {
    const path = try std.fs.path.join(gpa, &.{ directory, name });
    errdefer gpa.free(path);
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch {
        gpa.free(path);
        return "";
    };
    file.close(io);
    return path;
}

// ---------------------------------------------------------------------------
// Finding the compiler
// ---------------------------------------------------------------------------

/// The name of the compiler binary, as it is installed.
pub const compiler_name = "luce";

/// `luce build` exits with this when the program says something the
/// backend has no lowering for, rather than with the ordinary 1.
///
/// The distinction is not cosmetic: everything else a build can fail
/// with is about *this attempt* — an unwritable directory, a missing
/// library, a linker that is not there — and is worth retrying
/// somewhere else.  This one is about the program, and no directory
/// changes it, so a caller that would otherwise try a second place
/// stops here instead.
pub const exit_unsupported: u8 = 2;

/// Where the `luce` compiler is, for whoever needs something built.
pub const Compiler = struct {
    /// The binary, or an empty string when it was not found.
    path: []const u8,
    /// The directory beside the running binary that was looked in, for
    /// the error message.  Empty when even that could not be asked for.
    beside: []const u8,

    pub fn found(self: *const Compiler) bool {
        return self.path.len != 0;
    }

    pub fn deinit(self: *Compiler, gpa: Allocator) void {
        gpa.free(self.path);
        gpa.free(self.beside);
        self.* = undefined;
    }
};

/// Find the `luce` binary: beside the running executable first, then on
/// `PATH`.
///
/// Beside first is what a toolchain does, and it is what makes an
/// install tree self-consistent — a `loom` from `build/` builds with
/// the `luce` from `build/`, never with whatever an older install left
/// earlier on `PATH`.  `PATH` is the fallback for a `loom` that was
/// copied somewhere on its own.
///
/// `search_path` is the `PATH` variable's value; null skips that half.
/// Never fails for a missing compiler — the caller reports that at the
/// moment it matters, which is not every startup.
pub fn findCompiler(gpa: Allocator, io: std.Io, search_path: ?[]const u8) FindError!Compiler {
    const beside = std.process.executableDirPathAlloc(io, gpa) catch
        try gpa.dupe(u8, "");
    errdefer gpa.free(beside);

    if (beside.len != 0) {
        const candidate = try runnableIn(gpa, io, beside, compiler_name);
        if (candidate.len != 0) return .{ .path = candidate, .beside = beside };
    }

    var entries = std.mem.tokenizeScalar(u8, search_path orelse "", path_separator);
    while (entries.next()) |directory| {
        const candidate = try runnableIn(gpa, io, directory, compiler_name);
        if (candidate.len != 0) return .{ .path = candidate, .beside = beside };
    }
    return .{ .path = try gpa.dupe(u8, ""), .beside = beside };
}

/// The path of a *runnable* `name` inside `directory`, or an empty
/// string.  The caller owns a non-empty answer.
///
/// A compiler is something to run, and a directory on `PATH` may
/// perfectly well hold a `luce` that is not — a source tree with a
/// `luce/` in it, a half-finished download, a note someone named after
/// the tool.  Answering with one of those stops the search at a file
/// that then fails to spawn, and the real compiler further down `PATH`
/// is never looked at; a shell checks the execute bit before it stops,
/// for exactly this reason.
///
/// Only the compiler search asks.  A static library (`fileIn`) is
/// handed to a linker, not executed, and demanding the bit there would
/// refuse perfectly good `.a` files.
fn runnableIn(
    gpa: Allocator,
    io: std.Io,
    directory: []const u8,
    name: []const u8,
) FindError![]const u8 {
    const path = try fileIn(gpa, io, directory, name);
    if (path.len == 0) return path;
    std.Io.Dir.cwd().access(io, path, .{ .execute = true }) catch {
        gpa.free(path);
        return "";
    };
    return path;
}

const path_separator: u8 = if (@import("builtin").os.tag == .windows) ';' else ':';

// ---------------------------------------------------------------------------
// Naming a temporary
// ---------------------------------------------------------------------------

/// Room for what `writerTag` writes.
pub const writer_tag_bytes = 48;

/// Who is writing, as the text that makes a temporary file's name one
/// nobody else will pick.  Written into `buffer`, which the caller owns.
///
/// **The process id first, and the thread id after it.**  What these
/// names have to survive is two *processes* warming the same cache at
/// once — `zig build` runs a dozen — and a thread id is no help there:
/// it is unique only within a process, and the operating system hands
/// the same number out again as soon as the thread it named has ended.
/// So two `luce` runs would happily pick `foo.lc.1.o` and write each
/// other's object, which is exactly what the name exists to prevent.
/// The thread id stays because one process really can drive several
/// builds at once, and then it is the half that tells them apart.
pub fn writerTag(buffer: *[writer_tag_bytes]u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{d}-{d}", .{
        currentProcessId(),
        std.Thread.getCurrentId(),
    }) catch unreachable;
}

fn currentProcessId() u64 {
    return switch (@import("builtin").os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        .linux => @intCast(std.os.linux.getpid()),
        else => @intCast(std.c.getpid()),
    };
}

// ---------------------------------------------------------------------------
// Linking
// ---------------------------------------------------------------------------

pub const LinkResult = union(enum) {
    /// The artifact was written to the path the caller named.
    written,
    /// It was not; the payload is a sentence for a person and is owned
    /// by the caller.
    failed: []const u8,
};

pub const LinkError = error{OutOfMemory};

/// Put an object where `kind` says it belongs: written as it is for a
/// bare object, linked into a loadable artifact or an executable
/// otherwise.
///
/// Everything temporary is written beside `output` and removed, so a
/// half-built artifact never appears under the name a loader reads.
pub fn write(
    gpa: Allocator,
    io: std.Io,
    tools: *const Tools,
    kind: Kind,
    object: []const u8,
    output: []const u8,
) LinkError!LinkResult {
    if (kind == .object) {
        writeWhole(io, output, object) catch {
            return .{ .failed = try std.fmt.allocPrint(gpa, "cannot write {s}", .{output}) };
        };
        return .written;
    }

    // A distinct name per writer, so two runs warming the same cache
    // cannot write each other's half-finished object.
    var tag_storage: [writer_tag_bytes]u8 = undefined;
    const object_path = try std.fmt.allocPrint(
        gpa,
        "{s}.{s}.o",
        .{ output, writerTag(&tag_storage) },
    );
    defer gpa.free(object_path);
    defer std.Io.Dir.cwd().deleteFile(io, object_path) catch {};
    writeWhole(io, object_path, object) catch {
        return .{ .failed = try std.fmt.allocPrint(gpa, "cannot write {s}", .{object_path}) };
    };

    return link(gpa, io, tools, kind, object_path, output);
}

/// Run the linker over one object.  The result lands at `output`
/// atomically: the driver writes a temporary beside it and the rename
/// is what publishes it, so a loader never opens a partial file.
pub fn link(
    gpa: Allocator,
    io: std.Io,
    tools: *const Tools,
    kind: Kind,
    object_path: []const u8,
    output: []const u8,
) LinkError!LinkResult {
    if (tools.runtime.len == 0) return .{ .failed = try std.fmt.allocPrint(
        gpa,
        "cannot find libluce_rt.a (looked in {s}); set LUCE_LIB to the directory holding it",
        .{if (tools.searched.len != 0) tools.searched else "nowhere"},
    ) };
    if (kind == .executable and tools.start.len == 0) return .{ .failed = try std.fmt.allocPrint(
        gpa,
        "cannot find libluce_start.a (looked in {s}); set LUCE_LIB to the directory holding it",
        .{if (tools.searched.len != 0) tools.searched else "nowhere"},
    ) };

    var tag_storage: [writer_tag_bytes]u8 = undefined;
    const pending = try std.fmt.allocPrint(
        gpa,
        "{s}.{s}.pending",
        .{ output, writerTag(&tag_storage) },
    );
    defer gpa.free(pending);
    defer std.Io.Dir.cwd().deleteFile(io, pending) catch {};

    var arguments: std.ArrayList([]const u8) = .empty;
    defer arguments.deinit(gpa);
    try arguments.append(gpa, tools.driver);
    if (kind == .library) {
        try arguments.append(gpa, "-shared");
        // Everything a Luce artifact needs is either in it or in the
        // host table it is handed, so an undefined symbol is a bug in
        // the lowering and must stop the build rather than surface as
        // a load failure. macOS refuses undefined symbols in a dylib
        // by default; elsewhere it has to be asked for.
        if (!@import("builtin").os.tag.isDarwin()) {
            try arguments.append(gpa, "-Wl,--no-undefined");
        }
    }
    try arguments.append(gpa, "-o");
    try arguments.append(gpa, pending);
    try arguments.append(gpa, object_path);
    if (kind == .executable) try arguments.append(gpa, tools.start);
    try arguments.append(gpa, tools.runtime);

    const ran = std.process.run(gpa, io, .{ .argv = arguments.items }) catch |mistake| switch (mistake) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failed = try std.fmt.allocPrint(
            gpa,
            "cannot run the linker `{s}`; set LUCE_CC to a C compiler driver",
            .{tools.driver},
        ) },
    };
    defer gpa.free(ran.stdout);
    defer gpa.free(ran.stderr);
    if (ran.term != .exited or ran.term.exited != 0) {
        return .{ .failed = try std.fmt.allocPrint(
            gpa,
            "the link failed:\n{s}",
            .{std.mem.trimEnd(u8, ran.stderr, "\n")},
        ) };
    }

    std.Io.Dir.cwd().rename(pending, std.Io.Dir.cwd(), output, io) catch {
        return .{ .failed = try std.fmt.allocPrint(gpa, "cannot write {s}", .{output}) };
    };
    return .written;
}

fn writeWhole(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writePositionalAll(io, bytes, 0);
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

/// A loaded artifact: the `.lc` it lives in, what to call, and what it
/// said about itself.  `close` unloads it, which invalidates every
/// pointer the run borrowed from it — including a trap's names.
pub const Loaded = struct {
    library: std.DynLib,
    entry: abi.Entry,
    tag: *const artifact.Artifact,

    pub fn close(self: *Loaded) void {
        self.library.close();
        self.* = undefined;
    }

    /// Whether the artifact carries trap origins (docs/MODES.md).
    pub fn debug(self: *const Loaded) bool {
        return self.tag.debug != 0;
    }
};

pub const OpenResult = union(enum) {
    loaded: Loaded,
    /// The file is not there, or the platform's loader refused it.
    unopenable,
    /// It opened, and it is not an artifact this loader may run.  The
    /// reason is the artifact tag's, which is the whole point of the
    /// tag: a wrong file says which way it is wrong.
    mismatch: artifact.Mismatch,
};

/// Open a compiled artifact and check its tag before handing back
/// anything callable.
///
/// A native artifact is not portable and a file name cannot be trusted
/// to say so, so nothing is called until the tag agrees on the magic,
/// its own layout, the ABI version, the machine, and — when the caller
/// names one — the program it was built from.
pub fn open(path: [:0]const u8, expect_hash: ?u64) OpenResult {
    var library = std.DynLib.open(path) catch return .unopenable;
    const tag = library.lookup(*const artifact.Artifact, artifact.symbol);
    if (artifact.check(tag, expect_hash)) |mismatch| {
        library.close();
        return .{ .mismatch = mismatch };
    }
    const entry = library.lookup(abi.Entry, abi.entry_symbol) orelse {
        library.close();
        return .{ .mismatch = .not_an_artifact };
    };
    return .{ .loaded = .{ .library = library, .entry = entry, .tag = tag.? } };
}

/// A sentence for a person, for each way an artifact can be refused.
pub fn explain(mismatch: artifact.Mismatch) []const u8 {
    return switch (mismatch) {
        .not_an_artifact => "it is not a compiled Luce artifact",
        .format => "its tag is a layout this loader cannot read",
        .abi_version => "it was built against a different host ABI",
        .machine => "it was built for a different machine",
        .generator => "it was built by a different code generator",
        .source => "the program it was built from has changed",
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "discovery reports where it looked, and finds nothing that is not there" {
    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory = path_storage[0..try scratch.dir.realPath(testing.io, &path_storage)];

    var empty = try discover(testing.allocator, testing.io, directory, "clang");
    defer empty.deinit(testing.allocator);
    try testing.expectEqualStrings("clang", empty.driver);
    try testing.expectEqualStrings("", empty.runtime);
    try testing.expectEqualStrings("", empty.start);
    try testing.expectEqualStrings(directory, empty.searched);

    try scratch.dir.writeFile(testing.io, .{ .sub_path = "libluce_rt.a", .data = "!<arch>\n" });
    var found = try discover(testing.allocator, testing.io, directory, null);
    defer found.deinit(testing.allocator);
    try testing.expectEqualStrings("cc", found.driver);
    try testing.expect(std.mem.endsWith(u8, found.runtime, "libluce_rt.a"));
    try testing.expectEqualStrings("", found.start);
}

test "a link with no runtime library says so instead of running the driver" {
    var tools: Tools = .{
        .driver = try testing.allocator.dupe(u8, "cc"),
        .runtime = try testing.allocator.dupe(u8, ""),
        .start = try testing.allocator.dupe(u8, ""),
        .searched = try testing.allocator.dupe(u8, "/nowhere"),
    };
    defer tools.deinit(testing.allocator);

    const result = try link(testing.allocator, testing.io, &tools, .library, "x.o", "x.lc");
    switch (result) {
        .failed => |why| {
            defer testing.allocator.free(why);
            try testing.expect(std.mem.indexOf(u8, why, "libluce_rt.a") != null);
            try testing.expect(std.mem.indexOf(u8, why, "/nowhere") != null);
        },
        else => return error.ShouldHaveFailed,
    }
}

test "opening something that is not an artifact refuses it by name" {
    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory = path_storage[0..try scratch.dir.realPath(testing.io, &path_storage)];

    const missing = try std.fs.path.joinZ(testing.allocator, &.{ directory, "absent.lc" });
    defer testing.allocator.free(missing);
    try testing.expectEqual(OpenResult.unopenable, open(missing, null));
}

test "the compiler is found beside the binary first, then on PATH, or not at all" {
    const gpa = testing.allocator;
    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory = path_storage[0..try scratch.dir.realPath(testing.io, &path_storage)];

    // Nothing beside the test binary and nothing on an empty PATH.
    var nowhere = try findCompiler(gpa, testing.io, null);
    defer nowhere.deinit(gpa);
    try testing.expect(!nowhere.found());
    // It still says where it looked, which is what the message needs.
    try testing.expect(nowhere.beside.len != 0);

    var absent = try findCompiler(gpa, testing.io, directory);
    defer absent.deinit(gpa);
    try testing.expect(!absent.found());

    // A `luce` on PATH is found, and a directory that only *mentions*
    // the name is not: the file has to be there, and it has to be a
    // thing that runs.
    try scratch.dir.writeFile(testing.io, .{
        .sub_path = compiler_name,
        .data = "#!/bin/sh\n",
        .flags = .{ .permissions = .executable_file },
    });
    const search = try std.fmt.allocPrint(gpa, "/no/such/place{c}{s}", .{ path_separator, directory });
    defer gpa.free(search);
    var located = try findCompiler(gpa, testing.io, search);
    defer located.deinit(gpa);
    try testing.expect(located.found());
    try testing.expect(std.mem.endsWith(u8, located.path, compiler_name));

    // A file named `luce` that cannot be run is *not* the compiler.
    // That is the ordinary case and not a contrived one — a source
    // directory, a stray note, an interrupted download — and stopping
    // the search at one leaves the real compiler, further down `PATH`,
    // unfound.  Windows has no execute bit and decides by extension,
    // so there is nothing to check there.
    if (std.Io.File.Permissions.has_executable_bit) {
        var inert = testing.tmpDir(.{});
        defer inert.cleanup();
        var inert_storage: [std.fs.max_path_bytes]u8 = undefined;
        const inert_directory =
            inert_storage[0..try inert.dir.realPath(testing.io, &inert_storage)];
        try inert.dir.writeFile(testing.io, .{
            .sub_path = compiler_name,
            .data = "notes about the compiler\n",
        });
        var unrunnable = try findCompiler(gpa, testing.io, inert_directory);
        defer unrunnable.deinit(gpa);
        try testing.expect(!unrunnable.found());

        // And the search goes on past it to a real one.
        const past = try std.fmt.allocPrint(
            gpa,
            "{s}{c}{s}",
            .{ inert_directory, path_separator, directory },
        );
        defer gpa.free(past);
        var beyond = try findCompiler(gpa, testing.io, past);
        defer beyond.deinit(gpa);
        try testing.expect(beyond.found());
        try testing.expect(std.mem.startsWith(u8, beyond.path, directory));
    }
}

test "every refusal has a sentence, and each says which way the artifact is wrong" {
    // Not `len != 0`: six distinct refusals whose sentences were all
    // "no" would pass that and tell a reader nothing.  What a person
    // needs is *which* way the file is wrong, so the sentences have to
    // differ from each other — and they have to be the ones the loom
    // tests below expect to read on stderr.
    const sentences = [_][]const u8{
        "it is not a compiled Luce artifact",
        "its tag is a layout this loader cannot read",
        "it was built against a different host ABI",
        "it was built for a different machine",
        "it was built by a different code generator",
        "the program it was built from has changed",
    };
    const fields = @typeInfo(artifact.Mismatch).@"enum".fields;
    try testing.expectEqual(sentences.len, fields.len);
    inline for (fields, sentences) |field, sentence| {
        try testing.expectEqualStrings(sentence, explain(@field(artifact.Mismatch, field.name)));
    }
    for (sentences, 0..) |sentence, index| {
        for (sentences[index + 1 ..]) |other| {
            try testing.expect(!std.mem.eql(u8, sentence, other));
        }
    }
}

test "a temporary is named after the process that writes it, not only its thread" {
    // The name has to survive two *processes* warming one cache, which
    // is what `zig build` does a dozen times over.  A thread id alone
    // is unique only inside a process and is handed out again once its
    // thread ends, so two runs would pick the same name and write each
    // other's half-finished object.
    var mine: [writer_tag_bytes]u8 = undefined;
    const tag = writerTag(&mine);
    try testing.expect(tag.len != 0);
    // Two numbers, and the first is this process's.
    const divider = std.mem.indexOfScalar(u8, tag, '-') orelse return error.NoProcessInTag;
    try testing.expectEqual(currentProcessId(), try std.fmt.parseInt(u64, tag[0..divider], 10));
    try testing.expect(tag[divider + 1 ..].len != 0);
    // Stable within a run: it names the writer, not the moment.
    var again: [writer_tag_bytes]u8 = undefined;
    try testing.expectEqualStrings(tag, writerTag(&again));
}
