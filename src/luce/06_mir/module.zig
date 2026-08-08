//! The serialized module — a verified Luce program between the
//! compiler's two halves.
//!
//! The format is a direct serialization of the IR: constants, struct
//! layouts, heap-type shapes, functions with their instruction pools
//! and blocks, and the entry function.  Decoding re-runs the IR
//! verifier, so a damaged or hand-forged module is rejected instead of
//! executed; instruction *types* beyond the verifier's checks are
//! trusted, so treat a module like an executable — decode only what
//! you built or trust.
//!
//! **It is a seam, not a deliverable.**  What `luce build` writes is
//! machine code (`docs/CODEGEN.md`); these bytes are the front end's
//! hand-over to the back end and the artifact's cache key.  Two things
//! ride on them and nothing else does: `artifact.sourceHash` names the
//! program an artifact was built from, and `loom` hands the compiler a
//! module rather than a source file, which is what lets loom carry no
//! code generator (`apps/loom/runner.zig`).  When one has to reach a
//! disk on the way it is written as `.lcm` (`extension` below).
//!
//! Any change to the instruction set, the intrinsic list, or the trap
//! codes must bump `format_version`; there is no migration, a stale
//! module simply recompiles from its .luc source.

const std = @import("std");
const mir = @import("../06_mir.zig");
const types = @import("../support/types.zig");

const Allocator = std.mem.Allocator;

pub const magic = "LUCE";
/// 18 — `key_read` answers `string?` rather than `string`.  The
/// intrinsic list is unchanged and the wire shape with it, but the
/// *type* the verifier demands of `key_read`'s result is not, so a
/// module written under 17 would either fail verification or, worse,
/// pass it and lower against the wrong shape.
///
/// 20 — the command line stopped being an ambient service and became
/// `main`'s parameter (docs/METHODS.md).  Two intrinsics left the set
/// (`arg_count`, `arg_get`) and one trap code with them
/// (`argument_bounds`), so every instruction tag after them renumbers;
/// the entry may now carry one parameter, which the verifier checks.
///
/// 22 — `byte`, `short` and `half` join `types.Type` (docs/TYPES.md
/// step 5).  A type travels as a bare `u8` of its tag's ordinal, and
/// the three land *in ladder order* rather than on the end, so every
/// tag from `int` up renumbers.  That is safe here for exactly one
/// reason and it is this line: the version moved with them, so a
/// module written under 21 is refused by name instead of decoded
/// against the wrong tags.  Appending would have been the rule had
/// the version *not* moved — it is what `runtime.Value.Tag`, which is
/// ABI rather than wire, still does.
///
/// 25 — `exit_program` joins the intrinsics (docs/LANGUAGE.md's
/// fourth way a run ends), appended inside the host group, so every
/// tag after `dir_list` renumbers under the same one-line warrant.
/// 27 — the bit set arrives (docs/BITWISE.md): five `BinaryOp` tags
/// and one `UnaryOp`, appended, plus `shift_out_of_range` in the trap
/// codes, appended likewise.
///
/// 28 — enums arrive (docs/ENUMS.md).  A table of them joins the
/// program between the heap types and the functions, and
/// `types.Type` grows a tag for one — placed beside `strukt` and
/// `heap`, which are the other two types that index a table, so
/// `optional` renumbers.  Safe for the reason 22's note gives and no
/// other: the version moved with it.
/// 30 — threads arrive (docs/THREADS.md).  One instruction (`spawn`,
/// beside `call` because it is one), one intrinsic (`task_wait`), and
/// one heap type (`task`, carrying the spawned function's result type
/// and its fallibility) — all appended, and the version moves with
/// them because `Instruction` is written by tag ordinal and `spawn`
/// lands in the middle of the union rather than on the end.
///
/// 31 — function values arrive (docs/FUNCTIONS.md).  A table of
/// signatures joins the program between the enums and the functions,
/// `types.Type` grows a tag for one — placed beside `enumeration`,
/// which is the other type that indexes a table, so `optional`
/// renumbers — and two instructions join `Instruction`: `const_function`
/// beside the other constants and `call_indirect` beside `call`, both in
/// the middle of the union rather than on the end.  Safe for the reason
/// 22's note gives and no other: the version moved with them.
pub const format_version: u32 = 31;

