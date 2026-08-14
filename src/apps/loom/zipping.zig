//! A person zips and unzips, with nothing but the install tree.
//!
//! `std.zip` is proved as a library in `specs/zip_spec.zig` — the
//! format, against archives other people wrote, on both engines.  This
//! is the other half of that claim and it cannot be made from inside a
//! process: the program is `examples/zipper/zipper.luc`, it is compiled by the
//! installed `luce`, run by the installed `loom`, and the archives it
//! reads and writes are real files in a real directory.  A library
//! nobody can run is a claim rather than a capability, and the distance
//! between the two is exactly what these rows walk.
//!
//! What they hold to:
//!
//!   * an archive **Info-ZIP wrote** — the same bytes `zip_spec.zig`
//!     embeds — is listed, extracted to files whose contents are what
//!     Info-ZIP put in them, zipped again from those files, and
//!     extracted a second time to the same bytes.  Read, write, read:
//!     the fixed point is on disk, and every step is a process;
//!   * a name that climbs out of the directory it was given (`..`) or
//!     names its own absolute place is **refused, with nothing
//!     written** — zip-slip is the oldest bug in extraction, and the
//!     only proof of its absence is an archive that carries the attack
//!     and a directory that stays empty;
//!   * an entry under a directory that is not there is *named*, before
//!     any byte is written, because zipper cannot make a directory
//!     (docs/MISSING.md) and half an extraction is worse than none;
//!   * every command line answers with a status a shell can read;
//!   * and where the machine has Info-ZIP's own `zip` and `unzip`,
//!     **they agree**: `unzip -t` accepts an archive zipper wrote,
//!     deflate and all, and an archive `zip` wrote reads back through
//!     zipper byte for byte.  Where the machine has not, those rows say
//!     so out loud and the embedded-fixture rows above are the floor —
//!     they are unconditional, and they are the ones that prove the
//!     format.
//!
//! `product.zig` next door proves the *pair*; this file proves the
//! userland program the pair exists to run, which is why it is not in
//! there.

const std = @import("std");
const build_options = @import("build_options");
const harness = @import("harness");

const testing = std.testing;
const io = std.testing.io;
const Allocator = std.mem.Allocator;
const Install = harness.Install;
const Ran = harness.Ran;

/// The shipped program, by build-system import rather than a relative
/// `@embedFile` — for the reason loom's shell takes one for the editor:
/// a test that pinned its own inline copy of zipper would pin nothing.
const zipper_source = @embedFile("zipper.luc");

/// What `luce build` writes when a program is refused or a link fails,
/// and what a program that raised an error it did not handle exits
/// with; `report.zig` owns the table and these are two rows of it.
const exit_errored: u8 = 3;
/// What zipper exits with when the command line is wrong — its own
/// choice, and the conventional one for usage.
const exit_usage: u8 = 2;

// ---------------------------------------------------------------------------
// The yard
// ---------------------------------------------------------------------------

