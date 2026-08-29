//! Class construction bodies.
//!
//! `init` is compiled as a hidden factory, never as a method on a partly
//! alive object. The validator proves that every successful path establishes
//! every stored field and that the not-yet-existing `self` cannot escape.
//! Lowering then keeps one compiler-owned local per field, builds the ARC
//! object whole at each successful return, and lets ordinary scope unwinding
//! clean those locals on every failure path.

const std = @import("std");
const source_mod = @import("../source.zig");
const ast = @import("../parse.zig").ast;
const types = @import("../support/types.zig");
const nodes = @import("../hir.zig").nodes;

const builder = @import("builder.zig");
const context = @import("context.zig");
const defaults = @import("defaults.zig");
const expressions = @import("expressions.zig");
const helpers = @import("helpers.zig");
const ledger = @import("ledger.zig");
const recorder = @import("recorder.zig");
const resolve = @import("resolve.zig");
const shapes = @import("shapes.zig");

const Error = context.Error;
const FunctionBuilder = builder.FunctionBuilder;
const InitializerField = builder.InitializerField;
const Span = source_mod.Span;
const Type = types.Type;

const Flow = struct {
    initialized: []bool,
    falls_through: bool = true,
};

/// Prove the initializer's source-level lifecycle before ordinary expression
/// checking starts. This pass owns only facts unique to construction: which
/// `self.field` values exist and whether the placeholder `self` escapes.
pub fn validate(self: *FunctionBuilder, declaration: *const ast.FuncDecl) Error!void {
    const state = self.initializer orelse unreachable;
    const layout = self.analyzer.structs.items[state.layout];
    for (declaration.parameters) |parameter| {
        try refuseSelfBinding(self, parameter.name, parameter.name_span, "parameter");
    }
    const initialized = try self.temporary().alloc(bool, layout.fields.len);
    defer self.temporary().free(initialized);
    for (initialized, 0..) |*slot, index| {
        slot.* = defaults.fieldHasDefault(self.analyzer, state.layout, index);
    }

    var flow: Flow = .{ .initialized = initialized };
    try validateBlock(self, &flow, declaration.body);
    if (flow.falls_through) try requireComplete(self, flow.initialized, declaration.name_span);
}

fn validateBlock(self: *FunctionBuilder, flow: *Flow, block: ast.Block) Error!void {
    for (block.statements) |statement| {
        if (!flow.falls_through) break;
        try validateStatement(self, flow, statement);
    }
}

fn validateStatement(self: *FunctionBuilder, flow: *Flow, statement: ast.Statement) Error!void {
    switch (statement) {
        .let => |binding| {
            try refuseSelfBinding(self, binding.name, binding.name_span, "local");
            try validateExpression(self, flow.initialized, binding.value);
        },
        .variable => |binding| {
            try refuseSelfBinding(self, binding.name, binding.name_span, "local");
            if (binding.value) |value| try validateExpression(self, flow.initialized, value);
        },
        .destructure => |binding| {
            for (binding.names) |name| try refuseSelfBinding(self, name.text, name.span, "local");
            try validateExpression(self, flow.initialized, binding.value);
        },
        .assign_many => |assignment| {
            for (assignment.names) |name| {
                if (!std.mem.eql(u8, name.text, "self")) continue;
                try self.fail(
                    "luce.sema.class.lifecycle",
                    name.span,
                    "init cannot replace self; assign its stored fields, such as self.name = name",
                    .{},
                );
            }
            try validateExpression(self, flow.initialized, assignment.value);
        },
        .assign => |assignment| try validateAssignment(self, flow, assignment),
        .conditional => |conditional| try validateConditional(self, flow, conditional),
        .while_loop => |loop| {
            try validateExpression(self, flow.initialized, loop.condition);
            var body = try cloneFlow(self, flow.*);
            defer self.temporary().free(body.initialized);
            try validateBlock(self, &body, loop.body);
            // A loop may run zero times, so its stores establish no fact
            // after it. A literal endless loop without a break has no path
            // to the initializer's implicit return.
            if (helpers.exitingStatement(self.divergeView(), statement) != null) flow.falls_through = false;
        },
        .for_range => |loop| {
            try refuseSelfBinding(self, loop.name, loop.span, "loop binding");
            try validateExpression(self, flow.initialized, loop.start);
            try validateExpression(self, flow.initialized, loop.end);
            var body = try cloneFlow(self, flow.*);
            defer self.temporary().free(body.initialized);
            try validateBlock(self, &body, loop.body);
        },
        .for_each => |loop| {
            try refuseSelfBinding(self, loop.name, loop.span, "loop binding");
            if (loop.value_name) |name| try refuseSelfBinding(self, name, loop.span, "loop binding");
            try validateExpression(self, flow.initialized, loop.iterable);
            var body = try cloneFlow(self, flow.*);
            defer self.temporary().free(body.initialized);
            try validateBlock(self, &body, loop.body);
        },
        .return_statement => |returned| {
            for (returned.values) |value| try validateExpression(self, flow.initialized, value);
            if (returned.values.len != 0) {
                try self.fail(
                    "luce.sema.class.lifecycle",
                    returned.span,
                    "init returns the new class implicitly; write bare 'return'",
                    .{},
                );
            } else {
                try requireComplete(self, flow.initialized, returned.span);
            }
            flow.falls_through = false;
        },
        .break_statement, .continue_statement => flow.falls_through = false,
        // A no-op: it neither initializes a field nor leaves the block.
        .pass_statement => {},
        .expression => |written| {
            try validateExpression(self, flow.initialized, written.value);
            if (leavesByCall(self, written.value)) flow.falls_through = false;
        },
        .guarded => |guarded| try validateGuarded(self, flow, guarded),
        .match => |matched| try validateMatch(self, flow, matched),
    }
}

