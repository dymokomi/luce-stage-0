//! The Luce type system's vocabulary: what a type is, what a heap
//! object's shape is, what a struct's layout is, and how any of them
//! is written down for a person.
//!
//! Nothing about any backend appears here — this is the only type
//! language the checker and the IR both speak.

const std = @import("std");

/// Host-controlled compile options.  A program is a script: `main`
/// takes either no parameter or one `list[str]` argument parameter,
/// and either shape may declare `-> !` — the four legal entries.
/// `allow_host` grants the host builtins (console, files and terminal)
/// and is the only authority gate left.  Command-line arguments are
/// handed to `main`; they are not a callable service.
pub const CompileOptions = struct {
    allow_host: bool = false,
    /// Display name for the root module in debug info ("dice.luc") —
    /// what a runtime trap location reports.  "" falls back to
    /// "main.luc".  Imported modules always report "PREFIX.luc".
    source_name: []const u8 = "",
    /// Opaque host root token for the root module (docs/PACKAGES.md
    /// D7): whatever the host's loader answers as `Found.Text.root`
    /// for files of the same project, so the module registry's
    /// (root, name) keys agree end to end.  The compiler never
    /// interprets it.  "" is the rootless program.
    source_root: []const u8 = "",
    /// Stage 7, the whole of it (`optimize`): on for every artifact;
    /// `luce ir --full` clears it to show the raw lowering, unreached
    /// functions and all.  The name is older than the stage — it was
    /// one pass, dead-code elimination, when the flag was added.
    prune: bool = true,
    /// Where the entry comes from (`semantics/entry.zig`).
    entry: Entry = .declared,
};

/// Which function the runtime starts, and who wrote it.
///
/// There is one entry *mode* and there are four entry *shapes*; this
/// says only whether the source declared the one being used or the
/// compiler did.  Either way what comes out is a single row of the
/// function table, started through the published ABI.
pub const Entry = union(enum) {
    /// The ordinary program: `func main` in the root module, in one of
    /// the four shapes.
    declared,
    /// `luce test` (docs/TESTING.md D3): the root module's tests are
    /// the program, and the compiler writes the fourth shape —
    /// `func main(args: list[str]) -> !` — which reads one name out
    /// of `args` and calls that test by direct call.  The names are
    /// the runner's discovery, in declaration order; this stage
    /// re-derives none of it and lets an unknown one refuse itself as
    /// an ordinary unresolved call.  A `main` the source declares is
    /// left as an ordinary function nothing reaches.
    tests: []const []const u8,
};

// ---------------------------------------------------------------------------
// Type
// ---------------------------------------------------------------------------

