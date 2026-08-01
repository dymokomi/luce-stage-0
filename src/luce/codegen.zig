//! The self-written backend — Luce IR emitted straight to machine
//! code, no MIR, no C (docs/SPEED.md §16).
//!
//! This is the sovereignty engine growing behind the same seam as
//! the others: it emits against `native.abi` (the State word offsets
//! and the address table), produces the same hermetic spans as the
//! MIR engine — no host address in the bytes, every call target and
//! constant read from the table — and runs through the same
//! `image.map` + `native.runCode` machinery, under the same oracle.
//! MIR remains the racing baseline; a program this backend cannot
//! compile simply is not `supported()` and takes the usual path.
//!
//! M0 scope, deliberately narrow (the bring-up pattern that served
//! the MIR engine's own milestone 1): one aarch64 target
//! (macOS/Linux — the encoder is OS-blind, `image.map` does the OS
//! work), a single-function program, Int/Bool/String values in
//! registers, Int arithmetic with the full trap semantics, control
//! flow, and four intrinsics (`print`, `str` of Int, `assert`,
//! `trap`).  Opt-in via LOOM_ENGINE=zig.  x86-64 is the next
//! target; Windows follows once image.zig grows VirtualAlloc.
//!
//! Code shape: every value slot (locals first, then IR registers)
//! lives in the stack frame — correctness first, register allocation
//! is the next milestone.  x19 holds the State; scratch is x9-x16.
//! The trap protocol, depth budget, and service call marshaling
//! mirror the MIR lowering exactly, and native_spec holds both
//! engines to identical behavior.

const std = @import("std");
const builtin = @import("builtin");
const ir = @import("ir.zig");
const types = @import("types.zig");
const native = @import("native.zig");
const image = @import("image.zig");

const Allocator = std.mem.Allocator;
const abi = native.abi;

pub const available = builtin.cpu.arch == .aarch64 and image.supported;

/// Frame slots are addressed with a scaled 12-bit immediate.
const max_slots = 4000;

/// Whether the whole program fits this backend's M0 core.  One
/// function (post-prune scripts with no calls), value types
/// Int/Bool/String, integer arithmetic, control flow, and the four
/// supported intrinsics.
pub fn supported(program: *const ir.Program) bool {
    if (!available) return false;
    if (program.functions.len != 1) return false;
    const function = &program.functions[0];
    if (function.parameter_count != 0) return false;
    if (function.return_type != .none) return false;
    if (function.locals.len + function.instructions.len > max_slots) return false;
    for (function.locals) |local| {
        if (!valueShaped(local.local_type)) return false;
    }
    for (function.result_types) |result| {
        if (result != .none and !valueShaped(result)) return false;
    }
    for (function.instructions) |instruction| {
        switch (instruction) {
            .const_boolean, .const_int, .const_data => {},
            .local_get, .local_set => {},
            .jump, .branch, .trap => {},
            .ret => |value| if (value != null) return false,
            .unary => {},
            .binary => |operation| if (operation.operand_type != .int) return false,
            .intrinsic => |call| switch (call.kind) {
                .assert_true, .trap_message, .print => {},
                .str_value => switch (function.result_types[call.arguments[0]]) {
                    .int, .boolean, .string => {},
                    else => return false,
                },
                else => return false,
            },
            else => return false,
        }
    }
    return true;
}

fn valueShaped(of: types.Type) bool {
    return switch (of) {
        .int, .boolean, .string => true,
        else => false,
    };
}

/// Compile the program to one hermetic span per function (M0:
/// exactly one).  Callers map the spans executable (image.map) and
/// run them with native.runCode — the same path a cached image
/// takes.  Assumes supported() said yes.
pub fn compile(arena: Allocator, program: *const ir.Program) error{OutOfMemory}![]const []const u8 {
    var emitter: Emitter = .{
        .arena = arena,
        .program = program,
        .function = &program.functions[0],
    };
    try emitter.emitFunction();
    const spans = try arena.alloc([]const u8, 1);
    spans[0] = emitter.code.items;
    return spans;
}

// ---------------------------------------------------------------------------
// The emitter
// ---------------------------------------------------------------------------

/// A pending branch to a mark not yet bound.
const Fixup = struct {
    at: usize,
    mark: u32,
    kind: enum { jump26, cond19 },
};

/// One trap exit: sets the trap triple in the State, returns default.
const TrapSite = struct {
    mark: u32,
    code: ir.TrapCode,
    instruction: u32,
};

