//! The two-engine harness: how the executable specification runs a
//! program.
//!
//! Every spec in this directory states a fact about the language, and
//! a fact about the language is a fact about **both** engines.  So a
//! spec never runs a program once.  It compiles once, then runs the
//! result twice — interpreted through `interpreter.run` against
//! a `Reference` host, and compiled through libLLVM, `cc` and `dlopen`
//! against a `Capture` host built from the same `World` — and demands
//! the same printed bytes, the same trap code, the same trap message,
//! the same call trace frame for frame, the same raised error, and the
//! same leak census.
//!
//! That is the whole point of keeping the interpreter (docs/ENGINE.md):
//! it ships in nothing, it is not an engine, and it exists to
//! disagree.  An oracle consulted by a handful of curated tests can
//! drift; an oracle that is the second arm of every spec cannot drift
//! silently.
//!
//! The two hosts and the world they present are `hosts.zig`, next
//! door, and this file re-exports all four names — a spec knows one
//! door into the harness and it is this one.  What is here is the
//! rest: the pipeline a spec compiles through, the two runs, and the
//! vocabulary a spec states its expectations in.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

// The language and the emitter both come in as modules.  This file
// belongs to the `specs` module, which is the one place that names
// both: `luce` links no LLVM, `emit` is the only thing that does, and
// a spec needs each of them for one of its two arms.
const luce = @import("luce");
const emit = @import("emit");

const compile = luce.compile;
const mir = luce.mir;
const types = luce.types;
const abi = luce.llvm.abi;
const lower = luce.llvm;

const Allocator = std.mem.Allocator;
const testing = std.testing;
const io = std.testing.io;

// The two hosts and the world they present, next door.  Re-exported
// rather than referred to through `hosts.`, because a spec knows one
// name for the harness and it is this file's.
const hosts = @import("hosts.zig");

/// What the two hosts offer a program (`hosts.zig`).
pub const World = hosts.World;
/// What a spec adds to that world for one run.
pub const Provided = hosts.Provided;
/// The compiled arm's host: fixed buffers, entered from machine code.
pub const Capture = hosts.Capture;
/// The oracle's host, over the same world.
pub const Reference = hosts.Reference;

// ---------------------------------------------------------------------------
// The pipeline, as a test harness
// ---------------------------------------------------------------------------

/// The options every spec compiles under: a script, with the host
/// gate open.  A spec that wants the gate shut is asking about the
/// analyzer, and that is a compile-error test.
pub const hosted: types.CompileOptions = .{
    .allow_host = true,
    .source_name = "test.luc",
};

/// Compile one script; the caller owns the program.  A compile failure
/// is a broken spec, not an outcome under test, so it fails loudly.
pub fn program(source: []const u8) !mir.Program {
    return programWith(source, hosted);
}

pub fn programWith(source: []const u8, options: types.CompileOptions) !mir.Program {
    var result = try compile.compile(testing.allocator, source, options);
    switch (result) {
        .success => |compiled| return compiled,
        .failure => |*diagnostics| {
            const rendered = try diagnostics.render(testing.allocator);
            defer testing.allocator.free(rendered);
            std.debug.print("unexpected compile failure:\n{s}", .{rendered});
            result.deinit();
            return error.CompileFailed;
        },
    }
}

/// One sibling file of a project, for the specs that compile several
/// (`compile/modules.zig`).
pub const File = struct { name: []const u8, source: []const u8 };

/// A loader over an in-memory set of files.  Nothing here touches the
/// disk: what is under test is how the compiler joins several files
/// into one program, not how a host finds them.
const Files = struct {
    all: []const File,

    fn find(
        context: *anyopaque,
        arena: Allocator,
        name: []const u8,
    ) error{OutOfMemory}!luce.source.Found {
        const self: *Files = @ptrCast(@alignCast(context));
        for (self.all) |file| {
            if (std.mem.eql(u8, file.name, name)) {
                return .{ .text = .{ .bytes = try arena.dupe(u8, file.source) } };
            }
        }
        return .missing;
    }
};

