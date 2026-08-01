//! The WebAssembly backend — Luce IR to a self-contained `.wasm`
//! module (docs/NATIVE.md).
//!
//! A distribution target parallel to the native engines, not another
//! engine loom maps and jumps into: it emits a standalone module a
//! wasm runtime instantiates — the browser, wasmtime, node, deno —
//! with the host effects as imports.  It reuses everything above the
//! seam: the same verified Luce IR, the same trap codes, checked the
//! same way against the interpreter.
//!
//! Scope — the whole scalar language (the bring-up ladder the native
//! backends used):
//!   * milestone 0: one function, the Int/Bool core, integer
//!     arithmetic with full trap semantics, control flow, `assert`,
//!     integer output.
//!   * milestone 1 (here): many functions with parameters and return
//!     values, and floats — f64 arithmetic (IEEE, no traps), the
//!     comparisons, the checked Int(Float)/Float(Int) conversions, and
//!     the scalar math intrinsics (abs, min/max/clamp on Int, sqrt,
//!     floor, ceil).
//! Strings, structs, and the heap are milestone 2.  Deliberately left
//! out until then, each because matching the interpreter *exactly*
//! needs its own step, not because they are hard to reach: float `%`
//! (`@rem`/fmod has no wasm opcode) and float min/max/clamp (fmin/fmax
//! NaN and signed-zero rules wasm's `f64.min`/`f64.max` do not share).
//!
//! Two facts shape the lowering.  WebAssembly is a *structured* stack
//! machine — no registers, no arbitrary jumps — so each Luce function's
//! basic-block CFG becomes a dispatch loop: a `$pc` local selected by
//! `br_table`, correct for any control-flow graph without a relooper.
//! And IR registers and locals each become a wasm *local*, so values
//! move by `local.get`/`local.set` rather than by scheduling the
//! operand stack — the interpreter's register-array model,
//! transliterated.  A Luce call becomes a wasm `call`; recursion and
//! return values ride wasm's own call stack.
//!
//! Host boundary: two imports.  `emit_i64(i64)` is where a computed
//! integer leaves the module — `print(str(n))` lowers to it, so the
//! numeric pipeline is observable without a string runtime yet (floats
//! are observed through `Int(...)` and asserts until strings land).
//! `trap(code)` records a Luce trap code before the module halts on
//! `unreachable`.

