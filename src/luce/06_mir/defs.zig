//! IR type, enum, and struct definitions.
//! All data types for the Luce intermediate representation.

const std = @import("std");
const types = @import("../support/types.zig");
const value = @import("../runtime/value.zig");
const vocabulary = @import("../support/vocabulary.zig");

const Allocator = std.mem.Allocator;
const Type = types.Type;
const StructLayout = types.StructLayout;

pub const Register = u32;

/// Which `runtime.Tag` a value of `of` wears once it is boxed, or null
/// for the one type that cannot say: a `T?` boxes as its payload's tag
/// when it is there and as `none` when it is not, so what it wears is
/// decided by the value and never by the type.
///
/// Here rather than in either engine because **both** need it and they
/// must not answer differently — a program's types and the runtime's
/// tags are two halves of one wire surface, which is the same reason
/// `TrapCode` is named in this file.
pub fn boxTag(of: Type) ?value.Tag {
    return switch (of) {
        .none => .none,
        .boolean => .boolean,
        .byte => .byte,
        .short => .short,
        .int => .int,
        .long => .long,
        .half => .half,
        .float => .float,
        .double => .double,
        .string => .string,
        .strukt => .strukt,
        .heap => .object,
        .optional => null,
    };
}
pub const BlockId = u32;
pub const LocalId = u32;

pub const BinaryOp = vocabulary.BinaryOp;

pub const UnaryOp = enum { negate, logic_not };