fn validateAssignment(self: *FunctionBuilder, flow: *Flow, assignment: ast.Assign) Error!void {
    switch (assignment.target) {
        .name => |name| {
            if (std.mem.eql(u8, name.text, "self")) {
                try self.fail(
                    "luce.sema.class.lifecycle",
                    name.span,
                    "init cannot replace self; assign its stored fields, such as self.name = name",
                    .{},
                );
            }
            try validateExpression(self, flow.initialized, assignment.value);
        },
        .field => |field| {
            if (!std.mem.eql(u8, field.base, "self")) {
                try validateExpression(self, flow.initialized, assignment.value);
                return;
            }
            const index = initializerFieldIndex(self, field.field) orelse {
                try failUnknownField(self, field.field, field.span);
                try validateExpression(self, flow.initialized, assignment.value);
                return;
            };
            // Compound assignment reads the old value before it writes the
            // new one. A plain assignment establishes the field only after
            // its right side has been checked, so `self.x = self.x` is not a
            // back door around definite initialization.
            if (assignment.compound != null) try requireInitialized(self, flow.initialized, index, field.span);
            try validateExpression(self, flow.initialized, assignment.value);
            flow.initialized[index] = true;
        },
        .index => |index| {
            try validateExpression(self, flow.initialized, index.base);
            for (index.indices) |position| try validateExpression(self, flow.initialized, position);
            try validateExpression(self, flow.initialized, assignment.value);
        },
        .chain => |chain| {
            try validateExpression(self, flow.initialized, chain.place);
            try validateExpression(self, flow.initialized, assignment.value);
        },
    }
}

fn validateConditional(
    self: *FunctionBuilder,
    flow: *Flow,
    conditional: ast.Conditional,
) Error!void {
    try validateExpression(self, flow.initialized, conditional.condition);
    const entry = try self.temporary().dupe(bool, flow.initialized);
    defer self.temporary().free(entry);

    var then_flow: Flow = .{ .initialized = try self.temporary().dupe(bool, entry) };
    defer self.temporary().free(then_flow.initialized);
    try validateBlock(self, &then_flow, conditional.then_block);

    var else_flow: Flow = .{ .initialized = try self.temporary().dupe(bool, entry) };
    defer self.temporary().free(else_flow.initialized);
    if (conditional.else_block) |otherwise| try validateBlock(self, &else_flow, otherwise);
    mergeTwo(flow, then_flow, else_flow);
}

