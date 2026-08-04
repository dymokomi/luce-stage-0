//! The Luce parser: expressions.
//!
//! The Pratt expression parser, written as standalone functions that
//! operate on grammar.Parser, together with the f-string expansion the
//! literal grammar needs.
//!
//! Every recursive entry passes through `Parser.enter`, so grouping,
//! prefix chains, call arguments, and interpolation holes all share
//! one bound on native stack use.

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

// ---------------------------------------------------------------------------
// Precedence, and what an expression may start with
// ---------------------------------------------------------------------------

pub const Precedence = enum(u8) {
    none = 0,
    logic_or = 1,
    logic_and = 2,
    comparison = 3,
    /// `a else b` and `a catch b`, between comparison and arithmetic:
    /// `x else 0 > 5` compares the fallback and `x else n + 1` falls
    /// back to the sum, which is where Swift puts `??` and for the
    /// same reasons.  `catch` sits at the same level because it is the
    /// same shape of question — a value, or a value instead — and the
    /// two never meet in one expression.
    coalesce = 4,
    additive = 5,
    multiplicative = 6,
};

fn binaryPrecedence(kind: Kind) Precedence {
    return switch (kind) {
        .keyword_or => .logic_or,
        .keyword_and => .logic_and,
        .equal, .not_equal, .less, .less_equal, .greater, .greater_equal => .comparison,
        .keyword_else, .keyword_catch => .coalesce,
        .plus, .minus => .additive,
        .star, .slash, .slash_slash, .percent => .multiplicative,
        else => .none,
    };
}

/// True for every token that can begin an expression.  Recovery uses
/// it to tell "the reader forgot a separator" from "the reader forgot
/// a closing bracket": only the former is followed by something that
/// could have been the next element.
pub fn startsExpression(kind: Kind) bool {
    return switch (kind) {
        .int_literal,
        .float_literal,
        .string_literal,
        .fstring,
        .identifier,
        .keyword_true,
        .keyword_false,
        .keyword_none,
        .keyword_new,
        .keyword_not,
        .keyword_give,
        .keyword_copy,
        .keyword_try,
        .minus,
        .left_paren,
        .left_bracket,
        => true,
        else => false,
    };
}

fn binaryOp(kind: Kind) ast.BinaryOp {
    return switch (kind) {
        .keyword_or => .logic_or,
        .keyword_and => .logic_and,
        .keyword_else => .coalesce,
        .keyword_catch => .catch_error,
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
        .slash_slash => .floor_divide,
        .percent => .modulo,
        else => unreachable,
    };
}

// ---------------------------------------------------------------------------
// The Pratt loop: binary, unary, postfix
// ---------------------------------------------------------------------------

pub fn expression(self: *Parser) Error!?*ast.Expression {
    // Grouping, call arguments, indices and interpolation holes all
    // re-enter here, so one guard covers those recursion paths.
    if (!try self.enter("expression")) return null;
    defer self.leave();
    return binaryExpression(self, @intFromEnum(Precedence.logic_or));
}

