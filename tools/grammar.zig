//! The Luce TextMate grammar, generated from the language's own tables.
//!
//!   zig build grammar   # rewrites tools/vscode-luce/syntaxes/luce.tmLanguage.json
//!
//! **Generated because the hand-written one drifted.** The old grammar had
//! no mechanical relationship to the lexer, type vocabulary, builtins, or
//! receiver methods. It therefore kept removed words and missed implemented
//! ones across several language revisions. Every word below is read from the
//! table the compiler dispatches on, and
//! `test "the committed grammar is what the generator emits"` fails
//! the suite the moment the two disagree.
//!
//! **It imports `luce` rather than copying its tables.**  That is the
//! difference between this and `www/luce/src/highlight.zig`, which copies
//! deliberately: the site generator drives the *built binaries* as
//! subprocesses so it can verify what the toolchain really does, and
//! linking the language in would undercut that.  This generator
//! verifies nothing about a running program — it turns the language's
//! tables into one JSON file — so the import is free, and a copy would
//! only be one more thing to keep honest.
//!
//! The six classes and what they read:
//!
//!   keywords  `lex/token.zig`'s `keywords`, by kind
//!   ownership the same table's `new` and `spawn`
//!   symbols   `lex/token.zig`'s `Kind`, one row per punctuation
//!             and operator token — map braces and the bit set included
//!   types     `support/types.zig`'s `builtin_names`
//!   builtins  `semantics/builtins.zig`'s `builtins`
//!   methods   the same file's receiver-method tables
//!
//! A keyword the language gains reaches the grammar by itself; a
//! keyword whose colour nobody has decided stops the generator by
//! name rather than being quietly left out.  The symbols are the same
//! bargain one step further: their spellings live here, because the
//! lexer spells them in a `switch` and not in a table, and two tests
//! hold the copy honest — every symbol kind must have a row, and
//! every row's text must lex back to the kind it claims.  The bit set
//! (`& | ^ ~ << >>` and the five compound forms) reached the language
//! and not the grammar, which is the drift that argued for the table.

const std = @import("std");
const Allocator = std.mem.Allocator;
const luce = @import("luce");

/// Where the committed grammar lives, relative to the repository root.
/// Named once so the message a failing pin test prints and the path
/// `build.zig` copies to are the same string a reader can grep for.
pub const committed_path = "tools/vscode-luce/syntaxes/luce.tmLanguage.json";

pub const Error = error{
    /// A keyword in the lexer's table that `keywordClass` does not
    /// name.  Fail rather than emit a grammar missing a word: an
    /// uncoloured keyword is a silent wrong answer, and this is the
    /// mistake the old grammar shipped for a year.
    UnclassifiedKeyword,
} || Allocator.Error;

// ---------------------------------------------------------------------------
// The word classes
// ---------------------------------------------------------------------------

/// What a reserved word reads as.  One class per TextMate scope, so
/// the classification and the colouring are the same decision.
const Class = enum {
    /// `if`, `while`, `return` — the shape of the program.
    control,
    /// `and`, `or`, `not` — operators spelled as words.
    word_operator,
    /// `func`, `struct`, `const`, `let`, `var` — what a declaration
    /// opens with.
    storage,
    /// `pub`, `static` — declaration modifiers.
    /// `storage.modifier` is the scope existing grammars give this
    /// class, so themes already distinguish them from the `func` they
    /// precede (docs/VISIBILITY.md, docs/SELF.md).
    modifier,
    /// `import`.
    import,
    /// `try`, `catch` (docs/FAILURE.md).
    exception,
    /// `true`, `false`, `none` — values with no other spelling.
    constant,
    /// `new` and `spawn`: the words that make a reference — a heap
    /// object, or a worker holding one.  They keep a class of their own
    /// because a reader scanning a file wants to see where allocation
    /// and concurrency enter (docs/MEMORY.md, docs/THREADS.md).
    ownership,
    /// `self` — a name the language supplies rather than the program.
    /// `variable.language` is the scope every grammar since TextMate's
    /// own has given Python's `self`, Ruby's `self` and JavaScript's
    /// `this`, so a theme already has a colour for it.
    receiver,

    fn scope(self: Class) []const u8 {
        return switch (self) {
            .control => "keyword.control.luce",
            .word_operator => "keyword.operator.word.luce",
            .storage => "storage.type.luce",
            .modifier => "storage.modifier.luce",
            .import => "keyword.control.import.luce",
            .exception => "keyword.control.exception.luce",
            .constant => "constant.language.luce",
            .ownership => "keyword.other.ownership.luce",
            .receiver => "variable.language.luce",
        };
    }
};

/// Every class, in the order their rules are written.  Iterated rather
/// than listed twice, so a new class cannot be added without a rule.
const classes = [_]Class{
    .control,  .word_operator, .storage,  .modifier,
    .import,   .exception,     .constant, .ownership,
    .receiver,
};

/// The class each keyword the lexer reserves belongs to.
///
/// Every keyword kind is named explicitly and `else` yields null, so
/// adding one to `lex/token.zig` and not here is caught — by the
/// generator, which refuses to write a grammar it knows is short a
/// word, and by the test below, which names the keyword.
fn keywordClass(kind: luce.lex.Kind) ?Class {
    return switch (kind) {
        .keyword_if,
        .keyword_elif,
        .keyword_else,
        .keyword_while,
        .keyword_for,
        .keyword_in,
        .keyword_return,
        .keyword_break,
        .keyword_continue,
        .keyword_pass,
        // `match` is a dispatch statement, so it is control flow — the
        // class every editor already colours `switch` with.
        .keyword_match,
        => .control,

        // The logical word operators read as keywords in a Python-shaped
        // language and are coloured like them by every theme — `.control`
        // is the class themes reliably paint, and the bundled editor
        // already lumps them with keywords.  `is` (identity) stays a word
        // operator, its own distinct act.
        .keyword_and, .keyword_or, .keyword_not => .control,
        .keyword_is => .word_operator,

        .keyword_func,
        .keyword_struct,
        // `class` declares a reference type beside `struct`'s value type
        // (docs/MEMORY.md), and wears its class.
        .keyword_class,
        .keyword_init,
        .keyword_deinit,
        .keyword_interface,
        .keyword_alias,
        // `enum` and `union` declare types beside `struct`, and wear
        // its class.
        .keyword_enum,
        .keyword_union,
        .keyword_const,
        .keyword_let,
        .keyword_var,
        // `extern` declares a foreign function's shape beside `func`,
        // and wears the declaration class (docs/FFI.md).
        .keyword_extern,
        => .storage,

        .keyword_pub,
        .keyword_static,
        // `mutating` qualifies an interface requirement; concrete methods
        // infer receiver writes from their bodies.
        .keyword_mutating,
        // `weak` qualifies a storage place: it neither declares a binding
        // by itself nor changes the value's type.
        .keyword_weak,
        => .modifier,

        .keyword_import => .import,

        .keyword_try, .keyword_catch => .exception,

        .keyword_true, .keyword_false, .keyword_none => .constant,

        // `spawn` makes a resource — a worker with a heap of its own
        // (docs/THREADS.md).
        .keyword_spawn => .ownership,

        .keyword_self => .receiver,

        else => null,
    };
}

/// The two builtins that end a run, and the scope each gets.
///
/// `error` raises — a caller may `try` it on or `catch` it — and
/// `trap` stops the program dead, so they are two sentences and not
/// one; they share a colour because what a reader wants from either
/// is to see, at a glance, every place this program can stop.  Both
/// are matched on what they lower to rather than on their spelling,
/// so renaming one in the language renames it here.
fn stoppingScope(builtin: luce.semantics.Builtin) ?[]const u8 {
    return switch (builtin.kind) {
        .raise_error => "keyword.control.raise.luce",
        .trap_message => "keyword.control.trap.luce",
        else => null,
    };
}

