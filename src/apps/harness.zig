//! The miniature install tree both product suites drive.
//!
//! `apps/luce/product.zig` and `apps/loom/product.zig` prove the
//! *tools* — the things a person types and a build system calls — and
//! neither can be proved from inside a process, because the thing under
//! test is the process.  So both build a temporary directory laid out
//! the way `zig build --prefix` lays one out (binaries at the root, the
//! static libraries under `lib/`, which is where `native.discover`
//! looks), put the freshly built binaries in it, and use it exactly as
//! a person would.
//!
//! That much was written twice, and the second copy had already fallen
//! behind: one `write` created parent directories and the other did
//! not, so one suite could not write a nested source file at all and
//! nobody noticed, because the two copies were nine hundred lines apart
//! in different directories.  It is written once here.  What goes
//! *into* a tree still belongs to each suite — they install different
//! binaries for different reasons — and so does every assertion.
//!
//! Every stream is a real file rather than a pipe.  A pipe that fills
//! while the parent is draining the other one deadlocks, and nothing
//! here should have to know which of a program's two channels talks
//! first; a file also makes standard input something a test can simply
//! write, which is how a piped shell and `luce check -` get proved.
//!
//! Test-only, and it has no tests of its own: a harness that broke
//! would fail both suites at once, loudly, which is a better proof than
//! anything it could assert about itself.

const std = @import("std");

const testing = std.testing;
const io = std.testing.io;
const Allocator = std.mem.Allocator;

/// Where a run's three streams live inside the tree.  Dot-prefixed so a
/// test that asks what the tree holds is not answered with its own
/// plumbing.
const input_name = ".stdin";
const output_name = ".stdout";
const error_name = ".stderr";

// ---------------------------------------------------------------------------
// The tree
// ---------------------------------------------------------------------------

/// A temporary install tree, and the way to run what is in it.
pub const Install = struct {
    scratch: testing.TmpDir,
    /// The tree's real path — what a `PATH` or a `-o` argument has to
    /// say.  Owned by this Install.
    root: []const u8,

    /// An empty tree.  The caller fills it with `place` and closes it
    /// with `deinit`.
    pub fn make(gpa: Allocator) !Install {
        var scratch = testing.tmpDir(.{});
        errdefer scratch.cleanup();

        var path_storage: [std.fs.max_path_bytes]u8 = undefined;
        const root = try gpa.dupe(u8, path_storage[0..try scratch.dir.realPath(io, &path_storage)]);
        return .{ .scratch = scratch, .root = root };
    }

    pub fn deinit(self: *Install, gpa: Allocator) void {
        gpa.free(self.root);
        self.scratch.cleanup();
        self.* = undefined;
    }

    /// Copy a built file into the tree at `name`, creating whatever
    /// directories the name asks for.  `copyFile` carries the mode
    /// across, so the executable bit comes along with the bytes.
    pub fn place(self: *const Install, source: []const u8, name: []const u8) !void {
        try std.Io.Dir.cwd().copyFile(source, self.scratch.dir, name, io, .{ .make_path = true });
    }

    /// A path inside the tree; the caller owns it.
    pub fn at(self: *const Install, gpa: Allocator, name: []const u8) ![]u8 {
        return std.fs.path.join(gpa, &.{ self.root, name });
    }

    /// Write a file into the tree, creating whatever directories the
    /// name asks for — a test writes nested sources.
    pub fn write(self: *const Install, name: []const u8, text: []const u8) !void {
        if (std.fs.path.dirname(name)) |directory| {
            try self.scratch.dir.createDirPath(io, directory);
        }
        try self.scratch.dir.writeFile(io, .{ .sub_path = name, .data = text });
    }

    /// A file's whole contents; the caller owns them.
    pub fn read(self: *const Install, gpa: Allocator, name: []const u8) ![]u8 {
        return self.scratch.dir.readFileAlloc(io, name, gpa, .unlimited);
    }

    pub fn exists(self: *const Install, name: []const u8) bool {
        const file = self.scratch.dir.openFile(io, name, .{}) catch return false;
        file.close(io);
        return true;
    }

    /// Whether any entry in the tree's root ends in `suffix`.  What
    /// this is for is the temporary module: nothing may be left with
    /// that extension once a build is over, however the build ended.
    pub fn holdsAnything(self: *const Install, suffix: []const u8) !bool {
        var directory = try self.scratch.dir.openDir(io, ".", .{ .iterate = true });
        defer directory.close(io);
        var walk = directory.iterate();
        while (try walk.next(io)) |entry| {
            if (std.mem.endsWith(u8, entry.name, suffix)) return true;
        }
        return false;
    }

    /// Write `script` into the tree at `name`, runnable — for the
    /// stand-in binaries a suite plants where a real one would go.
    pub fn writeScript(self: *const Install, gpa: Allocator, name: []const u8, script: []const u8) !void {
        const path = try self.at(gpa, name);
        defer gpa.free(path);
        const file = try std.Io.Dir.cwd().createFile(io, path, .{
            .truncate = true,
            .permissions = .executable_file,
        });
        defer file.close(io);
        try file.writePositionalAll(io, script, 0);
    }

    /// Run anything, with the three streams on files inside the tree.
    /// The caller owns the answer (`Ran.deinit`).
    pub fn spawn(
        self: *const Install,
        gpa: Allocator,
        argv: []const []const u8,
        options: Spawn,
    ) !Ran {
        const input: std.process.SpawnOptions.StdIo = if (options.input) |text| stream: {
            try self.write(input_name, text);
            break :stream .{ .file = try self.scratch.dir.openFile(io, input_name, .{}) };
        } else .ignore;
        defer if (input == .file) input.file.close(io);

        const out_file = try self.scratch.dir.createFile(io, output_name, .{ .truncate = true });
        defer out_file.close(io);
        const err_file = try self.scratch.dir.createFile(io, error_name, .{ .truncate = true });
        defer err_file.close(io);

        var child = try std.process.spawn(io, .{
            .argv = argv,
            .environ_map = options.environment,
            .stdin = input,
            .stdout = .{ .file = out_file },
            .stderr = .{ .file = err_file },
        });
        const term = try child.wait(io);

        return .{
            .status = if (term == .exited) term.exited else 255,
            .out = try self.read(gpa, output_name),
            .err = try self.read(gpa, error_name),
        };
    }
};

