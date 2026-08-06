//! The Luce TextMate grammar, generated from the language's own tables.
//!
//!   zig build grammar   # rewrites tools/vscode-luce/syntaxes/luce.tmLanguage.json
//!
//! **Generated because the hand-written one drifted.**  The committed
//! grammar spent a release cycle highlighting `create_texel`,
//! `texel_output` and `read_file` — Fabric and host builtins the
//! language had deleted — while knowing nothing of `give`, `copy`,
//! `new`, `try`, `catch`, `none`, or the four heap types.  Nothing
//! pinned it to the language, so nothing said.  Every word below is
//! read from the table the compiler dispatches on, and
//! `test "the committed grammar is what the generator emits"` fails
//! the suite the moment the two disagree.
//!
//! **It imports `luce` rather than copying its tables.**  That is the
//! difference between this and `site/src/highlight.zig`, which copies
//! deliberately: the site generator drives the *built binaries* as
//! subprocesses so it can verify what the toolchain really does, and
//! linking the language in would undercut that.  This generator
//! verifies nothing about a running program — it turns five word
//! tables into one JSON file — so the import is free, and a copy would
//! only be one more thing to keep honest.
//!
//! The five classes and what they read:
//!
//!   keywords  `02_lex/token.zig`'s `keywords`, by kind
//!   verbs     the same table's `new`/`give`/`copy`, plus `free`
//!   types     `support/types.zig`'s `builtin_names`, plus `None`
//!   builtins  `04_semantics/builder.zig`'s `builtins`
//!   methods   the same file's five method tables
//!
//! A keyword the language gains reaches the grammar by itself; a
//! keyword whose colour nobody has decided stops the generator by
//! name rather than being quietly left out.

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
    /// `func`, `struct`, `let`, `var` — what a declaration opens with.
    storage,
    /// `import`.
    import,
    /// `try`, `catch` (docs/FAILURE.md).
    exception,
    /// `true`, `false`, `none` — values with no other spelling.
    constant,
    /// `new`, `give`, `copy` and the `free` builtin: the words that
    /// move ownership.  They get a class of their own because they are
    /// the language's one genuinely unusual idea (docs/OWNERSHIP.md),
    /// and a reader scanning a file should see every one of them.
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
    .control,   .word_operator, .storage,   .import,
    .exception, .constant,      .ownership, .receiver,
};

/// The class each keyword the lexer reserves belongs to.
///
/// Every keyword kind is named explicitly and `else` yields null, so
/// adding one to `02_lex/token.zig` and not here is caught — by the
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
        => .control,

        .keyword_and, .keyword_or, .keyword_not => .word_operator,

        .keyword_func,
        .keyword_struct,
        .keyword_let,
        .keyword_var,
        .keyword_public,
        .keyword_private,
        => .storage,

        .keyword_import => .import,

        .keyword_try, .keyword_catch => .exception,

        .keyword_true, .keyword_false, .keyword_none => .constant,

        .keyword_new, .keyword_give, .keyword_copy => .ownership,

        .keyword_self => .receiver,

        else => null,
    };
}

/// The one free builtin that is an ownership verb rather than a call
/// to colour like `len`.  Matched on what it lowers to and not on its
/// spelling, so renaming it in the language renames it here.
fn isOwnershipBuiltin(builtin: luce.semantics.Builtin) bool {
    return builtin.kind == .free_object;
}

/// Reserved names the language spells nowhere else.
///
/// `range` is *syntax*: the parser recognises it only in
/// `for i in range(a, b)` (`03_parse/grammar.zig`) and there is no
/// entry for it in the builtin table.  It is written like a call and
/// reads like one, so it is coloured like one.
const reserved_syntax = [_][]const u8{"range"};

