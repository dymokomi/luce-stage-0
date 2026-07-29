//! select ID|NAME — make one texel active.  An argument that is not an
//! id is looked up as an exact name; the match must be unique.

const loom = @import("loom");
const command = @import("../command.zig");
const common = @import("common.zig");

const TexelId = loom.texel_id.TexelId;
const Session = command.Session;
const Error = command.Error;
const Result = command.Result;

pub const entry: command.Command = .{
    .name = "select",
    .alias = "s",
    .argument_count = 1,
    .usage = "select ID|NAME           (s)   select the texel to work on",
    .run = run,
};

fn run(session: *Session, words: []const []const u8) Error!Result {
    const id = try common.resolveTexel(session, words[1]) orelse return .err;
    session.selected = id;
    var buffer: [TexelId.text_size]u8 = undefined;
    try session.out.print("{s}\n", .{id.format(&buffer)});
    return .ok;
}
