//! drop DIR NAME — remove a port from the selected texel.  An Output
//! Port with Fibers still bound to it is refused; disconnect the
//! consumers first.

const std = @import("std");
const loom = @import("loom");
const command = @import("../command.zig");
const common = @import("common.zig");

const Store = loom.store.Store;
const TexelId = loom.texel_id.TexelId;
const Session = command.Session;
const Error = command.Error;
const Result = command.Result;

pub const entry: command.Command = .{
    .name = "drop",
    .alias = "dr",
    .argument_count = 2,
    .usage = "drop DIR NAME            (dr)  remove a port from the selected texel",
    .run = run,
};

fn run(session: *Session, words: []const []const u8) Error!Result {
    const is_input = try common.parseDirection(session, words[1]) orelse return .err;
    if (!try common.selectedExists(session)) return .err;
    const port_name = words[2];
    const texel = session.store.get(session.selected).?;

    if (is_input) {
        if (!texel.hasInput(port_name)) {
            try session.err.print("loom: no input named {s}\n", .{port_name});
            return .err;
        }
    } else {
        if (!texel.hasOutput(port_name)) {
            try session.err.print("loom: no output named {s}\n", .{port_name});
            return .err;
        }
        if (outputConnected(session.store, session.selected, port_name)) {
            try session.err.print("loom: output {s} is still connected\n", .{port_name});
            return .err;
        }
    }

    var transaction = session.store.begin() catch return common.commitFailed(session, "drop");
    defer transaction.deinit();
    var changed = try common.cloneForEdit(session, &transaction, session.selected) orelse return .err;
    defer changed.deinit(session.allocator);
    const removed = if (is_input)
        changed.removeInput(session.allocator, port_name)
    else
        changed.removeOutput(session.allocator, port_name);
    if (!removed) return common.commitFailed(session, "drop");
    transaction.put(&changed) catch return common.commitFailed(session, "drop");
    transaction.commit() catch return common.commitFailed(session, "drop");
    return .ok;
}

/// True when any Input Port in the Fabric is bound to this output.
fn outputConnected(store: *const Store, id: TexelId, output_name: []const u8) bool {
    for (0..store.count()) |index| {
        const other = store.at(index).?;
        for (other.inputs.items) |input| {
            const binding = input.binding orelse continue;
            if (binding.source.eql(id) and std.mem.eql(u8, binding.output, output_name)) {
                return true;
            }
        }
    }
    return false;
}
