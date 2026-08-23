//! The compiler at its command line, and the binary it writes.
//!
//! `main.zig`'s tests prove the pieces; these prove the *tool* — the
//! thing a person types and a build system calls.  What a command line
//! costs when it is wrong is the whole of what this file is about: an
//! exit status a `make` rule reads, a sentence on standard error, an
//! artifact that is either there or is not.  None of that can be
//! reached from inside the process, because it is the process: the
//! statuses are `main`'s return value, the usage text is what a caller
//! meets before anything is compiled, and `--emit=exe` produces a file
//! whose whole behaviour is `apps/start.zig` running in a process of
//! its own.
//!
//! So these build a miniature install tree in a temporary directory —
//! `luce` at the root and the two static libraries under `lib/`, which
//! is the layout `zig build --prefix` produces and the one
//! `native.discover` looks for — and use it exactly as a person would.
//! `apps/loom/product.zig` does the same for the pair.
//!
//! Every stream is a real file rather than a pipe.  A pipe that fills
//! while the parent is draining the other one deadlocks, and nothing
//! here should have to know which of a program's two channels talks
//! first; a file also makes standard input something a test can simply
//! write, which is how `luce check -` gets proved.

const std = @import("std");
const build_options = @import("build_options");
const harness = @import("harness");

const testing = std.testing;
const io = std.testing.io;
const Allocator = std.mem.Allocator;
const Install = harness.Install;
const Ran = harness.Ran;
const expected_version = std.fmt.comptimePrint("luce {s}\n", .{build_options.version});
/// What a serialized module is called, for the "nothing was left
/// behind" checks — spelled out because this suite links no compiler.
const luce_module_extension = ".lcm";

// ---------------------------------------------------------------------------
// A miniature install tree
// ---------------------------------------------------------------------------

/// `luce` at the root and the two static libraries under `lib/`, which
/// is the layout `zig build --prefix` produces and the one
/// `native.discover` looks for.  The tree itself and the way to run
/// what is in it are `apps/harness.zig`'s, shared with the pair's
/// suite; what goes into this one is this suite's.
fn installTree(gpa: Allocator) !Install {
    var tree = try Install.make(gpa);
    errdefer tree.deinit(gpa);
    try tree.place(build_options.luce_binary, "luce");
    try tree.place(build_options.luce_rt_library, "lib/libluce_rt.a");
    try tree.place(build_options.luce_start_library, "lib/libluce_start.a");
    return tree;
}

/// Run the installed compiler, optionally with `input` on its standard
/// input.
fn runLuce(
    gpa: Allocator,
    tree: *const Install,
    arguments: []const []const u8,
    input: ?[]const u8,
) !Ran {
    const compiler = try tree.at(gpa, "luce");
    defer gpa.free(compiler);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, compiler);
    try argv.appendSlice(gpa, arguments);
    return tree.spawn(gpa, argv.items, .{ .input = input });
}

/// The same, standing *inside* the tree — which is where `luce test`
/// has to be run from, because the working directory is what it means
/// by `tests/` and by every relative path in its report.
fn runLuceHere(gpa: Allocator, tree: *const Install, arguments: []const []const u8) !Ran {
    const compiler = try tree.at(gpa, "luce");
    defer gpa.free(compiler);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, compiler);
    try argv.appendSlice(gpa, arguments);
    return tree.spawn(gpa, argv.items, .{ .in_tree = true });
}

const greeting =
    \\func main():
    \\    print("total " + str(3 * 10))
    \\
;

// ---------------------------------------------------------------------------
// Saying no
// ---------------------------------------------------------------------------

test "luce reports the project version" {
    const gpa = testing.allocator;
    var tree = try installTree(gpa);
    defer tree.deinit(gpa);

    var ran = try runLuce(gpa, &tree, &.{"--version"}, null);
    defer ran.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), ran.status);
    try testing.expectEqualStrings(expected_version, ran.out);
    try testing.expectEqualStrings("", ran.err);
}

test "luce reports the immutable build identity" {
    const gpa = testing.allocator;
    var tree = try installTree(gpa);
    defer tree.deinit(gpa);

    var ran = try runLuce(gpa, &tree, &.{"--build-info"}, null);
    defer ran.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), ran.status);
    try testing.expect(ran.saysOut(expected_version));
    try testing.expect(ran.saysOut(std.fmt.comptimePrint(
        "source {s}\n",
        .{build_options.source_commit},
    )));
    for ([_][]const u8{ "target ", "optimize ", "module-format ", "host-abi " }) |field| {
        try testing.expect(ran.saysOut(field));
    }
    try testing.expectEqualStrings("", ran.err);
}

test "a command line with nothing to do prints usage and fails" {
    const gpa = testing.allocator;
    var tree = try installTree(gpa);
    defer tree.deinit(gpa);

    // No arguments at all, a command that does not exist, and a
    // command with no file: all the same answer, because they are all
    // "there is nothing here to compile".  `build` is not among them:
    // a bare build means the project's `main:` now, and its own test
    // below says what it answers where no project governs.
    const empty_handed = [_][]const []const u8{
        &.{},
        &.{"polish"},
        &.{"check"},
        &.{"ir"},
        &.{"package"},
    };
    for (empty_handed) |arguments| {
        var ran = try runLuce(gpa, &tree, arguments, null);
        defer ran.deinit(gpa);
        try testing.expectEqual(@as(u8, 1), ran.status);
        try testing.expectEqualStrings("", ran.out);
        try testing.expect(ran.saysErr("usage:"));
        // Usage that does not name a command is usage that hides one.
        if (arguments.len == 1 and std.mem.eql(u8, arguments[0], "package")) {
            try testing.expect(ran.saysErr("luce package new"));
        } else {
            for ([_][]const u8{
                "luce --version",
                "luce --build-info",
                "luce build [FILE] [-o OUT] [--release] [--emit=WHAT] [--link INPUT ...]",
                "luce check FILE",
                "luce ir FILE [--full]",
                "luce test [PATH ...]",
                "luce install",
                "luce package new NAME [VERSION]",
                "luce package version NAME VERSION",
                "luce package publish NAME",
            }) |form| {
                try testing.expect(ran.saysErr(form));
            }
            try testing.expect(ran.saysErr(
                "--emit says which shape to write. The default is exe;\n" ++
                    "all three forms walk the same compiler pipeline:\n",
            ));
            try testing.expect(!ran.saysErr("exe differs between them"));
        }
    }
}

test "an option written twice, or one nobody has, is refused rather than resolved" {
    // Silently taking the last `-o` puts the artifact somewhere the
    // caller is not looking and reports success; silently taking the
    // last `--emit` writes a file of the wrong shape and reports
    // success.  Both are failures a build system cannot see, so
    // neither is resolved.
    const gpa = testing.allocator;
    var tree = try installTree(gpa);
    defer tree.deinit(gpa);
    try tree.write("sums.luc", greeting);
    const program = try tree.at(gpa, "sums.luc");
    defer gpa.free(program);

    // Absolute, so that "nothing was written" is a claim about
    // somewhere this test can look.  A relative `-o two.lc` lands in
    // whatever directory the test runner happens to be in, and the
    // check below would pass without ever having been true.
    const one = try tree.at(gpa, "one.lc");
    defer gpa.free(one);
    const two = try tree.at(gpa, "two.lc");
    defer gpa.free(two);

    const refusals = [_]struct { arguments: []const []const u8, says: []const u8 }{
        .{ .arguments = &.{ "-o", one, "-o", two }, .says = "-o was given twice" },
        .{ .arguments = &.{ "--release", "--release" }, .says = "--release was given twice" },
        .{
            .arguments = &.{ "--emit=exe", "--emit=object" },
            .says = "--emit was given twice",
        },
        .{ .arguments = &.{"--emit=wasm"}, .says = "--emit=wasm is not one of library, object, exe" },
        .{ .arguments = &.{"--fast"}, .says = "--fast is not an option build takes" },
        .{ .arguments = &.{"-o"}, .says = "-o needs a path after it" },
    };
    for (refusals) |refusal| {
        var arguments: std.ArrayList([]const u8) = .empty;
        defer arguments.deinit(gpa);
        try arguments.appendSlice(gpa, &.{ "build", program });
        try arguments.appendSlice(gpa, refusal.arguments);

        var ran = try runLuce(gpa, &tree, arguments.items, null);
        defer ran.deinit(gpa);
        try testing.expectEqual(@as(u8, 1), ran.status);
        try testing.expectEqualStrings("", ran.out);
        try testing.expect(ran.saysErr(refusal.says));
        // And nothing was written under either name it was given.
        try testing.expect(!tree.exists("sums.lc"));
        try testing.expect(!tree.exists("one.lc"));
        try testing.expect(!tree.exists("two.lc"));
    }

    // The other two commands take no options at all, and say so.
    var checked = try runLuce(gpa, &tree, &.{ "check", program, "--full" }, null);
    defer checked.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), checked.status);
    try testing.expect(checked.saysErr("check takes one file"));

    var dumped = try runLuce(gpa, &tree, &.{ "ir", program, "--half" }, null);
    defer dumped.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), dumped.status);
    try testing.expect(dumped.saysErr("ir takes one file"));
}

