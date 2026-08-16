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
//! Reading either form goes through `asStr`, which is why it takes
//! a pointer — the slice it answers for inline text points *into the
//! value*, so the value must be somewhere, not a temporary
//! (docs/STRINGS.md).
//!
//! What a value owns it owns exactly once: outside text and a struct's
//! field run are heap allocations with one owner, inline text is the
//! value itself and has nothing to free.  Heap objects are neither —
//! `object` carries a `Handle` into the runtime's object table, and
//! the table row, not the value, decides who frees it
//! (docs/MEMORY.md).
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
    i64 = 2,
    f64 = 3,
    str = 4,
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
    i32 = 7,
    f32 = 8,
    /// The three storage widths (docs/TYPES.md D5), appended in their
    /// turn.  No expression ever has one of these types — an operator
    /// widens them first — so a `Value` wears one only where storage
    /// does: an `array(byte, n)`'s zero, a boxed field, a boxed
    /// element crossing into a caller.
    u8 = 9,
    i16 = 10,
    f16 = 11,
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
    // Additional explicit integer widths append to the stable ABI.
    i8 = 13,
    u16 = 14,
    u32 = 15,
    u64 = 16,
    /// One Unicode scalar value in the low 32 bits.
    char = 17,
    /// Immutable binary data using the same inline/outside storage shape
    /// as text, but without a UTF-8 invariant.
    bytes = 18,
    /// A non-owning object handle. Weak values are storage machinery, not
    /// source-language values: a weak field/local holds this tag, while a
    /// read upgrades it to an owned `.object` or answers `.none` after the
    /// target dies. Appended so every earlier tag keeps its ABI value.
    weak = 19,
};

/// The index no object ever has.  The zero value of an object-typed
/// place is this handle, and using it traps `null_object` instead of
/// touching anything.
pub const null_index: u32 = std.math.maxInt(u32);

