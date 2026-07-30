//! The .lc module format — a verified Luce program on disk.
//!
//! `luce build` encodes a compiled ir.Program into a compact binary
//! module; `loom` decodes it back and runs it.  The format is a direct
//! serialization of the IR: constants, struct layouts, functions with
//! their instruction pools and blocks, the Port schema, and the entry
//! function.  Decoding re-runs the IR verifier, so a damaged or
//! hand-forged module is rejected instead of executed; instruction
//! *types* beyond the verifier's checks are trusted, so treat .lc
//! files like executables — run only what you built or trust.
//!
//! Any change to the instruction set, the intrinsic list, or the trap
//! codes must bump `format_version`; there is no migration, a stale
//! module simply recompiles from its .luc source.

const std = @import("std");
const ir = @import("ir.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

pub const magic = "LUCE";
pub const format_version: u32 = 8;

pub const DecodeError = error{
    OutOfMemory,
    InvalidModule,
    UnsupportedVersion,
};

// ---------------------------------------------------------------------------
// Encode
// ---------------------------------------------------------------------------

/// Serialize a verified program.  The caller owns the returned bytes.
pub fn encode(gpa: Allocator, program: *const ir.Program) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var writer: Writer = .{ .gpa = gpa, .out = &out };

    try writer.bytes(magic);
    try writer.int(u32, format_version);

    try writer.int(u32, @intCast(program.constants.len));
    for (program.constants) |constant| try writer.blob(constant);

    try writer.int(u32, @intCast(program.structs.len));
    for (program.structs) |layout| {
        try writer.blob(layout.name);
        try writer.int(u32, @intCast(layout.fields.len));
        for (layout.fields) |field| {
            try writer.blob(field.name);
            try writer.valueType(field.field_type);
        }
    }

    try writer.int(u32, @intCast(program.heap_types.len));
    for (program.heap_types) |descriptor| try writer.heapType(descriptor);

    try writer.ports(program.inputs);
    try writer.ports(program.outputs);
    try writer.int(u32, @intCast(program.reads.len));
    for (program.reads) |read| try writer.int(u32, read);

    try writer.int(u32, @intCast(program.functions.len));
    for (program.functions) |*function| try writer.function(function);
    try writer.int(u32, program.entry_function);

    return out.toOwnedSlice(gpa);
}

