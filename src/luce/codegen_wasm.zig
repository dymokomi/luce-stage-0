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
//!     `print` of any text; then the object heap (List/Builder, Array,
//!     Map), give/copy/free, structs, and float min/max/clamp with the
//!     interpreter's exact NaN rule (a NaN operand loses).
//! Deferred with reasons (not because they are hard to reach, but
//! because matching the reference *exactly* is its own step): float `%`
//! (`@rem`/fmod is bit-manipulation, not an opcode); `str(Float)` and
//! `parse_float` (Zig's shortest-round-trip float formatting is an
//! algorithm to port); containers whose elements themselves own heap
//! objects (the element-ownership walk); host effects (a distribution
//! module's effects are imports, out of the compute core's scope).

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
    if (function.return_type != .none and !supportedType(program, function.return_type)) return false;
    for (function.locals) |local| {
        if (!supportedType(program, local.local_type)) return false;
    }
    for (function.result_types) |result| {
        if (result != .none and !supportedType(program, result)) return false;
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
            .heap_new => |new| if (!supportedHeap(program, new.heap)) return false,
            .object_bind, .object_unbind => {}, // value type already gated above
            .struct_make, .struct_get, .struct_set => {}, // type gate covers the fields
            .intrinsic => |call| if (!intrinsicSupported(program, function, call)) return false,
            else => return false, // input/output ports
        }
    }
    return true;
}

/// A struct all of whose fields are scalars/strings — value records with
/// no owned objects, so no ownership walk.  Object and nested-struct
/// fields are a later phase.
fn supportedStruct(program: *const ir.Program, index: u32) bool {
    for (program.structs[index].fields) |field| {
        if (!nonOwning(program, field.field_type)) return false;
    }
    return true;
}

/// A List of scalars/strings, or a Builder — the heap shapes phase B1
/// lowers.  Maps, arrays, and object-holding containers are later.
fn supportedHeap(program: *const ir.Program, index: u32) bool {
    // The depth cap guards against a damaged module's cyclic type table;
    // any real chain is bounded by the table's length.
    return supportedHeapDepth(program, index, program.heap_types.len + 1);
}

fn supportedHeapDepth(program: *const ir.Program, index: u32, depth: usize) bool {
    if (depth == 0) return false;
    return switch (program.heap_types[index]) {
        .builder => true,
        .list => |element| elementSupported(program, element, depth),
        .array => |shape| elementSupported(program, shape.element, depth),
        // Map keys are Int/String (the analyzer's rule).
        .map => |pair| nonOwning(program, pair.key) and elementSupported(program, pair.value, depth),
    };
}

/// A container element: any non-owning value, or a supported heap type
/// (whose ownership the generated walks then carry).
fn elementSupported(program: *const ir.Program, of: types.Type, depth: usize) bool {
    if (of == .heap) return supportedHeapDepth(program, of.heap, depth - 1);
    return nonOwning(program, of);
}

/// A value that fits one 8-byte slot and owns no heap object: scalars,
/// strings, and structs all of whose fields are themselves non-owning.
/// Such values need no element/field ownership walk, so a container or
/// struct built from them is safe with a plain slot copy.  A heap object
/// field (a List inside a struct, a struct inside a List that holds
/// objects) owns things and waits for the element-ownership phase.
fn nonOwning(program: *const ir.Program, of: types.Type) bool {
    return switch (of) {
        .int, .boolean, .float, .string => true,
        .strukt => |index| supportedStruct(program, index),
        else => false, // heap objects, bytes
    };
}

/// The element type of a List or Array heap type (for gating decisions).
fn containerElement(program: *const ir.Program, of: types.Type) types.Type {
    return switch (program.heap_types[of.heap]) {
        .list => |element| element,
        .array => |shape| shape.element,
        else => .none,
    };
}

fn isBuilder(program: *const ir.Program, index: u32) bool {
    return std.meta.activeTag(program.heap_types[index]) == .builder;
}

/// The find/sort comparison mode for a List/Array element type.
fn elementMode(of: types.Type) i32 {
    return switch (of) {
        .float => cmp_float,
        .string => cmp_string,
        else => cmp_int,
    };
}

/// Map keys are Int or String (the analyzer's rule); String keys compare
/// by bytes, Int keys by value.
fn keyMode(of: types.Type) i32 {
    return if (of == .string) cmp_string else cmp_int;
}

fn supportedType(program: *const ir.Program, of: types.Type) bool {
    return switch (of) {
        .int, .boolean, .float, .string => true,
        .heap => |index| supportedHeap(program, index),
        .strukt => |index| supportedStruct(program, index),
        else => false, // bytes, none-as-value
    };
}

fn binarySupported(op: ir.Instruction.Binary) bool {
    return switch (op.operand_type) {
        .int => true,
        .string => op.op == .add or op.op.isComparison(),
        .boolean => op.op == .equal or op.op == .not_equal,
        .float => true, // % lowers to the runtime's bit-exact fmod
        .strukt => op.op == .equal or op.op == .not_equal,
        else => false,
    };
}

