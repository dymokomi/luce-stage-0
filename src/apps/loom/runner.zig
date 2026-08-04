//! Load, compile, and run Luce programs for the loom terminal.
//!
//! Two entry paths: `runModule` opens a `.lc` and calls it, and
//! `runScript` compiles a `.luc` into one first.  Nothing bounds how
//! long a program runs — interactive programs block on key_read for as
//! long as they like — and the screen is restored before any trap is
//! reported.
//!
//! ## A `.lc` is machine code
//!
//! `loom run FILE.lc` is one `dlopen`, one symbol lookup, one call.
//! Nothing is compiled, nothing is decoded, and no compiler has to be
//! installed: the artifact carries its own tag, and a file built for
//! another machine, another host ABI or another code generator is
//! refused by name before a single instruction of it runs
//! (`luce.llvm.abi.Artifact`, `native.open`).
//!
//! ## loom does not carry a code generator
//!
//! **It runs the `luce` binary instead.**  libLLVM is 164 MB, dyld
//! binds all of it before `main`, and that costs 5.7 ms on every single
//! invocation — including the warm runs and the ones that compile
//! nothing at all.  loom's whole job is starting programs, so it pays
//! that on none of them: `luce` is the compiler and links LLVM, loom is
//! the environment and does not.  A machine that only runs Luce
//! programs then needs no LLVM installed at all — and after the format
//! change it needs no `luce` either, unless it is compiling something.
//!
//! The compiler is looked for beside loom's own executable first and on
//! `PATH` after (`native.findCompiler`), which is how a toolchain finds
//! its tools and what keeps an install tree self-consistent.  What it
//! is handed is the **serialized module** loom's own front end just
//! produced (`06_mir/module.zig`), not the source file — the artifact
//! is then keyed to the exact program about to run rather than to
//! whatever a second compile of the same text would have produced.
//!
//! ## Where a compiled `.luc` puts its artifact
//!
//! Beside the source, as `NAME.lc` — the same file `luce build
//! NAME.luc` writes, so a build can ship one and loom simply finds it.
//! It is keyed on **content**: the artifact carries a hash of the
//! serialized module it was built from, and a program whose bytes
//! changed gets a rebuild whatever the clock says about either file.
//! When there is nowhere to write beside the program — a read-only
//! directory, or a program with no path at all, like the embedded
//! editor — the artifact goes to the temp directory under its hash
//! instead, which is the same cache with a different address.
//!
//! A warm run invokes nothing external.  A cold one runs `luce` once,
//! which runs the linker once.
//!
//! ## What the shell reads afterwards
//!
//! The exit status is the program's, and it is the same number a
//! standalone `--emit=exe` binary returns, because both take it from
//! one table (`apps/host.zig`): `0` finished, `1` trapped, `3` ended
//! on an uncaught error, `70` ran out of memory, `71` could not be run
//! or could not deliver its output.  A trap and an error are two
//! different sentences about a program and get two different numbers,
//! so a script can tell them apart without parsing stderr.
//!
//! Loom's own refusals — no such file, not a program this machine can
//! run, a compile that failed — are `1`: they are this command
//! failing, and they say so on stderr before anything of the program
//! has run.

const std = @import("std");
const luce = @import("luce");
const files = @import("files");
const native = @import("native");
const host_mod = @import("host");
const report = @import("report");

const Allocator = std.mem.Allocator;
const abi = luce.llvm.abi;

pub const compile_options: luce.types.CompileOptions = .{
    .allow_host = true,
};

