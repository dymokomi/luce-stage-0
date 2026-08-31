//! The loom terminal: the environment that runs compiled Luce.
//!
//!   loom                       the interactive shell
//!   loom run PROGRAM.lc [ARGS] run a compiled program
//!   loom luce PROGRAM.luc [..] compile a source file and run it
//!   loom PROGRAM.lc [ARGS]     sugar for run (and .luc for luce)
//!
//! `run` takes a `.lc`, which is machine code: one `dlopen`, one
//! symbol lookup, one call (runner.zig).  `luce` compiles a `.luc`
//! into one first.
//!
//! Loom is deliberately thin: ordinary files, the real terminal, and
//! the host boundary.  No disk images, no engine — programs carry the
//! behavior.

const builtin = @import("builtin");
const std = @import("std");
const build_info = @import("build_info");
const runner = @import("runner.zig");
const shell_mod = @import("shell.zig");
const streams = @import("streams");

pub fn main(init: std.process.Init.Minimal) !u8 {
    // loom's own allocator, and only its own: a program's objects come
    // from the copy of `libluce_rt` inside the artifact, which uses
    // libc's malloc (`runtime/exports.zig`).  A debug build pays for
    // the leak check and gets it; an optimized build takes malloc
    // directly.
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = switch (builtin.mode) {
        .Debug => debug_allocator.allocator(),
        .ReleaseSafe, .ReleaseFast, .ReleaseSmall => std.heap.c_allocator,
    };

    var threaded: std.Io.Threaded = .init(gpa, .{
        .environ = init.environ,
        .argv0 = .init(init.args),
    });
    defer threaded.deinit();
    const io = threaded.io();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const arguments = try init.args.toSlice(arena);

    var environ_map = try init.environ.createMap(gpa);
    defer environ_map.deinit();
    const no_color = environ_map.get("NO_COLOR") != null;
    // Where the compiler is and where a built artifact may go, read
    // once: it is process policy, not something a program or a command
    // can change (runner.zig).
    const policy = runner.Policy.read(&environ_map);
    var err_writer = streams.diagnostics(io);
    const err = &err_writer.interface;
    var out_buffer: [8192]u8 = undefined;
    var out_writer = streams.output(io, &out_buffer);
    const out = &out_writer.interface;

    if (arguments.len == 2 and std.mem.eql(u8, arguments[1], "--version")) {
        try out.print("loom {s}\n", .{build_info.version});
        try out.flush();
        return 0;
    }
    if (arguments.len == 2 and std.mem.eql(u8, arguments[1], "--build-info")) {
        try build_info.write(out, "loom");
        try out.flush();
        return 0;
    }

    const colored = !no_color and (std.Io.File.stdout().isTty(io) catch false);
    var shell: shell_mod.Shell = .{
        .gpa = gpa,
        .io = io,
        .out = out,
        .err = err,
        .palette = .{ .enabled = colored },
        .policy = policy,
    };

    if (arguments.len < 2) {
        const stdin = std.Io.File.stdin();
        const interactive = stdin.isTty(io) catch false;
        var in_buffer: [4096]u8 = undefined;
        var reader = stdin.reader(io, &in_buffer);
        return shell.run(&reader.interface, interactive);
    }

    const command = arguments[1];
    if (std.mem.eql(u8, command, "run")) {
        if (arguments.len < 3) return usage(err);
        return runner.runModule(gpa, io, out, err, arguments[2], arguments[3..]);
    }
    if (std.mem.eql(u8, command, "luce")) {
        if (arguments.len < 3) return usage(err);
        return runner.runScript(gpa, io, out, err, policy, arguments[2], arguments[3..]);
    }
    if (std.mem.endsWith(u8, command, ".lc")) {
        return runner.runModule(gpa, io, out, err, command, arguments[2..]);
    }
    if (std.mem.endsWith(u8, command, ".luc")) {
        return runner.runScript(gpa, io, out, err, policy, command, arguments[2..]);
    }
    return usage(err);
}

fn usage(err: *std.Io.Writer) !u8 {
    try err.print(
        "usage:\n" ++
            "  loom --version\n" ++
            "  loom --build-info\n" ++
            "  loom                        interactive shell\n" ++
            "  loom run PROGRAM.lc [ARGS]  run a compiled program\n" ++
            "  loom luce PROGRAM.luc [..]  compile a source file and run it\n" ++
            "  loom PROGRAM.lc [ARGS]      shorthand for run\n" ++
            "  loom PROGRAM.luc [ARGS]     shorthand for luce\n",
        .{},
    );
    return 1;
}

test {
    _ = @import("runner.zig");
    _ = @import("shell.zig");
}
