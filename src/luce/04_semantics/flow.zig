//! The two facts this walk carries across a branch, and the one
//! facility that saves, restores and joins them: which optional locals
//! are proved present (narrowing), and where the root behind an object
//! value stands (root provenance, docs/CONSTANTS.md).
//!
//! Both are per-local sets on the walker, both are read on the fast
//! path by a linear scan, and both need exactly the same three verbs
//! around every branch — save what holds here, restore it for the
//! other arm, intersect the two at the join.  Written once for the
//! pair, so the arms of an `if` can never disagree about which of the
//! two they remembered to put back.
//!
//! Its interface is those verbs plus the facts that feed them: what a
//! condition proves (`applyFacts`), what a loop body destroys
//! (`prepareLoopFacts`, `widenAssignedBy`), and the refusals that fire
//! when a program writes through a name it does not own
//! (`refuseConstantWrite`, `refuseConstantEscape`).

const std = @import("std");
const source_mod = @import("../01_source.zig");
const ast = @import("../03_parse.zig").ast;
const mir = @import("../06_mir.zig");
const context = @import("context.zig");
const RootState = context.RootState;
const Error = context.Error;
const Span = source_mod.Span;
const LocalId = mir.LocalId;

const assign = @import("assign.zig");
const builder = @import("builder.zig");
const recorder = @import("recorder.zig");
const FunctionBuilder = builder.FunctionBuilder;

pub fn isNarrowed(self: *const FunctionBuilder, local: LocalId) bool {
    return std.mem.indexOfScalar(LocalId, self.narrowed.items, local) != null;
}

/// `local` is known to hold a value from here on.
pub fn narrow(self: *FunctionBuilder, local: LocalId) Error!void {
    if (isNarrowed(self, local)) return;
    try self.narrowed.append(self.temporary(), local);
}

/// `local` might be absent again: it was assigned, or a loop body
/// assigns it and the back edge re-enters with whatever that left.
pub fn widen(self: *FunctionBuilder, local: LocalId) void {
    const at = std.mem.indexOfScalar(LocalId, self.narrowed.items, local) orelse return;
    _ = self.narrowed.swapRemove(at);
}

/// A copy of the current set, for a branch to rejoin against.  The
/// caller frees it.
pub fn narrowSave(self: *FunctionBuilder) Error![]LocalId {
    return self.temporary().dupe(LocalId, self.narrowed.items);
}

pub fn narrowRestore(self: *FunctionBuilder, saved: []const LocalId) Error!void {
    self.narrowed.clearRetainingCapacity();
    try self.narrowed.appendSlice(self.temporary(), saved);
}

/// Keep only what both arms of a conditional agree on.  A local
/// narrowed on one path and assigned away on the other is absent
/// again after the join, which is the whole reason this is a join
/// and not a union.
pub fn narrowIntersect(self: *FunctionBuilder, other: []const LocalId) void {
    var index = self.narrowed.items.len;
    while (index > 0) {
        index -= 1;
        if (std.mem.indexOfScalar(LocalId, other, self.narrowed.items[index]) == null) {
            _ = self.narrowed.swapRemove(index);
        }
    }
}

pub const RootFact = struct { local: LocalId, state: RootState };

fn sameRoot(left: RootState, right: RootState) bool {
    return switch (left) {
        .mutable => right == .mutable,
        .unknown => right == .unknown,
        .maybe_constant => right == .maybe_constant,
        .constant => |held| right == .constant and held.row == right.constant.row,
    };
}

pub fn joinedRoot(left: RootState, right: RootState) RootState {
    if (sameRoot(left, right)) return left;
    if (left == .constant or left == .maybe_constant or
        right == .constant or right == .maybe_constant)
    {
        return .maybe_constant;
    }
    return .unknown;
}

/// Record the root fact for a local stage 4 just declared.  The
/// declaration driver uses this for parameters: owned/give inputs
/// are mutable, while an ordinary borrow may hide a program root.
pub fn setRoot(self: *FunctionBuilder, local: LocalId, state: RootState) void {
    const info = self.localById(local) orelse return;
    info.root = state;
}

/// Snapshot the root provenance of every visible local.  Branches
/// restore the entry snapshot before lowering their sibling and
/// join exact agreement afterwards, beside optional narrowing's
/// own flow facts.
pub fn rootSave(self: *FunctionBuilder) Error![]RootFact {
    var facts: std.ArrayList(RootFact) = .empty;
    defer facts.deinit(self.temporary());
    for (self.scopes.items) |*scope| {
        var names = scope.names.valueIterator();
        while (names.next()) |info| {
            try facts.append(self.temporary(), .{ .local = info.local, .state = info.root });
        }
    }
    return facts.toOwnedSlice(self.temporary());
}

pub fn rootRestore(self: *FunctionBuilder, saved: []const RootFact) void {
    for (saved) |fact| {
        const info = self.localById(fact.local) orelse continue;
        info.root = fact.state;
    }
}

pub fn rootIntersect(self: *FunctionBuilder, other: []const RootFact) void {
    for (other) |fact| {
        const info = self.localById(fact.local) orelse continue;
        info.root = joinedRoot(info.root, fact.state);
    }
}

