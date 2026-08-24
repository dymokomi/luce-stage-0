//! `str` and `bytes` storage plus the pure conversion builtins.
//!
//! A Luce `str` is immutable and UTF-8. Every function here that
//! makes new text hands it back owned by nobody: whatever receives it
//! next owns it, and the statement that produced it releases it if
//! nothing does (docs/STRINGS.md).  Where the bytes go is the value's
//! own business — short text lives inside the `Value` and costs no
//! allocation at all. `slice` is the one borrow here, on both engines, and
//! storing one copies; a slice of inline text is a copy already,
//! because there is nothing to borrow from.
//!
//! The `str` surface the language keeps is deliberately small — `+`,
//! comparison, checked `s[a:b]`, `len`, `byte_at`, `find_byte` — and
//! everything else is the `strings` std module built on top of it
//! (docs/LANGUAGE.md).

const std = @import("std");
const heap = @import("heap.zig");
const value = @import("value.zig");

const Error = heap.Error;
const Runtime = heap.Runtime;
const Value = value.Value;

/// Whether a byte run can inhabit Luce's `str` type.
///
/// This is the one UTF-8 predicate used by binary-to-text parsing,
/// whole-file text reads, and every host ingress. Keeping it here makes
/// the `str` invariant a runtime rule shared by both execution engines.
pub fn isValid(encoded: []const u8) bool {
    return std.unicode.utf8ValidateSlice(encoded);
}

/// Copy text borrowed from a host into a Luce value. A host slot that
/// claims arbitrary bytes are text has violated the ABI contract, so it
/// fails closed before an invalid `str` can enter the program.
pub fn ownHost(runtime: *Runtime, encoded: []const u8) Error!Value {
    try requireHost(runtime, encoded);
    return runtime.ownValue(Value.ofStr(encoded));
}

/// Validate host-owned text that is copied somewhere other than a Value,
/// such as the terminal's remembered key payload.
pub fn requireHost(runtime: *Runtime, encoded: []const u8) Error!void {
    if (!isValid(encoded)) return runtime.fail(.host_unavailable);
}

/// `parse_str(data)` — immutable bytes as text, or absent when they are
/// not valid UTF-8. The successful result owns its storage independently
/// of the source bytes.
pub fn parseStr(runtime: *Runtime, held: Value) Error!Value {
    if (!held.hasValidBytesRepresentation()) return runtime.fail(.not_owned);
    const encoded = held.asBytes();
    if (!isValid(encoded)) return Value.none;
    return runtime.ownValue(Value.ofStr(encoded));
}

/// True when `index` is either the end of `held` or the first byte of a
/// UTF-8 sequence. Slicing anywhere else would produce a `str` that
/// is not valid UTF-8.
pub fn isStringBoundary(held: []const u8, index: usize) bool {
    return index == held.len or held[index] & 0xc0 != 0x80;
}

/// `left + right`, in fresh owned storage — inside the value when the
/// result fits there, which costs the join nothing and the release
/// nothing (docs/STRINGS.md).
pub fn concat(runtime: *Runtime, left: Value, right: Value) Error!Value {
    if (left.tag != right.tag) return runtime.fail(.not_owned);
    const tag = left.tag;
    const left_bytes, const right_bytes = switch (tag) {
        .str => blk: {
            if (!left.hasValidStringRepresentation() or !right.hasValidStringRepresentation()) {
                return runtime.fail(.not_owned);
            }
            break :blk .{ left.asStr(), right.asStr() };
        },
        .bytes => blk: {
            if (!left.hasValidBytesRepresentation() or !right.hasValidBytesRepresentation()) {
                return runtime.fail(.not_owned);
            }
            break :blk .{ left.asBytes(), right.asBytes() };
        },
        else => return runtime.fail(.not_owned),
    };
    const joined_length = std.math.add(usize, left_bytes.len, right_bytes.len) catch
        return error.OutOfMemory;
    if (joined_length == 0) return Value.ofOutside(tag, "");
    if (Value.fitsInline(joined_length)) {
        var joined: [value.inline_capacity]u8 = undefined;
        @memcpy(joined[0..left_bytes.len], left_bytes);
        @memcpy(joined[left_bytes.len..joined_length], right_bytes);
        return Value.ofInlineText(tag, joined[0..joined_length]);
    }
    return Value.ofOutside(tag, try std.mem.concat(runtime.objects, u8, &.{ left_bytes, right_bytes }));
}

