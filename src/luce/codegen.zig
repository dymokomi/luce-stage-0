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
//! Scope (milestone 1: registers), still deliberately narrow: one
//! aarch64 target (macOS/Linux — the encoder is OS-blind, image.map
//! does the OS work), a single-function program, Int/Bool/String
//! values, Int arithmetic with the full trap semantics, control
//! flow, and print/str/assert/trap.  Opt-in via LOOM_ENGINE=zig.
//! x86-64 is the next target; Windows follows once image.zig grows
//! VirtualAlloc.
//!
//! Code shape after milestone 1: locals live pinned in callee-saved
//! registers (x20-x26, slots beyond that), block-local temporaries
//! in a small scratch pool with spilling — sound because the IR
//! guarantees registers never cross blocks, so temporary lifetimes
//! are single-block and single-assignment.  Constants stay lazy
//! until a use forces them, which is what makes immediate forms
//! (add/sub/cmp #imm) and constant-divisor guard elision fall out;
//! a comparison feeding the adjacent branch fuses to cmp + b.cond.
//! x19 holds the State; x13/x14 are transient scratch the allocator
//! never owns; x16 is the call target.  The trap protocol, depth
//! budget, and service marshaling mirror the MIR lowering exactly,
//! and native_spec holds the engines to identical behavior.

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

/// Whether the whole program fits this backend's core.  One function
/// (post-prune scripts with no calls), value types Int/Bool/String,
/// integer arithmetic, control flow, and the four supported
/// intrinsics.
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

/// Compile the program to one hermetic span per function (currently
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

/// Where an IR register's value currently is.  Constants and
/// local_get results stay lazy until a use forces them — that is
/// what immediate operand forms and guard elision hang on.
const Location = union(enum) {
    /// Not defined yet, or dead past its last use.
    nowhere,
    /// In a scratch-pool register the allocator owns.
    register: u5,
    /// Spilled to (or only ever in) its frame slot.
    slot,
    /// A lazy integer/boolean constant.
    immediate: i64,
    /// A lazy string constant (index into the program's pool).
    constant: u32,
    /// A lazy local_get: valid while the local's version matches —
    /// a local_set in between materializes live aliases first.
    alias: struct { local: u32, version: u32 },
};

