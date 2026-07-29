//! Every command available inside the lucia terminal, owned as one set.
//!
//! Dispatch matches the first word against each command's name or
//! alias, checks the argument count against the command's declared
//! count, and prints its usage on a mismatch.

const std = @import("std");
const command = @import("command.zig");

const Session = command.Session;
const Command = command.Command;
const Error = command.Error;
const Result = command.Result;

pub const table = [_]Command{
    @import("commands/new.zig").entry,
    @import("commands/select.zig").entry,
    @import("commands/show.zig").entry,
    @import("commands/rename.zig").entry,
    @import("commands/find.zig").entry,
    @import("commands/delete.zig").entry,
    @import("commands/input.zig").entry,
    @import("commands/output.zig").entry,
    @import("commands/move.zig").entry,
    @import("commands/drop.zig").entry,
    @import("commands/connect.zig").entry,
    @import("commands/disconnect.zig").entry,
    @import("commands/set.zig").entry,
    @import("commands/allow_read.zig").entry,
    @import("commands/eval.zig").entry,
    @import("commands/code.zig").entry,
    @import("commands/luce.zig").entry,
    @import("commands/pull.zig").entry,
    @import("commands/watch.zig").entry,
    @import("commands/unwatch.zig").entry,
    @import("commands/list.zig").entry,
    @import("commands/help.zig").entry,
    @import("commands/exit.zig").entry,
};

pub fn run(session: *Session, words: []const []const u8) Error!Result {
    for (&table) |*matched| {
        if (!std.mem.eql(u8, words[0], matched.name) and
            !std.mem.eql(u8, words[0], matched.alias))
        {
            continue;
        }
        const argument_count = words.len - 1;
        if (!acceptsArgumentCount(matched.*, argument_count)) {
            try session.err.print("usage: {s}\n", .{matched.usage});
            return .err;
        }
        return matched.run(session, words);
    }
    return .unknown;
}

fn acceptsArgumentCount(matched: Command, count: usize) bool {
    const maximum = matched.maximum_argument_count orelse matched.argument_count;
    return count >= matched.argument_count and count <= maximum;
}

test "commands accept exact or explicitly bounded arity" {
    const exact = Command{
        .name = "exact",
        .alias = "x",
        .argument_count = 1,
        .usage = "exact ARG",
        .run = undefined,
    };
    try std.testing.expect(!acceptsArgumentCount(exact, 0));
    try std.testing.expect(acceptsArgumentCount(exact, 1));
    try std.testing.expect(!acceptsArgumentCount(exact, 2));

    var bounded = exact;
    bounded.maximum_argument_count = 2;
    try std.testing.expect(acceptsArgumentCount(bounded, 1));
    try std.testing.expect(acceptsArgumentCount(bounded, 2));
    try std.testing.expect(!acceptsArgumentCount(bounded, 3));
}
