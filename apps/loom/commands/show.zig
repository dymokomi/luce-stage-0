//! show — print the selected texel: identity, name, and every typed
//! port with its binding or source state.

const loom = @import("loom");
const command = @import("../command.zig");
const common = @import("common.zig");

const TexelId = loom.texel_id.TexelId;
const Session = command.Session;
const Error = command.Error;
const Result = command.Result;

pub const entry: command.Command = .{
    .name = "show",
    .alias = "sh",
    .argument_count = 0,
    .usage = "show                     (sh)  show the selected texel and its ports",
    .run = run,
};

fn run(session: *Session, words: []const []const u8) Error!Result {
    _ = words;
    if (!try common.selectedExists(session)) return .err;
    const texel = session.store.get(session.selected).?;

    var buffer: [TexelId.text_size]u8 = undefined;
    try session.out.print("id: {s}\n", .{texel.id.format(&buffer)});
    try session.out.print("name: {s}\n", .{common.texelNameOf(texel) orelse "-"});
    try session.out.print("revision: {d}\n", .{texel.revision});
    const evaluator = texel.evaluatorName();
    try session.out.print("evaluator: {s}\n", .{if (evaluator.len == 0) "-" else evaluator});

    for (texel.inputs.items) |input| {
        try session.out.print("input {s} {s}", .{ input.name, common.typeName(input.declared) });
        if (input.binding) |binding| {
            try session.out.print(" <- {s} {s}", .{ binding.source.format(&buffer), binding.output });
        }
        try session.out.print("\n", .{});
    }
    for (texel.outputs.items) |output| {
        try session.out.print("output {s} {s} source={s} revision={d}\n", .{
            output.name,
            common.typeName(output.declared),
            if (output.source != null) "yes" else "no",
            output.revision,
        });
    }
    return .ok;
}
