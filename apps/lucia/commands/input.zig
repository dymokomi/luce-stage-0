//! input NAME TYPE — add a typed Input Port to the selected texel.

const command = @import("../command.zig");
const common = @import("common.zig");
const ops = @import("../ops.zig");

const Session = command.Session;
const Error = command.Error;
const Result = command.Result;

pub const entry: command.Command = .{
    .name = "input",
    .alias = "in",
    .argument_count = 2,
    .usage = "input NAME TYPE          (in)  add an Input Port to the selected texel",
    .run = run,
};

fn run(session: *Session, words: []const []const u8) Error!Result {
    const declared = try common.parseType(session, words[2]) orelse return .err;
    if (!try common.selectedExists(session)) return .err;
    ops.addInput(session.allocator, session.store, session.selected, words[1], declared) catch |mistake|
        switch (mistake) {
            error.OutOfMemory => return error.OutOfMemory,
            error.PortExists => {
                try session.err.print("lucia: input {s} already exists\n", .{words[1]});
                return .err;
            },
            else => return common.commitFailed(session, "input"),
        };
    return .ok;
}
