//! The checked walk of a function body — pass two of stage 4, and the
//! check half of the check/lower seam (05_hir.zig).
//!
//! Scope management, local declaration, ownership tracking, operand
//! ordering, statement and expression checking, call resolution, and
//! builtin typing.  Every decision this walk reaches is **recorded on
//! the typed tree** (`nodes.Body`) as it is reached: checking and
//! recording are one visit because resolving `xs.append(v)` needs the
//! receiver's type and typing it needs the name resolved first.  What
//! is *not* here is emission — `05_hir/lower.zig` consumes the
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
const source_mod = @import("../01_source.zig");
const ast = @import("../03_parse.zig").ast;
const types = @import("../support/types.zig");
const conversionNamed = types.conversionNamed;
const mir = @import("../06_mir.zig");
const helpers = @import("helpers.zig");

// The typed tree the check/lower seam hands over (05_hir.zig).  This
// walk *records* it as it checks, and `recorder.zig` is the one file
// that builds a node.
const nodes = @import("../05_hir.zig").nodes;

// What running a subtree could disturb, asked before it is lowered
// (`effects.zig`).
const effects = @import("effects.zig");

// What the language spells, and what each spelling lowers to
// (`builtins.zig`).  Named here under the names the walk uses, so the
// tables read the same whether the reader came from the dispatch or
// from the editor grammar that is generated out of them.
const builtins_mod = @import("builtins.zig");
const builtins = builtins_mod.builtins;
const fresh_object_methods = builtins_mod.fresh_object_methods;

// Pass one, for the one thing this walk needs from it: the collected
// project it runs against.
const Analyzer = @import("declarations.zig").Analyzer;
const naming = @import("naming.zig");
const resolve = @import("resolve.zig");
const shapes = @import("shapes.zig");
const signatures = @import("signatures.zig");

// The stage's shared vocabulary (`04_semantics/context.zig`).
const context = @import("context.zig");
const FunctionDeclInfo = context.FunctionDeclInfo;
const EnclosingLocal = context.EnclosingLocal;
const OwnershipClass = context.OwnershipClass;
const RootState = context.RootState;
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
    /// The typed tree's node for this expression (05_hir.zig): what
    /// the walk records, and what `hir.lower` consumes.
    node: nodes.NodeRef,
    value_type: Type,
    /// Static knowledge of the root behind an object value.  Most
    /// producers are fresh/mutable; names and borrowed reads override
    /// the default where the distinction matters (CONSTANTS R-C/R-D).
    root: RootState = .mutable,
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

/// Whether a call answering a return shape is being received by a
/// destructuring statement, refused in an ordinary value position, or
/// returned directly (docs/RETURNS.md and the SELF polish ruling).
pub const ShapePosition = enum { refused, receive, returning };

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

/// How deep `splitsBlocks` will look before answering yes on
/// principle.  It runs on whole operand subtrees *before* they are
/// lowered, so the depth bound `lowerExpression` keeps cannot
/// protect it — it needs its own, and it has the luxury of a safe
/// wrong answer: "this may split" only ever costs a spill.  The
/// margin over the lowering bound keeps an accepted program from
/// ever paying for it.
pub const split_search_depth: u32 = helpers.max_expression_depth + 8;

/// A value that reached its place, and whether it got there by the
/// `T <: T?` widening — which is how an assignment knows the slot
/// definitely holds something now.
const Fitted = struct { value: Typed, present: bool };

/// Lower a left-to-right operand sequence whose values must all
/// be usable together afterwards.  Registers are block-local in
/// the emission, so every operand followed by a block-splitting
/// one is carried across the split in a hidden local — the slot is
/// allocated here and the reload is lower's, driven by the
/// recorded spill flags.  The returned values live in the arena.
/// Operand counts this stage's scratch fits without allocating.
/// Every binary operator has two, an index has at most five, and a
/// call of more than this is rare — but `lowerOperands` runs for
/// each of them, and two allocate-and-free pairs per operator is
/// most of the compiler's allocator traffic when it is not one.
const inline_operands = 8;

/// A method batch's landing needs the written arguments as well as
/// the name: which slot an argument fills is what says where it
/// lands, and a named argument may fill a slot its position does
/// not (docs/ARGS.md D5).
const MethodLanding = struct {
    name: []const u8,
    arguments: []const ast.Argument,
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
    method: MethodLanding,
    /// Operand zero is a container, the last operand is a value
    /// going into it, and everything between is an index.
    stored_element,
    /// Operand zero is a container or a string and every other
    /// operand subscripts it — an index or a slice bound.  The
    /// read half of `stored_element`, and it exists because
    /// `m[1] = "one"` landing its key while `m[1]` did not would
    /// be a rule about which side of the equals sign a literal
    /// sits on.
    subscripts,
};

/// A bare owning operand is staged at one exact point in a batch.
/// Its revision at that point distinguishes a later write, which
/// invalidates the staged value, from an earlier write whose new
/// value is precisely what the operand loads.
pub const StagedOperandOwner = struct {
    local: LocalId,
    revision: u32,
    name: []const u8,
};

