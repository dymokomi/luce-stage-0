//! unwatch OUTPUT — stop watching an output on the selected texel.

const command = @import("../command.zig");
const common = @import("common.zig");

const Session = command.Session;
const Error = command.Error;
const Result = command.Result;

pub const entry: command.Command = .{
    .name = "unwatch",
    .alias = "uw",
    .argument_count = 1,
    .usage = "unwatch OUTPUT           (uw)  stop watching a selected output",
    .run = run,
};

fn run(session: *Session, words: []const []const u8) Error!Result {
    if (!session.hasSelection()) {
        try session.err.print("lucia: no texel selected (try select ID)\n", .{});
        return .err;
    }
    const index = session.findWatch(session.selected, words[1]) orelse {
        try session.err.print("lucia: not watching {s}\n", .{words[1]});
        return .err;
    };
    var removed = session.watches.orderedRemove(index);
    removed.deinit(session.allocator);
    return .ok;
}