test "an option in the file's slot is answered with the rule, not the wrong word" {
    // `luce build --emit=object sums.luc` once answered "sums.luc is
    // not an option build takes": true of the word it names, and
    // useless, because sums.luc is exactly what the caller meant to
    // build.  The rule broken is that the file comes first, so that
    // is the sentence — with the fix written out.
    const gpa = testing.allocator;
    var tree = try installTree(gpa);
    defer tree.deinit(gpa);
    try tree.write("sums.luc", greeting);
    const program = try tree.at(gpa, "sums.luc");
    defer gpa.free(program);

    const misordered = [_][]const []const u8{
        &.{ "build", "--emit=object", program },
        &.{ "build", "--release", program },
        &.{ "build", "-o", "out", program },
    };
    for (misordered) |arguments| {
        var ran = try runLuce(gpa, &tree, arguments, null);
        defer ran.deinit(gpa);
        try testing.expectEqual(@as(u8, 1), ran.status);
        try testing.expectEqualStrings("", ran.out);
        const expected = try std.fmt.allocPrint(
            gpa,
            "build takes its file first: luce build FILE {s}",
            .{arguments[1]},
        );
        defer gpa.free(expected);
        try testing.expect(ran.saysErr(expected));
        try testing.expect(!tree.exists("sums.lc"));
        try testing.expect(!tree.exists("sums.o"));
    }
}

test "a bare build compiles the manifest's main, and says what is missing without one" {
    const gpa = testing.allocator;
    var tree = try installTree(gpa);
    defer tree.deinit(gpa);

    // No project: the bare form refuses and names both remedies.
    var rootless = try runLuceHere(gpa, &tree, &.{"build"});
    defer rootless.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), rootless.status);
    try testing.expect(rootless.saysErr("a bare build needs a project"));
    try testing.expect(rootless.saysErr("luce build FILE"));

    // A governing manifest without the key names the key.
    try tree.write("luce.yaml",
        \\name: sums
        \\version: 0.1.0
        \\
    );
    var unkeyed = try runLuceHere(gpa, &tree, &.{"build"});
    defer unkeyed.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), unkeyed.status);
    try testing.expect(unkeyed.saysErr("names no main:"));

    // With the key, the bare form is exactly the file form: the
    // executable lands beside the source, named after it, and an
    // option rides along unchanged.
    try tree.write("luce.yaml",
        \\name: sums
        \\version: 0.1.0
        \\main: src/sums.luc
        \\
    );
    try tree.write("src/sums.luc", greeting);
    var built = try runLuceHere(gpa, &tree, &.{"build"});
    defer built.deinit(gpa);
    try testing.expectEqualStrings("", built.err);
    try testing.expectEqual(@as(u8, 0), built.status);
    try testing.expect(tree.exists("src/sums"));

    var emitted = try runLuceHere(gpa, &tree, &.{ "build", "--emit=library" });
    defer emitted.deinit(gpa);
    try testing.expectEqualStrings("", emitted.err);
    try testing.expectEqual(@as(u8, 0), emitted.status);
    try testing.expect(tree.exists("src/sums.lc"));
}

test "--link embeds a C object the program's externs call" {
    // The FFI's closing loop (docs/FFI.md): cc compiles the C, --link
    // carries the object into the native link, and the extern is a
    // direct call into it.
    const gpa = testing.allocator;
    var tree = try installTree(gpa);
    defer tree.deinit(gpa);

    try tree.write("helper.c",
        \\#include <stdint.h>
        \\int64_t tripled(int64_t x) { return x * 3; }
        \\
    );
    const helper_c = try tree.at(gpa, "helper.c");
    defer gpa.free(helper_c);
    const helper_o = try tree.at(gpa, "helper.o");
    defer gpa.free(helper_o);
    const compiled = try std.process.run(gpa, io, .{
        .argv = &.{ "cc", "-c", helper_c, "-o", helper_o },
    });
    defer gpa.free(compiled.stdout);
    defer gpa.free(compiled.stderr);
    try testing.expect(compiled.term == .exited and compiled.term.exited == 0);

    try tree.write("embed.luc",
        \\extern func tripled(x: i64) -> i64
        \\
        \\func main():
        \\    print(str(tripled(14)))
        \\
    );
    var built = try runLuceHere(gpa, &tree, &.{ "build", "embed.luc", "--link", "helper.o" });
    defer built.deinit(gpa);
    try testing.expectEqualStrings("", built.err);
    try testing.expectEqual(@as(u8, 0), built.status);

    const program = try tree.at(gpa, "embed");
    defer gpa.free(program);
    const ran = try std.process.run(gpa, io, .{ .argv = &.{program} });
    defer gpa.free(ran.stdout);
    defer gpa.free(ran.stderr);
    try testing.expectEqualStrings("42\n", ran.stdout);

    // --link on a no-link artifact is refused with the reason.
    var refused = try runLuceHere(gpa, &tree, &.{ "build", "embed.luc", "--emit=object", "--link", "helper.o" });
    defer refused.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), refused.status);
    try testing.expect(refused.saysErr("--emit=object performs no link"));
}

// ---------------------------------------------------------------------------
// The scripted build: build.luc declares, the tool executes
// ---------------------------------------------------------------------------

