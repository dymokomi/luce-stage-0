//! The Luce parser: tokens to an arena-allocated AST.
//!
//! Handwritten recursive descent for declarations and statements with a
//! Pratt expression parser.  The parser recovers at line and block
//! boundaries so one edit produces several useful diagnostics instead
//! of one.

const std = @import("std");
const source_mod = @import("source.zig");
const token_mod = @import("token.zig");
const lexer_mod = @import("lexer.zig");
const ast = @import("ast.zig");
const diagnostics_mod = @import("diagnostics.zig");

const Allocator = std.mem.Allocator;
const Span = source_mod.Span;
const Token = token_mod.Token;
const Kind = token_mod.Kind;
const Diagnostics = diagnostics_mod.Diagnostics;

pub const Error = error{OutOfMemory};

/// Parse a whole program.  The AST is allocated from `arena` and lives
/// exactly as long as it; token storage is temporary.  Parse problems
/// land in `diagnostics` — a program with errors may still return a
/// partial tree for further reporting.
pub fn parse(
    arena: Allocator,
    temporary: Allocator,
    source: []const u8,
    diagnostics: *Diagnostics,
) Error!ast.Program {
    const tokens = try lexer_mod.lex(temporary, source, diagnostics);
    defer temporary.free(tokens);

    var parser: Parser = .{
        .arena = arena,
        .source = source,
        .tokens = tokens,
        .diagnostics = diagnostics,
    };
    return parser.program();
}

