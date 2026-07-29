//! connect INPUT ID OUTPUT — bind the selected texel's INPUT to OUTPUT
//! on the source texel (an id or a unique name).  Port types must
//! match; an Input Port holds at most one Fiber, so connecting again
//! replaces the old binding.

const command = @import("../command.zig");
const common = @import("common.zig");

const Session = command.Session;
const Error = command.Error;
const Result = command.Result;

pub const entry: command.Command = .{
    .name = "connect",
    .alias = "c",
    .argument_count = 3,
    .usage = "connect INPUT ID OUTPUT  (c)   bind a selected input to a source output",
    .run = run,
};

fn run(session: *Session, words: []const []const u8) Error!Result {
    const source = try common.resolveTexel(session, words[2]) orelse return .err;
    if (!try common.selectedExists(session)) return .err;

    var transaction = session.store.begin() catch return refused(session);
    defer transaction.deinit();
    transaction.connect(session.selected, words[1], source, words[3]) catch
        return refused(session);
    transaction.commit() catch return refused(session);
    return .ok;
}

fn refused(session: *Session) Error!Result {
    try session.err.print(
        "loom: connect failed (check both ports exist and types match)\n",
        .{},
    );
    return .err;
}
