//! The Fabric primitive: a Texel with stable identity, optional content,
//! an optional evaluator, and typed ports.
//!
//! Ownership is explicit throughout: a Texel owns its ports, a port owns
//! its name and binding or source value, and every holder offers clone
//! and deinit.  putInput and putOutput take ownership of the port they
//! are given.  Ports are kept sorted by name so iteration — and the
//! snapshot encoding built on it — is deterministic.

const std = @import("std");
const texel_id = @import("texel_id.zig");
const value_mod = @import("value.zig");

const Allocator = std.mem.Allocator;
const TexelId = texel_id.TexelId;
const Value = value_mod.Value;
const ValueType = value_mod.ValueType;

// ---------------------------------------------------------------------------
// Fiber
// ---------------------------------------------------------------------------
//
// Reference to one source Texel output.  The target InputPort owns the
// Fiber.
//
pub const Fiber = struct {
    source: TexelId,
    output: []u8,

    pub fn init(allocator: Allocator, source: TexelId, output: []const u8) !Fiber {
        return .{ .source = source, .output = try allocator.dupe(u8, output) };
    }

    pub fn clone(self: Fiber, allocator: Allocator) !Fiber {
        return init(allocator, self.source, self.output);
    }

    pub fn deinit(self: *Fiber, allocator: Allocator) void {
        allocator.free(self.output);
        self.* = undefined;
    }

    pub fn eql(self: Fiber, other: Fiber) bool {
        return self.source.eql(other.source) and std.mem.eql(u8, self.output, other.output);
    }

    pub fn valid(self: Fiber) bool {
        return !self.source.isUnset() and self.output.len > 0;
    }
};

// ---------------------------------------------------------------------------
// InputPort
// ---------------------------------------------------------------------------
//
// Named, typed input which owns zero or one source binding.
//
pub const InputPort = struct {
    name: []u8,
    declared: ValueType,
    binding: ?Fiber = null,

    pub fn init(allocator: Allocator, name: []const u8, declared: ValueType) !InputPort {
        return .{ .name = try allocator.dupe(u8, name), .declared = declared };
    }

    pub fn clone(self: InputPort, allocator: Allocator) !InputPort {
        var copied = try init(allocator, self.name, self.declared);
        errdefer copied.deinit(allocator);
        if (self.binding) |fiber| {
            copied.binding = try fiber.clone(allocator);
        }
        return copied;
    }

    pub fn deinit(self: *InputPort, allocator: Allocator) void {
        if (self.binding) |*fiber| fiber.deinit(allocator);
        allocator.free(self.name);
        self.* = undefined;
    }

    /// Take ownership of the fiber; any previous binding is released.
    pub fn bind(self: *InputPort, allocator: Allocator, fiber: Fiber) error{InvalidFiber}!void {
        if (!fiber.valid()) return error.InvalidFiber;
        if (self.binding) |*previous| previous.deinit(allocator);
        self.binding = fiber;
    }

    pub fn unbind(self: *InputPort, allocator: Allocator) void {
        if (self.binding) |*fiber| fiber.deinit(allocator);
        self.binding = null;
    }

    pub fn valid(self: InputPort) bool {
        if (self.name.len == 0 or self.declared == .none) return false;
        return if (self.binding) |fiber| fiber.valid() else true;
    }
};

