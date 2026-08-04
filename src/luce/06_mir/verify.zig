//! IR verifier — structural and type invariant checks.
//! Every piece of code that produces or decodes IR must pass this.

const std = @import("std");
const defs = @import("defs.zig");
const types = @import("../support/types.zig");

const Allocator = std.mem.Allocator;
const Type = types.Type;
const Program = defs.Program;
const Function = defs.Function;
const Instruction = defs.Instruction;
const Register = defs.Register;
const Local = defs.Local;

pub const VerifyError = error{
    OutOfMemory,
    EmptyFunction,
    UnterminatedBlock,
    MisplacedTerminator,
    UndefinedRegister,
    ValuelessRegister,
    TypeMismatch,
    BadLocal,
    BadBlock,
    BadFunction,
    BadStruct,
    BadConstant,
    BadIntrinsic,
    /// `raise_error` or `unwind` in a function that never said it
    /// could fail: a caller compiled against that signature has no
    /// branch to take, so the module is not one this build wrote.
    NotFallible,
};

// ---------------------------------------------------------------------------
// The whole program
// ---------------------------------------------------------------------------

/// Check every structural and type invariant of a program.
pub fn verify(allocator: Allocator, program: *const Program) VerifyError!void {
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
    if (try anyStructContainsItself(allocator, program)) return error.BadStruct;

    // Every signature is checked before any body is.  A `call` types
    // its arguments against `callee.locals[0..parameter_count]`, and
    // the callee may stand *later* in the table than its caller — so
    // waiting for the callee's own turn would mean indexing a
    // parameter table that has not been bounded yet, and a module
    // claiming more parameters than locals would take the verifier out
    // of bounds instead of being refused.  That module is precisely
    // what `decode` exists to refuse.
    for (program.functions) |*function| {
        if (function.parameter_count > function.locals.len) return error.BadLocal;
    }
    for (program.functions) |*function| {
        try verifyFunction(allocator, program, function);
    }
    if (program.entry_function >= program.functions.len) return error.BadFunction;
    const entry = &program.functions[program.entry_function];
    if (entry.parameter_count != 0) {
        return error.BadFunction;
    }
}

