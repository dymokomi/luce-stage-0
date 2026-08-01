//! The self-written backend, x86-64 — Luce IR emitted straight to
//! machine code, no MIR, no C.  The twin of codegen.zig (aarch64):
//! same seams (native.abi word offsets + AddressTable, hermetic
//! spans read through the State's address table, image.map +
//! native.runCode), same trap protocol, same oracle.
//!
//! Milestone 1: the scalar arithmetic core — Int/Float/Bool values
//! and arithmetic with every check (overflow via JO, idiv's zero and
//! MIN/-1 guards, Int(Float)'s NaN and range guards), comparisons
//! with cmp+jcc fusion on the integer path, C-ABI calls and
//! recursion, and the arithmetic-core intrinsics (str, print,
//! assert, trap) through the generic marshaling service.  A String
//! is carried only as an opaque descriptor word (a constant's
//! address or str()'s result); anything that inspects string bytes,
//! or any heap object, falls outside `supported()` and the runner's
//! engine ladder drops such a program to MIR — exactly the boundary
//! the aarch64 backend drew at its own milestone 1.
//!
//! Registers (System V AMD64).  r15 = State, r14 = frame serial
//! (zero in the scalar core; no bindings), rbx/r12 pin the first two
//! integer/bool locals in callee-saved homes, everything else lives
//! in rbp-relative frame slots.  Values stay lazy (immediates,
//! constant-table loads, and pinned-local aliases) until a use
//! forces them; an integer comparison feeding the adjacent branch
//! fuses to cmp + jcc.  rax/rdx are transient scratch (and idiv's
//! implicit pair), r13 the call target; xmm0-xmm3 a float scratch
//! pool, xmm5 transient.  Floats are never pinned (no XMM register
//! is callee-saved on this ABI), so they spill across calls.

const std = @import("std");
const builtin = @import("builtin");
const ir = @import("ir.zig");
const types = @import("types.zig");
const native = @import("native.zig");
const image = @import("image.zig");

const Allocator = std.mem.Allocator;
const abi = native.abi;
const AddressTable = native.AddressTable;

pub const available = builtin.cpu.arch == .x86_64 and image.supported;

/// Calls take value args in rsi,rdx,rcx,r8,r9 and float args in
/// xmm0-xmm7; wider signatures fall to MIR through the ladder.
const max_value_arguments = 5;
const max_float_arguments = 8;

/// Whether the whole program fits this backend: since milestone 2,
/// everything MIR's core takes (native.supported), narrowed only by
/// this ABI's register-passed argument counts and the shared frame
/// bound.  Anything wider drops to MIR through the runner's ladder.
pub fn supported(program: *const ir.Program) bool {
    if (!available) return false;
    if (!native.supported(program)) return false;
    for (program.functions) |*function| {
        if (function.locals.len + function.instructions.len > native.max_function_slots) return false;
        var value_arguments: usize = 0;
        var float_arguments: usize = 0;
        for (function.locals[0..function.parameter_count]) |local| {
            if (local.local_type == .float) float_arguments += 1 else value_arguments += 1;
        }
        if (value_arguments > max_value_arguments) return false;
        if (float_arguments > max_float_arguments) return false;
    }
    return true;
}

/// Compile the program to one hermetic span per function.
pub fn compile(arena: Allocator, program: *const ir.Program) error{OutOfMemory}![]const []const u8 {
    const table = try AddressTable.collect(arena, program);
    const spans = try arena.alloc([]const u8, program.functions.len);
    for (program.functions, spans, 0..) |*function, *span, index| {
        var emitter: Emitter = .{
            .arena = arena,
            .program = program,
            .table = table,
            .function = function,
            .function_index = @intCast(index),
        };
        try emitter.emitFunction();
        span.* = emitter.code.items;
    }
    return spans;
}

// ---------------------------------------------------------------------------
// The emitter
// ---------------------------------------------------------------------------

const Fixup = struct { at: usize, mark: u32 };
const TrapSite = struct { mark: u32, code: ir.TrapCode, instruction: u32 };

const Location = union(enum) {
    nowhere,
    register: u4,
    fregister: u4,
    slot,
    immediate: i64,
    table: u64,
    alias: struct { local: u32, version: u32 },
};

// General registers (SysV): callee-saved rbx(3), r12(12) pin locals;
// r13(13) is the call target; r14(14)=serial, r15(15)=State.  The
// value scratch pool is caller-saved r10,r11; rax,rdx are transient.
const scratch_pool = [_]u4{ 10, 11 };
const float_pool = [_]u4{ 0, 1, 2, 3 }; // xmm0-xmm3
const pinned_pool = [_]u4{ 3, 12 };

const state: u4 = 15;
const serial: u4 = 14;
const call_target: u4 = 13;
const helper: u4 = 0; // rax — also idiv low / return
const helper2: u4 = 2; // rdx — also idiv high
const fhelper: u4 = 5; // xmm5

// x86 condition codes (tttn).
const cc_o: u4 = 0x0;
const cc_ae: u4 = 0x3;
const cc_e: u4 = 0x4;
const cc_ne: u4 = 0x5;
const cc_a: u4 = 0x7;
const cc_l: u4 = 0xC;
const cc_ge: u4 = 0xD;
const cc_le: u4 = 0xE;
const cc_g: u4 = 0xF;

