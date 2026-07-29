//! eval NAME — assign a persisted evaluator to the selected texel.
//! The name must be one the terminal's registry actually offers.

const command = @import("../command.zig");
const common = @import("common.zig");
const evaluators = @import("../evaluators.zig");

const Session = command.Session;
const Error = command.Error;
const Result = command.Result;

pub const entry: command.Command = .{
    .name = "eval",
    .alias = "e",
    .argument_count = 1,
    .usage = "eval NAME                (e)   set the selected texel's evaluator",
    .run = run,
};

fn run(session: *Session, words: []const []const u8) Error!Result {
    if (!evaluators.knownEvaluator(words[1])) {
        try session.err.print("lucia: unknown evaluator {s} ({s})\n", .{
            words[1],
            evaluators.evaluator_names,
        });
        return .err;
    }
    if (!try common.selectedExists(session)) return .err;

    var transaction = session.store.begin() catch return common.commitFailed(session, "eval");
    defer transaction.deinit();
    var changed = try common.cloneForEdit(session, &transaction, session.selected) orelse return .err;
    defer changed.deinit(session.allocator);
    changed.setEvaluator(session.allocator, words[1]) catch
        return common.commitFailed(session, "eval");
    transaction.put(&changed) catch return common.commitFailed(session, "eval");
    transaction.commit() catch return common.commitFailed(session, "eval");
    return .ok;
}
