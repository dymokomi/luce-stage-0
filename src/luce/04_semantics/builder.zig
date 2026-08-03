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

const std = @import("std");
const source_mod = @import("../01_source.zig");
const ast = @import("../03_parse.zig").ast;
const types = @import("../support/types.zig");
const mir = @import("../06_mir.zig");
const helpers = @import("helpers.zig");

const declarations = @import("declarations.zig");
const Analyzed = declarations.Analyzed;
const ModuleTree = declarations.ModuleTree;
const FunctionInfo = declarations.FunctionInfo;
const ConstantValue = declarations.ConstantValue;
const Analyzer = declarations.Analyzer;
const OwnershipClass = declarations.OwnershipClass;
const Poison = declarations.Poison;
const LocalInfo = declarations.LocalInfo;
const Scope = declarations.Scope;
const FoundLocal = declarations.FoundLocal;
const LoopFrame = declarations.LoopFrame;
const isReserved = declarations.isReserved;
const Error = declarations.Error;

const Allocator = std.mem.Allocator;
const Span = source_mod.Span;
const Type = types.Type;
const PortSchema = types.PortSchema;
const StructLayout = types.StructLayout;
const Register = mir.Register;
const BlockId = mir.BlockId;
const LocalId = mir.LocalId;

// ---------------------------------------------------------------------------
// FunctionBuilder
// ---------------------------------------------------------------------------

const Value = struct {
    register: Register,
    value_type: Type,
};

