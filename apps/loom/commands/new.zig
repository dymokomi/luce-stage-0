//! new NAME — create a texel named NAME, select it, and print its id.

const std = @import("std");
const loom = @import("loom");
const command = @import("../command.zig");
const common = @import("common.zig");

const Texel = loom.texel.Texel;
const TexelId = loom.texel_id.TexelId;
const Session = command.Session;
const Error = command.Error;
const Result = command.Result;

pub const entry: command.Command = .{
    .name = "new",
    .alias = "n",
    .argument_count = 1,
    .usage = "new NAME                 (n)   create a texel, select it, and print its id",
    .run = run,
};

fn run(session: *Session, words: []const []const u8) Error!Result {
    var transaction = session.store.begin() catch return common.commitFailed(session, "new");
    defer transaction.deinit();

    var texel = Texel.init(TexelId.generate(session.io));
    defer texel.deinit(session.allocator);
    common.setName(session.allocator, &texel, words[1]) catch
        return common.commitFailed(session, "new");
    transaction.put(&texel) catch return common.commitFailed(session, "new");
    transaction.commit() catch return common.commitFailed(session, "new");

    session.selected = texel.id;
    var buffer: [TexelId.text_size]u8 = undefined;
    try session.out.print("{s}\n", .{texel.id.format(&buffer)});
    return .ok;
}