const Writer = struct {
    gpa: Allocator,
    out: *std.ArrayList(u8),

    fn bytes(self: *Writer, data: []const u8) error{OutOfMemory}!void {
        try self.out.appendSlice(self.gpa, data);
    }

    fn int(self: *Writer, comptime T: type, value: T) error{OutOfMemory}!void {
        var encoded: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &encoded, value, .little);
        try self.out.appendSlice(self.gpa, &encoded);
    }

    fn blob(self: *Writer, data: []const u8) error{OutOfMemory}!void {
        try self.int(u32, @intCast(data.len));
        try self.bytes(data);
    }

    fn valueType(self: *Writer, of: types.Type) error{OutOfMemory}!void {
        try self.int(u8, @intFromEnum(std.meta.activeTag(of)));
        if (of == .strukt) try self.int(u32, of.strukt);
        if (of == .heap) try self.int(u32, of.heap);
    }

    fn heapType(self: *Writer, descriptor: types.HeapType) error{OutOfMemory}!void {
        try self.int(u8, @intFromEnum(std.meta.activeTag(descriptor)));
        switch (descriptor) {
            .list => |element| try self.valueType(element),
            .map => |pair| {
                try self.valueType(pair.key);
                try self.valueType(pair.value);
            },
            .array => |shape| {
                try self.valueType(shape.element);
                try self.int(u8, shape.rank);
            },
            .builder => {},
        }
    }

    fn ports(self: *Writer, declared: []const types.Port) error{OutOfMemory}!void {
        try self.int(u32, @intCast(declared.len));
        for (declared) |port| {
            try self.blob(port.name);
            try self.int(u8, @intFromEnum(port.declared));
        }
    }

    fn registers(self: *Writer, list: []const ir.Register) error{OutOfMemory}!void {
        try self.int(u32, @intCast(list.len));
        for (list) |register| try self.int(u32, register);
    }

    fn function(self: *Writer, of: *const ir.Function) error{OutOfMemory}!void {
        try self.blob(of.name);
        try self.int(u32, of.parameter_count);
        try self.valueType(of.return_type);

        try self.int(u32, @intCast(of.locals.len));
        for (of.locals) |local| {
            try self.blob(local.name);
            try self.valueType(local.local_type);
        }

        try self.int(u32, @intCast(of.instructions.len));
        for (of.instructions, of.result_types) |encoded, result_type| {
            try self.instruction(encoded);
            try self.valueType(result_type);
        }

        try self.int(u32, @intCast(of.blocks.len));
        for (of.blocks) |block| try self.registers(block.items);

        // Debug info: the source file name and one line:column per
        // instruction; a --release build writes "" and zero.
        try self.blob(of.source);
        try self.int(u32, @intCast(of.origins.len));
        for (of.origins) |origin| {
            try self.int(u32, origin.line);
            try self.int(u32, origin.column);
        }
    }

    fn instruction(self: *Writer, of: ir.Instruction) error{OutOfMemory}!void {
        try self.int(u8, @intFromEnum(std.meta.activeTag(of)));
        switch (of) {
            .const_boolean => |value| try self.int(u8, @intFromBool(value)),
            .const_int => |value| try self.int(i64, value),
            .const_float => |value| try self.int(u64, @bitCast(value)),
            .const_data => |data| {
                try self.int(u32, data.constant);
                try self.valueType(data.data_type);
            },
            .local_get => |local| try self.int(u32, local),
            .local_set => |set| {
                try self.int(u32, set.local);
                try self.int(u32, set.value);
            },
            .input_load => |port| try self.int(u32, port),
            .output_store => |store| {
                try self.int(u32, store.port);
                try self.int(u32, store.value);
            },
            .binary => |binary| {
                try self.int(u8, @intFromEnum(binary.op));
                try self.valueType(binary.operand_type);
                try self.int(u32, binary.left);
                try self.int(u32, binary.right);
            },
            .unary => |unary| {
                try self.int(u8, @intFromEnum(unary.op));
                try self.int(u32, unary.operand);
            },
            .convert => |convert| {
                try self.int(u8, @intFromEnum(convert.kind));
                try self.int(u32, convert.operand);
            },
            .struct_make => |make| {
                try self.int(u32, make.layout);
                try self.registers(make.fields);
            },
            .struct_get => |get| {
                try self.int(u32, get.target);
                try self.int(u32, get.layout);
                try self.int(u32, get.field);
            },
            .struct_set => |set| {
                try self.int(u32, set.target);
                try self.int(u32, set.layout);
                try self.int(u32, set.field);
                try self.int(u32, set.value);
            },
            .call => |call| {
                try self.int(u32, call.function);
                try self.registers(call.arguments);
            },
            .intrinsic => |intrinsic| {
                try self.int(u8, @intFromEnum(intrinsic.kind));
                try self.registers(intrinsic.arguments);
            },
            .heap_new => |new| {
                try self.int(u32, new.heap);
                try self.registers(new.dims);
            },
            .object_bind => |bind| {
                try self.int(u32, bind.local);
                try self.int(u32, bind.value);
            },
            .object_unbind => |unbind| {
                try self.int(u32, unbind.local);
                try self.int(u32, unbind.value);
            },
            .jump => |target| try self.int(u32, target),
            .branch => |branch| {
                try self.int(u32, branch.condition);
                try self.int(u32, branch.then_block);
                try self.int(u32, branch.else_block);
            },
            .ret => |value| {
                try self.int(u8, @intFromBool(value != null));
                if (value) |returned| try self.int(u32, returned);
            },
            .trap => |code| try self.int(u8, @intFromEnum(code)),
        }
    }
};

// ---------------------------------------------------------------------------
// Decode
// ---------------------------------------------------------------------------