const Emitter = struct {
    arena: Allocator,
    program: *const ir.Program,
    function: *const ir.Function,
    code: std.ArrayList(u8) = .empty,
    marks: std.ArrayList(?usize) = .empty,
    fixups: std.ArrayList(Fixup) = .empty,
    sites: std.ArrayList(TrapSite) = .empty,
    block_marks: []u32 = &.{},
    epilogue: u32 = 0,
    propagate: u32 = 0,
    frame_size: u64 = 0,

    // -- aarch64 conditions ------------------------------------------------

    const eq: u4 = 0x0;
    const ne: u4 = 0x1;
    const vs: u4 = 0x6;
    const ge: u4 = 0xA;
    const lt: u4 = 0xB;
    const gt: u4 = 0xC;
    const le: u4 = 0xD;

    // Registers: x19 = State, x9-x12 scratch values, x16 call target.
    const state: u5 = 19;
    const zr: u5 = 31;

    fn word(self: *Emitter, encoded: u32) error{OutOfMemory}!void {
        try self.code.appendSlice(self.arena, &std.mem.toBytes(std.mem.nativeToLittle(u32, encoded)));
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

    // -- encodings ---------------------------------------------------------

    fn movz(self: *Emitter, rd: u5, chunk: u16, half: u2) !void {
        try self.word(0xD2800000 | @as(u32, half) << 21 | @as(u32, chunk) << 5 | rd);
    }

    fn movk(self: *Emitter, rd: u5, chunk: u16, half: u2) !void {
        try self.word(0xF2800000 | @as(u32, half) << 21 | @as(u32, chunk) << 5 | rd);
    }

    /// Any 64-bit value: movz of the low half-word, movk of each
    /// non-zero higher one.
    fn materialize(self: *Emitter, rd: u5, value: u64) !void {
        try self.movz(rd, @truncate(value), 0);
        inline for (1..4) |half| {
            const chunk: u16 = @truncate(value >> (16 * half));
            if (chunk != 0) try self.movk(rd, chunk, half);
        }
    }

    fn movReg(self: *Emitter, rd: u5, rm: u5) !void {
        try self.word(0xAA0003E0 | @as(u32, rm) << 16 | rd);
    }

    /// ldr rt, [rn, #slot * 8] — the frame and the State words.
    fn loadWord(self: *Emitter, rt: u5, rn: u5, byte_offset: u64) !void {
        const scaled: u12 = @intCast(byte_offset / 8);
        try self.word(0xF9400000 | @as(u32, scaled) << 10 | @as(u32, rn) << 5 | rt);
    }

    fn storeWord(self: *Emitter, rt: u5, rn: u5, byte_offset: u64) !void {
        const scaled: u12 = @intCast(byte_offset / 8);
        try self.word(0xF9000000 | @as(u32, scaled) << 10 | @as(u32, rn) << 5 | rt);
    }

    /// ldr rt, [state, offset] for table offsets past the immediate
    /// range: materialize the offset, then a register-offset load.
    fn loadTable(self: *Emitter, rt: u5, offset: u64) !void {
        try self.materialize(9, offset);
        try self.word(0xF8606800 | @as(u32, 9) << 16 | @as(u32, state) << 5 | rt);
    }

    fn loadSlot(self: *Emitter, rt: u5, slot: usize) !void {
        try self.loadWord(rt, 31, @as(u64, slot) * 8);
    }

    fn storeSlot(self: *Emitter, rt: u5, slot: usize) !void {
        try self.storeWord(rt, 31, @as(u64, slot) * 8);
    }

    fn addImmediate(self: *Emitter, rd: u5, rn: u5, immediate: u12) !void {
        try self.word(0x91000000 | @as(u32, immediate) << 10 | @as(u32, rn) << 5 | rd);
    }

    fn subImmediate(self: *Emitter, rd: u5, rn: u5, immediate: u12) !void {
        try self.word(0xD1000000 | @as(u32, immediate) << 10 | @as(u32, rn) << 5 | rd);
    }

    fn branchTo(self: *Emitter, mark: u32) !void {
        try self.fixups.append(self.arena, .{ .at = self.here(), .mark = mark, .kind = .jump26 });
        try self.word(0x14000000);
    }

    fn branchCond(self: *Emitter, condition: u4, mark: u32) !void {
        try self.fixups.append(self.arena, .{ .at = self.here(), .mark = mark, .kind = .cond19 });
        try self.word(0x54000000 | @as(u32, condition));
    }

    fn branchZero(self: *Emitter, rt: u5, mark: u32, when_zero: bool) !void {
        try self.fixups.append(self.arena, .{ .at = self.here(), .mark = mark, .kind = .cond19 });
        try self.word((if (when_zero) @as(u32, 0xB4000000) else 0xB5000000) | rt);
    }

    fn compareRegisters(self: *Emitter, rn: u5, rm: u5) !void {
        try self.word(0xEB00001F | @as(u32, rm) << 16 | @as(u32, rn) << 5);
    }

    fn setCond(self: *Emitter, rd: u5, condition: u4) !void {
        try self.word(0x9A9F07E0 | @as(u32, condition ^ 1) << 12 | rd);
    }

    fn callRegister(self: *Emitter, rn: u5) !void {
        try self.word(0xD63F0000 | @as(u32, rn) << 5);
    }

    // -- the trap protocol -------------------------------------------------

    fn trapSite(self: *Emitter, code: ir.TrapCode, instruction: u32) error{OutOfMemory}!u32 {
        const mark = try self.newMark();
        try self.sites.append(self.arena, .{ .mark = mark, .code = code, .instruction = instruction });
        return mark;
    }

    /// After a service call: any recorded trap propagates.
    fn trapCheck(self: *Emitter) !void {
        try self.loadWord(9, state, abi.trap_offset);
        try self.branchZero(9, self.propagate, false);
    }

    // -- the function ------------------------------------------------------

    fn emitFunction(self: *Emitter) error{OutOfMemory}!void {
        const function = self.function;
        const slots = function.locals.len + function.instructions.len;
        self.frame_size = std.mem.alignForward(u64, @as(u64, slots) * 8, 16);
        self.epilogue = try self.newMark();
        self.propagate = try self.newMark();
        const block_marks = try self.arena.alloc(u32, function.blocks.len);
        for (block_marks) |*mark| mark.* = try self.newMark();
        self.block_marks = block_marks;

        // Prologue: saves, frame, the State register, the depth
        // budget (the same subtract-store-check the MIR lowering
        // emits), typed zeros for the locals.
        try self.word(0xA9BF7BFD); // stp x29, x30, [sp, #-16]!
        try self.word(0xA9BF53F3); // stp x19, x20, [sp, #-16]!
        if (self.frame_size <= 4095) {
            try self.subImmediate(31, 31, @intCast(self.frame_size));
        } else {
            try self.materialize(9, self.frame_size);
            try self.word(0xCB2963FF); // sub sp, sp, x9 (extended)
        }
        try self.movReg(state, 0);
        const depth = try self.trapSite(.call_depth_exceeded, 0);
        try self.loadWord(9, state, abi.depth_offset);
        try self.word(0xF1000529); // subs x9, x9, #1
        try self.storeWord(9, state, abi.depth_offset);
        try self.branchCond(lt, depth);
        for (function.locals, 0..) |local, slot| {
            switch (local.local_type) {
                .int, .boolean => try self.storeSlot(zr, slot),
                .string => {
                    // The "" descriptor, like every constant, comes
                    // from the table.
                    try self.loadTable(9, abi.constantOffset(self.program.constants.len));
                    try self.storeSlot(9, slot);
                },
                else => unreachable, // supported() refused the rest
            }
        }

        for (function.blocks, 0..) |block, index| {
            self.bind(self.block_marks[index]);
            for (block.items) |item| try self.emitInstruction(item);
        }

        // Trap stubs: record the triple, return the default.
        for (self.sites.items) |site| {
            self.bind(site.mark);
            try self.materialize(9, @bitCast(abi.trap(site.code)));
            try self.storeWord(9, state, abi.trap_offset);
            try self.materialize(9, 0); // function index — M0 has one
            try self.storeWord(9, state, abi.trap_function_offset);
            try self.materialize(9, site.instruction);
            try self.storeWord(9, state, abi.trap_instruction_offset);
            try self.branchTo(self.propagate);
        }
        self.bind(self.propagate);
        // main returns nothing; a trap abandons the depth budget.
        try self.branchTo(self.epilogue);
        self.bind(self.epilogue);
        if (self.frame_size <= 4095) {
            try self.addImmediate(31, 31, @intCast(self.frame_size));
        } else {
            try self.materialize(9, self.frame_size);
            try self.word(0x8B2963FF); // add sp, sp, x9 (extended)
        }
        try self.word(0xA8C153F3); // ldp x19, x20, [sp], #16
        try self.word(0xA8C17BFD); // ldp x29, x30, [sp], #16
        try self.word(0xD65F03C0); // ret

        self.patch();
    }

    fn patch(self: *Emitter) void {
        for (self.fixups.items) |fixup| {
            const target = self.marks.items[fixup.mark].?;
            const displacement: i64 = @intCast(@as(i64, @intCast(target)) - @as(i64, @intCast(fixup.at)));
            const instructions: i64 = @divExact(displacement, 4);
            const bytes = self.code.items[fixup.at..][0..4];
            var encoded = std.mem.readInt(u32, bytes, .little);
            switch (fixup.kind) {
                .jump26 => encoded |= @as(u32, @intCast(instructions & 0x3FFFFFF)),
                .cond19 => encoded |= @as(u32, @intCast(instructions & 0x7FFFF)) << 5,
            }
            std.mem.writeInt(u32, bytes, encoded, .little);
        }
    }

    fn slotOf(self: *const Emitter, register: ir.Register) usize {
        return self.function.locals.len + register;
    }

    fn emitInstruction(self: *Emitter, item: ir.Register) error{OutOfMemory}!void {
        const function = self.function;
        switch (function.instructions[item]) {
            .const_int => |value| {
                try self.materialize(9, @bitCast(value));
                try self.storeSlot(9, self.slotOf(item));
            },
            .const_boolean => |value| {
                try self.materialize(9, @intFromBool(value));
                try self.storeSlot(9, self.slotOf(item));
            },
            .const_data => |data| {
                try self.loadTable(9, abi.constantOffset(data.constant));
                try self.storeSlot(9, self.slotOf(item));
            },
            .local_get => |local| {
                try self.loadSlot(9, local);
                try self.storeSlot(9, self.slotOf(item));
            },
            .local_set => |set| {
                try self.loadSlot(9, self.slotOf(set.value));
                try self.storeSlot(9, set.local);
            },
            .jump => |target| try self.branchTo(self.block_marks[target]),
            .branch => |branching| {
                try self.loadSlot(9, self.slotOf(branching.condition));
                try self.branchZero(9, self.block_marks[branching.then_block], false);
                try self.branchTo(self.block_marks[branching.else_block]);
            },
            .ret => {
                // Success restores the depth budget; traps do not.
                try self.loadWord(9, state, abi.depth_offset);
                try self.addImmediate(9, 9, 1);
                try self.storeWord(9, state, abi.depth_offset);
                try self.branchTo(self.epilogue);
            },
            .trap => |code| try self.branchTo(try self.trapSite(code, item)),
            .unary => |operation| {
                try self.loadSlot(9, self.slotOf(operation.operand));
                switch (operation.op) {
                    .negate => {
                        const overflow = try self.trapSite(.integer_overflow, item);
                        try self.word(0xEB0903EB); // subs x11, xzr, x9
                        try self.branchCond(vs, overflow);
                    },
                    .logic_not => {
                        try self.word(0xF100013F); // cmp x9, #0
                        try self.setCond(11, eq);
                    },
                }
                try self.storeSlot(11, self.slotOf(item));
            },
            .binary => |operation| try self.emitBinary(item, operation),
            .intrinsic => |call| try self.emitIntrinsic(item, call),
            else => unreachable, // supported() refused everything else
        }
    }

    fn emitBinary(self: *Emitter, item: ir.Register, operation: anytype) error{OutOfMemory}!void {
        try self.loadSlot(9, self.slotOf(operation.left));
        try self.loadSlot(10, self.slotOf(operation.right));
        if (operation.op.isComparison()) {
            try self.compareRegisters(9, 10);
            try self.setCond(11, switch (operation.op) {
                .equal => eq,
                .not_equal => ne,
                .less => lt,
                .less_equal => le,
                .greater => gt,
                .greater_equal => ge,
                else => unreachable,
            });
            try self.storeSlot(11, self.slotOf(item));
            return;
        }
        switch (operation.op) {
            .add, .subtract => {
                const overflow = try self.trapSite(.integer_overflow, item);
                const base: u32 = if (operation.op == .add) 0xAB000000 else 0xEB000000;
                try self.word(base | @as(u32, 10) << 16 | @as(u32, 9) << 5 | 11);
                try self.branchCond(vs, overflow);
            },
            .multiply => {
                const overflow = try self.trapSite(.integer_overflow, item);
                try self.word(0x9B0A7D2B); // mul x11, x9, x10
                try self.word(0x9B4A7D2C); // smulh x12, x9, x10
                // Overflow unless the high word is the sign
                // extension of the low: cmp x12, x11, asr #63.
                try self.word(0xEB8BFD9F);
                try self.branchCond(ne, overflow);
            },
            .divide, .remainder => {
                // The MIR lowering's exact guards: zero traps, MIN/-1
                // traps, everything else divides.
                const zero = try self.trapSite(.divide_by_zero, item);
                const overflow = try self.trapSite(.integer_overflow, item);
                const fine = try self.newMark();
                try self.branchZero(10, zero, true);
                try self.word(0xB100055F); // cmn x10, #1
                try self.branchCond(ne, fine);
                try self.movz(12, 0x8000, 3); // x12 = i64 minimum
                try self.compareRegisters(9, 12);
                try self.branchCond(eq, overflow);
                self.bind(fine);
                if (operation.op == .divide) {
                    try self.word(0x9ACA0D2B); // sdiv x11, x9, x10
                } else {
                    try self.word(0x9ACA0D2C); // sdiv x12, x9, x10
                    try self.word(0x9B0AA58B); // msub x11, x12, x10, x9
                }
            },
            else => unreachable,
        }
        try self.storeSlot(11, self.slotOf(item));
    }

    fn emitIntrinsic(self: *Emitter, item: ir.Register, call: ir.Instruction.IntrinsicCall) error{OutOfMemory}!void {
        switch (call.kind) {
            .assert_true => {
                const failed = try self.trapSite(.assertion_failed, item);
                try self.loadSlot(9, self.slotOf(call.arguments[0]));
                try self.branchZero(9, failed, true);
            },
            .str_value => switch (self.function.result_types[call.arguments[0]]) {
                // str on a String is a move, exactly as MIR lowers it.
                .string => {
                    try self.loadSlot(9, self.slotOf(call.arguments[0]));
                    try self.storeSlot(9, self.slotOf(item));
                },
                // Int gets the fast service: svc_str_int(state,
                // value) -> descriptor, then the OOM check.
                .int => {
                    try self.movReg(0, state);
                    try self.loadSlot(1, self.slotOf(call.arguments[0]));
                    try self.loadTable(16, abi.serviceOffset("svc_str_int"));
                    try self.callRegister(16);
                    try self.storeSlot(0, self.slotOf(item));
                    try self.trapCheck();
                },
                // Everything else the gate admits (Bool) goes through
                // the generic path, like MIR's lowering.
                else => {
                    try self.genericCall(item, call, .value);
                },
            },
            .print, .trap_message => try self.genericCall(item, call, .nothing),
            else => unreachable, // supported() refused the rest
        }
    }

    /// The generic service protocol, mirroring the MIR lowering:
    /// operands into the State's marshaling slots, then
    /// svc_instr_{i,v}(state, function, instruction, serial).  M0
    /// programs bind nothing, so the serial is zero, exactly as MIR
    /// emits for serial-free functions.
    fn genericCall(
        self: *Emitter,
        item: ir.Register,
        call: ir.Instruction.IntrinsicCall,
        result: enum { value, nothing },
    ) error{OutOfMemory}!void {
        for (call.arguments, 0..) |argument, slot| {
            try self.loadSlot(9, self.slotOf(argument));
            try self.storeWord(9, state, abi.slots_offset + 8 * @as(u64, slot));
        }
        try self.movReg(0, state);
        try self.materialize(1, 0);
        try self.materialize(2, item);
        try self.materialize(3, 0);
        try self.loadTable(16, abi.serviceOffset(
            if (result == .value) "svc_instr_i" else "svc_instr_v",
        ));
        try self.callRegister(16);
        if (result == .value) try self.storeSlot(0, self.slotOf(item));
        try self.trapCheck();
    }
};

// ---------------------------------------------------------------------------
// Tests — behavior is proven in native_spec.zig's three-way oracle;
// here the gate itself.
// ---------------------------------------------------------------------------

const compile_mod = @import("compile.zig");
const testing = std.testing;

test "the M0 gate admits the integer core and refuses the rest" {
    const admitted =
        \\func main():
        \\    var total = 0
        \\    for i in range(0, 10):
        \\        for j in range(0, 10):
        \\            total += (i * j) % 7
        \\    assert(total > 0)
        \\    print(str(total))
    ;
    const refused_float =
        \\func main():
        \\    print(str(1.5 * 2.0))
    ;
    const refused_call =
        \\func double(x: Int) -> Int:
        \\    return x * 2
        \\
        \\func main():
        \\    print(str(double(21)))
    ;
    inline for (.{ admitted, refused_float, refused_call }, 0..) |source, index| {
        var result = try compile_mod.compile(testing.allocator, source ++ "\n", .{}, .{
            .entry_mode = .script,
            .allow_host = true,
        });
        defer result.deinit();
        try testing.expect(result == .success);
        if (available) {
            try testing.expectEqual(index == 0, supported(&result.success));
        } else {
            try testing.expect(!supported(&result.success));
        }
    }
}