/// `s[start:end]` — a borrow of the original bytes, checked twice: in
/// range, and on UTF-8 sequence boundaries at both ends.
///
/// A slice of *inline* text is a copy rather than a borrow, and costs
/// nothing for it: the source is at most `inline_capacity` bytes, so
/// any part of it fits inline too.  That is not an optimisation, it is
/// what keeps the borrow honest — inline bytes live in the value, and
/// `held` is a copy of the caller's, so a view of it would be a view of
/// something about to go (docs/STRINGS.md).
pub fn slice(runtime: *Runtime, held: Value, start: i64, end: i64) Error!Value {
    if (start < 0 or end < start) return runtime.fail(.str_bounds);
    const source_bytes: []const u8, const start_index: usize, const end_index: usize = switch (held.tag) {
        .str => blk: {
            if (!held.hasValidStringRepresentation()) return runtime.fail(.not_owned);
            const text = held.asStr();
            const first = scalarOffset(text, @intCast(start)) orelse return runtime.fail(.str_bounds);
            const last = scalarOffset(text, @intCast(end)) orelse return runtime.fail(.str_bounds);
            break :blk .{ text, first, last };
        },
        .bytes => blk: {
            if (!held.hasValidBytesRepresentation()) return runtime.fail(.not_owned);
            const data = held.asBytes();
            if (end > data.len) return runtime.fail(.str_bounds);
            break :blk .{ data, @intCast(start), @intCast(end) };
        },
        else => return runtime.fail(.not_owned),
    };
    const wanted = source_bytes[start_index..end_index];
    if (held.textIsInline()) return Value.ofInlineText(held.tag, wanted);
    return Value.ofOutside(held.tag, wanted);
}

pub fn length(runtime: *Runtime, held: Value) Error!Value {
    return switch (held.tag) {
        .str => blk: {
            if (!held.hasValidStringRepresentation()) return runtime.fail(.not_owned);
            break :blk Value.ofI64(@intCast(scalarCount(held.asStr())));
        },
        .bytes => blk: {
            if (!held.hasValidBytesRepresentation()) return runtime.fail(.not_owned);
            break :blk Value.ofI64(@intCast(held.asBytes().len));
        },
        else => runtime.fail(.not_owned),
    };
}

pub fn at(runtime: *Runtime, held: Value, index: i64) Error!Value {
    if (index < 0) return runtime.fail(.str_bounds);
    return switch (held.tag) {
        .str => blk: {
            if (!held.hasValidStringRepresentation()) return runtime.fail(.not_owned);
            const text = held.asStr();
            const first = scalarOffset(text, @intCast(index)) orelse return runtime.fail(.str_bounds);
            if (first == text.len) return runtime.fail(.str_bounds);
            const scalar_length = std.unicode.utf8ByteSequenceLength(text[first]) catch unreachable;
            break :blk Value.ofChar(std.unicode.utf8Decode(text[first..][0..scalar_length]) catch unreachable);
        },
        .bytes => blk: {
            if (!held.hasValidBytesRepresentation()) return runtime.fail(.not_owned);
            const data = held.asBytes();
            if (index >= data.len) return runtime.fail(.str_bounds);
            break :blk Value.ofU8(data[@intCast(index)]);
        },
        else => runtime.fail(.not_owned),
    };
}

fn scalarCount(text: []const u8) usize {
    var count: usize = 0;
    var offset: usize = 0;
    while (offset < text.len) : (count += 1) {
        offset += std.unicode.utf8ByteSequenceLength(text[offset]) catch unreachable;
    }
    return count;
}

