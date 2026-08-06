//! The Luce abstract syntax tree.
//!
//! Nodes are arena-allocated by the parser and borrow spans into the
//! source buffer; the whole tree frees at once with the arena.  The
//! tree is untyped — semantic analysis attaches meaning.

const source_mod = @import("../01_source.zig");

const Span = source_mod.Span;

// ---------------------------------------------------------------------------
// Types as written
// ---------------------------------------------------------------------------

/// A type as written in source; resolution happens in analysis.
/// Scalar and struct types are a bare name; composite types carry
/// arguments (`list(long)`, `map(string, long)`), and an array's shape
/// is spelled with `_` wildcards (`array(long, _, _)`), counted here.
/// A trailing `?` makes it optional; there is no second level, so one
/// flag says all there is to say.
pub const TypeName = struct {
    name: []const u8, // borrowed from source
    arguments: []TypeName = &.{},
    wildcards: u8 = 0,
    optional: bool = false,
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
    /// `//` — floor division (docs/NUMERICS.md).
    floor_divide,
    /// `%` — a modulus, taking the sign of the divisor.
    modulo,
    equal,
    not_equal,
    less,
    less_equal,
    greater,
    greater_equal,
    /// The bit set (docs/BITWISE.md): Go's precedence, integers only,
    /// with the shift count as the one thing that traps.
    bit_and,
    bit_or,
    bit_xor,
    shift_left,
    shift_right,
    logic_and,
    logic_or,
    /// `a else b` — the value of `a` when it is there, `b` when it is
    /// not.  Luce has no truthiness and no ternary, so `else` can mean
    /// "otherwise" without ambiguity and no new token is needed
    /// (docs/FAILURE.md).
    coalesce,
    /// `a catch b` — the value of `a` when the call succeeded, `b`
    /// when it raised.  A different act from `else`, and so a
    /// different word: `catch` discards a reason on purpose, and is
    /// greppable for it (docs/FAILURE.md).
    catch_error,
};

pub const UnaryOp = enum {
    negate,
    logic_not,
    /// `~x` — two's complement, so it is `-x - 1` (docs/BITWISE.md).
    bit_not,
};

