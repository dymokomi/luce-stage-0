//! The native engine: verified Luce IR compiled to machine code at
//! load, through the vendored MIR JIT (vendor/mir).
//!
//! This is the second engine behind the backend boundary; the
//! interpreter stays the reference implementation and the spec
//! (native_spec.zig runs both and diffs).  Semantics are identical
//! by construction, twice over: the arithmetic core lowers with its
//! checks — overflow, division, conversion range — and everything
//! heap-shaped (collections, ownership, strings, structs, host
//! builtins) crosses a small C-ABI service layer into the
//! *interpreter's own machine*: `Runtime` embeds an
//! `interpreter.Machine`, and the generic services marshal operands
//! into RuntimeValues and call the same `intrinsic`/`binary`/
//! ownership code the reference engine runs.  Collection and
//! ownership semantics exist in exactly one place.
//!
//! Value representation in native code: Int/Bool are i64, Float is
//! f64, String is an i64 handle into the run's string table
//! (constants first, then "" as the zero value, then whatever str()
//! and friends make), a heap object is its i64 handle index, and a
//! struct value is the address of its RuntimeValue fields (structs
//! are immutable-by-rebuild, so sharing is safe — the same reason
//! the interpreter shares them).
//!
//! The generic marshaling protocol: a call site stores its operand
//! values into the State's scratch slots in canonical order, then
//! calls `svc_instr_{i,d,v}` with (function, instruction, serial);
//! the service looks the instruction up in the program, rebuilds
//! typed RuntimeValues from the slots, runs the reference
//! implementation, and hands the result back in the native
//! representation.  Hot arithmetic never touches any of this.
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
const interpreter = @import("interpreter.zig");

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
/// only the leading words at fixed offsets — the trap triple at
/// 0/8/16, the depth budget at 24, and the marshaling slots from 32 —
/// everything after is the Zig side's.
const State = extern struct {
    /// 0 = running; oom_trap = allocation failed; otherwise
    /// @intFromEnum(TrapCode) + 1.
    trap: i64 = 0,
    trap_function: i64 = 0,
    trap_instruction: i64 = 0,
    depth_left: i64,
    /// Generic-call scratch: operand values in canonical order, i64
    /// words with floats as raw bits.  Offset of slot k is 32 + 8k.
    slots: [slot_count]u64 = [_]u64{0} ** slot_count,
    runtime: *Runtime,

    const oom_trap: i64 = -1;
    const slots_offset = 32;
    pub const slot_count = 32;
};

const Runtime = struct {
    /// The interpreter's own machine: the heap, the owner model, and
    /// every intrinsic implementation.  The native engine borrows the
    /// reference implementation wholesale, so collection and
    /// ownership semantics exist in exactly one place.  Its frame
    /// stack stays empty — native code owns control flow.
    machine: interpreter.Machine,
    /// String handles: the program's constant pool first, then ""
    /// (the string zero value), then whatever runs make.
    strings: std.ArrayList([]const u8) = .empty,
};

fn trapWord(code: ir.TrapCode) i64 {
    return @as(i64, @intFromEnum(code)) + 1;
}

fn internString(state: *State, text: []const u8) i64 {
    const runtime = state.runtime;
    const handle: i64 = @intCast(runtime.strings.items.len);
    runtime.strings.append(runtime.machine.arena, text) catch {
        state.trap = State.oom_trap;
        return 0;
    };
    return handle;
}

/// A typed RuntimeValue from marshaling slot `slot`.
fn fromSlot(state: *State, slot: usize, of: types.Type) RuntimeValue {
    const raw = state.slots[slot];
    return switch (of) {
        .none => .none,
        .boolean => .{ .boolean = raw != 0 },
        .int => .{ .int = @bitCast(raw) },
        .float => .{ .float = @bitCast(raw) },
        .string => .{ .string = state.runtime.strings.items[@intCast(@as(i64, @bitCast(raw)))] },
        .heap => .{ .object = .{ .index = @intCast(raw & 0xffff_ffff) } },
        .strukt => |layout| blk: {
            const fields: [*]RuntimeValue = @ptrFromInt(raw);
            const count = state.runtime.machine.program.structs[layout].fields.len;
            break :blk .{ .strukt = fields[0..count] };
        },
        .bytes => unreachable, // supported() refused the program
    };
}