/// What a run is given beyond its arguments.  `environment` null
/// inherits this process's, which is what leaves a `cc` on the `PATH`
/// for a compile that has to link; `input` null gives the child nothing
/// to read, which is what makes an interactive program non-interactive.
pub const Spawn = struct {
    environment: ?*const std.process.Environ.Map = null,
    input: ?[]const u8 = null,
};

/// What one run of a real binary did.
pub const Ran = struct {
    status: u8,
    out: []u8,
    err: []u8,

    pub fn deinit(self: *Ran, gpa: Allocator) void {
        gpa.free(self.out);
        gpa.free(self.err);
        self.* = undefined;
    }

    pub fn saysOut(self: *const Ran, words: []const u8) bool {
        return std.mem.indexOf(u8, self.out, words) != null;
    }

    pub fn saysErr(self: *const Ran, words: []const u8) bool {
        return std.mem.indexOf(u8, self.err, words) != null;
    }
};

/// This process's environment with `additions` laid over it; the caller
/// owns the map.
///
/// A map handed to a child *replaces* its environment rather than
/// adding to it, and a cold run is a link: taking `PATH` away takes
/// `cc` away with it, and the build fails for a reason the test was not
/// asking about.  So setting one variable means copying the lot.  A
/// test that wants a world with nothing in it builds a bare map instead
/// and does not come here.
pub fn environmentWith(gpa: Allocator, additions: []const [2][]const u8) !std.process.Environ.Map {
    var count: usize = 0;
    while (std.c.environ[count] != null) : (count += 1) {}
    const inherited: std.process.Environ = .{ .block = .{ .slice = std.c.environ[0..count :null] } };
    var map = try inherited.createMap(gpa);
    errdefer map.deinit();
    for (additions) |pair| try map.put(pair[0], pair[1]);
    return map;
}
