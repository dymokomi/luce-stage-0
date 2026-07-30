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
    /// Expression nesting depth, so a pathological `((((…))))` or a
    /// long prefix-operator chain reports an error instead of
    /// overflowing the native stack.  Generous: real code never
    /// approaches it; only hostile or generated input does.
    depth: u32 = 0,

    const max_depth = 512;

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
        var imports: std.ArrayList(ast.Import) = .empty;
        defer imports.deinit(self.arena);
        var constants: std.ArrayList(ast.ConstDecl) = .empty;
        defer constants.deinit(self.arena);
        var structs: std.ArrayList(ast.StructDecl) = .empty;
        defer structs.deinit(self.arena);
        var functions: std.ArrayList(ast.FuncDecl) = .empty;
        defer functions.deinit(self.arena);

        while (self.peekKind() != .end_of_file) {
            switch (self.peekKind()) {
                .newline => _ = self.advance(),
                .keyword_import => {
                    const start = self.advance();
                    const name = (try self.expect(.identifier, "a module name after import")) orelse {
                        self.syncToLine();
                        continue;
                    };
                    _ = try self.expect(.newline, "a newline after the import");
                    try imports.append(self.arena, .{
                        .name = self.text(name),
                        .span = .{ .start = start.span.start, .end = name.span.end },
                    });
                },
                .keyword_struct => {
                    if (try self.structDecl()) |declaration| {
                        try structs.append(self.arena, declaration);
                    } else {
                        self.syncToLine();
                    }
                },
                .keyword_func => {
                    if (try self.funcDecl()) |declaration| {
                        try functions.append(self.arena, declaration);
                    } else {
                        self.syncToLine();
                    }
                },
                .keyword_let => {
                    if (try self.constDecl()) |declaration| {
                        try constants.append(self.arena, declaration);
                    } else {
                        self.syncToLine();
                    }
                },
                .keyword_var => {
                    try self.diagnostics.add(
                        "luce.parse.top",
                        self.peek().span,
                        "top-level declarations are let constants; var lives inside functions",
                        .{},
                    );
                    self.syncToLine();
                },
                else => {
                    try self.diagnostics.add(
                        "luce.parse.top",
                        self.peek().span,
                        "expected import, let, struct, or func at top level",
                        .{},
                    );
                    self.syncToLine();
                },
            }
        }
        return .{
            .imports = try imports.toOwnedSlice(self.arena),
            .constants = try constants.toOwnedSlice(self.arena),
            .structs = try structs.toOwnedSlice(self.arena),
            .functions = try functions.toOwnedSlice(self.arena),
        };
    }

    /// let name = value at file scope — a constant declaration.
    fn constDecl(self: *Parser) Error!?ast.ConstDecl {
        const start = self.advance(); // let
        const name = (try self.expect(.identifier, "a constant name")) orelse return null;
        var annotation: ?ast.TypeName = null;
        if (self.accept(.colon) != null) {
            annotation = (try self.typeName()) orelse return null;
        }
        if ((try self.expect(.assign, "'=' with the constant's value")) == null) return null;
        const value = (try self.expression()) orelse return null;
        _ = try self.expect(.newline, "a newline after the constant");
        return .{
            .name = self.text(name),
            .annotation = annotation,
            .value = value,
            .span = .{ .start = start.span.start, .end = value.span().end },
        };
    }

    fn typeName(self: *Parser) Error!?ast.TypeName {
        const item = (try self.expect(.identifier, "a type name")) orelse return null;
        var written: ast.TypeName = .{ .name = self.text(item), .span = item.span };
        // module.Struct — one dotted level reaches an imported type.
        if (self.peekKind() == .dot and self.peekAhead(1) == .identifier) {
            _ = self.advance();
            const member = self.advance();
            written.name = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{
                written.name,
                self.text(member),
            });
            written.span = .{ .start = item.span.start, .end = member.span.end };
        }
        if (self.peekKind() != .left_paren) return written;
        _ = self.advance(); // (

        var arguments: std.ArrayList(ast.TypeName) = .empty;
        defer arguments.deinit(self.arena);
        var wildcards: u8 = 0;
        while (self.peekKind() != .right_paren and self.peekKind() != .end_of_file) {
            if (self.peekKind() == .identifier and std.mem.eql(u8, self.text(self.peek()), "_")) {
                const wildcard = self.advance();
                if (wildcards == 255) {
                    try self.diagnostics.add("luce.parse.type", wildcard.span, "too many array dimensions", .{});
                    return null;
                }
                wildcards += 1;
            } else {
                if (wildcards != 0) {
                    try self.diagnostics.add(
                        "luce.parse.type",
                        self.peek().span,
                        "array shape wildcards come last: Array(Int, _, _)",
                        .{},
                    );
                    return null;
                }
                const argument = (try self.typeName()) orelse return null;
                try arguments.append(self.arena, argument);
            }
            if (self.accept(.comma) == null) break;
        }
        const closing = (try self.expect(.right_paren, "')' closing the type")) orelse return null;
        written.arguments = try arguments.toOwnedSlice(self.arena);
        written.wildcards = wildcards;
        written.span = .{ .start = item.span.start, .end = closing.span.end };
        return written;
    }

    fn structDecl(self: *Parser) Error!?ast.StructDecl {
        const start = self.advance(); // struct
        const name = (try self.expect(.identifier, "a struct name")) orelse return null;
        if ((try self.expect(.colon, "':'")) == null) return null;
        if ((try self.expect(.newline, "a newline")) == null) return null;
        if ((try self.expect(.indent, "an indented struct body")) == null) return null;

        var fields: std.ArrayList(ast.Field) = .empty;
        defer fields.deinit(self.arena);
        var functions: std.ArrayList(ast.FuncDecl) = .empty;
        defer functions.deinit(self.arena);
        while (self.peekKind() != .dedent and self.peekKind() != .end_of_file) {
            if (self.accept(.newline) != null) continue;
            if (self.peekKind() == .keyword_func) {
                if (try self.funcDecl()) |declaration| {
                    try functions.append(self.arena, declaration);
                } else {
                    self.syncToLine();
                }
                continue;
            }
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
            .functions = try functions.toOwnedSlice(self.arena),
            .span = .{ .start = start.span.start, .end = name.span.end },
        };
    }

    fn funcDecl(self: *Parser) Error!?ast.FuncDecl {
        const start = self.advance(); // func
        const name = (try self.expect(.identifier, "a function name")) orelse return null;
        if ((try self.expect(.left_paren, "'('")) == null) return null;

        var parameters: std.ArrayList(ast.Parameter) = .empty;
        defer parameters.deinit(self.arena);
        while (self.peekKind() != .right_paren and self.peekKind() != .end_of_file) {
            const parameter_name = (try self.expect(.identifier, "a parameter name")) orelse
                return null;
            if ((try self.expect(.colon, "':' after the parameter name")) == null) return null;
            const mode: ast.ParameterMode = if (self.accept(.keyword_give) != null) .give else .borrow;
            const parameter_type = (try self.typeName()) orelse return null;
            try parameters.append(self.arena, .{
                .name = self.text(parameter_name),
                .mode = mode,
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
            .keyword_for => return self.forLoop(),
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
        // var name: Type — a late declaration; the slot starts at the
        // type's zero value (OWNERSHIP.md S40).  let always initializes.
        if (mutable and annotation != null and self.peekKind() == .newline) {
            _ = self.advance();
            return .{ .variable = .{
                .name = self.text(name),
                .annotation = annotation,
                .value = null,
                .span = .{ .start = start.span.start, .end = annotation.?.span.end },
            } };
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

    fn forLoop(self: *Parser) Error!?ast.Statement {
        const start = self.advance();
        const name = (try self.expect(.identifier, "a loop variable")) orelse return null;
        // for key, value in ...: — an optional second binding.  A
        // two-name loop is never a range, so this precedes that check.
        var value_name: ?[]const u8 = null;
        var value_token: ?Token = null;
        if (self.accept(.comma) != null) {
            const second = (try self.expect(.identifier, "a second loop variable")) orelse return null;
            value_name = self.text(second);
            value_token = second;
        }
        if ((try self.expect(.keyword_in, "'in'")) == null) return null;

        // for i in range(a, b): keeps its dedicated integer lowering.
        if (value_name == null and self.peekKind() == .identifier and
            std.mem.eql(u8, self.text(self.peek()), "range") and
            self.peekAhead(1) == .left_paren)
        {
            _ = self.advance(); // range
            _ = self.advance(); // (
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

        const iterable = (try self.expression()) orelse return null;
        const body = (try self.block()) orelse return null;
        const end = if (value_token) |token| token.span.end else name.span.end;
        return .{ .for_each = .{
            .name = self.text(name),
            .value_name = value_name,
            .iterable = iterable,
            .body = body,
            .span = .{ .start = start.span.start, .end = end },
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

    // PLACE = expression, or a bare expression statement.  The place
    // is parsed as an ordinary expression and then classified: a name,
    // one dotted field on a name, or an indexed expression.
    fn assignOrExpression(self: *Parser) Error!?ast.Statement {
        const left = (try self.expression()) orelse return null;
        const compound = compoundOp(self.peekKind());
        if (self.peekKind() != .assign and compound == null) {
            _ = try self.expect(.newline, "a newline after the expression");
            return .{ .expression = .{ .value = left, .span = left.span() } };
        }
        _ = self.advance(); // '=' or 'OP='

        const target = (try self.targetFrom(left)) orelse return null;
        const value = (try self.expression()) orelse return null;
        _ = try self.expect(.newline, "a newline after the assignment");
        return .{ .assign = .{
            .target = target,
            .compound = compound,
            .value = value,
            .span = .{ .start = target.span().start, .end = value.span().end },
        } };
    }

    /// The arithmetic operator behind a compound-assignment token, or
    /// null for a plain `=` or a non-assignment token.
    fn compoundOp(kind: Kind) ?ast.BinaryOp {
        return switch (kind) {
            .plus_assign => .add,
            .minus_assign => .subtract,
            .star_assign => .multiply,
            .slash_assign => .divide,
            .percent_assign => .remainder,
            else => null,
        };
    }

    fn targetFrom(self: *Parser, left: *ast.Expression) Error!?ast.Target {
        switch (left.*) {
            .name => |name| return .{ .name = .{ .text = name.text, .span = name.span } },
            .field => |field| {
                if (field.target.* == .name) {
                    return .{ .field = .{
                        .base = field.target.name.text,
                        .field = field.name,
                        .span = field.span,
                    } };
                }
                // A field access on something that isn't a plain name
                // (p.inner.n, cells[0].value): a nested place the
                // analyzer reads and rebuilds.
                return .{ .chain = .{ .place = left, .span = field.span } };
            },
            .index => |index| return .{ .index = .{
                .base = index.target,
                .indices = index.indices,
                .span = index.span,
            } },
            else => {
                try self.diagnostics.add(
                    "luce.parse.assign",
                    left.span(),
                    "cannot assign to this expression",
                    .{},
                );
                return null;
            },
        }
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
        // Every expression — grouping, prefix ops, call arguments —
        // re-enters here, so one guard covers all recursion paths.
        if (self.depth >= max_depth) {
            try self.diagnostics.add("luce.parse.nesting", self.peek().span, "expression nested too deeply", .{});
            return null;
        }
        self.depth += 1;
        defer self.depth -= 1;
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
        if (self.accept(.keyword_give)) |keyword| {
            const operand = (try self.unaryExpression()) orelse return null;
            return self.make(.{ .give = .{
                .operand = operand,
                .span = .{ .start = keyword.span.start, .end = operand.span().end },
            } });
        }
        if (self.accept(.keyword_copy)) |keyword| {
            const operand = (try self.unaryExpression()) orelse return null;
            return self.make(.{ .copy = .{
                .operand = operand,
                .span = .{ .start = keyword.span.start, .end = operand.span().end },
            } });
        }
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
        while (true) {
            if (self.accept(.dot) != null) {
                const field = (try self.expect(.identifier, "a field name after '.'")) orelse
                    return null;
                if (self.peekKind() == .left_paren) {
                    value = (try self.methodCall(value, field)) orelse return null;
                    continue;
                }
                const node = try self.arena.create(ast.Expression);
                node.* = .{ .field = .{
                    .target = value,
                    .name = self.text(field),
                    .span = .{ .start = value.span().start, .end = field.span.end },
                } };
                value = node;
                continue;
            }
            if (self.peekKind() == .left_bracket) {
                value = (try self.indexOrSlice(value)) orelse return null;
                continue;
            }
            return value;
        }
    }

    /// value[...]: an index (one or more comma-separated expressions)
    /// or a slice (a colon with either bound optional).
    fn indexOrSlice(self: *Parser, target: *ast.Expression) Error!?*ast.Expression {
        _ = self.advance(); // [

        // [:end] — a slice from the beginning.
        if (self.accept(.colon) != null) {
            var end: ?*ast.Expression = null;
            if (self.peekKind() != .right_bracket) {
                end = (try self.expression()) orelse return null;
            }
            const closing = (try self.expect(.right_bracket, "']'")) orelse return null;
            return self.make(.{ .slice_range = .{
                .target = target,
                .start = null,
                .end = end,
                .span = .{ .start = target.span().start, .end = closing.span.end },
            } });
        }

        const first = (try self.expression()) orelse return null;

        // [start:] and [start:end] — a slice.
        if (self.accept(.colon) != null) {
            var end: ?*ast.Expression = null;
            if (self.peekKind() != .right_bracket) {
                end = (try self.expression()) orelse return null;
            }
            const closing = (try self.expect(.right_bracket, "']'")) orelse return null;
            return self.make(.{ .slice_range = .{
                .target = target,
                .start = first,
                .end = end,
                .span = .{ .start = target.span().start, .end = closing.span.end },
            } });
        }

        // [i] or [r, c, ...] — an index.
        var indices: std.ArrayList(*ast.Expression) = .empty;
        defer indices.deinit(self.arena);
        try indices.append(self.arena, first);
        while (self.accept(.comma) != null) {
            const next = (try self.expression()) orelse return null;
            try indices.append(self.arena, next);
        }
        const closing = (try self.expect(.right_bracket, "']'")) orelse return null;
        return self.make(.{ .index = .{
            .target = target,
            .indices = try indices.toOwnedSlice(self.arena),
            .span = .{ .start = target.span().start, .end = closing.span.end },
        } });
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
            .fstring => {
                const item = self.advance();
                return self.expandFString(item);
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
            .left_bracket => return self.listLiteral(),
            .keyword_new => return self.newObject(),
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
        return self.namedCallExpression(self.text(callee), callee.span.start);
    }

    fn methodCall(self: *Parser, target: *ast.Expression, name: Token) Error!?*ast.Expression {
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
        return self.make(.{ .method = .{
            .target = target,
            .name = self.text(name),
            .arguments = try arguments.toOwnedSlice(self.arena),
            .span = .{ .start = target.span().start, .end = closing.span.end },
        } });
    }

    fn namedCallExpression(self: *Parser, callee: []const u8, start: usize) Error!?*ast.Expression {
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
            .callee = callee,
            .arguments = try arguments.toOwnedSlice(self.arena),
            .span = .{ .start = start, .end = closing.span.end },
        } });
    }

    fn listLiteral(self: *Parser) Error!?*ast.Expression {
        const opening = self.advance(); // [
        var elements: std.ArrayList(*ast.Expression) = .empty;
        defer elements.deinit(self.arena);
        while (self.peekKind() != .right_bracket and self.peekKind() != .end_of_file) {
            const element = (try self.expression()) orelse return null;
            try elements.append(self.arena, element);
            if (self.accept(.comma) == null) break;
        }
        const closing = (try self.expect(.right_bracket, "']' closing the list")) orelse return null;
        return self.make(.{ .list_literal = .{
            .elements = try elements.toOwnedSlice(self.arena),
            .span = .{ .start = opening.span.start, .end = closing.span.end },
        } });
    }

    /// new List(Int) | new Map(String, Int) | new Array(Int, DIM...) |
    /// new Builder().  Type arguments come first; an Array's trailing
    /// arguments are runtime dimension expressions.
    fn newObject(self: *Parser) Error!?*ast.Expression {
        const start = self.advance(); // new
        const name = (try self.expect(.identifier, "List, Map, Array, or Builder after new")) orelse
            return null;
        const kind = self.text(name);
        var written: ast.TypeName = .{ .name = kind, .span = name.span };
        var dims: std.ArrayList(*ast.Expression) = .empty;
        defer dims.deinit(self.arena);

        var closing_end = name.span.end;
        if (std.mem.eql(u8, kind, "Builder")) {
            if (self.accept(.left_paren) != null) {
                const closing = (try self.expect(.right_paren, "')' — Builder takes no arguments")) orelse
                    return null;
                closing_end = closing.span.end;
            }
        } else if (std.mem.eql(u8, kind, "List") or std.mem.eql(u8, kind, "Map")) {
            self.index -= 1; // rewind so typeName reads name(args...) whole
            written = (try self.typeName()) orelse return null;
            closing_end = written.span.end;
        } else if (std.mem.eql(u8, kind, "Array")) {
            if ((try self.expect(.left_paren, "'(' after Array")) == null) return null;
            const element = (try self.typeName()) orelse return null;
            const arguments = try self.arena.alloc(ast.TypeName, 1);
            arguments[0] = element;
            written.arguments = arguments;
            while (self.accept(.comma) != null) {
                const dimension = (try self.expression()) orelse return null;
                try dims.append(self.arena, dimension);
            }
            const closing = (try self.expect(.right_paren, "')' closing the Array dimensions")) orelse
                return null;
            closing_end = closing.span.end;
        } else {
            try self.diagnostics.add(
                "luce.parse.new",
                name.span,
                "new builds List, Map, Array, or Builder (structs are values: {s}(...))",
                .{kind},
            );
            return null;
        }

        return self.make(.{ .new_object = .{
            .type_name = written,
            .dims = try dims.toOwnedSlice(self.arena),
            .span = .{ .start = start.span.start, .end = closing_end },
        } });
    }

    fn make(self: *Parser, value: ast.Expression) Error!*ast.Expression {
        const node = try self.arena.create(ast.Expression);
        node.* = value;
        return node;
    }

    /// Expand f"...{expr}..." into a String-typed concatenation:
    /// literal chunks (escapes and `{{`/`}}` decoded) joined with `+`,
    /// each `{expr}` wrapped in `str(expr)`.  A hole is sub-parsed
    /// against the real source with absolute spans, so diagnostics
    /// inside interpolations point at the right bytes.
    fn expandFString(self: *Parser, item: Token) Error!?*ast.Expression {
        const raw = self.text(item);
        const inner = raw[2 .. raw.len - 1]; // between f" and the closing "
        const inner_start = item.span.start + 2;

        var result: ?*ast.Expression = null;
        var literal: std.ArrayList(u8) = .empty;
        defer literal.deinit(self.arena);

        var index: usize = 0;
        while (index < inner.len) {
            const character = inner[index];
            if (character == '{') {
                if (index + 1 < inner.len and inner[index + 1] == '{') {
                    try literal.append(self.arena, '{');
                    index += 2;
                    continue;
                }
                // Flush the literal chunk, then the interpolation.
                result = try self.appendLiteralChunk(result, item.span, literal.items);
                literal.clearRetainingCapacity();
                const close = self.matchBrace(inner, index + 1) orelse {
                    try self.diagnostics.add("luce.parse.fstring", item.span, "unmatched open brace in f-string", .{});
                    return null;
                };
                const hole = inner[index + 1 .. close];
                const hole_expr = (try self.subExpression(hole, inner_start + index + 1)) orelse return null;
                const wrapped = try self.wrapStr(hole_expr, item.span);
                result = try self.concat(result, wrapped);
                index = close + 1;
                continue;
            }
            if (character == '}') {
                if (index + 1 < inner.len and inner[index + 1] == '}') {
                    try literal.append(self.arena, '}');
                    index += 2;
                    continue;
                }
                try self.diagnostics.add("luce.parse.fstring", item.span, "unmatched close brace in f-string (double it for a literal)", .{});
                return null;
            }
            if (character == '\\' and index + 1 < inner.len) {
                index += 1;
                try literal.append(self.arena, switch (inner[index]) {
                    'n' => '\n',
                    't' => '\t',
                    '\\' => '\\',
                    '"' => '"',
                    else => inner[index],
                });
                index += 1;
                continue;
            }
            try literal.append(self.arena, character);
            index += 1;
        }
        result = try self.appendLiteralChunk(result, item.span, literal.items);
        // An empty f-string, or one that is all interpolation, still
        // yields a String.
        return result orelse try self.make(.{ .string_literal = .{ .decoded = "", .span = item.span } });
    }

    /// Fold a non-empty literal chunk into the running concatenation.
    fn appendLiteralChunk(self: *Parser, current: ?*ast.Expression, span: Span, chunk: []const u8) Error!?*ast.Expression {
        if (chunk.len == 0) return current;
        const owned = try self.arena.dupe(u8, chunk);
        const node = try self.make(.{ .string_literal = .{ .decoded = owned, .span = span } });
        return try self.concat(current, node);
    }

    /// left + right, or right alone when there is no left yet.
    fn concat(self: *Parser, left: ?*ast.Expression, right: *ast.Expression) Error!*ast.Expression {
        const base = left orelse return right;
        return self.make(.{ .binary = .{
            .op = .add,
            .left = base,
            .right = right,
            .span = .{ .start = base.span().start, .end = right.span().end },
        } });
    }

    /// str(expr) — the interpolation converts each hole to text.
    fn wrapStr(self: *Parser, expr: *ast.Expression, span: Span) Error!*ast.Expression {
        const arguments = try self.arena.alloc(ast.Argument, 1);
        arguments[0] = .{ .name = null, .value = expr, .span = expr.span() };
        return self.make(.{ .call = .{ .callee = "str", .arguments = arguments, .span = span } });
    }

    /// Find the `}` matching the `{` just before `from`, tracking
    /// nested braces and skipping nested string literals whole.
    fn matchBrace(self: *Parser, inner: []const u8, from: usize) ?usize {
        _ = self;
        var depth: usize = 1;
        var index = from;
        while (index < inner.len) {
            switch (inner[index]) {
                '"' => {
                    index += 1;
                    while (index < inner.len and inner[index] != '"') {
                        if (inner[index] == '\\') index += 1;
                        index += 1;
                    }
                    index += 1; // closing "
                },
                '{' => {
                    depth += 1;
                    index += 1;
                },
                '}' => {
                    depth -= 1;
                    if (depth == 0) return index;
                    index += 1;
                },
                else => index += 1,
            }
        }
        return null;
    }

    /// Parse one expression from an f-string hole.  The hole bytes are
    /// lexed on their own, then their spans are shifted to absolute so
    /// the sub-parser reads the real source and reports real
    /// positions.
    fn subExpression(self: *Parser, bytes: []const u8, offset: usize) Error!?*ast.Expression {
        var scratch = Diagnostics.init(self.arena);
        const raw_tokens = try lexer_mod.lex(self.arena, bytes, &scratch);
        if (scratch.hasErrors()) {
            try self.diagnostics.add("luce.parse.fstring", .{ .start = offset, .end = offset + bytes.len }, "malformed expression in f-string", .{});
            return null;
        }
        const tokens = try self.arena.alloc(Token, raw_tokens.len);
        for (raw_tokens, tokens) |source_token, *shifted| {
            shifted.* = .{ .kind = source_token.kind, .span = .{
                .start = source_token.span.start + offset,
                .end = source_token.span.end + offset,
            } };
        }
        var sub: Parser = .{
            .arena = self.arena,
            .source = self.source,
            .tokens = tokens,
            .diagnostics = self.diagnostics,
        };
        const expr = (try sub.expression()) orelse return null;
        if (sub.peekKind() != .newline and sub.peekKind() != .end_of_file) {
            try self.diagnostics.add("luce.parse.fstring", expr.span(), "an f-string hole is a single expression", .{});
            return null;
        }
        return expr;
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
        \\func scale_point(point: Point, factor: Float) -> Point:
        \\    return Point(
        \\        x = point.x * factor,
        \\        y = point.y * factor,
        \\    )
        \\
        \\func evaluate(input: Input, output: Output):
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
    try testing.expectEqualStrings("output", assign.target.field.base);
    try testing.expectEqualStrings("position", assign.target.field.field);
}

test "collections parse: types, new, literals, indexing, slices, for-in" {
    var parsed = try parseText(
        \\func main():
        \\    var xs: List(Int) = [1, 2, 3]
        \\    var m = new Map(String, List(Int))
        \\    var grid = new Array(Float, 4, 8)
        \\    var b = new Builder()
        \\    xs[0] = 10
        \\    grid[1, 2] = 3.5
        \\    m["ones"] = xs
        \\    let mid = xs[1:2]
        \\    let head = xs[:1]
        \\    let tail = xs[1:]
        \\    for x in xs:
        \\        append(b, str(x))
        \\
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diagnostics.count());
    const body = parsed.program.functions[0].body;

    const annotated = body.statements[0].variable;
    try testing.expectEqualStrings("List", annotated.annotation.?.name);
    try testing.expectEqualStrings("Int", annotated.annotation.?.arguments[0].name);
    try testing.expectEqual(@as(usize, 3), annotated.value.?.list_literal.elements.len);

    const map_new = body.statements[1].variable.value.?.new_object;
    try testing.expectEqualStrings("Map", map_new.type_name.name);
    try testing.expectEqualStrings("List", map_new.type_name.arguments[1].name);

    const array_new = body.statements[2].variable.value.?.new_object;
    try testing.expectEqualStrings("Array", array_new.type_name.name);
    try testing.expectEqual(@as(usize, 2), array_new.dims.len);

    try testing.expectEqual(@as(usize, 1), body.statements[4].assign.target.index.indices.len);
    try testing.expectEqual(@as(usize, 2), body.statements[5].assign.target.index.indices.len);
    try testing.expect(body.statements[7].let.value.* == .slice_range);
    try testing.expect(body.statements[8].let.value.slice_range.start == null);
    try testing.expect(body.statements[9].let.value.slice_range.end == null);
    try testing.expectEqualStrings("x", body.statements[10].for_each.name);
}

test "late declarations parse: var with annotation only" {
    var parsed = try parseText(
        \\func main():
        \\    var report: Builder
        \\    var grid: Array(Int, _, _)
        \\    var count: Int
        \\    report = new Builder()
        \\
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diagnostics.count());
    const body = parsed.program.functions[0].body;
    try testing.expect(body.statements[0].variable.value == null);
    try testing.expectEqualStrings("Builder", body.statements[0].variable.annotation.?.name);
    try testing.expect(body.statements[1].variable.value == null);
    try testing.expect(body.statements[2].variable.value == null);

    // let never late-declares, and var needs a type or a value.
    var bad_let = try parseText(
        \\func main():
        \\    let frozen: Int
        \\
    );
    defer bad_let.deinit();
    try testing.expect(bad_let.diagnostics.count() > 0);
    var bad_var = try parseText(
        \\func main():
        \\    var untyped
        \\
    );
    defer bad_var.deinit();
    try testing.expect(bad_var.diagnostics.count() > 0);
}

test "array shape wildcards parse in annotations" {
    var parsed = try parseText(
        \\func total(grid: Array(Int, _, _)) -> Int:
        \\    return dim(grid, 0)
        \\
        \\func main():
        \\    return
        \\
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diagnostics.count());
    const parameter = parsed.program.functions[0].parameters[0];
    try testing.expectEqualStrings("Array", parameter.type_name.name);
    try testing.expectEqual(@as(u8, 2), parameter.type_name.wildcards);
}

test "struct bodies parse fields and namespaced functions" {
    var parsed = try parseText(
        \\struct Helpers:
        \\    value: Int
        \\    func double(value: Int) -> Int:
        \\        return value * 2
        \\
        \\func evaluate(input: Input, output: Output):
        \\    output.value = Helpers.double(input.value)
        \\
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diagnostics.count());
    try testing.expectEqual(@as(usize, 1), parsed.program.structs[0].fields.len);
    try testing.expectEqual(@as(usize, 1), parsed.program.structs[0].functions.len);
    // Dotted calls parse as method nodes; the analyzer decides whether
    // the chain names a namespace or a value.
    const dotted = parsed.program.functions[0].body.statements[0].assign.value.method;
    try testing.expectEqualStrings("double", dotted.name);
    try testing.expectEqualStrings("Helpers", dotted.target.name.text);
}

test "method calls parse on any postfix expression" {
    var parsed = try parseText(
        \\func main():
        \\    var xs = [3, 1]
        \\    xs.append(2)
        \\    xs.sort()
        \\    let n = xs[0:2].find(3)
        \\    let word = "Hello".lower()
        \\
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diagnostics.count());
    const body = parsed.program.functions[0].body;
    const call = body.statements[1].expression.value.method;
    try testing.expectEqualStrings("append", call.name);
    try testing.expect(body.statements[3].let.value.method.target.* == .slice_range);
    try testing.expect(body.statements[4].let.value.method.target.* == .string_literal);
}

test "deeply nested expressions report instead of overflowing the stack" {
    const allocator = testing.allocator;
    var opens: std.ArrayList(u8) = .empty;
    defer opens.deinit(allocator);
    try opens.appendSlice(allocator, "func main():\n    let x = ");
    for (0..5000) |_| try opens.append(allocator, '(');
    try opens.append(allocator, '1');
    for (0..5000) |_| try opens.append(allocator, ')');
    try opens.append(allocator, '\n');

    var parsed = try parseText(opens.items);
    defer parsed.deinit();
    // The point is that this returns at all (no crash); it must also
    // have reported the nesting limit.
    var saw_nesting = false;
    for (0..parsed.diagnostics.count()) |index| {
        if (std.mem.eql(u8, parsed.diagnostics.at(index).?.code, "luce.parse.nesting")) saw_nesting = true;
    }
    try testing.expect(saw_nesting);
}

test "fuzz: parsing any bytes terminates with spans inside the source" {
    try testing.fuzz({}, parseAnything, .{ .corpus = &.{
        "func main():\n    let x = 1 + 2\n",
        "func f(a: give List(Int)) -> Int:\n    return len(a)\n",
        "struct P:\n    x: Float\n",
        "let k = 3\n",
    } });
}

fn parseAnything(_: void, smith: *testing.Smith) anyerror!void {
    var buffer: [512]u8 = undefined;
    const length = smith.sliceWeightedBytes(&buffer, &.{
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .rangeAtMost(u8, 0x20, 0x7e, 5),
        .value(u8, ' ', 5),
        .value(u8, '\n', 5),
        .value(u8, '(', 3),
        .value(u8, ')', 3),
        .value(u8, ':', 2),
    });
    const source = buffer[0..length];

    var parsed = try parseText(source);
    defer parsed.deinit();

    // Every produced diagnostic points inside the source (parsing
    // itself terminating is the other half of the property — a hang
    // or crash fails the test by never returning).
    for (0..parsed.diagnostics.count()) |index| {
        const item = parsed.diagnostics.at(index).?;
        try testing.expect(item.span.start <= item.span.end);
        try testing.expect(item.span.end <= source.len);
    }
}

test "ownership verbs parse: give/copy expressions and give parameters" {
    var parsed = try parseText(
        \\func stash(index: Map(String, List(Int)), hits: give List(Int)):
        \\    index["latest"] = give hits
        \\
        \\func main():
        \\    var mine = [1, 2]
        \\    let moved = give mine
        \\    let doubled = copy moved
        \\    var index = new Map(String, List(Int))
        \\    stash(index, give doubled)
        \\
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diagnostics.count());

    const stash = parsed.program.functions[0];
    try testing.expectEqual(ast.ParameterMode.borrow, stash.parameters[0].mode);
    try testing.expectEqual(ast.ParameterMode.give, stash.parameters[1].mode);
    try testing.expect(stash.body.statements[0].assign.value.* == .give);

    const body = parsed.program.functions[1].body;
    const moved = body.statements[1].let.value;
    try testing.expect(moved.* == .give);
    try testing.expectEqualStrings("mine", moved.give.operand.name.text);
    try testing.expect(body.statements[2].let.value.* == .copy);
    const call_arguments = body.statements[4].expression.value.call.arguments;
    try testing.expect(call_arguments[1].value.* == .give);
}

test "top-level let constants parse; top-level var is refused" {
    var parsed = try parseText(
        \\let width = 80
        \\let banner: String = "loom " + version
        \\let version = "2.0"
        \\
        \\func main():
        \\    let unused = width
        \\
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diagnostics.count());
    try testing.expectEqual(@as(usize, 3), parsed.program.constants.len);
    try testing.expectEqualStrings("width", parsed.program.constants[0].name);
    try testing.expect(parsed.program.constants[0].annotation == null);
    try testing.expectEqualStrings("String", parsed.program.constants[1].annotation.?.name);
    try testing.expect(parsed.program.constants[1].value.* == .binary);

    var refused = try parseText(
        \\var counter = 0
        \\
        \\func main():
        \\    return
        \\
    );
    defer refused.deinit();
    try testing.expect(refused.diagnostics.count() > 0);
    try testing.expectEqualStrings("luce.parse.top", refused.diagnostics.at(0).?.code);
}

test "control flow, precedence, and elif chains parse" {
    var parsed = try parseText(
        \\func evaluate(input: Input, output: Output):
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
        \\func evaluate(input: Input, output: Output):
        \\    let = 3
        \\    let ok = 1
        \\    output.value = ok +
        \\
        \\func helper() -> Int:
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
        \\func evaluate(input: Input, output: Output):
        \\    output.text = "line\none\ttab \"quoted\""
        \\
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diagnostics.count());
    const value = parsed.program.functions[0].body.statements[0].assign.value;
    try testing.expectEqualStrings("line\none\ttab \"quoted\"", value.string_literal.decoded);
}