pub fn rootCaptureInto(self: *FunctionBuilder, target: []RootFact) void {
    for (target) |*fact| {
        const info = self.localById(fact.local) orelse continue;
        fact.state = info.root;
    }
}

pub fn rootJoinInto(self: *FunctionBuilder, target: []RootFact) void {
    for (target) |*fact| {
        const info = self.localById(fact.local) orelse continue;
        fact.state = joinedRoot(fact.state, info.root);
    }
}

pub fn refuseConstantWrite(
    self: *FunctionBuilder,
    state: RootState,
    span: Span,
    action: []const u8,
) Error!bool {
    return switch (state) {
        .mutable, .unknown => false,
        .constant => |held| blk: {
            try self.fail(
                "luce.sema.const",
                span,
                "{s} is a constant; {s} would write the program [CONSTANTS.md R-D]",
                .{ held.name, action },
            );
            break :blk true;
        },
        .maybe_constant => blk: {
            try self.fail(
                "luce.sema.const",
                span,
                "this value may name a constant; {s} would write the program — use copy before the paths join [CONSTANTS.md R-D]",
                .{action},
            );
            break :blk true;
        },
    };
}

pub fn refuseConstantEscape(
    self: *FunctionBuilder,
    state: RootState,
    span: Span,
    action: []const u8,
) Error!bool {
    return switch (state) {
        .mutable, .unknown => false,
        .constant => |held| blk: {
            try self.fail(
                "luce.sema.const",
                span,
                "{s} is a constant owned by the program; {s} cannot move or retain it — use copy on the value first [CONSTANTS.md R-C, R-D]",
                .{ held.name, action },
            );
            break :blk true;
        },
        .maybe_constant => blk: {
            try self.fail(
                "luce.sema.const",
                span,
                "this value may name a constant owned by the program; {s} cannot move or retain it — use copy before the paths join [CONSTANTS.md R-C, R-D]",
                .{action},
            );
            break :blk true;
        },
    };
}

fn constantState(self: *const FunctionBuilder, index: u32) ?RootState {
    const info = self.analyzer.constant_infos.items[index];
    if (info.state != .ready or info.value != .container) return null;
    return .{ .constant = .{
        .row = info.value.container,
        .name = info.declaration.name,
    } };
}

const WrittenConstant = union(enum) { not_constant, reported, root: RootState };

fn writtenConstantIndex(self: *FunctionBuilder, expression: *const ast.Expression) Error!?u32 {
    switch (expression.*) {
        .name => |name| {
            if (self.findLocal(name.text) != null) return null;
            const qualified = try self.analyzer.qualify(self.prefix, name.text);
            return self.analyzer.constant_names.get(qualified);
        },
        .field => |field| {
            if (field.target.* != .name or self.findLocal(field.target.name.text) != null) return null;
            if (!self.analyzer.importsModule(self.module, field.target.name.text)) return null;
            const joined = try std.fmt.allocPrint(self.temporary(), "{s}.{s}", .{
                field.target.name.text,
                field.name,
            });
            defer self.temporary().free(joined);
            return self.analyzer.constant_names.get(try self.importedName(joined));
        },
        else => return null,
    }
}

pub fn writtenConstant(self: *FunctionBuilder, expression: *const ast.Expression) Error!WrittenConstant {
    const index = (try writtenConstantIndex(self, expression)) orelse return .not_constant;
    switch (expression.*) {
        .field => |field| {
            const info = self.analyzer.constant_infos.items[index];
            if (info.declaration.visibility == .private and info.module != self.module) {
                try self.fail("luce.sema.private", field.span, "{s} is private to {s}", .{
                    field.name,
                    self.analyzer.moduleName(info.module),
                });
                return .reported;
            }
        },
        else => {},
    }
    return if (constantState(self, index)) |root| .{ .root = root } else .not_constant;
}

pub fn constantPlaceRoot(self: *FunctionBuilder, expression: *const ast.Expression) Error!WrittenConstant {
    return switch (expression.*) {
        .index => |index| blk: {
            const written = try writtenConstant(self, index.target);
            break :blk if (written == .not_constant)
                try constantPlaceRoot(self, index.target)
            else
                written;
        },
        .field => |field| try constantPlaceRoot(self, field.target),
        else => try writtenConstant(self, expression),
    };
}

