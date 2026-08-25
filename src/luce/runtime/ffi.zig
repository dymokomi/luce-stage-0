//! The FFI dispatch shim — the oracle's half of docs/FFI.md.
//!
//! Generated code calls an extern directly; the interpreter cannot,
//! because the shape it must call is data.  This file is the one
//! dynamic dispatcher: resolve the symbol in the running process —
//! symbols are link-time only, so whatever carries the oracle also
//! carries them — and call it through libffi.
//!
//! The 0.20 shim was a comptime thunk table instead: every argument a
//! 64-bit integer word, arity capped at eight, so nine arities times
//! three return kinds covered the whole vocabulary.  The 0.21 scalar
//! widening is exactly what retired it — `f32` parameters are a
//! different register class, narrow integers carry extension
//! contracts, and the arity cap is gone, so the set of concrete
//! function types stopped being enumerable and became libffi's job.
//! The target C ABI decides register and stack assignment, exactly as
//! it does for C.
//!
//! libffi is linked only into oracle-carrying binaries: nothing here
//! is referenced by `libluce_rt`'s exports, so the archive every
//! compiled artifact links stays free of it, and the products ship
//! without the dependency (the interpreter ships in nothing).

const std = @import("std");

/// One boundary slot's C shape, in libffi's own vocabulary.  The
/// caller has already normalized Luce's view: a handle is its
/// representation, `bool` crosses as C's one-byte `_Bool`, and a
/// pointer-shaped slot — token, out-slot address, C string — is
/// `pointer`.
pub const CType = enum {
    void,
    uint8,
    sint8,
    uint16,
    sint16,
    uint32,
    sint32,
    uint64,
    sint64,
    float,
    double,
    pointer,

    /// The libffi type descriptor this shape dispatches through.
    /// `_Bool` is not here because libffi has no bool descriptor;
    /// the caller passes `uint8`, which is what C's `_Bool` is on
    /// every emitted target.
    fn descriptor(self: CType) *FfiType {
        return switch (self) {
            .void => &ffi_type_void,
            .uint8 => &ffi_type_uint8,
            .sint8 => &ffi_type_sint8,
            .uint16 => &ffi_type_uint16,
            .sint16 => &ffi_type_sint16,
            .uint32 => &ffi_type_uint32,
            .sint32 => &ffi_type_sint32,
            .uint64 => &ffi_type_uint64,
            .sint64 => &ffi_type_sint64,
            .float => &ffi_type_float,
            .double => &ffi_type_double,
            .pointer => &ffi_type_pointer,
        };
    }
};

/// `ffi_type` as libffi's public ABI declares it.  Only the built-in
/// scalar descriptors below are ever used, so `elements` is never
/// populated from this side.
const FfiType = extern struct {
    size: usize,
    alignment: u16,
    kind: u16,
    elements: ?[*]?*FfiType,
};

extern var ffi_type_void: FfiType;
extern var ffi_type_uint8: FfiType;
extern var ffi_type_sint8: FfiType;
extern var ffi_type_uint16: FfiType;
extern var ffi_type_sint16: FfiType;
extern var ffi_type_uint32: FfiType;
extern var ffi_type_sint32: FfiType;
extern var ffi_type_uint64: FfiType;
extern var ffi_type_sint64: FfiType;
extern var ffi_type_float: FfiType;
extern var ffi_type_double: FfiType;
extern var ffi_type_pointer: FfiType;

extern fn ffi_prep_cif(
    cif: *anyopaque,
    abi: c_int,
    nargs: c_uint,
    rtype: *FfiType,
    atypes: ?[*]*FfiType,
) c_int;

extern fn ffi_call(
    cif: *anyopaque,
    function: *const fn () callconv(.c) void,
    rvalue: ?*anyopaque,
    avalue: ?[*]?*anyopaque,
) void;