/// How this loom builds what it is asked to run.  Read once from the
/// environment and carried down, because it is process policy rather
/// than anything a program can change.
pub const Policy = struct {
    /// `PATH` — where the `luce` compiler is looked for after the
    /// directory loom's own binary sits in.  Everything else the
    /// compiler needs (`LUCE_LIB`, `LUCE_CC`) it reads from the
    /// environment it inherits, so loom neither parses nor forwards it.
    search_path: ?[]const u8 = null,
    /// Where an artifact goes when it cannot go beside its program.
    ///
    /// `TMPDIR` rather than a hard-coded `/tmp`, and the difference is
    /// not tidiness: a shared `/tmp` is a directory anyone can create
    /// a file in, and this one gets `dlopen`ed.  macOS gives every
    /// user a private `TMPDIR` and most Linux sessions do too; where
    /// there is none the fallback is `/tmp`, and `Places` makes its
    /// own private directory inside whichever it is rather than trust
    /// the sticky bit (see there).
    temporary_directory: []const u8 = default_temporary_directory,

    pub fn read(environment: *const std.process.Environ.Map) Policy {
        return .{
            .search_path = environment.get("PATH"),
            .temporary_directory = trimSeparator(
                environment.get("TMPDIR") orelse default_temporary_directory,
            ),
        };
    }

    /// `TMPDIR` conventionally ends in a separator and a path built
    /// from it must not end in two.
    fn trimSeparator(directory: []const u8) []const u8 {
        const trimmed = std.mem.trimEnd(u8, directory, std.fs.path.sep_str);
        return if (trimmed.len == 0) default_temporary_directory else trimmed;
    }
};

/// Run a compiled program named directly — `loom run program.lc`.
///
/// Nothing is compiled and nothing is matched against a source file:
/// the artifact's own tag is the whole story, and it is read before a
/// single instruction of the artifact runs.
pub fn runModule(
    gpa: Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    path: []const u8,
    arguments: []const []const u8,
) !u8 {
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);

    switch (native.open(path_z, null)) {
        .loaded => |opened| {
            var loaded = opened;
            defer loaded.close();
            return runLoaded(gpa, io, out, err, &loaded, arguments);
        },
        // The platform loader says only "no", never why, so the one
        // distinction worth making is made here: a file that is not
        // there and a file that is not a program are different
        // mistakes, and only the second is about the program.
        .unopenable => {
            if (std.Io.Dir.cwd().openFile(io, path, .{})) |file| {
                file.close(io);
                try err.print(
                    "loom: cannot load {s}: it is not a compiled Luce program this machine can run\n",
                    .{path},
                );
            } else |_| {
                try err.print("loom: cannot read {s}: no such file\n", .{path});
            }
            return 1;
        },
        .mismatch => |why| {
            try err.print("loom: cannot run {s}: {s}\n", .{ path, native.explain(why) });
            return 1;
        },
    }
}

/// Compile a .luc source file (plus the modules it imports, resolved
/// beside it) and run it immediately.
pub fn runScript(
    gpa: Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    policy: Policy,
    path: []const u8,
    arguments: []const []const u8,
) !u8 {
    const found = try files.readSource(gpa, io, path);
    const source = switch (found) {
        .text => |text| text.bytes,
        .missing => {
            try err.print("loom: cannot read {s}: no such file\n", .{path});
            return 1;
        },
        .unreadable => |why| {
            try err.print("loom: cannot read {s}: {s}\n", .{ path, why });
            return 1;
        },
    };
    defer gpa.free(source);
    var loader: files.FileLoader = .{ .io = io, .directory = std.fs.path.dirname(path) orelse "" };
    return runSource(gpa, io, out, err, policy, path, source, loader.loader(), arguments);
}