/// Compile `root` against `files` as one program; the caller owns it.
pub fn project(root: []const u8, files: []const File) !mir.Program {
    var found: Files = .{ .all = files };
    var result = try compile.compileProject(
        testing.allocator,
        root,
        .{ .context = &found, .load = Files.find },
        hosted,
    );
    switch (result) {
        .success => |compiled| return compiled,
        .failure => |*diagnostics| {
            const rendered = try diagnostics.render(testing.allocator);
            defer testing.allocator.free(rendered);
            std.debug.print("unexpected compile failure:\n{s}", .{rendered});
            result.deinit();
            return error.CompileFailed;
        },
    }
}

/// Lower `source` and hand back the textual LLVM IR; the caller owns
/// it.  Null means the program uses something with no lowering yet.
pub fn render(source: []const u8) !?[]const u8 {
    return renderBuilt(source, .debug);
}

/// The same, in either build mode, so a test can hold the two
/// artifacts side by side (docs/MODES.md).
pub fn renderBuilt(source: []const u8, mode: Mode) !?[]const u8 {
    const gpa = testing.allocator;
    var compiled = try program(source);
    defer compiled.deinit();
    if (mode == .release) mir.strip(&compiled);

    const triple = try emit.hostTriple(gpa);
    defer gpa.free(triple);

    return switch (try lower.lowerToText(gpa, &compiled, .{ .triple = triple })) {
        .text => |rendered| rendered,
        .unsupported => null,
    };
}

/// How the artifact under test was built (docs/MODES.md).  Release
/// strips the origins, which is the only difference there is.
pub const Mode = enum { debug, release };

/// Compile, lower, emit, link, load, and run `source`.  Everything the
/// run produced lands in `capture`.
pub fn run(source: []const u8, capture: *Capture, provided: Provided) !abi.Status {
    return runBuilt(source, capture, provided, .debug);
}

pub fn runBuilt(
    source: []const u8,
    capture: *Capture,
    provided: Provided,
    mode: Mode,
) !abi.Status {
    var compiled = try program(source);
    defer compiled.deinit();
    if (mode == .release) mir.strip(&compiled);
    return runProgram(&compiled, capture, provided);
}

/// The same, over a program somebody else compiled — a project of
/// several files, or one the caller stripped or optimized by hand.
pub fn runProgram(
    compiled: *const mir.Program,
    capture: *Capture,
    provided: Provided,
) !abi.Status {
    const gpa = testing.allocator;

    const triple = try emit.hostTriple(gpa);
    defer gpa.free(triple);

    const bitcode = switch (try lower.lower(gpa, compiled, .{ .triple = triple })) {
        .bitcode => |bytes| bytes,
        .unsupported => |what| {
            std.debug.print("no lowering for {s}\n", .{what});
            return error.Unsupported;
        },
    };
    defer gpa.free(bitcode);

    const object = switch (try emit.compile(gpa, bitcode, .{ .triple = triple })) {
        .object => |bytes| bytes,
        .failed => |why| {
            defer gpa.free(why);
            std.debug.print("LLVM refused the module: {s}\n", .{why});
            return error.EmitFailed;
        },
    };
    defer gpa.free(object);

    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    try scratch.dir.writeFile(io, .{ .sub_path = "program.o", .data = object });

    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory = path_storage[0..try scratch.dir.realPath(io, &path_storage)];
    const object_path = try std.fs.path.join(gpa, &.{ directory, "program.o" });
    defer gpa.free(object_path);
    const library_path = try std.fs.path.joinZ(gpa, &.{ directory, "program.so" });
    defer gpa.free(library_path);

    // The link is also the proof that the artifact declares no
    // undefined symbols beyond `libluce_rt` and the C math functions
    // its float `%` calls: every effect arrives through the host
    // table, and every semantic through the runtime library.  Darwin
    // gets libm with libSystem; elsewhere it is a library of its own
    // and `-lm` follows the archive that wants it.
    const arguments: []const []const u8 = if (builtin.os.tag.isDarwin())
        &.{ "cc", "-shared", "-o", library_path, object_path, build_options.luce_rt_library }
    else
        &.{
            "cc",                          "-shared",
            "-Wl,--no-undefined",          "-o",
            library_path,                  object_path,
            build_options.luce_rt_library, "-lm",
        };
    const linked = try std.process.run(gpa, io, .{ .argv = arguments });
    defer gpa.free(linked.stdout);
    defer gpa.free(linked.stderr);
    if (linked.term != .exited or linked.term.exited != 0) {
        std.debug.print("link failed:\n{s}\n", .{linked.stderr});
        return error.LinkFailed;
    }

    var library = try std.DynLib.open(library_path);
    defer library.close();
    const entry = library.lookup(abi.Entry, abi.entry_symbol) orelse return error.NoEntryPoint;

    const table = capture.table(provided);
    return entry(&table);
}

