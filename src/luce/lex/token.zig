//! Luce tokens.
//!
//! A token is a kind plus the span it covers; there is no payload, so
//! every literal's *text* is read back out of the source by whoever
//! needs its value (the parser for strings, stage 4 for numbers).
//! Keep it that way: the token array is the hottest allocation in the
//! front end, and a span is two words.

const std = @import("std");
const source_mod = @import("../source.zig");

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
    /// `static func` inside a struct or enum declares a namespace
    /// function rather than a method with an implied `self`.
    keyword_static,
    keyword_struct,
    /// `class Name:` — a **reference type** (docs/MEMORY.md D1): shared
    /// identity, heap-allocated, freed by ARC at the last reference.  Its
    /// declaration grammar is a struct's; only the kind differs.
    keyword_class,
    /// `deinit:` inside a class — the one non-callable lifecycle hook.
    /// It runs at the last strong release while the instance fields are
    /// still alive.
    keyword_deinit,
    /// `init(...)` inside a class — the construction lifecycle body.
    /// It establishes every stored field before the class identity exists.
    keyword_init,
    /// `interface Name:` — a named set of method contracts that a
    /// struct may explicitly implement.
    keyword_interface,
    /// `mutating func` on an interface requirement says that dispatch may
    /// replace a value receiver. Concrete methods keep body-based inference.
    keyword_mutating,
    /// `alias Name = Type` — a transparent, compile-time-only second
    /// spelling for an existing type.
    keyword_alias,
    /// `enum Name:` — a set of named constants at one integer width
    /// (docs/ENUMS.md D1).  A declaration keyword beside `struct`,
    /// because an enum declares a type the same way one does.
    keyword_enum,
    /// `union Name:` — one of a closed set of members, each optionally
    /// carrying a named field list (docs/UNION.md D1).  A declaration
    /// keyword beside `struct` and `enum`, because a union declares a
    /// type the same way both do.
    keyword_union,
    /// `match expr:` — dispatch over an enum or a union, one arm per
    /// member (docs/ENUMS.md R1, docs/UNION.md D5).  Union arms carry
    /// payload bindings rather than a second keyword.
    keyword_match,
    /// File-scope compile-time values and frozen containers.  `let`
    /// and `var` are function-scope bindings; the three declaration
    /// words have disjoint jobs (docs/CONSTANTS.md R-A).
    keyword_const,
    keyword_let,
    keyword_var,
    /// `weak var name: T?` and `weak field: T?` declare zeroing,
    /// non-owning storage. `weak` never names a type or an expression.
    keyword_weak,
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
    /// `a is b` compares the identity of two references to the same
    /// nominal class. Value equality remains `==`.
    keyword_is,
    keyword_true,
    keyword_false,
    keyword_import,
    /// `spawn f(args)` — run `f` on a worker with its own runtime and
    /// answer the `task` that owns it (docs/THREADS.md D2, D3).  A
    /// keyword rather than a builtin because its operand is a *call*
    /// that must not be made here, which no builtin's arguments can
    /// say: `spawn f(x)` never evaluates `f(x)`.
    keyword_spawn,
    /// The absent value of a `T?` (docs/FAILURE.md).  A keyword rather
    /// than a name, so nothing can shadow it and `none` never reads as
    /// a variable somebody forgot to declare.
    keyword_none,
    /// `try CALL` — propagate what a fallible call raised
    /// (docs/FAILURE.md).
    keyword_try,
    /// The implied receiver available in the body of every non-static
    /// function declared inside a struct or enum (docs/SELF.md).  A
    /// keyword rather than a name, so nothing can shadow it and no
    /// declaration can call something else `self`.
    keyword_self,
    /// `extern func name(...) -> R` — a foreign function's declared
    /// shape, with no body (docs/FFI.md).  A keyword rather than a
    /// contextual word, so the boundary is greppable and nothing can
    /// shadow it.
    keyword_extern,
    /// `a catch b`, and `EXPR catch:` opening a handler block.  A
    /// keyword rather than a reuse of `else`, because the two are
    /// different acts: `else` says "no value here, use this instead",
    /// `catch` says "it failed, and I am deliberately discarding a
    /// reason".
    keyword_catch,
    /// The one visibility marker (docs/VISIBILITY.md): a declaration is
    /// private to its module unless it says `pub`. Fully reserved rather
    /// than contextual, so `pub` never doubles as a binding name.
    keyword_pub,

    // Literals
    /// A decimal digit run.  Its value is stage 4's business: the
    /// lexer does not evaluate, so an out-of-range literal is
    /// `luce.sema.literal`, not a lexical error.
    int_literal,
    /// A decimal literal with a fraction, an exponent, or both.
    float_literal,
    /// `'x'` or `'\u{1F44B}'`, quotes included. The parser decodes and
    /// verifies that the spelling denotes exactly one Unicode scalar.
    char_literal,
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
    /// `{key: value}` — a map literal.  Braces never delimit blocks;
    /// layout remains indentation-based (docs/CONSTANTS.md R-B).
    left_brace,
    right_brace,
    comma,
    colon,
    dot,
    dot_dot,
    /// `?`, and only ever after a type name: `i64?`, `User?`.
    question,
    /// `!`, and only ever after a return type: `-> str!`, `-> !`.
    /// Never a prefix operator — `not` is the negation, and a `!x`
    /// that mis-lexes against `!=` is the mistake this grammar
    /// declines to make twice.
    bang,
    assign,
    plus_assign,
    minus_assign,
    star_assign,
    slash_assign,
    /// `//=`, the compound form of floor division.
    slash_slash_assign,
    percent_assign,
    arrow,
    /// `=>` — yields a value: an expression lambda's body and an
    /// expression `match` arm.  Distinct from `->` (declares a type)
    /// and `:` (introduces a statement suite).
    fat_arrow,
    plus,
    minus,
    /// The bit set (docs/BITWISE.md): `&`, `|`, `^`, `~`, `<<`, `>>`
    /// and the five compound-assignment forms.
    ampersand,
    pipe,
    caret,
    tilde,
    shift_left,
    shift_right,
    ampersand_assign,
    pipe_assign,
    caret_assign,
    shift_left_assign,
    shift_right_assign,
    star,
    slash,
    /// `//`, floor division — the integer pair with `%`
    /// (docs/NUMERICS.md).  It is not the start of a comment: a
    /// comment runs from `#` to the end of the line.
    slash_slash,
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
    .{ .word = "static", .kind = .keyword_static },
    .{ .word = "struct", .kind = .keyword_struct },
    .{ .word = "class", .kind = .keyword_class },
    .{ .word = "deinit", .kind = .keyword_deinit },
    .{ .word = "init", .kind = .keyword_init },
    .{ .word = "interface", .kind = .keyword_interface },
    .{ .word = "mutating", .kind = .keyword_mutating },
    .{ .word = "alias", .kind = .keyword_alias },
    .{ .word = "enum", .kind = .keyword_enum },
    .{ .word = "union", .kind = .keyword_union },
    .{ .word = "match", .kind = .keyword_match },
    .{ .word = "const", .kind = .keyword_const },
    .{ .word = "let", .kind = .keyword_let },
    .{ .word = "var", .kind = .keyword_var },
    .{ .word = "weak", .kind = .keyword_weak },
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
    .{ .word = "is", .kind = .keyword_is },
    .{ .word = "true", .kind = .keyword_true },
    .{ .word = "false", .kind = .keyword_false },
    .{ .word = "import", .kind = .keyword_import },
    .{ .word = "spawn", .kind = .keyword_spawn },
    .{ .word = "none", .kind = .keyword_none },
    .{ .word = "try", .kind = .keyword_try },
    .{ .word = "catch", .kind = .keyword_catch },
    .{ .word = "self", .kind = .keyword_self },
    .{ .word = "pub", .kind = .keyword_pub },
    .{ .word = "extern", .kind = .keyword_extern },
};

/// The same table, arranged for lookup.  `keywords` stays the
/// declaration — one row per reserved word, readable and testable —
/// and this is derived from it at compile time, so the two can never
/// disagree.  It matters: every name in the file is looked up here,
/// and a linear walk of the whole keyword table per identifier is the
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

test "static is a reserved member-function word" {
    try std.testing.expectEqual(Kind.keyword_static, keyword_map.get("static").?);
    try std.testing.expect(keyword_map.get("statics") == null);
}

test "const is a reserved file-scope declaration word" {
    try std.testing.expectEqual(Kind.keyword_const, keyword_map.get("const").?);
    try std.testing.expect(keyword_map.get("constants") == null);
}
