//! The Luce IR interpreter — the first engine behind the backend
//! boundary.
//!
//! Deterministic and safe: checked integer arithmetic, explicit
//! conversion range checks, a step budget standing in for a deadline,
//! and a call-depth limit.  All temporary storage comes from the
//! evaluation arena; the interpreter itself allocates nothing that
//! outlives one evaluation.

const std = @import("std");
const ir = @import("ir.zig");
const fabric = @import("fabric.zig");
const backend = @import("backend.zig");

const Allocator = std.mem.Allocator;
const RuntimeValue = backend.RuntimeValue;
const InputValue = backend.InputValue;
const Result = backend.Result;
const Budget = backend.Budget;

pub fn run(
    arena: Allocator,
    program: *const ir.Program,
    inputs: []const InputValue,
    outputs: []?RuntimeValue,
    budget: Budget,
    host: ?backend.Host,
) error{OutOfMemory}!Result {
    // Gate on availability before executing anything: a program whose
    // read inputs are not all available computes nothing.
    for (program.reads) |port| {
        if (port >= inputs.len or inputs[port] == .unavailable) return .unavailable;
    }

    var machine: Machine = .{
        .arena = arena,
        .program = program,
        .inputs = inputs,
        .outputs = outputs,
        .steps = budget.steps,
        .depth_left = budget.call_depth,
        .host = host,
    };
    switch (try machine.call(program.entry_function, &.{})) {
        .value => return .{ .success = machine.intents },
        .trap => |trap| return .{ .trap = trap },
    }
}

const CallOutcome = union(enum) {
    value: RuntimeValue,
    trap: backend.Trap,
};