/// `FFI_DEFAULT_ABI`, per target.  The value is an enum position in
/// each target's `ffitarget.h` and is not exported as a symbol, so it
/// is stated here, once, beside its source: aarch64 counts
/// `FFI_FIRST_ABI = 0, FFI_SYSV` (default 1); x86-64 counts
/// `FFI_FIRST_ABI = 1, FFI_UNIX64` (default 2).
const default_abi: c_int = switch (@import("builtin").cpu.arch) {
    .x86_64 => 2,
    else => 1,
};

/// Storage for one `ffi_cif`.  libffi treats the caller's storage as
/// opaque scratch that `ffi_prep_cif` fills and `ffi_call` reads; the
/// struct's tail varies per target (aarch64 appends a fixed-argument
/// count for variadics), so rather than restating each target's
/// layout this provides aligned storage several times the largest
/// real `sizeof(ffi_cif)` (about 40 bytes) and lets libffi own the
/// contents.
const CifStorage = struct {
    words: [32]u64 align(16) = undefined,
};

/// `RTLD_DEFAULT`: search the whole process image, which is where a
/// link-time-resolved symbol lives.  The constant differs per OS and
/// is not exported by `std.c`, so it is stated here, once.
const default_handle: ?*anyopaque = switch (@import("builtin").os.tag) {
    .macos, .ios, .tvos, .watchos => @ptrFromInt(@as(usize, @bitCast(@as(isize, -2)))),
    else => null,
};

/// The symbol's address in this process, or null when no image
/// carries it — which the caller reports as the honest refusal it is.
pub fn resolve(name: [*:0]const u8) ?*anyopaque {
    return std.c.dlsym(default_handle, name);
}

/// One extern call.  Each argument arrives as its value's bits in the
/// low end of one 64-bit word beside its C shape; the answer comes
/// back the same way — integers in the low bits (libffi widens a
/// narrow integral return to a full `ffi_arg` word), `float`/`double`
/// as their bit patterns, zero for void.  The caller truncates,
/// sign-adjusts, or bit-casts by the declared type, exactly as it
/// stated the shapes.
///
/// The per-call allocations are the arity's — descriptor, address,
/// and value cell per argument — which is the honest price of an
/// uncapped arity on the oracle path, where dispatch is data anyway.
pub fn call(
    gpa: std.mem.Allocator,
    target: *anyopaque,
    parameters: []const CType,
    arguments: []const u64,
    returns: CType,
) std.mem.Allocator.Error!u64 {
    std.debug.assert(parameters.len == arguments.len);
    const atypes = try gpa.alloc(*FfiType, parameters.len);
    defer gpa.free(atypes);
    const avalues = try gpa.alloc(?*anyopaque, parameters.len);
    defer gpa.free(avalues);
    // Each argument's bytes, stored through its C type so the cell is
    // right on any endianness rather than by low-half coincidence.
    const cells = try gpa.alloc(u64, parameters.len);
    defer gpa.free(cells);
    for (parameters, arguments, atypes, avalues, cells) |shape, word, *atype, *avalue, *cell| {
        atype.* = shape.descriptor();
        avalue.* = cell;
        switch (shape) {
            .void => unreachable, // a parameter is never void
            .uint8, .sint8 => @as(*u8, @ptrCast(cell)).* = @truncate(word),
            .uint16, .sint16 => @as(*u16, @ptrCast(cell)).* = @truncate(word),
            .uint32, .sint32, .float => @as(*u32, @ptrCast(cell)).* = @truncate(word),
            .uint64, .sint64, .double, .pointer => cell.* = word,
        }
    }

    var cif: CifStorage = .{};
    const prepared = ffi_prep_cif(
        &cif.words,
        default_abi,
        @intCast(parameters.len),
        returns.descriptor(),
        if (parameters.len == 0) null else atypes.ptr,
    );
    // Every shape this file's `CType` can spell is a scalar libffi
    // accepts, so a refusal here is a compiler bug, not input.
    std.debug.assert(prepared == 0);

    var answer: u64 align(16) = 0;
    ffi_call(
        &cif.words,
        @ptrCast(@alignCast(target)),
        if (returns == .void) null else &answer,
        if (parameters.len == 0) null else avalues.ptr,
    );
    return switch (returns) {
        .void => 0,
        // A narrow integral return was widened into the full word by
        // libffi; the caller masks to the declared width, so handing
        // the word through unchanged loses nothing and invents
        // nothing.
        .uint8, .sint8, .uint16, .sint16, .uint32, .sint32, .uint64, .sint64, .pointer => answer,
        .float => @as(u32, @bitCast(@as(*const f32, @ptrCast(&answer)).*)),
        .double => @bitCast(@as(*const f64, @ptrCast(&answer)).*),
    };
}

