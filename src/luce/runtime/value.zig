//! The Luce runtime value: one 24-byte slot with a C layout.
//!
//! Everything the runtime library touches — a list element, a map key,
//! a struct field, an argument crossing the C boundary — is one of
//! these.  The layout is fixed because generated code builds and reads
//! them directly (docs/CODEGEN.md):
//!
//! ```c
//! struct LuceValue {
//!     uint8_t  tag;
//!     uint8_t  inline_length;
//!     uint8_t  inline_head[6];
//!     uint64_t bits;
//!     uint64_t length;
//! };
//! ```
//!
//! `bits` carries the whole payload of a scalar (an `i64`, an `f64`'s
//! bit pattern, a bool, an object index) or the address of a slice;
//! `length` is the slice length and is zero for everything else.
//!
//! **Short text lives in the value.**  The tag needs one byte, not
//! eight, and the seven that frees plus `bits` and `length` are
//! twenty-two contiguous bytes at offset 2 — enough for the strings
//! this language actually moves around (`String(long)` is at most twenty,
//! a split piece averages twelve), and the same twenty-two libc++
//! reaches in the same twenty-four.  `inline_length` says which form
//! the text is in: a count from 0 to `inline_capacity` when the bytes
//! are here, `text_outside` when `bits` and `length` address them.
//! Reading either form goes through `asString`, which is why it takes
//! a pointer — the slice it answers for inline text points *into the
//! value*, so the value must be somewhere, not a temporary
//! (docs/STRINGS.md).
//!
//! What a value owns it owns exactly once: outside text and a struct's
//! field run are heap allocations with one owner, inline text is the
//! value itself and has nothing to free.  Heap objects are neither —
//! `object` carries a `Handle` into the runtime's object table, and
//! the table row, not the value, decides who frees it
//! (docs/OWNERSHIP.md).
//!
//! `view()` exists for Zig callers.  Switching on a tagged union is how
//! the semantics were written and how they read best; the extern struct
//! is how they travel.  The two are the same 24 bytes.

const std = @import("std");

/// Which payload a `Value` carries.  One byte, because the other seven
/// are worth more as text (see the header).
pub const Tag = enum(u8) {
    /// No value: a statement's result, an unset frame slot.
    none = 0,
    boolean = 1,
    long = 2,
    double = 3,
    string = 4,
    /// A struct value: `bits` addresses `length` fields.  Struct
    /// storage is never mutated in place — `struct_set` allocates a
    /// fresh array — so sharing one array between copies is safe.
    strukt = 5,
    /// A `Handle` into the runtime's object table.
    object = 6,
    /// The narrow widths, **appended**: no number above ever changes
    /// what it means, which is the append-only rule the whole ABI is
    /// built on (docs/TYPES.md §6).  Each width gets a tag of its own
    /// rather than sharing one with its family, because
    /// `heap.Object.ElementKind.of` derives an array's cell width from
    /// the zero element's tag — the runtime is handed a zero and never
    /// the program's type table — and a `float` whose zero boxed as
    /// `double` would silently allocate eight-byte cells.
    int = 7,
    float = 8,
    /// The three storage widths (docs/TYPES.md D5), appended in their
    /// turn.  No expression ever has one of these types — an operator
    /// widens them first — so a `Value` wears one only where storage
    /// does: an `array(byte, n)`'s zero, a boxed field, a boxed
    /// element crossing into a caller.
    byte = 9,
    short = 10,
    half = 11,
    /// A **function value**: `bits` addresses `length` slots, exactly
    /// as `strukt` does, and the two slots are the function it names
    /// and the receiver it carries (docs/BINDING.md D12).
    ///
    /// **It is a tag of its own for one reason, and it is a semantic
    /// one**: a function value owns the run that holds it and never
    /// owns the objects inside it (docs/BINDING.md D4).  The receiver
    /// is *borrowed*, so every ownership walk — bind, unbind, adopt,
    /// loosen, free, the givable check — must stop at this run instead
    /// of descending into it and re-owning somebody else's graph.  A
    /// walk cannot tell a borrowed run from an owning one by looking,
    /// so the tag says it.  Storage is the other half and is unchanged:
    /// `ownValue` duplicates this run and `dropStorage` frees it, both
    /// exactly as for `strukt`, because the run itself *is* owned.
    ///
    /// Appended, like every tag since `strukt`: no number above ever
    /// changes what it means.
    function = 12,
};