fn scalarOffset(text: []const u8, wanted: usize) ?usize {
    var scalar: usize = 0;
    var offset: usize = 0;
    while (scalar < wanted) : (scalar += 1) {
        if (offset >= text.len) return null;
        offset += std.unicode.utf8ByteSequenceLength(text[offset]) catch return null;
    }
    return offset;
}

/// `s.byte_at(i)` — one raw byte, below the UTF-8 layer on purpose.
pub fn byteAt(runtime: *Runtime, held: Value, index: i64) Error!Value {
    if (!held.hasValidStringRepresentation()) return runtime.fail(.not_owned);
    const text = held.asStr();
    if (index < 0 or index >= text.len) return runtime.fail(.str_bounds);
    return Value.ofU8(text[@intCast(index)]);
}

/// `s.find_byte(b, from)` — the scanning primitive std's substring
/// search is built on, and the seam SIMD would enter through.  Answers
/// -1 when the byte is not there.
pub fn findByte(runtime: *Runtime, held: Value, byte: i64, start: i64) Error!Value {
    if (!held.hasValidStringRepresentation()) return runtime.fail(.not_owned);
    const text = held.asStr();
    if (byte < 0 or byte > 0xFF) return runtime.fail(.bad_codepoint);
    if (start < 0 or start > text.len) return runtime.fail(.str_bounds);
    const from: usize = @intCast(start);
    const found_at = std.mem.indexOfScalarPos(u8, text, from, @intCast(byte)) orelse
        return Value.ofI64(-1);
    return Value.ofI64(@intCast(found_at));
}

// ---------------------------------------------------------------------------
// Conversions
// ---------------------------------------------------------------------------

/// `str(x)` for every type it accepts.  Every answer is fresh owned
/// text, including the two that could have been a view — `str(s)` of a
/// str and `str(b)` of a bool — because a producer that sometimes
/// allocates and sometimes borrows cannot be told apart at its use
/// site, and the whole ownership rule turns on being able to
/// (docs/STRINGS.md). A builder hands back a copy of its bytes, so
/// later appends do not change the str that was taken.
pub fn str(runtime: *Runtime, held: Value) Error!Value {
    if (!held.hasValidRepresentation()) return runtime.fail(.not_owned);
    switch (held.view()) {
        // Twenty digits and a sign is the longest an i64 gets, so a
        // number's text always fits inside the value and `str(i)` in
        // a loop allocates nothing at all.
        .u8 => |number| return digitsOf(number),
        .u16 => |number| return digitsOf(number),
        .u32 => |number| return digitsOf(number),
        .u64 => |number| return digitsOf(number),
        .i8 => |number| return digitsOf(number),
        .i16 => |number| return digitsOf(number),
        .i32 => |number| return digitsOf(number),
        .i64 => |number| return digitsOf(number),
        .char => |scalar| {
            var buffer: [4]u8 = undefined;
            const encoded_length = std.unicode.utf8Encode(@intCast(scalar), &buffer) catch
                return runtime.fail(.bad_codepoint);
            return Value.ofInlineText(.str, buffer[0..encoded_length]);
        },
        // `{d}` on a float is the shortest representation that round
        // trips **at its own width** — Zig's Ryū-derived formatter,
        // which is width-generic, so `str(f32(1.0) / f32(3.0))`
        // is "0.33333334" and not binary64's seventeen digits
        // (docs/TYPES.md §3).
        .f16 => |number| return floatText(runtime, number),
        .f32 => |number| return floatText(runtime, number),
        .f64 => |number| return floatText(runtime, number),
        .boolean => |held_bool| return runtime.ownValue(
            Value.ofStr(if (held_bool) "true" else "false"),
        ),
        .str => {
            if (!held.hasValidStringRepresentation()) return runtime.fail(.not_owned);
            return runtime.ownValue(held);
        },
        .object => switch ((try runtime.resolve(held)).data) {
            .builder => |builder| return runtime.ownValue(Value.ofStr(builder.items)),
            .instance, .list, .map, .array, .variant_box, .file, .task, .channel => return runtime.fail(.not_owned),
        },
        else => return runtime.fail(.not_owned),
    }
}