fn validateMatch(self: *FunctionBuilder, flow: *Flow, matched: ast.Match) Error!void {
    try validateExpression(self, flow.initialized, matched.scrutinee);
    const entry = try self.temporary().dupe(bool, flow.initialized);
    defer self.temporary().free(entry);

    var have_continuation = false;
    for (matched.arms) |arm| {
        for (arm.bindings) |name| try refuseSelfBinding(self, name.text, name.span, "match binding");
        var branch: Flow = .{ .initialized = try self.temporary().dupe(bool, entry) };
        defer self.temporary().free(branch.initialized);
        try validateBlock(self, &branch, arm.body);
        if (branch.falls_through) mergeBranch(flow.initialized, &have_continuation, branch.initialized);
    }
    if (matched.else_block) |otherwise| {
        var branch: Flow = .{ .initialized = try self.temporary().dupe(bool, entry) };
        defer self.temporary().free(branch.initialized);
        try validateBlock(self, &branch, otherwise);
        if (branch.falls_through) mergeBranch(flow.initialized, &have_continuation, branch.initialized);
    }
    // A match without else is exhaustive when semantic checking accepts it;
    // its written arms are therefore every path, just as return analysis
    // treats them. On an invalid match another diagnostic already refuses it.
    if (matched.arms.len == 0) {
        @memcpy(flow.initialized, entry);
        flow.falls_through = true;
    } else {
        flow.falls_through = have_continuation;
    }
}

fn validateGuarded(self: *FunctionBuilder, flow: *Flow, guarded: ast.Guarded) Error!void {
    if (guarded.binding) |name| try refuseSelfBinding(self, name.text, name.span, "catch binding");
    const entry = try self.temporary().dupe(bool, flow.initialized);
    defer self.temporary().free(entry);

    var succeeded: Flow = .{ .initialized = try self.temporary().dupe(bool, entry) };
    defer self.temporary().free(succeeded.initialized);
    try validateStatement(self, &succeeded, guarded.attempt.*);

    var handled: Flow = .{ .initialized = try self.temporary().dupe(bool, entry) };
    defer self.temporary().free(handled.initialized);
    try validateBlock(self, &handled, guarded.handler);
    mergeTwo(flow, succeeded, handled);
}

fn cloneFlow(self: *FunctionBuilder, flow: Flow) Error!Flow {
    return .{
        .initialized = try self.temporary().dupe(bool, flow.initialized),
        .falls_through = flow.falls_through,
    };
}

fn mergeTwo(destination: *Flow, left: Flow, right: Flow) void {
    if (!left.falls_through and !right.falls_through) {
        destination.falls_through = false;
        return;
    }
    destination.falls_through = true;
    if (!left.falls_through) {
        @memcpy(destination.initialized, right.initialized);
        return;
    }
    if (!right.falls_through) {
        @memcpy(destination.initialized, left.initialized);
        return;
    }
    for (destination.initialized, left.initialized, right.initialized) |*slot, a, b| slot.* = a and b;
}

fn mergeBranch(destination: []bool, have: *bool, branch: []const bool) void {
    if (!have.*) {
        @memcpy(destination, branch);
        have.* = true;
        return;
    }
    for (destination, branch) |*slot, present| slot.* = slot.* and present;
}