/// The index no object ever has.  The zero value of an object-typed
/// place is this handle, and using it traps `null_object` instead of
/// touching anything.
pub const null_index: u32 = std.math.maxInt(u32);

/// Where a handle's generation sits in `Value.bits`: above the index,
/// in the high 32 bits, which carried nothing before.  Published
/// because generated code takes the two halves apart itself
/// (`08_llvm/lower.zig`) and the two must not drift.
pub const generation_shift = 32;

/// Where inline text starts inside a `Value`, and how much of it there
/// is: everything from the byte after `inline_length` to the end of the
/// slot.  Published because generated code reads inline text with a
/// `getelementptr` of exactly this offset.
pub const inline_at: usize = 2;
pub const inline_capacity: u8 = 22;

/// The `inline_length` of text that is *not* in the value: `bits`
/// addresses it and `length` measures it.  Any other value from 0 to
/// `inline_capacity` is a count of bytes living in the slot itself.
pub const text_outside: u8 = 0xff;

/// Which object: the row of the runtime's object table it lives in,
/// and which occupant of that row it is.
///
/// **The index alone does not name an object.**  A row is reused once
/// its occupant is freed (`heap.Runtime`), so what makes a handle
/// name one specific object is the generation beside it: a row's
/// generation moves on every time its occupant dies, so a handle to a
/// freed object stays detectably stale even after somebody else has
/// moved into its row, and using it traps `use_after_free`
/// (docs/OWNERSHIP.md S9) rather than silently naming the newcomer.
///
/// A handle travels whole in `Value.bits` — the index in the low 32
/// bits, the generation in the high 32 — so resolving one is still
/// one load and one compare.  Nothing serializes a handle: an object
/// exists only while a program runs, so the `.lcm` format has never
/// heard of this.
pub const Handle = struct {
    index: u32,
    generation: u32 = 0,

    /// The handle that names no object at all.
    pub const none: Handle = .{ .index = null_index };

    /// Object identity: the same row *and* the same occupant of it.
    pub fn same(self: Handle, other: Handle) bool {
        return self.index == other.index and self.generation == other.generation;
    }
};