/// Reserved and unspellable: a name the language keeps out of a
/// program's reach with nothing behind it.
///
/// Reserved words that name nothing callable.  Empty since `slice`
/// stopped being reserved (owner, 2026-08-04: the syntax `xs[a:b]` is
/// the feature, so the word needs no claiming) — and it stays here so
/// the next fossil has a place to be noticed instead of coloured.
const unspellable = [_][]const u8{};

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
    if (class == .ownership) {
        for (luce.semantics.builtins) |builtin| {
            if (isOwnershipBuiltin(builtin)) try words.add(builtin.name);
        }
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

/// The type names the language itself spells: the capitalised half of
/// the reserved list.  Any *other* capitalised name is a type too —
/// that is the convention the language enforces for structs — and the
/// grammar has a second, looser rule for those.
/// The builtin type names, read from the compiler's own table rather
/// than guessed from a name's case.  It used to take every reserved
/// name that began with a capital, which stopped being a description
/// of anything the moment the language's own names became lowercase
/// (docs/TYPES.md D8) — `long` is a type and `String` is one only
/// until the rename retires it, and neither fact is in a first letter.
fn typeNames(gpa: Allocator) Allocator.Error!Words {
    var words: Words = .{ .gpa = gpa };
    errdefer words.deinit();
    try words.addAll(&luce.types.builtin_names);
    try words.add("None");
    return words;
}

/// The free builtins, host-gated or not.  `free` is left out: it is an
/// ownership verb (`isOwnershipBuiltin`).
fn builtinNames(gpa: Allocator, host: bool) Allocator.Error!Words {
    var words: Words = .{ .gpa = gpa };
    errdefer words.deinit();
    if (!host) try words.addAll(&reserved_syntax);
    for (luce.semantics.builtins) |builtin| {
        if (isOwnershipBuiltin(builtin)) continue;
        if (builtin.host == host) try words.add(builtin.name);
    }
    return words;
}

/// Every name that means the language only behind a `.`: the four
/// receiver tables plus the two String primitives.  Several of them —
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

    const func_pattern = try std.fmt.allocPrint(
        arena,
        "\\b({s})\\s+([A-Za-z_][A-Za-z0-9_]*)",
        .{spelling(.keyword_func)},
    );
    const struct_pattern = try std.fmt.allocPrint(
        arena,
        "\\b({s})\\s+([A-Za-z_][A-Za-z0-9_]*)",
        .{spelling(.keyword_struct)},
    );
    const binding_pattern = try std.fmt.allocPrint(
        arena,
        "\\b({s}|{s})\\s+([A-Za-z_][A-Za-z0-9_]*)",
        .{ spelling(.keyword_let), spelling(.keyword_var) },
    );
    const import_pattern = try std.fmt.allocPrint(
        arena,
        "\\b({s})\\s+([A-Za-z_][A-Za-z0-9_.]*)",
        .{spelling(.keyword_import)},
    );

    // -- comments ----------------------------------------------------------
    // `#` to end of line, and there is no block form (02_lex/lexer.zig).
    const comment_rules = [_]Rule{
        .{ .match = .{
            .scope = "comment.line.number-sign.luce",
            .pattern = "(#).*$",
            .captures = &.{.{ .group = "1", .scope = "punctuation.definition.comment.luce" }},
        } },
    };

    // -- f-string holes ----------------------------------------------------
    // A hole is one expression.  Its patterns are `#code` and not
    // `$self`: the lexer scans an f-string as a single token that ends
    // at the first unescaped `"`, so a hole can contain neither a
    // string nor a comment, and offering them would colour text the
    // language cannot hold.
    const escape_rules = [_]Rule{
        .{ .match = .{
            .scope = "constant.character.escape.luce",
            .pattern = "\\\\[nt\\\\\"]",
        } },
        .{ .match = .{
            .scope = "invalid.illegal.escape.luce",
            .pattern = "\\\\.",
        } },
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
            .patterns = &.{.{ .include = "#code" }},
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
                // not (02_lex/lexer.zig).
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
    // Decimal only, and in the order the lexer decides them
    // (02_lex/lexer.zig's `number`): the malformed shapes are matched
    // before the well-formed ones they start with, so `1.2.3` reads as
    // one mistake rather than a float, a dot and an integer.
    const number_rules = [_]Rule{
        // "a number has one decimal point".
        .{ .match = .{
            .scope = "invalid.illegal.number.luce",
            .pattern = "\\b\\d+(?:\\.\\d+){2,}",
        } },
        .{ .match = .{
            .scope = "constant.numeric.float.luce",
            .pattern = "\\b\\d+(?:\\.\\d+(?:[eE][+-]?\\d+)?|[eE][+-]?\\d+)\\b",
        } },
        // "a float needs a digit after the point" — but `1.foo` is
        // member access and is left to the accessor rules.
        .{ .match = .{
            .scope = "invalid.illegal.number.luce",
            .pattern = "\\b\\d+\\.(?![A-Za-z_])",
        } },
        // A radix prefix, a digit separator, a unit suffix: one
        // malformed literal, not a number and a word.
        .{ .match = .{
            .scope = "invalid.illegal.number.luce",
            .pattern = "\\b\\d+[A-Za-z_][A-Za-z0-9_]*\\b",
        } },
        // "a decimal integer may not start with a zero; there are no
        // octal literals in Luce".
        .{ .match = .{
            .scope = "invalid.illegal.number.luce",
            .pattern = "\\b0\\d+\\b",
        } },
        // "a float needs a digit before the point".
        .{ .match = .{
            .scope = "invalid.illegal.number.luce",
            .pattern = "(?<![A-Za-z0-9_)\\]])\\.\\d+(?:[eE][+-]?\\d+)?",
        } },
        .{ .match = .{
            .scope = "constant.numeric.integer.luce",
            .pattern = "\\b\\d+\\b",
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
            .pattern = "(\\.)([A-Za-z_][A-Za-z0-9_]*)(?=\\s*\\()",
            .captures = &.{
                .{ .group = "1", .scope = "punctuation.accessor.luce" },
                .{ .group = "2", .scope = "entity.name.function.luce" },
            },
        } },
        .{ .match = .{
            .pattern = "(\\.)([A-Za-z_][A-Za-z0-9_]*)",
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

    // -- calls, operators, punctuation -------------------------------------
    const call_rules = [_]Rule{
        .{ .match = .{
            .scope = "entity.name.function.call.luce",
            .pattern = "\\b[A-Za-z_][A-Za-z0-9_]*(?=\\s*\\()",
        } },
    };

    const operator_rules = [_]Rule{
        .{ .match = .{
            .scope = "keyword.operator.function-return.luce",
            .pattern = "->",
        } },
        .{ .match = .{
            .scope = "keyword.operator.comparison.luce",
            .pattern = "==|!=|<=|>=|<|>",
        } },
        .{ .match = .{
            .scope = "keyword.operator.assignment.luce",
            .pattern = "(?<![=!<>])=(?!=)",
        } },
        // `T!` and `-> !`: the fallible marker (docs/FAILURE.md).  `!=`
        // is matched above, so what is left here is never a comparison.
        .{ .match = .{
            .scope = "keyword.operator.fallible.luce",
            .pattern = "!(?!=)",
        } },
        // `T?`: the optional marker.  Luce spells nothing else with a
        // question mark — there is no conditional expression — so the
        // bare character is exact.
        .{ .match = .{
            .scope = "keyword.operator.optional.luce",
            .pattern = "\\?",
        } },
        .{ .match = .{
            .scope = "keyword.operator.arithmetic.luce",
            .pattern = "\\+|-|\\*|/|%",
        } },
    };

    const punctuation_rules = [_]Rule{
        .{ .match = .{ .scope = "punctuation.section.group.begin.luce", .pattern = "\\(" } },
        .{ .match = .{ .scope = "punctuation.section.group.end.luce", .pattern = "\\)" } },
        .{ .match = .{ .scope = "punctuation.section.brackets.begin.luce", .pattern = "\\[" } },
        .{ .match = .{ .scope = "punctuation.section.brackets.end.luce", .pattern = "\\]" } },
        .{ .match = .{ .scope = "punctuation.separator.comma.luce", .pattern = "," } },
        .{ .match = .{ .scope = "punctuation.separator.colon.luce", .pattern = ":" } },
        .{ .match = .{ .scope = "punctuation.accessor.luce", .pattern = "\\." } },
    };

    // -- the code group ----------------------------------------------------
    // Everything that is neither a comment nor a string, named once so
    // an f-string hole can reuse it exactly.
    const code_rules = [_]Rule{
        .{ .include = "#numbers" },
        .{ .include = "#keywords" },
        .{ .include = "#types" },
        .{ .include = "#accessors" },
        .{ .include = "#builtins" },
        .{ .include = "#calls" },
        .{ .include = "#operators" },
        .{ .include = "#punctuation" },
    };

    const groups = [_]Group{
        .{ .name = "accessors", .patterns = &accessor_rules },
        .{ .name = "builtins", .patterns = &builtin_rules },
        .{ .name = "calls", .patterns = &call_rules },
        .{ .name = "code", .patterns = &code_rules },
        .{ .name = "comments", .patterns = &comment_rules },
        .{ .name = "declarations", .patterns = &declaration_rules },
        .{ .name = "keywords", .patterns = &keyword_rules },
        .{ .name = "numbers", .patterns = &number_rules },
        .{ .name = "operators", .patterns = &operator_rules },
        .{ .name = "punctuation", .patterns = &punctuation_rules },
        .{ .name = "strings", .patterns = &string_rules },
        .{ .name = "types", .patterns = &type_rules },
    };

    const top = [_]Rule{
        .{ .include = "#comments" },
        .{ .include = "#strings" },
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

/// How many of the five word classes claim `word`.
fn classesClaiming(gpa: Allocator, word: []const u8) !usize {
    var count: usize = 0;
    for (classes) |class| {
        var words = try keywordsOf(gpa, class);
        defer words.deinit();
        if (words.has(word)) count += 1;
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

/// The flagship program: a full-screen editor that uses declarations,
/// ownership, every container, f-strings, host effects and `catch`.
/// Reached by a name `build.zig` binds, because it sits above this
/// module's root and `@embedFile` does not leave a module.
const corpus = @embedFile("editor.luc");

test "every language word the editor uses is coloured" {
    // A corpus test rather than another table test: `programs/editor.luc`
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
            std.debug.print("editor.luc uses '{s}', which the grammar leaves alone\n", .{word});
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