fn validateExpression(self: *FunctionBuilder, initialized: []const bool, expression: *const ast.Expression) Error!void {
    // Ordinary lowering owns the user-facing nesting diagnostic. Bound this
    // initializer-only preflight to the same depth so a flat operator chain
    // cannot overflow the native stack before ordinary lowering gets there.
    if (self.depth >= helpers.max_expression_depth) return;
    self.depth += 1;
    defer self.depth -= 1;

    switch (expression.*) {
        .name => |name| if (std.mem.eql(u8, name.text, "self")) {
            try failEscapingSelf(self, name.span);
        },
        .field => |field| {
            if (isBareSelf(field.target)) {
                const index = initializerFieldIndex(self, field.name) orelse {
                    try failUnknownField(self, field.name, field.span);
                    return;
                };
                try requireInitialized(self, initialized, index, field.span);
                return;
            }
            try validateExpression(self, initialized, field.target);
        },
        .call => |call| {
            if (std.mem.eql(u8, call.callee, "self")) try failEscapingSelf(self, call.span);
            for (call.arguments) |argument| try validateExpression(self, initialized, argument.value);
        },
        .value_call => |call| {
            try validateExpression(self, initialized, call.callee);
            for (call.arguments) |argument| try validateExpression(self, initialized, argument.value);
        },
        .binary => |binary| {
            try validateExpression(self, initialized, binary.left);
            try validateExpression(self, initialized, binary.right);
        },
        .unary => |unary| try validateExpression(self, initialized, unary.operand),
        .new_object => |made| for (made.arguments) |argument| try validateExpression(self, initialized, argument.value),
        .list_literal => |literal| for (literal.elements) |element| try validateExpression(self, initialized, element),
        .map_literal => |literal| for (literal.entries) |entry| {
            try validateExpression(self, initialized, entry.key);
            try validateExpression(self, initialized, entry.value);
        },
        .index => |index| {
            try validateExpression(self, initialized, index.target);
            for (index.indices) |position| try validateExpression(self, initialized, position);
        },
        .slice_range => |slice| {
            try validateExpression(self, initialized, slice.target);
            if (slice.start) |start| try validateExpression(self, initialized, start);
            if (slice.end) |end| try validateExpression(self, initialized, end);
        },
        .method => |method| {
            if (isBareSelf(method.target)) {
                try self.fail(
                    "luce.sema.class.lifecycle",
                    method.span,
                    "init cannot call an instance method before the class exists; initialize fields directly or call a static helper",
                    .{},
                );
            } else {
                try validateExpression(self, initialized, method.target);
            }
            for (method.arguments) |argument| try validateExpression(self, initialized, argument.value);
        },
        .try_call => |attempt| try validateExpression(self, initialized, attempt.operand),
        .spawn => |worker| try validateExpression(self, initialized, worker.call),
        .match_value => |written| {
            try validateExpression(self, initialized, written.scrutinee);
            for (written.arms) |arm| try validateExpression(self, initialized, arm.value);
            if (written.else_value) |value| try validateExpression(self, initialized, value);
        },
        .lambda => |lambda| {
            var captures_self = expressionContainsSelf(lambda.body);
            for (lambda.parameters) |parameter| {
                captures_self = captures_self or std.mem.eql(u8, parameter.text, "self");
            }
            if (captures_self) {
                try self.fail(
                    "luce.sema.class.lifecycle",
                    lambda.span,
                    "init cannot capture or shadow self in a lambda; the class does not exist until initialization finishes",
                    .{},
                );
            }
        },
        .closure => |closure| {
            var captures_self = blockContainsSelf(closure.body);
            for (closure.captures) |capture| {
                captures_self = captures_self or std.mem.eql(u8, capture.name.text, "self");
                if (capture.value) |value| {
                    const value_uses_self = expressionContainsSelf(value);
                    captures_self = captures_self or value_uses_self;
                    if (!value_uses_self) try validateExpression(self, initialized, value);
                }
            }
            if (captures_self) {
                try self.fail(
                    "luce.sema.class.lifecycle",
                    closure.span,
                    "init cannot capture self in a closure; the class does not exist until initialization finishes",
                    .{},
                );
            }
        },
        .int_literal,
        .float_literal,
        .bool_literal,
        .char_literal,
        .string_literal,
        .none_literal,
        => {},
    }
}

/// Scan only trees which have first been proven safe to recurse through.
/// Closure bodies get fresh expression budgets during ordinary lowering, so
/// their statement walker applies this guard independently to each expression.
fn expressionContainsSelf(expression: *const ast.Expression) bool {
    if (helpers.deeperThan(expression, helpers.max_expression_depth)) return false;
    return containsSelf(expression);
}

