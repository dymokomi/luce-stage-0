//! rename NAME — give the selected texel a new name; identity is
//! untouched.

const command = @import("../command.zig");
const common = @import("common.zig");
const ops = @import("../ops.zig");

const Session = command.Session;
const Error = command.Error;
const Result = command.Result;

pub const entry: command.Command = .{
    .name = "rename",
    .alias = "rn",
    .argument_count = 1,
    .usage = "rename NAME              (rn)  rename the selected texel",
    .run = run,
};

fn run(session: *Session, words: []const []const u8) Error!Result {
    if (!try common.selectedExists(session)) return .err;
    ops.rename(session.allocator, session.store, session.selected, words[1]) catch |mistake|
        switch (mistake) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return common.commitFailed(session, "rename"),
        };
    return .ok;
}
