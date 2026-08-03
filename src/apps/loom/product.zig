//! The two binaries, proved together.
//!
//! `loom` does not carry a code generator: when it meets a program with
//! no current artifact beside it, it runs the `luce` binary to build
//! one (`runner.zig`).  That hand-off is a property of the *installed
//! pair*, not of either module, so nothing short of running both
//! executables can prove it — these tests build a miniature install
//! tree in a temporary directory and use it exactly as a person would.
//!
//! What they hold to:
//!
//!   * a `.luc` with no artifact present compiles and runs, and leaves
//!     the artifact beside itself for the next run to find;
//!   * the `.lc` `luce build` writes runs under a loom that has no
//!     compiler at all, because a `.lc` is machine code;
//!   * and a loom that cannot find `luce` says so, naming the binary
//!     that is missing and where it was looked for — there is no
//!     second engine to fall back to, and a `.luc` needs a compiler
//!     exactly as a `.c` does.

const std = @import("std");
const build_options = @import("build_options");

const testing = std.testing;
const io = std.testing.io;
const Allocator = std.mem.Allocator;

/// A miniature install tree: `loom` and `luce` at the root, the runtime
/// library under `lib/`, which is the layout `zig build --prefix`
/// produces and the one `native.discover` looks for.
const Install = struct {
    scratch: testing.TmpDir,
    root: []const u8,
    loom: []const u8,

    fn make(gpa: Allocator, with_compiler: bool) !Install {
        var scratch = testing.tmpDir(.{});
        errdefer scratch.cleanup();

        var path_storage: [std.fs.max_path_bytes]u8 = undefined;
        const root = try gpa.dupe(u8, path_storage[0..try scratch.dir.realPath(io, &path_storage)]);
        errdefer gpa.free(root);

        // `copyFile` carries the mode across, so the executable bit
        // comes along with the bytes.
        try std.Io.Dir.cwd().copyFile(build_options.loom_binary, scratch.dir, "loom", io, .{});
        if (with_compiler) {
            try std.Io.Dir.cwd().copyFile(build_options.luce_binary, scratch.dir, "luce", io, .{});
            try std.Io.Dir.cwd().copyFile(
                build_options.luce_rt_library,
                scratch.dir,
                "lib/libluce_rt.a",
                io,
                .{ .make_path = true },
            );
        }

        return .{ .scratch = scratch, .root = root, .loom = try std.fs.path.join(gpa, &.{ root, "loom" }) };
    }

    fn deinit(self: *Install, gpa: Allocator) void {
        gpa.free(self.loom);
        gpa.free(self.root);
        self.scratch.cleanup();
        self.* = undefined;
    }

    /// A path inside the tree; the caller owns it.
    fn at(self: *const Install, gpa: Allocator, name: []const u8) ![]u8 {
        return std.fs.path.join(gpa, &.{ self.root, name });
    }

    fn exists(self: *const Install, name: []const u8) bool {
        const file = self.scratch.dir.openFile(io, name, .{}) catch return false;
        file.close(io);
        return true;
    }

    fn write(self: *const Install, name: []const u8, text: []const u8) !void {
        try self.scratch.dir.writeFile(io, .{ .sub_path = name, .data = text });
    }

    fn read(self: *const Install, gpa: Allocator, name: []const u8) ![]u8 {
        return self.scratch.dir.readFileAlloc(io, name, gpa, .unlimited);
    }

    /// Put a stand-in where the compiler goes: a script that records
    /// having been called, says something, and exits with `status`.
    ///
    /// The real compiler cannot be made to fail on demand — every
    /// program a script can express lowers — so the exit-code contract
    /// between the two binaries is proved against a stand-in that can.
    fn plantCompiler(self: *const Install, gpa: Allocator, status: u8, says: []const u8) !void {
        // `echo` and the redirect are shell builtins; nothing here runs
        // a program, because the PATH these tests hand loom holds only
        // the install tree and there is no `dirname` on it.
        const script = try std.fmt.allocPrint(gpa,
            \\#!/bin/sh
            \\echo call >> "{s}/calls"
            \\echo "{s}" >&2
            \\exit {d}
            \\
        , .{ self.root, says, status });
        defer gpa.free(script);
        const path = try self.at(gpa, "luce");
        defer gpa.free(path);
        const file = try std.Io.Dir.cwd().createFile(io, path, .{
            .truncate = true,
            .permissions = .executable_file,
        });
        defer file.close(io);
        try file.writePositionalAll(io, script, 0);
    }

    /// How many times the stand-in was called.
    fn calls(self: *const Install, gpa: Allocator) !usize {
        const text = self.read(gpa, "calls") catch return 0;
        defer gpa.free(text);
        return std.mem.count(u8, text, "\n");
    }
};

/// Run the installed loom.  `environment` null inherits this process's,
/// which is what gives the compiler a `cc` to link with.
fn runLoom(
    gpa: Allocator,
    install: *const Install,
    arguments: []const []const u8,
    environment: ?*const std.process.Environ.Map,
) !std.process.RunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, install.loom);
    try argv.appendSlice(gpa, arguments);
    return std.process.run(gpa, io, .{ .argv = argv.items, .environ_map = environment });
}

const greeting =
    \\func main():
    \\    var total = 0
    \\    for index in range(0, 5):
    \\        total = total + index * index
    \\    print("total " + str(total))
    \\
;

const expected = "total 30\n";