fn containsSelf(expression: *const ast.Expression) bool {
    return switch (expression.*) {
        .name => |name| std.mem.eql(u8, name.text, "self"),
        .field => |field| containsSelf(field.target),
        .call => |call| std.mem.eql(u8, call.callee, "self") or anyArgumentContainsSelf(call.arguments),
        .value_call => |call| containsSelf(call.callee) or anyArgumentContainsSelf(call.arguments),
        .binary => |binary| containsSelf(binary.left) or containsSelf(binary.right),
        .unary => |unary| containsSelf(unary.operand),
        .new_object => |made| anyArgumentContainsSelf(made.arguments),
        .list_literal => |literal| anyExpressionContainsSelf(literal.elements),
        .map_literal => |literal| blk: {
            for (literal.entries) |entry| {
                if (containsSelf(entry.key) or containsSelf(entry.value)) break :blk true;
            }
            break :blk false;
        },
        .index => |index| containsSelf(index.target) or anyExpressionContainsSelf(index.indices),
        .slice_range => |slice| containsSelf(slice.target) or
            (slice.start != null and containsSelf(slice.start.?)) or
            (slice.end != null and containsSelf(slice.end.?)),
        .method => |method| containsSelf(method.target) or anyArgumentContainsSelf(method.arguments),
        .try_call => |attempt| containsSelf(attempt.operand),
        .spawn => |worker| containsSelf(worker.call),
        .lambda => |lambda| containsSelf(lambda.body),
        .closure => |closure| closureContainsSelf(closure),
        .match_value => |written| blk: {
            if (containsSelf(written.scrutinee)) break :blk true;
            for (written.arms) |arm| {
                if (containsSelf(arm.value)) break :blk true;
            }
            break :blk if (written.else_value) |value| containsSelf(value) else false;
        },
        .int_literal,
        .float_literal,
        .bool_literal,
        .char_literal,
        .string_literal,
        .none_literal,
        => false,
    };
}

fn blockContainsSelf(block: ast.Block) bool {
    for (block.statements) |statement| {
        if (statementContainsSelf(statement)) return true;
    }
    return false;
}

fn closureContainsSelf(closure: ast.Closure) bool {
    if (blockContainsSelf(closure.body)) return true;
    for (closure.captures) |capture| {
        if (std.mem.eql(u8, capture.name.text, "self")) return true;
        if (capture.value) |value| if (expressionContainsSelf(value)) return true;
    }
    return false;
}

fn statementContainsSelf(statement: ast.Statement) bool {
    return switch (statement) {
        .let => |binding| std.mem.eql(u8, binding.name, "self") or expressionContainsSelf(binding.value),
        .variable => |binding| std.mem.eql(u8, binding.name, "self") or
            (binding.value != null and expressionContainsSelf(binding.value.?)),
        .destructure => |binding| anyNameIsSelf(binding.names) or expressionContainsSelf(binding.value),
        .assign_many => |assignment| anyNameIsSelf(assignment.names) or expressionContainsSelf(assignment.value),
        .assign => |assignment| targetContainsSelf(assignment.target) or expressionContainsSelf(assignment.value),
        .conditional => |conditional| expressionContainsSelf(conditional.condition) or
            blockContainsSelf(conditional.then_block) or
            (conditional.else_block != null and blockContainsSelf(conditional.else_block.?)),
        .while_loop => |loop| expressionContainsSelf(loop.condition) or blockContainsSelf(loop.body),
        .for_range => |loop| std.mem.eql(u8, loop.name, "self") or
            expressionContainsSelf(loop.start) or expressionContainsSelf(loop.end) or blockContainsSelf(loop.body),
        .for_each => |loop| std.mem.eql(u8, loop.name, "self") or
            (loop.value_name != null and std.mem.eql(u8, loop.value_name.?, "self")) or
            expressionContainsSelf(loop.iterable) or blockContainsSelf(loop.body),
        .return_statement => |returned| anyExpressionContainsSelf(returned.values),
        .expression => |written| expressionContainsSelf(written.value),
        .guarded => |guarded| (guarded.binding != null and std.mem.eql(u8, guarded.binding.?.text, "self")) or
            statementContainsSelf(guarded.attempt.*) or blockContainsSelf(guarded.handler),
        .match => |matched| blk: {
            if (expressionContainsSelf(matched.scrutinee)) break :blk true;
            for (matched.arms) |arm| {
                if (anyNameIsSelf(arm.bindings) or blockContainsSelf(arm.body)) break :blk true;
            }
            break :blk matched.else_block != null and blockContainsSelf(matched.else_block.?);
        },
        .break_statement, .continue_statement, .pass_statement => false,
    };
}

