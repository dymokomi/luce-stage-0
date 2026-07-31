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
};

fn trapWord(code: ir.TrapCode) i64 {
    return @as(i64, @intFromEnum(code)) + 1;
}

/// A String natively: the address of one of these, arena-allocated
/// and immutable, so byte_at and len compile to plain loads.
/// Constants get theirs before lowering (addresses are embedded in
/// the emitted text); runtime strings get one per value.
const StringDesc = extern struct {
    ptr: [*]const u8,
    len: u64,
};

/// A scalar Array natively: the address of a view into the object —
/// its element storage, dims[0], the address of the stable alive
/// flag (heap cells never move), and the handle for everything
/// ownership-shaped.  Rank-1 indexing compiles to a null/alive/
/// bounds-checked inline load; every other operation converts back
/// to the handle at the service boundary.
const ArrayView = extern struct {
    elements: u64,
    len: u64,
    alive: u64,
    handle: u64,
};

/// Where a RuntimeValue keeps each scalar payload — measured at run
/// time (the union's layout is the compiler's business), embedded as
/// constants in the emitted text.
const Payloads = struct {
    int: u64,
    float: u64,
    boolean: u64,

    fn measure() Payloads {
        var probe: RuntimeValue = .{ .int = 0 };
        const base = @intFromPtr(&probe);
        const int_offset = @intFromPtr(&probe.int) - base;
        probe = .{ .float = 0 };
        const float_offset = @intFromPtr(&probe.float) - base;
        probe = .{ .boolean = false };
        const bool_offset = @intFromPtr(&probe.boolean) - base;
        return .{ .int = int_offset, .float = float_offset, .boolean = bool_offset };
    }
};

/// Everything the lowering embeds as immediates: constant string
/// descriptors (the last one is "", the string zero value) and the
/// element layout for inline array access.
const MemoryLayout = struct {
    constant_descs: []StringDesc,
    payloads: Payloads,

    const stride: u64 = @sizeOf(RuntimeValue);

    fn constDescAddress(self: *const MemoryLayout, constant: usize) i64 {
        return @bitCast(@intFromPtr(&self.constant_descs[constant]));
    }

    fn emptyStringAddress(self: *const MemoryLayout) i64 {
        return self.constDescAddress(self.constant_descs.len - 1);
    }
};

/// Scalar arrays of any rank use the view representation.
fn viewable(program: *const ir.Program, heap_index: u32) bool {
    return switch (program.heap_types[heap_index]) {
        .array => |shape| switch (shape.element) {
            .int, .boolean, .float => true,
            else => false,
        },
        else => false,
    };
}

fn newStringDesc(state: *State, text: []const u8) i64 {
    const desc = state.runtime.machine.arena.create(StringDesc) catch {
        state.trap = State.oom_trap;
        return 0;
    };
    desc.* = .{ .ptr = text.ptr, .len = text.len };
    return @bitCast(@intFromPtr(desc));
}

fn descText(raw: u64) []const u8 {
    const desc: *const StringDesc = @ptrFromInt(raw);
    return desc.ptr[0..desc.len];
}

/// A typed RuntimeValue from marshaling slot `slot`.
fn fromSlot(state: *State, slot: usize, of: types.Type) RuntimeValue {
    const raw = state.slots[slot];
    return switch (of) {
        .none => .none,
        .boolean => .{ .boolean = raw != 0 },
        .int => .{ .int = @bitCast(raw) },
        .float => .{ .float = @bitCast(raw) },
        .string => .{ .string = descText(raw) },
        .heap => |heap_index| blk: {
            if (viewable(state.runtime.machine.program, heap_index)) {
                if (raw == 0) break :blk .{ .object = backend.ObjectHandle.null_object };
                const view: *const ArrayView = @ptrFromInt(raw);
                break :blk .{ .object = .{ .index = @intCast(view.handle) } };
            }
            break :blk .{ .object = .{ .index = @intCast(raw & 0xffff_ffff) } };
        },
        .strukt => |layout| blk: {
            const fields: [*]RuntimeValue = @ptrFromInt(raw);
            const count = state.runtime.machine.program.structs[layout].fields.len;
            break :blk .{ .strukt = fields[0..count] };
        },
        .bytes => unreachable, // supported() refused the program
    };
}

/// The native i64 for a non-float RuntimeValue (floats travel on the
/// d-returning service path).  The static type decides the object
/// representation: viewable arrays travel as views, everything else
/// as handles.
fn toNative(state: *State, value: RuntimeValue, of: types.Type) i64 {
    return switch (value) {
        .none => 0,
        .boolean => |flag| @intFromBool(flag),
        .int => |number| number,
        .string => |text| newStringDesc(state, text),
        .object => |handle| objectNative(state, handle, of),
        .strukt => |fields| @bitCast(@intFromPtr(fields.ptr)),
        .float, .bytes => unreachable,
    };
}