/// The native i64 for a non-float RuntimeValue (floats travel on the
/// d-returning service path).
fn toNative(state: *State, value: RuntimeValue) i64 {
    return switch (value) {
        .none => 0,
        .boolean => |flag| @intFromBool(flag),
        .int => |number| number,
        .string => |text| internString(state, text),
        .object => |handle| @intCast(handle.index),
        .strukt => |fields| @bitCast(@intFromPtr(fields.ptr)),
        .float, .bytes => unreachable,
    };
}

const identity_registers = blk: {
    var list: [State.slot_count]ir.Register = undefined;
    for (&list, 0..) |*slot, index| slot.* = @intCast(index);
    break :blk list;
};

/// The generic path: rebuild the instruction's operands from the
/// slots and run the reference implementation.  Null means a trap or
/// OOM was recorded in the state.
fn genericResult(state: *State, function: i64, instruction: i64, serial: i64) ?RuntimeValue {
    const machine = &state.runtime.machine;
    const target = &machine.program.functions[@intCast(function)];
    const instr = target.instructions[@intCast(instruction)];
    var staged: [State.slot_count]RuntimeValue = undefined;
    const outcome: interpreter.Machine.EvalError!RuntimeValue = switch (instr) {
        .intrinsic => |call| blk: {
            for (call.arguments, 0..) |argument, index| {
                staged[index] = fromSlot(state, index, target.result_types[argument]);
            }
            const remapped: ir.Instruction.IntrinsicCall = .{
                .kind = call.kind,
                .arguments = @constCast(identity_registers[0..call.arguments.len]),
            };
            break :blk machine.intrinsic(remapped, &staged, @intCast(serial));
        },
        .binary => |operation| blk: {
            staged[0] = fromSlot(state, 0, operation.operand_type);
            staged[1] = fromSlot(state, 1, operation.operand_type);
            const remapped: ir.Instruction.Binary = .{
                .op = operation.op,
                .operand_type = operation.operand_type,
                .left = 0,
                .right = 1,
            };
            break :blk machine.binary(remapped, &staged);
        },
        .heap_new => |new| blk: {
            for (0..new.dims.len) |index| staged[index] = fromSlot(state, index, .int);
            const remapped: ir.Instruction.HeapNew = .{
                .heap = new.heap,
                .dims = @constCast(identity_registers[0..new.dims.len]),
            };
            break :blk machine.allocateObject(remapped, &staged);
        },
        .struct_make => |make| blk: {
            const fields = machine.arena.alloc(RuntimeValue, make.fields.len) catch
                break :blk error.OutOfMemory;
            for (make.fields, fields, 0..) |field_register, *slot, index| {
                slot.* = fromSlot(state, index, target.result_types[field_register]);
            }
            break :blk .{ .strukt = fields };
        },
        .struct_get => |get| blk: {
            const strukt = fromSlot(state, 0, target.result_types[get.target]);
            break :blk strukt.strukt[get.field];
        },
        .struct_set => |set| blk: {
            const source = fromSlot(state, 0, target.result_types[set.target]).strukt;
            const fields = machine.arena.alloc(RuntimeValue, source.len) catch
                break :blk error.OutOfMemory;
            @memcpy(fields, source);
            fields[set.field] = fromSlot(state, 1, target.result_types[set.value]);
            break :blk .{ .strukt = fields };
        },
        .object_bind => |bind| blk: {
            machine.bindValue(
                fromSlot(state, 0, target.result_types[bind.value]),
                @intCast(serial),
                bind.local,
            );
            break :blk .none;
        },
        .object_unbind => |unbind| blk: {
            machine.unbindValue(
                fromSlot(state, 0, target.result_types[unbind.value]),
                @intCast(serial),
                unbind.local,
            );
            break :blk .none;
        },
        else => unreachable, // never routed here
    };
    return outcome catch |mistake| {
        switch (mistake) {
            error.OutOfMemory => state.trap = State.oom_trap,
            error.Trap => state.trap = trapWord(machine.pending_trap.?.code),
        }
        state.trap_function = function;
        state.trap_instruction = instruction;
        return null;
    };
}