test "a build.luc plan runs its steps in dependency order and governs the bare build" {
    const gpa = testing.allocator;
    var tree = try installTree(gpa);
    defer tree.deinit(gpa);

    try tree.write("luce.yaml",
        \\name: shop
        \\version: 0.1.0
        \\
    );
    try tree.write("gen.c",
        \\int main(void) { return 0; }
        \\
    );
    try tree.write("helper.c",
        \\long luce_plan_probe(void) { return 7; }
        \\
    );
    // The app resolves its extern from the object a command step
    // built: a plan's `links` reach the native link, and an
    // unresolved symbol would fail this build.
    try tree.write("src/app.luc",
        \\extern func luce_plan_probe() -> i64
        \\
        \\func main():
        \\    print(str(luce_plan_probe()))
        \\
    );
    // The tool and helper steps must finish before the app compiles —
    // the order the output lines land in is the proof.
    try tree.write("build.luc",
        \\import std.build
        \\
        \\func main():
        \\    var b = build.Plan()
        \\    let tool = b.command("tool", ["cc", "-o", "gen", "gen.c"])
        \\    let helper = b.command("helper", ["cc", "-c", "-o", "helper.o", "helper.c"])
        \\    var app = b.program("app", "src/app.luc")
        \\    app.needs(tool)
        \\    app.needs(helper)
        \\    app.link("helper.o")
        \\    b.default(app)
        \\    b.emit()
        \\
    );

    var ran = try runLuceHere(gpa, &tree, &.{"build"});
    defer ran.deinit(gpa);
    try testing.expectEqualStrings("", ran.err);
    try testing.expectEqual(@as(u8, 0), ran.status);
    try testing.expectEqualStrings(
        "tool: ran cc\nhelper: ran cc\napp: src/app.luc -> src/app\n",
        ran.out,
    );
    try testing.expect(tree.exists("gen"));
    try testing.expect(tree.exists("src/app"));
    // The compiled script is cached under the project, keyed by hash.
    try testing.expect(tree.exists(".luce/cache/build"));
    try testing.expect(tree.exists(".luce/cache/build.hash"));

    // A second run hits the script cache and replays the same plan.
    var again = try runLuceHere(gpa, &tree, &.{"build"});
    defer again.deinit(gpa);
    try testing.expectEqualStrings("", again.err);
    try testing.expectEqual(@as(u8, 0), again.status);
    try testing.expectEqualStrings(
        "tool: ran cc\nhelper: ran cc\napp: src/app.luc -> src/app\n",
        again.out,
    );

    // A scripted build takes no options: the script decides everything.
    var optioned = try runLuceHere(gpa, &tree, &.{ "build", "--release" });
    defer optioned.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), optioned.status);
    try testing.expect(optioned.saysErr("a scripted build takes no options"));
}

test "a plan that fails a step, or chooses nothing, says so and builds nothing" {
    const gpa = testing.allocator;
    var tree = try installTree(gpa);
    defer tree.deinit(gpa);

    try tree.write("luce.yaml",
        \\name: shop
        \\version: 0.1.0
        \\
    );
    try tree.write("src/app.luc", greeting);
    // Two steps and no default: the plan must choose.
    try tree.write("build.luc",
        \\import std.build
        \\
        \\func main():
        \\    var b = build.Plan()
        \\    let one = b.program("one", "src/app.luc")
        \\    var two = b.program("two", "src/app.luc")
        \\    two.needs(one)
        \\    b.emit()
        \\
    );
    var undecided = try runLuceHere(gpa, &tree, &.{"build"});
    defer undecided.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), undecided.status);
    try testing.expect(undecided.saysErr("no default; choose one"));

    // A command that fails stops the plan before anything after it.
    try tree.write("build.luc",
        \\import std.build
        \\
        \\func main():
        \\    var b = build.Plan()
        \\    let tool = b.command("tool", ["cc", "--not-a-flag-cc-takes"])
        \\    var app = b.program("app", "src/app.luc")
        \\    app.needs(tool)
        \\    b.default(app)
        \\    b.emit()
        \\
    );
    var stopped = try runLuceHere(gpa, &tree, &.{"build"});
    defer stopped.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), stopped.status);
    try testing.expect(stopped.saysErr("step tool failed"));
    try testing.expect(!tree.exists("src/app"));
}

// ---------------------------------------------------------------------------
// luce install
// ---------------------------------------------------------------------------

const ZipEntry = struct { name: []const u8, data: []const u8 };

/// The tree hash docs/PACKAGES.md states, restated independently of
/// `files.hashPackageDirectory` so the two cannot drift together:
/// every regular file in sorted relative-path order, each contributing
/// its path, a NUL, its u64 little-endian length, and its bytes.
fn treeDigest(entries: []const ZipEntry) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (entries) |entry| {
        hasher.update(entry.name);
        hasher.update(&[_]u8{0});
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, entry.data.len, .little);
        hasher.update(&length);
        hasher.update(entry.data);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn appendInt(gpa: Allocator, bytes: *std.ArrayList(u8), comptime T: type, value: T) !void {
    var encoded: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &encoded, value, .little);
    try bytes.appendSlice(gpa, &encoded);
}

/// A store-only (no compression) zip of the entries — enough archive
/// for the installer to read back exactly what went in.  Caller frees.
fn storeZip(gpa: Allocator, entries: []const ZipEntry) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);
    var offsets: [8]u32 = undefined;
    for (entries, 0..) |entry, index| {
        offsets[index] = @intCast(bytes.items.len);
        try bytes.appendSlice(gpa, "PK\x03\x04");
        try appendInt(gpa, &bytes, u16, 20);
        try appendInt(gpa, &bytes, u16, 0);
        try appendInt(gpa, &bytes, u16, 0);
        try appendInt(gpa, &bytes, u16, 0);
        try appendInt(gpa, &bytes, u16, 0);
        try appendInt(gpa, &bytes, u32, std.hash.Crc32.hash(entry.data));
        try appendInt(gpa, &bytes, u32, @intCast(entry.data.len));
        try appendInt(gpa, &bytes, u32, @intCast(entry.data.len));
        try appendInt(gpa, &bytes, u16, @intCast(entry.name.len));
        try appendInt(gpa, &bytes, u16, 0);
        try bytes.appendSlice(gpa, entry.name);
        try bytes.appendSlice(gpa, entry.data);
    }
    const central_start: u32 = @intCast(bytes.items.len);
    for (entries, 0..) |entry, index| {
        try bytes.appendSlice(gpa, "PK\x01\x02");
        try appendInt(gpa, &bytes, u16, 20);
        try appendInt(gpa, &bytes, u16, 20);
        try appendInt(gpa, &bytes, u16, 0);
        try appendInt(gpa, &bytes, u16, 0);
        try appendInt(gpa, &bytes, u16, 0);
        try appendInt(gpa, &bytes, u16, 0);
        try appendInt(gpa, &bytes, u32, std.hash.Crc32.hash(entry.data));
        try appendInt(gpa, &bytes, u32, @intCast(entry.data.len));
        try appendInt(gpa, &bytes, u32, @intCast(entry.data.len));
        try appendInt(gpa, &bytes, u16, @intCast(entry.name.len));
        try appendInt(gpa, &bytes, u16, 0);
        try appendInt(gpa, &bytes, u16, 0);
        try appendInt(gpa, &bytes, u16, 0);
        try appendInt(gpa, &bytes, u16, 0);
        try appendInt(gpa, &bytes, u32, 0);
        try appendInt(gpa, &bytes, u32, offsets[index]);
        try bytes.appendSlice(gpa, entry.name);
    }
    const central_size: u32 = @intCast(bytes.items.len - central_start);
    try bytes.appendSlice(gpa, "PK\x05\x06");
    try appendInt(gpa, &bytes, u16, 0);
    try appendInt(gpa, &bytes, u16, 0);
    try appendInt(gpa, &bytes, u16, @intCast(entries.len));
    try appendInt(gpa, &bytes, u16, @intCast(entries.len));
    try appendInt(gpa, &bytes, u32, central_size);
    try appendInt(gpa, &bytes, u32, central_start);
    try appendInt(gpa, &bytes, u16, 0);
    return bytes.toOwnedSlice(gpa);
}

/// One-shot loopback HTTP file server: accept one connection, read one
/// request head, answer the payload, hang up.  All the network an
/// install test needs, and no certificate authority.
const OneArchive = struct {
    server: std.Io.net.Server,
    payload: []const u8,

    fn open(payload: []const u8) !OneArchive {
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        return .{ .server = try address.listen(io, .{}), .payload = payload };
    }

    fn port(self: *const OneArchive) !u16 {
        var storage: std.c.sockaddr.storage = undefined;
        var length: std.c.socklen_t = @sizeOf(std.c.sockaddr.storage);
        const asked = std.c.getsockname(self.server.socket.handle, @ptrCast(&storage), &length);
        if (std.posix.errno(asked) != .SUCCESS) return error.NoPort;
        if (storage.family != std.c.AF.INET) return error.NoPort;
        const in_network_order = @as(*align(1) const std.c.sockaddr.in, @ptrCast(&storage)).port;
        return std.mem.bigToNative(u16, in_network_order);
    }

    fn serve(self: *OneArchive) void {
        var stream = self.server.accept(io) catch return;
        defer stream.close(io);
        var in_buffer: [4096]u8 = undefined;
        var request = stream.reader(io, &in_buffer);
        var head: usize = 0;
        while (std.mem.indexOf(u8, request.interface.buffered(), "\r\n\r\n") == null) {
            request.interface.fillMore() catch break;
            head += 1;
            if (head > 64) break;
        }
        var out_buffer: [1024]u8 = undefined;
        var response = stream.writer(io, &out_buffer);
        response.interface.print(
            "HTTP/1.1 200 OK\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n",
            .{self.payload.len},
        ) catch return;
        response.interface.writeAll(self.payload) catch return;
        response.interface.flush() catch return;
    }
};