// ---------------------------------------------------------------------------
// Tests — the shim against functions in this very image
// ---------------------------------------------------------------------------

const testing = std.testing;

export fn luce_ffi_probe_add(a: i64, b: i64) callconv(.c) i64 {
    return a + b;
}

export fn luce_ffi_probe_narrow(a: u32) callconv(.c) u32 {
    return a +% 1;
}

export fn luce_ffi_probe_pi() callconv(.c) f64 {
    return 3.5;
}

export fn luce_ffi_probe_sum_bytes(at: u64, count: u64) callconv(.c) i64 {
    if (at == 0 or count == 0) return 0;
    const bytes: [*]const u8 = @ptrFromInt(at);
    var total: i64 = 0;
    for (bytes[0..count]) |b| total += b;
    return total;
}

/// C's null, deliberately: what a `foreign?` return decodes to `none`
/// and a bare `foreign` return turns into the `null_foreign` trap
/// (docs/FFI.md).
export fn luce_ffi_probe_null() callconv(.c) u64 {
    return 0;
}

/// A stable non-null token for the present half of the decode specs.
export fn luce_ffi_probe_token() callconv(.c) u64 {
    return 0x1234;
}

/// Echoes its token, so a `foreign?` parameter's encode (`none` -> 0)
/// and decode (0 -> `none`) can be watched round-trip in one call.
export fn luce_ffi_probe_echo(token: u64) callconv(.c) u64 {
    return token;
}

/// Echoes an `int`, so an integer-shaped handle (`extern type Device
/// = i32`) is watched crossing at its exact C width — zero included,
/// because an integer handle's zero is a value and takes no trap
/// (docs/FFI.md).
export fn luce_ffi_probe_echo_i32(v: i32) callconv(.c) i32 {
    return v;
}

/// A C string the `-> str` boundary copies and validates.
export fn luce_ffi_probe_greet() callconv(.c) [*:0]const u8 {
    return "hello from C";
}

/// Invalid UTF-8, deliberately: what the `-> str` boundary refuses to
/// launder (docs/FFI.md), pinned by the `invalid_utf8` trap spec.
export fn luce_ffi_probe_bad_text() callconv(.c) [*:0]const u8 {
    return "\xff\xfe";
}

/// `strlen`, so a `str` argument's NUL-terminated temporary is
/// observed from the C side.
export fn luce_ffi_probe_text_len(text: [*:0]const u8) callconv(.c) i64 {
    return @intCast(std.mem.span(text).len);
}

// -- the 0.21 phase-3 probes ------------------------------------------------

/// The out-parameter shape (docs/FFI.md): C fills the slots the
/// caller's compiler allocated, and the boundary reads them back as
/// extra results in declaration order after the declared return.
export fn luce_ffi_probe_split(v: i64, hi: ?*i32, lo: ?*i32) callconv(.c) bool {
    const bits: u64 = @bitCast(v);
    if (hi) |slot| slot.* = @bitCast(@as(u32, @truncate(bits >> 32)));
    if (lo) |slot| slot.* = @bitCast(@as(u32, @truncate(bits)));
    return true;
}

/// Writes `token` into an out slot, so a pointer-shaped handle
/// out-parameter's decode — the `null_foreign` trap on 0, `?`'s 0 to
/// `none` — is driven from the C side with any token the spec wants.
export fn luce_ffi_probe_out_token(token: u64, slot: ?*u64) callconv(.c) void {
    if (slot) |out| out.* = token;
}