const scratch_pool = [_]u5{ 9, 10, 11, 12 };
const pinned_pool = [_]u5{ 20, 21, 22, 23, 24, 25, 26 };

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

    // Analysis (emission order = block order, one position per item).
    positions: []u32 = &.{},
    last_use: []u32 = &.{},
    use_count: []u32 = &.{},

    // Allocation state.
    location: []Location = &.{},
    scratch_owner: [scratch_pool.len]?ir.Register = @splat(null),
    pinned: []?u5 = &.{},
    local_version: []u32 = &.{},
    position: u32 = 0,
    /// A comparison whose flags are still live for the next item.
    pending_compare: ?struct { register: ir.Register, condition: u4 } = null,
    /// A local_set already performed by its producer writing the
    /// pinned register directly; the set itself only bumps the
    /// version.
    pending_absorb: ?u32 = null,
    /// The block being emitted, for fallthrough elision.
    current_block: u32 = 0,

    // -- aarch64 conditions ------------------------------------------------

    const eq: u4 = 0x0;
    const ne: u4 = 0x1;
    const vs: u4 = 0x6;
    const ge: u4 = 0xA;
    const lt: u4 = 0xB;
    const gt: u4 = 0xC;
    const le: u4 = 0xD;

    const state: u5 = 19;
    const zr: u5 = 31;
    /// Transient scratch the allocator never owns.
    const helper: u5 = 13;
    const helper2: u5 = 14;

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

    fn loadWord(self: *Emitter, rt: u5, rn: u5, byte_offset: u64) !void {
        const scaled: u12 = @intCast(byte_offset / 8);
        try self.word(0xF9400000 | @as(u32, scaled) << 10 | @as(u32, rn) << 5 | rt);
    }

    fn storeWord(self: *Emitter, rt: u5, rn: u5, byte_offset: u64) !void {
        const scaled: u12 = @intCast(byte_offset / 8);
        try self.word(0xF9000000 | @as(u32, scaled) << 10 | @as(u32, rn) << 5 | rt);
    }

    /// ldr rt, [state, offset] — offsets can pass the immediate
    /// range, so the offset goes through the transient helper.
    fn loadTable(self: *Emitter, rt: u5, offset: u64) !void {
        try self.materialize(helper, offset);
        try self.word(0xF8606800 | @as(u32, helper) << 16 | @as(u32, state) << 5 | rt);
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

    /// cmp rn, #imm — subs for a non-negative immediate, cmn for a
    /// negative one (flags of rn - imm either way).
    fn compareImmediate(self: *Emitter, rn: u5, immediate: i64) !void {
        if (immediate >= 0) {
            try self.word(0xF100001F | @as(u32, @intCast(immediate)) << 10 | @as(u32, rn) << 5);
        } else {
            try self.word(0xB100001F | @as(u32, @intCast(-immediate)) << 10 | @as(u32, rn) << 5);
        }
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

    /// After a service call: any recorded trap propagates.  Reads
    /// through the helper — the pool may be holding values.
    fn trapCheck(self: *Emitter) !void {
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
            .local_set => |set| {
                buffer[0] = set.value;
                return buffer[0..1];
            },
            .branch => |branching| {
                buffer[0] = branching.condition;
                return buffer[0..1];
            },
            .intrinsic => |call| return call.arguments,
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

    fn poolIndexOf(register: u5) usize {
        for (scratch_pool, 0..) |candidate, index| {
            if (candidate == register) return index;
        }
        unreachable;
    }

    /// A free pool register, evicting the longest-lived owner if the
    /// pool is full.  Registers in `locked` (operands mid-use) are
    /// never evicted.
    fn allocScratch(self: *Emitter, owner: ir.Register, locked: []const u5) error{OutOfMemory}!u5 {
        for (scratch_pool, 0..) |candidate, index| {
            if (self.scratch_owner[index] == null and !contains(locked, candidate)) {
                self.scratch_owner[index] = owner;
                return candidate;
            }
        }
        var victim_index: ?usize = null;
        for (scratch_pool, 0..) |candidate, index| {
            if (contains(locked, candidate)) continue;
            const resident = self.scratch_owner[index].?;
            if (victim_index == null or
                self.last_use[resident] > self.last_use[self.scratch_owner[victim_index.?].?])
            {
                victim_index = index;
            }
        }
        const index = victim_index.?; // pool > lockable operands
        const evicted = self.scratch_owner[index].?;
        try self.storeSlot(scratch_pool[index], self.slotOf(evicted));
        self.location[evicted] = .slot;
        self.scratch_owner[index] = owner;
        return scratch_pool[index];
    }

    fn contains(haystack: []const u5, needle: u5) bool {
        for (haystack) |candidate| {
            if (candidate == needle) return true;
        }
        return false;
    }

    fn release(self: *Emitter, register: ir.Register) void {
        switch (self.location[register]) {
            .register => |physical| self.scratch_owner[poolIndexOf(physical)] = null,
            else => {},
        }
        self.location[register] = .nowhere;
    }

    /// Free operands whose last use is the current position.
    fn freeDead(self: *Emitter, operands: []const ir.Register) void {
        for (operands) |operand| {
            if (self.last_use[operand] <= self.position) self.release(operand);
        }
    }

    /// The value in a physical register, forcing lazy locations.
    /// Returned pool registers stay owned; pinned-local reads return
    /// the pinned register itself (never evictable, never a dest).
    fn operandRegister(self: *Emitter, register: ir.Register, locked: []const u5) error{OutOfMemory}!u5 {
        switch (self.location[register]) {
            .register => |physical| return physical,
            .nowhere => unreachable, // verifier: uses follow defs
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
            .constant => |index| {
                const physical = try self.allocScratch(register, locked);
                try self.loadTable(physical, abi.constantOffset(index));
                self.location[register] = .{ .register = physical };
                return physical;
            },
            .alias => |lazy| {
                if (self.local_version[lazy.local] == lazy.version) {
                    if (self.pinned[lazy.local]) |physical| return physical;
                }
                // The local moved on (or lives in a slot): the value
                // was materialized at the local_set (or never left
                // its slot) — load our own copy.
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

    /// Fetch a value into a specific register (ABI marshaling) —
    /// never touches pool ownership.
    fn fetchInto(self: *Emitter, target: u5, register: ir.Register) error{OutOfMemory}!void {
        switch (self.location[register]) {
            .register => |physical| try self.movReg(target, physical),
            .nowhere => unreachable,
            .slot => try self.loadSlot(target, self.slotOf(register)),
            .immediate => |value| try self.materialize(target, @bitCast(value)),
            .constant => |index| try self.loadTable(target, abi.constantOffset(index)),
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

    /// Before a local is overwritten: any live lazy alias to it gets
    /// its own copy of the current value (spilled to the alias's own
    /// frame slot — rare, so the slot is fine).
    fn materializeAliases(self: *Emitter, local: u32) error{OutOfMemory}!void {
        const version = self.local_version[local];
        for (self.location, 0..) |current, register| {
            if (current != .alias) continue;
            if (current.alias.local != local or current.alias.version != version) continue;
            if (self.last_use[register] <= self.position) continue;
            if (self.pinned[local]) |physical| {
                try self.storeSlot(physical, self.slotOf(@intCast(register)));
            } else {
                try self.loadSlot(helper, local);
                try self.storeSlot(helper, self.slotOf(@intCast(register)));
            }
            self.location[register] = .slot;
        }
    }

    /// Before a call: pool registers do not survive the C ABI, so
    /// every live pool value spills to its slot.
    fn spillForCall(self: *Emitter) error{OutOfMemory}!void {
        for (scratch_pool, 0..) |physical, index| {
            const resident = self.scratch_owner[index] orelse continue;
            if (self.last_use[resident] > self.position) {
                try self.storeSlot(physical, self.slotOf(resident));
                self.location[resident] = .slot;
            } else {
                self.location[resident] = .nowhere;
            }
            self.scratch_owner[index] = null;
        }
    }

    /// A destination register for `item`, preferring to reuse a
    /// dying operand's pool register.
    fn destRegister(self: *Emitter, item: ir.Register, operands: []const ir.Register, locked: []const u5) error{OutOfMemory}!u5 {
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

    /// The destination for a producing instruction: the pinned local
    /// register when the adjacent local_set absorbs it, a pool
    /// register otherwise.
    fn resultRegister(
        self: *Emitter,
        item: ir.Register,
        following: ?ir.Register,
        operands: []const ir.Register,
        locked: []const u5,
    ) error{OutOfMemory}!u5 {
        if (try self.absorbTarget(item, following)) |physical| return physical;
        return self.destRegister(item, operands, locked);
    }

    // -- the function ------------------------------------------------------

    fn emitFunction(self: *Emitter) error{OutOfMemory}!void {
        const function = self.function;
        try self.analyze();
        const slots = function.locals.len + function.instructions.len;
        self.frame_size = std.mem.alignForward(u64, @as(u64, slots) * 8, 16);
        self.epilogue = try self.newMark();
        self.propagate = try self.newMark();
        const block_marks = try self.arena.alloc(u32, function.blocks.len);
        for (block_marks) |*mark| mark.* = try self.newMark();
        self.block_marks = block_marks;
        self.pinned = try self.arena.alloc(?u5, function.locals.len);
        self.local_version = try self.arena.alloc(u32, function.locals.len);
        @memset(self.local_version, 0);
        for (self.pinned, 0..) |*slot, index| {
            slot.* = if (index < pinned_pool.len) pinned_pool[index] else null;
        }

        // Prologue: saves, frame, the State register, the depth
        // budget (the same subtract-store-check the MIR lowering
        // emits), typed zeros for the locals.
        try self.word(0xA9BF7BFD); // stp x29, x30, [sp, #-16]!
        try self.word(0xA9BF53F3); // stp x19, x20, [sp, #-16]!
        try self.word(0xA9BF5BF5); // stp x21, x22, [sp, #-16]!
        try self.word(0xA9BF63F7); // stp x23, x24, [sp, #-16]!
        try self.word(0xA9BF6BF9); // stp x25, x26, [sp, #-16]!
        if (self.frame_size <= 4095) {
            try self.subImmediate(31, 31, @intCast(self.frame_size));
        } else {
            try self.materialize(helper, self.frame_size);
            try self.word(0xCB2D63FF); // sub sp, sp, x13 (extended)
        }
        try self.movReg(state, 0);
        const depth = try self.trapSite(.call_depth_exceeded, 0);
        try self.loadWord(helper, state, abi.depth_offset);
        try self.word(0xF10005AD); // subs x13, x13, #1
        try self.storeWord(helper, state, abi.depth_offset);
        try self.branchCond(lt, depth);
        for (function.locals, 0..) |local, index| {
            const target = self.pinned[index];
            switch (local.local_type) {
                .int, .boolean => {
                    if (target) |physical| {
                        try self.movReg(physical, zr);
                    } else {
                        try self.storeSlot(zr, index);
                    }
                },
                .string => {
                    if (target) |physical| {
                        try self.loadTable(physical, abi.constantOffset(self.program.constants.len));
                    } else {
                        try self.loadTable(helper2, abi.constantOffset(self.program.constants.len));
                        try self.storeSlot(helper2, index);
                    }
                },
                else => unreachable, // supported() refused the rest
            }
        }

        for (function.blocks, 0..) |block, index| {
            self.bind(self.block_marks[index]);
            self.current_block = @intCast(index);
            // Temporaries never cross blocks (the IR guarantees it),
            // so the pool resets clean at every block edge.
            self.scratch_owner = @splat(null);
            self.pending_compare = null;
            for (block.items, 0..) |item, at| {
                const following: ?ir.Register =
                    if (at + 1 < block.items.len) block.items[at + 1] else null;
                try self.emitInstruction(item, following);
                self.position += 1;
                self.pendingExpired(item);
            }
        }

        // Trap stubs: record the triple, return the default.
        for (self.sites.items) |site| {
            self.bind(site.mark);
            try self.materialize(helper, @bitCast(abi.trap(site.code)));
            try self.storeWord(helper, state, abi.trap_offset);
            try self.materialize(helper, 0); // function index — one function
            try self.storeWord(helper, state, abi.trap_function_offset);
            try self.materialize(helper, site.instruction);
            try self.storeWord(helper, state, abi.trap_instruction_offset);
            try self.branchTo(self.propagate);
        }
        self.bind(self.propagate);
        // main returns nothing; a trap abandons the depth budget.
        try self.branchTo(self.epilogue);
        self.bind(self.epilogue);
        if (self.frame_size <= 4095) {
            try self.addImmediate(31, 31, @intCast(self.frame_size));
        } else {
            try self.materialize(helper, self.frame_size);
            try self.word(0x8B2D63FF); // add sp, sp, x13 (extended)
        }
        try self.word(0xA8C16BF9); // ldp x25, x26, [sp], #16
        try self.word(0xA8C163F7); // ldp x23, x24, [sp], #16
        try self.word(0xA8C15BF5); // ldp x21, x22, [sp], #16
        try self.word(0xA8C153F3); // ldp x19, x20, [sp], #16
        try self.word(0xA8C17BFD); // ldp x29, x30, [sp], #16
        try self.word(0xD65F03C0); // ret

        self.patch();
    }

    /// A fused comparison's flags live for exactly one following
    /// item (the branch that consumes them).
    fn pendingExpired(self: *Emitter, just_emitted: ir.Register) void {
        if (self.pending_compare) |pending| {
            if (pending.register != just_emitted and
                self.positions[pending.register] + 1 < self.position)
            {
                self.pending_compare = null;
            }
        }
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

    /// When `item`'s only use is the adjacent local_set of a pinned
    /// local, the producer can write the pinned register directly —
    /// no temporary, no mov.  Live aliases of the local are
    /// materialized here, before the early write.
    fn absorbTarget(self: *Emitter, item: ir.Register, following: ?ir.Register) error{OutOfMemory}!?u5 {
        const next = following orelse return null;
        if (self.use_count[item] != 1) return null;
        switch (self.function.instructions[next]) {
            .local_set => |set| {
                if (set.value != item) return null;
                const physical = self.pinned[set.local] orelse return null;
                try self.materializeAliases(set.local);
                self.pending_absorb = set.local;
                self.location[item] = .nowhere;
                return physical;
            },
            else => return null,
        }
    }

    fn emitInstruction(self: *Emitter, item: ir.Register, following: ?ir.Register) error{OutOfMemory}!void {
        const function = self.function;
        switch (function.instructions[item]) {
            // Constants and local reads stay lazy; a use forces them.
            .const_int => |value| self.location[item] = .{ .immediate = value },
            .const_boolean => |value| self.location[item] = .{ .immediate = @intFromBool(value) },
            .const_data => |data| self.location[item] = .{ .constant = data.constant },
            .local_get => |local| self.location[item] = .{
                .alias = .{ .local = local, .version = self.local_version[local] },
            },
            .local_set => |set| {
                if (self.pending_absorb) |local| {
                    if (local == set.local) {
                        // The producer already wrote the pinned
                        // register; only the version turns over.
                        self.pending_absorb = null;
                        self.local_version[set.local] += 1;
                        return;
                    }
                }
                try self.materializeAliases(set.local);
                if (self.pinned[set.local]) |physical| {
                    try self.fetchInto(physical, set.value);
                } else {
                    try self.fetchInto(helper, set.value);
                    try self.storeSlot(helper, set.local);
                }
                self.local_version[set.local] += 1;
                self.freeDead(&.{set.value});
            },
            // Blocks are laid out in index order, so a branch to the
            // physically next block is a fallthrough (aarch64
            // condition codes invert by flipping the low bit).
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
                            try self.branchCond(pending.condition ^ 1, self.block_marks[branching.else_block]);
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
            .ret => {
                // Success restores the depth budget; traps do not.
                try self.loadWord(helper, state, abi.depth_offset);
                try self.addImmediate(helper, helper, 1);
                try self.storeWord(helper, state, abi.depth_offset);
                try self.branchTo(self.epilogue);
            },
            .trap => |code| try self.branchTo(try self.trapSite(code, item)),
            .unary => |operation| {
                const operand = try self.operandRegister(operation.operand, &.{});
                switch (operation.op) {
                    .negate => {
                        const overflow = try self.trapSite(.integer_overflow, item);
                        const dest = try self.resultRegister(item, following, &.{operation.operand}, &.{operand});
                        // subs dest, xzr, operand
                        try self.word(0xEB000000 | @as(u32, operand) << 16 | @as(u32, zr) << 5 | dest);
                        try self.branchCond(vs, overflow);
                    },
                    .logic_not => {
                        try self.compareImmediate(operand, 0);
                        const dest = try self.resultRegister(item, following, &.{operation.operand}, &.{operand});
                        try self.setCond(dest, eq);
                    },
                }
                self.freeDead(&.{operation.operand});
            },
            .binary => |operation| try self.emitBinary(item, operation, following),
            .intrinsic => |call| try self.emitIntrinsic(item, call),
            else => unreachable, // supported() refused everything else
        }
    }

    fn immediateOperand(self: *const Emitter, register: ir.Register) ?i64 {
        return switch (self.location[register]) {
            .immediate => |value| value,
            else => null,
        };
    }

    fn conditionOf(op: ir.BinaryOp) u4 {
        return switch (op) {
            .equal => eq,
            .not_equal => ne,
            .less => lt,
            .less_equal => le,
            .greater => gt,
            .greater_equal => ge,
            else => unreachable,
        };
    }

    /// The condition with operands swapped (a < b == b > a).
    fn swappedCondition(condition: u4) u4 {
        return switch (condition) {
            eq, ne => condition,
            lt => gt,
            gt => lt,
            le => ge,
            ge => le,
            else => unreachable,
        };
    }

    fn fitsImmediate(value: i64) bool {
        return value > -4096 and value < 4096;
    }

    fn emitBinary(self: *Emitter, item: ir.Register, operation: anytype, following: ?ir.Register) error{OutOfMemory}!void {
        if (operation.op.isComparison()) {
            // Immediate forms, swapping when the constant is on the
            // left; then either fuse into the adjacent consuming
            // branch (no boolean ever materializes) or cset.
            var condition = conditionOf(operation.op);
            if (self.immediateOperand(operation.right)) |value| blk: {
                if (!fitsImmediate(value)) break :blk;
                const left = try self.operandRegister(operation.left, &.{});
                try self.compareImmediate(left, value);
                self.freeDead(&.{ operation.left, operation.right });
                return self.finishComparison(item, condition, following);
            }
            if (self.immediateOperand(operation.left)) |value| blk: {
                if (!fitsImmediate(value)) break :blk;
                const right = try self.operandRegister(operation.right, &.{});
                try self.compareImmediate(right, value);
                condition = swappedCondition(condition);
                self.freeDead(&.{ operation.left, operation.right });
                return self.finishComparison(item, condition, following);
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
                // adds/subs with a small immediate (negated flips the
                // op — flags still describe the true operation).
                if (self.immediateOperand(operation.right)) |value| blk: {
                    if (!fitsImmediate(value)) break :blk;
                    const effective_add = (operation.op == .add) == (value >= 0);
                    const magnitude: u12 = @intCast(@abs(value));
                    const left = try self.operandRegister(operation.left, &.{});
                    const dest = try self.resultRegister(item, following, &.{ operation.left, operation.right }, &.{left});
                    const base: u32 = if (effective_add) 0xB1000000 else 0xF1000000;
                    try self.word(base | @as(u32, magnitude) << 10 | @as(u32, left) << 5 | dest);
                    try self.branchCond(vs, overflow);
                    self.freeDead(&.{ operation.left, operation.right });
                    return;
                }
                const left = try self.operandRegister(operation.left, &.{});
                const right = try self.operandRegister(operation.right, &.{left});
                const dest = try self.resultRegister(item, following, &.{ operation.left, operation.right }, &.{ left, right });
                const base: u32 = if (operation.op == .add) 0xAB000000 else 0xEB000000;
                try self.word(base | @as(u32, right) << 16 | @as(u32, left) << 5 | dest);
                try self.branchCond(vs, overflow);
                self.freeDead(&.{ operation.left, operation.right });
            },
            .multiply => {
                const overflow = try self.trapSite(.integer_overflow, item);
                const left = try self.operandRegister(operation.left, &.{});
                const right = try self.operandRegister(operation.right, &.{left});
                // smulh first into the helper so the destination may
                // alias an operand.
                try self.word(0x9B407C00 | @as(u32, right) << 16 | @as(u32, left) << 5 | helper2);
                const dest = try self.resultRegister(item, following, &.{ operation.left, operation.right }, &.{ left, right });
                try self.word(0x9B007C00 | @as(u32, right) << 16 | @as(u32, left) << 5 | dest);
                // Overflow unless the high word is the sign extension
                // of the low: cmp helper2, dest, asr #63.
                try self.word(0xEB000000 | 0x2 << 22 | @as(u32, dest) << 16 |
                    @as(u32, 63) << 10 | @as(u32, helper2) << 5 | zr);
                try self.branchCond(ne, overflow);
                self.freeDead(&.{ operation.left, operation.right });
            },
            .divide, .remainder => {
                // The MIR lowering's exact guards — zero traps, MIN/-1
                // traps — with each guard elided when a constant
                // operand decides it statically (same semantics: the
                // elided branch could never fire).
                const divisor_constant = self.immediateOperand(operation.right);
                const dividend_constant = self.immediateOperand(operation.left);
                const left = try self.operandRegister(operation.left, &.{});
                const right = try self.operandRegister(operation.right, &.{left});
                if (divisor_constant) |value| {
                    if (value == 0) {
                        // Statically always a trap.
                        try self.branchTo(try self.trapSite(.divide_by_zero, item));
                    }
                } else {
                    try self.branchZero(right, try self.trapSite(.divide_by_zero, item), true);
                }
                const divisor_may_be_minus_one =
                    divisor_constant == null or divisor_constant.? == -1;
                const dividend_may_be_minimum =
                    dividend_constant == null or dividend_constant.? == std.math.minInt(i64);
                if (divisor_may_be_minus_one and dividend_may_be_minimum) {
                    const overflow = try self.trapSite(.integer_overflow, item);
                    const fine = try self.newMark();
                    if (divisor_constant == null) {
                        try self.compareImmediate(right, -1);
                        try self.branchCond(ne, fine);
                    }
                    try self.movz(helper2, 0x8000, 3); // i64 minimum
                    try self.compareRegisters(left, helper2);
                    try self.branchCond(eq, overflow);
                    self.bind(fine);
                }
                const dest = try self.resultRegister(item, following, &.{ operation.left, operation.right }, &.{ left, right });
                if (operation.op == .divide) {
                    // sdiv dest, left, right
                    try self.word(0x9AC00C00 | @as(u32, right) << 16 | @as(u32, left) << 5 | dest);
                } else {
                    try self.word(0x9AC00C00 | @as(u32, right) << 16 | @as(u32, left) << 5 | helper2);
                    // msub dest, helper2, right, left
                    try self.word(0x9B008000 | @as(u32, right) << 16 | @as(u32, left) << 10 |
                        @as(u32, helper2) << 5 | dest);
                }
                self.freeDead(&.{ operation.left, operation.right });
            },
            else => unreachable,
        }
    }

    /// A comparison's flags either fuse into the adjacent consuming
    /// branch or become a boolean via cset.
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
        const dest = try self.resultRegister(item, following, &.{}, &.{});
        try self.setCond(dest, condition);
    }

    fn emitIntrinsic(self: *Emitter, item: ir.Register, call: ir.Instruction.IntrinsicCall) error{OutOfMemory}!void {
        switch (call.kind) {
            .assert_true => {
                const failed = try self.trapSite(.assertion_failed, item);
                const value = try self.operandRegister(call.arguments[0], &.{});
                self.freeDead(&.{call.arguments[0]});
                try self.branchZero(value, failed, true);
            },
            .str_value => switch (self.function.result_types[call.arguments[0]]) {
                // str on a String is a move, exactly as MIR lowers
                // it.  Fetch before any dest bookkeeping — reusing a
                // dying operand's register would clear the location
                // this fetch still needs.
                .string => {
                    const dest = try self.destRegister(item, &.{}, &.{});
                    try self.fetchInto(dest, call.arguments[0]);
                    self.freeDead(&.{call.arguments[0]});
                },
                // Int gets the fast service: svc_str_int(state,
                // value) -> descriptor, then the OOM check.
                .int => {
                    try self.fetchInto(1, call.arguments[0]);
                    self.freeDead(&.{call.arguments[0]});
                    try self.spillForCall();
                    try self.movReg(0, state);
                    try self.loadTable(16, abi.serviceOffset("svc_str_int"));
                    try self.callRegister(16);
                    const dest = try self.destRegister(item, &.{}, &.{});
                    try self.movReg(dest, 0);
                    try self.trapCheck();
                },
                // Everything else the gate admits (Bool) goes through
                // the generic path, like MIR's lowering.
                else => try self.genericCall(item, call, .value),
            },
            .print, .trap_message => try self.genericCall(item, call, .nothing),
            else => unreachable, // supported() refused the rest
        }
    }

    /// The generic service protocol, mirroring the MIR lowering:
    /// operands into the State's marshaling slots, then
    /// svc_instr_{i,v}(state, function, instruction, serial).  These
    /// programs bind nothing, so the serial is zero, exactly as MIR
    /// emits for serial-free functions.
    fn genericCall(
        self: *Emitter,
        item: ir.Register,
        call: ir.Instruction.IntrinsicCall,
        result: enum { value, nothing },
    ) error{OutOfMemory}!void {
        for (call.arguments, 0..) |argument, slot| {
            try self.fetchInto(helper2, argument);
            try self.storeWord(helper2, state, abi.slots_offset + 8 * @as(u64, slot));
        }
        self.freeDead(call.arguments);
        try self.spillForCall();
        try self.movReg(0, state);
        try self.materialize(1, 0);
        try self.materialize(2, item);
        try self.materialize(3, 0);
        try self.loadTable(16, abi.serviceOffset(
            if (result == .value) "svc_instr_i" else "svc_instr_v",
        ));
        try self.callRegister(16);
        if (result == .value) {
            const dest = try self.destRegister(item, &.{}, &.{});
            try self.movReg(dest, 0);
        }
        try self.trapCheck();
    }
};

// ---------------------------------------------------------------------------
// Tests — behavior is proven in native_spec.zig's three-way oracle;
// here the gate itself.
// ---------------------------------------------------------------------------

const compile_mod = @import("compile.zig");
const testing = std.testing;

test "the gate admits the integer core and refuses the rest" {
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