/// Deserialize and verify a module.  The caller owns the returned
/// program (deinit); the program copies everything it keeps, so the
/// input bytes may be freed immediately.
pub fn decode(gpa: Allocator, data: []const u8) DecodeError!ir.Program {
    var program: ir.Program = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer program.deinit();
    const arena = program.arena.allocator();

    var reader: Reader = .{ .data = data };
    const found_magic = try reader.take(magic.len);
    if (!std.mem.eql(u8, found_magic, magic)) return error.InvalidModule;
    const version = try reader.int(u32);
    if (version != format_version) return error.UnsupportedVersion;

    const constant_count = try reader.count();
    const constants = try arena.alloc([]const u8, constant_count);
    for (constants) |*slot| slot.* = try arena.dupe(u8, try reader.blob());
    program.constants = constants;

    const struct_count = try reader.count();
    const structs = try arena.alloc(types.StructLayout, struct_count);
    for (structs) |*layout| {
        layout.name = try arena.dupe(u8, try reader.blob());
        const field_count = try reader.count();
        const fields = try arena.alloc(types.StructField, field_count);
        for (fields) |*field| {
            field.name = try arena.dupe(u8, try reader.blob());
            field.field_type = try reader.valueType();
        }
        layout.fields = fields;
    }
    program.structs = structs;

    const heap_count = try reader.count();
    const heap_types = try arena.alloc(types.HeapType, heap_count);
    for (heap_types) |*descriptor| descriptor.* = try reader.heapType();
    program.heap_types = heap_types;

    program.inputs = try reader.ports(arena);
    program.outputs = try reader.ports(arena);

    const read_count = try reader.count();
    const reads = try arena.alloc(u32, read_count);
    for (reads) |*slot| slot.* = try reader.int(u32);
    program.reads = reads;

    const function_count = try reader.count();
    const functions = try arena.alloc(ir.Function, function_count);
    for (functions) |*function| try reader.function(arena, function);
    program.functions = functions;
    program.entry_function = try reader.int(u32);
    if (reader.offset != data.len) return error.InvalidModule;

    ir.verify(gpa, &program) catch |mistake| switch (mistake) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModule,
    };
    return program;
}

