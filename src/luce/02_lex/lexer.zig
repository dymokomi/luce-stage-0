//! The Luce lexer: bytes to tokens plus indentation structure.
//!
//! Indentation defines blocks.  Four-space steps are canonical, tabs
//! are rejected, and blank or comment-only lines produce no layout
//! tokens.  Inside parentheses, newlines and indentation are plain
//! spacing, so calls and expressions may span lines.  The lexer never
//! fails hard: malformed input becomes diagnostics and the closest
//! reasonable token stream.

const std = @import("std");
const source_mod = @import("../01_source.zig");
const token_mod = @import("token.zig");
const diagnostics_mod = @import("../support/diagnostics.zig");

const Allocator = std.mem.Allocator;
const Span = source_mod.Span;
const Token = token_mod.Token;
const Kind = token_mod.Kind;
const Diagnostics = diagnostics_mod.Diagnostics;

pub const Error = error{OutOfMemory};

/// Lex the whole buffer.  The returned tokens borrow nothing; the
/// caller owns the slice.  Malformed input is reported through the
/// diagnostics and skipped.
pub fn lex(allocator: Allocator, source: []const u8, diagnostics: *Diagnostics) Error![]Token {
    var lexer: Lexer = .{
        .allocator = allocator,
        .source = source,
        .diagnostics = diagnostics,
    };
    defer lexer.indents.deinit(allocator);
    errdefer lexer.tokens.deinit(allocator);
    try lexer.run();
    return lexer.tokens.toOwnedSlice(allocator);
}

