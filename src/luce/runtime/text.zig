//! String storage and the pure conversion builtins.
//!
//! A Luce String is immutable and UTF-8.  Every function here that
//! makes new text hands it back owned by nobody: whatever receives it
//! next owns it, and the statement that produced it releases it if
//! nothing does (docs/STRINGS.md).  Where the bytes go is the value's
//! own business — short text lives inside the `Value` and costs no
//! allocation at all, which is why `str(long)` and `chr` never call the
//! allocator.  `slice` is the one borrow here, on both engines, and
//! storing one copies; a slice of inline text is a copy already,
//! because there is nothing to borrow from.
//!
//! The String surface the language keeps is deliberately small — `+`,
//! comparison, checked `s[a:b]`, `len`, `byte_at`, `find_byte` — and
//! everything else is the `strings` std module built on top of it
//! (docs/LANGUAGE.md).

const std = @import("std");
const heap = @import("heap.zig");
const value = @import("value.zig");

const Error = heap.Error;
const Runtime = heap.Runtime;
const Value = value.Value;

/// True when `index` is either the end of `held` or the first byte of a
/// UTF-8 sequence.  Slicing anywhere else would produce a String that
/// is not valid UTF-8.
pub fn isStringBoundary(held: []const u8, index: usize) bool {
    return index == held.len or held[index] & 0xc0 != 0x80;
}

/// `left + right`, in fresh owned storage — inside the value when the
/// result fits there, which costs the join nothing and the release
/// nothing (docs/STRINGS.md).
pub fn concat(runtime: *Runtime, left: []const u8, right: []const u8) Error!Value {
    const length = left.len + right.len;
    if (length == 0) return Value.ofString("");
    if (Value.fitsInline(length)) {
        var joined: [value.inline_capacity]u8 = undefined;
        @memcpy(joined[0..left.len], left);
        @memcpy(joined[left.len..length], right);
        return Value.ofInlineText(.string, joined[0..length]);
    }
    return Value.ofString(try std.mem.concat(runtime.objects, u8, &.{ left, right }));
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
    const text = held.asString();
    if (start < 0 or end < start or end > text.len) return runtime.fail(.string_bounds);
    const start_index: usize = @intCast(start);
    const end_index: usize = @intCast(end);
    if (!isStringBoundary(text, start_index) or !isStringBoundary(text, end_index)) {
        return runtime.fail(.string_boundary);
    }
    const wanted = text[start_index..end_index];
    if (held.textIsInline()) return Value.ofInlineText(held.tag, wanted);
    return Value.ofString(wanted);
}

/// `s.byte_at(i)` — one raw byte, below the UTF-8 layer on purpose.
pub fn byteAt(runtime: *Runtime, held: Value, index: i64) Error!Value {
    const text = held.asString();
    if (index < 0 or index >= text.len) return runtime.fail(.string_bounds);
    return Value.ofByte(text[@intCast(index)]);
}

/// `s.find_byte(b, from)` — the scanning primitive std's substring
/// search is built on, and the seam SIMD would enter through.  Answers
/// -1 when the byte is not there.
pub fn findByte(runtime: *Runtime, held: Value, byte: i64, start: i64) Error!Value {
    const text = held.asString();
    if (byte < 0 or byte > 0xFF) return runtime.fail(.bad_codepoint);
    if (start < 0 or start > text.len) return runtime.fail(.string_bounds);
    const from: usize = @intCast(start);
    const at = std.mem.indexOfScalarPos(u8, text, from, @intCast(byte)) orelse
        return Value.ofLong(-1);
    return Value.ofLong(@intCast(at));
}

// ---------------------------------------------------------------------------
// Conversions
// ---------------------------------------------------------------------------