fn objectNative(state: *State, handle: backend.ObjectHandle, of: types.Type) i64 {
    const machine = &state.runtime.machine;
    if (of == .heap and viewable(machine.program, of.heap)) {
        if (handle.isNull()) return 0;
        const object = machine.heap.items[handle.index];
        if (object.native_view) |existing| return @bitCast(@intFromPtr(existing));
        const view = machine.arena.create(ArrayView) catch {
            state.trap = State.oom_trap;
            return 0;
        };
        const array = object.data.array;
        view.* = .{
            .elements = @intFromPtr(array.elements.ptr),
            .len = if (array.dims.len == 0) 0 else @intCast(array.dims[0]),
            .alive = @intFromPtr(&object.alive),
            .handle = handle.index,
        };
        object.native_view = view;
        return @bitCast(@intFromPtr(view));
    }
    return @intCast(handle.index);
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
    const target = &state.runtime.machine.program.functions[@intCast(function)];
    return toNative(state, value, target.result_types[@intCast(instruction)]);
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
    const of: types.Type = .{ .strukt = @intCast(layout) };
    const zero = machine.zeroValue(of) catch {
        state.trap = State.oom_trap;
        return 0;
    };
    return toNative(state, zero, of);
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
    const object = machine.heap.items[index];
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
    const text = descText(@bitCast(handle));
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
    return newStringDesc(state, text[start..end]);
}

fn svcBuilderAppend(state: *State, function: i64, instruction: i64, handle: i64, text_handle: i64) callconv(.c) void {
    const object = fastResolve(state, function, instruction, handle) orelse return;
    const text = descText(@bitCast(text_handle));
    object.data.builder.appendSlice(state.runtime.machine.arena, text) catch {
        state.trap = State.oom_trap;
    };
}

fn svcBuilderAppendAscii(state: *State, function: i64, instruction: i64, handle: i64, code: i64) callconv(.c) void {
    const object = fastResolve(state, function, instruction, handle) orelse return;
    if (code < 0 or code > 0x7F) {
        recordFastTrap(state, .bad_codepoint, function, instruction);
        return;
    }
    object.data.builder.append(state.runtime.machine.arena, @intCast(code)) catch {
        state.trap = State.oom_trap;
    };
}

/// The scanning primitive.  std.mem does the block-vector search, so
/// what the JIT cannot vectorize the Zig side still does.
fn svcStrFindByte(state: *State, function: i64, instruction: i64, handle: i64, byte: i64, start: i64) callconv(.c) i64 {
    const text = descText(@bitCast(handle));
    if (byte < 0 or byte > 0xFF) {
        recordFastTrap(state, .bad_codepoint, function, instruction);
        return 0;
    }
    if (start < 0 or start > text.len) {
        recordFastTrap(state, .string_bounds, function, instruction);
        return 0;
    }
    const at = std.mem.indexOfScalarPos(u8, text, @intCast(start), @intCast(byte)) orelse return -1;
    return @intCast(at);
}

/// Int to text without the generic path's instruction lookup and
/// RuntimeValue staging — std.fmt writes two decimal digits per table
/// lookup into a stack buffer, and only the result is arena-copied.
fn svcStrInt(state: *State, value: i64) callconv(.c) i64 {
    var scratch: [24]u8 = undefined;
    const digits = std.fmt.bufPrint(&scratch, "{d}", .{value}) catch unreachable;
    const text = state.runtime.machine.arena.dupe(u8, digits) catch {
        state.trap = State.oom_trap;
        return 0;
    };
    return newStringDesc(state, text);
}

fn svcChr(state: *State, function: i64, instruction: i64, code: i64) callconv(.c) i64 {
    if (code < 0 or code > 0x10FFFF) {
        recordFastTrap(state, .bad_codepoint, function, instruction);
        return 0;
    }
    var scratch: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(@intCast(code), &scratch) catch {
        recordFastTrap(state, .bad_codepoint, function, instruction);
        return 0;
    };
    const text = state.runtime.machine.arena.dupe(u8, scratch[0..length]) catch {
        state.trap = State.oom_trap;
        return 0;
    };
    return newStringDesc(state, text);
}