pub const Intrinsic = enum {
    abs,
    min,
    max,
    clamp,
    sqrt,
    floor,
    ceil,
    /// `trunc(x)` — toward zero, the fourth of the four roundings.
    /// It arrived with `long(x)`'s rounding: before that, `long(x)` was
    /// the only way to say "toward zero" and taking it would have
    /// punched a hole in a set that `floor`, `ceil` and `math.round`
    /// otherwise complete (docs/NUMERICS.md §7).
    trunc,
    /// Comparison across the long/double line, exactly (docs/NUMERICS.md).
    /// Three arguments — the operator as an `long`, then the `long`
    /// operand, then the `double` one — because `Binary` carries a
    /// single `operand_type` and cannot say that its two sides are
    /// different types.  Stage 4 mirrors the operator when the double
    /// was written on the left, so the long is always argument one.
    compare_long_double,
    len,
    string_slice,
    string_byte,
    string_find_byte,
    assert_true,
    trap_message,
    null_object,
    /// The four an optional needs, and no instruction (docs/FAILURE.md).
    /// `none_value` materializes the absent value of its result type;
    /// `is_none` asks; `optional_wrap` is the `T <: T?` widening;
    /// `optional_unwrap` is what narrowing licensed — the analyzer has
    /// already proved the value is there, so it never checks.
    none_value,
    is_none,
    optional_wrap,
    optional_unwrap,
    /// The three an error needs beyond its terminators
    /// (docs/FAILURE.md).  `errored` asks whether the fallible call or
    /// intrinsic naming its one argument came back errored rather than
    /// returning; it is the only instruction that may read that
    /// register's outcome, and it must stand in the same block as what
    /// it asks about.  `error_message` reads the words out of the
    /// channel — what `catch NAME:` binds — and answers a borrow of
    /// run-lifetime storage, so a place that keeps them takes a copy in
    /// the ordinary way.  `forget` discards the pending error and its
    /// words — what `catch` does, and the reason a caught error leaks
    /// nothing; it stands *after* any `error_message` reading the same
    /// error, and after the copy that reading takes, so nothing has to
    /// know how long a forgotten error's words stay readable.
    errored,
    error_message,
    forget,
    /// `error("…")` — record `user_error` and the program's own words
    /// in the channel.  Not a terminator: the `unwind` that follows it
    /// comes *after* the releases this frame owes, and the words are
    /// copied into run-lifetime storage here, before any of them run
    /// (docs/FAILURE.md).  The same shape as `trap_message`, for the
    /// same reason.
    raise_error,
    index_get,
    index_set,
    list_slice,
    append_value,
    append_ascii,
    pop_value,
    insert_value,
    remove_entry,
    has_key,
    key_at,
    value_at,
    dim_size,
    free_object,
    give_object,
    copy_object,
    list_sort,
    list_reverse,
    list_find,
    list_contains,
    clear_object,
    map_keys,
    map_values,
    map_get,
    /// `m[k] OP= v` reads its place through this rather than
    /// `index_get`: a missing key is **defined** at the zero given as
    /// the third operand instead of trapping, because the operator on
    /// the left says this read is half of a write.  Maps only — a list
    /// or array compound assignment still reads through `index_get`
    /// and still traps out of range.
    map_place,
    array_fill,
    str_value,
    parse_int,
    parse_float,
    chr_code,
    ord_text,
    print,
    file_read,
    file_write,
    file_exists,
    term_rows,
    term_cols,
    term_clear,
    term_move,
    term_style,
    term_write,
    term_flush,
    key_read,
    key_text,
    /// One line from standard input, with the prompt the host writes
    /// and flushes before it blocks — the same discipline `key_read`
    /// follows, and the reason a prompt is an argument rather than a
    /// print of its own.  Answers `string?`: end of input is "there is
    /// nothing there", with no reason worth carrying (docs/FAILURE.md).
    read_line,
    /// A line to standard error.  A second console, not a second
    /// `print`: stdout is the program's data and stderr is where a
    /// program says something to a person while its output is a pipe.
    print_error,
    /// Milliseconds on a monotonic clock whose origin is unspecified,
    /// so only differences mean anything, and `sleep_ms`, which waits
    /// at least that long.  Neither can fail; a host without them is
    /// `host_unavailable` like every other withheld service.
    clock_ms,
    sleep_ms,
    /// One environment variable, or absent when it is unset.  Absence
    /// again, for the same reason `read_line`'s is: "not set" is the
    /// same fact every time and carries no news.
    env_get,
    /// The four file services the world can say no to, beside
    /// `file_read` and `file_write` and fallible on the same grounds:
    /// no non-racy check stands in for the result (docs/FAILURE.md).
    file_append,
    file_delete,
    file_rename,
    dir_list,
    /// The two halves of value storage (docs/STRINGS.md).  A string's
    /// bytes and a struct's field run have exactly one owner, so
    /// `own_storage` takes the copy every store into a place that
    /// outlives the statement needs, and `drop_storage` is the death
    /// point — it answers the emptied value, which the caller writes
    /// back, so releasing a place twice frees nothing the second time.
    /// Neither touches objects: those are `object_bind`'s business.
    own_storage,
    drop_storage,
    /// The third: what `ret` does to a value on its way out of the
    /// frame that made it.  Short text lives in the value, and on the
    /// compiled path a value lives in a frame slot — so text that fits
    /// inline is copied into storage the caller owns, and everything
    /// already independent of the frame moves untouched.
    export_storage,

    // -- per-intrinsic facts, classified once ---------------------------
    //
    // Each of the three below was written twice or guarded by an
    // `else`, which is the same defect wearing two hats: adding an
    // intrinsic and forgetting to classify it was silent.  They live
    // on the enum, they name every tag, and they have no `else` — so
    // a new tag is a compile error here until somebody decides what it
    // is.  `07_optimize/effects.zig`'s `intrinsicEffect` is the model.

    /// Can this intrinsic come back **errored** rather than answering?
    ///
    /// Stage 4 asks so a call site is made to say which of `try` and
    /// `catch` it means; `06_mir/verify.zig` asks so an `errored` may
    /// name only an instruction that really has an outcome.  The two
    /// used to keep separate lists, and a program where they disagreed
    /// is one that could branch on a word nobody wrote.
    pub fn isFallible(self: Intrinsic) bool {
        return switch (self) {
            // The six file services the world can say no to, with no
            // non-racy check that stands in for the result
            // (docs/FAILURE.md).
            .file_read,
            .file_write,
            .file_append,
            .file_delete,
            .file_rename,
            .dir_list,
            => true,

            .abs,
            .min,
            .max,
            .clamp,
            .sqrt,
            .floor,
            .ceil,
            .trunc,
            .compare_long_double,
            .len,
            .string_slice,
            .string_byte,
            .string_find_byte,
            .assert_true,
            .trap_message,
            .null_object,
            .none_value,
            .is_none,
            .optional_wrap,
            .optional_unwrap,
            .errored,
            .forget,
            .raise_error,
            .index_get,
            .index_set,
            .list_slice,
            .append_value,
            .append_ascii,
            .pop_value,
            .insert_value,
            .remove_entry,
            .has_key,
            .key_at,
            .value_at,
            .dim_size,
            .free_object,
            .give_object,
            .copy_object,
            .list_sort,
            .list_reverse,
            .list_find,
            .list_contains,
            .clear_object,
            .map_keys,
            .map_values,
            .map_get,
            .map_place,
            .array_fill,
            .str_value,
            .parse_int,
            .parse_float,
            .chr_code,
            .ord_text,
            .print,
            .file_exists,
            .term_rows,
            .term_cols,
            .term_clear,
            .term_move,
            .term_style,
            .term_write,
            .term_flush,
            .key_read,
            .key_text,
            .read_line,
            .print_error,
            .clock_ms,
            .sleep_ms,
            .env_get,
            .own_storage,
            .drop_storage,
            .export_storage,
            => false,
        };
    }

    /// Does this intrinsic answer text (or a field run) that **nobody
    /// else owns** — storage the receiving register is responsible for
    /// — rather than a view into something that already has an owner?
    ///
    /// Stage 4's ownership walk asks, to decide whether a value needs
    /// releasing where it dies (docs/STRINGS.md).
    pub fn makesFreshStorage(self: Intrinsic) bool {
        return switch (self) {
            // `str` and `chr` allocate, as do the host services that
            // answer text; `pop` takes the element's storage out of its
            // container, which leaves it owned by nobody; `copy`
            // duplicates; `own_storage` is the taking of a copy itself.
            .str_value,
            .chr_code,
            .file_read,
            .key_read,
            .read_line,
            .env_get,
            .pop_value,
            .copy_object,
            .own_storage,
            => true,

            // Everything else that answers text answers a *view*: a
            // slice, an element, a field, a map key, the key-text slot,
            // a constant, a parameter.  The rest answer no text at all.
            .abs,
            .min,
            .max,
            .clamp,
            .sqrt,
            .floor,
            .ceil,
            .trunc,
            .compare_long_double,
            .len,
            .string_slice,
            .string_byte,
            .string_find_byte,
            .assert_true,
            .trap_message,
            .null_object,
            .none_value,
            .is_none,
            .optional_wrap,
            .optional_unwrap,
            .errored,
            .forget,
            .raise_error,
            .index_get,
            .index_set,
            .list_slice,
            .append_value,
            .append_ascii,
            .insert_value,
            .remove_entry,
            .has_key,
            .key_at,
            .value_at,
            .dim_size,
            .free_object,
            .give_object,
            .list_sort,
            .list_reverse,
            .list_find,
            .list_contains,
            .clear_object,
            .map_keys,
            .map_values,
            .map_get,
            .map_place,
            .array_fill,
            .parse_int,
            .parse_float,
            .ord_text,
            .print,
            .file_write,
            .file_exists,
            .file_append,
            .file_delete,
            .file_rename,
            .dir_list,
            .term_rows,
            .term_cols,
            .term_clear,
            .term_move,
            .term_style,
            .term_write,
            .term_flush,
            .key_text,
            .print_error,
            .clock_ms,
            .sleep_ms,
            .drop_storage,
            .export_storage,
            => false,
        };
    }

    /// Which argument is a **store into the receiver** — the one
    /// `libluce_rt` keeps rather than reads — or null when none is.
    ///
    /// Stage 4 asks so a literal in that position lands at the
    /// container's element width rather than at `int`, and so the
    /// copy-on-store hazard is seen before a later operand can free
    /// the text being stored.  The receiver's own shape is the
    /// caller's business: these positions are the list methods', and a
    /// map or a builder spelling the same name stores nothing here.
    pub fn storedArgument(self: Intrinsic) ?usize {
        return switch (self) {
            .append_value => 1,
            .insert_value => 2,

            .abs,
            .min,
            .max,
            .clamp,
            .sqrt,
            .floor,
            .ceil,
            .trunc,
            .compare_long_double,
            .len,
            .string_slice,
            .string_byte,
            .string_find_byte,
            .assert_true,
            .trap_message,
            .null_object,
            .none_value,
            .is_none,
            .optional_wrap,
            .optional_unwrap,
            .errored,
            .forget,
            .raise_error,
            .index_get,
            .index_set,
            .list_slice,
            .append_ascii,
            .pop_value,
            .remove_entry,
            .has_key,
            .key_at,
            .value_at,
            .dim_size,
            .free_object,
            .give_object,
            .copy_object,
            .list_sort,
            .list_reverse,
            .list_find,
            .list_contains,
            .clear_object,
            .map_keys,
            .map_values,
            .map_get,
            .map_place,
            .array_fill,
            .str_value,
            .parse_int,
            .parse_float,
            .chr_code,
            .ord_text,
            .print,
            .file_read,
            .file_write,
            .file_exists,
            .file_append,
            .file_delete,
            .file_rename,
            .dir_list,
            .term_rows,
            .term_cols,
            .term_clear,
            .term_move,
            .term_style,
            .term_write,
            .term_flush,
            .key_read,
            .key_text,
            .read_line,
            .print_error,
            .clock_ms,
            .sleep_ms,
            .env_get,
            .own_storage,
            .drop_storage,
            .export_storage,
            => null,
        };
    }
};