/// Reserved names the language spells nowhere else.
///
/// `range` is *syntax*: the parser recognises it only in
/// `for i in range(a, b)` (`parse/grammar.zig`) and there is no
/// entry for it in the builtin table.  `discard` is syntax for the
/// same reason from the other end — it takes any type and answers
/// none, which is not a row the builtin table can hold, so the
/// statement walker recognises it directly.  Both are written like a
/// call and read like one, so both are coloured like one.
const reserved_syntax = [_][]const u8{ "range", "discard" };

/// Reserved and unspellable: a name the language keeps out of a
/// program's reach with nothing behind it.
///
/// Reserved words that name nothing callable.  Empty since `slice`
/// stopped being reserved (owner, 2026-08-04: the syntax `xs[a:b]` is
/// the feature, so the word needs no claiming) — and it stays here so
/// the next fossil has a place to be noticed instead of coloured.
const unspellable = [_][]const u8{};

// ---------------------------------------------------------------------------
// The symbols
// ---------------------------------------------------------------------------

/// What a symbol token reads as.  One role per TextMate scope, split
/// into the operators and the punctuation because the grammar carries
/// them in two groups a reader can turn off separately.
const Role = enum {
    /// `->`, which is neither an operator on values nor punctuation:
    /// it introduces the answer a declaration, function type, or
    /// expression lambda gives.
    function_return,
    comparison,
    assignment,
    arithmetic,
    /// `& | ^ ~ << >>` — the bit set (docs/BITWISE.md).
    bitwise,
    /// `?`: the optional marker, and Luce spells nothing else with a
    /// question mark — there is no conditional expression.
    optional,
    /// `!`: the fallible marker (docs/FAILURE.md), never a prefix
    /// negation — `not` is the negation.
    fallible,
    /// `..`: the inclusive range between two literals in a match
    /// arm's patterns, and nothing else yet.
    range,
    group_begin,
    group_end,
    brackets_begin,
    brackets_end,
    braces_begin,
    braces_end,
    separator_comma,
    separator_colon,
    accessor,

    fn scope(self: Role) []const u8 {
        return switch (self) {
            .function_return => "keyword.operator.function-return.luce",
            .comparison => "keyword.operator.comparison.luce",
            .assignment => "keyword.operator.assignment.luce",
            .arithmetic => "keyword.operator.arithmetic.luce",
            .bitwise => "keyword.operator.bitwise.luce",
            .optional => "keyword.operator.optional.luce",
            .fallible => "keyword.operator.fallible.luce",
            .range => "keyword.operator.range.luce",
            .group_begin => "punctuation.section.group.begin.luce",
            .group_end => "punctuation.section.group.end.luce",
            .brackets_begin => "punctuation.section.brackets.begin.luce",
            .brackets_end => "punctuation.section.brackets.end.luce",
            .braces_begin => "punctuation.section.braces.begin.luce",
            .braces_end => "punctuation.section.braces.end.luce",
            .separator_comma => "punctuation.separator.comma.luce",
            .separator_colon => "punctuation.separator.colon.luce",
            .accessor => "punctuation.accessor.luce",
        };
    }

    /// True for the roles the `#punctuation` group carries.  Every
    /// other role is an operator, and the two groups are emitted
    /// separately.
    fn isPunctuation(self: Role) bool {
        return switch (self) {
            .group_begin,
            .group_end,
            .brackets_begin,
            .brackets_end,
            .braces_begin,
            .braces_end,
            .separator_comma,
            .separator_colon,
            .accessor,
            => true,
            else => false,
        };
    }
};

/// One symbol token: the kind the lexer gives it, the one way it is
/// spelled, and what it reads as.
const Symbol = struct { kind: luce.lex.Kind, text: []const u8, role: Role };

/// Every symbol the lexer has a kind for, spelled and classed.
///
/// **The one table here that is a copy**, because the lexer spells
/// its symbols in a `switch` over bytes rather than in a table there
/// is anything to read.  Two tests pay for the copy: one fails when a
/// symbol kind has no row — the way the bit set arrived and the
/// grammar did not hear — and one lexes every row's text back and
/// checks it comes out as the kind claimed, so a spelling that moves
/// in the language moves here or the suite says which row lied.
const symbols = [_]Symbol{
    .{ .kind = .arrow, .text = "->", .role = .function_return },
    .{ .kind = .fat_arrow, .text = "=>", .role = .function_return },

    .{ .kind = .equal, .text = "==", .role = .comparison },
    .{ .kind = .not_equal, .text = "!=", .role = .comparison },
    .{ .kind = .less_equal, .text = "<=", .role = .comparison },
    .{ .kind = .greater_equal, .text = ">=", .role = .comparison },
    .{ .kind = .less, .text = "<", .role = .comparison },
    .{ .kind = .greater, .text = ">", .role = .comparison },

    .{ .kind = .shift_left_assign, .text = "<<=", .role = .assignment },
    .{ .kind = .shift_right_assign, .text = ">>=", .role = .assignment },
    .{ .kind = .slash_slash_assign, .text = "//=", .role = .assignment },
    .{ .kind = .plus_assign, .text = "+=", .role = .assignment },
    .{ .kind = .minus_assign, .text = "-=", .role = .assignment },
    .{ .kind = .star_assign, .text = "*=", .role = .assignment },
    .{ .kind = .slash_assign, .text = "/=", .role = .assignment },
    .{ .kind = .percent_assign, .text = "%=", .role = .assignment },
    .{ .kind = .ampersand_assign, .text = "&=", .role = .assignment },
    .{ .kind = .pipe_assign, .text = "|=", .role = .assignment },
    .{ .kind = .caret_assign, .text = "^=", .role = .assignment },
    .{ .kind = .assign, .text = "=", .role = .assignment },

    .{ .kind = .shift_left, .text = "<<", .role = .bitwise },
    .{ .kind = .shift_right, .text = ">>", .role = .bitwise },
    .{ .kind = .ampersand, .text = "&", .role = .bitwise },
    .{ .kind = .pipe, .text = "|", .role = .bitwise },
    .{ .kind = .caret, .text = "^", .role = .bitwise },
    .{ .kind = .tilde, .text = "~", .role = .bitwise },

    .{ .kind = .slash_slash, .text = "//", .role = .arithmetic },
    .{ .kind = .plus, .text = "+", .role = .arithmetic },
    .{ .kind = .minus, .text = "-", .role = .arithmetic },
    .{ .kind = .star, .text = "*", .role = .arithmetic },
    .{ .kind = .slash, .text = "/", .role = .arithmetic },
    .{ .kind = .percent, .text = "%", .role = .arithmetic },

    .{ .kind = .question, .text = "?", .role = .optional },
    .{ .kind = .bang, .text = "!", .role = .fallible },

    .{ .kind = .left_paren, .text = "(", .role = .group_begin },
    .{ .kind = .right_paren, .text = ")", .role = .group_end },
    .{ .kind = .left_bracket, .text = "[", .role = .brackets_begin },
    .{ .kind = .right_bracket, .text = "]", .role = .brackets_end },
    .{ .kind = .left_brace, .text = "{", .role = .braces_begin },
    .{ .kind = .right_brace, .text = "}", .role = .braces_end },
    .{ .kind = .comma, .text = ",", .role = .separator_comma },
    .{ .kind = .colon, .text = ":", .role = .separator_colon },
    .{ .kind = .dot, .text = ".", .role = .accessor },
    .{ .kind = .dot_dot, .text = "..", .role = .range },
};

/// True for the token kinds that are neither layout, nor a word, nor
/// a literal — the ones `symbols` must have a row for.  Named as an
/// exclusion because that is how the enum is written: everything left
/// over after the four groups above it is spelled with punctuation.
fn isSymbolKind(kind: luce.lex.Kind) bool {
    return switch (kind) {
        .newline,
        .indent,
        .dedent,
        .end_of_file,
        .identifier,
        .int_literal,
        .float_literal,
        .string_literal,
        .char_literal,
        .fstring,
        => false,
        else => !std.mem.startsWith(u8, @tagName(kind), "keyword_"),
    };
}

