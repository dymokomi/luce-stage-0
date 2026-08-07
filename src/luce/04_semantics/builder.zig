//! The checked walk of a function body — pass two of stage 4.
//!
//! Scope management, local declaration, ownership tracking, operand
//! ordering, statement and expression checking, call resolution, and
//! builtin typing.  Every decision this walk reaches is recorded on
//! stage 6's tape (`self.code`, a `mir.build.Lowering`) as it is
//! reached: checking and emitting are one visit because resolving
//! `xs.append(v)` needs the receiver's type and typing it needs the
//! name resolved first.  What is *not* here is how MIR is made — the
//! register numbering, the block bookkeeping, the local table, and the
//! assembly of a `mir.Program` all belong to `06_mir/build.zig`.
//!
//! **Why this is one file, and what would legitimately split it.**  A
//! file boundary in Zig is a privacy boundary, so a split is right only
//! where an API boundary is (docs/CODING_GUIDE.md).  What had one has
//! gone: the tables the language spells are `builtins.zig`, and the two
//! predicates that need no checker state are `effects.zig`.  Everything
//! left below is a method on this walker reaching this walker's scopes,
//! its tape, or both — carving it into siblings would mean publishing
//! `fail`, `fit`, `lowerExpression` and the rest for no reader but the
//! sibling, which is the split the guide names as the wrong one.  The
//! next honest cut is the check/lower seam, where the interface is a
//! *value* rather than a set of methods: `05_hir.zig`'s header lists
//! the six couplings that hold the two halves together here today, and
//! what each becomes on the far side.

const std = @import("std");
const source_mod = @import("../01_source.zig");
const ast = @import("../03_parse.zig").ast;
const types = @import("../support/types.zig");
const conversionNamed = types.conversionNamed;
const mir = @import("../06_mir.zig");
const helpers = @import("helpers.zig");

// What running a subtree could disturb, asked before it is lowered
// (`effects.zig`).
const effects = @import("effects.zig");

// What the language spells, and what each spelling lowers to
// (`builtins.zig`).  Named here under the names the walk below uses, so
// the tables read the same whether the reader came from the dispatch or
// from the editor grammar that is generated out of them.
const builtins_mod = @import("builtins.zig");
const Builtin = builtins_mod.Builtin;
const builtins = builtins_mod.builtins;
const retired_builtins = builtins_mod.retired_builtins;
const string_methods = builtins_mod.string_methods;
const list_methods = builtins_mod.list_methods;
const array_methods = builtins_mod.array_methods;
const map_methods = builtins_mod.map_methods;
const builder_methods = builtins_mod.builder_methods;
const file_methods = builtins_mod.file_methods;
const fresh_object_methods = builtins_mod.fresh_object_methods;

// Pass one, for the one thing this walk needs from it: the collected
// project it runs against.
const Analyzer = @import("declarations.zig").Analyzer;

// The stage's shared vocabulary (`04_semantics/context.zig`).
const context = @import("context.zig");
const Analyzed = context.Analyzed;
const ModuleTree = context.ModuleTree;
const FunctionDeclInfo = context.FunctionDeclInfo;
const ConstantValue = context.ConstantValue;
const OwnershipClass = context.OwnershipClass;
const Poison = context.Poison;
const LocalInfo = context.LocalInfo;
const Scope = context.Scope;
const FoundLocal = context.FoundLocal;
const LoopFrame = context.LoopFrame;
const isReserved = context.isReserved;
const Error = context.Error;

const Allocator = std.mem.Allocator;
const Span = source_mod.Span;
const Type = types.Type;
const StructLayout = types.StructLayout;
const Register = mir.Register;
const BlockId = mir.BlockId;
const LocalId = mir.LocalId;

// ---------------------------------------------------------------------------
// FunctionBuilder
// ---------------------------------------------------------------------------

/// A checked expression's result: the register holding it and the type
/// the checker decided it has.  A *typed register*, and not a value —
/// nothing here holds one; `runtime.Value` is the thing that does.
const Typed = struct {
    register: Register,
    value_type: Type,
};

/// The two places a call answering a return shape may stand, and the
/// one that is worth a longer sentence (docs/RETURNS.md).
const ShapePosition = enum { refused, bind, returning };

/// One slot of a callable surface, as name resolution sees it
/// (docs/ARGS.md): what the slot is called, whether a call site may
/// name it — a method receiver is not nameable (D7) — and whether it
/// carries a default (D2).  A user declaration and a builtin's table
/// row both flatten to this, which is what lets one resolver serve
/// every call path (D10).
const CallSlot = struct {
    name: []const u8,
    nameable: bool = true,
    defaulted: bool = false,
};

/// The slot argument `index` of `arguments` fills, with no reporting
/// (docs/ARGS.md D4, D5): positional arguments fill slots left to
/// right, a name fills the slot that spells it, and a receiver slot
/// is never filled by name.  `hidden` is how many leading slots the
/// call site does not write — 1 in the method form, whose receiver
/// stands in front of the dot; 0 otherwise.  The answer indexes the
/// declared list, `hidden` included.  Null where the call is
/// malformed; `resolveSlots` is the half that says how.
///
/// Two callers, one rule: `landsOn` asks it mid-batch so a literal
/// lands at the type of the slot it will fill, and `resolveSlots` asks
/// it while checking — one implementation, so the two can never
/// disagree about which slot that is.
fn argumentSlot(
    slots: []const CallSlot,
    hidden: usize,
    arguments: []const ast.Argument,
    index: usize,
) ?usize {
    const argument = arguments[index];
    if (argument.name) |written| {
        for (slots[hidden..], hidden..) |candidate, slot| {
            if (!candidate.nameable) continue;
            if (std.mem.eql(u8, candidate.name, written)) return slot;
        }
        return null;
    }
    var positional: usize = 0;
    for (arguments[0..index]) |earlier| {
        if (earlier.name == null) positional += 1;
    }
    const slot = hidden + positional;
    return if (slot < slots.len) slot else null;
}

/// How many of a surface's slots carry a default — the second number
/// in the count sentence, and the suffix a call may omit
/// (docs/ARGS.md D3).
fn defaultCount(slots: []const CallSlot) usize {
    var count: usize = 0;
    for (slots) |slot| {
        if (slot.defaulted) count += 1;
    }
    return count;
}

