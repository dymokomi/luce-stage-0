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
    /// A `!` written inside `task(...)` — the spawned function's own
    /// fallibility, travelling with the call the task carries
    /// (docs/THREADS.md).  Only `task` takes one; it is not the `!`
    /// after a return type, which the declaration parser reads.
    fallible: bool = false,
    /// What a `func(...) -> R` answers, null when it answers nothing
    /// (docs/FUNCTIONS.md S2).  Set only on a function type, whose
    /// `name` is the keyword `func` — a word no declaration can take,
    /// so nothing else can wear this shape.  Its parameter types are
    /// `arguments`, because that is what they are.
    result: ?*TypeName = null,
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

/// EXPRESSION(arguments) — **the call suffix**, beside the index and
/// the field access (docs/FUNCTIONS.md): it calls whatever value the
/// expression in front of it answers.
///
/// The two forms whose head *names a declaration* never reach here,
/// because only their written text can resolve one: a bare name is
/// `Call` and `receiver.method(...)` is `Method`.  What is left is
/// exactly the set the grammar used to have no room for —
/// `chooser()(5)`, `m["a"](1)`, `(f)(x)` — and every one of them is a
/// call through a function value.
pub const ValueCall = struct { callee: *Expression, arguments: []Argument, span: Span };

pub const CallOrigin = enum {
    written,
    /// `f"{x:.2f}"`, lowered to `strings.format_float(x, 2)`.
    format_spec,
};
pub const Binary = struct { op: BinaryOp, left: *Expression, right: *Expression, span: Span };
pub const Unary = struct { op: UnaryOp, operand: *Expression, span: Span };
pub const NewObject = struct { type_name: TypeName, dims: []*Expression, span: Span };
pub const ListLiteral = struct { elements: []*Expression, span: Span };
/// One `key: value` pair in a map literal.  Both expressions and the
/// pair itself are arena-owned with the program.
pub const MapEntry = struct { key: *Expression, value: *Expression, span: Span };
/// `{key: value, ...}` — a non-empty map literal.  Empty maps are
/// constructed with `new map(K, V)`, where their types have somewhere
/// to be written (docs/CONSTANTS.md R-B).
pub const MapLiteral = struct { entries: []MapEntry, span: Span };
pub const Index = struct { target: *Expression, indices: []*Expression, span: Span };
pub const SliceRange = struct { target: *Expression, start: ?*Expression, end: ?*Expression, span: Span };
pub const Method = struct { target: *Expression, name: []const u8, arguments: []Argument, span: Span };
pub const NoneLiteral = struct { span: Span };
pub const Try = struct { operand: *Expression, span: Span };
/// `spawn f(args)` — the call is *not* made here; it is handed to a
/// worker with a runtime of its own (docs/THREADS.md D2).  `call` is
/// always a `.call` or a `.method` node, because the parser refuses
/// anything else in front of it; which of the two is legal is stage
/// 4's question, since only stage 4 can tell `Struct.helper(x)` from
/// `value.method(x)`.
pub const Spawn = struct { call: *Expression, span: Span };
/// `(a, b) -> expr` — a **lambda** (docs/FUNCTIONS.md S3): a
/// parenthesized parameter list, an arrow, one expression.
///
/// The parameters are bare names and carry no types: a lambda has none
/// of its own, and takes them from the function type it lands on — the
/// rule the language already lives by for numbers, applied to one more
/// literal.  The body is one expression because a body with room for
/// statements immediately wants the enclosing scope, which is capture.
pub const Lambda = struct { parameters: []Name, body: *Expression, span: Span };

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
    /// callee(arguments) — a call suffix on an expression that is not
    /// a bare name and not `receiver.method`, so its head cannot name
    /// a declaration and the value it answers is what is called.
    value_call: ValueCall,
    binary: Binary,
    unary: Unary,
    /// new list(long), new map(string, long), new array(long, 5, 5),
    /// new builder().  Type arguments live in `type_name`; an array's
    /// runtime dimension expressions live in `dims`.
    new_object: NewObject,
    /// [1, 2, 3] — a list literal typed by its elements.
    list_literal: ListLiteral,
    /// {key: value, ...} — a map literal typed by its entries.
    map_literal: MapLiteral,
    /// target[i] or target[r, c].
    index: Index,
    /// target[a:b]; either bound may be omitted.
    slice_range: SliceRange,
    /// target.name(arguments) — a builtin method on a value, or a
    /// namespaced call when the target chain names a struct/module
    /// (the analyzer decides; the parser cannot know).
    method: Method,
    /// try CALL — hand the caller whatever the call raised, releasing
    /// what this frame owns on the way out (docs/FAILURE.md).
    try_call: Try,
    /// spawn CALL — run the call on a worker and answer the `task`
    /// that owns it (docs/THREADS.md D3).
    spawn: Spawn,
    /// (a, b) -> expr — a lambda, which stage 4 turns into a
    /// compiler-named top-level function (docs/FUNCTIONS.md D2).
    lambda: Lambda,

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
/// `low, high = minmax(xs)` — a multi-return assignment into existing
/// mutable names.  It is deliberately narrower than `Assign`: every
/// target is a bare name, there are at least two, and there is no
/// compound form.
pub const AssignMany = struct { names: []Name, value: *Expression, span: Span };
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
/// call on the right whose arity matches.  A multi-valued call may
/// also be discarded as a statement or assigned to existing vars.
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
/// Three shapes reach here: a call written as a statement, a plain
/// assignment whose value is a call, and an existing-name
/// multi-return assignment.  Each guards exactly *one* call, so
/// "which statement failed" has one answer — which is what separates
/// this from the Python `try:`/`except:` block docs/FAILURE.md refuses.
/// A `let` is not among them: the handler would have to supply the
/// value the name binds, and only `catch EXPR` can say that.
///
/// `binding` is the name `catch reason:` gives the handler to read the
/// error's words through — null for the plain `catch:` (`docs/FAILURE
/// .md`).  It is scoped to the handler and nowhere else.
pub const Guarded = struct { attempt: *Statement, binding: ?Name, handler: Block, span: Span };

