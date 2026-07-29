//! delete — remove the selected texel; refused while other texels
//! still reference it.  A successful delete clears the selection.

const command = @import("../command.zig");
const common = @import("common.zig");
const ops = @import("../ops.zig");

const Session = command.Session;
const Error = command.Error;
const Result = command.Result;

pub const entry: command.Command = .{
    .name = "delete",
    .alias = "rm",
    .argument_count = 0,
    .usage = "delete                   (rm)  delete the selected texel",
    .run = run,
};

fn run(session: *Session, words: []const []const u8) Error!Result {
    _ = words;
    if (!try common.selectedExists(session)) return .err;

    ops.removeTexel(session.store, session.selected) catch |mistake|
        switch (mistake) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return refused(session),
        };
    session.selected = .unset;
    return .ok;
}

fn refused(session: *Session) Error!Result {
    try session.err.print("lucia: delete failed (texel is still connected)\n", .{});
    return .err;
}