/// The narrow-scalar round trips: each echoes its exact C type, so a
/// value that crossed with the wrong extension comes back changed.
export fn luce_ffi_probe_echo_u8(v: u8) callconv(.c) u8 {
    return v;
}

export fn luce_ffi_probe_echo_i8(v: i8) callconv(.c) i8 {
    return v;
}

export fn luce_ffi_probe_echo_u16(v: u16) callconv(.c) u16 {
    return v;
}

export fn luce_ffi_probe_echo_i16(v: i16) callconv(.c) i16 {
    return v;
}

export fn luce_ffi_probe_echo_f32(v: f32) callconv(.c) f32 {
    return v;
}

export fn luce_ffi_probe_echo_bool(v: bool) callconv(.c) bool {
    return v;
}

/// Widens two `signed char`s through C arithmetic: a caller that
/// zero-extended a negative `i8` produces a visibly wrong sum.
export fn luce_ffi_probe_add_i8(a: i8, b: i8) callconv(.c) i64 {
    return @as(i64, a) + @as(i64, b);
}

/// The `cuLaunchKernel` shape: eleven arguments, integers and doubles
/// interleaved, folded so every position contributes distinguishably
/// — a swapped or skipped slot changes the answer.
export fn luce_ffi_probe_arity11(
    a: i32,
    b: f64,
    c: i64,
    d: f64,
    e: i32,
    f: i64,
    g: f64,
    h: i32,
    i: i64,
    j: f64,
    k: i32,
) callconv(.c) f64 {
    var total: f64 = 0;
    total += 1 * @as(f64, @floatFromInt(a));
    total += 2 * b;
    total += 3 * @as(f64, @floatFromInt(c));
    total += 4 * d;
    total += 5 * @as(f64, @floatFromInt(e));
    total += 6 * @as(f64, @floatFromInt(f));
    total += 7 * g;
    total += 8 * @as(f64, @floatFromInt(h));
    total += 9 * @as(f64, @floatFromInt(i));
    total += 10 * j;
    total += 11 * @as(f64, @floatFromInt(k));
    return total;
}

/// The `cblas_dgemm` shape: fourteen arguments, enough to spill past
/// both register files on every emitted target, folded positionally
/// like `arity11`.
export fn luce_ffi_probe_arity14(
    a: i32,
    b: i32,
    c: i32,
    d: i64,
    e: i64,
    f: i64,
    g: f64,
    h: i64,
    i: i64,
    j: f64,
    k: i64,
    l: i64,
    m: f64,
    n: i64,
) callconv(.c) f64 {
    var total: f64 = 0;
    total += 1 * @as(f64, @floatFromInt(a));
    total += 2 * @as(f64, @floatFromInt(b));
    total += 3 * @as(f64, @floatFromInt(c));
    total += 4 * @as(f64, @floatFromInt(d));
    total += 5 * @as(f64, @floatFromInt(e));
    total += 6 * @as(f64, @floatFromInt(f));
    total += 7 * g;
    total += 8 * @as(f64, @floatFromInt(h));
    total += 9 * @as(f64, @floatFromInt(i));
    total += 10 * j;
    total += 11 * @as(f64, @floatFromInt(k));
    total += 12 * @as(f64, @floatFromInt(l));
    total += 13 * m;
    total += 14 * @as(f64, @floatFromInt(n));
    return total;
}

// -- the 0.21 phase-4a probes ------------------------------------------------

/// The extern-struct crossing (docs/FFI.md): a `const Rect *`
/// parameter whose fields are folded with position weights, so a
/// wrong offset or a swapped field changes the answer.
const ProbeRect = extern struct { x: i32, y: i32, w: i32, h: i32 };

export fn luce_ffi_probe_rect_sum(rect: ?*const ProbeRect) callconv(.c) i64 {
    const held = rect orelse return -1;
    return 1 * @as(i64, held.x) + 2 * @as(i64, held.y) +
        3 * @as(i64, held.w) + 4 * @as(i64, held.h);
}