// ---------------------------------------------------------------------------
// OutputPort
// ---------------------------------------------------------------------------
//
// Named, typed output which owns its current source Value and revision.
//
pub const OutputPort = struct {
    name: []u8,
    declared: ValueType,
    source: ?Value = null,
    revision: u64 = 0,

    pub fn init(allocator: Allocator, name: []const u8, declared: ValueType) !OutputPort {
        return .{ .name = try allocator.dupe(u8, name), .declared = declared };
    }

    pub fn clone(self: OutputPort, allocator: Allocator) !OutputPort {
        var copied = try init(allocator, self.name, self.declared);
        errdefer copied.deinit(allocator);
        if (self.source) |source| {
            copied.source = try source.clone(allocator);
        }
        copied.revision = self.revision;
        return copied;
    }

    pub fn deinit(self: *OutputPort, allocator: Allocator) void {
        if (self.source) |*source| source.deinit(allocator);
        allocator.free(self.name);
        self.* = undefined;
    }

    /// Take ownership of the value and advance the revision.  The value
    /// must match the declared type.
    pub fn setSource(self: *OutputPort, allocator: Allocator, source: Value) error{TypeMismatch}!void {
        if (source.tag() == .none or source.tag() != self.declared) return error.TypeMismatch;
        if (self.source) |*previous| previous.deinit(allocator);
        self.source = source;
        self.revision +%= 1;
    }

    pub fn clearSource(self: *OutputPort, allocator: Allocator) void {
        if (self.source) |*source| {
            source.deinit(allocator);
            self.source = null;
            self.revision +%= 1;
        }
    }

    pub fn valid(self: OutputPort) bool {
        if (self.name.len == 0 or self.declared == .none) return false;
        return if (self.source) |source| source.tag() == self.declared else true;
    }
};