/// Compile source bytes (already in memory) and run them.  `name` is
/// the path they came from when there is one — it names diagnostics
/// and decides where a native artifact is kept.  The embedded editor
/// passes a bare name, which has no directory and so caches by hash.
pub fn runSource(
    gpa: Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    policy: Policy,
    name: []const u8,
    source: []const u8,
    loader: ?luce.compile.Loader,
    arguments: []const []const u8,
) !u8 {
    var options = compile_options;
    // The path as given, not its basename: a diagnostic or a trap that
    // says `bad.luc:3:1` names a file the reader still has to find.
    options.source_name = files.displayName(name);
    var result = try luce.compile.compileProject(gpa, source, loader, options);
    switch (result) {
        .success => {},
        .failure => |*diagnostics| {
            const rendered = try diagnostics.render(gpa);
            defer gpa.free(rendered);
            try err.print("loom: compile failed\n{s}", .{rendered});
            result.deinit();
            return 1;
        },
    }
    var program = result.success;
    defer program.deinit();

    // The canonical form of the program: same bytes, same hash, same
    // artifact `luce build` would produce from the same source — and
    // the bytes the compiler is handed when one has to be built.
    const encoded = try luce.mir.module.encode(gpa, &program);
    defer gpa.free(encoded);
    return run(gpa, io, out, err, policy, name, encoded, arguments);
}

/// Get this program's artifact — cached or freshly built — and run it.
///
/// `encoded` is the serialized module: what the artifact is keyed on,
/// and what the compiler is handed when one has to be built.  There is
/// nothing to fall back to and nothing to choose between, so a program
/// that cannot be compiled here is a sentence naming what was missing,
/// which is a fact the person can act on.
pub fn run(
    gpa: Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    policy: Policy,
    name: []const u8,
    encoded: []const u8,
    arguments: []const []const u8,
) !u8 {
    var refusal: ?[]const u8 = null;
    defer if (refusal) |why| gpa.free(why);
    if (try artifactFor(gpa, io, policy, name, encoded, &refusal)) |opened| {
        var loaded = opened;
        defer loaded.close();
        return runLoaded(gpa, io, out, err, &loaded, arguments);
    }
    try err.print("loom: cannot compile {s}: {s}\n", .{
        name,
        refusal orelse "the compiler is unavailable",
    });
    return 1;
}

// ---------------------------------------------------------------------------
// The compiled path
// ---------------------------------------------------------------------------

/// The native artifact for this program, opened and checked — built
/// first if there is not already a current one.  Null means the
/// compiled path is not available here, and `refusal` says why in a
/// sentence the caller owns.
fn artifactFor(
    gpa: Allocator,
    io: std.Io,
    policy: Policy,
    name: []const u8,
    encoded: []const u8,
    refusal: *?[]const u8,
) !?native.Loaded {
    const source_hash = abi.sourceHash(encoded);
    var places = try Places.of(gpa, io, policy.temporary_directory, name, source_hash);
    defer places.deinit(gpa);
    if (places.paths().len == 0) {
        refusal.* = try std.fmt.allocPrint(
            gpa,
            "there is nowhere to put the artifact: it cannot go beside the program, " ++
                "and {s} holds no private directory this user can make one in",
            .{policy.temporary_directory},
        );
        return null;
    }

    // A hit is the whole point: nothing compiled, nothing linked,
    // nothing external invoked.
    for (places.paths()) |candidate| {
        switch (native.open(candidate, source_hash)) {
            .loaded => |opened| return opened,
            .unopenable, .mismatch => {},
        }
    }

    // Cold, so the compiler has to be found — and only now, because
    // looking for it is work a warm run must not do.
    var compiler = try native.findCompiler(gpa, io, policy.search_path);
    defer compiler.deinit(gpa);
    if (!compiler.found()) {
        refusal.* = try std.fmt.allocPrint(
            gpa,
            "the `{s}` compiler is not beside {s} and not on PATH",
            .{ native.compiler_name, if (compiler.beside.len != 0) compiler.beside else "this binary" },
        );
        return null;
    }

    var last: ?[]const u8 = null;
    errdefer if (last) |why| gpa.free(why);
    for (places.paths()) |candidate| {
        if (last) |why| gpa.free(why);
        last = null;
        switch (try compileTo(gpa, io, compiler.path, encoded, candidate)) {
            .built => switch (native.open(candidate, source_hash)) {
                .loaded => |opened| return opened,
                .unopenable => last = try gpa.dupe(u8, "the artifact just built could not be loaded"),
                .mismatch => |why| last = try gpa.dupe(u8, native.explain(why)),
            },
            // Not a place-by-place failure: the program says something
            // the backend has no lowering for, and the next directory
            // would say the same.
            .refused => |why| {
                refusal.* = why;
                return null;
            },
            .failed => |why| last = why,
        }
    }
    refusal.* = last;
    return null;
}