const std = @import("std");
const ir = @import("ir.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

pub const available = true; // a pure byte emitter; no host machine code

/// Whether the whole program fits the scalar core (see the file header):
/// every function's parameters, locals, and results are Int/Bool/Float,
/// its instructions are the scalar set, and the entry is `main` (no
/// parameters, no result).  Strings, structs, and the heap fall out.
pub fn supported(program: *const ir.Program) bool {
    const entry = &program.functions[program.entry_function];
    if (entry.parameter_count != 0 or entry.return_type != .none) return false;
    for (program.functions) |*function| {
        if (!functionSupported(program, function)) return false;
    }
    return true;
}

fn functionSupported(program: *const ir.Program, function: *const ir.Function) bool {
    if (!valueOrNone(function.return_type)) return false;
    for (function.locals) |local| {
        if (!valueShaped(local.local_type)) return false;
    }
    for (function.result_types, 0..) |result, register| {
        if (result == .none) continue;
        // A str(Int) result is String-typed but lowered away into the
        // print that consumes it — the one String the scalar core sees.
        if (result == .string) {
            const producer = function.instructions[register];
            if (producer != .intrinsic or producer.intrinsic.kind != .str_value) return false;
            continue;
        }
        if (!valueShaped(result)) return false;
    }
    for (function.instructions) |instruction| {
        switch (instruction) {
            .const_boolean, .const_int, .const_float => {},
            .local_get, .local_set => {},
            .jump, .branch, .trap => {},
            .ret => {},
            .unary => {},
            .convert => {},
            .binary => |op| if (!binarySupported(op)) return false,
            .call => |callee| {
                // Arguments and result already constrained by every
                // function's own local/result gate; nothing more here.
                if (callee.function >= program.functions.len) return false;
            },
            .intrinsic => |call| if (!intrinsicSupported(function, call)) return false,
            else => return false, // input/output, struct_*, heap_*, object_* — milestone 2
        }
    }
    return true;
}

fn binarySupported(op: ir.Instruction.Binary) bool {
    return switch (op.operand_type) {
        .int => true, // full integer arithmetic + comparisons
        .boolean => op.op == .equal or op.op == .not_equal,
        // Float `%` is `@rem`/fmod, which has no wasm opcode.
        .float => op.op != .remainder,
        else => false,
    };
}

fn intrinsicSupported(
    function: *const ir.Function,
    call: ir.Instruction.IntrinsicCall,
) bool {
    const arg_type = struct {
        fn of(fun: *const ir.Function, register: ir.Register) types.Type {
            return fun.result_types[register];
        }
    }.of;
    return switch (call.kind) {
        .assert_true => true,
        .abs => arg_type(function, call.arguments[0]) == .int or
            arg_type(function, call.arguments[0]) == .float,
        // min/max/clamp: Int only — fmin/fmax NaN and signed-zero rules
        // differ from wasm's f64.min/f64.max (milestone 2).
        .min, .max, .clamp => arg_type(function, call.arguments[0]) == .int,
        .sqrt, .floor, .ceil => arg_type(function, call.arguments[0]) == .float,
        .str_value => arg_type(function, call.arguments[0]) == .int,
        .print => {
            const arg = function.instructions[call.arguments[0]];
            if (arg != .intrinsic or arg.intrinsic.kind != .str_value) return false;
            return arg_type(function, arg.intrinsic.arguments[0]) == .int;
        },
        else => false,
    };
}

fn valueShaped(of: types.Type) bool {
    return switch (of) {
        .int, .boolean, .float => true,
        else => false,
    };
}

fn valueOrNone(of: types.Type) bool {
    return of == .none or valueShaped(of);
}

/// Emit the whole program as one wasm module.  Assumes supported().
pub fn compile(arena: Allocator, program: *const ir.Program) error{OutOfMemory}![]const u8 {
    var builder: Builder = .{ .arena = arena, .program = program };
    return builder.module();
}

// ---------------------------------------------------------------------------
// wasm opcode/value vocabulary (the subset the scalar core uses)
// ---------------------------------------------------------------------------

const wasm = struct {
    const i32t: u8 = 0x7F;
    const i64t: u8 = 0x7E;
    const f64t: u8 = 0x7C;
    const func_type: u8 = 0x60;
    const empty_type: u8 = 0x40; // block/if result: none

    const unreachable_: u8 = 0x00;
    const block: u8 = 0x02;
    const loop: u8 = 0x03;
    const if_: u8 = 0x04;
    const else_: u8 = 0x05;
    const end: u8 = 0x0B;
    const br: u8 = 0x0C;
    const br_table: u8 = 0x0E;
    const ret: u8 = 0x0F;
    const call: u8 = 0x10;
    const drop: u8 = 0x1A;
    const select: u8 = 0x1B;

    const local_get: u8 = 0x20;
    const local_set: u8 = 0x21;
    const global_get: u8 = 0x23;
    const global_set: u8 = 0x24;
    const i32_const: u8 = 0x41;
    const i64_const: u8 = 0x42;
    const f64_const: u8 = 0x44;

    const i32_eqz: u8 = 0x45;
    const i32_eq: u8 = 0x46;
    const i32_ne: u8 = 0x47;
    const i32_and: u8 = 0x71;
    const i32_or: u8 = 0x72;

    const i64_eqz: u8 = 0x50;
    const i64_eq: u8 = 0x51;
    const i64_ne: u8 = 0x52;
    const i64_lt_s: u8 = 0x53;
    const i64_gt_s: u8 = 0x55;
    const i64_le_s: u8 = 0x57;
    const i64_ge_s: u8 = 0x59;
    const i64_add: u8 = 0x7C;
    const i64_sub: u8 = 0x7D;
    const i64_mul: u8 = 0x7E;
    const i64_div_s: u8 = 0x7F;
    const i64_rem_s: u8 = 0x81;
    const i64_and: u8 = 0x83;
    const i64_xor: u8 = 0x85;

    const f64_eq: u8 = 0x61;
    const f64_ne: u8 = 0x62;
    const f64_lt: u8 = 0x63;
    const f64_gt: u8 = 0x64;
    const f64_le: u8 = 0x65;
    const f64_ge: u8 = 0x66;
    const f64_abs: u8 = 0x99;
    const f64_neg: u8 = 0x9A;
    const f64_ceil: u8 = 0x9B;
    const f64_floor: u8 = 0x9C;
    const f64_sqrt: u8 = 0x9F;
    const f64_add: u8 = 0xA0;
    const f64_sub: u8 = 0xA1;
    const f64_mul: u8 = 0xA2;
    const f64_div: u8 = 0xA3;

    const i64_trunc_f64_s: u8 = 0xB0;
    const f64_convert_i64_s: u8 = 0xB9;
};

const import_emit = 0; // emit_i64(i64)
const import_trap = 1; // trap(i32 code)
const import_count = 2;

const depth_global = 0; // the sole wasm global: the call-depth budget

/// The call-depth budget the module traps at, matching what loom runs
/// every engine with (`native.max_call_depth`, loom's
/// `program_budget.call_depth`) so the standalone module and the
/// interpreter reach `call_depth_exceeded` on the same recursion — the
/// value is checked against `native.max_call_depth` in the tests below.
const call_depth_budget: i64 = 128;

/// Int(Float)'s guard boundaries, matching the interpreter: NaN or
/// outside [-2^63, 2^63) traps conversion_range.
const int_min_as_float: f64 = -9223372036854775808.0;
const int_max_as_float: f64 = 9223372036854775808.0;

fn valType(of: types.Type) u8 {
    return switch (of) {
        .int => wasm.i64t,
        .float => wasm.f64t,
        else => wasm.i32t, // boolean, and none/string placeholders
    };
}

// ---------------------------------------------------------------------------
// LEB128 / byte helpers
// ---------------------------------------------------------------------------

fn appendU32(list: *std.ArrayList(u8), arena: Allocator, value: u32) error{OutOfMemory}!void {
    var v = value;
    while (true) {
        var byte: u8 = @intCast(v & 0x7F);
        v >>= 7;
        if (v != 0) byte |= 0x80;
        try list.append(arena, byte);
        if (v == 0) break;
    }
}

fn appendI64(list: *std.ArrayList(u8), arena: Allocator, value: i64) error{OutOfMemory}!void {
    var v = value;
    while (true) {
        const low: u8 = @bitCast(@as(i8, @truncate(v)));
        var byte: u8 = low & 0x7F;
        v >>= 7;
        const sign = byte & 0x40;
        if ((v == 0 and sign == 0) or (v == -1 and sign != 0)) {
            try list.append(arena, byte);
            break;
        }
        byte |= 0x80;
        try list.append(arena, byte);
    }
}

fn appendF64(list: *std.ArrayList(u8), arena: Allocator, value: f64) error{OutOfMemory}!void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @bitCast(value), .little);
    try list.appendSlice(arena, &bytes);
}

