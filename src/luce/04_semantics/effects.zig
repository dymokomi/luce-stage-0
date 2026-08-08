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
//! before a single operand has been typed.  `07_optimize/effects.zig`
//! answers the same question one level down, about instructions.

const ast = @import("../03_parse.zig").ast;
const builtins = @import("builtins.zig");

/// Could evaluating this expression free something a container or
/// a struct field is holding?
///
/// Conservative, and it can afford to be: Luce has no mutable
/// globals, so the only way an expression reaches a container the
/// surrounding statement is also reading is by being handed one.
/// That means a call to a declaration or any method — a method's
/// receiver is the container in `xs.remove(0)`.  Every builtin but
/// `free` moves no ownership at all (`07_optimize/effects.zig`
/// answers the same question about instructions), so `string(i)` and
/// `len(xs)` beside a container read cost nothing.
pub fn mayMutateContainers(expression: *const ast.Expression) bool {
    return switch (expression.*) {
        .method => true,
        .give, .copy => true,
        // A spawn moves every object argument out of this runtime,
        // which is the largest disturbance there is (docs/THREADS.md).
        .spawn => true,
        // A lambda runs nothing where it is written: it becomes a
        // top-level function, and the value here is its name
        // (docs/FUNCTIONS.md D2).
        .lambda => false,
        .try_call => true,
        .call => |call| blk: {
            if (!builtins.isPure(call.callee)) break :blk true;
            for (call.arguments) |argument| {
                if (mayMutateContainers(argument.value)) break :blk true;
            }
            break :blk false;
        },
        .binary => |binary| mayMutateContainers(binary.left) or
            mayMutateContainers(binary.right),
        .unary => |unary| mayMutateContainers(unary.operand),
        .field => |field| mayMutateContainers(field.target),
        .index => |index| blk: {
            if (mayMutateContainers(index.target)) break :blk true;
            for (index.indices) |subscript| {
                if (mayMutateContainers(subscript)) break :blk true;
            }
            break :blk false;
        },
        .slice_range => |slice| blk: {
            if (mayMutateContainers(slice.target)) break :blk true;
            if (slice.start) |bound| {
                if (mayMutateContainers(bound)) break :blk true;
            }
            if (slice.end) |bound| {
                if (mayMutateContainers(bound)) break :blk true;
            }
            break :blk false;
        },
        .list_literal => |literal| blk: {
            for (literal.elements) |element| {
                if (mayMutateContainers(element)) break :blk true;
            }
            break :blk false;
        },
        .new_object => |new| blk: {
            for (new.dims) |dimension| {
                if (mayMutateContainers(dimension)) break :blk true;
            }
            break :blk false;
        },
        .name,
        .int_literal,
        .float_literal,
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
        .break_statement, .continue_statement => false,
    };
}
