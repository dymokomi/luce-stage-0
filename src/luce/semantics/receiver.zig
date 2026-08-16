//! Does this method write its receiver?
//!
//! The one receiver fact source no longer spells (docs/SELF.md D3):
//! a method is a writer if its body assigns `self`, or calls a method
//! of its own type that is one.  Everything
//! below is that walk — statement by statement and expression by
//! expression over the *untyped* tree, because it runs before any
//! body is checked and its answer is part of the signature the check
//! will use.
//!
//! It is a fixed point rather than one pass, because a read-looking
//! wrapper may call a writer declared later and recursion must not
//! make the answer depend on declaration order.  The value/object
//! line (D6) lives in exactly two places here, and they are the
//! reason the walk is not a one-line "does `self` appear": mutating
//! something reached *through* `self` is an ordinary borrow, and
//! evaluating a store's place can call a writer even when the store
//! itself is into an object's contents.
//!
//! Free functions over `declarations.zig`'s `*Analyzer`; `pub` means
//! visible to stage 4's own files, nothing wider.

const std = @import("std");
const ast = @import("../parse.zig").ast;

const context = @import("context.zig");
const Error = context.Error;
const FunctionDeclInfo = context.FunctionDeclInfo;
const Analyzer = @import("declarations.zig").Analyzer;

/// Infer the one receiver fact source no longer spells: whether a
/// method writes its implicit `self` (docs/SELF.md D3).
///
/// The walk is a fixed point because a read-looking wrapper may
/// call a writer declared later, and recursion must not make the
/// answer depend on declaration order.  Only `self.m()` propagates
/// a value-receiver write.  `self.items.append()` mutates the
/// borrowed object's contents and deliberately does not: the
/// value/object line is unchanged (D6).
pub fn inferReceiverWrites(self: *Analyzer) Error!void {
    var changed = true;
    while (changed) {
        changed = false;
        for (self.functions.items) |*info| {
            if (info.receiver != .reads) continue;
            // A class method never replaces the caller's reference. Field
            // assignment mutates the shared instance through that reference,
            // so it remains a read receiver and is callable through `let`.
            if (info.enclosing != null and info.enclosing.? == .class) continue;
            if (!blockWritesReceiver(self, info, info.declaration.body)) continue;
            info.receiver = .writes;
            changed = true;
        }
    }
}

fn blockWritesReceiver(
    self: *const Analyzer,
    info: *const FunctionDeclInfo,
    block: ast.Block,
) bool {
    for (block.statements) |statement| {
        if (statementWritesReceiver(self, info, statement)) return true;
    }
    return false;
}

fn statementWritesReceiver(
    self: *const Analyzer,
    info: *const FunctionDeclInfo,
    statement: ast.Statement,
) bool {
    return switch (statement) {
        .assign => |assign| selfTarget(assign.target) or
            targetEvaluationWritesReceiver(self, info, assign.target) or
            expressionWritesReceiver(self, info, assign.value),
        .assign_many => |assign| blk: {
            for (assign.names) |name| {
                if (std.mem.eql(u8, name.text, "self")) break :blk true;
            }
            break :blk expressionWritesReceiver(self, info, assign.value);
        },
        .let => |binding| expressionWritesReceiver(self, info, binding.value),
        .variable => |binding| binding.value != null and
            expressionWritesReceiver(self, info, binding.value.?),
        .destructure => |binding| expressionWritesReceiver(self, info, binding.value),
        .expression => |written| expressionWritesReceiver(self, info, written.value),
        .return_statement => |returned| blk: {
            for (returned.values) |value| {
                if (expressionWritesReceiver(self, info, value)) break :blk true;
            }
            break :blk false;
        },
        .conditional => |conditional| expressionWritesReceiver(self, info, conditional.condition) or
            blockWritesReceiver(self, info, conditional.then_block) or
            (conditional.else_block != null and
                blockWritesReceiver(self, info, conditional.else_block.?)),
        .while_loop => |loop| expressionWritesReceiver(self, info, loop.condition) or
            blockWritesReceiver(self, info, loop.body),
        .for_range => |loop| expressionWritesReceiver(self, info, loop.start) or
            expressionWritesReceiver(self, info, loop.end) or
            blockWritesReceiver(self, info, loop.body),
        .for_each => |loop| expressionWritesReceiver(self, info, loop.iterable) or
            blockWritesReceiver(self, info, loop.body),
        .guarded => |guarded| statementWritesReceiver(self, info, guarded.attempt.*) or
            blockWritesReceiver(self, info, guarded.handler),
        .match => |matched| blk: {
            if (expressionWritesReceiver(self, info, matched.scrutinee)) break :blk true;
            for (matched.arms) |arm| {
                if (blockWritesReceiver(self, info, arm.body)) break :blk true;
            }
            break :blk matched.else_block != null and
                blockWritesReceiver(self, info, matched.else_block.?);
        },
        .break_statement, .continue_statement => false,
    };
}

