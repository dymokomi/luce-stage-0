//! Turning a lowered program into something that runs: the link, the
//! artifact tag, and the load.
//!
//! Stage 10 stops at a relocatable object (`docs/CODEGEN.md`).  What
//! stands between that and a program a person can run is a linker
//! invocation and — for the loadable form — a loader that refuses the
//! wrong artifact by name.  Both `luce` and `loom` need exactly that,
//! so it is written once here, the way `files.zig` is written once.
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

// ---------------------------------------------------------------------------
// What is being produced
// ---------------------------------------------------------------------------

/// The three shapes a compiled program is asked for.
pub const Kind = enum {
    /// A relocatable object; the caller links it (`docs/CODEGEN.md`).
    object,
    /// A shared library a loader opens: what loom caches and runs, and
    /// what an embedder loads.  Carries the artifact tag.
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
            // artifact with a tag, and the name should say which of the
            // two files beside a program it is.  `.lcn` reads as "the
            // native form of the .lc", which is what it is.
            .library => ".lcn",
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
// Compiling and linking
// ---------------------------------------------------------------------------

pub const BuildResult = union(enum) {
    /// The artifact was written to the path the caller named.
    written,
    /// Something has no lowering yet; the payload names it and is
    /// static storage.
    unsupported: []const u8,
    /// The build failed; the payload is a sentence for a person and is
    /// owned by the caller.
    failed: []const u8,
};

pub const BuildError = error{OutOfMemory};

/// Lower `program`, emit an object for the host, and — unless a bare
/// object was asked for — link it into `output`.
///
/// `source_hash` is what the artifact's tag will claim it was built
/// from (`abi.sourceHash` of the serialized module), so a loader can
/// tell a stale cache entry from a current one.  Pass zero when
/// nothing will cache this.
///
/// Everything temporary is written beside `output` and removed, so a
/// half-built artifact never appears under the name a loader reads.
pub fn build(
    gpa: Allocator,
    io: std.Io,
    tools: *const Tools,
    program: *const luce.mir.Program,
    options: struct {
        kind: Kind,
        output: []const u8,
        source_hash: u64 = 0,
        triple: []const u8,
    },
) BuildError!BuildResult {
    const bitcode = switch (try luce.llvm.lower(gpa, program, .{
        .triple = options.triple,
        .source_hash = options.source_hash,
    })) {
        .bitcode => |bytes| bytes,
        .unsupported => |what| return .{ .unsupported = what },
    };
    defer gpa.free(bitcode);

    const object = switch (try luce.llvm.compile(gpa, bitcode, .{ .triple = options.triple })) {
        .object => |bytes| bytes,
        .failed => |why| return .{ .failed = why },
    };
    defer gpa.free(object);

    if (options.kind == .object) {
        writeWhole(io, options.output, object) catch {
            return .{ .failed = try std.fmt.allocPrint(gpa, "cannot write {s}", .{options.output}) };
        };
        return .written;
    }

    // A distinct name per process, so two loom runs warming the same
    // cache cannot write each other's half-finished object.
    const object_path = try std.fmt.allocPrint(
        gpa,
        "{s}.{d}.o",
        .{ options.output, std.Thread.getCurrentId() },
    );
    defer gpa.free(object_path);
    defer std.Io.Dir.cwd().deleteFile(io, object_path) catch {};
    writeWhole(io, object_path, object) catch {
        return .{ .failed = try std.fmt.allocPrint(gpa, "cannot write {s}", .{object_path}) };
    };

    return link(gpa, io, tools, options.kind, object_path, options.output);
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
) BuildError!BuildResult {
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

    const pending = try std.fmt.allocPrint(
        gpa,
        "{s}.{d}.pending",
        .{ output, std.Thread.getCurrentId() },
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

/// A loaded artifact: the library it lives in, what to call, and what
/// it said about itself.  `close` unloads it, which invalidates every
/// pointer the run borrowed from it — including a trap's names.
pub const Loaded = struct {
    library: std.DynLib,
    entry: abi.Entry,
    tag: *const abi.Artifact,

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
    mismatch: abi.Mismatch,
};

/// Open a compiled artifact and check its tag before handing back
/// anything callable.
///
/// A native artifact is not portable and a file name cannot be trusted
/// to say so, so nothing is called until the tag agrees on the magic,
/// its own layout, the ABI version, the machine, and — when the caller
/// names one — the program it was built from.
pub fn open(path: [:0]const u8, triple: []const u8, expect_hash: ?u64) OpenResult {
    var library = std.DynLib.open(path) catch return .unopenable;
    const tag = library.lookup(*const abi.Artifact, abi.artifact_symbol);
    if (abi.checkArtifact(tag, triple, expect_hash)) |mismatch| {
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
pub fn explain(mismatch: abi.Mismatch) []const u8 {
    return switch (mismatch) {
        .not_an_artifact => "it is not a compiled Luce artifact",
        .format => "it was built by a different luce",
        .abi_version => "it was built against a different host ABI",
        .triple => "it was built for a different machine",
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

    const result = try link(testing.allocator, testing.io, &tools, .library, "x.o", "x.lcn");
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

    const missing = try std.fs.path.joinZ(testing.allocator, &.{ directory, "absent.lcn" });
    defer testing.allocator.free(missing);
    try testing.expectEqual(OpenResult.unopenable, open(missing, "any", null));
}

test "every refusal has a sentence" {
    inline for (@typeInfo(abi.Mismatch).@"enum".fields) |field| {
        try testing.expect(explain(@field(abi.Mismatch, field.name)).len != 0);
    }
}

// ---------------------------------------------------------------------------
// The product path, end to end
// ---------------------------------------------------------------------------
//
// `08_llvm/test.zig` proves the *lowering* by linking and loading a
// program itself.  These prove the *product*: the same `build`, `open`
// and link the shipped `luce` and `loom` call, over the installed
// libraries, producing an artifact that a loader accepts and a shell
// can execute.  A gap between the two is exactly how "parity exists in
// a test harness and is delivered to nobody" happens again.

const build_options = @import("build_options");

/// A host for a compiled program, in fixed storage.  It is entered
/// from a `dlopen`ed library, and `std.testing.allocator` captures a
/// stack trace on every allocation: the unwinder cannot walk back
/// through the compiled program's frame.  So this one never allocates.
const Recorder = struct {
    printed: [4096]u8 = undefined,
    length: usize = 0,
    trap_code: ?i32 = null,
    trap_words: [256]u8 = undefined,
    trap_length: usize = 0,
    frames: usize = 0,

    fn table(self: *Recorder) abi.Host {
        return .{ .context = self, .print = print, .trap = trap };
    }

    fn text(self: *const Recorder) []const u8 {
        return self.printed[0..self.length];
    }

    fn trapped(self: *const Recorder) []const u8 {
        return self.trap_words[0..self.trap_length];
    }

    fn of(context: ?*anyopaque) *Recorder {
        return @ptrCast(@alignCast(context.?));
    }

    fn print(context: ?*anyopaque, bytes: [*]const u8, length: i64) callconv(.c) abi.Answer {
        const self = of(context);
        const said = bytes[0..@intCast(length)];
        if (self.length + said.len + 1 > self.printed.len) return .exhausted;
        @memcpy(self.printed[self.length..][0..said.len], said);
        self.length += said.len;
        self.printed[self.length] = '\n';
        self.length += 1;
        return .yes;
    }

    fn trap(
        context: ?*anyopaque,
        code: i32,
        message: [*]const u8,
        message_length: i64,
        frames: [*]const abi.TraceFrame,
        frame_count: i64,
        dropped: i64,
    ) callconv(.c) void {
        _ = frames;
        _ = dropped;
        const self = of(context);
        const words = message[0..@intCast(message_length)];
        self.trap_code = code;
        self.trap_length = @min(words.len, self.trap_words.len);
        @memcpy(self.trap_words[0..self.trap_length], words[0..self.trap_length]);
        self.frames = @intCast(frame_count);
    }
};

/// The installed libraries, as the shipped code would have found them.
fn installedTools(gpa: Allocator) !Tools {
    return .{
        .driver = try gpa.dupe(u8, "cc"),
        .runtime = try gpa.dupe(u8, build_options.luce_rt_library),
        .start = try gpa.dupe(u8, build_options.luce_start_library),
        .searched = try gpa.dupe(u8, "the build tree"),
    };
}

fn compileScript(gpa: Allocator, source: []const u8) !luce.mir.Program {
    var result = try luce.compile.compile(gpa, source, .{}, .{
        .entry_mode = .script,
        .allow_host = true,
        .source_name = "product.luc",
    });
    switch (result) {
        .success => |compiled| return compiled,
        .failure => {
            result.deinit();
            return error.CompileFailed;
        },
    }
}

const counter =
    \\func total(limit: Int) -> Int:
    \\    var sum = 0
    \\    var index = 0
    \\    while index < limit:
    \\        sum = sum + index * index
    \\        index = index + 1
    \\    return sum
    \\
    \\func main():
    \\    print(str(total(10)))
    \\
;

test "a program links, loads with its tag intact, and runs" {
    const gpa = testing.allocator;
    var tools = try installedTools(gpa);
    defer tools.deinit(gpa);

    var program = try compileScript(gpa, counter);
    defer program.deinit();
    const encoded = try luce.mir.module.encode(gpa, &program);
    defer gpa.free(encoded);
    const hash = abi.sourceHash(encoded);

    const triple = try luce.llvm.hostTriple(gpa);
    defer gpa.free(triple);

    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory = path_storage[0..try scratch.dir.realPath(testing.io, &path_storage)];
    const artifact = try std.fs.path.joinZ(gpa, &.{ directory, "product.lcn" });
    defer gpa.free(artifact);

    switch (try build(gpa, testing.io, &tools, &program, .{
        .kind = .library,
        .output = artifact,
        .source_hash = hash,
        .triple = triple,
    })) {
        .written => {},
        .unsupported => |what| {
            std.debug.print("no lowering for {s}\n", .{what});
            return error.Unsupported;
        },
        .failed => |why| {
            defer gpa.free(why);
            std.debug.print("{s}\n", .{why});
            return error.BuildFailed;
        },
    }

    // The object the link consumed is gone, and nothing half-written
    // is left under the artifact's name.
    var left: std.ArrayList(u8) = .empty;
    defer left.deinit(gpa);
    var listing = try scratch.dir.openDir(testing.io, ".", .{ .iterate = true });
    defer listing.close(testing.io);
    var walk = listing.iterate();
    while (try walk.next(testing.io)) |entry| {
        try left.appendSlice(gpa, entry.name);
        try left.append(gpa, ' ');
    }
    try testing.expectEqualStrings("product.lcn ", left.items);

    var loaded = switch (open(artifact, triple, hash)) {
        .loaded => |opened| opened,
        .unopenable => return error.CouldNotLoad,
        .mismatch => |why| {
            std.debug.print("refused: {s}\n", .{explain(why)});
            return error.Refused;
        },
    };
    defer loaded.close();

    // The tag says what it is, and a debug build kept its origins.
    try testing.expectEqual(abi.version, loaded.tag.abi_version);
    try testing.expectEqual(hash, loaded.tag.source_hash);
    try testing.expect(loaded.debug());

    var recorder: Recorder = .{};
    const table = recorder.table();
    try testing.expectEqual(abi.Status.ok, loaded.entry(&table));
    try testing.expectEqualStrings("285\n", recorder.text());
}

test "an artifact built from another program is refused as stale" {
    const gpa = testing.allocator;
    var tools = try installedTools(gpa);
    defer tools.deinit(gpa);

    var program = try compileScript(gpa, counter);
    defer program.deinit();

    const triple = try luce.llvm.hostTriple(gpa);
    defer gpa.free(triple);

    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory = path_storage[0..try scratch.dir.realPath(testing.io, &path_storage)];
    const artifact = try std.fs.path.joinZ(gpa, &.{ directory, "stale.lcn" });
    defer gpa.free(artifact);

    switch (try build(gpa, testing.io, &tools, &program, .{
        .kind = .library,
        .output = artifact,
        .source_hash = 0x1111_2222_3333_4444,
        .triple = triple,
    })) {
        .written => {},
        else => return error.BuildFailed,
    }

    // Content decides, and nothing else: the file is there, it loads,
    // it has a `luce_main` — and it is still the wrong program.
    try testing.expectEqual(abi.Mismatch.source, open(artifact, triple, 0xdead_beef).mismatch);
    try testing.expectEqual(
        abi.Mismatch.triple,
        open(artifact, "sparc-sun-solaris", 0x1111_2222_3333_4444).mismatch,
    );
    switch (open(artifact, triple, 0x1111_2222_3333_4444)) {
        .loaded => |opened| {
            var loaded = opened;
            loaded.close();
        },
        else => return error.ShouldHaveLoaded,
    }
}

test "a standalone executable prints, and a trapping one reports and exits nonzero" {
    const gpa = testing.allocator;
    var tools = try installedTools(gpa);
    defer tools.deinit(gpa);

    const triple = try luce.llvm.hostTriple(gpa);
    defer gpa.free(triple);

    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory = path_storage[0..try scratch.dir.realPath(testing.io, &path_storage)];

    // A program that says something, then divides by zero two frames
    // down — so the trace has something to say as well.
    var program = try compileScript(gpa,
        \\func divide(a: Int, b: Int) -> Int:
        \\    return a / b
        \\
        \\func main():
        \\    print("alive")
        \\    if arg_count() == 1:
        \\        print(str(divide(1, 0)))
        \\
    );
    defer program.deinit();

    const binary = try std.fs.path.join(gpa, &.{ directory, "program" });
    defer gpa.free(binary);
    switch (try build(gpa, testing.io, &tools, &program, .{
        .kind = .executable,
        .output = binary,
        .triple = triple,
    })) {
        .written => {},
        .unsupported => return error.Unsupported,
        .failed => |why| {
            defer gpa.free(why);
            std.debug.print("{s}\n", .{why});
            return error.BuildFailed;
        },
    }

    const ran = try std.process.run(gpa, testing.io, .{ .argv = &.{binary} });
    defer gpa.free(ran.stdout);
    defer gpa.free(ran.stderr);
    try testing.expectEqual(@as(u8, 0), ran.term.exited);
    try testing.expectEqualStrings("alive\n", ran.stdout);
    try testing.expectEqualStrings("", ran.stderr);

    const trapped = try std.process.run(gpa, testing.io, .{ .argv = &.{ binary, "boom" } });
    defer gpa.free(trapped.stdout);
    defer gpa.free(trapped.stderr);
    // Nonzero, the program's own output up to the trap, and a trace
    // with `file:line:column` — the promise docs/MODES.md makes about
    // a debug build, kept by a binary nothing is watching.
    try testing.expectEqual(@as(u8, 1), trapped.term.exited);
    try testing.expectEqualStrings("alive\n", trapped.stdout);
    try testing.expect(std.mem.indexOf(u8, trapped.stderr, "division by zero") != null);
    try testing.expect(std.mem.indexOf(u8, trapped.stderr, "at divide (product.luc:2:5)") != null);
    try testing.expect(std.mem.indexOf(u8, trapped.stderr, "at main (product.luc:7:9)") != null);
}

test "a release executable keeps the function names and drops the lines" {
    const gpa = testing.allocator;
    var tools = try installedTools(gpa);
    defer tools.deinit(gpa);

    const triple = try luce.llvm.hostTriple(gpa);
    defer gpa.free(triple);

    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory = path_storage[0..try scratch.dir.realPath(testing.io, &path_storage)];

    var program = try compileScript(gpa,
        \\func divide(a: Int, b: Int) -> Int:
        \\    return a / b
        \\
        \\func main():
        \\    print(str(divide(1, 0)))
        \\
    );
    defer program.deinit();
    luce.mir.strip(&program);

    const binary = try std.fs.path.join(gpa, &.{ directory, "stripped" });
    defer gpa.free(binary);
    switch (try build(gpa, testing.io, &tools, &program, .{
        .kind = .executable,
        .output = binary,
        .triple = triple,
    })) {
        .written => {},
        else => return error.BuildFailed,
    }

    const ran = try std.process.run(gpa, testing.io, .{ .argv = &.{binary} });
    defer gpa.free(ran.stdout);
    defer gpa.free(ran.stderr);
    try testing.expectEqual(@as(u8, 1), ran.term.exited);
    try testing.expect(std.mem.indexOf(u8, ran.stderr, "    at divide\n") != null);
    try testing.expect(std.mem.indexOf(u8, ran.stderr, "    at main\n") != null);
    try testing.expect(std.mem.indexOf(u8, ran.stderr, "product.luc") == null);
}
