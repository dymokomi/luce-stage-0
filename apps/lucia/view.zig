//! Headless state transition boundary for raw-terminal Views.

const std = @import("std");

pub const Action = struct {
    key: []const u8 = "",
    text: []const u8 = "",
    rows: i64,
    cols: i64,
};

/// Plain interface text and terminal-relative cursor position.  Text
/// is borrowed from the presenter context until the next step.
pub const Frame = struct {
    interface: []const u8,
    cursor_row: i64,
    cursor_col: i64,
    quit: bool,
};

pub const EvaluateFn = *const fn (context: *anyopaque, action: Action) anyerror!Evaluation;
pub const SaveFn = *const fn (context: *anyopaque) anyerror!void;

pub const Evaluation = struct {
    frame: Frame,
    save: bool,
};

/// Generic presenter state.  A View adapter owns all carried frame
/// state; this boundary only sequences evaluation and host effects.
pub const Presenter = struct {
    context: *anyopaque,
    evaluateFn: EvaluateFn,
    saveFn: SaveFn,

    pub fn step(self: *Presenter, action: Action) !Frame {
        const evaluated = try self.evaluateFn(self.context, action);
        if (evaluated.save) try self.saveFn(self.context);
        return evaluated.frame;
    }
};

test "presenter evaluates headlessly and performs requested saves" {
    const Test = struct {
        steps: usize = 0,
        saves: usize = 0,

        fn evaluate(context: *anyopaque, action: Action) !Evaluation {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.steps += 1;
            return .{
                .frame = .{
                    .interface = action.text,
                    .cursor_row = 2,
                    .cursor_col = 3,
                    .quit = false,
                },
                .save = std.mem.eql(u8, action.key, "save"),
            };
        }

        fn save(context: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.saves += 1;
        }
    };

    var state: Test = .{};
    var presenter: Presenter = .{
        .context = &state,
        .evaluateFn = Test.evaluate,
        .saveFn = Test.save,
    };
    const frame = try presenter.step(.{
        .key = "save",
        .text = "plain",
        .rows = 24,
        .cols = 80,
    });
    try std.testing.expectEqualStrings("plain", frame.interface);
    try std.testing.expectEqual(@as(usize, 1), state.steps);
    try std.testing.expectEqual(@as(usize, 1), state.saves);
}
