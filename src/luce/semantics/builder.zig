//! The checked walk of a function body — pass two of stage 4, and the
//! check half of the check/lower seam (hir.zig).
//!
//! Scope management, local declaration, ownership tracking, operand
//! ordering, statement and expression checking, call resolution, and
//! builtin typing.  Every decision this walk reaches is **recorded on
//! the typed tree** (`nodes.Body`) as it is reached: checking and
//! recording are one visit because resolving `xs.append(v)` needs the
//! receiver's type and typing it needs the name resolved first.  What
//! is *not* here is emission — `hir/lower.zig` consumes the
//! recorded tree and produces stage 6's tape, and nothing below
//! touches a `mir.build.Lowering` at all.
//!
//! **This file is the walker's spine, and its concerns are its
//! siblings.**  `FunctionBuilder` itself lives here — its state, its
//! scopes and locals, name resolution, the landing rules that fit one
//! type into another, the operand batch, and the expression dispatch
//! every form arrives through — and each concern that could be named
//! on its own is a file beside it, holding free functions over
//! `*FunctionBuilder`:
//!
//!   flow.zig        — narrowing and root provenance: save, restore, join.
//!   ledger.zig      — the statement-temporary ledger and the store kinds.
//!   recorder.zig    — the typed tree's recording API.
//!   refusals.zig    — what the walk says when it says no.
//!   statements.zig  — the statement walk.
//!   assign.zig      — assignment and the three shapes of place.
//!   expressions.zig — the ownership verbs, the constructors, the operators.
//!   calls.zig       — call, method and argument resolution.
//!   construct.zig   — construction, conversion, and the builtin dispatch.
//!
//! A file boundary in Zig is a privacy boundary, so the price of that
//! is stated plainly: the walker's own helpers — `fail`, `fit`,
//! `lowerExpression` and the rest — are `pub` here, and `pub` on this
//! type means *visible to the walker's own files*, nothing wider.  The
//! stage's outside surface is unchanged and small: pass one makes a
//! `FunctionBuilder`, declares its parameters, calls `lowerBlock`, and
//! takes `recorded_body` — which is why those stay methods below even
//! where the work moved out.

const std = @import("std");
const source_mod = @import("../source.zig");
const ast = @import("../parse.zig").ast;
const types = @import("../support/types.zig");
const conversionNamed = types.conversionNamed;
const mir = @import("../mir.zig");
const helpers = @import("helpers.zig");

// The typed tree the check/lower seam hands over (hir.zig).  This
// walk *records* it as it checks, and `recorder.zig` is the one file
// that builds a node.
const nodes = @import("../hir.zig").nodes;

// What running a subtree could disturb, asked before it is lowered
// (`effects.zig`).
const effects = @import("effects.zig");

// What the language spells, and what each spelling lowers to
// (`builtins.zig`).  Named here under the names the walk uses, so the
// tables read the same whether the reader came from the dispatch or
// from the editor grammar that is generated out of them.
const builtins_mod = @import("builtins.zig");
const builtins = builtins_mod.builtins;

// Pass one, for the one thing this walk needs from it: the collected
// project it runs against.
const Analyzer = @import("declarations.zig").Analyzer;
const naming = @import("naming.zig");
const resolve = @import("resolve.zig");
const shapes = @import("shapes.zig");
const signatures = @import("signatures.zig");

// The stage's shared vocabulary (`semantics/context.zig`).
const context = @import("context.zig");
const FunctionDeclInfo = context.FunctionDeclInfo;
const EnclosingLocal = context.EnclosingLocal;
const LocalInfo = context.LocalInfo;
const Scope = context.Scope;
const FoundLocal = context.FoundLocal;
const LoopFrame = context.LoopFrame;
const isReserved = context.isReserved;
const Error = context.Error;
const Allocator = std.mem.Allocator;
const Span = source_mod.Span;
const Type = types.Type;
const LocalId = mir.LocalId;

// The walker's own files: free functions over `*FunctionBuilder`, one
// per concern, listed in the header above.  Two of them own a type
// this walker holds — the ledger's slot and the recorder's frame.
const calls = @import("calls.zig");
const closures = @import("closures.zig");
const construct = @import("construct.zig");
const expressions = @import("expressions.zig");
const flow = @import("flow.zig");
const ledger = @import("ledger.zig");
const recorder = @import("recorder.zig");
const refusals = @import("refusals.zig");
const statements = @import("statements.zig");
const StatementFrame = recorder.StatementFrame;
const TempSlot = ledger.TempSlot;

/// A checked expression's result: the typed tree's node for it and the
/// type the checker decided it has.  A *typed node*, and not a value —
/// nothing here holds one; `runtime.Value` is the thing that does.
pub const Typed = struct {
    /// The typed tree's node for this expression (hir.zig): what
    /// the walk records, and what `hir.lower` consumes.
    node: nodes.NodeRef,
    value_type: Type,
    /// The batch-rewrite override (docs/STRINGS.md): a defensive
    /// borrow copy leaves the value *fresh* whatever the borrow was,
    /// and a spill reload leaves it a *view* of its slot — facts the
    /// recorded flags carry, which `hir.lower` re-derives identically
    /// (its `BatchEntry.provenance`).  Null everywhere else, so the
    /// node kind answers.
    rewritten: ?Provenance = null,

    /// Where the value's storage stands as far as the ownership
    /// questions go: the node kind's answer (`nodes.provenance`),
    /// unless a batch rewrite replaced the value under the node.
    pub fn provenance(self: Typed) Provenance {
        return self.rewritten orelse nodes.provenance(self.node);
    }
};

/// Where a value's storage stands the moment it is produced — the
/// typed tree's vocabulary (`nodes.Provenance`), computed from the
/// node kind by `nodes.provenance` and never stamped by hand.
pub const Provenance = nodes.Provenance;

/// The one source expression that names the class object whose lifetime is
/// ending. Lifecycle checking grants this borrow only as a field/method
/// receiver or when it is stored weakly; every strong value use is a
/// resurrection attempt and is diagnosed before ownership lowering.
pub fn isBareSelf(expression: *const ast.Expression) bool {
    return switch (expression.*) {
        .name => |name| std.mem.eql(u8, name.text, "self"),
        else => false,
    };
}

/// Whether a call answering a return shape is being received by a
/// destructuring statement, refused in an ordinary value position, or
/// returned directly (docs/RETURNS.md and the SELF polish ruling).
pub const ShapePosition = enum { refused, receive, returning };

/// A closure expression is currently landing in a field of its own class.
/// `closures.zig` uses this one-hop context to reject the direct ARC cycle
/// `self.callback = func(): use(self)` while still accepting a closure that
/// does not capture `self` or captures it weakly.
pub const ClosureDestination = struct {
    field: []const u8,
    span: Span,
};

/// A fallible call awaiting the `try` or `catch` written in front
/// of it.
const Opened = struct {
    /// How many statement temporaries existed when the call's
    /// branch was taken.  Anything parked after it belongs to the
    /// side where the call *returned*, and releasing it on the
    /// failing side would release a slot nothing ever stored into
    /// — the floor the try/catch nodes record (nodes.TryCall).
    temps_floor: usize,
};

/// Does this binding own the storage in its slot?  Every real
/// binding does — `let b = a` copies a's string fields even while
/// it aliases a's objects (S26) — and a parameter never does: its
/// bytes belong to the caller's binding, which outlives the call
/// (docs/STRINGS.md).
pub const StorageClass = enum { owns, borrows };

/// A value that reached its place, and whether it got there by the
/// `T <: T?` widening — which is how an assignment knows the slot
/// definitely holds something now.
const Fitted = struct { value: Typed, present: bool };

/// Lower a left-to-right operand sequence whose values must all
/// be usable together afterwards.  Registers are block-local in
/// the emission, so every operand followed by a block-splitting
/// one is carried across the split in a hidden local — the slot,
/// the store and the reload are all lower's, and what the check
/// keeps of it is the reload's *provenance*.  The returned values
/// live in the arena.
/// Operand counts this stage's scratch fits without allocating.
/// Every binary operator has two, an index has at most five, and a
/// call of more than this is rare — but `lowerOperands` runs for
/// each of them, and two allocate-and-free pairs per operator is
/// most of the compiler's allocator traffic when it is not one.
const inline_operands = 8;

/// A nested store's written path: the root local's type, and the
/// accessors from it down to the leaf in written order.
///
/// Every landing the batch needs is a walk of this and nothing else —
/// a field names its own type and a container names its element — so
/// the leaf is known before a single operand is lowered, however deep
/// the path runs.
const ChainLanding = struct {
    root: Type,
    steps: []const *const ast.Expression,
};

/// What one operand of a batch lands on, as `landsOn` answers it.
///
/// The third answer is the reason this is not a plain `?Type`: a
/// landing can *fail*, and when it does the receiver's own sentence
/// has already been said — a method the receiver does not have, or
/// one handed more arguments than it takes.  The batch stops there
/// rather than lowering an argument that would be refused for wanting
/// a place the call never had.
const Place = union(enum) {
    /// Nothing names one; the operand takes its own default.
    unknown,
    /// The type written down for it.
    lands: Type,
    /// The batch cannot go on and the reason is reported.
    refused,
};

pub const Landing = union(enum) {
    /// Nothing is written down; every operand takes the default.
    nothing,
    /// One type per operand, positionally.
    places: []const Type,
    /// One optional type per operand.  Runtime map literals use
    /// this because their keys always have a landing (`long` when
    /// unannotated), while their values only do when an annotated
    /// map names one.
    maybe_places: []const ?Type,
    /// Operand zero is a method receiver and names what the rest
    /// take — through the declaration for a struct receiver,
    /// through `methodParameters` for a builtin one.
    ///
    /// The whole written call, because the landing needs all of it:
    /// which slot an argument fills is what says where it lands and a
    /// named argument may fill a slot its position does not
    /// (docs/ARGS.md D5), and a receiver with no such method at all
    /// is a sentence this batch says for itself.
    method: ast.Method,
    /// Operand zero is a container, the last operand is a value
    /// going into it, and everything between is an index.
    stored_element,
    /// The operands of a **nested** store: every subscript of the
    /// written path in order, then the value at the end.
    ///
    /// `stored_element` at depth, and the reason it is a landing of
    /// its own rather than that one: a nested place's leaf is not
    /// operand zero's element but the end of a written path, and the
    /// path says what it is with nothing lowered.  Without it a place
    /// one field deep would take a bare function name, a lambda, a
    /// union constructor and a bare `none` while the same place two
    /// deep refused them — a rule about how far away a slot is
    /// (docs/BINDING.md D7, docs/FUNCTIONS.md D2).
    chain: ChainLanding,
    /// Operand zero is a container or a string and every other
    /// operand subscripts it — an index or a slice bound.  The
    /// read half of `stored_element`, and it exists because
    /// `m[1] = "one"` landing its key while `m[1]` did not would
    /// be a rule about which side of the equals sign a literal
    /// sits on.
    subscripts,
};

/// One lowered operand batch: the values in written order, and the
/// batch's per-operand rewrite — which operands took the defensive
/// borrow copy in front of a later container-mutating operand.  The
/// flags are what the call nodes record (nodes.OperandBatch); the
/// values' nodes stay the written expressions, pre-rewrite, per that
/// batch's convention.  A spill across a block split is *not* here:
/// it is `nodes.splitsBlocks`' answer about those same nodes, which
/// lower asks itself (hir.zig, coupling #4).  Arena-owned, because
/// the recorded batch outlives the statement.
pub const OperandRun = struct {
    values: []Typed,
    copied: []bool,
};

