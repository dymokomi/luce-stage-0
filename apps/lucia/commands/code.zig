//! code — write Luce source into the selected texel.
//!
//! Switches the terminal into collect mode: following lines accumulate
//! verbatim until a line holding a single "." commits them as the
//! texel's content and reports compile diagnostics against the
//! texel's current ports.  Pair with eval luce to make the texel
//! compute.

const command = @import("../command.zig");
const common = @import("common.zig");

const Session = command.Session;
const Error = command.Error;
const Result = command.Result;

pub const entry: command.Command = .{
    .name = "code",
    .alias = "cd",
    .argument_count = 0,
    .usage = "code                     (cd)  write luce source into the selected texel",
    .run = run,
};

fn run(session: *Session, words: []const []const u8) Error!Result {
    _ = words;
    if (!try common.selectedExists(session)) return .err;
    session.collecting = .{ .texel = session.selected };
    try session.out.print("enter luce source; finish with a single .\n", .{});
    return .ok;
}