pub const FunctionBuilder = struct {
    analyzer: *Analyzer,
    module: usize,
    prefix: []const u8,
    /// Stage 6's tape.  Every decision this walk reaches is recorded
    /// on it in the order it is reached; the only things ever read
    /// back are a register's type and a local's type.
    code: mir.build.Lowering,
    /// What this function answers, in order — the arity a `return`
    /// is checked against.  `code.return_type` is the one value the
    /// channel carries, which for two or more is the synthesized
    /// layout they ride in (docs/RETURNS.md).
    results: []const Type = &.{},
    /// What actually leaves: `[self] ++ results` in a `var self`
    /// method, `results` in everything else.
    channel: []const Type = &.{},
    /// True in a `var self` method, where every `return` carries the
    /// receiver out in front of whatever the reader wrote — its
    /// receiver *is* result zero (docs/RETURNS.md §5).
    writes_receiver: bool = false,
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
    /// Set for exactly one hop.  `try` and `catch` raise it, and the
    /// very next `lowerExpressionInner` reads and clears it, so the
    /// permission reaches the call they are written in front of and
    /// nothing nested inside it (docs/FAILURE.md).
    allow_fallible: bool = false,
    /// Where a multi-valued call currently stands.
    ///
    /// A call that answers a return shape may stand in exactly two
    /// places — the right of a destructuring bind, and a statement of
    /// its own — and nowhere else (docs/RETURNS.md).  Statement
    /// position is `as_statement`, which this walk already carries;
    /// this is the other one.
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
    /// The element type the next list literal should be built at, when
    /// the place it is going into names one — `let xs: list(double) =
    /// [1, 2, 3]` (docs/NUMERICS.md).  A literal has no annotation of
    /// its own, so without this the elements infer `long` and the whole
    /// list refuses to fit a `list(double)` it could have been.
    ///
    /// Set for exactly one hop, the way `allow_fallible` is:
    /// `lowerExpressionInner` reads and clears it, so it reaches the
    /// literal it was raised in front of and nothing nested inside it.
    /// Inference where nothing is expected is untouched — `let xs =
    /// [1, 2, 3]` is still a `list(long)`.
    wanted_element: ?Type = null,
    /// The scalar type the next expression lands on, when the place it
    /// is going into names one — `let x: double = 7` (docs/TYPES.md §1,
    /// D3).  **A numeric literal has no type of its own**; it takes the
    /// type of its context if it fits, and this is how the context
    /// reaches it.
    ///
    /// Set for exactly one hop, the way `wanted_element` is:
    /// `lowerExpressionInner` reads and clears it, so it reaches the
    /// literal it was raised in front of and nothing nested inside it
    /// that has a landing width of its own.  Inference where nothing is
    /// expected is untouched — `let n = 1` still takes the default.
    wanted: ?Type = null,
    /// What a fallible call left for the `try` or `catch` in front of
    /// it to finish.  Set by `openFallible` and consumed once.
    opened: ?Opened = null,
    /// Registers that are a *reload* of another register across a
    /// fallible call's branch.  The value is the same value — the slot
    /// only carries it from one block to the next — so every question
    /// asked about where a value came from has to look through the
    /// link, or a call's fresh string would be nobody's to free.
    carried: std.ArrayList(Carried) = .empty,

    /// A fallible call whose failing side is still an empty block.
    const Opened = struct {
        /// Where control goes when the call raised.
        handler: BlockId,
        /// How many statement temporaries existed when the branch was
        /// taken.  Anything parked after it belongs to the side where
        /// the call *returned*, and releasing it on the failing side
        /// would release a slot nothing ever stored into.
        temps_floor: usize,
    };

    const Carried = struct { register: Register, origin: Register };

    const TempSlot = struct {
        local: LocalId,
        register: Register,
        /// Whether this temporary owns the objects in its value, its
        /// storage, or both — the same two questions `context.Release`
        /// answers for a named binding.
        objects: bool,
        storage: bool,
        /// Whether the park may be retracted so a store can take the
        /// storage instead of copying it (`takeStorage`).  True of
        /// every parked temporary, whose slot is written and never
        /// read; false of the slot a fallible call's result crosses
        /// its branch in, which is reloaded (docs/STRINGS.md).
        disownable: bool = true,
        /// Whether a store already took this storage.  One value has
        /// one owner, so the second store of the same register — if a
        /// shape that does that ever exists — copies.
        taken: bool = false,
    };

    fn arena(self: *FunctionBuilder) Allocator {
        return self.analyzer.arena;
    }

    fn temporary(self: *FunctionBuilder) Allocator {
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
        self.carried.deinit(self.temporary());
    }

    // Narrowing ------------------------------------------------------------
    //
    // The whole of the flow analysis: a set of locals proved present,
    // what a condition adds to it, what an assignment or a loop takes
    // out, and the join two branches meet at.

    fn isNarrowed(self: *const FunctionBuilder, local: LocalId) bool {
        return std.mem.indexOfScalar(LocalId, self.narrowed.items, local) != null;
    }

    /// `local` is known to hold a value from here on.
    fn narrow(self: *FunctionBuilder, local: LocalId) Error!void {
        if (self.isNarrowed(local)) return;
        try self.narrowed.append(self.temporary(), local);
    }

    /// `local` might be absent again: it was assigned, or a loop body
    /// assigns it and the back edge re-enters with whatever that left.
    fn widen(self: *FunctionBuilder, local: LocalId) void {
        const at = std.mem.indexOfScalar(LocalId, self.narrowed.items, local) orelse return;
        _ = self.narrowed.swapRemove(at);
    }

    /// A copy of the current set, for a branch to rejoin against.  The
    /// caller frees it.
    fn narrowSave(self: *FunctionBuilder) Error![]LocalId {
        return self.temporary().dupe(LocalId, self.narrowed.items);
    }

    fn narrowRestore(self: *FunctionBuilder, saved: []const LocalId) Error!void {
        self.narrowed.clearRetainingCapacity();
        try self.narrowed.appendSlice(self.temporary(), saved);
    }

    /// Keep only what both arms of a conditional agree on.  A local
    /// narrowed on one path and assigned away on the other is absent
    /// again after the join, which is the whole reason this is a join
    /// and not a union.
    fn narrowIntersect(self: *FunctionBuilder, other: []const LocalId) void {
        var index = self.narrowed.items.len;
        while (index > 0) {
            index -= 1;
            if (std.mem.indexOfScalar(LocalId, other, self.narrowed.items[index]) == null) {
                _ = self.narrowed.swapRemove(index);
            }
        }
    }

    /// What `condition` proves about absence when it evaluates to
    /// `want`: `x != none` proves `x` present when true, `x == none`
    /// proves it present when false, `and` passes both facts through on
    /// the true side, `or` on the false side, and `not` swaps.
    /// Anything else proves nothing, which is always safe.
    fn applyFacts(self: *FunctionBuilder, condition: *const ast.Expression, want: bool, budget: u32) Error!void {
        if (budget == 0) return;
        switch (condition.*) {
            .unary => |unary| if (unary.op == .logic_not) {
                try self.applyFacts(unary.operand, !want, budget - 1);
            },
            .binary => |binary| switch (binary.op) {
                .equal, .not_equal => {
                    // `x != none` when true, `x == none` when false.
                    if (want != (binary.op == .not_equal)) return;
                    const tested = if (binary.right.* == .none_literal)
                        binary.left
                    else if (binary.left.* == .none_literal)
                        binary.right
                    else
                        return;
                    if (tested.* != .name) return;
                    const found = self.findLocal(tested.name.text) orelse return;
                    if (self.code.localType(found.info.local) != .optional) return;
                    try self.narrow(found.info.local);
                },
                .logic_and => if (want) {
                    try self.applyFacts(binary.left, true, budget - 1);
                    try self.applyFacts(binary.right, true, budget - 1);
                },
                .logic_or => if (!want) {
                    try self.applyFacts(binary.left, false, budget - 1);
                    try self.applyFacts(binary.right, false, budget - 1);
                },
                else => {},
            },
            else => {},
        }
    }

    /// Forget what a loop body could undo.  The body runs before the
    /// back edge re-enters it, so a narrowing established outside the
    /// loop is only good inside it if nothing in the loop assigns the
    /// name — and a narrowing established *by* the body has to survive
    /// its own last statement to be worth anything, which it does not.
    fn widenAssignedIn(self: *FunctionBuilder, block: ast.Block) void {
        for (block.statements) |statement| {
            switch (statement) {
                .assign => |assign| switch (assign.target) {
                    .name => |name| if (self.findLocal(name.text)) |found| self.widen(found.info.local),
                    .field, .index, .chain => {},
                },
                .conditional => |conditional| {
                    self.widenAssignedIn(conditional.then_block);
                    if (conditional.else_block) |arm| self.widenAssignedIn(arm);
                },
                .while_loop => |loop| self.widenAssignedIn(loop.body),
                .for_range => |loop| self.widenAssignedIn(loop.body),
                .for_each => |loop| self.widenAssignedIn(loop.body),
                .match => |matched| {
                    for (matched.arms) |arm| self.widenAssignedIn(arm.body);
                    if (matched.else_block) |arm| self.widenAssignedIn(arm);
                },
                else => {},
            }
        }
    }

    fn fail(self: *FunctionBuilder, code: []const u8, span: Span, comptime format: []const u8, arguments: anytype) Error!void {
        try self.analyzer.fail(code, span, format, arguments);
    }

    // Scopes and locals ----------------------------------------------------

    pub fn pushScope(self: *FunctionBuilder) Error!void {
        try self.scopes.append(self.temporary(), .{});
    }

    pub fn popScope(self: *FunctionBuilder) void {
        var scope = self.scopes.pop().?;
        scope.names.deinit(self.temporary());
        scope.owned.deinit(self.temporary());
    }

    fn findLocal(self: *FunctionBuilder, name: []const u8) ?FoundLocal {
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
    fn rememberOwnerName(self: *FunctionBuilder, alias: []const u8, source: []const u8) void {
        const from = self.findLocal(source) orelse return;
        const root = from.info.owner_name orelse source;
        const declared = self.findLocal(alias) orelse return;
        declared.info.owner_name = root;
    }

    /// The owner to name in a refusal, or null when there is none worth
    /// naming.  A recorded name is only useful advice while it is still
    /// the owner: one that has since been given away or freed would
    /// send the reader to a second diagnostic, so it is withheld and
    /// the refusal falls back to saying that an owner exists.
    fn ownerNameFor(self: *FunctionBuilder, info: *const LocalInfo) ?[]const u8 {
        const owner = info.owner_name orelse return null;
        const found = self.findLocal(owner) orelse return null;
        if (found.info.class != .owned) return null;
        if (found.info.poisoned != null) return null;
        return owner;
    }

    // Unknown names --------------------------------------------------------
    //
    // "unknown name totl" is a true statement; "did you mean total?"
    // is the answer.  rustc's resolver offers the closest name in
    // scope and it is most of what makes its name errors feel
    // helpful, so this stage does the same at every place a written
    // name finds nothing.

    /// The name a declaration key is written as inside this module, or
    /// null when it belongs to a module this one cannot see unqualified.
    fn visibleName(self: *const FunctionBuilder, key: []const u8) ?[]const u8 {
        if (self.prefix.len == 0) return key;
        if (key.len <= self.prefix.len + 1) return null;
        if (!std.mem.startsWith(u8, key, self.prefix)) return null;
        if (key[self.prefix.len] != '.') return null;
        return key[self.prefix.len + 1 ..];
    }

    /// The declaration-level gate at every site a call resolves
    /// (docs/VISIBILITY.md §1): a private function, or any member of a
    /// private struct, is reachable from its own file and nowhere
    /// else.  True when the call may proceed.  The refusal names the
    /// withheld declaration and its module — private is never
    /// "unknown" (D2), and it fires *after* existence is established,
    /// which is what the code buys.
    fn functionReachable(self: *FunctionBuilder, function_index: u32, span: Span) Error!bool {
        const info = self.analyzer.functions.items[function_index];
        if (info.module == self.module) return true;
        // A namespace function of a private struct — or of a private
        // enum — is reached through that name, and it is the name that
        // is withheld.
        if (info.enclosing) |owner| {
            const declaration = switch (owner) {
                .strukt => |index| self.analyzer.struct_decls.items[index].declaration.visibility,
                .enumeration => |reference| self.analyzer.enum_decls.items[reference.index].declaration.visibility,
            };
            if (declaration == .private) {
                try self.fail("luce.sema.private", span, "{s} is private to {s}", .{
                    switch (owner) {
                        .strukt => |index| self.analyzer.struct_decls.items[index].declaration.name,
                        .enumeration => |reference| self.analyzer.enum_decls.items[reference.index].declaration.name,
                    },
                    self.analyzer.moduleName(info.module),
                });
                return false;
            }
        }
        if (info.declaration.visibility == .private) {
            try self.fail("luce.sema.private", span, "{s} is private to {s}", .{
                info.declaration.name,
                self.analyzer.moduleName(info.module),
            });
            return false;
        }
        return true;
    }

    /// The field-level gate at every site a field is read, written, or
    /// named (docs/VISIBILITY.md §1, §3).  Within the declaring module
    /// the bit is never consulted.
    fn fieldReachable(
        self: *FunctionBuilder,
        layout_index: u32,
        field_index: u32,
        span: Span,
    ) Error!bool {
        const info = self.analyzer.struct_decls.items[layout_index];
        if (info.module == self.module) return true;
        if (field_index >= info.field_visibility.len) return true;
        if (info.field_visibility[field_index] != .private) return true;
        try self.fail("luce.sema.private", span, "{s} of {s} is private to {s}", .{
            self.analyzer.structs.items[layout_index].fields[field_index].name,
            info.declaration.name,
            self.analyzer.moduleName(info.module),
        });
        return false;
    }

    fn offerDeclarations(self: *FunctionBuilder, suggestion: *helpers.Suggestion) void {
        var functions = self.analyzer.function_names.iterator();
        while (functions.next()) |entry| {
            const info = self.analyzer.functions.items[entry.value_ptr.*];
            if (info.declaration.visibility == .private and info.module != self.module) continue;
            if (self.visibleName(entry.key_ptr.*)) |name| suggestion.offer(name);
        }
        var structs = self.analyzer.struct_names.iterator();
        while (structs.next()) |entry| {
            const info = self.analyzer.struct_decls.items[entry.value_ptr.*];
            if (info.declaration.visibility == .private and info.module != self.module) continue;
            if (self.visibleName(entry.key_ptr.*)) |name| suggestion.offer(name);
        }
        var constants = self.analyzer.constant_names.iterator();
        while (constants.next()) |entry| {
            const info = self.analyzer.constant_infos.items[entry.value_ptr.*];
            if (info.declaration.visibility == .private and info.module != self.module) continue;
            if (self.visibleName(entry.key_ptr.*)) |name| suggestion.offer(name);
        }
    }

    fn offerLocals(self: *FunctionBuilder, suggestion: *helpers.Suggestion) void {
        var index = self.scopes.items.len;
        while (index > 0) {
            index -= 1;
            var names = self.scopes.items[index].names.keyIterator();
            while (names.next()) |key| suggestion.offer(key.*);
        }
    }

    /// Report a bare name that resolved to nothing — unless it is a
    /// name whose own declaration already failed, in which case the
    /// error the reader needs is already reported and this one is
    /// only noise.
    fn failUnknownName(self: *FunctionBuilder, name: []const u8, span: Span) Error!void {
        if (self.undeclared.contains(name)) return;
        const qualified = try self.analyzer.qualify(self.prefix, name);
        if (try self.failNotAValue(name, qualified, span)) return;
        var suggestion = helpers.Suggestion.init(name);
        self.offerLocals(&suggestion);
        self.offerDeclarations(&suggestion);
        if (suggestion.best()) |closest| {
            try self.fail("luce.sema.name", span, "unknown name {s}; did you mean {s}?", .{ name, closest });
            return;
        }
        try self.fail("luce.sema.name", span, "unknown name {s}", .{name});
    }

    /// A name in value position that names a declaration rather than a
    /// value.  Luce has no function values, so `let f = helper` and
    /// `let x = math.seed` are mistakes — but they are not *unknown
    /// names*, and saying so denies a declaration the compiler has
    /// already checked.  Answers what the name is and how to use it;
    /// true when it reported.
    fn failNotAValue(
        self: *FunctionBuilder,
        written: []const u8,
        qualified: []const u8,
        span: Span,
    ) Error!bool {
        if (self.analyzer.function_names.contains(qualified)) {
            try self.fail(
                "luce.sema.name",
                span,
                "{s} is a function, and Luce has no function values; write {s}(...) to call it",
                .{ written, written },
            );
            return true;
        }
        if (self.analyzer.struct_names.contains(qualified)) {
            try self.fail(
                "luce.sema.name",
                span,
                "{s} is a struct, not a value; write {s}(field = ...) to build one",
                .{ written, written },
            );
            return true;
        }
        return false;
    }

    /// `math.seed`, `Words.classify` — a namespace member reached
    /// without a call.  The namespace is real and its members are in
    /// hand, so the answer names what the member is, or offers the
    /// closest member there actually is.
    ///
    /// `namespace` and `member` are spelled the way the author wrote
    /// them; `joined` is the fully-qualified key those two resolve to,
    /// which is what the declaration tables are keyed on.
    fn failNamespaceMember(
        self: *FunctionBuilder,
        namespace: []const u8,
        member: []const u8,
        joined: []const u8,
        span: Span,
    ) Error!void {
        const written = try std.fmt.allocPrint(self.arena(), "{s}.{s}", .{ namespace, member });
        if (try self.failNotAValue(written, joined, span)) return;

        // Members of this namespace only: `math.sed` wants `seed`
        // offered, never a same-named function of another module — and
        // never a name the namespace withheld (VISIBILITY.md D2:
        // did-you-mean offers visible names only).
        const scope = joined[0 .. joined.len - member.len];
        var suggestion = helpers.Suggestion.init(member);
        {
            var entries = self.analyzer.function_names.iterator();
            while (entries.next()) |entry| {
                const tail = namespaceTail(scope, entry.key_ptr.*) orelse continue;
                const info = self.analyzer.functions.items[entry.value_ptr.*];
                if (info.declaration.visibility == .private and info.module != self.module) continue;
                suggestion.offer(tail);
            }
        }
        {
            var entries = self.analyzer.struct_names.iterator();
            while (entries.next()) |entry| {
                const tail = namespaceTail(scope, entry.key_ptr.*) orelse continue;
                const info = self.analyzer.struct_decls.items[entry.value_ptr.*];
                if (info.declaration.visibility == .private and info.module != self.module) continue;
                suggestion.offer(tail);
            }
        }
        {
            var entries = self.analyzer.constant_names.iterator();
            while (entries.next()) |entry| {
                const tail = namespaceTail(scope, entry.key_ptr.*) orelse continue;
                const info = self.analyzer.constant_infos.items[entry.value_ptr.*];
                if (info.declaration.visibility == .private and info.module != self.module) continue;
                suggestion.offer(tail);
            }
        }
        if (suggestion.best()) |closest| {
            try self.fail(
                "luce.sema.name",
                span,
                "{s} has no member {s}; did you mean {s}.{s}?",
                .{ namespace, member, namespace, closest },
            );
            return;
        }
        try self.fail("luce.sema.name", span, "{s} has no member {s}", .{ namespace, member });
    }

    /// The immediate member `key` names inside `scope` ("geo."), or
    /// null when the key lives elsewhere or deeper.
    fn namespaceTail(scope: []const u8, key: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, key, scope)) return null;
        const tail = key[scope.len..];
        if (tail.len == 0 or std.mem.indexOfScalar(u8, tail, '.') != null) return null;
        return tail;
    }

    /// Remember that `name`'s declaration was abandoned, so its later
    /// uses stay quiet.
    fn forgetName(self: *FunctionBuilder, name: []const u8) Error!void {
        try self.undeclared.put(self.temporary(), name, {});
    }

    /// Report a call whose callee names no declaration, offering the
    /// closest function or struct the reader could have meant.
    fn failUnknownFunction(self: *FunctionBuilder, written: []const u8, span: Span) Error!void {
        // A name the language used to spell is not a typo, and the
        // reader is owed the replacement rather than a guess at what
        // they might have meant.  Reached only once nothing else
        // resolved, because `arg` is an ordinary word now and a program
        // that declares one gets its own.
        for (retired_builtins) |gone| {
            if (!std.mem.eql(u8, written, gone.name)) continue;
            try self.fail("luce.sema.retired", span, "{s} was retired: {s}", .{ gone.name, gone.instead });
            return;
        }
        // A conversion named for the type it produces is spelled the
        // way that type is, and the types are lowercase now
        // (docs/TYPES.md D8): `Int(x)` is `long(x)`.
        if (types.retiredSpelling(written)) |now| {
            try self.fail(
                "luce.sema.call",
                span,
                "the builtin types are lowercase: {s} is written {s}",
                .{ written, now },
            );
            return;
        }
        var suggestion = helpers.Suggestion.init(written);
        var functions = self.analyzer.function_names.iterator();
        while (functions.next()) |entry| {
            const info = self.analyzer.functions.items[entry.value_ptr.*];
            if (info.declaration.visibility == .private and info.module != self.module) continue;
            if (self.visibleName(entry.key_ptr.*)) |name| suggestion.offer(name);
        }
        var structs = self.analyzer.struct_names.iterator();
        while (structs.next()) |entry| {
            const info = self.analyzer.struct_decls.items[entry.value_ptr.*];
            if (info.declaration.visibility == .private and info.module != self.module) continue;
            if (self.visibleName(entry.key_ptr.*)) |name| suggestion.offer(name);
        }
        if (suggestion.best()) |closest| {
            try self.fail("luce.sema.call", span, "unknown function {s}; did you mean {s}?", .{ written, closest });
            return;
        }
        try self.fail("luce.sema.call", span, "unknown function {s}", .{written});
    }

    /// Report a field a struct does not have, offering the closest one
    /// it does.  A struct's fields are right there in the layout, so
    /// there is never an excuse for this message not to help — and a
    /// field withheld from this module is never offered (VISIBILITY.md
    /// D2: did-you-mean offers visible names only).
    fn failUnknownField(
        self: *FunctionBuilder,
        code: []const u8,
        layout_index: u32,
        field: []const u8,
        span: Span,
    ) Error!void {
        const layout = self.analyzer.structs.items[layout_index];
        const info = self.analyzer.struct_decls.items[layout_index];
        var suggestion = helpers.Suggestion.init(field);
        for (layout.fields, 0..) |candidate, index| {
            if (info.module != self.module and
                index < info.field_visibility.len and
                info.field_visibility[index] == .private) continue;
            suggestion.offer(candidate.name);
        }
        if (suggestion.best()) |closest| {
            try self.fail(code, span, "{s} has no field {s}; did you mean {s}?", .{ layout.name, field, closest });
            return;
        }
        try self.fail(code, span, "{s} has no field {s}", .{ layout.name, field });
    }

    // Ownership releases -------------------------------------------------

    /// Emit releases for the owned locals of every scope at or above
    /// `from`, innermost first.  `moved` is a returned binding: its
    /// *object* moves to the caller (S16), but its storage does not —
    /// the return took a copy — so the slot still gives its bytes back
    /// (docs/STRINGS.md).
    fn emitScopeReleases(self: *FunctionBuilder, from: usize, moved: []const LocalId) Error!void {
        var scope_index = self.scopes.items.len;
        while (scope_index > from) {
            scope_index -= 1;
            const owned = self.scopes.items[scope_index].owned.items;
            var owned_index = owned.len;
            while (owned_index > 0) {
                owned_index -= 1;
                const release = owned[owned_index];
                const keeps_objects = std.mem.indexOfScalar(LocalId, moved, release.local) != null;
                try self.code.release(
                    release.local,
                    release.objects and !keeps_objects,
                    release.storage,
                );
            }
        }
    }

    /// Emit releases for the innermost scope, in reverse declaration
    /// order, without popping it: the normal end of a block.
    pub fn emitScopeEnd(self: *FunctionBuilder) Error!void {
        try self.emitScopeReleases(self.scopes.items.len - 1, &.{});
    }

    /// Park a fresh value in a hidden local so the end of the statement
    /// can release it if nothing adopted it (S3, S19): the object it
    /// carries when `objects` is set, its freshly allocated storage
    /// when `storage` is (docs/STRINGS.md).
    fn registerTemp(
        self: *FunctionBuilder,
        value: Typed,
        objects: bool,
        storage: bool,
    ) Error!void {
        const local = try self.code.park(value.register, value.value_type, objects, storage);
        try self.temps.append(self.temporary(), .{
            .local = local,
            .register = value.register,
            .objects = objects,
            .storage = storage,
        });
    }

    /// Is this exact register already parked?
    ///
    /// **One value, one park.**  A `try` hands back what the call it
    /// wraps produced, so the walk sees the same register twice — once
    /// for the call and once for the `try` around it — and two hidden
    /// locals both claiming one string's bytes free them twice.  The
    /// question is asked of the register rather than of the
    /// expression, which is why `a else b` is untouched: its three
    /// registers are three different values.
    fn parkedAlready(self: *const FunctionBuilder, register: Register) bool {
        for (self.temps.items) |temp| {
            if (temp.register == register) return true;
        }
        return false;
    }

    /// Emit releases for the temporaries above `from` without
    /// forgetting them (unwinding paths: return, break, continue).
    fn emitTempReleases(self: *FunctionBuilder, from: usize) Error!void {
        try self.emitTempReleasesUpTo(from, self.temps.items.len);
    }

    /// The same, stopping below `limit`.  A `try`'s failing side takes
    /// this form: the temporaries parked *after* the call was made
    /// live on the side where it returned, and their slots were never
    /// stored into on the side where it did not.
    fn emitTempReleasesUpTo(self: *FunctionBuilder, from: usize, limit: usize) Error!void {
        var index = @min(self.temps.items.len, limit);
        while (index > from) {
            index -= 1;
            const temp = self.temps.items[index];
            try self.code.release(temp.local, temp.objects, temp.storage);
        }
    }

    /// Release and forget the temporaries above `from`: the end of the
    /// statement (or of a condition) that created them.
    fn flushTemps(self: *FunctionBuilder, from: usize) Error!void {
        try self.emitTempReleases(from);
        self.temps.shrinkRetainingCapacity(from);
    }

    /// Resolve a written declaration name from this module's point of
    /// view: bare names are module-local; a dotted name is either a
    /// module-local struct namespace (Text.width) or an imported one
    /// (geo.helper, geo.Text.width).
    fn resolveDeclared(
        self: *FunctionBuilder,
        written: []const u8,
        span: Span,
        origin: ast.CallOrigin,
    ) Error!?[]const u8 {
        if (std.mem.indexOfScalar(u8, written, '.')) |dot| {
            const head = written[0..dot];
            const local_head = try self.analyzer.qualify(self.prefix, head);
            if (self.analyzer.struct_names.contains(local_head)) {
                return try self.analyzer.qualify(self.prefix, written);
            }
            if (self.analyzer.importsModule(self.module, head)) {
                return written;
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
                    .{ head, try self.analyzer.importSpelling(head) },
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
        return try self.analyzer.qualify(self.prefix, written);
    }

    /// Does this binding own the storage in its slot?  Every real
    /// binding does — `let b = a` copies a's string fields even while
    /// it aliases a's objects (S26) — and a parameter never does: its
    /// bytes belong to the caller's binding, which outlives the call
    /// (docs/STRINGS.md).
    pub const StorageClass = enum { owns, borrows };

    fn declareLocal(
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
                try self.analyzer.declaredAt(self.analyzer.modules[self.module].file, found.info.declared_at),
            });
            return null;
        }
        const qualified = try self.analyzer.qualify(self.prefix, name);
        if (try self.analyzer.firstDeclarationOf(qualified)) |where| {
            try self.fail("luce.sema.duplicate", span, "{s} is already a top-level declaration{s}", .{ name, where });
            return null;
        }
        const carries = self.analyzer.carriesObjects(local_type);
        const owns_storage = storage_class == .owns and self.analyzer.ownsStorage(local_type);
        const local = try self.code.addLocal(name, local_type, owns_storage);
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

    // Value storage --------------------------------------------------------
    //
    // A string's bytes and a struct's field run have exactly one owner
    // (docs/STRINGS.md).  Stage 4 says where that owner is: a fresh
    // allocation is parked in a statement temporary the moment it is
    // made, and every store into a place that outlives the statement
    // takes a copy — except the one case where it provably need not,
    // a value this statement made and nothing has claimed yet.

    /// True when `register` holds storage this statement just
    /// allocated and nobody owns yet.  Asked of the *instruction*
    /// rather than of the expression that produced it: the set of
    /// producers is closed and small, and reading it off the tape
    /// cannot drift from what was actually emitted.
    fn producesFreshStorage(self: *const FunctionBuilder, register: Register) bool {
        return switch (self.code.instructions.items[self.sourceOf(register)]) {
            // string `+`; every other binary answers a scalar.
            .binary => true,
            // Both build a whole new struct value that owns its run.
            .struct_make, .struct_set => true,
            // A function's result is the caller's (S16), and `ret`
            // hands out a copy rather than a view of the callee's
            // frame.
            .call => true,
            .intrinsic => |call| call.kind.makesFreshStorage(),
            else => false,
        };
    }

    /// The register that actually produced this value.  A fallible
    /// call's result crosses its own branch through a hidden slot, so
    /// the register a `try` hands back is a `local_get` of a value the
    /// *call* made — and "did this statement allocate it" has to be
    /// asked of the call.  One hop is all there ever is: the slot is
    /// written once, right where the call stands.
    fn sourceOf(self: *const FunctionBuilder, register: Register) Register {
        for (self.carried.items) |link| {
            if (link.register == register) return link.origin;
        }
        return register;
    }

    /// Is this register's storage parked in a statement temporary?
    fn parkedForStorage(self: *const FunctionBuilder, register: Register) bool {
        for (self.temps.items) |temp| {
            if (temp.register == register and temp.storage) return true;
        }
        return false;
    }

    /// Take `register`'s storage for a place that outlives the
    /// statement, if it can be taken — otherwise say so and let the
    /// place copy.
    ///
    /// It can be taken when this statement allocated it and nothing
    /// else will give it back.  A parked temporary *is* something
    /// else, so the park is retracted here: its slot stops owning
    /// storage, the statement's release goes with it, and the place
    /// becomes the one owner.  That is the whole of move-instead-of-
    /// copy, and it is why this is not a question — asking it hands
    /// the storage over (docs/STRINGS.md).
    ///
    /// Two parks are kept rather than retracted.  A slot that is read
    /// back cannot stop owning storage, because a borrowing slot hands
    /// a reload the register shape and a string's form does not
    /// survive that — which is exactly the slot a fallible call's
    /// result crosses its branch in.  And a temporary that also owns
    /// *objects* keeps its slot, because that ownership is settled at
    /// run time by `object_bind` and the release still has to load the
    /// slot to ask.
    fn takeStorage(self: *FunctionBuilder, register: Register) bool {
        if (!self.producesFreshStorage(register)) return false;
        for (self.temps.items) |*temp| {
            if (temp.register != register) continue;
            if (temp.taken) return false;
            if (!temp.storage) continue;
            if (!temp.disownable or temp.objects) return false;
            self.code.disownStorage(temp.local);
            // Emptied rather than forgotten: the record is what keeps
            // one value from being parked twice, and every index into
            // this list is a floor some other unwinding path recorded.
            // A temporary that owns neither releases nothing.
            temp.storage = false;
            temp.taken = true;
            return true;
        }
        return true;
    }

    /// The register a store site is handed: this one when its storage
    /// can move into the place, a copy of it otherwise.
    ///
    /// **Every store goes through here** — a binding, a reassignment, a
    /// list element, a map value, a struct field, a return — because
    /// `libluce_rt` never copies at a store: the copy is written once,
    /// here, where the decision that elides it can be seen
    /// (docs/STRINGS.md).
    fn ownedForStore(self: *FunctionBuilder, value: Typed) Error!Register {
        if (!self.analyzer.ownsStorage(value.value_type)) return value.register;
        if (self.takeStorage(value.register)) return value.register;
        return self.code.ownStorage(value.register);
    }

    /// Whether a value of this type can be text in its own right —
    /// the one payload whose storage might be inside the value rather
    /// than an allocation of its own, and so the one that cannot
    /// simply be handed out of the frame that made it.
    fn carriesText(of: Type) bool {
        return switch (of) {
            .string => true,
            .optional => |payload| carriesText(payload.asType()),
            else => false,
        };
    }

    /// Store into a local, taking or copying the value's storage in
    /// when the local is the one that will have to give it back.
    fn storeOwned(self: *FunctionBuilder, local: LocalId, value: Typed) Error!void {
        const register = if (self.code.localOwnsStorage(local))
            try self.ownedForStore(value)
        else
            value.register;
        try self.code.store(local, register);
    }

    /// True when `register` holds a view of storage a container or a
    /// struct is holding, rather than storage of its own.  Those are
    /// the reads the hazard rule above has to protect; a local, a
    /// parameter, a constant and a fresh value are all safe, the
    /// first three because nothing in one statement can free them and
    /// the last because it has no other owner.
    fn borrowsStoredValue(self: *const FunctionBuilder, register: Register) bool {
        return switch (self.code.instructions.items[register]) {
            .struct_get => true,
            .intrinsic => |call| switch (call.kind) {
                .index_get, .map_get, .key_at, .value_at => true,
                else => false,
            },
            else => false,
        };
    }

    /// Park a freshly allocated string or struct value that was not
    /// produced through `lowerExpression` — a compound assignment's
    /// concatenation, say — so the statement's end reclaims it.
    fn parkFreshStorage(self: *FunctionBuilder, value: Typed) Error!void {
        if (!self.analyzer.ownsStorage(value.value_type)) return;
        if (!self.producesFreshStorage(value.register)) return;
        if (self.parkedForStorage(value.register)) return;
        try self.registerTemp(value, false, true);
    }

    /// How deep `splitsBlocks` will look before answering yes on
    /// principle.  It runs on whole operand subtrees *before* they are
    /// lowered, so the depth bound `lowerExpression` keeps cannot
    /// protect it — it needs its own, and it has the luxury of a safe
    /// wrong answer: "this may split" only ever costs a spill.  The
    /// margin over the lowering bound keeps an accepted program from
    /// ever paying for it.
    const split_search_depth: u32 = helpers.max_expression_depth + 8;

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
    fn namesMember(self: *FunctionBuilder, parts: []const []const u8) bool {
        var written: std.ArrayList(u8) = .empty;
        defer written.deinit(self.temporary());
        var at = parts.len;
        while (at > 1) {
            at -= 1;
            written.appendSlice(self.temporary(), parts[at]) catch return false;
            if (at > 1) written.append(self.temporary(), '.') catch return false;
        }
        const spelled = written.items;
        const index = found: {
            if (parts.len == 2) {
                const local = self.analyzer.qualify(self.prefix, spelled) catch return false;
                break :found self.analyzer.enum_names.get(local) orelse return false;
            }
            break :found self.analyzer.enum_names.get(spelled) orelse return false;
        };
        return self.analyzer.enums.items[index].findMember(parts[0]) != null;
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
    fn yieldsOwnership(self: *FunctionBuilder, expression: *const ast.Expression) Error!bool {
        return switch (expression.*) {
            .new_object, .list_literal, .slice_range, .call, .give, .copy => true,
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
            else => false,
        };
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
        return self.analyzer.carriesObjects(self.analyzer.functions.items[index].return_type);
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
            if (self.analyzer.carriesObjects(candidate.return_type)) return true;
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
        const head_qualified = try self.analyzer.qualify(self.prefix, head);
        if (self.analyzer.struct_names.contains(head_qualified)) return true;
        return self.analyzer.importsModule(self.module, head);
    }

    /// Report a destination that keeps what it is handed but was
    /// handed a bare name (S21).  `subject` says what the destination
    /// is; `situations` are the OWNERSHIP.md numbers to quote.
    ///
    /// The advice depends on the name.  "give NAME, or copy NAME" is
    /// right for an owned binding and *wrong* for a borrowed
    /// parameter, which can never be given at all (S12) — pointing a
    /// reader at `give` there only earns them a second error one
    /// keystroke later, which is exactly the loop good diagnostics
    /// exist to break.
    fn failNeedsOwnership(
        self: *FunctionBuilder,
        span: Span,
        subject: []const u8,
        value: *const ast.Expression,
        situations: []const u8,
    ) Error!void {
        if (value.* == .name) {
            if (self.findLocal(value.name.text)) |found| {
                const name = value.name.text;
                if (found.info.class == .borrow_param) {
                    try self.fail(
                        "luce.sema.own",
                        span,
                        "{s}; {s} is a borrowed parameter and can never be given away — store copy {s}, or take {s} as give in the signature [OWNERSHIP.md S12, {s}]",
                        .{ subject, name, name, name, situations },
                    );
                    return;
                }
                try self.fail(
                    "luce.sema.own",
                    span,
                    "{s}; write give {s} to hand it over, or copy {s} to keep your own [OWNERSHIP.md {s}]",
                    .{ subject, name, name, situations },
                );
                return;
            }
        }
        try self.fail(
            "luce.sema.own",
            span,
            "{s}; store something fresh, give NAME, or copy NAME [OWNERSHIP.md {s}]",
            .{ subject, situations },
        );
    }

    // Absence ---------------------------------------------------------------

    /// The advice a `T?` earns when it turns up where a `T` belongs —
    /// the message the whole feature is judged by, so it names the two
    /// ways out and the name to apply them to.  Empty when the type is
    /// not optional, so every caller can end with one `{s}` and say
    /// nothing extra when there is nothing extra to say.
    ///
    /// Only a *local* narrows (Dart's rule, and for Dart's reason: a
    /// field or an element can change between the test and the use),
    /// so anything else is told to bind a name first.
    fn absenceAdvice(self: *FunctionBuilder, of: Type, from: ?*const ast.Expression) Error![]const u8 {
        if (of != .optional) return "";
        const named: ?[]const u8 = named: {
            const expression = from orelse break :named null;
            if (expression.* != .name) break :named null;
            if (self.findLocal(expression.name.text) == null) break :named null;
            break :named expression.name.text;
        };
        if (named) |name| {
            return std.fmt.allocPrint(
                self.arena(),
                "; test it first (if {s} != none:) or supply a fallback ({s} else …)",
                .{ name, name },
            );
        }
        return std.fmt.allocPrint(
            self.arena(),
            "; bind it to a name and test that (let x = …, then if x != none:), or supply a fallback (… else …)",
            .{},
        );
    }

    /// The advice a number earns when it turns up where a *narrower*
    /// number belongs.  Narrowing is implicit in no direction and no
    /// context (docs/TYPES.md §2), and a mismatch that says only that
    /// leaves the reader to guess whether there is a way across at
    /// all — there is, spelled with the name of the type it produces.
    ///
    /// Empty for every pair that is not a numeric narrowing, so a
    /// caller may append it beside `absenceAdvice` and say nothing
    /// extra when there is nothing extra to say.
    fn narrowingAdvice(self: *FunctionBuilder, expected: Type, actual: Type) Error![]const u8 {
        if (!expected.isNumeric() or !actual.isNumeric()) return "";
        if (actual.widensTo(expected)) return "";
        return std.fmt.allocPrint(
            self.arena(),
            "; narrowing is never implicit — write {s}(…)",
            .{try self.analyzer.typeName(expected)},
        );
    }

    /// What to say after a type mismatch: absence first, because a
    /// missing value is a different mistake from a wrong width and the
    /// reader has to fix it first, then the narrowing that has a
    /// constructor to spell it.
    fn mismatchAdvice(
        self: *FunctionBuilder,
        expected: Type,
        actual: Type,
        from: ?*const ast.Expression,
    ) Error![]const u8 {
        const absence = try self.absenceAdvice(actual, from);
        if (absence.len != 0) return absence;
        return self.narrowingAdvice(expected, actual);
    }

    /// The name behind an expression that is a `T?` the flow analysis
    /// has already proved present — so a second test, or a fallback,
    /// is dead code the reader should be told about rather than left
    /// to wonder at "long is always there".
    fn narrowedName(self: *FunctionBuilder, expression: *const ast.Expression) ?[]const u8 {
        if (expression.* != .name) return null;
        const found = self.findLocal(expression.name.text) orelse return null;
        if (self.code.localType(found.info.local) != .optional) return null;
        if (!self.isNarrowed(found.info.local)) return null;
        return expression.name.text;
    }

    /// Report a `T?` standing where a `T` is required.  `situation`
    /// says what wanted the value, in the reader's words.
    fn failAbsence(
        self: *FunctionBuilder,
        span: Span,
        situation: []const u8,
        of: Type,
        from: ?*const ast.Expression,
    ) Error!void {
        try self.fail("luce.sema.absent", span, "{s} needs {s}, but this is {s}{s}", .{
            situation,
            try self.analyzer.typeName(of.held().?),
            try self.analyzer.typeName(of),
            try self.absenceAdvice(of, from),
        });
    }

    /// True after reporting, when `value` is optional and the place it
    /// stands in is not.  The one call every operation that needs a
    /// real value makes before it looks at the type any further.
    fn refusesAbsence(
        self: *FunctionBuilder,
        value: Typed,
        situation: []const u8,
        span: Span,
        from: ?*const ast.Expression,
    ) Error!bool {
        if (value.value_type != .optional) return false;
        try self.failAbsence(span, situation, value.value_type, from);
        return true;
    }

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
    fn fit(self: *FunctionBuilder, value: Typed, expected: Type) Error!?Typed {
        if (value.value_type.eql(expected)) return value;
        if (value.value_type.widensTo(expected)) return try self.widenNumeric(value, expected);
        const payload = expected.held() orelse return null;
        const inner = (try self.fit(value, payload)) orelse return null;
        const arguments = try self.arena().alloc(Register, 1);
        arguments[0] = inner.register;
        return .{
            .register = try self.code.emit(
                .{ .intrinsic = .{ .kind = .optional_wrap, .arguments = arguments } },
                expected,
            ),
            .value_type = expected,
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
    fn widenNumeric(self: *FunctionBuilder, value: Typed, to: Type) Error!Typed {
        std.debug.assert(value.value_type.widensTo(to));
        return .{
            .register = try self.code.emit(
                .{ .convert = value.register },
                to,
            ),
            .value_type = to,
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
    fn widensInto(self: *FunctionBuilder, held: *Typed, want: Type) Error!bool {
        if (held.value_type.eql(want)) return true;
        if (!held.value_type.widensTo(want)) return false;
        held.* = try self.widenNumeric(held.*, want);
        return true;
    }

    /// The element type a `list(T)` place names, for the literal about
    /// to be lowered into it; null for every place that is not one.
    fn elementOf(self: *FunctionBuilder, expected: Type) ?Type {
        const descriptor = self.analyzer.heapOf(expected) orelse return null;
        return if (descriptor == .list) descriptor.list else null;
    }

    /// The scalar type a literal going into `expected` lands on, or
    /// null when `expected` names no scalar for it to land on
    /// (docs/TYPES.md D3).
    ///
    /// `T?` looks through to its `T`: `let x: double? = 1` lands the
    /// literal at a float and wraps it, which is the same order `fit`
    /// composes its two widenings in.
    fn landingType(expected: Type) ?Type {
        return switch (expected) {
            // A storage type is a place a literal lands on like any
            // other — `pixels[i] = 200` with a `byte` element is §1's
            // own example, and 200 fits while 300 is refused where it
            // is written rather than where it is stored.
            .byte, .short, .int, .long, .half, .float, .double => expected,
            .optional => |payload| switch (payload) {
                .byte => .byte,
                .short => .short,
                .int => .int,
                .long => .long,
                .half => .half,
                .float => .float,
                .double => .double,
                // A number never lands on an enum: `Method` is a set of
                // names and `Method(8)` is the only way in (D4, R2).
                .boolean, .string, .strukt, .heap, .enumeration => null,
            },
            .none, .boolean, .string, .strukt, .heap, .enumeration => null,
        };
    }

    /// A number at the type an operator computes it at — `int` for a
    /// `byte` or a `short`, `float` for a `half`, and itself for the
    /// four that already do arithmetic (D5).  The one place that
    /// promotion is spelled for a *single* operand; `unifyNumeric` is
    /// the same rule for a pair.
    fn promoted(self: *FunctionBuilder, value: Typed) Error!Typed {
        const at = value.value_type.arithmeticType() orelse return value;
        if (value.value_type.eql(at)) return value;
        return self.widenNumeric(value, at);
    }

    /// Bring two numeric operands to the type they meet at
    /// (`Type.unified`).  True when it moved either of them.
    fn unifyNumeric(self: *FunctionBuilder, left: *Typed, right: *Typed) Error!bool {
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

    /// A value that reached its place, and whether it got there by the
    /// `T <: T?` widening — which is how an assignment knows the slot
    /// definitely holds something now.
    const Fitted = struct { value: Typed, present: bool };

    /// Lower an expression into a place whose type is already known —
    /// which is what gives `none` a type, since it has none of its
    /// own.  Reports and returns null on a mismatch; `subject` names
    /// the place for the message.
    fn lowerTyped(
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
            return .{
                .value = .{ .register = try self.code.zeroOf(expected), .value_type = expected },
                .present = false,
            };
        }
        self.wanted_element = self.elementOf(expected);
        self.wanted = landingType(expected);
        const value = (try self.lowerExpression(expression, false)) orelse return null;
        const fitted = (try self.fit(value, expected)) orelse {
            try self.fail("luce.sema.type", span, "{s} is {s} but the value is {s}{s}", .{
                subject,
                try self.analyzer.typeName(expected),
                try self.analyzer.typeName(value.value_type),
                try self.mismatchAdvice(expected, value.value_type, expression),
            });
            return null;
        };
        return .{ .value = fitted, .present = !value.value_type.eql(expected) };
    }

    /// Report a use of a poisoned name (S10, S29); true when poisoned.
    fn checkPoisoned(self: *FunctionBuilder, info: *const LocalInfo, name: []const u8, span: Span) Error!bool {
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

    /// Lower a left-to-right operand sequence whose registers must all
    /// be usable together afterwards.  Registers are block-local, so
    /// every operand followed by a block-splitting one is carried
    /// across the split in a hidden local and re-loaded at the end.
    /// The returned values live in the arena.
    /// Operand counts this stage's scratch fits without allocating.
    /// Every binary operator has two, an index has at most five, and a
    /// call of more than this is rare — but `lowerOperands` runs for
    /// each of them, and two allocate-and-free pairs per operator is
    /// most of the compiler's allocator traffic when it is not one.
    const inline_operands = 8;

    fn lowerOperands(self: *FunctionBuilder, expressions: []const *ast.Expression) Error!?[]Typed {
        return self.lowerOperandsInto(expressions, .nothing);
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
            .method => |method| {
                if (index == 0) return null;
                // A struct receiver's parameters come from the
                // declaration, and which slot this argument fills is
                // what decides its landing — names may reorder
                // (docs/ARGS.md D5), so the slot is answered silently
                // by the same rule the checker applies after the
                // batch, through the one `argumentSlot`.
                if (self.declaredName(values[0].value_type) != null) {
                    const function_index = (try self.structMethod(values[0].value_type, method.name)) orelse
                        return null;
                    const info = self.analyzer.functions.items[function_index];
                    if (info.declaration.parameters.len != info.parameter_types.len) return null;
                    const surface = try self.declarationSlots(info.declaration.parameters, info.parameter_defaults);
                    const slot = argumentSlot(surface, 1, method.arguments, index - 1) orelse
                        return null;
                    return info.parameter_types[slot];
                }
                // A builtin method's arguments are positional (D10); a
                // named one gets no landing here and its refusal after
                // the batch.
                if (method.arguments[index - 1].name != null) return null;
                const wanted = (try self.methodParameters(values[0].value_type, method.name)) orelse
                    return null;
                return if (index - 1 < wanted.len) wanted[index - 1] else null;
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
                    .builder, .file => null,
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
            .builder, .file => null,
        };
    }

    /// A method batch's landing needs the written arguments as well as
    /// the name: which slot an argument fills is what says where it
    /// lands, and a named argument may fill a slot its position does
    /// not (docs/ARGS.md D5).
    const MethodLanding = struct {
        name: []const u8,
        arguments: []const ast.Argument,
    };

    const Landing = union(enum) {
        /// Nothing is written down; every operand takes the default.
        nothing,
        /// One type per operand, positionally.
        places: []const Type,
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

    /// As `lowerOperands`, with the type each operand lands in already
    /// known — which is what lets a bare `none` be written among them,
    /// since it has no type of its own.
    fn lowerOperandsInto(
        self: *FunctionBuilder,
        expressions: []const *ast.Expression,
        landing: Landing,
    ) Error!?[]Typed {
        var spill_storage: [inline_operands]?LocalId = undefined;
        var split_storage: [inline_operands]bool = undefined;
        const wide = expressions.len > inline_operands;

        const values = try self.arena().alloc(Typed, expressions.len);
        const spills = if (wide)
            try self.temporary().alloc(?LocalId, expressions.len)
        else
            spill_storage[0..expressions.len];
        defer if (wide) self.temporary().free(spills);

        const later_splits = if (wide)
            try self.temporary().alloc(bool, expressions.len)
        else
            split_storage[0..expressions.len];
        defer if (wide) self.temporary().free(later_splits);
        var any_split = false;
        var backwards = expressions.len;
        while (backwards > 0) {
            backwards -= 1;
            later_splits[backwards] = any_split;
            if (self.splitsBlocks(expressions[backwards], split_search_depth)) any_split = true;
        }

        // Which operands still have something that could mutate a
        // container running after them — the residual hazard below.
        var later_mutates: [inline_operands]bool = undefined;
        const mutating = if (wide)
            try self.temporary().alloc(bool, expressions.len)
        else
            later_mutates[0..expressions.len];
        defer if (wide) self.temporary().free(mutating);
        var any_mutation = false;
        backwards = expressions.len;
        while (backwards > 0) {
            backwards -= 1;
            mutating[backwards] = any_mutation;
            if (effects.mayMutateContainers(expressions[backwards])) any_mutation = true;
        }

        for (expressions, 0..) |expression, index| {
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
            const place = try self.landsOn(landing, values, index, expressions.len);
            if (place) |landed| {
                self.wanted = landingType(landed);
                self.wanted_element = self.elementOf(landed);
            }
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
            // The residual hazard copy-on-store leaves open
            // (docs/STRINGS.md): this register may be a *borrow* of an
            // element's or a field's bytes, and an operand still to
            // come could free them — `f(pieces[0], drop_first(pieces))`
            // is the shape.  An object would go stale and trap (S9); a
            // string has no handle to check, so it closes here, by
            // copying the borrow before the mutation can happen.
            if (mutating[index] and
                self.analyzer.ownsStorage(value.value_type) and
                self.borrowsStoredValue(value.register))
            {
                values[index].register = try self.code.ownStorage(value.register);
                try self.parkFreshStorage(values[index]);
            }
            spills[index] = null;
            if (later_splits[index] and values[index].value_type != .none) {
                spills[index] = try self.code.spill(values[index].register, values[index].value_type);
            }
        }
        for (spills, 0..) |spill, index| {
            if (spill) |local| {
                values[index].register = try self.code.load(local);
            }
        }
        return values;
    }

    // Statements -----------------------------------------------------------

    pub fn lowerBlock(self: *FunctionBuilder, block: ast.Block) Error!void {
        try self.pushScope();
        try self.refuseUnreachable(block);
        for (block.statements) |statement| {
            // Fresh objects nothing adopted die with their statement
            // (S3); the release is a no-op for everything adopted.
            const temps_floor = self.temps.items.len;
            try self.lowerStatement(statement);
            try self.flushTemps(temps_floor);
        }
        try self.emitScopeEnd();
        self.popScope();
    }

    /// A statement below one that never comes back cannot run, and the
    /// reader wrote it believing it does.
    ///
    /// **Why this is a refusal and not a tolerated wart.**  Luce has
    /// one severity: every diagnostic stops the compile, because a
    /// warning is a rule the language did not commit to
    /// (`support/diagnostics.zig`).  So the only question is which side
    /// of the line this falls on, and the language already draws that
    /// line: it refuses `a < b < c` and `not a == b` because the way
    /// they read and the way they run disagree, and it *accepts* an
    /// unused local, which is merely redundant — the program means what
    /// it says and does what it says.  Unreachable code is the first
    /// kind, not the second.  A statement after `return` is one the
    /// author believes runs, and it never does.
    ///
    /// Only the first is reported: one terminator, one mistake, however
    /// many lines it stranded.
    fn refuseUnreachable(self: *FunctionBuilder, block: ast.Block) Error!void {
        for (block.statements, 0..) |statement, index| {
            if (index + 1 == block.statements.len) return;
            const leaves = helpers.exitingStatement(statement) orelse continue;
            const stranded = block.statements[index + 1];
            const at = self.analyzer.diagnostics.sources.place(
                self.analyzer.diagnostics.scope,
                statement.span().start,
            );
            return self.fail(
                "luce.sema.unreachable",
                stranded.span(),
                "this cannot run: the {s} on line {d} leaves the block first; delete it, or move it above the {s}",
                .{ leaves, at.line, leaves },
            );
        }
    }

    fn lowerStatement(self: *FunctionBuilder, statement: ast.Statement) Error!void {
        // Statement granularity is the trap-location contract: every
        // instruction a statement lowers to reports the statement's
        // own line, the way Python tracebacks do.
        self.code.origin = @intCast(statement.span().start);
        switch (statement) {
            .let => |binding| try self.lowerBinding(
                binding.name,
                binding.name_span,
                binding.annotation,
                binding.value,
                false,
                binding.span,
            ),
            .variable => |binding| {
                if (binding.value) |value| {
                    try self.lowerBinding(
                        binding.name,
                        binding.name_span,
                        binding.annotation,
                        value,
                        true,
                        binding.span,
                    );
                } else {
                    try self.lowerLateDeclaration(
                        binding.name,
                        binding.name_span,
                        binding.annotation.?,
                    );
                }
            },
            .destructure => |bind| try self.lowerDestructure(bind),
            .assign => |assign| try self.lowerAssign(assign),
            .conditional => |conditional| try self.lowerConditional(conditional),
            .while_loop => |loop| try self.lowerWhile(loop),
            .for_range => |loop| try self.lowerForRange(loop),
            .for_each => |loop| try self.lowerForEach(loop),
            .return_statement => |returned| try self.lowerReturn(returned),
            .break_statement => |broke| {
                if (self.loops.items.len == 0) {
                    try self.fail("luce.sema.loop", broke.span, "break outside a loop", .{});
                    return;
                }
                const frame = self.loops.items[self.loops.items.len - 1];
                // Early exits unwind what the scopes they leave still
                // own (S4).
                try self.emitTempReleases(frame.temps_depth);
                try self.emitScopeReleases(frame.scope_depth, &.{});
                try self.code.jump(frame.exit_block);
            },
            .continue_statement => |continued| {
                if (self.loops.items.len == 0) {
                    try self.fail("luce.sema.loop", continued.span, "continue outside a loop", .{});
                    return;
                }
                const frame = self.loops.items[self.loops.items.len - 1];
                try self.emitTempReleases(frame.temps_depth);
                try self.emitScopeReleases(frame.scope_depth, &.{});
                try self.code.jump(frame.continue_block);
            },
            .expression => |expression| {
                _ = try self.lowerExpression(expression.value, true);
            },
            .guarded => |guarded| try self.lowerGuarded(guarded),
            .match => |matched| try self.lowerMatch(matched),
        }
    }

    /// `match m:` — dispatch over an enum (docs/ENUMS.md R1).
    ///
    /// **The lowering is the compare-and-branch tree an `elif` chain
    /// would have been**, which is the point: the statement buys the
    /// *checking* — every member named, none named twice, nothing named
    /// that is not a member — and pays nothing for it at run time,
    /// because LLVM turns a chain of equalities on one value into the
    /// switch it already knows how to make.
    ///
    /// **With every member named, the last arm is the fallthrough.**  An
    /// enum's one promise is that every value of it is a member: the
    /// only ways to make one are a member name and `Method(n)`, which
    /// answers `Method?`.  So the final comparison would be a test that
    /// can only succeed, and nothing traps here — there is no case left
    /// for a trap to be about.
    fn lowerMatch(self: *FunctionBuilder, matched: ast.Match) Error!void {
        const temps_floor = self.temps.items.len;
        const scrutinee = (try self.lowerExpression(matched.scrutinee, false)) orelse return;
        if (scrutinee.value_type != .enumeration) {
            try self.fail(
                "luce.sema.match",
                matched.scrutinee.span(),
                "match dispatches over an enum, and {s} is not one; chain if and elif for a value whose cases have no names{s}",
                .{
                    try self.analyzer.typeName(scrutinee.value_type),
                    try self.absenceAdvice(scrutinee.value_type, matched.scrutinee),
                },
            );
            return;
        }
        const reference = scrutinee.value_type.enumeration;
        const declared = self.analyzer.enums.items[reference.index];

        // Which member each arm names, and which members were named:
        // both are needed before anything is lowered, because whether
        // the *last* arm is a comparison or the fallthrough depends on
        // the whole set.
        const chosen = try self.temporary().alloc(u32, matched.arms.len);
        defer self.temporary().free(chosen);
        const covered = try self.temporary().alloc(bool, declared.members.len);
        defer self.temporary().free(covered);
        @memset(covered, false);
        var usable = true;
        for (matched.arms, chosen) |arm, *slot| {
            const member = declared.findMember(arm.name) orelse {
                try self.failUnknownMember(declared, arm.name, arm.name_span);
                usable = false;
                continue;
            };
            if (covered[member]) {
                try self.fail(
                    "luce.sema.match",
                    arm.name_span,
                    "{s} already has an arm in this match",
                    .{arm.name},
                );
                usable = false;
                continue;
            }
            covered[member] = true;
            slot.* = member;
        }
        if (!usable) return;

        var missing: usize = 0;
        for (covered) |named| {
            if (!named) missing += 1;
        }
        if (matched.else_span) |span| {
            // An else that can never run is the coalesce's own refusal,
            // and it is refused for the reason exhaustiveness exists:
            // an arm that covers nothing today would quietly cover the
            // member somebody adds tomorrow, which is exactly the
            // mistake a checked match is here to make impossible.
            if (missing == 0) {
                try self.fail(
                    "luce.sema.match",
                    span,
                    "every member of {s} already has an arm, so this else can never run; drop it",
                    .{declared.name},
                );
                return;
            }
        } else if (missing != 0) {
            try self.failMissingArms(declared, covered, missing, matched.span);
            return;
        }

        // The scrutinee is read once and carried in a slot: a register
        // never crosses a block, and every arm's test is a block.
        const held = try self.code.spill(scrutinee.register, scrutinee.value_type);
        try self.flushTemps(temps_floor);

        // Facts an arm proves are the arm's own, and one that assigns
        // over a narrowed name unproves it for everybody after
        // (`lowerWhile` widens the same way, for the same reason).
        const entry = try self.narrowSave();
        defer self.temporary().free(entry);

        // With no else and every member named, the last arm needs no
        // test: it is where a value that matched nothing above must be.
        const fallthrough = matched.else_block == null;
        const tested = if (fallthrough) matched.arms.len - 1 else matched.arms.len;

        var frames: std.ArrayList(mir.build.Lowering.Conditional) = .empty;
        defer frames.deinit(self.temporary());
        for (matched.arms[0..tested], chosen[0..tested]) |arm, member| {
            const value = try self.code.emit(
                .{ .const_long = declared.members[member].value },
                scrutinee.value_type,
            );
            const same = try self.code.emit(.{ .binary = .{
                .op = .equal,
                .operand_type = scrutinee.value_type,
                .left = try self.code.load(held),
                .right = value,
            } }, .boolean);
            const arms = try self.code.openIf(same, true);
            try self.narrowRestore(entry);
            try self.lowerBlock(arm.body);
            try self.code.elseArm(arms);
            try frames.append(self.temporary(), arms);
        }
        try self.narrowRestore(entry);
        if (matched.else_block) |otherwise| {
            try self.lowerBlock(otherwise);
        } else {
            try self.lowerBlock(matched.arms[matched.arms.len - 1].body);
        }
        while (frames.pop()) |arms| try self.code.closeIf(arms);

        try self.narrowRestore(entry);
        for (matched.arms) |arm| self.widenAssignedIn(arm.body);
        if (matched.else_block) |otherwise| self.widenAssignedIn(otherwise);
    }

    /// A match arm, or a `Method.x`, naming something the enum has not.
    fn failUnknownMember(
        self: *FunctionBuilder,
        declared: types.EnumType,
        written: []const u8,
        span: Span,
    ) Error!void {
        var suggestion = helpers.Suggestion.init(written);
        for (declared.members) |member| suggestion.offer(member.name);
        if (suggestion.best()) |closest| {
            try self.fail("luce.sema.match", span, "{s} is not a member of {s}; did you mean {s}?", .{
                written,
                declared.name,
                closest,
            });
            return;
        }
        try self.fail("luce.sema.match", span, "{s} is not a member of {s}", .{ written, declared.name });
    }

    /// The members a match with no `else` left out, named — all of
    /// them, in declaration order, because a reader who has to compile
    /// again to learn the next one is doing the compiler's work
    /// (`context.writeMissingFields` is the same sentence for a struct).
    fn failMissingArms(
        self: *FunctionBuilder,
        declared: types.EnumType,
        covered: []const bool,
        missing: usize,
        span: Span,
    ) Error!void {
        var written: std.ArrayList(u8) = .empty;
        defer written.deinit(self.temporary());
        var written_so_far: usize = 0;
        for (covered, 0..) |named, index| {
            if (named) continue;
            if (written_so_far != 0) {
                if (missing > 2) try written.appendSlice(self.temporary(), ",");
                try written.appendSlice(self.temporary(), " ");
                if (written_so_far + 1 == missing) try written.appendSlice(self.temporary(), "and ");
            }
            try written.appendSlice(self.temporary(), declared.members[index].name);
            written_so_far += 1;
        }
        try self.fail(
            "luce.sema.match",
            span,
            "this match has no arm for {s} {s} of {s}; write {s}, or an else for everything the arms above do not name",
            .{
                if (missing == 1) "member" else "members",
                written.items,
                declared.name,
                if (missing == 1) "one" else "them",
            },
        );
    }

    /// `name_span` is the name alone and `span` the whole statement:
    /// a complaint about the word points at the word, and one about
    /// what the statement says points at the statement.
    fn lowerBinding(
        self: *FunctionBuilder,
        name: []const u8,
        name_span: Span,
        annotation: ?ast.TypeName,
        value_expression: *ast.Expression,
        mutable: bool,
        span: Span,
    ) Error!void {
        // An empty [] has no element type of its own; the annotation
        // supplies it: var xs: list(long) = []
        if (value_expression.* == .list_literal and value_expression.list_literal.elements.len == 0) {
            const written = annotation orelse {
                try self.fail(
                    "luce.sema.type",
                    span,
                    "an empty [] needs an annotation: var {s}: list(T) = []",
                    .{name},
                );
                return self.forgetName(name);
            };
            const expected = (try self.analyzer.resolveType(self.module, written)) orelse
                return self.forgetName(name);
            const descriptor = self.analyzer.heapOf(expected);
            if (descriptor == null or descriptor.? != .list) {
                try self.fail("luce.sema.type", span, "[] builds a list, but {s} is annotated {s}", .{
                    name,
                    try self.analyzer.typeName(expected),
                });
                return self.forgetName(name);
            }
            const list = try self.code.emit(.{ .heap_new = .{ .heap = expected.heap, .dims = &.{} } }, expected);
            const local = (try self.declareLocal(name, expected, mutable, .owned, name_span)) orelse
                return self.forgetName(name);
            try self.code.store(local, list);
            try self.code.bind(local, list);
            return;
        }

        // A binding whose initializer failed still declares a name the
        // reader meant; remembering it keeps one mistake from
        // producing an "unknown name" per later use.
        var value: Typed = undefined;
        // The annotation said `T?` and the initializer handed over a
        // plain `T`, so the binding starts out present.
        var widened = false;
        if (annotation) |written| {
            const expected = (try self.analyzer.resolveType(self.module, written)) orelse
                return self.forgetName(name);
            if (value_expression.* == .none_literal) {
                value = ((try self.lowerTyped(value_expression, expected, span, name)) orelse
                    return self.forgetName(name)).value;
            } else {
                self.wanted_element = self.elementOf(expected);
                self.wanted = landingType(expected);
                const initializer = (try self.lowerExpression(value_expression, false)) orelse
                    return self.forgetName(name);
                value = (try self.fit(initializer, expected)) orelse {
                    // `let f: double = 1` used to arrive here and be
                    // told to write `double(...)`; it widens on its own
                    // now (docs/NUMERICS.md).  What is left is two
                    // sentences, and which one is true depends on the
                    // pair: a `long` into an `int` *has* a conversion
                    // and is refused because narrowing is never
                    // implicit, while a `string` into an `int` has
                    // none at all (docs/TYPES.md §11).
                    const narrowing = try self.narrowingAdvice(expected, initializer.value_type);
                    try self.fail(
                        "luce.sema.type",
                        span,
                        "{s} declared {s} but initialized with {s}{s}{s}",
                        .{
                            name,
                            try self.analyzer.typeName(expected),
                            try self.analyzer.typeName(initializer.value_type),
                            if (narrowing.len != 0) narrowing else ", and there is no conversion between them",
                            try self.absenceAdvice(initializer.value_type, value_expression),
                        },
                    );
                    return self.forgetName(name);
                };
                widened = !initializer.value_type.eql(expected);
            }
        } else {
            value = (try self.lowerExpression(value_expression, false)) orelse
                return self.forgetName(name);
        }
        // A binding that received something fresh (or a give, or a
        // copy) owns the object; receiving another name is an alias
        // (S1, S8).  `var xs: list(T)? = none` owns too, for S40's
        // reason: the binding is established here and whatever a later
        // assignment fills in belongs to its scope — `none` itself
        // owns nothing (S43).
        const owns = self.analyzer.carriesObjects(value.value_type) and
            (value_expression.* == .none_literal or try self.yieldsOwnership(value_expression));
        const local = (try self.declareLocal(
            name,
            value.value_type,
            mutable,
            if (owns) .owned else .alias,
            name_span,
        )) orelse return self.forgetName(name);
        try self.storeOwned(local, value);
        if (owns) {
            try self.code.bind(local, value.register);
        } else if (value_expression.* == .name) {
            // `let y = x` aliases (S8).  Remember whose object it is,
            // so refusing `give y` can name `x` (S23).
            self.rememberOwnerName(name, value_expression.name.text);
        }
        // `let x: long? = 5` is optional in its type and present in
        // fact, and the reader should not have to test what they just
        // wrote.
        if (widened) try self.narrow(local);
    }

    /// `let low, high = minmax(xs)` — the one place a call answering a
    /// return shape hands its values to names (docs/RETURNS.md).
    ///
    /// Under the lowering the shape is one struct, so this is one
    /// `call` and one `struct_get` per name: S1 per name, as it says.
    fn lowerDestructure(self: *FunctionBuilder, bind: ast.Destructure) Error!void {
        self.shape_position = .bind;
        const value = (try self.lowerExpression(bind.value, false)) orelse {
            for (bind.names) |name| try self.forgetName(name.text);
            return;
        };
        const shape = self.analyzer.returnShapeOf(value.value_type) orelse {
            // One value, two names.  Naming the call is what makes the
            // sentence actionable, and the call is right there.
            try self.fail(
                "luce.sema.shape",
                bind.span,
                "{s} answers 1 value, got {d} names",
                .{ try self.calledName(bind.value), bind.names.len },
            );
            for (bind.names) |name| try self.forgetName(name.text);
            return;
        };
        if (shape.fields.len != bind.names.len) {
            try self.fail(
                "luce.sema.shape",
                bind.span,
                "{s} answers {d} values, got {d} name{s}",
                .{
                    try self.calledName(bind.value),
                    shape.fields.len,
                    bind.names.len,
                    helpers.plural(bind.names.len),
                },
            );
            for (bind.names) |name| try self.forgetName(name.text);
            return;
        }

        // Each value moves independently to its own binding, and each
        // binding owns what it received and is freed by its scope
        // (S16 per value, S1 per name, S45).  The struct the values
        // rode in is a statement temporary and dies with the
        // statement; it owns nothing once the fields are out.
        for (bind.names, shape.fields, 0..) |name, field, position| {
            const held = try self.code.emit(.{ .struct_get = .{
                .target = value.register,
                .layout = value.value_type.strukt,
                .field = @intCast(position),
            } }, field.field_type);
            const carried = self.analyzer.carriesObjects(field.field_type);
            const local = (try self.declareLocal(
                name.text,
                field.field_type,
                bind.mutable,
                if (carried) .owned else .alias,
                name.span,
            )) orelse continue;
            const stored: Typed = .{ .register = held, .value_type = field.field_type };
            try self.storeOwned(local, stored);
            if (carried) try self.code.bind(local, held);
        }
        // The shape itself never owned the objects its fields carried —
        // each name did, from the moment it was bound — so the
        // temporary must not release them a second time.
        try self.disownShape(value.register);
    }

    /// A destructured call's struct temporary hands its objects to the
    /// names and keeps only its own field run, which the statement's
    /// end still reclaims (docs/STRINGS.md).
    fn disownShape(self: *FunctionBuilder, register: Register) Error!void {
        var index = self.temps.items.len;
        while (index > 0) {
            index -= 1;
            if (self.temps.items[index].register != register) continue;
            if (self.temps.items[index].storage) {
                self.temps.items[index].objects = false;
            } else {
                _ = self.temps.orderedRemove(index);
            }
            return;
        }
    }

    /// The name a reader would recognise the call by, for a message
    /// about its arity.
    fn calledName(self: *FunctionBuilder, expression: *const ast.Expression) Error![]const u8 {
        return switch (expression.*) {
            .call => |call| call.callee,
            .method => |method| method.name,
            .try_call => |attempt| self.calledName(attempt.operand),
            else => "this",
        };
    }

    /// var name: Type — a late declaration (OWNERSHIP.md S40): the
    /// slot starts at the type's zero value; the zero of an object
    /// type is the null object, which traps on use until assigned.
    fn lowerLateDeclaration(
        self: *FunctionBuilder,
        name: []const u8,
        name_span: Span,
        written: ast.TypeName,
    ) Error!void {
        const declared = (try self.analyzer.resolveType(self.module, written)) orelse
            return self.forgetName(name);
        const zero = try self.code.zeroOf(declared);
        // The declaration establishes the binding and its scope; the
        // scope owns whatever a later assignment fills in (S36, S40).
        const local = (try self.declareLocal(name, declared, true, .owned, name_span)) orelse
            return self.forgetName(name);
        try self.storeOwned(local, .{ .register = zero, .value_type = declared });
    }

    // Assignment, and the three shapes of place it can name -------------------

    fn lowerAssign(self: *FunctionBuilder, assign: ast.Assign) Error!void {
        switch (assign.target) {
            .name => |name| try self.lowerAssignName(name.text, name.span, assign),
            .field => |field| try self.lowerAssignField(field, assign),
            .index => |index| try self.lowerAssignIndex(index, assign),
            .chain => |chain| try self.lowerAssignChain(chain, assign),
        }
    }

    /// place = value / place OP= value for a nested place
    /// (`root.a.b`, `cells[0].value`).  The chain is read exactly once
    /// (every subscript evaluated once), then rebuilt from the leaf:
    /// structs functionally update up to the root local, and the first
    /// container index writes in place and stops.  Restricted to
    /// value leaves and value structs — nesting object ownership
    /// through a chain stays the single-level form's job.
    fn lowerAssignChain(self: *FunctionBuilder, chain: ast.ChainTarget, assign: ast.Assign) Error!void {
        // Collect the accessor chain outer-to-inner, then find the
        // root name.
        var steps: std.ArrayList(*const ast.Expression) = .empty;
        defer steps.deinit(self.temporary());
        var walk: *const ast.Expression = chain.place;
        const root: ast.Name = while (true) {
            switch (walk.*) {
                .name => |name| break name,
                .field => |field| {
                    try steps.append(self.temporary(), walk);
                    walk = field.target;
                },
                .index => |index| {
                    try steps.append(self.temporary(), walk);
                    walk = index.target;
                },
                else => {
                    try self.fail("luce.parse.assign", chain.span, "assignment targets a name, a field, or an index of one", .{});
                    return;
                },
            }
        };
        std.mem.reverse(*const ast.Expression, steps.items);

        // The root must be a mutable, usable local.
        if (std.mem.eql(u8, root.text, "input") or std.mem.eql(u8, root.text, "output")) {
            try self.fail("luce.sema.name", root.span, "ports are not nested places", .{});
            return;
        }
        const found = self.findLocal(root.text) orelse {
            try self.failUnknownName(root.text, root.span);
            return;
        };
        const info = found.info;
        if (!info.mutable) {
            try self.fail("luce.sema.let", root.span, "{s} is let-bound; use var for reassignment", .{root.text});
            return;
        }
        if (try self.checkPoisoned(info, root.text, root.span)) return;
        const root_local = info.local;
        const root_type = self.code.localType(root_local);

        // Lower every subscript across the chain plus the right-hand
        // side in one pass: lowerOperands keeps them all live together
        // even across short-circuit block splits, so the descent and
        // rebuild below emit only non-splitting struct/index
        // instructions and every cached register stays valid.
        var operand_list: std.ArrayList(*ast.Expression) = .empty;
        defer operand_list.deinit(self.temporary());
        for (steps.items) |node| {
            if (node.* == .index) {
                for (node.index.indices) |subscript| try operand_list.append(self.temporary(), subscript);
            }
        }
        try operand_list.append(self.temporary(), assign.value);
        const operands = (try self.lowerOperands(operand_list.items)) orelse return;
        const value = operands[operands.len - 1];
        var next_operand: usize = 0;

        // Descend, reading the current value at each step and caching
        // what the rebuild needs.
        const accessors = try self.arena().alloc(mir.build.Lowering.Step, steps.items.len);
        var current = try self.code.load(root_local);
        var current_type = root_type;
        for (steps.items, accessors) |node, *accessor| {
            switch (node.*) {
                .field => |field| {
                    if (current_type != .strukt) {
                        try self.fail("luce.sema.field", field.span, "{s} has no fields", .{
                            try self.analyzer.typeName(current_type),
                        });
                        return;
                    }
                    const layout_index = current_type.strukt;
                    const layout = self.analyzer.structs.items[layout_index];
                    const field_index = layout.findField(field.name) orelse {
                        try self.failUnknownField("luce.sema.field", layout_index, field.name, field.span);
                        return;
                    };
                    if (!try self.fieldReachable(layout_index, field_index, field.span)) return;
                    accessor.* = .{ .field = .{ .parent = current, .layout = layout_index, .field_index = field_index } };
                    current = try self.code.emit(.{ .struct_get = .{
                        .target = current,
                        .layout = layout_index,
                        .field = field_index,
                    } }, layout.fields[field_index].field_type);
                    current_type = layout.fields[field_index].field_type;
                },
                .index => |index| {
                    const lowered = operands[next_operand .. next_operand + index.indices.len];
                    next_operand += index.indices.len;
                    const object_value: Typed = .{ .register = current, .value_type = current_type };
                    const element_type = (try self.checkIndex(object_value, lowered, index.span)) orelse return;
                    // Writing the element back frees the old one, so a
                    // container of object-carrying structs can't be a
                    // nested-place step (it would free objects the
                    // rebuilt struct still shares).
                    if (self.analyzer.carriesObjects(element_type)) {
                        try self.fail("luce.sema.own", index.span, "cannot assign through an index into object-carrying elements; rebuild the element and store it whole [OWNERSHIP.md S22]", .{});
                        return;
                    }
                    const subscripts = try self.arena().alloc(Register, lowered.len);
                    for (lowered, subscripts) |value_operand, *slot| slot.* = value_operand.register;
                    accessor.* = .{ .index = .{ .object = current, .subscripts = subscripts } };
                    // **Always an ordinary read, never a defining
                    // one**, and the parser is what guarantees it: a
                    // target ending in `[...]` becomes an `.index`
                    // target whatever its base, so a chain's last step
                    // is always a field (`targetFrom`).  Every index
                    // here is therefore a step on the way *down* — and
                    // `m["k"].value += 5` reads `m["k"]` to reach a
                    // field of it, which is asking, not writing.  It
                    // keeps `key_missing`.
                    //
                    // `t.counts["w"] += 1` is not this case: it is an
                    // `.index` target with `t.counts` for a base, and
                    // it defines like any other (`lowerAssignIndex`).
                    const read_arguments = try self.arena().alloc(Register, lowered.len + 1);
                    read_arguments[0] = current;
                    @memcpy(read_arguments[1..], subscripts);
                    current = try self.code.emit(
                        .{ .intrinsic = .{ .kind = .index_get, .arguments = read_arguments } },
                        element_type,
                    );
                    current_type = element_type;
                },
                else => unreachable, // only field/index steps are collected
            }
        }

        // The leaf must be a value; nesting object ownership through a
        // chain is not supported here.
        if (self.analyzer.carriesObjects(current_type)) {
            try self.fail("luce.sema.own", chain.span, "a nested place assigns a value; replace the whole object slot with the single-level form [OWNERSHIP.md S21, S25]", .{});
            return;
        }
        // The value was lowered before the chain named a type for it,
        // so a wider place widens it here (docs/TYPES.md §2).
        var placed = value;
        if (placed.value_type.widensTo(current_type)) {
            placed = try self.widenNumeric(placed, current_type);
        }
        if (!placed.value_type.eql(current_type)) {
            try self.fail("luce.sema.type", assign.span, "this place holds {s} but the value is {s}", .{
                try self.analyzer.typeName(current_type),
                try self.analyzer.typeName(placed.value_type),
            });
            return;
        }
        var new_value = placed.register;
        if (assign.compound) |op| {
            new_value = (try self.compoundCombine(op, current, current_type, placed, assign.span)) orelse return;
        }

        // The leaf is a store into whatever the chain descended to, so
        // it takes or copies its storage here; every step above it
        // moves the value the step below just built (docs/STRINGS.md).
        try self.code.rebuild(root_local, accessors, try self.ownedForStore(.{
            .register = new_value,
            .value_type = current_type,
        }));
    }

    /// The read at the head of a compound store into `object[...]`,
    /// and the one place in the language where a read may **define**
    /// what it reads.
    ///
    /// A **map** defines a missing key at the value type's zero and
    /// answers that, rather than trapping `key_missing`: the operator
    /// standing to the left says this read is half of a write, and a
    /// write into a map is how a map grows.  `counts[word] += 1` is
    /// therefore a complete counter, while `counts[word] =
    /// counts[word] + 1` still traps on the first occurrence — the two
    /// spellings diverge on purpose, because only one of them says on
    /// the left that a key is being written (docs/LANGUAGE.md, "Zero
    /// values").
    ///
    /// **Everything else keeps its bounds trap.**  A list or an array
    /// reads through `index_get` exactly as before: an index is a
    /// position in something that already has a shape, not a name that
    /// can be called into being, and `append` is the verb that grows a
    /// list.  The verifier refuses `map_place` on either of them, so
    /// this is not a rule stage 4 has to remember.
    fn compoundPlaceRead(
        self: *FunctionBuilder,
        object: Typed,
        subscripts: []const Register,
        element_type: Type,
    ) Error!Register {
        // `checkIndex` has already answered for this object, so it has
        // a heap shape and the map arm has exactly one subscript.
        if (self.analyzer.heapOf(object.value_type).? == .map) {
            const arguments = try self.arena().alloc(Register, 3);
            arguments[0] = object.register;
            arguments[1] = subscripts[0];
            arguments[2] = try self.code.zeroOf(element_type);
            return self.code.emit(
                .{ .intrinsic = .{ .kind = .map_place, .arguments = arguments } },
                element_type,
            );
        }
        const arguments = try self.arena().alloc(Register, subscripts.len + 1);
        arguments[0] = object.register;
        @memcpy(arguments[1..], subscripts);
        return self.code.emit(
            .{ .intrinsic = .{ .kind = .index_get, .arguments = arguments } },
            element_type,
        );
    }

    /// Combine the current value of a compound-assignment place with
    /// the right-hand side under OP — `place OP= value` reads the
    /// place once (the caller supplies `current`) and stores this.
    /// Type rules are a binary expression's exactly: numeric
    /// arithmetic, plus string concat for `+=`.  A storage-width place
    /// combines at its arithmetic type and narrows back with the range
    /// check, so the answer is always at `place_type`.  Returns the
    /// register holding the combined value, or null after reporting.
    fn compoundCombine(
        self: *FunctionBuilder,
        op: ast.BinaryOp,
        current: Register,
        place_type: Type,
        value: Typed,
        span: Span,
    ) Error!?Register {
        if (!value.value_type.eql(place_type)) {
            try self.fail("luce.sema.type", span, "compound assignment needs matching types: place is {s}, value is {s}", .{
                try self.analyzer.typeName(place_type),
                try self.analyzer.typeName(value.value_type),
            });
            return null;
        }
        // `/` answers a double whatever it divides (docs/NUMERICS.md
        // §2), so `n /= 2` on an integer place is a narrowing nobody
        // wrote.  It is a compile error rather than a silent
        // truncation, which is this design's whole safety story in
        // one line — and the fix is one character.
        //
        // **At every integer width.**  Naming one of them here would
        // leave the other silently truncating, which is the one
        // failure the message exists to prevent.
        if (op == .divide and place_type.isInteger()) {
            try self.fail(
                "luce.sema.type",
                span,
                "/ answers a double and this place is {s}; write '//=' for the integer quotient",
                .{try self.analyzer.typeName(place_type)},
            );
            return null;
        }
        const string_concat = op == .add and place_type == .string;
        if (!place_type.isNumeric() and !string_concat) {
            try self.fail("luce.sema.type", span, "{s} has no compound assignment (numbers, or += on string){s}", .{
                try self.analyzer.typeName(place_type),
                try self.absenceAdvice(place_type, null),
            });
            return null;
        }
        // The bit set has its compound forms too (docs/BITWISE.md
        // D5), and its own gate: integers only, at the two arithmetic
        // widths.
        switch (op) {
            .bit_and, .bit_or, .bit_xor, .shift_left, .shift_right => {
                if (place_type != .int and place_type != .long) {
                    try self.fail(
                        "luce.sema.type",
                        span,
                        "{s} works on int and long; {s} has no bits a program may see",
                        .{
                            context.operatorText(op),
                            try self.analyzer.typeName(place_type),
                        },
                    );
                    return null;
                }
            },
            else => {},
        }
        const operation: mir.BinaryOp = switch (op) {
            .add => .add,
            .subtract => .subtract,
            .multiply => .multiply,
            .divide => .divide,
            .floor_divide => .floor_divide,
            .modulo => .modulo,
            .bit_and => .bit_and,
            .bit_or => .bit_or,
            .bit_xor => .bit_xor,
            .shift_left => .shift_left,
            .shift_right => .shift_right,
            else => unreachable, // the parser only builds these ten
        };
        // **The combine happens at the type the operator computes at,
        // and the answer comes back to the place's own width** (D5).
        // No operator computes at a storage width, so `b += 1` on a
        // `byte` place is `b = byte(b + 1)` exactly: promote to `int`,
        // add there, and narrow back through the same checked
        // conversion that spelling already pays for.
        //
        // Nothing is narrowed silently, which is what lets this stand
        // beside "narrowing is implicit in no direction and no
        // context" rather than against it: 255 + 1 traps
        // `conversion_range` where a C `unsigned char` would wrap to
        // zero.  The place's declared type is where the narrowing is
        // written down — a plain `b = b + 1` has no place to say it
        // and is still refused.
        //
        // `string` has no arithmetic type and needs none: `+=`
        // concatenates at `string` and comes back at `string`.
        const at = place_type.arithmeticType() orelse place_type;
        const left = try self.promoted(.{ .register = current, .value_type = place_type });
        const right = try self.promoted(value);
        const combined = try self.code.emit(.{ .binary = .{
            .op = operation,
            .operand_type = at,
            .left = left.register,
            .right = right.register,
        } }, at);
        const answer = if (at.eql(place_type))
            combined
        else
            try self.code.emit(.{ .convert = combined }, place_type);
        // `s += t` concatenates into fresh storage that no expression
        // parked, so a place that keeps a copy would leave the join
        // behind (docs/STRINGS.md).  Parking it makes the statement's
        // end reclaim it either way.
        if (string_concat) {
            try self.parkFreshStorage(.{ .register = answer, .value_type = place_type });
        }
        return answer;
    }

    fn lowerAssignName(self: *FunctionBuilder, base: []const u8, span: Span, assign: ast.Assign) Error!void {
        const found = self.findLocal(base) orelse {
            const qualified = try self.analyzer.qualify(self.prefix, base);
            if (self.analyzer.constant_names.contains(qualified)) {
                try self.fail("luce.sema.let", span, "{s} is a file-scope constant and cannot be assigned", .{base});
            } else {
                try self.failUnknownName(base, span);
            }
            return;
        };
        const info = found.info;
        if (!info.mutable) {
            try self.fail("luce.sema.let", span, "{s} is let-bound; use var for reassignment", .{base});
            return;
        }
        if (try self.checkPoisoned(info, base, span)) return;
        if (info.iterating) {
            try self.fail(
                "luce.sema.own",
                span,
                "{s} is being iterated; reassigning it would free the collection under the loop [OWNERSHIP.md S5, S9]",
                .{base},
            );
            return;
        }
        const local = info.local;
        const class = info.class;
        const local_type = self.code.localType(local);
        // Compound assignment is value-only arithmetic, so an object
        // place gets a clear message here instead of the ownership
        // check firing on the (non-fresh) right-hand side.
        if (assign.compound != null and info.carries) {
            try self.fail("luce.sema.type", assign.span, "{s} has no compound assignment (numbers, or += on string)", .{
                try self.analyzer.typeName(local_type),
            });
            return;
        }
        if (info.carries) {
            // Assigning `none` is a legitimate way for an owner to let
            // go: the release below frees what was there and the slot
            // then owns nothing (S5, S43).
            const yields = assign.value.* == .none_literal or
                try self.yieldsOwnership(assign.value);
            if (class == .owned and !yields) {
                try self.fail(
                    "luce.sema.own",
                    assign.span,
                    "{s} owns its object; assign something fresh, give NAME, or copy NAME [OWNERSHIP.md S5, S21]",
                    .{base},
                );
                return;
            }
            if (class != .owned and yields) {
                try self.fail(
                    "luce.sema.own",
                    assign.span,
                    "{s} aliases another binding's object and cannot own a fresh one; declare a new name [OWNERSHIP.md S8]",
                    .{base},
                );
                return;
            }
        }
        // A compound assignment works on the value the place holds, so
        // a narrowed `T?` combines at `T` and widens the result back.
        const narrowed_place = local_type == .optional and self.isNarrowed(local);
        const combine_type = if (narrowed_place) local_type.held().? else local_type;
        const wanted = if (assign.compound != null) combine_type else local_type;

        const fitted = (try self.lowerTyped(assign.value, wanted, assign.span, base)) orelse return;
        const value = fitted.value;
        // What the slot now holds decides whether the name reads as
        // its payload from here on: a plain `T` is present, a `T?` or
        // a `none` is back to being a question.  A compound assignment
        // reads the place, so it can only leave what was already there.
        if (local_type == .optional and assign.compound == null) {
            if (fitted.present) try self.narrow(local) else self.widen(local);
        }
        var store = value.register;
        if (assign.compound) |op| {
            var current = try self.code.load(local);
            if (narrowed_place) {
                const unwrap = try self.arena().alloc(Register, 1);
                unwrap[0] = current;
                current = try self.code.emit(
                    .{ .intrinsic = .{ .kind = .optional_unwrap, .arguments = unwrap } },
                    combine_type,
                );
            }
            const combined = (try self.compoundCombine(op, current, combine_type, value, assign.span)) orelse return;
            store = ((try self.fit(.{ .register = combined, .value_type = combine_type }, local_type)) orelse
                return).register;
        }
        // The copy comes first, because the value being stored may be
        // a view of the storage the release is about to give back:
        // `s = s[1:]` is legal (docs/STRINGS.md).
        const owns_storage = self.code.localOwnsStorage(local);
        if (owns_storage) {
            store = try self.ownedForStore(.{ .register = store, .value_type = local_type });
        }
        // Reassigning an owning var frees the old object immediately
        // (S5); the very first assignment finds only the null object.
        // Compound assignment is value-only, so `carries` is false.
        const owns_objects = info.carries and class == .owned;
        try self.code.release(local, owns_objects, owns_storage);
        try self.code.store(local, store);
        if (owns_objects) {
            try self.code.bind(local, store);
        }
    }

    fn lowerAssignField(self: *FunctionBuilder, target: ast.FieldTarget, assign: ast.Assign) Error!void {
        const found = self.findLocal(target.base) orelse {
            try self.failUnknownName(target.base, target.span);
            return;
        };
        const info = found.info;
        if (!info.mutable) {
            try self.fail("luce.sema.let", target.span, "{s} is let-bound; use var for reassignment", .{target.base});
            return;
        }
        if (try self.checkPoisoned(info, target.base, target.span)) return;
        const local = info.local;
        const local_type = self.code.localType(local);
        if (local_type != .strukt) {
            try self.fail("luce.sema.field", target.span, "{s} is {s}, not a struct", .{
                target.base,
                try self.analyzer.typeName(local_type),
            });
            return;
        }
        const layout_index = local_type.strukt;
        const layout = self.analyzer.structs.items[layout_index];
        const field_index = layout.findField(target.field) orelse {
            try self.failUnknownField("luce.sema.field", layout_index, target.field, target.span);
            return;
        };
        if (!try self.fieldReachable(layout_index, field_index, target.span)) return;
        const expected = layout.fields[field_index].field_type;
        // An object field follows the verb rule and its owner drops
        // the old value (S25); only the owning binding can restock it.
        const field_carries = self.analyzer.carriesObjects(expected);
        if (field_carries) {
            if (info.class != .owned) {
                try self.fail(
                    "luce.sema.own",
                    target.span,
                    "{s} does not own its objects; assign the field through the owning name [OWNERSHIP.md S25, S26]",
                    .{target.base},
                );
                return;
            }
            // `none` owns nothing, so emptying an optional object field
            // is always legal — the release below frees what was there.
            if (assign.value.* != .none_literal and !(try self.yieldsOwnership(assign.value))) {
                try self.failNeedsOwnership(
                    assign.span,
                    "this field keeps its object",
                    assign.value,
                    "S21, S25",
                );
                return;
            }
        }
        const named = try std.fmt.allocPrint(self.arena(), "{s}.{s}", .{ target.base, target.field });
        const value = ((try self.lowerTyped(assign.value, expected, assign.span, named)) orelse return).value;
        const current = try self.code.load(local);
        var store = value.register;
        if (assign.compound) |op| {
            // Read the field once, combine, store back (fields that
            // carry objects can't be compound-assigned — value-only).
            const old_value = try self.code.emit(.{ .struct_get = .{
                .target = current,
                .layout = layout_index,
                .field = field_index,
            } }, expected);
            store = (try self.compoundCombine(op, old_value, expected, value, assign.span)) orelse return;
        }
        if (field_carries) {
            const old_field = try self.code.emit(.{ .struct_get = .{
                .target = current,
                .layout = layout_index,
                .field = field_index,
            } }, expected);
            try self.code.unbind(local, old_field);
        }
        // The new field is a store into the run `struct_set` builds;
        // the fields it copies out of `current` belong to `current`.
        const updated = try self.code.emit(.{ .struct_set = .{
            .target = current,
            .layout = layout_index,
            .field = field_index,
            .value = try self.ownedForStore(.{ .register = store, .value_type = expected }),
        } }, local_type);
        // `struct_set` built a whole new value that owns everything in
        // it, copying out of the old one; the old run and its value
        // fields go back now, and the objects it shares with the new
        // value are left alone (docs/STRINGS.md, S26).
        try self.code.release(local, false, self.code.localOwnsStorage(local));
        try self.code.store(local, updated);
        if (field_carries) {
            try self.code.bind(local, store);
        }
    }

    /// place[i] = v, grid[r, c] = v, m[key] = v.  The base may be any
    /// expression: objects mutate through the reference, so no local
    /// write-back is needed.
    fn lowerAssignIndex(self: *FunctionBuilder, target: ast.IndexTarget, assign: ast.Assign) Error!void {
        const expressions = try self.arena().alloc(*ast.Expression, target.indices.len + 2);
        expressions[0] = target.base;
        @memcpy(expressions[1 .. 1 + target.indices.len], target.indices);
        expressions[expressions.len - 1] = assign.value;
        const values = (try self.lowerOperandsInto(expressions, .stored_element)) orelse return;

        const object = values[0];
        const indices = values[1 .. values.len - 1];
        const value = &values[values.len - 1];
        const element_type = (try self.checkIndex(object, indices, target.span)) orelse return;
        // The value was lowered before the container named a type for
        // it, so a wider element widens it here (docs/TYPES.md §2).
        if (value.value_type.widensTo(element_type)) {
            value.* = try self.widenNumeric(value.*, element_type);
        }
        // Containers own their object elements: storing one takes a
        // fresh value, a give, or a copy (S20, S21).
        if (self.analyzer.carriesObjects(element_type) and
            !(try self.yieldsOwnership(assign.value)))
        {
            try self.failNeedsOwnership(
                assign.span,
                "a container keeps its object elements",
                assign.value,
                "S21",
            );
            return;
        }
        if (!value.value_type.eql(element_type)) {
            try self.fail("luce.sema.type", assign.span, "this place holds {s} but the value is {s}", .{
                try self.analyzer.typeName(element_type),
                try self.analyzer.typeName(value.value_type),
            });
            return;
        }
        var store = value.register;
        if (assign.compound) |op| {
            // Read the element once (the base and indices were lowered
            // once, above), combine, and store back.
            const subscripts = try self.arena().alloc(Register, indices.len);
            for (indices, subscripts) |index_value, *slot| slot.* = index_value.register;
            const current = try self.compoundPlaceRead(object, subscripts, element_type);
            store = (try self.compoundCombine(op, current, element_type, value.*, assign.span)) orelse return;
        }
        const arguments = try self.arena().alloc(Register, values.len);
        for (values, arguments) |lowered, *slot| slot.* = lowered.register;
        // The element is a store; the key beside it is not — a map
        // looks a key up before it keeps one (docs/STRINGS.md).
        arguments[arguments.len - 1] = try self.ownedForStore(.{
            .register = store,
            .value_type = element_type,
        });
        _ = try self.code.emit(.{ .intrinsic = .{ .kind = .index_set, .arguments = arguments } }, .none);
    }

    /// Type-check lowered index values against a heap object: lists
    /// take one long, arrays take rank Ints, maps take one key.
    /// Returns the element/value type.
    fn checkIndex(
        self: *FunctionBuilder,
        object: Typed,
        indices: []Typed,
        span: Span,
    ) Error!?Type {
        const descriptor = self.analyzer.heapOf(object.value_type) orelse {
            if (object.value_type == .string) {
                try self.fail("luce.sema.index", span, "strings are sliced (s[a:b] or slice), not indexed; byte_at reads bytes", .{});
            } else {
                try self.fail("luce.sema.index", span, "{s} cannot be indexed{s}", .{
                    try self.analyzer.typeName(object.value_type),
                    try self.absenceAdvice(object.value_type, null),
                });
            }
            return null;
        };
        if (indices.len > 4) {
            try self.fail("luce.sema.index", span, "at most 4 index dimensions", .{});
            return null;
        }

        switch (descriptor) {
            .list => |element| {
                if (indices.len != 1 or !try self.widensInto(&indices[0], .long)) {
                    try self.fail("luce.sema.index", span, "lists index with one long", .{});
                    return null;
                }
                return element;
            },
            .array => |shape| {
                if (indices.len != shape.rank) {
                    try self.fail("luce.sema.index", span, "this array has {d} dimensions, got {d} indices", .{
                        shape.rank,
                        indices.len,
                    });
                    return null;
                }
                for (indices) |*index_value| {
                    if (!try self.widensInto(index_value, .long)) {
                        try self.fail("luce.sema.index", span, "array indices are long", .{});
                        return null;
                    }
                }
                return shape.element;
            },
            .map => |pair| {
                // A key widens into the key type the way an index
                // widens into a `long`: `m[1]` on a `map(long, …)` is
                // the same key `m[1] = …` stores, and refusing one
                // while accepting the other would be a rule about
                // which side of the equals sign a literal sits on.
                // The other direction stays refused, because
                // `widensInto` never narrows.
                if (indices.len != 1 or !try self.widensInto(&indices[0], pair.key)) {
                    try self.fail("luce.sema.index", span, "this map is keyed by {s}", .{
                        try self.analyzer.typeName(pair.key),
                    });
                    return null;
                }
                return pair.value;
            },
            .builder => {
                try self.fail("luce.sema.index", span, "builder has no index; b.build() reads it", .{});
                return null;
            },
            .file => {
                try self.fail("luce.sema.index", span, "file has no index; f.read(buffer) reads bytes", .{});
                return null;
            },
        }
    }

    fn lowerCondition(self: *FunctionBuilder, expression: *ast.Expression) Error!?Typed {
        const condition = (try self.lowerExpression(expression, false)) orelse return null;
        if (condition.value_type != .boolean) {
            try self.fail("luce.sema.type", expression.span(), "condition must be bool, not {s}{s}", .{
                try self.analyzer.typeName(condition.value_type),
                try self.absenceAdvice(condition.value_type, expression),
            });
            return null;
        }
        return condition;
    }

    // Control flow: if, while, for, return ------------------------------------

    fn lowerConditional(self: *FunctionBuilder, conditional: ast.Conditional) Error!void {
        const temps_floor = self.temps.items.len;
        const condition = (try self.lowerCondition(conditional.condition)) orelse return;
        // Condition temporaries die before the branch: the condition
        // value is a bool, so nothing still needs them.
        try self.flushTemps(temps_floor);

        // The arms run under what the condition decided, and what
        // survives the join is what both of them still agree on.  An
        // arm that always leaves — `if x == none: return` — contributes
        // nothing to the join, which is what makes an early-return
        // guard narrow the rest of the block below it.
        const entry = try self.narrowSave();
        defer self.temporary().free(entry);

        const arms = try self.code.openIf(condition.register, conditional.else_block != null);
        try self.applyFacts(conditional.condition, true, split_search_depth);
        try self.lowerBlock(conditional.then_block);
        const after_then = try self.narrowSave();
        defer self.temporary().free(after_then);

        try self.narrowRestore(entry);
        try self.applyFacts(conditional.condition, false, split_search_depth);
        if (conditional.else_block) |else_block| {
            try self.code.elseArm(arms);
            try self.lowerBlock(else_block);
        }
        try self.code.closeIf(arms);

        const then_leaves = helpers.alwaysExits(conditional.then_block);
        const else_leaves = if (conditional.else_block) |else_block|
            helpers.alwaysExits(else_block)
        else
            false;
        if (then_leaves and else_leaves) return; // nothing reaches here
        if (then_leaves) return; // the else arm's state is already current
        if (else_leaves) {
            try self.narrowRestore(after_then);
            return;
        }
        self.narrowIntersect(after_then);
    }

    fn lowerWhile(self: *FunctionBuilder, loop: ast.While) Error!void {
        // The body runs before the back edge re-enters the header, so
        // anything it assigns may be absent again on the next pass.
        self.widenAssignedIn(loop.body);
        const entry = try self.narrowSave();
        defer self.temporary().free(entry);
        const shape = try self.code.openWhile();
        // The frame is pushed before the condition lowers: the header
        // re-runs every iteration, so the S30 give/free guard must see
        // the loop there too.
        try self.loops.append(self.temporary(), .{
            .continue_block = shape.header,
            .exit_block = shape.exit,
            .scope_depth = self.scopes.items.len,
            .temps_depth = self.temps.items.len,
        });
        const temps_floor = self.temps.items.len;
        const condition = (try self.lowerCondition(loop.condition)) orelse {
            _ = self.loops.pop();
            return self.code.abandonLoop(shape.exit);
        };
        // The header re-runs every iteration: its temporaries must die
        // in it, not after the loop.
        try self.flushTemps(temps_floor);
        try self.code.enterWhileBody(shape, condition.register);

        try self.applyFacts(loop.condition, true, split_search_depth);
        try self.lowerBlock(loop.body);
        _ = self.loops.pop();
        try self.code.closeWhile(shape);
        // After the loop nothing the body proved still holds: it may
        // have run zero times, and `break` leaves from anywhere.
        try self.narrowRestore(entry);
    }

    fn lowerForRange(self: *FunctionBuilder, loop: ast.ForRange) Error!void {
        self.widenAssignedIn(loop.body);
        const entry = try self.narrowSave();
        defer self.temporary().free(entry);
        const temps_floor = self.temps.items.len;
        const bounds = (try self.lowerOperands(&.{ loop.start, loop.end })) orelse return;
        // Widened *before* the registers are read: a bound written as
        // an `int` reaches a `long` loop by widening, and the counted
        // loop the IR opens is a `long` one (docs/TYPES.md §2).
        if (!try self.widensInto(&bounds[0], .long) or !try self.widensInto(&bounds[1], .long)) {
            try self.fail("luce.sema.type", loop.span, "range bounds must be long", .{});
            return;
        }
        const start = bounds[0];
        const end = bounds[1];
        // Bound temporaries die before the loop starts.
        try self.flushTemps(temps_floor);

        try self.pushScope();
        defer self.popScope();
        const index_local = (try self.declareLocal(loop.name, .long, false, .alias, loop.span)) orelse return;
        const shape = try self.code.openCountedLoop(index_local, start.register, end.register);

        try self.loops.append(self.temporary(), .{
            .continue_block = shape.step,
            .exit_block = shape.exit,
            .scope_depth = self.scopes.items.len,
            .temps_depth = self.temps.items.len,
        });
        try self.lowerBlock(loop.body);
        _ = self.loops.pop();
        try self.code.closeCountedLoop(shape);
        try self.narrowRestore(entry);
    }

    /// One iteration's binding of a loop name: a plain store when the
    /// slot borrows, a release-then-copy when it owns.
    fn bindLoopName(
        self: *FunctionBuilder,
        local: LocalId,
        value: Register,
        value_type: Type,
    ) Error!void {
        if (!self.code.localOwnsStorage(local)) {
            try self.code.store(local, value);
            return;
        }
        try self.code.release(local, false, true);
        try self.storeOwned(local, .{ .register = value, .value_type = value_type });
    }

    /// for x in xs: — the element (or map key) binds immutably each
    /// iteration, and a named iterable is locked against reassignment
    /// while the loop runs.  What that costs in blocks and hidden
    /// locals is `Lowering.openIteration`'s.
    fn lowerForEach(self: *FunctionBuilder, loop: ast.ForEach) Error!void {
        self.widenAssignedIn(loop.body);
        const entry = try self.narrowSave();
        defer self.temporary().free(entry);
        const iterable = (try self.lowerExpression(loop.iterable, false)) orelse return;
        const descriptor = self.analyzer.heapOf(iterable.value_type) orelse {
            try self.fail("luce.sema.loop", loop.span, "for iterates a list, a rank-1 array, or a map, not {s}{s}", .{
                try self.analyzer.typeName(iterable.value_type),
                try self.absenceAdvice(iterable.value_type, loop.iterable),
            });
            return;
        };
        // Each collection has a "position" (a map's key, or a
        // list/array's long index) and a "payload" (a map's value, or
        // the element).  `for x in c:` binds the payload for
        // sequences and the key for maps (Python's habit); `for a, b
        // in c:` binds position then payload.
        var payload_kind: mir.Intrinsic = .index_get;
        var position_kind: ?mir.Intrinsic = null; // null = the raw long index
        var position_type: Type = .long;
        const payload_type: Type = switch (descriptor) {
            .list => |element| element,
            .array => |shape| blk: {
                if (shape.rank != 1) {
                    try self.fail("luce.sema.loop", loop.span, "for iterates rank-1 arrays; index higher ranks explicitly", .{});
                    return;
                }
                break :blk shape.element;
            },
            .map => |pair| blk: {
                position_kind = .key_at;
                position_type = pair.key;
                payload_kind = .value_at;
                break :blk pair.value;
            },
            .builder => {
                try self.fail("luce.sema.loop", loop.span, "builder is not iterable", .{});
                return;
            },
            .file => {
                try self.fail("luce.sema.loop", loop.span, "file is not iterable; read into a buffer with f.read(buffer)", .{});
                return;
            },
        };

        try self.pushScope();
        defer self.popScope();
        var shape = try self.code.openIteration(iterable.value_type);

        // Which intrinsic and type each declared name binds to.
        const two_names = loop.value_name != null;
        const map_like = descriptor == .map;
        // Single name: payload for sequences, key for maps.  Two
        // names: first = position, second = payload.
        const first_kind: ?mir.Intrinsic = if (two_names or map_like) position_kind else payload_kind;
        const first_type: Type = if (two_names or map_like) position_type else payload_type;
        // A loop name holds a *view* of the element, and the body can
        // invalidate it: an element overwrite frees the old element
        // (S22), and unlike an object — whose handle would go stale
        // and trap — a string has no handle to check
        // (docs/STRINGS.md).  So a body that could free something a
        // container holds gives the name a copy of its own, released
        // at the top of the next iteration and at the end of the loop;
        // a body that provably cannot keeps the borrow, which is what
        // makes `for piece in pieces:` cost nothing.
        const keeps_view = !effects.blockMayMutateContainers(loop.body);
        const storage_class: StorageClass = if (keeps_view) .borrows else .owns;
        const name_local = (try self.declareLocalAs(
            loop.name,
            first_type,
            false,
            .alias,
            storage_class,
            loop.span,
        )) orelse return;
        const value_local: ?LocalId = if (two_names)
            (try self.declareLocalAs(
                loop.value_name.?,
                payload_type,
                false,
                .alias,
                storage_class,
                loop.span,
            )) orelse return
        else
            null;
        try self.code.startIteration(&shape, iterable.register);

        // Bind the first name: a getter intrinsic (key_at / index_get)
        // or the raw index when it is the list/array position.
        //
        // The owning form releases the previous iteration's copy
        // before storing this one; the slot starts empty, so the first
        // release frees nothing.
        const first_value = try self.code.iterationValue(shape, first_kind, first_type);
        try self.bindLoopName(name_local, first_value, first_type);
        // Bind the payload as a second name when present.
        if (value_local) |local| {
            const payload = try self.code.iterationValue(shape, payload_kind, payload_type);
            try self.bindLoopName(local, payload, payload_type);
        }
        try self.loops.append(self.temporary(), .{
            .continue_block = shape.step,
            .exit_block = shape.exit,
            .scope_depth = self.scopes.items.len,
            .temps_depth = self.temps.items.len,
        });
        // A named iterable is locked against reassignment for the
        // duration of the loop (restored below for outer loops).
        var iterated: ?[]const u8 = null;
        var was_iterating = false;
        if (loop.iterable.* == .name) {
            if (self.findLocal(loop.iterable.name.text)) |iterable_binding| {
                iterated = loop.iterable.name.text;
                was_iterating = iterable_binding.info.iterating;
                iterable_binding.info.iterating = true;
            }
        }
        try self.lowerBlock(loop.body);
        if (iterated) |name| {
            if (self.findLocal(name)) |iterable_binding| {
                iterable_binding.info.iterating = was_iterating;
            }
        }
        _ = self.loops.pop();
        try self.code.closeIteration(shape);
        // The loop names live in the scope pushed above, so the copy
        // the last iteration (or a `break`) left behind goes back here.
        try self.emitScopeEnd();
        try self.narrowRestore(entry);
    }

    fn lowerReturn(self: *FunctionBuilder, returned: ast.Return) Error!void {
        // A `var self` method's receiver rides out in front of
        // whatever the reader wrote, so every `return` in one is a
        // shape however many values it names — including a bare one
        // (docs/RETURNS.md §5).
        if (self.writes_receiver) return self.lowerReturnShape(returned);
        if (returned.values.len >= 2) return self.lowerReturnShape(returned);
        if (returned.values.len == 1) {
            const expression = returned.values[0];
            if (self.code.return_type == .none) {
                // Still lower it: an expression with a mistake in it
                // deserves its own message before this one.
                _ = try self.lowerExpression(expression, false);
                try self.fail("luce.sema.return", returned.span, "this function returns nothing", .{});
                return;
            }
            if (expression.* == .none_literal) {
                const absent = (try self.lowerTyped(
                    expression,
                    self.code.return_type,
                    returned.span,
                    "this function's result",
                )) orelse return;
                try self.emitTempReleases(0);
                try self.emitScopeReleases(0, &.{});
                try self.code.ret(absent.value.register);
                return;
            }
            if (self.results.len >= 2) {
                self.shape_position = .returning;
                _ = try self.lowerExpression(expression, false);
                try self.fail("luce.sema.return", returned.span, "{s} answers {d} values, got 1", .{
                    self.code.name, self.results.len,
                });
                return;
            }
            self.wanted = landingType(self.code.return_type);
            self.wanted_element = self.elementOf(self.code.return_type);
            const lowered = (try self.lowerExpression(expression, false)) orelse return;
            const value = (try self.fit(lowered, self.code.return_type)) orelse {
                try self.fail("luce.sema.type", returned.span, "returning {s} from a function returning {s}{s}", .{
                    try self.analyzer.typeName(lowered.value_type),
                    try self.analyzer.typeName(self.code.return_type),
                    try self.mismatchAdvice(self.code.return_type, lowered.value_type, expression),
                });
                return;
            };

            // Whatever a function returns, the caller owns (S16, S17):
            // an owned name moves out, fresh values flow out, borrows
            // are compile errors.
            var moved_storage: [1]LocalId = undefined;
            var moved: []const LocalId = &.{};
            if (self.analyzer.carriesObjects(value.value_type)) {
                switch (expression.*) {
                    .name => |name| {
                        // The name lowered to a value of an
                        // object-carrying type, so it is a local: a
                        // constant can never carry an object.  Said
                        // out loud rather than asserted, because a
                        // compiler that unwraps its beliefs crashes
                        // when one of them turns out to be wrong.
                        const found = self.findLocal(name.text) orelse return;
                        switch (found.info.class) {
                            .owned => {
                                moved_storage[0] = found.info.local;
                                moved = moved_storage[0..1];
                            },
                            .borrow_param => {
                                try self.fail(
                                    "luce.sema.own",
                                    returned.span,
                                    "{s} is a borrowed parameter; return copy {s}, or take the parameter as give [OWNERSHIP.md S17]",
                                    .{ name.text, name.text },
                                );
                                return;
                            },
                            .alias => {
                                try self.fail(
                                    "luce.sema.own",
                                    returned.span,
                                    "{s} aliases an object it does not own; return copy {s} or return the owning name [OWNERSHIP.md S16, S17]",
                                    .{ name.text, name.text },
                                );
                                return;
                            },
                        }
                    },
                    else => {
                        if (!(try self.yieldsOwnership(expression))) {
                            try self.fail(
                                "luce.sema.own",
                                returned.span,
                                "this object is borrowed from a container or struct; return a copy [OWNERSHIP.md S17, S22]",
                                .{},
                            );
                            return;
                        }
                        // The fresh return value was parked as a
                        // statement temporary; the object in it moves
                        // to the caller, so the unwinding below must
                        // not free it.  Its *storage* still goes back:
                        // the return took a copy of that
                        // (docs/STRINGS.md).
                        var index = self.temps.items.len;
                        while (index > 0) {
                            index -= 1;
                            // The park recorded the register before
                            // any `T <: T?` widening, which moves no
                            // bits and keeps the same object.
                            if (self.temps.items[index].register == lowered.register) {
                                if (self.temps.items[index].storage) {
                                    self.temps.items[index].objects = false;
                                } else {
                                    _ = self.temps.orderedRemove(index);
                                }
                                break;
                            }
                        }
                    },
                }
            }
            // Whatever a string-returning function hands back may be
            // a view of a parameter (`strings.trim` returns
            // `s[first:last]`) or of a local this frame is about to
            // release, and Luce has no annotation that tells them
            // apart — so `ret` copies, except where the value is
            // provably this statement's own (docs/STRINGS.md).
            var handed_out = try self.ownedForStore(value);
            // And whatever it is by then has to be able to leave: short
            // text lives in the value, a value lives in a slot, and
            // this frame's slots are about to go (docs/STRINGS.md).  A
            // struct's run and text that is already an allocation move
            // untouched, so the caller owns exactly the one allocation
            // it owned before short text lived in values at all.
            if (carriesText(value.value_type)) {
                handed_out = try self.code.exportStorage(handed_out);
            }
            try self.emitTempReleases(0);
            try self.emitScopeReleases(0, moved);
            try self.code.ret(handed_out);
            return;
        }
        if (self.code.return_type != .none) {
            try self.fail("luce.sema.return", returned.span, "return needs a value of type {s}", .{
                try self.analyzer.typeName(self.code.return_type),
            });
            return;
        }
        try self.emitTempReleases(0);
        try self.emitScopeReleases(0, &.{});
        try self.code.ret(null);
    }

    /// `return a, b` — S16 said once per value, and nothing more
    /// (OWNERSHIP.md S45, docs/RETURNS.md §3).
    ///
    /// Each value moves independently to the caller; a borrowed
    /// parameter or an alias in any position is S17 exactly and says
    /// so with the words it already had.  The one fact the single-value
    /// channel never had to state is that **the values must be distinct
    /// objects**: two moves of one handle would leave two caller
    /// bindings owning it and free it twice.  That is the only
    /// genuinely new check here, and it is where `moved` already is.
    fn lowerReturnShape(self: *FunctionBuilder, returned: ast.Return) Error!void {
        if (self.writes_receiver) return self.lowerReceiverReturn(returned);
        if (self.results.len < 2) {
            for (returned.values) |expression| _ = try self.lowerExpression(expression, false);
            if (self.results.len == 0) {
                try self.fail("luce.sema.return", returned.span, "this function returns nothing", .{});
                return;
            }
            try self.fail("luce.sema.return", returned.span, "{s} answers 1 value, got {d}", .{
                self.code.name, returned.values.len,
            });
            return;
        }
        if (returned.values.len != self.results.len) {
            for (returned.values) |expression| _ = try self.lowerExpression(expression, false);
            try self.fail("luce.sema.return", returned.span, "{s} answers {d} values, got {d}", .{
                self.code.name, self.results.len, returned.values.len,
            });
            return;
        }

        // One walk, so an operand that splits blocks cannot strand the
        // ones before it — the same rule every other operand run keeps.
        const values = (try self.lowerOperandsInto(returned.values, .{ .places = self.results })) orelse return;
        const registers = try self.arena().alloc(Register, values.len);

        var moved: std.ArrayList(LocalId) = .empty;
        defer moved.deinit(self.temporary());
        for (values, returned.values, 0..) |lowered, expression, position| {
            const value = (try self.fit(lowered, self.results[position])) orelse {
                try self.fail(
                    "luce.sema.type",
                    expression.span(),
                    "value {d} of this return is {s}, and {s} answers {s} there{s}",
                    .{
                        position + 1,
                        try self.analyzer.typeName(lowered.value_type),
                        self.code.name,
                        try self.analyzer.typeName(self.results[position]),
                        try self.absenceAdvice(lowered.value_type, expression),
                    },
                );
                return;
            };
            if (try self.movesOut(expression, value, &moved)) |register| {
                registers[position] = register;
            } else return;
        }

        // The shape is one value in the slot, so everything below the
        // comma is the single-value channel unchanged: the struct is
        // made here, it is what `ret` hands over, and the unwinder
        // skips every object it just gave away.
        const shape = try self.code.emit(
            .{ .struct_make = .{ .layout = self.code.return_type.strukt, .fields = registers } },
            self.code.return_type,
        );
        // Exported before the releases: the shape's field run and
        // whatever text rides in it have to be able to leave a frame
        // whose slots are about to go (docs/STRINGS.md).
        const handed_out = try self.code.exportStorage(shape);
        try self.emitTempReleases(0);
        try self.emitScopeReleases(0, moved.items);
        try self.code.ret(handed_out);
    }

    /// The implicit `return self` a `var self` method with no declared
    /// result ends on.  Written here rather than in stage 6 because it
    /// is a fact about the language, not about the tape.
    pub fn returnReceiver(self: *FunctionBuilder) Error!void {
        try self.lowerReceiverReturn(.{ .values = &.{}, .span = self.currentSpan() });
    }

    fn currentSpan(self: *const FunctionBuilder) Span {
        return .{ .start = self.code.origin, .end = self.code.origin };
    }

    /// `return` inside a `var self` method: the receiver goes out in
    /// front of whatever the reader wrote (docs/RETURNS.md §5).
    ///
    /// `func step(var self):` answers arity one — the receiver alone —
    /// and lowers exactly as `docs/METHODS.md` said it would.
    /// `func next(var self) -> long:` answers `(Rng, long)`, and the call
    /// site takes result zero back to the receiver's place and result
    /// one to the name.  There is one mechanism, not two.
    ///
    /// The receiver is a value struct that carries no objects — that is
    /// what `var self` requires — so the write-back is a pure value
    /// store and none of the ownership walk above applies to it.
    fn lowerReceiverReturn(self: *FunctionBuilder, returned: ast.Return) Error!void {
        if (returned.values.len != self.results.len) {
            for (returned.values) |expression| _ = try self.lowerExpression(expression, false);
            try self.fail("luce.sema.return", returned.span, "{s} answers {d} value{s}, got {d}", .{
                self.code.name,
                self.results.len,
                helpers.plural(self.results.len),
                returned.values.len,
            });
            return;
        }
        const receiver = self.findLocal("self") orelse return;

        // Arity one: the receiver alone, and the channel is the plain
        // single return the language already had.
        if (self.results.len == 0) {
            // Exported **before** the releases, not after: `self` owns
            // its run and the scope is about to give it back, so a
            // value read out afterwards would be a view of freed
            // storage.  This is the order the single-value return has
            // always kept (docs/STRINGS.md).
            const alone = try self.code.load(receiver.info.local);
            const handed_out = try self.code.exportStorage(try self.ownedForStore(.{
                .register = alone,
                .value_type = self.code.return_type,
            }));
            try self.emitTempReleases(0);
            try self.emitScopeReleases(0, &.{});
            try self.code.ret(handed_out);
            return;
        }

        // **The values first, and the receiver after them.**  A
        // returned expression may call another `var self` method on
        // `self` — `return low + self.next() % span` is the shape —
        // and reading the receiver before that runs would hand the
        // caller back the state the method started with.
        const values = (try self.lowerOperandsInto(returned.values, .{ .places = self.results })) orelse return;
        const registers = try self.arena().alloc(Register, values.len + 1);
        // The receiver goes into the shape as a *store*, so it takes
        // its storage first: `ownValue` deep-copies a struct's run, and
        // without that the shape would carry a view of the slot this
        // frame is about to release (docs/STRINGS.md).
        registers[0] = try self.ownedForStore(.{
            .register = try self.code.load(receiver.info.local),
            .value_type = self.channel[0],
        });
        var moved: std.ArrayList(LocalId) = .empty;
        defer moved.deinit(self.temporary());
        for (values, returned.values, 0..) |lowered, expression, position| {
            const value = (try self.fit(lowered, self.results[position])) orelse {
                try self.fail(
                    "luce.sema.type",
                    expression.span(),
                    "value {d} of this return is {s}, and {s} answers {s} there{s}",
                    .{
                        position + 1,
                        try self.analyzer.typeName(lowered.value_type),
                        self.code.name,
                        try self.analyzer.typeName(self.results[position]),
                        try self.absenceAdvice(lowered.value_type, expression),
                    },
                );
                return;
            };
            // The *declared* results may carry objects freely and move
            // under S16/S28 like any other return: a method may answer
            // a fresh list while writing back a value-only receiver,
            // and the two facts do not interact.
            if (try self.movesOut(expression, value, &moved)) |register| {
                registers[position + 1] = register;
            } else return;
        }
        const shape = try self.code.emit(
            .{ .struct_make = .{ .layout = self.code.return_type.strukt, .fields = registers } },
            self.code.return_type,
        );
        // Exported before the releases: the shape's field run and
        // whatever text rides in it have to be able to leave a frame
        // whose slots are about to go (docs/STRINGS.md).
        const handed_out = try self.code.exportStorage(shape);
        try self.emitTempReleases(0);
        try self.emitScopeReleases(0, moved.items);
        try self.code.ret(handed_out);
    }

    /// One position of a `return a, b`: check that this value may
    /// leave, record the binding whose object it takes with it, and
    /// answer the register to put in the shape.  Null after reporting.
    fn movesOut(
        self: *FunctionBuilder,
        expression: *const ast.Expression,
        value: Typed,
        moved: *std.ArrayList(LocalId),
    ) Error!?Register {
        if (!self.analyzer.carriesObjects(value.value_type)) {
            return try self.ownedForStore(value);
        }
        switch (expression.*) {
            .name => |name| {
                const found = self.findLocal(name.text) orelse return null;
                switch (found.info.class) {
                    .owned => {
                        // The genuinely new check.  `return` is a
                        // terminator, so with one value there was
                        // never anything after it to poison — the
                        // comma is what puts something after a return
                        // for the first time (docs/RETURNS.md §3).
                        if (std.mem.indexOfScalar(LocalId, moved.items, found.info.local) != null) {
                            try self.fail(
                                "luce.sema.own",
                                expression.span(),
                                "{s} is returned twice; one object cannot be owned twice [OWNERSHIP.md S23, S45]",
                                .{name.text},
                            );
                            return null;
                        }
                        try moved.append(self.temporary(), found.info.local);
                    },
                    .borrow_param => {
                        try self.fail(
                            "luce.sema.own",
                            expression.span(),
                            "{s} is a borrowed parameter; return copy {s}, or take the parameter as give [OWNERSHIP.md S17]",
                            .{ name.text, name.text },
                        );
                        return null;
                    },
                    .alias => {
                        try self.fail(
                            "luce.sema.own",
                            expression.span(),
                            "{s} aliases an object it does not own; return copy {s} or return the owning name [OWNERSHIP.md S16, S17]",
                            .{ name.text, name.text },
                        );
                        return null;
                    },
                }
            },
            else => {
                if (!(try self.yieldsOwnership(expression))) {
                    try self.fail(
                        "luce.sema.own",
                        expression.span(),
                        "this object is borrowed from a container or struct; return a copy [OWNERSHIP.md S17, S22]",
                        .{},
                    );
                    return null;
                }
                self.disownTemp(value.register);
            },
        }
        return try self.ownedForStore(value);
    }

    /// A fresh value this return is handing over: the object moves to
    /// the caller, so the statement's unwinding must not free it.  Its
    /// *storage* still goes back — the return took a copy of that
    /// (docs/STRINGS.md).
    fn disownTemp(self: *FunctionBuilder, register: Register) void {
        var index = self.temps.items.len;
        while (index > 0) {
            index -= 1;
            if (self.temps.items[index].register != register) continue;
            if (self.temps.items[index].storage) {
                self.temps.items[index].objects = false;
            } else {
                _ = self.temps.orderedRemove(index);
            }
            return;
        }
    }

    // Expressions: the dispatch --------------------------------------------
    //
    // The depth bound and the two-level switch every expression form
    // below is reached through.  The forms themselves are three
    // sections down; what sits between is the fallible-call machinery
    // a `try` or a `catch` is built out of.

    fn lowerExpression(self: *FunctionBuilder, expression: *ast.Expression, as_statement: bool) Error!?Typed {
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
        const objects = self.analyzer.carriesObjects(value.value_type) and
            try self.yieldsOwnership(expression) and
            !self.parkedAlready(value.register);
        // Freshly allocated storage is parked for the same reason and
        // in the same slot, but the two questions differ: `give s`
        // hands over an object while borrowing the struct run it sits
        // in, and a string slice borrows without yielding anything
        // (docs/STRINGS.md).
        const storage = self.analyzer.ownsStorage(value.value_type) and
            self.producesFreshStorage(value.register) and
            !self.parkedAlready(value.register);
        if (objects or storage) try self.registerTemp(value, objects, storage);
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
    fn lowerIntLiteral(
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
            return .{ .register = try self.code.emit(.{ .const_double = parsed }, lands), .value_type = lands };
        }
        const parsed = helpers.parseIntLiteral(literal.text, negated, lands) orelse {
            try self.fail("luce.sema.literal", span, "{s}", .{context.rangeMessage(lands)});
            return null;
        };
        return .{ .register = try self.code.emit(.{ .const_long = parsed }, lands), .value_type = lands };
    }

    fn lowerExpressionInner(self: *FunctionBuilder, expression: *ast.Expression, as_statement: bool) Error!?Typed {
        // The permission a `try` or `catch` raised reaches exactly the
        // expression it was written in front of.  Read and cleared
        // here, before anything nested can see it.
        const fallible_allowed = self.allow_fallible;
        self.allow_fallible = false;
        const shape_position = self.shape_position;
        self.shape_position = .refused;
        const wanted_element = self.wanted_element;
        self.wanted_element = null;
        const wanted = self.wanted;
        self.wanted = null;
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
                return .{ .register = try self.code.emit(.{ .const_double = parsed }, lands), .value_type = lands };
            },
            .bool_literal => |literal| {
                return .{ .register = try self.code.emit(.{ .const_boolean = literal.value }, .boolean), .value_type = .boolean };
            },
            .string_literal => |literal| {
                const constant = try self.analyzer.pool.intern(literal.decoded);
                return .{
                    .register = try self.code.emit(.{ .const_string = constant }, .string),
                    .value_type = .string,
                };
            },
            .name => |name| {
                const found = self.findLocal(name.text) orelse {
                    // Not a local: perhaps a file-scope constant.
                    const qualified = try self.analyzer.qualify(self.prefix, name.text);
                    if (self.analyzer.constant_names.get(qualified)) |constant| {
                        return self.emitConstant(constant);
                    }
                    try self.failUnknownName(name.text, name.span);
                    return null;
                };
                if (try self.checkPoisoned(found.info, name.text, name.span)) return null;
                const local = found.info.local;
                const local_type = self.code.localType(local);
                const loaded = try self.code.load(local);
                // A narrowed local reads as its payload: the value is
                // the same bits, and the flow analysis has already
                // proved it is there.
                if (local_type == .optional and self.isNarrowed(local)) {
                    const payload = local_type.held().?;
                    const arguments = try self.arena().alloc(Register, 1);
                    arguments[0] = loaded;
                    return .{
                        .register = try self.code.emit(
                            .{ .intrinsic = .{ .kind = .optional_unwrap, .arguments = arguments } },
                            payload,
                        ),
                        .value_type = payload,
                    };
                }
                return .{ .register = loaded, .value_type = local_type };
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
            .field => |field| return self.lowerField(field),
            .call => |call| return self.lowerCall(call, as_statement, fallible_allowed, shape_position, wanted),
            .binary => |binary| {
                if (binary.op == .catch_error) return self.lowerCatch(binary, as_statement);
                return self.lowerBinary(binary, wanted);
            },
            .unary => |unary| return self.lowerUnary(unary, wanted),
            .method => |method| return self.lowerMethod(method, as_statement, fallible_allowed, shape_position),
            .new_object => |new| return self.lowerNew(new),
            .list_literal => |literal| return self.lowerListLiteral(literal, wanted_element),
            .index => |index| return self.lowerIndex(index),
            .slice_range => |slice| return self.lowerSliceRange(slice),
            .give => |give| return self.lowerGive(give),
            .copy => |copied| return self.lowerCopy(copied),
            .try_call => |attempt| return self.lowerTry(attempt, as_statement, shape_position),
        }
    }

    // Errors ---------------------------------------------------------------
    //
    // A fallible call ends in three instructions: ask whether it came
    // back errored, carry its value across the branch, and take the
    // failing side to a block the `try` or `catch` in front of it
    // fills.  Everything below is about which of those two fills it.

    /// Close a fallible call: emit the question, the branch, and the
    /// reload, and leave the lowering on the side where the call
    /// returned.  The failing side is an empty block waiting for
    /// whoever asked for it.
    fn openFallible(self: *FunctionBuilder, call: Register, result_type: Type) Error!Typed {
        const failed = try self.code.errored(call);
        // What the call answered has to survive the branch on its
        // outcome, and it arrives owning something — so the slot that
        // carries it across *is* the slot that owns it (S3).  One
        // place, not two, and a string's form survives the crossing
        // because an owning slot holds a whole value; a borrowing one
        // would carry a pointer into whatever scratch the call
        // answered into (docs/STRINGS.md).
        const objects = self.analyzer.carriesObjects(result_type);
        const storage = self.analyzer.ownsStorage(result_type);
        const slot: ?LocalId = if (result_type == .none)
            null
        else
            try self.code.carry(call, result_type, storage);

        const handler = try self.code.reserveBlock();
        const returned = try self.code.reserveBlock();
        try self.code.branch(failed, handler, returned);
        self.code.switchTo(returned);
        // Taken before the temporary below is recorded: the failing
        // side releases what the statement owned *before* the call,
        // and this slot was never stored into on that path.
        self.opened = .{ .handler = handler, .temps_floor = self.temps.items.len };

        const carried = slot orelse return .{ .register = call, .value_type = .none };
        const reload = try self.code.load(carried);
        try self.carried.append(self.temporary(), .{ .register = reload, .origin = call });
        // The binding waits for this side too: on the failing side the
        // call answered no object, and naming one would name whatever
        // the slot happens to hold.
        if (objects) try self.code.bind(carried, reload);
        if (objects or storage) {
            try self.temps.append(self.temporary(), .{
                .local = carried,
                .register = reload,
                .objects = objects,
                .storage = storage,
                // This slot is reloaded above, so it must keep owning
                // its storage: a borrowing slot would hand the reload
                // the register shape, and short text does not survive
                // that (docs/STRINGS.md).
                .disownable = false,
            });
        }
        return .{ .register = reload, .value_type = result_type };
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
        if (!self.code.fallible) {
            try self.fail(
                "luce.sema.fallible",
                attempt.span,
                "try hands the error to the caller, and {s} does not say it can fail; write '-> !' (or '-> T!') on its signature, or handle it with catch",
                .{self.code.name},
            );
            return null;
        }

        const resume_at = self.code.current;
        self.code.switchTo(attempted.opened.handler);
        try self.emitTempReleasesUpTo(0, attempted.opened.temps_floor);
        try self.emitScopeReleases(0, &.{});
        try self.code.unwind();
        self.code.switchTo(resume_at);
        return attempted.value;
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
            const merge = try self.code.reserveBlock();
            try self.code.jump(merge);
            self.code.switchTo(attempted.opened.handler);
            try self.code.forget();
            const floor = self.temps.items.len;
            _ = try self.lowerExpression(binary.right, true);
            try self.flushTemps(floor);
            try self.code.jump(merge);
            self.code.switchTo(merge);
            return .{ .register = value.register, .value_type = .none };
        }

        // Both sides must agree on ownership, for the reason `else`
        // does: the binding that receives the result either owns an
        // object or does not, and that is one static fact (S1, S8).
        if (self.analyzer.carriesObjects(value.value_type) and
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

        const result = try self.code.hiddenLocal(value.value_type, false);
        const merge = try self.code.reserveBlock();
        try self.code.store(result, value.register);
        try self.code.jump(merge);

        self.code.switchTo(attempted.opened.handler);
        try self.code.forget();
        if (isLeavingCall(binary.right)) {
            // `f() catch trap("…")` and `f() catch error("…")` never
            // come back, so they leave nothing to store — the same
            // shape `x else trap("…")` has.
            _ = try self.lowerExpression(binary.right, true);
        } else if (try self.lowerTyped(binary.right, value.value_type, binary.span, "the catch fallback")) |fallback| {
            try self.code.store(result, fallback.value.register);
        }
        try self.code.jump(merge);

        self.code.switchTo(merge);
        return .{ .register = try self.code.load(result), .value_type = value.value_type };
    }

    /// `CALL catch:` and an indented handler — the statement form, for
    /// a recovery that is more than one expression — and `CALL catch
    /// NAME:`, which hands that handler the error's own words.
    fn lowerGuarded(self: *FunctionBuilder, guarded: ast.Guarded) Error!void {
        // The permission reaches the *value* of the statement, which
        // is the first expression either shape lowers: the call
        // itself, or the value side of `place = call()`.
        self.opened = null;
        self.allow_fallible = true;
        try self.lowerStatement(guarded.attempt.*);
        self.allow_fallible = false;
        const opened = self.opened orelse {
            // The binding is named in the refusal when there is one:
            // "drop the catch" is advice a reader has to translate into
            // "and the name with it", and the name is half of what they
            // wrote.
            if (guarded.binding) |binding| {
                try self.fail(
                    "luce.sema.fallible",
                    guarded.span,
                    "catch guards a call that can fail, and this statement has none; drop the catch, and {s} with it — there is no error for it to name",
                    .{binding.text},
                );
            } else {
                try self.fail(
                    "luce.sema.fallible",
                    guarded.span,
                    "catch guards a call that can fail, and this statement has none; drop the catch",
                    .{},
                );
            }
            return;
        };
        self.opened = null;

        const merge = try self.code.reserveBlock();
        try self.code.jump(merge);
        self.code.switchTo(opened.handler);

        // The binding lives in a scope of its own, wrapped around the
        // handler's: it is not one of the handler's statements, and a
        // `return` or a `break` out of the handler has to release it on
        // the way past like any other local (S1).
        //
        // **The whole read stands in front of `forget`**, copy
        // included.  `error_message` hands back a borrow of the words
        // and the store is what copies them (docs/STRINGS.md), and
        // while those words would in fact survive the clear — `forget`
        // nulls a pointer and the arena holding them goes with the run
        // — writing it this way means nothing here depends on that.
        // The channel is read, copied, and only then emptied.
        const binding = guarded.binding orelse {
            try self.code.forget();
            try self.lowerBlock(guarded.handler);
            try self.code.jump(merge);
            self.code.switchTo(merge);
            return;
        };
        try self.pushScope();
        const words = try self.code.errorMessage();
        if (try self.declareLocal(binding.text, .string, false, .alias, binding.span)) |local| {
            try self.storeOwned(local, .{ .register = words, .value_type = .string });
        }
        try self.code.forget();
        try self.lowerBlock(guarded.handler);
        try self.emitScopeEnd();
        self.popScope();
        try self.code.jump(merge);
        self.code.switchTo(merge);
    }

    // Expressions: one form at a time ---------------------------------------
    //
    // The ownership verbs, the constructors, the accessors and the
    // operators, in the order the dispatch above names them.  Calls and
    // methods are their own section further down, and the builtins one
    // after that.

    /// give NAME — the named object transfers to whatever receives it;
    /// the name is poisoned to the end of its scope (S10, S13, S29).
    fn lowerGive(self: *FunctionBuilder, give: ast.Give) Error!?Typed {
        if (give.operand.* != .name) {
            try self.fail(
                "luce.sema.own",
                give.span,
                "give moves a named object; use copy for other expressions [OWNERSHIP.md S10, S31]",
                .{},
            );
            return null;
        }
        const name = give.operand.name.text;
        const found = self.findLocal(name) orelse {
            try self.failUnknownName(name, give.operand.name.span);
            return null;
        };
        const info = found.info;
        const local = info.local;
        const local_type = self.code.localType(local);
        if (!info.carries) {
            try self.fail(
                "luce.sema.own",
                give.span,
                "give applies to objects (list, map, array, builder, object-carrying structs), not values [OWNERSHIP.md S32]",
                .{},
            );
            return null;
        }
        if (try self.checkPoisoned(info, name, give.span)) return null;
        if (info.class == .borrow_param) {
            try self.fail(
                "luce.sema.own",
                give.span,
                "{s} is a borrowed parameter and cannot be given; take it as give in the signature, or copy it [OWNERSHIP.md S12]",
                .{name},
            );
            return null;
        }
        // An alias owns nothing, so it has nothing to hand over (S8).
        // This used to be left to the runtime, which trapped
        // `not_owned` at the give; the class is known right here, so
        // the answer is given here instead (S23).
        if (info.class == .alias) {
            if (self.ownerNameFor(info)) |owner| {
                try self.fail(
                    "luce.sema.own",
                    give.span,
                    "{s} aliases an object it does not own; give {s} (the owner), or copy {s} [OWNERSHIP.md S8, S23]",
                    .{ name, owner, name },
                );
            } else {
                try self.fail(
                    "luce.sema.own",
                    give.span,
                    "{s} aliases an object it does not own; give the owning name, or copy {s} [OWNERSHIP.md S8, S23]",
                    .{ name, name },
                );
            }
            return null;
        }
        if (self.loops.items.len > 0 and
            found.depth < self.loops.items[self.loops.items.len - 1].scope_depth)
        {
            try self.fail(
                "luce.sema.own",
                give.span,
                "{s} is declared outside this loop; the next iteration would use a given-away name — create it fresh inside the loop, or copy [OWNERSHIP.md S30]",
                .{name},
            );
            return null;
        }
        // An object that might not be there cannot be handed over: the
        // receiver would own a question, not a thing.  Narrowing is
        // what turns it back into a thing.
        if (local_type == .optional and !self.isNarrowed(local)) {
            try self.failAbsence(give.span, "give", local_type, give.operand);
            return null;
        }
        info.poisoned = .given;
        var value = try self.code.load(local);
        // A narrowed `T?` hands over the `T` it was proved to hold.
        const given_type = local_type.held() orelse local_type;
        if (local_type == .optional) {
            const unwrap = try self.arena().alloc(Register, 1);
            unwrap[0] = value;
            value = try self.code.emit(
                .{ .intrinsic = .{ .kind = .optional_unwrap, .arguments = unwrap } },
                given_type,
            );
        }
        // Every class but `.owned` was refused above, so the give
        // always names its binding and the runtime always has an owner
        // to check it against.  The intrinsic still accepts the
        // unnamed form, which is now reachable only from a module that
        // did not come from this stage (`06_mir/verify.zig` trusts
        // instruction types); the runtime keeps the container backstop
        // for it.
        const arguments = try self.arena().alloc(Register, 2);
        arguments[0] = value;
        arguments[1] = try self.code.emit(.{ .const_long = local }, .long);
        return .{
            .register = try self.code.emit(
                .{ .intrinsic = .{ .kind = .give_object, .arguments = arguments } },
                given_type,
            ),
            .value_type = given_type,
        };
    }

    /// Inline a folded file-scope constant at this use site.
    fn emitConstant(self: *FunctionBuilder, index: u32) Error!?Typed {
        const info = self.analyzer.constant_infos.items[index];
        if (info.state != .ready) return null; // already diagnosed
        return .{
            .register = try self.emitConstantValue(info.value, info.value_type),
            .value_type = info.value_type,
        };
    }

    fn emitConstantValue(self: *FunctionBuilder, value: ConstantValue, value_type: Type) Error!Register {
        return switch (value) {
            // The width is the constant's own, not the widest of its
            // family: a folded constant carries its value at the
            // family's widest member and its `value_type` says where
            // that value landed (docs/TYPES.md §1).
            .long => |folded| try self.code.emit(.{ .const_long = folded }, value_type),
            .double => |folded| try self.code.emit(.{ .const_double = folded }, value_type),
            .boolean => |folded| try self.code.emit(.{ .const_boolean = folded }, .boolean),
            .string => |folded| blk: {
                const constant = try self.analyzer.pool.intern(folded);
                break :blk try self.code.emit(
                    .{ .const_string = constant },
                    .string,
                );
            },
            .strukt => |folded| blk: {
                const layout = self.analyzer.structs.items[folded.layout];
                const fields = try self.arena().alloc(Register, folded.fields.len);
                for (folded.fields, layout.fields, fields) |field, field_layout, *slot| {
                    const made = try self.emitConstantValue(field, field_layout.field_type);
                    slot.* = try self.ownedForStore(.{
                        .register = made,
                        .value_type = field_layout.field_type,
                    });
                }
                break :blk try self.code.emit(
                    .{ .struct_make = .{ .layout = folded.layout, .fields = fields } },
                    value_type,
                );
            },
            // The typed absence a `T?` place gives a bare `none`: the
            // constant's type is the whole of its value (docs/ARGS.md
            // D9), and it inlines as the same zero `lowerTyped` emits.
            .absent => try self.code.zeroOf(value_type),
        };
    }

    /// copy EXPR — a deep, independent duplicate; always legal on
    /// readable objects (S31).
    fn lowerCopy(self: *FunctionBuilder, copied: ast.Copy) Error!?Typed {
        const value = (try self.lowerExpression(copied.operand, false)) orelse return null;
        // Copying a question makes no sense: there may be nothing to
        // duplicate.  Test it first.
        if (try self.refusesAbsence(value, "copy", copied.span, copied.operand)) return null;
        if (!self.analyzer.carriesObjects(value.value_type)) {
            try self.fail(
                "luce.sema.own",
                copied.span,
                "copy applies to objects (list, map, array, builder, object-carrying structs); values copy by themselves [OWNERSHIP.md S32]",
                .{},
            );
            return null;
        }
        // **A file cannot be copied** (docs/BYTES.md R5).  A copy is a
        // second object that owns its own contents, and there is only
        // one open file behind a handle: two Luce handles on it would
        // be two owners of one resource, which is the thing scope
        // ownership exists to make impossible.  `give` is the verb
        // that moves one.
        if (value.value_type == .heap and
            self.analyzer.heap_types.items[value.value_type.heap] == .file)
        {
            try self.fail(
                "luce.sema.own",
                copied.span,
                "a file cannot be copied; there is one open file behind a handle — give it instead [BYTES.md R5]",
                .{},
            );
            return null;
        }
        const arguments = try self.arena().alloc(Register, 1);
        arguments[0] = value.register;
        return .{
            .register = try self.code.emit(
                .{ .intrinsic = .{ .kind = .copy_object, .arguments = arguments } },
                value.value_type,
            ),
            .value_type = value.value_type,
        };
    }

    fn lowerNew(self: *FunctionBuilder, new: ast.NewObject) Error!?Typed {
        var object_type: Type = undefined;
        var dims: []Register = &.{};
        if (types.builtinNamed(new.type_name.name) == .array) {
            if (new.dims.len == 0 or new.dims.len > 4) {
                try self.fail("luce.sema.new", new.span, "new array takes 1 to 4 dimension sizes: new array(long, 5, 5)", .{});
                return null;
            }
            const element = (try self.analyzer.resolveType(self.module, new.type_name.arguments[0])) orelse return null;
            // `new array(T, n)` spells its shape with expressions, so
            // it interns the heap type here rather than through the
            // written-type path — and needs the same refusal.
            if (try self.analyzer.refuseOptionalPart(element, new.type_name.arguments[0], "array element")) {
                return null;
            }
            object_type = try self.analyzer.internHeapType(.{
                .array = .{ .element = element, .rank = @intCast(new.dims.len) },
            });
            dims = try self.arena().alloc(Register, new.dims.len);
            const dimensions = (try self.lowerOperands(new.dims)) orelse return null;
            for (dimensions, new.dims, dims) |*dimension, expression, *register| {
                if (!try self.widensInto(dimension, .long)) {
                    try self.fail("luce.sema.new", expression.span(), "array dimensions are long", .{});
                    return null;
                }
                register.* = dimension.register;
            }
        } else {
            object_type = (try self.analyzer.resolveType(self.module, new.type_name)) orelse return null;
            if (object_type != .heap) {
                try self.fail("luce.sema.new", new.span, "new builds list, map, array, or builder", .{});
                return null;
            }
            // **A file is opened, never made** (docs/BYTES.md R5).  A
            // handle with no file behind it is the one thing this type
            // must never hold, so the only way in is the door that
            // takes a path.
            if (self.analyzer.heap_types.items[object_type.heap] == .file) {
                try self.fail(
                    "luce.sema.new",
                    new.span,
                    "a file is opened, not made; write files.open(path) [BYTES.md R5]",
                    .{},
                );
                return null;
            }
        }
        return .{
            .register = try self.code.emit(.{ .heap_new = .{ .heap = object_type.heap, .dims = dims } }, object_type),
            .value_type = object_type,
        };
    }

    /// `[a, b, c]`.  `wanted` is the element type the place this
    /// literal is going into names, when it names one; without it the
    /// first element decides, exactly as it always has.
    fn lowerListLiteral(self: *FunctionBuilder, literal: ast.ListLiteral, wanted: ?Type) Error!?Typed {
        if (literal.elements.len == 0) {
            try self.fail(
                "luce.sema.type",
                literal.span,
                "an empty [] needs an annotated binding (var xs: list(long) = []) or new list(T)",
                .{},
            );
            return null;
        }
        // **The elements land on the element type when the place names
        // one.**  A literal has no type until it meets one
        // (docs/TYPES.md §1), and what it meets here is the annotation:
        // without this, `var xs: list(byte) = [1, 2, 3]` reads its
        // three literals at `int` and is then refused for narrowing
        // nobody wrote.  That was invisible while every element type
        // was `long` or wider; `list(byte)` at one byte an element
        // (docs/BYTES.md R1) is what made it reachable, and the same
        // landing is what `xs.append(1)` has always had.
        const landing: Landing = if (wanted) |element| places: {
            const places = try self.arena().alloc(Type, literal.elements.len);
            @memset(places, element);
            break :places .{ .places = places };
        } else .nothing;
        const elements = (try self.lowerOperandsInto(literal.elements, landing)) orelse
            return null;
        const element_type = wanted orelse unified: {
            // The elements meet where two operands of an operator meet
            // and for the same reason: `[1, 2.5]` and `[2.5, 1]` are
            // the same list, as `1 + 2.5` and `2.5 + 1` are the same
            // sum (docs/TYPES.md §2).  A non-numeric element stops the
            // fold and the first element decides, which is what the
            // mismatch below then reports.
            var meeting = elements[0].value_type;
            for (elements[1..]) |element| {
                meeting = Type.unified(meeting, element.value_type) orelse
                    break :unified elements[0].value_type;
            }
            break :unified meeting;
        };
        for (elements, literal.elements) |*element, expression| {
            // A `list(double)` takes narrower elements by widening
            // them, and so does a list the fold above landed on
            // (docs/TYPES.md §2): `[1.5, 2]` is a `list(double)`.
            if (element.value_type.widensTo(element_type)) {
                element.* = try self.widenNumeric(element.*, element_type);
            }
            if (!element.value_type.eql(element_type)) {
                try self.fail("luce.sema.type", expression.span(), "list elements are all {s}, got {s}", .{
                    try self.analyzer.typeName(element_type),
                    try self.analyzer.typeName(element.value_type),
                });
                return null;
            }
            // A literal is a container door like any other (S20, S21):
            // object elements must be fresh, given, or copied.
            if (self.analyzer.carriesObjects(element.value_type) and
                !(try self.yieldsOwnership(expression)))
            {
                try self.failNeedsOwnership(
                    expression.span(),
                    "a list literal keeps its object elements",
                    expression,
                    "S21",
                );
                return null;
            }
        }
        const object_type = try self.analyzer.internHeapType(.{ .list = element_type });
        const list = try self.code.emit(.{ .heap_new = .{ .heap = object_type.heap, .dims = &.{} } }, object_type);
        for (elements) |element| {
            const arguments = try self.arena().alloc(Register, 2);
            arguments[0] = list;
            arguments[1] = try self.ownedForStore(element);
            _ = try self.code.emit(.{ .intrinsic = .{ .kind = .append_value, .arguments = arguments } }, .none);
        }
        return .{ .register = list, .value_type = object_type };
    }

    fn lowerIndex(self: *FunctionBuilder, index: ast.Index) Error!?Typed {
        const expressions = try self.arena().alloc(*ast.Expression, index.indices.len + 1);
        expressions[0] = index.target;
        @memcpy(expressions[1..], index.indices);
        const values = (try self.lowerOperandsInto(expressions, .subscripts)) orelse return null;
        const element_type = (try self.checkIndex(values[0], values[1..], index.span)) orelse return null;
        const arguments = try self.arena().alloc(Register, values.len);
        for (values, arguments) |value, *slot| slot.* = value.register;
        return .{
            .register = try self.code.emit(
                .{ .intrinsic = .{ .kind = .index_get, .arguments = arguments } },
                element_type,
            ),
            .value_type = element_type,
        };
    }

    fn lowerSliceRange(self: *FunctionBuilder, slice: ast.SliceRange) Error!?Typed {
        var whole_sequence: std.ArrayList(*ast.Expression) = .empty;
        defer whole_sequence.deinit(self.temporary());
        try whole_sequence.append(self.temporary(), slice.target);
        if (slice.start) |expression| try whole_sequence.append(self.temporary(), expression);
        if (slice.end) |expression| try whole_sequence.append(self.temporary(), expression);
        const sequence = (try self.lowerOperandsInto(whole_sequence.items, .subscripts)) orelse return null;
        const target = sequence[0];
        const is_string = target.value_type == .string;
        const descriptor = self.analyzer.heapOf(target.value_type);
        if (!is_string and (descriptor == null or descriptor.? != .list)) {
            try self.fail("luce.sema.index", slice.span, "{s} cannot be sliced; slices work on list and string", .{
                try self.analyzer.typeName(target.value_type),
            });
            return null;
        }

        const lowered_bounds = sequence[1..];
        for (lowered_bounds) |*value| {
            if (!try self.widensInto(value, .long)) {
                try self.fail("luce.sema.type", slice.span, "slice bounds are long", .{});
                return null;
            }
        }
        var next_bound: usize = 0;
        var start: Register = undefined;
        if (slice.start != null) {
            start = lowered_bounds[next_bound].register;
            next_bound += 1;
        } else {
            start = try self.code.emit(.{ .const_long = 0 }, .long);
        }
        var end: Register = undefined;
        if (slice.end != null) {
            end = lowered_bounds[next_bound].register;
        } else {
            const whole = try self.arena().alloc(Register, 1);
            whole[0] = target.register;
            end = try self.code.emit(.{ .intrinsic = .{ .kind = .len, .arguments = whole } }, .long);
        }

        const arguments = try self.arena().alloc(Register, 3);
        arguments[0] = target.register;
        arguments[1] = start;
        arguments[2] = end;
        const kind: mir.Intrinsic = if (is_string) .string_slice else .list_slice;
        return .{
            .register = try self.code.emit(.{ .intrinsic = .{ .kind = kind, .arguments = arguments } }, target.value_type),
            .value_type = target.value_type,
        };
    }

    /// `Method.stored` — an enum member, as the constant it is
    /// (docs/ENUMS.md D3, D8).  Null when the dotted head names no
    /// enum, which leaves every other reading of a `.` to the caller.
    ///
    /// The lookup is the head-names-a-declaration path `Struct.func`
    /// and `module.name` already travel: a head that a local shadows is
    /// a value, a bare head is this module's, and one dotted level
    /// reaches an imported enum.
    fn enumMemberAccess(self: *FunctionBuilder, field: ast.FieldAccess) Error!MemberAccess {
        const chain = helpers.dottedChain(field.target) orelse return .not_a_member;
        if (self.findLocal(chain.head()) != null) return .not_a_member;

        var written: std.ArrayList(u8) = .empty;
        defer written.deinit(self.temporary());
        var at = chain.count;
        while (at > 0) {
            at -= 1;
            if (written.items.len != 0) try written.append(self.temporary(), '.');
            try written.appendSlice(self.temporary(), chain.parts[at]);
        }
        const spelled = written.items;

        // A bare name is this module's; a dotted one is an import's,
        // and only an imported module may be the head.
        const index = found: {
            if (chain.count == 1) {
                const local = try self.analyzer.qualify(self.prefix, spelled);
                break :found self.analyzer.enum_names.get(local) orelse return .not_a_member;
            }
            if (!self.analyzer.importsModule(self.module, chain.head())) return .not_a_member;
            break :found self.analyzer.enum_names.get(spelled) orelse return .not_a_member;
        };
        const info = self.analyzer.enum_decls.items[index];
        if (info.declaration.visibility == .private and info.module != self.module) {
            try self.fail("luce.sema.private", field.span, "{s} is private to {s}", .{
                info.declaration.name,
                self.analyzer.moduleName(info.module),
            });
            return .reported;
        }
        const declared = self.analyzer.enums.items[index];
        const of = self.analyzer.enumType(index);
        const member = declared.findMember(field.name) orelse {
            // `Method.deflated()` written without its parentheses is a
            // function of the enum, and it is not a value either
            // (docs/METHODS.md); the shared sentence says so.
            const qualified = try std.fmt.allocPrint(self.arena(), "{s}.{s}", .{ declared.name, field.name });
            const spelling = try std.fmt.allocPrint(self.arena(), "{s}.{s}", .{ spelled, field.name });
            if (try self.failNotAValue(spelling, qualified, field.span)) return .reported;
            try self.failUnknownMember(declared, field.name, field.span);
            return .reported;
        };
        return .{ .value = .{
            .register = try self.code.emit(.{ .const_long = declared.members[member].value }, of),
            .value_type = of,
        } };
    }

    /// What a dotted access turned out to be: not an enum member at
    /// all, one that was refused and reported, or the member's value.
    /// The middle case is why this is not an optional — a name that was
    /// already answered must not be lowered a second time as something
    /// else, which is how one mistake became two messages.
    const MemberAccess = union(enum) {
        not_a_member,
        reported,
        value: Typed,
    };

    fn lowerField(self: *FunctionBuilder, field: ast.FieldAccess) Error!?Typed {
        // A dotted chain whose head is a bare declaration name is a
        // namespace, exactly as it is in front of a call
        // (`methodNamespace`).  Without this the whole access falls
        // through to lowering the head as a value, which reports
        // "unknown name math" about an import the compiler just
        // checked.  Locals shadow nothing, so a head that names a
        // local is always a value.
        // `Method.stored`, `zip.Method.stored` — a member, which is a
        // constant of the enum's own type and namespaced always
        // (docs/ENUMS.md D3, D8).  It is asked first because it is the
        // one dotted form whose head names a *type* and whose answer is
        // a value; everything below reads a field of one.
        switch (try self.enumMemberAccess(field)) {
            .not_a_member => {},
            .reported => return null,
            .value => |member| return member,
        }
        if (field.target.* == .name and self.findLocal(field.target.name.text) == null) {
            const base = field.target.name.text;
            if (self.analyzer.importsModule(self.module, base)) {
                const joined = try std.fmt.allocPrint(self.arena(), "{s}.{s}", .{ base, field.name });
                // geo.pi — an imported module's file-scope constant.
                if (self.analyzer.constant_names.get(joined)) |constant| {
                    const info = self.analyzer.constant_infos.items[constant];
                    if (info.declaration.visibility == .private and info.module != self.module) {
                        try self.fail("luce.sema.private", field.span, "{s} is private to {s}", .{
                            field.name,
                            self.analyzer.moduleName(info.module),
                        });
                        return null;
                    }
                    return self.emitConstant(constant);
                }
                try self.failNamespaceMember(base, field.name, joined, field.span);
                return null;
            }
            // Words.classify — a struct of this module as a namespace.
            const head_qualified = try self.analyzer.qualify(self.prefix, base);
            if (self.analyzer.struct_names.contains(head_qualified)) {
                const joined = try std.fmt.allocPrint(self.arena(), "{s}.{s}", .{ head_qualified, field.name });
                try self.failNamespaceMember(base, field.name, joined, field.span);
                return null;
            }
        }
        const target = (try self.lowerExpression(field.target, false)) orelse return null;
        if (target.value_type != .strukt) {
            try self.fail("luce.sema.field", field.span, "{s} has no fields{s}", .{
                try self.analyzer.typeName(target.value_type),
                try self.absenceAdvice(target.value_type, field.target),
            });
            return null;
        }
        const layout_index = target.value_type.strukt;
        const layout = self.analyzer.structs.items[layout_index];
        const field_index = layout.findField(field.name) orelse {
            // `let f = p.length` — a *bound method value*, which is a
            // closure over `p` by another name and first among the
            // things docs/LANGUAGE.md deliberately does not have.  The
            // sentence is the one `let f = Point.length` already gets,
            // reached through the same helper (docs/METHODS.md).
            const member = try std.fmt.allocPrint(self.arena(), "{s}.{s}", .{ layout.name, field.name });
            // Spelled the way the reader wrote it where the receiver
            // has a name, and by its struct where it does not:
            // "the receiver.length" is not a phrase anybody typed.
            const written = switch (field.target.*) {
                .name => |name| try std.fmt.allocPrint(self.arena(), "{s}.{s}", .{ name.text, field.name }),
                else => member,
            };
            if (try self.failNotAValue(written, member, field.span)) return null;
            try self.failUnknownField("luce.sema.field", layout_index, field.name, field.span);
            return null;
        };
        if (!try self.fieldReachable(layout_index, field_index, field.span)) return null;
        const field_type = layout.fields[field_index].field_type;
        return .{
            .register = try self.code.emit(.{ .struct_get = .{
                .target = target.register,
                .layout = layout_index,
                .field = field_index,
            } }, field_type),
            .value_type = field_type,
        };
    }

    /// The two sides of an operator, each landing where it should.
    ///
    /// Two rules, and between them they are the whole of "a number has
    /// no type until it meets one" (docs/TYPES.md D3) inside an
    /// operator:
    ///
    ///   * **Both sides untyped** — `2 * 0.1` — and the *place* the
    ///     whole expression lands in decides, so `let x: double =
    ///     2 * 0.1` computes at binary64 throughout.  `wanted` is
    ///     pushed into both and reaches every literal under them.
    ///   * **One side typed** — `x * 0.1` — and that side decides,
    ///     because what the literal met is `x`.  This is Go's rule and
    ///     Luce needs it for Go's reason: without it the literal takes
    ///     the default `float`, and `double_x * float(0.1)` is not
    ///     `double_x * 0.1` — binary32's nearest 0.1 is a different
    ///     number, and the widening that follows cannot put back what
    ///     the parse threw away.
    ///
    /// In the second case the typed side is lowered **first**, so its
    /// type is known before the literal is parsed.  That reorders
    /// nothing observable: the sides swap only when one of them is a
    /// constant expression over literals, which evaluates to itself
    /// with no effects, no calls and no traps.
    ///
    /// `04_semantics/declarations.zig` folds a file-scope `let` by the
    /// same two rules, because the two must agree about what `2 * 0.1`
    /// is.
    fn lowerBinaryOperands(
        self: *FunctionBuilder,
        binary: ast.Binary,
        wanted: ?Type,
    ) Error!?[]Typed {
        const left_untyped = helpers.isUntypedNumber(binary.left);
        const right_untyped = helpers.isUntypedNumber(binary.right);
        if (left_untyped and right_untyped) {
            const values = try self.arena().alloc(Typed, 2);
            const expressions = [_]*ast.Expression{ binary.left, binary.right };
            for (expressions, 0..) |expression, index| {
                if (wanted) |place| self.wanted = landingType(place);
                values[index] = (try self.lowerExpression(expression, false)) orelse return null;
            }
            return values;
        }
        if (left_untyped == right_untyped) {
            return self.lowerOperands(&.{ binary.left, binary.right });
        }
        const values = try self.arena().alloc(Typed, 2);
        const written_first: usize = if (left_untyped) 1 else 0;
        const written_second: usize = 1 - written_first;
        const expressions = [_]*ast.Expression{ binary.left, binary.right };
        values[written_first] =
            (try self.lowerExpression(expressions[written_first], false)) orelse return null;
        if (landingType(values[written_first].value_type)) |place| self.wanted = place;
        values[written_second] =
            (try self.lowerExpression(expressions[written_second], false)) orelse return null;
        return values;
    }

    fn lowerBinary(self: *FunctionBuilder, binary: ast.Binary, wanted: ?Type) Error!?Typed {
        switch (binary.op) {
            .logic_and, .logic_or => return self.lowerShortCircuit(binary),
            .coalesce => return self.lowerCoalesce(binary),
            else => {},
        }
        if (binary.left.* == .none_literal or binary.right.* == .none_literal) {
            return self.lowerAbsenceTest(binary);
        }
        // Operators borrow their operands (S11); a give here would
        // hand the object to nobody.
        if (binary.left.* == .give or binary.right.* == .give) {
            try self.fail(
                "luce.sema.own",
                binary.span,
                "operators only borrow their operands; give needs an owning destination [OWNERSHIP.md S13]",
                .{},
            );
            return null;
        }
        const sides = (try self.lowerBinaryOperands(binary, wanted)) orelse return null;
        var left = sides[0];
        var right = sides[1];

        const operation: mir.BinaryOp = switch (binary.op) {
            .add => .add,
            .subtract => .subtract,
            .multiply => .multiply,
            .divide => .divide,
            .floor_divide => .floor_divide,
            .modulo => .modulo,
            .equal => .equal,
            .not_equal => .not_equal,
            .less => .less,
            .less_equal => .less_equal,
            .greater => .greater,
            .greater_equal => .greater_equal,
            .bit_and => .bit_and,
            .bit_or => .bit_or,
            .bit_xor => .bit_xor,
            .shift_left => .shift_left,
            .shift_right => .shift_right,
            .logic_and, .logic_or, .coalesce, .catch_error => unreachable, // answered above
        };

        // Numbers that mix (docs/TYPES.md §2).  Arithmetic brings them
        // to the type they meet at; a comparison **across the
        // ladders** does not widen at all — it is exact, and leaves
        // through its own instruction.  A comparison along one ladder
        // is an ordinary widening, because widening within a family
        // loses nothing.
        //
        // **Two numbers unify even when they are already the same
        // type**, which is what D5 needs and equality alone would
        // miss: `byte + byte` and `half * half` have equal operands
        // and must still leave as an `int` and a `float`, because no
        // expression ever has a storage type.  `unifyNumeric` moves
        // only what has to move, so a `long + long` is untouched.
        if (left.value_type.isNumeric() and right.value_type.isNumeric()) {
            const crosses = left.value_type.isInteger() != right.value_type.isInteger();
            if (crosses and operation.isComparison()) {
                return self.lowerExactCompare(operation, left, right);
            }
            _ = try self.unifyNumeric(&left, &right);
        }

        // `/` is **real division** and always answers a float, so two
        // integers widen here too and there is no integer `/` left in
        // the IR (docs/NUMERICS.md §2).  `1 / 2` is `0.5`; the
        // quotient that answers `0` is `1 // 2`.
        //
        // They widen to `double` at **either** integer width, which is
        // the cross-family rule and not a special case: `int / int` is
        // a `double` because that is where an integer meets a float,
        // and a `float` result would lose everything above 2^24 from
        // operands that reach it (docs/TYPES.md §2).
        if (operation == .divide and left.value_type.isInteger() and right.value_type.isInteger()) {
            left = try self.widenNumeric(left, .double);
            right = try self.widenNumeric(right, .double);
        }

        if (!left.value_type.eql(right.value_type)) {
            const absent = if (left.value_type == .optional) left else right;
            const written = if (left.value_type == .optional) binary.left else binary.right;
            try self.fail("luce.sema.type", binary.span, context.mismatched_operands_message ++ "{s}", .{
                context.operatorText(binary.op),
                try self.analyzer.typeName(left.value_type),
                try self.analyzer.typeName(right.value_type),
                try self.absenceAdvice(absent.value_type, written),
            });
            return null;
        }
        const operand_type = left.value_type;

        // An operator wants a value, and a `T?` may not be one.  Said
        // here rather than left to "does not support this operator",
        // because the fix is narrowing and the reader needs told.
        if (try self.refusesAbsence(left, "this operator", binary.span, binary.left)) return null;
        if (try self.refusesAbsence(right, "this operator", binary.span, binary.right)) return null;

        const arithmetic = switch (operation) {
            .add,
            .subtract,
            .multiply,
            .divide,
            .floor_divide,
            .modulo,
            .bit_and,
            .bit_or,
            .bit_xor,
            .shift_left,
            .shift_right,
            => true,
            else => false,
        };
        if (arithmetic) {
            // The bit set operates on the integers and nothing else
            // (docs/BITWISE.md D2): a double has no bits a program may
            // see, and the sentence says which fact refused it.
            switch (operation) {
                .bit_and, .bit_or, .bit_xor, .shift_left, .shift_right => {
                    if (operand_type != .int and operand_type != .long) {
                        try self.fail(
                            "luce.sema.type",
                            binary.span,
                            "{s} works on int and long; {s} has no bits a program may see",
                            .{
                                context.operatorText(binary.op),
                                try self.analyzer.typeName(operand_type),
                            },
                        );
                        return null;
                    }
                },
                else => {},
            }
            const string_concat = operation == .add and operand_type == .string;
            if (!operand_type.isNumeric() and !string_concat) {
                try self.fail("luce.sema.type", binary.span, "{s} does not support this operator", .{
                    try self.analyzer.typeName(operand_type),
                });
                return null;
            }
            return .{
                .register = try self.code.emit(.{ .binary = .{
                    .op = operation,
                    .operand_type = operand_type,
                    .left = left.register,
                    .right = right.register,
                } }, operand_type),
                .value_type = operand_type,
            };
        }

        // Comparisons: equality everywhere; ordering for long, double,
        // and string.
        const ordering = operation != .equal and operation != .not_equal;
        if (ordering and !(operand_type.isNumeric() or operand_type == .string)) {
            // **An enum is a set of names, not a number line**
            // (docs/ENUMS.md D6), and the reader who wanted the numbers
            // is one word away from having them — so the sentence says
            // the word rather than stopping at "has no ordering".
            if (operand_type == .enumeration) {
                try self.fail(
                    "luce.sema.type",
                    binary.span,
                    "{s} is a set of names and has no order; write int({s}) {s} int({s}) to compare the numbers behind them",
                    .{
                        try self.analyzer.typeName(operand_type),
                        try self.writtenTarget(binary.left),
                        context.operatorText(binary.op),
                        try self.writtenTarget(binary.right),
                    },
                );
                return null;
            }
            try self.fail("luce.sema.type", binary.span, "{s} has no ordering", .{
                try self.analyzer.typeName(operand_type),
            });
            return null;
        }
        if (operand_type == .none) {
            try self.fail("luce.sema.type", binary.span, "value has no type", .{});
            return null;
        }
        return .{
            .register = try self.code.emit(.{ .binary = .{
                .op = operation,
                .operand_type = operand_type,
                .left = left.register,
                .right = right.register,
            } }, .boolean),
            .value_type = .boolean,
        };
    }

    /// `1 < 1.5`, `9007199254740993 == 9007199254740992.0`: a
    /// comparison whose sides sit on different ladders compares the
    /// **numbers** and not a conversion of them (docs/NUMERICS.md §5).
    ///
    /// Four pairs reach here now — `{int, long} x {float, double}` —
    /// and one function answers all four, because widening the integer
    /// to `i64` and the float to `f64` is lossless by construction.
    /// So the operands widen into the pair the intrinsic already
    /// speaks and nothing new is written (docs/TYPES.md §5).
    ///
    /// **An `int` against a `double` skips the call.**  Every i32 is
    /// exactly representable in binary64, so widening decides it and
    /// an ordinary `fcmp` is the whole comparison — an optimisation
    /// the two-type language could not have, because it had no integer
    /// narrower than the mantissa.
    ///
    /// The runtime answers one shape — the integer first — so an
    /// operator written the other way round is **mirrored** rather
    /// than given a second implementation.  Only the ordering
    /// operators have a mirror image; equality is its own.
    fn lowerExactCompare(
        self: *FunctionBuilder,
        operation: mir.BinaryOp,
        left: Typed,
        right: Typed,
    ) Error!?Typed {
        const int_first = left.value_type.isInteger();
        var whole = if (int_first) left else right;
        var fraction = if (int_first) right else left;

        // A storage width promotes before anything else (D5), so what
        // reaches the pairs below is still `{int, long}` against
        // `{float, double}` and there are still four of them.
        whole = try self.promoted(whole);
        fraction = try self.promoted(fraction);

        if (whole.value_type == .int and fraction.value_type == .double) {
            const widened = try self.widenNumeric(whole, .double);
            const ordered = if (int_first)
                try self.emitCompare(operation, widened, fraction)
            else
                try self.emitCompare(operation, fraction, widened);
            return ordered;
        }

        if (whole.value_type == .int) whole = try self.widenNumeric(whole, .long);
        if (fraction.value_type == .float) fraction = try self.widenNumeric(fraction, .double);

        const spelled = if (int_first) operation else operation.mirrored();
        const arguments = try self.arena().alloc(Register, 3);
        arguments[0] = try self.code.emit(.{ .const_long = @intFromEnum(spelled) }, .long);
        arguments[1] = whole.register;
        arguments[2] = fraction.register;
        return .{
            .register = try self.code.emit(
                .{ .intrinsic = .{ .kind = .compare_long_double, .arguments = arguments } },
                .boolean,
            ),
            .value_type = .boolean,
        };
    }

    /// An ordinary same-type comparison, once both sides are one type.
    fn emitCompare(
        self: *FunctionBuilder,
        operation: mir.BinaryOp,
        left: Typed,
        right: Typed,
    ) Error!Typed {
        return .{
            .register = try self.code.emit(.{ .binary = .{
                .op = operation,
                .operand_type = left.value_type,
                .left = left.register,
                .right = right.register,
            } }, .boolean),
            .value_type = .boolean,
        };
    }

    /// `x == none` / `x != none` — the test that narrows.  It is the
    /// one comparison `none` takes part in: absence has no ordering
    /// and nothing else to be equal to.
    fn lowerAbsenceTest(self: *FunctionBuilder, binary: ast.Binary) Error!?Typed {
        if (binary.op != .equal and binary.op != .not_equal) {
            try self.fail("luce.sema.absent", binary.span, "none only compares with == and !=", .{});
            return null;
        }
        if (binary.left.* == .none_literal and binary.right.* == .none_literal) {
            try self.fail("luce.sema.absent", binary.span, "none == none says nothing; test a T? against none", .{});
            return null;
        }
        const written = if (binary.right.* == .none_literal) binary.left else binary.right;
        const already = self.narrowedName(written);
        const tested = (try self.lowerExpression(written, false)) orelse return null;
        if (tested.value_type != .optional) {
            if (already) |name| {
                try self.fail("luce.sema.absent", binary.span, "{s} already holds a value here, so this test has one answer; drop it", .{name});
                return null;
            }
            try self.fail("luce.sema.absent", binary.span, "{s} is always there; only a T? is ever none", .{
                try self.analyzer.typeName(tested.value_type),
            });
            return null;
        }
        const arguments = try self.arena().alloc(Register, 1);
        arguments[0] = tested.register;
        const absent = try self.code.emit(
            .{ .intrinsic = .{ .kind = .is_none, .arguments = arguments } },
            .boolean,
        );
        if (binary.op == .equal) return .{ .register = absent, .value_type = .boolean };
        return .{
            .register = try self.code.emit(.{ .unary = .{ .op = .logic_not, .operand = absent } }, .boolean),
            .value_type = .boolean,
        };
    }

    /// `trap("…")` written where a value belongs.  It is the one
    /// expression that never yields one and is still legal there,
    /// because it never comes back; `trap` is a reserved name, so
    /// nothing else can wear it.
    fn isLeavingCall(expression: *const ast.Expression) bool {
        if (expression.* != .call) return false;
        const callee = expression.call.callee;
        return std.mem.eql(u8, callee, "trap") or
            std.mem.eql(u8, callee, "error") or
            std.mem.eql(u8, callee, "exit");
    }

    /// `a else b` — `a` when it is there, `b` when it is not.  The
    /// fallback runs only on the absent side, which is what makes
    /// `x else trap("…")` the assert-unwrap (docs/FAILURE.md).
    fn lowerCoalesce(self: *FunctionBuilder, binary: ast.Binary) Error!?Typed {
        const already = self.narrowedName(binary.left);
        const left = (try self.lowerExpression(binary.left, false)) orelse return null;
        const payload = left.value_type.held() orelse {
            // A name already proved present is the likely case, and
            // "long always has a value" would only puzzle a reader who
            // wrote `long?`.
            if (already) |name| {
                try self.fail("luce.sema.absent", binary.span, "{s} already holds a value here, so the else can never run; drop it", .{name});
                return null;
            }
            try self.fail("luce.sema.absent", binary.span, "else supplies the value a T? does not have, and {s} always has one", .{
                try self.analyzer.typeName(left.value_type),
            });
            return null;
        };
        // Both arms must agree on ownership: the binding that receives
        // the result either owns an object or does not, and that is
        // one static fact, not one per branch (S1, S8, S16).
        if (self.analyzer.carriesObjects(payload) and
            (try self.yieldsOwnership(binary.left)) != (try self.yieldsOwnership(binary.right)))
        {
            try self.fail(
                "luce.sema.own",
                binary.span,
                "the two sides of else must agree on ownership: either both hand over a fresh object, or neither does [OWNERSHIP.md S1, S8]",
                .{},
            );
            return null;
        }
        const arguments = try self.arena().alloc(Register, 1);
        arguments[0] = left.register;
        const absent = try self.code.emit(
            .{ .intrinsic = .{ .kind = .is_none, .arguments = arguments } },
            .boolean,
        );
        const unwrap = try self.arena().alloc(Register, 1);
        unwrap[0] = left.register;
        const present = try self.code.emit(
            .{ .intrinsic = .{ .kind = .optional_unwrap, .arguments = unwrap } },
            payload,
        );
        const either = try self.code.openCoalesce(absent, present, payload);
        if (isLeavingCall(binary.right)) {
            // `x else trap("…")` is the assert-unwrap, and it is
            // greppable — which is why Luce has no force-unwrap sigil
            // (docs/FAILURE.md).  The fallback leaves nothing behind
            // because it never comes back.
            _ = try self.lowerExpression(binary.right, true);
        } else if (try self.lowerTyped(binary.right, payload, binary.span, "the else fallback")) |fallback| {
            try self.code.store(either.result, fallback.value.register);
        }
        return .{
            .register = try self.code.closeShortCircuit(either),
            .value_type = payload,
        };
    }

    fn lowerShortCircuit(self: *FunctionBuilder, binary: ast.Binary) Error!?Typed {
        const operator: []const u8 = if (binary.op == .logic_and) "and" else "or";
        const left = (try self.lowerExpression(binary.left, false)) orelse return null;
        if (left.value_type != .boolean) {
            // Which side, and what it is: the type is in hand and the
            // operand has its own span, so underlining both of them and
            // naming neither — which is what "and needs bool operands"
            // did — throws away everything the reader needs.
            // `condition must be bool, not long` is the model.
            try self.fail("luce.sema.type", binary.left.span(), "the left operand of {s} must be bool, not {s}{s}", .{
                operator,
                try self.analyzer.typeName(left.value_type),
                try self.absenceAdvice(left.value_type, binary.left),
            });
            return null;
        }
        // `and` evaluates its right side when the left is true, `or`
        // when it is false.
        const either = try self.code.openShortCircuit(left.register, binary.op == .logic_and);
        // Inside the right operand, the left one has already decided:
        // `x != none and x > 3` narrows `x` for the comparison, which
        // is the shape this feature exists for.  Nothing inside an
        // expression can widen, so the facts unwind by truncation.
        const facts_floor = self.narrowed.items.len;
        try self.applyFacts(binary.left, binary.op == .logic_and, split_search_depth);
        defer self.narrowed.shrinkRetainingCapacity(facts_floor);
        if (try self.lowerExpression(binary.right, false)) |right| {
            if (right.value_type != .boolean) {
                try self.fail("luce.sema.type", binary.right.span(), "the right operand of {s} must be bool, not {s}{s}", .{
                    operator,
                    try self.analyzer.typeName(right.value_type),
                    try self.absenceAdvice(right.value_type, binary.right),
                });
            } else {
                try self.code.store(either.result, right.register);
            }
        }
        return .{
            .register = try self.code.closeShortCircuit(either),
            .value_type = .boolean,
        };
    }

    fn lowerUnary(self: *FunctionBuilder, unary: ast.Unary, wanted: ?Type) Error!?Typed {
        // -9223372036854775808 is one literal, not a negated one: the
        // magnitude alone is past long's maximum, so the sign has to
        // fold in before the range is checked or the smallest long is
        // the one number nobody can write.
        if (unary.op == .negate and unary.operand.* == .int_literal) {
            return self.lowerIntLiteral(unary.operand.int_literal, unary.span, true, wanted);
        }
        // A minus does not change where a literal lands, so the
        // landing type passes straight through it: `let x: double =
        // -1.5` reads its text at a float exactly as `1.5` would.
        //
        // **No test kills this line yet, and none can.**  A negated
        // *integer* literal takes the branch above; what is left is a
        // negated float literal, which lands on a float whether it was
        // told to or not, and a negated name, which widens afterwards
        // to the same value.  At one integer width and one float width
        // the line is an equivalent mutant — it becomes load-bearing
        // at the resize, where landing and widening-afterwards stop
        // agreeing, and a spec for it belongs in that step.
        if (unary.op == .negate) self.wanted = wanted;
        const operand = (try self.lowerExpression(unary.operand, false)) orelse return null;
        switch (unary.op) {
            .negate => {
                if (!operand.value_type.isNumeric()) {
                    try self.fail("luce.sema.type", unary.span, "cannot negate {s}", .{
                        try self.analyzer.typeName(operand.value_type),
                    });
                    return null;
                }
                // A storage width negates at its arithmetic type,
                // like every other operator (D5): `-b` on a `byte` is
                // an `int`, which is also the only answer that could
                // be right — a `byte` has no negatives to hold.
                const at = try self.promoted(operand);
                return .{
                    .register = try self.code.emit(.{ .unary = .{ .op = .negate, .operand = at.register } }, at.value_type),
                    .value_type = at.value_type,
                };
            },
            .logic_not => {
                if (operand.value_type != .boolean) {
                    try self.fail("luce.sema.type", unary.span, "not needs a bool", .{});
                    return null;
                }
                return .{
                    .register = try self.code.emit(.{ .unary = .{ .op = .logic_not, .operand = operand.register } }, .boolean),
                    .value_type = .boolean,
                };
            },
            .bit_not => {
                // Integers only (docs/BITWISE.md D2); a storage width
                // complements at its arithmetic type, like every other
                // operator (docs/TYPES.md D5).
                if (!operand.value_type.isNumeric() or operand.value_type.isFloating()) {
                    try self.fail("luce.sema.type", unary.span, "~ works on int and long; {s} has no bits a program may see", .{
                        try self.analyzer.typeName(operand.value_type),
                    });
                    return null;
                }
                const at = try self.promoted(operand);
                return .{
                    .register = try self.code.emit(.{ .unary = .{ .op = .bit_not, .operand = at.register } }, at.value_type),
                    .value_type = at.value_type,
                };
            },
        }
    }

    // Calls and methods ----------------------------------------------------
    //
    // Struct construction, explicit conversion, namespaced calls, and
    // builtin methods on values.

    /// A declaration's parameters flattened to the resolver's
    /// vocabulary: a receiver slot is not nameable (D7), and a slot
    /// with a folded default says so.  Arena-owned.
    fn declarationSlots(
        self: *FunctionBuilder,
        parameters: []const ast.Parameter,
        defaults: []const ?context.TypedConstant,
    ) Error![]CallSlot {
        const surface = try self.arena().alloc(CallSlot, parameters.len);
        for (parameters, defaults, surface) |parameter, default, *slot| {
            slot.* = .{
                .name = parameter.name,
                .nameable = parameter.receiver == .not,
                .defaulted = default != null,
            };
        }
        return surface;
    }

    /// A builtin's table row flattened the same way — the table is its
    /// signature (docs/ARGS.md §3).  Arena-owned.
    fn builtinSlots(self: *FunctionBuilder, matched: Builtin) Error![]CallSlot {
        const surface = try self.arena().alloc(CallSlot, matched.parameters.len);
        for (matched.parameters, surface) |parameter, *slot| {
            slot.* = .{ .name = parameter.name, .defaulted = parameter.default != null };
        }
        return surface;
    }

    /// Which parameter slot each written argument fills — the name
    /// resolution of docs/ARGS.md, shared by every spelling of a user
    /// call.  The rules, each with its own sentence: positional
    /// arguments fill slots left to right and **the first named
    /// argument ends the positional run** (D4), names may reorder
    /// (D5), a slot is filled once, and `self` is not a nameable
    /// argument (D7).
    ///
    /// `surface` is the declared list flattened to `CallSlot`s;
    /// `hidden` is how many of its leading slots the call site does
    /// not write — 1 in the method form, whose receiver stands in
    /// front of the dot; 0 otherwise.  The answers index the declared
    /// list, `hidden` included, so they index `parameter_types`
    /// directly.  `seen` has one flag per declared slot; the caller
    /// pre-marks the hidden ones.  Count mistakes point at the call
    /// (`span`); name mistakes point at the argument.  Null after
    /// reporting; arena-owned otherwise.
    fn resolveSlots(
        self: *FunctionBuilder,
        callee: []const u8,
        code: []const u8,
        surface: []const CallSlot,
        hidden: usize,
        call_arguments: []const ast.Argument,
        seen: []bool,
        span: Span,
    ) Error!?[]u32 {
        const slots = try self.arena().alloc(u32, call_arguments.len);
        var positional: usize = 0;
        var named = false;
        for (call_arguments, slots, 0..) |argument, *filled, index| {
            if (argument.name == null and named) {
                // D4: the strict rule, Kotlin 1.3's — the first named
                // argument ends the positional run, so this argument
                // has no slot to count into.  Name the first slot
                // still open, which is the fix.
                for (surface, seen) |candidate, given| {
                    if (given or !candidate.nameable) continue;
                    try self.fail(code, argument.span, "a positional argument cannot follow a named one; write {s} = …", .{candidate.name});
                    return null;
                }
                try self.fail(code, argument.span, "a positional argument cannot follow a named one", .{});
                return null;
            }
            const slot = argumentSlot(surface, hidden, call_arguments, index) orelse {
                if (argument.name != null) {
                    try self.failUnknownParameter(callee, code, surface, hidden, argument);
                    return null;
                }
                // A positional argument past the last slot: the count
                // sentence, which is about the call and not about any
                // one argument.
                try self.failArgumentCount(callee, code, surface, hidden, call_arguments.len, span);
                return null;
            };
            if (argument.name) |written| {
                named = true;
                if (seen[slot]) {
                    if (slot < hidden + positional) {
                        try self.fail(code, argument.span, "{s} was given twice, by position and by name", .{written});
                    } else {
                        try self.fail(code, argument.span, "{s} was given twice", .{written});
                    }
                    return null;
                }
            } else {
                positional += 1;
            }
            seen[slot] = true;
            filled.* = @intCast(slot);
        }
        return slots;
    }

    /// The named argument that names no parameter (docs/ARGS.md §8):
    /// `self` gets the receiver sentence, anything else the
    /// did-you-mean, and the enumerate-the-surface fallback when
    /// nothing is close enough.
    fn failUnknownParameter(
        self: *FunctionBuilder,
        callee: []const u8,
        code: []const u8,
        surface: []const CallSlot,
        hidden: usize,
        argument: ast.Argument,
    ) Error!void {
        const written = argument.name.?;
        if (std.mem.eql(u8, written, "self")) {
            if (hidden != 0) {
                try self.fail("luce.sema.self", argument.span, "self is the receiver; it is written in front of the dot, not named", .{});
                return;
            }
            if (surface.len != 0 and !surface[0].nameable) {
                try self.fail("luce.sema.self", argument.span, "self is the receiver, not a parameter: write {s}({s}, …)", .{
                    callee,
                    try self.writtenTarget(argument.value),
                });
                return;
            }
        }
        var suggestion = helpers.Suggestion.init(written);
        for (surface[hidden..]) |candidate| {
            if (!candidate.nameable) continue;
            suggestion.offer(candidate.name);
        }
        if (suggestion.best()) |closest| {
            try self.fail(code, argument.span, "{s} has no parameter {s}; did you mean {s}?", .{ callee, written, closest });
            return;
        }
        var takes: std.ArrayList(u8) = .empty;
        defer takes.deinit(self.temporary());
        for (surface[hidden..]) |candidate| {
            if (!candidate.nameable) continue;
            if (takes.items.len != 0) try takes.appendSlice(self.temporary(), ", ");
            try takes.appendSlice(self.temporary(), candidate.name);
        }
        if (takes.items.len == 0) {
            try self.fail(code, argument.span, "{s} has no parameter {s}; it takes no arguments", .{ callee, written });
            return;
        }
        try self.fail(code, argument.span, "{s} has no parameter {s} (takes {s})", .{ callee, written, takes.items });
    }

    /// The count sentence: how many arguments the call site may write,
    /// against how many it wrote — and, where the signature has
    /// defaults, how many of its slots have one (docs/ARGS.md §8).
    fn failArgumentCount(
        self: *FunctionBuilder,
        callee: []const u8,
        code: []const u8,
        surface: []const CallSlot,
        hidden: usize,
        written_count: usize,
        span: Span,
    ) Error!void {
        const defaulted = defaultCount(surface);
        const takes = surface.len - hidden;
        if (defaulted != 0) {
            const required = takes - defaulted;
            try self.fail(code, span, "{s} takes {d} argument{s} and {d} with a default, got {d}", .{
                callee,
                required,
                helpers.plural(required),
                defaulted,
                written_count,
            });
            return;
        }
        try self.fail(code, span, "{s} takes {d} argument{s}, got {d}", .{
            callee,
            takes,
            helpers.plural(takes),
            written_count,
        });
    }

    /// Every required slot the call left unfilled, named at once —
    /// never the first only, for `writeMissingFields`' reason — and a
    /// slot with a default is never missing: it is filled from the
    /// declaration (docs/ARGS.md D2).  True when nothing is missing.
    fn checkRequiredSlots(
        self: *FunctionBuilder,
        callee: []const u8,
        code: []const u8,
        surface: []const CallSlot,
        seen: []const bool,
        span: Span,
    ) Error!bool {
        var missing: usize = 0;
        for (surface, seen) |candidate, given| {
            if (given or candidate.defaulted) continue;
            missing += 1;
        }
        if (missing == 0) return true;
        var names: std.ArrayList(u8) = .empty;
        defer names.deinit(self.temporary());
        var written: usize = 0;
        for (surface, seen) |candidate, given| {
            if (given or candidate.defaulted) continue;
            if (written != 0) {
                if (missing > 2) try names.appendSlice(self.temporary(), ",");
                try names.appendSlice(self.temporary(), " ");
                if (written + 1 == missing) try names.appendSlice(self.temporary(), "and ");
            }
            try names.appendSlice(self.temporary(), candidate.name);
            written += 1;
        }
        try self.fail(code, span, "{s} is missing {s}", .{ callee, names.items });
        return false;
    }

    fn lowerCall(
        self: *FunctionBuilder,
        call: ast.Call,
        as_statement: bool,
        fallible_allowed: bool,
        shape_position: ShapePosition,
        wanted: ?Type,
    ) Error!?Typed {
        // Builtins and conversions are bare names and take priority;
        // reserved names keep user declarations out of their way.
        if (std.mem.indexOfScalar(u8, call.callee, '.') == null) {
            if (conversionNamed(call.callee) != null) return self.lowerConvert(call);
            switch (try self.lowerIntrinsic(call, as_statement, fallible_allowed, wanted)) {
                .not_builtin => {},
                .failed => return null,
                .value => |value| return value,
            }
        }

        const resolved = (try self.resolveDeclared(call.callee, call.span, call.origin)) orelse
            return null;
        if (self.analyzer.struct_names.get(resolved)) |layout_index| {
            return self.lowerConstruct(call.arguments, call.span, layout_index);
        }
        if (self.analyzer.enum_names.get(resolved)) |enum_index| {
            return self.lowerEnumOfNumber(call.callee, call.arguments, call.span, enum_index);
        }
        const function_index = self.analyzer.function_names.get(resolved) orelse {
            try self.failUnknownFunction(call.callee, call.span);
            return null;
        };
        return self.lowerUserCall(
            function_index,
            call.callee,
            call.arguments,
            call.span,
            as_statement,
            fallible_allowed,
            shape_position,
        );
    }

    fn lowerUserCall(
        self: *FunctionBuilder,
        function_index: u32,
        name: []const u8,
        call_arguments: []const ast.Argument,
        span: Span,
        as_statement: bool,
        fallible_allowed: bool,
        shape_position: ShapePosition,
    ) Error!?Typed {
        const info = self.analyzer.functions.items[function_index];
        if (!try self.functionReachable(function_index, span)) return null;
        if (info.is_entry) {
            try self.fail("luce.sema.call", span, "entry function {s} cannot be called", .{name});
            return null;
        }
        // `Point.length(p)` stays callable and means exactly what
        // `p.length()` means: the method form is sugar with one
        // semantics under it, which is what makes converting a struct
        // one function at a time possible (docs/METHODS.md).
        //
        // `Point.scale(p, 2.0)` is the one exception, and it is why
        // this check exists: a `var self` method writes back to its
        // receiver's place, and the static form has no place to write
        // to.  It would take a copy, mutate it and discard it, in
        // silence — which is the one shape where allowing both
        // spellings would mean two semantics instead of one.
        if (info.receiver == .writes) {
            try self.fail(
                "luce.sema.self",
                span,
                "{s} takes var self and writes back to its receiver; call it as {s}.{s}(…)",
                .{
                    info.declaration.name,
                    if (call_arguments.len != 0)
                        try self.writtenTarget(call_arguments[0].value)
                    else
                        "the receiver",
                    info.declaration.name,
                },
            );
            return null;
        }
        // See `callUser`: a call that can fail has to say which of
        // `try` and `catch` it means, and the check comes before the
        // arguments so the reader is told the one thing that matters.
        if (info.fallible and !fallible_allowed) {
            try self.fail(
                "luce.sema.fallible",
                span,
                "{s} can fail: write 'try {s}(…)' to pass the error on, or '{s}(…) catch …' to handle it",
                .{ name, name, name },
            );
            return null;
        }
        // Which slot each argument fills is settled before any of them
        // is lowered: it is what says what type the argument lands in
        // (docs/ARGS.md §4) — the order `lowerConstruct` has kept
        // since construction shipped.
        const parameters = info.declaration.parameters;
        if (parameters.len != info.parameter_types.len) {
            // A parameter of this declaration failed to resolve, and
            // the declaration carries the diagnostic; there is no
            // signature left to check a call against.
            return null;
        }
        const surface = try self.declarationSlots(parameters, info.parameter_defaults);
        const seen = try self.temporary().alloc(bool, parameters.len);
        defer self.temporary().free(seen);
        @memset(seen, false);
        const slots = (try self.resolveSlots(name, "luce.sema.call", surface, 0, call_arguments, seen, span)) orelse
            return null;
        if (!(try self.checkRequiredSlots(name, "luce.sema.call", surface, seen, span))) return null;
        // Ownership handoffs are never invisible: a give parameter
        // needs give NAME, copy NAME, or something fresh at the call
        // site; a borrow parameter refuses a give (S13, S14).
        for (call_arguments, slots) |argument, slot| {
            if (info.parameter_modes[slot] == .give) {
                if (!(try self.yieldsOwnership(argument.value))) {
                    try self.failNeedsOwnership(
                        argument.span,
                        try std.fmt.allocPrint(self.arena(), "argument {d} of {s} takes ownership", .{ slot + 1, name }),
                        argument.value,
                        "S13, S14",
                    );
                    return null;
                }
            } else if (argument.value.* == .give) {
                try self.fail(
                    "luce.sema.own",
                    argument.span,
                    "{s} only borrows this argument; give needs a give parameter in the signature [OWNERSHIP.md S11, S13]",
                    .{name},
                );
                return null;
            }
        }
        // Arguments are evaluated in the order they are written and
        // bound to the slots they name (D5): the batch runs in source
        // order, and only the destination index is permuted.
        const expressions = try self.arena().alloc(*ast.Expression, call_arguments.len);
        const places = try self.arena().alloc(Type, call_arguments.len);
        for (call_arguments, expressions, places, slots) |argument, *expression, *place, slot| {
            expression.* = argument.value;
            place.* = info.parameter_types[slot];
        }
        const values = (try self.lowerOperandsInto(expressions, .{ .places = places })) orelse return null;
        const registers = try self.arena().alloc(Register, info.parameter_types.len);
        for (values, slots, 0..) |value, slot, index| {
            const fitted = (try self.fit(value, info.parameter_types[slot])) orelse {
                // A type mistake points at the argument, spelled the
                // way the reader spelled it: by name where it was
                // named, by position where it was counted.
                if (call_arguments[index].name) |written| {
                    try self.fail("luce.sema.type", call_arguments[index].span, "{s} of {s} is {s}, got {s}{s}", .{
                        written,
                        name,
                        try self.analyzer.typeName(info.parameter_types[slot]),
                        try self.analyzer.typeName(value.value_type),
                        try self.mismatchAdvice(info.parameter_types[slot], value.value_type, expressions[index]),
                    });
                } else {
                    try self.fail("luce.sema.type", call_arguments[index].span, "argument {d} of {s} is {s}, got {s}{s}", .{
                        slot + 1,
                        name,
                        try self.analyzer.typeName(info.parameter_types[slot]),
                        try self.analyzer.typeName(value.value_type),
                        try self.mismatchAdvice(info.parameter_types[slot], value.value_type, expressions[index]),
                    });
                }
                return null;
            };
            registers[slot] = fitted.register;
        }
        // A slot nobody filled takes its default: the constant
        // register the same literal would have produced at the call
        // site (docs/ARGS.md D2) — no code path, no branch, no second
        // entry point.  A struct default owns the field run it just
        // made, so it is parked as the statement temporary a written
        // construction would be (S3).
        for (info.parameter_defaults, seen, 0..) |maybe_default, given, slot| {
            if (given) continue;
            const filled = maybe_default.?;
            const made: Typed = .{
                .register = try self.emitConstantValue(filled.value, filled.value_type),
                .value_type = filled.value_type,
            };
            try self.parkFreshStorage(made);
            registers[slot] = made.register;
        }
        if (info.return_type == .none and !as_statement) {
            try self.fail("luce.sema.call", span, "{s} returns nothing", .{name});
            return null;
        }
        // A call that answers a return shape may stand in exactly two
        // places: the right of a destructuring bind, and a statement
        // of its own (docs/RETURNS.md).  Everything else — an
        // argument, an operand, a `return` — is refused, which is what
        // keeps the rule one a reader can hold: it has no exceptions.
        if (info.results.len >= 2 and !as_statement and shape_position != .bind) {
            try self.fail(
                "luce.sema.call",
                span,
                "{s} answers {d} values, and only a let or a var can receive them{s}",
                .{
                    name,
                    info.results.len,
                    if (shape_position == .returning) " — bind them, then return them" else "",
                },
            );
            return null;
        }
        const call = try self.code.emit(
            .{ .call = .{ .function = function_index, .arguments = registers } },
            info.return_type,
        );
        if (info.fallible) return try self.openFallible(call, info.return_type);
        return .{ .register = call, .value_type = info.return_type };
    }

    /// target.name(args): a namespaced call when the target chain is
    /// bare declaration names (Struct.func, module.func,
    /// module.Struct(...) construction), otherwise a builtin method on
    /// the target value.  Locals shadow nothing, so a chain whose head
    /// is a local is always a value method.
    fn lowerMethod(
        self: *FunctionBuilder,
        method: ast.Method,
        as_statement: bool,
        fallible_allowed: bool,
        shape_position: ShapePosition,
    ) Error!?Typed {
        switch (try self.methodNamespace(method)) {
            .resolved => |resolved| {
                if (self.analyzer.struct_names.get(resolved)) |layout_index| {
                    return self.lowerConstruct(method.arguments, method.span, layout_index);
                }
                if (self.analyzer.enum_names.get(resolved)) |enum_index| {
                    return self.lowerEnumOfNumber(method.name, method.arguments, method.span, enum_index);
                }
                const function_index = self.analyzer.function_names.get(resolved).?;
                return self.lowerUserCall(
                    function_index,
                    resolved,
                    method.arguments,
                    method.span,
                    as_statement,
                    fallible_allowed,
                    shape_position,
                );
            },
            .reported => return null,
            .value => return self.lowerValueMethod(method, as_statement, fallible_allowed, shape_position),
        }
    }

    const NamespaceResolution = union(enum) {
        /// Not a namespace: lower as a method on a value.
        value,
        /// A namespace whose member is missing; already diagnosed.
        reported,
        /// The fully-qualified declaration this call names.
        resolved: []const u8,
    };

    /// A dotted chain of bare names in front of a call, collected
    /// inner-to-outer: for geo.Text.width(...) the parts are
    /// [width-side first] and the head is "geo".
    /// Decide whether target.name(...) names a declaration.
    fn methodNamespace(self: *FunctionBuilder, method: ast.Method) Error!NamespaceResolution {
        const chain = helpers.dottedChain(method.target) orelse return .value;
        const parts = chain.parts;
        const count = chain.count;
        const head = chain.head();
        if (self.findLocal(head) != null) return .value;

        var written: std.ArrayList(u8) = .empty;
        defer written.deinit(self.temporary());
        var at = count;
        while (at > 0) {
            at -= 1;
            try written.appendSlice(self.temporary(), parts[at]);
            try written.append(self.temporary(), '.');
        }
        try written.appendSlice(self.temporary(), method.name);

        // Two namespace shapes exist: a struct of this module
        // (Words.classify) and an imported module (geo.helper,
        // geo.Point, geo.Text.width).  A head that names neither is a
        // value; a head that names one but whose member is missing is
        // a call error, not a method fallback.
        const joined = written.items;
        // `Method.stored.compressed()` — the chain in front of the call
        // names a *member*, which is a value, so this is a method on
        // one and not a namespace path (docs/ENUMS.md D3).  The same
        // shape as the imported-constant case below, one enum earlier.
        if (chain.count >= 2 and self.namesMember(parts[0..chain.count])) return .value;
        const head_qualified = try self.analyzer.qualify(self.prefix, head);
        if (self.analyzer.struct_names.contains(head_qualified) or
            self.analyzer.enum_names.contains(head_qualified))
        {
            const local = try self.analyzer.qualify(self.prefix, joined);
            if (self.analyzer.struct_names.contains(local) or
                self.analyzer.enum_names.contains(local) or
                self.analyzer.function_names.contains(local))
            {
                return .{ .resolved = try self.arena().dupe(u8, local) };
            }
            try self.failUnknownFunction(joined, method.span);
            return .reported;
        }
        if (self.analyzer.importsModule(self.module, head)) {
            if (self.analyzer.struct_names.contains(joined) or
                self.analyzer.enum_names.contains(joined) or
                self.analyzer.function_names.contains(joined))
            {
                return .{ .resolved = try self.arena().dupe(u8, joined) };
            }
            // geo.pi.method() — a value method on an imported constant.
            if (count >= 2) {
                const member = try std.fmt.allocPrint(self.temporary(), "{s}.{s}", .{ head, parts[count - 2] });
                defer self.temporary().free(member);
                if (self.analyzer.constant_names.contains(member)) return .value;
            }
            try self.failUnknownFunction(joined, method.span);
            return .reported;
        }
        // The head names a module elsewhere in this program: point at
        // the missing import instead of "unknown name".
        for (self.analyzer.modules) |module| {
            if (module.prefix.len != 0 and std.mem.eql(u8, module.prefix, head)) {
                try self.fail("luce.sema.import", method.span, "unknown namespace {s}; import {s} to use it", .{ head, try self.analyzer.importSpelling(head) });
                return .reported;
            }
        }
        return .value;
    }

    /// Builtin methods on values: strings, lists, arrays, maps, and
    /// builders.  `x.f(y)` is sugar for a plain typed operation with
    /// the receiver first — there is no dispatch.
    fn lowerValueMethod(
        self: *FunctionBuilder,
        method: ast.Method,
        as_statement: bool,
        fallible_allowed: bool,
        shape_position: ShapePosition,
    ) Error!?Typed {
        const expressions = try self.arena().alloc(*ast.Expression, method.arguments.len + 1);
        expressions[0] = method.target;
        for (method.arguments, 0..) |argument, index| {
            expressions[index + 1] = argument.value;
        }
        const values = (try self.lowerOperandsInto(expressions, .{ .method = .{
            .name = method.name,
            .arguments = method.arguments,
        } })) orelse return null;
        const receiver = values[0];
        const arguments = values[1..];
        if (try self.refusesAbsence(receiver, "a method's receiver", method.span, method.target)) {
            return null;
        }

        const found: MethodFound = blk: {
            if (receiver.value_type == .string) {
                // The primitives above, and nothing else: every other
                // string method is library code — s.find(x) is
                // strings.find(s, x) (docs/STD.md).
                for (string_methods) |primitive| {
                    if (!std.mem.eql(u8, method.name, primitive.name)) continue;
                    if (try self.refuseNamedMethodArguments(method)) return null;
                    if (!try self.methodTakes(method, arguments, receiver.value_type)) return null;
                    break :blk .{ .kind = primitive.kind, .result = primitive.result };
                }
                return self.stringsCall(method, values, as_statement);
            }
            if (self.analyzer.heapOf(receiver.value_type)) |descriptor| {
                // join belongs to the strings module too: it makes a
                // string, from list(string).
                if (descriptor == .list and descriptor.list == .string and
                    std.mem.eql(u8, method.name, "join"))
                {
                    return self.stringsCall(method, values, as_statement);
                }
                if (try self.refuseNamedMethodArguments(method)) return null;
                if (try self.objectMethod(method, receiver.value_type, descriptor, arguments)) |found| {
                    break :blk found;
                }
                return null;
            }
            // A struct value: `p.length()` *is* `Point.length(p)`, the
            // same MIR call resolved here rather than a second
            // semantics (docs/METHODS.md).
            //
            // It can never race a built-in method, and by construction
            // rather than by ordering: `types.StructLayout` has no
            // functions field and `heapOf` answers null for a struct,
            // so the two arms above are unreachable for one.
            // An enum answers here too, and by the same rule: its
            // functions are declared inside it and named `Method.f`, so
            // `m.compressed()` *is* `Method.compressed(m)`
            // (docs/ENUMS.md D7).
            if (self.declaredName(receiver.value_type) != null) {
                return self.lowerReceiverCall(method, values, as_statement, fallible_allowed, shape_position);
            }
            try self.fail("luce.sema.method", method.span, "{s} has no methods", .{
                try self.analyzer.typeName(receiver.value_type),
            });
            return null;
        };

        if (found.result == .none and !as_statement) {
            try self.fail("luce.sema.method", method.span, "{s} returns nothing", .{method.name});
            return null;
        }
        // Containers own their object elements: append/insert take a
        // fresh value, a give, or a copy (S20, S21).
        if (found.kind == .append_value or found.kind == .insert_value) {
            if (self.analyzer.heapOf(receiver.value_type)) |descriptor| {
                if (descriptor == .list and self.analyzer.carriesObjects(descriptor.list)) {
                    const value_index: usize = if (found.kind == .append_value) 0 else 1;
                    if (!(try self.yieldsOwnership(method.arguments[value_index].value))) {
                        try self.failNeedsOwnership(
                            method.arguments[value_index].span,
                            "a container keeps its object elements",
                            method.arguments[value_index].value,
                            "S21",
                        );
                        return null;
                    }
                }
            }
        }
        // Every other method argument is a borrow (S11): a give there
        // would hand the object to nobody.
        for (method.arguments, 0..) |argument, position| {
            if (argument.value.* != .give) continue;
            const adopting = (found.kind == .append_value and position == 0) or
                (found.kind == .insert_value and position == 1);
            if (!adopting) {
                try self.fail(
                    "luce.sema.own",
                    argument.span,
                    "{s} only borrows its arguments; give needs an owning destination [OWNERSHIP.md S11, S13]",
                    .{method.name},
                );
                return null;
            }
        }
        const registers = try self.arena().alloc(Register, values.len);
        for (values, registers) |value, *slot| slot.* = value.register;
        // A list keeps what it is appended, so the element is a store
        // and takes or copies its storage here; a builder copies bytes
        // into a buffer of its own and borrows (docs/STRINGS.md).
        if (self.storedElement(found.kind, receiver.value_type)) |position| {
            registers[position] = try self.ownedForStore(values[position]);
        }
        const emitted = try self.code.emit(
            .{ .intrinsic = .{ .kind = found.kind, .arguments = registers } },
            found.result,
        );
        // A method can fail too, since the byte channel arrived: a
        // handle's read, write and flush all answer to the world
        // (docs/BYTES.md).  Same rule as a free builtin's — the call
        // site says which of `try` and `catch` it means, and a site
        // that says neither is `luce.sema.fallible` rather than a
        // silently dropped outcome (docs/FAILURE.md).
        if (found.kind.isFallible()) {
            if (!fallible_allowed) {
                try self.fail(
                    "luce.sema.fallible",
                    method.span,
                    "{s} can fail: write 'try x.{s}(…)' to pass the error on, or 'x.{s}(…) catch …' to handle it",
                    .{ method.name, method.name, method.name },
                );
                return null;
            }
            return try self.openFallible(emitted, found.result);
        }
        return .{ .register = emitted, .value_type = found.result };
    }

    // Methods on a struct value ---------------------------------------------
    //
    // `p.length()` means `Point.length(p)` — not "is compiled like",
    // *means*: the same call, resolved in this stage.  There is no
    // dispatch, no reference, and no second semantics
    // (docs/METHODS.md).

    /// The declaration behind `x.f(…)` on a struct value, silently:
    /// the function `Struct.f` when it is a *method*, null when there
    /// is no such name or the name is a namespace function — whose
    /// receiver is not parameter zero, and whose method-form call
    /// `lowerReceiverCall` refuses with the sentence that says so.
    ///
    /// This is what makes the method form land its arguments where the
    /// static form lands them: `landsOn` asks it mid-batch, before an
    /// argument is lowered, because a struct receiver used to answer
    /// nothing there — so `p.f(none)` was refused while
    /// `Point.f(p, none)` compiled, and a `0.1` read its text at
    /// binary32 on one spelling and binary64 on the other
    /// (docs/ARGS.md §4).
    fn structMethod(self: *FunctionBuilder, receiver: Type, name: []const u8) Error!?u32 {
        const declared = self.declaredName(receiver) orelse return null;
        const qualified = try std.fmt.allocPrint(self.temporary(), "{s}.{s}", .{ declared, name });
        defer self.temporary().free(qualified);
        const function_index = self.analyzer.function_names.get(qualified) orelse return null;
        if (self.analyzer.functions.items[function_index].receiver == .not) return null;
        return function_index;
    }

    /// The qualified name of the declaration a value's type came from —
    /// `Point`, `geo.Method` — or null for a type nobody declared.
    ///
    /// **The two declaration keywords answer here alike.**  A struct and
    /// an enum both spell their functions `Name.func`, so the whole of
    /// the method machinery needs the name and nothing else
    /// (docs/METHODS.md, docs/ENUMS.md D7); only a sentence that has to
    /// say which word was written looks further.
    fn declaredName(self: *const FunctionBuilder, of: Type) ?[]const u8 {
        return switch (of) {
            .strukt => |index| self.analyzer.structs.items[index].name,
            .enumeration => |reference| self.analyzer.enums.items[reference.index].name,
            else => null,
        };
    }

    /// `x.f(a, b)` where `x` is a value of a declared type — a struct
    /// or an enum.  `values` is the whole operand run with the receiver
    /// at zero, already lowered by `lowerValueMethod`; a method's
    /// arguments take their types from the values, exactly as every
    /// other method's do.
    fn lowerReceiverCall(
        self: *FunctionBuilder,
        method: ast.Method,
        values: []Typed,
        as_statement: bool,
        fallible_allowed: bool,
        shape_position: ShapePosition,
    ) Error!?Typed {
        const receiver_type = values[0].value_type;
        const declared = self.declaredName(receiver_type).?;
        const qualified = try std.fmt.allocPrint(self.arena(), "{s}.{s}", .{ declared, method.name });
        const function_index = self.analyzer.function_names.get(qualified) orelse {
            try self.failUnknownMethod(receiver_type, declared, method);
            return null;
        };
        if (!try self.functionReachable(function_index, method.span)) return null;
        const info = self.analyzer.functions.items[function_index];
        // The whole difference between a namespace and a method is
        // whether the declaration's first parameter is the word `self`,
        // and this is where a reader who has not learned that finds out
        // (docs/METHODS.md).
        if (info.receiver == .not) {
            try self.fail(
                "luce.sema.self",
                method.span,
                "{s}.{s} is a namespace function, not a method; it takes no self — call it as {s}({s}, …)",
                .{ declared, method.name, qualified, try self.writtenReceiver(method) },
            );
            return null;
        }
        if (info.fallible and !fallible_allowed) {
            try self.fail(
                "luce.sema.fallible",
                method.span,
                "{s} can fail: write 'try {s}.{s}(…)' to pass the error on, or '{s}.{s}(…) catch …' to handle it",
                .{
                    method.name,
                    try self.writtenReceiver(method),
                    method.name,
                    try self.writtenReceiver(method),
                    method.name,
                },
            );
            return null;
        }

        // Which slot each argument fills: the receiver is parameter
        // zero and stands in front of the dot, so the call site writes
        // slots one up — the `hidden = 1` case of the one resolver
        // every user-call spelling shares (docs/ARGS.md §4).
        const parameters = info.declaration.parameters;
        if (parameters.len != info.parameter_types.len) {
            // A parameter of this declaration failed to resolve, and
            // the declaration carries the diagnostic.
            return null;
        }
        const surface = try self.declarationSlots(parameters, info.parameter_defaults);
        const seen = try self.temporary().alloc(bool, parameters.len);
        defer self.temporary().free(seen);
        @memset(seen, false);
        seen[0] = true; // the receiver, already in hand
        const slots = (try self.resolveSlots(method.name, "luce.sema.method", surface, 1, method.arguments, seen, method.span)) orelse
            return null;
        if (!(try self.checkRequiredSlots(method.name, "luce.sema.method", surface, seen, method.span))) return null;

        // Ownership at the call site is the plain-call rule said once
        // per argument: a give parameter needs `give`/`copy`/something
        // fresh, and a borrow parameter refuses a `give` (S13, S14).
        // The receiver never takes a verb — it is a struct value.
        for (method.arguments, slots) |argument, slot| {
            if (info.parameter_modes[slot] == .give) {
                if (!(try self.yieldsOwnership(argument.value))) {
                    try self.failNeedsOwnership(
                        argument.span,
                        try std.fmt.allocPrint(
                            self.arena(),
                            "argument {d} of {s} takes ownership",
                            .{ slot, method.name },
                        ),
                        argument.value,
                        "S13, S14",
                    );
                    return null;
                }
            } else if (argument.value.* == .give) {
                try self.fail(
                    "luce.sema.own",
                    argument.span,
                    "{s} only borrows this argument; give needs a give parameter in the signature [OWNERSHIP.md S11, S13]",
                    .{method.name},
                );
                return null;
            }
        }

        const registers = try self.arena().alloc(Register, info.parameter_types.len);
        registers[0] = values[0].register;
        for (method.arguments, slots, 0..) |argument, slot, index| {
            const value = values[index + 1];
            const want = info.parameter_types[slot];
            const fitted = (try self.fit(value, want)) orelse {
                if (argument.name) |written| {
                    try self.fail("luce.sema.type", argument.span, "{s} of {s} is {s}, got {s}{s}", .{
                        written,
                        method.name,
                        try self.analyzer.typeName(want),
                        try self.analyzer.typeName(value.value_type),
                        try self.absenceAdvice(value.value_type, argument.value),
                    });
                } else {
                    try self.fail("luce.sema.type", argument.span, "argument {d} of {s} is {s}, got {s}{s}", .{
                        slot,
                        method.name,
                        try self.analyzer.typeName(want),
                        try self.analyzer.typeName(value.value_type),
                        try self.absenceAdvice(value.value_type, argument.value),
                    });
                }
                return null;
            };
            registers[slot] = fitted.register;
        }
        // A slot nobody filled takes its default (docs/ARGS.md D2),
        // parked like the written construction it stands in for (S3).
        for (info.parameter_defaults, seen, 0..) |maybe_default, given, slot| {
            if (given) continue;
            const filled = maybe_default.?;
            const made: Typed = .{
                .register = try self.emitConstantValue(filled.value, filled.value_type),
                .value_type = filled.value_type,
            };
            try self.parkFreshStorage(made);
            registers[slot] = made.register;
        }
        if (info.results.len == 0 and !as_statement) {
            try self.fail("luce.sema.call", method.span, "{s} returns nothing", .{method.name});
            return null;
        }
        if (info.results.len >= 2 and !as_statement and shape_position != .bind) {
            try self.fail(
                "luce.sema.call",
                method.span,
                "{s} answers {d} values, and only a let or a var can receive them{s}",
                .{
                    method.name,
                    info.results.len,
                    if (shape_position == .returning) " — bind them, then return them" else "",
                },
            );
            return null;
        }
        const call = try self.code.emit(
            .{ .call = .{ .function = function_index, .arguments = registers } },
            info.return_type,
        );
        const answered: Typed = if (info.fallible)
            try self.openFallible(call, info.return_type)
        else
            .{ .register = call, .value_type = info.return_type };
        if (info.receiver != .writes) return answered;
        return self.writeReceiverBack(method, info, answered, as_statement);
    }

    /// `p.scale(2.0)` means `p = Point.scale(p, 2.0)` — copy in, copy
    /// out (docs/METHODS.md).
    ///
    /// Not a new mechanism: it is transcribed from what the corpus
    /// writes by hand at every mutation site it has, `var moved =
    /// state` on one side and `state = Handle.…(state, …)` on the
    /// other.  The compiler writes the two halves the programmer was
    /// writing already.
    ///
    /// **It is not observably by-reference.**  Inside a method the only
    /// inputs are its parameters; struct values copy on every store;
    /// there are no globals, no references, no closures and no threads.
    /// No expression inside the callee can name the receiver's place,
    /// so copy-in/copy-out and by-reference give the same answers on
    /// every program that can be written here.
    ///
    /// **The store stands on the returning edge only.**  A method that
    /// raises leaves its receiver as it was, all or nothing, and for
    /// free: `openFallible` has already branched, and this runs on the
    /// side where the call came back.
    fn writeReceiverBack(
        self: *FunctionBuilder,
        method: ast.Method,
        info: context.FunctionDeclInfo,
        answered: Typed,
        as_statement: bool,
    ) Error!?Typed {
        const place = (try self.receiverPlace(method, info)) orelse return null;
        // The channel value is a statement temporary like any other
        // fresh struct: its field run, and the receiver copy inside it,
        // go back at the end of the statement (S3, docs/STRINGS.md).
        // The caller of this walk never sees it — what it hands back is
        // a *field* of it — so nothing else would park it.
        try self.parkFreshStorage(.{
            .register = answered.register,
            .value_type = info.return_type,
        });
        // Arity one — `func step(var self):` — is the plain single
        // return the language already had: the whole answer is the
        // receiver.
        if (info.results.len == 0) {
            // A store into a place that outlives the statement takes
            // its storage first: the struct's field run belongs to the
            // value the call answered, and that value is a statement
            // temporary (docs/STRINGS.md).
            try self.code.rebuild(place.root, place.accessors, try self.ownedForStore(answered));
            return .{ .register = answered.register, .value_type = .none };
        }
        const shape = info.return_type.strukt;
        const layout = self.analyzer.structs.items[shape];
        const back = try self.code.emit(.{ .struct_get = .{
            .target = answered.register,
            .layout = shape,
            .field = 0,
        } }, layout.fields[0].field_type);
        try self.code.rebuild(place.root, place.accessors, try self.ownedForStore(.{
            .register = back,
            .value_type = layout.fields[0].field_type,
        }));

        // One declared result is the ordinary single value a reader
        // binds with `let roll = rng.next()`; two or more is a shape,
        // and the receiver is not part of it — the declared arity is
        // the arity at the call site.
        if (info.results.len == 1) {
            return .{
                .register = try self.code.emit(.{ .struct_get = .{
                    .target = answered.register,
                    .layout = shape,
                    .field = 1,
                } }, layout.fields[1].field_type),
                .value_type = layout.fields[1].field_type,
            };
        }
        _ = as_statement;
        try self.fail(
            "luce.sema.self",
            method.span,
            "{s} writes its receiver back and answers {d} values; a method may do one or the other",
            .{ method.name, info.results.len },
        );
        return null;
    }

    /// Where a `var self` method writes its receiver back to.
    ///
    /// The rule is not one invented for the feature: it is the rule
    /// `lowerAssignChain` already enforces for `cells[0].value = 3` — a
    /// place whose root is a mutable local.  Reusing it exactly means a
    /// receiver is legal in precisely the positions an assignment
    /// target is, and the two can never drift.
    fn receiverPlace(
        self: *FunctionBuilder,
        method: ast.Method,
        info: context.FunctionDeclInfo,
    ) Error!?struct { root: LocalId, accessors: []const mir.build.Lowering.Step } {
        _ = info;
        switch (method.target.*) {
            .name => |name| {
                const found = self.findLocal(name.text) orelse return null;
                if (!found.info.mutable) {
                    try self.fail(
                        "luce.sema.let",
                        name.span,
                        "{s} is let-bound; {s} takes var self and writes back to its receiver — use var",
                        .{ name.text, method.name },
                    );
                    return null;
                }
                return .{ .root = found.info.local, .accessors = &.{} };
            },
            else => {
                try self.fail(
                    "luce.sema.self",
                    method.span,
                    "{s} takes var self, so its receiver must be a variable — not a call result or a temporary",
                    .{method.name},
                );
                return null;
            },
        }
    }

    /// How the reader spelled the receiver, for a message that has to
    /// hand back the static form: the bare name where there is one,
    /// and the struct's own word where the receiver is an expression.
    fn writtenReceiver(self: *FunctionBuilder, method: ast.Method) Error![]const u8 {
        return self.writtenTarget(method.target);
    }

    fn writtenTarget(self: *FunctionBuilder, target: *const ast.Expression) Error![]const u8 {
        _ = self;
        return switch (target.*) {
            .name => |name| name.text,
            else => "the receiver",
        };
    }

    /// `p.foo()` where `Point` has no `foo` at all.
    ///
    /// **This replaces "Point has no methods"**, which was true until
    /// a struct could have one and would now be a lie.  It offers the
    /// closest method there actually is, which is what the list, map
    /// and builder families already do.
    fn failUnknownMethod(
        self: *FunctionBuilder,
        receiver: Type,
        written_name: []const u8,
        method: ast.Method,
    ) Error!void {
        var suggestion = helpers.Suggestion.init(method.name);
        for (self.analyzer.functions.items) |candidate| {
            const owner = candidate.enclosing orelse continue;
            if (!owner.asType().eql(receiver)) continue;
            if (candidate.receiver == .not) continue;
            // Never a method this module cannot call (VISIBILITY.md D2).
            if (candidate.declaration.visibility == .private and candidate.module != self.module) continue;
            const dot = std.mem.lastIndexOfScalar(u8, candidate.name, '.') orelse continue;
            suggestion.offer(candidate.name[dot + 1 ..]);
        }
        if (suggestion.best()) |closest| {
            try self.fail("luce.sema.method", method.span, "{s} has no method {s}; did you mean {s}?", .{
                written_name, method.name, closest,
            });
            return;
        }
        try self.fail("luce.sema.method", method.span, "{s} has no method {s}", .{ written_name, method.name });
    }

    /// Which argument of a method is a *store* into the receiver —
    /// the one `libluce_rt` will keep rather than read.  The positions
    /// are `Intrinsic.storedArgument`'s; this adds the receiver's
    /// shape, which is what says a list is being appended to and not a
    /// builder of the same spelling.
    fn storedElement(self: *const FunctionBuilder, kind: mir.Intrinsic, receiver: Type) ?usize {
        const descriptor = self.analyzer.heapOf(receiver) orelse return null;
        if (descriptor != .list) return null;
        return kind.storedArgument();
    }

    /// A builtin method's arguments are positional (docs/ARGS.md D10):
    /// its tables hold types computed from the receiver and no names,
    /// and a parallel name list would be exactly the drift the
    /// one-table comment on `builtins` records.  True after reporting.
    fn refuseNamedMethodArguments(self: *FunctionBuilder, method: ast.Method) Error!bool {
        for (method.arguments) |argument| {
            if (argument.name == null) continue;
            try self.fail(
                "luce.sema.method",
                argument.span,
                "{s} is a builtin method and its arguments are positional",
                .{method.name},
            );
            return true;
        }
        return false;
    }

    const MethodFound = struct { kind: mir.Intrinsic, result: Type };

    fn methodFail(self: *FunctionBuilder, method: ast.Method, comptime message: []const u8) Error!?MethodFound {
        try self.fail("luce.sema.method", method.span, message, .{});
        return null;
    }

    /// Check a built-in method's arguments against the types it takes,
    /// and say the one thing that is wrong.
    ///
    /// This is the sentence `lowerUserCall` writes for a user
    /// function, and a built-in method had better earn the same one:
    /// the count sentence names both counts, the type sentence names
    /// the position, the type wanted and the type given, and it is
    /// underlined at the argument that is wrong rather than at the
    /// whole call.  Before this existed each method wrote one sentence
    /// for both mistakes — `xs.append("hi")` on a `list(long)` was told
    /// "append takes one element value", which is an answer to a
    /// question the reader did not ask, since they passed exactly one.
    ///
    /// A `T?` standing where a `T` belongs collects the same advice it
    /// collects anywhere else; that advice is most of what teaches the
    /// feature, and dropping it here taught it in one place fewer.
    ///
    /// False after reporting.  `wanted` is positional and its length
    /// is the arity.
    /// What a method takes, given the receiver it is called on — **the
    /// one table**, and null when the receiver has no such method.
    ///
    /// It is consulted twice, which is the whole reason it exists as a
    /// function rather than as `&.{...}` in the dispatch below.  Once
    /// by `lowerOperandsInto`, *before* an argument is lowered, so a
    /// numeric literal lands at the type the receiver names: a number
    /// has no type until it meets one (docs/TYPES.md D3), and
    /// `xs.append(0.1)` on a `list(double)` must store binary64's 0.1,
    /// which is not what widening binary32's 0.1 produces.  And once
    /// by `methodTakes`, to check what actually arrived.  Two answers
    /// from one table cannot disagree; two tables would.
    ///
    /// A **struct** receiver is not answered here: its methods are
    /// user declarations, and `landsOn` reads the declaration through
    /// `structMethod` so a *named* argument can land at the slot it
    /// fills rather than the position it sits at (docs/ARGS.md §4).
    /// This table is builtin methods only, and they are positional.
    ///
    /// A string receiver whose name is not a primitive answers null:
    /// that call is `strings.name(s, ...)`, a library function with a
    /// signature of its own, and the ordinary call path lands its
    /// arguments.
    fn methodParameters(self: *FunctionBuilder, receiver: Type, name: []const u8) Error!?[]const Type {
        if (receiver == .string) {
            for (string_methods) |primitive| {
                if (std.mem.eql(u8, name, primitive.name)) return primitive.takes;
            }
            return null;
        }
        const descriptor = self.analyzer.heapOf(receiver) orelse return null;
        return switch (descriptor) {
            .list => |element| self.sequenceParameters(name, element, true),
            .array => |shape| blk: {
                if (std.mem.eql(u8, name, "dim")) break :blk try self.typeList(&.{.long});
                if (std.mem.eql(u8, name, "fill")) break :blk try self.typeList(&.{shape.element});
                break :blk self.sequenceParameters(name, shape.element, false);
            },
            .map => |pair| blk: {
                if (std.mem.eql(u8, name, "has") or
                    std.mem.eql(u8, name, "remove")) break :blk try self.typeList(&.{pair.key});
                if (std.mem.eql(u8, name, "get")) break :blk try self.typeList(&.{ pair.key, pair.value });
                if (std.mem.eql(u8, name, "keys") or
                    std.mem.eql(u8, name, "values") or
                    std.mem.eql(u8, name, "clear")) break :blk &.{};
                break :blk null;
            },
            .builder => blk: {
                if (std.mem.eql(u8, name, "append")) break :blk try self.typeList(&.{.string});
                if (std.mem.eql(u8, name, "append_ascii")) break :blk try self.typeList(&.{.long});
                if (std.mem.eql(u8, name, "build") or
                    std.mem.eql(u8, name, "clear")) break :blk &.{};
                break :blk null;
            },
            .file => blk: {
                // The buffer is the caller's `array(byte, n)`, and the
                // count a write takes is a `long`.  Neither landing
                // depends on the receiver, so both are written out.
                if (std.mem.eql(u8, name, "read")) break :blk try self.typeList(&.{
                    try self.analyzer.internHeapType(.{ .array = .{ .element = .byte, .rank = 1 } }),
                });
                if (std.mem.eql(u8, name, "write")) break :blk try self.typeList(&.{
                    try self.analyzer.internHeapType(.{ .array = .{ .element = .byte, .rank = 1 } }),
                    .long,
                });
                if (std.mem.eql(u8, name, "flush")) break :blk &.{};
                break :blk null;
            },
        };
    }

    /// The list and array half of `methodParameters`.  A `list(T)` and
    /// a rank-1 `array(T, _)` answer to the same names; `growable`
    /// says which four only a list has.
    fn sequenceParameters(
        self: *FunctionBuilder,
        name: []const u8,
        element: Type,
        growable: bool,
    ) Error!?[]const Type {
        if (growable) {
            if (std.mem.eql(u8, name, "append")) return try self.typeList(&.{element});
            if (std.mem.eql(u8, name, "insert")) return try self.typeList(&.{ .long, element });
            if (std.mem.eql(u8, name, "remove")) return try self.typeList(&.{.long});
            if (std.mem.eql(u8, name, "pop")) return &.{};
        }
        if (std.mem.eql(u8, name, "sort") or std.mem.eql(u8, name, "reverse")) return &.{};
        if (std.mem.eql(u8, name, "clear") and growable) return &.{};
        if (std.mem.eql(u8, name, "find") or std.mem.eql(u8, name, "contains")) {
            return try self.typeList(&.{element});
        }
        return null;
    }

    /// A parameter list in arena storage, because the element and key
    /// types in one are the receiver's and not compile-time constants.
    fn typeList(self: *FunctionBuilder, items: []const Type) Error![]const Type {
        return self.arena().dupe(Type, items);
    }

    /// Check a method's arguments against the types it takes, and
    /// widen the ones that reach them by widening — an `int` handed to
    /// a `list(double)`'s `append` is a `double` (docs/TYPES.md §2).
    /// The arguments are rewritten in place, because the registers the
    /// caller goes on to pass are these.
    ///
    /// A *literal* argument does not reach here needing a widening at
    /// all: it landed at this type when it was lowered, from this same
    /// table (`methodParameters`).
    fn methodTakes(
        self: *FunctionBuilder,
        method: ast.Method,
        arguments: []Typed,
        receiver: Type,
    ) Error!bool {
        // The dispatch below matched this name against the same table,
        // so a null here would mean the two had drifted apart.
        const wanted = (try self.methodParameters(receiver, method.name)).?;
        if (arguments.len != wanted.len) {
            try self.fail("luce.sema.method", method.span, "{s} takes {d} argument{s}, got {d}", .{
                method.name,
                wanted.len,
                helpers.plural(wanted.len),
                arguments.len,
            });
            return false;
        }
        for (arguments, wanted, 0..) |*argument, want, index| {
            if (argument.value_type.widensTo(want)) {
                argument.* = try self.widenNumeric(argument.*, want);
            }
            if (argument.value_type.eql(want)) continue;
            try self.fail(
                "luce.sema.type",
                method.arguments[index].span,
                "argument {d} of {s} is {s}, got {s}{s}",
                .{
                    index + 1,
                    method.name,
                    try self.analyzer.typeName(want),
                    try self.analyzer.typeName(argument.value_type),
                    try self.absenceAdvice(argument.value_type, method.arguments[index].value),
                },
            );
            return false;
        }
        return true;
    }

    /// Route a value method to the std strings module: `s.find(x)` is
    /// `strings.find(s, x)`, and `parts.join(sep)` is
    /// `strings.join(parts, sep)`.  The language keeps the primitives
    /// (literals, +, comparison, slices, len, byte_at); manipulation
    /// is library code and needs the import.
    fn stringsCall(
        self: *FunctionBuilder,
        method: ast.Method,
        values: []const Typed,
        as_statement: bool,
    ) Error!?Typed {
        const local_module = std.mem.eql(u8, self.prefix, "strings");
        if (!local_module and !self.analyzer.importsModule(self.module, "strings")) {
            try self.fail(
                "luce.sema.import",
                method.span,
                "string manipulation lives in the standard library: import std.strings to use {s} (docs/STD.md)",
                .{method.name},
            );
            return null;
        }
        // The routed spelling stays positional: the batch landed its
        // arguments from the receiver, not from strings' declaration,
        // so a reordered literal would land at the wrong width.  The
        // static spelling names freely (docs/ARGS.md D10).
        for (method.arguments) |argument| {
            if (argument.name == null) continue;
            try self.fail(
                "luce.sema.method",
                argument.span,
                "{s} routes to std.strings and its arguments are positional here; write strings.{s}(…) to name them",
                .{ method.name, method.name },
            );
            return null;
        }
        // strings takes borrows only; a give here has no owner (S11).
        for (method.arguments) |argument| {
            if (argument.value.* == .give) {
                try self.fail(
                    "luce.sema.own",
                    argument.span,
                    "{s} only borrows its arguments; give needs an owning destination [OWNERSHIP.md S11, S13]",
                    .{method.name},
                );
                return null;
            }
        }
        const qualified = try std.fmt.allocPrint(self.arena(), "strings.{s}", .{method.name});
        const function_index = self.analyzer.function_names.get(qualified) orelse {
            var suggestion = helpers.Suggestion.init(method.name);
            var entries = self.analyzer.function_names.iterator();
            while (entries.next()) |entry| {
                if (!std.mem.startsWith(u8, entry.key_ptr.*, "strings.")) continue;
                // A withheld helper is not a method anyone is owed
                // (VISIBILITY.md D2).
                const info = self.analyzer.functions.items[entry.value_ptr.*];
                if (info.declaration.visibility == .private and info.module != self.module) continue;
                suggestion.offer(entry.key_ptr.*["strings.".len..]);
            }
            // The reader wrote a method on a string; `strings` is the
            // module it routes to, and answering with the routing
            // target names something they never typed.  Say what they
            // asked about, then where the answer would have lived.
            if (suggestion.best()) |closest| {
                try self.fail("luce.sema.method", method.span, "string has no method {s}; did you mean {s}?", .{ method.name, closest });
            } else {
                try self.fail("luce.sema.method", method.span, "string has no method {s}, and neither has the strings module", .{method.name});
            }
            return null;
        };
        // A `strings` routing is a call like any other, and the
        // module's functions do not fail, so nothing is permitted
        // here: `s.split(",")` can never need a `try`.
        return self.callUser(function_index, qualified, values, method.span, as_statement, false);
    }

    /// The emitting half of a user call, for callers that already
    /// lowered their operands (method routing): arity and type checks
    /// against the signature, then the call instruction.
    fn callUser(
        self: *FunctionBuilder,
        function_index: u32,
        name: []const u8,
        values: []const Typed,
        span: Span,
        as_statement: bool,
        fallible_allowed: bool,
    ) Error!?Typed {
        // The method sugar routes to the same declaration and the same
        // refusal, so the leak has no second door (VISIBILITY.md §1):
        // `s.fold_case(…)` arrives here as `strings.fold_case`.
        if (!try self.functionReachable(function_index, span)) return null;
        const info = self.analyzer.functions.items[function_index];
        // **The whole of why a swallowed failure is unwritable.**  A
        // function that says it can fail cannot be called as if it
        // could not, so `if files.write_lines(...)` with no else is a
        // shape the grammar no longer has (docs/FAILURE.md).
        if (info.fallible and !fallible_allowed) {
            try self.fail(
                "luce.sema.fallible",
                span,
                "{s} can fail: write 'try {s}(…)' to pass the error on, or '{s}(…) catch …' to handle it",
                .{ name, name, name },
            );
            return null;
        }
        const total = info.parameter_types.len;
        if (info.parameter_defaults.len != total) return null; // the declaration already carries a diagnostic
        const covered = values.len <= total and covered: {
            for (info.parameter_defaults[values.len..]) |default| {
                if (default == null) break :covered false;
            }
            break :covered true;
        };
        if (!covered) {
            var defaulted: usize = 0;
            for (info.parameter_defaults) |default| {
                if (default != null) defaulted += 1;
            }
            if (defaulted != 0) {
                const required = total - defaulted;
                try self.fail("luce.sema.call", span, "{s} takes {d} argument{s} and {d} with a default, got {d}", .{
                    name,
                    required,
                    helpers.plural(required),
                    defaulted,
                    values.len,
                });
            } else {
                try self.fail("luce.sema.call", span, "{s} takes {d} argument{s}, got {d}", .{
                    name,
                    total,
                    helpers.plural(total),
                    values.len,
                });
            }
            return null;
        }
        const registers = try self.arena().alloc(Register, total);
        for (values, 0..) |value, index| {
            const fitted = (try self.fit(value, info.parameter_types[index])) orelse {
                try self.fail("luce.sema.type", span, "argument {d} of {s} is {s}, got {s}{s}", .{
                    index + 1,
                    name,
                    try self.analyzer.typeName(info.parameter_types[index]),
                    try self.analyzer.typeName(value.value_type),
                    try self.absenceAdvice(value.value_type, null),
                });
                return null;
            };
            registers[index] = fitted.register;
        }
        // The suffix the call omitted takes its defaults — how the
        // routed spelling `s.find(x)` reaches a `find` with a
        // defaulted `start` (docs/ARGS.md D2, D3).
        for (info.parameter_defaults[values.len..], values.len..) |maybe_default, slot| {
            const filled = maybe_default.?;
            const made: Typed = .{
                .register = try self.emitConstantValue(filled.value, filled.value_type),
                .value_type = filled.value_type,
            };
            try self.parkFreshStorage(made);
            registers[slot] = made.register;
        }
        if (info.return_type == .none and !as_statement) {
            try self.fail("luce.sema.call", span, "{s} returns nothing", .{name});
            return null;
        }
        const call = try self.code.emit(
            .{ .call = .{ .function = function_index, .arguments = registers } },
            info.return_type,
        );
        if (info.fallible) return try self.openFallible(call, info.return_type);
        return .{ .register = call, .value_type = info.return_type };
    }

    /// `descriptor` is the receiver's *shape*, which is everything the
    /// dispatch below turns on: a `list(long)` and a `list(string)`
    /// answer to the same method names and differ only in what the
    /// element type makes of the arguments, and the descriptor carries
    /// that.  The receiver's `Type` adds nothing on top of it.
    // Method tables, by receiver shape ----------------------------------------

    fn objectMethod(
        self: *FunctionBuilder,
        method: ast.Method,
        receiver: Type,
        descriptor: types.HeapType,
        arguments: []Typed,
    ) Error!?MethodFound {
        const name = method.name;
        switch (descriptor) {
            .list => |element| return self.sequenceMethod(method, receiver, element, true, arguments),
            .array => |shape| {
                if (std.mem.eql(u8, name, "dim")) {
                    if (!try self.methodTakes(method, arguments, receiver)) return null;
                    return .{ .kind = .dim_size, .result = .long };
                }
                if (std.mem.eql(u8, name, "fill")) {
                    if (!try self.methodTakes(method, arguments, receiver)) return null;
                    // One value cannot own every slot (S21, S23):
                    // arrays of objects store per slot instead.
                    if (self.analyzer.carriesObjects(shape.element)) {
                        try self.fail(
                            "luce.sema.own",
                            method.span,
                            "fill copies one value into every slot; an array of objects stores each slot separately [OWNERSHIP.md S21, S23]",
                            .{},
                        );
                        return null;
                    }
                    return .{ .kind = .array_fill, .result = .none };
                }
                if (shape.rank != 1) {
                    try self.fail("luce.sema.method", method.span, "only rank-1 arrays have {s}; index higher ranks", .{name});
                    return null;
                }
                return self.sequenceMethod(method, receiver, shape.element, false, arguments);
            },
            .map => |pair| {
                if (std.mem.eql(u8, name, "has")) {
                    if (!try self.methodTakes(method, arguments, receiver)) return null;
                    return .{ .kind = .has_key, .result = .boolean };
                }
                if (std.mem.eql(u8, name, "remove")) {
                    if (!try self.methodTakes(method, arguments, receiver)) return null;
                    return .{ .kind = .remove_entry, .result = .none };
                }
                if (std.mem.eql(u8, name, "keys")) {
                    if (!try self.methodTakes(method, arguments, receiver)) return null;
                    return .{ .kind = .map_keys, .result = try self.analyzer.internHeapType(.{ .list = pair.key }) };
                }
                if (std.mem.eql(u8, name, "values")) {
                    if (!try self.methodTakes(method, arguments, receiver)) return null;
                    return .{ .kind = .map_values, .result = try self.analyzer.internHeapType(.{ .list = pair.value }) };
                }
                if (std.mem.eql(u8, name, "get")) {
                    if (!try self.methodTakes(method, arguments, receiver)) return null;
                    return .{ .kind = .map_get, .result = pair.value };
                }
                if (std.mem.eql(u8, name, "clear")) {
                    if (!try self.methodTakes(method, arguments, receiver)) return null;
                    return .{ .kind = .clear_object, .result = .none };
                }
                var suggestion = helpers.Suggestion.init(name);
                suggestion.offerAll(&map_methods);
                if (suggestion.best()) |closest| {
                    try self.fail("luce.sema.method", method.span, "map has no method {s}; did you mean {s}?", .{ name, closest });
                } else {
                    try self.fail("luce.sema.method", method.span, "map has no method {s} (has get remove keys values clear)", .{name});
                }
                return null;
            },
            .builder => {
                // The method a builder should always have had.  Its
                // text used to come out through `b.build()`, which made
                // the one free builtin that took a heap object — and
                // is why `str` could not simply be renamed
                // `string` (docs/NUMERICS.md §7).
                if (std.mem.eql(u8, name, "build")) {
                    if (!try self.methodTakes(method, arguments, receiver)) return null;
                    return .{ .kind = .str_value, .result = .string };
                }
                if (std.mem.eql(u8, name, "append")) {
                    if (!try self.methodTakes(method, arguments, receiver)) return null;
                    return .{ .kind = .append_value, .result = .none };
                }
                if (std.mem.eql(u8, name, "append_ascii")) {
                    if (!try self.methodTakes(method, arguments, receiver)) return null;
                    return .{ .kind = .append_ascii, .result = .none };
                }
                if (std.mem.eql(u8, name, "clear")) {
                    if (!try self.methodTakes(method, arguments, receiver)) return null;
                    return .{ .kind = .clear_object, .result = .none };
                }
                var suggestion = helpers.Suggestion.init(name);
                suggestion.offerAll(&builder_methods);
                if (suggestion.best()) |closest| {
                    try self.fail("luce.sema.method", method.span, "builder has no method {s}; did you mean {s}?", .{ name, closest });
                } else {
                    try self.fail("luce.sema.method", method.span, "builder has no method {s} (append append_ascii build clear)", .{name});
                }
                return null;
            },
            // The byte channel (docs/BYTES.md R4).  A read fills the
            // caller's buffer and answers how many bytes landed — zero
            // is the end of the file — and a write takes a buffer and
            // a count and answers how many landed.  All three are
            // fallible: the world decides.  There is no `close`,
            // because `free f` is one and the end of the owning scope
            // is the other (OWNERSHIP.md, unchanged).
            .file => {
                if (std.mem.eql(u8, name, "read")) {
                    if (!try self.methodTakes(method, arguments, receiver)) return null;
                    return .{ .kind = .handle_read, .result = .long };
                }
                if (std.mem.eql(u8, name, "write")) {
                    if (!try self.methodTakes(method, arguments, receiver)) return null;
                    return .{ .kind = .handle_write, .result = .long };
                }
                if (std.mem.eql(u8, name, "flush")) {
                    if (!try self.methodTakes(method, arguments, receiver)) return null;
                    return .{ .kind = .handle_flush, .result = .none };
                }
                var suggestion = helpers.Suggestion.init(name);
                suggestion.offerAll(&file_methods);
                if (suggestion.best()) |closest| {
                    try self.fail("luce.sema.method", method.span, "file has no method {s}; did you mean {s}?", .{ name, closest });
                } else {
                    try self.fail("luce.sema.method", method.span, "file has no method {s} (read write flush; free f closes it)", .{name});
                }
                return null;
            },
        }
    }

    /// Methods shared by list and rank-1 array; growth operations are
    /// list-only.
    fn sequenceMethod(
        self: *FunctionBuilder,
        method: ast.Method,
        receiver: Type,
        element: Type,
        growable: bool,
        arguments: []Typed,
    ) Error!?MethodFound {
        const name = method.name;
        if (growable) {
            if (std.mem.eql(u8, name, "append")) {
                if (!try self.methodTakes(method, arguments, receiver)) return null;
                return .{ .kind = .append_value, .result = .none };
            }
            if (std.mem.eql(u8, name, "insert")) {
                if (!try self.methodTakes(method, arguments, receiver)) return null;
                return .{ .kind = .insert_value, .result = .none };
            }
            if (std.mem.eql(u8, name, "remove")) {
                if (!try self.methodTakes(method, arguments, receiver)) return null;
                return .{ .kind = .remove_entry, .result = .none };
            }
            if (std.mem.eql(u8, name, "pop")) {
                if (!try self.methodTakes(method, arguments, receiver)) return null;
                return .{ .kind = .pop_value, .result = element };
            }
            if (std.mem.eql(u8, name, "clear")) {
                if (!try self.methodTakes(method, arguments, receiver)) return null;
                return .{ .kind = .clear_object, .result = .none };
            }
        }
        if (std.mem.eql(u8, name, "sort")) {
            if (!try self.methodTakes(method, arguments, receiver)) return null;
            const ordered = element.isNumeric() or element == .string;
            if (!ordered) return self.methodFail(method, "sort orders numbers or string elements");
            return .{ .kind = .list_sort, .result = .none };
        }
        if (std.mem.eql(u8, name, "reverse")) {
            if (!try self.methodTakes(method, arguments, receiver)) return null;
            return .{ .kind = .list_reverse, .result = .none };
        }
        if (std.mem.eql(u8, name, "find")) {
            if (!try self.methodTakes(method, arguments, receiver)) return null;
            return .{ .kind = .list_find, .result = .long };
        }
        if (std.mem.eql(u8, name, "contains")) {
            if (!try self.methodTakes(method, arguments, receiver)) return null;
            return .{ .kind = .list_contains, .result = .boolean };
        }
        // "here" was the only word naming the receiver, and it names
        // nothing: map and builder both say which they are, and a
        // reader who mistook a list for a map needs exactly that.
        const shape_word = if (growable) "list" else "array";
        var suggestion = helpers.Suggestion.init(name);
        suggestion.offerAll(if (growable) &list_methods else &array_methods);
        if (suggestion.best()) |closest| {
            try self.fail("luce.sema.method", method.span, "{s} has no method {s}; did you mean {s}?", .{ shape_word, name, closest });
            return null;
        }
        if (growable) {
            try self.fail("luce.sema.method", method.span, "list has no method {s} (has append insert remove pop sort reverse find contains clear; join lives in strings)", .{name});
            return null;
        }
        try self.fail("luce.sema.method", method.span, "array has no method {s} (has dim fill sort reverse find contains)", .{name});
        return null;
    }

    // Construction and conversion ---------------------------------------------

    fn lowerConstruct(
        self: *FunctionBuilder,
        call_arguments: []const ast.Argument,
        span: Span,
        layout_index: u32,
    ) Error!?Typed {
        const layout = self.analyzer.structs.items[layout_index];
        // A marked struct constructed outside its module is the type
        // refusal; construction is never reached (VISIBILITY.md §8).
        const decl_info = self.analyzer.struct_decls.items[layout_index];
        if (decl_info.declaration.visibility == .private and decl_info.module != self.module) {
            try self.fail("luce.sema.private", span, "{s} is private to {s}", .{
                decl_info.declaration.name,
                self.analyzer.moduleName(decl_info.module),
            });
            return null;
        }
        if (layout.fields.len == 0) {
            try self.fail(
                "luce.sema.construct",
                span,
                context.namespace_has_no_fields_message,
                .{layout.name},
            );
            return null;
        }
        const registers = try self.arena().alloc(Register, layout.fields.len);
        var seen = try self.temporary().alloc(bool, layout.fields.len);
        defer self.temporary().free(seen);
        @memset(seen, false);

        // Which field each argument fills is settled before any of them
        // is lowered: it is what says what type the argument lands in,
        // and a bare `none` has no type until something says.
        const expressions = try self.arena().alloc(*ast.Expression, call_arguments.len);
        const fields = try self.arena().alloc(u32, call_arguments.len);
        const expected_types = try self.arena().alloc(Type, call_arguments.len);
        for (call_arguments, expressions, fields, expected_types) |argument, *slot, *field, *wanted| {
            const name = argument.name orelse {
                try self.fail("luce.sema.construct", argument.span, "{s} is built with named fields: {s}(field = ...)", .{ layout.name, layout.name });
                return null;
            };
            const field_index = layout.findField(name) orelse {
                try self.failUnknownField("luce.sema.construct", layout_index, name, argument.span);
                return null;
            };
            // Naming a private field — even one with a default — is
            // refused: a default is the module's chosen value for a
            // slot the module kept (VISIBILITY.md §3).
            if (!try self.fieldReachable(layout_index, field_index, argument.span)) return null;
            if (seen[field_index]) {
                try self.fail("luce.sema.construct", argument.span, context.duplicate_field_message, .{name});
                return null;
            }
            seen[field_index] = true;
            slot.* = argument.value;
            field.* = field_index;
            wanted.* = layout.fields[field_index].field_type;
        }
        const values = (try self.lowerOperandsInto(expressions, .{ .places = expected_types })) orelse return null;
        for (call_arguments, values, fields, expected_types) |argument, value, field_index, expected| {
            const name = argument.name.?;
            const fitted = (try self.fit(value, expected)) orelse {
                try self.fail("luce.sema.type", argument.span, "{s}.{s} is {s}, got {s}{s}", .{
                    layout.name,
                    name,
                    try self.analyzer.typeName(expected),
                    try self.analyzer.typeName(value.value_type),
                    try self.mismatchAdvice(expected, value.value_type, argument.value),
                });
                return null;
            };
            // Object fields follow the verb rule at construction
            // (S24): the binding that receives the struct owns them.
            // `none` owns nothing, so it is always a legal filling.
            if (self.analyzer.carriesObjects(expected) and
                argument.value.* != .none_literal and
                !(try self.yieldsOwnership(argument.value)))
            {
                try self.failNeedsOwnership(
                    argument.span,
                    try std.fmt.allocPrint(self.arena(), "{s}.{s} keeps its object", .{ layout.name, name }),
                    argument.value,
                    "S21, S24",
                );
                return null;
            }
            // A struct owns its field run and every value in it, so
            // construction is a store like any other (docs/STRINGS.md).
            registers[field_index] = try self.ownedForStore(fitted);
        }
        // A field nobody wrote takes its default (docs/ARGS.md D8):
        // the constant register the written value would have produced,
        // and the same store it would have taken — so only the
        // required fields can be missing.
        for (seen, 0..) |given, field_index| {
            if (given) continue;
            if (!self.analyzer.fieldHasDefault(layout_index, field_index)) continue;
            const filled = (try self.analyzer.fieldDefault(layout_index, field_index)) orelse return null;
            const made = try self.emitConstantValue(filled.value, filled.value_type);
            registers[field_index] = try self.ownedForStore(.{
                .register = made,
                .value_type = filled.value_type,
            });
            seen[field_index] = true;
        }
        // A still-missing field has no default.  Missing and *private*
        // makes the struct not constructible here at all, and the
        // diagnostic names the pattern that is: a public function of
        // the declaring module (VISIBILITY.md §3).
        if (decl_info.module != self.module) {
            for (seen, 0..) |given, field_index| {
                if (given) continue;
                if (field_index >= decl_info.field_visibility.len) continue;
                if (decl_info.field_visibility[field_index] != .private) continue;
                try self.fail(
                    "luce.sema.private",
                    span,
                    "{s} cannot be constructed here: {s} is marked private in {s} and has no default; construction belongs to a public function of {s}",
                    .{
                        decl_info.declaration.name,
                        layout.fields[field_index].name,
                        self.analyzer.moduleName(decl_info.module),
                        self.analyzer.moduleName(decl_info.module),
                    },
                );
                return null;
            }
        }
        for (seen) |given| {
            if (given) continue;
            var missing: std.ArrayList(u8) = .empty;
            defer missing.deinit(self.temporary());
            try context.writeMissingFields(&missing, self.temporary(), layout, seen);
            try self.fail("luce.sema.construct", span, context.missing_field_message, .{
                layout.name,
                missing.items,
            });
            return null;
        }
        const result_type: Type = .{ .strukt = layout_index };
        return .{
            .register = try self.code.emit(.{ .struct_make = .{ .layout = layout_index, .fields = registers } }, result_type),
            .value_type = result_type,
        };
    }

    /// `int(x)`, `long(x)`, `float(x)`, `double(x)`, `string(x)` — the
    /// conversion constructors, each named for the type it produces
    /// (docs/TYPES.md §3).  They are matched by name here, before
    /// name resolution, which is why they are not in the builtin
    /// table and why `string` is a reserved name.
    ///
    /// `string(x)` takes the scalars and nothing else: a `builder` is
    /// a heap object and its text comes out through `b.build()`, which
    /// is the method it should always have had.
    /// `Method(n)` — the number→enum direction, which answers
    /// `Method?` (docs/ENUMS.md R2).
    ///
    /// **It is the parse case, not the arithmetic case.**  The number
    /// arrives from a file, a wire or a spec field, and *unknown
    /// member* is precisely what the caller has to branch on — so this
    /// answers absence rather than trapping, and the caller writes
    /// `else` or narrows, like every other absence.
    ///
    /// The lowering is the same compare-and-branch tree `match` is: one
    /// equality per member against the number widened to `long`, each
    /// answering the member it matched, and absence where none did.
    /// Nothing is narrowed and nothing traps, which is what lets a
    /// `byte`-backed enum be asked about a number no `byte` could hold.
    fn lowerEnumOfNumber(
        self: *FunctionBuilder,
        written_name: []const u8,
        arguments: []const ast.Argument,
        span: Span,
        enum_index: u32,
    ) Error!?Typed {
        const info = self.analyzer.enum_decls.items[enum_index];
        if (info.declaration.visibility == .private and info.module != self.module) {
            try self.fail("luce.sema.private", span, "{s} is private to {s}", .{
                info.declaration.name,
                self.analyzer.moduleName(info.module),
            });
            return null;
        }
        if (arguments.len != 1 or !helpers.argumentMayName(arguments[0], "value")) {
            try self.fail("luce.sema.convert", span, "{s}(value) takes one number", .{written_name});
            return null;
        }
        const declared = self.analyzer.enums.items[enum_index];
        const of = self.analyzer.enumType(enum_index);
        const answer = Type.optionalOf(of).?;

        // The number lands on `long`: every member's value fits one
        // whatever the backing width is, so the comparison is exact and
        // a number past the width simply matches nothing.
        self.wanted = .long;
        const number = (try self.lowerExpression(arguments[0].value, false)) orelse return null;
        if (!number.value_type.isInteger()) {
            try self.fail(
                "luce.sema.convert",
                span,
                "{s}(value) reads a whole number and answers {s}?; {s} is not one{s}",
                .{
                    written_name,
                    declared.name,
                    try self.analyzer.typeName(number.value_type),
                    try self.absenceAdvice(number.value_type, arguments[0].value),
                },
            );
            return null;
        }
        const widened = if (number.value_type.eql(.long))
            number
        else
            try self.widenNumeric(number, .long);
        const held = try self.code.spill(widened.register, .long);

        // Absence first, so the slot has a value on every path; each
        // arm that matches overwrites it.
        const absent = try self.code.emit(
            .{ .intrinsic = .{ .kind = .none_value, .arguments = &.{} } },
            answer,
        );
        const result = try self.code.spill(absent, answer);

        var frames: std.ArrayList(mir.build.Lowering.Conditional) = .empty;
        defer frames.deinit(self.temporary());
        for (declared.members) |member| {
            const value = try self.code.emit(.{ .const_long = member.value }, .long);
            const same = try self.code.emit(.{ .binary = .{
                .op = .equal,
                .operand_type = .long,
                .left = try self.code.load(held),
                .right = value,
            } }, .boolean);
            const arms = try self.code.openIf(same, true);
            const found = try self.code.emit(.{ .const_long = member.value }, of);
            const wrapped = try self.arena().alloc(Register, 1);
            wrapped[0] = found;
            try self.code.store(result, try self.code.emit(
                .{ .intrinsic = .{ .kind = .optional_wrap, .arguments = wrapped } },
                answer,
            ));
            try self.code.elseArm(arms);
            try frames.append(self.temporary(), arms);
        }
        while (frames.pop()) |arms| try self.code.closeIf(arms);
        return .{ .register = try self.code.load(result), .value_type = answer };
    }

    fn lowerConvert(self: *FunctionBuilder, call: ast.Call) Error!?Typed {
        // One slot, named `value` like the reference spells it
        // (docs/ARGS.md D1: names are optional everywhere, so the
        // constructors take theirs too).
        if (call.arguments.len != 1 or !helpers.argumentMayName(call.arguments[0], "value")) {
            try self.fail("luce.sema.convert", call.span, "{s}(value) takes one argument", .{call.callee});
            return null;
        }
        const produces = conversionNamed(call.callee).?;
        // **A constructor is a written-down type, so its argument lands
        // on it.**  Without this `double(0.1)` reads `0.1` at binary32
        // and then widens the wrong number, which is the same
        // double-rounding a `list(double)` literal would have had — and
        // `long(3000000000)` would be refused for not fitting an `int`
        // that nobody wrote.  A literal has no type until it meets one
        // (docs/TYPES.md §1), and here it meets the constructor's.
        self.wanted = switch (produces) {
            .byte => .byte,
            .short => .short,
            .int => .int,
            .long => .long,
            .half => .half,
            .float => .float,
            .double => .double,
            .boolean, .string, .list, .map, .array, .builder, .file => null,
        };
        const value = (try self.lowerExpression(call.arguments[0].value, false)) orelse return null;
        // **A conversion accepts an enum exactly because it is named
        // for what it produces** (docs/ENUMS.md D4): `int(m)` is the
        // member's number, and `string(m)` is the member's *name* —
        // which is a different act from printing a number, and the one
        // an f-string hole performs for a reader who wrote none.
        if (value.value_type == .enumeration) {
            if (produces == .string) return self.lowerEnumName(value);
            return self.lowerEnumToNumber(call, value, produces);
        }
        if (produces == .string) {
            switch (value.value_type) {
                .string => return value,
                .byte, .short, .int, .long, .half, .float, .double, .boolean => {},
                .heap => {
                    const descriptor = self.analyzer.heapOf(value.value_type).?;
                    if (descriptor == .builder) {
                        try self.fail(
                            "luce.sema.convert",
                            call.span,
                            "string() converts a scalar; a builder hands over its text with .build()",
                            .{},
                        );
                        return null;
                    }
                    return self.failConvert(call, value);
                },
                else => return self.failConvert(call, value),
            }
            const arguments = try self.arena().alloc(Register, 1);
            arguments[0] = value.register;
            const made = try self.code.emit(
                .{ .intrinsic = .{ .kind = .str_value, .arguments = arguments } },
                .string,
            );
            // Fresh bytes nothing parked: the statement's end reclaims
            // them unless a place adopts them (docs/STRINGS.md).
            const answer: Typed = .{ .register = made, .value_type = .string };
            try self.parkFreshStorage(answer);
            return answer;
        }
        // Every other constructor is named for a numeric type and
        // produces it, from any number: one rule, and it needs no arm
        // per pair (docs/TYPES.md §3).  `long(x)` where `x` is already
        // a `long` is the identity — the constructors are how you
        // widen without an operator to hang it on, so a redundant one
        // is not a mistake to report.
        const target: Type = switch (produces) {
            .byte => .byte,
            .short => .short,
            .int => .int,
            .long => .long,
            .half => .half,
            .float => .float,
            .double => .double,
            .boolean, .string, .list, .map, .array, .builder, .file => unreachable, // answered above
        };
        if (value.value_type.eql(target)) return value;
        if (!value.value_type.isNumeric()) return self.failConvert(call, value);
        return .{
            .register = try self.code.emit(.{ .convert = value.register }, target),
            .value_type = target,
        };
    }

    /// `int(m)`, `long(m)`, `byte(m)` — the member's number, at the
    /// width the constructor names (docs/ENUMS.md D4).
    ///
    /// **Every numeric constructor takes an enum, and each behaves
    /// exactly as if the backing width had been written.**  `byte(m)`
    /// traps `conversion_range` where `byte(300)` would; `double(m)`
    /// answers the member's number as a double.  One rule, no table of
    /// pairs — which is the same shape `lowerConvert` already gives the
    /// seven numeric types (docs/TYPES.md §3).
    fn lowerEnumToNumber(
        self: *FunctionBuilder,
        call: ast.Call,
        value: Typed,
        produces: types.Builtin,
    ) Error!?Typed {
        const target: Type = switch (produces) {
            .byte => .byte,
            .short => .short,
            .int => .int,
            .long => .long,
            .half => .half,
            .float => .float,
            .double => .double,
            .boolean, .string, .list, .map, .array, .builder, .file => unreachable, // answered by the caller
        };
        _ = call;
        return .{
            .register = try self.code.emit(.{ .convert = value.register }, target),
            .value_type = target,
        };
    }

    /// `string(m)` — the member's name (docs/ENUMS.md D5).
    ///
    /// **The name table is the constant pool.**  Every member's name is
    /// interned there once, like every other string a program spells,
    /// and this is the tree that picks the row: one equality per member
    /// on a value that is already the compare-and-branch shape `match`
    /// uses, answering a constant.  So there is nothing new in
    /// `libluce_rt` — the two engines agree because they run the same
    /// MIR, which is the whole of D10's promise — and no table of
    /// pointers has to be emitted into an artifact and kept honest by
    /// something other than the program itself.
    fn lowerEnumName(self: *FunctionBuilder, value: Typed) Error!?Typed {
        const declared = self.analyzer.enums.items[value.value_type.enumeration.index];
        const result = try self.code.spill(
            try self.code.emit(
                .{ .const_string = try self.analyzer.pool.intern(declared.members[0].name) },
                .string,
            ),
            .string,
        );
        if (declared.members.len == 1) {
            return .{ .register = try self.code.load(result), .value_type = .string };
        }
        const held = try self.code.spill(value.register, value.value_type);

        var frames: std.ArrayList(mir.build.Lowering.Conditional) = .empty;
        defer frames.deinit(self.temporary());
        // The first member is what the slot already holds, so the tree
        // tests the others — the same "every value is a member" promise
        // `match` leans on, spent here to save a comparison.
        for (declared.members[1..]) |member| {
            const number = try self.code.emit(.{ .const_long = member.value }, value.value_type);
            const same = try self.code.emit(.{ .binary = .{
                .op = .equal,
                .operand_type = value.value_type,
                .left = try self.code.load(held),
                .right = number,
            } }, .boolean);
            const arms = try self.code.openIf(same, true);
            try self.code.store(result, try self.code.emit(
                .{ .const_string = try self.analyzer.pool.intern(member.name) },
                .string,
            ));
            try self.code.elseArm(arms);
            try frames.append(self.temporary(), arms);
        }
        while (frames.pop()) |arms| try self.code.closeIf(arms);
        return .{ .register = try self.code.load(result), .value_type = .string };
    }

    /// One sentence for all three constructors, naming what each takes.
    /// It used to be spelled per constructor as "long() converts double,
    /// not X" — which stopped being true the moment `long(long)` was an
    /// identity and `long` accepted both numeric types.
    fn failConvert(self: *FunctionBuilder, call: ast.Call, value: Typed) Error!?Typed {
        // A family, not a list of widths.  There are four arithmetic
        // types now and there will be seven (docs/TYPES.md §11), and
        // a message that enumerates them is a message that goes stale
        // every time the ladder grows a rung.
        const takes: []const u8 = if (conversionNamed(call.callee).? == .string)
            "a number, a bool, or a string"
        else
            "a number";
        try self.fail("luce.sema.convert", call.span, "{s}() converts {s}, not {s}{s}", .{
            call.callee,
            takes,
            try self.analyzer.typeName(value.value_type),
            try self.absenceAdvice(value.value_type, call.arguments[0].value),
        });
        return null;
    }

    // Builtins ---------------------------------------------------------------

    const IntrinsicResult = union(enum) {
        not_builtin,
        failed,
        value: Typed,
    };

    /// Lower a builtin call; .not_builtin when the callee is no
    /// builtin, .failed after reporting bad arguments.
    fn lowerIntrinsic(
        self: *FunctionBuilder,
        call: ast.Call,
        as_statement: bool,
        fallible_allowed: bool,
        wanted: ?Type,
    ) Error!IntrinsicResult {
        const matched = for (builtins) |builtin| {
            if (std.mem.eql(u8, call.callee, builtin.name)) break builtin;
        } else return .not_builtin;

        // `ord` of a literal folds to its codepoint.  That is what
        // lets the language do without character-literal syntax
        // altogether: `byte_at(s, i) == ord("(")` reads better than
        // `== 40` and now costs exactly the same.  An empty literal
        // is left alone — it traps at run time, and a fold that
        // changed that would be a fold that changed the program.
        if (matched.kind == .ord_text and call.arguments.len == 1 and
            helpers.argumentMayName(call.arguments[0], "text") and
            call.arguments[0].value.* == .string_literal)
        {
            if (helpers.ordOfLiteral(call.arguments[0].value.string_literal.decoded)) |codepoint| {
                return .{ .value = .{
                    .register = try self.code.emit(.{ .const_long = codepoint }, .long),
                    .value_type = .long,
                } };
            }
        }

        if (matched.host and !self.analyzer.options.allow_host) {
            try self.fail(
                "luce.sema.host",
                call.span,
                "{s} is a host builtin; this host does not allow console, file, or terminal access here",
                .{matched.name},
            );
            return .failed;
        }
        // Which slot each argument fills: the table is the builtin's
        // signature (docs/ARGS.md §3), so names and defaults resolve
        // through the same machinery a user call's do — the resolver
        // needs nothing but the slots.
        const surface = try self.builtinSlots(matched);
        const seen = try self.temporary().alloc(bool, surface.len);
        defer self.temporary().free(seen);
        @memset(seen, false);
        const slots = (try self.resolveSlots(matched.name, "luce.sema.call", surface, 0, call.arguments, seen, call.span)) orelse
            return .failed;
        if (!(try self.checkRequiredSlots(matched.name, "luce.sema.call", surface, seen, call.span))) return .failed;
        var argument_expressions: [3]*ast.Expression = undefined;
        for (call.arguments, 0..) |argument, index| {
            // Builtins borrow (S11); a give with no owner to receive
            // it would silently become an early free (free's operand
            // is a name and gets its own diagnosis).
            if (argument.value.* == .give and matched.kind != .free_object) {
                try self.fail(
                    "luce.sema.own",
                    argument.span,
                    "{s} only borrows its arguments; give needs an owning destination [OWNERSHIP.md S11, S13]",
                    .{matched.name},
                );
                return .failed;
            }
            argument_expressions[index] = argument.value;
        }
        const expressions = argument_expressions[0..call.arguments.len];
        // **The builtins that answer their operand's own type land
        // their operands where the whole call lands** (docs/TYPES.md
        // §9).  `let x: double = sqrt(2.0)` otherwise reads `2.0` at
        // binary32, takes a binary32 square root and widens the wrong
        // number into a place that said `double` — the same
        // double-rounding `methodParameters` exists to stop one level
        // down, and it is silent in exactly the same way.  Every other
        // builtin names its own operand types and takes no landing;
        // the polymorphic landing is one type for every slot, so a
        // reordered name cannot land a literal differently.
        const written = written: {
            const landing = if (matched.polymorphic) landingType(wanted orelse .none) else null;
            if (landing) |place| {
                const places = try self.arena().alloc(Type, expressions.len);
                @memset(places, place);
                break :written (try self.lowerOperandsInto(expressions, .{ .places = places })) orelse
                    return .failed;
            }
            break :written (try self.lowerOperands(expressions)) orelse return .failed;
        };
        // Written values land on the slots they resolved to, and a
        // slot nobody filled takes its default from the table — the
        // constant register the written literal would have been
        // (docs/ARGS.md D2, D10).
        const arguments = try self.arena().alloc(Typed, surface.len);
        for (written, slots) |value, slot| arguments[slot] = value;
        for (matched.parameters, seen, 0..) |parameter, given, slot| {
            if (given) continue;
            const filled = parameter.default.?;
            arguments[slot] = .{
                .register = try self.emitConstantValue(filled.value, filled.value_type),
                .value_type = filled.value_type,
            };
        }

        // Argument and result typing per builtin.
        var result: Type = .none;
        var extra_argument: ?Register = null;
        switch (matched.kind) {
            .abs => {
                if (!arguments[0].value_type.isNumeric()) return self.failIntrinsic(call, "abs takes a number");
                arguments[0] = try self.promoted(arguments[0]);
                result = arguments[0].value_type;
            },
            // `min`, `max` and `clamp` unify their arguments the way a
            // binary operator unifies its operands: one double among
            // them makes them all Floats (docs/NUMERICS.md).  Anything
            // else would make `clamp(x, 0, 10)` a type error for a
            // double `x` in a language where `x < 0` is not.
            .min, .max => {
                _ = try self.unifyNumeric(&arguments[0], &arguments[1]);
                if (!arguments[0].value_type.isNumeric() or
                    !arguments[0].value_type.eql(arguments[1].value_type))
                    return self.failIntrinsic(call, "min/max take two numbers of the same type");
                result = arguments[0].value_type;
            },
            .clamp => {
                _ = try self.unifyNumeric(&arguments[0], &arguments[1]);
                _ = try self.unifyNumeric(&arguments[0], &arguments[2]);
                _ = try self.unifyNumeric(&arguments[1], &arguments[2]);
                if (!arguments[0].value_type.isNumeric() or
                    !arguments[0].value_type.eql(arguments[1].value_type) or
                    !arguments[0].value_type.eql(arguments[2].value_type))
                    return self.failIntrinsic(call, "clamp takes three numbers of the same type");
                result = arguments[0].value_type;
            },
            .sqrt, .floor, .ceil, .trunc => {
                // Whichever float width it was given, and the same one
                // back (docs/TYPES.md §9).  `sqrt` of a `float`
                // answering a `double` would be a narrowing waiting to
                // happen at the next store, and `llvm.sqrt.f32` exists
                // — so there is nothing to buy by widening and a
                // diagnostic to pay for it with.
                if (!arguments[0].value_type.isFloating())
                    return self.failIntrinsic(call, "this builtin takes a float or a double");
                // A `half` arrives promoted to a `float`, so there is
                // no binary16 square root to ask any target for (D5).
                arguments[0] = try self.promoted(arguments[0]);
                result = arguments[0].value_type;
            },
            .len => {
                const measurable = arguments[0].value_type == .string or
                    arguments[0].value_type == .heap;
                if (!measurable) {
                    if (arguments[0].value_type == .optional) {
                        try self.failAbsence(call.span, "len", arguments[0].value_type, call.arguments[0].value);
                        return .failed;
                    }
                    return self.failIntrinsic(call, "len takes a string, list, map, array, or builder");
                }
                result = .long;
            },
            .free_object => {
                if (arguments[0].value_type != .heap) {
                    if (arguments[0].value_type == .optional) {
                        try self.failAbsence(call.span, "free", arguments[0].value_type, call.arguments[0].value);
                        return .failed;
                    }
                    return self.failIntrinsic(call, "free releases a list, map, array, or builder");
                }
                // free is deliberate early release of an owned name,
                // and poisons the name like give does (S6).
                const operand = call.arguments[0].value;
                if (operand.* != .name) {
                    try self.fail(
                        "luce.sema.own",
                        call.span,
                        "free releases an owned name; containers free their own elements [OWNERSHIP.md S6, S22]",
                        .{},
                    );
                    return .failed;
                }
                const found = self.findLocal(operand.name.text) orelse return .failed;
                switch (found.info.class) {
                    .borrow_param => {
                        try self.fail(
                            "luce.sema.own",
                            call.span,
                            "{s} is a borrowed parameter and cannot be freed; only owners free [OWNERSHIP.md S12]",
                            .{operand.name.text},
                        );
                        return .failed;
                    },
                    .alias => {
                        try self.fail(
                            "luce.sema.own",
                            call.span,
                            "{s} aliases an object it does not own; free the owning name [OWNERSHIP.md S6, S8]",
                            .{operand.name.text},
                        );
                        return .failed;
                    },
                    .owned => {},
                }
                if (self.loops.items.len > 0 and
                    found.depth < self.loops.items[self.loops.items.len - 1].scope_depth)
                {
                    try self.fail(
                        "luce.sema.own",
                        call.span,
                        "{s} is declared outside this loop; the next iteration would use a freed name [OWNERSHIP.md S30]",
                        .{operand.name.text},
                    );
                    return .failed;
                }
                found.info.poisoned = .freed;
                // Free names its binding so the runtime can verify
                // this name still owns the object (S6, S23).
                extra_argument = try self.code.emit(.{ .const_long = found.info.local }, .long);
                result = .none;
            },
            .parse_int, .parse_float => {
                if (arguments[0].value_type != .string)
                    return self.failIntrinsic(call, "this builtin parses a string");
                // "Not a number" is the same reason every time and the
                // name already implies it, so the answer is absence
                // rather than a trap (docs/FAILURE.md).
                result = if (matched.kind == .parse_int)
                    .{ .optional = .long }
                else
                    .{ .optional = .double };
            },
            // The parse family's third member (docs/BYTES.md R3): the
            // bytes back as text, or absent when they are not text.
            .parse_string => {
                const buffer = try self.analyzer.internHeapType(.{ .list = .byte });
                if (!arguments[0].value_type.eql(buffer))
                    return self.failIntrinsic(call, "parse_string takes a list(byte)");
                result = .{ .optional = .string };
            },
            .chr_code => {
                if (!try self.widensInto(&arguments[0], .long))
                    return self.failIntrinsic(call, "chr takes a long codepoint");
                result = .string;
            },
            .ord_text => {
                if (arguments[0].value_type != .string)
                    return self.failIntrinsic(call, "ord takes a string");
                result = .long;
            },
            // Lowered from syntax or method calls, never from bare names.
            .own_storage,
            .drop_storage,
            .export_storage,
            .give_object,
            .copy_object,
            .null_object,
            // Emitted by a mixed comparison; there is no name for it.
            .compare_long_double,
            // Emitted by `string(x)` and by `builder.build()`, both of
            // which are resolved before this table is consulted.
            .str_value,
            .none_value,
            .is_none,
            .optional_wrap,
            .optional_unwrap,
            .index_get,
            .index_set,
            .list_slice,
            .key_at,
            .value_at,
            .string_slice,
            .string_byte,
            .string_find_byte,
            .append_value,
            .append_ascii,
            .pop_value,
            .insert_value,
            .remove_entry,
            .has_key,
            .dim_size,
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
            => unreachable,

            .assert_true => {
                if (arguments[0].value_type != .boolean)
                    return self.failIntrinsic(call, "assert takes a bool");
                result = .none;
            },
            .trap_message => {
                if (arguments[0].value_type != .string)
                    return self.failIntrinsic(call, "trap takes a string message");
                result = .none;
            },
            .raise_error => {
                if (arguments[0].value_type != .string)
                    return self.failIntrinsic(call, "error takes a string message");
                result = .none;
            },
            // Emitted by `try` and `catch`; never written by a reader.
            .errored, .error_message, .forget => unreachable,
            .print, .term_write => {
                if (arguments[0].value_type != .string)
                    return self.failIntrinsic(call, "this builtin takes a string");
                result = .none;
            },
            .file_read => {
                if (arguments[0].value_type != .string)
                    return self.failIntrinsic(call, "file_read takes a string path");
                result = .string;
            },
            .file_write => {
                if (arguments[0].value_type != .string or arguments[1].value_type != .string)
                    return self.failIntrinsic(call, "file_write takes (path string, content string)");
                // The world decided, so a failed write is news and not
                // a bool nobody looked at (docs/FAILURE.md).  It
                // answers nothing and every call site says which of
                // `try` and `catch` it means.
                result = .none;
            },
            .file_exists => {
                if (arguments[0].value_type != .string)
                    return self.failIntrinsic(call, "file_exists takes a string path");
                result = .boolean;
            },
            .term_rows, .term_cols => {
                result = .long;
            },
            .term_clear, .term_flush => {
                result = .none;
            },
            .term_move => {
                if (!try self.widensInto(&arguments[0], .long) or
                    !try self.widensInto(&arguments[1], .long))
                    return self.failIntrinsic(call, "term_move takes (row long, column long)");
                result = .none;
            },
            .term_style => {
                if (!try self.widensInto(&arguments[0], .long) or
                    !try self.widensInto(&arguments[1], .long) or
                    arguments[2].value_type != .boolean)
                    return self.failIntrinsic(call, "term_style takes (foreground long, background long, bold bool)");
                result = .none;
            },
            .key_read => {
                // A keyboard runs dry — a pipe ends, a terminal
                // closes — and there is nothing there and no reason
                // worth carrying, which is `string?` and not a name
                // in the closed set (docs/FAILURE.md).  The same fact
                // `read_line` already answers `none` for, off the same
                // descriptor.
                result = .{ .optional = .string };
            },
            .key_text => {
                result = .string;
            },
            .read_line => {
                if (arguments[0].value_type != .string)
                    return self.failIntrinsic(call, "read_line takes a string prompt");
                // End of input is absence, not failure: `string?`, and
                // `read_line("> ") else ""` is the whole handling
                // (docs/FAILURE.md).
                result = .{ .optional = .string };
            },
            .print_error => {
                if (arguments[0].value_type != .string)
                    return self.failIntrinsic(call, "print_error takes a string");
                result = .none;
            },
            .clock_ms => {
                result = .long;
            },
            // Bytes, bytes and a count.  `long` and not `int` for the
            // same reason `clock_ms` is: a machine with more than two
            // gigabytes of memory overflows the narrow ladder, and a
            // fact nobody can hold is not a fact (docs/TYPES.md).
            .os_total_memory, .os_available_memory, .os_cpu_count => {
                result = .long;
            },
            .sleep_ms => {
                if (!try self.widensInto(&arguments[0], .long))
                    return self.failIntrinsic(call, "sleep_ms takes a long of milliseconds");
                result = .none;
            },
            .exit_program => {
                if (!try self.widensInto(&arguments[0], .long))
                    return self.failIntrinsic(call, "exit takes a long status");
                result = .none;
            },
            .env_get => {
                if (arguments[0].value_type != .string)
                    return self.failIntrinsic(call, "env takes a string name");
                result = .{ .optional = .string };
            },
            .file_append => {
                if (arguments[0].value_type != .string or arguments[1].value_type != .string)
                    return self.failIntrinsic(call, "file_append takes (path string, content string)");
                result = .none;
            },
            .file_delete => {
                if (arguments[0].value_type != .string)
                    return self.failIntrinsic(call, "file_delete takes a string path");
                result = .none;
            },
            .file_rename => {
                if (arguments[0].value_type != .string or arguments[1].value_type != .string)
                    return self.failIntrinsic(call, "file_rename takes (from string, to string)");
                result = .none;
            },
            .dir_list => {
                if (arguments[0].value_type != .string)
                    return self.failIntrinsic(call, "dir_list takes a string path");
                result = try self.analyzer.internHeapType(.{ .list = .string });
            },
            // The byte channel's door (docs/BYTES.md R5).  The mode is
            // a number here and a named door in `std.files`, which is
            // where a reader meets it: a builtin speaks what the host
            // slot speaks, and the library is where it gets a name.
            .file_open => {
                if (arguments[0].value_type != .string)
                    return self.failIntrinsic(call, "file_open takes (path string, mode long)");
                if (!try self.widensInto(&arguments[1], .long))
                    return self.failIntrinsic(call, "file_open takes (path string, mode long)");
                result = try self.analyzer.internHeapType(.file);
            },
            // Reached through `f.read(buffer)` and its two siblings,
            // which `objectMethod` types against the receiver: a
            // handle method is not a free builtin and has no row in
            // the table above.
            .handle_read, .handle_write, .handle_flush => unreachable,
        }
        // `error("…")` leaves the function, so it can stand where a
        // value belongs the way `trap("…")` can — but only inside a
        // function that said it can fail.
        if (matched.kind == .raise_error and !self.code.fallible) {
            try self.fail(
                "luce.sema.fallible",
                call.span,
                "error raises, and {s} does not say it can fail; write '-> !' (or '-> T!') on its signature",
                .{self.code.name},
            );
            return .failed;
        }
        const leaves = matched.kind == .raise_error;
        if (result == .none and !as_statement and !leaves) {
            try self.fail("luce.sema.call", call.span, "{s} returns nothing", .{matched.name});
            return .failed;
        }

        const register_count = arguments.len + @intFromBool(extra_argument != null);
        const registers = try self.arena().alloc(Register, register_count);
        for (arguments, registers[0..arguments.len]) |value, *register| register.* = value.register;
        if (extra_argument) |extra| registers[register_count - 1] = extra;
        const emitted = try self.code.emit(
            .{ .intrinsic = .{ .kind = matched.kind, .arguments = registers } },
            result,
        );

        // Two host services can be told no by the world, and one
        // builtin says no itself.  All three end this frame or hand
        // their caller a branch, exactly as a fallible call does.
        if (leaves) {
            // The words were copied into run-lifetime storage by the
            // instruction above, so the releases below cannot take
            // them back out from under the error (docs/FAILURE.md).
            try self.emitTempReleases(0);
            try self.emitScopeReleases(0, &.{});
            try self.code.unwind();
            return .{ .value = .{ .register = emitted, .value_type = .none } };
        }
        if (matched.kind.isFallible()) {
            if (!fallible_allowed) {
                try self.fail(
                    "luce.sema.fallible",
                    call.span,
                    "{s} can fail: write 'try {s}(…)' to pass the error on, or '{s}(…) catch …' to handle it",
                    .{ matched.name, matched.name, matched.name },
                );
                return .failed;
            }
            return .{ .value = try self.openFallible(emitted, result) };
        }
        return .{ .value = .{ .register = emitted, .value_type = result } };
    }

    fn failIntrinsic(self: *FunctionBuilder, call: ast.Call, message: []const u8) Error!IntrinsicResult {
        try self.fail("luce.sema.type", call.span, "{s}", .{message});
        return .failed;
    }
};