fn anyNameIsSelf(names: []const ast.Name) bool {
    for (names) |name| if (std.mem.eql(u8, name.text, "self")) return true;
    return false;
}

fn targetContainsSelf(target: ast.Target) bool {
    return switch (target) {
        .name => |name| std.mem.eql(u8, name.text, "self"),
        .field => |field| std.mem.eql(u8, field.base, "self"),
        .index => |index| expressionContainsSelf(index.base) or anyExpressionContainsSelf(index.indices),
        .chain => |chain| expressionContainsSelf(chain.place),
    };
}

fn anyExpressionContainsSelf(expressions_to_scan: []const *ast.Expression) bool {
    for (expressions_to_scan) |expression| if (expressionContainsSelf(expression)) return true;
    return false;
}

fn anyArgumentContainsSelf(arguments: []const ast.Argument) bool {
    for (arguments) |argument| if (expressionContainsSelf(argument.value)) return true;
    return false;
}

fn isBareSelf(expression: *const ast.Expression) bool {
    return expression.* == .name and std.mem.eql(u8, expression.name.text, "self");
}

/// Does this expression statement leave the block it sits in — a
/// diverging builtin, or a bare call to a `-> never` function?  The
/// initializer flow pass runs before the body is lowered, so it cannot
/// read the builder's recorded set; a bare name resolves through the
/// already-collected function table instead.  A `self.method()` that
/// diverges is not read here, which only ever asks a field for one more
/// explicit assignment — never accepts an uninitialized one.
fn leavesByCall(self: *const FunctionBuilder, expression: *const ast.Expression) bool {
    if (expression.* != .call) return false;
    const name = expression.call.callee;
    if (std.mem.eql(u8, name, "error") or
        std.mem.eql(u8, name, "trap") or
        std.mem.eql(u8, name, "exit")) return true;
    const index = self.analyzer.function_names.get(name) orelse return false;
    return self.analyzer.functions.items[index].diverges;
}

fn initializerFieldIndex(self: *const FunctionBuilder, name: []const u8) ?u32 {
    const state = self.initializer orelse return null;
    return self.analyzer.structs.items[state.layout].findField(name);
}

fn requireInitialized(self: *FunctionBuilder, initialized: []const bool, index: u32, span: Span) Error!void {
    if (index < initialized.len and initialized[index]) return;
    const state = self.initializer orelse unreachable;
    const field = self.analyzer.structs.items[state.layout].fields[index];
    try self.fail(
        "luce.sema.class.init",
        span,
        "self.{s} is read before init has assigned it",
        .{field.name},
    );
}

fn requireComplete(self: *FunctionBuilder, initialized: []const bool, span: Span) Error!void {
    var missing: usize = 0;
    for (initialized) |present| if (!present) {
        missing += 1;
    };
    if (missing == 0) return;
    const state = self.initializer orelse unreachable;
    const layout = self.analyzer.structs.items[state.layout];
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(self.temporary());
    try context.writeMissingFields(&names, self.temporary(), layout, initialized);
    try self.fail(
        "luce.sema.class.init",
        span,
        "init reaches a successful return without initializing {s}",
        .{names.items},
    );
}

fn failUnknownField(self: *FunctionBuilder, name: []const u8, span: Span) Error!void {
    const state = self.initializer orelse unreachable;
    const layout = self.analyzer.structs.items[state.layout];
    try self.fail(
        "luce.sema.class.init",
        span,
        "{s} has no stored field {s}",
        .{ layout.name, name },
    );
}

fn failEscapingSelf(self: *FunctionBuilder, span: Span) Error!void {
    try self.fail(
        "luce.sema.class.lifecycle",
        span,
        "init may use self only to read or assign a stored field; the class does not exist until initialization finishes",
        .{},
    );
}

fn refuseSelfBinding(self: *FunctionBuilder, name: []const u8, span: Span, role: []const u8) Error!void {
    if (!std.mem.eql(u8, name, "self")) return;
    try self.fail(
        "luce.sema.class.lifecycle",
        span,
        "self names the class being initialized and cannot be used as a {s}",
        .{role},
    );
}