/// What one attempt to have the compiler build an artifact came back
/// with.  Both sentences are owned by the caller.
const Attempt = union(enum) {
    /// The artifact is at the path that was asked for.
    built,
    /// Nowhere would have worked: this program cannot be compiled.
    refused: []const u8,
    /// This place did not work; another one might.
    failed: []const u8,
};

/// Ask the `luce` binary for a native artifact at `output`.
///
/// The input is the serialized module loom's own front end just made,
/// because that is the program that is about to run — not the source
/// file, which a second compile might read differently.  It is written
/// beside the artifact and removed again — on the failing path as much
/// as the succeeding one, which is what the `defer` below is for: a
/// `.lcm` is a hand-over, never a deliverable, and one left in a
/// user's directory after a failed build is litter they did not make.
/// It is also the only way a program with no file of its own (the
/// embedded editor) can be compiled at all.
fn compileTo(
    gpa: Allocator,
    io: std.Io,
    compiler: []const u8,
    encoded: []const u8,
    output: []const u8,
) !Attempt {
    // A distinct name per writer, so two looms warming the same cache
    // cannot write each other's half-written module (`native.writerTag`
    // says why it is the process and not only the thread).
    var tag_storage: [native.writer_tag_bytes]u8 = undefined;
    const module_path = try std.fmt.allocPrint(gpa, "{s}.{s}{s}", .{
        output,
        native.writerTag(&tag_storage),
        luce.mir.module.extension,
    });
    defer gpa.free(module_path);
    defer std.Io.Dir.cwd().deleteFile(io, module_path) catch {};

    files.writeWhole(io, module_path, encoded) catch {
        return .{ .failed = try std.fmt.allocPrint(gpa, "cannot write {s}", .{module_path}) };
    };

    const ran = std.process.run(gpa, io, .{
        .argv = &.{ compiler, "build", module_path, "-o", output },
    }) catch |mistake| switch (mistake) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failed = try std.fmt.allocPrint(
            gpa,
            "cannot run the compiler `{s}`",
            .{compiler},
        ) },
    };
    defer gpa.free(ran.stdout);
    defer gpa.free(ran.stderr);

    if (ran.term == .exited and ran.term.exited == 0) return .built;

    const said = std.mem.trimEnd(u8, ran.stderr, "\n");
    const why = if (said.len != 0)
        try gpa.dupe(u8, said)
    else
        try std.fmt.allocPrint(gpa, "`{s}` failed and said nothing", .{compiler});
    if (ran.term == .exited and ran.term.exited == native.exit_unsupported) {
        return .{ .refused = why };
    }
    return .{ .failed = why };
}

