//! The native engine: verified Luce IR compiled to machine code at
//! load, through the vendored MIR JIT (vendor/mir).
//!
//! This is the second engine behind the backend boundary; the
//! interpreter stays the reference implementation and the spec
//! (native_spec.zig runs both and diffs).  Semantics are identical
//! by construction: every checked operation lowers with its checks —
//! overflow, division, conversion range — and traps carry the same
//! stable codes and origins as the interpreter's.
//!
//! Milestone 1 covers the arithmetic core: Int/Float/Bool values,
//! String as an opaque handle (constants, str(), print, trap
//! messages), blocks and calls.  `supported()` says whether a whole
//! program fits; anything outside runs on the interpreter instead —
//! per-program fallback, never mixed engines.
//!
//! Lowering goes through MIR's textual form (MIR_scan_string): the
//! program prints as one MIR module, MIR assembles, verifies, and
//! generates.  Text keeps the binding surface tiny — no MIR structs
//! cross the C boundary, only the handful of functions in
//! mir_glue.c.
//!
//! The trap protocol is three words of State memory the emitted code
//! stores to (code, function, instruction) plus a depth counter; on
//! any trap the function returns a default value and every call site
//! checks the trap word and unwinds.  The hot path never reads them.

const std = @import("std");
const builtin = @import("builtin");
const ir = @import("ir.zig");
const types = @import("types.zig");
const backend = @import("backend.zig");

const Allocator = std.mem.Allocator;
const RuntimeValue = backend.RuntimeValue;
const InputValue = backend.InputValue;
const Result = backend.Result;
const Budget = backend.Budget;

/// MIR generates for these hosts; anywhere else the interpreter runs
/// everything.
pub const available = switch (builtin.cpu.arch) {
    .x86_64, .aarch64 => switch (builtin.os.tag) {
        .linux, .macos, .windows => true,
        else => false,
    },
    else => false,
};

// ---------------------------------------------------------------------------
// C bindings (mir_glue.c + the few plain functions of mir.h)
// ---------------------------------------------------------------------------

const c = struct {
    const Context = ?*anyopaque;
    const Item = ?*anyopaque;

    extern fn luce_mir_init() Context;
    extern fn luce_mir_error_text() [*:0]const u8;
    extern fn luce_mir_protected(
        ctx: Context,
        body: *const fn (payload: ?*anyopaque) callconv(.c) void,
        payload: ?*anyopaque,
    ) c_int;
    extern fn luce_mir_load_all(ctx: Context) void;

    extern fn MIR_finish(ctx: Context) void;
    extern fn MIR_scan_string(ctx: Context, str: [*:0]const u8) void;
    extern fn MIR_load_external(ctx: Context, name: [*:0]const u8, addr: ?*anyopaque) void;
    extern fn MIR_link(
        ctx: Context,
        set_interface: *const fn (ctx: Context, item: Item) callconv(.c) void,
        import_resolver: ?*const fn (name: [*:0]const u8) callconv(.c) ?*anyopaque,
    ) void;
    extern fn MIR_set_gen_interface(ctx: Context, item: Item) void;
    extern fn MIR_gen_init(ctx: Context) void;
    extern fn MIR_gen(ctx: Context, item: Item) ?*anyopaque;
    extern fn MIR_gen_finish(ctx: Context) void;
    extern fn luce_mir_find_func(ctx: Context, name: [*:0]const u8) Item;
};

// ---------------------------------------------------------------------------
// The runtime the emitted code calls into
// ---------------------------------------------------------------------------

/// The first argument of every emitted function.  Native code touches
/// only the four leading words (fixed offsets 0/8/16/24); everything
/// after is the Zig side's.
const State = extern struct {
    /// 0 = running; oom_trap = allocation failed; otherwise
    /// @intFromEnum(TrapCode) + 1.
    trap: i64 = 0,
    trap_function: i64 = 0,
    trap_instruction: i64 = 0,
    depth_left: i64,
    runtime: *Runtime,

    const oom_trap: i64 = -1;
};

const Runtime = struct {
    arena: Allocator,
    host: ?backend.Host,
    /// String handles: the program's constant pool first (handle ==
    /// constant index), then whatever str() makes at runtime.
    strings: std.ArrayList([]const u8) = .empty,
    /// The explicit trap("...") message, when that is what stopped us.
    trap_message: ?[]const u8 = null,
};

