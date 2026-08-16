//! The typed tree — the value that crosses the check/lower seam.
//!
//! One node per thing a checked function body can *be*, resolved and
//! typed the way stage 4 decides it and structured the way the reader
//! wrote it.  `hir.zig`'s header lists the six couplings this tree
//! dissolves; this file is the vocabulary and holds no behavior at all
//! beyond the accessors and the two computed properties (`provenance`,
//! `splitsBlocks`).
//!
//! **How it is made.**  `semantics/builder.zig`'s checked walk
//! records each expression's node on the `Typed` it answers and each
//! statement into its block frame, emitting nothing; `hir/lower.zig`
//! consumes the finished `Body` and is the one emission.  A body whose
//! check was diagnosed may be recorded with gaps — the driver stops at
//! diagnostics, so lower never sees one.
//!
//! ## The one rule this tree must not break
//!
//! From `hir.zig`, the stage's decision record: "**Whole-array
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
//! (hir.zig, coupling #5): `Body.locals` lists every slot, named
//! and hidden, in allocation order. Lower reproduces stage 6's table
//! row for row, then claims recorded ids exactly once while replaying.

const std = @import("std");
const source = @import("../source.zig");
const types = @import("../support/types.zig");
const vocabulary = @import("../support/vocabulary.zig");
const mir = @import("../mir.zig");

const Span = source.Span;
const Type = types.Type;

/// A slot in `Body.locals` — the tree's own local numbering, which
/// lower reproduces row for row in stage 6 (hir.zig, coupling #5).
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
/// (hir.zig, coupling #2).  Here it is a *computed* property of the
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

/// A statement temporary this expression's value's storage was parked
/// in (docs/STRINGS.md): the hidden slot, whether the park owns the
/// value's storage, and whether the statement's end still releases it.
/// Null on an expression whose storage nothing parked.  Recording it is
/// what lets lower emit the park's owning slot and its scope-exit
/// `drop_storage` without re-deriving the walk (hir.zig, coupling
/// #3: the ledger of statement temporaries becomes this).
///
/// `storage` is the claim at the park — the hidden slot was made owning
/// storage exactly when it is set, and an unwinding path between the
/// park and any adopting store releases that storage.  `released_storage`
/// is the settled answer after an adopting store retracted it — what the
/// statement's end still releases.  A park nothing retracted records the
/// two equal.
pub const Park = struct {
    local: LocalId,
    /// The hidden slot was made owning storage exactly when set.
    storage: bool,
    /// The storage the statement's end still releases, post-retraction
    /// (coupling #3): an adopting store takes it.
    released_storage: bool,
    /// The value carries a reference object at the park — a fresh
    /// container or resource, or a struct/union holding one — so the
    /// statement's end drops the reference unless a store adopts the
    /// value first, exactly as `storage` governs its bytes (docs/MEMORY.md).
    objects: bool = false,
};

/// How a store takes the value's storage (docs/STRINGS.md): `plain`
/// stores a scalar or an object handle with no storage question at
/// all; `take` is move-instead-of-copy — the value's park is retracted
/// and the place adopts the storage; `copy` duplicates a view or an
/// already-owned run.  Decided during check, so lower emits the decided
/// form once instead of performing surgery on emitted code (hir.zig,
/// coupling #3).
pub const StoreKind = enum { plain, take, copy };

/// One slot a scope releases on the way out — the storage under it that
/// the release gives back (`drop_storage`).  The recorded home for
/// scope-exit storage releases: every `Block` carries its own, in
/// emission order.  Objects a scope leaves behind are not released here:
/// they live until the runtime sweeps at exit.
pub const Release = struct {
    local: LocalId,
    storage: bool,
    objects: bool = false,
};

/// One slot of `Body.locals`, named or hidden, in declaration order.
pub const LocalDecl = struct {
    /// The written name, or null for a slot the lowering needed for
    /// itself — a spill, a loop counter, a statement temporary.
    name: ?[]const u8,
    local_type: Type,
    /// Whether the slot owns the string bytes and struct field runs it
    /// holds — stage 6's own column (docs/STRINGS.md), recorded because
    /// it embeds check-side analysis a re-derivation would have to
    /// repeat (a loop name owns a copy exactly when the body could
    /// mutate the container under it).  **Settled**: a park retracted
    /// by an adopting store (`takeStorage`) is recorded post-
    /// retraction, per coupling #3.
    owns_storage: bool,
    /// The declaring name's span, or the making expression's for a
    /// hidden slot.
    span: Span,
};