/// A Luce type: a scalar, a structure (by index into the program's
/// layout table), a heap object shape (by index into the program's
/// heap type table), an optional `T?`, or none (the absence of a
/// value).  Heap type indexes are interned by the analyzer, so equal
/// shapes share one index and equality is an index comparison.
pub const Type = union(enum) {
    none,
    boolean,
    /// Fixed-width numbers. Every integer is a checked arithmetic type;
    /// no width is merely storage and no operator silently promotes it.
    u8,
    u16,
    u32,
    u64,
    i8,
    i16,
    i32,
    i64,
    f16,
    f32,
    f64,
    /// One Unicode scalar value, stored as a 32-bit code point.
    char,
    /// Immutable, valid UTF-8 text.
    str,
    /// Immutable binary data with no text invariant.
    bytes,
    strukt: u32,
    heap: u32,
    /// A set of named constants at one integer width (docs/ENUMS.md).
    /// The index reaches the program's enum table — the type's name and
    /// its members — and the width travels beside it, for the reason
    /// `EnumRef` gives.
    enumeration: EnumRef,
    /// A tagged union — the language keyword is `union`, and inside the
    /// compiler the word is `variant`, because Zig's own `union` takes
    /// the name in the one place it must not be dodged around: this arm
    /// (docs/UNION.md D18).  The index reaches the program's variant
    /// table, beside `strukt` and `heap`, which are the other types
    /// that index one.
    variant: u32,
    /// `func(T, ...) -> R` — a **function value** (docs/FUNCTIONS.md).
    /// The index reaches the program's signature table, interned the
    /// way heap shapes are, so two identically written function types
    /// share one index and equality is an index comparison.
    ///
    /// **Underneath it is a pair**: the index of the function it names
    /// in the program's function table, and the receiver it travels
    /// with — empty for a plain function value and a lambda, a whole
    /// value for a bound method (docs/BINDING.md D12).  Both engines
    /// carry the pair as a two-slot field run, which is why `boxTag`
    /// answers `.strukt` for one and why `libluce_rt` still learns
    /// nothing: to the runtime it is a run of two values, and only the
    /// type table knows which signature the pair may be called at.
    ///
    /// **The receiver's type is not in this type**, on purpose: one
    /// `func(Point, Point) -> bool` place accepts a plain function, a
    /// lambda, and a bind of any receiver whose method has that shape.
    /// What a value carries is therefore a property of the value, not
    /// of its type, and the run is self-describing so no reader needs
    /// the type to walk one.
    function: u32,
    /// `T?` — a `T` that may be absent (docs/FAILURE.md).  `?` means
    /// nullable and only nullable; it never carries a reason.
    optional: Payload,

    /// Which enum, and how wide its members are stored (docs/ENUMS.md
    /// D2, D10).
    ///
    /// **The width travels in the type on purpose.**  Every other
    /// question a machine asks of an enum — what a register holds, what
    /// tag it boxes with, how wide an array cell is, whether a constant
    /// fits — is a question about the backing integer and nothing else,
    /// and a `Type` that could not answer it would make each of those
    /// sites take the enum table to learn one of four words.  It is the
    /// same choice `optional` makes with its payload.  The *name* still
    /// lives in the table, because a name is not a machine fact.
    ///
    /// Two `EnumRef`s with one index always carry one width: `index` is
    /// the identity and the width follows it, which is why `eql` reads
    /// only the index and why stage 4 builds these in exactly one
    /// place.
    pub const EnumRef = struct {
        index: u32,
        backing: Backing,

        /// The eight integer widths an enum may use as its backing.
        pub const Backing = enum {
            u8,
            u16,
            u32,
            u64,
            i8,
            i16,
            i32,
            i64,

            pub fn asType(self: Backing) Type {
                return switch (self) {
                    inline else => |tag| @unionInit(Type, @tagName(tag), {}),
                };
            }

            /// The integer width a written type names.
            pub fn of(written: Type) ?Backing {
                return switch (written) {
                    .u8 => .u8,
                    .u16 => .u16,
                    .u32 => .u32,
                    .u64 => .u64,
                    .i8 => .i8,
                    .i16 => .i16,
                    .i32 => .i32,
                    .i64 => .i64,
                    else => null,
                };
            }
        };
    };

    /// What a `T?` may hold.  A union of its own rather than a
    /// `*Type`, so `T??` and an optional no-result type are
    /// *unrepresentable* rather than merely refused: there is one level
    /// of absence and no way to
    /// write a second.
    pub const Payload = union(enum) {
        boolean,
        u8,
        u16,
        u32,
        u64,
        i8,
        i16,
        i32,
        i64,
        f16,
        f32,
        f64,
        char,
        str,
        bytes,
        strukt: u32,
        heap: u32,
        enumeration: EnumRef,
        /// `Shape?` — the one absence a recursive union terminates at
        /// that is not a container (docs/UNION.md D14).
        variant: u32,
        /// `(func(T, ...) -> R)?` — **the storable form of a function
        /// value** (docs/BINDING.md D7).
        ///
        /// A bare `func` type stands where a value is always present:
        /// a parameter, a `let`, or a custom-initialized class field.
        /// A memberwise aggregate field and a container element are slots
        /// that exist before anything fills them, and a function value has
        /// no zero — every value of the type names a function, and an empty
        /// slot names none. So those positions use the optional, whose zero
        /// is the absence `T?` already means. (A map value is installed with
        /// its key and uses the bare type.)
        ///
        /// The written spelling needs its parentheses: `func(i64) ->
        /// str?` is a function *answering* an optional, because a
        /// result type consumes its own `?` first.
        function: u32,

        pub fn asType(self: Payload) Type {
            return switch (self) {
                .boolean => .boolean,
                .u8 => .u8,
                .u16 => .u16,
                .u32 => .u32,
                .u64 => .u64,
                .i8 => .i8,
                .i16 => .i16,
                .i32 => .i32,
                .i64 => .i64,
                .f16 => .f16,
                .f32 => .f32,
                .f64 => .f64,
                .char => .char,
                .str => .str,
                .bytes => .bytes,
                .strukt => |index| .{ .strukt = index },
                .heap => |index| .{ .heap = index },
                .enumeration => |reference| .{ .enumeration = reference },
                .variant => |index| .{ .variant = index },
                .function => |index| .{ .function = index },
            };
        }

        pub fn eql(self: Payload, other: Payload) bool {
            return switch (self) {
                .strukt => |index| other == .strukt and other.strukt == index,
                .heap => |index| other == .heap and other.heap == index,
                .enumeration => |reference| other == .enumeration and
                    other.enumeration.index == reference.index,
                .variant => |index| other == .variant and other.variant == index,
                .function => |index| other == .function and other.function == index,
                else => std.meta.activeTag(self) == std.meta.activeTag(other),
            };
        }
    };

    pub fn eql(self: Type, other: Type) bool {
        return switch (self) {
            .strukt => |index| other == .strukt and other.strukt == index,
            .heap => |index| other == .heap and other.heap == index,
            .enumeration => |reference| other == .enumeration and
                other.enumeration.index == reference.index,
            .variant => |index| other == .variant and other.variant == index,
            .function => |index| other == .function and other.function == index,
            .optional => |payload| other == .optional and payload.eql(other.optional),
            else => std.meta.activeTag(self) == std.meta.activeTag(other),
        };
    }

    /// The type a value of this one is **stored and computed as** by a
    /// machine: an enum is its backing integer, and everything else is
    /// itself (docs/ENUMS.md D10).
    ///
    /// Every engine-side switch over a type starts here, which is what
    /// keeps "an enum is its number underneath" one sentence rather
    /// than an arm in thirty switches — and what lets those switches
    /// answer `.enumeration` with `unreachable, // answered above`
    /// honestly.  Nothing in stage 4 may use it to *type* an
    /// expression: an enum is not an integer to a program, and the two
    /// convert only where somebody wrote `i32(m)`.
    pub fn storage(self: Type) Type {
        return switch (self) {
            .enumeration => |reference| reference.backing.asType(),
            // **A variant answers with itself, never as a `.strukt`
            // with a different index** (docs/UNION.md D8): a variant
            // index names a row of `Program.variants` and a struct
            // index a row of `Program.structs`, and a switch that was
            // handed the wrong table would read the wrong shape.  The
            // engines answer `.variant` beside `.strukt`, arm by arm.
            else => self,
        };
    }

    pub fn isNumeric(self: Type) bool {
        return self.isInteger() or self.isFloating();
    }

    /// The integers, and nothing else — `bool` is never numeric.
    pub fn isInteger(self: Type) bool {
        return switch (self) {
            .u8, .u16, .u32, .u64, .i8, .i16, .i32, .i64 => true,
            else => false,
        };
    }

    pub fn isFloating(self: Type) bool {
        return self == .f16 or self == .f32 or self == .f64;
    }

    pub fn isUnsigned(self: Type) bool {
        return self == .u8 or self == .u16 or self == .u32 or self == .u64;
    }

    /// How wide a numeric type is, in bits.  Asked only of one:
    /// callers test `isNumeric` first, and a non-numeric answering
    /// zero would let a caller compute with the answer instead of
    /// being stopped by it.
    pub fn numericBits(self: Type) u16 {
        return switch (self) {
            .u8, .i8 => 8,
            .u16, .i16, .f16 => 16,
            .u32, .i32, .f32 => 32,
            .u64, .i64, .f64 => 64,
            .none, .boolean, .char, .str, .bytes, .strukt, .heap, .enumeration, .variant, .function, .optional => 0,
        };
    }

    /// The closed range an integer type holds, as the one statement of
    /// it in the tree. Carried at `i128` because `i64`'s bounds are
    /// its own extremes and comparing them to another type's must not
    /// itself overflow.
    ///
    /// Asked only of an integer; the caller has tested `isInteger`.
    pub fn integerRange(self: Type) struct { low: i128, high: i128 } {
        return switch (self) {
            .u8 => .{ .low = 0, .high = std.math.maxInt(u8) },
            .u16 => .{ .low = 0, .high = std.math.maxInt(u16) },
            .u32 => .{ .low = 0, .high = std.math.maxInt(u32) },
            .u64 => .{ .low = 0, .high = std.math.maxInt(u64) },
            .i8 => .{ .low = std.math.minInt(i8), .high = std.math.maxInt(i8) },
            .i16 => .{ .low = std.math.minInt(i16), .high = std.math.maxInt(i16) },
            .i32 => .{ .low = std.math.minInt(i32), .high = std.math.maxInt(i32) },
            .i64 => .{ .low = std.math.minInt(i64), .high = std.math.maxInt(i64) },
            .none, .boolean, .f16, .f32, .f64, .char, .str, .bytes, .strukt, .heap, .enumeration, .variant, .function, .optional => unreachable,
        };
    }

    /// The type two numeric operands meet at, or null when either is
    /// not a number.
    ///
    /// Concrete numeric operands meet only when their types already
    /// match. A literal is contextualized before this question is asked.
    pub fn unified(left: Type, right: Type) ?Type {
        if (!left.isNumeric() or !right.isNumeric()) return null;
        return if (left.eql(right)) left else null;
    }

    /// Whether the conversion `to(x)` can stop the program.
    ///
    /// Two of the four families of pair can, and for the same reason:
    /// the answer may have no representation at all in the
    /// destination, and Luce refuses to invent one (docs/TYPES.md §3).
    ///
    ///   * **float to integer** traps `conversion_range` outside the
    ///     target, NaN and the infinities included — at every width,
    ///     because truncation can land outside any destination width.
    ///   * **integer to a narrower integer** traps `conversion_range`
    ///     outside the target: `i32(3000000000)` is not 3 billion
    ///     modulo anything, it is a program that stops.
    ///
    /// The other two never do.  Integer to float rounds to nearest and
    /// always has an answer; float to float rounds to nearest, ties to
    /// even, and reaches `inf` rather than trapping, because `/` is
    /// already IEEE without traps and the language should not acquire
    /// a second story about infinity.
    ///
    /// Asked only of a legal conversion: both ends numeric, and not
    /// the same type.
    pub fn conversionTraps(from: Type, to: Type) bool {
        // `char(integer)` is checked against the Unicode scalar set,
        // whose surrogate-shaped hole means no integer width can make
        // the conversion total.  The one way back, `u32(char)`, is the
        // scalar's representation and cannot fail.
        if (to == .char) {
            std.debug.assert(from.isInteger());
            return true;
        }
        if (from == .char) {
            std.debug.assert(to == .u32);
            return false;
        }
        std.debug.assert(from.isNumeric() and to.isNumeric());
        if (from.isFloating()) return to.isInteger();
        if (to.isFloating()) return false;
        // Integer to integer: it traps exactly when the destination
        // cannot hold every value the source can. Comparing ranges rather
        // than widths handles signedness correctly: `i16(u8_value)` is
        // total, while `u8(i16_value)` can fail even though both names state
        // their representation explicitly.
        const source = from.integerRange();
        const target = to.integerRange();
        return target.low > source.low or target.high < source.high;
    }

    /// `T` written as `T?`, or null when there is no such type: a
    /// no-result type has no value to be absent, and `T??` does not exist.
    pub fn optionalOf(base: Type) ?Type {
        return switch (base) {
            .none, .optional => null,
            // `(func(...) -> R)?` — the storable form of a function
            // value (docs/BINDING.md D7).  The parentheses are the
            // written spelling's business; here it is one more payload.
            .function => |index| .{ .optional = .{ .function = index } },
            .boolean => .{ .optional = .boolean },
            .u8 => .{ .optional = .u8 },
            .u16 => .{ .optional = .u16 },
            .u32 => .{ .optional = .u32 },
            .u64 => .{ .optional = .u64 },
            .i8 => .{ .optional = .i8 },
            .i16 => .{ .optional = .i16 },
            .i32 => .{ .optional = .i32 },
            .i64 => .{ .optional = .i64 },
            .f16 => .{ .optional = .f16 },
            .f32 => .{ .optional = .f32 },
            .f64 => .{ .optional = .f64 },
            .char => .{ .optional = .char },
            .str => .{ .optional = .str },
            .bytes => .{ .optional = .bytes },
            .strukt => |index| .{ .optional = .{ .strukt = index } },
            .heap => |index| .{ .optional = .{ .heap = index } },
            // `Shape?` is D14's converse: the cheap half of keeping
            // `T?` its own mechanism, and what gives a recursive union
            // a terminator that is not a container (docs/UNION.md).
            .variant => |index| .{ .optional = .{ .variant = index } },
            // `Method?` is what `Method(n)` answers, so this is the one
            // optional the language makes without anybody writing `?`
            // (docs/ENUMS.md R2).
            .enumeration => |reference| .{ .optional = .{ .enumeration = reference } },
        };
    }

    /// The `T` inside a `T?`, or null when this is not an optional.
    pub fn held(self: Type) ?Type {
        return switch (self) {
            .optional => |payload| payload.asType(),
            else => null,
        };
    }
};

