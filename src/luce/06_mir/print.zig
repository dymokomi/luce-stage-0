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

    // An enum prints its members with their numbers: the values are
    // what the compare-and-branch trees below are written against, so a
    // reader of the IR can check an arm against the name it came from.
    for (program.enums) |declared| {
        const backing_name = try typeName(allocator, program, declared.backing.asType());
        defer allocator.free(backing_name);
        try appendPrint(&text, allocator, "enum {s}({s}):\n", .{ declared.name, backing_name });
        for (declared.members) |member| {
            try appendPrint(&text, allocator, "    {s} = {d}\n", .{ member.name, member.value });
        }
    }

    // A union prints its members with their payload fields: the member
    // *index* is what `variant_make` and the compare trees below carry,
    // so the declaration order here is the key to reading them.
    for (program.variants) |declared| {
        try appendPrint(&text, allocator, "union {s}:\n", .{declared.name});
        for (declared.members) |member| {
            try appendPrint(&text, allocator, "    {s}", .{member.name});
            if (member.fields.len != 0) {
                try text.append(allocator, '(');
                for (member.fields, 0..) |field, index| {
                    if (index != 0) try text.appendSlice(allocator, ", ");
                    const field_type_name = try typeName(allocator, program, field.field_type);
                    defer allocator.free(field_type_name);
                    try appendPrint(&text, allocator, "{s}: {s}", .{ field.name, field_type_name });
                }
                try text.append(allocator, ')');
            }
            try text.append(allocator, '\n');
        }
    }

    for (program.container_constants, 0..) |constant, index| {
        const constant_type_name = try typeName(allocator, program, .{ .heap = constant.heap });
        defer allocator.free(constant_type_name);
        try appendPrint(&text, allocator, "constant container#{d} {s}: {s} = ", .{
            index,
            constant.name,
            constant_type_name,
        });
        switch (constant.payload) {
            .sequence => |values| {
                try text.append(allocator, '[');
                for (values, 0..) |value, value_index| {
                    if (value_index != 0) try text.appendSlice(allocator, ", ");
                    try printConstantValue(&text, allocator, program, value);
                }
                try text.appendSlice(allocator, "]\n");
            },
            .map => |entries| {
                try text.append(allocator, '{');
                for (entries, 0..) |entry, entry_index| {
                    if (entry_index != 0) try text.appendSlice(allocator, ", ");
                    try printConstantValue(&text, allocator, program, entry.key);
                    try text.appendSlice(allocator, ": ");
                    try printConstantValue(&text, allocator, program, entry.value);
                }
                try text.appendSlice(allocator, "}\n");
            },
        }
    }

    for (program.functions) |*function| {
        try appendPrint(&text, allocator, "func {s}(", .{function.name});
        for (function.locals[0..function.parameter_count], 0..) |local, index| {
            if (index != 0) try text.appendSlice(allocator, ", ");
            const parameter_type_name = try typeName(allocator, program, local.local_type);
            defer allocator.free(parameter_type_name);
            try appendPrint(&text, allocator, "{s}{s}: {s}", .{
                if (local.inout) "inout " else "",
                local.name,
                parameter_type_name,
            });
        }
        const return_type_name = try typeName(allocator, program, function.return_type);
        defer allocator.free(return_type_name);
        try appendPrint(&text, allocator, ") -> {s}{s}\n", .{
            return_type_name,
            if (function.fallible) "!" else "",
        });
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
    return types.typeName(allocator, program.structs, program.heap_types, program.enums, program.variants, program.signatures, of);
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

fn printConstantValue(
    text: *std.ArrayList(u8),
    allocator: Allocator,
    program: *const Program,
    constant: defs.ConstantValue,
) error{OutOfMemory}!void {
    switch (constant) {
        .boolean => |value| try appendPrint(text, allocator, "{}", .{value}),
        .long => |value| try appendPrint(text, allocator, "{d}", .{value}),
        .double => |value| try appendPrint(text, allocator, "{d}", .{value}),
        .string => |index| try appendPrint(text, allocator, "data#{d}", .{index}),
        .strukt => |value| {
            const layout = program.structs[value.layout];
            try appendPrint(text, allocator, "{s}(", .{layout.name});
            for (value.fields, layout.fields, 0..) |field, declared, index| {
                if (index != 0) try text.appendSlice(allocator, ", ");
                try appendPrint(text, allocator, "{s}=", .{declared.name});
                try printConstantValue(text, allocator, program, field);
            }
            try text.append(allocator, ')');
        },
        .absent => try text.appendSlice(allocator, "none"),
    }
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
        .const_long => |value| try appendPrint(text, allocator, "const {d}", .{value}),
        .const_double => |value| try appendPrint(text, allocator, "const {d}", .{value}),
        .const_string => |constant| try appendPrint(text, allocator, "const data#{d}", .{constant}),
        .const_container => |constant| try appendPrint(text, allocator, "const_container container#{d}", .{constant}),
        .const_function => |named| if (named.receiver) |receiver|
            try appendPrint(text, allocator, "const_function {s} bound r{d}", .{
                program.functions[named.function].name,
                receiver,
            })
        else
            try appendPrint(text, allocator, "const_function {s}", .{
                program.functions[named.function].name,
            }),
        .local_get => |local| try appendPrint(text, allocator, "local_get %{d}", .{local}),
        .local_set => |set| try appendPrint(text, allocator, "local_set %{d}, r{d}", .{ set.local, set.value }),
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
        .convert => |operand| try appendPrint(text, allocator, "convert r{d}", .{operand}),
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
        .variant_make => |make| {
            try appendPrint(text, allocator, "variant_make {s}.{s}", .{
                program.variants[make.variant].name,
                program.variants[make.variant].members[make.member].name,
            });
            for (make.fields) |field| try appendPrint(text, allocator, ", r{d}", .{field});
        },
        .variant_tag => |tag| try appendPrint(text, allocator, "variant_tag r{d}", .{tag.target}),
        .variant_field => |get| try appendPrint(text, allocator, "variant_field r{d}, {s}.{s}.{s}", .{
            get.target,
            program.variants[get.variant].name,
            program.variants[get.variant].members[get.member].name,
            program.variants[get.variant].members[get.member].fields[get.field].name,
        }),
        .call => |call| {
            try appendPrint(text, allocator, "call {s}", .{program.functions[call.function].name});
            for (call.arguments) |argument| try appendPrint(text, allocator, ", r{d}", .{argument});
        },
        .call_inout => |call| {
            try appendPrint(text, allocator, "call_inout {s}, &%{d}", .{
                program.functions[call.function].name,
                call.receiver,
            });
            for (call.arguments) |argument| try appendPrint(text, allocator, ", r{d}", .{argument});
        },
        .spawn => |call| {
            try appendPrint(text, allocator, "spawn {s}", .{program.functions[call.function].name});
            for (call.arguments) |argument| try appendPrint(text, allocator, ", r{d}", .{argument});
        },
        .call_indirect => |call| {
            const signature_name = try typeName(allocator, program, .{ .function = call.signature });
            defer allocator.free(signature_name);
            try appendPrint(text, allocator, "call_indirect r{d} : {s}", .{ call.callee, signature_name });
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
        .unwind => try appendPrint(text, allocator, "unwind", .{}),
    }
    try text.append(allocator, '\n');
}
