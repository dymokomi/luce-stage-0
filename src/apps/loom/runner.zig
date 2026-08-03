//! Load, compile, and run Luce programs for the loom terminal.
//!
//! One boundary for three entry paths: `runModule` executes a compiled
//! `.lc`, `runArtifact` executes a native `.lcn` artifact, and
//! `runScript` compiles a `.luc` in memory and executes the result.
//! Programs run with an effectively unlimited step budget —
//! interactive programs block on key_read for as long as they like —
//! and the screen is restored before any trap is reported.
//!
//! ## Two engines, one program
//!
//! A `.lc` is portable serialized IR and can be run two ways: by the
//! interpreter, which is the reference implementation the specs prove,
//! or as native code, which measures at 0.97-1.07x of C where the
//! interpreter measures at 30-60x (docs/CODEGEN.md).  The two agree by
//! construction — one runtime library, one host, one rendering of a
//! trap — so which one ran is a performance fact and never a
//! behavioural one.
//!
//! **loom prefers native and falls back to the interpreter.**  The
//! native path needs the `luce` compiler, a lowering for everything the
//! program says, a C toolchain to link with, and somewhere to put the
//! result; when any of those is missing the program still runs, because
//! slower is better than not at all.  `LOOM_ENGINE=native` turns the
//! fallback into an error that says what was missing, and
//! `LOOM_ENGINE=interpreter` takes the reference engine on purpose —
//! which is what the `agree` tests, and any report of a disagreement,
//! need to be able to ask for.
//!
//! ## loom does not carry a code generator
//!
//! **It runs the `luce` binary instead.**  libLLVM is 164 MB, dyld
//! binds all of it before `main`, and that costs 5.7 ms on every single
//! invocation — including the warm runs and the ones that compile
//! nothing at all.  loom's whole job is starting programs, so it pays
//! that on none of them: `luce` is the compiler and links LLVM, loom is
//! the environment and does not.  A machine that only runs Luce
//! programs then needs no LLVM installed at all.
//!
//! The compiler is looked for beside loom's own executable first and on
//! `PATH` after (`native.findCompiler`), which is how a toolchain finds
//! its tools and what keeps an install tree self-consistent.  What it
//! is handed is the serialized module loom is already holding, not the
//! source — the artifact is then keyed to the exact program about to
//! run rather than to whatever a second compile of the same file would
//! have produced.  Re-encoding a decoded module is byte-identical
//! (`06_mir/module.zig`), so the hash matches by construction.
//!
//! ## Where the native artifact lives
//!
//! Beside the program, as `NAME.lcn` — the same file `luce build
//! --emit=library NAME.luc` writes, so a build can ship one warm and
//! loom simply finds it.  It is keyed on **content**: the artifact
//! carries a hash of the serialized module it was built from, and a
//! program whose bytes changed gets a rebuild whatever the clock says
//! about either file.  When there is nowhere to write beside the
//! program — a read-only directory, or a program with no path at all,
//! like the embedded editor — the artifact goes to the temp directory
//! under its hash instead, which is the same cache with a different
//! address.
//!
//! A warm run invokes nothing external: one `dlopen`, one symbol
//! lookup, one call.  A cold one runs the linker once.

const std = @import("std");
const luce = @import("luce");
const files = @import("files");
const native = @import("native");
const host_mod = @import("host");

const Allocator = std.mem.Allocator;
const abi = luce.llvm.abi;

/// Interactive programs run until they return; the step budget is
/// intentionally open-ended.  Call depth is policy, not a native
/// stack limit, and the policy is the host's — `host.call_depth` is
/// the one number, so the interpreter and a compiled artifact refuse
/// the same call.
const program_budget: luce.backend.Budget = .{
    .steps = std.math.maxInt(u64),
    .call_depth = host_mod.call_depth,
};

pub const compile_options: luce.types.CompileOptions = .{
    .entry_mode = .script,
    .allow_host = true,
};

/// Which engine runs a program.
pub const Engine = enum {
    /// Native if it can be had, the interpreter otherwise.
    auto,
    /// Native, or say why not and refuse to run.
    native,
    /// The reference engine, always.
    interpreter,
};

