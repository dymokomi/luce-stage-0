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

/// Payload types are named so analysis code can take them as real
/// parameters instead of `anytype` — a signature should say what it
/// receives.
pub const Literal = struct { text: []const u8, span: Span };
pub const BoolLiteral = struct { value: bool, span: Span };
pub const StringLiteral = struct { decoded: []const u8, span: Span }; // arena-owned, unescaped
pub const Name = struct { text: []const u8, span: Span };
pub const FieldAccess = struct { target: *Expression, name: []const u8, span: Span };
pub const Call = struct { callee: []const u8, arguments: []Argument, span: Span };
pub const Binary = struct { op: BinaryOp, left: *Expression, right: *Expression, span: Span };
pub const Unary = struct { op: UnaryOp, operand: *Expression, span: Span };
pub const NewObject = struct { type_name: TypeName, dims: []*Expression, span: Span };
pub const ListLiteral = struct { elements: []*Expression, span: Span };
pub const Index = struct { target: *Expression, indices: []*Expression, span: Span };
pub const SliceRange = struct { target: *Expression, start: ?*Expression, end: ?*Expression, span: Span };
pub const Method = struct { target: *Expression, name: []const u8, arguments: []Argument, span: Span };
pub const Give = struct { operand: *Expression, span: Span };
pub const Copy = struct { operand: *Expression, span: Span };

pub const Expression = union(enum) {
    int_literal: Literal,
    float_literal: Literal,
    bool_literal: BoolLiteral,
    string_literal: StringLiteral,
    name: Name,
    field: FieldAccess,
    call: Call,
    binary: Binary,
    unary: Unary,
    /// new List(Int), new Map(String, Int), new Array(Int, 5, 5),
    /// new Builder().  Type arguments live in `type_name`; an Array's
    /// runtime dimension expressions live in `dims`.
    new_object: NewObject,
    /// [1, 2, 3] — a List literal typed by its elements.
    list_literal: ListLiteral,
    /// target[i] or target[r, c].
    index: Index,
    /// target[a:b]; either bound may be omitted.
    slice_range: SliceRange,
    /// target.name(arguments) — a builtin method on a value, or a
    /// namespaced call when the target chain names a struct/module
    /// (the analyzer decides; the parser cannot know).
    method: Method,
    /// give x — transfer ownership; x is poisoned afterwards (S10).
    give: Give,
    /// copy x — a deep, independent duplicate (S31).
    copy: Copy,

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
pub const NameTarget = struct { text: []const u8, span: Span };
pub const FieldTarget = struct { base: []const u8, field: []const u8, span: Span };
pub const IndexTarget = struct { base: *Expression, indices: []*Expression, span: Span };
/// A nested place `root.a.b`, `cells[0].value` — a field access whose
/// target is not a plain name, so it can't be the simple `name.field`
/// form.  Carries the whole field expression; the analyzer reads the
/// chain once and rebuilds it, writing the innermost object element or
/// the root local.  (`base[i]` with a complex base is still IndexTarget.)
pub const ChainTarget = struct { place: *Expression, span: Span };

pub const Target = union(enum) {
    name: NameTarget,
    field: FieldTarget,
    index: IndexTarget,
    chain: ChainTarget,

    pub fn span(self: *const Target) Span {
        return switch (self.*) {
            inline else => |node| node.span,
        };
    }
};

pub const Binding = struct { name: []const u8, annotation: ?TypeName, value: *Expression, span: Span };
pub const Variable = struct { name: []const u8, annotation: ?TypeName, value: ?*Expression, span: Span };
/// `place = value`, or a compound assignment `place OP= value` when
/// `compound` is set (which reads the place, applies OP, stores back —
/// the place is evaluated once).  Compound forms are value-only
/// arithmetic; OP is add/subtract/multiply/divide/remainder.
pub const Assign = struct { target: Target, compound: ?BinaryOp = null, value: *Expression, span: Span };
pub const Conditional = struct {
    condition: *Expression,
    then_block: Block,
    /// elif chains become nested conditionals in this block.
    else_block: ?Block,
    span: Span,
};
pub const While = struct { condition: *Expression, body: Block, span: Span };
pub const ForRange = struct {
    name: []const u8,
    start: *Expression,
    end: *Expression,
    body: Block,
    span: Span,
};
pub const ForEach = struct {
    name: []const u8,
    /// `for key, value in ...:` — the second binding: a Map's value or
    /// a List/Array element's index.  Null for the single-name form.
    value_name: ?[]const u8 = null,
    iterable: *Expression,
    body: Block,
    span: Span,
};
pub const Return = struct { value: ?*Expression, span: Span };
pub const Marker = struct { span: Span };
pub const ExpressionStatement = struct { value: *Expression, span: Span };

pub const Statement = union(enum) {
    let: Binding,
    /// var name: Type with no value is a late declaration: the slot
    /// holds the type's zero value until assigned (OWNERSHIP.md S40).
    variable: Variable,
    assign: Assign,
    conditional: Conditional,
    while_loop: While,
    for_range: ForRange,
    /// for x in xs: — list and rank-1 array elements, or map keys.
    for_each: ForEach,
    return_statement: Return,
    break_statement: Marker,
    continue_statement: Marker,
    expression: ExpressionStatement,
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

/// How a parameter receives objects: borrowed (the default — the
/// callee may read and mutate contents but not keep) or given (the
/// callee takes ownership; the call site must say `give`/`copy` or
/// pass something fresh).  See OWNERSHIP.md S11-S15.
pub const ParameterMode = enum { borrow, give };

pub const Parameter = struct {
    name: []const u8,
    mode: ParameterMode = .borrow,
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

/// import name — binds the sibling file name.luc as a namespace.
pub const Import = struct {
    name: []const u8,
    span: Span,
};

/// let name = expression at file scope: a compile-time constant of a
/// value type, usable anywhere in the module and through imports.
pub const ConstDecl = struct {
    name: []const u8,
    annotation: ?TypeName,
    value: *Expression,
    span: Span,
};

pub const Program = struct {
    imports: []Import,
    constants: []ConstDecl,
    structs: []StructDecl,
    functions: []FuncDecl,
};