const Lexer = struct {
    allocator: Allocator,
    source: []const u8,
    diagnostics: *Diagnostics,
    tokens: std.ArrayList(Token) = .empty,
    indents: std.ArrayList(usize) = .empty,
    offset: usize = 0,
    paren_depth: usize = 0,
    at_line_start: bool = true,

    fn run(self: *Lexer) Error!void {
        try self.indents.append(self.allocator, 0);
        while (self.offset < self.source.len) {
            if (self.at_line_start and self.paren_depth == 0) {
                try self.lineStart();
                if (self.offset >= self.source.len) break;
                if (self.at_line_start) continue; // blank line consumed
            }
            try self.next();
        }
        // Close the final line and every open block.
        if (self.lastKind() != .newline and self.lastKind() != null) {
            try self.emit(.newline, .{ .start = self.source.len, .end = self.source.len });
        }
        while (self.indents.items.len > 1) {
            _ = self.indents.pop();
            try self.emit(.dedent, .{ .start = self.source.len, .end = self.source.len });
        }
        try self.emit(.end_of_file, .{ .start = self.source.len, .end = self.source.len });
    }

    fn lastKind(self: *const Lexer) ?Kind {
        if (self.tokens.items.len == 0) return null;
        return self.tokens.items[self.tokens.items.len - 1].kind;
    }

    // Measure indentation and emit indent/dedent when it changes.
    // Blank and comment-only lines are layout-free.
    fn lineStart(self: *Lexer) Error!void {
        const line_begin = self.offset;
        var width: usize = 0;
        while (self.offset < self.source.len) {
            const character = self.source[self.offset];
            if (character == ' ') {
                width += 1;
                self.offset += 1;
            } else if (character == '\t') {
                try self.diagnostics.add(
                    "luce.lex.tab",
                    .{ .start = self.offset, .end = self.offset + 1 },
                    "tabs are not allowed; indent with four spaces",
                    .{},
                );
                self.offset += 1;
            } else {
                break;
            }
        }
        if (self.offset >= self.source.len) return;

        const character = self.source[self.offset];
        if (character == '\n') {
            self.offset += 1;
            return; // blank line
        }
        if (character == '#') {
            self.skipComment();
            if (self.offset < self.source.len and self.source[self.offset] == '\n') {
                self.offset += 1;
            }
            return; // comment-only line
        }

        const current = self.indents.items[self.indents.items.len - 1];
        const here: Span = .{ .start = line_begin, .end = self.offset };
        if (width > current) {
            try self.indents.append(self.allocator, width);
            try self.emit(.indent, here);
        } else if (width < current) {
            while (self.indents.items.len > 1 and
                self.indents.items[self.indents.items.len - 1] > width)
            {
                _ = self.indents.pop();
                try self.emit(.dedent, here);
            }
            if (self.indents.items[self.indents.items.len - 1] != width) {
                try self.diagnostics.add(
                    "luce.lex.indent",
                    here,
                    "indentation does not match any open block",
                    .{},
                );
            }
        }
        self.at_line_start = false;
    }

    fn next(self: *Lexer) Error!void {
        const character = self.source[self.offset];
        // f"..." is an interpolated string; the parser expands it.  A
        // bare `f` followed by anything else is an ordinary word.
        if (character == 'f' and self.peek(1) == '"') {
            try self.fstring();
            return;
        }
        switch (character) {
            ' ' => self.offset += 1,
            '\t' => {
                try self.diagnostics.add(
                    "luce.lex.tab",
                    .{ .start = self.offset, .end = self.offset + 1 },
                    "tabs are not allowed",
                    .{},
                );
                self.offset += 1;
            },
            '\r' => self.offset += 1,
            '\n' => {
                self.offset += 1;
                if (self.paren_depth == 0) {
                    try self.emit(.newline, .{ .start = self.offset - 1, .end = self.offset });
                    self.at_line_start = true;
                }
            },
            '#' => self.skipComment(),
            '(' => {
                self.paren_depth += 1;
                try self.single(.left_paren);
            },
            ')' => {
                if (self.paren_depth > 0) self.paren_depth -= 1;
                try self.single(.right_paren);
            },
            '[' => {
                self.paren_depth += 1;
                try self.single(.left_bracket);
            },
            ']' => {
                if (self.paren_depth > 0) self.paren_depth -= 1;
                try self.single(.right_bracket);
            },
            ',' => try self.single(.comma),
            ':' => try self.single(.colon),
            '.' => try self.single(.dot),
            '+' => try self.maybeAssign(.plus, .plus_assign),
            '*' => try self.maybeAssign(.star, .star_assign),
            '/' => try self.maybeAssign(.slash, .slash_assign),
            '%' => try self.maybeAssign(.percent, .percent_assign),
            '-' => {
                if (self.peek(1) == '>') {
                    try self.emit(.arrow, .{ .start = self.offset, .end = self.offset + 2 });
                    self.offset += 2;
                } else {
                    try self.maybeAssign(.minus, .minus_assign);
                }
            },
            '=' => {
                if (self.peek(1) == '=') {
                    try self.emit(.equal, .{ .start = self.offset, .end = self.offset + 2 });
                    self.offset += 2;
                } else {
                    try self.single(.assign);
                }
            },
            '!' => {
                if (self.peek(1) == '=') {
                    try self.emit(.not_equal, .{ .start = self.offset, .end = self.offset + 2 });
                    self.offset += 2;
                } else {
                    try self.diagnostics.add(
                        "luce.lex.character",
                        .{ .start = self.offset, .end = self.offset + 1 },
                        "unexpected character '!' (use 'not')",
                        .{},
                    );
                    self.offset += 1;
                }
            },
            '<' => {
                if (self.peek(1) == '=') {
                    try self.emit(.less_equal, .{ .start = self.offset, .end = self.offset + 2 });
                    self.offset += 2;
                } else {
                    try self.single(.less);
                }
            },
            '>' => {
                if (self.peek(1) == '=') {
                    try self.emit(.greater_equal, .{ .start = self.offset, .end = self.offset + 2 });
                    self.offset += 2;
                } else {
                    try self.single(.greater);
                }
            },
            '"' => try self.string(),
            '0'...'9' => try self.number(),
            'a'...'z', 'A'...'Z', '_' => try self.word(),
            else => {
                try self.diagnostics.add(
                    "luce.lex.character",
                    .{ .start = self.offset, .end = self.offset + 1 },
                    "unexpected character",
                    .{},
                );
                self.offset += 1;
            },
        }
    }

    fn peek(self: *const Lexer, ahead: usize) u8 {
        if (self.offset + ahead >= self.source.len) return 0;
        return self.source[self.offset + ahead];
    }

    fn single(self: *Lexer, kind: Kind) Error!void {
        try self.emit(kind, .{ .start = self.offset, .end = self.offset + 1 });
        self.offset += 1;
    }

    /// An operator that may be followed by '=' to form a compound
    /// assignment (`+` / `+=`, `*` / `*=`, ...).
    fn maybeAssign(self: *Lexer, bare: Kind, compound: Kind) Error!void {
        if (self.peek(1) == '=') {
            try self.emit(compound, .{ .start = self.offset, .end = self.offset + 2 });
            self.offset += 2;
        } else {
            try self.single(bare);
        }
    }

    fn emit(self: *Lexer, kind: Kind, span: Span) Error!void {
        try self.tokens.append(self.allocator, .{ .kind = kind, .span = span });
    }

    fn skipComment(self: *Lexer) void {
        while (self.offset < self.source.len and self.source[self.offset] != '\n') {
            self.offset += 1;
        }
    }

    fn word(self: *Lexer) Error!void {
        const start = self.offset;
        while (self.offset < self.source.len) {
            const character = self.source[self.offset];
            const part = (character >= 'a' and character <= 'z') or
                (character >= 'A' and character <= 'Z') or
                (character >= '0' and character <= '9') or character == '_';
            if (!part) break;
            self.offset += 1;
        }
        const span: Span = .{ .start = start, .end = self.offset };
        const text = span.slice(self.source);
        for (token_mod.keywords) |keyword| {
            if (std.mem.eql(u8, keyword.word, text)) {
                try self.emit(keyword.kind, span);
                return;
            }
        }
        try self.emit(.identifier, span);
    }

    fn number(self: *Lexer) Error!void {
        const start = self.offset;
        while (self.offset < self.source.len and isDigit(self.source[self.offset])) {
            self.offset += 1;
        }
        var is_float = false;
        if (self.offset < self.source.len and self.source[self.offset] == '.' and
            self.offset + 1 < self.source.len and isDigit(self.source[self.offset + 1]))
        {
            is_float = true;
            self.offset += 1;
            while (self.offset < self.source.len and isDigit(self.source[self.offset])) {
                self.offset += 1;
            }
        }
        if (self.offset < self.source.len and
            (self.source[self.offset] == 'e' or self.source[self.offset] == 'E'))
        {
            var look = self.offset + 1;
            if (look < self.source.len and
                (self.source[look] == '+' or self.source[look] == '-'))
            {
                look += 1;
            }
            if (look < self.source.len and isDigit(self.source[look])) {
                is_float = true;
                self.offset = look;
                while (self.offset < self.source.len and isDigit(self.source[self.offset])) {
                    self.offset += 1;
                }
            }
        }
        const span: Span = .{ .start = start, .end = self.offset };
        // A digit run immediately followed by identifier characters is
        // one malformed literal, not two tokens.
        if (self.offset < self.source.len) {
            const following = self.source[self.offset];
            if ((following >= 'a' and following <= 'z') or
                (following >= 'A' and following <= 'Z') or following == '_')
            {
                while (self.offset < self.source.len and
                    ((self.source[self.offset] >= 'a' and self.source[self.offset] <= 'z') or
                        (self.source[self.offset] >= 'A' and self.source[self.offset] <= 'Z') or
                        (self.source[self.offset] >= '0' and self.source[self.offset] <= '9') or
                        self.source[self.offset] == '_'))
                {
                    self.offset += 1;
                }
                try self.diagnostics.add(
                    "luce.lex.number",
                    .{ .start = start, .end = self.offset },
                    "malformed numeric literal",
                    .{},
                );
                return;
            }
        }
        try self.emit(if (is_float) .float_literal else .int_literal, span);
    }

    fn string(self: *Lexer) Error!void {
        const start = self.offset;
        self.offset += 1;
        while (self.offset < self.source.len) {
            const character = self.source[self.offset];
            if (character == '"') {
                self.offset += 1;
                const span: Span = .{ .start = start, .end = self.offset };
                if (!std.unicode.utf8ValidateSlice(span.slice(self.source))) {
                    try self.diagnostics.add(
                        "luce.lex.utf8",
                        span,
                        "string is not valid UTF-8",
                        .{},
                    );
                    return;
                }
                try self.emit(.string_literal, span);
                return;
            }
            if (character == '\n') break;
            if (character == '\\') {
                self.offset += 1;
                if (self.offset < self.source.len) {
                    switch (self.source[self.offset]) {
                        'n', 't', '\\', '"' => {},
                        else => try self.diagnostics.add(
                            "luce.lex.escape",
                            .{ .start = self.offset - 1, .end = self.offset + 1 },
                            "unknown escape (use \\n, \\t, \\\\, or \\\")",
                            .{},
                        ),
                    }
                }
            }
            self.offset += 1;
        }
        try self.diagnostics.add(
            "luce.lex.string",
            .{ .start = start, .end = self.offset },
            "unterminated string",
            .{},
        );
    }

    /// Scan an f-string to its closing quote and emit one `fstring`
    /// token.  Brace depth and nested string literals are tracked so a
    /// `"` or `}` inside `{...}` does not end the f-string early; the
    /// parser re-scans the interior to split chunks from holes.
    fn fstring(self: *Lexer) Error!void {
        const start = self.offset;
        self.offset += 2; // f"
        var depth: usize = 0;
        while (self.offset < self.source.len) {
            const character = self.source[self.offset];
            if (character == '\n') break;
            if (depth == 0) {
                if (character == '"') {
                    self.offset += 1;
                    const span: Span = .{ .start = start, .end = self.offset };
                    if (!std.unicode.utf8ValidateSlice(span.slice(self.source))) {
                        try self.diagnostics.add("luce.lex.utf8", span, "string is not valid UTF-8", .{});
                        return;
                    }
                    try self.emit(.fstring, span);
                    return;
                }
                if (character == '\\') {
                    self.offset += 2;
                    continue;
                }
                if (character == '{') {
                    if (self.peek(1) == '{') {
                        self.offset += 2;
                        continue;
                    }
                    depth = 1;
                }
                self.offset += 1;
            } else {
                // Inside a hole: skip nested strings whole, track brace
                // nesting.
                switch (character) {
                    '"' => self.skipNestedString(),
                    '{' => {
                        depth += 1;
                        self.offset += 1;
                    },
                    '}' => {
                        depth -= 1;
                        self.offset += 1;
                    },
                    else => self.offset += 1,
                }
            }
        }
        try self.diagnostics.add(
            "luce.lex.string",
            .{ .start = start, .end = self.offset },
            "unterminated f-string",
            .{},
        );
    }

    /// Advance past a `"..."` nested inside an f-string hole, honoring
    /// escapes, so its closing quote is not mistaken for the
    /// f-string's.  Stops at the end of input or a newline.
    fn skipNestedString(self: *Lexer) void {
        self.offset += 1; // opening "
        while (self.offset < self.source.len) {
            const character = self.source[self.offset];
            if (character == '\n') return;
            if (character == '\\') {
                self.offset += 2;
                continue;
            }
            self.offset += 1;
            if (character == '"') return;
        }
    }
};

