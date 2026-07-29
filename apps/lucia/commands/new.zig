//! new NAME — create a texel named NAME, select it, and print its id.

const loom = @import("loom");
const command = @import("../command.zig");
const common = @import("common.zig");
const ops = @import("../ops.zig");

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
    const id = ops.createTexel(session.allocator, session.io, session.store, .{
        .name = words[1],
    }) catch |mistake| switch (mistake) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return common.commitFailed(session, "new"),
    };
    session.selected = id;
    var buffer: [TexelId.text_size]u8 = undefined;
    try session.out.print("{s}\n", .{id.format(&buffer)});
    return .ok;
}
