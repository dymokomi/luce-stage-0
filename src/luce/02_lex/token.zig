//! Luce tokens.
//!
//! A token is a kind plus the span it covers; there is no payload, so
//! every literal's *text* is read back out of the source by whoever
//! needs its value (the parser for strings, stage 4 for numbers).
//! Keep it that way: the token array is the hottest allocation in the
//! front end, and a span is two words.

const std = @import("std");
const source_mod = @import("../01_source.zig");

pub const Kind = enum {
    // Layout
    newline,
    /// One step deeper than the enclosing block.  Indents and dedents
    /// always balance: the lexer closes at end of input every block it
    /// opened.
    indent,
    dedent,
    end_of_file,

    // Words
    /// An ASCII name: a letter or `_`, then letters, digits or `_`.
    /// Keywords are recognized from the same run and get their own
    /// kinds, so an identifier is never a keyword.
    identifier,
    keyword_func,
    keyword_struct,
    keyword_let,
    keyword_var,
    keyword_if,
    keyword_elif,
    keyword_else,
    keyword_while,
    keyword_for,
    keyword_in,
    keyword_return,
    keyword_break,
    keyword_continue,
    keyword_and,
    keyword_or,
    keyword_not,
    keyword_true,
    keyword_false,
    keyword_new,
    keyword_import,
    keyword_give,
    keyword_copy,

    // Literals
    /// A decimal digit run.  Its value is stage 4's business: the
    /// lexer does not evaluate, so an out-of-range literal is
    /// `luce.sema.literal`, not a lexical error.
    int_literal,
    /// A decimal literal with a fraction, an exponent, or both.
    float_literal,
    /// `"..."`, quotes included; escapes are decoded by the parser.
    string_literal,
    /// f"...{expr}..." — the parser expands it into str()-wrapped
    /// concatenation; the token spans the whole f"..." including the
    /// leading f and both quotes.
    fstring,

    // Symbols
    left_paren,
    right_paren,
    left_bracket,
    right_bracket,
    comma,
    colon,
    dot,
    assign,
    plus_assign,
    minus_assign,
    star_assign,
    slash_assign,
    percent_assign,
    arrow,
    plus,
    minus,
    star,
    slash,
    percent,
    equal,
    not_equal,
    less,
    less_equal,
    greater,
    greater_equal,
};

pub const Token = struct {
    kind: Kind,
    span: source_mod.Span,
};

/// Every reserved word.  A word that matches one of these is that
/// keyword and cannot be a name — the analyzer never sees `let for`
/// as a declaration, it sees two keywords.
pub const keywords = [_]struct { word: []const u8, kind: Kind }{
    .{ .word = "func", .kind = .keyword_func },
    .{ .word = "struct", .kind = .keyword_struct },
    .{ .word = "let", .kind = .keyword_let },
    .{ .word = "var", .kind = .keyword_var },
    .{ .word = "if", .kind = .keyword_if },
    .{ .word = "elif", .kind = .keyword_elif },
    .{ .word = "else", .kind = .keyword_else },
    .{ .word = "while", .kind = .keyword_while },
    .{ .word = "for", .kind = .keyword_for },
    .{ .word = "in", .kind = .keyword_in },
    .{ .word = "return", .kind = .keyword_return },
    .{ .word = "break", .kind = .keyword_break },
    .{ .word = "continue", .kind = .keyword_continue },
    .{ .word = "and", .kind = .keyword_and },
    .{ .word = "or", .kind = .keyword_or },
    .{ .word = "not", .kind = .keyword_not },
    .{ .word = "true", .kind = .keyword_true },
    .{ .word = "false", .kind = .keyword_false },
    .{ .word = "new", .kind = .keyword_new },
    .{ .word = "import", .kind = .keyword_import },
    .{ .word = "give", .kind = .keyword_give },
    .{ .word = "copy", .kind = .keyword_copy },
};

/// The same table, arranged for lookup.  `keywords` stays the
/// declaration — one row per reserved word, readable and testable —
/// and this is derived from it at compile time, so the two can never
/// disagree.  It matters: every name in the file is looked up here,
/// and a linear walk of twenty-two `memcmp`s per identifier is the
/// hottest avoidable cost in the front end (Zig's own tokenizer keeps
/// its keywords in exactly this structure, for exactly this reason).
pub const keyword_map = std.StaticStringMap(Kind).initComptime(entries: {
    var rows: [keywords.len]struct { []const u8, Kind } = undefined;
    for (keywords, 0..) |keyword, index| rows[index] = .{ keyword.word, keyword.kind };
    break :entries rows;
});

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "the keyword table is unique, identifier-shaped, and one kind each" {
    for (keywords, 0..) |keyword, index| {
        try std.testing.expect(keyword.word.len > 0);
        for (keyword.word) |character| {
            try std.testing.expect(std.ascii.isLower(character));
        }
        for (keywords[index + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, keyword.word, other.word));
            try std.testing.expect(keyword.kind != other.kind);
        }
    }
}

test "the lookup map holds exactly the declared table, and nothing else" {
    try std.testing.expectEqual(keywords.len, keyword_map.kvs.len);
    for (keywords) |keyword| {
        try std.testing.expectEqual(keyword.kind, keyword_map.get(keyword.word).?);
    }
    for ([_][]const u8{ "", "fun", "funcs", "Func", "_let", "x", "returns" }) |word| {
        try std.testing.expect(keyword_map.get(word) == null);
    }
}