const Parser = struct {
    arena: Allocator,
    source: []const u8,
    tokens: []const Token,
    diagnostics: *Diagnostics,
    index: usize = 0,

    // Token helpers --------------------------------------------------------

    fn peek(self: *const Parser) Token {
        return self.tokens[self.index];
    }

    fn peekKind(self: *const Parser) Kind {
        return self.tokens[self.index].kind;
    }

    fn peekAhead(self: *const Parser, ahead: usize) Kind {
        const at = @min(self.index + ahead, self.tokens.len - 1);
        return self.tokens[at].kind;
    }

    fn advance(self: *Parser) Token {
        const item = self.tokens[self.index];
        if (self.index + 1 < self.tokens.len) self.index += 1;
        return item;
    }

    fn accept(self: *Parser, kind: Kind) ?Token {
        if (self.peekKind() != kind) return null;
        return self.advance();
    }

    fn expect(self: *Parser, kind: Kind, what: []const u8) Error!?Token {
        if (self.accept(kind)) |item| return item;
        try self.diagnostics.add(
            "luce.parse.expected",
            self.peek().span,
            "expected {s}",
            .{what},
        );
        return null;
    }

    fn text(self: *const Parser, item: Token) []const u8 {
        return item.span.slice(self.source);
    }

    // Skip to the start of the next line at the current block level.
    fn syncToLine(self: *Parser) void {
        var depth: usize = 0;
        while (true) {
            switch (self.peekKind()) {
                .end_of_file => return,
                .newline => {
                    _ = self.advance();
                    if (depth == 0) return;
                },
                .indent => {
                    depth += 1;
                    _ = self.advance();
                },
                .dedent => {
                    if (depth == 0) return;
                    depth -= 1;
                    _ = self.advance();
                },
                else => _ = self.advance(),
            }
        }
    }

    // Declarations ---------------------------------------------------------

    fn program(self: *Parser) Error!ast.Program {
        var structs: std.ArrayList(ast.StructDecl) = .empty;
        defer structs.deinit(self.arena);
        var functions: std.ArrayList(ast.FnDecl) = .empty;
        defer functions.deinit(self.arena);

        while (self.peekKind() != .end_of_file) {
            switch (self.peekKind()) {
                .newline => _ = self.advance(),
                .keyword_struct => {
                    if (try self.structDecl()) |declaration| {
                        try structs.append(self.arena, declaration);
                    } else {
                        self.syncToLine();
                    }
                },
                .keyword_fn => {
                    if (try self.fnDecl()) |declaration| {
                        try functions.append(self.arena, declaration);
                    } else {
                        self.syncToLine();
                    }
                },
                else => {
                    try self.diagnostics.add(
                        "luce.parse.top",
                        self.peek().span,
                        "expected fn or struct at top level",
                        .{},
                    );
                    self.syncToLine();
                },
            }
        }
        return .{
            .structs = try structs.toOwnedSlice(self.arena),
            .functions = try functions.toOwnedSlice(self.arena),
        };
    }

    fn typeName(self: *Parser) Error!?ast.TypeName {
        const item = (try self.expect(.identifier, "a type name")) orelse return null;
        return .{ .name = self.text(item), .span = item.span };
    }

    fn structDecl(self: *Parser) Error!?ast.StructDecl {
        const start = self.advance(); // struct
        const name = (try self.expect(.identifier, "a struct name")) orelse return null;
        if ((try self.expect(.colon, "':'")) == null) return null;
        if ((try self.expect(.newline, "a newline")) == null) return null;
        if ((try self.expect(.indent, "an indented field list")) == null) return null;

        var fields: std.ArrayList(ast.Field) = .empty;
        defer fields.deinit(self.arena);
        while (self.peekKind() != .dedent and self.peekKind() != .end_of_file) {
            if (self.accept(.newline) != null) continue;
            const field_name = (try self.expect(.identifier, "a field name")) orelse {
                self.syncToLine();
                continue;
            };
            if ((try self.expect(.colon, "':' after the field name")) == null) {
                self.syncToLine();
                continue;
            }
            const field_type = (try self.typeName()) orelse {
                self.syncToLine();
                continue;
            };
            _ = try self.expect(.newline, "a newline after the field");
            try fields.append(self.arena, .{
                .name = self.text(field_name),
                .type_name = field_type,
                .span = .{ .start = field_name.span.start, .end = field_type.span.end },
            });
        }
        _ = self.accept(.dedent);
        return .{
            .name = self.text(name),
            .fields = try fields.toOwnedSlice(self.arena),
            .span = .{ .start = start.span.start, .end = name.span.end },
        };
    }

    fn fnDecl(self: *Parser) Error!?ast.FnDecl {
        const start = self.advance(); // fn
        const name = (try self.expect(.identifier, "a function name")) orelse return null;
        if ((try self.expect(.left_paren, "'('")) == null) return null;

        var parameters: std.ArrayList(ast.Parameter) = .empty;
        defer parameters.deinit(self.arena);
        while (self.peekKind() != .right_paren and self.peekKind() != .end_of_file) {
            const parameter_name = (try self.expect(.identifier, "a parameter name")) orelse
                return null;
            if ((try self.expect(.colon, "':' after the parameter name")) == null) return null;
            const parameter_type = (try self.typeName()) orelse return null;
            try parameters.append(self.arena, .{
                .name = self.text(parameter_name),
                .type_name = parameter_type,
                .span = .{ .start = parameter_name.span.start, .end = parameter_type.span.end },
            });
            if (self.accept(.comma) == null) break;
        }
        if ((try self.expect(.right_paren, "')'")) == null) return null;

        var return_type: ?ast.TypeName = null;
        if (self.accept(.arrow) != null) {
            return_type = (try self.typeName()) orelse return null;
        }
        const body = (try self.block()) orelse return null;
        return .{
            .name = self.text(name),
            .parameters = try parameters.toOwnedSlice(self.arena),
            .return_type = return_type,
            .body = body,
            .span = .{ .start = start.span.start, .end = name.span.end },
        };
    }

    // Statements -----------------------------------------------------------

    fn block(self: *Parser) Error!?ast.Block {
        if ((try self.expect(.colon, "':'")) == null) return null;
        if ((try self.expect(.newline, "a newline")) == null) return null;
        const opened = (try self.expect(.indent, "an indented block")) orelse return null;

        var statements: std.ArrayList(ast.Statement) = .empty;
        defer statements.deinit(self.arena);
        while (self.peekKind() != .dedent and self.peekKind() != .end_of_file) {
            if (self.accept(.newline) != null) continue;
            if (try self.statement()) |parsed| {
                try statements.append(self.arena, parsed);
            } else {
                self.syncToLine();
            }
        }
        const closed = self.peek().span;
        _ = self.accept(.dedent);
        return .{
            .statements = try statements.toOwnedSlice(self.arena),
            .span = .{ .start = opened.span.start, .end = closed.end },
        };
    }

    fn statement(self: *Parser) Error!?ast.Statement {
        switch (self.peekKind()) {
            .keyword_let => return self.binding(false),
            .keyword_var => return self.binding(true),
            .keyword_if => return self.conditional(),
            .keyword_while => return self.whileLoop(),
            .keyword_for => return self.forRange(),
            .keyword_return => return self.returnStatement(),
            .keyword_break => {
                const item = self.advance();
                _ = try self.expect(.newline, "a newline after break");
                return .{ .break_statement = .{ .span = item.span } };
            },
            .keyword_continue => {
                const item = self.advance();
                _ = try self.expect(.newline, "a newline after continue");
                return .{ .continue_statement = .{ .span = item.span } };
            },
            else => return self.assignOrExpression(),
        }
    }

    fn binding(self: *Parser, mutable: bool) Error!?ast.Statement {
        const start = self.advance(); // let or var
        const name = (try self.expect(.identifier, "a binding name")) orelse return null;
        var annotation: ?ast.TypeName = null;
        if (self.accept(.colon) != null) {
            annotation = (try self.typeName()) orelse return null;
        }
        if ((try self.expect(.assign, "'=' with an initial value")) == null) return null;
        const value = (try self.expression()) orelse return null;
        _ = try self.expect(.newline, "a newline after the binding");
        const span: Span = .{ .start = start.span.start, .end = value.span().end };
        if (mutable) {
            return .{ .variable = .{
                .name = self.text(name),
                .annotation = annotation,
                .value = value,
                .span = span,
            } };
        }
        return .{ .let = .{
            .name = self.text(name),
            .annotation = annotation,
            .value = value,
            .span = span,
        } };
    }

    fn conditional(self: *Parser) Error!?ast.Statement {
        const start = self.advance(); // if or elif
        const condition = (try self.expression()) orelse return null;
        const then_block = (try self.block()) orelse return null;

        var else_block: ?ast.Block = null;
        if (self.peekKind() == .keyword_elif) {
            // An elif chain is sugar for else: if ...
            const nested = (try self.conditional()) orelse return null;
            const statements = try self.arena.alloc(ast.Statement, 1);
            statements[0] = nested;
            const nested_span = switch (nested) {
                .conditional => |inner| inner.span,
                else => start.span,
            };
            else_block = .{ .statements = statements, .span = nested_span };
        } else if (self.accept(.keyword_else) != null) {
            else_block = (try self.block()) orelse return null;
        }
        return .{ .conditional = .{
            .condition = condition,
            .then_block = then_block,
            .else_block = else_block,
            .span = .{ .start = start.span.start, .end = condition.span().end },
        } };
    }

    fn whileLoop(self: *Parser) Error!?ast.Statement {
        const start = self.advance();
        const condition = (try self.expression()) orelse return null;
        const body = (try self.block()) orelse return null;
        return .{ .while_loop = .{
            .condition = condition,
            .body = body,
            .span = .{ .start = start.span.start, .end = condition.span().end },
        } };
    }

    fn forRange(self: *Parser) Error!?ast.Statement {
        const start = self.advance();
        const name = (try self.expect(.identifier, "a loop variable")) orelse return null;
        if ((try self.expect(.keyword_in, "'in'")) == null) return null;
        const callee = (try self.expect(.identifier, "range(start, end)")) orelse return null;
        if (!std.mem.eql(u8, self.text(callee), "range")) {
            try self.diagnostics.add(
                "luce.parse.range",
                callee.span,
                "for iterates over range(start, end) in Luce 0.1",
                .{},
            );
            return null;
        }
        if ((try self.expect(.left_paren, "'('")) == null) return null;
        const first = (try self.expression()) orelse return null;
        if ((try self.expect(.comma, "',' between range bounds")) == null) return null;
        const second = (try self.expression()) orelse return null;
        _ = self.accept(.comma);
        if ((try self.expect(.right_paren, "')'")) == null) return null;
        const body = (try self.block()) orelse return null;
        return .{ .for_range = .{
            .name = self.text(name),
            .start = first,
            .end = second,
            .body = body,
            .span = .{ .start = start.span.start, .end = name.span.end },
        } };
    }

    fn returnStatement(self: *Parser) Error!?ast.Statement {
        const start = self.advance();
        if (self.accept(.newline) != null) {
            return .{ .return_statement = .{ .value = null, .span = start.span } };
        }
        const value = (try self.expression()) orelse return null;
        _ = try self.expect(.newline, "a newline after return");
        return .{ .return_statement = .{
            .value = value,
            .span = .{ .start = start.span.start, .end = value.span().end },
        } };
    }

    // name (. name)? = expression, or a bare expression statement.
    fn assignOrExpression(self: *Parser) Error!?ast.Statement {
        if (self.peekKind() == .identifier) {
            // Lookahead: IDENT = ..., or IDENT . IDENT = ...
            if (self.peekAhead(1) == .assign) {
                const base = self.advance();
                _ = self.advance(); // =
                const value = (try self.expression()) orelse return null;
                _ = try self.expect(.newline, "a newline after the assignment");
                return .{ .assign = .{
                    .target = .{ .base = self.text(base), .field = null, .span = base.span },
                    .value = value,
                    .span = .{ .start = base.span.start, .end = value.span().end },
                } };
            }
            if (self.peekAhead(1) == .dot and self.peekAhead(2) == .identifier and
                self.peekAhead(3) == .assign)
            {
                const base = self.advance();
                _ = self.advance(); // .
                const field = self.advance();
                _ = self.advance(); // =
                const value = (try self.expression()) orelse return null;
                _ = try self.expect(.newline, "a newline after the assignment");
                return .{ .assign = .{
                    .target = .{
                        .base = self.text(base),
                        .field = self.text(field),
                        .span = .{ .start = base.span.start, .end = field.span.end },
                    },
                    .value = value,
                    .span = .{ .start = base.span.start, .end = value.span().end },
                } };
            }
        }
        const value = (try self.expression()) orelse return null;
        _ = try self.expect(.newline, "a newline after the expression");
        return .{ .expression = .{ .value = value, .span = value.span() } };
    }

    // Expressions ----------------------------------------------------------

    const Precedence = enum(u8) {
        none = 0,
        logic_or = 1,
        logic_and = 2,
        comparison = 3,
        additive = 4,
        multiplicative = 5,
    };

    fn binaryPrecedence(kind: Kind) Precedence {
        return switch (kind) {
            .keyword_or => .logic_or,
            .keyword_and => .logic_and,
            .equal, .not_equal, .less, .less_equal, .greater, .greater_equal => .comparison,
            .plus, .minus => .additive,
            .star, .slash, .percent => .multiplicative,
            else => .none,
        };
    }

    fn binaryOp(kind: Kind) ast.BinaryOp {
        return switch (kind) {
            .keyword_or => .logic_or,
            .keyword_and => .logic_and,
            .equal => .equal,
            .not_equal => .not_equal,
            .less => .less,
            .less_equal => .less_equal,
            .greater => .greater,
            .greater_equal => .greater_equal,
            .plus => .add,
            .minus => .subtract,
            .star => .multiply,
            .slash => .divide,
            .percent => .remainder,
            else => unreachable,
        };
    }

    fn expression(self: *Parser) Error!?*ast.Expression {
        return self.binaryExpression(@intFromEnum(Precedence.logic_or));
    }

    fn binaryExpression(self: *Parser, minimum: u8) Error!?*ast.Expression {
        var left = (try self.unaryExpression()) orelse return null;
        while (true) {
            const precedence = binaryPrecedence(self.peekKind());
            if (@intFromEnum(precedence) < minimum or precedence == .none) return left;
            const operator = self.advance();
            const right = (try self.binaryExpression(@intFromEnum(precedence) + 1)) orelse
                return null;
            const node = try self.arena.create(ast.Expression);
            node.* = .{ .binary = .{
                .op = binaryOp(operator.kind),
                .left = left,
                .right = right,
                .span = .{ .start = left.span().start, .end = right.span().end },
            } };
            left = node;
        }
    }

    fn unaryExpression(self: *Parser) Error!?*ast.Expression {
        if (self.accept(.keyword_not)) |operator| {
            const operand = (try self.unaryExpression()) orelse return null;
            const node = try self.arena.create(ast.Expression);
            node.* = .{ .unary = .{
                .op = .logic_not,
                .operand = operand,
                .span = .{ .start = operator.span.start, .end = operand.span().end },
            } };
            return node;
        }
        if (self.accept(.minus)) |operator| {
            const operand = (try self.unaryExpression()) orelse return null;
            const node = try self.arena.create(ast.Expression);
            node.* = .{ .unary = .{
                .op = .negate,
                .operand = operand,
                .span = .{ .start = operator.span.start, .end = operand.span().end },
            } };
            return node;
        }
        return self.postfixExpression();
    }

    fn postfixExpression(self: *Parser) Error!?*ast.Expression {
        var value = (try self.primaryExpression()) orelse return null;
        while (self.accept(.dot)) |dot| {
            const field = (try self.expect(.identifier, "a field name after '.'")) orelse
                return null;
            _ = dot;
            const node = try self.arena.create(ast.Expression);
            node.* = .{ .field = .{
                .target = value,
                .name = self.text(field),
                .span = .{ .start = value.span().start, .end = field.span.end },
            } };
            value = node;
        }
        return value;
    }

    fn primaryExpression(self: *Parser) Error!?*ast.Expression {
        switch (self.peekKind()) {
            .int_literal => {
                const item = self.advance();
                return self.make(.{ .int_literal = .{ .text = self.text(item), .span = item.span } });
            },
            .float_literal => {
                const item = self.advance();
                return self.make(.{ .float_literal = .{ .text = self.text(item), .span = item.span } });
            },
            .keyword_true => {
                const item = self.advance();
                return self.make(.{ .bool_literal = .{ .value = true, .span = item.span } });
            },
            .keyword_false => {
                const item = self.advance();
                return self.make(.{ .bool_literal = .{ .value = false, .span = item.span } });
            },
            .string_literal => {
                const item = self.advance();
                const decoded = try self.decodeString(item);
                return self.make(.{ .string_literal = .{ .decoded = decoded, .span = item.span } });
            },
            .identifier => {
                const item = self.advance();
                if (self.peekKind() == .left_paren) {
                    return self.callExpression(item);
                }
                return self.make(.{ .name = .{ .text = self.text(item), .span = item.span } });
            },
            .left_paren => {
                _ = self.advance();
                const inner = (try self.expression()) orelse return null;
                if ((try self.expect(.right_paren, "')'")) == null) return null;
                return inner;
            },
            else => {
                try self.diagnostics.add(
                    "luce.parse.expression",
                    self.peek().span,
                    "expected an expression",
                    .{},
                );
                return null;
            },
        }
    }

    fn callExpression(self: *Parser, callee: Token) Error!?*ast.Expression {
        _ = self.advance(); // (
        var arguments: std.ArrayList(ast.Argument) = .empty;
        defer arguments.deinit(self.arena);
        while (self.peekKind() != .right_paren and self.peekKind() != .end_of_file) {
            var argument_name: ?[]const u8 = null;
            if (self.peekKind() == .identifier and self.peekAhead(1) == .assign) {
                const named = self.advance();
                _ = self.advance(); // =
                argument_name = self.text(named);
            }
            const value = (try self.expression()) orelse return null;
            try arguments.append(self.arena, .{
                .name = argument_name,
                .value = value,
                .span = value.span(),
            });
            if (self.accept(.comma) == null) break;
        }
        const closing = (try self.expect(.right_paren, "')'")) orelse return null;
        return self.make(.{ .call = .{
            .callee = self.text(callee),
            .arguments = try arguments.toOwnedSlice(self.arena),
            .span = .{ .start = callee.span.start, .end = closing.span.end },
        } });
    }

    fn make(self: *Parser, value: ast.Expression) Error!*ast.Expression {
        const node = try self.arena.create(ast.Expression);
        node.* = value;
        return node;
    }

    fn decodeString(self: *Parser, item: Token) Error![]const u8 {
        const raw = self.text(item);
        const inner = raw[1 .. raw.len - 1];
        var decoded: std.ArrayList(u8) = .empty;
        defer decoded.deinit(self.arena);
        var index: usize = 0;
        while (index < inner.len) : (index += 1) {
            if (inner[index] == '\\' and index + 1 < inner.len) {
                index += 1;
                try decoded.append(self.arena, switch (inner[index]) {
                    'n' => '\n',
                    't' => '\t',
                    '\\' => '\\',
                    '"' => '"',
                    else => inner[index],
                });
            } else {
                try decoded.append(self.arena, inner[index]);
            }
        }
        return decoded.toOwnedSlice(self.arena);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    diagnostics: Diagnostics,
    program: ast.Program,

    fn deinit(self: *Parsed) void {
        self.diagnostics.deinit();
        self.arena.deinit();
    }
};

fn parseText(text: []const u8) !Parsed {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();
    var diagnostics = Diagnostics.init(testing.allocator);
    errdefer diagnostics.deinit();
    const program = try parse(arena.allocator(), testing.allocator, text, &diagnostics);
    return .{ .arena = arena, .diagnostics = diagnostics, .program = program };
}

test "the plan's scale example parses" {
    var parsed = try parseText(
        \\struct Point:
        \\    x: Float
        \\    y: Float
        \\
        \\fn scale_point(point: Point, factor: Float) -> Point:
        \\    return Point(
        \\        x = point.x * factor,
        \\        y = point.y * factor,
        \\    )
        \\
        \\fn evaluate():
        \\    let position = input.position
        \\    let factor = input.scale
        \\    output.position = scale_point(position, factor)
        \\
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diagnostics.count());
    try testing.expectEqual(@as(usize, 1), parsed.program.structs.len);
    try testing.expectEqual(@as(usize, 2), parsed.program.functions.len);
    try testing.expectEqualStrings("Point", parsed.program.structs[0].name);
    try testing.expectEqual(@as(usize, 2), parsed.program.structs[0].fields.len);
    try testing.expectEqualStrings("scale_point", parsed.program.functions[0].name);
    try testing.expectEqual(@as(usize, 2), parsed.program.functions[0].parameters.len);
    try testing.expect(parsed.program.functions[0].return_type != null);

    // evaluate's third statement is an output.position assignment.
    const evaluate = parsed.program.functions[1];
    try testing.expectEqual(@as(usize, 3), evaluate.body.statements.len);
    const assign = evaluate.body.statements[2].assign;
    try testing.expectEqualStrings("output", assign.target.base);
    try testing.expectEqualStrings("position", assign.target.field.?);
}

test "control flow, precedence, and elif chains parse" {
    var parsed = try parseText(
        \\fn evaluate():
        \\    var total = 0
        \\    for index in range(0, 10):
        \\        if index % 2 == 0 and index != 4:
        \\            total = total + index * 2
        \\        elif index == 5:
        \\            continue
        \\        else:
        \\            break
        \\    while total > 100:
        \\        total = total - 1
        \\    output.total = total
        \\
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diagnostics.count());
    const body = parsed.program.functions[0].body;
    try testing.expectEqual(@as(usize, 4), body.statements.len);

    // Precedence: total + index * 2 parses as total + (index * 2).
    const loop = body.statements[1].for_range;
    const conditional = loop.body.statements[0].conditional;
    const sum = conditional.then_block.statements[0].assign.value.binary;
    try testing.expectEqual(ast.BinaryOp.add, sum.op);
    try testing.expectEqual(ast.BinaryOp.multiply, sum.right.binary.op);
    // The elif chain nests inside the else block.
    try testing.expect(conditional.else_block != null);
    const chained = conditional.else_block.?.statements[0].conditional;
    try testing.expect(chained.else_block != null);
}

test "malformed statements recover and keep reporting" {
    var parsed = try parseText(
        \\fn evaluate():
        \\    let = 3
        \\    let ok = 1
        \\    output.value = ok +
        \\
        \\fn helper() -> Int:
        \\    return 2
        \\
    );
    defer parsed.deinit();
    try testing.expect(parsed.diagnostics.count() >= 2);
    // Recovery still sees both functions.
    try testing.expectEqual(@as(usize, 2), parsed.program.functions.len);
}

test "strings decode escapes" {
    var parsed = try parseText(
        \\fn evaluate():
        \\    output.text = "line\none\ttab \"quoted\""
        \\
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diagnostics.count());
    const value = parsed.program.functions[0].body.statements[0].assign.value;
    try testing.expectEqualStrings("line\none\ttab \"quoted\"", value.string_literal.decoded);
}
