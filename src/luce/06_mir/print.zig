//! IR pretty-printer — render a readable dump of the whole program.

const std = @import("std");
const defs = @import("defs.zig");
const types = @import("../support/types.zig");

const Allocator = std.mem.Allocator;
const Program = defs.Program;
const Function = defs.Function;
const Instruction = defs.Instruction;
const Register = defs.Register;
const Type = types.Type;

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