/// Where a handle's generation sits in `Value.bits`: above the index,
/// in the high 32 bits, which carried nothing before.  Published
/// because generated code takes the two halves apart itself
/// (`codegen/lower.zig`) and the two must not drift.
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
/// (docs/MEMORY.md) rather than silently naming the newcomer.
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

    pub fn ofI64(held: i64) Value {
        return .{ .tag = .i64, .bits = @bitCast(held) };
    }

    pub fn ofF64(held: f64) Value {
        return .{ .tag = .f64, .bits = @bitCast(held) };
    }

    /// The narrow widths.  Each sits in the low bits of the same
    /// word, sign- or zero-extended by the reader rather than stored
    /// wide, so a boxed value is the same twenty-four bytes whatever
    /// it holds and only its tag says how much of `bits` is the
    /// number (docs/TYPES.md §6).
    pub fn ofI32(held: i32) Value {
        return .{ .tag = .i32, .bits = @as(u32, @bitCast(held)) };
    }

    pub fn ofF32(held: f32) Value {
        return .{ .tag = .f32, .bits = @as(u32, @bitCast(held)) };
    }

    /// The storage widths.  A `byte` is the one whose bits are read
    /// back as a magnitude (D4); a `short` sign-extends, and a `half`
    /// keeps its sixteen binary16 bits and is widened by whoever
    /// reads it.
    pub fn ofU8(held: u8) Value {
        return .{ .tag = .u8, .bits = held };
    }

    pub fn ofI16(held: i16) Value {
        return .{ .tag = .i16, .bits = @as(u16, @bitCast(held)) };
    }

    pub fn ofF16(held: f16) Value {
        return .{ .tag = .f16, .bits = @as(u16, @bitCast(held)) };
    }

    pub fn ofI8(held: i8) Value {
        return .{ .tag = .i8, .bits = @as(u8, @bitCast(held)) };
    }

    pub fn ofU16(held: u16) Value {
        return .{ .tag = .u16, .bits = held };
    }

    pub fn ofU32(held: u32) Value {
        return .{ .tag = .u32, .bits = held };
    }

    pub fn ofU64(held: u64) Value {
        return .{ .tag = .u64, .bits = held };
    }

    pub fn ofChar(held: u32) Value {
        return .{ .tag = .char, .bits = held };
    }

    /// Text that lives somewhere else — a program constant, an owned
    /// allocation, a borrow of either.  This is the form every *view*
    /// takes, because a view must not copy.
    pub fn ofStr(held: []const u8) Value {
        return ofOutside(.str, held);
    }

    pub fn ofBytes(held: []const u8) Value {
        return ofOutside(.bytes, held);
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

    /// A non-owning handle stored behind the `weak` modifier. It has the
    /// same payload bits as an object handle but never contributes to the
    /// object's strong count.
    pub fn ofWeak(handle: Handle) Value {
        return .{
            .tag = .weak,
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

    pub fn asI64(self: Value) i64 {
        return @bitCast(self.bits);
    }

    pub fn asF64(self: Value) f64 {
        return @bitCast(self.bits);
    }

    pub fn asI32(self: Value) i32 {
        return @bitCast(@as(u32, @truncate(self.bits)));
    }

    pub fn asF32(self: Value) f32 {
        return @bitCast(@as(u32, @truncate(self.bits)));
    }

    pub fn asU8(self: Value) u8 {
        return @truncate(self.bits);
    }

    pub fn asI16(self: Value) i16 {
        return @bitCast(@as(u16, @truncate(self.bits)));
    }

    pub fn asF16(self: Value) f16 {
        return @bitCast(@as(u16, @truncate(self.bits)));
    }

    pub fn asI8(self: Value) i8 {
        return @bitCast(@as(u8, @truncate(self.bits)));
    }

    pub fn asU16(self: Value) u16 {
        return @truncate(self.bits);
    }

    pub fn asU32(self: Value) u32 {
        return @truncate(self.bits);
    }

    pub fn asU64(self: Value) u64 {
        return self.bits;
    }

    pub fn asChar(self: Value) u32 {
        return @truncate(self.bits);
    }

    /// The text this value holds.
    ///
    /// **The receiver is a pointer on purpose.**  Inline text lives in
    /// the value, so the slice points into `self` and is good for
    /// exactly as long as `self` stays put — take it from a slot, a
    /// cell or a named local, never from a temporary, and never keep it
    /// across anything that could move or overwrite that place
    /// (docs/STRINGS.md).
    pub fn asStr(self: *const Value) []const u8 {
        return self.textOf();
    }

    pub fn asBytes(self: *const Value) []const u8 {
        return self.textOf();
    }

    /// The tag byte after crossing an untrusted ABI boundary.  Reading an
    /// invalid value through the enum field is already undefined in Zig, so
    /// validators inspect the byte representation before they let any switch
    /// or comparison see a `Tag`.
    fn validTag(self: *const Value) ?Tag {
        const raw = std.mem.asBytes(self)[@offsetOf(Value, "tag")];
        return std.enums.fromInt(Tag, raw);
    }

    /// Whether the String representation can be read without leaving the
    /// value's declared storage.  The tag is not enough at the C/MIR seam:
    /// an invalid inline length would slice past the value, and a non-empty
    /// outside String with a null pointer would turn a borrowed payload into
    /// a native memory fault.
    pub fn hasValidStringRepresentation(self: Value) bool {
        const tag = self.validTag() orelse return false;
        if (tag != .str) return false;
        // This is a representation check at an untrusted ABI boundary,
        // not a content walk.  An outside pointer can be proved non-null,
        // non-wrapping, and correctly shaped here; it cannot be safely
        // dereferenced merely because foreign code supplied an address.
        // Luce's constructors and parsers establish the UTF-8 invariant
        // when text enters the runtime.
        return self.hasValidInlineOrOutsideBytes();
    }

    pub fn hasValidBytesRepresentation(self: Value) bool {
        const tag = self.validTag() orelse return false;
        if (tag != .bytes) return false;
        return self.hasValidInlineOrOutsideBytes();
    }

    fn hasValidInlineOrOutsideBytes(self: Value) bool {
        if (self.inline_length == text_outside) {
            return self.hasValidByteRun();
        }
        return self.inline_length <= inline_capacity;
    }

    fn hasValidByteRun(self: Value) bool {
        const length = std.math.cast(usize, self.length) orelse return false;
        if (length == 0) return true;
        const address = std.math.cast(usize, self.bits) orelse return false;
        if (address == 0) return false;
        _ = std.math.add(usize, address, length) catch return false;
        return true;
    }

    /// Whether a value's tagged storage can be walked without turning a
    /// malformed C/MIR payload into a native pointer fault.  A struct run
    /// may have any length, while a function run is always the two slots
    /// described by the function-value ABI.  This proves representation
    /// shape, not that an arbitrary outside pointer names allocated memory;
    /// ownership boundaries still reject the impossible null, alignment,
    /// and overflow cases before any walk.
    pub fn hasValidRepresentation(self: Value) bool {
        const tag = self.validTag() orelse return false;
        return switch (tag) {
            .str => self.hasValidStringRepresentation(),
            .bytes => self.hasValidBytesRepresentation(),
            .strukt => self.hasValidFieldRun(),
            // An unwritten function slot is a valid null function: its
            // ABI shape is still the two-slot run, but there is no
            // backing allocation until a function is stored.  Readers
            // reject the null name as an absent callable; ownership
            // walks must still be able to carry and release the slot.
            .function => self.length == 2 and
                (self.bits == 0 or self.hasValidFieldRun()),
            else => true,
        };
    }

    fn hasValidFieldRun(self: Value) bool {
        const length = std.math.cast(usize, self.length) orelse return false;
        if (length == 0) return true;
        const address = std.math.cast(usize, self.bits) orelse return false;
        if (address == 0 or address % @alignOf(Value) != 0) return false;
        const bytes = std.math.mul(usize, length, @sizeOf(Value)) catch return false;
        _ = std.math.add(usize, address, bytes) catch return false;
        return true;
    }

    /// True when the text is in the value rather than behind `bits`.
    pub fn textIsInline(self: Value) bool {
        return self.inline_length != text_outside;
    }

    /// True when this value holds a heap allocation of its own — the
    /// question `dropStorage` and `ownValue` both turn on.  Inline
    /// text answers false: the bytes are the value.
    pub fn ownsStorage(self: Value) bool {
        const tag = self.validTag() orelse return false;
        return switch (tag) {
            .str, .bytes => !self.textIsInline() and self.bits != 0 and self.length != 0,
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

    pub fn asWeak(self: Value) Handle {
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
    /// switch on the payload.  A pointer receiver for `asStr`'s
    /// reason: a `.str` arm borrows the value's own bytes.
    pub fn view(self: *const Value) View {
        return switch (self.tag) {
            .none => .none,
            .boolean => .{ .boolean = self.asBoolean() },
            .u8 => .{ .u8 = self.asU8() },
            .u16 => .{ .u16 = self.asU16() },
            .u32 => .{ .u32 = self.asU32() },
            .u64 => .{ .u64 = self.asU64() },
            .i8 => .{ .i8 = self.asI8() },
            .i16 => .{ .i16 = self.asI16() },
            .i32 => .{ .i32 = self.asI32() },
            .i64 => .{ .i64 = self.asI64() },
            .f16 => .{ .f16 = self.asF16() },
            .f32 => .{ .f32 = self.asF32() },
            .f64 => .{ .f64 = self.asF64() },
            .char => .{ .char = self.asChar() },
            .str => .{ .str = self.asStr() },
            .bytes => .{ .bytes = self.asBytes() },
            .strukt => .{ .strukt = self.asStruct() },
            .function => .{ .function = self.asStruct() },
            .object => .{ .object = self.asObject() },
            .weak => .{ .weak = self.asWeak() },
        };
    }
};

/// A `Value` seen as a tagged union.  Construction goes through
/// `Value.of*`; this is only for reading.
pub const View = union(enum) {
    none,
    boolean: bool,
    u8: u8,
    u16: u16,
    u32: u32,
    u64: u64,
    i8: i8,
    i16: i16,
    i32: i32,
    i64: i64,
    f16: f16,
    f32: f32,
    f64: f64,
    char: u32,
    str: []const u8,
    bytes: []const u8,
    strukt: []Value,
    /// A function value's run: the same shape a struct's run has, and a
    /// separate arm because the objects inside one are **borrowed**, so
    /// every ownership walk stops here (`Tag.function`).
    function: []Value,
    object: Handle,
    /// A non-owning object handle. It is visible only to runtime storage
    /// machinery; ordinary expression registers contain an upgraded object
    /// or `none`, never this arm.
    weak: Handle,
};

/// Map keys compare by content. Integer keys retain their exact width,
/// enum keys use their exact backing width, and text compares by bytes.
pub fn keyEquals(left: *const Value, right: *const Value) bool {
    const left_tag = left.validTag() orelse return false;
    const right_tag = right.validTag() orelse return false;
    if (left_tag != right_tag) return false;
    return switch (left_tag) {
        .u8 => left.asU8() == right.asU8(),
        .u16 => left.asU16() == right.asU16(),
        .u32 => left.asU32() == right.asU32(),
        .u64 => left.asU64() == right.asU64(),
        .i8 => left.asI8() == right.asI8(),
        .i16 => left.asI16() == right.asI16(),
        .i32 => left.asI32() == right.asI32(),
        .i64 => left.asI64() == right.asI64(),
        .char => left.asChar() == right.asChar(),
        .str => if (left.hasValidStringRepresentation() and right.hasValidStringRepresentation())
            std.mem.eql(u8, left.asStr(), right.asStr())
        else
            false,
        .bytes => if (left.hasValidBytesRepresentation() and right.hasValidBytesRepresentation())
            std.mem.eql(u8, left.asBytes(), right.asBytes())
        else
            false,
        else => false,
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

test "an unknown ABI tag is invalid data, not a native enum panic" {
    var held = Value.none;
    std.mem.asBytes(&held)[@offsetOf(Value, "tag")] = 0xff;
    try std.testing.expect(!held.hasValidRepresentation());
    try std.testing.expect(!held.hasValidStringRepresentation());
    try std.testing.expect(!held.ownsStorage());
    try std.testing.expect(!keyEquals(&held, &held));
}

test "every payload survives a round trip" {
    try std.testing.expectEqual(@as(i64, -9), Value.ofI64(-9).asI64());
    try std.testing.expectEqual(@as(f64, 1.5), Value.ofF64(1.5).asF64());
    try std.testing.expect(Value.ofBoolean(true).asBoolean());
    try std.testing.expect(!Value.ofBoolean(false).asBoolean());
    const hi = Value.ofStr("hi");
    try std.testing.expectEqualStrings("hi", hi.asStr());
    const empty = Value.ofStr("");
    try std.testing.expectEqualStrings("", empty.asStr());

    var fields = [_]Value{ Value.ofI64(1), Value.ofStr("two") };
    const held = Value.ofStruct(&fields);
    try std.testing.expectEqual(@as(usize, 2), held.asStruct().len);
    try std.testing.expectEqualStrings("two", held.asStruct()[1].asStr());
}

test "text reads the same whichever form it is in" {
    // Every boundary the two forms meet at, and one well past it.
    const lengths = [_]usize{ 0, 1, inline_capacity - 1, inline_capacity, inline_capacity + 1, 100 };
    var words: [128]u8 = undefined;
    for (&words, 0..) |*byte, index| byte.* = @intCast('a' + index % 26);

    for (lengths) |length| {
        const wanted = words[0..length];
        const outside = Value.ofStr(wanted);
        try std.testing.expect(!outside.textIsInline());
        try std.testing.expectEqualStrings(wanted, outside.asStr());

        if (!Value.fitsInline(length)) continue;
        const held = Value.ofInlineText(.str, wanted);
        try std.testing.expect(held.textIsInline());
        try std.testing.expectEqualStrings(wanted, held.asStr());
        // The bytes are the value: copying it copies them, and the
        // copy is not looking at the original.
        var copied = held;
        try std.testing.expectEqualStrings(wanted, copied.asStr());
        if (length > 0) {
            try std.testing.expect(copied.asStr().ptr != held.asStr().ptr);
        }
        // Nothing to give back, on either engine's release path.
        try std.testing.expect(!held.ownsStorage());
        try std.testing.expect(keyEquals(&held, &outside));
    }
}

test "an inline value owns no allocation and an outside one does" {
    var words = "borrowed".*;
    try std.testing.expect(Value.ofStr(&words).ownsStorage());
    try std.testing.expect(!Value.ofStr("").ownsStorage());
    try std.testing.expect(!Value.ofInlineText(.str, "borrowed").ownsStorage());
    try std.testing.expect(!Value.ofI64(7).ownsStorage());
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
    switch (Value.ofF64(-0.0).view()) {
        .f64 => |held| try std.testing.expect(std.math.signbit(held)),
        else => return error.WrongTag,
    }
    switch (Value.none.view()) {
        .none => {},
        else => return error.WrongTag,
    }
}