const geo_entries = [_]ZipEntry{
    .{ .name = "geo.luc", .data = "pub func area(size: i64) -> i64:\n    return size * size\n" },
    .{ .name = "luce.yaml", .data = "name: geo\nversion: 1.2.0\n" },
};

fn installManifest(gpa: Allocator, port: u16, digest: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "name: atlas\nversion: 0.1.0\n\npackages:\n  geo: 1.2.0 url:http://127.0.0.1:{d}/geo-1.2.0.zip sha256:{s}\n",
        .{ port, digest },
    );
}

test "luce install fetches, verifies, fills the store once, and the package resolves" {
    const gpa = testing.allocator;
    var tree = try installTree(gpa);
    defer tree.deinit(gpa);

    const digest = treeDigest(&geo_entries);
    const archive = try storeZip(gpa, &geo_entries);
    defer gpa.free(archive);
    var served = try OneArchive.open(archive);
    defer served.server.deinit(io);
    const manifest_text = try installManifest(gpa, try served.port(), &digest);
    defer gpa.free(manifest_text);
    try tree.write("luce.yaml", manifest_text);
    var thread = try std.Thread.spawn(.{}, OneArchive.serve, .{&served});

    var ran = try runLuceHere(gpa, &tree, &.{"install"});
    defer ran.deinit(gpa);
    thread.join();
    try testing.expectEqualStrings("", ran.err);
    try testing.expectEqual(@as(u8, 0), ran.status);
    try testing.expect(ran.saysOut("installed geo 1.2.0"));
    try testing.expect(tree.exists(".luce/packages/geo-1.2.0/geo.luc"));
    try testing.expect(tree.exists(".luce/packages/geo-1.2.0/luce.yaml"));
    // Nothing transient survives a clean install.
    try testing.expect(!tree.exists(".luce/packages/geo-1.2.0.staging"));
    try testing.expect(!tree.exists(".luce/packages/geo-1.2.0.fetched.zip"));

    // Idempotent, and verified rather than trusted: the second run
    // re-hashes the store and fetches nothing — the server is gone, so
    // a fetch would fail loudly.
    var again = try runLuceHere(gpa, &tree, &.{"install"});
    defer again.deinit(gpa);
    try testing.expectEqualStrings("", again.err);
    try testing.expectEqual(@as(u8, 0), again.status);
    try testing.expect(again.saysOut("geo 1.2.0: already installed"));

    // The reason install exists: the installed package resolves and
    // links like any other.
    try tree.write("main.luc",
        \\import geo
        \\
        \\func main():
        \\    print(str(geo.area(4)))
        \\
    );
    var built = try runLuceHere(gpa, &tree, &.{ "build", "main.luc", "--emit=library" });
    defer built.deinit(gpa);
    try testing.expectEqualStrings("", built.err);
    try testing.expectEqual(@as(u8, 0), built.status);
    try testing.expect(tree.exists("main.lc"));
}

test "luce install refuses the unverifiable, the non-loopback, and the unnamed" {
    const gpa = testing.allocator;
    var tree = try installTree(gpa);
    defer tree.deinit(gpa);

    const rows = [_]struct { row: []const u8, says: []const u8 }{
        .{
            .row = "  geo: 1.2.0 url:http://127.0.0.1:1/geo.zip",
            .says = "names url: but no sha256:",
        },
        .{
            .row = "  geo: 1.2.0 url:http://pkg.example.com/geo.zip sha256:" ++ ("ab" ** 32),
            .says = "only the loopback host may be fetched over http",
        },
        .{
            .row = "  geo: 1.2.0",
            .says = "names no url: to fetch from",
        },
    };
    for (rows) |case| {
        const text = try std.fmt.allocPrint(
            gpa,
            "name: atlas\nversion: 0.1.0\n\npackages:\n{s}\n",
            .{case.row},
        );
        defer gpa.free(text);
        try tree.write("luce.yaml", text);
        var ran = try runLuceHere(gpa, &tree, &.{"install"});
        defer ran.deinit(gpa);
        try testing.expectEqual(@as(u8, 1), ran.status);
        try testing.expect(ran.saysErr(case.says));
        try testing.expect(!tree.exists(".luce/packages/geo-1.2.0"));
    }
}

test "a fetched tree that hashes to different bytes never lands in the store" {
    const gpa = testing.allocator;
    var tree = try installTree(gpa);
    defer tree.deinit(gpa);

    const archive = try storeZip(gpa, &geo_entries);
    defer gpa.free(archive);
    var served = try OneArchive.open(archive);
    defer served.server.deinit(io);
    const wrong = "ab" ** 32;
    const manifest_text = try installManifest(gpa, try served.port(), wrong);
    defer gpa.free(manifest_text);
    try tree.write("luce.yaml", manifest_text);
    var thread = try std.Thread.spawn(.{}, OneArchive.serve, .{&served});

    var ran = try runLuceHere(gpa, &tree, &.{"install"});
    defer ran.deinit(gpa);
    thread.join();
    try testing.expectEqual(@as(u8, 1), ran.status);
    try testing.expect(ran.saysErr("does not match its stated hash"));
    try testing.expect(ran.saysErr("nothing was installed"));
    try testing.expect(!tree.exists(".luce/packages/geo-1.2.0"));
    try testing.expect(!tree.exists(".luce/packages/geo-1.2.0.staging"));
    try testing.expect(!tree.exists(".luce/packages/geo-1.2.0.fetched.zip"));
}

test "package commands create a direct source package and version it" {
    const gpa = testing.allocator;
    var tree = try installTree(gpa);
    defer tree.deinit(gpa);

    try tree.write("luce.yaml",
        \\name: atlas
        \\version: 0.1.0
        \\
    );
    try tree.write("main.luc",
        \\import widget
        \\
    );

    var created = try runLuceHere(gpa, &tree, &.{ "package", "new", "widget" });
    defer created.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), created.status);
    try testing.expectEqualStrings("", created.err);
    try testing.expect(created.saysOut("created package widget 0.1.0 in widget/"));
    try testing.expect(tree.exists("widget/luce.yaml"));
    try testing.expect(tree.exists("widget/widget.luc"));
    try testing.expect(!tree.exists("packages/widget/widget.luc"));
    try tree.write("widget/widget.luc",
        \\pub func answer() -> i64:
        \\    return 42
        \\
    );
    try tree.write("main.luc",
        \\import widget
        \\
        \\func main():
        \\    print(str(widget.answer()))
        \\
    );
    var checked = try runLuceHere(gpa, &tree, &.{ "check", "main.luc" });
    defer checked.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), checked.status);
    try testing.expect(checked.saysOut("main.luc: ok"));

    const root_after_new = try tree.read(gpa, "luce.yaml");
    defer gpa.free(root_after_new);
    try testing.expect(std.mem.indexOf(u8, root_after_new, "widget: 0.1.0 path:widget") != null);
    const package_after_new = try tree.read(gpa, "widget/luce.yaml");
    defer gpa.free(package_after_new);
    try testing.expectEqualStrings("name: widget\nversion: 0.1.0\n", package_after_new);

    var versioned = try runLuceHere(gpa, &tree, &.{ "package", "version", "widget", "0.2.0" });
    defer versioned.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), versioned.status);
    try testing.expectEqualStrings("", versioned.err);
    try testing.expect(versioned.saysOut("versioned package widget: 0.1.0 -> 0.2.0"));

    const root_after_version = try tree.read(gpa, "luce.yaml");
    defer gpa.free(root_after_version);
    try testing.expect(std.mem.indexOf(u8, root_after_version, "widget: 0.2.0 path:widget") != null);
    const package_after_version = try tree.read(gpa, "widget/luce.yaml");
    defer gpa.free(package_after_version);
    try testing.expectEqualStrings("name: widget\nversion: 0.2.0\n", package_after_version);

    var published = try runLuceHere(gpa, &tree, &.{ "package", "publish", "widget" });
    defer published.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), published.status);
    try testing.expectEqualStrings("", published.out);
    try testing.expect(published.saysErr("publishing is not available yet"));
    try testing.expect(published.saysErr("no package registry is configured"));
}