// ---------------------------------------------------------------------------
// The two engines, side by side
// ---------------------------------------------------------------------------

/// How a run ended, in the one vocabulary both engines answer in.
pub const End = union(enum) {
    /// The run finished; the number is what it left alive (S33 says
    /// that is zero for anything the specs run).
    finished: u32,
    trapped: mir.TrapCode,
    errored: mir.ErrorCode,
    /// The program said `exit(status)` — the fourth way a run ends.
    exited: i64,
};

/// One comparison, held open.  Most specs never touch it — they say
/// `ok`, `trap`, `errors` or `prints` below — but a spec that wants
/// the exact transcript, the exact words, or the exact trace asks the
/// session, and by then the two engines have already been made to
/// agree about all three.
pub const Session = struct {
    reference: Reference,
    capture: *Capture,
    /// How the run ended, once both engines said the same thing.
    end: End,

    pub fn deinit(self: *Session) void {
        self.reference.deinit();
        testing.allocator.destroy(self.capture);
    }

    /// What `print` wrote, plus every tagged screen effect, one per
    /// line.  Both engines produced this byte for byte.
    pub fn printed(self: *const Session) []const u8 {
        return self.reference.printed.items;
    }

    /// The words a trap or an uncaught error carried.
    pub fn message(self: *const Session) []const u8 {
        if (self.reference.trap_code != null) return self.reference.trap_message;
        return self.reference.error_message;
    }

    /// The call trace, one `function source:line:column` per line.
    pub fn trace(self: *const Session) []const u8 {
        if (self.reference.trap_code != null) return self.reference.trap_trace.items;
        return self.reference.error_origin.items;
    }

    /// The one file the world holds now, or null when it holds none.
    /// Both engines left it this way — `settle` compared them.
    pub fn file(self: *const Session) ?struct { name: []const u8, content: []const u8 } {
        const world = &self.reference.world;
        if (world.file_name_length == 0) return null;
        return .{
            .name = world.file_name[0..world.file_name_length],
            .content = world.file_content[0..world.file_content_length],
        };
    }
};

/// Run `source` both ways and demand the same bytes, the same trap
/// code, the same words, the same call trace, and the same leak
/// census.
pub fn agree(source: []const u8) !void {
    var session = try compare(source, .{});
    defer session.deinit();
}

/// The same, against a host that offers only `provided` — so a
/// withheld service has to fail closed the same way on both engines.
pub fn agreeGiven(source: []const u8, provided: Provided) !void {
    var session = try compare(source, provided);
    defer session.deinit();
}

/// The comparison itself: compile once, run twice, settle.  The caller
/// owns the session.
pub fn compare(source: []const u8, provided: Provided) !Session {
    var compiled = try program(source);
    defer compiled.deinit();
    return compareProgram(&compiled, provided);
}

/// The same, over an already-compiled program — a project of several
/// files, or one a caller built with the passes turned off.
pub fn compareProgram(compiled: *const mir.Program, provided: Provided) !Session {
    var reference: Reference = .{ .provided = provided };
    errdefer reference.deinit();
    try reference.run(compiled);

    // A `Capture` is forty kilobytes of fixed buffers, which is more
    // than a spec's stack frame should carry.
    const capture = try testing.allocator.create(Capture);
    errdefer testing.allocator.destroy(capture);
    capture.* = .{};
    const status = try runProgram(compiled, capture, provided);

    const end = try settle(&reference, capture, status);
    return .{ .reference = reference, .capture = capture, .end = end };
}

