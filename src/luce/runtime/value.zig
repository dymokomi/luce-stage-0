//! The Luce runtime value: one 24-byte slot with a C layout.
//!
//! Everything the runtime library touches — a list element, a map key,
//! a struct field, an argument crossing the C boundary — is one of
//! these.  The layout is fixed because generated code builds and reads
//! them directly (docs/CODEGEN.md):
//!
//! ```c
//! struct LuceValue { uint64_t tag; uint64_t bits; uint64_t length; };
//! ```
//!
//! `bits` carries the whole payload of a scalar (an `i64`, an `f64`'s
//! bit pattern, a bool, an object index) or the address of a slice;
//! `length` is the slice length and is zero for everything else.  The
//! tag is a full word so the three fields sit at offsets 0, 8, and 16
//! on every target, with no padding for a reader to guess at.
//!
//! Nothing here owns memory.  String and struct payloads are borrowed
//! from the program's constants or from the runtime arena, and they
//! stay valid for the whole run — a value is a view, never a handle to
//! free.  Heap objects are the exception in spirit only: `object`
//! carries an index into the runtime's object table, and the table
//! entry, not the value, decides who frees it (docs/OWNERSHIP.md).
//!
//! `view()` exists for Zig callers.  Switching on a tagged union is how
//! the semantics were written and how they read best; the extern struct
//! is how they travel.  The two are the same 24 bytes.

const std = @import("std");

/// Which payload `Value.bits` and `Value.length` carry.  A full word so
/// the struct has no padding on any target.
pub const Tag = enum(u64) {
    /// No value: a statement's result, an unset frame slot.
    none = 0,
    boolean = 1,
    int = 2,
    float = 3,
    string = 4,
    bytes = 5,
    /// A struct value: `bits` addresses `length` fields.  Struct
    /// storage is never mutated in place — `struct_set` allocates a
    /// fresh array — so sharing one array between copies is safe.
    strukt = 6,
    /// An index into the runtime's object table, or `null_index`.
    object = 7,
};

/// The index no object ever has.  The zero value of an object-typed
/// place is this handle, and using it traps `null_object` instead of
/// touching anything.
pub const null_index: u32 = std.math.maxInt(u32);