test "package new bootstraps a rootless source tree" {
    const gpa = testing.allocator;
    var tree = try installTree(gpa);
    defer tree.deinit(gpa);
    try tree.write("main.luc", "# the project entry\n");

    var created = try runLuceHere(gpa, &tree, &.{ "package", "new", "greet" });
    defer created.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), created.status);
    try testing.expectEqualStrings("", created.err);
    try testing.expect(tree.exists("luce.yaml"));
    try testing.expect(tree.exists("greet/luce.yaml"));
    try testing.expect(tree.exists("greet/greet.luc"));

    const root_manifest = try tree.read(gpa, "luce.yaml");
    defer gpa.free(root_manifest);
    try testing.expect(std.mem.indexOf(u8, root_manifest, "version: 0.1.0") != null);
    try testing.expect(std.mem.indexOf(u8, root_manifest, "greet: 0.1.0 path:greet") != null);
}

// ---------------------------------------------------------------------------
// check and ir
// ---------------------------------------------------------------------------

test "check compiles, reports, and writes nothing" {
    const gpa = testing.allocator;
    var tree = try installTree(gpa);
    defer tree.deinit(gpa);
    try tree.write("sums.luc", greeting);
    // A path with a directory in it, because a diagnostic that says
    // `sums.luc:2:5` names a file the reader still has to find — and
    // there may be three of them.
    try tree.write("sub/broken.luc",
        \\func main():
        \\    let count: i64 = "seven"
        \\    print(str(count))
        \\
    );

    const program = try tree.at(gpa, "sums.luc");
    defer gpa.free(program);
    var good = try runLuce(gpa, &tree, &.{ "check", program }, null);
    defer good.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), good.status);
    try testing.expectEqualStrings("", good.err);
    try testing.expect(good.saysOut(": ok\n"));
    try testing.expect(good.saysOut(program));
    // Checking is not building: nothing landed beside the source.
    try testing.expect(!tree.exists("sums.lc"));

    const broken = try tree.at(gpa, "sub/broken.luc");
    defer gpa.free(broken);
    var refused = try runLuce(gpa, &tree, &.{ "check", broken }, null);
    defer refused.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), refused.status);
    try testing.expectEqualStrings("", refused.out);
    try testing.expect(refused.saysErr("compile failed"));
    // The path as it was written, the position, and the stable code —
    // the three things an editor and a person both need.
    try testing.expect(refused.saysErr(broken));
    try testing.expect(refused.saysErr(":2:5:"));
    try testing.expect(refused.saysErr("[luce.sema.type]"));

    const absent = try tree.at(gpa, "nowhere.luc");
    defer gpa.free(absent);
    var missing = try runLuce(gpa, &tree, &.{ "check", absent }, null);
    defer missing.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), missing.status);
    try testing.expect(missing.saysErr("no such file"));
    try testing.expect(missing.saysErr(absent));
}

test "query diagnostics answers JSON: positions for a broken file, [] for a clean one" {
    const gpa = testing.allocator;
    var tree = try installTree(gpa);
    defer tree.deinit(gpa);
    try tree.write("sums.luc", greeting);
    try tree.write("broken.luc",
        \\func main():
        \\    let count: i64 = "seven"
        \\    print(str(count))
        \\
    );

    const program = try tree.at(gpa, "sums.luc");
    defer gpa.free(program);
    var clean = try runLuce(gpa, &tree, &.{ "query", "diagnostics", program }, null);
    defer clean.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), clean.status);
    try testing.expectEqualStrings("[]\n", clean.out);

    // A broken compile is still a successful *query*: the array is the
    // answer, machine-readable, on standard output alone.
    const broken = try tree.at(gpa, "broken.luc");
    defer gpa.free(broken);
    var full = try runLuce(gpa, &tree, &.{ "query", "diagnostics", broken }, null);
    defer full.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), full.status);
    try testing.expectEqualStrings("", full.err);
    try testing.expect(full.saysOut("\"code\":\"luce.sema.type\""));
    try testing.expect(full.saysOut("\"line\":2"));
    try testing.expect(full.saysOut("\"column\":5"));
    try testing.expect(full.saysOut("\"end_column\":"));

    // The buffer a tool has not saved yet travels as `-`.
    var piped = try runLuce(gpa, &tree, &.{ "query", "diagnostics", "-" }, "func main():\n    print(missing)\n");
    defer piped.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), piped.status);
    try testing.expect(piped.saysOut("\"code\":\"luce.sema.name\""));
    try testing.expect(piped.saysOut("\"path\":\"<stdin>\""));

    // A file the query cannot read is the query's own failure.
    const absent = try tree.at(gpa, "nowhere.luc");
    defer gpa.free(absent);
    var missing = try runLuce(gpa, &tree, &.{ "query", "diagnostics", absent }, null);
    defer missing.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), missing.status);
    try testing.expect(missing.saysErr("no such file"));
}

test "ir prints the program, and --full keeps what the entry never reaches" {
    // Pruning is what makes an unused std import cost nothing to ship,
    // so `luce ir` shows the program as it will be compiled.  `--full`
    // is the other question — what does this *file* say — and is how a
    // module under inspection gets looked at at all.
    const gpa = testing.allocator;
    var tree = try installTree(gpa);
    defer tree.deinit(gpa);
    try tree.write("shape.luc",
        \\func unreached() -> i64:
        \\    return 7
        \\
        \\func main():
        \\    print("here")
        \\
    );
    const program = try tree.at(gpa, "shape.luc");
    defer gpa.free(program);

    var pruned = try runLuce(gpa, &tree, &.{ "ir", program }, null);
    defer pruned.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), pruned.status);
    try testing.expectEqualStrings("", pruned.err);
    try testing.expect(pruned.saysOut("func main()"));
    try testing.expect(!pruned.saysOut("unreached"));

    var whole = try runLuce(gpa, &tree, &.{ "ir", program, "--full" }, null);
    defer whole.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), whole.status);
    try testing.expect(whole.saysOut("func main()"));
    try testing.expect(whole.saysOut("func unreached()"));

    // Reading is not building here either.
    try testing.expect(!tree.exists("shape.lc"));

    // A program that does not compile has no IR to print.
    try tree.write("broken.luc", "func main():\n    let x: i64 = \"s\"\n    print(str(x))\n");
    const broken = try tree.at(gpa, "broken.luc");
    defer gpa.free(broken);
    var failed = try runLuce(gpa, &tree, &.{ "ir", broken }, null);
    defer failed.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), failed.status);
    try testing.expectEqualStrings("", failed.out);
    try testing.expect(failed.saysErr("compile failed"));
}

