//! The FFI dispatch shim — the oracle's half of docs/FFI.md.
//!
//! Generated code calls an extern directly; the interpreter cannot,
//! because the shape it must call is data.  This file is the one
//! dynamic dispatcher: resolve the symbol in the running process —
//! symbols are link-time only, so whatever carries the oracle also
//! carries them — and call it through a comptime thunk table.
//!
//! The table is why Tier 1's vocabulary is what it is: every
//! parameter is a 32- or 64-bit integer or an opaque token, so every
//! argument travels as one 64-bit word (a 32-bit argument's value in
//! the low half, which is all the callee reads on every target this
//! compiler emits), and the return is void, one integer word, or one
//! `f64`.  Arity is capped at eight.  That is
//! `(9 arities) x (3 return kinds)` concrete function types — a
//! table, not libffi.
//!
//! **A 32-bit return is masked here**, not trusted: the callee owes
//! only the low half of the register, and the high bits are whatever
//! the machine left there.

const std = @import("std");

/// The Tier-1 arity cap (docs/FFI.md); the verifier holds it.
pub const max_parameters = 8;

/// What a call answers, before the caller narrows a 32-bit result.
pub const Answer = union(enum) {
    none,
    /// The full integer register; the caller truncates or sign-extends
    /// to the declared width.
    integer: u64,
    real: f64,
};

pub const ReturnKind = enum { none, integer, real };

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

/// One extern call: every argument already a 64-bit word, the return
/// kind already decided by the declaration.  The comptime table makes
/// this a direct C call for every shape Tier 1 admits.
pub fn call(target: *anyopaque, arguments: []const u64, kind: ReturnKind) Answer {
    std.debug.assert(arguments.len <= max_parameters);
    switch (arguments.len) {
        inline 0...max_parameters => |arity| switch (kind) {
            inline else => |returns| {
                const Fn = ThunkType(arity, returns);
                const callee: *const Fn = @ptrCast(@alignCast(target));
                var packed_arguments: std.meta.ArgsTuple(Fn) = undefined;
                inline for (0..arity) |index| {
                    packed_arguments[index] = arguments[index];
                }
                return switch (returns) {
                    .none => blk: {
                        @call(.auto, callee, packed_arguments);
                        break :blk .none;
                    },
                    .integer => .{ .integer = @call(.auto, callee, packed_arguments) },
                    .real => .{ .real = @call(.auto, callee, packed_arguments) },
                };
            },
        },
        else => unreachable,
    }
}

/// The C function type for one (arity, return-kind) cell of the
/// table.  Written out literally — nine rows, three return types —
/// because that *is* the whole table, and a reader can check it
/// against the C ABI by looking.
fn ThunkType(comptime arity: usize, comptime returns: ReturnKind) type {
    const R = switch (returns) {
        .none => void,
        .integer => u64,
        .real => f64,
    };
    return switch (arity) {
        0 => fn () callconv(.c) R,
        1 => fn (u64) callconv(.c) R,
        2 => fn (u64, u64) callconv(.c) R,
        3 => fn (u64, u64, u64) callconv(.c) R,
        4 => fn (u64, u64, u64, u64) callconv(.c) R,
        5 => fn (u64, u64, u64, u64, u64) callconv(.c) R,
        6 => fn (u64, u64, u64, u64, u64, u64) callconv(.c) R,
        7 => fn (u64, u64, u64, u64, u64, u64, u64) callconv(.c) R,
        8 => fn (u64, u64, u64, u64, u64, u64, u64, u64) callconv(.c) R,
        else => unreachable,
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

test "the shim resolves and calls through every return kind" {
    const add = resolve("luce_ffi_probe_add") orelse return error.TestUnexpectedResult;
    const summed = call(add, &.{ @bitCast(@as(i64, 40)), @bitCast(@as(i64, 2)) }, .integer);
    try testing.expectEqual(@as(u64, 42), summed.integer);

    const narrow = resolve("luce_ffi_probe_narrow") orelse return error.TestUnexpectedResult;
    const bumped = call(narrow, &.{9}, .integer);
    // Only the low half is owed; the caller masks.
    try testing.expectEqual(@as(u32, 10), @as(u32, @truncate(bumped.integer)));

    const pi = resolve("luce_ffi_probe_pi") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(f64, 3.5), call(pi, &.{}, .real).real);
}

test "a symbol nothing carries answers null" {
    try testing.expectEqual(@as(?*anyopaque, null), resolve("luce_ffi_probe_that_never_existed"));
}