/// What a serialized module is called when it has to sit on a disk.
/// Named here because this file owns the format, and named at all
/// because two processes have to agree on it: `loom` writes one and
/// `luce build` reads it back (`docs/CODEGEN.md`).
pub const extension = ".lcm";

pub const DecodeError = error{
    OutOfMemory,
    InvalidModule,
    UnsupportedVersion,
};

// ---------------------------------------------------------------------------
// Encode
// ---------------------------------------------------------------------------

/// Serialize a verified program.  The caller owns the returned bytes.
pub fn encode(gpa: Allocator, program: *const mir.Program) error{OutOfMemory}![]u8 {
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

    try writer.int(u32, @intCast(program.enums.len));
    for (program.enums) |declared| {
        try writer.blob(declared.name);
        try writer.int(u8, @intFromEnum(declared.backing));
        try writer.int(u32, @intCast(declared.members.len));
        for (declared.members) |member| {
            try writer.blob(member.name);
            try writer.int(i64, member.value);
        }
    }

    try writer.int(u32, @intCast(program.signatures.len));
    for (program.signatures) |signature| {
        try writer.int(u32, @intCast(signature.parameters.len));
        for (signature.parameters) |parameter| {
            try writer.valueType(parameter.value_type);
            try writer.int(u8, @intFromBool(parameter.gives));
        }
        try writer.valueType(signature.result);
    }

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
        if (of == .function) try self.int(u32, of.function);
        // The width travels with the index, as it does in memory: the
        // decoder rebuilds the whole reference without reaching into
        // the enum table, which is read later in the stream.
        if (of == .enumeration) {
            try self.int(u32, of.enumeration.index);
            try self.int(u8, @intFromEnum(of.enumeration.backing));
        }
        // A `T?` writes its payload as a type of its own, which cannot
        // be optional in turn: one tag byte, then the payload's.
        if (of == .optional) try self.valueType(of.optional.asType());
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
            .builder, .file => {},
            .task => |work| {
                try self.valueType(work.result);
                try self.int(u8, @intFromBool(work.fallible));
            },
        }
    }

    fn registers(self: *Writer, list: []const mir.Register) error{OutOfMemory}!void {
        try self.int(u32, @intCast(list.len));
        for (list) |register| try self.int(u32, register);
    }

    fn function(self: *Writer, of: *const mir.Function) error{OutOfMemory}!void {
        try self.blob(of.name);
        try self.int(u32, of.parameter_count);
        try self.valueType(of.return_type);
        try self.int(u8, @intFromBool(of.fallible));

        try self.int(u32, @intCast(of.locals.len));
        for (of.locals) |local| {
            try self.blob(local.name);
            try self.valueType(local.local_type);
            try self.int(u8, @intFromBool(local.owns_storage));
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

    fn instruction(self: *Writer, of: mir.Instruction) error{OutOfMemory}!void {
        try self.int(u8, @intFromEnum(std.meta.activeTag(of)));
        switch (of) {
            .const_boolean => |value| try self.int(u8, @intFromBool(value)),
            .const_long => |value| try self.int(i64, value),
            .const_double => |value| try self.int(u64, @bitCast(value)),
            .const_string => |constant| try self.int(u32, constant),
            .const_function => |named| try self.int(u32, named),
            .local_get => |local| try self.int(u32, local),
            .local_set => |set| {
                try self.int(u32, set.local);
                try self.int(u32, set.value);
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
            .convert => |operand| try self.int(u32, operand),
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
            .call, .spawn => |call| {
                try self.int(u32, call.function);
                try self.registers(call.arguments);
            },
            .call_indirect => |call| {
                try self.int(u32, call.callee);
                try self.int(u32, call.signature);
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
            .unwind => {},
        }
    }
};

// ---------------------------------------------------------------------------
// Decode
// ---------------------------------------------------------------------------

/// Deserialize and verify a module.  The caller owns the returned
/// program (deinit); the program copies everything it keeps, so the
/// input bytes may be freed immediately.
pub fn decode(gpa: Allocator, data: []const u8) DecodeError!mir.Program {
    var program: mir.Program = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
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

    const enum_count = try reader.count();
    const enums = try arena.alloc(types.EnumType, enum_count);
    for (enums) |*declared| {
        declared.name = try arena.dupe(u8, try reader.blob());
        declared.backing = try reader.enumTag(types.Type.EnumRef.Backing);
        const member_count = try reader.count();
        const members = try arena.alloc(types.EnumMember, member_count);
        for (members) |*member| {
            member.name = try arena.dupe(u8, try reader.blob());
            member.value = try reader.int(i64);
        }
        declared.members = members;
    }
    program.enums = enums;

    const signature_count = try reader.count();
    const signatures = try arena.alloc(types.Signature, signature_count);
    for (signatures) |*signature| {
        const parameter_count = try reader.count();
        const parameters = try arena.alloc(types.Signature.Parameter, parameter_count);
        for (parameters) |*parameter| {
            parameter.value_type = try reader.valueType();
            parameter.gives = (try reader.int(u8)) != 0;
        }
        signature.parameters = parameters;
        signature.result = try reader.valueType();
    }
    program.signatures = signatures;

    const function_count = try reader.count();
    const functions = try arena.alloc(mir.Function, function_count);
    for (functions) |*function| try reader.function(arena, function);
    program.functions = functions;
    program.entry_function = try reader.int(u32);
    if (reader.offset != data.len) return error.InvalidModule;

    mir.verify(gpa, &program) catch |mistake| switch (mistake) {
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
            .byte => .byte,
            .short => .short,
            .int => .int,
            .long => .long,
            .half => .half,
            .float => .float,
            .double => .double,
            .string => .string,
            .strukt => .{ .strukt = try self.int(u32) },
            .heap => .{ .heap = try self.int(u32) },
            .function => .{ .function = try self.int(u32) },
            .enumeration => .{ .enumeration = .{
                .index = try self.int(u32),
                .backing = try self.enumTag(types.Type.EnumRef.Backing),
            } },
            // `T??` has no representation, so a payload that decodes
            // as optional is a damaged module, not a nested one.
            .optional => types.Type.optionalOf(try self.valueType()) orelse
                return error.InvalidModule,
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
            .file => .file,
            .task => .{ .task = .{
                .result = try self.valueType(),
                .fallible = (try self.int(u8)) != 0,
            } },
        };
    }

    fn registers(self: *Reader, arena: Allocator) DecodeError![]mir.Register {
        const register_count = try self.count();
        const list = try arena.alloc(mir.Register, register_count);
        for (list) |*register| register.* = try self.int(u32);
        return list;
    }

    fn function(self: *Reader, arena: Allocator, out: *mir.Function) DecodeError!void {
        out.name = try arena.dupe(u8, try self.blob());
        out.parameter_count = try self.int(u32);
        out.return_type = try self.valueType();
        out.fallible = (try self.int(u8)) != 0;

        const local_count = try self.count();
        const locals = try arena.alloc(mir.Local, local_count);
        for (locals) |*local| {
            local.name = try arena.dupe(u8, try self.blob());
            local.local_type = try self.valueType();
            local.owns_storage = (try self.int(u8)) != 0;
        }
        out.locals = locals;

        const instruction_count = try self.count();
        const instructions = try arena.alloc(mir.Instruction, instruction_count);
        const result_types = try arena.alloc(types.Type, instruction_count);
        for (instructions, result_types) |*decoded, *result_type| {
            decoded.* = try self.instruction(arena);
            result_type.* = try self.valueType();
        }
        out.instructions = instructions;
        out.result_types = result_types;

        const block_count = try self.count();
        const blocks = try arena.alloc(mir.Block, block_count);
        for (blocks) |*block| block.items = try self.registers(arena);
        out.blocks = blocks;

        // Debug info is all-or-nothing per function; reject a table
        // that disagrees with the instruction count before allocating.
        out.source = try arena.dupe(u8, try self.blob());
        const origin_count = try self.count();
        if (origin_count != 0 and origin_count != instruction_count) return error.InvalidModule;
        const origins = try arena.alloc(mir.Origin, origin_count);
        for (origins) |*origin| {
            origin.line = try self.int(u32);
            origin.column = try self.int(u32);
        }
        out.origins = origins;
    }

    fn instruction(self: *Reader, arena: Allocator) DecodeError!mir.Instruction {
        const tag = try self.enumTag(std.meta.Tag(mir.Instruction));
        return switch (tag) {
            .const_boolean => .{ .const_boolean = (try self.int(u8)) != 0 },
            .const_long => .{ .const_long = try self.int(i64) },
            .const_double => .{ .const_double = @bitCast(try self.int(u64)) },
            .const_string => .{ .const_string = try self.int(u32) },
            .const_function => .{ .const_function = try self.int(u32) },
            .local_get => .{ .local_get = try self.int(u32) },
            .local_set => .{ .local_set = .{
                .local = try self.int(u32),
                .value = try self.int(u32),
            } },
            .binary => .{ .binary = .{
                .op = try self.enumTag(mir.BinaryOp),
                .operand_type = try self.valueType(),
                .left = try self.int(u32),
                .right = try self.int(u32),
            } },
            .unary => .{ .unary = .{
                .op = try self.enumTag(mir.UnaryOp),
                .operand = try self.int(u32),
            } },
            .convert => .{ .convert = try self.int(u32) },
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
            .spawn => .{ .spawn = .{
                .function = try self.int(u32),
                .arguments = try self.registers(arena),
            } },
            .call_indirect => .{ .call_indirect = .{
                .callee = try self.int(u32),
                .signature = try self.int(u32),
                .arguments = try self.registers(arena),
            } },
            .intrinsic => .{ .intrinsic = .{
                .kind = try self.enumTag(mir.Intrinsic),
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
            .trap => .{ .trap = try self.enumTag(mir.TrapCode) },
            .unwind => .unwind,
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const compile_mod = @import("../compile.zig");
const interpreter = @import("../interpreter.zig");

fn compileScript(source: []const u8) !mir.Program {
    var result = try compile_mod.compile(testing.allocator, source, .{
        .allow_host = true,
    });
    switch (result) {
        .success => |program| return program,
        .failure => |*diagnostics| {
            const rendered = try diagnostics.render(testing.allocator);
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
        \\    x: double
        \\    y: double
        \\
        \\func length(point: Point) -> double:
        \\    return sqrt(point.x * point.x + point.y * point.y)
        \\
        \\func main():
        \\    var point = Point(x = 3.0, y = 4.0)
        \\    point.x = 6.0
        \\    var total: long = 0
        \\    for index in range(0, 5):
        \\        if index % 2 == 0:
        \\            total = total + index
        \\    print("length ready")
        \\    let text = "π = " + "3.14159"[0:4]
        \\    var points = new list(double)
        \\    points.append(length(point))
        \\    var counts = new map(string, long)
        \\    counts[text] = len(points)
        \\    var grid = new array(long, 2, 3)
        \\    grid[1, 2] = total
        \\    for value in points:
        \\        total = total + long(value)
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
    const original_dump = try mir.print(testing.allocator, &program);
    defer testing.allocator.free(original_dump);
    const loaded_dump = try mir.print(testing.allocator, &loaded);
    defer testing.allocator.free(loaded_dump);
    try testing.expectEqualStrings(original_dump, loaded_dump);

    // Encoding the decoded program is byte-identical: the format is a
    // fixed point.
    const again = try encode(testing.allocator, &loaded);
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(u8, encoded, again);
}

test "an optional type round-trips with its payload, and T?? is rejected" {
    var program = try compileScript(
        \\struct Slot:
        \\    held: string?
        \\
        \\func widen(n: long) -> long?:
        \\    return n
        \\
        \\func main():
        \\    var counted: long? = none
        \\    counted = widen(3)
        \\    var slot = Slot(held = none)
        \\    slot.held = "there"
        \\    var listed: list(long)? = none
        \\    listed = new list(long)
        \\    listed.append(1)
        \\    assert((counted else 0) == 3)
        \\    assert(slot.held != none)
        \\    assert(len(listed) == 1)
        \\
    );
    defer program.deinit();

    const encoded = try encode(testing.allocator, &program);
    defer testing.allocator.free(encoded);
    var loaded = try decode(testing.allocator, encoded);
    defer loaded.deinit();

    const original_dump = try mir.print(testing.allocator, &program);
    defer testing.allocator.free(original_dump);
    const loaded_dump = try mir.print(testing.allocator, &loaded);
    defer testing.allocator.free(loaded_dump);
    try testing.expectEqualStrings(original_dump, loaded_dump);
    try testing.expect(std.mem.indexOf(u8, loaded_dump, "long?") != null);
    try testing.expect(std.mem.indexOf(u8, loaded_dump, "list(long)?") != null);

    const again = try encode(testing.allocator, &loaded);
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(u8, encoded, again);

    // A payload that decodes as optional is a damaged module: `T??`
    // has no representation, so it must be refused rather than nested.
    const nested = try testing.allocator.dupe(u8, encoded);
    defer testing.allocator.free(nested);
    const optional_tag: u8 = @intFromEnum(std.meta.activeTag(@as(types.Type, .{ .optional = .long })));
    var damaged = false;
    for (nested, 0..) |byte, at| {
        if (byte != optional_tag or at + 1 >= nested.len) continue;
        if (nested[at + 1] != optional_tag) {
            nested[at + 1] = optional_tag;
            damaged = true;
            break;
        }
    }
    try testing.expect(damaged);
    if (decode(testing.allocator, nested)) |decoded| {
        // Some byte positions are not a type tag at all, so the module
        // may still be well formed — but it must never hold a `T??`.
        var owned = decoded;
        defer owned.deinit();
        for (owned.functions) |function| {
            for (function.result_types) |of| try testing.expect(of.held() == null or of.held().? != .optional);
        }
    } else |mistake| {
        try testing.expect(mistake != error.OutOfMemory);
    }
}

test "debug origins round-trip; strip removes them and shrinks the module" {
    var program = try compileScript(
        \\func twice(value: long) -> long:
        \\    return value * 2
        \\
        \\func main():
        \\    let sum = twice(4) + twice(5)
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
        try testing.expectEqualSlices(mir.Origin, original.origins, loaded.origins);
    }
    // Bench compiles without a source_name; the root falls back.
    try testing.expectEqualStrings("main.luc", debug_loaded.functions[0].source);

    mir.strip(&program);
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

// A decoded module *running* is a fact about the language rather
// than about the format, so it is proved on both engines in
// `specs/format_spec.zig` — which also pins the round trip's bytes,
// because those bytes are the artifact key.

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
        .operand_type = .long,
        .left = 900,
        .right = 901,
    } };
    const encoded = try encode(testing.allocator, &program);
    defer testing.allocator.free(encoded);
    try testing.expectError(error.InvalidModule, decode(testing.allocator, encoded));
}

// A compact program touching every interesting wire shape: structs,
// heap types, intrinsics, calls, branches, ownership instructions.
//
// **Loop-free on purpose.**  The mutation test below runs what it
// decodes, and a run has to end for the suite to end.  Nothing bounds
// how long a Luce program runs — `while true:` is a legal program —
// so termination is a property of the corpus, not of the engine, and
// the corpus keeps it by being acyclic (see `forwardOnly`).
const mutation_source =
    \\struct Point:
    \\    x: double
    \\    tag: string
    \\
    \\func total(values: list(long)) -> long:
    \\    return values[0] + values[1] + values[2]
    \\
    \\func main():
    \\    var xs: list(long) = [3, 1, 2]
    \\    xs.sort()
    \\    var ages = new map(string, long)
    \\    ages["ada"] = total(xs)
    \\    let point = Point(x = sqrt(4.0), tag = "p"[0:1])
    \\    if point.x > 1.0 and ages.has("ada"):
    \\        xs.append(long(point.x))
    \\    assert(len(xs) == 4)
    \\
;

/// True when no terminator in `program` jumps to a block at or before
/// its own — which, with a call-depth bound in front of recursion, is
/// enough to make every run end.
///
/// The unmutated module satisfies this by construction and the test
/// asserts that it does; a flipped byte that turns a forward jump into
/// a back edge is skipped, because how long a damaged program runs is
/// not what this test is about and no engine promises it stops.
fn forwardOnly(program: *const mir.Program) bool {
    for (program.functions) |function| {
        for (function.blocks, 0..) |block, index| {
            const last = block.items[block.items.len - 1];
            switch (function.instructions[last]) {
                .jump => |target| if (target <= index) return false,
                .branch => |branch| {
                    if (branch.then_block <= index or branch.else_block <= index) return false;
                },
                else => {},
            }
        }
    }
    return true;
}

test "single-byte damage is rejected or runs to a clean outcome — never a crash" {
    var program = try compileScript(mutation_source);
    defer program.deinit();
    const encoded = try encode(testing.allocator, &program);
    defer testing.allocator.free(encoded);

    try testing.expect(forwardOnly(&program));

    // Every byte, six adversarial values: decode must reject or the
    // program must run to a clean success/trap.  This is the
    // corpus-mode stand-in for fuzzing the trust boundary; any panic
    // here is a verifier hole (a real one was found this way).
    //
    // **The interpreter is a sanitizer here, not a reference engine.**
    // Every test that runs a *Luce program* runs it on both engines
    // and compares them (docs/ENGINE.md, step 8); this one does not,
    // and the reason is that a mutant is not a Luce program: no source
    // produces it, nothing specifies what it should print, and the
    // lowering refuses damaged IR by design, so there is no second
    // arm to compare against and nothing for two engines to agree
    // about.  What is under test is the decoder's trust boundary, and
    // an engine that walks every instruction with bounds checks is
    // the instrument that finds a hole in it.
    var ran: usize = 0;
    var looping: usize = 0;
    for (0..encoded.len) |index| {
        for ([_]u8{ 0x00, 0x01, 0x02, 0x7f, 0x80, 0xff }) |value| {
            if (encoded[index] == value) continue;
            const mutant = try testing.allocator.dupe(u8, encoded);
            defer testing.allocator.free(mutant);
            mutant[index] = value;
            var decoded = decode(testing.allocator, mutant) catch continue;
            defer decoded.deinit();
            if (!forwardOnly(&decoded)) {
                looping += 1;
                continue;
            }
            ran += 1;
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            // Objects draw on the same arena as values here, and
            // deliberately: a damaged module may *leak* value storage
            // — an `own_storage` whose paired `local_set` a flipped
            // byte redirected leaves its bytes in a register nothing
            // sweeps (docs/STRINGS.md) — and this test is about
            // termination and crashes, not about reclamation.  Every
            // other suite runs the runtime under
            // `std.testing.allocator`, which is where reclamation is
            // proved.
            _ = try interpreter.run(
                .{ .arena = arena.allocator(), .objects = arena.allocator() },
                &decoded,
                .{ .call_depth = 64 },
                null,
            );
        }
    }

    // The skip is a narrow one — a handful of block-index bytes — and
    // saying so here is what keeps it from quietly swallowing the
    // corpus if the lowering or the format ever changes shape.
    try testing.expect(looping * 20 < ran);
}

test "decode allocates in proportion to its input" {
    var program = try compileScript(mutation_source);
    defer program.deinit();
    const encoded = try encode(testing.allocator, &program);
    defer testing.allocator.free(encoded);

    // A one-byte flip must never turn a small module into a huge
    // allocation request: every count is bounded by the remaining
    // input (`Reader.count`), so the whole decode is O(input) with the
    // widest decoded element as its constant.
    //
    // **That constant is computed rather than guessed.**  A magic
    // multiplier is a number that goes quietly wrong when a decoded
    // type grows a field, and this test would then fail for a reason
    // that has nothing to do with what it proves.  The arena never
    // reuses what it frees, so the headroom is a small multiple of the
    // bound rather than the bound itself.
    const widest = @max(
        @sizeOf(mir.Function),
        @sizeOf(mir.Instruction),
        @sizeOf(mir.Local),
        @sizeOf(mir.Block),
        @sizeOf(types.StructLayout),
        @sizeOf(types.StructField),
        @sizeOf(types.HeapType),
        @sizeOf(types.Type),
    );
    const cap = 8 * widest * encoded.len + 4096;
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
    inline for (comptime std.meta.fieldNames(mir.Instruction)) |name| hasher.update(name);
    inline for (comptime std.meta.fieldNames(mir.Intrinsic)) |name| hasher.update(name);
    inline for (comptime std.meta.fieldNames(mir.TrapCode)) |name| hasher.update(name);
    inline for (comptime std.meta.fieldNames(mir.ErrorCode)) |name| hasher.update(name);
    // **The type tags are wire surface too**: a type travels as the
    // ordinal of its tag (`Writer.valueType`), so adding, removing or
    // reordering one renumbers every tag after it — which is exactly
    // the silent misreading a version bump exists to prevent.  Enums
    // arriving is what showed this was missing: the instruction set did
    // not move an inch and the wire did.
    inline for (comptime std.meta.fieldNames(types.Type)) |name| hasher.update(name);
    inline for (comptime std.meta.fieldNames(types.HeapType)) |name| hasher.update(name);
    // And the signature table's own shape, for the same reason: a
    // parameter's verb travels as a byte beside its type, so a field
    // added to `Signature.Parameter` moves the wire (docs/FUNCTIONS.md).
    inline for (comptime std.meta.fieldNames(types.Signature)) |name| hasher.update(name);
    inline for (comptime std.meta.fieldNames(types.Signature.Parameter)) |name| hasher.update(name);
    // If this fails you changed the instruction set, the intrinsics,
    // or the trap or error codes: bump format_version and update BOTH
    // numbers.
    //
    // **It fingerprints the names and nothing else**, so it catches an
    // intrinsic added, removed or renamed and cannot catch one whose
    // *type* changed — `key_read` going from `string` to `string?`
    // moved this number and left the hash alone.  A version bump is
    // still required for that, and this test is not what will remind
    // you.
    try testing.expectEqual(@as(u32, 31), format_version);
    try testing.expectEqual(@as(u64, 12968420805031615277), hasher.final());
}

test "an enum round-trips with its members, and a foreign width is rejected" {
    var program = try compileScript(
        \\enum Method(byte):
        \\    stored = 0
        \\    deflated = 8
        \\
        \\func main():
        \\    var m = Method.stored
        \\    m = Method.deflated
        \\    var seen = new list(Method)
        \\    seen.append(m)
        \\    assert(seen[0] == Method.deflated)
        \\    assert(string(m) == "deflated")
        \\    assert(int(m) == 8)
        \\
    );
    defer program.deinit();

    const encoded = try encode(testing.allocator, &program);
    defer testing.allocator.free(encoded);
    var loaded = try decode(testing.allocator, encoded);
    defer loaded.deinit();

    const original_dump = try mir.print(testing.allocator, &program);
    defer testing.allocator.free(original_dump);
    const loaded_dump = try mir.print(testing.allocator, &loaded);
    defer testing.allocator.free(loaded_dump);
    try testing.expectEqualStrings(original_dump, loaded_dump);
    try testing.expect(std.mem.indexOf(u8, loaded_dump, "enum Method(byte):") != null);
    try testing.expect(std.mem.indexOf(u8, loaded_dump, "deflated = 8") != null);
    try testing.expect(std.mem.indexOf(u8, loaded_dump, "list(Method)") != null);

    const again = try encode(testing.allocator, &loaded);
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(u8, encoded, again);

    // **The width in a type and the width in the table are one fact**
    // (`types.Type.EnumRef`), so a module where they disagree is
    // damaged and must be refused rather than read at whichever of the
    // two an engine happens to consult.
    var widened = try testing.allocator.dupe(u8, encoded);
    defer testing.allocator.free(widened);
    const table_at = std.mem.indexOf(u8, widened, "Method").? + "Method".len;
    try testing.expectEqual(@intFromEnum(types.Type.EnumRef.Backing.byte), widened[table_at]);
    widened[table_at] = @intFromEnum(types.Type.EnumRef.Backing.long);
    try testing.expectError(error.InvalidModule, decode(testing.allocator, widened));
}

test "an enum register holding no member is refused" {
    var program = try compileScript(
        \\enum Method:
        \\    stored = 0
        \\    deflated = 8
        \\
        \\func main():
        \\    var m = Method.stored
        \\    m = Method.deflated
        \\    assert(m == Method.deflated)
        \\
    );
    defer program.deinit();

    // The one promise an enum makes is that every value of it is a
    // member (docs/ENUMS.md), and `match` spends it: with every member
    // named, the last arm is the fallthrough and nothing traps.  A
    // hand-made module that puts 3 in a `Method` register is what that
    // promise has to be defended against.
    for (program.functions[0].instructions, program.functions[0].result_types) |*instruction, of| {
        if (of != .enumeration or instruction.* != .const_long) continue;
        instruction.* = .{ .const_long = 3 };
        break;
    }
    const encoded = try encode(testing.allocator, &program);
    defer testing.allocator.free(encoded);
    try testing.expectError(error.InvalidModule, decode(testing.allocator, encoded));
}