/// One lowered operand batch: the values in written order, and the
/// batch's two per-operand rewrites — which operands were reloaded
/// from a spill slot across a block split, and which took the
/// defensive borrow copy in front of a later container-mutating
/// operand.  The flags are what the call nodes record
/// (nodes.OperandBatch); the values' nodes stay the written
/// expressions, pre-rewrite, per that batch's convention.
/// Arena-owned, because the recorded batch outlives the statement.
pub const OperandRun = struct {
    values: []Typed,
    spilled: []bool,
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
    /// The typed tree's statement recorder (05_hir.zig): one frame per
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
    /// this table instead (05_hir.zig, coupling #5).
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
                return .{ .info = found, .depth = index };
            }
        }
        return null;
    }

    // Who owns what an alias names (S8, S23) --------------------------------
    //
    // `let y = x` makes y another name for x's object.  Refusing
    // `give y` is only half an answer; the other half is `give x`, and
    // these two keep enough to say it.

    /// Record, on the alias just declared, the name that owns its
    /// object.  Chains collapse to their root: after `let a = xs` and
    /// `let b = a`, both name `xs`, because that is the name a reader
    /// would have to write.
    pub fn rememberOwnerName(self: *FunctionBuilder, alias: []const u8, source: []const u8) void {
        const from = self.findLocal(source) orelse return;
        const root = from.info.owner_name orelse source;
        const declared = self.findLocal(alias) orelse return;
        declared.info.owner_name = root;
    }

    /// Replacing an owning binding does not make its old aliases point
    /// at the replacement.  They still hold the old (now released)
    /// handle, so retaining `owner_name` would make later diagnostics
    /// recommend moving an unrelated new graph.  Alias chains are
    /// collapsed to the written root in `rememberOwnerName`, making a
    /// linear visible-scope invalidation both complete and rare (S8,
    /// S23).
    pub fn forgetAliasesOwnedBy(self: *FunctionBuilder, owner: []const u8) void {
        for (self.scopes.items) |*scope| {
            var locals = scope.names.valueIterator();
            while (locals.next()) |info| {
                const remembered = info.owner_name orelse continue;
                if (std.mem.eql(u8, remembered, owner)) info.owner_name = null;
            }
        }
    }

    /// The owner to name in a refusal, or null when there is none worth
    /// naming.  A recorded name is only useful advice while it is still
    /// the owner: one that has since been given away or freed would
    /// send the reader to a second diagnostic, so it is withheld and
    /// the refusal falls back to saying that an owner exists.
    pub fn ownerNameFor(self: *FunctionBuilder, info: *const LocalInfo) ?[]const u8 {
        const owner = info.owner_name orelse return null;
        const found = self.findLocal(owner) orelse return null;
        if (found.info.class != .owned) return null;
        if (found.info.poisoned != null) return null;
        return owner;
    }

    /// True when giving this binding here would poison a name that a
    /// later iteration can reach (S30).  Returns and other terminating
    /// moves ask their own question; this is for handoff advice and
    /// the `give` expression itself.
    pub fn declaredOutsideActiveLoop(self: *const FunctionBuilder, depth: usize) bool {
        if (self.loops.items.len == 0) return false;
        return depth < self.loops.items[self.loops.items.len - 1].scope_depth;
    }

    /// A live owner that may actually be given at this source point.
    /// An outer-loop owner is still the alias's owner, but naming it as
    /// a repair would immediately earn S30's next diagnostic.
    pub fn giveableOwnerNameFor(self: *FunctionBuilder, info: *const LocalInfo) ?[]const u8 {
        const owner = self.ownerNameFor(info) orelse return null;
        const found = self.findLocal(owner) orelse return null;
        if (self.declaredOutsideActiveLoop(found.depth)) return null;
        const owner_type = recorder.localType(self, found.info.local);
        if (owner_type == .optional and !flow.isNarrowed(self, found.info.local)) return null;
        return owner;
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
            if (self.analyzer.struct_names.contains(local_head)) {
                return try naming.qualify(self.analyzer, self.prefix, written);
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
        class: OwnershipClass,
        span: Span,
    ) Error!?LocalId {
        return self.declareLocalAs(name, local_type, mutable, class, .owns, span);
    }

    pub fn declareLocalAs(
        self: *FunctionBuilder,
        name: []const u8,
        local_type: Type,
        mutable: bool,
        class: OwnershipClass,
        storage_class: StorageClass,
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
        const carries = shapes.carriesObjects(self.analyzer, local_type);
        const owns_storage = storage_class == .owns and shapes.ownsStorage(self.analyzer, local_type);
        const local = try recorder.recordLocal(self, name, local_type, owns_storage, span);
        const scope = &self.scopes.items[self.scopes.items.len - 1];
        try scope.names.put(self.temporary(), name, .{
            .local = local,
            .mutable = mutable,
            .declared_at = span,
            .class = if (carries) class else .alias,
            .carries = carries,
        });
        const owns_objects = carries and class == .owned;
        if (owns_objects or owns_storage) {
            try scope.owned.append(self.temporary(), .{
                .local = local,
                .objects = owns_objects,
                .storage = owns_storage,
            });
        }
        return local;
    }

    /// Install the implicit receiver as logical parameter zero.
    ///
    /// A reader borrows an ordinary value parameter.  A writer is an
    /// alias of the caller's mutable binding: its MIR slot owns the
    /// *representation* needed to drop replaced strings/struct runs,
    /// but its lifetime and object-owner identity remain the caller's,
    /// so this scope must never release it (docs/SELF.md D3-D6).
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
        const carries = shapes.carriesObjects(self.analyzer, receiver_type);
        const scope = &self.scopes.items[self.scopes.items.len - 1];
        try scope.names.put(self.temporary(), "self", .{
            .local = local,
            .mutable = writes,
            .declared_at = span,
            .class = if (!carries)
                .alias
            else if (writes)
                .inout_receiver
            else
                .borrow_param,
            .carries = carries,
        });
        return local;
    }

    // Block splits ---------------------------------------------------------
    //
    // Whether lowering a subtree can end in a basic block other than
    // the one it started in — asked of a whole operand run before any
    // of it is lowered, because a register does not cross a split and
    // the value it holds has to be carried in a slot instead.  A safe
    // wrong answer is "yes", which costs one spill.

    /// True when lowering this expression may end in a different basic
    /// block than it started: short-circuit `and`/`or` anywhere inside
    /// it branches and merges.
    fn splitsBlocks(self: *const FunctionBuilder, expression: *const ast.Expression, budget: u32) bool {
        if (budget == 0) return true;
        const left = budget - 1;
        return switch (expression.*) {
            .binary => |binary| binary.op == .logic_and or binary.op == .logic_or or
                binary.op == .coalesce or binary.op == .catch_error or
                self.splitsBlocks(binary.left, left) or self.splitsBlocks(binary.right, left),
            .unary => |unary| self.splitsBlocks(unary.operand, left),
            .field => |field| self.splitsBlocks(field.target, left),
            .call => |call| self.callSplits(call.callee) or self.anySplits(call.arguments, left),
            .new_object => |new| for (new.dims) |dimension| {
                if (self.splitsBlocks(dimension, left)) break true;
            } else false,
            .list_literal => |literal| for (literal.elements) |element| {
                if (self.splitsBlocks(element, left)) break true;
            } else false,
            .map_literal => |literal| for (literal.entries) |entry| {
                if (self.splitsBlocks(entry.key, left) or self.splitsBlocks(entry.value, left)) break true;
            } else false,
            .index => |index| self.splitsBlocks(index.target, left) or for (index.indices) |item| {
                if (self.splitsBlocks(item, left)) break true;
            } else false,
            .slice_range => |slice| self.splitsBlocks(slice.target, left) or
                (slice.start != null and self.splitsBlocks(slice.start.?, left)) or
                (slice.end != null and self.splitsBlocks(slice.end.?, left)),
            .method => |method| self.callSplits(method.name) or
                self.splitsBlocks(method.target, left) or
                self.anySplits(method.arguments, left),
            .give => |give| self.splitsBlocks(give.operand, left),
            .copy => |copied| self.splitsBlocks(copied.operand, left),
            // A fallible call branches on its outcome, always.
            .try_call => true,
            // A spawn is one runtime call and no branch, but what it
            // is *given* may split; ask the arguments.
            .spawn => |worker| self.splitsBlocks(worker.call, left),
            else => false,
        };
    }

    /// Whether a call written with this name may end in a different
    /// block than it started.
    ///
    /// The two enum forms do: `string(m)` picks a member's name and
    /// `Method(n)` picks a member, and both are the compare-and-branch
    /// tree `match` is (docs/ENUMS.md D5, R2).  It is asked by **name**,
    /// because this walk runs before any operand has a type — so
    /// `string(count)` answers yes as well, and pays the one spill a
    /// safe wrong answer costs here.
    fn callSplits(self: *const FunctionBuilder, callee: []const u8) bool {
        if (conversionNamed(callee)) |produces| return produces == .string;
        return self.namesEnum(callee);
    }

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
        return false;
    }

    /// Whether a written name is an enum's, in this module or an
    /// imported one.  Matched on the last segment, which is what a
    /// method-form call hands over (`zip.Method(8)` arrives here as
    /// `Method`), and over-matching only costs a spill.
    fn namesEnum(self: *const FunctionBuilder, written: []const u8) bool {
        var names = self.analyzer.enum_names.keyIterator();
        while (names.next()) |key| {
            const declared = key.*;
            if (std.mem.eql(u8, declared, written)) return true;
            const dot = std.mem.lastIndexOfScalar(u8, declared, '.') orelse continue;
            if (std.mem.eql(u8, declared[dot + 1 ..], written)) return true;
        }
        return false;
    }

    fn anySplits(self: *const FunctionBuilder, arguments: []const ast.Argument, budget: u32) bool {
        for (arguments) |argument| {
            if (self.splitsBlocks(argument.value, budget)) return true;
        }
        return false;
    }

    // Ownership classification ---------------------------------------------

    /// True when evaluating this expression yields an object the
    /// receiver may own: something fresh (new, a literal, a slice, a
    /// call result, pop/split/keys), a give, or a copy.  Names and
    /// element/field reads are borrows (S8, S22).  Only consulted for
    /// object-carrying types, so value-typed calls answering true is
    /// harmless.
    pub fn yieldsOwnership(self: *FunctionBuilder, expression: *const ast.Expression) Error!bool {
        return switch (expression.*) {
            // A spawn makes a task nobody has named, exactly as `new`
            // makes a list nobody has named (docs/THREADS.md D3).
            .new_object, .list_literal, .map_literal, .slice_range, .call, .give, .copy, .spawn => true,
            // `try f()` hands over exactly what `f()` does: the value
            // crosses a block boundary through a slot, and a slot
            // carrying an object changes nothing about who owns it.
            .try_call => |attempt| try self.yieldsOwnership(attempt.operand),
            // `a else b` and `a catch b` hand over an object exactly
            // when both sides do; both lowerings refuse the case where
            // they differ.
            .binary => |binary| (binary.op == .coalesce or binary.op == .catch_error) and
                try self.yieldsOwnership(binary.left) and
                try self.yieldsOwnership(binary.right),
            .method => |method| blk: {
                if (try self.methodIsNamespaced(method)) break :blk true;
                for (fresh_object_methods) |name| {
                    if (std.mem.eql(u8, method.name, name)) break :blk true;
                }
                if (self.structMethodYieldsObject(method.name)) break :blk true;
                break :blk self.routedMethodYieldsObject(method.name);
            },
            // `Json.null` — a bare union member is a construction, and
            // a construction is fresh (docs/UNION.md D4).
            .field => |field| blk: {
                const chain = helpers.dottedChain(field.target) orelse break :blk false;
                if (self.findLocal(chain.head()) != null) break :blk false;
                var parts_buffer: [8][]const u8 = undefined;
                if (chain.count + 1 > parts_buffer.len) break :blk false;
                parts_buffer[0] = field.name;
                for (chain.parts[0..chain.count], 1..) |part, at| parts_buffer[at] = part;
                break :blk self.namesVariantParts(parts_buffer[0 .. chain.count + 1]);
            },
            else => false,
        };
    }

    /// Whether a dotted chain, written inner-to-outer, spells a
    /// **union** member: `Json.null`, `zip.Shape.circle`.  The last
    /// part is the member and everything in front of it names the
    /// union — `namesMember`'s shape, narrowed to one table, for the
    /// caller that has to know which kind it found.
    fn namesVariantParts(self: *FunctionBuilder, parts: []const []const u8) bool {
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
        const index = self.analyzer.variant_names.get(head) orelse return false;
        return self.analyzer.variants.items[index].findMember(parts[0]) != null;
    }

    /// True when `name` is a standard-library function that method
    /// sugar routes to and that hands back an object — `s.split(",")`
    /// is `strings.split(s, ",")`, and a call's result belongs to the
    /// caller (S16).
    ///
    /// Asked of the declaration rather than of a hand-kept list on
    /// purpose: a list is a thing that goes stale, and the way it
    /// would go stale here is a new object-returning `strings`
    /// function whose result nobody owns and nobody frees.  A method
    /// with no such routing answers false, and a routed one returning
    /// a value answers false too, so this only ever says yes where an
    /// object really comes out.
    fn routedMethodYieldsObject(self: *const FunctionBuilder, name: []const u8) bool {
        var qualified: [64]u8 = undefined;
        const written = std.fmt.bufPrint(&qualified, "strings.{s}", .{name}) catch return false;
        const index = self.analyzer.function_names.get(written) orelse return false;
        return shapes.carriesObjects(self.analyzer, self.analyzer.functions.items[index].return_type);
    }

    /// True when some struct in this program declares a **method** by
    /// this name whose result carries objects — `p.spread()` answering
    /// a fresh `list(long)`, which the caller owns like any other call
    /// result (S16, docs/METHODS.md).
    ///
    /// Asked of the name rather than of the receiver, and for the same
    /// reason `routedMethodYieldsObject` is: this question is put
    /// *before* a give argument is lowered, so the receiver's type is
    /// not yet known and cannot be.  Answering yes for a name some
    /// other struct also spells costs nothing — every caller has
    /// already established that the value in hand carries objects, and
    /// a call's result is owned whenever it does.
    fn structMethodYieldsObject(self: *const FunctionBuilder, name: []const u8) bool {
        for (self.analyzer.functions.items) |candidate| {
            if (candidate.receiver == .not) continue;
            const dot = std.mem.lastIndexOfScalar(u8, candidate.name, '.') orelse continue;
            if (!std.mem.eql(u8, candidate.name[dot + 1 ..], name)) continue;
            if (shapes.carriesObjects(self.analyzer, candidate.return_type)) return true;
        }
        return false;
    }

    /// Side-effect-free twin of methodNamespace: does target.name(...)
    /// resolve to a declaration (whose result the caller owns, S16)
    /// rather than a builtin method on a value?
    fn methodIsNamespaced(self: *FunctionBuilder, method: ast.Method) Error!bool {
        const chain = helpers.dottedChain(method.target) orelse return false;
        const head = chain.head();
        if (self.findLocal(head) != null) return false;
        if (refusals.capturesName(self, head)) return false;
        const head_qualified = try naming.qualify(self.analyzer, self.prefix, head);
        if (self.analyzer.struct_names.contains(head_qualified)) return true;
        if (self.analyzer.variant_names.contains(head_qualified)) return true;
        return naming.importsModule(self.analyzer, self.module, head);
    }
    // Landing ---------------------------------------------------------------
    //
    // Getting a checked value into the place that expects it: the
    // implicit widenings (docs/TYPES.md), the numeric unification two
    // operands meet at, and the one function every place calls to say
    // yes or no.  What is said when the answer is no is `refusals.zig`.

    /// Make an already-lowered value fit `expected`, applying the two
    /// widenings the language has: `long` into `double`
    /// (docs/NUMERICS.md) and `T` into `T?` (S43 — the widened value
    /// owns exactly what it owned before).  Null means it does not fit
    /// and the caller reports.
    ///
    /// **This is the one place promotion happens**, which is why every
    /// site that already called it — annotation, argument, return,
    /// element, field — gets promotion consistently and none of them
    /// had to learn about it.  The two widenings compose in the one
    /// order that makes sense: `let x: double? = 1` widens, then wraps.
    pub fn fit(self: *FunctionBuilder, value: Typed, expected: Type) Error!?Typed {
        if (value.value_type.eql(expected)) return value;
        if (value.value_type.widensTo(expected)) return try self.widenNumeric(value, expected);
        const payload = expected.held() orelse return null;
        const inner = (try self.fit(value, payload)) orelse return null;
        // The `T <: T?` widening is a node of its own
        // (`wrap_optional`), recorded here at the one place promotion
        // is spelled — as `convert` is at `widenNumeric` — so every
        // site that wraps records without knowing it.
        return .{
            .node = try recorder.recordNode(self, .{ .wrap_optional = .{
                .operand = inner.node,
                .result = expected,
                .span = inner.node.span(),
            } }),
            .value_type = expected,
            .root = inner.root,
        };
    }

    /// Widen a number to a wider one along `Type.widensTo` — the whole
    /// of the language's unwritten numeric conversion (docs/TYPES.md
    /// §2).  Four pairs: `int` to `long` and to `double`, `long` to
    /// `double`, `float` to `double`.  Never the reverse, and never
    /// across a ladder into a *narrow* float, because implicit
    /// narrowing is what would make a lost digit silent.
    ///
    /// A widened *literal* costs nothing: the conversion of a constant
    /// is folded before any machine code exists.  A widened variable
    /// costs one instruction.
    ///
    /// The caller has already asked `widensTo`; this asserts it rather
    /// than re-deciding it, so there is one statement of the lattice.
    pub fn widenNumeric(self: *FunctionBuilder, value: Typed, to: Type) Error!Typed {
        std.debug.assert(value.value_type.widensTo(to));
        // The widening is a node of its own (`convert`), so an operand
        // tree says where every conversion stands — and recording it
        // here covers every site that widens, because this is the one
        // place widening is spelled.
        return .{
            .node = try recorder.recordNode(self, .{ .convert = .{
                .operand = value.node,
                .result = to,
                .span = value.node.span(),
            } }),
            .value_type = to,
            .root = value.root,
        };
    }

    /// Bring an already-lowered value to `want` when it gets there by
    /// widening, and say whether it is there afterwards.
    ///
    /// The builtins ask this rather than comparing types, because
    /// "an index is a `long`" has always meant *an integer*, and an
    /// `int` is one — it reaches a `long` place with nothing written
    /// down, exactly as it does at an argument or a store
    /// (docs/TYPES.md §2).  Comparing exactly would refuse
    /// `xs[i]` for the commonest `int` there is, a loop counter.
    ///
    /// The value is rewritten in place, because the register the
    /// caller goes on to pass is this one.
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
            .builder, .file, .task => null,
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
        self.wanted_function = if (expected == .function) expected.function else null;
    }

    /// A number at the type an operator computes it at — `int` for a
    /// `byte` or a `short`, `float` for a `half`, and itself for the
    /// four that already do arithmetic (D5).  The one place that
    /// promotion is spelled for a *single* operand; `unifyNumeric` is
    /// the same rule for a pair.
    pub fn promoted(self: *FunctionBuilder, value: Typed) Error!Typed {
        const at = value.value_type.arithmeticType() orelse return value;
        if (value.value_type.eql(at)) return value;
        return self.widenNumeric(value, at);
    }

    /// Bring two numeric operands to the type they meet at
    /// (`Type.unified`).  True when it moved either of them.
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
                        "move the operation into a top-level or static function that receives and returns the value [SELF.md D3, FUNCTIONS.md D1]",
                    .{written},
                );
            } else {
                if (info.declaration.parameters.len == 0) {
                    try self.fail(
                        "luce.sema.call",
                        span,
                        "{s} is a method, and a method reference would carry its receiver; " ++
                            "write a lambda that takes the receiver — (x) -> x.{s}() [FUNCTIONS.md D1]",
                        .{ written, info.declaration.name },
                    );
                } else {
                    try self.fail(
                        "luce.sema.call",
                        span,
                        "{s} is a method, and a method reference would carry its receiver; " ++
                            "write a lambda whose first parameter receives the value and whose remaining parameters forward the method arguments [FUNCTIONS.md D1]",
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
        if (!self.matchesSignature(info, wants)) {
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

    /// Whether a declared function really has the shape a function type
    /// demands: the same parameter types in the same order, the same
    /// verb on each, and the same answer.
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
    ) bool {
        _ = self;
        if (info.results.len >= 2) return false;
        if (info.parameter_types.len != wants.parameters.len) return false;
        if (!info.return_type.eql(wants.result)) return false;
        for (info.parameter_types, info.parameter_modes, wants.parameters) |held, mode, parameter| {
            if ((mode == .give) != parameter.gives) return false;
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
        for (info.parameter_types, info.parameter_modes, parameters) |held, mode, *parameter| {
            parameter.* = .{ .value_type = held, .gives = mode == .give };
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

    /// Report a use of a poisoned name (S10, S29); true when poisoned.
    pub fn checkPoisoned(self: *FunctionBuilder, info: *const LocalInfo, name: []const u8, span: Span) Error!bool {
        const why = info.poisoned orelse return false;
        try self.fail(
            "luce.sema.own",
            span,
            "{s} was {s} and cannot be touched again in this scope [OWNERSHIP.md {s}]",
            .{
                name,
                if (why == .given) @as([]const u8, "given away") else "freed",
                if (why == .given) @as([]const u8, "S10, S29") else "S6",
            },
        );
        return true;
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
    ) Error!?Type {
        switch (landing) {
            .nothing => return null,
            .places => |places| return places[index],
            .maybe_places => |places| return places[index],
            .method => |method| {
                if (index == 0) return null;
                // A struct receiver's parameters come from the
                // declaration, and which slot this argument fills is
                // what decides its landing — names may reorder
                // (docs/ARGS.md D5), so the slot is answered silently
                // by the same rule the checker applies after the
                // batch, through the one `argumentSlot`.
                if (calls.declaredName(self, values[0].value_type) != null) {
                    const function_index = (try calls.structMethod(self, values[0].value_type, method.name)) orelse
                        return null;
                    const info = self.analyzer.functions.items[function_index];
                    const hidden: usize = if (info.receiver == .not) 0 else 1;
                    if (info.declaration.parameters.len + hidden != info.parameter_types.len) return null;
                    const surface = try calls.declarationSlots(self, info);
                    const slot = calls.argumentSlot(surface, 1, method.arguments, index - 1) orelse
                        return null;
                    return info.parameter_types[slot];
                }
                const wanted = (try calls.methodParameters(self, values[0].value_type, method.name)) orelse
                    return null;
                const slot = index - 1;
                if (slot >= wanted.len) return null;
                // A builtin method's arguments are positional (D10),
                // so a named one is refused after the batch.  A bare
                // function or lambda still needs its positional type
                // while being lowered, however; without that landing
                // its "needs a function place" error would hide the
                // more fundamental named-argument refusal.
                if (method.arguments[slot].name != null and wanted[slot] != .function) return null;
                return wanted[slot];
            },
            .stored_element => {
                if (index == 0) return null;
                // The subscripts land where subscripts land; the value
                // at the end lands on the element type, which the
                // container named.
                if (index + 1 < count) return self.subscriptType(values[0].value_type);
                const descriptor = self.analyzer.heapOf(values[0].value_type) orelse return null;
                return switch (descriptor) {
                    .list => |element| element,
                    .array => |shape| shape.element,
                    .map => |pair| pair.value,
                    .builder, .file, .task => null,
                };
            },
            .subscripts => {
                if (index == 0) return null;
                return self.subscriptType(values[0].value_type);
            },
        }
    }

    /// What a subscript of `container` lands on: a map takes its key
    /// type, and everything a position can address — a list, an array,
    /// a string being sliced — takes a `long`.
    fn subscriptType(self: *FunctionBuilder, container: Type) ?Type {
        if (container == .string) return .long;
        const descriptor = self.analyzer.heapOf(container) orelse return null;
        return switch (descriptor) {
            .list, .array => .long,
            .map => |pair| pair.key,
            .builder, .file, .task => null,
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
        const run = (try self.lowerOperandsIntoTracking(operands, landing, null)) orelse return null;
        return run.values;
    }

    /// The ordinary operand walk, optionally recording the revision of
    /// each bare owning name at the moment that operand is staged.  Only
    /// shaped returns need the observation; all other callers use the
    /// wrapper above and pay no bookkeeping cost.
    pub fn lowerOperandsIntoTracking(
        self: *FunctionBuilder,
        operands: []const *ast.Expression,
        landing: Landing,
        staged_owners: ?[]?StagedOperandOwner,
    ) Error!?OperandRun {
        if (staged_owners) |owners| {
            std.debug.assert(owners.len == operands.len);
            @memset(owners, null);
        }
        var spill_storage: [inline_operands]?LocalId = undefined;
        var split_storage: [inline_operands]bool = undefined;
        const wide = operands.len > inline_operands;

        const values = try self.arena().alloc(Typed, operands.len);
        const spilled = try self.arena().alloc(bool, operands.len);
        @memset(spilled, false);
        const copied = try self.arena().alloc(bool, operands.len);
        @memset(copied, false);
        const spills = if (wide)
            try self.temporary().alloc(?LocalId, operands.len)
        else
            spill_storage[0..operands.len];
        defer if (wide) self.temporary().free(spills);

        const later_splits = if (wide)
            try self.temporary().alloc(bool, operands.len)
        else
            split_storage[0..operands.len];
        defer if (wide) self.temporary().free(later_splits);
        var any_split = false;
        var backwards = operands.len;
        while (backwards > 0) {
            backwards -= 1;
            later_splits[backwards] = any_split;
            if (self.splitsBlocks(operands[backwards], split_search_depth)) any_split = true;
        }

        // Which operands still have something that could mutate a
        // container running after them — the residual hazard below.
        var later_mutates: [inline_operands]bool = undefined;
        const mutating = if (wide)
            try self.temporary().alloc(bool, operands.len)
        else
            later_mutates[0..operands.len];
        defer if (wide) self.temporary().free(mutating);
        var any_mutation = false;
        backwards = operands.len;
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
            const place = try self.landsOn(landing, values, index, operands.len);
            if (place) |landed| self.wantPlace(landed);
            // A bare `none` has no type of its own; the place it lands
            // on supplies one, whichever way the batch knows the place
            // — written down up front (`.places`) or answered by the
            // receiver (`.method`), the same answer either way.
            const value = if (expression.* == .none_literal and place != null)
                ((try self.lowerTyped(expression, place.?, expression.span(), "this place")) orelse
                    return null).value
            else
                (try self.lowerExpression(expression, false)) orelse return null;
            values[index] = value;
            if (staged_owners) |owners| {
                if (expression.* == .name) {
                    if (self.findLocal(expression.name.text)) |found| {
                        if (found.info.carries and found.info.class == .owned) {
                            owners[index] = .{
                                .local = found.info.local,
                                .revision = found.info.revision,
                                .name = expression.name.text,
                            };
                        }
                    }
                }
            }
            // The residual hazard copy-on-store leaves open
            // (docs/STRINGS.md): this value may be a *borrow* of an
            // element's or a field's bytes, and an operand still to
            // come could free them — `f(pieces[0], drop_first(pieces))`
            // is the shape.  An object would go stale and trap (S9); a
            // string has no handle to check, so it closes here, by
            // deciding the copy before the mutation can happen.
            if (mutating[index] and
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
            spills[index] = null;
            if (later_splits[index] and values[index].value_type != .none) {
                // The spill slot's row, in the order lower makes it.
                spills[index] = try recorder.recordLocal(self, null, values[index].value_type, false, expression.span());
            }
        }
        for (spills, 0..) |spill, index| {
            if (spill != null) {
                // The reload is a view of the spill slot's storage: a
                // fresh operand spilled across a split loses its
                // freshness, so the store that receives it copies.
                values[index].rewritten = .view;
                spilled[index] = true;
            }
        }
        return .{ .values = values, .spilled = spilled, .copied = copied };
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
        // Every ownership-yielding object is parked as a statement
        // temporary (S3).  Whatever adopts it — a binding, a
        // container, a give parameter, a return — re-owns it at run
        // time, which turns the parked release into a no-op.
        const objects = shapes.carriesObjects(self.analyzer, value.value_type) and
            try self.yieldsOwnership(expression) and
            !ledger.parkedAlready(self, value.node);
        // Freshly allocated storage is parked for the same reason and
        // in the same slot, but the two questions differ: `give s`
        // hands over an object while borrowing the struct run it sits
        // in, and a string slice borrows without yielding anything
        // (docs/STRINGS.md).
        const storage = shapes.ownsStorage(self.analyzer, value.value_type) and
            value.provenance() == .fresh and
            !ledger.parkedAlready(self, value.node);
        if (objects or storage) try ledger.registerTemp(self, value, objects, storage, expression.span());
        return value;
    }

    /// Materialise an integer literal at the type it lands on
    /// (docs/TYPES.md D3).  `negated` folds the minus in first, so
    /// `long`'s minimum stays writable; `wanted` is the landing type
    /// the context asked for, and null means there is no context and
    /// the literal takes the default, which is `int`.
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
        const lands: Type = wanted orelse .int;
        if (lands.isFloating()) {
            const parsed = helpers.parseIntLiteralAsFloat(literal.text, negated, lands) orelse {
                try self.fail("luce.sema.literal", span, "{s}", .{context.rangeMessage(lands)});
                return null;
            };
            return .{
                .node = try recorder.recordNode(self, .{ .const_double = .{ .value = parsed, .result = lands, .span = span } }),
                .value_type = lands,
            };
        }
        const parsed = helpers.parseIntLiteral(literal.text, negated, lands) orelse {
            try self.fail("luce.sema.literal", span, "{s}", .{context.rangeMessage(lands)});
            return null;
        };
        return .{
            .node = try recorder.recordNode(self, .{ .const_long = .{ .value = parsed, .result = lands, .span = span } }),
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
                // A float literal lands on `float` with no context —
                // the owner's ruling, and the one place the language
                // differs from every precedent (docs/TYPES.md D2).
                const lands: Type = if (wanted) |place|
                    (if (place.isFloating()) place else .float)
                else
                    .float;
                const parsed = helpers.parseFloatLiteral(literal.text, lands) orelse {
                    try self.fail("luce.sema.literal", literal.span, "{s}", .{context.rangeMessage(lands)});
                    return null;
                };
                return .{
                    .node = try recorder.recordNode(self, .{ .const_double = .{ .value = parsed, .result = lands, .span = literal.span } }),
                    .value_type = lands,
                };
            },
            .bool_literal => |literal| {
                return .{
                    .node = try recorder.recordNode(self, .{ .const_boolean = .{ .value = literal.value, .result = .boolean, .span = literal.span } }),
                    .value_type = .boolean,
                };
            },
            .string_literal => |literal| {
                const constant = try self.analyzer.pool.intern(literal.decoded);
                return .{
                    .node = try recorder.recordNode(self, .{ .const_string = .{ .constant = constant, .result = .string, .span = literal.span } }),
                    .value_type = .string,
                };
            },
            .name => |name| {
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
                if (try self.checkPoisoned(found.info, name.text, name.span)) return null;
                const local = found.info.local;
                const local_type = recorder.localType(self, local);
                // A narrowed local reads as its payload: the value is
                // the same bits, and the flow analysis has already
                // proved it is there.
                if (local_type == .optional and flow.isNarrowed(self, local)) {
                    const payload = local_type.held().?;
                    return .{
                        .node = try recorder.recordNode(self, .{ .narrowed_get = .{
                            .local = local,
                            .payload = payload,
                            .result = payload,
                            .span = name.span,
                        } }),
                        .value_type = payload,
                        .root = found.info.root,
                    };
                }
                // A name reads as a view of what its slot holds; the
                // narrowed unwrap above answers neither fresh nor view.
                return .{
                    .node = try recorder.recordNode(self, .{ .local_get = .{
                        .local = local,
                        .result = local_type,
                        .span = name.span,
                    } }),
                    .value_type = local_type,
                    .root = found.info.root,
                };
            },
            // `none` has no type of its own; every place that can
            // accept it supplies one through `lowerTyped`, so reaching
            // here means nothing did.
            .none_literal => |literal| {
                try self.fail(
                    "luce.sema.absent",
                    literal.span,
                    "none needs a type here; write it into something declared T? (var x: long? = none), or compare with a T? (x == none)",
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
                            return self.functionValue(written, field.span, signature);
                        }
                    }
                }
                return expressions.lowerField(self, field);
            },
            .call => |call| return calls.lowerCall(self, call, as_statement, fallible_allowed, shape_position, wanted),
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
            .give => |give| return expressions.lowerGive(self, give),
            .copy => |copied| return expressions.lowerCopy(self, copied),
            .try_call => |attempt| return self.lowerTry(attempt, as_statement, shape_position),
            .spawn => |worker| return calls.lowerSpawn(self, worker, as_statement),
            .lambda => |written| return self.lowerLambda(expression, written, wanted_function),
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
                "a lambda needs a place that expects a function: annotate the binding, or pass it where a func(...) parameter is declared [FUNCTIONS.md S3]",
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
        for (written.parameters, signature.parameters, parameters) |name, parameter, *slot| {
            slot.* = .{
                .name = name.text,
                .name_span = name.span,
                .mode = if (parameter.gives) .give else .borrow,
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
    fn visibleLocals(self: *FunctionBuilder) Error![]const EnclosingLocal {
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
        const objects = shapes.carriesObjects(self.analyzer, result_type);
        const storage = shapes.ownsStorage(self.analyzer, result_type);

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
        if (objects or storage) {
            // The carried slot's park is recorded like every other
            // (coupling #3): at the park, settled at retractions.
            ledger.setPark(node, .{
                .local = carried,
                .objects = objects,
                .storage = storage,
                .released_objects = objects,
                .released_storage = storage,
            });
            try self.temps.append(self.temporary(), .{
                .local = carried,
                .node = node,
                .objects = objects,
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

        // Both sides must agree on ownership, for the reason `else`
        // does: the binding that receives the result either owns an
        // object or does not, and that is one static fact (S1, S8).
        if (shapes.carriesObjects(self.analyzer, value.value_type) and
            !(try self.yieldsOwnership(binary.right)))
        {
            try self.fail(
                "luce.sema.own",
                binary.span,
                "the two sides of catch must agree on ownership: the call hands over a fresh object, so the fallback must too [OWNERSHIP.md S1, S8]",
                .{},
            );
            return null;
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

    /// Pass one's entry to the root ledger, for the parameters it
    /// declares before the walk starts (`flow.zig`).
    pub fn setRoot(self: *FunctionBuilder, local: LocalId, state: RootState) void {
        flow.setRoot(self, local, state);
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