/// The SDL_GetRectUnion shape: two structs in by pointer, one filled
/// through an out pointer.
export fn luce_ffi_probe_rect_union(
    a: ?*const ProbeRect,
    b: ?*const ProbeRect,
    slot: ?*ProbeRect,
) callconv(.c) bool {
    const first = a orelse return false;
    const second = b orelse return false;
    const out = slot orelse return false;
    const x = @min(first.x, second.x);
    const y = @min(first.y, second.y);
    const right = @max(first.x + first.w, second.x + second.w);
    const bottom = @max(first.y + first.h, second.y + second.h);
    out.* = .{ .x = x, .y = y, .w = right - x, .h = bottom - y };
    return true;
}

/// Nested extern structs (the layout-verification Outer shape): the
/// mixed widths force real padding, and every field carries its own
/// weight so a wrong inner offset changes the answer.
const ProbeInner = extern struct { a: i8, b: i32 };
const ProbeOuter = extern struct { a: i8, inner: ProbeInner, b: i8, tail: ProbeInner };

export fn luce_ffi_probe_outer_sum(outer: ?*const ProbeOuter) callconv(.c) i64 {
    const held = outer orelse return -1;
    return 1 * @as(i64, held.a) + 2 * @as(i64, held.inner.a) + 3 * @as(i64, held.inner.b) +
        4 * @as(i64, held.b) + 5 * @as(i64, held.tail.a) + 6 * @as(i64, held.tail.b);
}

/// Fills the nested shape through an out pointer, so the inner
/// offsets are watched in the read-back direction too.
export fn luce_ffi_probe_outer_fill(seed: i32, slot: ?*ProbeOuter) callconv(.c) void {
    const out = slot orelse return;
    out.* = .{
        .a = 1,
        .inner = .{ .a = 2, .b = seed },
        .b = 3,
        .tail = .{ .a = 4, .b = seed + 1 },
    };
}

/// Every remaining C-layout field family in one shape — `_Bool`,
/// `double`, narrow signed, `float`, `short`, a pointer-shaped
/// handle, and the widths around them — folded position by position.
const ProbeMixed = extern struct {
    a: bool,
    b: f64,
    c: i8,
    d: f32,
    e: i16,
    f: ?*anyopaque,
    g: u8,
    h: i64,
};

export fn luce_ffi_probe_mixed_sum(mixed: ?*const ProbeMixed) callconv(.c) f64 {
    const held = mixed orelse return -1;
    var total: f64 = 0;
    if (held.a) total += 1;
    total += 2 * held.b;
    total += 3 * @as(f64, @floatFromInt(held.c));
    total += 4 * @as(f64, held.d);
    total += 5 * @as(f64, @floatFromInt(held.e));
    if (held.f != null) total += 6;
    total += 7 * @as(f64, @floatFromInt(held.g));
    total += 8 * @as(f64, @floatFromInt(held.h));
    return total;
}

/// Writes one present token and one null into an out struct's
/// pointer-shaped handle fields: a field read carries no automatic
/// trap, and the spec watches the zero arrive as a value
/// (docs/FFI.md).
const ProbePair = extern struct { first: u64, second: u64 };

export fn luce_ffi_probe_pair_fill(token: u64, slot: ?*ProbePair) callconv(.c) void {
    const out = slot orelse return;
    out.* = .{ .first = token, .second = 0 };
}

/// The `extern var` probes (docs/FFI.md): a mutable C global beside
/// the C-side reader and writer that prove a Luce store landed on the
/// real symbol and a C store is seen by a direct Luce load.
export var luce_ffi_probe_counter: i64 = 11;

export fn luce_ffi_probe_counter_read() callconv(.c) i64 {
    return luce_ffi_probe_counter;
}

export fn luce_ffi_probe_counter_write(value: i64) callconv(.c) void {
    luce_ffi_probe_counter = value;
}