test "a program may arrive on standard input, and is named for what it is" {
    // `luce check <(generate)` and `luce check -` are table stakes for
    // an editor, and a stream has no name to put in a diagnostic — so
    // it gets one, and it is not a dash.
    const gpa = testing.allocator;
    var tree = try installTree(gpa);
    defer tree.deinit(gpa);

    var checked = try runLuce(gpa, &tree, &.{ "check", "-" }, greeting);
    defer checked.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), checked.status);
    try testing.expectEqualStrings("<stdin>: ok\n", checked.out);

    var dumped = try runLuce(gpa, &tree, &.{ "ir", "-" }, greeting);
    defer dumped.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), dumped.status);
    try testing.expect(dumped.saysOut("func main()"));

    var complained = try runLuce(
        gpa,
        &tree,
        &.{ "check", "-" },
        "func main():\n    let x: i64 = \"s\"\n    print(str(x))\n",
    );
    defer complained.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), complained.status);
    try testing.expect(complained.saysErr("<stdin>:2:5:"));

    // A stream has no name to derive an output path from, so building
    // one says so rather than writing a file called `-.lc`.
    var nameless = try runLuce(gpa, &tree, &.{ "build", "-" }, greeting);
    defer nameless.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), nameless.status);
    try testing.expect(nameless.saysErr("needs -o to say where to write"));
    try testing.expect(!tree.exists("-.lc"));

    const target = try tree.at(gpa, "streamed.lc");
    defer gpa.free(target);
    var built = try runLuce(gpa, &tree, &.{ "build", "-", "--emit=library", "-o", target }, greeting);
    defer built.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), built.status);
    try testing.expect(built.saysOut("<stdin> -> "));
    try testing.expect(tree.exists("streamed.lc"));
}

// ---------------------------------------------------------------------------
// The three shapes
// ---------------------------------------------------------------------------

test "each --emit shape writes what it says, and the object links into a program that runs" {
    // The default and `--emit=exe` are the same request said two ways;
    // `--emit=library` is the loadable `.lc`; and `--emit=object` is the
    // one whose whole promise is that somebody else links it.  So this
    // links it — by hand, with `cc`, over the two installed libraries,
    // which is exactly what `--emit=exe` does internally and exactly
    // what an embedder would type.
    const gpa = testing.allocator;
    var tree = try installTree(gpa);
    defer tree.deinit(gpa);
    try tree.write("sums.luc", greeting);
    const program = try tree.at(gpa, "sums.luc");
    defer gpa.free(program);

    // The default: FILE.luc -> FILE, and one line saying so.
    var implied = try runLuce(gpa, &tree, &.{ "build", program }, null);
    defer implied.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), implied.status);
    try testing.expectEqualStrings("", implied.err);
    try testing.expect(implied.saysOut("sums.luc -> "));
    try testing.expect(implied.saysOut("sums\n"));
    try testing.expect(tree.exists("sums"));
    const default_binary = try tree.at(gpa, "sums");
    defer gpa.free(default_binary);
    var default_ran = try tree.spawn(gpa, &.{default_binary}, .{});
    defer default_ran.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), default_ran.status);
    try testing.expectEqualStrings("total 30\n", default_ran.out);

    // Said out loud, the library shape is still available when a loader
    // needs a `.lc`.
    try tree.scratch.dir.deleteFile(io, "sums");
    var named = try runLuce(gpa, &tree, &.{ "build", program, "--emit=library" }, null);
    defer named.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), named.status);
    try testing.expect(tree.exists("sums.lc"));

    // An object: FILE.luc -> FILE.o, and nothing that runs yet.
    var relocatable = try runLuce(gpa, &tree, &.{ "build", program, "--emit=object" }, null);
    defer relocatable.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), relocatable.status);
    try testing.expect(relocatable.saysOut("sums.o"));
    try testing.expect(tree.exists("sums.o"));

    // Linked by hand, exactly as the documentation says to: the
    // program's object, `main`, the semantics — and, where the C
    // library keeps its thread and math functions apart, `-pthread`
    // and `-lm`. Darwin gets both with libSystem.
    const object = try tree.at(gpa, "sums.o");
    defer gpa.free(object);
    const start = try tree.at(gpa, "lib/libluce_start.a");
    defer gpa.free(start);
    const runtime = try tree.at(gpa, "lib/libluce_rt.a");
    defer gpa.free(runtime);
    const linked = try tree.at(gpa, "byhand");
    defer gpa.free(linked);
    const by_hand: []const []const u8 = if (@import("builtin").os.tag.isDarwin())
        &.{
            "cc",         "-o",     linked,       object,  start,        runtime,
            "-framework", "AppKit", "-framework", "Metal", "-framework", "QuartzCore",
        }
    else
        &.{ "cc", "-o", linked, object, start, runtime, "-pthread", "-lm" };
    var link = try tree.spawn(gpa, by_hand, .{});
    defer link.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), link.status);

    var byhand = try tree.spawn(gpa, &.{linked}, .{});
    defer byhand.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), byhand.status);
    try testing.expectEqualStrings("total 30\n", byhand.out);

    // And the shape that does that linking itself: a bare name, and a
    // file a shell runs.
    var executable = try runLuce(gpa, &tree, &.{ "build", program, "--emit=exe" }, null);
    defer executable.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), executable.status);
    try testing.expect(executable.saysOut("sums.luc -> "));
    try testing.expect(tree.exists("sums"));

    const standalone = try tree.at(gpa, "sums");
    defer gpa.free(standalone);
    var ran = try tree.spawn(gpa, &.{standalone}, .{});
    defer ran.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), ran.status);
    try testing.expectEqualStrings("total 30\n", ran.out);
    try testing.expectEqualStrings("", ran.err);

    // `-o` names the file whatever the shape, and the extension rule
    // does not get a say.
    const elsewhere = try tree.at(gpa, "chosen.bin");
    defer gpa.free(elsewhere);
    var placed = try runLuce(gpa, &tree, &.{ "build", program, "-o", elsewhere, "--emit=exe" }, null);
    defer placed.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), placed.status);
    try testing.expect(tree.exists("chosen.bin"));
}

// ---------------------------------------------------------------------------
// The two modes, and how a run ends
// ---------------------------------------------------------------------------

const stumbles =
    \\func at(xs: list[i64], index: i64) -> i64:
    \\    return xs[index]
    \\
    \\func main():
    \\    var xs: list[i64] = [1, 2, 3]
    \\    print("before")
    \\    print(str(at(xs, 7)))
    \\
;

test "a debug artifact says where it trapped; a release one says what trapped" {
    // The CLI half of docs/MODES.md.  `--release` has exactly one
    // meaning — the artifact carries no origins — and the way to see
    // it is a program that stops: debug names `file:line:column` for
    // every frame, release names the functions and no positions.  Both
    // print the same output, trap at the same call, and exit with the
    // same number, because the mode is not allowed to change the
    // program.
    const gpa = testing.allocator;
    var tree = try installTree(gpa);
    defer tree.deinit(gpa);
    try tree.write("stumble.luc", stumbles);
    const program = try tree.at(gpa, "stumble.luc");
    defer gpa.free(program);

    const debug_path = try tree.at(gpa, "debug");
    defer gpa.free(debug_path);
    var debug_build = try runLuce(gpa, &tree, &.{ "build", program, "--emit=exe", "-o", debug_path }, null);
    defer debug_build.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), debug_build.status);

    const release_path = try tree.at(gpa, "release");
    defer gpa.free(release_path);
    var release_build = try runLuce(
        gpa,
        &tree,
        &.{ "build", program, "--emit=exe", "-o", release_path, "--release" },
        null,
    );
    defer release_build.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), release_build.status);

    var debug_ran = try tree.spawn(gpa, &.{debug_path}, .{});
    defer debug_ran.deinit(gpa);
    var release_ran = try tree.spawn(gpa, &.{release_path}, .{});
    defer release_ran.deinit(gpa);

    // Same program, so: same output, same trap, same status.
    try testing.expectEqualStrings("before\n", debug_ran.out);
    try testing.expectEqualStrings("before\n", release_ran.out);
    try testing.expectEqual(@as(u8, 1), debug_ran.status);
    try testing.expectEqual(@as(u8, 1), release_ran.status);
    for ([_]*const Ran{ &debug_ran, &release_ran }) |ran| {
        try testing.expect(ran.saysErr("trap: index out of bounds [index_bounds]"));
        // Both name the calls, innermost first.
        try testing.expect(ran.saysErr("at at"));
        try testing.expect(ran.saysErr("at main"));
    }

    // The difference, and the only one: debug carries positions.
    try testing.expect(debug_ran.saysErr("stumble.luc:2:5"));
    try testing.expect(debug_ran.saysErr("stumble.luc:7:5"));
    // Release carries none — no source name, no line, not one.
    try testing.expect(!release_ran.saysErr("stumble.luc"));
    try testing.expect(!release_ran.saysErr("("));

    // What is deliberately *not* asserted here: that the release file
    // is smaller.  It is not, at this level — the two executables come
    // out byte-for-byte the same length, because an origin table this
    // small disappears into the segment alignment a linker rounds
    // every Mach-O and ELF section up to, and what is left is mostly
    // libluce_rt either way.  Whether the tables actually left the
    // *artifact* is a question about the artifact, and belongs to a
    // test that reads one; from out here the trap report is the whole
    // of the observable difference, which is exactly the promise
    // docs/MODES.md makes.
}

