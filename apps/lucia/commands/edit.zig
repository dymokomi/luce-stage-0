//! edit — open the selected texel in the full-screen editor.
//!
//! The editor works on a private clone: the ports pane edits inputs,
//! outputs, types, and output source values; the code pane edits the
//! Luce content with line numbers, syntax highlighting, and
//! auto-indent.  Ctrl+S commits ports and content as one transaction
//! (with compile diagnostics in the status line); Ctrl+Q leaves
//! without saving.  Needs an interactive terminal.

const std = @import("std");
const loom = @import("loom");
const command = @import("../command.zig");
const common = @import("common.zig");
const editor_mod = @import("../editor/editor.zig");
const screen = @import("../editor/screen.zig");

const Session = command.Session;
const Error = command.Error;
const Result = command.Result;

pub const entry: command.Command = .{
    .name = "edit",
    .alias = "ed",
    .argument_count = 0,
    .usage = "edit                     (ed)  open the selected texel in the editor",
    .run = run,
};

const Host = struct {
    session: *Session,
};

fn run(session: *Session, words: []const []const u8) Error!Result {
    _ = words;
    if (!try common.selectedExists(session)) return .err;
    const interactive = std.Io.File.stdin().isTty(session.io) catch false;
    if (!interactive) {
        try session.err.print("lucia: edit needs an interactive terminal\n", .{});
        return .err;
    }

    const current = session.store.get(session.selected).?;
    const clone = try current.clone(session.allocator);
    const label = try common.texelLabel(session.allocator, session.store, session.selected);
    defer session.allocator.free(label);

    var editor = editor_mod.Editor.init(session.allocator, session.palette, label, clone) catch |mistake| {
        var owned = clone;
        owned.deinit(session.allocator);
        return mistake;
    };
    defer editor.deinit();

    var host: Host = .{ .session = session };
    screen.run(session.io, &editor, commit, &host) catch {
        try session.err.print("lucia: the editor could not run on this terminal\n", .{});
        return .err;
    };
    try session.out.print("{s}\n", .{editor.status.items});
    return .ok;
}

/// Commit the editor's clone — ports and content — as one transaction,
/// then report compile diagnostics against the new state.
fn commit(context: *anyopaque, editor: *editor_mod.Editor) anyerror!void {
    const host: *Host = @ptrCast(@alignCast(context));
    const session = host.session;
    const allocator = session.allocator;

    const text = try editor.buffer.text();
    defer allocator.free(text);
    if (std.mem.trim(u8, text, " \n").len == 0) {
        editor.texel.clearContent(allocator);
    } else {
        try editor.texel.setContent(allocator, try loom.value.Value.initText(allocator, text));
    }

    var transaction = session.store.begin() catch {
        try editor.reportSave("save failed: cannot begin a transaction");
        return;
    };
    defer transaction.deinit();
    transaction.put(&editor.texel) catch {
        try editor.reportSave("save failed: the texel no longer fits the fabric");
        return;
    };
    transaction.commit() catch {
        try editor.reportSave("save failed: commit refused (check connected fibers)");
        return;
    };
    editor.buffer.changed = false;

    // Diagnostics against the committed state, straight into the
    // status line.
    const committed = session.store.get(editor.texel.id) orelse {
        try editor.reportSave("saved");
        return;
    };
    if (committed.evaluatorName().len != 0 and committed.content != null) {
        if (try session.luce.check(committed)) |rendered| {
            defer allocator.free(rendered);
            const first_line_end = std.mem.indexOfScalar(u8, rendered, '\n') orelse rendered.len;
            const message = try std.fmt.allocPrint(allocator, "saved; luce: {s}", .{
                rendered[0..first_line_end],
            });
            defer allocator.free(message);
            try editor.reportSave(message);
            return;
        }
    }
    try editor.reportSave("saved");
}