// ---------------------------------------------------------------------------
// Reading the language's tables
// ---------------------------------------------------------------------------

/// A growable, order-preserving list of words that refuses duplicates.
/// Order is the tables' own, so the emitted regex is a function of the
/// language and nothing else — the property that makes the generator
/// deterministic.
const Words = struct {
    items: std.ArrayList([]const u8) = .empty,
    gpa: Allocator,

    fn deinit(self: *Words) void {
        self.items.deinit(self.gpa);
    }

    fn add(self: *Words, word: []const u8) Allocator.Error!void {
        if (self.has(word)) return;
        try self.items.append(self.gpa, word);
    }

    fn addAll(self: *Words, list: []const []const u8) Allocator.Error!void {
        for (list) |word| try self.add(word);
    }

    fn has(self: *const Words, word: []const u8) bool {
        for (self.items.items) |entry| {
            if (std.mem.eql(u8, entry, word)) return true;
        }
        return false;
    }

    /// `a|b|c`, ready to sit inside a group.
    fn joined(self: *const Words, gpa: Allocator) Allocator.Error![]u8 {
        return std.mem.join(gpa, "|", self.items.items);
    }
};

/// The words of one class, in the lexer's table order.
fn keywordsOf(gpa: Allocator, class: Class) Error!Words {
    var words: Words = .{ .gpa = gpa };
    errdefer words.deinit();
    for (luce.lex.keywords) |keyword| {
        const found = keywordClass(keyword.kind) orelse return Error.UnclassifiedKeyword;
        if (found == class) try words.add(keyword.word);
    }
    return words;
}

/// The one word a keyword kind is spelled with — for the declaration
/// rules, which have to name `func` and `struct` in a regex of their
/// own rather than in an alternation.
fn spelling(kind: luce.lex.Kind) []const u8 {
    for (luce.lex.keywords) |keyword| {
        if (keyword.kind == kind) return keyword.word;
    }
    unreachable; // every kind `keywordClass` names is in the table.
}

/// The builtin type names, read from the compiler's own table rather
/// than guessed from a name's case. User-declared types follow their own
/// capitalized-name grammar rule.
fn typeNames(gpa: Allocator) Allocator.Error!Words {
    var words: Words = .{ .gpa = gpa };
    errdefer words.deinit();
    try words.addAll(&luce.types.builtin_names);
    // `never` is a type name a program may write (a function's return),
    // but it is not a builtin the resolver dispatches like `str`: it is
    // reserved and handled on its own path, so it is named here rather
    // than read out of the builtin table (docs/FAILURE.md).
    try words.add("never");
    return words;
}

/// The free builtins, host-gated or not.  Two are left out and each
/// has a rule of its own: `error` and `trap` are the two ways a program
/// stops.
fn builtinNames(gpa: Allocator, host: bool) Allocator.Error!Words {
    var words: Words = .{ .gpa = gpa };
    errdefer words.deinit();
    if (!host) try words.addAll(&reserved_syntax);
    for (luce.semantics.builtins) |builtin| {
        if (stoppingScope(builtin) != null) continue;
        if (builtin.host == host) try words.add(builtin.name);
    }
    return words;
}

/// The stopping builtins, one word to a rule, in the builtin table's
/// order.  One rule each rather than an alternation: the two scopes
/// differ, and a theme that wants to colour raising and trapping
/// apart can, while `package.json` colours both of them red.
fn stoppingRules(arena: Allocator) Allocator.Error![]const Rule {
    var rules: std.ArrayList(Rule) = .empty;
    for (luce.semantics.builtins) |builtin| {
        const scope = stoppingScope(builtin) orelse continue;
        try rules.append(arena, .{ .match = .{
            .scope = scope,
            .pattern = try std.fmt.allocPrint(arena, "\\b{s}\\b", .{builtin.name}),
        } });
    }
    return rules.toOwnedSlice(arena);
}

/// The symbol rules of one half of the table — the punctuation or
/// everything else — **longest spelling first**.
///
/// The order is the whole correctness argument.  TextMate takes the
/// match that starts earliest and, among those, the rule written
/// first; so `<<=` must be tried before `<<`, `<<` before `<`, and
/// `==` before `=`, or a compound assignment reads as a comparison
/// with a stray `=` after it.  Sorting by length gives that for every
/// pair at once, and rows that stay adjacent afterwards and share a
/// role are merged into one alternation, which is only a smaller file
/// and never a different answer.
fn symbolRules(arena: Allocator, punctuation: bool) Allocator.Error![]const Rule {
    const rows = try sortedSymbols(arena, punctuation);
    var rules: std.ArrayList(Rule) = .empty;
    var start: usize = 0;
    while (start < rows.len) {
        var end = start + 1;
        while (end < rows.len and rows[end].role == rows[start].role) end += 1;
        var alternatives: std.ArrayList([]const u8) = .empty;
        for (rows[start..end]) |row| {
            try alternatives.append(arena, try escaped(arena, row.text));
        }
        try rules.append(arena, .{ .match = .{
            .scope = rows[start].role.scope(),
            .pattern = try std.mem.join(arena, "|", alternatives.items),
        } });
        start = end;
    }
    return rules.toOwnedSlice(arena);
}

/// One half of the symbol table, longest spelling first and the
/// table's own order within a length — a stable sort, so the output is
/// a function of the table and nothing else.
fn sortedSymbols(arena: Allocator, punctuation: bool) Allocator.Error![]Symbol {
    var rows: std.ArrayList(Symbol) = .empty;
    for (symbols) |symbol| {
        if (symbol.role.isPunctuation() == punctuation) try rows.append(arena, symbol);
    }
    std.sort.insertion(Symbol, rows.items, {}, struct {
        fn longerFirst(_: void, left: Symbol, right: Symbol) bool {
            return left.text.len > right.text.len;
        }
    }.longerFirst);
    return rows.toOwnedSlice(arena);
}

/// A literal spelling as a regex: every byte a regex would read as
/// syntax gets a backslash.  Applied to all of them rather than to the
/// ones that need it today, so a symbol the language gains cannot
/// arrive as an accidental metacharacter.
fn escaped(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |byte| {
        if (std.mem.indexOfScalar(u8, "\\^$.[]|()?*+{}", byte) != null) try out.append(arena, '\\');
        try out.append(arena, byte);
    }
    return out.toOwnedSlice(arena);
}

/// Every name that means the language only behind a `.`: the four
/// receiver tables plus the two `str` primitives. Several of them —
/// `find`, `get`, `clear`, `values` — are words a program may
/// perfectly well use for a function of its own, which is why they are
/// coloured after the dot and never before it.
fn methodNames(gpa: Allocator) Allocator.Error!Words {
    var words: Words = .{ .gpa = gpa };
    errdefer words.deinit();
    try words.addAll(&luce.semantics.list_methods);
    try words.addAll(&luce.semantics.array_methods);
    try words.addAll(&luce.semantics.map_methods);
    try words.addAll(&luce.semantics.builder_methods);
    try words.addAll(&luce.semantics.task_methods);
    for (luce.semantics.string_methods) |primitive| try words.add(primitive.name);
    return words;
}

// ---------------------------------------------------------------------------
// The grammar, as data
// ---------------------------------------------------------------------------

/// One numbered capture group and the scope it gets.
const Capture = struct { group: []const u8, scope: []const u8 };

const Match = struct {
    scope: ?[]const u8 = null,
    pattern: []const u8,
    captures: []const Capture = &.{},
};

/// A `begin`/`end` pair with its own patterns inside — a string, or an
/// f-string hole.
const Region = struct {
    scope: []const u8,
    begin: []const u8,
    begin_captures: []const Capture = &.{},
    end: []const u8,
    end_captures: []const Capture = &.{},
    patterns: []const Rule = &.{},
};

const Rule = union(enum) {
    include: []const u8,
    match: Match,
    region: Region,
};

