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
const macos_graphics = @import("macos_graphics");
const report = @import("report");
const streams = @import("streams");

const abi = luce.llvm.abi;
const artifact = luce.llvm.artifact;

/// The program linked beside this shim.  Undefined here on purpose:
/// the link is what supplies it, and a `libluce_start.a` linked
/// without a compiled program fails to link rather than to run.
extern fn luce_main(host: *const abi.Host) callconv(.c) abi.Status;

/// What the program says it is.  Checked before it is called, because
/// a shim and an object from two different compilers link cleanly and
/// then disagree about the shape of the table being handed over.
extern const luce_artifact: artifact.Artifact;

export fn main(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    const gpa = std.heap.c_allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var err_writer = streams.diagnostics(io);
    const err = &err_writer.interface;
    var out_buffer: [8192]u8 = undefined;
    var out_writer = streams.output(io, &out_buffer);
    const out = &out_writer.interface;

    // argv[0] is the program's own path; `arg(0)` is the first thing
    // the user typed after it, which is what `loom run PROGRAM a b`
    // gives as well.
    const count: usize = if (argc > 1) @intCast(argc - 1) else 0;
    const arguments = gpa.alloc([]const u8, count) catch {
        err.print("luce: out of memory\n", .{}) catch {};
        return report.exit_exhausted;
    };
    defer gpa.free(arguments);
    for (arguments, 0..) |*argument, index| {
        argument.* = std.mem.span(argv[index + 1]);
    }

    if (artifact.check(&luce_artifact, null)) |mismatch| {
        err.print(
            "luce: this executable was built from a mismatched artifact ({s}); rebuild it from source\n",
            .{@tagName(mismatch)},
        ) catch {};
        err.flush() catch {};
        return report.exit_broken;
    }

    var services: host_mod.Host = undefined;
    services.setup(gpa, io, out, err, arguments);
    defer services.deinit();

    var graphics = macos_graphics.init();
    defer if (graphics) |*backend| macos_graphics.deinit(backend);
    if (graphics) |*backend| macos_graphics.install(&services, backend);

    const table = services.table();
    const status = luce_main(&table);

    // Land back on the ordinary screen before saying anything, the
    // same order loom's runner uses.
    services.restoreScreen();
    // Output that could not be written did not happen: a full or
    // closed pipe swallows the tail, and exiting 0 would claim it
    // arrived.  loom's runner says the same thing the same way.
    const delivered = if (out.flush()) |_| true else |_| undelivered: {
        err.print("luce: output could not be written\n", .{}) catch {};
        break :undelivered false;
    };
    const code = finish(&services, err, status);
    err.flush() catch {};
    if (code == report.exit_ok and !delivered) return report.exit_broken;
    return code;
}

/// How the run ended, said and scored — every sentence and every
/// number out of `apps/report.zig`, which is also where loom's runner
/// gets them.  Nothing about a failure is rendered twice in this tree.
fn finish(services: *host_mod.Host, err: *std.Io.Writer, status: abi.Status) c_int {
    switch (status) {
        .ok => {
            report.printLeaks(err, "", "luce", services.leaked orelse 0);
            return report.exit_ok;
        },
        .errored => {
            const raised = services.reportedError() orelse {
                err.print("luce: the program failed and said nothing\n", .{}) catch {};
                return report.exit_errored;
            };
            report.printError(err, "", "luce", @tagName(raised.code), raised.message, raised.origin);
            return report.exit_errored;
        },
        .trapped => {
            const trap = services.reportedTrap() orelse {
                err.print("luce: the program trapped and said nothing\n", .{}) catch {};
                return report.exit_trapped;
            };
            report.printTrap(
                err,
                "",
                "luce",
                @tagName(trap.code),
                trap.message,
                trap.trace,
                trap.dropped,
            );
            return report.exit_trapped;
        },
        .exhausted => {
            err.print("luce: out of memory\n", .{}) catch {};
            return report.exit_exhausted;
        },
        .exited => {
            // The program's chosen end: quiet, and the process
            // carries the low eight bits the way POSIX does.
            return @intCast((services.exit_status orelse 0) & 0xff);
        },
        _ => {
            err.print("luce: the program returned an unknown status\n", .{}) catch {};
            return report.exit_broken;
        },
    }
}
