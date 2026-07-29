//! watch OUTPUT — event-activated demand: print the selected texel's
//! output now, then again whenever a change moves its value.

const command = @import("../command.zig");
const common = @import("common.zig");

const Session = command.Session;
const Error = command.Error;
const Result = command.Result;

pub const entry: command.Command = .{
    .name = "watch",
    .alias = "w",
    .argument_count = 1,
    .usage = "watch OUTPUT             (w)   print a selected output when it changes",
    .run = run,
};

fn run(session: *Session, words: []const []const u8) Error!Result {
    if (!try common.selectedExists(session)) return .err;
    if (!session.store.get(session.selected).?.hasOutput(words[1])) {
        try session.err.print("loom: no output named {s}\n", .{words[1]});
        return .err;
    }
    if (session.findWatch(session.selected, words[1]) != null) {
        try session.err.print("loom: already watching {s}\n", .{words[1]});
        return .err;
    }

    const outcome = try session.spool.demand(session.selected, words[1]);
    const rendered = try common.outcomeText(session.allocator, outcome);
    errdefer session.allocator.free(rendered);
    try common.printOutcome(session, session.selected, words[1], outcome);

    const output = try session.allocator.dupe(u8, words[1]);
    errdefer session.allocator.free(output);
    try session.watches.append(session.allocator, .{
        .texel = session.selected,
        .output = output,
        .last = rendered,
    });
    return .ok;
}