// ---------------------------------------------------------------------------
// One function's code
// ---------------------------------------------------------------------------

const FunctionEmitter = struct {
    arena: Allocator,
    program: *const ir.Program,
    function: *const ir.Function,
    code: std.ArrayList(u8) = .empty,

    /// str(Int) is lowered away: its result register remembers the
    /// source Int register, which the consuming print emits.
    str_source: []?ir.Register = &.{},

    pc_local: u32 = 0,
    registers_base: u32 = 0,
    /// Extra wasm scopes open between here and the dispatch loop (an
    /// `if` adds one); a `br` to the loop crosses them.
    scope_extra: u32 = 0,
    loop_depth: u32 = 0,

    // -- local layout -------------------------------------------------------
    //
    // wasm locals in index order: the Luce locals (parameters first, so
    // a wasm param index is exactly its Luce LocalId), then `$pc`, then
    // one slot per IR register.  So localLocal(i) == i, the pc follows
    // all locals, and registers follow the pc.

    fn localLocal(self: *const FunctionEmitter, local: ir.LocalId) u32 {
        _ = self;
        return local;
    }
    fn regLocal(self: *const FunctionEmitter, register: ir.Register) u32 {
        return self.registers_base + register;
    }

    // -- code helpers -------------------------------------------------------

    fn op(self: *FunctionEmitter, code: u8) error{OutOfMemory}!void {
        try self.code.append(self.arena, code);
    }
    fn u32v(self: *FunctionEmitter, value: u32) error{OutOfMemory}!void {
        try appendU32(&self.code, self.arena, value);
    }
    fn constI64(self: *FunctionEmitter, value: i64) error{OutOfMemory}!void {
        try self.op(wasm.i64_const);
        try appendI64(&self.code, self.arena, value);
    }
    fn constI32(self: *FunctionEmitter, value: i32) error{OutOfMemory}!void {
        try self.op(wasm.i32_const);
        try appendI64(&self.code, self.arena, value);
    }
    fn constF64(self: *FunctionEmitter, value: f64) error{OutOfMemory}!void {
        try self.op(wasm.f64_const);
        try appendF64(&self.code, self.arena, value);
    }
    fn localGet(self: *FunctionEmitter, index: u32) error{OutOfMemory}!void {
        try self.op(wasm.local_get);
        try self.u32v(index);
    }
    fn localSet(self: *FunctionEmitter, index: u32) error{OutOfMemory}!void {
        try self.op(wasm.local_set);
        try self.u32v(index);
    }
    fn getReg(self: *FunctionEmitter, register: ir.Register) error{OutOfMemory}!void {
        try self.localGet(self.regLocal(register));
    }
    fn setReg(self: *FunctionEmitter, register: ir.Register) error{OutOfMemory}!void {
        try self.localSet(self.regLocal(register));
    }
    fn callFunc(self: *FunctionEmitter, func: u32) error{OutOfMemory}!void {
        try self.op(wasm.call);
        try self.u32v(func);
    }
    fn i64Min(self: *FunctionEmitter) error{OutOfMemory}!void {
        try self.constI64(std.math.minInt(i64));
    }

    fn trap(self: *FunctionEmitter, code: ir.TrapCode) error{OutOfMemory}!void {
        try self.constI32(@intFromEnum(code));
        try self.callFunc(import_trap);
        try self.op(wasm.unreachable_);
    }

    /// <i32 condition on the stack>, then trap(code) when it is true.
    fn trapIf(self: *FunctionEmitter, code: ir.TrapCode) error{OutOfMemory}!void {
        try self.op(wasm.if_);
        try self.op(wasm.empty_type);
        try self.trap(code);
        try self.op(wasm.end);
    }

    /// Reserve one call-stack frame on entry, or trap: `if depth == 0:
    /// trap(call_depth_exceeded); depth -= 1`.  Checking before the
    /// decrement makes the module trap on exactly the recursion the
    /// interpreter refuses (it traps when a push would exceed the
    /// budget, counting the entry frame).
    fn emitDepthEntry(self: *FunctionEmitter) error{OutOfMemory}!void {
        try self.op(wasm.global_get);
        try self.u32v(depth_global);
        try self.op(wasm.i64_eqz);
        try self.trapIf(.call_depth_exceeded);
        try self.op(wasm.global_get);
        try self.u32v(depth_global);
        try self.constI64(1);
        try self.op(wasm.i64_sub);
        try self.op(wasm.global_set);
        try self.u32v(depth_global);
    }

    /// Give the frame back after a call returns (`depth += 1`) — reached
    /// only on the callee's successful return, so a trapped callee
    /// leaves the budget spent, matching the engines' restore-on-success.
    fn emitDepthRestore(self: *FunctionEmitter) error{OutOfMemory}!void {
        try self.op(wasm.global_get);
        try self.u32v(depth_global);
        try self.constI64(1);
        try self.op(wasm.i64_add);
        try self.op(wasm.global_set);
        try self.u32v(depth_global);
    }

    /// Set $pc to `block` and branch to the dispatch loop.
    fn gotoBlock(self: *FunctionEmitter, block: ir.BlockId) error{OutOfMemory}!void {
        try self.constI32(@intCast(block));
        try self.localSet(self.pc_local);
        try self.op(wasm.br);
        try self.u32v(self.loop_depth + self.scope_extra);
    }

    // -- lowering -----------------------------------------------------------

    fn emitInstruction(self: *FunctionEmitter, item: ir.Register) error{OutOfMemory}!void {
        const function = self.function;
        switch (function.instructions[item]) {
            .const_int => |value| {
                try self.constI64(value);
                try self.setReg(item);
            },
            .const_boolean => |value| {
                try self.constI32(@intFromBool(value));
                try self.setReg(item);
            },
            .const_float => |value| {
                try self.constF64(value);
                try self.setReg(item);
            },
            .local_get => |local| {
                try self.localGet(self.localLocal(local));
                try self.setReg(item);
            },
            .local_set => |set| {
                try self.getReg(set.value);
                try self.localSet(self.localLocal(set.local));
            },
            .unary => |operation| try self.emitUnary(item, operation),
            .convert => |operation| try self.emitConvert(item, operation),
            .binary => |operation| try self.emitBinary(item, operation),
            .call => |callee| try self.emitCall(item, callee),
            .intrinsic => |call| try self.emitIntrinsic(item, call),
            .jump => |target| try self.gotoBlock(target),
            .branch => |branching| {
                try self.getReg(branching.condition);
                try self.op(wasm.if_);
                try self.op(wasm.empty_type);
                self.scope_extra += 1;
                try self.gotoBlock(branching.then_block);
                self.scope_extra -= 1;
                try self.op(wasm.end);
                try self.gotoBlock(branching.else_block);
            },
            .ret => |value| {
                if (value) |register| try self.getReg(register);
                try self.op(wasm.ret);
            },
            .trap => |code| try self.trap(code),
            else => unreachable, // supported() refused the rest
        }
    }

    fn emitUnary(self: *FunctionEmitter, item: ir.Register, operation: anytype) error{OutOfMemory}!void {
        switch (operation.op) {
            .negate => switch (self.function.result_types[operation.operand]) {
                .float => {
                    try self.getReg(operation.operand);
                    try self.op(wasm.f64_neg);
                    try self.setReg(item);
                },
                else => { // int: -MIN overflows
                    try self.getReg(operation.operand);
                    try self.i64Min();
                    try self.op(wasm.i64_eq);
                    try self.trapIf(.integer_overflow);
                    try self.constI64(0);
                    try self.getReg(operation.operand);
                    try self.op(wasm.i64_sub);
                    try self.setReg(item);
                },
            },
            .logic_not => {
                try self.getReg(operation.operand);
                try self.op(wasm.i32_eqz);
                try self.setReg(item);
            },
        }
    }

    fn emitConvert(self: *FunctionEmitter, item: ir.Register, operation: anytype) error{OutOfMemory}!void {
        switch (operation.kind) {
            .int_to_float => {
                try self.getReg(operation.operand);
                try self.op(wasm.f64_convert_i64_s);
                try self.setReg(item);
            },
            .float_to_int => {
                // NaN or outside [-2^63, 2^63) traps conversion_range;
                // otherwise truncate toward zero (i64.trunc_f64_s cannot
                // then trap, because the guard cleared its trapping set).
                try self.getReg(operation.operand);
                try self.getReg(operation.operand);
                try self.op(wasm.f64_ne); // isNaN
                try self.getReg(operation.operand);
                try self.constF64(int_min_as_float);
                try self.op(wasm.f64_lt);
                try self.op(wasm.i32_or);
                try self.getReg(operation.operand);
                try self.constF64(int_max_as_float);
                try self.op(wasm.f64_ge);
                try self.op(wasm.i32_or);
                try self.trapIf(.conversion_range);
                try self.getReg(operation.operand);
                try self.op(wasm.i64_trunc_f64_s);
                try self.setReg(item);
            },
        }
    }

    fn emitBinary(self: *FunctionEmitter, item: ir.Register, operation: anytype) error{OutOfMemory}!void {
        switch (operation.operand_type) {
            .float => try self.emitFloatBinary(item, operation),
            .boolean => {
                try self.getReg(operation.left);
                try self.getReg(operation.right);
                try self.op(if (operation.op == .equal) wasm.i32_eq else wasm.i32_ne);
                try self.setReg(item);
            },
            else => try self.emitIntBinary(item, operation),
        }
    }

    fn emitFloatBinary(self: *FunctionEmitter, item: ir.Register, operation: anytype) error{OutOfMemory}!void {
        try self.getReg(operation.left);
        try self.getReg(operation.right);
        try self.op(switch (operation.op) {
            .add => wasm.f64_add,
            .subtract => wasm.f64_sub,
            .multiply => wasm.f64_mul,
            .divide => wasm.f64_div,
            .equal => wasm.f64_eq,
            .not_equal => wasm.f64_ne,
            .less => wasm.f64_lt,
            .less_equal => wasm.f64_le,
            .greater => wasm.f64_gt,
            .greater_equal => wasm.f64_ge,
            .remainder => unreachable, // gated out
        });
        try self.setReg(item);
    }

    fn emitIntBinary(self: *FunctionEmitter, item: ir.Register, operation: anytype) error{OutOfMemory}!void {
        const dest = self.regLocal(item);
        if (operation.op.isComparison()) {
            try self.getReg(operation.left);
            try self.getReg(operation.right);
            try self.op(switch (operation.op) {
                .equal => wasm.i64_eq,
                .not_equal => wasm.i64_ne,
                .less => wasm.i64_lt_s,
                .less_equal => wasm.i64_le_s,
                .greater => wasm.i64_gt_s,
                .greater_equal => wasm.i64_ge_s,
                else => unreachable,
            });
            try self.localSet(dest);
            return;
        }
        switch (operation.op) {
            .add, .subtract => {
                try self.getReg(operation.left);
                try self.getReg(operation.right);
                try self.op(if (operation.op == .add) wasm.i64_add else wasm.i64_sub);
                try self.localSet(dest);
                try self.overflowCheckAddSub(operation.op == .add, operation.left, operation.right, item);
            },
            .multiply => {
                try self.getReg(operation.left);
                try self.getReg(operation.right);
                try self.op(wasm.i64_mul);
                try self.localSet(dest);
                // b != 0 and (a==MIN&&b==-1, or r/b != a); the check
                // divide is only reached when it is safe.
                try self.getReg(operation.right);
                try self.op(wasm.i64_eqz);
                try self.op(wasm.if_);
                try self.op(wasm.empty_type); // b == 0: no overflow
                try self.op(wasm.else_);
                try self.getReg(operation.left);
                try self.i64Min();
                try self.op(wasm.i64_eq);
                try self.getReg(operation.right);
                try self.constI64(-1);
                try self.op(wasm.i64_eq);
                try self.op(wasm.i32_and);
                try self.trapIf(.integer_overflow);
                try self.localGet(dest);
                try self.getReg(operation.right);
                try self.op(wasm.i64_div_s);
                try self.getReg(operation.left);
                try self.op(wasm.i64_ne);
                try self.trapIf(.integer_overflow);
                try self.op(wasm.end);
            },
            .divide, .remainder => {
                try self.getReg(operation.right);
                try self.op(wasm.i64_eqz);
                try self.trapIf(.divide_by_zero);
                try self.getReg(operation.left);
                try self.i64Min();
                try self.op(wasm.i64_eq);
                try self.getReg(operation.right);
                try self.constI64(-1);
                try self.op(wasm.i64_eq);
                try self.op(wasm.i32_and);
                try self.trapIf(.integer_overflow);
                try self.getReg(operation.left);
                try self.getReg(operation.right);
                try self.op(if (operation.op == .divide) wasm.i64_div_s else wasm.i64_rem_s);
                try self.localSet(dest);
            },
            else => unreachable,
        }
    }

    /// (a^r)&(b^r)<0 for add, (a^b)&(a^r)<0 for sub — the sign-based
    /// signed-overflow test, matching the interpreter's checked ops.
    fn overflowCheckAddSub(self: *FunctionEmitter, is_add: bool, left: ir.Register, right: ir.Register, dest: ir.Register) error{OutOfMemory}!void {
        if (is_add) {
            try self.getReg(left);
            try self.getReg(dest);
            try self.op(wasm.i64_xor);
            try self.getReg(right);
            try self.getReg(dest);
            try self.op(wasm.i64_xor);
        } else {
            try self.getReg(left);
            try self.getReg(right);
            try self.op(wasm.i64_xor);
            try self.getReg(left);
            try self.getReg(dest);
            try self.op(wasm.i64_xor);
        }
        try self.op(wasm.i64_and);
        try self.constI64(0);
        try self.op(wasm.i64_lt_s);
        try self.trapIf(.integer_overflow);
    }

    fn emitCall(self: *FunctionEmitter, item: ir.Register, callee: anytype) error{OutOfMemory}!void {
        for (callee.arguments) |argument| try self.getReg(argument);
        try self.callFunc(import_count + callee.function);
        // The callee's entry spent a frame; getting here means it
        // returned, so restore the budget (the global ops sit above any
        // returned value on the stack and leave it in place).
        try self.emitDepthRestore();
        // Match the callee's stack effect: a returned value is stored
        // into this call's register, or dropped if nothing consumes it.
        if (self.program.functions[callee.function].return_type != .none) {
            if (self.function.result_types[item] != .none) {
                try self.setReg(item);
            } else {
                try self.op(wasm.drop);
            }
        }
    }

    fn emitIntrinsic(self: *FunctionEmitter, item: ir.Register, call: ir.Instruction.IntrinsicCall) error{OutOfMemory}!void {
        const args = call.arguments;
        switch (call.kind) {
            .assert_true => {
                try self.getReg(args[0]);
                try self.op(wasm.i32_eqz);
                try self.trapIf(.assertion_failed);
            },
            .abs => switch (self.function.result_types[args[0]]) {
                .float => {
                    try self.getReg(args[0]);
                    try self.op(wasm.f64_abs);
                    try self.setReg(item);
                },
                else => { // int: abs(MIN) overflows
                    try self.getReg(args[0]);
                    try self.i64Min();
                    try self.op(wasm.i64_eq);
                    try self.trapIf(.integer_overflow);
                    // abs(v) = v < 0 ? -v : v, via select
                    try self.constI64(0);
                    try self.getReg(args[0]);
                    try self.op(wasm.i64_sub); // -v
                    try self.getReg(args[0]); // v
                    try self.getReg(args[0]);
                    try self.constI64(0);
                    try self.op(wasm.i64_lt_s); // v < 0
                    try self.op(wasm.select); // (-v) if v<0 else v
                    try self.setReg(item);
                },
            },
            .min, .max => { // Int only (gate)
                const want_min = call.kind == .min;
                try self.getReg(args[0]);
                try self.getReg(args[1]);
                try self.getReg(args[0]);
                try self.getReg(args[1]);
                try self.op(if (want_min) wasm.i64_lt_s else wasm.i64_gt_s);
                try self.op(wasm.select); // a if (a<b|a>b) else b
                try self.setReg(item);
            },
            .clamp => { // Int only (gate): min(max(v, low), high)
                const dest = self.regLocal(item);
                // t = max(v, low)
                try self.getReg(args[0]);
                try self.getReg(args[1]);
                try self.getReg(args[0]);
                try self.getReg(args[1]);
                try self.op(wasm.i64_gt_s);
                try self.op(wasm.select);
                try self.localSet(dest);
                // dest = min(t, high)
                try self.localGet(dest);
                try self.getReg(args[2]);
                try self.localGet(dest);
                try self.getReg(args[2]);
                try self.op(wasm.i64_lt_s);
                try self.op(wasm.select);
                try self.localSet(dest);
            },
            .sqrt, .floor, .ceil => {
                try self.getReg(args[0]);
                try self.op(switch (call.kind) {
                    .sqrt => wasm.f64_sqrt,
                    .floor => wasm.f64_floor,
                    .ceil => wasm.f64_ceil,
                    else => unreachable,
                });
                try self.setReg(item);
            },
            .str_value => {
                // Lowered away: remember the source integer.
                self.str_source[item] = args[0];
            },
            .print => {
                const int_register = self.str_source[args[0]].?;
                try self.getReg(int_register);
                try self.callFunc(import_emit);
            },
            else => unreachable,
        }
    }

    // -- the dispatch loop --------------------------------------------------

    fn emitBody(self: *FunctionEmitter) error{OutOfMemory}!void {
        const function = self.function;
        const block_count: u32 = @intCast(function.blocks.len);

        // Reserve a call-stack frame (or trap) before anything else.
        try self.emitDepthEntry();

        // No further prologue: wasm zero-initialises every non-parameter
        // local (so $pc starts 0, the entry block) and Luce forbids
        // reading a local before it is assigned.

        try self.op(wasm.block);
        try self.op(wasm.empty_type); // $exit
        try self.op(wasm.loop);
        try self.op(wasm.empty_type); // $loop
        var b: u32 = 0;
        while (b < block_count) : (b += 1) {
            try self.op(wasm.block);
            try self.op(wasm.empty_type);
        }
        // br_table: pc = j branches to $B{j}, relative depth
        // (block_count-1)-j; default is block 0.
        try self.localGet(self.pc_local);
        try self.op(wasm.br_table);
        try self.u32v(block_count);
        var j: u32 = 0;
        while (j < block_count) : (j += 1) try self.u32v(block_count - 1 - j);
        try self.u32v(block_count - 1);

        // Block bodies, innermost first: after end $B{k} comes block
        // k's code, whose branch to $loop is at depth k.
        var k: i64 = @as(i64, block_count) - 1;
        while (k >= 0) : (k -= 1) {
            try self.op(wasm.end); // close $B{k}
            self.loop_depth = @intCast(k);
            self.scope_extra = 0;
            for (function.blocks[@intCast(k)].items) |item| try self.emitInstruction(item);
        }
        try self.op(wasm.end); // close $loop
        try self.op(wasm.end); // close $exit
        // Every Luce block ends in a terminator, so control leaves only
        // via `return`/`trap`; the fall-through here is unreachable, and
        // saying so satisfies the validator for value-returning
        // functions (whose result type it would otherwise demand).
        try self.op(wasm.unreachable_);
        try self.op(wasm.end); // close the function body
    }

    /// The function body: local declarations then code.  The declared
    /// locals (after the parameters, which the signature carries) are,
    /// in index order, the non-parameter Luce locals, then `$pc`, then
    /// one slot per IR register — run-length encoded by type.
    fn body(self: *FunctionEmitter) error{OutOfMemory}![]const u8 {
        const function = self.function;
        self.str_source = try self.arena.alloc(?ir.Register, function.instructions.len);
        @memset(self.str_source, null);

        const local_count: u32 = @intCast(function.locals.len);
        self.pc_local = local_count;
        self.registers_base = local_count + 1;

        try self.emitBody();

        var out: std.ArrayList(u8) = .empty;
        var kinds: std.ArrayList(u8) = .empty;
        for (function.locals[function.parameter_count..]) |local| {
            try kinds.append(self.arena, valType(local.local_type));
        }
        try kinds.append(self.arena, wasm.i32t); // pc
        for (function.result_types) |result| {
            try kinds.append(self.arena, valType(result));
        }
        try appendRunLength(&out, self.arena, kinds.items);
        try out.appendSlice(self.arena, self.code.items);
        return out.items;
    }
};