/// The shape of one heap-backed type: a container's element/key/rank,
/// or the state a reference-counted file/task resource carries.
/// Resources use the object table for identity, a strong count, and a
/// last-release death point; they are not containers.
pub const HeapType = union(enum) {
    list: Type,
    map: struct { key: Type, value: Type },
    array: struct { element: Type, rank: u8 },
    builder,
    /// An open file (docs/BYTES.md R5).  A heap type and not a scalar
    /// because a file is a **resource**. References share its handle,
    /// and the last strong release closes it; a stale handle traps
    /// rather than becoming undefined access. It carries no element type — a file is not a
    /// container — so the shape is the whole of it, and
    /// `std.network`'s sockets are meant to arrive beside it wearing
    /// the same pattern.
    file,
    /// A running worker (docs/THREADS.md D3).  The `file` precedent
    /// exactly: a resource, not a container, whose last-release death
    /// point is a **join**. Structured cleanup follows from the same ARC
    /// rule instead of being a discipline laid on top.
    ///
    /// `result` is what `f` answers, `.none` when it answers nothing.
    /// `fallible` is `f`'s own attribute travelling with the call it
    /// carries, exactly as `Function.fallible` sits beside
    /// `Function.return_type` — a task is a call in flight, and a call
    /// carries its function's attributes.  This does **not** make `T!`
    /// a type (docs/FAILURE.md): `types.Type` is untouched, and what
    /// the flag decides is only whether `t.wait()` is a site that has
    /// to say `try` or `catch`.  It is part of the shape because two
    /// tasks that differ in it are two different obligations, and a
    /// `list[task[f64]]` may not hold both.
    task: struct { result: Type, fallible: bool },
    /// One instance of a nominal `class` layout. Unlike a value struct,
    /// copying this type copies one object handle and therefore shares
    /// identity. Appended so every existing serialized heap-shape tag keeps
    /// its meaning.
    class: u32,

    pub fn eql(self: HeapType, other: HeapType) bool {
        return switch (self) {
            .class => |layout| other == .class and other.class == layout,
            .list => |element| other == .list and element.eql(other.list),
            .map => |pair| other == .map and
                pair.key.eql(other.map.key) and pair.value.eql(other.map.value),
            .array => |shape| other == .array and
                shape.element.eql(other.array.element) and shape.rank == other.array.rank,
            .builder => other == .builder,
            .file => other == .file,
            .task => |work| other == .task and
                work.result.eql(other.task.result) and work.fallible == other.task.fallible,
        };
    }
};