test "the standalone binary answers 0 for finished, 1 for a trap, 3 for an uncaught error" {
    // `apps/start.zig` is a whole product with no process of its own
    // to be tested in: it is the `main` a compiled program becomes an
    // executable with, and everything it does — checking the tag it
    // was linked against, running, restoring the screen, reporting,
    // scoring — happens between a shell's `exec` and its `$?`.
    //
    // A trap and an uncaught error are two different sentences about a
    // program (docs/FAILURE.md), so they are two different numbers,
    // and a script can tell them apart without parsing stderr.
    const gpa = testing.allocator;
    var tree = try installTree(gpa);
    defer tree.deinit(gpa);

    const endings = [_]struct {
        name: []const u8,
        source: []const u8,
        status: u8,
        out: []const u8,
        says: []const u8,
    }{
        .{
            .name = "fine",
            .source = greeting,
            .status = 0,
            .out = "total 30\n",
            .says = "",
        },
        .{
            .name = "stumble",
            .source = stumbles,
            .status = 1,
            .out = "before\n",
            .says = "luce: trap: index out of bounds [index_bounds]",
        },
        .{
            .name = "refuse",
            .source =
            \\func check(value: i64) -> i64!:
            \\    if value < 0:
            \\        error(f"negative: {value}")
            \\    return value
            \\
            \\func main() -> !:
            \\    print(str(try check(1)))
            \\    print(str(try check(-5)))
            \\
            ,
            .status = 3,
            .out = "1\n",
            .says = "luce: error: negative: -5 [user_error]",
        },
    };

    for (endings) |ending| {
        const source_name = try std.fmt.allocPrint(gpa, "{s}.luc", .{ending.name});
        defer gpa.free(source_name);
        try tree.write(source_name, ending.source);
        const program = try tree.at(gpa, source_name);
        defer gpa.free(program);

        var built = try runLuce(gpa, &tree, &.{ "build", program, "--emit=exe" }, null);
        defer built.deinit(gpa);
        try testing.expectEqual(@as(u8, 0), built.status);

        const binary = try tree.at(gpa, ending.name);
        defer gpa.free(binary);
        var ran = try tree.spawn(gpa, &.{binary}, .{});
        defer ran.deinit(gpa);
        try testing.expectEqual(ending.status, ran.status);
        try testing.expectEqualStrings(ending.out, ran.out);
        if (ending.says.len == 0) {
            try testing.expectEqualStrings("", ran.err);
        } else {
            try testing.expect(ran.saysErr(ending.says));
        }
        // Nothing ever escaped ownership: that report is an engine
        // bug, and it must not appear on any of these three paths.
        try testing.expect(!ran.saysErr("escaped ownership"));
    }
}

test "a standalone binary reads the arguments it was given, past its own name" {
    // `args[0]` is the first thing the person typed after the program,
    // which is what `loom run PROGRAM a b` gives too — a program's
    // behaviour must not depend on who started it (MEMORY.md).
    const gpa = testing.allocator;
    var tree = try installTree(gpa);
    defer tree.deinit(gpa);
    try tree.write("echo.luc",
        \\func main(args: list[str]):
        \\    print(str(len(args)))
        \\    for word in args:
        \\        print(word)
        \\
    );
    const program = try tree.at(gpa, "echo.luc");
    defer gpa.free(program);
    var built = try runLuce(gpa, &tree, &.{ "build", program, "--emit=exe" }, null);
    defer built.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), built.status);

    const binary = try tree.at(gpa, "echo");
    defer gpa.free(binary);
    var bare = try tree.spawn(gpa, &.{binary}, .{});
    defer bare.deinit(gpa);
    try testing.expectEqualStrings("0\n", bare.out);

    var given = try tree.spawn(gpa, &.{ binary, "alpha", "beta" }, .{});
    defer given.deinit(gpa);
    try testing.expectEqualStrings("2\nalpha\nbeta\n", given.out);
}

// ---------------------------------------------------------------------------
// luce test
// ---------------------------------------------------------------------------
//
// `luce test` is a compiler *and* a runner (docs/TESTING.md), and every
// part of it that matters is outside the process: the working
// directory is what `tests/` means, a failing test's report is what a
// person reads, the exit status is what a build script reads, and the
// artifact it built has to be gone afterwards.  So it is proved here,
// over a real tree, run exactly as a person would run it.

/// A project laid out the way the memo assumes: code at the root under
/// a `luce.yaml`, tests in `tests/` importing it by name.
fn testedProject(gpa: Allocator) !Install {
    var tree = try installTree(gpa);
    errdefer tree.deinit(gpa);

    try tree.write("luce.yaml",
        \\name: geo
        \\version: 0.1.0
        \\
    );
    try tree.write("geo.luc",
        \\pub func area(width: i64, height: i64) -> i64:
        \\    return width * height
        \\
        \\pub func at(xs: list[i64], index: i64) -> i64:
        \\    return xs[index]
        \\
    );
    // Two passing tests and one that traps two frames down, so the
    // trace has something to say.  The import is the whole reason the
    // project has a root: `tests/geo_test.luc` reaching `geo` means
    // the project's geo, not a phantom `tests/geo.luc` (D3).
    try tree.write("tests/geo_test.luc",
        \\import geo
        \\
        \\func helper(side: i64) -> i64:
        \\    return geo.area(side, side)
        \\
        \\pub func test_area_of_unit_square():
        \\    assert(geo.area(1, 1) == 1)
        \\
        \\pub func test_area_of_square():
        \\    print("checking 5 x 5")
        \\    assert(helper(5) == 25)
        \\
        \\pub func test_reads_past_the_end():
        \\    var xs: list[i64] = [1, 2, 3]
        \\    assert(geo.at(xs, 7) == 0)
        \\
    );
    // The two endings that are not a trap: an error the world raised,
    // and a test that walked out.
    try tree.write("tests/edge_test.luc",
        \\pub func test_refuses() -> !:
        \\    error("the world said no")
        \\
        \\pub func test_walks_out():
        \\    exit(3)
        \\
    );
    // A helper module: swept, holds no test, never claimed to.
    try tree.write("tests/support.luc",
        \\func doubled(value: i64) -> i64:
        \\    return value * 2
        \\
    );
    return tree;
}