/// Where an artifact for this program may live, best first.
///
/// Beside the source is the honest place: deletable with it, visible in
/// a listing, and exactly the name `luce build` writes — so a warm
/// artifact can be shipped rather than earned.  The temp directory is
/// the fallback for a read-only directory or a program with no path at
/// all, and keys on the hash because there is no name to key on.
///
/// ## The spare place is a directory of this user's own
///
/// **A cached artifact is a file loom `dlopen`s, and its name is the
/// program's content hash** — which is to say, a name anyone holding
/// the same program can compute.  Where `TMPDIR` is a per-session
/// directory (macOS always, most Linux desktops) that is nobody's
/// business but the user's.  Where it is not — a bare `/tmp`, a
/// container, a daemon — it is a directory every account on the
/// machine may create files in, and the sticky bit does not help: it
/// stops one user *replacing* another's file and stops nobody from
/// creating it first.  The next loom to want that program would then
/// open a stranger's shared library and call it.
///
/// So the spare place is `luce-artifacts` inside the temp directory,
/// made `rwx------`, and used only when what is really there is a
/// directory with no group or other permissions at all.  A symbolic
/// link is refused rather than followed.  Anything else means there is
/// no spare place: a loom that recompiles every run is slow, and a
/// loom that runs somebody else's code is not loom.
///
/// **Nothing is ever swept from it**, deliberately.  The entries are
/// content-keyed, so a stale one is never loaded — a changed program
/// or a changed code generator is refused by the tag and rebuilt over
/// the same name — and a sweep would need an age policy, a lock, and a
/// way to know that no other loom is about to `dlopen` the file it is
/// deleting.  Reaping a temp directory is the operating system's job
/// and every system that has one does it; `rm -rf` on this directory
/// is always safe and costs one recompile.
const Places = struct {
    beside: ?[:0]u8 = null,
    /// Null when there is no private directory to be had.
    temporary: ?[:0]u8 = null,
    /// Scratch for `paths`, which answers a borrowed slice rather than
    /// allocating one per call.
    storage: [2][:0]const u8 = undefined,

    /// The name of the private directory made inside `TMPDIR`.
    const spare_directory = "luce-artifacts";

    fn of(
        gpa: Allocator,
        io: std.Io,
        temporary: []const u8,
        name: []const u8,
        source_hash: u64,
    ) !Places {
        var made: Places = .{};
        if (stemOf(name)) |stem| {
            made.beside = try std.fmt.allocPrintSentinel(gpa, "{s}.lc", .{stem}, 0);
        }
        errdefer if (made.beside) |path| gpa.free(path);

        const directory = try std.fmt.allocPrint(
            gpa,
            "{s}{c}{s}",
            .{ temporary, std.fs.path.sep, spare_directory },
        );
        defer gpa.free(directory);
        if (isPrivate(io, directory)) {
            made.temporary = try std.fmt.allocPrintSentinel(
                gpa,
                "{s}{c}luce-{x:0>16}.lc",
                .{ directory, std.fs.path.sep, source_hash },
                0,
            );
        }
        return made;
    }

    /// Make the spare directory if it is not there, and answer whether
    /// what is there now may be used.
    ///
    /// The two questions are one call because they are one decision:
    /// creating it is how it comes to be private, and checking it is
    /// how a directory somebody else created is refused.  A `create`
    /// that succeeded made it with the permissions asked for; a
    /// `create` that failed because something is already there has to
    /// be followed by a look at what that something is.
    fn isPrivate(io: std.Io, directory: []const u8) bool {
        const cwd = std.Io.Dir.cwd();
        if (cwd.createDir(io, directory, .fromMode(0o700))) |_| {
            // Made by this call, with these permissions.  A umask can
            // only take bits away.
            return true;
        } else |mistake| switch (mistake) {
            error.PathAlreadyExists => {},
            else => return false,
        }
        // Windows has no mode to read and no world-writable /tmp to
        // defend against; a per-user temp directory is what it gives.
        if (!std.Io.File.Permissions.has_executable_bit) return true;
        // The link is deliberately not followed: one planted where
        // this directory goes is exactly the trick being refused.
        const found = cwd.statFile(io, directory, .{ .follow_symlinks = false }) catch return false;
        if (found.kind != .directory) return false;
        return found.permissions.toMode() & 0o077 == 0;
    }

    fn deinit(self: *Places, gpa: Allocator) void {
        if (self.beside) |path| gpa.free(path);
        if (self.temporary) |path| gpa.free(path);
        self.* = undefined;
    }

    fn paths(self: *Places) []const [:0]const u8 {
        var count: usize = 0;
        if (self.beside) |path| {
            self.storage[count] = path;
            count += 1;
        }
        if (self.temporary) |path| {
            self.storage[count] = path;
            count += 1;
        }
        return self.storage[0..count];
    }
};

