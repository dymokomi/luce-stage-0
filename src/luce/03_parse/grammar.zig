//! The Luce parser: declarations and statements.
//!
//! Handwritten recursive descent over the declaration and statement
//! grammar; the Pratt expression parser it calls into lives in
//! expressions.zig.  The parser recovers at line and block boundaries
//! so one edit produces several useful diagnostics instead of one.

const std = @import("std");
const source_mod = @import("../01_source.zig");
const lex_mod = @import("../02_lex.zig");
const ast = @import("ast.zig");
const diagnostics_mod = @import("../support/diagnostics.zig");
const expr = @import("expressions.zig");

const Allocator = std.mem.Allocator;
const Span = source_mod.Span;
const Token = lex_mod.Token;
const Kind = lex_mod.Kind;
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
    const tokens = try lex_mod.lex(temporary, source, diagnostics);
    defer temporary.free(tokens);

    var parser: Parser = .{
        .arena = arena,
        .source = source,
        .tokens = tokens,
        .diagnostics = diagnostics,
    };
    return parser.program();
}

pub const Parser = struct {
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

    pub const max_depth = expr.max_depth;

    // Token helpers --------------------------------------------------------

    pub fn peek(self: *const Parser) Token {
        return self.tokens[self.index];
    }

    pub fn peekKind(self: *const Parser) Kind {
        return self.tokens[self.index].kind;
    }

    pub fn peekAhead(self: *const Parser, ahead: usize) Kind {
        const at = @min(self.index + ahead, self.tokens.len - 1);
        return self.tokens[at].kind;
    }

    pub fn advance(self: *Parser) Token {
        const item = self.tokens[self.index];
        if (self.index + 1 < self.tokens.len) self.index += 1;
        return item;
    }

    pub fn accept(self: *Parser, kind: Kind) ?Token {
        if (self.peekKind() != kind) return null;
        return self.advance();
    }

    pub fn expect(self: *Parser, kind: Kind, what: []const u8) Error!?Token {
        if (self.accept(kind)) |item| return item;
        try self.diagnostics.add(
            "luce.parse.expected",
            self.peek().span,
            "expected {s}",
            .{what},
        );
        return null;
    }

    pub fn text(self: *const Parser, item: Token) []const u8 {
        return item.span.slice(self.source);
    }

    // Skip to the start of the next line at the current block level.
    pub fn syncToLine(self: *Parser) void {
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

    pub fn program(self: *Parser) Error!ast.Program {
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
    pub fn constDecl(self: *Parser) Error!?ast.ConstDecl {
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

    pub fn typeName(self: *Parser) Error!?ast.TypeName {
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

    pub fn structDecl(self: *Parser) Error!?ast.StructDecl {
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

    pub fn funcDecl(self: *Parser) Error!?ast.FuncDecl {
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

    pub fn block(self: *Parser) Error!?ast.Block {
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

    pub fn statement(self: *Parser) Error!?ast.Statement {
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

    pub fn binding(self: *Parser, mutable: bool) Error!?ast.Statement {
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

    pub fn conditional(self: *Parser) Error!?ast.Statement {
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

    pub fn whileLoop(self: *Parser) Error!?ast.Statement {
        const start = self.advance();
        const condition = (try self.expression()) orelse return null;
        const body = (try self.block()) orelse return null;
        return .{ .while_loop = .{
            .condition = condition,
            .body = body,
            .span = .{ .start = start.span.start, .end = condition.span().end },
        } };
    }

    pub fn forLoop(self: *Parser) Error!?ast.Statement {
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

    pub fn returnStatement(self: *Parser) Error!?ast.Statement {
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
    pub fn assignOrExpression(self: *Parser) Error!?ast.Statement {
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

    pub fn targetFrom(self: *Parser, left: *ast.Expression) Error!?ast.Target {
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

    // Expression entry — delegates to expressions.zig.
    pub fn expression(self: *Parser) Error!?*ast.Expression {
        return expr.expression(self);
    }

    pub fn make(self: *Parser, value: ast.Expression) Error!*ast.Expression {
        return expr.make(self, value);
    }
};