pub const FunctionBuilder = struct {
    analyzer: *Analyzer,
    module: usize,
    prefix: []const u8,
    has_frames: bool,
    /// Stage 6's tape.  Every decision this walk reaches is recorded
    /// on it in the order it is reached; the only things ever read
    /// back are a register's type and a local's type.
    code: mir.build.Lowering,
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

    const TempSlot = struct { local: LocalId, register: Register };

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

    fn offerDeclarations(self: *FunctionBuilder, suggestion: *helpers.Suggestion) void {
        const tables = [_]*const std.StringHashMapUnmanaged(u32){
            &self.analyzer.function_names,
            &self.analyzer.struct_names,
            &self.analyzer.constant_names,
        };
        for (tables) |table| {
            var keys = table.keyIterator();
            while (keys.next()) |key| {
                if (self.visibleName(key.*)) |name| suggestion.offer(name);
            }
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
        var suggestion = helpers.Suggestion.init(name);
        self.offerLocals(&suggestion);
        self.offerDeclarations(&suggestion);
        if (suggestion.best()) |closest| {
            try self.fail("luce.sema.name", span, "unknown name {s}; did you mean {s}?", .{ name, closest });
            return;
        }
        try self.fail("luce.sema.name", span, "unknown name {s}", .{name});
    }

    /// Remember that `name`'s declaration was abandoned, so its later
    /// uses stay quiet.
    fn forgetName(self: *FunctionBuilder, name: []const u8) Error!void {
        try self.undeclared.put(self.temporary(), name, {});
    }

    /// Report a call whose callee names no declaration, offering the
    /// closest function or struct the reader could have meant.
    fn failUnknownFunction(self: *FunctionBuilder, written: []const u8, span: Span) Error!void {
        var suggestion = helpers.Suggestion.init(written);
        var functions = self.analyzer.function_names.keyIterator();
        while (functions.next()) |key| {
            if (self.visibleName(key.*)) |name| suggestion.offer(name);
        }
        var structs = self.analyzer.struct_names.keyIterator();
        while (structs.next()) |key| {
            if (self.visibleName(key.*)) |name| suggestion.offer(name);
        }
        if (suggestion.best()) |closest| {
            try self.fail("luce.sema.call", span, "unknown function {s}; did you mean {s}?", .{ written, closest });
            return;
        }
        try self.fail("luce.sema.call", span, "unknown function {s}", .{written});
    }

    /// Report a field a struct does not have, offering the closest one
    /// it does.  A struct's fields are right there in the layout, so
    /// there is never an excuse for this message not to help.
    fn failUnknownField(
        self: *FunctionBuilder,
        code: []const u8,
        layout: StructLayout,
        field: []const u8,
        span: Span,
    ) Error!void {
        var suggestion = helpers.Suggestion.init(field);
        for (layout.fields) |candidate| suggestion.offer(candidate.name);
        if (suggestion.best()) |closest| {
            try self.fail(code, span, "{s} has no field {s}; did you mean {s}?", .{ layout.name, field, closest });
            return;
        }
        try self.fail(code, span, "{s} has no field {s}", .{ layout.name, field });
    }

    // Ownership releases -------------------------------------------------

    /// Emit releases for the owned locals of every scope at or above
    /// `from`, innermost first, skipping `moved` (a returned binding —
    /// its object moves to the caller, S16).
    fn emitScopeReleases(self: *FunctionBuilder, from: usize, moved: ?LocalId) Error!void {
        var scope_index = self.scopes.items.len;
        while (scope_index > from) {
            scope_index -= 1;
            const owned = self.scopes.items[scope_index].owned.items;
            var owned_index = owned.len;
            while (owned_index > 0) {
                owned_index -= 1;
                if (moved != null and owned[owned_index] == moved.?) continue;
                try self.code.release(owned[owned_index]);
            }
        }
    }

    /// Emit releases for the innermost scope, in reverse declaration
    /// order, without popping it: the normal end of a block.
    pub fn emitScopeEnd(self: *FunctionBuilder) Error!void {
        try self.emitScopeReleases(self.scopes.items.len - 1, null);
    }

    /// Park a fresh, unowned object in a hidden local so the end of
    /// the statement can release it if nothing adopted it (S3, S19).
    fn registerTemp(self: *FunctionBuilder, value: Value) Error!void {
        const local = try self.code.park(value.register, value.value_type);
        try self.temps.append(self.temporary(), .{ .local = local, .register = value.register });
    }

    /// Emit releases for the temporaries above `from` without
    /// forgetting them (unwinding paths: return, break, continue).
    fn emitTempReleases(self: *FunctionBuilder, from: usize) Error!void {
        var index = self.temps.items.len;
        while (index > from) {
            index -= 1;
            try self.code.release(self.temps.items[index].local);
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
    fn resolveDeclared(self: *FunctionBuilder, written: []const u8, span: Span) Error!?[]const u8 {
        if (std.mem.indexOfScalar(u8, written, '.')) |dot| {
            const head = written[0..dot];
            const local_head = try self.analyzer.qualify(self.prefix, head);
            if (self.analyzer.struct_names.contains(local_head)) {
                return try self.analyzer.qualify(self.prefix, written);
            }
            if (self.analyzer.importsModule(self.module, head)) {
                return written;
            }
            try self.fail("luce.sema.import", span, "unknown namespace {s}; import {s} to use it", .{ head, try self.analyzer.importSpelling(head) });
            return null;
        }
        return try self.analyzer.qualify(self.prefix, written);
    }

    pub fn declareLocal(
        self: *FunctionBuilder,
        name: []const u8,
        local_type: Type,
        mutable: bool,
        class: OwnershipClass,
        span: Span,
    ) Error!?LocalId {
        if (isReserved(name) or std.mem.eql(u8, name, "evaluate")) {
            try self.fail("luce.sema.reserved", span, "{s} is a reserved name", .{name});
            return null;
        }
        if (self.findLocal(name) != null) {
            try self.fail("luce.sema.duplicate", span, "{s} is already declared", .{name});
            return null;
        }
        const qualified = try self.analyzer.qualify(self.prefix, name);
        if (self.analyzer.function_names.contains(qualified) or
            self.analyzer.struct_names.contains(qualified) or
            self.analyzer.constant_names.contains(qualified))
        {
            try self.fail("luce.sema.duplicate", span, "{s} is already a declaration", .{name});
            return null;
        }
        const carries = self.analyzer.carriesObjects(local_type);
        const local = try self.code.addLocal(name, local_type);
        const scope = &self.scopes.items[self.scopes.items.len - 1];
        try scope.names.put(self.temporary(), name, .{
            .local = local,
            .mutable = mutable,
            .class = if (carries) class else .alias,
            .carries = carries,
        });
        if (carries and class == .owned) {
            try scope.owned.append(self.temporary(), local);
        }
        return local;
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
    fn splitsBlocks(expression: *const ast.Expression, budget: u32) bool {
        if (budget == 0) return true;
        const left = budget - 1;
        return switch (expression.*) {
            .binary => |binary| binary.op == .logic_and or binary.op == .logic_or or
                splitsBlocks(binary.left, left) or splitsBlocks(binary.right, left),
            .unary => |unary| splitsBlocks(unary.operand, left),
            .field => |field| splitsBlocks(field.target, left),
            .call => |call| anySplits(call.arguments, left),
            .new_object => |new| for (new.dims) |dimension| {
                if (splitsBlocks(dimension, left)) break true;
            } else false,
            .list_literal => |literal| for (literal.elements) |element| {
                if (splitsBlocks(element, left)) break true;
            } else false,
            .index => |index| splitsBlocks(index.target, left) or for (index.indices) |item| {
                if (splitsBlocks(item, left)) break true;
            } else false,
            .slice_range => |slice| splitsBlocks(slice.target, left) or
                (slice.start != null and splitsBlocks(slice.start.?, left)) or
                (slice.end != null and splitsBlocks(slice.end.?, left)),
            .method => |method| splitsBlocks(method.target, left) or
                anySplits(method.arguments, left),
            .give => |give| splitsBlocks(give.operand, left),
            .copy => |copied| splitsBlocks(copied.operand, left),
            else => false,
        };
    }

    fn anySplits(arguments: []const ast.Argument, budget: u32) bool {
        for (arguments) |argument| {
            if (splitsBlocks(argument.value, budget)) return true;
        }
        return false;
    }

    // Ownership classification ---------------------------------------------

    /// Builtin value methods whose result is a fresh object the caller
    /// owns (S22).  These three are intrinsics with no signature to
    /// consult, so the list is the signature; the method tables in
    /// `objectMethod` and `sequenceMethod` must agree with it.  A
    /// method that routes into the standard library is *not* here —
    /// `routedMethodYieldsObject` asks its declaration instead, so
    /// adding an object-returning `strings` function cannot quietly
    /// leak what it returns.
    const fresh_object_methods = [_][]const u8{ "pop", "keys", "values" };

    /// True when evaluating this expression yields an object the
    /// receiver may own: something fresh (new, a literal, a slice, a
    /// call result, pop/split/keys), a give, or a copy.  Names and
    /// element/field reads are borrows (S8, S22).  Only consulted for
    /// object-carrying types, so value-typed calls answering true is
    /// harmless.
    fn yieldsOwnership(self: *FunctionBuilder, expression: *const ast.Expression) Error!bool {
        return switch (expression.*) {
            .new_object, .list_literal, .slice_range, .call, .give, .copy => true,
            .method => |method| blk: {
                if (try self.methodIsNamespaced(method)) break :blk true;
                for (fresh_object_methods) |name| {
                    if (std.mem.eql(u8, method.name, name)) break :blk true;
                }
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

    fn lowerOperands(self: *FunctionBuilder, expressions: []const *ast.Expression) Error!?[]Value {
        var spill_storage: [inline_operands]?LocalId = undefined;
        var split_storage: [inline_operands]bool = undefined;
        const wide = expressions.len > inline_operands;

        const values = try self.arena().alloc(Value, expressions.len);
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
            if (splitsBlocks(expressions[backwards], split_search_depth)) any_split = true;
        }

        for (expressions, 0..) |expression, index| {
            const value = (try self.lowerExpression(expression, false)) orelse return null;
            values[index] = value;
            spills[index] = null;
            if (later_splits[index] and value.value_type != .none) {
                spills[index] = try self.code.spill(value.register, value.value_type);
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

    fn lowerStatement(self: *FunctionBuilder, statement: ast.Statement) Error!void {
        // Statement granularity is the trap-location contract: every
        // instruction a statement lowers to reports the statement's
        // own line, the way Python tracebacks do.
        self.code.origin = @intCast(statement.span().start);
        switch (statement) {
            .let => |binding| try self.lowerBinding(binding.name, binding.annotation, binding.value, false, binding.span),
            .variable => |binding| {
                if (binding.value) |value| {
                    try self.lowerBinding(binding.name, binding.annotation, value, true, binding.span);
                } else {
                    try self.lowerLateDeclaration(binding.name, binding.annotation.?, binding.span);
                }
            },
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
                try self.emitScopeReleases(frame.scope_depth, null);
                try self.code.jump(frame.exit_block);
            },
            .continue_statement => |continued| {
                if (self.loops.items.len == 0) {
                    try self.fail("luce.sema.loop", continued.span, "continue outside a loop", .{});
                    return;
                }
                const frame = self.loops.items[self.loops.items.len - 1];
                try self.emitTempReleases(frame.temps_depth);
                try self.emitScopeReleases(frame.scope_depth, null);
                try self.code.jump(frame.continue_block);
            },
            .expression => |expression| {
                _ = try self.lowerExpression(expression.value, true);
            },
        }
    }

    fn lowerBinding(
        self: *FunctionBuilder,
        name: []const u8,
        annotation: ?ast.TypeName,
        value_expression: *ast.Expression,
        mutable: bool,
        span: Span,
    ) Error!void {
        // An empty [] has no element type of its own; the annotation
        // supplies it: var xs: List(Int) = []
        if (value_expression.* == .list_literal and value_expression.list_literal.elements.len == 0) {
            const written = annotation orelse {
                try self.fail(
                    "luce.sema.type",
                    span,
                    "an empty [] needs an annotation: var {s}: List(T) = []",
                    .{name},
                );
                return self.forgetName(name);
            };
            const expected = (try self.analyzer.resolveType(self.module, written)) orelse
                return self.forgetName(name);
            const descriptor = self.analyzer.heapOf(expected);
            if (descriptor == null or descriptor.? != .list) {
                try self.fail("luce.sema.type", span, "[] builds a List, but {s} is annotated {s}", .{
                    name,
                    try self.analyzer.typeName(expected),
                });
                return self.forgetName(name);
            }
            const list = try self.code.emit(.{ .heap_new = .{ .heap = expected.heap, .dims = &.{} } }, expected);
            const local = (try self.declareLocal(name, expected, mutable, .owned, span)) orelse return;
            try self.code.store(local, list);
            try self.code.bind(local, list);
            return;
        }

        // A binding whose initializer failed still declares a name the
        // reader meant; remembering it keeps one mistake from
        // producing an "unknown name" per later use.
        const value = (try self.lowerExpression(value_expression, false)) orelse
            return self.forgetName(name);
        if (annotation) |written| {
            const expected = (try self.analyzer.resolveType(self.module, written)) orelse
                return self.forgetName(name);
            if (!value.value_type.eql(expected)) {
                try self.fail(
                    "luce.sema.type",
                    span,
                    "{s} declared {s} but initialized with {s} (conversions are explicit: {s}(...))",
                    .{ name, try self.analyzer.typeName(expected), try self.analyzer.typeName(value.value_type), try self.analyzer.typeName(expected) },
                );
                return self.forgetName(name);
            }
        }
        // A binding that received something fresh (or a give, or a
        // copy) owns the object; receiving another name is an alias
        // (S1, S8).
        const owns = self.analyzer.carriesObjects(value.value_type) and
            try self.yieldsOwnership(value_expression);
        const local = (try self.declareLocal(
            name,
            value.value_type,
            mutable,
            if (owns) .owned else .alias,
            span,
        )) orelse return;
        try self.code.store(local, value.register);
        if (owns) {
            try self.code.bind(local, value.register);
        }
    }

    /// var name: Type — a late declaration (OWNERSHIP.md S40): the
    /// slot starts at the type's zero value; the zero of an object
    /// type is the null object, which traps on use until assigned.
    fn lowerLateDeclaration(
        self: *FunctionBuilder,
        name: []const u8,
        written: ast.TypeName,
        span: Span,
    ) Error!void {
        const declared = (try self.analyzer.resolveType(self.module, written)) orelse
            return self.forgetName(name);
        const zero = try self.code.zeroOf(declared);
        // The declaration establishes the binding and its scope; the
        // scope owns whatever a later assignment fills in (S36, S40).
        const local = (try self.declareLocal(name, declared, true, .owned, span)) orelse return;
        try self.code.store(local, zero);
    }

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
                        try self.failUnknownField("luce.sema.field", layout, field.name, field.span);
                        return;
                    };
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
                    const object_value: Value = .{ .register = current, .value_type = current_type };
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
        if (!value.value_type.eql(current_type)) {
            try self.fail("luce.sema.type", assign.span, "this place holds {s} but the value is {s}", .{
                try self.analyzer.typeName(current_type),
                try self.analyzer.typeName(value.value_type),
            });
            return;
        }
        var new_value = value.register;
        if (assign.compound) |op| {
            new_value = (try self.compoundCombine(op, current, current_type, value, assign.span)) orelse return;
        }

        try self.code.rebuild(root_local, accessors, new_value);
    }

    /// Combine the current value of a compound-assignment place with
    /// the right-hand side under OP — `place OP= value` reads the
    /// place once (the caller supplies `current`) and stores this.
    /// Type rules are a binary expression's exactly: numeric
    /// arithmetic, plus String concat for `+=`.  Returns the register
    /// holding the combined value, or null after reporting.
    fn compoundCombine(
        self: *FunctionBuilder,
        op: ast.BinaryOp,
        current: Register,
        place_type: Type,
        value: Value,
        span: Span,
    ) Error!?Register {
        if (!value.value_type.eql(place_type)) {
            try self.fail("luce.sema.type", span, "compound assignment needs matching types: place is {s}, value is {s}", .{
                try self.analyzer.typeName(place_type),
                try self.analyzer.typeName(value.value_type),
            });
            return null;
        }
        const string_concat = op == .add and place_type == .string;
        if (!place_type.isNumeric() and !string_concat) {
            try self.fail("luce.sema.type", span, "{s} has no compound assignment (numbers, or += on String)", .{
                try self.analyzer.typeName(place_type),
            });
            return null;
        }
        const operation: mir.BinaryOp = switch (op) {
            .add => .add,
            .subtract => .subtract,
            .multiply => .multiply,
            .divide => .divide,
            .remainder => .remainder,
            else => unreachable, // the parser only builds these five
        };
        return try self.code.emit(.{ .binary = .{
            .op = operation,
            .operand_type = place_type,
            .left = current,
            .right = value.register,
        } }, place_type);
    }

    fn lowerAssignName(self: *FunctionBuilder, base: []const u8, span: Span, assign: ast.Assign) Error!void {
        if (std.mem.eql(u8, base, "output")) {
            try self.fail("luce.sema.output", span, "assign to output.NAME", .{});
            return;
        }
        if (std.mem.eql(u8, base, "input")) {
            try self.fail("luce.sema.input", span, "input ports are read-only", .{});
            return;
        }
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
            try self.fail("luce.sema.type", assign.span, "{s} has no compound assignment (numbers, or += on String)", .{
                try self.analyzer.typeName(local_type),
            });
            return;
        }
        if (info.carries) {
            const yields = try self.yieldsOwnership(assign.value);
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
        const value = (try self.lowerExpression(assign.value, false)) orelse return;
        if (!value.value_type.eql(local_type)) {
            try self.fail("luce.sema.type", assign.span, "{s} is {s} but the value is {s}", .{
                base,
                try self.analyzer.typeName(local_type),
                try self.analyzer.typeName(value.value_type),
            });
            return;
        }
        var store = value.register;
        if (assign.compound) |op| {
            const current = try self.code.load(local);
            store = (try self.compoundCombine(op, current, local_type, value, assign.span)) orelse return;
        }
        // Reassigning an owning var frees the old object immediately
        // (S5); the very first assignment finds only the null object.
        // Compound assignment is value-only, so `carries` is false.
        if (info.carries and class == .owned) {
            try self.code.release(local);
        }
        try self.code.store(local, store);
        if (info.carries and class == .owned) {
            try self.code.bind(local, store);
        }
    }

    fn lowerAssignField(self: *FunctionBuilder, target: ast.FieldTarget, assign: ast.Assign) Error!void {
        if (std.mem.eql(u8, target.base, "output")) {
            if (!self.has_frames) {
                try self.fail("luce.sema.name", target.span, "output exists only in the evaluator entry", .{});
                return;
            }
            const port = self.analyzer.schema.findOutput(target.field) orelse {
                try self.fail("luce.sema.port", target.span, "no output port named {s}", .{target.field});
                return;
            };
            if (assign.compound != null) {
                try self.fail("luce.sema.output", target.span, "output ports are write-only; compound assignment must read the place", .{});
                return;
            }
            const expected = Type.fromPort(self.analyzer.schema.outputs[port].declared);
            const value = (try self.lowerExpression(assign.value, false)) orelse return;
            if (!value.value_type.eql(expected)) {
                try self.fail("luce.sema.type", assign.span, "output.{s} is {s} but the value is {s}", .{
                    target.field,
                    try self.analyzer.typeName(expected),
                    try self.analyzer.typeName(value.value_type),
                });
                return;
            }
            _ = try self.code.emit(.{ .output_store = .{ .port = port, .value = value.register } }, .none);
            return;
        }
        if (std.mem.eql(u8, target.base, "input")) {
            if (self.has_frames) {
                try self.fail("luce.sema.input", target.span, "input ports are read-only", .{});
            } else {
                try self.fail("luce.sema.name", target.span, "input exists only in the evaluator entry", .{});
            }
            return;
        }

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
            try self.failUnknownField("luce.sema.field", layout, target.field, target.span);
            return;
        };
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
            if (!(try self.yieldsOwnership(assign.value))) {
                try self.failNeedsOwnership(
                    assign.span,
                    "this field keeps its object",
                    assign.value,
                    "S21, S25",
                );
                return;
            }
        }
        const value = (try self.lowerExpression(assign.value, false)) orelse return;
        if (!value.value_type.eql(expected)) {
            try self.fail("luce.sema.type", assign.span, "{s}.{s} is {s} but the value is {s}", .{
                target.base,
                target.field,
                try self.analyzer.typeName(expected),
                try self.analyzer.typeName(value.value_type),
            });
            return;
        }
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
        const updated = try self.code.emit(.{ .struct_set = .{
            .target = current,
            .layout = layout_index,
            .field = field_index,
            .value = store,
        } }, local_type);
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
        const values = (try self.lowerOperands(expressions)) orelse return;

        const object = values[0];
        const indices = values[1 .. values.len - 1];
        const value = values[values.len - 1];
        const element_type = (try self.checkIndex(object, indices, target.span)) orelse return;
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
            const read_arguments = try self.arena().alloc(Register, indices.len + 1);
            read_arguments[0] = object.register;
            for (indices, read_arguments[1..]) |index_value, *slot| slot.* = index_value.register;
            const current = try self.code.emit(
                .{ .intrinsic = .{ .kind = .index_get, .arguments = read_arguments } },
                element_type,
            );
            store = (try self.compoundCombine(op, current, element_type, value, assign.span)) orelse return;
        }
        const arguments = try self.arena().alloc(Register, values.len);
        for (values, arguments) |lowered, *slot| slot.* = lowered.register;
        arguments[arguments.len - 1] = store;
        _ = try self.code.emit(.{ .intrinsic = .{ .kind = .index_set, .arguments = arguments } }, .none);
    }

    /// Type-check lowered index values against a heap object: lists
    /// take one Int, arrays take rank Ints, maps take one key.
    /// Returns the element/value type.
    fn checkIndex(
        self: *FunctionBuilder,
        object: Value,
        indices: []const Value,
        span: Span,
    ) Error!?Type {
        const descriptor = self.analyzer.heapOf(object.value_type) orelse {
            if (object.value_type == .string) {
                try self.fail("luce.sema.index", span, "strings are sliced (s[a:b] or slice), not indexed; byte_at reads bytes", .{});
            } else {
                try self.fail("luce.sema.index", span, "{s} cannot be indexed", .{
                    try self.analyzer.typeName(object.value_type),
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
                if (indices.len != 1 or indices[0].value_type != .int) {
                    try self.fail("luce.sema.index", span, "lists index with one Int", .{});
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
                for (indices) |index_value| {
                    if (index_value.value_type != .int) {
                        try self.fail("luce.sema.index", span, "array indices are Int", .{});
                        return null;
                    }
                }
                return shape.element;
            },
            .map => |pair| {
                if (indices.len != 1 or !indices[0].value_type.eql(pair.key)) {
                    try self.fail("luce.sema.index", span, "this map is keyed by {s}", .{
                        try self.analyzer.typeName(pair.key),
                    });
                    return null;
                }
                return pair.value;
            },
            .builder => {
                try self.fail("luce.sema.index", span, "Builder has no index; str(b) reads it", .{});
                return null;
            },
        }
    }

    fn lowerCondition(self: *FunctionBuilder, expression: *ast.Expression) Error!?Value {
        const condition = (try self.lowerExpression(expression, false)) orelse return null;
        if (condition.value_type != .boolean) {
            try self.fail("luce.sema.type", expression.span(), "condition must be Bool, not {s}", .{
                try self.analyzer.typeName(condition.value_type),
            });
            return null;
        }
        return condition;
    }

    fn lowerConditional(self: *FunctionBuilder, conditional: ast.Conditional) Error!void {
        const temps_floor = self.temps.items.len;
        const condition = (try self.lowerCondition(conditional.condition)) orelse return;
        // Condition temporaries die before the branch: the condition
        // value is a Bool, so nothing still needs them.
        try self.flushTemps(temps_floor);
        const arms = try self.code.openIf(condition.register, conditional.else_block != null);
        try self.lowerBlock(conditional.then_block);
        if (conditional.else_block) |else_block| {
            try self.code.elseArm(arms);
            try self.lowerBlock(else_block);
        }
        try self.code.closeIf(arms);
    }

    fn lowerWhile(self: *FunctionBuilder, loop: ast.While) Error!void {
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

        try self.lowerBlock(loop.body);
        _ = self.loops.pop();
        try self.code.closeWhile(shape);
    }

    fn lowerForRange(self: *FunctionBuilder, loop: ast.ForRange) Error!void {
        const temps_floor = self.temps.items.len;
        const bounds = (try self.lowerOperands(&.{ loop.start, loop.end })) orelse return;
        const start = bounds[0];
        const end = bounds[1];
        if (start.value_type != .int or end.value_type != .int) {
            try self.fail("luce.sema.type", loop.span, "range bounds must be Int", .{});
            return;
        }
        // Bound temporaries die before the loop starts.
        try self.flushTemps(temps_floor);

        try self.pushScope();
        defer self.popScope();
        const index_local = (try self.declareLocal(loop.name, .int, false, .alias, loop.span)) orelse return;
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
    }

    /// for x in xs: — the element (or map key) binds immutably each
    /// iteration, and a named iterable is locked against reassignment
    /// while the loop runs.  What that costs in blocks and hidden
    /// locals is `Lowering.openIteration`'s.
    fn lowerForEach(self: *FunctionBuilder, loop: ast.ForEach) Error!void {
        const iterable = (try self.lowerExpression(loop.iterable, false)) orelse return;
        const descriptor = self.analyzer.heapOf(iterable.value_type) orelse {
            try self.fail("luce.sema.loop", loop.span, "for iterates a List, a rank-1 Array, or a Map, not {s}", .{
                try self.analyzer.typeName(iterable.value_type),
            });
            return;
        };
        // Each collection has a "position" (a Map's key, or a
        // List/Array's Int index) and a "payload" (a Map's value, or
        // the element).  `for x in c:` binds the payload for
        // sequences and the key for maps (Python's habit); `for a, b
        // in c:` binds position then payload.
        var payload_kind: mir.Intrinsic = .index_get;
        var position_kind: ?mir.Intrinsic = null; // null = the raw Int index
        var position_type: Type = .int;
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
                try self.fail("luce.sema.loop", loop.span, "Builder is not iterable", .{});
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
        const name_local = (try self.declareLocal(loop.name, first_type, false, .alias, loop.span)) orelse return;
        const value_local: ?LocalId = if (two_names)
            (try self.declareLocal(loop.value_name.?, payload_type, false, .alias, loop.span)) orelse return
        else
            null;
        try self.code.startIteration(&shape, iterable.register);

        // Bind the first name: a getter intrinsic (key_at / index_get)
        // or the raw index when it is the List/Array position.
        const first_value = try self.code.iterationValue(shape, first_kind, first_type);
        try self.code.store(name_local, first_value);
        // Bind the payload as a second name when present.
        if (value_local) |local| {
            const payload = try self.code.iterationValue(shape, payload_kind, payload_type);
            try self.code.store(local, payload);
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
    }

    fn lowerReturn(self: *FunctionBuilder, returned: ast.Return) Error!void {
        if (returned.value) |expression| {
            const value = (try self.lowerExpression(expression, false)) orelse return;
            if (self.code.return_type == .none) {
                try self.fail("luce.sema.return", returned.span, "this function returns nothing", .{});
                return;
            }
            if (!value.value_type.eql(self.code.return_type)) {
                try self.fail("luce.sema.type", returned.span, "returning {s} from a function returning {s}", .{
                    try self.analyzer.typeName(value.value_type),
                    try self.analyzer.typeName(self.code.return_type),
                });
                return;
            }

            // Whatever a function returns, the caller owns (S16, S17):
            // an owned name moves out, fresh values flow out, borrows
            // are compile errors.
            var moved: ?LocalId = null;
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
                            .owned => moved = found.info.local,
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
                        // statement temporary; un-park it so the
                        // unwinding below leaves it alone.
                        var index = self.temps.items.len;
                        while (index > 0) {
                            index -= 1;
                            if (self.temps.items[index].register == value.register) {
                                _ = self.temps.orderedRemove(index);
                                break;
                            }
                        }
                    },
                }
            }
            try self.emitTempReleases(0);
            try self.emitScopeReleases(0, moved);
            try self.code.ret(value.register);
            return;
        }
        if (self.code.return_type != .none) {
            try self.fail("luce.sema.return", returned.span, "return needs a {s} value", .{
                try self.analyzer.typeName(self.code.return_type),
            });
            return;
        }
        try self.emitTempReleases(0);
        try self.emitScopeReleases(0, null);
        try self.code.ret(null);
    }

    // Expressions ----------------------------------------------------------

    fn lowerExpression(self: *FunctionBuilder, expression: *ast.Expression, as_statement: bool) Error!?Value {
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
        // Every ownership-yielding object is parked as a statement
        // temporary (S3).  Whatever adopts it — a binding, a
        // container, a give parameter, a return — re-owns it at run
        // time, which turns the parked release into a no-op.
        if (value.value_type != .none and
            self.analyzer.carriesObjects(value.value_type) and
            try self.yieldsOwnership(expression))
        {
            try self.registerTemp(value);
        }
        return value;
    }

    fn lowerExpressionInner(self: *FunctionBuilder, expression: *ast.Expression, as_statement: bool) Error!?Value {
        switch (expression.*) {
            .int_literal => |literal| {
                const parsed = helpers.parseIntLiteral(literal.text, false) orelse {
                    try self.fail("luce.sema.literal", literal.span, "{s}", .{declarations.integer_range_message});
                    return null;
                };
                return .{ .register = try self.code.emit(.{ .const_int = parsed }, .int), .value_type = .int };
            },
            .float_literal => |literal| {
                const parsed = helpers.parseFloatLiteral(literal.text) orelse {
                    try self.fail("luce.sema.literal", literal.span, "{s}", .{declarations.float_range_message});
                    return null;
                };
                return .{ .register = try self.code.emit(.{ .const_float = parsed }, .float), .value_type = .float };
            },
            .bool_literal => |literal| {
                return .{ .register = try self.code.emit(.{ .const_boolean = literal.value }, .boolean), .value_type = .boolean };
            },
            .string_literal => |literal| {
                const constant = try self.analyzer.pool.intern(literal.decoded);
                return .{
                    .register = try self.code.emit(.{ .const_data = .{ .constant = constant, .data_type = .string } }, .string),
                    .value_type = .string,
                };
            },
            .name => |name| {
                if (std.mem.eql(u8, name.text, "input") or std.mem.eql(u8, name.text, "output")) {
                    if (self.has_frames) {
                        try self.fail("luce.sema.port", name.span, "{s} is used as {s}.PORT", .{ name.text, name.text });
                    } else {
                        try self.fail("luce.sema.name", name.span, "{s} exists only in the evaluator entry", .{name.text});
                    }
                    return null;
                }
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
                return .{ .register = try self.code.load(local), .value_type = local_type };
            },
            .field => |field| return self.lowerField(field),
            .call => |call| return self.lowerCall(call, as_statement),
            .binary => |binary| return self.lowerBinary(binary),
            .unary => |unary| return self.lowerUnary(unary),
            .method => |method| return self.lowerMethod(method, as_statement),
            .new_object => |new| return self.lowerNew(new),
            .list_literal => |literal| return self.lowerListLiteral(literal),
            .index => |index| return self.lowerIndex(index),
            .slice_range => |slice| return self.lowerSliceRange(slice),
            .give => |give| return self.lowerGive(give),
            .copy => |copied| return self.lowerCopy(copied),
        }
    }

    /// give NAME — the named object transfers to whatever receives it;
    /// the name is poisoned to the end of its scope (S10, S13, S29).
    fn lowerGive(self: *FunctionBuilder, give: ast.Give) Error!?Value {
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
                "give applies to objects (List, Map, Array, Builder, object-carrying structs), not values [OWNERSHIP.md S32]",
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
        info.poisoned = .given;
        const owned = info.class == .owned;
        const value = try self.code.load(local);
        // An owned name passes its binding along so the runtime can
        // verify the name still owns the object; an alias keeps only
        // the container backstop (S23).
        const arguments = try self.arena().alloc(Register, if (owned) 2 else 1);
        arguments[0] = value;
        if (owned) {
            arguments[1] = try self.code.emit(.{ .const_int = local }, .int);
        }
        return .{
            .register = try self.code.emit(
                .{ .intrinsic = .{ .kind = .give_object, .arguments = arguments } },
                local_type,
            ),
            .value_type = local_type,
        };
    }

    /// Inline a folded file-scope constant at this use site.
    fn emitConstant(self: *FunctionBuilder, index: u32) Error!?Value {
        const info = self.analyzer.constant_infos.items[index];
        if (info.state != .ready) return null; // already diagnosed
        return .{
            .register = try self.emitConstantValue(info.value, info.value_type),
            .value_type = info.value_type,
        };
    }

    fn emitConstantValue(self: *FunctionBuilder, value: ConstantValue, value_type: Type) Error!Register {
        return switch (value) {
            .int => |folded| try self.code.emit(.{ .const_int = folded }, .int),
            .float => |folded| try self.code.emit(.{ .const_float = folded }, .float),
            .boolean => |folded| try self.code.emit(.{ .const_boolean = folded }, .boolean),
            .string => |folded| blk: {
                const constant = try self.analyzer.pool.intern(folded);
                break :blk try self.code.emit(
                    .{ .const_data = .{ .constant = constant, .data_type = .string } },
                    .string,
                );
            },
            .strukt => |folded| blk: {
                const layout = self.analyzer.structs.items[folded.layout];
                const fields = try self.arena().alloc(Register, folded.fields.len);
                for (folded.fields, layout.fields, fields) |field, field_layout, *slot| {
                    slot.* = try self.emitConstantValue(field, field_layout.field_type);
                }
                break :blk try self.code.emit(
                    .{ .struct_make = .{ .layout = folded.layout, .fields = fields } },
                    value_type,
                );
            },
        };
    }

    /// copy EXPR — a deep, independent duplicate; always legal on
    /// readable objects (S31).
    fn lowerCopy(self: *FunctionBuilder, copied: ast.Copy) Error!?Value {
        const value = (try self.lowerExpression(copied.operand, false)) orelse return null;
        if (!self.analyzer.carriesObjects(value.value_type)) {
            try self.fail(
                "luce.sema.own",
                copied.span,
                "copy applies to objects (List, Map, Array, Builder, object-carrying structs); values copy by themselves [OWNERSHIP.md S32]",
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

    fn lowerNew(self: *FunctionBuilder, new: ast.NewObject) Error!?Value {
        var object_type: Type = undefined;
        var dims: []Register = &.{};
        if (std.mem.eql(u8, new.type_name.name, "Array")) {
            if (new.dims.len == 0 or new.dims.len > 4) {
                try self.fail("luce.sema.new", new.span, "new Array takes 1 to 4 dimension sizes: new Array(Int, 5, 5)", .{});
                return null;
            }
            const element = (try self.analyzer.resolveType(self.module, new.type_name.arguments[0])) orelse return null;
            object_type = try self.analyzer.internHeapType(.{
                .array = .{ .element = element, .rank = @intCast(new.dims.len) },
            });
            dims = try self.arena().alloc(Register, new.dims.len);
            const dimensions = (try self.lowerOperands(new.dims)) orelse return null;
            for (dimensions, new.dims, dims) |dimension, expression, *register| {
                if (dimension.value_type != .int) {
                    try self.fail("luce.sema.new", expression.span(), "array dimensions are Int", .{});
                    return null;
                }
                register.* = dimension.register;
            }
        } else {
            object_type = (try self.analyzer.resolveType(self.module, new.type_name)) orelse return null;
            if (object_type != .heap) {
                try self.fail("luce.sema.new", new.span, "new builds List, Map, Array, or Builder", .{});
                return null;
            }
        }
        return .{
            .register = try self.code.emit(.{ .heap_new = .{ .heap = object_type.heap, .dims = dims } }, object_type),
            .value_type = object_type,
        };
    }

    fn lowerListLiteral(self: *FunctionBuilder, literal: ast.ListLiteral) Error!?Value {
        if (literal.elements.len == 0) {
            try self.fail(
                "luce.sema.type",
                literal.span,
                "an empty [] needs an annotated binding (var xs: List(Int) = []) or new List(T)",
                .{},
            );
            return null;
        }
        const elements = (try self.lowerOperands(literal.elements)) orelse return null;
        for (elements, literal.elements) |element, expression| {
            if (!element.value_type.eql(elements[0].value_type)) {
                try self.fail("luce.sema.type", expression.span(), "list elements are all {s}, got {s}", .{
                    try self.analyzer.typeName(elements[0].value_type),
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
        const object_type = try self.analyzer.internHeapType(.{ .list = elements[0].value_type });
        const list = try self.code.emit(.{ .heap_new = .{ .heap = object_type.heap, .dims = &.{} } }, object_type);
        for (elements) |element| {
            const arguments = try self.arena().alloc(Register, 2);
            arguments[0] = list;
            arguments[1] = element.register;
            _ = try self.code.emit(.{ .intrinsic = .{ .kind = .append_value, .arguments = arguments } }, .none);
        }
        return .{ .register = list, .value_type = object_type };
    }

    fn lowerIndex(self: *FunctionBuilder, index: ast.Index) Error!?Value {
        const expressions = try self.arena().alloc(*ast.Expression, index.indices.len + 1);
        expressions[0] = index.target;
        @memcpy(expressions[1..], index.indices);
        const values = (try self.lowerOperands(expressions)) orelse return null;
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

    fn lowerSliceRange(self: *FunctionBuilder, slice: ast.SliceRange) Error!?Value {
        var whole_sequence: std.ArrayList(*ast.Expression) = .empty;
        defer whole_sequence.deinit(self.temporary());
        try whole_sequence.append(self.temporary(), slice.target);
        if (slice.start) |expression| try whole_sequence.append(self.temporary(), expression);
        if (slice.end) |expression| try whole_sequence.append(self.temporary(), expression);
        const sequence = (try self.lowerOperands(whole_sequence.items)) orelse return null;
        const target = sequence[0];
        const is_string = target.value_type == .string;
        const descriptor = self.analyzer.heapOf(target.value_type);
        if (!is_string and (descriptor == null or descriptor.? != .list)) {
            try self.fail("luce.sema.index", slice.span, "{s} cannot be sliced; slices work on List and String", .{
                try self.analyzer.typeName(target.value_type),
            });
            return null;
        }

        const lowered_bounds = sequence[1..];
        for (lowered_bounds) |value| {
            if (value.value_type != .int) {
                try self.fail("luce.sema.type", slice.span, "slice bounds are Int", .{});
                return null;
            }
        }
        var next_bound: usize = 0;
        var start: Register = undefined;
        if (slice.start != null) {
            start = lowered_bounds[next_bound].register;
            next_bound += 1;
        } else {
            start = try self.code.emit(.{ .const_int = 0 }, .int);
        }
        var end: Register = undefined;
        if (slice.end != null) {
            end = lowered_bounds[next_bound].register;
        } else {
            const whole = try self.arena().alloc(Register, 1);
            whole[0] = target.register;
            end = try self.code.emit(.{ .intrinsic = .{ .kind = .len, .arguments = whole } }, .int);
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

    fn lowerField(self: *FunctionBuilder, field: ast.FieldAccess) Error!?Value {
        // input.NAME reads a port; anything else reads a struct field.
        if (field.target.* == .name) {
            const base = field.target.name.text;
            if (std.mem.eql(u8, base, "input")) {
                if (!self.has_frames) {
                    try self.fail("luce.sema.name", field.span, "input exists only in the evaluator entry", .{});
                    return null;
                }
                const port = self.analyzer.schema.findInput(field.name) orelse {
                    try self.fail("luce.sema.port", field.span, "no input port named {s}", .{field.name});
                    return null;
                };
                try self.analyzer.reads.put(self.analyzer.temporary, port, {});
                const port_type = Type.fromPort(self.analyzer.schema.inputs[port].declared);
                return .{ .register = try self.code.emit(.{ .input_load = port }, port_type), .value_type = port_type };
            }
            if (std.mem.eql(u8, base, "output")) {
                if (self.has_frames) {
                    try self.fail("luce.sema.output", field.span, "output ports are write-only", .{});
                } else {
                    try self.fail("luce.sema.name", field.span, "output exists only in the evaluator entry", .{});
                }
                return null;
            }
            // geo.pi — an imported module's file-scope constant.
            if (self.findLocal(base) == null and self.analyzer.importsModule(self.module, base)) {
                const joined = try std.fmt.allocPrint(self.arena(), "{s}.{s}", .{ base, field.name });
                if (self.analyzer.constant_names.get(joined)) |constant| {
                    return self.emitConstant(constant);
                }
            }
        }
        const target = (try self.lowerExpression(field.target, false)) orelse return null;
        if (target.value_type != .strukt) {
            try self.fail("luce.sema.field", field.span, "{s} has no fields", .{
                try self.analyzer.typeName(target.value_type),
            });
            return null;
        }
        const layout_index = target.value_type.strukt;
        const layout = self.analyzer.structs.items[layout_index];
        const field_index = layout.findField(field.name) orelse {
            try self.failUnknownField("luce.sema.field", layout, field.name, field.span);
            return null;
        };
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

    fn lowerBinary(self: *FunctionBuilder, binary: ast.Binary) Error!?Value {
        switch (binary.op) {
            .logic_and, .logic_or => return self.lowerShortCircuit(binary),
            else => {},
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
        const sides = (try self.lowerOperands(&.{ binary.left, binary.right })) orelse return null;
        const left = sides[0];
        const right = sides[1];
        if (!left.value_type.eql(right.value_type)) {
            try self.fail("luce.sema.type", binary.span, "operands are {s} and {s} (conversions are explicit)", .{
                try self.analyzer.typeName(left.value_type),
                try self.analyzer.typeName(right.value_type),
            });
            return null;
        }
        const operand_type = left.value_type;

        const operation: mir.BinaryOp = switch (binary.op) {
            .add => .add,
            .subtract => .subtract,
            .multiply => .multiply,
            .divide => .divide,
            .remainder => .remainder,
            .equal => .equal,
            .not_equal => .not_equal,
            .less => .less,
            .less_equal => .less_equal,
            .greater => .greater,
            .greater_equal => .greater_equal,
            .logic_and, .logic_or => unreachable,
        };

        const arithmetic = switch (operation) {
            .add, .subtract, .multiply, .divide, .remainder => true,
            else => false,
        };
        if (arithmetic) {
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

        // Comparisons: equality everywhere; ordering for Int, Float,
        // and String.
        const ordering = operation != .equal and operation != .not_equal;
        if (ordering and !(operand_type.isNumeric() or operand_type == .string)) {
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

    fn lowerShortCircuit(self: *FunctionBuilder, binary: ast.Binary) Error!?Value {
        const left = (try self.lowerExpression(binary.left, false)) orelse return null;
        if (left.value_type != .boolean) {
            try self.fail("luce.sema.type", binary.span, "{s} needs Bool operands", .{
                if (binary.op == .logic_and) @as([]const u8, "and") else "or",
            });
            return null;
        }
        // `and` evaluates its right side when the left is true, `or`
        // when it is false.
        const either = try self.code.openShortCircuit(left.register, binary.op == .logic_and);
        if (try self.lowerExpression(binary.right, false)) |right| {
            if (right.value_type != .boolean) {
                try self.fail("luce.sema.type", binary.span, "{s} needs Bool operands", .{
                    if (binary.op == .logic_and) @as([]const u8, "and") else "or",
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

    fn lowerUnary(self: *FunctionBuilder, unary: ast.Unary) Error!?Value {
        // -9223372036854775808 is one literal, not a negated one: the
        // magnitude alone is past Int's maximum, so the sign has to
        // fold in before the range is checked or the smallest Int is
        // the one number nobody can write.
        if (unary.op == .negate and unary.operand.* == .int_literal) {
            const literal = unary.operand.int_literal;
            const parsed = helpers.parseIntLiteral(literal.text, true) orelse {
                try self.fail("luce.sema.literal", unary.span, "{s}", .{declarations.integer_range_message});
                return null;
            };
            return .{ .register = try self.code.emit(.{ .const_int = parsed }, .int), .value_type = .int };
        }
        const operand = (try self.lowerExpression(unary.operand, false)) orelse return null;
        switch (unary.op) {
            .negate => {
                if (!operand.value_type.isNumeric()) {
                    try self.fail("luce.sema.type", unary.span, "cannot negate {s}", .{
                        try self.analyzer.typeName(operand.value_type),
                    });
                    return null;
                }
                return .{
                    .register = try self.code.emit(.{ .unary = .{ .op = .negate, .operand = operand.register } }, operand.value_type),
                    .value_type = operand.value_type,
                };
            },
            .logic_not => {
                if (operand.value_type != .boolean) {
                    try self.fail("luce.sema.type", unary.span, "not needs a Bool", .{});
                    return null;
                }
                return .{
                    .register = try self.code.emit(.{ .unary = .{ .op = .logic_not, .operand = operand.register } }, .boolean),
                    .value_type = .boolean,
                };
            },
        }
    }

    // Calls and methods ----------------------------------------------------
    //
    // Struct construction, explicit conversion, namespaced calls, and
    // builtin methods on values.
    fn lowerCall(self: *FunctionBuilder, call: ast.Call, as_statement: bool) Error!?Value {
        // Builtins and conversions are bare names and take priority;
        // reserved names keep user declarations out of their way.
        if (std.mem.indexOfScalar(u8, call.callee, '.') == null) {
            if (std.mem.eql(u8, call.callee, "Int") or std.mem.eql(u8, call.callee, "Float")) {
                return self.lowerConvert(call);
            }
            switch (try self.lowerIntrinsic(call, as_statement)) {
                .not_builtin => {},
                .failed => return null,
                .value => |value| return value,
            }
        }

        const resolved = (try self.resolveDeclared(call.callee, call.span)) orelse return null;
        if (self.analyzer.struct_names.get(resolved)) |layout_index| {
            return self.lowerConstruct(call.arguments, call.span, layout_index);
        }
        const function_index = self.analyzer.function_names.get(resolved) orelse {
            try self.failUnknownFunction(call.callee, call.span);
            return null;
        };
        return self.lowerUserCall(function_index, call.callee, call.arguments, call.span, as_statement);
    }

    fn lowerUserCall(
        self: *FunctionBuilder,
        function_index: u32,
        name: []const u8,
        call_arguments: []const ast.Argument,
        span: Span,
        as_statement: bool,
    ) Error!?Value {
        const info = self.analyzer.functions.items[function_index];
        if (info.is_entry) {
            try self.fail("luce.sema.call", span, "entry function {s} cannot be called", .{name});
            return null;
        }
        if (call_arguments.len != info.parameter_types.len) {
            try self.fail("luce.sema.call", span, "{s} takes {d} arguments, got {d}", .{
                name,
                info.parameter_types.len,
                call_arguments.len,
            });
            return null;
        }
        const expressions = try self.arena().alloc(*ast.Expression, call_arguments.len);
        for (call_arguments, expressions) |argument, *slot| {
            if (argument.name != null) {
                try self.fail("luce.sema.call", argument.span, "function arguments are positional", .{});
                return null;
            }
            slot.* = argument.value;
        }
        // Ownership handoffs are never invisible: a give parameter
        // needs give NAME, copy NAME, or something fresh at the call
        // site; a borrow parameter refuses a give (S13, S14).
        for (expressions, 0..) |argument, index| {
            if (index >= info.parameter_modes.len) break;
            if (info.parameter_modes[index] == .give) {
                if (!(try self.yieldsOwnership(argument))) {
                    try self.failNeedsOwnership(
                        call_arguments[index].span,
                        try std.fmt.allocPrint(self.arena(), "argument {d} of {s} takes ownership", .{ index + 1, name }),
                        argument,
                        "S13, S14",
                    );
                    return null;
                }
            } else if (argument.* == .give) {
                try self.fail(
                    "luce.sema.own",
                    call_arguments[index].span,
                    "{s} only borrows this argument; give needs a give parameter in the signature [OWNERSHIP.md S11, S13]",
                    .{name},
                );
                return null;
            }
        }
        const values = (try self.lowerOperands(expressions)) orelse return null;
        const registers = try self.arena().alloc(Register, call_arguments.len);
        for (values, 0..) |value, index| {
            if (!value.value_type.eql(info.parameter_types[index])) {
                try self.fail("luce.sema.type", call_arguments[index].span, "argument {d} of {s} is {s}, got {s}", .{
                    index + 1,
                    name,
                    try self.analyzer.typeName(info.parameter_types[index]),
                    try self.analyzer.typeName(value.value_type),
                });
                return null;
            }
            registers[index] = value.register;
        }
        if (info.return_type == .none and !as_statement) {
            try self.fail("luce.sema.call", span, "{s} returns nothing", .{name});
            return null;
        }
        return .{
            .register = try self.code.emit(.{ .call = .{ .function = function_index, .arguments = registers } }, info.return_type),
            .value_type = info.return_type,
        };
    }

    /// target.name(args): a namespaced call when the target chain is
    /// bare declaration names (Struct.func, module.func,
    /// module.Struct(...) construction), otherwise a builtin method on
    /// the target value.  Locals shadow nothing, so a chain whose head
    /// is a local is always a value method.
    fn lowerMethod(self: *FunctionBuilder, method: ast.Method, as_statement: bool) Error!?Value {
        switch (try self.methodNamespace(method)) {
            .resolved => |resolved| {
                if (self.analyzer.struct_names.get(resolved)) |layout_index| {
                    return self.lowerConstruct(method.arguments, method.span, layout_index);
                }
                const function_index = self.analyzer.function_names.get(resolved).?;
                return self.lowerUserCall(function_index, resolved, method.arguments, method.span, as_statement);
            },
            .reported => return null,
            .value => return self.lowerValueMethod(method, as_statement),
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
        const head_qualified = try self.analyzer.qualify(self.prefix, head);
        if (self.analyzer.struct_names.contains(head_qualified)) {
            const local = try self.analyzer.qualify(self.prefix, joined);
            if (self.analyzer.struct_names.contains(local) or self.analyzer.function_names.contains(local)) {
                return .{ .resolved = try self.arena().dupe(u8, local) };
            }
            try self.failUnknownFunction(joined, method.span);
            return .reported;
        }
        if (self.analyzer.importsModule(self.module, head)) {
            if (self.analyzer.struct_names.contains(joined) or self.analyzer.function_names.contains(joined)) {
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
    fn lowerValueMethod(self: *FunctionBuilder, method: ast.Method, as_statement: bool) Error!?Value {
        const expressions = try self.arena().alloc(*ast.Expression, method.arguments.len + 1);
        expressions[0] = method.target;
        for (method.arguments, 0..) |argument, index| {
            if (argument.name != null) {
                try self.fail("luce.sema.method", argument.span, "method arguments are positional", .{});
                return null;
            }
            expressions[index + 1] = argument.value;
        }
        const values = (try self.lowerOperands(expressions)) orelse
            return null;
        const receiver = values[0];
        const arguments = values[1..];

        const found: MethodFound = blk: {
            if (receiver.value_type == .string) {
                // byte_at is the language's primitive byte access;
                // every other String method is library code —
                // s.find(x) is strings.find(s, x) (docs/STD.md).
                if (std.mem.eql(u8, method.name, "byte_at")) {
                    if (arguments.len != 1 or arguments[0].value_type != .int) {
                        try self.fail("luce.sema.method", method.span, "byte_at takes an Int offset", .{});
                        return null;
                    }
                    break :blk .{ .kind = .string_byte, .result = .int };
                }
                // find_byte is the scanning primitive that byte_at is
                // the access primitive: std strings builds substring
                // search on it (docs/STD.md).
                if (std.mem.eql(u8, method.name, "find_byte")) {
                    if (arguments.len != 2 or arguments[0].value_type != .int or
                        arguments[1].value_type != .int)
                    {
                        try self.fail("luce.sema.method", method.span, "find_byte takes (byte Int, start Int)", .{});
                        return null;
                    }
                    break :blk .{ .kind = .string_find_byte, .result = .int };
                }
                return self.stringsCall(method, values, as_statement);
            }
            if (self.analyzer.heapOf(receiver.value_type)) |descriptor| {
                // join belongs to the strings module too: it makes a
                // String, from List(String).
                if (descriptor == .list and descriptor.list == .string and
                    std.mem.eql(u8, method.name, "join"))
                {
                    return self.stringsCall(method, values, as_statement);
                }
                // Built-in methods take at most two arguments; only
                // routed strings calls go wider.
                if (method.arguments.len > 2) {
                    try self.fail("luce.sema.method", method.span, "no method takes more than 2 arguments", .{});
                    return null;
                }
                if (try self.objectMethod(method, receiver.value_type, descriptor, arguments)) |found| {
                    break :blk found;
                }
                return null;
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
        return .{
            .register = try self.code.emit(.{ .intrinsic = .{ .kind = found.kind, .arguments = registers } }, found.result),
            .value_type = found.result,
        };
    }

    const MethodFound = struct { kind: mir.Intrinsic, result: Type };

    fn methodFail(self: *FunctionBuilder, method: ast.Method, comptime message: []const u8) Error!?MethodFound {
        try self.fail("luce.sema.method", method.span, message, .{});
        return null;
    }

    /// Route a value method to the std strings module: `s.find(x)` is
    /// `strings.find(s, x)`, and `parts.join(sep)` is
    /// `strings.join(parts, sep)`.  The language keeps the primitives
    /// (literals, +, comparison, slices, len, byte_at); manipulation
    /// is library code and needs the import.
    fn stringsCall(
        self: *FunctionBuilder,
        method: ast.Method,
        values: []const Value,
        as_statement: bool,
    ) Error!?Value {
        const local_module = std.mem.eql(u8, self.prefix, "strings");
        if (!local_module and !self.analyzer.importsModule(self.module, "strings")) {
            try self.fail(
                "luce.sema.import",
                method.span,
                "String manipulation lives in the standard library: import std.strings to use {s} (docs/STD.md)",
                .{method.name},
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
            var keys = self.analyzer.function_names.keyIterator();
            while (keys.next()) |key| {
                if (std.mem.startsWith(u8, key.*, "strings.")) suggestion.offer(key.*["strings.".len..]);
            }
            if (suggestion.best()) |closest| {
                try self.fail("luce.sema.method", method.span, "strings has no function {s}; did you mean {s}?", .{ method.name, closest });
            } else {
                try self.fail("luce.sema.method", method.span, "strings has no function {s}", .{method.name});
            }
            return null;
        };
        return self.callUser(function_index, qualified, values, method.span, as_statement);
    }

    /// The emitting half of a user call, for callers that already
    /// lowered their operands (method routing): arity and type checks
    /// against the signature, then the call instruction.
    fn callUser(
        self: *FunctionBuilder,
        function_index: u32,
        name: []const u8,
        values: []const Value,
        span: Span,
        as_statement: bool,
    ) Error!?Value {
        const info = self.analyzer.functions.items[function_index];
        if (values.len != info.parameter_types.len) {
            try self.fail("luce.sema.call", span, "{s} takes {d} arguments, got {d}", .{
                name,
                info.parameter_types.len,
                values.len,
            });
            return null;
        }
        const registers = try self.arena().alloc(Register, values.len);
        for (values, 0..) |value, index| {
            if (!value.value_type.eql(info.parameter_types[index])) {
                try self.fail("luce.sema.type", span, "argument {d} of {s} is {s}, got {s}", .{
                    index + 1,
                    name,
                    try self.analyzer.typeName(info.parameter_types[index]),
                    try self.analyzer.typeName(value.value_type),
                });
                return null;
            }
            registers[index] = value.register;
        }
        if (info.return_type == .none and !as_statement) {
            try self.fail("luce.sema.call", span, "{s} returns nothing", .{name});
            return null;
        }
        return .{
            .register = try self.code.emit(.{ .call = .{ .function = function_index, .arguments = registers } }, info.return_type),
            .value_type = info.return_type,
        };
    }

    /// The method names each receiver kind answers to — the tables
    /// below dispatch on them, and a "did you mean" needs the same
    /// list to measure against.  Kept beside the dispatch so the two
    /// cannot drift apart unnoticed.
    const list_methods = [_][]const u8{
        "append", "insert",  "remove", "pop",      "clear",
        "sort",   "reverse", "find",   "contains",
    };
    const array_methods = [_][]const u8{ "dim", "fill", "sort", "reverse", "find", "contains" };
    const map_methods = [_][]const u8{ "has", "get", "remove", "keys", "values", "clear" };
    const builder_methods = [_][]const u8{ "append", "append_ascii", "clear" };

    fn objectMethod(
        self: *FunctionBuilder,
        method: ast.Method,
        receiver_type: Type,
        descriptor: types.HeapType,
        arguments: []const Value,
    ) Error!?MethodFound {
        _ = receiver_type;
        const name = method.name;
        switch (descriptor) {
            .list => |element| return self.sequenceMethod(method, element, true, arguments),
            .array => |shape| {
                if (std.mem.eql(u8, name, "dim")) {
                    if (arguments.len != 1 or arguments[0].value_type != .int)
                        return self.methodFail(method, "dim takes an Int axis");
                    return .{ .kind = .dim_size, .result = .int };
                }
                if (std.mem.eql(u8, name, "fill")) {
                    if (arguments.len != 1 or !arguments[0].value_type.eql(shape.element))
                        return self.methodFail(method, "fill takes one element value");
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
                return self.sequenceMethod(method, shape.element, false, arguments);
            },
            .map => |pair| {
                if (std.mem.eql(u8, name, "has")) {
                    if (arguments.len != 1 or !arguments[0].value_type.eql(pair.key))
                        return self.methodFail(method, "has takes the map's key type");
                    return .{ .kind = .has_key, .result = .boolean };
                }
                if (std.mem.eql(u8, name, "remove")) {
                    if (arguments.len != 1 or !arguments[0].value_type.eql(pair.key))
                        return self.methodFail(method, "remove takes the map's key type");
                    return .{ .kind = .remove_entry, .result = .none };
                }
                if (std.mem.eql(u8, name, "keys")) {
                    if (arguments.len != 0) return self.methodFail(method, "keys takes no arguments");
                    return .{ .kind = .map_keys, .result = try self.analyzer.internHeapType(.{ .list = pair.key }) };
                }
                if (std.mem.eql(u8, name, "values")) {
                    if (arguments.len != 0) return self.methodFail(method, "values takes no arguments");
                    return .{ .kind = .map_values, .result = try self.analyzer.internHeapType(.{ .list = pair.value }) };
                }
                if (std.mem.eql(u8, name, "get")) {
                    if (arguments.len != 2 or !arguments[0].value_type.eql(pair.key) or
                        !arguments[1].value_type.eql(pair.value))
                        return self.methodFail(method, "get takes (key, default) of the map's key and value types");
                    return .{ .kind = .map_get, .result = pair.value };
                }
                if (std.mem.eql(u8, name, "clear")) {
                    if (arguments.len != 0) return self.methodFail(method, "clear takes no arguments");
                    return .{ .kind = .clear_object, .result = .none };
                }
                var suggestion = helpers.Suggestion.init(name);
                suggestion.offerAll(&map_methods);
                if (suggestion.best()) |closest| {
                    try self.fail("luce.sema.method", method.span, "Map has no method {s}; did you mean {s}?", .{ name, closest });
                } else {
                    try self.fail("luce.sema.method", method.span, "Map has no method {s} (has get remove keys values clear)", .{name});
                }
                return null;
            },
            .builder => {
                if (std.mem.eql(u8, name, "append")) {
                    if (arguments.len != 1 or arguments[0].value_type != .string)
                        return self.methodFail(method, "a Builder appends String");
                    return .{ .kind = .append_value, .result = .none };
                }
                if (std.mem.eql(u8, name, "append_ascii")) {
                    if (arguments.len != 1 or arguments[0].value_type != .int)
                        return self.methodFail(method, "append_ascii takes an Int byte in 0..127");
                    return .{ .kind = .append_ascii, .result = .none };
                }
                if (std.mem.eql(u8, name, "clear")) {
                    if (arguments.len != 0) return self.methodFail(method, "clear takes no arguments");
                    return .{ .kind = .clear_object, .result = .none };
                }
                var suggestion = helpers.Suggestion.init(name);
                suggestion.offerAll(&builder_methods);
                if (suggestion.best()) |closest| {
                    try self.fail("luce.sema.method", method.span, "Builder has no method {s}; did you mean {s}?", .{ name, closest });
                } else {
                    try self.fail("luce.sema.method", method.span, "Builder has no method {s} (append append_ascii clear)", .{name});
                }
                return null;
            },
        }
    }

    /// Methods shared by List and rank-1 Array; growth operations are
    /// list-only.
    fn sequenceMethod(
        self: *FunctionBuilder,
        method: ast.Method,
        element: Type,
        growable: bool,
        arguments: []const Value,
    ) Error!?MethodFound {
        const name = method.name;
        if (growable) {
            if (std.mem.eql(u8, name, "append")) {
                if (arguments.len != 1 or !arguments[0].value_type.eql(element))
                    return self.methodFail(method, "append takes one element value");
                return .{ .kind = .append_value, .result = .none };
            }
            if (std.mem.eql(u8, name, "insert")) {
                if (arguments.len != 2 or arguments[0].value_type != .int or
                    !arguments[1].value_type.eql(element))
                    return self.methodFail(method, "insert takes (index Int, value)");
                return .{ .kind = .insert_value, .result = .none };
            }
            if (std.mem.eql(u8, name, "remove")) {
                if (arguments.len != 1 or arguments[0].value_type != .int)
                    return self.methodFail(method, "remove takes an Int index");
                return .{ .kind = .remove_entry, .result = .none };
            }
            if (std.mem.eql(u8, name, "pop")) {
                if (arguments.len != 0) return self.methodFail(method, "pop takes no arguments");
                return .{ .kind = .pop_value, .result = element };
            }
            if (std.mem.eql(u8, name, "clear")) {
                if (arguments.len != 0) return self.methodFail(method, "clear takes no arguments");
                return .{ .kind = .clear_object, .result = .none };
            }
        }
        if (std.mem.eql(u8, name, "sort")) {
            if (arguments.len != 0) return self.methodFail(method, "sort takes no arguments");
            const ordered = element == .int or element == .float or element == .string;
            if (!ordered) return self.methodFail(method, "sort orders Int, Float, or String elements");
            return .{ .kind = .list_sort, .result = .none };
        }
        if (std.mem.eql(u8, name, "reverse")) {
            if (arguments.len != 0) return self.methodFail(method, "reverse takes no arguments");
            return .{ .kind = .list_reverse, .result = .none };
        }
        if (std.mem.eql(u8, name, "find")) {
            if (arguments.len != 1 or !arguments[0].value_type.eql(element))
                return self.methodFail(method, "find takes one element value");
            return .{ .kind = .list_find, .result = .int };
        }
        if (std.mem.eql(u8, name, "contains")) {
            if (arguments.len != 1 or !arguments[0].value_type.eql(element))
                return self.methodFail(method, "contains takes one element value");
            return .{ .kind = .list_contains, .result = .boolean };
        }
        var suggestion = helpers.Suggestion.init(name);
        suggestion.offerAll(if (growable) &list_methods else &array_methods);
        if (suggestion.best()) |closest| {
            try self.fail("luce.sema.method", method.span, "no method {s} here; did you mean {s}?", .{ name, closest });
            return null;
        }
        try self.fail("luce.sema.method", method.span, "no method {s} here (append insert remove pop sort reverse find contains clear; join lives in strings)", .{name});
        return null;
    }

    fn lowerConstruct(
        self: *FunctionBuilder,
        call_arguments: []const ast.Argument,
        span: Span,
        layout_index: u32,
    ) Error!?Value {
        const layout = self.analyzer.structs.items[layout_index];
        if (layout.fields.len == 0) {
            try self.fail(
                "luce.sema.construct",
                span,
                "{s} is a function namespace and has no value fields",
                .{layout.name},
            );
            return null;
        }
        const registers = try self.arena().alloc(Register, layout.fields.len);
        var seen = try self.temporary().alloc(bool, layout.fields.len);
        defer self.temporary().free(seen);
        @memset(seen, false);

        const expressions = try self.arena().alloc(*ast.Expression, call_arguments.len);
        for (call_arguments, expressions) |argument, *slot| slot.* = argument.value;
        const values = (try self.lowerOperands(expressions)) orelse return null;
        for (call_arguments, values) |argument, value| {
            const name = argument.name orelse {
                try self.fail("luce.sema.construct", argument.span, "{s} is built with named fields: {s}(field = ...)", .{ layout.name, layout.name });
                return null;
            };
            const field_index = layout.findField(name) orelse {
                try self.failUnknownField("luce.sema.construct", layout, name, argument.span);
                return null;
            };
            if (seen[field_index]) {
                try self.fail("luce.sema.construct", argument.span, "field {s} given twice", .{name});
                return null;
            }
            const expected = layout.fields[field_index].field_type;
            if (!value.value_type.eql(expected)) {
                try self.fail("luce.sema.type", argument.span, "{s}.{s} is {s}, got {s}", .{
                    layout.name,
                    name,
                    try self.analyzer.typeName(expected),
                    try self.analyzer.typeName(value.value_type),
                });
                return null;
            }
            // Object fields follow the verb rule at construction
            // (S24): the binding that receives the struct owns them.
            if (self.analyzer.carriesObjects(expected) and
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
            seen[field_index] = true;
            registers[field_index] = value.register;
        }
        for (seen, 0..) |given, index| {
            if (!given) {
                try self.fail("luce.sema.construct", span, "{s} is missing field {s}", .{
                    layout.name,
                    layout.fields[index].name,
                });
                return null;
            }
        }
        const result_type: Type = .{ .strukt = layout_index };
        return .{
            .register = try self.code.emit(.{ .struct_make = .{ .layout = layout_index, .fields = registers } }, result_type),
            .value_type = result_type,
        };
    }

    fn lowerConvert(self: *FunctionBuilder, call: ast.Call) Error!?Value {
        if (call.arguments.len != 1 or call.arguments[0].name != null) {
            try self.fail("luce.sema.convert", call.span, "{s}(value) takes one argument", .{call.callee});
            return null;
        }
        const value = (try self.lowerExpression(call.arguments[0].value, false)) orelse return null;
        const to_int = std.mem.eql(u8, call.callee, "Int");
        if (to_int) {
            if (value.value_type == .int) return value;
            if (value.value_type != .float) {
                try self.fail("luce.sema.convert", call.span, "Int() converts Float, not {s}", .{
                    try self.analyzer.typeName(value.value_type),
                });
                return null;
            }
            return .{
                .register = try self.code.emit(.{ .convert = .{ .kind = .float_to_int, .operand = value.register } }, .int),
                .value_type = .int,
            };
        }
        if (value.value_type == .float) return value;
        if (value.value_type != .int) {
            try self.fail("luce.sema.convert", call.span, "Float() converts Int, not {s}", .{
                try self.analyzer.typeName(value.value_type),
            });
            return null;
        }
        return .{
            .register = try self.code.emit(.{ .convert = .{ .kind = .int_to_float, .operand = value.register } }, .float),
            .value_type = .float,
        };
    }

    // Builtins ---------------------------------------------------------------

    const IntrinsicResult = union(enum) {
        not_builtin,
        failed,
        value: Value,
    };

    /// Lower a builtin call; .not_builtin when the callee is no
    /// builtin, .failed after reporting bad arguments.
    fn lowerIntrinsic(self: *FunctionBuilder, call: ast.Call, as_statement: bool) Error!IntrinsicResult {
        const Builtin = struct {
            name: []const u8,
            kind: mir.Intrinsic,
            arity: usize,
            host: bool = false,
        };
        const builtins = [_]Builtin{
            .{ .name = "abs", .kind = .abs, .arity = 1 },
            .{ .name = "min", .kind = .min, .arity = 2 },
            .{ .name = "max", .kind = .max, .arity = 2 },
            .{ .name = "clamp", .kind = .clamp, .arity = 3 },
            .{ .name = "sqrt", .kind = .sqrt, .arity = 1 },
            .{ .name = "floor", .kind = .floor, .arity = 1 },
            .{ .name = "ceil", .kind = .ceil, .arity = 1 },
            .{ .name = "len", .kind = .len, .arity = 1 },
            .{ .name = "assert", .kind = .assert_true, .arity = 1 },
            .{ .name = "trap", .kind = .trap_message, .arity = 1 },
            .{ .name = "free", .kind = .free_object, .arity = 1 },
            .{ .name = "str", .kind = .str_value, .arity = 1 },
            .{ .name = "parse_int", .kind = .parse_int, .arity = 1 },
            .{ .name = "parse_float", .kind = .parse_float, .arity = 1 },
            .{ .name = "chr", .kind = .chr_code, .arity = 1 },
            .{ .name = "ord", .kind = .ord_text, .arity = 1 },
            .{ .name = "print", .kind = .print, .arity = 1, .host = true },
            .{ .name = "file_read", .kind = .file_read, .arity = 1, .host = true },
            .{ .name = "file_write", .kind = .file_write, .arity = 2, .host = true },
            .{ .name = "file_exists", .kind = .file_exists, .arity = 1, .host = true },
            .{ .name = "arg_count", .kind = .arg_count, .arity = 0, .host = true },
            .{ .name = "arg", .kind = .arg_get, .arity = 1, .host = true },
            .{ .name = "term_rows", .kind = .term_rows, .arity = 0, .host = true },
            .{ .name = "term_cols", .kind = .term_cols, .arity = 0, .host = true },
            .{ .name = "term_clear", .kind = .term_clear, .arity = 0, .host = true },
            .{ .name = "term_move", .kind = .term_move, .arity = 2, .host = true },
            .{ .name = "term_style", .kind = .term_style, .arity = 3, .host = true },
            .{ .name = "term_write", .kind = .term_write, .arity = 1, .host = true },
            .{ .name = "term_flush", .kind = .term_flush, .arity = 0, .host = true },
            .{ .name = "key_read", .kind = .key_read, .arity = 0, .host = true },
            .{ .name = "key_text", .kind = .key_text, .arity = 0, .host = true },
        };
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
            call.arguments[0].name == null and call.arguments[0].value.* == .string_literal)
        {
            if (helpers.ordOfLiteral(call.arguments[0].value.string_literal.decoded)) |codepoint| {
                return .{ .value = .{
                    .register = try self.code.emit(.{ .const_int = codepoint }, .int),
                    .value_type = .int,
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
        if (call.arguments.len != matched.arity) {
            try self.fail("luce.sema.call", call.span, "{s} takes {d} arguments", .{ matched.name, matched.arity });
            return .failed;
        }
        var argument_expressions: [3]*ast.Expression = undefined;
        for (call.arguments, 0..) |argument, index| {
            if (argument.name != null) {
                try self.fail("luce.sema.call", argument.span, "builtin arguments are positional", .{});
                return .failed;
            }
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
        const arguments = (try self.lowerOperands(argument_expressions[0..call.arguments.len])) orelse
            return .failed;

        // Argument and result typing per builtin.
        var result: Type = .none;
        var extra_argument: ?Register = null;
        switch (matched.kind) {
            .abs => {
                if (!arguments[0].value_type.isNumeric()) return self.failIntrinsic(call, "abs takes Int or Float");
                result = arguments[0].value_type;
            },
            .min, .max => {
                if (!arguments[0].value_type.isNumeric() or
                    !arguments[0].value_type.eql(arguments[1].value_type))
                    return self.failIntrinsic(call, "min/max take two Ints or two Floats");
                result = arguments[0].value_type;
            },
            .clamp => {
                if (!arguments[0].value_type.isNumeric() or
                    !arguments[0].value_type.eql(arguments[1].value_type) or
                    !arguments[0].value_type.eql(arguments[2].value_type))
                    return self.failIntrinsic(call, "clamp takes three Ints or three Floats");
                result = arguments[0].value_type;
            },
            .sqrt, .floor, .ceil => {
                if (arguments[0].value_type != .float)
                    return self.failIntrinsic(call, "this builtin takes a Float");
                result = .float;
            },
            .len => {
                const measurable = arguments[0].value_type == .string or
                    arguments[0].value_type == .bytes or
                    arguments[0].value_type == .heap;
                if (!measurable)
                    return self.failIntrinsic(call, "len takes a String, Bytes, List, Map, Array, or Builder");
                result = .int;
            },
            .free_object => {
                if (arguments[0].value_type != .heap)
                    return self.failIntrinsic(call, "free releases a List, Map, Array, or Builder");
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
                extra_argument = try self.code.emit(.{ .const_int = found.info.local }, .int);
                result = .none;
            },
            .str_value => {
                const descriptor = self.analyzer.heapOf(arguments[0].value_type);
                const stringable = switch (arguments[0].value_type) {
                    .int, .float, .boolean, .string => true,
                    .heap => descriptor.? == .builder,
                    else => false,
                };
                if (!stringable)
                    return self.failIntrinsic(call, "str takes Int, Float, Bool, String, or Builder");
                result = .string;
            },
            .parse_int, .parse_float => {
                if (arguments[0].value_type != .string)
                    return self.failIntrinsic(call, "this builtin parses a String");
                result = if (matched.kind == .parse_int) .int else .float;
            },
            .chr_code => {
                if (arguments[0].value_type != .int)
                    return self.failIntrinsic(call, "chr takes an Int codepoint");
                result = .string;
            },
            .ord_text => {
                if (arguments[0].value_type != .string)
                    return self.failIntrinsic(call, "ord takes a String");
                result = .int;
            },
            // Lowered from syntax or method calls, never from bare names.
            .give_object,
            .copy_object,
            .null_object,
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
            .array_fill,
            => unreachable,

            .assert_true => {
                if (arguments[0].value_type != .boolean)
                    return self.failIntrinsic(call, "assert takes a Bool");
                result = .none;
            },
            .trap_message => {
                if (arguments[0].value_type != .string)
                    return self.failIntrinsic(call, "trap takes a String message");
                result = .none;
            },
            .print, .term_write => {
                if (arguments[0].value_type != .string)
                    return self.failIntrinsic(call, "this builtin takes a String");
                result = .none;
            },
            .file_read => {
                if (arguments[0].value_type != .string)
                    return self.failIntrinsic(call, "file_read takes a String path");
                result = .string;
            },
            .file_write => {
                if (arguments[0].value_type != .string or arguments[1].value_type != .string)
                    return self.failIntrinsic(call, "file_write takes (path String, content String)");
                result = .boolean;
            },
            .file_exists => {
                if (arguments[0].value_type != .string)
                    return self.failIntrinsic(call, "file_exists takes a String path");
                result = .boolean;
            },
            .arg_count, .term_rows, .term_cols => {
                result = .int;
            },
            .arg_get => {
                if (arguments[0].value_type != .int)
                    return self.failIntrinsic(call, "arg takes an Int index");
                result = .string;
            },
            .term_clear, .term_flush => {
                result = .none;
            },
            .term_move => {
                if (arguments[0].value_type != .int or arguments[1].value_type != .int)
                    return self.failIntrinsic(call, "term_move takes (row Int, col Int)");
                result = .none;
            },
            .term_style => {
                if (arguments[0].value_type != .int or
                    arguments[1].value_type != .int or
                    arguments[2].value_type != .boolean)
                    return self.failIntrinsic(call, "term_style takes (foreground Int, background Int, bold Bool)");
                result = .none;
            },
            .key_read, .key_text => {
                result = .string;
            },
        }
        if (result == .none and !as_statement) {
            try self.fail("luce.sema.call", call.span, "{s} returns nothing", .{matched.name});
            return .failed;
        }

        const register_count = arguments.len + @intFromBool(extra_argument != null);
        const registers = try self.arena().alloc(Register, register_count);
        for (arguments, registers[0..arguments.len]) |value, *register| register.* = value.register;
        if (extra_argument) |extra| registers[register_count - 1] = extra;
        return .{ .value = .{
            .register = try self.code.emit(.{ .intrinsic = .{ .kind = matched.kind, .arguments = registers } }, result),
            .value_type = result,
        } };
    }

    fn failIntrinsic(self: *FunctionBuilder, call: ast.Call, message: []const u8) Error!IntrinsicResult {
        try self.fail("luce.sema.type", call.span, "{s}", .{message});
        return .failed;
    }
};