/// The words the runtime says back (`support/vocabulary.zig`).  Named
/// here because a program's instructions and its traps are one wire
/// surface; defined below both stages because `libluce_rt` speaks them
/// too and must not import a compiler stage to do it.
pub const ErrorCode = vocabulary.ErrorCode;
pub const FileAct = vocabulary.FileAct;
pub const TrapCode = vocabulary.TrapCode;

pub const Instruction = union(enum) {
    const_boolean: bool,
    /// A numeric constant, **carried at the widest member of its
    /// family** — the register's own type is the width it lands on.
    ///
    /// This is the language's own rule about literals, kept one stage
    /// further down: a number has no type until it meets one
    /// (docs/TYPES.md D3), and what it meets here is the register.
    /// Every value an `int` register can hold is exactly an `i64` and
    /// every value a `float` register can hold is exactly an `f64`, so
    /// nothing is lost by carrying them this way and no width needs an
    /// instruction of its own — which is why adding `byte`, `short`
    /// and `half` will add none either.  `06_mir/verify.zig` checks
    /// the value really does fit the register it lands in.
    const_long: i64,
    const_double: f64,
    const_string: u32,
    local_get: LocalId,
    local_set: struct { local: LocalId, value: Register },
    binary: Binary,
    unary: Unary,
    /// A numeric conversion: from the operand's type to this
    /// instruction's own result type.
    ///
    /// **There is no kind.**  A conversion already knows both ends —
    /// the operand carries the source and the register carries the
    /// destination — so a stored kind is information the verifier can
    /// derive and a second place for the two to disagree.  Seven types
    /// would have been up to forty-two kinds; there are none, and the
    /// instruction set got smaller rather than larger (docs/TYPES.md
    /// §3).
    convert: Register,
    struct_make: struct { layout: u32, fields: []Register },
    struct_get: struct { target: Register, layout: u32, field: u32 },
    struct_set: struct { target: Register, layout: u32, field: u32, value: Register },
    call: Call,
    intrinsic: IntrinsicCall,
    heap_new: HeapNew,
    object_bind: struct { local: LocalId, value: Register },
    object_unbind: struct { local: LocalId, value: Register },
    jump: BlockId,
    branch: struct { condition: Register, then_block: BlockId, else_block: BlockId },
    ret: ?Register,
    trap: TrapCode,
    /// Leave this frame with an error already in the channel — what
    /// `try` does on the failing side, and what follows `raise_error`.
    /// It carries nothing because the releases it owes stand in the
    /// block in front of it: `lowerReturn`'s three lines with one
    /// terminator changed (docs/FAILURE.md).
    unwind,

    pub const Binary = struct { op: BinaryOp, operand_type: Type, left: Register, right: Register };
    pub const Unary = struct { op: UnaryOp, operand: Register };
    pub const Call = struct { function: u32, arguments: []Register };
    pub const IntrinsicCall = struct { kind: Intrinsic, arguments: []Register };
    pub const HeapNew = struct { heap: u32, dims: []Register };

    pub fn isTerminator(self: Instruction) bool {
        return switch (self) {
            .jump, .branch, .ret, .trap, .unwind => true,
            else => false,
        };
    }
};

