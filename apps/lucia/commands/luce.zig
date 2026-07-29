//! luce ID|NAME — execute a texel's Luce code once, right now.
//!
//! Demand decides when ordinary evaluation happens; this command is
//! the direct lever: compile the texel's content against its ports,
//! resolve its bound inputs through the session spool, run it, and
//! print what it wrote.  Outputs are shown, not published — the
//! Fabric's values still come from demand — but fabric intents the
//! program computes do apply, which is how a template texel is fired
//! by hand as many times as needed.

const std = @import("std");
const loom = @import("loom");
const luce = @import("luce");
const command = @import("../command.zig");
const common = @import("common.zig");
const luce_service = @import("../luce_service.zig");

const Session = command.Session;
const Error = command.Error;
const Result = command.Result;

pub const entry: command.Command = .{
    .name = "luce",
    .alias = "lu",
    .argument_count = 1,
    .usage = "luce ID|NAME             (lu)  run a texel's luce code once, now",
    .run = run,
};

fn run(session: *Session, words: []const []const u8) Error!Result {
    const palette = session.palette;
    const id = try common.resolveTexel(session, words[1]) orelse return .err;
    const texel = session.store.get(id).?;

    if (texel.content == null) {
        try session.err.print("lucia: {s} has no luce source (use code)\n", .{words[1]});
        return .err;
    }
    if (try session.luce.check(texel)) |rendered| {
        defer session.allocator.free(rendered);
        try session.err.print("lucia: {s}luce compile failed\n{s}{s}", .{
            palette.sgr(.err),
            rendered,
            palette.sgr(.reset),
        });
        return .err;
    }
    const program = session.luce.cachedFor(texel) orelse return .err;

    var arena = std.heap.ArenaAllocator.init(session.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    // Resolve each program input through the spool.  Demand borrows
    // invalidate on the next demand, so every value is copied into the
    // run's arena immediately.
    const input_frame = try scratch.alloc(luce.backend.InputValue, program.inputs.len);
    for (program.inputs, input_frame) |port, *slot| {
        const declared = texel.getInput(port.name) orelse {
            slot.* = .unavailable;
            continue;
        };
        const binding = declared.binding orelse {
            slot.* = .unavailable;
            continue;
        };
        const outcome = try session.spool.demand(binding.source, binding.output);
        slot.* = switch (luce_service.LuceService.fromOutcome(outcome.*, port.declared)) {
            .unavailable => .unavailable,
            .value => |value| .{ .value = switch (value) {
                .string => |text| .{ .string = try scratch.dupe(u8, text) },
                .bytes => |bytes| .{ .bytes = try scratch.dupe(u8, bytes) },
                else => value,
            } },
        };
    }
    const output_frame = try scratch.alloc(?luce.backend.RuntimeValue, program.outputs.len);
    @memset(output_frame, null);

    const result = try luce.backend.evaluate(
        scratch,
        program,
        input_frame,
        output_frame,
        luce_service.budget,
    );
    switch (result) {
        .unavailable => {
            try session.out.print("{s}unavailable{s} (an input this program reads is not available)\n", .{
                palette.sgr(.unavailable),
                palette.sgr(.reset),
            });
            return .ok;
        },
        .trap => |trapped| {
            try session.err.print("lucia: {s}luce trap: {s}{s}\n", .{
                palette.sgr(.err),
                trapped.message,
                palette.sgr(.reset),
            });
            return .err;
        },
        .success => |intents| {
            for (program.outputs, output_frame) |port, written| {
                const value = written orelse continue;
                var converted = try luce_service.LuceService.toValue(session.allocator, value);
                defer converted.deinit(session.allocator);
                const rendered = try common.valueText(session.allocator, converted);
                defer session.allocator.free(rendered);
                try session.out.print("{s}{s}{s} {s}= {s}{s}\n", .{
                    palette.sgr(.port),
                    port.name,
                    palette.sgr(.reset),
                    palette.sgr(.value),
                    rendered,
                    palette.sgr(.reset),
                });
            }
            for (intents) |intent| {
                try session.luce.pending.append(
                    session.allocator,
                    try session.luce.copyIntent(intent),
                );
            }
            return .ok;
        },
    }
}