/// An install tree with zipper compiled in it, and a way to run it the
/// way a person does: from inside the directory the files are in, with
/// relative paths.
const Yard = struct {
    tree: Install,

    fn open(gpa: Allocator) !Yard {
        var tree = try Install.make(gpa);
        errdefer tree.deinit(gpa);
        try tree.place(build_options.loom_binary, "loom");
        try tree.place(build_options.luce_binary, "luce");
        try tree.place(build_options.luce_rt_library, "lib/libluce_rt.a");
        try tree.write("zipper.luc", zipper_source);

        // A `.lc` is machine code, so this is a link: the environment
        // is inherited, because taking `PATH` away takes `cc` with it.
        const compiler = try tree.at(gpa, "luce");
        defer gpa.free(compiler);
        var built = try tree.spawn(gpa, &.{ compiler, "build", "zipper.luc", "--emit=library", "-o", "zipper.lc" }, .{
            .in_tree = true,
        });
        defer built.deinit(gpa);
        if (built.status != 0) {
            std.debug.print("zipper did not build:\n{s}\n{s}\n", .{ built.out, built.err });
            return error.ZipperDidNotBuild;
        }
        return .{ .tree = tree };
    }

    fn deinit(self: *Yard, gpa: Allocator) void {
        self.tree.deinit(gpa);
        self.* = undefined;
    }

    /// `loom run zipper.lc ARGUMENTS...`, standing in the tree.
    fn run(self: *const Yard, gpa: Allocator, arguments: []const []const u8) !Ran {
        const loom = try self.tree.at(gpa, "loom");
        defer gpa.free(loom);
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ loom, "run", "zipper.lc" });
        try argv.appendSlice(gpa, arguments);
        return self.tree.spawn(gpa, argv.items, .{ .in_tree = true });
    }

    /// A run that had better have worked: status 0 and a silent stderr.
    /// The caller owns the answer.
    fn expectRuns(self: *const Yard, gpa: Allocator, arguments: []const []const u8) !Ran {
        var ran = try self.run(gpa, arguments);
        errdefer ran.deinit(gpa);
        if (ran.status != 0 or ran.err.len != 0) {
            std.debug.print("zipper {s}: status {d}\n{s}\n{s}\n", .{
                arguments[0],
                ran.status,
                ran.out,
                ran.err,
            });
            return error.ZipperFailed;
        }
        return ran;
    }

    /// A file in the tree, byte for byte.
    fn expectFile(self: *const Yard, gpa: Allocator, name: []const u8, wanted: []const u8) !void {
        const found = try self.tree.read(gpa, name);
        defer gpa.free(found);
        try testing.expectEqualStrings(wanted, found);
    }
};

// ---------------------------------------------------------------------------
// Other people's bytes
// ---------------------------------------------------------------------------

/// Two files stored whole by Info-ZIP — `a.txt` holding "hello\n" and
/// `b.txt` holding "world contents here\n".
///
/// **The same 220 bytes `specs/zip_spec.zig` embeds**, and deliberately
/// so: the library suite reads them in a process with no world, and
/// these rows carry them out to a disk and back through two more
/// processes, so both halves are talking about one archive.  They are
/// copied rather than shared because `specs/` is a module of its own
/// and holds them as Luce source (a `list(byte)` literal a program
/// builds), which is not a thing Zig can read.  Anyone changing one
/// copy is changing what the other proves.
const stored_archive = [_]u8{
    0x50, 0x4b, 0x03, 0x04, 0x0a, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf9, 0x8b,
    0x06, 0x5d, 0x20, 0x30, 0x3a, 0x36, 0x06, 0x00, 0x00, 0x00, 0x06, 0x00,
    0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x61, 0x2e, 0x74, 0x78, 0x74, 0x68,
    0x65, 0x6c, 0x6c, 0x6f, 0x0a, 0x50, 0x4b, 0x03, 0x04, 0x0a, 0x00, 0x00,
    0x00, 0x00, 0x00, 0xf9, 0x8b, 0x06, 0x5d, 0xb7, 0x5a, 0xda, 0x4b, 0x14,
    0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x62,
    0x2e, 0x74, 0x78, 0x74, 0x77, 0x6f, 0x72, 0x6c, 0x64, 0x20, 0x63, 0x6f,
    0x6e, 0x74, 0x65, 0x6e, 0x74, 0x73, 0x20, 0x68, 0x65, 0x72, 0x65, 0x0a,
    0x50, 0x4b, 0x01, 0x02, 0x1e, 0x03, 0x0a, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xf9, 0x8b, 0x06, 0x5d, 0x20, 0x30, 0x3a, 0x36, 0x06, 0x00, 0x00, 0x00,
    0x06, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0xa4, 0x81, 0x00, 0x00, 0x00, 0x00, 0x61, 0x2e,
    0x74, 0x78, 0x74, 0x50, 0x4b, 0x01, 0x02, 0x1e, 0x03, 0x0a, 0x00, 0x00,
    0x00, 0x00, 0x00, 0xf9, 0x8b, 0x06, 0x5d, 0xb7, 0x5a, 0xda, 0x4b, 0x14,
    0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xa4, 0x81, 0x29, 0x00, 0x00,
    0x00, 0x62, 0x2e, 0x74, 0x78, 0x74, 0x50, 0x4b, 0x05, 0x06, 0x00, 0x00,
    0x00, 0x00, 0x02, 0x00, 0x02, 0x00, 0x66, 0x00, 0x00, 0x00, 0x60, 0x00,
    0x00, 0x00, 0x00, 0x00,
};