const Machine = struct {
    arena: Allocator,
    program: *const ir.Program,
    inputs: []const InputValue,
    outputs: []?RuntimeValue,
    steps: u64,
    depth_left: u32,
    host: ?backend.Host,
    /// Intents recorded by the fabric builtins, in order.  Arena-owned;
    /// the caller copies what it applies.
    intents: fabric.Intents = .{},

    fn trap(self: *Machine, code: ir.TrapCode) CallOutcome {
        _ = self;
        return .{ .trap = .{ .code = code, .message = code.message() } };
    }

    fn call(self: *Machine, function_index: u32, arguments: []const RuntimeValue) error{OutOfMemory}!CallOutcome {
        if (self.depth_left == 0) return self.trap(.call_depth_exceeded);
        self.depth_left -= 1;
        defer self.depth_left += 1;

        const function = &self.program.functions[function_index];
        const registers = try self.arena.alloc(RuntimeValue, function.instructions.len);
        const locals = try self.arena.alloc(RuntimeValue, function.locals.len);
        @memset(locals, .none);
        @memcpy(locals[0..arguments.len], arguments);

        var block: ir.BlockId = 0;
        dispatch: while (true) {
            for (self.program.functions[function_index].blocks[block].items) |item| {
                if (self.steps == 0) return self.trap(.step_budget_exhausted);
                self.steps -= 1;

                const instruction = function.instructions[item];
                switch (instruction) {
                    .const_boolean => |value| registers[item] = .{ .boolean = value },
                    .const_int => |value| registers[item] = .{ .int = value },
                    .const_float => |value| registers[item] = .{ .float = value },
                    .const_data => |data| {
                        const stored = self.program.constants[data.constant];
                        registers[item] = if (data.data_type == .string)
                            .{ .string = stored }
                        else
                            .{ .bytes = stored };
                    },
                    .local_get => |local| registers[item] = locals[local],
                    .local_set => |set| locals[set.local] = registers[set.value],
                    .input_load => |port| registers[item] = self.inputs[port].value,
                    .output_store => |store| self.outputs[store.port] = registers[store.value],
                    .binary => |operation| {
                        switch (try self.binary(operation, registers)) {
                            .value => |value| registers[item] = value,
                            .trap => |failed| return .{ .trap = failed },
                        }
                    },
                    .unary => |operation| {
                        switch (operation.op) {
                            .logic_not => registers[item] = .{ .boolean = !registers[operation.operand].boolean },
                            .negate => switch (registers[operation.operand]) {
                                .int => |value| {
                                    if (value == std.math.minInt(i64)) return self.trap(.integer_overflow);
                                    registers[item] = .{ .int = -value };
                                },
                                .float => |value| registers[item] = .{ .float = -value },
                                else => unreachable,
                            },
                        }
                    },
                    .convert => |operation| switch (operation.kind) {
                        .int_to_float => registers[item] = .{
                            .float = @floatFromInt(registers[operation.operand].int),
                        },
                        .float_to_int => {
                            const value = registers[operation.operand].float;
                            if (std.math.isNan(value) or
                                value < -9223372036854775808.0 or
                                value >= 9223372036854775808.0)
                            {
                                return self.trap(.conversion_range);
                            }
                            registers[item] = .{ .int = @intFromFloat(@trunc(value)) };
                        },
                    },
                    .struct_make => |make| {
                        const fields = try self.arena.alloc(RuntimeValue, make.fields.len);
                        for (make.fields, fields) |field_register, *slot| {
                            slot.* = registers[field_register];
                        }
                        registers[item] = .{ .strukt = fields };
                    },
                    .struct_get => |get| {
                        registers[item] = registers[get.target].strukt[get.field];
                    },
                    .struct_set => |set| {
                        const source = registers[set.target].strukt;
                        const fields = try self.arena.alloc(RuntimeValue, source.len);
                        @memcpy(fields, source);
                        fields[set.field] = registers[set.value];
                        registers[item] = .{ .strukt = fields };
                    },
                    .call => |called| {
                        const arguments_storage = try self.arena.alloc(RuntimeValue, called.arguments.len);
                        for (called.arguments, arguments_storage) |argument, *slot| {
                            slot.* = registers[argument];
                        }
                        switch (try self.call(called.function, arguments_storage)) {
                            .value => |value| registers[item] = value,
                            .trap => |failed| return .{ .trap = failed },
                        }
                    },
                    .intrinsic => |operation| {
                        switch (try self.intrinsic(operation, registers)) {
                            .value => |value| registers[item] = value,
                            .trap => |failed| return .{ .trap = failed },
                        }
                    },
                    .jump => |target| {
                        block = target;
                        continue :dispatch;
                    },
                    .branch => |branched| {
                        block = if (registers[branched.condition].boolean)
                            branched.then_block
                        else
                            branched.else_block;
                        continue :dispatch;
                    },
                    .ret => |value| {
                        if (value) |returned| return .{ .value = registers[returned] };
                        return .{ .value = .none };
                    },
                    .trap => |code| return self.trap(code),
                }
            }
            unreachable; // the verifier guarantees a terminator
        }
    }

    fn binary(
        self: *Machine,
        operation: anytype,
        registers: []const RuntimeValue,
    ) error{OutOfMemory}!CallOutcome {
        const left = registers[operation.left];
        const right = registers[operation.right];
        switch (operation.op) {
            .add, .subtract, .multiply, .divide, .remainder => {},
            else => return .{ .value = .{ .boolean = self.compare(operation.op, left, right) } },
        }

        switch (left) {
            .int => |left_int| {
                const right_int = right.int;
                switch (operation.op) {
                    .add => {
                        const result = @addWithOverflow(left_int, right_int);
                        if (result[1] != 0) return self.trap(.integer_overflow);
                        return .{ .value = .{ .int = result[0] } };
                    },
                    .subtract => {
                        const result = @subWithOverflow(left_int, right_int);
                        if (result[1] != 0) return self.trap(.integer_overflow);
                        return .{ .value = .{ .int = result[0] } };
                    },
                    .multiply => {
                        const result = @mulWithOverflow(left_int, right_int);
                        if (result[1] != 0) return self.trap(.integer_overflow);
                        return .{ .value = .{ .int = result[0] } };
                    },
                    .divide => {
                        if (right_int == 0) return self.trap(.divide_by_zero);
                        if (left_int == std.math.minInt(i64) and right_int == -1) {
                            return self.trap(.integer_overflow);
                        }
                        return .{ .value = .{ .int = @divTrunc(left_int, right_int) } };
                    },
                    .remainder => {
                        if (right_int == 0) return self.trap(.divide_by_zero);
                        if (left_int == std.math.minInt(i64) and right_int == -1) {
                            return self.trap(.integer_overflow);
                        }
                        return .{ .value = .{ .int = @rem(left_int, right_int) } };
                    },
                    else => unreachable,
                }
            },
            .float => |left_float| {
                const right_float = right.float;
                // IEEE 754 semantics: division by zero and overflow
                // produce infinities and NaN, never traps.
                const computed: f64 = switch (operation.op) {
                    .add => left_float + right_float,
                    .subtract => left_float - right_float,
                    .multiply => left_float * right_float,
                    .divide => left_float / right_float,
                    .remainder => @rem(left_float, right_float),
                    else => unreachable,
                };
                return .{ .value = .{ .float = computed } };
            },
            .string => |left_string| {
                // The analyzer only admits + for strings.
                const joined = try std.mem.concat(self.arena, u8, &.{ left_string, right.string });
                return .{ .value = .{ .string = joined } };
            },
            else => unreachable,
        }
    }

    fn compare(self: *const Machine, operation: ir.BinaryOp, left: RuntimeValue, right: RuntimeValue) bool {
        switch (left) {
            .int => |value| {
                const other = right.int;
                return switch (operation) {
                    .equal => value == other,
                    .not_equal => value != other,
                    .less => value < other,
                    .less_equal => value <= other,
                    .greater => value > other,
                    .greater_equal => value >= other,
                    else => unreachable,
                };
            },
            .float => |value| {
                const other = right.float;
                return switch (operation) {
                    .equal => value == other,
                    .not_equal => value != other,
                    .less => value < other,
                    .less_equal => value <= other,
                    .greater => value > other,
                    .greater_equal => value >= other,
                    else => unreachable,
                };
            },
            .string => |value| {
                const order = std.mem.order(u8, value, right.string);
                return switch (operation) {
                    .equal => order == .eq,
                    .not_equal => order != .eq,
                    .less => order == .lt,
                    .less_equal => order != .gt,
                    .greater => order == .gt,
                    .greater_equal => order != .lt,
                    else => unreachable,
                };
            },
            .bytes => |value| {
                const same = std.mem.eql(u8, value, right.bytes);
                return if (operation == .equal) same else !same;
            },
            .boolean => |value| {
                const same = value == right.boolean;
                return if (operation == .equal) same else !same;
            },
            .strukt => |value| {
                var same = true;
                for (value, right.strukt) |left_field, right_field| {
                    if (!self.compare(.equal, left_field, right_field)) same = false;
                }
                return if (operation == .equal) same else !same;
            },
            .none => unreachable,
        }
    }

    fn intrinsic(
        self: *Machine,
        operation: anytype,
        registers: []const RuntimeValue,
    ) error{OutOfMemory}!CallOutcome {
        const arguments = operation.arguments;
        switch (operation.kind) {
            .abs => switch (registers[arguments[0]]) {
                .int => |value| {
                    if (value == std.math.minInt(i64)) return self.trap(.integer_overflow);
                    return .{ .value = .{ .int = @intCast(@abs(value)) } };
                },
                .float => |value| return .{ .value = .{ .float = @abs(value) } },
                else => unreachable,
            },
            .min, .max => {
                const wants_minimum = operation.kind == .min;
                switch (registers[arguments[0]]) {
                    .int => |left| {
                        const right = registers[arguments[1]].int;
                        const chosen = if (wants_minimum) @min(left, right) else @max(left, right);
                        return .{ .value = .{ .int = chosen } };
                    },
                    .float => |left| {
                        const right = registers[arguments[1]].float;
                        const chosen = if (wants_minimum) @min(left, right) else @max(left, right);
                        return .{ .value = .{ .float = chosen } };
                    },
                    else => unreachable,
                }
            },
            .clamp => switch (registers[arguments[0]]) {
                .int => |value| {
                    const low = registers[arguments[1]].int;
                    const high = registers[arguments[2]].int;
                    return .{ .value = .{ .int = @min(@max(value, low), high) } };
                },
                .float => |value| {
                    const low = registers[arguments[1]].float;
                    const high = registers[arguments[2]].float;
                    return .{ .value = .{ .float = @min(@max(value, low), high) } };
                },
                else => unreachable,
            },
            .sqrt => return .{ .value = .{ .float = @sqrt(registers[arguments[0]].float) } },
            .floor => return .{ .value = .{ .float = @floor(registers[arguments[0]].float) } },
            .ceil => return .{ .value = .{ .float = @ceil(registers[arguments[0]].float) } },
            .len => {
                const measured = switch (registers[arguments[0]]) {
                    .string => |value| value.len,
                    .bytes => |value| value.len,
                    else => unreachable,
                };
                return .{ .value = .{ .int = @intCast(measured) } };
            },
            .string_slice => {
                const value = registers[arguments[0]].string;
                const start = registers[arguments[1]].int;
                const end = registers[arguments[2]].int;
                if (start < 0 or end < start or end > value.len) {
                    return self.trap(.string_bounds);
                }
                const start_index: usize = @intCast(start);
                const end_index: usize = @intCast(end);
                if (!isStringBoundary(value, start_index) or
                    !isStringBoundary(value, end_index))
                {
                    return self.trap(.string_boundary);
                }
                return .{ .value = .{ .string = value[start_index..end_index] } };
            },
            .string_byte => {
                const value = registers[arguments[0]].string;
                const index = registers[arguments[1]].int;
                if (index < 0 or index >= value.len) return self.trap(.string_bounds);
                return .{ .value = .{ .int = value[@intCast(index)] } };
            },
            .assert_true => {
                if (!registers[arguments[0]].boolean) return self.trap(.assertion_failed);
                return .{ .value = .none };
            },
            .trap_message => {
                return .{ .trap = .{
                    .code = .explicit_trap,
                    .message = registers[arguments[0]].string,
                } };
            },
            .read_file => {
                const host = self.host orelse return self.trap(.file_host_unavailable);
                const capability = registers[arguments[0]].bytes;
                const path = registers[arguments[1]].string;
                return switch (try host.readFileFn(host.context, self.arena, capability, path)) {
                    .content => |content| .{ .value = .{ .string = content } },
                    .denied => self.trap(.file_capability_denied),
                    .failed => self.trap(.file_read_failed),
                };
            },
            .script_directory => {
                const host = self.host orelse return self.trap(.file_host_unavailable);
                const callback = host.scriptDirectoryFn orelse
                    return self.trap(.file_host_unavailable);
                const capability = (try callback(host.context, self.arena)) orelse
                    return self.trap(.file_host_unavailable);
                return .{ .value = .{ .bytes = capability } };
            },
            .fabric_image => {
                const path = registers[arguments[0]].string;
                const pages = registers[arguments[1]].int;
                if (path.len == 0 or pages <= 0) return self.trap(.invalid_image);
                try self.intents.images.append(self.arena, .{
                    .path = path,
                    .pages = @intCast(pages),
                });
                return .{ .value = .none };
            },
            .fabric_create => {
                const handle: i64 = @intCast(self.intents.texels.items.len);
                try self.intents.texels.append(self.arena, .{
                    .name = registers[arguments[0]].string,
                });
                return .{ .value = .{ .int = handle } };
            },
            .fabric_input, .fabric_output => {
                const intent = self.intentAt(registers[arguments[0]].int) orelse
                    return self.trap(.invalid_handle);
                const declared = fabric.portTypeNamed(registers[arguments[2]].string) orelse
                    return self.trap(.invalid_port_type);
                const spec: fabric.PortSpec = .{
                    .name = registers[arguments[1]].string,
                    .declared = declared,
                };
                if (operation.kind == .fabric_input) {
                    try intent.inputs.append(self.arena, spec);
                } else {
                    try intent.outputs.append(self.arena, spec);
                }
                return .{ .value = .none };
            },
            .fabric_content => {
                const intent = self.intentAt(registers[arguments[0]].int) orelse
                    return self.trap(.invalid_handle);
                intent.content = registers[arguments[1]].string;
                return .{ .value = .none };
            },
            .fabric_evaluator => {
                const intent = self.intentAt(registers[arguments[0]].int) orelse
                    return self.trap(.invalid_handle);
                intent.evaluator = registers[arguments[1]].string;
                return .{ .value = .none };
            },
            .fabric_set => {
                const intent = self.intentAt(registers[arguments[0]].int) orelse
                    return self.trap(.invalid_handle);
                const value: fabric.SourceValue = switch (registers[arguments[2]]) {
                    .boolean => |flag| .{ .boolean = flag },
                    .int => |number| .{ .int = number },
                    .float => |number| .{ .float = number },
                    .string => |text| .{ .text = text },
                    else => unreachable,
                };
                try intent.sets.append(self.arena, .{
                    .output = registers[arguments[1]].string,
                    .value = value,
                });
                return .{ .value = .none };
            },
        }
    }

    fn intentAt(self: *Machine, handle: i64) ?*fabric.NewTexel {
        if (handle < 0 or handle >= self.intents.texels.items.len) return null;
        return &self.intents.texels.items[@intCast(handle)];
    }
};

