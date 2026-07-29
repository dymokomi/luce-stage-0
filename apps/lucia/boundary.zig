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
const ops = @import("ops.zig");
const common = @import("commands/common.zig");

const Allocator = std.mem.Allocator;
const Store = loom.store.Store;
const Value = loom.value.Value;

pub const keyboard_name = "keyboard";
pub const mouse_name = "mouse";

/// Create the boundary texels missing from this Fabric, one create
/// each, through the same operations everything else uses.
pub fn ensureBoundary(allocator: Allocator, io: std.Io, store: *Store) !void {
    if (common.findNamed(store, keyboard_name) == null) {
        var empty_line = try Value.initText(allocator, "");
        defer empty_line.deinit(allocator);
        _ = try ops.createTexel(allocator, io, store, .{
            .name = keyboard_name,
            .outputs = &.{
                .{ .name = "line", .declared = .text },
                .{ .name = "count", .declared = .int },
            },
            .sets = &.{
                .{ .output = "line", .value = empty_line },
                .{ .output = "count", .value = .{ .int = 0 } },
            },
        });
    }
    if (common.findNamed(store, mouse_name) == null) {
        _ = try ops.createTexel(allocator, io, store, .{
            .name = mouse_name,
            .outputs = &.{
                .{ .name = "x", .declared = .real },
                .{ .name = "y", .declared = .real },
                .{ .name = "button", .declared = .int },
            },
            .sets = &.{
                .{ .output = "x", .value = .{ .real = 0.0 } },
                .{ .output = "y", .value = .{ .real = 0.0 } },
                .{ .output = "button", .value = .{ .int = 0 } },
            },
        });
    }
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
