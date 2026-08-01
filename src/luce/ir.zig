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
    /// s.find_byte(byte, start) — the offset of the first `byte` at or
    /// after `start`, or -1.  Scanning is a primitive like byte_at is
    /// access: std strings builds substring search on top of it, and
    /// an engine is free to vectorize it.
    string_find_byte,
    assert_true,
    trap_message,
    // Collections and heap objects (see types.HeapType).
    null_object,
    index_get,
    index_set,
    list_slice,
    append_value,
    /// b.append_ascii(code) — one ASCII byte onto a Builder, without
    /// the String a chr()+append would allocate.  ASCII only: a
    /// Builder's bytes become a String, and String is valid UTF-8.
    append_ascii,
    pop_value,
    insert_value,
    remove_entry,
    has_key,
    key_at,
    value_at,
    dim_size,
    free_object,
    /// give NAME — passes the object through after checking it is not
    /// owned by a container (the one dynamic ownership check, S23).
    give_object,
    /// copy EXPR — a deep, independent duplicate of the object and
    /// everything it owns (S31).
    copy_object,
    // List / rank-1 Array / Map / Builder methods.
    list_sort,
    list_reverse,
    list_find,
    list_contains,
    clear_object,
    map_keys,
    map_values,
    map_get,
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

/// Where one instruction came from: a 1-based line and byte column in
/// its function's source file.  Debug info only — never read on the
/// execution path, only when a trap is being reported.
pub const Origin = struct {
    line: u32,
    column: u32,
};