/// One named entry of the grammar's `repository`.
const Group = struct { name: []const u8, patterns: []const Rule };

/// What a reader is told when they open the generated file.  TextMate
/// grammars carry no comments; VS Code's own grammars use this key for
/// exactly this, and every engine ignores it.
const preamble = [_][]const u8{
    "This file is GENERATED from the Luce compiler's own word tables.",
    "Do not edit it: run `zig build grammar` and commit the result.",
    "The generator is tools/grammar.zig, and a test in `zig build test` fails when this file and the language disagree.",
};

// ---------------------------------------------------------------------------
// Emitting
// ---------------------------------------------------------------------------

/// Build the whole grammar.  The caller owns the returned bytes.
pub fn emit(gpa: Allocator) Error![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Every alternation the rules below need, read from the language.
    var class_patterns: [classes.len][]const u8 = undefined;
    for (classes, 0..) |class, index| {
        var words = try keywordsOf(arena, class);
        class_patterns[index] = try std.fmt.allocPrint(
            arena,
            "\\b(?:{s})\\b",
            .{try words.joined(arena)},
        );
    }

    var type_words = try typeNames(arena);
    const type_pattern = try std.fmt.allocPrint(
        arena,
        "\\b(?:{s})\\b",
        .{try type_words.joined(arena)},
    );

    var pure_words = try builtinNames(arena, false);
    const pure_pattern = try std.fmt.allocPrint(
        arena,
        "\\b(?:{s})\\b",
        .{try pure_words.joined(arena)},
    );

    var host_words = try builtinNames(arena, true);
    const host_pattern = try std.fmt.allocPrint(
        arena,
        "\\b(?:{s})\\b",
        .{try host_words.joined(arena)},
    );

    var method_words = try methodNames(arena);
    const method_pattern = try std.fmt.allocPrint(
        arena,
        "(\\.)({s})\\b",
        .{try method_words.joined(arena)},
    );

    // A name starts with a letter and carries letters, digits and
    // underscores after it [VISIBILITY.md R3].  Written once and used
    // by every rule that names something, so the one place a leading
    // underscore is refused is `#names` below.
    const name = "[A-Za-z][A-Za-z0-9_]*";

    const func_pattern = try std.fmt.allocPrint(
        arena,
        "\\b({s})\\s+({s})",
        .{ spelling(.keyword_func), name },
    );
    const struct_pattern = try std.fmt.allocPrint(
        arena,
        "\\b({s})\\s+({s})",
        .{ spelling(.keyword_struct), name },
    );
    const alias_pattern = try std.fmt.allocPrint(
        arena,
        "\\b({s})\\s+({s})",
        .{ spelling(.keyword_alias), name },
    );
    const binding_pattern = try std.fmt.allocPrint(
        arena,
        "\\b({s}|{s}|{s})\\s+({s})",
        .{
            spelling(.keyword_const),
            spelling(.keyword_let),
            spelling(.keyword_var),
            name,
        },
    );
    // `import std.zip` and `import geometry` alike: the module path is
    // one name or several joined by dots, and the `std.` namespace is
    // reserved rather than special (docs/STD.md).
    const import_pattern = try std.fmt.allocPrint(
        arena,
        "\\b({s})\\s+({s}(?:\\.{s})*)",
        .{ spelling(.keyword_import), name, name },
    );

    // -- comments ----------------------------------------------------------
    // `#` to end of line, and there is no block form (lex/lexer.zig).
    const comment_rules = [_]Rule{
        .{ .match = .{
            .scope = "comment.line.number-sign.luce",
            .pattern = "(#).*$",
            .captures = &.{.{ .group = "1", .scope = "punctuation.definition.comment.luce" }},
        } },
    };

    // -- f-string holes ----------------------------------------------------
    // A hole is one expression. Its inner rules enter strings and a
    // recursive brace group before ordinary code, so a quote or map
    // closing brace inside the expression cannot end the outer region.
    // Repository includes make the recursion structural: every nested
    // region consumes its opener before it can include itself again.
    const escape_rules = [_]Rule{
        .{ .match = .{
            .scope = "constant.character.escape.luce",
            .pattern = "\\\\[ntr\\\\\"]",
        } },
        .{ .match = .{
            .scope = "invalid.illegal.escape.luce",
            .pattern = "\\\\.",
        } },
    };
    const character_escape_rules = [_]Rule{
        .{ .match = .{
            .scope = "constant.character.escape.luce",
            .pattern = "\\\\(?:[ntr\\\\'\"]|u\\{[0-9A-Fa-f]+\\})",
        } },
        .{ .match = .{
            .scope = "invalid.illegal.escape.luce",
            .pattern = "\\\\.",
        } },
    };
    const nested_code_rules = [_]Rule{
        .{ .include = "#comments" },
        .{ .include = "#strings" },
        .{ .include = "#braces" },
        .{ .include = "#code" },
    };
    const hole_rules = [_]Rule{
        // `{{` and `}}` are literal braces and must be tried first:
        // both they and a hole begin at a `{`.
        .{ .match = .{
            .scope = "constant.character.escape.luce",
            .pattern = "\\{\\{|\\}\\}",
        } },
        .{ .region = .{
            .scope = "meta.interpolation.luce",
            .begin = "\\{",
            .begin_captures = &.{.{ .group = "0", .scope = "punctuation.section.interpolation.begin.luce" }},
            .end = "\\}",
            .end_captures = &.{.{ .group = "0", .scope = "punctuation.section.interpolation.end.luce" }},
            .patterns = &nested_code_rules,
        } },
        // A `}` that closes nothing: `luce.parse.fstring`, "unmatched
        // close brace in f-string (double it for a literal)".
        .{ .match = .{
            .scope = "invalid.illegal.unmatched-brace.luce",
            .pattern = "\\}",
        } },
        escape_rules[0],
        escape_rules[1],
    };

    // -- strings -----------------------------------------------------------
    // One line each: an unterminated literal ends at the newline, which
    // is what the lexer reports too.
    const string_rules = [_]Rule{
        .{
            .region = .{
                .scope = "string.quoted.double.interpolated.luce",
                // `\b` before the `f` is the lexer's rule: `f"` opens an
                // f-string only when the byte before it is not part of a
                // name, so `prefix f"x"` interpolates and `deaf"x"` does
                // not (lex/lexer.zig).
                .begin = "\\bf\"",
                .begin_captures = &.{.{ .group = "0", .scope = "punctuation.definition.string.begin.luce" }},
                .end = "(\")|$",
                .end_captures = &.{.{ .group = "1", .scope = "punctuation.definition.string.end.luce" }},
                .patterns = &hole_rules,
            },
        },
        .{ .region = .{
            .scope = "string.quoted.double.luce",
            .begin = "\"",
            .begin_captures = &.{.{ .group = "0", .scope = "punctuation.definition.string.begin.luce" }},
            .end = "(\")|$",
            .end_captures = &.{.{ .group = "1", .scope = "punctuation.definition.string.end.luce" }},
            .patterns = &escape_rules,
        } },
        .{ .region = .{
            .scope = "constant.character.luce",
            .begin = "'",
            .begin_captures = &.{.{ .group = "0", .scope = "punctuation.definition.character.begin.luce" }},
            .end = "(')|$",
            .end_captures = &.{.{ .group = "1", .scope = "punctuation.definition.character.end.luce" }},
            .patterns = &character_escape_rules,
        } },
    };

    // Braces are a proper recursive region inside an interpolation.
    // Outside one, `#punctuation` still colours the same bytes without
    // assigning a map-specific meaning to every brace in the file.
    const brace_rules = [_]Rule{
        .{ .region = .{
            .scope = "meta.braces.luce",
            .begin = "\\{",
            .begin_captures = &.{.{ .group = "0", .scope = "punctuation.section.braces.begin.luce" }},
            .end = "\\}",
            .end_captures = &.{.{ .group = "0", .scope = "punctuation.section.braces.end.luce" }},
            .patterns = &nested_code_rules,
        } },
    };

    // -- declarations ------------------------------------------------------
    const declaration_rules = [_]Rule{
        .{ .match = .{
            .pattern = func_pattern,
            .captures = &.{
                .{ .group = "1", .scope = "storage.type.function.luce" },
                .{ .group = "2", .scope = "entity.name.function.luce" },
            },
        } },
        .{ .match = .{
            .pattern = struct_pattern,
            .captures = &.{
                .{ .group = "1", .scope = "storage.type.struct.luce" },
                .{ .group = "2", .scope = "entity.name.type.struct.luce" },
            },
        } },
        .{ .match = .{
            .pattern = alias_pattern,
            .captures = &.{
                .{ .group = "1", .scope = "storage.type.alias.luce" },
                .{ .group = "2", .scope = "entity.name.type.alias.luce" },
            },
        } },
        .{ .match = .{
            .pattern = binding_pattern,
            .captures = &.{
                .{ .group = "1", .scope = "storage.type.luce" },
                .{ .group = "2", .scope = "variable.other.definition.luce" },
            },
        } },
        .{ .match = .{
            .pattern = import_pattern,
            .captures = &.{
                .{ .group = "1", .scope = "keyword.control.import.luce" },
                .{ .group = "2", .scope = "entity.name.namespace.luce" },
            },
        } },
    };

    // -- numbers -----------------------------------------------------------
    // **The one correspondence no test here can hold**: there is no
    // regex engine in this program, so nothing can run these patterns
    // over a literal and compare the answer to the lexer's.  They are
    // written next to the lexer's rules and cited to them, and a
    // change to `number()` is a change to be made here by reading.
    //
    // Three bases and the digit separator (docs/BITWISE.md R3, D7),
    // in the order the lexer decides them (lex/lexer.zig's `number`
    // and `basedNumber`).  The well-formed shapes are written exactly
    // — separators between digits and nowhere else — and everything a
    // digit starts that they decline is one malformed literal, which
    // is the lexer's own boundary: `12ab`, `0x`, `1__0` and `0755` are
    // each one mistake rather than a number with something after it.
    const number_rules = [_]Rule{
        // "a number has one decimal point", before the float rule that
        // would otherwise claim the first two thirds of `1.2.3`.
        .{ .match = .{
            .scope = "invalid.illegal.number.luce",
            .pattern = "\\b\\d[\\d_]*(?:\\.[\\d_]+){2,}",
        } },
        // A fraction, an exponent, or both.  A leading zero is only
        // refused on an *integer*, so `01.5` is a float the lexer
        // accepts and this rule accepts with it.
        .{ .match = .{
            .scope = "constant.numeric.float.luce",
            .pattern = "\\b\\d(?:_?\\d)*(?:\\.\\d(?:_?\\d)*(?:[eE][+-]?\\d(?:_?\\d)*)?" ++
                "|[eE][+-]?\\d(?:_?\\d)*)\\b",
        } },
        // "a float needs a digit after the point" — but `1.foo` is
        // member access and is left to the accessor rules.
        .{ .match = .{
            .scope = "invalid.illegal.number.luce",
            .pattern = "\\b\\d[\\d_]*\\.(?![A-Za-z_])",
        } },
        .{ .match = .{
            .scope = "constant.numeric.hex.luce",
            .pattern = "\\b0[xX][0-9a-fA-F](?:_?[0-9a-fA-F])*\\b",
        } },
        .{ .match = .{
            .scope = "constant.numeric.binary.luce",
            .pattern = "\\b0[bB][01](?:_?[01])*\\b",
        } },
        // A decimal integer, which may not start with a zero: there
        // are no octal literals in Luce, so `0755` falls through to
        // the rule below and is refused whole.
        .{ .match = .{
            .scope = "constant.numeric.integer.luce",
            .pattern = "\\b(?:0|[1-9](?:_?\\d)*)\\b",
        } },
        // Everything else a digit opens: an octal, an empty or glued
        // base (`0x`, `0b12`), a misplaced separator (`1_`, `1__0`), a
        // unit suffix (`12ab`), an unfinished exponent (`1e`).
        .{ .match = .{
            .scope = "invalid.illegal.number.luce",
            .pattern = "\\b\\d[A-Za-z0-9_]*",
        } },
        // "a float needs a digit before the point".
        .{ .match = .{
            .scope = "invalid.illegal.number.luce",
            .pattern = "(?<![A-Za-z0-9_)\\]])\\.\\d[\\d_]*(?:[eE][+-]?\\d[\\d_]*)?",
        } },
    };

    // -- keywords ----------------------------------------------------------
    var keyword_rules: [classes.len]Rule = undefined;
    for (classes, 0..) |class, index| {
        keyword_rules[index] = .{ .match = .{
            .scope = class.scope(),
            .pattern = class_patterns[index],
        } };
    }

    // -- types -------------------------------------------------------------
    const type_rules = [_]Rule{
        .{ .match = .{ .scope = "support.type.luce", .pattern = type_pattern } },
        // Every other capitalised name: the convention the language
        // enforces for structs (docs/LANGUAGE.md).
        .{ .match = .{
            .scope = "entity.name.type.luce",
            .pattern = "\\b[A-Z][A-Za-z0-9_]*\\b",
        } },
    };

    // -- what follows a dot ------------------------------------------------
    // Methods first, because several of them are also ordinary names a
    // program may declare; a call next, so `strings.split(s)` reads as
    // a call and not a field; a field last.
    const accessor_rules = [_]Rule{
        .{ .match = .{
            .pattern = method_pattern,
            .captures = &.{
                .{ .group = "1", .scope = "punctuation.accessor.luce" },
                .{ .group = "2", .scope = "support.function.method.luce" },
            },
        } },
        .{ .match = .{
            .pattern = try std.fmt.allocPrint(arena, "(\\.)({s})(?=\\s*\\()", .{name}),
            .captures = &.{
                .{ .group = "1", .scope = "punctuation.accessor.luce" },
                .{ .group = "2", .scope = "entity.name.function.luce" },
            },
        } },
        .{ .match = .{
            .pattern = try std.fmt.allocPrint(arena, "(\\.)({s})", .{name}),
            .captures = &.{
                .{ .group = "1", .scope = "punctuation.accessor.luce" },
                .{ .group = "2", .scope = "variable.other.member.luce" },
            },
        } },
    };

    // -- builtins ----------------------------------------------------------
    // Split by the host gate, because that is a real distinction in the
    // language: an ungated call to one of the second list is
    // `luce.sema.host`.
    const builtin_rules = [_]Rule{
        .{ .match = .{ .scope = "support.function.builtin.luce", .pattern = pure_pattern } },
        .{ .match = .{ .scope = "support.function.builtin.host.luce", .pattern = host_pattern } },
    };

    // -- the two words that stop a program ---------------------------------
    const stopping_rules = try stoppingRules(arena);

    // -- names -------------------------------------------------------------
    // A name starts with a letter, so a word that opens with an
    // underscore is `luce.lex.name` and not a name at all
    // [VISIBILITY.md R3].  The lone `_` is left alone: it is the
    // array-shape wildcard (`array[f64, _, _]`) and declares
    // nothing, so it is neither a name nor a mistake.
    const name_rules = [_]Rule{
        .{ .match = .{
            .scope = "invalid.illegal.name.luce",
            .pattern = "\\b_[A-Za-z0-9_]+\\b",
        } },
    };

    // -- calls, operators, punctuation -------------------------------------
    const call_rules = [_]Rule{
        .{ .match = .{
            .scope = "entity.name.function.call.luce",
            .pattern = try std.fmt.allocPrint(arena, "\\b{s}(?=\\s*\\()", .{name}),
        } },
    };

    const operator_rules = try symbolRules(arena, false);
    const punctuation_rules = try symbolRules(arena, true);

    // -- import lines --------------------------------------------------------
    // `from` and the member-renaming `as` are contextual words, not
    // reserved ones — a program may name a field `from` — so they
    // colour only where the import grammar puts them: on a line that
    // is an import.  The line is a region so `as` can repeat
    // (`from geo import a as x, b as y`), and everything else on it
    // falls through to the ordinary code rules.
    const module_path = try std.fmt.allocPrint(arena, "{s}(?:\\.{s})*", .{ name, name });
    // After `from M import`, everything left on the line is members:
    // an uppercase member reads as the type it names and a lowercase
    // one as the function it names — the same colours the same words
    // wear at their use sites.
    const member_rules = [_]Rule{
        .{ .match = .{
            .scope = "keyword.control.import.luce",
            .pattern = "\\b(as)\\b",
        } },
        .{ .match = .{
            .scope = "entity.name.type.luce",
            .pattern = "\\b[A-Z][A-Za-z0-9_]*\\b",
        } },
        .{ .match = .{
            .scope = "entity.name.function.luce",
            .pattern = "\\b[a-z][A-Za-z0-9_]*\\b",
        } },
    };
    const from_line = try std.fmt.allocPrint(
        arena,
        "^\\s*(from)\\s+({s})\\s+(import)\\b",
        .{module_path},
    );
    const import_line = try std.fmt.allocPrint(
        arena,
        "^\\s*(import)\\s+({s})(?:\\s+(as)\\s+({s}))?\\s*$",
        .{ module_path, name },
    );
    const import_rules = [_]Rule{
        .{ .region = .{
            .scope = "meta.import.luce",
            .begin = from_line,
            .begin_captures = &.{
                .{ .group = "1", .scope = "keyword.control.import.luce" },
                .{ .group = "2", .scope = "entity.name.namespace.luce" },
                .{ .group = "3", .scope = "keyword.control.import.luce" },
            },
            .end = "$",
            .patterns = &member_rules,
        } },
        .{ .match = .{
            .pattern = import_line,
            .captures = &.{
                .{ .group = "1", .scope = "keyword.control.import.luce" },
                .{ .group = "2", .scope = "entity.name.namespace.luce" },
                .{ .group = "3", .scope = "keyword.control.import.luce" },
                .{ .group = "4", .scope = "entity.name.namespace.luce" },
            },
        } },
    };

    // -- the code group ----------------------------------------------------
    // Everything that is neither a comment nor a string, named once so
    // an f-string hole can reuse it exactly.
    const code_rules = [_]Rule{
        .{ .include = "#numbers" },
        .{ .include = "#keywords" },
        .{ .include = "#stopping" },
        .{ .include = "#types" },
        .{ .include = "#accessors" },
        .{ .include = "#builtins" },
        .{ .include = "#names" },
        .{ .include = "#calls" },
        .{ .include = "#operators" },
        .{ .include = "#punctuation" },
    };

    const groups = [_]Group{
        .{ .name = "accessors", .patterns = &accessor_rules },
        .{ .name = "imports", .patterns = &import_rules },
        .{ .name = "builtins", .patterns = &builtin_rules },
        .{ .name = "braces", .patterns = &brace_rules },
        .{ .name = "calls", .patterns = &call_rules },
        .{ .name = "code", .patterns = &code_rules },
        .{ .name = "comments", .patterns = &comment_rules },
        .{ .name = "declarations", .patterns = &declaration_rules },
        .{ .name = "keywords", .patterns = &keyword_rules },
        .{ .name = "names", .patterns = &name_rules },
        .{ .name = "numbers", .patterns = &number_rules },
        .{ .name = "operators", .patterns = operator_rules },
        .{ .name = "punctuation", .patterns = punctuation_rules },
        .{ .name = "stopping", .patterns = stopping_rules },
        .{ .name = "strings", .patterns = &string_rules },
        .{ .name = "types", .patterns = &type_rules },
    };

    const top = [_]Rule{
        .{ .include = "#comments" },
        .{ .include = "#strings" },
        .{ .include = "#imports" },
        .{ .include = "#declarations" },
        .{ .include = "#code" },
    };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try writeDocument(gpa, &out, &top, &groups);
    return out.toOwnedSlice(gpa);
}

