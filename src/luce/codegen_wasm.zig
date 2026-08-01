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
//! Structure.  WebAssembly is a *structured* stack machine — no
//! registers, no arbitrary jumps — so each Luce function's basic-block
//! CFG becomes a dispatch loop: a `$pc` local selected by `br_table`,
//! correct for any control-flow graph without a relooper.  IR registers
//! and locals each become a wasm *local*, so values move by
//! `local.get`/`local.set` rather than by scheduling the operand stack.
//! A Luce call becomes a wasm `call`; recursion and return values ride
//! wasm's own call stack, with call depth kept a budget (a global) that
//! traps `call_depth_exceeded` exactly where the interpreter does.
//!
//! Values.  Scalars are wasm scalars: Int → i64, Bool → i32, Float →
//! f64.  Everything with identity lives in **linear memory**, reached
//! by an i32 address held in a local: a String is a length-prefixed
//! byte block (`[i32 len][bytes]`), so a string-typed local is just its
//! address, and the zero address (0) is the empty string.  A small
//! **runtime prelude** of hand-emitted wasm functions owns memory: a
//! bump allocator (`rt_alloc`) and the string primitives.  Memory is
//! never reclaimed mid-run — which matches the interpreter, whose
//! `free` only marks an object dead and whose arena reclaims at the end.
//!
//! Host boundary: two imports.  `emit_str(ptr, len)` is where text
//! leaves the module — every `print` lowers to it, reading the bytes
//! straight from memory.  `trap(code)` records a Luce trap code before
//! `unreachable` halts the module.
//!
//! Scope, following the bring-up ladder the native backends used:
//!   * M0: one function, the Int/Bool core.
//!   * M1: many functions, floats, the checked conversions and scalar
//!     math intrinsics.
//!   * M2 (here, in phases): strings — the length-prefixed runtime, the
//!     string operators and intrinsics, `str(Int)`/`str(Bool)`, and
//!     `print` of any text.
//! Deferred with reasons (not because they are hard to reach, but
//! because matching the reference *exactly* is its own step): float `%`
//! and float `min`/`max`/`clamp` (fmod / fmin-fmax semantics with no
//! wasm opcode); `str(Float)` and `parse_float` (Zig's shortest-round-
//! trip float formatting is an algorithm to port, not an opcode).  The
//! object heap (List/Map/Array/Builder), structs, and ownership are the
//! next phase.

const std = @import("std");
const ir = @import("ir.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

pub const available = true; // a pure byte emitter; no host machine code

// ---------------------------------------------------------------------------
// The gate
// ---------------------------------------------------------------------------

/// Whether the whole program fits the current backend scope: every
/// function's parameters, locals, and results are Int/Bool/Float/String,
/// its instructions are the scalar-plus-string set, and the entry is
/// `main` (no parameters, no result).  Structs and the heap fall out.
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
    for (function.result_types) |result| {
        if (result != .none and !valueShaped(result)) return false;
    }
    for (function.instructions) |instruction| {
        switch (instruction) {
            .const_boolean, .const_int, .const_float => {},
            .const_data => |data| if (data.data_type != .string) return false, // bytes: later
            .local_get, .local_set => {},
            .jump, .branch, .trap => {},
            .ret => {},
            .unary => {},
            .convert => {},
            .binary => |op| if (!binarySupported(op)) return false,
            .call => |callee| if (callee.function >= program.functions.len) return false,
            .intrinsic => |call| if (!intrinsicSupported(function, call)) return false,
            else => return false, // input/output, struct_*, heap_*, object_*
        }
    }
    return true;
}

fn binarySupported(op: ir.Instruction.Binary) bool {
    return switch (op.operand_type) {
        .int => true,
        .string => op.op == .add or op.op.isComparison(),
        .boolean => op.op == .equal or op.op == .not_equal,
        .float => op.op != .remainder, // float % is @rem/fmod: no wasm opcode
        else => false,
    };
}

fn intrinsicSupported(function: *const ir.Function, call: ir.Instruction.IntrinsicCall) bool {
    const argType = struct {
        fn of(fun: *const ir.Function, register: ir.Register) types.Type {
            return fun.result_types[register];
        }
    }.of;
    return switch (call.kind) {
        .assert_true, .trap_message => true,
        .abs => argType(function, call.arguments[0]) == .int or
            argType(function, call.arguments[0]) == .float,
        .min, .max, .clamp => argType(function, call.arguments[0]) == .int,
        .sqrt, .floor, .ceil => argType(function, call.arguments[0]) == .float,
        .len => argType(function, call.arguments[0]) == .string,
        .string_slice, .string_byte, .string_find_byte => true,
        .chr_code, .ord_text, .parse_int => true,
        // str(Float)/parse_float need Zig-exact float<->decimal; deferred.
        .str_value => argType(function, call.arguments[0]) != .float,
        .print => argType(function, call.arguments[0]) == .string,
        else => false,
    };
}

