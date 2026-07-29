//! Boundary texels — where the host enters the Fabric.
//!
//! A device pushes a new source value onto a boundary texel's Output
//! Ports through the store's volatile observe path, bumping revisions
//! and the logical generation without touching the volume.  Nothing
//! downstream recomputes until something demands it: push invalidates,
//! pull evaluates.  An observation becomes durable only when a later
//! commit snapshots it.
//!
//! keyboard offers line (text, the last line typed) and count (int).
//! mouse offers x, y (real) and button (int); it cannot fire while the
//! terminal reads whole lines from a tty, and waits for raw-mode input.

const std = @import("std");
const loom = @import("loom");
const common = @import("commands/common.zig");

const Allocator = std.mem.Allocator;
const Store = loom.store.Store;
const Transaction = loom.store.Transaction;
const Texel = loom.texel.Texel;
const OutputPort = loom.texel.OutputPort;
const TexelId = loom.texel_id.TexelId;
const Value = loom.value.Value;
const ValueType = loom.value.ValueType;

pub const keyboard_name = "keyboard";
pub const mouse_name = "mouse";

const BoundaryOutput = struct {
    name: []const u8,
    declared: ValueType,
};

const keyboard_outputs = [_]BoundaryOutput{
    .{ .name = "line", .declared = .text },
    .{ .name = "count", .declared = .int },
};

const mouse_outputs = [_]BoundaryOutput{
    .{ .name = "x", .declared = .real },
    .{ .name = "y", .declared = .real },
    .{ .name = "button", .declared = .int },
};

/// Create one boundary texel with typed, pre-set outputs.
fn makeBoundary(
    allocator: Allocator,
    io: std.Io,
    transaction: *Transaction,
    name: []const u8,
    outputs: []const BoundaryOutput,
) !void {
    var texel = Texel.init(TexelId.generate(io));
    defer texel.deinit(allocator);
    try common.setName(allocator, &texel, name);
    for (outputs) |output| {
        var port = try OutputPort.init(allocator, output.name, output.declared);
        errdefer port.deinit(allocator);
        const initial: Value = switch (output.declared) {
            .text => try Value.initText(allocator, ""),
            .int => .{ .int = 0 },
            else => .{ .real = 0.0 },
        };
        try port.setSource(allocator, initial);
        try texel.putOutput(allocator, port);
    }
    try transaction.put(&texel);
}

/// Create the boundary texels missing from this Fabric, in one commit.
pub fn ensureBoundary(allocator: Allocator, io: std.Io, store: *Store) !void {
    const keyboard = common.findNamed(store, keyboard_name) == null;
    const mouse = common.findNamed(store, mouse_name) == null;
    if (!keyboard and !mouse) return;

    var transaction = try store.begin();
    defer transaction.deinit();
    if (keyboard) try makeBoundary(allocator, io, &transaction, keyboard_name, &keyboard_outputs);
    if (mouse) try makeBoundary(allocator, io, &transaction, mouse_name, &mouse_outputs);
    try transaction.commit();
}

/// Record one keyboard interaction: the line just typed, and one more
/// count.  Best effort; a Fabric without the keyboard texel is left
/// alone.
pub fn observeKeyboard(allocator: Allocator, store: *Store, line: []const u8) !void {
    const id = common.findNamed(store, keyboard_name) orelse return;

    var counted: i64 = 0;
    if (store.get(id)) |texel| {
        if (texel.getOutput("count")) |port| {
            if (port.source) |source| {
                if (source.tag() == .int) counted = source.int;
            }
        }
    }

    try store.observe(id, "line", try Value.initText(allocator, line));
    try store.observe(id, "count", .{ .int = counted + 1 });
}
