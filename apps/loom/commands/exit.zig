//! exit — leave the terminal.

const command = @import("../command.zig");

const Session = command.Session;
const Error = command.Error;
const Result = command.Result;

pub const entry: command.Command = .{
    .name = "exit",
    .alias = "q",
    .argument_count = 0,
    .usage = "exit                     (q)   leave the terminal",
    .run = run,
};

fn run(session: *Session, words: []const []const u8) Error!Result {
    _ = session;
    _ = words;
    return .exit;
}
