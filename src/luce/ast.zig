//! The Luce abstract syntax tree.
//!
//! Nodes are arena-allocated by the parser and borrow spans into the
//! source buffer; the whole tree frees at once with the arena.  The
//! tree is untyped — semantic analysis attaches meaning.

const source_mod = @import("source.zig");

const Span = source_mod.Span;

// ---------------------------------------------------------------------------
// Types as written
// ---------------------------------------------------------------------------

/// A type as written in source; resolution happens in analysis.
/// Scalar and struct types are a bare name; composite types carry
/// arguments (`List(Int)`, `Map(String, Int)`), and an Array's shape
/// is spelled with `_` wildcards (`Array(Int, _, _)`), counted here.
pub const TypeName = struct {
    name: []const u8, // borrowed from source
    arguments: []TypeName = &.{},
    wildcards: u8 = 0,
    span: Span,
};

// ---------------------------------------------------------------------------
// Expressions
// ---------------------------------------------------------------------------

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
    logic_and,
    logic_or,
};

pub const UnaryOp = enum { negate, logic_not };

pub const Argument = struct {
    /// Field name for named construction (Point(x = 1)); null for
    /// positional call arguments.
    name: ?[]const u8,
    value: *Expression,
    span: Span,
};

pub const Expression = union(enum) {
    int_literal: struct { text: []const u8, span: Span },
    float_literal: struct { text: []const u8, span: Span },
    bool_literal: struct { value: bool, span: Span },
    string_literal: struct { decoded: []const u8, span: Span }, // arena-owned, unescaped
    name: struct { text: []const u8, span: Span },
    field: struct { target: *Expression, name: []const u8, span: Span },
    call: struct { callee: []const u8, arguments: []Argument, span: Span },
    binary: struct { op: BinaryOp, left: *Expression, right: *Expression, span: Span },
    unary: struct { op: UnaryOp, operand: *Expression, span: Span },
    /// new List(Int), new Map(String, Int), new Array(Int, 5, 5),
    /// new Builder().  Type arguments live in `type_name`; an Array's
    /// runtime dimension expressions live in `dims`.
    new_object: struct { type_name: TypeName, dims: []*Expression, span: Span },
    /// [1, 2, 3] — a List literal typed by its elements.
    list_literal: struct { elements: []*Expression, span: Span },
    /// target[i] or target[r, c].
    index: struct { target: *Expression, indices: []*Expression, span: Span },
    /// target[a:b]; either bound may be omitted.
    slice_range: struct { target: *Expression, start: ?*Expression, end: ?*Expression, span: Span },

    pub fn span(self: *const Expression) Span {
        return switch (self.*) {
            inline else => |node| node.span,
        };
    }
};

// ---------------------------------------------------------------------------
// Statements
// ---------------------------------------------------------------------------

/// The left side of an assignment: a name, one dotted field such as
/// point.x or output.position, or an indexed place such as xs[i] or
/// grid[r, c] (whose base may be any expression — objects mutate by
/// reference).
pub const Target = union(enum) {
    name: struct { text: []const u8, span: Span },
    field: struct { base: []const u8, field: []const u8, span: Span },
    index: struct { base: *Expression, indices: []*Expression, span: Span },

    pub fn span(self: *const Target) Span {
        return switch (self.*) {
            inline else => |node| node.span,
        };
    }
};

pub const Statement = union(enum) {
    let: struct { name: []const u8, annotation: ?TypeName, value: *Expression, span: Span },
    variable: struct { name: []const u8, annotation: ?TypeName, value: *Expression, span: Span },
    assign: struct { target: Target, value: *Expression, span: Span },
    conditional: struct {
        condition: *Expression,
        then_block: Block,
        /// elif chains become nested conditionals in this block.
        else_block: ?Block,
        span: Span,
    },
    while_loop: struct { condition: *Expression, body: Block, span: Span },
    for_range: struct {
        name: []const u8,
        start: *Expression,
        end: *Expression,
        body: Block,
        span: Span,
    },
    /// for x in xs: — list and rank-1 array elements, or map keys.
    for_each: struct {
        name: []const u8,
        iterable: *Expression,
        body: Block,
        span: Span,
    },
    return_statement: struct { value: ?*Expression, span: Span },
    break_statement: struct { span: Span },
    continue_statement: struct { span: Span },
    expression: struct { value: *Expression, span: Span },
};

pub const Block = struct {
    statements: []Statement,
    span: Span,
};

// ---------------------------------------------------------------------------
// Declarations
// ---------------------------------------------------------------------------

pub const Field = struct {
    name: []const u8,
    type_name: TypeName,
    span: Span,
};

pub const StructDecl = struct {
    name: []const u8,
    fields: []Field,
    functions: []FuncDecl,
    span: Span,
};

pub const Parameter = struct {
    name: []const u8,
    type_name: TypeName,
    span: Span,
};

pub const FuncDecl = struct {
    name: []const u8,
    parameters: []Parameter,
    return_type: ?TypeName,
    body: Block,
    span: Span,
};

pub const Program = struct {
    structs: []StructDecl,
    functions: []FuncDecl,
};
