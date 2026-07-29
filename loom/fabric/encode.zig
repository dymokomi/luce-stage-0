//! Snapshot binary encoding.
//!
//! Versioned deterministic little-endian encoding for Texels and
//! out-of-line blobs.  Decoding is strict and consumes the complete
//! input.  This format is the frozen contract shared with the reference
//! C++ implementation — the golden fixture test proves both read the
//! same bytes.  Never encode raw struct layouts.

const std = @import("std");
const texel_id = @import("texel_id.zig");
const value_mod = @import("value.zig");
const texel_mod = @import("texel.zig");

const Allocator = std.mem.Allocator;
const TexelId = texel_id.TexelId;
const Value = value_mod.Value;
const ValueType = value_mod.ValueType;
const BlobRef = value_mod.BlobRef;
const Fiber = texel_mod.Fiber;
const InputPort = texel_mod.InputPort;
const OutputPort = texel_mod.OutputPort;
const Texel = texel_mod.Texel;

const snapshot_version: u32 = 1;
const snapshot_magic = [8]u8{ 'L', 'U', 'T', 'E', 'X', 'E', 'L', 0 };

pub const Error = error{ InvalidSnapshot, OutOfMemory };

// ---------------------------------------------------------------------------
// BlobRecord
// ---------------------------------------------------------------------------
//
// One out-of-line blob: its reference and its owned bytes.
//
pub const BlobRecord = struct {
    reference: BlobRef,
    bytes: []u8,

    pub fn deinit(self: *BlobRecord, allocator: Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// Snapshot
// ---------------------------------------------------------------------------
//
// A decoded snapshot owns its texels and blobs.
//
pub const Snapshot = struct {
    texels: std.ArrayList(Texel) = .empty,
    blobs: std.ArrayList(BlobRecord) = .empty,

    pub fn deinit(self: *Snapshot, allocator: Allocator) void {
        for (self.texels.items) |*item| item.deinit(allocator);
        self.texels.deinit(allocator);
        for (self.blobs.items) |*blob| blob.deinit(allocator);
        self.blobs.deinit(allocator);
        self.* = undefined;
    }
};

pub fn temporalEvaluator(evaluator: []const u8) bool {
    return std.mem.eql(u8, evaluator, "loom.state") or
        std.mem.eql(u8, evaluator, "loom.delay");
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

const Writer = struct {
    allocator: Allocator,
    bytes: std.ArrayList(u8) = .empty,

    fn deinit(self: *Writer) void {
        self.bytes.deinit(self.allocator);
    }

    fn write(self: *Writer, data: []const u8) Error!void {
        try self.bytes.appendSlice(self.allocator, data);
    }

    fn writeByte(self: *Writer, value: u8) Error!void {
        try self.bytes.append(self.allocator, value);
    }

    fn writeU32(self: *Writer, value: u32) Error!void {
        var encoded: [4]u8 = undefined;
        std.mem.writeInt(u32, &encoded, value, .little);
        try self.write(&encoded);
    }

    fn writeU64(self: *Writer, value: u64) Error!void {
        var encoded: [8]u8 = undefined;
        std.mem.writeInt(u64, &encoded, value, .little);
        try self.write(&encoded);
    }

    fn writeString(self: *Writer, text: []const u8) Error!void {
        try self.writeU64(text.len);
        try self.write(text);
    }
};

fn encodeValue(writer: *Writer, value: Value) Error!void {
    if (value == .none) return Error.InvalidSnapshot;
    try writer.writeByte(@intFromEnum(value.tag()));
    switch (value) {
        .none => unreachable,
        .boolean => |flag| try writer.writeByte(if (flag) 1 else 0),
        .int => |number| try writer.writeU64(@bitCast(number)),
        .real => |number| try writer.writeU64(@bitCast(number)),
        .text => |content| try writer.writeString(content),
        .bytes => |content| {
            try writer.writeU64(content.len);
            try writer.write(content);
        },
        .texel => |id| {
            if (id.isUnset()) return Error.InvalidSnapshot;
            try writer.write(&id.bytes);
        },
        .blob => |reference| {
            if (reference.isUnset()) return Error.InvalidSnapshot;
            try writer.write(&reference.id);
            try writer.writeU64(reference.size);
        },
    }
}

fn encodeTexelBody(writer: *Writer, texel: *const Texel) Error!void {
    if (!texel.valid()) return Error.InvalidSnapshot;
    if (texel.inputCount() > std.math.maxInt(u32)) return Error.InvalidSnapshot;
    if (texel.outputCount() > std.math.maxInt(u32)) return Error.InvalidSnapshot;

    try writer.write(&texel.id.bytes);
    try writer.writeByte(if (texel.content != null) 1 else 0);
    if (texel.content) |content| try encodeValue(writer, content);
    try writer.writeString(texel.evaluatorName());
    try writer.writeU64(texel.revision);

    try writer.writeU32(@intCast(texel.inputCount()));
    for (texel.inputs.items) |port| {
        try writer.writeString(port.name);
        try writer.writeByte(@intFromEnum(port.declared));
        try writer.writeByte(if (port.binding != null) 1 else 0);
        if (port.binding) |fiber| {
            try writer.write(&fiber.source.bytes);
            try writer.writeString(fiber.output);
        }
    }

    try writer.writeU32(@intCast(texel.outputCount()));
    for (texel.outputs.items) |port| {
        try writer.writeString(port.name);
        try writer.writeByte(@intFromEnum(port.declared));
        try writer.writeByte(if (port.source != null) 1 else 0);
        if (port.source) |source| try encodeValue(writer, source);
        try writer.writeU64(port.revision);
    }
}

/// Encode one texel; the caller owns the returned bytes.
pub fn encodeTexel(allocator: Allocator, texel: *const Texel) Error![]u8 {
    var writer: Writer = .{ .allocator = allocator };
    errdefer writer.deinit();
    try encodeTexelBody(&writer, texel);
    return writer.bytes.toOwnedSlice(allocator);
}

/// Encode a validated snapshot; the caller owns the returned bytes.
/// Texels and blobs are encoded in sorted order, so equal contents
/// always produce equal bytes.
pub fn encodeSnapshot(
    allocator: Allocator,
    texels: []const Texel,
    blobs: []const BlobRecord,
) Error![]u8 {
    if (texels.len > std.math.maxInt(u32) or blobs.len > std.math.maxInt(u32)) {
        return Error.InvalidSnapshot;
    }
    try validateSnapshot(allocator, texels, blobs);

    const texel_order = try sortedIndexes(allocator, texels.len, texels, texelIndexLess);
    defer allocator.free(texel_order);
    const blob_order = try sortedIndexes(allocator, blobs.len, blobs, blobIndexLess);
    defer allocator.free(blob_order);

    var writer: Writer = .{ .allocator = allocator };
    errdefer writer.deinit();

    try writer.write(&snapshot_magic);
    try writer.writeU32(snapshot_version);
    try writer.writeU32(@intCast(texels.len));
    for (texel_order) |index| {
        const body = try encodeTexel(allocator, &texels[index]);
        defer allocator.free(body);
        try writer.writeU64(body.len);
        try writer.write(body);
    }

    try writer.writeU32(@intCast(blobs.len));
    for (blob_order) |index| {
        const blob = blobs[index];
        try writer.write(&blob.reference.id);
        try writer.writeU64(blob.reference.size);
        try writer.write(blob.bytes);
    }
    return writer.bytes.toOwnedSlice(allocator);
}

fn texelIndexLess(texels: []const Texel, left: usize, right: usize) bool {
    return texels[left].id.lessThan(texels[right].id);
}

fn blobIndexLess(blobs: []const BlobRecord, left: usize, right: usize) bool {
    return std.mem.order(u8, &blobs[left].reference.id, &blobs[right].reference.id) == .lt;
}

fn sortedIndexes(
    allocator: Allocator,
    count: usize,
    context: anytype,
    comptime less: fn (@TypeOf(context), usize, usize) bool,
) Error![]usize {
    const order = try allocator.alloc(usize, count);
    for (order, 0..) |*slot, index| slot.* = index;
    const Sorter = struct {
        context: @TypeOf(context),
        fn lessThan(self: @This(), left: usize, right: usize) bool {
            return less(self.context, left, right);
        }
    };
    std.mem.sort(usize, order, Sorter{ .context = context }, Sorter.lessThan);
    return order;
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

const Reader = struct {
    data: []const u8,
    offset: usize = 0,

    fn take(self: *Reader, count: usize) Error![]const u8 {
        if (count > self.remaining()) return Error.InvalidSnapshot;
        const slice = self.data[self.offset..][0..count];
        self.offset += count;
        return slice;
    }

    fn byte(self: *Reader) Error!u8 {
        return (try self.take(1))[0];
    }

    fn u32Value(self: *Reader) Error!u32 {
        return std.mem.readInt(u32, (try self.take(4))[0..4], .little);
    }

    fn u64Value(self: *Reader) Error!u64 {
        return std.mem.readInt(u64, (try self.take(8))[0..8], .little);
    }

    fn string(self: *Reader) Error![]const u8 {
        const length = try self.u64Value();
        if (length > self.remaining()) return Error.InvalidSnapshot;
        return self.take(@intCast(length));
    }

    fn id(self: *Reader) Error!TexelId {
        var parsed: TexelId = .{};
        @memcpy(&parsed.bytes, try self.take(TexelId.size));
        return parsed;
    }

    fn remaining(self: *const Reader) usize {
        return self.data.len - self.offset;
    }

    fn done(self: *const Reader) bool {
        return self.offset == self.data.len;
    }
};

fn decodeValueType(raw: u8) Error!ValueType {
    if (raw < @intFromEnum(ValueType.boolean) or raw > @intFromEnum(ValueType.blob)) {
        return Error.InvalidSnapshot;
    }
    return @enumFromInt(raw);
}

fn decodeValue(allocator: Allocator, reader: *Reader) Error!Value {
    const kind = try decodeValueType(try reader.byte());
    switch (kind) {
        .none => unreachable,
        .boolean => {
            const flag = try reader.byte();
            if (flag > 1) return Error.InvalidSnapshot;
            return .{ .boolean = flag == 1 };
        },
        .int => return .{ .int = @bitCast(try reader.u64Value()) },
        .real => return .{ .real = @bitCast(try reader.u64Value()) },
        .text => return Value.initText(allocator, try reader.string()),
        .bytes => {
            const length = try reader.u64Value();
            if (length > reader.remaining()) return Error.InvalidSnapshot;
            return Value.initBytes(allocator, try reader.take(@intCast(length)));
        },
        .texel => {
            const parsed = try reader.id();
            if (parsed.isUnset()) return Error.InvalidSnapshot;
            return .{ .texel = parsed };
        },
        .blob => {
            var reference: BlobRef = .{};
            @memcpy(&reference.id, try reader.take(BlobRef.id_size));
            reference.size = try reader.u64Value();
            if (reference.isUnset()) return Error.InvalidSnapshot;
            return .{ .blob = reference };
        },
    }
}

/// Decode one texel body; the caller owns the result.
pub fn decodeTexel(allocator: Allocator, data: []const u8) Error!Texel {
    var reader: Reader = .{ .data = data };

    const parsed_id = try reader.id();
    if (parsed_id.isUnset()) return Error.InvalidSnapshot;
    var texel = Texel.init(parsed_id);
    errdefer texel.deinit(allocator);

    const content_flag = try reader.byte();
    if (content_flag > 1) return Error.InvalidSnapshot;
    if (content_flag == 1) {
        var content = try decodeValue(allocator, &reader);
        errdefer content.deinit(allocator);
        texel.setContent(allocator, content) catch return Error.InvalidSnapshot;
    }

    const evaluator = try reader.string();
    if (evaluator.len > 0) {
        texel.setEvaluator(allocator, evaluator) catch |err| switch (err) {
            error.OutOfMemory => return Error.OutOfMemory,
            error.EmptyName => unreachable,
        };
    }
    texel.revision = try reader.u64Value();

    const input_count = try reader.u32Value();
    if (input_count > reader.remaining()) return Error.InvalidSnapshot;
    var input_index: u32 = 0;
    while (input_index < input_count) : (input_index += 1) {
        const name = try reader.string();
        if (name.len == 0 or texel.hasInput(name)) return Error.InvalidSnapshot;
        const declared = try decodeValueType(try reader.byte());
        const bound = try reader.byte();
        if (bound > 1) return Error.InvalidSnapshot;

        var port = try InputPort.init(allocator, name, declared);
        errdefer port.deinit(allocator);
        if (bound == 1) {
            const source = try reader.id();
            const output_name = try reader.string();
            const fiber = try Fiber.init(allocator, source, output_name);
            port.bind(allocator, fiber) catch {
                var released = fiber;
                released.deinit(allocator);
                return Error.InvalidSnapshot;
            };
        }
        texel.putInput(allocator, port) catch return Error.InvalidSnapshot;
    }

    const output_count = try reader.u32Value();
    if (output_count > reader.remaining()) return Error.InvalidSnapshot;
    var output_index: u32 = 0;
    while (output_index < output_count) : (output_index += 1) {
        const name = try reader.string();
        if (name.len == 0 or texel.hasOutput(name)) return Error.InvalidSnapshot;
        const declared = try decodeValueType(try reader.byte());
        const sourced = try reader.byte();
        if (sourced > 1) return Error.InvalidSnapshot;

        var port = try OutputPort.init(allocator, name, declared);
        errdefer port.deinit(allocator);
        if (sourced == 1) {
            var source = try decodeValue(allocator, &reader);
            port.setSource(allocator, source) catch {
                source.deinit(allocator);
                return Error.InvalidSnapshot;
            };
        }
        // The stored revision wins over the bump setSource applied.
        port.revision = try reader.u64Value();
        texel.putOutput(allocator, port) catch return Error.InvalidSnapshot;
    }

    if (!reader.done() or !texel.valid()) return Error.InvalidSnapshot;
    return texel;
}

/// Decode a complete snapshot; the caller owns the result.
pub fn decodeSnapshot(allocator: Allocator, data: []const u8) Error!Snapshot {
    var reader: Reader = .{ .data = data };
    var snapshot: Snapshot = .{};
    errdefer snapshot.deinit(allocator);

    const magic = try reader.take(snapshot_magic.len);
    if (!std.mem.eql(u8, magic, &snapshot_magic)) return Error.InvalidSnapshot;
    if (try reader.u32Value() != snapshot_version) return Error.InvalidSnapshot;

    const texel_count = try reader.u32Value();
    if (texel_count > reader.remaining() / 8) return Error.InvalidSnapshot;
    var texel_index: u32 = 0;
    while (texel_index < texel_count) : (texel_index += 1) {
        const body_size = try reader.u64Value();
        if (body_size == 0 or body_size > reader.remaining()) return Error.InvalidSnapshot;
        const body = try reader.take(@intCast(body_size));
        var decoded = try decodeTexel(allocator, body);
        errdefer decoded.deinit(allocator);
        for (snapshot.texels.items) |existing| {
            if (existing.id.eql(decoded.id)) return Error.InvalidSnapshot;
        }
        try snapshot.texels.append(allocator, decoded);
    }

    const blob_count = try reader.u32Value();
    if (blob_count > reader.remaining() / (BlobRef.id_size + 8)) return Error.InvalidSnapshot;
    var blob_index: u32 = 0;
    while (blob_index < blob_count) : (blob_index += 1) {
        var reference: BlobRef = .{};
        @memcpy(&reference.id, try reader.take(BlobRef.id_size));
        reference.size = try reader.u64Value();
        if (reference.isUnset() or reference.size > reader.remaining()) {
            return Error.InvalidSnapshot;
        }
        for (snapshot.blobs.items) |existing| {
            if (std.mem.eql(u8, &existing.reference.id, &reference.id)) {
                return Error.InvalidSnapshot;
            }
        }
        const bytes = try allocator.dupe(u8, try reader.take(@intCast(reference.size)));
        errdefer allocator.free(bytes);
        try snapshot.blobs.append(allocator, .{ .reference = reference, .bytes = bytes });
    }

    if (!reader.done()) return Error.InvalidSnapshot;
    try validateSnapshot(allocator, snapshot.texels.items, snapshot.blobs.items);
    return snapshot;
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------
//
// Checks graph bindings, types, blob references, temporal texel shape,
// and acyclicity.  Ordinary computation must be acyclic; recurrence only
// enters through State and Delay, which break cycles by construction.
//

fn validTemporalTexel(texel: *const Texel) bool {
    if (texel.inputCount() != 1 or texel.outputCount() != 1) return false;
    const input = texel.getInput("next") orelse return false;
    const output = texel.getOutput("value") orelse return false;
    const source = output.source orelse return false;
    return input.declared == output.declared and source.tag() == output.declared;
}

fn findTexel(texels: []const Texel, id: TexelId) ?*const Texel {
    for (texels) |*texel| {
        if (texel.id.eql(id)) return texel;
    }
    return null;
}

fn findBlob(blobs: []const BlobRecord, reference: BlobRef) ?*const BlobRecord {
    for (blobs) |*blob| {
        if (std.mem.eql(u8, &blob.reference.id, &reference.id)) return blob;
    }
    return null;
}

fn valueReferencesValid(
    value: Value,
    texels: []const Texel,
    blobs: []const BlobRecord,
) bool {
    switch (value) {
        .texel => |id| return !id.isUnset() and findTexel(texels, id) != null,
        .blob => |reference| {
            if (reference.isUnset()) return false;
            const found = findBlob(blobs, reference) orelse return false;
            return found.reference.size == reference.size;
        },
        .none => return false,
        else => return true,
    }
}

const VisitState = enum { visiting, finished };
const VisitTable = std.AutoHashMapUnmanaged([TexelId.size]u8, VisitState);

fn visit(
    allocator: Allocator,
    id: TexelId,
    texels: []const Texel,
    visits: *VisitTable,
) Error!bool {
    if (visits.get(id.bytes)) |state| return state == .finished;
    try visits.put(allocator, id.bytes, .visiting);

    const target = findTexel(texels, id) orelse return false;
    if (temporalEvaluator(target.evaluatorName())) {
        try visits.put(allocator, id.bytes, .finished);
        return true;
    }
    for (target.inputs.items) |input| {
        const fiber = input.binding orelse continue;
        if (visits.get(fiber.source.bytes)) |state| {
            if (state == .visiting) return false;
            continue;
        }
        if (!try visit(allocator, fiber.source, texels, visits)) return false;
    }
    try visits.put(allocator, id.bytes, .finished);
    return true;
}

pub fn validateSnapshot(
    allocator: Allocator,
    texels: []const Texel,
    blobs: []const BlobRecord,
) Error!void {
    for (blobs, 0..) |blob, index| {
        if (blob.reference.isUnset()) return Error.InvalidSnapshot;
        if (blob.reference.size != blob.bytes.len) return Error.InvalidSnapshot;
        for (blobs[0..index]) |earlier| {
            if (std.mem.eql(u8, &earlier.reference.id, &blob.reference.id)) {
                return Error.InvalidSnapshot;
            }
        }
    }

    for (texels, 0..) |*texel, index| {
        if (!texel.valid()) return Error.InvalidSnapshot;
        if (temporalEvaluator(texel.evaluatorName()) and !validTemporalTexel(texel)) {
            return Error.InvalidSnapshot;
        }
        for (texels[0..index]) |earlier| {
            if (earlier.id.eql(texel.id)) return Error.InvalidSnapshot;
        }
    }

    for (texels) |*texel| {
        if (texel.content) |content| {
            if (!valueReferencesValid(content, texels, blobs)) return Error.InvalidSnapshot;
        }
        for (texel.inputs.items) |input| {
            const fiber = input.binding orelse continue;
            const source = findTexel(texels, fiber.source) orelse
                return Error.InvalidSnapshot;
            const output = source.getOutput(fiber.output) orelse
                return Error.InvalidSnapshot;
            if (output.declared != input.declared) return Error.InvalidSnapshot;
        }
        for (texel.outputs.items) |output| {
            const source = output.source orelse continue;
            if (!valueReferencesValid(source, texels, blobs)) return Error.InvalidSnapshot;
        }
    }

    var visits: VisitTable = .empty;
    defer visits.deinit(allocator);
    for (texels) |*texel| {
        if (visits.contains(texel.id.bytes)) continue;
        if (!try visit(allocator, texel.id, texels, &visits)) return Error.InvalidSnapshot;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn sourceTexel(allocator: Allocator, text: []const u8) !Texel {
    var texel = Texel.init(TexelId.generate(std.testing.io));
    errdefer texel.deinit(allocator);
    var output = try OutputPort.init(allocator, "value", .text);
    try output.setSource(allocator, try Value.initText(allocator, text));
    try texel.putOutput(allocator, output);
    return texel;
}

test "snapshot round-trips texels, ports, bindings, and blobs" {
    const allocator = testing.allocator;

    var one = try sourceTexel(allocator, "hello");
    defer one.deinit(allocator);

    var two = Texel.init(TexelId.generate(std.testing.io));
    defer two.deinit(allocator);
    try two.setEvaluator(allocator, "copy");
    var input = try InputPort.init(allocator, "input", .text);
    try input.bind(allocator, try Fiber.init(allocator, one.id, "value"));
    try two.putInput(allocator, input);
    try two.putOutput(allocator, try OutputPort.init(allocator, "value", .text));
    two.revision = 7;

    var blob: BlobRecord = .{
        .reference = .{ .id = @splat(3), .size = 4 },
        .bytes = try allocator.dupe(u8, "data"),
    };
    defer blob.deinit(allocator);

    const texels = [_]Texel{ one, two };
    const blobs = [_]BlobRecord{blob};
    const encoded = try encodeSnapshot(allocator, &texels, &blobs);
    defer allocator.free(encoded);

    var decoded = try decodeSnapshot(allocator, encoded);
    defer decoded.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), decoded.texels.items.len);
    try testing.expectEqual(@as(usize, 1), decoded.blobs.items.len);
    try testing.expectEqualStrings("data", decoded.blobs.items[0].bytes);

    const copied = findTexel(decoded.texels.items, two.id) orelse return error.Missing;
    try testing.expectEqual(@as(u64, 7), copied.revision);
    try testing.expectEqualStrings("copy", copied.evaluatorName());
    const bound = copied.getInput("input").?.binding orelse return error.Missing;
    try testing.expect(bound.source.eql(one.id));

    const original = findTexel(decoded.texels.items, one.id) orelse return error.Missing;
    try testing.expectEqualStrings("hello", original.getOutput("value").?.source.?.text);
}

test "encoding is deterministic regardless of given order" {
    const allocator = testing.allocator;

    var one = try sourceTexel(allocator, "a");
    defer one.deinit(allocator);
    var two = try sourceTexel(allocator, "b");
    defer two.deinit(allocator);

    const forward = try encodeSnapshot(allocator, &[_]Texel{ one, two }, &.{});
    defer allocator.free(forward);
    const backward = try encodeSnapshot(allocator, &[_]Texel{ two, one }, &.{});
    defer allocator.free(backward);
    try testing.expectEqualSlices(u8, forward, backward);
}

test "decode rejects trailing garbage and truncation" {
    const allocator = testing.allocator;

    var one = try sourceTexel(allocator, "x");
    defer one.deinit(allocator);
    const encoded = try encodeSnapshot(allocator, &[_]Texel{one}, &.{});
    defer allocator.free(encoded);

    var padded = try allocator.dupe(u8, encoded);
    defer allocator.free(padded);
    padded = try allocator.realloc(padded, encoded.len + 1);
    padded[encoded.len] = 0;
    try testing.expectError(Error.InvalidSnapshot, decodeSnapshot(allocator, padded));
    try testing.expectError(
        Error.InvalidSnapshot,
        decodeSnapshot(allocator, encoded[0 .. encoded.len - 1]),
    );
}

test "validate rejects cycles, dangling bindings, and type mismatches" {
    const allocator = testing.allocator;

    // A texel bound to a missing source.
    var dangling = Texel.init(TexelId.generate(std.testing.io));
    defer dangling.deinit(allocator);
    var input = try InputPort.init(allocator, "input", .text);
    try input.bind(allocator, try Fiber.init(allocator, TexelId.generate(std.testing.io), "value"));
    try dangling.putInput(allocator, input);
    try testing.expectError(
        Error.InvalidSnapshot,
        validateSnapshot(allocator, &[_]Texel{dangling}, &.{}),
    );

    // A two-texel cycle.
    var first = Texel.init(TexelId.generate(std.testing.io));
    defer first.deinit(allocator);
    var second = Texel.init(TexelId.generate(std.testing.io));
    defer second.deinit(allocator);
    try first.putOutput(allocator, try OutputPort.init(allocator, "value", .text));
    try second.putOutput(allocator, try OutputPort.init(allocator, "value", .text));
    var first_input = try InputPort.init(allocator, "input", .text);
    try first_input.bind(allocator, try Fiber.init(allocator, second.id, "value"));
    try first.putInput(allocator, first_input);
    var second_input = try InputPort.init(allocator, "input", .text);
    try second_input.bind(allocator, try Fiber.init(allocator, first.id, "value"));
    try second.putInput(allocator, second_input);
    try testing.expectError(
        Error.InvalidSnapshot,
        validateSnapshot(allocator, &[_]Texel{ first, second }, &.{}),
    );

    // A binding whose types disagree.
    var int_source = Texel.init(TexelId.generate(std.testing.io));
    defer int_source.deinit(allocator);
    try int_source.putOutput(allocator, try OutputPort.init(allocator, "value", .int));
    var text_consumer = Texel.init(TexelId.generate(std.testing.io));
    defer text_consumer.deinit(allocator);
    var mismatched = try InputPort.init(allocator, "input", .text);
    try mismatched.bind(allocator, try Fiber.init(allocator, int_source.id, "value"));
    try text_consumer.putInput(allocator, mismatched);
    try testing.expectError(
        Error.InvalidSnapshot,
        validateSnapshot(allocator, &[_]Texel{ int_source, text_consumer }, &.{}),
    );
}
