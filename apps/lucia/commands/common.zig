//! Shared helpers for terminal commands.

const std = @import("std");
const loom = @import("loom");
const color = @import("../color.zig");
const command = @import("../command.zig");

const Allocator = std.mem.Allocator;
const Store = loom.store.Store;
const Transaction = loom.store.Transaction;
const Texel = loom.texel.Texel;
const OutputPort = loom.texel.OutputPort;
const TexelId = loom.texel_id.TexelId;
const Value = loom.value.Value;
const ValueType = loom.value.ValueType;
const Outcome = loom.spool.Outcome;
const Session = command.Session;
const Error = command.Error;
const Result = command.Result;

// A texel's name is ordinary Fabric material: a text value offered on
// the "name" Output Port.  Identity never depends on it.
pub const name_port = "name";

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

/// Parse a port type name; reports the valid names on the error writer.
pub fn parseType(session: *Session, text: []const u8) Error!?ValueType {
    const Named = struct {
        name: []const u8,
        declared: ValueType,
    };
    const named = [_]Named{
        .{ .name = "bool", .declared = .boolean },
        .{ .name = "int", .declared = .int },
        .{ .name = "real", .declared = .real },
        .{ .name = "text", .declared = .text },
        .{ .name = "bytes", .declared = .bytes },
        .{ .name = "texel", .declared = .texel },
        .{ .name = "blob", .declared = .blob },
    };
    for (named) |candidate| {
        if (std.mem.eql(u8, text, candidate.name)) return candidate.declared;
    }
    try session.err.print(
        "lucia: unknown type {s} (bool int real text bytes texel blob)\n",
        .{text},
    );
    return null;
}

pub fn typeName(declared: ValueType) []const u8 {
    return switch (declared) {
        .none => "none",
        .boolean => "bool",
        .int => "int",
        .real => "real",
        .text => "text",
        .bytes => "bytes",
        .texel => "texel",
        .blob => "blob",
    };
}

/// Parse a port direction; reports the valid directions on the error
/// writer.  True means input.
pub fn parseDirection(session: *Session, text: []const u8) Error!?bool {
    if (std.mem.eql(u8, text, "in")) return true;
    if (std.mem.eql(u8, text, "out")) return false;
    try session.err.print("lucia: direction must be in or out\n", .{});
    return null;
}

