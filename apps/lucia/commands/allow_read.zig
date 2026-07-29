//! allow-read DIRECTORY NAME — issue a volatile directory-read
//! capability as an ordinary Bytes Output Port in the Fabric.

const loom = @import("loom");
const command = @import("../command.zig");
const common = @import("common.zig");
const ops = @import("../ops.zig");

const TexelId = loom.texel_id.TexelId;
const Session = command.Session;
const Error = command.Error;
const Result = command.Result;

pub const entry: command.Command = .{
    .name = "allow-read",
    .alias = "ar",
    .argument_count = 2,
    .usage = "allow-read DIRECTORY NAME (ar) issue a session-only file capability texel",
    .run = run,
};

fn run(session: *Session, words: []const []const u8) Error!Result {
    var capability = session.files.issue(words[1]) catch |mistake| switch (mistake) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try session.err.print(
                "lucia: cannot grant read access to directory {s}\n",
                .{words[1]},
            );
            return .err;
        },
    };
    var granted = false;
    defer {
        if (!granted) _ = session.authority.revoke(capability);
        capability.deinit(session.allocator);
    }

    var encoded = loom.capability.encodeCapability(session.allocator, capability) catch
        return error.OutOfMemory;
    defer encoded.deinit(session.allocator);
    const id = ops.createTexel(session.allocator, session.io, session.store, .{
        .name = words[2],
        .outputs = &.{.{ .name = "capability", .declared = .bytes }},
        .sets = &.{.{ .output = "capability", .value = encoded }},
    }) catch |mistake| switch (mistake) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return common.commitFailed(session, "allow-read"),
    };
    granted = true;
    session.selected = id;

    var buffer: [TexelId.text_size]u8 = undefined;
    try session.out.print(
        "{s}\nread capability is volatile and valid only for this terminal session\n",
        .{id.format(&buffer)},
    );
    return .ok;
}