/// How this loom runs programs.  Read once from the environment and
/// carried down, because it is process policy rather than anything a
/// program can change.
pub const Policy = struct {
    engine: Engine = .auto,
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
    /// there is none the fallback is still `/tmp`, whose sticky bit is
    /// what is left to rely on.
    temporary_directory: []const u8 = default_temporary_directory,

    pub fn read(environment: *const std.process.Environ.Map) Policy {
        return .{
            .engine = named(environment.get("LOOM_ENGINE")) orelse .auto,
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

    fn named(text: ?[]const u8) ?Engine {
        return std.meta.stringToEnum(Engine, text orelse return null);
    }
};

/// Run a compiled module from disk: a portable `.lc`, or a native
/// `.lcn` artifact taken as it is.
pub fn runModule(
    gpa: Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    policy: Policy,
    path: []const u8,
    arguments: []const []const u8,
) !u8 {
    if (std.mem.endsWith(u8, path, native.Kind.library.extension())) {
        return runArtifact(gpa, io, out, err, path, arguments);
    }

    const encoded = files.readWhole(gpa, io, path) catch {
        try err.print("loom: cannot read {s}\n", .{path});
        return 1;
    };
    defer gpa.free(encoded);

    var program = luce.mir.module.decode(gpa, encoded) catch |mistake| switch (mistake) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedVersion => {
            try err.print("loom: {s} was built by a different luce; rebuild it from source\n", .{path});
            return 1;
        },
        error.InvalidModule => {
            try err.print("loom: {s} is not a valid .lc module\n", .{path});
            return 1;
        },
    };
    defer program.deinit();
    return run(gpa, io, out, err, policy, path, encoded, &program, arguments);
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
    var result = try luce.compile.compileProject(gpa, source, loader, .{}, options);
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

    // A script has no `.lc` on disk, so the canonical form of the
    // program is made here: same bytes, same hash, same artifact `luce
    // build` would produce from the same source — and the bytes the
    // compiler is handed when one has to be built.
    const encoded = try luce.mir.module.encode(gpa, &program);
    defer gpa.free(encoded);
    return run(gpa, io, out, err, policy, name, encoded, &program, arguments);
}

/// Run one program on whichever engine the policy allows.
///
/// `encoded` is the program in its portable form — what a native
/// artifact is keyed on, and what the compiler is handed when one has
/// to be built.
pub fn run(
    gpa: Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    policy: Policy,
    name: []const u8,
    encoded: []const u8,
    program: *const luce.mir.Program,
    arguments: []const []const u8,
) !u8 {
    if (policy.engine != .interpreter) {
        var refusal: ?[]const u8 = null;
        defer if (refusal) |why| gpa.free(why);
        if (try artifactFor(gpa, io, policy, name, encoded, &refusal)) |opened| {
            var loaded = opened;
            defer loaded.close();
            return runLoaded(gpa, io, out, err, &loaded, arguments);
        }
        // Forcing the native engine turns the fallback into a report:
        // somebody asked for compiled code and is owed the reason they
        // did not get it.
        if (policy.engine == .native) {
            try err.print("loom: cannot run {s} as native code: {s}\n", .{
                name,
                refusal orelse "the compiled path is unavailable",
            });
            return 1;
        }
    }
    return runInterpreted(gpa, io, out, err, program, arguments);
}

/// Run a native artifact named directly — `loom run program.lcn`.
/// Nothing is compiled and nothing is matched against a `.lc`: the
/// artifact's own tag is the whole story, and it is read before a
/// single instruction of the artifact runs.
pub fn runArtifact(
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
        .unopenable => {
            try err.print("loom: cannot load {s}\n", .{path});
            return 1;
        },
        .mismatch => |why| {
            try err.print("loom: cannot run {s}: {s}\n", .{ path, native.explain(why) });
            return 1;
        },
    }
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
    var places = try Places.of(gpa, policy.temporary_directory, name, source_hash);
    defer places.deinit(gpa);

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
        switch (try compileTo(gpa, io, compiler.path, name, encoded, candidate)) {
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
/// The input is the serialized module, because that is the program that
/// is about to run.  A `.lc` on disk already *is* those bytes and is
/// named where it stands; anything else — a `.luc` loom compiled in
/// memory, the embedded editor — has them written beside the artifact
/// and removed again, which is also the only way a program with no file
/// of its own can be compiled at all.
fn compileTo(
    gpa: Allocator,
    io: std.Io,
    compiler: []const u8,
    name: []const u8,
    encoded: []const u8,
    output: []const u8,
) !Attempt {
    const on_disk = std.mem.endsWith(u8, name, ".lc");
    const module_path = if (on_disk)
        try gpa.dupe(u8, name)
    else
        // A distinct name per process, so two looms warming the same
        // cache cannot write each other's half-written module.
        try std.fmt.allocPrint(gpa, "{s}.{d}.lc", .{ output, std.Thread.getCurrentId() });
    defer gpa.free(module_path);
    defer if (!on_disk) std.Io.Dir.cwd().deleteFile(io, module_path) catch {};

    if (!on_disk) files.writeWhole(io, module_path, encoded) catch {
        return .{ .failed = try std.fmt.allocPrint(gpa, "cannot write {s}", .{module_path}) };
    };

    const ran = std.process.run(gpa, io, .{
        .argv = &.{ compiler, "build", module_path, "--emit=library", "-o", output },
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
/// Beside the program is the honest place: deletable with the program,
/// visible in a listing, and exactly the name `luce build
/// --emit=library` writes — so a warm artifact can be shipped rather
/// than earned.  The temp directory is the fallback for a read-only
/// directory or a program with no path at all, and keys on the hash
/// because there is no name to key on.
const Places = struct {
    beside: ?[:0]u8 = null,
    temporary: [:0]u8,
    /// Scratch for `paths`, which answers a borrowed slice rather than
    /// allocating one per call.
    storage: [2][:0]const u8 = undefined,

    fn of(gpa: Allocator, temporary: []const u8, name: []const u8, source_hash: u64) !Places {
        var made: Places = .{ .temporary = undefined };
        if (stemOf(name)) |stem| {
            made.beside = try std.fmt.allocPrintSentinel(gpa, "{s}.lcn", .{stem}, 0);
        }
        errdefer if (made.beside) |path| gpa.free(path);
        made.temporary = try std.fmt.allocPrintSentinel(
            gpa,
            "{s}{c}luce-{x:0>16}.lcn",
            .{ temporary, std.fs.path.sep, source_hash },
            0,
        );
        return made;
    }

    fn deinit(self: *Places, gpa: Allocator) void {
        if (self.beside) |path| gpa.free(path);
        gpa.free(self.temporary);
        self.* = undefined;
    }

    fn paths(self: *Places) []const [:0]const u8 {
        if (self.beside) |path| {
            self.storage[0] = path;
            self.storage[1] = self.temporary;
            return self.storage[0..2];
        }
        self.storage[0] = self.temporary;
        return self.storage[0..1];
    }
};

/// `foo.lc` and `foo.luc` both name an artifact `foo.lcn` beside them.
/// Anything else — the embedded editor, a program read from a stream —
/// has no file to sit beside and answers null.
fn stemOf(name: []const u8) ?[]const u8 {
    if (std.mem.endsWith(u8, name, ".lc")) return name[0 .. name.len - ".lc".len];
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
    out.flush() catch {};
    switch (status) {
        .ok => {
            const leaked = services.leaked orelse 0;
            host_mod.printLeaks(err, "loom", if (leaked > 0) @intCast(leaked) else 0);
            return 0;
        },
        .trapped => {
            const trap = services.reportedTrap() orelse {
                try err.print("loom: the program trapped and said nothing\n", .{});
                return 1;
            };
            host_mod.printTrap(err, "loom", @tagName(trap.code), trap.message, trap.trace, trap.dropped);
            return 1;
        },
        .errored => {
            const raised = services.reportedError() orelse {
                try err.print("loom: the program failed and said nothing\n", .{});
                return 1;
            };
            host_mod.printError(err, "loom", @tagName(raised.code), raised.message, raised.origin);
            return 1;
        },
        .exhausted => {
            try err.print("loom: out of memory\n", .{});
            return 1;
        },
        _ => {
            try err.print("loom: the program returned an unknown status\n", .{});
            return 1;
        },
    }
}

// ---------------------------------------------------------------------------
// The reference engine
// ---------------------------------------------------------------------------

/// The execution boundary: one hosted evaluation against the real
/// terminal, filesystem, and arguments.
fn runInterpreted(
    gpa: Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    program: *const luce.mir.Program,
    arguments: []const []const u8,
) !u8 {
    var services: host_mod.Host = undefined;
    services.setup(gpa, io, out, err, arguments);
    defer services.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const outputs = try arena.allocator().alloc(?luce.backend.RuntimeValue, program.outputs.len);
    @memset(outputs, null);
    const inputs = try arena.allocator().alloc(luce.backend.InputValue, program.inputs.len);
    @memset(inputs, .unavailable);

    const result = try luce.backend.evaluateHosted(
        .{ .arena = arena.allocator(), .objects = gpa },
        program,
        inputs,
        outputs,
        program_budget,
        services.host(),
    );

    // Land back on the ordinary screen before reporting anything.
    services.restoreScreen();
    switch (result) {
        .success => |success| {
            host_mod.printLeaks(err, "loom", success.leaked_objects);
            return 0;
        },
        .trap => |trap| {
            host_mod.printTrap(err, "loom", @tagName(trap.code), trap.message, trap.trace, trap.dropped);
            return 1;
        },
        .errored => |raised| {
            host_mod.printError(err, "loom", @tagName(raised.code), raised.message, raised.origin);
            return 1;
        },
        .unavailable => {
            try err.print("loom: program inputs unavailable; is this a script module?\n", .{});
            return 1;
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the engine is named, and a name nobody recognises is not one of them" {
    var environment: std.process.Environ.Map = .init(testing.allocator);
    defer environment.deinit();
    try testing.expectEqual(Engine.auto, Policy.read(&environment).engine);

    try environment.put("LOOM_ENGINE", "interpreter");
    try testing.expectEqual(Engine.interpreter, Policy.read(&environment).engine);
    try environment.put("LOOM_ENGINE", "native");
    try testing.expectEqual(Engine.native, Policy.read(&environment).engine);
    try environment.put("LOOM_ENGINE", "quick");
    try testing.expectEqual(Engine.auto, Policy.read(&environment).engine);
}

test "the compiler is looked for on the PATH loom itself was given" {
    var environment: std.process.Environ.Map = .init(testing.allocator);
    defer environment.deinit();
    try testing.expect(Policy.read(&environment).search_path == null);

    try environment.put("PATH", "/usr/local/bin:/usr/bin");
    try testing.expectEqualStrings("/usr/local/bin:/usr/bin", Policy.read(&environment).search_path.?);
}

test "the fallback artifact directory is the session's own, not a shared one" {
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

test "an artifact is named beside the program it came from" {
    try testing.expectEqualStrings("programs/editor", stemOf("programs/editor.lc").?);
    try testing.expectEqualStrings("programs/editor", stemOf("programs/editor.luc").?);
    // Nothing to sit beside: the embedded editor, or a stream.
    try testing.expectEqual(@as(?[]const u8, null), stemOf("editor"));

    var beside = try Places.of(testing.allocator, "/scratch", "programs/editor.lc", 0x1234);
    defer beside.deinit(testing.allocator);
    try testing.expectEqualStrings("programs/editor.lcn", beside.beside.?);
    try testing.expectEqual(@as(usize, 2), beside.paths().len);
    try testing.expectEqualStrings("programs/editor.lcn", beside.paths()[0]);

    var anonymous = try Places.of(testing.allocator, "/scratch", "editor", 0x1234);
    defer anonymous.deinit(testing.allocator);
    try testing.expect(anonymous.beside == null);
    try testing.expectEqual(@as(usize, 1), anonymous.paths().len);
    try testing.expectEqualStrings("/scratch/luce-0000000000001234.lcn", anonymous.temporary);
}