/// Run-length encode a local-type vector into (group_count, then each
/// (count, type)) — the wasm code-section local declaration format.
fn appendRunLength(out: *std.ArrayList(u8), arena: Allocator, kinds: []const u8) error{OutOfMemory}!void {
    var groups: u32 = 0;
    var i: usize = 0;
    while (i < kinds.len) {
        var j = i + 1;
        while (j < kinds.len and kinds[j] == kinds[i]) j += 1;
        groups += 1;
        i = j;
    }
    try appendU32(out, arena, groups);
    i = 0;
    while (i < kinds.len) {
        var j = i + 1;
        while (j < kinds.len and kinds[j] == kinds[i]) j += 1;
        try appendU32(out, arena, @intCast(j - i));
        try out.append(arena, kinds[i]);
        i = j;
    }
}

// ---------------------------------------------------------------------------
// Module assembly
// ---------------------------------------------------------------------------

const Builder = struct {
    arena: Allocator,
    program: *const ir.Program,

    fn module(self: *Builder) error{OutOfMemory}![]const u8 {
        const a = self.arena;
        const functions = self.program.functions;

        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(a, &.{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 }); // \0asm, v1

        // Types: 0 (i64)->(), 1 (i32)->() for the imports, then one per
        // function — index (import_count + f)'s type is (2 + f).
        var t: std.ArrayList(u8) = .empty;
        try appendU32(&t, a, import_count + @as(u32, @intCast(functions.len)));
        try t.appendSlice(a, &.{ wasm.func_type, 1, wasm.i64t, 0 });
        try t.appendSlice(a, &.{ wasm.func_type, 1, wasm.i32t, 0 });
        for (functions) |*function| try appendFuncType(&t, a, function);
        try section(&out, a, 1, t.items);

        // Imports: env.emit_i64 (type 0), env.trap (type 1).
        var im: std.ArrayList(u8) = .empty;
        try appendU32(&im, a, import_count);
        try appendImport(&im, a, "env", "emit_i64", 0);
        try appendImport(&im, a, "env", "trap", 1);
        try section(&out, a, 2, im.items);

        // Functions: function f references type index (2 + f).
        var fs: std.ArrayList(u8) = .empty;
        try appendU32(&fs, a, @intCast(functions.len));
        for (functions, 0..) |_, f| try appendU32(&fs, a, import_count + @as(u32, @intCast(f)));
        try section(&out, a, 3, fs.items);

        // Globals: one mutable i64, the call-depth budget.
        var gl: std.ArrayList(u8) = .empty;
        try appendU32(&gl, a, 1);
        try gl.appendSlice(a, &.{ wasm.i64t, 0x01, wasm.i64_const }); // type, mutable, init
        try appendI64(&gl, a, call_depth_budget);
        try gl.append(a, wasm.end);
        try section(&out, a, 6, gl.items);

        // Exports: the entry function as "main".
        var ex: std.ArrayList(u8) = .empty;
        try appendU32(&ex, a, 1);
        try appendName(&ex, a, "main");
        try ex.append(a, 0x00); // kind: func
        try appendU32(&ex, a, import_count + self.program.entry_function);
        try section(&out, a, 7, ex.items);

        // Code: one entry per function.
        var cs: std.ArrayList(u8) = .empty;
        try appendU32(&cs, a, @intCast(functions.len));
        for (functions) |*function| {
            var emitter: FunctionEmitter = .{ .arena = a, .program = self.program, .function = function };
            const code = try emitter.body();
            try appendU32(&cs, a, @intCast(code.len));
            try cs.appendSlice(a, code);
        }
        try section(&out, a, 10, cs.items);

        return out.items;
    }
};