fn isStringBoundary(value: []const u8, index: usize) bool {
    return index == value.len or value[index] & 0xc0 != 0x80;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const compile_mod = @import("compile.zig");
const types = @import("types.zig");

const Bench = struct {
    program: ir.Program,
    arena: std.heap.ArenaAllocator,
    outputs: []?RuntimeValue,

    fn setup(source: []const u8, schema: types.PortSchema, options: types.CompileOptions) !Bench {
        var result = try compile_mod.compile(testing.allocator, source, schema, options);
        switch (result) {
            .success => {},
            .failure => |*diagnostics| {
                const rendered = try diagnostics.render(testing.allocator, source);
                defer testing.allocator.free(rendered);
                std.debug.print("unexpected diagnostics:\n{s}", .{rendered});
                result.deinit();
                return error.TestUnexpectedResult;
            },
        }
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer arena.deinit();
        const outputs = try arena.allocator().alloc(?RuntimeValue, schema.outputs.len);
        @memset(outputs, null);
        return .{ .program = result.success, .arena = arena, .outputs = outputs };
    }

    fn deinit(self: *Bench) void {
        self.arena.deinit();
        self.program.deinit();
    }

    fn evaluate(self: *Bench, inputs: []const InputValue) !Result {
        @memset(self.outputs, null);
        return backend.evaluate(
            self.arena.allocator(),
            &self.program,
            inputs,
            self.outputs,
            .{ .steps = 200_000, .call_depth = 64 },
        );
    }

    fn evaluateHosted(self: *Bench, inputs: []const InputValue, host: backend.Host) !Result {
        @memset(self.outputs, null);
        return backend.evaluateHosted(
            self.arena.allocator(),
            &self.program,
            inputs,
            self.outputs,
            .{ .steps = 200_000, .call_depth = 64 },
            host,
        );
    }
};

test "the plan's vertical slice: smooth pointer transform" {
    var bench = try Bench.setup(
        \\struct Point:
        \\    x: Float
        \\    y: Float
        \\
        \\func smooth(current: Point, target: Point, amount: Float) -> Point:
        \\    return Point(
        \\        x = current.x + (target.x - current.x) * amount,
        \\        y = current.y + (target.y - current.y) * amount,
        \\    )
        \\
        \\func evaluate(input: Input, output: Output):
        \\    let previous = Point(x = input.previous_x, y = input.previous_y)
        \\    let pointer = Point(x = input.pointer_x, y = input.pointer_y)
        \\    let eased = smooth(previous, pointer, input.amount)
        \\    output.x = eased.x
        \\    output.y = eased.y
        \\
    , .{
        .inputs = &.{
            .{ .name = "previous_x", .declared = .float },
            .{ .name = "previous_y", .declared = .float },
            .{ .name = "pointer_x", .declared = .float },
            .{ .name = "pointer_y", .declared = .float },
            .{ .name = "amount", .declared = .float },
        },
        .outputs = &.{
            .{ .name = "x", .declared = .float },
            .{ .name = "y", .declared = .float },
        },
    }, .{});
    defer bench.deinit();

    const result = try bench.evaluate(&.{
        .{ .value = .{ .float = 0.0 } },
        .{ .value = .{ .float = 0.0 } },
        .{ .value = .{ .float = 10.0 } },
        .{ .value = .{ .float = -4.0 } },
        .{ .value = .{ .float = 0.25 } },
    });
    try testing.expect(result == .success);
    try testing.expectEqual(@as(f64, 2.5), bench.outputs[0].?.float);
    try testing.expectEqual(@as(f64, -1.0), bench.outputs[1].?.float);
}

test "namespaced struct functions execute through qualified calls" {
    var bench = try Bench.setup(
        \\struct Math:
        \\    func twice(value: Int) -> Int:
        \\        return value * 2
        \\
        \\    func plus(left: Int, right: Int) -> Int:
        \\        return left + right
        \\
        \\func evaluate(input: Input, output: Output):
        \\    output.value = Math.twice(Math.plus(input.left, input.right))
        \\
    , .{
        .inputs = &.{
            .{ .name = "left", .declared = .int },
            .{ .name = "right", .declared = .int },
        },
        .outputs = &.{.{ .name = "value", .declared = .int }},
    }, .{});
    defer bench.deinit();

    const result = try bench.evaluate(&.{
        .{ .value = .{ .int = 3 } },
        .{ .value = .{ .int = 4 } },
    });
    try testing.expect(result == .success);
    try testing.expectEqual(@as(i64, 14), bench.outputs[0].?.int);
}

test "loops, recursion, strings, and builtins compute" {
    var bench = try Bench.setup(
        \\func factorial(value: Int) -> Int:
        \\    if value <= 1:
        \\        return 1
        \\    return value * factorial(value - 1)
        \\
        \\func evaluate(input: Input, output: Output):
        \\    var total = 0
        \\    for index in range(1, 11):
        \\        total = total + index
        \\    output.sum = total
        \\    output.fact = factorial(10)
        \\    output.label = "sum " + input.name
        \\    output.small = min(clamp(total, 0, 40), abs(-3))
        \\
    , .{
        .inputs = &.{.{ .name = "name", .declared = .string }},
        .outputs = &.{
            .{ .name = "sum", .declared = .int },
            .{ .name = "fact", .declared = .int },
            .{ .name = "label", .declared = .string },
            .{ .name = "small", .declared = .int },
        },
    }, .{});
    defer bench.deinit();

    const result = try bench.evaluate(&.{.{ .value = .{ .string = "of ten" } }});
    try testing.expect(result == .success);
    try testing.expectEqual(@as(i64, 55), bench.outputs[0].?.int);
    try testing.expectEqual(@as(i64, 3628800), bench.outputs[1].?.int);
    try testing.expectEqualStrings("sum of ten", bench.outputs[2].?.string);
    try testing.expectEqual(@as(i64, 3), bench.outputs[3].?.int);
}

test "checked string intrinsics slice and inspect UTF-8 bytes" {
    var bench = try Bench.setup(
        \\func evaluate(input: Input, output: Output):
        \\    output.prefix = slice(input.text, 0, 2)
        \\    output.middle = slice(input.text, 2, 6)
        \\    output.byte = byte_at(input.text, 2)
        \\
    , .{
        .inputs = &.{.{ .name = "text", .declared = .string }},
        .outputs = &.{
            .{ .name = "prefix", .declared = .string },
            .{ .name = "middle", .declared = .string },
            .{ .name = "byte", .declared = .int },
        },
    }, .{});
    defer bench.deinit();

    const result = try bench.evaluate(&.{.{ .value = .{ .string = "ab\xF0\x9F\x99\x82cd\nnext" } }});
    try testing.expect(result == .success);
    try testing.expectEqualStrings("ab", bench.outputs[0].?.string);
    try testing.expectEqualStrings("\xF0\x9F\x99\x82", bench.outputs[1].?.string);
    try testing.expectEqual(@as(i64, 0xf0), bench.outputs[2].?.int);
}

test "string intrinsics implement multiline UTF-8-safe edits" {
    var bench = try Bench.setup(
        \\func continuation(byte: Int) -> Bool:
        \\    return byte >= 128 and byte < 192
        \\
        \\func previous(value: String, cursor: Int) -> Int:
        \\    var at = cursor - 1
        \\    while at > 0 and continuation(byte_at(value, at)):
        \\        at = at - 1
        \\    return at
        \\
        \\func evaluate(input: Input, output: Output):
        \\    if input.insert:
        \\        output.text = slice(input.text, 0, input.cursor) + input.added + slice(input.text, input.cursor, len(input.text))
        \\        output.cursor = input.cursor + len(input.added)
        \\    else:
        \\        let before = previous(input.text, input.cursor)
        \\        output.text = slice(input.text, 0, before) + slice(input.text, input.cursor, len(input.text))
        \\        output.cursor = before
        \\
    , .{
        .inputs = &.{
            .{ .name = "insert", .declared = .boolean },
            .{ .name = "text", .declared = .string },
            .{ .name = "cursor", .declared = .int },
            .{ .name = "added", .declared = .string },
        },
        .outputs = &.{
            .{ .name = "text", .declared = .string },
            .{ .name = "cursor", .declared = .int },
        },
    }, .{});
    defer bench.deinit();

    const original = "A\xF0\x9F\x99\x82\nB";
    const inserted = try bench.evaluate(&.{
        .{ .value = .{ .boolean = true } },
        .{ .value = .{ .string = original } },
        .{ .value = .{ .int = 5 } },
        .{ .value = .{ .string = "x" } },
    });
    try testing.expect(inserted == .success);
    try testing.expectEqualStrings("A\xF0\x9F\x99\x82x\nB", bench.outputs[0].?.string);
    try testing.expectEqual(@as(i64, 6), bench.outputs[1].?.int);

    const erased = try bench.evaluate(&.{
        .{ .value = .{ .boolean = false } },
        .{ .value = .{ .string = original } },
        .{ .value = .{ .int = 5 } },
        .{ .value = .{ .string = "" } },
    });
    try testing.expect(erased == .success);
    try testing.expectEqualStrings("A\nB", bench.outputs[0].?.string);
    try testing.expectEqual(@as(i64, 1), bench.outputs[1].?.int);
}

test "checked string intrinsics trap on bounds and UTF-8 splits" {
    var bench = try Bench.setup(
        \\func evaluate(input: Input, output: Output):
        \\    if input.mode == 1:
        \\        output.text = slice(input.text, -1, 0)
        \\    elif input.mode == 2:
        \\        output.text = slice(input.text, 0, len(input.text) + 1)
        \\    elif input.mode == 3:
        \\        output.text = slice(input.text, 0, 2)
        \\    else:
        \\        output.byte = byte_at(input.text, len(input.text))
        \\
    , .{
        .inputs = &.{
            .{ .name = "mode", .declared = .int },
            .{ .name = "text", .declared = .string },
        },
        .outputs = &.{
            .{ .name = "text", .declared = .string },
            .{ .name = "byte", .declared = .int },
        },
    }, .{});
    defer bench.deinit();

    const text: InputValue = .{ .value = .{ .string = "a\xF0\x9F\x99\x82b" } };
    try expectTrap(&bench, &.{ .{ .value = .{ .int = 1 } }, text }, .string_bounds);
    try expectTrap(&bench, &.{ .{ .value = .{ .int = 2 } }, text }, .string_bounds);
    try expectTrap(&bench, &.{ .{ .value = .{ .int = 3 } }, text }, .string_boundary);
    try expectTrap(&bench, &.{ .{ .value = .{ .int = 4 } }, text }, .string_bounds);
}

test "string intrinsics reject wrong argument types" {
    var result = try compile_mod.compile(testing.allocator,
        \\func evaluate(input: Input, output: Output):
        \\    output.text = slice(1, 0, 1)
        \\
    , .{ .outputs = &.{.{ .name = "text", .declared = .string }} }, .{});
    defer result.deinit();
    try testing.expect(result == .failure);
    try testing.expectEqualStrings("luce.sema.type", result.failure.at(0).?.code);
}

test "an unavailable read input gates evaluation" {
    var bench = try Bench.setup(
        \\func evaluate(input: Input, output: Output):
        \\    output.doubled = input.value * 2
        \\
    , .{
        .inputs = &.{.{ .name = "value", .declared = .int }},
        .outputs = &.{.{ .name = "doubled", .declared = .int }},
    }, .{});
    defer bench.deinit();

    try testing.expectEqual(Result.unavailable, try bench.evaluate(&.{.unavailable}));
    try testing.expectEqual(@as(?RuntimeValue, null), bench.outputs[0]);

    const available = try bench.evaluate(&.{.{ .value = .{ .int = 21 } }});
    try testing.expect(available == .success);
    try testing.expectEqual(@as(i64, 42), bench.outputs[0].?.int);
}

fn expectTrap(bench: *Bench, inputs: []const InputValue, code: ir.TrapCode) !void {
    const result = try bench.evaluate(inputs);
    try testing.expect(result == .trap);
    try testing.expectEqual(code, result.trap.code);
}

test "checked arithmetic and conversions trap" {
    var bench = try Bench.setup(
        \\func evaluate(input: Input, output: Output):
        \\    if input.mode == 1:
        \\        output.value = 9223372036854775807 + input.mode
        \\    elif input.mode == 2:
        \\        output.value = 1 / (input.mode - 2)
        \\    elif input.mode == 3:
        \\        output.value = Int(1.0e300)
        \\    elif input.mode == 4:
        \\        assert(input.mode == 0)
        \\    elif input.mode == 5:
        \\        trap("torn seam")
        \\    else:
        \\        output.value = 0
        \\
    , .{
        .inputs = &.{.{ .name = "mode", .declared = .int }},
        .outputs = &.{.{ .name = "value", .declared = .int }},
    }, .{});
    defer bench.deinit();

    try expectTrap(&bench, &.{.{ .value = .{ .int = 1 } }}, .integer_overflow);
    try expectTrap(&bench, &.{.{ .value = .{ .int = 2 } }}, .divide_by_zero);
    try expectTrap(&bench, &.{.{ .value = .{ .int = 3 } }}, .conversion_range);
    try expectTrap(&bench, &.{.{ .value = .{ .int = 4 } }}, .assertion_failed);

    const explicit = try bench.evaluate(&.{.{ .value = .{ .int = 5 } }});
    try testing.expect(explicit == .trap);
    try testing.expectEqual(ir.TrapCode.explicit_trap, explicit.trap.code);
    try testing.expectEqualStrings("torn seam", explicit.trap.message);

    const fine = try bench.evaluate(&.{.{ .value = .{ .int = 0 } }});
    try testing.expect(fine == .success);
}

test "the step budget stops an infinite loop" {
    var bench = try Bench.setup(
        \\func evaluate(input: Input, output: Output):
        \\    var spinning = 0
        \\    while true:
        \\        spinning = spinning + 1
        \\    output.value = spinning
        \\
    , .{ .outputs = &.{.{ .name = "value", .declared = .int }} }, .{});
    defer bench.deinit();
    try expectTrap(&bench, &.{}, .step_budget_exhausted);
}

test "unbounded recursion hits the call depth limit" {
    var bench = try Bench.setup(
        \\func dive(depth: Int) -> Int:
        \\    return dive(depth + 1)
        \\
        \\func evaluate(input: Input, output: Output):
        \\    output.value = dive(0)
        \\
    , .{ .outputs = &.{.{ .name = "value", .declared = .int }} }, .{});
    defer bench.deinit();
    try expectTrap(&bench, &.{}, .call_depth_exceeded);
}

test "unwritten outputs stay unwritten; conditional writes land" {
    var bench = try Bench.setup(
        \\func evaluate(input: Input, output: Output):
        \\    if input.flag:
        \\        output.first = 1
        \\    else:
        \\        output.second = 2
        \\
    , .{
        .inputs = &.{.{ .name = "flag", .declared = .boolean }},
        .outputs = &.{
            .{ .name = "first", .declared = .int },
            .{ .name = "second", .declared = .int },
        },
    }, .{});
    defer bench.deinit();

    const result = try bench.evaluate(&.{.{ .value = .{ .boolean = true } }});
    try testing.expect(result == .success);
    try testing.expectEqual(@as(i64, 1), bench.outputs[0].?.int);
    try testing.expectEqual(@as(?RuntimeValue, null), bench.outputs[1]);
}

test "fabric builtins record complete texel intents" {
    var bench = try Bench.setup(
        \\func evaluate(input: Input, output: Output):
        \\    let adder = create_texel(input.name)
        \\    texel_input(adder, "left", "int")
        \\    texel_input(adder, "right", "int")
        \\    texel_output(adder, "value", "int")
        \\    texel_evaluator(adder, "luce")
        \\    texel_content(adder, "func evaluate(input: Input, output: Output):\n    output.value = input.left + input.right\n")
        \\    let label = create_texel("banner")
        \\    texel_output(label, "text", "text")
        \\    texel_set(label, "text", "hello")
        \\    output.made = 2
        \\
    , .{
        .inputs = &.{.{ .name = "name", .declared = .string }},
        .outputs = &.{.{ .name = "made", .declared = .int }},
    }, .{ .allow_fabric = true });
    defer bench.deinit();

    const result = try bench.evaluate(&.{.{ .value = .{ .string = "adder" } }});
    try testing.expect(result == .success);
    const intents = result.success.texels.items;
    try testing.expectEqual(@as(usize, 2), intents.len);

    try testing.expectEqualStrings("adder", intents[0].name);
    try testing.expectEqual(@as(usize, 2), intents[0].inputs.items.len);
    try testing.expectEqualStrings("left", intents[0].inputs.items[0].name);
    try testing.expectEqual(@as(usize, 1), intents[0].outputs.items.len);
    try testing.expectEqualStrings("luce", intents[0].evaluator.?);
    try testing.expect(std.mem.indexOf(u8, intents[0].content.?, "input.left + input.right") != null);

    try testing.expectEqualStrings("banner", intents[1].name);
    try testing.expectEqualStrings("hello", intents[1].sets.items[0].value.text);
}

test "create_image records an image intent and validates its shape" {
    var bench = try Bench.setup(
        \\func evaluate(input: Input, output: Output):
        \\    if input.bad:
        \\        create_image("", 0)
        \\    else:
        \\        create_image("fresh.img", 64)
        \\
    , .{
        .inputs = &.{.{ .name = "bad", .declared = .boolean }},
    }, .{ .allow_fabric = true });
    defer bench.deinit();

    const result = try bench.evaluate(&.{.{ .value = .{ .boolean = false } }});
    try testing.expect(result == .success);
    const images = result.success.images.items;
    try testing.expectEqual(@as(usize, 1), images.len);
    try testing.expectEqualStrings("fresh.img", images[0].path);
    try testing.expectEqual(@as(u64, 64), images[0].pages);

    try expectTrap(&bench, &.{.{ .value = .{ .boolean = true } }}, .invalid_image);
}

test "fabric builtins trap on bad handles and types, and need the gate" {
    var bench = try Bench.setup(
        \\func evaluate(input: Input, output: Output):
        \\    if input.mode == 1:
        \\        texel_output(7, "value", "int")
        \\    else:
        \\        let t = create_texel("x")
        \\        texel_output(t, "value", "matrix")
        \\
    , .{
        .inputs = &.{.{ .name = "mode", .declared = .int }},
    }, .{ .allow_fabric = true });
    defer bench.deinit();
    try expectTrap(&bench, &.{.{ .value = .{ .int = 1 } }}, .invalid_handle);
    try expectTrap(&bench, &.{.{ .value = .{ .int = 2 } }}, .invalid_port_type);

    // Without the gate, the builtins do not exist.
    var gated = try compile_mod.compile(testing.allocator,
        \\func evaluate(input: Input, output: Output):
        \\    let t = create_texel("x")
        \\
    , .{}, .{});
    defer gated.deinit();
    try testing.expect(gated == .failure);
    try testing.expectEqualStrings("luce.sema.fabric", gated.failure.at(0).?.code);
}

const TestFileHost = struct {
    capability: []const u8,
    content: []const u8,
    fail_read: bool = false,

    fn read(
        context: *anyopaque,
        arena: Allocator,
        capability: []const u8,
        path: []const u8,
    ) error{OutOfMemory}!backend.FileRead {
        const self: *TestFileHost = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, capability, self.capability)) return .denied;
        if (self.fail_read) return .failed;
        if (!std.mem.eql(u8, path, "sibling.luc")) return .failed;
        return .{ .content = try arena.dupe(u8, self.content) };
    }

    fn directory(context: *anyopaque, arena: Allocator) error{OutOfMemory}!?[]const u8 {
        const self: *TestFileHost = @ptrCast(@alignCast(context));
        return try arena.dupe(u8, self.capability);
    }

    fn host(self: *TestFileHost) backend.Host {
        return .{
            .context = self,
            .readFileFn = read,
            .scriptDirectoryFn = directory,
        };
    }
};