fn svcInstrI(state: *State, function: i64, instruction: i64, serial: i64) callconv(.c) i64 {
    const value = genericResult(state, function, instruction, serial) orelse return 0;
    return toNative(state, value);
}

fn svcInstrD(state: *State, function: i64, instruction: i64, serial: i64) callconv(.c) f64 {
    const value = genericResult(state, function, instruction, serial) orelse return 0;
    return value.float;
}

fn svcInstrV(state: *State, function: i64, instruction: i64, serial: i64) callconv(.c) void {
    _ = genericResult(state, function, instruction, serial);
}

/// A fresh frame serial, so native bindings never collide with each
/// other (or with anything the machine made).
fn svcSerial(state: *State) callconv(.c) i64 {
    const machine = &state.runtime.machine;
    const serial = machine.next_serial;
    machine.next_serial += 1;
    return serial;
}

/// The typed zero of a struct local (S40 late declarations).
fn svcZeroStrukt(state: *State, layout: i64) callconv(.c) i64 {
    const machine = &state.runtime.machine;
    const zero = machine.zeroValue(.{ .strukt = @intCast(layout) }) catch {
        state.trap = State.oom_trap;
        return 0;
    };
    return toNative(state, zero);
}

/// Return-value ownership (S16): whatever the finishing frame still
/// owned in the returned value (slot 0, typed by the function's
/// return type) goes loose for the caller to bind.
fn svcLoosen(state: *State, function: i64, serial: i64) callconv(.c) void {
    const machine = &state.runtime.machine;
    const target = &machine.program.functions[@intCast(function)];
    machine.loosenFromFrame(fromSlot(state, 0, target.return_type), @intCast(serial));
}

// -- fast services ----------------------------------------------------------
//
// The generic path pays an instruction lookup and RuntimeValue
// staging per call — fine when the operation does real work (sort,
// split, print), twice the interpreter's cost when it doesn't.  The
// hottest cheap primitives get direct services instead: sequence
// indexing over scalar elements, byte_at, len.  Each mirrors the
// interpreter's checks exactly, and the oracle proves it.

fn recordFastTrap(state: *State, code: ir.TrapCode, function: i64, instruction: i64) void {
    state.trap = trapWord(code);
    state.trap_function = function;
    state.trap_instruction = instruction;
}

/// Machine.resolve's exact rules: null handles trap null_object,
/// out-of-table or freed ones use_after_free.
fn fastResolve(state: *State, function: i64, instruction: i64, raw: i64) ?*interpreter.Machine.HeapObject {
    const machine = &state.runtime.machine;
    const index = @as(u64, @bitCast(raw)) & 0xffff_ffff;
    if (index == 0xffff_ffff) {
        recordFastTrap(state, .null_object, function, instruction);
        return null;
    }
    if (index >= machine.heap.items.len) {
        recordFastTrap(state, .use_after_free, function, instruction);
        return null;
    }
    const object = &machine.heap.items[index];
    if (!object.alive) {
        recordFastTrap(state, .use_after_free, function, instruction);
        return null;
    }
    return object;
}

/// The element slot of a list or rank-1 array (the only shapes the
/// lowering routes here), bounds-checked like the interpreter.
fn fastElement(state: *State, function: i64, instruction: i64, handle: i64, index: i64) ?*RuntimeValue {
    const object = fastResolve(state, function, instruction, handle) orelse return null;
    const elements: []RuntimeValue = switch (object.data) {
        .list => |list| list.items,
        .array => |array| array.elements,
        else => unreachable,
    };
    if (index < 0 or index >= elements.len) {
        recordFastTrap(state, .index_bounds, function, instruction);
        return null;
    }
    return &elements[@intCast(index)];
}

fn svcSeqGetI(state: *State, function: i64, instruction: i64, handle: i64, index: i64) callconv(.c) i64 {
    const element = fastElement(state, function, instruction, handle, index) orelse return 0;
    return switch (element.*) {
        .int => |value| value,
        .boolean => |value| @intFromBool(value),
        else => unreachable,
    };
}

fn svcSeqGetD(state: *State, function: i64, instruction: i64, handle: i64, index: i64) callconv(.c) f64 {
    const element = fastElement(state, function, instruction, handle, index) orelse return 0;
    return element.float;
}

