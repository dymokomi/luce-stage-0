//! View evaluators — pure text renderers for View Texels.
//!
//! A View is an ordinary Texel whose computation produces an interface:
//! these evaluators read the View's text inputs (in the texel's
//! name-sorted port order) and render the `interface` output.  Declared
//! outputs they do not produce fall back to their stored sources — the
//! same passthrough convention the C border documents — so a name port
//! can ride beside the rendered interface.

const std = @import("std");
const texel_mod = @import("../fabric/texel.zig");
const texel_id = @import("../fabric/texel_id.zig");
const value_mod = @import("../fabric/value.zig");
const spool_mod = @import("../evaluation/spool.zig");

const Allocator = std.mem.Allocator;
const Texel = texel_mod.Texel;
const InputPort = texel_mod.InputPort;
const OutputPort = texel_mod.OutputPort;
const TexelId = texel_id.TexelId;
const Value = value_mod.Value;
const Evaluator = spool_mod.Evaluator;
const Outcome = spool_mod.Outcome;
const OutcomeMap = spool_mod.OutcomeMap;
const Error = spool_mod.Error;

pub const prose_view_evaluator = "view.prose";
pub const table_view_evaluator = "view.table";
pub const interface_output = "interface";

// ---------------------------------------------------------------------------
// Text helpers
// ---------------------------------------------------------------------------

/// Collapse whitespace runs into single spaces and trim the ends, so a
/// View renders source text as one flowing line.
fn flowingText(allocator: Allocator, text: []const u8) Error![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var spacing = false;
    for (text) |character| {
        switch (character) {
            ' ', '\t', '\n', '\r' => spacing = result.items.len != 0,
            else => {
                if (spacing) {
                    try result.append(allocator, ' ');
                    spacing = false;
                }
                try result.append(allocator, character);
            },
        }
    }
    return result.toOwnedSlice(allocator);
}

/// The flowing text of one input outcome, or null when the outcome is
/// not an available text value.
fn availableText(allocator: Allocator, outcome: ?Outcome) Error!?[]u8 {
    const present = outcome orelse return null;
    if (present != .available or present.available.tag() != .text) return null;
    return try flowingText(allocator, present.available.text);
}

fn appendRepeated(list: *std.ArrayList(u8), allocator: Allocator, character: u8, count: usize) Error!void {
    try list.appendNTimes(allocator, character, count);
}

/// Declared outputs the renderer did not produce fall back to their
/// stored sources; outputs with no source stay absent (and the Spool
/// reports the omission).
fn passthrough(allocator: Allocator, view: *const Texel, outputs: *OutcomeMap) Error!void {
    for (view.outputs.items) |port| {
        if (outputs.contains(port.name)) continue;
        const source = port.source orelse continue;
        try outputs.put(allocator, port.name, .{ .available = try source.clone(allocator) });
    }
}

fn emitUnavailable(allocator: Allocator, view: *const Texel, outputs: *OutcomeMap) Error!void {
    try outputs.put(allocator, interface_output, .unavailable);
    try passthrough(allocator, view, outputs);
}

// ---------------------------------------------------------------------------
// ProseViewEvaluator
// ---------------------------------------------------------------------------
//
// Renders every text input as "name: text" paragraphs, in the texel's
// name-sorted input order.
//
pub const ProseViewEvaluator = struct {
    pub fn evaluator(self: *ProseViewEvaluator) Evaluator {
        return .{ .context = self, .evaluateFn = run };
    }

    fn run(
        context: *anyopaque,
        allocator: Allocator,
        view: *const Texel,
        inputs: *const OutcomeMap,
        outputs: *OutcomeMap,
    ) Error!void {
        _ = context;
        var rendered: std.ArrayList(u8) = .empty;
        defer rendered.deinit(allocator);

        for (view.inputs.items) |input| {
            const text = try availableText(allocator, inputs.get(input.name)) orelse
                return emitUnavailable(allocator, view, outputs);
            defer allocator.free(text);
            if (rendered.items.len != 0) try rendered.appendSlice(allocator, "\n\n");
            try rendered.appendSlice(allocator, input.name);
            try rendered.appendSlice(allocator, ": ");
            try rendered.appendSlice(allocator, text);
        }

        const owned = try rendered.toOwnedSlice(allocator);
        try outputs.put(allocator, interface_output, .{ .available = .{ .text = owned } });
        try passthrough(allocator, view, outputs);
    }
};