const first_name = "a.txt";
const first_contents = "hello\n";
const second_name = "b.txt";
const second_contents = "world contents here\n";

/// One entry called `../escape.txt`, written by Python's `zipfile`
/// because no honest archiver will author one — which is the point.
/// This is zip-slip: an extractor that joins the name to the target
/// directory and writes what comes out puts the file one level *above*
/// where it was told to, and every published instance of the bug looked
/// exactly like this archive.
const slip_archive = [_]u8{
    0x50, 0x4b, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf2, 0x3e,
    0x07, 0x5d, 0xfb, 0x5e, 0xb3, 0x85, 0x06, 0x00, 0x00, 0x00, 0x06, 0x00,
    0x00, 0x00, 0x0d, 0x00, 0x00, 0x00, 0x2e, 0x2e, 0x2f, 0x65, 0x73, 0x63,
    0x61, 0x70, 0x65, 0x2e, 0x74, 0x78, 0x74, 0x70, 0x77, 0x6e, 0x65, 0x64,
    0x0a, 0x50, 0x4b, 0x01, 0x02, 0x14, 0x03, 0x14, 0x00, 0x00, 0x00, 0x00,
    0x00, 0xf2, 0x3e, 0x07, 0x5d, 0xfb, 0x5e, 0xb3, 0x85, 0x06, 0x00, 0x00,
    0x00, 0x06, 0x00, 0x00, 0x00, 0x0d, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x01, 0x00, 0x00, 0x00, 0x00, 0x2e,
    0x2e, 0x2f, 0x65, 0x73, 0x63, 0x61, 0x70, 0x65, 0x2e, 0x74, 0x78, 0x74,
    0x50, 0x4b, 0x05, 0x06, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
    0x3b, 0x00, 0x00, 0x00, 0x31, 0x00, 0x00, 0x00, 0x00, 0x00,
};

/// The same attack said the other way: one entry called
/// `/etc/passwd`, which ignores the target directory entirely.
const absolute_archive = [_]u8{
    0x50, 0x4b, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf2, 0x3e,
    0x07, 0x5d, 0xfb, 0x5e, 0xb3, 0x85, 0x06, 0x00, 0x00, 0x00, 0x06, 0x00,
    0x00, 0x00, 0x0b, 0x00, 0x00, 0x00, 0x2f, 0x65, 0x74, 0x63, 0x2f, 0x70,
    0x61, 0x73, 0x73, 0x77, 0x64, 0x70, 0x77, 0x6e, 0x65, 0x64, 0x0a, 0x50,
    0x4b, 0x01, 0x02, 0x14, 0x03, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf2,
    0x3e, 0x07, 0x5d, 0xfb, 0x5e, 0xb3, 0x85, 0x06, 0x00, 0x00, 0x00, 0x06,
    0x00, 0x00, 0x00, 0x0b, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x80, 0x01, 0x00, 0x00, 0x00, 0x00, 0x2f, 0x65, 0x74,
    0x63, 0x2f, 0x70, 0x61, 0x73, 0x73, 0x77, 0x64, 0x50, 0x4b, 0x05, 0x06,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x39, 0x00, 0x00, 0x00,
    0x2f, 0x00, 0x00, 0x00, 0x00, 0x00,
};

// ---------------------------------------------------------------------------
// Read, write, read
// ---------------------------------------------------------------------------