fn intrinsicSupported(program: *const ir.Program, function: *const ir.Function, call: ir.Instruction.IntrinsicCall) bool {
    const argType = struct {
        fn of(fun: *const ir.Function, register: ir.Register) types.Type {
            return fun.result_types[register];
        }
    }.of;
    // Host/fabric intrinsics (arg_count, term_*, …) take no value arg;
    // they are unsupported, so guard the type lookup.
    const a0 = if (call.arguments.len > 0) argType(function, call.arguments[0]) else types.Type.none;
    return switch (call.kind) {
        .assert_true, .trap_message, .null_object => true,
        .abs => a0 == .int or a0 == .float,
        .min, .max, .clamp => a0 == .int or a0 == .float,
        .sqrt, .floor, .ceil => a0 == .float,
        .len => a0 == .string or a0 == .heap,
        .string_slice, .string_byte, .string_find_byte => true,
        .chr_code, .ord_text, .parse_int => true,
        // The List / Builder operations (their receiver's heap type is
        // already gated by the type check).
        .index_get, .index_set, .append_value, .append_ascii => true,
        .pop_value, .insert_value, .remove_entry => true,
        .list_slice, .list_reverse, .clear_object => true,
        // find/contains compare elements; struct comparison in a
        // container is deferred (sort never reaches structs — the
        // analyzer requires orderable elements).
        .list_find, .list_contains => std.meta.activeTag(containerElement(program, a0)) != .strukt,
        .list_sort => true,
        .dim_size => true,
        // fill duplicates one value into every slot — for an object that
        // would forge shared ownership, and the analyzer forbids it.
        .array_fill => !heapTypeOwns(program, a0.heap),
        .has_key, .key_at, .value_at, .map_get, .map_keys, .map_values => true,
        // give/copy/free on an object (struct values are a later phase).
        .give_object, .copy_object, .free_object => a0 == .heap,
        // parse_float still needs a correctly-rounded reader; str(Float)
        // ships via the ryu runtime.
        .str_value => a0 != .heap or isBuilder(program, a0.heap),
        .print => a0 == .string,
        else => false, // map/array ops, give/copy/free: later phases
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
    const i64_shl: u8 = 0x86;
    const i64_shr_u: u8 = 0x88;
    const i64_le_u: u8 = 0x58;

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
    const f64_min: u8 = 0xA4;
    const f64_max: u8 = 0xA5;

    const i32_wrap_i64: u8 = 0xA7;
    const i64_extend_i32_s: u8 = 0xAC;
    const i64_extend_i32_u: u8 = 0xAD;
    const i64_trunc_f64_s: u8 = 0xB0;
    const f64_convert_i64_s: u8 = 0xB9;
    const i64_reinterpret_f64: u8 = 0xBD;
    const f64_reinterpret_i64: u8 = 0xBF;

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
const serial_global = 2; // i64: the next ownership serial (frame identity)

/// The call-depth budget the module traps at — the same value loom runs
/// every engine with (`native.max_call_depth`); checked in the tests.
const call_depth_budget: i64 = 128;

// -- object records (docs/OWNERSHIP.md) -------------------------------------
//
// Every heap object is a fixed 40-byte record in linear memory; its
// address is its handle (0 is null).  Ownership lives in the record:
// the interpreter's HeapObject.owner, transliterated.  Elements/bytes
// sit in a separately allocated, growable buffer at `data`.  Nothing is
// ever reclaimed — the interpreter's free() only marks an object dead,
// and its arena reclaims at the end, so a bump allocator matches.
const obj_alive = 0; // i32: 1 live, 0 freed
const obj_owner_kind = 4; // i32: 0 loose, 1 container, 2 binding
const obj_owner_serial = 8; // i64: the owning frame's serial (binding)
const obj_owner_local = 16; // i32: the owning local (binding)
const obj_length = 20; // i32: element count (list/map/array) or byte count (builder)
const obj_capacity = 24; // i32: allocated element slots or bytes
const obj_data = 28; // i32: address of the element/byte buffer
const obj_dims = 32; // i32: array — address of the rank i64 dimensions
const obj_rank = 36; // i32: array — number of dimensions
const obj_record_size = 40;

const owner_loose = 0;
const owner_container = 1;
const owner_binding = 2;

// find/sort element-comparison modes (the element type decides which).
const cmp_int = 0; // i64 identity (Int, Bool)
const cmp_float = 1; // f64 equality/order
const cmp_string = 2; // lexicographic via str_cmp

// Generated per-heap-type ownership walks (monomorphized from the
// program's static heap-type table; function index = user_base -
// gen_count + type*gen_kinds + kind).
const gen_free_elements = 0; // (h) -> ()   free every owned element
const gen_free_object = 1; // (h) -> ()   mark dead + free_elements
const gen_copy_object = 2; // (h) -> h'   deep copy (null passes through)
const gen_own_elements = 3; // (h) -> ()   deep-copy + adopt every element in place
const gen_kinds = 4;

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
// Ryu tables — str(Float)'s shortest-round-trip digits need the 5^i /
// 5^-i 128-bit fixed-point tables Zig's own formatter uses (private to
// std, so generated here at comptime with exact big-int math and proven
// against std.fmt by the replica test below).  Layout matches the
// reference: each entry is (low u64, high u64) of a 125-bit value.
// ---------------------------------------------------------------------------

const pow5_table_len = 326; // 5^i, truncated to the top 125 bits
const pow5_inv_table_len = 342; // floor(2^(len(5^i)-1+125) / 5^i) + 1

const RyuTables = struct { pow5: [pow5_table_len][2]u64, inv: [pow5_inv_table_len][2]u64 };

fn generatedPow5Tables() RyuTables {
    @setEvalBranchQuota(2_000_000);
    var result: RyuTables = undefined;
    var pow: comptime_int = 1; // 5^i
    var len: comptime_int = 1; // bit length of pow
    var i: usize = 0;
    while (i < pow5_inv_table_len) : (i += 1) {
        if (i < pow5_table_len) {
            const split: comptime_int = if (len <= 125) pow << (125 - len) else pow >> (len - 125);
            result.pow5[i] = .{ @truncate(split), @truncate(split >> 64) };
        }
        const inv: comptime_int = ((1 << (len - 1 + 125)) / pow) + 1;
        result.inv[i] = .{ @truncate(inv), @truncate(inv >> 64) };
        pow *= 5;
        len += 2;
        if ((pow >> len) != 0) len += 1;
    }
    return result;
}

const ryu_tables = generatedPow5Tables();

// Linear-memory addresses: the data image places the tables right after
// the empty-string block at 0, 8-aligned; strings follow them.
const pow5_table_addr: u32 = 8;
const pow5_inv_table_addr: u32 = pow5_table_addr + pow5_table_len * 16;
const tables_end_addr: u32 = pow5_inv_table_addr + pow5_inv_table_len * 16;

// -- the reference algorithm in plain Zig -----------------------------------
//
// A faithful replica of std.fmt's binaryToDecimal (full-table 64-bit
// backend) and positional rendering, over the generated tables.  It
// exists to prove the tables and the exact algorithm the wasm runtime
// transliterates — the test below holds it byte-identical to std.fmt
// itself, so any generation slip or transcription slip fails in Zig,
// before the wasm translation can inherit it.

const RefDecimal = struct { mantissa: u64, exponent: i32, sign: bool };
const ref_special_exponent = std.math.maxInt(i32);

fn refLog10Pow2(e: u32) u32 {
    return @intCast((@as(u64, e) * 169464822037455) >> 49);
}
fn refLog10Pow5(e: u32) u32 {
    return @intCast((@as(u64, e) * 196742565691928) >> 48);
}
fn refPow5Bits(e: u32) u32 {
    return @intCast(((@as(u64, e) * 163391164108059) >> 46) + 1);
}
fn refPow5Factor(value_: u64) u32 {
    var count: u32 = 0;
    var value = value_;
    while (value > 0) : ({
        count += 1;
        value /= 5;
    }) {
        if (value % 5 != 0) return count;
    }
    return 0;
}
fn refMulShift64(m: u64, mul: *const [2]u64, j: u32) u64 {
    const b0 = @as(u128, m) * mul[0];
    const b2 = @as(u128, m) * mul[1];
    if (j < 128) {
        const shift: u6 = @intCast(j - 64);
        return @intCast(((b0 >> 64) + b2) >> shift);
    }
    return 0;
}

fn refBinaryToDecimal(bits: u64) RefDecimal {
    const mantissa_bits = 52;
    const bias = 1023;
    const ieee_sign = (bits >> 63) & 1 != 0;
    const ieee_mantissa = bits & ((@as(u64, 1) << mantissa_bits) - 1);
    const ieee_exponent: u32 = @intCast((bits >> mantissa_bits) & 0x7FF);

    if (ieee_exponent == 0 and ieee_mantissa == 0) {
        return .{ .mantissa = 0, .exponent = 0, .sign = ieee_sign };
    }
    if (ieee_exponent == 0x7FF) {
        return .{ .mantissa = ieee_mantissa, .exponent = ref_special_exponent, .sign = ieee_sign };
    }

    var e2: i32 = undefined;
    var m2: u64 = undefined;
    if (ieee_exponent == 0) {
        e2 = 1 - bias - mantissa_bits - 2;
        m2 = ieee_mantissa;
    } else {
        e2 = @as(i32, @intCast(ieee_exponent)) - bias - mantissa_bits - 2;
        m2 = (@as(u64, 1) << mantissa_bits) | ieee_mantissa;
    }
    const accept_bounds = (m2 & 1) == 0;
    const mv = 4 * m2;
    const mm_shift: u1 = @intFromBool(ieee_mantissa != 0 or ieee_exponent == 0);

    var vr: u64 = undefined;
    var vp: u64 = undefined;
    var vm: u64 = undefined;
    var e10: i32 = undefined;
    var vm_is_trailing_zeros = false;
    var vr_is_trailing_zeros = false;
    if (e2 >= 0) {
        const q: u32 = refLog10Pow2(@intCast(e2)) - @intFromBool(e2 > 3);
        e10 = @intCast(q);
        const k: i32 = @intCast(125 + refPow5Bits(q) - 1);
        const i: u32 = @intCast(-e2 + @as(i32, @intCast(q)) + k);
        const mul = &ryu_tables.inv[q];
        vr = refMulShift64(mv, mul, i);
        vp = refMulShift64(mv + 2, mul, i);
        vm = refMulShift64(mv - 1 - mm_shift, mul, i);
        if (q <= 21) {
            if (mv % 5 == 0) {
                vr_is_trailing_zeros = refPow5Factor(mv) >= q;
            } else if (accept_bounds) {
                vm_is_trailing_zeros = refPow5Factor(mv - 1 - mm_shift) >= q;
            } else {
                vp -= @intFromBool(refPow5Factor(mv + 2) >= q);
            }
        }
    } else {
        const q: u32 = refLog10Pow5(@intCast(-e2)) - @intFromBool(-e2 > 1);
        e10 = @as(i32, @intCast(q)) + e2;
        const pow_index: i32 = -e2 - @as(i32, @intCast(q));
        const k: i32 = @as(i32, @intCast(refPow5Bits(@intCast(pow_index)))) - 125;
        const j: u32 = @intCast(@as(i32, @intCast(q)) - k);
        const mul = &ryu_tables.pow5[@intCast(pow_index)];
        vr = refMulShift64(mv, mul, j);
        vp = refMulShift64(mv + 2, mul, j);
        vm = refMulShift64(mv - 1 - mm_shift, mul, j);
        if (q <= 1) {
            vr_is_trailing_zeros = true;
            if (accept_bounds) {
                vm_is_trailing_zeros = mm_shift == 1;
            } else {
                vp -= 1;
            }
        } else if (q < 63) {
            vr_is_trailing_zeros = (mv & ((@as(u64, 1) << @intCast(q)) - 1)) == 0;
        }
    }

    var removed: u32 = 0;
    var last_removed_digit: u8 = 0;
    while (vp / 10 > vm / 10) {
        vm_is_trailing_zeros = vm_is_trailing_zeros and vm % 10 == 0;
        vr_is_trailing_zeros = vr_is_trailing_zeros and last_removed_digit == 0;
        last_removed_digit = @intCast(vr % 10);
        vr /= 10;
        vp /= 10;
        vm /= 10;
        removed += 1;
    }
    if (vm_is_trailing_zeros) {
        while (vm % 10 == 0) {
            vr_is_trailing_zeros = vr_is_trailing_zeros and last_removed_digit == 0;
            last_removed_digit = @intCast(vr % 10);
            vr /= 10;
            vp /= 10;
            vm /= 10;
            removed += 1;
        }
    }
    if (vr_is_trailing_zeros and last_removed_digit == 5 and vr % 2 == 0) {
        last_removed_digit = 4;
    }
    return .{
        .mantissa = vr + @intFromBool((vr == vm and (!accept_bounds or !vm_is_trailing_zeros)) or last_removed_digit >= 5),
        .exponent = e10 + @as(i32, @intCast(removed)),
        .sign = ieee_sign,
    };
}

fn refDecimalLength(v: u64) u32 {
    var length: u32 = 1;
    var value = v;
    while (value >= 10) : (value /= 10) length += 1;
    return length;
}

/// Positional rendering with no precision — std.fmt's decimal mode.
fn refFormatDecimal(buf: []u8, d: RefDecimal) []const u8 {
    if (d.exponent == ref_special_exponent) {
        var index: usize = 0;
        if (d.sign) {
            buf[0] = '-';
            index = 1;
        }
        const word = if (d.mantissa != 0) "nan" else "inf";
        @memcpy(buf[index..][0..3], word);
        return buf[0 .. index + 3];
    }
    var output = d.mantissa;
    const olength = refDecimalLength(output);
    var index: usize = 0;
    if (d.sign) {
        buf[index] = '-';
        index += 1;
    }
    const dp_offset = d.exponent + @as(i32, @intCast(olength));
    if (dp_offset <= 0) {
        buf[index] = '0';
        buf[index + 1] = '.';
        index += 2;
        const zeros: u32 = @intCast(-dp_offset);
        @memset(buf[index..][0..zeros], '0');
        index += zeros;
        refWriteDecimal(buf[index..], &output, olength);
        index += olength;
    } else {
        const dp: usize = @intCast(dp_offset);
        if (dp >= olength) {
            refWriteDecimal(buf[index..], &output, olength);
            index += olength;
            @memset(buf[index..][0 .. dp - olength], '0');
            index += dp - olength;
        } else {
            refWriteDecimal(buf[index + dp + 1 ..], &output, olength - @as(u32, @intCast(dp)));
            buf[index + dp] = '.';
            refWriteDecimal(buf[index..], &output, @intCast(dp));
            index += olength + 1;
        }
    }
    return buf[0..index];
}

fn refWriteDecimal(buf: []u8, value: *u64, count: u32) void {
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        buf[count - i - 1] = '0' + @as(u8, @intCast(value.* % 10));
        value.* /= 10;
    }
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
    fn memoryFill(self: *Asm) !void { // dest, byte value, len on stack
        try self.op(wasm.misc);
        try self.u32v(wasm.memory_fill_sub);
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

    // -- the object heap ---------------------------------------------------
    obj_alloc, // () -> i32   (a fresh live, loose, empty record)
    live, // (i32 h) -> i32   (trap null/freed; else return h)
    reserve, // (i32 h, i32 need, i32 elem_size) -> ()   (grow data buffer)
    list_push, // (i32 h, i64 v) -> ()
    list_get, // (i32 h, i64 i) -> i64
    list_set, // (i32 h, i64 i, i64 v) -> i64   (returns the old slot)
    list_pop, // (i32 h) -> i64
    list_insert, // (i32 h, i64 i, i64 v) -> ()
    list_remove, // (i32 h, i64 i) -> i64   (returns the removed slot)
    list_slice, // (i32 h, i64 start, i64 end) -> i32   (copies slots)
    list_find, // (i32 h, i64 wanted, i32 mode) -> i64
    list_sort, // (i32 h, i32 mode, i32 reverse) -> ()
    builder_byte, // (i32 h, i64 code) -> ()   (append_ascii; traps > 0x7F)
    builder_str, // (i32 h, i32 s) -> ()   (append a string's bytes)
    builder_to_str, // (i32 h) -> i32
    // Ownership on a single object handle (docs/OWNERSHIP.md).  A null
    // or freed handle is a no-op, matching the interpreter's liveObject.
    own_bind, // (i32 h, i64 serial, i32 local) -> ()   (owner := binding)
    own_should_free, // (i32 h, i64 serial, i32 local) -> i32   (that binding still owns it)
    own_loosen_frame, // (i32 h, i64 serial) -> ()   (binding(serial,*) := loose)
    own_adopt, // (i32 h) -> ()   (owner := container; S20)
    own_loosen, // (i32 h) -> ()   (owner := loose; pop hands the element out)
    array_new, // (i32 rank, i32 dims_buf) -> i32   (validate dims, alloc elements)
    // Maps: entries are 16 bytes (key 8, value 8); keys compared by mode.
    map_find, // (i32 h, i64 key, i32 mode) -> i32   (entry index, or -1)
    map_index, // (i32 h, i64 key, i32 mode) -> i64   (value; traps key_missing)
    map_get_or, // (i32 h, i64 key, i32 mode, i64 def) -> i64
    map_set, // (i32 h, i64 key, i32 mode, i64 val) -> ()
    map_remove, // (i32 h, i64 key, i32 mode) -> ()
    map_key_at, // (i32 h, i64 i) -> i64
    map_value_at, // (i32 h, i64 i) -> i64
    map_keys, // (i32 h) -> i32   (a new List of the keys)
    map_values, // (i32 h) -> i32   (a new List of the values)
    // give/copy/free (docs/OWNERSHIP.md S23, S31).
    own_check, // (i32 h, i32 has_expected, i64 serial, i32 local) -> ()
    obj_clone, // (i32 h, i32 elem_size) -> i32   (shallow buffer copy)
    array_clone, // (i32 h) -> i32
    // Float min/max matching Zig's @min/@max: a NaN operand loses (the
    // other returns); wasm's own f64.min/max would propagate it.  Signed
    // zeros the opcode already orders correctly (-0 < +0).
    fmin, // (f64 a, f64 b) -> f64
    fmax, // (f64 a, f64 b) -> f64
    frem, // (f64 x, f64 y) -> f64   (fmod: @rem's float semantics, bit-exact)
    // str(Float): ryu shortest round-trip + positional rendering.
    umulhi, // (i64 a, i64 b) -> i64   (high 64 bits of the unsigned product)
    mul_shift, // (i64 m, i32 entry_addr, i64 j) -> i64   (ryu mulShift64)
    p5fac, // (i64 v) -> i64   (largest k with 5^k dividing v)
    wdig, // (i32 addr, i64 value, i64 count) -> i64   (write digits; return rest)
    fstr, // (f64) -> i32   (a fresh string block)

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
    .{ .params = &.{}, .result = wasm.i32t }, // obj_alloc
    .{ .params = &.{wasm.i32t}, .result = wasm.i32t }, // live
    .{ .params = &.{ wasm.i32t, wasm.i32t, wasm.i32t }, .result = null }, // reserve
    .{ .params = &.{ wasm.i32t, wasm.i64t }, .result = null }, // list_push
    .{ .params = &.{ wasm.i32t, wasm.i64t }, .result = wasm.i64t }, // list_get
    .{ .params = &.{ wasm.i32t, wasm.i64t, wasm.i64t }, .result = wasm.i64t }, // list_set
    .{ .params = &.{wasm.i32t}, .result = wasm.i64t }, // list_pop
    .{ .params = &.{ wasm.i32t, wasm.i64t, wasm.i64t }, .result = null }, // list_insert
    .{ .params = &.{ wasm.i32t, wasm.i64t }, .result = wasm.i64t }, // list_remove
    .{ .params = &.{ wasm.i32t, wasm.i64t, wasm.i64t }, .result = wasm.i32t }, // list_slice
    .{ .params = &.{ wasm.i32t, wasm.i64t, wasm.i32t }, .result = wasm.i64t }, // list_find
    .{ .params = &.{ wasm.i32t, wasm.i32t, wasm.i32t }, .result = null }, // list_sort
    .{ .params = &.{ wasm.i32t, wasm.i64t }, .result = null }, // builder_byte
    .{ .params = &.{ wasm.i32t, wasm.i32t }, .result = null }, // builder_str
    .{ .params = &.{wasm.i32t}, .result = wasm.i32t }, // builder_to_str
    .{ .params = &.{ wasm.i32t, wasm.i64t, wasm.i32t }, .result = null }, // own_bind
    .{ .params = &.{ wasm.i32t, wasm.i64t, wasm.i32t }, .result = wasm.i32t }, // own_should_free
    .{ .params = &.{ wasm.i32t, wasm.i64t }, .result = null }, // own_loosen_frame
    .{ .params = &.{wasm.i32t}, .result = null }, // own_adopt
    .{ .params = &.{wasm.i32t}, .result = null }, // own_loosen
    .{ .params = &.{ wasm.i32t, wasm.i32t }, .result = wasm.i32t }, // array_new
    .{ .params = &.{ wasm.i32t, wasm.i64t, wasm.i32t }, .result = wasm.i32t }, // map_find
    .{ .params = &.{ wasm.i32t, wasm.i64t, wasm.i32t }, .result = wasm.i64t }, // map_index
    .{ .params = &.{ wasm.i32t, wasm.i64t, wasm.i32t, wasm.i64t }, .result = wasm.i64t }, // map_get_or
    .{ .params = &.{ wasm.i32t, wasm.i64t, wasm.i32t, wasm.i64t }, .result = null }, // map_set
    .{ .params = &.{ wasm.i32t, wasm.i64t, wasm.i32t }, .result = null }, // map_remove
    .{ .params = &.{ wasm.i32t, wasm.i64t }, .result = wasm.i64t }, // map_key_at
    .{ .params = &.{ wasm.i32t, wasm.i64t }, .result = wasm.i64t }, // map_value_at
    .{ .params = &.{wasm.i32t}, .result = wasm.i32t }, // map_keys
    .{ .params = &.{wasm.i32t}, .result = wasm.i32t }, // map_values
    .{ .params = &.{ wasm.i32t, wasm.i32t, wasm.i64t, wasm.i32t }, .result = null }, // own_check
    .{ .params = &.{ wasm.i32t, wasm.i32t }, .result = wasm.i32t }, // obj_clone
    .{ .params = &.{wasm.i32t}, .result = wasm.i32t }, // array_clone
    .{ .params = &.{ wasm.f64t, wasm.f64t }, .result = wasm.f64t }, // fmin
    .{ .params = &.{ wasm.f64t, wasm.f64t }, .result = wasm.f64t }, // fmax
    .{ .params = &.{ wasm.f64t, wasm.f64t }, .result = wasm.f64t }, // frem
    .{ .params = &.{ wasm.i64t, wasm.i64t }, .result = wasm.i64t }, // umulhi
    .{ .params = &.{ wasm.i64t, wasm.i32t, wasm.i64t }, .result = wasm.i64t }, // mul_shift
    .{ .params = &.{wasm.i64t}, .result = wasm.i64t }, // p5fac
    .{ .params = &.{ wasm.i32t, wasm.i64t, wasm.i64t }, .result = wasm.i64t }, // wdig
    .{ .params = &.{wasm.f64t}, .result = wasm.i32t }, // fstr
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
        .obj_alloc => {
            // locals: p(0).
            try locals.append(arena, wasm.i32t);
            try a.constI32(obj_record_size);
            try a.callFunc(Rt.alloc.index());
            try a.localTee(0);
            try a.constI32(1);
            try a.store(wasm.i32_store, obj_alive);
            // Everything else (owner, length, capacity, data) is already
            // zero: bumped memory is never reused, so it is untouched.
            try a.localGet(0);
        },
        .live => {
            // params: h(0).
            try a.localGet(0);
            try a.op(wasm.i32_eqz);
            try a.trapIf(.null_object);
            try a.localGet(0);
            try a.load(wasm.i32_load, obj_alive);
            try a.op(wasm.i32_eqz);
            try a.trapIf(.use_after_free);
            try a.localGet(0);
        },
        .reserve => {
            // params: h(0), need(1), esz(2).  locals: cap(3), newcap(4), newdata(5).
            try locals.appendSlice(arena, &.{ wasm.i32t, wasm.i32t, wasm.i32t });
            try emitReserve(&a);
        },
        .list_push => {
            // params: h(0), v(1,i64).  locals: len(2), data(3).
            try locals.appendSlice(arena, &.{ wasm.i32t, wasm.i32t });
            try emitListPush(&a);
        },
        .list_get => {
            try emitListGet(&a);
        },
        .list_set => {
            // params: h(0), i(1,i64), v(2,i64).  locals: addr(3).
            try locals.append(arena, wasm.i32t);
            try emitListSet(&a);
        },
        .list_pop => {
            // params: h(0).  locals: newlen(1).
            try locals.append(arena, wasm.i32t);
            try emitListPop(&a);
        },
        .list_insert => {
            // params: h(0), i(1,i64), v(2,i64).  locals: len(3), data(4), idx(5).
            try locals.appendSlice(arena, &.{ wasm.i32t, wasm.i32t, wasm.i32t });
            try emitListInsert(&a);
        },
        .list_remove => {
            // params: h(0), i(1,i64).  locals: len(3? ), data, idx, old(i64).
            try locals.appendSlice(arena, &.{ wasm.i32t, wasm.i32t, wasm.i64t });
            try emitListRemove(&a);
        },
        .list_slice => {
            // params: h(0), start(1,i64), end(2,i64).  locals: nl(3), nh(4), buf(5).
            try locals.appendSlice(arena, &.{ wasm.i32t, wasm.i32t, wasm.i32t });
            try emitListSlice(&a);
        },
        .list_find => {
            // params: h(0), wanted(1,i64), mode(2,i32).  locals: len(3), i(4), data(5), slot(6,i64).
            try locals.appendSlice(arena, &.{ wasm.i32t, wasm.i32t, wasm.i32t, wasm.i64t });
            try emitListFind(&a);
        },
        .list_sort => {
            // params: h(0), mode(1), reverse(2).  locals: n(3), data(4), i(5), j(6),
            // lo(7), hi(8), key(9,i64), other(10,i64), tmp(11,i64).
            try locals.appendSlice(arena, &.{ wasm.i32t, wasm.i32t, wasm.i32t, wasm.i32t, wasm.i32t, wasm.i32t, wasm.i64t, wasm.i64t, wasm.i64t });
            try emitListSort(&a);
        },
        .builder_byte => {
            // params: h(0), code(1,i64).  locals: len(2), cap(3), data(4).
            try locals.appendSlice(arena, &.{ wasm.i32t, wasm.i32t, wasm.i32t });
            try emitBuilderByte(&a);
        },
        .builder_str => {
            // params: h(0), s(1).  locals: len(2), cap(3), data(4), sl(5), need(6).
            try locals.appendSlice(arena, &.{ wasm.i32t, wasm.i32t, wasm.i32t, wasm.i32t, wasm.i32t });
            try emitBuilderStr(&a);
        },
        .builder_to_str => {
            // params: h(0).  locals: bl(1), ns(2).
            try locals.appendSlice(arena, &.{ wasm.i32t, wasm.i32t });
            try emitBuilderToStr(&a);
        },
        .own_bind => try emitOwnBind(&a),
        .own_should_free => try emitOwnShouldFree(&a),
        .own_loosen_frame => try emitOwnLoosenFrame(&a),
        .own_adopt => try emitOwnSetOwner(&a, owner_container),
        .own_loosen => try emitOwnSetOwner(&a, owner_loose),
        .array_new => {
            // params: rank(0), dims(1).  locals: obj(2), total(3,i64),
            // k(4), size(5,i64).
            try locals.appendSlice(arena, &.{ wasm.i32t, wasm.i64t, wasm.i32t, wasm.i64t });
            try emitArrayNew(&a);
        },
        .map_find => {
            // params: h(0), key(1), mode(2).  locals: len(3), i(4), data(5), ekey(6,i64).
            try locals.appendSlice(arena, &.{ wasm.i32t, wasm.i32t, wasm.i32t, wasm.i64t });
            try emitMapFind(&a);
        },
        .map_index => {
            // params: h(0), key(1), mode(2).  locals: at(3).
            try locals.append(arena, wasm.i32t);
            try emitMapIndex(&a);
        },
        .map_get_or => {
            // params: h(0), key(1), mode(2), def(3).  locals: at(4).
            try locals.append(arena, wasm.i32t);
            try emitMapGetOr(&a);
        },
        .map_set => {
            // params: h(0), key(1), mode(2), val(3).  locals: at(4), data(5), len(6).
            try locals.appendSlice(arena, &.{ wasm.i32t, wasm.i32t, wasm.i32t });
            try emitMapSet(&a);
        },
        .map_remove => {
            // params: h(0), key(1), mode(2).  locals: at(3), data(4), len(5).
            try locals.appendSlice(arena, &.{ wasm.i32t, wasm.i32t, wasm.i32t });
            try emitMapRemove(&a);
        },
        .map_key_at => {
            // params: h(0), i(1).  locals: none.
            try emitMapEntryAt(&a, 0);
        },
        .map_value_at => {
            try emitMapEntryAt(&a, 8);
        },
        .map_keys => {
            // params: h(0).  locals: nl(1), i(2), len(3), data(4).
            try locals.appendSlice(arena, &.{ wasm.i32t, wasm.i32t, wasm.i32t, wasm.i32t });
            try emitMapCollect(&a, 0);
        },
        .map_values => {
            try locals.appendSlice(arena, &.{ wasm.i32t, wasm.i32t, wasm.i32t, wasm.i32t });
            try emitMapCollect(&a, 8);
        },
        .own_check => try emitOwnCheck(&a),
        .obj_clone => {
            // params: h(0), esz(1).  locals: new(2), len(3), buf(4).
            try locals.appendSlice(arena, &.{ wasm.i32t, wasm.i32t, wasm.i32t });
            try emitObjClone(&a);
        },
        .array_clone => {
            // params: h(0).  locals: new(1), len(2), buf(3).
            try locals.appendSlice(arena, &.{ wasm.i32t, wasm.i32t, wasm.i32t });
            try emitArrayClone(&a);
        },
        .fmin, .fmax => try emitFloatMinMax(&a, which == .fmin),
        .frem => {
            // params: x(0,f64), y(1,f64).
            // locals: uxi(2), uyi(3), ex(4), ey(5), sx(6), i(7) — all i64.
            try locals.appendSlice(arena, &.{ wasm.i64t, wasm.i64t, wasm.i64t, wasm.i64t, wasm.i64t, wasm.i64t });
            try emitFrem(&a);
        },
        .umulhi => {
            // params: a(0), b(1).  locals: mid(2), mid2(3) — i64.
            try locals.appendSlice(arena, &.{ wasm.i64t, wasm.i64t });
            try emitUmulhi(&a);
        },
        .mul_shift => {
            // params: m(0,i64), addr(1,i32), j(2,i64).
            // locals: sumlo(3,i64), sumhi(4,i64), sh(5,i64).
            try locals.appendSlice(arena, &.{ wasm.i64t, wasm.i64t, wasm.i64t });
            try emitMulShift(&a);
        },
        .p5fac => {
            // params: v(0,i64).  locals: n(1,i64).
            try locals.append(arena, wasm.i64t);
            try emitP5Fac(&a);
        },
        .wdig => {
            // params: addr(0,i32), value(1,i64), count(2,i64).  locals: k(3,i64).
            try locals.append(arena, wasm.i64t);
            try emitWdig(&a);
        },
        .fstr => {
            // params: x(0,f64).  locals: 19 i64 then 7 i32 (see emitFstr).
            var n: usize = 0;
            while (n < 19) : (n += 1) try locals.append(arena, wasm.i64t);
            n = 0;
            while (n < 7) : (n += 1) try locals.append(arena, wasm.i32t);
            try emitFstr(&a);
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

// -- the object heap runtime ------------------------------------------------
//
// These operate on the 40-byte records above; ownership (bind/unbind/
// adopt/free) is emitted at the use site, where the static type is
// known, not here.  `h` is always parameter 0.

/// Push `h`'s length field (i32) onto the stack.
fn objLen(a: *Asm) !void {
    try a.localGet(0);
    try a.load(wasm.i32_load, obj_length);
}
/// Push `h`'s length as an i64.
fn objLenI64(a: *Asm) !void {
    try objLen(a);
    try a.op(wasm.i64_extend_i32_u);
}
/// Push `h`'s data pointer (i32).
fn objData(a: *Asm) !void {
    try a.localGet(0);
    try a.load(wasm.i32_load, obj_data);
}
/// Trap index_bounds unless 0 <= `i_local` < length.
fn boundsGet(a: *Asm, i_local: u32) !void {
    try a.localGet(i_local);
    try a.constI64(0);
    try a.op(wasm.i64_lt_s);
    try a.localGet(i_local);
    try objLenI64(a);
    try a.op(wasm.i64_ge_s);
    try a.op(wasm.i32_or);
    try a.trapIf(.index_bounds);
}
/// Push the address of element `i_local` (an i64 index) at 8 bytes each.
fn elemAddr(a: *Asm, i_local: u32) !void {
    try objData(a);
    try a.localGet(i_local);
    try a.op(wasm.i32_wrap_i64);
    try a.constI32(3);
    try a.op(wasm.i32_shl); // * 8
    try a.op(wasm.i32_add);
}

fn emitReserve(a: *Asm) !void {
    const h = 0;
    const need = 1;
    const esz = 2;
    const cap = 3;
    const newcap = 4;
    const newdata = 5;
    try a.localGet(h);
    try a.load(wasm.i32_load, obj_capacity);
    try a.localTee(cap);
    try a.localGet(need);
    try a.op(wasm.i32_ge_u);
    try a.op(wasm.if_); // already big enough
    try a.op(wasm.empty_type);
    try a.op(wasm.ret);
    try a.op(wasm.end);
    // newcap = cap==0 ? 1 : cap ; double until >= need
    try a.localGet(cap);
    try a.localSet(newcap);
    try a.localGet(newcap);
    try a.op(wasm.i32_eqz);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.constI32(1);
    try a.localSet(newcap);
    try a.op(wasm.end);
    try a.op(wasm.block);
    try a.op(wasm.empty_type);
    try a.op(wasm.loop);
    try a.op(wasm.empty_type);
    try a.localGet(newcap);
    try a.localGet(need);
    try a.op(wasm.i32_ge_u);
    try a.op(wasm.br_if);
    try a.u32v(1);
    try a.localGet(newcap);
    try a.constI32(1);
    try a.op(wasm.i32_shl);
    try a.localSet(newcap);
    try a.op(wasm.br);
    try a.u32v(0);
    try a.op(wasm.end);
    try a.op(wasm.end);
    // newdata = alloc(newcap * esz); copy the live prefix; publish.
    try a.localGet(newcap);
    try a.localGet(esz);
    try a.op(wasm.i32_mul);
    try a.callFunc(Rt.alloc.index());
    try a.localSet(newdata);
    try a.localGet(newdata);
    try objData(a);
    try objLen(a);
    try a.localGet(esz);
    try a.op(wasm.i32_mul);
    try a.memoryCopy();
    try a.localGet(h);
    try a.localGet(newdata);
    try a.store(wasm.i32_store, obj_data);
    try a.localGet(h);
    try a.localGet(newcap);
    try a.store(wasm.i32_store, obj_capacity);
}

fn emitListPush(a: *Asm) !void {
    const v = 1;
    const len = 2;
    // reserve(h, length + 1, 8)
    try a.localGet(0);
    try objLen(a);
    try a.constI32(1);
    try a.op(wasm.i32_add);
    try a.constI32(8);
    try a.callFunc(Rt.reserve.index());
    // store v at data + length*8 ; length++
    try objLen(a);
    try a.localSet(len);
    try objData(a);
    try a.localGet(len);
    try a.constI32(3);
    try a.op(wasm.i32_shl);
    try a.op(wasm.i32_add);
    try a.localGet(v);
    try a.store(wasm.i64_store, 0);
    try a.localGet(0);
    try a.localGet(len);
    try a.constI32(1);
    try a.op(wasm.i32_add);
    try a.store(wasm.i32_store, obj_length);
}

fn emitListGet(a: *Asm) !void {
    const i = 1;
    try boundsGet(a, i);
    try elemAddr(a, i);
    try a.load(wasm.i64_load, 0);
}

fn emitListSet(a: *Asm) !void {
    const i = 1;
    const v = 2;
    const addr = 3;
    try boundsGet(a, i);
    try elemAddr(a, i);
    try a.localSet(addr);
    try a.localGet(addr);
    try a.load(wasm.i64_load, 0); // old (returned)
    try a.localGet(addr);
    try a.localGet(v);
    try a.store(wasm.i64_store, 0);
}

fn emitListPop(a: *Asm) !void {
    const newlen = 1;
    try objLen(a);
    try a.op(wasm.i32_eqz);
    try a.trapIf(.empty_collection);
    try a.localGet(0);
    try objLen(a);
    try a.constI32(1);
    try a.op(wasm.i32_sub);
    try a.localTee(newlen);
    try a.store(wasm.i32_store, obj_length);
    try objData(a);
    try a.localGet(newlen);
    try a.constI32(3);
    try a.op(wasm.i32_shl);
    try a.op(wasm.i32_add);
    try a.load(wasm.i64_load, 0);
}

fn emitListInsert(a: *Asm) !void {
    const i = 1;
    const v = 2;
    const len = 3;
    const idx = 5;
    // i < 0 or i > length -> index_bounds
    try a.localGet(i);
    try a.constI64(0);
    try a.op(wasm.i64_lt_s);
    try a.localGet(i);
    try objLenI64(a);
    try a.op(wasm.i64_gt_s);
    try a.op(wasm.i32_or);
    try a.trapIf(.index_bounds);
    try objLen(a);
    try a.localSet(len);
    try a.localGet(i);
    try a.op(wasm.i32_wrap_i64);
    try a.localSet(idx);
    // reserve(h, len + 1, 8)
    try a.localGet(0);
    try a.localGet(len);
    try a.constI32(1);
    try a.op(wasm.i32_add);
    try a.constI32(8);
    try a.callFunc(Rt.reserve.index());
    // shift [idx..len) up by one: copy(data+(idx+1)*8, data+idx*8, (len-idx)*8)
    try objData(a);
    try a.localGet(idx);
    try a.constI32(1);
    try a.op(wasm.i32_add);
    try a.constI32(3);
    try a.op(wasm.i32_shl);
    try a.op(wasm.i32_add);
    try objData(a);
    try a.localGet(idx);
    try a.constI32(3);
    try a.op(wasm.i32_shl);
    try a.op(wasm.i32_add);
    try a.localGet(len);
    try a.localGet(idx);
    try a.op(wasm.i32_sub);
    try a.constI32(3);
    try a.op(wasm.i32_shl);
    try a.memoryCopy();
    // store v at idx ; length++
    try objData(a);
    try a.localGet(idx);
    try a.constI32(3);
    try a.op(wasm.i32_shl);
    try a.op(wasm.i32_add);
    try a.localGet(v);
    try a.store(wasm.i64_store, 0);
    try a.localGet(0);
    try a.localGet(len);
    try a.constI32(1);
    try a.op(wasm.i32_add);
    try a.store(wasm.i32_store, obj_length);
}

fn emitListRemove(a: *Asm) !void {
    const i = 1;
    const len = 2;
    const idx = 3;
    const old = 4;
    try boundsGet(a, i);
    try objLen(a);
    try a.localSet(len);
    try a.localGet(i);
    try a.op(wasm.i32_wrap_i64);
    try a.localSet(idx);
    // old = slot[idx]
    try objData(a);
    try a.localGet(idx);
    try a.constI32(3);
    try a.op(wasm.i32_shl);
    try a.op(wasm.i32_add);
    try a.load(wasm.i64_load, 0);
    try a.localSet(old);
    // shift [idx+1..len) down: copy(data+idx*8, data+(idx+1)*8, (len-idx-1)*8)
    try objData(a);
    try a.localGet(idx);
    try a.constI32(3);
    try a.op(wasm.i32_shl);
    try a.op(wasm.i32_add);
    try objData(a);
    try a.localGet(idx);
    try a.constI32(1);
    try a.op(wasm.i32_add);
    try a.constI32(3);
    try a.op(wasm.i32_shl);
    try a.op(wasm.i32_add);
    try a.localGet(len);
    try a.localGet(idx);
    try a.op(wasm.i32_sub);
    try a.constI32(1);
    try a.op(wasm.i32_sub);
    try a.constI32(3);
    try a.op(wasm.i32_shl);
    try a.memoryCopy();
    try a.localGet(0);
    try a.localGet(len);
    try a.constI32(1);
    try a.op(wasm.i32_sub);
    try a.store(wasm.i32_store, obj_length);
    try a.localGet(old);
}

fn emitListSlice(a: *Asm) !void {
    const start = 1;
    const end = 2;
    const nl = 3;
    const nh = 4;
    const buf = 5;
    // start<0 or end<start or end>length -> index_bounds
    try a.localGet(start);
    try a.constI64(0);
    try a.op(wasm.i64_lt_s);
    try a.localGet(end);
    try a.localGet(start);
    try a.op(wasm.i64_lt_s);
    try a.op(wasm.i32_or);
    try a.localGet(end);
    try objLenI64(a);
    try a.op(wasm.i64_gt_s);
    try a.op(wasm.i32_or);
    try a.trapIf(.index_bounds);
    try a.localGet(end);
    try a.localGet(start);
    try a.op(wasm.i64_sub);
    try a.op(wasm.i32_wrap_i64);
    try a.localSet(nl);
    try a.callFunc(Rt.obj_alloc.index());
    try a.localSet(nh);
    // if nl > 0: buf = alloc(nl*8); copy slots; set fields
    try a.localGet(nl);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.localGet(nl);
    try a.constI32(3);
    try a.op(wasm.i32_shl);
    try a.callFunc(Rt.alloc.index());
    try a.localSet(buf);
    try a.localGet(buf);
    try objData(a);
    try a.localGet(start);
    try a.op(wasm.i32_wrap_i64);
    try a.constI32(3);
    try a.op(wasm.i32_shl);
    try a.op(wasm.i32_add);
    try a.localGet(nl);
    try a.constI32(3);
    try a.op(wasm.i32_shl);
    try a.memoryCopy();
    try a.localGet(nh);
    try a.localGet(buf);
    try a.store(wasm.i32_store, obj_data);
    try a.localGet(nh);
    try a.localGet(nl);
    try a.store(wasm.i32_store, obj_capacity);
    try a.localGet(nh);
    try a.localGet(nl);
    try a.store(wasm.i32_store, obj_length);
    try a.op(wasm.end);
    try a.localGet(nh);
}

/// left < right for the given comparison mode; both are i64 slots.
fn emitLess(a: *Asm, left_local: u32, right_local: u32, mode_local: u32) !void {
    // int mode
    try a.localGet(mode_local);
    try a.constI32(cmp_float);
    try a.op(wasm.i32_eq);
    try a.op(wasm.if_);
    try a.op(wasm.i32t);
    try a.localGet(left_local);
    try a.op(0xBF); // f64.reinterpret_i64
    try a.localGet(right_local);
    try a.op(0xBF);
    try a.op(wasm.f64_lt);
    try a.op(wasm.else_);
    try a.localGet(mode_local);
    try a.constI32(cmp_string);
    try a.op(wasm.i32_eq);
    try a.op(wasm.if_);
    try a.op(wasm.i32t);
    try a.localGet(left_local);
    try a.op(wasm.i32_wrap_i64);
    try a.localGet(right_local);
    try a.op(wasm.i32_wrap_i64);
    try a.callFunc(Rt.str_cmp.index());
    try a.constI32(0);
    try a.op(wasm.i32_lt_s);
    try a.op(wasm.else_);
    try a.localGet(left_local);
    try a.localGet(right_local);
    try a.op(wasm.i64_lt_s);
    try a.op(wasm.end);
    try a.op(wasm.end);
}

fn emitListFind(a: *Asm) !void {
    const wanted = 1;
    const mode = 2;
    const len = 3;
    const i = 4;
    const data = 5;
    const slot = 6;
    try objLen(a);
    try a.localSet(len);
    try objData(a);
    try a.localSet(data);
    try a.constI32(0);
    try a.localSet(i);
    try a.op(wasm.block);
    try a.op(wasm.empty_type);
    try a.op(wasm.loop);
    try a.op(wasm.empty_type);
    try a.localGet(i);
    try a.localGet(len);
    try a.op(wasm.i32_ge_s);
    try a.op(wasm.br_if);
    try a.u32v(1);
    try a.localGet(data);
    try a.localGet(i);
    try a.constI32(3);
    try a.op(wasm.i32_shl);
    try a.op(wasm.i32_add);
    try a.load(wasm.i64_load, 0);
    try a.localSet(slot);
    // equal? by mode
    try a.localGet(mode);
    try a.constI32(cmp_float);
    try a.op(wasm.i32_eq);
    try a.op(wasm.if_);
    try a.op(wasm.i32t);
    try a.localGet(slot);
    try a.op(0xBF);
    try a.localGet(wanted);
    try a.op(0xBF);
    try a.op(wasm.f64_eq);
    try a.op(wasm.else_);
    try a.localGet(mode);
    try a.constI32(cmp_string);
    try a.op(wasm.i32_eq);
    try a.op(wasm.if_);
    try a.op(wasm.i32t);
    try a.localGet(slot);
    try a.op(wasm.i32_wrap_i64);
    try a.localGet(wanted);
    try a.op(wasm.i32_wrap_i64);
    try a.callFunc(Rt.str_cmp.index());
    try a.op(wasm.i32_eqz);
    try a.op(wasm.else_);
    try a.localGet(slot);
    try a.localGet(wanted);
    try a.op(wasm.i64_eq);
    try a.op(wasm.end);
    try a.op(wasm.end);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.localGet(i);
    try a.op(wasm.i64_extend_i32_s);
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
}

fn emitListSort(a: *Asm) !void {
    const mode = 1;
    const reverse = 2;
    const n = 3;
    const data = 4;
    const i = 5;
    const j = 6;
    const lo = 7;
    const hi = 8;
    const key = 9;
    const other = 10;
    const tmp = 11;
    try objLen(a);
    try a.localSet(n);
    try objData(a);
    try a.localSet(data);
    try a.localGet(reverse);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    // reverse in place: lo=0, hi=n-1; while lo<hi swap
    try a.constI32(0);
    try a.localSet(lo);
    try a.localGet(n);
    try a.constI32(1);
    try a.op(wasm.i32_sub);
    try a.localSet(hi);
    try a.op(wasm.block);
    try a.op(wasm.empty_type);
    try a.op(wasm.loop);
    try a.op(wasm.empty_type);
    try a.localGet(lo);
    try a.localGet(hi);
    try a.op(wasm.i32_ge_s);
    try a.op(wasm.br_if);
    try a.u32v(1);
    // tmp = slot[lo]; slot[lo] = slot[hi]; slot[hi] = tmp
    try slotAddr(a, data, lo);
    try a.load(wasm.i64_load, 0);
    try a.localSet(tmp);
    try slotAddr(a, data, lo);
    try slotAddr(a, data, hi);
    try a.load(wasm.i64_load, 0);
    try a.store(wasm.i64_store, 0);
    try slotAddr(a, data, hi);
    try a.localGet(tmp);
    try a.store(wasm.i64_store, 0);
    try a.localGet(lo);
    try a.constI32(1);
    try a.op(wasm.i32_add);
    try a.localSet(lo);
    try a.localGet(hi);
    try a.constI32(1);
    try a.op(wasm.i32_sub);
    try a.localSet(hi);
    try a.op(wasm.br);
    try a.u32v(0);
    try a.op(wasm.end);
    try a.op(wasm.end);
    try a.op(wasm.else_);
    // insertion sort ascending: for i in 1..n
    try a.constI32(1);
    try a.localSet(i);
    try a.op(wasm.block);
    try a.op(wasm.empty_type);
    try a.op(wasm.loop);
    try a.op(wasm.empty_type);
    try a.localGet(i);
    try a.localGet(n);
    try a.op(wasm.i32_ge_s);
    try a.op(wasm.br_if);
    try a.u32v(1);
    try slotAddr(a, data, i);
    try a.load(wasm.i64_load, 0);
    try a.localSet(key);
    try a.localGet(i);
    try a.constI32(1);
    try a.op(wasm.i32_sub);
    try a.localSet(j);
    // while j >= 0 and less(key, slot[j]): slot[j+1]=slot[j]; j--
    try a.op(wasm.block);
    try a.op(wasm.empty_type);
    try a.op(wasm.loop);
    try a.op(wasm.empty_type);
    try a.localGet(j);
    try a.constI32(0);
    try a.op(wasm.i32_lt_s);
    try a.op(wasm.br_if);
    try a.u32v(1);
    try slotAddr(a, data, j);
    try a.load(wasm.i64_load, 0);
    try a.localSet(other);
    try emitLess(a, key, other, mode);
    try a.op(wasm.i32_eqz);
    try a.op(wasm.br_if);
    try a.u32v(1);
    // slot[j+1] = other
    try a.localGet(data);
    try a.localGet(j);
    try a.constI32(1);
    try a.op(wasm.i32_add);
    try a.constI32(3);
    try a.op(wasm.i32_shl);
    try a.op(wasm.i32_add);
    try a.localGet(other);
    try a.store(wasm.i64_store, 0);
    try a.localGet(j);
    try a.constI32(1);
    try a.op(wasm.i32_sub);
    try a.localSet(j);
    try a.op(wasm.br);
    try a.u32v(0);
    try a.op(wasm.end);
    try a.op(wasm.end);
    // slot[j+1] = key
    try a.localGet(data);
    try a.localGet(j);
    try a.constI32(1);
    try a.op(wasm.i32_add);
    try a.constI32(3);
    try a.op(wasm.i32_shl);
    try a.op(wasm.i32_add);
    try a.localGet(key);
    try a.store(wasm.i64_store, 0);
    try a.localGet(i);
    try a.constI32(1);
    try a.op(wasm.i32_add);
    try a.localSet(i);
    try a.op(wasm.br);
    try a.u32v(0);
    try a.op(wasm.end);
    try a.op(wasm.end);
    try a.op(wasm.end);
}

/// Push the address of slot `i_local` (an i32 index) in buffer `data_local`.
fn slotAddr(a: *Asm, data_local: u32, i_local: u32) !void {
    try a.localGet(data_local);
    try a.localGet(i_local);
    try a.constI32(3);
    try a.op(wasm.i32_shl);
    try a.op(wasm.i32_add);
}

fn emitBuilderByte(a: *Asm) !void {
    const code = 1;
    const len = 2;
    try a.localGet(code);
    try a.constI64(0);
    try a.op(wasm.i64_lt_s);
    try a.localGet(code);
    try a.constI64(0x7F);
    try a.op(wasm.i64_gt_s);
    try a.op(wasm.i32_or);
    try a.trapIf(.bad_codepoint);
    try a.localGet(0);
    try objLen(a);
    try a.constI32(1);
    try a.op(wasm.i32_add);
    try a.constI32(1);
    try a.callFunc(Rt.reserve.index());
    try objLen(a);
    try a.localSet(len);
    try objData(a);
    try a.localGet(len);
    try a.op(wasm.i32_add);
    try a.localGet(code);
    try a.op(wasm.i32_wrap_i64);
    try a.store(wasm.i32_store8, 0);
    try a.localGet(0);
    try a.localGet(len);
    try a.constI32(1);
    try a.op(wasm.i32_add);
    try a.store(wasm.i32_store, obj_length);
}

fn emitBuilderStr(a: *Asm) !void {
    const s = 1;
    const len = 2;
    const sl = 5;
    const need = 6;
    try objLen(a);
    try a.localSet(len);
    try a.localGet(s);
    try a.load(wasm.i32_load, 0);
    try a.localSet(sl);
    try a.localGet(len);
    try a.localGet(sl);
    try a.op(wasm.i32_add);
    try a.localSet(need);
    try a.localGet(0);
    try a.localGet(need);
    try a.constI32(1);
    try a.callFunc(Rt.reserve.index());
    // copy(data + len, s + 4, sl)
    try objData(a);
    try a.localGet(len);
    try a.op(wasm.i32_add);
    try a.localGet(s);
    try a.constI32(4);
    try a.op(wasm.i32_add);
    try a.localGet(sl);
    try a.memoryCopy();
    try a.localGet(0);
    try a.localGet(need);
    try a.store(wasm.i32_store, obj_length);
}

fn emitBuilderToStr(a: *Asm) !void {
    const bl = 1;
    const ns = 2;
    try objLen(a);
    try a.localSet(bl);
    try a.localGet(bl);
    try a.callFunc(Rt.str_new.index());
    try a.localSet(ns);
    try a.localGet(ns);
    try a.constI32(4);
    try a.op(wasm.i32_add);
    try objData(a);
    try a.localGet(bl);
    try a.memoryCopy();
    try a.localGet(ns);
}

/// Guard the body of an ownership helper: return early on a null or
/// freed handle (the interpreter's liveObject skip).  Leaves nothing on
/// the stack; `h` is parameter 0.
fn emitLiveGuard(a: *Asm) !void {
    try a.localGet(0);
    try a.op(wasm.i32_eqz);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.op(wasm.ret);
    try a.op(wasm.end);
    try a.localGet(0);
    try a.load(wasm.i32_load, obj_alive);
    try a.op(wasm.i32_eqz);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.op(wasm.ret);
    try a.op(wasm.end);
}

/// Push whether `h`'s owner is binding(serial, [local]) — the (serial)
/// local args are parameters 1 (i64) and, when `with_local`, 2 (i32).
fn emitOwnedByBinding(a: *Asm, with_local: bool) !void {
    try a.localGet(0);
    try a.load(wasm.i32_load, obj_owner_kind);
    try a.constI32(owner_binding);
    try a.op(wasm.i32_eq);
    try a.localGet(0);
    try a.load(wasm.i64_load, obj_owner_serial);
    try a.localGet(1);
    try a.op(wasm.i64_eq);
    try a.op(wasm.i32_and);
    if (with_local) {
        try a.localGet(0);
        try a.load(wasm.i32_load, obj_owner_local);
        try a.localGet(2);
        try a.op(wasm.i32_eq);
        try a.op(wasm.i32_and);
    }
}

fn emitOwnBind(a: *Asm) !void {
    try emitLiveGuard(a);
    try a.localGet(0);
    try a.constI32(owner_binding);
    try a.store(wasm.i32_store, obj_owner_kind);
    try a.localGet(0);
    try a.localGet(1);
    try a.store(wasm.i64_store, obj_owner_serial);
    try a.localGet(0);
    try a.localGet(2);
    try a.store(wasm.i32_store, obj_owner_local);
}

fn emitOwnShouldFree(a: *Asm) !void {
    // The scope-exit decision only: whether (serial, local) still owns
    // the object.  The caller frees through the statically-typed
    // free_object walk, so children are released too.
    try a.localGet(0);
    try a.op(wasm.i32_eqz);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.constI32(0);
    try a.op(wasm.ret);
    try a.op(wasm.end);
    try a.localGet(0);
    try a.load(wasm.i32_load, obj_alive);
    try a.op(wasm.i32_eqz);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.constI32(0);
    try a.op(wasm.ret);
    try a.op(wasm.end);
    try emitOwnedByBinding(a, true);
}

/// own_adopt / own_loosen: set a live object's owner kind.
fn emitOwnSetOwner(a: *Asm, kind: i32) !void {
    try emitLiveGuard(a);
    try a.localGet(0);
    try a.constI32(kind);
    try a.store(wasm.i32_store, obj_owner_kind);
}

// ---------------------------------------------------------------------------
// Generated ownership walks — one family per heap type, monomorphized:
// the walks the interpreter does with runtime tags, done here with the
// static type table (a List(List(Int))'s free calls its element type's
// free directly).  For non-owning element types the walks collapse to
// the plain clone/mark-dead of phase B1.
// ---------------------------------------------------------------------------

/// The function index of generated (type, kind) given where the
/// generated block starts.
fn genFuncIndex(gen_base: u32, type_index: u32, kind: u32) u32 {
    return gen_base + type_index * gen_kinds + kind;
}

/// Whether this heap type's elements (or map values) own heap objects.
fn heapTypeOwns(program: *const ir.Program, type_index: u32) bool {
    return switch (program.heap_types[type_index]) {
        .builder => false,
        .list => |element| element == .heap,
        .array => |shape| shape.element == .heap,
        .map => |pair| pair.value == .heap,
    };
}

/// The element/value heap-type index of an owning container.
fn heapChildType(program: *const ir.Program, type_index: u32) u32 {
    return switch (program.heap_types[type_index]) {
        .list => |element| element.heap,
        .array => |shape| shape.element.heap,
        .map => |pair| pair.value.heap,
        .builder => unreachable,
    };
}

fn emitGenerated(arena: Allocator, program: *const ir.Program, type_index: u32, kind: u32) ![]const u8 {
    var a: Asm = .{ .arena = arena };
    var locals: std.ArrayList(u8) = .empty;
    const gen_base = import_count + Rt.count;
    const owns = heapTypeOwns(program, type_index);
    // Slot geometry: maps hold their value at +8 of a 16-byte entry.
    const is_map = std.meta.activeTag(program.heap_types[type_index]) == .map;
    const stride: i32 = if (is_map) map_entry_size else 8;
    const value_offset: u32 = if (is_map) 8 else 0;

    switch (kind) {
        gen_free_elements => if (owns) {
            // locals: i(1,i32), len(2,i32), data(3,i32) — param h(0).
            try locals.appendSlice(arena, &.{ wasm.i32t, wasm.i32t, wasm.i32t });
            const child = heapChildType(program, type_index);
            try emitGenWalk(&a, stride, value_offset, struct {
                child_index: u32,
                base: u32,
                fn body(self: @This(), asm_: *Asm) !void {
                    // slot value (an element handle) is on the stack.
                    try asm_.op(wasm.i32_wrap_i64);
                    try asm_.callFunc(genFuncIndex(self.base, self.child_index, gen_free_object));
                }
            }{ .child_index = child, .base = gen_base });
        },
        gen_free_object => {
            try a.localGet(0);
            try a.op(wasm.i32_eqz);
            try a.op(wasm.if_);
            try a.op(wasm.empty_type);
            try a.op(wasm.ret);
            try a.op(wasm.end);
            try a.localGet(0);
            try a.load(wasm.i32_load, obj_alive);
            try a.op(wasm.i32_eqz);
            try a.op(wasm.if_);
            try a.op(wasm.empty_type);
            try a.op(wasm.ret);
            try a.op(wasm.end);
            try a.localGet(0);
            try a.constI32(0);
            try a.store(wasm.i32_store, obj_alive);
            if (owns) {
                try a.localGet(0);
                try a.callFunc(genFuncIndex(gen_base, type_index, gen_free_elements));
            }
        },
        gen_copy_object => {
            // Null passes through (the interpreter's deepCopy rule).
            try a.localGet(0);
            try a.op(wasm.i32_eqz);
            try a.op(wasm.if_);
            try a.op(wasm.empty_type);
            try a.constI32(0);
            try a.op(wasm.ret);
            try a.op(wasm.end);
            switch (program.heap_types[type_index]) {
                .array => {
                    try a.localGet(0);
                    try a.callFunc(Rt.array_clone.index());
                },
                .builder => {
                    try a.localGet(0);
                    try a.constI32(1);
                    try a.callFunc(Rt.obj_clone.index());
                },
                .map => {
                    try a.localGet(0);
                    try a.constI32(map_entry_size);
                    try a.callFunc(Rt.obj_clone.index());
                },
                .list => {
                    try a.localGet(0);
                    try a.constI32(8);
                    try a.callFunc(Rt.obj_clone.index());
                },
            }
            if (owns) {
                // locals: clone(1,i32) — deep-copy the elements in place.
                try locals.append(arena, wasm.i32t);
                try a.localSet(1);
                try a.localGet(1);
                try a.callFunc(genFuncIndex(gen_base, type_index, gen_own_elements));
                try a.localGet(1);
            }
        },
        gen_own_elements => if (owns) {
            // locals: i(1,i32), len(2,i32), data(3,i32) — replace each
            // element with an adopted deep copy (list_slice/map_values/
            // copy all need exactly this walk).
            try locals.appendSlice(arena, &.{ wasm.i32t, wasm.i32t, wasm.i32t });
            const child = heapChildType(program, type_index);
            try emitGenWalkAddr(&a, stride, value_offset, struct {
                child_index: u32,
                base: u32,
                fn body(self: @This(), asm_: *Asm) !void {
                    // slot address is in local 4; load, copy, adopt, store.
                    try asm_.localGet(4);
                    try asm_.load(wasm.i64_load, 0);
                    try asm_.op(wasm.i32_wrap_i64);
                    try asm_.callFunc(genFuncIndex(self.base, self.child_index, gen_copy_object));
                    try asm_.localTee(5);
                    try asm_.callFunc(Rt.own_adopt.index());
                    try asm_.localGet(4);
                    try asm_.localGet(5);
                    try asm_.op(wasm.i64_extend_i32_u);
                    try asm_.store(wasm.i64_store, 0);
                }
            }{ .child_index = child, .base = gen_base });
        },
        else => unreachable,
    }
    try a.op(wasm.end);

    var out: std.ArrayList(u8) = .empty;
    if (kind == gen_own_elements and owns) {
        // The addr walk needs two extra scratch i32s (addr, copied).
        try locals.appendSlice(arena, &.{ wasm.i32t, wasm.i32t });
    }
    try appendRunLength(&out, arena, locals.items);
    try out.appendSlice(arena, a.code.items);
    return out.items;
}

/// Loop over an object's slots pushing each slot VALUE (i64) for the
/// callback.  param h=0; locals i=1, len=2, data=3.
fn emitGenWalk(a: *Asm, stride: i32, value_offset: u32, callback: anytype) !void {
    try emitGenWalkSetup(a);
    try a.op(wasm.block);
    try a.op(wasm.empty_type);
    try a.op(wasm.loop);
    try a.op(wasm.empty_type);
    try a.localGet(1);
    try a.localGet(2);
    try a.op(wasm.i32_ge_s);
    try a.op(wasm.br_if);
    try a.u32v(1);
    try a.localGet(3);
    try a.localGet(1);
    try a.constI32(stride);
    try a.op(wasm.i32_mul);
    try a.op(wasm.i32_add);
    try a.load(wasm.i64_load, value_offset);
    try callback.body(a);
    try emitGenWalkStep(a);
    try a.op(wasm.end);
    try a.op(wasm.end);
}

/// Loop over an object's slots leaving each slot ADDRESS in local 4 for
/// the callback.  param h=0; locals i=1, len=2, data=3, addr=4, tmp=5.
fn emitGenWalkAddr(a: *Asm, stride: i32, value_offset: u32, callback: anytype) !void {
    try emitGenWalkSetup(a);
    try a.op(wasm.block);
    try a.op(wasm.empty_type);
    try a.op(wasm.loop);
    try a.op(wasm.empty_type);
    try a.localGet(1);
    try a.localGet(2);
    try a.op(wasm.i32_ge_s);
    try a.op(wasm.br_if);
    try a.u32v(1);
    try a.localGet(3);
    try a.localGet(1);
    try a.constI32(stride);
    try a.op(wasm.i32_mul);
    try a.op(wasm.i32_add);
    try a.constI32(@intCast(value_offset));
    try a.op(wasm.i32_add);
    try a.localSet(4);
    try callback.body(a);
    try emitGenWalkStep(a);
    try a.op(wasm.end);
    try a.op(wasm.end);
}

fn emitGenWalkSetup(a: *Asm) !void {
    try a.constI32(0);
    try a.localSet(1);
    try a.localGet(0);
    try a.load(wasm.i32_load, obj_length);
    try a.localSet(2);
    try a.localGet(0);
    try a.load(wasm.i32_load, obj_data);
    try a.localSet(3);
}

fn emitGenWalkStep(a: *Asm) !void {
    try a.localGet(1);
    try a.constI32(1);
    try a.op(wasm.i32_add);
    try a.localSet(1);
    try a.op(wasm.br);
    try a.u32v(0);
}

fn emitOwnLoosenFrame(a: *Asm) !void {
    try emitLiveGuard(a);
    try emitOwnedByBinding(a, false);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.localGet(0);
    try a.constI32(owner_loose);
    try a.store(wasm.i32_store, obj_owner_kind);
    try a.op(wasm.end);
}

/// A safety valve matching the interpreter: one array cannot exceed
/// this many elements (a dim or the product beyond it traps index_bounds).
const max_array_elements: i64 = 1 << 24;

fn emitArrayNew(a: *Asm) !void {
    const rank = 0;
    const dims = 1;
    const obj = 2;
    const total = 3;
    const k = 4;
    const size = 5;
    try a.callFunc(Rt.obj_alloc.index());
    try a.localSet(obj);
    try a.constI64(1);
    try a.localSet(total);
    try a.constI32(0);
    try a.localSet(k);
    try a.op(wasm.block);
    try a.op(wasm.empty_type);
    try a.op(wasm.loop);
    try a.op(wasm.empty_type);
    try a.localGet(k);
    try a.localGet(rank);
    try a.op(wasm.i32_ge_s);
    try a.op(wasm.br_if);
    try a.u32v(1);
    // size = dims[k]
    try a.localGet(dims);
    try a.localGet(k);
    try a.constI32(3);
    try a.op(wasm.i32_shl);
    try a.op(wasm.i32_add);
    try a.load(wasm.i64_load, 0);
    try a.localSet(size);
    // size < 0 or size > max -> index_bounds
    try a.localGet(size);
    try a.constI64(0);
    try a.op(wasm.i64_lt_s);
    try a.localGet(size);
    try a.constI64(max_array_elements);
    try a.op(wasm.i64_gt_s);
    try a.op(wasm.i32_or);
    try a.trapIf(.index_bounds);
    // total *= size ; total > max -> index_bounds
    try a.localGet(total);
    try a.localGet(size);
    try a.op(wasm.i64_mul);
    try a.localTee(total);
    try a.constI64(max_array_elements);
    try a.op(wasm.i64_gt_s);
    try a.trapIf(.index_bounds);
    try a.localGet(k);
    try a.constI32(1);
    try a.op(wasm.i32_add);
    try a.localSet(k);
    try a.op(wasm.br);
    try a.u32v(0);
    try a.op(wasm.end);
    try a.op(wasm.end);
    // elements = alloc(total * 8), zero by construction
    try a.localGet(obj);
    try a.localGet(total);
    try a.op(wasm.i32_wrap_i64);
    try a.constI32(3);
    try a.op(wasm.i32_shl);
    try a.callFunc(Rt.alloc.index());
    try a.store(wasm.i32_store, obj_data);
    try a.localGet(obj);
    try a.localGet(total);
    try a.op(wasm.i32_wrap_i64);
    try a.store(wasm.i32_store, obj_length);
    try a.localGet(obj);
    try a.localGet(dims);
    try a.store(wasm.i32_store, obj_dims);
    try a.localGet(obj);
    try a.localGet(rank);
    try a.store(wasm.i32_store, obj_rank);
    try a.localGet(obj);
}

const map_entry_size = 16;

/// entry key/value address: data + i*16 (+8 for the value).
fn emitEntryAddr(a: *Asm, data_local: u32, i_local: u32, field: u32) !void {
    try a.localGet(data_local);
    try a.localGet(i_local);
    try a.constI32(4); // *16
    try a.op(wasm.i32_shl);
    try a.op(wasm.i32_add);
    if (field != 0) {
        try a.constI32(@intCast(field));
        try a.op(wasm.i32_add);
    }
}

/// Whether entry key `ekey_local` equals `key_local` under `mode_local`
/// (leaves an i32 on the stack): string keys compare bytes, else i64.
fn emitKeyEq(a: *Asm, ekey_local: u32, key_local: u32, mode_local: u32) !void {
    try a.localGet(mode_local);
    try a.constI32(cmp_string);
    try a.op(wasm.i32_eq);
    try a.op(wasm.if_);
    try a.op(wasm.i32t);
    try a.localGet(ekey_local);
    try a.op(wasm.i32_wrap_i64);
    try a.localGet(key_local);
    try a.op(wasm.i32_wrap_i64);
    try a.callFunc(Rt.str_cmp.index());
    try a.op(wasm.i32_eqz);
    try a.op(wasm.else_);
    try a.localGet(ekey_local);
    try a.localGet(key_local);
    try a.op(wasm.i64_eq);
    try a.op(wasm.end);
}

fn emitMapFind(a: *Asm) !void {
    const key = 1;
    const mode = 2;
    const len = 3;
    const i = 4;
    const data = 5;
    const ekey = 6;
    try a.localGet(0);
    try a.load(wasm.i32_load, obj_length);
    try a.localSet(len);
    try a.localGet(0);
    try a.load(wasm.i32_load, obj_data);
    try a.localSet(data);
    try a.constI32(0);
    try a.localSet(i);
    try a.op(wasm.block);
    try a.op(wasm.empty_type);
    try a.op(wasm.loop);
    try a.op(wasm.empty_type);
    try a.localGet(i);
    try a.localGet(len);
    try a.op(wasm.i32_ge_s);
    try a.op(wasm.br_if);
    try a.u32v(1);
    try emitEntryAddr(a, data, i, 0);
    try a.load(wasm.i64_load, 0);
    try a.localSet(ekey);
    try emitKeyEq(a, ekey, key, mode);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.localGet(i);
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
    try a.constI32(-1);
}

fn emitMapIndex(a: *Asm) !void {
    const key = 1;
    const mode = 2;
    const at = 3;
    try a.localGet(0);
    try a.localGet(key);
    try a.localGet(mode);
    try a.callFunc(Rt.map_find.index());
    try a.localTee(at);
    try a.constI32(0);
    try a.op(wasm.i32_lt_s);
    try a.trapIf(.key_missing);
    try a.localGet(0);
    try a.load(wasm.i32_load, obj_data);
    try a.localGet(at);
    try a.constI32(4);
    try a.op(wasm.i32_shl);
    try a.op(wasm.i32_add);
    try a.load(wasm.i64_load, 8);
}

fn emitMapGetOr(a: *Asm) !void {
    const key = 1;
    const mode = 2;
    const def = 3;
    const at = 4;
    try a.localGet(0);
    try a.localGet(key);
    try a.localGet(mode);
    try a.callFunc(Rt.map_find.index());
    try a.localTee(at);
    try a.constI32(0);
    try a.op(wasm.i32_ge_s);
    try a.op(wasm.if_);
    try a.op(wasm.i64t);
    try a.localGet(0);
    try a.load(wasm.i32_load, obj_data);
    try a.localGet(at);
    try a.constI32(4);
    try a.op(wasm.i32_shl);
    try a.op(wasm.i32_add);
    try a.load(wasm.i64_load, 8);
    try a.op(wasm.else_);
    try a.localGet(def);
    try a.op(wasm.end);
}

fn emitMapSet(a: *Asm) !void {
    const key = 1;
    const mode = 2;
    const val = 3;
    const at = 4;
    const data = 5;
    const len = 6;
    try a.localGet(0);
    try a.localGet(key);
    try a.localGet(mode);
    try a.callFunc(Rt.map_find.index());
    try a.localTee(at);
    try a.constI32(0);
    try a.op(wasm.i32_ge_s);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    // replace value in place
    try a.localGet(0);
    try a.load(wasm.i32_load, obj_data);
    try a.localGet(at);
    try a.constI32(4);
    try a.op(wasm.i32_shl);
    try a.op(wasm.i32_add);
    try a.localGet(val);
    try a.store(wasm.i64_store, 8);
    try a.op(wasm.else_);
    // append a new entry
    try a.localGet(0);
    try a.localGet(0);
    try a.load(wasm.i32_load, obj_length);
    try a.constI32(1);
    try a.op(wasm.i32_add);
    try a.constI32(map_entry_size);
    try a.callFunc(Rt.reserve.index());
    try a.localGet(0);
    try a.load(wasm.i32_load, obj_data);
    try a.localSet(data);
    try a.localGet(0);
    try a.load(wasm.i32_load, obj_length);
    try a.localSet(len);
    try emitEntryAddr(a, data, len, 0);
    try a.localGet(key);
    try a.store(wasm.i64_store, 0);
    try emitEntryAddr(a, data, len, 0);
    try a.localGet(val);
    try a.store(wasm.i64_store, 8);
    try a.localGet(0);
    try a.localGet(len);
    try a.constI32(1);
    try a.op(wasm.i32_add);
    try a.store(wasm.i32_store, obj_length);
    try a.op(wasm.end);
}

fn emitMapRemove(a: *Asm) !void {
    const key = 1;
    const mode = 2;
    const at = 3;
    const data = 4;
    const len = 5;
    try a.localGet(0);
    try a.localGet(key);
    try a.localGet(mode);
    try a.callFunc(Rt.map_find.index());
    try a.localTee(at);
    try a.constI32(0);
    try a.op(wasm.i32_ge_s);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.localGet(0);
    try a.load(wasm.i32_load, obj_data);
    try a.localSet(data);
    try a.localGet(0);
    try a.load(wasm.i32_load, obj_length);
    try a.localSet(len);
    // copy(data+at*16, data+(at+1)*16, (len-at-1)*16)
    try emitEntryAddr(a, data, at, 0);
    try a.localGet(data);
    try a.localGet(at);
    try a.constI32(1);
    try a.op(wasm.i32_add);
    try a.constI32(4);
    try a.op(wasm.i32_shl);
    try a.op(wasm.i32_add);
    try a.localGet(len);
    try a.localGet(at);
    try a.op(wasm.i32_sub);
    try a.constI32(1);
    try a.op(wasm.i32_sub);
    try a.constI32(4);
    try a.op(wasm.i32_shl);
    try a.memoryCopy();
    try a.localGet(0);
    try a.localGet(len);
    try a.constI32(1);
    try a.op(wasm.i32_sub);
    try a.store(wasm.i32_store, obj_length);
    try a.op(wasm.end);
}

/// map_key_at / map_value_at: bounds-checked entry field read.
fn emitMapEntryAt(a: *Asm, field: u32) !void {
    const i = 1;
    try a.localGet(i);
    try a.constI64(0);
    try a.op(wasm.i64_lt_s);
    try a.localGet(i);
    try a.localGet(0);
    try a.load(wasm.i32_load, obj_length);
    try a.op(wasm.i64_extend_i32_u);
    try a.op(wasm.i64_ge_s);
    try a.op(wasm.i32_or);
    try a.trapIf(.index_bounds);
    try a.localGet(0);
    try a.load(wasm.i32_load, obj_data);
    try a.localGet(i);
    try a.op(wasm.i32_wrap_i64);
    try a.constI32(4);
    try a.op(wasm.i32_shl);
    try a.op(wasm.i32_add);
    try a.load(wasm.i64_load, field);
}

/// map_keys / map_values: a new List filled with each entry's key or
/// value (scalar copy); reuses list_push.
fn emitMapCollect(a: *Asm, field: u32) !void {
    const nl = 1;
    const i = 2;
    const len = 3;
    const data = 4;
    try a.callFunc(Rt.obj_alloc.index());
    try a.localSet(nl);
    try a.localGet(0);
    try a.load(wasm.i32_load, obj_length);
    try a.localSet(len);
    try a.localGet(0);
    try a.load(wasm.i32_load, obj_data);
    try a.localSet(data);
    try a.constI32(0);
    try a.localSet(i);
    try a.op(wasm.block);
    try a.op(wasm.empty_type);
    try a.op(wasm.loop);
    try a.op(wasm.empty_type);
    try a.localGet(i);
    try a.localGet(len);
    try a.op(wasm.i32_ge_s);
    try a.op(wasm.br_if);
    try a.u32v(1);
    try a.localGet(nl);
    try emitEntryAddr(a, data, i, field);
    try a.load(wasm.i64_load, 0);
    try a.callFunc(Rt.list_push.index());
    try a.localGet(i);
    try a.constI32(1);
    try a.op(wasm.i32_add);
    try a.localSet(i);
    try a.op(wasm.br);
    try a.u32v(0);
    try a.op(wasm.end);
    try a.op(wasm.end);
    try a.localGet(nl);
}

/// checkGivable (S23): a null handle is givable; a freed one traps
/// use_after_free; a container-owned one, or one the named binding no
/// longer owns, traps not_owned.
fn emitOwnCheck(a: *Asm) !void {
    const has_expected = 1;
    const serial = 2;
    const local = 3;
    try a.localGet(0);
    try a.op(wasm.i32_eqz);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.op(wasm.ret);
    try a.op(wasm.end);
    try a.localGet(0);
    try a.load(wasm.i32_load, obj_alive);
    try a.op(wasm.i32_eqz);
    try a.trapIf(.use_after_free);
    try a.localGet(0);
    try a.load(wasm.i32_load, obj_owner_kind);
    try a.constI32(owner_container);
    try a.op(wasm.i32_eq);
    try a.trapIf(.not_owned);
    try a.localGet(has_expected);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.localGet(0);
    try a.load(wasm.i32_load, obj_owner_kind);
    try a.constI32(owner_binding);
    try a.op(wasm.i32_eq);
    try a.localGet(0);
    try a.load(wasm.i64_load, obj_owner_serial);
    try a.localGet(serial);
    try a.op(wasm.i64_eq);
    try a.op(wasm.i32_and);
    try a.localGet(0);
    try a.load(wasm.i32_load, obj_owner_local);
    try a.localGet(local);
    try a.op(wasm.i32_eq);
    try a.op(wasm.i32_and);
    try a.op(wasm.i32_eqz);
    try a.trapIf(.not_owned);
    try a.op(wasm.end);
}

/// A shallow clone of a List/Map/Builder: a fresh loose object whose
/// data buffer duplicates the source's (elements are scalars here, so
/// this is a full deep copy; object elements are a later phase).
fn emitObjClone(a: *Asm) !void {
    const esz = 1;
    const new = 2;
    const len = 3;
    const buf = 4;
    try a.callFunc(Rt.obj_alloc.index());
    try a.localSet(new);
    try a.localGet(0);
    try a.load(wasm.i32_load, obj_length);
    try a.localSet(len);
    try a.localGet(len);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.localGet(len);
    try a.localGet(esz);
    try a.op(wasm.i32_mul);
    try a.callFunc(Rt.alloc.index());
    try a.localSet(buf);
    try a.localGet(buf);
    try a.localGet(0);
    try a.load(wasm.i32_load, obj_data);
    try a.localGet(len);
    try a.localGet(esz);
    try a.op(wasm.i32_mul);
    try a.memoryCopy();
    try a.localGet(new);
    try a.localGet(buf);
    try a.store(wasm.i32_store, obj_data);
    try a.localGet(new);
    try a.localGet(len);
    try a.store(wasm.i32_store, obj_capacity);
    try a.localGet(new);
    try a.localGet(len);
    try a.store(wasm.i32_store, obj_length);
    try a.op(wasm.end);
    try a.localGet(new);
}

/// fmin/fmax bodies: `x != x` detects NaN; a NaN operand returns the
/// other (matching Zig's @min/@max, which the interpreter uses), then
/// the wasm opcode supplies the ordering — including -0 < +0.
fn emitFloatMinMax(a: *Asm, want_min: bool) !void {
    try a.localGet(0);
    try a.localGet(0);
    try a.op(wasm.f64_ne); // a is NaN
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.localGet(1);
    try a.op(wasm.ret);
    try a.op(wasm.end);
    try a.localGet(1);
    try a.localGet(1);
    try a.op(wasm.f64_ne); // b is NaN
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.localGet(0);
    try a.op(wasm.ret);
    try a.op(wasm.end);
    try a.localGet(0);
    try a.localGet(1);
    try a.op(if (want_min) wasm.f64_min else wasm.f64_max);
}

/// frem body: fmod(x, y), musl's integer-shift algorithm — the same
/// one Zig's compiler_rt gives @rem on doubles, so results (value,
/// result sign on ±0, NaN-ness) are bit-identical to the interpreter.
/// Locals: x=0, y=1 (f64); uxi=2, uyi=3, ex=4, ey=5, sx=6, i=7 (i64).
fn emitFrem(a: *Asm) !void {
    const x = 0;
    const y = 1;
    const uxi = 2;
    const uyi = 3;
    const ex = 4;
    const ey = 5;
    const sx = 6;
    const iv = 7;
    const implicit_bit: i64 = 1 << 52;

    try a.localGet(x);
    try a.op(wasm.i64_reinterpret_f64);
    try a.localSet(uxi);
    try a.localGet(y);
    try a.op(wasm.i64_reinterpret_f64);
    try a.localSet(uyi);
    // ex/ey: biased exponents; sx: x's sign bit.
    try a.localGet(uxi);
    try a.constI64(52);
    try a.op(wasm.i64_shr_u);
    try a.constI64(0x7FF);
    try a.op(wasm.i64_and);
    try a.localSet(ex);
    try a.localGet(uyi);
    try a.constI64(52);
    try a.op(wasm.i64_shr_u);
    try a.constI64(0x7FF);
    try a.op(wasm.i64_and);
    try a.localSet(ey);
    try a.localGet(uxi);
    try a.constI64(63);
    try a.op(wasm.i64_shr_u);
    try a.localSet(sx);

    // y == ±0, y NaN, or x inf/NaN -> NaN via (x*y)/(x*y).
    try a.localGet(uyi);
    try a.constI64(1);
    try a.op(wasm.i64_shl);
    try a.op(wasm.i64_eqz);
    try a.localGet(y);
    try a.localGet(y);
    try a.op(wasm.f64_ne);
    try a.op(wasm.i32_or);
    try a.localGet(ex);
    try a.constI64(0x7FF);
    try a.op(wasm.i64_eq);
    try a.op(wasm.i32_or);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.localGet(x);
    try a.localGet(y);
    try a.op(wasm.f64_mul);
    try a.localGet(x);
    try a.localGet(y);
    try a.op(wasm.f64_mul);
    try a.op(wasm.f64_div);
    try a.op(wasm.ret);
    try a.op(wasm.end);

    // |x| <= |y|: equal magnitudes -> ±0 with x's sign; else x itself.
    try a.localGet(uxi);
    try a.constI64(1);
    try a.op(wasm.i64_shl);
    try a.localGet(uyi);
    try a.constI64(1);
    try a.op(wasm.i64_shl);
    try a.op(wasm.i64_le_u);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.localGet(uxi);
    try a.constI64(1);
    try a.op(wasm.i64_shl);
    try a.localGet(uyi);
    try a.constI64(1);
    try a.op(wasm.i64_shl);
    try a.op(wasm.i64_eq);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.constF64(0.0);
    try a.localGet(x);
    try a.op(wasm.f64_mul); // 0*x: ±0 with x's sign
    try a.op(wasm.ret);
    try a.op(wasm.end);
    try a.localGet(x);
    try a.op(wasm.ret);
    try a.op(wasm.end);

    // Normalize x: subnormals shift their mantissa up; normals get the
    // implicit bit made explicit.
    try emitFremNormalize(a, ex, uxi, iv);
    // Normalize y likewise.
    try emitFremNormalize(a, ey, uyi, iv);

    // The division loop: while ex > ey, subtract-and-shift.
    try a.op(wasm.block);
    try a.op(wasm.empty_type);
    try a.op(wasm.loop);
    try a.op(wasm.empty_type);
    try a.localGet(ex);
    try a.localGet(ey);
    try a.op(wasm.i64_le_s);
    try a.op(wasm.br_if);
    try a.u32v(1);
    try emitFremStep(a, uxi, uyi, iv, x);
    try a.localGet(uxi);
    try a.constI64(1);
    try a.op(wasm.i64_shl);
    try a.localSet(uxi);
    try a.localGet(ex);
    try a.constI64(1);
    try a.op(wasm.i64_sub);
    try a.localSet(ex);
    try a.op(wasm.br);
    try a.u32v(0);
    try a.op(wasm.end);
    try a.op(wasm.end);
    // One final subtract at equal exponents.
    try emitFremStep(a, uxi, uyi, iv, x);

    // Renormalize the remainder mantissa.
    try a.op(wasm.block);
    try a.op(wasm.empty_type);
    try a.op(wasm.loop);
    try a.op(wasm.empty_type);
    try a.localGet(uxi);
    try a.constI64(52);
    try a.op(wasm.i64_shr_u);
    try a.constI64(0);
    try a.op(wasm.i64_ne);
    try a.op(wasm.br_if);
    try a.u32v(1);
    try a.localGet(uxi);
    try a.constI64(1);
    try a.op(wasm.i64_shl);
    try a.localSet(uxi);
    try a.localGet(ex);
    try a.constI64(1);
    try a.op(wasm.i64_sub);
    try a.localSet(ex);
    try a.op(wasm.br);
    try a.u32v(0);
    try a.op(wasm.end);
    try a.op(wasm.end);

    // Scale back: a positive exponent re-biases; otherwise subnormal.
    try a.localGet(ex);
    try a.constI64(0);
    try a.op(wasm.i64_gt_s);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.localGet(uxi);
    try a.constI64(implicit_bit);
    try a.op(wasm.i64_sub);
    try a.localGet(ex);
    try a.constI64(52);
    try a.op(wasm.i64_shl);
    try a.op(wasm.i64_or);
    try a.localSet(uxi);
    try a.op(wasm.else_);
    try a.localGet(uxi);
    try a.constI64(1);
    try a.localGet(ex);
    try a.op(wasm.i64_sub);
    try a.op(wasm.i64_shr_u);
    try a.localSet(uxi);
    try a.op(wasm.end);
    // Restore x's sign and reinterpret.
    try a.localGet(uxi);
    try a.localGet(sx);
    try a.constI64(63);
    try a.op(wasm.i64_shl);
    try a.op(wasm.i64_or);
    try a.op(wasm.f64_reinterpret_i64);
}

/// Normalize one operand for frem: a zero exponent (subnormal) walks
/// the mantissa left until the would-be implicit bit reaches the top,
/// decrementing the exponent; a normal masks and sets the implicit bit.
fn emitFremNormalize(a: *Asm, e_local: u32, u_local: u32, i_local: u32) !void {
    try a.localGet(e_local);
    try a.op(wasm.i64_eqz);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    // i = u << 12; while i >= 0 (top bit clear): e--; i <<= 1
    try a.localGet(u_local);
    try a.constI64(12);
    try a.op(wasm.i64_shl);
    try a.localSet(i_local);
    try a.op(wasm.block);
    try a.op(wasm.empty_type);
    try a.op(wasm.loop);
    try a.op(wasm.empty_type);
    try a.localGet(i_local);
    try a.constI64(0);
    try a.op(wasm.i64_lt_s);
    try a.op(wasm.br_if);
    try a.u32v(1);
    try a.localGet(e_local);
    try a.constI64(1);
    try a.op(wasm.i64_sub);
    try a.localSet(e_local);
    try a.localGet(i_local);
    try a.constI64(1);
    try a.op(wasm.i64_shl);
    try a.localSet(i_local);
    try a.op(wasm.br);
    try a.u32v(0);
    try a.op(wasm.end);
    try a.op(wasm.end);
    // u <<= (1 - e)
    try a.localGet(u_local);
    try a.constI64(1);
    try a.localGet(e_local);
    try a.op(wasm.i64_sub);
    try a.op(wasm.i64_shl);
    try a.localSet(u_local);
    try a.op(wasm.else_);
    try a.localGet(u_local);
    try a.constI64(0xFFFFFFFFFFFFF);
    try a.op(wasm.i64_and);
    try a.constI64(1 << 52);
    try a.op(wasm.i64_or);
    try a.localSet(u_local);
    try a.op(wasm.end);
}

/// One subtract step of frem: i = ux - uy; if i >= 0 { if i == 0
/// return ±0 with x's sign; ux = i }.
fn emitFremStep(a: *Asm, ux_local: u32, uy_local: u32, i_local: u32, x_local: u32) !void {
    try a.localGet(ux_local);
    try a.localGet(uy_local);
    try a.op(wasm.i64_sub);
    try a.localSet(i_local);
    try a.localGet(i_local);
    try a.constI64(0);
    try a.op(wasm.i64_ge_s);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.localGet(i_local);
    try a.op(wasm.i64_eqz);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.constF64(0.0);
    try a.localGet(x_local);
    try a.op(wasm.f64_mul);
    try a.op(wasm.ret);
    try a.op(wasm.end);
    try a.localGet(i_local);
    try a.localSet(ux_local);
    try a.op(wasm.end);
}

/// umulhi: the high 64 bits of a*b, via four 32-bit partial products.
/// params a=0, b=1; locals mid=2, mid2=3.
fn emitUmulhi(a: *Asm) !void {
    const mid = 2;
    const mid2 = 3;
    const mask32: i64 = 0xFFFFFFFF;
    // mid = (a>>32)*(b&M) + ((a&M)*(b&M) >> 32)
    try a.localGet(0);
    try a.constI64(32);
    try a.op(wasm.i64_shr_u);
    try a.localGet(1);
    try a.constI64(mask32);
    try a.op(wasm.i64_and);
    try a.op(wasm.i64_mul);
    try a.localGet(0);
    try a.constI64(mask32);
    try a.op(wasm.i64_and);
    try a.localGet(1);
    try a.constI64(mask32);
    try a.op(wasm.i64_and);
    try a.op(wasm.i64_mul);
    try a.constI64(32);
    try a.op(wasm.i64_shr_u);
    try a.op(wasm.i64_add);
    try a.localSet(mid);
    // mid2 = (a&M)*(b>>32) + (mid & M)
    try a.localGet(0);
    try a.constI64(mask32);
    try a.op(wasm.i64_and);
    try a.localGet(1);
    try a.constI64(32);
    try a.op(wasm.i64_shr_u);
    try a.op(wasm.i64_mul);
    try a.localGet(mid);
    try a.constI64(mask32);
    try a.op(wasm.i64_and);
    try a.op(wasm.i64_add);
    try a.localSet(mid2);
    // result = (a>>32)*(b>>32) + (mid>>32) + (mid2>>32)
    try a.localGet(0);
    try a.constI64(32);
    try a.op(wasm.i64_shr_u);
    try a.localGet(1);
    try a.constI64(32);
    try a.op(wasm.i64_shr_u);
    try a.op(wasm.i64_mul);
    try a.localGet(mid);
    try a.constI64(32);
    try a.op(wasm.i64_shr_u);
    try a.op(wasm.i64_add);
    try a.localGet(mid2);
    try a.constI64(32);
    try a.op(wasm.i64_shr_u);
    try a.op(wasm.i64_add);
}

/// ryu mulShift64: ((m*mul.lo >> 64) + m*mul.hi) >> (j-64), the 128-bit
/// sum carried by hand.  params m=0, addr=1(i32), j=2; locals sumlo=3,
/// sumhi=4, sh=5.
fn emitMulShift(a: *Asm) !void {
    const m = 0;
    const addr = 1;
    const j = 2;
    const sumlo = 3;
    const sumhi = 4;
    const sh = 5;
    // sumlo = m*hi (low half); add b0hi = umulhi(m, lo) with carry.
    try a.localGet(m);
    try a.localGet(addr);
    try a.load(wasm.i64_load, 8); // mul.hi
    try a.op(wasm.i64_mul);
    try a.localSet(sumlo);
    // sumhi = umulhi(m, hi)
    try a.localGet(m);
    try a.localGet(addr);
    try a.load(wasm.i64_load, 8);
    try a.callFunc(Rt.umulhi.index());
    try a.localSet(sumhi);
    // tmp := umulhi(m, lo); sumlo += tmp; carry into sumhi.
    try a.localGet(sumlo);
    try a.localGet(m);
    try a.localGet(addr);
    try a.load(wasm.i64_load, 0); // mul.lo
    try a.callFunc(Rt.umulhi.index());
    try a.op(wasm.i64_add);
    try a.localTee(sh); // reuse sh briefly as the new low word
    try a.localGet(sumlo);
    try a.op(wasm.i64_lt_u); // wrapped -> carry
    try a.op(wasm.i64_extend_i32_u);
    try a.localGet(sumhi);
    try a.op(wasm.i64_add);
    try a.localSet(sumhi);
    try a.localGet(sh);
    try a.localSet(sumlo);
    // sh = j - 64 (always 1..63 for f64); result = sumlo>>sh | sumhi<<(64-sh)
    try a.localGet(j);
    try a.constI64(64);
    try a.op(wasm.i64_sub);
    try a.localSet(sh);
    try a.localGet(sumlo);
    try a.localGet(sh);
    try a.op(wasm.i64_shr_u);
    try a.localGet(sumhi);
    try a.constI64(64);
    try a.localGet(sh);
    try a.op(wasm.i64_sub);
    try a.op(wasm.i64_shl);
    try a.op(wasm.i64_or);
}

/// p5fac: how many times 5 divides v.  params v=0; locals n=1.
fn emitP5Fac(a: *Asm) !void {
    const v = 0;
    const n = 1;
    try a.constI64(0);
    try a.localSet(n);
    try a.op(wasm.block);
    try a.op(wasm.empty_type);
    try a.op(wasm.loop);
    try a.op(wasm.empty_type);
    try a.localGet(v);
    try a.op(wasm.i64_eqz);
    try a.op(wasm.br_if);
    try a.u32v(1);
    try a.localGet(v);
    try a.constI64(5);
    try a.op(wasm.i64_rem_u);
    try a.constI64(0);
    try a.op(wasm.i64_ne);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.localGet(n);
    try a.op(wasm.ret);
    try a.op(wasm.end);
    try a.localGet(n);
    try a.constI64(1);
    try a.op(wasm.i64_add);
    try a.localSet(n);
    try a.localGet(v);
    try a.constI64(5);
    try a.op(wasm.i64_div_u);
    try a.localSet(v);
    try a.op(wasm.br);
    try a.u32v(0);
    try a.op(wasm.end);
    try a.op(wasm.end);
    try a.constI64(0);
}

/// wdig: write `count` decimal digits of `value` ending at addr+count-1
/// (backward, like the reference's writeDecimal), returning the undivided
/// remainder so a split render can continue with the leading digits.
/// params addr=0(i32), value=1, count=2; locals k=3.
fn emitWdig(a: *Asm) !void {
    const addr = 0;
    const value = 1;
    const count = 2;
    const k = 3;
    try a.constI64(0);
    try a.localSet(k);
    try a.op(wasm.block);
    try a.op(wasm.empty_type);
    try a.op(wasm.loop);
    try a.op(wasm.empty_type);
    try a.localGet(k);
    try a.localGet(count);
    try a.op(wasm.i64_ge_s);
    try a.op(wasm.br_if);
    try a.u32v(1);
    // buf[count-1-k] = '0' + value % 10
    try a.localGet(addr);
    try a.localGet(count);
    try a.constI64(1);
    try a.op(wasm.i64_sub);
    try a.localGet(k);
    try a.op(wasm.i64_sub);
    try a.op(wasm.i32_wrap_i64);
    try a.op(wasm.i32_add);
    try a.localGet(value);
    try a.constI64(10);
    try a.op(wasm.i64_rem_u);
    try a.op(wasm.i32_wrap_i64);
    try a.constI32('0');
    try a.op(wasm.i32_add);
    try a.store(wasm.i32_store8, 0);
    try a.localGet(value);
    try a.constI64(10);
    try a.op(wasm.i64_div_u);
    try a.localSet(value);
    try a.localGet(k);
    try a.constI64(1);
    try a.op(wasm.i64_add);
    try a.localSet(k);
    try a.op(wasm.br);
    try a.u32v(0);
    try a.op(wasm.end);
    try a.op(wasm.end);
    try a.localGet(value);
}

/// fstr: str(Float) — the ryu core (binaryToDecimal, full-table 64-bit
/// backend) then positional rendering, transliterated from the proven
/// Zig replica above.  params x=0 (f64); locals: bits=1, mant=2, iexp=3,
/// m2=4, e2=5, mv=6, mms=7, q=8, vr=9, vp=10, vm=11, e10=12, removed=13,
/// lastrem=14, outv=15, olen=16, dp=17, tmp=18, jsh=19 (i64); sign=20,
/// accept=21, vmtz=22, vrtz=23, addr=24, ptr=25, idx=26 (i32).
fn emitFstr(a: *Asm) !void {
    const x = 0;
    const bits = 1;
    const mant = 2;
    const iexp = 3;
    const m2 = 4;
    const e2 = 5;
    const mv = 6;
    const mms = 7;
    const q = 8;
    const vr = 9;
    const vp = 10;
    const vm = 11;
    const e10 = 12;
    const removed = 13;
    const lastrem = 14;
    const outv = 15;
    const olen = 16;
    const dp = 17;
    const tmp = 18;
    const jsh = 19;
    const sign = 20;
    const accept = 21;
    const vmtz = 22;
    const vrtz = 23;
    const addr = 24;
    const ptr = 25;
    const idx = 26;

    try a.localGet(x);
    try a.op(wasm.i64_reinterpret_f64);
    try a.localSet(bits);
    try a.localGet(bits);
    try a.constI64(63);
    try a.op(wasm.i64_shr_u);
    try a.op(wasm.i32_wrap_i64);
    try a.localSet(sign);
    try a.localGet(bits);
    try a.constI64(0xFFFFFFFFFFFFF);
    try a.op(wasm.i64_and);
    try a.localSet(mant);
    try a.localGet(bits);
    try a.constI64(52);
    try a.op(wasm.i64_shr_u);
    try a.constI64(0x7FF);
    try a.op(wasm.i64_and);
    try a.localSet(iexp);

    // nan / inf: three letters, optionally signed.
    try a.localGet(iexp);
    try a.constI64(0x7FF);
    try a.op(wasm.i64_eq);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.constI32(3);
    try a.localGet(sign);
    try a.op(wasm.i32_add);
    try a.callFunc(Rt.str_new.index());
    try a.localSet(ptr);
    try a.localGet(ptr);
    try a.constI32(4);
    try a.op(wasm.i32_add);
    try a.localSet(idx);
    try a.localGet(sign);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.localGet(idx);
    try a.constI32('-');
    try a.store(wasm.i32_store8, 0);
    try a.localGet(idx);
    try a.constI32(1);
    try a.op(wasm.i32_add);
    try a.localSet(idx);
    try a.op(wasm.end);
    // "nan" when the mantissa is set, else "inf".
    try a.localGet(mant);
    try a.constI64(0);
    try a.op(wasm.i64_ne);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.localGet(idx);
    try a.constI32('n');
    try a.store(wasm.i32_store8, 0);
    try a.localGet(idx);
    try a.constI32('a');
    try a.store(wasm.i32_store8, 1);
    try a.localGet(idx);
    try a.constI32('n');
    try a.store(wasm.i32_store8, 2);
    try a.op(wasm.else_);
    try a.localGet(idx);
    try a.constI32('i');
    try a.store(wasm.i32_store8, 0);
    try a.localGet(idx);
    try a.constI32('n');
    try a.store(wasm.i32_store8, 1);
    try a.localGet(idx);
    try a.constI32('f');
    try a.store(wasm.i32_store8, 2);
    try a.op(wasm.end);
    try a.localGet(ptr);
    try a.op(wasm.ret);
    try a.op(wasm.end);

    // Zero (either sign): mantissa 0, exponent 0 through the shared
    // rendering (which prints "0"/"-0").
    try a.localGet(iexp);
    try a.op(wasm.i64_eqz);
    try a.localGet(mant);
    try a.op(wasm.i64_eqz);
    try a.op(wasm.i32_and);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.constI64(0);
    try a.localSet(outv);
    try a.constI64(0);
    try a.localSet(e10);
    try a.op(wasm.else_);
    try emitFstrCore(a, .{
        .mant = mant,
        .iexp = iexp,
        .m2 = m2,
        .e2 = e2,
        .mv = mv,
        .mms = mms,
        .q = q,
        .vr = vr,
        .vp = vp,
        .vm = vm,
        .e10 = e10,
        .removed = removed,
        .lastrem = lastrem,
        .outv = outv,
        .tmp = tmp,
        .jsh = jsh,
        .accept = accept,
        .vmtz = vmtz,
        .vrtz = vrtz,
        .addr = addr,
    });
    try a.op(wasm.end);

    // -- render (positional, no precision) ---------------------------------
    // olen = decimal length of outv.
    try a.constI64(1);
    try a.localSet(olen);
    try a.localGet(outv);
    try a.localSet(tmp);
    try a.op(wasm.block);
    try a.op(wasm.empty_type);
    try a.op(wasm.loop);
    try a.op(wasm.empty_type);
    try a.localGet(tmp);
    try a.constI64(10);
    try a.op(wasm.i64_lt_u);
    try a.op(wasm.br_if);
    try a.u32v(1);
    try a.localGet(tmp);
    try a.constI64(10);
    try a.op(wasm.i64_div_u);
    try a.localSet(tmp);
    try a.localGet(olen);
    try a.constI64(1);
    try a.op(wasm.i64_add);
    try a.localSet(olen);
    try a.op(wasm.br);
    try a.u32v(0);
    try a.op(wasm.end);
    try a.op(wasm.end);
    // dp = e10 + olen.
    try a.localGet(e10);
    try a.localGet(olen);
    try a.op(wasm.i64_add);
    try a.localSet(dp);

    // Total byte length by shape, then the block.
    try a.localGet(dp);
    try a.constI64(0);
    try a.op(wasm.i64_le_s);
    try a.op(wasm.if_);
    try a.op(wasm.i64t);
    try a.constI64(2);
    try a.localGet(dp);
    try a.op(wasm.i64_sub);
    try a.localGet(olen);
    try a.op(wasm.i64_add);
    try a.op(wasm.else_);
    try a.localGet(dp);
    try a.localGet(olen);
    try a.op(wasm.i64_ge_s);
    try a.op(wasm.if_);
    try a.op(wasm.i64t);
    try a.localGet(dp);
    try a.op(wasm.else_);
    try a.localGet(olen);
    try a.constI64(1);
    try a.op(wasm.i64_add);
    try a.op(wasm.end);
    try a.op(wasm.end);
    try a.op(wasm.i32_wrap_i64);
    try a.localGet(sign);
    try a.op(wasm.i32_add);
    try a.callFunc(Rt.str_new.index());
    try a.localSet(ptr);
    try a.localGet(ptr);
    try a.constI32(4);
    try a.op(wasm.i32_add);
    try a.localSet(idx);
    try a.localGet(sign);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.localGet(idx);
    try a.constI32('-');
    try a.store(wasm.i32_store8, 0);
    try a.localGet(idx);
    try a.constI32(1);
    try a.op(wasm.i32_add);
    try a.localSet(idx);
    try a.op(wasm.end);

    try a.localGet(dp);
    try a.constI64(0);
    try a.op(wasm.i64_le_s);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    // 0.000ddd
    try a.localGet(idx);
    try a.constI32('0');
    try a.store(wasm.i32_store8, 0);
    try a.localGet(idx);
    try a.constI32('.');
    try a.store(wasm.i32_store8, 1);
    try a.localGet(idx);
    try a.constI32(2);
    try a.op(wasm.i32_add);
    try a.localSet(idx);
    try a.localGet(idx);
    try a.constI32('0');
    try a.constI64(0);
    try a.localGet(dp);
    try a.op(wasm.i64_sub);
    try a.op(wasm.i32_wrap_i64);
    try a.memoryFill();
    try a.localGet(idx);
    try a.constI64(0);
    try a.localGet(dp);
    try a.op(wasm.i64_sub);
    try a.op(wasm.i32_wrap_i64);
    try a.op(wasm.i32_add);
    try a.localSet(idx);
    try a.localGet(idx);
    try a.localGet(outv);
    try a.localGet(olen);
    try a.callFunc(Rt.wdig.index());
    try a.op(wasm.drop);
    try a.op(wasm.else_);
    try a.localGet(dp);
    try a.localGet(olen);
    try a.op(wasm.i64_ge_s);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    // dddd000
    try a.localGet(idx);
    try a.localGet(outv);
    try a.localGet(olen);
    try a.callFunc(Rt.wdig.index());
    try a.op(wasm.drop);
    try a.localGet(idx);
    try a.localGet(olen);
    try a.op(wasm.i32_wrap_i64);
    try a.op(wasm.i32_add);
    try a.constI32('0');
    try a.localGet(dp);
    try a.localGet(olen);
    try a.op(wasm.i64_sub);
    try a.op(wasm.i32_wrap_i64);
    try a.memoryFill();
    try a.op(wasm.else_);
    // dd.dd — fractional digits first (they are the low ones), then
    // the point, then the leading digits from the remaining value.
    try a.localGet(idx);
    try a.localGet(dp);
    try a.op(wasm.i32_wrap_i64);
    try a.op(wasm.i32_add);
    try a.constI32(1);
    try a.op(wasm.i32_add);
    try a.localGet(outv);
    try a.localGet(olen);
    try a.localGet(dp);
    try a.op(wasm.i64_sub);
    try a.callFunc(Rt.wdig.index());
    try a.localSet(outv);
    try a.localGet(idx);
    try a.localGet(dp);
    try a.op(wasm.i32_wrap_i64);
    try a.op(wasm.i32_add);
    try a.constI32('.');
    try a.store(wasm.i32_store8, 0);
    try a.localGet(idx);
    try a.localGet(outv);
    try a.localGet(dp);
    try a.callFunc(Rt.wdig.index());
    try a.op(wasm.drop);
    try a.op(wasm.end);
    try a.op(wasm.end);
    try a.localGet(ptr);
}

/// The binaryToDecimal core of fstr for a nonzero finite input: from
/// (mant, iexp) to (outv, e10).  Faithful to the Zig replica; local
/// indices arrive from the caller.
const FstrLocals = struct {
    mant: u32,
    iexp: u32,
    m2: u32,
    e2: u32,
    mv: u32,
    mms: u32,
    q: u32,
    vr: u32,
    vp: u32,
    vm: u32,
    e10: u32,
    removed: u32,
    lastrem: u32,
    outv: u32,
    tmp: u32,
    jsh: u32,
    accept: u32,
    vmtz: u32,
    vrtz: u32,
    addr: u32,
};

fn emitFstrCore(a: *Asm, L: FstrLocals) !void {
    // e2/m2 from the ieee fields (bias 1023, 52 mantissa bits, -2).
    try a.localGet(L.iexp);
    try a.op(wasm.i64_eqz);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.constI64(1 - 1023 - 52 - 2);
    try a.localSet(L.e2);
    try a.localGet(L.mant);
    try a.localSet(L.m2);
    try a.op(wasm.else_);
    try a.localGet(L.iexp);
    try a.constI64(1023 + 52 + 2);
    try a.op(wasm.i64_sub);
    try a.localSet(L.e2);
    try a.constI64(1 << 52);
    try a.localGet(L.mant);
    try a.op(wasm.i64_or);
    try a.localSet(L.m2);
    try a.op(wasm.end);
    // accept = even(m2); mv = 4*m2; mms = (mant != 0) or (iexp == 0).
    try a.localGet(L.m2);
    try a.constI64(1);
    try a.op(wasm.i64_and);
    try a.op(wasm.i64_eqz);
    try a.localSet(L.accept);
    try a.localGet(L.m2);
    try a.constI64(2);
    try a.op(wasm.i64_shl);
    try a.localSet(L.mv);
    try a.localGet(L.mant);
    try a.constI64(0);
    try a.op(wasm.i64_ne);
    try a.localGet(L.iexp);
    try a.op(wasm.i64_eqz);
    try a.op(wasm.i32_or);
    try a.op(wasm.i64_extend_i32_u);
    try a.localSet(L.mms);
    try a.constI32(0);
    try a.localSet(L.vmtz);
    try a.constI32(0);
    try a.localSet(L.vrtz);

    try a.localGet(L.e2);
    try a.constI64(0);
    try a.op(wasm.i64_ge_s);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    // q = log10Pow2(e2) - (e2 > 3)
    try a.localGet(L.e2);
    try a.constI64(169464822037455);
    try a.op(wasm.i64_mul);
    try a.constI64(49);
    try a.op(wasm.i64_shr_u);
    try a.localGet(L.e2);
    try a.constI64(3);
    try a.op(wasm.i64_gt_s);
    try a.op(wasm.i64_extend_i32_u);
    try a.op(wasm.i64_sub);
    try a.localSet(L.q);
    try a.localGet(L.q);
    try a.localSet(L.e10);
    // jsh = -e2 + q + (125 + pow5Bits(q) - 1)
    try a.localGet(L.q);
    try a.constI64(163391164108059);
    try a.op(wasm.i64_mul);
    try a.constI64(46);
    try a.op(wasm.i64_shr_u);
    try a.constI64(1);
    try a.op(wasm.i64_add); // pow5Bits(q)
    try a.constI64(124);
    try a.op(wasm.i64_add);
    try a.localGet(L.q);
    try a.op(wasm.i64_add);
    try a.localGet(L.e2);
    try a.op(wasm.i64_sub);
    try a.localSet(L.jsh);
    // addr = inv_table + q*16
    try a.localGet(L.q);
    try a.op(wasm.i32_wrap_i64);
    try a.constI32(4);
    try a.op(wasm.i32_shl);
    try a.constI32(@intCast(pow5_inv_table_addr));
    try a.op(wasm.i32_add);
    try a.localSet(L.addr);
    try emitFstrMulShifts(a, L);
    // trailing-zero bookkeeping, q <= 21
    try a.localGet(L.q);
    try a.constI64(21);
    try a.op(wasm.i64_le_s);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.localGet(L.mv);
    try a.constI64(5);
    try a.op(wasm.i64_rem_u);
    try a.op(wasm.i64_eqz);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.localGet(L.mv);
    try a.callFunc(Rt.p5fac.index());
    try a.localGet(L.q);
    try a.op(wasm.i64_ge_s);
    try a.localSet(L.vrtz);
    try a.op(wasm.else_);
    try a.localGet(L.accept);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.localGet(L.mv);
    try a.constI64(1);
    try a.op(wasm.i64_sub);
    try a.localGet(L.mms);
    try a.op(wasm.i64_sub);
    try a.callFunc(Rt.p5fac.index());
    try a.localGet(L.q);
    try a.op(wasm.i64_ge_s);
    try a.localSet(L.vmtz);
    try a.op(wasm.else_);
    try a.localGet(L.vp);
    try a.localGet(L.mv);
    try a.constI64(2);
    try a.op(wasm.i64_add);
    try a.callFunc(Rt.p5fac.index());
    try a.localGet(L.q);
    try a.op(wasm.i64_ge_s);
    try a.op(wasm.i64_extend_i32_u);
    try a.op(wasm.i64_sub);
    try a.localSet(L.vp);
    try a.op(wasm.end);
    try a.op(wasm.end);
    try a.op(wasm.end);
    try a.op(wasm.else_);
    // e2 < 0: q = log10Pow5(-e2) - (-e2 > 1)
    try a.constI64(0);
    try a.localGet(L.e2);
    try a.op(wasm.i64_sub);
    try a.localSet(L.tmp); // tmp = -e2
    try a.localGet(L.tmp);
    try a.constI64(196742565691928);
    try a.op(wasm.i64_mul);
    try a.constI64(48);
    try a.op(wasm.i64_shr_u);
    try a.localGet(L.tmp);
    try a.constI64(1);
    try a.op(wasm.i64_gt_s);
    try a.op(wasm.i64_extend_i32_u);
    try a.op(wasm.i64_sub);
    try a.localSet(L.q);
    try a.localGet(L.q);
    try a.localGet(L.e2);
    try a.op(wasm.i64_add);
    try a.localSet(L.e10);
    // i5 = -e2 - q; jsh = q - (pow5Bits(i5) - 125)
    try a.localGet(L.tmp);
    try a.localGet(L.q);
    try a.op(wasm.i64_sub);
    try a.localSet(L.tmp); // tmp = i5
    try a.localGet(L.q);
    try a.localGet(L.tmp);
    try a.constI64(163391164108059);
    try a.op(wasm.i64_mul);
    try a.constI64(46);
    try a.op(wasm.i64_shr_u);
    try a.constI64(1);
    try a.op(wasm.i64_add); // pow5Bits(i5)
    try a.constI64(125);
    try a.op(wasm.i64_sub);
    try a.op(wasm.i64_sub);
    try a.localSet(L.jsh);
    // addr = pow5_table + i5*16
    try a.localGet(L.tmp);
    try a.op(wasm.i32_wrap_i64);
    try a.constI32(4);
    try a.op(wasm.i32_shl);
    try a.constI32(@intCast(pow5_table_addr));
    try a.op(wasm.i32_add);
    try a.localSet(L.addr);
    try emitFstrMulShifts(a, L);
    try a.localGet(L.q);
    try a.constI64(1);
    try a.op(wasm.i64_le_s);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.constI32(1);
    try a.localSet(L.vrtz);
    try a.localGet(L.accept);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.localGet(L.mms);
    try a.constI64(1);
    try a.op(wasm.i64_eq);
    try a.localSet(L.vmtz);
    try a.op(wasm.else_);
    try a.localGet(L.vp);
    try a.constI64(1);
    try a.op(wasm.i64_sub);
    try a.localSet(L.vp);
    try a.op(wasm.end);
    try a.op(wasm.else_);
    try a.localGet(L.q);
    try a.constI64(63);
    try a.op(wasm.i64_lt_s);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    // vrtz = (mv & ((1<<q)-1)) == 0
    try a.localGet(L.mv);
    try a.constI64(1);
    try a.localGet(L.q);
    try a.op(wasm.i64_shl);
    try a.constI64(1);
    try a.op(wasm.i64_sub);
    try a.op(wasm.i64_and);
    try a.op(wasm.i64_eqz);
    try a.localSet(L.vrtz);
    try a.op(wasm.end);
    try a.op(wasm.end);
    try a.op(wasm.end);

    // Digit removal: while vp/10 > vm/10.
    try a.constI64(0);
    try a.localSet(L.removed);
    try a.constI64(0);
    try a.localSet(L.lastrem);
    try a.op(wasm.block);
    try a.op(wasm.empty_type);
    try a.op(wasm.loop);
    try a.op(wasm.empty_type);
    try a.localGet(L.vp);
    try a.constI64(10);
    try a.op(wasm.i64_div_u);
    try a.localGet(L.vm);
    try a.constI64(10);
    try a.op(wasm.i64_div_u);
    try a.op(wasm.i64_le_u);
    try a.op(wasm.br_if);
    try a.u32v(1);
    try emitFstrRemoveDigit(a, L);
    try a.op(wasm.br);
    try a.u32v(0);
    try a.op(wasm.end);
    try a.op(wasm.end);
    // If vm kept trailing zeros, keep stripping.
    try a.localGet(L.vmtz);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.op(wasm.block);
    try a.op(wasm.empty_type);
    try a.op(wasm.loop);
    try a.op(wasm.empty_type);
    try a.localGet(L.vm);
    try a.constI64(10);
    try a.op(wasm.i64_rem_u);
    try a.constI64(0);
    try a.op(wasm.i64_ne);
    try a.op(wasm.br_if);
    try a.u32v(1);
    try emitFstrRemoveDigit(a, L);
    try a.op(wasm.br);
    try a.u32v(0);
    try a.op(wasm.end);
    try a.op(wasm.end);
    try a.op(wasm.end);
    // Banker's nudge: ...500 exactly, round to even.
    try a.localGet(L.vrtz);
    try a.localGet(L.lastrem);
    try a.constI64(5);
    try a.op(wasm.i64_eq);
    try a.op(wasm.i32_and);
    try a.localGet(L.vr);
    try a.constI64(1);
    try a.op(wasm.i64_and);
    try a.op(wasm.i64_eqz);
    try a.op(wasm.i32_and);
    try a.op(wasm.if_);
    try a.op(wasm.empty_type);
    try a.constI64(4);
    try a.localSet(L.lastrem);
    try a.op(wasm.end);
    // outv = vr + roundUp; e10 += removed.
    try a.localGet(L.vr);
    // (vr == vm and (!accept or !vmtz)) or lastrem >= 5
    try a.localGet(L.vr);
    try a.localGet(L.vm);
    try a.op(wasm.i64_eq);
    try a.localGet(L.accept);
    try a.op(wasm.i32_eqz);
    try a.localGet(L.vmtz);
    try a.op(wasm.i32_eqz);
    try a.op(wasm.i32_or);
    try a.op(wasm.i32_and);
    try a.localGet(L.lastrem);
    try a.constI64(5);
    try a.op(wasm.i64_ge_s);
    try a.op(wasm.i32_or);
    try a.op(wasm.i64_extend_i32_u);
    try a.op(wasm.i64_add);
    try a.localSet(L.outv);
    try a.localGet(L.e10);
    try a.localGet(L.removed);
    try a.op(wasm.i64_add);
    try a.localSet(L.e10);
}

/// vr/vp/vm = mulShift(mv / mv+2 / mv-1-mms, table entry, jsh).
fn emitFstrMulShifts(a: *Asm, L: FstrLocals) !void {
    try a.localGet(L.mv);
    try a.localGet(L.addr);
    try a.localGet(L.jsh);
    try a.callFunc(Rt.mul_shift.index());
    try a.localSet(L.vr);
    try a.localGet(L.mv);
    try a.constI64(2);
    try a.op(wasm.i64_add);
    try a.localGet(L.addr);
    try a.localGet(L.jsh);
    try a.callFunc(Rt.mul_shift.index());
    try a.localSet(L.vp);
    try a.localGet(L.mv);
    try a.constI64(1);
    try a.op(wasm.i64_sub);
    try a.localGet(L.mms);
    try a.op(wasm.i64_sub);
    try a.localGet(L.addr);
    try a.localGet(L.jsh);
    try a.callFunc(Rt.mul_shift.index());
    try a.localSet(L.vm);
}

/// One removal step shared by both stripping loops.
fn emitFstrRemoveDigit(a: *Asm, L: FstrLocals) !void {
    try a.localGet(L.vmtz);
    try a.localGet(L.vm);
    try a.constI64(10);
    try a.op(wasm.i64_rem_u);
    try a.op(wasm.i64_eqz);
    try a.op(wasm.i32_and);
    try a.localSet(L.vmtz);
    try a.localGet(L.vrtz);
    try a.localGet(L.lastrem);
    try a.op(wasm.i64_eqz);
    try a.op(wasm.i32_and);
    try a.localSet(L.vrtz);
    try a.localGet(L.vr);
    try a.constI64(10);
    try a.op(wasm.i64_rem_u);
    try a.localSet(L.lastrem);
    try a.localGet(L.vr);
    try a.constI64(10);
    try a.op(wasm.i64_div_u);
    try a.localSet(L.vr);
    try a.localGet(L.vp);
    try a.constI64(10);
    try a.op(wasm.i64_div_u);
    try a.localSet(L.vp);
    try a.localGet(L.vm);
    try a.constI64(10);
    try a.op(wasm.i64_div_u);
    try a.localSet(L.vm);
    try a.localGet(L.removed);
    try a.constI64(1);
    try a.op(wasm.i64_add);
    try a.localSet(L.removed);
}

/// A clone of an Array: duplicate its dimensions and its element buffer.
fn emitArrayClone(a: *Asm) !void {
    const new = 1;
    const len = 2;
    const buf = 3;
    try a.callFunc(Rt.obj_alloc.index());
    try a.localSet(new);
    // copy dims (rank * 8 bytes)
    try a.localGet(0);
    try a.load(wasm.i32_load, obj_rank);
    try a.constI32(3);
    try a.op(wasm.i32_shl);
    try a.callFunc(Rt.alloc.index());
    try a.localSet(buf);
    try a.localGet(buf);
    try a.localGet(0);
    try a.load(wasm.i32_load, obj_dims);
    try a.localGet(0);
    try a.load(wasm.i32_load, obj_rank);
    try a.constI32(3);
    try a.op(wasm.i32_shl);
    try a.memoryCopy();
    try a.localGet(new);
    try a.localGet(buf);
    try a.store(wasm.i32_store, obj_dims);
    try a.localGet(new);
    try a.localGet(0);
    try a.load(wasm.i32_load, obj_rank);
    try a.store(wasm.i32_store, obj_rank);
    // copy elements (length * 8 bytes)
    try a.localGet(0);
    try a.load(wasm.i32_load, obj_length);
    try a.localSet(len);
    try a.localGet(len);
    try a.constI32(3);
    try a.op(wasm.i32_shl);
    try a.callFunc(Rt.alloc.index());
    try a.localSet(buf);
    try a.localGet(buf);
    try a.localGet(0);
    try a.load(wasm.i32_load, obj_data);
    try a.localGet(len);
    try a.constI32(3);
    try a.op(wasm.i32_shl);
    try a.memoryCopy();
    try a.localGet(new);
    try a.localGet(buf);
    try a.store(wasm.i32_store, obj_data);
    try a.localGet(new);
    try a.localGet(len);
    try a.store(wasm.i32_store, obj_length);
    try a.localGet(new);
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
    user_base: u32 = 0, // first user function's index (after runtime + generated)

    pc_local: u32 = 0,
    serial_local: u32 = 0, // this frame's ownership serial (identity)
    registers_base: u32 = 0,
    scratch_base: u32 = 0, // 4 temporaries: i32, i32, i64, i64
    scope_extra: u32 = 0,
    loop_depth: u32 = 0,

    const scratch_count = 4;
    fn scratchI32a(self: *const FunctionEmitter) u32 {
        return self.scratch_base;
    }
    fn scratchI32b(self: *const FunctionEmitter) u32 {
        return self.scratch_base + 1;
    }
    fn scratchI64a(self: *const FunctionEmitter) u32 {
        return self.scratch_base + 2;
    }
    fn scratchI64b(self: *const FunctionEmitter) u32 {
        return self.scratch_base + 3;
    }

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
            .struct_make => |make| {
                const layout = self.program.structs[make.layout];
                const ptr = self.scratchI32a();
                try self.a.constI32(@intCast(make.fields.len * 8));
                try self.a.callFunc(Rt.alloc.index());
                try self.a.localSet(ptr);
                for (make.fields, layout.fields, 0..) |field_reg, field, index| {
                    try self.a.localGet(ptr);
                    try self.getReg(field_reg);
                    try self.emitToSlot(field.field_type);
                    try self.a.store(wasm.i64_store, @intCast(index * 8));
                }
                try self.a.localGet(ptr);
                try self.setReg(item);
            },
            .struct_get => |get| {
                const field = self.program.structs[get.layout].fields[get.field];
                try self.getReg(get.target);
                try self.a.load(wasm.i64_load, @intCast(get.field * 8));
                try self.emitFromSlot(field.field_type);
                try self.setReg(item);
            },
            .struct_set => |set| {
                // Functional update: a fresh record, one field replaced
                // (struct values are immutable, so sharing is safe).
                const layout = self.program.structs[set.layout];
                const field = layout.fields[set.field];
                const ptr = self.scratchI32a();
                try self.a.constI32(@intCast(layout.fields.len * 8));
                try self.a.callFunc(Rt.alloc.index());
                try self.a.localSet(ptr);
                try self.a.localGet(ptr);
                try self.getReg(set.target);
                try self.a.constI32(@intCast(layout.fields.len * 8));
                try self.a.memoryCopy();
                try self.a.localGet(ptr);
                try self.getReg(set.value);
                try self.emitToSlot(field.field_type);
                try self.a.store(wasm.i64_store, @intCast(set.field * 8));
                try self.a.localGet(ptr);
                try self.setReg(item);
            },
            .heap_new => |new| {
                if (new.dims.len == 0) {
                    // List/Builder/Map start empty.
                    try self.a.callFunc(Rt.obj_alloc.index());
                } else {
                    // Array: fill a dims buffer, then validate + allocate.
                    const dims_buf = self.scratchI32a();
                    try self.a.constI32(@intCast(new.dims.len * 8));
                    try self.a.callFunc(Rt.alloc.index());
                    try self.a.localSet(dims_buf);
                    for (new.dims, 0..) |dim_reg, axis| {
                        try self.a.localGet(dims_buf);
                        try self.getReg(dim_reg);
                        try self.a.store(wasm.i64_store, @intCast(axis * 8));
                    }
                    try self.a.constI32(@intCast(new.dims.len));
                    try self.a.localGet(dims_buf);
                    try self.a.callFunc(Rt.array_new.index());
                }
                try self.setReg(item);
            },
            .object_bind => |bind| {
                // Only object-typed values carry ownership; the binding
                // set covers the single handle (structs: later).
                if (function.result_types[bind.value] == .heap) {
                    try self.getReg(bind.value);
                    try self.a.localGet(self.serial_local);
                    try self.a.constI32(@intCast(bind.local));
                    try self.a.callFunc(Rt.own_bind.index());
                }
            },
            .object_unbind => |unbind| {
                if (function.result_types[unbind.value] == .heap) {
                    // The scope-exit release: free (with children) only
                    // what this binding still owns.
                    try self.getReg(unbind.value);
                    try self.a.localGet(self.serial_local);
                    try self.a.constI32(@intCast(unbind.local));
                    try self.a.callFunc(Rt.own_should_free.index());
                    try self.a.op(wasm.if_);
                    try self.a.op(wasm.empty_type);
                    try self.getReg(unbind.value);
                    try self.a.callFunc(self.genFor(unbind.value, gen_free_object));
                    try self.a.op(wasm.end);
                }
            },
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
                // Whatever the finishing frame still owns in the returned
                // value moves out loose, so the caller can bind it (S16).
                if (value) |register| {
                    if (function.result_types[register] == .heap) {
                        try self.getReg(register);
                        try self.a.localGet(self.serial_local);
                        try self.a.callFunc(Rt.own_loosen_frame.index());
                    }
                    try self.getReg(register);
                }
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
            .strukt => |layout| try self.emitStructBinary(item, operation, layout),
            .boolean => {
                try self.getReg(operation.left);
                try self.getReg(operation.right);
                try self.a.op(if (operation.op == .equal) wasm.i32_eq else wasm.i32_ne);
                try self.setReg(item);
            },
            else => try self.emitIntBinary(item, operation),
        }
    }

    /// Struct equality: every field equal, compared by its own type.
    fn emitStructBinary(self: *FunctionEmitter, item: ir.Register, operation: anytype, layout_index: u32) !void {
        const layout = self.program.structs[layout_index];
        const acc = self.scratchI32a();
        const a_slot = self.scratchI64a();
        const b_slot = self.scratchI64b();
        try self.a.constI32(1);
        try self.a.localSet(acc);
        for (layout.fields, 0..) |field, index| {
            try self.getReg(operation.left);
            try self.a.load(wasm.i64_load, @intCast(index * 8));
            try self.a.localSet(a_slot);
            try self.getReg(operation.right);
            try self.a.load(wasm.i64_load, @intCast(index * 8));
            try self.a.localSet(b_slot);
            switch (field.field_type) {
                .string => {
                    try self.a.localGet(a_slot);
                    try self.a.op(wasm.i32_wrap_i64);
                    try self.a.localGet(b_slot);
                    try self.a.op(wasm.i32_wrap_i64);
                    try self.a.callFunc(Rt.str_cmp.index());
                    try self.a.op(wasm.i32_eqz);
                },
                .float => {
                    try self.a.localGet(a_slot);
                    try self.a.op(0xBF); // f64.reinterpret_i64
                    try self.a.localGet(b_slot);
                    try self.a.op(0xBF);
                    try self.a.op(wasm.f64_eq);
                },
                else => {
                    try self.a.localGet(a_slot);
                    try self.a.localGet(b_slot);
                    try self.a.op(wasm.i64_eq);
                },
            }
            try self.a.localGet(acc);
            try self.a.op(wasm.i32_and);
            try self.a.localSet(acc);
        }
        try self.a.localGet(acc);
        if (operation.op == .not_equal) try self.a.op(wasm.i32_eqz);
        try self.setReg(item);
    }

    fn emitFloatBinary(self: *FunctionEmitter, item: ir.Register, operation: anytype) !void {
        try self.getReg(operation.left);
        try self.getReg(operation.right);
        if (operation.op == .remainder) {
            try self.a.callFunc(Rt.frem.index());
        } else {
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
        }
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

    /// The generated ownership walk (kind) for the heap type of `register`.
    fn genFor(self: *const FunctionEmitter, register: ir.Register, kind: u32) u32 {
        return genFuncIndex(import_count + Rt.count, self.function.result_types[register].heap, kind);
    }

    /// The generated walk for the ELEMENT/value heap type of the
    /// container in `register` (which must be owning).
    fn childGen(self: *const FunctionEmitter, register: ir.Register, kind: u32) u32 {
        const child = heapChildType(self.program, self.function.result_types[register].heap);
        return genFuncIndex(import_count + Rt.count, child, kind);
    }

    /// Whether the container in `register` has elements that own objects.
    fn elemOwning(self: *const FunctionEmitter, register: ir.Register) bool {
        return heapTypeOwns(self.program, self.function.result_types[register].heap);
    }

    fn emitCall(self: *FunctionEmitter, item: ir.Register, callee: anytype) !void {
        for (callee.arguments) |argument| try self.getReg(argument);
        try self.a.callFunc(callee.function + self.user_base);
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
                if (self.function.result_types[args[0]] == .float) {
                    try self.getReg(args[0]);
                    try self.getReg(args[1]);
                    try self.a.callFunc(if (call.kind == .min) Rt.fmin.index() else Rt.fmax.index());
                    try self.setReg(item);
                    return;
                }
                try self.getReg(args[0]);
                try self.getReg(args[1]);
                try self.getReg(args[0]);
                try self.getReg(args[1]);
                try self.a.op(if (call.kind == .min) wasm.i64_lt_s else wasm.i64_gt_s);
                try self.a.op(wasm.select);
                try self.setReg(item);
            },
            .clamp => {
                if (self.function.result_types[args[0]] == .float) {
                    // min(max(v, low), high) — the interpreter's order.
                    try self.getReg(args[0]);
                    try self.getReg(args[1]);
                    try self.a.callFunc(Rt.fmax.index());
                    try self.getReg(args[2]);
                    try self.a.callFunc(Rt.fmin.index());
                    try self.setReg(item);
                    return;
                }
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
            .len => {
                if (self.function.result_types[args[0]] == .heap) {
                    try self.resolved(args[0]);
                    if (self.isArray(args[0])) {
                        // an Array's length is its first dimension
                        try self.a.load(wasm.i32_load, obj_dims);
                        try self.a.load(wasm.i64_load, 0);
                    } else { // list/map element count, or builder byte count
                        try self.a.load(wasm.i32_load, obj_length);
                        try self.a.op(wasm.i64_extend_i32_u);
                    }
                } else { // string byte length
                    try self.getReg(args[0]);
                    try self.a.load(wasm.i32_load, 0);
                    try self.a.op(wasm.i64_extend_i32_u);
                }
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
            .null_object => {
                try self.a.constI32(0); // the null handle
                try self.setReg(item);
            },
            .index_get => {
                if (self.isMap(args[0])) {
                    const kv = self.mapKV(args[0]);
                    try self.resolved(args[0]);
                    try self.getReg(args[1]);
                    try self.emitToSlot(kv.key);
                    try self.a.constI32(keyMode(kv.key));
                    try self.a.callFunc(Rt.map_index.index());
                    try self.emitFromSlot(kv.value);
                } else if (self.isArray(args[0])) {
                    try self.emitArrayAddr(args[0], args[1..]);
                    try self.a.load(wasm.i64_load, 0);
                    try self.emitFromSlot(self.elementType(args[0]));
                } else {
                    try self.resolved(args[0]);
                    try self.getReg(args[1]);
                    try self.a.callFunc(Rt.list_get.index());
                    try self.emitFromSlot(self.elementType(args[0]));
                }
                try self.setReg(item);
            },
            .index_set => {
                const owning = self.elemOwning(args[0]);
                if (self.isMap(args[0])) {
                    const kv = self.mapKV(args[0]);
                    // An overwrite frees the old owned value first (S22);
                    // a missing key reads the null handle, a no-op free.
                    if (owning) {
                        try self.resolved(args[0]);
                        try self.getReg(args[1]);
                        try self.emitToSlot(kv.key);
                        try self.a.constI32(keyMode(kv.key));
                        try self.a.constI64(0);
                        try self.a.callFunc(Rt.map_get_or.index());
                        try self.a.op(wasm.i32_wrap_i64);
                        try self.a.callFunc(self.childGen(args[0], gen_free_object));
                    }
                    try self.resolved(args[0]);
                    try self.getReg(args[1]);
                    try self.emitToSlot(kv.key);
                    try self.a.constI32(keyMode(kv.key));
                    try self.getReg(args[args.len - 1]);
                    try self.emitToSlot(kv.value);
                    try self.a.callFunc(Rt.map_set.index());
                } else if (self.isArray(args[0])) {
                    if (owning) {
                        try self.emitArrayAddr(args[0], args[1 .. args.len - 1]);
                        try self.a.load(wasm.i64_load, 0);
                        try self.a.op(wasm.i32_wrap_i64);
                        try self.a.callFunc(self.childGen(args[0], gen_free_object));
                    }
                    try self.emitArrayAddr(args[0], args[1 .. args.len - 1]);
                    try self.getReg(args[args.len - 1]);
                    try self.emitToSlot(self.elementType(args[0]));
                    try self.a.store(wasm.i64_store, 0);
                } else {
                    try self.resolved(args[0]);
                    try self.getReg(args[1]);
                    try self.getReg(args[args.len - 1]);
                    try self.emitToSlot(self.elementType(args[0]));
                    try self.a.callFunc(Rt.list_set.index());
                    if (owning) {
                        // The returned old element is freed (S22).
                        try self.a.op(wasm.i32_wrap_i64);
                        try self.a.callFunc(self.childGen(args[0], gen_free_object));
                    } else {
                        try self.a.op(wasm.drop);
                    }
                }
                // The container adopts the stored object (S20).
                if (owning) {
                    try self.getReg(args[args.len - 1]);
                    try self.a.callFunc(Rt.own_adopt.index());
                }
            },
            .has_key => {
                const kv = self.mapKV(args[0]);
                try self.resolved(args[0]);
                try self.getReg(args[1]);
                try self.emitToSlot(kv.key);
                try self.a.constI32(keyMode(kv.key));
                try self.a.callFunc(Rt.map_find.index());
                try self.a.constI32(0);
                try self.a.op(wasm.i32_ge_s);
                try self.setReg(item);
            },
            .map_get => {
                const kv = self.mapKV(args[0]);
                try self.resolved(args[0]);
                try self.getReg(args[1]);
                try self.emitToSlot(kv.key);
                try self.a.constI32(keyMode(kv.key));
                try self.getReg(args[2]);
                try self.emitToSlot(kv.value);
                try self.a.callFunc(Rt.map_get_or.index());
                try self.emitFromSlot(kv.value);
                try self.setReg(item);
            },
            .key_at => {
                const kv = self.mapKV(args[0]);
                try self.resolved(args[0]);
                try self.getReg(args[1]);
                try self.a.callFunc(Rt.map_key_at.index());
                try self.emitFromSlot(kv.key);
                try self.setReg(item);
            },
            .value_at => {
                const kv = self.mapKV(args[0]);
                try self.resolved(args[0]);
                try self.getReg(args[1]);
                try self.a.callFunc(Rt.map_value_at.index());
                try self.emitFromSlot(kv.value);
                try self.setReg(item);
            },
            .map_keys => {
                try self.resolved(args[0]);
                try self.a.callFunc(Rt.map_keys.index());
                try self.setReg(item);
            },
            .map_values => {
                try self.resolved(args[0]);
                try self.a.callFunc(Rt.map_values.index());
                try self.setReg(item);
                // Object values: the returned list independently owns
                // deep copies (S23) — the walk type is the result list's.
                if (self.elemOwning(item)) {
                    try self.getReg(item);
                    try self.a.callFunc(self.genFor(item, gen_own_elements));
                }
            },
            .give_object => {
                // Resolve (null/use-after-free), verify givable, pass through.
                try self.resolved(args[0]);
                try self.emitGivableArgs(args);
                try self.a.callFunc(Rt.own_check.index());
                try self.getReg(args[0]);
                try self.setReg(item);
            },
            .free_object => {
                try self.resolved(args[0]);
                try self.emitGivableArgs(args);
                try self.a.callFunc(Rt.own_check.index());
                // freeObject: the typed walk releases owned elements too.
                try self.getReg(args[0]);
                try self.a.callFunc(self.genFor(args[0], gen_free_object));
            },
            .copy_object => {
                try self.resolved(args[0]);
                try self.a.callFunc(self.genFor(args[0], gen_copy_object));
                try self.setReg(item);
            },
            .dim_size => {
                const handle = self.scratchI32a();
                const axis = self.scratchI64a();
                try self.resolved(args[0]);
                try self.a.localSet(handle);
                try self.getReg(args[1]);
                try self.a.localSet(axis);
                // axis < 0 or axis >= rank -> index_bounds
                try self.a.localGet(axis);
                try self.a.constI64(0);
                try self.a.op(wasm.i64_lt_s);
                try self.a.localGet(axis);
                try self.a.localGet(handle);
                try self.a.load(wasm.i32_load, obj_rank);
                try self.a.op(wasm.i64_extend_i32_u);
                try self.a.op(wasm.i64_ge_s);
                try self.a.op(wasm.i32_or);
                try self.a.trapIf(.index_bounds);
                // dims[axis]
                try self.a.localGet(handle);
                try self.a.load(wasm.i32_load, obj_dims);
                try self.a.localGet(axis);
                try self.a.op(wasm.i32_wrap_i64);
                try self.a.constI32(3);
                try self.a.op(wasm.i32_shl);
                try self.a.op(wasm.i32_add);
                try self.a.load(wasm.i64_load, 0);
                try self.setReg(item);
            },
            .array_fill => {
                const element = self.elementType(args[0]);
                const handle = self.scratchI32a();
                const data = self.scratchI32b();
                const value = self.scratchI64a();
                const i = self.scratchI64b();
                try self.resolved(args[0]);
                try self.a.localSet(handle);
                try self.getReg(args[1]);
                try self.emitToSlot(element);
                try self.a.localSet(value);
                try self.a.localGet(handle);
                try self.a.load(wasm.i32_load, obj_data);
                try self.a.localSet(data);
                try self.a.constI64(0);
                try self.a.localSet(i);
                try self.a.op(wasm.block);
                try self.a.op(wasm.empty_type);
                try self.a.op(wasm.loop);
                try self.a.op(wasm.empty_type);
                try self.a.localGet(i);
                try self.a.localGet(handle);
                try self.a.load(wasm.i32_load, obj_length);
                try self.a.op(wasm.i64_extend_i32_u);
                try self.a.op(wasm.i64_ge_s);
                try self.a.op(wasm.br_if);
                try self.a.u32v(1);
                try self.a.localGet(data);
                try self.a.localGet(i);
                try self.a.op(wasm.i32_wrap_i64);
                try self.a.constI32(3);
                try self.a.op(wasm.i32_shl);
                try self.a.op(wasm.i32_add);
                try self.a.localGet(value);
                try self.a.store(wasm.i64_store, 0);
                try self.a.localGet(i);
                try self.a.constI64(1);
                try self.a.op(wasm.i64_add);
                try self.a.localSet(i);
                try self.a.op(wasm.br);
                try self.a.u32v(0);
                try self.a.op(wasm.end);
                try self.a.op(wasm.end);
            },
            .append_value => try self.emitAppendValue(args),
            .append_ascii => {
                try self.resolved(args[0]);
                try self.getReg(args[1]);
                try self.a.callFunc(Rt.builder_byte.index());
            },
            .pop_value => {
                const element = self.elementType(args[0]);
                try self.resolved(args[0]);
                try self.a.callFunc(Rt.list_pop.index());
                try self.emitFromSlot(element);
                try self.setReg(item);
                // pop hands the element out of the container (S22).
                if (self.elemOwning(args[0])) {
                    try self.getReg(item);
                    try self.a.callFunc(Rt.own_loosen.index());
                }
            },
            .insert_value => {
                const element = self.elementType(args[0]);
                try self.resolved(args[0]);
                try self.getReg(args[1]);
                try self.getReg(args[2]);
                try self.emitToSlot(element);
                try self.a.callFunc(Rt.list_insert.index());
                if (self.elemOwning(args[0])) {
                    try self.getReg(args[2]);
                    try self.a.callFunc(Rt.own_adopt.index());
                }
            },
            .remove_entry => {
                if (self.isMap(args[0])) {
                    const kv = self.mapKV(args[0]);
                    // Removing an owned value frees it (S22): take the
                    // stored value first (null when absent — free of the
                    // null handle is a no-op), then remove the entry.
                    if (self.elemOwning(args[0])) {
                        try self.resolved(args[0]);
                        try self.getReg(args[1]);
                        try self.emitToSlot(kv.key);
                        try self.a.constI32(keyMode(kv.key));
                        try self.a.constI64(0);
                        try self.a.callFunc(Rt.map_get_or.index());
                        try self.a.op(wasm.i32_wrap_i64);
                        try self.a.callFunc(self.childGen(args[0], gen_free_object));
                    }
                    try self.resolved(args[0]);
                    try self.getReg(args[1]);
                    try self.emitToSlot(kv.key);
                    try self.a.constI32(keyMode(kv.key));
                    try self.a.callFunc(Rt.map_remove.index());
                } else {
                    try self.resolved(args[0]);
                    try self.getReg(args[1]);
                    try self.a.callFunc(Rt.list_remove.index());
                    if (self.elemOwning(args[0])) {
                        // Removing an owned element frees it (S22).
                        try self.a.op(wasm.i32_wrap_i64);
                        try self.a.callFunc(self.childGen(args[0], gen_free_object));
                    } else {
                        try self.a.op(wasm.drop);
                    }
                }
            },
            .list_slice => {
                try self.resolved(args[0]);
                try self.getReg(args[1]);
                try self.getReg(args[2]);
                try self.a.callFunc(Rt.list_slice.index());
                try self.setReg(item);
                // Slices copy: object elements become adopted deep
                // copies, never shared (S23, S31).
                if (self.elemOwning(args[0])) {
                    try self.getReg(item);
                    try self.a.callFunc(self.genFor(item, gen_own_elements));
                }
            },
            .list_find, .list_contains => {
                const element = self.elementType(args[0]);
                try self.resolved(args[0]);
                try self.getReg(args[1]);
                try self.emitToSlot(element);
                try self.a.constI32(elementMode(element));
                try self.a.callFunc(Rt.list_find.index());
                if (call.kind == .list_contains) {
                    try self.a.constI64(-1);
                    try self.a.op(wasm.i64_ne);
                }
                try self.setReg(item);
            },
            .list_sort, .list_reverse => {
                const element = self.elementType(args[0]);
                try self.resolved(args[0]);
                try self.a.constI32(elementMode(element));
                try self.a.constI32(if (call.kind == .list_reverse) 1 else 0);
                try self.a.callFunc(Rt.list_sort.index());
            },
            .clear_object => {
                // clear frees all owned elements (S22), then empties.
                if (self.elemOwning(args[0])) {
                    try self.resolved(args[0]);
                    try self.a.callFunc(self.genFor(args[0], gen_free_elements));
                }
                try self.resolved(args[0]);
                try self.a.constI32(0);
                try self.a.store(wasm.i32_store, obj_length);
            },
            else => unreachable,
        }
    }

    /// Resolve an object register to a live handle on the stack (traps
    /// null_object / use_after_free), as the interpreter's resolve does.
    fn resolved(self: *FunctionEmitter, register: ir.Register) !void {
        try self.getReg(register);
        try self.a.callFunc(Rt.live.index());
    }

    /// The element type of the List or Array in `register`.
    fn elementType(self: *const FunctionEmitter, register: ir.Register) types.Type {
        return switch (self.program.heap_types[self.function.result_types[register].heap]) {
            .list => |element| element,
            .array => |shape| shape.element,
            else => .none, // builder/map have no uniform element here
        };
    }

    fn isArray(self: *const FunctionEmitter, register: ir.Register) bool {
        return std.meta.activeTag(self.program.heap_types[self.function.result_types[register].heap]) == .array;
    }

    fn isMap(self: *const FunctionEmitter, register: ir.Register) bool {
        return std.meta.activeTag(self.program.heap_types[self.function.result_types[register].heap]) == .map;
    }

    fn mapKV(self: *const FunctionEmitter, register: ir.Register) struct { key: types.Type, value: types.Type } {
        const pair = self.program.heap_types[self.function.result_types[register].heap].map;
        return .{ .key = pair.key, .value = pair.value };
    }

    /// Bytes per element/entry of the object in `register`.
    fn heapElemSize(self: *const FunctionEmitter, register: ir.Register) i32 {
        return switch (self.program.heap_types[self.function.result_types[register].heap]) {
            .builder => 1,
            .map => map_entry_size,
            else => 8, // list/array
        };
    }

    /// Push own_check's remaining arguments (has_expected, serial, local)
    /// after the handle: `give NAME`/`free(x)` carries a second argument
    /// naming the binding to verify against.
    fn emitGivableArgs(self: *FunctionEmitter, args: []const ir.Register) !void {
        if (args.len == 2) {
            try self.a.constI32(1);
            try self.a.localGet(self.serial_local);
            try self.getReg(args[1]);
            try self.a.op(wasm.i32_wrap_i64);
        } else {
            try self.a.constI32(0);
            try self.a.localGet(self.serial_local);
            try self.a.constI32(0);
        }
    }

    /// Resolve an Array and leave the address of element `indices` on the
    /// stack — the interpreter's flattenIndex, with each axis bounds
    /// checked (index_bounds) against its dimension.
    fn emitArrayAddr(self: *FunctionEmitter, obj: ir.Register, indices: []const ir.Register) !void {
        const handle = self.scratchI32a();
        const flat = self.scratchI64a();
        const idx = self.scratchI64b();
        try self.resolved(obj);
        try self.a.localSet(handle);
        try self.a.constI64(0);
        try self.a.localSet(flat);
        for (indices, 0..) |index_reg, axis| {
            try self.getReg(index_reg);
            try self.a.localSet(idx);
            try self.a.localGet(idx);
            try self.a.constI64(0);
            try self.a.op(wasm.i64_lt_s);
            try self.a.localGet(idx);
            try self.emitDimLoad(handle, axis);
            try self.a.op(wasm.i64_ge_s);
            try self.a.op(wasm.i32_or);
            try self.a.trapIf(.index_bounds);
            try self.a.localGet(flat);
            try self.emitDimLoad(handle, axis);
            try self.a.op(wasm.i64_mul);
            try self.a.localGet(idx);
            try self.a.op(wasm.i64_add);
            try self.a.localSet(flat);
        }
        try self.a.localGet(handle);
        try self.a.load(wasm.i32_load, obj_data);
        try self.a.localGet(flat);
        try self.a.op(wasm.i32_wrap_i64);
        try self.a.constI32(3);
        try self.a.op(wasm.i32_shl);
        try self.a.op(wasm.i32_add);
    }

    /// Push dims[axis] (i64) of the array whose handle is in `handle_local`.
    fn emitDimLoad(self: *FunctionEmitter, handle_local: u32, axis: usize) !void {
        try self.a.localGet(handle_local);
        try self.a.load(wasm.i32_load, obj_dims);
        try self.a.load(wasm.i64_load, @intCast(axis * 8));
    }

    /// Convert a value (already on the stack, in its natural wasm type)
    /// to the 8-byte i64 element slot.
    fn emitToSlot(self: *FunctionEmitter, of: types.Type) !void {
        switch (of) {
            .int => {},
            .float => try self.a.op(0xBD), // i64.reinterpret_f64
            .boolean => try self.a.op(wasm.i64_extend_i32_u),
            else => try self.a.op(wasm.i64_extend_i32_u), // string/object address
        }
    }

    /// Convert an i64 element slot (on the stack) back to the value type.
    fn emitFromSlot(self: *FunctionEmitter, of: types.Type) !void {
        switch (of) {
            .int => {},
            .float => try self.a.op(0xBF), // f64.reinterpret_i64
            .boolean => try self.a.op(wasm.i32_wrap_i64),
            else => try self.a.op(wasm.i32_wrap_i64), // string/object address
        }
    }

    /// append(): a List takes an element slot; a Builder takes a String's
    /// bytes.  The receiver's heap type decides.
    fn emitAppendValue(self: *FunctionEmitter, args: []const ir.Register) !void {
        if (isBuilder(self.program, self.function.result_types[args[0]].heap)) {
            try self.resolved(args[0]);
            try self.getReg(args[1]);
            try self.a.callFunc(Rt.builder_str.index());
        } else {
            const element = self.elementType(args[0]);
            try self.resolved(args[0]);
            try self.getReg(args[1]);
            try self.emitToSlot(element);
            try self.a.callFunc(Rt.list_push.index());
            // The container adopts an appended object (S20).
            if (self.elemOwning(args[0])) {
                try self.getReg(args[1]);
                try self.a.callFunc(Rt.own_adopt.index());
            }
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
            .float => {
                try self.getReg(arg);
                try self.a.callFunc(Rt.fstr.index());
                try self.setReg(item);
            },
            .heap => { // a Builder's bytes become a String
                try self.resolved(arg);
                try self.a.callFunc(Rt.builder_to_str.index());
                try self.setReg(item);
            },
            else => unreachable,
        }
    }

    fn emitBody(self: *FunctionEmitter) !void {
        const function = self.function;
        const block_count: u32 = @intCast(function.blocks.len);

        try self.emitDepthEntry();

        // This frame's ownership serial: the next serial, then bump it.
        try self.a.globalGet(serial_global);
        try self.a.localSet(self.serial_local);
        try self.a.globalGet(serial_global);
        try self.a.constI64(1);
        try self.a.op(wasm.i64_add);
        try self.a.globalSet(serial_global);

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
        self.serial_local = local_count + 1;
        self.registers_base = local_count + 2;
        self.scratch_base = self.registers_base + @as(u32, @intCast(function.result_types.len));

        try self.emitBody();

        var out: std.ArrayList(u8) = .empty;
        const arena = self.a.arena;
        var kinds: std.ArrayList(u8) = .empty;
        for (function.locals[function.parameter_count..]) |local| {
            try kinds.append(arena, valType(local.local_type));
        }
        try kinds.append(arena, wasm.i32t); // pc
        try kinds.append(arena, wasm.i64t); // serial
        for (function.result_types) |result| {
            try kinds.append(arena, valType(result));
        }
        try kinds.appendSlice(arena, &.{ wasm.i32t, wasm.i32t, wasm.i64t, wasm.i64t }); // scratch
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
        try data.appendSlice(a, &.{ 0, 0, 0, 0 }); // pad to the tables' 8-alignment
        std.debug.assert(data.items.len == pow5_table_addr);
        for (ryu_tables.pow5) |entry| {
            try appendU64Le(&data, a, entry[0]);
            try appendU64Le(&data, a, entry[1]);
        }
        std.debug.assert(data.items.len == pow5_inv_table_addr);
        for (ryu_tables.inv) |entry| {
            try appendU64Le(&data, a, entry[0]);
            try appendU64Le(&data, a, entry[1]);
        }
        std.debug.assert(data.items.len == tables_end_addr);
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

        // The typed ownership walks: four generated functions per heap
        // type (free_elements, free_object, copy_object, own_elements),
        // monomorphized from the program's static heap-type table.
        const gen_count: u32 = gen_kinds * @as(u32, @intCast(self.program.heap_types.len));
        const total_functions: u32 = Rt.count + gen_count + @as(u32, @intCast(functions.len));

        // Types: 0 = emit_str (i32,i32)->(), 1 = trap (i32)->(), then
        // one per runtime function, per generated function, per user
        // function — index i's type is always import_count + i.
        var t: std.ArrayList(u8) = .empty;
        try appendU32Raw(&t, a, import_count + total_functions);
        try t.appendSlice(a, &.{ wasm.func_type, 2, wasm.i32t, wasm.i32t, 0 }); // emit_str
        try t.appendSlice(a, &.{ wasm.func_type, 1, wasm.i32t, 0 }); // trap
        for (rt_signatures) |sig| try appendSigType(&t, a, sig.params, sig.result);
        var gi: u32 = 0;
        while (gi < gen_count) : (gi += 1) {
            if (gi % gen_kinds == gen_copy_object) {
                try appendSigType(&t, a, &.{wasm.i32t}, wasm.i32t);
            } else {
                try appendSigType(&t, a, &.{wasm.i32t}, null);
            }
        }
        for (functions) |*function| try appendFuncType(&t, a, function);
        try section(&out, a, 1, t.items);

        // Imports: env.emit_str (type 0), env.trap (type 1).
        var im: std.ArrayList(u8) = .empty;
        try appendU32Raw(&im, a, import_count);
        try appendImport(&im, a, "env", "emit_str", 0);
        try appendImport(&im, a, "env", "trap", 1);
        try section(&out, a, 2, im.items);

        // Functions: runtime, generated, user, each referencing its type.
        var fs: std.ArrayList(u8) = .empty;
        try appendU32Raw(&fs, a, total_functions);
        var fi: u32 = 0;
        while (fi < total_functions) : (fi += 1) try appendU32Raw(&fs, a, import_count + fi);
        try section(&out, a, 3, fs.items);

        // Memory: one, min_pages, exported so the host can read strings.
        var me: std.ArrayList(u8) = .empty;
        try appendU32Raw(&me, a, 1);
        try me.append(a, 0x00); // limits: min only
        try appendU32Raw(&me, a, min_pages);
        try section(&out, a, 5, me.items);

        // Globals: depth budget (i64), heap pointer (i32), ownership
        // serial (i64) — all mutable.
        var gl: std.ArrayList(u8) = .empty;
        try appendU32Raw(&gl, a, 3);
        try gl.appendSlice(a, &.{ wasm.i64t, 0x01, wasm.i64_const });
        try appendI64Raw(&gl, a, call_depth_budget);
        try gl.append(a, wasm.end);
        try gl.appendSlice(a, &.{ wasm.i32t, 0x01, wasm.i32_const });
        try appendI64Raw(&gl, a, heap_base);
        try gl.append(a, wasm.end);
        try gl.appendSlice(a, &.{ wasm.i64t, 0x01, wasm.i64_const });
        try appendI64Raw(&gl, a, 1); // first serial
        try gl.append(a, wasm.end);
        try section(&out, a, 6, gl.items);

        // Exports: main and memory.
        var ex: std.ArrayList(u8) = .empty;
        try appendU32Raw(&ex, a, 2);
        try appendName(&ex, a, "main");
        try ex.append(a, 0x00);
        try appendU32Raw(&ex, a, @intCast(import_count + Rt.count + gen_count + self.program.entry_function));
        try appendName(&ex, a, "memory");
        try ex.append(a, 0x02); // export kind: memory
        try appendU32Raw(&ex, a, 0);
        try section(&out, a, 7, ex.items);

        // Code: runtime, generated ownership walks, then user functions.
        var cs: std.ArrayList(u8) = .empty;
        try appendU32Raw(&cs, a, total_functions);
        for (0..Rt.count) |ri| {
            const code = try emitRuntime(a, @enumFromInt(ri));
            try appendU32Raw(&cs, a, @intCast(code.len));
            try cs.appendSlice(a, code);
        }
        for (self.program.heap_types, 0..) |_, type_index| {
            var kind: u32 = 0;
            while (kind < gen_kinds) : (kind += 1) {
                const code = try emitGenerated(a, self.program, @intCast(type_index), kind);
                try appendU32Raw(&cs, a, @intCast(code.len));
                try cs.appendSlice(a, code);
            }
        }
        for (functions) |*function| {
            var emitter: FunctionEmitter = .{
                .a = .{ .arena = a },
                .program = self.program,
                .function = function,
                .constant_addr = constant_addr,
                .true_addr = true_addr,
                .false_addr = false_addr,
                .user_base = import_count + Rt.count + gen_count,
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

fn appendU64Le(data: *std.ArrayList(u8), arena: Allocator, value: u64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    try data.appendSlice(arena, &bytes);
}

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

test "the ryu replica renders byte-identical to std.fmt" {
    // The generated tables and the transcribed algorithm together must
    // reproduce Zig's own {d} exactly — every edge shape plus a broad
    // random sweep over raw bit patterns (finite and not).
    var ref_buf: [400]u8 = undefined;
    var std_buf: [400]u8 = undefined;

    const edges = [_]f64{
        0.0,                     -0.0,                1.0,      2.0,               1.5,                     0.1,
        1.0 / 3.0,               -2.5,                1.0e300,  1.0e-5,            1.0e15,                  1.0e16,
        1.5e-10,                 123456789.123456789, 5.0e-324, -5.0e-324,         2.2250738585072014e-308, 1.7976931348623157e308,
        4.9406564584124654e-324, 9007199254740993.0,  0.3,      std.math.inf(f64), -std.math.inf(f64),      std.math.nan(f64),
        123.456,                 -0.001,              1e22,     1e23,              12345678901234567890.0,
    };
    for (edges) |value| {
        const expected = try std.fmt.bufPrint(&std_buf, "{d}", .{value});
        const actual = refFormatDecimal(&ref_buf, refBinaryToDecimal(@bitCast(value)));
        try testing.expectEqualStrings(expected, actual);
    }

    var prng = std.Random.DefaultPrng.init(0x8c5a3f92);
    const random = prng.random();
    var round: usize = 0;
    while (round < 20000) : (round += 1) {
        const bits = random.int(u64);
        const value: f64 = @bitCast(bits);
        const expected = try std.fmt.bufPrint(&std_buf, "{d}", .{value});
        const actual = refFormatDecimal(&ref_buf, refBinaryToDecimal(bits));
        try testing.expectEqualStrings(expected, actual);
    }
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

    // A List of scalars and a Builder are supported (B1).
    var list = (try compileOrNull(
        \\func main():
        \\    var xs = new List(Int)
        \\    xs.append(3)
        \\    print(str(len(xs)))
    )).?;
    defer list.deinit();
    try testing.expect(supported(&list));

    // A struct of scalars is supported (B5).
    var record = (try compileOrNull(
        \\struct Point:
        \\    x: Int
        \\    y: Int
        \\
        \\func main():
        \\    var p = Point(x = 1, y = 2)
        \\    print(str(p.x + p.y))
    )).?;
    defer record.deinit();
    try testing.expect(supported(&record));

    // Host effects (arg/file/terminal) are not lowered — a distribution
    // module's effects would be imports, out of the compute core's scope.
    var hosted = (try compileOrNull(
        \\func main():
        \\    print(str(arg_count()))
    )).?;
    defer hosted.deinit();
    try testing.expect(!supported(&hosted));

    // str(Float) is supported via the ryu runtime; parse_float still
    // waits for a correctly-rounded reader.
    var floatstr = (try compileOrNull(
        \\func main():
        \\    var x = 1.5
        \\    print(str(x))
    )).?;
    defer floatstr.deinit();
    try testing.expect(supported(&floatstr));

    var pf = (try compileOrNull(
        \\func main():
        \\    print(str(parse_float("1.5") * 2.0))
    )).?;
    defer pf.deinit();
    try testing.expect(!supported(&pf));
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
