//! input NAME TYPE — add a typed Input Port to the selected texel.

const loom = @import("loom");
const command = @import("../command.zig");
const common = @import("common.zig");

const InputPort = loom.texel.InputPort;
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
    if (session.store.get(session.selected).?.hasInput(words[1])) {
        try session.err.print("lucia: input {s} already exists\n", .{words[1]});
        return .err;
    }

    var transaction = session.store.begin() catch return common.commitFailed(session, "input");
    defer transaction.deinit();
    var changed = try common.cloneForEdit(session, &transaction, session.selected) orelse return .err;
    defer changed.deinit(session.allocator);
    const port = InputPort.init(session.allocator, words[1], declared) catch
        return common.commitFailed(session, "input");
    changed.putInput(session.allocator, port) catch
        return common.commitFailed(session, "input");
    transaction.put(&changed) catch return common.commitFailed(session, "input");
    transaction.commit() catch return common.commitFailed(session, "input");
    return .ok;
}