fn svcStrConcat(state: *State, left: i64, right: i64) callconv(.c) i64 {
    const first = descText(@bitCast(left));
    const second = descText(@bitCast(right));
    const joined = std.mem.concat(state.runtime.machine.arena, u8, &.{ first, second }) catch {
        state.trap = State.oom_trap;
        return 0;
    };
    return newStringDesc(state, joined);
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
    .{ .name = "svc_obj_len", .address = @ptrCast(@constCast(&svcObjLen)) },
    .{ .name = "svc_str_slice", .address = @ptrCast(@constCast(&svcStrSlice)) },
    .{ .name = "svc_builder_append", .address = @ptrCast(@constCast(&svcBuilderAppend)) },
    .{ .name = "svc_builder_append_ascii", .address = @ptrCast(@constCast(&svcBuilderAppendAscii)) },
    .{ .name = "svc_str_find_byte", .address = @ptrCast(@constCast(&svcStrFindByte)) },
    .{ .name = "svc_str_int", .address = @ptrCast(@constCast(&svcStrInt)) },
    .{ .name = "svc_chr", .address = @ptrCast(@constCast(&svcChr)) },
    .{ .name = "svc_str_concat", .address = @ptrCast(@constCast(&svcStrConcat)) },
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
    layout: *const MemoryLayout,
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

fn lowerProgram(arena: Allocator, program: *const ir.Program, layout: *const MemoryLayout) error{OutOfMemory}![:0]const u8 {
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
        \\p_svc_obj_len: proto i64, i64:s, i64:f, i64:i, i64:h
        \\p_svc_str_slice: proto i64, i64:s, i64:f, i64:i, i64:h, i64:a, i64:b
        \\p_svc_builder_append: proto i64:s, i64:f, i64:i, i64:h, i64:x
        \\p_svc_builder_append_ascii: proto i64:s, i64:f, i64:i, i64:h, i64:c
        \\p_svc_str_find_byte: proto i64, i64:s, i64:f, i64:i, i64:h, i64:b, i64:a
        \\p_svc_str_int: proto i64, i64:s, i64:v
        \\p_svc_chr: proto i64, i64:s, i64:f, i64:i, i64:c
        \\p_svc_str_concat: proto i64, i64:s, i64:a, i64:b
        \\import svc_instr_i, svc_instr_d, svc_instr_v, svc_serial, svc_zero_strukt, svc_loosen
        \\import svc_seq_get_i, svc_seq_get_d, svc_seq_set_i, svc_seq_set_d, svc_obj_len
        \\import svc_str_slice, svc_builder_append, svc_builder_append_ascii
        \\import svc_str_find_byte, svc_str_int, svc_chr, svc_str_concat
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
        try lowerFunction(&text, program, layout, function, @intCast(index));
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
            // The serial only ever feeds bindings: bind/unbind, the
            // give check (S23), and return loosening (S16).  Every
            // other service ignores it, so hot leaf functions skip
            // the acquisition call.
            .object_bind, .object_unbind => return true,
            .intrinsic => |call| {
                if (call.kind == .give_object) return true;
            },
            else => {},
        }
    }
    return false;
}