fn stateRuntime(state: *State) *Runtime {
    return state.runtime;
}

fn svcStrInt(state: *State, value: i64) callconv(.c) i64 {
    const runtime = stateRuntime(state);
    const text = std.fmt.allocPrint(runtime.arena, "{d}", .{value}) catch {
        state.trap = State.oom_trap;
        return 0;
    };
    return internString(state, text);
}

fn svcStrFloat(state: *State, value: f64) callconv(.c) i64 {
    const runtime = stateRuntime(state);
    const text = std.fmt.allocPrint(runtime.arena, "{d}", .{value}) catch {
        state.trap = State.oom_trap;
        return 0;
    };
    return internString(state, text);
}

fn svcStrBool(state: *State, value: i64) callconv(.c) i64 {
    return internString(state, if (value != 0) "true" else "false");
}

fn svcPrint(state: *State, handle: i64) callconv(.c) void {
    const runtime = stateRuntime(state);
    const host = runtime.host orelse {
        state.trap = trapWord(.host_unavailable);
        return;
    };
    const callback = host.printFn orelse {
        state.trap = trapWord(.host_unavailable);
        return;
    };
    callback(host.context, runtime.strings.items[@intCast(handle)]) catch {
        state.trap = State.oom_trap;
    };
}

fn svcTrapMessage(state: *State, handle: i64) callconv(.c) void {
    const runtime = stateRuntime(state);
    runtime.trap_message = runtime.strings.items[@intCast(handle)];
    state.trap = trapWord(.explicit_trap);
}

fn svcFrem(a: f64, b: f64) callconv(.c) f64 {
    return @rem(a, b);
}

fn internString(state: *State, text: []const u8) i64 {
    const runtime = stateRuntime(state);
    const handle: i64 = @intCast(runtime.strings.items.len);
    runtime.strings.append(runtime.arena, text) catch {
        state.trap = State.oom_trap;
        return 0;
    };
    return handle;
}

fn trapWord(code: ir.TrapCode) i64 {
    return @as(i64, @intFromEnum(code)) + 1;
}

const Service = struct { name: [:0]const u8, address: *anyopaque };

const services = [_]Service{
    .{ .name = "svc_str_int", .address = @ptrCast(@constCast(&svcStrInt)) },
    .{ .name = "svc_str_float", .address = @ptrCast(@constCast(&svcStrFloat)) },
    .{ .name = "svc_str_bool", .address = @ptrCast(@constCast(&svcStrBool)) },
    .{ .name = "svc_print", .address = @ptrCast(@constCast(&svcPrint)) },
    .{ .name = "svc_trap_message", .address = @ptrCast(@constCast(&svcTrapMessage)) },
    .{ .name = "svc_frem", .address = @ptrCast(@constCast(&svcFrem)) },
};

// ---------------------------------------------------------------------------
// Supportability
// ---------------------------------------------------------------------------

/// Whether this whole program fits the milestone-1 native core.  The
/// decision is per program: one unsupported instruction anywhere and
/// the interpreter runs all of it.
pub fn supported(program: *const ir.Program) bool {
    if (!available) return false;
    if (program.inputs.len != 0 or program.outputs.len != 0 or program.reads.len != 0) return false;
    for (program.functions) |*function| {
        if (!scalarType(function.return_type)) return false;
        for (function.locals) |local| {
            if (!scalarType(local.local_type)) return false;
        }
        for (function.result_types) |result_type| {
            if (!scalarType(result_type)) return false;
        }
        for (function.instructions) |instruction| {
            if (!supportedInstruction(instruction)) return false;
        }
    }
    return true;
}

fn scalarType(of: types.Type) bool {
    return switch (of) {
        .none, .boolean, .int, .float, .string => true,
        else => false,
    };
}

