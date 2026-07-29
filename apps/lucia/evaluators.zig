//! Terminal evaluators — the pure computations eval can assign.
//!
//! Each reads its inputs by port name and emits one "value" output; a
//! missing or unavailable input emits unavailable rather than an error.
//! Declared outputs a computation does not emit fall back to their
//! stored sources (the passthrough convention), which is how the name
//! port rides beside computed outputs.

const std = @import("std");
const loom = @import("loom");

const Allocator = std.mem.Allocator;
const Texel = loom.texel.Texel;
const Value = loom.value.Value;
const Evaluator = loom.spool.Evaluator;
const Registry = loom.spool.Registry;
const Outcome = loom.spool.Outcome;
const OutcomeMap = loom.spool.OutcomeMap;
const Error = loom.spool.Error;

pub const evaluator_names = "concat sum upper";

pub fn knownEvaluator(name: []const u8) bool {
    return std.mem.eql(u8, name, "concat") or std.mem.eql(u8, name, "sum") or
        std.mem.eql(u8, name, "upper");
}

/// Register every terminal evaluator under its persisted name.
pub fn registerAll(registry: *Registry) !void {
    try registry.put("concat", .{ .context = &stateless, .evaluateFn = concat });
    try registry.put("sum", .{ .context = &stateless, .evaluateFn = sum });
    try registry.put("upper", .{ .context = &stateless, .evaluateFn = upper });
}

var stateless: u8 = 0;

// ---------------------------------------------------------------------------
// Emission helpers
// ---------------------------------------------------------------------------

/// Declared outputs the computation did not emit fall back to their
/// stored sources; outputs with no source stay absent (and the Spool
/// reports the omission).
fn passthrough(allocator: Allocator, texel: *const Texel, outputs: *OutcomeMap) Error!void {
    for (texel.outputs.items) |port| {
        if (outputs.contains(port.name)) continue;
        const source = port.source orelse continue;
        try outputs.put(allocator, port.name, .{ .available = try source.clone(allocator) });
    }
}

fn emit(
    allocator: Allocator,
    texel: *const Texel,
    outputs: *OutcomeMap,
    outcome: Outcome,
) Error!void {
    try outputs.put(allocator, "value", outcome);
    try passthrough(allocator, texel, outputs);
}

fn availableText(inputs: *const OutcomeMap, name: []const u8) ?[]const u8 {
    const outcome = inputs.get(name) orelse return null;
    if (outcome != .available or outcome.available.tag() != .text) return null;
    return outcome.available.text;
}

fn availableInt(inputs: *const OutcomeMap, name: []const u8) ?i64 {
    const outcome = inputs.get(name) orelse return null;
    if (outcome != .available or outcome.available.tag() != .int) return null;
    return outcome.available.int;
}

// ---------------------------------------------------------------------------
// Evaluators
// ---------------------------------------------------------------------------

/// concat: left text + right text -> value text.
fn concat(
    context: *anyopaque,
    allocator: Allocator,
    texel: *const Texel,
    inputs: *const OutcomeMap,
    outputs: *OutcomeMap,
) Error!void {
    _ = context;
    const left = availableText(inputs, "left") orelse
        return emit(allocator, texel, outputs, .unavailable);
    const right = availableText(inputs, "right") orelse
        return emit(allocator, texel, outputs, .unavailable);
    const joined = try std.mem.concat(allocator, u8, &.{ left, right });
    try emit(allocator, texel, outputs, .{ .available = .{ .text = joined } });
}

/// sum: left int + right int -> value int.
fn sum(
    context: *anyopaque,
    allocator: Allocator,
    texel: *const Texel,
    inputs: *const OutcomeMap,
    outputs: *OutcomeMap,
) Error!void {
    _ = context;
    const left = availableInt(inputs, "left") orelse
        return emit(allocator, texel, outputs, .unavailable);
    const right = availableInt(inputs, "right") orelse
        return emit(allocator, texel, outputs, .unavailable);
    try emit(allocator, texel, outputs, .{ .available = .{ .int = left +% right } });
}

/// upper: text text -> value text, uppercased.
fn upper(
    context: *anyopaque,
    allocator: Allocator,
    texel: *const Texel,
    inputs: *const OutcomeMap,
    outputs: *OutcomeMap,
) Error!void {
    _ = context;
    const text = availableText(inputs, "text") orelse
        return emit(allocator, texel, outputs, .unavailable);
    const raised = try allocator.dupe(u8, text);
    for (raised) |*character| character.* = std.ascii.toUpper(character.*);
    try emit(allocator, texel, outputs, .{ .available = .{ .text = raised } });
}