fn writeDocument(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    top: []const Rule,
    groups: []const Group,
) Allocator.Error!void {
    try out.appendSlice(gpa, "{\n");
    try key(gpa, out, 1, "information_for_contributors");
    try out.appendSlice(gpa, " [\n");
    for (preamble, 0..) |line, index| {
        try indent(gpa, out, 2);
        try quoted(gpa, out, line);
        try comma(gpa, out, index + 1 < preamble.len);
    }
    try indent(gpa, out, 1);
    try out.appendSlice(gpa, "],\n");

    try field(gpa, out, 1, "$schema", "https://raw.githubusercontent.com/martinring/tmlanguage/master/tmlanguage.json", true);
    try field(gpa, out, 1, "name", "Luce", true);
    try field(gpa, out, 1, "scopeName", "source.luce", true);

    try key(gpa, out, 1, "patterns");
    try out.appendSlice(gpa, " ");
    try writeRules(gpa, out, 1, top);
    try out.appendSlice(gpa, ",\n");

    try key(gpa, out, 1, "repository");
    try out.appendSlice(gpa, " {\n");
    for (groups, 0..) |group, index| {
        try key(gpa, out, 2, group.name);
        try out.appendSlice(gpa, " {\n");
        try key(gpa, out, 3, "patterns");
        try out.appendSlice(gpa, " ");
        try writeRules(gpa, out, 3, group.patterns);
        try out.appendSlice(gpa, "\n");
        try indent(gpa, out, 2);
        try out.appendSlice(gpa, "}");
        try comma(gpa, out, index + 1 < groups.len);
    }
    try indent(gpa, out, 1);
    try out.appendSlice(gpa, "}\n}\n");
}