test "an archive Info-ZIP wrote is listed, extracted, built again, and extracted again" {
    const gpa = testing.allocator;
    var yard = try Yard.open(gpa);
    defer yard.deinit(gpa);
    try yard.tree.write("fixture.zip", &stored_archive);

    // Listing reads the central directory and nothing else, so what it
    // says about the two entries is what Info-ZIP recorded about them.
    var listed = try yard.expectRuns(gpa, &.{ "list", "fixture.zip" });
    defer listed.deinit(gpa);
    try testing.expect(listed.saysOut("2 entries in fixture.zip, 220 bytes"));
    try testing.expect(listed.saysOut("stored"));
    try testing.expect(listed.saysOut(first_name));
    try testing.expect(listed.saysOut(second_name));

    // No directory argument: the entries land where the person is
    // standing, which is the tree.
    var extracted = try yard.expectRuns(gpa, &.{ "unzip", "fixture.zip" });
    defer extracted.deinit(gpa);
    try testing.expect(extracted.saysOut("2 files extracted into ."));
    try yard.expectFile(gpa, first_name, first_contents);
    try yard.expectFile(gpa, second_name, second_contents);

    // Back in, from the files on disk rather than from anything held
    // over — this run knows nothing about the archive it came from.
    var rebuilt = try yard.expectRuns(gpa, &.{ "zip", "again.zip", first_name, second_name });
    defer rebuilt.deinit(gpa);
    try testing.expect(rebuilt.saysOut("2 files (26 bytes) into again.zip"));
    try testing.expect(yard.tree.exists("again.zip"));

    var relisted = try yard.expectRuns(gpa, &.{ "list", "again.zip" });
    defer relisted.deinit(gpa);
    try testing.expect(relisted.saysOut("2 entries in again.zip"));
    try testing.expect(relisted.saysOut(first_name));
    try testing.expect(relisted.saysOut(second_name));

    // And out again, into somewhere of its own: the bytes at the end of
    // parse → write → parse are the bytes Info-ZIP put in at the start.
    try yard.tree.makeDirectory("round");
    var again = try yard.expectRuns(gpa, &.{ "unzip", "again.zip", "round" });
    defer again.deinit(gpa);
    try yard.expectFile(gpa, "round/" ++ first_name, first_contents);
    try yard.expectFile(gpa, "round/" ++ second_name, second_contents);
}

// ---------------------------------------------------------------------------
// Names that lie
// ---------------------------------------------------------------------------

test "an entry that names its way out of the directory is refused, and nothing is written" {
    const gpa = testing.allocator;
    var yard = try Yard.open(gpa);
    defer yard.deinit(gpa);
    try yard.tree.write("slip.zip", &slip_archive);
    try yard.tree.write("absolute.zip", &absolute_archive);
    try yard.tree.makeDirectory("target");

    // `../escape.txt` would land beside `target`, which is the tree
    // root — where this test can see it, and where a real one would be
    // somebody's home directory.
    var slipped = try yard.run(gpa, &.{ "unzip", "slip.zip", "target" });
    defer slipped.deinit(gpa);
    try testing.expectEqual(exit_errored, slipped.status);
    try testing.expect(slipped.saysErr("climbs out of the directory"));
    try testing.expect(slipped.saysErr("../escape.txt"));
    try testing.expect(!yard.tree.exists("escape.txt"));
    try testing.expect(!yard.tree.exists("target/escape.txt"));
    // The names are all checked before any byte is written, so the
    // refusal reports no extraction at all rather than a partial one.
    try testing.expectEqualStrings("", slipped.out);

    var absolute = try yard.run(gpa, &.{ "unzip", "absolute.zip", "target" });
    defer absolute.deinit(gpa);
    try testing.expectEqual(exit_errored, absolute.status);
    try testing.expect(absolute.saysErr("is an absolute path"));
    try testing.expectEqualStrings("", absolute.out);

    // The writing half goes through the same gate: zipper will not
    // author an archive it would refuse to extract.
    var authored = try yard.run(gpa, &.{ "zip", "hostile.zip", "../escape.txt" });
    defer authored.deinit(gpa);
    try testing.expectEqual(exit_errored, authored.status);
    try testing.expect(authored.saysErr("climbs out of the directory"));
    try testing.expect(!yard.tree.exists("hostile.zip"));
}

