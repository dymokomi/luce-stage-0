//! String storage and the pure conversion builtins.
//!
//! A Luce String is immutable and UTF-8.  Every function here that
//! makes new text allocates it from `Runtime.objects` and hands it back
//! owned by nobody: whatever receives it next owns it, and the
//! statement that produced it releases it if nothing does
//! (docs/STRINGS.md).  `slice` is the exception and stays one — it is a
//! borrow of its argument, on both engines, and storing one copies.
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

/// `left + right`, in fresh owned storage.
pub fn concat(runtime: *Runtime, left: []const u8, right: []const u8) Error!Value {
    if (left.len + right.len == 0) return Value.ofString("");
    const joined = try std.mem.concat(runtime.objects, u8, &.{ left, right });
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

/// `str(x)` for every type it accepts.  Every answer is fresh owned
/// text, including the two that could have been a view — `str(s)` of a
/// String and `str(b)` of a Bool — because a producer that sometimes
/// allocates and sometimes borrows cannot be told apart at its use
/// site, and the whole ownership rule turns on being able to
/// (docs/STRINGS.md).  A Builder hands back a copy of its bytes, so
/// later appends do not change the String that was taken.
pub fn str(runtime: *Runtime, held: Value) Error!Value {
    switch (held.view()) {
        .int => |number| return Value.ofString(try intText(runtime, number)),
        // `{d}` on a float is the shortest representation that round
        // trips — Zig's Ryū-derived formatter, the same one the
        // hand-written wasm runtime had to port by hand.
        .float => |number| {
            const text = try std.fmt.allocPrint(runtime.objects, "{d}", .{number});
            return Value.ofString(text);
        },
        .boolean => |held_bool| return runtime.ownValue(
            Value.ofString(if (held_bool) "true" else "false"),
        ),
        .string => return runtime.ownValue(held),
        .object => {
            const object = try runtime.resolve(held);
            if (object.data.builder.items.len == 0) return Value.ofString("");
            const text = try runtime.objects.dupe(u8, object.data.builder.items);
            return Value.ofString(text);
        },
        else => unreachable,
    }
}

/// `str(Int)` on its own, because generated code calls it directly and
/// wants the bytes rather than a `Value`.
pub fn intText(runtime: *Runtime, number: i64) Error![]const u8 {
    return std.fmt.allocPrint(runtime.objects, "{d}", .{number});
}

/// `parse_int(s) -> Int?`.  "Not a number" is the same reason every
/// time and the function's name already implies it, so the answer is
/// absence rather than a trap or an error (docs/FAILURE.md).
pub fn parseInt(runtime: *Runtime, held: Value) Error!Value {
    _ = runtime;
    const parsed = std.fmt.parseInt(i64, held.asString(), 10) catch return Value.none;
    return Value.ofInt(parsed);
}

/// `parse_float(s) -> Float?`.  Refuses what `str` would never produce
/// as a number: NaN and the infinities parse, and are answered absent
/// here so a Float that came from text is always finite.
pub fn parseFloat(runtime: *Runtime, held: Value) Error!Value {
    _ = runtime;
    const parsed = std.fmt.parseFloat(f64, held.asString()) catch return Value.none;
    if (std.math.isNan(parsed) or std.math.isInf(parsed)) return Value.none;
    return Value.ofFloat(parsed);
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
    const encoded = try runtime.objects.dupe(u8, buffer[0..length]);
    return Value.ofString(encoded);
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