pub const Function = struct {
    name: []const u8, // arena-owned by the program
    parameter_count: u32,
    return_type: Type,
    locals: []Local, // parameters first
    instructions: []Instruction,
    result_types: []Type, // parallel to instructions; .none = no result
    blocks: []Block, // entry is block 0
    /// Debug info, parallel to instructions; empty when the module was
    /// built --release.  Traps then report codes without locations.
    origins: []Origin = &.{},
    /// The source file this function came from ("dice.luc",
    /// "strings.luc"); "" when stripped.
    source: []const u8 = "",
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

/// Drop debug info — the release build.  Traps in a stripped program
/// still name their functions, but carry no source lines, and the
/// encoded module is smaller.  Semantics never change: every check
/// and trap fires identically in both modes.
pub fn strip(program: *Program) void {
    for (program.functions) |*function| {
        function.origins = &.{};
        function.source = "";
    }
}

// ---------------------------------------------------------------------------
// Dead-code elimination
// ---------------------------------------------------------------------------

/// Drop every function unreachable from the entry.
///
/// Std modules arrive whole: `import strings` brings eighteen
/// functions where a program may call three, and each one is
/// otherwise encoded into the `.lc`, decoded at load, and compiled to
/// machine code — the largest single cost in a short program's run
/// (docs/SPEED.md §12).  This is the dead-code elimination a compiled
/// language is expected to do, and it belongs here, in the compiler,
/// so the artifact itself is smaller and everything downstream of it
/// gets faster.
///
/// Call targets and the entry are the only function references in the
/// IR, so remapping is a renumber.  Call on verified programs only —
/// the compiler verifies before pruning (an analyzer bug surfaces as
/// a diagnostic, not an index panic here) and again after (proving
/// the renumbering).  Functions are all that shrinks: constants,
/// struct layouts, and heap-type rows they referenced stay, and the
/// scratch plus the dead functions' memory stay in the program arena
/// until deinit — the artifact is what gets smaller, not the
/// resident compiler.
pub fn prune(arena: Allocator, program: *Program) Allocator.Error!void {
    const count = program.functions.len;
    if (count == 0) return;

    const reachable = try arena.alloc(bool, count);
    @memset(reachable, false);
    var pending: std.ArrayList(u32) = .empty;
    reachable[program.entry_function] = true;
    try pending.append(arena, program.entry_function);
    while (pending.pop()) |index| {
        for (program.functions[index].instructions) |instruction| {
            const called = switch (instruction) {
                .call => |call| call.function,
                else => continue,
            };
            if (reachable[called]) continue;
            reachable[called] = true;
            try pending.append(arena, called);
        }
    }

    var kept: u32 = 0;
    const renumbered = try arena.alloc(u32, count);
    for (reachable, renumbered) |live, *slot| {
        if (!live) continue;
        slot.* = kept;
        kept += 1;
    }
    if (kept == count) return;

    const functions = try arena.alloc(Function, kept);
    for (reachable, 0..) |live, index| {
        if (!live) continue;
        const function = program.functions[index];
        for (function.instructions) |*instruction| {
            switch (instruction.*) {
                .call => |*call| call.function = renumbered[call.function],
                else => {},
            }
        }
        functions[renumbered[index]] = function;
    }
    program.functions = functions;
    program.entry_function = renumbered[program.entry_function];
}

test "unreachable functions are pruned and call targets renumbered" {
    // Five functions with the entry in the middle: [dead, main, dead,
    // mid, leaf], main -> mid -> leaf.  Pruning must keep the chain,
    // shift the indices, and leave a program the verifier accepts.
    var program: Program = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer program.deinit();
    const arena = program.arena.allocator();

    const functions = try arena.alloc(Function, 5);
    for (functions, 0..) |*function, index| {
        // Every function gets its own instruction pool (prune rewrites
        // call targets in place, so sharing would double-renumber).
        const instructions = try arena.dupe(Instruction, &.{
            .{ .const_int = 1 },
            .{ .ret = 0 },
        });
        const items = try arena.dupe(Register, &.{ 0, 1 });
        const blocks = try arena.alloc(Block, 1);
        blocks[0] = .{ .items = items };
        function.* = .{
            .name = try std.fmt.allocPrint(arena, "f{d}", .{index}),
            .parameter_count = 0,
            .return_type = .int,
            .locals = &.{},
            .instructions = instructions,
            .result_types = try arena.dupe(types.Type, &.{ .int, .none }),
            .blocks = blocks,
        };
    }
    functions[1].name = try arena.dupe(u8, "main");
    functions[1].instructions[0] = .{ .call = .{ .function = 3, .arguments = &.{} } };
    functions[3].name = try arena.dupe(u8, "mid");
    functions[3].instructions[0] = .{ .call = .{ .function = 4, .arguments = &.{} } };
    functions[4].name = try arena.dupe(u8, "leaf");
    program.functions = functions;
    program.entry_function = 1;
    try verify(testing.allocator, &program);

    try prune(arena, &program);
    try testing.expectEqual(@as(usize, 3), program.functions.len);
    try testing.expectEqual(@as(u32, 0), program.entry_function);
    try testing.expectEqualStrings("main", program.functions[0].name);
    try testing.expectEqualStrings("mid", program.functions[1].name);
    try testing.expectEqualStrings("leaf", program.functions[2].name);
    try testing.expectEqual(@as(u32, 1), program.functions[0].instructions[0].call.function);
    try testing.expectEqual(@as(u32, 2), program.functions[1].instructions[0].call.function);
    try verify(testing.allocator, &program);

    // Fully live programs pass through untouched (the no-op fast path
    // keeps prune idempotent).
    try prune(arena, &program);
    try testing.expectEqual(@as(usize, 3), program.functions.len);
    try testing.expectEqual(@as(u32, 0), program.entry_function);
}

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
    BadIntrinsic,
};

