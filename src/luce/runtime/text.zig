//! String storage and the pure conversion builtins.
//!
//! A Luce String is immutable, UTF-8, and never owned by the value that
//! names it: results allocated here come from the runtime arena and
//! stay valid for the whole run.  The String surface the language keeps
//! is deliberately small — `+`, comparison, checked `s[a:b]`, `len`,
//! `byte_at`, `find_byte` — and everything else is the `strings` std
//! module built on top of it (docs/LANGUAGE.md).

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

/// `left + right`, in fresh arena storage.
pub fn concat(runtime: *Runtime, left: []const u8, right: []const u8) Error!Value {
    const joined = try std.mem.concat(runtime.arena, u8, &.{ left, right });
    return Value.ofString(joined);
}

/// `s[start:end]` — a borrow of the original bytes, checked twice: in
/// range, and on UTF-8 sequence boundaries at both ends.
pub fn slice(runtime: *Runtime, held: Value, start: i64, end: i64) Error!Value {
    const text = held.asString();
    if (start < 0 or end < start or end > text.len) return runtime.fail(.string_bounds);
    const start_index: usize = @intCast(start);
    const end_index: usize = @intCast(end);
    if (!isStringBoundary(text, start_index) or !isStringBoundary(text, end_index)) {
        return runtime.fail(.string_boundary);
    }
    return Value.ofString(text[start_index..end_index]);
}

/// `s.byte_at(i)` — one raw byte, below the UTF-8 layer on purpose.
pub fn byteAt(runtime: *Runtime, held: Value, index: i64) Error!Value {
    const text = held.asString();
    if (index < 0 or index >= text.len) return runtime.fail(.string_bounds);
    return Value.ofInt(text[@intCast(index)]);
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
        return Value.ofInt(-1);
    return Value.ofInt(@intCast(at));
}

// ---------------------------------------------------------------------------
// Conversions
// ---------------------------------------------------------------------------

/// `str(x)` for every type it accepts.  Int and Float allocate; Bool
/// answers static text; String is already the answer; a Builder hands
/// back a copy of its bytes, so later appends do not change the String
/// that was taken.
pub fn str(runtime: *Runtime, held: Value) Error!Value {
    switch (held.view()) {
        .int => |number| return Value.ofString(try intText(runtime, number)),
        // `{d}` on a float is the shortest representation that round
        // trips — Zig's Ryū-derived formatter, the same one the
        // hand-written wasm runtime had to port by hand.
        .float => |number| {
            const text = try std.fmt.allocPrint(runtime.arena, "{d}", .{number});
            return Value.ofString(text);
        },
        .boolean => |held_bool| return Value.ofString(if (held_bool) "true" else "false"),
        .string => return held,
        .object => {
            const object = try runtime.resolve(held);
            const text = try runtime.arena.dupe(u8, object.data.builder.items);
            return Value.ofString(text);
        },
        else => unreachable,
    }
}

/// `str(Int)` on its own, because generated code calls it directly and
/// wants the bytes rather than a `Value`.
pub fn intText(runtime: *Runtime, number: i64) Error![]const u8 {
    return std.fmt.allocPrint(runtime.arena, "{d}", .{number});
}

pub fn parseInt(runtime: *Runtime, held: Value) Error!Value {
    const parsed = std.fmt.parseInt(i64, held.asString(), 10) catch
        return runtime.fail(.parse_failed);
    return Value.ofInt(parsed);
}

/// `parse_float` refuses what `str` would never produce as a number:
/// NaN and the infinities parse, and are rejected here so a Float that
/// came from text is always finite.
pub fn parseFloat(runtime: *Runtime, held: Value) Error!Value {
    const parsed = std.fmt.parseFloat(f64, held.asString()) catch
        return runtime.fail(.parse_failed);
    if (std.math.isNan(parsed) or std.math.isInf(parsed)) return runtime.fail(.parse_failed);
    return Value.ofFloat(parsed);
}

/// `chr(code)` — one codepoint, UTF-8 encoded into arena storage.
pub fn chr(runtime: *Runtime, code: i64) Error!Value {
    if (code < 0 or code > 0x10FFFF) return runtime.fail(.bad_codepoint);
    const codepoint: u21 = @intCast(code);
    const encoded = try runtime.arena.alloc(u8, 4);
    const length = std.unicode.utf8Encode(codepoint, encoded) catch
        return runtime.fail(.bad_codepoint);
    return Value.ofString(encoded[0..length]);
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
    return Value.ofInt(codepoint);
}