fn writeRules(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    depth: usize,
    rules: []const Rule,
) Allocator.Error!void {
    try out.appendSlice(gpa, "[\n");
    for (rules, 0..) |rule, index| {
        try writeRule(gpa, out, depth + 1, rule);
        try comma(gpa, out, index + 1 < rules.len);
    }
    try indent(gpa, out, depth);
    try out.appendSlice(gpa, "]");
}

fn writeRule(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    depth: usize,
    rule: Rule,
) Allocator.Error!void {
    try indent(gpa, out, depth);
    try out.appendSlice(gpa, "{\n");
    switch (rule) {
        .include => |target| try field(gpa, out, depth + 1, "include", target, false),
        .match => |match| {
            if (match.scope) |scope| try field(gpa, out, depth + 1, "name", scope, true);
            try field(gpa, out, depth + 1, "match", match.pattern, match.captures.len != 0);
            try writeCaptures(gpa, out, depth + 1, "captures", match.captures, false);
        },
        .region => |region| {
            const after_end = region.end_captures.len != 0 or region.patterns.len != 0;
            try field(gpa, out, depth + 1, "name", region.scope, true);
            try field(gpa, out, depth + 1, "begin", region.begin, true);
            try writeCaptures(gpa, out, depth + 1, "beginCaptures", region.begin_captures, true);
            try field(gpa, out, depth + 1, "end", region.end, after_end);
            try writeCaptures(gpa, out, depth + 1, "endCaptures", region.end_captures, region.patterns.len != 0);
            if (region.patterns.len != 0) {
                try key(gpa, out, depth + 1, "patterns");
                try out.appendSlice(gpa, " ");
                try writeRules(gpa, out, depth + 1, region.patterns);
                try out.appendSlice(gpa, "\n");
            }
        },
    }
    try indent(gpa, out, depth);
    try out.appendSlice(gpa, "}");
}