fn valueShaped(of: types.Type) bool {
    return switch (of) {
        .int, .boolean, .float, .string => true,
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
// wasm opcode/value vocabulary
// ---------------------------------------------------------------------------

const wasm = struct {
    const i32t: u8 = 0x7F;
    const i64t: u8 = 0x7E;
    const f64t: u8 = 0x7C;
    const func_type: u8 = 0x60;
    const empty_type: u8 = 0x40; // block/if result: none

    const unreachable_: u8 = 0x00;
    const nop: u8 = 0x01;
    const block: u8 = 0x02;
    const loop: u8 = 0x03;
    const if_: u8 = 0x04;
    const else_: u8 = 0x05;
    const end: u8 = 0x0B;
    const br: u8 = 0x0C;
    const br_if: u8 = 0x0D;
    const br_table: u8 = 0x0E;
    const ret: u8 = 0x0F;
    const call: u8 = 0x10;
    const drop: u8 = 0x1A;
    const select: u8 = 0x1B;

    const local_get: u8 = 0x20;
    const local_set: u8 = 0x21;
    const local_tee: u8 = 0x22;
    const global_get: u8 = 0x23;
    const global_set: u8 = 0x24;

    const i32_load: u8 = 0x28;
    const i64_load: u8 = 0x29;
    const i32_load8_u: u8 = 0x2D;
    const i32_store: u8 = 0x36;
    const i64_store: u8 = 0x37;
    const i32_store8: u8 = 0x3A;
    const memory_size: u8 = 0x3F;
    const memory_grow: u8 = 0x40;

    const i32_const: u8 = 0x41;
    const i64_const: u8 = 0x42;
    const f64_const: u8 = 0x44;

    const i32_eqz: u8 = 0x45;
    const i32_eq: u8 = 0x46;
    const i32_ne: u8 = 0x47;
    const i32_lt_s: u8 = 0x48;
    const i32_lt_u: u8 = 0x49;
    const i32_gt_s: u8 = 0x4A;
    const i32_gt_u: u8 = 0x4B;
    const i32_le_s: u8 = 0x4C;
    const i32_le_u: u8 = 0x4D;
    const i32_ge_s: u8 = 0x4E;
    const i32_ge_u: u8 = 0x4F;

    const i64_eqz: u8 = 0x50;
    const i64_eq: u8 = 0x51;
    const i64_ne: u8 = 0x52;
    const i64_lt_s: u8 = 0x53;
    const i64_lt_u: u8 = 0x54;
    const i64_gt_s: u8 = 0x55;
    const i64_le_s: u8 = 0x57;
    const i64_ge_s: u8 = 0x59;

    const i32_add: u8 = 0x6A;
    const i32_sub: u8 = 0x6B;
    const i32_mul: u8 = 0x6C;
    const i32_and: u8 = 0x71;
    const i32_or: u8 = 0x72;
    const i32_shl: u8 = 0x74;
    const i32_shr_u: u8 = 0x76;

    const i64_add: u8 = 0x7C;
    const i64_sub: u8 = 0x7D;
    const i64_mul: u8 = 0x7E;
    const i64_div_s: u8 = 0x7F;
    const i64_div_u: u8 = 0x80;
    const i64_rem_s: u8 = 0x81;
    const i64_rem_u: u8 = 0x82;
    const i64_and: u8 = 0x83;
    const i64_or: u8 = 0x84;
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

    const i32_wrap_i64: u8 = 0xA7;
    const i64_extend_i32_s: u8 = 0xAC;
    const i64_extend_i32_u: u8 = 0xAD;
    const i64_trunc_f64_s: u8 = 0xB0;
    const f64_convert_i64_s: u8 = 0xB9;

    const misc: u8 = 0xFC; // prefix for memory.copy/fill
    const memory_copy_sub: u8 = 0x0A;
    const memory_fill_sub: u8 = 0x0B;
};

// Imports (function indices 0 and 1).
const import_emit = 0; // emit_str(i32 ptr, i32 len)
const import_trap = 1; // trap(i32 code)
const import_count = 2;

// Globals.
const depth_global = 0; // i64: the call-depth budget
const heap_global = 1; // i32: the bump pointer

/// The call-depth budget the module traps at — the same value loom runs
/// every engine with (`native.max_call_depth`); checked in the tests.
const call_depth_budget: i64 = 128;

/// Int(Float)'s guard boundaries, matching the interpreter: NaN or
/// outside [-2^63, 2^63) traps conversion_range.
const int_min_as_float: f64 = -9223372036854775808.0;
const int_max_as_float: f64 = 9223372036854775808.0;

fn valType(of: types.Type) u8 {
    return switch (of) {
        .int => wasm.i64t,
        .float => wasm.f64t,
        else => wasm.i32t, // boolean, string (address), none/other placeholders
    };
}

// ---------------------------------------------------------------------------
// Asm — the low-level wasm byte emitter shared by the runtime prelude and
// the per-function lowering.
// ---------------------------------------------------------------------------

const Asm = struct {
    arena: Allocator,
    code: std.ArrayList(u8) = .empty,

    fn op(self: *Asm, code: u8) !void {
        try self.code.append(self.arena, code);
    }
    fn u32v(self: *Asm, value: u32) !void {
        var v = value;
        while (true) {
            var byte: u8 = @intCast(v & 0x7F);
            v >>= 7;
            if (v != 0) byte |= 0x80;
            try self.code.append(self.arena, byte);
            if (v == 0) break;
        }
    }
    fn i64v(self: *Asm, value: i64) !void {
        var v = value;
        while (true) {
            const low: u8 = @bitCast(@as(i8, @truncate(v)));
            var byte: u8 = low & 0x7F;
            v >>= 7;
            const sign = byte & 0x40;
            if ((v == 0 and sign == 0) or (v == -1 and sign != 0)) {
                try self.code.append(self.arena, byte);
                break;
            }
            byte |= 0x80;
            try self.code.append(self.arena, byte);
        }
    }
    fn constI32(self: *Asm, value: i32) !void {
        try self.op(wasm.i32_const);
        try self.i64v(value);
    }
    fn constI64(self: *Asm, value: i64) !void {
        try self.op(wasm.i64_const);
        try self.i64v(value);
    }
    fn constF64(self: *Asm, value: f64) !void {
        try self.op(wasm.f64_const);
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, @bitCast(value), .little);
        try self.code.appendSlice(self.arena, &bytes);
    }
    fn localGet(self: *Asm, index: u32) !void {
        try self.op(wasm.local_get);
        try self.u32v(index);
    }
    fn localSet(self: *Asm, index: u32) !void {
        try self.op(wasm.local_set);
        try self.u32v(index);
    }
    fn localTee(self: *Asm, index: u32) !void {
        try self.op(wasm.local_tee);
        try self.u32v(index);
    }
    fn globalGet(self: *Asm, index: u32) !void {
        try self.op(wasm.global_get);
        try self.u32v(index);
    }
    fn globalSet(self: *Asm, index: u32) !void {
        try self.op(wasm.global_set);
        try self.u32v(index);
    }
    fn callFunc(self: *Asm, func: u32) !void {
        try self.op(wasm.call);
        try self.u32v(func);
    }
    /// A memory load/store: address (and value, for stores) already on
    /// the stack.  Alignment hint 0 (byte-aligned) is always valid;
    /// `offset` folds a constant displacement in.
    fn load(self: *Asm, code: u8, offset: u32) !void {
        try self.op(code);
        try self.u32v(0);
        try self.u32v(offset);
    }
    fn store(self: *Asm, code: u8, offset: u32) !void {
        try self.op(code);
        try self.u32v(0);
        try self.u32v(offset);
    }
    fn memoryCopy(self: *Asm) !void { // dest, src, len on stack
        try self.op(wasm.misc);
        try self.u32v(wasm.memory_copy_sub);
        try self.op(0x00);
        try self.op(0x00);
    }

    /// Trap with a Luce code, then `unreachable` (stack-polymorphic, so
    /// this is valid mid-expression in a value-returning function).
    fn trap(self: *Asm, code: ir.TrapCode) !void {
        try self.constI32(@intFromEnum(code));
        try self.callFunc(import_trap);
        try self.op(wasm.unreachable_);
    }
    /// <i32 condition on the stack>, then trap(code) when it is true.
    fn trapIf(self: *Asm, code: ir.TrapCode) !void {
        try self.op(wasm.if_);
        try self.op(wasm.empty_type);
        try self.trap(code);
        try self.op(wasm.end);
    }
};

// ---------------------------------------------------------------------------
// The runtime prelude — hand-emitted wasm functions owning memory and the
// string primitives.  Indices are import_count + Rt(enum value).
// ---------------------------------------------------------------------------

const Rt = enum(u32) {
    alloc, // (i32 size) -> i32
    str_new, // (i32 len) -> i32   (allocate a block, write len, bytes uninit)
    str_from_i64, // (i64) -> i32
    str_concat, // (i32 a, i32 b) -> i32
    str_cmp, // (i32 a, i32 b) -> i32   (-1/0/1)
    str_slice, // (i32 s, i64 start, i64 end) -> i32
    str_byte, // (i32 s, i64 index) -> i64
    str_find, // (i32 s, i64 byte, i64 start) -> i64
    chr, // (i64 code) -> i32
    ord, // (i32 s) -> i64
    parse_int, // (i32 s) -> i64

    const count: u32 = @typeInfo(Rt).@"enum".fields.len;

    fn index(self: Rt) u32 {
        return import_count + @intFromEnum(self);
    }
};

/// The (params, result) signature of each runtime function, as wasm
/// valtypes — parallel to the Rt enum order.
const RtSig = struct { params: []const u8, result: ?u8 };
const rt_signatures = [_]RtSig{
    .{ .params = &.{wasm.i32t}, .result = wasm.i32t }, // alloc
    .{ .params = &.{wasm.i32t}, .result = wasm.i32t }, // str_new
    .{ .params = &.{wasm.i64t}, .result = wasm.i32t }, // str_from_i64
    .{ .params = &.{ wasm.i32t, wasm.i32t }, .result = wasm.i32t }, // str_concat
    .{ .params = &.{ wasm.i32t, wasm.i32t }, .result = wasm.i32t }, // str_cmp
    .{ .params = &.{ wasm.i32t, wasm.i64t, wasm.i64t }, .result = wasm.i32t }, // str_slice
    .{ .params = &.{ wasm.i32t, wasm.i64t }, .result = wasm.i64t }, // str_byte
    .{ .params = &.{ wasm.i32t, wasm.i64t, wasm.i64t }, .result = wasm.i64t }, // str_find
    .{ .params = &.{wasm.i64t}, .result = wasm.i32t }, // chr
    .{ .params = &.{wasm.i32t}, .result = wasm.i64t }, // ord
    .{ .params = &.{wasm.i32t}, .result = wasm.i64t }, // parse_int
};

/// Emit one runtime function's body (locals + code).  Written in the
/// same op vocabulary as the compiled functions; the extra locals each
/// declares are appended after its parameters.
fn emitRuntime(arena: Allocator, which: Rt) ![]const u8 {
    var a: Asm = .{ .arena = arena };
    var locals: std.ArrayList(u8) = .empty; // extra local valtypes, in order
    switch (which) {
        .alloc => {
            // params: size(0).  locals: result(1).
            try locals.append(arena, wasm.i32t);
            const size = 0;
            const result = 1;
            // result = heap_ptr
            try a.globalGet(heap_global);
            try a.localSet(result);
            // heap_ptr = result + ((size + 7) & ~7)
            try a.localGet(result);
            try a.localGet(size);
            try a.constI32(7);
            try a.op(wasm.i32_add);
            try a.constI32(-8);
            try a.op(wasm.i32_and);
            try a.op(wasm.i32_add);
            try a.globalSet(heap_global);
            // grow memory until it covers heap_ptr
            try a.op(wasm.block);
            try a.op(wasm.empty_type);
            try a.op(wasm.loop);
            try a.op(wasm.empty_type);
            try a.globalGet(heap_global);
            try a.op(wasm.memory_size);
            try a.op(0x00);
            try a.constI32(16); // << 16 == * 65536
            try a.op(wasm.i32_shl);
            try a.op(wasm.i32_le_u);
            try a.op(wasm.br_if);
            try a.u32v(1); // done
            try a.constI32(1);
            try a.op(wasm.memory_grow);
            try a.op(0x00);
            try a.op(wasm.drop);
            try a.op(wasm.br);
            try a.u32v(0); // loop
            try a.op(wasm.end); // loop
            try a.op(wasm.end); // block
            try a.localGet(result);
        },
        .str_new => {
            // params: len(0).  locals: ptr(1).
            try locals.append(arena, wasm.i32t);
            const len = 0;
            const ptr = 1;
            try a.localGet(len);
            try a.constI32(4);
            try a.op(wasm.i32_add);
            try a.callFunc(Rt.alloc.index());
            try a.localTee(ptr);
            try a.localGet(len);
            try a.store(wasm.i32_store, 0);
            try a.localGet(ptr);
        },
        .str_from_i64 => {
            // params: v(0).  locals: mag(1,i64), count(2,i32), ptr(3,i32),
            // w(4,i32), t(5,i64).
            try locals.appendSlice(arena, &.{ wasm.i64t, wasm.i32t, wasm.i32t, wasm.i32t, wasm.i64t });
            const v = 0;
            const mag = 1;
            const count = 2;
            const ptr = 3;
            const w = 4;
            const t = 5;
            // mag = v < 0 ? (0 - v) : v   (0 - MIN wraps to |MIN| unsigned)
            try a.constI64(0);
            try a.localGet(v);
            try a.op(wasm.i64_sub);
            try a.localGet(v);
            try a.localGet(v);
            try a.constI64(0);
            try a.op(wasm.i64_lt_s);
            try a.op(wasm.select);
            try a.localSet(mag);
            // count = 0; t = mag; do { count++; t /u= 10 } while t != 0
            try a.constI32(0);
            try a.localSet(count);
            try a.localGet(mag);
            try a.localSet(t);
            try a.op(wasm.loop);
            try a.op(wasm.empty_type);
            try a.localGet(count);
            try a.constI32(1);
            try a.op(wasm.i32_add);
            try a.localSet(count);
            try a.localGet(t);
            try a.constI64(10);
            try a.op(wasm.i64_div_u);
            try a.localTee(t);
            try a.constI64(0);
            try a.op(wasm.i64_ne);
            try a.op(wasm.br_if);
            try a.u32v(0);
            try a.op(wasm.end);
            // total length = count + (v < 0 ? 1 : 0); ptr = str_new(len)
            try a.localGet(count);
            try a.localGet(v);
            try a.constI64(0);
            try a.op(wasm.i64_lt_s);
            try a.op(wasm.i32_add); // count + (v<0)
            try a.callFunc(Rt.str_new.index());
            try a.localSet(ptr);
            // w = ptr + 4 + len ; write digits backwards from mag
            try a.localGet(ptr);
            try a.constI32(4);
            try a.op(wasm.i32_add);
            try a.localGet(ptr);
            try a.load(wasm.i32_load, 0); // len
            try a.op(wasm.i32_add);
            try a.localSet(w);
            try a.localGet(mag);
            try a.localSet(t);
            try a.op(wasm.loop);
            try a.op(wasm.empty_type);
            try a.localGet(w);
            try a.constI32(1);
            try a.op(wasm.i32_sub);
            try a.localTee(w);
            // digit byte = '0' + (t %u 10)
            try a.localGet(t);
            try a.constI64(10);
            try a.op(wasm.i64_rem_u);
            try a.op(wasm.i32_wrap_i64);
            try a.constI32('0');
            try a.op(wasm.i32_add);
            try a.store(wasm.i32_store8, 0);
            try a.localGet(t);
            try a.constI64(10);
            try a.op(wasm.i64_div_u);
            try a.localTee(t);
            try a.constI64(0);
            try a.op(wasm.i64_ne);
            try a.op(wasm.br_if);
            try a.u32v(0);
            try a.op(wasm.end);
            // if v < 0: store '-' at ptr + 4
            try a.localGet(v);
            try a.constI64(0);
            try a.op(wasm.i64_lt_s);
            try a.op(wasm.if_);
            try a.op(wasm.empty_type);
            try a.localGet(ptr);
            try a.constI32('-');
            try a.store(wasm.i32_store8, 4);
            try a.op(wasm.end);
            try a.localGet(ptr);
        },
        .str_concat => {
            // params: aa(0), bb(1).  locals: la(2), lb(3), ptr(4).
            try locals.appendSlice(arena, &.{ wasm.i32t, wasm.i32t, wasm.i32t });
            const aa = 0;
            const bb = 1;
            const la = 2;
            const lb = 3;
            const ptr = 4;
            try a.localGet(aa);
            try a.load(wasm.i32_load, 0);
            try a.localSet(la);
            try a.localGet(bb);
            try a.load(wasm.i32_load, 0);
            try a.localSet(lb);
            try a.localGet(la);
            try a.localGet(lb);
            try a.op(wasm.i32_add);
            try a.callFunc(Rt.str_new.index());
            try a.localSet(ptr);
            // memcpy(ptr+4, aa+4, la)
            try a.localGet(ptr);
            try a.constI32(4);
            try a.op(wasm.i32_add);
            try a.localGet(aa);
            try a.constI32(4);
            try a.op(wasm.i32_add);
            try a.localGet(la);
            try a.memoryCopy();
            // memcpy(ptr+4+la, bb+4, lb)
            try a.localGet(ptr);
            try a.constI32(4);
            try a.op(wasm.i32_add);
            try a.localGet(la);
            try a.op(wasm.i32_add);
            try a.localGet(bb);
            try a.constI32(4);
            try a.op(wasm.i32_add);
            try a.localGet(lb);
            try a.memoryCopy();
            try a.localGet(ptr);
        },
        .str_cmp => {
            // params: aa(0), bb(1).  locals: la(2), lb(3), n(4), i(5), ca(6), cb(7).
            try locals.appendSlice(arena, &.{ wasm.i32t, wasm.i32t, wasm.i32t, wasm.i32t, wasm.i32t, wasm.i32t });
            const aa = 0;
            const bb = 1;
            const la = 2;
            const lb = 3;
            const n = 4;
            const i = 5;
            const ca = 6;
            const cb = 7;
            try a.localGet(aa);
            try a.load(wasm.i32_load, 0);
            try a.localSet(la);
            try a.localGet(bb);
            try a.load(wasm.i32_load, 0);
            try a.localSet(lb);
            // n = min(la, lb)
            try a.localGet(la);
            try a.localGet(lb);
            try a.localGet(la);
            try a.localGet(lb);
            try a.op(wasm.i32_lt_u);
            try a.op(wasm.select);
            try a.localSet(n);
            try a.constI32(0);
            try a.localSet(i);
            // for i in 0..n: compare bytes
            try a.op(wasm.block);
            try a.op(wasm.empty_type);
            try a.op(wasm.loop);
            try a.op(wasm.empty_type);
            try a.localGet(i);
            try a.localGet(n);
            try a.op(wasm.i32_ge_u);
            try a.op(wasm.br_if);
            try a.u32v(1); // break to after-loop
            try a.localGet(aa);
            try a.constI32(4);
            try a.op(wasm.i32_add);
            try a.localGet(i);
            try a.op(wasm.i32_add);
            try a.load(wasm.i32_load8_u, 0);
            try a.localSet(ca);
            try a.localGet(bb);
            try a.constI32(4);
            try a.op(wasm.i32_add);
            try a.localGet(i);
            try a.op(wasm.i32_add);
            try a.load(wasm.i32_load8_u, 0);
            try a.localSet(cb);
            // if ca < cb: return -1
            try a.localGet(ca);
            try a.localGet(cb);
            try a.op(wasm.i32_lt_u);
            try a.op(wasm.if_);
            try a.op(wasm.empty_type);
            try a.constI32(-1);
            try a.op(wasm.ret);
            try a.op(wasm.end);
            // if ca > cb: return 1
            try a.localGet(ca);
            try a.localGet(cb);
            try a.op(wasm.i32_gt_u);
            try a.op(wasm.if_);
            try a.op(wasm.empty_type);
            try a.constI32(1);
            try a.op(wasm.ret);
            try a.op(wasm.end);
            try a.localGet(i);
            try a.constI32(1);
            try a.op(wasm.i32_add);
            try a.localSet(i);
            try a.op(wasm.br);
            try a.u32v(0);
            try a.op(wasm.end); // loop
            try a.op(wasm.end); // block
            // prefixes equal: shorter is less
            try a.localGet(la);
            try a.localGet(lb);
            try a.op(wasm.i32_lt_u);
            try a.op(wasm.if_);
            try a.op(wasm.empty_type);
            try a.constI32(-1);
            try a.op(wasm.ret);
            try a.op(wasm.end);
            try a.localGet(la);
            try a.localGet(lb);
            try a.op(wasm.i32_gt_u);
            try a.op(wasm.if_);
            try a.op(wasm.empty_type);
            try a.constI32(1);
            try a.op(wasm.ret);
            try a.op(wasm.end);
            try a.constI32(0);
        },
        .str_slice => {
            // params: s(0,i32), start(1,i64), end(2,i64).
            // locals: len(3,i64), si(4,i32), ei(5,i32), newlen(6,i32), ptr(7,i32).
            try locals.appendSlice(arena, &.{ wasm.i64t, wasm.i32t, wasm.i32t, wasm.i32t, wasm.i32t });
            const s = 0;
            const start = 1;
            const end = 2;
            const len = 3;
            const si = 4;
            const ei = 5;
            const newlen = 6;
            const ptr = 7;
            try a.localGet(s);
            try a.load(wasm.i32_load, 0);
            try a.op(wasm.i64_extend_i32_u);
            try a.localSet(len);
            // start<0 or end<start or end>len -> string_bounds
            try a.localGet(start);
            try a.constI64(0);
            try a.op(wasm.i64_lt_s);
            try a.localGet(end);
            try a.localGet(start);
            try a.op(wasm.i64_lt_s);
            try a.op(wasm.i32_or);
            try a.localGet(end);
            try a.localGet(len);
            try a.op(wasm.i64_gt_s);
            try a.op(wasm.i32_or);
            try a.trapIf(.string_bounds);
            try a.localGet(start);
            try a.op(wasm.i32_wrap_i64);
            try a.localSet(si);
            try a.localGet(end);
            try a.op(wasm.i32_wrap_i64);
            try a.localSet(ei);
            // boundary(s, si) and boundary(s, ei)
            try emitBoundaryTrap(&a, s, si);
            try emitBoundaryTrap(&a, s, ei);
            try a.localGet(ei);
            try a.localGet(si);
            try a.op(wasm.i32_sub);
            try a.localSet(newlen);
            try a.localGet(newlen);
            try a.callFunc(Rt.str_new.index());
            try a.localSet(ptr);
            try a.localGet(ptr);
            try a.constI32(4);
            try a.op(wasm.i32_add);
            try a.localGet(s);
            try a.constI32(4);
            try a.op(wasm.i32_add);
            try a.localGet(si);
            try a.op(wasm.i32_add);
            try a.localGet(newlen);
            try a.memoryCopy();
            try a.localGet(ptr);
        },
        .str_byte => {
            // params: s(0), index(1,i64).  locals: len(2,i64).
            try locals.append(arena, wasm.i64t);
            const s = 0;
            const index = 1;
            const len = 2;
            try a.localGet(s);
            try a.load(wasm.i32_load, 0);
            try a.op(wasm.i64_extend_i32_u);
            try a.localSet(len);
            try a.localGet(index);
            try a.constI64(0);
            try a.op(wasm.i64_lt_s);
            try a.localGet(index);
            try a.localGet(len);
            try a.op(wasm.i64_ge_s);
            try a.op(wasm.i32_or);
            try a.trapIf(.string_bounds);
            try a.localGet(s);
            try a.constI32(4);
            try a.op(wasm.i32_add);
            try a.localGet(index);
            try a.op(wasm.i32_wrap_i64);
            try a.op(wasm.i32_add);
            try a.load(wasm.i32_load8_u, 0);
            try a.op(wasm.i64_extend_i32_u);
        },
        .str_find => {
            // params: s(0), byte(1,i64), start(2,i64).
            // locals: len(3,i64), i(4,i32), stop(5,i32).
            try locals.appendSlice(arena, &.{ wasm.i64t, wasm.i32t, wasm.i32t });
            const s = 0;
            const byte = 1;
            const start = 2;
            const len = 3;
            const i = 4;
            const stop = 5;
            try a.localGet(byte);
            try a.constI64(0);
            try a.op(wasm.i64_lt_s);
            try a.localGet(byte);
            try a.constI64(0xFF);
            try a.op(wasm.i64_gt_s);
            try a.op(wasm.i32_or);
            try a.trapIf(.bad_codepoint);
            try a.localGet(s);
            try a.load(wasm.i32_load, 0);
            try a.op(wasm.i64_extend_i32_u);
            try a.localSet(len);
            try a.localGet(start);
            try a.constI64(0);
            try a.op(wasm.i64_lt_s);
            try a.localGet(start);
            try a.localGet(len);
            try a.op(wasm.i64_gt_s);
            try a.op(wasm.i32_or);
            try a.trapIf(.string_bounds);
            try a.localGet(start);
            try a.op(wasm.i32_wrap_i64);
            try a.localSet(i);
            try a.localGet(len);
            try a.op(wasm.i32_wrap_i64);
            try a.localSet(stop);
            try a.op(wasm.block);
            try a.op(wasm.empty_type);
            try a.op(wasm.loop);
            try a.op(wasm.empty_type);
            try a.localGet(i);
            try a.localGet(stop);
            try a.op(wasm.i32_ge_u);
            try a.op(wasm.br_if);
            try a.u32v(1);
            // if byte at s+4+i == byte: return i
            try a.localGet(s);
            try a.constI32(4);
            try a.op(wasm.i32_add);
            try a.localGet(i);
            try a.op(wasm.i32_add);
            try a.load(wasm.i32_load8_u, 0);
            try a.op(wasm.i64_extend_i32_u);
            try a.localGet(byte);
            try a.op(wasm.i64_eq);
            try a.op(wasm.if_);
            try a.op(wasm.empty_type);
            try a.localGet(i);
            try a.op(wasm.i64_extend_i32_u);
            try a.op(wasm.ret);
            try a.op(wasm.end);
            try a.localGet(i);
            try a.constI32(1);
            try a.op(wasm.i32_add);
            try a.localSet(i);
            try a.op(wasm.br);
            try a.u32v(0);
            try a.op(wasm.end);
            try a.op(wasm.end);
            try a.constI64(-1);
        },
        .chr => {
            // params: code(0,i64).  locals: c(1,i32), ptr(2,i32).
            try locals.appendSlice(arena, &.{ wasm.i32t, wasm.i32t });
            try emitChr(&a);
        },
        .ord => {
            // params: s(0,i32).  locals: len(1,i32), b0(2,i32), seqlen(3,i32), cp(4,i32).
            try locals.appendSlice(arena, &.{ wasm.i32t, wasm.i32t, wasm.i32t, wasm.i32t });
            try emitOrd(&a);
        },
        .parse_int => {
            // params: s(0,i32).  locals: len(1), i(2), neg(3), acc(4,i64), digit(5,i32), any(6).
            try locals.appendSlice(arena, &.{ wasm.i32t, wasm.i32t, wasm.i32t, wasm.i64t, wasm.i32t, wasm.i32t });
            try emitParseInt(&a);
        },
    }
    try a.op(wasm.end); // end function body

    // Assemble: local declarations (run-length encoded) then code.
    var out: std.ArrayList(u8) = .empty;
    try appendRunLength(&out, arena, locals.items);
    try out.appendSlice(arena, a.code.items);
    return out.items;
}

/// Trap string_boundary unless `index` sits on a UTF-8 boundary of the
/// string at `s`: index == len, or the byte there is not a continuation
/// byte (top bits != 0b10).  `s` and `index` are locals.
fn emitBoundaryTrap(a: *Asm, s: u32, index: u32) !void {
    // ok = (index == len) | ((byte[s+4+index] & 0xC0) != 0x80)
    try a.localGet(index);
    try a.localGet(s);
    try a.load(wasm.i32_load, 0);
    try a.op(wasm.i32_eq); // index == len
    try a.localGet(s);
    try a.constI32(4);
    try a.op(wasm.i32_add);
    try a.localGet(index);
    try a.op(wasm.i32_add);
    try a.load(wasm.i32_load8_u, 0);
    try a.constI32(0xC0);
    try a.op(wasm.i32_and);
    try a.constI32(0x80);
    try a.op(wasm.i32_ne); // not a continuation byte
    try a.op(wasm.i32_or);
    try a.op(wasm.i32_eqz); // trap when NOT ok
    try a.trapIf(.string_boundary);
}

/// UTF-8 encode a codepoint (rt_chr body).  Matches std.unicode: the
/// valid range is [0, 0x10FFFF] minus the surrogates [0xD800, 0xDFFF].
fn emitChr(a: *Asm) !void {
    const code = 0; // i64
    const c = 1; // i32 codepoint
    const ptr = 2; // i32
    // range/surrogate check -> bad_codepoint
    try a.localGet(code);
    try a.constI64(0);
    try a.op(wasm.i64_lt_s);
    try a.localGet(code);
    try a.constI64(0x10FFFF);
    try a.op(wasm.i64_gt_s);
    try a.op(wasm.i32_or);
    try a.trapIf(.bad_codepoint);
    try a.localGet(code);
    try a.constI64(0xD800);
    try a.op(wasm.i64_ge_s);
    try a.localGet(code);
    try a.constI64(0xDFFF);
    try a.op(wasm.i64_le_s);
    try a.op(wasm.i32_and);
    try a.trapIf(.bad_codepoint);
    try a.localGet(code);
    try a.op(wasm.i32_wrap_i64);
    try a.localSet(c);
    // 1 byte: c < 0x80
    try a.localGet(c);
    try a.constI32(0x80);
    try a.op(wasm.i32_lt_u);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.constI32(1);
    try a.callFunc(Rt.str_new.index());
    try a.localTee(ptr);
    try a.localGet(c);
    try a.store(wasm.i32_store8, 4);
    try a.localGet(ptr);
    try a.op(wasm.ret);
    try a.op(wasm.end);
    // 2 bytes: c < 0x800
    try a.localGet(c);
    try a.constI32(0x800);
    try a.op(wasm.i32_lt_u);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.constI32(2);
    try a.callFunc(Rt.str_new.index());
    try a.localSet(ptr);
    // byte0 = 0xC0 | (c >> 6)
    try a.localGet(ptr);
    try a.constI32(0xC0);
    try a.localGet(c);
    try a.constI32(6);
    try a.op(wasm.i32_shr_u);
    try a.op(wasm.i32_or);
    try a.store(wasm.i32_store8, 4);
    // byte1 = 0x80 | (c & 0x3F)
    try a.localGet(ptr);
    try a.constI32(0x80);
    try a.localGet(c);
    try a.constI32(0x3F);
    try a.op(wasm.i32_and);
    try a.op(wasm.i32_or);
    try a.store(wasm.i32_store8, 5);
    try a.localGet(ptr);
    try a.op(wasm.ret);
    try a.op(wasm.end);
    // 3 bytes: c < 0x10000
    try a.localGet(c);
    try a.constI32(0x10000);
    try a.op(wasm.i32_lt_u);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.constI32(3);
    try a.callFunc(Rt.str_new.index());
    try a.localSet(ptr);
    try a.localGet(ptr);
    try a.constI32(0xE0);
    try a.localGet(c);
    try a.constI32(12);
    try a.op(wasm.i32_shr_u);
    try a.op(wasm.i32_or);
    try a.store(wasm.i32_store8, 4);
    try a.localGet(ptr);
    try a.constI32(0x80);
    try a.localGet(c);
    try a.constI32(6);
    try a.op(wasm.i32_shr_u);
    try a.constI32(0x3F);
    try a.op(wasm.i32_and);
    try a.op(wasm.i32_or);
    try a.store(wasm.i32_store8, 5);
    try a.localGet(ptr);
    try a.constI32(0x80);
    try a.localGet(c);
    try a.constI32(0x3F);
    try a.op(wasm.i32_and);
    try a.op(wasm.i32_or);
    try a.store(wasm.i32_store8, 6);
    try a.localGet(ptr);
    try a.op(wasm.ret);
    try a.op(wasm.end);
    // 4 bytes
    try a.constI32(4);
    try a.callFunc(Rt.str_new.index());
    try a.localSet(ptr);
    try a.localGet(ptr);
    try a.constI32(0xF0);
    try a.localGet(c);
    try a.constI32(18);
    try a.op(wasm.i32_shr_u);
    try a.op(wasm.i32_or);
    try a.store(wasm.i32_store8, 4);
    try a.localGet(ptr);
    try a.constI32(0x80);
    try a.localGet(c);
    try a.constI32(12);
    try a.op(wasm.i32_shr_u);
    try a.constI32(0x3F);
    try a.op(wasm.i32_and);
    try a.op(wasm.i32_or);
    try a.store(wasm.i32_store8, 5);
    try a.localGet(ptr);
    try a.constI32(0x80);
    try a.localGet(c);
    try a.constI32(6);
    try a.op(wasm.i32_shr_u);
    try a.constI32(0x3F);
    try a.op(wasm.i32_and);
    try a.op(wasm.i32_or);
    try a.store(wasm.i32_store8, 6);
    try a.localGet(ptr);
    try a.constI32(0x80);
    try a.localGet(c);
    try a.constI32(0x3F);
    try a.op(wasm.i32_and);
    try a.op(wasm.i32_or);
    try a.store(wasm.i32_store8, 7);
    try a.localGet(ptr);
}

/// UTF-8 decode the first codepoint of `s` (rt_ord body).  Mirrors
/// std.unicode: the leading byte fixes the sequence length, continuation
/// bytes must be 0b10xxxxxx, and the result must be neither overlong nor
/// a surrogate — any violation traps bad_codepoint.
fn emitOrd(a: *Asm) !void {
    const s = 0;
    const len = 1;
    const b0 = 2;
    const seqlen = 3;
    const cp = 4;
    try a.localGet(s);
    try a.load(wasm.i32_load, 0);
    try a.localTee(len);
    try a.op(wasm.i32_eqz);
    try a.trapIf(.bad_codepoint); // empty
    try a.localGet(s);
    try a.load(wasm.i32_load8_u, 4);
    try a.localSet(b0);
    // 1-byte: b0 < 0x80
    try a.localGet(b0);
    try a.constI32(0x80);
    try a.op(wasm.i32_lt_u);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.localGet(b0);
    try a.op(wasm.i64_extend_i32_u);
    try a.op(wasm.ret);
    try a.op(wasm.end);
    // continuation byte or > 0xF7 leading is invalid
    try a.localGet(b0);
    try a.constI32(0xC0);
    try a.op(wasm.i32_lt_u); // 0x80..0xBF are continuations: invalid lead
    try a.localGet(b0);
    try a.constI32(0xF7);
    try a.op(wasm.i32_gt_u);
    try a.op(wasm.i32_or);
    try a.trapIf(.bad_codepoint);
    // seqlen from the leading byte
    try a.localGet(b0);
    try a.constI32(0xE0);
    try a.op(wasm.i32_lt_u);
    try a.op(wasm.if_);
    try a.op(wasm.i32t);
    try a.constI32(2);
    try a.op(wasm.else_);
    try a.localGet(b0);
    try a.constI32(0xF0);
    try a.op(wasm.i32_lt_u);
    try a.op(wasm.if_);
    try a.op(wasm.i32t);
    try a.constI32(3);
    try a.op(wasm.else_);
    try a.constI32(4);
    try a.op(wasm.end);
    try a.op(wasm.end);
    try a.localSet(seqlen);
    // len must cover seqlen
    try a.localGet(len);
    try a.localGet(seqlen);
    try a.op(wasm.i32_lt_u);
    try a.trapIf(.bad_codepoint);
    // validate continuation bytes and build cp
    try emitDecodeTail(a, s, b0, seqlen, cp, len);
    try a.localGet(cp);
    try a.op(wasm.i64_extend_i32_u);
}

/// The multi-byte decode shared branches of rt_ord: fold the seqlen-1
/// continuation bytes into cp, trapping bad_codepoint on any byte that
/// is not 0b10xxxxxx, then reject overlong encodings and surrogates.
fn emitDecodeTail(a: *Asm, s: u32, b0: u32, seqlen: u32, cp: u32, i_tmp: u32) !void {
    // cp = b0 & (0x7F >> seqlen)  — the leading-byte payload
    try a.localGet(b0);
    try a.constI32(0x7F);
    try a.localGet(seqlen);
    try a.op(wasm.i32_shr_u);
    try a.op(wasm.i32_and);
    try a.localSet(cp);
    // for k in 1..seqlen: byte must be continuation; cp = (cp<<6)|(b&0x3F)
    try a.constI32(1);
    try a.localSet(i_tmp); // reuse i_tmp as loop index k
    try a.op(wasm.block);
    try a.op(wasm.empty_type);
    try a.op(wasm.loop);
    try a.op(wasm.empty_type);
    try a.localGet(i_tmp);
    try a.localGet(seqlen);
    try a.op(wasm.i32_ge_u);
    try a.op(wasm.br_if);
    try a.u32v(1);
    // byte = load8u(s+4+k)
    try a.localGet(s);
    try a.constI32(4);
    try a.op(wasm.i32_add);
    try a.localGet(i_tmp);
    try a.op(wasm.i32_add);
    try a.load(wasm.i32_load8_u, 0);
    // (byte & 0xC0) != 0x80 -> bad
    try a.localTee(b0); // reuse b0 to hold current byte
    try a.constI32(0xC0);
    try a.op(wasm.i32_and);
    try a.constI32(0x80);
    try a.op(wasm.i32_ne);
    try a.trapIf(.bad_codepoint);
    try a.localGet(cp);
    try a.constI32(6);
    try a.op(wasm.i32_shl);
    try a.localGet(b0);
    try a.constI32(0x3F);
    try a.op(wasm.i32_and);
    try a.op(wasm.i32_or);
    try a.localSet(cp);
    try a.localGet(i_tmp);
    try a.constI32(1);
    try a.op(wasm.i32_add);
    try a.localSet(i_tmp);
    try a.op(wasm.br);
    try a.u32v(0);
    try a.op(wasm.end);
    try a.op(wasm.end);
    // overlong / range / surrogate rejection by seqlen
    // seqlen==2: cp >= 0x80 ; ==3: cp in [0x800,0xFFFF] not surrogate ;
    // ==4: cp in [0x10000,0x10FFFF]
    try a.localGet(seqlen);
    try a.constI32(2);
    try a.op(wasm.i32_eq);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.localGet(cp);
    try a.constI32(0x80);
    try a.op(wasm.i32_lt_u);
    try a.trapIf(.bad_codepoint);
    try a.op(wasm.end);
    try a.localGet(seqlen);
    try a.constI32(3);
    try a.op(wasm.i32_eq);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.localGet(cp);
    try a.constI32(0x800);
    try a.op(wasm.i32_lt_u);
    try a.localGet(cp);
    try a.constI32(0xD800);
    try a.op(wasm.i32_ge_u);
    try a.localGet(cp);
    try a.constI32(0xDFFF);
    try a.op(wasm.i32_le_u);
    try a.op(wasm.i32_and);
    try a.op(wasm.i32_or);
    try a.trapIf(.bad_codepoint);
    try a.op(wasm.end);
    try a.localGet(seqlen);
    try a.constI32(4);
    try a.op(wasm.i32_eq);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.localGet(cp);
    try a.constI32(0x10000);
    try a.op(wasm.i32_lt_u);
    try a.localGet(cp);
    try a.constI32(0x10FFFF);
    try a.op(wasm.i32_gt_u);
    try a.op(wasm.i32_or);
    try a.trapIf(.bad_codepoint);
    try a.op(wasm.end);
}

/// parse_int (rt_parse_int body): base-10 with an optional leading
/// sign, matching std.fmt.parseInt(i64, .., 10) for the shapes Luce
/// programs produce — sign, then one or more ASCII digits, with `_`
/// permitted between digits.  Empty, a stray character, a lone sign, a
/// misplaced `_`, or i64 overflow all trap parse_failed.
fn emitParseInt(a: *Asm) !void {
    const s = 0;
    const len = 1;
    const i = 2;
    const neg = 3;
    const acc = 4;
    const digit = 5;
    const any = 6;
    try a.localGet(s);
    try a.load(wasm.i32_load, 0);
    try a.localSet(len);
    try a.constI32(0);
    try a.localSet(i);
    try a.constI32(0);
    try a.localSet(neg);
    try a.constI64(0);
    try a.localSet(acc);
    try a.constI32(0);
    try a.localSet(any);
    // empty -> fail
    try a.localGet(len);
    try a.op(wasm.i32_eqz);
    try a.trapIf(.parse_failed);
    // optional sign
    try a.localGet(s);
    try a.load(wasm.i32_load8_u, 4);
    try a.constI32('-');
    try a.op(wasm.i32_eq);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.constI32(1);
    try a.localSet(neg);
    try a.constI32(1);
    try a.localSet(i);
    try a.op(wasm.else_);
    try a.localGet(s);
    try a.load(wasm.i32_load8_u, 4);
    try a.constI32('+');
    try a.op(wasm.i32_eq);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.constI32(1);
    try a.localSet(i);
    try a.op(wasm.end);
    try a.op(wasm.end);
    // digit loop; acc built as a negative magnitude so MIN parses
    try a.op(wasm.block);
    try a.op(wasm.empty_type);
    try a.op(wasm.loop);
    try a.op(wasm.empty_type);
    try a.localGet(i);
    try a.localGet(len);
    try a.op(wasm.i32_ge_u);
    try a.op(wasm.br_if);
    try a.u32v(1);
    try a.localGet(s);
    try a.constI32(4);
    try a.op(wasm.i32_add);
    try a.localGet(i);
    try a.op(wasm.i32_add);
    try a.load(wasm.i32_load8_u, 0);
    try a.localSet(digit);
    // '_' separator: allowed only between digits (any already set)
    try a.localGet(digit);
    try a.constI32('_');
    try a.op(wasm.i32_eq);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.localGet(any);
    try a.op(wasm.i32_eqz);
    try a.trapIf(.parse_failed); // leading '_'
    try a.localGet(i);
    try a.constI32(1);
    try a.op(wasm.i32_add);
    try a.localSet(i);
    try a.op(wasm.br);
    try a.u32v(1); // continue loop
    try a.op(wasm.end);
    // digit < '0' or > '9' -> fail
    try a.localGet(digit);
    try a.constI32('0');
    try a.op(wasm.i32_lt_u);
    try a.localGet(digit);
    try a.constI32('9');
    try a.op(wasm.i32_gt_u);
    try a.op(wasm.i32_or);
    try a.trapIf(.parse_failed);
    try a.constI32(1);
    try a.localSet(any);
    // acc = acc*10 - (digit - '0'); overflow if acc > 0 after (wrapped)
    // Detect overflow: compute acc*10, check for i64 overflow via the
    // guarded check-multiply, then subtract with an overflow check.
    try a.localGet(acc);
    try a.constI64(10);
    try a.op(wasm.i64_mul);
    try a.localGet(digit);
    try a.constI32('0');
    try a.op(wasm.i32_sub);
    try a.op(wasm.i64_extend_i32_u);
    try a.op(wasm.i64_sub);
    try a.localTee(acc);
    // If acc became positive, we overflowed (magnitude only grows).
    try a.constI64(0);
    try a.op(wasm.i64_gt_s);
    try a.trapIf(.parse_failed);
    try a.localGet(i);
    try a.constI32(1);
    try a.op(wasm.i32_add);
    try a.localSet(i);
    try a.op(wasm.br);
    try a.u32v(0);
    try a.op(wasm.end); // loop
    try a.op(wasm.end); // block
    // must have seen a digit; trailing '_' (any stays true) is fine only
    // if the last non-sign char was a digit — enforced by requiring the
    // final char not to be '_'
    try a.localGet(any);
    try a.op(wasm.i32_eqz);
    try a.trapIf(.parse_failed);
    try a.localGet(s);
    try a.constI32(4);
    try a.op(wasm.i32_add);
    try a.localGet(len);
    try a.op(wasm.i32_add);
    try a.constI32(1);
    try a.op(wasm.i32_sub);
    try a.load(wasm.i32_load8_u, 0);
    try a.constI32('_');
    try a.op(wasm.i32_eq);
    try a.trapIf(.parse_failed); // trailing '_'
    // acc holds the negative magnitude.  Positive result = 0 - acc, but
    // acc == MIN means magnitude 2^63 with no sign — out of i64 range.
    try a.localGet(neg);
    try a.op(wasm.if_);
    try a.op(wasm.i64t); // block result: i64
    try a.localGet(acc);
    try a.op(wasm.else_);
    try a.localGet(acc);
    try a.constI64(std.math.minInt(i64));
    try a.op(wasm.i64_eq);
    try a.trapIf(.parse_failed);
    try a.constI64(0);
    try a.localGet(acc);
    try a.op(wasm.i64_sub);
    try a.op(wasm.end);
}

// ---------------------------------------------------------------------------
// Per-function lowering
// ---------------------------------------------------------------------------

const FunctionEmitter = struct {
    a: Asm,
    program: *const ir.Program,
    function: *const ir.Function,
    constant_addr: []const u32, // linear-memory address of each string constant
    true_addr: u32 = 0, // "true"/"false" string blocks, for str(Bool)
    false_addr: u32 = 0,

    pc_local: u32 = 0,
    registers_base: u32 = 0,
    scope_extra: u32 = 0,
    loop_depth: u32 = 0,

    fn regLocal(self: *const FunctionEmitter, register: ir.Register) u32 {
        return self.registers_base + register;
    }
    fn getReg(self: *FunctionEmitter, register: ir.Register) !void {
        try self.a.localGet(self.regLocal(register));
    }
    fn setReg(self: *FunctionEmitter, register: ir.Register) !void {
        try self.a.localSet(self.regLocal(register));
    }

    fn emitDepthEntry(self: *FunctionEmitter) !void {
        try self.a.globalGet(depth_global);
        try self.a.op(wasm.i64_eqz);
        try self.a.trapIf(.call_depth_exceeded);
        try self.a.globalGet(depth_global);
        try self.a.constI64(1);
        try self.a.op(wasm.i64_sub);
        try self.a.globalSet(depth_global);
    }
    fn emitDepthRestore(self: *FunctionEmitter) !void {
        try self.a.globalGet(depth_global);
        try self.a.constI64(1);
        try self.a.op(wasm.i64_add);
        try self.a.globalSet(depth_global);
    }

    fn gotoBlock(self: *FunctionEmitter, block: ir.BlockId) !void {
        try self.a.constI32(@intCast(block));
        try self.a.localSet(self.pc_local);
        try self.a.op(wasm.br);
        try self.a.u32v(self.loop_depth + self.scope_extra);
    }

    fn emitInstruction(self: *FunctionEmitter, item: ir.Register) !void {
        const function = self.function;
        switch (function.instructions[item]) {
            .const_int => |value| {
                try self.a.constI64(value);
                try self.setReg(item);
            },
            .const_boolean => |value| {
                try self.a.constI32(@intFromBool(value));
                try self.setReg(item);
            },
            .const_float => |value| {
                try self.a.constF64(value);
                try self.setReg(item);
            },
            .const_data => |data| {
                try self.a.constI32(@intCast(self.constant_addr[data.constant]));
                try self.setReg(item);
            },
            .local_get => |local| {
                try self.a.localGet(local);
                try self.setReg(item);
            },
            .local_set => |set| {
                try self.getReg(set.value);
                try self.a.localSet(set.local);
            },
            .unary => |operation| try self.emitUnary(item, operation),
            .convert => |operation| try self.emitConvert(item, operation),
            .binary => |operation| try self.emitBinary(item, operation),
            .call => |callee| try self.emitCall(item, callee),
            .intrinsic => |call| try self.emitIntrinsic(item, call),
            .jump => |target| try self.gotoBlock(target),
            .branch => |branching| {
                try self.getReg(branching.condition);
                try self.a.op(wasm.if_);
                try self.a.op(wasm.empty_type);
                self.scope_extra += 1;
                try self.gotoBlock(branching.then_block);
                self.scope_extra -= 1;
                try self.a.op(wasm.end);
                try self.gotoBlock(branching.else_block);
            },
            .ret => |value| {
                if (value) |register| try self.getReg(register);
                try self.a.op(wasm.ret);
            },
            .trap => |code| try self.a.trap(code),
            else => unreachable, // supported() refused the rest
        }
    }

    fn emitUnary(self: *FunctionEmitter, item: ir.Register, operation: anytype) !void {
        switch (operation.op) {
            .negate => switch (self.function.result_types[operation.operand]) {
                .float => {
                    try self.getReg(operation.operand);
                    try self.a.op(wasm.f64_neg);
                    try self.setReg(item);
                },
                else => {
                    try self.getReg(operation.operand);
                    try self.a.constI64(std.math.minInt(i64));
                    try self.a.op(wasm.i64_eq);
                    try self.a.trapIf(.integer_overflow);
                    try self.a.constI64(0);
                    try self.getReg(operation.operand);
                    try self.a.op(wasm.i64_sub);
                    try self.setReg(item);
                },
            },
            .logic_not => {
                try self.getReg(operation.operand);
                try self.a.op(wasm.i32_eqz);
                try self.setReg(item);
            },
        }
    }

    fn emitConvert(self: *FunctionEmitter, item: ir.Register, operation: anytype) !void {
        switch (operation.kind) {
            .int_to_float => {
                try self.getReg(operation.operand);
                try self.a.op(wasm.f64_convert_i64_s);
                try self.setReg(item);
            },
            .float_to_int => {
                try self.getReg(operation.operand);
                try self.getReg(operation.operand);
                try self.a.op(wasm.f64_ne); // isNaN
                try self.getReg(operation.operand);
                try self.a.constF64(int_min_as_float);
                try self.a.op(wasm.f64_lt);
                try self.a.op(wasm.i32_or);
                try self.getReg(operation.operand);
                try self.a.constF64(int_max_as_float);
                try self.a.op(wasm.f64_ge);
                try self.a.op(wasm.i32_or);
                try self.a.trapIf(.conversion_range);
                try self.getReg(operation.operand);
                try self.a.op(wasm.i64_trunc_f64_s);
                try self.setReg(item);
            },
        }
    }

    fn emitBinary(self: *FunctionEmitter, item: ir.Register, operation: anytype) !void {
        switch (operation.operand_type) {
            .float => try self.emitFloatBinary(item, operation),
            .string => try self.emitStringBinary(item, operation),
            .boolean => {
                try self.getReg(operation.left);
                try self.getReg(operation.right);
                try self.a.op(if (operation.op == .equal) wasm.i32_eq else wasm.i32_ne);
                try self.setReg(item);
            },
            else => try self.emitIntBinary(item, operation),
        }
    }

    fn emitFloatBinary(self: *FunctionEmitter, item: ir.Register, operation: anytype) !void {
        try self.getReg(operation.left);
        try self.getReg(operation.right);
        try self.a.op(switch (operation.op) {
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
            .remainder => unreachable,
        });
        try self.setReg(item);
    }

    fn emitStringBinary(self: *FunctionEmitter, item: ir.Register, operation: anytype) !void {
        if (operation.op == .add) { // concat
            try self.getReg(operation.left);
            try self.getReg(operation.right);
            try self.a.callFunc(Rt.str_concat.index());
            try self.setReg(item);
            return;
        }
        // comparison: str_cmp then relate to 0
        try self.getReg(operation.left);
        try self.getReg(operation.right);
        try self.a.callFunc(Rt.str_cmp.index());
        try self.a.constI32(0);
        try self.a.op(switch (operation.op) {
            .equal => wasm.i32_eq,
            .not_equal => wasm.i32_ne,
            .less => wasm.i32_lt_s,
            .less_equal => wasm.i32_le_s,
            .greater => wasm.i32_gt_s,
            .greater_equal => wasm.i32_ge_s,
            else => unreachable,
        });
        try self.setReg(item);
    }

    fn emitIntBinary(self: *FunctionEmitter, item: ir.Register, operation: anytype) !void {
        const dest = self.regLocal(item);
        if (operation.op.isComparison()) {
            try self.getReg(operation.left);
            try self.getReg(operation.right);
            try self.a.op(switch (operation.op) {
                .equal => wasm.i64_eq,
                .not_equal => wasm.i64_ne,
                .less => wasm.i64_lt_s,
                .less_equal => wasm.i64_le_s,
                .greater => wasm.i64_gt_s,
                .greater_equal => wasm.i64_ge_s,
                else => unreachable,
            });
            try self.a.localSet(dest);
            return;
        }
        switch (operation.op) {
            .add, .subtract => {
                try self.getReg(operation.left);
                try self.getReg(operation.right);
                try self.a.op(if (operation.op == .add) wasm.i64_add else wasm.i64_sub);
                try self.a.localSet(dest);
                try self.overflowCheckAddSub(operation.op == .add, operation.left, operation.right, item);
            },
            .multiply => {
                try self.getReg(operation.left);
                try self.getReg(operation.right);
                try self.a.op(wasm.i64_mul);
                try self.a.localSet(dest);
                try self.getReg(operation.right);
                try self.a.op(wasm.i64_eqz);
                try self.a.op(wasm.if_);
                try self.a.op(wasm.empty_type);
                try self.a.op(wasm.else_);
                try self.getReg(operation.left);
                try self.a.constI64(std.math.minInt(i64));
                try self.a.op(wasm.i64_eq);
                try self.getReg(operation.right);
                try self.a.constI64(-1);
                try self.a.op(wasm.i64_eq);
                try self.a.op(wasm.i32_and);
                try self.a.trapIf(.integer_overflow);
                try self.a.localGet(dest);
                try self.getReg(operation.right);
                try self.a.op(wasm.i64_div_s);
                try self.getReg(operation.left);
                try self.a.op(wasm.i64_ne);
                try self.a.trapIf(.integer_overflow);
                try self.a.op(wasm.end);
            },
            .divide, .remainder => {
                try self.getReg(operation.right);
                try self.a.op(wasm.i64_eqz);
                try self.a.trapIf(.divide_by_zero);
                try self.getReg(operation.left);
                try self.a.constI64(std.math.minInt(i64));
                try self.a.op(wasm.i64_eq);
                try self.getReg(operation.right);
                try self.a.constI64(-1);
                try self.a.op(wasm.i64_eq);
                try self.a.op(wasm.i32_and);
                try self.a.trapIf(.integer_overflow);
                try self.getReg(operation.left);
                try self.getReg(operation.right);
                try self.a.op(if (operation.op == .divide) wasm.i64_div_s else wasm.i64_rem_s);
                try self.a.localSet(dest);
            },
            else => unreachable,
        }
    }

    fn overflowCheckAddSub(self: *FunctionEmitter, is_add: bool, left: ir.Register, right: ir.Register, dest: ir.Register) !void {
        if (is_add) {
            try self.getReg(left);
            try self.getReg(dest);
            try self.a.op(wasm.i64_xor);
            try self.getReg(right);
            try self.getReg(dest);
            try self.a.op(wasm.i64_xor);
        } else {
            try self.getReg(left);
            try self.getReg(right);
            try self.a.op(wasm.i64_xor);
            try self.getReg(left);
            try self.getReg(dest);
            try self.a.op(wasm.i64_xor);
        }
        try self.a.op(wasm.i64_and);
        try self.a.constI64(0);
        try self.a.op(wasm.i64_lt_s);
        try self.a.trapIf(.integer_overflow);
    }

    fn emitCall(self: *FunctionEmitter, item: ir.Register, callee: anytype) !void {
        for (callee.arguments) |argument| try self.getReg(argument);
        try self.a.callFunc(callee.function + import_count + Rt.count);
        try self.emitDepthRestore();
        if (self.program.functions[callee.function].return_type != .none) {
            if (self.function.result_types[item] != .none) {
                try self.setReg(item);
            } else {
                try self.a.op(wasm.drop);
            }
        }
    }

    fn emitIntrinsic(self: *FunctionEmitter, item: ir.Register, call: ir.Instruction.IntrinsicCall) !void {
        const args = call.arguments;
        switch (call.kind) {
            .assert_true => {
                try self.getReg(args[0]);
                try self.a.op(wasm.i32_eqz);
                try self.a.trapIf(.assertion_failed);
            },
            .trap_message => try self.a.trap(.explicit_trap),
            .abs => switch (self.function.result_types[args[0]]) {
                .float => {
                    try self.getReg(args[0]);
                    try self.a.op(wasm.f64_abs);
                    try self.setReg(item);
                },
                else => {
                    try self.getReg(args[0]);
                    try self.a.constI64(std.math.minInt(i64));
                    try self.a.op(wasm.i64_eq);
                    try self.a.trapIf(.integer_overflow);
                    try self.a.constI64(0);
                    try self.getReg(args[0]);
                    try self.a.op(wasm.i64_sub);
                    try self.getReg(args[0]);
                    try self.getReg(args[0]);
                    try self.a.constI64(0);
                    try self.a.op(wasm.i64_lt_s);
                    try self.a.op(wasm.select);
                    try self.setReg(item);
                },
            },
            .min, .max => {
                try self.getReg(args[0]);
                try self.getReg(args[1]);
                try self.getReg(args[0]);
                try self.getReg(args[1]);
                try self.a.op(if (call.kind == .min) wasm.i64_lt_s else wasm.i64_gt_s);
                try self.a.op(wasm.select);
                try self.setReg(item);
            },
            .clamp => {
                const dest = self.regLocal(item);
                try self.getReg(args[0]);
                try self.getReg(args[1]);
                try self.getReg(args[0]);
                try self.getReg(args[1]);
                try self.a.op(wasm.i64_gt_s);
                try self.a.op(wasm.select);
                try self.a.localSet(dest);
                try self.a.localGet(dest);
                try self.getReg(args[2]);
                try self.a.localGet(dest);
                try self.getReg(args[2]);
                try self.a.op(wasm.i64_lt_s);
                try self.a.op(wasm.select);
                try self.a.localSet(dest);
            },
            .sqrt, .floor, .ceil => {
                try self.getReg(args[0]);
                try self.a.op(switch (call.kind) {
                    .sqrt => wasm.f64_sqrt,
                    .floor => wasm.f64_floor,
                    .ceil => wasm.f64_ceil,
                    else => unreachable,
                });
                try self.setReg(item);
            },
            .len => { // string length
                try self.getReg(args[0]);
                try self.a.load(wasm.i32_load, 0);
                try self.a.op(wasm.i64_extend_i32_u);
                try self.setReg(item);
            },
            .string_slice => {
                try self.getReg(args[0]);
                try self.getReg(args[1]);
                try self.getReg(args[2]);
                try self.a.callFunc(Rt.str_slice.index());
                try self.setReg(item);
            },
            .string_byte => {
                try self.getReg(args[0]);
                try self.getReg(args[1]);
                try self.a.callFunc(Rt.str_byte.index());
                try self.setReg(item);
            },
            .string_find_byte => {
                try self.getReg(args[0]);
                try self.getReg(args[1]);
                try self.getReg(args[2]);
                try self.a.callFunc(Rt.str_find.index());
                try self.setReg(item);
            },
            .chr_code => {
                try self.getReg(args[0]);
                try self.a.callFunc(Rt.chr.index());
                try self.setReg(item);
            },
            .ord_text => {
                try self.getReg(args[0]);
                try self.a.callFunc(Rt.ord.index());
                try self.setReg(item);
            },
            .parse_int => {
                try self.getReg(args[0]);
                try self.a.callFunc(Rt.parse_int.index());
                try self.setReg(item);
            },
            .str_value => try self.emitStrValue(item, args[0]),
            .print => {
                try self.getReg(args[0]); // block ptr
                try self.a.constI32(4);
                try self.a.op(wasm.i32_add); // byte start = ptr + 4
                try self.getReg(args[0]);
                try self.a.load(wasm.i32_load, 0); // len
                try self.a.callFunc(import_emit);
            },
            else => unreachable,
        }
    }

    fn emitStrValue(self: *FunctionEmitter, item: ir.Register, arg: ir.Register) !void {
        switch (self.function.result_types[arg]) {
            .int => {
                try self.getReg(arg);
                try self.a.callFunc(Rt.str_from_i64.index());
                try self.setReg(item);
            },
            .boolean => {
                // "true" / "false" constants, chosen by the flag
                try self.a.constI32(@intCast(self.true_addr));
                try self.a.constI32(@intCast(self.false_addr));
                try self.getReg(arg);
                try self.a.op(wasm.select);
                try self.setReg(item);
            },
            .string => {
                try self.getReg(arg);
                try self.setReg(item);
            },
            else => unreachable, // float gated out
        }
    }

    fn emitBody(self: *FunctionEmitter) !void {
        const function = self.function;
        const block_count: u32 = @intCast(function.blocks.len);

        try self.emitDepthEntry();

        try self.a.op(wasm.block);
        try self.a.op(wasm.empty_type); // $exit
        try self.a.op(wasm.loop);
        try self.a.op(wasm.empty_type); // $loop
        var b: u32 = 0;
        while (b < block_count) : (b += 1) {
            try self.a.op(wasm.block);
            try self.a.op(wasm.empty_type);
        }
        try self.a.localGet(self.pc_local);
        try self.a.op(wasm.br_table);
        try self.a.u32v(block_count);
        var j: u32 = 0;
        while (j < block_count) : (j += 1) try self.a.u32v(block_count - 1 - j);
        try self.a.u32v(block_count - 1);

        var k: i64 = @as(i64, block_count) - 1;
        while (k >= 0) : (k -= 1) {
            try self.a.op(wasm.end);
            self.loop_depth = @intCast(k);
            self.scope_extra = 0;
            for (function.blocks[@intCast(k)].items) |item| try self.emitInstruction(item);
        }
        try self.a.op(wasm.end); // $loop
        try self.a.op(wasm.end); // $exit
        try self.a.op(wasm.unreachable_);
        try self.a.op(wasm.end); // function body
    }

    /// The function's local declarations then its code.  Declared locals
    /// (after the parameters carried by the signature) are the
    /// non-parameter Luce locals, then `$pc`, then one slot per IR
    /// register.
    fn body(self: *FunctionEmitter) ![]const u8 {
        const function = self.function;
        const local_count: u32 = @intCast(function.locals.len);
        self.pc_local = local_count;
        self.registers_base = local_count + 1;

        try self.emitBody();

        var out: std.ArrayList(u8) = .empty;
        const arena = self.a.arena;
        var kinds: std.ArrayList(u8) = .empty;
        for (function.locals[function.parameter_count..]) |local| {
            try kinds.append(arena, valType(local.local_type));
        }
        try kinds.append(arena, wasm.i32t); // pc
        for (function.result_types) |result| {
            try kinds.append(arena, valType(result));
        }
        try appendRunLength(&out, arena, kinds.items);
        try out.appendSlice(arena, self.a.code.items);
        return out.items;
    }
};

fn appendRunLength(out: *std.ArrayList(u8), arena: Allocator, kinds: []const u8) !void {
    var groups: u32 = 0;
    var i: usize = 0;
    while (i < kinds.len) {
        var j = i + 1;
        while (j < kinds.len and kinds[j] == kinds[i]) j += 1;
        groups += 1;
        i = j;
    }
    try appendU32Raw(out, arena, groups);
    i = 0;
    while (i < kinds.len) {
        var j = i + 1;
        while (j < kinds.len and kinds[j] == kinds[i]) j += 1;
        try appendU32Raw(out, arena, @intCast(j - i));
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

    fn module(self: *Builder) ![]const u8 {
        const a = self.arena;
        const functions = self.program.functions;

        // -- data image: empty string at 0, "true"/"false", then the
        //    program's string constants; the heap starts after it.
        var data: std.ArrayList(u8) = .empty;
        try data.appendSlice(a, &.{ 0, 0, 0, 0 }); // address 0: empty string
        const true_addr: u32 = @intCast(data.items.len);
        try appendStringBlock(&data, a, "true");
        const false_addr: u32 = @intCast(data.items.len);
        try appendStringBlock(&data, a, "false");
        const constant_addr = try a.alloc(u32, self.program.constants.len);
        for (self.program.constants, 0..) |constant, index| {
            constant_addr[index] = @intCast(data.items.len);
            try appendStringBlock(&data, a, constant);
        }
        const heap_base: u32 = (@as(u32, @intCast(data.items.len)) + 7) & ~@as(u32, 7);
        const min_pages: u32 = (heap_base + 0x10000 * 4) / 0x10000; // data + 256KB headroom

        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(a, &.{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 });

        // Types: 0 = emit_str (i32,i32)->(), 1 = trap (i32)->(), then one
        // per runtime function, then one per user function.
        var t: std.ArrayList(u8) = .empty;
        try appendU32Raw(&t, a, @intCast(import_count + Rt.count + functions.len));
        try t.appendSlice(a, &.{ wasm.func_type, 2, wasm.i32t, wasm.i32t, 0 }); // emit_str
        try t.appendSlice(a, &.{ wasm.func_type, 1, wasm.i32t, 0 }); // trap
        for (rt_signatures) |sig| try appendSigType(&t, a, sig.params, sig.result);
        for (functions) |*function| try appendFuncType(&t, a, function);
        try section(&out, a, 1, t.items);

        // Imports: env.emit_str (type 0), env.trap (type 1).
        var im: std.ArrayList(u8) = .empty;
        try appendU32Raw(&im, a, import_count);
        try appendImport(&im, a, "env", "emit_str", 0);
        try appendImport(&im, a, "env", "trap", 1);
        try section(&out, a, 2, im.items);

        // Functions: runtime then user, each referencing its type index.
        var fs: std.ArrayList(u8) = .empty;
        try appendU32Raw(&fs, a, @intCast(Rt.count + functions.len));
        var fi: u32 = 0;
        while (fi < Rt.count + functions.len) : (fi += 1) try appendU32Raw(&fs, a, import_count + fi);
        try section(&out, a, 3, fs.items);

        // Memory: one, min_pages, exported so the host can read strings.
        var me: std.ArrayList(u8) = .empty;
        try appendU32Raw(&me, a, 1);
        try me.append(a, 0x00); // limits: min only
        try appendU32Raw(&me, a, min_pages);
        try section(&out, a, 5, me.items);

        // Globals: depth budget (i64), heap pointer (i32), both mutable.
        var gl: std.ArrayList(u8) = .empty;
        try appendU32Raw(&gl, a, 2);
        try gl.appendSlice(a, &.{ wasm.i64t, 0x01, wasm.i64_const });
        try appendI64Raw(&gl, a, call_depth_budget);
        try gl.append(a, wasm.end);
        try gl.appendSlice(a, &.{ wasm.i32t, 0x01, wasm.i32_const });
        try appendI64Raw(&gl, a, heap_base);
        try gl.append(a, wasm.end);
        try section(&out, a, 6, gl.items);

        // Exports: main and memory.
        var ex: std.ArrayList(u8) = .empty;
        try appendU32Raw(&ex, a, 2);
        try appendName(&ex, a, "main");
        try ex.append(a, 0x00);
        try appendU32Raw(&ex, a, @intCast(import_count + Rt.count + self.program.entry_function));
        try appendName(&ex, a, "memory");
        try ex.append(a, 0x02); // export kind: memory
        try appendU32Raw(&ex, a, 0);
        try section(&out, a, 7, ex.items);

        // Code: runtime functions then user functions.
        var cs: std.ArrayList(u8) = .empty;
        try appendU32Raw(&cs, a, @intCast(Rt.count + functions.len));
        for (0..Rt.count) |ri| {
            const code = try emitRuntime(a, @enumFromInt(ri));
            try appendU32Raw(&cs, a, @intCast(code.len));
            try cs.appendSlice(a, code);
        }
        for (functions) |*function| {
            var emitter: FunctionEmitter = .{
                .a = .{ .arena = a },
                .program = self.program,
                .function = function,
                .constant_addr = constant_addr,
                .true_addr = true_addr,
                .false_addr = false_addr,
            };
            const code = try emitter.body();
            try appendU32Raw(&cs, a, @intCast(code.len));
            try cs.appendSlice(a, code);
        }
        try section(&out, a, 10, cs.items);

        // Data: one active segment writing the image at offset 0.
        var da: std.ArrayList(u8) = .empty;
        try appendU32Raw(&da, a, 1);
        try da.appendSlice(a, &.{ 0x00, wasm.i32_const });
        try appendI64Raw(&da, a, 0);
        try da.append(a, wasm.end);
        try appendU32Raw(&da, a, @intCast(data.items.len));
        try da.appendSlice(a, data.items);
        try section(&out, a, 11, da.items);

        return out.items;
    }
};

/// A length-prefixed string block: [i32 len][bytes].
fn appendStringBlock(data: *std.ArrayList(u8), arena: Allocator, text: []const u8) !void {
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(text.len), .little);
    try data.appendSlice(arena, &header);
    try data.appendSlice(arena, text);
}

fn appendSigType(t: *std.ArrayList(u8), arena: Allocator, params: []const u8, result: ?u8) !void {
    try t.append(arena, wasm.func_type);
    try appendU32Raw(t, arena, @intCast(params.len));
    try t.appendSlice(arena, params);
    if (result) |r| {
        try appendU32Raw(t, arena, 1);
        try t.append(arena, r);
    } else {
        try appendU32Raw(t, arena, 0);
    }
}

fn appendFuncType(t: *std.ArrayList(u8), arena: Allocator, function: *const ir.Function) !void {
    try t.append(arena, wasm.func_type);
    try appendU32Raw(t, arena, function.parameter_count);
    for (function.locals[0..function.parameter_count]) |param| {
        try t.append(arena, valType(param.local_type));
    }
    if (function.return_type == .none) {
        try appendU32Raw(t, arena, 0);
    } else {
        try appendU32Raw(t, arena, 1);
        try t.append(arena, valType(function.return_type));
    }
}

fn section(out: *std.ArrayList(u8), arena: Allocator, id: u8, contents: []const u8) !void {
    try out.append(arena, id);
    try appendU32Raw(out, arena, @intCast(contents.len));
    try out.appendSlice(arena, contents);
}

fn appendName(list: *std.ArrayList(u8), arena: Allocator, name: []const u8) !void {
    try appendU32Raw(list, arena, @intCast(name.len));
    try list.appendSlice(arena, name);
}

fn appendImport(list: *std.ArrayList(u8), arena: Allocator, module_name: []const u8, field: []const u8, type_index: u32) !void {
    try appendName(list, arena, module_name);
    try appendName(list, arena, field);
    try list.append(arena, 0x00);
    try appendU32Raw(list, arena, type_index);
}

fn appendU32Raw(list: *std.ArrayList(u8), arena: Allocator, value: u32) !void {
    var v = value;
    while (true) {
        var byte: u8 = @intCast(v & 0x7F);
        v >>= 7;
        if (v != 0) byte |= 0x80;
        try list.append(arena, byte);
        if (v == 0) break;
    }
}

fn appendI64Raw(list: *std.ArrayList(u8), arena: Allocator, value: i64) !void {
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

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const compile_mod = @import("compile.zig");
const testing = std.testing;
const script: types.CompileOptions = .{ .entry_mode = .script, .allow_host = true };

test "the baked call-depth budget matches what loom runs every engine with" {
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

test "scalars and strings are supported; heap and str(Float) are not yet" {
    var core = (try compileOrNull(
        \\func label(n: Int) -> String:
        \\    return "n=" + str(n)
        \\
        \\func main():
        \\    var s = ""
        \\    for i in range(0, 4):
        \\        s = s + label(i) + ";"
        \\    print(s)
        \\    print(str(len(s) > 0))
    )).?;
    defer core.deinit();
    try testing.expect(supported(&core));

    var heap = (try compileOrNull(
        \\func main():
        \\    var xs = new List(Int)
        \\    xs.append(3)
        \\    print(str(len(xs)))
    )).?;
    defer heap.deinit();
    try testing.expect(!supported(&heap));

    var floatstr = (try compileOrNull(
        \\func main():
        \\    var x = 1.5
        \\    print(str(x))
    )).?;
    defer floatstr.deinit();
    try testing.expect(!supported(&floatstr));
}

test "a supported program emits a well-formed wasm module" {
    var program = (try compileOrNull(
        \\func main():
        \\    var s = "hello, " + "world"
        \\    print(s)
        \\    print(str(len(s)))
    )).?;
    defer program.deinit();
    try testing.expect(supported(&program));

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const bytes = try compile(arena_state.allocator(), &program);

    try testing.expectEqualSlices(u8, &.{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 }, bytes[0..8]);
    var offset: usize = 8;
    var last_id: u8 = 0;
    while (offset < bytes.len) {
        const id = bytes[offset];
        // Custom sections (id 0) may repeat; ours are all ordered non-zero.
        try testing.expect(id > last_id);
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
    try testing.expectEqual(bytes.len, offset);
}