fn lowerFunction(
    text: *Text,
    program: *const ir.Program,
    layout: *const MemoryLayout,
    function: *const ir.Function,
    index: u32,
) error{OutOfMemory}!void {
    var lowering: FunctionLowering = .{
        .text = text,
        .program = program,
        .layout = layout,
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
    try text.print("    local i64:t, i64:t2, i64:tc, i64:to, d:dt, i64:fs\n", .{});
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
            .string => try text.print("    mov l{d}, {d}\n", .{ number, layout.emptyStringAddress() }),
            .heap => |heap_index| try text.print("    mov l{d}, {d}\n", .{
                number,
                // Null: a zero view for viewable arrays, the null
                // handle for everything else.
                if (viewable(program, heap_index)) @as(i64, 0) else @as(i64, 4294967295),
            }),
            .strukt => |struct_layout| {
                try text.print("    call p_svc_zero_strukt, svc_zero_strukt, l{d}, s, {d}\n", .{
                    number, struct_layout,
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

/// The scalar element type of a fast-service list access: a List of
/// Int/Bool/Float with one index (scalar arrays go inline instead;
/// everything else is generic).
fn fastSeqElement(lowering: *FunctionLowering, call: ir.Instruction.IntrinsicCall) ?types.Type {
    const of = lowering.function.result_types[call.arguments[0]];
    if (of != .heap) return null;
    const wanted: usize = if (call.kind == .index_get) 2 else 3;
    if (call.arguments.len != wanted) return null;
    const element = switch (lowering.program.heap_types[of.heap]) {
        .list => |element| element,
        else => return null,
    };
    return switch (element) {
        .int, .boolean, .float => element,
        else => null,
    };
}

/// The scalar element type of an inline array access: rank-1 with
/// one index — the shape whose view makes indexing three checks and
/// a load.
fn arrayInlineElement(lowering: *FunctionLowering, call: ir.Instruction.IntrinsicCall) ?types.Type {
    const of = lowering.function.result_types[call.arguments[0]];
    if (of != .heap) return null;
    const wanted: usize = if (call.kind == .index_get) 2 else 3;
    if (call.arguments.len != wanted) return null;
    return switch (lowering.program.heap_types[of.heap]) {
        .array => |shape| if (shape.rank == 1) switch (shape.element) {
            .int, .boolean, .float => shape.element,
            else => null,
        } else null,
        else => null,
    };
}

/// Null and liveness checks on a view register: the same traps the
/// interpreter's resolve raises, as three inline instructions.
fn emitViewPrelude(lowering: *FunctionLowering, item: ir.Register, view: ir.Register) error{OutOfMemory}!void {
    const null_stub = try lowering.site(.null_object, item);
    const dead_stub = try lowering.site(.use_after_free, item);
    try lowering.text.print(
        \\    beq S{0d}_{1d}, r{3d}, 0
        \\    mov t, i64:16(r{3d})
        \\    mov t, u8:0(t)
        \\    beq S{0d}_{2d}, t, 0
        \\
    , .{ lowering.index, null_stub, dead_stub, view });
}

/// Inline rank-1 array indexing: bounds check against the view, then
/// a typed load or store at elements + index * stride + payload
/// offset.  The element tag never changes, so a store that writes
/// only the payload leaves the value well-formed.
fn emitArrayAccess(lowering: *FunctionLowering, item: ir.Register, call: ir.Instruction.IntrinsicCall, element: types.Type) error{OutOfMemory}!void {
    const text = lowering.text;
    const view = call.arguments[0];
    const index_register = call.arguments[1];
    try emitViewPrelude(lowering, item, view);
    const bounds = try lowering.site(.index_bounds, item);
    try text.print(
        \\    mov t, i64:8(r{1d})
        \\    ubge S{2d}_{3d}, r{0d}, t
        \\    mov t, i64:0(r{1d})
        \\    mul t2, r{0d}, {4d}
        \\    add t, t, t2
        \\
    , .{ index_register, view, lowering.index, bounds, MemoryLayout.stride });
    const payloads = lowering.layout.payloads;
    if (call.kind == .index_get) {
        switch (element) {
            .float => try text.print("    dmov r{d}, d:{d}(t)\n", .{ item, payloads.float }),
            .int => try text.print("    mov r{d}, i64:{d}(t)\n", .{ item, payloads.int }),
            .boolean => try text.print("    mov r{d}, u8:{d}(t)\n", .{ item, payloads.boolean }),
            else => unreachable,
        }
    } else {
        const value = call.arguments[2];
        switch (element) {
            .float => try text.print("    dmov d:{d}(t), r{d}\n", .{ payloads.float, value }),
            .int => try text.print("    mov i64:{d}(t), r{d}\n", .{ payloads.int, value }),
            .boolean => try text.print("    mov u8:{d}(t), r{d}\n", .{ payloads.boolean, value }),
            else => unreachable,
        }
    }
}

fn lowerInstruction(lowering: *FunctionLowering, item: ir.Register) error{OutOfMemory}!void {
    const text = lowering.text;
    const function = lowering.function;
    const instruction = function.instructions[item];
    switch (instruction) {
        .const_boolean => |value| try text.print("    mov r{d}, {d}\n", .{ item, @intFromBool(value) }),
        .const_int => |value| try text.print("    mov r{d}, {d}\n", .{ item, value }),
        .const_float => |value| try emitFloatMove(text, item, value),
        .const_data => |data| try text.print("    mov r{d}, {d}\n", .{
            item, lowering.layout.constDescAddress(data.constant),
        }),
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
                const of = function.result_types[call.arguments[0]];
                if (of == .string) {
                    try text.print("    mov r{d}, r{d}\n", .{ item, call.arguments[0] });
                } else if (of == .int) {
                    // str(i) is the hottest formatting path there is.
                    // Formatting itself cannot fail, but the result is
                    // allocated, so the OOM check still follows: a
                    // failed allocation leaves a null descriptor, and
                    // nothing may run on with one.
                    try text.print("    call p_svc_str_int, svc_str_int, r{d}, s, r{d}\n", .{
                        item, call.arguments[0],
                    });
                    try emitTrapCheck(lowering);
                } else {
                    try emitGeneric(lowering, item);
                }
            },
            .chr_code => {
                try text.print("    call p_svc_chr, svc_chr, r{d}, s, {d}, {d}, r{d}\n", .{
                    item, lowering.index, item, call.arguments[0],
                });
                try emitTrapCheck(lowering);
            },
            .string_find_byte => {
                try text.print("    call p_svc_str_find_byte, svc_str_find_byte, r{d}, s, {d}, {d}, r{d}, r{d}, r{d}\n", .{
                    item, lowering.index, item, call.arguments[0], call.arguments[1], call.arguments[2],
                });
                try emitTrapCheck(lowering);
            },
            .append_ascii => {
                try text.print("    call p_svc_builder_append_ascii, svc_builder_append_ascii, s, {d}, {d}, r{d}, r{d}\n", .{
                    lowering.index, item, call.arguments[0], call.arguments[1],
                });
                try emitTrapCheck(lowering);
            },
            .len => {
                const operand = call.arguments[0];
                const of = function.result_types[operand];
                if (of == .string) {
                    // A string is a {ptr, len} descriptor: one load.
                    try text.print("    mov r{d}, i64:8(r{d})\n", .{ item, operand });
                } else if (of == .heap and viewable(lowering.program, of.heap)) {
                    try emitViewPrelude(lowering, item, operand);
                    try text.print("    mov r{d}, i64:8(r{d})\n", .{ item, operand });
                } else {
                    try text.print("    call p_svc_obj_len, svc_obj_len, r{d}, s, {d}, {d}, r{d}\n", .{
                        item, lowering.index, item, operand,
                    });
                    try emitTrapCheck(lowering);
                }
            },
            .string_byte => {
                // Inline: bounds against the descriptor, one byte
                // load (ubge treats a negative index as huge).
                const bounds = try lowering.site(.string_bounds, item);
                try text.print(
                    \\    mov t, i64:8(r{1d})
                    \\    ubge S{3d}_{4d}, r{2d}, t
                    \\    mov t, i64:0(r{1d})
                    \\    mov r{0d}, u8:(t, r{2d})
                    \\
                , .{ item, call.arguments[0], call.arguments[1], lowering.index, bounds });
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
                if (arrayInlineElement(lowering, call)) |element| {
                    try emitArrayAccess(lowering, item, call, element);
                } else if (fastSeqElement(lowering, call)) |element| {
                    const suffix: []const u8 = if (element == .float) "d" else "i";
                    try text.print("    call p_svc_seq_get_{s}, svc_seq_get_{s}, r{d}, s, {d}, {d}, r{d}, r{d}\n", .{
                        suffix, suffix, item, lowering.index, item, call.arguments[0], call.arguments[1],
                    });
                    try emitTrapCheck(lowering);
                } else {
                    try emitGeneric(lowering, item);
                }
            },
            .index_set => {
                if (arrayInlineElement(lowering, call)) |element| {
                    try emitArrayAccess(lowering, item, call, element);
                } else if (fastSeqElement(lowering, call)) |element| {
                    const suffix: []const u8 = if (element == .float) "d" else "i";
                    try text.print("    call p_svc_seq_set_{s}, svc_seq_set_{s}, s, {d}, {d}, r{d}, r{d}, r{d}\n", .{
                        suffix, suffix, lowering.index, item, call.arguments[0], call.arguments[1], call.arguments[2],
                    });
                    try emitTrapCheck(lowering);
                } else {
                    try emitGeneric(lowering, item);
                }
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
    // Concatenation gets a direct service; string ordering stays with
    // the reference implementation.  Concat allocates, so the OOM
    // check follows it.
    if (of == .string) {
        if (operation.op != .add) return emitGeneric(lowering, item);
        try lowering.text.print("    call p_svc_str_concat, svc_str_concat, r{d}, s, r{d}, r{d}\n", .{
            item, operation.left, operation.right,
        });
        try emitTrapCheck(lowering);
        return;
    }
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

    // Constant descriptors and the value layout come first: the
    // emitted text embeds their addresses and offsets as immediates.
    const constant_descs = try arena.alloc(StringDesc, program.constants.len + 1);
    for (program.constants, constant_descs[0..program.constants.len]) |constant, *desc| {
        desc.* = .{ .ptr = constant.ptr, .len = constant.len };
    }
    constant_descs[program.constants.len] = .{ .ptr = "", .len = 0 };
    const layout: MemoryLayout = .{
        .constant_descs = constant_descs,
        .payloads = Payloads.measure(),
    };

    const text = try lowerProgram(arena, program, &layout);

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