test "luce test compiles a tests tree, runs each test on its own, and scores the run" {
    const gpa = testing.allocator;
    var tree = try testedProject(gpa);
    defer tree.deinit(gpa);

    var ran = try runLuceHere(gpa, &tree, &.{"test"});
    defer ran.deinit(gpa);

    // Red, because three of the six tests failed.
    try testing.expectEqual(@as(u8, 1), ran.status);

    // Files in sorted order, tests in declaration order — the report
    // is a property of the tree, not of the filesystem's iteration.
    const order = [_][]const u8{
        "tests/edge_test.luc\n",
        "test_refuses",
        "test_walks_out",
        "tests/geo_test.luc\n",
        "test_area_of_unit_square",
        "test_area_of_square",
        "test_reads_past_the_end",
    };
    var at: usize = 0;
    for (order) |word| {
        const found = std.mem.indexOfPos(u8, ran.out, at, word) orelse {
            std.debug.print("the report never says {s}\n", .{word});
            return error.TestUnexpectedResult;
        };
        at = found;
    }

    // Every call is announced before entry. The test's own output then
    // lands between that progress line and the final verdict, in the
    // same order in a captured report as it has on a terminal.
    try testing.expect(ran.saysOut(
        "  test  test_area_of_unit_square\n" ++
            "  ok    test_area_of_unit_square\n",
    ));
    try testing.expect(std.mem.indexOf(
        u8,
        ran.out,
        "  test  test_area_of_square\nchecking 5 x 5\n  ok    test_area_of_square",
    ) != null);

    // A trap, rendered as every trap is, indented under the name that
    // took it — and with the *called* frames in it, which is what makes
    // a debug build the only build this command makes.
    try testing.expect(ran.saysOut("  FAIL  test_reads_past_the_end\n"));
    try testing.expect(ran.saysOut("        luce: trap: index out of bounds [index_bounds]"));
    try testing.expect(ran.saysOut("            at geo.at ("));
    try testing.expect(ran.saysOut("            at test_reads_past_the_end (tests/geo_test.luc:"));

    // An error is not a trap and does not print a stack
    // (docs/FAILURE.md); it prints where it was raised.
    try testing.expect(ran.saysOut("        luce: error: the world said no [user_error]"));
    try testing.expect(ran.saysOut("            raised in test_refuses (tests/edge_test.luc:2:5)"));

    // A test that exits fails by name, whatever status it chose.
    try testing.expect(ran.saysOut("        it called exit(3); a test returns\n"));

    // One summary line, counting the helper module so a wrongly-silent
    // file is one glance away.
    try testing.expect(ran.saysOut(
        "2 passed, 3 failed, 5 tests in 2 files, 1 file without tests\n",
    ));

    // Nothing was left behind: the artifacts were removed, and the
    // `NAME.lc` a `luce build --emit=library` would write was never touched.
    try testing.expect(!tree.exists("tests/geo_test.lc"));
    try testing.expect(!tree.exists("tests/edge_test.lc"));
    for ([_][]const u8{ ".lc", luce_module_extension }) |suffix| {
        try testing.expect(!try holdsAnythingUnder(&tree, "tests", suffix));
    }
}

test "a green run says so and exits 0" {
    // The other half of the exit status: a build script reads `$?` and
    // needs it to mean something.
    const gpa = testing.allocator;
    var tree = try installTree(gpa);
    defer tree.deinit(gpa);
    try tree.write("tests/plain_test.luc",
        \\pub func test_arithmetic():
        \\    assert(2 + 2 == 4)
        \\
    );

    var ran = try runLuceHere(gpa, &tree, &.{"test"});
    defer ran.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), ran.status);
    try testing.expect(ran.saysOut(
        "  test  test_arithmetic\n" ++
            "  ok    test_arithmetic\n",
    ));
    try testing.expect(ran.saysOut("1 passed, 0 failed, 1 test in 1 file\n"));
    try testing.expectEqualStrings("", ran.err);
}

test "a discovery refusal and a compile failure are reported, and the healthy files still run" {
    // Both are "this file did not run", both make the run red, and
    // neither may stop the file after it (D4).  The refusal is
    // positioned so an editor can jump to it, and names the fix.
    const gpa = testing.allocator;
    var tree = try installTree(gpa);
    defer tree.deinit(gpa);

    try tree.write("tests/a_hidden_test.luc",
        \\func test_never_runs():
        \\    assert(true)
        \\
    );
    try tree.write("tests/b_broken_test.luc",
        \\pub func test_typed():
        \\    let count: i64 = "seven"
        \\    assert(count == 7)
        \\
    );
    try tree.write("tests/c_healthy_test.luc",
        \\pub func test_still_ran():
        \\    assert(true)
        \\
    );

    var ran = try runLuceHere(gpa, &tree, &.{"test"});
    defer ran.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), ran.status);

    try testing.expect(ran.saysOut(
        "tests/a_hidden_test.luc:1:6: test_never_runs is not public and would never run",
    ));
    try testing.expect(ran.saysOut("mark it pub, or rename it if it is a helper"));
    try testing.expect(ran.saysOut("tests/b_broken_test.luc:2:5:"));
    try testing.expect(ran.saysOut("[luce.sema.type]"));
    // The third file ran anyway, which is the claim.
    try testing.expect(ran.saysOut("  ok    test_still_ran\n"));
    try testing.expect(ran.saysOut("1 passed, 0 failed, 1 test in 1 file, 2 files not run\n"));
}

test "a named file with no tests is refused, and a swept one is a helper module" {
    // The same silent file, twice, answered two ways (D2): naming it
    // is a claim that it holds tests, and sweeping it is not.
    const gpa = testing.allocator;
    var tree = try testedProject(gpa);
    defer tree.deinit(gpa);

    var named = try runLuceHere(gpa, &tree, &.{ "test", "tests/support.luc" });
    defer named.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), named.status);
    try testing.expect(named.saysOut("tests/support.luc: no tests here"));

    // Swept as part of a directory, it is counted and nothing else.
    var swept = try runLuceHere(gpa, &tree, &.{ "test", "tests/geo_test.luc", "tests/support.luc" });
    defer swept.deinit(gpa);
    try testing.expect(swept.saysOut("no tests here"));

    // And a `tests/` directory that is not there at all is a plain
    // failure naming what was looked for, never a green run of nothing.
    var bare = try installTree(gpa);
    defer bare.deinit(gpa);
    var nothing = try runLuceHere(gpa, &bare, &.{"test"});
    defer nothing.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), nothing.status);
    try testing.expect(nothing.saysErr("no tests directory here"));
    try testing.expectEqualStrings("", nothing.out);
}

test "luce test takes paths and no build options" {
    const gpa = testing.allocator;
    var tree = try testedProject(gpa);
    defer tree.deinit(gpa);

    // One file, named: only its tests run.
    var one = try runLuceHere(gpa, &tree, &.{ "test", "tests/edge_test.luc" });
    defer one.deinit(gpa);
    try testing.expect(one.saysOut("test_refuses"));
    try testing.expect(!one.saysOut("test_area_of_unit_square"));

    // A path that is neither file nor directory stops the command
    // rather than being quietly swept up in nothing.
    var absent = try runLuceHere(gpa, &tree, &.{ "test", "tests/nowhere_test.luc" });
    defer absent.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), absent.status);
    try testing.expect(absent.saysErr("no such file or directory"));
    try testing.expectEqualStrings("", absent.out);

    // `--release` would strip the trap origins the report is made of,
    // so there is no option to give: it is a path, and it is not there.
    var released = try runLuceHere(gpa, &tree, &.{ "test", "--release" });
    defer released.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), released.status);
    try testing.expect(released.saysErr("--release"));
}

/// Whether anything under `directory` in the tree ends in `suffix` —
/// what "the artifact was removed" is a claim about.
fn holdsAnythingUnder(tree: *const Install, directory: []const u8, suffix: []const u8) !bool {
    var opened = tree.scratch.dir.openDir(io, directory, .{ .iterate = true }) catch return false;
    defer opened.close(io);
    var walk = opened.iterate();
    while (try walk.next(io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, suffix)) return true;
    }
    return false;
}