/// Open the hidden field slots at the beginning of the initializer's outer
/// body scope, then materialize declared field defaults into those slots.
pub fn lowerPrelude(self: *FunctionBuilder, span: Span) Error!void {
    const current = self.initializer orelse unreachable;
    if (current.prelude_done) return;
    const layout = self.analyzer.structs.items[current.layout];
    const fields = try self.arena().alloc(InitializerField, layout.fields.len);

    for (layout.fields, fields) |declared, *field| {
        // Every ordinary type has a safe zero. Function values and structs
        // which contain one do not; wrap those in an internal optional so
        // failure cleanup still has a valid value to release.
        const needs_optional = declared.field_type != .optional and
            try shapes.carries(self.analyzer, declared.field_type, .function);
        const storage_type = if (needs_optional)
            Type.optionalOf(declared.field_type).?
        else
            declared.field_type;
        const local_name = try std.fmt.allocPrint(self.arena(), "$init.{s}", .{declared.name});
        const local = (try self.declareLocal(local_name, storage_type, true, span)) orelse continue;
        field.* = .{
            .name = declared.name,
            .local_name = local_name,
            .local = local,
            .value_type = declared.field_type,
            .storage_type = storage_type,
        };
        const store: nodes.StoreKind = if (!shapes.ownsStorage(self.analyzer, storage_type))
            .plain
        else switch (storage_type) {
            .strukt, .variant => .take,
            else => .copy,
        };
        try recorder.recordStatement(self, .{ .declare = .{
            .local = local,
            .value = null,
            .store = store,
            .span = span,
        } });
    }
    self.initializer.?.fields = fields;
    self.initializer.?.prelude_done = true;

    for (fields, 0..) |field, index| {
        if (!defaults.fieldHasDefault(self.analyzer, current.layout, index)) continue;
        const folded = (try defaults.fieldDefault(self.analyzer, current.layout, index)) orelse continue;
        var value = try expressions.emitConstantValue(self, folded.value, folded.value_type, span);
        if (!value.value_type.eql(field.storage_type)) {
            value = (try self.fit(value, field.storage_type)) orelse continue;
        }
        try recorder.recordStatement(self, .{ .assign = .{
            .place = .{ .local = field.local },
            .value = value.node,
            .store = ledger.storeOwnedKind(self, field.local, value),
            .span = span,
        } });
    }
}

/// Materialize the finished class from the hidden field locals and return it.
/// Called for a written bare `return` and for the implicit return at the end
/// of the body.
pub fn lowerReturn(self: *FunctionBuilder, span: Span) Error!void {
    const state = self.initializer orelse unreachable;
    const entries = try self.arena().alloc(recorder.RecordedOperand, state.fields.len);
    for (state.fields, entries, 0..) |field, *entry, index| {
        const value: builder.Typed = if (field.storage_type.eql(field.value_type)) .{
            .node = try recorder.recordNode(self, .{ .local_get = .{
                .local = field.local,
                .result = field.value_type,
                .span = span,
            } }),
            .value_type = field.value_type,
        } else .{
            .node = try recorder.recordNode(self, .{ .narrowed_get = .{
                .local = field.local,
                .payload = field.value_type,
                .result = field.value_type,
                .span = span,
            } }),
            .value_type = field.value_type,
        };
        ledger.ownedForStore(self, value);
        entry.* = .{ .node = value.node, .slot = @intCast(index) };
    }
    const result_type = try resolve.nominalType(self.analyzer, state.layout);
    const value: builder.Typed = .{
        .node = try recorder.recordNode(self, .{ .struct_make = .{
            .layout = state.layout,
            .operands = try recorder.recordOperandBatch(self, entries, entries.len),
            .result = result_type,
            .span = span,
        } }),
        .value_type = result_type,
    };
    const values = try self.arena().alloc(nodes.NodeRef, 1);
    values[0] = value.node;
    const stores = try self.arena().alloc(nodes.StoreKind, 1);
    stores[0] = ledger.ownedForStoreKind(self, value);
    try recorder.recordStatement(self, .{ .return_ = .{
        .values = values,
        .stores = stores,
        .span = span,
    } });
}