/// Compare the two arms and answer what they agreed on.
fn settle(reference: *Reference, capture: *Capture, status: abi.Status) !End {
    try testing.expectEqualStrings(reference.printed.items, capture.printed());
    try sameWorld(&reference.world, &capture.world);
    if (reference.trap_code) |code| {
        try testing.expectEqual(abi.Status.trapped, status);
        try testing.expectEqual(code, capture.trap_code.?);
        try testing.expectEqualStrings(reference.trap_message, capture.trapMessage());
        // Same frames, same lines, same "... N more" — a trap is not
        // reported identically until its trace is.
        try testing.expectEqualStrings(reference.trap_trace.items, capture.trapTrace());
        return .{ .trapped = code };
    }
    if (reference.error_code) |code| {
        // An error is news, so what has to match is the news: the
        // code, the words, and the one place it was raised
        // (docs/FAILURE.md).  Not the census — a run that ended
        // errored publishes nothing, on either engine.
        try testing.expectEqual(abi.Status.errored, status);
        try testing.expectEqual(code, capture.error_code.?);
        try testing.expectEqualStrings(reference.error_message, capture.errorMessage());
        try testing.expectEqualStrings(reference.error_origin.items, capture.errorOrigin());
        return .{ .errored = code };
    }
    if (reference.exit_status) |chosen| {
        // The program's chosen end: the same status number on both
        // engines, and the same census — the unwind skips releases on
        // both arms, so what was standing is part of what the program
        // did (docs/LANGUAGE.md).
        try testing.expectEqual(abi.Status.exited, status);
        try testing.expectEqual(chosen, capture.exit_status.?);
        try testing.expectEqual(@as(i64, reference.leaked.?), capture.leaked.?);
        return .{ .exited = chosen };
    }
    try testing.expectEqual(abi.Status.ok, status);
    try testing.expectEqual(@as(?mir.TrapCode, null), capture.trap_code);
    try testing.expectEqual(@as(i64, reference.leaked.?), capture.leaked.?);
    return .{ .finished = reference.leaked.? };
}

/// The two arms started from one world and each got a copy; they must
/// have left their copies in the same state.  The transcript catches a
/// wrong *effect*; this catches a wrong *result* of one — a file
/// written with the bytes of the previous statement, a key read one
/// time too many, a clock read that never happened.
fn sameWorld(reference: *const World, capture: *const World) !void {
    try testing.expectEqualStrings(
        reference.file_name[0..reference.file_name_length],
        capture.file_name[0..capture.file_name_length],
    );
    try testing.expectEqualStrings(
        reference.file_content[0..reference.file_content_length],
        capture.file_content[0..capture.file_content_length],
    );
    try testing.expectEqual(reference.keys_read, capture.keys_read);
    try testing.expectEqual(reference.lines_read, capture.lines_read);
    try testing.expectEqual(reference.clock, capture.clock);
}

// ---------------------------------------------------------------------------
// What a spec says
// ---------------------------------------------------------------------------
//
// Four assertions, each one "the engines agree, and here is what they
// agreed on".  A spec never reaches past these for an ordinary claim:
// the comparison is not an extra a spec opts into, it is how running a
// program works here.

/// The program runs, every `assert` in it holds, and nothing is left
/// alive — scope ownership frees everything (S33).
pub fn ok(source: []const u8) !void {
    return okGiven(source, .{});
}

pub fn okGiven(source: []const u8, provided: Provided) !void {
    var session = try compare(source, provided);
    defer session.deinit();
    return expectClean(&session);
}

/// The same, over a program the caller compiled.
pub fn okProgram(compiled: *const mir.Program, provided: Provided) !void {
    var session = try compareProgram(compiled, provided);
    defer session.deinit();
    return expectClean(&session);
}

fn expectClean(session: *const Session) !void {
    switch (session.end) {
        .finished => |left| {
            if (left == 0) return;
            std.debug.print("{d} objects leaked\n", .{left});
            return error.TestUnexpectedResult;
        },
        .trapped => |code| {
            std.debug.print("unexpected trap: {s} ({s})\n", .{ session.message(), @tagName(code) });
            return error.TestUnexpectedResult;
        },
        .errored => |code| {
            std.debug.print("unexpected error: {s} ({s})\n", .{ session.message(), @tagName(code) });
            return error.TestUnexpectedResult;
        },
        .exited => |status| {
            std.debug.print("unexpected exit({d})\n", .{status});
            return error.TestUnexpectedResult;
        },
    }
}

/// The run aborts with exactly `code`, on both engines, at the same
/// place.  Operands are deliberately held in mutable locals in these
/// programs: a compile-time-constant fault would be caught by the
/// analyzer instead and never reach an engine.
pub fn trap(source: []const u8, code: mir.TrapCode) !void {
    return trapGiven(source, .{}, code);
}

