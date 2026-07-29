//! Luce IR — the small typed intermediate representation.
//!
//! Functions hold one instruction pool and a list of basic blocks;
//! blocks list instruction indices in execution order and end in
//! exactly one terminator.  A register is the index of the instruction
//! that produced it, and registers never cross block boundaries —
//! mutable locals carry every value that lives past a block, which
//! keeps verification simple and lowers directly to stack slots in a
//! native backend.  The IR is deliberately only what the language
//! needs; it is a stable boundary in front of any code generator, not
//! a universal optimizer.

const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Type = types.Type;
const StructLayout = types.StructLayout;
const Port = types.Port;

pub const Register = u32;
pub const BlockId = u32;
pub const LocalId = u32;

pub const BinaryOp = enum {
    add,
    subtract,
    multiply,
    divide,
    remainder,
    equal,
    not_equal,
    less,
    less_equal,
    greater,
    greater_equal,

    pub fn isComparison(self: BinaryOp) bool {
        return switch (self) {
            .equal, .not_equal, .less, .less_equal, .greater, .greater_equal => true,
            else => false,
        };
    }
};

pub const UnaryOp = enum { negate, logic_not };

pub const ConvertKind = enum { int_to_float, float_to_int };

pub const Intrinsic = enum {
    abs,
    min,
    max,
    clamp,
    sqrt,
    floor,
    ceil,
    len,
    assert_true,
    trap_message,
    // Fabric builtins (gated by compile options; see fabric.zig).
    fabric_create,
    fabric_input,
    fabric_output,
    fabric_content,
    fabric_evaluator,
    fabric_set,
};

pub const TrapCode = enum {
    integer_overflow,
    divide_by_zero,
    conversion_range,
    assertion_failed,
    explicit_trap,
    missing_return,
    step_budget_exhausted,
    call_depth_exceeded,
    invalid_handle,
    invalid_port_type,

    pub fn message(self: TrapCode) []const u8 {
        return switch (self) {
            .integer_overflow => "integer overflow",
            .divide_by_zero => "division by zero",
            .conversion_range => "conversion out of range",
            .assertion_failed => "assertion failed",
            .explicit_trap => "explicit trap",
            .missing_return => "function ended without returning a value",
            .step_budget_exhausted => "evaluation step budget exhausted",
            .call_depth_exceeded => "call depth exceeded",
            .invalid_handle => "invalid texel handle",
            .invalid_port_type => "unknown port type (bool int real text bytes)",
        };
    }
};

pub const Instruction = union(enum) {
    const_boolean: bool,
    const_int: i64,
    const_float: f64,
    /// Index into the program constant pool; strings and bytes share it.
    const_data: struct { constant: u32, data_type: Type },
    local_get: LocalId,
    local_set: struct { local: LocalId, value: Register },
    input_load: u32,
    output_store: struct { port: u32, value: Register },
    binary: struct { op: BinaryOp, operand_type: Type, left: Register, right: Register },
    unary: struct { op: UnaryOp, operand: Register },
    convert: struct { kind: ConvertKind, operand: Register },
    struct_make: struct { layout: u32, fields: []Register },
    struct_get: struct { target: Register, layout: u32, field: u32 },
    /// Functional field update: a copy of target with one field replaced.
    struct_set: struct { target: Register, layout: u32, field: u32, value: Register },
    call: struct { function: u32, arguments: []Register },
    intrinsic: struct { kind: Intrinsic, arguments: []Register },
    jump: BlockId,
    branch: struct { condition: Register, then_block: BlockId, else_block: BlockId },
    ret: ?Register,
    trap: TrapCode,

    pub fn isTerminator(self: Instruction) bool {
        return switch (self) {
            .jump, .branch, .ret, .trap => true,
            else => false,
        };
    }
};

pub const Local = struct {
    name: []const u8, // arena-owned by the program
    local_type: Type,
};

pub const Block = struct {
    items: []Register, // instruction indices, in execution order
};

pub const Function = struct {
    name: []const u8, // arena-owned by the program
    parameter_count: u32,
    return_type: Type,
    locals: []Local, // parameters first
    instructions: []Instruction,
    result_types: []Type, // parallel to instructions; .none = no result
    blocks: []Block, // entry is block 0
};