test "file read fails closed without a host and reports stable host traps" {
    var bench = try Bench.setup(
        \\func evaluate(input: Input, output: Output):
        \\    output.text = read_file(input.capability, "sibling.luc")
        \\
    , .{
        .inputs = &.{.{ .name = "capability", .declared = .bytes }},
        .outputs = &.{.{ .name = "text", .declared = .string }},
    }, .{});
    defer bench.deinit();

    try expectTrap(&bench, &.{.{ .value = .{ .bytes = "cap" } }}, .file_host_unavailable);

    var host: TestFileHost = .{ .capability = "cap", .content = "loaded" };
    const denied = try bench.evaluateHosted(
        &.{.{ .value = .{ .bytes = "foreign" } }},
        host.host(),
    );
    try testing.expectEqual(ir.TrapCode.file_capability_denied, denied.trap.code);

    const loaded = try bench.evaluateHosted(
        &.{.{ .value = .{ .bytes = "cap" } }},
        host.host(),
    );
    try testing.expect(loaded == .success);
    try testing.expectEqualStrings("loaded", bench.outputs[0].?.string);

    host.fail_read = true;
    const failed = try bench.evaluateHosted(
        &.{.{ .value = .{ .bytes = "cap" } }},
        host.host(),
    );
    try testing.expectEqual(ir.TrapCode.file_read_failed, failed.trap.code);
}

test "script directory capability is supplied only by a hosted fabric run" {
    var bench = try Bench.setup(
        \\func evaluate(input: Input, output: Output):
        \\    output.capability = script_directory()
        \\
    , .{ .outputs = &.{.{ .name = "capability", .declared = .bytes }} }, .{
        .allow_fabric = true,
    });
    defer bench.deinit();

    try expectTrap(&bench, &.{}, .file_host_unavailable);
    var host: TestFileHost = .{ .capability = "directory-cap", .content = "" };
    const result = try bench.evaluateHosted(&.{}, host.host());
    try testing.expect(result == .success);
    try testing.expectEqualStrings("directory-cap", bench.outputs[0].?.bytes);
}