fn expressionWritesReceiver(
    self: *const Analyzer,
    info: *const FunctionDeclInfo,
    expression: *const ast.Expression,
) bool {
    return switch (expression.*) {
        .method => |method| blk: {
            if (method.target.* == .name and
                std.mem.eql(u8, method.target.name.text, "self") and
                memberWritesReceiver(self, info, method.name))
            {
                break :blk true;
            }
            if (expressionWritesReceiver(self, info, method.target)) break :blk true;
            for (method.arguments) |argument| {
                if (expressionWritesReceiver(self, info, argument.value)) break :blk true;
            }
            break :blk false;
        },
        .call => |call| blk: {
            for (call.arguments) |argument| {
                if (expressionWritesReceiver(self, info, argument.value)) break :blk true;
            }
            break :blk false;
        },
        // A call through a function value cannot write this frame's
        // receiver: a function value's parameters are its own, and the
        // receiver it may carry is a value of its own (BINDING.md D9
        // refuses binding a writing method).  What it is *handed* still
        // counts, exactly as a declared call's arguments do.
        .value_call => |written| blk: {
            if (expressionWritesReceiver(self, info, written.callee)) break :blk true;
            for (written.arguments) |argument| {
                if (expressionWritesReceiver(self, info, argument.value)) break :blk true;
            }
            break :blk false;
        },
        .binary => |binary| expressionWritesReceiver(self, info, binary.left) or
            expressionWritesReceiver(self, info, binary.right),
        .unary => |unary| expressionWritesReceiver(self, info, unary.operand),
        .field => |field| expressionWritesReceiver(self, info, field.target),
        .index => |index| blk: {
            if (expressionWritesReceiver(self, info, index.target)) break :blk true;
            for (index.indices) |subscript| {
                if (expressionWritesReceiver(self, info, subscript)) break :blk true;
            }
            break :blk false;
        },
        .slice_range => |slice| expressionWritesReceiver(self, info, slice.target) or
            (slice.start != null and expressionWritesReceiver(self, info, slice.start.?)) or
            (slice.end != null and expressionWritesReceiver(self, info, slice.end.?)),
        .list_literal => |literal| blk: {
            for (literal.elements) |element| {
                if (expressionWritesReceiver(self, info, element)) break :blk true;
            }
            break :blk false;
        },
        .map_literal => |literal| blk: {
            for (literal.entries) |entry| {
                if (expressionWritesReceiver(self, info, entry.key) or
                    expressionWritesReceiver(self, info, entry.value)) break :blk true;
            }
            break :blk false;
        },
        .new_object => |new| blk: {
            for (new.dims) |dimension| {
                if (expressionWritesReceiver(self, info, dimension)) break :blk true;
            }
            break :blk false;
        },
        .try_call => |attempt| expressionWritesReceiver(self, info, attempt.operand),
        .spawn => |spawn| expressionWritesReceiver(self, info, spawn.call),
        // A lambda cannot carry self.  Its body is checked in its
        // synthesized function and must not change the enclosing
        // method's receiver classification.
        .lambda => false,
        // A closure body runs later and owns its own receiver classification.
        // Only explicit snapshot expressions run while this method does.
        .closure => |written| blk: {
            for (written.captures) |capture| {
                if (capture.value) |value| {
                    if (expressionWritesReceiver(self, info, value)) break :blk true;
                }
            }
            break :blk false;
        },
        .name,
        .int_literal,
        .float_literal,
        .char_literal,
        .string_literal,
        .bool_literal,
        .none_literal,
        => false,
    };
}

fn memberWritesReceiver(
    self: *const Analyzer,
    caller: *const FunctionDeclInfo,
    name: []const u8,
) bool {
    const owner = caller.enclosing orelse return false;
    for (self.functions.items) |candidate| {
        if (candidate.receiver != .writes) continue;
        const candidate_owner = candidate.enclosing orelse continue;
        if (!candidate_owner.asType().eql(owner.asType())) continue;
        if (candidate.module != caller.module) continue;
        if (std.mem.eql(u8, candidate.declaration.name, name)) return true;
    }
    return false;
}

fn selfTarget(target: ast.Target) bool {
    return switch (target) {
        .name => |name| std.mem.eql(u8, name.text, "self"),
        .field => |field| std.mem.eql(u8, field.base, "self"),
        .chain => |chain| expressionRootIsSelf(chain.place),
        // Index assignment mutates an object's contents, not the
        // value holding that reference (SELF D6).
        .index => false,
    };
}

/// A store's place is evaluated before it is written.  That
/// evaluation can itself call a writing method —
/// `items[self.bump()] = value` — even when the eventual store is
/// into an object's contents and is therefore not a self-value
/// write.  Keep that question separate from `selfTarget` so D6's
/// value/object line stays visible.
fn targetEvaluationWritesReceiver(
    self: *const Analyzer,
    info: *const FunctionDeclInfo,
    target: ast.Target,
) bool {
    return switch (target) {
        .name, .field => false,
        .index => |index| blk: {
            if (expressionWritesReceiver(self, info, index.base)) break :blk true;
            for (index.indices) |subscript| {
                if (expressionWritesReceiver(self, info, subscript)) break :blk true;
            }
            break :blk false;
        },
        .chain => |chain| expressionWritesReceiver(self, info, chain.place),
    };
}

fn expressionRootIsSelf(expression: *const ast.Expression) bool {
    return switch (expression.*) {
        .name => |name| std.mem.eql(u8, name.text, "self"),
        .field => |field| expressionRootIsSelf(field.target),
        else => false,
    };
}