const Reader = struct {
    data: []const u8,
    offset: usize = 0,

    /// Cap per-list allocation before contents are read, so a short
    /// hostile module cannot request absurd allocations up front.
    const max_count = 1 << 24;

    fn take(self: *Reader, length: usize) DecodeError![]const u8 {
        if (self.data.len - self.offset < length) return error.InvalidModule;
        const slice = self.data[self.offset .. self.offset + length];
        self.offset += length;
        return slice;
    }

    fn int(self: *Reader, comptime T: type) DecodeError!T {
        const raw = try self.take(@sizeOf(T));
        return std.mem.readInt(T, raw[0..@sizeOf(T)], .little);
    }

    fn count(self: *Reader) DecodeError!usize {
        const value = try self.int(u32);
        if (value > max_count) return error.InvalidModule;
        // Every list element costs at least one byte on the wire, so
        // a count larger than the remaining input is a lie — and
        // rejecting it here keeps decode's allocations proportional
        // to the input instead of trusting a four-byte field.
        if (value > self.data.len - self.offset) return error.InvalidModule;
        return value;
    }

    fn blob(self: *Reader) DecodeError![]const u8 {
        const length = try self.count();
        return self.take(length);
    }

    fn enumTag(self: *Reader, comptime T: type) DecodeError!T {
        const raw = try self.int(u8);
        return std.enums.fromInt(T, raw) orelse error.InvalidModule;
    }

    fn valueType(self: *Reader) DecodeError!types.Type {
        const tag = try self.enumTag(std.meta.Tag(types.Type));
        return switch (tag) {
            .none => .none,
            .boolean => .boolean,
            .int => .int,
            .float => .float,
            .string => .string,
            .bytes => .bytes,
            .strukt => .{ .strukt = try self.int(u32) },
            .heap => .{ .heap = try self.int(u32) },
        };
    }

    fn heapType(self: *Reader) DecodeError!types.HeapType {
        const tag = try self.enumTag(std.meta.Tag(types.HeapType));
        return switch (tag) {
            .list => .{ .list = try self.valueType() },
            .map => .{ .map = .{
                .key = try self.valueType(),
                .value = try self.valueType(),
            } },
            .array => .{ .array = .{
                .element = try self.valueType(),
                .rank = try self.int(u8),
            } },
            .builder => .builder,
        };
    }

    fn ports(self: *Reader, arena: Allocator) DecodeError![]types.Port {
        const port_count = try self.count();
        const declared = try arena.alloc(types.Port, port_count);
        for (declared) |*port| {
            port.name = try arena.dupe(u8, try self.blob());
            port.declared = try self.enumTag(types.PortType);
        }
        return declared;
    }

    fn registers(self: *Reader, arena: Allocator) DecodeError![]ir.Register {
        const register_count = try self.count();
        const list = try arena.alloc(ir.Register, register_count);
        for (list) |*register| register.* = try self.int(u32);
        return list;
    }

    fn function(self: *Reader, arena: Allocator, out: *ir.Function) DecodeError!void {
        out.name = try arena.dupe(u8, try self.blob());
        out.parameter_count = try self.int(u32);
        out.return_type = try self.valueType();

        const local_count = try self.count();
        const locals = try arena.alloc(ir.Local, local_count);
        for (locals) |*local| {
            local.name = try arena.dupe(u8, try self.blob());
            local.local_type = try self.valueType();
        }
        out.locals = locals;

        const instruction_count = try self.count();
        const instructions = try arena.alloc(ir.Instruction, instruction_count);
        const result_types = try arena.alloc(types.Type, instruction_count);
        for (instructions, result_types) |*decoded, *result_type| {
            decoded.* = try self.instruction(arena);
            result_type.* = try self.valueType();
        }
        out.instructions = instructions;
        out.result_types = result_types;

        const block_count = try self.count();
        const blocks = try arena.alloc(ir.Block, block_count);
        for (blocks) |*block| block.items = try self.registers(arena);
        out.blocks = blocks;

        // Debug info is all-or-nothing per function; reject a table
        // that disagrees with the instruction count before allocating.
        out.source = try arena.dupe(u8, try self.blob());
        const origin_count = try self.count();
        if (origin_count != 0 and origin_count != instruction_count) return error.InvalidModule;
        const origins = try arena.alloc(ir.Origin, origin_count);
        for (origins) |*origin| {
            origin.line = try self.int(u32);
            origin.column = try self.int(u32);
        }
        out.origins = origins;
    }

    fn instruction(self: *Reader, arena: Allocator) DecodeError!ir.Instruction {
        const tag = try self.enumTag(std.meta.Tag(ir.Instruction));
        return switch (tag) {
            .const_boolean => .{ .const_boolean = (try self.int(u8)) != 0 },
            .const_int => .{ .const_int = try self.int(i64) },
            .const_float => .{ .const_float = @bitCast(try self.int(u64)) },
            .const_data => .{ .const_data = .{
                .constant = try self.int(u32),
                .data_type = try self.valueType(),
            } },
            .local_get => .{ .local_get = try self.int(u32) },
            .local_set => .{ .local_set = .{
                .local = try self.int(u32),
                .value = try self.int(u32),
            } },
            .input_load => .{ .input_load = try self.int(u32) },
            .output_store => .{ .output_store = .{
                .port = try self.int(u32),
                .value = try self.int(u32),
            } },
            .binary => .{ .binary = .{
                .op = try self.enumTag(ir.BinaryOp),
                .operand_type = try self.valueType(),
                .left = try self.int(u32),
                .right = try self.int(u32),
            } },
            .unary => .{ .unary = .{
                .op = try self.enumTag(ir.UnaryOp),
                .operand = try self.int(u32),
            } },
            .convert => .{ .convert = .{
                .kind = try self.enumTag(ir.ConvertKind),
                .operand = try self.int(u32),
            } },
            .struct_make => .{ .struct_make = .{
                .layout = try self.int(u32),
                .fields = try self.registers(arena),
            } },
            .struct_get => .{ .struct_get = .{
                .target = try self.int(u32),
                .layout = try self.int(u32),
                .field = try self.int(u32),
            } },
            .struct_set => .{ .struct_set = .{
                .target = try self.int(u32),
                .layout = try self.int(u32),
                .field = try self.int(u32),
                .value = try self.int(u32),
            } },
            .call => .{ .call = .{
                .function = try self.int(u32),
                .arguments = try self.registers(arena),
            } },
            .intrinsic => .{ .intrinsic = .{
                .kind = try self.enumTag(ir.Intrinsic),
                .arguments = try self.registers(arena),
            } },
            .heap_new => .{ .heap_new = .{
                .heap = try self.int(u32),
                .dims = try self.registers(arena),
            } },
            .object_bind => .{ .object_bind = .{
                .local = try self.int(u32),
                .value = try self.int(u32),
            } },
            .object_unbind => .{ .object_unbind = .{
                .local = try self.int(u32),
                .value = try self.int(u32),
            } },
            .jump => .{ .jump = try self.int(u32) },
            .branch => .{ .branch = .{
                .condition = try self.int(u32),
                .then_block = try self.int(u32),
                .else_block = try self.int(u32),
            } },
            .ret => blk: {
                const has_value = (try self.int(u8)) != 0;
                break :blk .{ .ret = if (has_value) try self.int(u32) else null };
            },
            .trap => .{ .trap = try self.enumTag(ir.TrapCode) },
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const compile_mod = @import("compile.zig");
const backend = @import("backend.zig");

fn compileScript(source: []const u8) !ir.Program {
    var result = try compile_mod.compile(testing.allocator, source, .{}, .{
        .entry_mode = .script,
        .allow_host = true,
    });
    switch (result) {
        .success => |program| return program,
        .failure => |*diagnostics| {
            const rendered = try diagnostics.render(testing.allocator, source);
            defer testing.allocator.free(rendered);
            std.debug.print("unexpected diagnostics:\n{s}", .{rendered});
            result.deinit();
            return error.TestUnexpectedResult;
        },
    }
}

test "a compiled program round-trips through the module format" {
    const source =
        \\struct Point:
        \\    x: Float
        \\    y: Float
        \\
        \\func length(point: Point) -> Float:
        \\    return sqrt(point.x * point.x + point.y * point.y)
        \\
        \\func main():
        \\    var point = Point(x = 3.0, y = 4.0)
        \\    point.x = 6.0
        \\    var total = 0
        \\    for index in range(0, 5):
        \\        if index % 2 == 0:
        \\            total = total + index
        \\    print("length ready")
        \\    let text = "π = " + "3.14159"[0:4]
        \\    var points = new List(Float)
        \\    points.append(length(point))
        \\    var counts = new Map(String, Int)
        \\    counts[text] = len(points)
        \\    var grid = new Array(Int, 2, 3)
        \\    grid[1, 2] = total
        \\    for value in points:
        \\        total = total + Int(value)
        \\    free(points)
        \\    free(counts)
        \\    free(grid)
        \\
    ;
    var program = try compileScript(source);
    defer program.deinit();

    const encoded = try encode(testing.allocator, &program);
    defer testing.allocator.free(encoded);

    var loaded = try decode(testing.allocator, encoded);
    defer loaded.deinit();

    // The decoded program prints identically — same structs, functions,
    // instructions, and constants.
    const original_dump = try ir.print(testing.allocator, &program);
    defer testing.allocator.free(original_dump);
    const loaded_dump = try ir.print(testing.allocator, &loaded);
    defer testing.allocator.free(loaded_dump);
    try testing.expectEqualStrings(original_dump, loaded_dump);

    // Encoding the decoded program is byte-identical: the format is a
    // fixed point.
    const again = try encode(testing.allocator, &loaded);
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(u8, encoded, again);
}

test "debug origins round-trip; strip removes them and shrinks the module" {
    var program = try compileScript(
        \\func double(value: Int) -> Int:
        \\    return value * 2
        \\
        \\func main():
        \\    let sum = double(4) + double(5)
        \\
    );
    defer program.deinit();

    const debug_encoded = try encode(testing.allocator, &program);
    defer testing.allocator.free(debug_encoded);
    var debug_loaded = try decode(testing.allocator, debug_encoded);
    defer debug_loaded.deinit();
    for (debug_loaded.functions, program.functions) |loaded, original| {
        try testing.expectEqualStrings(original.source, loaded.source);
        try testing.expectEqual(original.instructions.len, loaded.origins.len);
        try testing.expectEqualSlices(ir.Origin, original.origins, loaded.origins);
    }
    // Bench compiles without a source_name; the root falls back.
    try testing.expectEqualStrings("main.luc", debug_loaded.functions[0].source);

    ir.strip(&program);
    const release_encoded = try encode(testing.allocator, &program);
    defer testing.allocator.free(release_encoded);
    try testing.expect(release_encoded.len < debug_encoded.len);
    var release_loaded = try decode(testing.allocator, release_encoded);
    defer release_loaded.deinit();
    for (release_loaded.functions) |function| {
        try testing.expectEqual(@as(usize, 0), function.origins.len);
        try testing.expectEqualStrings("", function.source);
    }
}

test "an origins table that disagrees with the instruction count is rejected" {
    var program = try compileScript(
        \\func main():
        \\    print("hi")
        \\
    );
    defer program.deinit();
    // Damage in memory, then encode: one origin too few.
    const function = &program.functions[0];
    function.origins = function.origins[0 .. function.origins.len - 1];
    const encoded = try encode(testing.allocator, &program);
    defer testing.allocator.free(encoded);
    try testing.expectError(error.InvalidModule, decode(testing.allocator, encoded));
}

test "a decoded module runs behind the backend boundary" {
    var program = try compileScript(
        \\func double(value: Int) -> Int:
        \\    return value * 2
        \\
        \\func main():
        \\    assert(double(21) == 42)
        \\
    );
    defer program.deinit();
    const encoded = try encode(testing.allocator, &program);
    defer testing.allocator.free(encoded);
    var loaded = try decode(testing.allocator, encoded);
    defer loaded.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try backend.evaluate(arena.allocator(), &loaded, &.{}, &.{}, .{});
    try testing.expect(result == .success);
}

test "truncated, oversold, and damaged modules are rejected" {
    var program = try compileScript(
        \\func main():
        \\    return
        \\
    );
    defer program.deinit();
    const encoded = try encode(testing.allocator, &program);
    defer testing.allocator.free(encoded);

    // Wrong magic.
    var wrong_magic = try testing.allocator.dupe(u8, encoded);
    defer testing.allocator.free(wrong_magic);
    wrong_magic[0] = 'X';
    try testing.expectError(error.InvalidModule, decode(testing.allocator, wrong_magic));

    // Future version.
    var future = try testing.allocator.dupe(u8, encoded);
    defer testing.allocator.free(future);
    future[4] = 0xff;
    try testing.expectError(error.UnsupportedVersion, decode(testing.allocator, future));

    // Every truncation fails cleanly instead of crashing.
    var length = encoded.len;
    while (length > 0) : (length -= 1) {
        try testing.expectError(error.InvalidModule, decode(testing.allocator, encoded[0..length -| 1]));
    }

    // Trailing garbage is rejected too.
    const padded = try std.mem.concat(testing.allocator, u8, &.{ encoded, "extra" });
    defer testing.allocator.free(padded);
    try testing.expectError(error.InvalidModule, decode(testing.allocator, padded));
}

test "a damaged register reference fails verification, not execution" {
    var program = try compileScript(
        \\func main():
        \\    let value = 1 + 2
        \\
    );
    defer program.deinit();

    // Corrupt an operand register to point far out of range; the
    // decoder's verifier pass must reject the module.
    program.functions[0].instructions[2] = .{ .binary = .{
        .op = .add,
        .operand_type = .int,
        .left = 900,
        .right = 901,
    } };
    const encoded = try encode(testing.allocator, &program);
    defer testing.allocator.free(encoded);
    try testing.expectError(error.InvalidModule, decode(testing.allocator, encoded));
}

// A compact program touching every interesting wire shape: structs,
// heap types, intrinsics, calls, branches, ownership instructions.
const mutation_source =
    \\struct Point:
    \\    x: Float
    \\    tag: String
    \\
    \\func total(values: List(Int)) -> Int:
    \\    var sum = 0
    \\    for value in values:
    \\        sum = sum + value
    \\    return sum
    \\
    \\func main():
    \\    var xs = [3, 1, 2]
    \\    xs.sort()
    \\    var ages = new Map(String, Int)
    \\    ages["ada"] = total(xs)
    \\    let point = Point(x = sqrt(4.0), tag = "p"[0:1])
    \\    if point.x > 1.0 and ages.has("ada"):
    \\        xs.append(Int(point.x))
    \\    assert(total(xs) == 8)
    \\
;

test "single-byte damage is rejected or runs to a clean outcome — never a crash" {
    var program = try compileScript(mutation_source);
    defer program.deinit();
    const encoded = try encode(testing.allocator, &program);
    defer testing.allocator.free(encoded);

    // Every byte, six adversarial values: decode must reject or the
    // program must terminate as success/trap within budget.  This is
    // the corpus-mode stand-in for fuzzing the trust boundary; any
    // panic here is a verifier hole (a real one was found this way).
    for (0..encoded.len) |index| {
        for ([_]u8{ 0x00, 0x01, 0x02, 0x7f, 0x80, 0xff }) |value| {
            if (encoded[index] == value) continue;
            const mutant = try testing.allocator.dupe(u8, encoded);
            defer testing.allocator.free(mutant);
            mutant[index] = value;
            var decoded = decode(testing.allocator, mutant) catch continue;
            defer decoded.deinit();
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const outputs = try arena.allocator().alloc(?backend.RuntimeValue, decoded.outputs.len);
            @memset(outputs, null);
            _ = try backend.evaluate(arena.allocator(), &decoded, &.{}, outputs, .{
                .steps = 50_000,
                .call_depth = 64,
            });
        }
    }
}

test "decode allocates in proportion to its input" {
    var program = try compileScript(mutation_source);
    defer program.deinit();
    const encoded = try encode(testing.allocator, &program);
    defer testing.allocator.free(encoded);

    // A one-byte flip must never turn a small module into a huge
    // allocation request: counts are bounded by the remaining input.
    const cap = 64 * encoded.len + 4096;
    const scratch = try testing.allocator.alloc(u8, cap);
    defer testing.allocator.free(scratch);
    for (0..encoded.len) |index| {
        for ([_]u8{ 0x00, 0x01, 0x7f, 0x80, 0xff }) |value| {
            if (encoded[index] == value) continue;
            const mutant = try testing.allocator.dupe(u8, encoded);
            defer testing.allocator.free(mutant);
            mutant[index] = value;
            var fixed = std.heap.FixedBufferAllocator.init(scratch);
            if (decode(fixed.allocator(), mutant)) |decoded| {
                var owned = decoded;
                owned.deinit();
            } else |mistake| {
                try testing.expect(mistake != error.OutOfMemory);
            }
        }
    }
}

test "the wire surface is fingerprinted: change it, bump format_version" {
    var hasher = std.hash.Wyhash.init(0);
    inline for (comptime std.meta.fieldNames(ir.Instruction)) |name| hasher.update(name);
    inline for (comptime std.meta.fieldNames(ir.Intrinsic)) |name| hasher.update(name);
    inline for (comptime std.meta.fieldNames(ir.TrapCode)) |name| hasher.update(name);
    // If this fails you changed the instruction set, the intrinsics,
    // or the trap codes: bump format_version and update BOTH numbers.
    try testing.expectEqual(@as(u32, 8), format_version);
    try testing.expectEqual(@as(u64, 13456387974860105935), hasher.final());
}