// ---------------------------------------------------------------------------
// Program
// ---------------------------------------------------------------------------
//
// One compiled evaluator: struct layouts, functions, the constant
// pool, the Port schema it was compiled against, and which input ports
// the program reads.  Everything lives in the program's own arena.
//
pub const Program = struct {
    arena: std.heap.ArenaAllocator,
    structs: []StructLayout = &.{},
    functions: []Function = &.{},
    constants: []const []const u8 = &.{},
    inputs: []Port = &.{},
    outputs: []Port = &.{},
    /// Input port indices the program reads; unavailable reads gate
    /// evaluation before it starts.
    reads: []u32 = &.{},
    evaluate_function: u32 = 0,

    pub fn deinit(self: *Program) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// Verifier
// ---------------------------------------------------------------------------

pub const VerifyError = error{
    OutOfMemory,
    EmptyFunction,
    UnterminatedBlock,
    MisplacedTerminator,
    UndefinedRegister,
    ValuelessRegister,
    TypeMismatch,
    BadLocal,
    BadPort,
    BadBlock,
    BadFunction,
    BadStruct,
    BadConstant,
};

/// Check every structural and type invariant of a program.  Verified
/// programs cannot reference undefined registers, mismatch types, or
/// fall through a block.
pub fn verify(allocator: Allocator, program: *const Program) VerifyError!void {
    for (program.functions) |*function| {
        try verifyFunction(allocator, program, function);
    }
    if (program.evaluate_function >= program.functions.len) return error.BadFunction;
}

fn verifyFunction(allocator: Allocator, program: *const Program, function: *const Function) VerifyError!void {
    if (function.blocks.len == 0) return error.EmptyFunction;
    if (function.parameter_count > function.locals.len) return error.BadLocal;
    if (function.instructions.len != function.result_types.len) return error.BadFunction;

    // Registers are block-local: track which instructions this block
    // has executed so far.
    var defined = std.AutoHashMapUnmanaged(Register, void){};
    defer defined.deinit(allocator);

    for (function.blocks) |block| {
        if (block.items.len == 0) return error.UnterminatedBlock;
        defined.clearRetainingCapacity();
        for (block.items, 0..) |item, position| {
            if (item >= function.instructions.len) return error.UndefinedRegister;
            const instruction = function.instructions[item];
            const last = position == block.items.len - 1;
            if (instruction.isTerminator() != last) {
                return if (last) error.UnterminatedBlock else error.MisplacedTerminator;
            }
            try verifyInstruction(program, function, &defined, item, instruction);
            try defined.put(allocator, item, {});
        }
    }
}

fn operandType(function: *const Function, defined: *const std.AutoHashMapUnmanaged(Register, void), register: Register) VerifyError!Type {
    if (register >= function.instructions.len) return error.UndefinedRegister;
    if (!defined.contains(register)) return error.UndefinedRegister;
    const result = function.result_types[register];
    if (result == .none) return error.ValuelessRegister;
    return result;
}

fn expectType(actual: Type, expected: Type) VerifyError!void {
    if (!actual.eql(expected)) return error.TypeMismatch;
}

fn verifyInstruction(
    program: *const Program,
    function: *const Function,
    defined: *const std.AutoHashMapUnmanaged(Register, void),
    register: Register,
    instruction: Instruction,
) VerifyError!void {
    const result = function.result_types[register];
    switch (instruction) {
        .const_boolean => try expectType(result, .boolean),
        .const_int => try expectType(result, .int),
        .const_float => try expectType(result, .float),
        .const_data => |data| {
            if (data.constant >= program.constants.len) return error.BadConstant;
            if (data.data_type != .string and data.data_type != .bytes) return error.TypeMismatch;
            try expectType(result, data.data_type);
        },
        .local_get => |local| {
            if (local >= function.locals.len) return error.BadLocal;
            try expectType(result, function.locals[local].local_type);
        },
        .local_set => |set| {
            if (set.local >= function.locals.len) return error.BadLocal;
            const value = try operandType(function, defined, set.value);
            try expectType(value, function.locals[set.local].local_type);
        },
        .input_load => |port| {
            if (port >= program.inputs.len) return error.BadPort;
            try expectType(result, Type.fromPort(program.inputs[port].declared));
        },
        .output_store => |store| {
            if (store.port >= program.outputs.len) return error.BadPort;
            const value = try operandType(function, defined, store.value);
            try expectType(value, Type.fromPort(program.outputs[store.port].declared));
        },
        .binary => |binary| {
            const left = try operandType(function, defined, binary.left);
            const right = try operandType(function, defined, binary.right);
            try expectType(left, binary.operand_type);
            try expectType(right, binary.operand_type);
            if (binary.op.isComparison()) {
                try expectType(result, .boolean);
            } else {
                try expectType(result, binary.operand_type);
            }
        },
        .unary => |unary| {
            const operand = try operandType(function, defined, unary.operand);
            switch (unary.op) {
                .negate => {
                    if (!operand.isNumeric()) return error.TypeMismatch;
                    try expectType(result, operand);
                },
                .logic_not => {
                    try expectType(operand, .boolean);
                    try expectType(result, .boolean);
                },
            }
        },
        .convert => |convert| {
            const operand = try operandType(function, defined, convert.operand);
            switch (convert.kind) {
                .int_to_float => {
                    try expectType(operand, .int);
                    try expectType(result, .float);
                },
                .float_to_int => {
                    try expectType(operand, .float);
                    try expectType(result, .int);
                },
            }
        },
        .struct_make => |make| {
            if (make.layout >= program.structs.len) return error.BadStruct;
            const layout = program.structs[make.layout];
            if (make.fields.len != layout.fields.len) return error.BadStruct;
            for (make.fields, layout.fields) |field_register, field| {
                const value = try operandType(function, defined, field_register);
                try expectType(value, field.field_type);
            }
            try expectType(result, .{ .strukt = make.layout });
        },
        .struct_get => |get| {
            if (get.layout >= program.structs.len) return error.BadStruct;
            const layout = program.structs[get.layout];
            if (get.field >= layout.fields.len) return error.BadStruct;
            const target = try operandType(function, defined, get.target);
            try expectType(target, .{ .strukt = get.layout });
            try expectType(result, layout.fields[get.field].field_type);
        },
        .struct_set => |set| {
            if (set.layout >= program.structs.len) return error.BadStruct;
            const layout = program.structs[set.layout];
            if (set.field >= layout.fields.len) return error.BadStruct;
            const target = try operandType(function, defined, set.target);
            try expectType(target, .{ .strukt = set.layout });
            const value = try operandType(function, defined, set.value);
            try expectType(value, layout.fields[set.field].field_type);
            try expectType(result, .{ .strukt = set.layout });
        },
        .call => |call| {
            if (call.function >= program.functions.len) return error.BadFunction;
            const callee = program.functions[call.function];
            if (call.arguments.len != callee.parameter_count) return error.BadFunction;
            for (call.arguments, 0..) |argument, index| {
                const value = try operandType(function, defined, argument);
                try expectType(value, callee.locals[index].local_type);
            }
            if (!result.eql(callee.return_type)) return error.TypeMismatch;
        },
        .intrinsic => |intrinsic| {
            for (intrinsic.arguments) |argument| {
                _ = try operandType(function, defined, argument);
            }
        },
        .jump => |target| {
            if (target >= function.blocks.len) return error.BadBlock;
        },
        .branch => |branch| {
            const condition = try operandType(function, defined, branch.condition);
            try expectType(condition, .boolean);
            if (branch.then_block >= function.blocks.len) return error.BadBlock;
            if (branch.else_block >= function.blocks.len) return error.BadBlock;
        },
        .ret => |value| {
            if (value) |returned| {
                const actual = try operandType(function, defined, returned);
                try expectType(actual, function.return_type);
            } else {
                try expectType(function.return_type, .none);
            }
        },
        .trap => {},
    }
}

// ---------------------------------------------------------------------------
// Printer
// ---------------------------------------------------------------------------

/// Render a readable dump of the whole program.  The caller owns the
/// text.  The dump is deterministic for identical programs.
pub fn print(allocator: Allocator, program: *const Program) error{OutOfMemory}![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);

    for (program.structs) |layout| {
        try appendPrint(&text, allocator, "struct {s}:\n", .{layout.name});
        for (layout.fields) |field| {
            try appendPrint(&text, allocator, "    {s}: {s}\n", .{
                field.name,
                types.typeName(program.structs, field.field_type),
            });
        }
    }

    for (program.functions) |*function| {
        try appendPrint(&text, allocator, "fn {s}(", .{function.name});
        for (function.locals[0..function.parameter_count], 0..) |local, index| {
            if (index != 0) try text.appendSlice(allocator, ", ");
            try appendPrint(&text, allocator, "{s}: {s}", .{
                local.name,
                types.typeName(program.structs, local.local_type),
            });
        }
        try appendPrint(&text, allocator, ") -> {s}\n", .{
            types.typeName(program.structs, function.return_type),
        });
        for (function.locals[function.parameter_count..], function.parameter_count..) |local, index| {
            try appendPrint(&text, allocator, "    local %{d} {s}: {s}\n", .{
                index,
                local.name,
                types.typeName(program.structs, local.local_type),
            });
        }
        for (function.blocks, 0..) |block, block_index| {
            try appendPrint(&text, allocator, "  b{d}:\n", .{block_index});
            for (block.items) |item| {
                try printInstruction(&text, allocator, program, function, item);
            }
        }
    }
    return text.toOwnedSlice(allocator);
}

