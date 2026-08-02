//! The Luce parser: expressions.
//!
//! The Pratt expression parser, written as standalone functions that
//! operate on grammar.Parser, together with the f-string expansion the
//! literal grammar needs.

const std = @import("std");
const grammar = @import("grammar.zig");
const source_mod = @import("../01_source.zig");
const lex_mod = @import("../02_lex.zig");
const ast = @import("ast.zig");
const diagnostics_mod = @import("../support/diagnostics.zig");

const Parser = grammar.Parser;
const Span = source_mod.Span;
const Token = lex_mod.Token;
const Kind = lex_mod.Kind;
const Diagnostics = diagnostics_mod.Diagnostics;
const Error = grammar.Error;

pub const max_depth = 512;

// Expressions ---------------------------------------------------------------

pub const Precedence = enum(u8) {
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

pub fn expression(self: *Parser) Error!?*ast.Expression {
    // Every expression — grouping, prefix ops, call arguments —
    // re-enters here, so one guard covers all recursion paths.
    if (self.depth >= max_depth) {
        try self.diagnostics.add("luce.parse.nesting", self.peek().span, "expression nested too deeply", .{});
        return null;
    }
    self.depth += 1;
    defer self.depth -= 1;
    return binaryExpression(self, @intFromEnum(Precedence.logic_or));
}

fn binaryExpression(self: *Parser, minimum: u8) Error!?*ast.Expression {
    var left = (try unaryExpression(self)) orelse return null;
    while (true) {
        const precedence = binaryPrecedence(self.peekKind());
        if (@intFromEnum(precedence) < minimum or precedence == .none) return left;
        const operator = self.advance();
        const right = (try binaryExpression(self, @intFromEnum(precedence) + 1)) orelse
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
        const operand = (try unaryExpression(self)) orelse return null;
        return make(self, .{ .give = .{
            .operand = operand,
            .span = .{ .start = keyword.span.start, .end = operand.span().end },
        } });
    }
    if (self.accept(.keyword_copy)) |keyword| {
        const operand = (try unaryExpression(self)) orelse return null;
        return make(self, .{ .copy = .{
            .operand = operand,
            .span = .{ .start = keyword.span.start, .end = operand.span().end },
        } });
    }
    if (self.accept(.keyword_not)) |operator| {
        const operand = (try unaryExpression(self)) orelse return null;
        const node = try self.arena.create(ast.Expression);
        node.* = .{ .unary = .{
            .op = .logic_not,
            .operand = operand,
            .span = .{ .start = operator.span.start, .end = operand.span().end },
        } };
        return node;
    }
    if (self.accept(.minus)) |operator| {
        const operand = (try unaryExpression(self)) orelse return null;
        const node = try self.arena.create(ast.Expression);
        node.* = .{ .unary = .{
            .op = .negate,
            .operand = operand,
            .span = .{ .start = operator.span.start, .end = operand.span().end },
        } };
        return node;
    }
    return postfixExpression(self);
}

fn postfixExpression(self: *Parser) Error!?*ast.Expression {
    var value = (try primaryExpression(self)) orelse return null;
    while (true) {
        if (self.accept(.dot) != null) {
            const field = (try self.expect(.identifier, "a field name after '.'")) orelse
                return null;
            if (self.peekKind() == .left_paren) {
                value = (try methodCall(self, value, field)) orelse return null;
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
            value = (try indexOrSlice(self, value)) orelse return null;
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
            end = (try expression(self)) orelse return null;
        }
        const closing = (try self.expect(.right_bracket, "']'")) orelse return null;
        return make(self, .{ .slice_range = .{
            .target = target,
            .start = null,
            .end = end,
            .span = .{ .start = target.span().start, .end = closing.span.end },
        } });
    }

    const first = (try expression(self)) orelse return null;

    // [start:] and [start:end] — a slice.
    if (self.accept(.colon) != null) {
        var end: ?*ast.Expression = null;
        if (self.peekKind() != .right_bracket) {
            end = (try expression(self)) orelse return null;
        }
        const closing = (try self.expect(.right_bracket, "']'")) orelse return null;
        return make(self, .{ .slice_range = .{
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
        const next = (try expression(self)) orelse return null;
        try indices.append(self.arena, next);
    }
    const closing = (try self.expect(.right_bracket, "']'")) orelse return null;
    return make(self, .{ .index = .{
        .target = target,
        .indices = try indices.toOwnedSlice(self.arena),
        .span = .{ .start = target.span().start, .end = closing.span.end },
    } });
}

fn primaryExpression(self: *Parser) Error!?*ast.Expression {
    switch (self.peekKind()) {
        .int_literal => {
            const item = self.advance();
            return make(self, .{ .int_literal = .{ .text = self.text(item), .span = item.span } });
        },
        .float_literal => {
            const item = self.advance();
            return make(self, .{ .float_literal = .{ .text = self.text(item), .span = item.span } });
        },
        .keyword_true => {
            const item = self.advance();
            return make(self, .{ .bool_literal = .{ .value = true, .span = item.span } });
        },
        .keyword_false => {
            const item = self.advance();
            return make(self, .{ .bool_literal = .{ .value = false, .span = item.span } });
        },
        .string_literal => {
            const item = self.advance();
            const decoded = try decodeString(self, item);
            return make(self, .{ .string_literal = .{ .decoded = decoded, .span = item.span } });
        },
        .fstring => {
            const item = self.advance();
            return expandFString(self, item);
        },
        .identifier => {
            const item = self.advance();
            if (self.peekKind() == .left_paren) {
                return callExpression(self, item);
            }
            return make(self, .{ .name = .{ .text = self.text(item), .span = item.span } });
        },
        .left_paren => {
            _ = self.advance();
            const inner = (try expression(self)) orelse return null;
            if ((try self.expect(.right_paren, "')'")) == null) return null;
            return inner;
        },
        .left_bracket => return listLiteral(self),
        .keyword_new => return newObject(self),
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
    return namedCallExpression(self, self.text(callee), callee.span.start);
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
        const value = (try expression(self)) orelse return null;
        try arguments.append(self.arena, .{
            .name = argument_name,
            .value = value,
            .span = value.span(),
        });
        if (self.accept(.comma) == null) break;
    }
    const closing = (try self.expect(.right_paren, "')'")) orelse return null;
    return make(self, .{ .method = .{
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
        const value = (try expression(self)) orelse return null;
        try arguments.append(self.arena, .{
            .name = argument_name,
            .value = value,
            .span = value.span(),
        });
        if (self.accept(.comma) == null) break;
    }
    const closing = (try self.expect(.right_paren, "')'")) orelse return null;
    return make(self, .{ .call = .{
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
        const element = (try expression(self)) orelse return null;
        try elements.append(self.arena, element);
        if (self.accept(.comma) == null) break;
    }
    const closing = (try self.expect(.right_bracket, "']' closing the list")) orelse return null;
    return make(self, .{ .list_literal = .{
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
            const dimension = (try expression(self)) orelse return null;
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

    return make(self, .{ .new_object = .{
        .type_name = written,
        .dims = try dims.toOwnedSlice(self.arena),
        .span = .{ .start = start.span.start, .end = closing_end },
    } });
}

pub fn make(self: *Parser, value: ast.Expression) Error!*ast.Expression {
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
            result = try appendLiteralChunk(self, result, item.span, literal.items);
            literal.clearRetainingCapacity();
            const close = matchBrace(self, inner, index + 1) orelse {
                try self.diagnostics.add("luce.parse.fstring", item.span, "unmatched open brace in f-string", .{});
                return null;
            };
            const hole = inner[index + 1 .. close];
            const hole_expr = (try subExpression(self, hole, inner_start + index + 1)) orelse return null;
            const wrapped = try wrapStr(self, hole_expr, item.span);
            result = try concat(self, result, wrapped);
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
    result = try appendLiteralChunk(self, result, item.span, literal.items);
    // An empty f-string, or one that is all interpolation, still
    // yields a String.
    return result orelse try make(self, .{ .string_literal = .{ .decoded = "", .span = item.span } });
}

/// Fold a non-empty literal chunk into the running concatenation.
fn appendLiteralChunk(self: *Parser, current: ?*ast.Expression, span: Span, chunk: []const u8) Error!?*ast.Expression {
    if (chunk.len == 0) return current;
    const owned = try self.arena.dupe(u8, chunk);
    const node = try make(self, .{ .string_literal = .{ .decoded = owned, .span = span } });
    return try concat(self, current, node);
}

/// left + right, or right alone when there is no left yet.
fn concat(self: *Parser, left: ?*ast.Expression, right: *ast.Expression) Error!*ast.Expression {
    const base = left orelse return right;
    return make(self, .{ .binary = .{
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
    return make(self, .{ .call = .{ .callee = "str", .arguments = arguments, .span = span } });
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
    const raw_tokens = try lex_mod.lex(self.arena, bytes, &scratch);
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
    const expr = (try expression(&sub)) orelse return null;
    if (sub.peekKind() != .newline and sub.peekKind() != .end_of_file) {
        try self.diagnostics.add("luce.parse.fstring", expr.span(), "an f-string hole is a single expression", .{});
        return null;
    }
    return expr;
}

pub fn decodeString(self: *Parser, item: Token) Error![]const u8 {
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
