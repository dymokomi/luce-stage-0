//! The compiler's back half: lower, emit, link.
//!
//! `luce` is the only binary that carries a code generator, so this is
//! the only file above the language module that imports `emit` — and
//! therefore the only one that drags libLLVM into a process.  `loom`
//! reaches the same artifacts through `apps/native.zig`, which links
//! nothing and knows only how to find tools, run a linker, and open a
//! tagged library (`docs/CODEGEN.md`).
//!
//! One function: take a verified program and put it on disk in one of
//! the three native shapes.  What differs between them is only what is
//! linked around the same object.

const std = @import("std");
const luce = @import("luce");
const native = @import("native");
const emit = @import("emit");

const Allocator = std.mem.Allocator;
const abi = luce.llvm.abi;

pub const Result = union(enum) {
    /// The artifact was written to the path the caller named.
    written,
    /// Something has no lowering yet; the payload names it and is
    /// static storage.
    unsupported: []const u8,
    /// The build failed; the payload is a sentence for a person and is
    /// owned by the caller.
    failed: []const u8,
};

pub const Error = error{OutOfMemory};

/// Lower `program`, emit an object for the host, and — unless a bare
/// object was asked for — link it into `output`.
///
/// `source_hash` is what the artifact's tag will claim it was built
/// from (`abi.sourceHash` of the serialized module), so a loader can
/// tell a stale cache entry from a current one.  Pass zero when
/// nothing will cache this.
///
/// The target is the host, and asking LLVM which host that is happens
/// here rather than at a call site: nothing above this line has an
/// opinion about triples, and nothing above it should have to link the
/// library that knows one.
pub fn build(
    gpa: Allocator,
    io: std.Io,
    tools: *const native.Tools,
    program: *const luce.mir.Program,
    options: struct {
        kind: native.Kind,
        output: []const u8,
        source_hash: u64 = 0,
    },
) Error!Result {
    const triple = try emit.hostTriple(gpa);
    defer gpa.free(triple);

    const bitcode = switch (try luce.llvm.lower(gpa, program, .{
        .triple = triple,
        .source_hash = options.source_hash,
    })) {
        .bitcode => |bytes| bytes,
        .unsupported => |what| return .{ .unsupported = what },
    };
    defer gpa.free(bitcode);

    const object = switch (try emit.compile(gpa, bitcode, .{ .triple = triple })) {
        .object => |bytes| bytes,
        .failed => |why| return .{ .failed = why },
    };
    defer gpa.free(object);

    return switch (try native.write(gpa, io, tools, options.kind, object, options.output)) {
        .written => .written,
        .failed => |why| .{ .failed = why },
    };
}

// ---------------------------------------------------------------------------
// The product path, end to end
// ---------------------------------------------------------------------------
//
// `08_llvm/test.zig` proves the *lowering* by linking and loading a
// program itself.  These prove the *product*: the same `build`, `open`
// and link the shipped `luce` calls, over the installed libraries,
// producing an artifact that a loader accepts and a shell can execute.
// A gap between the two is exactly how "parity exists in a test harness
// and is delivered to nobody" happens again.

const testing = std.testing;
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
        return .{ .context = self, .print = print, .trap = trap, .raised = raised };
    }

    fn text(self: *const Recorder) []const u8 {
        return self.printed[0..self.length];
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

    /// The other way a run can end.  This recorder only ever runs
    /// programs that finish or trap, so an error arriving here means
    /// the test drifted — record it as a trap code nobody expects and
    /// let the assertion say so.
    fn raised(
        context: ?*anyopaque,
        code: i32,
        message: [*]const u8,
        message_length: i64,
        origin: *const abi.TraceFrame,
    ) callconv(.c) void {
        _ = origin;
        const self = of(context);
        const words = message[0..@intCast(message_length)];
        self.trap_code = code;
        self.trap_length = @min(words.len, self.trap_words.len);
        @memcpy(self.trap_words[0..self.trap_length], words[0..self.trap_length]);
    }
};

/// The installed libraries, as the shipped code would have found them.
fn installedTools(gpa: Allocator) !native.Tools {
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

    var loaded = switch (native.open(artifact, hash)) {
        .loaded => |opened| opened,
        .unopenable => return error.CouldNotLoad,
        .mismatch => |why| {
            std.debug.print("refused: {s}\n", .{native.explain(why)});
            return error.Refused;
        },
    };
    defer loaded.close();

    // The tag says what it is, and a debug build kept its origins.
    try testing.expectEqual(abi.version, loaded.tag.abi_version);
    try testing.expectEqual(hash, loaded.tag.source_hash);
    // And what wrote it, which is the fact that decides whether a
    // `.lcn` found beside a program may be run or has to be rebuilt.
    try testing.expectEqual(abi.artifact_format, loaded.tag.format);
    try testing.expectEqual(abi.generator, loaded.tag.generator);
    try testing.expect(loaded.debug());
    try testing.expectEqualStrings(
        abi.machine,
        loaded.tag.machine[0..@intCast(loaded.tag.machine_length)],
    );

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
    })) {
        .written => {},
        else => return error.BuildFailed,
    }

    // Content decides, and nothing else: the file is there, it loads,
    // it has a `luce_main` — and it is still the wrong program.
    try testing.expectEqual(abi.Mismatch.source, native.open(artifact, 0xdead_beef).mismatch);
    switch (native.open(artifact, 0x1111_2222_3333_4444)) {
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