test "a .luc with no artifact is compiled by luce and runs, warm the next time" {
    const gpa = testing.allocator;
    var install = try Install.make(gpa, true);
    defer install.deinit(gpa);
    try install.write("sums.luc", greeting);

    const program = try install.at(gpa, "sums.luc");
    defer gpa.free(program);

    try testing.expect(!install.exists("sums.lc"));
    const cold = try runLoom(gpa, &install, &.{program}, null);
    defer gpa.free(cold.stdout);
    defer gpa.free(cold.stderr);
    try testing.expectEqualStrings("", cold.stderr);
    try testing.expectEqualStrings(expected, cold.stdout);
    try testing.expectEqual(@as(u8, 0), cold.term.exited);

    // The compiler left the artifact where the next run will find it.
    try testing.expect(install.exists("sums.lc"));

    const warm = try runLoom(gpa, &install, &.{program}, null);
    defer gpa.free(warm.stdout);
    defer gpa.free(warm.stderr);
    try testing.expectEqualStrings("", warm.stderr);
    try testing.expectEqualStrings(expected, warm.stdout);
}

test "the .lc luce writes runs on a loom with no compiler at all" {
    const gpa = testing.allocator;
    var install = try Install.make(gpa, true);
    defer install.deinit(gpa);
    try install.write("sums.luc", greeting);

    const compiler = try install.at(gpa, "luce");
    defer gpa.free(compiler);
    const source = try install.at(gpa, "sums.luc");
    defer gpa.free(source);
    const built = try std.process.run(gpa, io, .{ .argv = &.{ compiler, "build", source } });
    defer gpa.free(built.stdout);
    defer gpa.free(built.stderr);
    try testing.expectEqual(@as(u8, 0), built.term.exited);
    try testing.expect(install.exists("sums.lc"));

    // The compiler is taken away, and so is anything a build could
    // need: what is left is a `.lc`, a loom, and a `dlopen`.
    try install.scratch.dir.deleteFile(io, "luce");
    var bare: std.process.Environ.Map = .init(gpa);
    defer bare.deinit();
    try bare.put("PATH", install.root);

    const artifact = try install.at(gpa, "sums.lc");
    defer gpa.free(artifact);
    const ran = try runLoom(gpa, &install, &.{ "run", artifact }, &bare);
    defer gpa.free(ran.stdout);
    defer gpa.free(ran.stderr);
    try testing.expectEqualStrings("", ran.stderr);
    try testing.expectEqualStrings(expected, ran.stdout);
    try testing.expectEqual(@as(u8, 0), ran.term.exited);
}

test "a .luc with no luce to compile it says which binary is missing and where it looked" {
    const gpa = testing.allocator;
    var install = try Install.make(gpa, false);
    defer install.deinit(gpa);
    try install.write("sums.luc", greeting);

    const program = try install.at(gpa, "sums.luc");
    defer gpa.free(program);

    // An environment with nowhere to find a compiler: not beside loom,
    // because nothing was installed there, and not on PATH.
    var bare: std.process.Environ.Map = .init(gpa);
    defer bare.deinit();
    try bare.put("PATH", install.root);

    const ran = try runLoom(gpa, &install, &.{program}, &bare);
    defer gpa.free(ran.stdout);
    defer gpa.free(ran.stderr);
    try testing.expectEqual(@as(u8, 1), ran.term.exited);
    try testing.expectEqualStrings("", ran.stdout);
    // The tool by name, the directory it should have been in, and the
    // other place that was tried — enough to act on without guessing.
    try testing.expect(std.mem.indexOf(u8, ran.stderr, "`luce`") != null);
    try testing.expect(std.mem.indexOf(u8, ran.stderr, install.root) != null);
    try testing.expect(std.mem.indexOf(u8, ran.stderr, "PATH") != null);
    // Nothing was built, and nothing was left behind pretending to be.
    try testing.expect(!install.exists("sums.lc"));
}

test "a compiler that refuses the program is asked once; one that fails a place is asked again" {
    const gpa = testing.allocator;

    // Exit 1 is about *this attempt*, so the other place is tried: two
    // calls, one beside the program and one in the temp directory.
    {
        var install = try Install.make(gpa, false);
        defer install.deinit(gpa);
        try install.write("sums.luc", greeting);
        try install.plantCompiler(gpa, 1, "luce: cannot write it");

        const program = try install.at(gpa, "sums.luc");
        defer gpa.free(program);
        var environment: std.process.Environ.Map = .init(gpa);
        defer environment.deinit();
        try environment.put("PATH", install.root);
        try environment.put("TMPDIR", install.root);

        const ran = try runLoom(gpa, &install, &.{program}, &environment);
        defer gpa.free(ran.stdout);
        defer gpa.free(ran.stderr);
        try testing.expectEqual(@as(u8, 1), ran.term.exited);
        // Whatever the compiler said is what the reader is told.
        try testing.expect(std.mem.indexOf(u8, ran.stderr, "cannot write it") != null);
        try testing.expectEqual(@as(usize, 2), try install.calls(gpa));
    }

    // Exit 2 is about the *program*, and no directory changes that.
    {
        var install = try Install.make(gpa, false);
        defer install.deinit(gpa);
        try install.write("sums.luc", greeting);
        try install.plantCompiler(gpa, 2, "sums.lc: linking failed: no C toolchain");

        const program = try install.at(gpa, "sums.luc");
        defer gpa.free(program);
        var environment: std.process.Environ.Map = .init(gpa);
        defer environment.deinit();
        try environment.put("PATH", install.root);
        try environment.put("TMPDIR", install.root);

        const ran = try runLoom(gpa, &install, &.{program}, &environment);
        defer gpa.free(ran.stdout);
        defer gpa.free(ran.stderr);
        try testing.expectEqual(@as(u8, 1), ran.term.exited);
        try testing.expect(std.mem.indexOf(u8, ran.stderr, "no C toolchain") != null);
        try testing.expectEqual(@as(usize, 1), try install.calls(gpa));
    }
}
