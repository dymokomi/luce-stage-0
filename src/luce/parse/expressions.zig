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
const source_mod = @import("../source.zig");
const lex_mod = @import("../lex.zig");
const ast = @import("ast.zig");
const diagnostics_mod = @import("../support/diagnostics.zig");
const types = @import("../support/types.zig");

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
        .equal, .not_equal, .keyword_is, .less, .less_equal, .greater, .greater_equal => .comparison,
        .keyword_else, .keyword_catch => .coalesce,
        // Go's precedence for the bit set (docs/BITWISE.md R1): `|`
        // and `^` bind with `+`, `&` and the shifts with `*` — which
        // is what makes `flags & mask != 0` mean what it reads as,
        // the parse C famously gets wrong.
        .plus, .minus, .pipe, .caret => .additive,
        .star, .slash, .slash_slash, .percent, .ampersand, .shift_left, .shift_right => .multiplicative,
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
        .char_literal,
        .string_literal,
        .fstring,
        .identifier,
        .keyword_true,
        .keyword_false,
        .keyword_none,
        .keyword_self,
        .keyword_not,
        .keyword_spawn,
        .keyword_try,
        .keyword_func,
        .minus,
        .tilde,
        .left_paren,
        .left_bracket,
        .left_brace,
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
        .keyword_is => .identity,
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
        .ampersand => .bit_and,
        .pipe => .bit_or,
        .caret => .bit_xor,
        .shift_left => .shift_left,
        .shift_right => .shift_right,
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