fn binaryExpression(self: *Parser, minimum: u8) Error!?*ast.Expression {
    var left = (try unaryExpression(self)) orelse return null;
    // The comparison operators do not associate (docs/LANGUAGE.md):
    // `a < b < c` is Python's chain to every reader who writes it and
    // `(a < b) < c` to the grammar, so it is refused where it is
    // written.  The first comparison of *this* level is remembered;
    // a parenthesized `(a < b) == (c < d)` recurses into its own
    // call and so starts its own chain, which is why comparing two
    // Bools stays legal.
    var first_comparison: ?Token = null;
    while (true) {
        // `call catch:` opens a handler block and belongs to the
        // statement, not to this expression.  One token of lookahead
        // separates the two spellings of `catch`, and nothing else
        // can follow the operator form with a colon.
        if (self.peekKind() == .keyword_catch and self.peekAhead(1) == .colon) return left;
        // A `!` never joins two expressions.  Saying so here rather
        // than letting the statement end and complain about a stray
        // token keeps the answer the one the reader needs, in both
        // the `3 ! 4` and the `!x` position.
        if (self.peekKind() == .bang) {
            try bangIsNotAnOperator(self);
            return null;
        }
        // Before the token is read as an operator of ours: `i++` and
        // `a === b` both start with one that is, and answering them
        // as the operator plus a broken operand names the wrong half.
        if (foreignOperator(self)) |found| {
            try reportForeignOperator(self, found);
            return null;
        }
        const precedence = binaryPrecedence(self.peekKind());
        if (@intFromEnum(precedence) < minimum or precedence == .none) return left;
        const operator = self.advance();
        // Everything associates left except `else`, which associates
        // right so `a else b else c` is a real chain: `b else c` is the
        // fallback `a` reaches for, and each link may be optional.
        const next_minimum = @intFromEnum(precedence) + @intFromBool(precedence != .coalesce);
        const right = (try binaryExpression(self, next_minimum)) orelse
            return null;
        if (precedence == .comparison) {
            if (first_comparison) |earlier| {
                try chainedComparison(self, left, earlier, operator, right);
                return null;
            }
            first_comparison = operator;
        }
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

// ---------------------------------------------------------------------------
// Operators other languages have
// ---------------------------------------------------------------------------
//
// `x++`, `a === b`, `a <> b` are all written by people arriving from
// C, JavaScript or Python, and every one of them used to be answered
// by naming the *second* character: "expected an expression, found
// '+'".  That is true and useless.  The lexer splits these into two
// ordinary tokens because Luce has no such operator, so the pair is
// still sitting there adjacent in the stream and can be read back.
//
// The bar for claiming a pair is that it can never be anything else.
// `a++b` cannot (there is no prefix `+`), so `++` is always a
// diagnostic.  `a--b` *is* `a - (-b)` and compiles today, and `--a` is
// a double negation, so `--` is claimed only where nothing follows it
// — which is exactly the postfix decrement a C hand writes and the one
// spelling the existing grammar has no reading for.

/// A foreign operator, and what Luce writes instead.
const Foreign = struct {
    /// As written, for the message and to size the span.
    written: []const u8,
    /// The rest of the sentence, after "there is no 'X' operator".
    instead: []const u8,
    /// True when the pair is only foreign with no operand after it:
    /// `i--` is a decrement, `a--b` is a subtraction of a negation.
    postfix_only: bool = false,
};

fn foreignPair(first: Kind, second: Kind) ?Foreign {
    return switch (first) {
        .plus => switch (second) {
            .plus => .{ .written = "++", .instead = "write 'x += 1' to increment" },
            else => null,
        },
        .minus => switch (second) {
            .minus => .{
                .written = "--",
                .instead = "write 'x -= 1' to decrement",
                .postfix_only = true,
            },
            else => null,
        },
        .star => switch (second) {
            .star => .{ .written = "**", .instead = "import std.math and call math.pow(x, y), or math.ipow(x, y) for Int" },
            else => null,
        },
        .equal => switch (second) {
            .assign => .{ .written = "===", .instead = "'==' compares, and compares by value" },
            else => null,
        },
        .not_equal => switch (second) {
            .assign => .{ .written = "!==", .instead = "'!=' compares, and compares by value" },
            else => null,
        },
        .less => switch (second) {
            .greater => .{ .written = "<>", .instead = "write '!=' to compare for difference" },
            .less => .{ .written = "<<", .instead = "Luce has no bitwise operators; multiply by a power of two" },
            else => null,
        },
        .greater => switch (second) {
            .greater => .{ .written = ">>", .instead = "Luce has no bitwise operators; divide by a power of two" },
            else => null,
        },
        else => null,
    };
}

/// The foreign operator starting at the current token, if there is
/// one.  The two tokens must **touch** — `a < > b` is two operators
/// the reader spaced out, not one they meant — and a `postfix_only`
/// pair must have nothing that could be an operand after it.
fn foreignOperator(self: *Parser) ?Foreign {
    const first = self.peek();
    const found = foreignPair(first.kind, self.peekAhead(1)) orelse return null;
    if (self.tokenAhead(1).span.start != first.span.end) return null;
    if (found.postfix_only and startsExpression(self.peekAhead(2))) return null;
    return found;
}

/// Report the foreign operator at the current token and consume both
/// halves, so the statement ends here rather than reporting the second
/// character again as a stray one.  One habit, one diagnostic.
fn reportForeignOperator(self: *Parser, found: Foreign) Error!void {
    const first = self.advance();
    const second = self.advance();
    try self.report(
        "luce.parse.expression",
        .{ .start = first.span.start, .end = second.span.end },
        "there is no '{s}' operator: {s}",
        .{ found.written, found.instead },
    );
}

/// The one thing `!` is for, said in the one place a reader can meet
/// it by accident.  It marks a fallible return type (`-> T!`) and is
/// never an operator; `not` is the negation, and `!=` lexes whole.
fn bangIsNotAnOperator(self: *Parser) Error!void {
    try self.report(
        "luce.parse.expression",
        self.peek().span,
        "there is no '!' operator: write 'not x' for negation; '!' marks a return type that can fail ('-> T!')",
        .{},
    );
}

/// `a < b < c`.  Python reads it as `a < b and b < c`; this grammar
/// reads it as `(a < b) < c`, which is a Bool compared with an Int and
/// so always a type error one stage later.  Report it here, with the
/// `and` form written out in the reader's own words when their source
/// is short enough to quote back.
fn chainedComparison(
    self: *Parser,
    left: *ast.Expression,
    earlier: Token,
    operator: Token,
    right: *ast.Expression,
) Error!void {
    const middle = if (left.* == .binary) self.quotable(left.binary.right.span()) else null;
    if (middle) |mid| {
        if (self.quotable(left.span())) |whole| {
            if (self.quotable(right.span())) |tail| {
                return self.report(
                    "luce.parse.chain",
                    operator.span,
                    "chained comparison: write '{s} and {s} {s} {s}'",
                    .{ whole, mid, self.text(operator), tail },
                );
            }
        }
    }
    try self.report(
        "luce.parse.chain",
        operator.span,
        "chained comparison: '{s}' does not chain with '{s}'; write 'a {s} b and b {s} c'",
        .{ self.text(earlier), self.text(operator), self.text(earlier), self.text(operator) },
    );
}

/// The prefix operators, right-associative and all at one precedence:
/// `give`, `copy`, `not`, and unary `-`.  Guarded, because a chain of
/// them recurses once per operator.
fn unaryExpression(self: *Parser) Error!?*ast.Expression {
    if (!try self.enter("expression")) return null;
    defer self.leave();

    // `++i` in front of an operand.  Not `--i`, which is the double
    // negation this grammar already reads and answers correctly.
    if (foreignOperator(self)) |found| {
        try reportForeignOperator(self, found);
        return null;
    }

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
    if (self.accept(.keyword_try)) |keyword| {
        const operand = (try unaryExpression(self)) orelse return null;
        return make(self, .{ .try_call = .{
            .operand = operand,
            .span = .{ .start = keyword.span.start, .end = operand.span().end },
        } });
    }
    if (self.accept(.keyword_not)) |operator| {
        const operand = (try unaryExpression(self)) orelse return null;
        // `not a == b` is `(not a) == b` here and `not (a == b)` in
        // Python, and with Bool operands both parse and disagree
        // (docs/LANGUAGE.md).  A silently different answer is worse
        // than an error, so the reader is asked which one they meant.
        if (binaryPrecedence(self.peekKind()) == .comparison) {
            try notBeforeComparison(self, operator, operand, self.peek());
            return null;
        }
        return make(self, .{ .unary = .{
            .op = .logic_not,
            .operand = operand,
            .span = .{ .start = operator.span.start, .end = operand.span().end },
        } });
    }
    if (self.accept(.minus)) |operator| {
        const operand = (try unaryExpression(self)) orelse return null;
        return make(self, .{ .unary = .{
            .op = .negate,
            .operand = operand,
            .span = .{ .start = operator.span.start, .end = operand.span().end },
        } });
    }
    return postfixExpression(self);
}

/// `not` is a prefix operator and so binds tighter than every binary
/// one, comparison included — Zig's and C's reading, not Python's.
/// Both readings are legal Bool expressions with different answers, so
/// the parser refuses to pick and names the two spellings.
fn notBeforeComparison(
    self: *Parser,
    keyword: Token,
    operand: *ast.Expression,
    operator: Token,
) Error!void {
    const op = self.text(operator);
    const name = self.quotable(operand.span()) orelse "a";
    try self.report(
        "luce.parse.precedence",
        keyword.span,
        "'not' binds tighter than '{s}': write '(not {s}) {s} …' for this reading, " ++
            "or 'not ({s} {s} …)' for Python's",
        .{ op, name, op, name, op },
    );
}

fn postfixExpression(self: *Parser) Error!?*ast.Expression {
    var value = (try primaryExpression(self)) orelse return null;
    while (true) {
        if (self.accept(.dot) != null) {
            const field = (try self.expect(.identifier, "a field or function name after '.'")) orelse
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
/// `s[0:4:2]` — Python's third slice field.  Answered where it is
/// written rather than as "expected ']' to close '['", which names the
/// bracket and leaves the reader to discover that the language has two
/// slice fields and not three.  True when it reported.
fn sliceHasNoStep(self: *Parser) Error!bool {
    if (self.peekKind() != .colon) return false;
    try self.report(
        "luce.parse.expected",
        self.peek().span,
        "a slice is [start:end] and has no step; take every nth with a loop",
        .{},
    );
    return true;
}

fn indexOrSlice(self: *Parser, target: *ast.Expression) Error!?*ast.Expression {
    const opener = self.advance(); // [

    // [:end] — a slice from the beginning.
    if (self.accept(.colon) != null) {
        var end: ?*ast.Expression = null;
        if (self.peekKind() != .right_bracket) {
            end = (try expression(self)) orelse return null;
        }
        if (try sliceHasNoStep(self)) return null;
        const closing = (try self.expectClose(.right_bracket, opener)) orelse return null;
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
        if (try sliceHasNoStep(self)) return null;
        const closing = (try self.expectClose(.right_bracket, opener)) orelse return null;
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
    var previous_end = first.span().end;
    while (self.accept(.comma) != null) {
        if (ranOut(self.peekKind())) break;
        const next = (try expression(self)) orelse return null;
        try indices.append(self.arena, next);
        previous_end = next.span().end;
    }
    if (try self.missingSeparator(previous_end)) return null;
    const closing = (try self.expectClose(.right_bracket, opener)) orelse return null;
    return make(self, .{ .index = .{
        .target = target,
        .indices = try indices.toOwnedSlice(self.arena),
        .span = .{ .start = target.span().start, .end = closing.span.end },
    } });
}

// ---------------------------------------------------------------------------
// Primaries: names, literals, calls, `new`
// ---------------------------------------------------------------------------

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
        .keyword_none => {
            const item = self.advance();
            return make(self, .{ .none_literal = .{ .span = item.span } });
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
                return namedCallExpression(self, self.text(item), item.span.start);
            }
            return make(self, .{ .name = .{ .text = self.text(item), .span = item.span } });
        },
        .left_paren => {
            const opener = self.advance();
            const inner = (try expression(self)) orelse return null;
            // `(1, 2)` — there are no tuples, and "expected ')' to
            // close '(', found ','" does not say so.
            if (self.peekKind() == .comma) {
                try self.report(
                    "luce.parse.expression",
                    self.peek().span,
                    "there are no tuples: group values in a list '[a, b]' or a struct",
                    .{},
                );
                return null;
            }
            if ((try self.expectClose(.right_paren, opener)) == null) return null;
            return inner;
        },
        .left_bracket => return listLiteral(self),
        .keyword_new => return newObject(self),
        // `!` is the fallibility mark on a return type and nothing
        // else.  It used to be refused by the lexer, which is where
        // the `not` hint lived; now that it lexes, the hint belongs
        // here — a reader who writes `!x` still has to be told the
        // word for it.
        .bang => {
            try bangIsNotAnOperator(self);
            return null;
        },
        // `//` is floor division (docs/NUMERICS.md), and taking that
        // spelling spent the lexer's *"a comment starts with '#';
        // there is no '//' form"* — a good message aimed at exactly
        // the newcomer the operator is otherwise courting.  It is not
        // gone, it moved here, because **prefix position is where the
        // comment reading is unambiguous**: an operator with nothing
        // to its left cannot be arithmetic, and a `// comment` is
        // written at the start of a line every time.  With a left
        // operand, `a // b` is division and is meant to be.
        .slash_slash => {
            try self.report(
                "luce.parse.comment",
                self.peek().span,
                "'//' is floor division and needs a number on its left; a comment starts with '#'",
                .{},
            );
            return null;
        },
        else => {
            try self.report(
                "luce.parse.expression",
                self.peek().span,
                "expected an expression, found {s}",
                .{try self.found()},
            );
            return null;
        },
    }
}

/// The shared `( ... )` argument list: positional values, or
/// `name = value` for struct construction.  A trailing comma is fine.
///
/// The loop stops at a newline as well as at the closer, because a
/// newline inside brackets only reaches the parser when the group was
/// never closed — the lexer suspends them otherwise.  Stopping there
/// is what lets `expectClose` blame the opener instead of demanding an
/// expression at end of file.
fn argumentList(self: *Parser, opener: Token) Error!?struct { arguments: []ast.Argument, closing: Token } {
    var arguments: std.ArrayList(ast.Argument) = .empty;
    defer arguments.deinit(self.arena);
    var previous_end = opener.span.end;
    while (!endsList(self.peekKind(), .right_paren)) {
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
        previous_end = value.span().end;
        if (self.accept(.comma) == null) break;
    }
    if (try self.missingSeparator(previous_end)) return null;
    const closing = (try self.expectClose(.right_paren, opener)) orelse return null;
    return .{ .arguments = try arguments.toOwnedSlice(self.arena), .closing = closing };
}

/// The loop condition every comma-separated list shares: stop at the
/// closer, at end of file, and at a newline — see `argumentList`.
pub fn endsList(kind: Kind, closer: Kind) bool {
    return kind == closer or ranOut(kind);
}

/// A comma-separated list has run out of input rather than reached its
/// closer.  The bracket was never closed, and that is the diagnostic
/// the reader needs — not "expected an expression" at the element that
/// was never coming.
pub fn ranOut(kind: Kind) bool {
    return kind == .newline or kind == .end_of_file;
}

fn methodCall(self: *Parser, target: *ast.Expression, name: Token) Error!?*ast.Expression {
    const opener = self.advance(); // (
    const list = (try argumentList(self, opener)) orelse return null;
    return make(self, .{ .method = .{
        .target = target,
        .name = self.text(name),
        .arguments = list.arguments,
        .span = .{ .start = target.span().start, .end = list.closing.span.end },
    } });
}

fn namedCallExpression(self: *Parser, callee: []const u8, start: usize) Error!?*ast.Expression {
    const opener = self.advance(); // (
    const list = (try argumentList(self, opener)) orelse return null;
    return make(self, .{ .call = .{
        .callee = callee,
        .arguments = list.arguments,
        .span = .{ .start = start, .end = list.closing.span.end },
    } });
}

fn listLiteral(self: *Parser) Error!?*ast.Expression {
    const opener = self.advance(); // [
    var elements: std.ArrayList(*ast.Expression) = .empty;
    defer elements.deinit(self.arena);
    var previous_end = opener.span.end;
    while (!endsList(self.peekKind(), .right_bracket)) {
        const element = (try expression(self)) orelse return null;
        try elements.append(self.arena, element);
        previous_end = element.span().end;
        if (self.accept(.comma) == null) break;
    }
    if (try self.missingSeparator(previous_end)) return null;
    const closing = (try self.expectClose(.right_bracket, opener)) orelse return null;
    return make(self, .{ .list_literal = .{
        .elements = try elements.toOwnedSlice(self.arena),
        .span = .{ .start = opener.span.start, .end = closing.span.end },
    } });
}

/// new List(Int) | new Map(String, Int) | new Array(Int, DIM...) |
/// new Builder().  Type arguments come first; an Array's trailing
/// arguments are runtime dimension expressions.
fn newObject(self: *Parser) Error!?*ast.Expression {
    const start = self.advance(); // new
    // The kind is read without consuming it: List and Map hand the
    // whole `Name(args...)` to typeName, which must see the name.
    if (self.peekKind() != .identifier) {
        _ = try self.expect(.identifier, "List, Map, Array, or Builder after new");
        return null;
    }
    const name = self.peek();
    const kind = self.text(name);
    var written: ast.TypeName = .{ .name = kind, .span = name.span };
    var dims: std.ArrayList(*ast.Expression) = .empty;
    defer dims.deinit(self.arena);

    var closing_end = name.span.end;
    if (std.mem.eql(u8, kind, "Builder")) {
        _ = self.advance();
        if (self.accept(.left_paren)) |opener| {
            const closing = (try self.expectClose(.right_paren, opener)) orelse return null;
            closing_end = closing.span.end;
        }
    } else if (std.mem.eql(u8, kind, "List") or std.mem.eql(u8, kind, "Map")) {
        written = (try self.typeName()) orelse return null;
        closing_end = written.span.end;
    } else if (std.mem.eql(u8, kind, "Array")) {
        _ = self.advance();
        const opener = (try self.expect(.left_paren, "'(' after Array")) orelse return null;
        const element = (try self.typeName()) orelse return null;
        const arguments = try self.arena.alloc(ast.TypeName, 1);
        arguments[0] = element;
        written.arguments = arguments;
        var previous_end = element.span.end;
        while (self.accept(.comma) != null) {
            if (ranOut(self.peekKind())) break;
            const dimension = (try expression(self)) orelse return null;
            try dims.append(self.arena, dimension);
            previous_end = dimension.span().end;
        }
        if (try self.missingSeparator(previous_end)) return null;
        const closing = (try self.expectClose(.right_paren, opener)) orelse return null;
        closing_end = closing.span.end;
    } else {
        try self.report(
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

// ---------------------------------------------------------------------------
// Building a node
// ---------------------------------------------------------------------------

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
///
/// This is the one place stage 3 desugars rather than records; the
/// structured form belongs in stage 5 (docs/PIPELINE.md).
// ---------------------------------------------------------------------------
// F-strings, desugared here into `+` and `str(...)`
// ---------------------------------------------------------------------------

fn expandFString(self: *Parser, item: Token) Error!?*ast.Expression {
    const raw = self.text(item);
    // Stage 2 emits a recovery token for an *unterminated* literal too,
    // so that the line still has an operand — see its "an unterminated
    // f-string stops at the line and still yields an operand".  It has
    // already reported; expanding the truncated bytes would only add a
    // second message about a brace that was never really open.  Stand
    // in an empty String and let the rest of the line parse.
    if (!closedLiteral(raw, 3)) return placeholderString(self, item);
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
            const close = matchBrace(inner, index + 1) orelse {
                try self.report("luce.parse.fstring", item.span, "unmatched open brace in f-string", .{});
                return null;
            };
            const hole = inner[index + 1 .. close];
            const hole_expr = (try subExpression(self, hole, inner_start + index + 1)) orelse return null;
            // The synthesized `str(...)` takes the *hole's* span, not
            // the whole f-string's.  Everything stage 4 says about this
            // call is about what the reader wrote between the braces —
            // `str takes Int, Float, Bool, String, or Builder` for a
            // list in a hole — and underlining the entire literal makes
            // a reader with four holes in one line check all four.
            const wrapped = try wrapStr(self, hole_expr, hole_expr.span());
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
            try self.report("luce.parse.fstring", item.span, "unmatched close brace in f-string (double it for a literal)", .{});
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
fn matchBrace(inner: []const u8, from: usize) ?usize {
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
/// lexed on their own and their spans shifted to absolute, then the
/// *same* parser reads them, so the nesting bound, the arena, and the
/// diagnostics are shared rather than reset per hole.
fn subExpression(self: *Parser, bytes: []const u8, offset: usize) Error!?*ast.Expression {
    if (bytes.len == 0) {
        try self.report(
            "luce.parse.fstring",
            .{ .start = offset, .end = offset },
            "empty interpolation: {{}} needs an expression between the braces",
            .{},
        );
        return null;
    }
    // `f"{x:.2f}"` is the habit Python travellers arrive with, and its
    // tail rarely even lexes.  A colon outside strings and brackets is
    // never valid in a Luce expression, so catch it before the lexer
    // turns it into "malformed expression".
    if (topLevelColon(bytes)) |at| {
        try self.report(
            "luce.parse.fstring",
            .{ .start = offset + at, .end = offset + at + 1 },
            "no format specifiers in an f-string hole; use strings.format_float(x, 2)",
            .{},
        );
        return null;
    }
    // The hole is a slice of stage 1's prepared text, so it satisfies
    // `lex()`'s precondition already — every byte property is
    // inherited, and the braces that bound it are ASCII, so no UTF-8
    // sequence is ever cut.  The one property a *slice* can break is
    // "no leading byte-order mark", since prepare only strips the
    // file's own.  Answer that here rather than tripping the seam's
    // Debug check.
    if (std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF")) {
        try self.report(
            "luce.parse.fstring",
            .{ .start = offset, .end = offset + bytes.len },
            "malformed expression in f-string",
            .{},
        );
        return null;
    }
    var scratch = Diagnostics.init(self.arena);
    const raw_tokens = (try lex_mod.lex(self.arena, bytes, &scratch)).tokens;
    if (scratch.hasErrors()) {
        try self.report("luce.parse.fstring", .{ .start = offset, .end = offset + bytes.len }, "malformed expression in f-string", .{});
        return null;
    }
    const tokens = try self.arena.alloc(Token, raw_tokens.len);
    for (raw_tokens, tokens) |source_token, *shifted| {
        shifted.* = .{ .kind = source_token.kind, .span = .{
            .start = source_token.span.start + offset,
            .end = source_token.span.end + offset,
        } };
    }

    const saved_tokens = self.tokens;
    const saved_index = self.index;
    self.tokens = tokens;
    self.index = 0;
    defer {
        self.tokens = saved_tokens;
        self.index = saved_index;
    }

    const parsed = (try expression(self)) orelse return null;
    if (self.peekKind() != .newline and self.peekKind() != .end_of_file) {
        try self.report("luce.parse.fstring", parsed.span(), "an f-string hole is a single expression", .{});
        return null;
    }
    return parsed;
}

/// The offset of a `:` in an f-string hole that sits outside any
/// string literal and any bracket — the shape a Python format
/// specifier has, and one no Luce expression ever has.
fn topLevelColon(bytes: []const u8) ?usize {
    var brackets: usize = 0;
    var index: usize = 0;
    while (index < bytes.len) : (index += 1) {
        switch (bytes[index]) {
            '"' => {
                index += 1;
                while (index < bytes.len and bytes[index] != '"') {
                    if (bytes[index] == '\\') index += 1;
                    index += 1;
                }
            },
            '(', '[' => brackets += 1,
            ')', ']' => brackets -|= 1,
            ':' => if (brackets == 0) return index,
            else => {},
        }
    }
    return null;
}

/// True when a literal token really reached its closing quote.  Stage
/// 2 hands the parser a recovery token for an unterminated one so the
/// line still has an operand, so this is a question, not a guarantee:
/// `least` is the shortest closed form (2 for `""`, 3 for `f""`).
fn closedLiteral(raw: []const u8, least: usize) bool {
    return raw.len >= least and raw[raw.len - 1] == '"';
}

/// The empty String a truncated literal stands in as.  Stage 2 already
/// reported the truncation; this keeps the parse going without a
/// second message about it.
fn placeholderString(self: *Parser, item: Token) Error!*ast.Expression {
    return make(self, .{ .string_literal = .{ .decoded = "", .span = item.span } });
}

pub fn decodeString(self: *Parser, item: Token) Error![]const u8 {
    const raw = self.text(item);
    if (!closedLiteral(raw, 2)) return "";
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