fn appendPrint(
    text: *std.ArrayList(u8),
    allocator: Allocator,
    comptime format: []const u8,
    arguments: anytype,
) error{OutOfMemory}!void {
    const line = try std.fmt.allocPrint(allocator, format, arguments);
    defer allocator.free(line);
    try text.appendSlice(allocator, line);
}

fn printInstruction(
    text: *std.ArrayList(u8),
    allocator: Allocator,
    program: *const Program,
    function: *const Function,
    register: Register,
) error{OutOfMemory}!void {
    const instruction = function.instructions[register];
    const has_result = function.result_types[register] != .none;
    if (has_result) {
        try appendPrint(text, allocator, "    r{d} = ", .{register});
    } else {
        try text.appendSlice(allocator, "    ");
    }
    switch (instruction) {
        .const_boolean => |value| try appendPrint(text, allocator, "const {}", .{value}),
        .const_int => |value| try appendPrint(text, allocator, "const {d}", .{value}),
        .const_float => |value| try appendPrint(text, allocator, "const {d}", .{value}),
        .const_data => |data| try appendPrint(text, allocator, "const data#{d}", .{data.constant}),
        .local_get => |local| try appendPrint(text, allocator, "local_get %{d}", .{local}),
        .local_set => |set| try appendPrint(text, allocator, "local_set %{d}, r{d}", .{ set.local, set.value }),
        .input_load => |port| try appendPrint(text, allocator, "input_load {s}", .{program.inputs[port].name}),
        .output_store => |store| try appendPrint(text, allocator, "output_store {s}, r{d}", .{
            program.outputs[store.port].name,
            store.value,
        }),
        .binary => |binary| try appendPrint(text, allocator, "{s}.{s} r{d}, r{d}", .{
            @tagName(binary.op),
            types.typeName(program.structs, binary.operand_type),
            binary.left,
            binary.right,
        }),
        .unary => |unary| try appendPrint(text, allocator, "{s} r{d}", .{ @tagName(unary.op), unary.operand }),
        .convert => |convert| try appendPrint(text, allocator, "{s} r{d}", .{ @tagName(convert.kind), convert.operand }),
        .struct_make => |make| {
            try appendPrint(text, allocator, "struct_make {s}", .{program.structs[make.layout].name});
            for (make.fields) |field| try appendPrint(text, allocator, ", r{d}", .{field});
        },
        .struct_get => |get| try appendPrint(text, allocator, "struct_get r{d}, {s}.{s}", .{
            get.target,
            program.structs[get.layout].name,
            program.structs[get.layout].fields[get.field].name,
        }),
        .struct_set => |set| try appendPrint(text, allocator, "struct_set r{d}, {s}.{s}, r{d}", .{
            set.target,
            program.structs[set.layout].name,
            program.structs[set.layout].fields[set.field].name,
            set.value,
        }),
        .call => |call| {
            try appendPrint(text, allocator, "call {s}", .{program.functions[call.function].name});
            for (call.arguments) |argument| try appendPrint(text, allocator, ", r{d}", .{argument});
        },
        .intrinsic => |intrinsic| {
            try appendPrint(text, allocator, "intrinsic {s}", .{@tagName(intrinsic.kind)});
            for (intrinsic.arguments) |argument| try appendPrint(text, allocator, ", r{d}", .{argument});
        },
        .jump => |target| try appendPrint(text, allocator, "jump b{d}", .{target}),
        .branch => |branch| try appendPrint(text, allocator, "branch r{d}, b{d}, b{d}", .{
            branch.condition,
            branch.then_block,
            branch.else_block,
        }),
        .ret => |value| {
            if (value) |returned| {
                try appendPrint(text, allocator, "ret r{d}", .{returned});
            } else {
                try text.appendSlice(allocator, "ret");
            }
        },
        .trap => |code| try appendPrint(text, allocator, "trap {s}", .{@tagName(code)}),
    }
    try text.append(allocator, '\n');
}