/// The shape of one function type: what it takes and what it answers
/// (docs/FUNCTIONS.md S2).
///
/// **Parameter types, and no names**, because a name is documentation of
/// a declaration and a type is not a declaration.
///
/// A function type carries no `!`: there is no spelling for one in this
/// run, so a fallible function is refused where a value is wanted
/// rather than silently losing its obligation (docs/FUNCTIONS.md, As
/// built).
pub const Signature = struct {
    parameters: []Parameter,
    /// What a call through this type answers; `.none` for a function
    /// that answers nothing.  A return *shape* is not a type, so a
    /// multi-valued function is not a function value either.
    result: Type,

    pub const Parameter = struct {
        value_type: Type,
    };

    pub fn eql(self: Signature, other: Signature) bool {
        if (self.parameters.len != other.parameters.len) return false;
        if (!self.result.eql(other.result)) return false;
        for (self.parameters, other.parameters) |mine, theirs| {
            if (!mine.value_type.eql(theirs.value_type)) return false;
        }
        return true;
    }
};

/// One member of an enum, as the program carries it: the name
/// `str(m)` answers and the explicit backing conversion answers (docs/ENUMS.md
/// D1, D5).
pub const EnumMember = struct {
    name: []const u8, // arena-owned by the program
    value: i128,
};

