//! list — print every texel with its name, or - when it has none.  The
//! selected texel is marked with a star.

const loom = @import("loom");
const command = @import("../command.zig");
const common = @import("common.zig");

const TexelId = loom.texel_id.TexelId;
const Session = command.Session;
const Error = command.Error;
const Result = command.Result;

pub const entry: command.Command = .{
    .name = "list",
    .alias = "ls",
    .argument_count = 0,
    .usage = "list                     (ls)  list every texel",
    .run = run,
};

fn run(session: *Session, words: []const []const u8) Error!Result {
    _ = words;
    const palette = session.palette;
    for (0..session.store.count()) |index| {
        const texel = session.store.at(index).?;
        var buffer: [TexelId.text_size]u8 = undefined;
        try session.out.print("{s}{s}{s} {s}{s}{s}{s}\n", .{
            palette.sgr(.identity),
            texel.id.format(&buffer),
            palette.sgr(.reset),
            palette.sgr(.name),
            common.texelNameOf(texel) orelse "-",
            palette.sgr(.reset),
            if (texel.id.eql(session.selected)) " *" else "",
        });
    }
    return .ok;
}