fn svcSeqSetI(state: *State, function: i64, instruction: i64, handle: i64, index: i64, value: i64) callconv(.c) void {
    const element = fastElement(state, function, instruction, handle, index) orelse return;
    // Scalar elements only ever reach here; the stored tag is the
    // element type, so overwrite in kind (no ownership to move).
    element.* = switch (element.*) {
        .int => .{ .int = value },
        .boolean => .{ .boolean = value != 0 },
        else => unreachable,
    };
}

fn svcSeqSetD(state: *State, function: i64, instruction: i64, handle: i64, index: i64, value: f64) callconv(.c) void {
    const element = fastElement(state, function, instruction, handle, index) orelse return;
    element.* = .{ .float = value };
}

fn svcStrByte(state: *State, function: i64, instruction: i64, handle: i64, index: i64) callconv(.c) i64 {
    const text = state.runtime.strings.items[@intCast(handle)];
    if (index < 0 or index >= text.len) {
        recordFastTrap(state, .string_bounds, function, instruction);
        return 0;
    }
    return text[@intCast(index)];
}

fn svcStrLen(state: *State, handle: i64) callconv(.c) i64 {
    return @intCast(state.runtime.strings.items[@intCast(handle)].len);
}

fn svcObjLen(state: *State, function: i64, instruction: i64, handle: i64) callconv(.c) i64 {
    const object = fastResolve(state, function, instruction, handle) orelse return 0;
    const measured: usize = switch (object.data) {
        .list => |list| list.items.len,
        .map => |map| map.items.len,
        .array => |array| if (array.dims.len == 0) 0 else @intCast(array.dims[0]),
        .builder => |builder| builder.items.len,
    };
    return @intCast(measured);
}

fn svcStrSlice(state: *State, function: i64, instruction: i64, handle: i64, from: i64, to: i64) callconv(.c) i64 {
    const text = state.runtime.strings.items[@intCast(handle)];
    if (from < 0 or to < from or to > text.len) {
        recordFastTrap(state, .string_bounds, function, instruction);
        return 0;
    }
    const start: usize = @intCast(from);
    const end: usize = @intCast(to);
    if (!interpreter.isStringBoundary(text, start) or !interpreter.isStringBoundary(text, end)) {
        recordFastTrap(state, .string_boundary, function, instruction);
        return 0;
    }
    return internString(state, text[start..end]);
}

fn svcBuilderAppend(state: *State, function: i64, instruction: i64, handle: i64, text_handle: i64) callconv(.c) void {
    const object = fastResolve(state, function, instruction, handle) orelse return;
    const text = state.runtime.strings.items[@intCast(text_handle)];
    object.data.builder.appendSlice(state.runtime.machine.arena, text) catch {
        state.trap = State.oom_trap;
    };
}

const Service = struct { name: [:0]const u8, address: *anyopaque };

const services = [_]Service{
    .{ .name = "svc_instr_i", .address = @ptrCast(@constCast(&svcInstrI)) },
    .{ .name = "svc_instr_d", .address = @ptrCast(@constCast(&svcInstrD)) },
    .{ .name = "svc_instr_v", .address = @ptrCast(@constCast(&svcInstrV)) },
    .{ .name = "svc_serial", .address = @ptrCast(@constCast(&svcSerial)) },
    .{ .name = "svc_zero_strukt", .address = @ptrCast(@constCast(&svcZeroStrukt)) },
    .{ .name = "svc_loosen", .address = @ptrCast(@constCast(&svcLoosen)) },
    .{ .name = "svc_seq_get_i", .address = @ptrCast(@constCast(&svcSeqGetI)) },
    .{ .name = "svc_seq_get_d", .address = @ptrCast(@constCast(&svcSeqGetD)) },
    .{ .name = "svc_seq_set_i", .address = @ptrCast(@constCast(&svcSeqSetI)) },
    .{ .name = "svc_seq_set_d", .address = @ptrCast(@constCast(&svcSeqSetD)) },
    .{ .name = "svc_str_byte", .address = @ptrCast(@constCast(&svcStrByte)) },
    .{ .name = "svc_str_len", .address = @ptrCast(@constCast(&svcStrLen)) },
    .{ .name = "svc_obj_len", .address = @ptrCast(@constCast(&svcObjLen)) },
    .{ .name = "svc_str_slice", .address = @ptrCast(@constCast(&svcStrSlice)) },
    .{ .name = "svc_builder_append", .address = @ptrCast(@constCast(&svcBuilderAppend)) },
};

