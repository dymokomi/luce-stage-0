//! delete — remove the selected texel; refused while other texels
//! still reference it.  A successful delete clears the selection.

const command = @import("../command.zig");
const common = @import("common.zig");

const Session = command.Session;
const Error = command.Error;
const Result = command.Result;

pub const entry: command.Command = .{
    .name = "delete",
    .alias = "rm",
    .argument_count = 0,
    .usage = "delete                   (rm)  delete the selected texel",
    .run = run,
};

fn run(session: *Session, words: []const []const u8) Error!Result {
    _ = words;
    if (!try common.selectedExists(session)) return .err;

    var transaction = session.store.begin() catch return refused(session);
    defer transaction.deinit();
    transaction.remove(session.selected) catch return refused(session);
    transaction.commit() catch return refused(session);
    session.selected = .unset;
    return .ok;
}

fn refused(session: *Session) Error!Result {
    try session.err.print("lucia: delete failed (texel is still connected)\n", .{});
    return .err;
}
