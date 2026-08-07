//! The Luce type system's vocabulary: what a type is, what a heap
//! object's shape is, what a struct's layout is, and how any of them
//! is written down for a person.
//!
//! Nothing about any backend appears here — this is the only type
//! language the checker and the IR both speak.

const std = @import("std");

/// Host-controlled compile options.  A program is a script: exactly
/// `func main():`, or `func main() -> !:` when it can be stopped.
/// `allow_host` grants the host builtins (console, files, arguments,
/// terminal) and is the only authority gate left.
pub const CompileOptions = struct {
    allow_host: bool = false,
    /// Display name for the root module in debug info ("dice.luc") —
    /// what a runtime trap location reports.  "" falls back to
    /// "main.luc".  Imported modules always report "PREFIX.luc".
    source_name: []const u8 = "",
    /// Stage 7, the whole of it (`07_optimize`): on for every artifact;
    /// `luce ir --full` clears it to show the raw lowering, unreached
    /// functions and all.  The name is older than the stage — it was
    /// one pass, dead-code elimination, when the flag was added.
    prune: bool = true,
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
    /// The seven numeric types, in ladder order: four integer widths
    /// and three float widths, sized as Java, C, C#, GLSL and every
    /// GPU API size them (docs/TYPES.md).
    ///
    /// **`byte`, `short` and `half` are storage, not arithmetic**
    /// (D5): an operator widens them to `int` and `float` before it
    /// does anything, so no expression ever *has* one of these types
    /// and there is no checked arithmetic at 8 or 16 bits.  They are
    /// what an annotation, a parameter, a struct field and above all
    /// an array element may say — `array(byte, n)` at one byte an
    /// element is what the three are for (§10).
    byte,
    short,
    int,
    long,
    half,
    float,
    double,
    string,
    strukt: u32,
    heap: u32,
    /// A set of named constants at one integer width (docs/ENUMS.md).
    /// The index reaches the program's enum table — the type's name and
    /// its members — and the width travels beside it, for the reason
    /// `EnumRef` gives.
    enumeration: EnumRef,
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

        /// The four rungs of the integer ladder a member may be stored
        /// at.  A narrower type than `Type` because these are the only
        /// four an enum can name, and a set that cannot spell `double`
        /// needs no diagnostic saying so.
        pub const Backing = enum {
            byte,
            short,
            int,
            long,

            pub fn asType(self: Backing) Type {
                return switch (self) {
                    .byte => .byte,
                    .short => .short,
                    .int => .int,
                    .long => .long,
                };
            }

            /// The rung a written width names, or null when the name is
            /// not one of the four.
            pub fn of(written: Type) ?Backing {
                return switch (written) {
                    .byte => .byte,
                    .short => .short,
                    .int => .int,
                    .long => .long,
                    else => null,
                };
            }
        };
    };

    /// What a `T?` may hold.  A union of its own rather than a
    /// `*Type`, so `T??` and `None?` are *unrepresentable* rather than
    /// merely refused: there is one level of absence and no way to
    /// write a second.
    pub const Payload = union(enum) {
        boolean,
        byte,
        short,
        int,
        long,
        half,
        float,
        double,
        string,
        strukt: u32,
        heap: u32,
        enumeration: EnumRef,

        pub fn asType(self: Payload) Type {
            return switch (self) {
                .boolean => .boolean,
                .byte => .byte,
                .short => .short,
                .int => .int,
                .long => .long,
                .half => .half,
                .float => .float,
                .double => .double,
                .string => .string,
                .strukt => |index| .{ .strukt = index },
                .heap => |index| .{ .heap = index },
                .enumeration => |reference| .{ .enumeration = reference },
            };
        }

        pub fn eql(self: Payload, other: Payload) bool {
            return switch (self) {
                .strukt => |index| other == .strukt and other.strukt == index,
                .heap => |index| other == .heap and other.heap == index,
                .enumeration => |reference| other == .enumeration and
                    other.enumeration.index == reference.index,
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
    /// convert only where somebody wrote `int(m)`.
    pub fn storage(self: Type) Type {
        return switch (self) {
            .enumeration => |reference| reference.backing.asType(),
            else => self,
        };
    }

    pub fn isNumeric(self: Type) bool {
        return self.isInteger() or self.isFloating();
    }

    /// The integers, and nothing else — `bool` is not a small integer
    /// here and never has been.  Three are signed; `byte` is the one
    /// unsigned type there is and the only one there will be (D4).
    pub fn isInteger(self: Type) bool {
        return self == .byte or self == .short or self == .int or self == .long;
    }

    pub fn isFloating(self: Type) bool {
        return self == .half or self == .float or self == .double;
    }

    /// Whether the bits of an integer type are read as a magnitude.
    /// Only `byte` is, which is what "unsigned" means about it and the
    /// whole of what is numeric about it (D4): widening a `byte` is a
    /// `zext`, widening a `short` a `sext`.
    pub fn isUnsigned(self: Type) bool {
        return self == .byte;
    }

    /// How wide a numeric type is, in bits.  Asked only of one:
    /// callers test `isNumeric` first, and a non-numeric answering
    /// zero would let a caller compute with the answer instead of
    /// being stopped by it.
    pub fn numericBits(self: Type) u16 {
        return switch (self) {
            .byte => 8,
            .short, .half => 16,
            .int, .float => 32,
            .long, .double => 64,
            // An enum is not a number (D6): asking how wide one is is
            // asking about `int(m)`, which is a different type.
            .none, .boolean, .string, .strukt, .heap, .enumeration, .optional => 0,
        };
    }

    /// The closed range an integer type holds, as the one statement of
    /// it in the tree.  Carried at `i128` because `long`'s bounds are
    /// `i64`'s extremes and comparing them to another type's must not
    /// itself overflow.
    ///
    /// Asked only of an integer; the caller has tested `isInteger`.
    pub fn integerRange(self: Type) struct { low: i128, high: i128 } {
        return switch (self) {
            .byte => .{ .low = 0, .high = 255 },
            .short => .{ .low = -32768, .high = 32767 },
            .int => .{ .low = -2147483648, .high = 2147483647 },
            .long => .{
                .low = std.math.minInt(i64),
                .high = std.math.maxInt(i64),
            },
            .none, .boolean, .half, .float, .double, .string, .strukt, .heap, .enumeration, .optional => unreachable,
        };
    }

    /// The type an operator computes this one at — D5's collapse from
    /// a seven-by-seven promotion table to four arithmetic types.
    /// `byte` and `short` compute at `int`, `half` at `float`, and the
    /// four arithmetic types compute at themselves.  Null for
    /// everything that is not a number.
    ///
    /// This is why there is no checked arithmetic at 8 or 16 bits and
    /// no binary16 arithmetic on any target: no expression ever has
    /// one of the three storage types, so there is nothing for either
    /// to be defined on.
    pub fn arithmeticType(self: Type) ?Type {
        return switch (self) {
            .byte, .short, .int => .int,
            .long => .long,
            .half, .float => .float,
            .double => .double,
            .none, .boolean, .string, .strukt, .heap, .enumeration, .optional => null,
        };
    }

    /// Whether a value of `self` reaches a `to` place with **nothing
    /// written down** — the whole of the language's implicit
    /// conversion, stated once (docs/TYPES.md §2).
    ///
    /// Along a ladder, every rung reaches every rung above it and
    /// exactly: `byte` into `short`, `int` and `long`, `short` into
    /// `int` and `long`, `int` into `long`; `half` into `float`.
    /// Across the ladders the answer is always `double`:
    /// `int` is exact in it and `long` is exact below 2^53, which is
    /// the one lossy implicit conversion the language has and the one
    /// `docs/NUMERICS.md` §6 ratified.  What is *not* here is Java's
    /// `int → float` and `long → float`, which lose everything above
    /// 2^24 from sources that reach it routinely; a program that wants
    /// a narrow float writes `float(x)` and says so.
    ///
    /// Narrowing is in no direction and no context: not `long` into
    /// `int`, not `double` into `float`, not at a store, an argument
    /// or a return.
    pub fn widensTo(self: Type, to: Type) bool {
        return switch (self) {
            .byte => to == .short or to == .int or to == .long or to == .double,
            .short => to == .int or to == .long or to == .double,
            .int => to == .long or to == .double,
            .long => to == .double,
            .half => to == .float or to == .double,
            .float => to == .double,
            // An enum reaches no number with nothing written down (D4):
            // it is a set of names, and `int(m)` is how a program says
            // it means the number.
            .double, .none, .boolean, .string, .strukt, .heap, .enumeration, .optional => false,
        };
    }

    /// The type two numeric operands meet at, or null when either is
    /// not a number.
    ///
    /// **Each operand goes to its arithmetic type first** (D5), so a
    /// storage type never survives an operator: `byte + byte` is an
    /// `int`, `half * half` a `float`, and neither 8-bit arithmetic
    /// nor binary16 arithmetic is ever asked for.  After that the
    /// rule is the four-type one it always was — same type, same
    /// answer; two integers meet at the wider; two floats meet at the
    /// wider; a mixed pair meets at `double`, whichever way round it
    /// was written.
    pub fn unified(left: Type, right: Type) ?Type {
        const wide_left = left.arithmeticType() orelse return null;
        const wide_right = right.arithmeticType() orelse return null;
        if (wide_left.eql(wide_right)) return wide_left;
        if (wide_left.isInteger() and wide_right.isInteger()) return .long;
        if (wide_left.isFloating() and wide_right.isFloating()) return .double;
        return .double;
    }

    /// Whether the conversion `to(x)` can stop the program.
    ///
    /// Two of the four families of pair can, and for the same reason:
    /// the answer may have no representation at all in the
    /// destination, and Luce refuses to invent one (docs/TYPES.md §3).
    ///
    ///   * **float to integer** traps `conversion_range` outside the
    ///     target, NaN and the infinities included — at every width,
    ///     because rounding half away from zero can land past the top
    ///     of an `int` as easily as past the top of a `long`.
    ///   * **integer to a narrower integer** traps `conversion_range`
    ///     outside the target: `int(3000000000)` is not 3 billion
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
        std.debug.assert(from.isNumeric() and to.isNumeric());
        if (from.isFloating()) return to.isInteger();
        if (to.isFloating()) return false;
        // Integer to integer: it traps exactly when the destination
        // cannot hold every value the source can.  Comparing the two
        // *ranges* rather than their widths is what keeps `byte`
        // honest in both directions — `short(b)` is a widening
        // although `byte` is unsigned, and `byte(s)` is not although
        // `short` is wider.
        const source = from.integerRange();
        const target = to.integerRange();
        return target.low > source.low or target.high < source.high;
    }

    /// `T` written as `T?`, or null when there is no such type: `None`
    /// has no value to be absent, and `T??` does not exist.
    pub fn optionalOf(base: Type) ?Type {
        return switch (base) {
            .none, .optional => null,
            .boolean => .{ .optional = .boolean },
            .byte => .{ .optional = .byte },
            .short => .{ .optional = .short },
            .int => .{ .optional = .int },
            .long => .{ .optional = .long },
            .half => .{ .optional = .half },
            .float => .{ .optional = .float },
            .double => .{ .optional = .double },
            .string => .{ .optional = .string },
            .strukt => |index| .{ .optional = .{ .strukt = index } },
            .heap => |index| .{ .optional = .{ .heap = index } },
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

/// The shape of one heap object type: what a list holds, a map's key
/// and value, an array's element and rank, or a builder.
pub const HeapType = union(enum) {
    list: Type,
    map: struct { key: Type, value: Type },
    array: struct { element: Type, rank: u8 },
    builder,

    pub fn eql(self: HeapType, other: HeapType) bool {
        return switch (self) {
            .list => |element| other == .list and element.eql(other.list),
            .map => |pair| other == .map and
                pair.key.eql(other.map.key) and pair.value.eql(other.map.value),
            .array => |shape| other == .array and
                shape.element.eql(other.array.element) and shape.rank == other.array.rank,
            .builder => other == .builder,
        };
    }
};

/// One member of an enum, as the program carries it: the name
/// `string(m)` answers and the number `int(m)` answers (docs/ENUMS.md
/// D1, D5).
pub const EnumMember = struct {
    name: []const u8, // arena-owned by the program
    value: i64,
};

/// One declared enum: its name, the width its members are stored at,
/// and the members in declaration order.
///
/// **The order is the declaration's**, and two things read it: the
/// first member is the type's zero — what `var m: Method` starts at and
/// what an `array(Method, n)` is filled with — and `match`'s
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
    pub fn memberOfValue(self: EnumType, value: i64) ?u32 {
        for (self.members, 0..) |member, index| {
            if (member.value == value) return @intCast(index);
        }
        return null;
    }
};

pub const StructField = struct {
    name: []const u8, // arena-owned by the program
    field_type: Type,
};

pub const StructLayout = struct {
    name: []const u8, // arena-owned by the program
    fields: []StructField,

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
    byte,
    short,
    int,
    long,
    half,
    float,
    double,
    string,
    list,
    map,
    array,
    builder,
};

/// The builtin a name spells, or null when it names nothing builtin —
/// a struct of the reader's own, or a mistake.
///
/// **Lowercase names are the language's; TitleCase names are yours**
/// (docs/TYPES.md D8), which is what makes the case of a type name say
/// who defined it.  There are no TitleCase builtins and no aliases for
/// the ones there used to be: a program that writes `long` is told the
/// name is `long`, by `failUnknownType`, once.
pub fn builtinNamed(text: []const u8) ?Builtin {
    for (builtin_table) |entry| {
        if (std.mem.eql(u8, text, entry.name)) return entry.is;
    }
    return null;
}

const builtin_table = [_]struct { name: []const u8, is: Builtin }{
    .{ .name = "bool", .is = .boolean },
    .{ .name = "byte", .is = .byte },
    .{ .name = "short", .is = .short },
    .{ .name = "int", .is = .int },
    .{ .name = "long", .is = .long },
    .{ .name = "half", .is = .half },
    .{ .name = "float", .is = .float },
    .{ .name = "double", .is = .double },
    .{ .name = "string", .is = .string },
    .{ .name = "list", .is = .list },
    .{ .name = "map", .is = .map },
    .{ .name = "array", .is = .array },
    .{ .name = "builder", .is = .builder },
};

/// The lowercase name a retired TitleCase spelling is written with
/// now, or null when the name was never one of the language's.
///
/// The two resized names are the reason this exists rather than a
/// suggestion by edit distance: nothing spells `long` closely enough
/// to `Int` for a did-you-mean to find it, and a reader whose only
/// mistake is remembering the older name should be told the newer one
/// outright.  It is also the sentence the whole tree's migration
/// hangs on, so it names both halves.
///
/// **`Int` answers `long` and `Float` answers `double`, not `int` and
/// `float`** — the lowercase names exist now, but they are 32 bits
/// wide and the TitleCase ones never were.  A reader migrating a
/// program written before the resize wants the type that holds what
/// theirs held; the narrow one is a decision, and a decision belongs
/// where somebody writes it down.
pub fn retiredSpelling(text: []const u8) ?[]const u8 {
    const retired = [_]struct { was: []const u8, now: []const u8 }{
        .{ .was = "Int", .now = "long" },
        .{ .was = "Float", .now = "double" },
        .{ .was = "Bool", .now = "bool" },
        .{ .was = "String", .now = "string" },
        .{ .was = "List", .now = "list" },
        .{ .was = "Map", .now = "map" },
        .{ .was = "Array", .now = "array" },
        .{ .was = "Builder", .now = "builder" },
    };
    for (retired) |entry| {
        if (std.mem.eql(u8, text, entry.was)) return entry.now;
    }
    return null;
}

/// The builtin a **conversion constructor** produces, or null when the
/// name is not one.  A conversion is named for the type it produces
/// (docs/NUMERICS.md §7), so this is `builtinNamed` narrowed to the
/// scalars — one table, asked a second question, rather than the three
/// hard-coded string comparisons that used to disagree.
pub fn conversionNamed(text: []const u8) ?Builtin {
    const builtin = builtinNamed(text) orelse return null;
    return switch (builtin) {
        .byte, .short, .int, .long, .half, .float, .double, .string => builtin,
        .boolean, .list, .map, .array, .builder => null,
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
/// (`list(long)`, `map(string, list(long))`, `array(double, _, _)`), an
/// optional takes the `?` it is written with, so the caller supplies
/// an allocator and owns the result.
pub fn typeName(
    allocator: std.mem.Allocator,
    layouts: []const StructLayout,
    heap_types: []const HeapType,
    enums: []const EnumType,
    of: Type,
) error{OutOfMemory}![]u8 {
    var written: std.ArrayList(u8) = .empty;
    errdefer written.deinit(allocator);
    try writeTypeName(&written, allocator, layouts, heap_types, enums, of);
    return written.toOwnedSlice(allocator);
}

fn writeTypeName(
    written: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    layouts: []const StructLayout,
    heap_types: []const HeapType,
    enums: []const EnumType,
    of: Type,
) error{OutOfMemory}!void {
    switch (of) {
        .none => try written.appendSlice(allocator, "None"),
        .boolean => try written.appendSlice(allocator, "bool"),
        .byte => try written.appendSlice(allocator, "byte"),
        .short => try written.appendSlice(allocator, "short"),
        .int => try written.appendSlice(allocator, "int"),
        .long => try written.appendSlice(allocator, "long"),
        .half => try written.appendSlice(allocator, "half"),
        .float => try written.appendSlice(allocator, "float"),
        .double => try written.appendSlice(allocator, "double"),
        .string => try written.appendSlice(allocator, "string"),
        .strukt => |index| try written.appendSlice(allocator, layouts[index].name),
        .enumeration => |reference| try written.appendSlice(allocator, enums[reference.index].name),
        .heap => |index| switch (heap_types[index]) {
            .list => |element| {
                try written.appendSlice(allocator, "list(");
                try writeTypeName(written, allocator, layouts, heap_types, enums, element);
                try written.appendSlice(allocator, ")");
            },
            .map => |pair| {
                try written.appendSlice(allocator, "map(");
                try writeTypeName(written, allocator, layouts, heap_types, enums, pair.key);
                try written.appendSlice(allocator, ", ");
                try writeTypeName(written, allocator, layouts, heap_types, enums, pair.value);
                try written.appendSlice(allocator, ")");
            },
            .array => |shape| {
                try written.appendSlice(allocator, "array(");
                try writeTypeName(written, allocator, layouts, heap_types, enums, shape.element);
                for (0..shape.rank) |_| try written.appendSlice(allocator, ", _");
                try written.appendSlice(allocator, ")");
            },
            .builder => try written.appendSlice(allocator, "builder"),
        },
        .optional => |payload| {
            try writeTypeName(written, allocator, layouts, heap_types, enums, payload.asType());
            try written.appendSlice(allocator, "?");
        },
    }
}

test "type equality distinguishes struct indices" {
    try std.testing.expect(Type.eql(.long, .long));
    try std.testing.expect(!Type.eql(.long, .double));
    try std.testing.expect(Type.eql(.{ .strukt = 2 }, .{ .strukt = 2 }));
    try std.testing.expect(!Type.eql(.{ .strukt = 2 }, .{ .strukt = 3 }));
    try std.testing.expect(!Type.eql(.{ .strukt = 2 }, .long));
}

test "an optional is its payload plus one level, and never two" {
    const maybe_int = Type.optionalOf(.long).?;
    try std.testing.expect(maybe_int.eql(.{ .optional = .long }));
    try std.testing.expect(!maybe_int.eql(.long));
    try std.testing.expect(maybe_int.held().?.eql(.long));
    try std.testing.expectEqual(@as(?Type, null), (Type{ .long = {} }).held());

    // `T??` and `None?` have no representation to reach.
    try std.testing.expectEqual(@as(?Type, null), Type.optionalOf(maybe_int));
    try std.testing.expectEqual(@as(?Type, null), Type.optionalOf(.none));

    // Payload identity is the payload's own: two `Point?`s are equal,
    // a `Point?` and a `Line?` are not.
    try std.testing.expect(Type.optionalOf(.{ .strukt = 2 }).?.eql(.{ .optional = .{ .strukt = 2 } }));
    try std.testing.expect(!Type.optionalOf(.{ .strukt = 2 }).?.eql(.{ .optional = .{ .strukt = 3 } }));

    // A `long?` is not a number: arithmetic needs it narrowed first.
    try std.testing.expect(!maybe_int.isNumeric());
}

test "an optional type writes the ? it was written with" {
    const written = try typeName(std.testing.allocator, &.{}, &.{.{ .list = .long }}, &.{}, .{ .optional = .{ .heap = 0 } });
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings("list(long)?", written);
}

test "an enum is its own type, its own name, and its backing width underneath" {
    const method: Type = .{ .enumeration = .{ .index = 0, .backing = .byte } };
    const kind: Type = .{ .enumeration = .{ .index = 1, .backing = .byte } };

    // Identity is the index: two enums of one width are two types.
    try std.testing.expect(method.eql(.{ .enumeration = .{ .index = 0, .backing = .byte } }));
    try std.testing.expect(!method.eql(kind));
    try std.testing.expect(!method.eql(.byte));

    // Not a number to a program: no arithmetic, no ordering, no
    // implicit reach into a width that would hold it (D4, D6).
    try std.testing.expect(!method.isNumeric());
    try std.testing.expect(!method.isInteger());
    try std.testing.expectEqual(@as(?Type, null), method.arithmeticType());
    try std.testing.expect(!method.widensTo(.int));
    try std.testing.expect(!method.widensTo(.long));
    try std.testing.expect(!(Type{ .byte = {} }).widensTo(method));

    // A number underneath, everywhere a machine asks (D10).
    try std.testing.expect(method.storage().eql(.byte));
    try std.testing.expect((Type{ .long = {} }).storage().eql(.long));

    // `Method?` exists, holds a `Method`, and is not a `byte?`.
    const maybe = Type.optionalOf(method).?;
    try std.testing.expect(maybe.held().?.eql(method));
    try std.testing.expect(!maybe.eql(Type.optionalOf(.byte).?));
    try std.testing.expect(!maybe.eql(Type.optionalOf(kind).?));

    const enums = [_]EnumType{
        .{ .name = "Method", .backing = .byte, .members = &.{} },
        .{ .name = "Kind", .backing = .byte, .members = &.{} },
    };
    const written = try typeName(std.testing.allocator, &.{}, &.{.{ .list = method }}, &enums, .{ .heap = 0 });
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings("list(Method)", written);
}