fn appendFuncType(t: *std.ArrayList(u8), arena: Allocator, function: *const ir.Function) error{OutOfMemory}!void {
    try t.append(arena, wasm.func_type);
    try appendU32(t, arena, function.parameter_count);
    for (function.locals[0..function.parameter_count]) |param| {
        try t.append(arena, valType(param.local_type));
    }
    if (function.return_type == .none) {
        try appendU32(t, arena, 0);
    } else {
        try appendU32(t, arena, 1);
        try t.append(arena, valType(function.return_type));
    }
}

fn section(out: *std.ArrayList(u8), arena: Allocator, id: u8, contents: []const u8) error{OutOfMemory}!void {
    try out.append(arena, id);
    try appendU32(out, arena, @intCast(contents.len));
    try out.appendSlice(arena, contents);
}

fn appendName(list: *std.ArrayList(u8), arena: Allocator, name: []const u8) error{OutOfMemory}!void {
    try appendU32(list, arena, @intCast(name.len));
    try list.appendSlice(arena, name);
}

fn appendImport(list: *std.ArrayList(u8), arena: Allocator, module_name: []const u8, field: []const u8, type_index: u32) error{OutOfMemory}!void {
    try appendName(list, arena, module_name);
    try appendName(list, arena, field);
    try list.append(arena, 0x00); // import kind: func
    try appendU32(list, arena, type_index);
}

