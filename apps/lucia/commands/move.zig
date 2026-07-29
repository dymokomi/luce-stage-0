//! move DIR OLD NEW — rename a port on the selected texel.  Renaming an
//! Output Port rewires every Fiber bound to it in the same commit, so
//! existing connections survive the new name.

const std = @import("std");
const loom = @import("loom");
const command = @import("../command.zig");
const common = @import("common.zig");

const InputPort = loom.texel.InputPort;
const OutputPort = loom.texel.OutputPort;
const Fiber = loom.texel.Fiber;
const Session = command.Session;
const Error = command.Error;
const Result = command.Result;

pub const entry: command.Command = .{
    .name = "move",
    .alias = "mv",
    .argument_count = 3,
    .usage = "move DIR OLD NEW         (mv)  rename a port on the selected texel",
    .run = run,
};

fn run(session: *Session, words: []const []const u8) Error!Result {
    const is_input = try common.parseDirection(session, words[1]) orelse return .err;
    if (!try common.selectedExists(session)) return .err;
    return if (is_input)
        moveInput(session, words[2], words[3])
    else
        moveOutput(session, words[2], words[3]);
}

fn moveInput(session: *Session, old_name: []const u8, new_name: []const u8) Error!Result {
    const allocator = session.allocator;
    const texel = session.store.get(session.selected).?;
    const port = texel.getInput(old_name) orelse {
        try session.err.print("lucia: no input named {s}\n", .{old_name});
        return .err;
    };
    if (texel.hasInput(new_name)) {
        try session.err.print("lucia: input {s} already exists\n", .{new_name});
        return .err;
    }

    var transaction = session.store.begin() catch return common.commitFailed(session, "move");
    defer transaction.deinit();
    var changed = try common.cloneForEdit(session, &transaction, session.selected) orelse return .err;
    defer changed.deinit(allocator);

    // The renamed port keeps its type and, when bound, its Fiber.
    var renamed = InputPort.init(allocator, new_name, port.declared) catch
        return common.commitFailed(session, "move");
    if (port.binding) |binding| {
        const carried = Fiber.init(allocator, binding.source, binding.output) catch {
            renamed.deinit(allocator);
            return common.commitFailed(session, "move");
        };
        renamed.bind(allocator, carried) catch {
            renamed.deinit(allocator);
            return common.commitFailed(session, "move");
        };
    }
    _ = changed.removeInput(allocator, old_name);
    changed.putInput(allocator, renamed) catch
        return common.commitFailed(session, "move");
    transaction.put(&changed) catch return common.commitFailed(session, "move");
    transaction.commit() catch return common.commitFailed(session, "move");
    return .ok;
}

fn moveOutput(session: *Session, old_name: []const u8, new_name: []const u8) Error!Result {
    const allocator = session.allocator;
    const texel = session.store.get(session.selected).?;
    const port = texel.getOutput(old_name) orelse {
        try session.err.print("lucia: no output named {s}\n", .{old_name});
        return .err;
    };
    if (texel.hasOutput(new_name)) {
        try session.err.print("lucia: output {s} already exists\n", .{new_name});
        return .err;
    }

    var transaction = session.store.begin() catch return common.commitFailed(session, "move");
    defer transaction.deinit();
    var changed = try common.cloneForEdit(session, &transaction, session.selected) orelse return .err;
    defer changed.deinit(allocator);

    // The renamed port keeps its type and its stored source value.
    var renamed = OutputPort.init(allocator, new_name, port.declared) catch
        return common.commitFailed(session, "move");
    if (port.source) |source| {
        const carried = source.clone(allocator) catch {
            renamed.deinit(allocator);
            return common.commitFailed(session, "move");
        };
        renamed.setSource(allocator, carried) catch {
            renamed.deinit(allocator);
            return common.commitFailed(session, "move");
        };
    }
    _ = changed.removeOutput(allocator, old_name);
    changed.putOutput(allocator, renamed) catch
        return common.commitFailed(session, "move");
    transaction.put(&changed) catch return common.commitFailed(session, "move");

    // Repoint every Fiber bound to the old output name, in the same
    // atomic commit.
    for (0..session.store.count()) |index| {
        const other = session.store.at(index).?;
        if (other.id.eql(session.selected)) continue;
        for (other.inputs.items) |input| {
            const binding = input.binding orelse continue;
            if (!binding.source.eql(session.selected)) continue;
            if (!std.mem.eql(u8, binding.output, old_name)) continue;
            transaction.connect(other.id, input.name, session.selected, new_name) catch
                return common.commitFailed(session, "move");
        }
    }
    transaction.commit() catch return common.commitFailed(session, "move");
    return .ok;
}
