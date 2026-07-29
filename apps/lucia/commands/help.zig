//! help — print the usage line of every command.

const command = @import("../command.zig");
const command_set = @import("../command_set.zig");

const Session = command.Session;
const Error = command.Error;
const Result = command.Result;

pub const entry: command.Command = .{
    .name = "help",
    .alias = "?",
    .argument_count = 0,
    .usage = "help                     (?)   show this list",
    .run = run,
};

fn run(session: *Session, words: []const []const u8) Error!Result {
    _ = words;
    try session.out.print("commands:\n", .{});
    for (command_set.table) |listed| {
        try session.out.print("  {s}\n", .{listed.usage});
    }
    try session.out.print(
        "\nTYPE: bool int real text bytes texel blob    DIR: in out\n",
        .{},
    );
    try session.out.print(
        "EVALUATORS: concat sum upper luce    BOUNDARY TEXELS: keyboard mouse\n",
        .{},
    );
    return .ok;
}