/// A checked function body: its statements, the body block's own
/// scope-exit releases, and every local slot the tree names, in
/// declaration order.
pub const Body = struct {
    statements: []const Statement,
    /// The body block's scope-exit releases (`Block.releases`), here
    /// because the body has no `Block` wrapper of its own.
    releases: []const Release = &.{},
    locals: []const LocalDecl,
    /// Statements the walk could not record — possible only on a
    /// diagnosed compile, whose bodies never reach `lower` (the
    /// driver stops at diagnostics, and `lowerFunction` asserts the
    /// zero).
    gaps: u32 = 0,
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
    const_integer: ConstInteger,
    /// A float literal (or an integer literal that landed on a float),
    /// parsed at its landing width.
    const_float: ConstFloat,
    const_boolean: ConstBoolean,
    /// A string literal.  Carries the interned pool slot rather than
    /// the bytes, because the pool is filled during checking and the
    /// order must not move (hir.zig, coupling #6).
    const_str: ConstStr,
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
    /// A folded container constant — a flat list, map or rank-1 array
    /// built at compile time — materialized as its interned
    /// program-root row (`const_container`).  Reached only through a
    /// defaulted construction operand; a *named* constant use records
    /// `constant_ref`, the source-level identity, instead.
    container_ref: ContainerRef,
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
    /// The `T <: T?` widening (MEMORY.md) — `convert`'s twin on
    /// the optional ladder, recorded at `fit`, the one place promotion
    /// is spelled.  A node rather than a property of the place,
    /// because the wrap emits a real instruction whose result is a
    /// *new* value with a storage answer of its own (`plain`, never
    /// the operand's), and a tree that passed the operand through
    /// whole would claim the operand's provenance for it.
    wrap_optional: WrapOptional,
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

    /// A struct built whole: the operands in evaluation order with the
    /// field slot each fills (named fields permute, exactly as named
    /// arguments do), defaults appended after the written operands in
    /// the order they materialize.
    struct_make: StructMake,
    /// A compiler-generated interface value: one bound function value per
    /// contract method, all targeting the same concrete receiver.
    interface_make: InterfaceMake,
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
    /// `spawn f(args)` — the call, made on a worker's own runtime
    /// (docs/THREADS.md); answers the `task` this scope owns.
    spawn: Spawn,
    /// A named function landing where a function value is expected
    /// (docs/FUNCTIONS.md S1).
    function_value: FunctionValue,
    /// A lambda, after the analyzer synthesized its declaration — a
    /// function value that remembers it was written in place.
    lambda_ref: LambdaRef,
    /// `receiver.method` where a function type lands — a function
    /// value whose environment is the receiver (docs/BINDING.md D1).
    bound_method: BoundMethod,

    // Payloads --------------------------------------------------------------

    pub const ConstInteger = struct {
        value: i128,
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    pub const ConstFloat = struct {
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

    pub const ConstStr = struct {
        /// The interned constant-pool slot (hir.zig, coupling #6).
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
        /// The container, with its batch rewrite flag: the read is one
        /// operand run (`Operand`'s convention), so the target and every
        /// subscript carry the borrow-copy fact a replay needs.
        target: Operand,
        /// One per written subscript, in evaluation order.
        indices: []const Operand,
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

    pub const ContainerRef = struct {
        /// The interned program-root container row (`const_container`).
        row: u32,
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
        /// The operand pair's evaluation and rewrite facts (`Sides`):
        /// recorded because the typed-side-first evaluation order is
        /// not derivable from the resolved tree.
        sides: Sides = .{},
    };

    /// The recorded evaluation facts of a two-operand batch — an
    /// arithmetic or comparison operator's pair.  `right_first` is the
    /// typed-side-first evaluation order the untyped-literal rule takes
    /// (docs/TYPES.md D3: the typed side is lowered first so the
    /// literal can land on it, and that reorders the emission);
    /// `left_copied` is the batch rewrite the paired walk performs on
    /// the left operand (the right operand is last in its batch and
    /// never takes it).  The left operand's spill is not recorded: it
    /// is `splitsBlocks(right)`, which lower asks for itself.
    pub const Sides = struct {
        right_first: bool = false,
        left_copied: bool = false,
    };

    pub const Convert = struct {
        operand: NodeRef,
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    pub const WrapOptional = struct {
        /// The payload, already at the optional's held type.
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
        /// `Binary.sides`, for the same pair walk.
        sides: Sides = .{},
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
        /// The operand's carried link: the `carried_get` reload of the
        /// slot the call's answer crossed its branch in, or the call
        /// itself for a callee answering nothing.
        call: NodeRef,
        /// The statement-temporary ledger's length when the call's
        /// branch was taken (`Opened.temps_floor`): parks below it
        /// belong to the statement's earlier operands and are released
        /// on the failing side; parks at or above it live only where
        /// the call returned, and their slots were never stored into
        /// where it did not.
        temps_floor: u32,
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    pub const CatchExpr = struct {
        /// The operand's carried link — `TryCall.call`'s convention.
        call: NodeRef,
        fallback: Fallback,
        /// `TryCall.temps_floor`, for the same failing side.
        temps_floor: u32,
        result: Type,
        span: Span,
        park: ?Park = null,

        /// What stands after `catch`: an ordinary fallback **value**
        /// stored into the merge slot, or a **leaving** call — `f()
        /// catch trap("…")` (docs/FAILURE.md) — evaluated for its exit
        /// and storing nothing.  `Coalesce.Fallback`'s rule, at the
        /// fallible merge: a tree that filed the leaving call as a
        /// value would oblige lower to store a value that never
        /// exists.  A call answering nothing files its fallback under
        /// `.value` too — `result` being `.none` already says neither
        /// side stores.
        pub const Fallback = union(enum) { value: NodeRef, leaving: NodeRef };
    };

    pub const StructMake = struct {
        layout: u32,
        /// The batch convention is a call's exactly (`OperandBatch`):
        /// operands in evaluation order — written fields as written,
        /// then one entry per defaulted field in materialization order
        /// — and `slots` are the layout's field indices, each present
        /// exactly once.  Lower evaluates in this order and permutes
        /// into layout order at the `struct_make`.
        operands: OperandBatch,
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    pub const InterfaceMethod = struct {
        function: u32,
        signature: u32,
        /// Internal interface dispatch may point at a fallible method;
        /// ordinary function values keep this false because their type
        /// intentionally carries no failure obligation.
        fallible: bool = false,
    };

    pub const InterfaceMake = struct {
        layout: u32,
        receiver: NodeRef,
        methods: []const InterfaceMethod,
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    pub const VariantMake = struct {
        variant: u32,
        member: u32,
        /// `StructMake`'s convention over the member's payload fields;
        /// empty for a bare member (docs/UNION.md D4).
        operands: OperandBatch,
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    pub const ListLiteral = struct {
        /// Written order, which is evaluation order — a bracket
        /// literal permutes nothing.  The result type says whether
        /// the literal landed as a list or a rank-1 array; the node
        /// stays the written form either way.
        elements: []const Operand,
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    pub const MapLiteral = struct {
        entries: []const Entry,
        result: Type,
        span: Span,
        park: ?Park = null,

        /// One written pair.  Keys and values are one interleaved
        /// operand run in the emission (key, value, key, value…), so
        /// each carries its own rewrite flags.
        pub const Entry = struct { key: Operand, value: Operand };
    };

    pub const Slice = struct {
        target: Operand,
        /// Null is the defaulted bound: start 0, stop `len(target)`.
        start: ?Operand,
        stop: ?Operand,
        result: Type,
        span: Span,
        park: ?Park = null,
    };

    pub const NewObject = struct {
        /// The interned heap-type row of the object being made.
        heap_type: u32,
        /// Dimension sizes for an array; empty otherwise.
        operands: []const Operand,
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

    pub const BoundMethod = struct {
        /// The method's function table index.  **Its parameter zero is
        /// the receiver**, which the value carries rather than takes,
        /// so the type this expression wears is one parameter shorter
        /// than the declaration (docs/BINDING.md D1).
        function: u32,
        /// The receiver, copied into the value at the bind (D3).  What
        /// the value holds is its own from here on, which is why a
        /// bound value releases like the struct value it contains.
        receiver: NodeRef,
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
    /// A call **through a function value** (docs/FUNCTIONS.md D2, D5):
    /// the expression that answers the value, and the interned
    /// signature the call was checked against.
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

    pub const Indirect = struct {
        /// The expression the callee value comes out of — a name, an
        /// element, a field, another call.  **A node rather than a
        /// slot**, which is what makes the call suffix one more suffix
        /// instead of a second call form: a narrowed name records the
        /// `narrowed_get` every other read of it records, so the
        /// storable form (docs/BINDING.md D7) needs no flag of its own.
        ///
        /// It is the run's **first** operand in evaluation order, the
        /// way a method's receiver is: what a reader wrote first runs
        /// first, and it rides the same spill machinery the arguments
        /// do so an argument that opens a block cannot strand it.
        callee: NodeRef,
        signature: u32,
        /// Interface dispatch can carry a fallible method even though an
        /// ordinary function value's type does not encode fallibility.
        fallible: bool = false,
        /// The defensive borrow copy `OperandBatch.borrow_copy` records
        /// for an argument, recorded here for the callee, which is not
        /// one of the slot-filling operands: a callee read out of a
        /// container is a *borrow* of that container's run, and an
        /// argument still to come could free it (docs/STRINGS.md's
        /// residual hazard).  True means the copy is emitted, and the
        /// park that rides it stands on the callee's own node.
        borrow_copy: bool = false,
    };
};

/// A call's — or a construction's — operands in **evaluation order**:
/// the written arguments first, as written, then one entry per
/// defaulted slot in the order the defaults are materialized
/// (docs/ARGS.md D2), with the declaration slot each one fills and the
/// two per-operand facts the walk decides while lowering them.
/// `struct_make` and `variant_make` carry the same batch with field
/// indices for slots, because named-field construction *is* the
/// named-argument call shape (docs/ARGS.md D8).
///
/// **The operand nodes are the written expressions, pre-rewrite.**  A
/// defensive borrow copy replaces the operand's *register*, never its
/// node, so the flags below beside the pre-copy nodes are the full
/// story lower replays — the spill across a block split is not among
/// them, because it is `splitsBlocks`' exact answer about these very
/// nodes and lower asks it itself (coupling #4).  A defaulted entry's node
/// is the constant the declaration supplies, spanned at the call site
/// that omitted it.  The keep-copy a *writing receiver* forces on its
/// storage-owning arguments is deliberately not a flag here: it is a
/// property of the resolved callee — receiver mode and parameter type
/// — that lower re-derives, not a decision of this batch.
pub const OperandBatch = struct {
    /// How many leading entries are *written* operands — lowered as
    /// one batch, spills and copies included — before the defaulted
    /// suffix, whose entries materialize one by one at the fill point.
    /// Zero for a batch that is all defaults (a folded constant's
    /// construction), whose fields materialize sequentially.
    written: u32 = 0,
    operands: []const NodeRef,
    /// The declaration slot each operand fills — permuted where named
    /// arguments reorder (docs/ARGS.md D5), the receiver at slot 0 in
    /// the method form — so lower evaluates in this order and still
    /// lands every value on its parameter.
    slots: []const u32,
    /// Which operands took the defensive copy because they view
    /// storage a later writing operand in the same batch may replace
    /// (`f(s, s.change())` — docs/STRINGS.md).
    borrow_copy: []const bool,
};

/// One lowered operand with `OperandBatch`'s per-operand rewrite
/// fact, spelled per operand instead of as a parallel array — for the
/// families whose operands land where they stand and permute nothing:
/// a literal's elements, a map entry's halves, an array's dimensions,
/// a slice's parts.  The copies happen at these sites exactly as they
/// do before a call — the emission runs every batch through the same
/// walk — so the runs carry the same flag, under the same pre-rewrite
/// convention: a defensive borrow copy replaces the operand's
/// *register*, never its node.
pub const Operand = struct {
    node: NodeRef,
    /// Took the defensive borrow copy in front of a later
    /// container-mutating operand in the same run (docs/STRINGS.md).
    copied: bool = false,
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
    /// The base and subscripts carry their batch rewrite flag
    /// (`Operand`): the indexed store lowers one operand run — base,
    /// subscripts, value — and a replay needs the borrow-copy fact for
    /// every position (the value's ride on the statement).
    pub const Index = struct { base: Operand, indices: []const Operand };
    pub const Chain = struct { root: LocalId, steps: []const Step };
    pub const Step = union(enum) {
        field: struct { layout: u32, field: u32 },
        index: []const Operand,
    };
};

pub const Statement = union(enum) {
    /// `let` / `var`: the slot and its initializer — null when the
    /// declaration zero-fills (`var x: T`).
    declare: Declare,
    /// `let a, b = f()` — one call answering a return shape declares
    /// one name per value (docs/RETURNS.md).
    destructure: Destructure,
    assign: Assign,
    /// `low, high = minmax(xs)` — one call replacing two or more
    /// existing mutable names, every result prepared before any old
    /// value is released (docs/RETURNS.md).
    assign_many: AssignMany,
    /// `x += v` and its family, kept as the sugar the reader wrote —
    /// the node `hir.zig`'s header draws as the stage's picture.
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
    /// `CALL catch:` — the statement form: the guarded statement, and
    /// a handler that runs only where its one call raised, performing
    /// none of the statement's stores (docs/RETURNS.md).
    guarded: Guarded,
    /// `match m:` — dispatch over an enum or a union (docs/ENUMS.md
    /// R1, docs/UNION.md D5), kept whole: the arms in written order
    /// with the member each names resolved.  Lower spells the
    /// compare-and-branch tree, and the last arm is the fallthrough
    /// exactly when `else_body` is null — the arms then cover every
    /// member, so a value that matched nothing above must be the last
    /// one's.
    match: Match,
    /// A bare scope: arm bodies and every other place a `Block` stands
    /// as a statement of its own.
    block: Block,

    pub const Declare = struct {
        local: LocalId,
        value: ?NodeRef,
        /// How the store into the slot took the value's storage —
        /// `ownedForStore`'s decision (hir.zig, coupling #3), made
        /// for the zero fill too.
        store: StoreKind,
        span: Span,
    };

    pub const Destructure = struct {
        /// One declared slot per value, in written order.
        locals: []const LocalId,
        /// The call whose return shape is being received.
        value: NodeRef,
        /// The per-name store decisions, parallel to `locals`.
        stores: []const StoreKind,
        span: Span,
    };

    pub const AssignMany = struct {
        /// The existing slots being replaced, in written order.
        targets: []const LocalId,
        value: NodeRef,
        /// The per-target store decisions, parallel to `targets`.
        stores: []const StoreKind,
        span: Span,
    };

    pub const Assign = struct {
        place: Place,
        value: NodeRef,
        /// How the store takes the value's storage — decided during
        /// check, emitted once by lower (hir.zig, coupling #3).
        store: StoreKind,
        span: Span,
        /// The value's own batch rewrite, where the place's shape puts
        /// it in an operand run (an indexed or chained store): a borrow
        /// copy of the stored value is an emission the place nodes
        /// cannot carry.
        value_copied: bool = false,
    };

    pub const CompoundAssign = struct {
        place: Place,
        op: BinaryOp,
        value: NodeRef,
        /// `Assign.store`, for the combined value's write-back.
        store: StoreKind,
        span: Span,
        /// `Assign`'s value rewrite, for the same runs.
        value_copied: bool = false,
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
    /// it releases through on the way to the loop's exit, and the
    /// temporary ledger floor it releases down to (`LoopFrame`'s two
    /// depths, made context-free).
    pub const Break = struct {
        unwind: u32,
        /// The ledger's length as the loop began: temporaries parked
        /// above it belong to the body's current statement and are
        /// released on the way out.
        temps_floor: u32,
        span: Span,
    };

    pub const Continue = struct {
        unwind: u32,
        temps_floor: u32,
        span: Span,
    };

    pub const Return = struct {
        values: []const NodeRef,
        /// The per-value store decisions, parallel to `values` — how
        /// the return channel took each value's storage
        /// (`ownedForStore`, coupling #3).
        stores: []const StoreKind,
        span: Span,
        /// A shaped return's values are one operand batch; this is the
        /// batch's per-value rewrite, parallel to `values` (empty for
        /// the single-value form, which lowers no batch).
        copied: []const bool = &.{},
    };

    pub const Guarded = struct {
        /// The guarded statement itself — the call written as a
        /// statement, or the store receiving it — whose failing side
        /// performs none of its replacement stores (docs/RETURNS.md).
        attempt: *const Statement,
        /// The handler block, run only where the call raised.
        handler: Block,
        /// The binding of `catch NAME:`, holding the error's words —
        /// null when no name was written.
        error_local: ?LocalId,
        span: Span,
    };

    pub const Match = struct {
        scrutinee: NodeRef,
        /// The hidden slot the scrutinee is spilled into — every arm's
        /// test reloads it, because a register never crosses a block.
        held: LocalId,
        /// The arms in written order, each resolved to its member.
        arms: []const Arm,
        /// Null when the arms cover every member: the last arm is then
        /// the fallthrough and needs no test (docs/ENUMS.md R1).
        else_body: ?Block,
        span: Span,

        /// One arm: the member it names, its payload bindings (a union
        /// arm's, in member-field order — empty for a bare-member
        /// arm), and its body.
        pub const Arm = struct {
            member: u32,
            bindings: []const Binding,
            body: Block,
        };

        /// One payload binding: the arm-scoped local and the payload
        /// read stored into it — the recorded `variant_payload`, whose
        /// target is the reload of `held` (docs/UNION.md D10).  The
        /// binding scope's storage releases are re-derived from
        /// `Body.locals`, since a binding is always an alias and never
        /// claims objects.
        pub const Binding = struct { local: LocalId, payload: NodeRef };
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

/// Where a node's value stands as far as storage goes — the one
/// spelling of the property, answered from the node kind alone; the
/// checker and lower both read it, and the checker overrides it only
/// for the two recorded batch rewrites (its `Typed.rewritten`).
pub fn provenance(expression: *const Expression) Provenance {
    return switch (expression.*) {
        // Constants own nothing and view nothing.
        .const_integer, .const_float, .const_boolean, .const_str => .plain,
        // A struct or union zero is a built value that owns its run;
        // every other absence is a constant (`zeroOf`'s rule).
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
        // A program-root container row is a handle, not storage.
        .container_ref => .plain,
        // The slot only ferries the call's value across the branch;
        // the storage question belongs to the call.
        .carried_get => |payload| provenance(payload.origin),
        // String `+` allocates the joined bytes; every numeric binary
        // answers a scalar.
        .binary => |payload| if (payload.result == .str) .fresh else .plain,
        .convert, .unary, .compare => .plain,
        // The wrapped value is a new scalar-shaped `T?`; the storage a
        // string payload views keeps its owner (the tape reads
        // `optional_wrap` as neither fresh nor borrowed).
        .wrap_optional => .plain,
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
            .conversion => |produced| if (produced == .str) .fresh else .plain,
            // The member chains answer a reload of their result slot.
            .enum_name, .variant_name => .view,
        },
        // `try` hands back the call's own value through the carried
        // slot.
        .try_call => |payload| provenance(payload.call),
        // The answer is a reload of the slot both arms stored into.
        .catch_expr => .view,
        // Built whole; each owns its run (docs/UNION.md D8).
        .struct_make, .variant_make, .interface_make => .fresh,
        // These answer fresh *objects*, which the objects park tracks;
        // the storage question the tape asks of them answers no.
        .list_literal, .map_literal, .new_object => .plain,
        // A slice answers a view or a fresh object, never fresh
        // storage (`string_slice`/`list_slice` in the tape's tables).
        .slice => .plain,
        // A task is a resource, not storage.
        .spawn => .plain,
        // Built whole, exactly as a struct value is: a function value
        // owns the two-slot run holding the function it names and the
        // receiver it carries (docs/BINDING.md D12).
        .function_value, .lambda_ref, .bound_method => .fresh,
    };
}

/// The provenance of a materialized zero or folded constant of `of`: a
/// struct or union zero is built whole and owns its run, every other
/// absence is a constant.  Public because `lower.zig` materializes zeros
/// of its own — for a late declaration's fill — and there is one answer.
pub fn zeroOf(of: Type) Provenance {
    return switch (of) {
        .strukt, .variant => .fresh,
        else => .plain,
    };
}

/// The provenance an intrinsic's result carries: the allocators answer
/// fresh storage, the readers answer a view, and the rest answer no
/// storage question at all.  Public for the same reason `zeroOf` is —
/// `lower.zig` asks it of a fallible intrinsic call.
pub fn ofIntrinsic(kind: mir.Intrinsic) Provenance {
    if (kind.makesFreshStorage()) return .fresh;
    return switch (kind) {
        .index_get, .map_get, .key_at, .value_at => .view,
        else => .plain,
    };
}

/// Whether a node produces a *fresh reference object* it owns the one
/// reference to — a `new` container or a literal, a built struct/union or
/// function value, a slice's deep copy, a spawned task, a call's result —
/// as against borrowing one (a name, a field or element read, a narrowed
/// reload) or naming an immortal program constant (docs/MEMORY.md).  This
/// is to objects what `provenance`'s `.fresh` is to storage, and the two
/// disagree exactly where a value owns no bytes but does own a row: a
/// `[..]` list, a `{..}` map, a `new` object are storage-`.plain` yet
/// object-fresh.  Conservative by construction — every borrow and every
/// unclassified form answers `false`, which can only under-release (a
/// leak), never free a value something still holds.
pub fn freshObject(expression: *const Expression) bool {
    return switch (expression.*) {
        .list_literal, .map_literal, .new_object => true,
        .struct_make, .variant_make, .interface_make => true,
        .function_value, .lambda_ref, .bound_method => true,
        .slice, .spawn => true,
        .call => |payload| switch (payload.callee) {
            .function, .indirect => true,
            .intrinsic => |kind| freshObjectIntrinsic(kind),
            .conversion, .enum_name, .variant_name => false,
        },
        // `try f()` hands back the call's own value, so its freshness is
        // the call's.  The branch-crossing reload (`carried_get`) is *not*
        // parked here — the fallible machinery already places its store and
        // release (`replayParkOf` skips it), so parking it again would
        // record a temporary the replay never consumes.
        .try_call => |payload| freshObject(payload.call),
        else => false,
    };
}

/// The object an intrinsic answers, when it answers a fresh one: a deep
/// copy, a slice, a map's freshly built key or value list, or an element
/// taken out of its container.  A read of an element or a map value is a
/// *view* of the container's object, not a fresh one.
fn freshObjectIntrinsic(kind: mir.Intrinsic) bool {
    return switch (kind) {
        .copy_object, .list_slice, .map_keys, .map_values, .pop_value => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Block splits — the computed control-flow property
// ---------------------------------------------------------------------------

/// What `splitsBlocks` has to read to answer exactly: a member chain
/// over a **single**-member enum or union is one constant and no
/// branch at all (`hir/lower.zig`'s `replayEnumText`), so how many
/// members the declaration has is part of the answer.
pub const Declarations = struct {
    enums: []const types.EnumType = &.{},
    variants: []const types.VariantType = &.{},
};

/// Does lowering this node end in a different basic block than it
/// started in?
///
/// A MIR register never crosses a block boundary (`mir/build.zig`),
/// so a value produced before a subtree that branches has to cross the
/// split in a slot instead — the spill.  This is that question,
/// answered **exactly**, off the resolved tree: every arm below is a
/// node kind `hir/lower.zig` either does or does not open a block
/// for, and both halves of the seam read this one answer (hir.zig,
/// coupling #4 — it replaces the AST-shaped guess the checker used to
/// make before anything had a type).
///
/// The switch is exhaustive on purpose: a node kind added later has to
/// say here what its lowering does.  One that opens a block without
/// saying so is caught where it costs least — `lower.zig`'s batch
/// walk observes the block its emission actually left and asserts the
/// decision made here against it.
pub fn splitsBlocks(expression: *const Expression, declared: Declarations) bool {
    return switch (expression.*) {
        // Values, reads and materializations: straight-line, all.
        .const_integer,
        .const_boolean,
        .const_float,
        .const_str,
        .absent,
        .local_get,
        .narrowed_get,
        .constant_ref,
        .container_ref,
        .function_value,
        .lambda_ref,
        => false,
        .field_get => |read| splitsBlocks(read.target, declared),
        .variant_payload => |read| splitsBlocks(read.target, declared),
        .index_get => |read| splitsBlocks(read.target.node, declared) or
            splitsRun(read.indices, declared),
        // The slot only ferries the call's answer; the branch that
        // made the slot necessary is the call's own.
        .carried_get => |carried| splitsBlocks(carried.origin, declared),
        .binary => |operation| splitsBlocks(operation.left, declared) or
            splitsBlocks(operation.right, declared),
        .compare => |comparison| splitsBlocks(comparison.left, declared) or
            splitsBlocks(comparison.right, declared),
        .convert => |conversion| splitsBlocks(conversion.operand, declared),
        .wrap_optional => |wrapped| splitsBlocks(wrapped.operand, declared),
        .unary => |operation| splitsBlocks(operation.operand, declared),
        // The right side runs conditionally, and the answer is the
        // reload of a merge slot: two branches and a new block, always.
        .short_circuit, .coalesce => true,
        .call => |called| splitsCall(called, declared),
        // A fallible call's branch is the whole point of both.
        .try_call, .catch_expr => true,
        .struct_make => |built| splitsBatch(built.operands, declared),
        .interface_make => |built| splitsBlocks(built.receiver, declared),
        .variant_make => |built| splitsBatch(built.operands, declared),
        .list_literal => |literal| splitsRun(literal.elements, declared),
        .map_literal => |literal| for (literal.entries) |entry| {
            if (splitsBlocks(entry.key.node, declared) or
                splitsBlocks(entry.value.node, declared)) break true;
        } else false,
        .slice => |sliced| splitsBlocks(sliced.target.node, declared) or
            (sliced.start != null and splitsBlocks(sliced.start.?.node, declared)) or
            (sliced.stop != null and splitsBlocks(sliced.stop.?.node, declared)),
        .new_object => |made| splitsRun(made.operands, declared),
        // A spawn emits one instruction and no branch; what it is
        // *given* is lowered here, so ask the arguments — and only
        // them, because the call itself runs on the worker's runtime
        // and its own fallibility never reaches this frame.
        .spawn => |worker| splitsBatch(worker.call.call.operands, declared),
        .bound_method => |bound| splitsBlocks(bound.receiver, declared),
    };
}

/// Whether lowering a call opens a block: its operands, the member
/// chain the two enum and union text forms expand to, and the branch
/// a fallible answer is tested on.
fn splitsCall(called: Expression.Call, declared: Declarations) bool {
    if (splitsBatch(called.operands, declared)) return true;
    if (called.fallible) return true;
    return switch (called.callee) {
        // `string(m)` over a one-member enum is that member's name and
        // nothing else; every other chain compares and branches
        // (docs/ENUMS.md D5, R2).
        .enum_name => |index| called.result != .str or
            declared.enums[index].members.len > 1,
        .variant_name => |index| declared.variants[index].members.len > 1,
        // The callee expression is lowered in this frame beside the
        // arguments, so a branch inside it is this call's own.
        .indirect => |through| splitsBlocks(through.callee, declared),
        .function, .intrinsic, .conversion => false,
    };
}

/// Whether any operand of a batch splits.  Defaulted entries are
/// materialized constants and never do, but they are asked anyway:
/// they are lowered after the written operands, so a split in one
/// would strand exactly the same registers.
pub fn splitsBatch(batch: OperandBatch, declared: Declarations) bool {
    for (batch.operands) |operand| {
        if (splitsBlocks(operand, declared)) return true;
    }
    return false;
}

/// Whether any operand of a non-permuting run splits.
fn splitsRun(operands: []const Operand, declared: Declarations) bool {
    for (operands) |operand| {
        if (splitsBlocks(operand.node, declared)) return true;
    }
    return false;
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
    left.* = .{ .local_get = .{ .local = 1, .result = .i64, .span = test_span } };
    const right = try arena.create(Expression);
    right.* = .{ .const_integer = .{ .value = 1, .result = .i64, .span = test_span } };
    const sum = try arena.create(Expression);
    sum.* = .{ .binary = .{ .op = .add, .left = left, .right = right, .result = .i64, .span = test_span } };
    const indices = try arena.alloc(Operand, 1);
    indices[0] = .{ .node = sum };
    const element = try arena.create(Expression);
    element.* = .{ .index_get = .{
        .target = .{ .node = target },
        .indices = indices,
        .result = .str,
        .span = test_span,
        .park = .{
            .local = 5,
            .storage = true,
            .released_storage = true,
        },
    } };

    try testing.expect(element.result() == .str);
    try testing.expectEqual(test_span.start, element.span().start);
    try testing.expectEqual(@as(LocalId, 5), element.park().?.local);
    try testing.expect(element.park().?.storage);
    try testing.expect(target.park() == null);
    try testing.expect(sum.result() == .i64);

    // A narrowed read remembers the payload the flow analysis proved.
    const narrowed = try arena.create(Expression);
    narrowed.* = .{ .narrowed_get = .{
        .local = 2,
        .payload = .f64,
        .result = .f64,
        .span = test_span,
    } };
    try testing.expect(narrowed.narrowed_get.payload.eql(narrowed.result()));

    // A statement tree: a block that releases its slot on the way out,
    // a break that unwinds two scopes, a return that moves one local.
    const statements = try arena.alloc(Statement, 3);
    statements[0] = .{ .declare = .{ .local = 3, .value = element, .store = .take, .span = test_span } };
    statements[1] = .{ .break_ = .{ .unwind = 2, .temps_floor = 1, .span = test_span } };
    const returned = try arena.alloc(NodeRef, 1);
    returned[0] = narrowed;
    const returned_stores = try arena.alloc(StoreKind, 1);
    returned_stores[0] = .copy;
    statements[2] = .{ .return_ = .{
        .values = returned,
        .stores = returned_stores,
        .span = test_span,
    } };
    const releases = try arena.alloc(Release, 1);
    releases[0] = .{ .local = 3, .storage = true };
    const block: Statement = .{ .block = .{
        .statements = statements,
        .releases = releases,
        .span = test_span,
    } };

    try testing.expectEqual(test_span.end, block.span().end);
    try testing.expectEqual(@as(u32, 2), statements[1].break_.unwind);
    try testing.expectEqual(@as(u32, 1), statements[1].break_.temps_floor);
    try testing.expectEqual(@as(LocalId, 3), block.block.releases[0].local);
    try testing.expectEqual(StoreKind.copy, statements[2].return_.stores[0]);

    // The guarded statement wraps its attempt whole, and a match's
    // arms carry their resolved members and payload bindings.
    const attempt = try arena.create(Statement);
    attempt.* = statements[0];
    const guarded: Statement = .{ .guarded = .{
        .attempt = attempt,
        .handler = block.block,
        .error_local = 4,
        .span = test_span,
    } };
    try testing.expectEqual(@as(LocalId, 3), guarded.guarded.attempt.declare.local);
    try testing.expectEqual(@as(LocalId, 4), guarded.guarded.error_local.?);

    const bindings = try arena.alloc(Statement.Match.Binding, 1);
    bindings[0] = .{ .local = 6, .payload = narrowed };
    const arms = try arena.alloc(Statement.Match.Arm, 1);
    arms[0] = .{ .member = 1, .bindings = bindings, .body = block.block };
    const matched: Statement = .{ .match = .{
        .scrutinee = narrowed,
        .held = 5,
        .arms = arms,
        .else_body = null,
        .span = test_span,
    } };
    try testing.expectEqual(@as(u32, 1), matched.match.arms[0].member);
    try testing.expectEqual(@as(LocalId, 6), matched.match.arms[0].bindings[0].local);
    try testing.expectEqual(test_span.start, matched.span().start);

    // A destructuring bind declares one slot per value, each with its
    // own store decision.
    const bound = try arena.alloc(LocalId, 2);
    bound[0] = 7;
    bound[1] = 8;
    const bind_stores = try arena.alloc(StoreKind, 2);
    bind_stores[0] = .plain;
    bind_stores[1] = .copy;
    const destructured: Statement = .{ .destructure = .{
        .locals = bound,
        .value = element,
        .stores = bind_stores,
        .span = test_span,
    } };
    try testing.expectEqual(@as(LocalId, 8), destructured.destructure.locals[1]);
    try testing.expectEqual(StoreKind.copy, destructured.destructure.stores[1]);

    // A body lists every slot, named and hidden, in declaration order,
    // and carries the flip's gap gate.
    const locals = try arena.alloc(LocalDecl, 2);
    locals[0] = .{ .name = "xs", .local_type = .{ .heap = 2 }, .owns_storage = false, .span = test_span };
    locals[1] = .{ .name = null, .local_type = .str, .owns_storage = true, .span = test_span };
    const body: Body = .{ .statements = statements, .locals = locals };
    try testing.expect(body.locals[1].name == null);
    try testing.expect(body.locals[1].owns_storage);
    try testing.expectEqual(@as(u32, 0), body.gaps);
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
    const text = try node(arena, .{ .const_str = .{ .constant = 0, .result = .str, .span = test_span } });
    try testing.expectEqual(Provenance.plain, provenance(text));
    const zero = try node(arena, .{ .absent = .{ .result = .{ .strukt = 0 }, .span = test_span } });
    try testing.expectEqual(Provenance.fresh, provenance(zero));
    const none = try node(arena, .{ .absent = .{ .result = .{ .optional = .i64 }, .span = test_span } });
    try testing.expectEqual(Provenance.plain, provenance(none));

    // Reads are views; the narrowed unwrap is neither fresh nor view.
    const name = try node(arena, .{ .local_get = .{ .local = 0, .result = .str, .span = test_span } });
    try testing.expectEqual(Provenance.view, provenance(name));
    const narrowed = try node(arena, .{ .narrowed_get = .{ .local = 0, .payload = .str, .result = .str, .span = test_span } });
    try testing.expectEqual(Provenance.plain, provenance(narrowed));
    const field = try node(arena, .{ .field_get = .{ .target = name, .layout = 0, .field = 1, .result = .str, .span = test_span } });
    try testing.expectEqual(Provenance.view, provenance(field));
    const payload = try node(arena, .{ .variant_payload = .{ .target = name, .variant = 0, .member = 1, .field = 0, .result = .str, .span = test_span } });
    try testing.expectEqual(Provenance.view, provenance(payload));
    const indices = try arena.alloc(Operand, 0);
    const element = try node(arena, .{ .index_get = .{ .target = .{ .node = name }, .indices = indices, .result = .str, .span = test_span } });
    try testing.expectEqual(Provenance.view, provenance(element));

    // A folded constant materializes as its value does.
    const folded_struct = try node(arena, .{ .constant_ref = .{ .constant = 0, .result = .{ .strukt = 1 }, .span = test_span } });
    try testing.expectEqual(Provenance.fresh, provenance(folded_struct));
    const folded_text = try node(arena, .{ .constant_ref = .{ .constant = 1, .result = .str, .span = test_span } });
    try testing.expectEqual(Provenance.plain, provenance(folded_text));

    // String `+` allocates; numeric binaries answer scalars.
    const join = try node(arena, .{ .binary = .{ .op = .add, .left = name, .right = text, .result = .str, .span = test_span } });
    try testing.expectEqual(Provenance.fresh, provenance(join));
    const sum = try node(arena, .{ .binary = .{ .op = .add, .left = name, .right = name, .result = .i64, .span = test_span } });
    try testing.expectEqual(Provenance.plain, provenance(sum));

    // Both slot-merging operators answer a reload of the slot.
    const either = try node(arena, .{ .short_circuit = .{ .op = .logic_or, .left = name, .right = name, .result = .boolean, .span = test_span } });
    try testing.expectEqual(Provenance.view, provenance(either));
    const fallback = try node(arena, .{ .coalesce = .{ .value = narrowed, .fallback = .{ .value = text }, .result = .str, .span = test_span } });
    try testing.expectEqual(Provenance.view, provenance(fallback));
    const asserted = try node(arena, .{ .coalesce = .{ .value = narrowed, .fallback = .{ .leaving = text }, .result = .str, .span = test_span } });
    try testing.expectEqual(Provenance.view, provenance(asserted));

    // A call's answer is the caller's — through a name or a function
    // value alike; an intrinsic answers what its table row says; the
    // member chains answer a reload; the carried reload and `try`
    // follow the call.
    const batch: OperandBatch = .{ .operands = &.{}, .slots = &.{}, .borrow_copy = &.{} };
    const called = try node(arena, .{ .call = .{ .callee = .{ .function = 0 }, .operands = batch, .fallible = true, .result = .str, .span = test_span } });
    try testing.expectEqual(Provenance.fresh, provenance(called));
    const through = try node(arena, .{ .call = .{ .callee = .{ .indirect = .{ .callee = name, .signature = 0 } }, .operands = batch, .fallible = false, .result = .str, .span = test_span } });
    try testing.expectEqual(Provenance.fresh, provenance(through));
    const looked_up = try node(arena, .{ .call = .{ .callee = .{ .intrinsic = .map_get }, .operands = batch, .fallible = false, .result = .str, .span = test_span } });
    try testing.expectEqual(Provenance.view, provenance(looked_up));
    const made_text = try node(arena, .{ .call = .{ .callee = .{ .intrinsic = .str_value }, .operands = batch, .fallible = false, .result = .str, .span = test_span } });
    try testing.expectEqual(Provenance.fresh, provenance(made_text));
    const member_name = try node(arena, .{ .call = .{ .callee = .{ .enum_name = 0 }, .operands = batch, .fallible = false, .result = .str, .span = test_span } });
    try testing.expectEqual(Provenance.view, provenance(member_name));
    const union_name = try node(arena, .{ .call = .{ .callee = .{ .variant_name = 0 }, .operands = batch, .fallible = false, .result = .str, .span = test_span } });
    try testing.expectEqual(Provenance.view, provenance(union_name));
    const carried = try node(arena, .{ .carried_get = .{ .slot = 4, .origin = called, .result = .str, .span = test_span } });
    try testing.expectEqual(Provenance.fresh, provenance(carried));
    const attempted = try node(arena, .{ .try_call = .{ .call = carried, .temps_floor = 0, .result = .str, .span = test_span } });
    try testing.expectEqual(Provenance.fresh, provenance(attempted));
    const caught = try node(arena, .{ .catch_expr = .{ .call = carried, .fallback = .{ .value = text }, .temps_floor = 0, .result = .str, .span = test_span } });
    try testing.expectEqual(Provenance.view, provenance(caught));
    const asserted_catch = try node(arena, .{ .catch_expr = .{ .call = carried, .fallback = .{ .leaving = text }, .temps_floor = 1, .result = .str, .span = test_span } });
    try testing.expectEqual(Provenance.view, provenance(asserted_catch));

    // Construction: built values own their runs; a fresh container is
    // an object, not storage; the duplicate is nobody's yet.
    const fields = try arena.alloc(NodeRef, 1);
    fields[0] = text;
    const field_slots = try arena.alloc(u32, 1);
    field_slots[0] = 0;
    const no_rewrites = try arena.alloc(bool, 1);
    no_rewrites[0] = false;
    const one_field: OperandBatch = .{
        .operands = fields,
        .slots = field_slots,
        .borrow_copy = no_rewrites,
    };
    const built = try node(arena, .{ .struct_make = .{ .layout = 0, .operands = one_field, .result = .{ .strukt = 0 }, .span = test_span } });
    try testing.expectEqual(Provenance.fresh, provenance(built));
    const member = try node(arena, .{ .variant_make = .{ .variant = 0, .member = 0, .operands = batch, .result = .{ .variant = 0 }, .span = test_span } });
    try testing.expectEqual(Provenance.fresh, provenance(member));
    const elements = try arena.alloc(Operand, 1);
    elements[0] = .{ .node = text, .copied = true };
    const listed = try node(arena, .{ .list_literal = .{ .elements = elements, .result = .{ .heap = 0 }, .span = test_span } });
    try testing.expectEqual(Provenance.plain, provenance(listed));
    try testing.expect(listed.list_literal.elements[0].copied);
    const fresh_object = try node(arena, .{ .new_object = .{ .heap_type = 0, .operands = &.{}, .result = .{ .heap = 0 }, .span = test_span } });
    try testing.expectEqual(Provenance.plain, provenance(fresh_object));
    const sliced = try node(arena, .{ .slice = .{ .target = .{ .node = name }, .start = null, .stop = null, .result = .str, .span = test_span } });
    try testing.expectEqual(Provenance.plain, provenance(sliced));
    const worker = try node(arena, .{ .spawn = .{ .call = called, .result = .{ .heap = 1 }, .span = test_span } });
    try testing.expectEqual(Provenance.plain, provenance(worker));
    // A function value is built whole and owns the run holding the
    // function it names and the receiver it carries, bound or not.
    const named = try node(arena, .{ .function_value = .{ .function = 2, .result = .{ .function = 0 }, .span = test_span } });
    try testing.expectEqual(Provenance.fresh, provenance(named));
    const synthesized = try node(arena, .{ .lambda_ref = .{ .function = 3, .result = .{ .function = 0 }, .span = test_span } });
    try testing.expectEqual(Provenance.fresh, provenance(synthesized));
    const bound = try node(arena, .{ .bound_method = .{
        .function = 4,
        .receiver = name,
        .result = .{ .function = 0 },
        .span = test_span,
    } });
    try testing.expectEqual(Provenance.fresh, provenance(bound));

    // The two folded/widened materializations that ride construction:
    // a wrapped optional is a new plain value whatever its payload
    // was, and a program-root container row is a handle.
    const wrapped = try node(arena, .{ .wrap_optional = .{ .operand = name, .result = .{ .optional = .str }, .span = test_span } });
    try testing.expectEqual(Provenance.plain, provenance(wrapped));
    const rooted = try node(arena, .{ .container_ref = .{ .row = 4, .result = .{ .heap = 0 }, .span = test_span } });
    try testing.expectEqual(Provenance.plain, provenance(rooted));
}

test "splitsBlocks names exactly the lowerings that open a block" {
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

    // Two enums, one of each shape: a member chain over a single
    // member is one constant, so only the two-member one branches.
    var one_member = [_]types.EnumMember{.{ .name = "only", .value = 0 }};
    var two_members = [_]types.EnumMember{
        .{ .name = "stored", .value = 0 },
        .{ .name = "deflated", .value = 1 },
    };
    const enums = [_]types.EnumType{
        .{ .name = "Single", .backing = .i32, .members = &one_member },
        .{ .name = "Method", .backing = .i32, .members = &two_members },
    };
    const declared: Declarations = .{ .enums = &enums };

    const name = try node(arena, .{ .local_get = .{ .local = 0, .result = .i64, .span = test_span } });
    const literal = try node(arena, .{ .const_integer = .{ .value = 1, .result = .i64, .span = test_span } });
    try testing.expect(!splitsBlocks(name, declared));
    try testing.expect(!splitsBlocks(literal, declared));

    // Straight-line operators stay straight-line, and ask their
    // operands.
    const sum = try node(arena, .{ .binary = .{ .op = .add, .left = name, .right = literal, .result = .i64, .span = test_span } });
    try testing.expect(!splitsBlocks(sum, declared));

    // `and`/`or` and the optional fallback are control flow.
    const flag = try node(arena, .{ .const_boolean = .{ .value = true, .result = .boolean, .span = test_span } });
    const circuit = try node(arena, .{ .short_circuit = .{ .op = .logic_and, .left = flag, .right = flag, .result = .boolean, .span = test_span } });
    try testing.expect(splitsBlocks(circuit, declared));
    const fallback = try node(arena, .{ .coalesce = .{ .value = name, .fallback = .{ .value = literal }, .result = .i64, .span = test_span } });
    try testing.expect(splitsBlocks(fallback, declared));

    // A split anywhere inside an operand run reaches the run.
    const outer = try node(arena, .{ .binary = .{ .op = .add, .left = sum, .right = fallback, .result = .i64, .span = test_span } });
    try testing.expect(splitsBlocks(outer, declared));

    // A call: its operands, its fallibility, and the member chains.
    const operands = try arena.alloc(NodeRef, 1);
    operands[0] = name;
    const slots = try arena.alloc(u32, 1);
    slots[0] = 0;
    const no_copies = try arena.alloc(bool, 1);
    no_copies[0] = false;
    const one_operand: OperandBatch = .{ .written = 1, .operands = operands, .slots = slots, .borrow_copy = no_copies };
    const plain_call = try node(arena, .{ .call = .{ .callee = .{ .function = 0 }, .operands = one_operand, .fallible = false, .result = .i64, .span = test_span } });
    try testing.expect(!splitsBlocks(plain_call, declared));
    const fallible_call = try node(arena, .{ .call = .{ .callee = .{ .function = 0 }, .operands = one_operand, .fallible = true, .result = .i64, .span = test_span } });
    try testing.expect(splitsBlocks(fallible_call, declared));
    const single_name = try node(arena, .{ .call = .{ .callee = .{ .enum_name = 0 }, .operands = one_operand, .fallible = false, .result = .str, .span = test_span } });
    try testing.expect(!splitsBlocks(single_name, declared));
    const member_name = try node(arena, .{ .call = .{ .callee = .{ .enum_name = 1 }, .operands = one_operand, .fallible = false, .result = .str, .span = test_span } });
    try testing.expect(splitsBlocks(member_name, declared));
    // `Method(n)` compares its way in whatever the member count.
    const from_number = try node(arena, .{ .call = .{ .callee = .{ .enum_name = 0 }, .operands = one_operand, .fallible = false, .result = .{ .optional = .{ .enumeration = .{ .index = 0, .backing = .i32 } } }, .span = test_span } });
    try testing.expect(splitsBlocks(from_number, declared));

    // `try` and `catch` are the fallible branch itself; a spawn is
    // one instruction and asks only what it is given.
    const carried = try node(arena, .{ .carried_get = .{ .slot = 1, .origin = fallible_call, .result = .i64, .span = test_span } });
    try testing.expect(splitsBlocks(carried, declared));
    const attempted = try node(arena, .{ .try_call = .{ .call = carried, .temps_floor = 0, .result = .i64, .span = test_span } });
    try testing.expect(splitsBlocks(attempted, declared));
    const worker = try node(arena, .{ .spawn = .{ .call = fallible_call, .result = .{ .heap = 0 }, .span = test_span } });
    try testing.expect(!splitsBlocks(worker, declared));
}