/// One declared enum: its name, the width its members are stored at,
/// and the members in declaration order.
///
/// **The order is the declaration's**, and two things read it: the
/// first member is the type's zero — what `var m: Method` starts at and
/// what an `array[Method, _]` is filled with—and `match`'s
/// exhaustiveness names a missing member by walking it, so a reader is
/// told about members in the order they wrote them.
pub const EnumType = struct {
    name: []const u8, // arena-owned by the program
    backing: Type.EnumRef.Backing,
    members: []EnumMember,

    pub fn findMember(self: EnumType, name: []const u8) ?u32 {
        for (self.members, 0..) |member, index| {
            if (std.mem.eql(u8, member.name, name)) return @intCast(index);
        }
        return null;
    }

    /// The member holding `value`, or null when no member does — which
    /// is exactly the question `Method(n)` asks (R2).
    pub fn memberOfValue(self: EnumType, value: i128) ?u32 {
        for (self.members, 0..) |member, index| {
            if (member.value == value) return @intCast(index);
        }
        return null;
    }
};

pub const StructField = struct {
    name: []const u8, // arena-owned by the program
    /// Zeroing non-owning storage. `field_type` remains the logical `T?`
    /// seen by source and expression registers; only the field cell carries
    /// the runtime's internal weak-handle tag.
    weak: bool = false,
    field_type: Type,
};

/// One callable requirement of an interface.  Requirements are metadata,
/// not fields in the existential value: every interface value has the same
/// two-slot representation (witness identity, owned payload), while this
/// table describes how calls through that value are checked and dispatched.
pub const InterfaceMethod = struct {
    name: []const u8, // arena-owned by the program
    signature: u32,
    mutating: bool = false,
    fallible: bool = false,
};

/// One member of a union, as the program carries it: the name an arm
/// and `str(u)` answer, and the payload fields in declaration order
/// (docs/UNION.md D1).  A bare member has no fields; the fields reuse
/// the struct field shape because that is what they are — a payload is
/// a field run whose slot 0 is the tag (D8).
pub const VariantMember = struct {
    name: []const u8, // arena-owned by the program
    fields: []StructField,

    pub fn findField(self: VariantMember, name: []const u8) ?u32 {
        for (self.fields, 0..) |field, index| {
            if (std.mem.eql(u8, field.name, name)) return @intCast(index);
        }
        return null;
    }
};

/// One declared union: its name and its members in declaration order.
///
/// **The order is the declaration's**, and two things read it: the
/// first member is the type's zero — what `var s: Shape` starts at,
/// with every payload field at its own zero (D13) — and `match`'s
/// exhaustiveness names a missing member by walking it.  The member
/// index is the tag a value's slot 0 holds.
pub const VariantType = struct {
    name: []const u8, // arena-owned by the program
    members: []VariantMember,

    pub fn findMember(self: VariantType, name: []const u8) ?u32 {
        for (self.members, 0..) |member, index| {
            if (std.mem.eql(u8, member.name, name)) return @intCast(index);
        }
        return null;
    }

    /// How many `Value` slots every value of this union carries: one
    /// for the member index, then the **largest** member's field count
    /// — D12's own number, made the run length.  One length for the
    /// whole type rather than the live member's own, because generated
    /// code re-derives a value's box from its static type alone (a
    /// call's result is a bare pointer), exactly as it does for a
    /// struct; a member with fewer fields pads the tail with `none`
    /// slots, which own nothing, copy as themselves, and free nothing
    /// (docs/UNION.md D8, D12).
    pub fn runLength(self: VariantType) usize {
        var widest: usize = 0;
        for (self.members) |member| widest = @max(widest, member.fields.len);
        return 1 + widest;
    }
};

