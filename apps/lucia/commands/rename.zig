//! rename NAME — give the selected texel a new name; identity is
//! untouched.

const command = @import("../command.zig");
const common = @import("common.zig");

const Session = command.Session;
const Error = command.Error;
const Result = command.Result;

pub const entry: command.Command = .{
    .name = "rename",
    .alias = "rn",
    .argument_count = 1,
    .usage = "rename NAME              (rn)  rename the selected texel",
    .run = run,
};

fn run(session: *Session, words: []const []const u8) Error!Result {
    if (!try common.selectedExists(session)) return .err;

    var transaction = session.store.begin() catch return common.commitFailed(session, "rename");
    defer transaction.deinit();
    var changed = try common.cloneForEdit(session, &transaction, session.selected) orelse return .err;
    defer changed.deinit(session.allocator);
    common.setName(session.allocator, &changed, words[1]) catch
        return common.commitFailed(session, "rename");
    transaction.put(&changed) catch return common.commitFailed(session, "rename");
    transaction.commit() catch return common.commitFailed(session, "rename");
    return .ok;
}
