//! output NAME TYPE — add a typed Output Port to the selected texel.

const loom = @import("loom");
const command = @import("../command.zig");
const common = @import("common.zig");

const OutputPort = loom.texel.OutputPort;
const Session = command.Session;
const Error = command.Error;
const Result = command.Result;

pub const entry: command.Command = .{
    .name = "output",
    .alias = "out",
    .argument_count = 2,
    .usage = "output NAME TYPE         (out) add an Output Port to the selected texel",
    .run = run,
};

fn run(session: *Session, words: []const []const u8) Error!Result {
    const declared = try common.parseType(session, words[2]) orelse return .err;
    if (!try common.selectedExists(session)) return .err;
    if (session.store.get(session.selected).?.hasOutput(words[1])) {
        try session.err.print("lucia: output {s} already exists\n", .{words[1]});
        return .err;
    }

    var transaction = session.store.begin() catch return common.commitFailed(session, "output");
    defer transaction.deinit();
    var changed = try common.cloneForEdit(session, &transaction, session.selected) orelse return .err;
    defer changed.deinit(session.allocator);
    const port = OutputPort.init(session.allocator, words[1], declared) catch
        return common.commitFailed(session, "output");
    changed.putOutput(session.allocator, port) catch
        return common.commitFailed(session, "output");
    transaction.put(&changed) catch return common.commitFailed(session, "output");
    transaction.commit() catch return common.commitFailed(session, "output");
    return .ok;
}