pub const Value = extern struct {
    tag: Tag = .none,
    /// Scalar payload, or the address of the slice `length` measures.
    bits: u64 = 0,
    /// Slice length; zero for every scalar.
    length: u64 = 0,

    // -- construction ---------------------------------------------------

    pub const none: Value = .{ .tag = .none };
    pub const false_value: Value = .{ .tag = .boolean, .bits = 0 };
    pub const true_value: Value = .{ .tag = .boolean, .bits = 1 };
    /// The zero value of an object-typed place.
    pub const null_object: Value = .{ .tag = .object, .bits = null_index };

    pub fn ofBoolean(held: bool) Value {
        return .{ .tag = .boolean, .bits = @intFromBool(held) };
    }

    pub fn ofInt(held: i64) Value {
        return .{ .tag = .int, .bits = @bitCast(held) };
    }

    pub fn ofFloat(held: f64) Value {
        return .{ .tag = .float, .bits = @bitCast(held) };
    }

    pub fn ofString(held: []const u8) Value {
        return .{ .tag = .string, .bits = @intFromPtr(held.ptr), .length = held.len };
    }

    pub fn ofBytes(held: []const u8) Value {
        return .{ .tag = .bytes, .bits = @intFromPtr(held.ptr), .length = held.len };
    }

    pub fn ofStruct(fields: []Value) Value {
        return .{ .tag = .strukt, .bits = @intFromPtr(fields.ptr), .length = fields.len };
    }

    pub fn ofObject(index: u32) Value {
        return .{ .tag = .object, .bits = index };
    }

    // -- reading ---------------------------------------------------------
    //
    // Each accessor assumes the tag it names.  Luce is statically typed
    // and the IR verifier has already run, so a mismatch is a compiler
    // bug, not a program error — the same assumption the interpreter's
    // payload switches always made.

    pub fn asBoolean(self: Value) bool {
        return self.bits != 0;
    }

    pub fn asInt(self: Value) i64 {
        return @bitCast(self.bits);
    }

    pub fn asFloat(self: Value) f64 {
        return @bitCast(self.bits);
    }

    pub fn asString(self: Value) []const u8 {
        return self.textOf();
    }

    pub fn asBytes(self: Value) []const u8 {
        return self.textOf();
    }

    pub fn asStruct(self: Value) []Value {
        if (self.length == 0) return &.{};
        const fields: [*]Value = @ptrFromInt(@as(usize, @intCast(self.bits)));
        return fields[0..@intCast(self.length)];
    }

    pub fn asObject(self: Value) u32 {
        return @truncate(self.bits);
    }

    pub fn isNullObject(self: Value) bool {
        return self.asObject() == null_index;
    }

    /// True when this is the absent value of a `T?`.  One tag test for
    /// every payload type: a present `Int?` is tagged `int` and a
    /// present `List(T)?` is tagged `object`, so absence needs no
    /// per-type encoding and no second word (docs/FAILURE.md).  It is
    /// *not* the null object, which is a present handle to nothing.
    pub fn isNone(self: Value) bool {
        return self.tag == .none;
    }

    fn textOf(self: Value) []const u8 {
        if (self.length == 0) return "";
        const start: [*]const u8 = @ptrFromInt(@as(usize, @intCast(self.bits)));
        return start[0..@intCast(self.length)];
    }

    // -- switching --------------------------------------------------------

    /// The same 24 bytes as a tagged union, for Zig callers that want to
    /// switch on the payload.
    pub fn view(self: Value) View {
        return switch (self.tag) {
            .none => .none,
            .boolean => .{ .boolean = self.asBoolean() },
            .int => .{ .int = self.asInt() },
            .float => .{ .float = self.asFloat() },
            .string => .{ .string = self.asString() },
            .bytes => .{ .bytes = self.asBytes() },
            .strukt => .{ .strukt = self.asStruct() },
            .object => .{ .object = self.asObject() },
        };
    }
};

/// A `Value` seen as a tagged union.  Construction goes through
/// `Value.of*`; this is only for reading.
pub const View = union(enum) {
    none,
    boolean: bool,
    int: i64,
    float: f64,
    string: []const u8,
    bytes: []const u8,
    strukt: []Value,
    object: u32,
};

/// Map keys compare by content: the analyzer admits Int and String
/// keys only.
pub fn keyEquals(left: Value, right: Value) bool {
    return switch (left.view()) {
        .int => |held| held == right.asInt(),
        .string => |held| std.mem.eql(u8, held, right.asString()),
        else => unreachable, // the analyzer keys maps by Int or String
    };
}

test "the value layout is the one generated code assumes" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Value));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Value, "tag"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Value, "bits"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(Value, "length"));
}

test "every payload survives a round trip" {
    try std.testing.expectEqual(@as(i64, -9), Value.ofInt(-9).asInt());
    try std.testing.expectEqual(@as(f64, 1.5), Value.ofFloat(1.5).asFloat());
    try std.testing.expect(Value.ofBoolean(true).asBoolean());
    try std.testing.expect(!Value.ofBoolean(false).asBoolean());
    try std.testing.expectEqualStrings("hi", Value.ofString("hi").asString());
    try std.testing.expectEqualStrings("", Value.ofString("").asString());
    try std.testing.expectEqual(@as(u32, 7), Value.ofObject(7).asObject());
    try std.testing.expect(Value.null_object.isNullObject());

    var fields = [_]Value{ Value.ofInt(1), Value.ofString("two") };
    const held = Value.ofStruct(&fields);
    try std.testing.expectEqual(@as(usize, 2), held.asStruct().len);
    try std.testing.expectEqualStrings("two", held.asStruct()[1].asString());
}

test "a view carries the same payload as the accessors" {
    switch (Value.ofFloat(-0.0).view()) {
        .float => |held| try std.testing.expect(std.math.signbit(held)),
        else => return error.WrongTag,
    }
    switch (Value.none.view()) {
        .none => {},
        else => return error.WrongTag,
    }
}