pub const Value = extern struct {
    tag: Tag = .none,
    /// How many bytes of text live in this value, or `text_outside`
    /// when `bits` addresses them.  Read only for `string`; every
    /// other tag leaves it zero.
    inline_length: u8 = 0,
    /// The first six bytes of inline text.  The other sixteen are
    /// `bits` and `length` — offsets 2 through 23 are one run, and
    /// `inlineText` reads it whole.  Named as a field because an
    /// `extern struct` cannot overlap two, and never read directly.
    inline_head: [6]u8 = @splat(0),
    /// Scalar payload, or the address of the slice `length` measures.
    /// Inline text lives here too, from its seventh byte on.
    bits: u64 = 0,
    /// Slice length; zero for every scalar, and unused by inline text.
    length: u64 = 0,

    // -- construction ---------------------------------------------------

    pub const none: Value = .{ .tag = .none };
    /// The zero value of an object-typed place.
    pub const null_object: Value = ofObject(.none);

    pub fn ofBoolean(held: bool) Value {
        return .{ .tag = .boolean, .bits = @intFromBool(held) };
    }

    pub fn ofLong(held: i64) Value {
        return .{ .tag = .long, .bits = @bitCast(held) };
    }

    pub fn ofDouble(held: f64) Value {
        return .{ .tag = .double, .bits = @bitCast(held) };
    }

    /// The narrow widths.  Each sits in the low bits of the same
    /// word, sign- or zero-extended by the reader rather than stored
    /// wide, so a boxed value is the same twenty-four bytes whatever
    /// it holds and only its tag says how much of `bits` is the
    /// number (docs/TYPES.md §6).
    pub fn ofInt(held: i32) Value {
        return .{ .tag = .int, .bits = @as(u32, @bitCast(held)) };
    }

    pub fn ofFloat(held: f32) Value {
        return .{ .tag = .float, .bits = @as(u32, @bitCast(held)) };
    }

    /// The storage widths.  A `byte` is the one whose bits are read
    /// back as a magnitude (D4); a `short` sign-extends, and a `half`
    /// keeps its sixteen binary16 bits and is widened by whoever
    /// reads it.
    pub fn ofByte(held: u8) Value {
        return .{ .tag = .byte, .bits = held };
    }

    pub fn ofShort(held: i16) Value {
        return .{ .tag = .short, .bits = @as(u16, @bitCast(held)) };
    }

    pub fn ofHalf(held: f16) Value {
        return .{ .tag = .half, .bits = @as(u16, @bitCast(held)) };
    }

    /// Text that lives somewhere else — a program constant, an owned
    /// allocation, a borrow of either.  This is the form every *view*
    /// takes, because a view must not copy.
    pub fn ofString(held: []const u8) Value {
        return ofOutside(.string, held);
    }

    /// The same, for a caller that already has the tag in hand.
    pub fn ofOutside(tag: Tag, held: []const u8) Value {
        return .{
            .tag = tag,
            .inline_length = text_outside,
            .bits = @intFromPtr(held.ptr),
            .length = held.len,
        };
    }

    /// Text that lives in the value.  `held` must fit — callers ask
    /// `fitsInline` first — and the bytes are copied in, so the answer
    /// borrows nothing and owns nothing.
    pub fn ofInlineText(tag: Tag, held: []const u8) Value {
        std.debug.assert(held.len <= inline_capacity);
        var made: Value = .{ .tag = tag, .inline_length = @intCast(held.len) };
        @memcpy(made.inlineStorage()[0..held.len], held);
        return made;
    }

    /// Whether text of this length can live in a value rather than in
    /// an allocation of its own.
    pub fn fitsInline(length: usize) bool {
        return length <= inline_capacity;
    }

    pub fn ofStruct(fields: []Value) Value {
        return .{ .tag = .strukt, .bits = @intFromPtr(fields.ptr), .length = fields.len };
    }

    /// A function value's run — the same bytes `ofStruct` makes, worn
    /// under the tag that says the objects inside it are borrowed
    /// (docs/BINDING.md D4, D12).
    pub fn ofFunction(slots: []Value) Value {
        return .{ .tag = .function, .bits = @intFromPtr(slots.ptr), .length = slots.len };
    }

    pub fn ofObject(handle: Handle) Value {
        return .{
            .tag = .object,
            .bits = handle.index |
                @as(u64, handle.generation) << generation_shift,
        };
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

    pub fn asLong(self: Value) i64 {
        return @bitCast(self.bits);
    }

    pub fn asDouble(self: Value) f64 {
        return @bitCast(self.bits);
    }

    pub fn asInt(self: Value) i32 {
        return @bitCast(@as(u32, @truncate(self.bits)));
    }

    pub fn asFloat(self: Value) f32 {
        return @bitCast(@as(u32, @truncate(self.bits)));
    }

    pub fn asByte(self: Value) u8 {
        return @truncate(self.bits);
    }

    pub fn asShort(self: Value) i16 {
        return @bitCast(@as(u16, @truncate(self.bits)));
    }

    pub fn asHalf(self: Value) f16 {
        return @bitCast(@as(u16, @truncate(self.bits)));
    }

    /// The text this value holds.
    ///
    /// **The receiver is a pointer on purpose.**  Inline text lives in
    /// the value, so the slice points into `self` and is good for
    /// exactly as long as `self` stays put — take it from a slot, a
    /// cell or a named local, never from a temporary, and never keep it
    /// across anything that could move or overwrite that place
    /// (docs/STRINGS.md).
    pub fn asString(self: *const Value) []const u8 {
        return self.textOf();
    }

    /// True when the text is in the value rather than behind `bits`.
    pub fn textIsInline(self: Value) bool {
        return self.inline_length != text_outside;
    }

    /// True when this value holds a heap allocation of its own — the
    /// question `dropStorage` and `ownValue` both turn on.  Inline
    /// text answers false: the bytes are the value.
    pub fn ownsStorage(self: Value) bool {
        return switch (self.tag) {
            .string => !self.textIsInline() and self.bits != 0 and self.length != 0,
            .strukt, .function => self.bits != 0 and self.length != 0,
            else => false,
        };
    }

    /// The field run behind a struct value, as a **mutable alias into
    /// the run itself** — not a copy.  Writing through it writes the
    /// struct, and every other value sharing the run sees it, which is
    /// why `setField` builds a new run rather than storing in place.
    /// It lives as long as the run does: until `luce_rt_close`, or
    /// until the storage is dropped.  Empty for a struct with no
    /// fields.
    /// The field run this value holds, or the empty run when it holds
    /// none.
    ///
    /// **A value with no run reads as the empty run**, whichever of the
    /// two words says so.  `length` is zero for a struct with no fields;
    /// `bits` is zero for a slot that was never written, whose length
    /// may still be the one its *type* fixes — a function value's run is
    /// always two slots long, so its unwritten form is a null address
    /// with a length of two (docs/BINDING.md D12).  `dropStorage` has
    /// always read both words this way; reading them here is what makes
    /// every other walk agree with it.
    pub fn asStruct(self: Value) []Value {
        if (self.length == 0 or self.bits == 0) return &.{};
        const fields: [*]Value = @ptrFromInt(@as(usize, @intCast(self.bits)));
        return fields[0..@intCast(self.length)];
    }

    pub fn asObject(self: Value) Handle {
        return .{
            .index = @truncate(self.bits),
            .generation = @truncate(self.bits >> generation_shift),
        };
    }

    /// True when this is the absent value of a `T?`.  One tag test for
    /// every payload type: a present `long?` is tagged `int` and a
    /// present `List(T)?` is tagged `object`, so absence needs no
    /// per-type encoding and no second word (docs/FAILURE.md).  It is
    /// *not* the null object, which is a present handle to nothing.
    pub fn isNone(self: Value) bool {
        return self.tag == .none;
    }

    fn textOf(self: *const Value) []const u8 {
        if (self.inline_length != text_outside) {
            return self.inlineText()[0..self.inline_length];
        }
        if (self.length == 0) return "";
        const start: [*]const u8 = @ptrFromInt(@as(usize, @intCast(self.bits)));
        return start[0..@intCast(self.length)];
    }

    /// The whole inline run — `inline_head` and the two words after it,
    /// read as the one twenty-two byte field they physically are.
    fn inlineText(self: *const Value) *const [inline_capacity]u8 {
        return std.mem.asBytes(self)[inline_at..][0..inline_capacity];
    }

    fn inlineStorage(self: *Value) *[inline_capacity]u8 {
        return std.mem.asBytes(self)[inline_at..][0..inline_capacity];
    }

    // -- switching --------------------------------------------------------

    /// The same 24 bytes as a tagged union, for Zig callers that want to
    /// switch on the payload.  A pointer receiver for `asString`'s
    /// reason: a `.string` arm borrows the value's own bytes.
    pub fn view(self: *const Value) View {
        return switch (self.tag) {
            .none => .none,
            .boolean => .{ .boolean = self.asBoolean() },
            .byte => .{ .byte = self.asByte() },
            .short => .{ .short = self.asShort() },
            .int => .{ .int = self.asInt() },
            .long => .{ .long = self.asLong() },
            .half => .{ .half = self.asHalf() },
            .float => .{ .float = self.asFloat() },
            .double => .{ .double = self.asDouble() },
            .string => .{ .string = self.asString() },
            .strukt => .{ .strukt = self.asStruct() },
            .function => .{ .function = self.asStruct() },
            .object => .{ .object = self.asObject() },
        };
    }
};

/// A `Value` seen as a tagged union.  Construction goes through
/// `Value.of*`; this is only for reading.
pub const View = union(enum) {
    none,
    boolean: bool,
    byte: u8,
    short: i16,
    int: i32,
    long: i64,
    half: f16,
    float: f32,
    double: f64,
    string: []const u8,
    strukt: []Value,
    /// A function value's run: the same shape a struct's run has, and a
    /// separate arm because the objects inside one are **borrowed**, so
    /// every ownership walk stops here (`Tag.function`).
    function: []Value,
    object: Handle,
};

/// Map keys compare by content: the analyzer admits long and String
/// keys only.
pub fn keyEquals(left: *const Value, right: *const Value) bool {
    return switch (left.view()) {
        .long => |held| held == right.asLong(),
        .string => |held| std.mem.eql(u8, held, right.asString()),
        else => unreachable, // the analyzer keys maps by long or String
    };
}

test "the value layout is the one generated code assumes" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Value));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(Value));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Value, "tag"));
    try std.testing.expectEqual(@as(usize, 1), @offsetOf(Value, "inline_length"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Value, "bits"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(Value, "length"));

    // Inline text starts where the tag words end and runs to the end
    // of the slot: `inline_head` and both payload words, contiguous.
    try std.testing.expectEqual(inline_at, @offsetOf(Value, "inline_head"));
    try std.testing.expectEqual(@sizeOf(Value), inline_at + inline_capacity);
}