// ---------------------------------------------------------------------------
// TableViewEvaluator
// ---------------------------------------------------------------------------
//
// Renders the text inputs as a bordered ASCII Field/Value table, in the
// texel's name-sorted input order.
//
pub const TableViewEvaluator = struct {
    pub fn evaluator(self: *TableViewEvaluator) Evaluator {
        return .{ .context = self, .evaluateFn = run };
    }

    fn run(
        context: *anyopaque,
        allocator: Allocator,
        view: *const Texel,
        inputs: *const OutcomeMap,
        outputs: *OutcomeMap,
    ) Error!void {
        _ = context;
        var name_width: usize = 5;
        var value_width: usize = 5;
        for (view.inputs.items) |input| {
            const text = try availableText(allocator, inputs.get(input.name)) orelse
                return emitUnavailable(allocator, view, outputs);
            defer allocator.free(text);
            name_width = @max(name_width, input.name.len);
            value_width = @max(value_width, text.len);
        }

        var rendered: std.ArrayList(u8) = .empty;
        defer rendered.deinit(allocator);

        try appendBorder(&rendered, allocator, name_width, value_width);
        try appendRow(&rendered, allocator, "Field", "Value", name_width, value_width);
        try appendBorder(&rendered, allocator, name_width, value_width);
        for (view.inputs.items) |input| {
            const text = (try availableText(allocator, inputs.get(input.name))).?;
            defer allocator.free(text);
            try appendRow(&rendered, allocator, input.name, text, name_width, value_width);
        }
        try appendBorder(&rendered, allocator, name_width, value_width);
        _ = rendered.pop(); // final border carries no trailing newline

        const owned = try rendered.toOwnedSlice(allocator);
        try outputs.put(allocator, interface_output, .{ .available = .{ .text = owned } });
        try passthrough(allocator, view, outputs);
    }

    fn appendBorder(list: *std.ArrayList(u8), allocator: Allocator, name_width: usize, value_width: usize) Error!void {
        try list.append(allocator, '+');
        try appendRepeated(list, allocator, '-', name_width + 2);
        try list.append(allocator, '+');
        try appendRepeated(list, allocator, '-', value_width + 2);
        try list.appendSlice(allocator, "+\n");
    }

    fn appendRow(
        list: *std.ArrayList(u8),
        allocator: Allocator,
        name: []const u8,
        text: []const u8,
        name_width: usize,
        value_width: usize,
    ) Error!void {
        try list.appendSlice(allocator, "| ");
        try list.appendSlice(allocator, name);
        try appendRepeated(list, allocator, ' ', name_width - name.len);
        try list.appendSlice(allocator, " | ");
        try list.appendSlice(allocator, text);
        try appendRepeated(list, allocator, ' ', value_width - text.len);
        try list.appendSlice(allocator, " |\n");
    }
};

// ---------------------------------------------------------------------------
// View construction
// ---------------------------------------------------------------------------

pub const MakeError = error{ OutOfMemory, UnsetId, EmptyName, InvalidPort };

fn makeView(
    allocator: Allocator,
    id: TexelId,
    evaluator_name: []const u8,
    input_names: []const []const u8,
) MakeError!Texel {
    if (id.isUnset()) return error.UnsetId;

    var view = Texel.init(id);
    errdefer view.deinit(allocator);
    view.setEvaluator(allocator, evaluator_name) catch |mistake| switch (mistake) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.EmptyName,
    };
    try putOutput(allocator, &view, interface_output);
    for (input_names) |name| {
        if (name.len == 0) return error.EmptyName;
        var port = try InputPort.init(allocator, name, .text);
        errdefer port.deinit(allocator);
        view.putInput(allocator, port) catch |mistake| switch (mistake) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidPort,
        };
    }
    return view;
}

fn putOutput(allocator: Allocator, view: *Texel, name: []const u8) MakeError!void {
    var port = try OutputPort.init(allocator, name, .text);
    errdefer port.deinit(allocator);
    view.putOutput(allocator, port) catch |mistake| switch (mistake) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPort,
    };
}

/// A prose View over the named text inputs.  The caller owns the result.
pub fn makeProseView(allocator: Allocator, id: TexelId, input_names: []const []const u8) MakeError!Texel {
    return makeView(allocator, id, prose_view_evaluator, input_names);
}

/// A table View over the named text inputs.  The caller owns the result.
pub fn makeTableView(allocator: Allocator, id: TexelId, input_names: []const []const u8) MakeError!Texel {
    return makeView(allocator, id, table_view_evaluator, input_names);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "flowing text collapses whitespace and trims the ends" {
    const allocator = testing.allocator;
    const flowed = try flowingText(allocator, "  alpha\n\tbeta  gamma \r\n");
    defer allocator.free(flowed);
    try testing.expectEqualStrings("alpha beta gamma", flowed);
}

test "make view declares the interface output and text inputs" {
    const allocator = testing.allocator;
    var view = try makeProseView(allocator, TexelId.generate(testing.io), &.{ "body", "title" });
    defer view.deinit(allocator);

    try testing.expectEqualStrings(prose_view_evaluator, view.evaluatorName());
    try testing.expect(view.hasOutput(interface_output));
    try testing.expectEqual(@as(usize, 2), view.inputCount());
    try testing.expectError(error.UnsetId, makeTableView(allocator, .unset, &.{"body"}));
    try testing.expectError(error.EmptyName, makeTableView(allocator, TexelId.generate(testing.io), &.{""}));
}
