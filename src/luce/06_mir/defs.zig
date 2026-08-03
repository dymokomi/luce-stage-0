//! IR type, enum, and struct definitions.
//! All data types for the Luce intermediate representation.

const std = @import("std");
const types = @import("../support/types.zig");

const Allocator = std.mem.Allocator;
const Type = types.Type;
const StructLayout = types.StructLayout;
const Port = types.Port;

pub const Register = u32;
pub const BlockId = u32;
pub const LocalId = u32;

pub const BinaryOp = enum {
    add,
    subtract,
    multiply,
    divide,
    remainder,
    equal,
    not_equal,
    less,
    less_equal,
    greater,
    greater_equal,

    pub fn isComparison(self: BinaryOp) bool {
        return switch (self) {
            .equal, .not_equal, .less, .less_equal, .greater, .greater_equal => true,
            else => false,
        };
    }
};

pub const UnaryOp = enum { negate, logic_not };

pub const ConvertKind = enum { int_to_float, float_to_int };

pub const Intrinsic = enum {
    abs,
    min,
    max,
    clamp,
    sqrt,
    floor,
    ceil,
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
    arg_count,
    arg_get,
    term_rows,
    term_cols,
    term_clear,
    term_move,
    term_style,
    term_write,
    term_flush,
    key_read,
    key_text,
    /// The two halves of value storage (docs/STRINGS.md).  A String's
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
};

pub const TrapCode = enum {
    integer_overflow,
    divide_by_zero,
    conversion_range,
    assertion_failed,
    explicit_trap,
    missing_return,
    step_budget_exhausted,
    call_depth_exceeded,
    string_bounds,
    string_boundary,
    host_unavailable,
    argument_bounds,
    file_read_failed,
    index_bounds,
    key_missing,
    empty_collection,
    use_after_free,
    null_object,
    bad_codepoint,
    not_owned,

    pub fn message(self: TrapCode) []const u8 {
        return switch (self) {
            .integer_overflow => "integer overflow",
            .divide_by_zero => "division by zero",
            .conversion_range => "conversion out of range",
            .assertion_failed => "assertion failed",
            .explicit_trap => "explicit trap",
            .missing_return => "function ended without returning a value",
            .step_budget_exhausted => "evaluation step budget exhausted",
            .call_depth_exceeded => "call depth exceeded",
            .string_bounds => "string index out of bounds",
            .string_boundary => "string slice splits a UTF-8 sequence",
            .host_unavailable => "host service unavailable",
            .argument_bounds => "program argument out of range",
            .file_read_failed => "file read failed",
            .index_bounds => "index out of bounds",
            .key_missing => "key not found in map",
            .empty_collection => "pop from an empty list",
            .use_after_free => "object used after free",
            .null_object => "null object reference",
            .bad_codepoint => "invalid character code",
            .not_owned => "object is owned by a container",
        };
    }
};

pub const Instruction = union(enum) {
    const_boolean: bool,
    const_int: i64,
    const_float: f64,
    const_data: struct { constant: u32, data_type: Type },
    local_get: LocalId,
    local_set: struct { local: LocalId, value: Register },
    input_load: u32,
    output_store: struct { port: u32, value: Register },
    binary: Binary,
    unary: Unary,
    convert: struct { kind: ConvertKind, operand: Register },
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

    pub const Binary = struct { op: BinaryOp, operand_type: Type, left: Register, right: Register };
    pub const Unary = struct { op: UnaryOp, operand: Register };
    pub const Call = struct { function: u32, arguments: []Register };
    pub const IntrinsicCall = struct { kind: Intrinsic, arguments: []Register };
    pub const HeapNew = struct { heap: u32, dims: []Register };

    pub fn isTerminator(self: Instruction) bool {
        return switch (self) {
            .jump, .branch, .ret, .trap => true,
            else => false,
        };
    }
};

pub const Local = struct {
    name: []const u8,
    local_type: Type,
    /// True when this slot owns the String bytes and struct field runs
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
    inputs: []Port = &.{},
    outputs: []Port = &.{},
    reads: []u32 = &.{},
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
