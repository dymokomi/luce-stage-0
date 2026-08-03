//! The loom terminal: the environment that runs compiled Luce.
//!
//!   loom                       the interactive shell
//!   loom run PROGRAM.lc [ARGS] run a compiled program
//!   loom luce PROGRAM.luc [..] compile a source file and run it
//!   loom edit FILE             open the Luce editor on a file
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
const runner = @import("runner.zig");
const shell_mod = @import("shell.zig");
const streams = @import("streams");

pub fn main(init: std.process.Init.Minimal) !u8 {
    // One allocator for loom and for the objects the program it runs
    // allocates (`backend.Memory.objects`), which puts it on the
    // running program's hot path: scope ownership allocates and frees
    // objects as the program's scopes open and close.  A debug build
    // pays for the leak check and gets it; an optimized build takes
    // libc's malloc, which is 13x faster on that traffic and is what
    // a compiled artifact already uses (`runtime/exports.zig`).
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
    const editor_override = environ_map.get("LOOM_EDITOR");
    // Where the compiler is and where a built artifact may go, read
    // once: it is process policy, not something a program or a command
    // can change (runner.zig).
    const policy = runner.Policy.read(&environ_map);
    var err_writer = streams.diagnostics(io);
    const err = &err_writer.interface;
    var out_buffer: [8192]u8 = undefined;
    var out_writer = streams.output(io, &out_buffer);
    const out = &out_writer.interface;

    const colored = !no_color and (std.Io.File.stdout().isTty(io) catch false);
    var shell: shell_mod.Shell = .{
        .gpa = gpa,
        .io = io,
        .out = out,
        .err = err,
        .palette = .{ .enabled = colored },
        .editor_override = editor_override,
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
    if (std.mem.eql(u8, command, "edit")) {
        if (arguments.len != 3) return usage(err);
        return shell.edit(arguments[2]);
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
            "  loom                        interactive shell\n" ++
            "  loom run PROGRAM.lc [ARGS]  run a compiled program\n" ++
            "  loom luce PROGRAM.luc [..]  compile a source file and run it\n" ++
            "  loom edit FILE              open the Luce editor\n" ++
            "  loom PROGRAM.lc [ARGS]      shorthand for run\n",
        .{},
    );
    return 1;
}

test {
    _ = @import("palette.zig");
    _ = @import("runner.zig");
    _ = @import("shell.zig");
}
