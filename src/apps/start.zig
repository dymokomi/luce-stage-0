//! `libluce_start` — the `main` a compiled Luce program becomes an
//! executable with.
//!
//! A compiled artifact exports `luce_main(const LuceHost *)` and
//! nothing else (`luce.llvm.abi`).  That is enough to be *loaded* — by
//! loom, by an embedder — but not enough to be *run* by a shell, which
//! wants a process with an entry point, arguments, a console, and an
//! exit status.  This file is that shim, and it is a static library so
//! that `luce build --emit=exe` is one `cc` invocation:
//!
//! ```sh
//! cc -o prog prog.o libluce_start.a libluce_rt.a
//! ```
//!
//! **The services are loom's, not a second set.**  A standalone binary
//! offers the same host as `loom run` — the same console, the same
//! cwd-relative files, the same 256-color terminal, the same key
//! names, the same call-depth policy — because it is the same
//! `apps/host.zig`.  Anything else would make "the compiled program
//! behaves identically" true of one runner and not the other, and the
//! whole two-engine bargain rests on it being true everywhere.
//!
//! It reports a trap exactly as loom's runner does, for the same
//! reason: a trap's rendering is part of what the two engines have to
//! agree on.

const std = @import("std");
const luce = @import("luce");
const host_mod = @import("host");

const abi = luce.llvm.abi;

/// The program linked beside this shim.  Undefined here on purpose:
/// the link is what supplies it, and a `libluce_start.a` linked
/// without a compiled program fails to link rather than to run.
extern fn luce_main(host: *const abi.Host) callconv(.c) abi.Status;

/// What the program says it is.  Checked before it is called, because
/// a shim and an object from two different compilers link cleanly and
/// then disagree about the shape of the table being handed over.
extern const luce_artifact: abi.Artifact;

/// A trap trace prints at most this many frames — loom's number, so
/// the two runners render the same trap the same way.
const max_printed_frames = 12;

/// Exit statuses.  A trap is `1`, which is what loom returns and what
/// a shell reads as "the program failed".  Running out of memory is
/// not the program's fault and says so with a different number.
const exit_trapped = 1;
const exit_exhausted = 70;
const exit_broken = 71;

export fn main(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    const gpa = std.heap.c_allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var err_writer = std.Io.File.stderr().writer(io, &.{});
    const err = &err_writer.interface;
    var out_buffer: [8192]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(io, &out_buffer);
    const out = &out_writer.interface;

    // argv[0] is the program's own path; `arg(0)` is the first thing
    // the user typed after it, which is what `loom run PROGRAM a b`
    // gives as well.
    const count: usize = if (argc > 1) @intCast(argc - 1) else 0;
    const arguments = gpa.alloc([]const u8, count) catch {
        err.print("luce: out of memory\n", .{}) catch {};
        return exit_exhausted;
    };
    defer gpa.free(arguments);
    for (arguments, 0..) |*argument, index| {
        argument.* = std.mem.span(argv[index + 1]);
    }

    if (abi.checkArtifact(&luce_artifact, tripleOf(&luce_artifact), null)) |mismatch| {
        err.print(
            "luce: this executable was built from a mismatched artifact ({s}); rebuild it from source\n",
            .{@tagName(mismatch)},
        ) catch {};
        err.flush() catch {};
        return exit_broken;
    }

    var services: host_mod.Host = undefined;
    services.setup(gpa, io, out, arguments);
    defer services.deinit();

    const table = services.table();
    const status = luce_main(&table);

    // Land back on the ordinary screen before saying anything, the
    // same order loom's runner uses.
    services.restoreScreen();
    out.flush() catch {};
    const code = report(&services, err, status);
    err.flush() catch {};
    return code;
}

/// The artifact's own triple, which is trivially the triple it was
/// built for: a wrong-architecture executable never reached `main` at
/// all — the operating system's loader refused it first.  What is
/// still worth checking is the magic, the tag's layout, and the ABI
/// version, and passing the tag its own triple asks exactly that.
fn tripleOf(tag: *const abi.Artifact) []const u8 {
    if (tag.magic != abi.artifact_magic) return "";
    return tag.triple[0..@intCast(tag.triple_length)];
}

fn report(services: *host_mod.Host, err: *std.Io.Writer, status: abi.Status) c_int {
    switch (status) {
        .ok => {
            // Scope ownership frees everything (OWNERSHIP.md S33); a
            // nonzero count is an engine bug, not a program's.
            const leaked = services.leaked orelse 0;
            if (leaked != 0) {
                err.print(
                    "luce: internal error: {d} object{s} escaped ownership — please report this\n",
                    .{ leaked, if (leaked == 1) "" else "s" },
                ) catch {};
            }
            return 0;
        },
        .trapped => {
            const trap = services.reportedTrap() orelse {
                err.print("luce: the program trapped and said nothing\n", .{}) catch {};
                return exit_trapped;
            };
            err.print("luce: trap: {s} [{s}]\n", .{ trap.message, @tagName(trap.code) }) catch {};
            for (trap.trace, 0..) |frame, index| {
                if (index == max_printed_frames) break;
                if (frame.line != 0) {
                    err.print("    at {s} ({s}:{d}:{d})\n", .{
                        frame.function, frame.source, frame.line, frame.column,
                    }) catch {};
                } else {
                    err.print("    at {s}\n", .{frame.function}) catch {};
                }
            }
            const hidden = trap.dropped +
                @as(u32, @intCast(trap.trace.len -| max_printed_frames));
            if (hidden != 0) err.print("    ... {d} more frames\n", .{hidden}) catch {};
            return exit_trapped;
        },
        .exhausted => {
            err.print("luce: out of memory\n", .{}) catch {};
            return exit_exhausted;
        },
        _ => {
            err.print("luce: the program returned an unknown status\n", .{}) catch {};
            return exit_broken;
        },
    }
}