test "every payload survives a round trip" {
    try std.testing.expectEqual(@as(i64, -9), Value.ofLong(-9).asLong());
    try std.testing.expectEqual(@as(f64, 1.5), Value.ofDouble(1.5).asDouble());
    try std.testing.expect(Value.ofBoolean(true).asBoolean());
    try std.testing.expect(!Value.ofBoolean(false).asBoolean());
    const hi = Value.ofString("hi");
    try std.testing.expectEqualStrings("hi", hi.asString());
    const empty = Value.ofString("");
    try std.testing.expectEqualStrings("", empty.asString());

    var fields = [_]Value{ Value.ofLong(1), Value.ofString("two") };
    const held = Value.ofStruct(&fields);
    try std.testing.expectEqual(@as(usize, 2), held.asStruct().len);
    try std.testing.expectEqualStrings("two", held.asStruct()[1].asString());
}

test "text reads the same whichever form it is in" {
    // Every boundary the two forms meet at, and one well past it.
    const lengths = [_]usize{ 0, 1, inline_capacity - 1, inline_capacity, inline_capacity + 1, 100 };
    var words: [128]u8 = undefined;
    for (&words, 0..) |*byte, index| byte.* = @intCast('a' + index % 26);

    for (lengths) |length| {
        const wanted = words[0..length];
        const outside = Value.ofString(wanted);
        try std.testing.expect(!outside.textIsInline());
        try std.testing.expectEqualStrings(wanted, outside.asString());

        if (!Value.fitsInline(length)) continue;
        const held = Value.ofInlineText(.string, wanted);
        try std.testing.expect(held.textIsInline());
        try std.testing.expectEqualStrings(wanted, held.asString());
        // The bytes are the value: copying it copies them, and the
        // copy is not looking at the original.
        var copied = held;
        try std.testing.expectEqualStrings(wanted, copied.asString());
        if (length > 0) {
            try std.testing.expect(copied.asString().ptr != held.asString().ptr);
        }
        // Nothing to give back, on either engine's release path.
        try std.testing.expect(!held.ownsStorage());
        try std.testing.expect(keyEquals(&held, &outside));
    }
}