/// What `condition` proves about absence when it evaluates to
/// `want`: `x != none` proves `x` present when true, `x == none`
/// proves it present when false, `and` passes both facts through on
/// the true side, `or` on the false side, and `not` swaps.
/// Anything else proves nothing, which is always safe.
pub fn applyFacts(self: *FunctionBuilder, condition: *const ast.Expression, want: bool, budget: u32) Error!void {
    if (budget == 0) return;
    switch (condition.*) {
        .unary => |unary| if (unary.op == .logic_not) {
            try applyFacts(self, unary.operand, !want, budget - 1);
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
                if (recorder.localType(self, found.info.local) != .optional) return;
                try narrow(self, found.info.local);
            },
            .logic_and => if (want) {
                try applyFacts(self, binary.left, true, budget - 1);
                try applyFacts(self, binary.right, true, budget - 1);
            },
            .logic_or => if (!want) {
                try applyFacts(self, binary.left, false, budget - 1);
                try applyFacts(self, binary.right, false, budget - 1);
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
pub fn widenAssignedIn(self: *FunctionBuilder, block: ast.Block) void {
    for (block.statements) |statement| widenAssignedBy(self, statement);
}

fn expressionMayNameVisibleConstant(
    self: *FunctionBuilder,
    expression: *const ast.Expression,
) Error!bool {
    if (try writtenConstantIndex(self, expression)) |index| {
        return constantState(self, index) != null;
    }
    return switch (expression.*) {
        .name => |name| if (self.findLocal(name.text)) |found|
            found.info.root == .constant or found.info.root == .maybe_constant
        else
            false,
        .binary => |binary| (binary.op == .coalesce and
            (try expressionMayNameVisibleConstant(self, binary.left) or
                try expressionMayNameVisibleConstant(self, binary.right))),
        else => false,
    };
}

fn taintLoopRootsBy(self: *FunctionBuilder, statement: ast.Statement) Error!bool {
    return switch (statement) {
        .assign => |assigned| switch (assigned.target) {
            .name => |name| blk: {
                if (!try expressionMayNameVisibleConstant(self, assigned.value)) break :blk false;
                const found = self.findLocal(name.text) orelse break :blk false;
                if (found.info.root == .constant or found.info.root == .maybe_constant) break :blk false;
                found.info.root = .maybe_constant;
                break :blk true;
            },
            .field, .index, .chain => false,
        },
        .conditional => |conditional| blk: {
            var changed = try taintLoopRootsIn(self, conditional.then_block);
            if (conditional.else_block) |arm| changed = try taintLoopRootsIn(self, arm) or changed;
            break :blk changed;
        },
        .while_loop => |loop| taintLoopRootsIn(self, loop.body),
        .for_range => |loop| taintLoopRootsIn(self, loop.body),
        .for_each => |loop| taintLoopRootsIn(self, loop.body),
        .guarded => |guarded| blk: {
            var changed = try taintLoopRootsBy(self, guarded.attempt.*);
            changed = try taintLoopRootsIn(self, guarded.handler) or changed;
            break :blk changed;
        },
        .match => |matched| blk: {
            var changed = false;
            for (matched.arms) |arm| changed = try taintLoopRootsIn(self, arm.body) or changed;
            if (matched.else_block) |arm| changed = try taintLoopRootsIn(self, arm) or changed;
            break :blk changed;
        },
        .let,
        .variable,
        .destructure,
        .assign_many,
        .return_statement,
        .break_statement,
        .continue_statement,
        .expression,
        => false,
    };
}

fn taintLoopRootsIn(self: *FunctionBuilder, block: ast.Block) Error!bool {
    var changed = false;
    for (block.statements) |statement| changed = try taintLoopRootsBy(self, statement) or changed;
    return changed;
}

pub fn prepareLoopFacts(self: *FunctionBuilder, block: ast.Block) Error!void {
    // Follow visible root aliases to a fixed point before lowering
    // the loop body.  The body can run again: `xs = TABLE` at its
    // end makes an earlier `xs.append(...)` a constant write on the
    // next iteration even when `xs` entered mutable.  This tiny
    // name-flow pass preserves that fact without treating fresh-only
    // loop assignments as constants.
    while (try taintLoopRootsIn(self, block)) {}
    widenAssignedIn(self, block);
}

fn forgetAssignedFacts(self: *FunctionBuilder, local: LocalId) void {
    widen(self, local);
    if (self.localById(local)) |info| {
        info.root = switch (info.root) {
            .constant, .maybe_constant => .maybe_constant,
            .mutable, .unknown => .unknown,
        };
    }
}

fn widenAssignedBy(self: *FunctionBuilder, statement: ast.Statement) void {
    switch (statement) {
        .assign => |assigned| switch (assigned.target) {
            .name => |name| if (self.findLocal(name.text)) |found| forgetAssignedFacts(self, found.info.local),
            .field, .index, .chain => {},
        },
        .assign_many => |assigned| for (assigned.names) |name| {
            if (self.findLocal(name.text)) |found| forgetAssignedFacts(self, found.info.local);
        },
        .conditional => |conditional| {
            widenAssignedIn(self, conditional.then_block);
            if (conditional.else_block) |arm| widenAssignedIn(self, arm);
        },
        .while_loop => |loop| widenAssignedIn(self, loop.body),
        .for_range => |loop| widenAssignedIn(self, loop.body),
        .for_each => |loop| widenAssignedIn(self, loop.body),
        .guarded => |guarded| {
            widenAssignedBy(self, guarded.attempt.*);
            widenAssignedIn(self, guarded.handler);
        },
        .match => |matched| {
            for (matched.arms) |arm| widenAssignedIn(self, arm.body);
            if (matched.else_block) |arm| widenAssignedIn(self, arm);
        },
        else => {},
    }
}
