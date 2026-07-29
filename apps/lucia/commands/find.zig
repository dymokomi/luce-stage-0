//! find TEXT — list every texel whose name contains TEXT.

const std = @import("std");
const loom = @import("loom");
const command = @import("../command.zig");
const common = @import("common.zig");

const TexelId = loom.texel_id.TexelId;
const Session = command.Session;
const Error = command.Error;
const Result = command.Result;

pub const entry: command.Command = .{
    .name = "find",
    .alias = "f",
    .argument_count = 1,
    .usage = "find TEXT                (f)   list texels whose name contains TEXT",
    .run = run,
};

fn run(session: *Session, words: []const []const u8) Error!Result {
    var matches: usize = 0;
    for (0..session.store.count()) |index| {
        const texel = session.store.at(index).?;
        const name = common.texelNameOf(texel) orelse continue;
        if (std.mem.indexOf(u8, name, words[1]) == null) continue;
        var buffer: [TexelId.text_size]u8 = undefined;
        try session.out.print("{s} {s}\n", .{ texel.id.format(&buffer), name });
        matches += 1;
    }
    if (matches == 0) {
        try session.out.print("no matches\n", .{});
    }
    return .ok;
}