const Emitter = struct {
    arena: Allocator,
    program: *const ir.Program,
    table: AddressTable,
    function: *const ir.Function,
    function_index: u32,
    code: std.ArrayList(u8) = .empty,
    marks: std.ArrayList(?usize) = .empty,
    fixups: std.ArrayList(Fixup) = .empty,
    sites: std.ArrayList(TrapSite) = .empty,
    block_marks: []u32 = &.{},
    epilogue: u32 = 0,
    propagate: u32 = 0,
    frame_size: u64 = 0,

    positions: []u32 = &.{},
    last_use: []u32 = &.{},
    use_count: []u32 = &.{},

    location: []Location = &.{},
    scratch_owner: [scratch_pool.len]?ir.Register = @splat(null),
    float_owner: [float_pool.len]?ir.Register = @splat(null),
    pinned: []?u4 = &.{},
    local_version: []u32 = &.{},
    position: u32 = 0,
    pending_compare: ?struct { register: ir.Register, condition: u4 } = null,
    current_block: u32 = 0,

    // -- byte-level emission -----------------------------------------------

    fn byte(self: *Emitter, value: u8) error{OutOfMemory}!void {
        try self.code.append(self.arena, value);
    }

    fn bytes(self: *Emitter, slice: []const u8) error{OutOfMemory}!void {
        try self.code.appendSlice(self.arena, slice);
    }

    fn imm32(self: *Emitter, value: i32) error{OutOfMemory}!void {
        try self.bytes(&std.mem.toBytes(std.mem.nativeToLittle(i32, value)));
    }

    fn here(self: *const Emitter) usize {
        return self.code.items.len;
    }

    fn newMark(self: *Emitter) error{OutOfMemory}!u32 {
        try self.marks.append(self.arena, null);
        return @intCast(self.marks.items.len - 1);
    }

    fn bind(self: *Emitter, mark: u32) void {
        self.marks.items[mark] = self.here();
    }

    fn typeOf(self: *const Emitter, register: ir.Register) types.Type {
        return self.function.result_types[register];
    }

    fn isFloat(self: *const Emitter, register: ir.Register) bool {
        return self.typeOf(register) == .float;
    }

    // -- ModRM / REX primitives -------------------------------------------

    /// REX prefix for a reg/rm pair; W selects 64-bit.  Emitted only
    /// when a bit is needed, except we always emit for W=1.
    fn rex(self: *Emitter, w: bool, reg: u4, index: u4, rm: u4) error{OutOfMemory}!void {
        const value: u8 = 0x40 |
            (@as(u8, @intFromBool(w)) << 3) |
            (@as(u8, reg >> 3) << 2) |
            (@as(u8, index >> 3) << 1) |
            (@as(u8, rm >> 3));
        try self.byte(value);
    }

    fn modrmReg(self: *Emitter, reg: u4, rm: u4) error{OutOfMemory}!void {
        try self.byte(0xC0 | (@as(u8, reg & 7) << 3) | (rm & 7));
    }

    /// ModRM+disp32 for [base + disp]; base rsp/r12 would need a SIB,
    /// but this backend only ever bases memory on rbp, r15 (State),
    /// and view registers, none of which are rsp/r12 as a base here.
    fn modrmMem(self: *Emitter, reg: u4, base: u4, disp: i32) error{OutOfMemory}!void {
        try self.byte(0x80 | (@as(u8, reg & 7) << 3) | (base & 7));
        if ((base & 7) == 4) try self.byte(0x24); // SIB for rsp/r12 base
        try self.imm32(disp);
    }

    // -- moves & memory ----------------------------------------------------

    fn movReg(self: *Emitter, dst: u4, src: u4) error{OutOfMemory}!void {
        if (dst == src) return;
        try self.rex(true, src, 0, dst);
        try self.byte(0x89); // mov rm, reg
        try self.modrmReg(src, dst);
    }

    fn materialize(self: *Emitter, dst: u4, value: u64) error{OutOfMemory}!void {
        if (value == 0) {
            // xor dst, dst (clears the full 64-bit register).
            try self.rex(false, dst, 0, dst);
            try self.byte(0x31);
            try self.modrmReg(dst, dst);
            return;
        }
        // movabs dst, imm64.
        try self.rex(true, 0, 0, dst);
        try self.byte(0xB8 | (@as(u8, dst) & 7));
        try self.bytes(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
    }

    fn slotDisp(self: *const Emitter, slot: usize) i32 {
        _ = self;
        return -@as(i32, @intCast(48 + slot * 8));
    }

    fn loadMem(self: *Emitter, dst: u4, base: u4, disp: i32) error{OutOfMemory}!void {
        try self.rex(true, dst, 0, base);
        try self.byte(0x8B); // mov reg, rm
        try self.modrmMem(dst, base, disp);
    }

    fn storeMem(self: *Emitter, src: u4, base: u4, disp: i32) error{OutOfMemory}!void {
        try self.rex(true, src, 0, base);
        try self.byte(0x89); // mov rm, reg
        try self.modrmMem(src, base, disp);
    }

    fn loadSlot(self: *Emitter, dst: u4, slot: usize) error{OutOfMemory}!void {
        try self.loadMem(dst, 5, self.slotDisp(slot)); // rbp base
    }

    fn storeSlot(self: *Emitter, src: u4, slot: usize) error{OutOfMemory}!void {
        try self.storeMem(src, 5, self.slotDisp(slot));
    }

    fn loadWord(self: *Emitter, dst: u4, base: u4, offset: u64) error{OutOfMemory}!void {
        try self.loadMem(dst, base, @intCast(offset));
    }

    fn storeWord(self: *Emitter, src: u4, base: u4, offset: u64) error{OutOfMemory}!void {
        try self.storeMem(src, base, @intCast(offset));
    }

    /// A table entry off the State (r15): mov dst, [r15 + offset].
    fn loadTable(self: *Emitter, dst: u4, offset: u64) error{OutOfMemory}!void {
        try self.loadMem(dst, state, @intCast(offset));
    }

    // -- float moves & memory ---------------------------------------------

    /// movsd for [base + disp]; opcode selects load (0x10) or store
    /// (0x11).  xmm registers use the same reg field.
    fn fmem(self: *Emitter, opcode: u8, reg: u4, base: u4, disp: i32) error{OutOfMemory}!void {
        try self.byte(0xF2);
        if (reg >= 8 or base >= 8) try self.rex(false, reg, 0, base);
        try self.byte(0x0F);
        try self.byte(opcode);
        try self.modrmMem(reg, base, disp);
    }

    fn floadSlot(self: *Emitter, dst: u4, slot: usize) error{OutOfMemory}!void {
        try self.fmem(0x10, dst, 5, self.slotDisp(slot));
    }

    fn fstoreSlot(self: *Emitter, src: u4, slot: usize) error{OutOfMemory}!void {
        try self.fmem(0x11, src, 5, self.slotDisp(slot));
    }

    fn floadWord(self: *Emitter, dst: u4, base: u4, offset: u64) error{OutOfMemory}!void {
        try self.fmem(0x10, dst, base, @intCast(offset));
    }

    fn fstoreWord(self: *Emitter, src: u4, base: u4, offset: u64) error{OutOfMemory}!void {
        try self.fmem(0x11, src, base, @intCast(offset));
    }

    fn floadTable(self: *Emitter, dst: u4, offset: u64) error{OutOfMemory}!void {
        try self.fmem(0x10, dst, state, @intCast(offset));
    }

    fn fmovRegs(self: *Emitter, dst: u4, src: u4) error{OutOfMemory}!void {
        if (dst == src) return;
        try self.byte(0xF2);
        if (dst >= 8 or src >= 8) try self.rex(false, dst, 0, src);
        try self.byte(0x0F);
        try self.byte(0x10); // movsd xmm(dst), xmm(src)
        try self.modrmReg(dst, src);
    }

    /// xorps xmm, xmm — the float zero.
    fn fzero(self: *Emitter, dst: u4) error{OutOfMemory}!void {
        if (dst >= 8) try self.rex(false, dst, 0, dst);
        try self.byte(0x0F);
        try self.byte(0x57); // xorps
        try self.modrmReg(dst, dst);
    }

    // -- integer arithmetic on registers ----------------------------------

    /// A two-register ALU op (0x01 add, 0x29 sub, 0x39 cmp, 0x31 xor,
    /// 0x09 or, 0x21 and, 0x85 test) in `rm op= reg` direction: the
    /// result lands in `dst`, `src` is the reg field.
    fn alu(self: *Emitter, opcode: u8, dst: u4, src: u4) error{OutOfMemory}!void {
        try self.rex(true, src, 0, dst);
        try self.byte(opcode);
        try self.modrmReg(src, dst);
    }

    fn compareRegisters(self: *Emitter, a: u4, b: u4) error{OutOfMemory}!void {
        try self.alu(0x39, a, b); // cmp a, b  (a - b)
    }

    fn compareImmediate(self: *Emitter, reg: u4, value: i64) error{OutOfMemory}!void {
        // cmp rm, imm32 (81 /7).
        try self.rex(true, 0, 0, reg);
        try self.byte(0x81);
        try self.byte(0xF8 | @as(u8, reg & 7)); // /7
        try self.imm32(@intCast(value));
    }

    fn testReg(self: *Emitter, reg: u4) error{OutOfMemory}!void {
        try self.alu(0x85, reg, reg); // test reg, reg
    }

    fn setCond(self: *Emitter, dst: u4, condition: u4) error{OutOfMemory}!void {
        // setcc dst8, then movzx dst, dst8 for a clean 0/1.
        if (dst >= 4) try self.rex(false, 0, 0, dst); // reach sil/dil/r8b..
        try self.byte(0x0F);
        try self.byte(0x90 | @as(u8, condition));
        try self.byte(0xC0 | @as(u8, dst & 7));
        // movzx dst(64), dst(8).
        try self.rex(true, dst, 0, dst);
        try self.byte(0x0F);
        try self.byte(0xB6);
        try self.modrmReg(dst, dst);
    }

    fn callReg(self: *Emitter, reg: u4) error{OutOfMemory}!void {
        if (reg >= 8) try self.byte(0x41); // REX.B
        try self.byte(0xFF);
        try self.byte(0xD0 | @as(u8, reg & 7)); // /2
    }

    // -- branches ----------------------------------------------------------

    fn branchTo(self: *Emitter, mark: u32) error{OutOfMemory}!void {
        try self.byte(0xE9);
        try self.fixups.append(self.arena, .{ .at = self.here(), .mark = mark });
        try self.imm32(0);
    }

    fn branchCond(self: *Emitter, condition: u4, mark: u32) error{OutOfMemory}!void {
        try self.byte(0x0F);
        try self.byte(0x80 | @as(u8, condition));
        try self.fixups.append(self.arena, .{ .at = self.here(), .mark = mark });
        try self.imm32(0);
    }

    fn branchZero(self: *Emitter, reg: u4, mark: u32, when_zero: bool) error{OutOfMemory}!void {
        try self.testReg(reg);
        try self.branchCond(if (when_zero) cc_e else cc_ne, mark);
    }

    // -- the trap protocol -------------------------------------------------

    fn trapSite(self: *Emitter, code: ir.TrapCode, instruction: u32) error{OutOfMemory}!u32 {
        const mark = try self.newMark();
        try self.sites.append(self.arena, .{ .mark = mark, .code = code, .instruction = instruction });
        return mark;
    }

    fn trapCheck(self: *Emitter) error{OutOfMemory}!void {
        try self.loadWord(helper, state, abi.trap_offset);
        try self.branchZero(helper, self.propagate, false);
    }

    // -- analysis ----------------------------------------------------------

    fn operandsOf(instruction: *const ir.Instruction, buffer: *[2]ir.Register) []const ir.Register {
        switch (instruction.*) {
            .binary => |operation| {
                buffer[0] = operation.left;
                buffer[1] = operation.right;
                return buffer[0..2];
            },
            .unary => |operation| {
                buffer[0] = operation.operand;
                return buffer[0..1];
            },
            .convert => |operation| {
                buffer[0] = operation.operand;
                return buffer[0..1];
            },
            .local_set => |set| {
                buffer[0] = set.value;
                return buffer[0..1];
            },
            .branch => |branching| {
                buffer[0] = branching.condition;
                return buffer[0..1];
            },
            .ret => |value| {
                if (value) |register| {
                    buffer[0] = register;
                    return buffer[0..1];
                }
                return buffer[0..0];
            },
            .call => |call| return call.arguments,
            .intrinsic => |call| return call.arguments,
            // Generic-service instructions marshal their operands in
            // the canonical order genericResult reads them back (kept in
            // lockstep with native.zig's genericOperands); analyze()
            // reads the same list for liveness, so an omission here both
            // starves the slots and mistracks the operand's last use.
            .heap_new => |new| return new.dims,
            .struct_make => |make| return make.fields,
            .struct_get => |getter| {
                buffer[0] = getter.target;
                return buffer[0..1];
            },
            .struct_set => |setter| {
                buffer[0] = setter.target;
                buffer[1] = setter.value;
                return buffer[0..2];
            },
            .object_bind => |binding| {
                buffer[0] = binding.value;
                return buffer[0..1];
            },
            .object_unbind => |unbinding| {
                buffer[0] = unbinding.value;
                return buffer[0..1];
            },
            else => return buffer[0..0],
        }
    }

    fn analyze(self: *Emitter) error{OutOfMemory}!void {
        const function = self.function;
        const count = function.instructions.len;
        self.positions = try self.arena.alloc(u32, count);
        self.last_use = try self.arena.alloc(u32, count);
        self.use_count = try self.arena.alloc(u32, count);
        self.location = try self.arena.alloc(Location, count);
        @memset(self.last_use, 0);
        @memset(self.use_count, 0);
        @memset(self.location, .nowhere);
        var position: u32 = 0;
        for (function.blocks) |block| {
            for (block.items) |item| {
                self.positions[item] = position;
                var buffer: [2]ir.Register = undefined;
                for (operandsOf(&function.instructions[item], &buffer)) |operand| {
                    self.last_use[operand] = position;
                    self.use_count[operand] += 1;
                }
                position += 1;
            }
        }
    }

    // -- the allocator -----------------------------------------------------

    fn slotOf(self: *const Emitter, register: ir.Register) usize {
        return self.function.locals.len + register;
    }

    fn poolIndexOf(register: u4) usize {
        for (scratch_pool, 0..) |candidate, index| {
            if (candidate == register) return index;
        }
        unreachable;
    }

    fn floatPoolIndexOf(register: u4) usize {
        for (float_pool, 0..) |candidate, index| {
            if (candidate == register) return index;
        }
        unreachable;
    }

    fn contains(haystack: []const u4, needle: u4) bool {
        for (haystack) |candidate| {
            if (candidate == needle) return true;
        }
        return false;
    }

    fn allocScratch(self: *Emitter, owner: ir.Register, locked: []const u4) error{OutOfMemory}!u4 {
        for (scratch_pool, 0..) |candidate, index| {
            if (self.scratch_owner[index] == null and !contains(locked, candidate)) {
                self.scratch_owner[index] = owner;
                return candidate;
            }
        }
        var victim: ?usize = null;
        for (scratch_pool, 0..) |candidate, index| {
            if (contains(locked, candidate)) continue;
            const resident = self.scratch_owner[index].?;
            if (victim == null or
                self.last_use[resident] > self.last_use[self.scratch_owner[victim.?].?])
            {
                victim = index;
            }
        }
        const index = victim.?;
        const evicted = self.scratch_owner[index].?;
        try self.storeSlot(scratch_pool[index], self.slotOf(evicted));
        self.location[evicted] = .slot;
        self.scratch_owner[index] = owner;
        return scratch_pool[index];
    }

    fn allocFloat(self: *Emitter, owner: ir.Register, locked: []const u4) error{OutOfMemory}!u4 {
        for (float_pool, 0..) |candidate, index| {
            if (self.float_owner[index] == null and !contains(locked, candidate)) {
                self.float_owner[index] = owner;
                return candidate;
            }
        }
        var victim: ?usize = null;
        for (float_pool, 0..) |candidate, index| {
            if (contains(locked, candidate)) continue;
            const resident = self.float_owner[index].?;
            if (victim == null or
                self.last_use[resident] > self.last_use[self.float_owner[victim.?].?])
            {
                victim = index;
            }
        }
        const index = victim.?;
        const evicted = self.float_owner[index].?;
        try self.fstoreSlot(float_pool[index], self.slotOf(evicted));
        self.location[evicted] = .slot;
        self.float_owner[index] = owner;
        return float_pool[index];
    }

    fn release(self: *Emitter, register: ir.Register) void {
        switch (self.location[register]) {
            .register => |physical| self.scratch_owner[poolIndexOf(physical)] = null,
            .fregister => |physical| self.float_owner[floatPoolIndexOf(physical)] = null,
            else => {},
        }
        self.location[register] = .nowhere;
    }

    fn freeDead(self: *Emitter, operands: []const ir.Register) void {
        for (operands) |operand| {
            if (self.last_use[operand] <= self.position) self.release(operand);
        }
    }

    fn operandRegister(self: *Emitter, register: ir.Register, locked: []const u4) error{OutOfMemory}!u4 {
        if (self.isFloat(register)) return self.operandFloat(register, locked);
        switch (self.location[register]) {
            .register => |physical| return physical,
            .fregister => unreachable,
            .nowhere => unreachable,
            .slot => {
                const physical = try self.allocScratch(register, locked);
                try self.loadSlot(physical, self.slotOf(register));
                self.location[register] = .{ .register = physical };
                return physical;
            },
            .immediate => |value| {
                const physical = try self.allocScratch(register, locked);
                try self.materialize(physical, @bitCast(value));
                self.location[register] = .{ .register = physical };
                return physical;
            },
            .table => |offset| {
                const physical = try self.allocScratch(register, locked);
                try self.loadTable(physical, offset);
                self.location[register] = .{ .register = physical };
                return physical;
            },
            .alias => |lazy| {
                if (self.local_version[lazy.local] == lazy.version) {
                    if (self.pinned[lazy.local]) |physical| return physical;
                }
                const physical = try self.allocScratch(register, locked);
                if (self.local_version[lazy.local] == lazy.version) {
                    try self.loadSlot(physical, lazy.local);
                } else {
                    try self.loadSlot(physical, self.slotOf(register));
                }
                self.location[register] = .{ .register = physical };
                return physical;
            },
        }
    }

    fn operandFloat(self: *Emitter, register: ir.Register, locked: []const u4) error{OutOfMemory}!u4 {
        switch (self.location[register]) {
            .fregister => |physical| return physical,
            .register, .immediate => unreachable,
            .nowhere => unreachable,
            .slot => {
                const physical = try self.allocFloat(register, locked);
                try self.floadSlot(physical, self.slotOf(register));
                self.location[register] = .{ .fregister = physical };
                return physical;
            },
            .table => |offset| {
                const physical = try self.allocFloat(register, locked);
                try self.floadTable(physical, offset);
                self.location[register] = .{ .fregister = physical };
                return physical;
            },
            .alias => |lazy| {
                const physical = try self.allocFloat(register, locked);
                if (self.local_version[lazy.local] == lazy.version) {
                    try self.floadSlot(physical, lazy.local);
                } else {
                    try self.floadSlot(physical, self.slotOf(register));
                }
                self.location[register] = .{ .fregister = physical };
                return physical;
            },
        }
    }

    fn fetchInto(self: *Emitter, target: u4, register: ir.Register) error{OutOfMemory}!void {
        if (self.isFloat(register)) return self.ffetchInto(target, register);
        switch (self.location[register]) {
            .register => |physical| try self.movReg(target, physical),
            .fregister => unreachable,
            .nowhere => unreachable,
            .slot => try self.loadSlot(target, self.slotOf(register)),
            .immediate => |value| try self.materialize(target, @bitCast(value)),
            .table => |offset| try self.loadTable(target, offset),
            .alias => |lazy| {
                if (self.local_version[lazy.local] == lazy.version) {
                    if (self.pinned[lazy.local]) |physical| {
                        try self.movReg(target, physical);
                    } else {
                        try self.loadSlot(target, lazy.local);
                    }
                } else {
                    try self.loadSlot(target, self.slotOf(register));
                }
            },
        }
    }

    fn ffetchInto(self: *Emitter, target: u4, register: ir.Register) error{OutOfMemory}!void {
        switch (self.location[register]) {
            .fregister => |physical| try self.fmovRegs(target, physical),
            .register, .immediate => unreachable,
            .nowhere => unreachable,
            .slot => try self.floadSlot(target, self.slotOf(register)),
            .table => |offset| try self.floadTable(target, offset),
            .alias => |lazy| {
                if (self.local_version[lazy.local] == lazy.version) {
                    try self.floadSlot(target, lazy.local);
                } else {
                    try self.floadSlot(target, self.slotOf(register));
                }
            },
        }
    }

    fn materializeAliases(self: *Emitter, local: u32) error{OutOfMemory}!void {
        const version = self.local_version[local];
        const floaty = self.function.locals[local].local_type == .float;
        for (self.location, 0..) |current, register| {
            if (current != .alias) continue;
            if (current.alias.local != local or current.alias.version != version) continue;
            if (self.last_use[register] <= self.position) continue;
            if (self.pinned[local]) |physical| {
                if (floaty) {
                    try self.fstoreSlot(physical, self.slotOf(@intCast(register)));
                } else {
                    try self.storeSlot(physical, self.slotOf(@intCast(register)));
                }
            } else if (floaty) {
                try self.floadSlot(fhelper, local);
                try self.fstoreSlot(fhelper, self.slotOf(@intCast(register)));
            } else {
                try self.loadSlot(helper, local);
                try self.storeSlot(helper, self.slotOf(@intCast(register)));
            }
            self.location[register] = .slot;
        }
    }

    /// Before any call, every occupied pool value spills to its slot
    /// so nothing rides in a caller-saved register across the call.
    /// Every occupant is spilled — including a value whose last use is
    /// the call itself (a call argument): the argument is then fetched
    /// from its slot into an ABI register, so it must not be dropped to
    /// `.nowhere` first (that was the milestone-1 hazard, latent until
    /// calls carried operands that lived in the pool).  A truly dead
    /// occupant costs one wasted store; the fast path will prune it.
    fn spillForCall(self: *Emitter) error{OutOfMemory}!void {
        for (scratch_pool, 0..) |physical, index| {
            const resident = self.scratch_owner[index] orelse continue;
            try self.storeSlot(physical, self.slotOf(resident));
            self.location[resident] = .slot;
            self.scratch_owner[index] = null;
        }
        for (float_pool, 0..) |physical, index| {
            const resident = self.float_owner[index] orelse continue;
            try self.fstoreSlot(physical, self.slotOf(resident));
            self.location[resident] = .slot;
            self.float_owner[index] = null;
        }
    }

    fn destRegister(self: *Emitter, item: ir.Register, operands: []const ir.Register, locked: []const u4) error{OutOfMemory}!u4 {
        if (self.isFloat(item)) return self.destFloat(item, operands, locked);
        for (operands) |operand| {
            if (self.last_use[operand] > self.position) continue;
            switch (self.location[operand]) {
                .register => |physical| {
                    self.scratch_owner[poolIndexOf(physical)] = item;
                    self.location[operand] = .nowhere;
                    self.location[item] = .{ .register = physical };
                    return physical;
                },
                else => {},
            }
        }
        const physical = try self.allocScratch(item, locked);
        self.location[item] = .{ .register = physical };
        return physical;
    }

    fn destFloat(self: *Emitter, item: ir.Register, operands: []const ir.Register, locked: []const u4) error{OutOfMemory}!u4 {
        for (operands) |operand| {
            if (self.last_use[operand] > self.position) continue;
            switch (self.location[operand]) {
                .fregister => |physical| {
                    self.float_owner[floatPoolIndexOf(physical)] = item;
                    self.location[operand] = .nowhere;
                    self.location[item] = .{ .fregister = physical };
                    return physical;
                },
                else => {},
            }
        }
        const physical = try self.allocFloat(item, locked);
        self.location[item] = .{ .fregister = physical };
        return physical;
    }

    // -- the function ------------------------------------------------------

    fn emitFunction(self: *Emitter) error{OutOfMemory}!void {
        const function = self.function;
        try self.analyze();
        const slots = function.locals.len + function.instructions.len;
        self.frame_size = std.mem.alignForward(u64, 48 + @as(u64, slots) * 8, 16);
        self.epilogue = try self.newMark();
        self.propagate = try self.newMark();
        const block_marks = try self.arena.alloc(u32, function.blocks.len);
        for (block_marks) |*mark| mark.* = try self.newMark();
        self.block_marks = block_marks;
        self.pinned = try self.arena.alloc(?u4, function.locals.len);
        self.local_version = try self.arena.alloc(u32, function.locals.len);
        @memset(self.local_version, 0);
        var next_pinned: usize = 0;
        for (self.pinned, function.locals) |*slot, local| {
            // Only integer/bool/string/heap locals pin (no XMM is
            // callee-saved on this ABI, so floats never do).
            if (local.local_type != .float and next_pinned < pinned_pool.len) {
                slot.* = pinned_pool[next_pinned];
                next_pinned += 1;
            } else {
                slot.* = null;
            }
        }

        // Prologue: push rbp; mov rbp,rsp; sub rsp,frame; save the
        // callee-saved registers to fixed frame slots; State into r15.
        try self.byte(0x55); // push rbp
        try self.rex(true, 0, 0, 4);
        try self.byte(0x89);
        try self.byte(0xE5); // mov rbp, rsp
        try self.subRspImm(self.frame_size);
        try self.storeMem(3, 5, -8); // rbx
        try self.storeMem(12, 5, -16); // r12
        try self.storeMem(13, 5, -24); // r13
        try self.storeMem(14, 5, -32); // r14
        try self.storeMem(15, 5, -40); // r15
        try self.movReg(state, 7); // r15 = rdi (State arg0)

        // Depth budget: dec [State+depth]; trap if it went negative.
        const depth = try self.trapSite(.call_depth_exceeded, 0);
        try self.loadWord(helper, state, abi.depth_offset);
        // sub rax, 1
        try self.rex(true, 0, 0, helper);
        try self.byte(0x83);
        try self.byte(0xE8 | @as(u8, helper & 7));
        try self.byte(0x01);
        try self.storeWord(helper, state, abi.depth_offset);
        try self.branchCond(cc_l, depth); // signed < 0

        // Parameters: value args rsi,rdx,rcx,r8,r9; float args
        // xmm0-xmm7 — into pinned homes or slots before anything can
        // clobber the argument registers.
        const value_arg_regs = [_]u4{ 6, 2, 1, 8, 9 };
        var value_argument: usize = 0;
        var float_argument: u4 = 0;
        for (function.locals[0..function.parameter_count], 0..) |local, index| {
            if (local.local_type == .float) {
                const incoming = float_argument;
                float_argument += 1;
                try self.fstoreSlot(incoming, index);
            } else {
                const incoming = value_arg_regs[value_argument];
                value_argument += 1;
                if (self.pinned[index]) |physical| {
                    try self.movReg(physical, incoming);
                } else {
                    try self.storeSlot(incoming, index);
                }
            }
        }

        // The frame serial (r14): functions with bindings want a real
        // one from svc_serial; every other passes zero, exactly as MIR
        // emits.  Nothing is live in a caller-saved register yet.
        if (abi.wantsSerial(self.program, function)) {
            try self.movReg(7, state); // rdi = State
            try self.loadTable(call_target, abi.serviceOffset("svc_serial"));
            try self.callReg(call_target);
            try self.movReg(serial, 0); // r14 = rax
        } else {
            try self.materialize(serial, 0);
        }

        // Typed zeros for non-parameter locals (S40 late declarations).
        for (function.locals[function.parameter_count..], function.parameter_count..) |local, index| {
            const home = self.pinned[index];
            switch (local.local_type) {
                .float => {
                    try self.fzero(fhelper);
                    try self.fstoreSlot(fhelper, index);
                },
                .string => {
                    const offset = AddressTable.constant(self.program.constants.len);
                    if (home) |physical| {
                        try self.loadTable(physical, offset);
                    } else {
                        try self.loadTable(helper, offset);
                        try self.storeSlot(helper, index);
                    }
                },
                .heap => |heap_index| {
                    // Null: a zero view for viewable arrays, the null
                    // handle (0xFFFF_FFFF) for everything else.
                    const null_value: u64 = if (abi.viewableHeap(self.program, heap_index)) 0 else 0xFFFF_FFFF;
                    if (home) |physical| {
                        try self.materialize(physical, null_value);
                    } else {
                        try self.materialize(helper, null_value);
                        try self.storeSlot(helper, index);
                    }
                },
                .strukt => |layout| {
                    // A struct zero is built by the runtime (recursive,
                    // object fields start null); svc_zero_strukt returns
                    // the field-array pointer this engine uses.
                    try self.movReg(7, state);
                    try self.materialize(6, layout); // rsi = layout
                    try self.loadTable(call_target, abi.serviceOffset("svc_zero_strukt"));
                    try self.callReg(call_target);
                    if (home) |physical| {
                        try self.movReg(physical, 0);
                    } else {
                        try self.storeSlot(0, index);
                    }
                    try self.trapCheck();
                },
                else => {
                    if (home) |physical| {
                        try self.materialize(physical, 0);
                    } else {
                        try self.materialize(helper, 0);
                        try self.storeSlot(helper, index);
                    }
                },
            }
        }

        for (function.blocks, 0..) |block, index| {
            self.bind(self.block_marks[index]);
            self.current_block = @intCast(index);
            self.scratch_owner = @splat(null);
            self.float_owner = @splat(null);
            self.pending_compare = null;
            for (block.items, 0..) |item, at| {
                const following: ?ir.Register =
                    if (at + 1 < block.items.len) block.items[at + 1] else null;
                try self.emitInstruction(item, following);
                self.position += 1;
            }
        }

        // Trap stubs: record the triple, return the default.
        for (self.sites.items) |site| {
            self.bind(site.mark);
            try self.materialize(helper, @bitCast(abi.trap(site.code)));
            try self.storeWord(helper, state, abi.trap_offset);
            try self.materialize(helper, self.function_index);
            try self.storeWord(helper, state, abi.trap_function_offset);
            try self.materialize(helper, site.instruction);
            try self.storeWord(helper, state, abi.trap_instruction_offset);
            try self.branchTo(self.propagate);
        }
        self.bind(self.propagate);
        switch (function.return_type) {
            .none => {},
            .float => try self.fzero(0),
            else => try self.materialize(helper, 0),
        }
        try self.branchTo(self.epilogue);
        self.bind(self.epilogue);
        // Restore callee-saved, tear down the frame, return.
        try self.loadMem(3, 5, -8);
        try self.loadMem(12, 5, -16);
        try self.loadMem(13, 5, -24);
        try self.loadMem(14, 5, -32);
        try self.loadMem(15, 5, -40);
        try self.rex(true, 0, 0, 4);
        try self.byte(0x89);
        try self.byte(0xEC); // mov rsp, rbp
        try self.byte(0x5D); // pop rbp
        try self.byte(0xC3); // ret

        self.patch();
    }

    fn subRspImm(self: *Emitter, amount: u64) error{OutOfMemory}!void {
        // sub rsp, imm32.
        try self.rex(true, 0, 0, 4);
        try self.byte(0x81);
        try self.byte(0xEC); // /5, rm=rsp
        try self.imm32(@intCast(amount));
    }

    fn patch(self: *Emitter) void {
        for (self.fixups.items) |fixup| {
            const target = self.marks.items[fixup.mark].?;
            const next: i64 = @intCast(fixup.at + 4);
            const displacement: i32 = @intCast(@as(i64, @intCast(target)) - next);
            const slice = self.code.items[fixup.at..][0..4];
            std.mem.writeInt(i32, slice, displacement, .little);
        }
    }

    // -- instruction lowering ----------------------------------------------

    fn immediateOperand(self: *const Emitter, register: ir.Register) ?i64 {
        return switch (self.location[register]) {
            .immediate => |value| value,
            else => null,
        };
    }

    fn fitsImmediate(value: i64) bool {
        return value >= std.math.minInt(i32) and value <= std.math.maxInt(i32);
    }

    fn conditionOf(op: ir.BinaryOp) u4 {
        return switch (op) {
            .equal => cc_e,
            .not_equal => cc_ne,
            .less => cc_l,
            .less_equal => cc_le,
            .greater => cc_g,
            .greater_equal => cc_ge,
            else => unreachable,
        };
    }

    fn swappedCondition(condition: u4) u4 {
        return switch (condition) {
            cc_e, cc_ne => condition,
            cc_l => cc_g,
            cc_g => cc_l,
            cc_le => cc_ge,
            cc_ge => cc_le,
            else => unreachable,
        };
    }

    fn emitInstruction(self: *Emitter, item: ir.Register, following: ?ir.Register) error{OutOfMemory}!void {
        const function = self.function;
        switch (function.instructions[item]) {
            .const_int => |value| self.location[item] = .{ .immediate = value },
            .const_boolean => |value| self.location[item] = .{ .immediate = @intFromBool(value) },
            .const_float => |value| self.location[item] = .{ .table = self.table.floatOffset(value) },
            .const_data => |data| self.location[item] = .{ .table = AddressTable.constant(data.constant) },
            .local_get => |local| self.location[item] = .{
                .alias = .{ .local = local, .version = self.local_version[local] },
            },
            .local_set => |set| {
                try self.materializeAliases(set.local);
                const floaty = function.locals[set.local].local_type == .float;
                if (self.pinned[set.local]) |physical| {
                    try self.fetchInto(physical, set.value);
                } else if (floaty) {
                    try self.ffetchInto(fhelper, set.value);
                    try self.fstoreSlot(fhelper, set.local);
                } else {
                    try self.fetchInto(helper, set.value);
                    try self.storeSlot(helper, set.local);
                }
                self.local_version[set.local] += 1;
                self.freeDead(&.{set.value});
            },
            .jump => |target| if (target != self.current_block + 1) {
                try self.branchTo(self.block_marks[target]);
            },
            .branch => |branching| {
                const fallthrough_then = branching.then_block == self.current_block + 1;
                const fallthrough_else = branching.else_block == self.current_block + 1;
                if (self.pending_compare) |pending| {
                    if (pending.register == branching.condition) {
                        self.pending_compare = null;
                        if (fallthrough_then) {
                            try self.branchCond(invertCondition(pending.condition), self.block_marks[branching.else_block]);
                        } else {
                            try self.branchCond(pending.condition, self.block_marks[branching.then_block]);
                            if (!fallthrough_else) {
                                try self.branchTo(self.block_marks[branching.else_block]);
                            }
                        }
                        return;
                    }
                }
                const condition = try self.operandRegister(branching.condition, &.{});
                self.freeDead(&.{branching.condition});
                if (fallthrough_then) {
                    try self.branchZero(condition, self.block_marks[branching.else_block], true);
                } else {
                    try self.branchZero(condition, self.block_marks[branching.then_block], false);
                    if (!fallthrough_else) {
                        try self.branchTo(self.block_marks[branching.else_block]);
                    }
                }
            },
            .ret => |value| {
                // Return-value ownership first (S16): whatever the
                // frame still owned in the value goes loose for the
                // caller, marshaled through slot 0 the service reads.
                if (value) |register| {
                    if (abi.objectCarrying(self.program, function.return_type)) {
                        // Object-carrying returns are heap/struct, never
                        // float — the value word is a handle or a field
                        // pointer.
                        try self.fetchInto(helper2, register);
                        try self.storeWord(helper2, state, abi.slots_offset);
                        try self.spillForCall();
                        try self.movReg(7, state);
                        try self.materialize(6, self.function_index);
                        try self.movReg(2, serial);
                        try self.loadTable(call_target, abi.serviceOffset("svc_loosen"));
                        try self.callReg(call_target);
                        try self.restoreDepth();
                        // The (possibly loosened) return value back into rax.
                        try self.loadWord(0, state, abi.slots_offset);
                        try self.branchTo(self.epilogue);
                        return;
                    }
                }
                try self.restoreDepth();
                if (value) |register| {
                    if (self.isFloat(register)) {
                        try self.ffetchInto(0, register);
                    } else {
                        try self.fetchInto(0, register);
                    }
                    self.freeDead(&.{register});
                }
                try self.branchTo(self.epilogue);
            },
            .trap => |code| try self.branchTo(try self.trapSite(code, item)),
            .call => |call| try self.emitCall(item, call),
            .unary => |operation| try self.emitUnary(item, operation, following),
            .convert => |operation| try self.emitConvert(item, operation, following),
            .binary => |operation| try self.emitBinary(item, operation, following),
            .intrinsic => |call| try self.emitIntrinsic(item, call),
            .struct_make, .struct_get, .struct_set, .heap_new, .object_bind, .object_unbind => try self.emitGeneric(item),
            else => unreachable,
        }
    }

    fn invertCondition(condition: u4) u4 {
        return condition ^ 1;
    }

    /// A successful return restores the call-depth budget (a trap
    /// abandons it): add 1 to [State + depth].
    fn restoreDepth(self: *Emitter) error{OutOfMemory}!void {
        try self.loadWord(helper, state, abi.depth_offset);
        try self.rex(true, 0, 0, helper);
        try self.byte(0x83);
        try self.byte(0xC0 | @as(u8, helper & 7)); // add rax, imm8
        try self.byte(0x01);
        try self.storeWord(helper, state, abi.depth_offset);
    }

    fn emitUnary(self: *Emitter, item: ir.Register, operation: anytype, following: ?ir.Register) error{OutOfMemory}!void {
        _ = following;
        if (self.typeOf(item) == .float and operation.op == .negate) {
            // Flip the sign bit: xor with the -0.0 mask is simplest as
            // 0.0 - operand via subsd.  fzero result then subsd op.
            const operand = try self.operandFloat(operation.operand, &.{});
            const dest = try self.destFloat(item, &.{operation.operand}, &.{operand});
            if (dest != operand) {
                try self.fzero(dest);
                try self.fsub(dest, operand);
            } else {
                // dest aliases operand: 0 - dest needs a temp.
                try self.fzero(fhelper);
                try self.fsub(fhelper, operand);
                try self.fmovRegs(dest, fhelper);
            }
            self.freeDead(&.{operation.operand});
            return;
        }
        const operand = try self.operandRegister(operation.operand, &.{});
        switch (operation.op) {
            .negate => {
                const overflow = try self.trapSite(.integer_overflow, item);
                const dest = try self.destRegister(item, &.{operation.operand}, &.{operand});
                try self.movReg(dest, operand);
                // neg dest (F7 /3); sets OF only for INT64_MIN.
                try self.rex(true, 0, 0, dest);
                try self.byte(0xF7);
                try self.byte(0xD8 | @as(u8, dest & 7));
                try self.branchCond(cc_o, overflow);
            },
            .logic_not => {
                try self.compareImmediate(operand, 0);
                const dest = try self.destRegister(item, &.{operation.operand}, &.{operand});
                try self.setCond(dest, cc_e);
            },
        }
        self.freeDead(&.{operation.operand});
    }

    fn emitConvert(self: *Emitter, item: ir.Register, operation: anytype, following: ?ir.Register) error{OutOfMemory}!void {
        _ = following;
        switch (operation.kind) {
            .int_to_float => {
                const operand = try self.operandRegister(operation.operand, &.{});
                const dest = try self.destFloat(item, &.{}, &.{});
                // cvtsi2sd xmm(dest), r/m64(operand).
                try self.byte(0xF2);
                try self.rex(true, dest, 0, operand);
                try self.byte(0x0F);
                try self.byte(0x2A);
                try self.modrmReg(dest, operand);
                self.freeDead(&.{operation.operand});
            },
            .float_to_int => {
                const range = try self.trapSite(.conversion_range, item);
                const operand = try self.operandFloat(operation.operand, &.{});
                // NaN: ucomisd operand,operand sets PF -> jp range.
                try self.ucomisd(operand, operand);
                try self.branchCond(0xA, range); // jp
                // below -2^63: operand < min -> ucomisd(min, operand)
                // gives min>operand? use operand < min via ucomisd
                // operand,min and jb.
                try self.floadTable(fhelper, self.table.floatOffset(-9223372036854775808.0));
                try self.ucomisd(operand, fhelper);
                try self.branchCond(0x2, range); // jb (operand < min)
                // at/above 2^63: operand >= 2^63 -> ucomisd operand,lim
                // and jae.
                try self.floadTable(fhelper, self.table.floatOffset(9223372036854775808.0));
                try self.ucomisd(operand, fhelper);
                try self.branchCond(cc_ae, range);
                const dest = try self.destRegister(item, &.{}, &.{});
                // cvttsd2si r64(dest), xmm(operand).
                try self.byte(0xF2);
                try self.rex(true, dest, 0, operand);
                try self.byte(0x0F);
                try self.byte(0x2C);
                try self.modrmReg(dest, operand);
                self.freeDead(&.{operation.operand});
            },
        }
    }

    fn ucomisd(self: *Emitter, a: u4, b: u4) error{OutOfMemory}!void {
        try self.byte(0x66);
        if (a >= 8 or b >= 8) try self.rex(false, a, 0, b);
        try self.byte(0x0F);
        try self.byte(0x2E); // ucomisd a, b
        try self.modrmReg(a, b);
    }

    fn fsub(self: *Emitter, dst: u4, src: u4) error{OutOfMemory}!void {
        try self.fop(0x5C, dst, src);
    }

    fn fop(self: *Emitter, opcode: u8, dst: u4, src: u4) error{OutOfMemory}!void {
        try self.byte(0xF2);
        if (dst >= 8 or src >= 8) try self.rex(false, dst, 0, src);
        try self.byte(0x0F);
        try self.byte(opcode);
        try self.modrmReg(dst, src);
    }

    fn emitBinary(self: *Emitter, item: ir.Register, operation: anytype, following: ?ir.Register) error{OutOfMemory}!void {
        if (operation.operand_type == .float) return self.emitFloatBinary(item, operation, following);
        // String concatenation and comparison, and struct equality,
        // live in the reference implementation — the generic service
        // (String + has a dedicated fast service added in the next
        // pass; correctness lives here first).  Heap/bool/int compare
        // as words below.
        switch (operation.operand_type) {
            .string, .strukt => return self.emitGeneric(item),
            else => {},
        }
        if (operation.op.isComparison()) {
            var condition = conditionOf(operation.op);
            if (self.immediateOperand(operation.right)) |value| {
                if (fitsImmediate(value)) {
                    const left = try self.operandRegister(operation.left, &.{});
                    try self.compareImmediate(left, value);
                    self.freeDead(&.{ operation.left, operation.right });
                    return self.finishComparison(item, condition, following);
                }
            }
            if (self.immediateOperand(operation.left)) |value| {
                if (fitsImmediate(value)) {
                    const right = try self.operandRegister(operation.right, &.{});
                    try self.compareImmediate(right, value);
                    condition = swappedCondition(condition);
                    self.freeDead(&.{ operation.left, operation.right });
                    return self.finishComparison(item, condition, following);
                }
            }
            const left = try self.operandRegister(operation.left, &.{});
            const right = try self.operandRegister(operation.right, &.{left});
            try self.compareRegisters(left, right);
            self.freeDead(&.{ operation.left, operation.right });
            return self.finishComparison(item, condition, following);
        }
        switch (operation.op) {
            .add, .subtract => {
                const overflow = try self.trapSite(.integer_overflow, item);
                const left = try self.operandRegister(operation.left, &.{});
                const right = try self.operandRegister(operation.right, &.{left});
                // The two-operand sequence is `mov dest, left; op dest,
                // right`, so dest may reuse `left` (the mov is then a
                // no-op) but never `right` — moving left in would clobber
                // right before the op reads it.  Only `left` is offered
                // for reuse; a fresh dest still avoids both source regs.
                const dest = try self.destRegister(item, &.{operation.left}, &.{ left, right });
                try self.movReg(dest, left);
                try self.alu(if (operation.op == .add) 0x01 else 0x29, dest, right);
                try self.branchCond(cc_o, overflow);
                self.freeDead(&.{ operation.left, operation.right });
            },
            .multiply => {
                const overflow = try self.trapSite(.integer_overflow, item);
                const left = try self.operandRegister(operation.left, &.{});
                const right = try self.operandRegister(operation.right, &.{left});
                // dest may reuse only `left`, as for add/subtract above.
                const dest = try self.destRegister(item, &.{operation.left}, &.{ left, right });
                try self.movReg(dest, left);
                // imul dest, right (0F AF /r); sets OF on signed overflow.
                try self.rex(true, dest, 0, right);
                try self.byte(0x0F);
                try self.byte(0xAF);
                try self.modrmReg(dest, right);
                try self.branchCond(cc_o, overflow);
                self.freeDead(&.{ operation.left, operation.right });
            },
            .divide, .remainder => try self.emitDivide(item, operation, following),
            else => unreachable,
        }
    }

    fn emitDivide(self: *Emitter, item: ir.Register, operation: anytype, following: ?ir.Register) error{OutOfMemory}!void {
        _ = following;
        const divisor_constant = self.immediateOperand(operation.right);
        const dividend_constant = self.immediateOperand(operation.left);
        const left = try self.operandRegister(operation.left, &.{});
        const right = try self.operandRegister(operation.right, &.{left});
        if (divisor_constant) |value| {
            if (value == 0) try self.branchTo(try self.trapSite(.divide_by_zero, item));
        } else {
            try self.branchZero(right, try self.trapSite(.divide_by_zero, item), true);
        }
        const divisor_may_be_minus_one = divisor_constant == null or divisor_constant.? == -1;
        const dividend_may_be_minimum =
            dividend_constant == null or dividend_constant.? == std.math.minInt(i64);
        if (divisor_may_be_minus_one and dividend_may_be_minimum) {
            const overflow = try self.trapSite(.integer_overflow, item);
            const fine = try self.newMark();
            if (divisor_constant == null) {
                try self.compareImmediate(right, -1);
                try self.branchCond(cc_ne, fine);
            }
            try self.materialize(helper2, @bitCast(@as(i64, std.math.minInt(i64))));
            try self.compareRegisters(left, helper2);
            try self.branchCond(cc_e, overflow);
            self.bind(fine);
        }
        // idiv uses rdx:rax; get the dividend into rax, sign-extend
        // into rdx (cqo), then idiv the divisor.  right must not be
        // rax/rdx — it never is (the pool is r10/r11, pinned rbx/r12).
        try self.movReg(helper, left); // rax = left
        try self.byte(0x48);
        try self.byte(0x99); // cqo (sign-extend rax into rdx)
        // idiv right (F7 /7).
        try self.rex(true, 0, 0, right);
        try self.byte(0xF7);
        try self.byte(0xF8 | @as(u8, right & 7));
        const dest = try self.destRegister(item, &.{ operation.left, operation.right }, &.{ left, right });
        // Quotient in rax, remainder in rdx.
        try self.movReg(dest, if (operation.op == .divide) helper else helper2);
        self.freeDead(&.{ operation.left, operation.right });
    }

    fn emitFloatBinary(self: *Emitter, item: ir.Register, operation: anytype, following: ?ir.Register) error{OutOfMemory}!void {
        _ = following;
        if (operation.op.isComparison()) {
            try self.emitFloatCompare(item, operation);
            return;
        }
        if (operation.op == .remainder) return self.emitGeneric(item);
        const left = try self.operandFloat(operation.left, &.{});
        const right = try self.operandFloat(operation.right, &.{left});
        const dest = try self.destFloat(item, &.{ operation.left, operation.right }, &.{ left, right });
        // Two-operand SSE; move left into dest first when needed.
        if (dest != left) {
            if (dest == right) {
                // subsd/divsd are not commutative and dest==right: use
                // fhelper to preserve left.
                try self.fmovRegs(fhelper, left);
                try self.fop(floatOpcode(operation.op), fhelper, right);
                try self.fmovRegs(dest, fhelper);
                self.freeDead(&.{ operation.left, operation.right });
                return;
            }
            try self.fmovRegs(dest, left);
        }
        try self.fop(floatOpcode(operation.op), dest, right);
        self.freeDead(&.{ operation.left, operation.right });
    }

    fn floatOpcode(op: ir.BinaryOp) u8 {
        return switch (op) {
            .add => 0x58,
            .subtract => 0x5C,
            .multiply => 0x59,
            .divide => 0x5E,
            else => unreachable,
        };
    }

    /// Float comparisons never fuse into branches (ucomisd sets
    /// unsigned flags and NaN needs PF), so each materializes a clean
    /// boolean matching IEEE (NaN false for all but !=).
    fn emitFloatCompare(self: *Emitter, item: ir.Register, operation: anytype) error{OutOfMemory}!void {
        const left = try self.operandFloat(operation.left, &.{});
        const right = try self.operandFloat(operation.right, &.{left});
        const dest = try self.destRegister(item, &.{}, &.{});
        switch (operation.op) {
            .greater => {
                try self.ucomisd(left, right);
                try self.setCond(dest, cc_a);
            },
            .greater_equal => {
                try self.ucomisd(left, right);
                try self.setCond(dest, cc_ae);
            },
            .less => {
                try self.ucomisd(right, left);
                try self.setCond(dest, cc_a);
            },
            .less_equal => {
                try self.ucomisd(right, left);
                try self.setCond(dest, cc_ae);
            },
            .equal => {
                // ZF=1 and not unordered: sete dest; setnp helper2b;
                // and dest, helper2.
                try self.ucomisd(left, right);
                try self.setCond(dest, cc_e);
                try self.setCond(helper2, 0xB); // setnp
                try self.alu(0x21, dest, helper2); // and dest, helper2
            },
            .not_equal => {
                try self.ucomisd(left, right);
                try self.setCond(dest, cc_ne);
                try self.setCond(helper2, 0xA); // setp
                try self.alu(0x09, dest, helper2); // or dest, helper2
            },
            else => unreachable,
        }
        self.freeDead(&.{ operation.left, operation.right });
    }

    fn finishComparison(self: *Emitter, item: ir.Register, condition: u4, following: ?ir.Register) error{OutOfMemory}!void {
        if (following) |next| {
            if (self.use_count[item] == 1) {
                switch (self.function.instructions[next]) {
                    .branch => |branching| if (branching.condition == item) {
                        self.pending_compare = .{ .register = item, .condition = condition };
                        return;
                    },
                    else => {},
                }
            }
        }
        const dest = try self.destRegister(item, &.{}, &.{});
        try self.setCond(dest, condition);
    }

    // -- calls and services ------------------------------------------------

    fn emitCall(self: *Emitter, item: ir.Register, call: anytype) error{OutOfMemory}!void {
        const callee = &self.program.functions[call.function];
        // Spill the pool to slots first, then load args from their now
        // stable locations (slot / immediate / table / pinned) into
        // the ABI registers.  Fetch reads never touch the pool or the
        // arg registers' sources, so this order is safe.
        try self.spillForCall();
        const value_arg_regs = [_]u4{ 6, 2, 1, 8, 9 };
        var value_argument: usize = 0;
        var float_argument: u4 = 0;
        for (call.arguments, 0..) |argument, index| {
            if (callee.locals[index].local_type == .float) {
                try self.ffetchInto(float_argument, argument);
                float_argument += 1;
            } else {
                try self.fetchInto(value_arg_regs[value_argument], argument);
                value_argument += 1;
            }
        }
        self.freeDead(call.arguments);
        try self.movReg(7, state); // rdi = State
        try self.loadTable(call_target, self.table.function(call.function));
        try self.callReg(call_target);
        if (callee.return_type != .none) {
            if (callee.return_type == .float) {
                const dest = try self.destFloat(item, &.{}, &.{});
                try self.fmovRegs(dest, 0);
            } else {
                const dest = try self.destRegister(item, &.{}, &.{});
                try self.movReg(dest, 0); // rax
            }
        }
        try self.trapCheck();
    }

    /// The generic service protocol: operands into the State's
    /// marshaling slots, then svc_instr_{i,d,v}(state, function,
    /// instruction, serial).  The scalar core reaches it only for
    /// str(non-string)/print/trap.
    fn emitGeneric(self: *Emitter, item: ir.Register) error{OutOfMemory}!void {
        var buffer: [2]ir.Register = undefined;
        const operands = operandsOf(&self.function.instructions[item], &buffer);
        for (operands, 0..) |operand, slot| {
            const offset = abi.slots_offset + 8 * @as(u64, slot);
            if (self.isFloat(operand)) {
                try self.ffetchInto(fhelper, operand);
                try self.fstoreWord(fhelper, state, offset);
            } else {
                try self.fetchInto(helper, operand);
                try self.storeWord(helper, state, offset);
            }
        }
        self.freeDead(operands);
        try self.spillForCall();
        // Args: rdi=state, rsi=function, rdx=instruction, rcx=serial.
        try self.movReg(7, state);
        try self.materialize(6, self.function_index);
        try self.materialize(2, item);
        try self.movReg(1, serial);
        switch (self.typeOf(item)) {
            .none => {
                try self.loadTable(call_target, abi.serviceOffset("svc_instr_v"));
                try self.callReg(call_target);
            },
            .float => {
                try self.loadTable(call_target, abi.serviceOffset("svc_instr_d"));
                try self.callReg(call_target);
                const dest = try self.destFloat(item, &.{}, &.{});
                try self.fmovRegs(dest, 0);
            },
            else => {
                try self.loadTable(call_target, abi.serviceOffset("svc_instr_i"));
                try self.callReg(call_target);
                const dest = try self.destRegister(item, &.{}, &.{});
                try self.movReg(dest, 0);
            },
        }
        try self.trapCheck();
    }

    fn emitIntrinsic(self: *Emitter, item: ir.Register, call: ir.Instruction.IntrinsicCall) error{OutOfMemory}!void {
        switch (call.kind) {
            .assert_true => {
                const failed = try self.trapSite(.assertion_failed, item);
                const condition = try self.operandRegister(call.arguments[0], &.{});
                self.freeDead(&.{call.arguments[0]});
                try self.branchZero(condition, failed, true);
            },
            .str_value => {
                // str on a String is a move; every other value goes
                // through the generic marshaling service.
                if (self.typeOf(call.arguments[0]) == .string) {
                    const source = try self.operandRegister(call.arguments[0], &.{});
                    const dest = try self.destRegister(item, &.{call.arguments[0]}, &.{source});
                    try self.movReg(dest, source);
                    self.freeDead(&.{call.arguments[0]});
                } else {
                    try self.emitGeneric(item);
                }
            },
            // Everything else — collections, string manipulation,
            // conversions, host builtins — runs through the generic
            // marshaling service, which reconstructs the instruction
            // and runs the interpreter's own implementation.  The
            // fast-service and inline-access optimizations layer on
            // top of this in the next pass; the generic path is the
            // correctness floor.
            else => try self.emitGeneric(item),
        }
    }
};