pub fn trapGiven(source: []const u8, provided: Provided, code: mir.TrapCode) !void {
    var session = try compare(source, provided);
    defer session.deinit();
    return expectTrapped(&session, code);
}

/// The same, over a program the caller compiled — and, for the checks
/// stage 4 now makes statically, over one the caller went on to
/// damage.  A trap no source program can still reach is reached from
/// here or nowhere (`src/luce/specs/ownership_spec.zig`'s S23).
pub fn trapProgram(compiled: *const mir.Program, provided: Provided, code: mir.TrapCode) !void {
    var session = try compareProgram(compiled, provided);
    defer session.deinit();
    return expectTrapped(&session, code);
}

/// The run aborts with `code`, on both engines, carrying exactly these
/// words.
///
/// `trap` proves the code; this proves the **sentence**, which is the
/// whole point of a `trap("… " + x)` and was the one thing nothing
/// pinned while the compiled path reported whatever the frame it had
/// already left behind happened to hold (GitHub #28).  The differential
/// alone is not enough here: two arms can agree on a message that is
/// wrong, and dead stack can hold the right bytes by luck.
pub fn trapSays(source: []const u8, code: mir.TrapCode, message: []const u8) !void {
    var session = try compare(source, .{});
    defer session.deinit();
    try expectTrapped(&session, code);
    try testing.expectEqualStrings(message, session.message());
}

fn expectTrapped(session: *const Session, code: mir.TrapCode) !void {
    switch (session.end) {
        .trapped => |raised| {
            if (raised == code) return;
            std.debug.print("expected trap {s}, got {s}\n", .{ @tagName(code), @tagName(raised) });
            return error.TestUnexpectedResult;
        },
        .finished => {
            std.debug.print("expected trap {s}, ran clean\n", .{@tagName(code)});
            return error.TestUnexpectedResult;
        },
        .errored => |raised| {
            std.debug.print("expected trap {s}, got error {s}\n", .{
                @tagName(code), @tagName(raised),
            });
            return error.TestUnexpectedResult;
        },
        .exited => |status| {
            std.debug.print("expected trap {s}, got exit({d})\n", .{ @tagName(code), status });
            return error.TestUnexpectedResult;
        },
    }
}

/// The run ends because the program said `exit(status)`, with exactly
/// this status on both engines — and the same transcript and census in
/// front of it, which `settle` already held them to.
pub fn exits(source: []const u8, provided: Provided, status: i64) !void {
    var session = try compare(source, provided);
    defer session.deinit();
    switch (session.end) {
        .exited => |chosen| try testing.expectEqual(status, chosen),
        .finished => {
            std.debug.print("expected exit({d}), the run finished\n", .{status});
            return error.TestUnexpectedResult;
        },
        .trapped => |raised| {
            std.debug.print("expected exit({d}), got trap {s}\n", .{ status, @tagName(raised) });
            return error.TestUnexpectedResult;
        },
        .errored => |raised| {
            std.debug.print("expected exit({d}), got error {s}\n", .{ status, @tagName(raised) });
            return error.TestUnexpectedResult;
        },
    }
}

/// The run ends as an error nobody caught, carrying exactly these
/// words (docs/FAILURE.md).
pub fn errors(
    source: []const u8,
    provided: Provided,
    code: mir.ErrorCode,
    message: []const u8,
) !void {
    var session = try compare(source, provided);
    defer session.deinit();
    switch (session.end) {
        .errored => |raised| try testing.expectEqual(code, raised),
        else => {
            std.debug.print("expected error {s}, the run did not raise\n", .{@tagName(code)});
            return error.TestUnexpectedResult;
        },
    }
    try testing.expectEqualStrings(message, session.message());
}

/// The engines agree, and this is the transcript they agreed on.
pub fn prints(source: []const u8, expected: []const u8) !void {
    return printsGiven(source, .{}, expected);
}

pub fn printsGiven(source: []const u8, provided: Provided, expected: []const u8) !void {
    var session = try compare(source, provided);
    defer session.deinit();
    try testing.expectEqualStrings(expected, session.printed());
}

// ---------------------------------------------------------------------------
// The harness's own tests
// ---------------------------------------------------------------------------

test {
    // The hosts' own tests reach the runner through here: `specs.zig`
    // names this file, and this file names theirs.
    _ = hosts;
}