/// Check every structural and type invariant of a program.  Verified
/// programs cannot reference undefined registers, mismatch types,
/// fall through a block, or hand an intrinsic the wrong argument
/// shape — the interpreter's positional reads and union accesses all
/// rest on this pass, so a decoded module is safe to run, not merely
/// plausible.
pub fn verify(allocator: Allocator, program: *const Program) VerifyError!void {
    // The type tables themselves first: every index reachable from a
    // type must land inside the tables, map keys must be hashable
    // (Int/String), array ranks must be 1-4, and no struct may
    // contain itself (the interpreter zeroes structs recursively).
    for (program.heap_types) |descriptor| switch (descriptor) {
        .list => |element| try verifyType(program, element),
        .map => |pair| {
            if (pair.key != .int and pair.key != .string) return error.BadStruct;
            try verifyType(program, pair.value);
        },
        .array => |shape| {
            try verifyType(program, shape.element);
            if (shape.rank < 1 or shape.rank > 4) return error.BadStruct;
        },
        .builder => {},
    };
    for (program.structs) |layout| {
        for (layout.fields) |field| try verifyType(program, field.field_type);
    }
    for (0..program.structs.len) |index| {
        if (structContainsItself(program, @intCast(index), @intCast(index), 0)) {
            return error.BadStruct;
        }
    }

    for (program.functions) |*function| {
        try verifyFunction(allocator, program, function);
    }
    if (program.entry_function >= program.functions.len) return error.BadFunction;
    const entry = &program.functions[program.entry_function];
    // Every backend invokes the entry with no Luce arguments. Keep that
    // ABI true for decoded modules, not only for analyzer-produced IR.
    // Scalar return values are ABI-safe and may simply be ignored.
    if (entry.parameter_count != 0) {
        return error.BadFunction;
    }
}

fn verifyType(program: *const Program, of: Type) VerifyError!void {
    switch (of) {
        .strukt => |index| if (index >= program.structs.len) return error.BadStruct,
        .heap => |index| if (index >= program.heap_types.len) return error.BadStruct,
        else => {},
    }
}

fn structContainsItself(program: *const Program, origin: u32, current: u32, depth: usize) bool {
    if (depth > program.structs.len) return true;
    for (program.structs[current].fields) |field| {
        if (field.field_type == .strukt) {
            if (field.field_type.strukt == origin) return true;
            if (structContainsItself(program, origin, field.field_type.strukt, depth + 1)) return true;
        }
    }
    return false;
}

