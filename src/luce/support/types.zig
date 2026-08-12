//! The Luce type system's vocabulary: what a type is, what a heap
//! object's shape is, what a struct's layout is, and how any of them
//! is written down for a person.
//!
//! Nothing about any backend appears here — this is the only type
//! language the checker and the IR both speak.

const std = @import("std");

/// Host-controlled compile options.  A program is a script: `main`
/// takes either no parameter or one `list(string)` argument parameter,
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
    /// Stage 7, the whole of it (`07_optimize`): on for every artifact;
    /// `luce ir --full` clears it to show the raw lowering, unreached
    /// functions and all.  The name is older than the stage — it was
    /// one pass, dead-code elimination, when the flag was added.
    prune: bool = true,
    /// Where the entry comes from (`04_semantics/entry.zig`).
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
    /// `func main(args: list(string)) -> !` — which reads one name out
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
    /// The seven numeric types, in ladder order: four integer widths
    /// and three float widths, sized as Java, C, C#, GLSL and every
    /// GPU API size them (docs/TYPES.md).
    ///
    /// **`byte`, `short` and `half` are storage, not arithmetic**
    /// (D5): an operator widens them to `int` and `float` before it
    /// does anything, so no expression ever *has* one of these types
    /// and there is no checked arithmetic at 8 or 16 bits.  They are
    /// what an annotation, a parameter, a struct field and above all
    /// an array element may say — `array(byte, _)`, with its extent
    /// supplied at construction, is one byte an element and is what the
    /// three are for (§10).
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
        /// `Shape?` — the one absence a recursive union terminates at
        /// that is not a container (docs/UNION.md D14).
        variant: u32,
        /// `(func(T, ...) -> R)?` — **the storable form of a function
        /// value** (docs/BINDING.md D7).
        ///
        /// A bare `func` type stands where a value is always present:
        /// a parameter, a `let`.  A struct field, a container element
        /// and a map value are slots that exist before anything fills
        /// them, and a function value has no zero — every value of the
        /// type names a function, and an empty slot names none.  So the
        /// storable shape is the optional, whose zero is the absence
        /// `T?` already means, and calling through one takes the
        /// narrowing or the `else` any other optional takes.
        ///
        /// The written spelling needs its parentheses: `func(long) ->
        /// string?` is a function *answering* an optional, because a
        /// result type consumes its own `?` first.
        function: u32,

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
    /// convert only where somebody wrote `int(m)`.
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
            .none, .boolean, .string, .strukt, .heap, .enumeration, .variant, .function, .optional => 0,
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
            .none, .boolean, .half, .float, .double, .string, .strukt, .heap, .enumeration, .variant, .function, .optional => unreachable,
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
            .none, .boolean, .string, .strukt, .heap, .enumeration, .variant, .function, .optional => null,
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
            .double, .none, .boolean, .string, .strukt, .heap, .enumeration, .variant, .function, .optional => false,
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
            // `(func(...) -> R)?` — the storable form of a function
            // value (docs/BINDING.md D7).  The parentheses are the
            // written spelling's business; here it is one more payload.
            .function => |index| .{ .optional = .{ .function = index } },
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
/// or the state a scope-owned file/task resource carries.  Resources
/// use the heap table for an owner and death point; they are not
/// containers.
pub const HeapType = union(enum) {
    list: Type,
    map: struct { key: Type, value: Type },
    array: struct { element: Type, rank: u8 },
    builder,
    /// An open file (docs/BYTES.md R5).  A heap type and not a scalar
    /// because a file is a **resource**, and scope ownership is what
    /// gives a resource a death point: the binding that received the
    /// handle owns it, the owning scope's end closes it, and a use
    /// after close traps like a use after free because it is the same
    /// mistake.  It carries no element type — a file is not a
    /// container — so the shape is the whole of it, and
    /// `std.network`'s sockets are meant to arrive beside it wearing
    /// the same pattern.
    file,
    /// A running worker (docs/THREADS.md D3).  The `file` precedent
    /// exactly: a resource, not a container, whose death point is the
    /// owning scope's end — and for a worker the death point is a
    /// **join**, which is how structured concurrency falls out of
    /// scope ownership rather than being a discipline laid on top.
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
    /// `list(task(double))` may not hold both.
    task: struct { result: Type, fallible: bool },

    pub fn eql(self: HeapType, other: HeapType) bool {
        return switch (self) {
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
/// **Parameter types, and the verb each one receives objects with** —
/// no names, because a name is documentation of a declaration and a
/// type is not a declaration.  The verb is here because it is not
/// documentation: `func(give list(long))` and `func(list(long))` differ
/// in who owns the list afterwards, and a call through a value checks
/// its arguments' verbs exactly as a direct call does (D5).  Two
/// signatures that differ only in a verb are two types.
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
        /// Written `give T`: the callee takes ownership (OWNERSHIP.md
        /// S13).
        gives: bool = false,
    };

    pub fn eql(self: Signature, other: Signature) bool {
        if (self.parameters.len != other.parameters.len) return false;
        if (!self.result.eql(other.result)) return false;
        for (self.parameters, other.parameters) |mine, theirs| {
            if (mine.gives != theirs.gives) return false;
            if (!mine.value_type.eql(theirs.value_type)) return false;
        }
        return true;
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

/// One member of a union, as the program carries it: the name an arm
/// and `string(u)` answer, and the payload fields in declaration order
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
    /// An open file (docs/BYTES.md R5).  A heap-backed resource rather
    /// than a fifth container: it takes no type
    /// argument and there is no `new file`, because a handle with no
    /// file behind it is the one thing this type must never hold.
    /// The raw `file_open(path, mode)` host builtin makes one;
    /// `std.files` exposes the ordinary open/create/append wrappers.
    file,
    /// A running worker (docs/THREADS.md D3).  A resource like `file`
    /// and written with a type argument like `list`: `task(double)` is
    /// what `spawn` answers for a `func -> double`, `task` alone for a
    /// function that answers nothing, and the `!` inside — `task(T!)`,
    /// `task(!)` — is the spawned function's own fallibility, which
    /// decides whether `wait` is a site that says `try`.  There is no
    /// `new task`: `spawn` is the only way to make one.
    task,
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
    .{ .name = "file", .is = .file },
    .{ .name = "task", .is = .task },
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
/// (`list(long)`, `map(string, list(long))`, `array(double, _, _)`), an
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
        .variant => |index| try written.appendSlice(allocator, variants[index].name),
        .heap => |index| switch (heap_types[index]) {
            .list => |element| {
                try written.appendSlice(allocator, "list(");
                try writeTypeName(written, allocator, layouts, heap_types, enums, variants, signatures, element);
                try written.appendSlice(allocator, ")");
            },
            .map => |pair| {
                try written.appendSlice(allocator, "map(");
                try writeTypeName(written, allocator, layouts, heap_types, enums, variants, signatures, pair.key);
                try written.appendSlice(allocator, ", ");
                try writeTypeName(written, allocator, layouts, heap_types, enums, variants, signatures, pair.value);
                try written.appendSlice(allocator, ")");
            },
            .array => |shape| {
                try written.appendSlice(allocator, "array(");
                try writeTypeName(written, allocator, layouts, heap_types, enums, variants, signatures, shape.element);
                for (0..shape.rank) |_| try written.appendSlice(allocator, ", _");
                try written.appendSlice(allocator, ")");
            },
            .builder => try written.appendSlice(allocator, "builder"),
            .file => try written.appendSlice(allocator, "file"),
            .task => |work| {
                try written.appendSlice(allocator, "task");
                if (work.result != .none) {
                    try written.appendSlice(allocator, "(");
                    try writeTypeName(written, allocator, layouts, heap_types, enums, variants, signatures, work.result);
                    if (work.fallible) try written.appendSlice(allocator, "!");
                    try written.appendSlice(allocator, ")");
                } else if (work.fallible) try written.appendSlice(allocator, "!");
            },
        },
        .function => |index| {
            const signature = signatures[index];
            try written.appendSlice(allocator, "func(");
            for (signature.parameters, 0..) |parameter, at| {
                if (at != 0) try written.appendSlice(allocator, ", ");
                if (parameter.gives) try written.appendSlice(allocator, "give ");
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
            // `func(long) -> string?` is a function *answering* an
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
    const written = try typeName(std.testing.allocator, &.{}, &.{.{ .list = .long }}, &.{}, &.{}, &.{}, .{ .optional = .{ .heap = 0 } });
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
    const written = try typeName(std.testing.allocator, &.{}, &.{.{ .list = method }}, &enums, &.{}, &.{}, .{ .heap = 0 });
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings("list(Method)", written);
}