/// Parse literal value text against a port's declared type; reports the
/// failure on the error writer.  Blobs cannot be written from the
/// terminal.  The caller owns the returned value.
pub fn parseValue(session: *Session, text: []const u8, declared: ValueType) Error!?Value {
    switch (declared) {
        .boolean => {
            if (std.mem.eql(u8, text, "true")) return .{ .boolean = true };
            if (std.mem.eql(u8, text, "false")) return .{ .boolean = false };
            try session.err.print("lucia: bool value must be true or false\n", .{});
            return null;
        },
        .int => {
            const number = std.fmt.parseInt(i64, text, 10) catch {
                try session.err.print("lucia: {s} is not an int\n", .{text});
                return null;
            };
            return .{ .int = number };
        },
        .real => {
            const number = std.fmt.parseFloat(f64, text) catch {
                try session.err.print("lucia: {s} is not a real\n", .{text});
                return null;
            };
            return .{ .real = number };
        },
        .text => return try Value.initText(session.allocator, text),
        .bytes => return try Value.initBytes(session.allocator, text),
        .texel => {
            const id = TexelId.parse(text) orelse {
                try session.err.print("lucia: {s} is not a texel id\n", .{text});
                return null;
            };
            if (id.isUnset()) {
                try session.err.print("lucia: {s} is not a texel id\n", .{text});
                return null;
            }
            return .{ .texel = id };
        },
        else => {
            try session.err.print(
                "lucia: cannot set a {s} value from the terminal\n",
                .{typeName(declared)},
            );
            return null;
        },
    }
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

/// Render a value for terminal display.  The caller owns the text.
pub fn valueText(allocator: Allocator, value: Value) Error![]u8 {
    return switch (value) {
        .none => try allocator.dupe(u8, "none"),
        .boolean => |flag| try allocator.dupe(u8, if (flag) "true" else "false"),
        .int => |number| try std.fmt.allocPrint(allocator, "{d}", .{number}),
        .real => |number| try std.fmt.allocPrint(allocator, "{d}", .{number}),
        .text => |text| try allocator.dupe(u8, text),
        .bytes => |bytes| try std.fmt.allocPrint(allocator, "{d} bytes", .{bytes.len}),
        .texel => |id| blk: {
            var buffer: [TexelId.text_size]u8 = undefined;
            break :blk try allocator.dupe(u8, id.format(&buffer));
        },
        .blob => try allocator.dupe(u8, "blob"),
    };
}

/// Render an outcome the way watch and pull display it.  The caller
/// owns the text.
pub fn outcomeText(allocator: Allocator, outcome: *const Outcome) Error![]u8 {
    switch (outcome.*) {
        .err => |message| return try std.mem.concat(allocator, u8, &.{ "error: ", message }),
        .unavailable => return try allocator.dupe(u8, "unavailable"),
        .available => |value| {
            const rendered = try valueText(allocator, value);
            defer allocator.free(rendered);
            return try std.mem.concat(allocator, u8, &.{ "= ", rendered });
        },
    }
}

// ---------------------------------------------------------------------------
// Texel lookups
// ---------------------------------------------------------------------------

/// A texel's name value, when it offers one.  Borrowed from the store;
/// valid until the next commit.
pub fn texelName(store: *const Store, id: TexelId) ?[]const u8 {
    const texel = store.get(id) orelse return null;
    return texelNameOf(texel);
}

pub fn texelNameOf(texel: *const Texel) ?[]const u8 {
    const output = texel.getOutput(name_port) orelse return null;
    const source = output.source orelse return null;
    if (source.tag() != .text) return null;
    return source.text;
}

/// Find a texel by exact name without reporting; boundary lookups are
/// quiet.  Null when no texel carries the name.
pub fn findNamed(store: *const Store, name: []const u8) ?TexelId {
    for (0..store.count()) |index| {
        const texel = store.at(index).?;
        const found = texelNameOf(texel) orelse continue;
        if (std.mem.eql(u8, found, name)) return texel.id;
    }
    return null;
}

/// Resolve id-or-name text to a texel: valid id text wins, otherwise
/// the argument must match exactly one texel's name.  Reports failures
/// on the error writer.
pub fn resolveTexel(session: *Session, text: []const u8) Error!?TexelId {
    if (TexelId.parse(text)) |id| {
        if (!id.isUnset() and session.store.has(id)) return id;
    }
    var matches: usize = 0;
    var found: TexelId = .unset;
    for (0..session.store.count()) |index| {
        const texel = session.store.at(index).?;
        const name = texelNameOf(texel) orelse continue;
        if (std.mem.eql(u8, name, text)) {
            found = texel.id;
            matches += 1;
        }
    }
    if (matches == 1) return found;
    if (matches == 0) {
        try session.err.print("lucia: no texel named {s}\n", .{text});
    } else {
        try session.err.print("lucia: {d} texels named {s} (use the id)\n", .{ matches, text });
    }
    return null;
}

/// Reports a missing selection on the error writer.
pub fn selectedExists(session: *Session) Error!bool {
    if (!session.hasSelection()) {
        try session.err.print("lucia: no texel selected (try select ID)\n", .{});
        return false;
    }
    if (!session.store.has(session.selected)) {
        try session.err.print("lucia: selected texel no longer exists\n", .{});
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Editing
// ---------------------------------------------------------------------------

/// Give the texel its name value: the name output holds a text source.
pub fn setName(allocator: Allocator, texel: *Texel, name: []const u8) !void {
    var output = try OutputPort.init(allocator, name_port, .text);
    errdefer output.deinit(allocator);
    try output.setSource(allocator, try Value.initText(allocator, name));
    try texel.putOutput(allocator, output);
}

/// A private working copy of one texel inside an open transaction,
/// ready to mutate and put back.
pub fn cloneForEdit(session: *Session, transaction: *Transaction, id: TexelId) Error!?Texel {
    const current = transaction.get(id) orelse {
        try session.err.print("lucia: texel no longer exists\n", .{});
        return null;
    };
    return try current.clone(session.allocator);
}

pub fn commitFailed(session: *Session, what: []const u8) Error!Result {
    try session.err.print("lucia: {s} commit failed\n", .{what});
    return .err;
}

// ---------------------------------------------------------------------------
// Display
// ---------------------------------------------------------------------------

/// Short display label for a texel: its name, or the id's first
/// characters.  The caller owns the text.
pub fn texelLabel(allocator: Allocator, store: *const Store, id: TexelId) Error![]u8 {
    if (texelName(store, id)) |name| return try allocator.dupe(u8, name);
    var buffer: [TexelId.text_size]u8 = undefined;
    return try allocator.dupe(u8, id.format(&buffer)[0..8]);
}

/// Print one endpoint outcome as label.output = value, colored by how
/// the outcome went.
pub fn printOutcome(
    session: *Session,
    texel: TexelId,
    output: []const u8,
    outcome: *const Outcome,
) Error!void {
    const label = try texelLabel(session.allocator, session.store, texel);
    defer session.allocator.free(label);
    const rendered = try outcomeText(session.allocator, outcome);
    defer session.allocator.free(rendered);
    const palette = session.palette;
    const style: color.Style = switch (outcome.*) {
        .available => .value,
        .unavailable => .unavailable,
        .err => .err,
    };
    try session.out.print("{s}{s}.{s}{s} {s}{s}{s}\n", .{
        palette.sgr(.name),
        label,
        output,
        palette.sgr(.reset),
        palette.sgr(style),
        rendered,
        palette.sgr(.reset),
    });
}