/// `foo.luc` names an artifact `foo.lc` beside it.  Anything else — the
/// embedded editor, a program read from a stream — has no file to sit
/// beside and answers null.
fn stemOf(name: []const u8) ?[]const u8 {
    if (std.mem.endsWith(u8, name, ".luc")) return name[0 .. name.len - ".luc".len];
    return null;
}

/// Where artifacts go when `TMPDIR` says nothing.
const default_temporary_directory = switch (@import("builtin").os.tag) {
    .windows => ".",
    else => "/tmp",
};

/// Run an opened artifact against the real host.
fn runLoaded(
    gpa: Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    loaded: *native.Loaded,
    arguments: []const []const u8,
) !u8 {
    var services: host_mod.Host = undefined;
    services.setup(gpa, io, out, err, arguments);
    defer services.deinit();

    const table = services.table();
    const status = loaded.entry(&table);

    // Land back on the ordinary screen before reporting anything.
    services.restoreScreen();
    // Output that could not be written did not happen.  A full or
    // closed pipe loses the tail of a program's transcript, and a
    // runner that returned 0 would be claiming it arrived — so the
    // failure is said once, here, and counted in the exit status.
    // The standalone binary (`apps/start.zig`) does the same.
    const delivered = if (out.flush()) |_| true else |_| undelivered: {
        err.print("loom: output could not be written\n", .{}) catch {};
        break :undelivered false;
    };
    switch (status) {
        .ok => {
            report.printLeaks(err, "loom", services.leaked orelse 0);
            return if (delivered) report.exit_ok else report.exit_broken;
        },
        .trapped => {
            const trap = services.reportedTrap() orelse {
                try err.print("loom: the program trapped and said nothing\n", .{});
                return report.exit_trapped;
            };
            report.printTrap(err, "loom", @tagName(trap.code), trap.message, trap.trace, trap.dropped);
            return report.exit_trapped;
        },
        .errored => {
            const raised = services.reportedError() orelse {
                try err.print("loom: the program failed and said nothing\n", .{});
                return report.exit_errored;
            };
            report.printError(err, "loom", @tagName(raised.code), raised.message, raised.origin);
            return report.exit_errored;
        },
        .exhausted => {
            try err.print("loom: out of memory\n", .{});
            return report.exit_exhausted;
        },
        _ => {
            try err.print("loom: the program returned an unknown status\n", .{});
            return report.exit_broken;
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the compiler is looked for on the PATH loom itself was given" {
    var environment: std.process.Environ.Map = .init(testing.allocator);
    defer environment.deinit();
    try testing.expect(Policy.read(&environment).search_path == null);

    try environment.put("PATH", "/usr/local/bin:/usr/bin");
    try testing.expectEqualStrings("/usr/local/bin:/usr/bin", Policy.read(&environment).search_path.?);
}

test "the spare artifact directory is the session's own, not a shared one" {
    var environment: std.process.Environ.Map = .init(testing.allocator);
    defer environment.deinit();
    try testing.expectEqualStrings(
        default_temporary_directory,
        Policy.read(&environment).temporary_directory,
    );

    // TMPDIR conventionally ends in a separator; a path built from it
    // must not end in two.
    try environment.put("TMPDIR", "/var/folders/ab/T/");
    try testing.expectEqualStrings("/var/folders/ab/T", Policy.read(&environment).temporary_directory);
    try environment.put("TMPDIR", "/");
    try testing.expectEqualStrings(
        default_temporary_directory,
        Policy.read(&environment).temporary_directory,
    );
}

/// The absolute path of a fresh temporary directory, for the tests
/// that need a `TMPDIR` of their own.  The caller owns it.
fn scratchDirectory(scratch: *testing.TmpDir, storage: *[std.fs.max_path_bytes]u8) ![]const u8 {
    return storage[0..try scratch.dir.realPath(testing.io, storage)];
}

test "an artifact is named beside the source it came from" {
    const gpa = testing.allocator;
    try testing.expectEqualStrings("programs/editor", stemOf("programs/editor.luc").?);
    // Nothing to sit beside: the embedded editor, or a stream.
    try testing.expectEqual(@as(?[]const u8, null), stemOf("editor"));

    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const temporary = try scratchDirectory(&scratch, &path_storage);

    var beside = try Places.of(gpa, testing.io, temporary, "programs/editor.luc", 0x1234);
    defer beside.deinit(gpa);
    try testing.expectEqualStrings("programs/editor.lc", beside.beside.?);
    try testing.expectEqual(@as(usize, 2), beside.paths().len);
    try testing.expectEqualStrings("programs/editor.lc", beside.paths()[0]);

    var anonymous = try Places.of(gpa, testing.io, temporary, "editor", 0x1234);
    defer anonymous.deinit(gpa);
    try testing.expect(anonymous.beside == null);
    try testing.expectEqual(@as(usize, 1), anonymous.paths().len);
    const expected = try std.fmt.allocPrint(
        gpa,
        "{s}/{s}/luce-0000000000001234.lc",
        .{ temporary, Places.spare_directory },
    );
    defer gpa.free(expected);
    try testing.expectEqualStrings(expected, anonymous.temporary.?);
}

test "the spare artifact directory is made private, and one that is not is not used" {
    // What goes in this directory is `dlopen`ed and named by a hash
    // anyone holding the program can compute, so on a shared /tmp the
    // file it will open can be planted before loom ever looks.  The
    // answer is a directory of this user's own; the check is what
    // makes a directory somebody else left there unusable rather than
    // trusted.
    if (!std.Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;

    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const temporary = try scratchDirectory(&scratch, &path_storage);

    // Made on first use, and private whatever the umask says.
    var fresh = try Places.of(gpa, io, temporary, "editor", 7);
    defer fresh.deinit(gpa);
    try testing.expect(fresh.temporary != null);
    const found = try scratch.dir.statFile(io, Places.spare_directory, .{});
    try testing.expectEqual(std.Io.File.Kind.directory, found.kind);
    try testing.expectEqual(@as(std.posix.mode_t, 0), found.permissions.toMode() & 0o077);

    // Found again on the next run, without being remade.
    var again = try Places.of(gpa, io, temporary, "editor", 7);
    defer again.deinit(gpa);
    try testing.expectEqualStrings(fresh.temporary.?, again.temporary.?);

    // A directory anyone may write to is refused: that is the shared
    // /tmp this whole rule exists for, one level down.
    var open = testing.tmpDir(.{});
    defer open.cleanup();
    var open_storage: [std.fs.max_path_bytes]u8 = undefined;
    const open_root = try scratchDirectory(&open, &open_storage);
    try open.dir.createDir(io, Places.spare_directory, .fromMode(0o777));
    var shared = try Places.of(gpa, io, open_root, "editor", 7);
    defer shared.deinit(gpa);
    try testing.expect(shared.temporary == null);
    // And with nowhere else to go, there is no place at all.
    try testing.expectEqual(@as(usize, 0), shared.paths().len);

    // A symbolic link where the directory should be is refused rather
    // than followed, however private its target is.
    var linked = testing.tmpDir(.{});
    defer linked.cleanup();
    var linked_storage: [std.fs.max_path_bytes]u8 = undefined;
    const linked_root = try scratchDirectory(&linked, &linked_storage);
    const target = try std.fs.path.join(gpa, &.{ temporary, Places.spare_directory });
    defer gpa.free(target);
    try linked.dir.symLink(io, target, Places.spare_directory, .{});
    var redirected = try Places.of(gpa, io, linked_root, "editor", 7);
    defer redirected.deinit(gpa);
    try testing.expect(redirected.temporary == null);
}
