//! Luce tokens.

const source_mod = @import("source.zig");

pub const Kind = enum {
    // Layout
    newline,
    indent,
    dedent,
    end_of_file,

    // Words
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
    int_literal,
    float_literal,
    string_literal,

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
