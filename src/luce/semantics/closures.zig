//! Block closures and the ARC environments they carry.
//!
//! The runtime already has one ownership model: classes are ARC objects and a
//! function value may own one receiver. A closure therefore adds no second
//! heap or tracing rule. Stage 4 writes a private class for its environment,
//! binds that object as the function value's receiver, and writes a private
//! class cell for each captured mutable. The outer local stays an ordinary
//! local (so flow narrowing remains cheap); replacing stores mirror into the
//! cell, and every closure reads/writes that same cell.

const std = @import("std");
const ast = @import("../parse.zig").ast;
const types = @import("../support/types.zig");
const nodes = @import("../hir.zig").nodes;
const context = @import("context.zig");
const Error = context.Error;
const Type = types.Type;
const Span = @import("../source.zig").Span;
const LocalId = @import("../mir.zig").LocalId;

const builder_mod = @import("builder.zig");
const FunctionBuilder = builder_mod.FunctionBuilder;
const Typed = builder_mod.Typed;
const Analyzer = @import("declarations.zig").Analyzer;
const flow = @import("flow.zig");
const ledger = @import("ledger.zig");
const naming = @import("naming.zig");
const recorder = @import("recorder.zig");
const resolve = @import("resolve.zig");
const shapes = @import("shapes.zig");
const signatures = @import("signatures.zig");

// -- Before the body walk -------------------------------------------------

/// Find mutable declarations that may be reached from a block closure before
/// lowering any statement. Their cells must be created at declaration, not at
/// the closure literal: a literal may sit in one branch or run repeatedly in a
/// loop, while every path after the declaration must still name one cell.
pub fn prepareFunction(self: *FunctionBuilder, body: ast.Block) Error!void {
    var mutable: std.StringHashMapUnmanaged(void) = .empty;
    defer mutable.deinit(self.temporary());
    try collectMutableBlock(self, body, &mutable);
    try scanBlockForClosures(self, body, &mutable, false);
}

fn collectMutableBlock(
    self: *FunctionBuilder,
    block: ast.Block,
    mutable: *std.StringHashMapUnmanaged(void),
) Error!void {
    for (block.statements) |statement| try collectMutableStatement(self, statement, mutable);
}

fn collectMutableStatement(
    self: *FunctionBuilder,
    statement: ast.Statement,
    mutable: *std.StringHashMapUnmanaged(void),
) Error!void {
    switch (statement) {
        .variable => |declared| try mutable.put(self.temporary(), declared.name, {}),
        .destructure => |declared| if (declared.mutable) {
            for (declared.names) |name| try mutable.put(self.temporary(), name.text, {});
        },
        .conditional => |conditional| {
            try collectMutableBlock(self, conditional.then_block, mutable);
            if (conditional.else_block) |otherwise| try collectMutableBlock(self, otherwise, mutable);
        },
        .while_loop => |loop| try collectMutableBlock(self, loop.body, mutable),
        .for_range => |loop| try collectMutableBlock(self, loop.body, mutable),
        .for_each => |loop| try collectMutableBlock(self, loop.body, mutable),
        .guarded => |guarded| {
            try collectMutableStatement(self, guarded.attempt.*, mutable);
            try collectMutableBlock(self, guarded.handler, mutable);
        },
        .match => |matched| {
            for (matched.arms) |arm| try collectMutableBlock(self, arm.body, mutable);
            if (matched.else_block) |otherwise| try collectMutableBlock(self, otherwise, mutable);
        },
        else => {},
    }
}

fn markMutable(
    self: *FunctionBuilder,
    mutable: *const std.StringHashMapUnmanaged(void),
    name: []const u8,
) Error!void {
    if (mutable.contains(name)) try self.captured_mutables.put(self.temporary(), name, {});
}

/// Walk ordinary source looking for closure literals. Once inside one, every
/// lexical name is a conservative candidate; `lower` performs the exact
/// lexical collection. False positives here only allocate a cell for an
/// otherwise ordinary `var`, never change its meaning.
fn scanBlockForClosures(
    self: *FunctionBuilder,
    block: ast.Block,
    mutable: *const std.StringHashMapUnmanaged(void),
    inside: bool,
) Error!void {
    for (block.statements) |statement| try scanStatement(self, statement, mutable, inside);
}