/// One arm of a `match`: a bare member name and the block it opens
/// (docs/ENUMS.md R3).  The scrutinee's type is known and the arm
/// namespace is closed, so the name needs no qualification.
///
/// `bindings` is the union extension (docs/UNION.md D5): a payload arm
/// is written `circle(radius):` — the member's name, then the fields it
/// binds, each by the field's own name.  Empty for a bare arm, which is
/// the whole of what an enum's arms may be and is also legal on a
/// payload-carrying union member — the arm that only cares which one.
pub const MatchArm = struct {
    name: []const u8,
    name_span: Span,
    bindings: []Name = &.{},
    body: Block,
    span: Span,
};

/// `match expr:` — dispatch over an enum (docs/ENUMS.md R1).  Arms are
/// member names in the order they were written; `else_block` is the
/// optional `else:`, and without one stage 4 requires every member.
pub const Match = struct {
    scrutinee: *Expression,
    arms: []MatchArm,
    else_block: ?Block,
    /// The span of `else`, for a diagnostic about the arm that catches
    /// everything.  Null when there is none.
    else_span: ?Span = null,
    span: Span,
};

pub const Marker = struct { span: Span };
pub const ExpressionStatement = struct { value: *Expression, span: Span };

pub const Statement = union(enum) {
    let: Binding,
    /// var name: Type with no value is a late declaration: the slot
    /// holds the type's zero value until assigned (MEMORY.md).
    variable: Variable,
    /// let a, b = f() / var a, b = f() — one keyword, two or more
    /// names, one call.
    destructure: Destructure,
    assign: Assign,
    /// a, b = f() — one call replacing two or more existing vars.
    assign_many: AssignMany,
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
    /// match m: — one arm per member of the scrutinee's enum.
    match: Match,

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

/// Value or reference (docs/MEMORY.md D1).  A `struct` is a value type
/// (copies); a `class` is a reference type (shared, ARC-freed).  The two
/// share every bit of declaration grammar, so they share this node and
/// differ only in the kind the header keyword sets.
pub const TypeKind = enum { value, reference };

pub const StructDecl = struct {
    name: []const u8,
    name_span: Span,
    fields: []Field,
    functions: []FuncDecl,
    /// Interfaces this struct explicitly promises to implement.  The
    /// parser keeps the written type names; stage 4 checks the promise
    /// against the completed method table.
    interfaces: []TypeName = &.{},
    visibility: Visibility = .none,
    /// `struct` → value, `class` → reference.  Ownership work reads this
    /// once ARC lands; today it is recorded and otherwise inert.
    kind: TypeKind = .value,
    span: Span,
};

/// A method contract inside an interface.  Unlike a function declaration,
/// this has no body: the interface says what an implementer must provide.
pub const InterfaceMethod = struct {
    name: []const u8,
    name_span: Span,
    parameters: []Parameter,
    returns: []TypeName,
    fallible: bool = false,
    span: Span,
};

/// `interface Name:` — a nominal set of method contracts.  Interfaces are
/// intentionally small in this first version: they have methods only,
/// cannot inherit from one another, and are implemented explicitly by a
/// struct's `: Name` list.
pub const InterfaceDecl = struct {
    name: []const u8,
    name_span: Span,
    methods: []InterfaceMethod,
    visibility: Visibility = .none,
    span: Span,
};

/// One member of an enum: a snake_case name and, where the
/// declaration wrote one, the constant integer expression that gives
/// it its value (docs/ENUMS.md D1).  An unvalued member takes the
/// previous member's value plus one; an unvalued first member is 0.
pub const EnumMember = struct {
    name: []const u8,
    name_span: Span,
    value: ?*Expression = null,
    span: Span,
};

/// `enum Method:` / `enum Method(byte):` — a set of named constants at
/// one integer width, with the methods and namespace functions a
/// struct has (docs/ENUMS.md D1, D2, D7).
///
/// `backing` is the width written in parentheses after the name, null
/// for the default `int`.  It is a `TypeName` rather than a resolved
/// width because stage 3 resolves nothing: `enum Method(Point):` is a
/// stage-4 diagnostic about a width, not a parse error about a token.
pub const EnumDecl = struct {
    name: []const u8,
    name_span: Span,
    backing: ?TypeName = null,
    members: []EnumMember,
    functions: []FuncDecl,
    visibility: Visibility = .none,
    span: Span,
};

/// One member of a union: a snake_case name and, where the member
/// carries a payload, the parenthesized field list it was declared
/// with (docs/UNION.md D1).  Fields are named always — a positional
/// payload is refused where it is written — and take the same `= EXPR`
/// default clause a struct field takes (D4).  A bare member has an
/// empty list; `circle()` is refused, so empty never means "wrote
/// parentheses".
pub const UnionMember = struct {
    name: []const u8,
    name_span: Span,
    fields: []Field = &.{},
    span: Span,
};

/// `union Shape:` — one of a closed set of members, at least one of
/// which carries a payload (docs/UNION.md D1, D2 — the all-bare form
/// is an enum, and stage 4 says so).  Takes the methods and namespace
/// functions a struct takes (D17).
pub const UnionDecl = struct {
    name: []const u8,
    name_span: Span,
    members: []UnionMember,
    functions: []FuncDecl,
    visibility: Visibility = .none,
    span: Span,
};

pub const Parameter = struct {
    name: []const u8,
    name_span: Span,
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
    /// Written `static func` inside a struct or enum.  A plain member
    /// function is a method whose `self` is implied; the parser does
    /// not synthesize that receiver into `parameters` (docs/SELF.md).
    is_static: bool = false,
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
/// file geo.luc, `import std.math` binds the standard library's math,
/// and `import geo.shapes` binds geo/shapes.luc under the project
/// root (docs/PACKAGES.md D2).  `name` is the module as written after
/// `import`, without the std head — "geo", "geo.shapes", "math" —
/// and `binding` is the namespace call sites use: the last segment,
/// or the alias when the import says `as`.
pub const Import = struct {
    name: []const u8,
    binding: []const u8,
    origin: source_mod.Origin,
    span: Span,
};

/// const name = expression at file scope: a compile-time value or
/// frozen container, usable anywhere in the module and through imports.
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
    interfaces: []InterfaceDecl = &.{},
    enums: []EnumDecl = &.{},
    unions: []UnionDecl = &.{},
    functions: []FuncDecl,
};