/// A pointer-shaped global for the bare-semantics case: reading zero
/// out of a handle-typed `extern var` is a value, never a trap.
export var luce_ffi_probe_token_slot: u64 = 0;

/// The `str?` echo.  The answer is copied into private storage first:
/// the boundary frees an argument's NUL temporary the moment the call
/// returns, so echoing the argument pointer itself would hand the
/// caller freed memory.
var echo_text_storage: [64]u8 = undefined;

export fn luce_ffi_probe_echo_text(text: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 {
    const source = text orelse return null;
    const held = std.mem.span(source);
    std.debug.assert(held.len < echo_text_storage.len);
    @memcpy(echo_text_storage[0..held.len], held);
    echo_text_storage[held.len] = 0;
    return @ptrCast(&echo_text_storage);
}

test "the shim resolves and calls through every return kind" {
    const add = resolve("luce_ffi_probe_add") orelse return error.TestUnexpectedResult;
    const summed = try call(
        testing.allocator,
        add,
        &.{ .sint64, .sint64 },
        &.{ @bitCast(@as(i64, 40)), @bitCast(@as(i64, 2)) },
        .sint64,
    );
    try testing.expectEqual(@as(i64, 42), @as(i64, @bitCast(summed)));

    const narrow = resolve("luce_ffi_probe_narrow") orelse return error.TestUnexpectedResult;
    const bumped = try call(testing.allocator, narrow, &.{.uint32}, &.{9}, .uint32);
    // Only the low half is owed; the caller masks.
    try testing.expectEqual(@as(u32, 10), @as(u32, @truncate(bumped)));

    const pi = resolve("luce_ffi_probe_pi") orelse return error.TestUnexpectedResult;
    const answered = try call(testing.allocator, pi, &.{}, &.{}, .double);
    try testing.expectEqual(@as(f64, 3.5), @as(f64, @bitCast(answered)));
}

test "the shim carries float arguments and narrow signed values" {
    // What retired the thunk table: a float argument travels in the
    // FP register class, and libffi is what knows that.
    const echo_f32 = resolve("luce_ffi_probe_echo_f32") orelse return error.TestUnexpectedResult;
    const bits: u32 = @bitCast(@as(f32, 2.5));
    const back = try call(testing.allocator, echo_f32, &.{.float}, &.{bits}, .float);
    try testing.expectEqual(@as(f32, 2.5), @as(f32, @bitCast(@as(u32, @truncate(back)))));

    // A negative i8 crosses with its sign: -5 + -6 is -11 only when
    // both arguments arrived sign-correct.
    const add_i8 = resolve("luce_ffi_probe_add_i8") orelse return error.TestUnexpectedResult;
    const low: u64 = @as(u8, @bitCast(@as(i8, -5)));
    const high: u64 = @as(u8, @bitCast(@as(i8, -6)));
    const summed = try call(testing.allocator, add_i8, &.{ .sint8, .sint8 }, &.{ low, high }, .sint64);
    try testing.expectEqual(@as(i64, -11), @as(i64, @bitCast(summed)));
}

test "the shim passes eleven mixed arguments position-correct" {
    const target = resolve("luce_ffi_probe_arity11") orelse return error.TestUnexpectedResult;
    const answered = try call(
        testing.allocator,
        target,
        &.{ .sint32, .double, .sint64, .double, .sint32, .sint64, .double, .sint32, .sint64, .double, .sint32 },
        &.{
            1,                       @bitCast(@as(f64, 2.0)),
            3,                       @bitCast(@as(f64, 4.0)),
            5,                       6,
            @bitCast(@as(f64, 7.0)), 8,
            9,                       @bitCast(@as(f64, 10.0)),
            11,
        },
        .double,
    );
    // sum of n * n for n in 1..11
    try testing.expectEqual(@as(f64, 506.0), @as(f64, @bitCast(answered)));
}

test "a symbol nothing carries answers null" {
    try testing.expectEqual(@as(?*anyopaque, null), resolve("luce_ffi_probe_that_never_existed"));
}