fn scanStatement(
    self: *FunctionBuilder,
    statement: ast.Statement,
    mutable: *const std.StringHashMapUnmanaged(void),
    inside: bool,
) Error!void {
    switch (statement) {
        .let => |declared| try scanExpression(self, declared.value, mutable, inside),
        .variable => |declared| if (declared.value) |value| try scanExpression(self, value, mutable, inside),
        .destructure => |declared| try scanExpression(self, declared.value, mutable, inside),
        .assign => |assign| {
            try scanTarget(self, assign.target, mutable, inside);
            try scanExpression(self, assign.value, mutable, inside);
        },
        .assign_many => |assign| {
            if (inside) for (assign.names) |name| try markMutable(self, mutable, name.text);
            try scanExpression(self, assign.value, mutable, inside);
        },
        .conditional => |conditional| {
            try scanExpression(self, conditional.condition, mutable, inside);
            try scanBlockForClosures(self, conditional.then_block, mutable, inside);
            if (conditional.else_block) |otherwise| try scanBlockForClosures(self, otherwise, mutable, inside);
        },
        .while_loop => |loop| {
            try scanExpression(self, loop.condition, mutable, inside);
            try scanBlockForClosures(self, loop.body, mutable, inside);
        },
        .for_range => |loop| {
            try scanExpression(self, loop.start, mutable, inside);
            try scanExpression(self, loop.end, mutable, inside);
            try scanBlockForClosures(self, loop.body, mutable, inside);
        },
        .for_each => |loop| {
            try scanExpression(self, loop.iterable, mutable, inside);
            try scanBlockForClosures(self, loop.body, mutable, inside);
        },
        .return_statement => |returned| for (returned.values) |value| try scanExpression(self, value, mutable, inside),
        .expression => |written| try scanExpression(self, written.value, mutable, inside),
        .guarded => |guarded| {
            try scanStatement(self, guarded.attempt.*, mutable, inside);
            try scanBlockForClosures(self, guarded.handler, mutable, inside);
        },
        .match => |matched| {
            try scanExpression(self, matched.scrutinee, mutable, inside);
            for (matched.arms) |arm| try scanBlockForClosures(self, arm.body, mutable, inside);
            if (matched.else_block) |otherwise| try scanBlockForClosures(self, otherwise, mutable, inside);
        },
        .break_statement, .continue_statement => {},
    }
}

fn scanTarget(
    self: *FunctionBuilder,
    target: ast.Target,
    mutable: *const std.StringHashMapUnmanaged(void),
    inside: bool,
) Error!void {
    switch (target) {
        .name => |name| if (inside) try markMutable(self, mutable, name.text),
        .field => |field| if (inside) try markMutable(self, mutable, field.base),
        .index => |index| {
            try scanExpression(self, index.base, mutable, inside);
            for (index.indices) |position| try scanExpression(self, position, mutable, inside);
        },
        .chain => |chain| try scanExpression(self, chain.place, mutable, inside),
    }
}