pub const Argument = struct {
    /// The name the argument was written with — a struct field in a
    /// construction (Point(x = 1)) or a parameter in a call
    /// (find(s, start = 2), docs/ARGS.md); null for a positional
    /// argument.  The span covers the name when there is one.
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
pub const Call = struct {
    callee: []const u8,
    arguments: []Argument,
    span: Span,
    /// Where the call came from.  Almost every one was written by the
    /// reader; a few are the compiler's own lowering of some other
    /// syntax, and a diagnostic about one of those has to talk about
    /// the syntax rather than about the call — the reader never typed
    /// the callee and cannot be asked to fix it.
    origin: CallOrigin = .written,
};

pub const CallOrigin = enum {
    written,
    /// `f"{x:.2f}"`, lowered to `strings.format_float(x, 2)`.
    format_spec,
};
pub const Binary = struct { op: BinaryOp, left: *Expression, right: *Expression, span: Span };
pub const Unary = struct { op: UnaryOp, operand: *Expression, span: Span };
pub const NewObject = struct { type_name: TypeName, dims: []*Expression, span: Span };
pub const ListLiteral = struct { elements: []*Expression, span: Span };
pub const Index = struct { target: *Expression, indices: []*Expression, span: Span };
pub const SliceRange = struct { target: *Expression, start: ?*Expression, end: ?*Expression, span: Span };
pub const Method = struct { target: *Expression, name: []const u8, arguments: []Argument, span: Span };
pub const Give = struct { operand: *Expression, span: Span };
pub const Copy = struct { operand: *Expression, span: Span };
pub const NoneLiteral = struct { span: Span };
pub const Try = struct { operand: *Expression, span: Span };

pub const Expression = union(enum) {
    int_literal: Literal,
    float_literal: Literal,
    bool_literal: BoolLiteral,
    string_literal: StringLiteral,
    /// `none` — the absent value.  It has no type of its own; the
    /// place it is written into supplies one.
    none_literal: NoneLiteral,
    name: Name,
    field: FieldAccess,
    call: Call,
    binary: Binary,
    unary: Unary,
    /// new list(long), new map(string, long), new array(long, 5, 5),
    /// new builder().  Type arguments live in `type_name`; an array's
    /// runtime dimension expressions live in `dims`.
    new_object: NewObject,
    /// [1, 2, 3] — a list literal typed by its elements.
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
    /// try CALL — hand the caller whatever the call raised, releasing
    /// what this frame owns on the way out (docs/FAILURE.md).
    try_call: Try,

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

/// `name_span` on every declaration below is the span of the **name
/// alone**, beside the `span` of the whole declaration.  A diagnostic
/// about a name — reserved, duplicate, already a declaration — points
/// at the name; a diagnostic about the declaration points at the
/// declaration.  With one span they all pointed at the declaration,
/// so `let print = 3` underlined `= 3` as part of a complaint about
/// the word `print`, and `func term_rows():` underlined the `func`.
pub const Binding = struct {
    name: []const u8,
    name_span: Span,
    annotation: ?TypeName,
    value: *Expression,
    span: Span,
};
pub const Variable = struct {
    name: []const u8,
    name_span: Span,
    annotation: ?TypeName,
    value: ?*Expression,
    span: Span,
};
/// `place = value`, or a compound assignment `place OP= value` when
/// `compound` is set (which reads the place, applies OP, stores back —
/// the place is evaluated once).  Compound forms are value-only
/// arithmetic; OP is add/subtract/multiply/divide/floor_divide/modulo.
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
    /// `for key, value in ...:` — the second binding: a map's value or
    /// a list/array element's index.  Null for the single-name form.
    value_name: ?[]const u8 = null,
    iterable: *Expression,
    body: Block,
    span: Span,
};
/// `return`, `return x`, or `return a, b` — one expression per value
/// the function answers (docs/RETURNS.md).  Empty is a bare `return`.
pub const Return = struct { values: []*Expression, span: Span };

/// `let low, high = minmax(xs)` — a destructuring bind.
///
/// Two or more names, **one** keyword governing all of them, and a
/// call on the right whose arity matches.  It is one of exactly two
/// places a multi-valued call may stand; the other is a statement of
/// its own (docs/RETURNS.md).
pub const Destructure = struct {
    names: []Name,
    mutable: bool,
    value: *Expression,
    span: Span,
};
/// A statement and an indented handler that runs where the one call
/// in it raised — the statement form of `catch`, for a recovery that
/// is more than one expression.
///
/// Two shapes reach here and no others: a call written as a
/// statement, and a plain assignment whose value is a call.  Both
/// guard exactly *one* call, so "which statement failed" has one
/// answer — which is what separates this from the Python
/// `try:`/`except:` block docs/FAILURE.md refuses.  A `let` is not
/// among them: the handler would have to supply the value the name
/// binds, and only `catch EXPR` can say that.
///
/// `binding` is the name `catch reason:` gives the handler to read the
/// error's words through — null for the plain `catch:` (`docs/FAILURE
/// .md`).  It is scoped to the handler and nowhere else.
pub const Guarded = struct { attempt: *Statement, binding: ?Name, handler: Block, span: Span };
pub const Marker = struct { span: Span };
pub const ExpressionStatement = struct { value: *Expression, span: Span };

pub const Statement = union(enum) {
    let: Binding,
    /// var name: Type with no value is a late declaration: the slot
    /// holds the type's zero value until assigned (OWNERSHIP.md S40).
    variable: Variable,
    /// let a, b = f() / var a, b = f() — one keyword, two or more
    /// names, one call.
    destructure: Destructure,
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
    /// call catch: — the handler runs only where the call raised.
    guarded: Guarded,

    pub fn span(self: *const Statement) Span {
        return switch (self.*) {
            inline else => |node| node.span,
        };
    }
};

pub const Block = struct {
    statements: []Statement,
    span: Span,
};

// ---------------------------------------------------------------------------
// Declarations
// ---------------------------------------------------------------------------

/// The visibility a declaration wrote, three states so inert
/// explicitness survives to be reasoned about (docs/VISIBILITY.md
/// D13): `none` is an unmarked declaration — public by default —
/// `public` a restated default, `private` the marked case.  A struct
/// region label dissolves onto its members' markers here in stage 3;
/// stage 4 never knows a region existed (D15).
pub const Visibility = enum { none, public, private };

pub const Field = struct {
    name: []const u8,
    name_span: Span,
    type_name: TypeName,
    /// `= EXPRESSION` after the type: the field's default, the same
    /// clause a parameter takes and the same folder behind it
    /// (docs/ARGS.md D8).  Null for a required field.
    default: ?*Expression = null,
    visibility: Visibility = .none,
    span: Span,
};

pub const StructDecl = struct {
    name: []const u8,
    name_span: Span,
    fields: []Field,
    functions: []FuncDecl,
    visibility: Visibility = .none,
    span: Span,
};

/// How a parameter receives objects: borrowed (the default — the
/// callee may read and mutate contents but not keep) or given (the
/// callee takes ownership; the call site must say `give`/`copy` or
/// pass something fresh).  See OWNERSHIP.md S11-S15.
pub const ParameterMode = enum { borrow, give };

/// Whether a parameter is the method's receiver, and if so whether the
/// method writes it back (docs/METHODS.md).
///
/// `self` and `var self` carry no type: inside `struct Point` the
/// receiver can be nothing but a `Point`, so there is nothing to
/// resolve and `type_name` below is not read for one.  Stage 4 fills
/// the type in from the enclosing struct.
pub const Receiver = enum { not, reads, writes };

pub const Parameter = struct {
    name: []const u8,
    name_span: Span,
    mode: ParameterMode = .borrow,
    /// `.not` for every ordinary parameter; `.reads` for `self` and
    /// `.writes` for `var self`.  When it is not `.not`, `type_name`
    /// is a placeholder nothing reads — the enclosing struct is the
    /// type, and stage 4 is where that is known.
    receiver: Receiver = .not,
    type_name: TypeName,
    /// `= EXPRESSION` after the type: the parameter's default, folded
    /// to a compile-time constant by stage 4 (docs/ARGS.md D2).  Null
    /// for a required parameter.
    default: ?*Expression = null,
    span: Span,
};

pub const FuncDecl = struct {
    name: []const u8,
    name_span: Span,
    parameters: []Parameter,
    /// What the function answers, in order.  Empty answers nothing;
    /// one is `-> T`; two or more is a **return shape**, `-> (A, B)`
    /// — which is a shape a signature has and not a type a program
    /// can name (docs/RETURNS.md).
    returns: []TypeName = &.{},
    /// Written `-> T!` or `-> !`.  Fallibility is an attribute of the
    /// function, never part of what it returns: there is no `T!` type
    /// to resolve, so nothing downstream of here grows a case for one
    /// (docs/FAILURE.md).
    fallible: bool = false,
    body: Block,
    visibility: Visibility = .none,
    span: Span,

    /// The span of everything after `->`, for a diagnostic about the
    /// claim rather than about the declaration.  Null when the
    /// function answers nothing.
    pub fn returnsSpan(self: FuncDecl) ?Span {
        if (self.returns.len == 0) return null;
        return .{
            .start = self.returns[0].span.start,
            .end = self.returns[self.returns.len - 1].span.end,
        };
    }
};

/// An import, in either namespace: `import geo` binds the sibling
/// file geo.luc, `import std.math` binds the standard library's math.
/// `name` is the module's name and the namespace it takes at the call
/// site both — the two spellings differ only in `origin`.
pub const Import = struct {
    name: []const u8,
    origin: source_mod.Origin,
    span: Span,
};

/// let name = expression at file scope: a compile-time constant of a
/// value type, usable anywhere in the module and through imports.
pub const ConstDecl = struct {
    name: []const u8,
    name_span: Span,
    annotation: ?TypeName,
    value: *Expression,
    visibility: Visibility = .none,
    span: Span,
};

pub const Program = struct {
    imports: []Import,
    constants: []ConstDecl,
    structs: []StructDecl,
    functions: []FuncDecl,
};