/// Which spelling of `catch` the cursor is looking at: the statement's
/// handler block, or the operator whose right side is a fallback value.
///
/// `catch:` needs one token, because a fallback is an expression and no
/// expression starts with a colon.  `catch NAME:` needs three, and the
/// third is the newline: a slice takes a whole expression on each side
/// of its colon, so `xs[first() catch fallback : 10]` is the operator
/// form with a name for a fallback — and the lexer emits no newline
/// inside brackets, so a newline behind the colon can only be the end
/// of a statement line.
pub fn opensHandler(self: *const Parser) bool {
    if (self.peekAhead(1) == .colon) return true;
    return self.peekAhead(1) == .identifier and
        self.peekAhead(2) == .colon and
        self.peekAhead(3) == .newline;
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
        // `call catch:` and `call catch reason:` open a handler block
        // and belong to the statement, not to this expression.
        if (self.peekKind() == .keyword_catch and opensHandler(self)) return left;
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
            .star => .{ .written = "**", .instead = "import std.math and call math.pow(x, y), or math.ipow(x, y) for i64" },
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
            // `<<` and `>>` lex whole now (docs/BITWISE.md), so the
            // old "no bitwise operators" rows can never fire and are
            // gone.
            else => null,
        },
        // `&&` and `||` were the lexer's kindness while `&` was a
        // stray; the characters are operators now, so the hint moved
        // here — the same sentence, one stage later.
        .ampersand => switch (second) {
            .ampersand => .{ .written = "&&", .instead = "write 'and'; a single '&' is bitwise" },
            else => null,
        },
        .pipe => switch (second) {
            .pipe => .{ .written = "||", .instead = "write 'or'; a single '|' is bitwise" },
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
/// reads it as `(a < b) < c`, which is a bool compared with an i64 and
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
/// `not` and unary `-`.  Guarded, because a chain of them recurses once
/// per operator.
fn unaryExpression(self: *Parser) Error!?*ast.Expression {
    if (!try self.enter("expression")) return null;
    defer self.leave();

    // `++i` in front of an operand.  Not `--i`, which is the double
    // negation this grammar already reads and answers correctly.
    if (foreignOperator(self)) |found| {
        try reportForeignOperator(self, found);
        return null;
    }

    if (self.accept(.keyword_try)) |keyword| {
        const operand = (try unaryExpression(self)) orelse return null;
        return make(self, .{ .try_call = .{
            .operand = operand,
            .span = .{ .start = keyword.span.start, .end = operand.span().end },
        } });
    }
    // `spawn` takes a *call* and nothing else, so its operand is a
    // postfix expression rather than a unary one: there is no verb
    // that could stand between the keyword and the call it hands over
    // (docs/THREADS.md D2 — the verbs go on the arguments, inside).
    if (self.accept(.keyword_spawn)) |keyword| {
        const operand = (try postfixExpression(self)) orelse return null;
        switch (operand.*) {
            .call, .method => {},
            else => {
                try self.report(
                    "luce.parse.spawn",
                    keyword.span,
                    "spawn runs a call on a worker; write 'spawn f(…)'",
                    .{},
                );
                return null;
            },
        }
        return make(self, .{ .spawn = .{
            .call = operand,
            .span = .{ .start = keyword.span.start, .end = operand.span().end },
        } });
    }
    if (self.accept(.keyword_not)) |operator| {
        const operand = (try unaryExpression(self)) orelse return null;
        // `not a == b` is `(not a) == b` here and `not (a == b)` in
        // Python, and with bool operands both parse and disagree
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
    if (self.accept(.tilde)) |operator| {
        const operand = (try unaryExpression(self)) orelse return null;
        return make(self, .{ .unary = .{
            .op = .bit_not,
            .operand = operand,
            .span = .{ .start = operator.span.start, .end = operand.span().end },
        } });
    }
    return postfixExpression(self);
}

/// `not` is a prefix operator and so binds tighter than every binary
/// one, comparison included — Zig's and C's reading, not Python's.
/// Both readings are legal bool expressions with different answers, so
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
            if (self.peekKind() == .keyword_init) {
                const lifecycle = self.advance();
                try self.report(
                    "luce.sema.class.lifecycle",
                    lifecycle.span,
                    "init runs only through class construction; write ClassName(...)",
                    .{},
                );
                return null;
            }
            if (self.peekKind() == .keyword_deinit) {
                const lifecycle = self.advance();
                try self.report(
                    "luce.sema.class.lifecycle",
                    lifecycle.span,
                    "deinit is called only by ARC at the last strong release; it is not a method or function value",
                    .{},
                );
                return null;
            }
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
        // A call is one more suffix, on the same footing as the index
        // and the field: `EXPR(args)` parses wherever `EXPR[i]` does,
        // and calls the value the expression answers.  The two forms
        // whose head names a *declaration* never arrive here — the
        // primary above takes `name(...)` and the dot above takes
        // `receiver.method(...)`, because only their written text can
        // resolve a declaration.
        //
        // A newline ends the chain here exactly as it ends an index
        // chain, and for the same reason: the lexer suspends newlines
        // only inside an open group, so `f` on one line and `(x)` on
        // the next are two statements and stay two.
        if (self.peekKind() == .left_paren) {
            value = (try valueCall(self, value)) orelse return null;
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
        .char_literal => {
            const item = self.advance();
            return make(self, .{ .char_literal = .{ .value = try decodeChar(self, item), .span = item.span } });
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
        // `self` reads as the name it is: an implied local binding of
        // the enclosing struct's type, which stage 4 represents as
        // logical parameter zero.  A keyword rather than an identifier
        // so nothing can shadow it, but an ordinary name everywhere it
        // is *used* —
        // `self.x`, `self.items.append(1)`, `f(self)` all work with no
        // case of their own (docs/SELF.md).  It is never a call:
        // `self(...)` is not a thing, and falls to the same
        // "unknown function" a bare `self()` would.
        .keyword_self => {
            const item = self.advance();
            return make(self, .{ .name = .{ .text = "self", .span = item.span } });
        },
        .identifier => {
            // The container types construct by call — `list[i64]()`,
            // `map[str, i64]()`, `array[i64](5)`, `builder()` — and
            // their heads are reserved builtin names, so the reading
            // is decided here, before the word could name a value.
            const head = self.text(self.peek());
            if (self.peekAhead(1) == .left_bracket and
                (std.mem.eql(u8, head, "list") or std.mem.eql(u8, head, "map") or
                    std.mem.eql(u8, head, "array")))
            {
                return containerConstruction(self);
            }
            if (std.mem.eql(u8, head, "builder") and self.peekAhead(1) == .left_paren) {
                return containerConstruction(self);
            }
            const item = self.advance();
            if (self.peekKind() == .left_paren) {
                return namedCallExpression(self, self.text(item), item.span.start);
            }
            return make(self, .{ .name = .{ .text = self.text(item), .span = item.span } });
        },
        .left_paren => {
            // `(a, b) -> expr` — a lambda (docs/FUNCTIONS.md S3).  The
            // decision is made *before* anything is parsed, by looking
            // one token past the matching `)`: `(a, b)` can open nothing
            // else, because there are no tuples, and the
            // single-parameter case resolves at the arrow, one token
            // after the close.  So the lookahead is bounded by the
            // parenthesis it is already sitting on.
            if (arrowFollowsGroup(self)) return lambda(self);
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
        .left_bracket => {
            if (captureListFollows(self)) return blockClosure(self, true);
            return listLiteral(self);
        },
        .left_brace => return mapLiteral(self),
        .keyword_func => return blockClosure(self, false),
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
/// `name = value` — a named argument, or a field of a struct
/// construction; stage 4 decides which and enforces the rules
/// (docs/ARGS.md).  `self = value` parses as the name "self" so the
/// analyzer can refuse it with a sentence about the receiver instead
/// of a parse error about the keyword.  A trailing comma is fine.
///
/// A named argument's span covers the name as well as the value, so a
/// diagnostic about the *name* — unknown, duplicated — underlines
/// what the reader wrote, not just the value beside it.
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
        var name_start: ?usize = null;
        const named_next = self.peekAhead(1) == .assign and
            (self.peekKind() == .identifier or self.peekKind() == .keyword_self);
        if (named_next) {
            const named = self.advance();
            _ = self.advance(); // =
            argument_name = self.text(named);
            name_start = named.span.start;
        }
        const value = (try expression(self)) orelse return null;
        try arguments.append(self.arena, .{
            .name = argument_name,
            .value = value,
            .span = .{ .start = name_start orelse value.span().start, .end = value.span().end },
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

/// `EXPR(arguments)` — the call suffix's arguments, which are an
/// ordinary argument list; the callee is whatever the postfix loop had
/// in hand when it reached the `(`.
fn valueCall(self: *Parser, callee: *ast.Expression) Error!?*ast.Expression {
    const opener = self.advance(); // (
    const list = (try argumentList(self, opener)) orelse return null;
    return make(self, .{ .value_call = .{
        .callee = callee,
        .arguments = list.arguments,
        .span = .{ .start = callee.span().start, .end = list.closing.span.end },
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

/// Whether the `(` under the cursor closes on a `->`, which is what
/// makes it a lambda's parameter list rather than a grouping.  Nesting
/// is counted so `((a))` and `(f(x))` answer honestly; a run that ends
/// at end of input answers no and lets the ordinary parse report the
/// unclosed paren.
fn arrowFollowsGroup(self: *Parser) bool {
    var depth: usize = 0;
    var ahead: usize = 0;
    while (true) : (ahead += 1) {
        switch (self.peekAhead(ahead)) {
            .left_paren => depth += 1,
            .right_paren => {
                depth -= 1;
                if (depth == 0) return self.peekAhead(ahead + 1) == .arrow;
            },
            .end_of_file => return false,
            else => {},
        }
    }
}

/// `(a, b) -> expr`.  The parameters are bare names — a type written
/// here would be a second spelling of a signature the landing site
/// already carries — and the body is one expression, which is what
/// keeps the form honest: an expression cannot secretly grow state.
fn lambda(self: *Parser) Error!?*ast.Expression {
    const opener = self.advance(); // (
    var parameters: std.ArrayList(ast.Name) = .empty;
    defer parameters.deinit(self.arena);
    while (!endsList(self.peekKind(), .right_paren)) {
        const name = (try self.expect(.identifier, "a parameter name")) orelse return null;
        try self.refuseWildcardName(name);
        try parameters.append(self.arena, .{ .text = self.text(name), .span = name.span });
        if (self.accept(.comma) == null) break;
    }
    if ((try self.expectClose(.right_paren, opener)) == null) return null;
    _ = self.advance(); // ->
    // A block after the arrow is the one shape this grammar cannot
    // take: an indentation language cannot put statements inside a
    // call's parentheses, which is why Python's lambda is one
    // expression too (docs/FUNCTIONS.md).  Said here, where the reader
    // wrote the colon, rather than as "expected an expression".
    if (self.peekKind() == .colon) {
        try self.report(
            "luce.parse.expression",
            self.peek().span,
            "a lambda is one expression, not a block; a body that wants statements is a function wanting a name [FUNCTIONS.md]",
            .{},
        );
        return null;
    }
    const body = (try expression(self)) orelse return null;
    return make(self, .{ .lambda = .{
        .parameters = try parameters.toOwnedSlice(self.arena),
        .body = body,
        .span = .{ .start = opener.span.start, .end = body.span().end },
    } });
}

/// Whether the bracket under the cursor is a closure capture list. The token
/// immediately after its matching `]` is decisive, so ordinary list literals
/// retain their grammar and no expression inside the list has to be guessed.
fn captureListFollows(self: *Parser) bool {
    var depth: usize = 0;
    var ahead: usize = 0;
    while (true) : (ahead += 1) {
        switch (self.peekAhead(ahead)) {
            .left_bracket => depth += 1,
            .right_bracket => {
                depth -= 1;
                if (depth == 0) return self.peekAhead(ahead + 1) == .keyword_func;
            },
            .end_of_file => return false,
            else => {},
        }
    }
}

/// `[capture, weak owner, copy = expression] func(a, b): BLOCK`, or the same
/// form beginning directly with `func`. Capture entries are intentionally
/// small: inference is the default, and the list exists only to request weak
/// storage or an explicitly named snapshot.
fn blockClosure(self: *Parser, has_capture_list: bool) Error!?*ast.Expression {
    const start = self.peek().span.start;
    var captures: std.ArrayList(ast.ClosureCapture) = .empty;
    defer captures.deinit(self.arena);

    if (has_capture_list) {
        const opener = self.advance(); // [
        while (!endsList(self.peekKind(), .right_bracket)) {
            const weak = self.accept(.keyword_weak) != null;
            const named = if (self.accept(.keyword_self)) |receiver|
                receiver
            else
                (try self.expect(.identifier, "a captured name")) orelse return null;
            if (named.kind == .identifier) try self.refuseWildcardName(named);
            var mode: ast.ClosureCaptureMode = if (weak) .weak else .strong;
            var value: ?*ast.Expression = null;
            var end = named.span.end;
            if (self.accept(.assign) != null) {
                if (weak) {
                    try self.report(
                        "luce.parse.closure",
                        named.span,
                        "a capture is either weak or a value snapshot, not both; remove 'weak' or '= ...'",
                        .{},
                    );
                    return null;
                }
                mode = .snapshot;
                value = (try expression(self)) orelse return null;
                end = value.?.span().end;
            }
            try captures.append(self.arena, .{
                .name = .{
                    .text = if (named.kind == .keyword_self) "self" else self.text(named),
                    .span = named.span,
                },
                .mode = mode,
                .value = value,
                .span = .{ .start = if (weak) named.span.start - "weak ".len else named.span.start, .end = end },
            });
            if (self.accept(.comma) == null) break;
        }
        if ((try self.expectClose(.right_bracket, opener)) == null) return null;
    }

    _ = (try self.expect(.keyword_func, "'func' after the capture list")) orelse return null;
    const opener = (try self.expect(.left_paren, "'(' after 'func'")) orelse return null;
    var parameters: std.ArrayList(ast.Name) = .empty;
    defer parameters.deinit(self.arena);
    while (!endsList(self.peekKind(), .right_paren)) {
        const name = (try self.expect(.identifier, "a parameter name")) orelse return null;
        try self.refuseWildcardName(name);
        try parameters.append(self.arena, .{ .text = self.text(name), .span = name.span });
        if (self.accept(.comma) == null) break;
    }
    if ((try self.expectClose(.right_paren, opener)) == null) return null;
    const body = (try self.block("closure")) orelse return null;
    return make(self, .{ .closure = .{
        .captures = try captures.toOwnedSlice(self.arena),
        .parameters = try parameters.toOwnedSlice(self.arena),
        .body = body,
        .span = .{ .start = start, .end = body.span.end },
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

/// `{key: value, ...}` — the runtime and constant map literal share
/// one syntax (docs/CONSTANTS.md R-B).  A literal is deliberately
/// non-empty: without an entry there is nowhere to infer either type,
/// so the constructor is the honest spelling.
fn mapLiteral(self: *Parser) Error!?*ast.Expression {
    const opener = self.advance(); // {
    if (self.accept(.right_brace)) |closing| {
        try self.report(
            "luce.parse.expression",
            .{ .start = opener.span.start, .end = closing.span.end },
            "an empty map has no literal; write 'map[K, V]()' so its key and value types are explicit",
            .{},
        );
        return null;
    }

    var entries: std.ArrayList(ast.MapEntry) = .empty;
    defer entries.deinit(self.arena);
    var previous_end = opener.span.end;
    while (!endsList(self.peekKind(), .right_brace)) {
        const key = (try expression(self)) orelse return null;
        if ((try self.expect(.colon, "':' between a map key and value")) == null) return null;
        const value = (try expression(self)) orelse return null;
        try entries.append(self.arena, .{
            .key = key,
            .value = value,
            .span = .{ .start = key.span().start, .end = value.span().end },
        });
        previous_end = value.span().end;
        if (self.accept(.comma) == null) break;
    }
    if (try self.missingSeparator(previous_end)) return null;
    const closing = (try self.expectClose(.right_brace, opener)) orelse return null;
    return make(self, .{ .map_literal = .{
        .entries = try entries.toOwnedSlice(self.arena),
        .span = .{ .start = opener.span.start, .end = closing.span.end },
    } });
}

/// `new TYPE`, `new TYPE(dimensions...)`, or `new TYPE(arguments...)`.
/// Square brackets inside TYPE carry type arguments; parentheses carry
/// construction values — an array's dimensions, or a class's fields or
/// init arguments. The analyzer decides which resolved shape accepts
/// which, so the parser records one shared argument list.
/// A container construction: `list[i64]()`, `map[str, i64]()`,
/// `array[i64](5, 5)`, `builder()` — a builtin container head, its
/// type arguments, and the call that makes one.
fn containerConstruction(self: *Parser) Error!?*ast.Expression {
    const start = self.peek().span.start;
    const written = (try self.constructionTypeName()) orelse return null;
    var arguments: []ast.Argument = &.{};
    var closing_end = written.span.end;
    if (self.accept(.left_paren)) |opener| {
        const listed = (try argumentList(self, opener)) orelse return null;
        arguments = listed.arguments;
        closing_end = listed.closing.span.end;
    }

    return make(self, .{ .new_object = .{
        .type_name = written,
        .arguments = arguments,
        .span = .{ .start = start, .end = closing_end },
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

/// Expand f"...{expr}..." into a str-typed concatenation:
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
    // in an empty string and let the rest of the line parse.
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
            const whole_hole = inner[index + 1 .. close];
            const hole_start = inner_start + index + 1;
            // `{x:.2f}` — the value, then how to write it.
            const split = topLevelColon(whole_hole);
            const hole = if (split) |at| whole_hole[0..at] else whole_hole;
            const trimmed_hole = trimHoleSpaces(hole);
            const hole_expr = (try subExpression(
                self,
                trimmed_hole.bytes,
                hole_start + trimmed_hole.leading,
            )) orelse return null;
            const wrapped = if (split) |at| blk: {
                const spec = trimHoleSpaces(whole_hole[at + 1 ..]).bytes;
                const digits = decimalsOf(spec) orelse {
                    try self.report(
                        "luce.parse.fstring",
                        .{ .start = hole_start + at, .end = hole_start + whole_hole.len },
                        "unknown format spec ':{s}'; the one form is ':.Nf' — N decimal places of an f64",
                        .{spec},
                    );
                    return null;
                };
                break :blk try wrapFormat(self, hole_expr, digits, hole_expr.span());
            } else
                // The synthesized `str(...)` takes the *hole's*
                // span, not the whole f-string's.  Everything stage 4
                // says about this call is about what the reader wrote
                // between the braces — `str()` converts numbers,
                // bool, or `str` for a list in a hole — and
                // underlining the entire literal makes a reader with
                // four holes in one line check all four.
                try wrapStr(self, hole_expr, hole_expr.span());
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
                'r' => '\r',
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
    // yields a string.
    return result orelse try make(self, .{ .string_literal = .{ .decoded = "", .span = item.span } });
}

const TrimmedHole = struct {
    bytes: []const u8,
    leading: usize,
};

/// Spaces immediately inside an interpolation belong to the f-string
/// syntax, not to the expression.  The hole is lexed as a standalone
/// line, so leaving its leading space in place makes the lexer mistake
/// it for indentation.  Trim only ordinary spaces: tabs remain an
/// invalid source character everywhere in Luce.
fn trimHoleSpaces(bytes: []const u8) TrimmedHole {
    var leading: usize = 0;
    while (leading < bytes.len and bytes[leading] == ' ') : (leading += 1) {}
    var trailing = bytes.len;
    while (trailing > leading and bytes[trailing - 1] == ' ') : (trailing -= 1) {}
    return .{
        .bytes = bytes[leading..trailing],
        .leading = leading,
    };
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

/// `str(expr)` — interpolation converts each hole to text.
fn wrapStr(self: *Parser, expr: *ast.Expression, span: Span) Error!*ast.Expression {
    const arguments = try self.arena.alloc(ast.Argument, 1);
    arguments[0] = .{ .name = null, .value = expr, .span = expr.span() };
    return make(self, .{ .call = .{ .callee = "str", .arguments = arguments, .span = span } });
}

/// `strings.format_float(expr, decimals)` — what `{x:.2f}` means.
///
/// **Formatting belongs where formatting happens** (docs/NUMERICS.md
/// §8), and where it happens is an f-string: every numeric formatting
/// site in the corpus is inside one or inside a `print`.  So the spec
/// lowers to the std function that already existed, already rounds
/// half away from zero, and is already tested — which is why this is
/// one production in this scanner and no runtime at all.  It needs
/// `import std.strings` for the same reason `s.split(",")` does, and
/// says so through the same diagnostic.
fn wrapFormat(
    self: *Parser,
    expr: *ast.Expression,
    digits: []const u8,
    span: Span,
) Error!*ast.Expression {
    // The digit run travels as the literal text it was written as, so
    // stage 4 range-checks it exactly as it checks one a reader typed.
    const places = try make(self, .{ .int_literal = .{
        .text = try self.arena.dupe(u8, digits),
        .span = span,
    } });
    const arguments = try self.arena.alloc(ast.Argument, 2);
    arguments[0] = .{ .name = null, .value = expr, .span = expr.span() };
    arguments[1] = .{ .name = null, .value = places, .span = span };
    return make(self, .{ .call = .{
        .callee = "strings.format_float",
        .arguments = arguments,
        .span = span,
        .origin = .format_spec,
    } });
}

/// The `N` of a `.Nf` spec, or null when the spec is anything else.
///
/// **One form, deliberately** (docs/NUMERICS.md §8): no width, no
/// fill, no alignment, no `%`, no `e`, no thousands separator.  The
/// `f` is redundant — the compiler knows the operand's type — and is
/// required anyway, because `{x:.2}` means *two significant digits* in
/// Python and letting it mean two decimal places here would be a
/// silent divergence from the language Luce is shaped after.
fn decimalsOf(spec: []const u8) ?[]const u8 {
    if (spec.len < 3) return null;
    if (spec[0] != '.' or spec[spec.len - 1] != 'f') return null;
    const digits = spec[1 .. spec.len - 1];
    for (digits) |character| {
        if (character < '0' or character > '9') return null;
    }
    return digits;
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
/// string literal or grouping delimiter — the shape a Python format
/// specifier has, and one no Luce expression ever has.
/// Where a hole's format spec begins, or null when it has none.
///
/// A colon outside strings and brackets used to be refused outright —
/// `f"{x:.2f}"` is the habit Python travellers arrive with, and its
/// tail rarely even lexes, so it was caught before the lexer could
/// call it a malformed expression.  It is the feature now
/// (docs/NUMERICS.md §8), and this is the same scan: a colon *inside*
/// grouping belongs to whatever opened it, which is what keeps
/// `f"{s[1:3]}"` a slice, `f"{copy {"a": 1}}"` a map, and a colon inside a
/// string as text.
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
            '(', '[', '{' => brackets += 1,
            ')', ']', '}' => brackets -|= 1,
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

fn decodeChar(self: *Parser, item: Token) Error!u32 {
    const raw = self.text(item);
    // The lexer already diagnosed an unterminated token.  A closed
    // two-byte spelling is different: `''` is the empty literal and
    // belongs to the cardinality diagnostic below.
    if (raw.len < 2 or raw[raw.len - 1] != '\'') return 0;
    const inner = raw[1 .. raw.len - 1];
    if (inner.len == 0) {
        try self.report("luce.parse.char", item.span, "a character literal contains exactly one Unicode scalar; this one is empty", .{});
        return 0;
    }
    if (inner[0] == '\\') return decodeCharEscape(self, item, inner);

    const length = std.unicode.utf8ByteSequenceLength(inner[0]) catch {
        try self.report("luce.parse.char", item.span, "malformed Unicode scalar in character literal", .{});
        return 0;
    };
    if (length != inner.len) {
        try self.report("luce.parse.char", item.span, "a character literal contains exactly one Unicode scalar; this one contains more than one", .{});
        return 0;
    }
    return std.unicode.utf8Decode(inner[0..length]) catch {
        try self.report("luce.parse.char", item.span, "malformed Unicode scalar in character literal", .{});
        return 0;
    };
}

fn decodeCharEscape(self: *Parser, item: Token, inner: []const u8) Error!u32 {
    if (inner.len == 2) return switch (inner[1]) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        '\\' => '\\',
        '\'' => '\'',
        '"' => '"',
        else => {
            try self.report("luce.parse.char", item.span, "unknown character escape", .{});
            return 0;
        },
    };
    if (!std.mem.startsWith(u8, inner, "\\u{") or inner[inner.len - 1] != '}') {
        try self.report("luce.parse.char", item.span, "a Unicode character escape is written \\u{{HEX}}", .{});
        return 0;
    }
    const digits = inner[3 .. inner.len - 1];
    if (digits.len == 0 or digits.len > 6) {
        try self.report("luce.parse.char", item.span, "a Unicode character escape needs one to six hexadecimal digits", .{});
        return 0;
    }
    const scalar = std.fmt.parseInt(u32, digits, 16) catch {
        try self.report("luce.parse.char", item.span, "a Unicode character escape contains a non-hexadecimal digit", .{});
        return 0;
    };
    if (!isUnicodeScalar(scalar)) {
        try self.report("luce.parse.char", item.span, "U+{X} is not a Unicode scalar value", .{scalar});
        return 0;
    }
    return scalar;
}

fn isUnicodeScalar(value: u32) bool {
    return value <= 0x10ffff and !(value >= 0xd800 and value <= 0xdfff);
}

/// The empty string a truncated literal stands in as.  Stage 2 already
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
                'r' => '\r',
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
