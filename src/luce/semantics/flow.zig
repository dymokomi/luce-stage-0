//! The one fact this walk carries across a branch, and the facility
//! that saves, restores and joins it: which optional locals are proved
//! present (narrowing).
//!
//! It is a per-local set on the walker, read on the fast path by a
//! linear scan, and it needs exactly three verbs around every branch —
//! save what holds here, restore it for the other arm, intersect the
//! two at the join.
//!
//! Its interface is those verbs plus the facts that feed them: what a
//! condition proves (`applyFacts`) and what a loop body destroys
//! (`prepareLoopFacts`, `widenAssignedBy`).

const std = @import("std");
const ast = @import("../parse.zig").ast;
const mir = @import("../mir.zig");
const context = @import("context.zig");
const Error = context.Error;
const LocalId = mir.LocalId;

const builder = @import("builder.zig");
const recorder = @import("recorder.zig");
const helpers = @import("helpers.zig");
const FunctionBuilder = builder.FunctionBuilder;

/// How deep `applyFacts` walks a condition before it stops proving
/// anything.  It runs over a condition's whole subtree, so the depth
/// bound the checked walk keeps cannot protect it — it needs its own,
/// and proving nothing is always safe.  The margin over the checking
/// bound keeps an accepted program from ever reaching it.
pub const fact_search_depth: u32 = helpers.max_expression_depth + 8;

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
                // Each weak read is a new optional snapshot. Proving one
                // read present says nothing about a later read after code in
                // the arm may have released the final strong owner.
                if (found.info.weak) return;
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

pub fn prepareLoopFacts(self: *FunctionBuilder, block: ast.Block) Error!void {
    widenAssignedIn(self, block);
}

fn widenAssignedBy(self: *FunctionBuilder, statement: ast.Statement) void {
    switch (statement) {
        .assign => |assigned| switch (assigned.target) {
            .name => |name| if (self.findLocal(name.text)) |found| widen(self, found.info.local),
            .field, .index, .chain => {},
        },
        .assign_many => |assigned| for (assigned.names) |name| {
            if (self.findLocal(name.text)) |found| widen(self, found.info.local);
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
