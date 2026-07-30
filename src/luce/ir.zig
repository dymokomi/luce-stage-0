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
    string_slice,
    string_byte,
    assert_true,
    trap_message,
    // Collections and heap objects (see types.HeapType).
    null_object,
    index_get,
    index_set,
    list_slice,
    append_value,
    pop_value,
    insert_value,
    remove_entry,
    has_key,
    key_at,
    dim_size,
    free_object,
    /// give NAME — passes the object through after checking it is not
    /// owned by a container (the one dynamic ownership check, S23).
    give_object,
    /// copy EXPR — a deep, independent duplicate of the object and
    /// everything it owns (S31).
    copy_object,
    // String methods.
    str_find,
    str_contains,
    str_starts,
    str_ends,
    str_trim,
    str_lower,
    str_upper,
    str_replace,
    str_repeat,
    str_split,
    // List / rank-1 Array / Map / Builder methods.
    list_sort,
    list_reverse,
    list_find,
    list_contains,
    list_join,
    clear_object,
    map_keys,
    array_fill,
    // Conversions and text.
    str_value,
    parse_int,
    parse_float,
    chr_code,
    ord_text,
    // Host builtins (gated by compile options; see backend.Host).
    print,
    file_read,
    file_write,
    file_exists,
    arg_count,
    arg_get,
    term_rows,
    term_cols,
    term_clear,
    term_move,
    term_style,
    term_write,
    term_flush,
    key_read,
    key_text,
    // Fabric builtins (gated by compile options; see fabric.zig).
    fabric_image,
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
    invalid_image,
    string_bounds,
    string_boundary,
    host_unavailable,
    argument_bounds,
    file_read_failed,
    index_bounds,
    key_missing,
    empty_collection,
    use_after_free,
    null_object,
    parse_failed,
    bad_codepoint,
    not_owned,

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
            .invalid_image => "create_image needs a path and a positive page count",
            .string_bounds => "string index out of bounds",
            .string_boundary => "string slice splits a UTF-8 sequence",
            .host_unavailable => "host service unavailable",
            .argument_bounds => "program argument out of range",
            .file_read_failed => "file read failed",
            .index_bounds => "index out of bounds",
            .key_missing => "key not found in map",
            .empty_collection => "pop from an empty list",
            .use_after_free => "object used after free",
            .null_object => "null object reference",
            .parse_failed => "cannot parse number",
            .bad_codepoint => "invalid character code",
            .not_owned => "object is owned by a container",
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
    binary: Binary,
    unary: struct { op: UnaryOp, operand: Register },
    convert: struct { kind: ConvertKind, operand: Register },
    struct_make: struct { layout: u32, fields: []Register },
    struct_get: struct { target: Register, layout: u32, field: u32 },
    /// Functional field update: a copy of target with one field replaced.
    struct_set: struct { target: Register, layout: u32, field: u32, value: Register },
    call: struct { function: u32, arguments: []Register },
    intrinsic: IntrinsicCall,
    /// Allocate one heap object of the program's heap type `heap`;
    /// `dims` carries an Array's runtime dimensions (empty otherwise).
    heap_new: HeapNew,
    /// Ownership: the objects reachable through `value` (the object
    /// itself, or a struct's object fields recursively) now belong to
    /// this frame's `local`; its scope-exit release frees them.
    object_bind: struct { local: LocalId, value: Register },
    /// Ownership: free the objects in `value` still bound to this
    /// frame's `local`.  Objects owned elsewhere by now — adopted by a
    /// container, re-bound by a give — are left alone, so releases are
    /// safe on every path.
    object_unbind: struct { local: LocalId, value: Register },
    jump: BlockId,
    branch: struct { condition: Register, then_block: BlockId, else_block: BlockId },
    ret: ?Register,
    trap: TrapCode,

    /// Named payloads, so the interpreter's handlers can say what
    /// they take instead of `anytype`.
    pub const Binary = struct { op: BinaryOp, operand_type: Type, left: Register, right: Register };
    pub const IntrinsicCall = struct { kind: Intrinsic, arguments: []Register };
    pub const HeapNew = struct { heap: u32, dims: []Register };

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
    heap_types: []types.HeapType = &.{},
    functions: []Function = &.{},
    constants: []const []const u8 = &.{},
    inputs: []Port = &.{},
    outputs: []Port = &.{},
    /// Input port indices the program reads; unavailable reads gate
    /// evaluation before it starts.
    reads: []u32 = &.{},
    entry_function: u32 = 0,

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
    if (program.entry_function >= program.functions.len) return error.BadFunction;
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
        .object_bind => |bind| {
            if (bind.local >= function.locals.len) return error.BadLocal;
            _ = try operandType(function, defined, bind.value);
        },
        .object_unbind => |unbind| {
            if (unbind.local >= function.locals.len) return error.BadLocal;
            _ = try operandType(function, defined, unbind.value);
        },
        .heap_new => |new| {
            if (new.heap >= program.heap_types.len) return error.BadStruct;
            const expected_dims: usize = switch (program.heap_types[new.heap]) {
                .array => |shape| shape.rank,
                else => 0,
            };
            if (new.dims.len != expected_dims) return error.BadStruct;
            for (new.dims) |dimension| {
                const value = try operandType(function, defined, dimension);
                try expectType(value, .int);
            }
            try expectType(result, .{ .heap = new.heap });
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
            const field_type_name = try typeName(allocator, program, field.field_type);
            defer allocator.free(field_type_name);
            try appendPrint(&text, allocator, "    {s}: {s}\n", .{ field.name, field_type_name });
        }
    }

    for (program.functions) |*function| {
        try appendPrint(&text, allocator, "func {s}(", .{function.name});
        for (function.locals[0..function.parameter_count], 0..) |local, index| {
            if (index != 0) try text.appendSlice(allocator, ", ");
            const parameter_type_name = try typeName(allocator, program, local.local_type);
            defer allocator.free(parameter_type_name);
            try appendPrint(&text, allocator, "{s}: {s}", .{ local.name, parameter_type_name });
        }
        const return_type_name = try typeName(allocator, program, function.return_type);
        defer allocator.free(return_type_name);
        try appendPrint(&text, allocator, ") -> {s}\n", .{return_type_name});
        for (function.locals[function.parameter_count..], function.parameter_count..) |local, index| {
            const local_type_name = try typeName(allocator, program, local.local_type);
            defer allocator.free(local_type_name);
            try appendPrint(&text, allocator, "    local %{d} {s}: {s}\n", .{
                index,
                local.name,
                local_type_name,
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

fn typeName(allocator: Allocator, program: *const Program, of: Type) error{OutOfMemory}![]u8 {
    return types.typeName(allocator, program.structs, program.heap_types, of);
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
        .binary => |binary| {
            const operand_type_name = try typeName(allocator, program, binary.operand_type);
            defer allocator.free(operand_type_name);
            try appendPrint(text, allocator, "{s}.{s} r{d}, r{d}", .{
                @tagName(binary.op),
                operand_type_name,
                binary.left,
                binary.right,
            });
        },
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
        .heap_new => |new| {
            const object_type_name = try typeName(allocator, program, .{ .heap = new.heap });
            defer allocator.free(object_type_name);
            try appendPrint(text, allocator, "heap_new {s}", .{object_type_name});
            for (new.dims) |dimension| try appendPrint(text, allocator, ", r{d}", .{dimension});
        },
        .object_bind => |bind| try appendPrint(text, allocator, "object_bind %{d}, r{d}", .{ bind.local, bind.value }),
        .object_unbind => |unbind| try appendPrint(text, allocator, "object_unbind %{d}, r{d}", .{ unbind.local, unbind.value }),
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the verifier rejects structural damage a decoder could admit" {
    // A minimal valid program: main() -> Int { return 1 }.
    var program: Program = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer program.deinit();
    const arena = program.arena.allocator();

    const instructions = try arena.dupe(Instruction, &.{
        .{ .const_int = 1 },
        .{ .ret = 0 },
    });
    const result_types = try arena.dupe(types.Type, &.{ .int, .none });
    const items = try arena.dupe(Register, &.{ 0, 1 });
    const blocks = try arena.alloc(Block, 1);
    blocks[0] = .{ .items = items };
    const functions = try arena.alloc(Function, 1);
    functions[0] = .{
        .name = try arena.dupe(u8, "main"),
        .parameter_count = 0,
        .return_type = .int,
        .locals = &.{},
        .instructions = instructions,
        .result_types = result_types,
        .blocks = blocks,
    };
    program.functions = functions;
    try verify(testing.allocator, &program);

    // An operand register that was never defined.
    functions[0].instructions[1] = .{ .ret = 5 };
    try testing.expectError(error.UndefinedRegister, verify(testing.allocator, &program));
    functions[0].instructions[1] = .{ .ret = 0 };

    // A block that does not end in a terminator.
    blocks[0].items = items[0..1];
    try testing.expectError(error.UnterminatedBlock, verify(testing.allocator, &program));
    blocks[0].items = items;

    // A terminator before the end of its block.
    const reordered = try arena.dupe(Register, &.{ 1, 0 });
    blocks[0].items = reordered;
    try testing.expectError(error.MisplacedTerminator, verify(testing.allocator, &program));
    blocks[0].items = items;

    // A producer whose recorded type disagrees with its consumer.
    functions[0].result_types[0] = .boolean;
    try testing.expectError(error.TypeMismatch, verify(testing.allocator, &program));
    functions[0].result_types[0] = .int;

    // An ownership instruction naming a local that does not exist.
    const owned_instructions = try arena.dupe(Instruction, &.{
        .{ .const_int = 1 },
        .{ .object_bind = .{ .local = 7, .value = 0 } },
        .{ .ret = 0 },
    });
    const owned_results = try arena.dupe(types.Type, &.{ .int, .none, .none });
    const owned_items = try arena.dupe(Register, &.{ 0, 1, 2 });
    functions[0].instructions = owned_instructions;
    functions[0].result_types = owned_results;
    blocks[0].items = owned_items;
    try testing.expectError(error.BadLocal, verify(testing.allocator, &program));
    functions[0].instructions = instructions;
    functions[0].result_types = result_types;
    blocks[0].items = items;

    // An entry index outside the function table.
    program.entry_function = 9;
    try testing.expectError(error.BadFunction, verify(testing.allocator, &program));
    program.entry_function = 0;
    try verify(testing.allocator, &program);
}
