//! What running a piece of source could disturb, asked before it is
//! lowered.
//!
//! One question, in two shapes: could evaluating this expression — or
//! running this block — free something a container or a struct field
//! is holding?  `builder.zig` asks the expression form when it has to
//! decide the order two operands are evaluated in, and the block form
//! when it has to decide whether a loop may keep a borrowed view of a
//! row across its body.
//!
//! **Pure, and about syntax rather than about types.**  Nothing here
//! touches the checker's state, and that is what makes it a file of
//! its own: the answer is a property of the tree, so it can be had
//! before a single operand has been typed.  `optimize/effects.zig`
//! answers the same question one level down, about instructions.

const ast = @import("../parse.zig").ast;
const builtins = @import("builtins.zig");
const helpers = @import("helpers.zig");

/// Could evaluating this expression free something a container or
/// a struct field is holding?
///
/// Conservative, and it can afford to be: Luce has no mutable
/// globals, so the only way an expression reaches a container the
/// surrounding statement is also reading is by being handed one.
/// That means a call to a declaration or any method — a method's
/// receiver is the container in `xs.remove(0)`.  The free builtins
/// move nothing (`optimize/effects.zig` answers the same question
/// about instructions), so `str(i)` and `len(xs)` beside a
/// container read cost nothing.
pub fn mayMutateContainers(expression: *const ast.Expression) bool {
    return mutatesWithin(expression, helpers.max_expression_depth);
}

/// The recursive body, bounded so a pathologically deep expression —
/// one lowering itself refuses as nested past `max_expression_depth`
/// — cannot walk off the native stack here first, before that refusal
/// is reached.  Exhausting the budget answers the conservative `true`:
/// this walk exists to be conservative, an over-deep expression is
/// rejected downstream so the value is moot, and "assume it may" is
/// always the safe guess.
fn mutatesWithin(expression: *const ast.Expression, budget: u32) bool {
    if (budget == 0) return true;
    const left = budget - 1;
    return switch (expression.*) {
        .method => true,
        // A spawn moves every object argument out of this runtime,
        // which is the largest disturbance there is (docs/THREADS.md).
        .spawn => true,
        // A lambda runs nothing where it is written: it becomes a
        // top-level function, and the value here is its name
        // (docs/FUNCTIONS.md D2).
        .lambda => false,
        // Making a closure runs only explicit snapshot expressions. Reading
        // inferred/strong/weak captures and allocating the environment cannot
        // mutate a source container.
        .closure => |written| blk: {
            for (written.captures) |capture| {
                if (capture.value) |value| {
                    if (mutatesWithin(value, left)) break :blk true;
                }
            }
            break :blk false;
        },
        // A match runs its scrutinee and the one arm it chooses; if any
        // of those could mutate, so could the match.
        .match_value => |written| blk: {
            if (mutatesWithin(written.scrutinee, left)) break :blk true;
            for (written.arms) |arm| {
                if (mutatesWithin(arm.value, left)) break :blk true;
            }
            if (written.else_value) |value| {
                if (mutatesWithin(value, left)) break :blk true;
            }
            break :blk false;
        },
        .try_call => true,
        // Nothing is known about what a function value does, so a call
        // through one disturbs everything a declared call could.
        .value_call => true,
        .call => |call| blk: {
            if (!builtins.isPure(call.callee)) break :blk true;
            for (call.arguments) |argument| {
                if (mutatesWithin(argument.value, left)) break :blk true;
            }
            break :blk false;
        },
        .binary => |binary| mutatesWithin(binary.left, left) or
            mutatesWithin(binary.right, left),
        .unary => |unary| mutatesWithin(unary.operand, left),
        .field => |field| mutatesWithin(field.target, left),
        .index => |index| blk: {
            if (mutatesWithin(index.target, left)) break :blk true;
            for (index.indices) |subscript| {
                if (mutatesWithin(subscript, left)) break :blk true;
            }
            break :blk false;
        },
        .slice_range => |slice| blk: {
            if (mutatesWithin(slice.target, left)) break :blk true;
            if (slice.start) |bound| {
                if (mutatesWithin(bound, left)) break :blk true;
            }
            if (slice.end) |bound| {
                if (mutatesWithin(bound, left)) break :blk true;
            }
            break :blk false;
        },
        .list_literal => |literal| blk: {
            for (literal.elements) |element| {
                if (mutatesWithin(element, left)) break :blk true;
            }
            break :blk false;
        },
        .map_literal => |literal| blk: {
            for (literal.entries) |entry| {
                if (mutatesWithin(entry.key, left) or mutatesWithin(entry.value, left)) break :blk true;
            }
            break :blk false;
        },
        .new_object => |new| blk: {
            for (new.arguments) |argument| {
                if (mutatesWithin(argument.value, left)) break :blk true;
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

/// The same question of a whole block: could running it free
/// something a container or a struct field is holding?
pub fn blockMayMutateContainers(block: ast.Block) bool {
    for (block.statements) |statement| {
        if (statementMayMutateContainers(statement)) return true;
    }
    return false;
}

fn anyMutates(expressions: []const *ast.Expression) bool {
    for (expressions) |expression| {
        if (mayMutateContainers(expression)) return true;
    }
    return false;
}

fn blockAnyMutates(arms: []const ast.MatchArm) bool {
    for (arms) |arm| {
        if (blockMayMutateContainers(arm.body)) return true;
    }
    return false;
}

fn statementMayMutateContainers(statement: ast.Statement) bool {
    return switch (statement) {
        // A write through a place is exactly a container or field
        // store, and that frees what it replaced (S22, S25).
        .assign => |assign| assign.target != .name or
            mayMutateContainers(assign.value),
        .assign_many => |assign| mayMutateContainers(assign.value),
        .let => |binding| mayMutateContainers(binding.value),
        .destructure => |bind| mayMutateContainers(bind.value),
        .variable => |binding| binding.value != null and
            mayMutateContainers(binding.value.?),
        .expression => |expression| mayMutateContainers(expression.value),
        .guarded => |guarded| statementMayMutateContainers(guarded.attempt.*) or
            blockMayMutateContainers(guarded.handler),
        .return_statement => |returned| anyMutates(returned.values),
        .conditional => |conditional| mayMutateContainers(conditional.condition) or
            blockMayMutateContainers(conditional.then_block) or
            (conditional.else_block != null and
                blockMayMutateContainers(conditional.else_block.?)),
        .while_loop => |loop| mayMutateContainers(loop.condition) or
            blockMayMutateContainers(loop.body),
        .for_range => |loop| mayMutateContainers(loop.start) or
            mayMutateContainers(loop.end) or
            blockMayMutateContainers(loop.body),
        .for_each => |loop| mayMutateContainers(loop.iterable) or
            blockMayMutateContainers(loop.body),
        .match => |matched| mayMutateContainers(matched.scrutinee) or
            blockAnyMutates(matched.arms) or
            (matched.else_block != null and
                blockMayMutateContainers(matched.else_block.?)),
        .break_statement, .continue_statement, .pass_statement => false,
    };
}