fn writeCaptures(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    depth: usize,
    name: []const u8,
    captures: []const Capture,
    trailing: bool,
) Allocator.Error!void {
    if (captures.len == 0) return;
    try key(gpa, out, depth, name);
    try out.appendSlice(gpa, " {\n");
    for (captures, 0..) |capture, index| {
        try key(gpa, out, depth + 1, capture.group);
        try out.appendSlice(gpa, " { ");
        try quoted(gpa, out, "name");
        try out.appendSlice(gpa, ": ");
        try quoted(gpa, out, capture.scope);
        try out.appendSlice(gpa, " }");
        try comma(gpa, out, index + 1 < captures.len);
    }
    try indent(gpa, out, depth);
    try out.appendSlice(gpa, "}");
    try comma(gpa, out, trailing);
}

fn field(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    depth: usize,
    name: []const u8,
    value: []const u8,
    trailing: bool,
) Allocator.Error!void {
    try key(gpa, out, depth, name);
    try out.appendSlice(gpa, " ");
    try quoted(gpa, out, value);
    try comma(gpa, out, trailing);
}

fn key(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    depth: usize,
    name: []const u8,
) Allocator.Error!void {
    try indent(gpa, out, depth);
    try quoted(gpa, out, name);
    try out.appendSlice(gpa, ":");
}

fn comma(gpa: Allocator, out: *std.ArrayList(u8), more: bool) Allocator.Error!void {
    try out.appendSlice(gpa, if (more) ",\n" else "\n");
}

fn indent(gpa: Allocator, out: *std.ArrayList(u8), depth: usize) Allocator.Error!void {
    for (0..depth) |_| try out.appendSlice(gpa, "  ");
}

/// A JSON string.  Two escapes carry the whole grammar — regexes are
/// full of `\` and quote the odd `"` — and a control byte would be a
/// bug upstream, so it is escaped rather than passed through.
fn quoted(gpa: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    try out.append(gpa, '"');
    const digits = "0123456789abcdef";
    for (text) |byte| switch (byte) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        0...0x1f => {
            try out.appendSlice(gpa, "\\u00");
            try out.append(gpa, digits[byte >> 4]);
            try out.append(gpa, digits[byte & 0xf]);
        },
        else => try out.append(gpa, byte),
    };
    try out.append(gpa, '"');
}

// ---------------------------------------------------------------------------
// The tool
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init.Minimal) !u8 {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{
        .environ = init.environ,
        .argv0 = .init(init.args),
    });
    defer threaded.deinit();
    const io = threaded.io();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arguments = try init.args.toSlice(arena_state.allocator());
    if (arguments.len != 2) {
        std.debug.print("usage: luce-grammar OUTPUT.tmLanguage.json\n", .{});
        return 2;
    }

    const text = emit(gpa) catch |failure| {
        std.debug.print("luce-grammar: {s}\n", .{@errorName(failure)});
        return 1;
    };
    defer gpa.free(text);

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = arguments[1], .data = text }) catch |failure| {
        std.debug.print(
            "luce-grammar: cannot write {s}: {s}\n",
            .{ arguments[1], @errorName(failure) },
        );
        return 1;
    };
    return 0;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// The committed grammar, as bytes.  Embedded rather than read from
/// disk so the pin below holds wherever the test runs from.
const committed = @embedFile("vscode-luce/syntaxes/luce.tmLanguage.json");

test "the committed grammar is what the generator emits" {
    // This is the pin.  A language change that adds a keyword, a
    // builtin or a method reaches the grammar only when someone runs
    // the generator, and this is what makes forgetting a test failure
    // instead of a year of silence.
    const gpa = std.testing.allocator;
    const generated = try emit(gpa);
    defer gpa.free(generated);
    if (std.mem.eql(u8, committed, generated)) return;

    // The first line that differs, and not the whole file: it is three
    // hundred generated lines, and printing two copies of it buries the
    // one line that matters under the six hundred that do not.
    var committed_lines = std.mem.splitScalar(u8, committed, '\n');
    var generated_lines = std.mem.splitScalar(u8, generated, '\n');
    var line: usize = 1;
    while (true) : (line += 1) {
        const theirs = committed_lines.next();
        const ours = generated_lines.next();
        if (theirs == null and ours == null) break;
        if (theirs != null and ours != null and std.mem.eql(u8, theirs.?, ours.?)) continue;
        std.debug.print(
            \\
            \\{s} is stale: run `zig build grammar` and commit the result.
            \\
            \\  line {d}
            \\  committed: {s}
            \\  generated: {s}
            \\
            \\
        , .{ committed_path, line, theirs orelse "(end of file)", ours orelse "(end of file)" });
        break;
    }
    return error.TestUnexpectedResult;
}

test "the generator is deterministic" {
    const gpa = std.testing.allocator;
    const first = try emit(gpa);
    defer gpa.free(first);
    const second = try emit(gpa);
    defer gpa.free(second);
    try std.testing.expectEqualStrings(first, second);
}

test "what it emits is JSON, and it is a grammar" {
    const gpa = std.testing.allocator;
    const text = try emit(gpa);
    defer gpa.free(text);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("source.luce", root.get("scopeName").?.string);
    try std.testing.expect(root.get("patterns").?.array.items.len > 0);

    // Every `#name` the grammar includes has an entry in the
    // repository: a missing one silently colours nothing.
    const repository = root.get("repository").?.object;
    var missing: usize = 0;
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, text, index, "\"include\": \"#")) |found| {
        const start = found + "\"include\": \"#".len;
        const end = std.mem.indexOfScalarPos(u8, text, start, '"').?;
        if (!repository.contains(text[start..end])) {
            std.debug.print("include #{s} has no repository entry\n", .{text[start..end]});
            missing += 1;
        }
        index = end;
    }
    try std.testing.expectEqual(@as(usize, 0), missing);
}

test "f-string holes enter strings and recursively balanced braces" {
    const gpa = std.testing.allocator;
    const text = try emit(gpa);
    defer gpa.free(text);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    defer parsed.deinit();
    const repository = parsed.value.object.get("repository").?.object;

    var hole_has_strings = false;
    var hole_has_braces = false;
    const string_rules = repository.get("strings").?.object.get("patterns").?.array.items;
    for (string_rules) |string_value| {
        const string_rule = string_value.object;
        const string_begin = string_rule.get("begin") orelse continue;
        if (string_begin != .string or !std.mem.eql(u8, string_begin.string, "\\bf\"")) continue;
        for (string_rule.get("patterns").?.array.items) |hole_value| {
            const hole = hole_value.object;
            const hole_begin = hole.get("begin") orelse continue;
            if (hole_begin != .string or !std.mem.eql(u8, hole_begin.string, "\\{")) continue;
            for (hole.get("patterns").?.array.items) |inside_value| {
                const include = inside_value.object.get("include") orelse continue;
                if (std.mem.eql(u8, include.string, "#strings")) hole_has_strings = true;
                if (std.mem.eql(u8, include.string, "#braces")) hole_has_braces = true;
            }
        }
    }

    var braces_recurse = false;
    var braces_enter_strings = false;
    const brace_rules = repository.get("braces").?.object.get("patterns").?.array.items;
    for (brace_rules[0].object.get("patterns").?.array.items) |inside_value| {
        const include = inside_value.object.get("include") orelse continue;
        if (std.mem.eql(u8, include.string, "#braces")) braces_recurse = true;
        if (std.mem.eql(u8, include.string, "#strings")) braces_enter_strings = true;
    }

    try std.testing.expect(hole_has_strings);
    try std.testing.expect(hole_has_braces);
    try std.testing.expect(braces_recurse);
    try std.testing.expect(braces_enter_strings);
}

test "character literals have their own quoted rule and Unicode escape" {
    const gpa = std.testing.allocator;
    const text = try emit(gpa);
    defer gpa.free(text);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    defer parsed.deinit();
    const string_rules = parsed.value.object
        .get("repository").?.object
        .get("strings").?.object
        .get("patterns").?.array.items;

    var found_character = false;
    var found_unicode_escape = false;
    for (string_rules) |value| {
        const rule = value.object;
        const begin = rule.get("begin") orelse continue;
        if (begin != .string or !std.mem.eql(u8, begin.string, "'")) continue;
        const scope = rule.get("name") orelse continue;
        found_character = scope == .string and
            std.mem.eql(u8, scope.string, "constant.character.luce");
        for (rule.get("patterns").?.array.items) |pattern_value| {
            const pattern = pattern_value.object.get("match") orelse continue;
            if (pattern == .string and std.mem.indexOf(u8, pattern.string, "u\\{") != null) {
                found_unicode_escape = true;
            }
        }
    }
    try std.testing.expect(found_character);
    try std.testing.expect(found_unicode_escape);
}