fn isDigit(character: u8) bool {
    return character >= '0' and character <= '9';
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn lexKinds(allocator: Allocator, text: []const u8, expected: []const Kind) !void {
    var diagnostics = Diagnostics.init(allocator);
    defer diagnostics.deinit();
    const tokens = try lex(allocator, text, &diagnostics);
    defer allocator.free(tokens);
    try testing.expectEqual(@as(usize, 0), diagnostics.count());
    var kinds: std.ArrayList(Kind) = .empty;
    defer kinds.deinit(allocator);
    for (tokens) |item| try kinds.append(allocator, item.kind);
    try testing.expectEqualSlices(Kind, expected, kinds.items);
}

test "lexer produces layout tokens for indented blocks" {
    try lexKinds(testing.allocator,
        \\func evaluate(input: Input, output: Output):
        \\    let x = 1
        \\
    , &.{
        .keyword_func, .identifier, .left_paren,  .identifier, .colon,
        .identifier,   .comma,      .identifier,  .colon,      .identifier,
        .right_paren,  .colon,      .newline,     .indent,     .keyword_let,
        .identifier,   .assign,     .int_literal, .newline,    .dedent,
        .end_of_file,
    });
}

test "blank and comment lines carry no layout" {
    try lexKinds(testing.allocator,
        \\# heading
        \\
        \\let a = 2
        \\
        \\# trailing
    , &.{ .keyword_let, .identifier, .assign, .int_literal, .newline, .end_of_file });
}

test "parentheses suspend newlines" {
    try lexKinds(testing.allocator,
        \\let a = clamp(
        \\    1, 2,
        \\    3,
        \\)
    , &.{
        .keyword_let, .identifier,  .assign,      .identifier,  .left_paren,
        .int_literal, .comma,       .int_literal, .comma,       .int_literal,
        .comma,       .right_paren, .newline,     .end_of_file,
    });
}

test "operators, literals, and keywords lex" {
    try lexKinds(
        testing.allocator,
        "let ok = not (1.5e2 >= 2 and x != \"a b\")\n",
        &.{
            .keyword_let,   .identifier,     .assign,      .keyword_not, .left_paren,
            .float_literal, .greater_equal,  .int_literal, .keyword_and, .identifier,
            .not_equal,     .string_literal, .right_paren, .newline,     .end_of_file,
        },
    );
}

test "tabs, bad indentation, and unterminated strings diagnose" {
    const allocator = testing.allocator;
    var diagnostics = Diagnostics.init(allocator);
    defer diagnostics.deinit();
    const tokens = try lex(allocator, "\tlet a = \"open\n  bad = 1\n", &diagnostics);
    defer allocator.free(tokens);
    try testing.expect(diagnostics.count() >= 2);
}

test "arbitrary bytes never crash the lexer" {
    const allocator = testing.allocator;
    var noise: [512]u8 = undefined;
    var seed: u64 = 0x9e3779b97f4a7c15;
    for (&noise) |*byte| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        byte.* = @truncate(seed >> 33);
    }
    var diagnostics = Diagnostics.init(allocator);
    defer diagnostics.deinit();
    const tokens = try lex(allocator, &noise, &diagnostics);
    defer allocator.free(tokens);
    try testing.expect(tokens.len >= 1);
    try testing.expectEqual(Kind.end_of_file, tokens[tokens.len - 1].kind);
}