fn supportedInstruction(instruction: ir.Instruction) bool {
    return switch (instruction) {
        .const_boolean, .const_int => true,
        // The scanner has no spelling for non-finite doubles; the
        // interpreter runs the rare folded nan/inf constant.
        .const_float => |value| std.math.isFinite(value),
        .const_data => |data| data.data_type == .string,
        .local_get, .local_set => true,
        .binary => |operation| switch (operation.operand_type) {
            .int, .float => true,
            .boolean => operation.op.isComparison(),
            else => false, // String + and comparison wait for M2.
        },
        .unary, .convert => true,
        .call => true,
        .intrinsic => |call| switch (call.kind) {
            .str_value, .print, .assert_true, .trap_message => true,
            else => false,
        },
        .jump, .branch, .ret, .trap => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Lowering: Luce IR -> MIR text
// ---------------------------------------------------------------------------

const Text = struct {
    arena: Allocator,
    out: std.ArrayList(u8) = .empty,

    fn print(self: *Text, comptime format: []const u8, arguments: anytype) error{OutOfMemory}!void {
        const line = try std.fmt.allocPrint(self.arena, format, arguments);
        try self.out.appendSlice(self.arena, line);
    }
};

fn regType(of: types.Type) []const u8 {
    return if (of == .float) "d" else "i64";
}

fn movFor(of: types.Type) []const u8 {
    return if (of == .float) "dmov" else "mov";
}

/// One trap exit collected during a function's lowering; stubs are
/// emitted after the body so the hot path stays branch-not-taken.
const TrapSite = struct { label: u32, code: ir.TrapCode, instruction: u32 };

const FunctionLowering = struct {
    text: *Text,
    program: *const ir.Program,
    function: *const ir.Function,
    index: u32,
    sites: std.ArrayList(TrapSite) = .empty,
    next_label: u32 = 0,

    fn site(self: *FunctionLowering, code: ir.TrapCode, instruction: u32) error{OutOfMemory}!u32 {
        const label = self.next_label;
        self.next_label += 1;
        try self.sites.append(self.text.arena, .{ .label = label, .code = code, .instruction = instruction });
        return label;
    }

    fn freshLabel(self: *FunctionLowering) u32 {
        const label = self.next_label;
        self.next_label += 1;
        return label;
    }
};

fn lowerProgram(arena: Allocator, program: *const ir.Program) error{OutOfMemory}![:0]const u8 {
    var text: Text = .{ .arena = arena };
    try text.print("luce: module\n", .{});

    for (program.functions, 0..) |_, index| {
        try text.print("forward L{d}\n", .{index});
    }
    try text.print(
        \\p_svc_str_int: proto i64, i64:s, i64:v
        \\p_svc_str_float: proto i64, i64:s, d:v
        \\p_svc_str_bool: proto i64, i64:s, i64:v
        \\p_svc_print: proto i64:s, i64:h
        \\p_svc_trap_message: proto i64:s, i64:h
        \\p_svc_frem: proto d, d:a, d:b
        \\import svc_str_int, svc_str_float, svc_str_bool, svc_print, svc_trap_message, svc_frem
        \\
    , .{});
    for (program.functions, 0..) |*function, index| {
        try text.print("p_L{d}: proto ", .{index});
        if (function.return_type != .none) try text.print("{s}, ", .{regType(function.return_type)});
        try text.print("i64:s", .{});
        for (function.locals[0..function.parameter_count], 0..) |local, parameter| {
            try text.print(", {s}:a{d}", .{ regType(local.local_type), parameter });
        }
        try text.print("\n", .{});
    }
    for (program.functions, 0..) |_, index| {
        try text.print("export L{d}\n", .{index});
    }
    for (program.functions, 0..) |*function, index| {
        try lowerFunction(&text, program, function, @intCast(index));
    }
    try text.print("endmodule\n", .{});
    try text.out.append(arena, 0);
    const slice = text.out.items;
    return slice[0 .. slice.len - 1 :0];
}

fn lowerFunction(
    text: *Text,
    program: *const ir.Program,
    function: *const ir.Function,
    index: u32,
) error{OutOfMemory}!void {
    var lowering: FunctionLowering = .{
        .text = text,
        .program = program,
        .function = function,
        .index = index,
    };
    defer lowering.sites.deinit(text.arena);

    // Signature: results, then the state pointer, then parameters.
    try text.print("L{d}: func ", .{index});
    if (function.return_type != .none) try text.print("{s}, ", .{regType(function.return_type)});
    try text.print("i64:s", .{});
    for (function.locals[0..function.parameter_count], 0..) |local, parameter| {
        try text.print(", {s}:l{d}", .{ regType(local.local_type), parameter });
    }
    try text.print("\n", .{});

    // Declarations: non-parameter locals, value registers, scratch.
    try text.print("    local i64:t, i64:tc, i64:to, d:dt\n", .{});
    for (function.locals[function.parameter_count..], function.parameter_count..) |local, number| {
        try text.print("    local {s}:l{d}\n", .{ regType(local.local_type), number });
    }
    for (function.result_types, 0..) |result_type, register| {
        if (result_type == .none) continue;
        try text.print("    local {s}:r{d}\n", .{ regType(result_type), register });
    }

    // Prologue: the call-depth budget, then typed zero for every
    // non-parameter local (the interpreter's defensive rule).
    try text.print(
        \\    mov t, i64:24(s)
        \\    sub t, t, 1
        \\    mov i64:24(s), t
        \\    blt DEPTH{d}, t, 0
        \\
    , .{index});
    for (function.locals[function.parameter_count..], function.parameter_count..) |local, number| {
        try text.print("    {s} l{d}, {s}\n", .{
            movFor(local.local_type),
            number,
            if (local.local_type == .float) "0.0" else "0",
        });
    }

    for (function.blocks, 0..) |block, block_index| {
        try text.print("B{d}_{d}:\n", .{ index, block_index });
        for (block.items) |item| {
            try lowerInstruction(&lowering, item);
        }
    }

    // Trap stubs, then the shared tails.
    for (lowering.sites.items) |stub| {
        try text.print("S{d}_{d}: mov to, {d}\n    mov tc, {d}\n    jmp TRAP{d}\n", .{
            index, stub.label, stub.instruction, trapWord(stub.code), index,
        });
    }
    try text.print(
        \\TRAP{d}: mov i64:0(s), tc
        \\    mov tc, {d}
        \\    mov i64:8(s), tc
        \\    mov i64:16(s), to
        \\PROP{d}:
        \\
    , .{ index, index, index });
    try emitDefaultReturn(text, function.return_type);
    try text.print("DEPTH{d}: mov to, 0\n    mov tc, {d}\n    jmp TRAP{d}\n", .{
        index, trapWord(.call_depth_exceeded), index,
    });
    try text.print("endfunc\n", .{});
}

fn emitDefaultReturn(text: *Text, return_type: types.Type) error{OutOfMemory}!void {
    switch (return_type) {
        .none => try text.print("    ret\n", .{}),
        .float => try text.print("    dmov dt, 0.0\n    ret dt\n", .{}),
        else => try text.print("    mov t, 0\n    ret t\n", .{}),
    }
}

/// The post-call trap check: callee (or service) may have stopped us.
fn emitTrapCheck(lowering: *FunctionLowering) error{OutOfMemory}!void {
    try lowering.text.print("    mov t, i64:0(s)\n    bne PROP{d}, t, 0\n", .{lowering.index});
}

/// Stores the trap origin, for service calls that can trap with a
/// location (print, trap): two words the service leaves untouched.
fn emitOrigin(lowering: *FunctionLowering, instruction: u32) error{OutOfMemory}!void {
    try lowering.text.print(
        "    mov t, {d}\n    mov i64:8(s), t\n    mov t, {d}\n    mov i64:16(s), t\n",
        .{ lowering.index, instruction },
    );
}

fn lowerInstruction(lowering: *FunctionLowering, item: ir.Register) error{OutOfMemory}!void {
    const text = lowering.text;
    const function = lowering.function;
    const instruction = function.instructions[item];
    switch (instruction) {
        .const_boolean => |value| try text.print("    mov r{d}, {d}\n", .{ item, @intFromBool(value) }),
        .const_int => |value| try text.print("    mov r{d}, {d}\n", .{ item, value }),
        .const_float => |value| try emitFloatMove(text, item, value),
        .const_data => |data| try text.print("    mov r{d}, {d}\n", .{ item, data.constant }),
        .local_get => |local| {
            const kind = function.locals[local].local_type;
            try text.print("    {s} r{d}, l{d}\n", .{ movFor(kind), item, local });
        },
        .local_set => |set| {
            const kind = function.locals[set.local].local_type;
            try text.print("    {s} l{d}, r{d}\n", .{ movFor(kind), set.local, set.value });
        },
        .binary => |operation| try lowerBinary(lowering, item, operation),
        .unary => |operation| switch (operation.op) {
            .logic_not => try text.print("    eq r{d}, r{d}, 0\n", .{ item, operation.operand }),
            .negate => {
                if (function.result_types[item] == .float) {
                    try text.print("    dneg r{d}, r{d}\n", .{ item, operation.operand });
                } else {
                    const overflow = try lowering.site(.integer_overflow, item);
                    try text.print("    mov t, 0\n    subo r{d}, t, r{d}\n    bo S{d}_{d}\n", .{
                        item, operation.operand, lowering.index, overflow,
                    });
                }
            },
        },
        .convert => |operation| switch (operation.kind) {
            .int_to_float => try text.print("    i2d r{d}, r{d}\n", .{ item, operation.operand }),
            .float_to_int => {
                const range = try lowering.site(.conversion_range, item);
                // NaN, below -2^63, or at/above 2^63 traps; in-range
                // truncates toward zero exactly like the interpreter.
                try text.print(
                    \\    dne t, r{1d}, r{1d}
                    \\    bt S{2d}_{3d}, t
                    \\    dmov dt, -9223372036854775808.0
                    \\    dlt t, r{1d}, dt
                    \\    bt S{2d}_{3d}, t
                    \\    dmov dt, 9223372036854775808.0
                    \\    dge t, r{1d}, dt
                    \\    bt S{2d}_{3d}, t
                    \\    d2i r{0d}, r{1d}
                    \\
                , .{ item, operation.operand, lowering.index, range });
            },
        },
        .call => |call| {
            const callee = &lowering.program.functions[call.function];
            try text.print("    call p_L{d}, L{d}", .{ call.function, call.function });
            if (callee.return_type != .none) try text.print(", r{d}", .{item});
            try text.print(", s", .{});
            for (call.arguments) |argument| try text.print(", r{d}", .{argument});
            try text.print("\n", .{});
            try emitTrapCheck(lowering);
        },
        .intrinsic => |call| try lowerIntrinsic(lowering, item, call),
        .jump => |target| try text.print("    jmp B{d}_{d}\n", .{ lowering.index, target }),
        .branch => |branching| try text.print("    bt B{d}_{d}, r{d}\n    jmp B{d}_{d}\n", .{
            lowering.index, branching.then_block, branching.condition,
            lowering.index, branching.else_block,
        }),
        .ret => |value| {
            // Restore the depth budget on the successful path only;
            // a trap abandons the whole evaluation anyway.
            try text.print("    mov t, i64:24(s)\n    add t, t, 1\n    mov i64:24(s), t\n", .{});
            if (value) |register| {
                try text.print("    ret r{d}\n", .{register});
            } else {
                try text.print("    ret\n", .{});
            }
        },
        .trap => |code| {
            const stub = try lowering.site(code, item);
            try text.print("    jmp S{d}_{d}\n", .{ lowering.index, stub });
        },
        else => unreachable, // supported() refused everything else.
    }
}

fn emitFloatMove(text: *Text, item: ir.Register, value: f64) error{OutOfMemory}!void {
    // Full decimal notation ({d} on 1.0e300 is ~300 digits), with a
    // ".0" appended when the value prints integral — MIR's scanner
    // types the literal by the dot.
    const digits = try std.fmt.allocPrint(text.arena, "{d}", .{value});
    const fractional = std.mem.indexOfAny(u8, digits, ".e") != null;
    try text.print("    dmov r{d}, {s}{s}\n", .{ item, digits, if (fractional) "" else ".0" });
}

fn lowerBinary(
    lowering: *FunctionLowering,
    item: ir.Register,
    operation: ir.Instruction.Binary,
) error{OutOfMemory}!void {
    const text = lowering.text;
    const of = operation.operand_type;
    if (operation.op.isComparison()) {
        const name = switch (operation.op) {
            .equal => "eq",
            .not_equal => "ne",
            .less => "lt",
            .less_equal => "le",
            .greater => "gt",
            .greater_equal => "ge",
            else => unreachable,
        };
        const prefix: []const u8 = if (of == .float) "d" else "";
        try text.print("    {s}{s} r{d}, r{d}, r{d}\n", .{
            prefix, name, item, operation.left, operation.right,
        });
        return;
    }
    if (of == .float) {
        switch (operation.op) {
            .add, .subtract, .multiply, .divide => {
                const name = switch (operation.op) {
                    .add => "dadd",
                    .subtract => "dsub",
                    .multiply => "dmul",
                    .divide => "ddiv",
                    else => unreachable,
                };
                try text.print("    {s} r{d}, r{d}, r{d}\n", .{ name, item, operation.left, operation.right });
            },
            .remainder => try text.print("    call p_svc_frem, svc_frem, r{d}, r{d}, r{d}\n", .{
                item, operation.left, operation.right,
            }),
            else => unreachable,
        }
        return;
    }
    switch (operation.op) {
        .add, .subtract, .multiply => {
            const name = switch (operation.op) {
                .add => "addo",
                .subtract => "subo",
                .multiply => "mulo",
                else => unreachable,
            };
            const overflow = try lowering.site(.integer_overflow, item);
            try text.print("    {s} r{d}, r{d}, r{d}\n    bo S{d}_{d}\n", .{
                name, item, operation.left, operation.right, lowering.index, overflow,
            });
        },
        .divide, .remainder => {
            const zero = try lowering.site(.divide_by_zero, item);
            const overflow = try lowering.site(.integer_overflow, item);
            const fine = lowering.freshLabel();
            // b == 0 traps; MIN / -1 traps; anything else divides.
            try text.print(
                \\    beq S{0d}_{1d}, r{3d}, 0
                \\    bne K{0d}_{4d}, r{3d}, -1
                \\    bne K{0d}_{4d}, r{2d}, -9223372036854775808
                \\    jmp S{0d}_{5d}
                \\K{0d}_{4d}:
                \\
            , .{ lowering.index, zero, operation.left, operation.right, fine, overflow });
            const name: []const u8 = if (operation.op == .divide) "div" else "mod";
            try text.print("    {s} r{d}, r{d}, r{d}\n", .{ name, item, operation.left, operation.right });
        },
        else => unreachable,
    }
}

fn lowerIntrinsic(
    lowering: *FunctionLowering,
    item: ir.Register,
    call: ir.Instruction.IntrinsicCall,
) error{OutOfMemory}!void {
    const text = lowering.text;
    switch (call.kind) {
        .str_value => {
            const operand = call.arguments[0];
            switch (lowering.function.result_types[operand]) {
                .string => try text.print("    mov r{d}, r{d}\n", .{ item, operand }),
                .int => {
                    try text.print("    call p_svc_str_int, svc_str_int, r{d}, s, r{d}\n", .{ item, operand });
                    try emitTrapCheck(lowering);
                },
                .float => {
                    try text.print("    call p_svc_str_float, svc_str_float, r{d}, s, r{d}\n", .{ item, operand });
                    try emitTrapCheck(lowering);
                },
                .boolean => {
                    try text.print("    call p_svc_str_bool, svc_str_bool, r{d}, s, r{d}\n", .{ item, operand });
                    try emitTrapCheck(lowering);
                },
                else => unreachable,
            }
        },
        .print => {
            try emitOrigin(lowering, item);
            try text.print("    call p_svc_print, svc_print, s, r{d}\n", .{call.arguments[0]});
            try emitTrapCheck(lowering);
        },
        .assert_true => {
            const failed = try lowering.site(.assertion_failed, item);
            try text.print("    bf S{d}_{d}, r{d}\n", .{ lowering.index, failed, call.arguments[0] });
        },
        .trap_message => {
            try emitOrigin(lowering, item);
            try text.print("    call p_svc_trap_message, svc_trap_message, s, r{d}\n    jmp PROP{d}\n", .{
                call.arguments[0], lowering.index,
            });
        },
        else => unreachable,
    }
}

// ---------------------------------------------------------------------------
// Compiling and running
// ---------------------------------------------------------------------------

/// Everything the protected callback needs; MIR errors longjmp out,
/// so the callback keeps no resources of its own.
const CompileJob = struct {
    ctx: c.Context,
    text: [*:0]const u8,
    function_count: usize,
    name_buffer: [32]u8 = undefined,
    entry: u32,
    entry_address: ?*anyopaque = null,
};

fn compileBody(payload: ?*anyopaque) callconv(.c) void {
    const job: *CompileJob = @ptrCast(@alignCast(payload.?));
    c.MIR_scan_string(job.ctx, job.text);
    for (services) |service| {
        c.MIR_load_external(job.ctx, service.name.ptr, service.address);
    }
    c.luce_mir_load_all(job.ctx);
    c.MIR_link(job.ctx, &c.MIR_set_gen_interface, null);
    for (0..job.function_count) |index| {
        const name = std.fmt.bufPrintZ(&job.name_buffer, "L{d}", .{index}) catch unreachable;
        const item = c.luce_mir_find_func(job.ctx, name.ptr);
        const address = c.MIR_gen(job.ctx, item);
        if (index == job.entry) job.entry_address = address;
    }
}

pub const RunError = error{ OutOfMemory, NativeFailed };

/// Compile the whole program to machine code and run its entry.  The
/// signature mirrors the interpreter's `run`; `budget.steps` is not
/// enforced here (native code is for programs meant to finish), the
/// call-depth budget is.
pub fn run(
    arena: Allocator,
    program: *const ir.Program,
    inputs: []const InputValue,
    outputs: []?RuntimeValue,
    budget: Budget,
    host: ?backend.Host,
) RunError!Result {
    _ = inputs;
    _ = outputs;
    if (!available) return error.NativeFailed;

    const text = try lowerProgram(arena, program);

    const ctx = c.luce_mir_init() orelse return error.NativeFailed;
    // After a longjmp'd MIR error the context's state is unknown, so
    // the error path abandons it (a small, one-time leak on what is
    // by definition a lowering bug) rather than risk finish crashing.
    var healthy = true;
    defer if (healthy) {
        c.MIR_gen_finish(ctx);
        c.MIR_finish(ctx);
    };

    c.MIR_gen_init(ctx);
    var job: CompileJob = .{
        .ctx = ctx,
        .text = text.ptr,
        .function_count = program.functions.len,
        .entry = program.entry_function,
    };
    if (c.luce_mir_protected(ctx, &compileBody, &job) != 0) {
        healthy = false;
        return error.NativeFailed;
    }
    const entry = job.entry_address orelse return error.NativeFailed;

    var runtime: Runtime = .{ .arena = arena, .host = host };
    try runtime.strings.ensureTotalCapacity(arena, program.constants.len + 8);
    for (program.constants) |constant| {
        runtime.strings.appendAssumeCapacity(constant);
    }
    var state: State = .{
        .depth_left = @intCast(budget.call_depth),
        .runtime = &runtime,
    };

    const main: *const fn (*State) callconv(.c) void = @ptrCast(@alignCast(entry));
    main(&state);

    if (state.trap == 0) return .{ .success = .{ .leaked_objects = 0 } };
    if (state.trap == State.oom_trap) return error.OutOfMemory;

    const code: ir.TrapCode = @enumFromInt(@as(u32, @intCast(state.trap - 1)));
    const message = runtime.trap_message orelse code.message();
    return .{ .trap = .{
        .code = code,
        .message = message,
        .trace = try nativeTrace(arena, program, state),
    } };
}

/// One frame: where the trap fired.  The native stack is gone by the
/// time we are back here, so milestone 1 reports the innermost frame
/// only; the interpreter remains the engine with full call traces.
fn nativeTrace(
    arena: Allocator,
    program: *const ir.Program,
    state: State,
) error{OutOfMemory}![]backend.TraceFrame {
    const function_index: usize = @intCast(state.trap_function);
    if (function_index >= program.functions.len) return &.{};
    const function = &program.functions[function_index];
    const instruction: usize = @intCast(state.trap_instruction);
    const frame = try arena.alloc(backend.TraceFrame, 1);
    frame[0] = .{
        .function = function.name,
        .source = function.source,
        .line = if (instruction < function.origins.len) function.origins[instruction].line else 0,
        .column = if (instruction < function.origins.len) function.origins[instruction].column else 0,
    };
    return frame;
}
