//! The typed tree — the value that crosses the check/lower seam.
//!
//! One node per thing a checked function body can *be*, resolved and
//! typed the way stage 4 decides it and structured the way the reader
//! wrote it.  `05_hir.zig`'s header lists the six couplings this tree
//! dissolves; this file is the vocabulary and holds no behavior at all
//! beyond the accessors and the one computed property (`provenance`).
//!
//! **How it lands.**  The single-atom seam was measured impossible, so
//! the tree arrives family by family: `04_semantics/builder.zig` keeps
//! emitting exactly what it emits today and *additionally* records each
//! converted expression's node on the `Typed` it answers, which makes
//! every landing byte-identical on the MIR by construction.  The final
//! flip — a separate `lower` pass consuming this tree — happens only
//! when the whole tree is recorded and no `Typed.node` is ever null.
//! Until then a node's children may be missing where they would come
//! from an unconverted family, and the recording arm leaves the whole
//! node null rather than record a broken tree.
//!
//! ## The one rule this tree must not break
//!
//! From `05_hir.zig`, the stage's decision record: "**Whole-array
//! operations survive HIR and MIR as single nodes.  Never expand one
//! into a scalar loop.**"  Sugar that gets expanded too early is a
//! refactor; an array operation expanded into a scalar loop is
//! information destroyed, and no later pass recovers it.  The design
//! consequence for this file: **no node kind below exists only as an
//! expansion of an array operation** — every kind names something the
//! source can say, so a future whole-array node slots in beside them
//! instead of being reverse-engineered out of them.
//!
//! ## What the vocabulary leans on
//!
//! Types are stage 4's `Type`s; the resolved operator set is
//! `support/vocabulary.zig`'s, and a resolved builtin is named by the
//! `mir.Intrinsic` it lowers to — the same table `builder.zig` already
//! resolves against, reused rather than mirrored so the two can never
//! drift.  Locals are `LocalId`s of **this tree's own numbering**
//! (05_hir.zig, coupling #5): `Body.locals` lists every slot, named
//! and hidden, in declaration order, and lower reproduces stage 6's
//! table by walking it in that order.

const std = @import("std");
const source = @import("../01_source.zig");
const types = @import("../support/types.zig");
const vocabulary = @import("../support/vocabulary.zig");
const mir = @import("../06_mir.zig");

const Span = source.Span;
const Type = types.Type;

/// A slot in `Body.locals` — the tree's own local numbering, which
/// lower reproduces in stage 6 by walking the same declarations in the
/// same order (05_hir.zig, coupling #5).
pub const LocalId = u32;

/// A reference to an expression node.  Nodes live in an arena beside
/// the tree that holds them, so a plain pointer is the reference.
pub const NodeRef = *Expression;

/// The resolved operator vocabulary, shared with stage 6 so the tree
/// and the tape can never spell one operation two ways.
pub const BinaryOp = vocabulary.BinaryOp;
pub const UnaryOp = mir.UnaryOp;

/// Where a value's storage stands the moment it is produced — the
/// property `builder.zig` stamps on every `Typed` as `Provenance`
/// (05_hir.zig, coupling #2).  Here it is a *computed* property of the
/// node kind (`provenance` below), which is what the stamp becomes when
/// the seam lands.  The answer is meaningful only where the result type
/// owns storage, exactly as the ownership questions that ask it are.
pub const Provenance = enum {
    /// Storage this statement allocated and nobody owns yet: a string
    /// `+`, a built struct or union value, a call's result, an
    /// allocating intrinsic, a taken copy.
    fresh,
    /// A view of storage something else holds: a local reload, a field
    /// or payload read, an element or map lookup.
    view,
    /// Everything else — constants, scalars, borrowless products.
    plain,
};

/// A statement temporary this expression's value was parked in (S3):
/// the hidden slot, and which of its two claims — the objects in the
/// value, the storage under it — the statement's end releases.  Null on
/// an expression nothing parked.  Recording it is what lets lower emit
/// the park without re-deriving the ownership walk (05_hir.zig,
/// coupling #3: the ledger of statement temporaries becomes this).
pub const Park = struct {
    local: LocalId,
    objects: bool,
    storage: bool,
};

/// How a store takes the value's storage (docs/STRINGS.md): `plain`
/// stores a scalar or an object handle with no storage question at
/// all; `take` is move-instead-of-copy — the value's park is retracted
/// and the place adopts the storage; `copy` duplicates a view or an
/// already-owned run.  Decided during check, so lower emits the decided
/// form once instead of performing surgery on emitted code (05_hir.zig,
/// coupling #3).
pub const StoreKind = enum { plain, take, copy };

/// One slot a scope releases on the way out, and which of its two
/// claims — the objects in its value, the storage under it — the
/// release gives back.  The recorded home for scope-exit releases:
/// every `Block` carries its own, in emission order.
pub const Release = struct {
    local: LocalId,
    objects: bool,
    storage: bool,
};