/// `bytes(value)` copies a textual or packed-u8 sequence into an
/// immutable binary value.  It never aliases a mutable list or array:
/// the conversion is the boundary at which later container writes stop
/// affecting the bytes that were produced.
pub fn bytes(runtime: *Runtime, held: Value) Error!Value {
    const source: []const u8 = switch (held.tag) {
        .str => blk: {
            if (!held.hasValidStringRepresentation()) return runtime.fail(.not_owned);
            break :blk held.asStr();
        },
        .object => blk: {
            const object = try runtime.resolve(held);
            switch (object.data) {
                .list => {},
                .array => if (object.dims.len != 1) return runtime.fail(.not_owned),
                .instance, .map, .builder, .variant_box, .file, .task, .channel => return runtime.fail(.not_owned),
            }
            if (object.elements.kind != .u8) return runtime.fail(.not_owned);
            break :blk object.elements.cells(u8);
        },
        else => return runtime.fail(.not_owned),
    };
    return runtime.ownValue(Value.ofBytes(source));
}

/// An integer's digits, at either width.  The text always fits inside
/// the value, so this allocates nothing.
fn digitsOf(number: anytype) Value {
    var digits: [24]u8 = undefined;
    return Value.ofInlineText(.str, std.fmt.bufPrint(
        &digits,
        "{d}",
        .{number},
    ) catch unreachable);
}

/// A float's shortest round-tripping text, at either width.  Every NaN
/// renders as "nan", whatever its sign bit says: IEEE 754 gives the
/// sign of a NaN no meaning, hardware disagrees about which sign an
/// invalid operation produces (`0.0 / 0.0` is a positive quiet NaN on
/// aarch64 and the negative "real indefinite" on x86-64), and this
/// formatter is the one place a Luce program could ever observe the
/// difference — comparisons answer false, `parse_f64` refuses NaN,
/// and `i64(NaN)` traps.  Canonicalizing here makes every
/// NaN-producing operation print identically on every host, so the
/// backend needs no per-operation canonicalization at all.
fn floatText(runtime: *Runtime, number: anytype) Error!Value {
    if (std.math.isNan(number)) return Value.ofInlineText(.str, "nan");
    var written: [64]u8 = undefined;
    const rendered = std.fmt.bufPrint(&written, "{d}", .{number}) catch
        return Value.ofStr(try std.fmt.allocPrint(
            runtime.objects,
            "{d}",
            .{number},
        ));
    return runtime.ownValue(Value.ofStr(rendered));
}

/// `parse_i64(s) -> i64?`.  "Not a number" is the same reason every
/// time and the function's name already implies it, so the answer is
/// absence rather than a trap or an error (docs/FAILURE.md).
pub fn parseI64(runtime: *Runtime, held: Value) Error!Value {
    if (!held.hasValidStringRepresentation()) return runtime.fail(.not_owned);
    const parsed = std.fmt.parseInt(i64, held.asStr(), 10) catch return Value.none;
    return Value.ofI64(parsed);
}

/// `parse_f64(s) -> f64?`.  Refuses what `str` would never produce
/// as a number: NaN and the infinities parse, and are answered absent
/// here so an f64 that came from text is always finite.
pub fn parseF64(runtime: *Runtime, held: Value) Error!Value {
    if (!held.hasValidStringRepresentation()) return runtime.fail(.not_owned);
    const parsed = std.fmt.parseFloat(f64, held.asStr()) catch return Value.none;
    if (std.math.isNan(parsed) or std.math.isInf(parsed)) return Value.none;
    return Value.ofF64(parsed);
}