fn verifyFunction(allocator: Allocator, program: *const Program, function: *const Function) VerifyError!void {
    if (function.blocks.len == 0) return error.EmptyFunction;
    if (function.parameter_count > function.locals.len) return error.BadLocal;
    if (function.instructions.len != function.result_types.len) return error.BadFunction;
    // Debug info is all-or-nothing per function: one origin per
    // instruction, or none (a --release build).
    if (function.origins.len != 0 and function.origins.len != function.instructions.len)
        return error.BadFunction;
    try verifyType(program, function.return_type);
    for (function.locals) |local| try verifyType(program, local.local_type);
    for (function.result_types) |result_type| try verifyType(program, result_type);

    // Registers are block-local: track which instructions this block
    // has executed so far.
    var defined = std.AutoHashMapUnmanaged(Register, void){};
    defer defined.deinit(allocator);
    const seen = try allocator.alloc(bool, function.instructions.len);
    defer allocator.free(seen);
    @memset(seen, false);

    for (function.blocks) |block| {
        if (block.items.len == 0) return error.UnterminatedBlock;
        defined.clearRetainingCapacity();
        for (block.items, 0..) |item, position| {
            if (item >= function.instructions.len) return error.UndefinedRegister;
            // An instruction is one SSA definition and executes at one
            // position.  Repeating it (even in another block) breaks
            // liveness/code-size analysis in native backends.
            if (seen[item]) return error.BadFunction;
            seen[item] = true;
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
                // Ordering exists for Int, Float, and String only;
                // equality for everything with a value.
                switch (binary.op) {
                    .equal, .not_equal => {},
                    else => if (!binary.operand_type.isNumeric() and binary.operand_type != .string)
                        return error.TypeMismatch,
                }
                try expectType(result, .boolean);
            } else {
                // Arithmetic is numeric, plus + as String concat.
                const concat = binary.op == .add and binary.operand_type == .string;
                if (!binary.operand_type.isNumeric() and !concat) return error.TypeMismatch;
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
        .intrinsic => |intrinsic| try verifyIntrinsic(program, function, defined, register, intrinsic),
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
// Intrinsic signatures
// ---------------------------------------------------------------------------
//
// The interpreter executes intrinsics with positional register reads
// and direct union-field access ("the analyzer guarantees...").  For
// decoded modules the analyzer guaranteed nothing, so this switch
// re-establishes every one of those guarantees: exact arity, argument
// types (resolved against the program's heap-type table for container
// operations), and the result type.  It is exhaustive by construction
// — adding an intrinsic without a signature is a compile error.

fn verifyIntrinsic(
    program: *const Program,
    function: *const Function,
    defined: *const std.AutoHashMapUnmanaged(Register, void),
    register: Register,
    call: Instruction.IntrinsicCall,
) VerifyError!void {
    const result = function.result_types[register];
    // The widest intrinsic is index_set on a rank-4 array: object,
    // four indices, value.
    if (call.arguments.len > 6) return error.BadIntrinsic;
    var buffer: [6]Type = undefined;
    for (call.arguments, 0..) |argument, index| {
        buffer[index] = try operandType(function, defined, argument);
    }
    const arguments = buffer[0..call.arguments.len];

    switch (call.kind) {
        .abs => {
            try exactly(arguments, 1);
            if (!arguments[0].isNumeric()) return error.BadIntrinsic;
            try expectType(result, arguments[0]);
        },
        .min, .max => {
            try exactly(arguments, 2);
            if (!arguments[0].isNumeric()) return error.BadIntrinsic;
            try expectType(arguments[1], arguments[0]);
            try expectType(result, arguments[0]);
        },
        .clamp => {
            try exactly(arguments, 3);
            if (!arguments[0].isNumeric()) return error.BadIntrinsic;
            try expectType(arguments[1], arguments[0]);
            try expectType(arguments[2], arguments[0]);
            try expectType(result, arguments[0]);
        },
        .sqrt, .floor, .ceil => {
            try exactly(arguments, 1);
            try expectType(arguments[0], .float);
            try expectType(result, .float);
        },
        .len => {
            try exactly(arguments, 1);
            const measurable = arguments[0] == .string or arguments[0] == .bytes or
                arguments[0] == .heap;
            if (!measurable) return error.BadIntrinsic;
            try expectType(result, .int);
        },
        .string_slice => {
            try exactly(arguments, 3);
            try expectType(arguments[0], .string);
            try expectType(arguments[1], .int);
            try expectType(arguments[2], .int);
            try expectType(result, .string);
        },
        .string_byte => {
            try exactly(arguments, 2);
            try expectType(arguments[0], .string);
            try expectType(arguments[1], .int);
            try expectType(result, .int);
        },
        .string_find_byte => {
            try exactly(arguments, 3);
            try expectType(arguments[0], .string);
            try expectType(arguments[1], .int);
            try expectType(arguments[2], .int);
            try expectType(result, .int);
        },
        .assert_true => {
            try exactly(arguments, 1);
            try expectType(arguments[0], .boolean);
            try expectType(result, .none);
        },
        .trap_message => {
            try exactly(arguments, 1);
            try expectType(arguments[0], .string);
            try expectType(result, .none);
        },
        .null_object => {
            try exactly(arguments, 0);
            if (result != .heap) return error.BadIntrinsic;
        },
        .index_get, .index_set => {
            const reads = call.kind == .index_get;
            const value_slots: usize = if (reads) 0 else 1;
            if (arguments.len < 1) return error.BadIntrinsic;
            const element: Type = switch (try heapShape(program, arguments[0])) {
                .list => |item| blk: {
                    try exactly(arguments, 2 + value_slots);
                    try expectType(arguments[1], .int);
                    break :blk item;
                },
                .map => |pair| blk: {
                    try exactly(arguments, 2 + value_slots);
                    try expectType(arguments[1], pair.key);
                    break :blk pair.value;
                },
                .array => |shape| blk: {
                    try exactly(arguments, 1 + shape.rank + value_slots);
                    for (arguments[1 .. 1 + shape.rank]) |index| try expectType(index, .int);
                    break :blk shape.element;
                },
                .builder => return error.BadIntrinsic,
            };
            if (reads) {
                try expectType(result, element);
            } else {
                try expectType(arguments[arguments.len - 1], element);
                try expectType(result, .none);
            }
        },
        .list_slice => {
            try exactly(arguments, 3);
            if (try heapShape(program, arguments[0]) != .list) return error.BadIntrinsic;
            try expectType(arguments[1], .int);
            try expectType(arguments[2], .int);
            try expectType(result, arguments[0]);
        },
        .append_value => {
            try exactly(arguments, 2);
            switch (try heapShape(program, arguments[0])) {
                .list => |element| try expectType(arguments[1], element),
                .builder => try expectType(arguments[1], .string),
                else => return error.BadIntrinsic,
            }
            try expectType(result, .none);
        },
        .append_ascii => {
            try exactly(arguments, 2);
            if (try heapShape(program, arguments[0]) != .builder) return error.BadIntrinsic;
            try expectType(arguments[1], .int);
            try expectType(result, .none);
        },
        .pop_value => {
            try exactly(arguments, 1);
            switch (try heapShape(program, arguments[0])) {
                .list => |element| try expectType(result, element),
                else => return error.BadIntrinsic,
            }
        },
        .insert_value => {
            try exactly(arguments, 3);
            switch (try heapShape(program, arguments[0])) {
                .list => |element| {
                    try expectType(arguments[1], .int);
                    try expectType(arguments[2], element);
                },
                else => return error.BadIntrinsic,
            }
            try expectType(result, .none);
        },
        .remove_entry => {
            try exactly(arguments, 2);
            switch (try heapShape(program, arguments[0])) {
                .list => try expectType(arguments[1], .int),
                .map => |pair| try expectType(arguments[1], pair.key),
                else => return error.BadIntrinsic,
            }
            try expectType(result, .none);
        },
        .has_key => {
            try exactly(arguments, 2);
            switch (try heapShape(program, arguments[0])) {
                .map => |pair| try expectType(arguments[1], pair.key),
                else => return error.BadIntrinsic,
            }
            try expectType(result, .boolean);
        },
        .key_at => {
            try exactly(arguments, 2);
            switch (try heapShape(program, arguments[0])) {
                .map => |pair| {
                    try expectType(arguments[1], .int);
                    try expectType(result, pair.key);
                },
                else => return error.BadIntrinsic,
            }
        },
        .value_at => {
            try exactly(arguments, 2);
            switch (try heapShape(program, arguments[0])) {
                .map => |pair| {
                    try expectType(arguments[1], .int);
                    try expectType(result, pair.value);
                },
                else => return error.BadIntrinsic,
            }
        },
        .dim_size => {
            try exactly(arguments, 2);
            if (try heapShape(program, arguments[0]) != .array) return error.BadIntrinsic;
            try expectType(arguments[1], .int);
            try expectType(result, .int);
        },
        .free_object => {
            // The optional second argument is the owning local, for
            // the runtime binding check.
            if (arguments.len < 1 or arguments.len > 2) return error.BadIntrinsic;
            if (arguments[0] != .heap) return error.BadIntrinsic;
            if (arguments.len == 2) try expectType(arguments[1], .int);
            try expectType(result, .none);
        },
        .give_object => {
            if (arguments.len < 1 or arguments.len > 2) return error.BadIntrinsic;
            if (arguments[0] != .heap and arguments[0] != .strukt) return error.BadIntrinsic;
            if (arguments.len == 2) try expectType(arguments[1], .int);
            try expectType(result, arguments[0]);
        },
        .copy_object => {
            try exactly(arguments, 1);
            if (arguments[0] != .heap and arguments[0] != .strukt) return error.BadIntrinsic;
            try expectType(result, arguments[0]);
        },
        .list_sort, .list_reverse => {
            try exactly(arguments, 1);
            const element: Type = switch (try heapShape(program, arguments[0])) {
                .list => |item| item,
                .array => |shape| if (shape.rank == 1) shape.element else return error.BadIntrinsic,
                else => return error.BadIntrinsic,
            };
            // Sort's comparator orders Int, Float, and String only.
            if (call.kind == .list_sort and
                !element.isNumeric() and element != .string)
            {
                return error.BadIntrinsic;
            }
            try expectType(result, .none);
        },
        .list_find, .list_contains => {
            try exactly(arguments, 2);
            const element: Type = switch (try heapShape(program, arguments[0])) {
                .list => |item| item,
                .array => |shape| if (shape.rank == 1) shape.element else return error.BadIntrinsic,
                else => return error.BadIntrinsic,
            };
            try expectType(arguments[1], element);
            try expectType(result, if (call.kind == .list_find) .int else .boolean);
        },
        .clear_object => {
            try exactly(arguments, 1);
            switch (try heapShape(program, arguments[0])) {
                .list, .map, .builder => {},
                .array => return error.BadIntrinsic,
            }
            try expectType(result, .none);
        },
        .map_keys => {
            try exactly(arguments, 1);
            switch (try heapShape(program, arguments[0])) {
                .map => |pair| if (!(try heapShape(program, result)).eql(.{ .list = pair.key })) {
                    return error.BadIntrinsic;
                },
                else => return error.BadIntrinsic,
            }
        },
        .map_values => {
            try exactly(arguments, 1);
            switch (try heapShape(program, arguments[0])) {
                .map => |pair| if (!(try heapShape(program, result)).eql(.{ .list = pair.value })) {
                    return error.BadIntrinsic;
                },
                else => return error.BadIntrinsic,
            }
        },
        .map_get => {
            try exactly(arguments, 3);
            switch (try heapShape(program, arguments[0])) {
                .map => |pair| {
                    try expectType(arguments[1], pair.key);
                    try expectType(arguments[2], pair.value);
                    try expectType(result, pair.value);
                },
                else => return error.BadIntrinsic,
            }
        },
        .array_fill => {
            try exactly(arguments, 2);
            switch (try heapShape(program, arguments[0])) {
                .array => |shape| try expectType(arguments[1], shape.element),
                else => return error.BadIntrinsic,
            }
            try expectType(result, .none);
        },
        .str_value => {
            try exactly(arguments, 1);
            const stringable = switch (arguments[0]) {
                .int, .float, .boolean, .string => true,
                .heap => (try heapShape(program, arguments[0])) == .builder,
                else => false,
            };
            if (!stringable) return error.BadIntrinsic;
            try expectType(result, .string);
        },
        .parse_int, .parse_float => {
            try exactly(arguments, 1);
            try expectType(arguments[0], .string);
            try expectType(result, if (call.kind == .parse_int) .int else .float);
        },
        .chr_code => {
            try exactly(arguments, 1);
            try expectType(arguments[0], .int);
            try expectType(result, .string);
        },
        .ord_text => {
            try exactly(arguments, 1);
            try expectType(arguments[0], .string);
            try expectType(result, .int);
        },
        .print, .term_write => {
            try exactly(arguments, 1);
            try expectType(arguments[0], .string);
            try expectType(result, .none);
        },
        .file_read => {
            try exactly(arguments, 1);
            try expectType(arguments[0], .string);
            try expectType(result, .string);
        },
        .file_write => {
            try exactly(arguments, 2);
            try expectType(arguments[0], .string);
            try expectType(arguments[1], .string);
            try expectType(result, .boolean);
        },
        .file_exists => {
            try exactly(arguments, 1);
            try expectType(arguments[0], .string);
            try expectType(result, .boolean);
        },
        .arg_count, .term_rows, .term_cols => {
            try exactly(arguments, 0);
            try expectType(result, .int);
        },
        .arg_get => {
            try exactly(arguments, 1);
            try expectType(arguments[0], .int);
            try expectType(result, .string);
        },
        .term_clear, .term_flush => {
            try exactly(arguments, 0);
            try expectType(result, .none);
        },
        .term_move => {
            try exactly(arguments, 2);
            try expectType(arguments[0], .int);
            try expectType(arguments[1], .int);
            try expectType(result, .none);
        },
        .term_style => {
            try exactly(arguments, 3);
            try expectType(arguments[0], .int);
            try expectType(arguments[1], .int);
            try expectType(arguments[2], .boolean);
            try expectType(result, .none);
        },
        .key_read, .key_text => {
            try exactly(arguments, 0);
            try expectType(result, .string);
        },
        .fabric_image => {
            try exactly(arguments, 2);
            try expectType(arguments[0], .string);
            try expectType(arguments[1], .int);
            try expectType(result, .none);
        },
        .fabric_create => {
            try exactly(arguments, 1);
            try expectType(arguments[0], .string);
            try expectType(result, .int);
        },
        .fabric_input, .fabric_output => {
            try exactly(arguments, 3);
            try expectType(arguments[0], .int);
            try expectType(arguments[1], .string);
            try expectType(arguments[2], .string);
            try expectType(result, .none);
        },
        .fabric_content, .fabric_evaluator => {
            try exactly(arguments, 2);
            try expectType(arguments[0], .int);
            try expectType(arguments[1], .string);
            try expectType(result, .none);
        },
        .fabric_set => {
            try exactly(arguments, 3);
            try expectType(arguments[0], .int);
            try expectType(arguments[1], .string);
            const settable = switch (arguments[2]) {
                .boolean, .int, .float, .string => true,
                else => false,
            };
            if (!settable) return error.BadIntrinsic;
            try expectType(result, .none);
        },
    }
}

fn exactly(arguments: []const Type, count: usize) VerifyError!void {
    if (arguments.len != count) return error.BadIntrinsic;
}

/// Resolve a heap-typed value to its shape; anything else is not a
/// container and fails the intrinsic.
fn heapShape(program: *const Program, of: Type) VerifyError!types.HeapType {
    if (of != .heap) return error.BadIntrinsic;
    if (of.heap >= program.heap_types.len) return error.BadStruct;
    return program.heap_types[of.heap];
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
    // A minimal valid script entry: main() { let _ = 1; return }.
    var program: Program = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer program.deinit();
    const arena = program.arena.allocator();

    const instructions = try arena.dupe(Instruction, &.{
        .{ .const_int = 1 },
        .{ .ret = null },
    });
    const result_types = try arena.dupe(types.Type, &.{ .int, .none });
    const items = try arena.dupe(Register, &.{ 0, 1 });
    const blocks = try arena.alloc(Block, 1);
    blocks[0] = .{ .items = items };
    const functions = try arena.alloc(Function, 1);
    functions[0] = .{
        .name = try arena.dupe(u8, "main"),
        .parameter_count = 0,
        .return_type = .none,
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
    functions[0].instructions[1] = .{ .ret = null };

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

    // Entry functions are called without Luce arguments; a decoded
    // module cannot redefine that ABI.
    functions[0].parameter_count = 1;
    functions[0].locals = try arena.dupe(Local, &.{.{ .name = "arg", .local_type = .int }});
    try testing.expectError(error.BadFunction, verify(testing.allocator, &program));
    functions[0].parameter_count = 0;
    functions[0].locals = &.{};

    // A register definition appears exactly once in the block graph.
    const duplicate = try arena.dupe(Register, &.{ 0, 0, 1 });
    blocks[0].items = duplicate;
    try testing.expectError(error.BadFunction, verify(testing.allocator, &program));
    blocks[0].items = items;
    try verify(testing.allocator, &program);
}