// ---------------------------------------------------------------------------
// tests — the gate and byte structure hold without a wasm runtime; the
// end-to-end oracle against the interpreter lives in tools/wasm-test.sh,
// which runs the emitted modules in deno.
// ---------------------------------------------------------------------------

const compile_mod = @import("compile.zig");
const testing = std.testing;
const script: types.CompileOptions = .{ .entry_mode = .script, .allow_host = true };

test "the baked call-depth budget matches what loom runs every engine with" {
    // The wasm module traps at its own baked budget; the oracle runs the
    // interpreter at native.max_call_depth (loom's program_budget), so
    // the two must be the same number or recursion would diverge.
    const native = @import("native.zig");
    try testing.expectEqual(@as(i64, native.max_call_depth), call_depth_budget);
}

fn compileOrNull(source: []const u8) !?ir.Program {
    var result = try compile_mod.compile(testing.allocator, source, .{}, script);
    switch (result) {
        .failure => {
            result.deinit();
            return null;
        },
        .success => |program| return program,
    }
}

test "the scalar core is supported; heap and string output are not yet" {
    // Many functions, parameters and returns, floats through Int, every
    // operator, the branch, negation, assert, print(str(Int)).
    var core = (try compileOrNull(
        \\func hypot2(x: Float, y: Float) -> Int:
        \\    return Int((x * x + y * y) * 100.0)
        \\
        \\func main():
        \\    var total = 0
        \\    for i in range(0, 10):
        \\        if i % 2 == 0:
        \\            total += hypot2(Float(i), 2.0)
        \\        else:
        \\            total -= 0 - i
        \\    assert(total > 0)
        \\    print(str(total))
    )).?;
    defer core.deinit();
    try testing.expect(supported(&core));

    // A List is heap-shaped — milestone 2, refused now.
    var heap = (try compileOrNull(
        \\func main():
        \\    var xs = new List(Int)
        \\    xs.append(3)
        \\    print(str(len(xs)))
    )).?;
    defer heap.deinit();
    try testing.expect(!supported(&heap));

    // print(str) of a String literal is not the str(Int) pipeline.
    var text = (try compileOrNull(
        \\func main():
        \\    print("hello")
    )).?;
    defer text.deinit();
    try testing.expect(!supported(&text));

    // Float `%` is fmod, with no wasm opcode: refused.
    var frem = (try compileOrNull(
        \\func main():
        \\    var a = 5.0
        \\    print(str(Int(a % 2.0)))
    )).?;
    defer frem.deinit();
    try testing.expect(!supported(&frem));
}

test "a supported program emits a well-formed wasm module" {
    var program = (try compileOrNull(
        \\func step(n: Int) -> Int:
        \\    return n * 2
        \\
        \\func main():
        \\    var n = 1
        \\    while n < 1000:
        \\        n = step(n)
        \\    print(str(n))
    )).?;
    defer program.deinit();
    try testing.expect(supported(&program));

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const bytes = try compile(arena_state.allocator(), &program);

    // Magic \0asm and version 1.
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 }, bytes[0..8]);

    // Every section after the header is length-prefixed and consumes
    // exactly its declared bytes, in ascending id order — a structural
    // pass a runtime would otherwise catch.
    var offset: usize = 8;
    var last_id: u8 = 0;
    while (offset < bytes.len) {
        const id = bytes[offset];
        try testing.expect(id > last_id); // sections strictly ordered
        last_id = id;
        offset += 1;
        var length: u32 = 0;
        var shift: u5 = 0;
        while (true) {
            const byte = bytes[offset];
            offset += 1;
            length |= @as(u32, byte & 0x7F) << shift;
            if (byte & 0x80 == 0) break;
            shift += 7;
        }
        offset += length;
    }
    try testing.expectEqual(bytes.len, offset); // sections tile the module exactly
}