// ---------------------------------------------------------------------------
// Supportability
// ---------------------------------------------------------------------------

/// Whether this whole program fits the native core.  Since milestone
/// 2 that is nearly everything a script can be; what remains outside
/// is the Bytes stub type, ports (evaluator mode), the dormant
/// fabric intrinsics, and non-finite folded float constants.  The
/// decision stays per program: one unsupported instruction anywhere
/// and the interpreter runs all of it.
pub fn supported(program: *const ir.Program) bool {
    if (!available) return false;
    if (program.inputs.len != 0 or program.outputs.len != 0 or program.reads.len != 0) return false;
    for (program.structs) |layout| {
        for (layout.fields) |field| {
            if (field.field_type == .bytes) return false;
        }
    }
    for (program.heap_types) |descriptor| {
        if (heapHasBytes(descriptor)) return false;
    }
    for (program.functions) |*function| {
        if (function.return_type == .bytes) return false;
        for (function.locals) |local| {
            if (local.local_type == .bytes) return false;
        }
        for (function.result_types) |result_type| {
            if (result_type == .bytes) return false;
        }
        for (function.instructions) |instruction| {
            if (!supportedInstruction(instruction)) return false;
        }
    }
    return true;
}

fn heapHasBytes(descriptor: types.HeapType) bool {
    return switch (descriptor) {
        .list => |element| element == .bytes,
        .map => |pair| pair.key == .bytes or pair.value == .bytes,
        .array => |shape| shape.element == .bytes,
        .builder => false,
    };
}

fn supportedInstruction(instruction: ir.Instruction) bool {
    return switch (instruction) {
        // The scanner has no spelling for non-finite doubles; the
        // interpreter runs the rare folded nan/inf constant.
        .const_float => |value| std.math.isFinite(value),
        .const_data => |data| data.data_type == .string,
        .struct_make => |make| make.fields.len <= State.slot_count,
        .intrinsic => |call| switch (call.kind) {
            // Fabric intents are dormant in v2 and gated off anyway.
            .fabric_image,
            .fabric_create,
            .fabric_input,
            .fabric_output,
            .fabric_content,
            .fabric_evaluator,
            .fabric_set,
            => false,
            else => call.arguments.len <= State.slot_count,
        },
        .input_load, .output_store => false,
        else => true,
    };
}

