//! set NAME VALUE — set a source value on the selected texel's Output
//! Port NAME, parsed against the port's declared type.

const command = @import("../command.zig");
const common = @import("common.zig");

const Session = command.Session;
const Error = command.Error;
const Result = command.Result;

pub const entry: command.Command = .{
    .name = "set",
    .alias = "se",
    .argument_count = 2,
    .usage = "set NAME VALUE           (se)  set a source value on a selected output",
    .run = run,
};

fn run(session: *Session, words: []const []const u8) Error!Result {
    if (!try common.selectedExists(session)) return .err;
    const port = session.store.get(session.selected).?.getOutput(words[1]) orelse {
        try session.err.print("lucia: no output named {s}\n", .{words[1]});
        return .err;
    };
    var value = try common.parseValue(session, words[2], port.declared) orelse return .err;
    var value_owned = true;
    defer if (value_owned) value.deinit(session.allocator);

    var transaction = session.store.begin() catch return common.commitFailed(session, "set");
    defer transaction.deinit();
    var changed = try common.cloneForEdit(session, &transaction, session.selected) orelse return .err;
    defer changed.deinit(session.allocator);
    const output = changed.mutableOutput(words[1]) orelse
        return common.commitFailed(session, "set");
    output.setSource(session.allocator, value) catch
        return common.commitFailed(session, "set");
    value_owned = false;
    transaction.put(&changed) catch return common.commitFailed(session, "set");
    transaction.commit() catch return common.commitFailed(session, "set");
    return .ok;
}