// ---------------------------------------------------------------------------
// Texel
// ---------------------------------------------------------------------------
//
// Atomic in identity, not necessarily small in content.  Ports live in
// name-sorted tables; put replaces or inserts, keeping order stable.
//
pub const Texel = struct {
    id: TexelId,
    content: ?Value = null,
    evaluator: ?[]u8 = null,
    revision: u64 = 0,
    inputs: std.ArrayList(InputPort) = .empty,
    outputs: std.ArrayList(OutputPort) = .empty,

    pub fn init(id: TexelId) Texel {
        return .{ .id = id };
    }

    pub fn clone(self: Texel, allocator: Allocator) !Texel {
        var copied = Texel.init(self.id);
        errdefer copied.deinit(allocator);

        if (self.content) |content| copied.content = try content.clone(allocator);
        if (self.evaluator) |name| copied.evaluator = try allocator.dupe(u8, name);
        copied.revision = self.revision;

        try copied.inputs.ensureTotalCapacity(allocator, self.inputs.items.len);
        for (self.inputs.items) |port| {
            copied.inputs.appendAssumeCapacity(try port.clone(allocator));
        }
        try copied.outputs.ensureTotalCapacity(allocator, self.outputs.items.len);
        for (self.outputs.items) |port| {
            copied.outputs.appendAssumeCapacity(try port.clone(allocator));
        }
        return copied;
    }

    pub fn deinit(self: *Texel, allocator: Allocator) void {
        if (self.content) |*content| content.deinit(allocator);
        if (self.evaluator) |name| allocator.free(name);
        for (self.inputs.items) |*port| port.deinit(allocator);
        self.inputs.deinit(allocator);
        for (self.outputs.items) |*port| port.deinit(allocator);
        self.outputs.deinit(allocator);
        self.* = undefined;
    }

    /// Take ownership of the value as this texel's opaque content.
    pub fn setContent(self: *Texel, allocator: Allocator, content: Value) error{NoValue}!void {
        if (content.tag() == .none) return error.NoValue;
        if (self.content) |*previous| previous.deinit(allocator);
        self.content = content;
    }

    pub fn clearContent(self: *Texel, allocator: Allocator) void {
        if (self.content) |*content| content.deinit(allocator);
        self.content = null;
    }

    pub fn setEvaluator(self: *Texel, allocator: Allocator, name: []const u8) !void {
        if (name.len == 0) return error.EmptyName;
        const owned = try allocator.dupe(u8, name);
        if (self.evaluator) |previous| allocator.free(previous);
        self.evaluator = owned;
    }

    pub fn evaluatorName(self: *const Texel) []const u8 {
        return self.evaluator orelse "";
    }

    // Inputs -----------------------------------------------------------------

    pub fn inputCount(self: *const Texel) usize {
        return self.inputs.items.len;
    }

    pub fn hasInput(self: *const Texel, name: []const u8) bool {
        return self.findInput(name) != null;
    }

    pub fn getInput(self: *const Texel, name: []const u8) ?*const InputPort {
        const index = self.findInput(name) orelse return null;
        return &self.inputs.items[index];
    }

    pub fn mutableInput(self: *Texel, name: []const u8) ?*InputPort {
        const index = self.findInput(name) orelse return null;
        return &self.inputs.items[index];
    }

    pub fn inputAt(self: *const Texel, index: usize) ?*const InputPort {
        if (index >= self.inputs.items.len) return null;
        return &self.inputs.items[index];
    }

    /// Take ownership of the port; a port with the same name is replaced.
    pub fn putInput(self: *Texel, allocator: Allocator, port: InputPort) !void {
        if (!port.valid()) return error.InvalidPort;
        if (self.findInput(port.name)) |index| {
            self.inputs.items[index].deinit(allocator);
            self.inputs.items[index] = port;
            return;
        }
        try self.inputs.insert(allocator, self.inputInsertIndex(port.name), port);
    }

    pub fn removeInput(self: *Texel, allocator: Allocator, name: []const u8) bool {
        const index = self.findInput(name) orelse return false;
        var removed = self.inputs.orderedRemove(index);
        removed.deinit(allocator);
        return true;
    }

    // Outputs ----------------------------------------------------------------

    pub fn outputCount(self: *const Texel) usize {
        return self.outputs.items.len;
    }

    pub fn hasOutput(self: *const Texel, name: []const u8) bool {
        return self.findOutput(name) != null;
    }

    pub fn getOutput(self: *const Texel, name: []const u8) ?*const OutputPort {
        const index = self.findOutput(name) orelse return null;
        return &self.outputs.items[index];
    }

    pub fn mutableOutput(self: *Texel, name: []const u8) ?*OutputPort {
        const index = self.findOutput(name) orelse return null;
        return &self.outputs.items[index];
    }

    pub fn outputAt(self: *const Texel, index: usize) ?*const OutputPort {
        if (index >= self.outputs.items.len) return null;
        return &self.outputs.items[index];
    }

    /// Take ownership of the port; a port with the same name is replaced.
    pub fn putOutput(self: *Texel, allocator: Allocator, port: OutputPort) !void {
        if (!port.valid()) return error.InvalidPort;
        if (self.findOutput(port.name)) |index| {
            self.outputs.items[index].deinit(allocator);
            self.outputs.items[index] = port;
            return;
        }
        try self.outputs.insert(allocator, self.outputInsertIndex(port.name), port);
    }

    pub fn removeOutput(self: *Texel, allocator: Allocator, name: []const u8) bool {
        const index = self.findOutput(name) orelse return false;
        var removed = self.outputs.orderedRemove(index);
        removed.deinit(allocator);
        return true;
    }

    pub fn valid(self: *const Texel) bool {
        if (self.id.isUnset()) return false;
        for (self.inputs.items) |port| {
            if (!port.valid()) return false;
        }
        for (self.outputs.items) |port| {
            if (!port.valid()) return false;
        }
        return true;
    }

    // Port tables are small; linear scans stay honest and cache-friendly.

    fn findInput(self: *const Texel, name: []const u8) ?usize {
        for (self.inputs.items, 0..) |port, index| {
            if (std.mem.eql(u8, port.name, name)) return index;
        }
        return null;
    }

    fn inputInsertIndex(self: *const Texel, name: []const u8) usize {
        for (self.inputs.items, 0..) |port, index| {
            if (std.mem.order(u8, name, port.name) == .lt) return index;
        }
        return self.inputs.items.len;
    }

    fn findOutput(self: *const Texel, name: []const u8) ?usize {
        for (self.outputs.items, 0..) |port, index| {
            if (std.mem.eql(u8, port.name, name)) return index;
        }
        return null;
    }

    fn outputInsertIndex(self: *const Texel, name: []const u8) usize {
        for (self.outputs.items, 0..) |port, index| {
            if (std.mem.order(u8, name, port.name) == .lt) return index;
        }
        return self.outputs.items.len;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "ports insert sorted, replace by name, and remove" {
    const allocator = testing.allocator;
    var texel = Texel.init(TexelId.generate(std.testing.io));
    defer texel.deinit(allocator);

    try texel.putOutput(allocator, try OutputPort.init(allocator, "value", .text));
    try texel.putOutput(allocator, try OutputPort.init(allocator, "name", .text));
    try texel.putInput(allocator, try InputPort.init(allocator, "right", .int));
    try texel.putInput(allocator, try InputPort.init(allocator, "left", .int));

    try testing.expectEqual(@as(usize, 2), texel.outputCount());
    try testing.expectEqualStrings("name", texel.outputAt(0).?.name);
    try testing.expectEqualStrings("value", texel.outputAt(1).?.name);
    try testing.expectEqualStrings("left", texel.inputAt(0).?.name);
    try testing.expectEqualStrings("right", texel.inputAt(1).?.name);

    // Replacing keeps one port per name.
    var replacement = try OutputPort.init(allocator, "value", .text);
    try replacement.setSource(allocator, try Value.initText(allocator, "hello"));
    try texel.putOutput(allocator, replacement);
    try testing.expectEqual(@as(usize, 2), texel.outputCount());
    try testing.expectEqualStrings("hello", texel.getOutput("value").?.source.?.text);

    try testing.expect(texel.removeInput(allocator, "left"));
    try testing.expect(!texel.removeInput(allocator, "left"));
    try testing.expectEqual(@as(usize, 1), texel.inputCount());
}

test "set source enforces the declared type and bumps revisions" {
    const allocator = testing.allocator;
    var port = try OutputPort.init(allocator, "value", .int);
    defer port.deinit(allocator);

    try testing.expectEqual(@as(u64, 0), port.revision);
    try port.setSource(allocator, .{ .int = 5 });
    try testing.expectEqual(@as(u64, 1), port.revision);
    try testing.expectError(error.TypeMismatch, port.setSource(allocator, .{ .boolean = true }));
}

test "bindings are owned and validity checks cover ports" {
    const allocator = testing.allocator;
    var texel = Texel.init(TexelId.generate(std.testing.io));
    defer texel.deinit(allocator);

    var input = try InputPort.init(allocator, "text", .text);
    try input.bind(allocator, try Fiber.init(allocator, TexelId.generate(std.testing.io), "value"));
    try texel.putInput(allocator, input);
    try testing.expect(texel.valid());

    const bound = texel.getInput("text").?;
    try testing.expect(bound.binding != null);
    try testing.expectEqualStrings("value", bound.binding.?.output);

    texel.mutableInput("text").?.unbind(allocator);
    try testing.expect(texel.getInput("text").?.binding == null);
}

test "clone is deep" {
    const allocator = testing.allocator;
    var texel = Texel.init(TexelId.generate(std.testing.io));
    try texel.setEvaluator(allocator, "concat");
    var output = try OutputPort.init(allocator, "value", .text);
    try output.setSource(allocator, try Value.initText(allocator, "shared?"));
    try texel.putOutput(allocator, output);

    var copied = try texel.clone(allocator);
    texel.deinit(allocator);
    defer copied.deinit(allocator);

    try testing.expectEqualStrings("concat", copied.evaluatorName());
    try testing.expectEqualStrings("shared?", copied.getOutput("value").?.source.?.text);
}

test "type mismatch on setSource does not leak the given value" {
    const allocator = testing.allocator;
    var port = try OutputPort.init(allocator, "value", .int);
    defer port.deinit(allocator);

    var wrong = try Value.initText(allocator, "leak?");
    if (port.setSource(allocator, wrong)) |_| {
        return error.ExpectedTypeMismatch;
    } else |err| {
        try testing.expectEqual(error.TypeMismatch, err);
        wrong.deinit(allocator);
    }
}