fn verifyType(program: *const Program, of: Type) VerifyError!void {
    switch (of) {
        .strukt => |index| if (index >= program.structs.len) return error.BadStruct,
        .heap => |index| if (index >= program.heap_types.len) return error.BadStruct,
        // A payload is a type in its own right and is bounded the same
        // way; it can never be optional itself, so this is one step.
        .optional => |payload| try verifyType(program, payload.asType()),
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Struct layouts, and the one question that can hang a decoder
// ---------------------------------------------------------------------------

/// Does any struct contain itself, directly or through another?  Such
/// a layout has no finite value and nothing downstream may assume one
/// exists.
///
/// One linear pass over the containment graph — Tarjan's strongly
/// connected components, with an explicit stack.  Asking the question
/// per layout by walking down from it re-walks every *path* through
/// the graph, so a struct with two struct fields doubles the work per
/// level: twenty levels is a million walks, and forty never finishes.
/// Stage 4 refuses cycles before they can reach a `.lcm`, so from
/// source this was already unreachable; a hand-written or fuzzed
/// module reaches it through `decode`, which is exactly the input that
/// must not be able to hang the decoder.  (`04_semantics/
/// declarations.zig` answers the same question the same way, and also
/// sums each layout's shape while it is there.)
fn anyStructContainsItself(allocator: Allocator, program: *const Program) VerifyError!bool {
    const count = program.structs.len;
    if (count == 0) return false;

    const unvisited = std.math.maxInt(u32);
    const order = try allocator.alloc(u32, count);
    defer allocator.free(order);
    const lowest = try allocator.alloc(u32, count);
    defer allocator.free(lowest);
    const open = try allocator.alloc(bool, count);
    defer allocator.free(open);
    @memset(order, unvisited);
    @memset(open, false);

    // Tarjan's component stack, and the explicit depth-first one.
    var pending: std.ArrayList(u32) = .empty;
    defer pending.deinit(allocator);
    const Step = struct { layout: u32, field: u32 };
    var path: std.ArrayList(Step) = .empty;
    defer path.deinit(allocator);

    var next_order: u32 = 0;
    for (0..count) |root| {
        if (order[root] != unvisited) continue;
        order[root] = next_order;
        lowest[root] = next_order;
        next_order += 1;
        open[root] = true;
        try pending.append(allocator, @intCast(root));
        try path.append(allocator, .{ .layout = @intCast(root), .field = 0 });

        while (path.items.len != 0) {
            // `step` points into `path`, which the descent below may
            // grow: everything read through it is read before that
            // append, and nothing is read after.
            const step = &path.items[path.items.len - 1];
            const layout = step.layout;
            const fields = program.structs[layout].fields;
            if (step.field < fields.len) {
                const field_type = fields[step.field].field_type;
                step.field += 1;
                if (field_type != .strukt) continue;
                const held = field_type.strukt;
                // `verifyType` has already bounded every field index.
                if (held == layout) return true;
                if (order[held] == unvisited) {
                    order[held] = next_order;
                    lowest[held] = next_order;
                    next_order += 1;
                    open[held] = true;
                    try pending.append(allocator, held);
                    try path.append(allocator, .{ .layout = held, .field = 0 });
                } else if (open[held]) {
                    lowest[layout] = @min(lowest[layout], order[held]);
                }
                continue;
            }

            _ = path.pop();
            if (path.items.len != 0) {
                const parent = path.items[path.items.len - 1].layout;
                lowest[parent] = @min(lowest[parent], lowest[layout]);
            }
            if (lowest[layout] != order[layout]) continue;

            // The root of a component: everything pushed at or after
            // it is a member.  More than one member means they hold
            // each other, so none of them has a finite value.
            var first = pending.items.len;
            while (pending.items[first - 1] != layout) first -= 1;
            first -= 1;
            const members = pending.items[first..];
            if (members.len > 1) return true;
            for (members) |member| open[member] = false;
            pending.shrinkRetainingCapacity(first);
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// One function: its blocks, its registers, its terminators
// ---------------------------------------------------------------------------

fn verifyFunction(allocator: Allocator, program: *const Program, function: *const Function) VerifyError!void {
    if (function.blocks.len == 0) return error.EmptyFunction;
    if (function.parameter_count > function.locals.len) return error.BadLocal;
    if (function.instructions.len != function.result_types.len) return error.BadFunction;
    if (function.origins.len != 0 and function.origins.len != function.instructions.len)
        return error.BadFunction;
    try verifyType(program, function.return_type);
    for (function.locals) |local| try verifyType(program, local.local_type);
    for (function.result_types) |result_type| try verifyType(program, result_type);

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

// ---------------------------------------------------------------------------
// One instruction
// ---------------------------------------------------------------------------

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
        .const_string => |constant| {
            if (constant >= program.constants.len) return error.BadConstant;
            try expectType(result, .string);
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
        .binary => |binary| {
            const left = try operandType(function, defined, binary.left);
            const right = try operandType(function, defined, binary.right);
            try expectType(left, binary.operand_type);
            try expectType(right, binary.operand_type);
            if (binary.op.isComparison()) {
                switch (binary.op) {
                    .equal, .not_equal => {},
                    else => if (!binary.operand_type.isNumeric() and binary.operand_type != .string)
                        return error.TypeMismatch,
                }
                try expectType(result, .boolean);
            } else {
                const concat = binary.op == .add and binary.operand_type == .string;
                if (!binary.operand_type.isNumeric() and !concat) return error.TypeMismatch;
                // `/` is real division and always answers a Float
                // (docs/NUMERICS.md §2), so `Binary { .divide, .int }`
                // is not a shape stage 4 can emit — the quotient that
                // answers an Int is `floor_divide`.  Rejecting it here
                // is what lets the runtime and the lowering stop
                // carrying an integer `/` at all.
                if (binary.op == .divide and binary.operand_type == .int) {
                    return error.TypeMismatch;
                }
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
        .unwind => {
            if (!function.fallible) return error.NotFallible;
        },
    }
}

/// Can the instruction in `register` come back errored rather than
/// answering?  Only these two shapes can, so only these two may be
/// asked about by `errored` — an `errored` naming anything else is a
/// module that could branch on a word nobody wrote.
fn raisesError(program: *const Program, function: *const Function, register: Register) bool {
    return switch (function.instructions[register]) {
        .call => |call| call.function < program.functions.len and
            program.functions[call.function].fallible,
        .intrinsic => |intrinsic| switch (intrinsic.kind) {
            .file_read,
            .file_write,
            .file_append,
            .file_delete,
            .file_rename,
            .dir_list,
            => true,
            else => false,
        },
        else => false,
    };
}

// ---------------------------------------------------------------------------
// One intrinsic call, argument by argument
// ---------------------------------------------------------------------------

fn verifyIntrinsic(
    program: *const Program,
    function: *const Function,
    defined: *const std.AutoHashMapUnmanaged(Register, void),
    register: Register,
    call: Instruction.IntrinsicCall,
) VerifyError!void {
    const result = function.result_types[register];
    if (call.arguments.len > 6) return error.BadIntrinsic;
    // `errored` names an *instruction*, not a value: the call it asks
    // about may return nothing at all (`-> !`), so its argument never
    // goes through the operand pass below.
    if (call.kind == .errored) {
        if (call.arguments.len != 1) return error.BadIntrinsic;
        const asked = call.arguments[0];
        if (asked >= function.instructions.len) return error.UndefinedRegister;
        if (!defined.contains(asked)) return error.UndefinedRegister;
        if (!raisesError(program, function, asked)) return error.BadIntrinsic;
        return expectType(result, .boolean);
    }
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
        .sqrt, .floor, .ceil, .trunc => {
            try exactly(arguments, 1);
            try expectType(arguments[0], .float);
            try expectType(result, .float);
        },
        .compare_int_float => {
            try exactly(arguments, 3);
            // The operator travels as an Int because an intrinsic call
            // carries registers and no immediates; which operator it
            // names is trusted exactly as an instruction's type is.
            try expectType(arguments[0], .int);
            try expectType(arguments[1], .int);
            try expectType(arguments[2], .float);
            try expectType(result, .boolean);
        },
        .len => {
            try exactly(arguments, 1);
            const measurable = arguments[0] == .string or arguments[0] == .heap;
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
        .none_value => {
            try exactly(arguments, 0);
            if (result != .optional) return error.BadIntrinsic;
        },
        .is_none => {
            try exactly(arguments, 1);
            if (arguments[0] != .optional) return error.BadIntrinsic;
            try expectType(result, .boolean);
        },
        .optional_wrap => {
            try exactly(arguments, 1);
            const widened = Type.optionalOf(arguments[0]) orelse return error.BadIntrinsic;
            try expectType(result, widened);
        },
        .optional_unwrap => {
            try exactly(arguments, 1);
            const payload = arguments[0].held() orelse return error.BadIntrinsic;
            try expectType(result, payload);
        },
        // Settled above, before the operands were typed.
        .errored => return error.BadIntrinsic,
        .forget => {
            try exactly(arguments, 0);
            try expectType(result, .none);
        },
        .raise_error => {
            if (!function.fallible) return error.NotFallible;
            try exactly(arguments, 1);
            try expectType(arguments[0], .string);
            try expectType(result, .none);
        },
        .own_storage, .drop_storage, .export_storage => {
            try exactly(arguments, 1);
            try expectType(result, arguments[0]);
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
            try expectType(result, if (call.kind == .parse_int)
                .{ .optional = .int }
            else
                .{ .optional = .float });
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
            // Answers nothing: a write that did not land is an error
            // in the channel, not a Bool (docs/FAILURE.md).
            try expectType(result, .none);
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
        .key_text => {
            try exactly(arguments, 0);
            try expectType(result, .string);
        },
        .key_read => {
            // `String?`: a keyboard that has run dry has nothing to
            // hand over, which is absence and not news (docs/FAILURE.md).
            try exactly(arguments, 0);
            try expectType(result, .{ .optional = .string });
        },
        .read_line, .env_get => {
            try exactly(arguments, 1);
            try expectType(arguments[0], .string);
            try expectType(result, .{ .optional = .string });
        },
        .print_error => {
            try exactly(arguments, 1);
            try expectType(arguments[0], .string);
            try expectType(result, .none);
        },
        .clock_ms => {
            try exactly(arguments, 0);
            try expectType(result, .int);
        },
        .sleep_ms => {
            try exactly(arguments, 1);
            try expectType(arguments[0], .int);
            try expectType(result, .none);
        },
        .file_append, .file_rename => {
            try exactly(arguments, 2);
            try expectType(arguments[0], .string);
            try expectType(arguments[1], .string);
            // Answers nothing: what the world said travels in the
            // error channel, like every other file service.
            try expectType(result, .none);
        },
        .file_delete => {
            try exactly(arguments, 1);
            try expectType(arguments[0], .string);
            try expectType(result, .none);
        },
        .dir_list => {
            try exactly(arguments, 1);
            try expectType(arguments[0], .string);
            const shape = try heapShape(program, result);
            if (shape != .list or shape.list != .string) return error.BadIntrinsic;
        },
    }
}

// ---------------------------------------------------------------------------
// Small shared checks
// ---------------------------------------------------------------------------

fn exactly(arguments: []const Type, count: usize) VerifyError!void {
    if (arguments.len != count) return error.BadIntrinsic;
}

fn heapShape(program: *const Program, of: Type) VerifyError!types.HeapType {
    if (of != .heap) return error.BadIntrinsic;
    if (of.heap >= program.heap_types.len) return error.BadStruct;
    return program.heap_types[of.heap];
}
