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
const files = @import("files");

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

    if (override_lib) |value| {
        // `LUCE_LIB` is a search path now that it also names package
        // shelves (docs/PACKAGES.md D3): colon-separated, semicolon on
        // Windows, first directory holding each library wins.
        var directories = std.mem.splitScalar(u8, value, std.fs.path.delimiter);
        while (directories.next()) |directory| {
            if (directory.len == 0) continue;
            if (searched.items.len != 0) try searched.appendSlice(gpa, ", ");
            try searched.appendSlice(gpa, directory);
            if (runtime.len == 0) runtime = try fileIn(gpa, io, directory, "libluce_rt.a");
            if (start.len == 0) start = try fileIn(gpa, io, directory, "libluce_start.a");
        }
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
// Naming a temporary, and owning it
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

/// A file this build made, and is therefore allowed to remove.
///
/// **Nothing the tooling writes or deletes may collide with a file a
/// person owns**, and a name is not a proof of ownership.  Every
/// intermediate here is named after the artifact it is built beside —
/// `sums.lc.4821-3.o`, `sums.lc.4821-3.pending`, `notes.luc.4821-3.lcm`
/// — because that is the only directory a build is entitled to write
/// in; but a person may perfectly well have a file of that name, and
/// the old shape — create with truncate, delete on the way out — would
/// empty it and then delete it without ever noticing. `writerTag` makes
/// that collision improbable; it cannot make it impossible, and
/// "improbable" is not a promise to make about somebody else's files.
///
/// So a scratch file is **claimed**: created exclusively, which fails
/// if anything is already at the name, and released only when the claim
/// succeeded.  A build that meets an occupied name stops and says so
/// rather than writing over it.  After this, no path the tooling
/// deletes is a path it did not create — which is a property of the
/// code rather than of the odds.
pub const Scratch = struct {
    /// The name claimed.  Borrowed from the caller, who must keep it
    /// alive until `release`.
    path: []const u8,
    /// Whether the file is still this build's to remove.  A `rename`
    /// that succeeds hands the name away, and there is then nothing to
    /// release.
    held: bool,

    /// What claiming a name came to.
    pub const Claim = union(enum) {
        /// The name was free, and this file is now this build's.
        made: Scratch,
        /// Something is already there.  It is not this build's, so the
        /// build stops rather than writing over it.
        taken,
        /// The name could not be created at all — an unwritable
        /// directory, or a path whose parents are not there.
        unwritable,
    };

    /// Claim `path`: create it, empty, and refuse the name if anything
    /// is already under it.
    pub fn claim(io: std.Io, path: []const u8) Claim {
        const file = std.Io.Dir.cwd().createFile(io, path, .{
            .truncate = true,
            .exclusive = true,
        }) catch |refused| return switch (refused) {
            error.PathAlreadyExists => .taken,
            else => .unwritable,
        };
        file.close(io);
        return .{ .made = .{ .path = path, .held = true } };
    }

    /// Put `bytes` in the claimed file: **not atomic and not synced**,
    /// deliberately.
    ///
    /// What is written this way is handed to `cc` a line later and
    /// deleted before the build returns — it is never published, never
    /// read by a loader, and never survives a crash worth surviving.
    /// Anything a caller will *see* goes through `files.writeWhole`,
    /// which replaces atomically and syncs; the two are two names
    /// because they are two durability contracts, and the one thing a
    /// file write must not do is hide which one it is.
    pub fn fill(self: *const Scratch, io: std.Io, bytes: []const u8) !void {
        const file = try std.Io.Dir.cwd().openFile(io, self.path, .{ .mode = .write_only });
        defer file.close(io);
        try file.writePositionalAll(io, bytes, 0);
    }

    /// Publish the claimed file as `destination`, which is what makes an
    /// artifact appear whole or not at all.  The claim ends with the
    /// name: after this there is nothing left to release.
    pub fn rename(self: *Scratch, io: std.Io, destination: []const u8) !void {
        try std.Io.Dir.cwd().rename(self.path, std.Io.Dir.cwd(), destination, io);
        self.held = false;
    }

    /// Remove it, if it is still this build's to remove.
    pub fn release(self: *Scratch, io: std.Io) void {
        if (!self.held) return;
        std.Io.Dir.cwd().deleteFile(io, self.path) catch {};
        self.held = false;
    }
};

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
/// half-built artifact never appears under the name a loader reads —
/// and every temporary is *claimed* before it is written, so nothing
/// removed here was ever a file somebody else's (`Scratch`).
pub fn write(
    gpa: Allocator,
    io: std.Io,
    tools: *const Tools,
    kind: Kind,
    object: []const u8,
    output: []const u8,
) LinkError!LinkResult {
    if (kind == .object) {
        // Atomic like the linked kinds below: a half-written object
        // must not appear under the name the caller asked for, and the
        // promise above is the same one for all three kinds.
        files.writeWhole(io, output, object) catch {
            return .{ .failed = try std.fmt.allocPrint(gpa, "cannot write {s}", .{output}) };
        };
        return .written;
    }

    // A distinct name per writer, so two runs warming the same cache
    // cannot write each other's half-finished object — and claimed
    // rather than truncated, so the one it is not this build's to write
    // is refused instead (`Scratch`).
    var tag_storage: [writer_tag_bytes]u8 = undefined;
    const object_path = try std.fmt.allocPrint(
        gpa,
        "{s}.{s}.o",
        .{ output, writerTag(&tag_storage) },
    );
    defer gpa.free(object_path);
    var scratch = switch (Scratch.claim(io, object_path)) {
        .made => |claimed| claimed,
        .taken => return .{ .failed = try occupied(gpa, object_path) },
        .unwritable => return .{ .failed = try std.fmt.allocPrint(gpa, "cannot write {s}", .{object_path}) },
    };
    defer scratch.release(io);
    scratch.fill(io, object) catch {
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
    // Claimed before the driver is told to write it: `cc -o` would
    // happily replace whatever is at that name, and the rename below
    // would then carry a stranger's file away under the artifact's
    // name.  The claim is what says the name was nobody's.
    var scratch = switch (Scratch.claim(io, pending)) {
        .made => |claimed| claimed,
        .taken => return .{ .failed = try occupied(gpa, pending) },
        .unwritable => return .{ .failed = try std.fmt.allocPrint(gpa, "cannot write {s}", .{pending}) },
    };
    defer scratch.release(io);

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
    // `libluce_start.a` carries the optional macOS AppKit/Metal host for
    // standalone programs. The framework flags belong on the final link,
    // not in the archive, so an executable produced by `luce build` gets
    // the same window backend as `loom`.
    if (kind == .executable and @import("builtin").os.tag == .macos) {
        try arguments.appendSlice(gpa, &.{
            "-framework",
            "AppKit",
            "-framework",
            "Metal",
            "-framework",
            "QuartzCore",
        });
    }
    // Float `%` is `fmod`, so the runtime's semantics reach the C
    // math functions.  Darwin keeps them in libSystem, which every
    // link already gets; glibc keeps them in a library of their own
    // and it has to be asked for, after the archive that wants it.
    if (!@import("builtin").os.tag.isDarwin()) try arguments.append(gpa, "-lm");

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

    scratch.rename(io, output) catch {
        return .{ .failed = try std.fmt.allocPrint(gpa, "cannot write {s}", .{output}) };
    };
    return .written;
}

/// The sentence for a scratch name that is already a file.  It names
/// the file, because the one thing the person can do about it is move
/// that file out of the way.
fn occupied(gpa: Allocator, path: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(
        gpa,
        "{s} is already there, and a build will not write over a file it did not make; move it aside",
        .{path},
    );
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

/// A loaded artifact: the `.lc` it lives in, what to call, and what it
/// said about itself.  `close` unloads it, which invalidates every
/// pointer the run borrowed from it — including a trap's names.
///
/// The tag is a *copy*, taken from the file before it was loaded, and
/// that is not an accident of the reading order: it is the value the
/// decision to load was made on, and it stays readable whatever the
/// library does afterwards.
pub const Loaded = struct {
    library: std.DynLib,
    entry: abi.Entry,
    tag: artifact.Artifact,

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
/// to say so, so nothing is loaded until the tag agrees on the magic,
/// its own layout, the ABI version, the machine, and — when the caller
/// names one — the program it was built from.  **The tag is read out
/// of the file's own bytes first** (`readTag`); the platform loader
/// gets a turn only once it has agreed.
pub fn open(io: std.Io, path: [:0]const u8, expect_hash: ?u64) OpenResult {
    switch (readTag(io, path)) {
        .unreadable => return .unopenable,
        .damaged => return .{ .mismatch = .damaged },
        .untagged => return .{ .mismatch = .not_an_artifact },
        .tag => |found| {
            if (artifact.check(&found, expect_hash)) |mismatch| {
                return .{ .mismatch = mismatch };
            }

            // A bare word is a *library name* to a platform loader, not
            // a file: it is looked for where the system keeps libraries
            // and never in the working directory.  `loom run sums.lc`
            // means the file, so a path with no separator in it is
            // spelled `./sums.lc` before the loader sees it.  (dyld
            // happens to try the working directory last; nothing else
            // does, and relying on that made `loom run sums.lc` a
            // macOS-only spelling.)
            var relative: [std.fs.max_path_bytes]u8 = undefined;
            const named = if (std.mem.indexOfScalar(u8, path, std.fs.path.sep) != null)
                path
            else
                std.fmt.bufPrintZ(&relative, ".{c}{s}", .{ std.fs.path.sep, path }) catch
                    return .unopenable;

            var library = std.DynLib.open(named) catch return .unopenable;
            const entry = library.lookup(abi.Entry, abi.entry_symbol) orelse {
                library.close();
                return .{ .mismatch = .not_an_artifact };
            };
            return .{ .loaded = .{ .library = library, .entry = entry, .tag = found } };
        },
    }
}

/// Room for what `explain` writes.
pub const explanation_bytes = 192;

/// A sentence for a person, for each way an artifact can be refused,
/// written into `into`.
///
/// **Three of them name both sides**, because a loader refusing an
/// artifact knows two things a person does not have in front of them:
/// what the file says, and what this build is.  "It was built for a
/// different machine" leaves the reader to guess at both.
pub fn explain(mismatch: artifact.Mismatch, into: *[explanation_bytes]u8) []const u8 {
    return switch (mismatch) {
        .not_an_artifact => "it is not a compiled Luce artifact",
        .damaged => "it is truncated, or its object file is damaged",
        .format => |claimed| std.fmt.bufPrint(
            into,
            "its tag is layout version {d}, and this loader reads version {d}",
            .{ claimed, artifact.format },
        ) catch unreachable,
        .abi_version => |claimed| std.fmt.bufPrint(
            into,
            "it was built against host ABI {d}, and this loader speaks {d}",
            .{ claimed, abi.version },
        ) catch unreachable,
        .machine => |named| std.fmt.bufPrint(
            into,
            "it was built for {s}, and this machine is {s}",
            .{ named.name(), artifact.machine },
        ) catch unreachable,
        .generator => "it was built by a different code generator",
        .source => "the program it was built from has changed",
    };
}

// ---------------------------------------------------------------------------
// Reading the tag out of the file, before any loader touches it
// ---------------------------------------------------------------------------
//
// **The tag is read cold.**  It used to be read through a symbol,
// which meant `dlopen` happened first and the platform loader spoke
// first — and what a platform loader says about a broken file is not a
// sentence.  On Linux a `.lc` truncated anywhere from a quarter of the
// way to nearly all of it opens and *runs*, because the loader only
// needs the program headers and the segments they name; further in, it
// maps a segment past the end of the file and the first touch of that
// page is a SIGBUS with nothing to say.  On macOS dyld refuses it, and
// what reached the person was the loader's shrug relayed as if it were
// an answer about the program.
//
// So: open the file, walk its container's headers with every offset
// checked against the file's length before it is followed, find the
// section the tag lives in (`artifact.section`), and copy the tag out.
// Nothing is mapped, nothing is relocated, nothing runs.  A file whose
// headers describe something that is not inside it is `damaged` — an
// answer about the *file*, which is the true one.
//
// Both containers are read on both platforms, dispatched by the file's
// own magic rather than by the host, because that is what makes the
// wrong-machine sentence possible: a Linux `.lc` on macOS is an ELF
// file this reader walks happily, finds a tag in, and refuses by name.
//
// Not read: 32-bit and big-endian containers.  `luce` stamps the
// machine it is running on and cross-compiles for nothing, so an
// artifact in one of those was written by a `luce` on such a machine,
// and this loader — being 64-bit and little-endian — could not have
// built it.  It is refused as not an artifact, which is the one thing
// that is certainly true of it here.

/// What the file itself says.
const Cold = union(enum) {
    /// The tag, copied out of the section it lives in.
    tag: artifact.Artifact,
    /// The file opened and read, and holds no Luce tag: not a
    /// container this reader knows, or one with no such section.
    untagged,
    /// A header, a table, or the section itself reaches past the end of
    /// the file, or the section is too small to be a tag.
    damaged,
    /// The file could not be opened or read at all.
    unreadable,
};

/// The artifact tag `path` carries.
///
/// Small positional reads rather than one read of the whole file: a
/// `.lc` carries `libluce_rt` inside it and is a megabyte or so, while
/// what decides this is a few hundred bytes of headers.  `loom run`'s
/// promise is one `dlopen`, one lookup and one call, and this is the
/// price of not letting the first of those be a crash.
fn readTag(io: std.Io, path: []const u8) Cold {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return .unreadable;
    defer file.close(io);
    const info = file.stat(io) catch return .unreadable;
    const size = info.size;

    var head: [8]u8 = undefined;
    if ((file.readPositionalAll(io, &head, 0) catch return .unreadable) != head.len) {
        return .untagged;
    }
    // 0xfeedfacf is a 64-bit little-endian Mach-O; "\x7fELF" with class
    // 2 and data 1 is a 64-bit little-endian ELF.  Anything else is
    // some other kind of file (see the note above).
    if (std.mem.readInt(u32, head[0..4], .little) == 0xfeed_facf) {
        return readMachO(io, file, size);
    }
    if (std.mem.eql(u8, head[0..4], "\x7fELF") and head[4] == 2 and head[5] == 1) {
        return readElf(io, file, size);
    }
    return .untagged;
}

/// Read `length` bytes at `at`, refusing anything the file does not
/// actually contain.  Every walk below goes through here, which is
/// where "truncated" is answered once instead of at each step.
fn readAt(io: std.Io, file: std.Io.File, size: u64, at: u64, into: []u8) ?void {
    if (at > size or into.len > size - at) return null;
    const landed = file.readPositionalAll(io, into, at) catch return null;
    if (landed != into.len) return null;
}

/// The tag out of a section whose contents start at `at`, once the
/// section itself has been found.
fn tagAt(io: std.Io, file: std.Io.File, size: u64, at: u64, length: u64) Cold {
    if (length < @sizeOf(artifact.Artifact)) return .damaged;
    var found: artifact.Artifact = undefined;
    const into = std.mem.asBytes(&found);
    readAt(io, file, size, at, into) orelse return .damaged;
    return .{ .tag = found };
}

/// Walk a Mach-O's load commands for `__LUCE,__artifact`, checking
/// every segment against the file's length on the way.
///
/// **The whole container is checked, not only the part the tag is in.**
/// A file cut off after the tag would otherwise read as a perfectly
/// good artifact and be handed to the loader, which is the case this
/// exists to stop; a segment that claims bytes the file does not have
/// says so wherever it sits.
///
/// The offsets are the format's, written out rather than cast onto a
/// struct: this reads a file that may be damaged, so every field is
/// taken by hand at a bounds-checked offset and nothing is assumed to
/// be there because a header said it was.
fn readMachO(io: std.Io, file: std.Io.File, size: u64) Cold {
    const header_bytes = 32;
    const segment_command: u32 = 0x19; // LC_SEGMENT_64
    const segment_header_bytes = 72;
    const section_bytes = 80;
    const name_bytes = 16;

    var header: [header_bytes]u8 = undefined;
    readAt(io, file, size, 0, &header) orelse return .damaged;
    const command_count = std.mem.readInt(u32, header[16..20], .little);
    const commands_bytes = std.mem.readInt(u32, header[20..24], .little);
    if (commands_bytes > size) return .damaged;

    var found: ?Cold = null;
    var at: u64 = header_bytes;
    const end = header_bytes + @as(u64, commands_bytes);
    var seen: u32 = 0;
    while (seen < command_count) : (seen += 1) {
        var command: [8]u8 = undefined;
        readAt(io, file, size, at, &command) orelse return .damaged;
        const kind = std.mem.readInt(u32, command[0..4], .little);
        const command_bytes = std.mem.readInt(u32, command[4..8], .little);
        // A command that does not advance, or one that runs past the
        // table it is in, is a header describing something that is not
        // there.
        if (command_bytes < 8 or at + command_bytes > end) return .damaged;

        if (kind == segment_command and command_bytes >= segment_header_bytes) {
            var segment: [segment_header_bytes]u8 = undefined;
            readAt(io, file, size, at, &segment) orelse return .damaged;
            const segment_at = std.mem.readInt(u64, segment[40..48], .little);
            const segment_bytes = std.mem.readInt(u64, segment[48..56], .little);
            if (segment_at > size or segment_bytes > size - segment_at) return .damaged;

            const ours = std.mem.eql(
                u8,
                sliceName(segment[8..][0..name_bytes]),
                artifact.section.mach_segment,
            );
            const section_count = std.mem.readInt(u32, segment[64..68], .little);
            var index: u32 = 0;
            while (ours and found == null and index < section_count) : (index += 1) {
                const section_at = at + segment_header_bytes + @as(u64, index) * section_bytes;
                if (section_at + section_bytes > end) return .damaged;
                var section: [section_bytes]u8 = undefined;
                readAt(io, file, size, section_at, &section) orelse return .damaged;
                if (!std.mem.eql(u8, sliceName(section[0..name_bytes]), artifact.section.mach_name)) {
                    continue;
                }
                found = tagAt(
                    io,
                    file,
                    size,
                    std.mem.readInt(u32, section[48..52], .little),
                    std.mem.readInt(u64, section[40..48], .little),
                );
            }
        }
        at += command_bytes;
    }
    return found orelse .untagged;
}

/// A Mach-O name: up to `run.len` bytes, NUL-padded when shorter.
fn sliceName(run: []const u8) []const u8 {
    return run[0 .. std.mem.indexOfScalar(u8, run, 0) orelse run.len];
}

/// Walk an ELF's section headers for `.luce_artifact`, checking every
/// section against the file's length on the way — see `readMachO` for
/// why the whole container is checked and not only the tag's part of
/// it.
fn readElf(io: std.Io, file: std.Io.File, size: u64) Cold {
    const file_header_bytes = 64;
    const section_header_bytes = 64;

    var header: [file_header_bytes]u8 = undefined;
    readAt(io, file, size, 0, &header) orelse return .damaged;
    const table_at = std.mem.readInt(u64, header[40..48], .little);
    const entry_bytes = std.mem.readInt(u16, header[58..60], .little);
    const entry_count = std.mem.readInt(u16, header[60..62], .little);
    const names_index = std.mem.readInt(u16, header[62..64], .little);
    // A section header table this reader cannot walk: no table, an
    // entry size that is not this format's, or the extended forms
    // (`e_shnum` zero, `e_shstrndx` 0xffff) that no `cc` produces for
    // an artifact with one extra section.
    if (table_at == 0 or entry_count == 0) return .untagged;
    if (entry_bytes < section_header_bytes) return .damaged;
    if (names_index >= entry_count) return .damaged;

    // The names section, which every other section's name points into.
    var names_header: [section_header_bytes]u8 = undefined;
    readAt(
        io,
        file,
        size,
        table_at + @as(u64, names_index) * entry_bytes,
        &names_header,
    ) orelse return .damaged;
    const names_at = std.mem.readInt(u64, names_header[24..32], .little);
    const names_bytes = std.mem.readInt(u64, names_header[32..40], .little);

    const occupies_no_file_space = 8; // SHT_NOBITS — `.bss` and its kind
    var found: ?Cold = null;
    var index: u16 = 0;
    while (index < entry_count) : (index += 1) {
        var section: [section_header_bytes]u8 = undefined;
        readAt(
            io,
            file,
            size,
            table_at + @as(u64, index) * entry_bytes,
            &section,
        ) orelse return .damaged;
        const kind = std.mem.readInt(u32, section[4..8], .little);
        const section_at = std.mem.readInt(u64, section[24..32], .little);
        const section_bytes = std.mem.readInt(u64, section[32..40], .little);
        if (kind != occupies_no_file_space) {
            if (section_at > size or section_bytes > size - section_at) return .damaged;
        }
        if (found != null) continue;

        const name_at = std.mem.readInt(u32, section[0..4], .little);
        if (name_at >= names_bytes) return .damaged;
        if (!namedElf(io, file, size, names_at + name_at)) continue;
        found = tagAt(io, file, size, section_at, section_bytes);
    }
    return found orelse .untagged;
}

/// Whether the NUL-terminated name at `at` is the artifact section's.
///
/// Read rather than compared in memory because the string table is the
/// one part of an ELF this reader has no reason to hold: the name it is
/// looking for is known, so its length plus the terminator answers it.
fn namedElf(io: std.Io, file: std.Io.File, size: u64, at: u64) bool {
    const wanted = artifact.section.elf;
    var found: [wanted.len + 1]u8 = undefined;
    readAt(io, file, size, at, &found) orelse return false;
    return found[wanted.len] == 0 and std.mem.eql(u8, found[0..wanted.len], wanted);
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
    const gpa = testing.allocator;
    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory = path_storage[0..try scratch.dir.realPath(testing.io, &path_storage)];

    const missing = try std.fs.path.joinZ(gpa, &.{ directory, "absent.lc" });
    defer gpa.free(missing);
    try testing.expectEqual(OpenResult.unopenable, open(testing.io, missing, null));

    // A file that is there and is not an object file at all: the
    // reader answers about the file rather than handing it to a loader
    // to find out.
    try scratch.dir.writeFile(testing.io, .{ .sub_path = "note.lc", .data = "not an object file" });
    const note = try std.fs.path.joinZ(gpa, &.{ directory, "note.lc" });
    defer gpa.free(note);
    try testing.expect(open(testing.io, note, null).mismatch.is(.not_an_artifact));

    // Shorter than the magic it would have to begin with.
    try scratch.dir.writeFile(testing.io, .{ .sub_path = "stub.lc", .data = "\x7fEL" });
    const stub = try std.fs.path.joinZ(gpa, &.{ directory, "stub.lc" });
    defer gpa.free(stub);
    try testing.expect(open(testing.io, stub, null).mismatch.is(.not_an_artifact));
}

test "a container whose headers point outside the file is damaged, not run" {
    // Both walkers, with nothing behind the headers: an ELF whose
    // section table is past the end, and a Mach-O whose load commands
    // are.  This is the shape a truncated artifact has, and the answer
    // has to be about the file — the alternative is what a platform
    // loader does with one, which on Linux is to map a segment past the
    // end and take a SIGBUS on the first touch.
    const gpa = testing.allocator;
    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory = path_storage[0..try scratch.dir.realPath(testing.io, &path_storage)];

    var elf: [64]u8 = @splat(0);
    @memcpy(elf[0..4], "\x7fELF");
    elf[4] = 2; // 64-bit
    elf[5] = 1; // little-endian
    std.mem.writeInt(u64, elf[40..48], 1 << 40, .little); // e_shoff
    std.mem.writeInt(u16, elf[58..60], 64, .little); // e_shentsize
    std.mem.writeInt(u16, elf[60..62], 3, .little); // e_shnum
    std.mem.writeInt(u16, elf[62..64], 1, .little); // e_shstrndx
    try scratch.dir.writeFile(testing.io, .{ .sub_path = "far.lc", .data = &elf });
    const far = try std.fs.path.joinZ(gpa, &.{ directory, "far.lc" });
    defer gpa.free(far);
    try testing.expect(open(testing.io, far, null).mismatch.is(.damaged));

    var mach: [32]u8 = @splat(0);
    std.mem.writeInt(u32, mach[0..4], 0xfeed_facf, .little);
    std.mem.writeInt(u32, mach[16..20], 4, .little); // ncmds
    std.mem.writeInt(u32, mach[20..24], 4096, .little); // sizeofcmds
    try scratch.dir.writeFile(testing.io, .{ .sub_path = "cut.lc", .data = &mach });
    const cut = try std.fs.path.joinZ(gpa, &.{ directory, "cut.lc" });
    defer gpa.free(cut);
    try testing.expect(open(testing.io, cut, null).mismatch.is(.damaged));
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
    // Not `len != 0`: seven distinct refusals whose sentences were all
    // "no" would pass that and tell a reader nothing.  What a person
    // needs is *which* way the file is wrong, so the sentences have to
    // differ from each other — and they have to be the ones the loom
    // tests expect to read on stderr.
    const elsewhere = "sparc64-solaris-none";
    const refusals = [_]artifact.Mismatch{
        .not_an_artifact,
        .damaged,
        .{ .format = 99 },
        .{ .abi_version = 9999 },
        .{ .machine = .of(elsewhere) },
        .generator,
        .source,
    };
    try testing.expectEqual(@typeInfo(artifact.Mismatch).@"union".fields.len, refusals.len);

    var written: [refusals.len][explanation_bytes]u8 = undefined;
    var sentences: [refusals.len][]const u8 = undefined;
    for (refusals, 0..) |refusal, index| {
        sentences[index] = explain(refusal, &written[index]);
        try testing.expect(sentences[index].len != 0);
    }
    for (sentences, 0..) |sentence, index| {
        for (sentences[index + 1 ..]) |other| {
            try testing.expect(!std.mem.eql(u8, sentence, other));
        }
    }

    // The three that are disagreements name both sides, because the
    // loader is one of them and is holding the other.
    try testing.expectEqualStrings(
        "its tag is layout version 99, and this loader reads version " ++
            std.fmt.comptimePrint("{d}", .{artifact.format}),
        sentences[2],
    );
    try testing.expectEqualStrings(
        "it was built against host ABI 9999, and this loader speaks " ++
            std.fmt.comptimePrint("{d}", .{abi.version}),
        sentences[3],
    );
    try testing.expectEqualStrings(
        "it was built for " ++ elsewhere ++ ", and this machine is " ++ artifact.machine,
        sentences[4],
    );
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

test "a scratch name that is already a file is refused, and that file is left alone" {
    // The whole point of the claim.  The writer tag makes a collision
    // with somebody's file improbable; this makes the consequence of
    // one a refusal instead of a silent truncate-and-delete.
    const gpa = testing.allocator;
    var scratch_dir = testing.tmpDir(.{});
    defer scratch_dir.cleanup();
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory = path_storage[0..try scratch_dir.dir.realPath(testing.io, &path_storage)];

    const theirs = "notes worth keeping\n";
    try scratch_dir.dir.writeFile(testing.io, .{ .sub_path = "theirs", .data = theirs });
    const occupied_path = try std.fs.path.join(gpa, &.{ directory, "theirs" });
    defer gpa.free(occupied_path);
    try testing.expectEqual(Scratch.Claim.taken, Scratch.claim(testing.io, occupied_path));

    // Refused means untouched: not emptied, and still there.
    const after = try scratch_dir.dir.readFileAlloc(testing.io, "theirs", gpa, .unlimited);
    defer gpa.free(after);
    try testing.expectEqualStrings(theirs, after);

    // A free name is made, filled, and released — and releasing twice,
    // or releasing a claim a rename has carried away, removes nothing.
    const ours = try std.fs.path.join(gpa, &.{ directory, "ours" });
    defer gpa.free(ours);
    var held = switch (Scratch.claim(testing.io, ours)) {
        .made => |claimed| claimed,
        else => return error.ShouldHaveClaimed,
    };
    try held.fill(testing.io, "body");
    const written = try scratch_dir.dir.readFileAlloc(testing.io, "ours", gpa, .unlimited);
    defer gpa.free(written);
    try testing.expectEqualStrings("body", written);

    const published = try std.fs.path.join(gpa, &.{ directory, "published" });
    defer gpa.free(published);
    try held.rename(testing.io, published);
    held.release(testing.io);
    held.release(testing.io);
    try testing.expect(scratch_dir.dir.statFile(testing.io, "published", .{}) catch null != null);

    // And a name under a directory that is not there is unwritable
    // rather than taken: two different answers, because a person can do
    // something about one of them.
    const nowhere = try std.fs.path.join(gpa, &.{ directory, "absent", "child" });
    defer gpa.free(nowhere);
    try testing.expectEqual(Scratch.Claim.unwritable, Scratch.claim(testing.io, nowhere));
}

test "a build refuses an occupied intermediate rather than writing over it" {
    // The same rule where it matters: `write` names its object after
    // the artifact, and a file already wearing that name stops the
    // build with a sentence naming it.
    const gpa = testing.allocator;
    var scratch_dir = testing.tmpDir(.{});
    defer scratch_dir.cleanup();
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory = path_storage[0..try scratch_dir.dir.realPath(testing.io, &path_storage)];

    const output = try std.fs.path.join(gpa, &.{ directory, "sums.lc" });
    defer gpa.free(output);
    var tag_storage: [writer_tag_bytes]u8 = undefined;
    const object_name = try std.fmt.allocPrint(gpa, "sums.lc.{s}.o", .{writerTag(&tag_storage)});
    defer gpa.free(object_name);
    const theirs = "not an object file\n";
    try scratch_dir.dir.writeFile(testing.io, .{ .sub_path = object_name, .data = theirs });

    var tools: Tools = .{
        .driver = try gpa.dupe(u8, "cc"),
        .runtime = try gpa.dupe(u8, "libluce_rt.a"),
        .start = try gpa.dupe(u8, ""),
        .searched = try gpa.dupe(u8, "/nowhere"),
    };
    defer tools.deinit(gpa);

    switch (try write(gpa, testing.io, &tools, .library, "irrelevant", output)) {
        .failed => |why| {
            defer gpa.free(why);
            try testing.expect(std.mem.indexOf(u8, why, object_name) != null);
            try testing.expect(std.mem.indexOf(u8, why, "did not make") != null);
        },
        else => return error.ShouldHaveFailed,
    }

    // Untouched, and no artifact was produced under the output's name.
    const after = try scratch_dir.dir.readFileAlloc(testing.io, object_name, gpa, .unlimited);
    defer gpa.free(after);
    try testing.expectEqualStrings(theirs, after);
    try testing.expectEqual(@as(?std.Io.File.Stat, null), scratch_dir.dir.statFile(testing.io, "sums.lc", .{}) catch null);
}