test "every keyword the lexer reserves has a class" {
    for (luce.lex.keywords) |keyword| {
        if (keywordClass(keyword.kind) == null) {
            std.debug.print(
                "keyword '{s}' has no grammar class; add it to keywordClass\n",
                .{keyword.word},
            );
            return error.TestUnexpectedResult;
        }
    }
}

/// How many of the word classes claim `word`.
fn classesClaiming(gpa: Allocator, word: []const u8) !usize {
    var count: usize = 0;
    for (classes) |class| {
        var words = try keywordsOf(gpa, class);
        defer words.deinit();
        if (words.has(word)) count += 1;
    }
    for (luce.semantics.builtins) |builtin| {
        if (stoppingScope(builtin) == null) continue;
        if (std.mem.eql(u8, builtin.name, word)) count += 1;
    }
    var types = try typeNames(gpa);
    defer types.deinit();
    if (types.has(word)) count += 1;
    for ([_]bool{ false, true }) |host| {
        var builtins = try builtinNames(gpa, host);
        defer builtins.deinit();
        if (builtins.has(word)) count += 1;
    }
    var methods = try methodNames(gpa);
    defer methods.deinit();
    if (methods.has(word)) count += 1;
    return count;
}

test "every name the language reserves is coloured exactly once" {
    // The guard the site's copied tables have and the old grammar had
    // not: a reserved name is one no program may take for itself, so
    // every one of them is the language wherever it appears, and every
    // one of them must be coloured — once, by one class.
    const gpa = std.testing.allocator;
    for (luce.semantics.reserved_names) |name| {
        const count = try classesClaiming(gpa, name);
        const wanted: usize = if (inList(&unspellable, name)) 0 else 1;
        if (count != wanted) {
            std.debug.print(
                "reserved name '{s}' is claimed by {d} classes, want {d}\n",
                .{ name, count, wanted },
            );
            return error.TestUnexpectedResult;
        }
    }
}

test "every method name is coloured, and only behind a dot" {
    const gpa = std.testing.allocator;
    var methods = try methodNames(gpa);
    defer methods.deinit();
    for (methods.items.items) |name| {
        try std.testing.expectEqual(@as(usize, 1), try classesClaiming(gpa, name));
    }
    // The rule that carries them is the only one with a `(\.)` in
    // front, so a bare `find(1)` is somebody's own function.
    const text = try emit(gpa);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "(\\\\.)(append|") != null);
}

fn inList(list: []const []const u8, word: []const u8) bool {
    for (list) |entry| {
        if (std.mem.eql(u8, entry, word)) return true;
    }
    return false;
}

/// The flagship program as a corpus of real Luce: declarations,
/// ownership, every container, f-strings, host effects and `catch`.
/// Since the editor split into modules no single file is large enough to
/// exercise the language on its own, so the corpus is several of them
/// concatenated — the coordinator, the highlighter, the text model, the
/// declarative application and the file browser. Reached by names `build.zig` binds,
/// because they sit above this module's root and `@embedFile` does not
/// leave a module.
const corpus = @embedFile("model.luc") ++ "\n" ++
    @embedFile("highlight.luc") ++ "\n" ++
    @embedFile("document.luc") ++ "\n" ++
    @embedFile("ui/workbench.luc") ++ "\n" ++
    @embedFile("ui/source.luc") ++ "\n" ++
    @embedFile("listing.luc");

test "every language word the editor uses is coloured" {
    // A corpus test rather than another table test: `examples/editor/editor.luc`
    // is the largest Luce program there is, and what it says is what a
    // person actually looks at in an editor.  Any word in it that the
    // language reserves, or that names a method, must have a class.
    const gpa = std.testing.allocator;
    var index: usize = 0;
    var checked: usize = 0;
    while (index < corpus.len) {
        if (!isWordStart(corpus[index])) {
            index += 1;
            continue;
        }
        const start = index;
        while (index < corpus.len and isWordPart(corpus[index])) index += 1;
        const word = corpus[start..index];
        if (!luce.semantics.isReserved(word)) continue;
        if (inList(&unspellable, word)) continue;
        if (try classesClaiming(gpa, word) != 1) {
            std.debug.print("the editor uses '{s}', which the grammar leaves alone\n", .{word});
            return error.TestUnexpectedResult;
        }
        checked += 1;
    }
    // The corpus has to be worth reading: if it stops exercising the
    // language, this test stops proving anything and should say so.
    try std.testing.expect(checked > 100);
}

fn isWordStart(byte: u8) bool {
    return byte == '_' or std.ascii.isAlphabetic(byte);
}

fn isWordPart(byte: u8) bool {
    return byte == '_' or std.ascii.isAlphanumeric(byte);
}

test "every symbol the lexer has a kind for has a row, and only one" {
    // The guard the bit set went without: `&`, `|`, `^`, `~`, `<<` and
    // `>>` reached `Kind` and the grammar heard nothing, because the
    // operator rules were a hand-written list nothing compared to the
    // language.  This is that comparison.
    inline for (std.meta.fields(luce.lex.Kind)) |declared| {
        const kind: luce.lex.Kind = @enumFromInt(declared.value);
        if (isSymbolKind(kind)) {
            var found: usize = 0;
            for (symbols) |symbol| {
                if (symbol.kind == kind) found += 1;
            }
            if (found != 1) {
                std.debug.print(
                    "token kind '{s}' has {d} rows in `symbols`, want 1\n",
                    .{ declared.name, found },
                );
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "every symbol's spelling lexes back to the kind it claims" {
    // The other half of the copy's price: a row may not merely exist,
    // it has to be what the lexer reads.  Each spelling is lexed on
    // its own line, and the token in front of the layout must be the
    // kind the row names — so a symbol that changes meaning in the
    // language changes here or this names the row that lied.
    const gpa = std.testing.allocator;
    for (symbols) |symbol| {
        var text: [16]u8 = undefined;
        const source = try std.fmt.bufPrint(&text, "{s}\n", .{symbol.text});
        var diagnostics = luce.diagnostics.Diagnostics.init(gpa);
        defer diagnostics.deinit();
        const lexed = try luce.lex.lex(gpa, source, &diagnostics);
        defer gpa.free(lexed.tokens);
        if (lexed.tokens.len == 0 or lexed.tokens[0].kind != symbol.kind) {
            std.debug.print(
                "'{s}' lexes as {s}, not {s}\n",
                .{
                    symbol.text,
                    if (lexed.tokens.len == 0) "nothing" else @tagName(lexed.tokens[0].kind),
                    @tagName(symbol.kind),
                },
            );
            return error.TestUnexpectedResult;
        }
    }
}

test "a symbol is always tried before the shorter one it opens with" {
    // What makes `<<=` a compound assignment rather than a shift and a
    // stray `=`, and `==` a comparison rather than two assignments:
    // TextMate takes the first rule that matches at a position, and
    // the rules are written in this order, so a spelling that another
    // one starts with must come after it.
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_]bool{ false, true }) |punctuation| {
        const rows = try sortedSymbols(arena, punctuation);
        for (rows, 0..) |row, index| {
            for (rows[index + 1 ..]) |later| {
                if (!std.mem.startsWith(u8, later.text, row.text)) continue;
                if (later.text.len == row.text.len) continue;
                std.debug.print(
                    "'{s}' is written before '{s}', which opens with it\n",
                    .{ row.text, later.text },
                );
                return error.TestUnexpectedResult;
            }
        }
    }
}