pub const FunctionBuilder = struct {
    analyzer: *Analyzer,
    module: usize,
    prefix: []const u8,
    /// The function's declared name, for the sentences that say it.
    name: []const u8,
    /// What this function answers, in order — the arity a `return`
    /// is checked against.  `return_type` is the one value the
    /// channel carries, which for two or more is the synthesized
    /// layout they ride in (docs/RETURNS.md).
    results: []const Type = &.{},
    return_type: Type = .none,
    /// Whether the declaration wrote `!` — what `raise` and the
    /// try-pass-through check against (docs/FAILURE.md).
    fallible: bool = false,
    /// True only while checking a class's hidden `deinit:` function.
    is_deinitializer: bool = false,
    /// A tightly scoped permission for the bare `self` borrow. Callers save
    /// and restore it around a direct receiver or weak-store expression.
    allow_deinitializer_self: bool = false,
    /// This declaration sits inside a struct/enum but said `static`,
    /// so a use of `self` gets the teaching sentence rather than an
    /// ordinary unknown-name report.
    static_member: bool = false,
    scopes: std.ArrayList(Scope) = .empty,
    loops: std.ArrayList(LoopFrame) = .empty,
    /// Statement temporaries (S3): every fresh, unowned object is
    /// parked in a hidden local; the end of the statement releases the
    /// ones nothing adopted.  Adoption is a runtime re-owning, so a
    /// stale release is a safe no-op.
    temps: std.ArrayList(TempSlot) = .empty,
    /// How many expression levels are open, for the nesting bound.
    depth: u32 = 0,
    /// Names whose declaration was abandoned after an error:
    /// `let total = nope` reports the unknown name, but `total` is a
    /// name the reader wrote and meant.  Answering every later use
    /// with "unknown name total" turns one mistake into a screenful of
    /// noise, so those uses are met with silence — the error that
    /// matters is already on the list.  rustc calls the same idea an
    /// error type; this stage has no type to spare, so it remembers
    /// the names instead.
    undeclared: std.StringHashMapUnmanaged(void) = .empty,
    /// Which optional locals are known, right here, to hold a value.
    ///
    /// **Narrowing is the feature; `?.` is the convenience**
    /// (docs/FAILURE.md).  Luce deletes most of what makes flow
    /// analysis expensive elsewhere — no closures to capture and
    /// invalidate, no subtyping beyond `T <: T?`, no shadowing, no
    /// aliasing of locals, no concurrency — so Dart's promotion chain
    /// collapses to this: a set of locals, saved and joined around
    /// each branch, and cleared for anything a loop body assigns.
    /// Short enough that a linear scan is the whole lookup.
    narrowed: std.ArrayList(LocalId) = .empty,
    /// Every local name in scope where this function's **lambda** was
    /// written, or null for a function somebody declared
    /// (`context.FunctionDeclInfo.enclosing_locals`).  Read by the
    /// capture refusal and by lambda-parameter no-shadowing checks.
    enclosing_locals: ?[]const EnclosingLocal = null,
    /// Mutable names a block closure in this function may capture. A syntax
    /// prepass fills this before lowering so their cells exist on every path.
    captured_mutables: std.StringHashMapUnmanaged(void) = .empty,
    /// Prologue metadata when this function is a block closure body.
    closure_captures: []const context.ClosureCaptureInfo = &.{},
    /// The class field the next closure literal would be stored into, when
    /// checking a direct `self.field = ...` assignment. Saved and restored by
    /// assignment lowering so nested expressions cannot leak the context.
    closure_destination: ?ClosureDestination = null,
    /// Set for exactly one hop.  `try` and `catch` raise it, and the
    /// very next `lowerExpressionInner` reads and clears it, so the
    /// permission reaches the call they are written in front of and
    /// nothing nested inside it (docs/FAILURE.md).
    allow_fallible: bool = false,
    /// Where a multi-valued call currently stands.
    ///
    /// A call that answers a return shape may be received by a
    /// destructuring let/var or existing-name assignment, or discarded
    /// as a statement.  Statement position is `as_statement`, which
    /// this walk already carries; this is the receiving position.
    ///
    /// Set for exactly one hop the way `allow_fallible` is, so the
    /// permission reaches the call it was raised in front of and
    /// nothing nested inside it: `let a, b = f(g())` binds `f`'s two
    /// values and still refuses `g`'s.
    ///
    /// `.returning` is `.refused` with one extra clause on the
    /// sentence.  `return minmax(xs)` is the pass-through Go allows
    /// and this language does not — Go pays for it with a rule saying
    /// a multi-valued call used as arguments must be the *only*
    /// arguments — and the reader is owed the one line that fixes it.
    shape_position: ShapePosition = .refused,
    /// The container type the next bracket or map literal should be
    /// built at, when the place it is going into names one —
    /// `let xs: list(double) = [1, 2, 3]`, a rank-1 array annotation,
    /// or `let names: map(string, long) = {"one": 1}`.  A literal has
    /// no annotation of its own, so the container supplies both its
    /// shape and the landing types of its contents.
    ///
    /// Set for exactly one hop, the way `allow_fallible` is:
    /// `lowerExpressionInner` reads and clears it, so it reaches the
    /// literal it was raised in front of and nothing nested inside it.
    /// Inference where nothing is expected is untouched — `let xs =
    /// [1, 2, 3]` is still a `list(long)`.
    wanted_container: ?Type = null,
    /// The scalar type the next expression lands on, when the place it
    /// is going into names one — `let x: double = 7` (docs/TYPES.md §1,
    /// D3).  **A numeric literal has no type of its own**; it takes the
    /// type of its context if it fits, and this is how the context
    /// reaches it.
    ///
    /// Set for exactly one hop, the way `wanted_container` is:
    /// `lowerExpressionInner` reads and clears it, so it reaches the
    /// literal it was raised in front of and nothing nested inside it
    /// that has a landing width of its own.  Inference where nothing is
    /// expected is untouched — `let n = 1` still takes the default.
    wanted: ?Type = null,
    /// The signature the next expression lands on, when the place it is
    /// going into names one — `xs.sort_by(by_score)`, `let before:
    /// func(long, long) -> bool = ascending` (docs/FUNCTIONS.md).
    ///
    /// **A function value and a lambda are literals**, in exactly the
    /// sense a number is: a bare declaration name is not a value until
    /// something says which shape it must wear, and a lambda has no
    /// parameter types at all until it lands.  So this is `wanted` for
    /// functions, set and cleared for exactly one hop the same way — and
    /// a lambda that reaches `lowerExpressionInner` with it unset is the
    /// refusal "a lambda needs a place that expects a function".
    wanted_function: ?u32 = null,
    /// What a fallible call left for the `try` or `catch` in front of
    /// it to finish.  Set by `openFallible` and consumed once.
    opened: ?Opened = null,
    /// The typed tree's statement recorder (hir.zig): one frame per
    /// open block, appended by each statement's arm as it records.  A
    /// statement whose children carry no node records nothing —
    /// `lowerBlock` counts the gap — and the final flip is gated on a
    /// gapless tree.
    recorded_blocks: std.ArrayList(StatementFrame) = .empty,
    /// The one-hop hand-over of the `Block` `lowerBlock` just closed:
    /// the caller that owns the surrounding statement consumes it, the
    /// way `opened` travels.
    recorded_block: ?nodes.Block = null,
    /// The tree's per-body locals table (nodes.Body.locals), recorded
    /// beside stage 6's as each slot is made — named and hidden alike
    /// — so the tree's `LocalId`s stay the tape's until the flip walks
    /// this table instead (hir.zig, coupling #5).
    recorded_locals: std.ArrayList(nodes.LocalDecl) = .empty,
    /// Statements the walk could not record (nodes.Body.gaps).
    recorded_gaps: u32 = 0,
    /// The assembled typed tree of this body (`finishBody`), null until
    /// the walk completes.  Nothing consumes it yet — the flip's lower
    /// pass will — and until then it exists so the recording is proven
    /// live over the whole suite.
    recorded_body: ?nodes.Body = null,

    pub fn arena(self: *FunctionBuilder) Allocator {
        return self.analyzer.arena;
    }

    pub fn temporary(self: *FunctionBuilder) Allocator {
        return self.analyzer.temporary;
    }

    /// The declaration tables `nodes.splitsBlocks` reads — the member
    /// counts that tell a one-constant text conversion from a
    /// compare-and-branch chain.  The same tables lower hands it.
    pub fn declarations(self: *const FunctionBuilder) nodes.Declarations {
        return .{
            .enums = self.analyzer.enums.items,
            .variants = self.analyzer.variants.items,
        };
    }

    pub fn deinitScratch(self: *FunctionBuilder) void {
        for (self.scopes.items) |*scope| {
            scope.names.deinit(self.temporary());
            scope.owned.deinit(self.temporary());
        }
        self.scopes.deinit(self.temporary());
        self.loops.deinit(self.temporary());
        self.temps.deinit(self.temporary());
        self.undeclared.deinit(self.temporary());
        self.narrowed.deinit(self.temporary());
        self.captured_mutables.deinit(self.temporary());
        for (self.recorded_blocks.items) |*frame| frame.statements.deinit(self.temporary());
        self.recorded_blocks.deinit(self.temporary());
        self.recorded_locals.deinit(self.temporary());
    }

    pub fn fail(self: *FunctionBuilder, code: []const u8, span: Span, comptime format: []const u8, arguments: anytype) Error!void {
        try self.analyzer.fail(code, span, format, arguments);
    }

    // Scopes and locals ----------------------------------------------------

    pub fn localById(self: *FunctionBuilder, local: LocalId) ?*LocalInfo {
        for (self.scopes.items) |*scope| {
            var names = scope.names.valueIterator();
            while (names.next()) |info| {
                if (info.local == local) return info;
            }
        }
        return null;
    }

    pub fn pushScope(self: *FunctionBuilder) Error!void {
        try self.scopes.append(self.temporary(), .{});
    }

    pub fn popScope(self: *FunctionBuilder) void {
        var scope = self.scopes.pop().?;
        scope.names.deinit(self.temporary());
        scope.owned.deinit(self.temporary());
    }

    pub fn findLocal(self: *FunctionBuilder, name: []const u8) ?FoundLocal {
        var index = self.scopes.items.len;
        while (index > 0) {
            index -= 1;
            if (self.scopes.items[index].names.getPtr(name)) |found| {
                return .{ .info = found };
            }
        }
        return null;
    }

    // Name resolution ------------------------------------------------------
    //
    // What a written name refers to: a module-local declaration, a
    // struct or module namespace, an import.  What is said when it
    // refers to nothing is `refusals.zig`.

    /// Resolve a written declaration name from this module's point of
    /// view: bare names are module-local; a dotted name is either a
    /// module-local struct namespace (Text.width) or an imported one
    /// (geo.helper, geo.Text.width).
    pub fn resolveDeclared(
        self: *FunctionBuilder,
        written: []const u8,
        span: Span,
        origin: ast.CallOrigin,
    ) Error!?[]const u8 {
        if (std.mem.indexOfScalar(u8, written, '.')) |dot| {
            const head = written[0..dot];
            const local_head = try naming.qualify(self.analyzer, self.prefix, head);
            if (self.analyzer.struct_names.contains(local_head) or
                self.analyzer.interface_names.contains(local_head) or
                self.analyzer.enum_names.contains(local_head) or
                self.analyzer.variant_names.contains(local_head))
            {
                return try naming.qualify(self.analyzer, self.prefix, written);
            }
            if (self.analyzer.alias_names.get(local_head)) |alias_index| {
                const target = (try resolve.resolveAlias(self.analyzer, self.module, alias_index, span)) orelse
                    return null;
                const namespace = resolve.namespaceName(self.analyzer, target) orelse {
                    try self.fail(
                        "luce.sema.name",
                        span,
                        "{s} is a type alias for {s}, which has no static members",
                        .{ head, try self.analyzer.typeName(target) },
                    );
                    return null;
                };
                return try std.fmt.allocPrint(self.arena(), "{s}{s}", .{ namespace, written[dot..] });
            }
            if (naming.importsModule(self.analyzer, self.module, head)) {
                return try self.importedName(written);
            }
            // A call the reader never wrote cannot be fixed where it
            // points.  `f"{x:.2f}"` lowers to `strings.format_float`,
            // so the generic message would name a namespace that
            // appears nowhere in the program, under a caret inside an
            // f-string hole.  The rule is the same one — a format spec
            // is a string service like any other — but it has to be
            // said about the syntax that is actually there.
            //
            // **`.written` cannot be reached from here today**, and is
            // the safe default rather than live behavior: a dotted
            // callee only ever arrives on a `.call` node the compiler
            // synthesized, because `namedCallExpression` builds one
            // only from a bare identifier, which holds no dot.  A
            // written `mod.func()` parses as a method and is answered
            // by `methodNamespace` below, which carries its own copy
            // of these words.  Kept, and kept exhaustive, so that the
            // next synthesized callee has to choose rather than
            // inherit a sentence about format specs.
            switch (origin) {
                .written => try self.fail(
                    "luce.sema.import",
                    span,
                    "unknown namespace {s}; import {s} to use it",
                    .{ head, try naming.importSpelling(self.analyzer, head) },
                ),
                .format_spec => try self.fail(
                    "luce.sema.import",
                    span,
                    "a format spec like {{x:.2f}} formats through std.strings; add import std.strings",
                    .{},
                ),
            }
            return null;
        }
        return try naming.qualify(self.analyzer, self.prefix, written);
    }

    /// The declared key of a cross-module reference written in this
    /// function's module (`Analyzer.importedName`): the written text
    /// itself for a module of the program's own root, and the
    /// root-qualified key for a package's (docs/PACKAGES.md D7).
    pub fn importedName(self: *FunctionBuilder, written: []const u8) Error![]const u8 {
        return naming.importedName(self.analyzer, self.module, written);
    }

    pub fn declareLocal(
        self: *FunctionBuilder,
        name: []const u8,
        local_type: Type,
        mutable: bool,
        span: Span,
    ) Error!?LocalId {
        return self.declareLocalAs(name, local_type, mutable, .owns, span);
    }

    pub fn declareLocalAs(
        self: *FunctionBuilder,
        name: []const u8,
        local_type: Type,
        mutable: bool,
        storage_class: StorageClass,
        span: Span,
    ) Error!?LocalId {
        return self.declareLocalKind(name, local_type, mutable, storage_class, false, span);
    }

    /// Declare a zeroing non-owning local. The slot owns neither value
    /// storage nor an object count; every read performs an owned upgrade.
    pub fn declareWeakLocal(
        self: *FunctionBuilder,
        name: []const u8,
        local_type: Type,
        span: Span,
    ) Error!?LocalId {
        return self.declareLocalKind(name, local_type, true, .borrows, true, span);
    }

    fn declareLocalKind(
        self: *FunctionBuilder,
        name: []const u8,
        local_type: Type,
        mutable: bool,
        storage_class: StorageClass,
        weak: bool,
        span: Span,
    ) Error!?LocalId {
        if (isReserved(name) or std.mem.eql(u8, name, "evaluate")) {
            try self.fail("luce.sema.reserved", span, "{s} is a reserved name", .{name});
            return null;
        }
        if (self.findLocal(name)) |found| {
            try self.fail("luce.sema.duplicate", span, "{s} is already declared{s}", .{
                name,
                try naming.declaredAt(self.analyzer, self.analyzer.modules[self.module].file, found.info.declared_at),
            });
            return null;
        }
        const qualified = try naming.qualify(self.analyzer, self.prefix, name);
        if (try naming.firstDeclarationOf(self.analyzer, qualified)) |where| {
            try self.fail("luce.sema.duplicate", span, "{s} is already a top-level declaration{s}", .{ name, where });
            return null;
        }
        const owns = storage_class == .owns;
        const owns_storage = owns and shapes.ownsStorage(self.analyzer, local_type);
        const owns_objects = owns and shapes.carriesObjects(self.analyzer, local_type);
        const local = if (weak)
            try recorder.recordWeakLocal(self, name, local_type, span)
        else
            try recorder.recordLocal(self, name, local_type, owns_storage, span);
        const scope = &self.scopes.items[self.scopes.items.len - 1];
        try scope.names.put(self.temporary(), name, .{
            .local = local,
            .mutable = mutable,
            .weak = weak,
            .declared_at = span,
        });
        if (owns_storage or owns_objects) {
            try scope.owned.append(self.temporary(), .{
                .local = local,
                .storage = owns_storage,
                .objects = owns_objects,
            });
        }
        return local;
    }

    /// Install the implicit receiver as logical parameter zero.
    ///
    /// A reader borrows an ordinary value parameter.  A writer's MIR
    /// slot owns the *representation* needed to drop replaced
    /// strings/struct runs, but this scope never releases it — its
    /// storage belongs to the caller's binding (docs/SELF.md D3-D6).
    pub fn declareReceiver(
        self: *FunctionBuilder,
        receiver_type: Type,
        writes: bool,
        span: Span,
    ) Error!?LocalId {
        if (self.findLocal("self") != null) {
            try self.fail("luce.sema.duplicate", span, "self is already declared", .{});
            return null;
        }
        const owns_storage = writes and shapes.ownsStorage(self.analyzer, receiver_type);
        const local = try recorder.recordLocal(self, "self", receiver_type, owns_storage, span);
        const scope = &self.scopes.items[self.scopes.items.len - 1];
        try scope.names.put(self.temporary(), "self", .{
            .local = local,
            .mutable = writes,
            .declared_at = span,
        });
        return local;
    }

    // Namespaced members ---------------------------------------------------

    /// Whether a dotted chain, written inner-to-outer as
    /// `helpers.dottedChain` collects it, spells an enum member:
    /// `Method.stored`, `zip.Method.stored`.  The last part is the
    /// member and everything in front of it names the enum.
    pub fn namesMember(self: *FunctionBuilder, parts: []const []const u8) bool {
        var written: std.ArrayList(u8) = .empty;
        defer written.deinit(self.temporary());
        var at = parts.len;
        while (at > 1) {
            at -= 1;
            written.appendSlice(self.temporary(), parts[at]) catch return false;
            if (at > 1) written.append(self.temporary(), '.') catch return false;
        }
        const spelled = written.items;
        const head = if (parts.len == 2)
            naming.qualify(self.analyzer, self.prefix, spelled) catch return false
        else
            spelled;
        if (self.analyzer.enum_names.get(head)) |index| {
            return self.analyzer.enums.items[index].findMember(parts[0]) != null;
        }
        if (self.analyzer.variant_names.get(head)) |index| {
            return self.analyzer.variants.items[index].findMember(parts[0]) != null;
        }
        if (self.analyzer.alias_names.get(head)) |alias_index| {
            const info = self.analyzer.alias_decls.items[alias_index];
            if (info.state != .ready) return false;
            return switch (info.resolved) {
                .enumeration => |reference| self.analyzer.enums.items[reference.index].findMember(parts[0]) != null,
                .variant => |index| self.analyzer.variants.items[index].findMember(parts[0]) != null,
                else => false,
            };
        }
        return false;
    }

    // Landing ---------------------------------------------------------------
    //
    // Getting a checked value into the place that expects it. Concrete
    // numeric values never convert here; literals have already landed at
    // their contextual type. Optional wrapping and nominal interface
    // conversion are the two representation changes this boundary may add.
    // What is said when the answer is no lives in `refusals.zig`.

    /// Make an already-lowered value fit `expected`. Exact values pass
    /// unchanged, a conforming nominal type can become an interface existential,
    /// and a present `T` can become `T?`. Null means it does not fit and the
    /// caller reports. Numeric representation changes are never implicit.
    pub fn fit(self: *FunctionBuilder, value: Typed, expected: Type) Error!?Typed {
        if (value.value_type.eql(expected)) return value;
        if (value.value_type.widensTo(expected)) return try self.widenNumeric(value, expected);
        // A concrete struct or class may be passed to a nominal interface only
        // after it explicitly promised that interface.  The conversion
        // records one bound method per contract slot; lower reuses the
        // ordinary function-value ABI for those slots.
        if (expected == .strukt) {
            if (self.analyzer.interfaceForLayout(expected.strukt)) |interface_index| {
                const concrete_layout = self.analyzer.nominalLayout(value.value_type) orelse return null;
                if (self.analyzer.conformance(concrete_layout, interface_index)) |conformance| {
                    const contract = self.analyzer.interface_decls.items[interface_index];
                    const methods = try self.arena().alloc(nodes.Expression.InterfaceMethod, contract.methods.len);
                    for (conformance.methods, contract.methods, methods) |function, method, *slot| {
                        slot.* = .{
                            .function = function,
                            .signature = method.signature,
                            // The interface call carries the contract's
                            // failure obligation; the witness entry carries
                            // the concrete target's actual effect.  A
                            // non-fallible implementation may satisfy a
                            // fallible requirement, just as Swift's
                            // throwing protocol witness rules do.
                            .fallible = self.analyzer.functions.items[function].fallible,
                        };
                    }
                    const converted = Typed{
                        .node = try recorder.recordNode(self, .{ .interface_make = .{
                            .layout = expected.strukt,
                            .receiver = value.node,
                            .methods = methods,
                            .result = expected,
                            .span = value.node.span(),
                        } }),
                        .value_type = expected,
                    };
                    // The conversion allocates an interface value even
                    // when it appears only as a call argument.  Keep it in
                    // the statement ledger until the call either adopts it
                    // or the statement unwinds; without this park the hidden
                    // function slots (and their owned receiver copies) leak.
                    try ledger.parkFreshValue(self, converted, value.node.span());
                    return converted;
                }
            }
        }
        const payload = expected.held() orelse return null;
        const inner = (try self.fit(value, payload)) orelse return null;
        // The `T <: T?` inclusion is a node of its own (`wrap_optional`),
        // recorded here so every assignment-like boundary agrees.
        return .{
            .node = try recorder.recordNode(self, .{ .wrap_optional = .{
                .operand = inner.node,
                .result = expected,
                .span = inner.node.span(),
            } }),
            .value_type = expected,
        };
    }

    /// Record an implicit numeric conversion admitted by `Type.widensTo`.
    /// The explicit-width contract currently admits none; keeping this
    /// assertion at old call sites makes any accidental reintroduction fail
    /// loudly until those sites are removed.
    pub fn widenNumeric(self: *FunctionBuilder, value: Typed, to: Type) Error!Typed {
        std.debug.assert(value.value_type.widensTo(to));
        return self.convertNumeric(value, to);
    }

    /// Record a numeric conversion required by a language construct rather
    /// than by implicit assignment. Integer `/` uses this to produce its
    /// specified f64 result; source-level conversions use the same node.
    pub fn convertNumeric(self: *FunctionBuilder, value: Typed, to: Type) Error!Typed {
        std.debug.assert(value.value_type.isNumeric() and to.isNumeric());
        // A conversion is a node of its own, so the tree records the exact
        // source boundary that changes representation.
        return .{
            .node = try recorder.recordNode(self, .{ .convert = .{
                .operand = value.node,
                .result = to,
                .span = value.node.span(),
            } }),
            .value_type = to,
        };
    }

    /// Check whether an already-lowered value is exactly `want`. The helper
    /// retains its historical name until its call sites are collapsed; under
    /// the explicit-width contract `Type.widensTo` is always false.
    pub fn widensInto(self: *FunctionBuilder, held: *Typed, want: Type) Error!bool {
        if (held.value_type.eql(want)) return true;
        if (!held.value_type.widensTo(want)) return false;
        held.* = try self.widenNumeric(held.*, want);
        return true;
    }

    /// The container place a literal can take its shape from.  Bracket
    /// literals accept lists and rank-1 arrays; map literals accept
    /// maps.  The particular literal checks the descriptor after this
    /// one-hop signal reaches it.
    fn containerPlace(self: *FunctionBuilder, expected: Type) ?Type {
        const descriptor = self.analyzer.heapOf(expected) orelse return null;
        return switch (descriptor) {
            .list, .map => expected,
            .array => |shape| if (shape.rank == 1) expected else null,
            .class, .builder, .file, .task => null,
        };
    }

    /// Raise every landing signal the place `expected` names, for the
    /// one expression about to be lowered into it: the scalar width a
    /// literal takes, the element type a list literal is built at, and
    /// the signature a bare function name or a lambda lands on.
    ///
    /// One call rather than three assignments, because they are one
    /// act: *this is the place, tell the literal about it*.  A place
    /// that names none of the three raises none, and inference where
    /// nothing is expected stays untouched.
    pub fn wantPlace(self: *FunctionBuilder, expected: Type) void {
        self.wanted = context.literalLandingType(expected);
        self.wanted_container = self.containerPlace(expected);
        self.wanted_function = switch (expected) {
            .function => |index| index,
            // **A place that may hold none is still a place.**  The
            // storable form of a function value is `(func(...) -> R)?`
            // (docs/BINDING.md D7), so a struct field, a container
            // element and a slot declared before it is filled are all
            // optional places — and a bare function name, a lambda and
            // a bind land on the signature *inside* one exactly as they
            // land on a bare `func` place.  `fit` then wraps the value
            // it made, which is the same two steps `let x: f64? = 1`
            // takes; `literalLandingType` looks through the same layer
            // one line above, for the same reason.
            .optional => |payload| switch (payload) {
                .function => |index| index,
                else => null,
            },
            else => null,
        };
    }

    /// A number at the type an operator computes it at. Every explicit-width
    /// numeric type computes as itself, so this is now an identity helper
    /// retained while old call sites are simplified.
    pub fn promoted(self: *FunctionBuilder, value: Typed) Error!Typed {
        _ = self;
        return value;
    }

    /// Check the single concrete numeric type two operands share. With no
    /// implicit numeric conversion, this never moves either operand.
    pub fn unifyNumeric(self: *FunctionBuilder, left: *Typed, right: *Typed) Error!bool {
        const meeting = Type.unified(left.value_type, right.value_type) orelse return false;
        var moved = false;
        if (!left.value_type.eql(meeting)) {
            left.* = try self.widenNumeric(left.*, meeting);
            moved = true;
        }
        if (!right.value_type.eql(meeting)) {
            right.* = try self.widenNumeric(right.*, meeting);
            moved = true;
        }
        return moved;
    }

    /// Lower an expression into a place whose type is already known —
    /// which is what gives `none` a type, since it has none of its
    /// own.  Reports and returns null on a mismatch; `subject` names
    /// the place for the message.
    pub fn lowerTyped(
        self: *FunctionBuilder,
        expression: *ast.Expression,
        expected: Type,
        span: Span,
        subject: []const u8,
    ) Error!?Fitted {
        if (expression.* == .none_literal) {
            if (expected != .optional) {
                // No article in front of a type name: "a long" reads as
                // an adjective, and "a long is always there" says nothing
                // besides.  The variants below sidestep it the same
                // way, and this is the wording they are standardised
                // on.
                try self.fail("luce.sema.absent", expression.span(), "{s} is {s}, which is always there; only {s}? is ever none", .{
                    subject,
                    try self.analyzer.typeName(expected),
                    try self.analyzer.typeName(expected),
                });
                return null;
            }
            const absent: Typed = .{
                .node = try recorder.recordNode(self, .{ .absent = .{
                    .result = expected,
                    .span = expression.span(),
                } }),
                .value_type = expected,
            };
            return .{ .value = absent, .present = false };
        }
        self.wantPlace(expected);
        const value = (try self.lowerExpression(expression, false)) orelse return null;
        const fitted = (try self.fit(value, expected)) orelse {
            try self.fail("luce.sema.type", span, "{s} is {s} but the value is {s}{s}", .{
                subject,
                try self.analyzer.typeName(expected),
                try self.analyzer.typeName(value.value_type),
                try refusals.mismatchAdvice(self, expected, value.value_type, expression),
            });
            return null;
        };
        return .{ .value = fitted, .present = !value.value_type.eql(expected) };
    }

    /// A **named function as a value**, where a function type is what
    /// the place expects (docs/FUNCTIONS.md S1).
    ///
    /// `written` is what the reader wrote — a bare name, or one dotted
    /// level for `Struct.helper` and `module.helper` — and `signature`
    /// is the shape the place demands.  Everything a call site checks
    /// about a declaration is checked here too, because this *is* the
    /// call site's check moved earlier: visibility, the entry, the
    /// method rule, and now the shape.
    fn functionValue(
        self: *FunctionBuilder,
        written: []const u8,
        span: Span,
        signature: u32,
    ) Error!?Typed {
        const resolved = (try self.resolveDeclared(written, span, .written)) orelse return null;
        const index = self.analyzer.function_names.get(resolved) orelse {
            try refusals.failUnknownFunction(self, written, span);
            return null;
        };
        if (!try refusals.functionReachable(self, index, span)) return null;
        const info = self.analyzer.functions.items[index];
        if (info.is_entry) {
            try self.fail("luce.sema.call", span, "entry function {s} cannot be called", .{written});
            return null;
        }
        // **A method is not a value** (docs/FUNCTIONS.md D1).  A
        // reference to one is a closure over its receiver, which is the
        // far side of the capture line — so the refusal shows the
        // honest form, which re-receives the receiver as a parameter
        // and therefore carries nothing.
        if (info.receiver != .not) {
            if (info.receiver == .writes) {
                try self.fail(
                    "luce.sema.call",
                    span,
                    "{s} writes its implicit self and is not a function value; " ++
                        "move the operation into a top-level or static function that receives and returns the value",
                    .{written},
                );
            } else {
                if (info.declaration.parameters.len == 0) {
                    try self.fail(
                        "luce.sema.call",
                        span,
                        "{s} is a method, and a method reference would carry its receiver; " ++
                            "write a lambda that takes the receiver — (x) -> x.{s}()",
                        .{ written, info.declaration.name },
                    );
                } else {
                    try self.fail(
                        "luce.sema.call",
                        span,
                        "{s} is a method, and a method reference would carry its receiver; " ++
                            "write a lambda whose first parameter receives the value and whose remaining parameters forward the method arguments",
                        .{written},
                    );
                }
            }
            return null;
        }
        // A fallible function's `!` is an obligation its call sites
        // carry, and a function type has nowhere to write one, so
        // letting one become a value would drop the obligation in
        // silence (docs/FUNCTIONS.md, As built).
        if (info.fallible) {
            try self.fail(
                "luce.sema.fallible",
                span,
                "{s} can fail, and a function type carries no '!'; a fallible function is not a value yet [FUNCTIONS.md]",
                .{written},
            );
            return null;
        }
        const wants = self.analyzer.signatures.items[signature];
        if (!self.matchesSignature(info, wants, 0)) {
            try self.fail(
                "luce.sema.type",
                span,
                "this place is {s}, and {s} is {s}",
                .{
                    try self.analyzer.typeName(.{ .function = signature }),
                    written,
                    try self.writtenSignature(info),
                },
            );
            return null;
        }
        const value: Type = .{ .function = signature };
        return .{
            .node = try recorder.recordNode(self, .{ .function_value = .{
                .function = index,
                .result = value,
                .span = span,
            } }),
            .value_type = value,
        };
    }

    /// **`Msg.query_changed` where a function type lands** — a union
    /// member constructor as a function value (docs/BINDING.md D11).
    ///
    /// The member's payload fields are the parameters, in declaration
    /// order, and the union is the result: `query_changed(query:
    /// string)` is a `func(string) -> Msg`.  A field that carries
    /// objects takes `give`, because that is the verb its construction
    /// takes (S24) and calling through a value checks argument verbs
    /// exactly as a direct call does (FUNCTIONS D5).
    ///
    /// **A payload-less member stays a value, not a function**, so it
    /// is answered here as the value it is and the landing place says
    /// what it wanted — one decision, said once.
    ///
    /// Nothing downstream learns a constructor exists: the analyzer
    /// synthesizes the top-level function `Msg.query_changed` whose
    /// body is the construction the reader would have written, and
    /// emits the `const_function` a named function emits.  That is the
    /// lambda's own route (FUNCTIONS D2), one node kind over.
    fn memberConstructor(
        self: *FunctionBuilder,
        field: ast.FieldAccess,
        written: []const u8,
        signature: u32,
    ) Error!expressions.MemberAccess {
        const qualified = (try self.resolveDeclared(written, field.span, .written)) orelse
            return .reported;
        const found = construct.variantMemberOfQualified(self, qualified) orelse
            return .not_a_member;
        const declared = self.analyzer.variants.items[found.variant];
        const member = declared.members[found.member];
        if (member.fields.len == 0) {
            const value = (try expressions.lowerField(self, field)) orelse return .reported;
            return .{ .value = value };
        }

        // The constructor's own shape, and the comparison the place
        // deserves before a function is synthesized for it.
        const result: Type = .{ .variant = found.variant };
        const parameters = try self.arena().alloc(types.Signature.Parameter, member.fields.len);
        for (member.fields, parameters) |payload, *parameter| {
            parameter.* = .{ .value_type = payload.field_type };
        }
        const made: types.Signature = .{ .parameters = parameters, .result = result };
        const wants = self.analyzer.signatures.items[signature];
        if (!made.eql(wants)) {
            const spelled = try resolve.internSignature(self.analyzer, made);
            try self.fail("luce.sema.type", field.span, "this place is {s}, and {s} is {s}", .{
                try self.analyzer.typeName(.{ .function = signature }),
                written,
                try self.analyzer.typeName(spelled),
            });
            return .reported;
        }

        // The synthesized declaration: `func Msg.query_changed(query:
        // string) -> Msg: return Msg.query_changed(query = query)`.
        // The body reuses the written head, so an imported union
        // resolves from the reference site's own module exactly as it
        // did where the reader wrote it, and the arguments are named
        // because a member construction takes nothing else (UNION D4).
        const declaration = try self.arena().create(ast.FuncDecl);
        const written_parameters = try self.arena().alloc(ast.Parameter, member.fields.len);
        const arguments = try self.arena().alloc(ast.Argument, member.fields.len);
        for (member.fields, written_parameters, arguments) |payload, *slot, *argument| {
            slot.* = .{
                .name = payload.name,
                .name_span = field.span,
                .type_name = .{ .name = "func", .span = field.span },
                .span = field.span,
            };
            const read = try self.arena().create(ast.Expression);
            read.* = .{ .name = .{ .text = payload.name, .span = field.span } };
            argument.* = .{ .name = payload.name, .value = read, .span = field.span };
        }
        const construction = try self.arena().create(ast.Expression);
        construction.* = .{ .method = .{
            .target = field.target,
            .name = field.name,
            .arguments = arguments,
            .span = field.span,
        } };
        const values = try self.arena().alloc(*ast.Expression, 1);
        values[0] = construction;
        const body = try self.arena().alloc(ast.Statement, 1);
        body[0] = .{ .return_statement = .{ .values = values, .span = field.span } };
        const returns = try self.arena().alloc(ast.TypeName, 1);
        returns[0] = .{ .name = "func", .span = field.span };
        declaration.* = .{
            .name = written,
            .name_span = field.span,
            .parameters = written_parameters,
            .returns = returns,
            .body = .{ .statements = body, .span = field.span },
            .span = field.span,
        };
        const index = try signatures.registerLambda(
            self.analyzer,
            declaration,
            self.module,
            made,
            &.{},
        );
        const value: Type = .{ .function = signature };
        return .{ .value = .{
            .node = try recorder.recordNode(self, .{ .function_value = .{
                .function = index,
                .result = value,
                .span = field.span,
            } }),
            .value_type = value,
        } };
    }

    /// **`receiver.method` where a function type lands** — a bound
    /// method: a function value whose environment is the receiver
    /// (docs/BINDING.md D1, D2).
    ///
    /// There is no marker.  What makes this a bind is the place it
    /// lands in, exactly as a bare function name becomes a value by
    /// landing (FUNCTIONS.md D2); the value's type is the method's
    /// signature with the receiver's parameter dropped, and the
    /// receiver travels inside the value.
    ///
    /// Answers `.not_a_member` when the receiver's type has no method
    /// of this name, so `p.x` still reads as the field it is, and
    /// `.reported` once a diagnostic has been spoken — a bind that was
    /// refused must not be re-read as a field, which is how one mistake
    /// became two messages.  Every refusal a bind has of its own is
    /// spoken here.
    fn boundMethod(
        self: *FunctionBuilder,
        field: ast.FieldAccess,
        signature: u32,
    ) Error!expressions.MemberAccess {
        const receiver = (try self.lowerExpression(field.target, false)) orelse return .reported;
        const index = (try calls.structMethod(self, receiver.value_type, field.name)) orelse
            return .not_a_member;
        if (!try refusals.functionReachable(self, index, field.span)) return .reported;
        const info = self.analyzer.functions.items[index];
        const declared = calls.declaredName(self, receiver.value_type).?;

        // **A writing method does not bind in this run**
        // (docs/BINDING.md D9).  A writer needs one bare owning `var`
        // receiver aliased in place (SELF.md D3); a bound writer is an
        // inout closure whose store-back discipline is its own design.
        if (info.receiver == .writes) {
            try self.fail(
                "luce.sema.call",
                field.span,
                "{s}.{s} writes its receiver, and a writing method is not a function value; " ++
                    "bind a reading method, or call this one on the binding that owns it",
                .{ declared, field.name },
            );
            return .reported;
        }
        // A fallible method's `!` is an obligation its call sites
        // carry, and a function type still has nowhere to write one
        // (docs/BINDING.md D8, not built).
        if (info.fallible) {
            try self.fail(
                "luce.sema.fallible",
                field.span,
                "{s}.{s} can fail, and a function type carries no '!'; " ++
                    "a fallible method is not a value yet",
                .{ declared, field.name },
            );
            return .reported;
        }
        const wants = self.analyzer.signatures.items[signature];
        if (!self.matchesSignature(info, wants, 1)) {
            try self.fail("luce.sema.type", field.span, "this place is {s}, and {s}.{s} bound is {s}", .{
                try self.analyzer.typeName(.{ .function = signature }),
                declared,
                field.name,
                try self.boundSignature(info),
            });
            return .reported;
        }
        const value: Type = .{ .function = signature };
        return .{ .value = .{
            .node = try recorder.recordNode(self, .{ .bound_method = .{
                .function = index,
                .receiver = receiver.node,
                .result = value,
                .span = field.span,
            } }),
            .value_type = value,
        } };
    }

    /// The function type a bind of this method would wear: the
    /// declaration's shape with the receiver's parameter dropped, which
    /// is what a reader has to compare the place against.
    fn boundSignature(self: *FunctionBuilder, info: context.FunctionDeclInfo) Error![]const u8 {
        if (info.results.len >= 2) {
            return std.fmt.allocPrint(self.arena(), "a method answering {d} values", .{info.results.len});
        }
        const written = info.parameter_types[1..];
        const parameters = try self.arena().alloc(types.Signature.Parameter, written.len);
        for (written, parameters) |held, *parameter| {
            parameter.* = .{ .value_type = held };
        }
        const shape = try resolve.internSignature(self.analyzer, .{
            .parameters = parameters,
            .result = info.return_type,
        });
        return self.analyzer.typeName(shape);
    }

    /// Whether a declared function really has the shape a function type
    /// demands: the same parameter types in the same order and the same
    /// answer.
    ///
    /// **No widening anywhere.**  A `func(long)` place does not accept a
    /// `func(double)` even though a `long` reaches a `double` on its
    /// own: the widening happens at the *argument*, and a value that
    /// stands in for the function has no argument yet to widen.  This is
    /// the same reason a `list(int)` does not fit a `list(long)`.
    fn matchesSignature(
        self: *FunctionBuilder,
        info: context.FunctionDeclInfo,
        wants: types.Signature,
        /// The first collected parameter the written type covers: zero
        /// for a plain function value, one for a bind — whose receiver
        /// the value carries instead of taking (docs/BINDING.md D1).
        first: usize,
    ) bool {
        _ = self;
        if (info.results.len >= 2) return false;
        if (info.parameter_types.len != wants.parameters.len + first) return false;
        if (!info.return_type.eql(wants.result)) return false;
        for (
            info.parameter_types[first..],
            wants.parameters,
        ) |held, parameter| {
            if (!held.eql(parameter.value_type)) return false;
        }
        return true;
    }

    /// A declared function's shape, written as a function type — what a
    /// mismatch puts on the other side of the sentence.
    fn writtenSignature(
        self: *FunctionBuilder,
        info: context.FunctionDeclInfo,
    ) Error![]const u8 {
        const parameters = try self.arena().alloc(types.Signature.Parameter, info.parameter_types.len);
        for (info.parameter_types, parameters) |held, *parameter| {
            parameter.* = .{ .value_type = held };
        }
        const shape = try resolve.internSignature(self.analyzer, .{
            .parameters = parameters,
            .result = if (info.results.len >= 2) .none else info.return_type,
        });
        if (info.results.len >= 2) {
            return std.fmt.allocPrint(self.arena(), "a function answering {d} values", .{info.results.len});
        }
        return self.analyzer.typeName(shape);
    }

    fn lowerOperands(self: *FunctionBuilder, operands: []const *ast.Expression) Error!?[]Typed {
        return self.lowerOperandsInto(operands, .nothing);
    }

    /// What the operands of one batch land on — asked per operand, in
    /// order, because not every batch knows the answer up front.
    ///
    /// A call's parameters are written down in front of it, so
    /// `places` has the whole list before anything is lowered.  A
    /// **method's** are not: `xs.append(0.1)` takes its parameter type
    /// from `xs`, which is operand zero of this very batch — and the
    /// same is true of `xs[i] = 0.1`, whose element type is operand
    /// zero's.  Both are answered here, after operand zero has been
    /// lowered and before the argument is, which is the only order in
    /// which `0.1` can be parsed at the width it lands on
    /// (docs/TYPES.md §1).  Widening it afterwards is a different
    /// number.
    ///
    /// Splitting the batch in two would have answered it as well, and
    /// would have given up the cross-operand analysis that copies a
    /// borrowed string before a later operand can free it
    /// (docs/STRINGS.md).  One batch, asked as it goes.
    /// The type operand `index` of a batch lands on, given the
    /// operands already lowered into `values`, or null when nothing
    /// names one.  Operand zero never lands on anything: it is either
    /// an ordinary operand or the receiver the others ask about.
    fn landsOn(
        self: *FunctionBuilder,
        landing: Landing,
        values: []const Typed,
        index: usize,
        count: usize,
    ) Error!Place {
        switch (landing) {
            .nothing => return .unknown,
            .places => |places| return .{ .lands = places[index] },
            .maybe_places => |places| return maybePlace(places[index]),
            .method => |method| {
                if (index == 0) return .unknown;
                const receiver = values[0].value_type;
                // A struct receiver's parameters come from the
                // declaration, and which slot this argument fills is
                // what decides its landing — names may reorder
                // (docs/ARGS.md D5), so the slot is answered silently
                // by the same rule the checker applies after the
                // batch, through the one `argumentSlot`.
                if (calls.declaredName(self, receiver) != null and
                    !(receiver == .strukt and self.analyzer.interfaceForLayout(receiver.strukt) != null))
                {
                    const function_index = (try calls.structMethod(self, receiver, method.name)) orelse {
                        // No declaration of that name at all: what the
                        // receiver has is the answer, and it has to
                        // come before an argument is refused for
                        // wanting a place that will never exist.  A
                        // name that *is* declared and is not a method
                        // — a static function — is the dispatch's
                        // sentence, one step further on.
                        if (try calls.failAbsentReceiverMethod(self, receiver, method)) return .refused;
                        return .unknown;
                    };
                    const info = self.analyzer.functions.items[function_index];
                    const hidden: usize = if (info.receiver == .not) 0 else 1;
                    if (info.declaration.parameters.len + hidden != info.parameter_types.len) return .unknown;
                    const surface = try calls.declarationSlots(self, info);
                    const slot = calls.argumentSlot(surface, 1, method.arguments, index - 1) orelse
                        return .unknown;
                    return .{ .lands = info.parameter_types[slot] };
                }
                const wanted = (try calls.methodParameters(self, receiver, method.name)) orelse {
                    // The same question for a container: a name no
                    // builtin table has is either a method the
                    // receiver does not have — said here — or a call
                    // that routes into the standard library, whose
                    // own declaration lands its arguments.
                    if (try calls.failAbsentMethod(self, receiver, method)) return .refused;
                    return .unknown;
                };
                const slot = index - 1;
                if (slot >= wanted.len) {
                    // More arguments than the method takes.  The count
                    // is knowable here, and saying it now is what
                    // keeps a bare function name in the extra one from
                    // answering for the call.  A *named* argument is
                    // refused ahead of the count (D10), so leave one
                    // to the dispatch.
                    if (calls.namesAnyArgument(method.arguments)) return .unknown;
                    try calls.failMethodArity(self, method, wanted.len);
                    return .refused;
                }
                // A builtin method's arguments are positional (D10),
                // so a named one is refused after the batch.  A bare
                // function or lambda still needs its positional type
                // while being lowered, however; without that landing
                // its "needs a function place" error would hide the
                // more fundamental named-argument refusal.
                if (method.arguments[slot].name != null and wanted[slot] != .function) return .unknown;
                return .{ .lands = wanted[slot] };
            },
            .stored_element => {
                if (index == 0) return .unknown;
                // The subscripts land where subscripts land; the value
                // at the end lands on the element type, which the
                // container named.
                if (index + 1 < count) return maybePlace(self.subscriptType(values[0].value_type));
                const descriptor = self.analyzer.heapOf(values[0].value_type) orelse return .unknown;
                return maybePlace(switch (descriptor) {
                    .list => |element| element,
                    .array => |shape| shape.element,
                    .map => |pair| pair.value,
                    .class, .builder, .file, .task => null,
                });
            },
            .subscripts => {
                if (index == 0) return .unknown;
                return maybePlace(self.subscriptType(values[0].value_type));
            },
            .chain => |path| return maybePlace(self.chainPlace(path, index, count)),
        }
    }

    /// A landing that may or may not be there, as the `Place` the
    /// batch reads: the two shapes say the same thing, and this is
    /// where the older one becomes the newer.
    fn maybePlace(place: ?Type) Place {
        return if (place) |landed| .{ .lands = landed } else .unknown;
    }

    /// Where operand `index` of a nested store lands: a subscript
    /// takes the position its container is addressed by, and the
    /// value at the end takes the leaf the written path reaches.
    ///
    /// **Silent, like every other answer here.**  A step this walk
    /// cannot follow — a field of something that is not a struct, a
    /// name no layout has, an index of something that is not a
    /// container — answers null and leaves every word of the report
    /// to the descent that checks the same path afterwards
    /// (`assign.lowerAssignChain`), which is the division a method's
    /// landing already keeps.
    fn chainPlace(self: *FunctionBuilder, path: ChainLanding, index: usize, count: usize) ?Type {
        var reached = path.root;
        var subscripts_seen: usize = 0;
        for (path.steps) |node| {
            switch (node.*) {
                .field => |field| {
                    const layout_index = self.analyzer.nominalLayout(reached) orelse return null;
                    const layout = self.analyzer.structs.items[layout_index];
                    const field_index = layout.findField(field.name) orelse return null;
                    reached = layout.fields[field_index].field_type;
                },
                .index => |subscripted| {
                    const past = subscripts_seen + subscripted.indices.len;
                    if (index >= subscripts_seen and index < past) return self.subscriptType(reached);
                    subscripts_seen = past;
                    const descriptor = self.analyzer.heapOf(reached) orelse return null;
                    reached = switch (descriptor) {
                        .list => |element| element,
                        .array => |shape| shape.element,
                        .map => |pair| pair.value,
                        .class, .builder, .file, .task => return null,
                    };
                },
                else => return null, // only field and index steps are collected
            }
        }
        // Every subscript answered above; what is left is the value.
        return if (index + 1 == count) reached else null;
    }

    /// What a subscript of `container` lands on: a map takes its key
    /// type, and everything a position can address — a list, an array,
    /// a string being sliced — takes a `long`.
    fn subscriptType(self: *FunctionBuilder, container: Type) ?Type {
        if (container == .str or container == .bytes) return .i64;
        const descriptor = self.analyzer.heapOf(container) orelse return null;
        return switch (descriptor) {
            .list, .array => .i64,
            .map => |pair| pair.key,
            .class, .builder, .file, .task => null,
        };
    }

    /// As `lowerOperands`, with the type each operand lands in already
    /// known — which is what lets a bare `none` be written among them,
    /// since it has no type of its own.
    fn lowerOperandsInto(
        self: *FunctionBuilder,
        operands: []const *ast.Expression,
        landing: Landing,
    ) Error!?[]Typed {
        const run = (try self.lowerOperandsIntoTracking(operands, landing)) orelse return null;
        return run.values;
    }

    /// The ordinary operand walk: lower each operand into the place it
    /// lands on and record the batch's per-operand defensive copies.
    pub fn lowerOperandsIntoTracking(
        self: *FunctionBuilder,
        operands: []const *ast.Expression,
        landing: Landing,
    ) Error!?OperandRun {
        const wide = operands.len > inline_operands;

        const values = try self.arena().alloc(Typed, operands.len);
        const copied = try self.arena().alloc(bool, operands.len);
        @memset(copied, false);

        // Which operands still have something that could mutate a
        // container running after them — the residual hazard below.
        var later_mutates: [inline_operands]bool = undefined;
        const mutating = if (wide)
            try self.temporary().alloc(bool, operands.len)
        else
            later_mutates[0..operands.len];
        defer if (wide) self.temporary().free(mutating);
        var any_mutation = false;
        var backwards = operands.len;
        while (backwards > 0) {
            backwards -= 1;
            mutating[backwards] = any_mutation;
            if (effects.mayMutateContainers(operands[backwards])) any_mutation = true;
        }

        for (operands, 0..) |expression, index| {
            // An argument and a returned value are both places with a
            // type written down, so a literal going into one lands
            // there (docs/TYPES.md D3, §1's *"an argument takes the
            // parameter's type"*) rather than taking the default and
            // widening afterwards.
            //
            // **Both hops, for the same reason.**  A `list(long)`
            // parameter is a written-down type exactly as a `long` one
            // is, and `[1, 2, 3]` has no element type until it lands —
            // so the literal reads its elements at the parameter's
            // width.  This is not covariance and does not become it: a
            // *named* `list(int)` is still refused there, because it
            // already has a type and D6 says no list converts to
            // another.
            const place: ?Type = switch (try self.landsOn(landing, values, index, operands.len)) {
                .unknown => null,
                .lands => |landed| landed,
                // The batch's own answer was that it has none, and it
                // has been said: a second sentence about this operand
                // would only bury it.
                .refused => return null,
            };
            if (place) |landed| self.wantPlace(landed);
            // A bare `none` has no type of its own; the place it lands
            // on supplies one, whichever way the batch knows the place
            // — written down up front (`.places`) or answered by the
            // receiver (`.method`), the same answer either way.
            const value = lifecycle_value: {
                const previous_permission = self.allow_deinitializer_self;
                defer self.allow_deinitializer_self = previous_permission;
                if (self.is_deinitializer and index == 0 and isBareSelf(expression)) {
                    switch (landing) {
                        .method => self.allow_deinitializer_self = true,
                        else => {},
                    }
                }
                break :lifecycle_value if (expression.* == .none_literal and place != null)
                    ((try self.lowerTyped(expression, place.?, expression.span(), "this place")) orelse
                        return null).value
                else
                    (try self.lowerExpression(expression, false)) orelse return null;
            };
            values[index] = value;
            // The residual hazard copy-on-store leaves open
            // (docs/STRINGS.md): this value may be a *borrow* of an
            // element's or a field's bytes, and an operand still to
            // come could free them — `f(pieces[0], drop_first(pieces))`
            // is the shape.  An object would go stale and trap (S9); a
            // string has no handle to check, so it closes here, by
            // deciding the copy before the mutation can happen.
            // An interface receiver is already a dispatch value whose
            // hidden function runs own the concrete receiver.  A concrete
            // value *landing on* an interface is protected for the same
            // reason: `fit` binds an owned receiver before a later operand
            // runs.  Copying the pre-fit value here would attach a batch
            // rewrite to a post-fit interface node, copying the dispatch
            // run while parking the concrete receiver — two different
            // values and, before the local-order fix, a double free.
            // Neither is the borrowed-storage hazard this rule protects.
            const interface_receiver = value.value_type == .strukt and
                self.analyzer.interfaceForLayout(value.value_type.strukt) != null;
            const interface_landing = place != null and place.? == .strukt and
                self.analyzer.interfaceForLayout(place.?.strukt) != null;
            if (mutating[index] and
                !interface_receiver and
                !interface_landing and
                shapes.ownsStorage(self.analyzer, value.value_type) and
                value.provenance() == .view)
            {
                // The copy is storage this statement allocated and
                // nobody owns yet, whatever the borrow it closed was;
                // the operand's node stays the written expression
                // (nodes.OperandBatch's pre-copy convention), and the
                // recorded flag is what makes lower emit the copy.
                values[index].rewritten = .fresh;
                copied[index] = true;
                try ledger.parkFreshStorage(self, values[index], expression.span());
            }
        }
        // An operand a later one branches past does not survive in a
        // register (hir.zig, coupling #4): lower carries it across
        // the split in a slot, and the reload is a *view* of that
        // slot's storage, so a fresh operand loses its freshness and
        // the store that receives it copies.  The question is asked of
        // the recorded nodes, where it has an exact answer, and lower
        // asks the same one of the same nodes — the decision is not
        // recorded because it is derivable.
        var any_split = false;
        backwards = operands.len;
        while (backwards > 0) {
            backwards -= 1;
            if (any_split and values[backwards].value_type != .none) {
                values[backwards].rewritten = .view;
            }
            if (nodes.splitsBlocks(values[backwards].node, self.declarations())) any_split = true;
        }
        return .{ .values = values, .copied = copied };
    }

    // Expressions: the dispatch --------------------------------------------
    //
    // The depth bound and the two-level switch every expression form
    // is reached through.  The forms themselves are `expressions.zig`;
    // what sits between here and them is the fallible-call machinery a
    // `try` or a `catch` is built out of.

    pub fn lowerExpression(self: *FunctionBuilder, expression: *ast.Expression, as_statement: bool) Error!?Typed {
        // Stage 3 bounds recursive *descent*, which a left-leaning
        // chain never exercises: `1 + 1 + ... + 1` parses in a Pratt
        // loop and hands back a tree as deep as the chain is long, and
        // an f-string desugars to exactly such a chain.  This walk is
        // recursive, so it needs a bound of its own.
        if (self.depth >= helpers.max_expression_depth) {
            try self.fail(
                "luce.sema.nesting",
                expression.span(),
                "expression nested too deeply (limit {d})",
                .{helpers.max_expression_depth},
            );
            return null;
        }
        self.depth += 1;
        defer self.depth -= 1;

        const value = (try self.lowerExpressionInner(expression, as_statement)) orelse return null;
        if (value.value_type == .none) return value;
        // A freshly made value is parked as a statement temporary so the
        // statement's end reclaims what nothing adopts (docs/STRINGS.md,
        // docs/MEMORY.md): its freshly allocated storage — a string `+`, a
        // built struct run, a call's fresh result — and the reference
        // object it names — a `new` container, a fresh `Json.array`.  A
        // borrow (a slice, a reload, a field read) allocates and owns
        // nothing, so it parks nothing.
        const parkable = !ledger.parkedAlready(self, value.node);
        const storage = parkable and value.provenance() == .fresh and
            shapes.ownsStorage(self.analyzer, value.value_type);
        const objects = parkable and nodes.freshObject(value.node) and
            shapes.carriesObjects(self.analyzer, value.value_type);
        if (storage or objects) try ledger.registerTemp(self, value, storage, objects, expression.span());
        return value;
    }

    /// Materialise an integer literal at the type it lands on
    /// (docs/TYPES.md D3).  `negated` folds the minus in first, so
    /// `long`'s minimum stays writable; `wanted` is the landing type
    /// the context asked for, and null means there is no context and
    /// the literal takes the default, which is `i64`.
    ///
    /// **The text is read at the width it lands on**, never at the
    /// widest and then narrowed: a float landing reads the *digits*
    /// rather than `parseIntLiteral`'s result, so an integer literal
    /// past `long`'s range still lands correctly on a float that has
    /// room for it, and the one rule keeps its one spelling.
    pub fn lowerIntLiteral(
        self: *FunctionBuilder,
        literal: ast.Literal,
        span: Span,
        negated: bool,
        wanted: ?Type,
    ) Error!?Typed {
        const lands: Type = wanted orelse .i64;
        if (lands.isFloating()) {
            const parsed = helpers.parseIntLiteralAsFloat(literal.text, negated, lands) orelse {
                try self.fail("luce.sema.literal", span, "{s}", .{context.rangeMessage(lands)});
                return null;
            };
            return .{
                .node = try recorder.recordNode(self, .{ .const_float = .{ .value = parsed, .result = lands, .span = span } }),
                .value_type = lands,
            };
        }
        const parsed = helpers.parseIntLiteral(literal.text, negated, lands) orelse {
            try self.fail("luce.sema.literal", span, "{s}", .{context.rangeMessage(lands)});
            return null;
        };
        return .{
            .node = try recorder.recordNode(self, .{ .const_integer = .{ .value = parsed, .result = lands, .span = span } }),
            .value_type = lands,
        };
    }

    fn lowerExpressionInner(self: *FunctionBuilder, expression: *ast.Expression, as_statement: bool) Error!?Typed {
        // The permission a `try` or `catch` raised reaches exactly the
        // expression it was written in front of.  Read and cleared
        // here, before anything nested can see it.
        const fallible_allowed = self.allow_fallible;
        self.allow_fallible = false;
        const shape_position = self.shape_position;
        self.shape_position = .refused;
        const wanted_container = self.wanted_container;
        self.wanted_container = null;
        const wanted = self.wanted;
        self.wanted = null;
        const wanted_function = self.wanted_function;
        self.wanted_function = null;
        switch (expression.*) {
            .int_literal => |literal| return self.lowerIntLiteral(literal, literal.span, false, wanted),
            .float_literal => |literal| {
                // A float literal lands on `f64` with no context.
                const lands: Type = if (wanted) |place|
                    (if (place.isFloating()) place else .f64)
                else
                    .f64;
                const parsed = helpers.parseFloatLiteral(literal.text, lands) orelse {
                    try self.fail("luce.sema.literal", literal.span, "{s}", .{context.rangeMessage(lands)});
                    return null;
                };
                return .{
                    .node = try recorder.recordNode(self, .{ .const_float = .{ .value = parsed, .result = lands, .span = literal.span } }),
                    .value_type = lands,
                };
            },
            .bool_literal => |literal| {
                return .{
                    .node = try recorder.recordNode(self, .{ .const_boolean = .{ .value = literal.value, .result = .boolean, .span = literal.span } }),
                    .value_type = .boolean,
                };
            },
            .char_literal => |literal| {
                return .{
                    .node = try recorder.recordNode(self, .{ .const_integer = .{ .value = literal.value, .result = .char, .span = literal.span } }),
                    .value_type = .char,
                };
            },
            .string_literal => |literal| {
                const constant = try self.analyzer.pool.intern(literal.decoded);
                return .{
                    .node = try recorder.recordNode(self, .{ .const_str = .{ .constant = constant, .result = .str, .span = literal.span } }),
                    .value_type = .str,
                };
            },
            .name => |name| {
                if (self.is_deinitializer and
                    std.mem.eql(u8, name.text, "self") and
                    !self.allow_deinitializer_self)
                {
                    try self.fail(
                        "luce.sema.class.lifecycle",
                        name.span,
                        "deinit may use self only to read or mutate its fields, call one of its methods, or store a weak reference; a new strong self reference would resurrect the class",
                        .{},
                    );
                    return null;
                }
                const found = self.findLocal(name.text) orelse {
                    // Not a local: perhaps a file-scope constant.
                    const qualified = try naming.qualify(self.analyzer, self.prefix, name.text);
                    if (self.analyzer.constant_names.get(qualified)) |constant| {
                        return expressions.emitConstant(self, constant, name.span);
                    }
                    // Or a function, where a function is what the place
                    // wants (docs/FUNCTIONS.md S1).  A local wins, and
                    // there is no local of this name.
                    if (wanted_function) |signature| {
                        return self.functionValue(name.text, name.span, signature);
                    }
                    try refusals.failUnknownName(self, name.text, name.span);
                    return null;
                };
                const local = found.info.local;
                const local_type = recorder.localType(self, local);
                if (try closures.readCapturedMutable(self, local, name.span)) |captured| {
                    return captured;
                }
                // A narrowed local reads as its payload: the value is
                // the same bits, and the flow analysis has already
                // proved it is there.
                if (!found.info.weak and local_type == .optional and flow.isNarrowed(self, local)) {
                    const payload = local_type.held().?;
                    return .{
                        .node = try recorder.recordNode(self, .{ .narrowed_get = .{
                            .local = local,
                            .payload = payload,
                            .result = payload,
                            .span = name.span,
                        } }),
                        .value_type = payload,
                    };
                }
                // A name reads as a view of what its slot holds; the
                // narrowed unwrap above answers neither fresh nor view.
                return .{
                    .node = try recorder.recordNode(self, .{ .local_get = .{
                        .local = local,
                        .weak = found.info.weak,
                        .result = local_type,
                        .span = name.span,
                    } }),
                    .value_type = local_type,
                };
            },
            // `none` has no type of its own; every place that can
            // accept it supplies one through `lowerTyped`, so reaching
            // here means nothing did.
            .none_literal => |literal| {
                try self.fail(
                    "luce.sema.absent",
                    literal.span,
                    "none needs a type here; write it into something declared T? (var x: i64? = none), or compare with a T? (x == none)",
                    .{},
                );
                return null;
            },
            .field => |field| {
                // A dotted head still obeys lexical shadowing.  In a
                // synthesized lambda the enclosing local is absent
                // from this top-level function's scope, so check it
                // before `math.pi` can be mistaken for an imported
                // namespace (FUNCTIONS.md S3).
                if (helpers.dottedChain(field.target)) |chain| {
                    if (try refusals.failCapturedName(self, chain.head(), field.span)) return null;
                }
                // `Struct.helper` and `module.helper` where a function
                // is wanted: the same head-names-a-declaration path a
                // call takes, one dot earlier (docs/FUNCTIONS.md S1).
                if (wanted_function) |signature| {
                    if (helpers.dottedChain(field.target)) |chain| {
                        if (chain.count == 1 and self.findLocal(chain.head()) == null) {
                            const written = try std.fmt.allocPrint(self.arena(), "{s}.{s}", .{
                                chain.head(),
                                field.name,
                            });
                            // `Msg.query_changed` — a union member
                            // constructor is a function value too
                            // (docs/BINDING.md D11), asked before the
                            // function table because the two cannot
                            // collide: a member and a function sharing
                            // a name is refused where the union is
                            // declared.
                            switch (try self.memberConstructor(field, written, signature)) {
                                .not_a_member => {},
                                .reported => return null,
                                .value => |made| return made,
                            }
                            return self.functionValue(written, field.span, signature);
                        }
                    }
                    // `receiver.method` — the method travels with the
                    // value it was written on (docs/BINDING.md D1).
                    //
                    // `.not_a_member` means the receiver's type has no
                    // method of this name, and the field path below
                    // says what it always said about `p.x`.  It lowers
                    // the receiver a second time to do so, which costs
                    // nothing that matters: no field is a function
                    // value, so every route through here ends in a
                    // diagnostic and the tape is never replayed.
                    switch (try self.boundMethod(field, signature)) {
                        .not_a_member => {},
                        .reported => return null,
                        .value => |bound| return bound,
                    }
                }
                return expressions.lowerField(self, field);
            },
            .call => |call| return calls.lowerCall(self, call, as_statement, fallible_allowed, shape_position, wanted),
            .value_call => |written| return calls.lowerValueCallExpression(self, written, as_statement),
            .binary => |binary| {
                if (binary.op == .catch_error) return self.lowerCatch(binary, as_statement);
                return expressions.lowerBinary(self, binary, wanted);
            },
            .unary => |unary| return expressions.lowerUnary(self, unary, wanted),
            .method => |method| return calls.lowerMethod(self, method, as_statement, fallible_allowed, shape_position),
            .new_object => |new| return expressions.lowerNew(self, new),
            .list_literal => |literal| return expressions.lowerListLiteral(self, literal, wanted_container),
            .map_literal => |literal| return expressions.lowerMapLiteral(self, literal, wanted_container),
            .index => |index| return expressions.lowerIndex(self, index),
            .slice_range => |slice| return expressions.lowerSliceRange(self, slice),
            .try_call => |attempt| return self.lowerTry(attempt, as_statement, shape_position),
            .spawn => |worker| return calls.lowerSpawn(self, worker, as_statement),
            .lambda => |written| return self.lowerLambda(expression, written, wanted_function),
            .closure => |written| return closures.lowerClosure(self, written, wanted_function),
        }
    }

    /// `(a, b) -> expr` — a lambda (docs/FUNCTIONS.md S3, D2).
    ///
    /// **It becomes a top-level function here, and is a function value
    /// from then on.**  Nothing downstream of this method knows a lambda
    /// existed: the analyzer synthesizes a declaration whose body is the
    /// one expression, registers it, and emits the `const_function` a
    /// written name would have emitted.  So both engines dispatch
    /// through the same table for both spellings, and every rule about
    /// function values — the verbs, the visibility, the comparison —
    /// holds for a lambda because it *is* the named case.
    ///
    /// The parameters take their types from the signature the lambda
    /// lands on, which is the whole of the literal rule: a lambda in a
    /// place that expects no function type has no types to take, and is
    /// refused saying so.
    fn lowerLambda(
        self: *FunctionBuilder,
        expression: *ast.Expression,
        written: ast.Lambda,
        wanted_function: ?u32,
    ) Error!?Typed {
        const index = wanted_function orelse {
            try self.fail(
                "luce.sema.type",
                written.span,
                "a lambda needs a place that expects a function: annotate the binding, or pass it where a func(...) parameter is declared",
                .{},
            );
            return null;
        };
        const signature = self.analyzer.signatures.items[index];
        if (written.parameters.len != signature.parameters.len) {
            try self.fail(
                "luce.sema.type",
                written.span,
                "this place is {s} and takes {d} parameter{s}; this lambda writes {d}",
                .{
                    try self.analyzer.typeName(.{ .function = index }),
                    signature.parameters.len,
                    if (signature.parameters.len == 1) "" else "s",
                    written.parameters.len,
                },
            );
            return null;
        }
        const enclosing = try self.visibleLocals();
        for (written.parameters) |parameter| {
            for (enclosing) |held| {
                if (!std.mem.eql(u8, parameter.text, held.name)) continue;
                try self.fail("luce.sema.duplicate", parameter.span, "{s} is already declared{s}", .{
                    parameter.text,
                    try naming.declaredAt(
                        self.analyzer,
                        self.analyzer.modules[self.module].file,
                        held.declared_at,
                    ),
                });
                return null;
            }
        }
        // The synthesized declaration.  Its parameters carry names and
        // no written types — the signature is where the types are, and
        // `registerLambda` hands them over resolved — and its body is
        // the one expression, as the statement that leaves with it.
        const parameters = try self.arena().alloc(ast.Parameter, written.parameters.len);
        for (written.parameters, parameters) |name, *slot| {
            slot.* = .{
                .name = name.text,
                .name_span = name.span,
                .type_name = .{ .name = "func", .span = name.span },
                .span = name.span,
            };
        }
        const body_statements = try self.arena().alloc(ast.Statement, 1);
        if (signature.result == .none) {
            body_statements[0] = .{ .expression = .{ .value = written.body, .span = written.body.span() } };
        } else {
            const values = try self.arena().alloc(*ast.Expression, 1);
            values[0] = written.body;
            body_statements[0] = .{ .return_statement = .{ .values = values, .span = written.body.span() } };
        }
        const returns = try self.arena().alloc(ast.TypeName, if (signature.result == .none) 0 else 1);
        if (returns.len == 1) returns[0] = .{ .name = "func", .span = written.span };
        const declaration = try self.arena().create(ast.FuncDecl);
        const at = self.analyzer.diagnostics.sources.place(
            self.analyzer.modules[self.module].file,
            written.span.start,
        );
        declaration.* = .{
            // Unforgeable from source, and readable in a trace: no
            // identifier holds a parenthesis.  The source place makes
            // sibling lambdas distinct too, so `string(f)` never gives
            // two unequal functions the same compiler name.
            .name = try std.fmt.allocPrint(
                self.arena(),
                "{s}.(lambda@{d}.{d})",
                .{ self.name, at.line, at.column },
            ),
            .name_span = written.span,
            .parameters = parameters,
            .returns = returns,
            .body = .{ .statements = body_statements, .span = written.span },
            .span = written.span,
        };
        const named = try signatures.registerLambda(
            self.analyzer,
            declaration,
            self.module,
            signature,
            enclosing,
        );
        _ = expression;
        const value: Type = .{ .function = index };
        return .{
            // A function value that remembers it was written in place
            // (nodes.LambdaRef); everything else about it is the
            // named case, synthesized declaration included.
            .node = try recorder.recordNode(self, .{ .lambda_ref = .{
                .function = named,
                .result = value,
                .span = written.span,
            } }),
            .value_type = value,
        };
    }

    /// Every local name a body can see right now, innermost scope
    /// first.  A synthesized lambda carries the names it was already
    /// forbidden to capture too: without that inherited tail, a lambda
    /// nested inside it could mistake a grandparent local for a module
    /// or top-level declaration.  Built only where a lambda is
    /// (`FunctionDeclInfo.enclosing_locals`).
    pub fn visibleLocals(self: *FunctionBuilder) Error![]const EnclosingLocal {
        var names: std.ArrayList(EnclosingLocal) = .empty;
        errdefer names.deinit(self.arena());
        var depth = self.scopes.items.len;
        while (depth > 0) {
            depth -= 1;
            var entries = self.scopes.items[depth].names.iterator();
            while (entries.next()) |entry| try names.append(self.arena(), .{
                .name = entry.key_ptr.*,
                .declared_at = entry.value_ptr.declared_at,
            });
        }
        if (self.enclosing_locals) |inherited| try names.appendSlice(self.arena(), inherited);
        return names.toOwnedSlice(self.arena());
    }

    // Errors ---------------------------------------------------------------
    //
    // A fallible call ends in three instructions: ask whether it came
    // back errored, carry its value across the branch, and take the
    // failing side to a block the `try` or `catch` in front of it
    // fills.  Everything below is about which of those two fills it.

    /// Close a fallible call: the call's answer crosses the branch on
    /// its outcome through a hidden owning slot (S3) — one place, not
    /// two, and a string's form survives the crossing because an
    /// owning slot holds a whole value (docs/STRINGS.md).  The checker
    /// allocates the slot's row, records the `carried_get` reload with
    /// its park, and leaves `opened` for the `try` or `catch` written
    /// in front; the question, the branch and the reload are lower's.
    ///
    /// `origin` is the call's own recorded node; the reload records as
    /// `carried_get` around it, which is where the try/catch family
    /// finds the branch-crossing link already in place.
    pub fn openFallible(
        self: *FunctionBuilder,
        result_type: Type,
        origin: nodes.NodeRef,
        span: Span,
    ) Error!Typed {
        const storage = shapes.ownsStorage(self.analyzer, result_type);
        const objects = shapes.carriesObjects(self.analyzer, result_type);

        // A callee answering nothing has no value to carry: the
        // "value" is the call itself, and so is its node.  The floor
        // is taken now either way — the failing side releases what the
        // statement owned *before* the call.
        if (result_type == .none) {
            self.opened = .{ .temps_floor = self.temps.items.len };
            return .{ .node = origin, .value_type = .none };
        }
        const carried = try recorder.recordLocal(self, null, result_type, storage, span);
        self.opened = .{ .temps_floor = self.temps.items.len };

        // The node says what the reload is in the tree's vocabulary —
        // a `carried_get` whose origin is the call — built before the
        // ledger row below so the row can carry it and `flushTemps`
        // can settle its park onto it (coupling #3).
        const node = try recorder.recordNode(self, .{ .carried_get = .{
            .slot = carried,
            .origin = origin,
            .result = result_type,
            .span = origin.span(),
        } });
        if (storage or objects) {
            // The carried slot's park is recorded like every other
            // (coupling #3): at the park, settled at retractions.
            ledger.setPark(node, .{
                .local = carried,
                .storage = storage,
                .released_storage = storage,
                .objects = objects,
            });
            try self.temps.append(self.temporary(), .{
                .local = carried,
                .node = node,
                .storage = storage,
                // This slot is reloaded, so it must keep owning its
                // storage: a borrowing slot would hand the reload the
                // register shape, and short text does not survive
                // that (docs/STRINGS.md).
                .disownable = false,
            });
        }
        return .{ .node = node, .value_type = result_type };
    }

    /// Lower the one call a `try` or `catch` is written in front of,
    /// with the permission that makes a fallible call legal.  Answers
    /// the value and what `openFallible` left, or null when the
    /// operand was not a call that can fail.
    fn lowerAttempt(
        self: *FunctionBuilder,
        operand: *ast.Expression,
        span: Span,
        verb: []const u8,
        as_statement: bool,
        shape_position: ShapePosition,
    ) Error!?struct { value: ?Typed, opened: Opened } {
        self.opened = null;
        self.allow_fallible = true;
        // `try f()` hands back exactly what `f()` does, so where the
        // `try` stands is where the call stands: `let a, b = try f()`
        // is a destructuring bind of a fallible call, and the whole of
        // what the two features owe each other (docs/RETURNS.md §2).
        self.shape_position = shape_position;
        const lowered = try self.lowerExpression(operand, as_statement);
        self.allow_fallible = false;
        self.shape_position = .refused;
        const opened = self.opened orelse {
            // A mistake inside the operand has already been reported;
            // adding "this cannot fail" to it would be noise.
            if (lowered != null) {
                try self.fail(
                    "luce.sema.fallible",
                    span,
                    "{s} applies to a call that can fail, and this one cannot; drop the {s}",
                    .{ verb, verb },
                );
            }
            return null;
        };
        self.opened = null;
        return .{ .value = lowered, .opened = opened };
    }

    /// `try CALL` — pass the error on.  The failing side is
    /// `lowerReturn`'s three lines with one terminator changed:
    /// release the temporaries, release the scopes innermost first,
    /// leave (docs/FAILURE.md).
    fn lowerTry(
        self: *FunctionBuilder,
        attempt: ast.Try,
        as_statement: bool,
        shape_position: ShapePosition,
    ) Error!?Typed {
        // Whether the operand can fail is asked **first**, and the
        // order is the diagnostic.  Asked the other way round, `try
        // plain()` inside a plain `main` answered "main does not say it
        // can fail; write '-> !'" — advice that is wrong, and wrong in
        // the expensive direction: following it changes a signature,
        // recompiles, and produces the real message, which is that
        // there was never an error to hand anywhere.  The same mistake
        // in a `main() -> !` already got that real message, so the
        // compiler knew; it just spoke in the wrong order.
        const attempted = (try self.lowerAttempt(
            attempt.operand,
            attempt.span,
            "try",
            as_statement,
            shape_position,
        )) orelse return null;
        if (!self.fallible) {
            try self.fail(
                "luce.sema.fallible",
                attempt.span,
                "try hands the error to the caller, and {s} does not say it can fail; write '-> !' (or '-> T!') on its signature, or handle it with catch",
                .{self.name},
            );
            return null;
        }

        var value = attempted.value orelse return null;
        // The tree wraps what the operand answered — the carried
        // reload, or the call itself for a callee answering nothing —
        // in the node form of the `try`, with the ledger floor the
        // failing side releases down to (nodes.TryCall); the failing
        // side itself — the releases and the unwind — is lower's.
        value.node = try recorder.recordNode(self, .{ .try_call = .{
            .call = value.node,
            .temps_floor = @intCast(attempted.opened.temps_floor),
            .result = value.value_type,
            .span = attempt.span,
        } });
        return value;
    }

    /// `CALL catch FALLBACK` — the fallback runs only where the call
    /// raised, and the reason is deliberately discarded there.
    fn lowerCatch(self: *FunctionBuilder, binary: ast.Binary, as_statement: bool) Error!?Typed {
        const attempted = (try self.lowerAttempt(
            binary.left,
            binary.span,
            "catch",
            as_statement,
            // `catch` supplies **one** value, so a multi-valued call
            // never stands behind it: `f() catch 0, 0` is a comma list
            // to the right of an operator, which has no reading that
            // does not first invent a tuple and then give it a
            // precedence (docs/RETURNS.md §2).  `.refused` is what
            // makes the call itself say so.
            .refused,
        )) orelse return null;
        const value = attempted.value orelse return null;

        // A call that answers nothing has no value to fall back to, so
        // both sides are statements and the whole thing is one.
        if (value.value_type == .none) {
            const floor = self.temps.items.len;
            const handled = (try self.lowerExpression(binary.right, true)) orelse return null;
            const fallback: nodes.Expression.CatchExpr.Fallback =
                if (expressions.isLeavingCall(binary.right)) .{ .leaving = handled.node } else .{ .value = handled.node };
            ledger.flushTemps(self, floor);
            return .{
                .node = try recorder.recordNode(self, .{ .catch_expr = .{
                    .call = value.node,
                    .fallback = fallback,
                    .temps_floor = @intCast(attempted.opened.temps_floor),
                    .result = .none,
                    .span = binary.span,
                } }),
                .value_type = .none,
            };
        }

        // The hidden merge slot both sides store into; the answer is
        // its reload — a view of what the slot holds.
        _ = try recorder.recordLocal(self, null, value.value_type, false, binary.span);
        var fallback: ?nodes.Expression.CatchExpr.Fallback = null;
        if (expressions.isLeavingCall(binary.right)) {
            // `f() catch trap("…")` and `f() catch error("…")` never
            // come back, so they leave nothing to store — the same
            // shape `x else trap("…")` has, and the node files the
            // call under `.leaving`, the union arm that stores nothing
            // (nodes.CatchExpr.Fallback).
            if (try self.lowerExpression(binary.right, true)) |gone| {
                fallback = .{ .leaving = gone.node };
            }
        } else if (try self.lowerTyped(binary.right, value.value_type, binary.span, "the catch fallback")) |landed| {
            fallback = .{ .value = landed.value.node };
        }
        const filed = fallback orelse return null;

        return .{
            .node = try recorder.recordNode(self, .{ .catch_expr = .{
                .call = value.node,
                .fallback = filed,
                .temps_floor = @intCast(attempted.opened.temps_floor),
                .result = value.value_type,
                .span = binary.span,
            } }),
            .value_type = value.value_type,
        };
    }

    /// The walk itself: pass one hands the body over here
    /// (`statements.zig`).
    pub fn lowerBlock(self: *FunctionBuilder, block: ast.Block) Error!void {
        try statements.lowerBlock(self, block);
    }

    /// The tree the walk recorded, sealed for stage 5
    /// (`recorder.zig`).
    pub fn finishBody(self: *FunctionBuilder) Error!void {
        try recorder.finishBody(self);
    }
};