test "an inline value owns no allocation and an outside one does" {
    var words = "borrowed".*;
    try std.testing.expect(Value.ofString(&words).ownsStorage());
    try std.testing.expect(!Value.ofString("").ownsStorage());
    try std.testing.expect(!Value.ofInlineText(.string, "borrowed").ownsStorage());
    try std.testing.expect(!Value.ofLong(7).ownsStorage());
    try std.testing.expect(!Value.null_object.ownsStorage());
}

test "a handle keeps its row and its occupant apart" {
    const handle: Handle = .{ .index = 7, .generation = 3 };
    const held = Value.ofObject(handle);
    try std.testing.expectEqual(@as(u32, 7), held.asObject().index);
    try std.testing.expectEqual(@as(u32, 3), held.asObject().generation);
    try std.testing.expect(held.asObject().index != null_index);

    // Every corner of both halves survives, and neither reaches into
    // the other.
    const extreme: Handle = .{ .index = null_index - 1, .generation = std.math.maxInt(u32) };
    try std.testing.expect(extreme.same(Value.ofObject(extreme).asObject()));

    // Two occupants of one row are not the same object.
    try std.testing.expect(!handle.same(.{ .index = 7, .generation = 4 }));
    try std.testing.expect(!handle.same(.{ .index = 8, .generation = 3 }));
    try std.testing.expect(handle.same(.{ .index = 7, .generation = 3 }));

    // The null handle names no row, at no generation.
    try std.testing.expectEqual(null_index, Value.null_object.asObject().index);
    try std.testing.expectEqual(@as(u32, 0), Value.null_object.asObject().generation);
}

test "a view carries the same payload as the accessors" {
    switch (Value.ofDouble(-0.0).view()) {
        .double => |held| try std.testing.expect(std.math.signbit(held)),
        else => return error.WrongTag,
    }
    switch (Value.none.view()) {
        .none => {},
        else => return error.WrongTag,
    }
}