pub const Local = struct {
    name: []const u8,
    local_type: Type,
    /// True when this slot owns the string bytes and struct field runs
    /// it holds, and releases them when it dies (docs/STRINGS.md).
    /// False for a parameter, which borrows its caller's, and for the
    /// hidden slots a block-split spill uses, which borrow whatever
    /// they carry across the branch.
    ///
    /// Read by both engines to decide two things: that a frame's slot
    /// starts *empty* rather than at a shared zero, and that a trap
    /// unwinding past every release can still give the storage back.
    owns_storage: bool = false,
};

pub const Block = struct {
    items: []Register,
};

pub const Origin = struct {
    line: u32,
    column: u32,
};

pub const Function = struct {
    name: []const u8,
    parameter_count: u32,
    return_type: Type,
    /// Written `-> T!` or `-> !`: this function may come back errored
    /// instead of returning, and every caller has to say which of
    /// `try` and `catch` it means (docs/FAILURE.md).
    ///
    /// **Fallibility is an attribute of the function, not of its
    /// type.**  `return_type` is the `T`, unchanged and unwidened,
    /// which is what keeps `types.Type` out of this entirely — and
    /// what gives Luce Ok-wrapping for free: `return x` in a `-> T!`
    /// function returns `x`.
    fallible: bool = false,
    locals: []Local,
    instructions: []Instruction,
    result_types: []Type,
    blocks: []Block,
    origins: []Origin = &.{},
    source: []const u8 = "",
};

pub const Program = struct {
    arena: std.heap.ArenaAllocator,
    structs: []StructLayout = &.{},
    heap_types: []types.HeapType = &.{},
    functions: []Function = &.{},
    constants: []const []const u8 = &.{},
    entry_function: u32 = 0,

    pub fn deinit(self: *Program) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Drop debug info — the release build.  Traps in a stripped program
/// still name their functions, but carry no source lines, and the
/// encoded module is smaller.  Semantics never change: every check
/// and trap fires identically in both modes.
pub fn strip(program: *Program) void {
    for (program.functions) |*function| {
        function.origins = &.{};
        function.source = "";
    }
}