fn scanExpression(
    self: *FunctionBuilder,
    expression: *const ast.Expression,
    mutable: *const std.StringHashMapUnmanaged(void),
    inside: bool,
) Error!void {
    switch (expression.*) {
        .name => |name| if (inside) try markMutable(self, mutable, name.text),
        .field => |field| try scanExpression(self, field.target, mutable, inside),
        .call => |call| {
            if (inside) try markMutable(self, mutable, call.callee);
            for (call.arguments) |argument| try scanExpression(self, argument.value, mutable, inside);
        },
        .value_call => |call| {
            try scanExpression(self, call.callee, mutable, inside);
            for (call.arguments) |argument| try scanExpression(self, argument.value, mutable, inside);
        },
        .binary => |binary| {
            try scanExpression(self, binary.left, mutable, inside);
            try scanExpression(self, binary.right, mutable, inside);
        },
        .unary => |unary| try scanExpression(self, unary.operand, mutable, inside),
        .new_object => |made| for (made.arguments) |argument| try scanExpression(self, argument.value, mutable, inside),
        .list_literal => |literal| for (literal.elements) |element| try scanExpression(self, element, mutable, inside),
        .map_literal => |literal| for (literal.entries) |entry| {
            try scanExpression(self, entry.key, mutable, inside);
            try scanExpression(self, entry.value, mutable, inside);
        },
        .index => |index| {
            try scanExpression(self, index.target, mutable, inside);
            for (index.indices) |position| try scanExpression(self, position, mutable, inside);
        },
        .slice_range => |slice| {
            try scanExpression(self, slice.target, mutable, inside);
            if (slice.start) |start| try scanExpression(self, start, mutable, inside);
            if (slice.end) |end| try scanExpression(self, end, mutable, inside);
        },
        .method => |method| {
            try scanExpression(self, method.target, mutable, inside);
            for (method.arguments) |argument| try scanExpression(self, argument.value, mutable, inside);
        },
        .try_call => |attempt| try scanExpression(self, attempt.operand, mutable, inside),
        .spawn => |worker| try scanExpression(self, worker.call, mutable, inside),
        .lambda => {}, // concise lambdas are deliberately capture-free
        .closure => |closure| {
            for (closure.captures) |capture| switch (capture.mode) {
                .strong => try markMutable(self, mutable, capture.name.text),
                .weak => {}, // weak is a creation-time snapshot, not a cell
                .snapshot => if (capture.value) |value| try scanExpression(self, value, mutable, inside),
            };
            try scanBlockForClosures(self, closure.body, mutable, true);
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

// -- Hidden ARC cells -----------------------------------------------------

fn hiddenClass(
    analyzer: *Analyzer,
    name: []const u8,
    fields: []const types.StructField,
) Error!struct { layout: u32, class_type: Type } {
    const layout: u32 = @intCast(analyzer.structs.items.len);
    try analyzer.structs.append(analyzer.arena, .{
        .name = name,
        .fields = try analyzer.arena.dupe(types.StructField, fields),
        .closure_storage = true,
        .reference = true,
    });
    // A reference layout travels as one handle. The field graph still lives
    // in the layout and is walked by ARC when the object dies.
    try analyzer.struct_shapes.append(analyzer.temporary, .{ .carries = true, .values = 1 });
    return .{ .layout = layout, .class_type = try resolve.internHeapType(analyzer, .{ .class = layout }) };
}

fn cellLayout(self: *FunctionBuilder, value_type: Type, weak: bool) Error!context.ClosureCellLayout {
    for (self.analyzer.closure_cells.items) |held| {
        if (held.weak == weak and held.value_type.eql(value_type)) return held;
    }
    const name = try std.fmt.allocPrint(
        self.arena(),
        "{s}.(capture-cell-{d})",
        .{ self.name, self.analyzer.closure_cells.items.len },
    );
    const fields = try self.arena().alloc(types.StructField, 1);
    fields[0] = .{ .name = "value", .field_type = value_type, .weak = weak };
    const made = try hiddenClass(self.analyzer, name, fields);
    const row: context.ClosureCellLayout = .{
        .value_type = value_type,
        .weak = weak,
        .layout = made.layout,
        .cell_type = made.class_type,
    };
    try self.analyzer.closure_cells.append(self.analyzer.arena, row);
    return row;
}

/// Retire the source slot that only bridges a value into, or names a value
/// already held by, a closure cell. The declaration statement records how
/// lowering prepares the value; the semantic scope must agree that the slot
/// itself owns no lifetime after that handoff.
fn markCellBackedBinding(
    self: *FunctionBuilder,
    source_local: LocalId,
    ownership: nodes.BindingOwnership,
) Error!void {
    std.debug.assert(ownership != .normal);
    var found = false;
    var frame_index = self.recorded_blocks.items.len;
    while (frame_index > 0 and !found) {
        frame_index -= 1;
        const statements = self.recorded_blocks.items[frame_index].statements.items;
        var statement_index = statements.len;
        while (statement_index > 0) {
            statement_index -= 1;
            const statement = &statements[statement_index];
            switch (statement.*) {
                .declare => |*declared| {
                    if (declared.local != source_local) continue;
                    declared.ownership = ownership;
                    if (ownership == .borrow) declared.store = .plain;
                    found = true;
                    break;
                },
                .destructure => |*bind| {
                    for (bind.locals, 0..) |local, index| {
                        if (local != source_local) continue;
                        if (bind.ownerships.len == 0) {
                            const ownerships = try self.arena().alloc(nodes.BindingOwnership, bind.locals.len);
                            @memset(ownerships, .normal);
                            bind.ownerships = ownerships;
                        }
                        @constCast(bind.ownerships)[index] = ownership;
                        if (ownership == .borrow) @constCast(bind.stores)[index] = .plain;
                        found = true;
                        break;
                    }
                    if (found) break;
                },
                else => {},
            }
        }
    }
    std.debug.assert(found);

    // The frame-level storage backstop follows this row even when normal
    // scope releases do not. The bridge slot deliberately owns no storage:
    // `transfer` prepares it before the cell adopts it, and `borrow` merely
    // views the cell's already-owned value.
    const source = &self.recorded_locals.items[source_local];
    source.boxed_storage = source.owns_storage;
    source.owns_storage = false;

    var scope_index = self.scopes.items.len;
    while (scope_index > 0) {
        scope_index -= 1;
        const owned = &self.scopes.items[scope_index].owned;
        for (owned.items, 0..) |release, index| {
            if (release.local != source_local) continue;
            _ = owned.orderedRemove(index);
            return;
        }
    }
}

/// After a source `var` declaration has been recorded, create its shared cell
/// when the prepass found a capture. For a closure prologue, link to the cell
/// already loaded from the environment instead of making a second one.
pub fn captureMutableBinding(
    self: *FunctionBuilder,
    name: []const u8,
    source_local: LocalId,
    value_type: Type,
    weak: bool,
    span: Span,
) Error!void {
    for (self.closure_captures) |capture| {
        if (!capture.mutable or !std.mem.eql(u8, capture.name, name)) continue;
        const cell_name = capture.cell_name orelse unreachable;
        const cell = self.findLocal(cell_name) orelse unreachable;
        self.findLocal(name).?.info.capture_cell = .{
            .local = cell.info.local,
            .layout = capture.cell_layout orelse unreachable,
            .cell_type = recorder.localType(self, cell.info.local),
            .value_type = value_type,
            .weak = capture.weak_cell,
        };
        // The environment's cell is the owner. This synthesized local only
        // gives the closure body its source-level name.
        try markCellBackedBinding(self, source_local, .borrow);
        return;
    }
    if (!self.captured_mutables.contains(name)) return;

    const cell = try cellLayout(self, value_type, weak);
    const source = Typed{
        .node = try recorder.recordNode(self, .{ .local_get = .{
            .local = source_local,
            .weak = weak,
            .result = value_type,
            .span = span,
        } }),
        .value_type = value_type,
    };
    if (weak) try ledger.registerTemp(self, source, false, true, span);
    const entries = try self.arena().alloc(recorder.RecordedOperand, 1);
    entries[0] = .{ .node = source.node, .slot = 0, .moved = !weak };
    const made = Typed{
        .node = try recorder.recordNode(self, .{ .struct_make = .{
            .layout = cell.layout,
            .operands = try recorder.recordOperandBatch(self, entries, 1),
            .result = cell.cell_type,
            .span = span,
        } }),
        .value_type = cell.cell_type,
    };
    try ledger.registerTemp(self, made, false, true, span);
    const cell_name = try std.fmt.allocPrint(self.arena(), "$cell.{s}@{d}", .{ name, span.start });
    const cell_local = (try self.declareLocal(cell_name, cell.cell_type, false, span)) orelse return;
    const store = ledger.storeOwnedKind(self, cell_local, made);
    try recorder.recordStatement(self, .{ .declare = .{
        .local = cell_local,
        .value = made.node,
        .store = store,
        .span = span,
    } });
    // The cell now owns the declaration's prepared initial value. The old
    // slot remains only as a stable source-level id and a lowering bridge.
    if (!weak) try markCellBackedBinding(self, source_local, .transfer);
    // Declaring the hidden cell may grow the scope's name table; reacquire the
    // source entry rather than retaining a pointer through that growth.
    self.findLocal(name).?.info.capture_cell = .{
        .local = cell_local,
        .layout = cell.layout,
        .cell_type = cell.cell_type,
        .value_type = value_type,
        .weak = weak,
    };
}

/// Read the canonical value of a captured mutable. The source local remains
/// the identity used by diagnostics and flow narrowing, while the ARC cell is
/// the only storage that every closure and the writing scope share.
pub fn readCapturedMutable(
    self: *FunctionBuilder,
    source_local: LocalId,
    span: Span,
) Error!?Typed {
    const info = self.localById(source_local) orelse return null;
    const cell = info.capture_cell orelse return null;
    const target = try recorder.recordNode(self, .{ .local_get = .{
        .local = cell.local,
        .result = cell.cell_type,
        .span = span,
    } });
    const narrowed = !info.weak and cell.value_type == .optional and
        flow.isNarrowed(self, source_local);
    const result = if (narrowed) cell.value_type.held().? else cell.value_type;
    return .{
        .node = try recorder.recordNode(self, .{ .field_get = .{
            .target = target,
            .layout = cell.layout,
            .field = 0,
            .weak = cell.weak,
            .stored = if (narrowed) cell.value_type else null,
            .narrowed = narrowed,
            .result = result,
            .span = span,
        } }),
        .value_type = result,
    };
}

// -- Exact lexical capture collection ------------------------------------

const CapturedName = struct { text: []const u8, span: Span };

const Collector = struct {
    self: *FunctionBuilder,
    locals: std.ArrayList([]const u8) = .empty,
    captured: std.ArrayList(CapturedName) = .empty,

    fn deinit(c: *Collector) void {
        c.locals.deinit(c.self.temporary());
        c.captured.deinit(c.self.temporary());
    }

    fn local(c: *const Collector, name: []const u8) bool {
        for (c.locals.items) |held| if (std.mem.eql(u8, held, name)) return true;
        return false;
    }

    fn note(c: *Collector, name: []const u8, span: Span) Error!void {
        if (c.local(name) or c.self.findLocal(name) == null) return;
        for (c.captured.items) |held| if (std.mem.eql(u8, held.text, name)) return;
        try c.captured.append(c.self.temporary(), .{ .text = name, .span = span });
    }

    fn addLocal(c: *Collector, name: []const u8) Error!void {
        if (!c.local(name)) try c.locals.append(c.self.temporary(), name);
    }

    fn block(c: *Collector, body: ast.Block) Error!void {
        const floor = c.locals.items.len;
        defer c.locals.shrinkRetainingCapacity(floor);
        for (body.statements) |item| try c.statement(item);
    }

    fn blockWith(c: *Collector, body: ast.Block, names: []const ast.Name) Error!void {
        const floor = c.locals.items.len;
        defer c.locals.shrinkRetainingCapacity(floor);
        for (names) |name| try c.addLocal(name.text);
        for (body.statements) |item| try c.statement(item);
    }

    fn statement(c: *Collector, written: ast.Statement) Error!void {
        switch (written) {
            .let => |declared| {
                try c.expression(declared.value);
                try c.addLocal(declared.name);
            },
            .variable => |declared| {
                if (declared.value) |value| try c.expression(value);
                try c.addLocal(declared.name);
            },
            .destructure => |declared| {
                try c.expression(declared.value);
                for (declared.names) |name| try c.addLocal(name.text);
            },
            .assign => |assigned| {
                try c.target(assigned.target);
                try c.expression(assigned.value);
            },
            .assign_many => |assigned| {
                for (assigned.names) |name| {
                    if (!c.local(name.text)) try c.note(name.text, name.span);
                }
                try c.expression(assigned.value);
            },
            .conditional => |conditional| {
                try c.expression(conditional.condition);
                try c.block(conditional.then_block);
                if (conditional.else_block) |otherwise| try c.block(otherwise);
            },
            .while_loop => |loop| {
                try c.expression(loop.condition);
                try c.block(loop.body);
            },
            .for_range => |loop| {
                try c.expression(loop.start);
                try c.expression(loop.end);
                const name = ast.Name{ .text = loop.name, .span = loop.span };
                try c.blockWith(loop.body, &.{name});
            },
            .for_each => |loop| {
                try c.expression(loop.iterable);
                var names: [2]ast.Name = undefined;
                names[0] = .{ .text = loop.name, .span = loop.span };
                var count: usize = 1;
                if (loop.value_name) |value_name| {
                    names[1] = .{ .text = value_name, .span = loop.span };
                    count = 2;
                }
                try c.blockWith(loop.body, names[0..count]);
            },
            .return_statement => |returned| for (returned.values) |value| try c.expression(value),
            .expression => |value_statement| try c.expression(value_statement.value),
            .guarded => |guarded| {
                try c.statement(guarded.attempt.*);
                if (guarded.binding) |binding| {
                    try c.blockWith(guarded.handler, &.{binding});
                } else try c.block(guarded.handler);
            },
            .match => |matched| {
                try c.expression(matched.scrutinee);
                for (matched.arms) |arm| try c.blockWith(arm.body, arm.bindings);
                if (matched.else_block) |otherwise| try c.block(otherwise);
            },
            .break_statement, .continue_statement => {},
        }
    }

    fn target(c: *Collector, written: ast.Target) Error!void {
        switch (written) {
            .name => |name| if (!c.local(name.text)) try c.note(name.text, name.span),
            .field => |field| if (!c.local(field.base)) try c.note(field.base, field.span),
            .index => |index| {
                try c.expression(index.base);
                for (index.indices) |position| try c.expression(position);
            },
            .chain => |chain| try c.expression(chain.place),
        }
    }

    fn expression(c: *Collector, written: *const ast.Expression) Error!void {
        switch (written.*) {
            .name => |name| try c.note(name.text, name.span),
            .field => |field| try c.expression(field.target),
            .call => |call| {
                try c.note(call.callee, call.span);
                for (call.arguments) |argument| try c.expression(argument.value);
            },
            .value_call => |call| {
                try c.expression(call.callee);
                for (call.arguments) |argument| try c.expression(argument.value);
            },
            .binary => |binary| {
                try c.expression(binary.left);
                try c.expression(binary.right);
            },
            .unary => |unary| try c.expression(unary.operand),
            .new_object => |made| for (made.arguments) |argument| try c.expression(argument.value),
            .list_literal => |literal| for (literal.elements) |element| try c.expression(element),
            .map_literal => |literal| for (literal.entries) |entry| {
                try c.expression(entry.key);
                try c.expression(entry.value);
            },
            .index => |index| {
                try c.expression(index.target);
                for (index.indices) |position| try c.expression(position);
            },
            .slice_range => |slice| {
                try c.expression(slice.target);
                if (slice.start) |start| try c.expression(start);
                if (slice.end) |end| try c.expression(end);
            },
            .method => |method| {
                try c.expression(method.target);
                for (method.arguments) |argument| try c.expression(argument.value);
            },
            .try_call => |attempt| try c.expression(attempt.operand),
            .spawn => |worker| try c.expression(worker.call),
            .lambda => {},
            .closure => |nested| {
                // A nested capture list is evaluated in this closure.
                for (nested.captures) |capture| switch (capture.mode) {
                    .strong, .weak => try c.note(capture.name.text, capture.name.span),
                    .snapshot => try c.expression(capture.value.?),
                };
                const floor = c.locals.items.len;
                defer c.locals.shrinkRetainingCapacity(floor);
                for (nested.parameters) |parameter| try c.addLocal(parameter.text);
                for (nested.captures) |capture| try c.addLocal(capture.name.text);
                for (nested.body.statements) |item| try c.statement(item);
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
};

const CapturePlan = struct {
    name: []const u8,
    span: Span,
    expression: *ast.Expression,
    expected: ?Type,
    weak: bool = false,
    mutable: bool = false,
    value_type: Type,
    cell_layout: ?u32 = null,
    weak_cell: bool = false,
    strong_self: bool = false,
};

fn nameExpression(self: *FunctionBuilder, name: []const u8, span: Span) Error!*ast.Expression {
    const expression = try self.arena().create(ast.Expression);
    expression.* = .{ .name = .{ .text = name, .span = span } };
    return expression;
}

fn planLocalCapture(
    self: *FunctionBuilder,
    plans: *std.ArrayList(CapturePlan),
    name: []const u8,
    span: Span,
    weak: bool,
) Error!bool {
    if (self.lifecycle == .initializer and std.mem.eql(u8, name, "self")) {
        // The initializer validator owns the lifecycle diagnostic. There is
        // intentionally no receiver local for capture preparation to find.
        return false;
    }
    const found = self.findLocal(name) orelse {
        try self.fail("luce.sema.closure.capture", span, "{s} is not a local value available to this closure", .{name});
        return false;
    };
    if (self.lifecycle == .deinitializer and std.mem.eql(u8, name, "self")) {
        try self.fail(
            "luce.sema.class.lifecycle",
            span,
            "deinit cannot capture self in a closure; the class is already on its last strong release",
            .{},
        );
        return false;
    }
    const declared_type = recorder.localType(self, found.info.local);
    if (weak) {
        const optional = if (declared_type == .optional)
            declared_type
        else
            Type.optionalOf(declared_type) orelse {
                try self.fail("luce.sema.closure.capture", span, "weak capture requires an ARC reference, not {s}", .{try self.analyzer.typeName(declared_type)});
                return false;
            };
        if (!shapes.weakTarget(self.analyzer, optional)) {
            try self.fail("luce.sema.closure.capture", span, "weak capture requires a class, list, map, array, or builder reference, not {s}", .{try self.analyzer.typeName(declared_type)});
            return false;
        }
        try plans.append(self.temporary(), .{
            .name = name,
            .span = span,
            .expression = try nameExpression(self, name, span),
            .expected = optional,
            .weak = true,
            .value_type = optional,
        });
        return true;
    }
    if (found.info.mutable) {
        const cell = found.info.capture_cell orelse {
            try self.fail("luce.sema.closure.capture", span, "internal capture cell for {s} was not prepared", .{name});
            return false;
        };
        const cell_name = self.recorded_locals.items[cell.local].name orelse unreachable;
        try plans.append(self.temporary(), .{
            .name = name,
            .span = span,
            .expression = try nameExpression(self, cell_name, span),
            .expected = cell.cell_type,
            .mutable = true,
            .value_type = cell.value_type,
            .cell_layout = cell.layout,
            .weak_cell = cell.weak,
            .strong_self = std.mem.eql(u8, name, "self"),
        });
        return true;
    }
    try plans.append(self.temporary(), .{
        .name = name,
        .span = span,
        .expression = try nameExpression(self, name, span),
        .expected = declared_type,
        .value_type = declared_type,
        .strong_self = std.mem.eql(u8, name, "self"),
    });
    return true;
}

fn conflictsWithOuter(
    self: *FunctionBuilder,
    visible: []const context.EnclosingLocal,
    name: []const u8,
    span: Span,
) Error!bool {
    for (visible) |held| {
        if (!std.mem.eql(u8, held.name, name)) continue;
        try self.fail("luce.sema.duplicate", span, "{s} is already declared in the enclosing scope{s}", .{
            name,
            try naming.declaredAt(
                self.analyzer,
                self.analyzer.modules[self.module].file,
                held.declared_at,
            ),
        });
        return true;
    }
    return false;
}

/// Lifting a closure into a hidden function must not weaken Luce's
/// no-shadowing rule. The hidden function naturally sees its parameters and
/// materialized captures; this walk covers enclosing locals the closure never
/// reads. Nested closure bodies validate themselves when they are lowered.
fn validateOuterBindings(
    self: *FunctionBuilder,
    block: ast.Block,
    visible: []const context.EnclosingLocal,
) Error!bool {
    for (block.statements) |statement| {
        switch (statement) {
            .let => |declared| if (try conflictsWithOuter(self, visible, declared.name, declared.name_span)) return false,
            .variable => |declared| if (try conflictsWithOuter(self, visible, declared.name, declared.name_span)) return false,
            .destructure => |declared| for (declared.names) |name| {
                if (try conflictsWithOuter(self, visible, name.text, name.span)) return false;
            },
            .conditional => |conditional| {
                if (!try validateOuterBindings(self, conditional.then_block, visible)) return false;
                if (conditional.else_block) |otherwise| {
                    if (!try validateOuterBindings(self, otherwise, visible)) return false;
                }
            },
            .while_loop => |loop| if (!try validateOuterBindings(self, loop.body, visible)) return false,
            .for_range => |loop| {
                if (try conflictsWithOuter(self, visible, loop.name, loop.span)) return false;
                if (!try validateOuterBindings(self, loop.body, visible)) return false;
            },
            .for_each => |loop| {
                if (try conflictsWithOuter(self, visible, loop.name, loop.span)) return false;
                if (loop.value_name) |name| {
                    if (try conflictsWithOuter(self, visible, name, loop.span)) return false;
                }
                if (!try validateOuterBindings(self, loop.body, visible)) return false;
            },
            .guarded => |guarded| {
                if (guarded.binding) |binding| {
                    if (try conflictsWithOuter(self, visible, binding.text, binding.span)) return false;
                }
                if (!try validateOuterBindings(self, guarded.handler, visible)) return false;
            },
            .match => |matched| {
                for (matched.arms) |arm| {
                    for (arm.bindings) |binding| {
                        if (try conflictsWithOuter(self, visible, binding.text, binding.span)) return false;
                    }
                    if (!try validateOuterBindings(self, arm.body, visible)) return false;
                }
                if (matched.else_block) |otherwise| {
                    if (!try validateOuterBindings(self, otherwise, visible)) return false;
                }
            },
            .assign,
            .assign_many,
            .return_statement,
            .expression,
            .break_statement,
            .continue_statement,
            => {},
        }
    }
    return true;
}

/// Lower a block closure into one hidden function plus, when needed, one ARC
/// environment class bound as that function value's receiver.
pub fn lowerClosure(
    self: *FunctionBuilder,
    written: ast.Closure,
    wanted_function: ?u32,
) Error!?Typed {
    const signature_index = wanted_function orelse {
        try self.fail(
            "luce.sema.type",
            written.span,
            "a closure needs a place that expects a function: annotate the binding or return it from a function with a func(...) result",
            .{},
        );
        return null;
    };
    const signature = self.analyzer.signatures.items[signature_index];
    if (written.parameters.len != signature.parameters.len) {
        try self.fail(
            "luce.sema.type",
            written.span,
            "this place takes {d} parameter{s}; this closure writes {d}",
            .{ signature.parameters.len, if (signature.parameters.len == 1) "" else "s", written.parameters.len },
        );
        return null;
    }

    const visible = try self.visibleLocals();
    for (written.parameters, 0..) |parameter, index| {
        for (written.parameters[0..index]) |earlier| {
            if (!std.mem.eql(u8, parameter.text, earlier.text)) continue;
            try self.fail("luce.sema.duplicate", parameter.span, "duplicate closure parameter {s}", .{parameter.text});
            return null;
        }
        for (visible) |held| {
            if (!std.mem.eql(u8, parameter.text, held.name)) continue;
            try self.fail("luce.sema.duplicate", parameter.span, "{s} is already declared in the enclosing scope", .{parameter.text});
            return null;
        }
    }
    if (!try validateOuterBindings(self, written.body, visible)) return null;

    var explicit: std.StringHashMapUnmanaged(void) = .empty;
    defer explicit.deinit(self.temporary());
    var plans: std.ArrayList(CapturePlan) = .empty;
    defer plans.deinit(self.temporary());
    for (written.captures) |capture| {
        if (explicit.contains(capture.name.text)) {
            try self.fail("luce.sema.duplicate", capture.name.span, "{s} is captured twice", .{capture.name.text});
            return null;
        }
        for (written.parameters) |parameter| {
            if (!std.mem.eql(u8, parameter.text, capture.name.text)) continue;
            try self.fail("luce.sema.duplicate", capture.name.span, "{s} is both a capture and a parameter", .{capture.name.text});
            return null;
        }
        try explicit.put(self.temporary(), capture.name.text, {});
        switch (capture.mode) {
            .strong => if (!try planLocalCapture(self, &plans, capture.name.text, capture.span, false)) return null,
            .weak => if (!try planLocalCapture(self, &plans, capture.name.text, capture.span, true)) return null,
            .snapshot => try plans.append(self.temporary(), .{
                .name = capture.name.text,
                .span = capture.span,
                .expression = capture.value.?,
                .expected = null,
                .value_type = .none,
                .strong_self = builder_mod.isBareSelf(capture.value.?),
            }),
        }
    }

    var collector: Collector = .{ .self = self };
    defer collector.deinit();
    for (written.parameters) |parameter| try collector.addLocal(parameter.text);
    for (written.captures) |capture| try collector.addLocal(capture.name.text);
    for (written.body.statements) |statement| try collector.statement(statement);
    for (collector.captured.items) |capture| {
        if (explicit.contains(capture.text)) continue;
        if (!try planLocalCapture(self, &plans, capture.text, capture.span, false)) return null;
    }

    if (self.closure_destination) |destination| {
        for (plans.items) |plan| {
            if (!plan.strong_self) continue;
            try self.fail(
                "luce.sema.closure.cycle",
                written.span,
                "storing this closure in self.{s} while it strongly captures self creates an ARC cycle; write [weak self] func(...) and unwrap self inside the closure",
                .{destination.field},
            );
            return null;
        }
    }

    const expressions = try self.arena().alloc(*ast.Expression, plans.items.len);
    const landings = try self.arena().alloc(?Type, plans.items.len);
    for (plans.items, expressions, landings) |plan, *expression, *landing| {
        expression.* = plan.expression;
        landing.* = plan.expected;
    }
    const run = (try self.lowerOperandsIntoTracking(expressions, .{ .maybe_places = landings })) orelse return null;
    for (plans.items, run.values) |*plan, *value| {
        if (plan.expected) |expected| {
            value.* = (try self.fit(value.*, expected)) orelse {
                try self.fail("luce.sema.closure.capture", plan.span, "capture {s} needs {s}, got {s}", .{
                    plan.name,
                    try self.analyzer.typeName(expected),
                    try self.analyzer.typeName(value.value_type),
                });
                return null;
            };
            plan.value_type = if (plan.mutable) plan.value_type else expected;
        } else {
            plan.value_type = value.value_type;
        }
    }

    const at = self.analyzer.diagnostics.sources.place(
        self.analyzer.modules[self.module].file,
        written.span.start,
    );
    const function_name = try std.fmt.allocPrint(
        self.arena(),
        "{s}.(closure@{d}.{d})",
        .{ self.name, at.line, at.column },
    );

    var environment_node: ?nodes.NodeRef = null;
    var environment_type: ?Type = null;
    const capture_infos = try self.arena().alloc(context.ClosureCaptureInfo, plans.items.len);
    var prologue_count: usize = 0;
    for (plans.items) |plan| prologue_count += if (plan.mutable) 2 else 1;
    const body_statements = try self.arena().alloc(ast.Statement, prologue_count + written.body.statements.len);
    var next_statement: usize = 0;

    if (plans.items.len != 0) {
        const fields = try self.arena().alloc(types.StructField, plans.items.len);
        const entries = try self.arena().alloc(recorder.RecordedOperand, plans.items.len);
        for (plans.items, run.values, run.copied, fields, entries, capture_infos, 0..) |plan, value, copied, *field, *entry, *info, index| {
            field.* = .{ .name = plan.name, .field_type = if (plan.mutable) value.value_type else plan.value_type, .weak = plan.weak };
            entry.* = .{ .node = value.node, .slot = @intCast(index), .copied = copied };
            ledger.ownedForStore(self, value);
            info.* = .{
                .name = plan.name,
                .value_type = plan.value_type,
                .mutable = plan.mutable,
                .cell_layout = plan.cell_layout,
                .weak_cell = plan.weak_cell,
                .declared_at = plan.span,
            };
        }
        const env_name = try std.fmt.allocPrint(self.arena(), "{s}.(environment)", .{function_name});
        const env = try hiddenClass(self.analyzer, env_name, fields);
        environment_type = env.class_type;
        environment_node = try recorder.recordNode(self, .{ .struct_make = .{
            .layout = env.layout,
            .operands = try recorder.recordOperandBatch(self, entries, entries.len),
            .result = env.class_type,
            .span = written.span,
        } });

        for (plans.items, capture_infos) |plan, *info| {
            const env_name_node = try nameExpression(self, "$closure", plan.span);
            const from_env = try self.arena().create(ast.Expression);
            from_env.* = .{ .field = .{
                .target = env_name_node,
                .name = plan.name,
                .span = plan.span,
            } };
            if (!plan.mutable) {
                body_statements[next_statement] = .{ .let = .{
                    .name = plan.name,
                    .name_span = plan.span,
                    .annotation = null,
                    .value = from_env,
                    .span = plan.span,
                } };
                next_statement += 1;
                continue;
            }
            const cell_name = try std.fmt.allocPrint(self.arena(), "$capture.{s}@{d}", .{ plan.name, plan.span.start });
            info.cell_name = cell_name;
            body_statements[next_statement] = .{ .let = .{
                .name = cell_name,
                .name_span = plan.span,
                .annotation = null,
                .value = from_env,
                .span = plan.span,
            } };
            next_statement += 1;
            const cell_name_node = try nameExpression(self, cell_name, plan.span);
            const from_cell = try self.arena().create(ast.Expression);
            from_cell.* = .{ .field = .{
                .target = cell_name_node,
                .name = "value",
                .span = plan.span,
            } };
            body_statements[next_statement] = .{ .variable = .{
                .name = plan.name,
                .name_span = plan.span,
                .annotation = null,
                .value = from_cell,
                .span = plan.span,
            } };
            next_statement += 1;
        }
    }
    @memcpy(body_statements[next_statement..], written.body.statements);

    const hidden: usize = if (environment_type == null) 0 else 1;
    const parameters = try self.arena().alloc(ast.Parameter, written.parameters.len + hidden);
    if (environment_type != null) parameters[0] = .{
        .name = "$closure",
        .name_span = written.span,
        .type_name = .{ .name = "func", .span = written.span },
        .span = written.span,
    };
    for (written.parameters, parameters[hidden..]) |parameter, *slot| slot.* = .{
        .name = parameter.text,
        .name_span = parameter.span,
        .type_name = .{ .name = "func", .span = parameter.span },
        .span = parameter.span,
    };
    const returns = try self.arena().alloc(ast.TypeName, if (signature.result == .none) 0 else 1);
    if (returns.len == 1) returns[0] = .{ .name = "func", .span = written.span };
    const declaration = try self.arena().create(ast.FuncDecl);
    declaration.* = .{
        .name = function_name,
        .name_span = written.span,
        .parameters = parameters,
        .returns = returns,
        .body = .{ .statements = body_statements, .span = written.body.span },
        .span = written.span,
    };
    const function = if (environment_type) |env_type|
        try signatures.registerClosure(self.analyzer, declaration, self.module, env_type, signature, capture_infos)
    else
        try signatures.registerLambda(self.analyzer, declaration, self.module, signature, &.{});
    const result: Type = .{ .function = signature_index };
    return .{
        .node = try recorder.recordNode(self, .{ .lambda_ref = .{
            .function = function,
            .environment = environment_node,
            .result = result,
            .span = written.span,
        } }),
        .value_type = result,
    };
}