/// Objects reachable through a value of this type (for return-value
/// loosening; mirrors the analyzer's carriesObjects).
fn carriesObjects(program: *const ir.Program, of: types.Type) bool {
    return switch (of) {
        .heap => true,
        .strukt => |layout| blk: {
            for (program.structs[layout].fields) |field| {
                if (carriesObjects(program, field.field_type)) break :blk true;
            }
            break :blk false;
        },
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
        \\p_svc_instr_i: proto i64, i64:s, i64:f, i64:i, i64:sr
        \\p_svc_instr_d: proto d, i64:s, i64:f, i64:i, i64:sr
        \\p_svc_instr_v: proto i64:s, i64:f, i64:i, i64:sr
        \\p_svc_serial: proto i64, i64:s
        \\p_svc_zero_strukt: proto i64, i64:s, i64:l
        \\p_svc_loosen: proto i64:s, i64:f, i64:sr
        \\p_svc_seq_get_i: proto i64, i64:s, i64:f, i64:i, i64:h, i64:x
        \\p_svc_seq_get_d: proto d, i64:s, i64:f, i64:i, i64:h, i64:x
        \\p_svc_seq_set_i: proto i64:s, i64:f, i64:i, i64:h, i64:x, i64:v
        \\p_svc_seq_set_d: proto i64:s, i64:f, i64:i, i64:h, i64:x, d:v
        \\p_svc_str_byte: proto i64, i64:s, i64:f, i64:i, i64:h, i64:x
        \\p_svc_str_len: proto i64, i64:s, i64:h
        \\p_svc_obj_len: proto i64, i64:s, i64:f, i64:i, i64:h
        \\p_svc_str_slice: proto i64, i64:s, i64:f, i64:i, i64:h, i64:a, i64:b
        \\p_svc_builder_append: proto i64:s, i64:f, i64:i, i64:h, i64:x
        \\import svc_instr_i, svc_instr_d, svc_instr_v, svc_serial, svc_zero_strukt, svc_loosen
        \\import svc_seq_get_i, svc_seq_get_d, svc_seq_set_i, svc_seq_set_d, svc_str_byte, svc_str_len, svc_obj_len
        \\import svc_str_slice, svc_builder_append
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

/// Whether any instruction routes through the generic services (and
/// therefore wants a real frame serial for its bindings).
fn needsSerial(program: *const ir.Program, function: *const ir.Function) bool {
    if (carriesObjects(program, function.return_type)) return true;
    for (function.instructions) |instruction| {
        switch (instruction) {
            .object_bind,
            .object_unbind,
            .heap_new,
            .struct_make,
            .struct_get,
            .struct_set,
            => return true,
            .binary => |operation| {
                if (operation.operand_type == .string) return true;
                if (operation.operand_type == .float and operation.op == .remainder) return true;
            },
            .intrinsic => |call| switch (call.kind) {
                .assert_true => {},
                else => return true,
            },
            else => {},
        }
    }
    return false;
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

    // Declarations: scratch, the frame serial, non-parameter locals,
    // value registers.
    try text.print("    local i64:t, i64:tc, i64:to, d:dt, i64:fs\n", .{});
    for (function.locals[function.parameter_count..], function.parameter_count..) |local, number| {
        try text.print("    local {s}:l{d}\n", .{ regType(local.local_type), number });
    }
    for (function.result_types, 0..) |result_type, register| {
        if (result_type == .none) continue;
        try text.print("    local {s}:r{d}\n", .{ regType(result_type), register });
    }

    // Prologue: the call-depth budget, the frame serial when bindings
    // need one, then the typed zero for every non-parameter local
    // (the interpreter's defensive rule; S40 late declarations).
    try text.print(
        \\    mov t, i64:24(s)
        \\    sub t, t, 1
        \\    mov i64:24(s), t
        \\    blt DEPTH{d}, t, 0
        \\
    , .{index});
    if (needsSerial(program, function)) {
        try text.print("    call p_svc_serial, svc_serial, fs, s\n", .{});
    } else {
        try text.print("    mov fs, 0\n", .{});
    }
    for (function.locals[function.parameter_count..], function.parameter_count..) |local, number| {
        switch (local.local_type) {
            .float => try text.print("    dmov l{d}, 0.0\n", .{number}),
            .string => try text.print("    mov l{d}, {d}\n", .{ number, program.constants.len }),
            .heap => try text.print("    mov l{d}, 4294967295\n", .{number}),
            .strukt => |layout| {
                try text.print("    call p_svc_zero_strukt, svc_zero_strukt, l{d}, s, {d}\n", .{
                    number, layout,
                });
                try emitTrapCheck(&lowering);
            },
            else => try text.print("    mov l{d}, 0\n", .{number}),
        }
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

/// The operand registers a generic instruction marshals, in the
/// canonical order `genericResult` reads them back.
fn genericOperands(
    instruction: ir.Instruction,
    buffer: *[2]ir.Register,
) []const ir.Register {
    switch (instruction) {
        .intrinsic => |call| return call.arguments,
        .binary => |operation| {
            buffer[0] = operation.left;
            buffer[1] = operation.right;
            return buffer[0..2];
        },
        .heap_new => |new| return new.dims,
        .struct_make => |make| return make.fields,
        .struct_get => |get| {
            buffer[0] = get.target;
            return buffer[0..1];
        },
        .struct_set => |set| {
            buffer[0] = set.target;
            buffer[1] = set.value;
            return buffer[0..2];
        },
        .object_bind => |bind| {
            buffer[0] = bind.value;
            return buffer[0..1];
        },
        .object_unbind => |unbind| {
            buffer[0] = unbind.value;
            return buffer[0..1];
        },
        else => unreachable,
    }
}

/// Marshal an instruction's operands into the state slots and run it
/// through the reference implementation.
fn emitGeneric(lowering: *FunctionLowering, item: ir.Register) error{OutOfMemory}!void {
    const text = lowering.text;
    const function = lowering.function;
    const instruction = function.instructions[item];
    var buffer: [2]ir.Register = undefined;
    const operands = genericOperands(instruction, &buffer);
    for (operands, 0..) |operand, slot| {
        const offset = State.slots_offset + 8 * slot;
        if (function.result_types[operand] == .float) {
            try text.print("    dmov d:{d}(s), r{d}\n", .{ offset, operand });
        } else {
            try text.print("    mov i64:{d}(s), r{d}\n", .{ offset, operand });
        }
    }
    switch (function.result_types[item]) {
        .none => try text.print("    call p_svc_instr_v, svc_instr_v, s, {d}, {d}, fs\n", .{
            lowering.index, item,
        }),
        .float => try text.print("    call p_svc_instr_d, svc_instr_d, r{d}, s, {d}, {d}, fs\n", .{
            item, lowering.index, item,
        }),
        else => try text.print("    call p_svc_instr_i, svc_instr_i, r{d}, s, {d}, {d}, fs\n", .{
            item, lowering.index, item,
        }),
    }
    try emitTrapCheck(lowering);
}

/// The scalar element type of a fast-path sequence access: a List or
/// rank-1 Array of Int/Bool/Float indexed with one index (and, for
/// set, a scalar value).  Anything else takes the generic path.
fn fastSeqElement(lowering: *FunctionLowering, call: ir.Instruction.IntrinsicCall) ?types.Type {
    const of = lowering.function.result_types[call.arguments[0]];
    if (of != .heap) return null;
    const wanted: usize = if (call.kind == .index_get) 2 else 3;
    if (call.arguments.len != wanted) return null;
    const element = switch (lowering.program.heap_types[of.heap]) {
        .list => |element| element,
        .array => |shape| if (shape.rank == 1) shape.element else return null,
        else => return null,
    };
    return switch (element) {
        .int, .boolean, .float => element,
        else => null,
    };
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
        .binary => try lowerBinary(lowering, item),
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
        .intrinsic => |call| switch (call.kind) {
            // assert is hot in every spec; str on a String is a move.
            .assert_true => {
                const failed = try lowering.site(.assertion_failed, item);
                try text.print("    bf S{d}_{d}, r{d}\n", .{ lowering.index, failed, call.arguments[0] });
            },
            .str_value => {
                if (function.result_types[call.arguments[0]] == .string) {
                    try text.print("    mov r{d}, r{d}\n", .{ item, call.arguments[0] });
                } else {
                    try emitGeneric(lowering, item);
                }
            },
            .len => {
                const operand = call.arguments[0];
                if (function.result_types[operand] == .string) {
                    try text.print("    call p_svc_str_len, svc_str_len, r{d}, s, r{d}\n", .{
                        item, operand,
                    });
                } else {
                    try text.print("    call p_svc_obj_len, svc_obj_len, r{d}, s, {d}, {d}, r{d}\n", .{
                        item, lowering.index, item, operand,
                    });
                    try emitTrapCheck(lowering);
                }
            },
            .string_byte => {
                try text.print("    call p_svc_str_byte, svc_str_byte, r{d}, s, {d}, {d}, r{d}, r{d}\n", .{
                    item, lowering.index, item, call.arguments[0], call.arguments[1],
                });
                try emitTrapCheck(lowering);
            },
            .string_slice => {
                try text.print("    call p_svc_str_slice, svc_str_slice, r{d}, s, {d}, {d}, r{d}, r{d}, r{d}\n", .{
                    item, lowering.index, item, call.arguments[0], call.arguments[1], call.arguments[2],
                });
                try emitTrapCheck(lowering);
            },
            .append_value => {
                // Builder appends are hot in std strings; list appends
                // keep the generic path (element adoption is ownership).
                const receiver = function.result_types[call.arguments[0]];
                if (receiver == .heap and lowering.program.heap_types[receiver.heap] == .builder) {
                    try text.print("    call p_svc_builder_append, svc_builder_append, s, {d}, {d}, r{d}, r{d}\n", .{
                        lowering.index, item, call.arguments[0], call.arguments[1],
                    });
                    try emitTrapCheck(lowering);
                } else {
                    try emitGeneric(lowering, item);
                }
            },
            .index_get => {
                const element = fastSeqElement(lowering, call) orelse
                    return emitGeneric(lowering, item);
                const suffix: []const u8 = if (element == .float) "d" else "i";
                try text.print("    call p_svc_seq_get_{s}, svc_seq_get_{s}, r{d}, s, {d}, {d}, r{d}, r{d}\n", .{
                    suffix, suffix, item, lowering.index, item, call.arguments[0], call.arguments[1],
                });
                try emitTrapCheck(lowering);
            },
            .index_set => {
                const element = fastSeqElement(lowering, call) orelse
                    return emitGeneric(lowering, item);
                const suffix: []const u8 = if (element == .float) "d" else "i";
                try text.print("    call p_svc_seq_set_{s}, svc_seq_set_{s}, s, {d}, {d}, r{d}, r{d}, r{d}\n", .{
                    suffix, suffix, lowering.index, item, call.arguments[0], call.arguments[1], call.arguments[2],
                });
                try emitTrapCheck(lowering);
            },
            else => try emitGeneric(lowering, item),
        },
        .struct_make,
        .struct_get,
        .struct_set,
        .heap_new,
        .object_bind,
        .object_unbind,
        => try emitGeneric(lowering, item),
        .jump => |target| try text.print("    jmp B{d}_{d}\n", .{ lowering.index, target }),
        .branch => |branching| try text.print("    bt B{d}_{d}, r{d}\n    jmp B{d}_{d}\n", .{
            lowering.index, branching.then_block, branching.condition,
            lowering.index, branching.else_block,
        }),
        .ret => |value| {
            // Return-value ownership first (S16): what the frame
            // still owned in the value goes loose for the caller.
            if (value) |register| {
                if (carriesObjects(lowering.program, function.return_type)) {
                    const offset = State.slots_offset;
                    if (function.return_type == .float) {
                        try text.print("    dmov d:{d}(s), r{d}\n", .{ offset, register });
                    } else {
                        try text.print("    mov i64:{d}(s), r{d}\n", .{ offset, register });
                    }
                    try text.print("    call p_svc_loosen, svc_loosen, s, {d}, fs\n", .{lowering.index});
                }
            }
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

fn lowerBinary(lowering: *FunctionLowering, item: ir.Register) error{OutOfMemory}!void {
    const text = lowering.text;
    const operation = lowering.function.instructions[item].binary;
    const of = operation.operand_type;
    // String work (concat, ordering) lives in the reference
    // implementation, one service call away.
    if (of == .string) return emitGeneric(lowering, item);
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
            .remainder => try emitGeneric(lowering, item),
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

    var runtime: Runtime = .{ .machine = .{
        .arena = arena,
        .program = program,
        .inputs = inputs,
        .outputs = outputs,
        .steps = std.math.maxInt(u64),
        .max_depth = 0,
        .host = host,
    } };
    try runtime.strings.ensureTotalCapacity(arena, program.constants.len + 16);
    for (program.constants) |constant| {
        runtime.strings.appendAssumeCapacity(constant);
    }
    // The string zero value, at the handle every lowering emits.
    runtime.strings.appendAssumeCapacity("");

    var state: State = .{
        .depth_left = @intCast(budget.call_depth),
        .runtime = &runtime,
    };

    const main: *const fn (*State) callconv(.c) void = @ptrCast(@alignCast(entry));
    main(&state);

    if (state.trap == 0) {
        return .{ .success = .{ .leaked_objects = runtime.machine.live_objects } };
    }
    if (state.trap == State.oom_trap) return error.OutOfMemory;

    const code: ir.TrapCode = @enumFromInt(@as(u32, @intCast(state.trap - 1)));
    const message = if (runtime.machine.pending_trap) |pending| pending.message else code.message();
    return .{ .trap = .{
        .code = code,
        .message = message,
        .trace = try nativeTrace(arena, program, state),
    } };
}

/// One frame: where the trap fired.  The native stack is gone by the
/// time we are back here, so the native engine reports the innermost
/// frame only; the interpreter remains the engine with full call
/// traces.
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
