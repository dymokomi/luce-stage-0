//! disconnect INPUT — unbind the Fiber on the selected texel's INPUT.

const command = @import("../command.zig");
const common = @import("common.zig");
const ops = @import("../ops.zig");

const Session = command.Session;
const Error = command.Error;
const Result = command.Result;

pub const entry: command.Command = .{
    .name = "disconnect",
    .alias = "dc",
    .argument_count = 1,
    .usage = "disconnect INPUT         (dc)  unbind an input on the selected texel",
    .run = run,
};

fn run(session: *Session, words: []const []const u8) Error!Result {
    if (!try common.selectedExists(session)) return .err;

    ops.disconnect(session.store, session.selected, words[1]) catch |mistake|
        switch (mistake) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return refused(session, words[1]),
        };
    return .ok;
}

fn refused(session: *Session, name: []const u8) Error!Result {
    try session.err.print("lucia: disconnect failed (no bound input named {s})\n", .{name});
    return .err;
}