/// `Builtin.bytes_at(pointer, count)` — `count` bytes copied out of
/// C-owned memory into a fresh `bytes` (docs/FFI.md).  A copy, never
/// a borrow: what happens to the foreign memory afterward is the
/// library's business, and the copy is already safely owned.  The
/// null token traps `null_foreign` — a callee that may answer null
/// declared `foreign?`, and `none` never reaches here.
pub fn bytesAt(runtime: *Runtime, pointer: Value, count: u64) Error!Value {
    const token: u64 = @bitCast(pointer.asI64());
    if (token == 0) return runtime.fail(.null_foreign);
    if (count == 0) return runtime.ownValue(Value.ofBytes(&.{}));
    const source: [*]const u8 = @ptrFromInt(token);
    return runtime.ownValue(Value.ofBytes(source[0..count]));
}

/// `Builtin.cstring_at(pointer)` — NUL-scan C-owned memory, copy, and
/// validate into a fresh `str` (docs/FFI.md).  A `str` is valid UTF-8
/// by contract, so invalid text traps `invalid_utf8` rather than
/// laundering the contract; an API that answers arbitrary bytes is a
/// `bytes_at` API.
pub fn cstringAt(runtime: *Runtime, pointer: Value) Error!Value {
    return cstringResult(runtime, @bitCast(pointer.asI64()));
}

/// A `str` argument crossing to C (docs/FFI.md): the bytes plus one
/// terminating zero, in a fresh allocation **borrowed for the call**.
/// The eight bytes before the handed-out address carry the
/// allocation's length so `cstringFree` can give back exactly what
/// was taken — `strlen` cannot be trusted for that job, because a
/// valid `str` may contain U+0000 and C's view simply truncates
/// there, which is C's business and not a memory-accounting error.
/// Answers the token as a `foreign` Value.
pub fn cstringMake(runtime: *Runtime, text_value: Value) Error!Value {
    if (!text_value.hasValidStringRepresentation()) return runtime.fail(.not_owned);
    const text = text_value.asStr();
    const total = 8 + text.len + 1;
    const buffer = runtime.objects.alloc(u8, total) catch
        return runtime.fail(.allocation_failed);
    std.mem.writeInt(u64, buffer[0..8], total, .little);
    @memcpy(buffer[8 .. 8 + text.len], text);
    buffer[total - 1] = 0;
    return Value.ofI64(@bitCast(@as(u64, @intFromPtr(buffer.ptr + 8))));
}

/// A `str?` argument crossing to C (docs/FFI.md): `none` crosses as
/// C's NULL — the zero token, which `cstringFree` already ignores —
/// and a present value takes `cstringMake`'s NUL-temporary rules
/// whole.
pub fn cstringMakeOpt(runtime: *Runtime, text_value: Value) Error!Value {
    if (text_value.isNone()) return Value.ofI64(0);
    return cstringMake(runtime, text_value);
}

/// The paired release: the call returned, the borrow is over.
pub fn cstringFree(runtime: *Runtime, token: u64) void {
    if (token == 0) return;
    const base: [*]u8 = @ptrFromInt(token - 8);
    const total = std.mem.readInt(u64, base[0..8], .little);
    runtime.objects.free(base[0..total]);
}

/// A `-> str` extern result (docs/FFI.md): the same copy-and-validate
/// `cstring_at` performs, from the raw token the call answered.
pub fn cstringResult(runtime: *Runtime, token: u64) Error!Value {
    if (token == 0) return runtime.fail(.null_foreign);
    const source: [*:0]const u8 = @ptrFromInt(token);
    const held = std.mem.span(source);
    if (!std.unicode.utf8ValidateSlice(held)) return runtime.fail(.invalid_utf8);
    return runtime.ownValue(Value.ofStr(held));
}

/// A `-> str?` extern result (docs/FFI.md): C's NULL decodes to
/// `none`; anything else takes `cstringResult`'s copy-and-validate
/// whole.
pub fn cstringResultOpt(runtime: *Runtime, token: u64) Error!Value {
    if (token == 0) return Value.none;
    return cstringResult(runtime, token);
}