/// One slot of `Body.locals`, named or hidden, in declaration order.
pub const LocalDecl = struct {
    /// The written name, or null for a slot the lowering needed for
    /// itself — a spill, a loop counter, a statement temporary.
    name: ?[]const u8,
    local_type: Type,
    /// The declaring name's span, or the making expression's for a
    /// hidden slot.
    span: Span,
};

/// A checked function body: its statements and every local slot the
/// tree names, in declaration order.
pub const Body = struct {
    statements: []const Statement,
    locals: []const LocalDecl,
};

// ---------------------------------------------------------------------------
// Expressions
// ---------------------------------------------------------------------------

/// A checked expression.  Every payload carries `result` (the type the
/// checker decided), `span` (the source it came from), and `park` (the
/// statement temporary it was parked in, if any) — read them through
/// the accessors below.
pub const Expression = union(enum) {
    // Literals --------------------------------------------------------------

    /// An integer literal, parsed at the width it landed on
    /// (docs/TYPES.md D3) — the value, not the text.
    const_long: ConstLong,
    /// A float literal (or an integer literal that landed on a float),
    /// parsed at its landing width.
    const_double: ConstDouble,
    const_boolean: ConstBoolean,
    /// A string literal.  Carries the interned pool slot rather than
    /// the bytes, because the pool is filled during checking and the
    /// order must not move (05_hir.zig, coupling #6).
    const_string: ConstString,
    /// The typed absence a `T?` place gives a bare `none`, and the
    /// zero a declared-only `var` starts as — `result` is the whole of
    /// its value (docs/ARGS.md D9).
    absent: Absent,

    // Reads -----------------------------------------------------------------

    /// A name read: the value its slot holds.
    local_get: LocalGet,
    /// A narrowed `T?` name read as its payload — the flow analysis
    /// has already proved the value is there (docs/FAILURE.md).
    narrowed_get: NarrowedGet,
    /// `value.field` — a view into the struct's run.
    field_get: FieldGet,
    /// A union member's payload field, read inside the arm that proved
    /// the member (docs/UNION.md D10).
    variant_payload: VariantPayload,
    /// `xs[i]`, `grid[r, c]`, `m[k]` — an element read.
    index_get: IndexGet,
    /// A use of a folded file-scope constant, inlined at this site.
    constant_ref: ConstantRef,
    /// The reload of the hidden slot a fallible call's result crosses
    /// its branch in — the recorded form of the walker's `carried`
    /// link.  The value is the *call's* value; the slot only ferries
    /// it, so every question about where the value came from follows
    /// `origin`.
    carried_get: CarriedGet,

    // Operators -------------------------------------------------------------

    /// An arithmetic or bit operation at its resolved type.  Never a
    /// comparison (`compare`), never `and`/`or` (`short_circuit`):
    /// this node's operands and result are the same type, which is
    /// what makes lower mechanical.
    binary: Binary,
    /// The explicit widening a literal or narrower operand took to
    /// reach its landing type (docs/TYPES.md §1).  A node rather than
    /// a property, so operand trees say where every conversion stands.
    convert: Convert,
    unary: Unary,
    /// `and` / `or`, which evaluate their right side conditionally and
    /// so are control flow, not `binary`.
    short_circuit: ShortCircuit,
    /// `x else fallback` — the optional fallback; the fallback runs
    /// only when `value` is absent.
    coalesce: Coalesce,
    /// A comparison: operands at their met type — or each on its own
    /// ladder for the exact cross-ladder comparison, which compares
    /// the numbers and not a conversion of them (docs/NUMERICS.md §5)
    /// — result boolean.
    compare: Compare,

    // Calls -----------------------------------------------------------------

    /// Every call shape, one node: what was resolved (`callee`), the
    /// operands in evaluation order, and whether the call can come
    /// back errored.
    call: Call,

    // Sugar that stays a node -----------------------------------------------

    /// `try CALL` — pass the failure on (docs/FAILURE.md).  The node
    /// form of what the fused walk coordinates through the one-hop
    /// `opened` field.
    try_call: TryCall,
    /// `CALL catch fallback` — the expression form; the fallback is
    /// evaluated only on the failing side.
    catch_expr: CatchExpr,

    // Construction ----------------------------------------------------------

    /// A struct built whole, every field in layout order (defaults
    /// already filled in).
    struct_make: StructMake,
    /// A struct built out of an existing one with named fields
    /// replaced — kept structured so lower, not check, spells the
    /// copy-and-replace.
    struct_with: StructWith,
    /// A union member built whole (docs/UNION.md D8).
    variant_make: VariantMake,
    /// `[a, b, c]` at its landing container type.
    list_literal: ListLiteral,
    /// `{key: value, ...}` at its landing map type.
    map_literal: MapLiteral,
    /// `xs[a:b]` / `s[a:b]`; a null bound is the defaulted end.
    slice: Slice,
    /// `new list(T)`, `new array(T, n, ...)`, `new map(K, V)`,
    /// `new builder` — a fresh container object.
    new_object: NewObject,
    /// `give x` — the owner hands over and is poisoned (S10).
    give: Give,
    /// `copy x` — a deep duplicate nobody owns yet (S21).
    copy: Copy,
    /// `spawn f(args)` — the call, made on a worker's own runtime
    /// (docs/THREADS.md); answers the `task` this scope owns.
    spawn: Spawn,
    /// A named function landing where a function value is expected
    /// (docs/FUNCTIONS.md S1).
    function_value: FunctionValue,
    /// A lambda, after the analyzer synthesized its declaration — a
    /// function value that remembers it was written in place.
    lambda_ref: LambdaRef,

    // Payloads --------------------------------------------------------------

    pub const ConstLong = struct {
        value: i64,
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    pub const ConstDouble = struct {
        value: f64,
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    pub const ConstBoolean = struct {
        value: bool,
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    pub const ConstString = struct {
        /// The interned constant-pool slot (05_hir.zig, coupling #6).
        constant: u32,
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    pub const Absent = struct {
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    pub const LocalGet = struct {
        local: LocalId,
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    pub const NarrowedGet = struct {
        local: LocalId,
        /// The payload type the narrowing proved — always equal to
        /// `result`, carried under its own name because it is the fact
        /// the flow analysis established and the fact lower unwraps at.
        payload: Type,
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    pub const FieldGet = struct {
        target: NodeRef,
        layout: u32,
        field: u32,
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    pub const VariantPayload = struct {
        target: NodeRef,
        variant: u32,
        member: u32,
        field: u32,
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    pub const IndexGet = struct {
        target: NodeRef,
        /// One per written subscript, in evaluation order.
        indices: []const NodeRef,
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    pub const ConstantRef = struct {
        /// The analyzer's constant table index.
        constant: u32,
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    pub const CarriedGet = struct {
        /// The hidden slot the value crossed the branch in.
        slot: LocalId,
        /// The call that made the value — where every question about
        /// the value's storage is really asked.
        origin: NodeRef,
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    pub const Binary = struct {
        op: BinaryOp,
        left: NodeRef,
        right: NodeRef,
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    pub const Convert = struct {
        operand: NodeRef,
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    pub const Unary = struct {
        op: UnaryOp,
        operand: NodeRef,
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    pub const ShortCircuit = struct {
        op: enum { logic_and, logic_or },
        left: NodeRef,
        right: NodeRef,
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    pub const Coalesce = struct {
        value: NodeRef,
        fallback: Fallback,
        result: Type,
        span: Span,
        park: ?Park = null,

        /// What stands after `else`: an ordinary fallback **value**
        /// stored into the merge slot, or a **leaving** call — `x else
        /// trap("…")`, the assert-unwrap (docs/FAILURE.md) — which is
        /// evaluated for its exit and stores nothing, so the coalesce
        /// has no fallback value at all.  A union rather than a bare
        /// `NodeRef`, because a tree that filed the leaving call as a
        /// value would oblige lower to store a value that never
        /// exists.
        pub const Fallback = union(enum) { value: NodeRef, leaving: NodeRef };
    };

    pub const Compare = struct {
        /// A comparison member of `BinaryOp` (`isComparison`), never an
        /// arithmetic one — the split twin of `binary`'s rule.
        op: BinaryOp,
        left: NodeRef,
        right: NodeRef,
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    pub const Call = struct {
        callee: ResolvedCallee,
        operands: OperandBatch,
        /// Whether the call can come back errored — in which case a
        /// `try_call`, `catch_expr` or guarded statement stands in
        /// front of it.
        fallible: bool,
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    pub const TryCall = struct {
        call: NodeRef,
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    pub const CatchExpr = struct {
        call: NodeRef,
        fallback: NodeRef,
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    pub const StructMake = struct {
        layout: u32,
        /// Every field in layout order, defaults filled in.
        fields: []const NodeRef,
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    pub const StructWith = struct {
        base: NodeRef,
        layout: u32,
        replacements: []const Replacement,
        result: Type,
        span: Span,
        park: ?Park = null,

        pub const Replacement = struct { field: u32, value: NodeRef };
    };

    pub const VariantMake = struct {
        variant: u32,
        member: u32,
        fields: []const NodeRef,
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    pub const ListLiteral = struct {
        elements: []const NodeRef,
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    pub const MapLiteral = struct {
        entries: []const Entry,
        result: Type,
        span: Span,
        park: ?Park = null,

        pub const Entry = struct { key: NodeRef, value: NodeRef };
    };

    pub const Slice = struct {
        target: NodeRef,
        /// Null is the defaulted bound: start 0, stop `len(target)`.
        start: ?NodeRef,
        stop: ?NodeRef,
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    pub const NewObject = struct {
        /// The interned heap-type row of the object being made.
        heap_type: u32,
        /// Dimension sizes for an array; empty otherwise.
        operands: []const NodeRef,
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    pub const Give = struct {
        operand: NodeRef,
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    pub const Copy = struct {
        operand: NodeRef,
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    pub const Spawn = struct {
        call: NodeRef,
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    pub const FunctionValue = struct {
        /// The function table index — the same number `const_function`
        /// materializes (docs/FUNCTIONS.md D2).
        function: u32,
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    pub const LambdaRef = struct {
        /// The synthesized declaration's function table index.
        function: u32,
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    // Accessors -------------------------------------------------------------

    /// The type the checker decided this expression has.
    pub fn result(self: *const Expression) Type {
        return switch (self.*) {
            inline else => |payload| payload.result,
        };
    }

    pub fn span(self: *const Expression) Span {
        return switch (self.*) {
            inline else => |payload| payload.span,
        };
    }

    /// The statement temporary this value was parked in, if any (S3).
    pub fn park(self: *const Expression) ?Park {
        return switch (self.*) {
            inline else => |payload| payload.park,
        };
    }
};

/// What a call site resolved to — the things a written call can name
/// once checking is done.
pub const ResolvedCallee = union(enum) {
    /// A declared function or method, by function table index.
    function: u32,
    /// A call through a function value held in a local
    /// (docs/FUNCTIONS.md D2, D5): the slot the callee is read from —
    /// *after* the operands, the order the emission keeps — and the
    /// interned signature the call is checked against.
    indirect: Indirect,
    /// A builtin that lowers to one MIR intrinsic — the resolved name
    /// of the operation, shared with stage 6 so it cannot drift.
    /// `string(f)` records here as `function_name` rather than as a
    /// `.conversion`, because a function's name is a constant of the
    /// program's own, not the fresh bytes `.conversion` to string
    /// means (docs/FUNCTIONS.md D3).
    intrinsic: mir.Intrinsic,
    /// A conversion constructor (docs/NUMERICS.md §7), by the type it
    /// produces.  Never the identity: `long(x)` on a `long` passes the
    /// operand through whole, node included, so no call node exists
    /// to claim freshness the value does not have.
    conversion: Type,
    /// The structural enum text pair — `string(m)` and `Method(n)` —
    /// by enum table index; lower emits the member chain.
    enum_name: u32,
    /// The union half of the text pair — `string(u)` — by union table
    /// index; lower emits the member chain over the tag
    /// (docs/UNION.md D16).
    variant_name: u32,

    pub const Indirect = struct { local: LocalId, signature: u32 };
};

/// A call's operands in **evaluation order** — the written arguments
/// first, as written, then one entry per defaulted slot in the order
/// the defaults are materialized (docs/ARGS.md D2) — with the
/// declaration slot each one fills and the two per-operand facts the
/// walk decides while lowering them.
///
/// **The operand nodes are the written expressions, pre-rewrite.**  A
/// spill reload or a defensive borrow copy replaces the operand's
/// *register*, never its node, so the flags below beside the pre-copy
/// nodes are the full story lower replays.  A defaulted entry's node
/// is the constant the declaration supplies, spanned at the call site
/// that omitted it.  The keep-copy a *writing receiver* forces on its
/// storage-owning arguments is deliberately not a flag here: it is a
/// property of the resolved callee — receiver mode and parameter type
/// — that lower re-derives, not a decision of this batch.
pub const OperandBatch = struct {
    operands: []const NodeRef,
    /// The declaration slot each operand fills — permuted where named
    /// arguments reorder (docs/ARGS.md D5), the receiver at slot 0 in
    /// the method form — so lower evaluates in this order and still
    /// lands every value on its parameter.
    slots: []const u32,
    /// Which operands were spilled across a block split before the
    /// call — coupling #4's conservative guess, recorded so lower
    /// reproduces the tape byte for byte until the guess is deleted
    /// (measured, in its own landing).
    spill: []const bool,
    /// Which operands took the defensive copy because they view
    /// storage a later writing operand in the same batch may replace
    /// (`f(s, s.change())` — docs/STRINGS.md).
    borrow_copy: []const bool,
};

// ---------------------------------------------------------------------------
// Statements
// ---------------------------------------------------------------------------

/// A scope's statements and its exit: every slot the scope releases on
/// the way out, in emission order — the recorded home for scope-exit
/// releases, so lower emits a scope end without re-walking ownership.
pub const Block = struct {
    statements: []const Statement,
    releases: []const Release,
    span: Span,
};

/// A place a store lands in — the shapes `builder.zig`'s three store
/// paths descend to.  Provisional until the assignment family lands:
/// each shape is reconciled against its arm when that arm converts.
pub const Place = union(enum) {
    local: LocalId,
    /// `x.field = v` — a field of a struct held in a local.
    field: Field,
    /// `xs[i] = v` — an element of a container.
    index: Index,
    /// A nested chain (`p.a[i].b = v`): the root local and the steps
    /// descended through, mirroring the rebuild the store performs.
    chain: Chain,

    pub const Field = struct { base: LocalId, layout: u32, field: u32 };
    pub const Index = struct { base: NodeRef, indices: []const NodeRef };
    pub const Chain = struct { root: LocalId, steps: []const Step };
    pub const Step = union(enum) {
        field: struct { layout: u32, field: u32 },
        index: []const NodeRef,
    };
};

pub const Statement = union(enum) {
    /// `let` / `var`: the slot and its initializer — null when the
    /// declaration zero-fills (`var x: T`).
    declare: Declare,
    assign: Assign,
    /// `x += v` and its family, kept as the sugar the reader wrote —
    /// the node `05_hir.zig`'s header draws as the stage's picture.
    compound_assign: CompoundAssign,
    /// An expression evaluated for its effects.
    expression: ExpressionStatement,
    if_else: IfElse,
    while_loop: WhileLoop,
    /// `for i in range(a, b):` — kept whole; the counter is a local of
    /// the loop's own.
    for_range: ForRange,
    /// `for x in xs:` / `for k, v in m:` — kept whole (never expanded
    /// to subscripts here; lower owns the iteration shape).
    for_in: ForIn,
    break_: Break,
    continue_: Continue,
    return_: Return,
    /// `CALL catch:` / a guarded receive — the statement forms whose
    /// failing side runs a handler and performs none of the stores.
    /// Provisional until the fallible family lands.
    guarded: Guarded,
    /// A bare scope: arm bodies and every other place a `Block` stands
    /// as a statement of its own.
    block: Block,

    pub const Declare = struct {
        local: LocalId,
        value: ?NodeRef,
        span: Span,
    };

    pub const Assign = struct {
        place: Place,
        value: NodeRef,
        /// How the store takes the value's storage — decided during
        /// check, emitted once by lower (05_hir.zig, coupling #3).
        store: StoreKind,
        span: Span,
    };

    pub const CompoundAssign = struct {
        place: Place,
        op: BinaryOp,
        value: NodeRef,
        span: Span,
    };

    pub const ExpressionStatement = struct {
        value: NodeRef,
        span: Span,
    };

    pub const IfElse = struct {
        condition: NodeRef,
        then_body: Block,
        else_body: ?Block,
        span: Span,
    };

    pub const WhileLoop = struct {
        condition: NodeRef,
        body: Block,
        span: Span,
    };

    pub const ForRange = struct {
        counter: LocalId,
        start: NodeRef,
        stop: NodeRef,
        body: Block,
        span: Span,
    };

    pub const ForIn = struct {
        sequence: NodeRef,
        /// The element, or a map's key.
        first: LocalId,
        /// A map's value, when two names are written.
        second: ?LocalId,
        body: Block,
        span: Span,
    };

    /// The recorded home for a break's unwinding: how many open scopes
    /// it releases through on the way to the loop's exit.
    pub const Break = struct {
        unwind: u32,
        span: Span,
    };

    pub const Continue = struct {
        unwind: u32,
        span: Span,
    };

    pub const Return = struct {
        values: []const NodeRef,
        /// The recorded home for return unwinding's moved set: the
        /// slots whose value leaves with the return, so the unwind
        /// releases every open scope *except* what these carry.
        moved: []const LocalId,
        span: Span,
    };

    pub const Guarded = struct {
        call: NodeRef,
        /// The stores the succeeding side performs — none of which the
        /// failing side may perform (docs/RETURNS.md).
        targets: []const Place,
        /// The handler block, with its error name bound when one was
        /// written.
        handler: ?Block,
        error_local: ?LocalId,
        span: Span,
    };

    pub fn span(self: *const Statement) Span {
        return switch (self.*) {
            .block => |body| body.span,
            inline else => |payload| payload.span,
        };
    }
};

// ---------------------------------------------------------------------------
// Provenance — the computed node-kind property
// ---------------------------------------------------------------------------

/// Where a node's value stands as far as storage goes — the property
/// `builder.zig` stamps by hand today (`Typed.provenance`), answered
/// here from the node kind alone.  The migration's Debug oracles assert
/// the two agree arm by arm as each family converts; when the seam
/// lands, this function is the only spelling left.
///
/// Kinds whose family has not converted yet carry the answer the
/// current stamps and tape predicates give; each family's landing
/// reconciles its rows before recording them.
pub fn provenance(expression: *const Expression) Provenance {
    return switch (expression.*) {
        // Constants own nothing and view nothing.
        .const_long, .const_double, .const_boolean, .const_string => .plain,
        // A struct or union zero is a built value that owns its run;
        // every other absence is a constant (`zeroProvenance`'s rule).
        .absent => |payload| zeroOf(payload.result),
        // A name reads as a view of what its slot holds.
        .local_get => .view,
        // The narrowed unwrap answers neither fresh nor view, exactly
        // as the tape predicates read it.
        .narrowed_get => .plain,
        // Views into a run something else holds.
        .field_get, .variant_payload, .index_get => .view,
        // A folded constant materializes as its value does: a struct
        // default is built whole and owns its run; everything else is
        // a constant.
        .constant_ref => |payload| zeroOf(payload.result),
        // The slot only ferries the call's value across the branch;
        // the storage question belongs to the call.
        .carried_get => |payload| provenance(payload.origin),
        // String `+` allocates the joined bytes; every numeric binary
        // answers a scalar.
        .binary => |payload| if (payload.result == .string) .fresh else .plain,
        .convert, .unary, .compare => .plain,
        // Both answer a reload of the hidden slot their arms stored
        // into — a view of what the slot holds.
        .short_circuit, .coalesce => .view,
        .call => |payload| switch (payload.callee) {
            // A function's result is the caller's (S16): fresh storage
            // whichever way the callee was named (docs/FUNCTIONS.md D2).
            .function, .indirect => .fresh,
            .intrinsic => |kind| ofIntrinsic(kind),
            // `string(x)` allocates its text; the numeric conversions
            // answer scalars.
            .conversion => |produced| if (produced == .string) .fresh else .plain,
            // The member chains answer a reload of their result slot.
            .enum_name, .variant_name => .view,
        },
        // `try` hands back the call's own value through the carried
        // slot.
        .try_call => |payload| provenance(payload.call),
        // The answer is a reload of the slot both arms stored into.
        .catch_expr => .view,
        // Built whole; each owns its run (docs/UNION.md D8).
        .struct_make, .struct_with, .variant_make => .fresh,
        // These answer fresh *objects*, which the objects park tracks;
        // the storage question the tape asks of them answers no.
        .list_literal, .map_literal, .new_object => .plain,
        // A slice answers a view or a fresh object, never fresh
        // storage (`string_slice`/`list_slice` in the tape's tables).
        .slice => .plain,
        // `give` hands over the object; the storage stays borrowed.
        .give => .plain,
        // The duplicate is storage nobody owns yet (S21).
        .copy => .fresh,
        // A task is a resource, not storage.
        .spawn => .plain,
        // A function value is a number (docs/FUNCTIONS.md D2).
        .function_value, .lambda_ref => .plain,
    };
}

/// The provenance of a materialized zero or folded constant of `of` —
/// `builder.zig`'s `zeroProvenance`, spelled once here for the two node
/// kinds that inline one.
fn zeroOf(of: Type) Provenance {
    return switch (of) {
        .strukt, .variant => .fresh,
        else => .plain,
    };
}

/// The provenance an intrinsic's result carries — `builder.zig`'s
/// `intrinsicProvenance`, which the seam landing retires in favor of
/// this one: the allocators answer fresh storage, the readers answer a
/// view, and the rest answer no storage question at all.
fn ofIntrinsic(kind: mir.Intrinsic) Provenance {
    if (kind.makesFreshStorage()) return .fresh;
    return switch (kind) {
        .index_get, .map_get, .key_at, .value_at => .view,
        else => .plain,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const test_span: Span = .{ .start = 3, .end = 7 };

test "nodes build, and the accessors answer every payload" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A read tree: xs[i + 1] with the target and subscript recorded.
    const target = try arena.create(Expression);
    target.* = .{ .local_get = .{ .local = 0, .result = .{ .heap = 2 }, .span = test_span } };
    const left = try arena.create(Expression);
    left.* = .{ .local_get = .{ .local = 1, .result = .long, .span = test_span } };
    const right = try arena.create(Expression);
    right.* = .{ .const_long = .{ .value = 1, .result = .long, .span = test_span } };
    const sum = try arena.create(Expression);
    sum.* = .{ .binary = .{ .op = .add, .left = left, .right = right, .result = .long, .span = test_span } };
    const indices = try arena.alloc(NodeRef, 1);
    indices[0] = sum;
    const element = try arena.create(Expression);
    element.* = .{ .index_get = .{
        .target = target,
        .indices = indices,
        .result = .string,
        .span = test_span,
        .park = .{ .local = 5, .objects = false, .storage = true },
    } };

    try testing.expect(element.result() == .string);
    try testing.expectEqual(test_span.start, element.span().start);
    try testing.expectEqual(@as(LocalId, 5), element.park().?.local);
    try testing.expect(element.park().?.storage);
    try testing.expect(target.park() == null);
    try testing.expect(sum.result() == .long);

    // A narrowed read remembers the payload the flow analysis proved.
    const narrowed = try arena.create(Expression);
    narrowed.* = .{ .narrowed_get = .{
        .local = 2,
        .payload = .double,
        .result = .double,
        .span = test_span,
    } };
    try testing.expect(narrowed.narrowed_get.payload.eql(narrowed.result()));

    // A statement tree: a block that releases its slot on the way out,
    // a break that unwinds two scopes, a return that moves one local.
    const statements = try arena.alloc(Statement, 3);
    statements[0] = .{ .declare = .{ .local = 3, .value = element, .span = test_span } };
    statements[1] = .{ .break_ = .{ .unwind = 2, .span = test_span } };
    const moved = try arena.alloc(LocalId, 1);
    moved[0] = 3;
    const returned = try arena.alloc(NodeRef, 1);
    returned[0] = narrowed;
    statements[2] = .{ .return_ = .{ .values = returned, .moved = moved, .span = test_span } };
    const releases = try arena.alloc(Release, 1);
    releases[0] = .{ .local = 3, .objects = true, .storage = false };
    const block: Statement = .{ .block = .{
        .statements = statements,
        .releases = releases,
        .span = test_span,
    } };

    try testing.expectEqual(test_span.end, block.span().end);
    try testing.expectEqual(@as(u32, 2), statements[1].break_.unwind);
    try testing.expectEqual(@as(LocalId, 3), block.block.releases[0].local);
    try testing.expectEqual(@as(LocalId, 3), statements[2].return_.moved[0]);

    // A body lists every slot, named and hidden, in declaration order.
    const locals = try arena.alloc(LocalDecl, 2);
    locals[0] = .{ .name = "xs", .local_type = .{ .heap = 2 }, .span = test_span };
    locals[1] = .{ .name = null, .local_type = .string, .span = test_span };
    const body: Body = .{ .statements = statements, .locals = locals };
    try testing.expect(body.locals[1].name == null);
}

test "provenance mirrors the storage categories the walk stamps" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const node = struct {
        fn make(allocator: std.mem.Allocator, expression: Expression) !NodeRef {
            const made = try allocator.create(Expression);
            made.* = expression;
            return made;
        }
    }.make;

    // Literals are plain; a struct-typed absence is a built value.
    const text = try node(arena, .{ .const_string = .{ .constant = 0, .result = .string, .span = test_span } });
    try testing.expectEqual(Provenance.plain, provenance(text));
    const zero = try node(arena, .{ .absent = .{ .result = .{ .strukt = 0 }, .span = test_span } });
    try testing.expectEqual(Provenance.fresh, provenance(zero));
    const none = try node(arena, .{ .absent = .{ .result = .{ .optional = .long }, .span = test_span } });
    try testing.expectEqual(Provenance.plain, provenance(none));

    // Reads are views; the narrowed unwrap is neither fresh nor view.
    const name = try node(arena, .{ .local_get = .{ .local = 0, .result = .string, .span = test_span } });
    try testing.expectEqual(Provenance.view, provenance(name));
    const narrowed = try node(arena, .{ .narrowed_get = .{ .local = 0, .payload = .string, .result = .string, .span = test_span } });
    try testing.expectEqual(Provenance.plain, provenance(narrowed));
    const field = try node(arena, .{ .field_get = .{ .target = name, .layout = 0, .field = 1, .result = .string, .span = test_span } });
    try testing.expectEqual(Provenance.view, provenance(field));
    const payload = try node(arena, .{ .variant_payload = .{ .target = name, .variant = 0, .member = 1, .field = 0, .result = .string, .span = test_span } });
    try testing.expectEqual(Provenance.view, provenance(payload));
    const indices = try arena.alloc(NodeRef, 0);
    const element = try node(arena, .{ .index_get = .{ .target = name, .indices = indices, .result = .string, .span = test_span } });
    try testing.expectEqual(Provenance.view, provenance(element));

    // A folded constant materializes as its value does.
    const folded_struct = try node(arena, .{ .constant_ref = .{ .constant = 0, .result = .{ .strukt = 1 }, .span = test_span } });
    try testing.expectEqual(Provenance.fresh, provenance(folded_struct));
    const folded_text = try node(arena, .{ .constant_ref = .{ .constant = 1, .result = .string, .span = test_span } });
    try testing.expectEqual(Provenance.plain, provenance(folded_text));

    // String `+` allocates; numeric binaries answer scalars.
    const join = try node(arena, .{ .binary = .{ .op = .add, .left = name, .right = text, .result = .string, .span = test_span } });
    try testing.expectEqual(Provenance.fresh, provenance(join));
    const sum = try node(arena, .{ .binary = .{ .op = .add, .left = name, .right = name, .result = .long, .span = test_span } });
    try testing.expectEqual(Provenance.plain, provenance(sum));

    // Both slot-merging operators answer a reload of the slot.
    const either = try node(arena, .{ .short_circuit = .{ .op = .logic_or, .left = name, .right = name, .result = .boolean, .span = test_span } });
    try testing.expectEqual(Provenance.view, provenance(either));
    const fallback = try node(arena, .{ .coalesce = .{ .value = narrowed, .fallback = .{ .value = text }, .result = .string, .span = test_span } });
    try testing.expectEqual(Provenance.view, provenance(fallback));
    const asserted = try node(arena, .{ .coalesce = .{ .value = narrowed, .fallback = .{ .leaving = text }, .result = .string, .span = test_span } });
    try testing.expectEqual(Provenance.view, provenance(asserted));

    // A call's answer is the caller's — through a name or a function
    // value alike; an intrinsic answers what its table row says; the
    // member chains answer a reload; the carried reload and `try`
    // follow the call.
    const batch: OperandBatch = .{ .operands = &.{}, .slots = &.{}, .spill = &.{}, .borrow_copy = &.{} };
    const called = try node(arena, .{ .call = .{ .callee = .{ .function = 0 }, .operands = batch, .fallible = true, .result = .string, .span = test_span } });
    try testing.expectEqual(Provenance.fresh, provenance(called));
    const through = try node(arena, .{ .call = .{ .callee = .{ .indirect = .{ .local = 1, .signature = 0 } }, .operands = batch, .fallible = false, .result = .string, .span = test_span } });
    try testing.expectEqual(Provenance.fresh, provenance(through));
    const looked_up = try node(arena, .{ .call = .{ .callee = .{ .intrinsic = .map_get }, .operands = batch, .fallible = false, .result = .string, .span = test_span } });
    try testing.expectEqual(Provenance.view, provenance(looked_up));
    const made_text = try node(arena, .{ .call = .{ .callee = .{ .intrinsic = .str_value }, .operands = batch, .fallible = false, .result = .string, .span = test_span } });
    try testing.expectEqual(Provenance.fresh, provenance(made_text));
    const member_name = try node(arena, .{ .call = .{ .callee = .{ .enum_name = 0 }, .operands = batch, .fallible = false, .result = .string, .span = test_span } });
    try testing.expectEqual(Provenance.view, provenance(member_name));
    const union_name = try node(arena, .{ .call = .{ .callee = .{ .variant_name = 0 }, .operands = batch, .fallible = false, .result = .string, .span = test_span } });
    try testing.expectEqual(Provenance.view, provenance(union_name));
    const carried = try node(arena, .{ .carried_get = .{ .slot = 4, .origin = called, .result = .string, .span = test_span } });
    try testing.expectEqual(Provenance.fresh, provenance(carried));
    const attempted = try node(arena, .{ .try_call = .{ .call = called, .result = .string, .span = test_span } });
    try testing.expectEqual(Provenance.fresh, provenance(attempted));
    const caught = try node(arena, .{ .catch_expr = .{ .call = called, .fallback = text, .result = .string, .span = test_span } });
    try testing.expectEqual(Provenance.view, provenance(caught));

    // Construction: built values own their runs; a fresh container is
    // an object, not storage; the duplicate is nobody's yet.
    const fields = try arena.alloc(NodeRef, 1);
    fields[0] = text;
    const built = try node(arena, .{ .struct_make = .{ .layout = 0, .fields = fields, .result = .{ .strukt = 0 }, .span = test_span } });
    try testing.expectEqual(Provenance.fresh, provenance(built));
    const member = try node(arena, .{ .variant_make = .{ .variant = 0, .member = 0, .fields = &.{}, .result = .{ .variant = 0 }, .span = test_span } });
    try testing.expectEqual(Provenance.fresh, provenance(member));
    const listed = try node(arena, .{ .list_literal = .{ .elements = &.{}, .result = .{ .heap = 0 }, .span = test_span } });
    try testing.expectEqual(Provenance.plain, provenance(listed));
    const fresh_object = try node(arena, .{ .new_object = .{ .heap_type = 0, .operands = &.{}, .result = .{ .heap = 0 }, .span = test_span } });
    try testing.expectEqual(Provenance.plain, provenance(fresh_object));
    const sliced = try node(arena, .{ .slice = .{ .target = name, .start = null, .stop = null, .result = .string, .span = test_span } });
    try testing.expectEqual(Provenance.plain, provenance(sliced));
    const given = try node(arena, .{ .give = .{ .operand = name, .result = .{ .heap = 0 }, .span = test_span } });
    try testing.expectEqual(Provenance.plain, provenance(given));
    const copied = try node(arena, .{ .copy = .{ .operand = name, .result = .string, .span = test_span } });
    try testing.expectEqual(Provenance.fresh, provenance(copied));
    const worker = try node(arena, .{ .spawn = .{ .call = called, .result = .{ .heap = 1 }, .span = test_span } });
    try testing.expectEqual(Provenance.plain, provenance(worker));
    const named = try node(arena, .{ .function_value = .{ .function = 2, .result = .{ .function = 0 }, .span = test_span } });
    try testing.expectEqual(Provenance.plain, provenance(named));
}
