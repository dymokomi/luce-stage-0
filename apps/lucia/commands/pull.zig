//! pull OUTPUT — one-shot demand on the selected texel's output through
//! the session spool.  Demand pulls upstream values and runs evaluators
//! only where cached revisions are stale.

const command = @import("../command.zig");
const common = @import("common.zig");

const Session = command.Session;
const Error = command.Error;
const Result = command.Result;

pub const entry: command.Command = .{
    .name = "pull",
    .alias = "p",
    .argument_count = 1,
    .usage = "pull OUTPUT              (p)   demand a selected output and print it",
    .run = run,
};

fn run(session: *Session, words: []const []const u8) Error!Result {
    if (!try common.selectedExists(session)) return .err;

    const outcome = try session.spool.demand(session.selected, words[1]);
    switch (outcome.*) {
        .err => {
            const rendered = try common.outcomeText(session.allocator, outcome);
            defer session.allocator.free(rendered);
            try session.err.print("lucia: {s}\n", .{rendered});
            return .err;
        },
        .unavailable => try session.out.print("unavailable\n", .{}),
        .available => |value| {
            const rendered = try common.valueText(session.allocator, value);
            defer session.allocator.free(rendered);
            try session.out.print("{s}\n", .{rendered});
        },
    }
    return .ok;
}