pub const StructLayout = struct {
    name: []const u8, // arena-owned by the program
    fields: []StructField,
    /// Method contracts for an interface layout, empty for every source
    /// struct and class.  Keeping these separate from `fields` prevents a
    /// generic field instruction from forging or exposing an existential's
    /// private witness/payload representation.
    interface_methods: []InterfaceMethod = &.{},
    /// Compiler-generated nominal layout for an interface existential.
    interface: bool = false,
    /// ARC storage synthesized for a closure environment or a captured
    /// mutable cell. These layouts are never source-addressable, and may
    /// therefore carry the closure's always-present function values without
    /// weakening the source rule above.
    closure_storage: bool = false,
    /// A `class` is a **reference type** (docs/MEMORY.md D1): shared
    /// identity, heap-allocated, ARC-freed. A plain `struct` is a value.
    /// Recorded from stage 3; read by the runtime and MIR once ARC lands.
    reference: bool = false,
    /// The hidden function ARC invokes at the last strong release, while
    /// every field is still alive. Null for value structs and classes that
    /// declare no `deinit:` hook.
    deinitializer: ?u32 = null,

    /// The runtime `Value` span of this nominal value.  A source struct has
    /// one slot per field.  An interface has one witness slot and exactly one
    /// owned payload slot, independent of its method count.
    pub fn runLength(self: StructLayout) usize {
        return if (self.interface) 2 else self.fields.len;
    }

    pub fn findField(self: StructLayout, name: []const u8) ?u32 {
        for (self.fields, 0..) |field, index| {
            if (std.mem.eql(u8, field.name, name)) return @intCast(index);
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// The names the language answers to
// ---------------------------------------------------------------------------

/// Which builtin a written type name names.  Not a `Type` — `list`,
/// `map` and `array` take arguments and only become types once those
/// are resolved — so this answers *which builtin*, and the analyzer
/// finishes the job.
///
/// **One table, in one place.**  The parser has to know that `new
/// list(...)` spells a container before any type exists, and the
/// analyzer has to resolve the same spelling to the same thing; when
/// each carried its own list, a name could be a type in one stage and
/// an unknown struct in the other.
pub const Builtin = enum {
    boolean,
    u8,
    u16,
    u32,
    u64,
    i8,
    i16,
    i32,
    i64,
    f16,
    f32,
    f64,
    char,
    str,
    bytes,
    list,
    map,
    array,
    builder,
    /// An open file (docs/BYTES.md R5).  A heap-backed resource rather
    /// than a fifth container: it takes no type
    /// argument and there is no `new file`, because a handle with no
    /// file behind it is the one thing this type must never hold.
    /// The compiler-only `Builtin.file_open(path, mode)` intrinsic makes
    /// one inside `std.files`; programs use its ordinary
    /// open/create/append wrappers.
    file,
    /// A running worker (docs/THREADS.md D3).  A resource like `file`
    /// and written with a type argument like `list`: `task[f64]` is
    /// what `spawn` answers for a function returning `f64`, `task` alone for a
    /// function that answers nothing, and the `!` inside—`task[T!]`,
    /// `task[!]`—is the spawned function's own fallibility, which
    /// decides whether `wait` is a site that says `try`.  There is no
    /// `new task`: `spawn` is the only way to make one.
    task,
};

/// The builtin a name spells, or null when it names nothing builtin —
/// a struct of the reader's own, or a mistake.
///
/// **Lowercase names are the language's; TitleCase names are yours**
/// (docs/TYPES.md D8), which is what makes the case of a type name say
/// who defined it. There are no TitleCase builtin aliases.
pub fn builtinNamed(text: []const u8) ?Builtin {
    for (builtin_table) |entry| {
        if (std.mem.eql(u8, text, entry.name)) return entry.is;
    }
    return null;
}

const builtin_table = [_]struct { name: []const u8, is: Builtin }{
    .{ .name = "bool", .is = .boolean },
    .{ .name = "u8", .is = .u8 },
    .{ .name = "u16", .is = .u16 },
    .{ .name = "u32", .is = .u32 },
    .{ .name = "u64", .is = .u64 },
    .{ .name = "i8", .is = .i8 },
    .{ .name = "i16", .is = .i16 },
    .{ .name = "i32", .is = .i32 },
    .{ .name = "i64", .is = .i64 },
    .{ .name = "f16", .is = .f16 },
    .{ .name = "f32", .is = .f32 },
    .{ .name = "f64", .is = .f64 },
    .{ .name = "char", .is = .char },
    .{ .name = "str", .is = .str },
    .{ .name = "bytes", .is = .bytes },
    .{ .name = "list", .is = .list },
    .{ .name = "map", .is = .map },
    .{ .name = "array", .is = .array },
    .{ .name = "builder", .is = .builder },
    .{ .name = "file", .is = .file },
    .{ .name = "task", .is = .task },
};

/// The builtin a **conversion constructor** produces, or null when the
/// name is not one.  A conversion is named for the type it produces
/// (docs/NUMERICS.md §7), so this is `builtinNamed` narrowed to the
/// scalars — one table, asked a second question, rather than the three
/// hard-coded string comparisons that used to disagree.
pub fn conversionNamed(text: []const u8) ?Builtin {
    const builtin = builtinNamed(text) orelse return null;
    return switch (builtin) {
        .u8, .u16, .u32, .u64, .i8, .i16, .i32, .i64, .f16, .f32, .f64, .char, .str, .bytes => builtin,
        .boolean, .list, .map, .array, .builder, .file, .task => null,
    };
}

/// The names offered back to a reader who wrote a type name that
/// spells nothing.  Derived from the one table, so a spelling the
/// language answers to can never be one it declines to suggest.
pub const builtin_names = names: {
    var offered: [builtin_table.len][]const u8 = undefined;
    for (builtin_table, 0..) |entry, index| offered[index] = entry.name;
    const settled = offered;
    break :names settled;
};

/// The written name of a type, for diagnostics.  Struct names resolve
/// through the layout table; heap type names render recursively
/// (`list[i64]`, `map[str, list[i64]]`, `array[f64, _, _]`), an
/// optional takes the `?` it is written with, so the caller supplies
/// an allocator and owns the result.
pub fn typeName(
    allocator: std.mem.Allocator,
    layouts: []const StructLayout,
    heap_types: []const HeapType,
    enums: []const EnumType,
    variants: []const VariantType,
    signatures: []const Signature,
    of: Type,
) error{OutOfMemory}![]u8 {
    var written: std.ArrayList(u8) = .empty;
    errdefer written.deinit(allocator);
    try writeTypeName(&written, allocator, layouts, heap_types, enums, variants, signatures, of);
    return written.toOwnedSlice(allocator);
}

fn writeTypeName(
    written: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    layouts: []const StructLayout,
    heap_types: []const HeapType,
    enums: []const EnumType,
    variants: []const VariantType,
    signatures: []const Signature,
    of: Type,
) error{OutOfMemory}!void {
    switch (of) {
        .none => try written.appendSlice(allocator, "None"),
        .boolean => try written.appendSlice(allocator, "bool"),
        .u8 => try written.appendSlice(allocator, "u8"),
        .u16 => try written.appendSlice(allocator, "u16"),
        .u32 => try written.appendSlice(allocator, "u32"),
        .u64 => try written.appendSlice(allocator, "u64"),
        .i8 => try written.appendSlice(allocator, "i8"),
        .i16 => try written.appendSlice(allocator, "i16"),
        .i32 => try written.appendSlice(allocator, "i32"),
        .i64 => try written.appendSlice(allocator, "i64"),
        .f16 => try written.appendSlice(allocator, "f16"),
        .f32 => try written.appendSlice(allocator, "f32"),
        .f64 => try written.appendSlice(allocator, "f64"),
        .char => try written.appendSlice(allocator, "char"),
        .str => try written.appendSlice(allocator, "str"),
        .bytes => try written.appendSlice(allocator, "bytes"),
        .strukt => |index| try written.appendSlice(allocator, layouts[index].name),
        .enumeration => |reference| try written.appendSlice(allocator, enums[reference.index].name),
        .variant => |index| try written.appendSlice(allocator, variants[index].name),
        .heap => |index| switch (heap_types[index]) {
            .class => |layout| try written.appendSlice(allocator, layouts[layout].name),
            .list => |element| {
                try written.appendSlice(allocator, "list[");
                try writeTypeName(written, allocator, layouts, heap_types, enums, variants, signatures, element);
                try written.appendSlice(allocator, "]");
            },
            .map => |pair| {
                try written.appendSlice(allocator, "map[");
                try writeTypeName(written, allocator, layouts, heap_types, enums, variants, signatures, pair.key);
                try written.appendSlice(allocator, ", ");
                try writeTypeName(written, allocator, layouts, heap_types, enums, variants, signatures, pair.value);
                try written.appendSlice(allocator, "]");
            },
            .array => |shape| {
                try written.appendSlice(allocator, "array[");
                try writeTypeName(written, allocator, layouts, heap_types, enums, variants, signatures, shape.element);
                for (0..shape.rank) |_| try written.appendSlice(allocator, ", _");
                try written.appendSlice(allocator, "]");
            },
            .builder => try written.appendSlice(allocator, "builder"),
            .file => try written.appendSlice(allocator, "file"),
            .task => |work| {
                try written.appendSlice(allocator, "task");
                if (work.result != .none) {
                    try written.appendSlice(allocator, "[");
                    try writeTypeName(written, allocator, layouts, heap_types, enums, variants, signatures, work.result);
                    if (work.fallible) try written.appendSlice(allocator, "!");
                    try written.appendSlice(allocator, "]");
                } else if (work.fallible) try written.appendSlice(allocator, "[!]");
            },
        },
        .function => |index| {
            const signature = signatures[index];
            try written.appendSlice(allocator, "func(");
            for (signature.parameters, 0..) |parameter, at| {
                if (at != 0) try written.appendSlice(allocator, ", ");
                try writeTypeName(written, allocator, layouts, heap_types, enums, variants, signatures, parameter.value_type);
            }
            try written.appendSlice(allocator, ")");
            if (signature.result != .none) {
                try written.appendSlice(allocator, " -> ");
                try writeTypeName(written, allocator, layouts, heap_types, enums, variants, signatures, signature.result);
            }
        },
        .optional => |payload| {
            // **A function payload is parenthesized**, because that is
            // the only spelling that reads back as this type: a bare
            // `func(i64) -> str?` is a function *answering* an
            // optional (docs/BINDING.md D7).  Every other payload takes
            // the `?` bare, and adding parentheses there would put a
            // second spelling of every type into diagnostics.
            const parenthesized = payload == .function;
            if (parenthesized) try written.appendSlice(allocator, "(");
            try writeTypeName(written, allocator, layouts, heap_types, enums, variants, signatures, payload.asType());
            if (parenthesized) try written.appendSlice(allocator, ")");
            try written.appendSlice(allocator, "?");
        },
    }
}

test "type equality distinguishes struct indices" {
    try std.testing.expect(Type.eql(.i64, .i64));
    try std.testing.expect(!Type.eql(.i64, .f64));
    try std.testing.expect(Type.eql(.{ .strukt = 2 }, .{ .strukt = 2 }));
    try std.testing.expect(!Type.eql(.{ .strukt = 2 }, .{ .strukt = 3 }));
    try std.testing.expect(!Type.eql(.{ .strukt = 2 }, .i64));
}

test "an optional is its payload plus one level, and never two" {
    const maybe_int = Type.optionalOf(.i64).?;
    try std.testing.expect(maybe_int.eql(.{ .optional = .i64 }));
    try std.testing.expect(!maybe_int.eql(.i64));
    try std.testing.expect(maybe_int.held().?.eql(.i64));
    try std.testing.expectEqual(@as(?Type, null), (Type{ .i64 = {} }).held());

    // `T??` and an optional no-result type have no representation to reach.
    try std.testing.expectEqual(@as(?Type, null), Type.optionalOf(maybe_int));
    try std.testing.expectEqual(@as(?Type, null), Type.optionalOf(.none));

    // Payload identity is the payload's own: two `Point?`s are equal,
    // a `Point?` and a `Line?` are not.
    try std.testing.expect(Type.optionalOf(.{ .strukt = 2 }).?.eql(.{ .optional = .{ .strukt = 2 } }));
    try std.testing.expect(!Type.optionalOf(.{ .strukt = 2 }).?.eql(.{ .optional = .{ .strukt = 3 } }));

    // An `i64?` is not a number: arithmetic needs it narrowed first.
    try std.testing.expect(!maybe_int.isNumeric());
}

test "an optional type writes the ? it was written with" {
    const written = try typeName(std.testing.allocator, &.{}, &.{.{ .list = .i64 }}, &.{}, &.{}, &.{}, .{ .optional = .{ .heap = 0 } });
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings("list[i64]?", written);
}

test "an enum is its own type, its own name, and its backing width underneath" {
    const method: Type = .{ .enumeration = .{ .index = 0, .backing = .u8 } };
    const kind: Type = .{ .enumeration = .{ .index = 1, .backing = .u8 } };

    // Identity is the index: two enums of one width are two types.
    try std.testing.expect(method.eql(.{ .enumeration = .{ .index = 0, .backing = .u8 } }));
    try std.testing.expect(!method.eql(kind));
    try std.testing.expect(!method.eql(.u8));

    // Not a number to a program: no arithmetic and no ordering (D4, D6).
    try std.testing.expect(!method.isNumeric());
    try std.testing.expect(!method.isInteger());

    // A number underneath, everywhere a machine asks (D10).
    try std.testing.expect(method.storage().eql(.u8));
    try std.testing.expect((Type{ .i64 = {} }).storage().eql(.i64));

    // `Method?` exists, holds a `Method`, and is not a `u8?`.
    const maybe = Type.optionalOf(method).?;
    try std.testing.expect(maybe.held().?.eql(method));
    try std.testing.expect(!maybe.eql(Type.optionalOf(.u8).?));
    try std.testing.expect(!maybe.eql(Type.optionalOf(kind).?));

    const enums = [_]EnumType{
        .{ .name = "Method", .backing = .u8, .members = &.{} },
        .{ .name = "Kind", .backing = .u8, .members = &.{} },
    };
    const written = try typeName(std.testing.allocator, &.{}, &.{.{ .list = method }}, &enums, &.{}, &.{}, .{ .heap = 0 });
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings("list[Method]", written);
}
