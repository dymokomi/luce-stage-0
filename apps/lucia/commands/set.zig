//! set NAME VALUE — set a source value on the selected texel's Output
//! Port NAME, parsed against the port's declared type.

const command = @import("../command.zig");
const common = @import("common.zig");
const ops = @import("../ops.zig");

const Session = command.Session;
const Error = command.Error;
const Result = command.Result;

pub const entry: command.Command = .{
    .name = "set",
    .alias = "se",
    .argument_count = 2,
    .usage = "set NAME VALUE           (se)  set a source value on a selected output",
    .run = run,
};

fn run(session: *Session, words: []const []const u8) Error!Result {
    if (!try common.selectedExists(session)) return .err;
    const port = session.store.get(session.selected).?.getOutput(words[1]) orelse {
        try session.err.print("lucia: no output named {s}\n", .{words[1]});
        return .err;
    };
    const value = try common.parseValue(session, words[2], port.declared) orelse return .err;
    ops.setSource(session.allocator, session.store, session.selected, words[1], value) catch |mistake|
        switch (mistake) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return common.commitFailed(session, "set"),
        };
    return .ok;
}