// ---------------------------------------------------------------------------
// The directories an archive names
// ---------------------------------------------------------------------------

test "an entry under a directory that is not there brings the directory with it" {
    const gpa = testing.allocator;
    var yard = try Yard.open(gpa);
    defer yard.deinit(gpa);

    // An archive with a nested name, made by zipper itself: an entry is
    // stored under the path it was named by, exactly as `zip` stores
    // one.
    try yard.tree.makeDirectory("papers");
    try yard.tree.write("papers/note.txt", "kept\n");
    try yard.tree.write("loose.txt", "beside\n");
    var built = try yard.expectRuns(gpa, &.{ "zip", "nested.zip", "papers/note.txt", "loose.txt" });
    defer built.deinit(gpa);

    // This was the ceiling docs/MISSING.md named: with no
    // directory-making builtin, zipper could only refuse an archive
    // whose tree was not already on disk.  `dir_create` closed it, so
    // an empty directory is somewhere a whole archive can land.
    try yard.tree.makeDirectory("empty");
    var done = try yard.expectRuns(gpa, &.{ "unzip", "nested.zip", "empty" });
    defer done.deinit(gpa);
    try yard.expectFile(gpa, "empty/papers/note.txt", "kept\n");
    try yard.expectFile(gpa, "empty/loose.txt", "beside\n");

    // And again into the same place: `make_directory` treats a
    // directory already there as success, so re-extracting is an
    // ordinary overwrite rather than a failure.
    var again = try yard.expectRuns(gpa, &.{ "unzip", "nested.zip", "empty" });
    defer again.deinit(gpa);
    try yard.expectFile(gpa, "empty/papers/note.txt", "kept\n");
}

// ---------------------------------------------------------------------------
// The command line
// ---------------------------------------------------------------------------

test "every zipper command line answers with a status a shell can read" {
    const gpa = testing.allocator;
    var yard = try Yard.open(gpa);
    defer yard.deinit(gpa);

    var bare = try yard.run(gpa, &.{});
    defer bare.deinit(gpa);
    try testing.expectEqual(exit_usage, bare.status);
    try testing.expect(bare.saysErr("usage: zipper"));
    try testing.expectEqualStrings("", bare.out);

    var unknown = try yard.run(gpa, &.{ "frobnicate", "x.zip" });
    defer unknown.deinit(gpa);
    try testing.expectEqual(exit_usage, unknown.status);
    try testing.expect(unknown.saysErr("no command called frobnicate"));

    var wrong_count = try yard.run(gpa, &.{"zip"});
    defer wrong_count.deinit(gpa);
    try testing.expectEqual(exit_usage, wrong_count.status);
    try testing.expect(wrong_count.saysErr("usage: zipper zip"));

    // A file that is not there is the runtime's sentence, not a
    // guessed one, and it names the file (docs/FAILURE.md).
    var missing = try yard.run(gpa, &.{ "list", "nowhere.zip" });
    defer missing.deinit(gpa);
    try testing.expectEqual(exit_errored, missing.status);
    try testing.expect(missing.saysErr("nowhere.zip"));

    // And something that is a file but not an archive is refused by
    // the format, with the reason the format gives.
    try yard.tree.write("prose.txt", "not an archive at all\n");
    var prose = try yard.run(gpa, &.{ "list", "prose.txt" });
    defer prose.deinit(gpa);
    try testing.expectEqual(exit_errored, prose.status);
    try testing.expect(prose.saysErr("zip: not an archive"));
}

// ---------------------------------------------------------------------------
// Info-ZIP's own tools, when the machine has them
// ---------------------------------------------------------------------------