// Property fuzzing (Zig's tokenizer does exactly this in
// std/zig/tokenizer.zig): on Smith-generated bytes, assert the
// lexer's invariants rather than a fixed token list.  Under `zig
// build test` this runs the corpus plus one empty input — cheap and
// deterministic; `zig build test --fuzz` explores from the corpus.
test "fuzz: the lexer upholds its span invariants on any bytes" {
    try testing.fuzz({}, lexAnything, .{ .corpus = &.{
        "func main():\n    let x = 1\n",
        "\tlet a = \"open\n",
        "let s = \"\xff\xfe\"\n",
        "0x 1.2e 99999999999999999999\n",
        "let s = f\"a{x + 1}b{{c}}\"\n",
    } });
}

fn lexAnything(_: void, smith: *testing.Smith) anyerror!void {
    var buffer: [512]u8 = undefined;
    // Weight the stream toward plausible source (spaces, newlines,
    // quotes, printable ASCII) so the fuzzer spends its time near the
    // interesting states, not in pure noise.
    const length = smith.sliceWeightedBytes(&buffer, &.{
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .rangeAtMost(u8, 0x20, 0x7e, 5),
        .value(u8, ' ', 6),
        .value(u8, '\n', 6),
        .value(u8, '\t', 3),
        .value(u8, '"', 3),
        .value(u8, '#', 2),
    });
    const source = buffer[0..length];

    var diagnostics = Diagnostics.init(testing.allocator);
    defer diagnostics.deinit();
    const tokens = try lex(testing.allocator, source, &diagnostics);
    defer testing.allocator.free(tokens);

    // There is always at least the EOF token, and it is last.
    try testing.expect(tokens.len >= 1);
    try testing.expectEqual(Kind.end_of_file, tokens[tokens.len - 1].kind);

    // Spans are ordered, non-inverted, and inside the source.
    var previous_start: usize = 0;
    for (tokens) |item| {
        try testing.expect(item.span.start <= item.span.end);
        try testing.expect(item.span.end <= source.len);
        try testing.expect(item.span.start >= previous_start);
        previous_start = item.span.start;
    }

    // The EOF token is empty and sits exactly at the end.
    const last = tokens[tokens.len - 1].span;
    try testing.expectEqual(source.len, last.start);
    try testing.expectEqual(source.len, last.end);

    // Every diagnostic points inside the source too.
    for (0..diagnostics.count()) |index| {
        const item = diagnostics.at(index).?;
        try testing.expect(item.span.start <= item.span.end);
        try testing.expect(item.span.end <= source.len);
    }
}