/// `str(x)` for every type it accepts.  Every answer is fresh owned
/// text, including the two that could have been a view — `str(s)` of a
/// String and `str(b)` of a Bool — because a producer that sometimes
/// allocates and sometimes borrows cannot be told apart at its use
/// site, and the whole ownership rule turns on being able to
/// (docs/STRINGS.md).  A Builder hands back a copy of its bytes, so
/// later appends do not change the String that was taken.
pub fn str(runtime: *Runtime, held: Value) Error!Value {
    switch (held.view()) {
        // Twenty digits and a sign is the longest an i64 gets, so a
        // number's text always fits inside the value and `string(i)` in
        // a loop allocates nothing at all.
        .byte => |number| return digitsOf(number),
        .short => |number| return digitsOf(number),
        .int => |number| return digitsOf(number),
        .long => |number| return digitsOf(number),
        // `{d}` on a float is the shortest representation that round
        // trips **at its own width** — Zig's Ryū-derived formatter,
        // which is width-generic, so `string(float(1.0) / float(3.0))`
        // is "0.33333334" and not binary64's seventeen digits
        // (docs/TYPES.md §3).
        .half => |number| return floatText(runtime, number),
        .float => |number| return floatText(runtime, number),
        .double => |number| return floatText(runtime, number),
        .boolean => |held_bool| return runtime.ownValue(
            Value.ofString(if (held_bool) "true" else "false"),
        ),
        .string => return runtime.ownValue(held),
        .object => switch ((try runtime.resolve(held)).data) {
            .builder => |builder| return runtime.ownValue(Value.ofString(builder.items)),
            .list, .map, .array, .file, .task => return runtime.fail(.not_owned),
        },
        else => return runtime.fail(.not_owned),
    }
}

/// An integer's digits, at either width.  The text always fits inside
/// the value, so this allocates nothing.
fn digitsOf(number: anytype) Value {
    var digits: [24]u8 = undefined;
    return Value.ofInlineText(.string, std.fmt.bufPrint(
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
/// difference — comparisons answer false, `parse_float` refuses NaN,
/// and `long(NaN)` traps.  Canonicalizing here makes every
/// NaN-producing operation print identically on every host, so the
/// backend needs no per-operation canonicalization at all.
fn floatText(runtime: *Runtime, number: anytype) Error!Value {
    if (std.math.isNan(number)) return Value.ofInlineText(.string, "nan");
    var written: [64]u8 = undefined;
    const rendered = std.fmt.bufPrint(&written, "{d}", .{number}) catch
        return Value.ofString(try std.fmt.allocPrint(
            runtime.objects,
            "{d}",
            .{number},
        ));
    return runtime.ownValue(Value.ofString(rendered));
}

/// `parse_int(s) -> long?`.  "Not a number" is the same reason every
/// time and the function's name already implies it, so the answer is
/// absence rather than a trap or an error (docs/FAILURE.md).
pub fn parseInt(runtime: *Runtime, held: Value) Error!Value {
    _ = runtime;
    const parsed = std.fmt.parseInt(i64, held.asString(), 10) catch return Value.none;
    return Value.ofLong(parsed);
}

/// `parse_float(s) -> double?`.  Refuses what `str` would never produce
/// as a number: NaN and the infinities parse, and are answered absent
/// here so a double that came from text is always finite.
pub fn parseFloat(runtime: *Runtime, held: Value) Error!Value {
    _ = runtime;
    const parsed = std.fmt.parseFloat(f64, held.asString()) catch return Value.none;
    if (std.math.isNan(parsed) or std.math.isInf(parsed)) return Value.none;
    return Value.ofDouble(parsed);
}

/// `chr(code)` — one codepoint, UTF-8 encoded into fresh owned
/// storage, sized to the encoding so the release gives back exactly
/// what was taken.
pub fn chr(runtime: *Runtime, code: i64) Error!Value {
    if (code < 0 or code > 0x10FFFF) return runtime.fail(.bad_codepoint);
    const codepoint: u21 = @intCast(code);
    var buffer: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(codepoint, &buffer) catch
        return runtime.fail(.bad_codepoint);
    // Four bytes at the most, so a codepoint always fits in the value.
    return Value.ofInlineText(.string, buffer[0..length]);
}

/// `ord(s)` — the first codepoint of `s`, or a trap when there is none
/// or the bytes are not a whole sequence.
pub fn ord(runtime: *Runtime, held: Value) Error!Value {
    const text = held.asString();
    if (text.len == 0) return runtime.fail(.bad_codepoint);
    const length = std.unicode.utf8ByteSequenceLength(text[0]) catch
        return runtime.fail(.bad_codepoint);
    if (text.len < length) return runtime.fail(.bad_codepoint);
    const codepoint = std.unicode.utf8Decode(text[0..length]) catch
        return runtime.fail(.bad_codepoint);
    return Value.ofLong(codepoint);
}