/// Where `name` is on `PATH`, or null.  The caller owns the answer.
///
/// The execute bit is checked rather than assumed, for the reason
/// `native.runnableIn` checks it: a directory on `PATH` may perfectly
/// well hold something called `zip` that is not a program, and stopping
/// at it would skip the real one further down.
fn onPath(gpa: Allocator, search_path: ?[]const u8, name: []const u8) !?[]u8 {
    var entries = std.mem.tokenizeScalar(u8, search_path orelse "", ':');
    while (entries.next()) |directory| {
        const candidate = try std.fs.path.join(gpa, &.{ directory, name });
        if (std.Io.Dir.cwd().access(io, candidate, .{ .execute = true })) |_| return candidate else |_| {}
        gpa.free(candidate);
    }
    return null;
}

test "Info-ZIP's own zip and unzip agree with zipper, where the machine has them" {
    const gpa = testing.allocator;

    var environment = try harness.environmentWith(gpa, &.{});
    defer environment.deinit();
    const search_path = environment.get("PATH");

    const system_zip = try onPath(gpa, search_path, "zip");
    defer if (system_zip) |path| gpa.free(path);
    const system_unzip = try onPath(gpa, search_path, "unzip");
    defer if (system_unzip) |path| gpa.free(path);

    if (system_zip == null or system_unzip == null) {
        // A skip that says so.  These rows are a cross-check and never
        // the proof: the archives above are Info-ZIP's bytes whatever
        // this machine has installed, and they run unconditionally.
        std.debug.print(
            "\n  skipped: Info-ZIP's zip{s} and unzip{s} are not on PATH; " ++
                "the embedded-archive rows still ran\n",
            .{
                if (system_zip == null) " (missing)" else "",
                if (system_unzip == null) " (missing)" else "",
            },
        );
        return;
    }

    var yard = try Yard.open(gpa);
    defer yard.deinit(gpa);

    // Something worth compressing, so the row goes through DEFLATE and
    // not only through stored entries: `Writer.add` keeps whichever of
    // the two is smaller, and 8,800 bytes of repetition is not.
    var repeated: std.ArrayList(u8) = .empty;
    defer repeated.deinit(gpa);
    for (0..200) |_| try repeated.appendSlice(gpa, "the quick brown fox jumps over the lazy dog\n");
    try yard.tree.write("prose.txt", repeated.items);
    try yard.tree.write(first_name, first_contents);

    // What zipper writes, Info-ZIP reads: `unzip -t` inflates every
    // entry and checks its CRC-32 against the directory's.
    var made = try yard.expectRuns(gpa, &.{ "zip", "ours.zip", "prose.txt", first_name });
    defer made.deinit(gpa);
    var tested = try yard.tree.spawn(gpa, &.{ system_unzip.?, "-t", "ours.zip" }, .{ .in_tree = true });
    defer tested.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), tested.status);
    try testing.expect(tested.saysOut("No errors detected"));

    // And it really did deflate: an archive that only stored would pass
    // the line above without exercising a bit of RFC 1951.
    var listed = try yard.expectRuns(gpa, &.{ "list", "ours.zip" });
    defer listed.deinit(gpa);
    try testing.expect(listed.saysOut("deflated"));

    // What Info-ZIP writes, zipper reads — dynamic Huffman and all,
    // which is what `zip` produces for text this size.
    var theirs = try yard.tree.spawn(
        gpa,
        &.{ system_zip.?, "-q", "theirs.zip", "prose.txt", first_name },
        .{ .in_tree = true },
    );
    defer theirs.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), theirs.status);

    try yard.tree.makeDirectory("from_theirs");
    var read_back = try yard.expectRuns(gpa, &.{ "unzip", "theirs.zip", "from_theirs" });
    defer read_back.deinit(gpa);
    try yard.expectFile(gpa, "from_theirs/prose.txt", repeated.items);
    try yard.expectFile(gpa, "from_theirs/" ++ first_name, first_contents);
}
